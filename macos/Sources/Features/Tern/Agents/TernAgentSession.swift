import Foundation

/// What a harness driver reports to its session, and what the session asks of it.
protocol TernHarnessDriver: AnyObject {
    /// The command line (after the binary) for a fresh or a resumed conversation.
    func arguments(resume: Bool) -> [String]
    /// Talk to a freshly spawned process (initialize, open the conversation).
    func begin(process: TernHarnessProcess, resume: Bool)
    /// A line of the harness's stdout, already parsed.
    func handle(_ frame: [String: Any])
    /// Hand a message to the harness. False if it couldn't be written.
    func send(_ message: TernAgentMessage) -> Bool
    /// Interrupt the running turn (Codex: exactly this turn).
    func interrupt(turnID: String?)
    /// Answer a pending request. Returns an error message if the answer doesn't fit.
    func answer(_ request: TernAgentRequest, _ answer: TernAgentAnswer) -> String?
}

enum TernAgentAnswer {
    case allow(always: Bool, message: String?)
    case deny(message: String?)
    case answers([String: String])   // question id → text
}

/// One managed session: its stored state, its harness process, its queue of messages and
/// the turn in progress. Every method runs on `TernAgents.queue`.
///
/// Delivery rule: messages wait in the session's own queue and are handed to the harness
/// one at a time, only when the harness is ready and no turn is running. So a message is
/// in exactly one place (queued here, written and unconfirmed, delivered), an interrupt
/// can only hit the turn that was running, and a redirect can go ahead of everything
/// queued (MA-4, MA-8, MA-25). Steering a running turn (negotiable) is given up for this.
final class TernAgentSession {
    var record: TernSessionRecord
    private(set) var messages: [TernAgentMessage] = []
    private var messageIndex: [String: Int] = [:]
    private(set) var items: [TernTranscriptItem] = []
    private var itemIndex: [String: Int] = [:]
    private var itemByRef: [String: String] = [:]
    private(set) var requests: [TernAgentRequest] = []
    /// Message ids waiting to be handed to the harness, in delivery order.
    private(set) var queue: [String] = []

    enum Phase: String { case stopped, launching, starting, ready, stopping, cleaning }
    private(set) var phase: Phase = .stopped
    private(set) var process: TernHarnessProcess?
    private var driver: TernHarnessDriver?
    private var generation = 0
    /// A message written to the harness whose delivery isn't confirmed yet.
    private(set) var inFlight: String?

    struct Turn {
        var id: String?
        var messages: [String]
        let selfStarted: Bool
        let startedAt: Date
        var interruptRequested = false
        var lastFinal: String?
        var error: String?
    }
    private(set) var turn: Turn?
    private var claudeTurnCounter = 0

    var backgroundTasks: Int?
    private(set) var activity: String = ""
    private var runningTools: [String: String] = [:]   // ref → description

    /// The process ended before it ever took a message: don't relaunch forever.
    private var failedLaunches = 0
    private var everReady = false
    private var startFlags: [String] = []

    /// `agent stop` (or shutdown) in progress.
    private struct Stop {
        let kind: Kind
        enum Kind { case user, shutdown, restart, remove }
        var completions: [() -> Void]
    }
    private var stop: Stop?
    /// The app is quitting: running turns are cut off (they continue after the restart).
    private(set) var shuttingDown = false
    private var shutdownReason = "quit"

    /// A redirect waiting for the turn it interrupted.
    private struct Redirect {
        let turnID: String?
        let turnStartedAt: Date
        let deadline: DispatchWorkItem
    }
    private var redirect: Redirect?
    /// A redirect arrived while a message was written but its turn not yet acknowledged: that
    /// turn is interrupted as soon as it starts.
    private var interruptWhenInFlightStarts = false

    private var waiters: [UUID: () -> Bool] = [:]
    private(set) var version = 0
    private var uiPosted = false

    weak var manager: TernAgents?

    init(record: TernSessionRecord) {
        self.record = record
    }

    // MARK: Loading and saving

    func adopt(messages loaded: [TernAgentMessage], items loadedItems: [TernTranscriptItem]) {
        messages = loaded.sorted { $0.order < $1.order }
        messageIndex = Dictionary(uniqueKeysWithValues: messages.enumerated().map { ($1.id, $0) })
        items = loadedItems
        itemIndex = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, $0) })
        for item in items { if let ref = item.ref { itemByRef[ref] = item.id } }
    }

    func saveRecord() {
        TernAgentStore.saveRecord(record)
    }

    private func store(_ message: TernAgentMessage) {
        if let index = messageIndex[message.id] {
            messages[index] = message
        } else {
            messageIndex[message.id] = messages.count
            messages.append(message)
        }
        TernAgentStore.append(record.id, message: message)
    }

    func replaceMessage(_ message: TernAgentMessage) {
        store(message)
    }

    func message(_ id: String) -> TernAgentMessage? {
        messageIndex[id].map { messages[$0] }
    }

    private func update(_ id: String, _ change: (inout TernAgentMessage) -> Void) {
        guard let index = messageIndex[id] else { return }
        var message = messages[index]
        change(&message)
        messages[index] = message
        TernAgentStore.append(record.id, message: message)
    }

    // MARK: Transcript

    @discardableResult
    func addItem(kind: String, text: String, message: String? = nil, tool: String? = nil, detail: String? = nil,
                 output: String? = nil, state: String? = nil, ref: String? = nil) -> String {
        let id = "\(record.id.prefix(8))-\(record.nextItem)"
        record.nextItem += 1
        let item = TernTranscriptItem(id: id, kind: kind, text: text, message: message, tool: tool, detail: detail,
                                      output: output.map { TernAgentText.clip($0) }, state: state, at: Date(), ref: ref)
        itemIndex[id] = items.count
        items.append(item)
        if let ref { itemByRef[ref] = id }
        TernAgentStore.append(record.id, item: item)
        changed()
        return id
    }

    func updateItem(ref: String, _ change: (inout TernTranscriptItem) -> Void) {
        guard let id = itemByRef[ref], let index = itemIndex[id] else { return }
        var item = items[index]
        change(&item)
        if let output = item.output { item.output = TernAgentText.clip(output) }
        items[index] = item
        TernAgentStore.append(record.id, item: item)
        changed()
    }

    func hasItem(ref: String) -> Bool { itemByRef[ref] != nil }

    func notice(_ text: String) {
        addItem(kind: "notice", text: text)
    }

    // MARK: Status

    var live: Bool { process != nil }

    var status: String {
        if live, !requests.isEmpty { return "needs_input" }
        switch phase {
        case .launching, .starting:
            return "starting"
        case .ready:
            return (turn != nil || inFlight != nil || !queue.isEmpty) ? "working" : "idle"
        case .stopping:
            return turn != nil ? "working" : "exited"
        case .stopped, .cleaning:
            if !queue.isEmpty && canRelaunch { return "starting" }
            return record.ended == "error" ? "error" : "exited"
        }
    }

    var activityText: String {
        if live, let request = requests.first { return "waiting: \(request.title)" }
        switch phase {
        case .launching, .starting: return everReady || record.conversation == true ? "resuming" : "starting"
        case .stopping: return "stopping"
        case .stopped, .cleaning:
            if !queue.isEmpty && canRelaunch { return "resuming" }
            if record.ended == "error" { return record.lastError.map { TernAgentText.oneLine($0, max: 120) } ?? "error" }
            return record.ended == "stopped" ? "stopped" : "exited"
        case .ready:
            if turn == nil && inFlight == nil && queue.isEmpty { return "idle" }
            if let tool = runningTools.values.first { return tool }
            if !activity.isEmpty { return activity }
            return turn?.selfStarted == true ? "working (on its own)" : "working"
        }
    }

    /// The latest message someone sent (not a product note).
    var lastMessage: TernAgentMessage? {
        messages.last { $0.note != true }
    }

    /// The most recent reply: the last turn that ended with a reply, including turns the
    /// agent started itself.
    var lastReply: String? {
        if let item = items.last(where: { $0.kind == "assistant" && $0.state == "final" }) { return item.text }
        return messages.last { $0.reply != nil }?.reply
    }

    func changed() {
        version &+= 1
        evaluateWaiters()
        if !uiPosted {
            uiPosted = true
            let id = record.id
            TernAgents.queue.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.uiPosted = false
                let snapshot = self?.snapshot()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { TernAgentUI.sessionChanged(id, snapshot) }
                }
            }
        }
    }

    func snapshot() -> TernAgentSnapshot {
        TernAgentSnapshot(id: record.id, name: record.name, kind: record.kind, status: status, activity: activityText,
                          cwd: record.cwd, live: live, items: items, requests: requests,
                          queued: queue.compactMap { message($0) }.filter { $0.note != true }.map(\.text),
                          version: version, error: record.lastError, model: record.startup?.model ?? record.model)
    }

    // MARK: Waiters

    /// `check` runs after every change; returning true removes it.
    func addWaiter(_ check: @escaping () -> Bool) -> UUID {
        let id = UUID()
        waiters[id] = check
        return id
    }

    func removeWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)
    }

    private func evaluateWaiters() {
        guard !waiters.isEmpty else { return }
        for (id, check) in waiters where check() {
            waiters.removeValue(forKey: id)
        }
    }

    // MARK: Messages in

    /// Queue a message. `front` puts it ahead of everything queued (a redirect or a note).
    @discardableResult
    func enqueue(text: String, from: String? = nil, note: Bool = false, continues: [String]? = nil,
                 front: Bool = false, id: String? = nil) -> TernAgentMessage {
        let message = TernAgentMessage(id: id ?? UUID().uuidString.lowercased(), text: text, createdAt: Date(),
                                       order: record.nextOrder, state: .queued, from: from, note: note ? true : nil,
                                       continues: continues)
        record.nextOrder += 1
        store(message)
        // Someone asked again: a session that couldn't start gets a new attempt.
        if !note && phase == .stopped { failedLaunches = 0 }
        if front { queue.insert(message.id, at: 0) } else { queue.append(message.id) }
        saveQueue()
        changed()
        return message
    }

    private func saveQueue() {
        record.queue = queue
        saveRecord()
    }

    /// Put messages that were queued when the app last ran back in the queue.
    func restoreQueue() {
        let queued = Set(messages.filter { $0.state == .queued }.map(\.id))
        var order = (record.queue ?? []).filter { queued.contains($0) }
        let known = Set(order)
        order += messages.filter { $0.state == .queued && !known.contains($0.id) }.map(\.id)
        queue = order
    }

    // MARK: Running the harness

    var canRelaunch: Bool { failedLaunches < 2 && stop == nil }

    func resetLaunchFailures() { failedLaunches = 0 }

    /// Hand the next message over, or start the harness if a message waits and it isn't
    /// running.
    func pump() {
        guard !shuttingDown else { return }
        switch phase {
        case .stopped:
            guard !queue.isEmpty, stop == nil else { return }
            guard canRelaunch else {
                // Never pending forever (MA-4): what can't reach the agent fails, with the reason.
                failQueued(.error, record.lastError ?? "\(record.kind.rawValue) couldn't start")
                changed()
                return
            }
            launch()
        case .ready:
            guard turn == nil, inFlight == nil, redirect == nil, let next = queue.first else { return }
            dispatch(next)
        default:
            return
        }
    }

    /// Whether the harness has a conversation to resume (it has taken a message before).
    var conversationExists: Bool { record.conversation == true }

    func launch() {
        guard phase == .stopped else { return }
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: record.cwd, isDirectory: &isDir), isDir.boolValue else {
            failOutstanding("the session's folder \(record.cwd) no longer exists")
            record.ended = "error"
            record.lastError = "the session's folder \(record.cwd) no longer exists"
            saveRecord()
            changed()
            return
        }
        phase = .launching
        generation += 1
        let gen = generation
        let resume = conversationExists
        let driver: TernHarnessDriver = record.kind == .claude
            ? TernClaudeDriver(session: self) : TernCodexDriver(session: self)
        self.driver = driver
        let snapshot = record
        changed()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let binary = TernAgentEnvironment.harnessBinary(snapshot.kind)
            let prepared = TernAgentEnvironment.harnessEnvironment(session: snapshot)
            TernAgents.queue.async {
                guard let self, self.generation == gen, self.phase == .launching else { return }
                guard let binary else {
                    self.launchFailed("\(snapshot.kind.rawValue) isn't installed (not found on your login shell's PATH)")
                    return
                }
                self.startFlags = prepared.flags
                do {
                    let process = try TernHarnessProcess(
                        executable: binary, arguments: driver.arguments(resume: resume), environment: prepared.env,
                        cwd: snapshot.cwd, queue: TernAgents.queue,
                        onLine: { [weak self] line in
                            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
                            TernAgents.queue.async {
                                guard let self, self.generation == gen else { return }
                                self.driver?.handle(object)
                            }
                        },
                        onEnd: { [weak self] status, stderr in
                            guard let self, self.generation == gen else { return }
                            self.processEnded(status: status, stderr: stderr)
                        })
                    self.process = process
                    self.phase = .starting
                    self.record.pid = process.pid
                    self.saveRecord()
                    driver.begin(process: process, resume: resume)
                    self.changed()
                } catch {
                    self.launchFailed("\(error)")
                }
            }
        }
    }

    private func launchFailed(_ reason: String) {
        phase = .stopped
        driver = nil
        record.ended = "error"
        record.lastError = reason
        failOutstanding(reason)
        saveRecord()
        notice("Couldn't start \(record.kind.rawValue): \(reason)")
        changed()
    }

    /// The harness answered and has its conversation open.
    func driverReady(harnessID: String?) {
        guard phase == .starting else { return }
        if let harnessID, harnessID != record.harnessID {
            record.harnessID = harnessID
        }
        phase = .ready
        everReady = true
        record.ended = nil
        saveRecord()
        queueContinuationIfNeeded()
        if !startFlags.isEmpty {
            var startup = record.startup ?? TernAgentStartup(at: Date())
            startup.recomputeFlags(extra: startFlags)
            record.startup = startup
        }
        changed()
        pump()
    }

    /// The harness couldn't open the conversation (gone, unreadable, …). Nothing is started
    /// fresh in its place (MA-24): messages waiting for it fail with the reason.
    func startFailed(_ reason: String) {
        // A start cut short by `agent stop` (or a quit) isn't a failure of the conversation.
        guard stop == nil, !shuttingDown else { return }
        record.lastError = reason
        record.ended = "error"
        failedLaunches = 99
        failOutstanding(reason)
        notice("Couldn't resume the conversation: \(reason)")
        saveRecord()
        changed()
        terminateProcess(grace: 0.5)
    }

    private func dispatch(_ id: String) {
        guard let driver, var message = message(id) else {
            queue.removeAll { $0 == id }
            return
        }
        queue.removeFirst()
        saveQueue()
        message.state = .sent
        store(message)
        inFlight = id
        changed()
        if !driver.send(message) {
            // The process is going away; its end puts the message back in the queue.
            return
        }
    }

    // MARK: Recovery

    /// Set at launch for a session whose turn was cut off (or that has messages waiting):
    /// once its harness is back, a note goes first (R-10).
    var recovering = false

    /// After a Codex resume: which unconfirmed messages the thread really received.
    func reconcileDelivery(received: Set<String>, known: Bool) {
        for m in messages where m.state == .sent && m.id != inFlight && !queue.contains(m.id) {
            if received.contains(m.id) {
                update(m.id) { $0.state = .delivered; $0.cutOff = true; $0.cutOffAt = $0.cutOffAt ?? Date() }
            } else if known {
                update(m.id) { $0.state = .queued; $0.cutOff = nil; $0.cutOffAt = nil; $0.cutOffReason = nil }
                queue.insert(m.id, at: 0)
                saveQueue()
            }
        }
    }

    /// The harness refused a message outright.
    func dispatchFailed(_ id: String, reason: String) {
        if inFlight == id { inFlight = nil }
        if let current = turn, current.messages == [id] { turn = nil }
        finish(id, .error, error: reason)
        changed()
        pump()
    }

    var turnLastFinal: String? { turn?.lastFinal }
    var turnError: String? { turn?.error }

    /// Queue the continuation note for turns cut off while the app wasn't running.
    private func queueContinuationIfNeeded() {
        guard recovering else { return }
        recovering = false
        // Claude can't say whether a message written just before the crash arrived; it was
        // written to its stdin, which it reads before anything else, so count it delivered.
        // (Codex says: its thread's history settled each one in reconcileDelivery.)
        if record.kind == .claude {
            for m in messages where m.state == .sent && m.id != inFlight && !queue.contains(m.id) {
                update(m.id) { $0.state = .delivered; $0.cutOff = true; $0.cutOffAt = $0.cutOffAt ?? Date() }
            }
        }
        let cut = messages.filter { $0.cutOff == true && !$0.state.isFinal && $0.note != true }
        guard !cut.isEmpty || record.openSelfTurn else { return }
        let at = cut.compactMap(\.cutOffAt).min() ?? record.cutOffAt ?? Date()
        let reason: String
        switch cut.first?.cutOffReason ?? record.cutOffReason ?? "crash" {
        case "quit": reason = "the \(TernPaths.productName) app quit"
        case "update": reason = "\(TernPaths.productName) was updated"
        default: reason = "the \(TernPaths.productName) app stopped unexpectedly"
        }
        let text = "[\(TernPaths.productName)] Your previous turn was cut off at \(TernAgentTime.clock(at)) because \(reason). "
            + "Everything you had running then (shell commands, background tasks and subagents) was stopped. "
            + "Check the state of your work before carrying on, then continue where you left off."
        record.openSelfTurn = false
        record.cutOffAt = nil
        record.cutOffReason = nil
        saveRecord()
        enqueue(text: text, note: true, continues: cut.map(\.id), front: true)
        notice("Continuing the turn that was cut off at \(TernAgentTime.clock(at)).")
    }

    // MARK: Driver events

    func setActivity(_ text: String) {
        guard activity != text else { return }
        activity = text
        changed()
    }

    func toolStarted(ref: String, description: String) {
        runningTools[ref] = description
        changed()
    }

    func toolEnded(ref: String) {
        if runningTools.removeValue(forKey: ref) != nil { changed() }
    }

    /// The harness confirmed the model received a message.
    func delivered(_ id: String) {
        guard let current = message(id), !current.state.isFinal, current.state != .delivered else {
            if inFlight == id { inFlight = nil }
            return
        }
        update(id) {
            $0.state = .delivered
            $0.deliveredAt = Date()
        }
        if record.conversation != true {
            record.conversation = true
            saveRecord()
        }
        failedLaunches = 0
        if inFlight == id { inFlight = nil }
        if turn == nil {
            beginTurn(id: nil, messages: [id], selfStarted: false)
        } else if turn?.messages.contains(id) == false {
            turn?.messages.append(id)
        }
        changed()
    }

    /// A turn began: for messages, or by itself (MA-28).
    func beginTurn(id: String?, messages ids: [String], selfStarted: Bool) {
        if turn != nil {
            if let id, turn?.id == nil { turn?.id = id }
            for m in ids where turn?.messages.contains(m) == false { turn?.messages.append(m) }
            return
        }
        claudeTurnCounter += 1
        turn = Turn(id: id ?? "t\(claudeTurnCounter)", messages: ids, selfStarted: selfStarted, startedAt: Date())
        // The harness has a conversation from its first turn on (Codex records the turn even if
        // the input never arrived), so later starts resume it.
        if record.conversation != true {
            record.conversation = true
            saveRecord()
        }
        activity = ""
        if selfStarted {
            record.openSelfTurn = true
            saveRecord()
            notice("The agent started a turn by itself.")
        } else if interruptWhenInFlightStarts {
            interruptWhenInFlightStarts = false
            interruptPending = false
            armRedirectInterrupt()
        } else if interruptPending {
            interruptPending = false
            turn?.interruptRequested = true
            driver?.interrupt(turnID: turn?.id)
        }
        changed()
    }

    /// Interrupt the turn now running for a redirect; restart the harness if it doesn't stop.
    private func armRedirectInterrupt() {
        guard let current = turn, live else { return }
        turn?.interruptRequested = true
        let turnStartedAt = current.startedAt
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.redirect != nil, let running = self.turn, running.startedAt == turnStartedAt else { return }
            self.notice("The turn didn't stop within 30 seconds of the interrupt; restarting the harness.")
            self.redirect = nil
            self.restartHarness()
        }
        redirect?.deadline.cancel()
        redirect = Redirect(turnID: current.id, turnStartedAt: turnStartedAt, deadline: work)
        TernAgents.queue.asyncAfter(deadline: .now() + 30, execute: work)
        driver?.interrupt(turnID: current.id)
    }

    func setTurnID(_ id: String) {
        turn?.id = id
    }

    var currentTurnID: String? { turn?.id }
    var turnIsRunning: Bool { turn != nil }

    func noteFinalText(_ text: String) {
        turn?.lastFinal = text
    }

    func noteTurnError(_ text: String) {
        turn?.error = text
    }

    enum Outcome {
        case done(String?)
        case interrupted
        case failed(String)
    }

    /// The running turn ended. `answered` lists the messages the harness says this turn
    /// answered (Claude's user_message_uuids); the session knows the rest.
    func endTurn(_ outcome: Outcome, answered: [String] = []) {
        var current = turn ?? Turn(id: nil, messages: [], selfStarted: answered.isEmpty, startedAt: Date())
        for m in answered where !current.messages.contains(m) { current.messages.append(m) }
        turn = nil
        activity = ""
        runningTools.removeAll()
        // Requests belong to the turn.
        for request in requests {
            updateItem(ref: "req:\(request.id)") { if $0.state == "pending" { $0.state = "withdrawn" } }
        }
        requests.removeAll()
        if current.selfStarted {
            if shuttingDown {
                // Cut off by the quit: it continues after the restart (R-10).
                record.cutOffAt = record.cutOffAt ?? Date()
                record.cutOffReason = record.cutOffReason ?? shutdownReason
            } else {
                record.openSelfTurn = false
            }
            saveRecord()
        }
        let reply: String?
        if case .done(let text) = outcome { reply = text } else { reply = nil }
        if let reply, !reply.isEmpty {
            if let index = items.lastIndex(where: { $0.kind == "assistant" }), items[index].text == reply {
                var item = items[index]
                item.state = "final"
                items[index] = item
                TernAgentStore.append(record.id, item: item)
            } else {
                addItem(kind: "assistant", text: reply, state: "final")
            }
        }
        var targets = current.messages
        // A note's turn answers the messages it continues.
        for m in current.messages {
            if let continues = message(m)?.continues { targets += continues }
        }
        for m in targets {
            guard let msg = message(m), !msg.state.isFinal else { continue }
            if shuttingDown {
                // Cut off by the quit: it continues after the restart (R-10). A message the
                // harness never took goes back to the queue.
                if msg.state == .delivered {
                    update(m) { $0.cutOff = true; $0.cutOffAt = Date(); $0.cutOffReason = self.shutdownReason }
                } else if msg.state == .sent {
                    update(m) { $0.state = .queued }
                    queue.insert(m, at: 0)
                    saveQueue()
                }
                continue
            }
            switch outcome {
            case .done(let text):
                finish(m, .done, reply: text)
            case .interrupted:
                finish(m, .interrupted, error: msg.state == .delivered || msg.note == true || msg.cutOff == true
                       ? nil : "interrupted before the agent received it")
            case .failed(let error):
                finish(m, .failed, error: error)
            }
        }
        if case .failed(let error) = outcome {
            addItem(kind: "error", text: error)
        } else if case .interrupted = outcome {
            notice("Turn interrupted.")
        }
        if let pending = inFlight, current.messages.contains(pending) { inFlight = nil }
        if redirect != nil {
            redirect?.deadline.cancel()
            redirect = nil
        }
        checkWatches(turnEnded: true)
        changed()
        pump()
    }

    private func finish(_ id: String, _ state: TernMessageState, reply: String? = nil, error: String? = nil) {
        update(id) {
            $0.state = state
            if let reply { $0.reply = reply }
            if let error { $0.error = error }
            $0.finishedAt = Date()
            $0.cutOff = nil
        }
        manager?.messageFinished(session: self, id)
    }

    /// The harness can't run for this session: everything still waiting on it ends with the
    /// reason, queued messages and turns cut off before a restart alike (never pending forever).
    private func failOutstanding(_ reason: String) {
        failQueued(.error, reason)
        if let inFlight { finish(inFlight, .error, error: reason) }
        inFlight = nil
        recovering = false
        for m in messages where !m.state.isFinal && (m.cutOff == true || m.state == .sent || m.state == .delivered) {
            finish(m.id, .error, error: reason)
        }
        if record.openSelfTurn {
            record.openSelfTurn = false
            record.cutOffAt = nil
            record.cutOffReason = nil
        }
    }

    /// Fail everything queued (the harness can't take messages).
    private func failQueued(_ state: TernMessageState, _ reason: String) {
        let ids = queue
        queue.removeAll()
        saveQueue()
        for id in ids { finish(id, state, error: reason) }
    }

    // MARK: Requests

    func nextRequestID() -> String {
        defer { record.nextRequest += 1 }
        return "r\(record.nextRequest)"
    }

    func openRequest(_ request: TernAgentRequest) {
        // Allowed always, earlier in this session: answer it now.
        if request.kind == "approval", let tool = request.ruleTool,
           record.alwaysRules.contains(TernAlwaysRule(tool: tool, content: request.ruleContent)),
           let driver, driver.answer(request, .allow(always: true, message: nil)) == nil {
            notice("Allowed (always for this session): \(request.title) \(request.detail)")
            return
        }
        requests.append(request)
        addItem(kind: "request", text: request.title, detail: request.detail, state: "pending", ref: "req:\(request.id)")
        saveRecord()
        checkWatches(needsInput: true)
        changed()
    }

    func closeRequest(harnessID: TernJSONValue) {
        guard let index = requests.firstIndex(where: { $0.harnessID.any as? NSObject == harnessID.any as? NSObject }) else { return }
        let request = requests.remove(at: index)
        updateItem(ref: "req:\(request.id)") { $0.state = "withdrawn" }
        changed()
    }

    func request(_ id: String?) throws -> TernAgentRequest {
        if let id, !id.isEmpty {
            guard let found = requests.first(where: { $0.id == id || $0.id == "r\(id)" }) else {
                throw TernError.notFound("no pending request \(id) (pending: \(requests.map(\.id).joined(separator: ", ")))")
            }
            return found
        }
        guard let first = requests.first else { throw TernError.notFound("\(record.name) has no pending requests") }
        return first
    }

    func respond(_ request: TernAgentRequest, _ answer: TernAgentAnswer) throws {
        guard let driver, live else { throw TernError.failed("\(record.name) isn't running") }
        if let problem = driver.answer(request, answer) { throw TernError.badRequest(problem) }
        requests.removeAll { $0.id == request.id }
        let state: String
        switch answer {
        case .allow(let always, _):
            state = always ? "allowed always" : "allowed"
            if always, let tool = request.ruleTool {
                let rule = TernAlwaysRule(tool: tool, content: request.ruleContent)
                if !record.alwaysRules.contains(rule) { record.alwaysRules.append(rule) }
                saveRecord()
            }
        case .deny: state = "denied"
        case .answers: state = "answered"
        }
        updateItem(ref: "req:\(request.id)") { $0.state = state }
        changed()
    }

    // MARK: Interrupt, redirect, stop

    /// Stop the running turn; the session stays. Returns whether a turn was running.
    @discardableResult
    func interrupt() -> Bool {
        guard live, let driver else { return false }
        if turn != nil {
            turn?.interruptRequested = true
            driver.interrupt(turnID: turn?.id)
            return true
        }
        if inFlight != nil {
            // Written but its turn not started yet: interrupt that turn as soon as it exists.
            // (Claude reads stdin in order, so an interrupt sent now lands after the message.)
            if record.kind == .claude {
                driver.interrupt(turnID: nil)
            } else {
                interruptPending = true
            }
            return true
        }
        return false
    }

    /// `agent interrupt` arrived while a message was written but its turn not yet named.
    private var interruptPending = false

    /// `agent send --interrupt`: TEXT goes first, the turn running now (if any) is
    /// interrupted, and a turn that doesn't stop within 30 s gets its harness restarted.
    func redirect(text: String, dropQueued: Bool, from: String?) -> TernAgentMessage {
        if dropQueued {
            let dropped = queue
            queue.removeAll()
            for id in dropped { finish(id, .cancelled, error: "dropped by a redirect") }
        }
        let message = enqueue(text: text, from: from, front: true)
        if turn == nil, inFlight != nil, live {
            interruptWhenInFlightStarts = true
        }
        if turn != nil, live {
            armRedirectInterrupt()
        }
        changed()
        pump()
        return message
    }

    /// Kill the harness and resume (a hung turn). The running turn's messages end
    /// interrupted; queued messages are delivered after the resume.
    private func restartHarness() {
        guard live else { return }
        stopProcess(kind: .restart, completion: nil)
    }

    /// End the session's work: its harness and everything it started. Queued messages end
    /// EXITED; messages sent while it stops are kept and resume it afterwards (MA-3).
    func stopSession(remove: Bool = false, completion: @escaping () -> Void) {
        let ids = queue
        queue.removeAll()
        saveQueue()
        for id in ids { finish(id, .exited, error: "the session was stopped before this message was delivered") }
        if let inFlight, message(inFlight)?.state == .sent {
            finish(inFlight, .exited, error: "the session was stopped before this message was delivered")
            self.inFlight = nil
        }
        stopProcess(kind: remove ? .remove : .user, completion: completion)
    }

    /// At quit: interrupt running turns (they continue after the restart) and stop.
    func beginShutdown(reason: String) {
        shuttingDown = true
        shutdownReason = reason
        if let current = turn, live {
            for m in current.messages where message(m)?.state == .delivered {
                update(m) { $0.cutOff = true; $0.cutOffAt = Date(); $0.cutOffReason = reason }
            }
            if current.selfStarted {
                record.cutOffAt = Date()
                record.cutOffReason = reason
                saveRecord()
            }
            driver?.interrupt(turnID: current.id)
        }
    }

    func shutdownProcess(completion: @escaping () -> Void) {
        stopProcess(kind: .shutdown, completion: completion)
    }

    private func stopProcess(kind: Stop.Kind, completion: (() -> Void)?) {
        if phase == .launching {
            // Still preparing to spawn: cancel that.
            generation += 1
            phase = .stopped
            driver = nil
        }
        guard let process else {
            // Nothing running; still make sure nothing of this session is left.
            let id = record.id
            DispatchQueue.global().async {
                let leftovers = TernProcessTree.sessionProcesses(session: id, stateDir: TernPaths.stateDirectory, harness: nil)
                TernProcessTree.terminate(leftovers, grace: 1.0)
                TernAgents.queue.async { completion?() }
            }
            if record.ended == nil || record.ended == "exited" { record.ended = "stopped" }
            saveRecord()
            changed()
            return
        }
        if stop != nil {
            if let completion { stop?.completions.append(completion) }
            return
        }
        stop = Stop(kind: kind, completions: completion.map { [$0] } ?? [])
        phase = .stopping
        changed()
        let gen = generation
        if turn != nil, kind != .restart {
            turn?.interruptRequested = true
            driver?.interrupt(turnID: turn?.id)
        }
        // Give an interrupt a moment to land, then close stdin (both harnesses exit), then
        // signal the process group, then kill everything that's left.
        let closeAfter: Double = (turn != nil && kind != .restart) ? 1.0 : 0.0
        TernAgents.queue.asyncAfter(deadline: .now() + closeAfter) { [weak self] in
            guard let self, self.generation == gen, self.process === process else { return }
            process.closeStdin()
        }
        TernAgents.queue.asyncAfter(deadline: .now() + closeAfter + (kind == .restart ? 0.2 : 1.0)) { [weak self] in
            guard let self, self.generation == gen, self.process === process else { return }
            self.terminateProcess(grace: 1.5)
        }
    }

    /// Signal the harness and everything it started; SIGKILL after `grace`.
    private func terminateProcess(grace: TimeInterval) {
        guard let process else { return }
        let id = record.id
        let pid = process.pid
        DispatchQueue.global().async {
            let pids = TernProcessTree.sessionProcesses(session: id, stateDir: TernPaths.stateDirectory, harness: pid)
            TernProcessTree.terminate(pids.union([pid]), grace: grace)
        }
    }

    // MARK: The process ended

    private func processEnded(status: Int32, stderr: String) {
        let stopping = stop
        let wasReady = everReady && phase != .starting
        let neverReady = phase == .starting || phase == .launching
        process = nil
        driver = nil
        inFlightCheck(stopping: stopping)
        let code = TernHarnessProcess.exitCode(status)
        let described = TernHarnessProcess.describe(status)
        let tail = TernAgentSession.lastLines(stderr)
        var reason: String?
        if stopping == nil && !shuttingDown {
            if neverReady {
                reason = record.lastError ?? "\(record.kind.rawValue) \(described) while starting" + (tail.isEmpty ? "" : ": \(tail)")
                failedLaunches += 1
            } else if code != 0 || turn != nil {
                reason = "\(record.kind.rawValue) \(described)" + (tail.isEmpty ? "" : ": \(tail)")
            }
        }
        // The turn that was running.
        if let current = turn {
            turn = nil
            runningTools.removeAll()
            activity = ""
            if current.selfStarted {
                if shuttingDown {
                    record.cutOffAt = record.cutOffAt ?? Date()
                    record.cutOffReason = record.cutOffReason ?? shutdownReason
                } else {
                    record.openSelfTurn = false
                }
            }
            var targets = current.messages
            for m in current.messages { targets += message(m)?.continues ?? [] }
            for m in targets {
                guard let msg = message(m), !msg.state.isFinal else { continue }
                if shuttingDown {
                    if msg.state == .delivered { update(m) { $0.cutOff = true; $0.cutOffAt = $0.cutOffAt ?? Date(); $0.cutOffReason = $0.cutOffReason ?? self.shutdownReason } }
                    continue
                }
                if stopping != nil {
                    finish(m, .interrupted, error: stopping?.kind == .restart
                           ? "stopped: the turn didn't stop within 30 seconds of an interrupt" : "the session was stopped")
                } else if msg.state == .delivered || msg.note == true {
                    finish(m, .error, error: reason ?? "\(record.kind.rawValue) \(described)")
                } else {
                    // Never received: deliver it again after the resume.
                    update(m) { $0.state = .queued }
                    queue.insert(m, at: 0)
                }
            }
        }
        requests.removeAll()
        backgroundTasks = nil
        // A redirect waiting on this process's turn: the turn is gone, the redirect goes next.
        redirect?.deadline.cancel()
        redirect = nil
        interruptPending = false
        if shuttingDown {
            record.ended = "stopped"
        } else if let stopping {
            record.ended = stopping.kind == .restart ? "exited" : "stopped"
            if stopping.kind == .user { record.lastError = nil }
        } else if let reason {
            record.ended = "error"
            record.lastError = reason
            if wasReady || !neverReady { notice("The harness ended unexpectedly: \(reason)") }
        } else {
            record.ended = "exited"
            notice("The harness exited.")
        }
        if neverReady && stopping == nil && !shuttingDown && failedLaunches >= 2 {
            failQueued(.error, reason ?? "\(record.kind.rawValue) couldn't start")
        }
        saveQueue()
        phase = .cleaning
        changed()
        if stopping == nil && !shuttingDown { checkWatches(exited: true) }
        // Make sure nothing the harness started is left (detached children included), then
        // resume if messages wait.
        let id = record.id
        DispatchQueue.global().async { [weak self] in
            let leftovers = TernProcessTree.sessionProcesses(session: id, stateDir: TernPaths.stateDirectory, harness: nil)
            TernProcessTree.terminate(leftovers, grace: 1.5)
            TernAgents.queue.async {
                guard let self else { return }
                self.phase = .stopped
                self.stop = nil
                self.changed()
                for completion in stopping?.completions ?? [] { completion() }
                if !self.shuttingDown && stopping?.kind != .remove { self.pump() }
            }
        }
    }

    /// A message written but not confirmed when the process ended was never delivered
    /// (every line the harness wrote has been read): it goes back to the front of the queue,
    /// unless the session was stopped.
    private func inFlightCheck(stopping: Stop?) {
        guard let id = inFlight else { return }
        inFlight = nil
        guard let msg = message(id), msg.state == .sent else { return }
        if turn?.messages.contains(id) == true { return }
        if let stopping, stopping.kind == .user || stopping.kind == .remove {
            finish(id, .exited, error: "the session was stopped before this message was delivered")
        } else {
            update(id) { $0.state = .queued }
            // Behind a redirect that was waiting for it, ahead of everything else.
            queue.insert(id, at: interruptWhenInFlightStarts ? min(1, queue.count) : 0)
        }
        interruptWhenInFlightStarts = false
    }

    static func lastLines(_ text: String, count: Int = 3) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return TernAgentText.oneLine(lines.suffix(count).joined(separator: " / "), max: 400)
    }

    // MARK: Startup report (MA-29)

    /// Codex reports its MCP servers' status asynchronously after the thread opens. Until
    /// they settle (or 5 s pass), `agent wait` holds its answer so its warning line can say
    /// what failed.
    private var startupBegan: Date?

    var startupSettling: Bool {
        guard let began = startupBegan else { return false }
        let age = Date().timeIntervalSince(began)
        if age < 1.0 { return true }
        if age < 5.0, record.startup?.mcpServers.contains(where: { $0["status"] == "starting" }) == true { return true }
        return false
    }

    func startupBegins() {
        startupBegan = Date()
        for delay in [1.05, 5.05] {
            TernAgents.queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.changed() }
        }
    }

    func updateStartup(_ change: (inout TernAgentStartup) -> Void, fresh: Bool) {
        var startup = (fresh ? nil : record.startup) ?? TernAgentStartup(at: Date())
        if fresh { startup.at = Date() }
        change(&startup)
        startup.recomputeFlags(extra: startFlags)
        record.startup = startup
        saveRecord()
        changed()
    }

    // MARK: Watches (MA-19)

    func checkWatches(turnEnded: Bool = false, needsInput: Bool = false, exited: Bool = false) {
        guard !record.watches.isEmpty else { return }
        var remaining: [TernAgentWatch] = []
        for watch in record.watches {
            var fire: String?
            if let target = watch.message {
                if let m = message(target), m.state.isFinal {
                    fire = "finished its turn: \(m.state.waitStatus)"
                }
            } else if turnEnded {
                fire = "finished its turn"
            }
            if fire == nil && needsInput { fire = "needs input: \(requests.last?.title ?? "a request")" }
            if fire == nil && exited { fire = record.ended == "error" ? "stopped with an error: \(record.lastError ?? "")" : "exited" }
            if let fire {
                manager?.deliverWatch(watch, from: self, event: fire)
            } else {
                remaining.append(watch)
            }
        }
        if remaining.count != record.watches.count {
            record.watches = remaining
            saveRecord()
        }
    }

    // MARK: Recovery after a restart

    /// Messages whose turn was running when the app last stopped (killed, quit, updated).
    func cutOffMessages() -> [TernAgentMessage] {
        messages.filter { ($0.state == .delivered || $0.state == .sent) && $0.note != true }
    }

    /// Before the queue is restored: a continuation note that never finished (cut off itself,
    /// or still queued) is replaced by a fresh one, so it must not be delivered too.
    func resetForRecovery() {
        for m in messages where m.note == true && !m.state.isFinal {
            finish(m.id, .interrupted, error: "replaced by a new continuation note")
        }
        let finished = Set(messages.filter(\.state.isFinal).map(\.id))
        if let saved = record.queue, saved.contains(where: finished.contains) {
            record.queue = saved.filter { !finished.contains($0) }
            saveRecord()
        }
    }
}

/// What the app's views show of a session.
struct TernAgentSnapshot {
    let id: String
    let name: String
    let kind: TernAgentKind
    let status: String
    let activity: String
    let cwd: String
    let live: Bool
    let items: [TernTranscriptItem]
    let requests: [TernAgentRequest]
    let queued: [String]
    let version: Int
    let error: String?
    let model: String?
}

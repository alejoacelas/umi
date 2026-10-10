import Foundation

/// What a harness driver reports to its session, and what the session asks of it.
protocol TernHarnessDriver: AnyObject {
    /// The command line (after the binary) for a fresh or a resumed conversation.
    func arguments(resume: Bool) -> [String]
    /// Talk to a freshly spawned process (initialize, open the conversation).
    func begin(process: TernHarnessProcess, resume: Bool)
    /// A line of the harness's stdout, already parsed.
    func handle(_ frame: [String: Any])
    /// Hand a message to the harness to start a turn. False if it couldn't be written.
    func send(_ message: TernAgentMessage) -> Bool
    /// Hand a message to the harness for the turn now running (steering): the agent sees it at
    /// its next step. False if it couldn't be written.
    func steer(_ message: TernAgentMessage) -> Bool
    /// Whether a message can be steered into the running turn now (Codex needs the turn's id).
    var canSteer: Bool { get }
    /// Interrupt the running turn (Codex: exactly this turn). `cancelQueued`: messages handed
    /// over for steering that the agent hasn't taken in yet are given back
    /// (`TernAgentSession.steeringCancelled`) instead of running after the interrupt.
    func interrupt(turnID: String?, cancelQueued: Bool)
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
/// Delivery rule: a message waits in the session's own queue until the harness can take it,
/// then is handed over: to start a turn when none runs, or into the running turn (steering,
/// AG-10), where the agent sees it at its next step. A message is always in exactly one place
/// (queued here, handed over and unconfirmed, delivered); the harness's own receipt says when
/// it was delivered. A redirect interrupts the running turn and takes back what was handed
/// over but not yet taken in, so its text goes first (AG-11).
///
/// Headless and live (AG-5 to AG-9): the agent's own interface can run in a pane on the same
/// conversation. Claude Code's interface owns the conversation while it runs, so the headless
/// process is stopped first and messages wait until the interface is idle, then run headless
/// and the interface comes back. Codex's interface attaches to the session's own app server,
/// so everything keeps going through it.
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
    /// Messages written to the harness whose delivery isn't confirmed yet, in order.
    private(set) var inFlight: [String] = []
    /// Messages put back in the queue because the process ended before saying it took them in,
    /// with why it ended: the thread's history (Codex) may show it did (AG-11).
    private var requeuedUnconfirmed: [String: String] = [:]

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
    /// A background task finished and the turn it wakes hasn't started yet (Claude reports the
    /// task gone before that turn's init, AG-13).
    private(set) var wakePending = false
    private var wakeGeneration = 0
    private(set) var activity: String = ""
    private var runningTools: [String: String] = [:]   // ref → description

    /// The process ended before it ever took a message: don't relaunch forever.
    private var failedLaunches = 0
    private var everReady = false
    private var startFlags: [String] = []

    /// `agent stop` (or shutdown) in progress.
    struct Stop {
        let kind: Kind
        enum Kind { case user, shutdown, restart, remove, handoff }
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

    // MARK: Live state (TernAgentLive.swift)

    enum LiveState: String { case starting, idle, working, needsInput }
    /// Set while the agent's own interface runs in a pane (from its hooks; nil otherwise).
    var liveState: LiveState?
    /// The user typed into the live interface since their last prompt: a message waiting for
    /// the session doesn't take it back from them (AG-9).
    var liveDraft = false
    var lastLiveKey: Date?
    /// Background work the live interface reported at its last Stop.
    var liveBackground = 0
    var liveActivity = ""
    /// Ending the live interface to deliver waiting messages headless (then going back live).
    var reclaiming = false
    /// Asked to show the agent's own interface in its pane (the attach command is on its way).
    var goingLive = false
    /// Removed from its pane while live: end the interface once the session settles (AG-8).
    var endLiveWhenSettled = false
    /// The last time a hook reported anything (an interrupt in the interface fires none).
    var lastHookAt: Date?
    /// Waiters for the headless process to stop (taking the session over).
    var stoppedHandlers: [() -> Void] = []
    /// When a turn last ended (or it last asked for input): the sidebar orders tabs by it.
    var lastStopAt: Date?
    var driverForLive: TernHarnessDriver? { driver }
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

    /// The headless harness process is running.
    var live: Bool { process != nil }

    /// Background work of its own that will wake the agent (Claude Code's background tasks,
    /// monitors, subagents): a session with some pending hasn't finished (AG-13). Codex never
    /// starts a turn by itself (X15wake), so its background terminals don't count.
    var pendingBackground: Int {
        record.kind == .claude ? (backgroundTasks ?? 0) : 0
    }

    var status: String {
        if let state = liveState, exclusiveLive {
            switch state {
            case .starting: return "starting"
            case .working: return "working"
            case .needsInput: return "needs_input"
            case .idle:
                if !queue.isEmpty { return liveDraft ? "needs_input" : "working" }
                return liveBackground > 0 ? "working" : "idle"
            }
        }
        if live, !requests.isEmpty { return "needs_input" }
        if let state = liveState, state == .needsInput { return "needs_input" }
        switch phase {
        case .launching, .starting:
            return "starting"
        case .ready:
            return (turn != nil || !inFlight.isEmpty || !queue.isEmpty || pendingBackground > 0 || wakePending)
                ? "working" : "idle"
        case .stopping:
            if turn != nil { return "working" }
            return stop?.kind == .handoff || stop?.kind == .restart ? "idle" : "stopped"
        case .stopped, .cleaning:
            if !queue.isEmpty && canRelaunch { return "starting" }
            if goingLive { return "starting" }
            return restingStatus
        }
    }

    /// No process and nothing to do: `stopped` only when someone stopped it; a session whose
    /// interface closed or whose agent exited by itself is idle (a message resumes it).
    private var restingStatus: String {
        switch record.ended {
        case "error": return "error"
        case "stopped": return "stopped"
        default: return "idle"
        }
    }

    var activityText: String {
        if let state = liveState, exclusiveLive {
            switch state {
            case .starting: return "opening its own interface"
            case .needsInput: return liveActivity.isEmpty ? "waiting for you in its interface" : liveActivity
            case .working: return liveActivity.isEmpty ? "working" : liveActivity
            case .idle:
                if !queue.isEmpty {
                    return liveDraft
                        ? "\(queue.count) message(s) wait until you send or clear what you typed in its interface"
                        : "taking it back to deliver \(queue.count) message(s)"
                }
                if liveBackground > 0 { return "waiting for \(liveBackground) background task(s)" }
                return "idle"
            }
        }
        if live, let request = requests.first { return "waiting: \(request.title)" }
        switch phase {
        case .launching, .starting: return everReady || record.conversation == true ? "resuming" : "starting"
        case .stopping: return "stopping"
        case .stopped, .cleaning:
            if !queue.isEmpty && canRelaunch { return "resuming" }
            if goingLive { return "opening its own interface" }
            if record.ended == "error" { return record.lastError.map { TernAgentText.oneLine($0, max: 120) } ?? "error" }
            return restingStatus
        case .ready:
            if turn == nil && inFlight.isEmpty && queue.isEmpty {
                if pendingBackground > 0 { return "waiting for \(pendingBackground) background task(s)" }
                return wakePending ? "a background task finished; it wakes the agent" : "idle"
            }
            if let tool = runningTools.values.first { return tool }
            if !activity.isEmpty { return activity }
            return turn?.selfStarted == true ? "working (on its own)" : "working"
        }
    }

    /// Nothing runs, nothing waits, and no background work will wake it: the session is done
    /// for now (what `agent wait` and "finished" mean, AG-12).
    var settled: Bool {
        if exclusiveLive { return liveState == .idle && queue.isEmpty && liveBackground == 0 }
        return turn == nil && inFlight.isEmpty && queue.isEmpty && pendingBackground == 0 && !wakePending
            && phase != .launching && phase != .starting && !goingLive
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
                          version: version, error: record.lastError, model: record.startup?.model ?? record.model,
                          location: location, pane: record.pane, title: record.title ?? record.name,
                          lastStopAt: lastStopAt)
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
        if exclusiveLive {
            // The agent's own interface owns the conversation now: waiting messages are
            // delivered by taking it back when it's idle (AG-9).
            considerReclaim()
            return
        }
        if goingLive { return }
        switch phase {
        case .stopped:
            // Messages wait, or a turn cut off before a restart waits to continue.
            guard !queue.isEmpty || recovering, stop == nil else { return }
            guard canRelaunch else {
                // Never pending forever (MA-4): what can't reach the agent fails, with the reason.
                failOutstanding(record.lastError ?? "\(record.kind.rawValue) couldn't start")
                changed()
                return
            }
            launch()
        case .ready:
            guard redirect == nil else { return }
            if turn == nil {
                guard inFlight.isEmpty, let next = queue.first else { return }
                dispatch(next, steer: false)
            } else if turn?.interruptRequested != true, driver?.canSteer == true {
                // The agent sees these during the turn it's running (AG-10). A product note
                // (a cut-off turn's continuation) only ever starts a turn.
                while let next = queue.first, message(next)?.note != true {
                    if !dispatch(next, steer: true) { break }
                }
            }
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
            // Tests hold a launch here to reach this moment (isolated instances only).
            if TernPaths.isIsolated, let raw = ProcessInfo.processInfo.environment["TERN_TEST_LAUNCH_DELAY"],
               let delay = Double(raw), delay > 0 {
                Thread.sleep(forTimeInterval: min(delay, 30))
            }
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
        // A session asked to go live with nothing to run first (`tern codex` with no task).
        checkSettled()
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

    @discardableResult
    private func dispatch(_ id: String, steer: Bool) -> Bool {
        guard let driver, var message = message(id) else {
            queue.removeAll { $0 == id }
            return false
        }
        queue.removeFirst()
        redirectFront.remove(id)
        saveQueue()
        message.state = .sent
        store(message)
        inFlight.append(id)
        changed()
        // A failed write means the process is going away; its end puts the message back.
        return steer ? driver.steer(message) : driver.send(message)
    }

    /// The harness gave back messages it had queued for steering but not taken in (an
    /// interrupt that cancels what's queued, for a redirect): they go back to the queue, after
    /// the redirect's text and in their order.
    func steeringCancelled(_ ids: [String]) {
        var back: [String] = []
        for id in ids where inFlight.contains(id) {
            guard let m = message(id), m.state == .sent else { continue }
            inFlight.removeAll { $0 == id }
            update(id) { $0.state = .queued }
            back.append(id)
        }
        guard !back.isEmpty else { return }
        let at = queue.firstIndex { message($0)?.note != true && !redirectFront.contains($0) } ?? queue.count
        queue.insert(contentsOf: back, at: at)
        saveQueue()
        changed()
    }

    // MARK: Recovery

    /// Set at launch for a session whose turn was cut off (or that has messages waiting):
    /// once its harness is back, a note goes first (R-10).
    var recovering = false

    /// After a Codex resume: which unconfirmed messages the thread really received.
    func reconcileDelivery(received: Set<String>, known: Bool) {
        // Put back in the queue when the process ended, but the thread has it: it was delivered
        // and ended with that process. Sending it again would repeat it (and what it caused).
        for id in queue where received.contains(id) {
            guard let why = requeuedUnconfirmed[id] else { continue }
            queue.removeAll { $0 == id }
            finish(id, .error, error: why.isEmpty ? "the agent ended after it received this message" : why)
        }
        requeuedUnconfirmed = requeuedUnconfirmed.filter { queue.contains($0.key) }
        saveQueue()
        for m in messages where m.state == .sent && !inFlight.contains(m.id) && !queue.contains(m.id) {
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
        inFlight.removeAll { $0 == id }
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
            for m in messages where m.state == .sent && !inFlight.contains(m.id) && !queue.contains(m.id) {
                if let delivered = claudeTranscriptHas(m.id), !delivered {
                    // The conversation's own record says it never arrived: send it again.
                    update(m.id) { $0.state = .queued; $0.cutOff = nil; $0.cutOffAt = nil; $0.cutOffReason = nil }
                    queue.insert(m.id, at: 0)
                    saveQueue()
                    continue
                }
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
        // openSelfTurn stays set until the note's turn ends: a quit or crash during the
        // continuation must continue it again.
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
            inFlight.removeAll { $0 == id }
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
        inFlight.removeAll { $0 == id }
        if turn == nil {
            beginTurn(id: nil, messages: [id], selfStarted: false)
        } else if turn?.messages.contains(id) == false {
            turn?.messages.append(id)
        }
        changed()
    }

    /// A turn began: for messages, or by itself (MA-28).
    func beginTurn(id: String?, messages ids: [String], selfStarted: Bool, fromInterface: Bool = false) {
        if turn != nil {
            if let id, turn?.id == nil { turn?.id = id }
            for m in ids where turn?.messages.contains(m) == false { turn?.messages.append(m) }
            return
        }
        claudeTurnCounter += 1
        turn = Turn(id: id ?? "t\(claudeTurnCounter)", messages: ids, selfStarted: selfStarted, startedAt: Date())
        wakePending = false
        // The harness has a conversation from its first turn on (Codex records the turn even if
        // the input never arrived), so later starts resume it.
        if record.conversation != true {
            record.conversation = true
            saveRecord()
        }
        activity = ""
        if fromInterface {
            // The user started it in the agent's own interface: theirs to finish.
        } else if selfStarted {
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
            driver?.interrupt(turnID: turn?.id, cancelQueued: false)
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
        // What was handed over for steering and not taken in comes back, to go after the
        // redirect's text.
        driver?.interrupt(turnID: current.id, cancelQueued: true)
    }

    func setTurnID(_ id: String) {
        turn?.id = id
    }

    var currentTurnID: String? { turn?.id }
    var turnIsRunning: Bool { turn != nil }

    /// A background task finished: the agent starts a turn for it (unless the running turn takes
    /// it in). Until then the session isn't settled; if no turn comes, a few quiet seconds end it.
    func backgroundTaskFinished() {
        wakePending = true
        wakeGeneration += 1
        armWakeTimeout(wakeGeneration)
        changed()
    }

    private func armWakeTimeout(_ generation: Int) {
        TernAgents.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.wakePending, self.wakeGeneration == generation else { return }
            if self.turnIsRunning || !self.inFlight.isEmpty {
                self.armWakeTimeout(generation)
                return
            }
            self.wakePending = false
            self.changed()
            self.checkSettled()
        }
    }

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
        lastStopAt = Date()
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
        let continuedSelfTurn = current.messages.contains { message($0)?.note == true }
        if current.selfStarted || continuedSelfTurn {
            if shuttingDown {
                // Cut off by the quit: it continues after the restart (R-10).
                record.cutOffAt = record.cutOffAt ?? Date()
                record.cutOffReason = record.cutOffReason ?? shutdownReason
            } else if current.selfStarted || record.openSelfTurn {
                // The self-started turn (or the note that continued it) is over.
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
        inFlight.removeAll { current.messages.contains($0) }
        if redirect != nil {
            redirect?.deadline.cancel()
            redirect = nil
        }
        checkWatches(turnEnded: true)
        changed()
        pump()
        checkSettled()
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
        for id in inFlight { finish(id, .error, error: reason) }
        inFlight.removeAll()
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
        lastStopAt = Date()
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

    /// Stop the running turn; the session stays. Messages handed over for steering and not yet
    /// taken in still reach the agent afterwards. Returns whether a turn was running.
    @discardableResult
    func interrupt() -> Bool {
        if exclusiveLive {
            // The agent's own interface runs this turn: interrupting it there is the user's
            // (Esc in the interface). Tern can't reach into it.
            return false
        }
        guard live, let driver else { return false }
        if turn != nil {
            turn?.interruptRequested = true
            driver.interrupt(turnID: turn?.id, cancelQueued: false)
            return true
        }
        if !inFlight.isEmpty {
            // Written but its turn not started yet: interrupt that turn as soon as it exists.
            // (Claude reads stdin in order, so an interrupt sent now lands after the message.)
            if record.kind == .claude {
                driver.interrupt(turnID: nil, cancelQueued: false)
            } else {
                interruptPending = true
            }
            return true
        }
        return false
    }

    /// Redirect texts at the front of the queue (they go before messages a cancel gives back).
    private var redirectFront: Set<String> = []

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
        redirectFront.insert(message.id)
        if turn == nil, !inFlight.isEmpty, live {
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
        // A turn cut off before a restart and not continued yet won't be: it was stopped.
        if recovering || record.openSelfTurn {
            recovering = false
            for m in messages where !m.state.isFinal && m.cutOff == true {
                finish(m.id, .exited, error: "the session was stopped before its cut-off turn continued")
            }
            record.openSelfTurn = false
            record.cutOffAt = nil
            record.cutOffReason = nil
            saveRecord()
        }
        for id in inFlight where message(id)?.state == .sent {
            finish(id, .exited, error: "the session was stopped before this message was delivered")
        }
        inFlight.removeAll()
        record.goLiveWhenSettled = nil
        if record.live == true {
            // Its own interface closes too (AG-15).
            endLiveInterface(reason: "stop")
        }
        stopProcess(kind: remove ? .remove : .user, completion: completion)
    }

    /// At quit: interrupt running turns (they continue after the restart) and stop.
    func beginShutdown(reason: String) {
        shuttingDown = true
        shutdownReason = reason
        if phase == .launching {
            // Still preparing to spawn: don't start now.
            generation += 1
            phase = .stopped
            driver = nil
        }
        if let current = turn, live {
            for m in current.messages where message(m)?.state == .delivered {
                update(m) { $0.cutOff = true; $0.cutOffAt = Date(); $0.cutOffReason = reason }
            }
            if current.selfStarted {
                record.cutOffAt = Date()
                record.cutOffReason = reason
                saveRecord()
            }
            driver?.interrupt(turnID: current.id, cancelQueued: true)
        }
    }

    func shutdownProcess(completion: @escaping () -> Void) {
        stopProcess(kind: .shutdown, completion: completion)
    }

    func stopProcess(kind: Stop.Kind, completion: (() -> Void)?) {
        if phase == .launching {
            // Still preparing to spawn: cancel that.
            generation += 1
            phase = .stopped
            driver = nil
        }
        guard let process else {
            // Nothing running; still make sure nothing of this session is left.
            let id = record.id
            let lastPID = record.pid
            DispatchQueue.global().async {
                let leftovers = TernProcessTree.sessionProcesses(session: id, stateDir: TernPaths.stateDirectory, harness: nil,
                                                                 exitedHarness: lastPID)
                TernProcessTree.terminate(leftovers, grace: 1.0)
                TernAgents.queue.async { [weak self] in
                    completion?()
                    // Whoever waits for the process to be gone (a handoff to the live interface
                    // that came during a launch, now cancelled) goes on.
                    guard let self, self.process == nil else { return }
                    let handlers = self.stoppedHandlers
                    self.stoppedHandlers.removeAll()
                    for handler in handlers { handler() }
                }
            }
            if kind != .handoff && (record.ended == nil || record.ended == "exited") { record.ended = "stopped" }
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
            driver?.interrupt(turnID: turn?.id, cancelQueued: true)
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
        let endedPID = process?.pid
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
        let endedWhy = reason ?? "\(record.kind.rawValue) \(described)"
        for (id, why) in requeuedUnconfirmed where why.isEmpty { requeuedUnconfirmed[id] = endedWhy }
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
                    let why: String
                    switch stopping?.kind {
                    case .restart: why = "stopped: the turn didn't stop within 30 seconds of an interrupt"
                    case .handoff: why = "interrupted: the session was taken over in its own interface"
                    default: why = "the session was stopped"
                    }
                    finish(m, .interrupted, error: why)
                } else if msg.state == .delivered || msg.note == true {
                    finish(m, .error, error: reason ?? "\(record.kind.rawValue) \(described)")
                } else {
                    // Never confirmed: deliver it again after the resume, unless the resume
                    // shows it arrived after all.
                    update(m) { $0.state = .queued }
                    queue.insert(m, at: 0)
                    requeuedUnconfirmed[m] = ""
                }
            }
        }
        requests.removeAll()
        backgroundTasks = nil
        wakePending = false
        // Tools this process was running (background commands included) ended with it.
        for item in items where item.kind == "tool" && item.state == "running" {
            if let ref = item.ref { updateItem(ref: ref) { $0.state = "stopped" } }
        }
        // A redirect waiting on this process's turn: the turn is gone, the redirect goes next.
        redirect?.deadline.cancel()
        redirect = nil
        interruptPending = false
        if shuttingDown {
            record.ended = "stopped"
        } else if let stopping {
            record.ended = stopping.kind == .restart ? "exited" : (stopping.kind == .handoff ? nil : "stopped")
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
            failOutstanding(reason ?? "\(record.kind.rawValue) couldn't start")
        }
        saveQueue()
        phase = .cleaning
        changed()
        if stopping == nil && !shuttingDown { checkWatches(exited: true) }
        // Make sure nothing the harness started is left (detached children included), then
        // resume if messages wait.
        let id = record.id
        DispatchQueue.global().async { [weak self] in
            let leftovers = TernProcessTree.sessionProcesses(session: id, stateDir: TernPaths.stateDirectory, harness: nil,
                                                             exitedHarness: endedPID)
            TernProcessTree.terminate(leftovers, grace: 1.5)
            TernAgents.queue.async {
                guard let self else { return }
                self.phase = .stopped
                self.stop = nil
                self.changed()
                for completion in stopping?.completions ?? [] { completion() }
                let handlers = self.stoppedHandlers
                self.stoppedHandlers.removeAll()
                for handler in handlers { handler() }
                if !self.shuttingDown && stopping?.kind != .remove && stopping?.kind != .handoff { self.pump() }
                self.checkSettled()
            }
        }
    }

    /// A message written but not confirmed when the process ended was never delivered
    /// (every line the harness wrote has been read): it goes back to the front of the queue,
    /// unless the session was stopped.
    private func inFlightCheck(stopping: Stop?) {
        let ids = inFlight
        inFlight.removeAll()
        var back: [String] = []
        for id in ids {
            guard let msg = message(id), msg.state == .sent else { continue }
            if turn?.messages.contains(id) == true { continue }
            if let stopping, stopping.kind == .user || stopping.kind == .remove {
                finish(id, .exited, error: "the session was stopped before this message was delivered")
            } else {
                update(id) { $0.state = .queued }
                back.append(id)
                if stopping == nil { requeuedUnconfirmed[id] = "" }
            }
        }
        // Behind a redirect that was waiting for them, ahead of everything else.
        if !back.isEmpty {
            queue.insert(contentsOf: back, at: interruptWhenInFlightStarts ? min(1, queue.count) : 0)
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
    /// background, pane (read-only view) or live.
    let location: String
    let pane: String?
    let title: String
    let lastStopAt: Date?
}

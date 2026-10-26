import Foundation

/// The managed sessions of this instance: which exist, finding them by selector, starting,
/// removing, recovering them at launch and stopping them at quit.
///
/// Sessions belong to the app process: their harnesses are its children and stop when it
/// quits (the user's choice, SPEC "Not requirements"). What makes that safe is resumption:
/// everything a session needs is on disk, a message to a stopped session resumes it, and a
/// turn cut off by a quit, crash or update continues by itself at the next launch (R-10).
///
/// All state lives on one serial queue. RPC handlers hop onto it and back; harness output is
/// parsed on reader threads and handled here in order; the UI gets snapshots on the main
/// thread. Nothing on this queue ever waits for the main thread.
final class UmiAgents: @unchecked Sendable {
    static let shared = UmiAgents()
    static let queue = DispatchQueue(label: "dev.umi.agents", qos: .userInitiated)

    private(set) var sessions: [UmiAgentSession] = []
    private var byID: [String: UmiAgentSession] = [:]
    private var bootstrapped = false

    // MARK: Launch

    /// Load sessions, stop whatever an earlier run of this instance left behind, and resume
    /// the sessions whose turn was cut off or that have messages waiting. Runs before any
    /// agent request is handled (requests queue up behind it).
    func bootstrap() {
        UmiAgentEnvironment.warm()
        Self.queue.async { [self] in
            guard !bootstrapped else { return }
            bootstrapped = true
            let loaded = UmiAgentStore.loadAll()
            for entry in loaded {
                let session = UmiAgentSession(record: entry.record)
                session.manager = self
                if session.record.live == true {
                    // Its interface ended with the app: it comes back live in its pane once the
                    // pane is restored (AG-7), headless until then.
                    session.record.live = nil
                    session.record.livePID = nil
                    session.record.liveAttached = nil
                    if session.record.pane != nil { session.record.goLiveWhenSettled = true }
                    session.saveRecord()
                }
                session.adopt(messages: entry.messages, items: entry.items)
                session.resetForRecovery()
                session.restoreQueue()
                sessions.append(session)
                byID[entry.record.id] = session
            }
            // Processes of sessions from an earlier run (the app was killed or crashed):
            // nothing started before keeps running (R-1).
            var leftovers = Set(UmiProcessTree.tagged(sessions: nil, stateDir: UmiPaths.stateDirectory).map(\.pid))
            let infos = UmiProcessTree.all()
            for session in sessions {
                if let pid = session.record.pid { leftovers.formUnion(UmiProcessTree.orphanedGroup(pid, in: infos)) }
            }
            if !leftovers.isEmpty {
                UmiProcessTree.terminate(leftovers, grace: 1.0)
            }
            for session in sessions {
                let cut = session.cutOffMessages()
                let logTime = (try? FileManager.default.attributesOfItem(
                    atPath: (UmiAgentStore.folder(session.record.id) as NSString).appendingPathComponent("log.jsonl"))[.modificationDate]
                    as? Date) ?? Date()
                for message in cut where message.cutOff != true {
                    session.markCutOff(message.id, at: logTime, reason: "crash")
                }
                if session.record.openSelfTurn, session.record.cutOffAt == nil {
                    session.record.cutOffAt = logTime
                    session.record.cutOffReason = session.record.cutOffReason ?? "crash"
                    session.saveRecord()
                }
                let hasCut = session.messages.contains { $0.cutOff == true && !$0.state.isFinal } || session.record.openSelfTurn
                if hasCut || !session.queue.isEmpty {
                    session.recovering = true
                    session.launch()
                }
            }
            watchLiveInterfaces()
        }
    }

    /// A live interface that died without saying so (killed, crashed): the session is headless
    /// again (AG-7). Checked every few seconds.
    private func watchLiveInterfaces() {
        Self.queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            for session in sessions where session.record.live == true {
                guard let pid = session.record.livePID else { continue }
                if kill(pid, 0) != 0 && errno == ESRCH { session.liveEnded() }
            }
            watchLiveInterfaces()
        }
    }

    // MARK: Running requests on the queue

    func runQuietly<T>(_ body: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Self.queue.async { continuation.resume(returning: body()) }
        }
    }

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Sessions

    func add(_ session: UmiAgentSession) {
        session.manager = self
        sessions.append(session)
        byID[session.record.id] = session
    }

    func remove(_ session: UmiAgentSession) {
        sessions.removeAll { $0 === session }
        byID.removeValue(forKey: session.record.id)
        UmiAgentStore.remove(session.record.id)
        session.changed()   // waiters on it end with "removed"
        let id = session.record.id
        DispatchQueue.main.async { MainActor.assumeIsolated { UmiAgentUI.sessionRemoved(id) } }
    }

    func session(id: String) -> UmiAgentSession? { byID[id] }

    /// SESSION: an id or unique id prefix, a name, the harness's session or thread id, or
    /// `self` (inside a managed agent).
    func resolve(_ selector: String?, caller: UmiCaller) throws -> UmiAgentSession {
        guard let selector, !selector.isEmpty else { throw UmiError.badRequest("name a session (its name or id, or self; `\(UmiPaths.cliName) agent ls` lists them)") }
        if selector == "self" {
            guard let id = caller.session else {
                throw UmiError.badRequest("`self` only works inside a managed agent session")
            }
            guard let session = byID[id] else { throw UmiError.notFound("this agent's session (\(id.prefix(8))) no longer exists") }
            return session
        }
        let lowered = selector.lowercased()
        if let exact = byID[lowered] { return exact }
        if let harness = sessions.first(where: { $0.record.harnessID?.lowercased() == lowered }) { return harness }
        let named = sessions.filter { $0.record.name == selector }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            let live = named.filter(\.live)
            if live.count == 1 { return live[0] }
            throw UmiError.ambiguous("\(named.count) sessions are named \"\(selector)\"; use an id")
        }
        if lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let prefixed = sessions.filter { $0.record.id.hasPrefix(lowered) || ($0.record.harnessID?.lowercased().hasPrefix(lowered) ?? false) }
            if prefixed.count == 1 { return prefixed[0] }
            if prefixed.count > 1 { throw UmiError.ambiguous("\"\(selector)\" matches \(prefixed.count) sessions; use more of the id") }
        }
        throw UmiError.notFound("no session matches \"\(selector)\" (`\(UmiPaths.cliName) agent ls` lists them)")
    }

    /// Names are unique among sessions that are live (or about to be): a finished session
    /// gives its name up (it's renamed with its id) when a new one takes it (MA-11).
    func claim(name: String, for session: UmiAgentSession?) throws {
        for other in sessions where other !== session && other.record.name == name {
            if other.live || other.record.live == true || other.status == "starting" || other.status == "working" {
                throw UmiError.badRequest("a running session (\(other.record.id.prefix(8))) is already named \"\(name)\"")
            }
        }
        for other in sessions where other !== session && other.record.name == name {
            other.record.name = "\(name)~\(other.record.id.prefix(6))"
            other.saveRecord()
            other.changed()
        }
    }

    // MARK: Messages finishing, watches

    func messageFinished(session: UmiAgentSession, _ id: String) {
        guard let message = session.message(id) else { return }
        let payload: [String: Any] = ["session": session.record.id, "name": session.record.name, "message": id,
                                      "status": message.state.waitStatus]
        DispatchQueue.main.async {
            MainActor.assumeIsolated { UmiEvents.shared.emit("agent.message.finished", payload) }
        }
    }

    /// `agent watch`: tell the supervising session, as a follow-up message.
    func deliverWatch(_ watch: UmiAgentWatch, from session: UmiAgentSession, event: String) {
        guard let target = byID[watch.notify] else { return }
        let cli = UmiPaths.cliName
        var text = "[\(UmiPaths.productName)] Session \"\(session.record.name)\" (\(session.record.id.prefix(8))) \(event)."
        if let message = watch.message.flatMap({ session.message($0) }) ?? session.lastMessage, let reply = message.reply, !reply.isEmpty {
            text += "\nIts reply begins: \(UmiAgentText.oneLine(reply, max: 300))"
        }
        if let report = session.record.report {
            text += "\nIts latest report: \(report.verdict): \(UmiAgentText.oneLine(report.summary, max: 200))"
        }
        text += "\nRead it with `\(cli) agent read \(session.record.name)`."
        if let extra = watch.text, !extra.isEmpty { text += "\n\(extra)" }
        target.enqueue(text: text, from: session.record.id)
        target.pump()
    }

    // MARK: Quit

    /// At quit (⌘Q, a quit event, SIGTERM, an update): interrupt running turns cleanly, so
    /// they continue after the next launch, then stop every harness and everything it
    /// started. Blocks the calling thread for at most ~8 s.
    func shutdown(reason: String) {
        var anyLive = false
        Self.queue.sync {
            // Every session: one that is launching or cleaning up must not start a harness now.
            for session in sessions {
                if session.live { anyLive = true }
                session.beginShutdown(reason: reason)
            }
        }
        // Let interrupted turns end (their results record where they stopped).
        let deadline = Date().addingTimeInterval(anyLive ? 3 : 0)
        while Date() < deadline {
            let running = Self.queue.sync { sessions.contains { $0.turnIsRunning && $0.live } }
            if !running { break }
            usleep(50_000)
        }
        let group = DispatchGroup()
        Self.queue.sync {
            for session in sessions where session.live {
                group.enter()
                session.shutdownProcess { group.leave() }
            }
        }
        _ = group.wait(timeout: .now() + 5)
        // Whatever is still tagged with this instance goes now, live harness or not (a detached
        // child of one that already exited may still be on its way out).
        let leftovers = UmiProcessTree.tagged(sessions: nil, stateDir: UmiPaths.stateDirectory)
        UmiProcessTree.killNow(Set(leftovers.map(\.pid)))
    }

    /// Turns running now (an update asks before cutting them off).
    /// Turns an update now would cut off: headless ones, and work in a Claude interface Umi
    /// shows live (it closes with the app).
    func runningTurns() -> Int {
        Self.queue.sync {
            sessions.filter { ($0.turnIsRunning && $0.live) || ($0.exclusiveLive && $0.liveState == .working) }.count
        }
    }
}

extension UmiAgentSession {
    func markCutOff(_ id: String, at: Date, reason: String) {
        guard let current = message(id) else { return }
        var updated = current
        if updated.state == .sent && record.kind == .claude {
            // Written to Claude, never confirmed: its transcript says whether it arrived. If not,
            // it's sent again; if the transcript can't be read, it counts as delivered (Claude
            // reads its input before anything else).
            if claudeTranscriptHas(id) == false {
                requeueNeverDelivered(id)
                return
            }
            updated.state = .delivered
        }
        updated.cutOff = true
        updated.cutOffAt = updated.cutOffAt ?? at
        updated.cutOffReason = updated.cutOffReason ?? reason
        replaceMessage(updated)
    }
}

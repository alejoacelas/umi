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
final class TernAgents: @unchecked Sendable {
    static let shared = TernAgents()
    static let queue = DispatchQueue(label: "dev.tern.agents", qos: .userInitiated)

    private(set) var sessions: [TernAgentSession] = []
    private var byID: [String: TernAgentSession] = [:]
    private var bootstrapped = false

    // MARK: Launch

    /// Load sessions, stop whatever an earlier run of this instance left behind, and resume
    /// the sessions whose turn was cut off or that have messages waiting. Runs before any
    /// agent request is handled (requests queue up behind it).
    func bootstrap() {
        TernAgentEnvironment.warm()
        Self.queue.async { [self] in
            guard !bootstrapped else { return }
            bootstrapped = true
            let loaded = TernAgentStore.loadAll()
            for entry in loaded {
                let session = TernAgentSession(record: entry.record)
                session.manager = self
                session.adopt(messages: entry.messages, items: entry.items)
                session.restoreQueue()
                sessions.append(session)
                byID[entry.record.id] = session
            }
            // Processes of sessions from an earlier run (the app was killed or crashed):
            // nothing started before keeps running (R-1).
            let leftovers = TernProcessTree.tagged(sessions: nil, stateDir: TernPaths.stateDirectory)
            if !leftovers.isEmpty {
                TernProcessTree.terminate(Set(leftovers.map(\.pid)), grace: 1.0)
            }
            for session in sessions {
                session.resetForRecovery()
                let cut = session.cutOffMessages()
                let logTime = (try? FileManager.default.attributesOfItem(
                    atPath: (TernAgentStore.folder(session.record.id) as NSString).appendingPathComponent("log.jsonl"))[.modificationDate]
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
        }
    }

    // MARK: Running requests on the queue

    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            Self.queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Sessions

    func add(_ session: TernAgentSession) {
        session.manager = self
        sessions.append(session)
        byID[session.record.id] = session
    }

    func remove(_ session: TernAgentSession) {
        sessions.removeAll { $0 === session }
        byID.removeValue(forKey: session.record.id)
        TernAgentStore.remove(session.record.id)
        let id = session.record.id
        DispatchQueue.main.async { MainActor.assumeIsolated { TernAgentUI.sessionRemoved(id) } }
    }

    func session(id: String) -> TernAgentSession? { byID[id] }

    /// SESSION: an id or unique id prefix, a name, the harness's session or thread id, or
    /// `self` (inside a managed agent).
    func resolve(_ selector: String?, caller: TernCaller) throws -> TernAgentSession {
        guard let selector, !selector.isEmpty else { throw TernError.badRequest("name a session (an id, a name, or self)") }
        if selector == "self" {
            guard let id = caller.session else {
                throw TernError.badRequest("`self` only works inside a managed agent session")
            }
            guard let session = byID[id] else { throw TernError.notFound("this agent's session (\(id.prefix(8))) no longer exists") }
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
            throw TernError.ambiguous("\(named.count) sessions are named \"\(selector)\"; use an id")
        }
        if lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
            let prefixed = sessions.filter { $0.record.id.hasPrefix(lowered) || ($0.record.harnessID?.lowercased().hasPrefix(lowered) ?? false) }
            if prefixed.count == 1 { return prefixed[0] }
            if prefixed.count > 1 { throw TernError.ambiguous("\"\(selector)\" matches \(prefixed.count) sessions; use more of the id") }
        }
        throw TernError.notFound("no session matches \"\(selector)\"")
    }

    /// Names are unique among sessions that are live (or about to be): a finished session
    /// gives its name up (it's renamed with its id) when a new one takes it (MA-11).
    func claim(name: String, for session: TernAgentSession?) throws {
        for other in sessions where other !== session && other.record.name == name {
            if other.live || other.status == "starting" || other.status == "working" {
                throw TernError.badRequest("a running session (\(other.record.id.prefix(8))) is already named \"\(name)\"")
            }
        }
        for other in sessions where other !== session && other.record.name == name {
            other.record.name = "\(name)~\(other.record.id.prefix(6))"
            other.saveRecord()
            other.changed()
        }
    }

    // MARK: Messages finishing, watches

    func messageFinished(session: TernAgentSession, _ id: String) {
        guard let message = session.message(id) else { return }
        let payload: [String: Any] = ["session": session.record.id, "name": session.record.name, "message": id,
                                      "status": message.state.waitStatus]
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TernEvents.shared.emit("agent.message.finished", payload) }
        }
    }

    /// `agent watch`: tell the supervising session, as a follow-up message.
    func deliverWatch(_ watch: TernAgentWatch, from session: TernAgentSession, event: String) {
        guard let target = byID[watch.notify] else { return }
        let cli = TernPaths.cliName
        var text = "[\(TernPaths.productName)] Session \"\(session.record.name)\" (\(session.record.id.prefix(8))) \(event)."
        if let message = watch.message.flatMap({ session.message($0) }) ?? session.lastMessage, let reply = message.reply, !reply.isEmpty {
            text += "\nIts reply begins: \(TernAgentText.oneLine(reply, max: 300))"
        }
        if let report = session.record.report {
            text += "\nIts latest report: \(report.verdict): \(TernAgentText.oneLine(report.summary, max: 200))"
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
            for session in sessions where session.live {
                anyLive = true
                session.beginShutdown(reason: reason)
            }
        }
        guard anyLive else { return }
        // Let interrupted turns end (their results record where they stopped).
        let deadline = Date().addingTimeInterval(3)
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
        // Whatever is still tagged with this instance goes now.
        let leftovers = TernProcessTree.tagged(sessions: nil, stateDir: TernPaths.stateDirectory)
        TernProcessTree.killNow(Set(leftovers.map(\.pid)))
    }

    /// Turns running now (an update asks before cutting them off).
    func runningTurns() -> Int {
        Self.queue.sync { sessions.filter { $0.turnIsRunning && $0.live }.count }
    }
}

extension TernAgentSession {
    func markCutOff(_ id: String, at: Date, reason: String) {
        guard let current = message(id) else { return }
        var updated = current
        if updated.state == .sent && record.kind == .claude { updated.state = .delivered }
        updated.cutOff = true
        updated.cutOffAt = updated.cutOffAt ?? at
        updated.cutOffReason = updated.cutOffReason ?? reason
        replaceMessage(updated)
    }
}

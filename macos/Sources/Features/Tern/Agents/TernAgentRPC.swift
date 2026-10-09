import Foundation

/// The control socket's `agent.*` methods (CLI.md, "Managed").
@MainActor
enum TernAgentRPC {
    static let agents = TernAgents.shared

    static func handle(method: String, params: TernParams, caller: TernCaller,
                       connection: TernConnection? = nil) async throws -> [String: Any] {
        switch method {
        case "agent.start": return try await start(params, caller: caller)
        case "agent.send": return try await send(params, caller: caller)
        case "agent.wait": return try await wait(params, caller: caller, connection: connection)
        case "agent.report": return try await report(params, caller: caller)
        case "agent.read": return try await read(params, caller: caller)
        case "agent.ls":
            let liveOnly = params.bool("live") ?? false
            let panes = TernAgentUI.panesBySession()
            return try await agents.run {
                // --parent S: only the sessions S started (an orchestrator's workers).
                let parent = try params.string("parent").map { try agents.resolve($0, caller: caller).record.id }
                return ["sessions": agents.sessions
                    .filter { (!liveOnly || $0.live) && (parent == nil || $0.record.parent == parent) }
                    .map { info($0, pane: panes[$0.record.id]) }]
            }
        case "agent.info":
            let panes = TernAgentUI.panesBySession()
            return try await agents.run {
                let session = try agents.resolve(params.string("session"), caller: caller)
                return info(session, pane: panes[session.record.id])
            }
        case "agent.interrupt":
            return try await agents.run {
                let session = try agents.resolve(params.string("session"), caller: caller)
                let hit = session.interrupt()
                return ["session": session.record.id, "interrupted": hit]
            }
        case "agent.stop":
            return try await stop(params, caller: caller)
        case "agent.resume":
            return try await resume(params, caller: caller)
        case "agent.approve", "agent.deny", "agent.answer":
            return try await answer(method, params, caller: caller)
        case "agent.watch":
            return try await watch(params, caller: caller)
        case "agent.open":
            return try await open(params, caller: caller)
        case "agent.rename":
            return try await agents.run {
                let session = try agents.resolve(params.string("session"), caller: caller)
                guard let name = params.string("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                    throw TernError.badRequest("give the new name")
                }
                if name == "self" { throw TernError.badRequest("\"self\" can't be a session name") }
                try agents.claim(name: name, for: session)
                session.record.name = name
                session.saveRecord()
                session.changed()
                return ["session": session.record.id, "name": name]
            }
        case "agent.rm":
            return try await remove(params, caller: caller)
        default:
            throw TernError.badRequest("unknown method \(method)")
        }
    }

    // MARK: start

    static func start(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        guard let kindName = params.string("kind"), let kind = TernAgentKind(rawValue: kindName) else {
            throw TernError.badRequest("unknown agent kind \"\(params.string("kind") ?? "")\" (use claude or codex)")
        }
        guard let cwd = params.string("cwd"), !cwd.isEmpty else { throw TernError.badRequest("no folder given") }
        var isDir = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            throw TernError.badRequest("no such folder: \(cwd)")
        }
        if params.has("profile"), kind == .claude {
            throw TernError.badRequest("--profile is a Codex option (Claude has no profiles)")
        }
        let env = (params.raw["env"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        let harnessArgs = params.strings("harness_args") ?? []
        let prompt = params.string("prompt").flatMap { $0.isEmpty ? nil : $0 }
        let placement = try Placement(params, caller: caller)
        // A placement that names a pane or window that doesn't exist fails before anything starts.
        if let placement {
            if let pane = placement.pane { _ = try TernTopology.resolvePane(pane, caller: caller) }
            if let window = placement.window { _ = try TernTopology.resolveWindow(window, caller: caller) }
            if placement.kind == .split { _ = try TernLayout.direction(placement.direction) }
        }
        let result: (TernAgentSession, TernAgentMessage?) = try await agents.run {
            let id = UUID().uuidString.lowercased()
            let name = params.string("name").flatMap { $0.isEmpty ? nil : $0 } ?? "\(kind.rawValue)-\(id.prefix(6))"
            if name == "self" { throw TernError.badRequest("\"self\" can't be a session name") }
            try agents.claim(name: name, for: nil)
            var parent: String?
            if let callerSession = caller.session, agents.session(id: callerSession) != nil { parent = callerSession }
            let record = TernSessionRecord(
                id: id, name: name, kind: kind, cwd: TernPaths.canonical(cwd), model: params.string("model"),
                effort: params.string("effort"), permissionMode: params.string("permission_mode"),
                fullAccess: params.bool("full_access") ?? false, profile: params.string("profile"),
                env: env, harnessArgs: harnessArgs,
                harnessID: kind == .claude ? UUID().uuidString.lowercased() : nil,
                parent: parent, createdAt: Date())
            let session = TernAgentSession(record: record)
            session.saveRecord()
            agents.add(session)
            session.notice("Started \(kind.rawValue) in \(record.cwd).")
            var message: TernAgentMessage?
            if let prompt { message = session.enqueue(text: prompt, from: parent) }
            session.launch()
            return (session, message)
        }
        let session = result.0
        var pane: String?
        var paneError: String?
        if let placement {
            do {
                pane = try TernAgentUI.open(session.record.id, placement: placement, caller: caller)
            } catch {
                paneError = (error as? TernError)?.message ?? "\(error)"
            }
        }
        TernEvents.shared.emit("agent.started", ["session": session.record.id, "name": session.record.name,
                                                 "kind": kind.rawValue])
        return try await agents.run {
            var out: [String: Any] = ["session": info(session, pane: pane)]
            if let message = result.1 { out["message"] = messageJSON(message) }
            if let pane { out["pane"] = pane }
            if let paneError { out["pane_error"] = "the session started, but couldn't be shown: \(paneError)" }
            return out
        }
    }

    // MARK: send

    static func send(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        guard let text = params.string("text"), !text.isEmpty else { throw TernError.badRequest("nothing to send") }
        return try await agents.run {
            let session = try agents.resolve(params.string("session"), caller: caller)
            var isDir = ObjCBool(false)
            if !session.live, !(FileManager.default.fileExists(atPath: session.record.cwd, isDirectory: &isDir) && isDir.boolValue) {
                throw TernError.failed("can't resume \(session.record.name): its folder \(session.record.cwd) no longer exists")
            }
            let from = caller.session.flatMap { agents.session(id: $0) != nil ? $0 : nil }
            let message: TernAgentMessage
            if params.bool("interrupt") ?? false {
                message = session.redirect(text: text, dropQueued: params.bool("drop_queued") ?? false, from: from)
            } else {
                if params.bool("drop_queued") ?? false { throw TernError.badRequest("--drop-queued goes with --interrupt") }
                message = session.enqueue(text: text, from: from)
                session.pump()
            }
            return ["message": messageJSON(message), "session": info(session, pane: nil)]
        }
    }

    // MARK: wait

    static func wait(_ params: TernParams, caller: TernCaller, connection: TernConnection? = nil) async throws -> [String: Any] {
        let timeout = params.double("timeout")
        let forReport = params.bool("report") ?? false
        let messageID = params.string("message")
        // Resolve, evaluate and register in one step on the agent queue, so no change can fall
        // between the first look and the waiter.
        return try await withCheckedThrowingContinuation { continuation in
            TernAgents.queue.async {
                let session: TernAgentSession
                do {
                    session = try agents.resolve(params.string("session"), caller: caller)
                    if let messageID, session.message(messageID) == nil {
                        throw TernError.notFound("\(session.record.name) has no message \(messageID)")
                    }
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                // The latest message is fixed now: a follow-up someone sends meanwhile doesn't
                // change what this wait is for.
                let target = messageID ?? session.lastMessage?.id
                func evaluate() -> [String: Any]? {
                    if agents.session(id: session.record.id) == nil {
                        return ["status": "ERROR", "error": "the session was removed", "session": info(session, pane: nil)]
                    }
                    return forReport ? reportResult(session, target) : waitResult(session, target)
                }
                if let now = evaluate() {
                    continuation.resume(returning: now)
                    return
                }
                if let timeout, timeout <= 0 {
                    continuation.resume(returning: timeoutResult(session, report: forReport, target: target))
                    return
                }
                var finished = false
                var waiterID: UUID?
                var timer: DispatchWorkItem?
                var watchdog: DispatchSourceTimer?
                func complete(_ value: [String: Any]) {
                    guard !finished else { return }
                    finished = true
                    if let waiterID { session.removeWaiter(waiterID) }
                    timer?.cancel()
                    watchdog?.cancel()
                    continuation.resume(returning: value)
                }
                waiterID = session.addWaiter {
                    guard let result = evaluate() else { return false }
                    complete(result)
                    return true
                }
                if let timeout {
                    let work = DispatchWorkItem { complete(timeoutResult(session, report: forReport, target: target)) }
                    timer = work
                    TernAgents.queue.asyncAfter(deadline: .now() + timeout, execute: work)
                }
                // A client that went away (Ctrl-C, a killed script) doesn't leave its wait behind.
                if let connection {
                    let source = DispatchSource.makeTimerSource(queue: TernAgents.queue)
                    source.schedule(deadline: .now() + 2, repeating: 2)
                    source.setEventHandler {
                        if connection.isClosed { complete(timeoutResult(session, report: forReport, target: target)) }
                    }
                    watchdog = source
                    source.resume()
                }
            }
        }
    }

    /// The answer to `agent wait`, or nil to keep waiting.
    nonisolated static func waitResult(_ session: TernAgentSession, _ messageID: String?) -> [String: Any]? {
        let target = messageID.flatMap { session.message($0) } ?? session.lastMessage
        var out: [String: Any] = ["session": info(session, pane: nil)]
        if let warning = startupWarning(session) { out["warning"] = warning }
        guard let message = target else {
            // Nothing was ever sent: the current state, at once.
            let status: String
            switch session.status {
            case "exited": status = "EXITED"
            case "error": status = "ERROR"
            case "needs_input": status = "NEEDS_INPUT"
            default: status = "DONE"
            }
            out["status"] = status
            if status == "NEEDS_INPUT" { out["requests"] = session.requests.map(\.json) }
            if status == "ERROR", let error = session.record.lastError { out["error"] = error }
            return out
        }
        out["message"] = messageJSON(message)
        if message.state.isFinal {
            if session.startupSettling { return nil }
            out["status"] = message.state.waitStatus
            if let reply = message.reply { out["reply"] = reply }
            if let error = message.error { out["error"] = error }
            return out
        }
        if session.live, !session.requests.isEmpty {
            out["status"] = "NEEDS_INPUT"
            out["requests"] = session.requests.map(\.json)
            return out
        }
        return nil
    }

    nonisolated static func reportResult(_ session: TernAgentSession, _ messageID: String?) -> [String: Any]? {
        let target = messageID.flatMap { session.message($0) } ?? session.lastMessage
        let after = target?.order ?? 0
        guard let report = session.record.report, report.order > after else { return nil }
        return ["report": report.json, "status": report.verdict.uppercased(), "session": info(session, pane: nil)]
    }

    nonisolated static func timeoutResult(_ session: TernAgentSession, report: Bool, target: String?) -> [String: Any] {
        var out: [String: Any] = ["status": "TIMEOUT", "session": info(session, pane: nil)]
        if !report, let message = target.flatMap({ session.message($0) }) { out["message"] = messageJSON(message) }
        return out
    }

    /// One line about what the harness reported as failed or needing the user (MA-29).
    nonisolated static func startupWarning(_ session: TernAgentSession) -> String? {
        guard let flags = session.record.startup?.flags, !flags.isEmpty else { return nil }
        return "\(session.record.name): " + flags.joined(separator: "; ")
            + " (see `\(TernPaths.cliName) agent info \(session.record.name)`)"
    }

    // MARK: report

    static func report(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        guard let verdict = params.string("verdict"), ["done", "blocked", "failed"].contains(verdict) else {
            throw TernError.badRequest("the verdict is done, blocked or failed")
        }
        let summary = params.string("summary") ?? ""
        return try await agents.run {
            let selector = params.string("session") ?? (caller.session != nil ? "self" : nil)
            guard let selector else {
                throw TernError.badRequest("`agent report` runs inside a managed session (or pass --session S)")
            }
            let session = try agents.resolve(selector, caller: caller)
            let report = TernAgentReport(verdict: verdict, summary: summary, at: Date(), order: session.record.nextOrder)
            session.record.nextOrder += 1
            session.record.report = report
            session.saveRecord()
            session.notice("Report: \(verdict)\(summary.isEmpty ? "" : ": \(summary)")")
            session.changed()
            let payload: [String: Any] = ["session": session.record.id, "name": session.record.name, "verdict": verdict,
                                          "summary": summary]
            DispatchQueue.main.async { MainActor.assumeIsolated { TernEvents.shared.emit("agent.report", payload) } }
            return ["report": report.json, "session": session.record.id]
        }
    }

    // MARK: read

    static func read(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        try await agents.run {
            let session = try agents.resolve(params.string("session"), caller: caller)
            if params.bool("transcript") ?? false {
                var items = session.items
                if let last = params.int("last") {
                    guard last >= 0 else { throw TernError.badRequest("--last must be 0 or more") }
                    items = Array(items.suffix(last))
                }
                return ["items": items.map(\.json), "session": session.record.id]
            }
            if let id = params.string("message") {
                guard let message = session.message(id) else {
                    throw TernError.notFound("\(session.record.name) has no message \(id)")
                }
                return ["reply": message.reply ?? "", "message": messageJSON(message), "status": message.state.waitStatus]
            }
            var out: [String: Any] = ["reply": session.lastReply ?? ""]
            if let message = session.lastMessage { out["message"] = messageJSON(message) }
            return out
        }
    }

    // MARK: stop, rm, resume

    static func stop(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        let session = try await agents.run { try agents.resolve(params.string("session"), caller: caller) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TernAgents.queue.async { session.stopSession { continuation.resume() } }
        }
        return try await agents.run { ["session": info(session, pane: nil), "stopped": true] }
    }

    static func remove(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        let force = params.bool("force") ?? false
        let session = try await agents.run { () -> TernAgentSession in
            let session = try agents.resolve(params.string("session"), caller: caller)
            if session.live && !force {
                throw TernError.badRequest("\(session.record.name) is running; stop it first or pass --force")
            }
            return session
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            TernAgents.queue.async { session.stopSession(remove: true) { continuation.resume() } }
        }
        let id = try await agents.run { () -> String in
            agents.remove(session)
            return session.record.id
        }
        TernEvents.shared.emit("agent.removed", ["session": id])
        return ["session": id, "removed": true]
    }

    static func resume(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        try await agents.run {
            let session = try agents.resolve(params.string("session"), caller: caller)
            var out: [String: Any] = [:]
            if let prompt = params.string("prompt"), !prompt.isEmpty {
                let message = session.enqueue(text: prompt, from: caller.session)
                out["message"] = messageJSON(message)
            }
            if !session.live && session.phase == .stopped {
                session.clearLaunchFailures()
                session.launch()
            } else {
                session.pump()
            }
            out["session"] = info(session, pane: nil)
            return out
        }
    }

    // MARK: approvals and questions

    static func answer(_ method: String, _ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        try await agents.run {
            let session = try agents.resolve(params.string("session"), caller: caller)
            let request = try session.request(params.string("request"))
            let answer: TernAgentAnswer
            switch method {
            case "agent.approve":
                answer = .allow(always: params.bool("always") ?? false, message: params.string("message"))
            case "agent.deny":
                answer = .deny(message: params.string("message"))
            default:
                var given: [String: String] = [:]
                for (key, value) in params.raw["answers"] as? [String: Any] ?? [:] {
                    guard let text = value as? String else { continue }
                    if let n = Int(key), n >= 1, n <= request.questions.count {
                        given[request.questions[n - 1].id] = text
                    } else if request.questions.contains(where: { $0.id == key }) {
                        given[key] = text
                    } else if let match = request.questions.first(where: { $0.question == key }) {
                        given[match.id] = text
                    } else {
                        throw TernError.badRequest("no question \"\(key)\" (questions: \(request.questions.enumerated().map { "\($0.offset + 1)=\($0.element.id)" }.joined(separator: ", ")))")
                    }
                }
                if let text = params.string("text"), !text.isEmpty {
                    let unanswered = request.questions.filter { given[$0.id] == nil }
                    guard unanswered.count == 1 else {
                        if request.questions.count > 1 {
                            throw TernError.badRequest("this request has \(request.questions.count) questions; answer each with --answer N=TEXT (one answer is never copied to several questions)")
                        }
                        throw TernError.badRequest("nothing left to answer")
                    }
                    given[unanswered[0].id] = text
                }
                let missing = request.questions.enumerated().filter { given[$0.element.id] == nil }
                if !missing.isEmpty {
                    let names = missing.map { "\($0.offset + 1) (\($0.element.question))" }.joined(separator: ", ")
                    throw TernError.badRequest("no answer for question \(names); use --answer N=TEXT")
                }
                answer = .answers(given)
            }
            try session.respond(request, answer)
            return ["session": session.record.id, "request": request.id]
        }
    }

    // MARK: watch

    static func watch(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        try await agents.run {
            let session = try agents.resolve(params.string("session"), caller: caller)
            guard let other = params.string("notify") else { throw TernError.badRequest("give --notify OTHER") }
            let target = try agents.resolve(other, caller: caller)
            if target === session { throw TernError.badRequest("a session can't watch itself") }
            let messageID = params.string("message") ?? session.lastMessage?.id
            if let messageID, session.message(messageID) == nil {
                throw TernError.notFound("\(session.record.name) has no message \(messageID)")
            }
            let watch = TernAgentWatch(id: "w\(session.record.nextWatch)", notify: target.record.id, message: messageID,
                                       text: params.string("text"), createdAt: Date())
            session.record.nextWatch += 1
            session.record.watches.append(watch)
            session.saveRecord()
            // Already finished (or nothing pending): say so now rather than never.
            if let messageID, let message = session.message(messageID), message.state.isFinal {
                session.checkWatches()
            } else if messageID == nil, session.status == "idle" || session.status == "exited" || session.status == "error" {
                session.checkWatches(turnEnded: true)
            } else if session.live, !session.requests.isEmpty {
                session.checkWatches(needsInput: true)
            }
            return ["session": session.record.id, "notify": target.record.id, "watch": watch.id]
        }
    }

    // MARK: open

    static func open(_ params: TernParams, caller: TernCaller) async throws -> [String: Any] {
        let session = try await agents.run { try agents.resolve(params.string("session"), caller: caller) }
        let placement = try Placement(params, caller: caller) ?? Placement(kind: .tab, focus: params.bool("focus") ?? false)
        let pane = try TernAgentUI.open(session.record.id, placement: placement, caller: caller)
        return try await agents.run { ["session": info(session, pane: pane), "pane": pane] }
    }

    // MARK: JSON

    nonisolated static func messageJSON(_ message: TernAgentMessage) -> [String: Any] {
        var out: [String: Any] = ["id": message.id, "text": message.text, "status": message.state.waitStatus,
                                  "state": message.state.rawValue, "at": TernAgentTime.iso(message.createdAt)]
        if let reply = message.reply { out["reply"] = reply }
        if let error = message.error { out["error"] = error }
        if let from = message.from { out["from"] = from }
        return out
    }

    nonisolated static func info(_ session: TernAgentSession, pane: String?) -> [String: Any] {
        let record = session.record
        var out: [String: Any] = [
            "id": record.id, "name": record.name, "kind": record.kind.rawValue, "status": session.status,
            "activity": session.activityText, "cwd": record.cwd, "live": session.live,
            "requests": session.requests.map(\.json), "full_access": record.fullAccess,
            "created_at": TernAgentTime.iso(record.createdAt), "queued": session.queue.count,
        ]
        if let harness = record.harnessID, record.kind == .codex || record.conversation == true || session.live {
            out["harness_id"] = harness
        }
        if let parent = record.parent { out["parent"] = parent }
        if let message = session.lastMessage { out["last_message"] = messageJSON(message) }
        if session.status == "error", let error = record.lastError { out["error"] = error }
        if let report = record.report { out["report"] = report.json }
        if let tasks = session.backgroundTasks { out["background_tasks"] = tasks }
        if let startup = record.startup { out["startup"] = startup.json }
        if let model = record.model { out["model"] = model }
        if let effort = record.effort { out["effort"] = effort }
        if let mode = record.permissionMode { out["permission_mode"] = mode }
        if let pane { out["pane"] = pane }
        return out
    }

    // MARK: Placement

    struct Placement {
        enum Kind { case tab, split, window }
        var kind: Kind
        var focus: Bool
        var window: String?
        var pane: String?
        var direction: String?

        init(kind: Kind, focus: Bool) {
            self.kind = kind
            self.focus = focus
        }

        /// nil: `--background`, or no placement at all (`agent start`'s default, AP-3).
        init?(_ params: TernParams, caller: TernCaller) throws {
            if params.bool("background") ?? false { return nil }
            if !params.has("placement") && !params.has("window") && !params.has("pane") && !(params.bool("focus") ?? false) {
                return nil
            }
            focus = params.bool("focus") ?? false
            switch params.string("placement") ?? "tab" {
            case "split": kind = .split
            case "window": kind = .window
            default: kind = .tab
            }
            window = params.string("window")
            pane = params.string("pane")
            direction = params.string("direction")
        }
    }
}

extension TernAgentSession {
    func clearLaunchFailures() {
        resetLaunchFailures()
    }
}

import Foundation

/// Codex through its app server, one private server per session:
///
///     codex app-server --listen unix://SOCKET [-c model_reasoning_effort=E] [-c profile=P] [harness arguments]
///
/// A private server (never the user's shared daemon) that loads the user's config.toml,
/// AGENTS.md, skills and MCP servers like `codex` does. One per session, because a thread can
/// be live in only one server at a time (PROTOCOLS X5) and each session has its own
/// environment. It listens on a Unix socket (WebSocket frames), so Codex's own interface can
/// attach to the same server and thread (`codex resume THREAD --remote unix://SOCKET`, AG-6):
/// the user sees and drives the session live while Tern keeps driving it too.
///
/// Turn tracking: `turn/start` carries our message id as `clientUserMessageId`; its answer
/// names the turn; the `userMessage` item with that client id is the delivery receipt; the
/// turn ends with `turn/completed` (completed, interrupted or failed). Interrupts name the
/// turn, so they can never hit another one.
final class TernCodexDriver: TernHarnessDriver {
    private unowned let session: TernAgentSession
    private weak var process: TernHarnessProcess?
    private var nextID = 1
    private var pending: [Int: (Any?, String?) -> Void] = [:]
    private var threadID: String?
    private var ready = false
    /// A turn/start whose answer hasn't come back: message id.
    private var startingMessage: String?
    private var commandOutput: [String: String] = [:]
    /// Command items still running after their turn ended (background terminals).
    private var openCommands: Set<String> = []
    /// Command items this process started and hasn't finished.
    private var runningCommands: Set<String> = []
    private var mcp: [String: [String: String]] = [:]
    private var mcpOrder: [String] = []
    private var socket: TernUnixWebSocket?
    /// The server's socket (short: Unix socket paths are limited to 104 bytes).
    let socketPath: String
    /// Messages handed over with `turn/steer` whose `userMessage` hasn't come back yet.
    private var steered: [String] = []

    init(session: TernAgentSession) {
        self.session = session
        socketPath = TernPaths.userTempDirectory + "tern-cx-\(session.record.id.prefix(12)).sock"
    }

    var canSteer: Bool { ready && startingMessage == nil && session.currentTurnID != nil }

    func arguments(resume: Bool) -> [String] {
        let record = session.record
        unlink(socketPath)
        var args = ["app-server", "--listen", "unix://\(socketPath)"]
        if let effort = record.effort { args += ["-c", "model_reasoning_effort=\(effort)"] }
        if let profile = record.profile { args += ["-c", "profile=\(profile)"] }
        args += record.harnessArgs
        return args
    }

    func begin(process: TernHarnessProcess, resume: Bool) {
        self.process = process
        let path = socketPath
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak process] in
            do {
                let ws = try TernUnixWebSocket(path: path, timeout: 30, onMessage: { [weak self] data in
                    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                    process?.trace("out", data)
                    TernAgents.queue.async {
                        guard let self, self.process === process, process != nil else { return }
                        self.handleMessage(object)
                    }
                }, onClose: { [weak self] in
                    TernAgents.queue.async {
                        // The server went away (or closed the connection): the process's end
                        // says why; make sure it ends.
                        guard let self, let process, self.process === process else { return }
                        self.socket = nil
                        kill(process.pid, SIGTERM)
                    }
                })
                TernAgents.queue.async {
                    guard let self, let process, self.process === process else {
                        ws.close()
                        return
                    }
                    self.socket = ws
                    self.initialize(resume: resume)
                }
            } catch {
                TernAgents.queue.async {
                    guard let self, let process, self.process === process else { return }
                    self.session.startFailed("Codex's server didn't open its socket: \(error)")
                }
            }
        }
        TernAgents.queue.asyncAfter(deadline: .now() + 90) { [weak self, weak process] in
            guard let self, let process, !self.ready, self.process === process else { return }
            self.session.startFailed("Codex didn't answer within 90 seconds of starting")
        }
    }

    deinit {
        socket?.close()
        unlink(socketPath)
    }

    /// One JSON-RPC message to the server.
    @discardableResult
    private func write(_ object: [String: Any]) -> Bool {
        guard let socket, let data = try? JSONSerialization.data(withJSONObject: TernJSON.sanitize(object)) else { return false }
        process?.trace("in", data)
        return socket.send(data)
    }

    private func initialize(resume: Bool) {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        request("initialize", ["clientInfo": ["name": "tern", "title": TernPaths.productName, "version": version],
                               "capabilities": ["experimentalApi": true]]) { [weak self] _, error in
            guard let self else { return }
            if let error {
                self.session.startFailed("Codex refused to start: \(error)")
                return
            }
            self.write(["method": "initialized"])
            self.openThread(resume: resume)
        }
    }

    private func threadParams() -> [String: Any] {
        let record = session.record
        var params: [String: Any] = ["cwd": record.cwd,
                                     "developerInstructions": TernAgentEnvironment.awarenessNote(session: record)]
        if let model = record.model { params["model"] = model }
        if record.fullAccess {
            params["approvalPolicy"] = "never"
            params["sandbox"] = "danger-full-access"
        } else if let mode = record.permissionMode {
            params["approvalPolicy"] = mode
        }
        return params
    }

    private func openThread(resume: Bool) {
        if resume, let thread = session.record.harnessID {
            var params = threadParams()
            params["threadId"] = thread
            request("thread/resume", params) { [weak self] result, error in
                guard let self else { return }
                if let error {
                    self.session.startFailed(error.contains("no rollout found")
                        ? "Codex no longer has this conversation (\(error))" : "Codex couldn't resume the conversation: \(error)")
                    return
                }
                let response = result as? [String: Any] ?? [:]
                self.threadID = thread
                let (received, known) = self.readThread(response)
                self.confirmDelivery(thread: thread, summary: received, known: known) {
                    self.ready = true
                    self.session.driverReady(harnessID: thread)
                }
            }
        } else {
            request("thread/start", threadParams()) { [weak self] result, error in
                guard let self else { return }
                guard error == nil, let response = result as? [String: Any],
                      let thread = (response["thread"] as? [String: Any])?["id"] as? String else {
                    self.session.startFailed("Codex couldn't start a conversation: \(error ?? "no thread id")")
                    return
                }
                self.threadID = thread
                _ = self.readThread(response)
                self.ready = true
                self.session.driverReady(harnessID: thread)
            }
        }
    }

    /// Which of our unconfirmed messages the thread really has. The resumed thread's turns are
    /// summaries (each turn's first message only), so a message steered into a turn is looked up
    /// in the thread's items, newest first, page by page until each is found or the history ends;
    /// an older Codex without `thread/items/list` leaves the summary.
    private func confirmDelivery(thread: String, summary: Set<String>, known: Bool, then done: @escaping () -> Void) {
        let wanted = session.unconfirmedMessageIDs.subtracting(summary)
        guard !wanted.isEmpty else {
            session.reconcileDelivery(received: summary, known: known)
            done()
            return
        }
        var received = summary
        func page(_ cursor: String?, _ count: Int) {
            var params: [String: Any] = ["threadId": thread, "sortDirection": "desc", "limit": 500]
            if let cursor { params["cursor"] = cursor }
            request("thread/items/list", params) { [weak self] result, error in
                guard let self else { return }
                guard error == nil, let response = result as? [String: Any],
                      let data = response["data"] as? [[String: Any]] else {
                    // Not answered: what the summary shows is all that's known.
                    self.session.reconcileDelivery(received: received, known: known)
                    done()
                    return
                }
                for entry in data {
                    guard let item = entry["item"] as? [String: Any], item["type"] as? String == "userMessage",
                          let client = item["clientId"] as? String else { continue }
                    received.insert(client)
                }
                if wanted.isSubset(of: received) || count >= 100 {
                    self.session.reconcileDelivery(received: received, known: true)
                    done()
                } else if let next = response["nextCursor"] as? String, !next.isEmpty {
                    page(next, count + 1)
                } else {
                    // The whole history was read: what isn't there never arrived.
                    self.session.reconcileDelivery(received: received, known: true)
                    done()
                }
            }
        }
        page(nil, 0)
    }

    /// The thread's model, and (after a resume) which of our messages its turns' summaries show:
    /// a message written just before a crash may or may not have reached it.
    private func readThread(_ response: [String: Any]) -> (received: Set<String>, known: Bool) {
        let model = response["model"] as? String
        session.updateStartup({ startup in
            if let model { startup.model = model }
            startup.mcpServers = []
        }, fresh: true)
        mcp.removeAll()
        mcpOrder.removeAll()
        session.startupBegins()
        // The thread's turns (a fresh thread has none) say which messages it really received.
        let turnList = (response["thread"] as? [String: Any])?["turns"] as? [[String: Any]]
        var received = Set<String>()
        for turn in turnList ?? [] {
            for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "userMessage" {
                if let client = item["clientId"] as? String { received.insert(client) }
            }
        }
        return (received, turnList != nil)
    }

    func send(_ message: TernAgentMessage) -> Bool {
        guard socket != nil, let thread = threadID else { return false }
        startingMessage = message.id
        let id = nextID
        nextID += 1
        pending[id] = { [weak self] result, error in
            guard let self else { return }
            self.startingMessage = nil
            if let error {
                self.session.dispatchFailed(message.id, reason: "Codex refused the message: \(error)")
                return
            }
            if let turn = (result as? [String: Any])?["turn"] as? [String: Any], let turnID = turn["id"] as? String {
                self.session.beginTurn(id: turnID, messages: [message.id], selfStarted: false)
            }
        }
        return write(["id": id, "method": "turn/start", "params": [
            "threadId": thread, "clientUserMessageId": message.id,
            "input": [["type": "text", "text": message.text, "text_elements": [Any]()]],
        ]])
    }

    /// Into the running turn (X4: `turn/steer` names the turn; with no turn running any more it
    /// starts one instead).
    func steer(_ message: TernAgentMessage) -> Bool {
        guard socket != nil, let thread = threadID, let turn = session.currentTurnID else { return send(message) }
        steered.append(message.id)
        steerTo(turn, message: message, thread: thread, retried: false)
        return true
    }

    private func steerTo(_ turn: String, message: TernAgentMessage, thread: String, retried: Bool) {
        request("turn/steer", ["threadId": thread, "expectedTurnId": turn, "clientUserMessageId": message.id,
                               "input": [["type": "text", "text": message.text, "text_elements": [Any]()]]]) { [weak self] _, error in
            guard let self, let error else { return }
            if error.contains("no active turn") {
                self.steered.removeAll { $0 == message.id }
                if !self.send(message) { self.session.dispatchFailed(message.id, reason: "couldn't write to Codex") }
            } else if !retried, let range = error.range(of: "but found `"), let end = error[range.upperBound...].firstIndex(of: "`") {
                self.steerTo(String(error[range.upperBound..<end]), message: message, thread: thread, retried: true)
            } else {
                self.steered.removeAll { $0 == message.id }
                self.session.dispatchFailed(message.id, reason: "Codex refused the message: \(error)")
            }
        }
    }

    func interrupt(turnID: String?, cancelQueued: Bool) {
        guard let thread = threadID else { return }
        if let turnID = session.currentTurnID ?? turnID {
            request("turn/interrupt", ["threadId": thread, "turnId": turnID]) { _, _ in }
        }
    }

    // MARK: JSON-RPC

    private func request(_ method: String, _ params: [String: Any], _ done: @escaping (Any?, String?) -> Void) {
        guard socket != nil else {
            done(nil, "the harness isn't running")
            return
        }
        let id = nextID
        nextID += 1
        pending[id] = done
        if !write(["id": id, "method": method, "params": params]) {
            pending.removeValue(forKey: id)
            done(nil, "couldn't write to the harness")
        }
    }

    /// The server's stdout carries nothing of the protocol in socket mode.
    func handle(_ frame: [String: Any]) {}

    private func handleMessage(_ frame: [String: Any]) {
        if let method = frame["method"] as? String {
            if frame["id"] != nil {
                handleServerRequest(method, id: frame["id"]!, params: frame["params"] as? [String: Any] ?? [:])
            } else {
                handleNotification(method, frame["params"] as? [String: Any] ?? [:])
            }
            return
        }
        guard let id = (frame["id"] as? NSNumber)?.intValue, let done = pending.removeValue(forKey: id) else { return }
        if let error = frame["error"] as? [String: Any] {
            done(nil, error["message"] as? String ?? "error")
        } else {
            done(frame["result"], nil)
        }
    }

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String else { return }
            if session.currentTurnID == id { return }
            if let starting = startingMessage {
                session.beginTurn(id: id, messages: [starting], selfStarted: false)
            } else if !session.turnIsRunning {
                // Nothing of ours was starting: the user started it in Codex's own interface
                // (attached to this server), or Codex started it by itself.
                session.beginTurn(id: id, messages: [], selfStarted: true, fromInterface: session.record.live == true)
            }
        case "item/started":
            guard let item = params["item"] as? [String: Any] else { return }
            itemStarted(item)
        case "item/completed":
            guard let item = params["item"] as? [String: Any] else { return }
            itemCompleted(item)
        case "item/commandExecution/outputDelta":
            guard let ref = params["itemId"] as? String, let delta = params["delta"] as? String else { return }
            var output = commandOutput[ref, default: ""]
            if output.utf8.count < 64 * 1024 { output += delta }
            commandOutput[ref] = output
        case "item/agentMessage/delta":
            session.setActivity("replying")
        case "item/reasoning/summaryTextDelta", "item/reasoning/textDelta":
            session.setActivity("thinking")
        case "turn/completed":
            guard let turn = params["turn"] as? [String: Any] else { return }
            turnCompleted(turn)
        case "error":
            let error = params["error"] as? [String: Any]
            if params["willRetry"] as? Bool != true, let message = error?["message"] as? String {
                session.noteTurnError(Self.readableError(message))
            }
        case "mcpServer/startupStatus/updated":
            guard let name = params["name"] as? String else { return }
            var status = params["status"] as? String ?? "?"
            if status == "ready" { status = "connected" }
            if params["failureReason"] as? String == "reauthenticationRequired" { status = "needs-auth" }
            var entry = ["name": name, "status": status]
            if let error = params["error"] as? String, status != "connected" { entry["error"] = error }
            if mcp[name] == nil { mcpOrder.append(name) }
            mcp[name] = entry
            let servers = mcpOrder.compactMap { mcp[$0] }
            session.updateStartup({ $0.mcpServers = servers }, fresh: false)
        case "serverRequest/resolved":
            if let id = params["requestId"] { session.closeRequest(harnessID: TernJSONValue(id)) }
        case "thread/compacted":
            session.notice("The conversation was compacted.")
        default:
            break
        }
    }

    private func itemStarted(_ item: [String: Any]) {
        guard let type = item["type"] as? String, let ref = item["id"] as? String else { return }
        switch type {
        case "userMessage":
            if let client = item["clientId"] as? String, session.message(client) != nil {
                if !session.hasItem(ref: ref) {
                    session.addItem(kind: "user", text: Self.userText(item), message: client, ref: ref)
                }
                steered.removeAll { $0 == client }
                session.delivered(client)
            } else if !session.hasItem(ref: ref) {
                // Typed in Codex's own interface.
                session.addItem(kind: "user", text: Self.userText(item), ref: ref)
            }
        case "commandExecution":
            let command = Self.command(item)
            runningCommands.insert(ref)
            if !session.hasItem(ref: ref) {
                session.addItem(kind: "tool", text: "shell", tool: "shell", detail: command, state: "running", ref: ref)
            }
            session.toolStarted(ref: ref, description: "running: \(TernAgentText.oneLine(command, max: 80))")
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            session.addItem(kind: "tool", text: "edit", tool: "edit", detail: paths.joined(separator: ", "), state: "running", ref: ref)
            session.toolStarted(ref: ref, description: "editing \(paths.first ?? "files")")
        case "mcpToolCall":
            let name = "\(item["server"] as? String ?? "mcp").\(item["tool"] as? String ?? "tool")"
            session.addItem(kind: "tool", text: name, tool: name, detail: Self.compactJSON(item["arguments"]), state: "running", ref: ref)
            session.toolStarted(ref: ref, description: "calling \(name)")
        case "webSearch":
            session.addItem(kind: "tool", text: "web search", tool: "web_search", detail: item["query"] as? String ?? "",
                            state: "running", ref: ref)
        case "agentMessage":
            session.setActivity("replying")
        case "reasoning":
            session.setActivity("thinking")
        default:
            break
        }
    }

    private func itemCompleted(_ item: [String: Any]) {
        guard let type = item["type"] as? String, let ref = item["id"] as? String else { return }
        switch type {
        case "userMessage":
            if let client = item["clientId"] as? String, session.message(client) != nil {
                if !session.hasItem(ref: ref) {
                    session.addItem(kind: "user", text: Self.userText(item), message: client, ref: ref)
                }
                steered.removeAll { $0 == client }
                session.delivered(client)
            } else if !session.hasItem(ref: ref) {
                session.addItem(kind: "user", text: Self.userText(item), ref: ref)
            }
        case "agentMessage":
            let text = item["text"] as? String ?? ""
            let phase = item["phase"] as? String
            if !text.isEmpty {
                session.addItem(kind: "assistant", text: text, state: phase == "final_answer" ? nil : "commentary", ref: ref)
            }
            if phase == "final_answer" || phase == nil { session.noteFinalText(text) }
        case "commandExecution":
            let output = (item["aggregatedOutput"] as? String) ?? commandOutput[ref] ?? ""
            commandOutput.removeValue(forKey: ref)
            let status = item["status"] as? String ?? "completed"
            if !session.hasItem(ref: ref) {
                session.addItem(kind: "tool", text: "shell", tool: "shell", detail: Self.command(item), state: "running", ref: ref)
            }
            session.updateItem(ref: ref) { entry in
                entry.output = output
                entry.state = status == "completed" ? "done" : (status == "declined" ? "declined" : "error")
                if let code = item["exitCode"] as? Int, code != 0 { entry.state = "error (exit \(code))" }
            }
            session.toolEnded(ref: ref)
            runningCommands.remove(ref)
            if openCommands.remove(ref) != nil {
                session.backgroundTasks = openCommands.isEmpty ? nil : openCommands.count
                session.changed()
            }
        case "fileChange", "mcpToolCall", "webSearch":
            let status = item["status"] as? String ?? "completed"
            session.updateItem(ref: ref) { entry in
                entry.state = status == "completed" ? "done" : status
                if type == "mcpToolCall", let result = item["result"] { entry.output = Self.compactJSON(result) }
                if let error = (item["error"] as? [String: Any])?["message"] as? String { entry.output = error }
            }
            session.toolEnded(ref: ref)
        default:
            break
        }
    }

    private func turnCompleted(_ turn: [String: Any]) {
        let status = turn["status"] as? String ?? "completed"
        if let id = turn["id"] as? String, session.currentTurnID != nil, session.currentTurnID != id {
            return   // not the turn we track
        }
        // Commands of this process still running when a turn completes keep going in the
        // background.
        let running = Array(runningCommands)
        if status == "completed" {
            openCommands.formUnion(running)
            session.backgroundTasks = openCommands.isEmpty ? nil : openCommands.count
        } else {
            for ref in running { session.updateItem(ref: ref) { $0.state = "interrupted" } }
            runningCommands.removeAll()
        }
        let error = (turn["error"] as? [String: Any])?["message"] as? String
        if status != "completed", !steered.isEmpty {
            // Steered into a turn that ended before taking them in: they go back to the queue.
            let back = steered
            steered.removeAll()
            session.steeringCancelled(back)
        }
        switch status {
        case "completed":
            var reply = session.turnLastFinal
            if reply == nil, let items = turn["items"] as? [[String: Any]],
               let last = items.last(where: { $0["type"] as? String == "agentMessage" }) {
                reply = last["text"] as? String
            }
            session.endTurn(.done(reply ?? ""))
        case "interrupted":
            session.endTurn(.interrupted)
        default:
            session.endTurn(.failed(session.turnError ?? error.map(Self.readableError) ?? "the turn failed"))
        }
    }

    // MARK: Requests

    private func handleServerRequest(_ method: String, id: Any, params: [String: Any]) {
        let harnessID = TernJSONValue(id)
        func open(kind: String, title: String, detail: String, questions: [TernAgentQuestion] = [],
                  url: String? = nil, permissions: Any? = nil, schema: Any? = nil, ruleTool: String? = nil, ruleContent: String? = nil) {
            var request = TernAgentRequest(id: session.nextRequestID(), kind: kind, title: title, detail: detail,
                                           questions: questions, harnessID: harnessID, method: method,
                                           input: TernJSONValue(params), ruleTool: ruleTool, ruleContent: ruleContent,
                                           createdAt: Date())
            request.url = url
            request.permissions = permissions.map { TernJSONValue($0) }
            request.schema = schema.map { TernJSONValue($0) }
            session.openRequest(request)
        }
        switch method {
        case "item/commandExecution/requestApproval", "execCommandApproval":
            let command = ((params["commandActions"] as? [[String: Any]])?.first?["command"] as? String)
                ?? (params["command"] as? String) ?? (params["command"] as? [String])?.joined(separator: " ") ?? "a command"
            var detail = command
            if let cwd = params["cwd"] as? String { detail += " (in \(cwd))" }
            if let reason = params["reason"] as? String, !reason.isEmpty { detail += " — \(reason)" }
            open(kind: "approval", title: "Run a command", detail: detail, ruleTool: "command",
                 ruleContent: params["command"] as? String ?? command)
        case "item/fileChange/requestApproval", "applyPatchApproval":
            var detail = params["reason"] as? String ?? "apply file changes"
            if let root = params["grantRoot"] as? String { detail += " (write access to \(root))" }
            open(kind: "approval", title: "Change files", detail: detail, ruleTool: "fileChange", ruleContent: params["grantRoot"] as? String)
        case "item/permissions/requestApproval":
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            var parts: [String] = []
            if (permissions["network"] as? [String: Any])?["enabled"] as? Bool == true { parts.append("network access") }
            if let fs = permissions["fileSystem"] as? [String: Any] {
                if let write = fs["write"] as? [String], !write.isEmpty { parts.append("write: \(write.joined(separator: ", "))") }
                if let read = fs["read"] as? [String], !read.isEmpty { parts.append("read: \(read.joined(separator: ", "))") }
            }
            var detail = parts.isEmpty ? Self.compactJSON(permissions) : parts.joined(separator: "; ")
            if let reason = params["reason"] as? String { detail += " — \(reason)" }
            open(kind: "approval", title: "Grant permissions", detail: detail, permissions: permissions,
                 ruleTool: "permissions", ruleContent: Self.canonicalJSON(permissions))
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).enumerated().map { index, q in
                TernAgentQuestion(id: q["id"] as? String ?? "\(index + 1)", question: q["question"] as? String ?? "?",
                                  header: q["header"] as? String,
                                  options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                  multiSelect: false)
            }
            open(kind: "question", title: questions.count == 1 ? "A question" : "\(questions.count) questions",
                 detail: questions.map(\.question).joined(separator: " / "), questions: questions)
        case "mcpServer/elicitation/request":
            let server = params["serverName"] as? String ?? "An MCP server"
            let message = params["message"] as? String ?? ""
            if params["mode"] as? String == "url" || params["url"] != nil {
                let url = params["url"] as? String ?? ""
                open(kind: "approval", title: "\(server) asks you to open a link", detail: "\(message) \(url)", url: url)
            } else {
                let schema = params["requestedSchema"] as? [String: Any] ?? [:]
                let properties = schema["properties"] as? [String: Any] ?? [:]
                let required = schema["required"] as? [String] ?? []
                let names = properties.keys.sorted { (required.firstIndex(of: $0) ?? 99, $0) < (required.firstIndex(of: $1) ?? 99, $1) }
                let questions = names.map { name -> TernAgentQuestion in
                    let field = properties[name] as? [String: Any] ?? [:]
                    let label = field["title"] as? String ?? field["description"] as? String ?? name
                    return TernAgentQuestion(id: name, question: label, header: nil,
                                             options: (field["enum"] as? [Any] ?? []).map { "\($0)" }, multiSelect: false)
                }
                open(kind: "question", title: "\(server) asks for input", detail: message, questions: questions, schema: schema)
            }
        default:
            // Dynamic tools, auth refresh and the like aren't something a session can answer.
            write(["id": id, "error": ["code": -32601,
                                       "message": "\(TernPaths.productName) doesn't handle \(method)"]])
        }
    }

    func answer(_ request: TernAgentRequest, _ answer: TernAgentAnswer) -> String? {
        guard socket != nil else { return "the harness isn't running" }
        let params = (request.input?.any as? [String: Any]) ?? [:]
        let id = request.harnessID.any
        var result: [String: Any]
        switch (request.method, answer) {
        case ("item/commandExecution/requestApproval", .allow(let always, _)),
             ("item/fileChange/requestApproval", .allow(let always, _)):
            result = ["decision": always ? "acceptForSession" : "accept"]
        case ("item/commandExecution/requestApproval", .deny), ("item/fileChange/requestApproval", .deny):
            result = ["decision": "decline"]
        case ("execCommandApproval", .allow(let always, _)), ("applyPatchApproval", .allow(let always, _)):
            result = ["decision": always ? "approved_for_session" : "approved"]
        case ("execCommandApproval", .deny), ("applyPatchApproval", .deny):
            result = ["decision": "denied"]
        case ("item/permissions/requestApproval", .allow(let always, _)):
            result = ["permissions": params["permissions"] ?? [String: Any](), "scope": always ? "session" : "turn"]
        case ("item/permissions/requestApproval", .deny):
            result = ["permissions": [String: Any](), "scope": "turn"]
        case ("item/tool/requestUserInput", .answers(let given)):
            var answers: [String: Any] = [:]
            for question in request.questions {
                guard let text = given[question.id] ?? given[question.question] else {
                    return "no answer for question \(question.id) (\(question.question))"
                }
                answers[question.id] = ["answers": [text]]
            }
            result = ["answers": answers]
        case ("item/tool/requestUserInput", _):
            return "this request asks questions: answer them with `agent answer`"
        case ("mcpServer/elicitation/request", .allow):
            if request.url == nil, !request.questions.isEmpty {
                return "this form has fields: fill them with `agent answer`"
            }
            result = ["action": "accept", "content": NSNull()]
        case ("mcpServer/elicitation/request", .deny):
            result = ["action": "decline", "content": NSNull()]
        case ("mcpServer/elicitation/request", .answers(let given)):
            var content: [String: Any] = [:]
            let properties = ((request.schema?.any as? [String: Any])?["properties"] as? [String: Any]) ?? [:]
            for question in request.questions {
                guard let text = given[question.id] ?? given[question.question] else {
                    return "no value for field \(question.id)"
                }
                // Values take the type the form's schema asks for.
                let type = (properties[question.id] as? [String: Any])?["type"] as? String
                switch type {
                case "boolean":
                    switch text.lowercased() {
                    case "true", "yes", "y", "1", "on": content[question.id] = true
                    case "false", "no", "n", "0", "off": content[question.id] = false
                    default: return "field \(question.id) takes true or false (got \(text))"
                    }
                case "integer":
                    guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else {
                        return "field \(question.id) takes a whole number (got \(text))"
                    }
                    content[question.id] = n
                case "number":
                    guard let n = Double(text.trimmingCharacters(in: .whitespaces)) else {
                        return "field \(question.id) takes a number (got \(text))"
                    }
                    content[question.id] = n
                default:
                    content[question.id] = text
                }
            }
            result = ["action": "accept", "content": content]
        case (_, .answers):
            return "this request is an approval: use `agent approve` or `agent deny`"
        default:
            return "can't answer \(request.method) that way"
        }
        write(["id": id, "result": result])
        return nil
    }

    // MARK: Helpers

    static func userText(_ item: [String: Any]) -> String {
        (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    static func command(_ item: [String: Any]) -> String {
        if let action = (item["commandActions"] as? [[String: Any]])?.first?["command"] as? String { return action }
        return item["command"] as? String ?? ""
    }

    /// The whole value, keys sorted: what "allow always" matches on (never truncated).
    static func canonicalJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: TernJSON.sanitize(value), options: [.sortedKeys]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func compactJSON(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "" }
        guard JSONSerialization.isValidJSONObject(value) || value is [Any] || value is [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: TernJSON.sanitize(value), options: [.sortedKeys]) else {
            return "\(value)"
        }
        return TernAgentText.oneLine(String(decoding: data, as: UTF8.self), max: 400)
    }

    /// Codex API errors arrive as JSON inside the message; keep the readable part.
    static func readableError(_ message: String) -> String {
        if let data = message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = (object["error"] as? [String: Any])?["message"] as? String {
            return inner
        }
        return message
    }
}

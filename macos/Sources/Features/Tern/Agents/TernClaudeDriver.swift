import Foundation

/// Claude Code through its own headless mode:
///
///     claude -p --input-format stream-json --output-format stream-json --verbose
///            --replay-user-messages --permission-prompt-tool stdio
///            (--session-id ID | --resume ID) [--model M] [--effort E]
///            [--dangerously-skip-permissions | --permission-mode MODE]
///            --append-system-prompt NOTE [harness arguments]
///
/// That is the `claude` CLI itself, so it loads what the terminal loads: CLAUDE.md, the
/// user's and the project's settings, skills, MCP servers, plugins, hooks and subagents
/// (MA-23). Frames are the ones recorded in acceptance/reference/PROTOCOLS.md.
///
/// Turn tracking: a turn for a message starts at `command_lifecycle started` (that is also
/// the delivery receipt); a `system/init` with no turn running is a turn Claude started by
/// itself (C11wake); every turn ends with exactly one `result`, which lists the messages it
/// answered (`user_message_uuids`), or none and an `origin` for a self-started turn.
final class TernClaudeDriver: TernHarnessDriver {
    private unowned let session: TernAgentSession
    private weak var process: TernHarnessProcess?
    private var initID = "tern-init"
    private var ready = false
    private var sawInitThisProcess = false
    private var controlCounter = 0
    private var ourControlRequests: Set<String> = []

    init(session: TernAgentSession) {
        self.session = session
    }

    func arguments(resume: Bool) -> [String] {
        let record = session.record
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                    "--replay-user-messages", "--permission-prompt-tool", "stdio"]
        let id = record.harnessID ?? record.id
        args += resume ? ["--resume", id] : ["--session-id", id]
        if let model = record.model { args += ["--model", model] }
        if let effort = record.effort { args += ["--effort", effort] }
        if record.fullAccess {
            args.append("--dangerously-skip-permissions")
        } else if let mode = record.permissionMode {
            args += ["--permission-mode", mode]
        }
        args += ["--append-system-prompt", TernAgentEnvironment.awarenessNote(session: record)]
        args += record.harnessArgs
        return args
    }

    func begin(process: TernHarnessProcess, resume: Bool) {
        self.process = process
        controlCounter += 1
        initID = "tern-init-\(controlCounter)"
        ourControlRequests.insert(initID)
        _ = process.writeJSON(["type": "control_request", "request_id": initID,
                               "request": ["subtype": "initialize", "hooks": NSNull()]])
        // A harness that never answers (a hung startup script, a broken install) must not
        // leave the session "starting" forever.
        let id = initID
        TernAgents.queue.asyncAfter(deadline: .now() + 90) { [weak self, weak process] in
            guard let self, let process, !self.ready, self.initID == id, self.process === process else { return }
            self.session.startFailed("\(TernAgentKind.claude.rawValue) didn't answer within 90 seconds of starting")
        }
    }

    func send(_ message: TernAgentMessage) -> Bool {
        guard let process else { return false }
        return process.writeJSON([
            "type": "user",
            "message": ["role": "user", "content": message.text],
            "parent_tool_use_id": NSNull(),
            "session_id": session.record.harnessID ?? session.record.id,
            "uuid": message.id,
        ])
    }

    func interrupt(turnID: String?) {
        guard let process else { return }
        controlCounter += 1
        let id = "tern-int-\(controlCounter)"
        ourControlRequests.insert(id)
        _ = process.writeJSON(["type": "control_request", "request_id": id, "request": ["subtype": "interrupt"]])
    }

    // MARK: Frames

    func handle(_ frame: [String: Any]) {
        switch frame["type"] as? String {
        case "control_response":
            handleControlResponse(frame)
        case "control_request":
            handleControlRequest(frame)
        case "control_cancel_request":
            if let id = frame["request_id"] as? String { session.closeRequest(harnessID: .string(id)) }
        case "command_lifecycle":
            guard let uuid = frame["command_uuid"] as? String else { return }
            if frame["state"] as? String == "started" { session.delivered(uuid) }
        case "system":
            handleSystem(frame)
        case "user":
            handleUser(frame)
        case "assistant":
            handleAssistant(frame)
        case "result":
            handleResult(frame)
        default:
            break   // rate_limit_event, stream_event, keep_alive, …
        }
    }

    private func handleControlResponse(_ frame: [String: Any]) {
        guard let response = frame["response"] as? [String: Any],
              let id = response["request_id"] as? String, ourControlRequests.contains(id) else {
            return   // Claude echoes our answers to its requests; those aren't ours to handle.
        }
        ourControlRequests.remove(id)
        if id == initID {
            if response["subtype"] as? String == "success" {
                ready = true
                session.driverReady(harnessID: session.record.harnessID ?? session.record.id)
            } else {
                session.startFailed(response["error"] as? String ?? "Claude refused to start the session")
            }
        }
    }

    private func handleSystem(_ frame: [String: Any]) {
        switch frame["subtype"] as? String {
        case "init":
            if !session.turnIsRunning {
                session.beginTurn(id: nil, messages: [], selfStarted: true)
            }
            let fresh = !sawInitThisProcess
            sawInitThisProcess = true
            session.updateStartup({ startup in
                if let model = frame["model"] as? String { startup.model = model }
                if let servers = frame["mcp_servers"] as? [[String: Any]] {
                    startup.mcpServers = servers.map { server in
                        var entry: [String: String] = ["name": server["name"] as? String ?? "?",
                                                       "status": server["status"] as? String ?? "?"]
                        if let source = server["source"] as? String { entry["source"] = source }
                        return entry
                    }
                }
                startup.skills = Self.names(frame["skills"])
                startup.plugins = Self.names(frame["plugins"])
                startup.agents = Self.names(frame["agents"])
            }, fresh: fresh)
        case "background_tasks_changed":
            if let tasks = frame["tasks"] as? [Any] {
                session.backgroundTasks = tasks.count
                session.changed()
            }
        case "task_notification":
            if let summary = frame["summary"] as? String, !summary.isEmpty, frame["status"] as? String != "stopped" {
                session.notice(summary)
            }
        case "compact_boundary":
            session.notice("The conversation was compacted.")
        default:
            break
        }
    }

    private func handleUser(_ frame: [String: Any]) {
        guard let message = frame["message"] as? [String: Any] else { return }
        if frame["parent_tool_use_id"] is String { return }   // a subagent's own conversation
        if frame["isReplay"] as? Bool == true {
            let uuid = frame["uuid"] as? String
            let text = Self.text(message["content"])
            session.addItem(kind: "user", text: text, message: uuid.flatMap { session.message($0) != nil ? $0 : nil })
            if let uuid { session.delivered(uuid) }
            return
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return }
        for block in blocks {
            switch block["type"] as? String {
            case "tool_result":
                guard let ref = block["tool_use_id"] as? String else { continue }
                let output = Self.text(block["content"])
                let failed = block["is_error"] as? Bool ?? false
                session.updateItem(ref: ref) { item in
                    item.output = output
                    item.state = failed ? "error" : "done"
                }
                session.toolEnded(ref: ref)
            case "text":
                if let text = block["text"] as? String, text.hasPrefix("[Request interrupted") {
                    // The turn's end says so.
                }
            default:
                break
            }
        }
    }

    private func handleAssistant(_ frame: [String: Any]) {
        guard let message = frame["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return }
        let nested = frame["parent_tool_use_id"] is String
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                guard !nested, let text = block["text"] as? String, !text.isEmpty else { continue }
                session.addItem(kind: "assistant", text: text)
                session.setActivity("replying")
            case "thinking":
                session.setActivity("thinking")
            case "tool_use":
                guard let ref = block["id"] as? String else { continue }
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any] ?? [:]
                let detail = Self.describeTool(name, input)
                if nested {
                    session.setActivity("subagent: \(name) \(TernAgentText.oneLine(detail, max: 60))")
                    continue
                }
                session.addItem(kind: "tool", text: name, tool: name, detail: detail, state: "running", ref: ref)
                session.toolStarted(ref: ref, description: "running \(name): \(TernAgentText.oneLine(detail, max: 80))")
            default:
                break
            }
        }
    }

    private func handleResult(_ frame: [String: Any]) {
        if !ready && !session.turnIsRunning {
            // `--resume` of a conversation Claude doesn't have answers with a result and no
            // initialize response (C4e, C12missing).
            let errors = (frame["errors"] as? [String])?.joined(separator: "; ")
            session.startFailed(Self.explainStartError(errors ?? frame["result"] as? String ?? "Claude ended the session at startup"))
            return
        }
        var answered = frame["user_message_uuids"] as? [String] ?? []
        if answered.isEmpty, let one = frame["user_message_uuid"] as? String { answered = [one] }
        answered = answered.filter { session.message($0) != nil }
        let subtype = frame["subtype"] as? String ?? ""
        let isError = frame["is_error"] as? Bool ?? false
        if subtype == "success" && !isError {
            session.endTurn(.done(frame["result"] as? String ?? ""), answered: answered)
        } else if subtype == "success" {
            session.endTurn(.failed(frame["result"] as? String ?? "the model request failed"), answered: answered)
        } else if (frame["terminal_reason"] as? String ?? "").hasPrefix("aborted") || subtype == "error_during_execution" {
            session.endTurn(.interrupted, answered: answered)
        } else {
            let errors = (frame["errors"] as? [String])?.joined(separator: "; ") ?? subtype
            session.endTurn(.failed(errors), answered: answered)
        }
    }

    // MARK: Requests

    private func handleControlRequest(_ frame: [String: Any]) {
        guard let id = frame["request_id"] as? String, let request = frame["request"] as? [String: Any] else { return }
        guard request["subtype"] as? String == "can_use_tool" else {
            _ = process?.writeJSON(["type": "control_response", "response": [
                "subtype": "error", "request_id": id,
                "error": "\(TernPaths.productName) doesn't handle \(request["subtype"] as? String ?? "this request")"]])
            return
        }
        let tool = request["tool_name"] as? String ?? "tool"
        let input = request["input"] as? [String: Any] ?? [:]
        if tool == "AskUserQuestion" {
            let raw = input["questions"] as? [[String: Any]] ?? []
            let questions = raw.enumerated().map { index, q in
                TernAgentQuestion(id: "\(index + 1)", question: q["question"] as? String ?? "?", header: q["header"] as? String,
                                  options: (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                  multiSelect: q["multiSelect"] as? Bool ?? false)
            }
            let title = questions.count == 1 ? "A question" : "\(questions.count) questions"
            session.openRequest(TernAgentRequest(
                id: session.nextRequestID(), kind: "question", title: title,
                detail: questions.map(\.question).joined(separator: " / "), questions: questions,
                harnessID: .string(id), method: "can_use_tool:\(tool)", input: TernJSONValue(input),
                ruleTool: nil, ruleContent: nil, createdAt: Date()))
            return
        }
        var detail = Self.describeTool(tool, input)
        if let path = request["blocked_path"] as? String, !detail.contains(path) { detail += " (\(path))" }
        let content = (input["command"] as? String) ?? (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
        let title: String
        switch tool {
        case "Bash": title = "Run a command"
        case "Write", "Edit", "MultiEdit", "NotebookEdit": title = "Change a file"
        default: title = "Use \(tool)"
        }
        session.openRequest(TernAgentRequest(
            id: session.nextRequestID(), kind: "approval", title: title, detail: detail, questions: [],
            harnessID: .string(id), method: "can_use_tool:\(tool)", input: TernJSONValue(input),
            ruleTool: tool, ruleContent: content, createdAt: Date()))
    }

    func answer(_ request: TernAgentRequest, _ answer: TernAgentAnswer) -> String? {
        guard let process else { return "the harness isn't running" }
        guard case .string(let id) = request.harnessID else { return "unknown request" }
        let input = (request.input?.any as? [String: Any]) ?? [:]
        var response: [String: Any]
        switch answer {
        case .allow(let always, _):
            if request.kind == "question" { return "this request asks questions: answer them with `agent answer`" }
            response = ["behavior": "allow", "updatedInput": input]
            if always, let tool = request.ruleTool {
                var rule: [String: Any] = ["toolName": tool]
                if let content = request.ruleContent { rule["ruleContent"] = content }
                // destination "session": for this session only, never written to settings files.
                response["updatedPermissions"] = [["type": "addRules", "rules": [rule], "behavior": "allow",
                                                   "destination": "session"]]
            }
        case .deny(let message):
            response = ["behavior": "deny", "message": message ?? "The user denied this."]
        case .answers(let given):
            guard request.kind == "question" else { return "this request is an approval: use `agent approve` or `agent deny`" }
            var answers: [String: String] = [:]
            for question in request.questions {
                guard let text = given[question.id] ?? given[question.question] else {
                    return "no answer for question \(question.id) (\(question.question))"
                }
                answers[question.question] = text
            }
            var updated = input
            updated["answers"] = answers
            response = ["behavior": "allow", "updatedInput": updated]
        }
        _ = process.writeJSON(["type": "control_response",
                               "response": ["subtype": "success", "request_id": id, "response": response]])
        return nil
    }

    // MARK: Helpers

    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let blocks = content as? [[String: Any]] {
            return blocks.compactMap { block -> String? in
                if let t = block["text"] as? String { return t }
                if block["type"] as? String == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
        }
        return ""
    }

    static func names(_ value: Any?) -> [String]? {
        guard let list = value as? [Any] else { return nil }
        return list.compactMap { entry in
            if let s = entry as? String { return s }
            if let d = entry as? [String: Any] { return d["name"] as? String }
            return nil
        }
    }

    static func describeTool(_ name: String, _ input: [String: Any]) -> String {
        if let command = input["command"] as? String { return command }
        if let path = input["file_path"] as? String ?? input["notebook_path"] as? String { return path }
        if let pattern = input["pattern"] as? String {
            return pattern + ((input["path"] as? String).map { " in \($0)" } ?? "")
        }
        if let url = input["url"] as? String { return url }
        if let query = input["query"] as? String { return query }
        if let description = input["description"] as? String { return description }
        if let skill = input["skill"] as? String ?? input["command_name"] as? String { return skill }
        if input.isEmpty { return "" }
        let data = (try? JSONSerialization.data(withJSONObject: TernJSON.sanitize(input), options: [.sortedKeys])) ?? Data()
        return TernAgentText.oneLine(String(decoding: data, as: UTF8.self), max: 240)
    }

    static func explainStartError(_ text: String) -> String {
        if text.contains("No conversation found") {
            return "Claude no longer has this conversation (\(text)). Claude deletes conversations untouched for "
                + "`cleanupPeriodDays` (30 days by default)."
        }
        return text
    }
}

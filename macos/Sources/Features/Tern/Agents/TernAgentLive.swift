import Darwin
import Foundation

// Headless and live (SPEC AG-5 to AG-9).
//
// A session is controlled headless. The agent's own interface can run in a pane on the same
// conversation, started by `tern agent attach` (which Take Over types into the pane):
// - Claude Code's interface owns the conversation while it runs (two processes on one
//   conversation would fork it), so the headless process stops first. Its hooks (Tern's
//   plugin, loaded with --plugin-dir) say what it does. Messages wait until it's idle and the
//   user has nothing typed in it; then the interface is ended, the messages run headless with
//   the read-only view in the pane, and the interface comes back.
// - Codex's interface attaches to the session's own app server (`codex resume --remote`), so
//   the server keeps running and everything still goes through it.
// Everything here runs on `TernAgents.queue`.

extension TernAgentSession {
    /// The agent's own interface owns the conversation (Claude Code, or a Codex the user typed).
    var exclusiveLive: Bool { liveState != nil && record.liveAttached != true }

    /// Where the session is, for `agent ls`/`info` (AG-14): its own interface in a pane, its
    /// read-only view in a pane, or no pane at all.
    var location: String {
        if record.live == true { return "live" }
        if TernAgentUI.shownPane(of: record.id) != nil { return "pane" }
        return "background"
    }

    // MARK: Going live

    /// Show the agent's own interface in the session's pane: the UI types the attach command
    /// there, and `prepareLive` does the rest when it arrives.
    func goLive() {
        guard let pane = record.pane, !goingLive, record.live != true else { return }
        goingLive = true
        record.goLiveWhenSettled = nil
        saveRecord()
        changed()
        let id = record.id
        let selector = attachSelector
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TernAgentUI.typeAttach(pane: pane, session: id, selector: selector) }
        }
        // If the command never arrives (the pane closed, its shell was busy), stop waiting.
        TernAgents.queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.goingLive, self.record.live != true else { return }
            self.goingLive = false
            self.changed()
            self.pump()
        }
    }

    /// `agent start` with a placement and no prompt: nothing to run headless first.
    func goLiveAfterStart() {
        record.goLiveWhenSettled = nil
        if record.kind == .codex && phase != .ready {
            // Its interface attaches once the server has the thread.
            record.goLiveWhenSettled = true
            saveRecord()
            return
        }
        goLive()
    }

    /// What Tern types to attach: the session's name when it names only this session.
    var attachSelector: String {
        if let manager, (try? manager.resolve(record.name, caller: TernCaller(pane: nil, instance: nil, session: nil))) === self {
            return record.name
        }
        return record.id
    }

    /// `agent attach` from a pane: make the conversation free for the agent's own interface
    /// (taking it over from a running headless turn, at once) and say how to run it there.
    func prepareLive(pane: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        if record.live == true, let current = record.pane, current != pane, liveState != nil {
            completion(.failure(TernError.failed("\(record.name) is already live in pane \(current.prefix(8)); "
                + "`\(TernPaths.cliName) agent open \(record.name)` shows it")))
            return
        }
        record.pane = pane
        switch record.kind {
        case .claude:
            if live {
                // Take it over now (AG-6): a running turn is interrupted; messages handed over
                // for steering and not taken in come back to the queue.
                if turnIsRunning { notice("Taken over in its own interface; the running turn was interrupted.") }
                stoppedHandlers.append { [weak self] in self?.finishPrepareLive(pane: pane, completion: completion) }
                stopProcess(kind: .handoff, completion: nil)
            } else if phase == .launching || phase == .starting {
                stoppedHandlers.append { [weak self] in self?.finishPrepareLive(pane: pane, completion: completion) }
                stopProcess(kind: .handoff, completion: nil)
            } else {
                finishPrepareLive(pane: pane, completion: completion)
            }
        case .codex:
            // The interface attaches to the session's own server: start it if it isn't running.
            if phase == .ready {
                finishPrepareLive(pane: pane, completion: completion)
                return
            }
            if phase == .stopped { launch() }
            var done = false
            var waiter: UUID?
            waiter = addWaiter { [weak self] in
                guard let self, !done else { return true }
                if self.phase == .ready {
                    done = true
                    self.finishPrepareLive(pane: pane, completion: completion)
                    return true
                }
                if self.phase == .stopped && self.record.ended == "error" {
                    done = true
                    completion(.failure(TernError.failed("couldn't start Codex for \(self.record.name): \(self.record.lastError ?? "unknown error")")))
                    return true
                }
                return false
            }
            TernAgents.queue.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, !done else { return }
                done = true
                if let waiter { self.removeWaiter(waiter) }
                completion(.failure(TernError.failed("Codex didn't start within a minute for \(self.record.name)")))
            }
        }
    }

    private func finishPrepareLive(pane: String, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        do {
            let spec = try liveCommand()
            record.live = true
            record.pane = pane
            record.liveAttached = record.kind == .codex
            record.livePID = nil
            record.goLiveWhenSettled = nil
            liveState = record.kind == .codex ? .idle : .starting
            liveDraft = false
            liveBackground = 0
            liveActivity = ""
            goingLive = false
            endLiveWhenSettled = false
            lastHookAt = Date()
            saveRecord()
            notice("Opened in its own interface (live) in a pane.")
            changed()
            completion(.success(spec))
        } catch {
            goingLive = false
            changed()
            completion(.failure(error))
        }
    }

    /// The command that runs the agent's own interface on this conversation.
    func liveCommand() throws -> [String: Any] {
        guard let binary = TernAgentEnvironment.harnessBinary(record.kind) else {
            throw TernError.failed("\(record.kind.rawValue) isn't installed (not found on your login shell's PATH)")
        }
        var args: [String] = []
        var env: [String: String] = record.env
        env["TERN_SESSION_ID"] = record.id
        env["TERN_SESSION_NAME"] = record.name
        switch record.kind {
        case .claude:
            guard let id = record.harnessID else { throw TernError.failed("\(record.name) has no conversation id") }
            // A session that never ran a turn has no conversation to resume yet: its interface
            // starts it, under the id Tern chose.
            args += record.conversation == true ? ["--resume", id] : ["--session-id", id]
            if let model = record.model { args += ["--model", model] }
            if let effort = record.effort { args += ["--effort", effort] }
            if record.fullAccess {
                args.append("--dangerously-skip-permissions")
            } else if let mode = record.permissionMode {
                args += ["--permission-mode", mode]
            }
            if let plugin = TernAgentPlugins.bundledClaudePlugin {
                // Tern's own copy of its plugin, so the interface reports to Tern even where the
                // plugin isn't installed; an installed copy stays quiet (TERN_PLUGIN_ROOT).
                args += ["--plugin-dir", plugin]
                env["TERN_PLUGIN_ROOT"] = plugin
            }
            args += record.harnessArgs
        case .codex:
            guard let thread = record.harnessID else { throw TernError.failed("\(record.name) has no thread id") }
            guard let socket = codexSocketPath else { throw TernError.failed("\(record.name)'s Codex server isn't running") }
            args += ["resume", thread, "--remote", "unix://\(socket)"]
            env["TERN_PLUGIN_ROOT"] = "attached"
        }
        return ["binary": binary, "args": args, "env": env, "cwd": record.cwd, "session": record.id,
                "name": record.name, "kind": record.kind.rawValue]
    }

    /// The Codex app server's socket, while it runs (set by the Codex driver).
    var codexSocketPath: String? { (driverForLive as? TernCodexDriver)?.socketPath }

    // MARK: Hooks from the live interface (Tern's plugin, AG-18)

    func hook(_ event: String, _ payload: [String: Any], pane: String?, pid: Int32?) {
        lastHookAt = Date()
        if record.live != true {
            // A hook from an interface Tern didn't attach (the user typed `claude` in a pane
            // where this conversation lives, or the attach raced): it's live now.
            guard event != "SessionEnd" else { return }
            record.live = true
            record.liveAttached = false
            if let pane { record.pane = pane }
            liveState = .idle
            saveRecord()
        }
        if let pid, pid > 1, record.livePID != pid {
            record.livePID = pid
            saveRecord()
        }
        let tool = payload["tool_name"] as? String ?? ""
        let input = payload["tool_input"] as? [String: Any] ?? [:]
        switch event {
        case "SessionStart":
            if let id = payload["session_id"] as? String, !id.isEmpty, id != record.harnessID {
                // `/clear` (or a fresh start) gives the interface a new conversation: the
                // session follows the interface.
                record.harnessID = id
                notice("Its interface started a new conversation (\(id.prefix(8))).")
            }
            record.conversation = true
            saveRecord()
            if liveState == .starting || liveState == nil { liveState = .idle }
        case "UserPromptSubmit":
            liveState = .working
            liveDraft = false
            liveActivity = ""
            let prompt = payload["prompt"] as? String ?? ""
            if !prompt.isEmpty {
                addItem(kind: "user", text: prompt)
                if record.title == nil { record.title = TernAgentText.oneLine(prompt, max: 60); saveRecord() }
            }
        case "PreToolUse":
            liveState = tool == "AskUserQuestion" ? .needsInput : .working
            let ref = payload["tool_use_id"] as? String
            let detail = TernClaudeDriver.describeTool(tool, input)
            if let ref, !hasItem(ref: ref) {
                addItem(kind: "tool", text: tool, tool: tool, detail: detail, state: "running", ref: ref)
            }
            liveActivity = tool == "AskUserQuestion" ? "asking you a question in its interface"
                : "running \(tool): \(TernAgentText.oneLine(detail, max: 80))"
        case "PostToolUse", "PostToolUseFailure":
            liveState = .working
            if let ref = payload["tool_use_id"] as? String {
                let output = TernAgentLive.text(payload["tool_response"])
                updateItem(ref: ref) { item in
                    item.state = event == "PostToolUse" ? "done" : "error"
                    if !output.isEmpty { item.output = output }
                }
            }
            liveActivity = ""
        case "PermissionRequest":
            liveState = .needsInput
            liveActivity = "asking permission in its interface: \(tool) \(TernAgentText.oneLine(TernClaudeDriver.describeTool(tool, input), max: 80))"
            checkWatches(needsInput: true)
        case "Notification":
            let kind = payload["notification_type"] as? String ?? ""
            if kind == "permission_prompt" || kind == "elicitation_dialog" || kind == "agent_needs_input" {
                liveState = .needsInput
                if liveActivity.isEmpty {
                    liveActivity = "waiting for you in its interface: \(TernAgentText.oneLine(payload["message"] as? String ?? "", max: 80))"
                }
                checkWatches(needsInput: true)
            }
        case "Stop", "StopFailure":
            let reply = payload["last_assistant_message"] as? String ?? ""
            if event == "Stop" {
                if !reply.isEmpty { addItem(kind: "assistant", text: reply, state: "final") }
            } else {
                let error = payload["error"] as? String ?? "the turn failed"
                addItem(kind: "error", text: reply.isEmpty ? error : "\(error): \(reply)")
                record.lastError = error
            }
            liveBackground = (payload["background_tasks"] as? [Any])?.count ?? 0
            liveBackground += (payload["session_crons"] as? [Any])?.count ?? 0
            liveState = .idle
            liveActivity = ""
            for item in items where item.kind == "tool" && item.state == "running" && liveBackground == 0 {
                if let ref = item.ref { updateItem(ref: ref) { $0.state = "done" } }
            }
            lastStopAt = Date()
            checkWatches(turnEnded: true)
        case "SessionEnd":
            liveEnded()
            return
        default:
            break
        }
        changed()
        pump()
        checkSettled()
    }

    /// Esc or Ctrl-C typed into the live interface while it worked: interrupts fire no hook, so
    /// a turn with no hook for two seconds afterwards is taken as interrupted (Warp does the same).
    func liveKey(interrupt: Bool) {
        lastLiveKey = Date()
        if !interrupt {
            if liveState != .working { liveDraft = true }
            changed()
            return
        }
        // Ctrl-C at an idle prompt clears what was typed.
        if liveState == .idle { liveDraft = false }
        guard liveState == .working || liveState == .needsInput else { changed(); return }
        let asked = Date()
        TernAgents.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.liveState == .working || self.liveState == .needsInput else { return }
            if let last = self.lastHookAt, last > asked { return }
            self.liveState = .idle
            self.liveActivity = ""
            self.addItem(kind: "notice", text: "Interrupted in its interface.")
            self.lastStopAt = Date()
            self.changed()
            self.pump()
            self.checkSettled()
        }
    }

    /// The live interface closed (its SessionEnd hook, its process gone, or its pane closed):
    /// the session is headless again (AG-7).
    func liveEnded() {
        guard record.live == true || liveState != nil else { return }
        let wasReclaiming = reclaiming
        record.live = nil
        record.livePID = nil
        record.liveAttached = nil
        liveState = nil
        liveDraft = false
        liveBackground = 0
        liveActivity = ""
        reclaiming = false
        endLiveWhenSettled = false
        if wasReclaiming {
            // Messages waited for it: they run headless now, then the interface comes back.
            record.goLiveWhenSettled = true
            notice("Running \(queue.count) waiting message(s) headless; its interface comes back afterwards.")
        } else {
            notice("Its interface closed; the session is headless again.")
        }
        saveRecord()
        let pane = record.pane
        let id = record.id
        // A `claude` the user typed leaves their shell behind; a session Tern opened goes back
        // to its read-only view.
        let keepView = record.origin != "typed" || wasReclaiming
        if !keepView { record.pane = nil; saveRecord() }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TernAgentUI.liveEnded(session: id, pane: pane, keepView: keepView) }
        }
        changed()
        pump()
        checkSettled()
    }

    /// End the live interface (to take the session back, or because it was removed from its
    /// pane and has finished).
    func endLiveInterface(reason: String) {
        guard record.live == true else { return }
        if record.liveAttached == true {
            // Codex's interface is only a view of the server: closing it changes nothing else.
            let pane = record.pane
            let id = record.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TernAgentUI.closeLiveInterface(session: id, pane: pane) }
            }
            liveEnded()
            return
        }
        if let pid = record.livePID, TernAgentLive.isLiveProcess(pid, of: self) {
            kill(pid, SIGTERM)
        } else {
            let pane = record.pane
            let id = record.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TernAgentUI.closeLiveInterface(session: id, pane: pane) }
            }
        }
        // If the interface ignores the request, it's ended harder.
        let pid = record.livePID
        TernAgents.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.record.live == true, self.record.livePID == pid else { return }
            if let pid, TernAgentLive.isLiveProcess(pid, of: self) { kill(pid, SIGKILL) }
            self.liveEnded()
        }
    }

    // MARK: Messages for a live session (AG-9)

    /// Take an exclusive live session back to deliver waiting messages, when its interface is
    /// idle and the user has nothing typed there.
    func considerReclaim() {
        guard exclusiveLive, !queue.isEmpty, liveState == .idle, liveBackground == 0, !reclaiming, !endLiveWhenSettled else {
            changed()
            return
        }
        guard !liveDraft else { changed(); return }
        if let key = lastLiveKey, Date().timeIntervalSince(key) < 3 {
            // The user is typing there right now: look again in a moment.
            TernAgents.queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.pump() }
            return
        }
        reclaiming = true
        notice("Taking it back from its interface to deliver \(queue.count) message(s).")
        changed()
        endLiveInterface(reason: "reclaim")
    }

    // MARK: Settling

    /// When nothing runs any more: go live where that was asked for, end an interface that was
    /// removed from its pane.
    func checkSettled() {
        guard settled else { return }
        if endLiveWhenSettled, record.live == true {
            endLiveWhenSettled = false
            endLiveInterface(reason: "hidden")
            return
        }
        if record.goLiveWhenSettled == true, record.pane != nil, record.live != true, !goingLive, !shuttingDown {
            goLive()
        }
    }

    // MARK: Removing from a pane (AG-8)

    enum HideAction { case closePane, parkPane, nothing }

    /// Remove the session from its pane without stopping it. The UI closes the pane, or parks
    /// it out of sight while the live interface finishes.
    func hide() -> HideAction {
        guard record.pane != nil else { return .nothing }
        record.goLiveWhenSettled = nil
        goingLive = false
        if record.live == true {
            if record.liveAttached == true {
                // Codex: the server keeps the turn going; its interface just closes.
                liveEnded()
                record.pane = nil
                saveRecord()
                changed()
                return .closePane
            }
            if settled {
                record.pane = nil
                saveRecord()
                endLiveInterface(reason: "hidden")
                return .closePane
            }
            endLiveWhenSettled = true
            saveRecord()
            changed()
            return .parkPane
        }
        record.pane = nil
        saveRecord()
        changed()
        return .closePane
    }

    // MARK: Crash recovery (Claude): what the conversation's own record says

    /// Whether Claude's transcript of this conversation has the message (as a turn's input, or
    /// taken in while a turn ran): nil when the transcript can't be read.
    func claudeTranscriptHas(_ messageID: String) -> Bool? {
        guard record.kind == .claude, let id = record.harnessID else { return nil }
        guard let path = TernAgentLive.claudeTranscript(session: id, cwd: record.cwd, env: record.env),
              let data = FileManager.default.contents(atPath: path) else { return nil }
        let needle = Data(messageID.utf8)
        return data.range(of: needle) != nil
    }
}

enum TernAgentLive {
    /// Claude Code's transcript of a conversation: `<config>/projects/<cwd with / and . as
    /// -><>/<id>.jsonl`, where `<config>` is CLAUDE_CONFIG_DIR or ~/.claude.
    static func claudeTranscript(session: String, cwd: String, env: [String: String]) -> String? {
        let config = env["CLAUDE_CONFIG_DIR"] ?? TernAgentEnvironment.login().env["CLAUDE_CONFIG_DIR"]
            ?? (NSHomeDirectory() + "/.claude")
        let slug = String(cwd.map { $0 == "/" || $0 == "." ? "-" : $0 })
        let direct = "\(config)/projects/\(slug)/\(session).jsonl"
        if FileManager.default.fileExists(atPath: direct) { return direct }
        // Resumed from another folder: look for it by id.
        let projects = "\(config)/projects"
        for folder in (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? [] {
            let candidate = "\(projects)/\(folder)/\(session).jsonl"
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// A session's live interface process: alive, and carrying the session's (or its pane's)
    /// identity in its environment, so a reused pid is never signalled.
    static func isLiveProcess(_ pid: Int32, of session: TernAgentSession) -> Bool {
        guard pid > 1, kill(pid, 0) == 0 else { return false }
        guard let env = TernProcessTree.environment(pid) else { return false }
        if env["TERN_SESSION_ID"] == session.record.id { return true }
        if let pane = session.record.pane, env["TERN_PANE_ID"] == pane, env["TERN_STATE_DIR"] == TernPaths.stateDirectory {
            return true
        }
        return false
    }

    static func text(_ value: Any?) -> String {
        if let s = value as? String { return TernAgentText.clip(s) }
        if let d = value as? [String: Any] {
            if let out = d["stdout"] as? String { return TernAgentText.clip(out) }
            if let content = d["content"] { return text(content) }
        }
        if let list = value as? [[String: Any]] {
            return TernAgentText.clip(list.compactMap { $0["text"] as? String }.joined(separator: "\n"))
        }
        return ""
    }
}

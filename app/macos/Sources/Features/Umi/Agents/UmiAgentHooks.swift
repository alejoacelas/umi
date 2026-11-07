import AppKit
import Darwin

/// What Umi's plugins for Claude Code and Codex tell it, written on the pane the agent runs in
/// (design/primitives.md, "Agent hook plugin"; SPEC AG-18, AG-19). Inside a pane, each hook event
/// runs `umi hook EVENT --agent claude|codex --pid PID`; the pane is the caller's (`UMI_PANE_ID`).
///
/// The status stays truthful:
/// - a turn that ends with background work still pending (Claude Code's background tasks and
///   scheduled wake-ups) stays `working`;
/// - an interrupt (Esc or Ctrl-C typed while it works) fires no hook: a turn with no hook for two
///   seconds after one is taken as interrupted, and the agent is `idle` (Warp does the same);
/// - a permission prompt or a question is `needs_input`.
///
/// It also follows the agent's input line (keys and text sent to the pane), so an update waits
/// while something is typed there (I-4), and brings agents back after a relaunch: each pane that
/// ran one gets its command typed again, resuming its conversation (`restore`).
@MainActor
enum UmiAgentHooks {
    // MARK: Hooks

    /// The control socket's `hook` method (and `agent.hook`, which plugins installed by Umi before
    /// 0.10 call until Umi brings them up to date at its next launch).
    static func handle(_ params: UmiParams, caller: UmiCaller) -> [String: Any] {
        guard let event = params.string("event"), !event.isEmpty,
              let kind = UmiAgentKind(rawValue: params.string("agent") ?? "claude") else { return [:] }
        // A pane of this instance (a stale or foreign pane is no caller at all).
        guard !caller.isStale, let id = caller.pane,
              let pane = UmiTopology.allSurfaces.first(where: { $0.umiID == id }) else { return [:] }
        let payload = params.raw["payload"] as? [String: Any] ?? [:]
        hook(event, kind: kind, payload: payload, pane: pane, pid: params.int("pid").map { Int32($0) })
        return ["pane": pane.umiID]
    }

    static func hook(_ event: String, kind: UmiAgentKind, payload: [String: Any], pane: Ghostty.SurfaceView, pid: Int32?) {
        let attention = UmiAttention.shared
        if attention.shuttingDown { return }
        // The process that ran the hook (the agent, or a shell it ran the hook in) and the command
        // it was typed as.
        let typed = pid.flatMap { $0 > 1 ? UmiTypedCommand.command(pid: $0, kind: kind) : nil }
        // `claude -p` run by a script in the pane is a one-off, not the pane's agent.
        if let typed, UmiTypedCommand.isOneOff(typed.args, kind: kind) { return }
        let now = Date()
        var agent = attention.agent(forPane: pane.id) ?? UmiAttention.Agent(kind: kind, status: .idle, at: now)
        if agent.kind != kind || (agent.status == .stopped && event == "SessionStart") {
            // Another agent in the pane: it starts afresh (the next agent's hooks overwrite agent.*).
            // The same conversation again (a relaunch typed it) keeps its title.
            let sameConversation = agent.kind == kind && agent.session != nil && agent.session == payload["session_id"] as? String
            let previous = agent
            agent = UmiAttention.Agent(kind: kind, status: .idle, at: now)
            if sameConversation {
                agent.session = previous.session
                agent.title = previous.title
                agent.conversation = previous.conversation
            }
        }
        agent.lastHookAt = now
        agent.idleInferred = false
        if let cwd = payload["cwd"] as? String, !cwd.isEmpty { agent.cwd = cwd }
        // The agent's own process (the hook may run in a shell it started).
        let agentPID = typed?.pid ?? pid
        if let agentPID, agentPID > 1, agent.pid != agentPID || agent.program == nil {
            agent.pid = agentPID
            if let typed { agent.program = typed.program; agent.typedArgs = typed.args }
            if let env = UmiProcessTree.environment(agentPID) {
                agent.env = env.filter { ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].contains($0.key) && !$0.value.isEmpty }
            }
        }
        if let id = payload["session_id"] as? String, !id.isEmpty, id != agent.session {
            // A new conversation (`/clear`, or a fresh start): what belonged to the old one goes.
            if agent.session != nil {
                agent.title = ""
                agent.summary = nil
                agent.done = nil
                agent.conversation = false
            }
            agent.session = id
        }
        if kind == .codex {
            agent.conversation = true
        } else if let path = payload["transcript_path"] as? String, FileManager.default.fileExists(atPath: path) {
            agent.conversation = true
        }
        let tool = payload["tool_name"] as? String ?? ""
        switch event {
        case "SessionStart":
            if agent.status == .stopped || agent.status == .error { agent.status = .idle }
            promptSent(&agent)
        case "UserPromptSubmit":
            agent.status = .working
            agent.detail = nil
            agent.conversation = true
            promptSent(&agent)
            if agent.title.isEmpty, let prompt = payload["prompt"] as? String, !prompt.isEmpty {
                agent.title = oneLine(prompt, max: 60)
            }
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                agent.status = .needsInput
                agent.detail = "asking you a question"
                agent.lastStop = now
            } else {
                agent.status = .working
            }
        case "PostToolUse", "PostToolUseFailure":
            agent.status = .working
            agent.detail = nil
        case "PermissionRequest":
            agent.status = .needsInput
            agent.detail = "asking permission: \(tool)"
            agent.lastStop = now
        case "Notification":
            let type = payload["notification_type"] as? String ?? ""
            if ["permission_prompt", "elicitation_dialog", "agent_needs_input"].contains(type) {
                agent.status = .needsInput
                agent.detail = oneLine(payload["message"] as? String ?? "waiting for you", max: 120)
                agent.lastStop = now
            }
        case "Stop", "StopFailure":
            let reply = payload["last_assistant_message"] as? String ?? ""
            agent.background = ((payload["background_tasks"] as? [Any])?.count ?? 0)
                + ((payload["session_crons"] as? [Any])?.count ?? 0)
            if event == "StopFailure" {
                agent.status = .error
                agent.detail = payload["error"] as? String ?? "the turn failed"
            } else {
                // Work it started that will wake it: not finished yet.
                agent.status = agent.background > 0 ? .working : .idle
                agent.detail = nil
            }
            if !reply.isEmpty {
                agent.summary = reply.split(whereSeparator: \.isNewline).first.map { oneLine(String($0), max: 160) }
            }
            agent.done = doneCheck(reply)
            agent.lastStop = now
        case "SessionEnd":
            agent.status = .stopped
            agent.background = 0
            agent.detail = nil
            agent.lastStop = now
            agent.draft = false
            agent.draftChars = 0
            agent.inputTouched = false
        default:
            break
        }
        attention.set(agent, forPane: pane.id)
        // Input that reached the pane after the agent started and before its first hook: its input
        // line may hold it (I-4).
        if let agentPID, let started = UmiTypedCommand.startTime(agentPID), let key = lastKeyAt[pane.id], key > started,
           event == "SessionStart" {
            attention.update(pane.id) { touch(&$0) }
        }
    }

    /// The `done-check` slot's default: the last line of the agent's last message starts with
    /// `Status: done`.
    static func doneCheck(_ reply: String) -> Bool {
        let last = reply.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last.map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Status: done") } ?? false
    }

    static func oneLine(_ text: String, max: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
    }

    // MARK: The agent's process ended

    /// A command ended in a pane: if it was the agent (its process is gone), the agent stopped.
    /// (Claude Code says so with its SessionEnd hook too.)
    static func commandFinished(in pane: Ghostty.SurfaceView) {
        let attention = UmiAttention.shared
        // Only an agent whose process Umi knows (from its hooks), once that process is gone: any
        // other command ending in the pane says nothing about the agent.
        guard !attention.shuttingDown, let agent = attention.agent(forPane: pane.id), agent.running,
              let pid = agent.pid, kill(pid, 0) != 0 else { return }
        attention.update(pane.id) {
            $0.status = .stopped
            $0.background = 0
            $0.lastStop = Date()
            $0.draft = false
            $0.draftChars = 0
            $0.inputTouched = false
        }
    }

    // MARK: Typing into the agent

    /// When a key last went to each pane: an agent is known only from its first hook, and keys may
    /// reach it before.
    static var lastKeyAt: [UUID: Date] = [:]

    static func noteKey(pane: Ghostty.SurfaceView) {
        if lastKeyAt.count > 512 { lastKeyAt.removeAll() }
        lastKeyAt[pane.id] = Date()
    }

    /// A pane whose agent's input Umi follows.
    static func follows(_ pane: UUID) -> Bool { UmiAttention.shared.agent(forPane: pane)?.running == true }

    /// What a key (or text) does to the agent's input line, as far as Umi can tell.
    enum Input: Equatable {
        case interrupt, escape, history, cursor, submit, clear, delete, other, edit
        case text(Int)
    }

    static func keyTyped(pane: Ghostty.SurfaceView, event: NSEvent) {
        guard follows(pane.id) else { return }
        let chars = event.charactersIgnoringModifiers ?? ""
        let control = event.modifierFlags.contains(.control)
        let input: Input
        if control && chars.lowercased() == "c" {
            input = .interrupt
        } else if event.keyCode == 53 {                          // esc
            input = .escape
        } else if [125, 126].contains(event.keyCode) && event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            input = .history                                      // up, down: may recall a prompt
        } else if [123, 124, 115, 119].contains(event.keyCode) && !event.modifierFlags.contains(.command) {
            input = .cursor                                       // left, right, home, end
        } else if event.keyCode == 36 || event.keyCode == 76 {   // return, enter
            // With Shift, Option or Control it inserts a newline in Claude Code and Codex; while an
            // input method composes, it confirms the composition.
            input = event.modifierFlags.isDisjoint(with: [.shift, .option, .control]) && !pane.hasMarkedText() ? .submit : .edit
        } else if control && chars.lowercased() == "u" {
            input = .clear
        } else if event.keyCode == 51 && event.modifierFlags.isDisjoint(with: [.option, .command]) {
            input = .delete                                       // backspace: one character
        } else if event.modifierFlags.contains(.command) && chars.lowercased() == "v" {
            // A paste puts text on the input line: it's typed text, as long as the paste is.
            input = .text(max(1, NSPasteboard.general.string(forType: .string)?.count ?? 1))
        } else if [123, 124, 125, 126, 115, 116, 119, 121, 117].contains(event.keyCode)
                    || event.modifierFlags.contains(.command) || (event.characters ?? "").isEmpty {
            input = .other                                        // navigation, shortcuts
        } else if event.keyCode == 51 || control {
            input = .edit                                         // a word deleted, a control key
        } else {
            input = .text((event.characters ?? "").count)
        }
        apply(input, to: pane.id)
    }

    /// Edit > Paste (or its key): the pasted text is typed text there.
    static func pasted(pane: Ghostty.SurfaceView, text: String?) {
        guard follows(pane.id) else { return }
        apply(.text(max(1, text?.count ?? 1)), to: pane.id)
    }

    /// Text and keys put into a pane through Umi (`umi send`, `umi keys`): scripts type into an
    /// agent this way, so it counts like the keyboard.
    static func inputSent(pane: Ghostty.SurfaceView, text: String, keys: [String]) {
        noteKey(pane: pane)
        guard follows(pane.id) else { return }
        if !text.isEmpty { apply(.text(text.count), to: pane.id) }
        for key in keys {
            let spec = key.lowercased()
            let input: Input
            if ["ctrl+c", "control+c", "c+c"].contains(spec) {
                input = .interrupt
            } else if ["esc", "escape"].contains(spec) {
                input = .escape
            } else if ["up", "down", "arrowup", "arrowdown"].contains(spec) {
                input = .history
            } else if ["left", "right", "home", "end", "arrowleft", "arrowright", "alt+left", "alt+right"].contains(spec) {
                input = .cursor
            } else if ["enter", "return", "ret", "cr", "nl"].contains(spec) {
                input = .submit
            } else if spec.hasSuffix("+enter") || spec.hasSuffix("+return") {
                input = .edit                                     // a newline, not a submit
            } else if ["ctrl+u", "control+u", "c+u"].contains(spec) {
                input = .clear
            } else if ["backspace", "bs"].contains(spec) {
                input = .delete
            } else if ["pgup", "pgdn", "pageup", "pagedown", "delete", "del"].contains(spec)
                        || spec.hasPrefix("arrow") || spec.hasPrefix("cmd+") || spec.hasPrefix("command+") {
                input = .other
            } else if spec.contains("+") {
                input = .edit
            } else {
                input = .text(1)
            }
            apply(input, to: pane.id)
        }
    }

    private static func apply(_ input: Input, to id: UUID) {
        let attention = UmiAttention.shared
        guard let agent = attention.agent(forPane: id) else { return }
        switch input {
        case .submit:
            // UserPromptSubmit says whether something was sent.
            attention.update(id) { if $0.status != .needsInput { $0.enterSeq = $0.inputSeq } }
        case .clear:
            attention.update(id) { $0.draft = false; $0.draftChars = 0; touch(&$0) }
        case .interrupt, .escape:
            if agent.status == .working || agent.status == .needsInput {
                interruptAsked(id)
            } else if input == .interrupt {
                // Ctrl-C at an idle prompt clears what was typed (Esc leaves it). The line still
                // counts as touched: a remapped Ctrl-C may have been a copy.
                attention.update(id) { $0.draft = false; $0.draftChars = 0 }
            }
        case .history, .cursor, .other:
            attention.update(id) { touch(&$0) }
        case .delete:
            typed(-1, id)
        case .text(let count):
            typed(count, id)
        case .edit:
            // Something changed the line by an amount Umi can't tell: if text was typed, it still
            // counts as typed, and the line may now hold text Umi didn't see.
            typed(0, id)
        }
    }

    private static func typed(_ count: Int, _ id: UUID) {
        UmiAttention.shared.update(id) { agent in
            // Keys typed into a permission or question dialog answer it: no draft on the prompt.
            if agent.status != .needsInput {
                agent.draftChars = max(0, agent.draftChars + count)
                if count > 0 { agent.draft = true } else if count < 0 && agent.draftChars == 0 { agent.draft = false }
            }
            touch(&agent)
        }
    }

    private static func touch(_ agent: inout UmiAttention.Agent) {
        agent.inputTouched = true
        agent.inputSeq &+= 1
    }

    /// The agent sent a prompt: its line is empty again unless something reached it after the last
    /// Enter (a draft typed while a queued prompt waited).
    private static func promptSent(_ agent: inout UmiAttention.Agent) {
        guard agent.inputSeq == agent.enterSeq else { return }
        agent.draft = false
        agent.draftChars = 0
        agent.inputTouched = false
    }

    /// Esc or Ctrl-C while the agent worked: interrupts fire no hook, so a turn with no hook for
    /// two seconds afterwards is taken as interrupted. A hook of the turn may still arrive just
    /// after the key (it was on its way): the two seconds then count from it, for up to ten seconds
    /// after the key.
    private static func interruptAsked(_ id: UUID, asked: Date = Date(), at check: Date? = nil) {
        let due = check ?? asked.addingTimeInterval(2)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, due.timeIntervalSinceNow)) {
            MainActor.assumeIsolated {
                let attention = UmiAttention.shared
                guard let agent = attention.agent(forPane: id), agent.status == .working || agent.status == .needsInput else { return }
                // A hook since the key that this check doesn't account for yet: two seconds from it.
                let next = agent.lastHookAt.addingTimeInterval(2)
                if agent.lastHookAt > asked, next > due.addingTimeInterval(0.01) {
                    if next < asked.addingTimeInterval(10) { interruptAsked(id, asked: asked, at: next) }
                    return
                }
                attention.update(id) {
                    $0.status = .idle
                    $0.idleInferred = true
                    $0.background = 0
                    $0.detail = nil
                    $0.lastStop = Date()
                }
            }
        }
    }

    // MARK: Desktop notifications (S-3)

    /// OSC 9/777 notifications dropped because an agent runs in the pane, and let through.
    private(set) static var droppedNotifications = 0
    private(set) static var passedNotifications = 0

    /// A desktop notification a pane's program asked for (OSC 9 or 777): dropped while an agent
    /// its plugin reports runs in the pane (Claude Code and Codex send them at each turn's end), as
    /// Warp drops them. Once the agent exits, the shell's notifications are Ghostty's. True: dropped.
    static func dropsDesktopNotification(fromPane id: UUID, title: String) -> Bool {
        guard UmiAttention.shared.agent(forPane: id)?.running == true else {
            passedNotifications += 1
            return false
        }
        droppedNotifications += 1
        UmiEvents.shared.emit("notify.dropped", ["pane": id.uuidString.lowercased(), "title": title])
        return true
    }

    // MARK: After a relaunch

    /// A restored pane ran an agent when the app last quit, crashed or updated: type its command
    /// again once the pane's shell is at its prompt (at most 15 s), resuming its conversation.
    static func restore(_ record: [String: Any], in pane: Ghostty.SurfaceView) {
        guard let kind = (record["kind"] as? String).flatMap(UmiAgentKind.init(rawValue:)),
              let command = record["command"] as? [String], !command.isEmpty else { return }
        let env = record["env"] as? [String: String] ?? [:]
        let line = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" } + command.map(shellQuote)
        // What `ls` shows until its hooks report: the agent, stopped, with its conversation.
        var agent = UmiAttention.Agent(kind: kind, status: .stopped)
        agent.session = record["session"] as? String
        agent.title = record["title"] as? String ?? ""
        agent.cwd = record["cwd"] as? String
        agent.conversation = record["conversation"] as? Bool ?? false
        agent.restart = command
        agent.env = env
        UmiAttention.shared.set(agent, forPane: pane.id)
        restoring.insert(pane.id)
        Task { @MainActor in
            defer { restoring.remove(pane.id) }
            let deadline = Date().addingTimeInterval(15)
            var waited = false
            while !UmiPaneContext.shellAtPrompt(pane) && Date() < deadline {
                waited = true
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if waited { try? await Task.sleep(nanoseconds: 300_000_000) }
            // Another program in front (the user started one): never type into it.
            guard UmiPaneContext.shellAtPrompt(pane) || UmiPaneContext.shellInFront(pane) else { return }
            UmiEvents.shared.emit("agent.restarted", ["pane": pane.umiID, "kind": kind.rawValue,
                                                       "session": agent.session ?? NSNull()])
            try? await UmiInput.send(text: line.joined(separator: " "), to: pane, enter: true)
        }
    }

    /// Labeled migration, for the update from Umi 0.9 (which ran sessions of its own): its saved
    /// layout names the session a pane showed (`agent`, a session id) instead of the command that
    /// brings the pane's agent back. A session whose own interface ran in that pane (an agent the
    /// user typed, or one taken over) is rebuilt from its record (`sessions/<id>/session.json`) as
    /// the command Umi 0.9 would have run there. A session Umi ran headless had no process in the
    /// pane and isn't brought back. Remove once no installed copy is older than 0.10.
    static func restartRecord(fromSession id: String) -> [String: Any]? {
        guard !id.contains("/"), !id.contains(".."),
              let data = FileManager.default.contents(atPath: UmiPaths.path("sessions") + "/\(id)/session.json"),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              json["live"] as? Bool == true,
              let kind = (json["kind"] as? String).flatMap(UmiAgentKind.init(rawValue:)),
              let session = json["harnessID"] as? String, !session.isEmpty else { return nil }
        let conversation = kind == .codex || json["conversation"] as? Bool == true
        var command = [kind.rawValue]
        let model = json["model"] as? String
        let effort = json["effort"] as? String
        let mode = json["permissionMode"] as? String
        let full = json["fullAccess"] as? Bool ?? false
        switch kind {
        case .claude:
            if let model { command += ["--model", model] }
            if let effort { command += ["--effort", effort] }
            if full { command.append("--dangerously-skip-permissions") } else if let mode { command += ["--permission-mode", mode] }
            command += json["harnessArgs"] as? [String] ?? []
            if conversation { command += ["--resume", session] }
        case .codex:
            command += ["resume", session]
            if let model { command += ["-m", model] }
            if let effort { command += ["-c", "model_reasoning_effort=\(effort)"] }
            if let profile = json["profile"] as? String { command += ["-p", profile] }
            if full { command.append("--dangerously-bypass-approvals-and-sandbox") } else if let mode { command += ["-a", mode] }
        }
        var out: [String: Any] = ["kind": kind.rawValue, "session": session, "command": command, "conversation": conversation]
        let env = (json["env"] as? [String: String] ?? [:]).filter { ["CLAUDE_CONFIG_DIR", "CODEX_HOME"].contains($0.key) }
        if !env.isEmpty { out["env"] = env }
        if let cwd = json["cwd"] as? String { out["cwd"] = cwd }
        if let title = json["title"] as? String { out["title"] = title }
        return out
    }

    /// Panes whose agent is being typed again after a relaunch (an update waits for them).
    private(set) static var restoring: Set<UUID> = []

    /// Quote a word for a POSIX shell.
    static func shellQuote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-~")
        if word.unicodeScalars.allSatisfy({ safe.contains($0) }) && !word.hasPrefix("~") { return word }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

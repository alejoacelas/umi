import AppKit
import Darwin
import GhosttyKit

/// A quiet moment (I-4): when Umi may quit and relaunch to install an update with nothing lost
/// and nobody interrupted. All of these hold, and anything Umi can't be sure of counts as busy:
/// - every pane is at its own shell's prompt with nothing typed and nothing else running there,
///   or runs an agent (Claude Code, Codex) whose `agent.status` is idle with nothing typed in it
///   and nothing it started still running;
/// - no editor document has unsaved changes, and no dialog, sheet or text field is in use (a web
///   pane counts as quiet: its page keeps unsaved drafts in its local storage, which survives the
///   relaunch, E-12);
/// - nobody has typed or clicked in Umi for two minutes.
///
/// `reasons(in:)` decides from a snapshot (the unit tests give it made-up ones); `snapshot()`
/// reads the app as it is now.
enum UmiQuiet {
    /// One thing that keeps this moment from being quiet.
    struct Reason: Equatable {
        enum Kind: String { case pane, editor, dialog, input }
        let kind: Kind
        let text: String
        var pane: String?
        var tab: String?

        var json: [String: Any] {
            var out: [String: Any] = ["kind": kind.rawValue, "reason": text]
            if let pane { out["pane"] = pane }
            if let tab { out["tab"] = tab }
            return out
        }

        /// For people: `pane 1a2b3c4d (tab "build"): running make`.
        var line: String {
            switch kind {
            case .pane:
                var where_ = "pane \(pane.map { String($0.prefix(8)) } ?? "?")"
                if let tab { where_ += " (tab \"\(tab)\")" }
                return "\(where_): \(text)"
            default: return text
            }
        }
    }

    /// What a pane holds, as far as Umi can tell.
    enum PaneState: Equatable {
        /// Its own shell, at an empty prompt, with nothing else running.
        case prompt
        /// Its own shell, at a prompt with something typed.
        case typed
        /// A program in front (its name).
        case running(String)
        /// Its own shell in front, with a job of its own still running.
        case job(String)
        /// Can't tell (why).
        case unknown(String)
        /// Its process has exited: nothing runs there.
        case exited
        /// An agent its plugin reports, in front. `busy`: why it isn't idle with nothing typed
        /// (nil: it is).
        case agent(busy: String?)
    }

    struct Pane: Equatable {
        let id: String
        let tab: String
        let state: PaneState
    }

    struct Snapshot {
        var panes: [Pane] = []
        /// Editor documents with unsaved changes.
        var unsaved: [String] = []
        /// Dialogs, sheets and text fields in use.
        var dialogs: [String] = []
        var lastInput: Date
        var now: Date
        /// How long nobody may have typed or clicked.
        var idle: TimeInterval
    }

    /// Everything that keeps the moment from being quiet: none means quiet.
    static func reasons(in snapshot: Snapshot) -> [Reason] {
        var out: [Reason] = []
        for pane in snapshot.panes {
            func add(_ text: String) { out.append(Reason(kind: .pane, text: text, pane: pane.id, tab: pane.tab)) }
            switch pane.state {
            case .prompt, .exited, .agent(busy: nil):
                continue
            case .typed: add("something is typed at its prompt")
            case .running(let name): add("\(name) is running")
            case .job(let name): add("\(name) is running in the background")
            case .unknown(let why): add("can't tell whether it's idle (\(why))")
            case .agent(busy: let busy?): add(busy)
            }
        }
        for name in snapshot.unsaved {
            out.append(Reason(kind: .editor, text: "\(name) has unsaved changes"))
        }
        for dialog in snapshot.dialogs {
            out.append(Reason(kind: .dialog, text: dialog))
        }
        let since = snapshot.now.timeIntervalSince(snapshot.lastInput)
        if since < snapshot.idle {
            out.append(Reason(kind: .input, text: "someone typed or clicked in \(UmiPaths.productName) \(Int(since)) s ago "
                              + "(it waits for \(Int(snapshot.idle)) s without)"))
        }
        return out
    }

    // MARK: Time and the user's activity

    /// Fake time for scripted checks (`debug.update.clock`, isolated instances only).
    @MainActor
    static var clockOffset: TimeInterval = 0
    @MainActor
    static var now: Date { Date().addingTimeInterval(clockOffset) }

    /// When someone last typed or clicked in the app (launching counts).
    @MainActor
    private(set) static var lastInput = Date()
    @MainActor
    private static var monitor: Any?

    /// How long nobody may have typed or clicked: two minutes (isolated instances may shorten
    /// it, UMI_UPDATE_IDLE_SECONDS).
    @MainActor
    static var idleInterval: TimeInterval { UmiUpdater.seconds("UMI_UPDATE_IDLE_SECONDS", default: 120) }

    @MainActor
    static func start() {
        guard monitor == nil else { return }
        lastInput = now
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        ) { event in
            MainActor.assumeIsolated { userActed() }
            return event
        }
    }

    /// Someone typed or clicked in the app (or a check says they did).
    @MainActor
    static func userActed() {
        lastInput = now
        UmiUpdater.shared.userActed()
    }

    // MARK: Reading the app

    @MainActor
    static func reasons() -> [Reason] { reasons(in: snapshot()) }

    @MainActor
    static func report() -> [String: Any] {
        let found = reasons()
        return ["quiet": found.isEmpty, "waiting_for": found.map(\.json),
                "idle_seconds": Int(now.timeIntervalSince(lastInput))]
    }

    @MainActor
    static func snapshot() -> Snapshot {
        var snapshot = Snapshot(lastInput: lastInput, now: now, idle: idleInterval)
        let processes = Processes()
        var seen = Set<UUID>()
        func add(_ pane: Ghostty.SurfaceView, tab: String) {
            guard seen.insert(pane.id).inserted else { return }
            var state = paneState(pane, agent: UmiAttention.shared.agent(forPane: pane.id), processes: processes)
            // An agent being typed again after a relaunch hasn't said what it does yet.
            if UmiAgentHooks.restoring.contains(pane.id), state == .prompt || state == .typed {
                state = .agent(busy: "its agent is starting again after the relaunch")
            }
            snapshot.panes.append(Pane(id: pane.umiID, tab: tab, state: state))
        }
        for controller in TerminalController.all where !controller.isClosed {
            for tab in controller.tabs {
                for pane in tab.panes { add(pane, tab: tab.title) }
                for doc in tab.editor.documents where doc.isDirty { snapshot.unsaved.append(doc.name) }
            }
            if controller.palette.isPresented { snapshot.dialogs.append("the command palette is open") }
        }
        if let delegate = NSApp.delegate as? AppDelegate, delegate.quickControllerInitialized {
            for pane in delegate.quickController.surfaceTree.root?.leaves() ?? [] { add(pane, tab: "(quick terminal)") }
        }

        if NSApp.modalWindow != nil { snapshot.dialogs.append("a dialog is open") }
        for window in NSApp.windows where window.isVisible {
            if window.attachedSheet != nil { snapshot.dialogs.append("a dialog is open in a window") }
            if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, !editor.string.isEmpty {
                snapshot.dialogs.append("a text field is being edited")
            }
        }
        return snapshot
    }

    /// Every process, read once per snapshot.
    struct Processes {
        let byPID: [pid_t: UmiProcessTree.Info]
        let children: [pid_t: [pid_t]]
        let fronts: [dev_t: pid_t]
        let onTerminal: [dev_t: [pid_t]]

        init() {
            let infos = UmiProcessTree.all(everyone: true)
            var byPID: [pid_t: UmiProcessTree.Info] = [:]
            var children: [pid_t: [pid_t]] = [:]
            var fronts: [dev_t: pid_t] = [:]
            var onTerminal: [dev_t: [pid_t]] = [:]
            for info in infos {
                byPID[info.pid] = info
                if !info.zombie { children[info.ppid, default: []].append(info.pid) }
                if info.tpgid > 0 {
                    fronts[info.tdev] = info.tpgid
                    onTerminal[info.tdev, default: []].append(info.pid)
                }
            }
            self.byPID = byPID
            self.children = children
            self.fronts = fronts
            self.onTerminal = onTerminal
        }

        /// The pane's own shell, and the `login` it runs under: the processes on its terminal that
        /// the app started (Ghostty runs `login`, which runs the shell).
        func shell(onTerminal device: dev_t, app: pid_t) -> (login: pid_t, shell: pid_t)? {
            let mine = onTerminal[device] ?? []
            guard let first = mine.first(where: { byPID[$0]?.ppid == app }) else { return nil }
            return (first, mine.first { byPID[$0]?.ppid == first } ?? first)
        }

        func descendants(of root: pid_t) -> [pid_t] {
            var out: [pid_t] = []
            var stack = children[root] ?? []
            while let pid = stack.popLast(), out.count < 4096 {
                out.append(pid)
                stack += children[pid] ?? []
            }
            return out
        }
    }

    /// Helpers a shell runs for its prompt that live as long as it does, and `caffeinate`, which
    /// agents run to keep the Mac awake: they hold no work.
    static let promptHelpers: Set<String> = ["gitstatusd", "gitstatusd-darwin-arm64", "caffeinate"]

    /// What a pane's terminal holds. `agent`: what its plugin reports about the pane's agent.
    @MainActor
    static func paneState(_ pane: Ghostty.SurfaceView, agent: UmiAttention.Agent?, processes: Processes) -> PaneState {
        guard let surface = pane.surface else { return .unknown("it has no terminal") }
        if ghostty_surface_process_exited(surface) { return .exited }
        // Text being composed with an input method isn't on the terminal yet.
        if pane.hasMarkedText() { return .typed }
        guard let tty = pane.surfaceModel?.ttyName else { return .unknown("its terminal has no device") }
        var info = stat()
        guard stat(tty, &info) == 0, let front = processes.fronts[info.st_rdev] else {
            return .unknown("no process is in front of its terminal")
        }
        guard let (login, shell) = processes.shell(onTerminal: info.st_rdev, app: getpid()) else {
            return .unknown("its shell can't be found")
        }
        // Whatever the shell started besides what is in front (and what that started) is a job a
        // relaunch would end: `sleep 600 &`, a suspended program, a server left running.
        // (Without job control a job stays in the shell's own group: with the shell in front,
        // every process it started counts.)
        let inFront: Set<pid_t> = front == shell ? [] : Set([front] + processes.descendants(of: front))
        for pid in processes.descendants(of: shell)
        where !inFront.contains(pid) && (front == shell || processes.byPID[pid]?.pgid != front) {
            let job = UmiProcess.name(pid) ?? "a process"
            if !promptHelpers.contains(job) { return .job(job) }
        }
        // A job that left the shell (`(cmd &)`, reparented to launchd) but still runs on its
        // terminal, which a relaunch would close under it.
        for pid in processes.onTerminal[info.st_rdev] ?? []
        where pid != login && pid != shell && !inFront.contains(pid) && processes.byPID[pid]?.zombie != true {
            let job = UmiProcess.name(pid) ?? "a process"
            if !promptHelpers.contains(job) { return .job(job) }
        }
        if front != shell {
            // The agent its hooks report, known by its process: never by its arguments.
            if let agent, agent.running {
                let group = agent.pid.flatMap { processes.byPID[$0]?.pgid }
                if group == front {
                    // Anything the agent runs: its hooks (Claude Code runs an event's hooks side by
                    // side, so the user's own Stop hook may still build after Umi's says the turn is
                    // done), its commands, and the servers it keeps (MCP), which Umi can't tell from
                    // work by their processes. Only `caffeinate`, run with a timeout to keep the Mac
                    // awake, holds nothing.
                    for pid in processes.descendants(of: front) {
                        guard let info = processes.byPID[pid], !info.zombie else { continue }
                        let job = UmiProcess.name(pid) ?? "a process"
                        if !promptHelpers.contains(job) { return .job("\(job), started by its agent,") }
                    }
                    return .agent(busy: agentBusy(agent))
                }
            }
            // A program, or a shell started from the pane's shell.
            return .running(UmiProcess.name(front) ?? "a program")
        }
        switch ghostty_surface_umi_prompt_state(surface) {
        case 1: return .prompt
        case 2: return .typed
        default: return .unknown("its shell doesn't mark its prompt")
        }
    }
}

extension UmiQuiet {
    /// Why an agent in front of its pane keeps the moment from being quiet (nil: its
    /// `agent.status` is idle and nothing is typed in it).
    static func agentBusy(_ agent: UmiAttention.Agent) -> String? {
        if agent.draft { return "something is typed in its agent" }
        if agent.inputTouched {
            return "its agent's input line may hold text (an update waits until a prompt is sent or the agent exits)"
        }
        if agent.idleInferred { return "its agent was interrupted from the keyboard; it waits for the agent to say it is idle" }
        switch agent.status {
        case .idle: return nil
        case .working: return agent.background > 0 ? "its agent is working (\(agent.background) background task\(agent.background == 1 ? "" : "s"))" : "its agent is working"
        case .needsInput: return "its agent is waiting for you" + (agent.detail.map { " (\($0))" } ?? "")
        case .error: return "its agent's last turn failed"
        case .stopped: return "its agent stopped but is still in front"
        }
    }
}

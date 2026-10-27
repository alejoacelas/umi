import AppKit
import Darwin
import GhosttyKit

/// A quiet moment (I-4): when Umi may quit and relaunch to install an update with nothing lost
/// and nobody interrupted. All of these hold, and anything Umi can't be sure of counts as busy:
/// - no agent turn runs in any session Umi knows (started by Umi or typed in a pane, AG-18), and
///   no message waits to be delivered;
/// - every pane is at its own shell's prompt with nothing typed and nothing else running there,
///   or shows an idle agent: its own interface (Claude Code, Codex) idle with nothing typed in
///   it, or a session's read-only view;
/// - no editor document has unsaved changes, and no dialog, sheet or text field is in use;
/// - nobody has typed or clicked in Umi for two minutes.
///
/// `reasons(in:)` decides from a snapshot (the unit tests give it made-up ones); `snapshot()`
/// reads the app as it is now.
enum UmiQuiet {
    /// One thing that keeps this moment from being quiet.
    struct Reason: Equatable {
        enum Kind: String { case session, pane, editor, dialog, input }
        let kind: Kind
        let text: String
        var pane: String?
        var tab: String?
        var session: String?
        var sessionName: String?

        var json: [String: Any] {
            var out: [String: Any] = ["kind": kind.rawValue, "reason": text]
            if let pane { out["pane"] = pane }
            if let tab { out["tab"] = tab }
            if let session { out["session"] = session }
            if let sessionName { out["name"] = sessionName }
            return out
        }

        /// For people: `pane 1a2b3c4d (tab "build"): running make`.
        var line: String {
            switch kind {
            case .session: return "session \(sessionName ?? session ?? "?"): \(text)"
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
        /// A session's read-only view (the session's id).
        case view(String)
        /// A session's own interface, in front (the session's id).
        case live(String)
    }

    struct Pane: Equatable {
        let id: String
        let tab: String
        let state: PaneState
    }

    /// A session Umi knows: `busy` says why it isn't idle with nothing waiting (nil: it is).
    struct Session: Equatable {
        let id: String
        let name: String
        let busy: String?
    }

    struct Snapshot {
        var panes: [Pane] = []
        var sessions: [Session] = []
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
        var known: [String: Session] = [:]
        for session in snapshot.sessions {
            known[session.id] = session
            if let busy = session.busy {
                out.append(Reason(kind: .session, text: busy, session: session.id, sessionName: session.name))
            }
        }
        for pane in snapshot.panes {
            func add(_ text: String) { out.append(Reason(kind: .pane, text: text, pane: pane.id, tab: pane.tab)) }
            switch pane.state {
            case .prompt, .exited, .view:
                // A read-only view has nothing to lose; its session is judged above.
                continue
            case .typed: add("something is typed at its prompt")
            case .running(let name): add("\(name) is running")
            case .job(let name): add("\(name) is running in the background")
            case .unknown(let why): add("can't tell whether it's idle (\(why))")
            case .live(let id):
                if known[id] == nil { add("an agent interface that isn't a session Umi knows") }
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
        struct Live { let id: String; let kind: UmiAgentKind; let pid: Int32?; let pane: String? }
        let (sessions, live): ([Session], [Live]) = UmiAgents.queue.sync {
            let all = UmiAgents.shared.sessions
            return (all.map { Session(id: $0.record.id, name: $0.record.name, busy: $0.quietBlocker) },
                    all.filter { $0.record.live == true }.map {
                        Live(id: $0.record.id, kind: $0.record.kind, pid: $0.record.livePID, pane: $0.record.pane)
                    })
        }
        snapshot.sessions = sessions

        let processes = Processes()
        let ui = UmiAgentUI.shared
        var seen = Set<UUID>()
        func add(_ pane: Ghostty.SurfaceView, tab: String) {
            guard seen.insert(pane.id).inserted else { return }
            let umiID = pane.umiID
            let state: PaneState
            if ui.isShowingAgent(pane.id), let id = ui.attachments[pane.id] {
                // The view covers a terminal of its own, which may have been used meanwhile.
                let under = paneState(pane, live: nil, processes: processes)
                state = under == .prompt || under == .exited ? .view(id) : under
            } else {
                let attached = ui.livePanes.contains(pane.id) ? ui.attachments[pane.id] : nil
                let session = live.first { $0.id == attached } ?? live.first { $0.pane == umiID }
                state = paneState(pane, live: session.map { ($0.id, $0.kind, $0.pid) }, processes: processes)
            }
            snapshot.panes.append(Pane(id: umiID, tab: tab, state: state))
        }
        for controller in TerminalController.all where !controller.isClosed {
            for tab in controller.tabs {
                for pane in tab.panes { add(pane, tab: tab.title) }
                for doc in tab.editor.documents where doc.isDirty { snapshot.unsaved.append(doc.name) }
            }
            if controller.palette.isPresented { snapshot.dialogs.append("the command palette is open") }
        }
        // Panes kept out of sight while a removed session's interface finishes (AG-8).
        for pane in ui.parked.values { add(pane, tab: "(removed from its tab)") }
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

        /// The pane's own shell: the process on its terminal that the app started, directly or
        /// through `login` (Ghostty runs `login`, which runs the shell).
        func shell(onTerminal device: dev_t, app: pid_t) -> pid_t? {
            let mine = onTerminal[device] ?? []
            guard let first = mine.first(where: { byPID[$0]?.ppid == app }) else { return nil }
            return mine.first { byPID[$0]?.ppid == first } ?? first
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

    /// Helpers a shell runs for its prompt that live as long as it does; they hold no work.
    static let promptHelpers: Set<String> = ["gitstatusd", "gitstatusd-darwin-arm64"]

    /// What a pane's terminal holds. `live`: the session whose own interface Umi shows there.
    @MainActor
    static func paneState(_ pane: Ghostty.SurfaceView, live: (id: String, kind: UmiAgentKind, pid: Int32?)?,
                          processes: Processes) -> PaneState {
        guard let surface = pane.surface else { return .unknown("it has no terminal") }
        if ghostty_surface_process_exited(surface) { return .exited }
        guard let tty = pane.surfaceModel?.ttyName else { return .unknown("its terminal has no device") }
        var info = stat()
        guard stat(tty, &info) == 0, let front = processes.fronts[info.st_rdev] else {
            return .unknown("no process is in front of its terminal")
        }
        guard let shell = processes.shell(onTerminal: info.st_rdev, app: getpid()) else {
            return .unknown("its shell can't be found")
        }
        // Whatever the shell started besides what is in front (and what that started) is a job a
        // relaunch would end: `sleep 600 &`, a suspended program, a server left running.
        let inFront: Set<pid_t> = front == shell ? [] : Set([front] + processes.descendants(of: front))
        for pid in processes.descendants(of: shell) where !inFront.contains(pid) && processes.byPID[pid]?.pgid != front {
            let job = UmiProcess.name(pid) ?? "a process"
            if !promptHelpers.contains(job) { return .job(job) }
        }
        if front != shell {
            // The session's own interface, known by its process (from its hooks) or by the session
            // its environment names (Umi started it): never by its arguments.
            if let live {
                let group = live.pid.flatMap { processes.byPID[$0]?.pgid }
                if group == front || UmiProcessTree.environment(front)?["UMI_SESSION_ID"] == live.id {
                    return .live(live.id)
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

extension UmiAgentSession {
    /// Why this session keeps the moment from being quiet (nil: it's idle and nothing waits).
    var quietBlocker: String? {
        if !queue.isEmpty { return "\(queue.count) message\(queue.count == 1 ? "" : "s") waiting to be delivered" }
        if !inFlight.isEmpty { return "a message is being delivered" }
        // Commands its agent left running after its turn (Codex's background terminals): a
        // relaunch would end them.
        if let tasks = backgroundTasks, tasks > 0 {
            return "\(tasks) background command\(tasks == 1 ? "" : "s") still running"
        }
        // Any interface of its own in a pane, Codex's attached one included.
        if record.live == true, liveDraft { return "something is typed in its interface" }
        if record.live == true, liveInputUnsure {
            return "its interface may have a prompt from its history on its input line (send or clear it)"
        }
        switch status {
        case "working": return activityText == "working" ? "a turn is running" : "a turn is running (\(activityText))"
        case "starting": return "it is starting"
        case "needs_input": return "it is waiting for you (\(activityText))"
        default: break
        }
        if goingLive || reclaiming { return "its interface is opening or closing" }
        if exclusiveLive, liveState != .idle { return "its interface is busy" }
        return nil
    }
}

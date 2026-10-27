import AppKit

// The app side of headless and live (AG-5 to AG-9): typing the attach command into a pane,
// taking over, removing a session from its pane (parked out of sight while its interface
// finishes), and what the sidebar and Dock show about sessions (UmiAttention).
@MainActor
extension UmiAgentUI {
    static func surface(umiID: String) -> Ghostty.SurfaceView? {
        UmiTopology.allSurfaces.first { $0.umiID == umiID }
    }

    // MARK: Going live

    /// Run the session's own interface in its pane: the read-only view steps aside and the
    /// pane's shell runs `umi agent attach` (which stops a headless turn, for Claude, and
    /// execs the agent's interface).
    static func typeAttach(pane: String, session: String, selector: String) {
        guard let surface = surface(umiID: pane) else {
            // The pane is gone (closed, or not restored): nothing to go live in.
            UmiAgents.queue.async {
                guard let s = UmiAgents.shared.session(id: session) else { return }
                if s.record.pane == pane { s.record.pane = nil }
                s.record.goLiveWhenSettled = nil
                s.goingLive = false
                s.saveRecord()
                s.changed()
                s.pump()
            }
            return
        }
        shared.attachments[surface.id] = session
        shared.livePanes.insert(surface.id)
        shared.showingTerminal.remove(surface.id)
        UmiState.shared.layoutDidChange()
        // Shell-quoted: a name may hold spaces, quotes or anything else.
        let quoted = selector.allSatisfy { $0.isLetter || $0.isNumber || "-_.~".contains($0) }
            ? selector : "'" + selector.replacingOccurrences(of: "'", with: "'\\''") + "'"
        Task { @MainActor in
            // An interface still on its way out (Claude Code prints its resume hint after its
            // SessionEnd hook) would swallow the line, and so does a shell that hasn't started
            // reading again: wait for its prompt (at most 10 s), then a moment for its line editor.
            let deadline = Date().addingTimeInterval(10)
            var waited = false
            while !UmiPaneContext.shellAtPrompt(surface) && Date() < deadline {
                waited = true
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if waited { try? await Task.sleep(nanoseconds: 300_000_000) }
            // Still another program in front (an editor, `cat > file`…): never type into it.
            // (A shell without shell integration shows no prompt mark but is in front.)
            guard UmiPaneContext.shellAtPrompt(surface) || UmiPaneContext.shellInFront(surface) else {
                shared.livePanes.remove(surface.id)
                UmiState.shared.layoutDidChange()
                UmiAgents.queue.async {
                    guard let s = UmiAgents.shared.session(id: session) else { return }
                    s.goingLive = false
                    s.notice("Couldn't open its interface here: another program is running in the pane's terminal.")
                    s.changed()
                    s.pump()
                }
                return
            }
            // `$UMI_CLI` is this app's own CLI (an older `umi` elsewhere on PATH must not answer).
            try? await UmiInput.send(text: "\"$UMI_CLI\" agent attach \(quoted)", to: surface, enter: true)
        }
        if UmiLayout.isFocusedPane(surface) {
            DispatchQueue.main.async { Ghostty.moveFocus(to: surface) }
        }
    }

    /// The Take Over button: at once, in this pane.
    func takeOver(_ surface: Ghostty.SurfaceView, session: String) {
        let pane = surface.umiID
        UmiAgents.queue.async {
            guard let s = UmiAgents.shared.session(id: session) else { return }
            s.record.pane = pane
            s.saveRecord()
            let selector = s.attachSelector
            DispatchQueue.main.async {
                MainActor.assumeIsolated { UmiAgentUI.typeAttach(pane: pane, session: session, selector: selector) }
            }
        }
        DispatchQueue.main.async { Ghostty.moveFocus(to: surface) }
    }

    /// The live interface ended: the pane shows the read-only view again, or (removed from
    /// its pane) the parked terminal goes away.
    static func liveEnded(session: String, pane: String?, keepView: Bool = true) {
        if let parkedSurface = shared.parked.removeValue(forKey: session) {
            shared.livePanes.remove(parkedSurface.id)
            shared.attachments.removeValue(forKey: parkedSurface.id)
            // Dropping the last reference closes the terminal (its shell gets SIGHUP).
            _ = parkedSurface
            return
        }
        guard let pane, let surface = surface(umiID: pane) else { return }
        shared.livePanes.remove(surface.id)
        if !keepView, shared.attachments[surface.id] == session {
            shared.attachments.removeValue(forKey: surface.id)
        }
        if shared.attachments[surface.id] == session {
            shared.showingTerminal.remove(surface.id)
            if UmiLayout.isFocusedPane(surface) {
                DispatchQueue.main.async { shared.focusAgentView(of: surface) }
            }
        }
        UmiState.shared.layoutDidChange()
    }

    /// End a live interface by signalling its processes in the pane (Codex's interface, or one
    /// whose process Umi doesn't know).
    static func closeLiveInterface(session: String, pane: String?) {
        let target = pane
        DispatchQueue.global().async {
            for info in UmiProcessTree.all() where info.pid > 1 {
                guard let env = UmiProcessTree.environment(info.pid) else { continue }
                guard env["UMI_STATE_DIR"] == UmiPaths.stateDirectory else { continue }
                let mine = env["UMI_SESSION_ID"] == session && (target == nil || env["UMI_PANE_ID"] == target)
                if mine, env["UMI_HEADLESS"] == nil { kill(info.pid, SIGTERM) }
            }
        }
    }

    /// A command ended in a pane where a session's interface ran: if it was the interface (its
    /// process is gone), the session is headless again. Claude's interface also says so through
    /// its SessionEnd hook; Codex's (a client of Umi's server) has no hooks of its own.
    func commandFinished(in surface: Ghostty.SurfaceView) {
        guard livePanes.contains(surface.id), let session = attachments[surface.id] else { return }
        UmiAgents.queue.async {
            guard let s = UmiAgents.shared.session(id: session), s.record.live == true,
                  s.record.pane == surface.umiID else { return }
            if let pid = s.record.livePID, kill(pid, 0) == 0 { return }
            s.liveEnded()
        }
    }

    // MARK: Typing in a live interface

    func keyTyped(pane: Ghostty.SurfaceView, event: NSEvent) {
        guard let session = attachments[pane.id] ?? Self.sessionLive(in: pane.id) else { return }
        let chars = event.charactersIgnoringModifiers ?? ""
        let control = event.modifierFlags.contains(.control)
        let input: LiveInput
        if control && chars.lowercased() == "c" {
            input = .interrupt
        } else if event.keyCode == 53 {                          // esc
            input = .escape
        } else if [125, 126].contains(event.keyCode) && event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
            input = .history                                      // up, down: may recall a prompt
        } else if event.keyCode == 36 || event.keyCode == 76 {   // return, enter
            input = .submit
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
        Self.liveInput(session: session, input)
    }

    /// Edit > Paste (or its key) in a live interface: the pasted text is typed text there.
    func pasted(pane: Ghostty.SurfaceView, text: String?) {
        guard let session = attachments[pane.id] ?? Self.sessionLive(in: pane.id) else { return }
        Self.liveInput(session: session, .text(max(1, text?.count ?? 1)))
    }

    /// Text and keys put into a pane through Umi (`umi send`, `umi keys`): agents and scripts
    /// type into a live interface this way, so it counts like the keyboard (AG-9, AG-19).
    func inputSent(pane: Ghostty.SurfaceView, text: String, keys: [String]) {
        guard let session = attachments[pane.id] ?? Self.sessionLive(in: pane.id) else { return }
        if !text.isEmpty { Self.liveInput(session: session, .text(text.count)) }
        for key in keys {
            let spec = key.lowercased()
            let input: LiveInput
            if ["ctrl+c", "control+c", "c+c"].contains(spec) {
                input = .interrupt
            } else if ["esc", "escape"].contains(spec) {
                input = .escape
            } else if ["up", "down", "arrowup", "arrowdown"].contains(spec) {
                input = .history
            } else if ["enter", "return", "ret", "cr", "nl"].contains(spec) {
                input = .submit
            } else if ["ctrl+u", "control+u", "c+u"].contains(spec) {
                input = .clear
            } else if ["backspace", "bs"].contains(spec) {
                input = .delete
            } else if ["up", "down", "left", "right", "pgup", "pgdn", "pageup", "pagedown", "home", "end", "delete", "del"]
                        .contains(spec) || spec.hasPrefix("arrow") || spec.hasPrefix("cmd+") || spec.hasPrefix("command+") {
                input = .other
            } else if spec.contains("+") {
                input = .edit
            } else {
                input = .text(1)
            }
            Self.liveInput(session: session, input)
        }
    }

    /// What a key (or text) does to the live interface's input line, as far as Umi can tell.
    enum LiveInput {
        case interrupt, escape, history, submit, clear, delete, other, edit
        case text(Int)
    }

    private static func liveInput(session: String, _ input: LiveInput) {
        UmiAgents.queue.async {
            guard let s = UmiAgents.shared.session(id: session), s.record.live == true else { return }
            switch input {
            case .submit:
                s.lastLiveKey = Date()   // UserPromptSubmit says whether something was sent
            case .clear:
                s.liveDraftCleared()     // Ctrl-U empties the input line
            case .interrupt:
                s.liveKey(interrupt: true, typed: 0)
            case .escape:
                // Interrupts a turn like Ctrl-C, but at the prompt it leaves what was typed.
                s.liveKey(interrupt: true, typed: 0, clearsInput: false)
            case .history:
                s.liveHistory()
            case .delete:
                s.liveKey(interrupt: false, typed: -1)
            case .text(let count):
                s.liveKey(interrupt: false, typed: count)
            case .edit:
                // Something changed the line by an amount Umi can't tell (a word deleted, Ctrl-P
                // or Ctrl-N recalling a prompt, Ctrl-G opening an editor): if text was typed, it
                // still counts as typed, and the line may now hold text Umi didn't see.
                s.liveKey(interrupt: false, typed: 0)
                s.liveInputMayHoldText()
            case .other:
                s.lastLiveKey = Date()
                s.changed()
            }
        }
    }

    /// A session live in a pane that has no attachment (typed `claude`, adopted by its hooks).
    static func sessionLive(in pane: UUID) -> String? {
        let umiID = pane.uuidString.lowercased()
        return UmiAgents.queue.sync {
            UmiAgents.shared.sessions.first { $0.record.live == true && $0.record.pane == umiID }?.record.id
        }
    }

    // MARK: The focused pane's session (Window > Take Over Session, Remove Session from Pane)

    /// The focused pane of the key window (or of Umi's current window), wherever keyboard focus
    /// is, when it shows a session. `live`: only a live one (true), only a read-only one (false).
    static func focusedSessionPane(live: Bool?) -> (Ghostty.SurfaceView, String)? {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? UmiTopology.currentWindow
        guard let pane = controller?.focusedSurface,
              let session = shared.session(forPane: pane.id) ?? sessionLive(in: pane.id) else { return nil }
        if let live, shared.livePanes.contains(pane.id) != live { return nil }
        return (pane, session)
    }

    @discardableResult
    static func takeOverFocused() -> Bool {
        guard let (pane, session) = focusedSessionPane(live: false) else { return false }
        shared.takeOver(pane, session: session)
        return true
    }

    @discardableResult
    static func removeFocusedFromPane() -> Bool {
        guard let (pane, _) = focusedSessionPane(live: nil) else { return false }
        shared.removeFromPane(pane)
        return true
    }

    // MARK: Removing a session from its pane (AG-8)

    /// The shortcut: the session in this pane keeps running out of sight.
    func removeFromPane(_ surface: Ghostty.SurfaceView) {
        guard let session = attachments[surface.id] ?? Self.sessionLive(in: surface.id) else {
            NSSound.beep()
            return
        }
        try? Self.hide(sessionID: session)
    }

    /// `agent hide` / the shortcut.
    static func hide(sessionID: String) throws {
        let result: (UmiAgentSession.HideAction, String?)? = UmiAgents.queue.sync {
            guard let s = UmiAgents.shared.session(id: sessionID) else { return nil }
            let pane = s.record.pane
            return (s.hide(), pane)
        }
        guard let (action, pane) = result else { throw UmiError.notFound("no such session") }
        let found = pane.flatMap { UmiAgentUI.surface(umiID: $0) }
            ?? UmiTopology.allSurfaces.first { shared.attachments[$0.id] == sessionID }
        let surface = found
        switch action {
        case .nothing:
            if surface == nil { throw UmiError.failed("the session isn't shown in a pane") }
            fallthrough
        case .closePane:
            guard let surface else { return }
            shared.attachments.removeValue(forKey: surface.id)
            shared.livePanes.remove(surface.id)
            shared.showingTerminal.remove(surface.id)
            try? UmiLayout.closePane(surface)
        case .parkPane:
            guard let surface else { return }
            // Out of the layout, still running: the live interface finishes its turn.
            shared.parked[sessionID] = surface
            UmiLayout.detach(surface)
        }
        UmiState.shared.layoutDidChange()
        UmiAgentMenu.shared.setNeedsRebuild()
    }

    /// A parked live interface shown again (`agent open` before it finished).
    static func unpark(_ sessionID: String, placement: UmiAgentRPC.Placement, caller: UmiCaller) throws -> Ghostty.SurfaceView? {
        guard let surface = shared.parked.removeValue(forKey: sessionID) else { return nil }
        // Where it was asked to go, worked out before anything changes (a bad target leaves it
        // parked): beside a pane, in a new window, or a new tab of a window.
        var destination: UmiLayout.PaneDestination?
        var window: TerminalController?
        do {
            let callerPane = (try? UmiTopology.callerPane(caller)) ?? nil
            switch placement.kind {
            case .split:
                let target = try placement.pane.map { try UmiTopology.resolvePane($0, caller: caller) } ?? callerPane
                    ?? UmiTopology.currentPane
                if let target { destination = .besidePane(target, try UmiLayout.direction(placement.direction)) }
                else { destination = .newWindow }
            case .window:
                destination = .newWindow
            case .tab:
                window = try placement.window.map { try UmiTopology.resolveWindow($0, caller: caller) }
                    ?? callerPane.flatMap { UmiTopology.locate($0)?.window }
            }
        } catch {
            shared.parked[sessionID] = surface
            throw error
        }
        guard let home = window ?? UmiTopology.currentWindow ?? UmiTopology.windows.first else {
            shared.parked[sessionID] = surface
            return nil
        }
        UmiLayout.adopt(surface, intoNewTabOf: home, focus: placement.focus && destination == nil)
        if let destination {
            // From its new tab to the place asked for (the tab goes away with it).
            _ = try? UmiLayout.move(surface, to: destination, focus: placement.focus)
        }
        UmiAgents.queue.async {
            guard let s = UmiAgents.shared.session(id: sessionID) else { return }
            s.endLiveWhenSettled = false
            s.record.pane = surface.umiID
            s.saveRecord()
            s.changed()
        }
        return surface
    }

    // MARK: What the chrome shows (UmiAttention)

    /// Called with every session update on the main thread.
    static func publishAttention(_ snapshot: UmiAgentSnapshot, previous: UmiAgentSnapshot?) {
        let attention = UmiAttention.shared
        let paneSurface = snapshot.pane.flatMap { surface(umiID: $0) }
            ?? UmiTopology.allSurfaces.first { shared.attachments[$0.id] == snapshot.id }
        let kind: UmiAttention.Kind = snapshot.kind == .claude ? .claude : .codex
        // Panes that showed this session and don't any more.
        for (id, agent) in attention.panes where agent.session == snapshot.id && id != paneSurface?.id {
            attention.set(nil, forPane: id)
        }
        var mark = paneSurface.flatMap { attention.agent(forPane: $0.id)?.mark } ?? .none
        let finished = snapshot.status == "idle" || snapshot.status == "stopped" || snapshot.status == "error"
        let wasBusy = previous.map { $0.status == "working" || $0.status == "starting" || $0.status == "needs_input" } ?? false
        let looked = paneSurface.map { isLookedAt($0) } ?? false
        if snapshot.status == "needs_input" {
            mark = looked ? .none : .needsYou
        } else if finished && wasBusy {
            mark = looked ? .none : .finished
        } else if snapshot.status == "working" && mark == .needsYou {
            mark = .none
        }
        if let paneSurface {
            attention.set(.init(session: snapshot.id, kind: kind, title: snapshot.title, status: snapshot.status,
                                live: shared.livePanes.contains(paneSurface.id), mark: mark,
                                lastStop: snapshot.lastStopAt), forPane: paneSurface.id)
        }
        // Background sessions (no pane) count only while they need input.
        var background = attention.background.filter { $0.session != snapshot.id }
        if paneSurface == nil, snapshot.status == "needs_input" {
            background.append((session: snapshot.id, title: snapshot.title, since: snapshot.lastStopAt ?? Date()))
        }
        attention.setBackground(background.sorted { $0.since < $1.since })
    }

    static func attentionRemoved(_ id: String) {
        let attention = UmiAttention.shared
        for (pane, agent) in attention.panes where agent.session == id { attention.set(nil, forPane: pane) }
        attention.setBackground(attention.background.filter { $0.session != id })
    }

    /// The user is looking at this pane: focused in the key window of the active app.
    static func isLookedAt(_ surface: Ghostty.SurfaceView) -> Bool {
        guard NSApp.isActive, let location = UmiTopology.locate(surface),
              location.window.window?.isKeyWindow == true, location.tab === location.window.selectedTab else { return false }
        return location.window.focusedSurface === surface
    }
}

extension UmiLayout {
    static func isFocusedPane(_ surface: Ghostty.SurfaceView) -> Bool {
        UmiTopology.locate(surface).map { $0.window.focusedSurface === surface } ?? false
    }

    /// Take a pane out of its tab without closing it (its program keeps running, out of sight).
    /// A tab left empty closes.
    static func detach(_ pane: Ghostty.SurfaceView) {
        guard let source = UmiTopology.locate(pane),
              let node = source.window.tree(of: source.tab).root?.node(view: pane) else { return }
        let newTree = source.window.tree(of: source.tab).removing(node)
        UmiEvents.shared.emit("pane.closed", ["pane": pane.umiID, "tab": source.tab.idString,
                                               "window": source.window.umiIDString, "parked": true])
        if newTree.isEmpty {
            // The tab goes away with its last pane: its editor's unsaved edits are saved or kept
            // as recovery copies first, as when a tab closes (E-3).
            UmiEditor.saveDirtyDocuments(of: source.tab)
            source.window.detachTab(source.tab, focusNeighbor: true)
            UmiEvents.shared.emit("tab.closed", ["tab": source.tab.idString, "window": source.window.umiIDString])
        } else {
            source.window.setTree(SplitTree(root: newTree.root, zoomed: nil), for: source.tab)
        }
    }

    /// Put a detached pane back, in a new tab.
    static func adopt(_ pane: Ghostty.SurfaceView, intoNewTabOf window: TerminalController, focus: Bool) {
        let tab = UmiTab(tree: .init(view: pane))
        window.insertTab(tab, at: window.newTabIndex(selecting: focus))
        UmiEvents.shared.emit("tab.created", ["tab": tab.idString, "window": window.umiIDString])
        if focus { focusPane(pane, activate: true) }
    }
}

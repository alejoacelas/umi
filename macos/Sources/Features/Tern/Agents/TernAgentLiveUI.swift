import AppKit

// The app side of headless and live (AG-5 to AG-9): typing the attach command into a pane,
// taking over, removing a session from its pane (parked out of sight while its interface
// finishes), and what the sidebar and Dock show about sessions (TernAttention).
@MainActor
extension TernAgentUI {
    static func surface(ternID: String) -> Ghostty.SurfaceView? {
        TernTopology.allSurfaces.first { $0.ternID == ternID }
    }

    // MARK: Going live

    /// Run the session's own interface in its pane: the read-only view steps aside and the
    /// pane's shell runs `tern agent attach` (which stops a headless turn, for Claude, and
    /// execs the agent's interface).
    static func typeAttach(pane: String, session: String, selector: String) {
        guard let surface = surface(ternID: pane) else {
            // The pane is gone (closed, or not restored): nothing to go live in.
            TernAgents.queue.async {
                guard let s = TernAgents.shared.session(id: session) else { return }
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
        TernState.shared.layoutDidChange()
        // Shell-quoted: a name may hold spaces, quotes or anything else.
        let quoted = selector.allSatisfy { $0.isLetter || $0.isNumber || "-_.~".contains($0) }
            ? selector : "'" + selector.replacingOccurrences(of: "'", with: "'\\''") + "'"
        Task { @MainActor in
            // An interface still on its way out (Claude Code prints its resume hint after its
            // SessionEnd hook) would swallow the line, and so does a shell that hasn't started
            // reading again: wait for its prompt (at most 10 s), then a moment for its line editor.
            let deadline = Date().addingTimeInterval(10)
            var waited = false
            while !TernPaneContext.shellAtPrompt(surface) && Date() < deadline {
                waited = true
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if waited { try? await Task.sleep(nanoseconds: 300_000_000) }
            // `$TERN_CLI` is this app's own CLI (an older `tern` elsewhere on PATH must not answer).
            try? await TernInput.send(text: "\"$TERN_CLI\" agent attach \(quoted)", to: surface, enter: true)
        }
        if TernLayout.isFocusedPane(surface) {
            DispatchQueue.main.async { Ghostty.moveFocus(to: surface) }
        }
    }

    /// The Take Over button: at once, in this pane.
    func takeOver(_ surface: Ghostty.SurfaceView, session: String) {
        let pane = surface.ternID
        TernAgents.queue.async {
            guard let s = TernAgents.shared.session(id: session) else { return }
            s.record.pane = pane
            s.saveRecord()
            let selector = s.attachSelector
            DispatchQueue.main.async {
                MainActor.assumeIsolated { TernAgentUI.typeAttach(pane: pane, session: session, selector: selector) }
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
        guard let pane, let surface = surface(ternID: pane) else { return }
        shared.livePanes.remove(surface.id)
        if !keepView, shared.attachments[surface.id] == session {
            shared.attachments.removeValue(forKey: surface.id)
        }
        if shared.attachments[surface.id] == session {
            shared.showingTerminal.remove(surface.id)
            if TernLayout.isFocusedPane(surface) {
                DispatchQueue.main.async { shared.focusAgentView(of: surface) }
            }
        }
        TernState.shared.layoutDidChange()
    }

    /// End a live interface by signalling its processes in the pane (Codex's interface, or one
    /// whose process Tern doesn't know).
    static func closeLiveInterface(session: String, pane: String?) {
        let target = pane
        DispatchQueue.global().async {
            for info in TernProcessTree.all() where info.pid > 1 {
                guard let env = TernProcessTree.environment(info.pid) else { continue }
                guard env["TERN_STATE_DIR"] == TernPaths.stateDirectory else { continue }
                let mine = env["TERN_SESSION_ID"] == session && (target == nil || env["TERN_PANE_ID"] == target)
                if mine, env["TERN_HEADLESS"] == nil { kill(info.pid, SIGTERM) }
            }
        }
    }

    /// A command ended in a pane where a session's interface ran: if it was the interface (its
    /// process is gone), the session is headless again. Claude's interface also says so through
    /// its SessionEnd hook; Codex's (a client of Tern's server) has no hooks of its own.
    func commandFinished(in surface: Ghostty.SurfaceView) {
        guard livePanes.contains(surface.id), let session = attachments[surface.id] else { return }
        TernAgents.queue.async {
            guard let s = TernAgents.shared.session(id: session), s.record.live == true,
                  s.record.pane == surface.ternID else { return }
            if let pid = s.record.livePID, kill(pid, 0) == 0 { return }
            s.liveEnded()
        }
    }

    // MARK: Typing in a live interface

    func keyTyped(pane: Ghostty.SurfaceView, event: NSEvent) {
        guard let session = attachments[pane.id] ?? Self.sessionLive(in: pane.id) else { return }
        let chars = event.charactersIgnoringModifiers ?? ""
        let interrupt = event.keyCode == 53 /* esc */
            || (event.modifierFlags.contains(.control) && chars.lowercased() == "c")
        let submit = event.keyCode == 36 || event.keyCode == 76   // return, enter
        // Text going into the input box: not navigation (arrows, page keys) or app shortcuts.
        let navigation: Set<UInt16> = [123, 124, 125, 126, 115, 116, 119, 121]
        let clears = event.modifierFlags.contains(.control) && chars.lowercased() == "u"
        let typing = !navigation.contains(event.keyCode) && !event.modifierFlags.contains(.command)
            && !(event.characters ?? "").isEmpty && !clears
        Self.liveInput(session: session, interrupt: interrupt, submit: submit, typing: typing, clears: clears)
    }

    /// Text and keys put into a pane through Tern (`tern send`, `tern keys`): agents and scripts
    /// type into a live interface this way, so it counts like the keyboard (AG-9, AG-19).
    func inputSent(pane: Ghostty.SurfaceView, text: String, keys: [String]) {
        guard let session = attachments[pane.id] ?? Self.sessionLive(in: pane.id) else { return }
        if !text.isEmpty { Self.liveInput(session: session, interrupt: false, submit: false, typing: true, clears: false) }
        for key in keys {
            let spec = key.lowercased()
            let interrupt = ["esc", "escape", "ctrl+c", "control+c", "c+c"].contains(spec)
            let submit = ["enter", "return", "ret", "cr", "nl"].contains(spec)
            let clears = ["ctrl+u", "control+u", "c+u"].contains(spec)
            let navigation = ["up", "down", "left", "right", "pgup", "pgdn", "pageup", "pagedown", "home", "end"]
                .contains(spec) || spec.hasPrefix("arrow") || spec.hasPrefix("cmd+") || spec.hasPrefix("command+")
            Self.liveInput(session: session, interrupt: interrupt, submit: submit,
                           typing: !interrupt && !submit && !navigation && !clears, clears: clears)
        }
    }

    private static func liveInput(session: String, interrupt: Bool, submit: Bool, typing: Bool, clears: Bool) {
        TernAgents.queue.async {
            guard let s = TernAgents.shared.session(id: session), s.record.live == true else { return }
            if submit {
                s.lastLiveKey = Date()
                return   // UserPromptSubmit says whether something was sent
            }
            if clears {
                // Ctrl-U empties the input line.
                s.liveDraftCleared()
                return
            }
            s.liveKey(interrupt: interrupt, typing: typing)
        }
    }

    /// A session live in a pane that has no attachment (typed `claude`, adopted by its hooks).
    static func sessionLive(in pane: UUID) -> String? {
        let ternID = pane.uuidString.lowercased()
        return TernAgents.queue.sync {
            TernAgents.shared.sessions.first { $0.record.live == true && $0.record.pane == ternID }?.record.id
        }
    }

    // MARK: The focused pane's session (Window > Take Over Session, Remove Session from Pane)

    /// The focused pane of the key window (or of Tern's current window), wherever keyboard focus
    /// is, when it shows a session. `live`: only a live one (true), only a read-only one (false).
    static func focusedSessionPane(live: Bool?) -> (Ghostty.SurfaceView, String)? {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TernTopology.currentWindow
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
        let result: (TernAgentSession.HideAction, String?)? = TernAgents.queue.sync {
            guard let s = TernAgents.shared.session(id: sessionID) else { return nil }
            let pane = s.record.pane
            return (s.hide(), pane)
        }
        guard let (action, pane) = result else { throw TernError.notFound("no such session") }
        let found = pane.flatMap { TernAgentUI.surface(ternID: $0) }
            ?? TernTopology.allSurfaces.first { shared.attachments[$0.id] == sessionID }
        let surface = found
        switch action {
        case .nothing:
            if surface == nil { throw TernError.failed("the session isn't shown in a pane") }
            fallthrough
        case .closePane:
            guard let surface else { return }
            shared.attachments.removeValue(forKey: surface.id)
            shared.livePanes.remove(surface.id)
            shared.showingTerminal.remove(surface.id)
            try? TernLayout.closePane(surface)
        case .parkPane:
            guard let surface else { return }
            // Out of the layout, still running: the live interface finishes its turn.
            shared.parked[sessionID] = surface
            TernLayout.detach(surface)
        }
        TernState.shared.layoutDidChange()
        TernAgentMenu.shared.setNeedsRebuild()
    }

    /// A parked live interface shown again (`agent open` before it finished).
    static func unpark(_ sessionID: String, placement: TernAgentRPC.Placement) throws -> Ghostty.SurfaceView? {
        guard let surface = shared.parked.removeValue(forKey: sessionID) else { return nil }
        guard let window = TernTopology.currentWindow ?? TernTopology.windows.first else {
            shared.parked[sessionID] = surface
            return nil
        }
        TernLayout.adopt(surface, intoNewTabOf: window, focus: placement.focus)
        TernAgents.queue.async {
            guard let s = TernAgents.shared.session(id: sessionID) else { return }
            s.endLiveWhenSettled = false
            s.record.pane = surface.ternID
            s.saveRecord()
            s.changed()
        }
        return surface
    }

    // MARK: What the chrome shows (TernAttention)

    /// Called with every session update on the main thread.
    static func publishAttention(_ snapshot: TernAgentSnapshot, previous: TernAgentSnapshot?) {
        let attention = TernAttention.shared
        let paneSurface = snapshot.pane.flatMap { surface(ternID: $0) }
            ?? TernTopology.allSurfaces.first { shared.attachments[$0.id] == snapshot.id }
        let kind: TernAttention.Kind = snapshot.kind == .claude ? .claude : .codex
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
        let attention = TernAttention.shared
        for (pane, agent) in attention.panes where agent.session == id { attention.set(nil, forPane: pane) }
        attention.setBackground(attention.background.filter { $0.session != id })
    }

    /// The user is looking at this pane: focused in the key window of the active app.
    static func isLookedAt(_ surface: Ghostty.SurfaceView) -> Bool {
        guard NSApp.isActive, let location = TernTopology.locate(surface),
              location.window.window?.isKeyWindow == true, location.tab === location.window.selectedTab else { return false }
        return location.window.focusedSurface === surface
    }
}

extension TernLayout {
    static func isFocusedPane(_ surface: Ghostty.SurfaceView) -> Bool {
        TernTopology.locate(surface).map { $0.window.focusedSurface === surface } ?? false
    }

    /// Take a pane out of its tab without closing it (its program keeps running, out of sight).
    /// A tab left empty closes.
    static func detach(_ pane: Ghostty.SurfaceView) {
        guard let source = TernTopology.locate(pane),
              let node = source.window.tree(of: source.tab).root?.node(view: pane) else { return }
        let newTree = source.window.tree(of: source.tab).removing(node)
        TernEvents.shared.emit("pane.closed", ["pane": pane.ternID, "tab": source.tab.idString,
                                               "window": source.window.ternIDString, "parked": true])
        if newTree.isEmpty {
            // The tab goes away with its last pane: its editor's unsaved edits are saved or kept
            // as recovery copies first, as when a tab closes (E-3).
            TernEditor.saveDirtyDocuments(of: source.tab)
            source.window.detachTab(source.tab, focusNeighbor: true)
            TernEvents.shared.emit("tab.closed", ["tab": source.tab.idString, "window": source.window.ternIDString])
        } else {
            source.window.setTree(SplitTree(root: newTree.root, zoomed: nil), for: source.tab)
        }
    }

    /// Put a detached pane back, in a new tab.
    static func adopt(_ pane: Ghostty.SurfaceView, intoNewTabOf window: TerminalController, focus: Bool) {
        let tab = TernTab(tree: .init(view: pane))
        window.insertTab(tab, at: window.tabs.count)
        TernEvents.shared.emit("tab.created", ["tab": tab.idString, "window": window.ternIDString])
        if focus { focusPane(pane, activate: true) }
    }
}

import AppKit

/// Control methods for moving between tabs and sessions (L-11, L-12), shortcuts (L-17), and
/// the internal `debug.*` methods that check the palettes, the tab order and the attention
/// data without the accessibility tree.
@MainActor
enum UmiNavigationRPC {
    static let methods: Set<String> = [
        "tab.back", "tab.next", "tab.prev", "jump.next", "jump.back",
        "shortcuts.list", "shortcuts.set", "shortcuts.reset",
        "debug.attention.set", "debug.attention.background", "debug.navigation",
        "debug.palette", "debug.palette.perform", "debug.palette.close", "debug.palette.state", "debug.key",
    ]

    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) async throws -> [String: Any] {
        switch method {
        case "tab.back":
            guard let (window, tab) = UmiNavigation.tabBack() else {
                throw UmiError.notFound("there's no earlier tab to go back to")
            }
            return tabResult(tab, in: window)

        case "tab.next", "tab.prev":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard window.tabs.count > 1 else { throw UmiError.notFound("the window has only one tab") }
            guard let tab = UmiNavigation.selectAdjacentTab(method == "tab.next" ? 1 : -1, in: window) else {
                throw UmiError.failed("couldn't change tabs")
            }
            return tabResult(tab, in: window)

        case "jump.next":
            switch UmiNavigation.jumpToNextNeedingYou() {
            case .pane(let pane)?:
                var result = UmiTopology.paneInfoJSON(pane)
                result["pane"] = pane.umiID
                return result
            case .session(let session)?:
                return ["session": session]
            case nil:
                throw UmiError.notFound("no session needs you")
            }

        case "jump.back":
            guard let pane = UmiNavigation.jumpBack() else { throw UmiError.notFound("there's nowhere to jump back to") }
            var result = UmiTopology.paneInfoJSON(pane)
            result["pane"] = pane.umiID
            return result

        // MARK: Shortcuts

        case "shortcuts.list":
            return ["shortcuts": UmiShortcutStore.shared.entries().map(\.json),
                    "files": [UmiShortcutStore.file, UmiShortcutStore.ghosttyFile]]

        case "shortcuts.set":
            guard let id = params.string("id"), !id.isEmpty else { throw UmiError.badRequest("name a shortcut id (see `umi shortcuts`)") }
            let keys = params.string("keys") ?? ""
            var shortcut: UmiShortcut?
            if !keys.isEmpty {
                guard let parsed = UmiShortcut(spec: keys) else {
                    throw UmiError.badRequest("can't read the shortcut \"\(keys)\" (write it like cmd+shift+] or ctrl+cmd+left)")
                }
                shortcut = parsed
            }
            do {
                let notes = try UmiShortcutStore.shared.set(id, to: shortcut)
                var result: [String: Any] = ["id": id, "keys": shortcut?.spec ?? "", "notes": notes]
                if let entry = UmiShortcutStore.shared.entry(id) { result["shortcut"] = entry.json }
                return result
            } catch let error as UmiShortcutStore.StoreError {
                throw UmiError.badRequest(error.description)
            }

        case "shortcuts.reset":
            do {
                try UmiShortcutStore.shared.reset(params.string("id"))
            } catch let error as UmiShortcutStore.StoreError {
                throw UmiError.badRequest(error.description)
            }
            return ["reset": params.string("id") ?? "all"]

        // MARK: Internal checks

        case "debug.attention.set":
            // Stand in for the agent engine: what the chrome knows about a pane's agent.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            if params.bool("clear") ?? false {
                UmiAttention.shared.set(nil, forPane: pane.id)
                return ["pane": pane.umiID, "agent": NSNull()]
            }
            let mark: UmiAttention.Mark
            switch params.string("mark") ?? "none" {
            case "finished": mark = .finished
            case "needs_you", "needs-you": mark = .needsYou
            default: mark = .none
            }
            let stopped = params.double("stopped_ago").map { Date().addingTimeInterval(-$0) }
            let agent = UmiAttention.Agent(session: params.string("session"),
                                            kind: params.string("kind") == "codex" ? .codex : .claude,
                                            title: params.string("title") ?? "agent", status: params.string("status") ?? "idle",
                                            live: params.bool("live") ?? false, mark: mark, lastStop: stopped)
            UmiAttention.shared.set(agent, forPane: pane.id)
            return ["pane": pane.umiID]

        case "debug.attention.background":
            let items = (params.raw["items"] as? [[String: Any]] ?? []).map { item in
                (session: item["session"] as? String ?? "", title: item["title"] as? String ?? "",
                 since: Date().addingTimeInterval(-((item["since_ago"] as? NSNumber)?.doubleValue ?? 0)))
            }
            UmiAttention.shared.setBackground(items)
            if params.bool("record_shows") ?? false {
                UmiAttention.shared.showSession = { session in
                    UmiNavigationRPC.shownSessions.append(session)
                }
            }
            return ["count": items.count, "shown": shownSessions]

        case "debug.navigation":
            return [
                "history": UmiTabHistory.recentFirst.map(\.idString),
                "focus_history": UmiFocusHistory.recentFirst.map(\.umiID),
                "order_frozen": UmiTabOrder.isFrozen,
                "can_go_back": UmiTabHistory.canGoBack,
                "can_jump_back": UmiNavigation.canJumpBack,
                "shown_sessions": shownSessions,
                "settings_visible": UmiSettingsWindow.isVisible,
                "key_monitor": UmiShortcuts.monitorInstalled,
                "app_active": NSApp.isActive,
            ]

        case "debug.palette":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard let mode = UmiPaletteModel.Mode(rawValue: params.string("mode") ?? "commands") else {
                throw UmiError.badRequest("mode is commands, panes or files")
            }
            let entries = await window.palette.preview(mode, query: params.string("query") ?? "", in: window)
            return ["entries": entries.map(\.json), "presented": window.palette.isPresented,
                    "pane": window.palette.pane?.umiID ?? ""]

        case "debug.palette.perform":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard let title = params.string("title") else { throw UmiError.badRequest("give an entry title") }
            return await window.palette.perform(title: title, answers: params.strings("answers") ?? [],
                                                timeout: params.double("timeout") ?? 20)

        case "debug.palette.state":
            // What the palette shows now, without opening or changing it.
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            let palette = window.palette
            return ["presented": palette.isPresented, "mode": palette.mode.rawValue, "step": "\(palette.step)",
                    "entries": palette.entries.map(\.title), "output": palette.output?.text ?? ""]

        case "debug.palette.close":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            window.palette.close()
            return ["presented": window.palette.isPresented]

        case "debug.key":
            // A key press delivered inside the app (not through the system: nothing outside the
            // app sees it), after putting focus somewhere: the path a shortcut takes from there.
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard let spec = params.string("keys"), let shortcut = UmiShortcut(spec: spec),
                  let code = keyCodes[shortcut.key] else {
                throw UmiError.badRequest("keys like cmd+shift+] (US layout letters, digits, [ ] , tab and arrows)")
            }
            var target = window.window
            switch params.string("focus") ?? "terminal" {
            case "editor", "preview":
                UmiDebug.focusEditor(in: window)
            case "palette":
                window.palette.open(.commands, in: window)
            case "settings":
                UmiSettingsWindow.show()
                target = NSApp.windows.first { $0.title == "Settings" && $0.isVisible }
            default:
                if let pane = window.selectedTab.effectiveFocusedSurface { Ghostty.moveFocus(to: pane) }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            let responder = target?.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
            guard let target else { throw UmiError.failed("no window to send the key to") }
            // What the app's key monitor does with a key press, before any view sees it. (AppKit
            // runs local monitors only for events from the window server; the AX tests press
            // real keys.) A key Umi doesn't take goes on to the focused view.
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shortcut.modifiers,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                               context: nil, characters: shortcut.key, charactersIgnoringModifiers: shortcut.key,
                                               isARepeat: false, keyCode: code) else {
                throw UmiError.failed("couldn't make the key event")
            }
            let handled = UmiShortcuts.dispatch(event)
            if !handled { NSApp.sendEvent(event) }
            try? await Task.sleep(nanoseconds: 300_000_000)
            return ["focus": responder, "handled": handled]

        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }

    /// US layout key codes, for debug.key.
    private static let keyCodes: [String: UInt16] = {
        var codes: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
            "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
            "\t": 48, "\r": 36, " ": 49, "\u{8}": 51, "\u{1b}": 53,
        ]
        let arrows: [(Int, UInt16)] = [(NSLeftArrowFunctionKey, 123), (NSRightArrowFunctionKey, 124),
                                       (NSDownArrowFunctionKey, 125), (NSUpArrowFunctionKey, 126)]
        for (scalar, code) in arrows { codes[String(UnicodeScalar(scalar)!)] = code }
        return codes
    }()

    /// Sessions the "show a session" hook was asked to show (debug.attention.background).
    static var shownSessions: [String] = []

    private static func tabResult(_ tab: UmiTab, in window: TerminalController) -> [String: Any] {
        ["tab": tab.idString, "window": window.umiIDString, "index": (window.index(of: tab) ?? 0) + 1, "title": tab.title]
    }
}

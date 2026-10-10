import AppKit
import GhosttyKit

/// The control socket's methods. Each returns a JSON-able dictionary or throws a TernError.
@MainActor
enum TernRPC {
    static func handle(method: String, params: TernParams, caller: TernCaller, connection: TernConnection) async throws -> [String: Any]? {
        defer { TernUndo.requestDidEnd() }
        return try await dispatch(method: method, params: params, caller: caller, connection: connection)
    }

    private static func dispatch(method: String, params: TernParams, caller: TernCaller, connection: TernConnection) async throws -> [String: Any]? {
        switch method {
        // MARK: System
        case "system.ping":
            return [
                "pid": Int(getpid()),
                "version": TernVersion.current,
                "build": TernVersion.build,
                "state_dir": TernPaths.stateDirectory,
                "instance": TernPaths.instanceID,
                "app": Bundle.main.bundlePath,
            ]

        case "system.activate":
            if TernTopology.windows.isEmpty, let ghostty = TernLayout.ghostty {
                _ = TerminalController.newWindow(ghostty)
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return ["ok": true]

        case "tree", "ls":
            return TernTopology.treeJSON()

        // MARK: Windows
        case "window.new":
            let focus = params.bool("focus") ?? true
            var options = TernLayout.PaneOptions(params)
            options.name = nil
            return try TernLayout.newWindow(options, tabName: params.string("name"), focus: focus,
                                            inheritFrom: try TernTopology.callerPane(caller))

        case "window.focus":
            let window = try TernTopology.window(params.string("window"), caller: caller)
            TernLayout.focusWindow(window)
            return ["window": window.ternIDString]

        case "window.close":
            let window = try TernTopology.window(params.string("window"), caller: caller)
            let id = window.ternIDString
            // Closing from the CLI is deliberate: no confirmation dialog.
            window.closeWindowImmediately()
            return ["window": id, "closed": true]

        // MARK: Tabs
        case "tab.new":
            var options = TernLayout.PaneOptions(params)
            options.name = nil
            let focus = params.bool("focus") ?? true
            var color = TerminalTabColor.none
            if let name = params.string("color") {
                guard let parsed = TernTopology.color(named: name) else { throw badColor(name) }
                color = parsed
            }
            let explicit = try params.string("pane").map { try TernTopology.resolvePane($0, caller: caller) }
            // An explicit --pane or --window overrides the caller's own pane, so a stale caller
            // identity doesn't matter then.
            let callerPane = explicit == nil && params.string("window") == nil
                ? try TernTopology.callerPane(caller) : (try? TernTopology.callerPane(caller)) ?? nil
            let window: TerminalController?
            if let selector = params.string("window") {
                window = try TernTopology.resolveWindow(selector, caller: caller)
            } else if let explicit, let location = TernTopology.locate(explicit) {
                window = location.window
            } else if let callerPane, let location = TernTopology.locate(callerPane) {
                window = location.window
            } else {
                window = TernTopology.currentWindow
            }
            // The new tab starts where the pane the request is about is: the given one, else
            // the caller's own (in that window), not whichever pane the window shows.
            let source = explicit ?? callerPane.flatMap { pane in
                window == nil || TernTopology.locate(pane)?.window === window ? pane : nil
            }
            let name = params.string("name")
            guard let window else {
                return try TernLayout.newWindow(options, tabName: name, focus: focus, inheritFrom: source)
            }
            return try TernLayout.newTab(in: window, options: options, tabName: name.flatMap { $0.isEmpty ? nil : $0 },
                                         color: color, index: params.int("index"), focus: focus, inheritFrom: source)

        case "tab.focus":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            TernLayout.focusTab(tab, in: window)
            return ["tab": tab.idString, "window": window.ternIDString]

        case "tab.close":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            window.closeTabImmediately(tab)
            return ["tab": tab.idString, "closed": true]

        case "tab.equalize":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            TernLayout.equalize(tab, in: window)
            return ["tab": tab.idString]

        case "tab.rename":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            let name = params.string("name") ?? ""
            tab.name = name.isEmpty ? nil : name
            if tab === window.selectedTab { window.titleOverride = tab.name }
            TernEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": window.ternIDString])
            TernState.shared.layoutDidChange()
            return ["tab": tab.idString, "name": name]

        case "tab.color":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            let name = params.string("color") ?? ""
            guard let color = TernTopology.color(named: name) else { throw badColor(name) }
            tab.color = color
            TernEvents.shared.emit("tab.colored", ["tab": tab.idString, "color": name, "window": window.ternIDString])
            TernState.shared.layoutDidChange()
            return ["tab": tab.idString, "color": name]

        case "tab.pin", "tab.unpin":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            let pin = method == "tab.pin"
            TernLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: [window]) {
                window.setPinned(tab, pin)
            }
            TernEvents.shared.emit(pin ? "tab.pinned" : "tab.unpinned", ["tab": tab.idString, "window": window.ternIDString])
            return ["tab": tab.idString, "pinned": pin]

        case "tab.move":
            let (source, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            if let by = params.int("by") {
                // Up or down the sidebar, within the tab's pin group (L-13).
                guard TernNavigation.moveTab(tab, by: by, in: source) else {
                    throw TernError.badRequest("the tab is already at the \(by < 0 ? "top" : "bottom") of its \(tab.pinned ? "pinned " : "")group")
                }
                return ["tab": tab.idString, "window": source.ternIDString, "index": (source.index(of: tab) ?? 0) + 1]
            }
            let focus = params.bool("focus") ?? true
            let newWindow = params.bool("new_window") ?? false
            let target = try params.string("window").map { try TernTopology.resolveWindow($0, caller: caller) }
            if newWindow && target != nil { throw TernError.badRequest("give either --window or --new-window") }
            if !newWindow && target == nil && params.int("index") == nil {
                throw TernError.badRequest("give --window W, --index I or --new-window")
            }
            if let index = params.int("index"), index < 1 { throw TernError.badRequest("--index starts at 1") }
            let result = try TernLayout.move(tab: tab, from: source, toWindow: target, index: params.int("index"),
                                             newWindow: newWindow, focus: focus)
            return ["tab": tab.idString, "window": result.ternIDString]

        // MARK: Panes
        case "pane.split", "split":
            let target = try TernTopology.pane(params.string("pane"), caller: caller)
            let direction = try TernLayout.direction(params.string("direction"))
            return try TernLayout.split(target, direction: direction, options: TernLayout.PaneOptions(params),
                                        ratio: params.double("ratio"), focus: params.bool("focus") ?? true)

        case "pane.info":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            return TernTopology.paneInfoJSON(pane)

        case "pane.focus":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            TernLayout.focusPane(pane, activate: true)
            return ["pane": pane.ternID]

        case "pane.close":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            try TernLayout.closePane(pane)
            return ["pane": pane.ternID, "closed": true]

        case "pane.zoom":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            try TernLayout.toggleZoom(pane)
            return TernTopology.paneInfoJSON(pane)

        case "pane.rename":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            let name = params.string("name") ?? ""
            if !name.isEmpty, let other = TernTopology.allSurfaces.first(where: { $0 !== pane && TernState.shared.paneName($0.id) == name }) {
                throw TernError.badRequest("another pane (\(other.ternID.prefix(8))) is already named \"\(name)\"")
            }
            TernState.shared.setPaneName(pane.id, name)
            TernEvents.shared.emit("pane.renamed", ["pane": pane.ternID, "name": name])
            return ["pane": pane.ternID, "name": name]

        case "pane.move":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            let focus = params.bool("focus") ?? true
            let direction = try TernLayout.direction(params.string("direction"))
            let destination: TernLayout.PaneDestination
            if let to = params.string("to") {
                destination = .besidePane(try TernTopology.resolvePane(to, caller: caller), direction)
            } else if let tabSelector = params.string("tab") {
                let (window, tab) = try TernTopology.resolveTab(tabSelector, caller: caller)
                guard let anchor = (tab === window.selectedTab ? window.focusedSurface : nil)
                        .flatMap({ window.tree(of: tab).contains($0) ? $0 : nil }) ?? tab.effectiveFocusedSurface ?? window.tree(of: tab).root?.leftmostLeaf() else {
                    throw TernError.notFound("the tab has no panes")
                }
                if anchor === pane, window.tree(of: tab).root?.leaves().count == 1 {
                    throw TernError.badRequest("the pane is already the only pane of that tab")
                }
                destination = .besidePane(anchor === pane ? (window.tree(of: tab).root?.leaves().first { $0 !== pane } ?? anchor) : anchor, direction)
            } else if params.bool("new_tab") ?? false {
                let window = try params.string("window").map { try TernTopology.resolveWindow($0, caller: caller) }
                    ?? TernTopology.locate(pane)?.window
                guard let window else { throw TernError.notFound("the pane isn't in a window") }
                destination = .newTab(window, index: nil)
            } else if params.bool("new_window") ?? false {
                destination = .newWindow
            } else if let windowSelector = params.string("window") {
                let window = try TernTopology.resolveWindow(windowSelector, caller: caller)
                let tab = window.selectedTab
                let tree = window.tree(of: tab)
                guard let anchor = (window.focusedSurface.flatMap { tree.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface),
                      anchor !== pane else {
                    throw TernError.badRequest("the pane is already there")
                }
                destination = .besidePane(anchor, direction)
            } else {
                throw TernError.badRequest("give one of --to PANE, --tab T, --window W, --new-tab or --new-window")
            }
            let location = try TernLayout.move(pane, to: destination, focus: focus)
            return ["pane": pane.ternID, "tab": location.tab.idString, "window": location.window.ternIDString]

        case "pane.swap":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            guard let targetSelector = params.string("target") else { throw TernError.badRequest("pane swap needs a TARGET pane") }
            let target = try TernTopology.resolvePane(targetSelector, caller: caller)
            try TernLayout.swap(pane, target)
            return ["pane": pane.ternID, "target": target.ternID]

        case "pane.resize":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            try TernLayout.resize(pane, direction: params.string("direction") ?? "", amount: params.int("amount") ?? 5)
            return ["pane": pane.ternID]

        case "pane.send", "send":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            try await TernInput.send(text: params.string("text") ?? "", to: pane, enter: params.bool("enter") ?? false)
            return ["pane": pane.ternID]

        case "pane.keys", "keys":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            try TernInput.send(keys: params.strings("keys") ?? [], to: pane)
            return ["pane": pane.ternID]

        case "pane.read", "read":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            let outputOnly = params.bool("output_only") ?? false
            let bytes = TernInput.outputBytes(pane)
            var text = TernInput.read(pane,
                                      scrollback: params.bool("scrollback") ?? false,
                                      lines: params.int("lines"),
                                      outputOnly: outputOnly)
            // `wait`: output written since an earlier read may have scrolled past the screen.
            // Every row takes at least one byte, so the last (new bytes + screen rows) rows
            // hold all of it.
            if outputOnly, let since = params.int("since_bytes"), let surface = pane.surface {
                let fresh = Int(clamping: bytes) - since
                let screenRows = Int(ghostty_surface_size(surface).rows)
                if fresh > screenRows {
                    text = TernInput.readOutputTail(pane, rows: min(fresh, 1_000_000) + screenRows)
                }
            }
            return ["pane": pane.ternID, "text": text, "output_bytes": Int(clamping: bytes)]

        // MARK: Events, notifications, UI
        case "events.subscribe":
            var paneID: String?
            if let selector = params.string("pane") {
                paneID = try TernTopology.resolvePane(selector, caller: caller).ternID
            }
            TernEvents.shared.addSubscriber(connection, filters: params.strings("filters") ?? [], pane: paneID)
            return ["subscribed": true]

        case "notify":
            let pane = try? TernTopology.pane(params.string("pane"), caller: caller)
            try await TernNotify.post(title: params.string("title") ?? "", body: params.string("body"), pane: pane)
            return ["ok": true]

        case "sidebar":
            let state = TernState.shared
            // The width is per window (S-8): the given window, else the caller's, else the current.
            // An unknown window changes nothing (L-4).
            let window = params.string("window") != nil
                ? try TernTopology.window(params.string("window"), caller: caller)
                : try? TernTopology.window(nil, caller: caller)
            if params.bool("toggle") ?? false { state.sidebarVisible.toggle() }
            if let visible = params.bool("visible") { state.sidebarVisible = visible }
            if let mode = params.string("mode") {
                guard let parsed = TernState.SidebarMode(rawValue: mode) else {
                    throw TernError.badRequest("unknown sidebar mode \"\(mode)\" (use tabs or files)")
                }
                state.sidebarMode = parsed
                state.sidebarVisible = true
            }
            if let width = params.double("width") {
                guard let window else { throw TernError.notFound("there are no Tern windows open") }
                window.sidebarWidth = TernTheme.clampSidebarWidth(CGFloat(width))
                state.sidebarWidth = window.sidebarWidth
            }
            var json: [String: Any] = ["visible": state.sidebarVisible, "mode": state.sidebarMode.rawValue]
            if let window {
                json["width"] = Double(window.sidebarWidth)
                json["window"] = window.ternIDString
            }
            return json

        case "reopen":
            return try TernReopen.shared.reopen()
        case "reopen.list":
            return ["items": TernReopen.shared.list()]

        case "screenshot":
            let window = try TernTopology.window(params.string("window"), caller: caller)
            guard let path = params.string("path"), !path.isEmpty else { throw TernError.badRequest("screenshot needs an output path") }
            try await TernScreenshot.capture(window, to: path)
            return ["path": path, "window": window.ternIDString]

        // MARK: Editor
        case "editor.open":
            return try TernEditor.handleOpen(params, caller: caller)
        case "editor.list":
            return try TernEditor.handleList(params, caller: caller)
        case "editor.close":
            return try TernEditor.handleClose(params, caller: caller)
        case "editor.mode":
            return try TernEditor.handleMode(params, caller: caller)

        // MARK: Interactive agents
        case "interactive.launch":
            return try TernInteractive.launch(params, caller: caller)

        // MARK: Updates
        case "update.check":
            return try await TernUpdater.shared.check(userInitiated: false)
        case "update.status":
            return TernUpdater.shared.status()
        case "update.answer":
            guard let answer = params.string("answer").flatMap(TernUpdater.Answer.init(rawValue:)) else {
                throw TernError.badRequest("answer is download, later or skip")
            }
            return try await TernUpdater.shared.answer(answer)
        case "update.download":
            return try await TernUpdater.shared.download()
        case "update.install_now":
            return try await TernUpdater.shared.installNow(force: params.bool("force") ?? false)

        // MARK: Internal (not part of the CLI contract): scripted checks of menu and editor
        // paths that otherwise need the accessibility tree.
        case "debug.menu":
            return ["items": TernDebug.menuItems()]
        case "debug.dock_badge":
            return ["badge": NSApp.dockTile.badgeLabel ?? ""]
        case "debug.undo":
            guard let um = (NSApp.delegate as? AppDelegate)?.undoManager else { return [:] }
            return ["can_undo": um.canUndo, "can_redo": um.canRedo, "undo": um.undoActionName,
                    "redo": um.redoActionName, "level": um.groupingLevel]
        case "debug.confirm":
            // Whether closing each window (and so quitting) would ask first.
            return ["windows": TernTopology.windows.map {
                ["window": $0.ternIDString, "needs_confirmation": !$0.windowCanBeClosedWithoutConfirmation()]
            }]
        case "debug.menu.perform":
            guard let title = params.string("title") else { throw TernError.badRequest("give a menu item title") }
            try TernDebug.performMenuItem(title)
            return ["performed": title]
        case "debug.editor.type":
            let (_, tab) = try TernEditor.targetTab(params, caller: caller, createWindow: false)
            guard let doc = params.string("path").flatMap({ tab.editor.document(for: URL(fileURLWithPath: $0)) }) ?? tab.editor.active else {
                throw TernError.notFound("no such document")
            }
            let text = params.string("text") ?? ""
            if params.bool("replace") ?? false || !text.isEmpty {
                doc.text = (params.bool("replace") ?? false) ? text : doc.text + text
            }
            tab.editor.active = doc
            var json = TernEditor.json(doc)
            json["text"] = doc.text
            json["error"] = doc.error ?? ""
            return json
        case "debug.editor.focus":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            TernLayout.focusTab(tab, in: window)
            TernDebug.focusEditor(in: window, selectEnd: params.bool("select_end") ?? false)
            return ["ok": true]

        case "debug.agent.pane", "debug.agent.type", "debug.agent.press":
            return try TernAgentDebug.handle(method, params, caller: caller)

        case let ui where ui.hasPrefix("debug.ui."):
            return try TernUIDebug.handle(method, params, caller: caller)

        default:
            if TernNavigationRPC.methods.contains(method) {
                return try await TernNavigationRPC.handle(method, params, caller: caller)
            }
            if method.hasPrefix("agent.") {
                return try await TernAgentRPC.handle(method: method, params: params, caller: caller, connection: connection)
            }
            throw TernError.badRequest("unknown method \(method)")
        }
    }

    private static func badColor(_ name: String) -> TernError {
        TernError.badRequest("unknown color \"\(name)\" (use blue, purple, pink, red, orange, yellow, green, teal, graphite or none)")
    }
}


/// Each control request is its own undo step.
///
/// A change registers undo into AppKit's automatic undo group, and AppKit closes that group
/// only after it handles a UI event. Requests aren't UI events: with the user away (no
/// events), every later change would land in the same group and one Undo would revert them
/// all. So a request that left the group open posts a harmless application-defined event;
/// AppKit handles it and closes the group. (Closing it by hand makes AppKit throw later, and
/// explicit groups don't help: AppKit nests them in its automatic one, and an empty explicit
/// group clears the redo stack.)
@MainActor
enum TernUndo {
    static func requestDidEnd() {
        guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager, manager.groupingLevel > 0 else { return }
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 0x7465, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}

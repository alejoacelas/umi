import AppKit
import GhosttyKit

/// The control socket's methods. Each returns a JSON-able dictionary or throws an UmiError.
@MainActor
enum UmiRPC {
    static func handle(method: String, params: UmiParams, caller: UmiCaller, connection: UmiConnection) async throws -> [String: Any]? {
        defer { UmiUndo.requestDidEnd() }
        return try await dispatch(method: method, params: params, caller: caller, connection: connection)
    }

    private static func dispatch(method: String, params: UmiParams, caller: UmiCaller, connection: UmiConnection) async throws -> [String: Any]? {
        switch method {
        // MARK: System
        case "system.ping":
            return [
                "pid": Int(getpid()),
                "version": UmiVersion.current,
                "build": UmiVersion.build,
                "state_dir": UmiPaths.stateDirectory,
                "instance": UmiPaths.instanceID,
                "app": Bundle.main.bundlePath,
            ]

        // MARK: Agent hooks (Umi's plugins for Claude Code and Codex)
        case "hook", "agent.hook":
            return UmiAgentHooks.handle(params, caller: caller)
        case "plugins", "agent.plugins":
            return await UmiAgentPlugins.rpc(params)

        case "system.activate":
            if UmiTopology.windows.isEmpty, let ghostty = UmiLayout.ghostty {
                _ = TerminalController.newWindow(ghostty)
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            return ["ok": true]

        case "tree", "ls":
            if let query = params.string("where") { return try UmiTopology.whereJSON(query) }
            return UmiTopology.treeJSON()

        // MARK: Windows
        case "window.new":
            let focus = params.bool("focus") ?? true
            var options = UmiLayout.PaneOptions(params)
            options.name = nil
            return try UmiLayout.newWindow(options, tabName: params.string("name"), focus: focus,
                                            inheritFrom: try UmiTopology.callerPane(caller))

        case "window.focus":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            UmiLayout.focusWindow(window)
            return ["window": window.umiIDString]

        case "window.close":
            // A query closes every window holding a match.
            let windows = try UmiTopology.everyWindow(params.string("window"), caller: caller)
            let ids = windows.map(\.umiIDString)
            // Closing from the CLI is deliberate: no confirmation dialog.
            for window in windows { window.closeWindowImmediately() }
            return ["window": ids[0], "windows": ids, "closed": true]

        // MARK: Tabs
        case "tab.new":
            var options = UmiLayout.PaneOptions(params)
            options.name = nil
            let focus = params.bool("focus") ?? true
            var color = TerminalTabColor.none
            if let name = params.string("color") {
                guard let parsed = UmiTopology.color(named: name) else { throw badColor(name) }
                color = parsed
            }
            let explicit = try params.string("pane").map { try UmiTopology.resolvePane($0, caller: caller) }
            // An explicit --pane or --window overrides the caller's own pane, so a stale caller
            // identity doesn't matter then.
            let callerPane = explicit == nil && params.string("window") == nil
                ? try UmiTopology.callerPane(caller) : (try? UmiTopology.callerPane(caller)) ?? nil
            let window: TerminalController?
            if let selector = params.string("window") {
                window = try UmiTopology.resolveWindow(selector, caller: caller)
            } else if let explicit, let location = UmiTopology.locate(explicit) {
                window = location.window
            } else if let callerPane, let location = UmiTopology.locate(callerPane) {
                window = location.window
            } else {
                window = UmiTopology.currentWindow
            }
            // The new tab starts where the pane the request is about is: the given one, else
            // the caller's own (in that window), not whichever pane the window shows.
            let source = explicit ?? callerPane.flatMap { pane in
                window == nil || UmiTopology.locate(pane)?.window === window ? pane : nil
            }
            let name = params.string("name")
            guard let window else {
                return try UmiLayout.newWindow(options, tabName: name, focus: focus, inheritFrom: source)
            }
            return try UmiLayout.newTab(in: window, options: options, tabName: name.flatMap { $0.isEmpty ? nil : $0 },
                                         color: color, index: params.int("index"), focus: focus, inheritFrom: source)

        case "tab.focus":
            let (window, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            UmiLayout.focusTab(tab, in: window)
            return ["tab": tab.idString, "window": window.umiIDString]

        case "tab.close":
            // A query closes every tab holding a match; so do equalize, color, pin and unpin.
            let tabs = try UmiTopology.everyTab(params.string("tab"), caller: caller)
            for (window, tab) in tabs { window.closeTabImmediately(tab) }
            return ["tab": tabs[0].1.idString, "tabs": tabs.map(\.1.idString), "closed": true]

        case "tab.equalize":
            let tabs = try UmiTopology.everyTab(params.string("tab"), caller: caller)
            for (window, tab) in tabs { UmiLayout.equalize(tab, in: window) }
            return ["tab": tabs[0].1.idString, "tabs": tabs.map(\.1.idString)]

        case "tab.rename":
            let (window, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            let name = params.string("name") ?? ""
            tab.name = name.isEmpty ? nil : name
            if tab === window.selectedTab { window.titleOverride = tab.name }
            UmiEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": name, "window": window.umiIDString])
            UmiState.shared.layoutDidChange()
            return ["tab": tab.idString, "name": name]

        case "tab.color":
            let tabs = try UmiTopology.everyTab(params.string("tab"), caller: caller)
            let name = params.string("color") ?? ""
            guard let color = UmiTopology.color(named: name) else { throw badColor(name) }
            for (window, tab) in tabs {
                tab.color = color
                UmiEvents.shared.emit("tab.colored", ["tab": tab.idString, "color": name, "window": window.umiIDString])
            }
            UmiState.shared.layoutDidChange()
            return ["tab": tabs[0].1.idString, "tabs": tabs.map(\.1.idString), "color": name]

        case "tab.pin", "tab.unpin":
            let tabs = try UmiTopology.everyTab(params.string("tab"), caller: caller)
            let pin = method == "tab.pin"
            var windows: [TerminalController] = []
            for (window, _) in tabs where !windows.contains(where: { $0 === window }) { windows.append(window) }
            UmiLayout.undoable(pin ? "Pin Tab" : "Unpin Tab", windows: windows) {
                for (window, tab) in tabs { window.setPinned(tab, pin) }
            }
            for (window, tab) in tabs {
                UmiEvents.shared.emit(pin ? "tab.pinned" : "tab.unpinned", ["tab": tab.idString, "window": window.umiIDString])
            }
            return ["tab": tabs[0].1.idString, "tabs": tabs.map(\.1.idString), "pinned": pin]

        case "tab.move":
            let (source, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            if let by = params.int("by") {
                // Up or down the sidebar, within the tab's pin group (L-13).
                guard UmiNavigation.moveTab(tab, by: by, in: source) else {
                    throw UmiError.badRequest("the tab is already at the \(by < 0 ? "top" : "bottom") of its \(tab.pinned ? "pinned " : "")group")
                }
                return ["tab": tab.idString, "window": source.umiIDString, "index": (source.index(of: tab) ?? 0) + 1]
            }
            let focus = params.bool("focus") ?? true
            let newWindow = params.bool("new_window") ?? false
            let target = try params.string("window").map { try UmiTopology.resolveWindow($0, caller: caller) }
            if newWindow && target != nil { throw UmiError.badRequest("give either --window or --new-window") }
            if !newWindow && target == nil && params.int("index") == nil {
                throw UmiError.badRequest("give --window W, --index I or --new-window")
            }
            if let index = params.int("index"), index < 1 { throw UmiError.badRequest("--index starts at 1") }
            let result = try UmiLayout.move(tab: tab, from: source, toWindow: target, index: params.int("index"),
                                             newWindow: newWindow, focus: focus)
            return ["tab": tab.idString, "window": result.umiIDString]

        // MARK: Panes
        case "pane.split", "split":
            let target = try UmiTopology.pane(params.string("pane"), caller: caller)
            let direction = try UmiLayout.direction(params.string("direction"))
            // A tab at its limit makes room (`hid`).
            var (result, hid) = try UmiHidden.collectingHidden {
                try UmiLayout.split(target, direction: direction, options: UmiLayout.PaneOptions(params),
                                    ratio: params.double("ratio"), focus: params.bool("focus") ?? true)
            }
            if let first = hid.first { result["hid"] = first.umiID }
            return result

        case "pane.info":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            return UmiTopology.paneInfoJSON(pane)

        case "pane.focus":
            // A hidden pane is brought in first (at the right end; its tab makes room).
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let (_, hid) = UmiHidden.collectingHidden { UmiLayout.focusPane(pane, activate: true) }
            var result: [String: Any] = ["pane": pane.umiID]
            if let location = UmiTopology.locate(pane) {
                result["tab"] = location.tab.idString
                result["window"] = location.window.umiIDString
            }
            if let first = hid.first { result["hid"] = first.umiID }
            return result

        case "pane.hide":
            // Every pane a query matches (design/cli.md choice 3).
            let panes = try UmiTopology.panes(params.string("pane"), caller: caller)
            var conditions: [UmiHidden.Condition] = []
            for text in params.strings("until") ?? [] {
                if let seconds = UmiQuery.duration(text), seconds > 0 {
                    conditions.append(UmiHidden.Condition(query: nil, at: Date().addingTimeInterval(seconds)))
                } else {
                    _ = try UmiTopology.parseQuery(text)
                    conditions.append(UmiHidden.Condition(query: text, at: nil))
                }
            }
            for pane in panes {
                if let location = UmiTopology.locate(pane), !location.tab.isHidden(pane) {
                    let shownCount = location.window.tree(of: location.tab).root?.leaves().count ?? 0
                    let hidingHere = panes.filter { location.tab.contains($0) && !location.tab.isHidden($0) }.count
                    if hidingHere >= shownCount {
                        throw UmiError.failed("that would hide the last pane on show in tab \(location.tab.idString.prefix(8)) (a tab shows at least one)")
                    }
                }
            }
            for pane in panes {
                try UmiHidden.hide(pane)
                if !conditions.isEmpty { UmiHidden.setConditions(conditions, for: pane) }
            }
            return ["pane": panes[0].umiID, "panes": panes.map(\.umiID)]

        case "pane.show":
            let panes = try UmiTopology.panes(params.string("pane"), caller: caller)
            let focus = params.bool("focus") ?? false
            var hid: [String] = []
            for (index, pane) in panes.enumerated() {
                let (_, made) = try UmiHidden.collectingHidden {
                    try UmiHidden.show(pane, focus: focus && index == panes.count - 1)
                }
                hid += made.map(\.umiID)
            }
            return ["pane": panes[0].umiID, "panes": panes.map(\.umiID), "hid": hid]

        case "pane.until":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            return ["pane": pane.umiID, "until": (UmiHidden.conditions[pane.id] ?? []).map(\.json)]

        case "pane.close":
            // Every pane a query matches (design/cli.md choice 3).
            let panes = try UmiTopology.panes(params.string("pane"), caller: caller)
            for pane in panes { try UmiLayout.closePane(pane) }
            return ["pane": panes[0].umiID, "panes": panes.map(\.umiID), "closed": true]

        case "pane.zoom":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            try UmiLayout.toggleZoom(pane)
            return UmiTopology.paneInfoJSON(pane)

        case "pane.rename":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let name = params.string("name") ?? ""
            if !name.isEmpty, let other = UmiTopology.allSurfaces.first(where: { $0 !== pane && UmiState.shared.paneName($0.id) == name }) {
                throw UmiError.badRequest("another pane (\(other.umiID.prefix(8))) is already named \"\(name)\"")
            }
            UmiState.shared.setPaneName(pane.id, name)
            UmiEvents.shared.emit("pane.renamed", ["pane": pane.umiID, "name": name])
            return ["pane": pane.umiID, "name": name]

        case "pane.move":
            // Every pane a query matches, in its order (design/cli.md choice 3): the first goes where
            // the options say, each next one beside the one moved before it.
            var panes = try UmiTopology.panes(params.string("pane"), caller: caller)
            let focus = params.bool("focus") ?? true
            let direction = try UmiLayout.direction(params.string("direction"))
            let target = try params.string("to").map { try UmiTopology.resolvePane($0, caller: caller) }
            if let target, panes.count > 1 { panes.removeAll { $0 === target } }
            let pane = panes[0]
            let destination: UmiLayout.PaneDestination
            if let target {
                destination = .besidePane(target, direction)
            } else if let tabSelector = params.string("tab") {
                let (window, tab) = try UmiTopology.resolveTab(tabSelector, caller: caller)
                guard let anchor = (tab === window.selectedTab ? window.focusedSurface : nil)
                        .flatMap({ window.tree(of: tab).contains($0) ? $0 : nil }) ?? tab.effectiveFocusedSurface ?? window.tree(of: tab).root?.leftmostLeaf() else {
                    throw UmiError.notFound("the tab has no panes")
                }
                if anchor === pane, window.tree(of: tab).root?.leaves().count == 1 {
                    throw UmiError.badRequest("the pane is already the only pane of that tab")
                }
                destination = .besidePane(anchor === pane ? (window.tree(of: tab).root?.leaves().first { $0 !== pane } ?? anchor) : anchor, direction)
            } else if params.bool("new_tab") ?? false {
                let window = try params.string("window").map { try UmiTopology.resolveWindow($0, caller: caller) }
                    ?? UmiTopology.locate(pane)?.window
                guard let window else { throw UmiError.notFound("the pane isn't in a window") }
                destination = .newTab(window, index: nil)
            } else if params.bool("new_window") ?? false {
                destination = .newWindow
            } else if let windowSelector = params.string("window") {
                let window = try UmiTopology.resolveWindow(windowSelector, caller: caller)
                let tab = window.selectedTab
                let tree = window.tree(of: tab)
                guard let anchor = (window.focusedSurface.flatMap { tree.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface),
                      anchor !== pane else {
                    throw UmiError.badRequest("the pane is already there")
                }
                destination = .besidePane(anchor, direction)
            } else {
                throw UmiError.badRequest("give one of --to PANE, --tab T, --window W, --new-tab or --new-window")
            }
            let (location, hid) = try UmiHidden.collectingHidden { () throws -> UmiTopology.Location in
                var location = try UmiLayout.move(pane, to: destination, focus: focus && panes.count == 1)
                for (index, next) in panes.enumerated().dropFirst() {
                    location = try UmiLayout.move(next, to: .besidePane(panes[index - 1], direction), focus: focus && index == panes.count - 1)
                }
                return location
            }
            var result: [String: Any] = ["pane": pane.umiID, "panes": panes.map(\.umiID), "tab": location.tab.idString,
                                         "window": location.window.umiIDString]
            if let first = hid.first(where: { UmiTopology.locate($0)?.tab === location.tab }) ?? hid.first { result["hid"] = first.umiID }
            return result

        case "pane.swap":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let targetSelector = params.string("target") else { throw UmiError.badRequest("pane swap needs a TARGET pane") }
            let target = try UmiTopology.resolvePane(targetSelector, caller: caller)
            try UmiLayout.swap(pane, target)
            return ["pane": pane.umiID, "target": target.umiID]

        case "pane.resize":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            try UmiLayout.resize(pane, direction: params.string("direction") ?? "", amount: params.int("amount") ?? 5)
            return ["pane": pane.umiID]

        case "pane.send", "send":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let text = params.string("text") ?? ""
            let enter = params.bool("enter") ?? false
            try await UmiInput.send(text: text, to: pane, enter: enter)
            UmiAgentHooks.inputSent(pane: pane, text: text, keys: enter ? ["enter"] : [])
            return ["pane": pane.umiID]

        case "pane.keys", "keys":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let keys = params.strings("keys") ?? []
            try UmiInput.send(keys: keys, to: pane)
            UmiAgentHooks.inputSent(pane: pane, text: "", keys: keys)
            return ["pane": pane.umiID]

        case "pane.read", "read":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let outputOnly = params.bool("output_only") ?? false
            let bytes = UmiInput.outputBytes(pane)
            var text = UmiInput.read(pane,
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
                    text = UmiInput.readOutputTail(pane, rows: min(fresh, 1_000_000) + screenRows)
                }
            }
            return ["pane": pane.umiID, "text": text, "output_bytes": Int(clamping: bytes)]

        // MARK: Events, notifications, UI
        case "events.subscribe":
            var paneID: String?
            if let selector = params.string("pane") {
                paneID = try logPane(selector, caller: caller)
            }
            let filters = params.strings("filters") ?? []
            // `--since`: the activity log first, then the live stream. Both happen on this turn of the
            // main actor, so no event falls between them.
            if let since = params.double("since") {
                for event in UmiActivityLog.shared.events(since: Date(timeIntervalSince1970: since), until: nil,
                                                          filters: filters, pane: paneID) {
                    connection.sendRaw(event)
                }
            }
            UmiEvents.shared.addSubscriber(connection, filters: filters, pane: paneID)
            return ["subscribed": true]

        case "log":
            let pane = try params.string("pane").map { try logPane($0, caller: caller) }
            let events = UmiActivityLog.shared.events(since: params.double("since").map(Date.init(timeIntervalSince1970:)),
                                                      until: params.double("until").map(Date.init(timeIntervalSince1970:)),
                                                      filters: params.strings("filters") ?? [], pane: pane)
            return ["events": events]

        case "focus_log":
            let pane = try params.string("pane").map { try logPane($0, caller: caller) }
            let stretches = UmiFocusLog.shared.stretches(since: params.double("since").map(Date.init(timeIntervalSince1970:)),
                                                         until: params.double("until").map(Date.init(timeIntervalSince1970:)),
                                                         pane: pane)
            return ["stretches": stretches]

        case "notify":
            let pane = try? UmiTopology.pane(params.string("pane"), caller: caller)
            try await UmiNotify.post(title: params.string("title") ?? "", body: params.string("body"), pane: pane)
            return ["ok": true]

        case "sidebar":
            let state = UmiState.shared
            // The width is per window (S-8): the given window, else the caller's, else the current.
            // An unknown window changes nothing (L-4).
            let window = params.string("window") != nil
                ? try UmiTopology.window(params.string("window"), caller: caller)
                : try? UmiTopology.window(nil, caller: caller)
            // Shown or hidden per window, as Warp's left panel: the given window, else the
            // caller's, else the current; with no window, what new windows start with.
            func setVisible(_ visible: Bool) {
                if let window { UmiSidebarVisibility.set(visible, in: window) } else { state.sidebarVisible = visible }
            }
            if params.bool("toggle") ?? false { setVisible(!(window?.sidebarVisible ?? state.sidebarVisible)) }
            if let visible = params.bool("visible") { setVisible(visible) }
            if let mode = params.string("mode") {
                guard let parsed = UmiState.SidebarMode(rawValue: mode) else {
                    throw UmiError.badRequest("unknown sidebar mode \"\(mode)\" (use tabs, files or search)")
                }
                state.sidebarMode = parsed
                setVisible(true)
            }
            if let width = params.double("width") {
                guard let window else { throw UmiError.notFound("there are no Umi windows open") }
                window.sidebarWidth = UmiTheme.clampSidebarWidth(CGFloat(width))
                state.sidebarWidth = window.sidebarWidth
            }
            var json: [String: Any] = ["visible": window?.sidebarVisible ?? state.sidebarVisible,
                                       "mode": state.sidebarMode.rawValue]
            if let window {
                json["width"] = Double(window.sidebarWidth)
                json["window"] = window.umiIDString
            }
            return json

        case "reopen":
            return try UmiReopen.shared.reopen()
        case "reopen.list":
            return ["items": UmiReopen.shared.list()]

        case "screenshot":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard let path = params.string("path"), !path.isEmpty else { throw UmiError.badRequest("screenshot needs an output path") }
            try await UmiScreenshot.capture(window, to: path)
            return ["path": path, "window": window.umiIDString]

        // MARK: Editor
        case "editor.open":
            return try UmiEditor.handleOpen(params, caller: caller)
        case "editor.list":
            return try UmiEditor.handleList(params, caller: caller)
        case "editor.close":
            return try UmiEditor.handleClose(params, caller: caller)
        case "editor.mode":
            return try UmiEditor.handleMode(params, caller: caller)
        case "comments.wait":
            // `umi comments wait FILE`: this connection gets `comments.done` for that file (E-11).
            guard let path = params.string("path"), !path.isEmpty else { throw UmiError.badRequest("give a path") }
            let canonical = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
            UmiEvents.shared.addSubscriber(connection, filters: ["comments.done"], pane: nil, path: canonical)
            return ["waiting": true, "path": canonical, "open": !UmiCommentsUI.documents(at: canonical).isEmpty]

        // MARK: Updates
        case "update.check":
            return try await UmiUpdater.shared.check(userInitiated: false)
        case "update.status":
            return UmiUpdater.shared.status()
        case "update.answer":
            guard let answer = params.string("answer").flatMap(UmiUpdater.Answer.init(rawValue:)) else {
                throw UmiError.badRequest("answer is download, later, skip, not_now or install_now")
            }
            return try await UmiUpdater.shared.answer(answer)
        case "update.download":
            return try await UmiUpdater.shared.download()
        case "update.install_now":
            return try await UmiUpdater.shared.installNow(force: params.bool("force") ?? false)
        case "update.rollback":
            return try await UmiUpdater.shared.rollback(force: params.bool("force") ?? false)

        // MARK: Internal (not part of the CLI contract): scripted checks of menu and editor
        // paths that otherwise need the accessibility tree.
        case "debug.menu":
            return ["items": UmiDebug.menuItems()]
        case "debug.dock_badge":
            return ["badge": NSApp.dockTile.badgeLabel ?? ""]
        case "debug.undo":
            guard let um = (NSApp.delegate as? AppDelegate)?.undoManager else { return [:] }
            return ["can_undo": um.canUndo, "can_redo": um.canRedo, "undo": um.undoActionName,
                    "redo": um.redoActionName, "level": um.groupingLevel]
        case "debug.confirm":
            // Whether closing each window (and so quitting) would ask first.
            return ["windows": UmiTopology.windows.map {
                ["window": $0.umiIDString, "needs_confirmation": !$0.windowCanBeClosedWithoutConfirmation()]
            }]
        case "debug.menu.perform":
            guard let title = params.string("title") else { throw UmiError.badRequest("give a menu item title") }
            try UmiDebug.performMenuItem(title)
            return ["performed": title]
        case "debug.editor.type":
            let (_, tab) = try UmiEditor.targetTab(params, caller: caller, createWindow: false)
            guard let doc = params.string("path").flatMap({ tab.editor.document(for: URL(fileURLWithPath: $0)) }) ?? tab.editor.active else {
                throw UmiError.notFound("no such document")
            }
            let text = params.string("text") ?? ""
            if params.bool("replace") ?? false || !text.isEmpty {
                doc.text = (params.bool("replace") ?? false) ? text : doc.text + text
            }
            var json = UmiEditor.json(doc, pane: tab.editor.pane(of: doc))
            json["text"] = doc.text
            json["error"] = doc.error ?? ""
            return json
        case "debug.blocks":
            // Warp's look in a pane (the renderer's blocks): whether it's on, how far the view is
            // moved down, each row's part in a block, and each block's folder, command, state and
            // duration.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            return UmiInput.blocks(pane)
        case "debug.terminal":
            // The terminal's look in a pane: the renderer's report (font, cell, cursor, padding)
            // with the scrollbar and the bell's effects.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            return UmiInput.blocks(pane).merging(UmiScroller.debugInfo(pane)) { _, new in new }
        case "debug.terminal.scroller":
            // An image of a pane's scrollbar as drawn, over the pane's background.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let path = params.string("path"), !path.isEmpty else { throw UmiError.badRequest("give a path") }
            return try UmiScroller.capture(pane, to: path)
        case "debug.terminal.action":
            // Run a Ghostty binding action (such as `select_all`) on a pane, wherever focus is.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let action = params.string("action"), let surface = pane.surface else {
                throw UmiError.badRequest("give a pane and an action")
            }
            return ["ok": ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))]
        case "debug.selection":
            // The text the user selected in a pane (no clipboard involved).
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            return ["text": UmiInput.selection(pane) ?? NSNull()]
        case "debug.editor.focus":
            let (window, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            UmiLayout.focusTab(tab, in: window)
            // focusTab gives the tab's focused pane keyboard focus on a later turn of the main
            // loop; the editor takes it after that, as a click on it would.
            try? await Task.sleep(nanoseconds: 300_000_000)
            UmiDebug.focusEditor(in: window, selectEnd: params.bool("select_end") ?? false)
            return ["ok": true]

        case "debug.focus_log":
            // The focus log's idle limit and the screen lock, for scripted checks (isolated instances only).
            guard UmiPaths.isIsolated else { throw UmiError.badRequest("only an isolated instance takes these") }
            if let seconds = params.double("idle_after") { UmiFocusLog.shared.idleAfter = seconds }
            if let locked = params.bool("locked") { UmiFocusLog.shared.assumeLocked = locked }
            UmiFocusLog.shared.update()
            return ["idle_after": UmiFocusLog.shared.idleAfter, "locked": UmiFocusLog.shared.assumeLocked,
                    "last_input": UmiTime.iso(UmiFocusLog.shared.lastInput)]

        case "debug.update.input":
            // Someone typing or clicking in the app, as the event monitor sees it.
            UmiQuiet.userActed()
            return UmiQuiet.report()
        case "debug.update.clock":
            // Fake time for the quiet-moment checks (isolated instances only).
            guard UmiPaths.isIsolated else { throw UmiError.badRequest("only an isolated instance takes fake time") }
            UmiQuiet.clockOffset += TimeInterval(params.int("advance") ?? 0)
            return UmiQuiet.report()

        case "debug.ui.comments":
            return try await UmiCommentsUI.debug(params)
        case "debug.ui.markdown":
            return try await UmiMarkdownScript.debug(params)
        case let ui where ui.hasPrefix("debug.ui."):
            return try UmiUIDebug.handle(method, params, caller: caller)

        default:
            if UmiNavigationRPC.methods.contains(method) {
                return try await UmiNavigationRPC.handle(method, params, caller: caller)
            }
            if UmiListsRPC.methods.contains(method) {
                return try await UmiListsRPC.handle(method, params, caller: caller)
            }
            if UmiAttributesRPC.methods.contains(method) {
                return try UmiAttributesRPC.handle(method, params, caller: caller)
            }
            if UmiLaunchConfigs.methods.contains(method) {
                return try UmiLaunchConfigs.handle(method, params)
            }
            throw UmiError.badRequest("unknown method \(method)")
        }
    }

    /// A pane for the logs: an open pane's selector, or an id (or id prefix) of a pane that may be
    /// gone, since the logs keep closed panes.
    private static func logPane(_ selector: String, caller: UmiCaller) throws -> String {
        do {
            return try UmiTopology.resolvePane(selector, caller: caller).umiID
        } catch let error as UmiError {
            let lowered = selector.lowercased()
            guard !lowered.isEmpty, lowered.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { throw error }
            return lowered
        }
    }

    private static func badColor(_ name: String) -> UmiError {
        UmiError.badRequest("unknown color \"\(name)\" (use red, green, yellow, blue, magenta, cyan, purple, pink, orange, teal, graphite or none)")
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
enum UmiUndo {
    static func requestDidEnd() {
        guard let manager = (NSApp.delegate as? AppDelegate)?.undoManager, manager.groupingLevel > 0 else { return }
        guard let event = NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            subtype: 0x7465, data1: 0, data2: 0) else { return }
        NSApp.postEvent(event, atStart: false)
    }
}

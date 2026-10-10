import AppKit

/// Internal `debug.ui.*` control methods (not part of the CLI contract): scripted checks of
/// sidebar rows, drops, drags, the row menu, dividers and the open-file path, which otherwise
/// need a mouse. Each one runs the same code the UI runs.
@MainActor
enum TernUIDebug {
    static func handle(_ method: String, _ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        switch method {
        case "debug.ui.rows":
            let window = try TernTopology.window(params.string("window"), caller: caller)
            return ["window": window.ternIDString, "sidebar_width": Double(window.sidebarWidth),
                    "rows": window.tabs.map { TernSidebarRowModel(tab: $0, in: window).json() }]

        case "debug.ui.attention.set":
            // Stands in for the agent engine (TernAttention's writer).
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            guard let kind = params.string("kind").flatMap(TernAttention.Kind.init(rawValue:)) else {
                throw TernError.badRequest("kind is claude or codex")
            }
            let mark: TernAttention.Mark
            switch params.string("mark") ?? "none" {
            case "none": mark = .none
            case "finished": mark = .finished
            case "needs_you": mark = .needsYou
            default: throw TernError.badRequest("mark is none, finished or needs_you")
            }
            let stopped = params.bool("stopped") ?? (mark != .none)
            TernAttention.shared.set(.init(session: params.string("session"), kind: kind,
                                           title: params.string("title") ?? "", status: params.string("status") ?? "idle",
                                           live: params.bool("live") ?? true, mark: mark,
                                           lastStop: stopped ? Date() : nil), forPane: pane.id)
            return attention()

        case "debug.ui.attention.clear":
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            TernAttention.shared.set(nil, forPane: pane.id)
            return attention()

        case "debug.ui.attention":
            return attention()

        case "debug.ui.assume_active":
            // Without the screen the app can't become active: count it as active (and the
            // current window as key) for checks of what looking does.
            TernLooking.assumeActive = params.bool("on") ?? true
            return attention()

        case "debug.ui.drop":
            let window = try TernTopology.window(params.string("window"), caller: caller)
            guard let zone = params.string("zone").flatMap(TernSidebarDrop.Zone.init(rawValue:)) else {
                throw TernError.badRequest("zone is before, into, after or end")
            }
            let row = try params.string("row").map { try TernTopology.resolveTab($0, caller: caller, window: window).1 }
            let payload: TernSidebarDrop.Payload
            if let pane = params.string("pane") {
                payload = .pane(try TernTopology.resolvePane(pane, caller: caller))
            } else if let tab = params.string("tab") {
                let (source, dragged) = try TernTopology.resolveTab(tab, caller: caller)
                payload = .tab(dragged, source)
            } else {
                throw TernError.badRequest("give a pane or a tab to drop")
            }
            guard let location = TernSidebarDrop.perform(payload, zone: zone, row: row, in: window) else {
                return ["dropped": false]
            }
            return ["dropped": true, "pane": location.pane.ternID, "tab": location.tab.idString,
                    "window": location.window.ternIDString]

        case "debug.ui.drag_out":
            let (_, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            let point = NSPoint(x: params.double("x") ?? 0, y: params.double("y") ?? 0)
            guard let window = TernTabDrag.droppedOutside(tab, at: point) else { return ["window": ""] }
            return ["window": window.ternIDString, "frame": frameJSON(window.window?.frame ?? .zero)]

        case "debug.ui.menu":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            let items = TernTabMenu.flatten(TernTabMenu.items(for: tab, in: window, rename: {}))
            return ["items": items.map { entry in
                ["title": entry.item.title, "path": entry.path.joined(separator: " > "),
                 "enabled": entry.item.enabled, "checked": entry.item.checked, "submenu": !entry.item.children.isEmpty]
            }]

        case "debug.ui.menu.perform":
            let (window, tab) = try TernTopology.tab(params.string("tab"), caller: caller)
            guard let path = params.string("title") else { throw TernError.badRequest("give the item's title (or path)") }
            let items = TernTabMenu.flatten(TernTabMenu.items(for: tab, in: window, rename: nil))
            guard let entry = items.first(where: { $0.path.joined(separator: " > ") == path })
                    ?? items.first(where: { $0.item.title == path }) else {
                throw TernError.notFound("no menu item \"\(path)\"")
            }
            guard entry.item.enabled, let action = entry.item.action else {
                throw TernError.failed("the menu item \"\(path)\" is disabled")
            }
            // Copies go to a private pasteboard, never the user's clipboard.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.tern.debug.\(TernPaths.instanceID)"))
            pasteboard.clearContents()
            TernTabMenu.pasteboard = pasteboard
            defer { TernTabMenu.pasteboard = .general }
            action()
            return ["performed": path, "copied": pasteboard.string(forType: .string) ?? ""]

        case "debug.ui.split.drop":
            // Dropping a pane on another pane's edge (the split view's drop target).
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            guard let targetSelector = params.string("target") else { throw TernError.badRequest("give a target pane") }
            let target = try TernTopology.resolvePane(targetSelector, caller: caller)
            guard let zone = params.string("zone").flatMap(TerminalSplitDropZone.init(rawValue:)) else {
                throw TernError.badRequest("zone is top, bottom, left or right")
            }
            guard let location = TernTopology.locate(target), location.tab === location.window.selectedTab else {
                throw TernError.badRequest("the target pane must be in its window's shown tab")
            }
            location.window.performSplitAction(.drop(.init(payload: pane, destination: target, zone: zone)))
            return ["pane": pane.ternID]

        case "debug.ui.split.divider":
            // The divider of the split right above a pane: double-click it, or drag it.
            let pane = try TernTopology.pane(params.string("pane"), caller: caller)
            guard let location = TernTopology.locate(pane), location.tab === location.window.selectedTab else {
                throw TernError.badRequest("the pane must be in its window's shown tab")
            }
            let tree = location.window.surfaceTree
            guard let root = tree.root, let path = root.path(to: .leaf(view: pane)), !path.isEmpty,
                  let split = root.node(at: .init(path: Array(path.path.dropLast()))) else {
                throw TernError.badRequest("the pane isn't split")
            }
            switch params.string("action") ?? "equalize" {
            case "equalize":
                location.window.performSplitAction(.equalize(split))
            case "move":
                guard let ratio = params.double("ratio"), ratio > 0, ratio < 1 else {
                    throw TernError.badRequest("give a ratio between 0 and 1")
                }
                location.window.performSplitAction(.resize(.init(node: split, ratio: ratio)))
            default:
                throw TernError.badRequest("action is equalize or move")
            }
            return ["pane": pane.ternID]

        case "debug.ui.open_file":
            // What Finder's double-click and `open FILE` call (AppDelegate's openFile).
            guard let path = params.string("path") else { throw TernError.badRequest("give a path") }
            let (window, tab) = try TernEditor.open(URL(fileURLWithPath: path), inCurrentTab: false)
            return ["tab": tab.idString, "window": window.ternIDString]

        default:
            throw TernError.badRequest("unknown method \(method)")
        }
    }

    private static func attention() -> [String: Any] {
        var panes: [String: Any] = [:]
        for (id, agent) in TernAttention.shared.panes {
            panes[id.uuidString.lowercased()] = ["kind": agent.kind.rawValue, "title": agent.title, "status": agent.status,
                                                 "mark": agent.mark == .none ? "none" : (agent.mark == .finished ? "finished" : "needs_you")]
        }
        return ["panes": panes, "needing_you": TernAttention.shared.needingYouCount,
                "badge": NSApp.dockTile.badgeLabel ?? "", "looked_at": TernLooking.lookedAt?.ternID ?? "",
                "active": NSApp.isActive]
    }

    private static func frameJSON(_ frame: NSRect) -> [String: Any] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }
}

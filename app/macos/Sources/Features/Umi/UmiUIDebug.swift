import AppKit
import GhosttyKit

/// Internal `debug.ui.*` control methods (not part of the CLI contract): scripted checks of
/// sidebar rows, drops, drags, the row menu, dividers and the open-file path, which otherwise
/// need a mouse. Each one runs the same code the UI runs.
@MainActor
enum UmiUIDebug {
    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        switch method {
        case "debug.ui.rows":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            return ["window": window.umiIDString, "sidebar_width": Double(window.sidebarWidth),
                    "frame": frameJSON(window.window?.frame ?? .zero),
                    "rows": window.tabs.map { UmiSidebarRowModel(tab: $0, in: window).json() }]

        case "debug.ui.open_url":
            // A link ⌘-clicked in a pane: what the terminal's open-URL action runs (E-12).
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let url = params.string("url") else { throw UmiError.badRequest("url is required") }
            return ["web_pane": UmiWebPanes.openFromTerminal(url, pane: pane)]

        case "debug.ui.attention.set":
            // Stands in for the agent engine (UmiAttention's writer).
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let kind = params.string("kind").flatMap(UmiAttention.Kind.init(rawValue:)) else {
                throw UmiError.badRequest("kind is claude or codex")
            }
            let mark: UmiAttention.Mark
            switch params.string("mark") ?? "none" {
            case "none": mark = .none
            case "finished": mark = .finished
            case "needs_you": mark = .needsYou
            default: throw UmiError.badRequest("mark is none, finished or needs_you")
            }
            let stopped = params.bool("stopped") ?? (mark != .none)
            UmiAttention.shared.set(.init(session: params.string("session"), kind: kind,
                                           title: params.string("title") ?? "", status: params.string("status") ?? "idle",
                                           live: params.bool("live") ?? true, mark: mark,
                                           lastStop: stopped ? Date() : nil), forPane: pane.id)
            return attention()

        case "debug.ui.attention.clear":
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            UmiAttention.shared.set(nil, forPane: pane.id)
            return attention()

        case "debug.ui.attention":
            return attention()

        case "debug.ui.assume_active":
            // Without the screen the app can't become active: count it as active (and the
            // current window as key) for checks of what looking does.
            UmiLooking.assumeActive = params.bool("on") ?? true
            return attention()

        case "debug.ui.drop":
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            guard let zone = params.string("zone").flatMap(UmiSidebarDrop.Zone.init(rawValue:)) else {
                throw UmiError.badRequest("zone is before, into, after or end")
            }
            let row = try params.string("row").map { try UmiTopology.resolveTab($0, caller: caller, window: window).1 }
            let payload: UmiSidebarDrop.Payload
            if let pane = params.string("pane") {
                payload = .pane(try UmiTopology.resolvePane(pane, caller: caller))
            } else if let tab = params.string("tab") {
                let (source, dragged) = try UmiTopology.resolveTab(tab, caller: caller)
                payload = .tab(dragged, source)
            } else {
                throw UmiError.badRequest("give a pane or a tab to drop")
            }
            guard let location = UmiSidebarDrop.perform(payload, zone: zone, row: row, in: window) else {
                return ["dropped": false]
            }
            return ["dropped": true, "pane": location.pane.umiID, "tab": location.tab.idString,
                    "window": location.window.umiIDString]

        case "debug.ui.drag_out":
            let (_, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            let point = NSPoint(x: params.double("x") ?? 0, y: params.double("y") ?? 0)
            guard let window = UmiTabDrag.droppedOutside(tab, at: point) else { return ["window": ""] }
            return ["window": window.umiIDString, "frame": frameJSON(window.window?.frame ?? .zero)]

        case "debug.ui.menu":
            let (window, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            let items = UmiTabMenu.flatten(UmiTabMenu.items(for: tab, in: window, rename: {}))
            return ["items": items.map { entry in
                ["title": entry.item.title, "path": entry.path.joined(separator: " > "),
                 "enabled": entry.item.enabled, "checked": entry.item.checked, "submenu": !entry.item.children.isEmpty]
            }]

        case "debug.ui.menu.perform":
            let (window, tab) = try UmiTopology.tab(params.string("tab"), caller: caller)
            guard let path = params.string("title") else { throw UmiError.badRequest("give the item's title (or path)") }
            let items = UmiTabMenu.flatten(UmiTabMenu.items(for: tab, in: window, rename: nil))
            guard let entry = items.first(where: { $0.path.joined(separator: " > ") == path })
                    ?? items.first(where: { $0.item.title == path }) else {
                throw UmiError.notFound("no menu item \"\(path)\"")
            }
            guard entry.item.enabled, let action = entry.item.action else {
                throw UmiError.failed("the menu item \"\(path)\" is disabled")
            }
            // Copies go to a private pasteboard, never the user's clipboard.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.umi.debug.\(UmiPaths.instanceID)"))
            pasteboard.clearContents()
            UmiTabMenu.pasteboard = pasteboard
            defer { UmiTabMenu.pasteboard = .general }
            action()
            return ["performed": path, "copied": pasteboard.string(forType: .string) ?? ""]

        case "debug.ui.split.drop":
            // Dropping a pane on another pane's edge (the split view's drop target).
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let targetSelector = params.string("target") else { throw UmiError.badRequest("give a target pane") }
            let target = try UmiTopology.resolvePane(targetSelector, caller: caller)
            guard let zone = params.string("zone").flatMap(TerminalSplitDropZone.init(rawValue:)) else {
                throw UmiError.badRequest("zone is top, bottom, left, right or center")
            }
            guard let location = UmiTopology.locate(target), location.tab === location.window.selectedTab else {
                throw UmiError.badRequest("the target pane must be in its window's shown tab")
            }
            location.window.performSplitAction(.drop(.init(payload: pane, destination: target, zone: zone)))
            return ["pane": pane.umiID]

        case "debug.ui.pane.tabdrop":
            // Dropping a dragged pane on the "previous tab" (top centre) or "next tab" (bottom
            // centre) target over the panes.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let target: UmiPaneTabDropTargets.Target = ["previous": .previous, "next": .next][params.string("target") ?? ""] else {
                throw UmiError.badRequest("target is previous or next")
            }
            guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
            let moved = try UmiPaneTabDropTargets.move(pane, target, in: location.window)
            return ["pane": pane.umiID, "tab": moved.tab.idString]

        case "debug.ui.split.divider":
            // The divider of the split right above a pane: double-click it, or drag it.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            guard let location = UmiTopology.locate(pane), location.tab === location.window.selectedTab else {
                throw UmiError.badRequest("the pane must be in its window's shown tab")
            }
            let tree = location.window.surfaceTree
            guard let root = tree.root, let path = root.path(to: .leaf(view: pane)), !path.isEmpty,
                  let split = root.node(at: .init(path: Array(path.path.dropLast()))) else {
                throw UmiError.badRequest("the pane isn't split")
            }
            switch params.string("action") ?? "equalize" {
            case "equalize":
                location.window.performSplitAction(.equalize(split))
            case "move":
                guard let ratio = params.double("ratio"), ratio > 0, ratio < 1 else {
                    throw UmiError.badRequest("give a ratio between 0 and 1")
                }
                location.window.performSplitAction(.resize(.init(node: split, ratio: ratio)))
            default:
                throw UmiError.badRequest("action is equalize or move")
            }
            return ["pane": pane.umiID]

        case "debug.ui.zoom":
            // The interface's zoom and the terminals' font size (L-33), and a pane's cell size.
            let zoom = UmiZoom.shared
            var out: [String: Any] = ["level": zoom.level, "font_size": Double(zoom.baseFontSize),
                                      "terminal_font_size": Double(zoom.terminalFontSize)]
            if let pane = try? UmiTopology.pane(params.string("pane"), caller: caller), let surface = pane.surface {
                let size = ghostty_surface_size(surface)
                out["cell_width_px"] = Int(size.cell_width_px)
                out["cell_height_px"] = Int(size.cell_height_px)
            }
            return out

        case "debug.ui.pane.menu":
            // The terminal's right-click menu (L-31): its items, or choose one by title.
            let pane = try UmiTopology.pane(params.string("pane"), caller: caller)
            let entries = UmiPaneMenu.entries(for: pane)
            if let title = params.string("title") {
                guard let entry = entries.compactMap({ $0 }).first(where: { $0.title == title }) else {
                    throw UmiError.notFound("no menu item \"\(title)\"")
                }
                guard entry.enabled else { throw UmiError.failed("the menu item \"\(title)\" is disabled") }
                entry.action()
                return ["performed": title]
            }
            return ["items": entries.map { entry -> [String: Any] in
                guard let entry else { return ["separator": true] }
                return ["title": entry.title, "enabled": entry.enabled, "checked": entry.checked]
            }]

        case "debug.ui.views":
            // The window's AppKit views, as an indented list of class names and frames.
            let window = try UmiTopology.window(params.string("window"), caller: caller)
            var lines: [String] = []
            func walk(_ view: NSView, _ depth: Int) {
                guard depth < (params.int("depth") ?? 40) else { return }
                let f = view.frame
                lines.append(String(repeating: "  ", count: depth)
                    + "\(type(of: view)) \(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))x\(Int(f.height))\(view.isHidden ? " hidden" : "")")
                for sub in view.subviews { walk(sub, depth + 1) }
            }
            if let content = window.window?.contentView { walk(content, 0) }
            return ["views": lines]

        case "debug.ui.open_file":
            // What Finder's double-click and `open FILE` call (AppDelegate's openFile).
            guard let path = params.string("path") else { throw UmiError.badRequest("give a path") }
            let (window, tab) = try UmiEditor.open(URL(fileURLWithPath: path), inCurrentTab: false)
            return ["tab": tab.idString, "window": window.umiIDString]

        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }

    private static func attention() -> [String: Any] {
        var panes: [String: Any] = [:]
        for (id, agent) in UmiAttention.shared.panes {
            panes[id.uuidString.lowercased()] = ["kind": agent.kind.rawValue, "title": agent.title, "status": agent.status,
                                                 "mark": agent.mark == .none ? "none" : (agent.mark == .finished ? "finished" : "needs_you")]
        }
        return ["panes": panes, "needing_you": UmiAttention.shared.needingYouCount,
                "badge": NSApp.dockTile.badgeLabel ?? "", "looked_at": UmiLooking.lookedAt?.umiID ?? "",
                "active": NSApp.isActive]
    }

    private static func frameJSON(_ frame: NSRect) -> [String: Any] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }
}

import AppKit
import SwiftUI

/// A window's drawer (attention-ui.md, "The drawer"; prototypes/drawer.html, option B): a place
/// that rises over the lower half of the tab without changing its layout, shown and put away by a
/// key. It belongs to the window: its panes left their tabs, keep running, don't count toward a
/// tab's three and aren't in the strip. One of them is on show while the drawer is open.
@MainActor
final class UmiDrawerModel: ObservableObject {
    /// The drawer's panes, in the order they came in.
    @Published fileprivate(set) var panes: [Ghostty.SurfaceView] = []
    @Published fileprivate(set) var isOpen = false
    /// The pane the drawer shows (when open), or showed last.
    @Published fileprivate(set) var current: Ghostty.SurfaceView?
    /// The tab each pane came from (by id), where hiding it puts it back (design/cli.md choice 6).
    fileprivate(set) var origins: [UUID: UUID] = [:]
    /// Bumped to build the panel's terminal view again when its pane didn't make it into the window
    /// (a pane taken out of a tree in the same turn can be left out by AppKit's view moves).
    @Published fileprivate(set) var renderToken = 0
    /// True for the turn a pane left a tree for the drawer: the panel waits for the tree to let go of
    /// its view before showing it.
    @Published fileprivate(set) var settling = false

    func contains(_ pane: Ghostty.SurfaceView) -> Bool { panes.contains { $0 === pane } }

    /// The pane on show in the drawer, if it is open.
    var showing: Ghostty.SurfaceView? { isOpen ? current : nil }

    /// Drawer panes that wait for the user while the drawer is closed: their indicator is "needs you".
    var waiting: [Ghostty.SurfaceView] {
        guard !isOpen else { return [] }
        return panes.filter { UmiIndicator.state(of: $0) == .needsYou }
    }
}

@MainActor
enum UmiDrawer {
    /// The drawer's share of the panes' height (the prototype's 52%).
    static let heightShare: CGFloat = 0.52
    /// Its header: a chip per pane, and what can be done with the one on show.
    static let headerHeight: CGFloat = 26

    // MARK: Where panes are

    /// The window whose drawer holds the pane.
    static func window(holding pane: Ghostty.SurfaceView) -> TerminalController? {
        UmiTopology.windows.first { $0.drawer.contains(pane) }
    }

    /// Whether any window's drawer holds a pane (cheap check for every tree change).
    private(set) static var anyPanes = false

    private static func recount() {
        anyPanes = UmiTopology.windows.contains { !$0.drawer.panes.isEmpty }
    }

    // MARK: Showing and hiding

    /// `drawer show PANE…`: move each pane into the window's drawer (it leaves its tab), and open
    /// the drawer on the first, focused.
    static func show(_ panes: [Ghostty.SurfaceView], in window: TerminalController, focus: Bool = true) throws {
        guard let first = panes.first else { throw UmiError.notFound("no pane to show in the drawer") }
        for pane in panes { try take(pane, into: window) }
        open(window, on: first, focus: focus)
    }

    /// `drawer show` with no pane: open the drawer as it was.
    static func open(_ window: TerminalController, focus: Bool = true) throws {
        guard let pane = window.drawer.current ?? window.drawer.panes.first else {
            throw UmiError.notFound("the drawer is empty (put a pane in it with `\(UmiPaths.cliName) drawer show PANE`)")
        }
        open(window, on: pane, focus: focus)
    }

    /// `drawer hide`: close it; its panes stay in it and keep running, and focus goes back to the pane
    /// focused before it opened.
    static func close(_ window: TerminalController, refocus: Bool = true) {
        let drawer = window.drawer
        guard drawer.isOpen else { return }
        let pane = drawer.current
        let hadFocus = pane.map { hasFocus($0, in: window) } ?? false
        drawer.isOpen = false
        window.setOccluded(drawer.panes, occluded: true)
        if refocus && hadFocus {
            // The tab's own focused pane: the one focused before the drawer took focus (the drawer's
            // pane never becomes a tab's focused pane), or the one the user focused since.
            let tab = window.selectedTab
            if let back = tab.effectiveFocusedSurface {
                tab.focusedSurface = back
                window.focusedSurface = back
                if window.window?.isKeyWindow ?? false {
                    DispatchQueue.main.async { Ghostty.moveFocus(to: back) }
                }
            }
        }
        var data: [String: Any] = ["window": window.umiIDString]
        if let pane { data["pane"] = pane.umiID }
        UmiEvents.shared.emit("drawer.closed", data)
        UmiLooking.focusChanged(in: window)
        UmiState.shared.layoutDidChange()
    }

    /// `drawer toggle [PANE…]`: show when closed or showing another pane, else put it away.
    static func toggle(_ panes: [Ghostty.SurfaceView]?, in window: TerminalController) throws {
        let drawer = window.drawer
        guard let panes, let first = panes.first else {
            if drawer.isOpen { close(window) } else { try open(window) }
            return
        }
        if drawer.isOpen, let current = drawer.current, panes.contains(where: { $0 === current }) {
            close(window)
        } else {
            try show(panes, in: window)
            _ = first
        }
    }

    /// `drawer next|prev`: the next or previous pane in the drawer, on show and focused.
    static func cycle(_ window: TerminalController, by offset: Int) throws {
        let panes = window.drawer.panes
        guard !panes.isEmpty else { throw UmiError.notFound("the drawer is empty") }
        let index = window.drawer.current.flatMap { current in panes.firstIndex { $0 === current } } ?? (offset > 0 ? -1 : 0)
        let next = panes[((index + offset) % panes.count + panes.count) % panes.count]
        open(window, on: next, focus: true)
    }

    /// Open the window's drawer on one of its panes.
    private static func open(_ window: TerminalController, on pane: Ghostty.SurfaceView, focus: Bool) {
        let drawer = window.drawer
        guard drawer.contains(pane) else { return }
        let wasOpen = drawer.isOpen
        let changed = !wasOpen || drawer.current !== pane
        drawer.current = pane
        drawer.isOpen = true
        window.setOccluded(drawer.panes.filter { $0 !== pane }, occluded: true)
        // Start at the size it will have, so its program sees the right columns and rows.
        let size = panelSize(in: window)
        if size.width > 0, size.height > 0 {
            pane.frame = CGRect(origin: .zero, size: size)
            pane.sizeDidChange(size)
        }
        DispatchQueue.main.async { window.setOccluded([pane], occluded: !window.drawer.isOpen || window.drawer.current !== pane) }
        ensureShown(pane, in: window)
        if focus {
            UmiTopology.windowBecameCurrent(window)
            window.window?.makeKeyAndOrderFront(nil)
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            focusPane(pane, in: window)
        }
        if changed {
            UmiEvents.shared.emit("drawer.opened", ["window": window.umiIDString, "pane": pane.umiID])
        }
        UmiState.shared.layoutDidChange()
    }

    /// Check that the panel's terminal made it into the window; if not, build the view again.
    private static func ensureShown(_ pane: Ghostty.SurfaceView, in window: TerminalController, attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard window.drawer.showing === pane, window.window != nil else { return }
            if pane.window === window.window, pane.superview != nil { return }
            guard attempt < 4 else { return }
            window.drawer.renderToken += 1
            ensureShown(pane, in: window, attempt: attempt + 1)
        }
    }

    /// Give the drawer's pane keyboard focus once its view is in the window.
    private static func focusPane(_ pane: Ghostty.SurfaceView, in window: TerminalController, attempt: Int = 0) {
        let delay = attempt == 0 ? 0 : 0.05 * Double(1 << min(attempt - 1, 4))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard window.drawer.showing === pane else { return }
            guard let host = pane.window else {
                if attempt < 8 { focusPane(pane, in: window, attempt: attempt + 1) }
                return
            }
            host.makeFirstResponder(pane)
            if window.focusedSurface !== pane { window.focusedSurfaceDidChange(to: pane) }
            UmiLooking.focusChanged(in: window)
            UmiEvents.shared.emit("pane.focused", ["pane": pane.umiID, "window": window.umiIDString, "in_drawer": true])
        }
    }

    /// Whether the drawer pane has keyboard focus in its window.
    static func hasFocus(_ pane: Ghostty.SurfaceView, in window: TerminalController) -> Bool {
        window.focusedSurface === pane || window.window?.firstResponder === pane
    }

    /// The size the drawer's terminal gets: the panes' width, its share of their height less the header.
    static func panelSize(in window: TerminalController) -> CGSize {
        var area = window.terminalAreaSize
        if area.width <= 0 || area.height <= 0 { area = window.surfaceTree.viewBounds() }
        guard area.width > 0, area.height > 0 else { return .zero }
        return CGSize(width: area.width, height: max((area.height * heightShare).rounded() - headerHeight - 1, 40))
    }

    // MARK: Panes coming in and going out

    /// Move a pane into the window's drawer: out of its tab (on show or hidden), or out of another
    /// window's drawer. A tab left with no pane closes; the window's only pane can't go.
    private static func take(_ pane: Ghostty.SurfaceView, into window: TerminalController) throws {
        if window.drawer.contains(pane) { return }
        if let other = Self.window(holding: pane) {
            let origin = other.drawer.origins[pane.id]
            release(pane, from: other)
            append(pane, to: window, origin: origin)
            UmiEvents.shared.emit("pane.moved", ["pane": pane.umiID,
                                                 "from": ["window": other.umiIDString, "drawer": true],
                                                 "to": ["window": window.umiIDString, "drawer": true],
                                                 "window": window.umiIDString])
            return
        }
        guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
        let tab = location.tab
        let source = location.window
        let tree = source.tree(of: tab)
        let index = (tree.root?.leaves().firstIndex { $0 === pane } ?? 0) + 1
        if tab.isHidden(pane) {
            UmiHidden.detach(pane, from: tab)
        } else {
            guard let node = tree.root?.node(view: pane) else { throw UmiError.notFound("the pane isn't in its tab") }
            let alone = tree.root?.leaves().count == 1 && tab.hidden.isEmpty
            if alone, source.tabs.count == 1, source === window {
                throw UmiError.failed("it's the window's only pane (the drawer belongs to the window)")
            }
            let focusedHere = tab.focusedSurface === pane || (tab === source.selectedTab && source.focusedSurface === pane)
            window.drawer.settling = true
            DispatchQueue.main.async { window.drawer.settling = false }
            let newTree = UmiHidden.refill(tree.removing(node), tab: tab, window: source)
            if newTree.isEmpty {
                source.detachTab(tab, focusNeighbor: false)
                UmiEvents.shared.emit("tab.closed", ["tab": tab.idString, "window": source.umiIDString])
            } else {
                source.setTree(SplitTree(root: newTree.root, zoomed: nil), for: tab)
                if focusedHere, let next = UmiFocusHistory.mostRecent(among: newTree.root?.leaves() ?? []) ?? newTree.root?.leaves().first {
                    tab.focusedSurface = next
                    if tab === source.selectedTab { source.focusedSurface = next }
                }
            }
        }
        append(pane, to: window, origin: tab.id)
        UmiEvents.shared.emit("pane.moved", ["pane": pane.umiID,
                                             "from": ["tab": tab.idString, "window": source.umiIDString, "index": index],
                                             "to": ["window": window.umiIDString, "drawer": true],
                                             "from_tab": tab.idString, "from_window": source.umiIDString,
                                             "window": window.umiIDString])
    }

    private static func append(_ pane: Ghostty.SurfaceView, to window: TerminalController, origin: UUID?) {
        window.drawer.panes.append(pane)
        if let origin { window.drawer.origins[pane.id] = origin }
        window.setOccluded([pane], occluded: true)
        recount()
        UmiState.shared.layoutDidChange()
    }

    /// Take a pane out of a drawer without closing it. The drawer closes if it showed it.
    private static func release(_ pane: Ghostty.SurfaceView, from window: TerminalController, refocus: Bool = false) {
        let drawer = window.drawer
        guard drawer.contains(pane) else { return }
        if drawer.current === pane {
            if drawer.isOpen { close(window, refocus: refocus) }
            drawer.current = nil
        }
        drawer.panes.removeAll { $0 === pane }
        drawer.origins[pane.id] = nil
        if drawer.current == nil { drawer.current = drawer.panes.first }
        recount()
        UmiState.shared.layoutDidChange()
    }

    /// `drawer dock [PANE]`: from the drawer into the current tab's layout, to the right of its
    /// focused pane, focused (`strip.make-room` applies). Returns the panes hidden to make room.
    @discardableResult
    static func dock(_ pane: Ghostty.SurfaceView) throws -> [Ghostty.SurfaceView] {
        guard let window = window(holding: pane) else { throw UmiError.badRequest("the pane isn't in a drawer") }
        let tab = window.selectedTab
        let tree = window.tree(of: tab)
        let anchor = window.focusedSurface.flatMap { tree.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface
        release(pane, from: window)
        // The tab's focused pane stays focused while the pane arrives (so `strip.make-room` spares it);
        // the docked pane takes focus after.
        if let anchor {
            tab.focusedSurface = anchor
            if tab === window.selectedTab { window.focusedSurface = anchor }
        }
        var newTree: SplitTree<Ghostty.SurfaceView>
        if let anchor, let inserted = try? tree.inserting(view: pane, at: anchor, direction: .right) {
            newTree = SplitTree(root: inserted.root, zoomed: nil)
        } else {
            newTree = tree.umiAppending(pane, atStart: false)
        }
        let bounds = window.surfaceTree.viewBounds()
        if bounds.width > 0, bounds.height > 0,
           let frame = newTree.root?.frames(in: bounds).first(where: { $0.view === pane })?.frame {
            pane.frame = CGRect(origin: .zero, size: frame.size)
            pane.sizeDidChange(frame.size)
        }
        let (_, hid) = UmiHidden.collectingHidden { window.setTree(newTree, for: tab) }
        window.setOccluded([pane], occluded: false)
        let index = (window.tree(of: tab).root?.leaves().firstIndex { $0 === pane } ?? 0) + 1
        UmiEvents.shared.emit("pane.moved", ["pane": pane.umiID,
                                             "from": ["window": window.umiIDString, "drawer": true],
                                             "to": ["tab": tab.idString, "window": window.umiIDString, "index": index],
                                             "tab": tab.idString, "window": window.umiIDString])
        UmiLayout.focusPane(pane, activate: true)
        return hid
    }

    /// `pane hide` of a drawer pane: back, hidden, to the tab it came from, or the current tab when
    /// that tab is gone (design/cli.md, "Drawer").
    static func hide(_ pane: Ghostty.SurfaceView) throws {
        guard let window = window(holding: pane) else { throw UmiError.badRequest("the pane isn't in a drawer") }
        let originID = window.drawer.origins[pane.id]
        var target: (TerminalController, UmiTab) = (window, window.selectedTab)
        if let originID {
            for w in UmiTopology.windows {
                if let tab = w.tabs.first(where: { $0.id == originID }) { target = (w, tab); break }
            }
        }
        release(pane, from: window, refocus: true)
        let (home, tab) = target
        tab.hidden.insert(pane, at: 0)
        home.setOccluded([pane], occluded: true)
        UmiEvents.shared.emit("pane.moved", ["pane": pane.umiID,
                                             "from": ["window": window.umiIDString, "drawer": true],
                                             "to": ["tab": tab.idString, "window": home.umiIDString, "hidden": true],
                                             "tab": tab.idString, "window": home.umiIDString])
        UmiHidden.reportPlaceChange(pane, shown: false, tab: tab, window: home)
    }

    /// A drawer pane went away (its program ended, or it was closed).
    static func remove(_ pane: Ghostty.SurfaceView, from window: TerminalController) {
        guard window.drawer.contains(pane) else { return }
        release(pane, from: window, refocus: true)
        UmiEvents.shared.emit("pane.closed", ["pane": pane.umiID, "window": window.umiIDString, "drawer": true])
    }

    /// `pane close` of a drawer pane: its program ends.
    static func closePane(_ pane: Ghostty.SurfaceView) {
        guard let window = window(holding: pane) else { return }
        remove(pane, from: window)
    }

    /// Take a pane out of the drawer for a move elsewhere (`pane move`): it goes into the current
    /// tab first, at its right end, without making room, quietly; the move then takes it on.
    static func leaveForMove(_ pane: Ghostty.SurfaceView) -> TerminalController? {
        guard let window = window(holding: pane) else { return nil }
        release(pane, from: window)
        let tab = window.selectedTab
        UmiHidden.withoutMakingRoom {
            window.setTree(window.tree(of: tab).umiAppending(pane, atStart: false), for: tab)
        }
        window.setOccluded([pane], occluded: tab !== window.selectedTab)
        return window
    }

    /// A tab's tree changed: a drawer pane that is in a tree now (an undo of an earlier layout
    /// change, say) has left its drawer.
    static func treeDidChange(_ tree: SplitTree<Ghostty.SurfaceView>) {
        guard anyPanes else { return }
        for window in UmiTopology.windows where !window.drawer.panes.isEmpty {
            for pane in window.drawer.panes where tree.contains(pane) { release(pane, from: window) }
        }
    }

    // MARK: Saving and restoring

    static func json(of window: TerminalController, encode: (Ghostty.SurfaceView) -> [String: Any]) -> [String: Any]? {
        let drawer = window.drawer
        guard !drawer.panes.isEmpty else { return nil }
        var json: [String: Any] = ["panes": drawer.panes.map(encode)]
        var origins: [String: String] = [:]
        for pane in drawer.panes { if let tab = drawer.origins[pane.id] { origins[pane.umiID] = tab.uuidString.lowercased() } }
        if !origins.isEmpty { json["origins"] = origins }
        if let current = drawer.current { json["current"] = current.umiID }
        return json
    }

    /// The drawer as saved: its panes come back in it, the drawer closed.
    static func restore(_ panes: [Ghostty.SurfaceView], json: [String: Any], in window: TerminalController) {
        guard !panes.isEmpty else { return }
        let origins = json["origins"] as? [String: String] ?? [:]
        for pane in panes {
            window.drawer.panes.append(pane)
            if let id = origins[pane.umiID].flatMap(UUID.init(uuidString:)) { window.drawer.origins[pane.id] = id }
        }
        window.drawer.current = panes.first { $0.umiID == json["current"] as? String } ?? panes.first
        window.setOccluded(panes, occluded: true)
        recount()
    }

    // MARK: JSON

    static func lsJSON(_ window: TerminalController) -> [String: Any] {
        let drawer = window.drawer
        var json: [String: Any] = [
            "open": drawer.isOpen,
            "window": window.umiIDString,
            "panes": drawer.panes.map { pane -> [String: Any] in
                var out = UmiTopology.paneJSON(pane, focused: drawer.showing === pane && hasFocus(pane, in: window), zoomed: false)
                out["on_show"] = drawer.showing === pane
                return out
            },
        ]
        if let current = drawer.current { json["current"] = current.umiID }
        return json
    }

    // MARK: Control methods

    static let methods: Set<String> = ["drawer.show", "drawer.hide", "drawer.toggle", "drawer.next", "drawer.prev",
                                       "drawer.dock", "drawer.ls", "debug.drawer"]

    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        switch method {
        case "drawer.show", "drawer.toggle":
            let window = try drawerWindow(params, caller: caller)
            let panes = try params.string("pane").map { try UmiTopology.resolvePanes($0, caller: caller) }
            if method == "drawer.show" {
                if let panes { try show(panes, in: window) } else { try open(window) }
            } else {
                try toggle(panes, in: window)
            }
            return lsJSON(window)
        case "drawer.hide":
            let window = try drawerWindow(params, caller: caller)
            close(window)
            return lsJSON(window)
        case "drawer.next", "drawer.prev":
            let window = try drawerWindow(params, caller: caller)
            try cycle(window, by: method == "drawer.next" ? 1 : -1)
            return lsJSON(window)
        case "drawer.dock":
            let pane: Ghostty.SurfaceView
            if let selector = params.string("pane") {
                pane = try UmiTopology.resolvePane(selector, caller: caller)
            } else if let caller = try UmiTopology.callerPane(caller), window(holding: caller) != nil {
                pane = caller
            } else {
                let window = try drawerWindow(params, caller: caller)
                guard let current = window.drawer.showing ?? window.drawer.current else { throw UmiError.notFound("the drawer is empty") }
                pane = current
            }
            let hid = try dock(pane)
            var result = UmiTopology.paneInfoJSON(pane)
            result["pane"] = pane.umiID
            result["hid"] = hid.map(\.umiID)
            return result
        case "drawer.ls":
            return lsJSON(try drawerWindow(params, caller: caller))
        case "debug.drawer":
            // What the window shows of its drawer: the panel and its chips, or the waiting line.
            let window = try drawerWindow(params, caller: caller)
            var out = lsJSON(window)
            let drawer = window.drawer
            out["waiting"] = drawer.waiting.map(\.umiID)
            out["line_label"] = waitingLabel(drawer.waiting) ?? NSNull()
            out["chips"] = drawer.panes.map { ["pane": $0.umiID, "title": UmiHidden.label(of: $0), "on_show": drawer.showing === $0,
                                               "state": UmiIndicator.state(of: $0).rawValue] }
            if let pane = drawer.showing, let content = window.window?.contentView, pane.window === window.window {
                out["frame"] = UmiTopology.frameJSON(pane.convert(pane.bounds, to: content))
                out["first_responder"] = window.window?.firstResponder === pane
            }
            out["focus_returns_to"] = window.selectedTab.effectiveFocusedSurface?.umiID ?? NSNull()
            // Where the window's panes are (points, in the window's content view, origin bottom left),
            // for checks of screenshots.
            if let content = window.window?.contentView {
                out["content"] = ["width": Double(content.bounds.width), "height": Double(content.bounds.height),
                                  "flipped": content.isFlipped]
                let frames = (window.surfaceTree.root?.leaves() ?? []).filter { $0.window === window.window }
                    .map { $0.convert($0.bounds, to: content) }
                if let first = frames.first {
                    out["panes_area"] = UmiTopology.frameJSON(frames.dropFirst().reduce(first) { $0.union($1) })
                }
            }
            return out
        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }

    /// The window a drawer command is about: `--window`, else the caller's own (a drawer pane's too),
    /// else the current one.
    private static func drawerWindow(_ params: UmiParams, caller: UmiCaller) throws -> TerminalController {
        if params.string("window") == nil, let pane = try UmiTopology.callerPane(caller), let window = window(holding: pane) {
            return window
        }
        return try UmiTopology.window(params.string("window"), caller: caller)
    }

    /// The waiting line's label: the first waiting pane's name, and how many more wait.
    static func waitingLabel(_ panes: [Ghostty.SurfaceView]) -> String? {
        guard let first = panes.first else { return nil }
        let more = panes.count > 1 ? " +\(panes.count - 1)" : ""
        return "\(UmiHidden.label(of: first))\(more) · needs you"
    }

    // MARK: Keys and menu items

    /// ⌃⌘M: `drawer toggle @manager` (design/cli.md choice 15).
    static func toggleManager() {
        guard let window = UmiTopology.currentWindow else { NSSound.beep(); return }
        do {
            let panes = try UmiTopology.match("@manager").map(\.pane)
            if panes.isEmpty {
                // Nothing has `role=manager`: an open drawer is put away; else nothing moves.
                if window.drawer.isOpen { close(window) } else { NSSound.beep() }
                return
            }
            try toggle(panes, in: window)
        } catch {
            NSSound.beep()
        }
    }

    /// Window ▸ Drawer ▸ Move Pane to Drawer: the focused pane goes into the drawer, on show.
    static func moveFocusedPane() {
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane else { NSSound.beep(); return }
        do { try show([pane], in: window) } catch { NSSound.beep() }
    }

    static func toggleCurrent() {
        guard let window = UmiTopology.currentWindow else { NSSound.beep(); return }
        do { try toggle(nil, in: window) } catch { NSSound.beep() }
    }

    static func cycleCurrent(_ offset: Int) {
        guard let window = UmiTopology.currentWindow else { NSSound.beep(); return }
        do { try cycle(window, by: offset) } catch { NSSound.beep() }
    }

    static func dockCurrent() {
        guard let window = UmiTopology.currentWindow, let pane = window.drawer.showing ?? window.drawer.current else {
            NSSound.beep(); return
        }
        do { try dock(pane) } catch { NSSound.beep() }
    }

    static var currentHasPanes: Bool { !(UmiTopology.currentWindow?.drawer.panes.isEmpty ?? true) }
    static var currentIsShowing: Bool { UmiTopology.currentWindow?.drawer.showing != nil }

    // MARK: Screenshots

    /// Draw the drawer (or its waiting line) into a window image, over the terminals' own images
    /// (`screenshot`): the panel's chrome comes from the cached image of the views.
    static func drawForScreenshot(_ controller: TerminalController, content: NSView, cached: NSImage) {
        let drawer = controller.drawer
        if let pane = drawer.showing, pane.window === controller.window, !pane.isHiddenOrHasHiddenAncestor {
            let frame = pane.convert(pane.bounds, to: content)
            // The header above the terminal (and its border line).
            let header = content.isFlipped
                ? NSRect(x: frame.minX, y: frame.minY - headerHeight - 1, width: frame.width, height: headerHeight + 1)
                : NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: headerHeight + 1)
            cached.draw(in: header, from: header, operation: .copy, fraction: 1)
            if !UmiFilePanes.shared.isFilePane(pane.id), !UmiWebPanes.shared.isWebPane(pane.id) {
                if let image = pane.terminalImage() { image.draw(in: frame) } else { cached.draw(in: frame, from: frame, operation: .copy, fraction: 1) }
            } else {
                cached.draw(in: frame, from: frame, operation: .copy, fraction: 1)
            }
            UmiIndicator.shared.draw(over: frame, of: pane, flipped: content.isFlipped)
            return
        }
        // The waiting line along the bottom edge of the panes, with its label: from the cached image.
        guard !drawer.waiting.isEmpty else { return }
        let leaves = controller.surfaceTree.root?.leaves() ?? []
        let frames = leaves.filter { $0.window === controller.window }.map { $0.convert($0.bounds, to: content) }
        guard let area = frames.first.map({ frames.dropFirst().reduce($0) { $0.union($1) } }) else { return }
        let band = content.isFlipped
            ? NSRect(x: area.minX, y: area.maxY - 22, width: area.width, height: 22)
            : NSRect(x: area.minX, y: area.minY, width: area.width, height: 22)
        cached.draw(in: band, from: band, operation: .sourceOver, fraction: 1)
    }
}

// MARK: - The drawer on screen

/// The drawer over the window's panes: the panel when open, else the waiting line when a drawer pane
/// needs the user.
struct UmiDrawerOverlay: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var drawer: UmiDrawerModel
    @ObservedObject private var attention = UmiAttention.shared
    @ObservedObject private var indicator = UmiIndicator.shared

    var body: some View {
        let _ = attention.revision
        GeometryReader { geo in
            if drawer.isOpen, !drawer.settling, let pane = drawer.current {
                UmiDrawerPanel(controller: controller, drawer: drawer, pane: pane)
                    .frame(width: geo.size.width, height: (geo.size.height * UmiDrawer.heightShare).rounded())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            } else if !drawer.waiting.isEmpty {
                UmiDrawerWaitingLine(controller: controller, drawer: drawer, color: indicator.color(.needsYou))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }
}

/// The open drawer (prototypes/drawer.html, option B): a header with a chip per pane and what can be
/// done with the one on show, over its terminal.
private struct UmiDrawerPanel: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject var controller: TerminalController
    @ObservedObject var drawer: UmiDrawerModel
    let pane: Ghostty.SurfaceView

    static let background = Color(red: 6 / 255.0, green: 6 / 255.0, blue: 6 / 255.0)

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(white: 0x22 / 255.0)).frame(height: 1)
            HStack(spacing: 2) {
                ForEach(drawer.panes, id: \.id) { member in
                    UmiDrawerChip(pane: member, onShow: member === pane) {
                        UmiCause.during(UmiCause(kind: "mouse")) {
                            if let window = UmiTopology.windows.first(where: { $0 === controller }) {
                                try? UmiDrawer.show([member], in: window)
                            }
                        }
                    }
                }
                Spacer(minLength: 8)
                UmiDrawerButton(title: "Dock", help: "Move it into the tab's layout") {
                    UmiCause.during(UmiCause(kind: "mouse")) { _ = try? UmiDrawer.dock(pane) }
                }
                UmiDrawerButton(title: "Hide", help: "Hide it in the tab it came from") {
                    UmiCause.during(UmiCause(kind: "mouse")) { try? UmiDrawer.hide(pane) }
                }
                UmiDrawerButton(title: "Put away", help: "Close the drawer (⌃⌘M for the manager)") {
                    UmiCause.during(UmiCause(kind: "mouse")) { UmiDrawer.close(controller) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.top, 3)
            .frame(height: UmiDrawer.headerHeight)
            .overlay(alignment: .bottom) { Rectangle().fill(Color(white: 0x16 / 255.0)).frame(height: 1) }
            Ghostty.InspectableSurface(surfaceView: pane, isSplit: false)
                .overlay { UmiFilePaneOverlay(surfaceView: pane, background: ghostty.config.backgroundColor) }
                .overlay { UmiWebPaneOverlay(surfaceView: pane, background: ghostty.config.backgroundColor) }
                .overlay { UmiPaneIndicatorOverlay(pane: pane) }
                .id("\(pane.id)-\(drawer.renderToken)")
        }
        .background(Self.background)
        .shadow(color: .black.opacity(0.6), radius: 18, y: -8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawer")
        .accessibilityValue(UmiHidden.label(of: pane))
    }
}

private struct UmiDrawerChip: View {
    @ObservedObject var pane: Ghostty.SurfaceView
    let onShow: Bool
    let action: () -> Void
    @ObservedObject private var attention = UmiAttention.shared
    @ObservedObject private var indicator = UmiIndicator.shared

    var body: some View {
        let _ = attention.revision
        let state = UmiIndicator.state(of: pane)
        let label = UmiHidden.label(of: pane)
        Button(action: action) {
            HStack(spacing: 6) {
                if let look = indicator.look(state, focused: false, split: false) {
                    UmiIndicatorDot(look: look)
                }
                Text(label).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 180, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .foregroundColor(Color.white.opacity(onShow ? 0.9 : 0.54))
            .background(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5)
                .fill(onShow ? Color(white: 0x11 / 255.0) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(label)
        .accessibilityValue((onShow ? "in the drawer, on show" : "in the drawer") + UmiDrawerChip.stateText(state))
    }

    static func stateText(_ state: UmiIndicator.State) -> String {
        switch state {
        case .working: return ", working"
        case .needsYou: return ", needs you"
        case .finished: return ", finished, not seen yet"
        case .none: return ""
        }
    }
}

private struct UmiDrawerButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundColor(Color.white.opacity(hovering ? 0.8 : 0.4))
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// While the drawer is closed, a pane in it that needs the user shows as a thin line along the
/// window's bottom edge with a short label at its right end; clicking the label shows it.
private struct UmiDrawerWaitingLine: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var drawer: UmiDrawerModel
    let color: NSColor?

    var body: some View {
        let waiting = drawer.waiting
        let amber = Color(nsColor: color ?? NSColor(red: 0xe0 / 255.0, green: 0xb0 / 255.0, blue: 0x4a / 255.0, alpha: 1))
        VStack(alignment: .trailing, spacing: 3) {
            if let label = UmiDrawer.waitingLabel(waiting) {
                Button {
                    UmiCause.during(UmiCause(kind: "mouse")) {
                        if let first = waiting.first { try? UmiDrawer.show([first], in: controller) }
                    }
                } label: {
                    Text(label).font(.system(size: 10.5)).foregroundColor(amber).lineLimit(1)
                }
                .buttonStyle(.plain)
                // Clear of the pane indicator at the bottom-right corner.
                .padding(.trailing, 26)
                .accessibilityLabel("Drawer: \(label)")
            }
            LinearGradient(colors: [amber.opacity(0), amber], startPoint: .leading, endPoint: UnitPoint(x: 0.7, y: 0.5))
                .frame(height: 3)
                .opacity(0.8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

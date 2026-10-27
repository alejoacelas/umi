import AppKit

/// Reopen what was closed (⇧⌘T, `umi reopen`): the last closed window, tab or pane comes
/// back in its old place, for 60 seconds after the close, as in Warp (L-20).
///
/// A stack of its own, separate from undo (which also holds moves, pins and splits, and keeps
/// a close for Ghostty's `undo-timeout` only). An item on the stack holds its panes, so their
/// programs keep running while it can be reopened; when it expires they end, as a closed pane's
/// always did. A pane returns to the same slot at the same size when its tab hasn't changed
/// since; otherwise next to the pane it was beside, with its old share of that row or column.
/// Closing a pane that shows an agent never stops the agent's session (the engine's rule).
@MainActor
final class UmiReopen {
    static let shared = UmiReopen()

    /// How long a closed item can be reopened (Warp's default grace period).
    static let gracePeriod: TimeInterval = 60

    enum Kind: String { case pane, tab, window }

    @MainActor
    final class Entry {
        let kind: Kind
        let closedAt = Date()

        // A closed pane, held (so its program keeps running), and the tab it was in.
        var pane: Ghostty.SurfaceView?
        weak var paneTab: UmiTab?
        /// The tab's tree just before and just after the close (other panes held weakly).
        var before: UmiSnapshot.WeakNode?
        var after: UmiSnapshot.WeakNode?

        // A closed tab, held, and where it was.
        var tab: UmiTab?
        var tabIndex = 0
        weak var window: TerminalController?

        // A closed window's tabs, held, and how it looked.
        var tabs: [UmiTab] = []
        var selected: UmiTab?
        var frame: NSRect?
        var focusedPane: UUID?
        var sidebarWidth: CGFloat?

        init(_ kind: Kind) { self.kind = kind }

        /// The panes this entry holds.
        var heldPanes: [Ghostty.SurfaceView] {
            switch kind {
            case .pane: return pane.map { [$0] } ?? []
            case .tab: return tab?.panes ?? []
            case .window: return tabs.flatMap(\.panes)
            }
        }

        var expiresAt: Date { closedAt.addingTimeInterval(UmiReopen.gracePeriod) }
    }

    private(set) var entries: [Entry] = []
    private var timer: Timer?

    // MARK: Recording closes

    /// A pane is about to leave `tree` (its tab's tree) for good: the user closed it.
    func recordPane(_ pane: Ghostty.SurfaceView, tab: UmiTab, tree: SplitTree<Ghostty.SurfaceView>,
                    in window: TerminalController) {
        guard UmiSnapshot.isAlive(pane), let root = tree.root, let node = root.node(view: pane) else { return }
        let entry = Entry(.pane)
        entry.pane = pane
        entry.paneTab = tab
        entry.window = window
        entry.tabIndex = window.index(of: tab) ?? window.tabs.count
        entry.before = UmiSnapshot.WeakNode(root)
        entry.after = tree.removing(node).root.map(UmiSnapshot.WeakNode.init)
        push(entry)
    }

    /// A tab is about to be closed (not its window's last tab: that closes the window).
    func recordTab(_ tab: UmiTab, index: Int, in window: TerminalController) {
        guard tab.panes.contains(where: UmiSnapshot.isAlive) else { return }
        let entry = Entry(.tab)
        entry.tab = tab
        entry.tabIndex = index
        entry.window = window
        push(entry)
    }

    /// A window is about to close (its tabs' trees are up to date).
    func recordWindow(_ window: TerminalController) {
        let tabs = window.tabs
        guard tabs.contains(where: { $0.panes.contains(where: UmiSnapshot.isAlive) }) else { return }
        let entry = Entry(.window)
        entry.tabs = tabs
        entry.selected = window.selectedTab
        entry.frame = window.window?.frame
        entry.focusedPane = window.focusedSurface?.id
        entry.sidebarWidth = window.sidebarWidth
        push(entry)
    }

    private func push(_ entry: Entry) {
        entries.append(entry)
        prune()
    }

    /// Drop expired entries (their panes end once nothing else holds them) and wake up for
    /// the next one.
    private func prune() {
        let now = Date()
        entries.removeAll { $0.expiresAt <= now }
        timer?.invalidate()
        timer = nil
        guard let next = entries.map(\.expiresAt).min() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(next.timeIntervalSinceNow, 0.05), repeats: false) { _ in
            MainActor.assumeIsolated { UmiReopen.shared.prune() }
        }
    }

    /// Whether a pane is held here (closed, and can still be reopened).
    func holds(_ paneID: UUID) -> Bool {
        entries.contains { $0.heldPanes.contains { $0.id == paneID } }
    }

    // MARK: Reopening

    /// What ⇧⌘T would reopen now, if anything.
    var next: Kind? {
        entries.last { reopenable($0) }?.kind
    }

    private func reopenable(_ entry: Entry) -> Bool {
        guard entry.expiresAt > Date() else { return false }
        switch entry.kind {
        case .pane:
            guard let pane = entry.pane else { return false }
            return UmiSnapshot.isAlive(pane) && UmiTopology.locate(pane) == nil
        case .tab:
            guard let tab = entry.tab else { return false }
            return UmiTopology.locate(tab: tab) == nil && tab.panes.contains(where: UmiSnapshot.isAlive)
        case .window:
            return entry.tabs.contains { UmiTopology.locate(tab: $0) == nil && $0.panes.contains(where: UmiSnapshot.isAlive) }
        }
    }

    /// Reopen the most recently closed item that can still come back.
    @discardableResult
    func reopen() throws -> [String: Any] {
        prune()
        while let entry = entries.popLast() {
            guard reopenable(entry) else { continue }
            if let result = try restore(entry) {
                prune()
                return result
            }
        }
        throw UmiError.notFound("there's nothing to reopen (closed panes, tabs and windows can be reopened for \(Int(Self.gracePeriod)) seconds)")
    }

    /// The stack, most recent first (`reopen --list`).
    func list() -> [[String: Any]] {
        prune()
        return entries.reversed().filter(reopenable).map { entry in
            var json: [String: Any] = [
                "kind": entry.kind.rawValue,
                "closed_at": ISO8601DateFormatter().string(from: entry.closedAt),
                "expires_in": max(0, Int(entry.expiresAt.timeIntervalSinceNow.rounded(.up))),
                "panes": entry.heldPanes.filter(UmiSnapshot.isAlive).map(\.umiID),
            ]
            switch entry.kind {
            case .pane:
                if let tab = entry.paneTab { json["tab"] = tab.idString }
            case .tab:
                if let tab = entry.tab { json["tab"] = tab.idString; json["title"] = tab.title }
            case .window:
                json["tabs"] = entry.tabs.map(\.idString)
            }
            return json
        }
    }

    private func restore(_ entry: Entry) throws -> [String: Any]? {
        switch entry.kind {
        case .pane: return try restorePane(entry)
        case .tab: return try restoreTab(entry)
        case .window: return try restoreWindow(entry)
        }
    }

    /// Same split sizes throughout (structural identity ignores them): a tab resized since the
    /// close keeps its new sizes, and the pane is inserted into it instead.
    private static func sameRatios(_ a: SplitTree<Ghostty.SurfaceView>.Node, _ b: SplitTree<Ghostty.SurfaceView>.Node) -> Bool {
        switch (a, b) {
        case (.leaf, .leaf):
            return true
        case (.split(let x), .split(let y)):
            return abs(x.ratio - y.ratio) < 0.001 && sameRatios(x.left, y.left) && sameRatios(x.right, y.right)
        default:
            return false
        }
    }

    private func restorePane(_ entry: Entry) throws -> [String: Any]? {
        guard let pane = entry.pane else { return nil }
        if let tab = entry.paneTab, let window = UmiTopology.locate(tab: tab) {
            let current = window.tree(of: tab)
            let newTree: SplitTree<Ghostty.SurfaceView>
            if let root = current.root, let after = entry.after?.resolve(), let before = entry.before?.resolve(),
               after.structuralIdentity == root.structuralIdentity, Self.sameRatios(after, root),
               before.node(view: pane) != nil {
                // The tab is as the close left it: the pane goes back in its slot, at its size.
                newTree = SplitTree(root: before, zoomed: nil)
            } else {
                newTree = Self.inserting(pane, into: current, tab: tab, before: entry.before?.resolve())
            }
            window.replaceTree(newTree, for: tab, undoAction: "Reopen Closed Pane")
            UmiLayout.focusPane(pane, activate: true)
            UmiEvents.shared.emit("pane.created", ["pane": pane.umiID, "tab": tab.idString,
                                                    "window": window.umiIDString, "reopened": true])
            return ["kind": "pane", "pane": pane.umiID, "tab": tab.idString, "window": window.umiIDString]
        }
        // Its tab is gone: the pane comes back as a tab of its own where that tab was.
        let tab = UmiTab(tree: .init(view: pane))
        let (window, index) = try placeTab(near: entry.window, index: entry.tabIndex)
        guard let window else {
            return try reopenInNewWindow([tab], selected: tab, frame: nil, focused: pane.id, kind: .pane)
        }
        insert(tab, into: window, at: index, undoAction: "Reopen Closed Pane")
        UmiEvents.shared.emit("pane.created", ["pane": pane.umiID, "tab": tab.idString,
                                                "window": window.umiIDString, "reopened": true])
        return ["kind": "pane", "pane": pane.umiID, "tab": tab.idString, "window": window.umiIDString]
    }

    private func restoreTab(_ entry: Entry) throws -> [String: Any]? {
        guard let tab = entry.tab, Self.dropExitedPanes(tab) else { return nil }
        let (window, index) = try placeTab(near: entry.window, index: entry.tabIndex)
        guard let window else {
            return try reopenInNewWindow([tab], selected: tab, frame: nil, focused: tab.focusedSurface?.id, kind: .tab)
        }
        insert(tab, into: window, at: index, undoAction: "Reopen Closed Tab")
        return ["kind": "tab", "tab": tab.idString, "window": window.umiIDString,
                "pane": tab.effectiveFocusedSurface?.umiID ?? ""]
    }

    private func restoreWindow(_ entry: Entry) throws -> [String: Any]? {
        let tabs = entry.tabs.filter { UmiTopology.locate(tab: $0) == nil && Self.dropExitedPanes($0) }
        guard !tabs.isEmpty else { return nil }
        let selected = entry.selected.flatMap { s in tabs.contains { $0 === s } ? s : nil } ?? tabs[0]
        return try reopenInNewWindow(tabs, selected: selected, frame: entry.frame, focused: entry.focusedPane,
                                     kind: .window, sidebarWidth: entry.sidebarWidth)
    }

    /// The window a reopened tab goes to: its own if still open (at its old index), else the
    /// current one (at the end). Nil: no window is open.
    private func placeTab(near window: TerminalController?, index: Int?) throws -> (TerminalController?, Int?) {
        if let window, UmiTopology.windows.contains(where: { $0 === window }) { return (window, index) }
        return (UmiTopology.currentWindow, nil)
    }

    private func insert(_ tab: UmiTab, into window: TerminalController, at index: Int?, undoAction: String) {
        window.insertTab(tab, at: index)
        UmiLayout.focusTab(tab, in: window)
        UmiEvents.shared.emit("tab.created", ["tab": tab.idString, "window": window.umiIDString, "reopened": true])
        guard let undoManager = window.undoManager else { return }
        undoManager.setActionName(undoAction)
        undoManager.registerUndo(withTarget: window, expiresAfter: window.undoExpiration) { target in
            undoManager.disableUndoRegistration {
                target.closeTabImmediately(tab, registerUndo: false)
            }
        }
    }

    private func reopenInNewWindow(_ tabs: [UmiTab], selected: UmiTab, frame: NSRect?, focused: UUID?,
                                   kind: Kind, sidebarWidth: CGFloat? = nil) throws -> [String: Any] {
        let ghostty = try UmiLayout.requireGhostty()
        if let focused, let pane = selected.panes.first(where: { $0.id == focused }) { selected.focusedSurface = pane }
        let controller = TerminalController.newWindow(ghostty, tabs: tabs, selected: selected, frame: frame,
                                                      focus: true, registerUndo: true)
        if let sidebarWidth { controller.sidebarWidth = sidebarWidth }
        UmiTopology.windowBecameCurrent(controller)
        var json: [String: Any] = ["kind": kind.rawValue, "window": controller.umiIDString, "tab": selected.idString]
        if let pane = selected.effectiveFocusedSurface { json["pane"] = pane.umiID }
        return json
    }

    /// A pane in a new tree next to where it was: beside the pane it was next to (in the same
    /// direction, with its old share of that row or column), else beside the tab's focused pane.
    private static func inserting(_ pane: Ghostty.SurfaceView, into current: SplitTree<Ghostty.SurfaceView>,
                                  tab: UmiTab, before: SplitTree<Ghostty.SurfaceView>.Node?) -> SplitTree<Ghostty.SurfaceView> {
        guard let root = current.root else { return SplitTree(view: pane) }
        if let before, let path = before.path(to: .leaf(view: pane)), !path.isEmpty {
            let parentPath = SplitTree<Ghostty.SurfaceView>.Path(path: Array(path.path.dropLast()))
            if case .split(let parent) = before.node(at: parentPath) {
                let paneIsFirst = path.path.last == .left
                let sibling = paneIsFirst ? parent.right : parent.left
                let neighbors = paneIsFirst ? sibling.leaves() : sibling.leaves().reversed()
                if let anchor = neighbors.first(where: { current.contains($0) }) {
                    let direction: SplitTree<Ghostty.SurfaceView>.NewDirection = parent.direction == .horizontal
                        ? (paneIsFirst ? .left : .right) : (paneIsFirst ? .up : .down)
                    let runPath = before.runRoot(of: parentPath)
                    let share = before.node(at: runPath)?.runMembers(parent.direction)
                        .first { $0.node == .leaf(view: pane) }?.share
                    if var tree = try? current.inserting(view: pane, at: anchor, direction: direction) {
                        if let share, share > 0, share < 1 {
                            tree = tree.settingShare(of: pane, to: share, along: parent.direction)
                        }
                        return SplitTree(root: tree.root, zoomed: nil)
                    }
                }
            }
        }
        let anchor = tab.effectiveFocusedSurface.flatMap { current.contains($0) ? $0 : nil } ?? root.leftmostLeaf()
        let tree = (try? current.inserting(view: pane, at: anchor, direction: .right)) ?? current
        return SplitTree(root: tree.root, zoomed: nil)
    }

    /// Take panes whose programs ended while closed out of a tab's tree. False: none is left.
    private static func dropExitedPanes(_ tab: UmiTab) -> Bool {
        guard let root = tab.tree.root, let alive = UmiSnapshot.WeakNode(root).resolve() else { return false }
        if alive != root { tab.tree = SplitTree(root: alive, zoomed: nil) }
        return true
    }

    // MARK: Menu (File ▸ Reopen Closed …, ⇧⌘T: an Umi shortcut item, `file.reopen`)

    static let anyTitle = "Reopen Closed Pane, Tab or Window"

    /// The menu item's title: what it would reopen.
    var menuTitle: String {
        switch next {
        case .pane: return "Reopen Closed Pane"
        case .tab: return "Reopen Closed Tab"
        case .window: return "Reopen Closed Window"
        case nil: return Self.anyTitle
        }
    }
}

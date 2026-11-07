import AppKit

/// Moving between tabs and panes from the keyboard, the menus and the CLI: next and previous
/// tab in sidebar order, ⌘1–9, back through the tabs visited (L-11), the panes whose agent
/// needs the user (L-12), and moving tabs up and down (L-13).
///
/// Everything here acts on Umi's own record of the current window, so it works whatever
/// has keyboard focus (L-10).
@MainActor
enum UmiNavigation {
    // MARK: Tabs in sidebar order

    /// The next (`delta` 1) or previous (-1) tab of the current window in sidebar order,
    /// wrapping around.
    @discardableResult
    static func selectAdjacentTab(_ delta: Int, in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow, window.tabs.count > 1, let index = window.index(of: window.selectedTab) else { return nil }
        let count = window.tabs.count
        let tab = window.tabs[((index + delta) % count + count) % count]
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    /// ⌘1–8: the Nth tab of the current window (the last one when there are fewer).
    @discardableResult
    static func selectTab(number: Int, in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow, !window.tabs.isEmpty, number >= 1 else { return nil }
        let tab = window.tabs[min(number, window.tabs.count) - 1]
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    /// ⌘9: the last tab of the current window.
    @discardableResult
    static func selectLastTab(in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow, let tab = window.tabs.last else { return nil }
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    // MARK: Back through the tabs visited

    /// ⌘⇧[: the tab visited before this one, in any window. Pressed again, the one before that.
    @discardableResult
    static func tabBack() -> (TerminalController, UmiTab)? {
        guard let (window, tab) = UmiTabHistory.back() else { return nil }
        UmiLayout.focusTab(tab, in: window)
        return (window, tab)
    }

    // MARK: Moving tabs

    /// Whether a tab can move up (-1) or down (1), as Warp's `can_move_tab`: a tab in a group
    /// only within its group; any other tab not past the end of its pin group.
    static func canMoveTab(_ tab: UmiTab, by delta: Int, in window: TerminalController) -> Bool {
        guard let index = window.index(of: tab) else { return false }
        let target = index + delta
        guard window.tabs.indices.contains(target) else { return false }
        let neighbor = window.tabs[target]
        if let group = tab.groupID { return neighbor.groupID == group }
        return neighbor.pinned == tab.pinned
    }

    /// Where a move up or down puts the tab: the next slot, or past the whole of another group
    /// next to it, so it never lands inside that group (Warp's `move_tab`).
    private static func moveTarget(_ tab: UmiTab, by delta: Int, in window: TerminalController) -> Int? {
        guard let index = window.index(of: tab) else { return nil }
        let target = index + delta
        guard window.tabs.indices.contains(target) else { return nil }
        guard let group = window.tabs[target].groupID, group != tab.groupID else { return target }
        let members = window.tabs.indices.filter { window.tabs[$0].groupID == group }
        return (delta < 0 ? members.first : members.last) ?? target
    }

    /// ⌃⇧← / ⌃⇧→ (and the sidebar row menu): move a tab up (-1) or down (1) the sidebar,
    /// within its pin group and its tab group, hopping over other groups whole. Returns false
    /// when it can't move that way.
    @discardableResult
    static func moveTab(_ tab: UmiTab, by delta: Int, in window: TerminalController) -> Bool {
        guard canMoveTab(tab, by: delta, in: window), let target = moveTarget(tab, by: delta, in: window) else { return false }
        UmiLayout.undoable(delta < 0 ? "Move Tab Up" : "Move Tab Down", windows: [window]) {
            window.moveTab(tab, to: target)
        }
        UmiEvents.shared.emit("tab.moved", ["tab": tab.idString, "from_window": window.umiIDString,
                                             "window": window.umiIDString, "index": (window.index(of: tab) ?? target) + 1])
        return true
    }

    // MARK: Panes whose agent needs the user

    /// Where "back" returns to: the pane focused when a run of jumps started.
    private static var jumpOrigin: Weak<Ghostty.SurfaceView>?
    /// Where the last jump went, to tell a run of jumps from a fresh start.
    private static var landing: UUID?

    /// ⌃⌘J: the next pane whose agent needs the user (needs input first, then finished and
    /// unseen; oldest first).
    @discardableResult
    static func jumpToNextNeedingYou() -> Ghostty.SurfaceView? {
        let here = UmiTopology.currentPane
        let targets = UmiAttention.shared.targetsNeedingYou().filter { $0 != here?.id && pane($0) != nil }
        guard let id = targets.first, let view = pane(id) else { return nil }
        if !isAtLanding(here) { jumpOrigin = here.map { Weak($0) } }
        landing = id
        UmiLayout.focusPane(view, activate: true)
        return view
    }

    /// ⌃⌘K: back to where the user was before jumping to panes that need them.
    @discardableResult
    static func jumpBack() -> Ghostty.SurfaceView? {
        guard let origin = jumpOrigin?.value, UmiTopology.locate(origin) != nil else { return nil }
        jumpOrigin = nil
        landing = nil
        UmiLayout.focusPane(origin, activate: true)
        return origin
    }

    static var canJumpBack: Bool {
        guard let origin = jumpOrigin?.value else { return false }
        return UmiTopology.locate(origin) != nil
    }

    private static func isAtLanding(_ here: Ghostty.SurfaceView?) -> Bool {
        guard let here, let landing, jumpOrigin?.value != nil else { return false }
        return here.id == landing
    }

    private static func pane(_ id: UUID) -> Ghostty.SurfaceView? {
        UmiTopology.allSurfaces.first { $0.id == id }
    }
}

// MARK: - Tab history

/// The tabs the user visited, across windows, most recent last, each once. Going back walks
/// down the list without reordering it, so pressing back again goes further back; visiting
/// any tab another way ends the walk.
@MainActor
enum UmiTabHistory {
    private static var entries: [Weak<UmiTab>] = []
    /// While walking back: the entry shown now.
    private static var cursor: Int?
    private static let limit = 200

    /// A tab became the one the user sees (the selected tab of the current window).
    static func visited(_ tab: UmiTab) {
        prune()
        if let cursor, entries[cursor].value === tab { return }
        if let cursor, let walked = entries[cursor].value {
            // Leaving a tab reached by going back: that tab counts as visited.
            entries.remove(at: cursor)
            entries.append(Weak(walked))
        }
        cursor = nil
        if entries.last?.value === tab { return }
        entries.removeAll { $0.value === tab }
        entries.append(Weak(tab))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The tab before the current one, skipping tabs that are closed. Moves the walk there.
    static func back() -> (TerminalController, UmiTab)? {
        prune()
        var index = (cursor ?? entries.count - 1) - 1
        while index >= 0 {
            if let tab = entries[index].value, let window = UmiTopology.locate(tab: tab) {
                cursor = index
                return (window, tab)
            }
            index -= 1
        }
        return nil
    }

    /// Whether going back would find a tab.
    static var canGoBack: Bool {
        prune()
        var index = (cursor ?? entries.count - 1) - 1
        while index >= 0 {
            if let tab = entries[index].value, UmiTopology.locate(tab: tab) != nil { return true }
            index -= 1
        }
        return false
    }

    /// The history, most recent first (for `debug.navigation`).
    static var recentFirst: [UmiTab] {
        prune()
        return entries.reversed().compactMap(\.value)
    }

    private static func prune() {
        var kept: [Weak<UmiTab>] = []
        var newCursor: Int?
        for (index, entry) in entries.enumerated() where entry.value != nil {
            if index == cursor { newCursor = kept.count }
            kept.append(entry)
        }
        entries = kept
        cursor = newCursor
    }
}

// MARK: - Pane focus history

/// Panes in the order the user last focused them, most recent last. Used to return focus to
/// the pane used before after a close (L-18), and to list panes most recent first (L-15).
@MainActor
enum UmiFocusHistory {
    private static var entries: [Weak<Ghostty.SurfaceView>] = []
    private static let limit = 500

    static func focused(_ pane: Ghostty.SurfaceView) {
        entries.removeAll { $0.value == nil || $0.value === pane }
        entries.append(Weak(pane))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        lookedIfVisible(pane)
    }

    /// Panes, most recently focused first.
    static var recentFirst: [Ghostty.SurfaceView] {
        entries.reversed().compactMap(\.value)
    }

    /// The most recently focused of `candidates`.
    static func mostRecent(among candidates: [Ghostty.SurfaceView]) -> Ghostty.SurfaceView? {
        for entry in entries.reversed() {
            if let pane = entry.value, candidates.contains(where: { $0 === pane }) { return pane }
        }
        return nil
    }

    /// The user looked at the pane if it has focus in the key window of the active app: its
    /// `seenAt` is now (UmiAttention).
    static func lookedIfVisible(_ pane: Ghostty.SurfaceView) {
        guard NSApp.isActive, let window = pane.window, window.isKeyWindow,
              let controller = window.windowController as? TerminalController,
              controller.focusedSurface === pane else { return }
        UmiAttention.shared.looked(atPane: pane.id)
    }
}

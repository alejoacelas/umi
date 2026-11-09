import AppKit

/// Moving between tabs and panes from the keyboard, the menus and the CLI: next and previous
/// tab in sidebar order and ⌘1–9 (L-11), and moving tabs up and down (L-13). The panes that need the user are `UmiGo`'s (`go --next jump`, L-12).
///
/// Everything here acts on Umi's own record of the current window, so it works whatever
/// has keyboard focus (L-10).
@MainActor
enum UmiNavigation {
    // MARK: Tabs in sidebar order

    /// The next (`delta` 1) or previous (-1) tab of the current window in sidebar order,
    /// wrapping around. Archived tabs are skipped; from an archived tab, ⇧⌘] goes to the first
    /// tab and ⇧⌘[ to the last.
    @discardableResult
    static func selectAdjacentTab(_ delta: Int, in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow else { return nil }
        let tabs = window.activeTabs
        guard let index = tabs.firstIndex(where: { $0 === window.selectedTab }) else {
            guard let tab = delta > 0 ? tabs.first : tabs.last else { return nil }
            UmiLayout.focusTab(tab, in: window)
            return tab
        }
        guard tabs.count > 1 else { return nil }
        let count = tabs.count
        let tab = tabs[((index + delta) % count + count) % count]
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    /// Whether ⇧⌘[ / ⇧⌘] have somewhere to go in the current window.
    static var canSelectAdjacentTab: Bool {
        guard let window = UmiTopology.currentWindow else { return false }
        let count = window.activeTabs.count
        return window.selectedTab.archived ? count > 0 : count > 1
    }

    /// ⌘1–8: the Nth tab of the current window (the last one when there are fewer), not counting
    /// archived tabs.
    @discardableResult
    static func selectTab(number: Int, in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow, number >= 1 else { return nil }
        let tabs = window.activeTabs
        guard !tabs.isEmpty else { return nil }
        let tab = tabs[min(number, tabs.count) - 1]
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    /// ⌘9: the last tab of the current window out of the archive.
    @discardableResult
    static func selectLastTab(in window: TerminalController? = nil) -> UmiTab? {
        guard let window = window ?? UmiTopology.currentWindow, let tab = window.activeTabs.last else { return nil }
        UmiLayout.focusTab(tab, in: window)
        return tab
    }

    // MARK: Moving tabs

    /// Whether a tab can move up (-1) or down (1), as Warp's `can_move_tab`: a tab in a group
    /// only within its group; any other tab not past the end of its pin group.
    static func canMoveTab(_ tab: UmiTab, by delta: Int, in window: TerminalController,
                           throughArchive: Bool = true) -> Bool {
        // The Archived row is the last place above the first tab: moving the first tab up archives
        // it, and an archived tab moved down comes back (design/archive.md).
        if tab.archived { return throughArchive && delta > 0 }
        if delta < 0, tab === window.activeTabs.first { return throughArchive }
        guard let index = window.index(of: tab) else { return false }
        let target = index + delta
        guard window.tabs.indices.contains(target) else { return false }
        let neighbor = window.tabs[target]
        if neighbor.archived { return false }
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

    /// ⌃⇧↑ / ⌃⇧↓ (and the sidebar row menu): move a tab up (-1) or down (1) the sidebar,
    /// within its pin group and its tab group, hopping over other groups whole. Returns false
    /// when it can't move that way.
    @discardableResult
    static func moveTab(_ tab: UmiTab, by delta: Int, in window: TerminalController) -> Bool {
        guard canMoveTab(tab, by: delta, in: window) else { return false }
        if tab.archived {
            UmiArchive.unarchive(tab, in: window)
            return true
        }
        if delta < 0, tab === window.activeTabs.first {
            UmiArchive.archive(tab, in: window)
            return true
        }
        guard let target = moveTarget(tab, by: delta, in: window) else { return false }
        UmiLayout.undoable(delta < 0 ? "Move Tab Up" : "Move Tab Down", windows: [window]) {
            window.moveTab(tab, to: target)
        }
        UmiEvents.shared.emit("tab.moved", ["tab": tab.idString, "from_window": window.umiIDString,
                                             "window": window.umiIDString, "index": (window.index(of: tab) ?? target) + 1])
        return true
    }
}

// MARK: - Tab history

/// The tabs the user visited, across windows, most recent last, each once (the palette's recent
/// tabs).
@MainActor
enum UmiTabHistory {
    private static var entries: [Weak<UmiTab>] = []
    private static let limit = 200

    /// While above zero, nothing is recorded: a keyboard move's preview steps through tabs the pane
    /// only passes over (UmiPaneMove records the landing).
    static var paused = 0

    /// A tab became the one the user sees (the selected tab of the current window).
    static func visited(_ tab: UmiTab) {
        guard paused == 0 else { return }
        entries.removeAll { $0.value == nil }
        if entries.last?.value === tab { return }
        entries.removeAll { $0.value === tab }
        entries.append(Weak(tab))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    /// The history, most recent first (for the palette and `debug.navigation`).
    static var recentFirst: [UmiTab] {
        entries.reversed().compactMap(\.value)
    }
}

// MARK: - Pane focus history

/// Panes in the order the user last focused them, most recent last. Used to return focus to
/// the pane used before after a close (L-18), and to list panes most recent first (L-15).
@MainActor
enum UmiFocusHistory {
    private static var entries: [Weak<Ghostty.SurfaceView>] = []
    private static let limit = 500

    /// While above zero, nothing is recorded (a keyboard move's preview; see UmiTabHistory.paused).
    static var paused = 0

    static func focused(_ pane: Ghostty.SurfaceView) {
        guard paused == 0 else { return }
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

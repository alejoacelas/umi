import AppKit
import Combine

/// Moving between tabs and panes from the keyboard, the menus and the CLI: next and previous
/// tab in sidebar order, ⌘1–9, back through the tabs visited (L-11), the sessions that need
/// the user (L-12), and moving tabs up and down (L-13).
///
/// Everything here acts on Tern's own record of the current window, so it works whatever
/// has keyboard focus (L-10).
@MainActor
enum TernNavigation {
    // MARK: Tabs in sidebar order

    /// The next (`delta` 1) or previous (-1) tab of the current window in sidebar order,
    /// wrapping around.
    @discardableResult
    static func selectAdjacentTab(_ delta: Int, in window: TerminalController? = nil) -> TernTab? {
        guard let window = window ?? TernTopology.currentWindow, window.tabs.count > 1, let index = window.index(of: window.selectedTab) else { return nil }
        let count = window.tabs.count
        let tab = window.tabs[((index + delta) % count + count) % count]
        TernTabOrder.freeze()
        TernLayout.focusTab(tab, in: window)
        return tab
    }

    /// ⌘1–8: the Nth tab of the current window (the last one when there are fewer).
    @discardableResult
    static func selectTab(number: Int, in window: TerminalController? = nil) -> TernTab? {
        guard let window = window ?? TernTopology.currentWindow, !window.tabs.isEmpty, number >= 1 else { return nil }
        let tab = window.tabs[min(number, window.tabs.count) - 1]
        TernTabOrder.freeze()
        TernLayout.focusTab(tab, in: window)
        return tab
    }

    /// ⌘9: the last tab of the current window.
    @discardableResult
    static func selectLastTab(in window: TerminalController? = nil) -> TernTab? {
        guard let window = window ?? TernTopology.currentWindow, let tab = window.tabs.last else { return nil }
        TernTabOrder.freeze()
        TernLayout.focusTab(tab, in: window)
        return tab
    }

    // MARK: Back through the tabs visited

    /// ⌘⇧[: the tab visited before this one, in any window. Pressed again, the one before that.
    @discardableResult
    static func tabBack() -> (TerminalController, TernTab)? {
        guard let (window, tab) = TernTabHistory.back() else { return nil }
        TernTabOrder.freeze()
        TernLayout.focusTab(tab, in: window)
        return (window, tab)
    }

    // MARK: Moving tabs

    /// Whether a tab can move up (-1) or down (1): not past the end of its pin group.
    static func canMoveTab(_ tab: TernTab, by delta: Int, in window: TerminalController) -> Bool {
        guard let index = window.index(of: tab) else { return false }
        let target = index + delta
        return window.tabs.indices.contains(target) && window.tabs[target].pinned == tab.pinned
    }

    /// ⌃⇧← / ⌃⇧→ (and the sidebar row menu): move a tab up (-1) or down (1) the sidebar,
    /// within its pin group. Returns false at the end of its group.
    @discardableResult
    static func moveTab(_ tab: TernTab, by delta: Int, in window: TerminalController) -> Bool {
        guard canMoveTab(tab, by: delta, in: window), let index = window.index(of: tab) else { return false }
        let target = index + delta
        TernTabOrder.hold {
            TernLayout.undoable(delta < 0 ? "Move Tab Up" : "Move Tab Down", windows: [window]) {
                window.moveTab(tab, to: target)
            }
        }
        TernEvents.shared.emit("tab.moved", ["tab": tab.idString, "from_window": window.ternIDString,
                                             "window": window.ternIDString, "index": target + 1])
        return true
    }

    // MARK: Sessions that need the user

    /// Where "back" returns to: the pane focused when a run of jumps started.
    private static var jumpOrigin: Weak<Ghostty.SurfaceView>?
    /// Where the last jump went, to tell a run of jumps from a fresh start.
    private enum Landing { case pane(UUID), session(String) }
    private static var landing: Landing?

    enum JumpResult { case pane(Ghostty.SurfaceView), session(String) }

    /// ⌃⌘J: the next session that needs the user (needs input first, then finished and
    /// unseen; oldest first). A session no pane shows is shown by the agent engine.
    @discardableResult
    static func jumpToNextNeedingYou() -> JumpResult? {
        let here = TernTopology.currentPane
        let targets = TernAttention.shared.targetsNeedingYou().filter { target in
            if case .pane(let id) = target { return id != here?.id && pane(id) != nil }
            return true
        }
        guard let target = targets.first else { return nil }
        if !isAtLanding(here) { jumpOrigin = here.map { Weak($0) } }
        switch target {
        case .pane(let id):
            guard let view = pane(id) else { return nil }
            landing = .pane(id)
            TernLayout.focusPane(view, activate: true)
            return .pane(view)
        case .session(let session):
            landing = .session(session)
            TernAttention.shared.showSession?(session)
            return .session(session)
        }
    }

    /// ⌃⌘K: back to where the user was before jumping to sessions that need them.
    @discardableResult
    static func jumpBack() -> Ghostty.SurfaceView? {
        guard let origin = jumpOrigin?.value, TernTopology.locate(origin) != nil else { return nil }
        jumpOrigin = nil
        landing = nil
        TernLayout.focusPane(origin, activate: true)
        return origin
    }

    static var canJumpBack: Bool {
        guard let origin = jumpOrigin?.value else { return false }
        return TernTopology.locate(origin) != nil
    }

    private static func isAtLanding(_ here: Ghostty.SurfaceView?) -> Bool {
        guard let here, let landing, jumpOrigin?.value != nil else { return false }
        switch landing {
        case .pane(let id): return here.id == id
        case .session(let session): return TernAttention.shared.agent(forPane: here.id)?.session == session
        }
    }

    private static func pane(_ id: UUID) -> Ghostty.SurfaceView? {
        TernTopology.allSurfaces.first { $0.id == id }
    }
}

// MARK: - Tab history

/// The tabs the user visited, across windows, most recent last, each once. Going back walks
/// down the list without reordering it, so pressing back again goes further back; visiting
/// any tab another way ends the walk.
@MainActor
enum TernTabHistory {
    private static var entries: [Weak<TernTab>] = []
    /// While walking back: the entry shown now.
    private static var cursor: Int?
    private static let limit = 200

    /// A tab became the one the user sees (the selected tab of the current window).
    static func visited(_ tab: TernTab) {
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
    static func back() -> (TerminalController, TernTab)? {
        prune()
        var index = (cursor ?? entries.count - 1) - 1
        while index >= 0 {
            if let tab = entries[index].value, let window = TernTopology.locate(tab: tab) {
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
            if let tab = entries[index].value, TernTopology.locate(tab: tab) != nil { return true }
            index -= 1
        }
        return false
    }

    /// The history, most recent first (for `debug.navigation`).
    static var recentFirst: [TernTab] {
        prune()
        return entries.reversed().compactMap(\.value)
    }

    private static func prune() {
        var kept: [Weak<TernTab>] = []
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
enum TernFocusHistory {
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
    /// agent's quiet mark clears (TernAttention).
    static func lookedIfVisible(_ pane: Ghostty.SurfaceView) {
        guard NSApp.isActive, let window = pane.window, window.isKeyWindow,
              let controller = window.windowController as? TerminalController,
              controller.focusedSurface === pane else { return }
        TernAttention.shared.looked(atPane: pane.id)
    }
}

// MARK: - Sidebar order (S-7)

/// The order of each window's tabs: pinned tabs first, in pin order; then the selected tab;
/// then tabs whose agents stopped or delivered, most recent first; then the others in their
/// existing order. This is the window's real tab order, so `ls`, `#N` and ⌘1–9 follow it.
///
/// It is recomputed when a window's selection changes, when an agent stops, and when a tab
/// is pinned or unpinned. Explicit placements (dragging, `tab move`, Move Tab Up/Down,
/// `tab new --index`) stay where they were put until the next recompute. During a burst of
/// tab-switching keys the order stays as the user saw it, so ⌘⇧] walks down the list instead
/// of bouncing between the two tabs at the top; it settles a moment after the last press.
@MainActor
enum TernTabOrder {
    /// How long the order stays as it is after a tab-switching key.
    static let settleDelay: TimeInterval = 1.2

    private static var frozenUntil = Date.distantPast
    private static var settle: DispatchWorkItem?
    private static var holding = 0
    /// Each tab's last agent stop as of the last recompute, to notice new stops.
    private static var knownStops: [UUID: Date] = [:]
    private static var attentionObserver: AnyCancellable?

    static func start() {
        guard attentionObserver == nil else { return }
        attentionObserver = TernAttention.shared.$revision
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { attentionChanged() } }
    }

    /// Run an explicit placement: the selection it makes doesn't reorder the tabs.
    static func hold<T>(_ body: () throws -> T) rethrows -> T {
        holding += 1
        defer { holding -= 1 }
        return try body()
    }

    /// Keep the order as it is for a moment (a tab-switching key was pressed).
    static func freeze() {
        frozenUntil = Date().addingTimeInterval(settleDelay)
        settle?.cancel()
        let work = DispatchWorkItem { MainActor.assumeIsolated { reorderAll() } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay + 0.05, execute: work)
    }

    static var isFrozen: Bool { Date() < frozenUntil }

    /// A window's selected tab changed.
    static func selectionChanged(in window: TerminalController) {
        guard holding == 0, !isFrozen else { return }
        reorder(window)
    }

    /// A tab was pinned or unpinned.
    static func pinsChanged(in window: TerminalController) {
        guard !isFrozen else { return }
        reorder(window)
    }

    private static func attentionChanged() {
        var changed: [TerminalController] = []
        for window in TernTopology.windows {
            for tab in window.tabs {
                let stop = TernAttention.shared.lastStop(for: tab, in: window)
                if knownStops[tab.id] != stop {
                    if !changed.contains(where: { $0 === window }) { changed.append(window) }
                    knownStops[tab.id] = stop
                }
            }
        }
        guard !isFrozen else { return }
        for window in changed { reorder(window) }
    }

    private static func reorderAll() {
        guard !isFrozen else { return }
        for window in TernTopology.windows { reorder(window) }
    }

    /// The order the rules give for a window's tabs.
    static func ordered(_ window: TerminalController) -> [TernTab] {
        let pinned = window.tabs.filter(\.pinned)
        var others = window.tabs.filter { !$0.pinned }
        var head: [TernTab] = []
        if let selected = others.first(where: { $0 === window.selectedTab }) {
            head = [selected]
            others.removeAll { $0 === selected }
        }
        var stops: [UUID: Date] = [:]
        for tab in window.tabs {
            let stop = TernAttention.shared.lastStop(for: tab, in: window)
            knownStops[tab.id] = stop
            if let stop { stops[tab.id] = stop }
        }
        // A stable sort: tabs that stopped at the same moment keep their order.
        let stopped = others.enumerated()
            .compactMap { item in stops[item.element.id].map { (item.offset, item.element, $0) } }
            .sorted { a, b in a.2 != b.2 ? a.2 > b.2 : a.0 < b.0 }
            .map(\.1)
        let never = others.filter { stops[$0.id] == nil }
        return pinned + head + stopped + never
    }

    static func reorder(_ window: TerminalController) {
        guard !window.isClosed else { return }
        let order = ordered(window)
        guard order.count == window.tabs.count, !zip(order, window.tabs).allSatisfy({ $0 === $1 }) else { return }
        window.reorderTabs(order)
    }
}

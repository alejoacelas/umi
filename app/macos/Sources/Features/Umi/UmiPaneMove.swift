import AppKit
import SwiftUI

/// Moving the focused pane from the keyboard (attention-ui.md, "Moving panes";
/// prototypes/move-literal.html, option A). Hold ⌃⌘: the move starts at the first arrow, so ⌃⌘
/// shortcuts with letters are unaffected. ←/→ move the pane within the tab it is over; ↑/↓ carry
/// it to the tab above or below, the last target being a new tab. Letting go of ⌃⌘ lands it, Esc
/// cancels, and ⌘Z undoes a landed move.
///
/// While the move lasts the window shows the target tab exactly as it would look with the pane
/// landed, the pane `strip.make-room` would hide included: each step makes the move for real,
/// quietly (no events, no undo), after putting the window back as it was. Landing puts it back
/// once more and makes the move through `UmiLayout.move`, the same code, so the result is what
/// was shown, reported once and undoable. The sidebar comes out for the move (even when hidden)
/// and every row lists its tab's panes (`UmiPaneMoveDisplay`).
@MainActor
final class UmiPaneMove {
    enum Arrow { case left, right, up, down }

    /// Where the pane is over: a tab of the window, or a new tab (last in the ↑/↓ order).
    enum Target: Equatable {
        case tab(UmiTab)
        case newTab

        static func == (a: Target, b: Target) -> Bool {
            switch (a, b) {
            case let (.tab(x), .tab(y)): return x === y
            case (.newTab, .newTab): return true
            default: return false
            }
        }
    }

    static private(set) var current: UmiPaneMove?
    /// `debug.key` with `hold`: the next steps count as made with ⌃⌘ held, until `debug.release`.
    static var debugHold = false
    private static var monitor: Any?
    private static var observers: [NSObjectProtocol] = []
    /// Above zero while the move itself changes the window (previews, putting it back, landing), so
    /// tree changes it makes aren't taken for the pane closing.
    private static var busy = 0
    /// The tab and focus histories are paused for this move (UmiTabHistory.paused).
    private var pausedHistories = false

    weak var window: TerminalController?
    let pane: Ghostty.SurfaceView
    let source: UmiTab
    /// The cause of the first step (a key, the menu), for the landing's events.
    private let cause: UmiCause

    // The window as it was when the move began.
    private struct TabState {
        let tab: UmiTab
        let tree: SplitTree<Ghostty.SurfaceView>
        let hidden: [Ghostty.SurfaceView]
        weak var focused: Ghostty.SurfaceView?
    }
    private let start: [TabState]
    private let startSelected: UmiTab
    /// The pane's place among the panes on show of its tab.
    private let startSpot: Int
    private let sidebarWasVisible: Bool
    /// A collapsed tab group opened while the pane is over one of its tabs.
    private weak var openedGroup: UmiTabGroup?

    private(set) var target: Target
    /// Where the pane lands among the target's panes on show (0: before the first).
    private(set) var spot: Int
    /// The panes the landing would hide to make room.
    private(set) var hid: [Ghostty.SurfaceView] = []

    private init(window: TerminalController, pane: Ghostty.SurfaceView, tab: UmiTab, cause: UmiCause) {
        self.window = window
        self.pane = pane
        self.source = tab
        self.cause = cause
        start = window.tabs.map { tab in
            TabState(tab: tab, tree: window.tree(of: tab), hidden: tab.hidden,
                     focused: (tab === window.selectedTab ? window.focusedSurface : nil) ?? tab.focusedSurface)
        }
        startSelected = window.selectedTab
        startSpot = window.tree(of: tab).root?.leaves().firstIndex { $0 === pane } ?? 0
        sidebarWasVisible = window.sidebarVisible
        target = .tab(tab)
        spot = startSpot
    }

    // MARK: Keys

    /// Whether a move can start (or is going on): a focused pane on show in the current window.
    static var canStart: Bool {
        if current != nil { return true }
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane else { return false }
        return window.surfaceTree.contains(pane)
    }

    /// ⌃⌘ with an arrow (or the menu item).
    static func step(_ arrow: Arrow) {
        if let move = current, move.window != nil, UmiSnapshot.isAlive(move.pane) {
            move.advance(arrow)
        } else {
            current?.finish()
            guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane,
                  window.surfaceTree.contains(pane) else { NSSound.beep(); return }
            let move = UmiPaneMove(window: window, pane: pane, tab: window.selectedTab, cause: UmiCause.now)
            current = move
            startMonitoring()
            move.begin()
            move.advance(arrow)
        }
        if !held { current?.land() }
    }

    /// ⌃⌘ are held for this step: a key press with both (not a menu click), or `debug.key` with `hold`.
    private static var held: Bool {
        if debugHold { return true }
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.modifierFlags.contains([.command, .control])
    }

    /// ⌃⌘ let go (or `debug.release`): the move lands.
    static func release() {
        debugHold = false
        current?.land()
    }

    /// Every key press goes through here first (`UmiShortcuts.dispatch`) while a move is going on:
    /// Esc cancels it; the move's own keys go on moving; any other key lands it and goes on.
    static func intercept(_ event: NSEvent) -> Bool {
        guard let move = current else { return false }
        if event.keyCode == 53 {
            move.cancel()
            return true
        }
        if isMoveKey(event) { return false }
        move.land()
        return false
    }

    private static let itemIDs = ["pane.move_left", "pane.move_right", "pane.move_up", "pane.move_down"]

    /// Whether the key press is one of the move's shortcuts in effect.
    private static func isMoveKey(_ event: NSEvent) -> Bool {
        guard let pressed = UmiShortcut(event: event) else { return false }
        return itemIDs.contains { UmiShortcuts.item(id: $0)?.shortcut == pressed }
    }

    /// Letting go of ⌃⌘ lands the move; so does a click. So does Umi going to the background or
    /// another window becoming key (⌃⌘ could be let go where Umi doesn't see it). The pane closing
    /// mid-move cancels it (`treeDidChange`).
    private static func startMonitoring() {
        if observers.isEmpty {
            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { current?.land() }
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { note in
                MainActor.assumeIsolated {
                    guard let move = current, let window = note.object as? NSWindow, window === move.window?.window else { return }
                    move.land()
                }
            })
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let move = current else { return }
                switch event.type {
                case .flagsChanged:
                    if !event.modifierFlags.contains([.command, .control]) {
                        debugHold = false
                        move.land()
                    }
                default:
                    move.land()
                }
            }
            return event
        }
    }

    // MARK: Steps

    /// The ↑/↓ order: the window's tabs in sidebar order, then a new tab (not for a pane that is
    /// alone in its tab: it would only move the tab).
    private var order: [Target] {
        let tabs = start.map { Target.tab($0.tab) }
        let alone = (start.first { $0.tab === source }.map { ($0.tree.root?.leaves().count ?? 0) <= 1 && $0.hidden.isEmpty }) ?? true
        return alone ? tabs : tabs + [.newTab]
    }

    private func begin() {
        guard let window else { return }
        // The preview steps through tabs the pane only passes over: only the landing is recorded.
        UmiTabHistory.paused += 1
        UmiFocusHistory.paused += 1
        pausedHistories = true
        if !sidebarWasVisible { UmiEvents.shared.muted { window.sidebarVisible = true } }
        publish()
    }

    private func advance(_ arrow: Arrow) {
        switch arrow {
        case .left, .right:
            let limit = spots(for: target)
            let next = spot + (arrow == .right ? 1 : -1)
            guard (0...limit).contains(next) else { NSSound.beep(); return }
            spot = next
        case .up, .down:
            let targets = order
            guard targets.count > 1 else { NSSound.beep(); return }
            let index = targets.firstIndex(of: target) ?? 0
            target = targets[(index + (arrow == .down ? 1 : -1) + targets.count) % targets.count]
            // Back over its own tab: where it was; over another: its right end.
            if case .tab(let tab) = target, tab === source { spot = startSpot } else { spot = spots(for: target) }
        }
        preview()
    }

    /// The state a tab had when the move began.
    private func startState(of tab: UmiTab) -> TabState? { start.first { $0.tab === tab } }

    /// The panes of the target on show, as it was, that the pane lands among: without the pane
    /// itself, and without the one the tab would hide to make room.
    private func neighbors(in target: Target) -> (kept: [Ghostty.SurfaceView], hidden: [Ghostty.SurfaceView]) {
        guard case .tab(let tab) = target, let state = startState(of: tab), let window else { return ([], []) }
        let leaves = (state.tree.root?.leaves() ?? []).filter { $0 !== pane }
        guard tab !== source, leaves.count + 1 > tab.visibleLimit else { return (leaves, []) }
        // The same pick the landing makes (`UmiHidden.makeRoom`), on the window as it was.
        guard let victim = UmiHidden.pickToHide(among: leaves, tab: tab, window: window) else { return (leaves, []) }
        return (leaves.filter { $0 !== victim }, [victim])
    }

    /// The last spot in a target: after the last pane it lands among.
    private func spots(for target: Target) -> Int { neighbors(in: target).kept.count }

    /// Where the pane goes, as `UmiLayout.move` takes it; nil when it stays where it was.
    private func destination() -> UmiLayout.PaneDestination? {
        guard let window else { return nil }
        switch target {
        case .newTab:
            return .newTab(window, index: start.count)
        case .tab(let tab):
            if tab === source && spot == startSpot { return nil }
            let kept = neighbors(in: target).kept
            guard !kept.isEmpty else { return nil }
            let at = min(max(spot, 0), kept.count)
            return at == 0 ? .besidePane(kept[0], .left) : .besidePane(kept[at - 1], .right)
        }
    }

    /// Show the target as it would be with the pane landed.
    private func preview() {
        guard let window else { return }
        UmiPaneMove.busy += 1
        defer { UmiPaneMove.busy -= 1 }
        restore()
        openGroup()
        if let destination = destination() {
            let undo = (NSApp.delegate as? AppDelegate)?.undoManager
            undo?.disableUndoRegistration()
            defer { undo?.enableUndoRegistration() }
            let (_, hidden) = UmiEvents.shared.muted {
                UmiHidden.quietly {
                    UmiHidden.collectingHidden { _ = try? UmiLayout.move(pane, to: destination, focus: true) }
                }
            }
            hid = hidden
        } else {
            hid = []
            if window.selectedTab !== source { UmiEvents.shared.muted { window.selectTab(source) } }
        }
        publish()
    }

    /// Put the window back as it was when the move began (the pane focused in its tab). With
    /// `dropping`, the pane closed meanwhile: everything else goes back, without it.
    private func restore(dropping: Bool = false) {
        guard let window else { return }
        UmiPaneMove.busy += 1
        defer { UmiPaneMove.busy -= 1 }
        if dropping {
            restoreWithout(window)
            return
        }
        UmiEvents.shared.muted {
            UmiHidden.quietly {
                UmiHidden.withoutMakingRoom {
                    let known = Set(start.map { ObjectIdentifier($0.tab) })
                    // A new tab made for a preview goes; the pane is put back in its own tab below.
                    for tab in window.tabs where !known.contains(ObjectIdentifier(tab)) {
                        window.detachTab(tab, focusNeighbor: false, keepWindow: true)
                    }
                    for state in start {
                        state.tab.hidden = state.hidden
                        state.tab.tree = state.tree
                        if let focused = state.focused, state.tree.contains(focused) { state.tab.focusedSurface = focused }
                    }
                    source.focusedSurface = pane
                    window.restoreTabs(start.map(\.tab), selected: startSelected, focusedPane: pane)
                    for state in start { window.setOccluded(state.hidden, occluded: true) }
                    window.setOccluded(startSelected.panes, occluded: false)
                }
            }
        }
        if window.window?.isKeyWindow ?? false { Ghostty.moveFocus(to: pane) }
    }

    /// A collapsed tab group opens while the pane is over one of its tabs, and closes again when
    /// it moves on.
    private func openGroup() {
        guard let window else { return }
        var group: UmiTabGroup?
        if case .tab(let tab) = target, let id = tab.groupID {
            group = window.sidebarModel.groups.first { $0.id == id }
        }
        if let opened = openedGroup, opened !== group {
            UmiEvents.shared.muted { UmiTabGroups.setCollapsed(opened, true, in: window) }
            openedGroup = nil
        }
        if let group, group.collapsed {
            UmiEvents.shared.muted { UmiTabGroups.setCollapsed(group, false, in: window) }
            openedGroup = group
        }
    }

    /// The window as it was without the pane, which closed during the move.
    private func restoreWithout(_ window: TerminalController) {
        UmiEvents.shared.muted {
            UmiHidden.quietly {
                UmiHidden.withoutMakingRoom {
                    let known = Set(start.map { ObjectIdentifier($0.tab) })
                    for tab in window.tabs where !known.contains(ObjectIdentifier(tab)) {
                        window.detachTab(tab, focusNeighbor: false, keepWindow: true)
                    }
                    var kept: [UmiTab] = []
                    for state in start {
                        var tree = state.tree
                        if let node = tree.root?.node(view: pane) { tree = tree.removing(node) }
                        var hidden = state.hidden.filter { $0 !== pane }
                        if tree.isEmpty, let first = hidden.first {
                            hidden.removeFirst()
                            tree = SplitTree(view: first)
                        }
                        guard !tree.isEmpty else { continue }
                        state.tab.hidden = hidden
                        state.tab.tree = SplitTree(root: tree.root, zoomed: nil)
                        if let focused = state.focused, focused !== pane, tree.contains(focused) { state.tab.focusedSurface = focused }
                        kept.append(state.tab)
                    }
                    guard !kept.isEmpty else { return }
                    let selected = kept.contains { $0 === startSelected } ? startSelected : kept[0]
                    let focus = selected.effectiveFocusedSurface
                    window.restoreTabs(kept, selected: selected, focusedPane: focus)
                    for tab in kept { window.setOccluded(tab.hidden, occluded: true) }
                    window.setOccluded(selected.panes, occluded: false)
                    if let focus, window.window?.isKeyWindow ?? false { Ghostty.moveFocus(to: focus) }
                }
            }
        }
    }

    /// A tab's tree changed: if the moving pane is in no tab any more (it closed), the move is over
    /// and everything else goes back as it was.
    static func treeDidChange() {
        guard let move = current, busy == 0 else { return }
        DispatchQueue.main.async {
            guard UmiPaneMove.current === move, busy == 0, UmiTopology.locate(move.pane) == nil else { return }
            move.abandon()
        }
    }

    /// The pane closed mid-move: put the window back without it, then end the move.
    func abandon() {
        guard UmiPaneMove.current === self else { return }
        restore(dropping: true)
        finish()
    }

    // MARK: Ending

    /// Land the pane where it is over.
    func land() {
        guard UmiPaneMove.current === self else { return }
        UmiPaneMove.busy += 1
        defer { UmiPaneMove.busy -= 1 }
        let destination = self.destination()
        restore()
        let landedGroup = openedGroup
        if destination != nil, case .tab(let tab) = target, tab.groupID != nil, tab.groupID == landedGroup?.id {
            // Landing in an opened group keeps it open.
            openedGroup = nil
        }
        finish(landing: true)
        guard let destination, UmiSnapshot.isAlive(pane) else { return }
        UmiCause.during(cause) {
            if (try? UmiLayout.move(pane, to: destination, focus: true)) == nil { NSSound.beep() }
        }
    }

    /// Esc: everything as it was.
    func cancel() {
        guard UmiPaneMove.current === self else { return }
        restore()
        finish()
    }

    /// The move is over: the sidebar and any group opened for it go back, and the histories record
    /// again (with `landing`, where the pane landed, after the landing's own move).
    fileprivate func finish(landing: Bool = false) {
        if UmiPaneMove.current === self { UmiPaneMove.current = nil }
        if pausedHistories {
            pausedHistories = false
            let pane = self.pane
            DispatchQueue.main.async {
                UmiTabHistory.paused -= 1
                UmiFocusHistory.paused -= 1
                guard landing, let location = UmiTopology.locate(pane) else { return }
                UmiFocusHistory.focused(pane)
                if UmiTopology.currentWindow === location.window { UmiTabHistory.visited(location.tab) }
            }
        }
        if let window {
            if let group = openedGroup { UmiEvents.shared.muted { UmiTabGroups.setCollapsed(group, true, in: window) } }
            if !sidebarWasVisible { UmiEvents.shared.muted { window.sidebarVisible = false } }
        }
        openedGroup = nil
        UmiPaneMoveDisplay.shared.info = nil
    }

    private func publish() {
        guard let window else { return }
        let targetTab: UmiTab?
        switch target {
        case .tab(let tab): targetTab = tab
        case .newTab: targetTab = window.tabs.first { $0.contains(pane) && $0 !== source }
        }
        UmiPaneMoveDisplay.shared.info = .init(window: window, pane: pane, source: source, target: targetTab,
                                               newTab: target == .newTab, spot: spot, hid: hid,
                                               offersNewTab: order.contains(.newTab))
    }

    // MARK: Checks

    /// `debug.move`: the move going on, if any, and what each row lists.
    static func debugState(in window: TerminalController) -> [String: Any] {
        guard let move = current, move.window === window, let info = UmiPaneMoveDisplay.shared.info else {
            return ["active": false, "sidebar_visible": window.sidebarVisible]
        }
        var out: [String: Any] = [
            "active": true, "pane": move.pane.umiID, "source": move.source.idString,
            "target": info.newTab ? "new" : (info.target?.idString ?? ""),
            "spot": move.spot, "hid": move.hid.map(\.umiID),
            "selected_tab": window.selectedTab.idString, "sidebar_visible": window.sidebarVisible,
            "offers_new_tab": info.offersNewTab,
        ]
        out["rows"] = window.tabs.map { tab -> [String: Any] in
            ["tab": tab.idString, "target": info.target === tab, "source": info.source === tab && info.target !== tab,
             "panes": UmiPaneMoveDisplay.entries(of: tab, in: window, info: info).map(\.json)]
        }
        return out
    }
}

// MARK: - What the sidebar shows during a move

/// The keyboard move going on, for the sidebar's rows (prototypes/move-literal.html, option A).
@MainActor
final class UmiPaneMoveDisplay: ObservableObject {
    static let shared = UmiPaneMoveDisplay()

    struct Info {
        weak var window: TerminalController?
        let pane: Ghostty.SurfaceView
        let source: UmiTab
        /// The tab the pane is over (the new tab made for the preview, when the target is a new tab).
        let target: UmiTab?
        let newTab: Bool
        let spot: Int
        let hid: [Ghostty.SurfaceView]
        let offersNewTab: Bool
    }

    @Published var info: Info?

    func info(for window: TerminalController) -> Info? {
        guard let info, info.window === window else { return nil }
        return info
    }

    /// One pane in a row's list.
    @MainActor
    struct Entry: Identifiable {
        enum Place: String { case shown, moving, hiding, hidden }
        let pane: Ghostty.SurfaceView
        let place: Place
        nonisolated var id: UUID { pane.id }

        var label: String { UmiHidden.label(of: pane) }

        var suffix: String {
            switch place {
            case .shown: return ""
            case .moving: return ""
            case .hiding: return " → hidden"
            case .hidden: return " · hidden"
            }
        }

        var json: [String: Any] {
            ["pane": pane.umiID, "title": label, "place": place.rawValue,
             "indicator": UmiIndicator.state(of: pane).rawValue]
        }
    }

    /// A row's panes during a move: those on show in layout order (the moving one marked), the
    /// ones the landing would hide, then the hidden ones.
    static func entries(of tab: UmiTab, in window: TerminalController, info: Info) -> [Entry] {
        let shown = window.tree(of: tab).root?.leaves() ?? []
        let hiding = info.target === tab ? info.hid : []
        var out = shown.map { Entry(pane: $0, place: $0 === info.pane ? .moving : .shown) }
        out += hiding.map { Entry(pane: $0, place: .hiding) }
        out += tab.hidden.filter { pane in !hiding.contains { $0 === pane } }.map { Entry(pane: $0, place: .hidden) }
        return out
    }
}

/// The pane list under a sidebar row during a keyboard move.
struct UmiMoveRowPanes: View {
    let entries: [UmiPaneMoveDisplay.Entry]
    @ObservedObject private var indicator = UmiIndicator.shared

    static let moving = Color(red: 0x3a / 255.0, green: 0xd1 / 255.0, blue: 0xe0 / 255.0)

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Circle()
                        .fill(dot(entry))
                        .frame(width: 6, height: 6)
                    Text(entry.label + entry.suffix)
                        .font(.system(size: 11))
                        .italic(entry.place == .hidden)
                        .strikethrough(entry.place == .hiding)
                        .foregroundColor(color(entry))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.top, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entries.map { $0.label + $0.suffix + ($0.place == .moving ? " · moving here" : "") }.joined(separator: ", "))
    }

    private func dot(_ entry: UmiPaneMoveDisplay.Entry) -> Color {
        let state = UmiIndicator.state(of: entry.pane)
        if let color = indicator.color(state) { return Color(color) }
        return Color(white: 0x2a / 255.0)
    }

    private func color(_ entry: UmiPaneMoveDisplay.Entry) -> Color {
        switch entry.place {
        case .moving: return Self.moving
        case .shown: return Color(white: 0xb5 / 255.0)
        case .hiding, .hidden: return Color(white: 0x5a / 255.0)
        }
    }
}

/// The "New tab" row at the end of the sidebar during a keyboard move, while the pane isn't over it.
struct UmiMoveNewTabRow: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                Circle().fill(UmiTheme.overlay2)
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundColor(UmiTheme.rowSubtitle)
            }
            .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("New tab").font(.system(size: 12)).foregroundColor(UmiTheme.rowSubtitle)
                Text("just this pane").font(.system(size: 11)).foregroundColor(UmiTheme.rowSubtitle)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New tab")
    }
}

// MARK: - The moving pane in the window

/// The moving pane's marker during a keyboard move (prototypes/move-literal.html, option A): a cyan
/// inset outline and a "moving here" tag at its bottom left. Never takes clicks.
struct UmiPaneMoveMarker: View {
    let pane: Ghostty.SurfaceView
    @ObservedObject private var display = UmiPaneMoveDisplay.shared

    static let cyan = UmiMoveRowPanes.moving
    static let cyanNS = NSColor(red: 0x3a / 255.0, green: 0xd1 / 255.0, blue: 0xe0 / 255.0, alpha: 1)
    /// The tag's place from the pane's bottom-left corner, and its look.
    static let tagInset = CGSize(width: 10, height: 10)
    static let tagText = "moving here"
    static let tagFont = NSFont.systemFont(ofSize: 10.5)

    var body: some View {
        if display.info?.pane === pane {
            ZStack(alignment: .bottomLeading) {
                Rectangle().strokeBorder(Self.cyan, lineWidth: 1)
                Text(Self.tagText)
                    .font(Font(Self.tagFont))
                    .foregroundColor(Self.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 3 / 255.0, green: 0x10 / 255.0, blue: 0x12 / 255.0)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Self.cyan.opacity(0.5), lineWidth: 1))
                    .padding(.leading, Self.tagInset.width)
                    .padding(.bottom, Self.tagInset.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("moving here")
        }
    }

    /// Draw the marker over the moving pane's terminal image (`screenshot`), as the view draws it.
    static func drawForScreenshot(_ controller: TerminalController, content: NSView) {
        guard let info = UmiPaneMoveDisplay.shared.info(for: controller) else { return }
        let pane = info.pane
        guard pane.window === controller.window, !pane.isHiddenOrHasHiddenAncestor,
              controller.surfaceTree.contains(pane) else { return }
        let frame = pane.convert(pane.bounds, to: content)
        cyanNS.setStroke()
        let outline = NSBezierPath(rect: frame.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: tagFont, .foregroundColor: cyanNS]
        let text = NSAttributedString(string: tagText, attributes: attributes)
        let size = text.size()
        let tagSize = CGSize(width: ceil(size.width) + 14, height: ceil(size.height) + 2)
        let x = frame.minX + tagInset.width
        let y = content.isFlipped ? frame.maxY - tagInset.height - tagSize.height : frame.minY + tagInset.height
        let tag = NSRect(origin: CGPoint(x: x, y: y), size: tagSize)
        let shape = NSBezierPath(roundedRect: tag.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor(red: 3 / 255.0, green: 0x10 / 255.0, blue: 0x12 / 255.0, alpha: 1).setFill()
        shape.fill()
        cyanNS.withAlphaComponent(0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        text.draw(at: CGPoint(x: tag.minX + 7, y: tag.minY + 1))
    }
}

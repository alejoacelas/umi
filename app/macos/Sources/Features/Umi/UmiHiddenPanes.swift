import AppKit
import SwiftUI

/// Hidden panes and the three-pane limit (design/attention-ui.md, "Panes per tab" and "Hidden
/// panes"). A hidden pane leaves its tab's split tree but stays in its tab (`UmiTab.hidden`, in
/// strip order) and its program keeps running. A tab shows at most `visibleLimit` panes: whenever
/// panes arrive in a tab already showing that many (a split, a file, a move, a reopen, a hidden
/// pane brought in), the `strip.make-room` slot picks the panes to hide, never one that arrived.
///
/// Every tree change of a tab reaches `treeDidChange` (from `TerminalController`), so the limit
/// holds for every way a pane arrives, Ghostty's own splits and drops included.
@MainActor
enum UmiHidden {
    // MARK: Making room

    /// Nesting depth of `withoutMakingRoom`: while above zero, arrivals hide nothing.
    private static var suspended = 0
    /// Nesting depth of `quietly`: while above zero, hiding and showing emit no events (the steps
    /// of a ⌘[ ⌘] walk, which reports only where it lands).
    private static var quiet = 0
    /// The panes made room for, per `collectingHidden` scope (innermost last).
    private static var collectors: [[Ghostty.SurfaceView]] = []
    /// Where in the hidden list the next pane hidden to make room goes: the place the incoming
    /// pane had, so the two chips swap (attention-ui.md, "The pane strip").
    private static var swapIndex: Int?
    /// A pane on show that the next make-room spares besides the arrivals (the pane a ⌘[ ⌘] walk
    /// began on).
    private static var spared: Ghostty.SurfaceView?

    static func withoutMakingRoom<T>(_ body: () throws -> T) rethrows -> T {
        suspended += 1
        defer { suspended -= 1 }
        return try body()
    }

    static func quietly<T>(_ body: () throws -> T) rethrows -> T {
        quiet += 1
        defer { quiet -= 1 }
        return try body()
    }

    /// Run `body` and return the panes hidden to make room meanwhile (the CLI's `hid`).
    static func collectingHidden<T>(_ body: () throws -> T) rethrows -> (T, [Ghostty.SurfaceView]) {
        collectors.append([])
        defer { collectors.removeLast() }
        let result = try body()
        return (result, collectors.last ?? [])
    }

    /// A tab's tree changed (`TerminalController.setTree`, `surfaceTreeDidChange`). Hidden panes
    /// that are in the new tree are on show again (an undo, a restore); panes that arrived make
    /// room when the tab now shows more than its limit.
    static func treeDidChange(_ tab: UmiTab, in window: TerminalController,
                              from old: SplitTree<Ghostty.SurfaceView>, to new: SplitTree<Ghostty.SurfaceView>) {
        let back = tab.hidden.filter { new.contains($0) }
        if !back.isEmpty {
            tab.hidden.removeAll { pane in back.contains { $0 === pane } }
            for pane in back { placeChanged(pane, shown: true, tab: tab, window: window, byCondition: false) }
        }
        guard suspended == 0 else { return }
        let leaves = new.root?.leaves() ?? []
        guard leaves.count > tab.visibleLimit else { return }
        let arrived = leaves.filter { !old.contains($0) }
        guard !arrived.isEmpty else { return }
        makeRoom(in: tab, window: window, keeping: arrived + (spared.map { [$0] } ?? []))
    }

    /// Hide panes on show, as `strip.make-room` picks them, until the tab shows its limit. Panes
    /// in `keeping` stay. When the slot picks nothing (every pane pinned), the tab shows more.
    static func makeRoom(in tab: UmiTab, window: TerminalController, keeping: [Ghostty.SurfaceView]) {
        var guardCount = 0
        while (window.tree(of: tab).root?.leaves().count ?? 0) > tab.visibleLimit, guardCount < 64 {
            guardCount += 1
            let candidates = (window.tree(of: tab).root?.leaves() ?? []).filter { pane in !keeping.contains { $0 === pane } }
            guard let victim = pickToHide(among: candidates, tab: tab, window: window) else { return }
            let index = swapIndex
            swapIndex = nil
            hideNow(victim, tab: tab, window: window, at: index ?? 0)
            if !collectors.isEmpty { collectors[collectors.count - 1].append(victim) }
        }
    }

    /// The first of `candidates` the `strip.make-room` slot picks (default: not pinned, not the
    /// tab's focused pane, the one looked at longest ago first).
    static func pickToHide(among candidates: [Ghostty.SurfaceView], tab: UmiTab, window: TerminalController) -> Ghostty.SurfaceView? {
        guard !candidates.isEmpty else { return nil }
        let placed = candidates.map { UmiTopology.Placed(pane: $0, tab: tab, window: window) }
        let config = UmiConfig.shared
        if let query = config.slotQuery("strip.make-room"), let picked = try? UmiTopology.match(query, among: placed) {
            return picked.first?.pane
        }
        if config.slot("strip.make-room") == "none" { return nil }
        // A slot that names a list in error: the default.
        if case .success(let query) = config.parse(UmiConfig.slots.first { $0.name == "strip.make-room" }?.defaultValue ?? ""),
           let picked = try? UmiTopology.match(query, among: placed) {
            return picked.first?.pane
        }
        return nil
    }

    // MARK: Hiding and showing

    /// `pane hide`: take the pane out of its tab's layout. Hiding the last pane on show fails
    /// (design/cli.md, choice 13). A hidden pane stays hidden.
    static func hide(_ pane: Ghostty.SurfaceView) throws {
        guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
        if location.tab.isHidden(pane) { return }
        let tree = location.window.tree(of: location.tab)
        guard tree.contains(pane) else { throw UmiError.notFound("the pane isn't in its tab") }
        guard (tree.root?.leaves().count ?? 0) > 1 else {
            throw UmiError.failed("it's the last pane on show in its tab (a tab shows at least one)")
        }
        hideNow(pane, tab: location.tab, window: location.window, at: 0)
    }

    /// Take a pane on show out of the tree into the tab's hidden list at `index`. Keyboard focus
    /// leaves it for the pane on show used most recently.
    private static func hideNow(_ pane: Ghostty.SurfaceView, tab: UmiTab, window: TerminalController, at index: Int) {
        let tree = window.tree(of: tab)
        guard let node = tree.root?.node(view: pane), tree.root != node else { return }
        let focusedHere = tab.focusedSurface === pane || (tab === window.selectedTab && window.focusedSurface === pane)
        let newTree = tree.removing(node)
        tab.hidden.insert(pane, at: min(max(index, 0), tab.hidden.count))
        window.setTree(SplitTree(root: newTree.root, zoomed: newTree.zoomed), for: tab)
        window.setOccluded([pane], occluded: true)
        if focusedHere {
            let rest = newTree.root?.leaves() ?? []
            if let next = UmiFocusHistory.mostRecent(among: rest) ?? rest.first {
                tab.focusedSurface = next
                if tab === window.selectedTab {
                    window.focusedSurface = next
                    if window.window?.isKeyWindow ?? false { UmiLayout.moveFocus(to: next, in: window) }
                }
            }
        }
        placeChanged(pane, shown: false, tab: tab, window: window, byCondition: false)
    }

    /// `pane show`, ⌘], a chip's click: bring a hidden pane into its tab, at the right end (the left
    /// end with `atStart`). The tab makes room if it is at its limit; the pane hidden for it takes
    /// the incoming pane's place in the strip. Returns the panes hidden.
    @discardableResult
    static func show(_ pane: Ghostty.SurfaceView, atStart: Bool = false, focus: Bool,
                     byCondition: Bool = false, sparing: Ghostty.SurfaceView? = nil) throws -> [Ghostty.SurfaceView] {
        guard let location = UmiTopology.locate(pane) else { throw UmiError.notFound("the pane isn't in a window") }
        let tab = location.tab
        let window = location.window
        guard let index = tab.hidden.firstIndex(where: { $0 === pane }) else {
            if focus { UmiLayout.focusPane(pane, activate: true) }
            return []
        }
        conditions[pane.id] = nil
        let tree = window.tree(of: tab)
        tab.hidden.remove(at: index)
        let newTree = tree.umiAppending(pane, atStart: atStart)
        // Start at the size it will have, so its program sees the right columns and rows.
        let bounds = window.surfaceTree.viewBounds()
        if bounds.width > 0, bounds.height > 0,
           let frame = newTree.root?.frames(in: bounds).first(where: { $0.view === pane })?.frame {
            pane.frame = CGRect(origin: .zero, size: frame.size)
            pane.sizeDidChange(frame.size)
        }
        let (_, hid) = collectingHidden {
            swapIndex = index
            spared = sparing
            defer {
                swapIndex = nil
                spared = nil
            }
            window.setTree(newTree, for: tab)
        }
        if !collectors.isEmpty { collectors[collectors.count - 1] += hid }
        window.setOccluded([pane], occluded: tab !== window.selectedTab)
        placeChanged(pane, shown: true, tab: tab, window: window, byCondition: byCondition)
        if focus { UmiLayout.focusPane(pane, activate: true) }
        return hid
    }

    /// A hidden pane came back or left: `changed_at`, the event, the saved layout.
    private static func placeChanged(_ pane: Ghostty.SurfaceView, shown: Bool, tab: UmiTab, window: TerminalController,
                                     byCondition: Bool) {
        guard quiet == 0 else { return }
        UmiAttention.shared.placeChanged(pane.id, shown: shown)
        var data: [String: Any] = ["pane": pane.umiID, "tab": tab.idString, "window": window.umiIDString]
        if byCondition { data["by_condition"] = true }
        UmiEvents.shared.emit(shown ? "pane.shown" : "pane.hidden", data)
        if shown { conditions[pane.id] = nil }
        UmiState.shared.layoutDidChange()
    }

    /// Report a net change of place after quiet steps (a ⌘[ ⌘] walk that landed).
    static func reportPlaceChange(_ pane: Ghostty.SurfaceView, shown: Bool, tab: UmiTab, window: TerminalController) {
        placeChanged(pane, shown: shown, tab: tab, window: window, byCondition: false)
    }

    /// A tab is about to be left with no pane on show while it has hidden ones: the one used most
    /// recently comes in instead (a tab always shows one). Returns the tree to use.
    static func refill(_ tree: SplitTree<Ghostty.SurfaceView>, tab: UmiTab, window: TerminalController) -> SplitTree<Ghostty.SurfaceView> {
        guard tree.isEmpty, !tab.hidden.isEmpty else { return tree }
        let pane = UmiFocusHistory.mostRecent(among: tab.hidden) ?? tab.hidden[0]
        tab.hidden.removeAll { $0 === pane }
        tab.focusedSurface = pane
        conditions[pane.id] = nil
        window.setOccluded([pane], occluded: tab !== window.selectedTab)
        // Reported only when it isn't a quiet step (a keyboard move's preview).
        if quiet == 0 {
            DispatchQueue.main.async { placeChanged(pane, shown: true, tab: tab, window: window, byCondition: false) }
        }
        return SplitTree(view: pane)
    }

    /// A hidden pane went away (its program ended, or it was closed).
    static func remove(_ pane: Ghostty.SurfaceView, from tab: UmiTab, in window: TerminalController) {
        guard tab.isHidden(pane) else { return }
        tab.hidden.removeAll { $0 === pane }
        conditions[pane.id] = nil
        UmiEvents.shared.emit("pane.closed", ["pane": pane.umiID, "tab": tab.idString, "window": window.umiIDString])
        UmiState.shared.layoutDidChange()
    }

    /// Take a hidden pane out of its tab without closing it (it is moving elsewhere).
    static func detach(_ pane: Ghostty.SurfaceView, from tab: UmiTab) {
        tab.hidden.removeAll { $0 === pane }
        conditions[pane.id] = nil
    }

    // MARK: Conditions (`pane hide --until`)

    struct Condition {
        /// A query about the pane itself.
        var query: String?
        /// A moment (from a duration).
        var at: Date?

        var json: [String: Any] {
            var out: [String: Any] = [:]
            if let query { out["query"] = query }
            if let at { out["at"] = UmiTime.iso(at) }
            return out
        }
    }

    /// Each hidden pane's pending conditions; the first to hold shows it. Showing a pane by any
    /// means clears them.
    private(set) static var conditions: [UUID: [Condition]] = [:]
    private static var listener: UUID?
    private static var timer: Timer?

    static func setConditions(_ list: [Condition], for pane: Ghostty.SurfaceView) {
        conditions[pane.id] = list.isEmpty ? nil : list
        startWatching()
        for condition in list {
            if let at = condition.at {
                let delay = max(at.timeIntervalSinceNow, 0) + 0.05
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { checkConditions() }
            }
        }
        UmiState.shared.layoutDidChange(persistOnly: true)
        checkConditions(only: pane.id)
    }

    static func restoreConditions(_ json: Any?, for pane: Ghostty.SurfaceView) {
        guard let list = json as? [[String: Any]], !list.isEmpty else { return }
        let parsed = list.map { item in
            Condition(query: item["query"] as? String, at: (item["at"] as? String).flatMap(UmiTime.parseISO))
        }
        DispatchQueue.main.async { setConditions(parsed, for: pane) }
    }

    /// Checked whenever a pane's attributes change and once a minute (design/cli.md, "Hidden panes").
    private static func startWatching() {
        if listener == nil {
            listener = UmiEvents.shared.addListener { name, data in
                guard name == "pane.changed", !conditions.isEmpty else { return }
                let id = (data["pane"] as? String).flatMap(UUID.init(uuidString:))
                DispatchQueue.main.async { checkConditions(only: id) }
            }
        }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
                MainActor.assumeIsolated { checkConditions() }
            }
        }
    }

    static func checkConditions(only id: UUID? = nil) {
        guard !conditions.isEmpty else { return }
        let now = Date()
        for (paneID, list) in conditions where id == nil || paneID == id {
            guard let pane = UmiTopology.allSurfaces.first(where: { $0.id == paneID }),
                  let location = UmiTopology.locate(pane) else { continue }
            guard location.tab.isHidden(pane) else {
                conditions[paneID] = nil
                continue
            }
            let holds = list.contains { condition in
                if let at = condition.at, at <= now { return true }
                if let text = condition.query, let query = try? UmiTopology.parseQuery(text) {
                    let placed = [UmiTopology.Placed(pane: pane, tab: location.tab, window: location.window)]
                    return !((try? UmiTopology.match(query, among: placed)) ?? []).isEmpty
                }
                return false
            }
            guard holds else { continue }
            conditions[paneID] = nil
            // Coming back never moves keyboard focus.
            UmiCause.during(UmiCause(kind: "config")) {
                _ = try? show(pane, focus: false, byCondition: true)
            }
        }
    }

    // MARK: The strip

    /// Every pane of a tab in strip order: those on show in layout order, then the hidden ones.
    static func strip(of tab: UmiTab, in window: TerminalController) -> [Ghostty.SurfaceView] {
        (window.tree(of: tab).root?.leaves() ?? []) + tab.hidden
    }

    /// The name a pane goes by on its chip.
    static func label(of pane: Ghostty.SurfaceView) -> String {
        if let doc = UmiFilePanes.shared.document(of: pane) { return doc.name }
        if let page = UmiWebPanes.shared.page(of: pane) { return page.displayTitle }
        if let name = UmiState.shared.paneName(pane.id), !name.isEmpty { return name }
        if let title = UmiAttention.shared.agent(forPane: pane.id)?.title, !title.isEmpty { return title }
        if !pane.title.isEmpty, pane.title != "👻" { return pane.title }
        let folder = UmiTopology.cwd(of: pane)
        return folder.isEmpty ? "Terminal" : UmiPaneContext.folderName(folder)
    }
}

extension SplitTree {
    /// The tree with `view` added at the right end of the tab (the left end with `atStart`), as a
    /// member of the top row with an equal share (Umi: hidden panes coming in).
    func umiAppending(_ view: ViewType, atStart: Bool) -> Self {
        guard let root else { return SplitTree(view: view) }
        let leaf = Node.leaf(view: view)
        let split = Node.split(.init(direction: .horizontal, ratio: 0.5,
                                     left: atStart ? leaf : root, right: atStart ? root : leaf))
        let joined = SplitTree(root: split, zoomed: nil)
        return joined.equalizingRun(containing: split)
    }
}

// MARK: - ⌘[ and ⌘]

/// ⌘[ and ⌘] walk every pane of the tab: those on show, then the hidden ones (attention-ui.md,
/// "The pane strip"). Stepping onto a hidden pane brings it in (at the right end with ⌘], the left
/// with ⌘[), hiding the pane `strip.make-room` picks; stepping on puts the layout back first.
/// Releasing ⌘ lands the walk where it is: on a hidden pane, it stays; on a pane that was on show,
/// the layout is as it was. A step not made with ⌘ held (the menu) lands at once.
@MainActor
final class UmiPaneWalk {
    static private(set) var current: UmiPaneWalk?
    /// `debug.key` with `hold`: the next steps count as made with ⌘ held, until `debug.release`.
    static var debugHold = false
    private static var monitor: Any?

    weak var window: TerminalController?
    weak var tab: UmiTab?
    private let order: [Weak<Ghostty.SurfaceView>]
    private let startTree: SplitTree<Ghostty.SurfaceView>
    private let startHidden: [Ghostty.SurfaceView]
    private weak var startFocus: Ghostty.SurfaceView?
    private var index: Int
    /// The hidden pane brought in for the current step, if any.
    private weak var brought: Ghostty.SurfaceView?
    /// The tree the walk last left, to notice changes made around it.
    private var expected: SplitTree<Ghostty.SurfaceView>

    private init(window: TerminalController, tab: UmiTab, from pane: Ghostty.SurfaceView) {
        self.window = window
        self.tab = tab
        let tree = window.tree(of: tab)
        let strip = UmiHidden.strip(of: tab, in: window)
        order = strip.map { Weak($0) }
        startTree = tree
        startHidden = tab.hidden
        startFocus = pane
        index = strip.firstIndex { $0 === pane } ?? 0
        expected = tree
    }

    /// ⌘] (`offset` 1) or ⌘[ (-1).
    static func step(_ offset: Int) {
        guard let window = UmiTopology.currentWindow, let pane = UmiTopology.currentPane else { return }
        let tab = window.selectedTab
        startMonitoring()
        if let walk = current, walk.window === window, walk.tab === tab, window.tree(of: tab).root == walk.expected.root,
           tab.contains(pane) {
            walk.advance(offset)
        } else {
            current?.land()
            let walk = UmiPaneWalk(window: window, tab: tab, from: pane)
            current = walk
            walk.advance(offset)
        }
        if !held { current?.land() }
    }

    /// ⌘ is held for this step: a key press with ⌘ (not a menu click), or `debug.key` with `hold`.
    private static var held: Bool {
        if debugHold { return true }
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.modifierFlags.contains(.command)
    }

    /// ⌘ was released (or `debug.release`): the walk lands where it is.
    static func release() {
        debugHold = false
        current?.land()
    }

    private func advance(_ offset: Int) {
        guard let window, let tab, !order.isEmpty else { return }
        // Skip panes that went away meanwhile.
        var target: Ghostty.SurfaceView?
        for _ in 0..<order.count {
            index = (index + offset + order.count) % order.count
            if let pane = order[index].value, tab.contains(pane) {
                target = pane
                break
            }
        }
        guard let target else { return }
        let wasShown = startTree.contains(target)
        UmiHidden.quietly {
            // Put the layout back as it was before showing the next one.
            if brought != nil {
                UmiHidden.withoutMakingRoom {
                    tab.hidden = startHidden.filter { tab.isHidden($0) || window.tree(of: tab).contains($0) }
                    window.setTree(startTree, for: tab)
                }
                window.setOccluded(tab.hidden, occluded: true)
                window.setOccluded(startTree.root?.leaves() ?? [], occluded: tab !== window.selectedTab)
                brought = nil
            }
            if !wasShown {
                // The pane focused when the walk began is never the one hidden for it.
                _ = try? UmiHidden.show(target, atStart: offset < 0, focus: false,
                                        sparing: startFocus.flatMap { startTree.contains($0) ? $0 : nil })
                brought = target
            }
        }
        UmiLayout.focusPane(target, activate: false)
        expected = window.tree(of: tab)
    }

    /// End the walk where it is, reporting what changed place.
    func land() {
        guard UmiPaneWalk.current === self else { return }
        UmiPaneWalk.current = nil
        guard let window, let tab else { return }
        let before = Set(startHidden.map(ObjectIdentifier.init))
        let after = Set(tab.hidden.map(ObjectIdentifier.init))
        for pane in startHidden where !after.contains(ObjectIdentifier(pane)) && tab.contains(pane) {
            UmiHidden.reportPlaceChange(pane, shown: true, tab: tab, window: window)
        }
        for pane in tab.hidden where !before.contains(ObjectIdentifier(pane)) {
            UmiHidden.reportPlaceChange(pane, shown: false, tab: tab, window: window)
        }
    }

    /// Whether the key press is one of Previous Pane / Next Pane's shortcuts in effect.
    private static func isWalkKey(_ event: NSEvent) -> Bool {
        guard let pressed = UmiShortcut(event: event) else { return false }
        return ["pane.stack_previous", "pane.stack_next"].contains { UmiShortcuts.item(id: $0)?.shortcut == pressed }
    }

    /// Releasing ⌘ lands the walk; so does any other key press or a click.
    private static func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { event in
            MainActor.assumeIsolated {
                guard let walk = current else { return }
                switch event.type {
                case .flagsChanged:
                    if !event.modifierFlags.contains(.command) { debugHold = false; walk.land() }
                case .keyDown:
                    // The walk's own keys (⌘[ and ⌘], or what the user bound them to) go on walking.
                    if !isWalkKey(event) { walk.land() }
                default:
                    walk.land()
                }
            }
            return event
        }
    }
}

// MARK: - The pane strip

/// The pane strip in the window's title bar (attention-ui.md, "The pane strip";
/// prototypes/pane-strip.html, option C): a chip for every pane of the tab, those on show in layout
/// order, then the hidden ones, dim. A chip's click shows or focuses its pane; a chip is its pane's
/// drag handle.
struct UmiPaneStrip: View {
    @ObservedObject var controller: TerminalController
    @ObservedObject var tab: UmiTab
    /// Room for the window's buttons when the sidebar is hidden.
    let leading: CGFloat
    @ObservedObject private var files = UmiFilePanes.shared
    @ObservedObject private var attention = UmiAttention.shared

    var body: some View {
        let tree = controller.tree(of: tab)
        let shown = tree.root?.leaves() ?? []
        let focused = (tab === controller.selectedTab ? controller.focusedSurface : nil).flatMap { tree.contains($0) ? $0 : nil }
            ?? tab.effectiveFocusedSurface
        HStack(spacing: 2) {
            ForEach(shown, id: \.id) { pane in
                UmiStripChip(pane: pane, onShow: true, focused: pane === focused)
            }
            if !shown.isEmpty, !tab.hidden.isEmpty {
                // The prototype's separator between the panes on show and the hidden ones.
                Rectangle()
                    .fill(Color(red: 0x2a / 255.0, green: 0x2a / 255.0, blue: 0x2a / 255.0))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 4)
                    .accessibilityHidden(true)
            }
            ForEach(tab.hidden, id: \.id) { pane in
                UmiStripChip(pane: pane, onShow: false, focused: false)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, leading)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane strip")
    }
}

private struct UmiStripChip: View {
    @ObservedObject var pane: Ghostty.SurfaceView
    let onShow: Bool
    let focused: Bool
    @ObservedObject private var files = UmiFilePanes.shared
    @ObservedObject private var web = UmiWebPanes.shared
    @ObservedObject private var attention = UmiAttention.shared
    @ObservedObject private var indicator = UmiIndicator.shared
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        let _ = attention.revision
        let doc = files.document(of: pane)
        let label = UmiHidden.label(of: pane)
        let state = UmiIndicator.state(of: pane)
        HStack(spacing: 5) {
            // The pane indicator, as on the pane (the focused chip is filled, so no grey mark here).
            if let look = indicator.look(state, focused: focused, split: false) {
                UmiIndicatorDot(look: look)
            }
            // A file's type icon in its colors and its unsaved dot, as Warp's file tabs show them.
            if let doc {
                UmiFileIcon(url: doc.url)
                UmiStripDirtyDot(doc: doc)
            } else {
                Image(systemName: web.isWebPane(pane.id) ? "globe" : "terminal")
                    .font(.system(size: 10))
            }
            Text(label)
                .font(UmiTheme.uiFont)
                .italic(!onShow)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: UmiStripChip.textWidth(label))
        }
        .foregroundColor(Color.white.opacity(focused ? 0.95 : (onShow ? 0.80 : 0.34)))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 6).fill(focused ? UmiTheme.selectedFill : (hovering ? UmiTheme.hoverFill : .clear)))
        // The chip is its pane's drag handle; a click without a drag shows or focuses the pane.
        .overlay {
            Ghostty.SurfaceDragSource(surfaceView: pane, isDragging: $dragging, isHovering: $hovering,
                                      onClick: { UmiStripChip.click(pane) })
        }
        .help(onShow ? label : "\(label) (hidden: click to bring it in)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .modifier(UmiStripChipValue(doc: doc, place: (onShow ? (focused ? "on show, focused" : "on show") : "hidden")
                                        + UmiStripChip.stateText(state)))
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(focused ? .isSelected : [])
        .accessibilityAction { UmiStripChip.click(pane) }
    }

    /// The pane indicator's state in a chip's accessibility value.
    static func stateText(_ state: UmiIndicator.State) -> String {
        switch state {
        case .working: return ", working"
        case .needsYou: return ", needs you"
        case .finished: return ", finished, not seen yet"
        case .none: return ""
        }
    }

    /// The name's width: as wide as it reads, so a chip is at most 300 points wide (E-24).
    static func textWidth(_ label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let width = (label as NSString).size(withAttributes: [.font: font]).width + 4
        // Room for the padding, the icon and the pane indicator's mark.
        return min(ceil(width), 300 - 16 - 15 - 13 - 14)
    }

    @MainActor
    static func click(_ pane: Ghostty.SurfaceView) {
        UmiCause.during(UmiCause(kind: "mouse")) {
            if let location = UmiTopology.locate(pane), location.tab.isHidden(pane) {
                _ = try? UmiHidden.show(pane, focus: true)
            } else {
                UmiLayout.focusPane(pane, activate: true)
            }
        }
    }
}

/// A chip's accessibility value: where its pane is ("on show", "on show, focused", "hidden"), and
/// ", unsaved changes" while a file chip's dot shows.
private struct UmiStripChipValue: ViewModifier {
    let doc: UmiDocument?
    let place: String

    func body(content: Content) -> some View {
        if let doc { content.modifier(Observed(doc: doc, place: place)) } else { content.accessibilityValue(place) }
    }

    private struct Observed: ViewModifier {
        @ObservedObject var doc: UmiDocument
        let place: String
        func body(content: Content) -> some View {
            content.accessibilityValue(doc.isDirty ? place + ", unsaved changes" : place)
        }
    }
}

/// A file chip's unsaved-changes dot: 8 points, as Warp's tabs.
private struct UmiStripDirtyDot: View {
    @ObservedObject var doc: UmiDocument

    var body: some View {
        if doc.isDirty {
            Circle().fill(UmiTheme.textSecondary).frame(width: 8, height: 8)
                .padding(.trailing, -1)
                .accessibilityLabel("Unsaved changes")
        }
    }
}

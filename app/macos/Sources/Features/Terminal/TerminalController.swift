import Foundation
import Cocoa
import SwiftUI
import Combine
import GhosttyKit

/// An Umi window: a sidebar of tabs, each tab a split tree of terminal panes, and an
/// editor panel per tab.
///
/// Umi keeps its own list of tabs per window instead of AppKit's native window tabs. The
/// window shows the selected tab's split tree (`surfaceTree`); the other tabs' panes keep
/// running off screen. Owning the model is what lets creating and moving things leave the
/// user's selection and focus untouched at every moment (L-8), keep pinned tabs grouped
/// (L-2), and move tabs between windows without AppKit merging or reordering them (M-2, M-6).
class TerminalController: BaseTerminalController {
    override var windowNibName: NSNib.Name? { "TerminalUmi" }

    /// The window's id for the CLI.
    let umiID = UUID()
    var umiIDString: String { umiID.uuidString.lowercased() }

    /// When the window was created, for stable window numbering.
    let createdAt = Date()

    /// The window's tabs, pinned ones first (in pin order).
    @Published private(set) var tabs: [UmiTab] = []

    private var selectedTabStorage: UmiTab?

    /// The tab whose panes the window shows.
    var selectedTab: UmiTab { selectedTabStorage! }

    /// True while the visible tree is being swapped for another tab's.
    private var switchingTabs = false

    /// The window was asked to appear without taking focus (L-8).
    var presentsWithoutFocus = false

    /// A name given at creation (`window new --name`), usable as a selector.
    var windowName: String?

    /// The size of the area the selected tab's panes share (laid out by SwiftUI).
    var terminalAreaSize: CGSize = .zero

    /// This window's sidebar width (S-8): dragged at the sidebar's edge, saved with the layout.
    /// A new window starts at the width last chosen in any window (`UmiState.sidebarWidth`).
    @Published var sidebarWidth: CGFloat = UmiState.shared.sidebarWidth {
        didSet {
            let clamped = UmiTheme.clampSidebarWidth(sidebarWidth)
            if clamped != sidebarWidth { sidebarWidth = clamped; return }
            guard sidebarWidth != oldValue else { return }
            UmiState.shared.layoutDidChange(persistOnly: true)
            UmiEvents.shared.emit("sidebar.changed", ["visible": UmiState.shared.sidebarVisible,
                                                        "mode": UmiState.shared.sidebarMode.rawValue,
                                                        "width": Double(sidebarWidth), "window": umiIDString])
        }
    }

    /// The window was closed (AppKit may keep the object around for a moment).
    private(set) var isClosed = false

    /// A frame chosen for this window (restored or undone) that showing it must not override.
    private var explicitFrame: NSRect?

    /// The initial window presentation is deferred by one runloop turn in a few places so
    /// AppKit can settle window state first. Close actions must cancel it to avoid
    /// re-showing a window that was already closed.
    private var pendingInitialPresentation: DispatchWorkItem?

    /// The configuration derived from the Ghostty config so we don't need to rely on references.
    private(set) var derivedConfig: DerivedConfig

    /// The notification cancellable for focused surface property changes.
    private var surfaceAppearanceCancellables: Set<AnyCancellable> = []

    /// Umi's palette over this window: commands, panes and files (L-14, L-15, L-16).
    let palette = UmiPaletteModel()

    init(_ ghostty: Ghostty.App,
         withBaseConfig base: Ghostty.SurfaceConfiguration? = nil,
         withSurfaceTree tree: SplitTree<Ghostty.SurfaceView>? = nil,
         parent: NSWindow? = nil
    ) {
        self.derivedConfig = DerivedConfig(ghostty.config)
        super.init(ghostty, baseConfig: base, surfaceTree: tree)
        let tab = UmiTab(tree: surfaceTree)
        tabs = [tab]
        selectedTabStorage = tab
        commonInit()
    }

    /// A window made of existing tabs (a tab moved to a new window, undo, restoration).
    init(_ ghostty: Ghostty.App, tabs: [UmiTab], selected: UmiTab? = nil) {
        precondition(!tabs.isEmpty, "a window needs at least one tab")
        self.derivedConfig = DerivedConfig(ghostty.config)
        let selected = selected.flatMap { s in tabs.contains { $0 === s } ? s : nil } ?? tabs[0]
        super.init(ghostty, baseConfig: nil, surfaceTree: selected.tree)
        self.tabs = Self.ordered(tabs)
        selectedTabStorage = selected
        focusedSurface = selected.effectiveFocusedSurface
        commonInit()
    }

    private func commonInit() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(onToggleFullscreen),
                           name: Ghostty.Notification.ghosttyToggleFullscreen, object: nil)
        center.addObserver(self, selector: #selector(onMoveTab), name: .ghosttyMoveTab, object: nil)
        center.addObserver(self, selector: #selector(onGotoTab),
                           name: Ghostty.Notification.ghosttyGotoTab, object: nil)
        center.addObserver(self, selector: #selector(onCloseTab), name: .ghosttyCloseTab, object: nil)
        center.addObserver(self, selector: #selector(onCloseOtherTabs), name: .ghosttyCloseOtherTabs, object: nil)
        center.addObserver(self, selector: #selector(onCloseTabsOnTheRight),
                           name: .ghosttyCloseTabsOnTheRight, object: nil)
        center.addObserver(self, selector: #selector(onResetWindowSize), name: .ghosttyResetWindowSize, object: nil)
        center.addObserver(self, selector: #selector(ghosttyConfigDidChange(_:)),
                           name: .ghosttyConfigDidChange, object: nil)
        center.addObserver(self, selector: #selector(onCloseWindow), name: .ghosttyCloseWindow, object: nil)
        center.addObserver(self, selector: #selector(onCloseHiddenSurface(_:)),
                           name: Ghostty.Notification.ghosttyCloseSurface, object: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported for this view")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func cancelPendingInitialPresentation() {
        pendingInitialPresentation?.cancel()
        pendingInitialPresentation = nil
    }

    private func scheduleInitialPresentation(_ block: @escaping () -> Void) {
        cancelPendingInitialPresentation()

        var scheduledWorkItem: DispatchWorkItem?
        scheduledWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { self.pendingInitialPresentation = nil }
            guard pendingInitialPresentation?.isCancelled == false else { return }
            block()
        }

        let workItem = scheduledWorkItem!
        pendingInitialPresentation = workItem
        DispatchQueue.main.async(execute: workItem)
    }

    // MARK: Tabs

    /// Pinned tabs first, keeping each group's relative order.
    private static func ordered(_ tabs: [UmiTab]) -> [UmiTab] {
        tabs.filter(\.pinned) + tabs.filter { !$0.pinned }
    }

    /// Every pane of every tab in this window.
    var allSurfaces: [Ghostty.SurfaceView] { tabs.flatMap(\.panes) }

    override func ownsSurface(_ surface: Ghostty.SurfaceView) -> Bool {
        tabs.contains { $0.contains(surface) } || surfaceTree.contains(surface)
    }

    func tab(containing surface: Ghostty.SurfaceView) -> UmiTab? {
        if surfaceTree.contains(surface) { return selectedTabStorage }
        return tabs.first { $0.contains(surface) }
    }

    func index(of tab: UmiTab) -> Int? { tabs.firstIndex { $0 === tab } }

    /// Where a new tab opens when no position is asked for (S-7). A tab the user goes to opens
    /// right after the selected tab, as in Warp (`window-new-tab-position = current`, the default;
    /// `end` puts it last). One opened in the background goes last, so no tab shifts while the
    /// user isn't looking. `insertTab` keeps it below the pinned tabs.
    func newTabIndex(selecting: Bool) -> Int {
        guard selecting, ghostty.config.windowNewTabPosition == "current",
              let selected = index(of: selectedTab) else { return tabs.count }
        return selected + 1
    }

    /// Show another tab. With `focus`, its focused pane takes keyboard focus (if this is
    /// the key window); without, nothing about focus changes beyond which tree is shown.
    /// Selecting never moves the tab (S-7).
    func selectTab(_ tab: UmiTab, focus: Bool = true) {
        guard tabs.contains(where: { $0 === tab }) else { return }
        guard tab !== selectedTabStorage else {
            if focus, let target = tab.effectiveFocusedSurface, window?.isKeyWindow ?? false {
                Ghostty.moveFocus(to: target)
            }
            return
        }
        let previous = selectedTab
        previous.tree = surfaceTree
        if let focusedSurface, previous.contains(focusedSurface) { previous.focusedSurface = focusedSurface }
        setOccluded(previous.panes, occluded: true)

        switchingTabs = true
        selectedTabStorage = tab
        let target = tab.effectiveFocusedSurface
        focusedSurface = target
        surfaceTree = tab.tree
        switchingTabs = false
        titleOverride = tab.name
        objectWillChange.send()

        if focus, let target, window?.isKeyWindow ?? false {
            UmiLayout.moveFocus(to: target, in: self)
        }
        UmiLooking.focusChanged(in: self)
        UmiEvents.shared.emit("tab.selected", ["tab": tab.idString, "window": umiIDString])
        UmiState.shared.layoutDidChange()
        if UmiTopology.currentWindow === self { UmiTabHistory.visited(tab) }
    }

    /// Insert a tab, keeping pinned tabs first. `index` is a position among all tabs and
    /// is clamped into the tab's group.
    func insertTab(_ tab: UmiTab, at index: Int? = nil) {
        guard !tabs.contains(where: { $0 === tab }) else { return }
        let pinnedCount = tabs.filter(\.pinned).count
        var position = index ?? tabs.count
        if tab.pinned {
            position = min(max(position, 0), pinnedCount)
        } else {
            position = min(max(position, pinnedCount), tabs.count)
        }
        tabs.insert(tab, at: position)
        setOccluded(tab.panes, occluded: tab !== selectedTabStorage)
        UmiState.shared.layoutDidChange()
    }

    /// Take a tab out of this window. If it was selected, a neighbor is selected instead;
    /// if it was the last tab, the window closes (unless `keepWindow`).
    func detachTab(_ tab: UmiTab, focusNeighbor: Bool = true, keepWindow: Bool = false) {
        guard let index = index(of: tab) else { return }
        if tab === selectedTabStorage {
            tab.tree = surfaceTree
            if let focusedSurface, tab.contains(focusedSurface) { tab.focusedSurface = focusedSurface }
        }
        tabs.remove(at: index)
        if tab === selectedTabStorage {
            if tabs.isEmpty {
                if !keepWindow {
                    switchingTabs = true
                    surfaceTree = .init()
                    switchingTabs = false
                    closeWindowWithoutConfirmation()
                }
                return
            }
            let neighbor = tabs[min(index, tabs.count - 1)]
            selectTab(neighbor, focus: focusNeighbor && (window?.isKeyWindow ?? false))
        }
        UmiState.shared.layoutDidChange()
    }

    /// Move a tab within this window. `index` is clamped into the tab's pin group.
    func moveTab(_ tab: UmiTab, to index: Int) {
        guard let from = self.index(of: tab) else { return }
        tabs.remove(at: from)
        let pinnedCount = tabs.filter(\.pinned).count
        let position = tab.pinned
            ? min(max(index, 0), pinnedCount)
            : min(max(index, pinnedCount), tabs.count)
        tabs.insert(tab, at: position)
        UmiState.shared.layoutDidChange()
    }

    /// Pin or unpin a tab. Pinned tabs come first, in pin order; unpinning moves the tab
    /// to the top of the unpinned group.
    func setPinned(_ tab: UmiTab, _ pinned: Bool) {
        guard let from = index(of: tab), tab.pinned != pinned else { return }
        tabs.remove(at: from)
        tab.pinned = pinned
        let pinnedCount = tabs.filter(\.pinned).count
        tabs.insert(tab, at: pinnedCount)
        UmiState.shared.layoutDidChange()
    }

    /// Replace a tab's tree. For the selected tab this is the visible tree.
    func setTree(_ tree: SplitTree<Ghostty.SurfaceView>, for tab: UmiTab) {
        if tab === selectedTabStorage {
            surfaceTree = tree
        } else {
            tab.tree = tree
            setOccluded(tab.panes, occluded: true)
            UmiState.shared.layoutDidChange()
        }
    }

    func tree(of tab: UmiTab) -> SplitTree<Ghostty.SurfaceView> {
        tab === selectedTabStorage ? surfaceTree : tab.tree
    }

    /// Replace the whole tab list (undo and restoration).
    func restoreTabs(_ newTabs: [UmiTab], selected: UmiTab, focusedPane: Ghostty.SurfaceView?) {
        guard !newTabs.isEmpty else { return }
        // The given tabs carry the trees to show; the visible tree is replaced, not saved.
        tabs = Self.ordered(newTabs)
        switchingTabs = true
        selectedTabStorage = tabs.contains { $0 === selected } ? selected : tabs[0]
        let tab = selectedTab
        focusedSurface = focusedPane.flatMap { tab.tree.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface
        surfaceTree = tab.tree
        switchingTabs = false
        titleOverride = tab.name
        for other in tabs where other !== tab { setOccluded(other.panes, occluded: true) }
        objectWillChange.send()
        UmiState.shared.layoutDidChange()
    }

    /// Tell libghostty that panes of hidden tabs aren't visible, so they stop rendering.
    private func setOccluded(_ panes: [Ghostty.SurfaceView], occluded: Bool) {
        for view in panes {
            guard let surface = view.surface else { continue }
            let visible = !occluded && (window?.occlusionState.contains(.visible) ?? false)
            if view.isWindowVisible != visible {
                ghostty_surface_set_occlusion(surface, visible)
                view.isWindowVisible = visible
            }
            if occluded { view.focusDidChange(false) }
        }
    }

    // MARK: Base Controller Overrides

    override var titleOverride: String? {
        didSet {
            guard !switchingTabs, let tab = selectedTabStorage, tab.name != titleOverride else { return }
            tab.name = titleOverride
            UmiEvents.shared.emit("tab.renamed", ["tab": tab.idString, "name": titleOverride ?? ""])
            UmiState.shared.layoutDidChange()
        }
    }

    override func surfaceTreeDidChange(from: SplitTree<Ghostty.SurfaceView>, to: SplitTree<Ghostty.SurfaceView>) {
        super.surfaceTreeDidChange(from: from, to: to)

        // Update our zoom state
        if let window = window as? TerminalWindow {
            window.surfaceIsZoomed = to.zoomed != nil
        }

        guard !switchingTabs, let tab = selectedTabStorage else { return }
        tab.tree = to
        if let focusedSurface, to.contains(focusedSurface) { tab.focusedSurface = focusedSurface }
        UmiState.shared.layoutDidChange()

        // The selected tab lost its last pane: close the tab (or the window).
        if to.isEmpty {
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.selectedTabStorage, current === tab, self.surfaceTree.isEmpty else { return }
                self.closeTabImmediately(tab)
            }
        }
    }

    override func replaceSurfaceTree(
        _ newTree: SplitTree<Ghostty.SurfaceView>,
        moveFocusTo newView: Ghostty.SurfaceView? = nil,
        moveFocusFrom oldView: Ghostty.SurfaceView? = nil,
        undoAction: String? = nil
    ) {
        // The last pane of the tab is going away: close the tab so undo brings it back.
        if newTree.isEmpty {
            closeTabImmediately(selectedTab)
            return
        }

        super.replaceSurfaceTree(
            newTree,
            moveFocusTo: newView,
            moveFocusFrom: oldView,
            undoAction: undoAction)
    }

    /// Undo of a tree change made while another tab was shown applies to that tab.
    override func undoTreeOwner() -> AnyObject? { selectedTabStorage }

    /// After a close, focus returns to the pane of this tab used most recently (L-18).
    override func previouslyFocusedSurface(excluding node: SplitTree<Ghostty.SurfaceView>.Node) -> Ghostty.SurfaceView? {
        let closing = Set(node.leaves().map(ObjectIdentifier.init))
        let remaining = (surfaceTree.root?.leaves() ?? []).filter { !closing.contains(ObjectIdentifier($0)) }
        return UmiFocusHistory.mostRecent(among: remaining)
    }

    /// Ghostty's "toggle command palette" opens Umi's palette (L-14).
    @IBAction override func toggleCommandPalette(_ sender: Any?) {
        palette.toggle(.commands, in: self)
    }

    override func restoreUndoTree(_ tree: SplitTree<Ghostty.SurfaceView>, owner: AnyObject?) {
        guard let tab = owner as? UmiTab, tab !== selectedTabStorage else {
            surfaceTree = tree
            return
        }
        guard tabs.contains(where: { $0 === tab }) else { return }
        tab.tree = tree
        selectTab(tab)
    }

    // MARK: Terminal Creation

    /// Returns all the available terminal controllers present in the app currently.
    static var all: [TerminalController] {
        return NSApplication.shared.windows.compactMap {
            $0.windowController as? TerminalController
        }
    }

    // Keep track of the last point that our window was launched at so that new
    // windows "cascade" over each other and don't just launch directly on top
    // of each other.
    private static var lastCascadePoint = NSPoint(x: 0, y: 0)

    private static func applyCascade(to window: NSWindow, hasFixedPos: Bool) {
        if hasFixedPos { return }

        if all.count > 1 {
            lastCascadePoint = window.cascadeTopLeft(from: lastCascadePoint)
        } else {
            // We assume the window frame is already correct at this point,
            // so we pass .zero to let cascade use the current frame position.
            lastCascadePoint = window.cascadeTopLeft(from: .zero)
        }
    }

    // The preferred parent terminal controller.
    static var preferredParent: TerminalController? {
        UmiTopology.currentWindow ?? all.first {
            $0.window?.isMainWindow ?? false
        } ?? lastMain ?? all.last
    }

    // The last controller to be main. We use this when paired with "preferredParent"
    // to find the preferred window to attach new tabs, perform actions, etc.
    static private(set) weak var lastMain: TerminalController?

    /// Present a newly created window: in front and focused, or (without focus) behind the
    /// key window without activating the app (L-8).
    fileprivate func present(focus: Bool) {
        guard let window else { return }
        if focus {
            showWindowSafely(self)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            presentsWithoutFocus = true
            positionWindow()
            if let key = NSApp.keyWindow, key !== window, key.isVisible {
                window.order(.below, relativeTo: key.windowNumber)
            } else {
                window.orderFront(nil)
            }
            syncAppearance()
        }
    }

    /// The "new window" action.
    static func newWindow(
        _ ghostty: Ghostty.App,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        withParent explicitParent: NSWindow? = nil,
        focus: Bool = true
    ) -> TerminalController {
        let c = TerminalController.init(ghostty, withBaseConfig: baseConfig)

        // Get our parent. Our parent is the one explicitly given to us,
        // otherwise the focused terminal, otherwise an arbitrary one.
        let parent: NSWindow? = explicitParent ?? preferredParent?.window
        if let parentController = parent?.windowController as? TerminalController {
            c.isBackgroundOpaque = parentController.isBackgroundOpaque
        }

        if focus, let parent, parent.styleMask.contains(.fullScreen) {
            c.toggleFullscreen(mode: .native)
        } else if focus, let fullscreenMode = ghostty.config.windowFullscreen {
            switch fullscreenMode {
            case .native:
                c.toggleFullscreen(mode: .native)

            case .nonNative, .nonNativeVisibleMenu, .nonNativePaddedNotch:
                DispatchQueue.main.async {
                    c.toggleFullscreen(mode: fullscreenMode)
                }
            }
        }

        if focus {
            c.scheduleInitialPresentation {
                c.present(focus: true)
                if let window = c.window, !window.styleMask.contains(.fullScreen) {
                    let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                    DispatchQueue.main.async {
                        Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
                    }
                }
            }
        } else {
            // Shown right away so the CLI can report it, but never key or in front.
            c.present(focus: false)
            if let window = c.window {
                let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
                Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            }
        }

        // Setup our undo
        if let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                // Close the window when undoing
                undoManager.disableUndoRegistration {
                    target.closeWindow(nil)
                }

                // Register redo action
                undoManager.registerUndo(
                    withTarget: ghostty,
                    expiresAfter: target.undoExpiration
                ) { ghostty in
                    _ = TerminalController.newWindow(
                        ghostty,
                        withBaseConfig: baseConfig,
                        withParent: explicitParent)
                }
            }
        }

        UmiState.shared.windowCreated(c)
        return c
    }

    /// Create a new window with an existing split tree (a pane dragged or moved out).
    /// The window is sized so the tree keeps its size, and never unusably small (M-5).
    static func newWindow(
        _ ghostty: Ghostty.App,
        tree: SplitTree<Ghostty.SurfaceView>,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil,
        focus: Bool = true,
        registerUndo: Bool = true
    ) -> TerminalController {
        let tab = UmiTab(tree: tree)
        return newWindow(ghostty, tabs: [tab], selected: tab, position: position,
                         confirmUndo: confirmUndo, inheritBackgroundOpacity: inheritBackgroundOpacity,
                         focus: focus, registerUndo: registerUndo)
    }

    /// Create a new window holding existing tabs.
    static func newWindow(
        _ ghostty: Ghostty.App,
        tabs: [UmiTab],
        selected: UmiTab,
        frame: NSRect? = nil,
        position: NSPoint? = nil,
        confirmUndo: Bool = true,
        inheritBackgroundOpacity: Bool? = nil,
        focus: Bool = true,
        registerUndo: Bool = true
    ) -> TerminalController {
        // The size the selected tree has now, before it moves into the new window.
        let treeSize: CGSize? = selected.tree.root?.viewBounds()

        let c = TerminalController.init(ghostty, tabs: tabs, selected: selected)
        if let inheritBackgroundOpacity {
            c.isBackgroundOpaque = inheritBackgroundOpacity
        }

        if let window = c.window {
            if let frame {
                c.explicitFrame = frame
                window.setFrame(frame, display: false)
            } else if let treeSize, treeSize.width > 0, treeSize.height > 0 {
                let chrome = UmiTheme.chromeSize(sidebar: UmiState.shared.sidebarVisible, width: c.sidebarWidth)
                window.setContentSize(CGSize(
                    width: max(treeSize.width + chrome.width, UmiTheme.minimumContentSize.width),
                    height: max(treeSize.height + chrome.height, UmiTheme.minimumContentSize.height)))
            }
            if let position {
                window.setFrameTopLeftPoint(position)
            }
            window.constrainToScreen()
        }

        if focus {
            c.showWindowSafely(self)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            c.present(focus: false)
        }
        if position == nil, frame == nil, let window = c.window, !window.styleMask.contains(.fullScreen) {
            let hasFixedPos = c.derivedConfig.windowPositionX != nil && c.derivedConfig.windowPositionY != nil
            Self.applyCascade(to: window, hasFixedPos: hasFixedPos)
            window.constrainToScreen()
        }
        if focus, let target = selected.effectiveFocusedSurface {
            DispatchQueue.main.async { Ghostty.moveFocus(to: target) }
        }

        // Setup our undo
        if registerUndo, let undoManager = c.undoManager {
            undoManager.setActionName("New Window")
            undoManager.registerUndo(
                withTarget: c,
                expiresAfter: c.undoExpiration
            ) { target in
                undoManager.disableUndoRegistration {
                    if confirmUndo {
                        target.closeWindow(nil)
                    } else {
                        target.closeWindowImmediately()
                    }
                }
            }
        }

        UmiState.shared.windowCreated(c)
        return c
    }

    /// The "new tab" action: a tab in the parent's window (or a new window if there is none).
    static func newTab(
        _ ghostty: Ghostty.App,
        from parent: NSWindow? = nil,
        withBaseConfig baseConfig: Ghostty.SurfaceConfiguration? = nil,
        focus: Bool = true
    ) -> TerminalController? {
        guard let parent,
              let parentController = parent.windowController as? TerminalController else {
            return newWindow(ghostty, withBaseConfig: baseConfig, withParent: parent, focus: focus)
        }
        parentController.addTab(config: baseConfig, select: focus, focus: focus)
        return parentController
    }

    /// Create a new tab in this window running a new shell, at `index` (a position among all
    /// tabs) or else where new tabs open (`newTabIndex`).
    @discardableResult
    func addTab(
        config: Ghostty.SurfaceConfiguration?,
        at index: Int? = nil,
        select: Bool,
        focus: Bool,
        name: String? = nil,
        color: TerminalTabColor = .none
    ) -> (UmiTab, Ghostty.SurfaceView)? {
        guard let ghosttyApp = ghostty.app else { return nil }
        let view = Ghostty.SurfaceView(ghosttyApp, baseConfig: config)
        // Start the pane at the size it will have when shown, so its program sees the
        // right number of columns and rows even while the tab is in the background.
        let contentSize = surfaceTree.viewBounds()
        if contentSize.width > 0, contentSize.height > 0 {
            view.frame = CGRect(origin: .zero, size: contentSize)
            view.sizeDidChange(contentSize)
        }
        let tab = UmiTab(tree: .init(view: view))
        tab.name = name
        tab.color = color
        insertTab(tab, at: index ?? newTabIndex(selecting: select))
        // Where it went, for redo: by then the selection (and so `newTabIndex`) may differ.
        let placed = self.index(of: tab)
        if select {
            selectTab(tab, focus: focus)
            if focus {
                window?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.async { Ghostty.moveFocus(to: view) }
            }
        }

        if let undoManager {
            undoManager.setActionName("New Tab")
            undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
                undoManager.disableUndoRegistration {
                    target.closeTabImmediately(tab, registerUndo: false)
                }
                // Redo opens the tab again, like Ghostty's New Tab.
                undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                    target.addTab(config: config, at: placed ?? index, select: select, focus: focus, name: name, color: color)
                }
            }
        }
        UmiEvents.shared.emit("tab.created", ["tab": tab.idString, "window": umiIDString])
        UmiEvents.shared.emit("pane.created", ["pane": view.umiID, "tab": tab.idString, "window": umiIDString])
        return (tab, view)
    }

    // MARK: - Methods

    @objc private func ghosttyConfigDidChange(_ notification: Notification) {
        // Get our managed configuration object out
        guard let config = notification.userInfo?[
            Notification.Name.GhosttyConfigChangeKey
        ] as? Ghostty.Config else { return }

        // If this is an app-level config update then we update some things.
        if notification.object == nil {
            // Update our derived config
            self.derivedConfig = DerivedConfig(config)
            syncRestoration()

            // If we have no surfaces in our window (is that possible?) then we update
            // our window appearance based on the root config. If we have surfaces, we
            // don't call this because focused surface changes will trigger appearance updates.
            if surfaceTree.isEmpty {
                syncAppearance(.init(config))
            }

            return
        }
    }

    /// Umi restores windows from its own state directory (see UmiPersistence), never
    /// through AppKit's per-app saved state, which would be shared by every instance of
    /// the same bundle id.
    private func syncRestoration() {
        guard isWindowLoaded, let window else { return }
        window.isRestorable = false
    }

    override func syncAppearance() {
        // When our focus changes, we update our window appearance based on the
        // currently focused surface.
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)
    }

    private func syncAppearance(_ surfaceConfig: Ghostty.SurfaceView.DerivedConfig) {
        // Let our window handle its own appearance
        guard let window = window as? TerminalWindow else { return }

        // Sync our zoom state for splits
        window.surfaceIsZoomed = surfaceTree.zoomed != nil

        // Set the font for the window and tab titles.
        if let titleFontName = surfaceConfig.windowTitleFontFamily {
            window.titlebarFont = NSFont(name: titleFontName, size: NSFont.systemFontSize)
        } else {
            window.titlebarFont = nil
        }

        // Call this last in case it uses any of the properties above.
        window.syncAppearance(surfaceConfig)
        terminalViewContainer?.ghosttyConfigDidChange(ghostty.config, preferredBackgroundColor: window.preferredBackgroundColor)
    }

    /// Adjusts the given frame for the configured window position.
    func adjustForWindowPosition(frame: NSRect, on screen: NSScreen) -> NSRect {
        guard let x = derivedConfig.windowPositionX else { return frame }
        guard let y = derivedConfig.windowPositionY else { return frame }

        let origin = screen.origin(
            fromTopLeftOffsetX: CGFloat(x),
            offsetY: CGFloat(y),
            windowSize: frame.size)

        var safeOrigin = origin
        let vf = screen.visibleFrame
        safeOrigin.x = min(max(safeOrigin.x, vf.minX), vf.maxX - frame.width)
        safeOrigin.y = min(max(safeOrigin.y, vf.minY), vf.maxY - frame.height)

        var result = frame
        result.origin = safeOrigin
        return result
    }

    /// This is called anytime a node in the surface tree is being removed.
    override func closeSurface(
        _ node: SplitTree<Ghostty.SurfaceView>.Node,
        withConfirmation: Bool = true
    ) {
        // If this isn't the root then we're dealing with a split closure.
        if surfaceTree.root != node {
            super.closeSurface(node, withConfirmation: withConfirmation)
            return
        }

        // Closing the last pane of a tab closes the tab.
        if withConfirmation {
            closeTab(selectedTab, sender: nil)
        } else {
            closeTabImmediately(selectedTab)
        }
    }

    /// A pane in a hidden tab whose program ended: take it out of its tab.
    @objc private func onCloseHiddenSurface(_ notification: Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard !surfaceTree.contains(target) else { return }   // the base class handles visible panes
        guard let tab = tabs.first(where: { $0.contains(target) }),
              let node = tab.tree.root?.node(view: target) else { return }
        let newTree = tab.tree.removing(node)
        UmiEvents.shared.emit("pane.closed", ["pane": target.umiID, "tab": tab.idString, "window": umiIDString])
        if newTree.isEmpty {
            closeTabImmediately(tab)
        } else {
            tab.tree = newTree
            UmiState.shared.layoutDidChange()
        }
    }

    /// Replace a tab's tree as one undoable step. Undo holds the old tree, and so its panes,
    /// for the undo interval, as closing a visible pane does.
    func replaceTree(_ newTree: SplitTree<Ghostty.SurfaceView>, for tab: UmiTab, undoAction: String) {
        let oldTree = tree(of: tab)
        let lostFocus = tab === selectedTabStorage && focusedSurface.map { !newTree.contains($0) } ?? false
        setTree(newTree, for: tab)
        // The focused pane went away (an undone split): focus moves to one that's left.
        if lostFocus, let next = tab.focusedSurface.flatMap({ newTree.contains($0) ? $0 : nil })
            ?? UmiFocusHistory.mostRecent(among: newTree.root?.leaves() ?? []) ?? newTree.root?.leaves().first {
            DispatchQueue.main.async { Ghostty.moveFocus(to: next) }
        }
        guard let undoManager else { return }
        undoManager.setActionName(undoAction)
        undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
            guard !target.isClosed, target.tabs.contains(where: { $0 === tab }) else { return }
            target.replaceTree(oldTree, for: tab, undoAction: undoAction)
        }
    }

    /// Close part of a tab that isn't shown; a tab left empty closes. Both can be undone,
    /// and reopened (⇧⌘T).
    func closeHiddenNode(_ node: SplitTree<Ghostty.SurfaceView>.Node, in tab: UmiTab) {
        let oldTree = tree(of: tab)
        let newTree = oldTree.removing(node)
        if newTree.isEmpty {
            closeTabImmediately(tab)
        } else {
            if case .leaf(let view) = node { UmiReopen.shared.recordPane(view, tab: tab, tree: oldTree, in: self) }
            replaceTree(newTree, for: tab, undoAction: "Close Terminal")
        }
    }

    /// A pane of the shown tab is being closed (not its last: that closes the tab).
    override func surfaceNodeWillClose(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
        guard case .leaf(let view) = node, surfaceTree.root != node else { return }
        UmiReopen.shared.recordPane(view, tab: selectedTab, tree: surfaceTree, in: self)
    }

    // MARK: Panes in hidden tabs (AppleScript, App Intents)

    /// The base class only knows the shown tree; a pane in a hidden tab goes through its tab.
    private func hiddenTab(containing view: Ghostty.SurfaceView) -> UmiTab? {
        surfaceTree.contains(view) ? nil : tabs.first { $0.contains(view) }
    }

    override func revealSurface(_ surface: Ghostty.SurfaceView) {
        if let tab = hiddenTab(containing: surface) { selectTab(tab, focus: false) }
    }

    override func focusSurface(_ view: Ghostty.SurfaceView) {
        if let tab = hiddenTab(containing: view) { selectTab(tab, focus: false) }
        super.focusSurface(view)
    }

    @discardableResult
    override func newSplit(
        at oldView: Ghostty.SurfaceView,
        direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
        baseConfig config: Ghostty.SurfaceConfiguration? = nil
    ) -> Ghostty.SurfaceView? {
        guard let tab = hiddenTab(containing: oldView) else {
            return super.newSplit(at: oldView, direction: direction, baseConfig: config)
        }
        // Split inside the hidden tab and leave it hidden, as Ghostty does in a background tab.
        guard let app = ghostty.app else { return nil }
        let newView = Ghostty.SurfaceView(app, baseConfig: config)
        guard let newTree = try? tab.tree.inserting(view: newView, at: oldView, direction: direction) else { return nil }
        let bounds = surfaceTree.viewBounds()
        if bounds.width > 0, bounds.height > 0,
           let frame = newTree.root?.frames(in: bounds).first(where: { $0.view === newView })?.frame {
            newView.frame = CGRect(origin: .zero, size: frame.size)
            newView.sizeDidChange(newView.frame.size)
        }
        replaceTree(SplitTree(root: newTree.root, zoomed: nil), for: tab, undoAction: "New Split")
        tab.focusedSurface = newView
        return newView
    }

    override func closeSurface(_ view: Ghostty.SurfaceView, withConfirmation: Bool = true) {
        guard let tab = hiddenTab(containing: view), let node = tab.tree.root?.node(view: view) else {
            super.closeSurface(view, withConfirmation: withConfirmation)
            return
        }
        if withConfirmation {
            // Show the tab, so the question is about something the person can see.
            selectTab(tab, focus: true)
            super.closeSurface(view, withConfirmation: true)
            return
        }
        closeHiddenNode(node, in: tab)
    }

    /// Close a tab without asking. Undo brings it back (for as long as undo-timeout keeps
    /// its panes alive).
    func closeTabImmediately(_ tab: UmiTab, registerUndo: Bool = true) {
        guard let index = index(of: tab) else { return }
        let paneIDs = tree(of: tab).root?.leaves().map(\.umiID) ?? []
        let tabsBefore = tabs
        let selectedBefore = selectedTab
        let focusedBefore = focusedSurface

        UmiEditor.saveDirtyDocuments(of: tab)

        if tabs.count == 1 {
            closeWindowImmediately()
            return
        }

        detachTab(tab)
        // ⇧⌘T can bring it back (not when undo of New Tab is what closes it).
        if registerUndo { UmiReopen.shared.recordTab(tab, index: index, in: self) }

        if registerUndo, let undoManager {
            undoManager.setActionName("Close Tab")
            undoManager.registerUndo(withTarget: self, expiresAfter: undoExpiration) { target in
                guard target.window?.isVisible ?? false else { return }
                if !target.tabs.contains(where: { $0 === tab }) {
                    target.insertTab(tab, at: index)
                }
                if selectedBefore === tab {
                    target.selectTab(tab)
                    if let focusedBefore, tab.contains(focusedBefore) {
                        DispatchQueue.main.async { Ghostty.moveFocus(to: focusedBefore) }
                    }
                }
                _ = tabsBefore
                undoManager.registerUndo(withTarget: target, expiresAfter: target.undoExpiration) { target in
                    target.closeTabImmediately(tab)
                }
            }
        }

        for pane in paneIDs {
            UmiEvents.shared.emit("pane.closed", ["pane": pane, "tab": tab.idString, "window": umiIDString])
        }
        UmiEvents.shared.emit("tab.closed", ["tab": tab.idString, "window": umiIDString])
    }

    /// Close a tab, asking first if a program is running in it.
    func closeTab(_ tab: UmiTab, sender: Any?) {
        guard tree(of: tab).contains(where: { $0.needsConfirmQuit }) else {
            closeTabImmediately(tab)
            return
        }
        confirmClose(
            messageText: "Close Tab?",
            informativeText: "The terminal still has a running process. If you close the tab the process will be killed."
        ) { [weak self] in
            self?.closeTabImmediately(tab)
        }
    }

    /// Close every tab but `keep` (the sidebar row's menu), asking first if a program runs in
    /// one of them. Pinned tabs aren't spared, as in Warp. Each can be reopened (⇧⌘T).
    func closeTabs(otherThan keep: UmiTab) {
        closeTabs(tabs.filter { $0 !== keep }, actionName: "Close Other Tabs", question: "Close Other Tabs?")
    }

    /// Close the tabs listed below `tab` in the sidebar.
    func closeTabs(below tab: UmiTab) {
        guard let index = index(of: tab) else { return }
        closeTabs(Array(tabs[(index + 1)...]), actionName: "Close Tabs Below", question: "Close Tabs Below?")
    }

    private func closeTabs(_ toClose: [UmiTab], actionName: String, question: String) {
        guard !toClose.isEmpty else { return }
        let close = { [weak self] in
            guard let self else { return }
            self.undoManager?.beginUndoGrouping()
            defer { self.undoManager?.endUndoGrouping() }
            for tab in toClose where self.tabs.contains(where: { $0 === tab }) { self.closeTabImmediately(tab) }
            self.undoManager?.setActionName(actionName)
        }
        guard toClose.contains(where: { tree(of: $0).contains(where: { $0.needsConfirmQuit }) }) else {
            close()
            return
        }
        confirmClose(
            messageText: question,
            informativeText: "At least one of these tabs still has a running process. If you close the tabs the processes will be killed."
        ) { close() }
    }

    private func closeOtherTabsImmediately() {
        let keep = selectedTab
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        for tab in tabs where tab !== keep {
            closeTabImmediately(tab)
        }
        undoManager?.setActionName("Close Other Tabs")
    }

    private func closeTabsOnTheRightImmediately() {
        guard let current = index(of: selectedTab) else { return }
        let toClose = tabs.enumerated().filter { $0.offset > current }.map(\.element)
        guard !toClose.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping() }
        for tab in toClose { closeTabImmediately(tab) }
        undoManager?.setActionName("Close Tabs to the Right")
    }

    /// Closes the window (all its tabs) immediately and without confirmation. Undo
    /// restores it.
    func closeWindowImmediately() {
        guard let window = window else { return }

        cancelPendingInitialPresentation()
        registerUndoForCloseWindow()
        for tab in tabs { UmiEditor.saveDirtyDocuments(of: tab) }
        // ⇧⌘T can bring it back (not when undo of New Window is what closes it).
        if !surfaceTree.isEmpty { selectedTab.tree = surfaceTree }
        if !(undoManager?.isUndoing ?? false) { UmiReopen.shared.recordWindow(self) }

        let paneIDs = allSurfaces.map(\.umiID)
        let tabIDs = tabs.map(\.idString)
        window.close()
        for pane in paneIDs { UmiEvents.shared.emit("pane.closed", ["pane": pane, "window": umiIDString]) }
        for tab in tabIDs { UmiEvents.shared.emit("tab.closed", ["tab": tab, "window": umiIDString]) }
        UmiEvents.shared.emit("window.closed", ["window": umiIDString])
    }

    /// Close the window without confirmation or undo (its tabs moved elsewhere).
    func closeWindowWithoutConfirmation() {
        cancelPendingInitialPresentation()
        tabs = []
        window?.close()
        UmiEvents.shared.emit("window.closed", ["window": umiIDString])
    }

    private func registerUndoForCloseWindow() {
        guard let undoManager, undoManager.isUndoRegistrationEnabled else { return }
        guard let undoState else { return }
        undoManager.setActionName("Close Window")
        undoManager.registerUndo(withTarget: ghostty, expiresAfter: undoExpiration) { ghostty in
            let newController = TerminalController(ghostty, with: undoState)
            undoManager.registerUndo(withTarget: newController, expiresAfter: newController.undoExpiration) { target in
                target.closeWindowImmediately()
            }
        }
    }

    /// Close all windows, asking for confirmation if necessary.
    static func closeAllWindows() {
        guard let confirmWindow = all
            .first(where: { $0.allSurfaces.contains(where: { $0.needsConfirmQuit }) })?
            .window
        else {
            closeAllWindowsImmediately()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Close All Windows?"
        alert.informativeText = "All terminal sessions will be terminated."
        alert.addButton(withTitle: "Close All Windows")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: confirmWindow, completionHandler: { response in
            if response == .alertFirstButtonReturn {
                alert.window.orderOut(nil)
                closeAllWindowsImmediately()
            }
        })
    }

    static private func closeAllWindowsImmediately() {
        let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager
        undoManager?.beginUndoGrouping()
        all.forEach { $0.closeWindowImmediately() }
        undoManager?.setActionName("Close All Windows")
        undoManager?.endUndoGrouping()
    }

    // MARK: Undo/Redo

    /// The state that we require to recreate a TerminalController from an undo.
    struct UndoState {
        let frame: NSRect
        let tabs: [UmiTab]
        let selected: UmiTab
        let focusedSurface: UUID?
    }

    convenience init(_ ghostty: Ghostty.App, with undoState: UndoState) {
        self.init(ghostty, tabs: undoState.tabs, selected: undoState.selected)

        showWindow(nil)
        if let window {
            window.setFrame(undoState.frame, display: true)
            window.makeKeyAndOrderFront(nil)
            if let focusedUUID = undoState.focusedSurface,
               let focusTarget = surfaceTree.first(where: { $0.id == focusedUUID }) {
                DispatchQueue.main.async { Ghostty.moveFocus(to: focusTarget, from: nil) }
            } else if let first = surfaceTree.first {
                self.focusedSurface = first
                DispatchQueue.main.async { Ghostty.moveFocus(to: first, from: nil) }
            }
        }
        UmiState.shared.windowCreated(self)
    }

    /// The current undo state for this controller
    var undoState: UndoState? {
        guard let window else { return nil }
        guard !surfaceTree.isEmpty else { return nil }
        selectedTab.tree = surfaceTree
        return .init(
            frame: window.frame,
            tabs: tabs,
            selected: selectedTab,
            focusedSurface: focusedSurface?.id)
    }

    // MARK: - NSWindowController

    override func windowWillLoad() {
        // We do NOT want to cascade because we handle this manually from the manager.
        shouldCascadeWindows = false
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        guard let window else { return }

        // Umi manages tabs itself; AppKit must never merge windows into tab groups.
        window.tabbingMode = .disallowed
        // While the screen is locked or asleep no frames are drawn, and AppKit's window-opening
        // animation never ends: each window opened then (agents open windows unattended) kept a
        // thread waiting for ever, until the shared thread pool ran out. No animation then.
        if UmiScreen.isUnavailable { window.animationBehavior = .none }

        let config = ghostty.config
        syncRestoration()

        if case let .leaf(view) = surfaceTree.root, focusedSurface == nil {
            focusedSurface = view
        }

        // Initialize our content view to the SwiftUI root
        let container = TerminalViewContainer {
            TerminalView(ghostty: ghostty, viewModel: self, delegate: self)
        }

        // The terminal's initial size plus the sidebar.
        let chrome = UmiTheme.chromeSize(sidebar: UmiState.shared.sidebarVisible, width: sidebarWidth)
        container.initialContentSize = focusedSurface?.initialSize.map {
            NSSize(width: $0.width + chrome.width, height: $0.height + chrome.height)
        }

        window.contentView = container

        // If we have a default size, we want to apply it.
        if let defaultSize {
            defaultSize.apply(to: window)

            if case .contentIntrinsicSize = defaultSize {
                if let screen = window.screen ?? NSScreen.main {
                    let frame = self.adjustForWindowPosition(frame: window.frame, on: screen)
                    window.setFrameOrigin(frame.origin)
                }
            }
        }

        syncAppearance(.init(config))
    }

    /// Place the window before it's first shown.
    private func positionWindow() {
        guard let terminalWindow = window as? TerminalWindow else { return }
        if let explicitFrame {
            terminalWindow.setFrame(explicitFrame, display: false)
            terminalWindow.constrainToScreen()
            return
        }
        let originChanged = terminalWindow.setInitialWindowPosition(
            x: derivedConfig.windowPositionX,
            y: derivedConfig.windowPositionY,
        )
        let restored = LastWindowPosition.shared.restore(
            terminalWindow,
            origin: !originChanged,
            size: defaultSize == nil,
        )
        if !originChanged, !restored {
            terminalWindow.center()
        }
    }

    /// Setup correct window frame before showing the window
    override func showWindow(_ sender: Any?) {
        guard window is TerminalWindow else { return }
        positionWindow()
        super.showWindow(sender)
        syncAppearance()
    }

    // MARK: NSWindowDelegate

    override func windowShouldClose(_ sender: NSWindow) -> Bool {
        closeWindow(nil)
        // We always explicitly close the window ourselves.
        return false
    }

    override func windowWillClose(_ notification: Notification) {
        isClosed = true
        super.windowWillClose(notification)
        cancelPendingInitialPresentation()
        UmiState.shared.windowClosed(self)

        if let focusedWindow = NSApplication.shared.keyWindow, focusedWindow != window {
            let frame = focusedWindow.frame
            Self.lastCascadePoint = NSPoint(x: frame.minX, y: frame.maxY)
        }
    }

    override func windowDidBecomeKey(_ notification: Notification) {
        super.windowDidBecomeKey(notification)
        UmiTopology.windowBecameCurrent(self)
        UmiLooking.focusChanged(in: self)
    }

    override func windowDidMove(_ notification: Notification) {
        super.windowDidMove(notification)
        LastWindowPosition.shared.save(window)
        UmiState.shared.layoutDidChange(persistOnly: true)
    }

    override func windowDidResize(_ notification: Notification) {
        super.windowDidResize(notification)
        LastWindowPosition.shared.save(window)
        if let window = self.window as? TerminalWindow {
            window.syncWindowTitleAppearance()
        }
        UmiState.shared.layoutDidChange(persistOnly: true)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        LastWindowPosition.shared.save(window)
        Self.lastMain = self
    }

    // MARK: First Responder

    @IBAction func newWindow(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newWindow(surface: surface)
    }

    @IBAction func newTab(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.newTab(surface: surface)
    }

    @IBAction func closeTab(_ sender: Any?) {
        closeTab(selectedTab, sender: sender)
    }

    @IBAction func closeOtherTabs(_ sender: Any?) {
        guard tabs.count > 1 else { return }
        let needsConfirm = tabs.contains { $0 !== selectedTab && tree(of: $0).contains(where: { $0.needsConfirmQuit }) }
        guard needsConfirm else {
            closeOtherTabsImmediately()
            return
        }
        confirmClose(
            messageText: "Close Other Tabs?",
            informativeText: "At least one other tab still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeOtherTabsImmediately()
        }
    }

    @IBAction func closeTabsOnTheRight(_ sender: Any?) {
        guard let current = index(of: selectedTab) else { return }
        let toClose = tabs.enumerated().filter { $0.offset > current }.map(\.element)
        guard !toClose.isEmpty else { return }
        let needsConfirm = toClose.contains { tree(of: $0).contains(where: { $0.needsConfirmQuit }) }
        guard needsConfirm else {
            closeTabsOnTheRightImmediately()
            return
        }
        confirmClose(
            messageText: "Close Tabs on the Right?",
            informativeText: "At least one tab to the right still has a running process. If you close the tab the process will be killed."
        ) {
            self.closeTabsOnTheRightImmediately()
        }
    }

    @IBAction func returnToDefaultSize(_ sender: Any?) {
        guard let window, let defaultSize else { return }
        defaultSize.apply(to: window)
    }

    /// Resize the window so that the given surface is the given size. Only when the
    /// surface is the only pane of the only tab.
    func resizeWindow(_ surfaceView: Ghostty.SurfaceView, to size: NSSize) -> Bool {
        guard let window,
              let screen = window.screen ?? NSScreen.main,
              case .leaf(let view) = surfaceTree.root, view == surfaceView,
              !surfaceView.inspectorVisible,
              tabs.count == 1,
              !(fullscreenStyle?.isFullscreen ?? false) else { return false }

        let dw = size.width > 0 ? size.width - surfaceView.frame.width : 0
        let dh = size.height > 0 ? size.height - surfaceView.frame.height : 0

        let visible = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width + dw, visible.width)
        frame.size.height = min(frame.height + dh, visible.height)
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true)
        window.constrainToScreen()
        return true
    }

    /// Every tab counts, not only the shown one: a program running in a hidden tab needs the
    /// same confirmation before the window closes or the app quits.
    override func windowCanBeClosedWithoutConfirmation() -> Bool {
        guard super.windowCanBeClosedWithoutConfirmation() else { return false }
        return !allSurfaces.contains { $0.needsConfirmQuit }
    }

    @IBAction override func closeWindow(_ sender: Any?) {
        guard allSurfaces.contains(where: { $0.needsConfirmQuit }) else {
            closeWindowImmediately()
            return
        }
        confirmClose(
            messageText: "Close Window?",
            informativeText: "All terminal sessions in this window will be terminated.",
        ) {
            self.closeWindowImmediately()
        }
    }

    @IBAction func toggleGhosttyFullScreen(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleFullscreen(surface: surface)
    }

    @IBAction func toggleTerminalInspector(_ sender: Any?) {
        guard let surface = focusedSurface?.surface else { return }
        ghostty.toggleTerminalInspector(surface: surface)
    }

    // MARK: - TerminalViewDelegate

    override func focusedSurfaceDidChange(to: Ghostty.SurfaceView?) {
        super.focusedSurfaceDidChange(to: to)

        if let to, let tab = selectedTabStorage, tab.contains(to), tab.focusedSurface !== to {
            tab.focusedSurface = to
            UmiEvents.shared.emit("pane.focused", ["pane": to.umiID, "tab": tab.idString, "window": umiIDString])
            UmiState.shared.layoutDidChange()
        }
        if to != nil { UmiLooking.focusChanged(in: self) }
        if let to, surfaceTree.contains(to) { UmiFocusHistory.focused(to) }

        surfaceAppearanceCancellables.removeAll()
        guard let focusedSurface else { return }
        syncAppearance(focusedSurface.derivedConfig)

        focusedSurface.$derivedConfig
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
        focusedSurface.$backgroundColor
            .dropFirst()
            .sink { [weak self, weak focusedSurface] _ in self?.syncAppearanceOnPropertyChange(focusedSurface) }
            .store(in: &surfaceAppearanceCancellables)
    }

    private func syncAppearanceOnPropertyChange(_ surface: Ghostty.SurfaceView?) {
        guard let surface else { return }
        DispatchQueue.main.async { [weak self, weak surface] in
            guard let surface else { return }
            guard let self else { return }
            guard self.focusedSurface == surface else { return }
            self.syncAppearance(surface.derivedConfig)
        }
    }

    // MARK: - Notifications

    @objc private func onMoveTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface, surfaceTree.contains(target) else { return }
        guard let action = notification.userInfo?[Notification.Name.GhosttyMoveTabKey] as? Ghostty.Action.MoveTab else { return }
        guard action.amount != 0, let current = index(of: selectedTab) else { return }
        UmiLayout.undoable("Move Tab", windows: [self]) {
            self.moveTab(self.selectedTab, to: current + action.amount)
        }
        UmiEvents.shared.emit("tab.moved", ["tab": selectedTab.idString, "window": umiIDString])
    }

    @objc private func onGotoTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface, surfaceTree.contains(target) else { return }
        guard let tabEnumAny = notification.userInfo?[Ghostty.Notification.GotoTabKey] else { return }
        guard let tabEnum = tabEnumAny as? ghostty_action_goto_tab_e else { return }
        let tabIndex: Int32 = tabEnum.rawValue

        // A Ghostty keybinding the user kept (Umi's defaults unbind these keys in favor of
        // its menu items): the same navigation as the menu items.
        if tabIndex <= 0 {
            if tabIndex == GHOSTTY_GOTO_TAB_PREVIOUS.rawValue {
                UmiNavigation.selectAdjacentTab(-1, in: self)
            } else if tabIndex == GHOSTTY_GOTO_TAB_NEXT.rawValue {
                UmiNavigation.selectAdjacentTab(1, in: self)
            } else if tabIndex == GHOSTTY_GOTO_TAB_LAST.rawValue {
                UmiNavigation.selectLastTab(in: self)
            }
        } else {
            UmiNavigation.selectTab(number: Int(tabIndex), in: self)
        }
    }

    @objc private func onCloseTab(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTab(self)
    }

    @objc private func onCloseOtherTabs(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeOtherTabs(self)
    }

    @objc private func onCloseTabsOnTheRight(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeTabsOnTheRight(self)
    }

    @objc private func onCloseWindow(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        closeWindow(self)
    }

    @objc private func onResetWindowSize(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard surfaceTree.contains(target) else { return }
        returnToDefaultSize(nil)
    }

    @objc private func onToggleFullscreen(notification: SwiftUI.Notification) {
        guard let target = notification.object as? Ghostty.SurfaceView else { return }
        guard target == self.focusedSurface else { return }

        let fullscreenMode: FullscreenMode
        if let any = notification.userInfo?[Ghostty.Notification.FullscreenModeKey],
           let mode = any as? FullscreenMode {
            fullscreenMode = mode
        } else {
            Ghostty.logger.warning("no fullscreen mode specified or invalid mode, doing nothing")
            return
        }

        toggleFullscreen(mode: fullscreenMode)
    }

    struct DerivedConfig {
        let backgroundColor: Color
        let macosWindowButtons: Ghostty.MacOSWindowButtons
        let macosTitlebarStyle: Ghostty.Config.MacOSTitlebarStyle
        let maximize: Bool
        let windowPositionX: Int16?
        let windowPositionY: Int16?

        init() {
            self.backgroundColor = Color(NSColor.windowBackgroundColor)
            self.macosWindowButtons = .visible
            self.macosTitlebarStyle = .default
            self.maximize = false
            self.windowPositionX = nil
            self.windowPositionY = nil
        }

        init(_ config: Ghostty.Config) {
            self.backgroundColor = config.backgroundColor
            self.macosWindowButtons = config.macosWindowButtons
            self.macosTitlebarStyle = config.macosTitlebarStyle
            self.maximize = config.maximize
            self.windowPositionX = config.windowPositionX
            self.windowPositionY = config.windowPositionY
        }
    }
}

// MARK: NSMenuItemValidation

extension TerminalController {
    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(closeTabsOnTheRight):
            guard let current = index(of: selectedTab) else { return false }
            return tabs.indices.contains { $0 > current }

        case #selector(closeOtherTabs):
            return tabs.count > 1

        case #selector(returnToDefaultSize):
            guard let window else { return false }
            if window.styleMask.contains(.fullScreen) { return false }
            if fullscreenStyle?.isFullscreen ?? false { return false }
            return defaultSize?.isChanged(for: window) ?? false

        default:
            return super.validateMenuItem(item)
        }
    }
}

// MARK: Default Size

extension TerminalController {
    /// The possible default sizes for a terminal. The size can't purely be known as a
    /// window frame because if we set `window-width/height` then it is based
    /// on content size.
    enum DefaultSize {
        /// A frame, set with `window.setFrame`
        case frame(NSRect)

        /// A content size, set with `window.setContentSize`
        case contentIntrinsicSize

        func isChanged(for window: NSWindow) -> Bool {
            switch self {
            case .frame(let rect):
                return window.frame != rect
            case .contentIntrinsicSize:
                guard let view = window.contentView else {
                    return false
                }

                return view.frame.size != view.intrinsicContentSize
            }
        }

        func apply(to window: NSWindow) {
            switch self {
            case .frame(let rect):
                window.setFrame(rect, display: true)
            case .contentIntrinsicSize:
                guard let size = window.contentView?.intrinsicContentSize else {
                    return
                }

                window.setContentSize(size)
                window.constrainToScreen()
            }
        }
    }

    private var defaultSize: DefaultSize? {
        if derivedConfig.maximize, let screen = window?.screen ?? NSScreen.main {
            return .frame(screen.visibleFrame)
        } else if focusedSurface?.initialSize != nil {
            return .contentIntrinsicSize
        } else {
            return nil
        }
    }
}

extension Ghostty.SurfaceView {
    /// The pane's id as the CLI shows it.
    var umiID: String { id.uuidString.lowercased() }
}

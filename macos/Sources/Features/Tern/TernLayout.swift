import AppKit
import GhosttyKit

/// Window, tab and pane operations shared by the CLI, shortcuts, menus and the sidebar.
///
/// Focus rule (L-8): an operation asked not to focus never changes any window's selected
/// tab or focused pane, never makes a window key and never activates the app, at any
/// moment. It edits the model directly instead of going through AppKit focus changes and
/// restoring them afterwards.
@MainActor
enum TernLayout {
    static var ghostty: Ghostty.App? { (NSApp.delegate as? AppDelegate)?.ghostty }

    static func requireGhostty() throws -> Ghostty.App {
        guard let ghostty, ghostty.app != nil else { throw TernError.failed("the terminal engine isn't ready") }
        return ghostty
    }

    // MARK: Surface configuration

    /// Options for a new pane.
    struct PaneOptions {
        var cwd: String?
        var command: String?
        var input: String?
        var name: String?
        var env: [String: String] = [:]

        init(_ params: TernParams) {
            cwd = params.string("cwd").flatMap { $0.isEmpty ? nil : ($0 as NSString).expandingTildeInPath }
            command = params.string("command").flatMap { $0.isEmpty ? nil : $0 }
            input = params.string("input")
            name = params.string("name").flatMap { $0.isEmpty ? nil : $0 }
        }

        init() {}
    }

    /// A surface configuration for a new pane, inheriting from `source` (working
    /// directory, font size) like Ghostty's own new split/tab does.
    static func surfaceConfig(_ options: PaneOptions, inheritingFrom source: Ghostty.SurfaceView?,
                              context: ghostty_surface_context_e) throws -> Ghostty.SurfaceConfiguration {
        var config: Ghostty.SurfaceConfiguration
        if let surface = source?.surface {
            config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, context))
        } else {
            config = Ghostty.SurfaceConfiguration()
        }
        config.context = context
        // A new pane gets its own identity, never its source's.
        for key in ["TERN_PANE_ID", "TERN_INSTANCE"] { config.environmentVariables.removeValue(forKey: key) }

        if let cwd = options.cwd {
            var isDir = ObjCBool(false)
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
                throw TernError.badRequest("no such folder: \(cwd)")
            }
            config.workingDirectory = cwd
        } else if config.workingDirectory == nil, let pwd = source?.pwd {
            config.workingDirectory = pwd
        }
        if let command = options.command {
            config.command = loginShellCommand(command)
        }
        if let input = options.input, !input.isEmpty {
            config.initialInput = input
        }
        for (key, value) in options.env { config.environmentVariables[key] = value }
        return config
    }

    /// Run a command through the user's login shell, so it sees the PATH and environment
    /// a fresh terminal would (the app's own environment is minimal when it is launched
    /// from the Dock or Finder).
    static func loginShellCommand(_ command: String) -> String {
        var shell = "/bin/zsh"
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_shell {
            let candidate = String(cString: path)
            if FileManager.default.isExecutableFile(atPath: candidate) { shell = candidate }
        }
        func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        return "\(quote(shell)) -l -i -c \(quote(command))"
    }

    static func direction(_ raw: String?) throws -> SplitTree<Ghostty.SurfaceView>.NewDirection {
        switch (raw ?? "right").lowercased() {
        case "right", "r": return .right
        case "left", "l": return .left
        case "down", "d", "below": return .down
        case "up", "u", "above": return .up
        default: throw TernError.badRequest("unknown direction \"\(raw ?? "")\" (use right, left, down or up)")
        }
    }

    /// Remember things about a new pane that the CLI reports before its shell does.
    private static func registerNewPane(_ view: Ghostty.SurfaceView, options: PaneOptions, config: Ghostty.SurfaceConfiguration) {
        TernState.shared.setStartFolder(view.id, config.workingDirectory)
        if let name = options.name { TernState.shared.setPaneName(view.id, name) }
    }

    static func created(_ pane: Ghostty.SurfaceView, tab: TernTab, window: TerminalController) -> [String: Any] {
        ["pane": pane.ternID, "tab": tab.idString, "window": window.ternIDString]
    }

    // MARK: Creation

    static func newWindow(_ options: PaneOptions, tabName: String?, focus: Bool,
                          inheritFrom: Ghostty.SurfaceView? = nil) throws -> [String: Any] {
        let ghostty = try requireGhostty()
        let source = inheritFrom ?? TernTopology.currentPane
        let config = try surfaceConfig(options, inheritingFrom: source, context: GHOSTTY_SURFACE_CONTEXT_WINDOW)
        let controller = TerminalController.newWindow(ghostty, withBaseConfig: config, focus: focus)
        // The window the user is in now, even before AppKit makes it key (the app may be in
        // the background while it comes forward).
        if focus { TernTopology.windowBecameCurrent(controller) }
        let tab = controller.selectedTab
        guard let pane = tab.effectiveFocusedSurface else { throw TernError.failed("the new window has no pane") }
        registerNewPane(pane, options: options, config: config)
        if let tabName {
            tab.name = tabName
            controller.windowName = tabName
        }
        TernEvents.shared.emit("pane.created", ["pane": pane.ternID, "tab": tab.idString, "window": controller.ternIDString])
        return created(pane, tab: tab, window: controller)
    }

    static func newTab(in window: TerminalController, options: PaneOptions, tabName: String?,
                       color: TerminalTabColor, index: Int?, focus: Bool,
                       inheritFrom source: Ghostty.SurfaceView?) throws -> [String: Any] {
        _ = try requireGhostty()
        let config = try surfaceConfig(options, inheritingFrom: source ?? window.selectedTab.effectiveFocusedSurface,
                                       context: GHOSTTY_SURFACE_CONTEXT_TAB)
        let position = index.map { $0 - 1 }
        // An explicit index is a placement: selecting the new tab doesn't move it to the top (S-7).
        let add = { window.addTab(config: config, at: position, select: focus, focus: focus, name: tabName, color: color) }
        guard let (tab, pane) = position == nil ? add() : TernTabOrder.hold(add) else {
            throw TernError.failed("couldn't create the tab")
        }
        registerNewPane(pane, options: options, config: config)
        if focus { TernTopology.windowBecameCurrent(window) }
        return created(pane, tab: tab, window: window)
    }

    static func split(_ target: Ghostty.SurfaceView, direction: SplitTree<Ghostty.SurfaceView>.NewDirection,
                      options: PaneOptions, ratio: Double?, focus: Bool) throws -> [String: Any] {
        let ghostty = try requireGhostty()
        guard let location = TernTopology.locate(target) else { throw TernError.notFound("the pane isn't in a window") }
        guard let app = ghostty.app else { throw TernError.failed("the terminal engine isn't ready") }
        let config = try surfaceConfig(options, inheritingFrom: target, context: GHOSTTY_SURFACE_CONTEXT_SPLIT)
        let window = location.window
        let tab = location.tab
        let view = Ghostty.SurfaceView(app, baseConfig: config)
        registerNewPane(view, options: options, config: config)

        let oldTree = window.tree(of: tab)
        var newTree = try oldTree.inserting(view: view, at: target, direction: direction)
        if let ratio, ratio > 0, ratio < 1 {
            newTree = resized(newTree, containing: view, ratio: ratio)
        }
        // Splitting unzooms, like Ghostty.
        newTree = SplitTree(root: newTree.root, zoomed: nil)

        if tab !== window.selectedTab {
            // Start at the size it will have, so its program sees the right columns/rows.
            let bounds = window.surfaceTree.viewBounds()
            if bounds.width > 0 {
                view.frame = CGRect(origin: .zero, size: CGSize(width: bounds.width / 2, height: bounds.height))
                view.sizeDidChange(view.frame.size)
            }
        }
        // Undo holds the new pane for the undo interval, so Redo can bring it back.
        window.replaceTree(newTree, for: tab, undoAction: "New Split")
        if focus {
            focusPane(view, activate: true)
        }
        TernEvents.shared.emit("pane.created", ["pane": view.ternID, "tab": tab.idString, "window": window.ternIDString])
        return created(view, tab: tab, window: window)
    }

    /// Set the ratio of the split that directly contains `view` so that `view` gets
    /// `ratio` of the space.
    static func resized(_ tree: SplitTree<Ghostty.SurfaceView>, containing view: Ghostty.SurfaceView, ratio: Double) -> SplitTree<Ghostty.SurfaceView> {
        guard let root = tree.root,
              let path = root.path(to: .leaf(view: view)),
              !path.path.isEmpty else { return tree }
        let parentPath = SplitTree<Ghostty.SurfaceView>.Path(path: Array(path.path.dropLast()))
        guard let parent = root.node(at: parentPath), case .split(let split) = parent else { return tree }
        let viewIsLeft = path.path.last == .left
        let resizedNode = SplitTree<Ghostty.SurfaceView>.Node.split(.init(
            direction: split.direction,
            ratio: viewIsLeft ? ratio : 1 - ratio,
            left: split.left,
            right: split.right))
        return (try? tree.replacing(node: parent, with: resizedNode)) ?? tree
    }

    // MARK: Focus

    /// Show a pane's tab and give the pane keyboard focus, bringing its window forward.
    static func focusPane(_ pane: Ghostty.SurfaceView, activate: Bool) {
        guard let location = TernTopology.locate(pane) else { return }
        let window = location.window
        // A zoomed tab shows only its zoomed pane: focusing another one unzooms, so the
        // focused pane is the one on screen.
        let tree = window.tree(of: location.tab)
        if let zoomed = tree.zoomed, zoomed != tree.root?.node(view: pane) {
            window.setTree(SplitTree(root: tree.root, zoomed: nil), for: location.tab)
        }
        window.selectTab(location.tab, focus: false)
        location.tab.focusedSurface = pane
        if window.surfaceTree.contains(pane) { window.focusedSurface = pane }
        TernTopology.windowBecameCurrent(window)
        TernFocusHistory.focused(pane)
        window.window?.makeKeyAndOrderFront(nil)
        if activate && !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        moveFocus(to: pane, in: window)
        TernEvents.shared.emit("pane.focused", ["pane": pane.ternID, "tab": location.tab.idString, "window": window.ternIDString])
        TernState.shared.layoutDidChange()
    }

    static func focusTab(_ tab: TernTab, in window: TerminalController) {
        window.selectTab(tab, focus: true)
        TernTopology.windowBecameCurrent(window)
        window.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let pane = tab.effectiveFocusedSurface {
            TernFocusHistory.focused(pane)
            moveFocus(to: pane, in: window)
        }
    }

    /// Give a pane keyboard focus once its view is in the window, unless the window was asked
    /// to focus something else meanwhile. (Ghostty's own retry would still focus a pane whose
    /// tab was shown, hidden and shown again in quick succession, after a later request.)
    static func moveFocus(to pane: Ghostty.SurfaceView, in window: TerminalController, attempt: Int = 0) {
        let delay = attempt == 0 ? 0 : 0.05 * Double(1 << (attempt - 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard window.focusedSurface === pane || window.selectedTab.focusedSurface === pane,
                  window.surfaceTree.contains(pane) else { return }
            guard let host = pane.window else {
                if attempt < 5 { moveFocus(to: pane, in: window, attempt: attempt + 1) }
                return
            }
            host.makeFirstResponder(pane)
        }
    }

    static func focusWindow(_ window: TerminalController) {
        TernTopology.windowBecameCurrent(window)
        window.window?.makeKeyAndOrderFront(nil)
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if let pane = window.selectedTab.effectiveFocusedSurface {
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
    }

    // MARK: Closing

    static func closePane(_ pane: Ghostty.SurfaceView) throws {
        guard let location = TernTopology.locate(pane) else { throw TernError.notFound("the pane isn't in a window") }
        let window = location.window
        let tab = location.tab
        let tree = window.tree(of: tab)
        guard let node = tree.root?.node(view: pane) else { throw TernError.notFound("the pane isn't in its tab") }
        TernEvents.shared.emit("pane.closed", ["pane": pane.ternID, "tab": tab.idString, "window": window.ternIDString])
        if tab === window.selectedTab {
            // The base controller's close keeps Ghostty's undo of closed panes.
            window.closeSurface(node, withConfirmation: false)
            return
        }
        // Undo keeps the closed pane alive for the undo interval, as for a visible pane.
        window.closeHiddenNode(node, in: tab)
    }

    // MARK: Zoom, resize, swap, equalize

    static func toggleZoom(_ pane: Ghostty.SurfaceView) throws {
        guard let location = TernTopology.locate(pane) else { throw TernError.notFound("the pane isn't in a window") }
        let tree = location.window.tree(of: location.tab)
        guard let node = tree.root?.node(view: pane) else { throw TernError.notFound("the pane isn't in its tab") }
        let newTree: SplitTree<Ghostty.SurfaceView>
        if tree.zoomed == node {
            newTree = SplitTree(root: tree.root, zoomed: nil)
        } else {
            guard tree.isSplit else { throw TernError.badRequest("there's nothing to zoom: the pane is alone in its tab") }
            newTree = SplitTree(root: tree.root, zoomed: node)
        }
        location.window.setTree(newTree, for: location.tab)
        TernEvents.shared.emit("pane.zoomed", ["pane": pane.ternID, "zoomed": newTree.zoomed != nil])
    }

    static func resize(_ pane: Ghostty.SurfaceView, direction: String, amount: Int) throws {
        guard let location = TernTopology.locate(pane) else { throw TernError.notFound("the pane isn't in a window") }
        let tree = location.window.tree(of: location.tab)
        guard let node = tree.root?.node(view: pane) else { throw TernError.notFound("the pane isn't in its tab") }
        let spatial: SplitTree<Ghostty.SurfaceView>.Spatial.Direction
        switch direction {
        case "up": spatial = .up
        case "down": spatial = .down
        case "left": spatial = .left
        case "right": spatial = .right
        default: throw TernError.badRequest("unknown direction \"\(direction)\" (use up, down, left or right)")
        }
        guard tree.isSplit else { throw TernError.badRequest("the pane is alone in its tab; there's nothing to resize") }
        // Amount is in cells; convert with the pane's cell size.
        var cell = CGSize(width: 8, height: 16)
        if let surface = pane.surface {
            let size = ghostty_surface_size(surface)
            let scale = pane.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            if size.cell_width_px > 0 { cell = CGSize(width: CGFloat(size.cell_width_px) / scale,
                                                      height: CGFloat(size.cell_height_px) / scale) }
        }
        let pixels = (direction == "left" || direction == "right") ? CGFloat(amount) * cell.width : CGFloat(amount) * cell.height
        let bounds = CGRect(origin: .zero, size: tree.viewBounds())
        do {
            let newTree = try tree.resizing(node: node, by: UInt16(min(max(pixels, 1), 4000)), in: spatial, with: bounds)
            location.window.setTree(newTree, for: location.tab)
        } catch {
            throw TernError.failed("couldn't resize the pane: \(error)")
        }
        TernEvents.shared.emit("pane.resized", ["pane": pane.ternID])
    }

    /// Swap two panes' places (in the same tab or across tabs and windows).
    static func swap(_ a: Ghostty.SurfaceView, _ b: Ghostty.SurfaceView) throws {
        guard a !== b else { throw TernError.badRequest("can't swap a pane with itself") }
        guard let la = TernTopology.locate(a), let lb = TernTopology.locate(b) else {
            throw TernError.notFound("both panes must be in windows")
        }
        undoable("Swap Panes", windows: [la.window, lb.window]) {
            func swapped(_ node: SplitTree<Ghostty.SurfaceView>.Node) -> SplitTree<Ghostty.SurfaceView>.Node {
                switch node {
                case .leaf(let view):
                    if view === a { return .leaf(view: b) }
                    if view === b { return .leaf(view: a) }
                    return node
                case .split(let split):
                    return .split(.init(direction: split.direction, ratio: split.ratio,
                                        left: swapped(split.left), right: swapped(split.right)))
                }
            }
            let ta = la.window.tree(of: la.tab)
            if let root = ta.root {
                la.window.setTree(SplitTree(root: swapped(root), zoomed: nil), for: la.tab)
            }
            if lb.tab !== la.tab {
                let tb = lb.window.tree(of: lb.tab)
                if let root = tb.root {
                    lb.window.setTree(SplitTree(root: swapped(root), zoomed: nil), for: lb.tab)
                }
            }
        }
        TernEvents.shared.emit("pane.swapped", ["pane": a.ternID, "target": b.ternID])
    }

    static func equalize(_ tab: TernTab, in window: TerminalController) {
        window.setTree(window.tree(of: tab).equalized(), for: tab)
    }

    // MARK: Moving panes

    enum PaneDestination {
        /// Next to another pane (in any tab or window).
        case besidePane(Ghostty.SurfaceView, SplitTree<Ghostty.SurfaceView>.NewDirection)
        /// A new tab in a window.
        case newTab(TerminalController, index: Int?)
        /// A new window.
        case newWindow
    }

    /// Move a live pane (its program and scrollback) somewhere else. The source tab (and
    /// window) closes if it becomes empty. Returns where the pane ended up.
    @discardableResult
    static func move(_ pane: Ghostty.SurfaceView, to destination: PaneDestination, focus: Bool) throws -> TernTopology.Location {
        guard let source = TernTopology.locate(pane) else { throw TernError.notFound("the pane isn't in a window") }
        if case .besidePane(let target, _) = destination, target === pane {
            throw TernError.badRequest("can't move a pane next to itself")
        }
        var involved: [TerminalController] = [source.window]
        switch destination {
        case .besidePane(let target, _):
            guard let t = TernTopology.locate(target) else { throw TernError.notFound("the target pane isn't in a window") }
            involved.append(t.window)
        case .newTab(let window, _):
            involved.append(window)
        case .newWindow:
            break
        }

        // Keep its size when it gets a window of its own (M-5).
        let size = pane.bounds.size
        var result: TernTopology.Location?
        try undoable("Move Pane", windows: involved) {
            result = try moveUngrouped(pane, from: source, to: destination, focus: focus, size: size)
        }
        guard let result else { throw TernError.failed("the move didn't happen") }
        TernEvents.shared.emit("pane.moved", [
            "pane": pane.ternID,
            "from_tab": source.tab.idString, "from_window": source.window.ternIDString,
            "tab": result.tab.idString, "window": result.window.ternIDString,
        ])
        return result
    }

    private static func moveUngrouped(_ pane: Ghostty.SurfaceView, from source: TernTopology.Location,
                                      to destination: PaneDestination, focus: Bool, size: CGSize) throws -> TernTopology.Location {
        let ghostty = try requireGhostty()
        let sourceTree = source.window.tree(of: source.tab)
        guard let node = sourceTree.root?.node(view: pane) else { throw TernError.notFound("the pane isn't in its tab") }

        // Work out the destination before changing anything, so a failure changes nothing.
        // The pane goes into its destination first and leaves its source second, so a window
        // that is both (its only pane moving to a new tab) is never left empty and closed.
        switch destination {
        case .besidePane(let target, let direction):
            guard let dest = TernTopology.locate(target) else { throw TernError.notFound("the target pane isn't in a window") }
            if dest.tab === source.tab {
                let without = sourceTree.removing(node)
                let newTree = try without.inserting(view: pane, at: target, direction: direction)
                source.window.setTree(SplitTree(root: newTree.root, zoomed: nil), for: source.tab)
            } else {
                let destTree = dest.window.tree(of: dest.tab)
                let newDestTree = try destTree.inserting(view: pane, at: target, direction: direction)
                dest.window.setTree(SplitTree(root: newDestTree.root, zoomed: nil), for: dest.tab)
                removeFromSource(pane, node: node, source: source, adoptingInto: dest.tab)
            }
            if focus { focusPane(pane, activate: true) }
            return TernTopology.Location(window: dest.window, tab: dest.tab, pane: pane)

        case .newTab(let window, let index):
            let tab = TernTab(tree: .init(view: pane))
            let position = index ?? ((window.index(of: source.tab).map { $0 + 1 }) ?? window.tabs.count)
            window.insertTab(tab, at: position)
            removeFromSource(pane, node: node, source: source, adoptingInto: tab)
            if focus {
                focusPane(pane, activate: true)
            }
            TernEvents.shared.emit("tab.created", ["tab": tab.idString, "window": window.ternIDString])
            return TernTopology.Location(window: window, tab: tab, pane: pane)

        case .newWindow:
            let tab = TernTab(tree: .init(view: pane))
            removeFromSource(pane, node: node, source: source, adoptingInto: tab)
            if size.width > 0, size.height > 0 { pane.frame.size = size }
            let controller = TerminalController.newWindow(
                ghostty, tabs: [tab], selected: tab,
                inheritBackgroundOpacity: source.window.isBackgroundOpaque,
                focus: focus, registerUndo: false)
            return TernTopology.Location(window: controller, tab: tab, pane: pane)
        }
    }

    /// Take a pane out of its tab. A tab left empty closes (and a window left without tabs);
    /// its editor documents go with the pane to `adoptingInto`, so no edit is dropped.
    private static func removeFromSource(_ pane: Ghostty.SurfaceView, node: SplitTree<Ghostty.SurfaceView>.Node,
                                         source: TernTopology.Location, adoptingInto destination: TernTab) {
        let newTree = source.window.tree(of: source.tab).removing(node)
        if newTree.isEmpty {
            destination.editor.adopt(from: source.tab.editor)
            source.window.detachTab(source.tab, focusNeighbor: false)
            TernEvents.shared.emit("tab.closed", ["tab": source.tab.idString, "window": source.window.ternIDString])
        } else {
            source.window.setTree(SplitTree(root: newTree.root, zoomed: nil), for: source.tab)
        }
    }

    // MARK: Moving tabs

    /// Move a tab within its window or to another (or a new) window. `index` is 1-based
    /// and clamped into the tab's pin group.
    static func move(tab: TernTab, from source: TerminalController, toWindow target: TerminalController?,
                     index: Int?, newWindow: Bool, focus: Bool) throws -> TerminalController {
        let ghostty = try requireGhostty()
        var involved: [TerminalController] = [source]
        if let target, target !== source { involved.append(target) }
        var result = source
        // A placement: selecting the moved tab doesn't move it to the top (S-7).
        TernTabOrder.hold { undoable("Move Tab", windows: involved) {
            if newWindow {
                let frame = source.window?.frame
                source.detachTab(tab, focusNeighbor: false)
                result = TerminalController.newWindow(
                    ghostty, tabs: [tab], selected: tab,
                    frame: frame.map { NSRect(origin: CGPoint(x: $0.minX + 30, y: $0.minY - 30), size: $0.size) },
                    focus: focus, registerUndo: false)
            } else if let target, target !== source {
                source.detachTab(tab, focusNeighbor: false)
                target.insertTab(tab, at: index.map { $0 - 1 })
                if focus { focusTab(tab, in: target) }
                result = target
            } else {
                source.moveTab(tab, to: (index ?? source.tabs.count) - 1)
                if focus { focusTab(tab, in: source) }
            }
        } }
        TernEvents.shared.emit("tab.moved", ["tab": tab.idString, "from_window": source.ternIDString, "window": result.ternIDString])
        return result
    }

    // MARK: Undo

    /// Run a layout change as one undoable step. Undo puts every involved window back the
    /// way it was (tabs, trees, selection, focus); redo puts the result back. Snapshots hold
    /// panes weakly, so undo never keeps a closed pane's process alive.
    @discardableResult
    static func undoable<T>(_ name: String, windows: [TerminalController], _ body: () throws -> T) rethrows -> T {
        let before = TernSnapshot(windows)
        let existing = Set(TerminalController.all.map(ObjectIdentifier.init))
        let result = try body()
        let created = TerminalController.all.filter { !existing.contains(ObjectIdentifier($0)) }
        let after = TernSnapshot(windows + created)
        guard let undoManager = (NSApp.delegate as? AppDelegate)?.undoManager,
              undoManager.isUndoRegistrationEnabled else { return result }
        registerUndo(name, undoManager: undoManager, restore: before, redo: after)
        return result
    }

    /// Long enough for people to change their minds; moves don't hold processes alive.
    static let moveUndoExpiration: Duration = .seconds(600)

    private static func registerUndo(_ name: String, undoManager: ExpiringUndoManager,
                                     restore: TernSnapshot, redo: TernSnapshot) {
        undoManager.registerUndo(withTarget: TernSnapshotTarget.shared, expiresAfter: moveUndoExpiration) { _ in
            restore.apply(closing: redo)
            registerUndo(name, undoManager: undoManager, restore: redo, redo: restore)
        }
        undoManager.setActionName(name)
    }
}

@MainActor
final class TernSnapshotTarget: NSObject {
    static let shared = TernSnapshotTarget()
}

/// The layout of some windows at one moment, with panes held weakly.
@MainActor
struct TernSnapshot {
    final class WindowBox {
        weak var controller: TerminalController?
        init(_ controller: TerminalController) { self.controller = controller }
    }

    indirect enum WeakNode {
        case leaf(Weak<Ghostty.SurfaceView>)
        case split(SplitTree<Ghostty.SurfaceView>.Direction, Double, WeakNode, WeakNode)

        init(_ node: SplitTree<Ghostty.SurfaceView>.Node) {
            switch node {
            case .leaf(let view): self = .leaf(Weak(view))
            case .split(let split): self = .split(split.direction, split.ratio, WeakNode(split.left), WeakNode(split.right))
            }
        }

        /// The node with closed panes left out (a split with one side gone collapses).
        func resolve() -> SplitTree<Ghostty.SurfaceView>.Node? {
            switch self {
            case .leaf(let weak):
                guard let view = weak.value, TernSnapshot.isAlive(view) else { return nil }
                return .leaf(view: view)
            case .split(let direction, let ratio, let left, let right):
                let l = left.resolve()
                let r = right.resolve()
                switch (l, r) {
                case let (l?, r?): return .split(.init(direction: direction, ratio: ratio, left: l, right: r))
                case let (l?, nil): return l
                case let (nil, r?): return r
                default: return nil
                }
            }
        }
    }

    struct TabState {
        let tab: Weak<TernTab>
        let id: UUID
        let name: String?
        let color: TerminalTabColor
        let pinned: Bool
        let tree: WeakNode?
        let zoomed: Weak<Ghostty.SurfaceView>?
        let focused: Weak<Ghostty.SurfaceView>?
    }

    struct WindowState {
        let box: WindowBox
        let tabs: [TabState]
        let selected: UUID
        let frame: NSRect?
        let focusedPane: Weak<Ghostty.SurfaceView>?
    }

    let windows: [WindowState]

    init(_ controllers: [TerminalController]) {
        var seen = Set<ObjectIdentifier>()
        var states: [WindowState] = []
        for controller in controllers where seen.insert(ObjectIdentifier(controller)).inserted {
            guard !controller.tabs.isEmpty, controller.window != nil else { continue }
            let tabs = controller.tabs.map { tab -> TabState in
                let tree = controller.tree(of: tab)
                var zoomed: Weak<Ghostty.SurfaceView>?
                if let node = tree.zoomed, case .leaf(let view) = node { zoomed = Weak(view) }
                let focused = (tab === controller.selectedTab ? controller.focusedSurface : nil) ?? tab.focusedSurface
                return TabState(tab: Weak(tab), id: tab.id, name: tab.name, color: tab.color, pinned: tab.pinned,
                                tree: tree.root.map(WeakNode.init), zoomed: zoomed, focused: focused.map { Weak($0) })
            }
            states.append(WindowState(box: TernSnapshot.box(for: controller), tabs: tabs, selected: controller.selectedTab.id,
                                      frame: controller.window?.frame,
                                      focusedPane: controller.focusedSurface.map { Weak($0) }))
        }
        windows = states
    }

    /// One box per controller, so a window recreated by undo is found again by redo.
    private static var boxes: [ObjectIdentifier: WindowBox] = [:]
    static func box(for controller: TerminalController) -> WindowBox {
        boxes = boxes.filter { $0.value.controller != nil }
        if let box = boxes[ObjectIdentifier(controller)] { return box }
        let box = WindowBox(controller)
        boxes[ObjectIdentifier(controller)] = box
        return box
    }

    nonisolated static func isAlive(_ view: Ghostty.SurfaceView) -> Bool {
        guard let surface = view.surface else { return false }
        return !ghostty_surface_process_exited(surface)
    }

    /// Put these windows back as they were. Windows of `other` that aren't part of this
    /// snapshot (created by the step being undone) close, without touching their panes,
    /// which have moved back.
    func apply(closing other: TernSnapshot) {
        guard let ghostty = TernLayout.ghostty else { return }
        let mine = Set(windows.map { ObjectIdentifier($0.box) })

        // 1. Resolve what each window should hold (closed panes left out).
        struct TabPlan {
            let state: TabState
            let root: SplitTree<Ghostty.SurfaceView>.Node
        }
        var plans: [(window: WindowState, tabs: [TabPlan])] = []
        var placed = Set<ObjectIdentifier>()
        for state in windows {
            var tabs: [TabPlan] = []
            for tabState in state.tabs {
                guard let root = tabState.tree?.resolve() else { continue }
                for view in root.leaves() { placed.insert(ObjectIdentifier(view)) }
                tabs.append(TabPlan(state: tabState, root: root))
            }
            plans.append((state, tabs))
        }

        // The window each existing tab object belongs in.
        var targetOf: [ObjectIdentifier: WindowBox] = [:]
        for plan in plans {
            for tab in plan.tabs {
                if let object = tab.state.tab.value { targetOf[ObjectIdentifier(object)] = plan.window.box }
            }
        }

        // 2. Once, before restoring anything: take restored tabs out of other windows, and
        //    the panes being placed out of every tab that isn't being restored, so no pane
        //    is ever in two trees and nothing restored is touched again. A tab this empties
        //    leaves its editor documents to the restored tab that gets its panes back.
        var orphans: [(editor: TernEditorGroup, panes: Set<ObjectIdentifier>)] = []
        for controller in TerminalController.all where !controller.isClosed {
            for existing in controller.tabs {
                if let target = targetOf[ObjectIdentifier(existing)] {
                    if target.controller !== controller {
                        controller.detachTab(existing, focusNeighbor: false, keepWindow: true)
                    }
                    continue
                }
                let tree = controller.tree(of: existing)
                var newTree = tree
                for leaf in tree.root?.leaves() ?? [] where placed.contains(ObjectIdentifier(leaf)) {
                    if let node = newTree.root?.node(view: leaf) { newTree = newTree.removing(node) }
                }
                guard newTree.root != tree.root else { continue }
                if newTree.isEmpty {
                    orphans.append((existing.editor, Set((tree.root?.leaves() ?? []).map(ObjectIdentifier.init))))
                    controller.detachTab(existing, focusNeighbor: false, keepWindow: true)
                } else {
                    controller.setTree(newTree, for: existing)
                }
            }
        }

        // 3. Restore each window.
        for plan in plans {
            let state = plan.window
            var tabs: [TernTab] = []
            for tabPlan in plan.tabs {
                let tabState = tabPlan.state
                let tab = tabState.tab.value ?? TernTab(id: tabState.id, tree: .init())
                tab.name = tabState.name
                tab.color = tabState.color
                tab.pinned = tabState.pinned
                var zoomedNode: SplitTree<Ghostty.SurfaceView>.Node?
                if let z = tabState.zoomed?.value, let node = tabPlan.root.node(view: z) { zoomedNode = node }
                tab.tree = SplitTree(root: tabPlan.root, zoomed: zoomedNode)
                if let f = tabState.focused?.value, tab.tree.contains(f) { tab.focusedSurface = f }
                let leaves = Set(tabPlan.root.leaves().map(ObjectIdentifier.init))
                for orphan in orphans where !orphan.panes.isDisjoint(with: leaves) {
                    tab.editor.adopt(from: orphan.editor)
                }
                tabs.append(tab)
            }
            let live = state.box.controller.flatMap { c in
                !c.isClosed && (c.window?.isVisible ?? false || c.presentsWithoutFocus) ? c : nil
            }
            // Tabs the window has now that the snapshot doesn't know about (and that still
            // hold panes) stay, after the restored ones: nothing live is ever dropped.
            if let live {
                for existing in live.tabs where !tabs.contains(where: { $0 === existing }) && !live.tree(of: existing).isEmpty {
                    if existing === live.selectedTab { existing.tree = live.surfaceTree }
                    tabs.append(existing)
                }
            }
            guard !tabs.isEmpty else {
                live?.closeWindowWithoutConfirmation()
                continue
            }
            let selected = tabs.first { $0.id == state.selected } ?? tabs[0]
            if let live {
                live.restoreTabs(tabs, selected: selected, focusedPane: state.focusedPane?.value)
            } else {
                let controller = TerminalController.newWindow(
                    ghostty, tabs: tabs, selected: selected, frame: state.frame, focus: false, registerUndo: false)
                state.box.controller = controller
                TernSnapshot.boxes[ObjectIdentifier(controller)] = state.box
            }
        }

        // Documents no restored tab took are saved, or kept as a recovery copy.
        for orphan in orphans {
            for doc in orphan.editor.documents { doc.preserveEdits() }
        }

        // 4. Windows the undone step created, now holding only panes that moved back, and
        //    windows emptied by the restore, close.
        for state in other.windows where !mine.contains(ObjectIdentifier(state.box)) {
            guard let controller = state.box.controller, !controller.isClosed else { continue }
            if controller.allSurfaces.allSatisfy({ placed.contains(ObjectIdentifier($0)) }) {
                controller.closeWindowWithoutConfirmation()
            }
        }
        for controller in TerminalController.all where controller.tabs.isEmpty && !controller.isClosed {
            controller.closeWindowWithoutConfirmation()
        }

        // Focus as it was, in the window that has it.
        for plan in plans {
            guard let controller = plan.window.box.controller, controller.window?.isKeyWindow ?? false,
                  let pane = controller.focusedSurface else { continue }
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
        TernState.shared.layoutDidChange()
        TernEvents.shared.emit("layout.restored", [:])
    }
}

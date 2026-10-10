import AppKit
import GhosttyKit

/// Windows, tabs and panes as the CLI sees them: ids, selectors (L-4) and JSON (L-7).
@MainActor
enum TernTopology {
    // MARK: Windows

    /// The window commands default to outside Tern's terminals: the last one the user (or
    /// the CLI) focused. AppKit has no key window while the app is in the background, so
    /// Tern remembers it.
    private static weak var current: TerminalController?

    static func windowBecameCurrent(_ controller: TerminalController) {
        guard current !== controller else { return }
        current = controller
        TernState.shared.layoutDidChange()
    }

    static func windowClosed(_ controller: TerminalController) {
        if current === controller { current = nil }
    }

    /// Open Tern windows, oldest first (their `#N` order).
    static var windows: [TerminalController] {
        TerminalController.all
            .filter { !$0.isClosed && !$0.tabs.isEmpty && $0.window != nil }
            .filter { $0.window?.isVisible ?? false || $0.window?.isMiniaturized ?? false || $0.presentsWithoutFocus }
            .sorted { $0.createdAt < $1.createdAt }
    }

    static var currentWindow: TerminalController? {
        if let current, windows.contains(where: { $0 === current }) { return current }
        if let key = NSApp.keyWindow?.windowController as? TerminalController, !key.tabs.isEmpty { return key }
        if let main = NSApp.mainWindow?.windowController as? TerminalController, !main.tabs.isEmpty { return main }
        return windows.last
    }

    static var currentTab: TernTab? { currentWindow?.selectedTab }

    static var currentPane: Ghostty.SurfaceView? {
        guard let window = currentWindow else { return nil }
        if let focused = window.focusedSurface, window.surfaceTree.contains(focused) { return focused }
        return window.selectedTab.effectiveFocusedSurface
    }

    static func windowNumber(_ controller: TerminalController) -> Int {
        (windows.firstIndex { $0 === controller } ?? 0) + 1
    }

    // MARK: Panes

    static var allSurfaces: [Ghostty.SurfaceView] { windows.flatMap(\.allSurfaces) }

    struct Location {
        let window: TerminalController
        let tab: TernTab
        let pane: Ghostty.SurfaceView
    }

    static func locate(_ pane: Ghostty.SurfaceView) -> Location? {
        for window in windows {
            if let tab = window.tab(containing: pane) {
                return Location(window: window, tab: tab, pane: pane)
            }
        }
        return nil
    }

    static func locate(tab: TernTab) -> TerminalController? {
        windows.first { $0.tabs.contains { $0 === tab } }
    }

    static func panes(of tab: TernTab, in window: TerminalController) -> [Ghostty.SurfaceView] {
        window.tree(of: tab).root?.leaves() ?? []
    }

    /// The pane's folder: what its shell reports (shell integration), else the folder of
    /// the program in its foreground, else where it was told to start.
    static func cwd(of pane: Ghostty.SurfaceView) -> String {
        if let pwd = pane.pwd, !pwd.isEmpty { return pwd }
        if let surface = pane.surface,
           let folder = TernProcess.cwd(pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))) {
            return folder
        }
        return TernState.shared.startFolder(pane.id) ?? ""
    }

    // MARK: Selectors

    /// The pane a request is about: the given selector, else the caller's own pane (inside
    /// Tern's terminals), else the focused one.
    static func pane(_ selector: String?, caller: TernCaller) throws -> Ghostty.SurfaceView {
        if let selector, !selector.isEmpty {
            return try resolvePane(selector, caller: caller)
        }
        if let callerPane = try callerPane(caller) { return callerPane }
        guard let pane = currentPane else { throw TernError.notFound("there are no panes (no Tern windows are open)") }
        return pane
    }

    static func tab(_ selector: String?, caller: TernCaller, window: TerminalController? = nil) throws -> (TerminalController, TernTab) {
        if let selector, !selector.isEmpty {
            return try resolveTab(selector, caller: caller, window: window)
        }
        if let window { return (window, window.selectedTab) }
        if let callerPane = try callerPane(caller), let location = locate(callerPane) {
            return (location.window, location.tab)
        }
        guard let window = currentWindow else { throw TernError.notFound("there are no tabs (no Tern windows are open)") }
        return (window, window.selectedTab)
    }

    static func window(_ selector: String?, caller: TernCaller) throws -> TerminalController {
        if let selector, !selector.isEmpty {
            return try resolveWindow(selector, caller: caller)
        }
        if let callerPane = try callerPane(caller), let location = locate(callerPane) {
            return location.window
        }
        guard let window = currentWindow else { throw TernError.notFound("there are no Tern windows open") }
        return window
    }

    /// The caller's own pane, if the CLI runs inside one of this instance's terminals.
    /// A pane id from an earlier run of this instance (a terminal that outlived it) is an
    /// error, never a fallback to another pane (R-7).
    static func callerPane(_ caller: TernCaller) throws -> Ghostty.SurfaceView? {
        guard let id = caller.pane else { return nil }
        if caller.isStale {
            throw TernError.notFound("this terminal's pane (\(id.prefix(8))) belongs to an earlier run of \(TernPaths.productName); pass --pane, --tab or --window")
        }
        guard let pane = allSurfaces.first(where: { $0.ternID == id.lowercased() }) else {
            throw TernError.notFound("this terminal's pane (\(id.prefix(8))) no longer exists; pass --pane, --tab or --window")
        }
        return pane
    }

    static func resolvePane(_ selector: String, caller: TernCaller) throws -> Ghostty.SurfaceView {
        if selector == "." {
            guard let pane = currentPane else { throw TernError.notFound("there is no focused pane") }
            return pane
        }
        let all = allSurfaces
        return try pick(selector, kind: "pane", candidates: all,
                        id: { $0.ternID }, name: { TernState.shared.paneName($0.id) })
    }

    static func resolveTab(_ selector: String, caller: TernCaller, window: TerminalController? = nil) throws -> (TerminalController, TernTab) {
        if selector == "." {
            guard let window = window ?? currentWindow else { throw TernError.notFound("there is no focused tab") }
            return (window, window.selectedTab)
        }
        if selector.hasPrefix("#") {
            guard let n = Int(selector.dropFirst()), n >= 1 else {
                throw TernError.badRequest("bad tab index \(selector) (use #1, #2, …)")
            }
            let base: TerminalController
            if let window {
                base = window
            } else if let callerPane = try callerPane(caller), let location = locate(callerPane) {
                base = location.window
            } else if let current = currentWindow {
                base = current
            } else {
                throw TernError.notFound("there are no tabs")
            }
            guard n <= base.tabs.count else {
                throw TernError.notFound("no tab \(selector) (window #\(windowNumber(base)) has \(base.tabs.count))")
            }
            return (base, base.tabs[n - 1])
        }
        let pairs = (window.map { [$0] } ?? windows).flatMap { w in w.tabs.map { (w, $0) } }
        let found = try pick(selector, kind: "tab", candidates: pairs,
                             id: { $0.1.idString }, name: { $0.1.name })
        return found
    }

    static func resolveWindow(_ selector: String, caller: TernCaller) throws -> TerminalController {
        if selector == "." {
            guard let window = currentWindow else { throw TernError.notFound("there is no focused window") }
            return window
        }
        let all = windows
        if selector.hasPrefix("#") {
            guard let n = Int(selector.dropFirst()), n >= 1 else {
                throw TernError.badRequest("bad window index \(selector) (use #1, #2, …)")
            }
            guard n <= all.count else {
                throw TernError.notFound("no window \(selector) (there \(all.count == 1 ? "is 1 window" : "are \(all.count) windows"))")
            }
            return all[n - 1]
        }
        return try pick(selector, kind: "window", candidates: all,
                        id: { $0.ternIDString }, name: { $0.windowName })
    }

    /// Resolve a selector among candidates: an exact id, then an exact name, then a unique
    /// id prefix. Ambiguity is an error, never a guess.
    private static func pick<T>(
        _ selector: String,
        kind: String,
        candidates: [T],
        id: (T) -> String,
        name: (T) -> String?
    ) throws -> T {
        let lowered = selector.lowercased()
        if let exact = candidates.first(where: { id($0) == lowered }) { return exact }
        let named = candidates.filter { name($0) == selector }
        if named.count == 1 { return named[0] }
        if named.count > 1 {
            throw TernError.ambiguous("\(named.count) \(kind)s are named \"\(selector)\"; use an id")
        }
        let isHex = lowered.allSatisfy { $0.isHexDigit || $0 == "-" }
        if isHex, lowered.count >= 1 {
            let prefixed = candidates.filter { id($0).hasPrefix(lowered) }
            if prefixed.count == 1 { return prefixed[0] }
            if prefixed.count > 1 {
                throw TernError.ambiguous("\"\(selector)\" matches \(prefixed.count) \(kind)s; use more of the id")
            }
        }
        throw TernError.notFound("no \(kind) matches \"\(selector)\"")
    }

    // MARK: JSON

    static func treeJSON() -> [String: Any] {
        var result: [String: Any] = ["windows": windows.map(windowJSON)]
        if let window = currentWindow {
            result["current_window"] = window.ternIDString
            result["current_tab"] = window.selectedTab.idString
        }
        if let pane = currentPane { result["current_pane"] = pane.ternID }
        return result
    }

    static func windowJSON(_ window: TerminalController) -> [String: Any] {
        [
            "id": window.ternIDString,
            "index": windowNumber(window),
            "selected_tab": window.selectedTab.idString,
            "focused": window === currentWindow,
            "tabs": window.tabs.enumerated().map { tabJSON($0.element, index: $0.offset + 1, in: window) },
        ]
    }

    static func tabJSON(_ tab: TernTab, index: Int, in window: TerminalController) -> [String: Any] {
        let panes = panes(of: tab, in: window)
        let focused = (tab === window.selectedTab ? window.focusedSurface : nil)
            .flatMap { panes.contains($0) ? $0 : nil } ?? tab.effectiveFocusedSurface
        let tree = window.tree(of: tab)
        var json: [String: Any] = [
            "id": tab.idString,
            "index": index,
            "title": tab.title,
            "selected": tab === window.selectedTab,
            "pinned": tab.pinned,
            "focused_pane": focused?.ternID ?? "",
            "window": window.ternIDString,
        ]
        // Zoom is per tab: mark the zoomed pane.
        var zoomedPane: Ghostty.SurfaceView?
        if let zoomed = tree.zoomed, case .leaf(let view) = zoomed { zoomedPane = view }
        let frames = paneFrames(tree, in: window)
        json["panes"] = panes.map { pane in
            var paneJSON = paneJSON(pane, focused: pane === focused, zoomed: pane === zoomedPane)
            if let frame = frames[ObjectIdentifier(pane)] { paneJSON["frame"] = frameJSON(frame) }
            return paneJSON
        }
        if let zoomedPane { json["zoomed_pane"] = zoomedPane.ternID }
        if let name = tab.name, !name.isEmpty { json["name"] = name }
        if tab.color != .none { json["color"] = TernTopology.colorName(tab.color) }
        return json
    }

    static func paneJSON(_ pane: Ghostty.SurfaceView, focused: Bool, zoomed: Bool) -> [String: Any] {
        var json: [String: Any] = [
            "id": pane.ternID,
            "cwd": cwd(of: pane),
            "focused": focused,
            "zoomed": zoomed,
            "title": pane.title,
        ]
        if let name = TernState.shared.paneName(pane.id) { json["name"] = name }
        if let session = TernAgentUI.shared.session(forPane: pane.id) {
            json["agent"] = session
            json["showing"] = TernAgentUI.shared.showingTerminal.contains(pane.id) ? "terminal" : "agent"
        }
        if let agent = TernState.shared.interactiveAgents[pane.id] {
            var info: [String: Any] = ["kind": agent.kind, "running": agent.running, "command": agent.commandLine]
            if let code = agent.exitCode { info["exit_code"] = code }
            json["interactive_agent"] = info
        }
        return json
    }

    /// Where each pane of a tab sits in the window's terminal area (points, top-left origin),
    /// from the split ratios: what the tab shows, or will show when selected. Zoom aside.
    static func paneFrames(_ tree: SplitTree<Ghostty.SurfaceView>, in window: TerminalController) -> [ObjectIdentifier: CGRect] {
        var size = window.terminalAreaSize
        if size.width <= 0 || size.height <= 0 { size = window.surfaceTree.viewBounds() }
        if size.width <= 0 || size.height <= 0 { size = tree.viewBounds() }
        guard let root = tree.root else { return [:] }
        var out: [ObjectIdentifier: CGRect] = [:]
        for (view, frame) in root.frames(in: size) { out[ObjectIdentifier(view)] = frame }
        return out
    }

    static func frameJSON(_ frame: CGRect) -> [String: Any] {
        func round(_ v: CGFloat) -> Double { (Double(v) * 10).rounded() / 10 }
        return ["x": round(frame.minX), "y": round(frame.minY), "width": round(frame.width), "height": round(frame.height)]
    }

    /// `pane info`: the pane plus its tab and window.
    static func paneInfoJSON(_ pane: Ghostty.SurfaceView) -> [String: Any] {
        guard let location = locate(pane) else {
            return paneJSON(pane, focused: false, zoomed: false)
        }
        let tree = location.window.tree(of: location.tab)
        var zoomed = false
        if let node = tree.zoomed, case .leaf(let view) = node { zoomed = view === pane }
        let focused = location.tab.effectiveFocusedSurface === pane
        var json = paneJSON(pane, focused: focused, zoomed: zoomed)
        json["tab"] = location.tab.idString
        json["window"] = location.window.ternIDString
        if let frame = paneFrames(tree, in: location.window)[ObjectIdentifier(pane)] { json["frame"] = frameJSON(frame) }
        json["tab_index"] = (location.window.index(of: location.tab) ?? 0) + 1
        json["window_index"] = windowNumber(location.window)
        if let size = pane.surface.map({ ghostty_surface_size($0) }) {
            json["columns"] = Int(size.columns)
            json["rows"] = Int(size.rows)
        }
        return json
    }

    // MARK: Colors

    static func colorName(_ color: TerminalTabColor) -> String {
        switch color {
        case .none: return "none"
        case .blue: return "blue"
        case .purple: return "purple"
        case .pink: return "pink"
        case .red: return "red"
        case .orange: return "orange"
        case .yellow: return "yellow"
        case .green: return "green"
        case .teal: return "teal"
        case .graphite: return "graphite"
        }
    }

    static func color(named name: String) -> TerminalTabColor? {
        TerminalTabColor.allCases.first { colorName($0) == name.lowercased() }
    }
}

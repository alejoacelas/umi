import AppKit
import GhosttyKit

/// What Umi keeps across restarts, all in the state directory (never in AppKit's
/// per-bundle saved state or user defaults, which every instance of the app would share):
///
/// - `layout.json`: windows, tabs (names, colors, pins, order), split trees with each pane's
///   folder and name, and each tab's open editor documents;
/// - `ui.json`: the sidebar's visibility and mode, and the width new windows start with
///   (each window's own width is in `layout.json`).
///
/// Saving is continuous (debounced) so a crash or a kill loses at most a fraction of a
/// second; quitting saves synchronously. `window-save-state = never` turns both saving
/// and restoring windows off (isolated test instances use it).
@MainActor
final class UmiPersistence {
    static let shared = UmiPersistence()

    private var layoutWork: DispatchWorkItem?
    private var uiWork: DispatchWorkItem?
    private var restoring = false

    private var layoutPath: String { UmiPaths.path("layout.json") }
    private var uiPath: String { UmiPaths.path("ui.json") }

    /// Whether windows are saved and restored. Read once the config is loaded.
    var windowStateEnabled: Bool {
        guard let ghostty = UmiLayout.ghostty else { return false }
        return ghostty.config.windowSaveState != "never"
    }

    // MARK: Saving

    func saveLayoutSoon() {
        guard !restoring else { return }
        layoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveLayoutNow() }
        }
        layoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func saveUISoon() {
        uiWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveUINow() }
        }
        uiWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func saveAllNow() {
        layoutWork?.cancel()
        uiWork?.cancel()
        saveLayoutNow()
        saveUINow()
    }

    func saveUINow() {
        let state = UmiState.shared
        let json: [String: Any] = ["sidebar": ["visible": state.sidebarVisible, "mode": state.sidebarMode.rawValue,
                                               "width": Double(state.sidebarWidth)]]
        write(json, to: uiPath)
    }

    func saveLayoutNow() {
        guard !restoring, windowStateEnabled else { return }
        let windows = UmiTopology.windows.map(encode(window:))
        write(["version": 1, "windows": windows, "saved": ISO8601DateFormatter().string(from: Date())], to: layoutPath)
    }

    private func write(_ json: [String: Any], to path: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: UmiJSON.sanitize(json), options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func encode(window: TerminalController) -> [String: Any] {
        var json: [String: Any] = [
            "id": window.umiIDString,
            "selected_tab": window.selectedTab.idString,
            "tabs": window.tabs.map { encode(tab: $0, in: window) },
        ]
        if let frame = window.window?.frame {
            json["frame"] = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]
        }
        if let name = window.windowName { json["name"] = name }
        json["sidebar_width"] = Double(window.sidebarWidth)
        if window === UmiTopology.currentWindow { json["current"] = true }
        return json
    }

    private func encode(tab: UmiTab, in window: TerminalController) -> [String: Any] {
        let tree = window.tree(of: tab)
        var json: [String: Any] = [
            "id": tab.idString,
            "pinned": tab.pinned,
            "color": UmiTopology.colorName(tab.color),
        ]
        if let name = tab.name { json["name"] = name }
        if let root = tree.root { json["tree"] = encode(node: root) }
        if let focused = (tab === window.selectedTab ? window.focusedSurface : nil) ?? tab.focusedSurface {
            json["focused_pane"] = focused.umiID
        }
        if let zoomed = tree.zoomed, case .leaf(let view) = zoomed { json["zoomed_pane"] = view.umiID }
        if !tab.editor.isEmpty {
            json["editor"] = [
                "documents": tab.editor.documents.map { ["path": $0.url.path, "mode": $0.mode.rawValue] },
                "active": tab.editor.active?.url.path ?? "",
                "fraction": Double(tab.editor.fraction),
            ]
        }
        return json
    }

    private func encode(node: SplitTree<Ghostty.SurfaceView>.Node) -> [String: Any] {
        switch node {
        case .leaf(let view):
            var pane: [String: Any] = ["id": view.umiID, "cwd": UmiTopology.cwd(of: view)]
            if let name = UmiState.shared.paneName(view.id) { pane["name"] = name }
            if let session = UmiAgentUI.shared.session(forPane: view.id) { pane["agent"] = session }
            return ["pane": pane]
        case .split(let split):
            return ["split": [
                "direction": split.direction == .horizontal ? "horizontal" : "vertical",
                "ratio": split.ratio,
                "left": encode(node: split.left),
                "right": encode(node: split.right),
            ]]
        }
    }

    // MARK: Restoring

    func restoreUI() {
        guard let data = FileManager.default.contents(atPath: uiPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = json["sidebar"] as? [String: Any] else { return }
        let state = UmiState.shared
        if let visible = sidebar["visible"] as? Bool { state.sidebarVisible = visible }
        if let mode = (sidebar["mode"] as? String).flatMap(UmiState.SidebarMode.init(rawValue:)) { state.sidebarMode = mode }
        if let width = sidebar["width"] as? Double { state.sidebarWidth = UmiTheme.clampSidebarWidth(CGFloat(width)) }
    }

    /// Recreate the windows of the last run. Returns how many were restored.
    @discardableResult
    func restoreLayout() -> Int {
        guard windowStateEnabled,
              let ghostty = UmiLayout.ghostty, let app = ghostty.app,
              let data = FileManager.default.contents(atPath: layoutPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = json["windows"] as? [[String: Any]] else { return 0 }
        restoring = true
        defer {
            restoring = false
            saveLayoutSoon()
        }
        var restored = 0
        var current: TerminalController?
        // After an update installed while another app was in front, the windows come back behind
        // it and the app stays in the background (I-4).
        let background = UmiUpdater.launchedInBackground
        var made: [TerminalController] = []
        for windowJSON in windows {
            var tabs: [UmiTab] = []
            var selected: UmiTab?
            for tabJSON in windowJSON["tabs"] as? [[String: Any]] ?? [] {
                guard let treeJSON = tabJSON["tree"] as? [String: Any],
                      let root = decode(node: treeJSON, app: app) else { continue }
                let id = (tabJSON["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
                var zoomed: SplitTree<Ghostty.SurfaceView>.Node?
                if let zoomedID = tabJSON["zoomed_pane"] as? String,
                   let view = root.leaves().first(where: { $0.umiID == zoomedID }) {
                    zoomed = root.node(view: view)
                }
                let tab = UmiTab(id: id, tree: SplitTree(root: root, zoomed: zoomed))
                tab.name = tabJSON["name"] as? String
                tab.pinned = tabJSON["pinned"] as? Bool ?? false
                tab.color = (tabJSON["color"] as? String).flatMap(UmiTopology.color(named:)) ?? .none
                if let focusedID = tabJSON["focused_pane"] as? String {
                    tab.focusedSurface = root.leaves().first { $0.umiID == focusedID }
                }
                if let editor = tabJSON["editor"] as? [String: Any] {
                    for doc in editor["documents"] as? [[String: Any]] ?? [] {
                        guard let path = doc["path"] as? String else { continue }
                        let mode = (doc["mode"] as? String).flatMap(UmiDocument.Mode.init(rawValue:))
                        _ = try? tab.editor.open(URL(fileURLWithPath: path), mode: mode)
                    }
                    if let active = editor["active"] as? String, let doc = tab.editor.document(for: URL(fileURLWithPath: active)) {
                        tab.editor.active = doc
                    }
                    if let fraction = editor["fraction"] as? Double { tab.editor.fraction = CGFloat(fraction) }
                }
                tabs.append(tab)
                if tabJSON["id"] as? String == windowJSON["selected_tab"] as? String { selected = tab }
            }
            guard !tabs.isEmpty else { continue }
            var frame: NSRect?
            if let f = windowJSON["frame"] as? [Double], f.count == 4 {
                frame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
            }
            let controller = TerminalController.newWindow(
                ghostty, tabs: tabs, selected: selected ?? tabs[0], frame: frame,
                focus: !background, registerUndo: false)
            made.append(controller)
            controller.windowName = windowJSON["name"] as? String
            if let width = windowJSON["sidebar_width"] as? Double { controller.sidebarWidth = CGFloat(width) }
            if windowJSON["current"] as? Bool == true { current = controller }
            restored += 1
        }
        if background {
            let top = current ?? made.last
            top?.window?.orderBack(nil)
            for controller in made where controller !== top {
                if let number = top?.window?.windowNumber { controller.window?.order(.below, relativeTo: number) }
            }
            if let top { UmiTopology.windowBecameCurrent(top) }
        } else if let current {
            current.window?.makeKeyAndOrderFront(nil)
            UmiTopology.windowBecameCurrent(current)
        }
        return restored
    }

    private func decode(node json: [String: Any], app: ghostty_app_t) -> SplitTree<Ghostty.SurfaceView>.Node? {
        if let pane = json["pane"] as? [String: Any] {
            var config = Ghostty.SurfaceConfiguration()
            if let cwd = pane["cwd"] as? String, !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd) {
                config.workingDirectory = cwd
            }
            let uuid = (pane["id"] as? String).flatMap(UUID.init(uuidString:))
            let view = Ghostty.SurfaceView(app, baseConfig: config, uuid: uuid)
            UmiState.shared.setStartFolder(view.id, config.workingDirectory ?? NSHomeDirectory())
            if let name = pane["name"] as? String { UmiState.shared.setPaneName(view.id, name) }
            // A pane that showed a managed session shows it again (AP-11).
            if let session = pane["agent"] as? String { UmiAgentUI.shared.attach(view.id, session: session) }
            return .leaf(view: view)
        }
        if let split = json["split"] as? [String: Any],
           let leftJSON = split["left"] as? [String: Any], let rightJSON = split["right"] as? [String: Any] {
            let left = decode(node: leftJSON, app: app)
            let right = decode(node: rightJSON, app: app)
            switch (left, right) {
            case let (l?, r?):
                let direction: SplitTree<Ghostty.SurfaceView>.Direction =
                    (split["direction"] as? String) == "vertical" ? .vertical : .horizontal
                let ratio = split["ratio"] as? Double ?? 0.5
                return .split(.init(direction: direction, ratio: ratio, left: l, right: r))
            case let (l?, nil): return l
            case let (nil, r?): return r
            default: return nil
            }
        }
        return nil
    }
}

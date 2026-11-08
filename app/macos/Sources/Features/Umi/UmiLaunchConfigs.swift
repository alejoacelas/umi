import AppKit
import GhosttyKit

/// Launch configurations (L-21, Warp parity): saved sets of windows, tabs and split panes, as
/// YAML files in `~/.config/umi/launch_configurations` (`$XDG_CONFIG_HOME/umi/…`), in Warp's
/// format where it maps:
///
/// ```yaml
/// name: Work
/// active_window_index: 0
/// windows:
///   - active_tab_index: 0
///     tabs:
///       - title: api
///         color: blue
///         layout:
///           split_direction: horizontal   # side by side; vertical: one above the other
///           panes:
///             - cwd: ~/code/api
///               is_focused: true
///               commands:
///                 - exec: make dev
///             - cwd: ~/code/api
/// ```
///
/// ⌃⌘L lists them (Return opens one in new windows); File ▸ Save New Launch Configuration…
/// saves every window; a sidebar row's "Save as New Config" saves that tab and opens the file;
/// `umi layout ls|save|open`. Opening builds the panes the way restoring a layout does
/// (`UmiPersistence`); a pane's commands are typed into its shell as it starts.
@MainActor
enum UmiLaunchConfigs {
    struct Config {
        var name: String
        var activeWindowIndex: Int?
        var windows: [Window]
        /// The file it was read from.
        var path = ""

        var tabCount: Int { windows.reduce(0) { $0 + $1.tabs.count } }
    }

    struct Window {
        var activeTabIndex: Int?
        var tabs: [Tab]
    }

    struct Tab {
        var title: String?
        var color: TerminalTabColor = .none
        var layout: Node
        /// Warp's older place for commands: they go to the tab's focused pane (else its first).
        var commands: [String] = []
    }

    indirect enum Node {
        /// `hidden`: Umi's `is_hidden: true`, a pane that opens hidden (Warp has no hidden panes).
        case pane(cwd: String, commands: [String], focused: Bool, hidden: Bool = false)
        case split(horizontal: Bool, panes: [Node])
    }

    static let fileSuffixes = [".yaml", ".yml"]

    static var directory: String {
        (UmiPaths.userConfigFile as NSString).deletingLastPathComponent + "/launch_configurations"
    }

    // MARK: Listing

    struct Listed {
        let path: String
        /// Which document of the file it is (0 for the first); a file can hold several, as in Warp.
        var document = 0
        let config: Config?
        let error: String?

        var id: String { document == 0 ? path : "\(path)#\(document)" }
    }

    /// Every configuration in the folder, by name: one per document of each file. A file that
    /// can't be read is listed once, with its error.
    static func list() -> [Listed] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return [] }
        return files.filter { file in fileSuffixes.contains { file.lowercased().hasSuffix($0) } }
            .map { directory + "/" + $0 }
            .flatMap { path -> [Listed] in
                do {
                    return try load(path).enumerated().map { Listed(path: path, document: $0, config: $1, error: nil) }
                } catch let error as UmiError {
                    return [Listed(path: path, config: nil, error: error.message)]
                } catch {
                    return [Listed(path: path, config: nil, error: "\(error)")]
                }
            }
            .sorted {
                let a = $0.config?.name ?? ($0.path as NSString).lastPathComponent
                let b = $1.config?.name ?? ($1.path as NSString).lastPathComponent
                return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
            }
    }

    /// The configuration whose name is `query`, else the one in the file named `query` (case
    /// doesn't matter). A file holding several configurations is opened by their names.
    static func find(_ query: String) throws -> Config {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = list()
        func fileMatches(_ item: Listed) -> Bool {
            let file = (item.path as NSString).lastPathComponent.lowercased()
            return file == wanted || stripSuffix(file) == wanted
        }
        let byName = all.first { $0.config?.name.lowercased() == wanted }
        let inFile = all.filter(fileMatches)
        if byName == nil, inFile.count > 1 {
            throw UmiError.badRequest("\(abbreviate(inFile[0].path)) holds several launch configurations; open one by name: "
                                      + inFile.compactMap { $0.config?.name }.joined(separator: ", "))
        }
        guard let item = byName ?? inFile.first else {
            let names = all.compactMap { $0.config?.name }
            throw UmiError.notFound("no launch configuration \"\(query)\" in \(abbreviate(directory))"
                                    + (names.isEmpty ? "" : " (there are: \(names.joined(separator: ", ")))"))
        }
        if let error = item.error { throw UmiError.failed(error) }
        return item.config!
    }

    // MARK: Reading

    /// The configurations in a file: one per YAML document (Warp reads every document of a file).
    static func load(_ path: String) throws -> [Config] {
        let file = (path as NSString).lastPathComponent
        guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
            throw UmiError.failed("\(file): couldn't read the file")
        }
        let documents: [Any]
        do {
            documents = try UmiYAML.documents(text)
        } catch let error as UmiYAML.ParseError {
            throw UmiError.badRequest("\(file): \(error)")
        }
        return try documents.enumerated().map { n, parsed in
            var config = try decode(parsed, file: file, document: documents.count > 1 ? n + 1 : nil)
            config.path = path
            return config
        }
    }

    static func decode(_ parsed: Any, file: String, document: Int? = nil) throws -> Config {
        let place = document.map { "\(file), document \($0)" } ?? file
        func fail(_ message: String) -> UmiError { UmiError.badRequest("\(place): \(message)") }
        guard let root = parsed as? [String: Any] else { throw fail("expected `name:` and `windows:` at the top") }
        // Warp requires `name`; Umi falls back to the file's name.
        let name = text(root["name"]) ?? humanName(file)
        guard let windowsJSON = root["windows"] as? [Any] else { throw fail("there's no `windows:` list") }
        var windows: [Window] = []
        for (w, windowAny) in windowsJSON.enumerated() {
            guard let windowJSON = windowAny as? [String: Any], let tabsJSON = windowJSON["tabs"] as? [Any] else {
                throw fail("window \(w + 1) has no `tabs:` list")
            }
            var tabs: [Tab] = []
            for (t, tabAny) in tabsJSON.enumerated() {
                let place = "window \(w + 1), tab \(t + 1)"
                guard let tabJSON = tabAny as? [String: Any], let layout = tabJSON["layout"] else {
                    throw fail("\(place) has no `layout:`")
                }
                var tab = Tab(title: text(tabJSON["title"]), layout: try node(layout, place: place, fail: fail),
                              commands: try commands(tabJSON["commands"], place: place, fail: fail))
                if let colorName = text(tabJSON["color"]) {
                    guard let color = color(named: colorName) else {
                        throw fail("\(place): unknown color \"\(colorName)\" (use blue, purple, pink, red, orange, yellow, "
                                    + "green, teal, graphite or none, or Warp's black, magenta, cyan and white)")
                    }
                    tab.color = color
                }
                tabs.append(tab)
            }
            windows.append(Window(activeTabIndex: windowJSON["active_tab_index"] as? Int, tabs: tabs))
        }
        return Config(name: name, activeWindowIndex: root["active_window_index"] as? Int, windows: windows)
    }

    private static func node(_ any: Any, place: String, fail: (String) -> UmiError) throws -> Node {
        guard let json = any as? [String: Any] else {
            throw fail("\(place): a layout is a pane (`cwd:`) or a split (`split_direction:` and `panes:`)")
        }
        if let panes = json["panes"] {
            guard let list = panes as? [Any], !list.isEmpty else { throw fail("\(place): `panes:` is an empty list") }
            let direction = text(json["split_direction"])?.lowercased() ?? "horizontal"
            guard direction == "horizontal" || direction == "vertical" else {
                throw fail("\(place): split_direction is horizontal (side by side) or vertical (one above the other)")
            }
            return .split(horizontal: direction == "horizontal",
                          panes: try list.map { try node($0, place: place, fail: fail) })
        }
        return .pane(cwd: text(json["cwd"]) ?? "", commands: try commands(json["commands"], place: place, fail: fail),
                     focused: json["is_focused"] as? Bool ?? false, hidden: json["is_hidden"] as? Bool ?? false)
    }

    /// `commands:` is a list of `exec: COMMAND` (Warp's form) or of plain strings.
    private static func commands(_ any: Any?, place: String, fail: (String) -> UmiError) throws -> [String] {
        guard let any, !(any is NSNull) else { return [] }
        guard let list = any as? [Any] else { throw fail("\(place): `commands:` is a list of `- exec: COMMAND`") }
        return try list.map { item in
            if let entry = item as? [String: Any], let exec = text(entry["exec"]) { return exec }
            if let line = text(item) { return line }
            throw fail("\(place): `commands:` is a list of `- exec: COMMAND`")
        }
    }

    private static func text(_ any: Any?) -> String? {
        switch any {
        case let s as String: return s
        case let i as Int: return String(i)
        case let d as Double: return String(d)
        case let b as Bool: return b ? "true" : "false"
        default: return nil
        }
    }

    /// Umi's tab colors, plus Warp's terminal-color names where they differ.
    static func color(named name: String) -> TerminalTabColor? {
        switch name.lowercased() {
        case "magenta": return .purple
        case "cyan": return .teal
        case "black", "white": return .graphite
        default: return UmiTopology.color(named: name)
        }
    }

    /// The name a saved file uses for a tab color: Warp's terminal-color name where Warp has one,
    /// so Warp can read the file; pink and orange have none and keep Umi's names (Warp then can't
    /// read that file).
    static func fileColorName(_ color: TerminalTabColor) -> String {
        switch color {
        case .purple: return "magenta"
        case .teal: return "cyan"
        case .graphite: return "white"
        default: return UmiTopology.colorName(color)
        }
    }

    // MARK: Capturing

    /// The windows as a configuration (Warp's "save the current configuration").
    static func capture(name: String, windows: [TerminalController]) -> Config {
        var out: [Window] = []
        var active: Int?
        for controller in windows {
            let tabs = controller.tabs.map { (tab: $0, template: capture(tab: $0, in: controller)) }
            let kept = tabs.compactMap(\.template)
            guard !kept.isEmpty else { continue }
            let selected = tabs.filter { $0.template != nil }.firstIndex { $0.tab === controller.selectedTab }
            if controller === UmiTopology.currentWindow { active = out.count }
            out.append(Window(activeTabIndex: selected, tabs: kept))
        }
        return Config(name: name, activeWindowIndex: active, windows: out)
    }

    /// One tab: its name, color and terminal panes (file and web panes are left out, as Warp
    /// leaves out panes that aren't terminals). Hidden panes are included, marked `is_hidden`, after
    /// the panes on show in a row of their own. Nil when no pane is left.
    static func capture(tab: UmiTab, in controller: TerminalController) -> Tab? {
        let tree = controller.tree(of: tab)
        let focused = tab === controller.selectedTab ? (controller.focusedSurface ?? tab.focusedSurface) : tab.focusedSurface
        let shown = tree.root.flatMap { capture(node: $0, focused: focused) }
        let hidden: [Node] = tab.hidden.compactMap { view in
            if UmiFilePanes.shared.document(of: view) != nil || UmiWebPanes.shared.page(of: view) != nil { return nil }
            return .pane(cwd: UmiTopology.cwd(of: view), commands: [], focused: false, hidden: true)
        }
        guard let first = shown ?? hidden.first else { return nil }
        if hidden.isEmpty { return Tab(title: tab.name, color: tab.color, layout: first) }
        var panes: [Node]
        if case .split(true, let inner) = first { panes = inner } else { panes = [first] }
        if shown == nil { panes = [] }
        panes += hidden
        return Tab(title: tab.name, color: tab.color, layout: panes.count == 1 ? panes[0] : .split(horizontal: true, panes: panes))
    }

    private static func capture(node: SplitTree<Ghostty.SurfaceView>.Node, focused: Ghostty.SurfaceView?) -> Node? {
        switch node {
        case .leaf(let view):
            if UmiFilePanes.shared.document(of: view) != nil || UmiWebPanes.shared.page(of: view) != nil { return nil }
            return .pane(cwd: UmiTopology.cwd(of: view), commands: [], focused: view === focused)
        case .split(let split):
            let horizontal = split.direction == .horizontal
            // Warp's splits hold any number of panes: a row inside a row is one row.
            var panes: [Node] = []
            for child in [split.left, split.right] {
                guard let captured = capture(node: child, focused: focused) else { continue }
                if case .split(let h, let inner) = captured, h == horizontal {
                    panes += inner
                } else {
                    panes.append(captured)
                }
            }
            if panes.count <= 1 { return panes.first }
            return .split(horizontal: horizontal, panes: panes)
        }
    }

    // MARK: Writing

    static func yaml(_ config: Config) -> String {
        var top: [(String, UmiYAML.Node)] = [("name", .string(config.name))]
        if let active = config.activeWindowIndex { top.append(("active_window_index", .int(active))) }
        top.append(("windows", .list(config.windows.map { window in
            var pairs: [(String, UmiYAML.Node)] = []
            if let active = window.activeTabIndex { pairs.append(("active_tab_index", .int(active))) }
            pairs.append(("tabs", .list(window.tabs.map { tab in
                var tabPairs: [(String, UmiYAML.Node)] = []
                if let title = tab.title { tabPairs.append(("title", .string(title))) }
                tabPairs.append(("layout", yaml(tab.layout)))
                if tab.color != .none { tabPairs.append(("color", .string(fileColorName(tab.color)))) }
                return .map(tabPairs)
            })))
            return .map(pairs)
        })))
        return header + UmiYAML.emit(.map(top))
    }

    private static func yaml(_ node: Node) -> UmiYAML.Node {
        switch node {
        case .pane(let cwd, let commands, let focused, let hidden):
            var pairs: [(String, UmiYAML.Node)] = [("cwd", .string(abbreviate(cwd)))]
            if !commands.isEmpty { pairs.append(("commands", .list(commands.map { .map([("exec", .string($0))]) }))) }
            if focused { pairs.append(("is_focused", .bool(true))) }
            if hidden { pairs.append(("is_hidden", .bool(true))) }
            return .map(pairs)
        case .split(let horizontal, let panes):
            return .map([("split_direction", .string(horizontal ? "horizontal" : "vertical")),
                         ("panes", .list(panes.map(yaml)))])
        }
    }

    private static let header = """
        # Umi launch configuration: windows, tabs and panes to open together.
        # Open it from the launch configuration palette (⌃⌘L) or with `umi layout open NAME`.
        #
        # A layout is a pane (`cwd:`, optional `commands:` of `- exec: COMMAND`, `is_focused:`,
        # `is_hidden:` for a pane that opens hidden)
        # or a split (`split_direction: horizontal` for side by side, `vertical` for one above
        # the other, and its `panes:`). A tab can have a `title:` and a `color:`.

        """

    /// Write a configuration to `fileName` (`.yaml` is added unless it ends in `.yaml` or `.yml`).
    /// Returns the file's path. An existing file is kept unless `replace`.
    @discardableResult
    static func write(_ config: Config, fileName raw: String, replace: Bool = false) throws -> String {
        let fileName = try normalizedFileName(raw)
        let path = directory + "/" + fileName
        if !replace && FileManager.default.fileExists(atPath: path) {
            throw UmiError.failed("a launch configuration with the same name already exists: \(abbreviate(path))")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        do {
            try yaml(config).write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            throw UmiError.failed("couldn't write \(abbreviate(path)): \(error.localizedDescription)")
        }
        return path
    }

    static func normalizedFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripSuffix(name).isEmpty else { throw UmiError.badRequest("give the launch configuration a name") }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            throw UmiError.badRequest("a launch configuration's name can't contain / or start with a dot")
        }
        return fileSuffixes.contains(where: { name.lowercased().hasSuffix($0) }) ? name : name + ".yaml"
    }

    /// Save every window under `fileName`; the configuration is named after the file.
    @discardableResult
    static func saveWindows(fileName: String, replace: Bool = false) throws -> (path: String, config: Config) {
        let normalized = try normalizedFileName(fileName)
        let config = capture(name: humanName(normalized), windows: UmiTopology.windows)
        guard !config.windows.isEmpty else { throw UmiError.failed("there are no terminal panes to save") }
        return (try write(config, fileName: normalized, replace: replace), config)
    }

    /// Save one tab as a new configuration, `my_tab_config.yaml` (or `_1`, `_2`, … when taken),
    /// as Warp's "Save as new config" does, then open the file in the editor.
    @discardableResult
    static func saveTab(_ tab: UmiTab, in controller: TerminalController, openFile: Bool = true) throws -> String {
        guard let template = capture(tab: tab, in: controller) else {
            throw UmiError.failed("the tab has no terminal panes to save")
        }
        var stem = "my_tab_config"
        var n = 0
        while fileSuffixes.contains(where: { FileManager.default.fileExists(atPath: directory + "/" + stem + $0) }) {
            n += 1
            stem = "my_tab_config_\(n)"
        }
        let config = Config(name: tab.name ?? tab.title, activeWindowIndex: 0,
                            windows: [Window(activeTabIndex: 0, tabs: [template])])
        let path = try write(config, fileName: stem + ".yaml")
        if openFile { _ = UmiEditor.openFromSystem(URL(fileURLWithPath: path), inCurrentTab: true) }
        return path
    }

    // MARK: Opening

    /// Open a configuration: each of its windows as a new window, the active one in front.
    @discardableResult
    static func open(_ config: Config, focus: Bool = true) throws -> [String: Any] {
        let ghostty = try UmiLayout.requireGhostty()
        guard let app = ghostty.app else { throw UmiError.failed("the terminal engine isn't ready") }
        if config.windows.isEmpty {
            // Like Warp: an empty configuration opens a plain new window.
            let made = try UmiLayout.newWindow(UmiLayout.PaneOptions(), tabName: nil, focus: focus)
            return ["name": config.name, "windows": [made["window"] ?? ""], "panes": [made["pane"] ?? ""]]
        }
        var made: [TerminalController] = []
        var front: TerminalController?
        var panes: [String] = []
        for (w, window) in config.windows.enumerated() {
            var tabs: [UmiTab] = []
            var selected: UmiTab?
            for (t, template) in window.tabs.enumerated() {
                var focused: Ghostty.SurfaceView?
                hiddenViews = []
                guard let built = build(withTabCommands(template), app: app, focused: &focused) else { continue }
                // Panes marked hidden, then those past the tab's limit (three), open hidden.
                var tree = SplitTree(root: built, zoomed: nil)
                var hidden: [Ghostty.SurfaceView] = []
                for view in hiddenViews where (tree.root?.leaves().count ?? 0) > 1 {
                    if let node = tree.root?.node(view: view) { tree = tree.removing(node); hidden.append(view) }
                }
                hiddenViews = []
                while let leaves = tree.root?.leaves(), leaves.count > 3, let last = leaves.last,
                      let node = tree.root?.node(view: last) {
                    tree = tree.removing(node)
                    hidden.insert(last, at: 0)
                }
                guard let root = tree.root else { continue }
                let tab = UmiTab(tree: SplitTree(root: root, zoomed: nil))
                tab.hidden = hidden
                if let f = focused, hidden.contains(where: { $0 === f }) { focused = nil }
                tab.name = template.title.flatMap { $0.isEmpty ? nil : $0 }
                tab.color = template.color
                if let focused { tab.focusedSurface = focused }
                panes += root.leaves().map(\.umiID) + hidden.map(\.umiID)
                tabs.append(tab)
                if t == window.activeTabIndex { selected = tab }
            }
            guard let first = tabs.first else { continue }
            let controller = TerminalController.newWindow(ghostty, tabs: tabs, selected: selected ?? first, focus: focus)
            made.append(controller)
            if w == config.activeWindowIndex { front = controller }
            for tab in tabs {
                UmiEvents.shared.emit("tab.created", ["tab": tab.idString, "window": controller.umiIDString])
            }
        }
        guard !made.isEmpty else { throw UmiError.failed("\(config.name) has no panes to open") }
        if focus, let window = front ?? made.last {
            window.window?.makeKeyAndOrderFront(nil)
            UmiLayout.focusWindow(window)
        }
        UmiState.shared.layoutDidChange()
        UmiEvents.shared.emit("layout.opened", ["name": config.name, "windows": made.map(\.umiIDString)])
        return ["name": config.name, "windows": made.map(\.umiIDString), "panes": panes]
    }

    private static func withTabCommands(_ tab: Tab) -> Node {
        guard !tab.commands.isEmpty else { return tab.layout }
        func hasFocus(_ node: Node) -> Bool {
            switch node {
            case .pane(_, _, let focused, _): return focused
            case .split(_, let panes): return panes.contains(where: hasFocus)
            }
        }
        func add(_ node: Node) -> Node {
            switch node {
            case .pane(let cwd, let commands, let focused, let hidden):
                return .pane(cwd: cwd, commands: commands + tab.commands, focused: focused, hidden: hidden)
            case .split(let horizontal, var panes):
                let target = panes.firstIndex(where: hasFocus) ?? 0
                panes[target] = add(panes[target])
                return .split(horizontal: horizontal, panes: panes)
            }
        }
        return add(tab.layout)
    }

    /// Panes built for `is_hidden` entries (by `build`, read by `open`).
    private static var hiddenViews: [Ghostty.SurfaceView] = []

    private static func build(_ node: Node, app: ghostty_app_t,
                              focused: inout Ghostty.SurfaceView?) -> SplitTree<Ghostty.SurfaceView>.Node? {
        switch node {
        case .pane(let cwd, let commands, let isFocused, let hidden):
            var config = Ghostty.SurfaceConfiguration()
            let folder = (cwd as NSString).expandingTildeInPath
            var isDir = ObjCBool(false)
            if !folder.isEmpty, FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue {
                config.workingDirectory = folder
            }
            // Typed into the shell as it starts, one per line.
            if !commands.isEmpty { config.initialInput = commands.joined(separator: "\n") + "\n" }
            let view = Ghostty.SurfaceView(app, baseConfig: config)
            UmiState.shared.setStartFolder(view.id, config.workingDirectory ?? NSHomeDirectory())
            if isFocused && focused == nil { focused = view }
            if hidden { hiddenViews.append(view) }
            return .leaf(view: view)
        case .split(let horizontal, let panes):
            let built = panes.compactMap { build($0, app: app, focused: &focused) }
            // Equal shares: the first pane takes 1/n of the row, the rest share what's left.
            func chain(_ nodes: ArraySlice<SplitTree<Ghostty.SurfaceView>.Node>) -> SplitTree<Ghostty.SurfaceView>.Node? {
                guard let first = nodes.first else { return nil }
                guard nodes.count > 1, let rest = chain(nodes.dropFirst()) else { return first }
                return .split(.init(direction: horizontal ? .horizontal : .vertical, ratio: 1 / Double(nodes.count),
                                    left: first, right: rest))
            }
            return chain(built[...])
        }
    }

    // MARK: Names

    /// `my_layout.yaml` → "My Layout": words split at `_`, each capitalized (the rule Warp's save
    /// dialog uses to name a configuration after its file).
    static func humanName(_ file: String) -> String {
        stripSuffix(file).split(separator: "_", omittingEmptySubsequences: true)
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }

    static func stripSuffix(_ file: String) -> String {
        for suffix in fileSuffixes where file.lowercased().hasSuffix(suffix) { return String(file.dropLast(suffix.count)) }
        return file
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    // MARK: File ▸ Launch Configurations

    static let menuTitle = "Launch Configurations"

    /// Fill the File ▸ Launch Configurations submenu with each configuration by name each time it
    /// opens, then a separator, before Umi's own items (as Warp's File menu lists them).
    static func installMenu(in mainMenu: NSMenu) {
        for item in UmiShortcuts.allItems(mainMenu) where item.title == menuTitle && item.submenu != nil {
            item.submenu?.delegate = UmiLaunchConfigMenu.shared
        }
    }

    static let menuItemMarker = "umi-launch-config"

    static func rebuildMenu(_ menu: NSMenu) {
        for item in menu.items where (item.representedObject as? String)?.hasPrefix(menuItemMarker) == true {
            menu.removeItem(item)
        }
        let configs = list().filter { $0.config != nil }
        guard !configs.isEmpty else { return }
        for (index, listed) in configs.enumerated() {
            let item = NSMenuItem(title: listed.config!.name, action: #selector(UmiLaunchConfigMenu.openConfig(_:)),
                                  keyEquivalent: "")
            item.target = UmiLaunchConfigMenu.shared
            item.representedObject = menuItemMarker + ":" + listed.id
            menu.insertItem(item, at: index)
        }
        let separator = NSMenuItem.separator()
        separator.representedObject = menuItemMarker
        menu.insertItem(separator, at: configs.count)
    }

    static func openMenuItem(_ item: NSMenuItem) {
        guard let marked = item.representedObject as? String, marked.hasPrefix(menuItemMarker + ":") else { return }
        let id = String(marked.dropFirst(menuItemMarker.count + 1))
        guard let config = list().first(where: { $0.id == id })?.config else { NSSound.beep(); return }
        do { try open(config) } catch { NSSound.beep() }
    }

    // MARK: Control methods

    static let methods: Set<String> = ["layout.ls", "layout.save", "layout.open"]

    static func handle(_ method: String, _ params: UmiParams) throws -> [String: Any] {
        switch method {
        case "layout.ls":
            return ["directory": directory, "configs": list().map { item -> [String: Any] in
                var out: [String: Any] = ["path": item.path, "file": (item.path as NSString).lastPathComponent,
                                          "document": item.document]
                if let config = item.config {
                    out["name"] = config.name
                    out["windows"] = config.windows.count
                    out["tabs"] = config.tabCount
                }
                if let error = item.error { out["error"] = error }
                return out
            }]
        case "layout.save":
            guard let name = params.string("name") else { throw UmiError.badRequest("give the launch configuration a name") }
            let (path, config) = try saveWindows(fileName: name, replace: params.bool("replace") ?? false)
            return ["path": path, "name": config.name, "windows": config.windows.count, "tabs": config.tabCount]
        case "layout.open":
            guard let name = params.string("name") else { throw UmiError.badRequest("name the launch configuration to open") }
            return try open(find(name), focus: params.bool("focus") ?? true)
        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }

    // MARK: Save dialog (File ▸ Save New Launch Configuration…)

    /// Ask for a file name and save every window, as Warp's "Save Current Configuration".
    static func presentSaveDialog(message: String? = nil, draft: String = "") {
        let alert = NSAlert()
        alert.messageText = "Save Current Configuration"
        alert.informativeText = message ?? "Saves your windows, tabs and panes to \(abbreviate(directory))."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "launch_config.yaml"
        field.stringValue = draft
        field.setAccessibilityLabel("Launch configuration name")
        alert.accessoryView = field
        alert.addButton(withTitle: "Save Configuration")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let window = UmiTopology.currentWindow?.window
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            let name = field.stringValue
            DispatchQueue.main.async {
                do {
                    let (path, _) = try saveWindows(fileName: name)
                    presentSaved(path)
                } catch let error as UmiError {
                    let failed = error.message.hasPrefix("a launch configuration with the same name")
                        ? "Failed to save. A launch configuration with the same name already exists." : error.message
                    presentSaveDialog(message: failed, draft: name)
                } catch {
                    presentSaveDialog(message: "An issue was encountered while saving.", draft: name)
                }
            }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private static func presentSaved(_ path: String) {
        let alert = NSAlert()
        alert.messageText = "Saved Successfully"
        alert.informativeText = "Saved to \(abbreviate(path)). Open it with ⌃⌘L."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open YAML File")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertSecondButtonReturn else { return }
            _ = UmiEditor.openFromSystem(URL(fileURLWithPath: path), inCurrentTab: true)
        }
        if let window = UmiTopology.currentWindow?.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

/// The File ▸ Launch Configurations submenu's delegate: lists the configurations as it opens.
final class UmiLaunchConfigMenu: NSObject, NSMenuDelegate {
    static let shared = UmiLaunchConfigMenu()

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { UmiLaunchConfigs.rebuildMenu(menu) }
    }

    @MainActor @objc func openConfig(_ sender: NSMenuItem) {
        UmiLaunchConfigs.openMenuItem(sender)
    }
}

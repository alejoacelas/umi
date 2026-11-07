import AppKit
import Combine
import CoreServices
import SwiftUI

/// A file or folder in the project explorer. Folders load their children when first expanded.
/// Only `UmiFileTreeModel` changes nodes; views draw the model's flattened `rows`.
@MainActor
final class UmiFileNode {
    let url: URL
    let isDirectory: Bool
    var expanded = false
    private(set) var children: [UmiFileNode]?

    var name: String { url.lastPathComponent }
    var path: String { url.path }

    /// Names never shown in the explorer.
    static let hidden: Set<String> = [".git", ".DS_Store", ".hg", ".svn"]
    static let maxEntries = 3000

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    /// Read the folder's entries (again, with `force`). Nodes already known keep their state.
    func loadChildren(force: Bool = false) {
        guard isDirectory, force || children == nil else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        let old = Dictionary((children ?? []).map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        var nodes: [UmiFileNode] = []
        for entry in entries.prefix(Self.maxEntries) {
            let name = entry.lastPathComponent
            if Self.hidden.contains(name) { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            // Dotfiles are shown (`.github`, `.env.example`); other Finder-hidden items aren't.
            if values?.isHidden == true && !name.hasPrefix(".") { continue }
            let isDirectory = values?.isDirectory ?? false
            if let known = old[name], known.isDirectory == isDirectory {
                nodes.append(known)
            } else {
                nodes.append(UmiFileNode(url: url.appendingPathComponent(name, isDirectory: isDirectory),
                                         isDirectory: isDirectory))
            }
        }
        nodes.sort(by: Self.order)
        children = nodes
    }

    /// Warp's order: folders first, then files; dotfiles first within each; natural order.
    static func order(_ a: UmiFileNode, _ b: UmiFileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let aDot = a.name.hasPrefix("."), bDot = b.name.hasPrefix(".")
        if aDot != bDot { return aDot }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Every loaded folder under (and including) this one.
    func loadedFolders() -> [UmiFileNode] {
        guard isDirectory, let children else { return isDirectory ? [self] : [] }
        return [self] + children.flatMap { $0.loadedFolders() }
    }
}

/// Watches a folder tree with FSEvents and reports the folders whose contents changed.
final class UmiFSWatcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String], Bool) -> Void

    /// `handler` gets the changed folders and whether everything must be rescanned, on the main queue.
    init?(path: String, handler: @escaping ([String], Bool) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<UmiFSWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var rescan = false
            for i in 0..<count {
                let flag = Int(flags[i])
                if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0 { rescan = true }
            }
            watcher.handler(list, rescan)
        }
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}

/// The project explorer of one window (S-2, Warp parity 2026-11-05): the git root of the focused
/// pane's folder (else that folder) as a tree, kept current with FSEvents, driven from the
/// keyboard (↑↓ select, → expand, ← collapse or go to the parent, Enter opens, Esc back to the
/// pane), with Warp's right-click menu.
@MainActor
final class UmiFileTreeModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        enum Kind: Equatable { case item, newFile }
        let id: String
        let url: URL
        let depth: Int
        let isDirectory: Bool
        let expanded: Bool
        let ignored: Bool
        let kind: Kind
    }

    enum Edit: Equatable {
        case rename(URL)
        case newFile(in: URL)
    }

    @Published private(set) var root: UmiFileNode?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var selected: URL?
    @Published private(set) var edit: Edit?
    @Published var editText = ""
    /// Bumped to scroll the selected row into view.
    @Published private(set) var scrollTick = 0
    /// Bumped when the tree should take keyboard focus (see `pendingFocus`).
    @Published private(set) var focusTick = 0
    var pendingFocus = false
    weak var keyView: NSView?

    private weak var controller: TerminalController?
    private var timer: Timer?
    private var watcher: UmiFSWatcher?
    private var ignored: Set<String> = []
    private var ignoredWork: Process?
    private var ignoredPending = false
    private var lastActiveFile: URL?
    /// Folders the user closed (by path); revealing the active file doesn't reopen them.
    private var collapsedByUser: Set<String> = []
    private var hiddenObserver: AnyCancellable?

    // MARK: One model per window

    private static var models: [ObjectIdentifier: UmiFileTreeModel] = [:]

    static func model(for controller: TerminalController) -> UmiFileTreeModel {
        models = models.filter { $0.value.controller != nil }
        if let model = models[ObjectIdentifier(controller)] { return model }
        let model = UmiFileTreeModel()
        model.controller = controller
        models[ObjectIdentifier(controller)] = model
        return model
    }

    static func existing(for controller: TerminalController) -> UmiFileTreeModel? {
        models[ObjectIdentifier(controller)]
    }

    init() {
        hiddenObserver = UmiState.shared.$showHiddenFiles.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.rebuild() }
        }
    }

    // MARK: Following the focused pane

    /// Follow the focused pane while the explorer is visible.
    func start() {
        stop()
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The pane the explorer follows: the window's focused pane.
    var focusedPane: Ghostty.SurfaceView? {
        guard let controller, !controller.tabs.isEmpty else { return nil }
        return controller.focusedSurface ?? controller.selectedTab.effectiveFocusedSurface
    }

    func update() {
        guard let pane = focusedPane else { return }
        let pwd = UmiTopology.cwd(of: pane)
        if !pwd.isEmpty {
            let rootURL = Self.projectRoot(for: URL(fileURLWithPath: pwd))
            if root?.url.path != rootURL.path { setRoot(rootURL) }
        }
        // Reveal the file the focused pane shows, once each time it changes (Warp's active file).
        if let doc = UmiFilePanes.shared.document(of: pane) {
            if doc.url != lastActiveFile {
                lastActiveFile = doc.url
                reveal(doc.url)
            }
        } else {
            lastActiveFile = nil
        }
    }

    private func setRoot(_ url: URL) {
        let node = UmiFileNode(url: url, isDirectory: true)
        node.expanded = true
        node.loadChildren()
        root = node
        selected = nil
        edit = nil
        ignored = []
        collapsedByUser = []
        watcher?.stop()
        watcher = UmiFSWatcher(path: url.path) { [weak self] paths, rescan in
            MainActor.assumeIsolated { self?.filesChanged(paths, rescan: rescan) }
        }
        rebuild()
        refreshIgnored()
    }

    /// A path with symlinks resolved as the file system does (realpath). Foundation's
    /// `resolvingSymlinksInPath` strips `/private`, but FSEvents reports `/private/var/…`.
    nonisolated static func realURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: url.hasDirectoryPath)
    }

    /// The git root of a folder, else the folder; symlinks resolved (FSEvents reports real paths).
    static func projectRoot(for url: URL) -> URL {
        let url = realURL(url)
        var current = url
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return url
    }

    // MARK: File system changes

    private func filesChanged(_ paths: [String], rescan: Bool) {
        guard let root else { return }
        let folders = root.loadedFolders()
        var touched = false
        for path in paths {
            let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
            // Git's own bookkeeping changes on every git command; it isn't shown.
            if trimmed.hasSuffix("/.git") || trimmed.contains("/.git/") { continue }
            touched = true
            if rescan { break }
            for folder in folders where folder.url.path == trimmed {
                folder.loadChildren(force: true)
            }
        }
        if rescan {
            for folder in folders { folder.loadChildren(force: true) }
            touched = true
        }
        guard touched else { return }
        if let selected, !FileManager.default.fileExists(atPath: selected.path) { self.selected = nil }
        rebuild()
        refreshIgnored()
    }

    /// Which entries git ignores (shown in italic and lighter, as Warp does).
    private func refreshIgnored() {
        guard let root else { return }
        if ignoredWork != nil { ignoredPending = true; return }
        let rootPath = root.url.path
        guard FileManager.default.fileExists(atPath: rootPath + "/.git") else {
            ignored = []
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", rootPath, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        ignoredWork = process
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: Set<String> = []
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    found = Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
                }
            } catch {}
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.ignoredWork = nil
                    if self.root?.url.path == rootPath, found != self.ignored {
                        self.ignored = found
                        self.rebuild()
                    }
                    if self.ignoredPending {
                        self.ignoredPending = false
                        self.refreshIgnored()
                    }
                }
            }
        }
    }

    func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        guard let root, !ignored.isEmpty else { return false }
        let rootPath = root.url.path
        guard url.path.hasPrefix(rootPath + "/") else { return false }
        let relative = String(url.path.dropFirst(rootPath.count + 1))
        if ignored.contains(relative) || ignored.contains(relative + "/") { return true }
        var parts = relative.split(separator: "/").map(String.init)
        parts.removeLast()
        var prefix = ""
        for part in parts {
            prefix += part + "/"
            if ignored.contains(prefix) { return true }
        }
        return false
    }

    // MARK: Rows

    func rebuild() {
        guard let root else {
            rows = []
            return
        }
        let showHidden = UmiState.shared.showHiddenFiles
        var out: [Row] = []
        func add(_ node: UmiFileNode, depth: Int) {
            out.append(Row(id: node.path, url: node.url, depth: depth, isDirectory: node.isDirectory,
                           expanded: node.expanded, ignored: isIgnored(node.url, isDirectory: node.isDirectory),
                           kind: .item))
            guard node.isDirectory, node.expanded else { return }
            if case .newFile(let folder) = edit, folder == node.url {
                out.append(Row(id: node.path + "/\u{0}new", url: node.url.appendingPathComponent("new_file"),
                               depth: depth + 1, isDirectory: false, expanded: false, ignored: false, kind: .newFile))
            }
            for child in node.children ?? [] {
                if !showHidden && child.name.hasPrefix(".") { continue }
                add(child, depth: depth + 1)
            }
        }
        add(root, depth: 0)
        if rows != out { rows = out }
        if let selected, !out.contains(where: { $0.url == selected && $0.kind == .item }) {
            // The selected item went away (deleted, or hidden): select nothing, as Warp does.
            self.selected = nil
        }
    }

    func node(at url: URL) -> UmiFileNode? {
        guard let root else { return nil }
        if root.url.path == url.path { return root }
        let rootPath = root.url.path
        guard url.path.hasPrefix(rootPath + "/") else { return nil }
        var node = root
        for part in url.path.dropFirst(rootPath.count + 1).split(separator: "/") {
            node.loadChildren()
            guard let next = node.children?.first(where: { $0.name == part }) else { return nil }
            node = next
        }
        return node
    }

    var selectedRow: Row? { rows.first { $0.url == selected && $0.kind == .item } }

    // MARK: Selection and keys

    func select(_ url: URL?, scroll: Bool = true) {
        selected = url.map { u in rows.first { $0.url.path == u.path && $0.kind == .item }?.url ?? u }
        if scroll { scrollTick &+= 1 }
    }

    /// Move the selection by `delta` rows (↑/↓). With nothing selected, the first row.
    func moveSelection(_ delta: Int) {
        let items = rows.filter { $0.kind == .item }
        guard !items.isEmpty else { return }
        guard let index = items.firstIndex(where: { $0.url == selected }) else {
            select(items[0].url)
            return
        }
        select(items[max(0, min(items.count - 1, index + delta))].url)
    }

    /// Open or close a folder. `byUser`: a key or click did it, which revealing the active file
    /// respects (it doesn't reopen a folder the user closed).
    func setExpanded(_ url: URL, _ expanded: Bool, byUser: Bool = false) {
        guard let node = node(at: url), node.isDirectory else { return }
        if byUser {
            if expanded { collapsedByUser.remove(node.path) } else { collapsedByUser.insert(node.path) }
        }
        guard node.expanded != expanded else { return }
        node.expanded = expanded
        if expanded { node.loadChildren() }
        rebuild()
    }

    /// → expands a collapsed folder.
    func expandSelected() {
        guard let row = selectedRow, row.isDirectory, !row.expanded else { return }
        setExpanded(row.url, true, byUser: true)
    }

    /// ← collapses an expanded folder, else goes to the item's folder.
    func collapseSelected() {
        guard let row = selectedRow else { return }
        if row.isDirectory && row.expanded {
            setExpanded(row.url, false, byUser: true)
        } else if let root, row.url.path != root.url.path {
            select(row.url.deletingLastPathComponent())
        }
    }

    /// Enter, or a click: a folder opens or closes, a file opens.
    func activate(_ url: URL) {
        select(url, scroll: false)
        guard let node = node(at: url) else { return }
        if node.isDirectory {
            setExpanded(url, !node.expanded, byUser: true)
        } else {
            open(url)
        }
    }

    /// A key while the tree has focus. True when it was the tree's.
    func handleKey(_ event: NSEvent) -> Bool {
        guard edit == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 126: moveSelection(-1)
        case 125: moveSelection(1)
        case 124: expandSelected()
        case 123: collapseSelected()
        case 36, 76:
            if let url = selected { activate(url) } else { moveSelection(1) }
        case 53: focusPane()
        default: return false
        }
        return true
    }

    /// Show `url` in the tree: open its folders, select it and scroll to it. As in Warp, it stops
    /// at a folder the user collapsed (the root included), and selects only the file itself.
    func reveal(_ url: URL) {
        guard let root else { return }
        let target = Self.realURL(url)
        let rootURL = Self.realURL(root.url)
        guard target.path.hasPrefix(rootURL.path + "/"), !collapsedByUser.contains(root.path) else { return }
        let relative = target.path.dropFirst(rootURL.path.count + 1).split(separator: "/")
        var node = root
        node.expanded = true
        node.loadChildren()
        var found = true
        for (index, part) in relative.enumerated() {
            guard let next = node.children?.first(where: { $0.name == part }) else { found = false; break }
            node = next
            if index < relative.count - 1 {
                if collapsedByUser.contains(node.path) { found = false; break }
                node.expanded = true
                node.loadChildren()
            }
        }
        rebuild()
        if found { select(node.url) }
    }

    // MARK: Focus

    /// Give the tree keyboard focus (when Files mode is shown by key, or a row is clicked).
    func requestFocus() {
        if let keyView, let window = keyView.window {
            window.makeFirstResponder(keyView)
            return
        }
        pendingFocus = true
        focusTick &+= 1
    }

    var hasFocus: Bool {
        guard let keyView, let window = keyView.window else { return false }
        return window.firstResponder === keyView
    }

    /// Esc: back to the focused pane.
    func focusPane() {
        guard let pane = focusedPane else { return }
        UmiLayout.focusPane(pane, activate: true)
        pane.window?.makeFirstResponder(pane)
    }

    // MARK: Actions

    /// Whether a file opens in Umi's editor (as in Warp, any file that isn't binary, within the
    /// editor's size limit); others open with their default app.
    static func isText(_ url: URL) -> Bool {
        guard (try? UmiTextFile.checkOpenable(url)) != nil,
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 8192)) ?? Data()
        return !head.contains(0)
    }

    func open(_ url: URL) {
        if Self.isText(url) {
            openInEditor(url)
        } else {
            openWithDefaultApp(url)
        }
    }

    /// Open a file in the editor, in a pane beside the focused pane (E-9; where it's already open,
    /// it shows there): Enter, New File and Warp's "Open in new pane".
    func openInEditor(_ url: URL) {
        guard let controller else { return }
        do {
            if let anchor = focusedPane {
                try UmiFilePanes.open(url, mode: nil, near: anchor, focus: true)
            } else {
                try controller.selectedTab.editor.open(url, mode: nil)
            }
        } catch let error as UmiError {
            alert("Can't open \(url.lastPathComponent)", error.message)
        } catch {}
    }

    /// Open with the file's default app. `UMI_TEST_OPEN_LOG` (tests only) appends the path to that
    /// file instead, so no app opens on the test Mac.
    func openWithDefaultApp(_ url: URL) {
        if let log = ProcessInfo.processInfo.environment["UMI_TEST_OPEN_LOG"], !log.isEmpty {
            if !FileManager.default.fileExists(atPath: log) { FileManager.default.createFile(atPath: log, contents: nil) }
            if let handle = FileHandle(forWritingAtPath: log) {
                handle.seekToEndOfFile()
                handle.write(Data((url.path + "\n").utf8))
                try? handle.close()
            }
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Open in a new tab: a folder as a terminal there, a file as a tab of its own.
    func openInNewTab(_ url: URL, isDirectory: Bool) {
        guard let controller else { return }
        var options = UmiLayout.PaneOptions()
        options.cwd = isDirectory ? url.path : url.deletingLastPathComponent().path
        do {
            if isDirectory {
                _ = try UmiLayout.newTab(in: controller, options: options, tabName: nil, color: .none,
                                         index: nil, focus: true, inheritFrom: nil)
                return
            }
            try UmiTextFile.checkOpenable(url)
            let doc = try UmiDocument(url: url, mode: nil)
            let created = try UmiLayout.newTab(in: controller, options: options, tabName: nil, color: .none,
                                               index: nil, focus: false, inheritFrom: nil)
            guard let id = created["pane"] as? String,
                  let pane = UmiTopology.allSurfaces.first(where: { $0.umiID == id }) else { return }
            UmiFilePanes.shared.attach(doc, to: pane)
            UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": pane.umiID,
                                                    "tab": (created["tab"] as? String) ?? "",
                                                    "window": controller.umiIDString])
            UmiLayout.focusPane(pane, activate: true)
        } catch let error as UmiError {
            alert("Can't open \(url.lastPathComponent)", error.message)
        } catch {}
    }

    /// The pane `cd` and Insert Path type into: the focused pane when it's a terminal, else the
    /// tab's terminal used most recently.
    var terminalPane: Ghostty.SurfaceView? {
        guard let controller else { return nil }
        func isTerminal(_ pane: Ghostty.SurfaceView) -> Bool {
            !UmiFilePanes.shared.isFilePane(pane.id) && UmiAgentUI.shared.session(forPane: pane.id) == nil
        }
        if let pane = focusedPane, isTerminal(pane) { return pane }
        let panes = (controller.tree(of: controller.selectedTab).root?.leaves() ?? []).filter(isTerminal)
        return UmiFocusHistory.mostRecent(among: panes) ?? panes.first
    }

    /// The terminal `cd to Directory` types into: `terminalPane` while its shell is in front (no
    /// program runs there).
    var promptPane: Ghostty.SurfaceView? {
        guard let pane = terminalPane, UmiPaneContext.shellInFront(pane) else { return nil }
        return pane
    }

    /// Warp's "cd to directory": replaces what is typed at the prompt with `cd <folder>` and leaves
    /// it there, not run (⌃E ⌃U clear the line in zsh, bash and fish); focus goes to that terminal.
    func cd(to url: URL) {
        guard let pane = promptPane else { NSSound.beep(); return }
        try? UmiInput.send(keys: ["ctrl+e", "ctrl+u"], to: pane)
        Task { @MainActor in
            try? await UmiInput.send(text: "cd " + Ghostty.Shell.quote(url.path), to: pane, enter: false)
        }
        UmiLayout.focusPane(pane, activate: true)
    }

    func insertPath(_ url: URL) {
        guard let pane = terminalPane else { NSSound.beep(); return }
        Task { @MainActor in
            try? await UmiInput.send(text: Ghostty.Shell.quote(url.path) + " ", to: pane, enter: false)
        }
    }

    func relativePath(_ url: URL) -> String {
        guard let root else { return url.path }
        let rootPath = root.url.path
        if url.path == rootPath { return "." }
        return url.path.hasPrefix(rootPath + "/") ? String(url.path.dropFirst(rootPath.count + 1)) : url.path
    }

    /// Delete moves to the Trash (never permanently); Warp asks nothing either. Panes showing the
    /// item, or a file under it, close, as Warp closes the tabs showing a deleted file; unsaved
    /// edits there are kept as a recovery copy (E-3).
    func delete(_ url: URL) {
        let gone = Self.realURL(url).path
        let showing = UmiFilePanes.shared.open.filter { _, doc in
            let path = Self.realURL(doc.url).path
            return path == gone || path.hasPrefix(gone + "/")
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            alert("Can't move \(url.lastPathComponent) to the Trash", error.localizedDescription)
            return
        }
        for (pane, _) in showing { UmiFilePanes.closePane(pane) }
        if selected?.path == url.path { selected = nil }
        node(at: url.deletingLastPathComponent())?.loadChildren(force: true)
        rebuild()
    }

    // MARK: Inline editing (New File, Rename)

    func startNewFile(in folder: URL) {
        setExpanded(folder, true)
        editText = ""
        edit = .newFile(in: folder)
        rebuild()
        select(folder.appendingPathComponent("new_file"))
    }

    func startRename(_ url: URL) {
        guard url.path != root?.url.path else { return }
        editText = url.lastPathComponent
        edit = .rename(url)
        select(url)
    }

    /// Enter in the field, or leaving it: an empty name cancels (as in Warp and VS Code).
    func commitEdit() {
        guard let current = edit else { return }
        let name = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        edit = nil
        defer {
            rebuild()
            requestFocus()
        }
        guard !name.isEmpty else {
            if case .rename(let url) = current { select(url) }
            return
        }
        guard !name.contains("/") else {
            alert("Can't use that name", "A file name can't contain \"/\".")
            return
        }
        switch current {
        case .newFile(let folder):
            let url = folder.appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: url.path),
                  FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                alert("Can't create \(name)", "Something with that name is already there, or the folder can't be written.")
                return
            }
            node(at: folder)?.loadChildren(force: true)
            rebuild()
            select(url)
            if Self.isText(url) { openInEditor(url) }
        case .rename(let url):
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            guard target != url else { select(url); return }
            do {
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                alert("Can't rename \(url.lastPathComponent)", error.localizedDescription)
                return
            }
            node(at: url.deletingLastPathComponent())?.loadChildren(force: true)
            rebuild()
            select(target)
        }
    }

    func cancelEdit() {
        guard let current = edit else { return }
        edit = nil
        rebuild()
        if case .rename(let url) = current { select(url) } else { selected = nil }
        requestFocus()
    }

    private func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = controller?.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: The right-click menu

    /// Warp's items (New File, cd to Directory, Open in New Pane, Open in New Tab, Reveal in Finder,
    /// Rename, Delete, Copy Path, Copy Relative Path) with Umi's (Open with Default App, Insert
    /// Path in Terminal).
    func menuItems(for url: URL, isDirectory: Bool) -> [UmiTabMenuItem] {
        var items: [UmiTabMenuItem] = []
        if isDirectory {
            items.append(.init(title: "New File") { [weak self] in self?.startNewFile(in: url) })
            items.append(.divider)
            items.append(.init(title: "cd to Directory", enabled: promptPane != nil) { [weak self] in self?.cd(to: url) })
            items.append(.init(title: "Open in New Tab") { [weak self] in self?.openInNewTab(url, isDirectory: true) })
        } else {
            let editable = Self.isText(url)
            items.append(.init(title: "Open in New Pane", enabled: editable) { [weak self] in self?.openInEditor(url) })
            items.append(.init(title: "Open in New Tab", enabled: editable) { [weak self] in self?.openInNewTab(url, isDirectory: false) })
            items.append(.init(title: "Open with Default App") { [weak self] in self?.openWithDefaultApp(url) })
        }
        items.append(.init(title: "Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) })
        if url.path != root?.url.path {
            items.append(.init(title: "Rename") { [weak self] in self?.startRename(url) })
            items.append(.init(title: "Delete") { [weak self] in self?.delete(url) })
        }
        items.append(.divider)
        items.append(.init(title: "Insert Path in Terminal", enabled: terminalPane != nil) { [weak self] in self?.insertPath(url) })
        items.append(.divider)
        items.append(.init(title: "Copy Path") { UmiTabMenu.copy(url.path) })
        items.append(.init(title: "Copy Relative Path") { [weak self] in UmiTabMenu.copy(self?.relativePath(url) ?? url.path) })
        return items
    }

    // MARK: Tests (`debug.ui.files`)

    func json() -> [String: Any] {
        var json: [String: Any] = [
            "root": root?.url.path ?? "", "selected": selected?.path ?? "", "focused": hasFocus,
            "show_hidden": UmiState.shared.showHiddenFiles,
            "style": ["font_size": Double(UmiFileTreeStyle.fontSize), "indent": Double(UmiFileTreeStyle.indent),
                      "row_height": Double(UmiFileTreeStyle.rowHeight), "icon": Double(UmiFileTreeStyle.iconSize),
                      "selected_fill": UmiFileTreeStyle.selectedOpacity, "hover_fill": UmiFileTreeStyle.hoverOpacity],
            "rows": rows.map { row -> [String: Any] in
                ["path": row.url.path, "name": row.url.lastPathComponent, "depth": row.depth, "dir": row.isDirectory,
                 "expanded": row.expanded, "selected": row.kind == .item && row.url == selected,
                 "ignored": row.ignored, "editing": row.kind == .newFile || edit == .rename(row.url),
                 "new_file": row.kind == .newFile,
                 // The asset shown, and whether the app has it.
                 "icon": row.isDirectory ? "folder" : UmiFileIcons.assetName(for: row.url),
                 "icon_loaded": row.isDirectory || NSImage(named: UmiFileIcons.assetName(for: row.url)) != nil]
            },
        ]
        switch edit {
        case .rename(let url): json["edit"] = ["kind": "rename", "path": url.path, "text": editText]
        case .newFile(let url): json["edit"] = ["kind": "new_file", "path": url.path, "text": editText]
        case nil: json["edit"] = NSNull()
        }
        if root == nil { json["empty"] = UmiFileTreeView.unavailableTitle }
        return json
    }
}

/// Warp's numbers for the explorer's rows.
enum UmiFileTreeStyle {
    static let fontSize: CGFloat = 14
    static let indent: CGFloat = 16
    static let iconSize: CGFloat = 16
    static let verticalPadding: CGFloat = 4
    /// 16 pt icon or the 14 pt line (17 pt), plus 4 pt above and below.
    static let rowHeight: CGFloat = 25
    /// The selected row: foreground at 20% (Warp's `fg_overlay_4`), hover at 10% (`fg_overlay_2`).
    static let selectedOpacity = 0.20
    static let hoverOpacity = 0.10

    static var ink: Color { UmiTheme.isLight ? .black : .white }
    /// Text: 60% normally, 90% under the pointer, full when selected (Warp's text_sub, text_main).
    static func text(selected: Bool, hovering: Bool) -> Color {
        selected ? ink : ink.opacity(hovering ? 0.9 : 0.6)
    }
    static func fill(selected: Bool, hovering: Bool) -> Color {
        selected ? ink.opacity(selectedOpacity) : (hovering ? ink.opacity(hoverOpacity) : .clear)
    }
}

// MARK: - Views

/// The project explorer in the sidebar.
struct UmiFileTreeView: View {
    @ObservedObject var model: UmiFileTreeModel
    @ObservedObject private var state = UmiState.shared

    static let unavailableTitle = "Project explorer unavailable"
    static let unavailableText = "The Project Explorer requires access to your local workspace. Open a new session or navigate to an active session to view."

    var body: some View {
        Group {
            if model.root != nil {
                ScrollViewReader { proxy in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.rows) { row in
                            UmiFileRow(model: model, row: row).id(row.id)
                        }
                    }
                    .onChange(of: model.scrollTick) { _ in
                        guard let id = model.selectedRow?.id else { return }
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id) }
                    }
                }
                .background(UmiKeyCatcher(model: model))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Project Explorer")
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 20))
                        .foregroundColor(UmiFileTreeStyle.ink.opacity(0.4))
                    Text(Self.unavailableTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(UmiFileTreeStyle.ink.opacity(0.6))
                    Text(Self.unavailableText)
                        .font(.system(size: 14))
                        .multilineTextAlignment(.center)
                        .foregroundColor(UmiFileTreeStyle.ink.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .padding(.top, 24)
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

private struct UmiFileRow: View {
    @ObservedObject var model: UmiFileTreeModel
    let row: UmiFileTreeModel.Row
    @State private var hovering = false

    var body: some View {
        let selected = row.kind == .item && model.selected == row.url
        let editing = row.kind == .newFile || model.edit == .rename(row.url)
        let color = UmiFileTreeStyle.text(selected: selected, hovering: hovering)
        HStack(spacing: 0) {
            Group {
                if row.isDirectory {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(color)
                } else {
                    Color.clear
                }
            }
            .frame(width: UmiFileTreeStyle.iconSize, height: UmiFileTreeStyle.iconSize)
            .padding(.trailing, 4)
            Group {
                if row.isDirectory {
                    Image(systemName: "folder")
                        .font(.system(size: UmiFileTreeStyle.iconSize * 0.78))
                        .foregroundColor(color)
                        .frame(width: UmiFileTreeStyle.iconSize, height: UmiFileTreeStyle.iconSize)
                        .accessibilityHidden(true)
                } else {
                    UmiFileIcon(url: row.url, size: UmiFileTreeStyle.iconSize)
                }
            }
            .padding(.trailing, 8)
            if editing {
                UmiTextInput(text: $model.editText, placeholder: "", fontSize: UmiFileTreeStyle.fontSize,
                             focusOnAppear: true, accessibilityLabel: row.kind == .newFile ? "New File Name" : "Rename",
                             onKey: { key in
                                 switch key {
                                 case .enter: model.commitEdit()
                                 case .escape: model.cancelEdit()
                                 default: return false
                                 }
                                 return true
                             },
                             onEndEditing: { if model.edit != nil { model.commitEdit() } })
            } else {
                Text(row.url.lastPathComponent)
                    .font(.system(size: UmiFileTreeStyle.fontSize, weight: row.ignored ? .light : .regular))
                    .italic(row.ignored)
                    .foregroundColor(color)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * UmiFileTreeStyle.indent + 8)
        .padding(.trailing, 8)
        .padding(.vertical, UmiFileTreeStyle.verticalPadding)
        .frame(minHeight: UmiFileTreeStyle.rowHeight)
        .background(RoundedRectangle(cornerRadius: 4).fill(UmiFileTreeStyle.fill(selected: selected, hovering: hovering)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard row.kind == .item, !editing else { return }
            model.requestFocus()
            model.activate(row.url)
        }
        .contextMenu {
            if row.kind == .item {
                UmiTabMenuView(items: model.menuItems(for: row.url, isDirectory: row.isDirectory))
            }
        }
        .help(row.url.path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.url.lastPathComponent)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }
}

/// An invisible view behind the tree that takes keyboard focus and hands keys to the model.
private struct UmiKeyCatcher: NSViewRepresentable {
    @ObservedObject var model: UmiFileTreeModel

    func makeNSView(context: Context) -> UmiKeyCatcherView {
        let view = UmiKeyCatcherView()
        view.onKey = { [weak model] event in model?.handleKey(event) ?? false }
        model.keyView = view
        return view
    }

    func updateNSView(_ view: UmiKeyCatcherView, context: Context) {
        _ = model.focusTick
        model.keyView = view
        view.onKey = { [weak model] event in model?.handleKey(event) ?? false }
        view.wantsFocus = { [weak model] in
            guard let model, model.pendingFocus else { return false }
            model.pendingFocus = false
            return true
        }
        view.takeFocusIfWanted()
    }
}

final class UmiKeyCatcherView: NSView {
    var onKey: (NSEvent) -> Bool = { _ in false }
    var wantsFocus: () -> Bool = { false }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { super.keyDown(with: event) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfWanted()
    }

    func takeFocusIfWanted() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.wantsFocus() else { return }
            window.makeFirstResponder(self)
        }
    }
}

/// A one-line text field for the sidebar (the explorer's inline names, global search's query)
/// that reports ↑ ↓ Enter Esc and takes focus when shown or asked.
struct UmiTextInput: NSViewRepresentable {
    enum Key { case up, down, enter, escape }

    @Binding var text: String
    var placeholder: String
    var fontSize: CGFloat
    /// Take focus when the field appears.
    var focusOnAppear = false
    /// Asked on every update: true once when the field should take focus.
    var claimFocus: () -> Bool = { false }
    var accessibilityLabel: String
    var onKey: (Key) -> Bool = { _ in false }
    var onEndEditing: () -> Void = {}
    var onMake: (UmiTextInputField) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> UmiTextInputField {
        let field = UmiTextInputField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.delegate = context.coordinator
        field.stringValue = text
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = UmiTheme.textNSColor
        field.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: UmiTheme.textNSColor.withAlphaComponent(0.4)])
        field.setAccessibilityLabel(accessibilityLabel)
        field.wantsFocus = focusOnAppear
        field.claimFocus = claimFocus
        onMake(field)
        return field
    }

    func updateNSView(_ field: UmiTextInputField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.textColor = UmiTheme.textNSColor
        field.claimFocus = claimFocus
        field.takeFocusIfWanted()
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: UmiTextInput

        init(_ parent: UmiTextInput) { self.parent = parent }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): return parent.onKey(.up)
            case #selector(NSResponder.moveDown(_:)): return parent.onKey(.down)
            case #selector(NSResponder.insertNewline(_:)): return parent.onKey(.enter)
            case #selector(NSResponder.cancelOperation(_:)): return parent.onKey(.escape)
            default: return false
            }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            parent.onEndEditing()
        }
    }
}

final class UmiTextInputField: NSTextField {
    var wantsFocus = false
    var claimFocus: () -> Bool = { false }

    /// Whether the field is being edited (its field editor has focus).
    var isEditingNow: Bool {
        guard let editor = window?.firstResponder as? NSTextView else { return false }
        return (editor.delegate as AnyObject?) === self
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        takeFocusIfWanted()
    }

    func takeFocusIfWanted() {
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, self.wantsFocus || self.claimFocus() else { return }
            self.wantsFocus = false
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}

/// What the sidebar's keys do (⇧⌘E and ⌃1, ⇧⌘F and ⌃3): show the explorer or global search with
/// keyboard focus in it, or, when it is already shown, go back to Tabs and the pane.
@MainActor
enum UmiSidebarKeys {
    static func toggleExplorer() {
        let state = UmiState.shared
        guard let window = UmiTopology.currentWindow else { return }
        let model = UmiFileTreeModel.model(for: window)
        if window.sidebarVisible && state.sidebarMode == .files {
            let hadFocus = model.hasFocus
            state.sidebarMode = .tabs
            if hadFocus { model.focusPane() }
        } else {
            state.sidebarMode = .files
            UmiSidebarVisibility.set(true, in: window)
            model.requestFocus()
        }
    }

    /// ⇧⌘F: show global search with the query focused (its text selected).
    static func openSearch() {
        let state = UmiState.shared
        guard let window = UmiTopology.currentWindow else { return }
        state.sidebarMode = .search
        UmiSidebarVisibility.set(true, in: window)
        let model = UmiGlobalSearchModel.model(for: window)
        model.updateRoot()
        model.focusQuery()
    }

    /// ⌃3: show global search, or hide it when it's shown.
    static func toggleSearch() {
        let state = UmiState.shared
        guard let window = UmiTopology.currentWindow else { return }
        if window.sidebarVisible && state.sidebarMode == .search {
            let model = UmiGlobalSearchModel.model(for: window)
            let hadFocus = model.focus != .none
            state.sidebarMode = .tabs
            if hadFocus { model.focusPane() }
        } else {
            openSearch()
        }
    }
}

/// `debug.ui.files*` and `debug.ui.search*` (internal, for the acceptance tests): the explorer's
/// and global search's state, and the explorer's right-click menu, which otherwise needs a mouse.
@MainActor
enum UmiFileTreeDebug {
    static func handle(_ method: String, _ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let window = try UmiTopology.window(params.string("window"), caller: caller)
        switch method {
        case "debug.ui.files":
            let model = UmiFileTreeModel.model(for: window)
            if params.bool("update") ?? false { model.update() }
            return model.json()

        case "debug.ui.files.menu", "debug.ui.files.menu.perform":
            let model = UmiFileTreeModel.model(for: window)
            guard let path = params.string("path") else { throw UmiError.badRequest("give the item's path") }
            let url = UmiFileTreeModel.realURL(URL(fileURLWithPath: path))
            guard let row = model.rows.first(where: { $0.url.path == url.path && $0.kind == .item }) else {
                throw UmiError.notFound("the explorer shows no \(path)")
            }
            let items = UmiTabMenu.flatten(model.menuItems(for: row.url, isDirectory: row.isDirectory))
            if method == "debug.ui.files.menu" {
                return ["items": items.map { ["title": $0.item.title, "enabled": $0.item.enabled] }]
            }
            guard let title = params.string("title") else { throw UmiError.badRequest("give the item's title") }
            guard let entry = items.first(where: { $0.item.title == title }) else {
                throw UmiError.notFound("no menu item \"\(title)\"")
            }
            guard entry.item.enabled, let action = entry.item.action else {
                throw UmiError.failed("the menu item \"\(title)\" is disabled")
            }
            // A right-click selects the row, as in Warp. Copies go to a private pasteboard.
            model.select(row.url)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.umi.debug.\(UmiPaths.instanceID)"))
            pasteboard.clearContents()
            UmiTabMenu.pasteboard = pasteboard
            defer { UmiTabMenu.pasteboard = .general }
            action()
            return ["performed": title, "copied": pasteboard.string(forType: .string) ?? ""]

        case "debug.ui.search":
            return UmiGlobalSearchModel.model(for: window).json()

        case "debug.ui.search.toggle":
            // What a click on the case or regex button does.
            let model = UmiGlobalSearchModel.model(for: window)
            switch params.string("name") {
            case "case": model.caseSensitive.toggle()
            case "regex": model.regex.toggle()
            default: throw UmiError.badRequest("name is case or regex")
            }
            return model.json()

        default:
            throw UmiError.badRequest("unknown method \(method)")
        }
    }
}

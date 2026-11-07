import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Reading and writing text files

/// What the editor can open safely, and in which encoding (E-5, E-6).
enum UmiTextFile {
    /// Files larger than this are refused (the editor holds the whole file in memory).
    static let sizeLimit = 16 * 1024 * 1024

    struct Loaded {
        let text: String
        let encoding: String.Encoding
        /// A byte-order mark the file started with, written back on save.
        let bom: Data
    }

    /// Check a path without opening it in a way that could block (FIFOs, devices).
    static func checkOpenable(_ url: URL) throws {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            throw UmiError.notFound("no such file: \(url.path)")
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            break
        case S_IFDIR:
            throw UmiError.badRequest("\(url.path) is a folder, not a file")
        case S_IFIFO:
            throw UmiError.badRequest("\(url.path) is a named pipe (FIFO); the editor only opens regular files")
        case S_IFCHR, S_IFBLK:
            throw UmiError.badRequest("\(url.path) is a device; the editor only opens regular files")
        case S_IFSOCK:
            throw UmiError.badRequest("\(url.path) is a socket; the editor only opens regular files")
        default:
            throw UmiError.badRequest("\(url.path) isn't a regular file")
        }
        if Int(st.st_size) > sizeLimit {
            let mb = Double(st.st_size) / 1_048_576
            throw UmiError.badRequest(String(format: "%@ is too large for the editor (%.0f MB; the limit is %d MB)",
                                              url.lastPathComponent, mb, sizeLimit / 1_048_576))
        }
    }

    static func read(_ url: URL) throws -> Loaded {
        try checkOpenable(url)
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw UmiError.failed("can't read \(url.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = (try? handle.readToEnd()) ?? Data()
        guard data.count <= sizeLimit else {
            throw UmiError.badRequest("\(url.lastPathComponent) is too large for the editor")
        }
        return try decode(data, name: url.lastPathComponent)
    }

    static func decode(_ data: Data, name: String) throws -> Loaded {
        // Byte-order marks.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard let text = String(data: data.dropFirst(3), encoding: .utf8) else { throw binary(name) }
            return Loaded(text: text, encoding: .utf8, bom: Data([0xEF, 0xBB, 0xBF]))
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            let little = data.starts(with: [0xFF, 0xFE])
            let encoding: String.Encoding = little ? .utf16LittleEndian : .utf16BigEndian
            guard let text = String(data: data.dropFirst(2), encoding: encoding) else { throw binary(name) }
            return Loaded(text: text, encoding: encoding, bom: Data(data.prefix(2)))
        }
        // A sample decides text or binary: NUL bytes mean binary. The sample may end in
        // the middle of a multi-byte character, which is fine.
        let sample = data.prefix(8192)
        if sample.contains(0) { throw binary(name) }
        if let text = String(data: data, encoding: .utf8) {
            return Loaded(text: text, encoding: .utf8, bom: Data())
        }
        let utf8Sample = (0...min(3, sample.count)).contains { trim in
            String(data: sample.dropLast(trim), encoding: .utf8) != nil
        }
        if utf8Sample && data.count > sample.count {
            // Valid at the start but not overall: not something to edit as text safely.
            throw UmiError.badRequest("\(name) isn't valid UTF-8 text; the editor won't risk changing it")
        }
        // Not UTF-8: a legacy single-byte text file (Latin-1), unless it's full of control
        // characters, which means binary.
        let controls = sample.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains($0) }.count
        if sample.isEmpty || Double(controls) / Double(sample.count) > 0.02 { throw binary(name) }
        guard let text = String(data: data, encoding: .isoLatin1) else { throw binary(name) }
        return Loaded(text: text, encoding: .isoLatin1, bom: Data())
    }

    private static func binary(_ name: String) -> UmiError {
        UmiError.badRequest("\(name) looks like a binary file; the editor only opens text")
    }

    static func encodingName(_ encoding: String.Encoding) -> String {
        switch encoding {
        case .utf8: return "UTF-8"
        case .isoLatin1: return "Latin-1 (ISO-8859-1)"
        case .utf16LittleEndian, .utf16BigEndian, .utf16: return "UTF-16"
        default: return String.localizedName(of: encoding)
        }
    }

    /// Write text in the file's own encoding, or refuse if it can't be represented: a
    /// file is never silently converted (E-5). Keeps the file's permissions.
    static func write(_ text: String, to url: URL, encoding: String.Encoding, bom: Data) throws {
        guard let body = text.data(using: encoding, allowLossyConversion: false) else {
            throw UmiError.failed("can't save \(url.lastPathComponent) in \(encodingName(encoding)) without losing characters; the file was left unchanged")
        }
        var data = bom
        data.append(body)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).umi-\(UUID().uuidString.prefix(8))")
        do {
            try data.write(to: temp, options: [])
            if fm.fileExists(atPath: url.path) {
                if let attributes = try? fm.attributesOfItem(atPath: url.path),
                   let permissions = attributes[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
                }
                _ = try fm.replaceItemAt(url, withItemAt: temp, backupItemName: nil, options: [.usingNewMetadataOnly])
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            // Fall back to writing in place (e.g. a folder we can't create files in).
            do {
                try data.write(to: url, options: [])
            } catch {
                throw UmiError.failed("couldn't save \(url.path): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Documents

/// One open file.
@MainActor
final class UmiDocument: ObservableObject, Identifiable {
    enum Mode: String { case preview, source }

    let id = UUID()
    let url: URL
    @Published var text: String {
        didSet { isDirty = text != savedText }
    }
    @Published private(set) var isDirty = false
    @Published var mode: Mode {
        didSet { if mode != oldValue { UmiState.shared.layoutDidChange() } }
    }
    /// The file changed on disk while there were unsaved edits.
    @Published var changedOnDisk = false
    @Published var error: String?
    /// Bumped when the preview should re-render (e.g. reloaded from disk).
    @Published private(set) var renderRevision = 0
    /// A line to show and put the cursor on (1-based), from the quick file search's
    /// `path:line`. The source view clears it once shown.
    @Published var revealLine: Int?
    /// With `revealLine`: where in the line the cursor goes (UTF-16 offset from the line's start),
    /// from global search's match. Cleared with `revealLine`.
    var revealColumn: Int?
    /// How many agents wait for the user to finish commenting (`umi comments wait`, E-11).
    @Published var reviewWaiters = 0
    /// The shown view, which starts a comment on its selection (E-11).
    weak var commentTarget: UmiCommentTarget?
    /// The source view's find, go to line and comments (E-21 to E-23), while it's shown.
    weak var code: UmiCodeEditor?

    private(set) var encoding: String.Encoding
    private var bom: Data
    private var savedText: String
    private var watcher: DispatchSourceFileSystemObject?
    private var reappearTimer: Timer?
    private var pendingCheck: DispatchWorkItem?
    let undoManager = UndoManager()

    var isMarkdown: Bool { UmiEditor.isMarkdown(url) }
    /// Markdown, JSON and CSV/TSV have a rendered view besides the source.
    var hasPreview: Bool { UmiEditor.hasPreview(url) }
    var name: String { url.lastPathComponent }

    init(url: URL, mode: Mode? = nil) throws {
        self.url = url
        let loaded = try UmiTextFile.read(url)
        self.text = loaded.text
        self.savedText = loaded.text
        self.encoding = loaded.encoding
        self.bom = loaded.bom
        self.mode = mode.flatMap { UmiEditor.hasPreview(url) ? $0 : .source } ?? (UmiEditor.hasPreview(url) ? .preview : .source)
        watch()
    }

    deinit {
        watcher?.cancel()
        reappearTimer?.invalidate()
    }

    /// Whether the file on disk still matches what we last loaded or saved.
    var diskMatchesBaseline: Bool {
        (try? UmiTextFile.read(url).text) == savedText
    }

    func toggleMode() {
        guard hasPreview else { return }
        mode = mode == .preview ? .source : .preview
    }

    @discardableResult
    func save() -> Bool {
        do {
            try UmiTextFile.write(text, to: url, encoding: encoding, bom: bom)
            savedText = text
            isDirty = false
            changedOnDisk = false
            error = nil
            watch()
            UmiEvents.shared.emit("editor.saved", ["path": url.path])
            return true
        } catch let e as UmiError {
            error = e.message
            NSSound.beep()
            return false
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Write the text to another file, in this document's encoding (Save As, E-23).
    func write(to other: URL) throws {
        try UmiTextFile.write(text, to: other, encoding: encoding, bom: bom)
    }

    func reload() {
        do {
            let loaded = try UmiTextFile.read(url)
            encoding = loaded.encoding
            bom = loaded.bom
            savedText = loaded.text
            text = loaded.text
            // The history's steps point into the old text: ⌘Z after a reload must not replay them.
            undoManager.removeAllActions()
            isDirty = false
            changedOnDisk = false
            error = nil
            renderRevision &+= 1
            watch()
            UmiEvents.shared.emit("editor.reloaded", ["path": url.path])
        } catch let e as UmiError {
            error = "Reload failed: \(e.message)"
            watch()
        } catch {
            self.error = "Reload failed: \(error.localizedDescription)"
            watch()
        }
    }

    /// The file now holds `saved` (written by a comment change): it's the new baseline.
    func adoptSaved(_ saved: String, encoding: String.Encoding, bom: Data) {
        self.encoding = encoding
        self.bom = bom
        savedText = saved
        isDirty = text != savedText
        error = nil
        watch()
    }

    // MARK: Watching the file

    /// Follow external changes (E-4): reload when clean, flag when dirty. The watcher
    /// follows an inode, so it's re-armed after every change (editors often replace files),
    /// and while the path is missing the document polls for it to come back.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        reappearTimer?.invalidate()
        reappearTimer = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            waitForFile()
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend, .attrib, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleCheck() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// Coalesce bursts of events (truncate, then write).
    private func scheduleCheck() {
        pendingCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fileChanged() }
        }
        pendingCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func fileChanged() {
        guard FileManager.default.fileExists(atPath: url.path) else {
            waitForFile()
            return
        }
        guard let loaded = try? UmiTextFile.read(url) else {
            watch()
            return
        }
        if loaded.text == savedText {
            // Our own save, or nothing that matters.
            watch()
            return
        }
        if isDirty {
            changedOnDisk = true
            watch()
        } else {
            reload()
        }
    }

    private func waitForFile() {
        watcher?.cancel()
        watcher = nil
        guard reappearTimer == nil else { return }
        reappearTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, FileManager.default.fileExists(atPath: self.url.path) else { return }
                self.reappearTimer?.invalidate()
                self.reappearTimer = nil
                self.fileChanged()
            }
        }
    }

    /// Unsaved edits: save them if the file on disk is still what we loaded, else keep a
    /// recovery copy. Never loses edits silently (E-3).
    func preserveEdits() {
        guard isDirty else { return }
        if !changedOnDisk && diskMatchesBaseline && save() { return }
        let dir = UmiPaths.directory("recovery")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = (dir as NSString).appendingPathComponent("\(stamp)-\(id.uuidString.prefix(8))-\(name)")
        try? text.write(toFile: backup, atomically: true, encoding: .utf8)
        UmiEvents.shared.emit("editor.recovered", ["path": url.path, "backup": backup])
    }
}

// MARK: - Opening and the CLI

@MainActor
enum UmiEditor {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    /// Scripts keep Ghostty's behavior of being executed when opened from Finder.
    static let executableScriptExtensions: Set<String> = ["sh", "zsh", "bash", "csh", "fish", "command", "tool", "pl"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    static func hasPreview(_ url: URL) -> Bool { isMarkdown(url) || UmiDataPreview.handles(url) }

    /// Whether files opened from Finder (or `open`) go to the editor.
    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if executableScriptExtensions.contains(ext) { return false }
        if markdownExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .plainText) || type.conforms(to: .sourceCode) {
            return true
        }
        if ["txt", "text", "log", "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "csv", "tsv"].contains(ext) {
            return true
        }
        return ext.isEmpty && (try? UmiTextFile.read(url)) != nil
    }

    /// The tab an editor request is about: an explicit pane or tab (which must exist),
    /// else the caller's tab, else the focused tab (E-9).
    static func targetTab(_ params: UmiParams, caller: UmiCaller, createWindow: Bool) throws -> (TerminalController, UmiTab) {
        if let pane = params.string("pane") {
            let surface = try UmiTopology.resolvePane(pane, caller: caller)
            guard let location = UmiTopology.locate(surface) else { throw UmiError.notFound("the pane isn't in a window") }
            return (location.window, location.tab)
        }
        if let tab = params.string("tab") {
            return try UmiTopology.resolveTab(tab, caller: caller)
        }
        if let callerPane = try UmiTopology.callerPane(caller), let location = UmiTopology.locate(callerPane) {
            return (location.window, location.tab)
        }
        if let window = UmiTopology.currentWindow { return (window, window.selectedTab) }
        guard createWindow, let ghostty = UmiLayout.ghostty else { throw UmiError.notFound("no Umi windows are open") }
        let window = TerminalController.newWindow(ghostty)
        return (window, window.selectedTab)
    }

    /// The pane a file opened by a request goes beside (E-9): an explicit pane, else the focused
    /// pane of an explicit tab (both must exist), else the caller's pane, else the focused pane.
    static func anchorPane(_ params: UmiParams, caller: UmiCaller) throws -> Ghostty.SurfaceView {
        if let pane = params.string("pane") { return try UmiTopology.resolvePane(pane, caller: caller) }
        if let tab = params.string("tab") {
            let (_, found) = try UmiTopology.resolveTab(tab, caller: caller)
            guard let pane = found.effectiveFocusedSurface else { throw UmiError.notFound("that tab has no panes") }
            return pane
        }
        if let callerPane = try UmiTopology.callerPane(caller) { return callerPane }
        let (_, tab) = try targetTab(params, caller: caller, createWindow: true)
        guard let pane = tab.effectiveFocusedSurface else { throw UmiError.notFound("no Umi windows are open") }
        return pane
    }

    /// `edit FILE…`: each file in a pane of its own, the first beside the anchor pane and each
    /// next one beside the one before, three panes to a tab (E-1, E-9). Keyboard focus stays
    /// where it is.
    static func handleOpen(_ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        guard let paths = params.strings("paths"), !paths.isEmpty else { throw UmiError.badRequest("edit: name a file") }
        let mode = params.string("mode").flatMap(UmiDocument.Mode.init(rawValue:))
        // Check every file and URL first: a refusal changes nothing. A URL opens in a web pane
        // when its origin is in `umi-web-origin` (E-12).
        for path in paths {
            if let url = webURL(path) {
                guard UmiWebPanes.handles(url) else {
                    throw UmiError.badRequest("\(path): its origin isn't an umi-web-origin in \(UmiPaths.userConfigFile)")
                }
            } else {
                try UmiTextFile.checkOpenable(URL(fileURLWithPath: path))
            }
        }
        var anchor = try anchorPane(params, caller: caller)
        var opened: [[String: Any]] = []
        var pages: [[String: Any]] = []
        for path in paths {
            if let url = webURL(path) {
                let (pane, page) = try UmiWebPanes.open(url, near: anchor, focus: false)
                pages.append(["url": page.url.absoluteString, "pane": pane.umiID])
                anchor = pane
                continue
            }
            let (pane, doc) = try UmiFilePanes.open(URL(fileURLWithPath: path), mode: mode, near: anchor, focus: false)
            opened.append(json(doc, pane: pane))
            anchor = pane
        }
        let location = UmiTopology.locate(anchor)
        return ["documents": opened, "pages": pages, "tab": location?.tab.idString ?? "",
                "window": location?.window.umiIDString ?? ""]
    }

    /// An http(s) URL given to `edit` in place of a file.
    private static func webURL(_ path: String) -> URL? {
        let lower = path.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return nil }
        return URL(string: path)
    }

    static func handleList(_ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let (window, tab) = try targetTab(params, caller: caller, createWindow: false)
        return ["documents": tab.editor.files.map { json($0.doc, pane: $0.pane) }, "tab": tab.idString,
                "window": window.umiIDString, "active": tab.editor.active?.url.path ?? ""]
    }

    /// The document a request names (`path`) or, without one, the tab's active one.
    private static func document(_ params: UmiParams, in tab: UmiTab) throws -> UmiDocument {
        if let path = params.string("path") {
            guard let found = tab.editor.document(for: URL(fileURLWithPath: path)) else {
                throw UmiError.notFound("\(path) isn't open in that tab")
            }
            return found
        }
        guard let active = tab.editor.active else { throw UmiError.notFound("no file is open in that tab") }
        return active
    }

    static func handleClose(_ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let (_, tab) = try targetTab(params, caller: caller, createWindow: false)
        let doc = try document(params, in: tab)
        if doc.isDirty && !(params.bool("force") ?? false) {
            throw UmiError.badRequest("\(doc.name) has unsaved changes; save it first or use --force to discard them")
        }
        tab.editor.close(doc, discarding: true)   // dirty only with --force
        return ["path": doc.url.path, "closed": true]
    }

    static func handleMode(_ params: UmiParams, caller: UmiCaller) throws -> [String: Any] {
        let (_, tab) = try targetTab(params, caller: caller, createWindow: false)
        let doc = try document(params, in: tab)
        if let raw = params.string("mode") {
            guard let mode = UmiDocument.Mode(rawValue: raw) else { throw UmiError.badRequest("use preview or source") }
            guard doc.hasPreview || mode == .source else {
                throw UmiError.badRequest("\(doc.name) has no preview; it only has a source view")
            }
            doc.mode = mode
        } else {
            guard doc.hasPreview else { throw UmiError.badRequest("\(doc.name) has no preview; it only has a source view") }
            doc.toggleMode()
        }
        return json(doc, pane: tab.editor.pane(of: doc))
    }

    static func json(_ doc: UmiDocument, pane: Ghostty.SurfaceView? = nil) -> [String: Any] {
        var json: [String: Any] = ["path": doc.url.path, "mode": doc.mode.rawValue, "dirty": doc.isDirty,
                                   "encoding": UmiTextFile.encodingName(doc.encoding), "changed_on_disk": doc.changedOnDisk]
        if let pane { json["pane"] = pane.umiID }
        return json
    }

    /// Open a file from Finder or `open FILE` (Umi is the default Markdown app), bringing it
    /// forward: Markdown in the docs tab (`UmiDocsTab`), other files in the tab whose folder is
    /// closest to the file, else in a new tab (E-10). The
    /// Open panel (`inCurrentTab`) opens in the current tab, where the person asked.
    @discardableResult
    static func openFromSystem(_ url: URL, inCurrentTab: Bool = false) -> Bool {
        do {
            try open(url, inCurrentTab: inCurrentTab)
            return true
        } catch let error as UmiError {
            let alert = NSAlert()
            alert.messageText = "Can't open \(url.lastPathComponent)"
            alert.informativeText = error.message
            alert.runModal()
            return false
        } catch {
            return false
        }
    }

    /// Open a file from outside Umi (see `openFromSystem`); returns where it opened.
    @discardableResult
    static func open(_ url: URL, inCurrentTab: Bool) throws -> (TerminalController, UmiTab) {
        try UmiTextFile.checkOpenable(url)
        if !inCurrentTab, isMarkdown(url) { return try UmiDocsTab.open(url) }
        let (_, tab) = inCurrentTab
            ? try targetTab(UmiParams([:]), caller: UmiCaller([:]), createWindow: true)
            : try closestTab(to: url)
        let pane = try tab.editor.open(url, mode: nil, focus: true).pane
        guard let location = UmiTopology.locate(pane) else { throw UmiError.failed("the file's pane went away") }
        return (location.window, location.tab)
    }

    /// The tab a file from outside Umi opens in (E-10):
    /// 1. a tab where it is already open;
    /// 2. else the tab with a pane whose folder is the deepest one containing the file. Every
    ///    pane of a tab counts, not only the focused one; `/` doesn't count. Ties go to the
    ///    current tab, then the current window's tabs in sidebar order, then the other
    ///    windows' (oldest window first);
    /// 3. else a new tab in the file's folder, in the current window (a new window if none).
    static func closestTab(to url: URL) throws -> (TerminalController, UmiTab) {
        let file = canonicalPath(url.path)
        let current = UmiTopology.currentWindow
        var candidates: [(TerminalController, UmiTab)] = []
        if let current {
            candidates.append((current, current.selectedTab))
            candidates += current.tabs.filter { $0 !== current.selectedTab }.map { (current, $0) }
        }
        for window in UmiTopology.windows where window !== current {
            candidates += window.tabs.map { (window, $0) }
        }
        if let open = candidates.first(where: { $0.1.editor.document(for: url) != nil }) { return open }

        var best: (window: TerminalController, tab: UmiTab, depth: Int)?
        for (window, tab) in candidates {
            for pane in UmiTopology.panes(of: tab, in: window) {
                let folder = canonicalPath(UmiTopology.cwd(of: pane))
                guard folder != "/", !folder.isEmpty, file.hasPrefix(folder + "/") else { continue }
                let depth = folder.split(separator: "/").count
                if depth > (best?.depth ?? 0) { best = (window, tab, depth) }
            }
        }
        if let best { return (best.window, best.tab) }

        // No tab is in or above the file's folder: a new tab there. It's made in the background and
        // `open` then shows it, so it goes where a new tab the user goes to opens (S-7).
        var options = UmiLayout.PaneOptions()
        options.cwd = url.deletingLastPathComponent().path
        let created: [String: Any]
        if let current {
            created = try UmiLayout.newTab(in: current, options: options, tabName: nil, color: .none,
                                            index: current.newTabIndex(selecting: true) + 1, focus: false,
                                            inheritFrom: nil)
        } else {
            created = try UmiLayout.newWindow(options, tabName: nil, focus: false)
        }
        guard let windowID = created["window"] as? String, let tabID = created["tab"] as? String,
              let window = UmiTopology.windows.first(where: { $0.umiIDString == windowID }),
              let tab = window.tabs.first(where: { $0.idString == tabID }) else {
            throw UmiError.failed("couldn't make a tab for \(url.lastPathComponent)")
        }
        return (window, tab)
    }

    /// A path with symlinks resolved (/tmp and /private/tmp are one folder).
    private static func canonicalPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    /// The focused pane's document (for menu commands).
    static var currentDocument: UmiDocument? {
        UmiTopology.currentPane.flatMap { UmiFilePanes.shared.document(of: $0) }
    }

    /// The focused pane's source view (find, go to line, comments), when it shows one.
    static var currentCode: UmiCodeEditor? {
        guard let doc = currentDocument, doc.mode == .source else { return nil }
        return doc.code
    }

    /// ⌘F, ⌘G and ⇧⌘G (Umi's Edit items): a rendered Markdown preview has its own find bar
    /// (MD-4), which gets the key; any other file pane finds in its source (E-22).
    static func find(previewAction: Selector, inSource body: @escaping (UmiCodeEditor) -> Void) {
        if let doc = currentDocument, doc.isMarkdown, doc.mode == .preview, let web = focusedPreview {
            NSApp.sendAction(previewAction, to: web, from: nil)
            return
        }
        inSource(body)
    }

    /// The preview in the focused file pane, if it shows one.
    static var focusedPreview: UmiPreviewWebView? {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return nil }
        var view: NSView? = responder
        while let current = view, !(current is UmiEditorContainerView) {
            if let web = current as? UmiPreviewWebView { return web }
            view = current.superview
        }
        guard let container = view else { return nil }
        func search(_ view: NSView) -> UmiPreviewWebView? {
            if let web = view as? UmiPreviewWebView { return web }
            for sub in view.subviews { if let web = search(sub) { return web } }
            return nil
        }
        return search(container)
    }

    /// Run `body` on the focused file pane's source view, switching a preview (JSON, CSV, or
    /// Markdown for ⌥⌘F) to its source first (E-22).
    static func inSource(_ body: @escaping (UmiCodeEditor) -> Void) {
        guard let doc = currentDocument else { return }
        if doc.mode == .source, let code = doc.code { return body(code) }
        let stale = doc.code
        doc.mode = .source
        // The source view is built on SwiftUI's next pass.
        func attempt(_ left: Int) {
            if doc.mode == .source, let code = doc.code, code !== stale, code.textView?.window != nil { return body(code) }
            guard left > 0 else { return NSSound.beep() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { MainActor.assumeIsolated { attempt(left - 1) } }
        }
        attempt(50)
    }

    /// True when keyboard focus is in an editor view.
    static var editorHasFocus: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        while let current = view {
            if current is UmiEditorContainerView { return true }
            view = current.superview
        }
        return false
    }

    /// ⌘S (and Overwrite): save and say so, as Warp's "File saved." toast does (E-23).
    @discardableResult
    static func saveFromUser(_ doc: UmiDocument) -> Bool {
        guard doc.save() else { return false }
        doc.code?.reloadDiffBase()
        UmiToast.show("File saved.", near: UmiFilePanes.shared.open.first { $0.doc === doc }?.pane)
        return true
    }

    /// ⇧⌘S: write the document to a file the user names; the pane then shows that file (E-23).
    static func saveAs(_ doc: UmiDocument) {
        guard let pane = UmiFilePanes.shared.open.first(where: { $0.doc === doc })?.pane else { return }
        let panel = NSSavePanel()
        panel.directoryURL = doc.url.deletingLastPathComponent()
        panel.nameFieldStringValue = doc.name
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do { try saveAs(doc, to: url, pane: pane) } catch {
                doc.error = (error as? UmiError)?.message ?? error.localizedDescription
                NSSound.beep()
            }
        }
        if let window = pane.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Save As to `url`: the file gets the text, and the pane shows it from then on. The old file
    /// keeps what it had. When another pane already shows that file, it stays the file's one pane
    /// (E-9): it takes the saved text and focus, and this pane closes, its text now saved there.
    /// That pane's unsaved edits are never overwritten: Save As refuses instead.
    static func saveAs(_ doc: UmiDocument, to url: URL, pane: Ghostty.SurfaceView) throws {
        let target = url.standardizedFileURL
        if target.resolvingSymlinksInPath() == doc.url.resolvingSymlinksInPath() {
            saveFromUser(doc)
            return
        }
        if let other = UmiFilePanes.shared.pane(showing: target), other !== pane,
           let shown = UmiFilePanes.shared.document(of: other) {
            guard !shown.isDirty else {
                throw UmiError.badRequest("“\(shown.name)” is open in another pane with unsaved changes. Save or close it first.")
            }
            try doc.write(to: target)
            shown.reload()
            shown.code?.reloadDiffBase()
            UmiEvents.shared.emit("editor.saved", ["path": shown.url.path, "from": doc.url.path])
            UmiFilePanes.closePane(pane, discarding: true)
            try UmiFilePanes.open(shown.url, mode: nil, near: other, focus: true)
            UmiToast.show("File saved.", near: other)
            return
        }
        try doc.write(to: target)
        let saved = try UmiDocument(url: target, mode: doc.hasPreview ? doc.mode : nil)
        UmiFilePanes.shared.replaceDocument(of: pane, with: saved)
        UmiEvents.shared.emit("editor.saved", ["path": saved.url.path, "from": doc.url.path])
        UmiToast.show("File saved.", near: pane)
        DispatchQueue.main.async { UmiFilePanes.shared.focusEditor(of: pane) }
    }

    static func saveDirtyDocuments(of tab: UmiTab) {
        for doc in tab.editor.documents { doc.preserveEdits() }
    }

    static func saveAllDirtyDocuments() {
        for window in TerminalController.all {
            for tab in window.tabs { saveDirtyDocuments(of: tab) }
        }
    }

    static func openPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if let pane = UmiTopology.currentPane, let pwd = pane.pwd { panel.directoryURL = URL(fileURLWithPath: pwd) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFromSystem(url, inCurrentTab: true) }
    }

    /// Close a document, asking first if it has unsaved changes (E-3).
    static func confirmClose(_ doc: UmiDocument, in group: UmiEditorGroup, window: NSWindow?) {
        guard doc.isDirty else {
            group.close(doc)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(doc.name)”?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                if doc.save() { group.close(doc) }
            case .alertThirdButtonReturn:
                group.close(doc, discarding: true)
            default:
                break
            }
        }
        if let window = window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }
}

// MARK: - Views

/// The visible preview/source control (E-2), named as Warp names it: Rendered / Raw.
struct UmiModeToggle: View {
    @ObservedObject var doc: UmiDocument

    var body: some View {
        HStack(spacing: 0) {
            segment("Rendered", .preview)
            segment("Raw", .source)
        }
        .help("Toggle rendered / raw (⌘E or ⇧⌘M)")
    }

    private func segment(_ title: String, _ mode: UmiDocument.Mode) -> some View {
        Button { doc.mode = mode } label: {
            Text(title)
                .font(UmiTheme.uiFontSmall)
                .foregroundColor(doc.mode == mode ? UmiTheme.textPrimary : UmiTheme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(doc.mode == mode ? UmiTheme.selectedFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(doc.mode == mode ? .isSelected : [])
    }
}

struct UmiDocumentView: View {
    @ObservedObject var doc: UmiDocument
    let group: UmiEditorGroup
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            if doc.changedOnDisk {
                // Warp's wording (E-4): drop the edits and take the disk's version, or save over it.
                banner("This file has saved changes that are not reflected here.",
                       actions: [("Discard this version", { doc.reload() }), ("Overwrite", { UmiEditor.saveFromUser(doc) })])
            }
            if let error = doc.error {
                banner(error, actions: [("Dismiss", { doc.error = nil })])
            }
            ZStack {
                switch doc.mode {
                case .preview:
                    UmiMarkdownPreview(doc: doc, group: group, background: background)
                case .source:
                    UmiSourceEditor(doc: doc, group: group)
                }
            }
        }
    }

    private func banner(_ text: String, actions: [(String, () -> Void)]) -> some View {
        HStack(spacing: 12) {
            Text(text).font(UmiTheme.uiFontSmall).foregroundColor(UmiTheme.textSecondary)
                .lineLimit(2)
            Spacer()
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].0, action: actions[index].1)
                    .buttonStyle(.plain)
                    .font(UmiTheme.uiFontSmall)
                    .foregroundColor(UmiTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(UmiTheme.hoverFill)
    }
}

/// Responder container: routes ⌘S, ⌘W and ⇧⌘M to the document while the editor has
/// focus, whatever the state of Caps Lock (E-8).
final class UmiEditorContainerView: NSView {
    weak var document: UmiDocument?
    var closeDocument: (() -> Void)?
    /// The editor inside took keyboard focus.
    var didFocus: (() -> Void)?

    /// Tell the container around `view` that it took keyboard focus.
    static func focused(_ view: NSView) {
        var current = view.superview
        while let candidate = current {
            if let container = candidate as? UmiEditorContainerView {
                container.didFocus?()
                return
            }
            current = candidate.superview
        }
    }

    /// The pane this editor is in takes focus with it, and its editor is what focusing the pane
    /// focuses.
    func attach(to group: UmiEditorGroup, focusTarget: NSView) {
        guard let pane = group.pane else { return }
        UmiFilePanes.shared.registerFocusTarget(focusTarget, for: pane.id)
        didFocus = { [weak pane] in
            guard let pane else { return }
            UmiFilePanes.shared.editorFocused(pane: pane)
        }
        // A view that replaces another in the focused file pane (Rendered / Raw, ⌘E or ⇧⌘M) takes
        // the keyboard the one it replaced had, so ⌘E pressed again switches back.
        DispatchQueue.main.async { [weak pane, weak focusTarget] in
            guard let pane, let focusTarget, let window = focusTarget.window,
                  UmiTopology.locate(pane)?.window.focusedSurface === pane,
                  window.firstResponder == nil || window.firstResponder === window else { return }
            window.makeFirstResponder(focusTarget)
        }
    }

    @objc func saveDocument(_ sender: Any?) { document.map { UmiEditor.saveFromUser($0) } }
    @objc func toggleMarkdownPreview(_ sender: Any?) { document?.toggleMode() }

    // The Find menu's items (⌘F, ⌘G, ⇧⌘G, ⌘E) reach the editor's own find instead of the
    // terminal underneath the file pane (whose window controller handles them otherwise).
    @objc func find(_ sender: Any?) { if let code = document?.code { code.openFind() } else { NSSound.beep() } }
    @objc func findNext(_ sender: Any?) { if let code = document?.code { code.findStep(1) } else { NSSound.beep() } }
    @objc func findPrevious(_ sender: Any?) { if let code = document?.code { code.findStep(-1) } else { NSSound.beep() } }
    @objc func findHide(_ sender: Any?) { document?.code?.closeFind() }
    /// ⌘E (Edit ▸ Find ▸ Use Selection for Find in a terminal) toggles Rendered / Raw in a file
    /// that has both views, as Warp's ⌘E does (E-2); in a file with only a source view it puts
    /// the selection in the find bar's query. Terminals keep theirs.
    @objc func selectionForFind(_ sender: Any?) {
        if document?.hasPreview ?? false { document?.toggleMode(); return }
        guard let code = document?.code, let textView = code.textView else { return NSSound.beep() }
        let range = textView.selectedRange()
        guard range.length > 0 else { return NSSound.beep() }
        code.find.query = (textView.string as NSString).substring(with: range)
    }
    @objc func scrollToSelection(_ sender: Any?) {
        guard let textView = document?.code?.textView else { return }
        textView.scrollRangeToVisible(textView.selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) else {
            return super.performKeyEquivalent(with: event)
        }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        switch (flags, key) {
        case ([.command], "w"):
            closeDocument?()
            return true
        case ([.command], "s"):
            if let document { UmiEditor.saveFromUser(document) }
            return true
        case ([.command, .shift], "m"):
            document?.toggleMode()
            return true
        // Ghostty leaves these menu items without keys (its terminals take them as bindings), so
        // the editor's text and its find fields get them here.
        // Undo is the text's own (the document's history), not the window's (pane closes and moves).
        case ([.command], "z") where responder is UmiEditorTextView, ([.command, .shift], "z") where responder is UmiEditorTextView:
            let undo = (responder as? NSTextView)?.undoManager
            let redo = flags.contains(.shift)
            if let undo, redo ? undo.canRedo : undo.canUndo {
                if redo { undo.redo() } else { undo.undo() }
            } else {
                NSSound.beep()
            }
            return true
        case ([.command], "c"):
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case ([.command], "x"):
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case ([.command], "v"):
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case ([.command], "e"):
            // Warp's key for Rendered / Raw (Warp parity, 2026-11-05) in a file with both views;
            // in a source-only file, Use Selection for Find. The menu item has no key of its own
            // (Ghostty's ⌘E is a terminal binding), so the key comes here.
            guard document != nil else { return super.performKeyEquivalent(with: event) }
            selectionForFind(nil)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Plain-text source editing.
struct UmiSourceEditor: NSViewRepresentable {
    @ObservedObject var doc: UmiDocument
    /// Umi: the interface's zoom scales the editor's text (L-33).
    @ObservedObject private var zoom = UmiZoom.shared
    let group: UmiEditorGroup

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> UmiEditorContainerView {
        let container = UmiEditorContainerView()
        container.document = doc
        container.closeDocument = { [weak doc, weak group, weak container] in
            guard let doc, let group else { return }
            UmiEditor.confirmClose(doc, in: group, window: container?.window)
        }
        doc.commentTarget = context.coordinator
        let (scroll, codeView) = UmiCodeEditor.makeScrollView()
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if let textView = scroll.documentView as? NSTextView {
            context.coordinator.textView = textView
            textView.delegate = context.coordinator
            textView.drawsBackground = false
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            // Find is the code view's own bar (E-22), not AppKit's.
            textView.usesFindBar = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.insertionPointColor = UmiTheme.accentNSColor
            textView.textContainerInset = NSSize(width: 4, height: 10)
            textView.string = doc.text
            // A new text view starts its own history: steps from an earlier one point into it.
            doc.undoManager.removeAllActions()
            // Opened with the caret at the top, as Warp opens files.
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.setAccessibilityLabel(doc.name)
            container.attach(to: group, focusTarget: textView)
        }
        container.addSubview(scroll)
        let code = UmiCodeEditor(doc: doc, textView: codeView, scroll: scroll, container: container, pane: group.pane)
        context.coordinator.code = code
        doc.code = code
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ container: UmiEditorContainerView, context: Context) {
        guard let scroll = container.subviews.first as? NSScrollView,
              let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != doc.text {
            let selection = textView.selectedRanges
            textView.string = doc.text
            // The text was replaced from outside the editor (reload, comments, the CLI): the
            // history's steps point into the old text, so ⌘Z must not replay them.
            doc.undoManager.removeAllActions()
            let length = (doc.text as NSString).length
            // Keep the selection where it was, clamped to the new text. AppKit throws (and the
            // app crashes) if given no ranges, as when a reload is shorter than the old cursor.
            let clamped = selection.map { value -> NSValue in
                let range = value.rangeValue
                let location = min(range.location, length)
                return NSValue(range: NSRange(location: location, length: min(range.length, length - location)))
            }
            textView.selectedRanges = clamped.isEmpty ? [NSValue(range: NSRange(location: 0, length: 0))] : clamped
        }
        // The theme went light or dark: the code view recolors (setting `textColor` would wipe the
        // syntax colors).
        if let code = context.coordinator.code, code.baseColor != UmiTheme.textNSColor { code.lookChanged() }
        // Umi: the interface's zoom (L-33) changes the terminals' font size, which the code view
        // takes its font from: take it again.
        if let code = context.coordinator.code, context.coordinator.zoomFactor != zoom.factor {
            context.coordinator.zoomFactor = zoom.factor
            code.lookChanged()
        }
        if doc.code !== context.coordinator.code { doc.code = context.coordinator.code }
        if let line = doc.revealLine {
            let column = doc.revealColumn ?? 0
            DispatchQueue.main.async { doc.revealLine = nil; doc.revealColumn = nil }
            Self.reveal(line: line, column: column, in: textView)
        }
    }

    /// Put the cursor in a line (at `column`, a UTF-16 offset clamped to the line) and scroll it
    /// into view.
    static func reveal(line: Int, column: Int = 0, in textView: NSTextView) {
        let text = textView.string as NSString
        var location = 0
        var current = 1
        while current < line, location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(range)
            current += 1
        }
        location = min(location, text.length)
        if column > 0 {
            // The line's own text, without its line break.
            var end = 0, contentsEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            location = min(location + column, contentsEnd)
        }
        let target = NSRange(location: location, length: 0)
        textView.setSelectedRange(target)
        textView.scrollRangeToVisible(target)
        textView.window?.makeFirstResponder(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, UmiCommentTarget {
        let doc: UmiDocument
        weak var textView: NSTextView?
        /// Owned here: lives as long as the source view.
        var code: UmiCodeEditor?
        /// The interface zoom the code view's font was last taken at (L-33).
        var zoomFactor: CGFloat = 1
        init(doc: UmiDocument) { self.doc = doc }

        /// Comment on the selection (E-11): the margin is the preview's, so here the text is
        /// asked for in a sheet, and the markup appears in the source.
        func startComment() {
            guard doc.isMarkdown, let textView else { return }
            let range = textView.selectedRange()
            guard range.length > 0 else {
                doc.error = "Select the text to comment on first."
                NSSound.beep()
                return
            }
            let base = doc.text
            let quote = (base as NSString).substring(with: range)
            UmiCommentsUI.prompt(quote: quote, window: textView.window) { [weak self] body in
                guard let self else { return }
                do { try self.doc.addComment(body, on: range, base: base) } catch { UmiCommentsUI.show(error, for: self.doc) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            doc.text = textView.string
        }

        /// Each document has its own undo history.
        func undoManager(for view: NSTextView) -> UndoManager? { doc.undoManager }
    }
}

/// Rendered Markdown (E-1, E-7): the document's JavaScript off, relative links open in the editor,
/// `#anchors` scroll within the page, local images are inlined. Comments (E-11) show in a margin
/// drawn by Umi's own script, which runs apart from the page (`UmiCommentsScript`).
struct UmiMarkdownPreview: NSViewRepresentable {
    @ObservedObject var doc: UmiDocument
    /// Umi: the interface's zoom scales the page (L-33).
    @ObservedObject private var zoom = UmiZoom.shared
    let group: UmiEditorGroup
    let background: Color

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> UmiEditorContainerView {
        let container = UmiEditorContainerView()
        container.document = doc
        container.closeDocument = { [weak doc, weak group, weak container] in
            guard let doc, let group else { return }
            UmiEditor.confirmClose(doc, in: group, window: container?.window)
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let scripts = config.userContentController
        // Code blocks, diagrams and find (Warp parity); before the margin, so it lays out the
        // page as these leave it.
        UmiMarkdownScript.userScripts.forEach(scripts.addUserScript)
        scripts.addUserScript(WKUserScript(source: UmiCommentsScript.source, injectionTime: .atDocumentEnd,
                                           forMainFrameOnly: true, in: UmiCommentsUI.world))
        scripts.add(UmiScriptHandlerProxy(context.coordinator), contentWorld: UmiCommentsUI.world, name: "umi")
        let web = UmiPreviewWebView(frame: .zero, configuration: config)
        web.pageZoom = zoom.factor
        web.coordinator = context.coordinator
        container.attach(to: group, focusTarget: web)
        web.navigationDelegate = context.coordinator
        web.setValue(false, forKey: "drawsBackground")
        web.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(web)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            web.topAnchor.constraint(equalTo: container.topAnchor),
            web.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.web = web
        context.coordinator.group = group
        if doc.isMarkdown { doc.commentTarget = context.coordinator }
        context.coordinator.render()
        return container
    }

    func updateNSView(_ container: UmiEditorContainerView, context: Context) {
        context.coordinator.group = group
        if let web = context.coordinator.web, web.pageZoom != zoom.factor { web.pageZoom = zoom.factor }
        context.coordinator.render()
        context.coordinator.showWaiters()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, UmiCommentTarget {
        let doc: UmiDocument
        weak var web: WKWebView?
        weak var group: UmiEditorGroup?
        var lastKey: String?
        /// The text the page shows: a new comment's offsets are in it.
        private(set) var renderedText = ""
        /// While a comment or reply is being written, the page isn't reloaded under it.
        private var composing = false
        private var renderPending = false
        // Kept across reloads.
        private var scroll: Double = 0
        private var focus: String?
        private var showResolved = false
        private var shownWaiters = 0

        init(doc: UmiDocument) { self.doc = doc }

        func render(force: Bool = false) {
            guard let web else { return }
            let key = "\(doc.renderRevision):\(doc.text.hashValue):\(UmiTheme.isLight):\(UmiMarkdownStyle.fontSize)"
            guard force || lastKey != key else { return }
            if composing && !force {
                renderPending = true
                return
            }
            renderPending = false
            lastKey = key
            renderedText = doc.text
            guard doc.isMarkdown else {
                // JSON and CSV/TSV previews have no comments.
                let body = UmiDataPreview.html(for: doc.url, text: doc.text)
                web.loadHTMLString(UmiMarkdown.page(body: body, background: "transparent", light: UmiTheme.isLight), baseURL: nil)
                return
            }
            let threads = UmiComments.Document(doc.text).threads
            let preview = UmiComments.preview(doc.text, resolvedIDs: Set(threads.filter(\.resolved).map(\.id)))
            let body = UmiMarkdown.html(from: preview.source, baseURL: doc.url.deletingLastPathComponent(),
                                        positions: preview.fileOffset(of:))
            shownWaiters = doc.reviewWaiters
            let data: [String: Any] = [
                "threads": threads.map(\.json), "focus": focus ?? NSNull(), "scroll": scroll,
                "waiting": doc.reviewWaiters, "showResolved": showResolved, "reveal": focus != nil,
            ]
            let head = UmiCommentsScript.head(data: data, light: UmiTheme.isLight)
            hasDiagrams = body.contains("umi-code umi-mermaid")
            web.loadHTMLString(UmiMarkdown.page(body: body, background: "transparent", light: UmiTheme.isLight, head: head,
                                                markdown: true, fontSize: UmiMarkdownStyle.fontSize),
                               baseURL: nil)
        }

        /// The page on show has Mermaid blocks: mermaid.js is loaded into it once it has loaded.
        private var hasDiagrams = false

        private func renderDiagrams() {
            guard hasDiagrams, let web else { return }
            let light = UmiTheme.isLight
            web.evaluateJavaScript(UmiMarkdownScript.mermaidJS, in: nil, in: UmiCommentsUI.world) { [weak web] _ in
                web?.callAsyncJavaScript("return window.umiMarkdown && umiMarkdown.renderMermaid(light)",
                                         arguments: ["light": light], in: nil, in: UmiCommentsUI.world) { _ in }
            }
        }

        /// Run in terminal (shell blocks): the command goes to the input of the tab's terminal
        /// used most recently, as Warp puts a notebook's command in its active session's input. It
        /// isn't run: the user presses Return there.
        private func runInTerminal(_ text: String) {
            guard let pane = group?.pane, let location = UmiTopology.locate(pane) else { return NSSound.beep() }
            let shown = location.window.tree(of: location.tab).root?.leaves() ?? []
            let terminals = shown.filter {
                $0 !== pane && UmiFilePanes.shared.document(of: $0) == nil
                    && !UmiWebPanes.shared.isWebPane($0.id)
            }
            guard let target = UmiFocusHistory.mostRecent(among: terminals) ?? terminals.first,
                  let surface = target.surfaceModel else {
                doc.error = "No terminal in this tab to run the command in."
                return NSSound.beep()
            }
            surface.sendText(text)
            UmiLayout.focusPane(target, activate: true)
        }

        private func copy(_ text: String) {
            UmiMarkdownScript.pasteboard.clearContents()
            UmiMarkdownScript.pasteboard.setString(text, forType: .string)
        }

        func showWaiters() {
            guard let web, shownWaiters != doc.reviewWaiters else { return }
            shownWaiters = doc.reviewWaiters
            web.evaluateJavaScript("window.umiComments && umiComments.setWaiting(\(doc.reviewWaiters))", in: nil, in: UmiCommentsUI.world)
        }

        func startComment() {
            web?.window?.makeFirstResponder(web)
            web?.evaluateJavaScript("window.umiComments && umiComments.startCompose()", in: nil, in: UmiCommentsUI.world)
        }

        private func call(_ js: String) {
            web?.evaluateJavaScript(js, in: nil, in: UmiCommentsUI.world)
        }

        private func jsString(_ text: String) -> String {
            let data = (try? JSONSerialization.data(withJSONObject: [text], options: [])) ?? Data("[\"\"]".utf8)
            let array = String(decoding: data, as: UTF8.self)
            return String(array.dropFirst().dropLast())
        }

        // MARK: Messages from the margin

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "scroll":
                scroll = (body["y"] as? Double) ?? scroll
            case "select":
                focus = body["id"] as? String
            case "show_resolved":
                showResolved = (body["on"] as? Bool) ?? false
            case "composing":
                composing = (body["on"] as? Bool) ?? false
                if !composing && renderPending { render() }
            case "done":
                call("umiComments.notice(\(jsString(UmiCommentsUI.reviewDone(doc))))")
            case "copy":
                copy(body["text"] as? String ?? "")
            case "run":
                runInTerminal(body["text"] as? String ?? "")
            case "add", "reply", "edit", "resolve", "delete":
                perform(type, body)
            default:
                break
            }
        }

        private func perform(_ type: String, _ body: [String: Any]) {
            let id = body["id"] as? String ?? ""
            let text = body["body"] as? String ?? ""
            do {
                switch type {
                case "add":
                    guard let start = body["start"] as? Int, let end = body["end"] as? Int, end >= start else {
                        throw UmiComments.Failure("Umi can't place a comment on that text")
                    }
                    focus = try doc.addComment(text, on: NSRange(location: start, length: end - start), base: renderedText)
                case "reply":
                    try doc.changeComments("replied") { try UmiComments.replying(to: id, text, in: $0, by: UmiComments.userAuthor).text }
                    focus = UmiComments.Document(doc.text).thread(id)?.id ?? focus
                case "edit":
                    try doc.changeComments("edited") { try UmiComments.editing(id, to: text, in: $0) }
                case "resolve":
                    let resolved = (body["resolved"] as? Bool) ?? true
                    try doc.changeComments(resolved ? "resolved" : "reopened") { try UmiComments.resolving(id, resolved, in: $0) }
                    if resolved { focus = nil }
                case "delete":
                    try doc.changeComments("deleted") { try UmiComments.deleting(id, in: $0) }
                    focus = nil
                default:
                    return
                }
                composing = false
                render(force: true)
            } catch {
                let message = (error as? UmiComments.Failure)?.message ?? (error as? UmiError)?.message ?? error.localizedDescription
                call("umiComments.failed(\(jsString(message)))")
            }
        }

        /// A page that just loaded has the count from when it was made: give it the current one.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            shownWaiters = doc.reviewWaiters
            call("window.umiComments && umiComments.setWaiting(\(doc.reviewWaiters))")
            renderDiagrams()
        }

        // MARK: Find (⌘F, ⌘G, ⇧⌘G), as Warp's find bar in a Markdown file

        func find(_ js: String) {
            web?.evaluateJavaScript("window.umiMarkdown && umiMarkdown.\(js)", in: nil, in: UmiCommentsUI.world)
        }

        // MARK: Links

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Same-document anchors scroll within the preview.
            if url.fragment != nil, url.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.isFileURL {
                let target = URL(fileURLWithPath: url.path)
                if let group, (try? UmiTextFile.checkOpenable(target)) != nil, UmiEditor.handles(target) || UmiEditor.isMarkdown(target) {
                    try? group.open(target, mode: nil)
                } else {
                    NSWorkspace.shared.open(target)
                }
            } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// The source editor's text view: tells its pane when it takes keyboard focus.
final class UmiEditorTextView: NSTextView {
    /// The code view's extras (current line, Esc), when it's the source editor.
    weak var code: UmiCodeEditor?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            UmiEditorContainerView.focused(self)
            MainActor.assumeIsolated { code?.reloadDiffBase() }
        }
        return result
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        MainActor.assumeIsolated { code?.drawCurrentLine(in: rect) }
    }

    /// Right-click in code: Cut, Copy and Paste only. Warp's menu here (Go to definition, Find
    /// references) needs a language server; AppKit's full text menu would let Substitutions turn
    /// smart quotes back on in code.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard code != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        // No items added by the system (AutoFill, Services, Writing Tools).
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) { menu.automaticallyInsertsWritingToolsItems = false }
        for (title, action) in [("Cut", #selector(cut(_:))), ("Copy", #selector(copy(_:))), ("Paste", #selector(paste(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    /// Esc closes the find bar or the go-to box; otherwise it does nothing (no completion list).
    override func cancelOperation(_ sender: Any?) {
        let handled = MainActor.assumeIsolated { code?.escape() ?? false }
        if !handled && code == nil { super.cancelOperation(sender) }
    }
}

/// The preview's web view: tells its pane when it takes keyboard focus. In a Markdown preview
/// Edit ▸ Find's items (⌘F, ⌘G, ⇧⌘G) search the document, and its right-click menu has Warp's
/// items (Warp parity, 2026-11-05).
final class UmiPreviewWebView: WKWebView {
    weak var coordinator: UmiMarkdownPreview.Coordinator?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { UmiEditorContainerView.focused(self) }
        return result
    }

    private var isMarkdown: Bool { coordinator?.doc.isMarkdown ?? false }

    @objc func find(_ sender: Any?) { coordinator?.find("openFind()") }
    @objc func findNext(_ sender: Any?) { coordinator?.find("findNext()") }
    @objc func findPrevious(_ sender: Any?) { coordinator?.find("findPrevious()") }
    @objc func findHide(_ sender: Any?) { coordinator?.find("closeFind()") }

    override func responds(to selector: Selector!) -> Bool {
        let findActions: Set<Selector> = [#selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(findHide(_:))]
        if let selector, findActions.contains(selector) { return isMarkdown }
        return super.responds(to: selector)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(find(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)), #selector(findHide(_:)):
            return isMarkdown
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: The right-click menu

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        let hasSelection = menu.items.contains { $0.identifier?.rawValue == "WKMenuItemIdentifierCopy" }
        let items = warpMenu(selection: hasSelection).items
        menu.removeAllItems()
        for item in items {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        super.willOpenMenu(menu, with: event)
    }

    /// Warp's items for a Markdown file's right-click menu: Copy (with a selection), Copy file
    /// path, the four splits, then Maximize (or Minimize) pane and Close pane in a split.
    func warpMenu(selection: Bool) -> NSMenu {
        let menu = NSMenu()
        if selection {
            let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            copy.target = self
            menu.addItem(copy)
        }
        guard let coordinator, let pane = coordinator.group?.pane else { return menu }
        let doc = coordinator.doc
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(UmiPreviewMenuItem("Copy file path") {
            UmiMarkdownScript.pasteboard.clearContents()
            UmiMarkdownScript.pasteboard.setString(doc.url.path, forType: .string)
        })
        menu.addItem(.separator())
        let splits: [(String, SplitTree<Ghostty.SurfaceView>.NewDirection)] = [
            ("Split pane right", .right), ("Split pane left", .left), ("Split pane down", .down), ("Split pane up", .up),
        ]
        for (title, direction) in splits {
            menu.addItem(UmiPreviewMenuItem(title) { [weak pane] in
                guard let pane else { return }
                var options = UmiLayout.PaneOptions()
                options.cwd = doc.url.deletingLastPathComponent().path
                if (try? UmiLayout.split(pane, direction: direction, options: options, ratio: nil, focus: true)) == nil { NSSound.beep() }
            })
        }
        if let location = UmiTopology.locate(pane), location.window.tree(of: location.tab).isSplit {
            let zoomed = location.window.tree(of: location.tab).zoomed != nil
            menu.addItem(UmiPreviewMenuItem(zoomed ? "Minimize pane" : "Maximize pane") { [weak pane] in
                guard let pane else { return }
                if (try? UmiLayout.toggleZoom(pane)) == nil { NSSound.beep() }
            })
            menu.addItem(UmiPreviewMenuItem("Close pane") { [weak self] in
                guard let container = self?.superview as? UmiEditorContainerView else { return }
                container.closeDocument?()
            })
        }
        return menu
    }
}

/// A menu item that runs a closure.
final class UmiPreviewMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @MainActor @objc private func run(_ sender: Any?) { handler() }
}

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

// MARK: - Reading and writing text files

/// What the editor can open safely, and in which encoding (E-5, E-6).
enum TernTextFile {
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
            throw TernError.notFound("no such file: \(url.path)")
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            break
        case S_IFDIR:
            throw TernError.badRequest("\(url.path) is a folder, not a file")
        case S_IFIFO:
            throw TernError.badRequest("\(url.path) is a named pipe (FIFO); the editor only opens regular files")
        case S_IFCHR, S_IFBLK:
            throw TernError.badRequest("\(url.path) is a device; the editor only opens regular files")
        case S_IFSOCK:
            throw TernError.badRequest("\(url.path) is a socket; the editor only opens regular files")
        default:
            throw TernError.badRequest("\(url.path) isn't a regular file")
        }
        if Int(st.st_size) > sizeLimit {
            let mb = Double(st.st_size) / 1_048_576
            throw TernError.badRequest(String(format: "%@ is too large for the editor (%.0f MB; the limit is %d MB)",
                                              url.lastPathComponent, mb, sizeLimit / 1_048_576))
        }
    }

    static func read(_ url: URL) throws -> Loaded {
        try checkOpenable(url)
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw TernError.failed("can't read \(url.path): \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = (try? handle.readToEnd()) ?? Data()
        guard data.count <= sizeLimit else {
            throw TernError.badRequest("\(url.lastPathComponent) is too large for the editor")
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
            throw TernError.badRequest("\(name) isn't valid UTF-8 text; the editor won't risk changing it")
        }
        // Not UTF-8: a legacy single-byte text file (Latin-1), unless it's full of control
        // characters, which means binary.
        let controls = sample.filter { $0 < 0x20 && ![0x09, 0x0A, 0x0C, 0x0D, 0x1B].contains($0) }.count
        if sample.isEmpty || Double(controls) / Double(sample.count) > 0.02 { throw binary(name) }
        guard let text = String(data: data, encoding: .isoLatin1) else { throw binary(name) }
        return Loaded(text: text, encoding: .isoLatin1, bom: Data())
    }

    private static func binary(_ name: String) -> TernError {
        TernError.badRequest("\(name) looks like a binary file; the editor only opens text")
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
            throw TernError.failed("can't save \(url.lastPathComponent) in \(encodingName(encoding)) without losing characters; the file was left unchanged")
        }
        var data = bom
        data.append(body)
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).tern-\(UUID().uuidString.prefix(8))")
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
                throw TernError.failed("couldn't save \(url.path): \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Documents

/// One open file.
@MainActor
final class TernDocument: ObservableObject, Identifiable {
    enum Mode: String { case preview, source }

    let id = UUID()
    let url: URL
    @Published var text: String {
        didSet { isDirty = text != savedText }
    }
    @Published private(set) var isDirty = false
    @Published var mode: Mode {
        didSet { if mode != oldValue { TernState.shared.layoutDidChange() } }
    }
    /// The file changed on disk while there were unsaved edits.
    @Published var changedOnDisk = false
    @Published var error: String?
    /// Bumped when the preview should re-render (e.g. reloaded from disk).
    @Published private(set) var renderRevision = 0

    private(set) var encoding: String.Encoding
    private var bom: Data
    private var savedText: String
    private var watcher: DispatchSourceFileSystemObject?
    private var reappearTimer: Timer?
    private var pendingCheck: DispatchWorkItem?
    let undoManager = UndoManager()

    var isMarkdown: Bool { TernEditor.isMarkdown(url) }
    var name: String { url.lastPathComponent }

    init(url: URL, mode: Mode? = nil) throws {
        self.url = url
        let loaded = try TernTextFile.read(url)
        self.text = loaded.text
        self.savedText = loaded.text
        self.encoding = loaded.encoding
        self.bom = loaded.bom
        self.mode = mode.flatMap { TernEditor.isMarkdown(url) ? $0 : .source } ?? (TernEditor.isMarkdown(url) ? .preview : .source)
        watch()
    }

    deinit {
        watcher?.cancel()
        reappearTimer?.invalidate()
    }

    /// Whether the file on disk still matches what we last loaded or saved.
    var diskMatchesBaseline: Bool {
        (try? TernTextFile.read(url).text) == savedText
    }

    func toggleMode() {
        guard isMarkdown else { return }
        mode = mode == .preview ? .source : .preview
    }

    @discardableResult
    func save() -> Bool {
        do {
            try TernTextFile.write(text, to: url, encoding: encoding, bom: bom)
            savedText = text
            isDirty = false
            changedOnDisk = false
            error = nil
            watch()
            TernEvents.shared.emit("editor.saved", ["path": url.path])
            return true
        } catch let e as TernError {
            error = e.message
            NSSound.beep()
            return false
        } catch {
            self.error = "Save failed: \(error.localizedDescription)"
            return false
        }
    }

    func reload() {
        do {
            let loaded = try TernTextFile.read(url)
            encoding = loaded.encoding
            bom = loaded.bom
            savedText = loaded.text
            text = loaded.text
            isDirty = false
            changedOnDisk = false
            error = nil
            renderRevision &+= 1
            watch()
            TernEvents.shared.emit("editor.reloaded", ["path": url.path])
        } catch let e as TernError {
            error = "Reload failed: \(e.message)"
            watch()
        } catch {
            self.error = "Reload failed: \(error.localizedDescription)"
            watch()
        }
    }

    /// Keep the edits as they are and stop warning about the disk.
    func keepMine() {
        changedOnDisk = false
        if let current = try? TernTextFile.read(url).text { savedText = current }
        isDirty = text != savedText
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
        guard let loaded = try? TernTextFile.read(url) else {
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
        let dir = TernPaths.directory("recovery")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let backup = (dir as NSString).appendingPathComponent("\(stamp)-\(id.uuidString.prefix(8))-\(name)")
        try? text.write(toFile: backup, atomically: true, encoding: .utf8)
        TernEvents.shared.emit("editor.recovered", ["path": url.path, "backup": backup])
    }
}

/// The open files of one tab, shown in a panel beside its terminals.
@MainActor
final class TernEditorGroup: ObservableObject {
    @Published var documents: [TernDocument] = []
    @Published var active: TernDocument?
    /// Panel width as a fraction of the tab's width.
    @Published var fraction: CGFloat = 0.5

    var isEmpty: Bool { documents.isEmpty }

    func document(for url: URL) -> TernDocument? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        return documents.first { $0.url.resolvingSymlinksInPath() == target }
    }

    @discardableResult
    func open(_ url: URL, mode: TernDocument.Mode?) throws -> TernDocument {
        let standardized = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = document(for: standardized) {
            if let mode, existing.isMarkdown { existing.mode = mode }
            active = existing
            return existing
        }
        let doc = try TernDocument(url: standardized, mode: mode)
        documents.append(doc)
        active = doc
        TernState.shared.layoutDidChange()
        return doc
    }

    func close(_ doc: TernDocument) {
        guard let index = documents.firstIndex(where: { $0 === doc }) else { return }
        documents.remove(at: index)
        if active === doc {
            active = documents.isEmpty ? nil : documents[min(index, documents.count - 1)]
        }
        TernState.shared.layoutDidChange()
    }
}

// MARK: - Opening and the CLI

@MainActor
enum TernEditor {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "mdx"]
    /// Scripts keep Ghostty's behavior of being executed when opened from Finder.
    static let executableScriptExtensions: Set<String> = ["sh", "zsh", "bash", "csh", "fish", "command", "tool", "pl"]

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether files opened from Finder (or `open`) go to the editor.
    static func handles(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if executableScriptExtensions.contains(ext) { return false }
        if markdownExtensions.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .plainText) || type.conforms(to: .sourceCode) {
            return true
        }
        if ["txt", "text", "log", "json", "yaml", "yml", "toml", "ini", "conf", "cfg", "env", "csv"].contains(ext) {
            return true
        }
        return ext.isEmpty && (try? TernTextFile.read(url)) != nil
    }

    /// The tab an editor request is about: an explicit pane or tab (which must exist),
    /// else the caller's tab, else the focused tab (E-9).
    static func targetTab(_ params: TernParams, caller: TernCaller, createWindow: Bool) throws -> (TerminalController, TernTab) {
        if let pane = params.string("pane") {
            let surface = try TernTopology.resolvePane(pane, caller: caller)
            guard let location = TernTopology.locate(surface) else { throw TernError.notFound("the pane isn't in a window") }
            return (location.window, location.tab)
        }
        if let tab = params.string("tab") {
            return try TernTopology.resolveTab(tab, caller: caller)
        }
        if let callerPane = try TernTopology.callerPane(caller), let location = TernTopology.locate(callerPane) {
            return (location.window, location.tab)
        }
        if let window = TernTopology.currentWindow { return (window, window.selectedTab) }
        guard createWindow, let ghostty = TernLayout.ghostty else { throw TernError.notFound("no Tern windows are open") }
        let window = TerminalController.newWindow(ghostty)
        return (window, window.selectedTab)
    }

    static func handleOpen(_ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        guard let paths = params.strings("paths"), !paths.isEmpty else { throw TernError.badRequest("edit: name a file") }
        let mode = params.string("mode").flatMap(TernDocument.Mode.init(rawValue:))
        // Check every file first: a refusal changes nothing.
        for path in paths { try TernTextFile.checkOpenable(URL(fileURLWithPath: path)) }
        let (window, tab) = try targetTab(params, caller: caller, createWindow: true)
        var opened: [[String: Any]] = []
        for path in paths {
            let doc = try tab.editor.open(URL(fileURLWithPath: path), mode: mode)
            opened.append(json(doc))
            TernEvents.shared.emit("editor.opened", ["path": doc.url.path, "tab": tab.idString, "window": window.ternIDString])
        }
        return ["documents": opened, "tab": tab.idString, "window": window.ternIDString]
    }

    static func handleList(_ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        let (window, tab) = try targetTab(params, caller: caller, createWindow: false)
        return ["documents": tab.editor.documents.map(json), "tab": tab.idString, "window": window.ternIDString,
                "active": tab.editor.active?.url.path ?? ""]
    }

    static func handleClose(_ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        let (_, tab) = try targetTab(params, caller: caller, createWindow: false)
        let doc: TernDocument
        if let path = params.string("path") {
            guard let found = tab.editor.document(for: URL(fileURLWithPath: path)) else {
                throw TernError.notFound("\(path) isn't open in that tab")
            }
            doc = found
        } else {
            guard let active = tab.editor.active else { throw TernError.notFound("no file is open in that tab") }
            doc = active
        }
        if doc.isDirty && !(params.bool("force") ?? false) {
            throw TernError.badRequest("\(doc.name) has unsaved changes; save it first or use --force to discard them")
        }
        tab.editor.close(doc)
        TernEvents.shared.emit("editor.closed", ["path": doc.url.path, "tab": tab.idString])
        return ["path": doc.url.path, "closed": true]
    }

    static func handleMode(_ params: TernParams, caller: TernCaller) throws -> [String: Any] {
        let (_, tab) = try targetTab(params, caller: caller, createWindow: false)
        let doc: TernDocument
        if let path = params.string("path") {
            guard let found = tab.editor.document(for: URL(fileURLWithPath: path)) else {
                throw TernError.notFound("\(path) isn't open in that tab")
            }
            doc = found
        } else {
            guard let active = tab.editor.active else { throw TernError.notFound("no file is open in that tab") }
            doc = active
        }
        if let raw = params.string("mode") {
            guard let mode = TernDocument.Mode(rawValue: raw) else { throw TernError.badRequest("use preview or source") }
            guard doc.isMarkdown || mode == .source else {
                throw TernError.badRequest("\(doc.name) isn't Markdown; it only has a source view")
            }
            doc.mode = mode
        } else {
            guard doc.isMarkdown else { throw TernError.badRequest("\(doc.name) isn't Markdown; it only has a source view") }
            doc.toggleMode()
        }
        return json(doc)
    }

    static func json(_ doc: TernDocument) -> [String: Any] {
        ["path": doc.url.path, "mode": doc.mode.rawValue, "dirty": doc.isDirty,
         "encoding": TernTextFile.encodingName(doc.encoding), "changed_on_disk": doc.changedOnDisk]
    }

    /// Open a file from Finder or `open FILE` in the current tab, bringing it forward.
    @discardableResult
    static func openFromSystem(_ url: URL) -> Bool {
        do {
            try TernTextFile.checkOpenable(url)
            let (window, tab) = try targetTab(TernParams([:]), caller: TernCaller([:]), createWindow: true)
            try tab.editor.open(url, mode: nil)
            TernLayout.focusTab(tab, in: window)
            return true
        } catch let error as TernError {
            let alert = NSAlert()
            alert.messageText = "Can't open \(url.lastPathComponent)"
            alert.informativeText = error.message
            alert.runModal()
            return false
        } catch {
            return false
        }
    }

    /// The active document of the current tab (for menu commands).
    static var currentDocument: TernDocument? {
        TernTopology.currentWindow?.selectedTab.editor.active
    }

    /// True when keyboard focus is in an editor view.
    static var editorHasFocus: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder as? NSView else { return false }
        var view: NSView? = responder
        while let current = view {
            if current is TernEditorContainerView { return true }
            view = current.superview
        }
        return false
    }

    static func saveDirtyDocuments(of tab: TernTab) {
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
        if let pane = TernTopology.currentPane, let pwd = pane.pwd { panel.directoryURL = URL(fileURLWithPath: pwd) }
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { openFromSystem(url) }
    }

    /// Close a document, asking first if it has unsaved changes (E-3).
    static func confirmClose(_ doc: TernDocument, in group: TernEditorGroup, window: NSWindow?) {
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
                group.close(doc)
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

/// A tab's terminals with its editor panel (when files are open) on the right,
/// separated by a draggable divider.
struct TernEditorSplit<Content: View>: View {
    @ObservedObject var group: TernEditorGroup
    let background: Color
    @ViewBuilder let content: () -> Content
    @State private var dragStart: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                content()
                if !group.isEmpty {
                    Rectangle()
                        .fill(TernTheme.hairline)
                        .frame(width: 1)
                        .overlay(
                            Color.clear
                                .frame(width: 8)
                                .contentShape(Rectangle())
                                .onHover { inside in
                                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                }
                                .gesture(DragGesture(minimumDistance: 1).onChanged { value in
                                    let start = dragStart ?? group.fraction
                                    dragStart = start
                                    let delta = value.translation.width / max(geometry.size.width, 1)
                                    group.fraction = min(0.85, max(0.2, start - delta))
                                }.onEnded { _ in dragStart = nil })
                        )
                    TernEditorPanel(group: group, background: background)
                        .frame(width: geometry.size.width * group.fraction)
                }
            }
        }
    }
}

/// The editor panel: file tabs, the preview/source toggle, and the document.
struct TernEditorPanel: View {
    @ObservedObject var group: TernEditorGroup
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            header
            if let doc = group.active {
                TernDocumentView(doc: doc, group: group, background: background)
                    .id(doc.id)
            }
        }
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor")
    }

    private var header: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(group.documents) { doc in
                        TernEditorTabChip(doc: doc, selected: doc === group.active,
                                          select: { group.active = doc },
                                          close: { TernEditor.confirmClose(doc, in: group, window: nil) })
                    }
                }
            }
            Spacer(minLength: 8)
            if let doc = group.active, doc.isMarkdown {
                TernModeToggle(doc: doc)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
    }
}

private struct TernEditorTabChip: View {
    @ObservedObject var doc: TernDocument
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: doc.isMarkdown ? "doc.richtext" : "doc.text")
                .font(.system(size: 10))
            Text(doc.name)
                .font(TernTheme.uiFont)
                .lineLimit(1)
            if doc.isDirty && !hovering {
                Circle().fill(TernTheme.textSecondary).frame(width: 6, height: 6).frame(width: 14)
                    .accessibilityLabel("Unsaved changes")
            } else {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .opacity(hovering || selected ? 1 : 0)
                .help("Close (⌘W)")
                .accessibilityLabel("Close \(doc.name)")
            }
        }
        .foregroundColor(selected ? TernTheme.textPrimary : TernTheme.textTertiary)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? TernTheme.selectedFill : (hovering ? TernTheme.hoverFill : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: select)
        .help(doc.url.path)
    }
}

/// The visible preview/source control (E-2).
private struct TernModeToggle: View {
    @ObservedObject var doc: TernDocument

    var body: some View {
        HStack(spacing: 0) {
            segment("Preview", .preview)
            segment("Source", .source)
        }
        .help("Toggle preview / source (⇧⌘M)")
    }

    private func segment(_ title: String, _ mode: TernDocument.Mode) -> some View {
        Button { doc.mode = mode } label: {
            Text(title)
                .font(TernTheme.uiFontSmall)
                .foregroundColor(doc.mode == mode ? TernTheme.textPrimary : TernTheme.textTertiary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(doc.mode == mode ? TernTheme.selectedFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(doc.mode == mode ? .isSelected : [])
    }
}

struct TernDocumentView: View {
    @ObservedObject var doc: TernDocument
    let group: TernEditorGroup
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            if doc.changedOnDisk {
                banner("This file changed on disk.", actions: [("Reload", { doc.reload() }), ("Keep Mine", { doc.keepMine() })])
            }
            if let error = doc.error {
                banner(error, actions: [("Dismiss", { doc.error = nil })])
            }
            ZStack {
                switch doc.mode {
                case .preview:
                    TernMarkdownPreview(doc: doc, group: group, background: background)
                case .source:
                    TernSourceEditor(doc: doc, group: group)
                }
            }
        }
    }

    private func banner(_ text: String, actions: [(String, () -> Void)]) -> some View {
        HStack(spacing: 12) {
            Text(text).font(TernTheme.uiFontSmall).foregroundColor(TernTheme.textSecondary)
                .lineLimit(2)
            Spacer()
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].0, action: actions[index].1)
                    .buttonStyle(.plain)
                    .font(TernTheme.uiFontSmall)
                    .foregroundColor(TernTheme.accent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(TernTheme.hoverFill)
    }
}

/// Responder container: routes ⌘S, ⌘W and ⇧⌘M to the document while the editor has
/// focus, whatever the state of Caps Lock (E-8).
final class TernEditorContainerView: NSView {
    weak var document: TernDocument?
    var closeDocument: (() -> Void)?

    @objc func saveDocument(_ sender: Any?) { document?.save() }
    @objc func toggleMarkdownPreview(_ sender: Any?) { document?.toggleMode() }

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
            document?.save()
            return true
        case ([.command, .shift], "m"):
            document?.toggleMode()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }
}

/// Plain-text source editing.
struct TernSourceEditor: NSViewRepresentable {
    @ObservedObject var doc: TernDocument
    let group: TernEditorGroup

    func makeCoordinator() -> Coordinator { Coordinator(doc: doc) }

    func makeNSView(context: Context) -> TernEditorContainerView {
        let container = TernEditorContainerView()
        container.document = doc
        container.closeDocument = { [weak doc, weak group, weak container] in
            guard let doc, let group else { return }
            TernEditor.confirmClose(doc, in: group, window: container?.window)
        }
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        if let textView = scroll.documentView as? NSTextView {
            textView.delegate = context.coordinator
            textView.drawsBackground = false
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.usesFindBar = true
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
            textView.textColor = TernTheme.textNSColor
            textView.insertionPointColor = TernTheme.accentNSColor
            textView.textContainerInset = NSSize(width: 12, height: 10)
            textView.string = doc.text
            textView.setAccessibilityLabel(doc.name)
        }
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    func updateNSView(_ container: TernEditorContainerView, context: Context) {
        guard let scroll = container.subviews.first as? NSScrollView,
              let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != doc.text {
            let selection = textView.selectedRanges
            textView.string = doc.text
            let length = (doc.text as NSString).length
            textView.selectedRanges = selection.compactMap { value in
                let range = value.rangeValue
                return range.location <= length ? NSValue(range: NSRange(location: range.location, length: min(range.length, length - range.location))) : nil
            }
            if textView.selectedRanges.isEmpty { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        }
        if textView.textColor != TernTheme.textNSColor { textView.textColor = TernTheme.textNSColor }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let doc: TernDocument
        init(doc: TernDocument) { self.doc = doc }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            doc.text = textView.string
        }

        /// Each document has its own undo history.
        func undoManager(for view: NSTextView) -> UndoManager? { doc.undoManager }
    }
}

/// Rendered Markdown (E-1, E-7): JavaScript off, relative links open in the editor,
/// `#anchors` scroll within the page, local images are inlined.
struct TernMarkdownPreview: NSViewRepresentable {
    @ObservedObject var doc: TernDocument
    let group: TernEditorGroup
    let background: Color

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TernEditorContainerView {
        let container = TernEditorContainerView()
        container.document = doc
        container.closeDocument = { [weak doc, weak group, weak container] in
            guard let doc, let group else { return }
            TernEditor.confirmClose(doc, in: group, window: container?.window)
        }
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
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
        render(web, context: context)
        return container
    }

    func updateNSView(_ container: TernEditorContainerView, context: Context) {
        guard let web = container.subviews.first as? WKWebView else { return }
        context.coordinator.group = group
        render(web, context: context)
    }

    private func render(_ web: WKWebView, context: Context) {
        let key = "\(doc.renderRevision):\(doc.text.hashValue):\(TernTheme.isLight)"
        guard context.coordinator.lastKey != key else { return }
        context.coordinator.lastKey = key
        context.coordinator.documentURL = doc.url
        context.coordinator.group = group
        let body = TernMarkdown.html(from: doc.text, baseURL: doc.url.deletingLastPathComponent())
        web.loadHTMLString(TernMarkdown.page(body: body, background: "transparent", light: TernTheme.isLight), baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastKey: String?
        var documentURL: URL?
        weak var group: TernEditorGroup?

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
                if let group, (try? TernTextFile.checkOpenable(target)) != nil, TernEditor.handles(target) || TernEditor.isMarkdown(target) {
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

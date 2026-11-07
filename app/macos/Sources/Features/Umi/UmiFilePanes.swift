import AppKit
import SwiftUI

/// Files open in panes of their own (E-1, E-9): a file pane is an ordinary pane (it splits,
/// moves, stacks, closes and is restored like any other) whose terminal is covered by the
/// file's editor. The terminal underneath is a shell in the file's folder that is never shown.
@MainActor
final class UmiFilePanes: ObservableObject {
    static let shared = UmiFilePanes()

    private struct Entry {
        weak var pane: Ghostty.SurfaceView?
        let doc: UmiDocument
        let host: UmiEditorGroup
    }

    @Published private var entries: [UUID: Entry] = [:]
    /// Panes whose dirty documents were already preserved when they left every window.
    private var preserved: Set<UUID> = []
    /// Panes closed on purpose without saving ("Don't Save", `editor close --force`): their
    /// edits are dropped, not preserved, unless undo brings the pane back.
    private var discarded: Set<UUID> = []

    func document(of pane: Ghostty.SurfaceView) -> UmiDocument? { entries[pane.id]?.doc }
    func host(of pane: Ghostty.SurfaceView) -> UmiEditorGroup? { entries[pane.id]?.host }
    func isFilePane(_ id: UUID) -> Bool { entries[id] != nil }

    func attach(_ doc: UmiDocument, to pane: Ghostty.SurfaceView) {
        entries[pane.id] = Entry(pane: pane, doc: doc, host: UmiEditorGroup(pane: pane))
        UmiFileIndex.noteOpened(doc.url.path)
        UmiState.shared.layoutDidChange()
    }

    /// The pane shows another file from now on (Save As): same pane, new document.
    func replaceDocument(of pane: Ghostty.SurfaceView, with doc: UmiDocument) {
        guard entries[pane.id] != nil else { return }
        attach(doc, to: pane)
    }

    /// Every file pane in a window, with its document.
    var open: [(pane: Ghostty.SurfaceView, doc: UmiDocument)] {
        let live = Set(UmiTopology.allSurfaces.map(ObjectIdentifier.init))
        return entries.values.compactMap { entry in
            guard let pane = entry.pane, live.contains(ObjectIdentifier(pane)) else { return nil }
            return (pane, entry.doc)
        }
    }

    /// The pane showing a file, if one does.
    func pane(showing url: URL) -> Ghostty.SurfaceView? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        return open.first { $0.doc.url.resolvingSymlinksInPath() == target }?.pane
    }

    /// Forget panes that are gone. A file pane that left every window (closed, or its tab
    /// closed) with unsaved edits has them saved or kept as a recovery copy, once (E-3); undo
    /// can still bring the pane back with its document.
    func prune() {
        let live = Set(UmiTopology.allSurfaces.map(\.id))
        for (id, entry) in entries {
            guard entry.pane != nil else {
                if entry.doc.isDirty, !discarded.contains(id) { entry.doc.preserveEdits() }
                entries[id] = nil
                preserved.remove(id)
                discarded.remove(id)
                continue
            }
            if live.contains(id) {
                preserved.remove(id)
                discarded.remove(id)
            } else if entry.doc.isDirty, !preserved.contains(id), !discarded.contains(id) {
                entry.doc.preserveEdits()
                preserved.insert(id)
            }
        }
    }

    // MARK: Opening

    /// Open a file in a pane of its own (E-1, E-9). A file already open shows where it is.
    /// Otherwise its pane goes to the right of `anchor`, unless `anchor`'s tab already shows
    /// three panes: then it gets a new tab right after that tab.
    @discardableResult
    static func open(_ url: URL, mode: UmiDocument.Mode?, near anchor: Ghostty.SurfaceView,
                     focus: Bool) throws -> (pane: Ghostty.SurfaceView, doc: UmiDocument) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = shared.pane(showing: url), let doc = shared.document(of: existing) {
            if let mode, doc.hasPreview { doc.mode = mode }
            if let location = UmiTopology.locate(existing), !location.window.tree(of: location.tab).contains(existing) {
                try UmiStacks.show(existing, focus: focus)
            } else if focus {
                UmiLayout.focusPane(existing, activate: true)
            }
            return (existing, doc)
        }
        let doc = try UmiDocument(url: url, mode: mode)
        doc.reviewWaiters = UmiEvents.shared.waiters(on: doc.url.path)
        let placed = try newPane(near: anchor, cwd: url.deletingLastPathComponent().path, for: url.lastPathComponent)
        shared.attach(doc, to: placed.pane)
        if focus { UmiLayout.focusPane(placed.pane, activate: true) }
        UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": placed.pane.umiID,
                                                "tab": placed.tab, "window": placed.window])
        return (placed.pane, doc)
    }

    /// A new pane for something opened from `anchor` (E-9): to the right of `anchor`, unless
    /// `anchor`'s tab already shows three panes: then in a new tab right after that tab. File
    /// panes and web panes are placed this way.
    static func newPane(near anchor: Ghostty.SurfaceView, cwd: String?,
                        for what: String) throws -> (pane: Ghostty.SurfaceView, tab: String, window: String) {
        guard let location = UmiTopology.locate(anchor) else { throw UmiError.notFound("the pane isn't in a window") }
        let window = location.window
        let tab = location.tab
        let tree = window.tree(of: tab)
        // A stack member that isn't on show: the new pane goes beside the member that is.
        let shownAnchor = tree.contains(anchor) ? anchor
            : (tab.stack(of: anchor).flatMap { window.shownMember(of: $0, in: tab) } ?? anchor)

        var options = UmiLayout.PaneOptions()
        options.cwd = cwd
        let created: [String: Any]
        if (tree.root?.leaves().count ?? 0) < maxPanesPerTab {
            created = try UmiLayout.split(shownAnchor, direction: .right, options: options, ratio: nil, focus: false)
        } else {
            let index = (window.index(of: tab) ?? window.tabs.count - 1) + 2   // 1-based, right after `tab`
            created = try UmiLayout.newTab(in: window, options: options, tabName: nil, color: .none, index: index,
                                            focus: false, inheritFrom: shownAnchor)
        }
        guard let id = created["pane"] as? String,
              let pane = UmiTopology.allSurfaces.first(where: { $0.umiID == id }) else {
            throw UmiError.failed("couldn't make a pane for \(what)")
        }
        return (pane, (created["tab"] as? String) ?? "", window.umiIDString)
    }

    /// New files get a pane in the caller's tab while it shows fewer than this many panes.
    static let maxPanesPerTab = 3

    // MARK: Closing

    /// Close a pane: a file pane with unsaved changes asks first (E-3).
    static func confirmClose(_ pane: Ghostty.SurfaceView) {
        guard let doc = shared.document(of: pane), let host = shared.host(of: pane) else {
            try? UmiLayout.closePane(pane)
            return
        }
        UmiEditor.confirmClose(doc, in: host, window: pane.window)
    }

    static func closePane(_ pane: Ghostty.SurfaceView, discarding: Bool = false) {
        let doc = shared.document(of: pane)
        if discarding { shared.discarded.insert(pane.id) }
        try? UmiLayout.closePane(pane)
        if let doc { UmiEvents.shared.emit("editor.closed", ["path": doc.url.path, "pane": pane.umiID]) }
    }

    // MARK: Focus

    /// What takes keyboard focus in each file pane (its text view or preview), by pane.
    private var focusTargets: [UUID: WeakBox<NSView>] = [:]

    func registerFocusTarget(_ view: NSView, for pane: UUID) { focusTargets[pane] = WeakBox(view) }

    /// Keyboard focus for a file pane goes to its editor.
    func focusEditor(of pane: Ghostty.SurfaceView) {
        guard entries[pane.id] != nil, let target = focusTargets[pane.id]?.value, let window = target.window else { return }
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    /// The editor took keyboard focus: its pane is the focused pane of its tab and window.
    func editorFocused(pane: Ghostty.SurfaceView) {
        guard let location = UmiTopology.locate(pane) else { return }
        location.tab.focusedSurface = pane
        if location.window.surfaceTree.contains(pane), location.window.focusedSurface !== pane {
            location.window.focusedSurfaceDidChange(to: pane)
        }
        UmiTopology.windowBecameCurrent(location.window)
    }
}

/// What a file pane's editor views open links and close through: their pane.
@MainActor
final class UmiEditorGroup {
    weak var pane: Ghostty.SurfaceView?

    init(pane: Ghostty.SurfaceView) { self.pane = pane }

    /// A file linked from this one: in a pane beside this one (or where it's already open).
    @discardableResult
    func open(_ url: URL, mode: UmiDocument.Mode?) throws -> UmiDocument {
        guard let pane else { throw UmiError.notFound("the pane is gone") }
        return try UmiFilePanes.open(url, mode: mode, near: pane, focus: true).doc
    }

    /// Close the document: its pane closes.
    func close(_ doc: UmiDocument, discarding: Bool = false) {
        guard let pane else { return }
        UmiFilePanes.closePane(pane, discarding: discarding)
    }
}

/// The files open in one tab's panes, shown or waiting in a stack (what `editor ls` lists).
@MainActor
final class UmiTabFiles {
    unowned let tab: UmiTab

    init(tab: UmiTab) { self.tab = tab }

    var files: [(pane: Ghostty.SurfaceView, doc: UmiDocument)] {
        guard let window = UmiTopology.locate(tab: tab) else { return [] }
        let panes = (window.tree(of: tab).root?.leaves() ?? []) + window.hiddenPanes(of: tab)
        return panes.compactMap { pane in UmiFilePanes.shared.document(of: pane).map { (pane, $0) } }
    }

    var documents: [UmiDocument] { files.map(\.doc) }
    var isEmpty: Bool { files.isEmpty }

    /// The file a command without a path is about: the focused pane's, else the file pane
    /// focused most recently, else the first.
    var active: UmiDocument? {
        let files = files
        if let focused = tab.effectiveFocusedSurface, let doc = UmiFilePanes.shared.document(of: focused) { return doc }
        if let recent = UmiFocusHistory.mostRecent(among: files.map(\.pane)) { return UmiFilePanes.shared.document(of: recent) }
        return files.first?.doc
    }

    func document(for url: URL) -> UmiDocument? {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        return documents.first { $0.url.resolvingSymlinksInPath() == target }
    }

    func pane(of doc: UmiDocument) -> Ghostty.SurfaceView? { files.first { $0.doc === doc }?.pane }

    /// Open a file from this tab (the palette, the file tree): beside its focused pane.
    @discardableResult
    func open(_ url: URL, mode: UmiDocument.Mode?, focus: Bool = true) throws -> (pane: Ghostty.SurfaceView, doc: UmiDocument) {
        guard let anchor = tab.effectiveFocusedSurface else { throw UmiError.notFound("the tab has no panes") }
        return try UmiFilePanes.open(url, mode: mode, near: anchor, focus: focus)
    }

    func close(_ doc: UmiDocument, discarding: Bool = false) {
        if let pane = pane(of: doc) { UmiFilePanes.closePane(pane, discarding: discarding) }
    }
}

// MARK: - The view over a file pane

/// Drawn over a file pane's terminal: a header (drag grip, name, preview/source) and the editor.
/// It's an AppKit view of its own, as the agent pane's is: SwiftUI drawn directly in the overlay
/// would sit under the terminal's view.
struct UmiFilePaneOverlay: View {
    let surfaceView: Ghostty.SurfaceView
    let background: Color
    @ObservedObject private var files = UmiFilePanes.shared

    var body: some View {
        if let doc = files.document(of: surfaceView), let host = files.host(of: surfaceView) {
            UmiFilePaneHosted(content: AnyView(UmiFilePaneContent(surfaceView: surfaceView, doc: doc, host: host,
                                                                   background: background)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct UmiFilePaneHosted: NSViewRepresentable {
    let content: AnyView

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: content)
        view.sizingOptions = []
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) { view.rootView = content }

    /// Always exactly the pane's size.
    @available(macOS 13.0, *)
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSHostingView<AnyView>, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 400, height: 300))
    }
}

private struct UmiFilePaneContent: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var doc: UmiDocument
    let host: UmiEditorGroup
    let background: Color

    var body: some View {
        VStack(spacing: 0) {
            UmiFilePaneHeader(surfaceView: surfaceView, doc: doc)
            UmiDocumentView(doc: doc, group: host, background: background)
                .id(doc.id)
        }
        .background(background)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Editor")
    }
}

/// What the header's ⋯ button and its right-click menu offer, as Warp's ⋯ menus do. The source
/// view's is the code view's (W: `code/view.rs` `overflow_menu_items`): Maximize pane (Minimize
/// pane when it is), Copy file path, Reveal in Finder, and View Markdown preview for Markdown. A
/// preview's is the rendered Markdown pane's (W: `notebooks/file/mod.rs`): Maximize pane, Refresh
/// file, Open in editor (the source view), Copy file path. The header's right-click menu is an Umi
/// addition: Warp's header has none.
@MainActor
enum UmiFilePaneMenu {
    struct Item {
        let title: String
        let enabled: Bool
        let action: () -> Void
        /// A separator goes before this item.
        var separated = false
    }

    static func items(for pane: Ghostty.SurfaceView, doc: UmiDocument) -> [Item] {
        let location = UmiTopology.locate(pane)
        let tree = location.map { $0.window.tree(of: $0.tab) }
        let node = tree?.root?.node(view: pane)
        let maximized = node != nil && tree?.zoomed == node
        // Warp never disables it; outside a split there is nothing to maximize, so it does nothing.
        let toggle = Item(title: maximized ? "Minimize pane" : "Maximize pane", enabled: true) {
            guard maximized || (tree?.isSplit ?? false) else { return }
            if (try? UmiLayout.toggleZoom(pane)) == nil { NSSound.beep() }
        }
        let copyPath = Item(title: "Copy file path", enabled: true, action: {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(doc.url.path, forType: .string)
        }, separated: true)
        if doc.mode == .preview {
            return [
                toggle,
                Item(title: "Refresh file", enabled: true, action: { reload(doc, window: pane.window) }, separated: true),
                Item(title: "Open in editor", enabled: true) { doc.mode = .source },
                copyPath,
            ]
        }
        var items = [
            toggle,
            copyPath,
            Item(title: "Reveal in Finder", enabled: true) {
                NSWorkspace.shared.activateFileViewerSelecting([doc.url])
            },
        ]
        if doc.isMarkdown {
            items.append(Item(title: "View Markdown preview", enabled: true) { doc.mode = .preview })
        }
        return items
    }

    /// Read the file again; unsaved edits are dropped only after asking (E-3).
    static func reload(_ doc: UmiDocument, window: NSWindow?) {
        guard doc.isDirty else {
            doc.reload()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reload “\(doc.name)” from disk?"
        alert.informativeText = "Your unsaved changes will be lost."
        alert.addButton(withTitle: "Reload")
        alert.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { if $0 == .alertFirstButtonReturn { doc.reload() } }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }
}

/// The file pane's header (E-24; Alejo's choice of 2026-11-07, the same row as a hosted page's):
/// the drag grip, the file type's icon and "folder / name" on the left (a dot before the name while
/// there are unsaved changes), and on the right Preview / Source (E-2), ⋯ (the pane menu, also on
/// right-click) and close.
private struct UmiFilePaneHeader: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var doc: UmiDocument

    var body: some View {
        UmiPaneHeaderBar(surfaceView: surfaceView) {
            UmiFileIcon(url: doc.url)
            UmiPathTitle(folder: Self.folder(of: doc.url), name: doc.name, dirty: doc.isDirty, help: doc.url.path)
        } trailing: {
            if doc.hasPreview { UmiModeToggle(doc: doc) }
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundColor(UmiTheme.textTertiary)
            .help("More")
            .accessibilityLabel("More actions")
            UmiPaneHeaderButton(symbol: "xmark", help: "Close (⌘W)", label: "Close \(doc.name)", size: 8) {
                UmiFilePanes.confirmClose(surfaceView)
            }
        }
        .contentShape(Rectangle())
        .contextMenu { menuItems }
    }

    /// The parent folder's name; none at the volume's root.
    static func folder(of url: URL) -> String? {
        let parent = url.deletingLastPathComponent()
        return parent.path == "/" ? nil : parent.lastPathComponent
    }

    @ViewBuilder private var menuItems: some View {
        ForEach(Array(UmiFilePaneMenu.items(for: surfaceView, doc: doc).enumerated()), id: \.offset) { _, item in
            if item.separated { Divider() }
            Button(item.title, action: item.action).disabled(!item.enabled)
        }
    }
}

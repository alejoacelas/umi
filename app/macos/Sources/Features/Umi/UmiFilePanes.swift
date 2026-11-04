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

    func document(of pane: Ghostty.SurfaceView) -> UmiDocument? { entries[pane.id]?.doc }
    func host(of pane: Ghostty.SurfaceView) -> UmiEditorGroup? { entries[pane.id]?.host }
    func isFilePane(_ id: UUID) -> Bool { entries[id] != nil }

    func attach(_ doc: UmiDocument, to pane: Ghostty.SurfaceView) {
        entries[pane.id] = Entry(pane: pane, doc: doc, host: UmiEditorGroup(pane: pane))
        UmiFileIndex.noteOpened(doc.url.path)
        UmiState.shared.layoutDidChange()
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
                if entry.doc.isDirty { entry.doc.preserveEdits() }
                entries[id] = nil
                preserved.remove(id)
                continue
            }
            if live.contains(id) {
                preserved.remove(id)
            } else if entry.doc.isDirty, !preserved.contains(id) {
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
        guard let location = UmiTopology.locate(anchor) else { throw UmiError.notFound("the pane isn't in a window") }
        let window = location.window
        let tab = location.tab
        let tree = window.tree(of: tab)
        // A stack member that isn't on show: the file goes beside the member that is.
        let shownAnchor = tree.contains(anchor) ? anchor
            : (tab.stack(of: anchor).flatMap { window.shownMember(of: $0, in: tab) } ?? anchor)

        var options = UmiLayout.PaneOptions()
        options.cwd = url.deletingLastPathComponent().path
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
            throw UmiError.failed("couldn't make a pane for \(url.lastPathComponent)")
        }
        shared.attach(doc, to: pane)
        if focus { UmiLayout.focusPane(pane, activate: true) }
        UmiEvents.shared.emit("editor.opened", ["path": doc.url.path, "pane": pane.umiID,
                                                "tab": (created["tab"] as? String) ?? "", "window": window.umiIDString])
        return (pane, doc)
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

    static func closePane(_ pane: Ghostty.SurfaceView) {
        let doc = shared.document(of: pane)
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
    func close(_ doc: UmiDocument) {
        guard let pane else { return }
        UmiFilePanes.closePane(pane)
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

    func close(_ doc: UmiDocument) {
        if let pane = pane(of: doc) { UmiFilePanes.closePane(pane) }
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

private struct UmiFilePaneHosted: NSViewRepresentable {
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

private struct UmiFilePaneHeader: View {
    let surfaceView: Ghostty.SurfaceView
    @ObservedObject var doc: UmiDocument
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(hovering ? UmiTheme.textSecondary : UmiTheme.textTertiary)
                Ghostty.SurfaceDragSource(surfaceView: surfaceView, isDragging: $dragging, isHovering: $hovering)
            }
            .frame(width: 22, height: 18)
            .help("Drag to move this pane")
            Image(systemName: UmiEditor.icon(for: doc.url)).font(.system(size: 10))
                .foregroundColor(UmiTheme.textSecondary)
            Text(doc.name)
                .font(UmiTheme.uiFont)
                .foregroundColor(UmiTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(doc.url.path)
            if doc.isDirty {
                Circle().fill(UmiTheme.textSecondary).frame(width: 6, height: 6)
                    .accessibilityLabel("Unsaved changes")
            }
            Spacer(minLength: 8)
            if doc.hasPreview { UmiModeToggle(doc: doc).fixedSize() }
            Button { UmiFilePanes.confirmClose(surfaceView) } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .foregroundColor(UmiTheme.textTertiary)
            .help("Close (⌘W)")
            .accessibilityLabel("Close \(doc.name)")
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
    }
}

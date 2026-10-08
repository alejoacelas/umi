import AppKit
import Combine
import SwiftUI

/// A node in the project explorer. Directory children load lazily.
@MainActor
final class TernFileNode: ObservableObject, Identifiable {
    let url: URL
    let isDirectory: Bool
    @Published var expanded = false
    @Published private(set) var children: [TernFileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }

    /// Names never shown in the explorer.
    static let hidden: Set<String> = [".git", ".DS_Store", ".hg", ".svn"]
    static let maxEntries = 3000

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
    }

    func loadChildren(force: Bool = false) {
        guard isDirectory, force || children == nil else { return }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: [])) ?? []
        var nodes: [TernFileNode] = []
        for entry in entries.prefix(Self.maxEntries) {
            let name = entry.lastPathComponent
            if Self.hidden.contains(name) { continue }
            let values = try? entry.resourceValues(forKeys: Set(keys))
            // Dotfiles are shown (like .github, .env.example) but Finder-hidden items aren't.
            if values?.isHidden == true && !name.hasPrefix(".") { continue }
            nodes.append(TernFileNode(url: entry, isDirectory: values?.isDirectory ?? false))
        }
        nodes.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        // Preserve expansion state across refreshes.
        if let old = children {
            let expandedOld = Dictionary(uniqueKeysWithValues: old.filter(\.expanded).map { ($0.url, $0) })
            nodes = nodes.map { expandedOld[$0.url] ?? $0 }
            for node in nodes where node.expanded { node.loadChildren(force: true) }
        }
        children = nodes
    }
}

/// Tracks which folder the explorer shows: the git root (or working
/// directory) of the focused pane in the hosting window.
@MainActor
final class TernFileTreeModel: ObservableObject {
    @Published private(set) var root: TernFileNode?
    private var timer: Timer?

    func update(window: NSWindow?) {
        guard let controller = window?.windowController as? TerminalController,
              !controller.tabs.isEmpty,
              let pane = controller.focusedSurface ?? controller.selectedTab.effectiveFocusedSurface else { return }
        let pwd = TernTopology.cwd(of: pane)
        guard !pwd.isEmpty else { return }
        let rootURL = Self.projectRoot(for: URL(fileURLWithPath: pwd))
        guard root?.url != rootURL else { return }
        let node = TernFileNode(url: rootURL, isDirectory: true)
        node.expanded = true
        node.loadChildren()
        root = node
    }

    func refresh() {
        root?.loadChildren(force: true)
    }

    /// Follow the focused pane while the explorer is visible.
    func start(window: @escaping () -> NSWindow?) {
        stop()
        update(window: window())
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update(window: window()) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    static func projectRoot(for url: URL) -> URL {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return url.standardizedFileURL
    }
}

/// The project explorer tree.
struct TernFileTreeView: View {
    @ObservedObject var model: TernFileTreeModel
    let hostWindow: NSWindow?

    var body: some View {
        if let root = model.root {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(root.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(TernTheme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    Button { model.refresh() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(TernTheme.textTertiary)
                    .help("Refresh")
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .help(root.url.path)

                if let children = root.children {
                    ForEach(children) { node in
                        TernFileRow(node: node, depth: 0, hostWindow: hostWindow)
                    }
                }
            }
        } else {
            Text("Open a folder in a pane to browse it here.")
                .font(TernTheme.uiFontSmall)
                .foregroundColor(TernTheme.textTertiary)
                .padding(.horizontal, 8)
        }
    }
}

private struct TernFileRow: View {
    @ObservedObject var node: TernFileNode
    let depth: Int
    let hostWindow: NSWindow?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Group {
                    if node.isDirectory {
                        Image(systemName: node.expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(TernTheme.textTertiary)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 10)
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(node.isDirectory ? TernTheme.textSecondary : TernTheme.textTertiary)
                    .frame(width: 14)
                Text(node.name)
                    .font(.system(size: 12))
                    .foregroundColor(node.name.hasPrefix(".") ? TernTheme.textTertiary : TernTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 12 + 4)
            .padding(.trailing, 6)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? TernTheme.hoverFill : .clear))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { activate() }
            .contextMenu { menu }

            if node.isDirectory, node.expanded, let children = node.children {
                ForEach(children) { child in
                    TernFileRow(node: child, depth: depth + 1, hostWindow: hostWindow)
                }
            }
        }
    }

    private var icon: String {
        if node.isDirectory { return "folder" }
        switch node.url.pathExtension.lowercased() {
        case "md", "markdown", "mdx": return "doc.richtext"
        case "swift", "zig", "rs", "go", "py", "js", "ts", "tsx", "jsx", "c", "h", "cpp", "java", "rb", "sh":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml": return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "svg", "webp": return "photo"
        default: return "doc.text"
        }
    }

    private var controller: TerminalController? {
        hostWindow?.windowController as? TerminalController
    }

    private func activate() {
        if node.isDirectory {
            node.expanded.toggle()
            if node.expanded { node.loadChildren() }
        } else if TernEditor.handles(node.url) || TernEditor.isMarkdown(node.url) {
            openInEditor()
        } else {
            NSWorkspace.shared.open(node.url)
        }
    }

    private func openInEditor() {
        guard let controller else { return }
        do {
            try controller.selectedTab.editor.open(node.url, mode: nil)
        } catch let error as TernError {
            let alert = NSAlert()
            alert.messageText = "Can't open \(node.name)"
            alert.informativeText = error.message
            if let window = hostWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
        } catch {}
    }

    @ViewBuilder
    private var menu: some View {
        if !node.isDirectory {
            Button("Open in Editor") { openInEditor() }
            Button("Open with Default App") { NSWorkspace.shared.open(node.url) }
        } else {
            Button("Open Terminal Here") {
                guard let controller else { return }
                var options = TernLayout.PaneOptions()
                options.cwd = node.url.path
                _ = try? TernLayout.newTab(in: controller, options: options, tabName: nil, color: .none,
                                           index: nil, focus: true, inheritFrom: nil)
            }
        }
        Button("Insert Path in Terminal") {
            guard let controller, let pane = controller.focusedSurface ?? controller.selectedTab.effectiveFocusedSurface else { return }
            Task { @MainActor in
                try? await TernInput.send(text: Ghostty.Shell.quote(node.url.path) + " ", to: pane, enter: false)
            }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        }
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }
    }
}

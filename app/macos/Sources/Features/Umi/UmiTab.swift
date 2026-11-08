import AppKit
import Combine

/// One tab of an Umi window: a split tree of panes plus the tab's own name, color, pin
/// and editor documents.
///
/// Tabs are Umi's own model, not AppKit window tabs. A window shows its selected tab's
/// split tree; the other tabs' panes keep running off screen. Moving a tab between windows
/// moves this object, so everything about it (programs, scrollback, editor documents)
/// comes along.
@MainActor
final class UmiTab: ObservableObject, Identifiable {
    let id: UUID

    /// The user-given name, or nil for the default (the focused pane's folder/title).
    @Published var name: String?
    @Published var color: TerminalTabColor = .none
    @Published var pinned: Bool = false
    /// The tab's attributes (`umi tab set`, UmiAttributes).
    @Published var attributes: [String: String] = [:]
    /// The tab Markdown files opened from outside Umi share (`UmiDocsTab`): the tab with the
    /// attribute `role=docs` (design/cli.md, choice 10).
    var isDocs: Bool {
        get { attributes["role"] == "docs" }
        set {
            if newValue {
                attributes["role"] = "docs"
            } else if attributes["role"] == "docs" {
                attributes.removeValue(forKey: "role")
            }
        }
    }
    /// The tab group it belongs to in its window (`UmiTabGroups`), if any.
    @Published var groupID: UUID?

    /// The split tree. For the window's selected tab, the controller's `surfaceTree` is
    /// the live copy and this is kept in sync with it.
    @Published var tree: SplitTree<Ghostty.SurfaceView>

    /// The pane that has (or last had) focus in this tab.
    weak var focusedSurface: Ghostty.SurfaceView?

    /// The tab's hidden panes (attention-ui.md, "Hidden panes"), in strip order: out of the
    /// split tree, still in the tab, their programs running. `UmiHidden` keeps it.
    @Published var hidden: [Ghostty.SurfaceView] = []

    /// How many panes the tab shows at most: the tab attribute `visible_limit`, default 3, at
    /// least 1 (design/cli.md, "Keys with a meaning to Umi").
    var visibleLimit: Int {
        guard let raw = attributes["visible_limit"], let n = Int(raw.trimmingCharacters(in: .whitespaces)) else { return 3 }
        return max(n, 1)
    }

    /// The files open in this tab's panes (each file is a pane of its own).
    private(set) lazy var editor = UmiTabFiles(tab: self)

    init(id: UUID = UUID(), tree: SplitTree<Ghostty.SurfaceView>) {
        self.id = id
        self.tree = tree
        self.focusedSurface = tree.root?.leftmostLeaf()
    }

    var idString: String { id.uuidString.lowercased() }

    var panes: [Ghostty.SurfaceView] { tree.root?.leaves() ?? [] }

    /// The focused pane if it's still in the tab, else the one of its panes used most
    /// recently (L-18), else the first pane.
    var effectiveFocusedSurface: Ghostty.SurfaceView? {
        if let focusedSurface, tree.contains(focusedSurface) { return focusedSurface }
        return UmiFocusHistory.mostRecent(among: panes) ?? tree.root?.leftmostLeaf()
    }

    /// Whether the pane is in this tab: on show in its tree, or hidden.
    func contains(_ surface: Ghostty.SurfaceView) -> Bool {
        tree.contains(surface) || isHidden(surface)
    }

    func isHidden(_ pane: Ghostty.SurfaceView) -> Bool { hidden.contains { $0 === pane } }

    /// What the tab is called when it has no name: the focused pane's title or folder.
    var title: String {
        if let name, !name.isEmpty { return name }
        if let pane = effectiveFocusedSurface {
            if let pwd = pane.pwd, !pwd.isEmpty { return UmiPaneContext.folderName(pwd) }
            if !pane.title.isEmpty, pane.title != "👻" { return pane.title }
        }
        return "Terminal"
    }
}

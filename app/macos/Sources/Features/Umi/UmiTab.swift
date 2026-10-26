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

    /// The split tree. For the window's selected tab, the controller's `surfaceTree` is
    /// the live copy and this is kept in sync with it.
    @Published var tree: SplitTree<Ghostty.SurfaceView>

    /// The pane that has (or last had) focus in this tab.
    weak var focusedSurface: Ghostty.SurfaceView?

    /// Files open in this tab's editor panel.
    let editor = UmiEditorGroup()

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

    func contains(_ surface: Ghostty.SurfaceView) -> Bool { tree.contains(surface) }

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

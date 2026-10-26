import AppKit
import Combine

/// App-wide Umi state that isn't owned by a window: the sidebar, pane names, panes'
/// starting folders and interactive agents. Views observe `revision`, which is bumped
/// (coalesced, once per runloop turn) whenever the layout may have changed.
@MainActor
final class UmiState: ObservableObject {
    static let shared = UmiState()

    enum SidebarMode: String, Codable { case tabs, files }

    @Published var sidebarVisible: Bool = true {
        didSet {
            guard sidebarVisible != oldValue else { return }
            UmiPersistence.shared.saveUISoon()
            UmiEvents.shared.emit("sidebar.changed", ["visible": sidebarVisible, "mode": sidebarMode.rawValue])
        }
    }

    @Published var sidebarMode: SidebarMode = .tabs {
        didSet {
            guard sidebarMode != oldValue else { return }
            UmiPersistence.shared.saveUISoon()
            UmiEvents.shared.emit("sidebar.changed", ["visible": sidebarVisible, "mode": sidebarMode.rawValue])
        }
    }

    /// The sidebar width a new window starts with: the one last chosen in any window (S-8).
    /// Each window keeps its own (`TerminalController.sidebarWidth`).
    var sidebarWidth: CGFloat = UmiTheme.sidebarWidth {
        didSet {
            guard sidebarWidth != oldValue else { return }
            UmiPersistence.shared.saveUISoon()
        }
    }

    /// Bumped whenever windows, tabs or panes may have changed.
    @Published private(set) var revision: Int = 0

    /// User-given pane names, by pane id.
    @Published private(set) var paneNames: [UUID: String] = [:]

    /// The folder each pane was started in, until its shell reports one.
    private(set) var paneStartFolders: [UUID: String] = [:]

    /// Agents launched as typed (`umi claude`), by pane.

    private var pendingBump = false

    // MARK: Layout changes

    /// Coalesce layout change notifications into one update per runloop turn. Also
    /// schedules saving the layout.
    func layoutDidChange(persistOnly: Bool = false) {
        UmiPersistence.shared.saveLayoutSoon()
        guard !persistOnly, !pendingBump else { return }
        pendingBump = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBump = false
            self.revision &+= 1
            self.prune()
            // Panes opened, closed or moved: Window > Agent Sessions marks the shown sessions,
            // and `agent ls` says where each session is.
            UmiAgentMenu.shared.setNeedsRebuild()
            UmiAgentUI.publishShownPanes()
        }
    }

    func windowCreated(_ controller: TerminalController) {
        UmiEvents.shared.emit("window.created", ["window": controller.umiIDString])
        for tab in controller.tabs {
            UmiEvents.shared.emit("tab.created", ["tab": tab.idString, "window": controller.umiIDString])
        }
        layoutDidChange()
    }

    func windowClosed(_ controller: TerminalController) {
        UmiTopology.windowClosed(controller)
        layoutDidChange()
    }

    // MARK: Panes

    func paneName(_ id: UUID) -> String? { paneNames[id] }

    func setPaneName(_ id: UUID, _ name: String?) {
        if let name, !name.isEmpty {
            paneNames[id] = name
        } else {
            paneNames.removeValue(forKey: id)
        }
        layoutDidChange()
    }

    func setStartFolder(_ id: UUID, _ folder: String?) {
        guard let folder, !folder.isEmpty else { return }
        paneStartFolders[id] = folder
    }

    func startFolder(_ id: UUID) -> String? { paneStartFolders[id] }

    /// Forget per-pane state of panes that no longer exist (except while undo could still
    /// bring them back: a pane in no window but still alive keeps its state).
    private func prune() {
        guard paneNames.count + paneStartFolders.count > 256 else { return }
        let live = Set(UmiTopology.allSurfaces.map(\.id))
        paneNames = paneNames.filter { live.contains($0.key) }
        paneStartFolders = paneStartFolders.filter { live.contains($0.key) }
    }
}


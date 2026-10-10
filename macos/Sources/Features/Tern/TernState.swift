import AppKit
import Combine

/// App-wide Tern state that isn't owned by a window: the sidebar, pane names, panes'
/// starting folders and interactive agents. Views observe `revision`, which is bumped
/// (coalesced, once per runloop turn) whenever the layout may have changed.
@MainActor
final class TernState: ObservableObject {
    static let shared = TernState()

    enum SidebarMode: String, Codable { case tabs, files }

    @Published var sidebarVisible: Bool = true {
        didSet {
            guard sidebarVisible != oldValue else { return }
            TernPersistence.shared.saveUISoon()
            TernEvents.shared.emit("sidebar.changed", ["visible": sidebarVisible, "mode": sidebarMode.rawValue])
        }
    }

    @Published var sidebarMode: SidebarMode = .tabs {
        didSet {
            guard sidebarMode != oldValue else { return }
            TernPersistence.shared.saveUISoon()
            TernEvents.shared.emit("sidebar.changed", ["visible": sidebarVisible, "mode": sidebarMode.rawValue])
        }
    }

    /// The sidebar width a new window starts with: the one last chosen in any window (S-8).
    /// Each window keeps its own (`TerminalController.sidebarWidth`).
    var sidebarWidth: CGFloat = TernTheme.sidebarWidth {
        didSet {
            guard sidebarWidth != oldValue else { return }
            TernPersistence.shared.saveUISoon()
        }
    }

    /// Bumped whenever windows, tabs or panes may have changed.
    @Published private(set) var revision: Int = 0

    /// User-given pane names, by pane id.
    @Published private(set) var paneNames: [UUID: String] = [:]

    /// The folder each pane was started in, until its shell reports one.
    private(set) var paneStartFolders: [UUID: String] = [:]

    /// Agents launched as typed (`tern claude`), by pane.
    @Published private(set) var interactiveAgents: [UUID: TernInteractiveAgent] = [:]

    private var pendingBump = false

    // MARK: Layout changes

    /// Coalesce layout change notifications into one update per runloop turn. Also
    /// schedules saving the layout.
    func layoutDidChange(persistOnly: Bool = false) {
        TernPersistence.shared.saveLayoutSoon()
        guard !persistOnly, !pendingBump else { return }
        pendingBump = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingBump = false
            self.revision &+= 1
            self.prune()
            // Panes opened, closed or moved: Window > Agent Sessions marks the shown sessions,
            // and `agent ls` says where each session is.
            TernAgentMenu.shared.setNeedsRebuild()
            TernAgentUI.publishShownPanes()
        }
    }

    func windowCreated(_ controller: TerminalController) {
        TernEvents.shared.emit("window.created", ["window": controller.ternIDString])
        for tab in controller.tabs {
            TernEvents.shared.emit("tab.created", ["tab": tab.idString, "window": controller.ternIDString])
        }
        layoutDidChange()
    }

    func windowClosed(_ controller: TerminalController) {
        TernTopology.windowClosed(controller)
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

    func setInteractiveAgent(_ id: UUID, _ agent: TernInteractiveAgent?) {
        interactiveAgents[id] = agent
        layoutDidChange()
    }

    /// Forget per-pane state of panes that no longer exist (except while undo could still
    /// bring them back: a pane in no window but still alive keeps its state).
    private func prune() {
        guard paneNames.count + paneStartFolders.count + interactiveAgents.count > 256 else { return }
        let live = Set(TernTopology.allSurfaces.map(\.id))
        paneNames = paneNames.filter { live.contains($0.key) }
        paneStartFolders = paneStartFolders.filter { live.contains($0.key) }
        interactiveAgents = interactiveAgents.filter { live.contains($0.key) }
    }
}

/// An agent launched in a pane exactly as if typed (`tern claude …`). Tern doesn't control
/// it; it only notes whether it is still running (IA-2).
struct TernInteractiveAgent: Equatable {
    let kind: String
    let commandLine: String
    var running: Bool
    var exitCode: Int?
}

import AppKit
import Combine
import GhosttyKit

/// Sessions in the app's windows (AG-5 to AG-9).
///
/// A session is shown in an ordinary pane: a terminal leaf with the session's read-only view
/// drawn over it (DECISIONS.md §1). The pane is a terminal in the session's folder, so it
/// splits, moves, swaps, zooms, closes and undoes, drags and is saved like any other pane.
/// Take Over types `tern agent attach` into that terminal and the view steps aside: the
/// agent's own interface runs there, live. Closing a read-only pane never touches the
/// session.
@MainActor
final class TernAgentUI: ObservableObject {
    static let shared = TernAgentUI()

    /// Pane id → session id. Kept for closed panes too, so undoing a close brings the
    /// session's view back with the pane.
    @Published var attachments: [UUID: String] = [:] {
        didSet { Self.publishShownPanes() }
    }
    /// Agent panes currently showing their terminal instead of the session.
    @Published var showingTerminal: Set<UUID> = []
    /// Panes where the session's own interface runs (or is starting): the view steps aside.
    @Published var livePanes: Set<UUID> = []
    /// Live interfaces removed from their panes (AG-8): out of sight, finishing their turn.
    var parked: [String: Ghostty.SurfaceView] = [:]

    private var models: [String: TernAgentViewModel] = [:]

    // MARK: Session updates from the agent queue

    static func sessionChanged(_ id: String, _ snapshot: TernAgentSnapshot?) {
        guard let snapshot else { return }
        let ui = shared
        let previous = ui.models[id]?.snapshot
        ui.model(for: id).snapshot = snapshot
        if previous?.status != snapshot.status || previous?.activity != snapshot.activity || previous?.name != snapshot.name
            || previous?.location != snapshot.location || previous?.pane != snapshot.pane || previous?.title != snapshot.title {
            TernState.shared.layoutDidChange(persistOnly: false)
            TernAgentMenu.shared.setNeedsRebuild()
            if previous?.status != snapshot.status {
                TernEvents.shared.emit("agent.status", ["session": id, "name": snapshot.name, "status": snapshot.status])
            }
        }
        // The sidebar's marks, ordering and the Dock badge (no desktop notifications).
        publishAttention(snapshot, previous: previous)
    }

    static func sessionRemoved(_ id: String) {
        let ui = shared
        ui.models[id]?.removed = true
        attentionRemoved(id)
        TernAgentMenu.shared.setNeedsRebuild()
        TernAgentMenu.shared.statusChanged(id, status: nil)
    }

    func model(for id: String) -> TernAgentViewModel {
        if let model = models[id] { return model }
        let model = TernAgentViewModel(sessionID: id)
        models[id] = model
        // First look: ask the agent queue for the current state.
        TernAgents.queue.async {
            let snapshot = TernAgents.shared.session(id: id)?.snapshot()
            DispatchQueue.main.async { MainActor.assumeIsolated { if let snapshot { model.snapshot = snapshot } else { model.removed = true } } }
        }
        return model
    }

    func snapshot(for id: String) -> TernAgentSnapshot? { models[id]?.snapshot ?? model(for: id).snapshot }

    // MARK: Attachments

    func session(forPane id: UUID) -> String? { attachments[id] }

    func attach(_ pane: UUID, session: String) {
        attachments[pane] = session
        showingTerminal.remove(pane)
        TernState.shared.layoutDidChange()
        TernAgentMenu.shared.setNeedsRebuild()
        // The session's pane is this one (a restored pane has a new id).
        let ternID = pane.uuidString.lowercased()
        TernAgents.queue.async {
            guard let s = TernAgents.shared.session(id: session) else { return }
            if s.record.pane != ternID {
                s.record.pane = ternID
                s.saveRecord()
                s.changed()
            }
            // A session that was live here before a quit goes live again now its pane is back.
            s.checkSettled()
        }
    }

    func detach(_ pane: UUID) {
        attachments.removeValue(forKey: pane)
        showingTerminal.remove(pane)
        TernState.shared.layoutDidChange()
        TernAgentMenu.shared.setNeedsRebuild()
    }

    /// Session id → the pane showing it, readable from the agent queue (`agent ls`, AG-14).
    private static let shownLock = NSLock()
    nonisolated(unsafe) private static var shown: [String: String] = [:]

    nonisolated static func shownPane(of session: String) -> String? {
        shownLock.lock()
        defer { shownLock.unlock() }
        return shown[session]
    }

    static func publishShownPanes() {
        let map = panesBySession()
        shownLock.lock()
        let before = shown
        shown = map
        shownLock.unlock()
        // A session whose pane closed (or that a pane shows now): its mark moves with it, to the
        // background list (Dock badge, ⌃⌘J) or to its new pane.
        for id in Set(before.keys).union(map.keys) where before[id] != map[id] {
            if let snapshot = shared.snapshot(for: id) { publishAttention(snapshot, previous: snapshot) }
        }
    }

    /// Panes in a window (not closed ones) that show a session: session id → pane id.
    static func panesBySession() -> [String: String] {
        var out: [String: String] = [:]
        for pane in TernTopology.allSurfaces {
            if let session = shared.attachments[pane.id], out[session] == nil { out[session] = pane.ternID }
        }
        return out
    }

    static func livePane(for session: String) -> Ghostty.SurfaceView? {
        TernTopology.allSurfaces.first { shared.attachments[$0.id] == session }
    }

    func isShowingAgent(_ pane: UUID) -> Bool {
        attachments[pane] != nil && !showingTerminal.contains(pane) && !livePanes.contains(pane)
    }

    func toggleTerminal(_ pane: Ghostty.SurfaceView) {
        if showingTerminal.contains(pane.id) {
            showingTerminal.remove(pane.id)
            focusAgentView(of: pane)
        } else {
            showingTerminal.insert(pane.id)
            DispatchQueue.main.async { Ghostty.moveFocus(to: pane) }
        }
    }

    // MARK: Opening (AP-3)

    /// Show a session: focus the pane already showing it, or make a new tab, split or window
    /// for it. Without focus, nothing about the user's focus changes (L-8).
    static func open(_ sessionID: String, placement: TernAgentRPC.Placement, caller: TernCaller) throws -> String {
        if let existing = livePane(for: sessionID) {
            // Showing the session again means showing it, not its shell.
            shared.showingTerminal.remove(existing.id)
            if placement.focus {
                TernLayout.focusPane(existing, activate: true)
                DispatchQueue.main.async { shared.focusAgentView(of: existing) }
            }
            return existing.ternID
        }
        let cwd = TernAgents.queue.sync { TernAgents.shared.session(id: sessionID)?.record.cwd }
        guard let cwd else { throw TernError.notFound("no such session") }
        var options = TernLayout.PaneOptions()
        var isDir = ObjCBool(false)
        options.cwd = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue ? cwd : NSHomeDirectory()
        let result: [String: Any]
        switch placement.kind {
        case .split:
            let target = try placement.pane.map { try TernTopology.resolvePane($0, caller: caller) }
                ?? (try? TernTopology.callerPane(caller)) ?? TernTopology.currentPane
            if let target {
                result = try TernLayout.split(target, direction: try TernLayout.direction(placement.direction),
                                              options: options, ratio: nil, focus: placement.focus)
            } else {
                result = try TernLayout.newWindow(options, tabName: nil, focus: placement.focus)
            }
        case .window:
            result = try TernLayout.newWindow(options, tabName: nil, focus: placement.focus)
        case .tab:
            let window = try placement.window.map { try TernTopology.resolveWindow($0, caller: caller) }
                ?? ((try? TernTopology.callerPane(caller)).flatMap { $0 }.flatMap { TernTopology.locate($0)?.window })
                ?? TernTopology.currentWindow
            if let window {
                result = try TernLayout.newTab(in: window, options: options, tabName: nil, color: .none, index: nil,
                                               focus: placement.focus, inheritFrom: nil)
            } else {
                result = try TernLayout.newWindow(options, tabName: nil, focus: placement.focus)
            }
        }
        guard let paneID = result["pane"] as? String,
              let pane = TerminalController.all.lazy.flatMap(\.allSurfaces).first(where: { $0.ternID == paneID }) else {
            throw TernError.failed("couldn't make a pane for the session")
        }
        shared.attach(pane.id, session: sessionID)
        let paneTernID = pane.ternID
        TernAgents.queue.async {
            guard let session = TernAgents.shared.session(id: sessionID) else { return }
            session.record.pane = paneTernID
            session.saveRecord()
            session.changed()
        }
        if placement.focus {
            DispatchQueue.main.async { shared.focusAgentView(of: pane) }
        }
        TernEvents.shared.emit("agent.opened", ["session": sessionID, "pane": paneID])
        return paneID
    }

    // MARK: Focus (L-8)

    /// What takes keyboard focus in each read-only view (its transcript), by pane.
    private var focusTargets: [UUID: WeakBox<NSView>] = [:]

    func registerFocusTarget(_ view: NSView, for pane: UUID) {
        focusTargets[pane] = WeakBox(view)
    }

    func focusTarget(for pane: UUID) -> NSView? { focusTargets[pane]?.value }

    /// Keyboard focus for an agent pane goes to its read-only view while that shows.
    func focusAgentView(of pane: Ghostty.SurfaceView) {
        guard isShowingAgent(pane.id), !livePanes.contains(pane.id), let target = focusTarget(for: pane.id),
              let window = target.window else { return }
        if window.firstResponder !== target { window.makeFirstResponder(target) }
    }

    /// The read-only view took keyboard focus: the pane is the focused pane of its tab and window.
    func agentViewFocused(pane: Ghostty.SurfaceView) {
        guard let location = TernTopology.locate(pane) else { return }
        location.tab.focusedSurface = pane
        if location.window.surfaceTree.contains(pane), location.window.focusedSurface !== pane {
            location.window.focusedSurfaceDidChange(to: pane)
        }
        TernTopology.windowBecameCurrent(location.window)
    }
}

/// A session as one view sees it.
@MainActor
final class TernAgentViewModel: ObservableObject {
    let sessionID: String
    @Published var snapshot: TernAgentSnapshot?
    @Published var removed = false
    /// Tool items expanded to show their output.
    @Published var expanded: Set<String> = []

    init(sessionID: String) {
        self.sessionID = sessionID
    }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

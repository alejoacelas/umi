import AppKit
import Combine
import GhosttyKit

/// Sessions in the app's windows (AG-5 to AG-9).
///
/// A session is shown in an ordinary pane: a terminal leaf with the session's read-only view
/// drawn over it (DECISIONS.md §1). The pane is a terminal in the session's folder, so it
/// splits, moves, swaps, zooms, closes and undoes, drags and is saved like any other pane.
/// Take Over types `umi agent attach` into that terminal and the view steps aside: the
/// agent's own interface runs there, live. Closing a read-only pane never touches the
/// session.
@MainActor
final class UmiAgentUI: ObservableObject {
    static let shared = UmiAgentUI()

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
    /// When a key last went to each pane: an agent the user typed is known only from its first
    /// hook, and keys may reach it before (UmiAgentRPC.hook).
    var lastKeyAt: [UUID: Date] = [:]

    private var models: [String: UmiAgentViewModel] = [:]

    // MARK: Session updates from the agent queue

    static func sessionChanged(_ id: String, _ snapshot: UmiAgentSnapshot?) {
        guard let snapshot else { return }
        let ui = shared
        let previous = ui.models[id]?.snapshot
        ui.model(for: id).snapshot = snapshot
        if previous?.status != snapshot.status || previous?.activity != snapshot.activity || previous?.name != snapshot.name
            || previous?.location != snapshot.location || previous?.pane != snapshot.pane || previous?.title != snapshot.title {
            UmiState.shared.layoutDidChange(persistOnly: false)
            UmiAgentMenu.shared.setNeedsRebuild()
            if previous?.status != snapshot.status {
                UmiEvents.shared.emit("agent.status", ["session": id, "name": snapshot.name, "status": snapshot.status])
            }
        }
        // The sidebar's marks, ordering and the Dock badge (no desktop notifications).
        publishAttention(snapshot, previous: previous)
    }

    static func sessionRemoved(_ id: String) {
        let ui = shared
        ui.models[id]?.removed = true
        attentionRemoved(id)
        UmiAgentMenu.shared.setNeedsRebuild()
        UmiAgentMenu.shared.statusChanged(id, status: nil)
    }

    func model(for id: String) -> UmiAgentViewModel {
        if let model = models[id] { return model }
        let model = UmiAgentViewModel(sessionID: id)
        models[id] = model
        // First look: ask the agent queue for the current state.
        UmiAgents.queue.async {
            let snapshot = UmiAgents.shared.session(id: id)?.snapshot()
            DispatchQueue.main.async { MainActor.assumeIsolated { if let snapshot { model.snapshot = snapshot } else { model.removed = true } } }
        }
        return model
    }

    func snapshot(for id: String) -> UmiAgentSnapshot? { models[id]?.snapshot ?? model(for: id).snapshot }

    // MARK: Attachments

    func session(forPane id: UUID) -> String? { attachments[id] }

    func attach(_ pane: UUID, session: String) {
        attachments[pane] = session
        showingTerminal.remove(pane)
        UmiState.shared.layoutDidChange()
        UmiAgentMenu.shared.setNeedsRebuild()
        // The session's pane is this one (a restored pane has a new id).
        let umiID = pane.uuidString.lowercased()
        let openPanes = Set(UmiTopology.allSurfaces.map(\.umiID))
        UmiAgents.queue.async {
            guard let s = UmiAgents.shared.session(id: session) else { return }
            if s.record.live == true, let old = s.record.pane, old != umiID, !openPanes.contains(old) {
                // Its interface still runs in a closed pane kept for reopening (L-20): end it, so
                // taking the session over here can't start a second process on its conversation.
                s.endingLivePane = old
                s.record.pane = nil
                s.endLiveInterface(reason: "shown elsewhere")
            }
            if s.record.pane != umiID {
                s.record.pane = umiID
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
        UmiState.shared.layoutDidChange()
        UmiAgentMenu.shared.setNeedsRebuild()
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
        for pane in UmiTopology.allSurfaces {
            if let session = shared.attachments[pane.id], out[session] == nil { out[session] = pane.umiID }
        }
        return out
    }

    static func livePane(for session: String) -> Ghostty.SurfaceView? {
        UmiTopology.allSurfaces.first { shared.attachments[$0.id] == session }
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
    static func open(_ sessionID: String, placement: UmiAgentRPC.Placement, caller: UmiCaller) throws -> String {
        if let existing = livePane(for: sessionID) {
            // Showing the session again means showing it, not its shell.
            shared.showingTerminal.remove(existing.id)
            if placement.focus {
                UmiLayout.focusPane(existing, activate: true)
                DispatchQueue.main.async { shared.focusAgentView(of: existing) }
            }
            return existing.umiID
        }
        let cwd = UmiAgents.queue.sync { UmiAgents.shared.session(id: sessionID)?.record.cwd }
        guard let cwd else { throw UmiError.notFound("no such session") }
        var options = UmiLayout.PaneOptions()
        var isDir = ObjCBool(false)
        options.cwd = FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue ? cwd : NSHomeDirectory()
        let result: [String: Any]
        switch placement.kind {
        case .split:
            let target = try placement.pane.map { try UmiTopology.resolvePane($0, caller: caller) }
                ?? (try? UmiTopology.callerPane(caller)) ?? UmiTopology.currentPane
            if let target {
                result = try UmiLayout.split(target, direction: try UmiLayout.direction(placement.direction),
                                              options: options, ratio: nil, focus: placement.focus)
            } else {
                result = try UmiLayout.newWindow(options, tabName: nil, focus: placement.focus)
            }
        case .window:
            result = try UmiLayout.newWindow(options, tabName: nil, focus: placement.focus)
        case .tab:
            let window = try placement.window.map { try UmiTopology.resolveWindow($0, caller: caller) }
                ?? ((try? UmiTopology.callerPane(caller)).flatMap { $0 }.flatMap { UmiTopology.locate($0)?.window })
                ?? UmiTopology.currentWindow
            if let window {
                result = try UmiLayout.newTab(in: window, options: options, tabName: nil, color: .none, index: nil,
                                               focus: placement.focus, inheritFrom: nil)
            } else {
                result = try UmiLayout.newWindow(options, tabName: nil, focus: placement.focus)
            }
        }
        guard let paneID = result["pane"] as? String,
              let pane = TerminalController.all.lazy.flatMap(\.allSurfaces).first(where: { $0.umiID == paneID }) else {
            throw UmiError.failed("couldn't make a pane for the session")
        }
        shared.attach(pane.id, session: sessionID)
        let paneUmiID = pane.umiID
        UmiAgents.queue.async {
            guard let session = UmiAgents.shared.session(id: sessionID) else { return }
            session.record.pane = paneUmiID
            session.saveRecord()
            session.changed()
        }
        if placement.focus {
            DispatchQueue.main.async { shared.focusAgentView(of: pane) }
        }
        UmiEvents.shared.emit("agent.opened", ["session": sessionID, "pane": paneID])
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
        guard let location = UmiTopology.locate(pane) else { return }
        location.tab.focusedSurface = pane
        if location.window.surfaceTree.contains(pane), location.window.focusedSurface !== pane {
            location.window.focusedSurfaceDidChange(to: pane)
        }
        UmiTopology.windowBecameCurrent(location.window)
    }
}

/// A session as one view sees it.
@MainActor
final class UmiAgentViewModel: ObservableObject {
    let sessionID: String
    @Published var snapshot: UmiAgentSnapshot?
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

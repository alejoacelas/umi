import AppKit
import Combine
import GhosttyKit

/// Managed sessions in the app's windows (AP).
///
/// A session is shown in an ordinary pane: a terminal leaf with the session's view drawn
/// over it (DECISIONS.md §1, phase 1). The pane is a terminal in the session's folder, so it
/// splits, moves, swaps, zooms, closes and undoes, drags and is saved like any other pane,
/// and the shell underneath is one click away (AP-2). The pane only shows the session:
/// closing it never touches the session (AP-4).
@MainActor
final class TernAgentUI: ObservableObject {
    static let shared = TernAgentUI()

    /// Pane id → session id. Kept for closed panes too, so undoing a close brings the
    /// session's view back with the pane.
    @Published private(set) var attachments: [UUID: String] = [:]
    /// Agent panes currently showing their terminal instead of the session.
    @Published var showingTerminal: Set<UUID> = []

    private var models: [String: TernAgentViewModel] = [:]
    /// Text typed but not sent, per session (AP-6): survives moves, toggles and failed sends.
    var drafts: [String: String] = [:]

    // MARK: Session updates from the agent queue

    static func sessionChanged(_ id: String, _ snapshot: TernAgentSnapshot?) {
        guard let snapshot else { return }
        let ui = shared
        let previous = ui.models[id]?.snapshot
        ui.model(for: id).snapshot = snapshot
        if previous?.status != snapshot.status || previous?.activity != snapshot.activity || previous?.name != snapshot.name {
            TernState.shared.layoutDidChange(persistOnly: false)
            if previous?.status != snapshot.status {
                TernEvents.shared.emit("agent.status", ["session": id, "name": snapshot.name, "status": snapshot.status])
                TernAgentNotifications.statusChanged(snapshot, from: previous?.status)
            }
        }
    }

    static func sessionRemoved(_ id: String) {
        let ui = shared
        ui.models[id]?.removed = true
        ui.drafts.removeValue(forKey: id)
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
    }

    func detach(_ pane: UUID) {
        attachments.removeValue(forKey: pane)
        showingTerminal.remove(pane)
        TernState.shared.layoutDidChange()
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
        attachments[pane] != nil && !showingTerminal.contains(pane)
    }

    func toggleTerminal(_ pane: Ghostty.SurfaceView) {
        if showingTerminal.contains(pane.id) {
            showingTerminal.remove(pane.id)
            focusComposer(of: pane)
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
                DispatchQueue.main.async { shared.focusComposer(of: existing) }
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
        if placement.focus {
            DispatchQueue.main.async { shared.focusComposer(of: pane) }
        }
        TernEvents.shared.emit("agent.opened", ["session": sessionID, "pane": paneID])
        return paneID
    }

    // MARK: Focus (AP-3, L-8)

    /// The composers of agent views, by pane.
    private var composers: [UUID: WeakBox<NSView>] = [:]

    func registerComposer(_ view: NSView, for pane: UUID) {
        composers[pane] = WeakBox(view)
    }

    func composer(for pane: UUID) -> NSView? { composers[pane]?.value }

    /// Keyboard focus for an agent pane goes to its composer while the session is showing.
    func focusComposer(of pane: Ghostty.SurfaceView) {
        guard isShowingAgent(pane.id), let composer = composer(for: pane.id), let window = composer.window else { return }
        if window.firstResponder !== composer { window.makeFirstResponder(composer) }
    }

    /// The composer took keyboard focus: the pane is the focused pane of its tab and window.
    func composerFocused(pane: Ghostty.SurfaceView) {
        guard let location = TernTopology.locate(pane) else { return }
        location.tab.focusedSurface = pane
        if location.window.surfaceTree.contains(pane), location.window.focusedSurface !== pane {
            location.window.focusedSurfaceDidChange(to: pane)
        }
        TernTopology.windowBecameCurrent(location.window)
    }

    // MARK: ⌃⌘J and the command palette

    /// The session that needs the user (or, failing that, the one that most recently
    /// finished), shown and focused.
    func jumpToAgentNeedingInput() {
        let target: String? = TernAgents.queue.sync {
            let sessions = TernAgents.shared.sessions
            if let waiting = sessions.last(where: { $0.status == "needs_input" }) { return waiting.record.id }
            return nil
        }
        guard let target else {
            NSSound.beep()
            return
        }
        _ = try? Self.open(target, placement: .init(kind: .tab, focus: true), caller: TernCaller([:]))
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

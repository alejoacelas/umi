import AppKit
import GhosttyKit

/// Synchronized input, as Warp's (`workspace/sync_inputs.rs`, L-32): what's typed into a pane of a
/// synced tab is typed into every terminal pane of every synced tab in that window. Each window
/// syncs nothing, some tabs, or all its tabs (new ones included). ⌥⌘I toggles the current tab,
/// "all tabs" toggles the window, ⌥⇧⌘I stops it.
@MainActor
final class UmiInputSync {
    static let shared = UmiInputSync()

    private enum State {
        case all
        case tabs(Set<ObjectIdentifier>)
    }

    private var states: [ObjectIdentifier: State] = [:]

    // MARK: State

    func isSynced(_ tab: UmiTab, in window: TerminalController) -> Bool {
        switch states[ObjectIdentifier(window)] {
        case .all: return true
        case .tabs(let tabs): return tabs.contains(ObjectIdentifier(tab))
        case nil: return false
        }
    }

    func isSyncingAny(_ window: TerminalController) -> Bool {
        switch states[ObjectIdentifier(window)] {
        case .all: return true
        case .tabs(let tabs): return window.tabs.contains { tabs.contains(ObjectIdentifier($0)) }
        case nil: return false
        }
    }

    func isSyncingAll(_ window: TerminalController) -> Bool {
        if case .all = states[ObjectIdentifier(window)] { return true }
        return false
    }

    /// ⌥⌘I: sync the window's current tab, or stop syncing it.
    func toggleTab(_ tab: UmiTab, in window: TerminalController) {
        let key = ObjectIdentifier(window)
        let all = Set(window.tabs.map(ObjectIdentifier.init))
        var synced: Set<ObjectIdentifier>
        switch states[key] {
        case .all: synced = all
        case .tabs(let tabs): synced = tabs.intersection(all)
        case nil: synced = []
        }
        if synced.contains(ObjectIdentifier(tab)) { synced.remove(ObjectIdentifier(tab)) } else { synced.insert(ObjectIdentifier(tab)) }
        // As in Warp: every tab synced is "all tabs", which new tabs join; none is nothing.
        states[key] = synced.isEmpty ? nil : (synced == all ? .all : .tabs(synced))
        changed(window)
    }

    /// Sync every pane in every tab of the window (new tabs too), or stop.
    func toggleAll(in window: TerminalController) {
        states[ObjectIdentifier(window)] = isSyncingAll(window) ? nil : .all
        changed(window)
    }

    /// ⌥⇧⌘I: stop syncing anything in the window.
    func stop(in window: TerminalController) {
        states[ObjectIdentifier(window)] = nil
        changed(window)
    }

    private func changed(_ window: TerminalController) {
        UmiState.shared.layoutDidChange()
        let tabs = window.tabs.filter { isSynced($0, in: window) }.map(\.idString)
        UmiEvents.shared.emit("input.sync", ["window": window.umiIDString, "all": isSyncingAll(window), "tabs": tabs])
    }

    // MARK: Typing

    /// The other terminal panes that what's typed into `pane` goes to: every terminal pane of
    /// every synced tab in its window, when its own tab is synced. Panes showing a file, a page
    /// or a session's read-only view aren't terminals there.
    func peers(of pane: Ghostty.SurfaceView) -> [Ghostty.SurfaceView] {
        guard !states.isEmpty, let location = UmiTopology.locate(pane),
              isSynced(location.tab, in: location.window) else { return [] }
        let window = location.window
        let agents = UmiAgentUI.shared
        return window.tabs.filter { isSynced($0, in: window) }
            .flatMap { UmiTopology.panes(of: $0, in: window) }
            .filter { other in
                other !== pane
                    && !UmiFilePanes.shared.isFilePane(other.id)
                    && !UmiWebPanes.shared.isWebPane(other.id)
                    && (agents.session(forPane: other.id) == nil || agents.livePanes.contains(other.id)
                        || agents.showingTerminal.contains(other.id))
            }
    }

    /// Type a key `pane` received into its peers too. Shortcuts (with ⌘) and keys still being
    /// composed by an input method stay with the pane.
    static func mirror(_ event: ghostty_input_key_s, from pane: Ghostty.SurfaceView) {
        guard !shared.states.isEmpty, !event.composing,
              event.mods.rawValue & GHOSTTY_MODS_SUPER.rawValue == 0 else { return }
        for peer in shared.peers(of: pane) {
            guard let surface = peer.surface else { continue }
            _ = ghostty_surface_key(surface, event)
        }
    }

    /// Paste into `pane`'s peers too.
    static func mirrorPaste(from pane: Ghostty.SurfaceView) {
        guard !shared.states.isEmpty else { return }
        let action = "paste_from_clipboard"
        for peer in shared.peers(of: pane) {
            guard let surface = peer.surface else { continue }
            _ = ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
        }
    }
}

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
        /// The synced tabs' ids.
        case tabs(Set<String>)
    }

    /// By window id. Ids, not object identities, so a new window or tab never inherits the
    /// state of a closed one.
    private var states: [String: State] = [:]

    // MARK: State

    func isSynced(_ tab: UmiTab, in window: TerminalController) -> Bool {
        switch states[window.umiIDString] {
        case .all: return true
        case .tabs(let tabs): return tabs.contains(tab.idString)
        case nil: return false
        }
    }

    func isSyncingAny(_ window: TerminalController) -> Bool {
        switch states[window.umiIDString] {
        case .all: return true
        case .tabs(let tabs): return window.tabs.contains { tabs.contains($0.idString) }
        case nil: return false
        }
    }

    func isSyncingAll(_ window: TerminalController) -> Bool {
        if case .all = states[window.umiIDString] { return true }
        return false
    }

    /// ⌥⌘I: sync the window's current tab, or stop syncing it.
    func toggleTab(_ tab: UmiTab, in window: TerminalController) {
        let key = window.umiIDString
        let all = Set(window.tabs.map(\.idString))
        var synced: Set<String>
        switch states[key] {
        case .all: synced = all
        case .tabs(let tabs): synced = tabs.intersection(all)
        case nil:
            // As in Warp: from nothing, just this tab, even when it's the window's only one,
            // so a tab opened later isn't synced.
            states[key] = .tabs([tab.idString])
            changed(window)
            return
        }
        if synced.contains(tab.idString) { synced.remove(tab.idString) } else { synced.insert(tab.idString) }
        // As in Warp: toggled from a synced set, every tab synced is "all tabs", which new
        // tabs join; none is nothing.
        states[key] = synced.isEmpty ? nil : (synced == all ? .all : .tabs(synced))
        changed(window)
    }

    /// Sync every pane in every tab of the window (new tabs too), or stop.
    func toggleAll(in window: TerminalController) {
        states[window.umiIDString] = isSyncingAll(window) ? nil : .all
        changed(window)
    }

    /// ⌥⇧⌘I: stop syncing anything in the window.
    func stop(in window: TerminalController) {
        states[window.umiIDString] = nil
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
        guard !states.isEmpty else { return [] }
        // Forget closed windows.
        let open = Set(UmiTopology.windows.map(\.umiIDString))
        states = states.filter { open.contains($0.key) }
        guard let location = UmiTopology.locate(pane),
              isSynced(location.tab, in: location.window) else { return [] }
        let window = location.window
        return window.tabs.filter { isSynced($0, in: window) }
            .flatMap { UmiTopology.panes(of: $0, in: window) }
            .filter { other in
                other !== pane
                    && !UmiFilePanes.shared.isFilePane(other.id)
                    && !UmiWebPanes.shared.isWebPane(other.id)
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

    /// Paste the text `pane` accepted into its peers too, as a paste (bracketed when their
    /// program asks for it). They don't ask again: the user confirmed it once, in `pane`.
    static func mirrorPaste(_ text: String, from pane: Ghostty.SurfaceView) {
        guard !shared.states.isEmpty else { return }
        let peers = shared.peers(of: pane)
        guard !peers.isEmpty else { return }
        let length = UInt(text.utf8.count)
        text.withCString { ptr in
            for peer in peers {
                guard let surface = peer.surface else { continue }
                ghostty_surface_text(surface, ptr, length)
            }
        }
    }
}

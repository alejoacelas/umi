import AppKit
import Combine

/// When the user looks at a pane: it has focus in the key window while the app is active.
/// Looking clears the quiet mark on that pane's agent (UmiAttention), which also updates the
/// Dock badge. It happens on pane focus changes, tab switches, and window and app activation.
/// A session that finishes while the user looks at its pane, or at any pane of its tab (Warp's
/// rule), was seen finishing: its mark clears at once. (A session that needs the user keeps its
/// mark until the next look at its own pane.)
@MainActor
enum UmiLooking {
    private static var cancellables: Set<AnyCancellable> = []

    /// Scripted checks without the screen (`debug.ui.assume_active`): the app counts as active
    /// and the current window as key.
    static var assumeActive = false

    private static var appIsActive: Bool { assumeActive || NSApp.isActive }

    private static var keyController: TerminalController? {
        assumeActive ? UmiTopology.currentWindow : NSApp.keyWindow?.windowController as? TerminalController
    }

    static func start() {
        guard cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in MainActor.assumeIsolated { lookAtKeyWindow() } }
            .store(in: &cancellables)
        UmiAttention.shared.$revision
            .sink { _ in
                // After the change is in place (the publisher fires before it is).
                DispatchQueue.main.async {
                    let attention = UmiAttention.shared
                    for (id, agent) in attention.panes where agent.mark == .finished && isLookingAtTab(of: id) {
                        attention.looked(atPane: id)
                    }
                }
            }
            .store(in: &cancellables)
    }

    /// The pane being looked at, if any.
    static var lookedAt: Ghostty.SurfaceView? {
        guard appIsActive, let controller = keyController else { return nil }
        return pane(of: controller)
    }

    /// The window the user is looking at: the key window of the active app.
    static var activeWindow: TerminalController? { appIsActive ? keyController : nil }

    /// Whether the user looks at this pane's tab: a pane of it has focus in the key window of the
    /// active app (Warp counts a session as seen if any pane of its tab had focus as it finished).
    static func isLookingAtTab(of paneID: UUID) -> Bool {
        guard let looked = lookedAt, let controller = keyController else { return false }
        if looked.id == paneID { return true }
        let tab = controller.selectedTab
        return (controller.tree(of: tab).root?.leaves() ?? []).contains { $0.id == paneID }
    }

    /// Something about `controller`'s focus changed: if its focused pane is being looked at,
    /// say so.
    static func focusChanged(in controller: TerminalController) {
        guard appIsActive, controller === keyController, let pane = pane(of: controller) else { return }
        UmiAttention.shared.looked(atPane: pane.id)
    }

    private static func lookAtKeyWindow() {
        guard let controller = keyController else { return }
        focusChanged(in: controller)
    }

    private static func pane(of controller: TerminalController) -> Ghostty.SurfaceView? {
        guard let pane = controller.focusedSurface, controller.surfaceTree.contains(pane) else { return nil }
        return pane
    }
}

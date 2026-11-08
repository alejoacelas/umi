import AppKit
import Combine

/// When the user looks at a pane: it has keyboard focus in the key window while the app is
/// active. Looking sets the pane's `seenAt` (UmiAttention), which clears its "finished, not seen"
/// mark and updates the Dock badge. It happens on pane focus changes, tab switches, and window
/// and app activation; a change in the pane looked at is seen as it happens. Only the pane
/// itself counts: looking at another pane of its tab doesn't.
@MainActor
enum UmiLooking {
    private static var cancellables: Set<AnyCancellable> = []

    /// Scripted checks without the screen (`debug.ui.assume_active`): the app counts as active
    /// and the current window as key.
    static var assumeActive = false
    /// Scripted checks: the app counts as inactive, wherever it is (`debug.ui.assume_inactive`).
    static var assumeInactive = false

    private static var appIsActive: Bool { !assumeInactive && (assumeActive || NSApp.isActive) }

    private static var keyController: TerminalController? {
        assumeActive ? UmiTopology.currentWindow : NSApp.keyWindow?.windowController as? TerminalController
    }

    static func start() {
        guard cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in MainActor.assumeIsolated { lookAtKeyWindow() } }
            .store(in: &cancellables)
    }

    /// The pane being looked at, if any.
    static var lookedAt: Ghostty.SurfaceView? {
        guard appIsActive, let controller = keyController else { return nil }
        return pane(of: controller)
    }

    /// The window the user is looking at: the key window of the active app.
    static var activeWindow: TerminalController? { appIsActive ? keyController : nil }

    /// Something about `controller`'s focus changed: if its focused pane is being looked at,
    /// say so.
    static func focusChanged(in controller: TerminalController) {
        defer { UmiFocusLog.shared.update() }
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

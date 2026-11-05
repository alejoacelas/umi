import AppKit
import Combine

/// When the user looks at a pane: it has focus in the key window while the app is active.
/// Looking clears the quiet mark on that pane's agent (UmiAttention), which also updates the
/// Dock badge. It happens on pane focus changes, tab switches, and window and app activation.
/// A session that finishes while the user looks at its pane, or at any pane of its tab (Warp's
/// rule), was seen finishing: it gets no mark. A mark already there clears only when the user
/// looks at its own pane. (A session that needs the user keeps its mark until then too.)
@MainActor
enum UmiLooking {
    private static var cancellables: Set<AnyCancellable> = []

    /// Scripted checks without the screen (`debug.ui.assume_active`): the app counts as active
    /// and the current window as key.
    static var assumeActive = false
    /// Scripted checks: the app counts as inactive, wherever it is (`debug.ui.inbox.assume_inactive`).
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
        UmiAttention.shared.$revision
            .sink { _ in
                // After the change is in place (the publisher fires before it is).
                // Only the looked-at pane's own mark: the tab rule applies as a turn finishes
                // (publishAttention), as Warp applies it when the event arrives.
                DispatchQueue.main.async {
                    guard let pane = lookedAt, UmiAttention.shared.agent(forPane: pane.id)?.mark == .finished else { return }
                    UmiAttention.shared.looked(atPane: pane.id)
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

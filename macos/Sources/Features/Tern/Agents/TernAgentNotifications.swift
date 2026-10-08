import AppKit
import UserNotifications

/// Desktop notifications when a session needs the user or finishes while the user isn't
/// looking at it (AP-7). Clicking one shows the session.
@MainActor
enum TernAgentNotifications {
    static func statusChanged(_ snapshot: TernAgentSnapshot, from previous: String?) {
        guard let previous, previous != snapshot.status else { return }
        let finished = (previous == "working" || previous == "starting") && snapshot.status == "idle"
        let needsInput = snapshot.status == "needs_input"
        guard finished || needsInput else { return }
        // Not when the user is looking at it.
        if NSApp.isActive, let pane = TernAgentUI.livePane(for: snapshot.id),
           let location = TernTopology.locate(pane), location.tab === location.window.selectedTab,
           location.window.window?.isKeyWindow == true, location.window.window?.isVisible == true {
            return
        }
        guard TernAgentNotifications.enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = needsInput ? "\(snapshot.name) needs you" : "\(snapshot.name) finished"
        if needsInput, let request = snapshot.requests.first {
            content.body = "\(request.title): \(TernAgentText.oneLine(request.detail, max: 120))"
        } else if let reply = snapshot.items.last(where: { $0.kind == "assistant" })?.text {
            content.body = TernAgentText.oneLine(reply, max: 160)
        }
        content.userInfo = ["tern_agent_session": snapshot.id]
        let request = UNNotificationRequest(identifier: "tern-agent-\(snapshot.id)-\(UUID().uuidString)", content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Isolated test instances don't post notifications.
    static var enabled: Bool {
        !TernPaths.isIsolated || ProcessInfo.processInfo.environment["TERN_AGENT_NOTIFICATIONS"] == "1"
    }

    /// A notification was clicked.
    static func handle(userInfo: [AnyHashable: Any]) -> Bool {
        guard let session = userInfo["tern_agent_session"] as? String else { return false }
        _ = try? TernAgentUI.open(session, placement: .init(kind: .tab, focus: true), caller: TernCaller([:]))
        return true
    }
}

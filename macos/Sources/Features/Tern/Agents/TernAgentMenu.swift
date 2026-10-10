import AppKit

/// Finding sessions that no pane shows (`agent start` runs in the background). The sidebar has
/// no agents section (S-2), so background sessions are found in:
/// - Window > Agent Sessions: every session with its status and activity, the ones that need
///   the user first; choosing one shows it (read-only, AG-5);
/// - the command palette ("Show Agent: …", the same order);
/// - "next session that needs you" and the Dock badge, which counts the sessions that need the
///   user (TernAttention).
/// Window > Take Over Session (⌃⌘O) and Remove Session from Pane (⌃⌘W) act on the focused
/// pane's session (AG-6, AG-8).
@MainActor
final class TernAgentMenu: NSObject, NSMenuDelegate {
    static let shared = TernAgentMenu()
    static let title = "Agent Sessions"
    /// Longer lists end with a pointer to the palette and `agent ls`.
    static let limit = 30

    private weak var menu: NSMenu?
    private var rebuildScheduled = false

    /// Add the submenu to the Window menu (after Tern's own items).
    func install(in windowMenu: NSMenu) {
        guard menu == nil else { return }
        let takeOver = NSMenuItem(title: "Take Over Session", action: #selector(takeOverFocused(_:)), keyEquivalent: "o")
        takeOver.keyEquivalentModifierMask = [.command, .control]
        takeOver.target = self
        takeOver.toolTip = "Run the agent's own interface in this pane, on the session's conversation"
        windowMenu.addItem(takeOver)
        let remove = NSMenuItem(title: "Remove Session from Pane", action: #selector(removeFocused(_:)), keyEquivalent: "w")
        remove.keyEquivalentModifierMask = [.command, .control]
        remove.target = self
        remove.toolTip = "Take the session out of this pane; it keeps running until it finishes"
        windowMenu.addItem(remove)
        let item = NSMenuItem(title: Self.title, action: nil, keyEquivalent: "")
        if #available(macOS 26.0, *) {
            item.image = NSImage(systemSymbolName: "bubble.left.and.text.bubble.right", accessibilityDescription: nil)
        }
        let submenu = NSMenu(title: Self.title)
        submenu.delegate = self
        item.submenu = submenu
        windowMenu.addItem(item)
        menu = submenu
        rebuild()
    }

    /// Sessions changed: rebuild soon (the accessibility tree reads the items without
    /// opening the menu, so they're kept current, not only built when it opens).
    func setNeedsRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                self?.rebuildScheduled = false
                self?.rebuild()
            }
        }
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    /// Sessions in the order a person wants them: needing the user, working, idle, failed,
    /// stopped; the most recent first within each.
    nonisolated static func ordered() -> [(id: String, name: String, kind: String, status: String, activity: String)] {
        let sessions = TernAgents.queue.sync {
            TernAgents.shared.sessions.map { ($0.record.id, $0.record.name, $0.record.kind.rawValue, $0.status, $0.activityText) }
        }
        let rank = ["needs_input": 0, "working": 1, "starting": 1, "idle": 2, "error": 3, "stopped": 4]
        return sessions.enumerated()
            .sorted { a, b in
                let ra = rank[a.element.3] ?? 5, rb = rank[b.element.3] ?? 5
                return ra != rb ? ra < rb : a.offset > b.offset
            }
            .map { (id: $0.element.0, name: $0.element.1, kind: $0.element.2, status: $0.element.3, activity: $0.element.4) }
    }

    static func symbol(for status: String) -> String {
        switch status {
        case "needs_input": return "exclamationmark.bubble"
        case "working", "starting": return "ellipsis.bubble"
        case "error": return "xmark.octagon"
        case "stopped": return "stop.circle"
        default: return "bubble.left"
        }
    }

    /// "fix-login — needs input · Run a command"
    static func describe(status: String, activity: String) -> String {
        var text = status.replacingOccurrences(of: "_", with: " ")
        let detail = activity.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty, detail != status { text += " · " + TernAgentText.oneLine(detail, max: 60) }
        return text
    }

    private func rebuild() {
        guard let menu else { return }
        let sessions = Self.ordered()
        let shown = TernAgentUI.panesBySession()
        menu.removeAllItems()
        if sessions.isEmpty {
            let empty = NSMenuItem(title: "No Sessions", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for session in sessions.prefix(Self.limit) {
            let item = NSMenuItem(title: "\(session.name) — \(Self.describe(status: session.status, activity: session.activity))",
                                  action: #selector(show(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = session.id
            item.image = NSImage(systemSymbolName: Self.symbol(for: session.status), accessibilityDescription: session.status)
            // A check mark: a pane shows it now.
            item.state = shown[session.id] != nil ? .on : .off
            item.toolTip = "\(session.kind) session \(session.id). Choose it to show it in a pane."
            menu.addItem(item)
        }
        if sessions.count > Self.limit {
            menu.addItem(.separator())
            let more = NSMenuItem(title: "\(sessions.count - Self.limit) more in the command palette and `\(TernPaths.cliName) agent ls`",
                                  action: nil, keyEquivalent: "")
            more.isEnabled = false
            menu.addItem(more)
        }
    }

    /// The focused pane of the key window (or of Tern's current window), wherever focus is.
    private func focusedPane() -> Ghostty.SurfaceView? {
        let controller = (NSApp.keyWindow?.windowController as? TerminalController) ?? TernTopology.currentWindow
        return controller?.focusedSurface
    }

    private func sessionInFocusedPane() -> (Ghostty.SurfaceView, String)? {
        guard let pane = focusedPane() else { return nil }
        if let session = TernAgentUI.shared.session(forPane: pane.id) ?? TernAgentUI.sessionLive(in: pane.id) {
            return (pane, session)
        }
        return nil
    }

    @objc private func takeOverFocused(_ sender: NSMenuItem) {
        guard let (pane, session) = sessionInFocusedPane(), !TernAgentUI.shared.livePanes.contains(pane.id) else {
            NSSound.beep()
            return
        }
        TernAgentUI.shared.takeOver(pane, session: session)
    }

    @objc private func removeFocused(_ sender: NSMenuItem) {
        guard let (pane, _) = sessionInFocusedPane() else {
            NSSound.beep()
            return
        }
        TernAgentUI.shared.removeFromPane(pane)
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(takeOverFocused(_:)):
            guard let (pane, _) = sessionInFocusedPane() else { return false }
            return !TernAgentUI.shared.livePanes.contains(pane.id)
        case #selector(removeFocused(_:)):
            return sessionInFocusedPane() != nil
        default:
            return true
        }
    }

    @objc private func show(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        _ = try? TernAgentUI.open(id, placement: .init(kind: .tab, focus: true), caller: TernCaller([:]))
    }

    // MARK: Dock badge

    /// Sessions that need the user right now.
    private(set) var needingInput: Set<String> = []

    func statusChanged(_ id: String, status: String?) {
        let before = needingInput
        if status == "needs_input" { needingInput.insert(id) } else { needingInput.remove(id) }
        if before != needingInput { (NSApp.delegate as? AppDelegate)?.refreshDockBadge() }
    }
}

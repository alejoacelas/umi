import AppKit
import Combine

/// What the window chrome knows about agent sessions: which pane shows which agent, the
/// session's title, whether it needs the user, and when it last stopped.
///
/// The agent engine writes it; the sidebar (icon, quiet colors, line 2), tab ordering, the
/// Dock badge and the "next session that needs you" shortcuts read it. Nothing here posts
/// desktop notifications.
@MainActor
final class UmiAttention: ObservableObject {
    static let shared = UmiAttention()

    enum Kind: String { case claude, codex }

    /// The quiet mark on an agent's icon. `finished`: its turn ended while the user wasn't
    /// looking. `needsYou`: it waits on the user (an approval, a question). Looking clears both
    /// (a session that still needs input gets `needsYou` back on its next update).
    enum Mark: Int, Comparable {
        case none = 0, finished = 1, needsYou = 2
        static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
    }

    struct Agent: Equatable {
        /// Umi's session id, when Umi knows the session.
        var session: String?
        var kind: Kind
        /// The session's title (the sidebar's second line).
        var title: String
        /// starting, working, idle, needs_input, stopped or error.
        var status: String
        /// The agent's own interface runs in the pane (otherwise the pane shows Umi's read-only view).
        var live: Bool
        var mark: Mark
        /// When its turn last ended or it last asked for input.
        var lastStop: Date?
    }

    /// A place the "next session that needs you" shortcut can go.
    enum Target: Equatable {
        case pane(UUID)
        /// A session no pane shows: going there shows it (read-only, in a new tab).
        case session(String)
    }

    /// Bumped on every change, for views and orderings that depend on this.
    @Published private(set) var revision = 0

    private(set) var panes: [UUID: Agent] = [:]
    /// Sessions no pane shows that need the user, oldest request first.
    private(set) var background: [(session: String, title: String, since: Date)] = []

    /// Shows a session that no pane shows (set by the agent engine).
    var showSession: ((String) -> Void)?

    // MARK: Reading

    func agent(forPane id: UUID) -> Agent? { panes[id] }

    /// A tab's agent for its sidebar row: the focused pane's, else the pane with the strongest
    /// mark, else the one that stopped last.
    func agent(for tab: UmiTab, in controller: TerminalController) -> Agent? {
        let leaves = controller.tree(of: tab).root?.leaves() ?? []
        let agents = leaves.compactMap { panes[$0.id] }
        guard !agents.isEmpty else { return nil }
        if let focused = tab.effectiveFocusedSurface, let agent = panes[focused.id] { return agent }
        return agents.max { a, b in
            if a.mark != b.mark { return a.mark < b.mark }
            return (a.lastStop ?? .distantPast) < (b.lastStop ?? .distantPast)
        }
    }

    /// The strongest mark among a tab's agents.
    func mark(for tab: UmiTab, in controller: TerminalController) -> Mark {
        let leaves = controller.tree(of: tab).root?.leaves() ?? []
        return leaves.compactMap { panes[$0.id]?.mark }.max() ?? .none
    }

    /// Sessions that need the user: shown ones with a mark, and background ones that need input.
    /// The Dock badge: sessions that need the user (a question, an approval, input), the
    /// user's words. A finish not seen yet is only the sidebar's quiet mark.
    var needingYouCount: Int {
        panes.values.filter { $0.mark == .needsYou }.count + background.count
    }

    /// Where "next session that needs you" goes, in order: needs-input first (oldest stop
    /// first), then finished-unseen (oldest first).
    func targetsNeedingYou() -> [Target] {
        var out: [(Target, Mark, Date)] = []
        for (id, agent) in panes where agent.mark != .none {
            out.append((.pane(id), agent.mark, agent.lastStop ?? .distantPast))
        }
        for item in background { out.append((.session(item.session), .needsYou, item.since)) }
        return out.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.2 < b.2 }.map(\.0)
    }

    // MARK: Writing (agent engine)

    func set(_ agent: Agent?, forPane id: UUID) {
        if panes[id] == agent { return }
        if let agent { panes[id] = agent } else { panes.removeValue(forKey: id) }
        changed()
    }

    func setBackground(_ items: [(session: String, title: String, since: Date)]) {
        let same = items.count == background.count && zip(items, background).allSatisfy {
            $0.session == $1.session && $0.title == $1.title && $0.since == $1.since
        }
        if same { return }
        background = items
        changed()
    }

    /// The user looked at a pane (it has focus in the key window of the active app).
    func looked(atPane id: UUID) {
        guard var agent = panes[id], agent.mark != .none else { return }
        agent.mark = .none
        panes[id] = agent
        changed()
        lookedHandler?(id)
    }

    /// Lets the agent engine record that a pane's session was seen.
    var lookedHandler: ((UUID) -> Void)?

    private func changed() {
        revision &+= 1
        updateDockBadge()
    }

    // MARK: Dock badge

    /// The Dock badge counts the sessions that need the user.
    private func updateDockBadge() {
        (NSApp?.delegate as? AppDelegate)?.refreshDockBadge()
    }
}

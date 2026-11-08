import AppKit
import Combine

/// The agents running in Umi's panes, one per pane, as their hooks report them (design/primitives.md,
/// "Agent hook plugin"). Umi runs no agents of its own: Claude Code and Codex run in panes, and Umi's
/// plugin calls `umi hook EVENT`, which lands in `UmiAgentHooks` and is written here.
///
/// What the chrome reads from it: the sidebar's agent mark and line 2, the default lists (`needs-you`,
/// `unseen`) behind the Dock badge and ⌃⌘J, `ls --json`'s `agent.*`
/// attributes, and the quiet moment for updates.
///
/// Attention is facts, not flags: a pane is "unseen" while its `changedAt` (the last change of its
/// agent's status) is later than its `seenAt` (the last moment the pane itself had keyboard focus
/// in the key window of the active app). Looking at another pane of the same tab doesn't count.
/// Nothing here posts desktop notifications.
@MainActor
final class UmiAttention: ObservableObject {
    static let shared = UmiAttention()

    typealias Kind = UmiAgentKind

    enum Status: String {
        case working, needsInput = "needs_input", idle, stopped, error

        /// Finished: its turn is over (it may be unseen).
        var finished: Bool { self == .idle || self == .stopped }
    }

    /// The quiet mark on an agent's icon, from the facts above: `needsYou` while its agent waits on
    /// the user (or failed), `finished` while it finished and the pane wasn't looked at since.
    enum Mark: Int, Comparable {
        case none = 0, finished = 1, needsYou = 2
        static func < (a: Mark, b: Mark) -> Bool { a.rawValue < b.rawValue }
    }

    /// One pane's agent.
    struct Agent: Equatable {
        var kind: Kind
        var status: Status
        /// `agent.title`: the first prompt of its conversation, one line ("" until there is one).
        var title: String = ""
        /// `agent.summary`: the first line of its last reply.
        var summary: String?
        /// `agent.done`: set at the end of each turn, true when the reply's last line starts with
        /// `Status: done`.
        var done: Bool?
        /// `agent.session`: the harness's own session (Claude) or thread (Codex) id.
        var session: String?
        /// What it says about its state: what it asks while it needs input, its error.
        var detail: String?
        /// Background tasks it reported at its last stop (Claude Code): work that will wake it.
        var background = 0
        /// When `status` last changed (`status_since`), and when the pane's agent state last
        /// changed in a way that asks to be looked at (`changed_at`).
        var statusSince: Date
        var changedAt: Date
        /// When the pane was last looked at (`seen_at`).
        var seenAt: Date?
        /// When its turn last ended, or it last asked for input.
        var lastStop: Date?

        // What brings it back after a relaunch (UmiAgentHooks.restart).
        /// The agent's process (from its hook), and the folder it runs in.
        var pid: Int32?
        var cwd: String?
        /// The agent's program as typed and its arguments (from its process).
        var program: String?
        var typedArgs: [String] = []
        /// The command a relaunch typed (until its hooks report the process).
        var restart: [String]?
        /// The agent's configuration folder (CLAUDE_CONFIG_DIR, CODEX_HOME), when its process had one.
        var env: [String: String] = [:]
        /// Its conversation exists on disk (Claude writes one only at the first prompt).
        var conversation = false

        // The input line of its interface, as far as Umi can follow it (for the quiet moment).
        var draftChars = 0
        var draft = false
        /// Something reached its input line that Umi couldn't follow.
        var inputTouched = false
        var inputSeq = 0
        var enterSeq = 0
        /// Interrupted from the keyboard (Esc, Ctrl-C) with no hook since: taken as idle.
        var idleInferred = false
        var lastHookAt: Date

        init(kind: Kind, status: Status, at now: Date = Date()) {
            self.kind = kind
            self.status = status
            statusSince = now
            changedAt = now
            lastHookAt = now
        }

        var unseen: Bool { seenAt.map { changedAt > $0 } ?? true }

        var mark: Mark {
            switch status {
            case .needsInput, .error: return .needsYou
            case .idle, .stopped: return unseen ? .finished : .none
            case .working: return .none
            }
        }

        /// Its agent runs in the pane's terminal (not stopped).
        var running: Bool { status != .stopped }

        /// The command that brings it back: as typed, on its own conversation.
        var command: [String] {
            guard let program else { return restart ?? [] }
            return UmiTypedCommand.restartCommand(program: program, args: typedArgs, kind: kind,
                                                  session: conversation ? session : nil)
        }

        /// `agent.*`, as `ls --json` shows them.
        var attributes: [String: String] {
            var out = ["agent.kind": kind.rawValue, "agent.status": status.rawValue]
            if !title.isEmpty { out["agent.title"] = title }
            if let summary { out["agent.summary"] = summary }
            if let done { out["agent.done"] = done ? "true" : "false" }
            if let session { out["agent.session"] = session }
            return out
        }
    }

    /// Bumped on every change, for views and orderings that depend on this.
    @Published private(set) var revision = 0

    private(set) var panes: [UUID: Agent] = [:]

    /// When each pane, with or without an agent, was last looked at.
    private var seen: [UUID: Date] = [:]

    /// When each pane was last hidden or shown (part of its `changed_at`), and when it last came
    /// back on show (it is unseen until looked at).
    private var placeChanged: [UUID: Date] = [:]
    private var shown: [UUID: Date] = [:]

    func placeChangedAt(_ id: UUID) -> Date? { placeChanged[id] }
    func shownAt(_ id: UUID) -> Date? { shown[id] }

    /// A pane was hidden or shown (UmiHidden).
    func placeChanged(_ id: UUID, shown isShown: Bool) {
        let now = Date()
        placeChanged[id] = now
        shown[id] = isShown ? now : nil
        changed()
    }

    /// The app is quitting: agents ending now come back after the relaunch, so their ends aren't
    /// recorded (UmiAppLifecycle).
    var shuttingDown = false

    // MARK: Reading

    func agent(forPane id: UUID) -> Agent? { panes[id] }

    /// `seen_at`: when the pane was last looked at. A new agent counts as seen when it arrives
    /// (its first state isn't news), so a pane's agent may be seen later than the pane was.
    func seenAt(_ id: UUID) -> Date? {
        switch (seen[id], panes[id]?.seenAt) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }

    /// Panes in a window (not closed ones kept for reopening) and their agents.
    var openPanes: [(UUID, Agent)] {
        let open = Set(UmiTopology.allSurfaces.map(\.id))
        return panes.filter { open.contains($0.key) }.map { ($0.key, $0.value) }
    }

    /// Panes whose agent is working: an update now would cut their turns off.
    var workingCount: Int { openPanes.filter { $0.1.status == .working }.count }

    // MARK: Writing (UmiAgentHooks)

    /// Change a pane's agent. A status change sets `changedAt` (and `statusSince`), and is a
    /// `pane.changed` event; the pane being looked at sees it at once.
    func update(_ id: UUID, _ change: (inout Agent) -> Void) {
        guard var agent = panes[id] else { return }
        let old = agent
        change(&agent)
        store(agent, old: old, forPane: id)
    }

    func set(_ agent: Agent?, forPane id: UUID) {
        let old = panes[id]
        guard var agent else {
            if let old {
                panes.removeValue(forKey: id)
                emitChanges(id, old: old.attributes, new: [:])
                changed()
            }
            return
        }
        if old == nil {
            // A new agent in the pane: a change to look at only once it does something.
            agent.seenAt = agent.seenAt ?? agent.changedAt
        }
        store(agent, old: old, forPane: id)
    }

    private func store(_ new: Agent, old: Agent?, forPane id: UUID) {
        var agent = new
        let now = Date()
        if let old, old.status != agent.status {
            agent.statusSince = now
            agent.changedAt = now
        }
        if UmiLooking.lookedAt?.id == id { agent.seenAt = max(agent.changedAt, now) }
        if panes[id] == agent { return }
        panes[id] = agent
        emitChanges(id, old: old?.attributes ?? [:], new: agent.attributes)
        changed()
        // What restarts after a relaunch is saved with the layout.
        if !sameJSON(old?.restartRecord, agent.restartRecord) { UmiState.shared.layoutDidChange(persistOnly: true) }
    }

    /// Each changed `agent.*` key is a `pane.changed` event, `agent.status` first (design/cli.md,
    /// choice 7).
    private func emitChanges(_ id: UUID, old: [String: String], new: [String: String]) {
        let keys = Set(old.keys).union(new.keys).sorted { a, b in
            a == "agent.status" ? b != "agent.status" : (b == "agent.status" ? false : a < b)
        }
        for key in keys where old[key] != new[key] {
            UmiEvents.shared.emit("pane.changed", ["pane": id.uuidString.lowercased(), "key": key,
                                                   "old": old[key] ?? NSNull(), "new": new[key] ?? NSNull()])
        }
    }

    /// The user looked at a pane (it has focus in the key window of the active app).
    func looked(atPane id: UUID) {
        seen[id] = Date()
        if seen.count > 512 {
            let open = Set(UmiTopology.allSurfaces.map(\.id))
            seen = seen.filter { open.contains($0.key) || UmiReopen.shared.holds($0.key) }
        }
        guard var agent = panes[id] else { return }
        agent.seenAt = Date()
        let before = panes[id]?.mark
        panes[id] = agent
        if before != agent.mark { changed() }
    }

    /// Scripted checks (`debug.attention.set`, `debug.ui.attention.set`): a pane's agent as given,
    /// standing in for its hooks. `mark`: `needs_you` (status needs_input), `finished` (changed
    /// `ago` seconds ago and not seen since) or `none` (seen). Nil clears it.
    func standIn(forPane id: UUID, kind: Kind?, title: String?, status: String?, mark: String?, ago: Double?,
                 detail: String? = nil) throws {
        guard let kind else {
            panes.removeValue(forKey: id)
            changed()
            return
        }
        let at = Date().addingTimeInterval(-(ago ?? 0))
        var agent = UmiAttention.Agent(kind: kind, status: .idle, at: at)
        agent.title = title ?? ""
        agent.detail = detail
        switch mark ?? "none" {
        case "needs_you", "needs-you": agent.status = .needsInput
        case "finished":
            agent.status = status.flatMap(Status.init(rawValue:)) ?? .idle
            agent.seenAt = .distantPast
        case "none":
            agent.status = status.flatMap(Status.init(rawValue:)) ?? .idle
            agent.seenAt = Date()
        default: throw UmiError.badRequest("mark is none, finished or needs_you")
        }
        if agent.status != .working { agent.lastStop = at }
        // The pane being looked at sees it at once, as with its hooks.
        if UmiLooking.lookedAt?.id == id { agent.seenAt = Date() }
        panes[id] = agent
        changed()
    }

    /// Forget agents of panes that are gone for good.
    func forget(_ ids: Set<UUID>) {
        let before = panes.count
        for id in ids { panes.removeValue(forKey: id) }
        if panes.count != before { changed() }
    }

    private func changed() {
        revision &+= 1
        (NSApp?.delegate as? AppDelegate)?.refreshDockBadge()
    }
}

extension UmiAttention.Agent {
    /// What the layout saves for this pane so its agent comes back after a quit, a crash or an
    /// update (nil: nothing to bring back).
    var restartRecord: [String: Any]? {
        // Running, or brought back by a relaunch and not reported by its hooks yet.
        guard running || (program == nil && restart != nil), !command.isEmpty else { return nil }
        var out: [String: Any] = ["kind": kind.rawValue, "command": command, "conversation": conversation]
        if let session { out["session"] = session }
        if !env.isEmpty { out["env"] = env }
        if let cwd { out["cwd"] = cwd }
        if !title.isEmpty { out["title"] = title }
        return out
    }
}

/// Two JSON objects hold the same (for "did what is saved change").
private func sameJSON(_ a: [String: Any]?, _ b: [String: Any]?) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (a?, b?): return NSDictionary(dictionary: a).isEqual(to: b)
    default: return false
    }
}

import Foundation
import Testing
@testable import Ghostty

/// L-12: where ⌃⌘J (`jump`) goes. Needs input first (oldest first), then unseen panes
/// (`changedAt > seenAt`) whose agent finished or failed (oldest first).
@MainActor struct UmiJumpTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func agent(_ status: UmiAttention.Status, changed: Double, seen: Double?) -> UmiAttention.Agent {
        var agent = UmiAttention.Agent(kind: .claude, status: status, at: start.addingTimeInterval(changed))
        agent.seenAt = seen.map { start.addingTimeInterval($0) }
        return agent
    }

    @Test func needsInputComesFirstThenUnseenOldestFirst() {
        let ask = UUID(), done = UUID(), failed = UUID()
        let order = UmiAttention.jumpOrder([
            (done, agent(.idle, changed: 10, seen: 0)),
            (failed, agent(.error, changed: 5, seen: 0)),
            (ask, agent(.needsInput, changed: 20, seen: 30)),
        ])
        #expect(order == [ask, failed, done])
    }

    @Test func aSeenFailedPaneDropsOut() {
        let failed = UUID()
        #expect(UmiAttention.jumpOrder([(failed, agent(.error, changed: 5, seen: 6))]).isEmpty)
        #expect(UmiAttention.jumpOrder([(failed, agent(.error, changed: 5, seen: 4))]) == [failed])
    }

    @Test func seenFinishedAndWorkingPanesAreNotTargets() {
        #expect(UmiAttention.jumpOrder([
            (UUID(), agent(.idle, changed: 5, seen: 6)),
            (UUID(), agent(.working, changed: 5, seen: nil)),
        ]).isEmpty)
    }
}

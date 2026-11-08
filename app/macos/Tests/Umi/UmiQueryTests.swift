import AppKit
import Foundation
import Testing
@testable import Ghostty

/// The query syntax (design/cli.md, "Queries"), the default lists that rebuild today's attention
/// behaviour (L-12: `jump` is needs input oldest first, then unseen oldest first), templates, and
/// what counts as an event's cause (D-6).
@MainActor struct UmiQueryTests {
    private func items(_ rows: [[String: String]]) -> [UmiQuery.Item] {
        rows.enumerated().map { UmiQuery.Item(order: $0.offset, attributes: $0.element) }
    }

    /// The panes (by `n`) a query picks among `rows`, with Umi's default lists.
    private func run(_ text: String, _ rows: [[String: String]], now: Date = Date()) throws -> [String] {
        let query = try UmiQuery.parse(text)
        let all = items(rows)
        let lists = Dictionary(uniqueKeysWithValues: try UmiConfig.defaultLists.map { ($0.name, try UmiQuery.parse($0.query)) })
        let evaluator = UmiQuery.Evaluator(items: all, now: now) { lists[$0] }
        return evaluator.run(query).compactMap { $0.value("n") }
    }

    @Test func comparisonsAndBooleans() throws {
        let rows = [["n": "a", "priority": "high", "count": "10"], ["n": "b", "priority": "low", "count": "9"], ["n": "c"]]
        #expect(try run("priority=high", rows) == ["a"])
        #expect(try run("priority!=high", rows) == ["b", "c"])
        #expect(try run("count > 9", rows) == ["a"])          // numbers, not text ("10" < "9" as text)
        #expect(try run("count<=9 or not priority", rows) == ["b", "c"])
        #expect(try run("priority=low or priority=high and count=10", rows) == ["a", "b"])  // and binds tighter
        #expect(try run("not (priority=high or priority=low)", rows) == ["c"])
        #expect(try run("priority=\"high\"", rows) == ["a"])
    }

    @Test func bareKeysHoldWhenSetAndNotFalse() throws {
        let rows = [["n": "a", "pinned": "true"], ["n": "b", "pinned": "false"], ["n": "c"], ["n": "d", "pinned": ""]]
        #expect(try run("pinned", rows) == ["a", "d"])
        #expect(try run("not pinned", rows) == ["b", "c"])
    }

    @Test func durationsAndTimes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = UmiTime.iso(now.addingTimeInterval(-3600)), recent = UmiTime.iso(now.addingTimeInterval(-60))
        let rows = [["n": "old", "idle_for": "600s", "status_since": old], ["n": "new", "idle_for": "30s", "status_since": recent]]
        #expect(try run("idle_for > 5m", rows, now: now) == ["old"])
        #expect(try run("idle_for < 1m", rows, now: now) == ["new"])
        #expect(try run("status_since < 10m", rows, now: now) == ["old"])   // older than 10 minutes
        #expect(try run("status_since > 10m", rows, now: now) == ["new"])
        #expect(UmiQuery.duration("1h30m") == 5400)
        #expect(UmiQuery.duration("5") == nil)
    }

    @Test func sortLimitAndThen() throws {
        let rows = [["n": "a", "p": "2"], ["n": "b", "p": "10"], ["n": "c"], ["n": "d", "p": "2"]]
        #expect(try run("n | sort p", rows) == ["a", "d", "b", "c"])        // missing last, ties keep order
        #expect(try run("n | sort -p", rows) == ["b", "a", "d", "c"])
        #expect(try run("n | sort -p | limit 2", rows) == ["b", "a"])
        #expect(try run("p=10 then n | sort n", rows) == ["b", "a", "c", "d"]) // no pane twice
    }

    @Test func parseErrorsNameAPosition() {
        for (text, position) in [("priority=", 10), ("a = 1 and", 10), ("(a=1", 5), ("a=1 | sort", 11), ("a ! b", 3), ("", 1)] {
            do {
                _ = try UmiQuery.parse(text)
                Issue.record("\(text) parsed")
            } catch let error as UmiQuery.ParseError {
                #expect(error.position == position, "\(text): \(error)")
            } catch {
                Issue.record("\(error)")
            }
        }
    }

    @Test func whatIsAQuery() {
        for selector in ["a=1", "x<3", "@jump", "a | sort b", "not hidden", "pinned and focused", "a or b"] {
            #expect(UmiQuery.looksLikeQuery(selector), "\(selector)")
        }
        for selector in [".", "#2", "3f2a", "my-pane", "notes", "priority"] {
            #expect(!UmiQuery.looksLikeQuery(selector), "\(selector)")
        }
    }

    // MARK: Today's attention behaviour as the default lists (L-12)

    private func pane(_ n: String, _ status: String, since: Double, changed: Double, unseen: Bool) -> [String: String] {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        return ["n": n, "agent.kind": "claude", "agent.status": status, "status_since": UmiTime.iso(start.addingTimeInterval(since)),
                "changed_at": UmiTime.iso(start.addingTimeInterval(changed)), "unseen": unseen ? "true" : "false"]
    }

    @Test func jumpIsNeedsInputThenUnseenOldestFirst() throws {
        let rows = [
            pane("done", "idle", since: 10, changed: 10, unseen: true),
            pane("failed", "error", since: 5, changed: 5, unseen: true),
            pane("ask2", "needs_input", since: 30, changed: 30, unseen: false),
            pane("ask1", "needs_input", since: 20, changed: 20, unseen: true),
        ]
        #expect(try run("@jump", rows) == ["ask1", "ask2", "failed", "done"])
        #expect(try run("@needs-you", rows) == ["ask1", "ask2"])   // the Dock badge counts these
    }

    @Test func seenAndWorkingPanesAreNotJumpTargets() throws {
        let rows = [pane("seen", "idle", since: 5, changed: 5, unseen: false), pane("busy", "working", since: 5, changed: 5, unseen: true),
                    pane("seenFailure", "error", since: 5, changed: 5, unseen: false), ["n": "shell"]]
        #expect(try run("@jump", rows).isEmpty)
    }

    @Test func tabSummaryPrefersTheFocusedAgentThenTheNeediest() throws {
        let summary = UmiConfig.slots.first { $0.name == "tab.summary" }!.defaultValue
        var focusedIdle = pane("focused", "idle", since: 1, changed: 1, unseen: false)
        focusedIdle["focused"] = "true"
        let asking = pane("asking", "needs_input", since: 2, changed: 2, unseen: true)
        #expect(try run(summary, [asking, focusedIdle]).first == "focused")
        let finished = pane("finished", "idle", since: 9, changed: 9, unseen: true)
        let quiet = pane("quiet", "idle", since: 10, changed: 10, unseen: false)
        #expect(try run(summary, [quiet, finished, asking]).first == "asking")
        #expect(try run(summary, [quiet, finished]).first == "finished")
        #expect(try run(summary, [["n": "shell", "focused": "true"]]).isEmpty)
    }

    @Test func templates() {
        let values = ["command": "make test", "cwd": "/tmp"]
        #expect(UmiQuery.render("{agent.title or command or cwd}") { values[$0] } == "make test")
        #expect(UmiQuery.render("in {cwd}: {agent.title}") { values[$0] } == "in /tmp: ")
    }

    @Test func doneCheckDefault() {
        #expect(UmiSlots.doneCheck("All good.\n\nStatus: done\n"))
        #expect(!UmiSlots.doneCheck("Status: done\nmore to do"))
    }

    // MARK: Causes (D-6)

    @Test func aKeyIsTheCauseOnlyWhileItIsDispatched() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .command],
                                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                                                  characters: "j", charactersIgnoringModifiers: "j", isARepeat: false, keyCode: 38))
        let during = UmiCause.dispatching(event) { UmiCause.now }
        #expect(during.kind == "key" && during.key == "ctrl+cmd+j")
        // Afterwards, whatever AppKit's currentEvent still holds, Umi's own changes are Umi's.
        #expect(UmiCause.now.kind == "umi")
    }
}

import Foundation
import Testing
@testable import Ghostty

/// I-4: an update installs itself only at a quiet moment. `UmiQuiet.reasons(in:)` decides from a
/// snapshot of the app; these give it made-up ones, with fake time. The acceptance suite checks the
/// same through `update --status` with fake agents (tests/test_quiet_updates.py).
struct UmiQuietTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Everything idle: two panes at their prompts, an idle session, nobody typing for 3 minutes.
    private func calm() -> UmiQuiet.Snapshot {
        var snapshot = UmiQuiet.Snapshot(lastInput: start, now: start.addingTimeInterval(180), idle: 120)
        snapshot.panes = [.init(id: "p1", tab: "work", state: .prompt), .init(id: "p2", tab: "work", state: .prompt)]
        snapshot.sessions = [.init(id: "s1", name: "claude-1", busy: nil)]
        return snapshot
    }

    @Test func everythingIdleIsQuiet() {
        #expect(UmiQuiet.reasons(in: calm()).isEmpty)
    }

    @Test func itNeedsTwoMinutesWithoutTypingOrClicking() {
        var snapshot = calm()
        snapshot.now = start.addingTimeInterval(119)
        let reasons = UmiQuiet.reasons(in: snapshot)
        #expect(reasons.map(\.kind) == [.input])
        snapshot.now = start.addingTimeInterval(120)
        #expect(UmiQuiet.reasons(in: snapshot).isEmpty)
    }

    @Test func aBusyPaneIsNamed() {
        for (state, words) in [(UmiQuiet.PaneState.running("make"), "make is running"),
                               (.job("sleep"), "sleep is running in the background"),
                               (.typed, "typed at its prompt"),
                               (.unknown("no marks"), "can't tell")] {
            var snapshot = calm()
            snapshot.panes[1] = .init(id: "p2", tab: "build", state: state)
            let reasons = UmiQuiet.reasons(in: snapshot)
            #expect(reasons.count == 1)
            #expect(reasons.first?.kind == .pane)
            #expect(reasons.first?.pane == "p2")
            #expect(reasons.first?.text.contains(words) == true)
            #expect(reasons.first?.line.contains("tab \"build\"") == true)
        }
    }

    @Test func aRunningTurnOrAWaitingMessageIsNotQuiet() {
        var snapshot = calm()
        snapshot.sessions.append(.init(id: "s2", name: "worker", busy: "a turn is running"))
        snapshot.sessions.append(.init(id: "s3", name: "waiting", busy: "1 message waiting to be delivered"))
        let reasons = UmiQuiet.reasons(in: snapshot)
        #expect(reasons.map(\.session) == ["s2", "s3"])
        #expect(reasons.allSatisfy { $0.kind == .session })
    }

    @Test func idleAgentsInPanesAreQuiet() {
        var snapshot = calm()
        snapshot.panes += [.init(id: "p3", tab: "agent", state: .live("s1")), .init(id: "p4", tab: "agent", state: .view("s1")),
                           .init(id: "p5", tab: "done", state: .exited)]
        #expect(UmiQuiet.reasons(in: snapshot).isEmpty)
        // An interface Umi doesn't know as a session can't be judged.
        snapshot.panes.append(.init(id: "p6", tab: "agent", state: .live("unknown")))
        #expect(UmiQuiet.reasons(in: snapshot).map(\.pane) == ["p6"])
    }

    @Test func unsavedEditsAndDialogsAreNotQuiet() {
        var snapshot = calm()
        snapshot.unsaved = ["notes.md"]
        snapshot.dialogs = ["a dialog is open"]
        let reasons = UmiQuiet.reasons(in: snapshot)
        #expect(reasons.map(\.kind) == [.editor, .dialog])
        #expect(reasons.first?.text == "notes.md has unsaved changes")
    }

    // MARK: The flags of an agent typed in a pane

    @Test func claudeFlagsComeBackWithoutThePromptOrTheConversation() {
        let flags = UmiTypedCommand.claude(["--dangerously-skip-permissions", "--model", "opus", "--resume", "abc",
                                            "--add-dir", "/a", "/b", "--verbose", "-n", "work", "fix the bug"])
        #expect(flags.fullAccess)
        #expect(flags.model == "opus")
        #expect(flags.args == ["--add-dir", "/a", "/b", "--verbose", "-n", "work"])
        let more = UmiTypedCommand.claude(["--permission-mode=plan", "--effort", "high", "-c", "--plugin-dir",
                                           "/Applications/Umi.app/Contents/Resources/agent-plugins/claude",
                                           "--plugin-dir", "/mine", "--settings", "{}", "-d", "hello"])
        #expect(!more.fullAccess)
        #expect(more.permissionMode == "plan")
        #expect(more.effort == "high")
        #expect(more.args == ["--plugin-dir", "/mine", "--settings", "{}", "-d", "hello"])
        #expect(UmiTypedCommand.claude(["--permission-mode", "bypassPermissions"]).fullAccess)
        // Options that take values though `claude --help` doesn't list them.
        #expect(UmiTypedCommand.claude(["--thinking", "disabled", "--channels", "a", "b", "--verbose", "go"]).args
                == ["--thinking", "disabled", "--channels", "a", "b", "--verbose"])
    }

    @Test func codexFlags() {
        let flags = UmiTypedCommand.codex(["--yolo", "-m", "gpt-5", "-c", "model_reasoning_effort=\"high\"", "-p", "fast",
                                           "resume", "--last", "do it"])
        #expect(flags.fullAccess)
        #expect(flags.model == "gpt-5")
        #expect(flags.effort == "high")
        #expect(flags.profile == "fast")
        #expect(flags.args.isEmpty)
    }

    @Test func theAgentsProgramIsFoundInItsArguments() {
        #expect(UmiTypedCommand.isProgram("claude", .claude))
        #expect(UmiTypedCommand.isProgram("/Users/me/.local/bin/claude", .claude))
        #expect(UmiTypedCommand.isProgram("/repo/acceptance/fakes/fake_claude.py", .claude))
        #expect(UmiTypedCommand.isProgram("/opt/lib/node_modules/@anthropic-ai/claude-code/cli.js", .claude))
        #expect(UmiTypedCommand.isProgram("codex", .codex))
        #expect(!UmiTypedCommand.isProgram("\"/x/umi-hook.sh\" claude SessionStart", .claude))
        #expect(!UmiTypedCommand.isProgram("/usr/bin/python3", .claude))
        #expect(!UmiTypedCommand.isProgram("claude", .codex))
    }
}

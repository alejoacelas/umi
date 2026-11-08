import Foundation
import Testing
@testable import Ghostty

/// I-4: an update installs itself only at a quiet moment. `UmiQuiet.reasons(in:)` decides from a
/// snapshot of the app; these give it made-up ones, with fake time. The acceptance suite checks the
/// same through `update --status` with fake agents (tests/test_quiet_updates.py).
struct UmiQuietTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Everything idle: two panes at their prompts, an idle agent in a third, nobody typing for 3
    /// minutes.
    private func calm() -> UmiQuiet.Snapshot {
        var snapshot = UmiQuiet.Snapshot(lastInput: start, now: start.addingTimeInterval(180), idle: 120)
        snapshot.panes = [.init(id: "p1", tab: "work", state: .prompt), .init(id: "p2", tab: "work", state: .prompt),
                          .init(id: "p3", tab: "agent", state: .agent(busy: nil))]
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

    @Test func aBusyAgentInAPaneIsNotQuiet() {
        var snapshot = calm()
        snapshot.panes.append(.init(id: "p4", tab: "agent", state: .agent(busy: "its agent is working")))
        let reasons = UmiQuiet.reasons(in: snapshot)
        #expect(reasons.map(\.pane) == ["p4"])
        #expect(reasons.first?.kind == .pane)
        #expect(reasons.first?.text == "its agent is working")
    }

    @Test func anAgentIsQuietOnlyWhenIdleWithNothingTyped() {
        let now = Date()
        var agent = UmiAttention.Agent(kind: .claude, status: .idle, at: now)
        #expect(UmiQuiet.agentBusy(agent) == nil)
        for status in [UmiAttention.Status.working, .needsInput, .error] {
            agent.status = status
            #expect(UmiQuiet.agentBusy(agent) != nil)
        }
        agent.status = .idle
        agent.draft = true
        #expect(UmiQuiet.agentBusy(agent)?.contains("typed") == true)
        agent.draft = false
        agent.inputTouched = true
        #expect(UmiQuiet.agentBusy(agent)?.contains("input line") == true)
        agent.inputTouched = false
        agent.idleInferred = true
        #expect(UmiQuiet.agentBusy(agent)?.contains("interrupted") == true)
    }

    @Test func idleAgentsAndExitedPanesAreQuiet() {
        var snapshot = calm()
        snapshot.panes += [.init(id: "p5", tab: "done", state: .exited)]
        #expect(UmiQuiet.reasons(in: snapshot).isEmpty)
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
        // After `--`, the first prompt, even one that starts with a hyphen.
        #expect(UmiTypedCommand.claude(["--verbose", "--", "- fix the failing tests", "-x"]).args == ["--verbose"])
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

    @Test func aRestartResumesTheConversationWithTheTypedFlags() {
        #expect(UmiTypedCommand.restartCommand(program: "claude", args: ["--dangerously-skip-permissions", "--model", "opus",
                                                                        "--resume", "old", "--add-dir", "/a", "--verbose", "fix it"],
                                               kind: .claude, session: "s1")
                == ["claude", "--model", "opus", "--dangerously-skip-permissions", "--add-dir", "/a", "--verbose",
                    "--resume", "s1"])
        // Never prompted: a fresh conversation, as typed.
        #expect(UmiTypedCommand.restartCommand(program: "/x/claude-code/cli.js", args: ["--verbose"], kind: .claude, session: nil)
                == ["claude", "--verbose"])
        #expect(UmiTypedCommand.restartCommand(program: "codex", args: ["--yolo", "-m", "gpt-5", "resume", "--last", "-i", "a.png",
                                                                       "-c", "x=1", "do it"],
                                               kind: .codex, session: "t1")
                == ["codex", "resume", "t1", "--yolo", "-m", "gpt-5", "-c", "x=1"])
        #expect(UmiTypedCommand.isOneOff(["-p", "hi"], kind: .claude))
        #expect(!UmiTypedCommand.isOneOff(["--", "-p"], kind: .claude))
        #expect(UmiTypedCommand.isOneOff(["exec", "hi"], kind: .codex))
        #expect(UmiTypedCommand.isOneOff(["-m", "o3", "exec", "hi"], kind: .codex))
        #expect(UmiTypedCommand.isOneOff(["--model=o3", "e", "hi"], kind: .codex))
        #expect(!UmiTypedCommand.isOneOff(["-m", "o3", "fix the bug"], kind: .codex))
    }

    @MainActor @Test func doneCheckReadsTheReplysLastLine() {
        #expect(UmiAgentHooks.doneCheck("Fixed it.\n\nStatus: done"))
        #expect(UmiAgentHooks.doneCheck("Status: done, pending verification: CI at 5pm\n"))
        #expect(!UmiAgentHooks.doneCheck("Status: done\nbut one more thing"))
        #expect(!UmiAgentHooks.doneCheck("Status: waiting on you: approve"))
        #expect(!UmiAgentHooks.doneCheck(""))
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

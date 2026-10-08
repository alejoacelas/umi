# Changes to the acceptance suite

Each change says what was wrong with the test (not the product), and quotes the requirement it
serves. No test was weakened to make it pass.

## 1. UI tests skip while the screen is locked (`conftest.py`)

**What was wrong.** The `ui` fixture only checked that this process has the Accessibility
permission. While the Mac's screen is locked, macOS still reports the permission, but it resolves
every window's accessibility element to the application element itself (`AXWindows`,
`AXFocusedWindow` and element-at-position all return `AXApplication`, for every app, Terminal.app
included). `UI.walk` then recurses application → menu bar → application … up to depth 40, which
never finishes, so the whole suite hangs on the first UI test instead of reporting anything.

**Change.** The `ui` fixture also skips, with the reason "the screen is locked …", when
`CGSessionCopyCurrentDictionary()` reports `CGSSessionScreenIsLocked`. Nothing about what a UI
test checks changed; they run exactly as before on an unlocked screen.

**Requirement.** The suite's own premise (TEST_INTERFACE.md): "UI tests (`ui` fixture) need this
terminal to have the Accessibility permission … Without it they're skipped, and the report says
so." A locked screen is the same situation: the accessibility tree is unavailable.

## 2. The written-checks script doesn't walk the accessibility tree on a locked screen (`checks/run_checks.py`)

**What was wrong.** Same cause as change 1: `setup_editor` uses the accessibility tree to type into
the editor for E-4's evidence whenever this process has the Accessibility permission. On a locked
screen the walk never ends and the script hangs before writing `REPORT.md`.

**Change.** That step is skipped while the screen is locked (the check then says "could not edit
through accessibility; do it by hand", which the script already handles). Every other piece of
evidence is collected as before.

**Requirement.** CHECKS.md: "When the evidence can't show a criterion …, the check says (by
hand)."

## Additions (no existing test changed)

- `tests/test_tern_extra.py`: 22 tests for risks this build's design introduces (hidden tabs whose
  panes keep running, instance and run identity, moves and undo, `wait`, the renamed core
  executable, `update --now`, the installer's download path). All pass.
- `checks/tern_verdicts.py`: the judged written-check verdicts, written into
  `results/checks/REPORT.md`.
- `checks/tern_extra_evidence.py`: screenshots for criteria `run_checks.py`'s setup can't show
  (Files mode with nested folders, Markdown images and page rules, the "changed on disk" notice).

## Phase 2

No existing test was changed or weakened in phase 2. Additions:

- **Fake Codex: `BACKGROUND n`** (`fakes/fake_codex.py`, self-test `t_codex_background` in
  `fakes/test_fakes.py`, documented in `fakes/README.md`). The brief asked whether Codex starts turns
  by itself (MA-28). It was checked with the real CLI (codex-cli 0.160.0, gpt-6-luna;
  `reference/agent-probes/probe_phase2b.py`, logs `reference/agent-logs/X15wake.jsonl` and
  `X15wakeb.jsonl`): it doesn't. What it does do, when a command keeps running after the turn
  (a background terminal), is send that command's `item/completed` later, with the finished turn's
  id and no new turn. `BACKGROUND n` reproduces exactly that shape (the item open at
  `turn/completed`, its `item/completed` n seconds later); trigger and receipt semantics are
  unchanged, and `WAKE` on Codex still replies `wake: not supported by codex`, now verified. All
  fake self-tests pass (43).
- **Fake Codex: answers are matched to server requests by id and type** (`fakes/fake_codex.py`,
  self-test `t_codex_answer_id_type`). A Tern bug answered request `0` with id `false`; the real
  codex-cli 0.160.0 ignored that answer and left the approval pending (seen in a protocol trace of
  the real CLI, with `TERN_AGENT_TRACE`), while the fake accepted it because Python treats
  `False == 0`. The fake now ignores an answer whose id is a boolean, as the real server did. Trigger
  and receipt semantics are unchanged; all 44 self-tests pass.
- **`tests/test_tern_agents_extra.py`**: tests for risks of this build's managed-agent design:
  Codex background tasks counted and never taken for a turn; a message the product died while
  handing over is delivered exactly once after the restart; a session that never received a message
  resumes after a stop; `agent wait` keeps waiting across an app restart; a self-started turn cut
  off by a crash continues; stopping a session while its harness is still starting; a harness that
  isn't installed fails clearly; `tern` inside an agent is this build's CLI; a redirect during a
  self-started turn; watching a turn that already finished notifies at once; `update --now` asks
  before cutting turns off (R-10); and a regression test for each review finding that could be
  scripted (a wait outliving its session, a cut-off turn whose conversation or folder is gone, a
  partial log line, a redirect whose harness dies, an invalid placement, quitting right after a
  harness crash, an explicit target beating a stale caller, a wait keeping its message, a stopped
  background command, timeout answers, owner-only session files). 25 tests, all pass.
- **`app/macos/TernTests/verify_agent_panes.py`** (outside the suite, like phase 1's
  `verify_ui_paths.py`): the agent-pane behaviors the suite checks through the accessibility tree,
  driven through internal `debug.agent.*` methods while the screen is locked. It doesn't count as a
  pass of the skipped UI tests; REPORT.md lists those as skipped.

## After phase 2 (by the supervisor of the runs)

- **`test_project_features_load_in_a_never_opened_folder_and_after_resume`** (`tests/test_real.py`).
  Haiku sometimes ran the subagent in the background and ended its turn with "waiting for the
  codeword-keeper agent"; the answer came in the turn Claude started by itself when the subagent
  finished (recorded: the task's `task_notification` arrives inside the turn, then a `result` with
  `origin.kind = task-notification`). The test took the first turn's reply as the answer. It now waits
  until the session settles and looks for each codeword in the agent's replies and its tools' output
  (the words exist only in the project's MCP server and subagent). MA-28: "A harness can start a turn
  without a message, for example when a background command finishes".
- **`test_user_codex_and_claude_config_untouched`** (`tests/test_real.py`) passed only because an
  earlier test had already run Codex in the same folder. Codex marks a git project it runs in with a
  writable sandbox as trusted in `~/.codex/config.toml`, and so does `codex exec -s workspace-write` or
  `--dangerously-bypass-approvals-and-sandbox` in a terminal (checked in a fresh repo with a throwaway
  `CODEX_HOME`; read-only writes nothing). The test now uses a never-opened folder and allows only
  that entry; SPEC MA-21 says so. A module fixture removes the trust entries the module's throwaway
  folders caused, and nothing else, so test runs stop adding to the user's Codex config.

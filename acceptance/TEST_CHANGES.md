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

## After the user's answers (updates ask first; workers start in the background)

The supervisor added `test_start_shows_nothing_by_default` (AP-3) with the brief. Every existing
test that needed a pane already passed a placement, so the new default broke none of them. One
existing helper was fixed:

- **`bundle_version` in `tests/test_install.py`** (used by `test_an_older_build_updates_itself` and
  `test_update_now_relaunches_the_same_instance` to wait for the update to land). **What was
  wrong:** it opened the installed app's `Info.plist` and raised if it was missing. The installer
  helper swaps the bundle with two renames (the old app aside, the new one in place), so for a few
  milliseconds there's no app at that path; a poll that lands there crashed the wait instead of
  polling again. It happened once, in the definitive run (it passed in every earlier run), and the log shows
  the update downloaded and the swap under way. **Change:** a missing `Info.plist` reads as "no
  version yet" (`None`), so the wait keeps polling; a failed install still fails the test after
  180 s, and the assertions that the old version is still in place still require "0.0.1". **Requirement:**
  I-4, "it verifies what it downloads, then installs it when the app quits"; nothing in SPEC asks
  for the swap to be atomic.

Additions:

- **`tests/test_tern_extra.py`, I-4's question** (a module fixture builds a release-stamped 0.0.1
  and a 999.0.0 once, behind a local server that logs requests; the instance checks every 2 s through
  `TERN_UPDATE_CHECK_SECONDS`, which only isolated instances honor):
  - `test_a_background_check_asks_and_downloads_nothing_until_yes`: with Finder in front, the feed
    turns newer; the background check asks (`update --status`: `asking`), Finder stays in front, the
    user's tab and pane are unchanged, a terminal keeps working; no `.zip` is requested over several
    checks, an `update --check` and a restart; a quit installs nothing; `tern update` (a yes) downloads
    and stages it.
  - `test_later_asks_again_later_and_skip_waits_for_a_newer_version`: Later holds across checks and a
    restart, then the question returns once its time (25 s here, through `TERN_UPDATE_LATER_SECONDS`)
    is up; Skip holds across checks and a restart; a newer version is asked about; nothing is
    downloaded.
  - `test_update_is_a_yes_even_after_skip_and_the_yes_outlives_a_restart`: `tern update` after Skip
    is a yes; its download fails (the zip hidden for a moment), and after a restart the same version
    downloads once, without asking, and stages.
  - `test_the_update_question_in_the_sidebar` (UI): the notice's Download / Later / Skip This Version
    buttons, no dialog; Later takes it away; "Check for Updates…" is a yes (its dialog says it's
    downloading), and the notice then offers Install Now….
- **`tests/test_tern_agents_extra.py`, AP-3's default**:
  - `test_workers_run_in_the_background_and_their_orchestrator_finds_them`: a session starts two
    workers with no placement; no pane; `agent ls --parent self` lists exactly them with their status;
    `agent open` shows one without moving the user's focus; `agent info` reports its pane.
  - `test_any_placement_option_shows_the_session`: `--focus` alone and `--window W` alone show the
    session; no option and `--background` don't.
  - `test_agents_and_people_are_told_workers_start_in_the_background`: `agent --help` and the note a
    worker gets (Claude's appended system prompt, reported by the fake's STATE) describe the new
    default; "new tab" is gone from the note.
  - `test_background_sessions_are_in_the_window_menu` (UI): Window > Agent Sessions lists a
    background session with its status; choosing it shows and focuses it.
- **Review regression tests** (`tests/test_tern_extra.py`):
  - round 1: `test_a_yes_shows_its_failures_and_never_covers_another_version`: a yes whose feed
    request fails shows as that version's failed download; after a restart with a newer version in
    the feed, the remembered yes downloads nothing and the newer version is asked about; with the
    feed back on the agreed version, exactly that zip is downloaded.
  - round 2: `test_try_again_is_a_yes_to_the_failed_version_only`: the sidebar's Download fails,
    the feed moves on, and Try Again (the same control method the buttons call) asks about the newer
    version instead of downloading it.
  - round 3: `test_the_latest_answer_counts`: Skip then Later means Later (asked again once its
    time is up); Later then Skip means Skip (a newer version is asked about at once).
- **`checks/tern_extra_evidence.py --only update`**: screenshots of the question and the staged
  update in the sidebar (`extra-I-4-update-question.png`, `extra-I-4-update-ready.png`).
- **`app/macos/TernTests/verify_agent_panes.py`**: the Agent Sessions menu (order, ✓ for shown
  sessions, choosing one) and the Dock badge, through `debug.menu` and `debug.dock_badge`.

## Agent sessions and the app changes (BRIEF-agents.md)

The agent requirements MA, AP, IA and R-1, R-2, R-8 to R-10 were replaced by AG-1 to AG-23 (the
user asked for a new design: sessions are always run headless, can go live in the agent's own interface and
come back, and are seen read-only only when the user asks). Tests of the replaced requirements were
ported to the new ones where the behaviour still applies, and dropped where the user's new design
replaced it. Nothing that still applies was weakened.

Changed tests:

- **`app/macos/Tests/Splits/SplitTreeTests.swift`, `equalized`** (upstream Ghostty test, changed by
  the UI-B work). **What was wrong:** it expected the third pane of a row to leave its neighbour at
  a 0.5 ratio before equalizing, Ghostty's halving split. **Change:** it expects 1/3, what a row of
  three equal panes has; the equalize step it checks is unchanged. **Requirement:** L-19, "a third
  makes 33/33/33 … whichever pane is split".
- **`tests/test_tern_panes_ui.py::test_move_tab_up_and_down_stay_in_their_pin_group`** (UI-B's
  test). **What was wrong:** after pinning `t2` it asked whether `t3` could move up, assuming `t3`
  was still the first unpinned tab. Pinning re-sorts the unpinned tabs (the current tab comes
  right after the pinned ones), so `t3` wasn't first. **Change:** it asks about whichever tab is
  first below the pinned group, and also checks that the pinned tab can't move down out of it
  (one more assertion). **Requirement:** S-7, "pinned tabs first … then the current (selected) tab".
- **`tests/test_tern_panes_ui.py::test_an_unseen_finish_or_a_question_colors_the_icon_and_counts_on_the_dock`**
  and **`verify_agent_panes.py`**'s badge check. **What was wrong:** they expected the Dock badge to
  count a session that finished while the user wasn't looking. The user's words keep the two apart:
  "when a session finishes and the user hasn't looked yet, or it needs them, the agent's icon takes a
  quiet color … The Dock badge counts the sessions that need the user." **Change:** a finish not seen
  yet leaves the badge empty; a question counts (one more step checks that two count as 2).
  **Requirement:** S-3, "The Dock badge counts the sessions that need the user."
- **`tests/test_layout.py::test_send_text_from_stdin_and_after_separator`**: tagged `T-1` only. It
  also carried `MA-13`, a removed requirement. The test sends to a pane (T-1); agent messages from
  stdin are AG-1's, tested in `test_sessions.py::test_text_from_stdin_and_after_separator`.
- **`tests/test_layout.py` `SHORTCUTS`**: the keys added to L-9 (navigation, palettes, Settings,
  jumps, ⇧⌘T, ⌃⌘O, ⌃⌘W) were added to the list; nothing was removed from it.
- **Ported to AG** (by the tests helper; details in `spec-drafts/tests-notes.md`): `test_robustness.py`
  (agent tests retagged AG-21, AG-22, AG-23; `exited` reads `stopped`; `--background` dropped, it is
  the default), `test_chaos.py` (retagged AG-10, AG-11, AG-13, AG-21; status names), `test_install.py`
  (`test_upgrading_keeps_sessions`: R-8 → AG-22), `test_tern_extra.py` (`tern claude TASK
  --new-window` in place of the typed command; the `tern claude --tab --pane A` part of the folder
  test is gone, because a session's folder is its `--cwd`, AG-1). `harness.py`: `clean_env` also
  removes `CLAUDE_*`, `TERN_*` and `AI_AGENT` inherited from the Claude Code session that runs the
  suite (they reached panes' shells); fake instances get their own `CLAUDE_CONFIG_DIR` and `CODEX_HOME`.
- **`checks/run_checks.py`**: a check with several ids (`**L-14, L-15, L-16: …**`) is parsed (it
  was skipped). `checks/tern_verdicts.py`: verdicts of removed checks (IA-1, AP-*) are gone.

Removed (requirements replaced by the user's new design): `test_managed.py`, `test_resumption.py`,
`test_agent_panes.py`, `test_interactive.py`, `test_real.py`, `test_tern_agents_extra.py`. What
still applies was ported to `test_sessions.py`, `test_live.py`, `test_sessions_real.py` and
`test_robustness.py`. Not ported, and why:

- typing a follow-up into Tern's agent pane, Esc there interrupting (AP-1): the pane is now
  read-only with a Take Over button; typing goes to the agent's own interface;
- undo of closing an agent pane (AP-2): removing a session from a pane is AG-8 (`agent hide`, ⌃⌘W);
  closing a view's pane leaving the session is tested;
- `tern claude|codex … -- ARGS` typed as the user's command (IA-1 to IA-3): `tern claude|codex` is
  now shorthand for `agent start … --tab --focus`, the user's "easy launch"; agents the user types
  themselves are AG-18's;
- `--drop-queued` (MA-25): not in the new CLI, messages to a busy session steer it;
- most real-agent tests: the brief asks for real tests that are few and cheap; their outcomes are
  covered with the fakes, and the real suite keeps launch/steer/resume, project instructions, live
  hand-over, plugin install and the zero-instruction orchestration tests (AG-20).

Additions: `tests/test_sessions.py`, `tests/test_live.py`, `tests/test_sessions_real.py` (AG-1 to
AG-23), `tests/test_tern_nav.py` (L-9 to L-18, S-7), `tests/test_tern_panes_ui.py` (L-19, L-20, M-4,
S-3, S-4, S-8, E-10), `app/macos/TernTests/verify_agent_panes.py` (rewritten for AG-5, AG-6, AG-8,
AG-9, S-3; with a regression check that a read-only view stays in its pane when the window gets
another split), and `checks/tern_extra_evidence.py --only ui` (agent rows, sidebar width, the three
palettes, a live session next to a read-only one).

Review regression tests (`tests/test_review_agents.py`, one test per finding that a test can reach,
each failing on the build before its fix): round 1, take over during a launch, a failed attach leaves
the pane alone, a name with quotes, a freed key given to another action, a cancelled palette run;
round 2, a session hidden mid-turn with a waiting message, a typed agent hidden mid-turn, a parked
tab's editor edits, a key given to a second terminal action, resetting a shortcut, hook paths with
spaces; round 3, a Codex server that stops reading, update-now with work in a live interface, a
waiting session whose pane closes, Rename Tab with an empty name, and a 4 MB message (found while
testing round 3). Not covered by a test: paging through more than 500 newer items of a Codex thread
to find a message (it needs a turn with hundreds of items after the message).

Fakes (`fakes/fake_codex.py`), to stay faithful to Codex: `thread/items/list` (every item with its
turn, newest first on request, paged, as in Codex's schema), and a hung server (`HANG`) stops reading
its socket as a hung process would. `test_chaos.py::test_random_operation_sequences` found a message
steered into a turn just before a crash delivered twice; it doesn't any more (12 of 12 repeats of the
helper's reproduction were clean, against 1 in 5 before).

- **`tests/test_live.py::test_a_headless_session_appears_only_when_asked`** (the helper's new test).
  **What was wrong:** it checked for the Take Over button in the first snapshot of the pane, taken the
  moment the pane's state says it shows the session, which can come before the view's controls are
  built (it failed once in about ten runs). **Change:** it checks a snapshot taken after the view shows
  the conversation. **Requirement:** AG-5, "with a Take Over button".

Round 4 regression tests: a live pane closed and its session shown elsewhere (one interface), a draft
deleted with Backspace, Ctrl-C on an idle prompt, reopening after a resize; and
`test_many_windows_opened_while_the_screen_is_locked_leave_the_app_responsive` (70 windows opened and
closed, then a session must answer), found because the whole suite stalled two thirds of the way
through with the screen locked.

Round 5 regression tests: resume of a live session, removing a working live session, a live
session's name, a Take Over that fails. Not covered by a test: a paste into a live interface (a test
would have to replace the user's clipboard) and stale file-search results arriving after a mode
change (a race of a few milliseconds).

- **`tests/test_tern_nav.py::test_jump_goes_to_sessions_needing_you_then_back`** (UI-A's test). **What
  was wrong:** it assumed the only marked panes in the shared instance were its own two; in a full run,
  a session an earlier test left finished in a tab nobody looked at was an older target, and the jump
  went there first (it passes on its own). **Change:** it clears other panes' marks before setting its
  own; what it checks is unchanged. **Requirement:** L-12, "the next session that needs the user".

Round 8 and 9 regression tests: background work from the interface across a quit, an unknown terminal
action refused; Take Over never types into another program, a message sent while Codex starts steers
its first turn, hiding a live Codex session ends its interface. Not covered by a test: a paste that
waits for confirmation, and cancelled file searches (timing).

Round 10 (the last review round; its findings were fixed afterwards and not reviewed again):
`claude --resume` typed by hand for a session Tern runs headless, an answer typed into a dialog, a
typed agent's own config folder, a parked session reopened where asked.

Found while updating this Mac's copy to 0.4.0 (fixed after the release, in the next version):
`test_a_plugin_installed_from_another_copy_of_tern_is_not_current`,
`test_a_disabled_claude_plugin_is_not_current`. And `test_sessions_real.py::test_plugins_install_into_the_agents_configuration`
showed that the agents' plugin commands, run from the home folder, changed the user's
`~/.claude/settings.json` (Claude Code reads it as that folder's project settings), which disabled
the plugin the installed copy had just enabled; Tern now runs them from an empty folder of its own,
and the test passes with the user's plugin enabled before and after.


## Warp's look for terminals, the sidebar order, and what 0.4.0 left (BRIEF-blocks.md)

New: `tests/test_tern_blocks.py` (S-9 to S-12: at the bottom, through `clear` and ⌘K, a completion
list below the prompt; blocks with their folder, duration and output, a running block's time, failed
blocks' tint and bar, lines between blocks, the bold command; the folder box; full-screen programs,
other shells, readers, only inside Tern). They read the app's internal `debug.blocks` method and decode
`tern screenshot` images with Quartz (no new dependency). `tests/test_suite_hygiene.py` checks the
cleanup of the user's agent folders on a made-up home folder.

- **`tests/test_tern_nav.py::test_current_tab_first_then_by_last_agent_stop`**, replaced by
  `test_only_the_current_tab_and_tabs_whose_agent_stopped_move`. **What changed:** the requirement.
  The user replaced the order it checked ("current tab is at the top and then ordered by which one had
  an agent last stop/deliver", re-sorted on every selection) with "other than the focused session, tabs
  should only move when an agent finishes their turn". The old test expected the tab the user left to
  drop back to its stop's place; the new one checks that it stays, that the selected tab moves to the
  top, that a tab whose agent stops moves to just below it (the latest stop first), and that a stop in
  the current tab, a cleared mark or a stop first seen long after it happened move nothing.
  **Requirement:** S-7 as rewritten.
- **`tests/test_live.py::test_an_interactive_launch_goes_live_after_its_first_turn`**. **What was
  wrong:** it read `agent info`, then the screen, and took `starting` to mean the first turn hadn't
  ended. After the first turn ends the session also says `starting` while it opens its own interface
  ("opening its own interface"). In a loaded full run, waiting for the view's transcript outlasted the
  3-second turn, so the screen was read during that hand-off, showed the interface, and the test failed
  (once in a full run; it passed alone). **Change:** it checks the order of events: whenever the
  interface is on screen, the first message is already `done`. The status check stays for the case
  where the turn hasn't ended. **Requirement:** AG-2, "the session runs headless until its first turn
  finishes, and is then resumed live in that place".
- **`tests/test_review_agents.py::test_take_over_never_types_into_another_program`**. **What was
  wrong:** it waited for the shell under the view by looking for `%` or `$` on screen, which zsh's
  default prompt shows and Tern's block prompt (the folder, then an empty command line) doesn't.
  **Change:** it also accepts the pane's prompt being ready as `debug.blocks` reports it. What it checks
  is unchanged. **Requirement:** AG-6.
- **`tests/test_sessions_real.py`** (the module's description). It said the only lasting change to the
  user's configuration was one trust answer per agent; the brief asks the suite to leave the user's
  agent folders as it found them, which `conftest.py` now does after every real run
  (`tests/agent_config.py`).

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

Found by the suite: `test_chaos.py::test_random_operation_sequences` found a Codex message delivered
again and again after a crash (start, stop, a message that crashes it: up to 39 deliveries).
`test_review_agents.py::test_a_message_that_crashed_codex_before_its_turn_was_reported_is_not_sent_again`
reproduces it deterministically (chaos seed 977) and fails on the build before the fix. Also new:
`test_tern_blocks.py::test_the_mouse_selects_what_is_drawn_where_it_points_ui` (a real double-click in a
pane whose view is moved down selects the word drawn there) and
`test_tern_panes_ui.py::test_shift_cmd_t_is_listed_where_shortcuts_are_edited`.

- **`tests/test_sessions.py::test_interrupt_goes_first_and_nothing_sent_before_it_is_lost[codex]`**.
  **What was wrong:** it required the redirect's reply to contain the redirect's own answer. The message
  sent just before the redirect (steered, not taken in by the interrupted turn) may be steered into the
  redirect's turn, and then that turn's reply, which is the reply of every message it answered, comes
  after it. With the screen locked the timing made that happen every time (it passed with the screen
  in use). The receipts already prove the redirect was the next thing the agent saw. **Change:** the
  reply contains the redirect's answer, or the steered message's when both share the turn; the
  transcript must show the redirect's own answer. **Requirements:** AG-10 ("While the session works,
  the agent sees TEXT during its current turn"; "`--interrupt` stops the running turn first, and TEXT
  is the next thing the agent sees") and AG-12 ("waits until the turn answering the latest (or given)
  message has ended … then the reply").
- **`tests/agent_config.py`**: a live test's folder is reused run after run, so Claude Code adds its
  transcripts to a project folder that already existed; those are removed too (the first real run
  left one, removed by hand).
- **`tests/test_live.py::test_an_interactive_launch_goes_live_after_its_first_turn[claude]`**, again:
  the failure the brief describes ("the interface was on screen while the session still said
  `starting`") also happens at the test's last check. The agent's interface draws its screen and then
  runs its SessionStart hook, which reaches Tern through `tern agent hook`, a process of its own; until
  it arrives the session is `starting` ("opening its own interface"), which is true: Tern hasn't heard
  from the interface yet. In a loaded run (here with the screen locked) that gap was long enough for
  the test to read it. **Change:** it waits up to 15 s for `live`/`idle` after the interface shows
  the conversation. **Requirements:** AG-2 ("then resumed live in that place") and AG-13 (truthful
  status).
- **`tests/test_robustness.py::test_no_zombies_accumulate`**. **What was wrong:** it failed on any
  zombie child of the product at one instant, 2 s after its sessions were removed; in two full runs a
  shared instance that had run ~200 tests had one at that instant. A process caught between its exit
  and its parent's wait is a zombie for that moment without accumulating. **Change:** it fails on a
  zombie still there 5 s later, and says which process and parent it was. Looking for the cause, a real
  way to leak one was found and fixed: a harness process outliving its session's object (removed while
  the harness was still exiting) was never reaped. **Requirement:** AG-21 ("No zombies accumulate").

## Umi: the rename (BRIEF-umi.md)

- **Everything renamed with the product**: `targets/tern.json` is `targets/umi.json` (with `UMI_*`
  variables, `Umi.app`, `umi-app`, `umi`), `test_tern_*.py` are `test_umi_*.py`, `checks/tern_*.py`
  are `checks/umi_*.py`, and the tests' texts and fake plugin names follow. No assertion changed.
  The targets for the old ui-a/ui-b worktrees were removed.
- **`targets/umi.json` and `tests/harness.py`**: the target's paths are relative to the target file
  (`../../app/...`), and the harness resolves command words starting with `./` or `../` the same way,
  so the suite runs from any checkout (the old target pointed into `~/dev/terminal-3`).
  `other_products`/`other_names` list Tern (P-1: Umi must coexist with its former self).
- **New, `tests/test_umi_import.py`** (SPEC R-11, coming from Tern): the first launch copies a
  "Tern" folder's tabs, pins, splits and sessions and leaves the folder byte-identical, and copies
  nothing again; a turn "Tern" is still running is delivered once and never run by Umi; nothing is
  copied when Umi has state of its own; a symbolic link in Tern's folder isn't copied or followed;
  and (P-1) an inherited `GHOSTTY_RESOURCES_DIR` of another app doesn't reach Umi's terminals.
- **Not a test change, but it changed results**: four blocks tests (S-10, S-11) failed after the
  rename because new windows were 65 columns wide. They had passed because isolated instances share
  the app's user defaults, and `dev.tern.app` remembered the size of Alejo's own Tern window
  (`NSWindowLastPosition`); `dev.umi.app` had none, so windows took the nib's 800 points minus the
  sidebar. Umi's window now starts at 1180 × 740 points, and isolated instances neither use nor
  save the remembered frame, so the suite no longer depends on how the user last sized a window.
- **`tests/test_editor.py::test_edit_targets_the_calling_pane_and_never_falls_back`** (and the same
  pattern in `tests/test_layout.py::test_cli_inside_panes_defaults_to_this_pane`). **What was
  wrong:** it waited for `EDIT-OK` on screen after typing `umi edit … && echo EDIT-OK`, and the
  typed command line itself contains `EDIT-OK`, so the wait could end before `umi edit` had run;
  in loaded full runs the check then found no document (twice in a row after the rename).
  **Change:** the waits match the whole output line (`^EDIT-OK$`, `^RENAMED-OK$`, `^TAB-OK$`).
  **Requirements:** E-9, P-4.
- **New, review round 3**: a watch copied from Tern never messages its supervisor
  (`test_a_copied_watch_never_resumes_its_supervisor`, fails on the build before the fix with the
  watch's message delivered), and a private Tern folder stays private
  (`test_a_private_tern_folder_stays_private`).
- **Review round 4**: `test_a_private_tern_folder_stays_private` also checks a Tern folder reached
  through a link (the link's own mode is looser than the folder's).
- **Not a test change**: a full run had 7 failures and errors from a full disk ("No space left on
  device", pytest unable to make its temporary folders); the same tests passed once space was freed.
  Full runs now keep one pytest temporary folder (`-o tmp_path_retention_count=1`).
- **`tests/test_sessions_real.py::test_a_session_goes_live_takes_messages_and_is_handed_back_and_taken_over`**.
  **What was wrong:** (1) it ran in `.work-real/live-claude` and `live-codex`, folders made by hand in
  the old checkout (the Codex one an empty git repository), so a fresh checkout failed with "no such
  folder"; (2) answering the agent's first-run trust question expected numbered choices, and Claude
  Code now asks with unnumbered ones, "No, exit" preselected; (3) the installed Codex CLI, being one
  version behind, first offered to update itself. **Change:** the test makes the folders as they were;
  the trust answer finds the "Yes" choice numbered or not; Codex's update offer is skipped with Esc
  (never Enter, which would run Codex's installer). The checks are unchanged. **Requirements:** AG-2,
  AG-6, AG-7, AG-9.

## Tabs keep their order, as in Warp (BRIEF-tab-order.md, 0.6.1)

S-7 changed: the requirement the old tests checked (the current tab at the top, tabs whose agent
stopped just below it) is gone, so those tests were replaced by tests of the new rule, not loosened.
**Requirement:** S-7, "the standard behavior from warp that doesn't switch tab order depending on
recency".

- **Removed** (they asserted the old rule): `test_only_the_current_tab_and_tabs_whose_agent_stopped_move`,
  `test_a_selected_tab_moved_by_hand_keeps_its_place_when_an_agent_stops`,
  `test_pinned_tabs_stay_first_and_placements_hold_until_the_next_reorder` and
  `test_next_tab_walks_the_sidebar_order_as_seen` (`tests/test_umi_nav.py`), and the `settle()` helper,
  which waited for the old order's freeze (`debug.navigation`'s `order_frozen`, removed from the app).
- **New, `tests/test_umi_nav.py`**: `test_selecting_a_tab_never_moves_it` (every route the suite can
  drive: `tab focus` by id and `#N`, `next`, `prev`, `back`, the Tab N / Last Tab / Cycle / Show Next /
  Back items, a ⇧⌘] press, a pane focus, `jump` and `jump back`, close and `reopen`, then a wait longer
  than the old settle delay); `test_an_agent_finishing_its_turn_never_moves_its_tab` (stops and
  questions in the current tab and others leave the order, and the rows show their marks);
  `test_new_tabs_open_right_after_the_current_one` (Warp's placement; background tabs last; `--index`;
  below a pinned current tab); `test_tabs_move_only_when_the_user_moves_them` (`tab move --index`,
  `--down`, Move Tab Up, a drop, pin and unpin; selecting afterwards moves nothing);
  `test_next_and_prev_walk_the_sidebar_order_which_stays_put` (replaces the "as seen" test).
- **New, `tests/test_live.py::test_a_turn_ending_never_moves_a_tab`**: the fake Claude and Codex finish
  turns in tabs the user isn't in (and one in the tab the user is in); no tab moves, and the rows show
  the finished mark. (The tests above stand in for the agent engine; this one is the real path.)
- **Changed, `tests/test_umi_nav.py::test_tab_number_items_and_cycling`**: it also checks the order is
  unchanged afterwards. `test_tab_keys_work_whatever_has_focus` and the `ui` test
  `test_tab_keys_from_the_editor_the_file_tree_and_the_palette` no longer wait for the order to settle.
- **Changed, `tests/test_umi_panes_ui.py::test_move_tab_up_and_down_stay_in_their_pin_group`**: it
  allowed any order of the unpinned tabs after pinning ("pinning re-sorts the unpinned tabs"); it now
  asserts the exact order (only the pinned tab moves, to the end of the pinned group).
- **Review round 1 (0.6.1)**: `tests/test_umi_panes_ui.py::test_markdown_opens_in_the_tab_whose_folder_is_closest`
  also checks that the new tab a file from outside opens goes right after the current tab (it went
  last); new `ui` test `tests/test_umi_nav.py::test_cmd_t_opens_after_the_current_tab_and_redo_puts_it_back_there`
  (Redo of New Tab opened the tab one place further down). **Requirements:** S-7, E-10, M-3.
- **Review rounds 2 and 3 (0.6.1)**: new `tests/test_live.py::test_undo_and_redo_of_a_move_leave_a_tab_made_since_in_its_place`
  (a hidden live interface shown again in a tab, after a tab the move didn't touch or after the moved
  one, then Undo and Redo of the earlier move: the tab went last, then moved along with the moved tab),
  and `tests/test_umi_nav.py::test_undo_and_redo_put_back_only_the_tabs_a_step_moved` (Move Tab Up, a
  pin and a move to another window, undone and redone through the Edit menu without the accessibility
  tree). **Requirements:** S-7, M-3.

## Updates install themselves at a quiet moment (BRIEF-quiet-updates.md, 0.6.2)

I-4 changed: by default a check that finds a newer version downloads it without asking and installs
it at a quiet moment; asking first is the `auto-update = check` setting. **Requirement:** I-4, "yes
let's make install when quiet the default"; AG-7 and AG-22 for what comes back.

- **Changed, `tests/test_umi_extra.py`**: the update-question tests (`test_a_background_check_asks_…`,
  `test_later_asks_…`, `test_update_is_a_yes_…`, `test_a_yes_shows_its_failures_…`,
  `test_the_latest_answer_counts`, `test_try_again_…`, the `ui` test `test_the_update_question_in_the_sidebar`)
  launch the installed copy with `--auto-update=check`, the setting that keeps the behaviour they
  check. What they assert is unchanged. Two of them counted every zip request; once a newer version
  is staged, the installed version's own zip is now fetched once too, to keep for a rollback, so they
  count downloads of the newer version (`_update_downloads`, which leaves out `/old/`). Their "nothing
  is downloaded until yes" checks still count every zip.
- **Changed, `tests/harness.py`**: `Instance(args=…)` adds launch arguments (config settings), used above.
- **New, `tests/test_quiet_updates.py`** (fake agents, fake time): two minutes without input; a busy
  pane (text typed at the prompt, a program, a background job, a shell started from the pane's shell,
  each pane judged on its own); a running turn and a message waiting for a live Claude with a draft;
  unsaved editor changes; idle agents in panes (a live interface, a read-only view, a `claude` the
  user typed) are quiet, and text typed into one isn't.
- **New, `tests/test_umi_extra.py`** (release builds): `test_an_update_installs_itself_at_a_quiet_moment_and_everything_comes_back`
  (downloaded without asking; not installed while a pane runs `sleep`, and the status names the pane;
  installed after a countdown once quiet; the relaunch keeps the app in front in front; tabs, folders
  and a `claude` typed with flags come back, same conversation, same flags);
  `test_not_now_activity_install_now_and_rollback` (activity stops the countdown, Not now waits, Install
  now installs; `--rollback` goes back and the newer version doesn't return by itself; `update --now`
  brings it back); `test_a_failed_install_doesnt_loop`; `test_an_isolated_instance_never_updates_the_users_app`.
- **New, `tests/test_live.py::test_a_claude_typed_with_flags_comes_back_with_them`**: quit and restart;
  the typed `claude --add-dir … --dangerously-skip-permissions --model …` comes back live in its pane,
  on its conversation, with those flags, and its first prompt isn't run again.
- **New, Swift unit tests `UmiQuietTests`**: the quiet decision from made-up snapshots with fake time,
  and the parsing of a typed agent's flags.
- **Review rounds 1 and 2 (0.6.2)**: `test_idle_agents_in_panes_are_quiet` also checks that Esc at the
  interface's prompt leaves a draft counted, and that Up and Ctrl-P make the line count as possibly
  holding text until it's cleared; new `test_a_job_beside_an_agent_interface_is_not_quiet`
  (`sleep 300 &` before the typed `claude`); new `tests/test_live.py::test_a_session_resumed_by_hand_takes_the_flags_typed_for_it`.
  **Requirements:** I-4, AG-10, AG-18.
- **Review round 3 (0.6.2)**: `test_idle_agents_in_panes_are_quiet` also types `a`, Left, Backspace
  and Ctrl-U (still not quiet), then sends the line (quiet); `test_a_running_turn_or_a_waiting_message_is_not_quiet`
  also checks a Codex `BACKGROUND` command left running after its turn, and that a prompt sent in
  Codex's attached interface leaves it quiet once its turn is done. **Requirement:** I-4.
- **Review round 4 (0.6.2)**: anything reaching an agent's input line now counts until a prompt is sent
  or Ctrl-C clears it, so `test_idle_agents_in_panes_are_quiet` checks that Esc and Ctrl-U leave it
  counted, that Up, Ctrl-P and Left make it count, and that Ctrl-C or sending a prompt empties it (the
  round-3 checks of Left and Backspace are part of this); `test_a_busy_pane_is_not_quiet` adds a job
  started with job control off (it stays in the shell's own process group). **Requirement:** I-4.
- **Review round 5 (0.6.2)**: Ctrl-C no longer counts as emptying an agent's input line for an update,
  so `test_idle_agents_in_panes_are_quiet` sends a prompt where it pressed Ctrl-C, checks that Ctrl-C
  keeps the line counted, and adds a prompt queued during a turn followed by a newer unsent draft
  (still counted once the turns are done). **Requirement:** I-4.
- **Review round 6 (0.6.2)**: `test_idle_agents_in_panes_are_quiet` also checks that Shift-Return isn't
  taken as sending, and that a turn interrupted with Esc keeps the moment from being quiet until the
  agent's next hook (here, the next prompt). **Requirement:** I-4.
- **Review round 7 (0.6.2)**: `test_a_busy_pane_is_not_quiet` adds a double-forked job, `(sleep 302 &)`,
  which leaves the shell but keeps the pane's terminal; `test_idle_agents_in_panes_are_quiet` checks
  that keys typed while a permission dialog is up keep the line counted. (Keys reaching a typed agent
  before its first hook come from the keyboard only, so no non-`ui` test can drive them.)
  **Requirement:** I-4.
- **Review rounds 8 to 13 (0.6.2)**: `test_a_busy_pane_is_not_quiet` adds a right prompt (`RPROMPT`):
  quiet with nothing typed, not quiet with something typed. Swift unit tests for `--` and for Claude's
  unlisted value options. (Input reaching a pane before Umi follows it, while an interface is being
  prepared, and IME composition come from the keyboard or exact timing, so no non-`ui` test can drive
  them.) **Requirement:** I-4.
- **Review round 14 (0.6.2)**: new `test_an_agents_own_hook_still_running_is_not_quiet` (a second
  plugin whose Stop hook sleeps 8 s). **Requirement:** I-4.
- **Review rounds 15 and 16 (0.6.2)**: `test_an_agents_own_hook_still_running_is_not_quiet` uses a hook
  that `exec`s its program and runs it in the interface's very first turn. **Requirement:** I-4.
- **Review round 17 (0.6.2)**: every process an agent interface started counts as running, so
  `test_an_agents_own_hook_still_running_is_not_quiet` uses a fast first turn right after the interface
  opens. **Requirement:** I-4.
- **Review round 18 (0.6.2)**: `test_a_running_turn_or_a_waiting_message_is_not_quiet` adds a process a
  headless agent leaves running after its turn (`RUN python3 … &`). **Requirement:** I-4.
- **Review round 19 (0.6.2)**: `test_idle_agents_in_panes_are_quiet` adds work a live interface leaves
  running detached from its terminal. **Requirement:** I-4.

## Even pane sizes after a resize, and comments (BRIEF-comments-and-pane-sizes.md)

L-19 changed: a dragged divider stays where it's dropped and counts as placed by hand; a pane
between placed dividers keeps its size, and only the panes not sized by hand share the stretch on
each side of the dragged divider (the editor panel counts as the last pane of the top row).
**Requirement:** L-19, "when I resize a panel, the remaining panels split the remaining screen
equally" and "only the panes that have not been manually resized shrink/grow in response to other
pane resizing."

- **Replaced, `tests/test_umi_panes_ui.py`**: `test_a_divider_moves_its_neighbors_and_double_click_equalizes_its_row`
  asserted the old rule (only the two panes beside the divider change: 50/16.7/33.3). It is now
  `test_a_dragged_divider_shares_each_side_equally_and_double_click_equalizes_its_row` (50/25/25,
  then 50/30/20 from the second divider, the first pane keeping its size; a column in the row keeps
  its 70/30 inside; double-click as before).
- **New, `tests/test_umi_panes_ui.py`**: `test_panes_sized_by_hand_keep_their_size_and_the_others_share`
  (40/20/20/20, then 40/25/25/10; a split keeps the placed dividers; double-click forgets them);
  `test_a_dragged_middle_divider_shares_both_sides` (37.5/37.5/12.5/12.5);
  `test_a_keyboard_resize_still_moves_only_the_two_neighbors` (`pane resize` keeps the old rule);
  `test_the_editor_panel_is_the_last_pane_of_the_top_row` (a free editor shares the right side; its
  divider, through the new internal `debug.ui.editor.divider`, leaves panes sized by hand alone and
  evens the others; once dragged, the editor keeps its size). `editor ls` now reports the panel's
  `fraction` for this.
- **Changed, Swift unit tests `SplitTreeTests`**: `aDividerMovesOnlyItsNeighbors` became
  `draggingADividerSharesEachSideEqually`; new `aPaneSizedByHandKeepsItsSize`,
  `panesNotSizedByHandShareTheStretchBetweenPlacedDividers`, `draggingAMiddleDividerSharesBothSides`,
  `aColumnInARowCountsAsOneAndKeepsItsInside`, `splitsAndClosesKeepTheDividersPlacedByHand`,
  `theEditorPanelIsTheRowsLastMember`, `draggingTheEditorsDividerSharesAmongPanesNotSizedByHand`,
  `aKeyboardResizeMovesOnlyTheTwoNeighbors`.

Comments (E-11). **Requirement:** E-11, "when I select text in Umi I want it to offer me the option
of leaving a comment on the doc … make sure comments are visible to you."

- **New, `tests/test_comments.py`** (through the internal `debug.ui.comments`, which runs the
  margin's own script in the preview: select words, press Comment, type, submit, click controls):
  the comment lands in the file beside its words in Roughdraft's format and its card is level with
  them, beside the text; a narrow panel shows the selected thread under its words; reply, edit,
  resolve, show resolved, reopen and delete (with its confirmation, leaving the file as it was);
  links taken whole, table cells, overlaps and code blocks refused with a reason; Edit ▸ Add Comment
  (and, as a `ui` test, its ⌥⌘M menu key); a comment being written survives an agent changing the
  file; `comments` with no app running (add, list, reply from stdin, resolve, delete, errors); a git
  pull merging another edit keeps the anchor, and removing the markup leaves a detached comment
  shown in the margin; the review loop (`comments wait` returns on Done with the comments, the
  margin says an agent waits, the agent's reply and resolve show in the margin).
- **New, Swift unit tests `UmiCommentsTests`**: the format (round trips, endmatter, block scalars,
  CRLF, Roughdraft files), placement, relocation, the preview's offsets, and a comment keeping
  unsaved edits unsaved.
- **Changed, `tests/test_comments.py` helpers hide the sidebar in their window**: another test leaves
  new windows' sidebar 600 points wide, which made the editor too narrow for the margin.
  `draggingADividerSharesEachSideEqually`; new `draggingAMiddleDividerSharesBothSides`,
  `aColumnInARowCountsAsOneAndKeepsItsInside`, `thePanelAfterTheTreeSharesTheRightSide`,
  `equalizingTheTopRowLeavesAnEvenRow`, `aKeyboardResizeMovesOnlyTheTwoNeighbors`.

## Files in panes, stacks, Warp's colors (2026-11-04)

E-1 and E-9 changed: each file opens in a pane of its own, to the right of the pane it was opened
from, three panes to a tab, then a new tab. The editor panel (and its divider) is gone, so L-19's
rule for it is gone too. M-7 is new (stacks). **Requirements:** E-1, E-9, L-19, M-7; Alejo's words in
REQUESTS.md (2026-11-04).

- **Replaced, `tests/test_umi_panes_ui.py`**: `test_the_editor_panel_is_the_last_pane_of_the_top_row`
  (the panel's `fraction`, `debug.ui.editor.divider`) became `test_a_file_pane_shares_its_row_like_any_pane`:
  a file pane is the middle of three equal columns and a dragged divider treats it as a pane.
- **New, `tests/test_editor.py`**: `test_files_open_in_panes_beside_the_caller_three_to_a_tab` (order,
  the fourth file's new tab, no second pane for an open file, focus stays, preview modes for Markdown,
  JSON and CSV, `pane` in `editor ls`); `test_a_file_opened_from_a_pane_goes_beside_that_pane` (between
  the caller and its right neighbour); `test_closing_a_file_pane_never_loses_edits` (E-3 through
  `pane close`). The existing editor tests keep their assertions: `editor ls --pane P` still lists the
  files of P's tab.
- **New, `tests/test_umi_stacks.py`**: stacking by a drop on a pane's middle (from the same and another
  tab), focusing a member shows it, closing the member on show, a member whose program ends, a stack
  left with one pane, undo, files stacking with terminals, and (UI) ⌘[ / ⌘] and the strip.
- **New, `tests/test_umi_panes_ui.py`** (branch `pane-tab-drop`):
  `test_a_pane_dropped_on_the_previous_or_next_tab_target_moves_there` and its real-mouse `_ui` twin
  (M-4).
- **Changed, `tests/test_comments.py`**: the helpers sized the editor panel (`debug.ui.editor.divider`);
  they now drag the divider between the caller and the file's pane to give the file the same share.
- **Changed, `tests/test_editor.py` `test_refuses_what_it_cannot_edit`**: each of the three cut-UTF-8
  files is closed after it is checked, so all three open in the caller's tab (a third would go to a
  new tab, which `editor ls --pane` doesn't list).
- **Replaced, `tests/test_umi_extra.py`** `test_editor_documents_follow_a_pane_out_of_its_dissolving_tab`
  became `test_a_file_stays_open_when_the_pane_that_opened_it_moves_away`: files no longer belong to a
  tab, so the tab keeps the file's pane and the file.
- **Changed, `tests/test_review_agents.py` `test_hiding_the_last_pane_of_a_tab_keeps_its_editors_edits`**:
  the edits also count as kept when the file's pane is still open with them (its tab no longer goes).
- **Fixed, `tests/test_umi_stacks.py`**: the undo test read the undo state (`debug.undo`) without
  undoing; it now checks the step is "Stack Pane" and performs Undo. `frames()` in
  `test_umi_panes_ui.py` skips stack members that aren't on show (they have no frame).

- **Changed, `tests/test_umi_blocks.py`** (found by this run's quick loop, after `d29e2c90b` gave Umi
  Warp's default Dark palette): `test_the_top_padding_extends_again_once_the_view_fills` detected red
  as green and blue below 90, which the palette's red `#ff8272` isn't; it now takes red well above
  green and blue (60 or more). `test_the_command_of_a_block_that_ran_is_bold` measured the densest
  band of text in the pane's left half, which with the brighter palette was the long working folder
  above the prompt in both screenshots (1709 against 1709); it now runs in `/`, so the band is the
  command again. The command is drawn bold (checked in the screenshot). **Requirements:** the
  tests' own (padding colour, bold commands), unchanged.

## Removed features: the shortcuts editor, the copy from Tern, `umi://open` links (2026-11-04)

Alejo removed three features (relayed by his agent). Only tests of the removed features were deleted;
every other test runs as before.

- **Settings opens the config file (L-17)**. ⌘, no longer opens a shortcuts editor: it opens
  `~/.config/umi/config` in the editor, and `umi shortcuts` is the way to change shortcuts.
  - **Replaced, `tests/test_umi_nav.py`**: `test_settings_opens_from_the_menu` (the Settings window
    showed) is now `test_settings_opens_the_config_file_in_the_editor` (Settings… opens the file in
    the editor, made empty when missing, left as it was when it exists; `XDG_CONFIG_HOME` points at
    a scratch folder). The `ui` test `test_cmd_comma_opens_settings_where_a_shortcut_is_recorded`
    (recording a key in the editor) is now `test_cmd_comma_opens_the_config_file` (a real ⌘, press
    opens the file).
  - **Removed**: the `settings` case of `test_tab_keys_work_whatever_has_focus` (no Settings window
    to have focus), and the internal `debug.navigation` field `settings_visible` and `debug.key`
    focus `settings` it used.
  - **Unchanged**: every `umi shortcuts` test (`test_shortcuts_can_be_changed_cleared_and_reset_without_a_restart`
    and the review-round tests in `test_review_agents.py` and `test_umi_panes_ui.py`) still covers L-17.
    The written check L-17 is gone: L-17 is now checked by script only.
- **No copy from Tern (R-11 is gone)**. Both of Alejo's Macs already have Umi state, so the first
  launch no longer copies Tern's, and inherited `TERN_*` variables are no longer cleared.
  - **Removed, `tests/test_umi_import.py`** (all seven R-11 tests) and the `UMI_IMPORT_STATE_DIR`
    hook it used. Coexisting with Tern stays covered by P-1 (`other_products` still lists Tern).
- **No `umi://open` links (I-6 is gone)**. Documents from the server are read and edited on a web
  page the agent server serves. Opening files from Finder and `open FILE` (I-3, E-10) is unchanged.
  - **Removed, `tests/test_umi_panes_ui.py`**: `test_open_links_pull_first_and_stay_inside_the_root`
    and the internal `debug.ui.open_url` it used (its entry above is removed with it).
- **Changed, `tests/test_umi_panes_ui.py` `test_dragging_a_pane_to_the_top_or_bottom_centre_moves_it_between_tabs_ui`**:
  the second drag finds the right-hand pane from the app's pane frames (offset from the pane area the
  accessibility tree gave for the single pane): the tree reports one "Terminal pane" element for two
  split panes. The drag is still the real mouse on the grab handle. Seen on mac-air-2: a lingering
  notification banner over the top right of the screen covers that handle and fails the test.
- **Changed, `tests/test_umi_panes_ui.py` `test_dragging_a_tab_row_reorders_and_the_row_menu_opens_ui`**:
  the row menu opens with a real right-click instead of `AXShowMenu`, and the test looks for it
  anywhere in the windows' accessibility tree. `AXShowMenu` opened the menu but returned -25204
  (the menu runs its own event loop, so the call times out), and the menu is a child of the
  window, not of the app, so the test never saw it. It checks the same items, then that Escape
  closes the menu: the menu it left open made the next test's drag fail.

## Added: web panes (E-12, 2026-11-04)

New requirement, new tests only; no existing test changed.

- **Added, `tests/test_umi_web.py`**: a local HTTP server on `127.0.0.1` stands in for the agent
  server, listed as `umi-web-origin` in a scratch `XDG_CONFIG_HOME`. The tests cover `edit URL`
  (placement beside the caller, no second pane for the same URL, other origins refused), a link
  opened from a terminal through the internal `debug.ui.open_url` (what the terminal's open-URL
  action runs), navigation within the origin and to another one (`localhost` vs `127.0.0.1`),
  moving and stacking without the page loading again, restoring by URL after a relaunch with the
  page's local storage intact and the pane not holding up a quiet update, and a screenshot showing
  the page. One `ui` test ⌘-clicks a URL printed in a terminal with the real mouse.
- **Test hook, `UMI_TEST_BROWSER_LOG`**: links a web pane sends to the default browser are written
  to that file instead of opening a browser on the test Mac.

## Markdown opens in one docs tab (E-10, 2026-11-05)

E-10 changed: Markdown opened from outside Umi goes to one shared docs tab instead of the closest
tab; other text files still go to the closest tab. **Requirement:** E-10.

- **Changed, `tests/test_umi_panes_ui.py`**: `test_markdown_opens_in_the_tab_whose_folder_is_closest`
  became `test_text_files_open_in_the_tab_whose_folder_is_closest`, and it and
  `test_ties_go_to_the_current_tab_and_any_pane_of_a_tab_counts` open `.txt` files instead of `.md`:
  the closest-tab rule now covers only non-Markdown files. Their assertions are unchanged.
- **New, `tests/test_umi_panes_ui.py`**: `test_markdown_opens_in_one_docs_tab_most_recent_first`
  (five files from two folders share one tab, one stack, newest first and on show; opening one again
  makes it the most recent; a text file still goes by folder).

## The sidebar as Warp's vertical tabs (S-2, S-3, S-4, S-8, S-13; Warp parity, 2026-11-05)

S-4 changed: the row menu takes Warp's labels ("Pin tab", "Copy tab title", "Rename active pane",
"Close other tabs" …) and order, leaves out items that can't apply instead of greying them, and
shows its colors as a row of dots (Default plus Warp's six). Renames happen in the row. S-2 changed:
each window shows or hides its own sidebar. **Requirements:** S-2, S-3, S-4, S-8, S-13.

- **Changed, `tests/test_umi_panes_ui.py` `test_the_row_menu_has_warps_items`**: the titles it
  looks for are Warp's; it no longer expects Move Tab Down and Close Tabs Below on the window's last
  tab (Warp leaves them out there; the new tests check them on a middle tab); it counts 7 color
  dots instead of 10 colors. Every action it performed is still performed and checked.
- **Changed, `tests/test_umi_panes_ui.py` `test_move_tab_up_and_down_stay_in_their_pin_group`**: a
  move that can't apply is checked to be absent from the menu instead of disabled. The moves and the
  pin-group boundaries it checks are the same.
- **Changed, `tests/test_umi_panes_ui.py` `test_close_other_tabs_and_tabs_below`**: performs "Close
  other tabs" (Warp's label) instead of "Close Other Tabs"; nothing else changed.
- **Changed, `tests/test_umi_panes_ui.py` `test_dragging_a_tab_row_reorders_and_the_row_menu_opens_ui`**:
  the right-click goes to the middle row (where every move and close item applies; on the last row
  Warp leaves out Close Tabs Below) and looks for Warp's titles and the "Default (no color)" dot.
- **New, `tests/test_umi_sidebar_warp.py`**: per-window sidebars from the CLI and with real ⌘B and
  ⌘\ presses; the 248 pt default width; the failed-command triangle (and 130, 141 not counting);
  Maximized; ⌘1–⌘9 hints (through `debug.ui.sidebar` and with a real held ⌘); search matching each
  field, the empty state, and ⌥⌘F, ⌃Tab, ⇧⌘], ⇧⌘[ and Esc pressed for real; the menu's exact order,
  hidden items, copies, color dots and toggling; Copy pull request link with a stand-in `gh`;
  renames in the row from the menu and with real ⌃⌘R and ⌃⇧⌘R presses; the menu opened with a real
  right-click.
- **New, `tests/test_umi_sidebar_warp.py`, tab groups (S-14)**: New group with tab and its name
  typed in place, Move to group, a member moved away coming back, Remove from group, pinning
  leaving a group; collapsing (hidden rows, search inside, rename opening it); the header's menu
  (order, color, New tab in group, Rename, Ungroup tabs); groups restored with the layout; and
  the Window menu's group items chosen for real with the name typed.
- **Test hooks**: `debug.ui.sidebar` (set the query, hold ⌘, type into or cancel an in-row rename;
  read the sidebar's state), `debug.ui.groups` (list a window's groups and sidebar lines, click a
  header), `debug.ui.group.menu` / `debug.ui.group.perform` (a header's right-click menu) and
  `UMI_GH_BIN` (the `gh` the pull request lookup runs).

## Sidebar review fixes (S-3, S-4, S-13, S-14; Warp parity, 2026-11-05)

- **Changed, `tests/test_umi_sidebar_warp.py` `test_the_group_header_menu`**: the exact list of
  header items now includes "Close tabs above" and "Close tabs below" (Warp's, added). Nothing it
  checked before was dropped.
- **New, `tests/test_umi_sidebar_warp.py`**: Move Tab Up/Down at group edges (left out, the CLI
  refusing, hopping over a whole group as one undo step) from the menu and with real ⌃⇧←/⌃⇧→;
  undo of a move to a new window and of a close, and reopen, bringing the group back; the group
  box's color in a screenshot; Close tabs above/below; Window ▸ Move Tab to Group ▸ and New Tab in
  Group chosen for real; ⌘ hints kept while ⇧ and ⌥ join ⌘; the pull request item at the first
  menu read; ⌥⌘F from a hidden sidebar in Files mode, Esc giving the keyboard back to the same
  pane, and ⌃Tab not filtered in Files mode; real clicks on a group header (click folds, a
  double-click only renames), on a color dot in the open row menu, and outside an in-row rename.
- **Test hooks**: `debug.ui.sidebar` also reports `key_pane`, the pane that has the keyboard.
- **New, `tests/test_umi_sidebar_warp.py` `test_an_item_clicked_in_the_row_menu_runs_ui`**: a real
  click on "Pin tab" in a real right-click menu. It failed before the fix: the menus' AppKit items
  never ran their closures, which every earlier test called directly through `debug.ui.menu.perform`.
## The file editor as Warp's (E-4, E-21 to E-24, 2026-11-05)

Warp parity for the file editor. **Requirements:** E-4 (amended: the banner's wording), E-21 to E-24
(new).

- **New, `tests/test_umi_editor_warp.py`**: the code view (terminal font and size, no wrap, the
  94-point gutter), syntax colors from the terminal's palette, marks against the last commit, ⌃G go
  to line (and ⌃G still reaching a terminal), ⌘F/⌘G/⇧⌘G driving the editor's own find with its
  toggles, replace one, Replace all with preserve case as one undo step, ⌘/ by language, ⌘S's toast
  and ⇧⌘S through the save panel, the disk-change banner's Discard this version / Overwrite, the
  header menu's items (Maximize/Minimize pane, Reload file asking first), the unsaved dot and the
  300-point chip limit. Keys are pressed as key events; results are read from files, the
  accessibility tree and the internal `debug.ui.editor`.
- No existing test changed.

### Review fixes (2026-11-05)

- **Changed, `test_cmd_f_opens_the_editors_own_find`**: after ⇧⌘G it expects the caret at the
  match's start (`[offset, 0]`) instead of the match selected. Warp moves the caret to the match's
  start (W: `code/editor/view.rs` `move_cursor_to_selected_match`), and E-22 now says so. The
  count and the match reached are checked as before.
- **Changed, `test_header_menu_has_warps_items`**: the source view's menu is Warp's code view menu
  (Maximize pane, Copy file path, Reveal in Finder); Reload file moved to the preview's menu as
  Warp's "Refresh file" (new test below). Stronger: the menu is also opened through the ⋯ button and
  a right-click on the header, and Copy file path is run and the pasteboard read back.
- **Changed, `test_header_shows_the_unsaved_dot_and_chips_show_type_icons`**: stronger. The dot is
  looked for on the chip itself (its accessibility value), not anywhere; the long name's chip must be
  wider than 200 (Warp's old limit) and at most 300; the type icon is checked in a screenshot.
- **New**: the preview's menu (Refresh file asking first, Open in editor, View Markdown preview
  back); ⌘G and ⇧⌘G from a closed bar landing on the nearest match; regex replace with a lookbehind;
  ⌘F in a Markdown preview; ⌘Z after Discard this version; Save As onto a file open in another
  pane; ⌘C, ⌘X, ⌘V, ⌘Z and ⇧⌘Z in the text; right-click in the text (Cut, Copy, Paste); a
  configured font-family; line-number colors and the current line, and the marks' colors, measured
  in screenshots; the header's title centred.
- **Fixed, `test_syntax_colors_come_from_the_terminal_palette`**: it read `highlighted` before the
  code view existed and failed with a KeyError once on mac-air-2; it now waits for the key. Same
  assertions.
## 3. Explorer and global search tests, and `debug.key` that keeps focus (`tests/test_umi_files.py`)

**What was missing.** Nothing tested the project explorer beyond the sidebar's mode, and global
search is new (SPEC S-2, Warp parity 2026-11-05).

**Change.** A new file, `tests/test_umi_files.py` (8 tests): the explorer's root, order, ignored
marks and row numbers; file-system changes without a refresh; the right-click menu's items and
what each does; revealing the active file; every new key (⌃1, ⇧⌘E, ↑↓←→, Enter, Esc, ⇧⌘>, ⇧⌘F,
⌃3, typing into the inline name field and the query); New File and Rename in the row; global
search's results, folding, opening at the line, the toggles. Keys go through `debug.key`, which
gains `focus: "none"` (keep focus where it is; an unhandled key goes to the window's first
responder), so the tests also run while the test Mac's screen is locked. Two internal methods back
them: `debug.ui.files*` (state and the right-click menu) and `debug.ui.search*` (state and the
toggles). No existing test changed.

**Requirement.** S-2 and L-9, L-10 as amended.

## 4. Explorer and global search: the review's fixes (`tests/test_umi_files.py`, 2026-11-05)

**What was missing.** A review found gaps against Warp and behaviors without a test.

**Change.** In `test_explorer_menu_has_warps_items`, the file menu's first item is now Warp's
"Open in New Pane" (it replaced "Open in Editor", the same action); the test performs it (a split
beside the terminal, no new tab). cd to Directory is now checked as Warp does it: the typed text is
replaced with `cd <folder>`, not run until Enter, and the item is off while a program runs. Insert
Path in Terminal is performed; Delete of a file open in a pane closes that pane. `test_explorer_keys`
also checks that ⇧⌘> is saved in `ui.json` and that ⌃1 pressed in the tree goes back to Tabs with
focus in the pane. New tests: `test_explorer_reveal_keeps_folders_the_user_closed`,
`test_explorer_opens_binary_files_with_their_default_app` (a fresh instance with the new test hook
`UMI_TEST_OPEN_LOG`, which writes what would go to the default app to a file),
`test_global_search_regex_is_perl_style_and_opens_at_the_match` (`a\d`, its highlight, the cursor
on the match's column, a bad regex's error), `test_global_search_outside_git_and_capped` and
`test_shift_cmd_f_leaves_a_terminal_search_open`. No assertion was weakened: the old cd check
(Enter sent with the command) asserted behavior that differed from Warp's.

**Requirement.** S-2, L-9.
- **Changed, `test_explorer_follows_the_file_system`**: a new `.rs` file's icon was the monogram
  "RS"; it is now Material Icon Theme's Rust icon, so the test checks the asset name
  (`fileicon-rust`) and that the app loads it (`icon_loaded`), which is stricter than before.
## One palette with Warp's filters and empty state; the shortcuts page (L-14 to L-17, 2026-11-05)

L-14 changed: the empty unfiltered ⌘P shows filter chips, Recent and Suggested (Warp's empty
state) instead of every action. **Requirements:** L-14 to L-17.

- **Changed, `tests/test_umi_nav.py`**: `test_command_palette_offers_cli_commands_menu_actions_and_ghostty_actions`
  lists the actions with `mode="actions"` (the palette's `actions:` filter) instead of the empty
  unfiltered palette. Its assertions are unchanged.
- **New, `tests/test_umi_palette_warp.py`**: typed prefixes filter the palette and show as its
  filter word; ⇧⌘P and ⌘O open it filtered; the unfiltered palette mixes actions, panes and files
  (at most 250); the empty palette's chips, Recent (after choosing a pane and an action) and
  Suggested; ⌘O's "Create a file named …" makes the file and opens it; Keyboard Shortcuts is the
  ⌘/ menu item and in `umi shortcuts`; ⌘P, ⇧⌘P, ⌘O and ⌘/ delivered through `debug.key` (Umi's own
  key handling) choose the filter, toggle the page, and leave it closed in the editor's source. `ui` tests press the real keys: typing `files:` and
  Backspace, ⇧⌘P then ⌘O, ↓ in the empty palette, ⌘O then Return to create a file, the palette's
  size and place (640 wide, 117 px from the window's top, at most 464 tall), ⌘/ opening, searching
  (by name and by "cmd p"), Esc and ⌘/ closing the page, and ⌘/ leaving the page closed in the
  editor's source.
- **Test hook, `debug.palette.state`** now also returns the query, filter word, selection, whether
  the empty state shows, its chips and the rows; **`debug.shortcuts_page`** returns the page's state.
- **After review, `tests/test_umi_palette_warp.py`**: new tests that an entry under Recent and
  Suggested is two rows with distinct ids; that ⌘O creates `~/…` and absolute names there; that
  the shortcuts page finds keys in any order, as words or symbols, Ghostty's bindings included,
  and never ⌘. for "cmd p"; that a file opened from the palette shows under Recent (with its
  line) and opens from there; that the empty palette indexes no files until a query; that a
  partial filter word is suggested; and `ui` tests for Tab applying it and for the arrows
  stopping at the empty palette's ends. `test_the_empty_palette_shows_filter_chips_recent_and_suggested`
  also checks the chips' icons. Hooks: rows carry `id` and `row_id`; `debug.palette.state` adds
  `files_index`, `suggestion` and `chip_icons`; `debug.shortcuts_page` takes a `query` and its
  rows carry their `shortcuts`.
- **Fixed, two `ui` tests that never passed on the test Mac**:
  `test_typing_a_prefix_filters_and_backspace_removes_the_filter_ui` looks for "Filter files:" in
  the element's value as well as its label (a static text's label reaches accessibility as its
  value). `test_cmd_slash_in_the_editor_source_leaves_the_page_closed_ui` focuses the source text
  through accessibility and asserts it has focus before pressing ⌘/: `debug.editor.focus` left
  the terminal focused there, so ⌘/ rightly opened the page. Their assertions are unchanged.

## Warp's look for the terminal itself (S-5, S-10 to S-12, 2026-11-05)

Warp parity: Warp's built-in Dark colors, selection, contrast rule, font, padding, cursor,
scrollbar, bell, block statuses and header, and the folder box. **Requirements:** S-5, S-10, S-11,
S-12.

- **New, `tests/test_umi_warp_terminal.py`**: the background `#050505` and the cursor `#19AAD8`
  (screenshots; the cursor test is a `ui` test, as it needs the window focused), the selection's color
  over the background with red text staying red, named colors raised to 4.5:1 while the same RGB gray
  isn't, Hack 13 with 15.3–15.9-point rows and a configured `font-family` replacing it, padding 16 /
  20 and none for a full-screen program (and back after it), the cursor 3 points wide, a row tall,
  with round ends, the scrollbar's thumb, the silent bell (no Dock badge), exit codes 130 and 141 and
  Ctrl-C as success, no running time in the first second, the header's `git:(branch)` (and the commit
  when detached), `(conda) (venv) user@host:`, and the folder box ending after 40 characters.
- **Changed, `tests/harness.py`**: instances no longer inherit the runner's `VIRTUAL_ENV`,
  `CONDA_DEFAULT_ENV`, `CONDA_PREFIX`, `SSH_CONNECTION`, `SSH_CLIENT` and `SSH_TTY` (`uv run` and the
  ssh session into the test Mac set them). The block header now shows them as Warp does, so panes
  inherited `(.venv) user@host:` from the test runner, which a window opened from the Dock never has.
  No assertion changed.
- **Test hook, `debug.terminal`**: `debug.blocks`' report plus the scrollbar (`scroller`) and the
  bell's effects (`bell`); `debug.terminal.action` runs a Ghostty binding action (`select_all`) on a pane. `debug.blocks` now also reports each block's `header_line` (the whole
  header; `header` stays the folder alone), the padding's four sides, the font's name and size, the
  cursor's size in points and the active screen.

### Review fixes (2026-11-05)

- **New, `tests/test_umi_warp_terminal.py`**: `test_a_branch_name_is_shown_and_never_run_with_prompt_subst`
  (a branch named `$(touch${IFS}pwned)` plus backticks, with `prompt_subst` on and off: no file
  made, the name shown as it is); `test_a_reset_on_the_alternate_screen_brings_the_padding_back`
  (RIS and the `reset` action); `test_turning_the_option_on_while_a_full_screen_program_runs_brings_the_padding_back`
  (config reload); `test_the_box_text_is_bold` (the box's folder has more heavy pixels than the same
  folder in a block's header).
- **Stricter**: `test_full_screen_programs_get_the_pane_without_padding` now requires no padding
  above the first row (was: less than a row) and less than a cell below and right.
  `test_minimum_contrast_raises_named_colors_only` adds a 256-color gray (index 59) that must keep
  its color. `test_the_scrollbar_is_warps_thumb_without_a_track` now checks what is drawn: after
  `seq 1 400` and a page up, the scroller is in the overlay style and visible, and its image shows
  one rounded `#696969` thumb 8 points wide, 2 points from the edge, with background above, below
  and right of it (it read back the class's constants before).
- **Test hook, `debug.terminal.scroller`**: writes an image of a pane's scrollbar as shown (its
  layers as on screen, mid-fade included), over the pane's background (the window's screenshot draws
  the terminal's image over the scrollbar). `debug.terminal`'s `scroller` adds `style`, `hidden`,
  `knob_proportion`, `value`, `width_pt`, `edge_inset`, `knob_rect_pt` (AppKit's knob),
  `thumb_rect_pt` and `thumb_attached`. This test found that AppKit drew the old thumb clipped to
  its own 6-point knob.
## Warp's panes, right-click menu, synchronized input and zoom (L-19, L-31–L-33, 2026-11-05)

L-19 gained Warp's 190-point minimum pane size: a dragged divider stops before a pane gets smaller,
and a keyboard resize or `pane resize` that would is refused. **Requirement:** L-19.

- **Changed, `tests/test_umi_panes_ui.py`**: three drag tests used shares that put a pane at 10–20%
  of the suite's window (its panes' area is about 928 points wide, so 20% is 186 points). Their
  numbers now keep every pane above 190 points; what each checks is unchanged:
  - `test_a_dragged_divider_shares_each_side_equally_and_double_click_equalizes_its_row`: the b|c
    divider goes to 78% of the row (50/28/22) instead of 80% (50/30/20);
  - `test_panes_sized_by_hand_keep_their_size_and_the_others_share`: the first divider goes to 28%
    and the last to 78% (28/25/25/22 instead of 40/25/25/10). The row then never holds five panes
    (five can't all be 190 points wide there): c is closed before the split that tests a placed
    divider surviving a split, so the drag after it still shows a keeping its share while b and e
    share the stretch; the double-click and the last drag use four panes (25/26/26/23 instead of
    20/23.3/23.3/23.3/10);
  - `test_a_dragged_middle_divider_shares_both_sides`: the middle divider goes to 56% (28/28/22/22)
    instead of 75% (37.5/37.5/12.5/12.5).
- **New, `tests/test_umi_warp_panes.py`**: the minimum (a drag stops at 190 points on either side; a
  keyboard resize below it is refused and says so), the divider's color and 9-point grab area, the
  right-click menu's items and order, and Maximize/Minimize, Close and Split from it (L-31), ⌥⌘I,
  ⌥⇧⌘I and the all-tabs toggle typing into the synced panes only, with the sidebar's mark and the
  inspector's new key (L-32), and ⌘= ⌘- ⌘0 and ⌥⇧> ⌥⇧< with the terminal's and the sidebar's sizes
  and the saved level (L-33). The divider grab area, the real right-click, and the key tests are
  `ui` tests.

### Review follow-ups (L-19, L-31–L-33, 2026-11-05)

New tests in `tests/test_umi_warp_panes.py`; no existing test changed. **Requirements:** L-19, L-31,
L-32, L-33.

- L-32: ⌥⌘I in a one-tab window leaves a tab opened later out; a paste into a synced pane reaches
  every pane, and a paste that needs confirming asks once, in the pane pasted into (cancelled, it
  goes nowhere); file and web panes in synced tabs get no keys; the sidebar row's link mark comes
  and goes (`ui`).
- L-31: Paste disabled with an empty clipboard; with text selected the menu starts with Copy and
  has no Paste or Clear, and Copy copies; in less's full-screen view there's no Paste, Clear or
  Copy; Close Pane asks first when a program runs, and Cancel keeps the pane.
- L-19: the minimum for a divider between rows; a drag stops when a pane beyond the divider's
  neighbours reaches it; a pane already below it may grow but not shrink.
- L-33: the zoom level and font size survive a restart; the editor's text and the Markdown
  preview scale with the zoom; sidebar rows drag and take clicks at 125% (`ui`).
- New internal methods for them: `debug.ui.clipboard.confirmation` (a pane's pending paste
  confirmation, answered as its buttons do), `debug.ui.sheet` (a window's dialog, cancelled as its
  Cancel button does), and `debug.ui.zoom` with `window` (the editor's text sizes and the preview's
  page zoom there).
## The Markdown preview as Warp's (MD-1 to MD-5, E-2; Warp parity, 2026-11-05)

New requirements MD-1 to MD-5 and E-2's Rendered / Raw and ⌘E. No existing test changed.

- **New, `tests/test_markdown_warp.py`**: the look (computed styles: font, sizes, weights, colors,
  borders, padding, full width; bare URLs linked), code blocks (labels, highlighting, Copy, Run in
  terminal), Mermaid (drawn, Raw / Rendered, Open full screen, Esc, a broken diagram), find (Edit ▸
  Find's items through the responder chain, Return / ⇧Return, Aa, `.*`, No matches, Esc), ⌘E's menu
  action in a file pane and in a terminal, and the right-click menu's items and actions. UI tests
  press the real keys (⌘F, ⌘G, ⇧⌘G, Return, Esc, ⌘E), check the Rendered / Raw buttons and open
  the right-click menu through the accessibility tree.
- **Test hook, `debug.ui.markdown`**: reads the preview's state and computed styles, clicks its
  buttons, types into find, performs menu actions through the responder chain, and lists or chooses
  the right-click menu's items. Once a test has used it, Copy and Copy file path write to a private
  pasteboard (`action=pasteboard` reads it), never the test Mac's clipboard.

### Review fixes (2026-11-05)

- `test_a_broken_diagram_shows_its_source_and_error` also checks that the error is drawn (its box
  is taller than its padding); before, it read only the message the script stored, which the page
  never showed.
- `test_code_blocks_are_highlighted_and_copy_or_run` checks Warp's highlight colors from its base16
  theme (functions blue, strings green; comments, numbers and parameters in the text color), so the
  Python block gained a comment and a number and the expected copied text changed with it.
- New, `test_on_a_light_background_the_preview_uses_warps_light_theme`: with a light background the
  preview's text, links and done checkboxes use Warp's Light theme (accent `#00c2ff`).
- `test_mermaid_diagrams_render_and_open_larger` also checks the footer's layout (Raw / Rendered and
  Open full screen beside the label, Copy at the right) and that Raw hides Open full screen, as in
  Warp.
- Written checks: new **MD-1** check in `CHECKS.md`, with a `run_checks.py` setup that screenshots a
  test document on the default dark background and on a light one; E-2's check now names the
  Rendered / Raw control.
- `test_the_preview_looks_like_warps_markdown_view` checks that the page has Roboto's four bundled
  faces and loaded one. Before, it used `document.fonts.check`, which is true when no face matches,
  so a build without the fonts passed.
- New, `test_the_text_follows_the_terminals_font_size`: with `font-size = 15` the preview's text,
  headings and code scale to 15 px, as Warp's Markdown follows its terminal font size.
- New Swift tests, `UmiMarkdownLinksTests`: bare URLs with trailing punctuation, unbalanced and
  balanced brackets, `www.`, escaping, and URLs in links, inline code and fenced blocks left alone;
  fenced blocks' language labels and kinds.
## Added: launch configurations (L-21, 2026-11-05)

- **New, `tests/test_umi_layouts.py`**: its own instance with a temporary `XDG_CONFIG_HOME`, so the
  user's launch configurations are never read or written. `umi layout save` writes Warp's format and
  `layout open` brings the windows, tabs, names, colors, folders, split direction and focused pane
  back; a hand-written file (two windows, a three-pane vertical split, pane and tab commands, Warp's
  `cyan`) opens as written and its commands run; a broken file is listed with its line and opens
  nothing; the File menu items and ⌃⌘L; the palette lists configurations and opens the chosen one;
  the row menu's "Save as New Config" sits where Warp has it, writes `my_tab_config.yaml` (then
  `_1`) and opens it in the editor; ⌃⌘L through the app's key monitor from a terminal, the editor
  and a palette; real key presses (UI, need an unlocked screen): ⌃⌘L then Return, and File ▸ Save New Launch
  Configuration… through its dialog, including the duplicate-name message.
- **New, `tests/test_umi_layouts.py`**: `test_a_file_with_several_documents_holds_several_configurations`
  (each `---` document is a configuration, listed and opened by name; the file's name is then
  ambiguous and says so; a broken second document is reported with its line in the file).
- **New, `tests/test_umi_layouts.py`**: `test_saved_colors_use_warps_names_where_warp_has_them`
  (purple, teal, graphite and pink tabs are saved as `magenta`, `cyan`, `white` and `pink`, and open
  with their Umi colors again).
- **New, `tests/test_umi_layouts.py`**: `test_command_palette_finds_launch_configurations_by_name`
  (⌘P's list finds a configuration by name and opens it; unreadable files stay out of it).
- **Changed, `tests/test_umi_layouts.py`**: `test_palette_lists_configurations_and_opens_the_chosen_one`
  now asserts what the query returns: a query that matches nothing empties the list, and `alp`
  ranks Alpha first (it sent the query without checking the result). The query also matches the
  file paths shown under the entries, so a weaker match can stay below Alpha.
- **Changed, `tests/test_umi_layouts.py`**: `test_save_new_launch_configuration_from_the_file_menu`
  (UI, real keys) now also checks that the dialog shown again after a duplicate name has the name in
  its focused field, that Cancel keeps the file, and that "Open YAML File" opens the saved file in
  the editor. AXPress on that button reports a failure because the sheet is gone when it returns;
  the test checks the editor instead of the code.
- **New, `tests/test_umi_layouts.py`**: `test_file_menu_lists_each_launch_configuration_by_name`
  (File ▸ Launch Configurations lists each readable configuration by name before the two items,
  choosing one opens it, and the list follows the folder).
- **New, `tests/test_umi_layouts.py`**: `test_save_captures_every_window_merges_rows_and_leaves_out_file_panes`
  (two windows saved and read back as a structure: `active_window_index` from the current window,
  `active_tab_index` counted among the saved tabs, a row nested in a row saved as one row, file
  panes left out, a tab of only a file pane left out and its "Save as New Config" disabled) and
  `test_layout_open_no_focus_keeps_the_users_focus_and_front_app` (L-8 for `layout open --no-focus`).
## Agent status, inbox, toasts and the update note (S-3, AG-24, I-4, L-9; Warp parity, 2026-11-05)

New tests only; no existing test changed. **Requirements:** S-3 (amended), AG-24 (new), I-4 and L-9
(amended).

- **New, `tests/test_umi_agent_events.py`**: Warp's status badges on the sidebar row
  (`debug.ui.rows` reports `badge`); a finish seen from another pane of its tab leaves no mark; a
  new turn clears the mark (`harness`, a fake Claude); OSC 9 and 777 from a pane running an agent
  are dropped; the inbox's items, filters and keys; toasts (8 s, two at most, read by a look,
  dismissed by ⌃⌘U and by opening the inbox); the note after an update, once; no note after a
  failed update; one `ui` test presses ⇧⌘U, ↓, Return, Shift-Tab, Escape and ⌃⌘U for real.
- **Test hooks**: `debug.ui.inbox` (what the inbox and toasts show), `debug.ui.inbox.toggle`,
  `debug.ui.inbox.key` (the inbox's own key handler), `debug.ui.inbox.dismiss` (⌃⌘U's action) and
  `debug.ui.inbox.fill` (finishes from panes that don't exist, to check the 100 limit). The
  update-note tests write `updates/attempt.json` in the instance's state directory, as the run
  before an update does.

### After review (2026-11-05)

- **Changed, `test_a_finish_seen_from_another_pane_of_its_tab_leaves_no_mark`**: it set the finished
  mark through `debug.ui.attention.set`, so it never ran the seen rule in the engine and passed only
  because looking cleared every finished mark in the looked-at tab (a bug). It now runs a fake
  Claude turn in a split beside the focused pane and checks the engine leaves no mark and a read
  item. Stronger, not weaker.
- **New**: `test_a_sibling_that_finished_out_of_sight_keeps_its_mark` (the negative case: switching
  to a sibling pane and an unrelated attention change leave the mark; a look at its own pane clears
  it).
- **New**: `test_no_note_after_a_rollback` (an `attempt.json` going down shows no note).
- **Extended, `tests/test_umi_extra.py`**: `test_not_now_activity_install_now_and_rollback` serves a
  feed with release notes and checks the relaunched 999.0.0 shows them in the note (the real path:
  feed, staged `release.json`, `attempt.json`), and that the rollback to 0.0.1 shows no note. Added
  assertions only.
- **New**: `test_the_inbox_belongs_to_one_window_and_goes_with_it` (⇧⌘U's action in a second window
  opens it there; closing that window closes it; toasts show again) and
  `test_a_click_outside_the_inbox_closes_it_and_typing_reaches_the_pane_ui` (real clicks inside and
  outside the panel, then real typing). `debug.ui.inbox.toggle` now takes `window`.
- **Extended, `test_the_agents_mark_wears_warps_status_badge`**: a session still waiting after the
  user looked (`needs_input`, no mark) keeps the "needs you" badge.
- **New**: `test_inbox_items_use_warps_words_and_read_rule` (Warp's titles and messages for each
  category, the agent's own error and question, cancelled, Codex; a request in a sibling pane of
  the looked-at tab is read and doesn't toast). `debug.ui.attention.set` takes `detail` (what the
  engine passes: the error or the question).
- **Extended, `test_an_agents_own_desktop_notifications_are_dropped`**: once the session is stopped,
  or its interface no longer runs in the terminal, OSC 9 is let through. `debug.ui.inbox` reports
  `passed_notifications`, so the test now checks each let-through notification arrived, where it
  only checked that nothing was dropped (stronger).
- **Changed, `test_unread_events_toast_in_the_active_window`**: the "no toasts while the app isn't
  active" check ran only when the test app happened to be in the background. A new hook,
  `debug.ui.inbox.assume_inactive`, makes the app count as inactive, so the check always runs
  (stronger).

## Merging the Warp branches (warp/parity, 2026-11-05)

Two tests changed because two branches' behaviours met; what each checks is unchanged.

- **Changed, `tests/test_umi_warp_panes.py` `test_the_zoom_scales_the_editor_and_the_markdown_preview`**:
  the editor's text now uses the terminal's font (E-21) instead of a fixed 12.5 pt, so the test reads
  the size at 100% and expects 110% of it after ⌘=, instead of 12.5 → 13.75. **Requirements:** L-33.
- **Changed, `tests/test_umi_editor_warp.py` `test_cmd_f_in_a_preview_finds_in_the_source`**: it
  opens a JSON file instead of a Markdown file. A rendered Markdown file now has its own find bar
  (MD-4), which ⌘F opens; JSON and CSV previews still switch to the source. **Requirements:** E-22.
- **Changed, `tests/test_umi_layouts.py` `test_tab_menu_save_as_new_config_saves_the_tab_and_opens_the_file`**:
  the item before "Save as New Config" is "Close tab", not "Close Tabs Below": the tab is its
  window's only tab, and Warp's menu (S-4) leaves out close items that can't apply. It still checks
  the item comes after the close items and before the colors. **Requirements:** L-21, S-4.
- **Changed, `tests/test_umi_sidebar_warp.py` `test_the_row_menu_has_warps_labels_in_warps_order`**:
  the expected list gains "Save as New Config" before "Tab Color" (L-21 put it there).
  **Requirements:** S-4.
- **Changed, `tests/test_umi_blocks.py` `test_the_folder_is_shortened_again_when_the_pane_narrows`**:
  narrows the pane in 5-column steps until the 190-point minimum (L-19) refuses one, instead of
  four 10-column steps the minimum refused. It still requires the pane at least 10 columns
  narrower and the folder shortened to fit. **Requirements:** S-10.
- **Changed, `tests/test_umi_palette_warp.py` (the ⌘/ shortcuts page test)**: in a Python file's
  source ⌘/ is the editor's Toggle Comment, an Umi item, so the key counts as handled; the test now
  checks the line was commented, and still that the page stayed closed. **Requirements:** L-17, E-23.
- **Changed, `tests/test_umi_layouts.py` `test_palette_lists_configurations_and_opens_the_chosen_one`
  and `test_command_palette_finds_launch_configurations_by_name`**: the full list is read with the
  `actions` mode, because the empty unfiltered palette is Warp's empty state (L-14). Assertions
  unchanged. **Requirements:** L-21.

## Testing warp/parity (2026-11-06)

- **Changed, `conftest.py` fixture `ui`**: it checks for a locked screen before every UI test
  instead of once per run (the Accessibility check stays once per run, in the new `ui_session`). On
  mac-air-2 the screen locked partway through a full run, and the next UI test walked the menu bar
  for over 30 minutes, which a locked screen makes endless (see `screen_locked`). UI tests that
  start after a lock are now skipped, with the same reason as before. No assertion changed.
- **Changed, `tests/test_umi_web.py` `test_cmd_click_on_a_link_opens_a_web_pane_ui`**: it now takes
  the `ui` fixture, as the other UI tests that drive their own instance do, so a locked screen skips
  it. It built its own `UI` without that check and, with the screen locked, searched the
  accessibility tree forever. No assertion changed. **Requirements:** E-12.
- **Changed, `tests/test_umi_warp_terminal.py` `test_full_screen_programs_get_the_pane_without_padding`**:
  after the program ends it waits up to 5 s for the columns and rows to be what they were, instead
  of reading them once at the moment the padding comes back. The terminal takes its new size on its
  own thread, so on mac-air-2 the read saw the full-screen column count (72 for 68). The required
  size is unchanged. **Requirements:** S-5, S-12.
- **Changed, `tests/test_markdown_warp.py` `test_rendered_and_raw_toggle_with_cmd_e`**: it no
  longer looks for a menu item with ⌘E. Ghostty's ⌘E (`search_selection`) is a performable
  binding, and Ghostty leaves performable bindings off its menu items (its own test in
  `src/config/CApi.zig` checks this), so no item ever had the key. The test now selects text in the
  terminal, presses ⌘E there and requires the terminal's search to open with the file still
  rendered: what SPEC E-2 asks of ⌘E in a terminal. The Rendered / Raw checks are unchanged.
  **Requirements:** E-2.
- **Added, `tests/test_markdown_warp.py` `test_cmd_e_in_a_source_only_file_uses_the_selection_for_find`**:
  in a file with only a source view, ⌘E puts the selected text in the find query and the file
  stays in source. **Requirements:** E-2.
- **Changed, `tests/test_markdown_warp.py` `test_right_click_opens_warps_menu`**: it reads the
  items drawn in their own rows. The accessibility tree of the preview's menu also lists an
  untitled, disabled element at the first item's position that the menu doesn't draw and that is
  not one of its items (checked on mac-air-2: the NSMenu holds the 8 expected items, and a
  screenshot of a real right-click shows only those). The expected list, separator included, is
  unchanged. **Requirements:** MD-5.
- **Fixed, `app/macos/UmiTests/verify_ui_paths.py` E-2 check**: before ⇧⌘M it focused the
  terminal pane, but `edit FILE --pane P` opens the file in a pane of its own beside P, so the
  focused pane had no document and Toggle Markdown Preview was rightly disabled (it failed on main
  too). It now focuses the file's pane with `debug.editor.focus`, as the E-3 and E-5 checks do.
  The check is unchanged. **Requirements:** E-2.
- **Fixed, `tests/test_umi_editor_warp.py` `test_cmd_f_in_a_terminal_still_searches_the_terminal`**:
  it empties the shared find pasteboard first and puts its text back afterwards. Ghostty's search
  starts with the pasteboard's text as its query, and with a query its first Esc only moves the
  keyboard back to the terminal (a second Esc closes it), so the test failed whenever an earlier
  test (the ⌘E ones) had left text there. Checked by hand on mac-air-2: with an empty query one
  Esc closes the search. Its assertions are unchanged. **Requirements:** E-22.
- **Added, `tests/test_umi_editor_warp.py` `test_a_file_with_long_lines_opens_at_its_left_edge_beside_the_gutter`**:
  a file with a line longer than the pane opens with its text starting right of the 94-point
  gutter. It opened scrolled 94 points sideways, its first characters under the line numbers
  (found walking the branch on mac-air-2). **Requirements:** E-21.
- **Added, `tests/test_umi_warp_panes.py` `test_the_pane_menu_shows_each_items_key_ui`**: the
  terminal's right-click menu shows each item's key, ⌘V for Paste, ⌘K for Clear and ⌘C for Copy
  included. Those three showed no key: Ghostty gives its performable bindings no menu key (found
  walking the branch on mac-air-2). **Requirements:** L-31.
- **Changed, `tests/test_markdown_warp.py` `test_rendered_and_raw_toggle_with_cmd_e`**: it no
  longer gives the pane keyboard focus again between the two ⌘E presses. Switching views left the
  keyboard with the window, so the second ⌘E did nothing for a person pressing it twice (found
  walking the branch on mac-air-2); the test's extra focus hid that. Stricter than before.
  **Requirements:** E-2.

## Design step 1: orchestration out (2026-11-07)

design/plan.md step 1 removes Umi-run agent sessions (design/spec-cleanup.md): AG-1 to AG-17 and
AG-20 to AG-24 left SPEC.md, and AG-18, AG-19, I-2, I-4, L-9, L-12, L-14, S-3 and R-3 to R-7 were
reworded around agents in panes. Tests of removed features went with them; tests that still apply
were moved onto the new surface (`<cli> hook`, `plugins`, each pane's `attributes`). No test was
weakened.

**Removed with their features.**
- `tests/test_sessions.py`, `tests/test_sessions_real.py`, `tests/test_chaos.py`,
  `tests/mcp_codeword.py`: headless sessions and the `agent` commands (AG-1 to AG-17, AG-20 to AG-23),
  their real-agent runs and their chaos runs.
- `tests/test_live.py`: the read-only view, Take Over, `agent hide`, messages to live sessions
  (AG-2, AG-5 to AG-9). Its AG-18/AG-19 tests were rewritten in `tests/test_agent_panes.py` (below).
- `tests/test_review_agents.py` → `tests/test_review_regressions.py`: the 34 review regressions about
  sessions, Take Over, parking, steering and resuming went; the 10 about shortcuts, the palette,
  reopening and the screen lock stay unchanged. Changed: "an update now counts work in a live
  interface" now types a fake Claude into a pane and checks the refusal names "1 agent turn"; "a
  session waiting for the user stays reachable after its pane closes" became "a pane waiting for the
  user stops counting once it closes" (the Dock count goes back down; `jump` no longer reaches a
  pane that is gone); "many windows opened while the screen is locked" checks that a pane's shell
  still answers instead of an agent session. The plugin-status regressions moved to
  `test_agent_panes.py`, calling `plugins` instead of `agent plugins`.
- `tests/test_robustness.py`: the AG-21 to AG-23 tests (orphans of sessions, crash recovery of
  sessions, partial log lines, long-run sessions, an agent of one instance reaching another,
  stale agent environments). R-3, R-4, R-5 and R-7 tests stay; added "agents report with spaces
  and long state dirs" (R-4 for `hook`).
- `tests/test_install.py`: `test_upgrading_keeps_sessions` (AG-22). Agents coming back after an
  update are checked by `test_umi_extra.py`'s quiet-moment install and by
  `test_agent_panes.py`'s relaunch tests.
- `tests/test_umi_agent_events.py` → `tests/test_umi_attention.py`: Warp's status badges, the
  inbox and the toasts (AG-24) went; Warp's tab-wide seen rule was replaced by per-pane tests (a
  finish seen from another pane of its tab keeps its mark, a finish in the pane looked at leaves
  none, a new turn clears it, a question keeps it, `jump` order). The update-note tests stay, read
  through `debug.ui.update_note` instead of `debug.ui.inbox`. The desktop-notification test moved
  to `test_agent_panes.py` and drives the pane through `hook` instead of the engine stand-in.
- `tests/test_layout.py`: `test_agent_shortcuts_are_menu_items` (⌃⌘J is in the main list);
  `SHORTCUTS` loses ⌃⌘O and ⌃⌘W (removed) and gains ⌃⌘U (the update note).
- `tests/test_umi_extra.py`: `test_an_agent_launched_into_a_new_window_gets_its_command` (`umi
  claude --new-window`, removed). The quiet-moment install test types its Claude with the new
  helpers and checks the agent comes back by its process's arguments and `RECALL`, instead of
  `agent info`/transcripts.
- `app/macos/UmiTests/verify_agent_panes.py`: the read-only view and Take Over without the
  accessibility tree.

**Changed to the new behaviour (design wins over the old spec).**
- `test_umi_panes_ui.py::test_looking_at_the_pane_clears_the_mark`: a pane whose agent needs input
  keeps its mark when looked at (the mark follows `agent.status=needs_input`, design/attention-ui.md);
  before, looking cleared it. A row whose agent has no title shows "working" (there is no
  "starting" status any more).
- `test_umi_palette_warp.py`: no `conversations:` filter or chip (Umi has no agent conversations
  of its own).
- `test_umi_nav.py`: the menu title is "Jump to Next Pane Needing You"; the jump to "a session no
  pane shows" went.
- `test_quiet_updates.py`: the session-based quiet tests became pane-based ones with typed fake
  agents: an agent at work or waiting is not quiet (turn, background work, permission prompt,
  failed turn), an idle agent with nothing typed is quiet (drafts, Esc/Ctrl-U/Ctrl-C, recalled
  prompts, a queued prompt and a newer draft, Shift-Return, an inferred interrupt), and the job and
  hook tests use the helpers. "A message waiting to be delivered" and "processes a headless agent
  left behind" went with headless sessions.
- `test_install.py::test_doctor`: `doctor` reports the CLI on PATH and the hook plugins, not
  `claude`/`codex`/`git` (design/spec-cleanup.md).
- Stand-ins: `debug.attention.set` and `debug.ui.attention.set` now write a pane's agent the way
  its hooks would (`mark` maps to needs_input, or finished-and-unseen, or seen); tests that used
  them keep their checks.

**Added.** `tests/test_agent_panes.py` (AG-18, AG-19, S-3, R-3): an agent typed in a pane writes
`agent.*` on it (both agents); status changes are `pane.changed` events; `agent.done` from the
reply's last line; the hooks are silent outside Umi; hooks from a plugin folder with spaces;
`claude -p` isn't the pane's agent; `plugins`; truthful status for both agents, a failed turn, an
agent killed without SessionEnd; a Claude typed with flags comes back after a quit with them on
its conversation; a Codex comes back after every process is killed while an exited one doesn't;
the agents' OSC 9/777 notifications are dropped; the removed `agent` commands fail and say what
to do. Swift: `UmiQuietTests` lost the session cases and gained agent-in-pane quiet rules, restart
command lines and the done check.

### After review (2026-11-07)

- `checks/umi_verdicts.py`: the AG-5 verdict (the read-only view) is gone with AG-5.
- Swift: `UmiJumpTests` is new (L-12: needs input first, then unseen panes whose agent finished or
  failed; a failed pane drops out once looked at). `UmiQuietTests`' one-off check gained
  `codex -m o3 exec …` and `codex --model=o3 e …` (one-offs) and `codex -m o3 "fix the bug"` (not).

## Design step 2: pane data (2026-11-08)

**Added.** `tests/test_pane_data.py` (D-1 to D-8): `pane|tab|window set/unset/get`, from inside a
pane and outside; each change an event, a repeated value none; attributes back after a restart;
read-only keys and bad names fail and change nothing; `role` moves between panes; the Docs tab is
the tab with `role=docs` (Markdown from outside goes there); `kind`, `cwd`, `branch`, `command`,
`focused`, `hidden`, `in_drawer`, `idle_for`, `visible_count`; `seen_at`, `changed_at`,
`status_since` and the pane's `indicator`; `agent.*` written with `pane set` (needs `agent.kind`,
counts for the Dock badge, overwritten by the next hook, `unset agent.kind` takes the agent away);
events carry `at` and `cause` (cli with command and calling pane, hook, key, palette, `UMI_CAUSE`);
`log` with `--since`/`--until`/`--filter`/`--pane`, `pane.moved`'s `from`/`to`, a bad time failing;
`events --since` replaying then streaming; the log kept across a restart; the focus log's
stretches, the open one, the idle limit and the screen lock. Swift: `UmiPaneDataTests` (attribute
names, read-only keys, the cause a request is recorded with, a scope outranking the request).

**Changed.**
- `test_agent_panes.py::test_agent_status_changes_are_pane_changed_events`: every changed `agent.*`
  key is now a `pane.changed` event (CLI.md, "Events and logs"), so the test picks the ones with key
  `agent.status` and checks the same three changes as before; it also checks their cause is `hook`.
- `test_agent_panes.py::test_the_plugins_hooks_are_silent_outside_umi` (its before/after comparison): `ls`'s
  `attributes` now hold Umi's own keys too, and some change by themselves (`idle_for`, `seen_at`), so
  the comparison covers what can be written on a pane (the user's attributes and `agent.*`), which
  is what a hook could change.

## Design step 3: queries, lists and slots (2026-11-08)

**Added.** `tests/test_queries.py` (Q-1 to Q-8, L-4, L-12): queries in `ls --where` (comparisons,
numbers, `and` over `or`, `not`, bare keys, `sort`, `limit`, `then`, quoted values, durations and
times), each match with its tab and window, an empty result; `pane set`/`unset`/`close` acting on
every match and one-pane commands on the first; tab and window selectors that are queries; bad
queries failing with the position, a query matching nothing, an unknown list; a key never read as
an id prefix by `pane get`/`unset` (step 2's review); `UMI_PANE` in a pane's shell and no
`UMI_PANE_ID`; `jump` gone; Umi's lists in `list ls`/`list show`; `go`, `go --next` walking and
wrapping, `go --back`, an empty list moving nothing; ⌃⌘J/⌃⌘K (`debug.key`) as `go --next jump` and
`go --back`, caused by the key; in an instance with its own config: lists and slots redefined, a
bad line reported, `slot ls`, the Dock badge from `slot.badge`, `sidebar.line2` as a template,
`landing` (`debug.landing`, caused by `config`), Ghostty reporting no error for Umi's lines;
`done-check` as a slot; a `key.…` binding running its command with the key as cause, listed by
`shortcuts` with `source: config`, and overriding ⌃⌘J; palette commands from a `command."…"` line and
from the commands folder (`command ls`, `command run` with `UMI_PANE`/`UMI_TAB`/`UMI_WINDOW`/
`UMI_CAUSE`/`UMI_CLI`, a failing one exiting 1, the ⌘P entry); `wait --attr`. Swift: `UmiQueryTests`
(parsing and positions of errors, comparisons, bare keys, durations and times, sort/limit/then,
what reads as a query, the default `jump`, `needs-you` and `tab.summary` lists, templates, the
`done-check` default, a key being the cause only while it is dispatched).

**Added after review.** `test_queries.py::test_pane_move_moves_every_match_in_order` (a query moves
every match, in its order, to a tab and to one new tab) and
`::test_tab_close_closes_every_tab_holding_a_match` (design/cli.md choice 3 and "Selectors": the
build moved and closed only the first). `test_the_config_redefines_lists_and_slots` also checks
that a list naming a missing list or itself shows an error in `list ls` and fails `ls --where`
(it was an empty list, silently). Swift `UmiQueryTests/aKeyLingeringInCurrentEventIsNotTheCause`:
a key taken off the queue and left in `NSApp.currentEvent` (under a second old, so the old rule
would have named it the cause) is not the cause of what Umi does next.

**Removed.** Swift `UmiJumpTests`: `UmiAttention.jumpOrder` is gone; the same three cases (needs
input first then unseen, oldest first; a seen failed pane drops out; seen and working panes are no
targets) are in `UmiQueryTests` against the default `jump` list.

**Changed.**
- `test_umi_nav.py::test_jump_goes_to_sessions_needing_you_then_back`,
  `test_umi_nav.py::test_selecting_a_tab_never_moves_it` (its ⌃⌘J part),
  `test_umi_attention.py::test_jump_goes_to_the_pane_that_needs_you_then_the_unseen_one` and
  `test_review_regressions.py::test_a_pane_waiting_for_the_user_stops_counting_once_it_closes`:
  `jump` and `jump back` became `go --next jump` and `go --back` (design/cli.md removes `jump`); the
  same panes in the same order. The empty case now checks exit 1 and "nothing in jump" (was a
  non-zero exit and "needs you").
- `harness.py` (`Instance.hook`), `test_pane_data.py` (`in_pane`), `test_robustness.py` and
  `test_agent_panes.py::test_the_plugins_hooks_are_silent_outside_umi`: a pane's identity is
  `UMI_PANE` now (`UMI_PANE_ID` is retired); same checks.
- `test_agent_panes.py::test_a_plugin_installed_from_another_copy_of_umi_is_not_current` and
  `::test_a_disabled_claude_plugin_is_not_current`: the installed version they fake is the bundled
  one, now 1.2.0 (the hook script reads `UMI_PANE`), so they still test "same version, but another
  copy" and "same version, but disabled" rather than an old version.
- `test_layout.py::test_cli_inside_panes_defaults_to_this_pane`, `test_editor.py::test_edit_targets_the_calling_pane_and_never_falls_back`,
  `test_editor.py::test_a_file_opened_from_a_pane_goes_beside_that_pane` and two checks in
  `test_robustness.py` typed the bare `<cli>` in a pane, which runs whichever copy is first on the
  pane's PATH: on mac-air-2 the installed 0.6.3, which reads the retired `UMI_PANE_ID`, so the build
  under test was never the one checked. They now type the build's own CLI by its path; the P-4 test
  first checks that `<cli>` is on PATH in the pane, which it did implicitly before.

## Design step 4: hidden panes and the pane strip (2026-11-08)

Stacks (M-7), E-9's "three panes, then a new tab" rule, the Docs tab as a stack (E-10), the header
grips and Ghostty's hover handle left with this step (design/spec-cleanup.md); hidden panes, the
three-pane limit, the pane strip and ⌘[ ⌘] over every pane came in (SPEC H-1 to H-8).

**Added.** `test_hidden_panes.py`: a fourth pane hides one (`hid`; never the arriving or focused
pane; the hidden pane keeps running; `strip` and `ls` order); pinned panes are never hidden to make
room (and an all-pinned tab shows more); every way a pane arrives makes room (a file, a move, a
reopen, focusing a hidden pane, a lower `visible_limit`); `pane hide`/`show` (events, `changed_at`,
the last pane on show refused, `--focus`, queries); `--until` with a query and a duration
(`by_condition`, cause `config`, `unseen`, `pane until`); closing the last pane on show brings a
hidden one in; ⌘[ ⌘] walking with ⌘ held (`debug.key` with `hold`, then `debug.release`) and through
the menu; undo of a move that made room; hidden panes and conditions after a restart; launch
configurations saving `is_hidden` and opening the rest hidden. UI (unlocked screen): the strip's
chips (order, values, place above the panes, click to bring in, no grab handle), real ⌘] held and
released, a hidden pane's chip dragged onto a pane's edge.

**Removed** with stacks: `test_umi_stacks.py` (all four tests: dropping on a pane's middle, undoing a
stack, files stacking, ⌘[ ⌘] cycling a stack and its strip). The "Stack here" zone is gone; the Swift
test `TerminalSplitDropZoneTests/centerSelectsLeft`, which failed on main since stacks added the
centre zone, passes again unchanged.

**Changed.**
- `test_editor.py::test_files_open_in_panes_beside_the_caller_three_to_a_tab` became
  `…_and_a_full_tab_makes_room`: the third file now stays in the caller's tab and one earlier file is
  hidden (`hid`), instead of a new tab (E-9 as rewritten). The rest is kept: order to the right of the
  caller, a file already open shown where it is (now brought in when hidden), focus kept, modes;
  `editor ls` documents now carry `hidden`.
- `test_umi_panes_ui.py::test_markdown_opens_in_one_docs_tab_most_recent_first` became
  `…_in_the_docs_tab_at_its_right_end_three_on_show`: the Docs tab is ordinary (E-10 as rewritten):
  each new document at its right end, three on show, the rest hidden; one opened again is brought in.
  Its last check (a text file goes by folder, not to the Docs tab) put the text file in a folder the
  Docs tab's own panes started in, so the Docs tab was the closest tab and the check failed on main
  too (steps 1 to 3 list it as failing there); the text file now gets a folder of its own, which is
  what that check means.
- `test_umi_panes_ui.py::test_dragging_a_pane_to_the_top_or_bottom_centre_moves_it_between_tabs_ui`:
  drags the pane's strip chip instead of Ghostty's hover handle, which is gone (H-8); same targets.
- `test_umi_editor_warp.py::test_header_shows_the_unsaved_dot_and_chips_show_type_icons`: the chips
  are in the pane strip (no stacking needed); a chip's accessibility value now says where its pane is,
  so the dirty check reads ", unsaved changes" at its end instead of the whole value.
- `test_umi_web.py::test_a_web_pane_moves_and_stacks_without_reloading` became
  `…_moves_hides_and_comes_back_without_reloading`: dropped on a pane's edge, hidden and shown instead
  of stacked; still checks the page doesn't load again.
- `test_pane_data.py::test_the_docs_tab_is_the_tab_with_role_docs`: the tab's `docs` field is gone
  (design/cli.md, "Removed"); it checks `role=docs` and its single holder instead.

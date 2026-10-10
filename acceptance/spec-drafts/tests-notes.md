# Notes: the acceptance tests for agent sessions (AG)

Written for spec-drafts/ag.md (AG-1 to AG-23) and ag-cli.md, against the build at
`app/macos/build/ReleaseLocal/Tern.app`. Run: `uv run pytest --target targets/tern.json tests/test_sessions.py
tests/test_live.py -m "not ui"`; real agents: `ACCEPTANCE_REAL=1 uv run pytest --target targets/tern.json -m real
tests/test_sessions_real.py`.

**Read first: section 1 (app bugs), item 1.1 changed the user's real `~/.codex/config.toml`.** The lead
fixed 1.1 to 1.10 (not 1.11's `ls` item); section 6 says what still fails on the fixed build.

## 1. What looks wrong in the app

Each item: the failing test(s), what they saw, and where the cause probably is. None is marked xfail.

### 1.1 `CODEX_HOME` is thrown away at launch, so `agent plugins` works on the user's real `~/.codex` (serious)

- `TernEnvironment.scrubInherited()` (TernPaths.swift) unsets every `CODEX_*` variable of the app, which
  includes `CODEX_HOME`. `TernAgentPlugins.commandEnvironment()` then can't see it, and `status`, `install`
  and `remove` read and write `~/.codex`, whatever the app was given. (`CLAUDE_CONFIG_DIR` survives: only
  `CLAUDE_CODE_*` is scrubbed.) Panes don't get `CODEX_HOME` either.
- **Consequence:** the first run of `test_sessions_real.py::test_plugins_install_into_the_agents_configuration`
  (21:18:40) installed Tern's Codex plugin into the user's real `~/.codex/config.toml`: `[marketplaces.tern]`
  with `source` = this build's `.../ReleaseLocal/Tern.app/Contents/Resources/agent-plugins`,
  `[plugins."tern@tern"]`, seven `[hooks.state."tern@tern:hooks/hooks.json:…"]` trust entries, and
  `~/.codex/plugins/cache/tern/`. Nothing else in it was changed by the test. I did not touch `~/.codex`
  myself; the lead should decide whether to leave it (the user approved Tern's plugins in their config,
  but this one points at a development build) or run `agent plugins remove` with a fixed build.
- The test now first plants an "installed" record of a fake version (`0.0.0-probe`) in its temporary
  `CLAUDE_CONFIG_DIR` and `CODEX_HOME`, checks that `agent plugins status` reports it, and refuses to
  install otherwise. With this build it stops there:
  `AssertionError: the app doesn't read CODEX_HOME; not installing (it would change ~/.codex):
  {'agent_installed': True, 'bundled_version': '1.0.0', 'current': True, 'hooks_trusted': True, 'installed': True, 'version': '1.0.0'}`
- Fix: don't scrub `CODEX_HOME` (and probably not `CODEX_*` configuration variables at all; only the
  session markers like `CODEX_THREAD_ID`, `CODEX_SANDBOX*`).

### 1.2 Codex: a message delivered just before a crash is delivered again and again (AG-11)

- `test_sessions.py::test_a_message_that_crashed_the_agent_is_not_sent_again[chaos1-codex]` and `[chaos2-codex]`;
  `test_chaos.py::test_random_operation_sequences` (`delivered more than once: {'8b0bd99b33': 5}`,
  `message 812487a98d delivered 14 times`).
- Repro: a Codex session started with `FAKE_CHAOS=1`, `agent send S "CRASH x"`: 16 receipts for `x` within
  8 s (calm: 1). Under chaos the fake's last notifications (the `userMessage` `item/completed`) are still in
  its writer queue when it exits, as can happen with the real server. The thread itself has the
  `userMessage` with its `clientId` (the fake saves it before crashing, and `thread/resume` returns it), so
  the delivery is knowable; Tern resends the message after each resume, and each resend crashes it again.
- The same chaos run also left a session `starting` ("resuming") for 90 s with three messages queued
  (`message 32207ae209 still pending after 90 s … 'status': 'starting', 'still': 'starting: resuming'`):
  probably the same loop, or its back-off; AG-11 "nothing is pending forever".

### 1.3 `agent wait --message X` prints another message's reply (AG-12)

- `test_sessions.py::test_interrupt_goes_first_and_nothing_sent_before_it_is_lost[claude]` and `[codex]`:
  `SLEEP 30 a` runs; `ECHO steered b` is sent (steered); then `agent send --interrupt "ECHO redirect c"`.
  `agent wait --message <c's id>` returns `DONE` with reply `ECHO steered b…` (its `message.reply` is the
  right `ECHO redirect c…`).
- Cause: `TernAgentRPC.waitResult` replaces the latest message's reply with `session.lastReply` whenever
  they differ ("turns after it, woken by its background work, have the newest word"). Here the later turn
  was `b`'s (requeued behind the redirect), not a turn the agent started itself.

### 1.4 `agent wait` returns before the turn that background work wakes has run (AG-12, AG-13)

- `test_sessions.py::test_wait_waits_until_background_work_has_settled`: `WAKE 3 w` (Claude starts a
  background `sleep 3`, replies "started", and 3 s later starts a turn by itself). `agent wait` returned
  `DONE` after 3.03 s, with the session still `working` and no `woke: w` in the transcript yet.
- Cause: `settled` is true in the gap between `background_tasks_changed {tasks: []}` and the self-started
  turn's `system/init`, which is the order real Claude Code uses (C11wake: `task_notification`,
  `background_tasks_changed`, then `init`). A finished task notification should count as pending work
  until its turn has ended.

### 1.5 `tern codex` without a task never goes live (AG-2)

- `test_live.py::test_the_claude_and_codex_shortcuts_give_the_user_a_session[codex]`: `tern codex --cwd …`
  (no task) opens a tab with the read-only view; for 30 s the session stays `idle`, `location: pane`, and
  the attach command is never typed. `tern claude` with no task works. The help says "without one it
  opens live at once".
- Probably `goLiveAfterStart` sets `goLiveWhenSettled` while Codex's server isn't ready, and nothing calls
  `checkSettled()` once it is (no turn ever runs).

### 1.6 After its live interface ends, a Claude session is `stopped`, not `idle` (AG-7, AG-8, AG-13)

- `test_live.py::test_hide_a_live_claude_with_a_running_turn`: after `agent hide` the interface finishes
  its turn and ends; the session is then `status: stopped`, `activity: stopped`. AG-8: "then the session is
  headless and idle".
- `test_live.py::test_quitting_the_interface_hands_the_session_back[claude]`: after `/exit`, `stopped`
  (Codex: `idle`). `stopped` is what `agent stop` leaves; nobody stopped this session.

### 1.7 Text on the live Claude prompt is lost when a message arrives (AG-9)

- `test_live.py::test_a_message_to_live_claude_waits_while_something_is_typed_in_it`: `tern send --pane P
  draft-…` (no Enter) puts text on the interface's prompt line; `agent send` then ends the interface within
  5 s and runs the message headless (`the interface was ended under the user's typing`). AG-9: "when its
  interface is idle and the user has nothing typed in it".
- The app learns about typing only from keyDown events (`TernAgentUI.keyTyped`), so text put there through
  Tern's own input path (`tern send`, `tern keys`, which agents and scripts use) isn't seen. The keyboard
  variant is `test_a_message_to_live_claude_waits_while_the_user_types_in_it` (a `ui` test, not run).

### 1.8 An interrupt typed into the live Claude interface through `tern keys` leaves it `working` (AG-19)

- `test_live.py::test_live_claude_status_is_truthful`, last step: `SLEEP 60` typed in the interface, then
  `tern keys --pane P esc`: the interface shows "Interrupted · What should Claude do instead?", but the
  session stays `working` (10 s and more). Same cause as 1.7: interrupts fire no hook, and the app only
  watches keyDown. Claude's transcript does record the interrupt (the app already reads that file for crash
  recovery), which would catch both paths.

### 1.9 After a quit, a live pane comes back read-only (AG-7)

- `test_live.py::test_sessions_cut_off_by_a_quit_come_back_in_their_place` (restoration-safe instance): a
  Claude session live in a tab; the app quits (⌘Q-style) and starts again. The pane comes back, but it shows
  the read-only view: `location: pane`, `status: stopped`, for 60 s. AG-7: "live panes live, read-only panes
  read-only". Likely the interface's SessionEnd (it gets SIGHUP as the app quits) clears `live` before the
  state is saved.

### 1.10 Real Claude: Take Over pressed right after quitting the interface is lost (AG-6, AG-7)

- `test_sessions_real.py::test_a_session_goes_live_takes_messages_and_is_handed_back_and_taken_over[claude]`:
  failed 2 of 3 runs at its last step (the codex case passed each time), with:
  ```
  AssertionError: timed out after 60s waiting for the session to be live: {… 'location': 'pane', 'status': 'stopped' …}
  the pane shows:
  … % "$TERN_CLI" agent attach real-383425
  Resume this session with:
  claude --resume f06e6c4f-…
  … % "$TERN_CLI" agent attach real-383425
  Resume this session with:
  claude --resume f06e6c4f-…
  "$TERN_CLI" agent attach real-383425
  … %
  ```
- What the screen says: the first `agent attach` is the go-live after the first turn; the interface was
  ended once to deliver the AG-9 message (Claude prints "Resume this session with …" as it exits) and came
  back (the second `agent attach`); the user then typed `/exit` (second "Resume this session"). The third
  `agent attach`, with no prompt before it, is the one Take Over typed: Tern showed the read-only view as
  soon as Claude's SessionEnd hook arrived, which is before Claude has finished exiting. The test pressed
  Take Over as soon as the view was back; the command was typed into the terminal while Claude still owned
  it, was echoed, and never reached the shell (the next line is a bare prompt). The session then sat in
  "opening its own interface" until the 30 s fallback and stayed in the read-only view.
- With a 1 s pause before pressing (a debugging script, not the test), it works every time. The fakes exit
  immediately after SessionEnd, so `test_live.py::test_take_over_as_soon_as_the_view_is_back` passes and
  can't show this.
- Fix: type the attach command only once the interface's process has exited and the shell is back at its
  prompt (or keep the view hidden until then), rather than on SessionEnd.

### 1.11 Smaller things

- `tern --json ls` shows `"showing": "agent"` for a pane whose session is live (its own interface on
  screen), while `debug.agent.pane` says `"live"`.
- `agent info` still had the old `live` key (the headless process runs), next to `location`; a live Claude
  session had `"live": false, "location": "live"`. (Fixed: it is now `running`, in CLI.md.)
- Not a bug, but tests must know it: a read-only view opened in a tab that isn't selected (`agent open`'s
  default) is built only when the tab is shown (`debug.agent.pane` gives an empty transcript until then), and
  a view just opened may show its first snapshot ("starting") for a moment. The tests focus the tab and wait
  for the content.

## 2. Decisions taken (headless run, nobody to ask)

- **Steering by default** replaces "follow-ups are queued in order". Tests that sent messages to a busy
  session now check steering (the receipt's `pid` and `turn` are the running turn's) and delivery order.
- **`--drop-queued`**: not in the new CLI contract (ag-cli.md), so the redirect test lost its `drop`
  variant. Without it, a message steered just before `--interrupt` must still be delivered exactly once,
  after the redirect (AG-11 "every message is delivered exactly once").
- **The reply of a settle-aware `agent wait`**: AG-12 says it prints "the reply", AG-13 says a self-started
  turn is "never taken as the reply to a message". The tests check the message's own reply through
  `agent read --message` (`"started"`) and don't pin which text the latest-message wait prints after the
  self-started turn (the app prints the newest; that is useful to orchestrators). 1.3 is a different case.
- **Status after a live interface ends:** `idle` (AG-8's words, "headless and idle"), for quitting it too.
- **Codex background terminals** never wake Codex (X15wake), so a session with one is `idle` but shows
  `background_tasks` (kept from the old suite).
- **A session's folder** is its `--cwd` (default: where the command runs), not the folder of the pane given
  with `--pane`; the last part of `test_tern_extra.py::test_new_tabs_start_in_the_folder_of_the_pane_they_come_from`
  (`tern claude --tab --pane A`) was dropped for that reason.
- **Agents typed in a pane** (AG-18): the fake is started with `FAKE_AGENT_DIR` = the fake's default state
  folder in the login environment (`$TMPDIR/fake-agent` of a login shell, computed by `login_fake_dir()`),
  because a session found through the hooks is resumed headless in the login environment, the way the real
  `claude` finds its conversations in `~/.claude` wherever it runs. The test deletes its conversation files.
- **Typing into live interfaces** uses `tern send --pane P --enter TEXT` and `tern keys`; that is a product
  path agents use too, so the app should treat it like the keyboard (1.7, 1.8).
- **Real tests:** headless ones run in a fresh folder that is not a git project, so Codex adds no trust
  entry to `~/.codex/config.toml`; the old `leave_no_codex_trust_behind` fixture (which edited the user's
  config itself) is gone. Live ones use `acceptance/.work-real/live-claude` and `live-codex`. The trust
  prompt is answered by moving to the "Yes" choice from where the cursor is (falls back to `down enter`).
  Live Claude runs without `--full-access`, because `--dangerously-skip-permissions` makes the real TUI ask
  the user to accept bypass mode (another lasting change to their settings).
- **Harness** (`tests/harness.py`): `clean_env` now also scrubs `CLAUDE_*`, `TERN_*` and `AI_AGENT` (the
  outer Claude Code's `CLAUDE_EFFORT=xhigh` and `CLAUDE_PID` reached panes' shells); fake instances set
  `CLAUDE_CONFIG_DIR` and `CODEX_HOME` to folders in their state directory, on the app and so on every pane;
  `start_agent` passes `--env CLAUDE_CONFIG_DIR=<fake dir>/claude-config`. New helpers: `rpc`,
  `session_view` (`debug.agent.pane`), `press` (`debug.agent.press`), `screen`, `type_line`,
  `session_panes`, `self_turns`, `violations`, `read_jsonl`. `cleanup` stops every session that isn't
  stopped. New pytest markers `sessions` and `live` (pyproject.toml).

## 3. What each new test proves

### tests/test_sessions.py (fakes, headless; markers `sessions`, `harness`)

AG-1: `start_prints_the_id_and_shows_nothing` (stdout is only the id; nothing on screen; wait/read; the
agent's own id, a prefix and the name select it); `start_options_reach_the_agent` (model, effort, full access,
env, arguments after `--`); `start_in_a_new_worktree`; `text_from_stdin_and_after_separator` (`start -`,
`send -`, `send --`); `no_command_waits_on_stdin_unless_asked`; `start_with_wait`; `bad_requests_fail_clearly`;
`session_settings_are_private_to_the_user`.
AG-3: `the_first_turn_starts_within_seconds` (< 5 s); `an_agent_that_is_not_installed_fails_at_once` (with the
reason, in start/wait/info/send); `a_send_that_cannot_resume_fails_at_once_and_never_starts_fresh` (folder or
conversation gone).
AG-4: `agents_get_a_fresh_login_environment`; `user_agent_config_is_untouched`;
`the_cli_inside_an_agent_is_this_builds_cli`.
AG-10: `a_message_sent_while_working_steers_the_running_turn` (same process and turn);
`a_message_to_an_idle_session_starts_a_turn_and_old_replies_stay` (+ transcript order, `--last`);
`message_ids_are_the_ones_the_agent_knows`; `interrupt_goes_first_and_nothing_sent_before_it_is_lost`;
`an_interrupt_as_the_turn_ends_never_interrupts_the_new_message` (slow); `an_interrupt_gets_through_a_hung_turn`
(slow); `an_interrupt_survives_its_agent_dying`; `an_interrupt_during_a_turn_the_agent_started_itself`;
`stop_then_send_resumes_the_conversation`; `a_session_that_never_got_a_message_resumes_after_stop`;
`every_resume_keeps_context_and_settings` (after stop, crash, kill -9 of the product, quit; slow).
AG-11: `messages_sent_while_working_are_each_delivered_once_in_order`; `messages_racing_the_end_of_a_turn_are_delivered_once`;
`a_message_the_agent_never_received_fails_visibly`; `interrupt_before_the_agent_takes_the_message`;
`a_message_sent_while_stopping_is_not_lost`; `a_message_the_product_died_while_handing_over_is_delivered_once`
(slow); `a_message_that_crashed_the_agent_is_not_sent_again` (calm and two chaos seeds; new, see 1.2).
AG-12: `wait_with_nothing_pending_and_timeouts` (TIMEOUT says what still runs);
`wait_waits_until_background_work_has_settled` (new, see 1.4); `a_wait_keeps_its_message_when_someone_sends_more`;
`a_timed_out_wait_names_its_own_message`; `a_wait_ends_when_its_session_is_removed`;
`wait_keeps_waiting_across_an_app_restart` (slow).
AG-13: `status_is_truthful_and_cheap_while_busy`; `turns_the_agent_starts_itself` (working, not idle, while the
background task is pending; never the message's reply; a message sent during it gets its own reply);
`a_codex_background_command_is_counted_and_never_a_turn`; `a_stopped_background_command_is_not_counted_again`.
AG-14: `what_failed_to_load_is_shown` (startup: model, MCP servers, flags; refreshed on resume);
`ls_and_info_say_what_each_session_is_doing`.
AG-15: `interrupt_keeps_the_session_and_messages_sent_meanwhile`; `stop_ends_everything_the_agent_started`
(detached, SIGTERM-ignoring children); `names_list_rename_remove`; `stopping_a_session_that_is_still_starting`;
`a_crash_is_an_error_and_a_send_resumes`; `an_agent_exiting_on_its_own`; `a_failed_turn`.
AG-16: `self_and_parent` (`self`, `ls --parent self`, workers shown nowhere); `agents_orchestrate_agents`
(both directions); `watch_notifies_the_supervisor`; `watching_a_finished_turn_notifies_at_once`;
`workers_report_and_supervisors_wait_for_reports`; `workers_run_in_the_background_and_their_orchestrator_finds_them`;
`a_session_knows_its_situation` (name, id, parent, folder, nobody watching, how to report, sessions it
starts run in the background); `the_help_is_short_plain_and_says_workers_run_in_the_background` (also AG-20).
AG-17: `approvals_allow_once_always_and_deny`; `full_access_never_asks`; `several_questions_get_separate_answers`;
`mcp_elicitations`; `withdrawn_requests_disappear`.
AG-22 (cut-off turns): `cut_off_turns_continue_by_themselves` (kill -9 and quit; the note says when and that
what ran was stopped); `a_cut_off_turn_the_agent_started_itself_continues`;
`a_cut_off_turn_whose_conversation_is_gone_fails_at_once`; `a_cut_off_turn_whose_folder_is_gone_fails_at_once`;
`installing_an_update_now_asks_before_cutting_turns_off`.

### tests/test_live.py (fakes' TUI modes; markers `live`, `harness`)

Every test also checks that no conversation ran in two processes at once (`violations.log` didn't grow).
AG-2: `an_interactive_launch_goes_live_after_its_first_turn` (read-only view and headless meanwhile, then the
fake's TUI in the same pane on the same conversation; delivered once; focus unchanged); `placements`
(`--tab --window`, `--split down --pane`, `--new-window`, each goes live); `the_users_focus_moves_only_when_asked`;
`the_claude_and_codex_shortcuts_give_the_user_a_session` (`tern claude|codex TASK`, and without a task: live
at once; see 1.5); `placement_options_never_swallow_the_prompt`; `any_placement_option_shows_the_session_and_none_shows_nothing`;
`a_placement_that_names_nothing_fails_and_starts_nothing`.
AG-5: `a_headless_session_appears_only_when_asked` (`agent open`: new tab, no focus change, both sides, tool
activity, Take Over; showing it again focuses it); `the_view_shows_requests_and_answers_them` (questions and an
approval answered with the view's buttons); `a_reopened_view_shows_everything_in_order`;
`closing_a_views_pane_leaves_the_session`; `a_sessions_pane_behaves_like_any_pane` (view and live: split,
focus, zoom, swap, move to a tab, a window and back; also M-1).
AG-6: `take_over_an_idle_session`; `take_over_during_a_running_turn` (Codex continues it, Claude is
interrupted, < 10 s either way); `open_live_takes_over_at_once`; `attach_outside_a_pane_says_what_to_do`;
`take_over_as_soon_as_the_view_is_back`.
AG-7: `quitting_the_interface_hands_the_session_back` (view, whole conversation, resumes headless; see 1.6);
`sessions_cut_off_by_a_quit_come_back_in_their_place` (slow; see 1.9).
AG-8: `hide_removes_the_view_and_the_session_keeps_running`; `hide_a_live_claude_with_a_running_turn` (the
interface finishes out of sight, then ends; see 1.6); `hide_a_live_codex_with_a_running_turn`.
AG-9: `a_message_to_live_claude_runs_headless_and_comes_back_live`; `a_message_to_live_claude_waits_for_its_running_turn`
(`waiting`/`waiting_reason` in info and ls); `a_message_to_live_claude_waits_while_something_is_typed_in_it`
(see 1.7); `a_message_to_live_codex_goes_through_at_once` (and steers a turn typed in the interface);
`stop_closes_a_live_interface` (also AG-15).
AG-18: `an_agent_typed_in_a_pane_becomes_a_known_session` (Claude and Codex with Tern's plugin installed:
origin `typed`, live in that pane, status and transcript from the hooks, then resumable headless);
`the_plugins_hooks_are_silent_outside_tern` (another terminal, an app that isn't running, a headless session,
Tern without a pane: no output, exit 0, quick, no session created).
AG-19: `live_claude_status_is_truthful` (working/idle, background work keeps it working, a permission prompt is
`needs_input`, an interrupt ends `working`; see 1.8); `live_codex_status_is_truthful`.
`ui` (written, not run: they take the keyboard): `background_sessions_are_in_the_window_menu` (port of the
Window > Agent Sessions test), `a_message_to_live_claude_waits_while_the_user_types_in_it`.

### tests/test_sessions_real.py (real agents; markers `real`, `slow`, `harness`)

`launch_steer_and_resume[claude|codex]` (AG-1, AG-10, AG-12: a running turn is steered, not interrupted; resume
after stop keeps context); `project_instructions_are_loaded[claude|codex]` (AG-4, CLAUDE.md / AGENTS.md);
`a_session_goes_live_takes_messages_and_is_handed_back_and_taken_over[claude|codex]` (AG-2, AG-9, AG-7, AG-6
with the real TUIs; see 1.10); `plugins_install_into_the_agents_configuration` (AG-18, no model call; see 1.1);
AG-20: `claude_with_no_instructions_has_codex_answer` (17*23), `codex_with_no_instructions_has_claude_answer`
(19*21), `an_agent_with_no_instructions_redirects_a_worker` (Claude starts a Codex worker on a story, then
changes its task to 6*7). Each checks the worker exists with the orchestrator as parent and the answer came
from it. Results: launch/steer, instructions and the three AG-20 tests passed (once each; the AG-20 tests took
under 30 s together). Live: codex passed 2 of 2, claude failed 2 of 3 (1.10). Plugins: stopped by its probe (1.1).

### Other files

- `tests/test_robustness.py`: agent tests retagged and adapted (`live` key → status, `exited` → `stopped`,
  `--background` dropped): `quitting_the_app_leaves_no_unowned_processes`, `killing_the_product…`,
  `no_zombies_accumulate` → AG-21; `crash_recovery`, `restart_resumes_sessions` → AG-22; `cli_stays_responsive…`
  → AG-23, AG-13; `long_runs…` → AG-23. Ported from test_tern_agents_extra: `quitting_right_after_an_agent_crash_leaves_nothing`
  (AG-21), `a_partial_log_line_left_by_a_crash_loses_nothing_after_it` (AG-22; Tern-specific, skips if the
  build has no `sessions/<id>/log.jsonl`), `an_explicit_target_overrides_a_stale_caller` (R-7, L-4; not about
  agents). Non-agent tests unchanged.
- `tests/test_chaos.py`: retagged AG-11, AG-13, AG-21 (AG-10); statuses `stopped`/`STOPPED`/`CANCELLED`
  replace `exited`/`EXITED`. It fails on 1.2.
- `tests/test_install.py::test_upgrading_keeps_sessions`: R-8 → AG-22.
- `tests/test_tern_extra.py`: `test_an_agent_launched_into_a_new_window_gets_its_command` ported to
  `tern claude TASK --new-window` (AG-2, L-8; the task headless, then live in the new window: passes);
  `test_new_tabs_start_in_the_folder_of_the_pane_they_come_from` keeps its first part (L-6) and loses the
  `tern claude --tab --pane A` part (decision above).
- Old ids elsewhere: the lead dropped `MA-13` from `tests/test_layout.py:342` and fixed `checks/run_checks.py` and `checks/tern_verdicts.py`. `TEST_CHANGES.md` still mentions the deleted files (history). `tests/mcp_codeword.py` is now unused (it served the dropped real "project features" test).

## 4. Old tests dropped, and why

Deleted: `test_managed.py`, `test_resumption.py`, `test_agent_panes.py`, `test_interactive.py`,
`test_real.py`, `test_tern_agents_extra.py`. Everything still valid was ported (section 3). Not ported:

- **AP-1 typing a follow-up into the agent pane, Esc in the pane interrupts (ui):** the pane is now "a
  read-only pane for seeing headless sessions … it has a takeover button" (the user); typing goes to the
  agent's own interface after Take Over (`take_over_an_idle_session` types into it).
- **AP-2 undo close brings the agent pane back (ui):** no AG requirement; "a keyboard shortcut for removing a
  session from a pane (such that I don't see it but it still runs until it finishes)" replaced closing as the
  way out (AG-8, `agent hide`), and closing a view's pane is covered by `closing_a_views_pane_leaves_the_session`.
- **AP-5 the pane after a restart shows the earlier conversation (ui):** covered without AX by
  `sessions_cut_off_by_a_quit_come_back_in_their_place` (the read-only pane after restart).
- **AP-9 no "new agent" form, no agents section (ui):** no AG requirement says it.
- **IA-1, IA-3 `tern claude|codex … -- ARGS` typed as the user's command; IA-2 the agent noted in `ls`:**
  `tern claude|codex` is now shorthand for `agent start … --tab --focus` ("make it easy to launch sessions that
  the user will interact with: a session that runs headless until the turn finishes and then it's resumed in
  a pane"); typed agents are AG-18's (`an_agent_typed_in_a_pane_becomes_a_known_session`).
- **MA-26 "the help explains idle":** replaced by AG-20 ("The help is short and plain; errors say what to do
  instead"): `the_help_is_short_plain_and_says_workers_run_in_the_background`.
- **MA-25 redirect with `--drop-queued`:** not in the new CLI (decision above).
- **Real tests** `test_interrupt`, `test_approval`, `test_a_question_in_full_access_never_leaves_the_session_stuck`,
  `test_project_skill_is_available`, `test_project_features_load_in_a_never_opened_folder_and_after_resume`,
  `test_a_worker_knows_its_situation`, `test_a_turn_cut_off_mid_command_continues`,
  `test_user_codex_and_claude_config_untouched`: "keep real tests few and cheap" (the brief). Their outcomes are
  covered with the fakes (AG-10, AG-15, AG-16, AG-17, AG-22, AG-4) and, for knowing how to use the product,
  by the AG-20 tests. The config one also needed to edit the user's `~/.codex` itself. Fidelity keeps one
  real test (project instructions); skills, MCP servers, hooks and subagents of a never-opened project are now
  checked by no real test (a gap for AG-4 if the lead wants it back: it costs one haiku turn with several
  tools).

## 5. Runs before the fixes

On the build of 21:50 (before the lead's fixes), `test_sessions.py` + `test_live.py` (not `ui`): 16 failed,
140 passed, 1 error; the failures are the items of section 1 (two were flaky test races of mine, fixed since:
reading a status twice per loop turn, and reading a just-opened view at once). `test_robustness.py`,
`test_chaos.py`, `test_install.py`: everything passed except the chaos sequence test (1.2).

## 6. What still fails on the fixed build

Run on the fixed copy (`--target /tmp/tern-alt/tern.json`, the same fixes the lead then built into
`build/ReleaseLocal`): `uv run pytest --target /tmp/tern-alt/tern.json tests/test_sessions.py tests/test_live.py
tests/test_robustness.py tests/test_chaos.py tests/test_install.py tests/test_tern_extra.py -m "not ui"`:
**1 failed, 225 passed** (16 min). The real tests were not rerun on the fixed build (the lead runs them).

### 6.1 Codex: a message is still delivered twice when crashes follow one another (AG-11)

`test_chaos.py::test_random_operation_sequences`:
```
AssertionError: message b980933cb2 delivered 2 times
Failing test case:
state.first_session(kind='codex', seed=1)
state.crash(which=0)      (seven times in a row, each followed by the receipt and status invariants)
state.teardown()
```
Reproduced on `targets/tern.json` (rebuilt) with a script: a Codex session started with `FAKE_CHAOS=1`, then
seven `agent send S "CRASH <nonce>"` 0.2 to 1.2 s apart, each awaited: in one of four attempts the first CRASH
message had 2 receipts (`{'556a4b3a2c': 2, …}`), the others 1. So 1.2's fix holds for one crash
(`test_a_message_that_crashed_the_agent_is_not_sent_again[chaos1-codex]` and `[chaos2-codex]` pass), but
a second message sent while the first crash is being recovered can make the first one go out again: likely
the reconciliation after a resume (which messages the thread already has) races with the next message's
`turn/start`, or treats the requeued first message as undelivered when the second resume happens before the
first was reconciled.

Everything else in the new and ported tests passes on the fixed build, including `test_tern_extra.py` (the
ported `tern claude TASK --new-window` test), `test_install.py::test_upgrading_keeps_sessions` (AG-22) and
the slow ones.

Not run on the fixed build: the `ui` tests (`test_live.py::test_background_sessions_are_in_the_window_menu`,
`test_a_message_to_live_claude_waits_while_the_user_types_in_it`) and `test_sessions_real.py`.

# Build log

One section per step of [plan.md](plan.md): status, what changed, what was verified and how, and
the choices Alejo should check.

## Step 0: start from Warp parity

**Status:** merged into main (`51ffb464f`).

- `origin/warp/parity` (`4d875c54f`, the 0.9.0 code plus the build-signing fix that release
  needed) merged into main with no conflicts.
- Verified: the merge had no conflicts. The only code on main that `warp/parity` lacked is
  `ad31dda32` (comment boxes grow), one Swift file. The suite runs on the merged tree in step 1.

**For Alejo to check:** the `v0.9.0` tag on GitHub points at `cc9933747` (main's head when it was
published: the design documents), not at the `warp/parity` commit the release was built from,
because `release.sh` lets `gh release create` tag the default branch. The binaries are right; the
tag's source isn't. Releases from main after this step don't have the problem.

## Step 1: take orchestration out

**Status:** built on `design/step1-no-orchestration`, review findings fixed, ready for the release.
The UI half of the suite didn't run: mac-air-2's screen is locked (see "Not verified").

**What changed**

- Removed Umi-run agent sessions: the session engine and store, the Claude and Codex drivers, the
  read-only view and Take Over, every `agent …` command and the `claude`/`codex` shortcuts, Window ▸
  Agent Sessions, Take Over Session (⌃⌘O), Remove Session from Pane (⌃⌘W), the palette's session
  entries and its `conversations:` filter, the inbox (⇧⌘U) and toasts, Warp's coloured status badges
  and Warp's tab-wide "seen" rule. About 8,000 lines of Swift and 700 of CLI went.
- The hook plugin (now 1.1.0) runs `umi hook EVENT --agent K --pid P`, which writes the pane's agent
  state (`UmiAgentHooks`, stored per pane in `UmiAttention`): `agent.kind`, `agent.status`,
  `agent.title`, `agent.summary`, `agent.done`, `agent.session`. `ls --json` shows them in each
  pane's `attributes`; a status change is a `pane.changed` event. The status stays truthful
  (background tasks keep it `working`, Esc/Ctrl-C with no hook for 2 s is `idle`, permission prompts
  and questions are `needs_input`, a failed turn is `error`, a dead process is `stopped`).
- Seen is per pane: `seenAt` is set while the pane itself has keyboard focus in the key window of
  the active app; `changedAt` when `agent.status` changes. The sidebar's agent mark, the Dock badge
  (panes with `needs_input`) and ⌃⌘J (`jump`: needs input, then unseen, oldest first) read them.
- After a relaunch (quit, crash, update) each pane whose agent ran gets its command typed again,
  with the flags it was typed with, resuming its conversation. Saved with the layout
  (`agent_restart`).
- The update's quiet moment counts panes: a pane with an agent is quiet only when `agent.status` is
  `idle` with nothing typed in it and nothing it started still running. `update --now` refuses while
  any pane's agent is `working`.
- `plugins` and `hook` are top-level commands; `doctor` reports the CLI on PATH and the plugins.
- The update note has its own overlay; ⌃⌘U is View ▸ Dismiss Update Note.
- SPEC: AG-1 to AG-17 and AG-20 to AG-24 left; AG-18/AG-19, I-2, I-4, L-9, L-10, L-12, L-14, L-15,
  S-3, S-7, S-13 and R-3 to R-7 reworded. CLI.md took design/cli.md's hook, plugins, doctor and the
  pane's `attributes`. CHECKS.md, TEST_INTERFACE.md, the README and the evidence scripts follow.
  TEST_CHANGES.md lists every removed and changed test.

**Verified, and how**

All runs are on mac-air-2, under `lockf -k ~/umi-screen.lock`, at `956d55395` (the app's code
is the same at the head; the later commit only fixes a Swift test). Earlier runs (at `208e04bc0`
and `1f8bdf4af`) are superseded by these.

- Dev copy (the Debug build, started the way `app/dist/dev.sh` starts it, plus the fakes'
  variables in its environment), driven by `~/umi-test-design-step1-trial.py`: 31 of 31 checks
  read back (`~/umi-test-design-step1-r4-trial.log`). `ls --json` (attributes, no `agent` field),
  `umi agent ls` and `umi claude` failing with what to do, `help --json`, the menus (no session or
  inbox items; ⌃⌘J and ⌃⌘U items), the palette (no session entries), `plugins`, `doctor`; a fake
  Claude typed in a pane writing `agent.*` (working, then idle with title and summary), its sidebar
  row (Claude mark, line 2 = title); a second agent at a permission prompt: Dock badge "1", row
  marked, ⌃⌘J to it and ⌃⌘K back (`debug.key`), its finish unseen until its own pane is focused;
  `update --status` naming the pane with a draft; `umi hook Stop` with "Status: done" giving
  `agent.done=true`; the update note shown, screenshotted and dismissed by ⌃⌘U; `umi comments`
  with no arguments exiting 1; then quitting and restarting the dev copy: both agents typed again
  in their panes, same sessions, `--model fake-trial --dangerously-skip-permissions --resume <id>`
  on the process, `RECALL` showing the same conversation; `/exit` → `stopped`. Screenshots in
  `~/umi-test-design-step1-shots`; `4-update-note.png` shows the note at the top right ("Umi
  updated to 9.9.9", the notes, "⌃⌘U to dismiss").
- Acceptance suite, ReleaseLocal, full run with `UMI_SIGN_IDENTITY=-`
  (`~/umi-test-design-step1-r4-suite.log`): 328 passed, 9 failed, 85 skipped. The 9 failures fail
  on origin/main too (below); 84 skips are the locked screen, 1 a window too narrow for three
  panes. The update tests need `UMI_SIGN_IDENTITY=-` on mac-air-2 (it has no signing identity;
  without it `release.sh`'s codesign fails silently and every update test errors, on main too).
- Swift unit tests (`~/umi-test-design-step1-r5-swift.log`, at the head): 410 passed, 1 failed:
  `TerminalSplitDropZoneTests/centerSelectsLeft`, which fails on origin/main too
  (`~/umi-test-design-step1-swift-base.log`). `UmiJumpTests` (new) passed.

**Not verified**

- The `ui` tests (84 of them: real keys, menus and the accessibility tree) were skipped: mac-air-2's
  screen is locked. They need someone to unlock it.
- The update note in the live window. `umi screenshot` draws the terminals' Metal images over the
  window's cached image, so it now draws the note again on top from the same SwiftUI view, as it
  does for the palette. The screenshot shows the view's look, not that the window itself shows it
  above the panes; that needs the screen unlocked.
- Failing on this branch and on origin/main alike (`~/umi-test-design-step1-r2-others.log` and
  `-r2-base.log`): `test_builds_from_a_path_with_spaces` (the copied CLI folder lacks
  `../../dist/signing.sh`), `test_shift_cmd_f_leaves_a_terminal_search_open`,
  `test_markdown_opens_in_one_docs_tab_most_recent_first`, five synchronized-input and pane-menu
  tests in `test_umi_warp_panes.py`, and `test_the_zoom_and_font_size_are_kept_across_restarts`.
  `test_option_command_i_in_a_one_tab_window_leaves_tabs_opened_later_out` is flaky on both: run
  three times each, it passed once of three on the branch and once of three on origin/main
  (`~/umi-test-design-step1-r5-sync-*.log`).

**After review**

- Fixed: README's uninstall runs `umi plugins remove`; ⌃⌘J drops a failed pane once looked at
  (choice 14); pruning agents keeps those of closed panes ⇧⌘T can still reopen; `codex -m o3 exec
  …` is a one-off (choice 5); `umi comments` with no arguments exits 1 (design/cli.md has no exit
  code 2); the AG-5 verdict and comments that still said "sessions" are gone; `umi screenshot`
  shows the update note.
- Logged instead of changed: keeping ⌃⌘U for the update note (choice 13).

**Choices for Alejo to check**

1. `jump` stays until step 3 brings `go`, rewritten for panes (design/cli.md removes it). Where:
   CLI.md, `UmiNavigation`. Why: ⌃⌘J would otherwise have no CLI form for two steps.
2. `ls --json` already carries each pane's `attributes`, holding only `agent.*` for now; step 2 adds
   the rest. Where: `UmiTopology.paneJSON`.
3. `agent.summary` is the first line of the agent's last reply; the design names it without saying
   what it holds. `agent.done` is computed now with the `done-check` default (step 3 makes it a slot).
4. A relaunch types the program as the shell was given it (`claude`, a path, or the agent's name for
   a `node …/cli.js`), re-exports only `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, and drops what picks a
   conversation, one-offs and the first prompt. Variables typed before the command
   (`FOO=1 claude`) don't come back. A Claude that never had a prompt comes back fresh (no
   `--resume`). Codex comes back as `codex resume ID <its flags>`.
5. `claude -p` (and `codex exec`, also after options: `codex -m o3 exec …`) run in a pane are
   one-offs: their hooks don't make the pane's agent.
6. Quiet moments: only `idle` is quiet; `error` and `needs_input` keep the update waiting (the design
   says "idle with nothing typed"). Keys typed into a permission dialog still count as a possible
   draft until the next prompt is sent, as before.
7. The interrupt rule waits 2 s after the key, or 2 s after a hook of the turn that arrives just after
   it (up to 10 s): the first suite run showed a PreToolUse arriving after the Esc.
8. A pane whose agent needs input keeps its mark when looked at (the mark follows
   `agent.status=needs_input`); before, looking cleared it. "Finished" marks clear on a look at the
   pane itself only.
9. Labeled transition code, to remove once no copy is older than 0.10: `umi agent hook` still runs
   `hook` (plugins installed by 0.9 call it until Umi updates them at launch), and a 0.9 layout's
   pane that showed a session whose own interface ran there gets that agent typed again, rebuilt
   from `sessions/<id>/session.json` (panes of headless sessions become plain shells). The old
   `sessions/` folder stays on disk untouched.
10. Menu ids kept for users' `shortcuts.json`: `session.next_needing_you` (now "Jump to Next Pane
    Needing You") and `view.dismiss_toasts` ("Dismiss Update Note").
11. `AGENTS.md` still mentions agent sessions and `app/macos/UmiTests/verify_agent_panes.py` (removed
    with the read-only view). I left it alone: AGENTS.md changes need Alejo's go-ahead.
12. The real-agent runs (`ACCEPTANCE_REAL=1`) have no tests left; their fixture in `conftest.py`
    stays harmless. A real Claude/Codex check of the hooks in a pane would be the next one to add.
13. ⌃⌘U stays, as View ▸ Dismiss Update Note, though spec-cleanup.md lists it with the inbox keys
    that leave. Where: `UmiShortcuts` (`view.dismiss_toasts`), SPEC I-4 and L-9. Why: spec-cleanup
    also says the update note needs a home of its own, and the note needs a way to go away; the key
    that already dismissed it is the one users know. Check: whether you'd rather the note close
    with a click or after a while, and ⌃⌘U be freed.
14. ⌃⌘J takes a pane whose agent failed (`error`) only while it is unseen; once looked at it drops
    out, as primitives.md defines unseen. Its sidebar mark still shows the failure. Where:
    `UmiAttention.jumpOrder`, SPEC L-12. Working panes are never jump targets, even unseen.


## Step 2: pane data

**Status:** built on `design/step2-pane-data`, ready for review. The UI half of the suite didn't run:
mac-air-2's screen is locked (see "Not verified").

**What changed**

- Attributes on panes, tabs and windows: `umi pane|tab|window set|unset|get` (`UmiAttributes`).
  Values are strings; keys are letters, digits, `.`, `-`, `_`. Panes' are kept by pane id, tabs' on
  the `UmiTab`, windows' on the window; all three are saved in `layout.json` and come back after a
  restart. Each changed value is a `pane.changed`, `tab.changed` or `window.changed` event.
- Read-only keys Umi keeps, computed when read: `kind`, `cwd`, `branch`, `command`, `focused`,
  `hidden`, `in_drawer`, `seen_at`, `changed_at`, `status_since`, `idle_for`, and `visible_count` on
  tabs. Setting one fails with exit 1 and changes nothing, not even the other pairs of the command.
- `role` has one holder per value among panes and among tabs. The Docs tab is now the tab with
  `role=docs` (design/cli.md choice 10): `UmiTab.isDocs` reads the attribute, and Markdown opened
  from outside goes to whichever tab holds it.
- `agent.*` can be written with `pane set` and change the pane's agent in `UmiAttention` (badge,
  ⌃⌘J, `changed_at`); the next hook overwrites them. Every changed `agent.*` key is a `pane.changed`
  event now, `agent.status` first.
- `ls --json`: every pane, tab and window has `attributes` holding everything; panes also have
  `kind`, `hidden`, `in_drawer` and `indicator`. `ls` text shows each pane's own attributes.
- Events carry `at` (ISO 8601) and `cause` (`UmiCause`): `key` with the key, `mouse`, `palette`,
  `cli` with the command and calling pane, `hook`, `umi`. The palette runs its commands with
  `UMI_CAUSE=palette`; the CLI sends its words and `UMI_CAUSE` with every request. `pane.moved`
  has `from` and `to` (tab, window, index).
- The activity log (`UmiActivityLog`): every event in day files under `<state>/logs/activity`, kept
  30 days; `umi log [--since] [--until] [--filter] [--pane]`; `umi events --since` replays it first.
- The focus log (`UmiFocusLog`): stretches of keyboard focus while Umi is active, the screen is
  unlocked and the user typed or clicked in the last 3 minutes, with what the pane showed, in
  `<state>/logs/focus`; `umi focus-log`.
- Times on the command line: ISO 8601, a clock time today (`9am`, `14:30`), or a duration (`2h`).
- Step 1 leftovers: the CLI no longer sends `UMI_SESSION_ID` (`UmiCaller.session` is gone); the
  comments in `UmiInputSync.swift` and `UmiReopen.swift` no longer describe sessions; CLI.md's
  `doctor` exit rule matches SPEC I-2 (non-zero only for a plugin that isn't installed and current);
  COMPROMISES.md marks the rows about sessions, Take Over, the read-only view, the inbox and the
  toasts as removed.
- SPEC: new section D (D-1 to D-8, core tier); L-7 and T-4 reworded. CLI.md gained "Attributes"
  and "Events and logs" from design/cli.md; the Pane, Tab and Window objects follow it.
  TEST_CHANGES.md lists the new and changed tests.

**Verified, and how**

All runs are on mac-air-2, under `lockf -k ~/umi-screen.lock`, in `~/umi-test-design-step2`. The
screen was locked for every run (`CGSSessionScreenIsLocked=Yes`), so the UI tests were skipped.

- Dev copy (the Debug build `app/dist/dev.sh` builds, started the way it starts it), driven by
  `~/umi-test-design-step2-trial.py`: 32 of 32 checks read back (`~/umi-test-design-step2-trial.log`,
  screenshots in `~/umi-test-design-step2-shots`). Tried: `ls --json`'s read-only attributes on a
  shell pane (kind, cwd, branch, focused, hidden, in_drawer, idle_for, seen_at) and the tab's
  `visible_count`; `pane set` from outside, its JSON, `pane get KEY`, `ls` text showing the
  attributes; `umi pane set typed=yes && umi pane get` typed in the pane itself, read back with
  `ls --json` and from the screen (`1-pane-get.png`), its log entry caused by `cli` with the command
  and the calling pane; `pane set cwd=…` failing with `umi: cwd is kept by Umi and can't be set`;
  `pane unset`; `tab set`/`window set`/`tab get`; `role=manager` moving between panes;
  `visible_count=2` after a split; `open -a Umi.app notes.md` landing in the tab given `role=docs`
  (`docs: true`); `agent.status` without `agent.kind` failing; `agent.kind=claude
  agent.status=needs_input` giving Dock badge 1 and indicator `needs_you` (`2-agent-set.png`); then
  `idle` setting `changed_at`/`status_since`; `unset agent.kind` taking the agent away; ⌃⌘T
  (`debug.key`) giving `pane.moved` with cause `{"kind": "key", "key": "ctrl+cmd+t"}` and
  `from`/`to`; the palette's "Set Pane Attribute…" giving cause `palette`; `umi log` typed in a pane
  (`3-log.png`: lines with "by cli (umi pane set …)" and "by palette"); `events --since 10m`
  replaying 15 events; `focus-log --json` and its text with the open stretch last; then quitting and
  restarting the dev copy: the pane's, tab's and window's attributes back, the activity log still
  holding the earlier events, and the stretch open at the quit written.
- Acceptance suite, ReleaseLocal at `d2d7e1c60` (the app's code is the same at the head), full run
  with `UMI_SIGN_IDENTITY=-` (`~/umi-test-design-step2-suite.log`): 355 passed, 8 failed, 85
  skipped. All of D-1 to D-8 pass (traceability copy: `~/umi-test-design-step2-traceability.md`).
  The 8 failures are the ones step 1 found on origin/main; run again on the step 1 worktree (the
  same app code as origin/main), all 8 fail there too (`~/umi-test-design-step2-base8.log`):
  `test_builds_from_a_path_with_spaces`, `test_shift_cmd_f_leaves_a_terminal_search_open`,
  `test_markdown_opens_in_one_docs_tab_most_recent_first` (same assertion on both: a `.txt` file
  goes to the docs tab), four synchronized-input and pane-menu tests in `test_umi_warp_panes.py`,
  and `test_the_zoom_and_font_size_are_kept_across_restarts`. 84 skips are the locked screen, 1 a
  window too narrow for three panes.
- Swift unit tests (`~/umi-test-design-step2-swift.log`): all passed except
  `TerminalSplitDropZoneTests/centerSelectsLeft`, which fails on origin/main too (step 1). The new
  `UmiPaneDataTests` passed.

**Not verified**

- The `ui` tests (84: real keys, menus and the accessibility tree) were skipped: mac-air-2's screen
  is locked. They need someone to unlock it. Nothing in this step draws new UI; the keys and the
  palette were tried through `debug.key` and `debug.palette.perform`.
- The focus log's screen-lock detection with a real lock: the tests stand in with
  `debug.focus_log locked=true` and `debug.ui.assume_active` (which counts the screen as unlocked).
- Mouse as a cause: nothing scripted clicks; it follows the same path as keys (AppKit's current event).

**Choices for Alejo to check**

1. `pane unset` and `pane get` (and the tab and window forms) take a first word as the target when it
   names one and more words follow (for `get`, also when it is the only word); otherwise every word
   is a key. `unset` with only a target fails. Where: `UmiAttributesRPC`, CLI.md "Attributes". Why:
   design/cli.md's `unset [PANE] KEY…` can't otherwise tell `unset priority status` apart. Check: a
   pane named like a key (`priority`) is taken as the pane.
2. `agent.*` through `pane set`: on a pane without an agent it needs `agent.kind` (`claude` or
   `codex`), and `agent.status`/`agent.done` must be one of their values; `agent.status` can't be
   unset alone; `unset agent.kind` removes the agent. Where: `UmiAttributes.agentChange`. Why: Umi's
   agent record needs a kind (icons, relaunch). Check: whether scripts running other agents should
   be able to set `agent.kind=aider`.
3. `command` is the command running, or the last one run (as the sidebar's line shows it), absent
   when none ran. `idle_for` is seconds since the terminal last printed, written `90s` so it
   compares with durations, counted from when Umi first saw the pane; absent for file and web panes.
4. `seen_at` is now while the pane is being looked at; for a pane with an agent it is never earlier
   than the agent's arrival (a new agent's first state isn't news), so `changed_at > seen_at` agrees
   with the marks. `changed_at` and `status_since` exist only on panes with an agent until step 4
   adds hiding.
5. `focused` means focused in its tab (as `ls`'s `focused` field), not "has keyboard focus now".
6. The read-only keys are read-only on tabs and windows too.
7. `role` has one holder among panes and among tabs (as designed); windows' `role` is ordinary. A
   closed pane kept for ⇧⌘T that held the role loses it quietly.
8. Every changed `agent.*` key is its own `pane.changed` event (`agent.status` first), so hooks now
   make more events than step 1's one per status change.
9. Causes: Umi's own key handling and palette rows open a scope; a CLI request carries its words
   (`umi pane set …`) and `UMI_CAUSE`; otherwise a key press or click AppKit handled in the last
   second; else `umi`. Internal `debug.*` requests take the cause of what they simulate. A palette row
   that acts inside the app is `palette` with the row's title as `command`.
10. `umi log --json` prints `{"events": [...]}`, like other commands' JSON; `events` prints the
    whole Event per line (with `ts` too).
11. The activity log keeps every event except `update.countdown` ticks; logs are day files under
    `<state>/logs/activity` and `<state>/logs/focus`, pruned past 30 days.
12. Focus stretches are written when they end (a crash loses the open one, COMPROMISES.md); every
    stretch counts, however short; `focus-log --since` lists stretches overlapping the range.
13. Pane JSON gained `kind`, `hidden`, `in_drawer` and `indicator` now; `hidden` means a stack member
    not on show until step 4 replaces stacks, and `indicator` is computed from today's marks.
14. The Docs tab became the tab with `role=docs` now (design/cli.md choice 10); the tab's `docs`
    field stays until step 4. `layout.json` keeps writing `docs: true` too.
15. `pinned` and `visible_limit` are stored with no effect until step 4.
16. A window reopened with ⇧⌘T comes back without its window attributes (COMPROMISES.md).
17. New palette entries: Set Pane Attribute…, Pin Pane (Never Hidden to Make Room), Unpin Pane,
    Remove Pane Attribute…, Show Pane Attributes, Set Tab Attribute…, Show Tab Attributes, Show
    Activity Log (Last Hour), Show Focus Log (Today).
18. Selectors don't take queries yet (step 3), so `pane set` acts on one pane. `pane move --back`
    isn't built; `pane.moved`'s `from` in the log is there for it.
19. Commands keep `UMI_PANE_ID` for the calling pane; design/cli.md names it `UMI_PANE` for palette
    and key commands, which step 3 brings.


## Step 3: queries, lists and slots

**Status:** reviewed and merged into main. The UI half of the suite didn't run: mac-air-2's screen
was locked for every run (see "Not verified").

**Checked by the orchestrator at the merged head (`71e39f857`):** the builder's last Swift run
never built (the project names the signing identity "Switcher Local Code Signing", which mac-air-2
lacks, and `UMI_SIGN_IDENTITY` doesn't reach xcodebuild). Rerun with `CODE_SIGN_IDENTITY=-` on the
xcodebuild line (`~/umi-test-design-step3-swift3.log` on mac-air-2): every test passed except
`TerminalSplitDropZoneTests/centerSelectsLeft`, which fails on main too.
`UmiQueryTests/aKeyLingeringInCurrentEventIsNotTheCause` passed. The acceptance suite's last full
run was at `703b57ad5` (372 passed, 8 failed, 85 skipped; the 8 also fail on main); the commits
after it are the review fixes, covered by `tests/test_queries.py` (17 of 17) and the Swift run.

**What changed**

- Queries (`UmiQuery`): `KEY OP VALUE`, bare keys, `@LIST`, `and`/`or`/`not`, parentheses, `| sort`,
  `| limit`, and `then` (parts listed one after another, each pane once). Numbers, durations and
  times compare as such. Errors name the character position. Every selector takes a query
  (`UmiTopology.resolvePane/Tab/Window`); `pane set`, `pane unset` and `pane close` act on every match
  (`tab|window set|unset` on every tab or window holding one); `ls --where QUERY`.
- The config (`UmiConfig`): `list.NAME`, `slot.NAME`, `key.KEYS` and `command."Title"` lines in
  `~/.config/umi/config` (and its `config-file` includes), read again when a file changes; executables
  in `~/.config/umi/commands/`. Ghostty skips these keys (Zig, `Config.umiOwnsKey`, called from
  `cli/args.zig`), so they never show as unknown settings.
- Umi's lists: `needs-you`, `unseen`, `jump` (`@needs-you then @unseen`), `manager`. Slots: `jump`,
  `badge`, `landing`, `landing.after`, `tab.summary`, `sidebar.line2`, `strip.make-room`,
  `indicator.working|needs_you|finished`, `done-check`. The Dock badge, the sidebar row's agent and
  line 2, `agent.done`, and coming back to the app (`landing`) read them; their defaults are the old
  behaviour written as queries. `strip.make-room` and `indicator.*` are stored for steps 4 and 5.
- `go LIST|QUERY`, `go --next`, `go --back` (`UmiGo`, one walk per window). ⌃⌘J and ⌃⌘K run
  `go --next jump` and `go --back` in the app; `UmiAttention.jumpOrder` and `UmiNavigation`'s jump
  code are gone.
- `key.…` bindings win over Umi's items on the same keys and run their command as `umi` with
  `UMI_CAUSE=key:<keys>`; `shortcuts ls` lists them (`kind`/`source` `config`). Palette commands show
  in ⌘P (their stdout in the palette, stderr on failure); `command ls`, `command run`.
- New attribute `unseen` (read-only). New commands: `list ls|show`, `go`, `slot ls`, `command ls|run`,
  `wait --attr`, `ls --where`. `jump` is removed (fails, naming `go`).
- Panes and commands get `UMI_PANE` (`UMI_PANE_ID` retired); palette and key commands also get
  `UMI_TAB`, `UMI_WINDOW`, `UMI_CAUSE`, `UMI_CLI`, `UMI_STATE_DIR`. The hook plugins are 1.2.0 (their
  script reads `UMI_PANE`); Umi updates installed ones at launch.
- After step 3's review: `pane move QUERY` moves every match and tab/window queries act on every
  tab or window holding a match (choice 11); a list naming a missing list or itself is an error
  (choice 13); CLI.md and Q-1 name ` then ` among what makes a selector a query (the code already
  did); a Swift test reproduces the lingering-key case of fix (a) without a real key.
- Step 2's review, (a): `UmiCause` takes a key or click as the cause only while AppKit dispatches it
  (the window's `sendEvent`, or a local monitor's event until the run loop's turn ends), not whatever
  `NSApp.currentEvent` still holds up to a second later. COMPROMISES.md's step 2 row says so now.
- Step 2's review, (b): `pane|tab|window get/unset` take a first word as the target only when it is
  a full id, a name, `.`, `#N` (tabs, windows) or a query; a unique id prefix is a key.
- Found while trying it: focusing a pane in another tab selected the tab with its old focused pane
  first, which counted that pane as looked at and cleared its unseen state; ⌃⌘J then skipped it.
  Fixed in `UmiLayout.focusPane` (the test for ⌃⌘J now puts both panes in one tab).
- SPEC: new section Q (Q-1 to Q-8, core tier); L-4, L-12, S-7, D-2, D-4, D-5, D-6 reworded. CLI.md
  took design/cli.md's Selectors, Queries, Lists and `go`, Configuration and `wait --attr`.
  TEST_CHANGES.md lists every added, changed and removed test.

**Verified, and how**

All runs are on mac-air-2, under `lockf -k ~/umi-screen.lock`, in `~/umi-test-design-step3`; the screen
was locked for every run (`CGSSessionScreenIsLocked=Yes`), so the UI tests were skipped.

- Dev copy (the Debug build, started the way `app/dist/dev.sh` starts it, with its own
  `XDG_CONFIG_HOME`), driven by `~/umi-test-design-step3-trial.py`: 40 of 40 checks read back
  (`~/umi-test-design-step3-trial.log`, screenshots in `~/umi-test-design-step3-shots`). Tried: Ghostty
  loading a config holding `list.`, `key.` lines with no errors (`debug.config_errors`); `ls --where`
  with `=`, `>`, `sort -`, `and`/`or` precedence, no match (empty, exit 0) and a bad query (exit 1,
  "character 7"); `pane set --pane QUERY` on two panes; `pane get QUERY`; `pane get <id prefix>` from
  inside a pane reading it as a key; `tab set --tab QUERY`; typed in a pane, `echo $UMI_PANE` (the
  pane, no `UMI_PANE_ID`) and `$UMI_CLI ls --where …` (`1-where.png`); `list ls`, `list show` in the
  list's order; `go mine`, `go --next` twice, `go --back`, `go` on an empty list (exit 1, focus kept);
  ⌃⌘J twice (needs input, then the unseen pane in the same tab) and ⌃⌘K back, caused by the key
  (`2-jump.png`); the Dock badge from the default `badge`; the sidebar row's agent from the default
  `tab.summary` (the focused pane's agent, else the one that needs you); `slot ls`; then, writing the
  config while running: `slot.badge = @mine` (badge 2), `slot.sidebar.line2 = {owner} / {team or
  command}` on the rows (`3-line2.png`), `landing` (1 min away: stays; 3 min: goes, caused by
  `config`), `slot.done-check = ^FINISHED` setting `agent.done` from a Stop hook; `key.ctrl+cmd+y =
  pane set bound=yes` pressed (the focused pane gets it, cause `key` with the keys), `shortcuts ls`
  listing config bindings; `command ls` with a config line and a `commands/` script, `command run`
  showing `UMI_TAB`, `UMI_WINDOW`, `UMI_CAUSE=palette`, `UMI_CLI`; "Say Hello" run from ⌘P showing its
  output (`4-palette-output.png`); `wait --attr` returning when the attribute is set and 124 on
  timeout; `jump` failing with "go --next jump"; `help` listing the new commands.
- Acceptance suite, ReleaseLocal at `138a15b11` (the head adds only this log), full run with `UMI_SIGN_IDENTITY=-`
  (`~/umi-test-design-step3-suite.log`): 368 passed, 10 failed, 85 skipped. All of Q-1 to Q-8 pass
  (`~/umi-test-design-step3-traceability.md`). The failures:
  - Seven fail on origin/main too, run there on the step 2 worktree (the same app code as main;
    `~/umi-test-design-step3-base.log`): `test_builds_from_a_path_with_spaces`,
    `test_shift_cmd_f_leaves_a_terminal_search_open`, `test_markdown_opens_in_one_docs_tab_most_recent_first`,
    `test_a_paste_into_a_synced_pane_is_confirmed_once_and_reaches_every_pane`,
    `test_file_and_web_panes_in_a_synced_tab_get_no_keys`,
    `test_the_pane_menu_with_a_selection_or_a_full_screen_program_has_no_paste_or_clear`,
    `test_the_zoom_and_font_size_are_kept_across_restarts` (step 1 and 2 found the same).
  - Two are flaky on both: `test_option_command_i_types_into_every_pane_of_the_tab` (main: failed in
    its full run and 1 of 4 single runs; step 3: 6 of 8 runs failed, at different steps; steps 1 and
    2 list it as failing on main) and
    `test_option_command_i_in_a_one_tab_window_leaves_tabs_opened_later_out` (main: 2 of 4 failed;
    `~/umi-test-design-step3-sync.log`).
  - `test_pane_data.py::test_umi_keeps_read_only_attributes` failed in both full runs at its
    `idle_for >= 2` after a 3 s sleep (the pane printed something about 2 s after `cd` into a new git
    repository); it passes alone (3 of 3) and with `test_layout.py`, `test_pane_data.py` and
    `test_queries.py` together (64 passed). It depends on the tests before it, on origin/main
    too: running `test_agent_panes.py` to `test_pane_data.py` in order fails it on both the step 2
    worktree (main's app code) and this branch (`~/umi-test-design-step3-prefix.log`). A full run of
    origin/main's suite passed it once (`~/umi-test-design-step3-mainfull.log`: the 8 failures above
    and below, nothing else).
  An earlier full run (at `9d6c6f837`) also failed `test_queries`' badge check (a closed pane didn't
  recount the badge; fixed in `f1000ea55`) and three tests that typed a bare `umi` in a pane, which on
  mac-air-2 is the installed 0.6.3 (it reads `UMI_PANE_ID`); those now run the build's CLI by path
  (TEST_CHANGES.md).
- Swift unit tests (`~/umi-test-design-step3-swift.log`): 423 passed, 1 failed:
  `TerminalSplitDropZoneTests/centerSelectsLeft`, which fails on origin/main too (step 1). The new
  `UmiQueryTests` (12) passed.

**Not verified**

- The `ui` tests (85 skipped: real keys, menus and the accessibility tree): mac-air-2's screen was
  locked for every run (`CGSSessionScreenIsLocked=Yes`). They need someone to unlock it. Keys were
  tried through `debug.key` (Umi's own key handling, then the window), the palette through
  `debug.palette.perform`.
- Fix (a) with real key presses: no key could be typed on the locked Mac. The Swift test
  `UmiQueryTests/aKeyLingeringInCurrentEventIsNotTheCause` reproduces the lingering case inside the
  app: it posts a key and takes it off AppKit's queue without sending it, checks that
  `NSApp.currentEvent` now holds that key under a second old (what the old rule named the cause),
  and checks that the cause is `umi`. A real key press on an unlocked mac-air-2, followed within a
  second by a change Umi makes on its own, is still untried.
- `landing` with a real return to the app: tried through `debug.landing` (the same code the
  activation notification calls), not by switching apps.

**Choices for Alejo to check**

1. `then` joins queries (`@needs-you then @unseen`): design/cli.md's grammar has no way to say "these,
   then those", which `jump` needs. A part that is only `@LIST` keeps that list's order. Where:
   `UmiQuery`, CLI.md "Queries".
2. `unseen` is a new read-only attribute (`changed_at > seen_at`), since a query can't compare two
   attributes. Where: `UmiAttributes.computedValue`, D-2, D-4.
3. `KEY != VALUE` holds for a pane without the key (so `agent.status!=working` includes shells).
4. Slots are `slot.NAME = VALUE`. `jump` is the list `jump`: `slot.jump` and `list.jump` set the same
   thing, so ⌃⌘J (`go --next jump`) always follows it. `badge`, `landing` and `tab.summary` take
   queries; `done-check` a regular expression; `sidebar.line2` a template (`{a or b}`: the first set
   key). `landing.after` (default 10m) is a slot of its own, since the design says only "after N
   minutes".
5. The defaults as queries: `tab.summary` approximates "the latest stop" with `status_since` (a working
   agent's start, not its last stop). The `sidebar.line2` default keeps the built-in line (the agent's
   status when it has no title, the running mark on commands); a template is used only once the user
   sets one, rendered from the `tab.summary` pane, else the focused one.
6. `strip.make-room` (`not pinned and not focused | sort seen_at`) and `indicator.*` (`muted`, `amber`,
   `muted`) are listed and stored; steps 4 and 5 use them.
7. `go`: a new walk's first `--next` skips the pane focused now (as ⌃⌘J did); the walk wraps round;
   `go LIST` (without `--next`) also starts a walk, so `go --back` returns from it. `go --back` uses
   the walk whose last step is focused now, else the current window's. A bare word that isn't a list
   is read as a query (`go pinned`).
8. A key binding's ACTION is a palette command's title, `@LIST` (`go --next`), or a `umi` command line,
   run as a `umi` process (COMPROMISES.md); a failure beeps. Like Umi's items, a binding needs ⌘ or ⌃
   (or a function key). ⌃⌘J on an empty list beeps, as before; `go` says "nothing in jump".
9. Palette commands from the commands folder are titled from the file name (`where-am-i.sh` → "Where
   am i"); `command."Title"` lines run with `/bin/sh -c`. `command run` from a terminal records its
   `umi` calls as `palette` unless `UMI_CAUSE` says otherwise.
10. For `pane set`, a positional first word that reads as `KEY=VALUE` is a pair even if it could be a
    query (`pane set owner=me x=1` sets two keys); a query target goes in `--pane`, or reads as one
    when it isn't a single pair (`@list`, `not hidden`, `(a=1)`). Where: `UmiAttributesRPC`, CLI.md.
11. `pane set`, `unset`, `close` and `move` act on every match, in the query's order. `pane move`'s
    first match goes where the options say and each next one beside the one moved before it (so
    `--new-tab` makes one new tab holding them all); with `--to P`, P itself stays put. A tab or
    window query acts on every tab or window holding a match for `close`, `equalize`, `color`,
    `pin`, `unpin`, `set` and `unset`; `tab focus|rename|move` and `window focus` take the one holding
    the first match (one focus, one name). `hide`/`show` come in step 4. Where: `UmiRPC`
    (`pane.move`, `tab.*`, `window.close`), `UmiTopology.everyTab/everyWindow`, CLI.md, Q-1.
12. `tab back` stays until step 6 (design/cli.md removes it, but ⇧⌘[ keeps meaning "back through the
    tabs visited" until step 6 makes it Warp's previous tab). design/plan.md's step 6 now says to
    remove it.
13. Problems in Umi's config lines show in `list ls` and `slot ls` (`problems`, and the CLI prints them
    on stderr), not in Ghostty's configuration-errors window. A list whose query names, directly or
    through other lists, a list that doesn't exist, doesn't parse or names it back is such a
    problem: `list ls` gives it an `error`, a query naming it fails with exit 1, and a query slot
    naming it shows the `error` in `slot ls`. Where: `UmiConfig.listError/referenceError`.
14. `ls` lost its `list` alias (`umi list` is now the lists).
15. The hook plugins went to 1.2.0 because their script now checks `UMI_PANE`; Umi updates installed
    ones at launch.
16. Fix (a) watches key and mouse events with a local monitor (each counts until the run loop's turn
    that dispatches it ends) and wraps the window's `sendEvent` (for keys Umi itself posts). Where:
    `UmiCause`, `TerminalWindow.sendEvent` (marked Umi).
17. `focusPane` now sets the tab's focused pane before selecting the tab (found by the trial; it
    cleared a neighbour's unseen state). Where: `UmiLayout.focusPane`.

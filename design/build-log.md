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


## Step 4: hidden panes and the pane strip

**Status:** built on `design/step4-hidden-panes-strip`, ready for review. The UI tests didn't run:
mac-air-2's screen was locked for every run (see "Not verified"). They are written and need one run
on an unlocked screen before merging.

**What changed**

- Hidden panes replace stacks (`UmiHiddenPanes.swift`; `UmiPaneStacks.swift` is gone). A hidden pane
  leaves its tab's split tree, stays in the tab (`UmiTab.hidden`, in strip order) and keeps running.
  `pane hide [PANE] [--until CONDITION]…`, `pane show [PANE] [--focus]`, `pane until [PANE]`; Window ▸
  Hide Pane; palette entries Hide Pane, Hide Pane Until…, Show Hidden Pane….
- The three-pane limit: every tree change of a tab reaches `UmiHidden.treeDidChange` (from
  `TerminalController.setTree` and `surfaceTreeDidChange`), so whatever adds a pane to a tab at its
  `visible_limit` (Ghostty's own splits and drops included) hides the pane `strip.make-room` picks,
  never one that arrived. `split`, `pane focus`, `pane move` and `edit` report `hid`. Lowering
  `visible_limit` hides at once. `pane focus`, `go` and the palette bring a hidden pane in at the
  right end.
- `--until`: a query about the pane or a duration, checked on every `pane.changed` of the pane, at
  the duration's moment and once a minute; shown without focus, `by_condition`, cause `config`,
  `unseen` until looked at; saved with the layout.
- The pane strip in the title bar band above the panes (`UmiPaneStrip`): a chip per pane, on show in
  layout order then hidden ones dim and italic, the focused one filled, file chips with their type
  icon and unsaved dot. A chip is a `SurfaceDragSource` (Ghostty's drag source gained a click that
  isn't a drag): click shows or focuses, drag moves the pane (a hidden one too: drops on pane edges,
  sidebar rows, the previous/next-tab targets, outside the window).
- ⌘[ ⌘] (`UmiPaneWalk`): walk the strip; a hidden pane is brought in at the right end (⌘]) or left
  end (⌘[); stepping on restores the layout first; releasing ⌘ (or any other key or click) lands it,
  and only the landing is reported. A menu click lands at once. `debug.key` takes `hold`, and
  `debug.release` lets go, so the suite can walk on a locked screen.
- Removed: stacks and the "Stack here" drop zone, `pane.stacked`, the `stack`/`shown` pane fields,
  the tab's `docs` field (layout.json no longer writes it; it still reads it), E-9's new-tab rule
  (files open right of the calling pane in its own tab), the file and web headers' grips, Ghostty's
  hover grab handle. The Docs tab is an ordinary tab (`role=docs`): Markdown from outside opens at its
  right end under the same limit.
- Closing the last pane on show of a tab with hidden panes brings in the hidden one used most
  recently, so the tab stays.
- Pane JSON: `hidden` is real; tab JSON gained `visible_limit` and `strip`; `editor ls` documents
  gained `hidden`; `changed_at` covers hiding and showing.
- Launch configurations save hidden terminal panes as `is_hidden: true` and open panes marked so,
  and those past three, hidden. Hidden panes and their conditions come back after a restart; undo of
  a move restores hidden lists (`UmiSnapshot`).
- SPEC: new section H (H-1 to H-8, fixed tier); M-7 removed; L-9, L-18, M-4, E-1, E-9, E-10, E-12,
  E-24 reworded. CLI.md took design/cli.md's "Hidden panes" and the `hid`, `visible_limit` and
  `strip` fields. CHECKS.md: M-4/H-8 and H-5/H-6 checks. TEST_CHANGES.md lists every test change.

**Verified, and how**

All runs are on mac-air-2, in `~/umi-test-design-step4`, under `lockf -k ~/umi-screen.lock`. The
screen was locked for every run (`CGSSessionScreenIsLocked` true), so every UI test was skipped. The
Mac has no signing identity: builds and the update tests use a local, uncommitted edit of
`app/dist/signing.sh` that accepts ad hoc signing (`~/umi-test-design-step4-build.sh`, as step 3 did).

- Dev copy (the Debug build, started as `app/dist/dev.sh` starts it), driven by
  `~/umi-test-design-step4-trial.py`, at `083681af3`: 30 of 30 checks read back
  (`~/umi-test-design-step4-trial.log`, screenshots in `~/umi-test-design-step4-shots`). Tried: three
  splits then a fourth (`hid`, never the new or focused pane; `strip` and `ls` order; no frame on the
  hidden pane; its shell still answering `send`/`read`); `pane hide` (event caused by `cli`,
  `changed_at`); hiding the last pane on show (exit 1, "last pane on show"); `pane show` (right end,
  focus kept) and `--focus`; `--until owner=me` (shown on `pane set owner=me`, no focus,
  `by_condition`, cause `config`, `unseen=true`), `pane until`, `--until 2s`; ⌘] held through every
  pane (`debug.key` with `hold`): the panes on show, then each hidden one at the right end, back on
  the first with the layout as it was, `debug.release` keeping it; ⌘[ bringing the last hidden pane in
  at the left end (`2-walk-left-end.png`); Window ▸ Next Pane and Hide Pane from the menu; `edit` into
  a full tab (right of the caller, same tab, `hid`); Markdown from outside opening the ordinary Docs
  tab; a hidden pane dropped on a pane's edge and on a sidebar row; `help` listing the commands; undo
  of a move that made room; `layout save` writing `is_hidden`; quitting and restarting: hidden panes
  and their conditions back. The screenshots show the strip in the title band
  (`1-strip-one-hidden.png`: alpha filled, gamma, delta, beta dim and italic) and a file pane's header
  without a grip (`3-file-pane-no-grip.png`).
- Acceptance suite, ReleaseLocal at `f28466520` (later commits change tests, the build log and make
  `umiAppending` generic for the Swift test), full run (`~/umi-test-design-step4-suite.log`): 365
  passed, 12 failed, 11 errors, 86 skipped (85 UI tests: the locked screen; 1 a window too narrow for
  three panes). Then:
  - the 11 errors and 2 failures in the update and install tests were the signing edit missing during
    that run (`release.sh: can't sign the app`); with it, `test_umi_extra.py` and `test_install.py`
    passed, 37 of 37 (`~/umi-test-design-step4-suite-updates.log`);
  - `test_the_prompt_sits_at_the_bottom_from_the_start` counted the strip's chips as terminal text;
    the test now measures below the title band (TEST_CHANGES.md); `test_umi_blocks.py` and
    `test_hidden_panes.py` then passed, 32 passed and 4 UI skipped
    (`~/umi-test-design-step4-suite-blocks.log`);
  - the other 9 fail on main too: run on the step 3 worktree (main's app code, `71e39f857`),
    `test_builds_from_a_path_with_spaces`, `test_shift_cmd_f_leaves_a_terminal_search_open` and five
    synchronized-input, pane-menu and zoom tests failed there as well
    (`~/umi-test-design-step4-base.log`); `test_option_command_i_in_a_one_tab_window_leaves_tabs_opened_later_out`
    passed there this time and is the one steps 1 to 3 found flaky on both.
  - `test_markdown_opens_in_one_docs_tab_most_recent_first`, failing on main since step 1, is
    replaced by the Docs tab's new test, which passes.
- Swift unit tests at the head (`~/umi-test-design-step4-swift.log`): 428 passed, none failed.
  `TerminalSplitDropZoneTests/centerSelectsLeft`, failing on main since stacks added the centre zone,
  passes again; the new `UmiHiddenPanesTests` (3) pass.

**Not verified**

- Every UI test (86 skipped), among them the five this step adds or changes and the orchestrator
  should run on an unlocked screen before merging:
  `test_hidden_panes.py::test_the_strip_names_every_pane_and_a_click_brings_a_hidden_one_in_ui`,
  `::test_real_cmd_brackets_walk_and_land_on_release_ui`,
  `::test_a_chip_dragged_onto_a_pane_edge_moves_its_pane_there_ui`,
  `test_umi_panes_ui.py::test_dragging_a_pane_to_the_top_or_bottom_centre_moves_it_between_tabs_ui`
  (now drags the chip) and
  `test_umi_editor_warp.py::test_header_shows_the_unsaved_dot_and_chips_show_type_icons` (the strip's
  chips). So none of these was seen working: a real click on a chip, a real drag of a chip, real ⌘
  held and released (the walk only ran through `debug.key` with `hold` and `debug.release`), whether
  the empty part of the title band still drags the window, the strip's place beside the window's
  buttons with the sidebar hidden (78 points in), and the chips' accessibility labels and values.
- The CHECKS.md items H-5, H-6, H-8 and M-4 (by hand).

**Choices for Alejo to check**

1. Strip order: the panes on show in layout order, then the hidden ones. A pane brought in takes the
   right (or left) end of the layout, and the pane hidden for it takes the incoming one's place among
   the hidden chips (the "swap"); a pane hidden with `pane hide` goes first among the hidden. Where:
   `UmiHidden.strip`, `show`, `hideNow`.
2. Closing the last pane on show of a tab with hidden panes brings in the hidden one used most
   recently instead of closing the tab and its hidden panes (the design says hidden panes don't come
   in by themselves after a close, but a tab can't show none). Where: `UmiHidden.refill`, H-4.
3. `unseen` after hiding: being hidden sets `changed_at` but doesn't make a pane unseen (else hiding
   a pane would make it a ⌃⌘J target); coming back on show without being looked at does, whatever
   brought it back (a condition, or `pane show` without `--focus`). So `unseen` is no longer exactly
   `changed_at > seen_at` for a hidden pane. Where: `UmiAttributes.computedValue("unseen")`, CLI.md.
4. ⌘[ ⌘] land on ⌘ released, and also on any other key press or click; a menu click lands each step
   at once. The walk isn't undoable (it lands where you let go). Each step focuses its pane, so the
   panes walked through count as looked at. The pane the walk began on is never hidden for it.
   Where: `UmiPaneWalk`.
5. A hidden pane that moves (`pane move`, a drop) leaves from the right end of its tab; moved within
   its own tab, the tab then makes room. Where: `UmiLayout.move`.
6. `pane hide QUERY` that would hide every pane on show of some tab is refused whole (exit 1, nothing
   hidden). Where: `UmiRPC` `pane.hide`.
7. `--until` conditions are saved with the layout and come back after a restart (the design doesn't
   say); a duration is also checked at its exact moment, not only once a minute.
8. Launch configurations mark hidden panes `is_hidden: true`, a key of Umi's own; Warp's reading of a
   file with it is untried. Hidden panes are written after the panes on show, in the top row.
9. Chips are at most 300 points wide (E-24's limit for file chips), not the prototype's 150. A
   narrow window clips the strip at its right; the prototype's "+N" collapse isn't built.
10. Window ▸ Hide Pane is new (no default key). ⌘[ ⌘] are Window ▸ Previous Pane / Next Pane; their
    ids stay `pane.stack_previous` / `pane.stack_next` for users' `shortcuts.json`.
11. With every other pane pinned, a tab shows more than its limit rather than hide a pinned pane.
12. A file opened from a hidden pane opens at the right end of its tab. The Docs tab's new
    documents open at its right end, focused (E-10: "to the right of its panes").
13. Transition code, to remove once no layout is older than 0.10: a layout saved with stacks brings
    their members not on show back as hidden panes (`UmiPersistence.restoreLayout`).
14. `edit` run outside Umi's panes still opens beside the current window's focused pane; design/cli.md's
    "Markdown goes to the Docs tab, other text to the closest tab" for that case isn't built (it
    wasn't before this step either).
15. The tests that check rows of four panes (L-19) raise the tab's `visible_limit`; step 6 removes the
    hand-placed divider rules they mostly cover.

**Incident.** The first push of this branch went to `main` (the new worktree tracked `origin/main`
and the repository's `push.default` is `upstream`): `main` briefly pointed at `c9034c9d0`, this step's
first commit. Minutes later it was put back to `69480b751` with `git push --force-with-lease`
(lease on `c9034c9d0`, so nothing else could be lost) and the branch now tracks its own remote
branch. If any other session fetched `main` in those minutes, it saw that commit.

### After review (2026-11-08)

**Fixed**

- Dragging a hidden pane's chip out of the window now gives the pane a window of its own, opened
  where the chip was dropped. The code had landed in the zoom handler (where it also made a zoom
  aimed at a hidden pane open a window); it is now in the handler for a drag that ends outside every
  window (`BaseTerminalController.ghosttySurfaceDragEndedNoTarget`). `UmiLayout.PaneDestination.newWindow`
  takes the drop point.
- Closing a tab, other tabs, tabs below or tabs on the right asks first when a hidden pane runs a
  program, as it does for panes on show (`TerminalController.runsProgram`). SPEC H-2 says so.
- The ⌘[ ⌘] walk goes on for the keys Previous Pane / Next Pane are bound to now
  (`UmiPaneWalk.isWalkKey`, via `UmiShortcut(event:)`), not fixed key codes. SPEC H-6 says so.
- The strip has the prototype's 1-point separator between the chips on show and the hidden ones, and
  hidden chips are 34% white, as in the prototype.

**New tests**: `test_hidden_panes.py::test_closing_a_tab_asks_first_when_a_hidden_pane_runs_a_program`
(not UI; passes), `::test_a_hidden_chip_dragged_out_of_the_window_gets_a_window_of_its_own_ui` and
`::test_a_rebound_next_pane_key_walks_and_stepping_on_puts_the_layout_back_ui` (UI; unrun).

**Verified, and how** (mac-air-2, `~/umi-test-design-step4` at `dfd2288cf`, under the screen lock;
the screen was locked again, `CGSSessionScreenIsLocked` true, so UI tests were skipped)

- Dev copy, `~/umi-test-design-step4-trial2.py`: 5 of 5 read back (`~/umi-test-design-step4-trial2.log`).
  Close tab with a running hidden pane shows "Close Tab?"; Cancel keeps the tab and the hidden pane;
  with the program stopped the tab closes at once; the strip shows alpha, gamma, a separator, then
  beta dim and italic (`~/umi-test-design-step4-shots/4-strip-separator.png`).
- Acceptance suite, ReleaseLocal, full run with the signing edit in place
  (`~/umi-test-design-step4-suite2.log`): 379 passed, 9 failed, 89 skipped (UI tests: the locked
  screen). 8 of the failures are the base failures listed above (they fail on main too).
  The ninth, `test_pane_data.py::test_umi_keeps_read_only_attributes` (`idle_for` read 1s after a
  3s sleep), passed in the earlier run and in 4 reruns since (`~/umi-test-design-step4-suite2-rerun.log`:
  `test_pane_data.py` and `test_hidden_panes.py`, 37 passed, 5 UI skipped): a timing flake, left alone.
- Swift unit tests (`~/umi-test-design-step4-swift.log`): 427 passed, 1 skipped (a benchmark), none failed.

**Not verified**: every UI test, now 7 in `test_hidden_panes.py` (the 5 there plus the 2 above),
`test_umi_panes_ui.py::test_dragging_a_pane_to_the_top_or_bottom_centre_moves_it_between_tabs_ui`,
`test_umi_editor_warp.py::test_header_shows_the_unsaved_dot_and_chips_show_type_icons` and the
rest of the UI tests. The drag out of the window was never seen working.

**Choices for Alejo to check**

16. With no title bar (full screen, or a hidden title bar style), the strip takes a 22-point band of
    its own above the panes instead of disappearing, because the chips are now the only drag handles
    and the only mouse way to a hidden pane. So "adds no height" holds only where there is a title
    bar. Untried in full screen. Where: `TerminalView` (`max(topInset, 22)`), SPEC H-5.
17. The walk follows a rebound key, but it is held only while ⌘ is down: a rebinding without ⌘
    lands each step at once, like a menu click. Where: `UmiPaneWalk.held`.


## Step 5: the pane indicator

**Status:** built on `design/step5-pane-indicator` (from `design/step4-hidden-panes-strip`, not yet in
main), ready for review. The UI tests didn't run: mac-air-2's screen was locked for every run (see
"Not verified"). They are written and need one run on an unlocked screen before merging.

**What changed**

- The pane indicator (`UmiIndicator.swift`): one mark per pane at its bottom right, in the
  terminal's right and bottom padding (centre 8 points from the right edge, 10 from the bottom), over
  terminals, file and web panes. States from `agent.status`: working; `needs_input`/`error` need you;
  `idle`/`stopped` finished while `unseen`, then nothing. Quiet palette from the prototype (working
  `#6f7f76`, needs you `#e0a93e`, finished `#bdbdbd`); nothing animates.
- Focus: the focused pane's mark is 9 points instead of 7 and at full strength (others' working and
  finished marks at 70%; needs you always full); in a tab showing more than one pane the focused
  pane is lifted by white at `indicator.focus` (default 3%: `#050505` becomes about `#0c0c0c`, the
  prototype's value), and an idle focused pane shows a grey (`#6a6a6a`) mark.
- The cyan focus line is gone (`TerminalSplitTreeView`). S-3's brighter agent logo is gone: the logo
  stays at 60% and the row's icon circle carries the summary pane's mark at its bottom-right edge.
- Strip chips show the mark before their icon; their accessibility value ends with the state.
- `tab.summary` now looks at all of a tab's panes, hidden ones after those on show.
- Slots: `indicator.working|needs_you|finished` take `muted`, `amber`, `green`, `violet`, `grey`,
  `#RRGGBB` or `none`; new slot `indicator.focus` (`3%`, up to 20%). Bad values show in `slot ls`
  and keep the default. The config is re-read every second for the indicator.
- `<cli> screenshot` draws the marks and the lift over the terminal images (they come from the
  terminals' layers and covered the SwiftUI overlay).
- `debug.ui.indicator` reports what is drawn (each pane's state, mark colour/size/opacity, lift;
  chips; rows; the style); a row's `mark` in `debug.ui.rows` is the indicator state (now with
  `working`); `debug.ui.attention` panes gained `indicator`.
- Removed Ghostty's unreferenced `SurfaceGrabHandle.swift` (left by step 4).
- SPEC: new section PI (PI-1 to PI-4, fixed tier); S-3, D-4, Q-4, H-5 reworded. CLI.md: `indicator`
  wording, `tab.summary`, the indicator slots and `indicator.focus`. CHECKS.md: PI-2/PI-3.
  TEST_CHANGES.md lists the added and the two changed tests.

**Verified, and how**

All runs are on mac-air-2, in `~/umi-test-design-step5`, under `lockf -k ~/umi-screen.lock`. The
screen was locked for every run (`CGSSessionScreenIsLocked` true), so every UI test was skipped.
Builds pass `CODE_SIGN_IDENTITY=-` to xcodebuild; the suite and Swift runs use the same local,
uncommitted `app/dist/signing.sh` edit as step 4 (`~/umi-test-design-step5-{build,suite,swift}.sh`).

- Dev copy (the Debug build, started as `app/dist/dev.sh` starts it, with its own config folder),
  driven by `~/umi-test-design-step5-trial.py` at `1d2acf8d4`: 34 of 34 checks read back
  (`~/umi-test-design-step5-trial.log`, screenshots in `~/umi-test-design-step5-shots`). Tried: the
  default style; a lone shell pane (no mark, no lift); three panes (the focused one's grey 9-point
  mark and 3% lift, the others nothing); hooks `UserPromptSubmit` (working, muted, 70%),
  `PermissionRequest` (needs you, amber, full), `Stop` out of sight (finished, light grey); the
  chips' states; in the screenshot, amber pixels at the needs-you pane's bottom right, grey at the
  focused one's, the focused pane's background a few levels brighter, no cyan on its top edge;
  focusing the finished pane clears it; focused needs-you is 9 points; the row of a tab follows
  `tab.summary` (needs you, then a working tab's row, then a tab whose hidden pane needs you);
  writing the config while running (`needs_you = #ff0000` drawn red, `focus = 10%` lifting about
  25 levels, `working = none`), bad values (`blinking`, `50%`) shown by `slot ls` with the defaults
  kept, `focus = 0`; a file pane focused (the mark and lift over its editor); a hidden pane's chip.
  The first run found that `screenshot` drew the terminal images over the marks; fixed in
  `1d2acf8d4`, after which the pixel checks passed (`1-three-panes-states.png`, `2-sidebar-rows.png`).
- Acceptance suite, ReleaseLocal at `5fae46d31` (later commits only add this log), full run
  (`~/umi-test-design-step5-suite.log`): 387 passed, 8 failed, 91 skipped (UI tests: the locked
  screen). `test_pane_indicator.py`: 7 passed, 2 UI skipped. The 8 failures are the ones steps 1 to 4
  list as failing on main; run alone on main's app code (`~/umi-test-design-step3`, `71e39f857`;
  origin/main `69480b751` differs only in the build log), 7 of them failed there too and
  `test_option_command_i_in_a_one_tab_window_leaves_tabs_opened_later_out`, the one steps 1 to 4
  found flaky on both, passed (`~/umi-test-design-step5-base.log`).
- Swift unit tests (`~/umi-test-design-step5-swift.log`): 430 passed, 1 skipped (a benchmark), none
  failed; the new `UmiIndicatorTests` (3) pass.

**Not verified**

- Every UI test (91 skipped). This step's two, for the orchestrator to run on an unlocked screen:
  `test_pane_indicator.py::test_the_marks_and_the_lift_on_screen_ui` (the marks, the lift and no
  cyan line in a `screencapture` of the real window, and a real click moving focus) and
  `::test_chips_and_rows_say_the_state_to_accessibility_ui`. So the SwiftUI overlay itself was never
  seen on screen: the screenshots above draw the marks with the same looks and positions
  (`UmiIndicator.draw`), but the on-screen overlay is a separate code path (`UmiPaneIndicatorOverlay`).
  Step 4's unrun UI tests still stand.
- The CHECKS.md item PI-2/PI-3 (by hand), and how 3% looks to a person ("subtle enough that other
  panes don't look dull").
- A light theme: the lift is white over the pane, which does almost nothing on a light background.

**Choices for Alejo to check**

1. Place: the mark's centre is 8 points from the pane's right edge and 10 from its bottom, inside
   Ghostty's padding (16 right, 20 below the prompt), so it never covers text; it sits just under the
   prompt line rather than on it, because the prompt's distance from the bottom varies with
   `window-padding-balance`. Full-screen programs have no bottom padding, so there it sits over the
   last row's right edge. Where: `UmiPaneIndicatorOverlay.inset`.
2. Focus: the prototype's "larger, brighter mark" (9 vs 7 points; other panes' working/finished marks
   at 70%, needs you always full) plus a white lift of the focused pane in a split (3%, the
   prototype's `#0c0c0c` on `#050505`). An idle focused pane in a split gets a grey dot (the
   prototype's size option did); a lone pane gets no lift and no grey dot, as the cyan line was only
   for splits. Chips show no grey dot (the focused chip is already filled).
3. "The amount is a setting": the slot `indicator.focus` (`3%`, `0` off, at most 20%) rather than a
   new config key, so Ghostty's parser needed no change. Where: `UmiConfig.slots`, `UmiIndicator`.
4. Slot values: `muted` means each state's quiet colour (working `#6f7f76`, finished `#bdbdbd`, and
   for needs you a dull amber `#8c7a52` I made up, since the prototype never mutes it); also `amber`,
   `green`, `violet`, `grey`, `#RRGGBB`, `none`. A bad value keeps the default, shown in `slot ls`.
5. The row's mark sits on the bottom-right edge of the row's icon circle, keeping Warp's icon and the
   agent logo (the prototype replaced the icon with the dot). The logo no longer brightens. A row's
   `mark` in `debug.ui.rows` now has `working` too.
6. `tab.summary` now considers hidden panes (after those on show), as the prototype's sidebar does,
   so a hidden pane that needs you shows on its row; this also changes which agent gives the row its
   logo and line 2. Where: `UmiSlots.summaryPane`, CLI.md, Q-4.
7. Accessibility: the pane mark itself is hidden from the accessibility tree; chips' values end with
   the state (", working", ", needs you", ", finished, not seen yet"), and rows say it as before.
8. On a light theme the lift does nearly nothing (white over white); untried.
9. "Nothing for a pane with no agent" (attention-ui.md open point 1) is kept: a long-running command
   or an unsaved file shows no mark.


## Step 6: moving panes and tabs

**Status:** built on `design/step6-moving` (from `design/step5-pane-indicator`, which is on step 4;
neither is in main yet), ready for review. The UI tests didn't run: mac-air-2's screen was locked
for every run (see "Not verified"). They are written and need one run on an unlocked screen.

**What changed**

- Keyboard moves (`UmiPaneMove.swift`): hold ⌃⌘ and press an arrow. ←/→ move the focused pane one
  place among the panes on show of the tab it is over; ↑/↓ carry it to the tab above or below in
  sidebar order, wrapping, its own tab included and a new tab last. Letting go of ⌃⌘ (or any other
  key, or a click) lands it; Esc cancels; ⌘Z undoes the landed move. Window ▸ Move Pane has the four
  items (Move Pane Left / Right / to Tab Above / to Tab Below, ids `pane.move_left|right|up|down`);
  from the menu, or without ⌃⌘ held, a step lands at once.
- The preview is the real layout: each step puts the window back as it was and makes the move with
  `UmiLayout.move`, with events muted (`UmiEvents.muted`, new), hiding and showing quiet and undo
  registration off; landing puts the window back and makes the same move for real, so it lands
  exactly as shown, reported once (`pane.moved`, and `pane.hidden` for a pane hidden to make room)
  and undoable. A refill during a quiet step no longer reports a `pane.shown` later.
- The sidebar during a move (`UmiSidebar`, `UmiMoveRowPanes`): it comes out even when hidden, shows
  the tabs whatever view it was in, and every row lists its tab's panes with their indicators (on
  show in layout order, the moving pane in the prototype's cyan, a pane the landing would hide struck
  through "→ hidden", hidden ones in italics "· hidden"). The target row is outlined in cyan, the
  source row dimmed; a "New tab" row stands at the end until the pane is over it. Rows' accessibility
  values list their panes and say "moving here" / "moving from". A collapsed tab group opens while
  the pane is over one of its tabs.
- ⌃⇧↑ / ⌃⇧↓ move tabs (were ⌃⇧← / ⌃⇧→); Ghostty's `jump_to_prompt` on those keys is unbound (⇧⌘↑/↓
  still jump).
- ⇧⌘[ is Warp's previous tab in sidebar order (Window ▸ Show Previous Tab, id `tab.previous`).
  `tab back`, the RPC `tab.back` and the walk back through the tabs visited are gone
  (design/cli.md choice 11); `UmiTabHistory` stays only for the palette's recent tabs.
- Keyboard resizing of splits is gone: ⌃⌘↑/↓ unbound like ⌃⌘←/→, Ghostty's Move Divider menu items
  hidden. ⌃⌘←/→ no longer move the pane to the previous or next tab. `pane resize` stays (CLI only).
- L-19's hand-placed divider rules are gone (`SplitTree`): a dragged divider changes only the two
  panes beside it, as in Warp; splits and closes still share space equally / in proportion. The
  `placed` flag, `splitRowDrag` and the unused trailing-panel code went; layouts saved with `placed`
  still load.
- Step 5's review finding: `UmiAttention.looked(atPane:)` now bumps `revision` whenever what makes the
  pane unseen changes (its agent's change or its coming back on show), not only when the agent's mark
  changes, so a look from app activation or a window becoming key redraws the overlay, chips and rows.
- `debug.move` reports the move going on (pane, source, target, spot, `hid`, each row's pane list);
  `debug.key` with `hold` also holds ⌃⌘ and `debug.release` lands; `debug.menu` names ↑/↓.
- SPEC: new section KM (KM-1 to KM-5, fixed tier); L-9, L-11, L-13, L-19 and M-4 reworded. CLI.md:
  `tab back` removed, keys named on `tab next|prev`, `tab move --up|--down` and `pane resize`.
  CHECKS.md: L-9 and a KM-3 check. TEST_CHANGES.md lists every added, changed and removed test.

**Verified, and how**

All runs are on mac-air-2, in `~/umi-test-design-step6`, under `lockf -k ~/umi-screen.lock`. The
screen was locked for every run (`CGSSessionScreenIsLocked` true), so every UI test was skipped.
Builds pass `CODE_SIGN_IDENTITY=-` to xcodebuild; the suite and Swift runs use the same local,
uncommitted `app/dist/signing.sh` edit as steps 4 and 5 (`~/umi-test-design-step6-{build,suite,swift}.sh`).

- Dev copy (the Debug build, started as `app/dist/dev.sh` starts it, with its own state and config),
  driven by `~/umi-test-design-step6-trial.py`: 31 of 31 checks read back at `4691af90b`
  (`~/umi-test-design-step6-trial.log`), and again with the Debug build of `419963633` (the app code of the final head; `~/umi-test-design-step6-trial2.log`);
  screenshots in `~/umi-test-design-step6-shots`. Keys went through `debug.key` (⌃⌘ held with `hold`,
  let go with `debug.release`), read back with `debug.move`, `ls --json` and `log`. Tried: ⌃⌘→ from
  the middle pane (target its own tab, spot 2, sidebar out, the layout alpha gamma beta, rows listing
  panes with the moving one marked, no `pane.moved` yet); → at the end staying; ← ← to the first
  place; ⌃⌘↓ over a two-pane tab (shown, the pane at its right end, source row marked); ⌃⌘↓ over a
  full tab (one pane hidden in the preview and listed as hiding,
  `3-move-over-C-full.png`); ← then letting go (landed as shown, one `pane.moved` caused by the key
  `ctrl+cmd+right`, one `pane.hidden`, the sidebar hidden again); Edit ▸ Undo (both back); Esc after
  two steps (everything as it was, focus on the pane, no move); ⌃⌘↑ from the first tab wrapping to the
  new tab and landing there (a tab of its own, last); ⌃⌘← without `hold` and Window ▸ Move Pane ▸ Move
  Pane Right (each lands at once); a lone pane (no new-tab target); a collapsed group opening while
  the pane is over its tab and closing after; ⌃⇧↑ / ⌃⇧↓ moving the tab; ⇧⌘[ / ⇧⌘] in sidebar order;
  `tab back` failing ("unknown subcommand back") and gone from `help`; `shortcuts` listing the four
  move items and no Ghostty `resize_split` key; `pane resize` still working.
- Acceptance suite, ReleaseLocal, full run at `49d25dfbe` (`~/umi-test-design-step6-suite-full.log`):
  398 passed, 7 failed, 93 skipped (UI tests: the locked screen). The 7 failures are the base
  failures below. `test_moving_panes.py`: 13 passed, 2 UI skipped. The first full run, at `20d1aca24` (its log was overwritten by the rerun below), gave
  398 passed, 7 failed, 93 skipped: six of the base failures below and
  `test_a_dragged_middle_divider_leaves_the_other_panes_alone`, whose drag to 45% stopped at the
  190-point minimum in the suite's ~930-point window (the product right, the numbers wrong); with the
  drag at 47% it passes (`~/umi-test-design-step6-suite-rerun.log`: `test_umi_panes_ui.py` and
  `test_moving_panes.py`, 49 passed, 7 UI skipped).
- The base failures (`test_builds_from_a_path_with_spaces`,
  `test_shift_cmd_f_leaves_a_terminal_search_open`, and five synchronized-input, pane-menu and zoom
  tests in `test_umi_warp_panes.py`; `test_option_command_i_types_into_every_pane_of_the_tab` failed
  in the second full run and passed in the first) are the ones steps 1 to 5 list; step 5 ran all
  seven on main's app code and they failed there too (`~/umi-test-design-step5-base.log`). None
  touches what this step changed.
- Swift unit tests at `20d1aca24` (`~/umi-test-design-step6-swift.log`): 428 passed, 1 skipped (a
  benchmark), none failed; among them the new `UmiIndicatorTests/aLookAtAPaneShownSinceBumpsTheRevision`
  and the rewritten `SplitTreeTests`.

**Found on the way (not fixed, pre-existing):** with the sidebar hidden, a closed pane's shell keeps
running after its 60 s reopen period ends. It showed when this step's tests hid the sidebar of the
shared instance (new windows then start without one) and
`test_closed_items_expire_after_60_seconds_and_their_programs_end` ran later. A minimal test (a window
with the sidebar off, a pane split, closed, waited out) fails the same way on step 5's build and on
main's app code (`71e39f857`, in `~/umi-test-design-step3`); with the sidebar on it passes. Something
in the sidebar-hidden layout holds closed panes; not looked into further. The step's tests now show
the sidebar again afterwards. The check is kept at `~/umi-test-design-step6-leak-check.py`. (That run
on main's code overwrote `~/umi-test-design-step3-suite.log` on mac-air-2.)

**Not verified**

- Every UI test (skipped: the locked screen). This step's two, for the orchestrator to run on an
  unlocked screen: `test_moving_panes.py::test_real_ctrl_cmd_arrows_move_and_land_on_release_ui` (real
  ⌃ and ⌘ held, ↓ and ←, landing on letting go, Esc while held) and
  `::test_the_rows_list_their_panes_to_accessibility_during_a_move_ui`; the changed
  `test_umi_nav.py::test_jump_and_move_tab_keys`, `test_umi_sidebar_warp.py::test_move_tab_keys_keep_groups_whole_ui`
  and `test_layout.py::test_shortcuts_are_menu_items`. So real ⌃⌘ released (the `flagsChanged` path),
  a real click landing a move, and how the sidebar's lists look to a person were never seen; the
  screenshots come from `<cli> screenshot`, which draws the real views.
- Steps 4 and 5's unrun UI tests still stand.
- The step 5 fix is checked by the Swift test (the revision bumps on a look that clears "shown, not
  seen"); a real app activation redrawing the overlay needs an unlocked screen.
- CHECKS.md items KM-3 and the new L-9 lines (by hand).

**Choices for Alejo to check**

1. Landing follows the pane: it keeps keyboard focus in its new tab, which stays shown. The
   prototype offered Enter (stay) and ⇧Enter (follow); the design lands on letting go of ⌃⌘, with
   no second key. Where: `UmiPaneMove.land`.
2. Over another tab the pane starts at the right end (the prototype started at the first place),
   matching where Umi brings panes in elsewhere; back over its own tab it starts where it was.
3. Places count among the panes on show without the one the landing would hide, so every ← / →
   visibly moves the pane; a place is "left of the first" or "right of pane k" in layout order, so in
   a tab with a column the pane is split in beside that pane rather than added as a new column.
4. ↑/↓ wrap around (as the prototype), and the targets are only the window's tabs, not other windows.
5. The new tab isn't offered to a pane alone in its tab (it would only move the tab to the end); a
   new tab made by a move goes last in the window.
6. The preview is the landed layout itself: the pane the landing would hide is hidden (the strip
   shows it hidden, its row strikes it through), where the prototype kept it as a narrow ghost.
7. Any other key or a click lands the move, as with the ⌘[ ⌘] walk; only Esc cancels.
8. Colours: the moving pane's name and the target row's outline use the prototype's cyan
   (`#3ad1e0`), though step 5 took the cyan focus line out; the source row is at 50%.
9. The sidebar shows the tabs view during the move even when Files or Search was showing, and goes
   back after. A sidebar search query still filters the rows (a hidden row is still a target).
10. A collapsed group opens while the pane is over one of its tabs, closes when it moves on or the
    move is cancelled, and stays open when the pane lands in it.
11. Ghostty's Move Divider menu items are hidden; `pane resize` stays. ⌃⇧↑/↓ took the keys of
    Ghostty's jump to prompt (⇧⌘↑/↓ still jump).
12. Menu ids changed: `tab.back` is now `tab.previous` (Show Previous Tab), and
    `pane.move_previous_tab` / `pane.move_next_tab` are replaced by `pane.move_left|right|up|down`.
    A user's `shortcuts.json` entries for the old ids no longer apply.
13. A dragged divider changes only its two neighbours (Warp); double-click equalizes its row and
    ⌃⌘= the whole tab, as before. Layouts saved with the old `placed` flags still load.

## Step 7: the drawer

**Status:** built on `design/step7-drawer` (from `design/step6-moving`, on steps 4 and 5; none of them
is in main yet), ready for review. The UI tests didn't run: mac-air-2's screen was locked for every run
(see "Not verified").

**What changed**

- The drawer (`UmiDrawer.swift`; prototypes/drawer.html, option B): each window has one, over the
  lower 52% of its panes at their full width, without changing the tab's layout. Its header has a chip
  per drawer pane (indicator and name; a click shows it) and Dock, Hide and Put away. A pane sent there
  leaves its tab (no strip chip, not counted toward `visible_limit`), keeps running, and is listed under
  the window's `drawer` in `ls --json` with `in_drawer: true` (the attribute too); queries, `go`, the
  Dock badge and `pane focus` see it (focusing it opens the drawer on it). Opening focuses the drawer's
  pane; closing gives focus back to the pane focused before. It is saved with the layout and comes back
  closed.
- CLI (design/cli.md, "Drawer"): `drawer show [PANE]`, `hide`, `toggle [PANE]`, `next|prev`,
  `dock [PANE]`, `ls`, all with `--window`. `pane hide` of a drawer pane puts it back hidden in the tab
  it came from (the current tab when that one is gone); `pane move` takes it out; `pane close`, or its
  program ending, ends it; split, zoom, swap and resize refuse it (exit 1). Events `drawer.opened`,
  `drawer.closed`, and `pane.moved` with `to`/`from` `{"window", "drawer": true}`.
- ⌃⌘M runs `drawer toggle @manager` (choice 15): Window ▸ Drawer ▸ Show or Hide Manager, id
  `drawer.manager`; a `key.ctrl+cmd+m` config line replaces it. Window ▸ Drawer also has Show or Hide
  Drawer, Move Pane to Drawer, Dock Drawer Pane, Next / Previous Drawer Pane (no keys). ⌘[ ⌘] with a
  drawer pane focused go through the drawer's panes.
- The waiting line: while the drawer is closed, a drawer pane whose indicator is "needs you" shows a
  3-point amber line along the bottom edge of the panes with "NAME · needs you" (+N) at its right end;
  clicking the label opens the drawer on it.
- Screenshots (`<cli> screenshot`) draw the drawer, its waiting line and the keyboard move's marker over
  the terminals' images, as they draw the pane indicator.
- Step 6's review:
  - (a) The moving pane is outlined in the prototype's cyan with a "moving here" tag at its bottom left
    (move-literal.html option A), and its strip chip is cyan (`UmiPaneMoveMarker`, `UmiStripChip`).
  - (b) Previews no longer record tabs and panes passed over: `UmiTabHistory` and `UmiFocusHistory`
    pause for the move; only the landing is recorded (after it), and Esc leaves both as they were.
  - (c) The move lands when Umi resigns active or its window stops being key, and a pane closing
    mid-move ends the move with every tab put back as it was, without that pane (restore first, then
    finish).
  - (d) With the sidebar hidden, a closed pane's shell ran on past its 60 s. SwiftUI kept the closed
    pane's view until the window's views next changed (any later change in that window, a split or the
    sidebar coming back, freed it; nothing in Umi's own code held it). Now when a reopen entry expires,
    a pane still alive a second later, in no window and no tab, ends its terminal
    (`SurfaceView.umiEndTerminal`, which frees the surface as deinit would).
- SPEC: new section DR (DR-1 to DR-5, fixed tier), ⌃⌘M in L-9, KM-3 (the marker) and KM-4 (landing on
  resign, the pane closing, the histories). CLI.md: the Drawer section, the window's `drawer`,
  `pane.moved` to or from a drawer; it now covers all of design/cli.md. TEST_CHANGES.md lists every
  added and changed test.

**Verified, and how**

All runs are on mac-air-2, in `~/umi-test-design-step7`, under `lockf -k ~/umi-screen.lock`. The
screen was locked for every run (`CGSSessionScreenIsLocked` true), so every UI test was skipped. Builds
pass `CODE_SIGN_IDENTITY=-`; the suite and Swift runs use the same local, uncommitted
`app/dist/signing.sh` edit as steps 4 to 6 (`~/umi-test-design-step7-{build,suite,swift}.sh`).

- Dev copy (the Debug build of `334f57a84`, started as `app/dist/dev.sh` starts it, with its own state
  and config), driven by `~/umi-test-design-step7-trial.py`: 41 of 41 checks read back
  (`~/umi-test-design-step7-trial2.log`; screenshots in `~/umi-test-design-step7-shots`). Keys went
  through `debug.key`, menu items through `debug.menu.perform`, read back with `ls --json`, `drawer ls`,
  `debug.drawer`, `debug.move`, `debug.navigation`, `log` and `read`. Tried: ⌃⌘M with a `role=manager`
  pane (it left its tab, the drawer opened over the lower half at the panes' width, focused it,
  `pane.moved` caused by the key, `drawer.opened`; `1-drawer-open.png`), `ls` text, ⌃⌘M again (closed,
  focus back on beta, the manager still running); `drawer show` with and without a pane, `hide`,
  `toggle` (closing, opening, switching), `next`, `prev`, `ls` (JSON and text), ⌘] in the drawer;
  the waiting line ("epsilon · needs you", `4-waiting-line.png`) and its going away when the drawer
  opens; `drawer dock` (right of the tab's focused pane, focused, the drawer closed, `pane.moved` from
  the drawer); Window ▸ Drawer ▸ Move Pane to Drawer, Previous / Next Drawer Pane, Show or Hide
  Drawer (both ways), Dock Drawer Pane; Window ▸ Hide Pane on a drawer pane (back hidden in its tab);
  `split` on a drawer pane refused; `pane focus` opening the drawer; `pane move --tab` taking it out;
  `help` and `shortcuts`; a keyboard move's cyan chip and outline (`5-moving-marker.png`), Esc leaving
  both histories as they were, landing on a simulated resign-active and resign-key (the landing
  recorded, tab B then A), the moving pane closed mid-move; a restart bringing both drawer panes back
  in the closed drawer; and, with the sidebar hidden, a closed pane's shell ending after its 60 s.
  The first trial run (`~/umi-test-design-step7-trial.log`, 39 of 41) found dock using the pane focused
  before the drawer opened rather than one focused since (fixed in `e85bb201f`) and a
  wrong expectation in the script.
- Acceptance suite, ReleaseLocal, full runs:
  - at `5534e9991` (`~/umi-test-design-step7-suite-full1.log`): 414 passed, 8 failed, 94 skipped. Seven
    are the base failures below; the eighth was this step's histories test, which compared the whole
    tab history while other tests' tabs drop out of it as they close (fixed in the test, see
    TEST_CHANGES.md; the claim checked is unchanged).
  - at `334f57a84` (`~/umi-test-design-step7-suite-full2.log`): 402 passed, 10 failed, 11 errors, 93
    skipped. The 11 errors and 3 of the failures are the update and install tests, broken by my own
    Debug build started on the same worktree during the run (its script restored `signing.sh`, so
    `release.sh` refused to sign ad hoc); rerun alone, `test_install.py` and `test_umi_extra.py` give
    37 passed, 1 skipped (`~/umi-test-design-step7-suite-rerun-updates.log`). The other 7 are the base
    failures. This step's tests: `test_drawer.py` 11 passed, 1 UI skipped; `test_moving_panes.py` 18
    passed, 2 UI skipped; the sidebar-hidden expiry test passed.
- The base failures: `test_builds_from_a_path_with_spaces`, `test_shift_cmd_f_leaves_a_terminal_search_open`
  and five synchronized-input, pane-menu and zoom tests in `test_umi_warp_panes.py`, the same as steps
  1 to 6 list. Run on main's app code (`71e39f857`, `~/umi-test-design-step3`), `test_umi_warp_panes.py`
  and the ⇧⌘F test fail the same way (`~/umi-test-design-step7-base-main.log`: 6 failed, 13 passed).
  Which of the two ⌥⌘I tests fails flips between runs (`…types_into_every_pane_of_the_tab` or
  `…in_a_one_tab_window_leaves_tabs_opened_later_out`), on main as here
  (`~/umi-test-design-step7-warp-panes.log`). None touches what this step changed.
- Swift unit tests at `334f57a84`'s code (`~/umi-test-design-step7-swift.log`): 428 passed, 1 skipped
  (a benchmark), none failed.
- Step 6's leak (d): `leaks --traceTree` on the closed pane's view found no owner in Umi's code; with
  the sidebar hidden it stayed alive (retain count 7) until any later change of the window's views (a
  split, the sidebar shown), which freed it. After the fix the shell ends at 61 s with the view still
  alive (`~/umi-test-design-step7-leak.py`, temporary instrumentation not committed).

**Not verified**

- Every UI test (93, skipped: the locked screen). This step's, for the orchestrator to run on an
  unlocked screen: `test_drawer.py::test_real_ctrl_cmd_m_and_the_drawers_buttons_ui` (real ⌃⌘M, typing
  into the drawer, the Put away and Dock buttons) and the changed `test_layout.py::test_shortcuts_are_menu_items`
  (⌃⌘M added). Steps 4 to 6's unrun UI tests still stand (step 6:
  `test_moving_panes.py::test_real_ctrl_cmd_arrows_move_and_land_on_release_ui`,
  `::test_the_rows_list_their_panes_to_accessibility_during_a_move_ui`,
  `test_umi_nav.py::test_jump_and_move_tab_keys`, `test_umi_sidebar_warp.py::test_move_tab_keys_keep_groups_whole_ui`).
- Never seen on a live screen: the drawer rising and its clicks (chips, Dock, Hide, Put away, the
  waiting line's label), real ⌃⌘M, and a real resign-active or key-window change during a move (both
  simulated by posting AppKit's notifications through `debug.move`). Screenshots come from `<cli>
  screenshot`, which draws the real views.
- Whether the closed-pane leak (d) happens on an unlocked screen at all, where the window's views update
  every frame; the fix holds either way.

**Choices for Alejo to check**

1. A drawer pane is listed under its window, not in a tab; where a query result or `pane info` needs a
   tab (`ls --where`, `UMI_TAB` for a command run from it), it gets the tab the drawer is over (the
   window's selected tab). Where: `UmiTopology.locate`, `placedPanes`.
2. ⌃⌘M with no pane holding `role=manager`: an open drawer is put away, otherwise it beeps and nothing
   moves (the design's "when nothing matches, Umi says so"; there is no on-screen note). Where:
   `UmiDrawer.toggleManager`.
3. `drawer show QUERY` and `drawer toggle QUERY` move every match into the drawer and show the first
   (design/cli.md choice 3: commands that change panes act on every match).
4. Dock, Hide and a drawer pane's program ending put the drawer away, as in the prototype; `drawer
   next|prev`, `pane focus` and `go` open it. Focus goes back to the tab's own focused pane (the one
   focused before the drawer took focus, or one focused since while it stayed open), and dock puts the
   pane to the right of that pane.
5. Only ⌃⌘M has a default key. The other drawer actions are Window ▸ Drawer items without keys
   (attention-ui.md leaves "keys for sending other panes to the drawer and cycling" open); ⌘[ ⌘] go
   through the drawer's panes while one is focused, standing in for the prototype's [ and ].
6. The window's only pane can't go into the drawer (exit 1: the drawer belongs to the window); a pane
   that was its tab's last closes that tab.
7. The drawer's height is the prototype's 52% of the panes, fixed (no setting); its header's "D · H"
   hint became three clickable words: Dock, Hide, Put away.
8. Drawer panes come back after a relaunch with the drawer closed. A window closed with panes in its
   drawer ends them (⇧⌘T brings the window back without them), and a closed drawer pane can't be
   reopened, as for hidden panes. Launch configurations (`layout save`) leave drawer panes out.
9. Moves into and out of the drawer aren't undoable (⌘Z doesn't put a pane back in or out); a later
   undo that brings a drawer pane back into a tab takes it out of the drawer. `pane move` of a drawer
   pane goes through the right end of the current tab, so its `pane.moved` names that tab as `from`.
10. The waiting line spans the window's panes (not the sidebar), shows while any drawer pane needs you
    and the drawer is closed, and its label opens the drawer on the first waiting pane.
11. Step 6 review (c): Umi resigning active or the window stopping being key lands the move (as any
    other key or a click does) rather than cancelling it; the pane closing mid-move cancels without it.
12. Step 6 review (d): the fix ends a closed pane's terminal explicitly one second after its reopen
    period ends, when its view is still alive but in no window and no tab. The SwiftUI reference that
    kept it alive wasn't pinned down (leaks shows no strong owner in Umi's code; any later update of
    the window's views releases it).

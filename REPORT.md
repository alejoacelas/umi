# Tern 0.5.0: Warp's look for terminals, the sidebar order (BRIEF-blocks.md)

The earlier parts follow, unchanged. Tern 0.5.0 is released and your installed copy has updated itself
to it.

## What changed

**Warp's look for terminals** (SPEC S-9 to S-12), as you chose: an imitation that keeps the shell
underneath. zsh edits the command line as before (zsh-autosuggestions included); Tern changes how the
terminal looks.

- **At the bottom.** The prompt sits at the bottom of the pane from the start, and output builds upward
  above it. It stays there after `clear` and ⌘K; a completion list below the command line is shown.
  With more than a screenful the pane scrolls as usual.
- **Blocks.** Each command and its output form a block: a grey header with the folder it ran in and how
  long it took in Warp's format (`(0.041s)`, `(1m 8.92s)`; while it runs, the seconds so far), the
  command in bold, its output after a small gap, and a thin line with space between blocks. A command
  that exits with an error gets Warp's mark: the theme's red at 10% over the block and a 5-point red bar
  on its left edge. Colors and spacing come from Warp's source (`~/dev/warp`, read only).
- **The folder box.** At the prompt, a small rounded box with an outline folder icon and the current
  folder (`~` for home).
- **Left out**, as you said: the "Lines: … Size: …" readout, Warp's input editor, block selection and
  actions.
- **Where it applies.** Only in Tern's own terminals running zsh; other terminals and zsh started
  anywhere else keep your prompt; other shells keep the usual look; full-screen programs (vim, an
  agent's full-screen interface) take the whole pane with no decorations. Programs and agents that read
  a pane (`tern read`, `tern wait --pattern`) see what the shell printed (two blank rows, the folder,
  the command line) and never what Tern draws. `shell-integration-features = no-tern-blocks` in your
  Ghostty config turns it off.

How: Tern's zsh integration prints the prompt as two spacer rows, the folder and an empty command
line, marked as a block (OSC 133); the terminal records each block's state, failure and duration on
its first row; the renderer moves the whole view down so the last used row sits at the bottom, and
draws the header, the bold command, the lines, tint, bar and folder box itself (a small Metal pipeline).
The mouse, selections and the input-method position follow what's drawn.

**The sidebar order** (S-7), in your words: "other than the focused session, tabs should only move
when an agent finishes their turn". Selecting a tab moves it to the top (after pinned tabs); the tab you
leave stays where it is; a tab whose agent stops moves to just below the current one. Nothing is
re-sorted any more.

**Left over from 0.4.0:**
- The live-launch test that saw the interface while the session said `starting`: the product was
  right, and the test had two races. After the first turn a session says `starting` while it opens its
  own interface, and again until the interface's start-up hook reaches Tern; under load the test read
  the screen in those gaps. It now checks the order of events and waits for the status to settle.
- ⇧⌘T is in the shortcut list ⌘, edits (and `tern shortcuts`).
- The suite leaves your `~/.claude`, `~/.claude.json` and `~/.codex` as it found them: what the
  real-agent tests add for the suite's own folders (trust entries, transcripts, Codex threads, history
  lines) is removed after the run, nothing else.
- Found by the suite on the way: a Codex message could be sent again and again after a crash (start,
  stop, then a message that crashes Codex: up to 39 deliveries). Fixed: Tern now checks the thread it
  wrote to before sending again.
- Found by the final run: a harness process that outlived its session (the session removed while the
  process was still exiting) was never reaped and stayed a zombie of the app. Tern now reaps it.

Code: app commits after `dd1bc8d31` (the look: `src/renderer/tern_blocks.zig`, `src/renderer/generic.zig`,
`src/renderer/shaders/shaders.metal`, `src/terminal/{page,Terminal,Screen}.zig`, `src/termio/`,
`src/Surface.zig`, the zsh integration; the order: `TernNavigation.swift`; ⇧⌘T: `TernShortcuts.swift`,
`TernReopen.swift`; the Codex fix: `TernCodexDriver.swift`, `TernAgentSession.swift`; the zombie:
`TernHarnessProcess.swift`).

## Decisions

Details, candidates and evidence: DECISIONS.md §60–§65.

| # | Decision |
|---|---|
| 60 | The blocks live in rows the shell prints (two spacers, the folder, the command line), and the renderer draws over them; nothing Tern draws is text. Per-block state, failure and duration ride on the block's first row (spare row bits), so they follow scrolling, reflow and clearing. "At the bottom" is one view offset per frame, applied to everything drawn and to the mouse. Nested shells keep their parent's block open, matched by OSC 133 `aid`. |
| 61 | Warp's numbers from its source; spacing scaled into whole rows (text drawn a little above its row keeps Warp's half-line gap before output); header and box text at the terminal's size. |
| 62 | Only zsh with Tern's integration (decided at spawn, or by Tern's own prompt mark), never other shells or terminals; full-screen programs untouched; the folder shortened to fit beside the box's icon. |
| 63 | Lines, tint, bar and box: a small Metal pipeline (rounded rectangles) under the text; the debug overlay was too costly to keep on. |
| 64 | Sidebar: selecting moves the selected tab to the top; an agent stop moves its tab to just below it; nothing else moves; hand placements hold. |
| 65 | The flaky live test (two races, both in the test), ⇧⌘T as a shortcut item, the suite's cleanup of your agent folders, and a Codex resend found by the suite. |

## Tests

- **The definitive run**, on the build that was released, with the real agents (Claude `haiku`, Codex
  `gpt-6-luna` at low effort): `ACCEPTANCE_REAL=1 uv run pytest --target targets/tern.json` under
  `caffeinate -d -i`: **390 passed, 0 failed, 21 skipped** (26 minutes, `logs/b-suite-definitive2.log`).
  The run before it, on the first release build, had 389 passed, 1 failed and 1 error
  (`logs/b-suite-definitive.log`). The failure was `test_no_zombies_accumulate`, which led to the zombie
  fix above. The error was a teardown whose `tern agent stop` took over 60 s (see "Open" below). The
  release was rebuilt with the fix and the whole suite run again. The 21 skipped are exactly the 21 UI tests: the screen was
  locked all afternoon and evening (checked with `conftest.py`'s `screen_locked()` before every review
  round and before the release), so they didn't run, and they are not counted as passing. Among them is
  the new real-mouse test of selections in a moved view.
- **New tests:** `test_tern_blocks.py` (23: at the bottom from the start, output building up, `clear`
  and ⌘K, a completion list, blocks with folder, duration and output, a running block's time, the
  failed block's tint and bar, the lines between blocks and the bold command measured on screenshots,
  the folder box and long folders, full-screen programs, other shells, readers, `no-tern-blocks`, zsh
  sourced by hand, nested shells, wide characters, padding, and one UI test); the S-7 tests rewritten
  to your rule; ⇧⌘T in the shortcut list; `test_suite_hygiene.py` (the agent-folder cleanup); review
  regressions (`test_review_agents.py`, including the Codex resend, which fails on the build before the
  fix with 39 deliveries); Zig unit tests for durations, wrapped folders and nested shells.
- **Changed tests**, none weakened (TEST_CHANGES.md, last part): the old S-7 order test (the
  requirement changed); the live-launch test (two races in the test, the brief's flaky failure); a
  redirect test that assumed a steered message couldn't share the redirect's turn; a test that waited
  for `%` or `$` on screen; the zombie test, which now fails on a zombie still there 5 s later (a
  process is briefly a zombie between its exit and its reaping) and names it.
- **Written checks** (CHECKS.md): S-9/S-10/S-11 (blocks, the bottom, the folder box) and S-12
  (full-screen programs) PASS, judged against `reference/warp-blocks.png` from `tern screenshot`s of the
  released build (`acceptance/results/checks/S-9-S-10-S-11-blocks.png`, `S-12-full-screen.png`); S-7
  re-judged under your rule; the rest as before.
- **Your agent folders:** after the real run, the suite removed what its sessions added for its own
  folders, and nothing else (`acceptance/results/agent-folders-cleanup.txt`). That was 23 items. From
  Codex: the trust entry for the live test's folder in `config.toml`, 6 threads (their rollouts and
  their rows in `state_5.sqlite` and `logs_2.sqlite`), and one index line. From Claude Code: 5 project
  folders, one transcript in a folder that was already there, one history line and 6 per-session
  folders. Afterwards neither `~/.codex/config.toml` nor `~/.claude.json` has an entry for the suite's
  folders.

## Codex review

`codex review --base e1b23c57f -c model_reasoning_effort="high"` (the base covers 0.4.0's last fixes
too), logs `logs/b-review1.log` to `b-review10.log`. Every finding was fixed, with a regression test
where a test could reach it, and the suite rerun (no failures) before the next round.

| Round | High | Moderate | What they were about |
|---|---|---|---|
| 1 | 0 | 4 | bold drawn through cached styles, the mouse on moved text, PS2 growing on empty Enters, a long folder above the view |
| 2 | 0 | 3 | a long folder past the pane's edge, selection highlights on the folder box, OpenGL |
| 3 | 0 | 1 | zsh's integration sourced by hand |
| 4 | 0 | 2 | a message waiting when `claude --resume` is typed by hand, nested shells |
| 5 | 0 | 3 | the folder after a resize, the selected tab moved by hand, stops below a placed tab |
| 6 | 0 | 1 | drag selection over the folder box |
| 7 | 0 | 1 | selection autoscroll in a moved view |
| 8 | 0 | 1 | wide characters in `debug.blocks` |
| 9 | 0 | 1 | the top padding's color after the view fills |
| 10 | 0 | 0 | none |

The loop stopped at round 10, which found nothing. Not covered by a test: the bold copy of a styled
command row (by construction), and selection autoscroll (needs a real drag past the pane).

## Release

- **Tern 0.5.0** is published at https://github.com/alejoacelas/tern/releases/tag/v0.5.0 (latest).
  It holds `Tern-0.5.0.zip` (the app, ad-hoc signed), `appcast.json` (SHA-256 and Ed25519 signature)
  and `install.sh`. `app/dist/release.sh` made them from app commit `972c2f68f`, the build the final
  run tested. Nothing else was published: no source, `acceptance/`, `reference/`, logs or keys. The
  repository's README has a new "Command blocks" paragraph, including how to turn the look off
  (committed with your GitHub noreply address).
- **The copy installed on this Mac updated itself.** Its `tern update` (your yes) downloaded 0.5.0, and
  `tern update --now` installed it and relaunched. No agent turn was running: your shells were idle,
  and your one Claude session had been idle since 11:20. Now `tern --version` → 0.5.0, the signature
  verifies, there's no quarantine, and `update --check` → up to date. Both windows came back with all
  6 tabs and 10 panes, with their names and folders.
- **Your Claude session** (the one you typed in window 1's first tab, titled "hi") came back in its
  pane. It's waiting at Claude Code's question about trusting the files in `~`. Claude Code asks this
  whenever it starts in your home folder, because it keeps no trust for `~`
  (`hasTrustDialogAccepted: false` in `~/.claude.json`, which the suite didn't touch). I left the
  answer to you. Once you answer, the session continues.

## Not done, and open

- **The UI tests didn't run.** The screen was locked all afternoon and evening. I checked
  `screen_locked()` before every review round and before the release, so all 21 UI tests were skipped
  each time. They are not counted as passing. They include the new real-mouse test of a selection in a
  moved view and the test for ⇧⌘T in the shortcut list. With the screen unlocked, this runs them:
  `cd ~/dev/terminal-3/acceptance && caffeinate -d -i uv run pytest --target targets/tern.json -m ui`.
- **`tern agent stop` took more than 60 s twice in about 14 full runs**, both times in a test's
  teardown with the screen locked (the second time in the first final run, after
  `test_placement_options_never_swallow_the_prompt[flags0]`). It didn't happen when that test was
  rerun, while a sampler watched for it, or in the final run. I didn't find the cause.
- **Disk space.** The disk nearly filled during the run (down to 283 MB free). I freed space only from
  what this run had made: the Zig build cache in `app/.zig-cache`, which grows back to about 8 GB with
  every build, and the suite's temporary folders.

## Questions for you

1. **Your prompt.** While the look is on, Tern's zsh shows the folder header and an empty command line
   in place of your PS1 (Warp ignores PS1 by default too). Keep it that way, or show your PS1, or part
   of it such as a git branch, in the header?
2. **Empty Enter.** An empty Enter or Ctrl-C at the prompt leaves an empty block (a header with no
   command), as zsh leaves a prompt line. Warp makes no block for these. Should Tern hide them?
3. **`clear`.** Tern's `clear` clears the screen, as zsh's does. Warp's pushes the blocks up out of
   view and keeps them in scrollback. Keep zsh's?
4. **"Last login".** The line `login` prints when a pane opens shows above the first block; Warp hides
   it. An empty `~/.hushlogin` hides it in every terminal, but I didn't create one in your home folder.
   Should Tern hide the line itself, or should I create the file?
5. **Older test leftovers in your agent folders.** The suite now cleans up after itself. Runs before
   this one (October 7 to October 11 at 02:53, before the cleanup existed) left 47 folders in
   `~/.claude/projects` (23 MB). All are named after the suite's temporary folders or
   `acceptance/.work-real`. They also left 112 Codex threads in `~/.codex/sessions` for those folders.
   I left them in place because they predate this brief, and your agent folders are otherwise off
   limits. Should they be removed?
6. **The questions in the 0.4.0 part below** are still open. Their current behavior is kept, as the
   brief said.

# Tern 0.4.0: agent sessions redone, and the app changes you decided (BRIEF-agents.md)

The earlier parts follow, unchanged. Phase 2's orchestrator guide among them is superseded by the one
at the end of this part (steering replaced queued follow-ups; `--drop-queued` is gone). Tern 0.4.0 is
released and your installed copy has updated itself to it.

## What changed

**Agent sessions** (SPEC.md AG-1 to AG-23, replacing MA, AP, IA and R-1, R-2, R-8 to R-10):

- **Always run headless, shown when asked.** `tern agent start claude|codex "TASK"` runs the agent
  headless (Claude's stream-json mode; a private `codex app-server` per session on a Unix socket).
  Nothing appears on screen. `tern agent open S` shows a session read-only in a pane: the
  conversation, tool activity, status, approval and question cards, and a **Take Over** button.
- **Live and back.** Take Over (⌃⌘O, or `agent open S --live`) runs the agent's own interface in
  that pane on the same conversation, at once. Claude's headless process stops first: one process
  per conversation, always. Codex's interface attaches to the session's own server. When the
  interface quits, the session is headless and idle again, and the pane shows the read-only view.
  ⌃⌘W (`agent hide`) takes a session out of its pane without stopping it; a live interface finishes
  its turn out of sight first.
- **Easy launch for yourself.** `tern claude "TASK"` (or `agent start … --tab|--split|--new-window`)
  runs the first turn headless in a new pane, then opens the agent's own interface there once the
  session has settled (background work included). With no task it opens live at once.
- **Messages reach live sessions.** Codex: through its server. Claude: when its interface is idle
  and nothing is typed there, Tern takes the session back, runs the messages headless, and brings
  the interface back in the same pane. Text typed, pasted or sent with `tern send` holds them back.
- **Supervising and steering.** A message to a working session steers the running turn (Claude's
  injection, Codex's `turn/steer`), each delivered exactly once, `--interrupt` goes first. `agent
  wait` waits until the session has settled (Warp's "every stop is done" bug avoided). Also:
  `watch --notify`, `report`, and `ls --parent self`.
- **Observability as Warp does it, without its failures.** Tern's plugins for Claude Code and Codex
  report hooks to the app through Tern's CLI over its socket, not through the terminal. They stay
  silent outside Tern and in headless sessions. The app installs and updates them in your own
  `~/.claude` and `~/.codex` at launch, as you approved. `claude`/`codex` typed in a pane become
  sessions Tern knows.

**The app changes you decided** (SPEC.md L-9 to L-20, M-4, S-3, S-4, S-7, S-8, E-10):

- Sidebar rows show the folder, then the session's title, with a quiet Claude or Codex mark that
  takes a muted color when a session finished and you haven't looked, or needs you. Looking clears
  it. There are no desktop notifications. The Dock badge counts the sessions that need you.
- Sidebar order: pinned tabs, then the current tab, then by last agent stop. Repeated presses walk
  the list before it re-sorts.
- Keys:
  - ⌘, Settings, where shortcuts are edited.
  - ⇧⌘[ back, ⇧⌘] and ⌃Tab next, ⌘1–9, from anywhere.
  - ⌃⌘J the next session that needs you, ⌃⌘K back.
  - ⌃⇧←/→ move the tab.
  - ⇧⌘T reopens a closed pane, tab or window in place for 60 s.
- Palettes: ⌘O quick open; ⌘P a command palette built from `tern help --json`, so it follows the
  CLI; ⇧⌘P panes, most recent first.
- Panes share their row equally, as in Warp. Panes can be dragged onto sidebar rows or between them;
  a tab dragged out of the window makes a new window. Each window has its own sidebar width. Rows
  have Warp's right-click menu. Markdown files open in the closest folder's tab.

Code: app commits after `2fa4d48ed` (agents: `Sources/Features/Tern/Agents/`, `TernPlugins/`, `TernCLI/agent.swift`;
the app changes: UI-A and UI-B merges, `TernNavigation*`, `TernTabOrder`, `TernReopen`, `TernSidebar*`,
`Command Palette/TernPalette.swift`, `TernShortcutStore.swift`).

## Decisions

Details, candidates and evidence: DECISIONS.md §20–§59.

| # | Decision |
|---|---|
| 20 | Control is always headless: each agent's own headless protocol (Claude's stream-json; a private Codex app server per session on a Unix socket, spoken over WebSocket). |
| 21 | Live is the agent's own interface started by one line Tern types, `"$TERN_CLI" agent attach S`; Claude's headless process stops first, Codex's interface attaches to the session's server. Typed only when the pane's shell has its terminal. |
| 22 | Messages to a live Claude wait until its interface is idle with nothing typed, then run headless and the interface comes back. Codex goes through its server. |
| 23 | Steering by default, every message delivered exactly once (Claude's `cancel_queued`, Codex's thread items checked after a crash). |
| 24 | "Finished" means settled: background work that will wake the agent keeps it working (Warp's bug). |
| 25 | Observability through Tern's own plugins and CLI over the socket, not terminal escape sequences (where Warp's status broke on agent updates). |
| 26 | ⌃⌘W removes a session from its pane; a working interface finishes out of sight first. |
| 27 | The CLI is written for agents with no instructions: one screen of help, a worked example, errors that say what to do. |
| 28, 59 | No desktop notifications; `stopped` means someone stopped it (a session with no process is idle); the Dock badge counts sessions that need you; a turn running in the interface continues after a quit; one interface per conversation everywhere. |
| 29–58 | The app changes (UI-B §29–46, UI-A §47–58): equal panes, reopen, row menu and drops, sidebar width, order (pins, then the current tab, then last agent stop; placements hold about a second), shortcuts from anywhere through a key monitor, palettes from `tern help --json`. |

## Tests

- **The definitive run**, on the build that was released, with the real agents (Claude `haiku`, Codex
  `gpt-6-luna` at low effort): `ACCEPTANCE_REAL=1 uv run pytest --target targets/tern.json` under
  `caffeinate -d -i`: **359 passed, 0 failed, 20 skipped**. The 20 skipped are exactly the 20 UI tests:
  the screen was locked throughout (checked with `conftest.py`'s `screen_locked()` before every review
  round and before the release), so they didn't run. They are not counted as passing. What they cover
  was also checked without the accessibility tree: `verify_ui_paths.py` 56/56 and
  `verify_agent_panes.py` 17/17, plus the internal `debug.*` methods the scripted tests use.
- **A final run** on the source as it is now (with the plugin fixes made after the release), the same
  way: **361 passed, 0 failed, 20 skipped** (the same 20 UI tests).
- **New tests:** `test_sessions.py` (107, AG-1 to AG-17, AG-22), `test_live.py` (51, the agents' own
  interfaces through the fakes' TUI modes: live and back, Take Over, hide, messages to live
  sessions, typed agents, plugins silent outside Tern), `test_sessions_real.py` (10 real-agent tests,
  among them three where an agent given only a task and the CLI's name orchestrates another),
  `test_review_agents.py` (45, one per review finding a test can reach, each failing on the build
  before its fix), `test_tern_nav.py` (29, L-9 to L-18, S-7) and `test_tern_panes_ui.py` (34, L-19,
  L-20, M-4, S-3, S-4, S-8, E-10). The fakes gained the live modes, Codex's socket server and
  `thread/items/list`.
- **Changed tests**, none weakened (TEST_CHANGES.md, last part): the replaced MA/AP/IA tests removed
  or ported. Six tests were wrong and are fixed, each explained:
  - an upstream split-ratio expectation (L-19);
  - a pin-group check that assumed the old order (S-7);
  - a stale `MA-13` tag;
  - two badge checks that counted finished sessions;
  - a jump test that assumed it owned every mark in the shared instance;
  - a view test that read buttons before they were built.
- **Written checks** (CHECKS.md): all 23 have verdicts in `acceptance/results/checks/REPORT.md`,
  judged from screenshots taken with `tern screenshot` (which now includes open palettes):
  - PASS for what screenshots show: S-1 to S-3, S-5 to S-8, L-14 to L-16, E-1, E-2, E-4, E-7, AG-5,
    and P-2, I-3, I-5 from before.
  - NOT JUDGED where a person must act, with steps (S-4, L-17, M-4, E-8, the keyboard side of L-9, the
    hover controls of S-3).
- **Found by the tests, not by the reviews:**
  - Every window opened while the screen is locked held a thread for ever (AppKit's opening animation
    never ends without frames). After 64 windows, agent commands stalled.
  - A 4 MB message took 17 s to send: the control connection rescanned it after every read.
  - A message steered into a Codex turn just before a crash could be delivered twice.
  - Process names were read with a buffer `proc_name` refuses, so every process looked like a shell.
  - A read-only view dropped out of its pane when the window got another split.
  - A test leak disabled the user's Claude plugin. Tern's plugin commands ran from the home folder,
    where Claude Code treats `~/.claude/settings.json` as project settings. Fixed, and the plugin
    re-enabled.

## Codex review

`codex review --base 2fa4d48ed -c model_reasoning_effort="high"`, ten rounds (logs
`logs/agents-review1.log` to `agents-review10.log`). Every high and moderate finding was fixed, with a
regression test where a test could reach it, and the suite rerun before the next round.

| Round | High | Moderate | What they were about |
|---|---|---|---|
| 1 | 1 | 4 | Take Over during a launch, a failed attach, quoting, shortcut order, palette races |
| 2 | 3 | 3 | parked sessions with waiting messages, typed agents' panes, editor edits of a parked tab, shortcuts, hook paths with spaces |
| 3 | 1 | 4 | Codex socket writes blocking every session, update protection, attention after a close, paged delivery checks, empty rename |
| 4 | 1 | 3 | one interface per conversation across a closed pane, drafts, reopen after a resize |
| 5 | 1 | 5 | resume while live, pastes, `rm` and names of live sessions, a failed Take Over, stale file results |
| 6 | 3 | 1 | crash delivery for Claude, live turns across a quit, typed agents' children, failed live turns |
| 7 | 2 | 1 | the same for Codex's attached interface, interrupted live turns |
| 8 | 0 | 3 | background work across a quit, paste confirmation, unknown terminal actions |
| 9 | 1 | 3 | never typing into another program, steering at turn start, hiding a live Codex, search cancellation |
| 10 | 1 | 3 | `claude --resume` typed by hand, dialog answers, typed agents' config folders, parked placement |

The loop stopped at ten rounds. Round 10's four findings were fixed and tested afterwards, but no
review round looked at those fixes. What remains, not reviewed again: those fixes and the plugin
fixes made after the release. Not covered by a test: a paste that waits for confirmation, cancelled
file searches, and paging through more than 500 newer items of a Codex thread.

## Release and update

- **Release v0.4.0** (a new minor version) published with `app/dist/release.sh --version 0.4.0`
  from the reviewed build, after building it with `--build --no-publish` and running the definitive
  run on it: https://github.com/alejoacelas/tern/releases/tag/v0.4.0 with `Tern-0.4.0.zip` (22.9 MB,
  ad-hoc signed), `appcast.json` (SHA-256 and Ed25519 signature) and `install.sh`. Nothing else: no
  source, `acceptance/`, logs or keys. The repository's README now describes agent sessions and Tern's
  plugins, and the uninstall line removes the plugins first (committed with your GitHub noreply
  address).
- **The copy installed on this Mac updated itself:** its `tern update` (your yes) found and
  downloaded 0.4.0, and `tern update --now` installed it and relaunched. Only idle shells were running,
  in two windows. Now: `tern --version` → 0.4.0, a release build, the signature verifies, no
  quarantine, `update --status` → up to date. Both windows came back, with all 8 panes.
- **Tern's plugins on this Mac** (installed by the app at launch, as you approved): Claude Code's
  `tern@tern` 1.0.1 (enabled) and Codex's (7 hooks trusted). Both come from
  `/Applications/Tern.app/Contents/Resources/agent-plugins`. A test run during development had
  installed the Codex one pointing at a development build, and 0.4.0 didn't re-point it because the
  version matched; I re-pointed it with the installed copy's `tern agent plugins install --force`.
  The source fix comes with the next version.
- **Your configuration otherwise:** the trust entries our test runs had added to
  `~/.codex/config.toml` over the phases (nine throwaway `acc-*` folders and one probe folder, plus
  the live test's folder) are removed. Nothing else in it changed. A copy from before the cleanup is
  in `logs/codex-config-before-cleanup.toml`. `/Applications/Shade.app` and your `~/.local/bin`
  entries are untouched.

## Questions for the user

1. **Claude's "trust this folder?" prompt.** When a session goes live in a folder Claude Code was
   never opened in, its own interface asks this, although the session already ran there headless.
   Tern leaves the answer to you, because answering writes `~/.claude.json`. Warp writes
   `hasTrustDialogAccepted` itself for its runs. Should Tern do the same for folders it starts
   sessions in?
2. **Dock badge.** It counts sessions that need you (a question, an approval, input), as you wrote,
   not ones that finished while you weren't looking; those get only the quiet sidebar mark. ⌃⌘J visits
   both, needing-you first. Should the badge count finished-unseen sessions too?
3. **Take Over interrupts a running Claude turn.** Claude Code can't share a running turn between two
   processes, so "taking over is immediate" interrupts it; Codex's turn carries on. Acceptable?
4. **Agents you type yourself** (`claude`, `codex` in a pane) become sessions Tern knows, through its
   plugin. You can supervise them, and they show in the sidebar and on the badge. Keep that, or only
   sessions Tern starts?
5. **⌃⌘K** for "back" after ⌃⌘J (my choice; ⌃⌘J was already taken). Fine?
6. **Real-agent tests and `~/.codex`.** The live Codex test answers Codex's folder-trust prompt for
   one fixed test folder, which writes an entry to `~/.codex/config.toml`. I remove it after the run.
   Would you rather the tests leave that one entry in place?

## How an agent supervises other agents with the CLI

Inside any Tern session (or any Tern terminal), `tern` is on PATH and reaches this instance. Workers
run headless and appear nowhere unless shown. `tern agent --help` says all of this in one screen.

```sh
# Start a worker (prints its id; nothing appears on screen). A name, a folder or worktree, a model
# and effort, full access, environment, and the agent's own flags after --.
tern agent start codex "Fix the failing test in tests/test_api.py" --name fix-api --worktree fix-api --full-access

# Wait until it has settled (background work included): DONE 0, NEEDS_INPUT 2,
# STOPPED/ERROR/FAILED/INTERRUPTED/CANCELLED 3, TIMEOUT 124. Prints the status, then the reply.
tern agent wait fix-api --timeout 1800

# Steer it while it works (the message goes into the running turn), or give it a new task when idle.
# --interrupt stops the current turn first and makes this next. Prints the message id.
tern agent send fix-api "Also run the linter before you finish"
tern agent wait fix-api --message MESSAGE_ID          # that message's own outcome

# Read: the last reply, one message's reply, or everything in order.
tern agent read fix-api [--message ID] [--transcript]

# What every worker of mine is doing, and what one is waiting on.
tern agent ls --parent self
tern agent info fix-api

# Answer what it asks (sessions without --full-access): approvals and questions.
tern agent approve fix-api [REQUEST] [--always]   |   tern agent deny fix-api [REQUEST]   |   tern agent answer fix-api "the answer"

# Be woken instead of polling: a message arrives in my own session when the worker finishes.
tern agent watch fix-api --notify self

# A worker reports its own verdict, and the supervisor can wait for that instead.
tern agent report done "Fixed: the fixture used the wrong port"      # inside the worker
tern agent wait fix-api --report

# Show a worker to the person (read-only, with Take Over), or put it in front of them live.
tern agent open fix-api [--split right] [--live]

# Interrupt, stop (everything it started ends; a message resumes it), remove.
tern agent interrupt fix-api   |   tern agent stop fix-api   |   tern agent rm fix-api
```

A Claude Code orchestrator in a pane can run `tern agent wait …` with `run_in_background`, or use
`watch --notify self` and carry on. The three zero-instruction tests in `test_sessions_real.py`
(Claude orchestrating Codex, Codex orchestrating Claude, and redirecting a worker mid-task) passed,
each finding these commands from `--help` alone.

===================================================================================================

# Tern: after phase 2 (the user's answers)

Phase 2's report and phase 1's follow this part. They're unchanged, except phase 2's orchestrator
guide, which now describes the new default.

Your answers to phase 2's questions (`acceptance/REQUESTS.md`, "Answers after phase 2"): "script
quits should not ask, updates should ask. license is good. default workers to background".

## What changed

- **Updates ask first (I-4).** When a background check finds a newer version, a notice appears at
  the bottom of every window's sidebar: "Tern X is available (you have Y)." with **Download**,
  **Later** and **Skip**. It's never a dialog, takes no focus, blocks nothing, and stays until you
  answer; nothing is downloaded until you say yes. One desktop notification per version points at
  it (clicking it shows the sidebar, opening a window if none is left). "Check for Updates…" and
  `tern update` count as a yes. After a yes the notice shows the download, then "Tern X is ready.
  It installs when you quit." with **Install Now…**; a failed download shows with **Try Again**.
  From a terminal: `tern update --status` (where things stand, no network), `--check` (looks),
  `--later`, `--skip`. Screenshots: `acceptance/results/checks/extra-I-4-update-question.png`,
  `extra-I-4-update-ready.png`.
- **Workers run in the background (AP-3).** `tern agent start` shows nothing unless given a
  placement (`--tab`, `--split`, `--new-window`, `--focus`, `--window W`, `--pane P`); `agent open`
  still defaults to a new tab without focus. You find sessions with no pane in **Window > Agent
  Sessions** (every session with its status and activity, the ones that need you first, ✓ for
  shown ones; choose one to show it), the **command palette** (same order), **⌃⌘J**, **desktop
  notifications** (as before) and the **Dock badge**, which counts the sessions waiting for you. An
  orchestrator finds its workers with `tern agent ls --parent self`; `agent ls` and `agent info`
  say which pane shows a session, if any. The CLI help, the note workers get about their situation,
  and the orchestrator guide (phase 2's part below) say all this.
- **Confirmed as they are:** a quit requested by another process doesn't ask (now your decision,
  no longer a compromise), and the MIT license in your name.

Code: `TernUpdater.swift` and `TernSidebar.swift` (the question), `TernCLI/main.swift` (`update`),
`Agents/TernAgentMenu.swift` (the menu, palette order, badge), `TernCLI/agent.swift` (the default,
`ls --parent`), `Agents/TernAgentEnvironment.swift` (the note). App commits `28615e3f0` to
`2fa4d48ed`.

## Decisions

Details, candidates and evidence: DECISIONS.md §18–§19.

| # | Decision | Pick | Evidence |
|---|---|---|---|
| 18 | The update question | A notice at the bottom of every window's sidebar (Download / Later / Skip), one notification per version pointing at it, `update --status/--check` saying it waits. Not a dialog or sheet (they take focus and block), not only a notification (it doesn't stay). Answers kept in `<state dir>/update.json`: a yes is remembered for exactly that version (a failed or interrupted download is retried, never extended to a newer version, which is asked about); Later = 24 h, across restarts; Skip = never this version, a newer one asks; the latest answer counts. An update an older build downloaded is never installed by this build: it's downloaded again after a yes and verified. | `test_a_background_check_asks_and_downloads_nothing_until_yes` (Finder stays in front, the user's pane unchanged, no zip requested over checks, `--check`, a restart and a quit), `test_later_asks_again_later_and_skip_waits_for_a_newer_version`, `test_update_is_a_yes_even_after_skip_and_the_yes_outlives_a_restart`, three review regressions, the UI test of the notice and the menu's yes, `test_an_older_build_updates_itself` |
| 19 | Sessions with no pane | No pane at all; found through Window > Agent Sessions, the palette, ⌃⌘J, notifications and the Dock badge (the sidebar may have no agents section, S-2), and by the orchestrator through `agent ls --parent self`, `agent info` (its pane, if any) and `agent open` | `test_start_shows_nothing_by_default`, `test_workers_run_in_the_background_and_their_orchestrator_finds_them`, `test_any_placement_option_shows_the_session`, `test_agents_and_people_are_told_workers_start_in_the_background`, the menu UI test, `verify_agent_panes.py` (menu order, ✓, badge) |

## Test changes

No test was weakened (TEST_CHANGES.md, last part). Every existing test that needed a pane already
passed a placement, so the new default broke none. One helper of the suite's update tests was fixed:
`bundle_version` crashed when it polled at the instant the installer swaps the bundle (two renames);
it now reads that instant as "not there yet" and keeps waiting. Added: 7 update tests in `tests/test_tern_extra.py` (one
UI) and 4 background-session tests in `tests/test_tern_agents_extra.py` (one UI), the update
evidence in `checks/tern_extra_evidence.py --only update`, and menu and badge checks in
`verify_agent_panes.py`.

## Status

The definitive run, on the build that was published, with the screen unlocked
(`ACCEPTANCE_REAL=1 uv run pytest --target targets/tern.json`, under `caffeinate -d -i`): **244
passed, 0 failed, 0 skipped** (`logs/a-suite-final2.log`, `acceptance/results/traceability.md`).
That includes:

- the **16 real-agent tests** (Claude haiku, Codex gpt-6-luna at low effort);
- all **17 UI tests**: phase 2's 15 (none ran in phase 2's report, the screen was locked; they
  passed on phase 2's build too, per the brief) and the 2 new ones. They were also run on their own
  (`-m ui`) before each review round: 17/17 every time;
- the **58 extra tests** (`test_tern_extra.py`, `test_tern_agents_extra.py`), 11 of them new.

Every requirement with automated tests passes (87); the other 13 are written checks only. The run
before it had one failure, a race in a test helper (TEST_CHANGES.md); the helper was fixed and the
whole run repeated. Also: `verify_agent_panes.py` 42/42 (with the new menu and badge checks).

Phase 2's table below still describes every requirement; what changed: I-4 and AP-3 have the new
tests, and the "UI tests skipped (locked screen)" column no longer applies: none was skipped.

## Written checks

The checks these changes touch were run again (`checks/run_checks.py`, then
`checks/tern_extra_evidence.py --only update`) and their screenshots judged; the others keep phase
2's verdicts (their screenshots, regenerated, show the same). Verdicts in
`acceptance/results/checks/REPORT.md`.

| Check | Verdict | Left for a person |
|---|---|---|
| P-2 | PASS: "Check for Updates…" is a yes (its dialog says it's downloading; the notice then offers Install Now…), checked through the accessibility tree with the screen unlocked; the question itself is the sidebar notice, not a dialog | Seeing the dialogs yourself, and the "up to date" one |
| S-1 | PASS: the notice is a faintly tinted block with plain text buttons, no border | |
| S-2 | PASS: still no agents section; background sessions are listed in the Window menu | |
| AP-7 | NOT JUDGED (unchanged; steps updated: a session started in the background notifies and badges the Dock) | all of it |

## Codex review

`codex review --base 68a15e8c7 -c model_reasoning_effort="high"` in `app/` (logs:
`logs/a-review1.log` … `a-review4.log`). After each round the findings were fixed, the app rebuilt,
the UI tests and the full suite rerun, and a regression test added.

| Round | Findings | What was fixed |
|---|---|---|
| 1 | 0 P1, 3 P2 | A remembered yes downloads exactly the release it was for (the retry no longer refetches the feed, so a newer version can't ride on it); a yes whose feed request fails shows as that version's failed download (the menu also says so in a dialog) instead of vanishing; clicking the update notification opens a window when none is left. |
| 2 | 0 P1, 1 P2 | Try Again on a failed download is a yes to that version only: if the feed moved on, the newer version is asked about. |
| 3 | 0 P1, 2 P2 | The latest answer counts (Later replaces an earlier Skip and vice versa); a queued retry of a remembered yes yields to a Later or Skip given meanwhile. |
| 4 | none | |

Nothing is left open from the reviews.

## Release and update

- **Release v0.3.0** (a new minor version) published with `app/dist/release.sh --version 0.3.0`
  from the reviewed, tested build (built with `--build --no-publish` first, then the definitive run,
  then published): https://github.com/alejoacelas/tern/releases/tag/v0.3.0 with `Tern-0.3.0.zip`
  (22.3 MB, ad-hoc signed), `appcast.json` (SHA-256 and Ed25519 signature) and `install.sh`. Nothing
  else: no source, `acceptance/`, logs or keys. The one-line install command now installs 0.3.0.
  The repository's README now says updates ask first (committed with your GitHub noreply address).
- **The copy installed on this Mac updated itself**, with the old (0.2.0) update behavior:
  `tern update --check` on /Applications/Tern.app 0.2.0 found 0.3.0; `tern update --now` downloaded
  and verified it, installed it and relaunched (only an idle shell was running in it, and it had no
  sessions). Now: bundle 0.3.0 running, `tern --version` → 0.3.0, `tern update --check` → "installed
  0.3.0, latest 0.3.0: up to date", `update --status` shows background checks on the public feed, no
  quarantine attribute, the signature verifies, its window came back. From now on it asks before
  downloading the next version.
- Untouched: /Applications/Shade.app, your other `~/.local/bin` entries, `~/.claude` and `~/.codex`.

## Questions for the user

1. **"Finished" notifications for background workers.** AP-7's rule is unchanged: a session that
   needs you, or finishes while you aren't looking at it, notifies. A background worker is never
   looked at, so each of its turns that ends notifies (as a worker in an unseen tab did). With
   dozens of workers, would you rather get "finished" only for sessions you started yourself (an
   orchestrator), and "needs you" for all?
2. **Your own orchestrator** started with `tern agent start` is in the background too (the spec says
   so for every `agent start`); add `--tab --focus`, or `tern agent open NAME` later. Should a
   session started from outside any agent (no parent) default to a tab instead?
3. **"Later" is 24 hours**, and there's one notification per version. Different interval, or no
   notification at all (the sidebar notice only)?
4. **The Dock badge** counts sessions that need you, and replaces Ghostty's bell count while any do.
   Keep?
5. Still open from phase 2 (unanswered): steering a running turn (question 2), keeping sessions
   alive across quits with a daemon (4), a Tern track in `supervise-workers` (5), and "allow always"
   writing a project rule (6).


---------------------------------------------------------------------------------------------------

# Tern: phase 2 report (managed agents)

Phase 1's report follows this part, unchanged.

## What was built

Managed Claude Code and Codex sessions, controlled from `tern agent …` and shown in panes.

- **The real harnesses, headless.** Claude runs as `claude -p --input-format stream-json
  --output-format stream-json --verbose --replay-user-messages --permission-prompt-tool stdio`
  (the CLI itself, so it loads CLAUDE.md, settings, skills, MCP servers, plugins, hooks and
  subagents as in your terminal); Codex as a private `codex app-server --listen stdio://` per
  session (never your shared Codex daemon). Model, effort, access, extra arguments and `--env` are
  kept for every resume.
- **Exactly-once delivery, truthful status.** Tern keeps its own queue and hands a harness one
  message at a time; a message's id is the one the harness echoes back, and delivery is what the
  harness confirms. Redirects (`send --interrupt [--drop-queued]`) go first and interrupt only the
  turn that was running; a turn that doesn't stop within 30 s gets its harness restarted.
- **Send and it runs.** A message to a stopped, crashed or restarted session resumes the same
  conversation; a turn cut off by a quit, crash or update continues by itself at the next launch
  with a short note. A conversation the harness no longer has, or a folder that's gone, fails the
  message at once with the reason.
- **Nothing left running.** Every process a session starts is found by an environment tag (even
  detached ones), and stopped with SIGTERM then SIGKILL; leftovers of a killed app are stopped at
  the next launch.
- **Composition.** `self`, parents, `agent watch --notify` (a supervisor gets a follow-up when a
  worker's turn ends, needs input or exits), worker reports (`agent report`, `agent wait
  --report`), what each worker loaded (`startup`, with a warning line when an MCP server failed or
  needs auth), approvals and questions (allow once / always for the session / deny; one answer per
  question), MCP elicitation (Codex).
- **Workers know their situation.** A few appended system-prompt lines (Claude) or developer
  instructions (Codex): a managed session nobody may be watching, its name, id, parent and
  folder, and how to report and reach other sessions.
- **Sessions in panes.** A session is drawn over an ordinary terminal pane (its shell, in the
  session's folder, is a toggle away), so it splits, moves, swaps, zooms, closes and undoes, drags
  and comes back after a restart like any pane. The view shows both sides (Markdown replies, code
  set apart), tool calls that expand to their output, cards for approvals and questions, queued
  messages, and a composer (Enter sends, Shift+Enter adds a line, Esc interrupts; drafts are kept).
  `agent start` opened a new tab by default without taking focus; `--focus`, `--split`,
  `--new-window`, `--background` (after phase 2: the background is the default, see the top). The sidebar's second line shows a session's status and activity;
  ⌃⌘J jumps to the session that needs you; the command palette lists every session. Desktop
  notifications when a session needs you or finishes out of sight.
- **Phase 1's open item** fixed: every editor tab, the active one included, stays readable in a
  narrow panel (the Preview/Source control moves to a row of its own when it doesn't fit).

Where things are:

| Path | What |
|---|---|
| `app/macos/Sources/Features/Tern/Agents/` | the engine (`TernAgentSession`, `TernAgents`), drivers (`TernClaudeDriver`, `TernCodexDriver`), processes (`TernHarnessProcess`, `TernProcessTree`), environment (`TernAgentEnvironment`), storage (`TernAgentStore`), RPC (`TernAgentRPC`), panes (`TernAgentUI`, `TernAgentPane`, `TernAgentTranscriptRenderer`) |
| `app/macos/TernCLI/agent.swift` | `tern agent …` |
| `<state dir>/sessions/<id>/` | a session's `session.json` and `log.jsonl` |
| `acceptance/tests/test_tern_agents_extra.py` | tests added for this design's risks |
| `app/macos/TernTests/verify_agent_panes.py` | agent-pane UI paths checked without the accessibility tree |
| `acceptance/reference/agent-probes/probe_phase2b.py`, `agent-logs/X15wake*.jsonl` | the Codex self-started-turn probe |

## How your orchestrator uses the CLI

Inside a Tern pane or a managed session, `tern` is on PATH and reaches the right instance. Session
names make good slugs.

```sh
# Start (prints the session id). Full access, its own worktree, a model and effort; the pointer is
# the first message. It runs in the background: no tab, no pane. To show it as well, add --tab,
# --split [DIR] or --new-window (--focus switches to it).
tern agent start claude --name fix-login --worktree fix-login --full-access --model opus --effort high \
  "Do the task in .supervise/fix-login/task.md"
tern agent start codex --name review-api --full-access --model gpt-6-luna --effort low \
  -- -c model_verbosity=low        # anything after -- goes to the harness

# Wait for the turn to end: DONE 0, NEEDS_INPUT 2, INTERRUPTED/FAILED/EXITED/ERROR/CANCELLED 3,
# TIMEOUT 124. Prints the status, then the reply (or the pending questions). It keeps waiting
# across a Tern restart.
tern agent wait fix-login --timeout 1200
# Or wait for the worker's own verdict: done 0, blocked 2, failed 3, timeout 124 (+ harness state).
tern agent wait fix-login --report --timeout 3600

# Read: the last reply, a given message's reply, or the transcript.
tern agent read fix-login
tern agent read fix-login --transcript --last 30

# Follow up (queued if it's busy; a stopped session resumes). Prints the message id.
m=$(tern agent send fix-login "The test still fails on CI; check the timezone handling.")
tern agent wait fix-login --message "$m"

# Redirect: interrupt what it's doing and make this next (--drop-queued drops older follow-ups).
tern agent send fix-login --interrupt "Stop: don't touch the schema. Revert that and continue."

# Answer what it asks (when not in full access): approvals and questions.
tern agent info fix-login                    # shows pending requests with their ids
tern agent approve fix-login [r3] [--always] # deny: tern agent deny fix-login --message "why"
tern agent answer fix-login --answer 1=blue --answer 2=L

# Get woken instead of polling: a follow-up message arrives in SUPERVISOR's session.
tern agent watch fix-login --notify self     # from inside a managed session
# Claude Code orchestrator in a pane: run `tern agent wait …` with run_in_background.

# Your workers: list them, and show one to the user when it helps.
tern agent ls --parent self                   # the sessions you started: status, activity, report, pane if shown
tern agent open fix-login                     # a new tab, without taking focus (--focus, --split, --new-window)

# Status, stop, list, resume after a restart.
tern agent ls                                 # every session, status, latest report
tern agent interrupt fix-login                # stop the turn, keep the session
tern agent stop fix-login                     # end its work and everything it started; resumable
tern agent rm fix-login --force               # forget it
```

Workers report with `tern agent report done|blocked|failed "summary"` (they're told how). An idle
harness only means nothing is running now, not that the task is done, and a Claude worker can start
working again by itself when a background command it started finishes; `agent wait --report` and
`agent info` show the worker's verdict next to what the harness says.

For the `supervise-workers` skill, the Tern track is: write the task file, `tern agent start … "Do
the task in .supervise/<slug>/task.md"`, `tern agent wait <slug>` (or `--report`), read the report,
check the evidence, `tern agent send <slug> …` to follow up, `tern agent stop <slug>` when accepted,
`tern agent ls --parent self` to rebuild state after a restart.

You (the user) find workers that no pane shows in Window > Agent Sessions (status and activity, the
ones that need you first; choose one to show it), in the command palette ("Show Agent: …"), with ⌃⌘J
(the one that needs you), through desktop notifications, and by the Dock badge, which counts the
sessions waiting for you. An orchestrator you start yourself with `tern agent start` is in the
background too: add `--tab --focus` to see it at once, or `tern agent open NAME` later. A managed orchestrator can replace the watcher
scripts with `tern agent watch <slug> --notify self`.


## Status

From the definitive run on a build of the released commit (`ACCEPTANCE_REAL=1 uv run pytest --target targets/tern.json`,
fakes and real agents together): **216 passed, 15 skipped, 0 failed** (`logs/p2-suite-final.log`).
The 15 skipped are all accessibility-tree UI tests: the Mac's screen was locked for the whole run,
and macOS hides the tree then (TEST_CHANGES.md §1). Their behaviors were checked another way, and
a skip is never counted as a pass below.

- **Real agents** (`ACCEPTANCE_REAL=1 … -m real`, Claude haiku and Codex gpt-6-luna at low effort):
  16/16 pass, in the definitive run and on their own (3.5 min).
- **Extra tests** for this design's risks (`tests/test_tern_agents_extra.py`): 25, all pass (in the run above).
- **Fake harness self-tests** (`fakes/test_fakes.py`): 44/44.
- **UI paths without the accessibility tree:** `app/macos/TernTests/verify_agent_panes.py` 36/36 (typing a follow-up and Enter, Esc, the composer's focus, questions and approvals answered from the cards, the shell toggle, drafts across toggles and moves, Undo of a closed agent pane, the transcript after reopening and after a restart, ⌃⌘J); phase 1's `verify_ui_paths.py` 43/43.
- Every fixed- and core-tier requirement passes its automated tests, except where the only tests are
  the skipped UI tests (L-9, M-3, E-4, E-5, AP-1, AP-5, AP-9); those behaviors pass in the scripts above
  (AP-9: no "new agent" control exists; the S-1/S-2 screenshots show none).
- Negotiable requirements: all their automated tests pass (MA-14, MA-16, IA-2, AP-11); the written
  ones (AP-6, AP-7, AP-8, AP-10) are judged below. COMPROMISES.md lists what was traded, not test failures.

Full table (`acceptance/results/traceability.md` lists the test names):

| Requirement | Tier | Kind | Tests | UI tests skipped (locked screen) | Written check |
|---|---|---|---|---|---|
| P-1 | Fixed | A | pass |  |  |
| P-2 | Fixed | A | pass |  | pass; part by hand not judged |
| P-3 | Fixed | A | pass |  |  |
| P-4 | Fixed | A | pass |  |  |
| I-1 | Fixed | A | pass |  |  |
| I-2 | Fixed | A | pass |  |  |
| I-3 | Fixed | W | written check |  | pass |
| I-4 | Fixed | A | pass |  |  |
| I-5 | Fixed | W | pass |  | pass; part by hand not judged |
| L-1 | Fixed | A | pass |  |  |
| L-2 | Fixed | A | pass |  |  |
| L-3 | Fixed | A | pass |  |  |
| L-4 | Fixed | A | pass |  |  |
| L-5 | Fixed | A | pass |  |  |
| L-6 | Fixed | A | pass |  |  |
| L-7 | Fixed | A | pass |  |  |
| L-8 | Fixed | A | pass |  |  |
| L-9 | Fixed | W | skipped (locked screen) | test_shortcuts_are_menu_items, test_agent_shortcuts_are_menu_items; the same paths pass in verify_ui_paths.py, verify_agent_panes.py | pass; part by hand not judged |
| M-1 | Fixed | A | pass |  |  |
| M-2 | Fixed | A | pass |  |  |
| M-3 | Fixed | A | skipped (locked screen) | test_undo_redo_of_moves; the same paths pass in verify_ui_paths.py |  |
| M-4 | Fixed | W | written check |  | not judged (by hand) |
| M-5 | Fixed | A | pass |  |  |
| M-6 | Fixed | A | pass |  |  |
| T-1 | Fixed | A | pass |  |  |
| T-2 | Fixed | A | pass |  |  |
| T-3 | Fixed | A | pass |  |  |
| T-4 | Fixed | A | pass |  |  |
| T-5 | Fixed | A | pass |  |  |
| T-6 | Fixed | A | pass |  |  |
| T-7 | Fixed | A | pass |  |  |
| S-1 | Fixed | W | written check |  | pass |
| S-2 | Fixed | A+W | pass | test_no_new_agent_form_and_no_agents_section | pass |
| S-3 | Fixed | W | written check |  | pass; part by hand not judged |
| S-4 | Fixed | W | written check |  | not judged (by hand) |
| S-5 | Fixed | W | written check |  | pass |
| S-6 | Fixed | W | written check |  | pass |
| E-1 | Fixed | A+W | pass |  | pass |
| E-2 | Fixed | A+W | pass | test_toggle_shows_the_source; the same paths pass in verify_ui_paths.py | pass |
| E-3 | Fixed | A+W | pass | test_dirty_documents_are_not_closed_silently_and_save_works; the same paths pass in verify_ui_paths.py | pass; part by hand not judged |
| E-4 | Fixed | A+W | skipped (locked screen) | test_follows_changes_on_disk; the same paths pass in verify_ui_paths.py | pass |
| E-5 | Fixed | A+W | skipped (locked screen) | test_non_utf8_files_keep_their_encoding; the same paths pass in verify_ui_paths.py | pass |
| E-6 | Fixed | A | pass |  |  |
| E-7 | Fixed | W | written check |  | pass; part by hand not judged |
| E-8 | Fixed | W | written check |  | not judged (by hand) |
| E-9 | Fixed | A | pass |  |  |
| IA-1 | Core | A+W | pass |  | pass |
| IA-2 | Negotiable | A | pass |  |  |
| IA-3 | Core | A | pass |  |  |
| IA-4 | Core | A | pass |  |  |
| MA-1 | Core | A | pass |  |  |
| MA-2 | Core | A | pass |  |  |
| MA-3 | Core | A | pass | test_follow_up_typed_into_the_pane (both); the same paths pass in verify_agent_panes.py |  |
| MA-4 | Core | A | pass |  |  |
| MA-5 | Core | A | pass |  |  |
| MA-6 | Core | A | pass |  |  |
| MA-7 | Core | A | pass |  |  |
| MA-8 | Core | A | pass | test_escape_in_the_pane_interrupts; the same paths pass in verify_agent_panes.py |  |
| MA-9 | Core | A | pass |  |  |
| MA-10 | Core | A | pass |  |  |
| MA-11 | Core | A | pass |  |  |
| MA-12 | Core | A | pass |  |  |
| MA-13 | Core | A | pass |  |  |
| MA-14 | Negotiable | A | pass |  |  |
| MA-15 | Core | A | pass |  |  |
| MA-16 | Negotiable | A | pass |  |  |
| MA-17 | Core | A | pass |  |  |
| MA-18 | Core | A | pass |  |  |
| MA-19 | Core | A | pass |  |  |
| MA-20 | Core | A | pass |  |  |
| MA-21 | Core | A | pass |  |  |
| MA-22 | Core | A | pass |  |  |
| MA-23 | Core | A | pass |  |  |
| MA-24 | Core | A | pass |  |  |
| MA-25 | Core | A | pass |  |  |
| MA-26 | Core | A | pass |  |  |
| MA-27 | Core | A | pass |  |  |
| MA-28 | Core | A | pass |  |  |
| MA-29 | Core | A | pass |  |  |
| AP-1 | Core | A+W | skipped (locked screen) | test_follow_up_typed_into_the_pane (both), test_escape_in_the_pane_interrupts, test_pane_shows_status_and_pending_requests; the same paths pass in verify_agent_panes.py | pass; part by hand not judged |
| AP-2 | Fixed | A | pass | test_undo_close_brings_the_agent_pane_back; the same paths pass in verify_agent_panes.py |  |
| AP-3 | Fixed | A | pass |  |  |
| AP-4 | Core | A | pass |  |  |
| AP-5 | Core | A+W | skipped (locked screen) | test_reopened_pane_shows_everything_in_order, test_pane_after_app_restart_shows_the_earlier_conversation; the same paths pass in verify_agent_panes.py | pass |
| AP-6 | Negotiable | W | written check |  | not judged (by hand) |
| AP-7 | Negotiable | W | written check |  | not judged (by hand) |
| AP-8 | Negotiable | W | written check |  | not judged (by hand) |
| AP-9 | Fixed | A | skipped (locked screen) | test_no_new_agent_form_and_no_agents_section |  |
| AP-10 | Negotiable | W | written check |  | pass; part by hand not judged |
| AP-11 | Negotiable | A | pass |  |  |
| R-1 | Core | A | pass |  |  |
| R-2 | Core | A | pass |  |  |
| R-3 | Core | A | pass | test_pane_after_app_restart_shows_the_earlier_conversation; the same paths pass in verify_agent_panes.py |  |
| R-4 | Core | A | pass |  |  |
| R-5 | Core | A | pass |  |  |
| R-6 | Core | A | pass |  |  |
| R-7 | Core | A | pass |  |  |
| R-8 | Core | A | pass |  |  |
| R-9 | Core | A | pass |  |  |
| R-10 | Core | A | pass |  |  |

**UI tests to run with the screen unlocked** (Questions, 1): `test_follow_up_typed_into_the_pane[claude]`,
`[codex]`, `test_escape_in_the_pane_interrupts`, `test_pane_shows_status_and_pending_requests`,
`test_undo_close_brings_the_agent_pane_back`, `test_reopened_pane_shows_everything_in_order`,
`test_pane_after_app_restart_shows_the_earlier_conversation`, `test_no_new_agent_form_and_no_agents_section`
(phase 2), and phase 1's `test_shortcuts_are_menu_items`, `test_agent_shortcuts_are_menu_items`,
`test_undo_redo_of_moves`, `test_toggle_shows_the_source`, `test_dirty_documents_are_not_closed_silently_and_save_works`,
`test_follows_changes_on_disk`, `test_non_utf8_files_keep_their_encoding`.

## Decisions

Details, candidates, costs and evidence: DECISIONS.md §9–§17.

| # | Decision | Pick | Evidence |
|---|---|---|---|
| 9 | Controlling a harness | The real CLIs headless: `claude -p` stream-json (the CLI, not the SDK, so it loads the terminal's configuration) and a private `codex app-server` per session over stdio. Not Claude's background agents (no programmatic follow-up API, the user's shared daemon) and not the TUI (screen control). | The real-agent tests (project CLAUDE.md/AGENTS.md, a project skill, a project MCP server + hook + subagent in a never-opened folder and after a resume, approvals, interrupts, orchestration, cut-off turns); flags checked against Claude Code 2.1.292 and codex-cli 0.160.0 |
| 10 | Message and turn tracking | The product's own queue, one message in the harness at a time; ids the harness echoes; delivery = the harness's confirmation; redirects go first and interrupt only the running turn (30 s → restart); after a product crash Codex is asked which messages its thread has | `test_chaos.py` (Hypothesis + bursts under 8 chaos seeds per harness), the MA-4/MA-25 tests, extra tests for the crash and handover windows; the Codex probe (no self-started turns) |
| 11 | Where sessions live | The app owns the harnesses; sessions stop at quit; everything on disk; send-and-it-runs; cut-off turns continue with a note | The MA-24, R-2, R-3, R-8, R-10 tests (fakes and real) |
| 12 | Stopping everything | Session-leader harnesses with no inherited descriptors; every descendant found by an environment tag (detached ones too) plus the process group; SIGTERM then SIGKILL; leftovers of a killed app stopped at launch | MA-9, MA-10, R-1 tests (SIGTERM-ignoring harness and detached child) |
| 13 | Sessions in panes | Drawn over an ordinary terminal leaf (phase 1's door): every pane operation and restoration unchanged; the shell underneath is a toggle away | AP-2, AP-3, AP-4, AP-11 tests; `verify_agent_panes.py` |
| 14 | Focus | Non-focusing opens edit the model only; an agent pane's keyboard focus is its composer | `test_opening_without_focus_never_moves_the_users_focus`; `verify_agent_panes.py` |
| 15 | Environment and awareness | The login shell's environment (never the caller's), the app's own `tern` first on PATH, a few appended instructions about the session; startup report with flags | MA-20, MA-27, MA-29 tests (fakes and real) |
| 16 | Persistence | A folder per session (`session.json` + append-only `log.jsonl`), owner-only; tool output clipped in storage | R-2, R-8, R-9 tests |

## Compromises

Full table: COMPROMISES.md (phase 2 part). No fixed- or core-tier test fails, so none is an
accepted test failure. In short:

- **No steering:** a follow-up waits for the running turn to end (negotiable; it keeps exactly-once
  delivery and redirects exact).
- **The pane renders the session**, not the harness's own TUI (the shell is a toggle away).
- **Sessions stop when Tern quits** (your choice); running turns are interrupted cleanly and continue
  after the next launch, with a note.
- **After a crash of the whole product**, a message written to Claude in the instant before counts
  as delivered (Claude can't be asked; Codex is).
- **Codex:** a deny carries no message; MCP elicitation forms and links are Codex-only.
- `agent wait` on Codex holds its answer up to 5 s while MCP servers report in.
- Tool output is clipped in storage (first 12 KB and last 4 KB).
- `update --now` refuses while agent turns run unless `--force`.
- Agent notifications are off in isolated test instances; an agent pane drags by the grip in its
  header.

## Codex review

`codex review --base 4d4a1fe32 -c model_reasoning_effort="high"` in `app/` (logs:
`logs/p2-review1.log` … `p2-review5.log`). After each round, every high (P1) and moderate (P2)
finding was fixed, the app rebuilt, the full suite rerun (and the extra tests and
`verify_agent_panes.py`), and a regression test added where the finding could be scripted.

| Round | Findings | What was fixed |
|---|---|---|
| 1 | 2 P1, 9 P2 | "Allow always" for Codex permission requests matched on a truncated key (now the whole canonical JSON); `agent wait` evaluated and registered in two steps (now one step on the agent queue); recovered messages whose conversation can't resume now fail with the reason; a partial last log line left by a crash is cut off before new entries are appended; stale continuation notes are dropped from a restored queue; a redirect arriving before a turn is acknowledged interrupts that turn when it starts; MCP form answers take the schema's types; agent notifications are presented while Tern is active and clicks are handled on the main thread; waits end when their session is removed; an update download rechecks running turns. |
| 2 | 2 P1, 7 P2 | Writes to a harness happen on its own queue (a harness that stops reading can't block every session); after a crash a Codex message is only counted delivered if the thread's history has it (a fresh thread counts as "none"); a redirect is cleared when its harness exits; cut-off messages fail when the session can't start (folder gone, harness missing); `agent interrupt` before Codex names the turn is applied when it does; an invalid `--pane`/`--window` fails before anything starts; notification authorization is requested; `agent open` of a pane showing its shell shows the session; multi-select questions. |
| 3 | 1 P1, 3 P2 | The final process sweep at quit runs even when no harness is live (a detached child of a harness that just crashed survived a quit); a self-started turn's continuation keeps its recovery marker until it ends; an explicit `--pane`/`--window` overrides a stale caller identity (a regression from phase 1's round 5, in `tab new` and `tern claude`); no Decline button for Codex questions (its protocol can't decline). |
| 4 | 2 P1, 2 P2 | The process group a harness led is cleaned up after it exits (a child that cleared its environment escaped the tag), safely: only when no process holds the group's id; every session, not only live ones, is marked at quit (a launching session could start during the shutdown); a wait keeps the message that was latest when it began; notifications when the session's pane shows its shell or is behind a zoomed pane. |
| 5 | 1 P1, 4 P2 | A recovered turn whose resumed harness dies at startup is retried, then failed with the reason (it stayed pending); session files are owner-only (`--env` values may be secrets); background commands are tracked per harness process (a stopped one was counted again); timeout answers name their own message; a wait whose client disconnected is dropped. Also found while checking: `agent stop` now ends a pending recovery. |

Round 5 was the last round the brief allows, so its fixes haven't had a review of their own. They
have regression tests where they could be scripted, and the suite, the extra tests and both
verification scripts pass on the released build.

Found outside the reviews, while testing: Codex approval answers carried request id `0` as `false`
(a JSON conversion bug) and the real Codex ignored them; the fake accepted them (Python treats
`False == 0`). Fixed in the app, and the fake now matches ids by type, with a self-test. The agent
pane overflowed narrow panes, the screenshot command painted terminals over agent panes, and the
editor's tab row hid the active file in narrow panels (phase 1's open item); all fixed.

## Written checks

`checks/run_checks.py` (now with the agent checks) and `checks/tern_extra_evidence.py` ran on the
final build; every screenshot was looked at and judged (`checks/tern_verdicts.py` writes the
verdicts into `acceptance/results/checks/REPORT.md`, which also has the steps for everything NOT
JUDGED). The screen was locked, so anything needing hands or eyes on the live window is NOT JUDGED.

| Check | Verdict | Left for a person |
|---|---|---|
| S-1 | PASS |  |
| S-3 | PASS | Close and pin controls on hover |
| S-4 | NOT JUDGED | all of it |
| S-5 | PASS |  |
| S-6 | PASS |  |
| S-2 | PASS |  |
| P-2 | PASS | Choosing the menu item and seeing its dialogs |
| I-5 | PASS | Seeing the window on screen |
| L-9 | PASS | Pressing the keys on a real keyboard |
| M-4 | NOT JUDGED | all of it |
| E-1 | PASS |  |
| E-2 | PASS |  |
| E-3 | PASS | The 'Save changes?' dialog when closing with ⌘W |
| E-4 | PASS |  |
| E-5 | PASS |  |
| E-7 | PASS | Clicking a relative link and an #anchor |
| E-8 | NOT JUDGED | all of it |
| I-3 | PASS |  |
| IA-1 | PASS |  |
| AP-1 | PASS | Typing, Enter, Esc and the card buttons with a real keyboard and mouse (scripted through the pane's controls) |
| AP-5 | PASS |  |
| AP-6 | NOT JUDGED | all of it (scripted parts pass) |
| AP-7 | NOT JUDGED | all of it |
| AP-8 | NOT JUDGED | all of it |
| AP-10 | PASS | Expanding a tool call, Shift+Enter, the queued-messages line |

## Release and update (done)

- **Release v0.2.0** published with `app/dist/release.sh --version 0.2.0 --build` to
  https://github.com/alejoacelas/tern/releases/tag/v0.2.0: `Tern-0.2.0.zip` (22.2 MB, ad-hoc signed),
  `appcast.json` (SHA-256 and Ed25519 signature), `install.sh`. Nothing else: no source, `acceptance/`,
  logs or keys. The one-line install command now installs 0.2.0.
- **The copy installed on this Mac updated itself:** `tern update --check` on /Applications/Tern.app
  0.1.0 found 0.2.0; `tern update --now` (its own update path) downloaded and verified it, installed
  it and relaunched. Now: bundle 0.2.0, `tern --version` → 0.2.0, `tern update --check` → "installed
  0.2.0, latest 0.2.0: up to date", no quarantine, signature verifies. Its window came back; no
  session was created in your own state.
- Untouched: /Applications/Shade.app, your other `~/.local/bin` entries, `~/.claude` and `~/.codex`
  (MA-21/IA-4 tests check the config files don't change).

## Left open

- **Round 5's fixes haven't had a review of their own** (the brief allows five rounds). They have
  regression tests where scriptable; the suite, extra tests and both scripts pass on the release.
- **The 15 UI tests** need an unlocked screen (Questions, 1).
- **Processes that both clear their environment and leave the harness's process group** (for example
  a tool that runs `env -i setsid …`) can't be found after their harness exits; everything else a
  session starts is (DECISIONS.md §12).
- **Claude: a message written in the instant before a crash of the whole product** counts as
  delivered (COMPROMISES.md); Codex is asked.
- **Codex MCP elicitation and permission requests were tested with the fake only** (the real
  approval test covers command approvals); Claude's elicitation isn't surfaced (never observed).
- **Notifications (AP-7)** are off in test instances and weren't seen on screen.
- From phase 1, unchanged: `tern-app +version` still prints "Ghostty …"; the SSH terminfo cache
  lives under Ghostty's folder name; the fish/elvish/nushell `ssh` wrapper edits weren't run.

## Questions for the user

1. **Run the UI tests with the screen unlocked**, Terminal allowed under Privacy & Security →
   Accessibility: `cd ~/dev/terminal-3/acceptance && uv run pytest --target targets/tern.json -m ui`.
   The NOT JUDGED written checks list their steps (`acceptance/results/checks/REPORT.md`).
2. **Steering.** Follow-ups wait for the running turn to end (never injected mid-turn), which keeps
   delivery exactly-once and redirects exact. Want steering anyway, for Claude at least, knowing it
   weakens those guarantees in edge cases?
3. **Default placement.** `agent start` opens a tab without taking focus (`--background` for none,
   `--focus` to switch to it). Should an orchestrator's workers default to `--background` instead,
   so dozens of workers don't fill the sidebar?
4. **Sessions and quitting.** Sessions stop when Tern quits and continue on the next message (turns
   cut off by the quit continue by themselves). OK to keep, or worth a daemon later?
5. **`supervise-workers`.** Want a Tern track in the skill (the mapping is under "How your
   orchestrator uses the CLI")? `tern agent watch <worker> --notify self` replaces the watcher scripts
   for a managed orchestrator.
6. **Allow always.** It's per session (remembered by Tern across resumes, never written to your
   settings). Would you rather "always" write a project rule (Claude's `localSettings`) the way the
   terminal offers?


---------------------------------------------------------------------------------------------------

# Tern: phase 1 report

## What was built

**Tern** is a fork of Ghostty (`35a81a980`) for working with coding agents. Phase 1 is the app:

- **Windows, tabs and panes, Warp-style.** Tabs live in a full-height left sidebar (⌘B), two
  lines per row (name or folder and branch/worktree; the running or last command, or an agent's
  state). Pinned tabs come first. Rows click, double-click to rename, right-click (pin, color,
  move, close) and drag (reorder, or onto another window's sidebar). A Files mode (⇧⌘E) is a
  project explorer for the focused pane's repository.
- **Tern's own tab model.** Each window holds its tabs itself instead of using AppKit window tabs,
  so creating or moving anything with `--no-focus` never changes the user's selection, focus or
  front app, at any moment (DECISIONS.md §1–2).
- **Live sessions move** between panes, tabs and windows (CLI, menus and shortcuts, drag), with
  their programs and scrollback; source tabs and windows close when emptied; undo and redo; a
  pane moved to a new window keeps its size.
- **`tern`, the CLI** (`Contents/MacOS/tern`, linked to `~/.local/bin/tern` by the installer):
  the whole CLI.md layout, I/O, events, editor and update surface. Inside Tern's terminals it
  defaults to the calling pane. It reaches exactly one instance, found from the state directory.
- **Editor** beside each tab's terminals: Markdown opens rendered (GFM tables, task lists, code,
  images, raw HTML, no scripts) with a Preview/Source toggle (⇧⌘M), several files as editor
  tabs, ⌘S, encodings kept, disk changes followed, unsafe files refused, edits never lost.
- **Plain `claude` / `codex`** launched in a new tab, split or window exactly as if typed
  (`tern claude …`), with their exit noted in the sidebar and `ls`.
- **Packaging and updates.** One-line install, `tern doctor`, a signed release feed on GitHub,
  updates downloaded and verified in the background and installed when the app quits. Ghostty's
  Sparkle updater (and its feed and key) are gone.
- **Identity.** `Tern.app`, bundle id `dev.tern.app`, executable `tern-app`, CLI `tern`, state
  directory `~/Library/Application Support/Tern` (or `$TERN_STATE_DIR`), socket
  `<per-user temp dir>/tern-<hash>.sock`, release repository `alejoacelas/tern`, its own icon.
  The user's Ghostty config still applies on top of Tern's defaults.

Where things are:

| Path | What |
|---|---|
| `app/` | The fork (git; branch `main`, upstream at branch `upstream-base`) |
| `app/macos/Sources/Features/Tern/` | Tern's code: control socket, RPC, topology, layout and undo, sidebar, editor, Markdown, persistence, updater, shortcuts |
| `app/macos/Sources/Features/Terminal/TerminalController.swift` | Windows with Tern's own tabs |
| `app/macos/TernCLI/` | The `tern` CLI (one Swift file, `build.sh`) |
| `app/dist/` | `release.sh`, `install.sh`, `sign-update.swift` |
| `app/src/apprt/embedded.zig`, `app/src/termio/Termio.zig` | libghostty additions: `ghostty_surface_read_output_text` and `ghostty_surface_read_output_tail` (output without the prompt and typed input), `ghostty_surface_output_bytes` (a count of bytes the program wrote, for `wait --idle`) |
| `app/src/shell-integration/`, `app/src/crash/dir.zig` | The SSH wrappers call `tern-app` (the renamed core executable); crash reports go to `~/.local/state/tern/crash` |
| `acceptance/targets/tern.json` | The suite's target file |
| `acceptance/tests/test_tern_extra.py` | Tests added for this design's risks |
| `app/macos/TernTests/verify_ui_paths.py` | Checks of the UI-only behaviors without the accessibility tree |
| `DECISIONS.md`, `COMPROMISES.md`, `acceptance/TEST_CHANGES.md` | Decisions, trade-offs, suite changes |

## Phase-1 status

From the last full run on the published build (`uv run pytest --target targets/tern.json --phase 1`: 64 passed, 6 skipped, 0 failed) and the judged written checks. Phase-2 requirements (managed agents) are left out; the full table, with test names, is `acceptance/results/traceability.md`.

| Requirement | Tier | Kind | Tests | Written check |
|---|---|---|---|---|
| P-1 | Fixed | A | pass |  |
| P-2 | Fixed | A | pass | pass; part by hand not judged |
| P-3 | Fixed | A | pass |  |
| P-4 | Fixed | A | pass |  |
| I-1 | Fixed | A | pass |  |
| I-2 | Fixed | A | pass |  |
| I-3 | Fixed | W | written check | pass |
| I-4 | Fixed | A | pass |  |
| I-5 | Fixed | W | pass | pass; part by hand not judged |
| L-1 | Fixed | A | pass |  |
| L-2 | Fixed | A | pass |  |
| L-3 | Fixed | A | pass |  |
| L-4 | Fixed | A | pass |  |
| L-5 | Fixed | A | pass |  |
| L-6 | Fixed | A | pass |  |
| L-7 | Fixed | A | pass |  |
| L-8 | Fixed | A | pass |  |
| L-9 | Fixed | W | skipped (locked screen); passes in verify_ui_paths.py | pass; part by hand not judged |
| M-1 | Fixed | A | pass |  |
| M-2 | Fixed | A | pass |  |
| M-3 | Fixed | A | skipped (locked screen); passes in verify_ui_paths.py |  |
| M-4 | Fixed | W | written check | not judged (by hand) |
| M-5 | Fixed | A | pass |  |
| M-6 | Fixed | A | pass |  |
| T-1 | Fixed | A | pass |  |
| T-2 | Fixed | A | pass |  |
| T-3 | Fixed | A | pass |  |
| T-4 | Fixed | A | pass |  |
| T-5 | Fixed | A | pass |  |
| T-6 | Fixed | A | pass |  |
| T-7 | Fixed | A | pass |  |
| S-1 | Fixed | W | written check | pass |
| S-2 | Fixed | A+W | pass | pass |
| S-3 | Fixed | W | written check | pass; part by hand not judged |
| S-4 | Fixed | W | written check | not judged (by hand) |
| S-5 | Fixed | W | written check | pass |
| S-6 | Fixed | W | written check | pass |
| E-1 | Fixed | A+W | pass | pass |
| E-2 | Fixed | A+W | pass | pass |
| E-3 | Fixed | A+W | pass | pass; part by hand not judged |
| E-4 | Fixed | A+W | skipped (locked screen); passes in verify_ui_paths.py | pass |
| E-5 | Fixed | A+W | skipped (locked screen); passes in verify_ui_paths.py | pass |
| E-6 | Fixed | A | pass |  |
| E-7 | Fixed | W | written check | pass; part by hand not judged |
| E-8 | Fixed | W | written check | not judged (by hand) |
| E-9 | Fixed | A | pass |  |
| IA-1 | Core | A+W | pass | pass |
| IA-2 | Negotiable | A | pass |  |
| IA-3 | Core | A | pass |  |
| MA-13 | Core | A | pass |  |
| R-3 | Core | A | pass |  |
| R-4 | Core | A | pass |  |
| R-5 | Core | A | pass |  |
| R-6 | Core | A | pass |  |
| R-7 | Core | A | pass |  |

- No phase-1 test fails. Every fixed- and core-tier test passes except the four whose UI tests were skipped because the screen was locked (L-9, M-3, E-4, E-5). Their behaviors pass through `app/macos/TernTests/verify_ui_paths.py` (43/43), which drives the same paths through Tern's internal `debug.*` methods.
- The only negotiable phase-1 requirement passes, so COMPROMISES.md holds trade-offs, not failures.
- Extra tests for this design's risks: `acceptance/tests/test_tern_extra.py` (22, all pass). Ghostty's own unit tests: 354 passed, 0 failed.

## Decisions

Details, candidates and costs: DECISIONS.md.

| # | Decision | Pick | Evidence |
|---|---|---|---|
| 1 | Tabs, and content that isn't a terminal | Tern's own tab model in each window (no AppKit tab groups); the editor is a per-tab panel; phase 2's agent views go on top of panes, so every pane stays a terminal | The M-1–M-6 tests (programs and scrollback survive every move), `test_moving_a_windows_only_pane_to_a_new_tab_keeps_it`, `test_editor_documents_follow_a_pane_out_of_its_dissolving_tab` |
| 2 | Focus (L-8) | `--no-focus` edits the model and nothing else; new windows go below the key window without activating the app | `test_no_focus_creation_never_changes_the_users_focus` and `test_no_focus_move_keeps_selection_and_front_app` sample `ls` throughout; `test_no_focus_creation_keeps_a_background_app_in_the_background` puts Finder in front first |
| 3 | Finding the right instance | Socket path derived from the state directory (`<per-user temp>/tern-<hash>.sock`); panes carry the instance and run id, and stale ones are refused | `test_paths_with_spaces_and_long_state_dirs`, `test_instances_never_talk_to_each_other`, `test_a_terminal_of_an_earlier_run_never_acts_on_the_new_run`, `test_the_cli_outside_tern_ignores_another_instances_pane` |
| 4 | Single instance | `flock` on `<state>/instance.lock` before the app starts (after Ghostty's `+action` commands, which run without it) | `test_simultaneous_launches_leave_one_instance` |
| 5 | Markdown | Foundation's GFM parser → HTML in a `WKWebView` with JavaScript off and a no-script CSP | `test_open_modes_and_several_documents`; E-1 and E-7 screenshots |
| 6 | Persistence | Tern's own `layout.json`/`ui.json` in the state directory, saved continuously and at quit; AppKit restoration off | `test_restart_restores_pins_and_names`, the R-3 tests, the restored-frame probe (review round 2) |
| 7 | Updates | Tern's own updater (Ed25519-signed JSON feed, installs after the app quits); Sparkle removed | `test_never_offers_another_products_updates`, `test_an_older_build_updates_itself`, `test_installer`, and the installed release finding no newer update |

## Compromises

Full table: COMPROMISES.md. No fixed- or core-tier phase-1 test fails, so none of them is an
accepted test failure. In short:

- AppKit window tabs are gone, and with them the native tab bar, tab overview, "Merge All
  Windows" and the `macos-titlebar-style` variants.
- The editor is a panel per tab, not a pane.
- A quit requested by another process (scripts, the installer, logout) doesn't ask about running
  programs; ⌘Q still asks.
- After a restart, the layout comes back, not the programs or scrollback (as with Ghostty).
- Undo of a closed pane lasts Ghostty's `undo-timeout`; undo of a move lasts 10 minutes.
- Development builds never update themselves.
- `wait --pattern` ignores the prompt and the typed command line.
- Each CLI request is closed as its own undo step by posting an application-defined event.

The six accessibility-tree UI tests were skipped because the screen was locked, not because of a
trade-off. Their behaviors were checked another way (below).

## Written checks

`checks/run_checks.py --phase 1` ran on the published build, plus `checks/tern_extra_evidence.py` for screenshots its setup can't produce. Each verdict was judged by looking at the evidence. Full verdicts, with the steps for everything NOT JUDGED: `acceptance/results/checks/REPORT.md`. The screen was locked, so anything needing a person's hands or eyes on the live window is NOT JUDGED.

| Check | Verdict | Left for a person |
|---|---|---|
| S-1 | PASS |  |
| S-3 | PASS | Close and pin controls on hover |
| S-4 | NOT JUDGED | all of it |
| S-5 | PASS |  |
| S-6 | PASS |  |
| S-2 | PASS |  |
| P-2 | PASS | Choosing the menu item and seeing its dialogs |
| I-5 | PASS | Seeing the window on screen |
| L-9 | PASS | Pressing the keys on a real keyboard |
| M-4 | NOT JUDGED | all of it |
| E-1 | PASS |  |
| E-2 | PASS |  |
| E-3 | PASS | The 'Save changes?' dialog when closing with ⌘W |
| E-4 | PASS |  |
| E-5 | PASS |  |
| E-7 | PASS | Clicking a relative link and an #anchor |
| E-8 | NOT JUDGED | all of it |
| I-3 | PASS |  |
| IA-1 | PASS |  |

E-1 passes with one flaw: with two files open in a narrow editor panel, the second file's tab is
partly hidden behind the Preview/Source control (the tab row scrolls but doesn't follow the active
file). E-3, E-4 and E-5 were judged through scripted checks plus screenshots, because typing into the
editor needs the accessibility tree.

## Codex review

`codex review --base upstream-base -c model_reasoning_effort="high"` in `app/`. After each round,
every high (P1) and moderate (P2) finding was fixed, the app rebuilt, and the phase-1 suite and
`verify_ui_paths.py` rerun before the next round. Regression checks were added for the findings
that could be scripted.

| Round | Findings | What was fixed |
|---|---|---|
| 1 | 3 P1, 1 P2 | Undo of a move only touches the windows it restores (it could take panes out of unrelated windows); moving a window's only pane to a new tab inserts before removing (the window closed under it); a tab emptied by a move hands its editor documents to the destination; AppleScript tab objects are bound to Tern's tabs. |
| 2 | 1 P1, 5 P2 | Undo/redo of a move keeps the tab's unsaved editor documents; a pane closed in a hidden tab can be undone (its tree is held for the undo interval); New Tab can be redone; AppleScript and App Intents focus, split and close panes in hidden tabs; notification clicks focus the quick terminal again; the CLI's login-shell timeout holds even when the shell hangs. Also found while probing: restored windows came back at the default frame. |
| 3 | 4 P1, 2 P2 | The feed's version (not covered by the signature) is checked before it names a folder (path traversal); quitting asks when a program runs in a hidden tab; `tern claude --window` types its command (the new window wasn't listed yet); Ghostty's Sparkle unit tests removed with Sparkle (unit tests: 354 passed); the Zig build helper uses `Tern.app`/`tern-app`; Redo of a split brings the pane back. |
| 4 | 1 P1, 7 P2 | The shell integration's `ssh` wrapper calls the renamed core executable (`ssh` failed with SSH integration on); Ghostty's `+action` commands run before the single-instance lock; command-palette jumps reach panes in hidden tabs; `wait --pattern` sees output that scrolled past the screen (and, on its first read, the scrollback); `wait --idle` measures bytes written, not screen changes (two small libghostty additions); `update --now` relaunches an isolated instance as itself (and the installer no longer waits on an unreaped exited app); panes made by ⌘T or AppleScript record their starting folder; `keys shift+1` types `!`. Found while rerunning the checks: the editor crashed (an uncaught AppKit exception) when a file reloaded shorter than the cursor position; fixed, with a check. Crash reports had gone to Ghostty's folder (`~/.local/state/ghostty/crash`); they now go to Tern's, and the eight reports from this run were removed. |
| 5 | 0 P1, 4 P2 | New tabs (and `tern claude` tabs) start in the folder of the pane they come from, not the window's focused pane; without shell integration a pane's folder is read from its process (it was assumed to be home, ignoring a configured `working-directory`); focusing another pane of a zoomed tab unzooms it; `release.sh` passes release notes as data. |

Round 5 was the last round the brief allows, so its fixes weren't reviewed again. They are
covered by new tests, and the suite, the extra tests and `verify_ui_paths.py` pass on the
published build.

After the reviews, the first real one-line install failed: under a UTF-8 locale (which Terminal
sets), macOS's bash 3.2 read `$version…` as one longer variable name, and the suite's installer
test (which installs from a local app) never reached that line. The installer was fixed, a test of
the download path with and without a locale was added (it fails on the old installer), and
`install.sh` was replaced on the v0.1.0 release (the app zip and feed are unchanged).

**Left open**
- Round 5's fixes haven't had a Codex review of their own.
- The `ssh` wrapper edits for fish, elvish and nushell weren't run (those shells aren't
  installed here); bash and zsh were tested.
- Ghostty's core still names itself in a few places Tern doesn't control: `tern-app +version`
  prints "Ghostty 1.3.2…", and the SSH terminfo cache lives under Ghostty's XDG folder name.
- The six accessibility-tree UI tests need an unlocked screen (Questions, 1).
- With two files in a narrow editor panel, the active file's tab can sit half hidden behind the
  Preview/Source control (E-1). Fix: scroll the tab row to the active file.

## Questions for the user

1. **Run the six UI tests with the screen unlocked.** The screen was locked for the whole
   second half of the run, so they were skipped (their behaviors pass through
   `verify_ui_paths.py`). With the screen unlocked and the Terminal app allowed under Privacy &
   Security → Accessibility:
   `cd ~/dev/terminal-3/acceptance && uv run pytest --target targets/tern.json --phase 1 -k "shortcuts or undo_redo or toggle_shows or dirty_documents or follows_changes or non_utf8"`.
   The NOT JUDGED written checks list their steps (`acceptance/results/checks/REPORT.md`).
2. **License and copyright.** The release repository's LICENSE is MIT, "Copyright (c) 2026 Alejo
   Acelas (Tern's changes)", above Ghostty's notice. Is that the name and license you want?
3. **Name.** "Tern" (`dev.tern.app`, `alejoacelas/tern`). Keep it, or rename before you share it?
4. **Quitting from outside.** Quit requests from other processes don't ask about running
   programs, so updates and scripts never get stuck on a dialog. Should they ask (and block) instead?
5. **Updates.** New versions download and verify in the background and install when you quit
   Tern. Would you rather be asked before the download?

## What phase 2 should know

**Doors left open**

- **Agent views as panes (AP-2).** Every pane is a terminal (`SplitTree<SurfaceView>` is
  unchanged). A managed session's view belongs as an attachment drawn over a pane, keyed by pane
  id, in `TerminalSplitLeaf` (`macos/Sources/Features/Splits/TerminalSplitTreeView.swift`). The
  terminal underneath is the "shell in the session's folder" AP-2 asks for, and split, move, swap,
  zoom, close/undo, drag, persistence and `ls` all keep working because the leaf is still a
  terminal. Keyboard focus must go to the attachment while it shows (route it in
  `SurfaceView.becomeFirstResponder` or by making the attachment's input first responder in
  `TernLayout.focusPane`). `ls` already reserves the pane's `agent` field (CLI.md).
- **The CLI and the socket.** `agent …` in the CLI and `agent.*` methods in `TernRPC` are reserved
  (they answer "not available yet"). Requests carry `caller: {pane, instance}`; add `session`
  (from a `TERN_SESSION_ID` the app sets in a managed agent's environment) for `self` (MA-12).
  Long-running methods (`agent wait`) must be `async` and suspend, not block the main actor; the
  socket server already handles concurrent requests and slow readers.
- **Agents reaching the app (MA-18).** An agent started by an instance inherits
  `TERN_STATE_DIR`; the CLI derives the socket from it, so it can only reach its own instance.
  `TernEnvironment.scrubInherited` already strips `CLAUDECODE`, `CLAUDE_CODE_*`, `CODEX_*` and
  another pane's identity from the app's own environment (MA-20).
- **Events.** `TernEvents.emit` takes any name; `agent.*` events flow to `tern events` filters
  unchanged.
- **Rendering.** `TernMarkdown.html` (Foundation's GFM parser, no scripts) can render agent replies
  (AP-10).
- **State.** Everything lives under the state directory; put sessions in their own files (for
  example `sessions/`), not in `layout.json`. `layout.json` can gain a per-pane `agent` field to
  reopen agent panes after a restart (AP-11).
- **Interactive agents** (`tern claude`) are tracked separately (`TernInteractive`,
  `interactive_agent` in `ls`); a managed session can coexist in the same model.

**What will constrain phase 2**

- **Quitting.** `TernAppLifecycle.willTerminate` runs on every quit (⌘Q, quit events, SIGTERM,
  update). A quit event from another process is answered `.terminateNow` at once
  (COMPROMISES.md). R-10 requires waiting for or cleanly interrupting running turns first: that
  check has to go into `applicationShouldTerminate` before those early returns (answer
  `.terminateLater` while turns are interrupted).
- **Undo.** Snapshots hold panes weakly and only for 10 minutes; Ghostty's own pane/tab close
  undo holds a closed pane's process for `undo-timeout` (5 s). An agent pane closed by mistake
  must not stop its session (AP-4): closing the pane shouldn't touch the session at all.
- **UI tests need an unlocked screen.** Every accessibility test (AP-1, AP-5 and the phase-1 UI
  tests) is skipped while the screen is locked.
- **The main actor.** All model changes happen on the main actor; agent I/O (pipes, JSON-RPC to
  `codex app-server`, Claude's stream-json) should run on their own queues and hop to the main
  actor only to publish state.

## Release and install (done)

- **Repository:** https://github.com/alejoacelas/tern (public). It holds only:
  - the README with the install command;
  - LICENSE (MIT, with Ghostty's notice);
  - `licenses/` (the embedded fonts).

  No source, `acceptance/`, logs or keys are in it. Its commit uses your GitHub noreply address,
  not this Mac's user and host name.
- **Release v0.1.0** has three files:
  - `Tern-0.1.0.zip` (21.7 MB; the reviewed build, ad-hoc signed);
  - `appcast.json` (its SHA-256 and Ed25519 signature);
  - `install.sh`, replaced after the locale fix described under Codex review.
- **Installed on this Mac** with the one-line command in a fresh login shell:
  - `/Applications/Tern.app` 0.1.0, running;
  - `~/.local/bin/tern`, a link to the app's CLI;
  - no quarantine attribute, so it opened without a Gatekeeper prompt;
  - `tern update --check` on the installed copy: "installed 0.1.0, latest 0.1.0: up to date".
- **Markdown default.** The install made Tern the default app for Markdown, as the brief allows
  at the final install. It was Shade (`dev.shade.terminal`) before. To switch back: Finder → a
  `.md` file → Get Info → Open with → Shade → Change All….
- **Untouched:** `/Applications/Shade.app` and your other `~/.local/bin` entries.

## Install on the other Mac

Paste into Terminal on the M4 Mac:

```sh
curl -fsSL https://github.com/alejoacelas/tern/releases/latest/download/install.sh | bash
```

That installs `/Applications/Tern.app`, links `~/.local/bin/tern`, makes Tern the Markdown app
and opens it. If `~/.local/bin` isn't on that Mac's PATH, the installer says so (`tern` is always
on PATH inside Tern's own terminals). `tern doctor` reports whether `claude`, `codex` and `git`
are on the login PATH. Updates then arrive by themselves (installed when Tern quits), or with
`tern update --now`.

## Publish an update from this Mac

```sh
~/dev/terminal-3/app/dist/release.sh --version X.Y.Z --build
```

It builds libghostty and the app, refuses to publish uncommitted work, stamps the version, signs
the app (ad hoc) and the update (Ed25519), and publishes a GitHub release with the zip, the feed
(`appcast.json`) and `install.sh`. Installed copies pick it up on their next check (or
`tern update`).

**The update-signing key** (if it's lost, installed copies can't verify new updates):
- login keychain, generic password, service **"Tern Update Signing Key"**, account `tern`;
- backup: `~/.config/tern/update-signing-key` (mode 600; `private=` is the key, `public=` the
  matching public key built into the app's `Info.plist` as `TernUpdatePublicKey`).

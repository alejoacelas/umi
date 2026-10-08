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

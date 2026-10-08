# Tern: phase 1 report

_Draft: results sections are filled in at the end of the run._

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
| `app/src/apprt/embedded.zig` | The one libghostty addition: `ghostty_surface_read_output_text` |
| `acceptance/targets/tern.json` | The suite's target file |
| `acceptance/tests/test_tern_extra.py` | Tests added for this design's risks |
| `app/macos/TernTests/verify_ui_paths.py` | Checks of the UI-only behaviors without the accessibility tree |
| `DECISIONS.md`, `COMPROMISES.md`, `acceptance/TEST_CHANGES.md` | Decisions, trade-offs, suite changes |

<!-- STATUS -->

## Decisions

Details, candidates and costs: DECISIONS.md.

| # | Decision | Pick | Evidence |
|---|---|---|---|
| 1 | Tabs, and content that isn't a terminal | Tern's own tab model in each window (no AppKit tab groups); the editor is a per-tab panel; phase 2's agent views go on top of panes, so every pane stays a terminal | The M-1–M-6 tests (programs and scrollback survive every move), `test_moving_a_windows_only_pane_to_a_new_tab_keeps_it`, `test_editor_documents_follow_a_pane_out_of_its_dissolving_tab` |
| 2 | Focus (L-8) | `--no-focus` edits the model and nothing else; new windows go below the key window without activating the app | `test_no_focus_creation_never_changes_the_users_focus` and `test_no_focus_move_keeps_selection_and_front_app` sample `ls` throughout; `test_no_focus_creation_keeps_a_background_app_in_the_background` puts Finder in front first |
| 3 | Finding the right instance | Socket path derived from the state directory (`<per-user temp>/tern-<hash>.sock`); panes carry the instance and run id, and stale ones are refused | `test_paths_with_spaces_and_long_state_dirs`, `test_instances_never_talk_to_each_other`, `test_a_terminal_of_an_earlier_run_never_acts_on_the_new_run`, `test_the_cli_outside_tern_ignores_another_instances_pane` |
| 4 | Single instance | `flock` on `<state>/instance.lock` before Ghostty starts | `test_simultaneous_launches_leave_one_instance` |
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

<!-- CHECKS -->

<!-- REVIEW -->

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

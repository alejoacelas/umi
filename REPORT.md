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

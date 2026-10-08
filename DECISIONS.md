# Architectural decisions (phase 1)

Each decision lists the candidates I saw, what each costs against SPEC.md, the pick, and the
evidence. "Tests" are acceptance-suite tests (`acceptance/tests/…`); `test_tern_extra.py` holds
the tests I added for risks of these choices.

Product identity used throughout: **Tern** (`Tern.app`, bundle id `dev.tern.app`, CLI `tern`,
state directory `~/Library/Application Support/Tern` or `$TERN_STATE_DIR`, control socket
`<per-user temp dir>/tern-<hash>.sock`, release repository `alejoacelas/tern`).

---------------------------------------------------------------------------------------------------

## 1. Windows, tabs and panes that aren't terminals

What it has to serve: E-1 (an editor panel beside a tab's terminals), M-1–M-6 (live terminals
move between panes, tabs and windows, with undo and drag), L-2 (pinned tabs grouped), L-8 (no
focus change at any moment), and in phase 2 AP-2 (an agent's view behaves like any pane: split
next to it, move, swap, zoom, close and undo, drag, with a shell in the session's folder).

### Tabs: whose model?

| Candidate | Cost |
|---|---|
| A. Keep Ghostty's model: every tab is an `NSWindow` in an AppKit window tab group, the tab bar hidden behind a sidebar (what the reference UI did) | AppKit selects a tab when one is added and activates windows when shown, so `--no-focus` can only *put focus back* afterwards; L-8 says "at every moment, not just eventually". Reordering means removing and re-adding windows (flicker, focus churn), so pins (L-2) and drag-reorder fight AppKit. The system "prefer tabs" setting can merge new windows into tabs (M-6). |
| B. **Tern's own tab model**: a window controller holds `[TernTab]`, each a split tree plus name/color/pin/editor; the window shows the selected tab's tree and the others keep running off screen | Upstream code that assumed "one controller = one tree" had to learn about hidden tabs: lookups (`ownsSurface`), panes that exit in a hidden tab, undo of tree changes made in another tab, occlusion. All of it lives in `TerminalController`/`BaseTerminalController` and is covered by tests. |

**Pick: B.** Creating a tab or window without focus edits the model and nothing else; moving a tab
is moving an object; pins are an ordering rule on an array; `tabbingMode = .disallowed` everywhere
means AppKit never merges windows.

### Non-terminal content

| Candidate | Cost |
|---|---|
| C. Generic split-tree leaf (`SplitTree<PaneHost>`, a leaf hosts a terminal or any view) | ~150 call sites in upstream controllers, drag-and-drop, search, inspector and focus code assume a `SurfaceView` leaf. Large, risky rewrite of fixed-tier behavior for a phase-2 benefit. |
| D. **Attachment on a terminal leaf**: every pane is a terminal; a non-terminal view (a managed agent's transcript, phase 2) is drawn over a pane and keyed by its pane id; the terminal underneath is a shell in the session's folder | Every existing pane operation (split, move, swap, zoom, close and undo, drag, persistence, `ls`) works unchanged because the leaf is still a terminal. AP-2's "a shell in the session's folder is available from the pane" comes for free (toggle the attachment). Costs: an idle shell per agent pane; keyboard focus must go to the attachment while it is showing. |
| E. Agent views as separate windows or tabs, never panes | Fails AP-2 outright. |
| F. Editor as a split-tree pane | E-1 asks for "an editor panel beside the tab's terminals" with editor tabs; a pane per file would multiply panes and still need a per-tab grouping. |

**Pick: D for phase 2's agent views, and a per-tab panel for the editor.** The editor's documents
belong to the `TernTab`, so they move with their tab between windows. The attachment point for
phase 2 is `TerminalSplitLeaf` (an `.overlay` keyed by pane id). Phase 1 doesn't build it: it
keeps the leaf type and pane identity it relies on.

**Evidence.**
- Moves keep programs and scrollback: `test_move_pane_everywhere_keeps_the_program_running`,
  `test_move_tabs_between_windows_keeps_programs`, `test_detached_pane_keeps_its_size`,
  `test_a_pane_that_exits_in_a_background_tab_is_removed`,
  `test_splitting_and_moving_in_a_background_tab_changes_no_focus`.
- Undo of moves across tabs and windows restores trees and focus from snapshots that hold panes
  weakly (undo never keeps a closed pane's process alive). The restore runs in phases (resolve
  every window, take placed panes out of other tabs once, then restore each window) so restoring
  one window can't disturb another. `test_undo_redo_of_moves` is a UI test (skipped while the
  screen was locked); `app/macos/TernTests/verify_ui_paths.py` checks undo and redo of a move
  within a window and across windows through the Edit menu, without the accessibility tree.
- Undo steps for CLI changes: AppKit closes its automatic undo group only after a UI event, so a
  request that registered undo posts a harmless application-defined event. (Explicit groups were
  tried and rejected: AppKit nests them in its automatic group, and an empty one clears the redo
  stack; closing the automatic group by hand makes AppKit throw later. All three were reproduced
  in a standalone program.)
- Editor documents per tab: `test_open_modes_and_several_documents`,
  `test_edit_targets_the_calling_pane_and_never_falls_back`.

## 2. Focus (L-8)

| Candidate | Cost |
|---|---|
| A. Create through AppKit's normal paths (which make the new window key, select the new tab, activate the app) and restore the previous focus right after (the reference UI did this with 50 and 250 ms delays) | Focus visibly moves and comes back; `ls` sampled in between sees the change. Fails "at every moment". |
| B. **Never touch focus for `--no-focus`**: build the tab or pane in the model, add it to a tree without making it first responder, order a new window *below* the key window without activating the app; `ls` reports Tern's own record of the current window | Needs Tern's own notion of "current window" (AppKit has no key window while the app is in the background). A tab created in the background starts at the window's terminal size so its program sees the right rows and columns before it's ever shown. |

**Pick: B.** **Evidence:** `test_no_focus_creation_never_changes_the_users_focus` and
`test_no_focus_move_keeps_selection_and_front_app` sample `ls` continuously during the commands;
`test_placements_and_no_focus` (interactive agents); and, because the suite's own tests start with
Tern in front, `test_no_focus_creation_keeps_a_background_app_in_the_background` puts Finder in
front first and checks it stays there.

## 3. Finding the right instance (P-4, R-4, R-5, R-7)

| Candidate | Cost |
|---|---|
| A. Socket inside the state directory | Breaks with long state-directory paths (Unix socket paths are limited to 104 bytes; the suite's are longer). |
| B. A fixed socket path, or one passed in an environment variable | A stale variable can name a path a *different* instance listens on later. Two instances can collide. |
| C. **Socket path derived from the state directory**: `<per-user temp dir>/tern-<first 16 hex of SHA-256(realpath(state dir))>.sock`, computed the same way by the app and the CLI; panes carry `TERN_STATE_DIR`, `TERN_PANE_ID` and `TERN_INSTANCE=<state hash>:<run id>` | The per-user temp dir comes from `confstr(_CS_DARWIN_USER_TEMP_DIR)`, not `$TMPDIR`, so every process of the user agrees. |

**Pick: C**, with these rules in the CLI and app:
- The CLI only ever connects to the socket of `$TERN_STATE_DIR` (or the default). A state
  directory with no running instance fails with "Tern isn't running for state directory …".
- A pane id from another state directory isn't a caller context at all (an instance's terminal
  pointing the CLI at another instance gets that instance's defaults).
- A pane id from an *earlier run* of the same instance (its run id differs) is refused for
  defaults with a clear message, never replaced by the focused pane.
- The socket is 0600 and the server checks the peer's uid.

**Evidence:** `test_paths_with_spaces_and_long_state_dirs`, `test_instances_never_talk_to_each_other`,
`test_stale_pane_environments_never_act_on_the_wrong_instance`, `test_cli_inside_panes_defaults_to_this_pane`,
`test_a_terminal_of_an_earlier_run_never_acts_on_the_new_run`,
`test_the_cli_outside_tern_ignores_another_instances_pane`.

## 4. Single instance (P-3)

| Candidate | Cost |
|---|---|
| A. Rely on LaunchServices | Doesn't cover direct launches of the executable (scripts, tests, two copies of the app). |
| B. "Whoever binds the socket wins" | Racy: both launches can unlink a stale socket and bind. |
| C. **`flock` on `<state dir>/instance.lock`** taken in `main` before the app starts or any window exists (after Ghostty's `+action` commands, such as the shell integration's `+ssh`, which run without the app) | Released by the kernel however the process dies, so a crash never leaves a stale lock. |

**Pick: C.** A losing launch asks the winner to show itself (`system.activate`) and exits 0.
**Evidence:** `test_simultaneous_launches_leave_one_instance`.

## 5. Markdown rendering (E-1, E-7; phase 2: AP-10)

| Candidate | Cost |
|---|---|
| A. **Foundation's CommonMark/GFM parser (`AttributedString(markdown:)`) → HTML, shown in a `WKWebView` with JavaScript off and a CSP that allows no scripts** (the reference UI's approach, which the user likes) | Foundation drops a few constructs (an image inside a link, task-list markers), which the converter patches. |
| B. Bundle cmark-gfm | More complete GFM, but a C dependency in the Xcode build. |
| C. A JavaScript renderer in the web view | Needs JavaScript on, which is exactly what E-7 forbids for page content. |
| D. Native attributed text | Tables, images and raw HTML are poor. |

**Pick: A.** Local images (Markdown and raw HTML) are inlined as data URIs, so the page needs no
file access; relative links to files open them in the editor; `#anchor` links scroll in place;
repeated headings get `-1`, `-2` suffixes. Phase 2 can render agent replies with the same
`TernMarkdown.html`. **Evidence:** `test_open_modes_and_several_documents`; the E-1/E-7 written
checks (screenshots).

## 6. Persistence (E-3, R-3)

| Candidate | Cost |
|---|---|
| A. AppKit window restoration (Ghostty's) | Saved per bundle id, so every instance (a test instance, a second build) would share and overwrite the user's saved windows; it can't restore Tern's own tabs. |
| B. **Tern's own files in the state directory**: `layout.json` (windows, tabs with names, colors, pins and order, split trees with each pane's folder and name, open editor documents) and `ui.json` (sidebar), saved continuously (debounced 0.25 s) and synchronously at quit and on SIGTERM; restored at launch | Restores layout and folders, not running programs or scrollback (as Ghostty). |

**Pick: B.** AppKit restoration is turned off (`NSQuitAlwaysKeepsWindows = false`,
`isRestorable = false`). `window-save-state = never` turns Tern's own saving and restoring off
(isolated test instances). Unsaved editor edits: closing a file asks; closing a tab or quitting
saves a document whose file hasn't changed on disk since it was loaded, and otherwise keeps a
recovery copy in `<state dir>/recovery/`. **Evidence:** `test_restart_restores_pins_and_names`
(the build is restoration-safe because nothing is shared), `test_dirty_documents_are_not_closed_silently_and_save_works` (UI).

## 7. Updates and releases (P-2, I-4, I-5)

| Candidate | Cost |
|---|---|
| A. Keep Sparkle, point it at Tern's feed and key | Sparkle's code-signature checks, XPC services and UI are built around Developer ID apps; driving "download now, install at quit" from a CLI means writing a custom user driver anyway. Its framework would still be in the bundle. |
| B. **Tern's own updater**: a JSON feed (`appcast.json`) with the version, zip URL, size, SHA-256 and an Ed25519 signature; CryptoKit verification; a helper script that installs after the app exits | ~400 lines to own. |

**Pick: B.** Sparkle and Ghostty's update UI are removed from the build, so no binary or plist
mentions Ghostty's feed or key (P-2). The updater:
- checks in the background (release builds; an isolated instance only when `TERN_FEED_URL` is
  set), from "Check for Updates…", and from `tern update --check`;
- downloads, verifies the SHA-256 and the signature against the public key in `Info.plist`, checks
  the bundle id, version and code signature, clears quarantine, and stages it in the state
  directory;
- installs when the app quits (any quit: ⌘Q, a quit event, SIGTERM) or at once with
  `tern update --now` / "Install and Relaunch"; it never quits by itself;
- `TERN_FEED_URL` points an instance at another feed; `NSAllowsLocalNetworking` lets the test feed
  be plain HTTP on 127.0.0.1.

Releases: `dist/release.sh --version X.Y.Z [--build]` stamps a copy of the built app, signs it ad
hoc, zips it, signs the zip with the key from the login keychain ("Tern Update Signing Key", backup
`~/.config/tern/update-signing-key`), writes the feed and publishes a GitHub release with the zip,
the feed and `install.sh`. The one-line install is
`curl -fsSL https://github.com/alejoacelas/tern/releases/latest/download/install.sh | bash`;
`curl` doesn't set the quarantine attribute and the installer clears it anyway, so Gatekeeper
doesn't prompt for the ad-hoc-signed app. **Evidence:** `test_never_offers_another_products_updates`,
`test_an_older_build_updates_itself`, `test_installer`.

## 8. Smaller decisions

- **`wait --pattern` matches output, not the typed command line.** With shell integration
  (Ghostty injects it), the terminal marks prompt and input cells (OSC 133). A one-function
  addition to libghostty (`ghostty_surface_read_output_text`) reads only output cells, so a
  pattern can't match the command that's about to print it (otherwise `send "x && echo DONE"`
  followed by `wait --pattern DONE` returns before `x` ran). Without shell integration every cell
  is output, so it degrades to matching the screen. **Evidence:** `test_wait_matches_output_not_the_typed_command`.
- **Quitting.** A quit asked for by another process (a quit Apple event: scripts, installers, the
  Dock, logout) doesn't show Ghostty's "processes are running" dialog; ⌘Q inside the app still
  asks. Edits are kept (above) and the layout is saved, so nothing is lost silently.
- **"Running / last command" in the sidebar** comes from every title change Ghostty's shell
  integration makes (recorded before display debouncing, so `true` and `echo hi` show), plus
  command-finished reports; the foreground process is a fallback without shell integration.
- **Interactive agents** (`tern claude …`): the command line is typed into a fresh shell as
  initial input, so it runs exactly as if typed. Its exit is the first command-finished report of
  that pane (OSC 133); a later command is never mistaken for the agent.
- **The editor refuses** folders, FIFOs, devices and sockets (checked with `stat`, never opened),
  files over 16 MB, and binaries (NUL bytes in the first 8 KB). A UTF-8 sample that ends inside a
  character still counts as text. Non-UTF-8 text opens as Latin-1 and is saved back in Latin-1,
  or the save is refused with a message if the text can't be represented.

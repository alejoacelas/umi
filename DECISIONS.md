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

===================================================================================================

# Architectural decisions (phase 2: managed agents)

Same format: candidates, what each costs against SPEC.md (the core tier above all), the pick, the
evidence. Tests are in `acceptance/tests/`; `test_tern_agents_extra.py` holds the tests added for
this design's risks. The code is in `app/macos/Sources/Features/Tern/Agents/` and
`app/macos/TernCLI/agent.swift`.

## 9. Controlling a harness

What it has to serve: MA-1 to MA-29 with both harnesses, and above all MA-23 ("a worker is the
agent the user would get in their own terminal") and the rule that control rests on ids and events
the harness reports, never on reading or typing into a screen.

| Candidate | Cost |
|---|---|
| A. The worker is the real TUI in a terminal pane, driven by typing and reading the screen | Forbidden by the user's own reliability rule (REQUESTS, "no screen scraping or keystroke injection"). No message ids, no turn boundaries, no approvals as data. Fails MA-2, MA-4, MA-5, MA-14 outright. |
| B. Claude through the Agent SDK libraries | By default they load neither `CLAUDE.md` nor the user's settings and use a minimal system prompt (brief, "facts found since"); matching the terminal means re-adding every setting source by hand and chasing each new one. A Node/Python runtime dependency. Fails MA-23 unless perfectly configured. |
| C. Claude Code's own background agents (`claude --bg`, `claude agents`, `attach`, `logs`, new in 2.1.29x) | They run in the user's shared Claude daemon, so workers would mix with the user's own sessions (MA-21, IA-4). `claude --help` shows no programmatic follow-up or turn API: `attach` is a TUI and `logs` is "recent terminal output", which is screen reading again. |
| D. **`claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages --permission-prompt-tool stdio`**, and **one private `codex app-server --listen stdio://` per session** | It is the `claude` CLI itself, so it loads the terminal's configuration (CLAUDE.md, user/project/local settings, skills, MCP servers, plugins, hooks, subagents); Codex's app server loads `config.toml`, AGENTS.md, skills and MCP servers like `codex`. Both report ids: Claude echoes our message uuid (`command_lifecycle`, replay, `result.user_message_uuids`), Codex echoes our `clientUserMessageId` on the `userMessage` item. Costs: no native TUI in the pane (the app renders the session), and two protocols to own. |
| E. A shared Codex app server for all sessions | One thread can be live in only one server (PROTOCOLS X5), every session would share one environment (`agent start --env` couldn't work) and one crash would take all Codex sessions down. Using the user's shared daemon (`codex app-server daemon`, `codex agents`) is excluded by MA-21. |

**Pick: D.** Workers are not terminal programs; their pane renders the session (decision 13) and
keeps a real shell underneath. Full access is `--dangerously-skip-permissions` (Claude) or
`approvalPolicy: never` + `sandbox: danger-full-access` (Codex); otherwise the harness's own
defaults apply, as when the user types `claude`. `--model`, `--effort`, `--permission-mode` go on
Claude's command line; Codex gets `model`/`approvalPolicy`/`sandbox` in `thread/start` and
`thread/resume`, effort as `-c model_reasoning_effort=E`, a profile as `-c profile=P`. Arguments
after `--` go to the harness unchanged.

**Checked against the real CLIs** (Claude Code 2.1.292, codex-cli 0.160.0):
- `--permission-mode default` is still accepted (it isn't in the help's choices any more); `--effort`
  exists; `--append-system-prompt` is recorded with the conversation (`--system-prompt-snapshot`).
- `codex app-server` accepts `-c` overrides; `thread/start` and `thread/resume` take
  `developerInstructions` (generated schema).
- Real-agent tests: `ACCEPTANCE_REAL=1 uv run pytest -m real` (REPORT.md, phase 2) cover project
  instructions, a project skill, project MCP server + hook + subagent in a never-opened folder and
  after a resume, approvals, interrupts, cross-agent orchestration and cut-off turns.

## 10. Message and turn tracking (exactly-once, truthful status)

| Candidate | Cost |
|---|---|
| A. Hand every message to the harness at once and let it queue or steer (Claude injects queued messages at tool boundaries, Codex steers into the running turn) | The harness then holds messages the product can't take back: a redirect can't go ahead of them (MA-25), `--drop-queued` can't cancel them, Claude's `interrupt` has no turn id so it can hit a queued message's turn that just started (MA-25 "never the turn that carries TEXT"), and a crash loses track of which queued ones the model saw. |
| B. Codex's experimental server-side queue (`thread/queue/*`) | Codex only, experimental, and it auto-drains: the same loss of control as A on the Codex side. |
| C. **The product's own queue, one message in the harness at a time**: a message is handed over only when the harness is ready and no turn runs; delivery is what the harness confirms (Claude `command_lifecycle started` or the replay; Codex the `userMessage` item with our client id); a turn ends at Claude's single `result` / Codex's `turn/completed` | Gives up steering a running turn (negotiable in SPEC; COMPROMISES.md). In exchange a message is always in exactly one place: queued (ours, cancellable, re-orderable), written-but-unconfirmed, or delivered. |

**Pick: C.** The rules that follow from it:
- **Ids.** A message id is a UUID the product generates and the harness echoes (Claude's `uuid`,
  Codex's `clientUserMessageId`); the session's `harness_id` is Claude's session id (passed with
  `--session-id`) or Codex's thread id. `agent send` prints the id before delivery.
- **Turns.** Claude: a turn for messages starts at `command_lifecycle started`; a `system/init`
  with no turn running is a turn Claude started by itself (C11wake); `result.user_message_uuids`
  lists what the turn answered, a result with `origin` and no uuids is a self-started turn. Codex:
  the `turn/start` answer names the turn; a `turn/started` for an unknown turn while nothing is
  being started would be a self-started turn (Codex doesn't make them: X15wake, below).
- **Interrupts** name the turn (Codex `turnId`); Claude's interrupt can't, but nothing of ours is
  queued inside Claude, so the only turn it can stop is the one running.
- **Redirect** (MA-25): TEXT goes to the front of the product's queue (`--drop-queued` cancels the
  others), the turn running at that moment is interrupted, and TEXT is handed over when that turn
  ends; a turn still running 30 s after the interrupt gets its harness killed and resumed.
- **Unconfirmed at the end of a process.** Every line a harness wrote is read before its end is
  handled, so a message written but not confirmed was never delivered and is handed over again
  after the resume. After a *product* crash (nothing read the last lines), Codex is asked: the
  `thread/resume` answer lists each turn's `userMessage` with its client id, so a message is
  re-sent only if the thread doesn't have it. Claude can't be asked; a message written to its
  stdin is counted as delivered (it reads stdin before anything else) and continues with the note.
- **Status** is derived, never stored: `needs_input` (pending requests), `starting` (launching or
  resuming), `working` (a turn runs, or a message is unanswered), `idle`, `exited`, `error`.
- **Codex background terminals.** A command still running when its turn completes is a background
  task (`background_tasks`); its late `item/completed` (X15wake) updates the transcript and the
  count, never a turn.

**Evidence.** `test_chaos.py` (Hypothesis sequences of send/interrupt/stop/crash/start under
`FAKE_CHAOS`, and bursts under 8 seeds per harness); `test_follow_ups_racing_the_end_of_a_turn_are_delivered_once`;
`test_interrupt_before_the_harness_takes_the_message`; the MA-25 tests (`test_redirect_goes_next`,
`test_a_redirect_as_the_turn_ends_never_interrupts_the_new_message`, `test_a_redirect_gets_through_a_hung_turn`);
`test_turns_the_agent_starts_itself`; extra tests for the crash windows and Codex background tasks.

**Codex never starts a turn by itself** (the brief's open question). Probed with the real CLI
(`reference/agent-probes/probe_phase2b.py`, logs `X15wake`, `X15wakeb`): a background command
finishing produced one `item/completed` for the finished turn and no `turn/started` in 60–75 s.
The fake now models that (`BACKGROUND n`, with a self-test); MA-28 stays Claude-only, and the Codex
side of the turn tracker still treats an unannounced `turn/started` as a self-started turn.

## 11. Where sessions live, and resumption

| Candidate | Cost |
|---|---|
| A. **The app owns the harness processes**; sessions stop when the app quits; everything a session needs is on disk, a message to a stopped session resumes it, and turns cut off by a quit, crash or update continue by themselves at the next launch | An app crash cuts running turns off (R-10 continues them with a note). One owner, one process to reason about. |
| B. A daemon (from the bundle) owns all harnesses and outlives the app | Turns survive app crashes, but: a second long-lived process to keep in step with app updates (R-8: an old daemon would keep running old code), its own crash and orphan story, and "every process of the product is killed" kills it too (R-2's scenario), so resumption has to be just as good anyway. The user asked for effort on resumption instead. |
| C. A small host process per session that keeps the harness and spools its output to disk | Survives an app-only crash, but the same update and orphan questions as B, per session. |

**Pick: A** (the user's call in SPEC, "Not requirements"). What makes it hold:
- **Send and it runs (MA-24).** A session that isn't running starts its harness on the next message
  with `--resume ID` (Claude) or `thread/resume` (Codex), in the same folder, with the same model,
  effort, access, environment overrides and harness arguments. A folder that's gone fails the
  send at once; a conversation the harness no longer has (Claude's `No conversation found`, Codex's
  `no rollout found`) fails the message with the reason and is never replaced by a fresh one. A
  conversation that never received a message is started fresh under the same id.
- **Cut-off turns (R-10).** At quit, running turns are interrupted cleanly and marked cut off; at
  launch, messages still delivered-but-unanswered (or a self-started turn left open) mark their
  session cut off. Its harness is resumed and gets a note first ("Your previous turn was cut off at
  14:05 on Oct 8 because …; everything you had running was stopped; check the state of your work
  before carrying on"); the note's turn is the cut-off message's reply. The message itself is never
  sent again. Queued messages are delivered after the note.
- **`agent wait` survives a restart**: the CLI reconnects and keeps waiting.

**Evidence.** `test_every_resume_keeps_context_and_settings` (after stop, harness crash, product
killed and app quit), `test_a_send_that_cannot_resume_fails_at_once_and_never_starts_fresh`,
`test_cut_off_turns_continue_by_themselves` (killed and quit, both harnesses),
`test_crash_recovery`, `test_restart_resumes_sessions`, `test_upgrading_keeps_sessions`, the real
`test_a_turn_cut_off_mid_command_continues`.

## 12. Stopping everything (MA-9, R-1)

| Candidate | Cost |
|---|---|
| A. Kill the harness's process group | Misses anything that called `setsid` or double-forked (the fakes' `SPAWN_STUBBORN`, any daemonizing tool). |
| B. Track descendants by parent links | Reparented processes (launchd) drop out of the tree. Misses everything after a product crash. |
| C. **Tag by environment**: every harness gets `TERN_SESSION_ID` and `TERN_STATE_DIR`, which everything it starts inherits; the kernel's copy of each process's environment (KERN_PROCARGS2) finds them all, detached or not, even after the product was killed. Plus the process group and descendants. | A process that deliberately scrubs its environment escapes; reading every process's environment costs ~20–50 ms per sweep. |

**Pick: C, with A and B on top.** Harnesses are spawned with `posix_spawn` as session leaders, with
no inherited descriptor but their three pipes (`POSIX_SPAWN_CLOEXEC_DEFAULT`: an inherited instance
lock would block the next launch). Stop: interrupt the running turn, close stdin, SIGTERM the group
and every tagged process, SIGKILL whatever is left after 1.5 s, then sweep again. Harness exits are
reaped (no zombies). After a crash of the harness, its leftovers are swept the same way before any
resume. At launch, every process tagged with this instance's state directory (an earlier run's) is
stopped before anything starts. Only this state directory's tags are touched (R-5).

**Evidence.** `test_stop_ends_everything_the_agent_started` (a harness that ignores SIGTERM and a
detached child that does too), `test_crash_is_an_error_and_a_follow_up_resumes`,
`test_names_list_rename_remove` (no zombie), `test_no_zombies_accumulate`,
`test_quitting_the_app_leaves_no_unowned_processes`, `test_killing_the_product_leaves_nothing_running_once_it_is_back`.

## 13. Sessions in panes (AP-1, AP-2, AP-11, M-1–M-6)

Built on phase 1's door (decision 1, candidate D): **a session is drawn over an ordinary terminal
leaf**, keyed by the pane's id. The terminal underneath is a shell in the session's folder (a
button, or Window → Toggle Agent Pane's Terminal, shows it). Because the leaf is still a terminal,
split, move (CLI, menus, drag), swap, zoom, close and undo, persistence and `ls` work unchanged;
`ls` reports the pane's `agent`. The attachment outlives a closed pane, so Undo brings the session's
view back with it; closing never touches the session (AP-4). `layout.json` stores each pane's
session, so agent panes come back after a restart (AP-11). One view per pane is cached and reused
when the pane moves, so its scroll position and composer survive.

Rejected: a TUI client (`tern agent attach`) running in the terminal. It would get every pane
behavior for free, but a terminal view takes no text through accessibility (the AP tests type
through it), cards with buttons and Markdown are poor in a terminal, and it would be a second
renderer to keep in step.

The view (AppKit): a header (name, harness, status and activity, Interrupt, Terminal, a drag
grip), the transcript as one read-only text view (Markdown replies with code set apart, tool calls
that expand to their output, requests and notices, all in order; accessibility reads it whole),
cards for pending approvals and questions with buttons, the queued messages, and a composer
(Enter sends, Shift+Enter adds a line, Esc interrupts; drafts kept per session).

## 14. Focus for agent panes (AP-3, L-8)

Phase 1's rule holds: a non-focusing open edits the model only (new tab or split created with
`focus: false`, no first responder, no activation). Keyboard focus for an agent pane is its
composer: when Ghostty makes the pane's surface first responder (pane focus, tab switch, a move),
the surface hands it to the composer on the next turn of the run loop; when the composer takes
focus (a click), the pane becomes its tab's and window's focused pane. `agent open` of a session
already shown focuses that pane only with `--focus`; otherwise it returns the pane and changes
nothing.

**Evidence.** `test_opening_without_focus_never_moves_the_users_focus` (samples `ls` throughout),
`test_open_focuses_an_existing_pane_and_reopens_a_closed_one`, `test_placements`; the UI tests
(`test_follow_up_typed_into_the_pane`, `test_escape_in_the_pane_interrupts`) need an unlocked screen.

## 15. Agent environment and awareness (MA-20, MA-21, MA-23, MA-27, MA-29)

- **Environment.** The user's login shell environment, captured the way a new terminal starts
  (`$SHELL -l -i`, from a clean slate, cached 5 minutes), never the app's or the caller's. Known
  agent markers are dropped even if present; the app's `tern` is put first on PATH (an older `tern`
  in `~/.local/bin` must not answer); `TERN_STATE_DIR`, `TERN_SESSION_ID` and `TERN_INSTANCE` are
  added; `--env` overrides are applied last and kept for every resume.
- **Awareness (MA-27), without being told by whoever started it.** Claude gets
  `--append-system-prompt`, Codex `developerInstructions`: a few lines saying it is a managed
  session nobody may be watching, its name, id, parent and folder, how to report
  (`tern agent report done|blocked|failed "…"`), and that `tern agent …` reaches other sessions
  (`tern agent info self` gives current details). Additive: the harness's own prompt, CLAUDE.md and
  AGENTS.md all still load.
- **What it loaded (MA-29).** Claude's `system/init` (model, MCP servers and their status, skills,
  plugins, agents) and Codex's thread answer plus `mcpServer/startupStatus/updated` become the
  session's `startup`, refreshed at every start or resume; failed and needs-auth servers become
  `flags`, printed as one warning line by `agent wait` and `agent start --wait`. Codex reports its
  servers after the thread opens, so `agent wait` holds its answer up to 5 s while servers are
  still starting.
- **The user's own agents are untouched** (MA-21, IA-4): nothing writes `~/.claude` or `~/.codex`;
  "allow always" is sent with destination `session` (Claude) / `acceptForSession` (Codex) and
  remembered by the product per session, never written to settings files.

## 16. Persistence (R-2, R-3, R-8, R-9)

| Candidate | Cost |
|---|---|
| A. SQLite | Transactions, but a single file shrinks only with VACUUM, and a second storage engine to own. |
| B. **A folder per session**: `session.json` (settings, ids, report, startup; rewritten atomically) and `log.jsonl` (messages and transcript items, append-only, replayed at launch) | Removing a session deletes its folder, so disk follows what the user keeps. A crash can leave a partial last line, which is skipped. |

**Pick: B**, in the state directory (`sessions/`), versioned (`"v": 1`) so a newer build reads an
older build's sessions (R-8). Message states are logged as they change, so after `kill -9` the
launch knows which messages were delivered and which turns were cut off. Tool output kept in the
transcript is clipped to 16 KB (head and tail) so a long run's storage grows with what the user
keeps, not with what tools print (R-9). Nothing is fsynced: the failure the product has to survive
is being killed, and the kernel keeps what was written.

**Evidence.** `test_crash_recovery` (transcript entries kept in order, none reused, nothing
delivered twice), `test_long_runs_stay_fast_and_disk_follows_what_is_kept`,
`test_upgrading_keeps_sessions`, `test_restart_resumes_sessions`.

## 17. Smaller decisions

- **Names** are unique among running sessions; starting one with the name of a finished session
  renames the finished one to `name~<id prefix>` (MA-11 "a finished one gives up its name").
- **`agent stop`** returns once everything is gone. Messages queued before it end `EXITED`; a message
  sent while it stops waits and resumes the session afterwards (MA-3).
- **A crashed harness** fails the message whose turn it was running (`ERROR`, with the reason);
  messages queued behind it are delivered after an automatic resume; two failed starts in a row
  stop the retries and fail what's queued.
- **`agent watch`** is one-shot: one follow-up to OTHER when the watched message's turn ends (default:
  the latest message), the session needs input, or it exits; if that already happened, at once.
- **`agent wait --report`** counts a report made after the message (by order, not clock), never
  returns early on idle, and always prints what the harness says (MA-26's "idle isn't done").
- **Desktop notifications** (AP-7) when a session needs the user or finishes and its pane isn't in
  front; clicking one shows the session. Off in isolated instances.

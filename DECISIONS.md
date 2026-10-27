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

**Pick: C, with A and B on top.** After a harness exits, the process group it led is swept too
(a child that cleared its environment stays in that group); a process id isn't reused while a group
with that id exists, so the group is only touched when no process holds its id. Harnesses are
spawned with `posix_spawn` as session leaders, with
no inherited descriptor but their three pipes (`POSIX_SPAWN_CLOEXEC_DEFAULT`: an inherited instance
lock would block the next launch); writes to a harness go through its own queue, so one that stops
reading can't block the others. Stop: interrupt the running turn, close stdin, SIGTERM the group
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

===================================================================================================

# Decisions after phase 2 (the user's answers)

The user answered phase 2's questions (REQUESTS.md, "Answers after phase 2"): "script quits should
not ask, updates should ask. license is good. default workers to background". SPEC I-4 and AP-3
changed accordingly. Same format as above.

## 18. The update question (I-4)

What it has to serve: "when a background check finds a newer version, it asks the user before
downloading or installing anything. The question never takes focus or blocks work, and it stays
available until answered. Choosing the menu item or running `<cli> update` counts as a yes." Also
P-2's written check, I-4's "never quits the app by itself", and R-10 (an update installs while
turns run only if the user agrees).

### How and where it asks

| Candidate | Cost |
|---|---|
| A. A dialog (`NSAlert`) when a background check finds a version (what "Check for Updates…" used to show) | Takes focus and blocks the app (and every terminal's input) until answered: exactly what I-4 now forbids. |
| B. A sheet on the front window | Doesn't activate the app, but blocks that window's work and grabs its keyboard focus. |
| C. Only a desktop notification with Download / Later buttons | Doesn't take focus, but it isn't "available until answered": banners go away, Notification Center gets cleared, Focus modes and a denied permission hide it, and test instances post none. |
| D. A badge or icon in the window chrome (titlebar) | S-1 forbids titlebar icons on the upper right; a badge says nothing about what to do. |
| E. **A notice at the bottom of every window's sidebar** with Download / Later / Skip, plus **one desktop notification per version** pointing at it, plus `tern update --check/--status` saying it's waiting | The notice is a view update (no first responder, no activation), sits where phase 1's "update ready" notice already was, and stays until answered. If the sidebar is hidden (⌘B), the notification says where the question is and clicking it shows the sidebar. Costs a small persisted file for the answers. |

**Pick: E.** The notice's buttons are not focusable (clicking one is the user's own action); its
text says the version and the installed one. The notification is posted once per version (never in
isolated test instances) and says nothing is downloaded until the user says so.

### What each answer does, over time

The answers live in `<state dir>/update.json` (`skipped`, `laterUntil`, `consent`, `notified`), so a
restart doesn't ask again early or forget a yes. Conventions follow Sparkle's, which macOS users know.

- **Download** (the notice), **"Check for Updates…"**, **`tern update`**, **`tern update --now`**:
  a yes to the newest version V. V is downloaded, verified and staged; it installs when the app quits
  (or at once with "Install Now…" / `--now`, which still asks before cutting agent turns off, R-10).
  The yes is remembered for V: if the app quits or crashes before V is staged, or the download fails,
  the next check downloads exactly V again (the release that check found, not whatever the feed says
  a moment later) without asking. A yes overrides an earlier Later or Skip. It is a yes to V only: if
  the feed has moved on to W when the remembered yes, the notice's Download or its Try Again runs, W
  is asked about instead; a newer W is also asked about after V installs (background checks pause
  while V waits for the quit). `tern update` and the menu item are a yes to the newest version.
- **The latest answer counts**: Later replaces an earlier Skip, Skip replaces an earlier Later, and
  either withdraws a remembered yes whose download hasn't finished; a retry of a remembered yes
  that was queued before such an answer yields to it. While a download runs or one is staged, Later
  and Skip are refused (it installs at quit; nothing is left to decline).
- **A failed download** after a yes (the feed or the zip doesn't answer, or verification fails) shows
  in the notice ("Couldn't download Tern V: …", Try Again / Later) and in `update --status`; the
  menu item also says so in a dialog, since the user just asked.
- **Later**: the question goes away for 24 hours, across restarts; the first check after that asks
  again (about whatever is newest then).
- **Skip** ("Skip This Version"): never ask about V again; a newer version is asked about. `tern
  update` or the menu item still download V if the user wants it after all.
- **No answer**: the question stays (and comes back after a restart, at the first check), and the
  quit installs nothing.
- Explicit checks (`tern update --check`) apply the same rules (they can raise the question, never
  answer it). The menu item and `tern update` don't ask: they are the answer.

### An update downloaded or staged by an older build

Builds up to 0.2.0 download without asking and stage the update in `<state dir>/updates/staged-V/`,
installing it at quit. Phase 2's installed copy runs that code, so it updates to this release as
before (the brief's release check). This build never installs anything it didn't stage itself after
a yes: a staged folder left by an older build (or by a run that crashed) isn't adopted, because its
zip and signature are gone (it can't be verified again) and nobody agreed to it under the new rule.
The question is asked as for any version, a yes downloads a fresh copy and checks its signature, and
leftover staged folders are deleted when a verified download is staged (by then no installer helper
can still be using them: one only runs after the app that staged it quit, before this app started).

### What `update --check`, `--status` and the menu show meanwhile

- `tern update --check` (looks) and `tern update --status` (no network) print the installed and
  newest version and where things stand: "asking (in the sidebar; nothing is downloaded until you
  say yes; `tern update` says yes)", "you chose Later; asks again after …", "you skipped V …",
  "downloading V", "V is downloaded and installs when Tern quits", or the download's error. JSON
  adds `state` (`unknown`, `up_to_date`, `asking`, `later`, `skipped`, `agreed`, `downloading`,
  `ready`, `failed`, `installing`), `question`, `ready`, `later_until`, `skipped`, `consent`.
- `tern update --later` / `--skip` answer from a terminal.
- "Check for Updates…" says "up to date", or starts the download at once and says so (it installs
  when Tern quits; the sidebar shows when it's ready and offers Install Now…), or, when V is already
  staged, offers Install and Relaunch / Install on Quit as before. These dialogs answer the user's
  own menu choice at that moment; nothing pops up later by itself.

### Evidence

- `test_a_background_check_asks_and_downloads_nothing_until_yes` (test_tern_extra.py): an installed
  release-stamped 0.0.1 build, Finder in front; the feed switches to 999.0.0; the background check
  asks (`state: asking`), Finder stays in front, the user's tab and pane don't change, a terminal keeps
  working, no `.zip` is requested over several checks, `update --check` or a restart, and a quit
  installs nothing; then `tern update` downloads and stages it.
- `test_later_asks_again_later_and_skip_waits_for_a_newer_version`: Later holds across a restart
  and the question returns once its time is up; Skip holds across checks and a restart; 999.1.0 is
  asked about; nothing is downloaded.
- `test_update_is_a_yes_even_after_skip_and_the_yes_outlives_a_restart`: `tern update` after Skip is
  a yes; its failed download is retried after a restart without asking, and stages.
- `test_an_older_build_updates_itself` (the suite's own, unchanged) still passes: `tern update` is the
  yes, the install happens at quit.
- The sidebar notice: UI test `test_the_update_question_in_the_sidebar` (buttons, Later, the menu's
  yes) and the I-4 evidence screenshots (written checks).
- Review regressions: `test_a_yes_shows_its_failures_and_never_covers_another_version`,
  `test_try_again_is_a_yes_to_the_failed_version_only`, `test_the_latest_answer_counts`.

## 19. Sessions with no pane (AP-3)

What it has to serve: AP-3 ("`agent start` runs a session in the background by default: it shows
nothing until asked"); S-2 (the sidebar has no agents section); AP-4 (a session can be shown again
from the CLI or the command palette); "needs input is never silently stuck" (core); and the brief's
rule that everything the user and the orchestrator could see about workers before stays reachable.

Before, a worker had a tab: its sidebar row showed its status and activity, the tab showed it live,
⌃⌘J and notifications led to it, `ls` showed its pane, and `agent info`/`ls` showed everything else.

| Candidate | Cost |
|---|---|
| A. A sidebar section or list of background sessions | S-2 forbids an agents section (fixed tier). |
| B. Keep one hidden tab per worker | Hidden tabs still count as tabs (`ls`, ⌘-numbers, the window's tab list) and are what the user asked to avoid. |
| C. One "Workers" tab that collects all background sessions as splits | Dozens of splits in one tab are unusable, and a pane would exist for every session: not "shows nothing". |
| D. **No pane at all; find them through the app's list surfaces and the CLI**: Window > Agent Sessions (every session with status and activity, the ones that need the user first; ✓ when a pane shows it; choosing one shows it), the command palette (same order and text), ⌃⌘J (the one that needs you, opened in a new tab), desktop notifications as before (clicking one shows the session), and the Dock badge counting sessions that need the user | Nothing new in the window chrome; a background session needing the user is visible at a glance (badge), in the menu and in a notification. Costs a submenu kept current as sessions change (accessibility reads menus without opening them). |

**Pick: D.** Details:
- **Showing one**: `agent open SESSION` (a new tab without focus, as before; `--focus`, `--split`,
  `--new-window`), the menu, the palette, ⌃⌘J or a notification (those four show it in a new tab of
  the current window and focus it, since the user asked for it). Closing that pane leaves the session
  running, as before (AP-4).
- **`agent start` with any placement option** (`--tab`, `--split`, `--new-window`, `--focus`,
  `--window W`, `--pane P`) shows the session as before; with none, or `--background`, it shows
  nothing. A person at a terminal gets one line on stderr saying how to show it (scripts and agents,
  whose stderr isn't a terminal, only see the id).
- **The orchestrator** (an agent, or the user's own orchestrator session started in the background):
  `agent ls --parent self` lists the sessions it started (`--parent S` for any session); `agent ls`
  and `agent info` show status, activity, report, background tasks and the pane showing a session,
  if any (`info` says "shown nowhere (background; `tern agent open` shows it)"); `agent wait`,
  `read`, `watch --notify` work the same whether or not a pane shows it. An orchestrator the user
  started in the background is found the same way as any session (menu, palette, `agent ls`).
- **What workers are told** (the awareness note): sessions they start run in the background unless
  they pass a placement; `agent ls --parent self` lists them; `agent open` shows one.
- **Notifications** keep AP-7's rule (needs you, or finished while not looked at). A background
  session is never looked at, so each of its turns that ends notifies, as a worker in an unseen tab
  did before (Questions for the user: limiting "finished" notifications for workers).

### Evidence

- `test_start_shows_nothing_by_default` (the suite's, both harnesses) and `test_placements`.
- `test_workers_run_in_the_background_and_their_orchestrator_finds_them`: a Claude session starts a
  Codex and a Claude worker with no placement; none gets a pane; `agent ls --parent self` from inside
  lists exactly them with their status; `agent open` shows one in a new tab without moving the
  user's focus, and `agent info` then reports its pane.
- `test_any_placement_option_shows_the_session`: `--focus` alone and `--window W` alone show the
  session; nothing and `--background` don't.
- `test_agents_and_people_are_told_workers_start_in_the_background`: the CLI help and the note Claude
  gets (reported by the fake's STATE) say so; "new tab" is gone from the note.
- `verify_agent_panes.py`: Window > Agent Sessions lists background sessions, the one needing input
  first; the Dock badge counts it and clears; choosing an item shows the session focused and marks it.
- The UI tests (`-m ui`) for the menu items.

===================================================================================================

# Decisions for agent sessions, redone (BRIEF-agents.md)

The user replaced phase 2's design (§9–§17, §19) with their own instructions (BRIEF-agents.md §1).
Where those sections conflict with what follows, this part wins. Phase 2's engine (its queue,
turn tracking, process cleanup, storage and both headless drivers) was kept where it still fits;
its pane view, composer, notifications and "two kinds of agent" were not. Requirements: SPEC.md, AG.
Probes: `acceptance/reference/agent-probes/probe_phase3.py`, recorded in PROTOCOLS.md Part 4.

## 20. How sessions are controlled: always headless

The user: "always use headless to launch sessions and control them. sessions can be resumed from
headless to live and back".

| Candidate | Cost |
|---|---|
| A. **Each agent's own headless mode**: `claude -p --input-format stream-json …` (as phase 2), and a private `codex app-server` per session, now listening on a Unix socket | Two protocols to own (already owned). Gives ids, turn boundaries, approvals as data, and steering (below). The live interface can attach to Codex's server (X16). |
| B. The agent's interface in a terminal, driven by typing and reading the screen (Warp drives its local and cloud agents this way, per the study of its client) | No message ids or turn boundaries; a draft in the input box is corrupted by typed text; the user ruled out screen control from the start. |
| C. Claude Code's background agents (`claude --bg`, `claude attach`) | Live ↔ background is native, but there's no programmatic turn or message API, and they run in the user's shared daemon with their own sessions. |
| D. Codex's shared daemon (`codex queue`, `codex agents`) | Mixes with the user's own Codex sessions; one environment for all. |

**Pick: A.** Codex's server moved from stdio to `--listen unix://SOCKET` (a short path in the
per-user temp folder, one per session), which speaks WebSocket (X16): Tern connects with a small
WebSocket client (`TernUnixWebSocket.swift`), and Codex's own interface can attach to the same
server. Evidence: X16, the fakes' and real tests (AG-1, AG-10–AG-15), the hand checks below.

## 21. Headless ↔ live

| Agent | How it goes live | How it comes back |
|---|---|---|
| Claude Code | The headless process stops (it owns the conversation file; two processes would fork it), then the pane's shell runs `"$TERN_CLI" agent attach S`, which execs `claude --resume ID` (`--session-id` for a conversation that never ran) with the session's model, effort, access and arguments, plus `--plugin-dir` (Tern's hook plugin). | The interface exits (`SessionEnd` hook, the attach command finishing in the pane, or its pid gone): the session is headless and idle; the pane shows the read-only view again. |
| Codex | The pane's shell runs `"$TERN_CLI" agent attach S`, which execs `codex resume THREAD --remote unix://SOCKET`: a client of the session's own server. Nothing stops; Tern keeps driving the thread. | The interface exits; the server and thread carry on. |

Why `tern agent attach` and not the agent command itself: one short line is typed (the only text
Tern ever types into a pane), it's the same in every pane and for both agents, and the app does the
handoff when it arrives (stopping Claude's headless process, starting Codex's server if needed),
so the timing can't race. It's a public command too, so a person can attach a session in any Tern
terminal. `$TERN_CLI` is the app's own CLI (another `tern` on PATH must not answer).

**Interactive launch (AG-2):** `agent start … --tab|--split|--new-window` makes the pane at once
with the read-only view, runs the first turn headless, and goes live there when the session
settles. Waiting for "settled" (not just the turn's end) follows Warp's own fix (below): a Claude
turn that ends with background work pending would otherwise lose that work when the headless process
stops.

**Take over (AG-6) is immediate:** for Claude the running headless turn is interrupted (the user's
"taking over is immediate"; Claude can't share a running turn), and messages handed over for
steering but not yet taken in come back to Tern's queue (`cancel_queued`, C15). For Codex the turn
keeps running and shows in the interface.

**The trust dialog:** in a folder Claude Code was never opened in, its interface asks "Is this a
project you … trust?" (C14), even though the session already ran there headless (`-p` skips it).
Tern leaves it to the user: answering it writes to `~/.claude.json`, which isn't Tern's to change
(BRIEF-agents.md §4). Warp writes `hasTrustDialogAccepted` for its harness runs. (Questions for the
user.)

Evidence: C14, X16; hand checks on this Mac on 2026-10-10 with the real CLIs in an isolated
instance: a Claude session started with `--tab` went live after its turn (the trust prompt, then
Claude's interface; hooks reported a typed prompt and its reply into Tern's transcript); a Codex
session went live attached (its history showed, and a message sent with `tern agent send` ran in
the interface); `agent hide` ended an idle Claude interface and closed its pane; `agent open --live`
brought it back live in a new tab; no process was left over. Tests: `test_live.py`,
`test_sessions_real.py`.

## 22. Messages to a live session (AG-9)

| Candidate | Cost |
|---|---|
| A. Type the message into the interface | A draft in the input box is mixed with it; no delivery receipt (the user's reliability rule). |
| B. Warp's mailbox: hooks hand queued messages to the model as `additionalContext` (PostToolUse) or keep it going (Stop `block`) | The brief says it loses messages and isn't to be copied; nothing fires while the interface is idle. |
| C. Wait until the user hands the session back | An orchestrator could wait forever on a worker the user left open in a pane. |
| D. Claude Code's "channels" (an MCP server pushing messages into a running session) | Needs `--dangerously-load-development-channels` for a plugin not on Anthropic's allowlist (`claude` binary strings), and a confirmation at start. |
| E. **Codex: through the session's own server (the interface is only a client). Claude: when its interface is idle and the user has typed nothing there since their last prompt, Tern ends the interface, runs the waiting messages headless (the pane shows the read-only view), and goes live again in the same pane.** | A short flip of the pane for Claude. A message waits while the user has text typed in the interface (`agent info`/`ls` say so; status `needs_input`, since it waits on the user). |

**Pick: E.** "Typed nothing" is known exactly: Tern sees every key that reaches the pane; the
`UserPromptSubmit` hook says the text was sent; Ctrl-C at the prompt clears it. A message is never
delivered within 3 s of a keystroke. Evidence: the hand check above (a message to a live idle Claude
went headless, replied "AGAIN" once, and the interface came back), `test_live.py`.

## 23. Steering and exactly-once (AG-10, AG-11)

The user wants agents to "supervise and steer other agents". Phase 2 gave steering up to keep one
message in the harness at a time.

**Pick: steer by default, keeping every message in exactly one known place.**
- A message sent while a turn runs is handed over at once (Claude: written to its stdin, injected at
  its next step; Codex: `turn/steer` naming the turn, falling back to `turn/start` when the turn just
  ended). Several can be in flight; each is delivered when the agent's own receipt says so (Claude's
  replay / `command_lifecycle started`; Codex's `userMessage` with our client id), and the turn's
  reply answers all the messages it took in (`result.user_message_uuids`).
- `--interrupt` (a redirect) uses `cancel_queued` (C15): Claude gives back what it hadn't taken in,
  and those messages go back to Tern's queue behind the redirect's text, which goes first. Codex
  records a steered message even in an interrupted turn (X17), so it counts as delivered.
- After a crash of the whole product, a Claude message that was written but not confirmed is looked
  up in Claude's own transcript (its `uuid`, or the `source_uuid` of the `queued_command` attachment,
  C14): there → delivered (the turn continues with the cut-off note); not there → sent again. This
  removes phase 2's compromise ("a message written in the instant before a crash counts as
  delivered") whenever the transcript can be read.

Evidence: the fakes' exactly-once and chaos tests (`test_chaos.py`, `test_sessions.py`), the steering
hand check (one reply covered both messages), C15, X17.

## 24. "Finished" means settled (AG-12, AG-13, AG-19)

Warp's bug (claude-code-warp #92, warp #16367): every Claude stop counted as done, although Claude
starts turns by itself when background work it started finishes. Tern's rule: a session is `working`
while a turn runs, a message waits, or background work of its own that will wake it is pending
(Claude's `background_tasks_changed` headless, `background_tasks` + `session_crons` on a live Stop);
`idle` means settled. `agent wait` on the latest message waits for that and prints the newest reply;
a timeout says what's still running. Codex doesn't start turns by itself (phase 2's X15wake), so its
background terminals don't hold it. Interrupts in a live interface fire no hook (Warp's comment, and
none in Claude's hook list): Esc or Ctrl-C typed in the pane followed by two seconds without a hook
counts as an interrupted turn.

## 25. Observability: Tern's plugins (AG-18)

The user: "use the paths warp illustrates for observability of running agents"; "Warp's plugins stay
silent outside Warp; Tern's should stay silent outside Tern".

Warp's path: a plugin per agent whose hooks send structured events to the terminal. Tern takes the
same path, with three changes learnt from Warp's failures:
- **Transport:** Warp writes OSC 777 to the terminal (Claude's `terminalSequence` output, or for Codex
  ≥ 0.155, whose hooks run detached, the terminal found through the process tree), and status broke
  when Claude 2.1.139 and Codex 0.155 changed how hooks reach the terminal. Tern's hook runs Tern's
  own CLI (`$TERN_CLI agent hook EVENT`), which talks to the app over its socket; it needs no
  terminal, so detached hooks and headless sessions are the same case.
- **Silence:** the hook script does nothing unless `TERN_CLI` and `TERN_STATE_DIR` are set (only
  Tern's terminals and sessions have them), and nothing in headless sessions (`TERN_HEADLESS`; Tern
  reads the stream there). It prints nothing and never fails the agent.
- **Done vs paused:** Stop carries `background_tasks`/`session_crons` (§24).

Install: the plugins ship in the app (`Contents/Resources/agent-plugins`, a directory marketplace
for each agent) and are installed with the agents' own commands at launch of the user's copy
(never by an isolated test instance), and updated when the app's version differs. Codex runs no
plugin hook until it's trusted: Tern trusts its own plugin's hooks (and nothing else) through Codex's
app server (`hooks/list`, `config/batchWrite` of `hooks.state.<key>.trusted_hash`). Sessions Tern
shows live load the bundled plugin with `--plugin-dir` and set `TERN_PLUGIN_ROOT`, so an installed
copy stays quiet and nothing reports twice. `tern agent plugins status|install|remove`.

`claude`/`codex` typed by the user in a pane report through the installed plugin and become sessions
Tern knows (`origin: typed`): in `agent ls`, the sidebar and the Dock badge, and supervisable like any
other (a message takes the session back as in §22, with the permission mode its hooks reported).

## 26. Removing a session from its pane (AG-8)

| What the pane shows | What the shortcut (⌃⌘W, Window > Remove Session from Pane, `agent hide`) does |
|---|---|
| The read-only view | Closes the pane; the session carries on headless. |
| Codex's interface | Closes the pane (the interface is a client); the server carries the turn on. |
| Claude's interface, idle | Ends the interface and closes the pane; the session is headless and idle. |
| Claude's interface, mid-turn | Takes the pane out of the layout without closing its terminal ("parked"); when the session settles, the interface is ended and the terminal closed. `agent open` before then puts the parked terminal back in a tab. |

## 27. The CLI for agents with no instructions (AG-20)

The help an agent sees first (`tern --help`, `tern agent --help`) says in one screen what each command
does, in a "command, then one line" layout, with a worked example; every command prints what a script
needs on stdout (the id) and, on stderr, one line saying what happened and what to do next (`agent
start`: "…; `tern agent wait NAME` waits for its reply"); errors say what to do instead ("no session
matches X (`tern agent ls` lists them)"). Names are what agents use: `start` takes `--name`, and every
command takes a name. The live tests in `test_sessions_real.py` give real agents only a task and the
CLI's name.

## 28. Smaller decisions

- **No desktop notifications** (BRIEF-agents.md §2): phase 2's agent notifications are gone; the
  sidebar marks and the Dock badge (TernAttention) replace them.
- **`tern claude [TASK]` / `tern codex [TASK]`** are kept as the short way to start a session for
  yourself: `agent start … --tab --focus`. They no longer type the agent into a shell (that would
  launch outside headless control).
- **Status words:** `stopped` replaces `exited`; `agent wait` prints `STOPPED`. Since §59 it means
  "someone stopped it": a session that merely has no process (its interface closed, its agent
  exited by itself) is `idle`.
- **The read-only view** keeps phase 2's transcript rendering and approval/question cards (answering
  an agent's request isn't composing a message), drops the composer, and adds Take Over. Its
  keyboard focus is the transcript, so shortcuts and copying work there.
- **Restart:** sessions that were live come back live in their restored pane; read-only panes come
  back read-only (AG-7).

===================================================================================================

# Decisions for the app changes decided with the user (BRIEF-agents.md §2)

Panes, tabs, the sidebar and Markdown files (§29–§46); navigation, palettes and shortcuts follow.
Tests: `acceptance/tests/test_tern_panes_ui.py`, `test_tern_nav.py`.

## 29. Equal panes on Ghostty's binary tree (L-19)

Options: (a) replace `SplitTree` with an n-ary
tree like Warp's; (b) keep the binary tree and treat a maximal chain of same-direction splits as
one row ("run"), as WARP-PARITY §2.1 proposes. Picked (b): every caller, the persistence format
(`ratio`), undo snapshots and SwiftUI's split views stay as they are. `SplitTree.inserting` and
`removing` (which every path goes through: ⌘D/menus, `split`, drops, `pane move`, closes, hidden-tab
splits, undo restores) now insert with share 1/(N+1) and remove proportionally, rebuilding the run
as a right-leaning chain. Evidence: `test_splits_along_a_row_share_it_equally`,
`test_closing_a_pane_shares_its_space_in_proportion`, `test_moves_and_drops_share_rows_equally`,
`test_splits_in_a_background_tab_share_equally_too`, the SplitTree unit tests. Known limit (as
WARP-PARITY says): closing D in `Row[A, Col[Row[B,C], D]]` joins B and C to A's row.

## 30. A divider drag moves only its two neighbors

In a chain `A|(B|C)` the divider between A and
B is the split `A|rest`; moving its ratio would rescale B *and* C. Warp moves only A and B. Picked
Warp's behavior: the new shares are written back into the run's existing shape (no structural
change, so SwiftUI keeps the views and the drag isn't interrupted). Keyboard resize
(`pane resize`, ⌃⌘↑/↓) uses the same rule. Evidence:
`test_a_divider_moves_its_neighbors_and_double_click_equalizes_its_row`.

## 31. `--ratio`

It used to set the ratio of the split holding the new pane. With runs, that would
mean a fraction of some sub-chain. Picked: R is the new pane's share of its row; the others keep
their proportions. Same result as before for a single pane (the old test still holds). Evidence:
`test_ratio_sets_the_new_panes_share_of_its_row`, `test_split_with_name_ratio_and_cwd`.

## 32. Pane sizes for tests: `frame` from ratios

NSView frames lag right after a split and don't
exist for hidden tabs. Picked: frames computed from the ratios over the window's measured terminal
area (SwiftUI's GeometryReader around the split view). Extra field, backward compatible.

## 33. Reopen is its own stack (L-20)

Options: (a) set `undo-timeout = 60s` and make ⇧⌘T replay
only undo entries for closes (WARP-PARITY gap 3); (b) a separate stack whose entries hold the closed
panes, tabs and windows for 60 s. Picked (b): undo's stack is linear (a later move or pin is undone
first), and its entries can't be popped out of order. `undo-timeout` stays Ghostty's 5 s for ⌘Z.
Items on the stack keep their processes; when an item expires nothing holds its panes and they end.
The 60 s is Warp's default grace period, fixed (not a setting). Evidence:
`test_reopen_brings_a_closed_pane_back_to_its_slot_with_its_program`,
`test_closed_items_expire_after_60_seconds_and_their_programs_end` (slow).

## 34. What counts as a close

Recorded: a user's close of a pane (⌘W, the menu, `pane close`,
also in hidden tabs), a tab (sidebar ✕, menu, `tab close`, Close Other Tabs/Below), a window (red
button, ⇧⌘W, `window close`); the last tab of a window records the window. Not recorded: moves
(drag, `pane move`, `tab move`), panes whose program exited (they can't come back running), closes
done by Undo of New Tab/New Window. An entry is skipped at reopen time if its panes are back in a
window (Undo brought them back) or all ended. Evidence:
`test_reopen_goes_last_closed_first_and_skips_what_came_back`,
`test_a_pane_whose_program_ended_is_not_reopened`.

## 35. Where a reopened pane goes

Warp drops a pane's reopen entry once its tab is rearranged.
Picked a softer rule: if the tab's tree is as the close left it, the old tree comes back exactly
(same slot, same sizes); otherwise the pane goes beside the pane it was next to, in the same
direction, with its old share; failing that, beside the tab's focused pane; if the tab is gone, a
tab of its own at the old index (the current window if that window is gone). Reopening registers an
undo step ("Reopen Closed Pane/Tab/Window"). Evidence:
`test_a_pane_comes_back_beside_its_neighbor_after_its_tab_changed`,
`test_reopen_brings_back_closed_tabs_and_windows_in_their_place`.

## 36. Row line 1 and line 2 (S-3)

The user: "its folder and then its session's title". Picked:
line 1 is the folder, unless the user named the tab (a name is explicit, so it wins; clearing it
brings the folder back). Line 2: the agent session's title (TernAttention), falling back to its
status while it has no title; for a tab with no agent, what the old S-3 said (running or last
command, an interactive agent's running/exited, else the folder's path). The session shown is
`TernAttention.agent(for:in:)`'s choice (focused pane's, else the strongest mark, else the latest
stop). Evidence: `test_rows_show_the_folder_then_the_sessions_title`,
`test_a_tab_without_an_agent_shows_its_command_on_line_2`, `test_rows_keep_the_branch_and_pane_count`.

## 37. Agent data comes only from TernAttention

The row used to read the old engine's
`TernAgentUI` snapshot (status · activity). It now reads only `TernAttention`, the interface the
lead's engine writes. Until the engine writes it, managed sessions show as plain terminals in rows.

## 38. Marks

Claude: a starburst of rays; Codex: a hexagon around a dot (11 pt, stroked,
monochrome, drawn as SwiftUI shapes: no bundled logos). Colors: none → the chrome's tertiary ink;
finished-unseen → Tern's accent at 85 %; needs-you → a muted amber at 90 %. Line 2 is brighter while
the session works. No dots, badges or animation on rows.

## 39. Looking

Defined as "focused in the key window while the app is active" (TernAttention's
words). Wired at: pane focus changes (`focusedSurfaceDidChange`), tab switches (`selectTab`),
`pane focus`/`tab focus` from the CLI (`TernLayout.focusPane`), window becoming key, the app becoming
active. A session that *finishes* while its pane is being looked at is cleared at once (Warp: a
notification raised while visible starts out read). A session that starts *needing the user*
while looked at isn't cleared by that alone, only by the next look event: TernAttention says the
engine re-marks a still-waiting session on its next update, so clearing needs-you on every change
could ping-pong with the engine. Evidence:
`test_looking_at_the_pane_clears_the_mark` (with `debug.ui.assume_active`), and the `ui` test
`test_looking_at_the_pane_clears_the_mark_ui` for real activation.

## 40. Tab color is a row tint

The 7 pt color dot sat in the icon slot, which agent marks now
need. Picked Warp's way: the color tints the row (8 % at rest, 16 % hovered or selected).

## 41. Drop zones (M-4)

Panes: middle half of a row → into that tab; top or bottom quarter →
a new tab before or after; below the rows → a new tab at the end (Warp's zones). Into a tab, the
pane goes beside that tab's focused pane, to the right (as ⌃⌘←/→ and `pane move --tab`), rather than
at the tab's root as Warp does, so the drag, the shortcuts and the CLI agree. Tabs: top or bottom
half → before or after. A 2 pt accent line shows edge drops; the row tints for "into". A pane
dropped on its own one-pane tab, or a tab on itself, does nothing. Evidence:
`test_a_pane_dropped_on_a_row_moves_into_that_tab`, `test_a_pane_dropped_between_rows_makes_a_new_tab_there`,
`test_a_tab_dropped_between_rows_lands_there`.

## 42. Dragging a tab out (M-4)

SwiftUI's `onDrag` can't tell how a drag ended, so a row's drag
now starts an AppKit dragging session (from a SwiftUI `DragGesture`, minimum 5 pt) whose
`endedAt` sees drops nothing took. Such a drop outside the tab's own window makes a new window there
(the drop point lands on its sidebar near the top); Escape cancels; a drop back over its own window
does nothing (a missed reorder shouldn't tear the tab off). Warp detaches on any drop outside a tab
bar. A window's only tab dragged out moves the window. Evidence:
`test_a_tab_dragged_out_of_its_window_makes_a_window_at_the_drop_point` (the drop handler) and the
`ui` test `test_dragging_a_tab_row_out_of_the_window_makes_a_window_ui` (the real drag).

## 43. Sidebar width (S-8)

Warp: 200 px to 50 % of the window, not saved. Picked: 180–600 pt, and
at most half the window while dragging; saved per window in `layout.json` (`sidebar_width`) and the
last chosen width in `ui.json` for new windows; a tab moved to a new window takes its old window's width;
double-click resets. Per-window *visibility* (optional) is not done: ⌘B is UI-A's item and the
global `TernState.sidebarVisible` is read in several places; it stays app-wide. Evidence:
`test_each_window_has_its_own_sidebar_width`, `test_sidebar_widths_are_restored_with_the_layout`.

## 44. Row menu (S-4)

Warp's sections and order; "Close Other Tabs" and "Close Tabs Below" don't
spare pinned tabs (as Warp) and ask first if a program runs; each closed tab can be reopened. Colors
are a submenu with a checkmark (SwiftUI context menus can't show a row of color dots). "Rename Tab…"
starts the in-place edit; "Rename Pane…" asks with a sheet. Move Tab Up/Down stay within the pin
group: this overlaps UI-A's ⌃⇧←/→; both call `TerminalController.moveTab` inside
`TernLayout.undoable` and emit `tab.moved`, so either can call the other's at merge time. Evidence:
`test_the_row_menu_has_warps_items`, `test_move_tab_up_and_down_stay_in_their_pin_group`,
`test_close_other_tabs_and_tabs_below`.

## 45. The closest tab for a file (E-10)

"Closest": the deepest folder that contains the file
among every pane's working directory (symlinks resolved, so `/tmp` and `/private/tmp` match). Any
pane of a tab counts, not only the focused one (a tab is "in" the folders of all its panes). `/`
never counts (it contains everything); the home folder does. A file already open in some tab shows
there. Ties: the current tab, then the current window in sidebar order, then other windows oldest
first. No match: a new tab started in the file's folder, in the current window (so the next file
from that folder joins it), a new window if none. The Open panel (⌘O) keeps opening in the current
tab, since the person chose from there. Evidence: `test_markdown_opens_in_the_tab_whose_folder_is_closest`,
`test_ties_go_to_the_current_tab_and_any_pane_of_a_tab_counts`.

## 46. Scripted checks of mouse-only paths

`debug.ui.*` control methods (internal, like
`debug.menu`) call the same functions the UI calls: rows (`TernSidebarRowModel`, which the view
renders), drops, the drag-end handler, the row menu (`TernTabMenu.items`, which the context menu
renders), split drops and dividers, the open-file path, and stand in for the engine's TernAttention
writes. `debug.ui.assume_active` counts the app as active (the CLI can't bring it to the front while
the person uses another app). The real gestures are `ui` tests.

## 47. Shortcuts from anywhere (L-10): a key monitor in front of the menu items

Menu key equivalents
alone (WARP-PARITY §2.2's suggestion) don't reach every case: a view's `performKeyEquivalent`
(Ghostty's terminal for its own bindings, WKWebView in the preview) runs before the menu, and AppKit
doesn't match ⇧⌘[ to a "[" + ⇧ menu item reliably (the event's character is "{"). So the items
stay menu items (shown, discoverable, in the palette), and `TernShortcuts.dispatch` performs them
from an app-local key-down monitor before any view sees the key. Tern's defaults also unbind
Ghostty's bindings for these keys (⇧⌘[ ⇧⌘] ⌘1–9 both digit forms, ⌃Tab ⌃⇧Tab ⇧⌘P ⌘,), so the
shortcuts editor shows them free; a binding the user puts in their own Ghostty config for one of
Tern's keys loses to Tern's item (Settings shows both, and changing either moves the key). Keys
without ⌘ or ⌃ (typing) never go to the monitor. Modal alerts and sheets keep their keys. The
monitor refreshes the menu's validation before performing (AppKit's enabled state can be stale).

## 48. ⇧⌘[ history

A list of the tabs visited across windows, most recent last, each once. Back walks
down it with a cursor without reordering (so pressing again goes further back, never ping-pongs);
visiting a tab any other way ends the walk and counts the tab reached by walking as visited (so
Back from the new tab returns to it, as a browser would). A visit is a selection change in the
current window, or a window becoming current. Windows created with focus count at once, even
while the app is in the background.

## 49. ⇧⌘] / ⌃Tab, ⌘1–8 / ⌘9

⇧⌘] and ⌃Tab stay within the window (as in Warp); they wrap. ⌘1–8 / ⌘9 are in a "Show Tab"
submenu of Window, to keep the menu short.

## 50. S-7: how the user's order meets pins and manual moves

I took the lead's suggestion: pins
first (explicit), then current, then last agent stop (most recent first), then never-stopped tabs
in their existing order; the real tab order changes, so `ls`, `#N` and ⌘1–9 follow what the user
sees. Details that weren't in the suggestion:
- *Ping-pong:* every tab-switching key or `tab next/prev/back` freezes the order for 1.2 s after
  the last press (one timer for the app); the reorder then runs for every window, animated.
  Sidebar clicks and `tab focus` reorder at once (the row moves to the top, animated), which is the
  literal ask; I considered waiting until the pointer leaves the sidebar but it needs UI-B's views
  and hides why rows didn't move.
- *Manual placement:* a placement (`tab move`, drag, Move Tab Up/Down, `tab new --index`) runs
  under `TernTabOrder.hold`, so the selection it makes doesn't reorder; the next selection change
  or agent stop does. Among tabs whose agents never stopped, a manual order survives reorders
  (their relative order is kept); among stopped tabs, last stop wins. M-2's test (move to
  `--index 2` and check index 2) passes because of the hold.
- *Pin/unpin* reorders at once (the unpinned tab goes to its place by the rules).
- *A tab with an old stop stays above a tab with no agent* that the user visited recently: the
  user's rule ranks by agent stop; tabs without agents keep a most-recently-current order among
  themselves because the previous current tab is first among them.
- Not configurable. If the user wants manual order back, a `sidebar order manual` switch would be
  the cheap door to add (one flag in `TernTabOrder`).

## 51. ⌃⌘K for "back"

⌃⇧⌘J was the natural pair but Ghostty binds it (`write_screen_file:copy`);
⌃⌘K is free in Ghostty and macOS, and J/K read as next/back. "Back" returns to the pane focused
when a *run* of jumps started (a run continues while each ⌃⌘J starts from the previous jump's
destination), not one step back: the user's words were "goes back (to where you were before
jumping)". A `.session` target calls `TernAttention.shared.showSession` (the lead's); a later ⌃⌘J
from the pane that shows that session continues the run.

## 52. Command palette from the CLI (L-14)

One table in `macos/TernCLI/commands.swift`: each help line
(section, usage, summary) and the palette actions it offers (title, words, values to ask). `tern
help` prints the table; `tern help --json` prints the same table; the palette reads the JSON
from the bundled CLI once per run and runs actions through the bundled CLI with the focused pane's
`TERN_PANE_ID`/`TERN_INSTANCE`/`TERN_STATE_DIR` and folder, so every command defaults to "this
pane" exactly as in a terminal. Commands that stream or block (`events`, `wait`) offer no action.
A typed `tern …` line (first word a known command) runs as typed, so commands without curated
actions are still reachable. Same-title entries are merged: a CLI action that asks for values
replaces the menu item (asked inline rather than in a dialog) and shows its shortcut; otherwise
the menu item wins, then Ghostty's action (which asks before closing a running program, unlike
`tab close`), then the CLI's. Ghostty's own "Command Palette" menu item and `toggle_command_palette`
open Tern's palette; Ghostty's palette remains only for non-Tern windows (Quick Terminal). The
build script now compiles every `.swift` file in `TernCLI/`.

## 53. Pane palette (L-15)

A global most-recently-focused list of panes (`TernFocusHistory`), fed by
focus changes and by `pane focus`/`tab focus`; panes never focused follow in layout order.

## 54. Quick open (L-16)

`git ls-files --cached --others --exclude-standard` from the repository
root of the focused pane's folder (outside a repository, that folder only, as Warp), indexed off the
main thread when the palette opens; up to 100 results; recency from files opened through the
editor (any path) or the palette; changed files from `git status`. `path:line` switches a Markdown
file to source and puts the cursor on the line (`TernDocument.revealLine`, a small editor hook).

## 55. Settings (L-17)

A Settings window (⌘,; Ghostty's "Preferences…" item, which opens the
Ghostty config, is renamed "Open Ghostty Config File" and loses ⌘,). Storage: Tern items in
`<state>/shortcuts.json`; Ghostty keybindings as `keybind = …` lines in `<state>/keybindings.conf`,
which `Ghostty.Config.loadConfig` loads after the user's config files (so a change made in Tern wins
over the user's file, which the UI states), applied by reloading the config. The list of Ghostty
bindings in effect is worked out by replaying, in Tern's load order, Ghostty's built-in defaults
(from the app's own `+list-keybinds --default`), Tern's defaults, the user's config files (and
their `config-file` includes) and `keybindings.conf`, because libghostty has no API to list
keybindings and no Zig changes were allowed. Menu shortcuts need ⌘ or ⌃ (or a function key);
terminal bindings can be any key.

## 56. L-18

`BaseTerminalController.findNextFocusTargetAfterClosing` asks an overridable
`previouslyFocusedSurface(excluding:)` first; `TerminalController` answers from the focus history.
`TernTab.effectiveFocusedSurface` and the undo/hidden-tab close paths use the same history.

## 57. Focus moves are guarded

`TernLayout.moveFocus(to:in:)` replaces `Ghostty.moveFocus` in Tern's
focus paths: it retries until the pane's view is in the window, but only while the window still
wants that pane. With Ghostty's version, quick `pane focus A; pane focus B` across tabs could end
with A focused (A's retry landed after B) — found by the L-15 test.

## 58. Looking clears marks

`TernFocusHistory` calls `TernAttention.shared.looked(atPane:)` when a pane
gets focus in the key window of the active app (UI-B's sidebar may call it too; it's idempotent).

## 59. After the tests of agent sessions (fixes to what they found)

- **`stopped` means someone stopped it.** A session whose live interface closed, or whose agent
  exited by itself, is `idle`: no process runs, and a message resumes it (AG-8: "then the session is
  headless and idle"). Only `agent stop` (or removing it) leaves `stopped`; a crash leaves `error`.
  Taking a stopped session over clears that.
- **Tern's own input counts as typing.** `tern send` and `tern keys` into a live pane are what
  agents and scripts use to type into an interface, so they count like the keyboard: text held on
  the prompt line holds messages back (AG-9), Esc or Ctrl-C ends a turn's `working` (AG-19), and
  Ctrl-U (from either) empties the line, so held messages go.
- **A message that crashed Codex isn't sent again.** When the process dies before Tern hears that
  it took a message in, the message goes back in the queue; on resume, if the thread's history has
  it (by the client id Tern gave it), it ends `FAILED` with the crash as the reason instead of
  being sent again (AG-11, exactly once).
- **A finished background task holds the settle** until the turn it wakes starts (Claude reports
  the task gone before that turn's init), or until 5 s pass with nothing running, for a task the
  running turn took in (AG-12, AG-13).
- **The latest message's wait** gives the newer reply only when it came from a turn the agent
  started itself, never another message's turn (a message requeued behind a redirect).
- **The attach line waits for the shell.** Take Over (and every go-live) types `tern agent attach`
  only once the pane's shell has the terminal again, at most 10 s: Claude Code still owns the
  terminal for a moment after its SessionEnd hook, and the line was swallowed (AG-6).
- **A quit leaves live sessions live.** Interface endings during the app's shutdown are ignored,
  so the session is saved as live in its pane and goes live there after the restart, as soon as
  the pane is restored (AG-7).
- **`agent info` says `running`** (Tern's headless process runs) instead of `live`, which read as
  "in its own interface" next to `location: live`.
- **`CODEX_HOME` is configuration, not a session marker**: the app keeps it, so panes, sessions
  and `agent plugins` use the user's chosen Codex folder.
- **The Dock badge counts sessions that need the user** (a question, an approval, input), not the
  ones that finished while the user wasn't looking: the user's sentence keeps them apart ("when a
  session finishes and the user hasn't looked yet, or it needs them, the agent's icon takes a quiet
  color … The Dock badge counts the sessions that need the user"). Finishes not seen yet show only
  as the sidebar's quiet mark; ⌃⌘J still visits them, after the ones that need the user. (Questions
  for the user.)
- **Codex delivery after a crash is read from the thread's items.** `thread/resume` (and
  `thread/turns/list`) show each turn's first message only, so a message steered into a turn was
  invisible there and could be sent twice. After a resume with unconfirmed messages, Tern pages
  through `thread/items/list` (newest first) until each is found or the history ends; an older Codex
  without that method leaves the summary (the old behaviour).
- **Codex's socket is written on its own queue**, as Claude's stdin already was: a server that stops
  reading blocks only its own writer, and more than 32 MB waiting closes the connection (the session
  then recovers like after a crash).
- **Hiding a session that's working** ends its interface once the interface has nothing running, even
  when messages wait for it (they run headless afterwards); the pane is remembered until the
  interface is gone, so an agent typed in a pane (whose process knows only its pane) is ended too.
- **One interface per conversation, also across a closed pane.** A closed pane's program is kept for
  60 s so ⇧⌘T can bring it back (L-20); a live Claude interface kept that way is ended when its session
  is shown in another pane, and a Take Over waits until it has exited. Likewise no headless process
  starts until the live interface's process is gone (its SessionEnd hook arrives first).
- **Drafts are counted, roughly.** Characters typed into a live interface minus Backspaces; at zero the
  line counts as empty. Edits Tern can't measure (a word deleted, a paste through the menu) leave a
  typed draft standing; Enter, Ctrl-C at the prompt or Ctrl-U clear it.
- **No window-opening animation while the screen is locked or the display asleep.** AppKit's animation
  never ends then, and each window opened unattended kept a worker thread for ever; after 64 the app's
  shared thread pool was exhausted and agent commands stalled (found by the suite, which runs with the
  screen locked). With the screen in use windows open as before.
- **A live interface counts as running everywhere it matters:** `agent resume` and every other path
  start no headless process while it owns the conversation (messages go the usual way, AG-9); `agent
  rm` needs `--force`; its name stays reserved; `update --now` counts its turn.
- **Pasted text is typed text** for the draft rule (pastes go through the clipboard read, which tells
  Tern the pane and the text).
- **A turn the user started in the interface is the agent's own open turn.** If the app quits or
  crashes during it, it continues by itself after the restart (a continuation note run headless; the
  interface then comes back in its pane), like a headless turn (AG-22). If the user quits the
  interface mid-turn, it isn't continued. A failed turn there (StopFailure) makes `agent wait` report
  FAILED until the next turn.
- **Stopping an agent typed in a pane ends what it started**: its process tree is captured before it's
  ended, and what's still running 3 s later and carries the session's or the pane's identity is ended
  too. (A process that double-forked away from the tree before the stop isn't found.)
- **After a crash of the product, a Claude message written but never confirmed is looked up in
  Claude's transcript before anything else**: missing there, it's sent again (no longer counted as
  delivered first).
- **Whether a pane's shell has its terminal** is read from the processes on the pane's tty (the
  terminal's foreground group, `kinfo_proc.e_tpgid`, and its leader's name), because the pty's master
  side can't say on macOS and the shell's environment can't be read (it's started through the setuid
  `login`). Tern types its one line (`tern agent attach`) only when the shell is at its prompt or
  known to be in front; otherwise it gives up and the pane keeps its read-only view. Found on the way:
  process names were read with a buffer `proc_name` refuses, so every process looked like a shell.
- **Tern's plugin counts as current only if it comes from this copy of the app and is enabled**, and
  the agents' plugin commands run from an empty folder of Tern's (run from the home folder, Claude Code
  also treats `~/.claude/settings.json` as project settings). Found while updating this Mac's copy;
  fixed after the 0.4.0 release.


===================================================================================================

# Decisions for Warp's look for terminals and the sidebar order (BRIEF-blocks.md)

The user chose an imitation that keeps the shell underneath: zsh keeps editing the command line, Tern
changes how the terminal looks (SPEC S-9 to S-12). Warp's colors and spacing were taken from its source
(`~/dev/warp`, read only); the numbers are in §61. Code: `src/renderer/tern_blocks.zig` (the layout),
`src/renderer/generic.zig` (drawing), `src/renderer/shaders/shaders.metal` (`tern_rect`),
`src/terminal/{page,Terminal,Screen}.zig` (per-block data), `src/termio/{stream_handler,Exec}.zig`, the
zsh integration (`src/shell-integration/zsh/ghostty-integration`), `src/Surface.zig` (mouse and IME).
Tests: `acceptance/tests/test_tern_blocks.py`.

## 60. Where the blocks live: rows the shell prints, drawn over by the renderer

What it has to serve: Warp's look (a header above each command with the folder and the duration, the
command in bold, a line and space between blocks, the prompt at the bottom), with programs and agents
that read the pane seeing what the shell and programs printed (S-12), and full-screen programs
untouched.

| Candidate | Cost |
|---|---|
| A. The renderer inserts space that isn't in the grid (a pixel offset per row) | Pixel-exact spacing, but every shader that maps rows to pixels changes (text, backgrounds, images, the cursor), and so do the mouse, selection and IME mappings, per row. Rows added visually push others off the top: a program that draws by absolute position (Claude Code's inline interface, progress bars) would be cut. |
| B. A SwiftUI or AppKit overlay over the Metal view | Draws text and shapes easily, but it isn't drawn in the same frame as the terminal: scrolling and output would make the decorations lag or jitter. |
| C. **The shell prints the block's rows; the renderer draws over them** | Spacing comes in whole rows (Warp's 1.0 and 1.1 lines of padding become 1 and 1). Readers see the prompt rows the shell printed (two blank rows and the folder), which is what the shell printed. Everything else in the terminal (selection, search, scrollback, reflow, programs) is unchanged. |

**Pick: C.** (Text can still be drawn a few pixels off its row, which is how Warp's spacing is kept
within whole rows, §61.) Tern's zsh integration sets the prompt to two spacer rows, the folder (`%~`) and an empty
command line, and starts it with `OSC 133;A;cl=line;tern=1`. The renderer, per frame, works out each
viewport row's part in a block (spacer, header, command, output) from the rows' OSC 133 marks, and
draws: the folder in Warp's header color with the duration after it, the command bold, a 1 pt line
along the top of the second spacer row, the folder box at the prompt, the tint and bar of a failed
block. Nothing is written to the terminal, so `read` and `wait --pattern` see the shell's rows (the
folder line is prompt, so `wait --pattern` never matches it).

**Nested shells (review round 4).** A zsh started from the prompt that loads Tern's integration shows
block prompts of its own while the command that started it runs. That command's block is kept (a
small stack of open blocks, with their start times) and finishes with its own end. Tern's zsh
integration tags each prompt and each command end with the shell's pid (OSC 133's `aid`), so the end
reported by the outer shell is matched to its block even when the inner shell's last command
(`exit`) never reported its own end; blocks of shells that ended inside it end then, without a
status.

**Per-block data on the block's first row.** A block's state (prompt, running, done), failure and
duration are 23 bits in the page row's spare padding (`tern_*` fields of `page.Row`): rows are copied
with their metadata through scrolling, reflow (`copyRowMetadata`) and clearing (reset with the row), so
the data stays with the block as long as the block exists, scrollback included, with no side table to
keep in step. The newest block is a tracked pin on the screen until its OSC 133;D; the stream handler
times C to D and records the exit status. Durations are stored in the finest unit that fits 17 bits
(ms to 2 min, then cs, ds, s), so Warp's formats show the right digits (`(0.041s)`, `(1m 8.92s)`,
`(3h 4m 12s)`); past 21 min the hundredths are tenths.

**At the bottom (S-9).** The whole view is moved down by the empty rows below the cursor's row (or
below the last row with anything on it under the cursor: a completion list, a program's status line).
It's one offset for the frame, applied in the projection and the background shader's padding, so text,
backgrounds, images and the cursor move together; the space above is plain background. The surface
maps the mouse (clicks, selection, mouse reports to programs) and the IME position through the same
offset, which the renderer publishes for each frame it draws. Moving the view rather than printing
blank lines keeps the prompt at the bottom through `clear`, ⌘K, resizes and anything that clears the
screen, and adds no rows for readers. Scrolled into history the offset shrinks row for row, so older
lines appear above without a jump.

**Evidence:** `test_the_prompt_sits_at_the_bottom_from_the_start`, `test_output_builds_upward_above_the_prompt`,
`test_it_stays_at_the_bottom_after_clear_and_cmd_k`, `test_a_list_below_the_prompt_is_shown`,
`test_each_command_is_a_block_with_its_folder_its_duration_and_its_output`,
`test_readers_see_what_the_shell_and_programs_printed`, and the screenshot checks below.

## 61. Warp's numbers, and where Tern differs

From `~/dev/warp/app/src/terminal/block_list_element.rs`, `view.rs`, `model/block.rs`,
`context_chips/display_chip.rs`, `warp_core/src/ui/theme/color.rs` (Dark theme):

| Element | Warp | Tern |
|---|---|---|
| Separator | 1 px, foreground at 10%, full width, along the top of every block | same (1 pt) |
| Padding | 1.0 line below output, 1.1 lines above the header, header slot 0.9, 0.19 to the command, 0.5 command to output: 4.69 lines | the same proportions scaled into Tern's four prompt rows (two spacers, folder, command): the separator, the folder and the command are drawn 0.15, 0.21 and 0.28 of a row above their rows, which leaves Warp's half-line gap (0.43 of a row) before the output. The prompt being typed isn't moved. |
| Header | monospace at 0.9×, best-contrast foreground at 60%, cwd (`~` for home), then the duration | the terminal's font and size, foreground blended 60% over the background |
| Duration | `(16.471s)`, `(1m 8.92s)`, `(3h 4m 12s)`, `(10h 43s)`; whole seconds while running, repainted every second | same; a 1-second wake-up of the renderer only while a running block is visible |
| Command | bold | bold (the input cells of the command rows, once it ran) |
| Failed block (non-zero exit only; never a running one) | the theme's red at 10% over the whole block, a 5 px bar in red at the element's left edge | same, the terminal palette's red (color 1), 5 pt, at the pane's left edge |
| Folder box | `surface_1` fill (foreground at 5%), 1 px border at 15%, radius 4, padding 2/4, outline folder icon, 4 px gap, text in foreground blended 50% with cyan | same; the icon is Codicons' outline folder from the bundled Nerd Font symbols; text at the terminal's size |
| Input | pinned to the bottom (Warp's default) | the prompt is pinned to the bottom (§60) |
| Full-screen programs | drawn without any decoration | same: the alternate screen turns the look off |
| `clear` | inserts a screenful of gap | zsh's `clear` clears; the prompt is redrawn at the bottom |

Not drawn (the brief): the "Lines: … Size: …" readout, Warp's input editor, block selection and
actions. Warp's selected/hovered/bookmarked block styles go with block selection.

## 62. Which terminals get the look

- **zsh only, and only Tern's integration.** The look is on for a terminal when Ghostty's shell
  integration injected into it is zsh's and the shell integration feature `tern-blocks` is on (the
  default; `shell-integration-features = no-tern-blocks` turns it off). The zsh integration prints the
  block prompt only when `GHOSTTY_SHELL_FEATURES` has `tern-blocks`, so zsh started anywhere else
  (another terminal, a nested `zsh`) keeps the user's prompt, and the user's `~/.zshrc` is untouched.
  Other shells (bash, fish …) keep the usual look: macOS's bash 3.2 gets no integration at all, so the
  terminal decides at spawn time rather than from the shell's marks. A prompt from another shell's
  integration (no `tern=1`) turns the look off until Tern's prompt comes back, and a Tern block prompt
  turns it on (zsh's integration sourced by hand with `shell-integration = none`; review round 3).
- **Full-screen programs:** the alternate screen has no blocks and no offset.
- **The prompt the shell prints:** the user's PS1 is replaced while the look is on (as Warp ignores
  PS1 by default); zsh's own line editing, completion, `PROMPT_SP`, PS2 and zsh-autosuggestions are as
  before. An empty Enter or Ctrl-C at the prompt leaves that prompt as a block without a command or
  duration, as zsh leaves a prompt line today (Warp doesn't make blocks for them; changing what Enter
  does would change zsh's editing).
- **A long folder** is shortened from the left (`…/rest`) to four columns less than the pane, which
  leaves the folder box's icon room (zsh's `%-4<…<`, worked out each time zsh draws the prompt, so a
  resize re-fits it; Warp's box cuts at 40 characters the same way). A folder that wraps anyway (the
  pane narrowed after the prompt was drawn) keeps all its rows as the header.

## 63. Decorations: one small Metal pipeline

The separators, tints, bars and the folder box are rectangles with optional border and rounded
corners, drawn by a new `tern_rect` pipeline between the cell backgrounds and the text (instanced quads,
a rounded-rectangle distance in the fragment shader, colors through the same `load_color` as the
cells). The debug overlay (`Overlay.zig`, CPU-drawn into a full-window image) was the other candidate:
it redraws and uploads a full-window image on every change, too costly to have on all the time. Text
Tern adds (durations, the folder icon) goes through the same glyph atlas as the terminal's text. The
OpenGL renderer (Linux) doesn't have the pipeline; the generic renderer skips it there at compile time.

## 64. S-7: only the current tab and tabs whose agent stopped move

The user: "other than the focused session, tabs should only move when an agent finishes their turn".
§50 sorted the whole window on every selection, so a tab the user left dropped back to the place its
last stop gave it. Now nothing is sorted:
- selecting a tab moves it to the top of the unpinned tabs; the others keep their places;
- a tab whose agent stops (a newer stop than Tern knew) moves to just below the current tab; several at
  once go most recent first; a stop in the current tab, a mark cleared, or a pinned tab move nothing;
- a stop first seen more than 60 s after it happened (sessions restored at launch) moves nothing, so a
  relaunch doesn't shuffle the restored order;
- placements (drag, `tab move`, Move Tab Up/Down, `tab new --index`, reopen) still hold: the tab they
  select (or the selected tab they move) stays where it was put until another tab is selected, and a
  tab whose agent stops goes just below it (review round 5);
- tab-switching keys still freeze the order for about a second; at the end the selected tab moves up,
  with any tab whose agent stopped meanwhile;
- pin and unpin: `setPinned` puts a pinned tab at the end of the pinned group and an unpinned one at the
  top of the others; then the current tab moves up as usual.

**Evidence:** `test_only_the_current_tab_and_tabs_whose_agent_stopped_move`,
`test_next_tab_walks_the_sidebar_order_as_seen`,
`test_pinned_tabs_stay_first_and_placements_hold_until_the_next_reorder`.

## 65. Left over from 0.4.0

- **The live launch that looked live while `starting`.** After a session's first turn ends, Tern
  stops its headless process and opens the agent's own interface in the pane; until the interface
  reports, the session says `starting` (activity "opening its own interface") with location `pane`.
  The test read `info` and then the screen, and took `starting` to mean the first turn hadn't ended. In
  a loaded full run, waiting for the view's transcript took longer than the 3-second turn, so it read
  the screen during that hand-off and saw the interface. The product was right (the interface never
  starts before the turn ends); the test now checks the order itself: whenever the interface is on
  screen, the first message is already done (TEST_CHANGES.md). The same test's last check has the
  same race the other way round: the interface draws its screen, then runs its SessionStart hook,
  which reaches Tern through `tern agent hook` (a process of its own); until it arrives the session
  is still `starting`, truthfully. With the screen locked a full run hit it too; the test now waits
  for the status to settle. Nothing in the product changed: Tern learns that the interface is up
  from the interface itself.
- **⇧⌘T in Settings.** Reopen was a menu item Tern added on its own, outside its list of shortcut
  items, so Settings (and the key monitor that makes shortcuts work whatever has focus) didn't know it.
  It is now the shortcut item `file.reopen` (File ▸ Reopen Closed …, its title naming what it would
  reopen), listed in Settings, `tern shortcuts` and the palette.
- **The user's agent folders.** Real-agent tests run the user's own `claude` and `codex` (their logins
  are there), and the agents record those runs: Codex's trust answer for the live test's folder in
  `config.toml`, its threads (rollouts, rows in `state_5.sqlite` and `logs_2.sqlite`, index and history
  lines); Claude Code's transcripts, history lines, per-session files and folder trust in
  `~/.claude.json`. A session fixture (`acceptance/tests/agent_config.py`, from `conftest.py` when
  `ACCEPTANCE_REAL` is set) notes what exists first and removes afterwards only what the run added for
  the suite's own folders (the acceptance folder, temporary `acc-*` and pytest folders) and the sessions
  run in them; what was there before stays byte for byte, and isolated instances never install Tern's
  plugins into the user's folders (`TernAgentPlugins.ensureInstalledAtLaunch`). Its log is `results/agent-folders-cleanup.txt`. Evidence:
  `test_suite_hygiene.py` (on a made-up home folder), and the real run's cleanup log.
  What runs before this one left (47 Claude Code project folders and 112 Codex threads for the suite's
  folders, October 7 to 11) predates the fixture and is left in place; the report asks whether to
  remove it.

- **Found by the suite: a Codex message sent again after a crash.** `test_chaos` found Codex sessions
  (start, stop, then a message that crashes it) where the message was delivered up to 39 times. Codex
  had taken the message in (its `userMessage` item was written) and died before its `turn/started`
  reached Tern (under chaos the notification was still in the server's writer). Tern marks a
  conversation as existing only when it sees a turn, so the next start opened a new thread and sent
  the message there, which crashed it again. Now a start resumes the thread Tern last wrote to whenever
  a message to it is unconfirmed, and looks the message up in its items (as after any crash, §59); if
  Codex never recorded that thread ("no rollout found"), nothing reached it, and a new thread is
  opened and the message sent there. Evidence:
  `test_a_message_that_crashed_codex_before_its_turn_was_reported_is_not_sent_again` (fails on the build
  before the fix: 39 deliveries), `test_chaos.py` (17 passed, and 40 random sequences).

- **Found by the final run: a zombie.** A harness process whose session object went away while the
  process was still exiting (the session removed during its stop) had nobody left to wait for it, so it
  stayed a zombie of the app. `TernHarnessProcess` now hands such a process to a small reaper (a
  dispatch process source per pid) when the object goes away first. The test that caught it now fails
  only on a zombie still there 5 s later, and names it (TEST_CHANGES.md).

---------------------------------------------------------------------------------------------------

# Decisions for Umi: the rename and one repository (BRIEF-umi.md)

Product identity from here on: **Umi** (`Umi.app`, bundle id `dev.umi.app`, CLI `umi`, state directory
`~/Library/Application Support/Umi` or `$UMI_STATE_DIR`, control socket `<per-user temp dir>/umi-<hash>.sock`,
user config `~/.config/umi/config`, release repository `alejoacelas/umi`). Everything above this part
says Tern and stays that way.

## 66. One repository: a subtree merge, not a rewritten history

Candidates: (a) `git subtree add --prefix=app` (the app's commits keep their ids; one merge commit
moves the tree under `app/`); (b) rewrite the app's 18,148 commits with an `app/` prefix
(`filter-repo --to-subdirectory-filter`) and merge them. (b) makes `git log -- app/x` reach back, but
every Ghostty commit gets a new id, so upstream Ghostty could never be merged again without
rewriting it too. (a) keeps `git subtree pull --prefix=app` against upstream working, and `git blame`
still follows files into the old history (checked on `UmiPaths.swift` and `Terminal.zig`). Pick (a).
The release repository (4 commits, `alejoacelas/tern`'s README and licenses) was merged the same way
and its files moved to the root (`README.md`, `LICENSE`, `licenses/`). The outer repository's ignore
rules for `app/` and `release-repo/` went; `logs/`, `.worktrees/` and `.ref/` (local Wraith reference
copies, not needed by anything) stay out. Largest blob in the whole history: 22 MB
(`pkg/harfbuzz/libharfbuzz.a`, Ghostty's). No secret in the Tern-era commits (searched for the
signing key itself and common token shapes). The two targets for the old ui-a/ui-b worktrees were
removed (they pointed at `~/dev/terminal-3/.worktrees`).

## 67. What the rename covers

"Everything user-facing" was read as everything a person or a future agent working here sees: not
only the bundle, CLI, state folder, variables, feed, installer, plugins and docs, but the source's own
names too (`Features/Umi`, `UmiPaths`, `umi_blocks.zig`, `ghostty_surface_umi_blocks`, the
`umi-blocks` shell feature and the `umi=1` mark in OSC 133), because a codebase full of `Tern*` types
would keep the old name alive in every future change and review. A script did it with rules that
leave `pattern`, `internal`, `alternate` and `ternary` alone; the diff was checked for any
substitution inside a word. Nothing needs backward compatibility with Tern's names: the shell
integration and the terminal ship together, and the one user setting that changed
(`no-tern-blocks`) wasn't set on this Mac. Kept as Tern on purpose: `DECISIONS.md` up to 65,
`REPORT.md`, `COMPROMISES.md`, `WARP-PARITY.md`, the old briefs, `acceptance/TEST_CHANGES.md`,
`acceptance/spec-drafts/`, `acceptance/reference/` (recorded logs), `acceptance/REQUESTS.md` (the user's
words), and the places that must name Tern: the import (68), the release script's fallbacks to the
key's old keychain name and backup file (71), and `TERN_*` in the variables Umi clears at launch
(Umi started from one of Tern's terminals must not claim to be Tern's pane). P-1 now lists Tern
among the products Umi must coexist with, and the target file lists `dev.tern.app`.

## 68. Coming from Tern: a copy at first launch, with every session stopped

When: while Umi's state directory is being made (before the instance lock, the socket or anything
else exists), only if Umi has no state directory and Tern's exists. Isolated instances copy nothing
unless `UMI_IMPORT_STATE_DIR` names a folder (the tests' way in); an app hosting unit tests is
isolated too (72). What: `layout.json`, `ui.json`, `shortcuts.json`, `keybindings.conf`, `recovery/`
and `sessions/`; not the generated defaults and theme, the update answers and downloads, logs or the
instance files. How: regular files and folders only (a symbolic link is never copied or followed),
files Tern replaces mid-copy are skipped, a failed copy is retried, everything goes into a staging
folder next to the destination that is renamed into place at the end (a crash mid-copy leaves
nothing; staging folders of dead launches are removed). Tern's folder is only read. A note
`imported-from-tern.json` says what was copied, whether Tern was running, and what failed.

Sessions: copying (not moving) leaves every conversation with Tern as well, and Tern may be running
(it is on this Mac, with a live Claude session) or start at any moment. Copied as is, Umi would bring
a live session back live in its pane (`claude --resume` on the conversation Tern's process is using)
and continue a turn Tern was in the middle of (delivering its message a second time). Review round 1
narrowed this to "only when Tern is running" (detected by its instance lock, before and after the
copy); round 2 showed that sampling a lock can't close the window where Tern starts right after.
Pick: every copied session is stopped, whether Tern runs or not: no live interface, harness pid,
queue or self-started turn; messages Tern hadn't finished end as interrupted in the copy; a notice in
the transcript says it was copied and that Take Over continues it in Umi. The panes show the sessions
as before. The cost: a session that was live in a Tern that is no longer running doesn't come back
live by itself, and a turn a crash cut off isn't continued by itself; one Take Over does either. A
session that can't be rewritten is left out. What failed is listed in the note and, for the user's own
copy, in an alert at launch with the way to retry (quit Umi, remove its state directory, open it).
Round 3: watches aren't copied either (a copied watch would message its supervising session when
the watched one finishes, resuming a conversation Tern may be driving; `umi agent watch` sets one up
again), and the copy is created with the permissions of Tern's folder, never looser (round 4: those of the
folder a link leads to, when Tern's folder is itself a link; a moved folder is still copied).

Evidence: `acceptance/tests/test_umi_import.py` (R-11): tabs, pins, splits, sessions and transcripts
copied, Tern's folder byte-identical, nothing copied twice; a turn "Tern" is still running is
delivered once, run by no second process, and finished by "Tern"; a turn cut off by killing "Tern"
isn't continued by Umi; nothing is copied over existing state; links aren't followed. A manual run on
a copy of this Mac's Tern state with its lock held restored the 2 windows and 6 tabs and showed the
live session idle with the notice.

## 69. The icon: an original one ships, the poster only on Alejo's Macs

The brief changed mid-run: the poster's art is Studio Ghibli's, so it must stay out of the
repository, its history and the release. Public build: an original icon drawn in code
(`app/dist/icon/icon.swift`: a prompt over a night sea), on Apple's macOS grid (1024 canvas, 824 body,
corner radius 185.4 with 60% corner smoothing, shadow inside the margin), written to every size of
`UmiIcon.appiconset` and to `AppIconImage` (About, Settings, the Dock tile plugin) by
`make-app-icon.sh`. Ghostty's `Ghostty.icon` no longer goes into the bundle, and the About window shows
Umi (its icon, name, a line about it, links to this repository, its releases and Ghostty) instead of
cycling Ghostty's icons. Ghostty's alternate icons (`macos-icon = blueprint` and so on) stay
available as settings.

Local: `macos-icon = custom` still works in the fork (it reads the file and sets it as the bundle's
Finder icon and the Dock tile, re-applied at every launch, so updates keep it). It goes in Umi's own
config file (70) so Ghostty doesn't pick it up. `app/dist/local-icon.sh` fetches the crop from
1Password, shapes it with `icon.swift shape` into `~/.config/umi/icon.png` and writes the two settings;
it was run on this Mac. Ghostty's mechanism writes a Finder icon file (`Icon\r`) into the bundle's
root; `release.sh` deletes it from the copy it signs, so a dev build that ran with a custom icon still
releases cleanly. Isolated instances never change the icon (they share the bundle id's defaults with
the user's copy and would reset its Dock tile), and Umi's icon notification has its own name. The
source image, `poster.*` and generated local icons are in `.gitignore`.

## 70. `~/.config/umi/config`: settings only Umi reads

Umi reads the user's Ghostty config, which Ghostty itself also reads; Umi-only settings there (the
custom icon, `no-umi-blocks`) would leak into Ghostty or make it report unknown values. Umi now loads
`$XDG_CONFIG_HOME/umi/config` (default `~/.config/umi/config`) right after Ghostty's files and before
the command line, and the shortcuts editor counts it among the user's files.

## 71. The signing key in 1Password

Stored as API Credential "UMI_UPDATE_SIGNING_KEY — umi" in `mac-agents` (field `credential`, plus the
public key and a note), created from a JSON template on stdin so the key never appeared in a command
line, and read back to check it matches the keychain and the backup (compared, never printed).
`release.sh` takes `$UMI_UPDATE_SIGNING_KEY`, then 1Password (`op-agent`/`op`, reference
`$UMI_SIGNING_KEY_REF` or the item's id), then the old keychain item and backup file. It now also
refuses to publish when the key's public half isn't the app's `UmiUpdatePublicKey`, which would make
every installed copy reject the update.

## 72. An app hosting unit tests is never the user's own copy

`zig build test` on macOS also runs `xcodebuild test`, whose host is the app itself with no
`UMI_STATE_DIR`: it was the user's own Umi. The first time it ran here it copied Tern's state into
`~/Library/Application Support/Umi` (a watchdog stopped it within a second, before it registered any
agent plugin; the folder was removed, and Tern and its session were untouched). Asking every caller
to set `TEST_RUNNER_UMI_STATE_DIR` is easy to forget, so the app now detects that it hosts XCTest
(`XCTestConfigurationFilePath`, `XCTestSessionIdentifier`, `XCTestBundlePath`, or XCTest injected
through `DYLD_INSERT_LIBRARIES`) and then behaves as an isolated instance with a temporary state
directory. Checked by running the Swift tests with no isolation variables: 359 passed, the host used
`$TMPDIR/umi-test-host-<pid>`, and no state appeared in Application Support.

## 73. A roomier first window, and isolated instances keep out of the user's window frame

New windows took the nib's 800 × 600 points, which leaves 65 columns beside the sidebar. Under Tern
this was hidden on this Mac because `dev.tern.app` remembered Alejo's own window frame
(`NSWindowLastPosition`), which isolated test instances share; four blocks tests expected that width.
Umi's window nib now starts at 1180 × 740 (about 110 columns with the sidebar; `constrainToScreen`
keeps it on small screens), and isolated instances neither restore nor save the remembered frame, so
tests don't depend on the user's windows and don't move where the user's next window opens.

## 74. CLAUDE.md points to AGENTS.md in words, not with an import

A root `CLAUDE.md` with `@AGENTS.md` made Claude Code, started by the real-agent tests in a folder
inside this repository, stop on "Allow external CLAUDE.md file imports?". It now says in one sentence
to read AGENTS.md, which Claude agents working here still see, with no import to approve.

## 75. S-7: tabs keep their order, as in Warp (0.6.1; replaces §50 and §64)

Alejo (2026-10-27): "fix the tab reordering? right now it has a custom logic and I want to have the
standard behavior from warp that doesn't switch tab order depending on recency". Warp never reorders
tabs on its own: its tab list changes only through the user's moves, pins and new tabs (its
`tab_mru_order` is a separate list for switching, never the bar's order).

- **Selection** never moves a tab, by any route: `selectTab` no longer reports to the order, so a click,
  ⌘1–9, ⇧⌘[ / ⇧⌘], ⌃Tab, `tab focus`, a pane focus, `jump`, a notification and reopen all leave the list.
- **Agent stops** never move a tab; the row's quiet mark (S-3) is the only sign.
- **The user's moves** are the only moves: drag, `tab move`, Move Tab Up/Down, `tab new --index`, pin
  and unpin (unchanged: pinning puts a tab at the end of the pinned tabs, unpinning at the top of the
  others, which is exactly Warp's `pin_tab`/`unpin_tab`).

Options: (a) drop every automatic move (chosen; it is what Warp does and what Alejo asked for);
(b) keep "an agent's stop moves its tab" and drop only the selection rule: rejected, since the stop
rule is the recency ordering he wants gone.

Removed rather than left dormant: `UmiTabOrder` (the 1.2 s settle delay and freeze after tab keys, the
pending and known stops and their attention observer, the 60 s "recent stop" cut-off, placed-by-hand
tracking, `hold` and its wrappers around drops, tab moves, Move Tab, `tab new --index` and reopen),
`TerminalController.reorderTabs` and its `tab.reordered` event (it could no longer fire),
`UmiAttention.lastStop(for:in:)`, and `debug.navigation`'s `order_frozen`.

**Evidence:** `test_selecting_a_tab_never_moves_it`, `test_an_agent_finishing_its_turn_never_moves_its_tab`,
`test_tabs_move_only_when_the_user_moves_them`, `test_next_and_prev_walk_the_sidebar_order_which_stays_put`
(`test_umi_nav.py`), and `test_a_turn_ending_never_moves_a_tab` (`test_live.py`, the fake agents).

## 76. Where new tabs open

**Warp** (its source at commit `6398d1e9`, 2026-10-03): the setting `new_tab_placement` defaults to
`AfterCurrentTab` (`app/src/workspace/tab_settings.rs:23-27`); `new_tab_index_and_group` puts a new tab
at the active tab's index + 1, pushed below the pinned tabs (`app/src/workspace/view.rs:13058-13089`);
every path that makes a tab (new terminal, file, notebook, a child agent) goes through it and then
selects the new tab. Warp has no tab that opens in the background.

**Umi until 0.6.0:** ⌘T inserted the tab after the current one (Ghostty's `window-new-tab-position =
current`, the default), `tab new` and session tabs went last; then the old S-7 moved any new tab that
got selected to the top of the unpinned tabs. So a new tab ended up at the top, not where Warp puts it.

**Now:** a new tab the user goes to opens right after the current tab, below the pinned tabs (⌘T, the
sidebar's +, `tab new`, files and folders opened in a new tab, sessions started with `--focus`), and
still follows `window-new-tab-position = end` if the user sets it. A tab opened in the background
(`--no-focus`, sessions shown without `--focus`) goes last, as it did. Options for those: (a) right
after the current tab too: several then stack newest first, and each one shifts every tab below the
current one while the user isn't looking, which is the kind of movement this change removes; (b) last
(chosen): keeps Umi's placement where Warp has nothing to copy. A pane moved to a new tab still opens
right after its own tab; moved into another window, it goes after that window's current tab when
focused, else last. One function decides (`TerminalController.newTabIndex(selecting:)`).

## 77. Undo and redo move only the tabs the step moved

Moves, pins and pane moves are undone by putting back a snapshot of the windows. Tabs made after the
step without an undo step of their own (a live interface hidden mid-turn and shown again with
`agent open --tab`) aren't in it: the restore put them last (review round 2), and anchoring them to the
tab before them moved them along with the moved tab (round 3). From the order alone it can't be told
which tab a step moved ([A, C, B] → [A, B, C] is C going down or B going up), so the step now records
the tabs it put in, took out of or moved (`TerminalController` reports `insertTab`, `detachTab`,
`moveTab` and `setPinned` to `UmiLayout.tabMoved` while an `undoable` step runs). Undo and redo keep
every other tab in its current order and put each recorded tab back after the tab it follows in the
snapshot. A tab made since and the moved tab can still be ambiguous for redo ([A, S, C, B], undo, redo
gives [A, C, S, B]: C goes back right after A); the rule keeps everything the step didn't move in order.

**Evidence:** `test_undo_and_redo_of_a_move_leave_a_tab_made_since_in_its_place` (both cases, with the
fake Claude), `test_undo_and_redo_put_back_only_the_tabs_a_step_moved`.

## 78. Updates install themselves at a quiet moment (I-4, 0.6.2; replaces §18's default)

Alejo's words (REQUESTS.md, 2026-10-27): "yes let's make install when quiet the default". He builds
Umi on one Mac and uses it all day on the other, and wants each tested release to arrive there without
interrupting him and without acting. Until 0.6.1 a background check asked first (§18) and an update
installed only on quit or when asked.

| Option | Cost |
|---|---|
| A. Keep asking; install on quit | What he asked to replace: he has to answer, and his Umi rarely quits. |
| B. Download without asking, install on quit | Still waits for a quit that may not come for days. |
| C. Download without asking, install at a quiet moment with a short notice (chosen) | Needs a dependable "nothing would be lost" test (§79) and a way out (Not now, a setting, rollback). |

The setting is Ghostty's own `auto-update` key, which Umi parsed but no longer used (Sparkle is gone):
a new value `install` is Umi's default (also when unset); `check` is the old behaviour (ask first,
install on quit or when asked: §18 still describes it); `download` downloads without asking and
installs on quit; `off` checks only when asked. Reusing the key keeps one documented place for it and
needs no new parser. Background checks run every 15 minutes (`UMI_UPDATE_CHECK_SECONDS` still shortens
it in isolated instances); `umi update` checks at once.

## 79. How "quiet" is decided

Every condition must hold, and whatever can't be determined counts as busy. `UmiQuiet.reasons(in:)`
decides from a snapshot (pure, unit-tested); `UmiQuiet.snapshot()` reads the app; the updater looks
once a second while an update waits (one read of the process table, one terminal lock per pane).

- **Sessions** (`UmiAgentSession.quietBlocker`): messages queued or being delivered; something typed
  in a live interface; status `working`, `starting` or `needs_input` (a turn waiting on the user is
  still a turn: a relaunch would cut it off); an interface opening or closing. Every session the app
  knows counts, started by Umi or typed in a pane (AG-18).
- **Panes**, each on its own:
  - *Its own shell at an empty prompt.* The pane's own shell is the process on its tty that the app
    started (through `login`); the pty's foreground process group comes from the kernel's process table
    (the `tpgid` of the processes on the tty). The shell must be in front: anything else in front is a
    program running there, a shell started from the pane's shell (`zsh`, `bash`) included, whose state a
    relaunch would lose. Whatever the shell started besides what is in front is a job (`sleep 600 &`, a
    suspended program) that a relaunch would end, also when an idle agent is in front; `gitstatusd`, a
    prompt helper that lives as long as its shell, is the only exception. Then the shell's own marks (OSC 133, Ghostty's shell
    integration) must say the cursor is in the prompt's input and every input cell from the prompt's
    first row through the rows the input continues on is blank: a new terminal function,
    `ghostty_surface_umi_prompt_state` (0 can't tell, 1 empty, 2 typed). No marks seen, a full-screen
    program's screen or a cursor outside the input is "can't tell". zsh-autosuggestions' grey text only
    shows after something typed, so it never makes an empty prompt look typed.
  - *An idle agent.* A session's read-only view is quiet when the terminal it covers is (its shell at
    an empty prompt, or exited: the terminal can be shown and used under the view). A live interface is
    quiet when it is what's in front, known by its process (the group of the process its hooks came
    from) or by the session its environment names (Umi started it), never by its arguments, and its
    session is idle with nothing typed. "Nothing typed" is what Umi saw typed, pasted or cleared, made
    conservative (review round 1): Esc at the prompt doesn't clear it (only a turn is interrupted), and
    Up or Down at the prompt may recall an earlier prompt, so the line counts as possibly holding text
    until it is sent or cleared (Ctrl-C, Ctrl-U).
  - A pane whose process exited is quiet.
- **Unsaved work**: editor documents with unsaved changes; a modal window, a sheet, a text field being
  edited (a tab rename, a search), the command palette.
- **The user**: a local event monitor sees keys, clicks and scrolling in the app (moving the mouse
  doesn't count); launching counts. `umi send` and `umi keys` aren't the user's input.

Not counted: screen contents. Umi doesn't keep scrollback across a quit, so a finished command's output
goes with the relaunch, as after a quit (R-3).

Evidence: `test_quiet_updates.py` (fake agents, fake time through `debug.update.clock`, input through
`debug.update.input`), `UmiQuietTests`.

## 80. The notice before installing

At a quiet moment the sidebar's update notice says "Updating to Umi X.Y.Z in N s" for 30 seconds (Not
now, Install now), then Umi installs and relaunches. Anything the user does stops the countdown; the
notice then says the update waits for the next quiet moment, with the same two buttons. Keeping the
buttons matters: a click on Install now is itself activity, and if the notice vanished on mouse-down
the click would land on nothing. Not now waits at least an hour (kept in `update.json` across
restarts), then the next quiet moment counts down again. Install now installs at once, but if anything
besides the user's own input stands in the way (a program started meanwhile) it explains what would be
interrupted in a dialog first: the user clicked, so a dialog is fair there. With the sidebar hidden the
notice isn't seen and the update still installs after the countdown: nothing would be lost, by §79.

## 81. The relaunch stays behind the app in front

Restoring the layout presents every window with focus, which activates the app: a relaunch while Alejo
works in another app would have jumped in front of it. Now, when Umi isn't the active app as it quits
to install, the installer relaunches it with `open -g` and leaves `updates/relaunch-background`; the
launch that finds it (at most five minutes old) restores the windows behind the other apps' and doesn't
activate. When Umi was in front, it comes back in front. Evidence: the end-to-end test checks the app
in front stays in front.

## 82. Rollback keeps verified zips

`umi update --rollback` installs the version installed before the current one.

| Option | Cost |
|---|---|
| A. Keep the replaced bundle | Nothing to verify it against later; a different code path from updates. |
| B. Zip the running bundle before replacing it | Unsigned: only its hash could be checked. |
| C. Keep each installed version's downloaded, signed zip (chosen) | The running version may not have one (installed by install.sh or an older updater). |

C is what the brief asked for. The staged update keeps its zip and what it was verified against
(`release.json`); after a successful swap the helper moves them to `updates/kept/VERSION`, writes the
replaced version to `kept/previous` and removes other kept versions. For a running version without a
kept zip, the updater fetches its own release again, from the feed `release.sh` now stamps into each
release (`UmiReleaseFeedURL`), and verifies it like an update while the new version is staged; the
countdown waits for that. `update --now` waits for that too (at most a minute and a half; review round 1).
Rollback verifies the kept zip again (signature, hash, bundle id, version,
code signature) and installs through the same helper. It marks the version it left
(`rolled_back_from`): that version and older ones never install by themselves again, so a rollback
can't be undone by the next quiet moment; `umi update` or `--now` clears the mark. A version that won't
start can't be rolled back from inside it; README gives the installer command with an older release's
feed.

## 83. No update loops

- A failed install (the helper couldn't swap, the app didn't exit) leaves `updates/attempt.json`
  behind: the next launch, still the old version, marks that version `failed_install`, and it doesn't
  install by itself again (a newer one does), not even through a yes remembered from before
  (`auto-update = check`; review round 1); `umi update` or `--now` tries again.
- A file that fails verification isn't downloaded again by the next check (the same file); a network
  failure is retried.
- At the end of the countdown Umi looks once more just before quitting, and stands down if anything
  started meanwhile.
- After a rollback, §82's mark.
- The feed serving an older or the same version never installs anything (versions are compared).
- While an update waits, checks go on: a newer release replaces the staged one.

## 84. Isolated instances never update the user's installed app

An isolated instance (`UMI_STATE_DIR`) refuses to download, install or roll back when its bundle is
`/Applications/Umi.app`, `~/Applications/Umi.app`, the bundle the user's own instance runs from, or the
one it last ran from (it records its location at each launch, `installed-app`, so a copy installed
elsewhere is protected while it isn't running; review round 1). Paths are compared after resolving
links. The
tests stand their own copy in with `UMI_UPDATE_PROTECTED_APP` (it can only add protection). An isolated
instance that does update (a test copy in a temporary Applications folder) relaunches through
`updates/relaunch.sh` with its whole environment and arguments; before, the helper passed only the
state directory and the feed, so a relaunched test instance would have lost its fake agents and run the
user's own `claude` and `codex`.

## 85. A `claude` typed in a pane keeps its flags

A session found through the plugin's hooks (AG-18) took its model from the hook payload and full access
from `permission_mode`; `SessionStart` carries neither in the fakes (and the real CLI's payload carries
no flags at all), and other flags were dropped. After a quit, a crash or an update the interface came
back as `claude --resume ID --plugin-dir …`, without `--dangerously-skip-permissions` (and, with the
fakes, without `--model`). Now
Umi reads the interface's arguments from its process (`KERN_PROCARGS2`, walking up from the hook's
parent to the agent's program) at its first hook and whenever the user types it again, and keeps them:
`--model`, `--effort`, `--dangerously-skip-permissions` and `--permission-mode` become the session's
settings, other options its harness arguments. Parsing follows `claude --help` (2.1.311): options that
take several values take them up to the next option, as Claude's own parser does. Left out: what picks
a conversation (`--resume`, `--continue`, `--session-id`, `--fork-session`), one-offs (`--print`,
`--worktree`, `--tmux`, `--bg`), Umi's or Tern's plugin, and the first prompt, which isn't run again.
For a typed Codex only the model, effort, approvals, full access and profile are kept: its interface
attaches to Umi's own Codex server, where its other flags don't apply. Evidence:
`test_a_claude_typed_with_flags_comes_back_with_them` (quit and restart) and the end-to-end update test.

## 86. A paste is a draft in a live interface

⌘V (a key binding, or Edit > Paste) into a live Claude interface wasn't seen as typing: a pasted draft
didn't hold back a waiting message (AG-9), and would not have held back an update. Now a paste counts as
typed text of the pasted length.

# Product specification (outcomes only)

A macOS terminal, forked from Ghostty, for working with coding agents. This file says **what the
user and their agents must be able to observe**, never how it is built. Every requirement has an ID.
The tag after it says how it is checked:

- **[A]**: an automated test in `tests/` (grep for the ID).
- **[W]**: a written check in `CHECKS.md`. A scripted setup produces evidence, usually a screenshot,
  that a person or model judges against the stated outcome.
- **[A+W]**: both.

`<cli>` is the product's command line tool. Its exact command surface is fixed by `CLI.md`, because
agents and scripts depend on it. `TEST_INTERFACE.md` lists the few things a build must provide so it
can be tested in isolation.

The words come from the user's own requests. Their verbatim requests are in `REQUESTS.md`; when in
doubt, they win.

---------------------------------------------------------------------------------------------------

## How the product is used

This is what the requirements serve, and what decides between them when they compete.

- **The orchestrator.** The user keeps an orchestrator agent running all day, usually Claude Code
  and sometimes Codex, in one of the app's panes (live) or as a headless session.
  - It runs in full-access (bypass permissions) mode.
  - Otherwise it uses its harness's full feature set: the user's skills (notably
    `supervise-workers`), MCP servers, subagents, background tasks, plan mode and questions to the
    user.
- **The workers.** The orchestrator starts Claude Code and Codex workers through `<cli>`, usually with
  full access, in a folder or a fresh git worktree, on a chosen model and effort. Workers run
  headless, and use their harness's full feature set.
  - The `supervise-workers` loop: write a task file, start a worker pointing at it, wait for it to
    finish, read the report, check the evidence, follow up or steer.
  - Follow-ups come seconds or hours later. Sometimes the orchestrator steers, interrupts or stops a
    worker, starts more, or has workers start their own workers.
- **The user.** The user watches all of this in the app. They arrange panes, tabs and windows
  Warp-style, move live terminals and sessions around, read files in the editor, and now and then step
  in: locate a session in a pane, take it over in the agent's own interface, hand it back.
- **Long runs.** The app, the orchestrator and the workers run for days. Over that time the machine
  sleeps, the app quits or crashes, and new builds get installed.

## Priorities

Each requirement below belongs to one of three tiers.

### Fixed: not up for compromise
The Warp-like interface and everything about panes, tabs and windows: creating, arranging and moving
terminals (and agents shown in panes) between panes, tabs and windows, from the UI and the CLI. Also
the product's identity, packaging and editor.

Requirements: P-1 to P-4, I-1 to I-5, L-1 to L-20, M-1 to M-6, T-1 to T-7, S-1 to S-8, E-1 to E-10.

### Core: agent sessions
These outcomes must hold every time, with both harnesses. How they are achieved is open. The user's
order: first, launching sessions that run reliably and that the user can interact with in the pane,
tab or window they choose; second, agents supervising and steering other agents.
- **Launch:** headless start, sessions the user will use going live in their chosen place, fidelity
  to the agent the user would get in their own terminal.
- **Headless and live:** a read-only view only where the user asks for one, taking over at once,
  handing back, removing a session from its pane without stopping it, messages that reach live
  sessions.
- **Supervision:** message ids, steering, exactly-once delivery, wait/read, truthful status,
  interrupt, stop, list, resume, watch, reports, orchestration from inside agents.
- **Observability:** the agents' own hooks report their state, Warp-style, for sessions the product
  started and agents the user typed.
- **A CLI agents can use with no instructions.**
- **Robustness:** crashes, restarts, upgrades, isolation, long runs, no orphans.

Requirements: AG-1 to AG-23, R-3 to R-7.

### Negotiable
Wanted, but these may be simplified, reworked or left out when keeping them would cost reliability in
the tiers above. Record every such compromise in `COMPROMISES.md`: what, why, and which requirement it
protects.
- How the read-only view presents a session, beyond AG-5.
- Approval flows for sessions that don't have full access, beyond surfacing and answering them
  (part of AG-17).

### Not requirements
These are open design decisions, not requirements. Make them on the merits and validate them with the
tests:
- how the read-only view presents a session;
- what process owns agents and sessions, and how the CLI finds the app;
- whether agents keep running while the app isn't. The user's call: sessions may stop when the app
  quits, as long as AG-10 and AG-22 hold. They would rather the effort go into making resumption
  reliable than into keeping agents alive across app restarts.

The user's instructions for agent sessions (BRIEF-agents.md §1, "Agent sessions") replace
`REQUESTS.md`'s "two launch modes": the product always launches and controls sessions headless;
sessions move from headless to live (the agent's own interface in a pane) and back. Control still
rests on identifiers and events the harness itself reports, never on reading or typing into a
screen; the one thing typed into a pane is the command that starts the agent's own interface there.

## Delivery phases

The product is delivered in two phases, each built against this suite. The tiers apply within each
phase.

- **Phase 1, the app:** everything that doesn't need managed agents. That's P, I, L, M, T, S, E and
  IA, and the parts of R-3 to R-7 about windows, panes and the CLI. Two items inside these groups
  wait for phase 2: L-9's ⌃⌘J (jump to the agent that needs the user) and S-3's managed-agent status
  line.
- **Phase 2, the harness:** managed agents, built on phase 1's app. That's MA, AP, the rest of R,
  and the agent parts above.

Tests that need managed agents carry the `harness` marker. `--phase 1` leaves them out, and the
traceability report marks requirements that only they cover as deferred.

Phase 2 requirements (since replaced by AG): MA-1 to MA-29, AP-1 to AP-11, R-1, R-2, R-8 to R-10.

A third run redid agent sessions (AG, replacing phase 2's MA, AP, IA, R-1, R-2 and R-8 to R-10)
and made the app changes the user decided after phase 2.

Phase 1 must not close doors on phase 2. Its decisions about panes, the CLI, control endpoints,
stored state and identity leave room for sessions shown in panes, agent commands in the CLI,
and agents reaching the app from their own processes.

---------------------------------------------------------------------------------------------------

## P. Product and identity

- **P-1 [A]** The app, its bundle id, its state directory, its control endpoints and its CLI name are
  distinct from Ghostty's, from "Wraith"'s and from "Shade"'s. It can be installed and run next to
  them without either one affecting the other.
- **P-2 [A]** The app never offers another product's updates, upstream Ghostty's included. Its
  updates come only from the product's own release feed (I-4).
- **P-3 [A]** Only one instance of a given build runs at a time. A second launch of the same build,
  including two simultaneous launches, ends with exactly one running instance, and that instance keeps
  serving the CLI.
- **P-4 [A]** Inside the app's terminals, `<cli>` is on PATH and commands default to "this pane"
  (and its tab and window).

## I. Installation and packaging

- **I-1 [A]** A packaged build installs on another Apple Silicon Mac with only the package. Nothing
  else is required (no Zig, Xcode, Python or Homebrew). The installer:
  - copies the app;
  - clears the download quarantine;
  - links `<cli>` into `~/.local/bin`;
  - makes the app the default for Markdown, unless asked not to.
- **I-2 [A]** After install, `<cli> doctor` reports what is missing on this machine, for example
  `claude`, `codex` or `git` not on the login PATH, and exits non-zero if anything is.
- **I-3 [W]** `open README.md` (or double-clicking a `.md` file) opens it in the app's editor.
- **I-4 [A]** Updates. An installed copy updates itself from the product's own public release feed:
  - it checks in the background, from a "Check for Updates…" menu item and from `<cli> update`;
  - when a background check finds a newer version, it asks the user before downloading or
    installing anything. The question never takes focus or blocks work, and it stays available
    until answered. Choosing the menu item or running `<cli> update` counts as a yes;
  - it verifies what it downloads, then installs it when the app quits, or at once when the user
    asks (`<cli> update --now`, or the update prompt);
  - it never quits the app or closes terminals by itself to install;
  - an older build updates to a newer one end to end.

  `<cli> update --check` prints the installed and the newest version. Publishing a new version from
  the development Mac is one command.
- **I-5 [W]** One-line install. On another Mac, one command pasted into Terminal installs the latest
  release, with no Gatekeeper prompt and nothing to install first. The release repository's README
  gives the command.

## L. Windows, tabs and panes

All of these work from the CLI (see CLI.md), and the common ones also from keyboard shortcuts and
the menu.

- **L-1 [A]** Create windows, tabs and split panes, optionally in a given working directory or
  running a given command, and optionally named.
- **L-2 [A]** Focus, close, rename (and clear the name of), color, pin and unpin tabs. Pinned tabs
  come first in their window, in pin order, and moving a tab never mixes the pinned and unpinned
  groups.
- **L-3 [A]** Focus, close, rename, zoom (and unzoom), resize and swap panes.
- **L-4 [A]** Selectors: panes, tabs and windows can be named by id or unique id prefix, by user-given
  name, by `.` (the focused one) and by `#N` index (tabs and windows). Ambiguous or unknown selectors
  fail with a clear message and a non-zero exit, and change nothing.
- **L-5 [A]** `--worktree NAME` on tab, split and window creation starts the new pane in a git
  worktree. That's an existing worktree directory, or a worktree with that branch or folder name, or a
  new worktree created next to the repository on a new branch NAME. It works even when git hooks
  print noise.
- **L-6 [A]** Relative `--cwd` values are relative to where the CLI ran.
- **L-7 [A]** `ls` shows every window, tab and pane with their ids, names, working directories,
  focus, zoom and pins.
- **L-8 [A]** Commands that create things accept a "don't focus it" option. The user's selected tab
  and focused pane are then unchanged, at every moment, not just eventually. If the app is in the
  background, it stays in the background: the app that was in front stays in front.
- **L-9 [W]** Keyboard shortcuts:
  - ⌘B toggles the sidebar;
  - ⇧⌘E shows the project explorer;
  - ⌘O opens a file;
  - ⇧⌘M toggles the Markdown preview and source;
  - ⌃⌘T / ⌃⌘N move the pane to a new tab or window;
  - ⌃⌘← / ⌃⌘→ move the pane into the previous or next tab;
  - ⌃⇧⌘N moves the tab to a new window;
  - ⌃⌘P pins or unpins the tab;
  - ⌃⌘R / ⌃⇧⌘R rename the tab or pane;
  - ⌃⌘J jumps to the agent that needs the user.

  The command palette also lists these actions.

## M. Moving live sessions

A "live session" is a pane with a running program, its scrollback and its state.

- **M-1 [A]** A pane can be moved next to another pane in the same tab, into another tab, into another
  window, into a new tab or into a new window. The program keeps running uninterrupted and the
  scrollback is preserved. The source tab or window closes if it becomes empty.
- **M-2 [A]** A tab, with all its panes, can be moved to another window (at a position) or to a new
  window, and reordered within its window. Its programs keep running.
- **M-3 [A]** Moves can be undone and redone. After undo, each tab's focused pane is what it was.
- **M-4 [W]** Panes can be dragged onto other panes, including in other windows. Tabs can be dragged
  in the sidebar to reorder them and onto another window's sidebar.
- **M-5 [A]** A pane moved to a new window gets a window large enough to keep its columns and rows,
  and a window never ends up unusably small.
- **M-6 [A]** A new window created by moving is a separate window. It isn't merged into an existing
  window's tabs.

## T. Terminal input and output, and events

- **T-1 [A]** Send text to a pane (optionally pressing Enter), including text piped on stdin. Send
  named keys (enter, esc, tab, arrows, ctrl+c, …).
- **T-2 [A]** Read a pane's screen or its full scrollback, or the last N lines.
- **T-3 [A]** Wait until a pane's output matches a pattern, or has been idle for N seconds, with a
  timeout. A timeout exits 124. A pane that closes while waited on ends the wait promptly with an
  error.
- **T-4 [A]** A stream of layout events (panes and tabs created, closed, renamed, moved, focused) can
  be followed as JSON lines, optionally filtered by kind or by pane. A consumer that stops reading
  never stalls the app: other commands keep working, and the stalled consumer is eventually
  disconnected.
- **T-5 [A]** Many concurrent CLI invocations all get correct answers.
- **T-6 [A]** Show a desktop notification from a pane.
- **T-7 [A]** The app can capture an image of a window, including terminal contents, through
  `<cli> screenshot`.

## S. Sidebar and look

- **S-1 [W]** No visible containers or borders around the content, Warp-like: the chrome blends into
  the terminal background. The window shows no native tab bar and no titlebar icons on the upper
  right.
- **S-2 [A+W]** A left sidebar, full height, toggled with ⌘B. It has two modes: Tabs and Files
  (project explorer for the focused pane's folder). It has no "agents" section, no "no agents
  running" text and no "new agent" button.
- **S-3 [W]** Tabs mode lists the window's tabs, grouped by tab, with pinned tabs first. Each row has
  two lines:
  - Line 1: the tab name, or else the focused pane's folder name, then the git branch. A linked
    worktree is shown differently from a normal checkout. Also a pane count when split, and close and
    pin affordances.
  - Line 2: what the focused pane is doing. That's the running command or the last one it ran, a
    managed agent's status and activity, or an interactive agent's state (running, exited).
- **S-4 [W]** Rows can be clicked to select, double-clicked to rename, right-clicked for pin, color,
  move and close, and dragged to reorder.
- **S-5 [W]** The theme's chrome text stays readable on light and dark backgrounds. The user's own
  Ghostty config and theme override the product's defaults.
- **S-6 [W]** The "running/last command" line updates for commands that finish instantly.

## E. Editor and Markdown

- **E-1 [A+W]** Opening a Markdown or text file shows it in an editor panel beside the tab's
  terminals. Markdown opens rendered (headings, lists, task lists, tables, code blocks, links,
  images); other text opens as source. Several files can be open as editor tabs.
- **E-2 [A+W]** Preview and source can be toggled with ⇧⌘M, with a visible control, and from the CLI.
- **E-3 [A+W]** Edits can be saved with ⌘S. Closing a file with unsaved changes asks first. Closing a
  tab or quitting never silently loses edits: they are saved, or a recovery copy is kept.
- **E-4 [A+W]** If the file changes on disk:
  - an unmodified document reloads;
  - a modified one shows that the disk changed and offers to reload;
  - a file deleted and recreated is picked up again.
- **E-5 [A+W]** Saving keeps the file's encoding. A non-UTF-8 file stays in its encoding, or the save is
  refused with a message. It is never silently converted.
- **E-6 [A]** The editor refuses things it can't edit safely: directories, FIFOs and devices,
  binaries, files over a size limit. It refuses with a clear message and never hangs. Text whose
  first bytes cut a UTF-8 character at a sampling boundary still opens.
- **E-7 [W]** In the preview, relative links to other files open them, and `#anchor` links scroll
  within the document. Repeated headings get distinct anchors. Local images, relative to the
  document, in Markdown or raw HTML, display, and so do remote images and linked badges. Page
  scripts never run.
- **E-8 [W]** Editor shortcuts work regardless of Caps Lock.
- **E-9 [A]** `<cli> edit FILE` opens a file in the calling pane's tab, or a given tab. An explicitly
  named pane or tab that doesn't exist is an error, never a fallback to another tab.

## AG. Agent sessions

A **session** is one Claude Code or Codex conversation the product knows. It runs in one of two ways:

- **Headless:** the product runs the agent without its interface (Claude Code's own headless mode,
  Codex's own app server) and controls it from events and ids the agent reports.
- **Live:** the agent's own interface (Claude Code's or Codex's) runs in a pane, on the same
  conversation.

The product always launches and controls sessions headless. A session moves from headless to live
when the user takes it over in a pane, and back to headless when its interface closes. Wherever it
runs, it is the same session: same id, conversation, folder and settings.

### Launching
- **AG-1 [A]** `agent start claude|codex PROMPT` starts a session headless and prints its id. It
  takes a name, a folder or a git worktree, a model and effort, full access (no approvals),
  environment variables and extra arguments for the agent. Without a placement nothing appears on
  screen. Text comes from arguments, from stdin with `-`, or after `--` where it isn't harness
  arguments; no command waits on stdin unless asked to with `-`.
- **AG-2 [A]** Sessions the user will interact with: with a placement (`--tab`, `--split [DIR]`,
  `--window`, `--pane P`), the session runs headless until its first turn finishes, and is then
  resumed live in that place, on the same conversation. Meanwhile the place shows the read-only
  view (AG-5). The user's focus doesn't move unless asked (`--focus`), as in L-8.
- **AG-3 [A]** Launches are reliable. A session's first turn starts within seconds. A session that
  can't start (the agent isn't installed, the folder is gone, the conversation no longer exists)
  fails at once, with the reason, in `agent start`/`send`/`wait`/`info`; it never silently starts a
  fresh conversation in its place.
- **AG-4 [A]** Fidelity. A session, headless or live, is the agent the user would get by typing the
  same command in their own terminal in that folder: their and the project's instructions
  (`CLAUDE.md`, `AGENTS.md`), skills, MCP servers, plugins, hooks and subagents; the login shell's
  environment, never the launching process's agent variables; their own logins. Running sessions
  never changes the user's own `claude`/`codex` configuration, except installing Tern's plugins
  (AG-18).

### Headless and live
- **AG-5 [A+W]** Read-only view. A headless session appears in a pane only when the user asks to
  locate it (`agent open`, the Window menu, the palette, the "next session that needs you"
  shortcut). The pane shows the session read-only: what was said on both sides, tool activity, its
  status and anything it waits on, and a **Take Over** button. Showing a session that is already
  shown focuses its pane.
- **AG-6 [A]** Take over. The button (or `agent open --live`) immediately replaces the read-only view
  with the agent's own interface on the same conversation, in that pane. A turn running at that
  moment continues in the live interface (Codex) or is interrupted (Claude Code, which can't share a
  running turn); either way nothing waits for the turn to end.
- **AG-7 [A]** Back to headless. When the live interface closes (the user quits it), the session is
  headless again with its whole conversation, and the pane shows the read-only view. A session cut
  off by a quit of the app comes back in the same place after a restart: live panes live, read-only
  panes read-only.
- **AG-8 [A]** Remove from a pane. A keyboard shortcut (and `agent hide`) removes the session from
  its pane without stopping it: the pane goes away (the user doesn't see it) and the session keeps
  running until it finishes. A live interface keeps running out of sight until its turn and any
  background work end; then the session is headless and idle.
- **AG-9 [A]** Messages reach live sessions. A message sent to a live session is delivered exactly
  once:
  - Codex: at once, through the conversation the live interface shows (steering a running turn, or
    starting one).
  - Claude Code: when its interface is idle and the user has nothing typed in it. The session runs
    the message headless (the pane shows the read-only view meanwhile) and then returns live to the
    same pane. Until then the message waits, and `agent info`/`ls` say why.

### Supervising and steering
- **AG-10 [A]** `agent send SESSION TEXT` prints a message id at once. While the session works, the
  agent sees TEXT during its current turn (steering, at its next step). Otherwise TEXT starts a turn.
  A session that is stopped, crashed, or from before an app restart or update resumes its
  conversation with the folder, model, effort, access, environment and arguments it was started
  with. `--interrupt` stops the running turn first, and TEXT is the next thing the agent sees.
  Message and session ids are the ones the agent itself reports or echoes; the agent's own session or
  thread id also selects the session.
- **AG-11 [A]** Exactly once. Every message is delivered to the agent exactly once, under any timing,
  including steering, interrupts, crashes and restarts. A message that can't be delivered ends in a
  failure state the caller sees; nothing is pending forever.
- **AG-12 [A]** `agent wait SESSION [--message ID] [--timeout S]` waits until the turn answering the
  latest (or given) message has ended and the session has settled (no background work of its own
  still pending), or until it needs input, and prints a status, then the reply. `DONE` 0;
  `NEEDS_INPUT` 2 (with what it waits on); `INTERRUPTED`, `FAILED`, `STOPPED`, `ERROR`,
  `CANCELLED` 3; `TIMEOUT` 124 (with what is still running). An old message's wait returns that
  message's own reply. `--report` waits for the worker's own report instead (AG-16).
- **AG-13 [A]** Truthful status: `starting`, `working`, `idle`, `needs_input`, `stopped` or `error`,
  for headless and live sessions alike. A session isn't `idle` while a turn runs, a message waits,
  or background work it started (that will wake it) is pending; it isn't `working` when it's done.
  Turns the agent starts by itself (a background task finished, a scheduled wake-up) show as
  `working`, appear in the transcript as their own turns, and are never taken as the reply to a
  message.
- **AG-14 [A]** `agent read` prints the last reply, a given message's reply, or the transcript in
  order. `agent ls` and `agent info` show each session's status and activity, where it is
  (`background`, a pane's read-only view, or live in a pane), its parent, its latest report, what it
  loaded when it last started (model, MCP servers and their state, flags for anything that failed or
  needs the user), and messages waiting.
- **AG-15 [A]** `agent interrupt` stops the running turn and keeps the session. `agent stop` ends the
  session's work completely: its agent process and everything it started, including detached
  processes and ones that ignore SIGTERM; a live interface closes; the conversation stays resumable.
  `agent rm` forgets a session (`--force` stops it first). `agent rename` renames; names are unique
  among running sessions.
- **AG-16 [A]** Agents supervise agents. Inside any session (headless or live), `<cli>` is on PATH
  and reaches the right instance; `self` names the session; sessions it starts record it as their
  parent (`agent ls --parent self`). `agent watch SESSION --notify OTHER` sends OTHER a message when
  SESSION finishes, needs input or stops. `agent report done|blocked|failed SUMMARY` records a
  worker's verdict, shown in `info`/`ls` and awaited by `agent wait --report` (done 0, blocked 2,
  failed 3). A session knows its situation without being told: its name and id, parent, folder, that
  nobody may be watching, and how to report and reach other sessions.
- **AG-17 [A]** Approvals and questions. Without full access, what the agent asks for (approvals,
  questions, several questions in one request) shows as pending requests that say exactly what
  would be allowed, answerable with `agent approve`/`deny`/`answer` and from the read-only view.
  Requests the agent withdraws disappear. In a live session the agent's own interface asks.

### Observability
- **AG-18 [A]** The product observes agents the way Warp does: Tern's plugins for Claude Code and
  Codex report each session's state from the agents' own hooks to the app. That covers sessions the
  product started, while live, and `claude`/`codex` the user starts by typing them in a pane, which
  then become sessions the product knows. The plugins are installed into the user's Claude Code and
  Codex and kept up to date (`agent plugins` shows their state). Outside the product (another
  terminal, or no app running) they're silent: no output and no effect.
- **AG-19 [A]** Live status is truthful through agent updates: a turn's end with background work
  still pending isn't "finished", an interrupted turn doesn't stay "working", and a session waiting
  on a permission prompt or a question is `needs_input`.

### CLI for agents
- **AG-20 [A]** An agent with no instructions about the product can use it: given only a task that
  needs other agents (and that `<cli>` exists), real Claude Code and Codex agents start sessions,
  wait for them, read their replies, steer them and stop them through `<cli>`, guided only by its
  help and its messages. The help is short and plain; errors say what to do instead.

### Robustness
- **AG-21 [A]** No orphans. Every process started for a session belongs to a session listed as
  running, or is gone: after `agent stop`, `agent rm --force`, a crash of the agent, a quit of the
  app, and after every process of the product is killed and the app started again. No zombies
  accumulate.
- **AG-22 [A]** Crash and restart. After the app quits, crashes (`kill -9` of every product process)
  or is updated, all sessions are listed; each resumes on its next message; no message is delivered
  twice or lost; transcripts keep every entry once. A turn cut off by the quit, crash or update
  continues by itself once the app runs again, with a short note saying when and why it was cut off
  and that what it had running was stopped; `agent wait` on the cut-off message returns the
  continued turn's reply. A normal quit or an update never cuts turns off silently: it interrupts
  them cleanly, and an update installs while turns run only if the user agrees.
- **AG-23 [A]** Long runs. Many sessions, long transcripts, large tool outputs and days of uptime don't
  make the CLI or the app slow. Disk use grows only with what the user keeps.

## R. Robustness

- **R-3 [A]** Restart. After the app quits and restarts, pins and tab names come back. Sessions come
  back as AG-22 says, and their panes as AG-7 says.
- **R-4 [A]** Paths. Everything works with a state directory or working directory containing spaces,
  and with a long state-directory path (Unix socket paths are limited to 104 bytes). The product
  builds from a checkout path containing spaces.
- **R-5 [A]** Isolation. Two isolated instances (different state directories) never talk to each
  other: CLI calls, agents and the panes of one never reach the other.
- **R-6 [A]** The app and its CLI keep working, and tell the truth, while sessions are busy,
  approvals are pending, or event consumers are slow.
- **R-7 [A]** Stale environments. A CLI run with stale pane, socket or agent variables (for example
  from a terminal that outlived its app) either reaches the right instance or fails clearly. It
  never acts on the wrong one.

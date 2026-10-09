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
  and sometimes Codex, in one of the app's panes or as a managed session.
  - It runs in full-access (bypass permissions) mode.
  - Otherwise it uses its harness's full feature set: the user's skills (notably
    `supervise-workers`), MCP servers, subagents, background tasks, plan mode and questions to the
    user.
- **The workers.** The orchestrator starts Claude Code and Codex workers through `<cli>`, usually with
  full access, in a folder or a fresh git worktree, on a chosen model and effort. Workers also use
  their harness's full feature set.
  - The `supervise-workers` loop: write a task file, start a worker pointing at it, wait for its turn
    to end, read the report, check the evidence, follow up.
  - Follow-ups come seconds or hours later. Sometimes the orchestrator interrupts or stops a worker,
    starts more, or has workers start their own workers.
- **The user.** The user watches all of this in the app. They arrange panes, tabs and windows
  Warp-style, move live terminals and workers around, read files in the editor, and now and then step
  in: type a follow-up, answer a question, interrupt.
- **Long runs.** The app, the orchestrator and the workers run for days. Over that time the machine
  sleeps, the app quits or crashes, and new builds get installed.

## Priorities

Each requirement below belongs to one of three tiers.

### Fixed: not up for compromise
The Warp-like interface and everything about panes, tabs and windows: creating, arranging and moving
terminals (and agents shown in panes) between panes, tabs and windows, from the UI and the CLI. Also
the product's identity, packaging and editor.

Requirements: P-1 to P-4, I-1 to I-5, L-1 to L-9, M-1 to M-6, T-1 to T-7, S-1 to S-6, E-1 to E-9,
AP-2, AP-3, AP-9.

### Core: the orchestration loop
These outcomes must hold every time, with both harnesses. How they are achieved is open. If something
in the third tier makes any of these less reliable, the third-tier item gives way.
- **Control:** start, message ids, follow-ups at any time, exactly-once delivery, wait/read, truthful
  status, interrupt, redirect, stop, list, resume.
- **Resumption:** a message sent to a session in any state gets it working again, with everything it
  had; turns cut off by a quit, crash or update continue by themselves.
- **Composition:** orchestration from inside agents, watch/notify, and workers' own reports.
- **Fidelity:** a worker is the agent the user would get in their own terminal, with everything it
  loads and the environment it gets, and it knows its situation; the user's own agents are left
  unaffected.
- **No hidden states:** turns an agent starts by itself are tracked, and what a worker failed to
  load is shown.
- **Needs input:** a session that needs input is never silently stuck.
- **Watching and stepping in:** the user can see each worker live in a pane, and step in there.
- **Robustness:** crashes, restarts, upgrades, isolation, long runs.

Requirements: MA-1 to MA-13, MA-15, MA-17 to MA-29, IA-1, IA-3, IA-4, AP-1, AP-4, AP-5, R-1 to
R-10.

### Negotiable
Wanted, but these may be simplified, reworked or left out when keeping them would cost reliability in
the tiers above. Record every such compromise in `COMPROMISES.md`: what, why, and which requirement it
protects. A documented compromise turns its failing tests into known, accepted failures.
- Approval flows for sessions that don't have full access, beyond surfacing them (MA-14).
- MCP elicitation forms and links beyond surfacing them (MA-16).
- `--permission-mode` and `--profile` (part of MA-1).
- Tracking interactive agents in the sidebar and `ls` (IA-2).
- How a worker's pane presents it, beyond AP-1 (AP-10).
- Composer drafts (AP-6), desktop notifications (AP-7), copy-reply (AP-8), agent panes reopening by
  themselves after a restart (AP-11).
- Steering: showing a follow-up to the agent while its turn is still running, rather than when the
  turn ends (MA-3 only asks for the latter). If offered, it must not weaken MA-4.

Requirements: MA-14, MA-16, IA-2, AP-6, AP-7, AP-8, AP-10, AP-11.

### Not requirements
These are open design decisions, not requirements. Make them on the merits and validate them with the
tests:
- whether "interactive" and "managed" agents are different kinds of session at all;
- whether a worker runs inside a terminal;
- how a worker's pane presents it;
- what process owns agents and sessions, and how the CLI finds the app;
- whether agents keep running while the app isn't. The user's call: sessions may stop when the app
  quits, as long as MA-24 and R-10 hold. They would rather the effort go into making resumption
  reliable than into keeping agents alive across app restarts.

`REQUESTS.md`'s "two launch modes" section was the user's first guess at simplifying the problem by
giving up something non-core. The user later said it isn't meant to be baked in (see the end of
`REQUESTS.md`). Its reliability rules still stand: control rests on identifiers and events the
harness itself reports, not on reading or typing into a screen.

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

Phase 2 requirements: MA-1 to MA-29, AP-1 to AP-11, R-1, R-2, R-8 to R-10.

Phase 1 must not close doors on phase 2. Its decisions about panes, the CLI, control endpoints,
stored state and identity leave room for sessions shown in panes (AP-2), agent commands in the CLI,
and agents reaching the app from their own processes (MA-18).

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

## IA. Agents launched as typed

Plain `claude` / `codex` in a terminal, launched for the user exactly as if typed.

- **IA-1 [A+W]** `<cli> claude [ARGS…]` / `<cli> codex [ARGS…]` open a new tab (or a split, or a
  window) whose shell runs `claude ARGS…` exactly as if the user had typed it into a fresh terminal.
  That means the same shell, environment, config, MCP servers and shared daemons. Nothing the product
  does afterwards changes how that session behaves.
- **IA-2 [A]** When the agent exits, the pane is an ordinary shell again. The product notes that the
  agent exited (shown in the sidebar and `ls`); other programs run later in that pane are not
  mistaken for the agent.
- **IA-3 [A]** Placement options (tab, split with a direction, new window, don't-focus) work and never
  swallow the agent's own arguments.
- **IA-4 [A]** Launching an interactive agent never changes how the user's own `claude`/`codex`
  behave elsewhere.

## MA. Managed agents (the product is the agent's control plane)

A managed session is a Claude Code or Codex session that the product controls. It exposes full control
through the CLI, so agents can orchestrate other agents, and shows the session in the app.

### Lifecycle and messages
- **MA-1 [A]** `agent start claude|codex [PROMPT]` starts a session and prints its id. It takes:
  - a name, cwd, worktree, model and effort;
  - a permission mode, or full access with no approvals;
  - extra harness arguments;
  - environment variables.
- **MA-2 [A]** Every message sent gets an id, printed by `agent send`. Message ids and session ids
  are the identifiers the harness itself reports or echoes back, not ones derived from text or timing.
  The harness's own session or thread id also selects the session.
- **MA-3 [A]** Follow-ups can be sent at any time:
  - while the agent is busy: accepted at once and delivered when the agent can take it, in order;
  - right after it finishes;
  - after its process exited, was stopped, crashed, or after the app restarted: the same
    conversation is resumed, with its context.

  A follow-up sent while the session is stopping is not lost.
- **MA-4 [A]** Each message is delivered to the agent exactly once, never zero times and never
  twice, under any timing. Messages the agent never received end in a failure state the caller can
  see, never "pending forever".
- **MA-5 [A]** `agent wait SESSION [--message ID] [--timeout S]` waits for the turn that answers the
  latest (or given) message and prints a status, then the reply.

  | Status | Exit |
  |---|---|
  | `DONE` | 0 |
  | `NEEDS_INPUT` (pending approvals and questions listed) | 2 |
  | `INTERRUPTED`, `FAILED`, `EXITED`, `ERROR`, `CANCELLED` | 3 |
  | `TIMEOUT` | 124 |

  `wait` on a session with nothing pending returns its current state immediately. An old message's
  wait returns that message's own reply.
- **MA-6 [A]** `agent read` prints the last reply, or a given message's reply, or the transcript
  (messages, tool activity, notices) in order.
- **MA-7 [A]** Status is always one of `starting`, `working`, `idle`, `needs_input`, `exited`, `error`
  and reflects reality: not "working" while the agent is idle, and not "idle" while a message is
  still unanswered.
- **MA-8 [A]** `agent interrupt` stops the current turn; the session stays alive. Messages already
  queued behind it still get delivered. A message sent right after an interrupt needs no waiting in
  between: it's delivered once the interrupted turn has ended.
- **MA-9 [A]** `agent stop` ends the session's work completely: its harness process and every process
  it started, including detached ones and ones that ignore polite termination. Nothing is left
  running. The conversation stays resumable.
- **MA-10 [A]** If the harness crashes or exits on its own, the session shows `error` (or `exited`)
  with the reason, everything it started is cleaned up, and a follow-up resumes the conversation.
- **MA-11 [A]** `agent ls` lists sessions, `agent info` shows one, `agent rename` renames, and
  `agent rm` removes. Names are unique among sessions: starting a session with the name of a running
  one fails, and a finished one gives up its name. Removing a running session requires force and
  stops it fully, leaving no zombie or orphan process.
- **MA-12 [A]** Inside a managed agent, `self` names its own session, and sessions it starts record it
  as their parent.
- **MA-13 [A]** Text can come from arguments, from stdin with `-`, or after `--` (text that starts
  with dashes). A command never waits on stdin unless asked to with `-`. Placement options never
  swallow the prompt.

### Approvals and questions
- **MA-14 [A]** Without full access, actions the agent needs approved show up as pending requests
  (status `needs_input`) that say exactly what would be allowed: the command, the file, or the
  concrete paths and network access. Each can be:
  - allowed once;
  - allowed always: this exact kind of action, for the session only;
  - denied, optionally with a message.

  The agent then continues.
- **MA-15 [A]** Questions from the agent, including several questions in one request, show every
  question and its options and take a separate answer for each. A single answer is never silently
  copied to several questions.
- **MA-16 [A]** MCP servers' requests for input show their link (open it, then confirm) or their form
  fields. A plain answer fills a single-field form.
- **MA-17 [A]** Requests that the agent withdraws (for example on interrupt) disappear from the
  pending list.

### Orchestration
- **MA-18 [A]** Agents can orchestrate agents through `<cli>`: a session can start another session,
  of either kind, send it messages, wait for it and read it. The CLI is on the agent's PATH and talks
  to the right app instance.
- **MA-19 [A]** `agent watch SESSION --notify OTHER`: when SESSION's turn ends (or it needs input or
  exits), OTHER receives a follow-up message saying so. A supervisor can sleep until its workers
  report back, without anything typing into a terminal.
- **MA-20 [A]** Managed agents run with the environment a new terminal would give them (the user's
  login shell environment). They never inherit markers of the process that launched them, such as
  another agent's session variables.
- **MA-21 [A]** Managed agents use the user's own logins and subscriptions, and never the user's
  shared Codex daemon. Running a managed Codex session doesn't change how the user's own `codex`
  behaves. The one exception is a change Codex makes itself whenever it runs: with a writable sandbox
  in a git project, it marks that project as trusted in the user's config, exactly as it does when
  run in a terminal.

### Real harness fidelity
- **MA-22 [A]** All of the above holds with the real Claude Code and Codex CLIs, as tested with cheap
  models, and with the fake harnesses under any legal event ordering and timing (see `fakes/README.md`).
- **MA-23 [A]** A managed worker has the features it would have if the user typed the same harness
  command in their own terminal, in that folder:
  - the user's and the project's instructions (`CLAUDE.md`, `AGENTS.md`);
  - skills, MCP servers (the user's and the project's), plugins, hooks and subagents;
  - slash commands that make sense without a UI;
  - background tasks, and long conversations that compact.

  This holds in a folder or worktree the user has never opened before, and after every resume
  (MA-24).

### Resumption, reports and awareness
- **MA-24 [A]** Send and it runs. A message sent to a session in any state gets the agent working on
  it as soon as the agent can take it. "Any state" means working, idle, stopped, crashed, or after
  the app quit, crashed or was updated, or the machine restarted. The agent works on it:
  - in the same conversation, with its context;
  - with the folder, model, effort, access level, environment and harness arguments the session was
    started with;
  - within seconds, when nothing else is queued.

  If that's impossible, for example because the folder is gone or the harness no longer has the
  conversation, the send fails at once with the reason. It never silently starts a fresh
  conversation.
- **MA-25 [A]** Redirect. `agent send SESSION --interrupt TEXT` interrupts the turn running when the
  command is given (if any) and makes TEXT the next thing the agent sees, ahead of messages already
  queued. With `--drop-queued`, messages queued before it are dropped and end `CANCELLED`.
  - The interrupt only ever stops the turn that was running when the command was given: never the
    turn that carries TEXT, and never a later one.
  - If that turn doesn't stop within 30 seconds (a hung command or harness), the session is stopped
    and resumed, and TEXT is still delivered.
- **MA-26 [A]** Worker reports. Inside a session, `agent report done|blocked|failed [SUMMARY…]`
  records the worker's own verdict on its task.
  - `agent info` and `agent ls` show the latest report (verdict, summary, time) next to what the
    harness says: its status, and how many background tasks are still running when the harness
    reports that.
  - `agent wait SESSION --report` waits for a report made after the latest message to the session
    (or after the given one). It exits 0 for done, 2 for blocked, 3 for failed, and 124 on timeout,
    and its output includes what the harness says.
  - The help for `agent wait` and `agent report` says, in a sentence or two, that an idle harness
    means nothing is running right now, not that the task is done, and that a worker can resume by
    itself (MA-28).
- **MA-27 [A]** Workers know their situation. Without being told by whoever started it, a managed
  worker can find out:
  - its session name and id, and its parent session;
  - its folder or worktree;
  - that it is a managed session that no person may be watching;
  - how to report (MA-26) and how to reach other sessions through `<cli>`.
- **MA-28 [A]** Turns the agent starts itself. A harness can start a turn without a message, for
  example when a background command finishes or a scheduled check fires (Claude Code does this).
  - The session shows `working` during that turn and `idle` after it.
  - The turn and its reply appear in the transcript as their own turn. They are never taken as the
    turn or reply of a message.
  - Messages sent meanwhile are delivered after it, in order, exactly once.
- **MA-29 [A]** What a worker loaded. `agent info` shows what the harness reported when the session
  last started or resumed, for example its model, its MCP servers and their state, its skills,
  plugins and subagents. It flags anything that failed or needs the user, such as an MCP server that
  needs authentication. `agent wait` and `agent start --wait` print a one-line warning when something
  is flagged.

## AP. Managed agents in the app

- **AP-1 [A+W]** A managed session is shown in a pane, live.
  - The user sees what was said on both sides, what the agent is doing (tool activity), its status,
    and anything it is waiting on.
  - Typing text in the pane and pressing Enter sends it as a follow-up (MA-3). Esc interrupts the
    turn (MA-8).
  - Pending approvals and questions can be answered from the pane.
- **AP-2 [A]** That pane behaves like any other pane. You can split next to it, move it to another
  tab or window, swap, zoom, close and undo the close, and drag it. A shell in the session's folder
  is available from the pane.
- **AP-3 [A]** `agent start` runs a session in the background by default: it shows nothing until
  asked. With a placement, `agent start` and `agent open` show a session as a new tab (`agent open`'s
  default), a split next to a pane, or a new window, with or without focus. Showing a session that is
  already open focuses its pane instead of opening another. A non-focusing open follows L-8.
- **AP-4 [A]** Closing the pane leaves the session running. It can be shown again later from the CLI
  or the command palette.
- **AP-5 [A+W]** What the pane shows is complete and in order, including after the app reconnects to
  sessions that progressed while it wasn't looking.
- **AP-6 [W]** Text typed in the pane but not yet sent is not lost:
  - when the message can't be sent: it's kept;
  - when switching the pane to its terminal and back;
  - when the pane moves.
- **AP-7 [W]** When an agent needs the user or finishes while the user isn't looking at it, a desktop
  notification appears. Clicking it shows the agent.
- **AP-8 [W]** Copy-reply actions copy the full reply, not a truncated one.
- **AP-9 [A]** There is no in-app "new agent" form. Sessions start from the CLI.
- **AP-10 [W]** Presentation:
  - assistant text is rendered as Markdown, with code blocks set apart;
  - tool calls can be expanded to their output;
  - approvals and questions appear as actionable cards;
  - Shift+Enter adds a newline;
  - queued messages are visible.
- **AP-11 [A]** Agent panes come back after the app restarts.

## R. Robustness

- **R-1 [A]** No orphans. Every process started for a session either belongs to a session that
  `agent ls` lists as live (and that `agent stop` can stop), or is gone. This includes detached
  processes and ones that ignore SIGTERM, and no zombie processes accumulate. In particular:
  - after `agent stop`, `agent rm --force` or a harness crash, nothing started for that session keeps
    running;
  - when the app quits, sessions either keep running as listed live sessions or stop completely;
  - after every process of the product is killed, nothing started before keeps running once the app
    is started again.
- **R-2 [A]** Crash recovery. If every process of the product is killed (`kill -9`) and the app is
  started again:
  - all sessions are listed;
  - each resumes on its next message;
  - no session reuses or skips transcript entries;
  - no message is delivered twice.
- **R-3 [A]** Restart. After the app quits and restarts, sessions resume as in MA-3, and pins and tab
  names come back. Agent panes coming back is AP-11.
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
- **R-8 [A]** Upgrades. Installing a new build while sessions from the old build exist loses no
  sessions. They resume with the new build.
- **R-9 [A]** Long runs. Many sessions, long transcripts, large tool outputs and days of uptime don't
  make the CLI or the app slow or unresponsive. The product's disk usage grows only with what the user
  keeps.
- **R-10 [A]** Cut-off turns continue. If a turn is running when the app quits, crashes or is
  updated, or the machine restarts, that session continues by itself once the app is running again.
  - It receives a short note saying when its turn was cut off, that anything it had running
    (commands, background tasks, subagents) was stopped, and that it should check the state of its
    work before carrying on.
  - `agent wait` on the cut-off message returns the reply of the continued turn.
  - The cut-off message is not delivered again (MA-4).

  A normal quit or an update never cuts turns off silently. It either waits until they end or
  interrupts them cleanly. An update installs while turns are running only if the user agrees.

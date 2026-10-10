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

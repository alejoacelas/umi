# Brief: agent sessions

You're working on Tern, a macOS terminal built from Ghostty, in this folder. Earlier runs built the
app and added agent orchestration. This run is headless: nobody is watching and nobody can answer
questions. Make decisions yourself, record them in DECISIONS.md, and finish. When something is
genuinely the user's call, pick the option that keeps the most doors open, list it under "Questions
for the user" in REPORT.md, and keep going.

## 1. Agent sessions

The user's instructions, in their words:
- use the paths warp illustrates for observability of running agents
- always use headless to launch sessions and control them. sessions can be resumed from headless to
  live and back
- make it easy to launch sessions that the user will interact with: a session that runs headless
  until the turn finishes and then it's resumed in a pane
- main priorities are: 1. launching sessions that run reliably, which will be available for the user
  to interact with in their chosen pane/tab/window 2. allowing agents to supervise and steer other
  agents
- a read-only pane for seeing headless sessions, which shows only if the user asks to locate the
  session in a pane/tab/window. it has a takeover button, and taking over is immediate
- a keyboard shortcut for removing a session from a pane (such that I don't see it but it still runs
  until it finishes)
- the cli should be intuitive to use for agents with zero upfront instruction. cli docs should be
  clean and simple, and we should do live tests to make sure it works for agents with zero upfront
  instruction

"Live" means the agent's own interface (Claude Code's or Codex's) running in a pane. "Headless" means
the same agent run by Tern without that interface.

**Don't anchor on what exists.** The agent orchestration already in Tern describes a design being
replaced. None of it is guidance: its code, BRIEF.md, the agent sections of DECISIONS.md,
COMPROMISES.md and REPORT.md, and the acceptance suite's agent requirements and tests (MA, AP, IA and
the agent parts of R). Reuse or remove the code as you see fit. Write new requirements and tests for
the instructions above, including live tests with real agents.

**Warp, for reference:** its client source is at `~/dev/warp`. Read it only; it holds the user's
uncommitted work. Its plugins are the GitHub repositories `warpdotdev/claude-code-warp` and
`warpdotdev/codex-warp`. Warp's plugins stay silent outside Warp; Tern's should stay silent outside
Tern.
- **What to look at:** Warp's observability lives in `app/src/terminal/cli_agent_sessions/` and in
  the `warp` plugin of each of those repositories. Their hooks send structured OSC 777 events to the
  terminal: through Claude Code's `terminalSequence` hook output, and for Codex 0.155 and later by
  finding the terminal through the process tree.
- **What to learn from its bugs:**
  - status broke when Claude 2.1.139 and Codex 0.155 updated;
  - every Claude stop counted as "done" until claude-code-warp #92 and warp #16367;
  - its orchestration mailbox (the `oz-harness-support` and `orchestration` plugins) loses messages
    and is not a model to copy.

## 2. App changes, decided with the user
- **Sidebar:** each tab shows two lines, its folder and then its session's title. When a session
  finishes and the user hasn't looked yet, or it needs them, the agent's icon takes a quiet color, and
  looking clears it. Colors and hints stay subtle, so they don't distract from the main panes. No
  desktop notifications. The Dock badge counts the sessions that need the user.
- **Sidebar order, in the user's words:** "order tabs on the sidebar such that current tab is at the
  top and then ordered by which one had an agent last stop/deliver". Pins and manual reordering exist
  today; reconcile them with this and record how.
- **⌘, (in the user's words):** "should take me to somewhere I can edit shortcuts".
- **Shortcuts:**
  - They work from anywhere: terminal, editor, sidebar, session views.
  - ⌘⇧[ goes to the previous tab, following tab movement history. Pressed again, it goes to the tab
    before that.
  - ⌘⇧] goes to the next tab in sidebar order.
  - ⌘1–9 and ⌃Tab also work from anywhere.
  - One shortcut goes to the next session that needs the user, and another goes back.
- **Panes distribute themselves equally across the screen,** as in Warp: panes in the same row or
  column share it equally after every split and close.
- **⇧⌘T** reopens the last closed window, tab or pane, in its old place, for 60 seconds, as in Warp.
  **⌘O** opens a quick file search, as in Warp.
- **⌘P:** a command palette offering the CLI's commands, built so the CLI can change without breaking
  the palette.
- **From the UI gaps in WARP-PARITY.md:**
  - dragging a pane onto a sidebar row moves it into that tab, and dropping it between rows makes a new
    tab;
  - ⌃⇧← and ⌃⇧→ reorder tabs;
  - ⇧⌘P lists panes, most recent first, each with its own title;
  - after a close, focus returns to the pane used before;
  - dragging a tab out of the window makes a new window;
  - each window's sidebar width can be changed;
  - the tab row's right-click menu has Warp's items.
- **Kept as they are:** ⌃⌘← and ⌃⌘→ (move the pane to the previous or next tab), the sidebar's Tabs
  and Files modes, and dimming of unfocused panes. No tab groups.
- **Markdown files** (Tern is the default app) open in the tab whose folder is closest to the file,
  and otherwise in a new tab.

## 3. Definition of done
- **The acceptance suite** in `acceptance/` passes, without the agent requirements it replaces,
  including the real-agent tests. Use cheap models: Claude `haiku`, and Codex `gpt-6-luna` with low
  effort.
  - Don't weaken a test. Fix a wrong test, and explain the change in `acceptance/TEST_CHANGES.md`.
  - Add tests for everything above.
  - Update `acceptance/SPEC.md` and `CLI.md` to describe what you built.
- **Building and releasing:** BRIEF-phase1.md section 7, and the build and release parts of REPORT.md.
- **UI tests** take over this Mac's keyboard and mouse, and the user may be at it.
  - Run them only before each review and before the release, under `caffeinate -d -i`.
  - Check `acceptance/conftest.py`'s `screen_locked()` first.
  - Never count a skip as a pass.
- **Adversarial review:** once the implementation is done and tested, in `app/`, run
  `codex review --base 2fa4d48ed -c model_reasoning_effort="high"`.
  - Fix high and moderate findings, rerun the suite, and review again.
  - Stop when a round finds no high or moderate findings, or after 10 rounds. List what remains.
- **Release** a new minor version. The copy installed on this Mac must update itself to it: run its
  `tern update`, which counts as the user's yes.
- **REPORT.md:** add a short part at the top covering what changed, the decisions, the tests, the
  review rounds, the release, questions for the user, and how an agent supervises other agents with
  the CLI.

## 4. Boundaries
- **Off limits:**
  - everything in `~/dev/terminal-2`;
  - the other folders in `~/dev`, except `~/dev/warp`, which is read-only;
  - in `~/dev/terminal/ghostty` (the UI reference, branch `wraith`): `WraithAgents.swift`,
    `WraithAgent.swift`, `WraithCodexBridge.swift`, `WraithInbox.swift`, the agent sections of
    `WRAITH.md`, the `agent*` CLI commands, the agent methods in `WraithRPC`, and `AgentTests`.
- **Leave alone:**
  - the user's other apps (`/Applications/Shade.app` is in daily use);
  - their `~/.local/bin` entries;
  - their `~/.claude` and `~/.codex` configuration, except installing and updating Tern's own plugins
    for observing agents, which the user approved.
- **Publishing:** only releases go to the public repository. Never publish `acceptance/`, logs,
  recordings, source, keys or tokens.

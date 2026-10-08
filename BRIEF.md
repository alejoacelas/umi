# Brief: phase 2, managed agents (the harness)

You are adding managed coding agents to an app that a previous run built in this folder. This run is
headless: nobody is watching and nobody can answer questions. Make decisions yourself, record them,
and finish.
- When something is genuinely the user's call, choose the option that keeps the most doors open.
  Note it under "Questions for the user" in your report, and keep going.
- Don't end your turn until the definition of done in section 2 is met, or you've hit a blocker you
  can't get around. Your last message is a short summary that points to `REPORT.md`.

## 1. What to build

The user's own words are in `acceptance/REQUESTS.md`. The behavior they translate into is
`acceptance/SPEC.md`, which every check refers to by requirement ID. Read both first, all of them.

**This run is phase 2 (SPEC.md, "Delivery phases"): managed agents.** That's MA, AP, the rest of R,
and the agent parts of the other groups.
- Phase 1 built the app. Its `BRIEF-phase1.md`, `REPORT.md`, `DECISIONS.md` and `COMPROMISES.md`
  say what exists, what was decided and where doors were left open for you. Read them before
  designing anything.
- Phase 1's results must stay green. A regression in a phase-1 requirement is a bug in your work.
- Phase 1's report lists what it left open. Fix the cheap items as you go, such as the editor's
  tab row not scrolling to the active file.

The user's priorities, in their words: they care most about **reliability** and **no hidden traps**,
"where the agents are not e.g., running a skill they're supposed to have access or confused about the
environment they're running in". Read SPEC.md's "How the product is used" and "Priorities" closely.
- The Fixed tier isn't up for compromise.
- The Core tier must hold every time, with both harnesses. How it holds is open.
- The Negotiable tier may give way to reliability. Record every trade-off in `COMPROMISES.md`: what
  you gave up, why, and which requirement it protects.

## 2. The acceptance suite is the definition of done

`acceptance/` is an outcome-only conformance suite. It treats the product as a black box and drives
it through the CLI (`CLI.md`), files, processes and the accessibility tree.
- `TEST_INTERFACE.md` says what a build provides so the suite can run it in isolation. Phase 1's
  target file is in `acceptance/targets/`. Extend it as needed.
- `fakes/` holds fake Claude Code and Codex harnesses with fault injection and delivery receipts.
  `fakes/README.md` explains them. They speak the programmatic protocols documented in
  `reference/PROTOCOLS.md`, and their behaviors are based on the real recordings in
  `reference/agent-logs/`.
- `CHECKS.md` lists the look-and-feel checks that need judging; `checks/run_checks.py` collects
  evidence for them.

Work against the full suite: no `--phase` option from now on. `--req MA-4,R-2` runs only the tests
for those requirements. `results/traceability.md` is rewritten after every full run.

Done means:
- every test of a fixed or core requirement passes, with the fakes;
- the real-agent tests pass on cheap models: `ACCEPTANCE_REAL=1 uv run pytest --target … -m real`;
- every negotiable failure is a documented compromise;
- the written checks are judged;
- a release with the harness is published, and the copy installed on this Mac updated itself to it.

Rules for the suite itself:
- **Don't weaken a test to make it pass.** If a test is wrong (it asserts something SPEC.md doesn't
  require, or it's flaky because of the test itself), fix the test. Explain the change in
  `acceptance/TEST_CHANGES.md` and quote the requirement.
- **Add tests** for anything your design makes risky that the suite doesn't cover yet, tagged with
  `@pytest.mark.req(...)`. The suite's coverage is a floor, not a ceiling. Some phase-2 tests were
  written before any build could run them. If one is wrong, fix it under the rule above.
- **The fakes are test doubles.** If your design talks to a harness through an interface the fakes
  don't speak, extend the fakes to speak it. Base every change on behavior you recorded from the real
  CLI, keep the trigger and receipt semantics, and add self-tests. Then confirm with the real-agent
  tests.
- **Codex starting turns by itself:** nobody has checked whether Codex ever does this, as Claude does
  (MA-28). Find out with the real CLI. If it does, extend the fake and the tests.
- **UI tests** drive the app through accessibility. Synthetic keystrokes don't reach Ghostty's
  terminal views, so use `<cli> send` for terminals. This process runs under Terminal.app, which has
  the Accessibility permission.
  - While the Mac's screen is locked, macOS hides the accessibility tree and the UI tests skip
    themselves. Phase 1 was locked out for most of its run. It checked the same behaviors another
    way (`app/macos/TernTests/verify_ui_paths.py`) and listed the skipped tests in its report. Do
    the same for any UI test you can't run, and never count a skip as a pass.
  - Check `acceptance/conftest.py`'s `screen_locked()` before relying on a UI result. The screen may
    unlock during your run; when it does, run the skipped UI tests, phase 1's included.

## 3. Architectural decisions you must make

These are the hard parts. Each one needs real reasoning:
1. Write down the candidate approaches you see and what each one costs against SPEC.md, especially
   the core tier.
2. Pick one.
3. Validate your pick, or your top candidates when it's close, with the existing tests plus
   targeted extra tests or prototypes. Prefer evidence over argument.

Record each decision and its evidence in `DECISIONS.md`, next to phase 1's. The decisions:
- **Controlling a harness.** How the product controls each harness (Claude Code and Codex), and
  whether a worker runs inside a terminal. The previous "two launch modes" were the user's guess, not
  a requirement (see REQUESTS.md). A worker must be the agent the user would get in their own
  terminal (MA-23), so check every feature you rely on against the real CLIs.
- **Message and turn tracking.** How messages, turns and replies are tracked so that delivery is
  exactly-once and statuses are truthful under any legal ordering and timing of harness events. That
  includes redirects and turns the agent starts by itself (MA-2, MA-4, MA-5, MA-7, MA-22, MA-25,
  MA-28). The fakes' chaos mode and the Hypothesis tests exist for this.
- **Where sessions live, and resumption.** Which process owns the agent processes, given that the
  app quits, crashes, restarts and gets updated.
  - The user's call (SPEC.md, "Not requirements"): sessions may stop when the app quits, as long as
    MA-24 and R-10 hold.
  - They'd rather the effort go into making "send a message to any session and it runs from there"
    reliable than into keeping agents alive across app restarts.
- **Stopping everything.** How everything an agent started is found and stopped, including
  detached processes and ones that ignore SIGTERM, and after the product itself is killed (MA-9,
  R-1).
- **Sessions in panes.** How a session is shown in a pane that behaves exactly like any other pane:
  moves, splits, undo, drag and restoration (AP-2, AP-11, M-1 to M-6). Build on phase 1's pane model.
- **Focus** for agent panes (AP-3, L-8), on phase 1's approach.
- **Agent environment and awareness.** How agents get exactly the environment a fresh login terminal
  would give them, and how a worker learns its situation without being told (MA-20, MA-21, MA-23,
  MA-27, MA-29, IA-1, IA-4).
- **Persistence:** what is stored where for sessions, how restoration and updates keep them, and how
  disk use stays bounded (R-2, R-3, R-8, R-9).

## 4. Starting point and boundaries

- **Workspace:** this folder (`~/dev/terminal-3`), on phase 1's code.
- **Research notes:** `acceptance/reference/` has notes from an earlier build on the harnesses'
  programmatic interfaces, with real event logs and the probe scripts that made them. Treat them as
  research to verify, not as decisions. Some facts found since:
  - Claude's Agent SDK libraries, by default, load neither `CLAUDE.md` nor the user's settings, and
    use a minimal system prompt. The `claude` CLI's own headless mode loads the same configuration as
    the terminal.
  - In a folder never opened before, headless `claude` starts the project's `.mcp.json` servers
    without the approval prompt the terminal shows (`C13projectmcp`).
  - Claude deletes conversations untouched for `cleanupPeriodDays` (default 30). Resuming one after
    that fails (`C12missing`).
  - Claude resumes a conversation from a different folder (`C12othercwd`).
  - Claude starts turns by itself when background tasks finish (`C11wake`).
- **UI reference:** `~/dev/terminal/ghostty`, branch `wraith`, for UI only, as in phase 1.
- **Off limits:**
  - In `~/dev/terminal/ghostty`: `WraithAgents.swift`, `WraithAgent.swift`,
    `WraithCodexBridge.swift`, `WraithInbox.swift`, the agent sections of `WRAITH.md`, the `agent*`
    commands of its CLI, the agent methods in `WraithRPC`, and its `AgentTests`.
  - Everything in `~/dev/terminal-2` (another attempt; you're meant to work independently of it).
  - The other folders in `~/dev`.
- **Leave alone:**
  - the user's other installed apps (`/Applications/Shade.app` is in daily use);
  - their `~/.local/bin` entries;
  - their own `~/.claude` and `~/.codex` configuration (MA-21, IA-4).

  The copy of this product installed on this Mac is the user's. Update it only through the product's
  own release and update path.
- **Publishing:** the same rules as phase 1: only releases go to the public repository. Never
  publish `acceptance/`, logs, recordings, source, keys or tokens.

## 5. Build notes

- Real agents for tests: Claude `haiku`; Codex `gpt-6-luna` with low effort.
- The user's `supervise-workers` skill is at
  https://github.com/alejoacelas/dotfiles/tree/main/skills/supervise-workers. The orchestration CLI
  should make its loop easy, including waiting on workers' reports (MA-26).
- Phase 1's notes in `BRIEF-phase1.md` (section 7) and `REPORT.md` still apply.

## 6. Process

1. Read phase 1's documents, `acceptance/` and the research notes. Make the decisions in section 3,
   prototyping where the evidence is cheap.
2. Build in vertical slices. Keep the full suite running against your build from the first slice on.
3. When everything automated is green or documented, run the written checks.
   - Run `checks/run_checks.py`, then judge `results/checks/REPORT.md` yourself by looking at every
     screenshot.
   - Mark what needs a person as NOT JUDGED, with exact steps for them.
4. **Adversarial review:** in `app/`,
   `codex review --base 4d4a1fe32 -c model_reasoning_effort="high"`. That base is just before
   phase 1's fifth review round, so the review also covers the round-5 fixes and the installer
   fix, which no review has seen yet.
   - Fix high and moderate findings, rebuild, rerun the suite, and review again.
   - Stop when a round reports no high or moderate findings, or after 5 rounds, whichever comes
     first. List what remains.
5. **Release:** publish the reviewed build as a new release. Check that the copy installed on this
   Mac updates itself to it.
6. **Report:** add a phase 2 part to `REPORT.md` and keep phase 1's. It covers:
   - what was built;
   - the full traceability table with each requirement's tier and status;
   - the decisions, with their evidence;
   - the compromises;
   - the written-check verdicts;
   - the review rounds and anything left open;
   - questions for the user;
   - how the user's orchestrator should use the CLI: start, send, redirect, wait on turns or
     reports, read, stop.

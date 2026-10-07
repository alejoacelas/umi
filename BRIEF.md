# Brief: a Ghostty-based terminal for orchestrating coding agents

You are building this product from scratch, on your own. Nobody is supervising this run. Make
decisions yourself, record them, and finish. When something is genuinely the user's call, choose the
option that keeps the most doors open, note it under "Questions for the user" in your final report,
and keep going.

## 1. What to build

The user's own words are in `acceptance/REQUESTS.md`. The behavior they translate into is
`acceptance/SPEC.md`, which every check refers to by requirement ID. Read both first.
- Read SPEC.md's "How the product is used" and "Priorities" sections closely. They say which
  outcomes are fixed, which are core, and which you may trade away for reliability.
- Record every trade-off in `COMPROMISES.md`: what you gave up, why, and which requirement it
  protects.

## 2. The acceptance suite is the definition of done

`acceptance/` is an outcome-only conformance suite.
- **What it checks:** it treats the product as a black box and drives it the way the user and their
  agents would: the CLI (contract in `CLI.md`), files, processes and the accessibility tree. It never
  asks how anything is built.
- **How it runs your build:** `TEST_INTERFACE.md` lists the few capabilities your build must provide
  so the suite can run it in isolation. You declare how your build provides them in a target file,
  `acceptance/targets/<yours>.json`.
- **The fakes:** `fakes/` holds fake Claude Code and Codex harnesses with fault injection and receipts.
  `fakes/README.md` explains them. They speak the programmatic protocols documented in
  `reference/PROTOCOLS.md`.
- **The written checks:** `CHECKS.md` lists the look-and-feel checks that need judging.
  `checks/run_checks.py` collects evidence for them.

The suite was validated against an earlier build of a similar product. `acceptance/results/` has
nothing from that build on purpose: your build should be judged on its own.

Work against the suite from the start:
- Write your target file as soon as anything runs.
- Run the relevant tests after each change: `--req MA-4,R-2` runs only the tests for those
  requirements.
- Keep `results/traceability.md` (rewritten after every run) moving toward green.
- Done means:
  - every test of a fixed or core requirement passes;
  - every negotiable failure is a documented compromise;
  - the written checks are judged;
  - the real-agent tests pass on cheap models.

Rules for the suite itself:
- **Don't weaken a test to make it pass.** If a test is wrong (it asserts something SPEC.md doesn't
  require, or it's flaky because of the test itself), fix the test. Explain the change in
  `acceptance/TEST_CHANGES.md` and quote the requirement.
- **Add tests** for anything your design makes risky that the suite doesn't cover yet. Tag them with
  `@pytest.mark.req(...)`. The suite's coverage is a floor, not a ceiling.
- **The fakes are test doubles.** If your design talks to a harness through an interface the fakes
  don't speak, extend the fakes to speak it. Base every change on behavior you recorded from the real
  CLI, keep the trigger and receipt semantics, and add self-tests. Then confirm with the real-agent
  tests (`ACCEPTANCE_REAL=1`).
- **UI tests** drive the app through accessibility: the AX tree, AX actions and menus.
  - Synthetic keystrokes don't reach Ghostty's terminal views, so a test can't type into a terminal
    pane. Use `<cli> send` for terminals.
  - This terminal has the Accessibility permission, so the UI tests work from here.
  - The UI tests open windows and bring the app to the front.

## 3. Architectural decisions you must make

These are the hard parts. Each one needs real reasoning:
1. Write down the candidate approaches you see and what each one costs against SPEC.md, especially
   the core tier.
2. Pick one.
3. Validate your pick, or your top candidates when it's close, with the existing tests plus
   targeted extra tests or prototypes. Prefer evidence over argument.

Record each decision and its evidence in `DECISIONS.md`. The decisions:
- **Where sessions live.** Where managed sessions live, and which process owns the agent
  processes, given that the app quits, crashes, restarts and gets upgraded while agents keep working
  (MA-3, R-1 to R-3, R-8).
- **Controlling a harness.** How the product controls each harness (Claude Code and Codex), and
  whether a worker runs inside a terminal. The previous brief's "two launch modes" were a guess,
  not a requirement (see REQUESTS.md).
- **Message and turn tracking.** How messages, turns and replies are tracked so that delivery is
  exactly-once and statuses are truthful under any legal ordering and timing of harness events
  (MA-2, MA-4, MA-5, MA-7, MA-22). The fakes' chaos mode and the Hypothesis tests exist for this.
- **Stopping everything.** How everything an agent started is found and stopped, including
  detached processes and ones that ignore SIGTERM, and after the product itself is killed (MA-9,
  R-1).
- **Sessions in panes.** How a session is shown in a pane that behaves exactly like any other pane:
  moves, splits, undo, drag and restoration (AP-2, AP-11, M-1 to M-6).
- **Focus.** How creating and moving things never changes the user's focus or the front app, at
  every moment rather than eventually (L-8, AP-3).
- **Finding the right instance.** How the CLI, the app and the agents find the right instance;
  isolation; stale environments; long paths (P-4, MA-18, R-4, R-5, R-7).
- **Agent environment.** How agents get exactly the environment a fresh login terminal would give
  them (MA-20, MA-21, MA-23, IA-1, IA-4).
- **Single instance** under simultaneous launches (P-3).
- **Markdown rendering** for the editor and for agent output (E-1, E-7, AP-10).
- **Persistence:** what is stored where, how restoration and upgrades work, and how disk use stays
  bounded (R-2, R-3, R-8, R-9).

## 4. Starting point and boundaries

- **Workspace:** this folder (`~/dev/terminal-3`).
- **Fork and UI reference:** fork upstream Ghostty at commit `35a81a980`. `~/dev/terminal/ghostty`
  has it as the branch `upstream-base`; branch `wraith` holds an earlier product whose **UI** the user
  likes.
  - You may read and copy its UI and layout code. That's the sidebar, editor, Markdown, theme, window
    chrome, shortcuts, layout control, topology, state, control server and the layout parts of its
    CLI.
  - `git diff upstream-base..wraith` shows every change.
- **Off limits:**
  - In `~/dev/terminal/ghostty`: `WraithAgents.swift`, `WraithAgent.swift`,
    `WraithCodexBridge.swift`, `WraithInbox.swift`, the agent sections of `WRAITH.md`, the `agent*`
    commands of its CLI, the agent methods in `WraithRPC`, and its `AgentTests`.
  - Everything in `~/dev/terminal-2` (another attempt; you're meant to work independently of it).
  - The other folders in `~/dev`.
- **Leave alone:** the user's installed apps (`/Applications/Shade.app` is in daily use) and their
  `~/.local/bin` entries, other than adding your own CLI link. Don't change their default Markdown
  app until your final install.
- **Research notes:** `acceptance/reference/` has notes from a previous build on the harnesses'
  programmatic interfaces, with real event logs. Treat them as research to verify, not as decisions.

## 5. Identity

Your product must be distinct from Ghostty, Wraith and Shade (SPEC P-1). Pick a new:
- app name and bundle id;
- state directory and control endpoints;
- CLI name.

## 6. Build notes from earlier builds

- Zig 0.16 is at `~/.local/zig/zig-aarch64-macos-0.16.0/zig`; gettext's `msgfmt` comes from Homebrew.
- Run `xattr -cr` on the app before codesigning (ad-hoc signing, arm64).
- To rename the product, keep `PRODUCT_MODULE_NAME = Ghostty` and change `PRODUCT_NAME`.
- For fast iteration: `xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64`.
- Unix socket paths are limited to 104 bytes, and test state dirs are deep. Plan for it (R-4).
- Real agents for tests: Claude `haiku`, Codex `gpt-6-luna` with low effort.
- The user's `supervise-workers` skill is at
  https://github.com/alejoacelas/dotfiles/tree/main/skills/supervise-workers. The orchestration CLI
  should make its loop easy.

## 7. Process

1. Read `acceptance/` and the UI reference. Make the decisions in section 3, prototyping where the
   evidence is cheap.
2. Build in vertical slices. Keep the suite running against your build from the first slice on.
3. When everything automated is green or documented, run the written checks.
   - Run `checks/run_checks.py`, then judge `results/checks/REPORT.md` yourself by looking at every
     screenshot.
   - Mark what needs a person as NOT JUDGED, with exact steps for them.
4. **Adversarial review, at most 5 rounds:**
   `codex review --base <your upstream base> -c model_reasoning_effort="high"`.
   - Fix high and moderate findings, rebuild, rerun the suite, and review again.
   - After at most 5 rounds, stop and list what remains.
5. **Package** for the user's other Mac (Apple Silicon, M4) so it works out of the box with only the
   package (SPEC I-1). Install it on this Mac under its own name.
6. **Final report**, in `REPORT.md` at the top of this folder:
   - what was built;
   - the traceability table with each requirement's tier and status;
   - the decisions, with their evidence;
   - the compromises;
   - the written-check verdicts;
   - the review rounds and anything left open;
   - questions for the user;
   - how to install.

# Brief: a Ghostty-based terminal for working with coding agents, phase 1 (the app)

You are building this product from scratch, on your own. This run is headless: nobody is watching
and nobody can answer questions. Make decisions yourself, record them, and finish.
- When something is genuinely the user's call, choose the option that keeps the most doors open.
  Note it under "Questions for the user" in your final report, and keep going.
- Don't end your turn until the definition of done in section 2 is met, or you've hit a blocker you
  can't get around. Your last message is a short summary that points to `REPORT.md`.

## 1. What to build

The user's own words are in `acceptance/REQUESTS.md`. The behavior they translate into is
`acceptance/SPEC.md`, which every check refers to by requirement ID. Read both first, all of them.

The product is delivered in two phases (SPEC.md, "Delivery phases"). **This run is phase 1: the
app.** That means windows, tabs and panes, moving live sessions, the terminal CLI and events, the
sidebar and look, the editor, plain `claude`/`codex` launched in panes, packaging, and updates.
- Managed agents (MA, AP and most of R) are phase 2, a later run built on your code. Don't build them.
- Read their requirements anyway. Phase 1 must not close doors on phase 2 (see the end of "Delivery
  phases").
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
- **The written checks:** `CHECKS.md` lists the look-and-feel checks that need judging.
  `checks/run_checks.py --phase 1` collects evidence for them.

The suite was validated against an earlier build of a similar product. `acceptance/results/` has
nothing from that build on purpose: your build should be judged on its own.

Work against the suite from the start:
- Write your target file as soon as anything runs.
- Always pass `--phase 1`. It leaves out the tests that need managed agents, and the report marks
  their requirements as deferred.
- Run the relevant tests after each change: `--phase 1 --req L-8,M-1` runs only the tests for those
  requirements.
- Keep `results/traceability.md` (rewritten after every full phase-1 run) moving toward green.

Done means:
- every phase-1 test of a fixed or core requirement passes;
- every negotiable failure is a documented compromise;
- the phase-1 written checks are judged;
- a release is published and installs with the one-line command (section 6).

Rules for the suite itself:
- **Don't weaken a test to make it pass.** If a test is wrong (it asserts something SPEC.md doesn't
  require, or it's flaky because of the test itself), fix the test. Explain the change in
  `acceptance/TEST_CHANGES.md` and quote the requirement.
- **Add tests** for anything your design makes risky that the suite doesn't cover yet. Tag them with
  `@pytest.mark.req(...)`. The suite's coverage is a floor, not a ceiling.
- **UI tests** drive the app through accessibility: the AX tree, AX actions and menus.
  - Synthetic keystrokes don't reach Ghostty's terminal views, so a test can't type into a terminal
    pane. Use `<cli> send` for terminals.
  - This process runs under Terminal.app, which has the Accessibility permission, so the UI tests
    work from here.
  - The UI tests open windows and bring the app to the front.

## 3. Architectural decisions you must make

These are the hard parts of phase 1. Each one needs real reasoning:
1. Write down the candidate approaches you see and what each one costs against SPEC.md.
2. Pick one.
3. Validate your pick, or your top candidates when it's close, with the existing tests plus
   targeted extra tests or prototypes. Prefer evidence over argument.

Record each decision and its evidence in `DECISIONS.md`. The decisions:
- **Panes that aren't terminals.** How an editor panel, and later a managed agent's view, lives in
  the same layout as terminals, and how live terminals move between panes, tabs and windows with
  their programs and scrollback intact, with undo and drag (E-1, M-1 to M-6, AP-2).
- **Focus.** How creating and moving things never changes the user's focus or the front app, at
  every moment rather than eventually (L-8).
- **Finding the right instance.** How the CLI (and later agents) finds the right instance;
  isolation; stale environments; long paths (P-4, R-4, R-5, R-7).
- **Single instance** under simultaneous launches (P-3).
- **Markdown rendering** for the editor, and later for agent output (E-1, E-7, AP-10).
- **Persistence:** what is stored where, how windows, pins and names come back after a restart, and
  how unsaved edits survive (E-3, R-3).
- **Updates and releases.** How releases are built, signed, published and verified, how an installed
  copy finds and installs them, and how a test points an instance at a local feed. This includes
  replacing the updater Ghostty ships with, which points at Ghostty's own feed (P-2, I-4, I-5).

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
- **Publishing (section 6):** you may create one public GitHub repository under the user's account,
  `alejoacelas`, for releases. `gh` is logged in. Publish only:
  - release files;
  - a README with the install command;
  - the license files, including Ghostty's MIT notice.

  Never publish:
  - `acceptance/`, logs or recordings: they contain details of the user's own account and setup;
  - source code;
  - keys or tokens.

## 5. Identity

Your product must be distinct from Ghostty, Wraith and Shade (SPEC P-1). Pick a new:
- app name and bundle id;
- state directory and control endpoints;
- CLI name;
- release repository name.

## 6. Packaging, releases and updates

The user wants to use the app on their other Mac (Apple Silicon, M4) and get updates as work
continues here.
- **Install:** one command pasted into Terminal installs the latest release from the public
  repository (I-5), with nothing else needed (I-1).
- **Updates:** the installed app updates itself from the public feed (I-4). The suite tests this end
  to end with a local feed: an older build updating itself to a newer one.
- **Releasing:** publishing a new version from this Mac is one command.
- **Update-signing key:** keep the private key in the login keychain under a name specific to your
  product. Also keep a backup copy at `~/.config/<your product>/` (mode 600). Say where both are in
  `REPORT.md`. If the key is lost, installed copies can't verify new updates.
- **Builds:** the app is ad-hoc signed and not notarized. Make sure neither install nor update trips
  Gatekeeper.

## 7. Build notes from earlier builds

- Zig 0.16 is at `~/.local/zig/zig-aarch64-macos-0.16.0/zig`; gettext's `msgfmt` comes from Homebrew.
- Run `xattr -cr` on the app before codesigning (ad-hoc signing, arm64).
- To rename the product, keep `PRODUCT_MODULE_NAME = Ghostty` and change `PRODUCT_NAME`.
- For fast iteration: `xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64`.
- Unix socket paths are limited to 104 bytes, and test state dirs are deep. Plan for it (R-4).
- Your shell environment comes from a clean login shell. Long commands (builds, full suite runs) may
  need to run in the background and be polled.

## 8. Process

1. Read `acceptance/` and the UI reference. Make the decisions in section 3, prototyping where the
   evidence is cheap.
2. Build in vertical slices. Keep the phase-1 suite running against your build from the first slice
   on.
3. When everything automated is green or documented, run the written checks.
   - Run `checks/run_checks.py --phase 1`, then judge `results/checks/REPORT.md` yourself by looking
     at every screenshot.
   - Mark what needs a person as NOT JUDGED, with exact steps for them.
4. **Adversarial review:**
   `codex review --base <your upstream base> -c model_reasoning_effort="high"`.
   - Fix high and moderate findings, rebuild, rerun the suite, and review again.
   - Stop when a round reports no high or moderate findings, or after 5 rounds, whichever comes
     first. List what remains.
5. **Release and install:**
   - Publish the reviewed build as the first release.
   - Install it on this Mac under its own name with the one-line command, the way the user will on
     the other Mac.
   - Check that the installed copy finds no newer update.
6. **Final report**, in `REPORT.md` at the top of this folder:
   - what was built;
   - the phase-1 traceability table with each requirement's tier and status;
   - the decisions, with their evidence;
   - the compromises;
   - the written-check verdicts;
   - the review rounds and anything left open;
   - what phase 2 should know about your code: where the doors were left open, and anything that
     will constrain it;
   - questions for the user;
   - how to install on the other Mac, and how to publish an update.

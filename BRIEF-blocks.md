# Brief: Warp's look for terminals, and the sidebar order

You're working on Tern, a macOS terminal built from Ghostty, in this folder. Earlier runs built the
app, then redid agent sessions (Tern 0.4.0, BRIEF-agents.md). This run is headless: nobody is
watching and nobody can answer questions. Make decisions yourself, record them in DECISIONS.md, and
finish. When something is genuinely the user's call, pick the option that keeps the most doors open,
list it under "Questions for the user" in REPORT.md, and keep going.

## 1. Warp's look for terminals

The user's request, in their words: "would it be easy to implement the look and placement from warp
of terminals? notice that the terminal shows at the bottom, when it returns it does so in a block
above, and it has a nice autocomplete suggestions feature" and "also the box thing telling you the
directory you're on". Their screenshot from Warp is `reference/warp-blocks.png`.

What the user chose, after hearing the options: an imitation that keeps the shell underneath. zsh
keeps editing the command line as it does today; Tern changes how the terminal looks.
- **At the bottom:** the prompt sits at the bottom of the pane from the start, and output builds
  upward above it, as in Warp. It stays there after `clear` and ⌘K.
- **Blocks:** each command and its output form a block, as in the screenshot:
  - a header with the folder it ran in and how long it took;
  - the command, in bold;
  - its output;
  - a thin line and some space between blocks.

  Warp marks some blocks with a colored bar on the left and a tint (the screenshot's last block).
  Take when Warp does that, its colors and its spacing from its source.
- **The folder box:** at the prompt, a small rounded box with a folder icon and the current folder,
  as at the bottom of the screenshot.
- **Leave out:**
  - the "Lines: … Size: …" line under each block in the screenshot (a debug readout of the user's
    Warp build);
  - Warp's own input editor;
  - block selection, copying and other block actions.
- **Suggestions are done already.** The user's `~/.zshrc` now loads zsh-autosuggestions (cloned into
  `~/.zsh`), with Tab to accept a suggestion. Don't build Tern's own. Shells that tests start may show
  its grey suggestion text.
- **Where it applies:**
  - Only inside Tern; other terminals look as they did.
  - Full-screen programs (the alternate screen: vim, Claude Code's fullscreen interface) take the
    whole pane as today, with no block decorations.
  - The user's shell is zsh; other shells may keep the usual look.
  - Agents that read panes (`tern read`, `tern wait --pattern`) keep seeing what the shell and
    programs printed.
- **For reference:** Warp's client source is at `~/dev/warp` (read only; it holds the user's
  uncommitted work). Its blocks are drawn in `app/src/terminal/block_list_element.rs` and nearby
  files. Ghostty already marks prompts, commands and output through its shell integration (OSC 133),
  and its renderer already has an overlay that highlights prompt rows (`src/renderer/Overlay.zig`).

## 2. The sidebar order

The user's words: "my idea was that other than the focused session, tabs should only move when an
agent finishes their turn". Today every tab switch sorts the whole sidebar again (DECISIONS.md §50),
so the tab the user leaves drops back to the place its last agent stop gives it. Pins stay first.

## 3. Left over from 0.4.0
- In a full run, `test_live.py::test_an_interactive_launch_goes_live_after_its_first_turn[claude]`
  failed once: the interface was on screen while the session still said `starting`. It passed 5
  times out of 5 alone. Find out why and fix the cause.
- ⇧⌘T works from the File menu but isn't in the shortcut list that ⌘, edits.
- The live Codex test leaves a trust entry for `acceptance/.work-real/live-codex` in
  `~/.codex/config.toml`. The suite must leave the user's `~/.claude` and `~/.codex` as it found them.
- The questions in 0.4.0's REPORT.md are still open. Keep the current behavior for each.

## 4. Definition of done
- **The acceptance suite** in `acceptance/` passes, including the real-agent tests. Use cheap models:
  Claude `haiku`, and Codex `gpt-6-luna` with low effort.
  - Don't weaken a test. Fix a wrong test, and explain the change in `acceptance/TEST_CHANGES.md`.
  - Add tests for everything above.
  - Update `acceptance/SPEC.md` and `acceptance/CLI.md` to describe what you built.
- **The look** is judged from screenshots (`tern screenshot`) against `reference/warp-blocks.png`:
  add written checks to CHECKS.md and record verdicts with the screenshots.
- **Building and releasing:** BRIEF-phase1.md section 7, and the build and release parts of REPORT.md.
- **UI tests** take over this Mac's keyboard and mouse, and the user may be at it.
  - Run them only before each review and before the release, under `caffeinate -d -i`.
  - Check `acceptance/conftest.py`'s `screen_locked()` first.
  - Never count a skip as a pass.
- **Adversarial review:** once the implementation is done and tested, in `app/`, run
  `codex review --base e1b23c57f -c model_reasoning_effort="high"`. The base also covers 0.4.0's
  fixes that no review saw.
  - Fix high and moderate findings, rerun the suite, and review again.
  - Stop when a round finds no high or moderate findings, or after 10 rounds. List what remains.
- **Release** a new minor version. The copy installed on this Mac must update itself to it: run its
  `tern update`, which counts as the user's yes.
- **REPORT.md:** add a short part at the top covering what changed, the decisions, the tests, the
  review rounds, the release, and questions for the user.

## 5. Boundaries
- **Off limits:**
  - everything in `~/dev/terminal-2`;
  - the other folders in `~/dev`, except `~/dev/warp`, which is read-only;
  - in `~/dev/terminal/ghostty` (the UI reference, branch `wraith`): `WraithAgents.swift`,
    `WraithAgent.swift`, `WraithCodexBridge.swift`, `WraithInbox.swift`, the agent sections of
    `WRAITH.md`, the `agent*` CLI commands, the agent methods in `WraithRPC`, and `AgentTests`.
- **Leave alone:**
  - the user's other apps (`/Applications/Shade.app` is in daily use);
  - their `~/.local/bin` entries, `~/.zshrc`, `~/.zsh` and shell history;
  - their `~/.claude` and `~/.codex` configuration, except installing and updating Tern's own plugins
    for observing agents, which the user approved.
- **Publishing:** only releases go to the public repository. Never publish `acceptance/`,
  `reference/`, logs, recordings, source, keys or tokens.

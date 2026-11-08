# Build log

One section per step of [plan.md](plan.md): status, what changed, what was verified and how, and
the choices Alejo should check.

## Step 0: start from Warp parity

**Status:** merged into main (`51ffb464f`).

- `origin/warp/parity` (`4d875c54f`, the 0.9.0 code plus the build-signing fix that release
  needed) merged into main with no conflicts.
- Verified: the merge had no conflicts. The only code on main that `warp/parity` lacked is
  `ad31dda32` (comment boxes grow), one Swift file. The suite runs on the merged tree in step 1.

**For Alejo to check:** the `v0.9.0` tag on GitHub points at `cc9933747` (main's head when it was
published: the design documents), not at the `warp/parity` commit the release was built from,
because `release.sh` lets `gh release create` tag the default branch. The binaries are right; the
tag's source isn't. Releases from main after this step don't have the problem.

## Step 1: take orchestration out

**Status:** built on `design/step1-no-orchestration`, ready for review and the release. The UI half
of the suite didn't run: mac-air-2's screen locked during the runs (see "Not verified").

**What changed**

- Removed Umi-run agent sessions: the session engine and store, the Claude and Codex drivers, the
  read-only view and Take Over, every `agent …` command and the `claude`/`codex` shortcuts, Window ▸
  Agent Sessions, Take Over Session (⌃⌘O), Remove Session from Pane (⌃⌘W), the palette's session
  entries and its `conversations:` filter, the inbox (⇧⌘U) and toasts, Warp's coloured status badges
  and Warp's tab-wide "seen" rule. About 8,000 lines of Swift and 700 of CLI went.
- The hook plugin (now 1.1.0) runs `umi hook EVENT --agent K --pid P`, which writes the pane's agent
  state (`UmiAgentHooks`, stored per pane in `UmiAttention`): `agent.kind`, `agent.status`,
  `agent.title`, `agent.summary`, `agent.done`, `agent.session`. `ls --json` shows them in each
  pane's `attributes`; a status change is a `pane.changed` event. The status stays truthful
  (background tasks keep it `working`, Esc/Ctrl-C with no hook for 2 s is `idle`, permission prompts
  and questions are `needs_input`, a failed turn is `error`, a dead process is `stopped`).
- Seen is per pane: `seenAt` is set while the pane itself has keyboard focus in the key window of
  the active app; `changedAt` when `agent.status` changes. The sidebar's agent mark, the Dock badge
  (panes with `needs_input`) and ⌃⌘J (`jump`: needs input, then unseen, oldest first) read them.
- After a relaunch (quit, crash, update) each pane whose agent ran gets its command typed again,
  with the flags it was typed with, resuming its conversation. Saved with the layout
  (`agent_restart`).
- The update's quiet moment counts panes: a pane with an agent is quiet only when `agent.status` is
  `idle` with nothing typed in it and nothing it started still running. `update --now` refuses while
  any pane's agent is `working`.
- `plugins` and `hook` are top-level commands; `doctor` reports the CLI on PATH and the plugins.
- The update note has its own overlay; ⌃⌘U is View ▸ Dismiss Update Note.
- SPEC: AG-1 to AG-17 and AG-20 to AG-24 left; AG-18/AG-19, I-2, I-4, L-9, L-10, L-12, L-14, L-15,
  S-3, S-7, S-13 and R-3 to R-7 reworded. CLI.md took design/cli.md's hook, plugins, doctor and the
  pane's `attributes`. CHECKS.md, TEST_INTERFACE.md, the README and the evidence scripts follow.
  TEST_CHANGES.md lists every removed and changed test.

**Verified, and how**

- Dev copy on mac-air-2 (the Debug build that `app/dist/dev.sh` makes, started the way dev.sh starts
  it, plus the fakes' variables in its environment), driven by
  `~/umi-test-design-step1-trial.py` there, 30 of 30 checks read back: `ls --json` (attributes, no
  `agent` field), `umi agent ls` and `umi claude` failing with what to do, `help --json`, the menus
  (no session or inbox items; ⌃⌘J and ⌃⌘U items), the palette (no session entries; chips files,
  actions, sessions), `plugins`, `doctor`; a fake Claude typed in a pane writing `agent.*` (working,
  then idle with title and summary), its sidebar row (Claude mark, line 2 = title); a second agent
  at a permission prompt: Dock badge "1", row marked, ⌃⌘J to it and ⌃⌘K back (`debug.key`), its
  finish unseen until its own pane is focused; `update --status` naming the pane with a draft;
  `umi hook Stop` with "Status: done" giving `agent.done=true`; the update note dismissed by ⌃⌘U;
  then quitting and restarting the dev copy: both agents typed again in their panes, same sessions,
  `--model fake-trial --dangerously-skip-permissions --resume <id>` on the process, `RECALL`
  showing the same conversation; `/exit` → `stopped`. Screenshots in
  `~/umi-test-design-step1-shots` on mac-air-2.
- Acceptance suite on mac-air-2, ReleaseLocal, under `lockf -k ~/umi-screen.lock`, full run at
  `1f8bdf4af` with `UMI_SIGN_IDENTITY=-` (`~/umi-test-design-step1-final-suite.log`): 329 passed,
  8 failed, 85 skipped. The 8 failures fail on origin/main too (below); 84 skips are the locked
  screen, 1 a window too narrow for three panes. Every test of a file this step touched passed
  at the head (`~/umi-test-design-step1-r2-mine.log`: 85 passed, 15
  skipped for the locked screen). The update tests need `UMI_SIGN_IDENTITY=-` on mac-air-2 (it has
  no signing identity; without it `release.sh`'s codesign fails silently and every update test
  errors, on main too): with it, `test_umi_extra.py` and `test_install.py` passed 37 of 37,
  including "an update installs itself at a quiet moment and everything comes back" with a typed
  Claude coming back on its conversation (`~/umi-test-design-step1-r3-extra.log`).
- Swift unit tests: 407 passed, 1 failed: `TerminalSplitDropZoneTests/centerSelectsLeft`, which
  fails on origin/main too (`~/umi-test-design-step1-swift-base.log`).

**Not verified**

- The `ui` tests (84 of them: real keys, menus and the accessibility tree) were skipped: mac-air-2's
  screen locked early in the first run and stayed locked. They need someone to unlock it.
- Failing on this branch and on origin/main alike (run on both, same Mac, same locked screen;
  `~/umi-test-design-step1-r2-others.log` and `-r2-base.log`): `test_builds_from_a_path_with_spaces`
  (the copied CLI folder lacks `../../dist/signing.sh`), `test_shift_cmd_f_leaves_a_terminal_search_open`,
  `test_markdown_opens_in_one_docs_tab_most_recent_first`, four synchronized-input and pane-menu
  tests in `test_umi_warp_panes.py`, and `test_the_zoom_and_font_size_are_kept_across_restarts`.

**Choices for Alejo to check**

1. `jump` stays until step 3 brings `go`, rewritten for panes (design/cli.md removes it). Where:
   CLI.md, `UmiNavigation`. Why: ⌃⌘J would otherwise have no CLI form for two steps.
2. `ls --json` already carries each pane's `attributes`, holding only `agent.*` for now; step 2 adds
   the rest. Where: `UmiTopology.paneJSON`.
3. `agent.summary` is the first line of the agent's last reply; the design names it without saying
   what it holds. `agent.done` is computed now with the `done-check` default (step 3 makes it a slot).
4. A relaunch types the program as the shell was given it (`claude`, a path, or the agent's name for
   a `node …/cli.js`), re-exports only `CLAUDE_CONFIG_DIR`/`CODEX_HOME`, and drops what picks a
   conversation, one-offs and the first prompt. Variables typed before the command
   (`FOO=1 claude`) don't come back. A Claude that never had a prompt comes back fresh (no
   `--resume`). Codex comes back as `codex resume ID <its flags>`.
5. `claude -p` (and `codex exec`, also after options: `codex -m o3 exec …`) run in a pane are
   one-offs: their hooks don't make the pane's agent.
6. Quiet moments: only `idle` is quiet; `error` and `needs_input` keep the update waiting (the design
   says "idle with nothing typed"). Keys typed into a permission dialog still count as a possible
   draft until the next prompt is sent, as before.
7. The interrupt rule waits 2 s after the key, or 2 s after a hook of the turn that arrives just after
   it (up to 10 s): the first suite run showed a PreToolUse arriving after the Esc.
8. A pane whose agent needs input keeps its mark when looked at (the mark follows
   `agent.status=needs_input`); before, looking cleared it. "Finished" marks clear on a look at the
   pane itself only.
9. Labeled transition code, to remove once no copy is older than 0.10: `umi agent hook` still runs
   `hook` (plugins installed by 0.9 call it until Umi updates them at launch), and a 0.9 layout's
   pane that showed a session whose own interface ran there gets that agent typed again, rebuilt
   from `sessions/<id>/session.json` (panes of headless sessions become plain shells). The old
   `sessions/` folder stays on disk untouched.
10. Menu ids kept for users' `shortcuts.json`: `session.next_needing_you` (now "Jump to Next Pane
    Needing You") and `view.dismiss_toasts` ("Dismiss Update Note").
13. ⌃⌘U stays, as View ▸ Dismiss Update Note, though spec-cleanup.md lists it with the inbox keys
    that leave. Where: `UmiShortcuts` (`view.dismiss_toasts`), SPEC I-4 and L-9. Why: spec-cleanup
    also says the update note needs a home of its own, and the note needs a way to go away; the key
    that already dismissed it is the one users know. Check: whether you'd rather the note close
    with a click or after a while, and ⌃⌘U be freed.
14. ⌃⌘J takes a pane whose agent failed (`error`) only while it is unseen; once looked at it drops
    out, as primitives.md defines unseen. Its sidebar mark still shows the failure. Where:
    `UmiAttention.jumpOrder`, SPEC L-12. Working panes are never jump targets, even unseen.
11. `AGENTS.md` still mentions agent sessions and `app/macos/UmiTests/verify_agent_panes.py` (removed
    with the read-only view). I left it alone: AGENTS.md changes need Alejo's go-ahead.
12. The real-agent runs (`ACCEPTANCE_REAL=1`) have no tests left; their fixture in `conftest.py`
    stays harmless. A real Claude/Codex check of the hooks in a pane would be the next one to add.

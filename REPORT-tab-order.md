# Umi 0.6.1: tabs keep their order, as in Warp (BRIEF-tab-order.md)

Your words: "fix the tab reordering? right now it has a custom logic and I want to have the standard
behavior from warp that doesn't switch tab order depending on recency". Released as
[v0.6.1](https://github.com/alejoacelas/umi/releases/tag/v0.6.1) and installed on this Mac. Decisions
75–77 in `DECISIONS.md` give the reasons.

## What changed

- **Selecting a tab never moves it**, by any route: a click, ⌘1–9, ⇧⌘[ / ⇧⌘], ⌃Tab, `umi tab focus`
  (or `next`, `prev`, `back`), a pane focus, `jump`, a notification, reopen.
- **An agent finishing its turn never moves its tab.** The row still shows the quiet mark.
- **Tabs move only when you move them**: dragging, `umi tab move`, Move Tab Up/Down, `umi tab new
  --index`, pinning and unpinning. Pinned tabs stay first. Pinning puts a tab at the end of the pinned
  tabs and unpinning puts it at the top of the others, exactly as Warp does.
- **New tabs open where Warp opens them.** I checked Warp's source (the copy in the Trash, commit
  `6398d1e9`): `new_tab_placement` defaults to `AfterCurrentTab`, below the pinned tabs, on every path
  that makes a tab. Umi didn't match: ⌘T inserted after the current tab, `tab new` and session tabs went
  last, and then the old rule moved any selected new tab to the top. Now a tab you go to opens right
  after the current one (⌘T, the sidebar's +, `tab new`, files and folders opened in a new tab,
  sessions started with `--focus`). A tab opened in the background (`--no-focus`, sessions shown without
  `--focus`) goes last, as before. Putting it after the current tab instead would push every tab below
  down while you aren't looking, and several would stack newest first (§76).
- **Removed, not left dormant**: `UmiTabOrder` with its 1.2 s settle delay and freeze, the
  pending and known stops and their observer, the 60 s cut-off, placed-by-hand tracking, and the `hold`
  wrappers around drops, moves, `tab new --index` and reopen. Also gone: `reorderTabs` and its
  `tab.reordered` event, `UmiAttention.lastStop(for:in:)`, and `debug.navigation`'s `order_frozen`.
  The callers are simpler.
- **Found by the review and fixed**:
  - a file opened from Finder in a new tab went last;
  - Redo of New Tab reopened the tab one place further down;
  - undoing an earlier move moved a tab made since: first to the end, then along with the moved tab.

  Undo and redo now record which tabs a step moved and put back only those (§77). One known limit:
  when a tab made since sits next to the moved tab, redo can't always restore the exact earlier order.
- **Docs**:
  - SPEC S-7 is rewritten, and L-11's reference to it is updated;
  - REQUESTS.md adds your words, dated 2026-10-27, and marks the earlier request superseded;
  - CLI.md says where `tab new` puts a tab and no longer lists `tab.reordered`;
  - CHECKS.md S-7 and the S-7 verdict are rewritten;
  - TEST_CHANGES.md records the test changes;
  - BRIEF-tab-order.md keeps the brief.

## Tests and review

- **Acceptance suite, fake agents, on the final build: 393 passed, 0 failed**, 32 skipped. 22 of
  those are UI tests (see below). The other 10 are real-agent tests, which this brief didn't ask for.
  Log: `logs/tab-order-suite-2.log`.
  - An earlier targeted run had one failure in `test_detached_pane_keeps_its_size` (M-5, a window
    size). It passed alone and in the full run, and it failed the same way in an earlier run before
    this change, so it depends on test order and isn't caused by this change.
- **Swift unit tests: 363 passed, 0 failed**, including the new `UmiTabOrderTests`:
  - selecting never moves a tab;
  - pinning moves only that tab;
  - moves stay in their pin group;
  - new tabs open after the current tab, or last in the background.
- **New acceptance tests**:
  - selecting by every route the suite can drive leaves the order, also after a wait longer than the old
    settle delay;
  - stops and questions in any tab leave it, and the marks show;
  - the fake Claude and Codex finishing turns move no tab (`test_live.py`);
  - new-tab placement;
  - manual moves and pins hold;
  - undo and redo through the Edit menu.

  The four tests of the old rule were replaced. Nothing was weakened: the pin test in
  `test_umi_panes_ui.py` is stricter than before.
- **Codex, 4 rounds** (`codex exec`, logs in `logs/tab-order-codex-round*.log`):
  - round 1: the Finder-file placement and the Redo placement;
  - round 2: undo put a tab made since at the end;
  - round 3: anchoring it to its neighbour still moved it along with the moved tab;
  - round 4: **no material findings**.

  I checked each finding in the code before fixing it, and each fix has a test that covers it.

## Release and install

- `app/dist/release.sh --version 0.6.1 --build` published v0.6.1, marked latest. The feed
  (`releases/latest/download/appcast.json`) serves 0.6.1, and the zip is signed with the usual key.
- While I worked, someone pushed two commits to `origin/main` (`791f75c40`, `1e21cb095`: `app/dist/dev.sh`
  and an AGENTS.md section). `gh release create` tags the remote head, so the tag `v0.6.1` is at
  `1e21cb095`, while I built from `d40e66547`. The two differ only in those two files, which aren't in
  the app, so the release matches its tag. My checkout is fast-forwarded to them.
- This Mac: `umi update --now` installed 0.6.1 and relaunched Umi. `umi --version` says 0.6.1, its idle
  Claude session came back, and its six tabs are in the same order.
- **Tern was not touched**: it's still running with the same process and its live Claude session.

## What I couldn't do

- **The 22 UI tests didn't run.** The screen was unlocked, but the process running pytest (under
  tmux) doesn't have the Accessibility permission, so the `ui` fixture skipped them. One of them is
  new and covers ⌘T placement plus Undo/Redo of New Tab through the real menu. Most of the same paths
  have non-UI tests through Umi's internal `debug.*` methods. To run them, give the terminal that runs
  pytest the Accessibility permission, then run
  `cd acceptance && uv run pytest --target targets/umi.json -m ui` and leave the Mac alone meanwhile.
- **Not checked by hand** (CHECKS.md S-7): clicking rows and pressing the keys in a real window, and
  clicking a desktop notification. All of them go through the same `selectTab`, which no longer
  reports to any ordering code.

## Disk

Free space dropped to 1.8 GB during the run. I deleted the Xcode DerivedData folders of the old
checkouts `~/dev/terminal`, `terminal-2` and `terminal-3` (and its worktrees), about 2.5 GB, which the
brief allows, plus this run's own pytest temporary folder. This repository's DerivedData stays.
About 4.8 GB was free before the release.

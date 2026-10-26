# Umi 0.6.0: Tern renamed, one repository (BRIEF-umi.md)

Install or update anywhere with
`curl -fsSL https://github.com/alejoacelas/umi/releases/latest/download/install.sh | bash`.
Decisions 66–74 in `DECISIONS.md` give the reasons; `AGENTS.md` says how to build, test and release.

## What changed

- **One repository**, public: [alejoacelas/umi](https://github.com/alejoacelas/umi), cloned at
  `~/best/projects/2026-10-26-umi`. The outer repository's 74 commits, the app's 18,148 (Ghostty's
  history plus the fork, merged under `app/` with `git subtree`, so Ghostty's commit ids are kept and
  upstream can still be merged) and the release repository's 4 (folded into `README.md`, `LICENSE`,
  `licenses/`). Build outputs, caches, `logs/`, `.worktrees/` and `.ref/` stay out; the largest file
  in the whole history is 22 MB. The repository hosts the releases too.
- **Renamed to Umi**: `Umi.app`, `dev.umi.app`, `umi-app` and the `umi` CLI (linked into
  `~/.local/bin`), `~/Library/Application Support/Umi`, `UMI_*`, the window and menu names, the About
  window (now Umi's, with links here), the update feed (this repository's latest release), the
  installer, the agent plugins and their marketplace (`umi@umi`), the docs and the acceptance suite;
  the source's own names too (`Features/Umi`, `UmiCLI`, `umi_blocks.zig`, `umi-blocks`). Old briefs,
  decisions, reports and commits still say Tern.
- **Coming from Tern**: the first launch copies Tern's windows, tabs, panes, sidebar, shortcuts,
  editor recovery and agent sessions; Tern's folder is only read. Copied sessions are stopped (never
  resumed by Umi on its own, since Tern may be driving them): Take Over continues one in Umi. Failures
  are listed in `imported-from-tern.json` and shown at launch. Spec R-11, seven tests.
- **Icon**: the public build ships an original icon (a prompt over a night sea), drawn by
  `app/dist/icon/icon.swift` on Apple's macOS grid; Ghostty's icon no longer ships. The poster icon is
  applied only locally: `app/dist/local-icon.sh` fetches it from 1Password, shapes it into
  `~/.config/umi/icon.png` and sets `macos-icon = custom` in `~/.config/umi/config`, a new config file
  only Umi reads. No poster image is in the repository, its history or the release (checked).
- **Signing key**: the same Ed25519 key, now also in 1Password as "UMI_UPDATE_SIGNING_KEY — umi"
  (`mac-agents`); `release.sh` reads it from there first and refuses a key that doesn't match the app's
  public key. Reference in `AGENTS.md`.
- **Fixed along the way**: inherited `GHOSTTY_RESOURCES_DIR` of another app (Tern, Ghostty) is ignored;
  `TERN_*` variables are cleared; an app hosting unit tests is isolated (it had created the user's
  state folder once, see below); isolated instances keep out of the user's icon and window frame;
  new windows open at 1180 × 740 (65 columns had been left beside the sidebar).

## Tests and review

- Acceptance suite, fakes, on the release build: **388 passed, 0 failed**, 31 skipped (21 UI tests:
  the screen was locked all session; 10 real-agent tests, run separately). Real agents
  (`ACCEPTANCE_REAL=1 -m real`, Claude `haiku`, Codex `gpt-6-luna`): **10 passed**; the suite then
  removed what they left in `~/.claude` and `~/.codex`. Test changes are in `acceptance/TEST_CHANGES.md`
  (renames, three racy waits, the real live test's folders and today's agent prompts).
- App tests: Swift unit tests **359 passed** (1 skipped benchmark). Zig: 3,893 passed, 25 skipped,
  1 failed; the failure was the one test the rename broke (the sorted shell-features string), fixed and
  passing on its own re-run.
- Codex as adversarial reviewer (`codex exec -s read-only`, logs in `logs/review-*.md`):

| Round | Material | About |
|---|---|---|
| 1 | 5 | Tern starting mid-copy, sanitising and copy failures, symlinks, inherited Ghostty resources |
| 2 | 2 | Tern starting after the last check (now: copied sessions always stopped), unreadable source |
| 3 | 2 | copied watches resuming a supervisor, staging permissions |
| 4 | 1 | permissions of a symlinked Tern folder |
| 5 | 0 | none |
| 6 | 0 | none (on the released state; one low note on AGENTS.md's test-host wording, fixed) |

Each finding was checked against the code, fixed, and given a regression test where one could reach
it (the watch test fails on the build before its fix).

## Release and install on this Mac

- [v0.6.0](https://github.com/alejoacelas/umi/releases/tag/v0.6.0): `Umi-0.6.0.zip`, `appcast.json`,
  `install.sh`, signed with the update key. Installed with the one-line installer into
  `/Applications/Umi.app` next to the running Tern, which was never quit, updated or touched (its live
  Claude session kept running throughout).
- Checked: Umi launched; `umi ls` shows Tern's 2 windows and 6 tabs with their ids, names and splits
  (Tern's agent session in its pane, idle, with nothing started); `umi tab new`, `umi send`, `umi read`
  (the pane's own `UMI_PANE_ID` came back) and `umi tab close` drive it; the poster icon shows on the
  installed app. Umi registered its `umi@umi` plugins with Claude Code and Codex.
- `~/.claude/settings.json` now enables only `umi@umi`, with the `umi` marketplace at
  `/Applications/Umi.app/Contents/Resources/agent-plugins` (it had `tern@tern`; the old file is
  `~/.claude/settings.json.before-umi`).

## Not done, or worth knowing

- **UI tests didn't run** (screen locked); neither did a visual check of the Dock tile. Run
  `cd acceptance && uv run pytest --target targets/umi.json -m ui` with the screen unlocked.
- **A test host made your Umi state folder once**: `zig build test` runs the Swift tests inside the app
  with no state folder of its own, so for about a second it was your Umi and copied Tern's state into
  `~/Library/Application Support/Umi`. A watchdog stopped it before it registered plugins; the folder
  was removed (nothing else touched) and the app now isolates test hosts itself (decision 72).
- **The disk filled up** during a test run (1.8 GB free; one run's failures came from it). I removed
  only what this run created (test temporary folders, the Debug build, today's Xcode DerivedData, the
  Zig cache). About 4 GB are free now. Xcode's DerivedData still holds ~2.5 GB of Ghostty builds from
  the earlier Tern runs, safe to delete with the old folders.
- **Before deleting Tern**: run `tern agent plugins remove` (it removes Tern's plugins and marketplaces
  from Claude Code and Codex, which still list them), then delete `Tern.app`, `~/.local/bin/tern` and
  `~/Library/Application Support/Tern`. Until then, don't take over in Umi a session Tern is still
  running: both would drive the same conversation.
- Umi is now the default app for Markdown files (the installer does that; `UMI_INSTALL_NO_DEFAULT=1`
  skips it).
- The `v0.6.0` tag is on the commit after the one the app was built from; the difference is tests and
  docs only.

## The old folders and `alejoacelas/tern`

Nothing in this repository needs `~/dev/terminal`, `~/dev/terminal-2`, `~/dev/terminal-3`,
`~/dev/terminal-3-notes`, `~/dev/kitty-plus`, `~/dev/warp` or the GitHub repository `alejoacelas/tern`:
it builds from its own checkout (Zig packages come from their upstream URLs), the suite's target uses
paths relative to the repository, the scripts and docs refer only to this repository, and a fresh clone
has no other remote and every path the Xcode project names. Both repositories' histories and the
release files are here, and installed copies update from `alejoacelas/umi`. They can be deleted
(after `tern agent plugins remove`, above).

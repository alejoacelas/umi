# Brief: rename Tern to Umi and consolidate into one repository

Alejo will not supervise this run. Make reasonable decisions yourself, record them
in `DECISIONS.md`, and keep going until the finish criteria are met. Do not stop
to ask questions. Commit early and often, and push after every commit. Never
commit or print secrets.

## Context

Tern is Alejo's macOS terminal for working with coding agents, built on Ghostty
and modelled on Warp. Today it lives in two local git repositories on this Mac,
neither with a GitHub copy:

- `~/dev/terminal-3`: spec, acceptance suite, briefs, `DECISIONS.md`,
  `COMPROMISES.md`, `REPORT.md`, `release-repo/` (the release README, install
  script, licenses).
- `~/dev/terminal-3/app`: the app itself, a Ghostty fork with its own history
  (ignored by the outer repo; its only remote is a local Ghostty clone).

Releases are published to the public repo `alejoacelas/tern`, which hosts only
release downloads. The new name is **Umi** (the heroine of *From Up on Poppy
Hill*; also Japanese for "sea").

## What to do

1. **One repository.** Create the public GitHub repo `alejoacelas/umi` and a
   local clone at `~/best/projects/2026-10-26-umi`. Bring in both repositories
   with their full histories, the app under `app/` (for example by merging the
   app's history into the outer repo with a subdirectory prefix). The new repo
   hosts the source and the releases. Fold `release-repo/` into it. Keep build
   outputs, caches, `logs/` and `.worktrees/` out of git; check that no file
   exceeds GitHub's 100 MB limit.
2. **Rename everything user-facing to Umi**: app name and window titles, bundle
   id (`dev.umi.app`), the CLI (`umi`, linked into `~/.local/bin`), state
   directory (`~/Library/Application Support/Umi`), environment variables
   (`TERN_*` to `UMI_*`), the update feed (releases of `alejoacelas/umi`), the
   install script, the agent plugins and their marketplace name, docs, and the
   acceptance suite. Historical records (old decisions, reports, commit
   history) can keep saying Tern.
3. **Keep Alejo's state.** On first launch, if Umi has no state directory and
   Tern's exists, copy (don't move) Tern's layout, UI state and sessions into
   Umi's, so Umi opens with the same tabs and agent sessions.
4. **Icon.** The poster-based icon must never enter the public repo, its
   history or the public release, because the art is Studio Ghibli's. Instead:
   - Ship the public build with a simple original icon you design yourself (no
     Ghostty or third-party artwork).
   - Apply the poster icon locally on Alejo's Macs only. The source is
     `icon-source.png` here (1434 px square crop of the poster; the full scan is
     `poster.jpg`), also stored in 1Password as a document:
     `op-agent document get gkm26qrhn7brei7p5lkcxjxlz4 --vault mac-agents`.
     Prefer a runtime setting the app reads (Ghostty has `macos-icon = custom`
     with `macos-custom-icon = <path>`; check the fork still supports it) with the
     file at `~/.config/umi/icon.png`, so updates keep it without touching the
     signed bundle. Shape it as a proper macOS icon (rounded rectangle, Apple's
     icon-grid margins). Add a small script in the repo (no image inside it)
     that fetches the file from 1Password and sets this up, and run it on this
     Mac.
   - Add `icon-source.png`, `poster.*` and the generated icon files to
     `.gitignore`, and check `git log --all` never contains them before pushing.
5. **Signing key.** Updates are signed with the Ed25519 key in the login
   keychain ("Tern Update Signing Key", backup `~/.config/tern/update-signing-key`).
   Keep using the same key. Store it in 1Password with
   `~/.local/bin/op-agent item create --vault mac-agents` as
   "UMI_UPDATE_SIGNING_KEY — umi", make the release script able to load it from
   there, and record the reference in `AGENTS.md`.
6. **Self-contained.** Alejo will delete `~/dev/terminal`, `~/dev/terminal-2`,
   `~/dev/terminal-3`, `~/dev/terminal-3-notes`, `~/dev/kitty-plus`, `~/dev/warp`
   and the GitHub repo `alejoacelas/tern` after this run. Make sure nothing in
   the new repo (build, tests, docs, scripts) needs them. Do not delete or move
   them yourself.
7. **Verify.** Build the app, run the acceptance suite and the app's tests, and
   fix what the rename broke. Then run Codex as an adversarial reviewer
   (`codex review` or `codex exec --dangerously-bypass-approvals-and-sandbox`)
   looking for leftover Tern names, broken update/install paths, state
   migration bugs and anything that still depends on the old folders. Verify
   each finding, fix the real ones, and repeat until a round finds nothing
   material.
8. **Release and install.** Publish release 0.6.0 of Umi from the new repo,
   then install it on this Mac with the new install script. **Tern is running
   on this Mac with a live agent session: do not quit, update or uninstall
   Tern.** Install Umi alongside it and check that Umi launches, the `umi` CLI
   drives it (open a tab, send a command, read the output, close the tab) and
   it restored Tern's tabs. Update `~/.claude/settings.json` on this Mac so the
   agent-plugin marketplace points at Umi.app instead of Tern.app.

## Finish criteria

- `alejoacelas/umi` holds both histories, builds, and passes the acceptance
  suite and tests; Codex's last round finds nothing material.
- Release 0.6.0 is published with a working `install.sh`; Umi is installed on
  this Mac next to the still-running Tern.
- `README.md` opens with the one-line install command. `AGENTS.md` covers
  build, test, release and where secrets live. Everything is committed and
  pushed.
- A short `REPORT-umi.md` lists what changed, anything you could not do, and
  confirms the old folders and `alejoacelas/tern` are no longer needed.

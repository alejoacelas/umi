# Working on Umi

Umi is a macOS terminal for working with coding agents: a fork of Ghostty with a Warp-like sidebar,
tabs and panes, an editor, agent sessions (Claude Code, Codex) and the `umi` CLI. It was called Tern
until 0.5.0 (see "Names" below). This repository holds the source and publishes the releases.

| Path | What it is |
|---|---|
| `app/` | The app: Ghostty with Ghostty's full history, plus Umi. Umi's Swift is in `app/macos/Sources/Features/Umi`, its CLI in `app/macos/UmiCLI`, its agent plugins in `app/macos/UmiPlugins`; Zig changes are marked `Umi:` in comments. `app/AGENTS.md` and `app/macos/AGENTS.md` are Ghostty's own guides. |
| `app/dist/` | `release.sh`, `install.sh`, `sign-update.swift`, `local-icon.sh`, `icon/` (the icon's drawing code). |
| `acceptance/` | The black-box acceptance suite: `SPEC.md` (requirements), `CLI.md` (the CLI contract), `REQUESTS.md` (the user's words), `tests/`, fake agents in `fakes/`, `targets/umi.json`. |
| `*.md` at the root | Briefs (`BRIEF*.md`), `DECISIONS.md`, `COMPROMISES.md`, reports (`REPORT.md`, `REPORT-umi.md`). Records from before 0.6.0 say Tern and stay that way. |
| `logs/`, `.worktrees/`, `.ref/` | Local only (ignored): run logs, agent worktrees, reference copies. |

## Build

Needs Xcode 26 and Zig 0.16 (`~/.local/zig/zig-aarch64-macos-0.16.0/zig` on Alejo's Macs; anything
else via `ZIG=/path/to/zig`). The first Zig build downloads Ghostty's Zig packages.

```sh
cd app
zig build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=false   # libghostty → macos/GhosttyKit.xcframework
cd macos
xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64 build               # → macos/build/ReleaseLocal/Umi.app
```

Rebuild the library whenever something outside `app/macos` changes. `app/dist/release.sh --version
X.Y.Z --build --no-publish` does both steps and stamps a release copy without publishing. The built
bundle is `Umi.app` (`dev.umi.app`), with `Contents/MacOS/umi-app` (the app) and
`Contents/MacOS/umi` (the CLI, built by `app/macos/UmiCLI/build.sh` during the Xcode build).

## Test

All of these use isolated instances (their own `UMI_STATE_DIR`) and never touch the user's running
Umi, or Tern.

```sh
cd acceptance
uv run pytest --target targets/umi.json                  # the whole suite with fake agents (~25 min)
uv run pytest --target targets/umi.json -m "not slow"    # the quick loop
ACCEPTANCE_REAL=1 uv run pytest --target targets/umi.json  # also the real Claude Code / Codex tests (cheap models)
uv run python ../app/macos/UmiTests/verify_ui_paths.py      # UI paths without the accessibility tree
uv run python ../app/macos/UmiTests/verify_agent_panes.py   # agent panes, the same way

cd app && zig build test -Dtest-filter=<name>            # Zig unit tests (the full set is slow)
cd app/macos && env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin xcodebuild -project Ghostty.xcodeproj \
    -scheme Ghostty -configuration Debug SYMROOT="$PWD/build" -skip-testing GhosttyUITests test   # Swift unit tests
```

- The suite tests the build at `app/macos/build/ReleaseLocal/Umi.app` (`targets/umi.json`; paths in
  it are relative to the file). `results/traceability.md` maps each SPEC requirement to its tests.
- UI tests need the terminal running pytest to have the Accessibility permission and an unlocked
  screen; otherwise they are skipped, and they type into windows, so don't use the Mac meanwhile.
- `ACCEPTANCE_REAL=1` runs the user's own `claude` and `codex` logins; a fixture removes afterwards
  what the run added to `~/.claude` and `~/.codex` (log in `acceptance/results/`).
- Record test changes in `acceptance/TEST_CHANGES.md` and never weaken a test to make it pass.

## Release

```sh
app/dist/release.sh --version X.Y.Z --build --notes "What changed"
```

It refuses to publish from a checkout with uncommitted changes. It builds, stamps a copy of the app
with the version, signs it ad hoc, zips it, signs the zip with the update-signing key (and checks the
key matches the app's `UmiUpdatePublicKey`), writes the feed `appcast.json`, and publishes a GitHub
release `vX.Y.Z` on `alejoacelas/umi` with `Umi-X.Y.Z.zip`, `appcast.json` and `install.sh` (marked
latest; installed copies and `install.sh` read `releases/latest/download/appcast.json`). Then install
or update this Mac with `curl -fsSL https://github.com/alejoacelas/umi/releases/latest/download/install.sh | bash`
(the installer refuses to replace a running Umi; use `umi update --now` from inside it instead).

## Secrets and private files

Nothing secret is in this repository. Never commit or print one.

- **Update-signing key** (Ed25519, raw 32 bytes, base64; the same key Tern's releases used):
  1Password, vault `mac-agents`, item **"UMI_UPDATE_SIGNING_KEY — umi"**, field `credential`:
  `op://mac-agents/vv5tqiflwseevf5w7shbhmwoae/credential` (read with `~/.local/bin/op-agent read …`).
  `release.sh` reads it from `$UMI_UPDATE_SIGNING_KEY` if set, then from 1Password, then from the
  login keychain item "Tern Update Signing Key" (account `tern`) or `~/.config/tern/update-signing-key`.
  Its public half is `UmiUpdatePublicKey` in `app/macos/Ghostty-Info.plist`; a new key would make
  every installed copy reject updates.
- **The poster icon**: Alejo's Macs show a crop of the *From Up on Poppy Hill* poster as Umi's icon.
  The art is Studio Ghibli's: it must never enter this repository, its history or a release. It is
  1Password document **"UMI_ICON — umi"** (`gkm26qrhn7brei7p5lkcxjxlz4`, vault `mac-agents`).
  `app/dist/local-icon.sh` fetches it, shapes it into `~/.config/umi/icon.png` and sets
  `macos-icon = custom` in `~/.config/umi/config`. `.gitignore` keeps `icon-source.png`, `poster.*`
  and generated local icons out; check `git log --all --stat` before pushing anything icon-related.
  The public icon is drawn by `app/dist/icon/icon.swift` (`app/dist/icon/make-app-icon.sh` writes
  the asset catalog).
- **GitHub**: the `gh` CLI's login (account `alejoacelas`) publishes releases.

## Names

Product: **Umi** (`Umi.app`, bundle id `dev.umi.app`, CLI `umi`, state directory
`~/Library/Application Support/Umi` or `$UMI_STATE_DIR`, control socket
`<per-user temp dir>/umi-<hash>.sock`, user config `~/.config/umi/config`, environment `UMI_*`,
agent plugins `umi@umi`, releases on `alejoacelas/umi`).

Before 0.6.0 it was **Tern** (`dev.tern.app`, `tern`, `TERN_*`, `~/Library/Application Support/Tern`,
`alejoacelas/tern`). Umi copies Tern's state on its first launch (`UmiTernImport.swift`, SPEC R-11)
and clears inherited `TERN_*` variables; nothing else refers to Tern on purpose. Historical records
(old briefs, decisions, reports, commit history) keep the old name.

## History

The outer repository's history comes first; `app/` was merged in with `git subtree add` (commit
"Merge the app (a Ghostty fork) with its full history under app/"), which keeps Ghostty's commit ids,
so upstream Ghostty can still be merged with `git subtree pull --prefix=app <ghostty remote> main`
(the fork's base is Ghostty `35a81a980`, 2026-10-05). `git blame` follows files into the app's old
history; for `git log` of an app file before the merge, run it on the merge's second parent with the
path without `app/`. The release repository (`alejoacelas/tern`'s README and licenses) was merged the
same way and folded into the root.

## Conventions

- Record decisions in `DECISIONS.md` (numbered, with the options and the evidence), compromises in
  `COMPROMISES.md`, and a report per run.
- Commit early, push after every commit. Commits end with a `Co-Authored-By` line when an agent made them.

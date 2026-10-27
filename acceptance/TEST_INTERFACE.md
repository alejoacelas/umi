# Test interface

The tests treat the product as a black box. They use its CLI (`CLI.md`), files on disk, processes and
what macOS reports (which app is in front, …). To run them in isolation, a build has to provide a
few capabilities. It declares how it provides them in a **target file**, `targets/<name>.json`, so
the tests stay independent of any implementation.

## Capabilities a build must provide

1. **Isolated instance.**
   - The app can be launched directly (its executable, plus any arguments) with an environment
     variable naming a **state directory**. Everything that instance stores or listens on lives
     there or is derived from it. The CLI given the same variable talks to that instance and nothing
     else. So do agents started by that instance.
   - Such an instance must not restore or save the user's windows. It must not touch the user's own
     running copy, its state or its sessions.
2. **Agent binaries.** Environment variables naming the executables to run for managed Claude and
   managed Codex sessions. They are set on the app and CLI of an isolated instance.
   - The product runs them exactly as it would run the real `claude`/`codex`: same arguments, same
     protocol.
   - The tests point them at `fakes/fake_claude.py` and `fakes/fake_codex.py`.
   - `agent start --env K=V` must reach the agent's environment (the fakes read `FAKE_*` variables
     from there).
3. **Installer test mode.** The installer can be told the destination for the app and the CLI link,
   and told not to change the default Markdown app and not to launch anything.
4. **Screenshots.** `<cli> screenshot` (a product feature in CLI.md) is how written checks collect
   visual evidence.
5. **Releases and updates (I-4).**
   - A command that makes the release files for the current build, stamped with a given version, as
     if publishing it: the feed, the downloadable update, and a stamped copy of the app. The tests
     serve these files from a local web server.
   - An environment variable that points an instance (app and CLI) at another feed URL instead of
     the public one. The tests serve that feed over plain HTTP on 127.0.0.1, and the instance must
     accept it.
   - For isolated instances only: ways to shorten the update timings (the check interval, the quiet
     period without input, the countdown, Not now), to move the clock the quiet checks read and to
     stand in for the user's typing or clicking (Umi: `UMI_UPDATE_*_SECONDS`, `debug.update.clock`,
     `debug.update.input`), and to name an app copy the instance must treat as the user's installed
     one (Umi: `UMI_UPDATE_PROTECTED_APP`, which only ever adds protection).
   - Launch arguments that set a config value (`--auto-update=check`), kept when the instance
     relaunches itself after an update.
6. **Optional: restoration-safe build.** Restart tests that rely on window restoration (pins, agent
   panes coming back) need a build whose saved window state is separate from the user's installed
   copy, for example a build with a different bundle id. Without one, those tests are skipped.

## Target file

```json
{
  "name": "Shade",
  "app": "/path/to/Shade.app",
  "executable": "Contents/MacOS/ghostty",
  "cli": "Contents/MacOS/shade",
  "launch_args": ["--window-save-state=never"],
  "restore_launch_args": [],
  "env": {
    "state_dir": "SHADE_STATE_DIR",
    "claude_bin": "SHADE_CLAUDE_BIN",
    "codex_bin": "SHADE_CODEX_BIN",
    "feed_url": "SHADE_FEED_URL"
  },
  "release": {
    "command": ["bash", "/path/to/release.sh", "--version", "{version}", "--out", "{out}",
                "--base-url", "{base_url}", "--no-publish"],
    "feed": "appcast.xml",
    "app": "Shade.app"
  },
  "installer": {
    "command": ["bash", "/path/to/install.sh", "--from", "{app}"],
    "env": {"dest": "SHADE_INSTALL_DEST", "bin": "SHADE_INSTALL_BIN",
            "no_default": "SHADE_INSTALL_NO_DEFAULT", "no_launch": "SHADE_INSTALL_NO_LAUNCH"}
  },
  "build_cli": {"source": "/path/to/cli/source", "command": ["bash", "{src}/build.sh", "--out", "{out}"]},
  "restoration_safe": false,
  "other_products": ["com.mitchellh.ghostty", "dev.wraith.terminal"],
  "other_names": ["Ghostty", "Wraith"]
}
```

- **Paths:** `app` and `build_cli.source` may be relative to the target file, and so may words of
  `release.command` and `installer.command` that start with `./` or `../` (`targets/umi.json` uses
  this, so the suite runs from any checkout).
- **`executable`, `cli`:** relative to `app`, or absolute.
- **`launch_args`:** how the tests launch an isolated instance. It must not restore or save windows.
- **`restore_launch_args`:** for restart tests that need window restoration. Only used when
  `restoration_safe` is true.
- **`installer.command`:** `{app}` is replaced with the app path. The installer runs with the
  isolated instance's environment, so anything it asks the product goes to that instance.
- **`build_cli`:** optional, for R-4 (building from a path with spaces). `source` is copied to a
  folder whose path has spaces, `{src}`, and `command` must produce the CLI binary at `{out}`.
- **`release`:** `command` writes the release files for version `{version}` into the folder `{out}`,
  which the tests then serve at `{base_url}` (it ends with `/`). It must not publish anything. `feed`
  and `app` are paths relative to `{out}`: the feed file, and the stamped app the tests install as
  the "older" build.
- **`env.feed_url`:** the variable that points an instance at another feed.
- **`other_products`, `other_names`:** bundle ids, and app and CLI names, this build must not collide
  with (P-1). Your own bundle id is read from your Info.plist.

## Running

Tooling is managed by `uv` (Python 3.12, pytest, Hypothesis, pyobjc; see `pyproject.toml`).

```sh
uv run pytest --target targets/<name>.json                 # everything automated, fakes only
uv run pytest --target targets/<name>.json -m managed      # one area: layout editor interactive managed
                                                           # chaos panes robustness install
uv run pytest --target targets/<name>.json -m "not slow"   # the quick loop
uv run pytest --target targets/<name>.json --req MA-4,R-2 # only the tests of these requirements
uv run pytest --target targets/<name>.json --phase 1      # phase 1 (the app): tests needing managed agents left out
ACCEPTANCE_REAL=1 uv run pytest --target ... -m real       # real Claude Code / Codex (cheap models)
uv run python checks/run_checks.py --target targets/<name>.json   # written checks: evidence + REPORT.md
```

- `results/traceability.md` maps every requirement in SPEC.md to its tier, its tests and their
  status. It's rewritten after every run.
- UI tests (`ui` fixture) need this terminal to have the Accessibility permission (System Settings →
  Privacy & Security → Accessibility). Without it they're skipped, and the report says so.
- The tests open windows on screen and type into them. They don't touch the user's running copy of
  any product. Don't use the machine while the UI tests run.

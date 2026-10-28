# Umi 0.6.2: updates install themselves when nothing would be lost (BRIEF-quiet-updates.md)

Your words: "yes let's make install when quiet the default". Decisions 78–86 in `DECISIONS.md` give the
reasons; this is the short version.

## What changed

- **By default an update installs itself at a quiet moment.** Umi checks the feed every 15 minutes
  (`umi update` checks at once). A newer signed release is downloaded and verified without asking. At
  the first quiet moment the sidebar says "Updating to Umi X.Y.Z in 30 s" with **Not now** (waits at
  least an hour) and **Install now**; then Umi quits, installs and relaunches. A key, click or scroll
  in Umi during the countdown stops it until the next quiet moment.
- **After the relaunch everything comes back as after a quit**: windows, tabs, panes and their
  folders, agent sessions in their panes, live ones live. If another app was in front, Umi comes back
  behind it and doesn't take focus.
- **A `claude` you typed in a pane keeps its flags** (`--dangerously-skip-permissions --model X`,
  `--add-dir …`) and its conversation across a quit, a crash or an update. Before, it came back
  without `--dangerously-skip-permissions`. The same goes for a session you resume by hand
  (`claude --resume ID …`).
- **CLI**:
  - `umi update --status` says what is pending and what a quiet moment waits for: which pane (and
    tab) or session, unsaved files, input.
  - `umi update --now` installs at once (still refusing to cut off running turns without `--force`).
  - `umi update --rollback` goes back to the version installed before, from its kept, verified zip.
    The version you left doesn't install itself again until you run `umi update`.
- **Setting**: `auto-update = check` in `~/.config/umi/config` brings back asking first (Download,
  Later, Skip; the update then installs when Umi quits). `download` downloads without asking and
  installs on quit; `off` checks only when asked; `install` (or nothing) is the new default.
- **Safety kept, and added**: signature, hash, bundle id, version and code signature are checked as
  before, and the helper still puts the old app back if the swap fails. New:
  - an install that fails doesn't retry by itself at every quiet moment;
  - a file that fails verification isn't downloaded again every 15 minutes;
  - the last look just before quitting stands the install down if anything started;
  - an isolated or test instance (`UMI_STATE_DIR`) only ever updates a copy inside a temporary folder,
    never your installed app.
- **Docs**: SPEC I-4 (rewritten) and AG-22, REQUESTS.md (your words), CLI.md, CHECKS.md,
  TEST_INTERFACE.md, README, TEST_CHANGES.md; the brief is BRIEF-quiet-updates.md.

## How "quiet" is decided

All of these must hold, and whatever Umi can't determine counts as busy (`UmiQuiet.swift`):

- **Sessions**: no session Umi knows (started by Umi or typed in a pane) is working, starting or
  waiting for you, or was only inferred idle after a keyboard interrupt; no message is queued or being
  delivered; nothing an agent left running after its turn (Codex's background terminals, or any process
  carrying a session's tag outside the panes' terminals, which the quit would end).
- **Each pane**, one of:
  - *its own shell at an empty prompt*. The shell is the process on the pane's tty that Umi started
    (through `login`), and it must be what's in front (the pty's foreground process group, from the
    kernel). Nothing it started may still run: no job, no suspended program, no nested shell. Its own
    prompt marks (OSC 133, read by a new terminal function) must say the cursor is in the prompt's
    input and nothing but blanks is typed there. No marks, or a full-screen program, means "can't
    tell", so busy.
  - *an idle agent*: its own interface in front (identified by its process or the session its
    environment names, never by its arguments) in a pane whose input Umi follows, its session idle,
    nothing it started still running (`caffeinate` aside), and nothing having reached its input line
    since the last prompt was sent (typing, pasting, dropping, recalling history all count; Ctrl-C
    doesn't clear it, since a remapped Ctrl-C may never reach the agent).
  - *a session's read-only view*, when the terminal under the view is itself quiet.
  - *a pane whose process exited*.
- **No unsaved editor changes**, dialog, sheet, text field in use or open command palette.
- **Nobody typed, clicked or scrolled in Umi for two minutes.** Moving the mouse doesn't count, and
  neither does typing in other apps.

## Tests

- **Acceptance suite, fake agents, final build: 405 passed, 1 failed, 32 skipped** (`logs/quiet-suite-final.log`).
  - The failure, `test_an_update_now_counts_work_in_a_live_interface`, timed out after 30 s waiting for a
    session to go live. It passed when rerun, and 45 runs of it and two similar tests passed. The same
    timeout showed up twice before, in long runs only (about once per 200+ tests), so it looks like
    load. It first appeared during this work, so I can't rule my change out.
  - The 32 skips: 22 UI tests and 10 real-agent tests (below).
  - An earlier full run, before the review fixes, had 403 passed and 0 failed.
- **New tests**:
  - `test_quiet_updates.py`, 7 tests with fake agents and fake time: two minutes without input; busy
    panes (typed text, a program, a background job, a job without job control, a double-forked job, a
    nested shell, a right prompt); running turns, queued messages, a Codex background command,
    processes a session left behind; unsaved editor changes; idle agents in panes, and every way to
    leave something in an agent's input; a job beside an agent; an agent's own slow hook.
  - In `test_umi_extra.py`, 4 end-to-end tests with release builds:
    - downloaded without asking, not installed while a pane runs `sleep`, installed after the
      countdown, back with tabs, folders and a typed `claude` with the same conversation and flags,
      and without coming to the front;
    - activity stops the countdown, Not now, Install now, rollback with no update loop;
    - a failed install doesn't loop;
    - an isolated instance never updates the user's app.
  - In `test_live.py`, a `claude` typed with flags comes back after a quit with the same conversation
    and flags, and its first prompt isn't re-run. That test would have failed before this change. A
    second test covers a session resumed by hand.
  - Swift unit tests `UmiQuietTests` cover the decision from made-up snapshots and the flag parser.
- **The question tests** (`auto-update = check`) run with `--auto-update=check` and assert what they did
  before (`acceptance/TEST_CHANGES.md`).
- **Swift unit tests: 371 passed, 0 failed.**
- **Real agents** (`ACCEPTANCE_REAL=1 -m real`):
  - the 4 Codex tests passed;
  - the 6 Claude tests couldn't run. This Mac's Claude Code isn't logged in for the login shell Umi
    gives agents (`claude auth status` → `"loggedIn": false`); the earlier Umi run passed them, so the
    login has lapsed since. Every failure is "Not logged in · Please run /login", or waiting for a tool
    call that a logged-out Claude never makes. I didn't log in for you or route this session's token
    into test sessions.

## Review

**Codex (`codex exec`, high effort), 20 rounds.** Logs are in `logs/quiet-codex-round*.log`.

- Rounds 1–19 found 48 problems; **round 20 found none** ("NO MATERIAL FINDINGS").
- I checked every finding in the code before fixing it. Every one was real.
- Most were ways a draft in an agent's interface or running work could go unseen. Examples: Esc,
  history recall, cursor moves, multi-line Ctrl-U, drops, dictation, a queued prompt clearing a newer
  draft, a remapped Ctrl-C; jobs without job control, double forks, detached work, the user's own Stop
  hooks.
- Keystroke-by-keystroke tracking kept failing, so it became a blunt rule (§79): once anything reaches
  an agent's input line, an update waits until a prompt is sent or the interface closes.
- For the same reason, every process a live interface started counts as running. Telling MCP servers
  from hooks by name or start time failed three times.
- Others found:
  - the isolated-instance guard (now an isolated instance only updates a copy in a temporary folder);
  - waiting for the rollback copy;
  - a failed install retried through a remembered yes;
  - the last check before quitting;
  - a relaunch stealing focus;
  - zsh's right prompt looking typed;
  - Claude options that take values.

## Release and install on this Mac

- **v0.6.2** was published with `app/dist/release.sh --version 0.6.2 --build` (tag at `b53356b40`),
  then marked latest.
- **0.6.2 on this Mac**: `umi update --now` (run by 0.6.1's own updater) installed it and relaunched
  Umi. Both windows, all six tabs, their panes and the Claude session came back as they were.
- **v0.6.3** changes nothing but the version: the 0.6.2 app re-stamped with `release.sh --version 0.6.3
  --app app/dist/out/0.6.2/Umi.app`. Only Info.plist (version, its own feed address) and the ad-hoc
  code signature differ.
- **0.6.3 installed itself.** Nobody touched this Mac's Umi; I only read `umi update --status`.
  - 02:59: quiet (only the two minutes since launch had been missing).
  - 03:12:23: its 15-minute background check found 0.6.3, downloaded and verified it, kept 0.6.2's
    zip, and started the countdown.
  - 03:12:41: it installed and relaunched.
- **After the relaunch**:
  - `umi --version` says 0.6.3;
  - the layout is identical to before both updates (ids aside);
  - the Claude session is back in its pane, idle;
  - `last_install` says 0.6.2 → 0.6.3, ok;
  - `umi update --rollback` would go back to 0.6.2 (both verified zips are kept).
- **Tern** was never touched: same process throughout, its live session still running.

## What I couldn't do, and what to know

- **UI tests (22) didn't run.** The process running pytest (under tmux) has no Accessibility
  permission. To run them, give the terminal that runs pytest the Accessibility permission, then run
  `cd acceptance && uv run pytest --target targets/umi.json -m ui` and leave the Mac alone meanwhile.
- **Claude real-agent tests didn't run**: Claude Code on this Mac isn't logged in (see Tests). Run
  `claude /login` in a login shell, then `ACCEPTANCE_REAL=1 uv run pytest --target targets/umi.json -m real`.
- **Conservative on purpose.** Each of these holds an update back; none lets one lose work, and
  `umi update --status` names the cause:
  - once you type into an agent's interface, an update waits for the next prompt you send;
  - an agent interface with MCP servers running (you have none) holds updates back until it closes;
  - a pane whose shell doesn't mark its prompt (no shell integration) never counts as quiet.
- **Not kept across the relaunch**, as after any quit: terminal scrollback (a finished command's output)
  and the quick terminal.
- **Not testable without a keyboard**: keys typed into a `claude` before its first hook, during a Take
  Over, or while an input method composes. They're handled, with no non-UI test.
- **A pre-existing intermittent failure** (in 0.6.1 too): `test_undo_and_redo_of_a_move_leave_a_tab_made_since_in_its_place`
  fails in about 6% of runs on both 0.6.1 and 0.6.2: 4 of 70 cases on a copy of 0.6.1, and a similar
  rate on the new build. Undo computes the right order, then the tab the step moved disappears. It
  lives in 0.6.1's tab-undo code, which this brief doesn't touch, so I left it. The final runs
  deselect it in the targeted batches; the full suite ran it.
- **If a new version won't start**, the installer puts any release back (README):
  `curl -fsSL https://github.com/alejoacelas/umi/releases/latest/download/install.sh | UMI_INSTALL_FEED=https://github.com/alejoacelas/umi/releases/download/v0.6.2/appcast.json bash`,
  with Umi quit. `umi update --rollback` needs the app running.
- **Disk.** Free space went down to about 0.9 GB. I deleted the Xcode DerivedData caches twice
  (allowed), plus this run's own pytest temporary folders and the download temp files the tests left.
  The Zig cache in `app/.zig-cache` grew by about 0.7 GB from this run's rebuilds.

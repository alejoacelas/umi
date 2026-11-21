# Checks for the umi-next UI

- `node status.test.js`: the reply status-line parser (`web/status.js`).
- `node comments.test.js`: the comment parser and writer (`web/comments.js`), Umi's cases.
- The rest drive a running UmiNext started with `UMI_NEXT_DEBUG=1` (they talk to
  `<state>/debug.sock` through the same protocol as `umi-next-ui-debug`, with `debugsock.py`'s
  client: every command times out after 30 s instead of hanging the run), on a Mac where it may take
  the screen (mac-air-2, under `lockf -k ~/umi-screen.lock`). Run them from this folder's copy, so
  they find `debugsock.py` and `front.py` next to them:
  - `keylat.py STATE_DIR N`: key-to-screen latency through the app's own key path.
  - `sampler.py PANE SECONDS OUT.json`: the longest time a pane's screen went without changing.
  - `reload_test.py COLOR`: edits `web/style.css` and times until the page shows the colour (paths
    inside are mac-air-2's test worktree; adjust).
  - `hyper.swift` (`swiftc -O hyper.swift -o hyper; ./hyper tap|space|withkey|d`: the modifiers
    alone, Hyper+Space, Hyper+U, Hyper+D), `key.swift`
    (`./key CODE cmd shift …`) and `click.swift`: real modifier, key and mouse events through the
    HID tap (needs Accessibility for the caller).
  - `services_test.py STATE_DIR SCRATCH`: every `web/fs.js` call, from the page through the bridge.
    It types nothing, so it can run without the screen lock if the app runs with
    `UMI_NEXT_OFFSCREEN=1` (window off screen, never active).
  - `files_test.py STATE_DIR SCRATCH [BIG_REPO]`: the explorer, its right-click menu, quick open,
    global search and Search tabs (track b), by keys through the debug socket; runs off screen.
    It uses the clipboard and moves one scratch file to the Trash.
    BIG_REPO adds streaming, cancel, the 20,000-line cap and quick open's speed on a large repository.
    At exit it closes the tabs and panes it opened and ends their sessions.
  - `shortcuts_test.py STATE_DIR KEY HYPER [--debug-events]`: today's shortcuts by real key events,
    keys outside the table reaching the terminal, and a table entry added live working without a
    rebuild. It runs `click` (built from `click.swift`) from KEY's folder. `--debug-events` sends
    the keys through the debug socket instead of the HID tap. At exit it closes the tabs and panes
    it opened and ends their sessions.
  - `cli_test.py APP [SCRATCH] [NOTIFY_LOG]`: every `umi-next` command against a running test copy
    (APP is its `UmiNext.app`). Types nothing, so it runs with `UMI_NEXT_OFFSCREEN=1`; start the app
    with `UMI_NEXT_FOCUS_ASSUME_ACTIVE=1` too for the focus-log checks, and with
    `UMI_NEXT_TEST_NOTIFY_LOG=NOTIFY_LOG` so `notify` writes there instead of notifying.
  - `file_test.py STATE_DIR SCRATCH OPEN_LOG`: file panes (track a): Markdown preview, links,
    images, find, Rendered / Raw, comments, source editing, save, disk changes, drafts across a
    reload, ⌘W's question, refusals, JSON / CSV / TSV previews, git marks, chip icons, the pane menus. Debug-socket keys only, so it runs with `UMI_NEXT_OFFSCREEN=1`;
    start the app with `UMI_NEXT_TEST_OPEN_LOG=OPEN_LOG`.
  - `menus_test.py STATE_DIR SCRATCH [EXTRA_CONF]`: the terminal's right-click menu (a right-click
    through the debug socket), a tab row's menu and Ghostty's keybindings on the shortcuts page;
    the native menu answers as if an item were chosen. Off screen; uses the clipboard. EXTRA_CONF:
    the app's `UMI_NEXT_TERMINAL_CONFIG`, written by a first run, checked by the next.
  - `file_keys_test.py STATE_DIR KEY SCRATCH`: the file-pane keys the debug socket can't send as a
    keyboard does (⌥⌘M, Escape in CodeMirror's panels, the Edit menu's ⌘X ⌘Z ⇧⌘Z), by real key
    events, under the screen lock.
- `resume_test.py APP`: starts a test copy (`build.sh --test NAME`) off screen by itself, opens a
  real Claude session, restarts the app and its daemon, and checks the pane resumes that agent.
  Needs `claude` on PATH; stops the copy and moves its state to the Trash at the end.
- `docket_test.sh` (mac-air-2, `lockf -k ~/umi-screen.lock zsh docket_test.sh`): snooze to docket end to
  end with a real Claude session, a stub `~/.config/umi-next/docket-hook`, and task links served from
  `http://127.0.0.1:18765/umi/` (allowed only through `UMI_NEXT_DEBUG_TASK_ORIGIN` in debug mode). It
  writes everything to `/tmp/dock-test.log` and fails (exit 1, `FAIL …` on stderr) when Hyper+D leaves
  no docket mark (in the page and in `docket.json`), the hook never gets its input, the failing hook
  leaves no `failed` state, or the task link doesn't focus the docketed session. It serves
  `/tmp/umitask` on port 18765 itself unless something already answers there. It doesn't set up:
  - in mac-air-2's `~/umi-next-tools`: `d.sh` (this folder's `docket_helpers.sh`), `claude-tok`,
    `click` and `hyper` (built from `click.swift` and `hyper.swift`);
  - the stub hook, executable: it writes its stdin to `/tmp/docket-hook-in-<anything>.json` and exits
    with the number in `~/.config/umi-next/hook-exit` (the script writes 0, then 1 for the failing run);
  - the checkout `~/umi-next-ui`, which it resets to origin/main and builds.

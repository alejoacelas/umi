# Checks for the umi-next UI

- `node status.test.js`: the reply status-line parser (`web/status.js`).
- `node comments.test.js`: the comment parser and writer (`web/comments.js`), Umi's cases.
- The rest drive a running UmiNext started with `UMI_NEXT_DEBUG=1` (they talk to
  `<state>/debug.sock` through the same protocol as `umi-next-ui-debug`), on a Mac where it may take
  the screen (mac-air-2, under `lockf -k ~/umi-screen.lock`):
  - `keylat.py STATE_DIR N`: key-to-screen latency through the app's own key path.
  - `sampler.py PANE SECONDS OUT.json`: the longest time a pane's screen went without changing.
  - `reload_test.py COLOR`: edits `web/style.css` and times until the page shows the colour (paths
    inside are mac-air-2's test worktree; adjust).
  - `hyper.swift` (`swiftc -O hyper.swift -o hyper; ./hyper tap|space|withkey`), `key.swift`
    (`./key CODE cmd shift …`) and `click.swift`: real modifier, key and mouse events through the
    HID tap (needs Accessibility for the caller).
  - `services_test.py STATE_DIR SCRATCH`: every `web/fs.js` call, from the page through the bridge.
    It types nothing, so it can run without the screen lock if the app runs with
    `UMI_NEXT_OFFSCREEN=1` (window off screen, never active).
  - `files_test.py STATE_DIR SCRATCH [BIG_REPO]`: the explorer, its right-click menu, quick open,
    global search and Search tabs (track b), by keys through the debug socket; runs off screen.
    BIG_REPO adds streaming, cancel, the 20,000-line cap and quick open's speed on a large repository.
  - `shortcuts_test.py STATE_DIR KEY HYPER`: today's shortcuts by real key events, keys outside
    the table reaching the terminal, and a table entry added live working without a rebuild.
- `docket_test.sh` (mac-air-2, `lockf -k ~/umi-screen.lock zsh docket_test.sh`): snooze to docket end to
  end with a real Claude session, a stub `~/.config/umi-next/docket-hook`, and task links served from
  `http://127.0.0.1:18765/umi/` (allowed only through `UMI_NEXT_DEBUG_TASK_ORIGIN` in debug mode). Its
  helpers (`docket_helpers.sh`, copied there as `d.sh`, plus `claude-tok`, `click`, `hyper`) live in mac-air-2's `~/umi-next-tools`.
  - `cli_test.py APP [SCRATCH]`: every `umi-next` command against a running test copy (APP is its
    `UmiNext.app`). Types nothing, so it runs with `UMI_NEXT_OFFSCREEN=1`; start the app with
    `UMI_NEXT_FOCUS_ASSUME_ACTIVE=1` too for the focus-log checks.
  - `file_test.py STATE_DIR SCRATCH OPEN_LOG`: file panes (track a): Markdown preview, links,
    images, find, Rendered / Raw, comments, source editing, save, disk changes, drafts across a
    reload, ⌘W's question, refusals. Debug-socket keys only, so it runs with `UMI_NEXT_OFFSCREEN=1`;
    start the app with `UMI_NEXT_TEST_OPEN_LOG=OPEN_LOG`.
  - `file_keys_test.py STATE_DIR KEY SCRATCH`: the file-pane keys the debug socket can't send as a
    keyboard does (⌥⌘M, Escape in CodeMirror's panels), by real key events, under the screen lock.

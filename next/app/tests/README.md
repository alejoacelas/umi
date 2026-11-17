# Checks for the umi-next UI

- `node status.test.js`: the reply status-line parser (`web/status.js`).
- The rest drive a running UmiNext started with `UMI_NEXT_DEBUG=1` (they talk to
  `<state>/debug.sock` through the same protocol as `umi-next-ui-debug`), on a Mac where it may take
  the screen (mac-air-2, under `lockf -k ~/umi-screen.lock`):
  - `keylat.py STATE_DIR N`: key-to-screen latency through the app's own key path.
  - `sampler.py PANE SECONDS OUT.json`: the longest time a pane's screen went without changing.
  - `reload_test.py COLOR`: edits `web/style.css` and times until the page shows the colour (paths
    inside are mac-air-2's test worktree; adjust).
  - `hyper.swift` (`swiftc -O hyper.swift -o hyper; ./hyper tap|space|withkey`) and `click.swift`:
    real modifier, key and mouse events through the HID tap (needs Accessibility for the caller).

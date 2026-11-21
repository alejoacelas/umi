# umi-next daemon protocol

The daemon owns every session's pty and its screen (a libghostty-vt terminal). Clients talk to it
over one unix stream socket. The UI never needs the socket: it runs `umi-next-attach <id>` as a
pane's command and `umi-next-ctl` for everything else. The `umi-next` CLI (`next/app/cli`) is the
third client: it sends `ls`, `screen` and `send` over the socket itself.

## Files

State dir: `$UMI_NEXT_STATE_DIR`, default `~/Library/Application Support/Umi-next/`.

| File | What |
|---|---|
| `daemon.sock` | the socket (mode 0600). Its path must fit in 103 bytes. |
| `daemon.lock` | `flock`ed by the running daemon, holds its pid. A second daemon exits at once. |
| `daemon.log` | the daemon's log (stderr too). |

`umi-next-ctl new` and `daemon-start` start the daemon if nothing answers on the socket; the daemon
forks, calls `setsid`, ignores SIGHUP, points stdin/stdout at `/dev/null`, and keeps running when
whatever started it dies. Sessions die with the daemon (`daemon-stop --force`, or a crash).

## Framing

Every message is a frame: `type` (1 byte), payload length (u32, big endian), payload.

| Type | Direction | Payload |
|---|---|---|
| `J` | both | a JSON object: a request, or its reply `{"ok": true, …}` / `{"ok": false, "error": "…"}` |
| `I` | client → daemon | bytes to write to the attached session's pty |
| `W` | client → daemon | resize: cols u16, rows u16 (big endian) |
| `O` | daemon → client | bytes for the client's terminal |
| `X` | daemon → client | the session's process exited: exit code i32 (big endian; 128+N for signal N) |

## Requests (`J`, field `op`)

| op | fields | reply |
|---|---|---|
| `ping` | | `pid`, `sessions`, `state_dir` |
| `new` | `cwd` (must be an existing folder, else `no folder <cwd>` and nothing starts), `cmd` (run as `$SHELL -l -c cmd`; absent: `$SHELL -l`), `cols`, `rows`, `name`, `by` (who started it: `user` from the UI, `cli` from `umi-next-ctl new` by default), `env` (object; the session's environment: `umi-next-ctl new` sends a fixed set of its own variables, listed as `sessionVariables` in `Sources/ctl/main.swift`, plus each `--env KEY=VALUE`, never its whole environment; absent: the daemon's; the daemon then sets `TERM`, `COLORTERM`, `PWD` and `UMI_NEXT_SESSION_ID`) | `id` |
| `ls` | | `sessions`: `[{id, name, by, cwd, command, pid, foreground, alive, exit_status, exit_signal, clients, cols, rows, created}]` |
| `kill` | `id`, `signal` (default 15) | sends the signal to the session's process group |
| `rm` | `id`, `force` | forgets an exited session; `force` SIGKILLs a live one first |
| `screen` | `id`, `format`: `plain` or `vt`, `scrollback` (bool, plain only) | `plain`: `text` (exactly rows lines), `styles`, `cursor {x,y,visible}`, `cols`, `rows`, `alternate`, `kitty_flags`, `mouse_tracking`, `bracketed_paste`, `app_cursor_keys`; with `scrollback`, also `history` (the rows above the screen, oldest first, one line each) and `history_rows`; `vt`: `vt` (base64 of the attach replay) |
| `send` | `id`, `data` (base64) | writes the bytes to the pty |
| `attach` | `id`, `cols`, `rows` | see below |
| `stop` | `force` | refuses while sessions are alive unless `force`. Then replies, SIGHUPs each live session's process group and its terminal's foreground group, gives them 2 s, SIGKILLs the groups still alive, waits at most 1 s more for the exits and every client's pending output, and exits; the requester's connection closes when the daemon exits |

`id` also accepts a session's name.

Each session keeps a scrollback bounded as Ghostty's default `scrollback-limit` (10 MB) and to
about 10,000 lines (libghostty prunes whole pages), so an attach replay stays quick. The
alternate screen has none (`history` is empty there; the primary screen's waits under it).

Compatibility: requests carry only fields, so a client and a daemon of different versions keep
working.

## Attach

1. Client sends `{"op":"attach","id":…,"cols":…,"rows":…}`.
2. Daemon replies `{"ok":true,"id":…}`, resizes the session to the client's size (pty
   `TIOCSWINSZ`, which sends SIGWINCH, and the vt terminal), then sends one `O` frame: the replay.
3. The replay is: `ESC c` (RIS); if the alternate screen is active, the primary screen and its
   scrollback; then libghostty-vt's VT formatter output for the active screen, its scrollback first, with every extra
   (palette, modes that differ from default — alternate screen, bracketed paste, mouse modes,
   cursor keys, cursor visibility, … — scrolling region, tabstops, pwd, modifyOtherKeys, cursor
   position, current style, hyperlink, kitty keyboard flags, charsets); then any escape sequence
   the program had only half written. The formatter leaves out the rows without text at the
   end of a screen, so when the contents come short of filling it, the replay scrolls them up by
   the missing rows (newlines at the bottom row) before the extras that follow the contents;
   scrollback rows never show on the client's screen.
4. Then live pty output as `O` frames; the client sends `I` (keystrokes) and `W` (resizes).
5. When the session's process exits the daemon sends `X` and closes. Attaching to an exited
   session sends the replay and `X` at once.

Several clients may attach to one session: all get the output, all may type, the latest resize
wins. A client that disconnects changes nothing for the session. While no client is attached the
daemon answers the program's terminal queries (device attributes, cursor position reports, mode
queries) itself; while one is attached, the client's terminal answers them.

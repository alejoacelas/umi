# CLI contract

`<cli>` is the product's command line tool (the name is the product's choice; see
`TEST_INTERFACE.md`). Agents and scripts depend on this surface, so it's fixed. Anything not listed
here is free. Output for humans is free-form unless stated. With `--json`, the listed fields must be
present. Extra fields are fine.

## General

- `--json` before the command, or anywhere before a `--` separator, prints JSON instead of human text.
- Exit codes:

  | Code | Meaning |
  |---|---|
  | 0 | success |
  | 1 | usage error, unknown selector, failed action |
  | 2 | `agent wait`: NEEDS_INPUT; `agent wait --report`: blocked |
  | 3 | `agent wait`: INTERRUPTED, FAILED, STOPPED, ERROR or CANCELLED; `agent wait --report`: failed |
  | 124 | a wait timed out |

- Errors go to stderr, prefixed `<cli>: `.
- Inside the app's panes, the pane, tab and window arguments default to the calling pane and its tab
  and window. Elsewhere they default to the focused ones.
- Selectors are described in SPEC L-4. `--pane`/`-p`, `--tab`/`-t` and `--window`/`-w` take selectors.
- Text arguments: words are joined with spaces. `-` alone means "read the text from stdin". Text after
  `--` is text, even if it starts with dashes (except for `agent start`, where it is harness
  arguments).
- No command ever waits for stdin unless given `-`. The exceptions are `send` (layout) with no text
  and a non-TTY stdin, and `edit` with no file.

## Layout

| Command | Notes |
|---|---|
| `ls` | JSON: `{"windows": [Window], "current_tab": id, "current_pane": id}` |
| `window new [--cwd D] [--cmd C] [--name N] [--worktree W [--base REF]] [--no-focus]` | prints the new pane's id; JSON has `pane`, `tab`, `window` |
| `window focus\|close [WINDOW]` | |
| `tab new [NAME] [--window W] [--pane P] [--cwd D] [--cmd C] [--name N] [--color C] [--index I] [--worktree W [--base REF]] [--no-focus]` | as `window new`; the tab opens right after the current tab, or last with `--no-focus`, or at `--index` (SPEC S-7) |
| `tab focus\|close\|equalize [TAB]` | |
| `tab back` | the tab visited before (again: the one before that), in any window; JSON `{"tab", "window", "index", "title"}`; fails when there is none |
| `tab next\|prev [--window W]` | the next or previous tab in sidebar order (wraps); JSON as `tab back` |
| `tab rename [TAB] NAME` | `""` clears |
| `tab color [TAB] COLOR` | red green yellow blue magenta cyan (Warp's six, from the theme's ANSI colors), purple pink orange teal graphite, none |
| `tab pin\|unpin [TAB]` | |
| `tab move [TAB] (--window W [--index I] \| --index I \| --up \| --down \| --new-window) [--no-focus]` | `--up`/`--down`: one place, within the tab's pin group and tab group (past a whole neighboring tab group); fails at the end of the group |
| `jump [back]` | the next session that needs the user (prints the pane, or the session id when no pane shows it), or back to where the user was; JSON `{"pane", "tab", "window", …}` or `{"session"}`; fails when nothing needs the user |
| `split [right\|down\|left\|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus] [--no-stack] [--worktree W]` | prints the new pane's id; R is the new pane's share of its row (or column), the others keep their proportions. In a tab already showing three places, the new pane joins the stack at P's place instead, on show (SPEC E-9, M-7); `--no-stack` splits anyway |
| `pane focus\|close\|info\|zoom [PANE]` | `info` JSON: Pane plus `tab`, `window` |
| `pane rename [PANE] NAME` | |
| `pane move [PANE] (--to PANE [--dir D] \| --tab T [--dir D] \| --window W [--dir D] \| --new-tab [--window W] \| --new-window) [--no-focus]` | the pane's program keeps running |
| `pane swap [PANE] TARGET` | |
| `pane resize [PANE] up\|down\|left\|right [AMOUNT]` | |
| `send [--pane P] [--enter\|-e] TEXT…` | no TEXT plus a piped stdin sends stdin |
| `keys [--pane P] KEY…` | enter esc tab backspace up down left right ctrl+c shift+tab … |
| `read [--pane P] [--scrollback] [--lines N]` | prints the text as the shell and programs printed it. With Umi's look (SPEC S-9 to S-12) a zsh prompt is two blank rows, the folder, and the command line; durations, lines and the folder box are drawn, not text |
| `wait [--pane P] (--pattern RE \| --idle SECS) [--timeout T]` | prints the matched text; 124 on timeout. The pattern matches program output, never the prompt (the folder line) or the typed command |
| `events [--filter PREFIX]… [--pane P]` | a filter keeps events whose name starts with PREFIX; JSON lines `{"event": name, "data": {…}}`, names like `pane.created`, `pane.closed`, `pane.moved`, `pane.focused`, `tab.created`, `tab.renamed`, `tab.selected`, `window.created` |
| `notify [--pane P] TITLE [BODY]` | |
| `sidebar [on\|off\|toggle\|status\|tabs\|files\|search] [--window W]` | shown or hidden per window (the given one, else the caller's, else the current); JSON: `{"visible": bool, "mode": "tabs"\|"files"\|"search", "width": points, "window": id}` |
| `sidebar width [N] [--window W]` | prints the window's sidebar width in points; with N sets it (clamped to 180–600) |
| `reopen [--list]` | reopens the last closed pane, tab or window (closed in the last 60 s); prints the pane's id (the window's for a window); JSON `{"kind": "pane"\|"tab"\|"window", "pane"?, "tab", "window"}`; exit 1 when there's nothing to reopen. `--list`: JSON `{"items": [{"kind", "closed_at", "expires_in", "panes": [id], "tab"?, "title"?, "tabs"?}]}`, most recent first |
| `screenshot [--window W] OUT.png` | an image of the window, terminal contents included |
| `worktree ls` | |
| `layout ls` | launch configurations (SPEC L-21) in `$XDG_CONFIG_HOME/umi/launch_configurations` (default `~/.config/umi/…`), by name; one per YAML document, so a file with several documents (separated by `---`) lists several; JSON `{"directory", "configs": [{"name", "file", "path", "document", "windows", "tabs"} or {"file", "path", "document", "error"}]}` (`document` counts from 0; a file that can't be read is listed once, with `error` and the line) |
| `layout save NAME [--replace]` | saves every window as `NAME.yaml` (unless NAME ends in `.yaml`/`.yml`), named after the file (`my_work` → "My Work"); prints the path; JSON `{"path", "name", "windows", "tabs"}`; fails when the file exists, unless `--replace` |
| `layout open NAME [--no-focus]` | NAME is a configuration's name or file name (case doesn't matter; a file holding several configurations fails and lists their names); opens each of its windows as a new window, the active one in front; prints the windows' ids; JSON `{"name", "windows": [id], "panes": [id]}` |

Objects in JSON:
- **Window**: `{"id", "index", "selected_tab": id, "tabs": [Tab]}`
- **Tab**: `{"id", "index", "title", "name"?, "selected": bool, "pinned": bool, "docs": bool, "color"?, "group"?: its tab group's name, "focused_pane": id, "panes": [Pane]}`
- **Pane**: `{"id", "cwd", "name"?, "focused": bool, "zoomed": bool, "agent"?: session id (a session
  shown in this pane, read-only or live), "file"?: path (a file pane), "shown": bool (false for a
  stack member that isn't on show), "stack"?: [id] (the panes sharing its place, in strip order),
  "frame"?: {"x", "y", "width", "height"} (points, top-left origin, in the window's terminal area),
  "url"?: the page's address and "title": its title (a web pane, SPEC E-12)}`.
  A tab's `panes` lists the panes on show, then stack members that aren't.

Events: `pane.created` and `tab.created` carry `"reopened": true` when `reopen` brought them back;
`sidebar.changed` is emitted when a window's sidebar is shown or hidden or its width changes.

Other commands:

| Command | Notes |
|---|---|
| `help [--json]` | `--json`: every command for programs: `{"cli", "product", "version": 1, "commands": [{"section", "usage", "summary", "actions": [{"title", "argv", "ask": [{"name", "prompt", "option"?, "choices"?, "optional", "kind", "words"?}]}]}]}` |
| `shortcuts [ls]` | JSON `{"shortcuts": [{"id", "title", "kind": "umi"\|"ghostty", "keys": [str], "display": [str], "default": [str], "changed": bool, "menu"?, "source"?}], "files": [str]}` |
| `shortcuts set ID KEYS`, `shortcuts clear ID`, `shortcuts reset [ID]` | ID from `shortcuts`: an Umi item (`tab.next`) or `ghostty:ACTION`; KEYS like `cmd+shift+]`; JSON of `set` has `notes`: the shortcuts the key was taken from |

Events also include `palette.opened` and `palette.ran`. Tabs change places only when moved (`tab.moved`) or
pinned; nothing reorders them on its own (SPEC S-7).

## Editor

| Command | Notes |
|---|---|
| `edit FILE\|URL… [--source\|--preview] [--tab T \| --pane P]` | opens each file in a pane of its own: the first to the right of the pane (the calling pane, or the tab's focused pane), each next one to the right of the one before; in a tab already showing three places it joins the stack at that pane's place instead, on show (SPEC E-9). A file already open shows where it is. Keyboard focus stays where it was, unless it was on the pane a file now covers: then the file's pane takes it. An http(s) URL whose origin is an `umi-web-origin` opens the same way in a web pane (SPEC E-12); other URLs are refused. JSON: `{"documents": [{"path", "pane", …}], "pages": [{"url", "pane"}], "tab", "window"}`. `open` is the same command |
| `editor ls [--tab T \| --pane P]` | JSON: `{"documents": [{"path", "pane", "mode": "preview"\|"source", "dirty": bool}], "active"}`: the files open in that tab's panes |
| `editor close [FILE] [--force]` | refuses dirty documents without `--force` |
| `editor mode [preview\|source] [FILE]` | toggles without a mode; FILE picks one of the tab's files (default: the focused one) |
| `editor default [--dry-run]` | make the app the default for Markdown, plain text, JSON, CSV, TSV and YAML; `--dry-run` prints the app bundle path |
| `comments [ls] FILE [--all]` | the file's open comments (E-11): id, line, the words each is on, its text, replies; `--all` adds resolved ones. JSON: `{"path", "comments": [{"id", "body", "by", "at", "status": "open"\|"resolved", "quote", "line", "detached", "anchor_deleted", "resolved_note"?, "replies": [{"id", "body", "by", "at"}]}]}`. Works on the file without the app |
| `comments add FILE --on TEXT [--nth N] TEXT… [--by NAME]` | comment on the first (or Nth) occurrence of TEXT outside code and other comments; prints `added ID` (JSON `{"id", "action", "path"}`) |
| `comments reply FILE ID TEXT… [--by NAME]` | reply to a thread (`-` reads stdin); `--by` defaults to `AI` |
| `comments edit FILE ID TEXT…` / `comments resolve FILE ID [--note TEXT]` / `comments reopen FILE ID` / `comments delete FILE ID` | change, resolve, reopen or delete (a thread goes with its replies and its markup; its words stay) |
| `comments wait FILE [--timeout SECS]` | block until the user presses Done on FILE's comments in the editor, then print its open comments as `comments ls` does; exits 124 on timeout. Needs the app |

## Updates

| Command | Notes |
|---|---|
| `update --check` | prints the installed and the newest version; JSON `{"installed", "latest", "update_available": bool}` |
| `update [--now [--force]]` | checks at once, then downloads and verifies the newest version. It installs at the next quiet moment (SPEC I-4; with `auto-update = check` or `download`, when the app quits), or with `--now` installs it and relaunches the app at once; `--now` refuses while managed-agent turns run unless `--force` |
| `update --status` | what is known without checking, and what a staged update waits for. JSON: `installed`, `latest`, `update_available`, `state` (`up_to_date`, `available`, `downloading`, `ready`, `installing`, `asking`, `later`, `skipped`, `agreed`, `held_back`, `failed`, `unknown`), `mode` (`install`, `download`, `check`, `off`), `ready` and `installs` (`quiet` or `quit`) for a staged update, `countdown` (seconds) while the notice counts down, `not_now_until`, `held_back` (why a newer version doesn't install by itself), `rolled_back_from`, `failed_install`, `rollback` (the version `--rollback` goes back to), `quiet` `{"quiet": bool, "waiting_for": [{"kind": "pane"\|"session"\|"editor"\|"dialog"\|"input", "reason", "pane"?, "tab"?, "session"?, "name"?}], "idle_seconds"}`; without `--json`, a line per thing it waits for |
| `update --rollback [--force]` | installs the version installed before this one from its kept, verified zip and relaunches; the version gone back from doesn't install by itself again (`update` installs it). Fails when no earlier version is kept |
| `update --later \| --skip` | answers the update question (`auto-update = check`): ask again after a day \| not about this version |

## Agents

Sessions are Claude Code or Codex conversations (SPEC, AG). The product starts and controls them
headless; a session can be shown in a pane read-only, taken over live there, and handed back.

| Command | Notes |
|---|---|
| `agent start claude\|codex PROMPT… [--name N] [--cwd D] [--worktree W [--base REF]] [--model M] [--effort E] [--full-access] [--permission-mode M] [--profile P] [--env K=V]… [PLACEMENT] [--wait [--timeout S]] [-- HARNESS ARGS]` | prints the session id (and a one-line hint on stderr); JSON `{"session": Session, "message": Message}`; with a PLACEMENT the session also gets a pane (AG-2); `--wait` behaves like `agent wait` |
| PLACEMENT | `--tab [--window W]`, `--split [DIR] [--pane P]`, `--new-window`, `--focus` (switch to it; also alone: a new tab, switched to) |
| `claude\|codex [PROMPT…] [agent start options]` | a session for the user: `agent start … --tab --focus` unless another placement is given |
| `agent send SESSION TEXT… [--interrupt] [--wait [--timeout S]]` | prints the message id; JSON `{"message": Message, "session": Session}` |
| `agent wait SESSION [--message ID] [--timeout S]` | prints STATUS, then the reply (or what it waits on); JSON `{"status", "reply"?, "message"?: Message, "session": Session, "requests"?: [Request], "error"?}` |
| `agent wait SESSION --report [--message ID] [--timeout S]` | waits for the worker's report; JSON `{"report": Report, "session": Session}` |
| `agent read SESSION [--message ID]` | the reply; JSON `{"reply", "message"?}` |
| `agent read SESSION --transcript [--last N]` | JSON `{"items": [Item]}` |
| `agent ls [--parent S]` | JSON `{"sessions": [Session]}` |
| `agent info SESSION` | JSON Session |
| `agent open SESSION [PLACEMENT] [--live]` | show it in a pane (default: a new tab, not focused); `--live`: take it over at once; JSON includes `pane` |
| `agent hide SESSION` | remove it from its pane; it keeps running until it finishes (AG-8) |
| `agent attach SESSION` | run the session's own interface in this terminal (what Take Over runs in the pane) |
| `agent interrupt\|stop SESSION` | |
| `agent rename SESSION NAME`, `agent rm SESSION [--force]` | |
| `agent report done\|blocked\|failed SUMMARY… [--session S]` | inside a session S defaults to `self`; JSON `{"report": Report}` |
| `agent watch SESSION --notify OTHER [--message ID] [--text T]` | |
| `agent approve SESSION [REQUEST] [--always] [--message TEXT]`, `agent deny SESSION [REQUEST] [--message TEXT]`, `agent answer SESSION [TEXT…] [--answer N=TEXT]…` | approvals and questions (sessions without full access) |
| `agent plugins [status\|install [--force]\|remove]` | Umi's plugins in Claude Code and Codex (AG-18); JSON per agent `{"installed", "version"?, "bundled_version"?, "current", "enabled"? (Claude), "hooks_trusted"? (Codex), "agent_installed", "steps"? (install)}`; current means this app's version, from this copy of the app, enabled and (Codex) its hooks trusted; `--force` reinstalls even when current |
| `agent hook EVENT` | used by Umi's plugins: reads the agent's hook input on stdin; prints nothing |
| `doctor` | exit 0 when everything needed is present |

SESSION is a session id or unique prefix, a name, the agent's own session or thread id, or `self`
(inside a session).

- **Session**: `{"id", "name", "kind": "claude"|"codex", "status": starting|working|idle|needs_input|stopped|error,
  "activity", "title", "cwd", "location": "background"|"pane"|"live", "running": bool (Umi's headless process for
  it runs), "pane"?: pane id, "harness_id"?, "parent"?,
  "requests": [Request], "last_message"?: Message, "waiting"?: [Message] (messages not delivered yet),
  "waiting_reason"?, "error"?, "report"?: Report, "background_tasks"?: int, "startup"?: Startup, "origin": "started"|"typed"}`
- **Report**: `{"verdict": "done"|"blocked"|"failed", "summary", "at"}` (ISO 8601 time)
- **Startup**: `{"at", "model"?, "mcp_servers"?: [{"name", "status"}], "skills"?: [str], "plugins"?: [str],
  "agents"?: [str], "flags": [str]}`. `flags` lists what failed or needs the user, in words.
- **Message**: `{"id", "text", "state": queued|sent|delivered|done|interrupted|failed|error|stopped|cancelled, "reply"?, "error"?}`
- **Request**: `{"id", "kind": "approval"|"question", "title", "detail", "questions": [{"id",
  "question", "options": [str]}], "details": {"url"?, "permissions"?, "schema"?}}`
- **Item**: `{"id", "kind": "user"|"assistant"|"tool"|"request"|"notice"|"error", "text", "message"?:
  message id (user items), "tool"?, "detail"?, "output"?, "state"?}`

Exit codes for `agent wait`: `DONE` 0; `NEEDS_INPUT` 2; `INTERRUPTED`, `FAILED`, `STOPPED`, `ERROR`,
`CANCELLED` 3; `TIMEOUT` 124. With `--report`: done 0, blocked 2, failed 3, timeout 124.

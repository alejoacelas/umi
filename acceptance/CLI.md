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
| `tab new [NAME] [--window W] [--pane P] [--cwd D] [--cmd C] [--name N] [--color C] [--index I] [--worktree W [--base REF]] [--no-focus]` | as `window new` |
| `tab focus\|close\|equalize [TAB]` | |
| `tab back` | the tab visited before (again: the one before that), in any window; JSON `{"tab", "window", "index", "title"}`; fails when there is none |
| `tab next\|prev [--window W]` | the next or previous tab in sidebar order (wraps); JSON as `tab back` |
| `tab rename [TAB] NAME` | `""` clears |
| `tab color [TAB] COLOR` | blue purple pink red orange yellow green teal graphite none |
| `tab pin\|unpin [TAB]` | |
| `tab move [TAB] (--window W [--index I] \| --index I \| --up \| --down \| --new-window) [--no-focus]` | `--up`/`--down`: one place, within the tab's pin group; fails at the end of the group |
| `jump [back]` | the next session that needs the user (prints the pane, or the session id when no pane shows it), or back to where the user was; JSON `{"pane", "tab", "window", …}` or `{"session"}`; fails when nothing needs the user |
| `split [right\|down\|left\|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus] [--worktree W]` | prints the new pane's id; R is the new pane's share of its row (or column), the others keep their proportions |
| `pane focus\|close\|info\|zoom [PANE]` | `info` JSON: Pane plus `tab`, `window` |
| `pane rename [PANE] NAME` | |
| `pane move [PANE] (--to PANE [--dir D] \| --tab T [--dir D] \| --window W [--dir D] \| --new-tab [--window W] \| --new-window) [--no-focus]` | the pane's program keeps running |
| `pane swap [PANE] TARGET` | |
| `pane resize [PANE] up\|down\|left\|right [AMOUNT]` | |
| `send [--pane P] [--enter\|-e] TEXT…` | no TEXT plus a piped stdin sends stdin |
| `keys [--pane P] KEY…` | enter esc tab backspace up down left right ctrl+c shift+tab … |
| `read [--pane P] [--scrollback] [--lines N]` | prints the text as the shell and programs printed it. With Tern's look (SPEC S-9 to S-12) a zsh prompt is two blank rows, the folder, and the command line; durations, lines and the folder box are drawn, not text |
| `wait [--pane P] (--pattern RE \| --idle SECS) [--timeout T]` | prints the matched text; 124 on timeout. The pattern matches program output, never the prompt (the folder line) or the typed command |
| `events [--filter PREFIX]… [--pane P]` | a filter keeps events whose name starts with PREFIX; JSON lines `{"event": name, "data": {…}}`, names like `pane.created`, `pane.closed`, `pane.moved`, `pane.focused`, `tab.created`, `tab.renamed`, `tab.selected`, `window.created` |
| `notify [--pane P] TITLE [BODY]` | |
| `sidebar [on\|off\|toggle\|status\|tabs\|files] [--window W]` | JSON: `{"visible": bool, "mode": "tabs"\|"files", "width": points, "window": id}` |
| `sidebar width [N] [--window W]` | prints the window's sidebar width in points; with N sets it (clamped to 180–600) |
| `reopen [--list]` | reopens the last closed pane, tab or window (closed in the last 60 s); prints the pane's id (the window's for a window); JSON `{"kind": "pane"\|"tab"\|"window", "pane"?, "tab", "window"}`; exit 1 when there's nothing to reopen. `--list`: JSON `{"items": [{"kind", "closed_at", "expires_in", "panes": [id], "tab"?, "title"?, "tabs"?}]}`, most recent first |
| `screenshot [--window W] OUT.png` | an image of the window, terminal contents included |
| `worktree ls` | |

Objects in JSON:
- **Window**: `{"id", "index", "selected_tab": id, "tabs": [Tab]}`
- **Tab**: `{"id", "index", "title", "name"?, "selected": bool, "pinned": bool, "color"?, "focused_pane": id, "panes": [Pane]}`
- **Pane**: `{"id", "cwd", "name"?, "focused": bool, "zoomed": bool, "agent"?: session id (a session
  shown in this pane, read-only or live), "frame"?: {"x", "y", "width", "height"} (points, top-left
  origin, in the window's terminal area)}`

Events: `pane.created` and `tab.created` carry `"reopened": true` when `reopen` brought them back;
`sidebar.changed` is emitted when a window's sidebar width changes.

Other commands:

| Command | Notes |
|---|---|
| `help [--json]` | `--json`: every command for programs: `{"cli", "product", "version": 1, "commands": [{"section", "usage", "summary", "actions": [{"title", "argv", "ask": [{"name", "prompt", "option"?, "choices"?, "optional", "kind", "words"?}]}]}]}` |
| `shortcuts [ls]` | JSON `{"shortcuts": [{"id", "title", "kind": "tern"\|"ghostty", "keys": [str], "display": [str], "default": [str], "changed": bool, "menu"?, "source"?}], "files": [str]}` |
| `shortcuts set ID KEYS`, `shortcuts clear ID`, `shortcuts reset [ID]` | ID from `shortcuts`: a Tern item (`tab.next`) or `ghostty:ACTION`; KEYS like `cmd+shift+]`; JSON of `set` has `notes`: the shortcuts the key was taken from |

Events also include `tab.reordered` `{"window", "tabs": [ids]}` when the sidebar order (SPEC S-7) changes,
`palette.opened` and `palette.ran`.

## Editor

| Command | Notes |
|---|---|
| `edit FILE… [--source\|--preview] [--tab T \| --pane P]` | opens in that tab's editor panel |
| `editor ls [--tab T \| --pane P]` | JSON: `{"documents": [{"path", "mode": "preview"\|"source", "dirty": bool}]}` |
| `editor close [FILE] [--force]` | refuses dirty documents without `--force` |
| `editor mode [preview\|source]` | toggles without an argument |
| `editor default [--dry-run]` | make the app the default for `.md`; `--dry-run` prints the app bundle path |

## Updates

| Command | Notes |
|---|---|
| `update --check` | prints the installed and the newest version; JSON `{"installed", "latest", "update_available": bool}` |
| `update [--now]` | downloads and verifies the newest version. It installs when the app quits, or with `--now` installs it and relaunches the app at once |

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
| `agent plugins [status\|install [--force]\|remove]` | Tern's plugins in Claude Code and Codex (AG-18); JSON per agent `{"installed", "version"?, "bundled_version"?, "current", "enabled"? (Claude), "hooks_trusted"? (Codex), "agent_installed", "steps"? (install)}`; current means this app's version, from this copy of the app, enabled and (Codex) its hooks trusted; `--force` reinstalls even when current |
| `agent hook EVENT` | used by Tern's plugins: reads the agent's hook input on stdin; prints nothing |
| `doctor` | exit 0 when everything needed is present |

SESSION is a session id or unique prefix, a name, the agent's own session or thread id, or `self`
(inside a session).

- **Session**: `{"id", "name", "kind": "claude"|"codex", "status": starting|working|idle|needs_input|stopped|error,
  "activity", "title", "cwd", "location": "background"|"pane"|"live", "running": bool (Tern's headless process for
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

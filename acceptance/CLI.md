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
  | 3 | `agent wait`: INTERRUPTED, FAILED, EXITED, ERROR or CANCELLED; `agent wait --report`: failed |
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
| `tab rename [TAB] NAME` | `""` clears |
| `tab color [TAB] COLOR` | blue purple pink red orange yellow green teal graphite none |
| `tab pin\|unpin [TAB]` | |
| `tab move [TAB] (--window W [--index I] \| --index I \| --new-window) [--no-focus]` | |
| `split [right\|down\|left\|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus] [--worktree W]` | prints the new pane's id |
| `pane focus\|close\|info\|zoom [PANE]` | `info` JSON: Pane plus `tab`, `window` |
| `pane rename [PANE] NAME` | |
| `pane move [PANE] (--to PANE [--dir D] \| --tab T [--dir D] \| --window W [--dir D] \| --new-tab [--window W] \| --new-window) [--no-focus]` | the pane's program keeps running |
| `pane swap [PANE] TARGET` | |
| `pane resize [PANE] up\|down\|left\|right [AMOUNT]` | |
| `send [--pane P] [--enter\|-e] TEXT…` | no TEXT plus a piped stdin sends stdin |
| `keys [--pane P] KEY…` | enter esc tab backspace up down left right ctrl+c shift+tab … |
| `read [--pane P] [--scrollback] [--lines N]` | prints text |
| `wait [--pane P] (--pattern RE \| --idle SECS) [--timeout T]` | prints the matched text; 124 on timeout |
| `events [--filter PREFIX]… [--pane P]` | a filter keeps events whose name starts with PREFIX; JSON lines `{"event": name, "data": {…}}`, names like `pane.created`, `pane.closed`, `pane.moved`, `pane.focused`, `tab.created`, `tab.renamed`, `tab.selected`, `window.created` |
| `notify [--pane P] TITLE [BODY]` | |
| `sidebar [on\|off\|toggle\|status\|tabs\|files]` | JSON: `{"visible": bool, "mode": "tabs"\|"files"}` |
| `screenshot [--window W] OUT.png` | an image of the window, terminal contents included |
| `worktree ls` | |

Objects in JSON:
- **Window**: `{"id", "index", "selected_tab": id, "tabs": [Tab]}`
- **Tab**: `{"id", "index", "title", "name"?, "selected": bool, "pinned": bool, "color"?, "focused_pane": id, "panes": [Pane]}`
- **Pane**: `{"id", "cwd", "name"?, "focused": bool, "zoomed": bool, "agent"?: session id (a managed
  agent shown in this pane), "interactive_agent"?: {"kind": "claude"|"codex", "running": bool}}`

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

### Interactive (plain TUI, not controlled)
`claude [ARGS…]` and `codex [ARGS…]` pass every argument to the agent. To set the product's own
options, put them before `--`: `claude [--tab | --split [DIR] | --window] [--cwd D] [--worktree W]
[--name N] [--pane P] [--no-focus] -- [ARGS…]`. JSON: `{"pane": id, "command": the typed command line}`.

### Managed
| Command | Notes |
|---|---|
| `agent start claude\|codex [PROMPT…] [--name N] [--cwd D] [--worktree W [--base REF]] [--model M] [--effort E] [--full-access] [--permission-mode M] [--profile P] [--env K=V]… [PLACEMENT] [--background] [--wait [--timeout S]] [-- HARNESS ARGS]` | prints the session id; JSON `{"session": Session, "message"?: Message}`; with `--wait`, behaves like `agent wait` |
| PLACEMENT | `--tab [--window W]` (default), `--split [DIR] [--pane P]`, `--new-window`, `--focus`; `--background` shows nothing |
| `agent send SESSION TEXT… [--interrupt [--drop-queued]] [--wait [--timeout S]]` | prints the message id; JSON `{"message": Message, "session": Session}`. `--interrupt`: see SPEC MA-25 |
| `agent wait SESSION [--message ID] [--timeout S]` | prints STATUS, then the reply (or the pending requests); JSON `{"status", "reply"?, "message"?: Message, "session": Session, "requests"?: [Request], "error"?}` |
| `agent wait SESSION --report [--message ID] [--timeout S]` | waits for the worker's report (SPEC MA-26); prints the verdict and summary, then what the harness says; JSON `{"report": Report, "session": Session}` |
| `agent report done\|blocked\|failed [SUMMARY…] [--session S]` | inside a managed session, S defaults to `self`; JSON `{"report": Report}` |
| `agent read SESSION [--message ID]` | prints the reply; JSON `{"reply", "message"?}` |
| `agent read SESSION --transcript [--last N]` | JSON `{"items": [Item]}` |
| `agent ls [--live]` | JSON `{"sessions": [Session]}` |
| `agent info SESSION` | JSON Session |
| `agent interrupt\|stop SESSION` | |
| `agent resume SESSION [PROMPT…]` | |
| `agent approve SESSION [REQUEST] [--always] [--message TEXT]` | `--always`: this kind of action, for this session |
| `agent deny SESSION [REQUEST] [--message TEXT]` | |
| `agent answer SESSION [TEXT…] [--answer N=TEXT]…` | `N` is a question number or id |
| `agent watch SESSION --notify OTHER [--message ID] [--text T]` | |
| `agent open SESSION [PLACEMENT]` | JSON includes `pane` |
| `agent rename SESSION NAME`, `agent rm SESSION [--force]` | |
| `doctor` | exit 0 when everything needed is present |

SESSION is a session id or unique prefix, a name, the harness's session or thread id, or `self`
(inside a managed agent).

- **Session**: `{"id", "name", "kind", "status": starting|working|idle|needs_input|exited|error,
  "activity", "cwd", "live": bool, "harness_id"?, "parent"?, "requests": [Request],
  "last_message"?: Message, "error"?, "report"?: Report, "background_tasks"?: int, "startup"?:
  Startup}`
- **Report**: `{"verdict": "done"|"blocked"|"failed", "summary", "at"}` (ISO 8601 time)
- **Startup**: `{"at", "model"?, "mcp_servers"?: [{"name", "status"}], "skills"?: [str], "plugins"?: [str],
  "agents"?: [str], "flags": [str]}`. `flags` lists what failed or needs the user, in words.
- **Message**: `{"id", "text", "reply"?}`
- **Request**: `{"id", "kind": "approval"|"question", "title", "detail", "questions": [{"id",
  "question", "options": [str]}], "details": {"url"?, "permissions"?, "schema"?}}`
- **Item**: `{"id", "kind": "user"|"assistant"|"tool"|"request"|"notice"|"error", "text", "message"?:
  message id (user items), "tool"?, "detail"?, "output"?, "state"?}`

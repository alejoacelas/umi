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
| `agent plugins [status\|install\|remove]` | Tern's plugins in Claude Code and Codex (AG-18) |
| `agent hook EVENT` | used by Tern's plugins: reads the agent's hook input on stdin; prints nothing |
| `doctor` | exit 0 when everything needed is present |

SESSION is a session id or unique prefix, a name, the agent's own session or thread id, or `self`
(inside a session).

- **Session**: `{"id", "name", "kind": "claude"|"codex", "status": starting|working|idle|needs_input|stopped|error,
  "activity", "title", "cwd", "location": "background"|"pane"|"live", "pane"?: pane id, "harness_id"?, "parent"?,
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

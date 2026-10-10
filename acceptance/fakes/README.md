# Fake coding-agent harnesses

| file | imitates |
|---|---|
| `fake_claude.py` | `claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages --permission-prompt-tool stdio` (Claude Code 2.1.289; hooks, transcript and `cancel_queued` from 2.1.296), and without `-p` the interactive `claude` (a line-oriented [TUI](#tui-mode-live-sessions)) |
| `fake_codex.py` | `codex app-server --listen stdio://` (codex-cli 0.160.0, JSON-RPC without the `"jsonrpc"` field), `codex app-server --listen unix://PATH` ([WebSocket, several clients](#codex-app-server-on-a-unix-socket-x16), 0.162.1), and the interactive `codex` / `codex resume` ([TUI](#tui-mode-live-sessions)) |
| `fake_common.py` | shared by both: plugin hooks, the one-process-per-session check, the terminal line editor. Keep it next to the two fakes. |
| `test_fakes.py` | self-tests: `python3 test_fakes.py [-v] [name-filter]` (55 tests, about 95 s) |

All are Python 3.9 stdlib-only scripts. The frame shapes and orderings come from real runs recorded in
`../reference/agent-logs/` and summarised in `../reference/PROTOCOLS.md`. This README supersedes the "Fakes"
section at the end of PROTOCOLS.md: thinking and rate-limit frames now exist under chaos, `task_started` is
now delayed, and the periodic queue notification is now emulated under chaos. The 2026-10-08 recordings
(C11wake, C12missing, C12othercwd, C13projectmcp, X14missing) added `WAKE`, `FAKE_MCP` and the missing-session
checks. The 2026-10-10 recordings (Claude Code 2.1.296 and codex-cli 0.162.1, script
`reference/agent-probes/probe_phase3.py`, logs in `reference/logs/`: `X16*`, `C14*`, `C15cancelq`) added
[live sessions](#live-sessions-tui-hooks-transcripts): the unix-socket app server, both TUIs, hooks, the
Claude transcript, the [violations log](#one-process-per-session-violationslog) and
[`cancel_queued`](#claude-interrupt-with-cancel_queued-c15cancelq).

The design rule: a fake may do anything the real harness was observed to do, or can clearly do, and nothing
it cannot. When a behavior was not probed, it is either left out or listed below as inferred.

## Environment variables

| variable | fake | effect |
|---|---|---|
| `FAKE_AGENT_DIR` | both | Root for all state. Defaults to `<tmp>/fake-agent`. Holds `claude/<session>.json` plus `<session>.pid` (the live process on it), `claude/tasks/<session>/<task>.output` (WAKE), `claude-config/projects/<slug>/<session>.jsonl` ([transcripts](#claude-transcript)), `codex/threads/<thread>.json` plus `<thread>.lock` (owner pid), `receipts.jsonl`, `self_turns.jsonl`, `violations.log` and `stubborn.pid`. |
| `FAKE_CLAUDE_PLUGIN_DIRS=<dir>:<dir>` | claude | Plugin directories treated as installed plugins, in addition to `--plugin-dir`. Their `hooks/hooks.json` [hooks](#hooks) run in both modes. |
| `FAKE_CODEX_PLUGIN_DIRS=<dir>:<dir>` | codex | Plugin directories treated as installed plugins (Codex has no `--plugin-dir`). Their hooks run wherever the engine runs: the app server (stdio or socket) or the local TUI. |
| `CLAUDE_CONFIG_DIR` | claude | Where the [transcript](#claude-transcript) goes (`<dir>/projects/...`). Unset: `$FAKE_AGENT_DIR/claude-config`. A value that resolves to the real `~/.claude` is ignored, so the fake never writes there. |
| `FAKE_CLAUDE_IDLE_SECS=<secs>` | claude | TUI only: how long the session sits idle after a turn before the `Notification` hook `idle_prompt` fires (once per idle period). Default 60, the real threshold. |
| `FAKE_CHAOS=<int>` | both | Turns on chaos mode, seeded by the integer. Unset or empty turns it off. See [Chaos mode](#chaos-mode). |
| `FAKE_SLOW_START=<secs>` | both | Sleeps before reading stdin, so the `initialize` answer (and anything else) comes late. |
| `FAKE_INPUT_DELAY=<secs>` | codex | Gap between `turn/started` and the first `userMessage` item. The real gap is 0.04 to 2.8 s (X1, X3, X4). An interrupt inside it drops the input (see [Early interrupt](#codex-early-interrupt)). |
| `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` (or `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`) | claude | Emits `system/session_state_changed` frames, as the real CLI does only when this is set. |
| `FAKE_MCP=<name:status,...>` | both | MCP servers and their startup status, comma-separated, status one of `connected`, `pending`, `failed`, `needs-auth` (for example `github:connected,jira:needs-auth`). Claude lists them in every `system/init`; Codex sends `mcpServer/startupStatus/updated` notifications. See [MCP servers](#mcp-servers-fake_mcp). Unset or empty means no servers, as before. A malformed entry makes the fake exit 2 at startup with a `bad FAKE_MCP entry` line on stderr. |
| `FAKE_WAKE_TURN_SECS=<secs>` | claude | How long a self-started `WAKE` turn spends between its `system/init` and its reply. Default 1.5: in C11wake the real one took 1.55 s from `task_notification` to `result`. Interruptible. |

Command-line handling:
* Claude accepts `--session-id`, `--resume` (`-r`), `--fork-session`, `--model`, `--permission-mode`, `--effort`,
  `--dangerously-skip-permissions`, `--plugin-dir DIR` (repeatable) and `-n/--name NAME` in both modes, and
  `--version`. `-p`/`--print` selects the stream-json mode; without it the fake is the [TUI](#claude-tui), and
  the words left over (not flags or flag values) are its first prompt. Every other flag is ignored, and the
  startup errors match C4 (the TUI prints the message on stderr and exits 1, without a JSON frame).
* Codex: the first word that isn't a flag picks the mode. `app-server` is the server: `--listen stdio://`
  (the default) or `--listen unix://PATH`, given at most once (a second `--listen` exits 2 like the real
  CLI's argument parser; any other URL exits 2). `resume [THREAD] [PROMPT]` is the [TUI](#codex-tui) on a
  thread, and anything else (`[OPTIONS] [PROMPT]`) the TUI on a new thread. `-c key=value` /
  `--config key=value` sets `model`, `model_reasoning_effort`, `approval_policy` and `sandbox_mode` as
  defaults for `thread/start` in every mode. The TUI also takes `-m/--model`, `-a/--ask-for-approval`,
  `-s/--sandbox`, `-C/--cd`, `--dangerously-bypass-approvals-and-sandbox` (`--yolo`), `--remote unix://PATH`
  and `--last`. `--version` prints `codex-cli <version>`. Everything else is ignored.

## Triggers

A trigger is a substring of the user message text. Everything after `RUN ` is the command, and the fake does
not scan it for triggers. That lets a test pass `SLEEP`, `CRASH` and so on to a nested agent through `RUN`.
Likewise everything after `WAKE n` (up to a `RUN `) is the wake text and is not scanned for triggers.

| trigger | claude | codex | behavior |
|---|---|---|---|
| default | yes | yes | reply `ok: <text>` |
| `ECHO` | yes | yes | reply = the user text |
| `RECALL` | yes | yes | reply `history: <earlier user texts joined by " \| ">`, which proves a resume kept context |
| `PRINTENV NAME` | yes | yes | reply = the value of `$NAME`, or `<unset>` |
| `STATE` | yes | yes | reply = one line of JSON describing what the harness was told (see [STATE](#state)) |
| `SLEEP n` | yes | yes | a Bash / `commandExecution` `sleep n` lasting n seconds. Interruptible. Codex puts a commentary agentMessage before it. |
| `RUN <cmd>` | yes | yes | runs `/bin/sh -c <cmd>` as a real tool call: Claude in its cwd, Codex in the thread cwd, both with the fake's environment. Stdout and stderr are combined. The reply is `exit=<code>\n<output>`. Interruptible: an interrupt or a SIGTERM to the fake kills the command's process group. |
| `HUGE n` | yes | yes | a tool call whose output is n MB (fractions allowed). Claude puts it in the `tool_result`, so the frame is about 2n MB because `tool_use_result.stdout` repeats it. Codex sends 1 MB `outputDelta` chunks plus the full `aggregatedOutput`. Reply `huge: n MB`. |
| `ASK_PERMISSION[:name]` | yes | - | Bash `touch <name>` (default `fake_permission.txt`, name chars `[A-Za-z0-9_.-]`) behind a `can_use_tool` control_request with the real Bash suggestions. Reply `permission allowed` or `permission denied: <message>`. An allow answer's `updatedPermissions` is applied (see [Allow for the rest of the session](#allow-for-the-rest-of-the-session)). A skipped prompt replies `permission allowed (remembered)` or `permission allowed (acceptEdits)`. |
| `ASK_QUESTIONS` | yes | yes | Claude: an AskUserQuestion `can_use_tool`. Codex: `item/tool/requestUserInput`. Reply `answers: ...`. |
| `ASK_APPROVAL[:name]` | - | yes | commandExecution `touch <name>` (default `fake_approval.txt`) needing `item/commandExecution/requestApproval` when approvalPolicy is not `never`. Reply `approval accepted`, `approval declined` or `approval not needed`. `cancel` interrupts the turn (X12). `acceptForSession` and `acceptWithExecpolicyAmendment` are remembered (see [Allow for the rest of the session](#allow-for-the-rest-of-the-session)). A skipped approval replies `approval accepted (remembered)`. |
| `ASK_PERMS` / `ASK_URL` / `ASK_FORM` | - | yes | `item/permissions/requestApproval` or an MCP elicitation in url or form mode. Reply `result: <client JSON>`. |
| `FAIL` (or a model containing `no-such-model`) | yes | yes | an API-error turn. Codex: `systemError` status, an `error` notification, and `turn/completed` with status `failed` (X7). Claude: see [Claude FAIL](#claude-fail-inferred). |
| `CRASH` | yes | yes | `exit(1)` mid-turn, after the message was delivered |
| `GARBAGE` | yes | yes | writes 4 non-JSON lines and 2 blank lines on stdout before the final answer, and the same again after the turn ends |
| `STDERR_SPAM` | yes | yes | writes about 2 MB to stderr during the turn. It blocks if the product does not drain stderr. |
| `HANG` | yes | yes | right after the message is delivered (Claude replay / Codex `userMessage` item), the fake stops writing anything and reads and ignores stdin, including EOF and malformed lines. It stays alive until killed. SIGTERM still kills it unless `IGNORE_TERM` was set. |
| `EXIT_CLEAN` | yes | yes | once the reply is done and the harness is idle, it exits 0 on its own while stdin is still open. Codex releases its thread locks first. |
| `IGNORE_TERM` | yes | yes | ignores SIGTERM from then on. Only SIGKILL works. |
| `SPAWN_STUBBORN` | yes | yes | starts a child in its own session that ignores SIGTERM and sleeps 300 s. Its pid goes to `$FAKE_AGENT_DIR/stubborn.pid`. |
| `WAKE n [text]` | yes | reply only | Claude: a Bash `sleep n` with `run_in_background: true` and reply `started`. n seconds later the fake starts a turn by itself whose reply is `woke: <text>` (or `woke`). See [Turns the harness starts by itself](#turns-the-harness-starts-by-itself-wake). Codex replies `wake: not supported by codex`: the real Codex was checked and doesn't start turns by itself (X15wake). |
| `BACKGROUND n` | - | yes | Codex: a `commandExecution` `sleep n` run as a background terminal. The reply is `started` and the turn completes while the item is still open; n seconds later `item/completed` arrives for it, with the finished turn's id and no new turn (X15wake). |

A message sent to Claude while a turn runs gets `command_lifecycle queued`. It is injected at the next tool
boundary (after SLEEP, RUN, HUGE, WAKE or ASK_*), or it runs as the next turn. Codex `turn/start` during an active
turn steers into it, and the input is delivered at the next tool boundary or after the final answer.

### Claude: interrupt with `cancel_queued` (C15cancelq)

`system/init` carries the 2.1.296 `capabilities` list (`interrupt_receipt_v1`, `interrupt_cancel_queued_v1`,
`interrupt_send_now_v1`, `msg_lifecycle_v1`, ...). `{"subtype":"interrupt","cancel_queued":true}` drops every
message still queued: each gets `command_lifecycle cancelled` at once, then the answer
`{"still_queued": [], "cancelled": [<their uuids>]}` (written when the running turn stops, as for a plain
interrupt), then the usual interrupted-turn frames. A cancelled message never runs, gets no `started` and writes
no receipt. With no turn running the answer comes at once (`"cancelled": [...]`, possibly empty). A plain
interrupt keeps the C2 behaviour: `still_queued` lists the queued messages and they run next as their own turn.
The self-test replays C15cancelq and matches it frame for frame. `send_now` (`interrupt_send_now_v1`) is not
implemented.

### STATE

The reply is exactly one line of JSON:
`{"harness", "session", "model", "effort", "full_access", "permission_mode", "cwd", "argv"}`.

* `model`: the model string as given, or `null` if the harness was never told one. Claude: `--model` or
  `set_model`, without resolving aliases. Codex: `thread/start` / `thread/resume` / `turn/start` `model`, or
  `-c model=`.
* `effort`: Claude `--effort`. Codex: `effort` from `thread/start` / `turn/start`, or
  `config.model_reasoning_effort`, or `-c model_reasoning_effort=`. `null` if none.
* `full_access`: Claude, when the permission mode is `bypassPermissions` (which includes
  `--dangerously-skip-permissions`). Codex, when `approvalPolicy == "never"` and the sandbox is
  `danger-full-access` / `{"type":"dangerFullAccess"}`.
* `permission_mode`: Claude's permission mode, or Codex's approval policy.
* `cwd`: Claude's process cwd, or the Codex thread cwd.
* `argv`: `sys.argv[1:]`.

### Claude FAIL (inferred)

No real Claude log shows an API error, so this shape is inferred, not probed. The fake emits:
1. an `assistant` frame with `message.model: "<synthetic>"` and the text
   `API Error: 404 {"type":"error","error":{"type":"not_found_error","message":"model: <model>"},...}`;
2. a `result` with `subtype:"success"`, `is_error:true`, `api_error_status:404`, `stop_reason:"stop_sequence"`
   and `result` set to that text;
3. lifecycle `completed`.

The basis is the result schema itself: real success results always carry `api_error_status` (null in every
log), which only makes sense if API errors arrive in the success shape. Like any error result, it makes the
exit code 1 if it is the last result (PROTOCOLS C1).

## Turns the harness starts by itself (WAKE)

Claude Code starts a turn on its own when a background command finishes. This was recorded on 2026-10-08
(`reference/agent-logs/C11wake.jsonl`, script `reference/agent-probes/probe_phase2.py C11wake`): haiku ran
`sleep 8; echo done-xyz` with `run_in_background: true`, replied `started`, and 8 s later the CLI ran a
second turn although nothing was sent. `WAKE n [text]` reproduces both turns.

The turn that sends `WAKE` (frames in C11wake order):
```
assistant  tool_use Bash {"command": "sleep <n>", "run_in_background": true}
system     background_tasks_changed {"tasks": [{"task_id", "run_id", "task_type": "local_bash", "description": "sleep <n>"}]}
system     task_started {"task_id", "run_id", "tool_use_id", "description", "is_backgrounded": true, "task_type": "local_bash"}
user       tool_result "Command running in background with ID: <task_id>. Output is being written to: <file>. You will
           be notified when it completes. To check interim output, use Read on that file path."
           tool_use_result {..., "noOutputExpected": false, "backgroundTaskId": "<task_id>"}
assistant  "started"  ->  result  ->  lifecycle completed  ->  idle
```
`task_id` looks like the real one (`b` + 8 characters), `run_id` too (`<9 chars>-<8 hex>`). The output file is
`$FAKE_AGENT_DIR/claude/tasks/<session>/<task_id>.output` (empty, since `sleep` prints nothing).

n seconds later, with no input:
```
system     task_updated {"task_id", "run_id", "patch": {"status": "completed", "end_time": <ms>}}
system     task_notification {"task_id", "run_id", "tool_use_id", "status": "completed", "output_file",
           "summary": "Background command \"sleep <n>\" completed (exit code 0)"}
system     background_tasks_changed {"tasks": []}        (the tasks still running, if any)
system     session_state_changed running                  (only with the session-state env var)
system     init
           ... FAKE_WAKE_TURN_SECS (default 1.5 s) ...
assistant  "woke: <text>"   (no user_message_uuid)
result     success, "woke: <text>", no user_message_uuid(s), num_turns 1, the next result_index,
           "origin": {"kind": "task-notification", "producer": "session-task", "runId": "<run_id>"}
system     session_state_changed idle
```
There is no user replay and there are no `command_lifecycle` frames, because no message was sent. The
`origin` field and the missing `user_message_uuid(s)` are exactly what the real result carried. Under chaos
the turn gets the usual thinking, `thinking_tokens` and `rate_limit_event` noise (C11wake has all three).

Rules the fake follows:
* If another turn is running when the n seconds are up, the whole sequence above starts right after that
  turn's result. If messages were queued behind that turn too, the self-started turn goes first and there is
  no `idle` between them.
* A message sent while the self-started turn runs gets `command_lifecycle queued` and runs as the next turn
  (the turn has no tool call, so nothing is injected into it). An interrupt ends it like any turn: an error
  result, still with `origin`, and no lifecycle frames.
* Several `WAKE`s can be pending at once; each has its own task and its own self-started turn.
* The self-started turn writes no receipt. It is recorded in `self_turns.jsonl` instead (see
  [Receipts](#receipts)).
* Codex doesn't start a turn by itself. Recorded on 2026-10-08 (`reference/agent-logs/X15wake.jsonl` and
  `X15wakeb.jsonl`, script `reference/agent-probes/probe_phase2b.py`): asked to start a background command and
  end its turn, gpt-6-luna ran `sleep 15; echo bg-done-42 > bg-done.txt` as a background terminal (a
  `commandExecution` item, source `unifiedExecStartup`, still `inProgress` at `turn/completed`). 14 s later the
  server sent that item's `item/completed` (status `completed`, exit code 0, the finished turn's `turnId`), and
  nothing else: no `turn/started` in 60 s of idling. X15wakeb (asked to be notified when the command ends)
  waited for the command in the foreground instead, and also started no turn of its own in 75 s. So `WAKE`
  on Codex only replies `wake: not supported by codex`, and `BACKGROUND n` reproduces the background terminal.

## Allow for the rest of the session

Both harnesses can remember an approval. The fakes model each mechanism from real probes recorded on
2026-10-07 (`reference/agent-logs/C10.jsonl`, `C10resume.jsonl` and `X13.jsonl`, with scripts
`reference/agent-probes/probe_always.py` and `probe_always_x.py`), plus the Codex 0.160.0 protocol schema
(`codex app-server generate-json-schema --experimental` / `generate-ts --experimental`).

Use `ASK_PERMISSION:<name>` / `ASK_APPROVAL:<name>` to vary the command, so a test can check that only
"this exact kind of action" is remembered.

### Claude: `updatedPermissions` on an allow answer

The `can_use_tool` request for `touch <name>` carries what the real CLI sent for `touch p1.txt` (C10, Claude
Code 2.1.292) and `touch c3bash.txt` (CBash, 2.1.289):

```json
"permission_suggestions": [
  {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "touch <name>"}], "behavior": "allow", "destination": "localSettings"},
  {"type": "addDirectories", "directories": ["<cwd>"], "destination": "session"},
  {"type": "setMode", "mode": "acceptEdits", "destination": "session"}],
"blocked_path": "<cwd>/<name>"
```

The suggested `addRules` uses `localSettings`, which persists. For a session-only "always", a product must
send its own update with `"destination": "session"`.

An allow answer with `"updatedPermissions": [...]` is applied the way C10 showed:

| update | effect in the fake | real evidence |
|---|---|---|
| `addRules` behavior `allow`, destination `session` (or `cliArg`) | matching Bash commands run without a prompt for the rest of this process. Gone after `--resume` in a new process. | C10 t2: no prompt for the same `touch p1.txt`. C10resume: prompted again. |
| `addRules` to `localSettings` / `projectSettings` | written where the real CLI keeps them, as `{"permissions": {"allow": ["Bash(touch x)"]}}` in `<cwd>/.claude/settings.local.json` / `<cwd>/.claude/settings.json`. Read on every check, so it survives restarts. | Claude Code settings files. Not probed, so no real file was written. |
| `addRules` to `userSettings` | as above, but in `$FAKE_AGENT_DIR/claude/user-settings.json`, never the real `~/.claude` | (same) |
| `replaceRules` / `removeRules` | edit the same stores | SDK `PermissionUpdate` types, not probed |
| `setMode` `acceptEdits` (session) | emits `{"type":"system","subtype":"status","status":null,"permissionMode":"acceptEdits",...}` before `state running`. Later `touch`/`mkdir`/`rm`/`rmdir`/`mv`/`cp`/`sed` commands run without a prompt, and the next turn's `system/init.permissionMode` is `acceptEdits`. Not persisted. | C10 t3/t4 and C10resume |
| `setMode` `bypassPermissions` | nothing asks any more (the existing bypass path) | `--dangerously-skip-permissions` (C7) |
| `addDirectories` / `removeDirectories` | recorded, no other effect | C10 suggestion |

Rule matching: `Bash` matches any command, `Bash(<command>)` an exact command, and `Bash(<prefix>:*)` a
prefix. AskUserQuestion (`ASK_QUESTIONS`) is never auto-allowed by Bash rules or acceptEdits.

The answer's echo now comes after `state running`, and after the `status` frame when there is one. That is
the real order (C3allow, C3deny, CBash, C10). Before this change, the fake echoed first.

### Codex: approval decisions

The 0.160.0 schema's `CommandExecutionApprovalDecision` is `"accept"`, `"acceptForSession"`,
`{"acceptWithExecpolicyAmendment": {"execpolicy_amendment": [...]}}`,
`{"applyNetworkPolicyAmendment": {...}}`, `"decline"` and `"cancel"`. `FileChangeApprovalDecision` is
`accept` / `acceptForSession` / `decline` / `cancel`, but the fake has no file-change approvals.

`availableDecisions` stays exactly what the real server offered for every shell command probed (X2, X3, X12,
X13): `["accept", {"acceptWithExecpolicyAmendment": {"execpolicy_amendment": argv}}, "cancel"]`.
`acceptForSession` and `decline` are not offered, but both are accepted.

| decision | effect in the fake | evidence |
|---|---|---|
| `acceptForSession` | runs now. The identical command then runs without approval for the rest of this process, in this thread only. It is forgotten when the process exits, including after `thread/resume` in a new process. | X13: no approval for the same command in thread A, approval for a different command, approval again in thread B of the same process. Schema: "future prompts in the same session-scoped approval cache should run without prompting". |
| `acceptWithExecpolicyAmendment` | runs now, and appends `prefix_rule(pattern=[...], decision="allow")` to `<codexHome>/rules/default.rules` (`$FAKE_AGENT_DIR/codex/rules/default.rules`). Any thread in any later process skips approval for commands whose argv starts with the pattern. | Schema: "apply the proposed execpolicy amendment so future matching commands can run without prompting". The 0.160.0 binary contains `rules`, `default.rules` and `prefix_rule(pattern=`. Not probed live, because it would write the user's real `~/.codex/rules`. |
| `applyNetworkPolicyAmendment` | treated as `accept`, with nothing remembered | schema only |

A remembered command emits `item/started` + `item/completed` for the commandExecution (source
`unifiedExecStartup`, status `completed`) with no `waitingOnApproval` and no server request. That matches the
X13 shape, and the X13 replay is frame-for-frame identical with the fake.

## Receipts

Every time a fake hands a user message to its "model", it appends one JSON line to
`$FAKE_AGENT_DIR/receipts.jsonl` in a single `O_APPEND` write. For Claude that moment is when the message
starts a turn or is injected into one (its lifecycle `started`). For Codex it is when the `userMessage` item
is emitted.

```json
{"harness": "claude"|"codex", "session": "<session id / thread id>", "message": "<uuid / clientUserMessageId or null>",
 "text": "<message text>", "turn": "<claude: result_index, a per-process counter | codex: turn id>", "pid": 123, "ts": 1791239000.1}
```

Messages that never reach the model write no receipt. That covers a Codex input dropped by an early
interrupt, and a Claude message still queued when the process dies. A message delivered by a process that
later crashes keeps its receipt. A product that resends such a message produces a second receipt, which is
the point.

A turn the harness starts by itself (Claude `WAKE`) is not a delivery, so it writes no receipt. It appends
one line to `$FAKE_AGENT_DIR/self_turns.jsonl` instead, in the same single-write way, when the turn starts
(at its `system/init`):

```json
{"harness": "claude", "session": "<session id>", "text": "<the reply it produces: woke: <text> | woke>", "ts": 1791239000.1}
```

An interrupted self-started turn is still recorded, although its reply never appears.

## Missing conversations and other folders

Recorded on 2026-10-08 (`probe_phase2.py`). The fakes already behaved this way; the self-tests now pin it.

| case | real behavior | fake |
|---|---|---|
| Claude `--resume <unknown uuid>` (`C12missing`, also `C4e`) | stderr `No conversation found with session ID: <id>`, then **one `result` on stdout**: `subtype:"error_during_execution"`, `is_error:true`, `num_turns:0`, `session_id:<id>`, `errors:["No conversation found with session ID: <id>"]`, `result_index:0`. No answer to `initialize`. Stdout closes about 1.2 s after start, exit code 1. A later stdin write gets a broken pipe. | the same frame with the same key set, before reading stdin, exit 1 |
| Claude `--resume <id>` from another working directory (`C12othercwd-1`, `-2`) | works. Same `session_id`, context kept (it recalled the codeword), and `system/init.cwd` is the new directory. | sessions live under `$FAKE_AGENT_DIR/claude/`, whatever the cwd; `system/init.cwd` and `STATE.cwd` report the new cwd |
| Codex `thread/resume` of an unknown thread (`X14missing`, also `X7`) | `{"error": {"code": -32600, "message": "no rollout found for thread id <id>"}, "id": N}`. No notifications. The server keeps running. | the same, no notifications (not even with `FAKE_MCP`); later requests work |

Note that C12missing contradicts the idea that a missing Claude session fails "before any stdout output": the
stderr line and the `result` frame arrive together. Only the `--session-id` errors (C4c, C4g) leave stdout
empty.

## MCP servers (FAKE_MCP)

`FAKE_MCP=github:connected,jira:needs-auth,slow:pending,broken:failed` declares four servers.

**Claude.** Every `system/init` (every turn, including self-started ones) carries them in order:
`"mcp_servers": [{"name": "github", "status": "connected", "source": "project"}, ...]`. Real entries always
have `name`, `status` and `source`. The claude.ai connectors in C1, C10 and C11wake have `source:"claudeai"`
and statuses `pending`, `connected` and `needs-auth`. A server from the project's `.mcp.json` has
`source:"project"`, and one whose command exits at once is `failed` (`C13projectmcp`), so the fake uses
`source:"project"`. The real statuses change between turns (`pending` on the first turn, `connected` later in
C1 and C11wake); the fake keeps the declared status for the life of the process.

**Codex.** Every X log has the same notification, with these five keys:
```
{"method": "mcpServer/startupStatus/updated",
 "params": {"threadId": T, "name": "node_repl", "status": "starting", "error": null, "failureReason": null},
 "emittedAtMs": ...}
```
All servers report `starting` together, and each reports `ready` 0.2 to 1.5 s later, in varying order. After
`thread/start` the `starting` ones come right after `thread/started` (X1, X2accept, X7). After a
`thread/resume` that loads the thread they come before the response (X5c_b). A failed resume sends none
(X14missing). Only `starting` and `ready` were ever recorded. The 0.160.0 schema
(`McpServerStatusUpdatedNotification`) allows `starting | ready | failed | cancelled`, with `failureReason`
`"reauthenticationRequired"` or null. The fake maps:

| `FAKE_MCP` status | Codex notifications | basis |
|---|---|---|
| `connected` | `starting`, then `ready` | every X log |
| `pending` | `starting` only | a server that has not finished starting |
| `failed` | `starting`, then `failed`, ``error: "MCP client for `<name>` failed to start: fake MCP server exited"``, `failureReason: null` | schema; the message prefix is a string in the 0.160.0 binary |
| `needs-auth` | `starting`, then `failed`, ``error: "MCP client for `<name>` failed to start: requires OAuth reauthentication. Use your client's MCP OAuth sign-in flow."``, `failureReason: "reauthenticationRequired"` | schema; the phrases are strings in the 0.160.0 binary |

The final status follows 0.2 s after `starting` (chaos: 0.1 to 1.5 s, and both orders shuffled). The
notifications carry no `turnId` and may land inside a turn, as in the real logs.

## Live sessions: TUI, hooks, transcripts

Tern runs every session headless (`claude -p` stream-json, a private `codex app-server`) and lets the user
take one over live: the agent's own interface in a pane, on the same conversation, and back. It observes live
agents through hooks in its plugins. The fakes support all of it: Codex's app server on a unix socket with
several clients, a line-oriented TUI for each harness, plugin hooks in every mode, Claude's transcript file,
and a log of any moment two processes ran one conversation.

### Codex app server on a unix socket (X16)

Probed with codex-cli 0.162.1 (`X16clientA.jsonl`, `X16tui.pty`/`.txt`): `codex app-server --listen unix://PATH`
speaks WebSocket on the socket (`101 Switching Protocols`, header
`x-codex-websocket-max-unfragmented-message-bytes: 16777216`, one JSON-RPC message per text frame). Client A
and Codex's own TUI (`codex resume THREAD --remote unix://PATH`) were connected at once. A saw the TUI's turns
(`turn/started`, a `userMessage` item with a `clientId`, `agentMessage`, `turn/completed`), the TUI showed A's
turns, A's `turn/steer` into a turn the TUI started worked, and after the TUI exited the server and the thread
stayed usable for A.

| aspect | fake | basis |
|---|---|---|
| handshake | `GET` with `Upgrade: websocket` and `Sec-WebSocket-Key` gets `HTTP/1.1 101 Switching Protocols` with `connection: upgrade`, `upgrade: websocket`, `sec-websocket-accept`, `x-codex-websocket-max-unfragmented-message-bytes: 16777216`. Anything else gets `400 Bad Request` and is closed. | X16 (status line and header); the 400 is inferred |
| frames | client frames must be masked (otherwise close 1002); ping is answered with pong; a close is echoed; fragmented messages are joined, control frames may come between fragments; binary messages are ignored (stderr line); invalid UTF-8 closes with 1007, messages over 256 MiB with 1009. Non-JSON text is logged on stderr and not fatal, as on stdio. | RFC 6455 |
| outgoing size | a message up to 16 MiB is one frame; a bigger one (`HUGE 17` and up) goes out as 16 MiB fragments | our reading of the header (inferred) |
| subscriptions | a client is subscribed to a thread by `thread/start`, `thread/resume`, `turn/start`, `turn/steer`, `thread/queue/add` and `thread/queue/start`. Notifications with `params.threadId` go to the thread's subscribers; the rest (`thread/started`, `account/rateLimits/updated`) to every initialized client. | X16: both clients saw each other's turns, and A got `thread/started` for a thread it did not start. Subscribing by a turn method is inferred. |
| `thread/unsubscribe` | the client gets no more notifications for that thread; the thread stays loaded and keeps its writer lock (X5). This applies to stdio as well. | the lock part is X5; the notification part is inferred |
| server requests (approvals, questions, permissions, elicitations) | sent with the same id to every subscriber of the thread. The first answer wins; later answers are ignored; `serverRequest/resolved` goes to all subscribers. A client that subscribes while a request is pending gets it right after its `thread/resume` answer. | **inferred** (not probed) |
| clients leaving | the server, its threads and their running turns carry on; pending requests stay pending for the others | X16 |
| lifetime | stdin is not read. The server runs until SIGTERM, SIGINT or SIGHUP, even with no client left; it then kills RUN commands, releases its thread locks, removes the socket file and dies of the signal. `EXIT_CLEAN` also removes the file; `CRASH` leaves it, as a crash would. A stale socket file (nobody listening) is replaced; a socket with a live listener makes the fake exit 1 (`address already in use`). | X16 (kept running; Tern kills it); the rest inferred |
| timing | `FAKE_SLOW_START` delays creating the socket. Under chaos each message waits 0 to 40 ms in its client's writer thread and is sometimes split over two socket writes. | |

Not reproduced from X16: `thread/settings/updated` before the TUI's turns, the ephemeral title-generation
thread (`thread/started` with `ephemeral: true`, then `thread/name/updated`), `remoteControl/status/changed`,
`account/updated`, `thread/goal/cleared` and the turns' new `rootTurnId`. Remember that macOS limits a unix
socket path to 103 bytes.

### TUI mode (live sessions)

Both TUIs are line-oriented, so tests can read the screen (`tern read --pane`) and type
(`tern send --pane … --enter`). The terminal is put in a raw-ish mode (no echo, no line buffering, signals on).
The input line stays at the bottom with a prompt (`> ` Claude, `› ` Codex); everything else is printed above
it, each line as `\r\x1b[K<text>\n`, after which the prompt and what is being typed are redrawn. Keys: printable
characters, Backspace, Ctrl-U (clear), Enter (`\r` or `\n`) submits, Ctrl-D on an empty line ends the TUI, Esc
interrupts a running turn, other escape sequences (arrows) are ignored. Ctrl-C (SIGINT) interrupts a running
turn; at the prompt it only prints `(Ctrl-C does not quit: type /exit or press Ctrl-D)`. `/exit` (or `/quit`),
Ctrl-D, SIGTERM and SIGHUP end it. Without a terminal on stdin the TUIs read plain lines and print plain lines,
and at the end of the input they finish the work they were given before quitting.

#### Claude TUI

`fake_claude [--resume ID | --session-id ID] [--plugin-dir DIR]… [--model M] [--effort E]
[--dangerously-skip-permissions] [--permission-mode M] [-n NAME] [PROMPT]` (any invocation without `-p`).

* It is the same engine on the same session file (`$FAKE_AGENT_DIR/claude/<sid>.json`), so every trigger works,
  `RECALL` sees turns from both modes, and receipts are written as usual (a typed line's `message` is a fresh
  uuid). A fresh session gets a new id, or `--session-id`'s; a missing `--resume` id prints
  `No conversation found with session ID: <id>` and exits 1.
* Startup prints `✻ Fake Claude Code <version>`, `  session: <id>`, `  cwd: <dir>`, then, on `--resume`, the
  conversation so far. Then the SessionStart hook runs, then PROMPT is sent if given.
* The terminal title is set with OSC 2 to `✳ <title>`: `-n NAME` if given, otherwise the conversation's first
  prompt (whitespace collapsed, cut to 40 characters). The title is kept in the session file, so a resumed TUI
  sets it at startup, also for a conversation started with `-p`.

| line | meaning |
|---|---|
| `> text` | a user message the model received (a turn's first message, or one injected mid-turn) |
| `⏺ text` | a reply (more lines indented by two spaces) |
| `⏺ Bash(cmd)` / `⏺ Bash(cmd) (background)` / `⏺ AskUserQuestion` | a tool call |
| `  ⎿  output` | a tool result: up to three lines, then `… +N lines`, or `(No output)` |
| `⏺ Background command "sleep n" completed (exit code 0)` | a WAKE task finished; the self-started turn follows |
| `✻ Worked for Ns` | the turn ended |
| `  ⎿  Interrupted · What should Claude do instead?` | the turn was interrupted |

* A line typed while a turn runs is queued and injected at the next tool boundary (shown then as `> text`), or
  runs as the next turn, exactly as in `-p` mode.
* `ASK_PERMISSION` without bypass prints `Bash command`, the command and
  `Do you want to proceed? [y]es / [a]lways / [n]o`, and waits. `y` allows. `a` allows and adds an allow rule
  for that exact command to `localSettings` (`<cwd>/.claude/settings.local.json`), like the real dialog's
  second option. `n` denies and stops the turn (`Interrupted`), like the real "No, and tell Claude what to do
  differently". Anything else repeats the question. `ASK_QUESTIONS` asks each question in turn; a number picks
  an option, any other text is the answer.
* Ctrl-C or Esc during a turn interrupts it (no hook fires). Lines still queued stay queued and run next.
* `/exit` and Ctrl-D end it with SessionEnd reason `exit`; SIGTERM, SIGHUP or the terminal going away with
  reason `other` (for the two signals the fake then dies of the signal). A running turn is abandoned (no Stop
  hook) and RUN commands are killed.

#### Codex TUI

`fake_codex [OPTIONS] [PROMPT]` (a new thread) and `fake_codex resume [THREAD] [PROMPT] [--remote unix://PATH]
[-m M] [-c k=v]… [--dangerously-bypass-approvals-and-sandbox]`.

* **With `--remote unix://PATH`** it is a WebSocket client of that server: `initialize` (client name
  `codex-tui`), then `thread/resume THREAD` with no overrides, as the real TUI did in X16 (`-m`, `-a`, `-s`
  and the bypass flag are not sent; `-c` only configures a local engine), or, without `resume`, `thread/start`
  with the folder and those flags. Hooks run in the server, not here. If the server goes away it prints
  `■ Lost the connection to the app server` and exits 1.
* **Without `--remote`** it runs its own engine in-process on the same state files
  (`$FAKE_AGENT_DIR/codex/threads/`) and takes the thread's writer lock. A new thread gets the current folder
  and `-m`, `-a`, `-s` or the bypass flag (`never` + `danger-full-access`); the defaults are `on-request` and
  `workspace-write`, the real TUI's. A resume applies the same flags as overrides (inferred). If another live
  process holds the thread, it prints `Error: thread <id> already has an active writer`, logs a
  [violation](#one-process-per-session-violationslog) and exits 1. Hooks run here, detached from the terminal.
* `resume` without THREAD: `--last` takes the most recently updated thread of the current folder (local only);
  without `--last` the fake exits 2 (there is no session picker).
* Startup prints `>_ Fake Codex (v<version>)`, `  thread: <id>`, `  directory: <cwd>`,
  `  model: … · approvals: … · sandbox: …` (plus `· remote: …`), then the thread's history from the resume answer
  (each turn's summary: first user message, last agent message).

| line | meaning |
|---|---|
| `› text` | a `userMessage` item, from any client (this TUI's own, another client's turn, a steer) |
| `• text` | an `agentMessage` item (commentary and final answers) |
| `• Ran cmd` + `  └ first output line` (or `(no output)`) | a completed command |
| `✗ Declined: cmd` | a declined command |
| `─ Worked for Ns ─` | a turn completed |
| `■ Conversation interrupted - tell the model what to do differently.` / `■ Turn failed: …` | a turn ended otherwise |
| `⚠ message` | a `warning` notification |

* A typed line is `turn/start`, or `turn/steer` with `expectedTurnId` while a turn runs (falling back to
  `turn/start` on an error). Turns started by other clients count as running turns too.
* An approval prints `Allow command?`, `  $ cmd` and `[y]es / [a]lways (this session) / [n]o, tell Codex what to
  do differently`: `accept`, `acceptForSession`, `cancel` (which aborts the turn, as the real TUI's "No" does).
  Questions are asked one by one (number or text). Permission and elicitation requests take `y`/`n`. A request
  another client answers first prints `(answered elsewhere)`.
* Ctrl-C or Esc during a turn sends `turn/interrupt`.
* Ending it: in local mode a running turn is saved as interrupted (no hook), SessionEnd runs (reason `exit` for
  `/exit` and Ctrl-D, `other` for signals) and the thread lock is released. In remote mode it only closes its
  WebSocket; the thread, and any turn still running, stay on the server.

### Hooks

Hooks come from plugin directories: Claude's `--plugin-dir DIR` (repeatable) and `$FAKE_CLAUDE_PLUGIN_DIRS`,
Codex's `$FAKE_CODEX_PLUGIN_DIRS` (both colon-separated; they stand in for installed plugins). Each
`DIR/hooks/hooks.json` has the plugin shape
`{"hooks": {"Event": [{"matcher"?: "...", "hooks": [{"type": "command", "command": "...", "timeout"?: secs}]}]}}`.
A directory listed twice counts once. The plugin's name and version come from `.claude-plugin/plugin.json` or
`.codex-plugin/plugin.json` (else the folder name); Claude's `system/init.plugins` lists them as
`{"name", "path", "source": "<name>@inline", "version"}` for `--plugin-dir` (C14resume) and
`"<name>@installed"` for the environment variable (made up: a real installed plugin names its marketplace).

Running a hook, both fakes:
* `${CLAUDE_PLUGIN_ROOT}` (Claude) or `${PLUGIN_ROOT}` and `${CLAUDE_PLUGIN_ROOT}` (Codex) in the command are
  replaced by the plugin directory, and the environment gets `CLAUDE_PLUGIN_ROOT` (both), `PLUGIN_ROOT` (Codex)
  and `CLAUDE_PROJECT_DIR` (Claude) on top of the fake's own environment.
* `/bin/sh -c <command>` is started by the fake itself, so the hook's parent is the fake (C14: `$PPID` is the
  `claude` process), with the session's folder as cwd and one JSON object on stdin. Its stdout and stderr are
  captured and ignored, and so are exit codes and JSON decisions (Tern's hooks print nothing).
* Claude keeps hooks in its own session and process group, so in the TUI a hook can open `/dev/tty`. Codex
  runs them detached with `setsid`, as Codex 0.155 and later do; a hook then finds the terminal through its
  parent chain (as Warp's codex-warp plugin does).
* The hooks of one event run in parallel and the fake waits for all of them before going on (so a slow Stop
  hook delays the turn's end). A hook still running after its `timeout` (default 60 s) is killed.
* `matcher` (a regex matched against the whole value; empty or `*` matches all) applies to the tool name for
  PreToolUse, PostToolUse and PermissionRequest, the `source` for SessionStart, the `notification_type` for
  Notification, the `reason` for SessionEnd and the `error` for StopFailure.
* In `-p` mode each SessionStart hook is also reported on stdout before the `initialize` answer, as in C14:
  `{"type":"system","subtype":"hook_started","hook_id","hook_name":"SessionStart:startup|resume","hook_event":"SessionStart",...}`
  then `hook_response` with `output`, `stdout`, `stderr`, `exit_code` and `outcome` (`success`, or `error` for a
  non-zero exit). No other event produces frames.

**Claude** (C14hooks, `claude -p` 2.1.296: SessionStart, UserPromptSubmit also for a steered message,
PreToolUse, PostToolUse, Stop, SessionEnd; the TUI probe stopped at the trust dialog, so TUI hooks are
inferred to be the same). Every input has `session_id`, `transcript_path` (the [transcript](#claude-transcript))
and `cwd`; turn events add `prompt_id` (one per turn: a steered message shares its turn's) and
`permission_mode`; tool events and Stop add `effort: {"level": <--effort or "medium">}` (C14 had medium);
all have `hook_event_name`.

| event | when | other fields | basis |
|---|---|---|---|
| SessionStart | at startup, before stdin is read (and before the TUI's first prompt) | `source`: `startup` or `resume` (also with `--fork-session`); no `permission_mode` | C14 (the real resume also sends `seconds_since_last_response`, `context_tokens`, ... : not reproduced) |
| UserPromptSubmit | each message that starts a turn or is injected into one (TUI lines too); not for a self-started WAKE turn | `prompt` | C14 |
| PreToolUse | after the tool_use frame, before the tool runs (SLEEP, RUN, HUGE, WAKE, ASK_PERMISSION, ASK_QUESTIONS) | `tool_name` (`Bash` / `AskUserQuestion`), `tool_input`, `tool_use_id` | C14 |
| PostToolUse | when the tool finished, before its tool_result frame; a WAKE command right away, with `backgroundTaskId` | `tool_name`, `tool_input`, `tool_response` (the frame's `tool_use_result`), `tool_use_id`, `duration_ms` | C14; none after a denial or an interrupt (inferred) |
| PermissionRequest | an `ASK_PERMISSION` that will prompt, right before the `can_use_tool` request (both modes) | `tool_name`, `tool_input`, `permission_suggestions` | inferred |
| Notification | TUI only: `permission_prompt` with that prompt (`Claude needs your permission to use Bash`); `idle_prompt` after `FAKE_CLAUDE_IDLE_SECS` idle after a turn (`Claude is waiting for your input`) | `notification_type`, `message` | inferred (real thresholds: 60 s) |
| Stop | a turn that ends normally, after its last reply and before its `result` | `stop_hook_active: false`, `last_assistant_message`, `background_tasks` (WAKE tasks still running, as `{"task_id","run_id","task_type":"local_bash","description"}`), `session_crons: []` | C14; the `background_tasks` entry shape is inferred |
| StopFailure | instead of Stop, for a `FAIL` turn | `error: "invalid_request"`, `last_assistant_message` (the API error text) | inferred |
| SessionEnd | when the process ends normally: stdin EOF in `-p` and `EXIT_CLEAN` (`other`), SIGTERM/SIGHUP (`other`), TUI `/exit` and Ctrl-D (`exit`) | `reason`, the last `prompt_id`; no `permission_mode` | C14 (`other` at stdin EOF); the rest inferred |

An interrupted turn fires no hook at all (no Stop), as with the real CLI; neither do CRASH, HANG or a SIGKILL.
For WAKE, the turn that starts the background command ends with a Stop listing it in `background_tasks`; the
self-started turn fires no UserPromptSubmit and ends with a Stop whose `background_tasks` is `[]` (or the
tasks still running).

**Codex** (not probed: the event set follows Warp's codex-warp plugins, which hook SessionStart,
UserPromptSubmit, PostToolUse, PermissionRequest, Stop and SessionEnd). Every input has `session_id` (the
thread id), `transcript_path` (the thread's `path`, its state file), `cwd` (the thread's), `hook_event_name`
and `model`; turn events add `turn_id`.

| event | when | other fields |
|---|---|---|
| SessionStart | after `thread/start` (`startup`, after `thread/started`) or a `thread/resume` that loads the thread (`resume`) | `source` |
| UserPromptSubmit | before each `userMessage` item, steered inputs included | `prompt` |
| PreToolUse | before each `commandExecution` starts (and before an approval is asked) | `tool_name: "Bash"`, `tool_input: {"command"}`, `tool_use_id` (the item id) |
| PostToolUse | after a command's `item/completed`; a `BACKGROUND` command right after it starts | the same, plus `tool_response` (the command output, a string) |
| PermissionRequest | right before `item/commandExecution/requestApproval` | `tool_name`, `tool_input` |
| Stop | a completed turn, once no input can join it any more, before `thread/status/changed idle` and `turn/completed`; not for failed or interrupted turns | `stop_hook_active: false`, `last_assistant_message` |
| SessionEnd | local TUI only, as it ends | `reason`: `exit` or `other` |

The app server fires no SessionEnd (when a real server's sessions end was not probed).

### Claude transcript

Both modes append to `${CLAUDE_CONFIG_DIR:-$FAKE_AGENT_DIR/claude-config}/projects/<slug>/<sid>.jsonl`, the
file every hook input names as `transcript_path`. The slug is the working directory with every character other
than `A-Z a-z 0-9` replaced by `-` (`/Users/x/a/.b` becomes `-Users-x-a--b`, as in C14; underscores become `-`
too, which is the real rule as far as we know). The path is chosen when the session is created and kept in the
session file, so resuming from another folder keeps appending to the same file (inferred). A forked session
starts a new file. Lines are shaped like Claude Code 2.1.296's; chained entries carry `parentUuid`,
`isSidechain`, `userType`, `cwd`, `sessionId`, `version`, `uuid` and `timestamp`:

| when | line |
|---|---|
| a message starts a turn | `{"type":"user","uuid":<the stream-json uuid, or a fresh one for a typed line>,"message":{"role":"user","content":<as sent>}}` |
| a message arrives while a turn runs | `{"type":"queue-operation","operation":"enqueue","content":<text>,"timestamp","sessionId"}` |
| it is injected mid-turn | `{"type":"attachment","attachment":{"type":"queued_command","prompt":<text>,"source_uuid":<its uuid>,"commandMode":"prompt"}}` then `{"type":"queue-operation","operation":"remove"}` |
| it runs as the next turn instead | `{"type":"queue-operation","operation":"dequeue"}` then the `user` line (inferred) |
| it is dropped by `cancel_queued` | `{"type":"queue-operation","operation":"remove"}` (inferred) |
| every assistant frame (text, tool_use, thinking) | `{"type":"assistant","uuid","requestId","message":{"id","type":"message","role":"assistant","model","content","stop_reason","usage"}}` |
| every tool result and interrupt marker | `{"type":"user","uuid","message":{"role":"user","content":[...]},"toolUseResult"?}` |

The fake still keeps the conversation in `$FAKE_AGENT_DIR/claude/<sid>.json`; the transcript is only written,
never read.

### One process per session (violations.log)

When a fake starts on a conversation that another live fake process is running, it appends one line to
`$FAKE_AGENT_DIR/violations.log` (a single `O_APPEND` write):
`two processes on <claude|codex> session <id>: pids <the other> and <this one>`.

* Claude (`-p` or TUI) records itself in `claude/<sid>.pid` when its session is set up (`--session-id`,
  `--resume`, or the new id of `--fork-session`), logs the line if a live fake owns it, and carries on, as the
  real CLI doesn't refuse. It removes the file on a normal end and on SIGTERM (and SIGHUP in the TUI); the file
  of an owner that died otherwise is ignored.
* Codex: a `thread/resume` (app server or local TUI) of a thread whose writer lock belongs to another live
  process is refused as before (`thread <id> already has an active writer`) and also logged.
* "Live" means the pid runs (not a zombie) and its command line names the same fake script, so dead owners,
  unreaped zombies and recycled pids never count. The Codex lock check now uses the same rule, so a zombie
  owner no longer blocks a resume.

Tests assert this file stays empty; a line means the product ran two processes on one conversation (for
example a live TUI started before the headless process was stopped).

## Chaos mode

`FAKE_CHAOS=<seed>` adds only variation the real harness can produce. Choices are seeded, but the exact
interleaving still depends on thread timing, so treat a seed as reproducible in spirit, not frame-for-frame.

### Both fakes

| variation | real-behavior basis |
|---|---|
| 0 to 40 ms delay before every stdout line | real frames arrive with arbitrary gaps (any log) |
| about 20% of lines written as two writes, 1 to 15 ms apart | pipes deliver partial lines. A reader must buffer to `\n`. |

### Claude

| variation | basis |
|---|---|
| `system/thinking_tokens` frames (1 to 3, rising `estimated_tokens`, with `user_message_uuid`) between `system/init` and the replay, and before later API responses | C1, C3allow, C3deny, C5, C9 (`init thinking thinking U:replay`; `tool_result thinking thinking A:thinking`) |
| an `assistant` thinking frame (`thinking:""` plus `signature`) before the text or tool_use frame, sharing its `message.id`. When it is the first frame of the turn it carries `user_message_uuid(s)` and the text frame does not. | every haiku log. PROTOCOLS "General frame facts" and C6. |
| `rate_limit_event` after the first API response of a turn (60%), occasionally after later ones | C1, C2, C9, CBash. C3noanswer has two in one turn. |
| a message sent during a tool is either injected at the boundary (replay, `started`, injected `completed` before the shared result, the first message's `completed` after it) or left queued and run as the next turn (`completed` then `started`, with no idle in between) | PROTOCOLS "Mid-turn injection" (C9), C2, C9b |

### Codex

| variation | basis |
|---|---|
| `thread/tokenUsage/updated` (+ `account/rateLimits/updated`) after tool items, after the final answer before `idle`, and before an interrupt ack | X1, X3, X4, X8, X12 |
| commentary agentMessage before tool calls, sometimes (SLEEP always has one without chaos) | present in X5a and X8, absent in X1 and X10 (PROTOCOLS X8) |
| agentMessage text split into 1 to 5 `item/agentMessage/delta` chunks | X4, X8 |
| `reasoning` items (`summary:[]`, `content:[]`) before outputs | X4q |
| `warning` notification before a `turn/start` answer (10%) | X7 (shape `{threadId, message}`) |
| `thread/queue/changed` repeated with no change every 1 to 3 s, but only for threads whose queue API was used. Real is every 10 s. | X4q |
| 0 to 300 ms between `turn/started` and the first `userMessage` item | X1, X3, X4 (the real gap is 0.04 to 2.8 s) |
| **steering race**: a `turn/start` or `turn/steer` arriving after the final answer but before `turn/completed` either joins the turn (second `userMessage`, second `final_answer`, one `turn/completed`) or waits for the turn to complete and then gets a new turn (`turn/start`) or `no active turn to steer` (`turn/steer`). A 0 to 40 ms window after each final answer widens the race. | PROTOCOLS X4: race test in X4 and X9 |
| interrupt during streaming leaves the item open, with no `item/completed` | PROTOCOLS X1 ("treat open items as aborted") |

These hold with or without chaos:
* An answer to a server request must carry the request's id with its type: `false` for request `0` is ignored
  and the request stays pending, as the real 0.160.0 server did (2026-10-08, a Tern trace).
* A `turn/start`, `turn/steer` or `turn/interrupt` that arrives while a turn is closing is answered after that
  turn's `turn/completed`. That is the X9 ordering.
* Steer responses are written before the steered input's `userMessage` item.
* An interrupt leaves in-flight items without `item/completed`. A dropped approval's `serverRequest/resolved`
  comes after `turn/completed` (X1, X3).

### Codex early interrupt

If an interrupt arrives after the `turn/start` answer but before the `userMessage` item, the turn ends
`interrupted` with no items at all. No `userMessage` is emitted for that `clientUserMessageId` and no receipt
is written, so the message was never delivered. `FAKE_INPUT_DELAY` makes this deterministic, and chaos makes
it occasional.

This was not probed directly, but it is plausible. Every real turn shows the `userMessage` item 0.04 to
2.8 s after `turn/started`, the first turn of a process being the slow one (X1: 1.8 s, X3: 2.8 s). An
interrupt aborts the turn task wherever it is, and its in-flight items never complete (X1, X3). An abort
inside that gap therefore never records the input. A product must not assume that an acknowledged
`turn/start` means delivery. Only the `userMessage` item with its `clientId` proves delivery.

### Deliberately not faked

| idea | why not |
|---|---|
| Claude: an extra `system/init` at turn start | Every real turn has exactly one `system/init`: 24 inits against 26 results across the C logs, with the difference being the two startup-failure runs. A second one in a turn was never seen. |
| Claude: `stream_event` frames | None appear in any real log. They need `--include-partial-messages`, which the documented command line does not pass. |
| Claude: unknown output `type`s | The real CLI tolerates unknown input types (C8), but no log shows an unknown output type. Version 2.1.289 has a fixed set. |
| Claude: `ASK_URL` / `ASK_FORM` / `ASK_PERMS` | No elicitation or permission-profile flow was probed for Claude stream-json. The only server-to-client request seen is `can_use_tool`. Newer CLIs may route MCP elicitation through a control_request, but nothing verified it, so it is left out. |
| Codex: `ASK_PERMISSION` | Its equivalent is `ASK_APPROVAL`. |
| Interrupts during the Claude gap between `system/init` and the replay | The real behavior is unknown. The fake answers an interrupt there as it always did: an `aborted_streaming` error result. |

## Known limits

* Claude `task_started` fires exactly 3.0 s into a Bash command, and `task_notification` only if it fired.
  Real timing is about 3 s (C2, C9).
* Claude models one content block per API response, plus the optional chaos thinking block, and one tool per
  response.
* RUN never asks permission. For Claude that is as if an allow rule matched. For Codex it ignores
  approvalPolicy and the sandbox. Use `ASK_PERMISSION` / `ASK_APPROVAL` to test approvals. Remembered
  approvals likewise apply only to those two triggers.
* Claude permission rules: only `allow` rules are honored. A matching `deny` or `ask` rule just keeps the
  prompt; the real CLI would auto-deny or always ask. `--allowedTools` / `--disallowedTools` are still
  ignored. acceptEdits auto-allows the listed filesystem commands without checking that paths are inside the
  working directories. Only Bash prompts can be remembered.
* Codex: an execpolicy rule is matched as a plain argv prefix. The real Starlark policy engine supports more.
  `acceptForSession` keys on the exact command string. There are no file-change or network approvals.
* RUN output is delivered when the command ends: one Codex `outputDelta`, then `item/completed`. A command
  that backgrounds a child holding stdout open is cut off 0.5 s after the shell exits. The Codex item shows
  `/bin/zsh -lc ...`, as the real one does, but the fake runs `/bin/sh -c`. A non-zero exit gives Codex item
  status `failed` and a Claude `tool_result` with `is_error:true`. The exact real formatting of failed
  commands was not probed.
* RUN children run in their own process group. An interrupt, stdin EOF (Codex) or SIGTERM to the fake kills
  them. SIGKILL of the fake orphans them.
* `HUGE`, `GARBAGE`, `STDERR_SPAM`, `HANG` and `EXIT_CLEAN` are hostile modes, not observed behavior. The
  real Bash tool truncates long output, and real stdout is pure JSON lines. They exist to test robustness.
* Codex: steered inputs still pending when a turn is interrupted are dropped and get no `userMessage`. The
  real behavior was not probed. An interrupt during the closing window after the final answer ends the turn
  `interrupted`.
* Claude `set_model` only changes what `system/init` and STATE report. `set_permission_mode` also changes
  whether `ASK_PERMISSION` asks. No real model switching exists in either fake.
* Chaos timing (40 ms per frame) slows a turn by about 0.2 to 0.5 s. Allow for it in timeouts.
* `WAKE` (Claude). Only the idle case was recorded (C11wake). Not probed, so chosen by the fake:
  * When the n seconds end during another turn, the fake holds back the whole sequence, `task_updated` and
    `task_notification` included, until that turn's result. The real CLI may report the task at once and may
    hand the notification to the running turn at its next tool call instead of starting a new turn.
  * Stdin EOF while a background command still runs: the fake exits once idle, and the self-started turn
    never happens. C11wake closed stdin only after the second turn.
  * The background command is a timer, not a process. It always ends with exit code 0 and an empty output
    file, and an interrupt or a new turn does not stop it.
  * The self-started reply is one text frame. The real model described the command's result.
* `WAKE` (Codex): verified (X15wake, X15wakeb): the app-server doesn't start a turn when a background command
  finishes. `BACKGROUND n` models the one thing it does report then, the late `item/completed`. Its command is a
  timer, not a process, so it has no output and always exits 0.
* `FAKE_MCP`: statuses never change during a process. Claude entries always say `source:"project"`. The
  Codex `failed` / `needs-auth` error texts are assembled from strings in the 0.160.0 binary, not observed, and
  `cancelled` is never produced. The repeated `ready` notifications seen at turn start in X10 and X12 are not
  reproduced, and there is no `mcpServerStatus/list` method.
* Codex `thread/resume`: the real server also sends `thread/status/changed {"type":"idle"}` right before the
  resume response (X5c_b). The fake does not.
* Claude's TUI has no folder trust dialog. In C14tui the real `claude --resume ID` (with
  `--dangerously-skip-permissions`) stopped at "Is this a project you created or one you trust?" in a folder it
  had not seen, and never got to the conversation. A product that takes a headless session over in a new
  folder (a fresh worktree) has to handle that dialog with the real CLI; tests against the fake won't show it.
* The TUIs are line-oriented stand-ins, not the real full-screen interfaces: no slash commands besides `/exit`
  and `/quit`, no `--continue`, no session pickers, no Shift-Tab mode cycling, no spinner or working title.
* Hooks: only `"type": "command"` hooks run; hook output, exit codes and JSON decisions (block, continue,
  additional context) are ignored; there is no SubagentStop, PreCompact or PostToolUseFailure.

### Live sessions: decisions taken without a probe

This work was done without anyone to ask, so these choices were made and are listed here (the probed parts
are marked in the sections above):
* **Several Codex clients**: server requests go to every subscriber of the thread and the first answer wins;
  a client that subscribes while one is pending gets it too; turn methods subscribe the caller;
  `thread/unsubscribe` stops that client's notifications; non-WebSocket HTTP gets a 400; messages over 16 MiB
  are fragmented at 16 MiB.
* **Claude SessionEnd `reason`**: `exit` for `/exit` and Ctrl-D, as the brief for this work specified. Claude
  Code's documentation lists `prompt_input_exit` for leaving from the prompt and `other` otherwise; nobody
  probed `/exit`, so treat the exact value as unverified and don't let a product depend on it. Signals and stdin
  EOF give `other` (stdin EOF in `-p` mode is probed).
* **Claude TUI answers**: `n` on a permission prompt stops the turn (the real dialog's third option);
  `a` adds a `localSettings` allow rule for the exact command. Codex TUI: `n` is `cancel`, `a` is
  `acceptForSession`.
* **Claude hooks**: PermissionRequest fires in both modes; Notification only in the TUI; AskUserQuestion gets
  Pre/PostToolUse but no PermissionRequest; StopFailure's `error` is `invalid_request`; SIGTERM runs SessionEnd.
* **Codex hooks**: the event list (including PreToolUse, which codex-warp doesn't use), `tool_name: "Bash"`,
  `tool_response` as the output string, SessionStart at `thread/start`/load, Stop only for completed turns,
  SessionEnd only from the local TUI, a BACKGROUND command's PostToolUse when it starts.
* **Codex TUI**: `--remote` sends `thread/resume` without overrides (X16) and ignores model/approval flags;
  the local TUI applies them on resume.
* **Transcript**: tool lines are written too; `dequeue` for a queued message that runs as its own turn; the
  file stays put when a session is resumed from another folder.
* **Title**: `-n NAME` wins over the first prompt.

## Writing tests against the fakes

* **Put a unique nonce in every message** (for example `f"{uuid4().hex[:12]} please ..."`), and check
  delivery by counting receipts whose `text` contains the nonce. Exactly-once delivery means the count is 1.
  Do not key on the `message` field: another product may not send uuids or `clientUserMessageId`s the same
  way, or at all (Claude accepts messages without a uuid).
* When one message embeds another, as in `RUN <product-cli> send B "<nonce> ..."`, the outer message's
  receipt also contains the inner nonce. Count the inner nonce only in receipts that do not contain
  `RUN `, or filter by `harness` / `session`.
* Read `receipts.jsonl` only after the product reports the message settled, and give each test its own
  `FAKE_AGENT_DIR`.
* Use `STATE` to assert configuration outcomes, such as model, effort, full access, cwd and flags, without
  knowing either protocol.
* Run the same outcome tests with chaos off and with a few `FAKE_CHAOS` seeds.
* For stop and cleanup tests, use `SLEEP n` / `RUN sleep n` (interruptible), `HANG` (unresponsive),
  `IGNORE_TERM` (needs SIGKILL) and `SPAWN_STUBBORN` (a leaked process to clean up).
* For orchestration, have an agent run `RUN <product-cli> ...`. The command inherits the fake's environment
  and cwd, and its text is never scanned for triggers.
* For a turn the agent starts by itself, send `WAKE n <nonce>` and expect `woke: <nonce>` in the product's
  transcript, exactly one `self_turns.jsonl` line with that text, and no receipt for it. Use
  `FAKE_WAKE_TURN_SECS` to make the product observe the agent working.
* For MCP status display, set `FAKE_MCP`. Remember that Claude reports statuses only at `system/init`, so
  nothing shows before the first turn, while Codex reports them right after `thread/start` / `thread/resume`.
* For take-over tests, run the product's live pane and read it: the fakes print `> text` / `› text` for user
  messages and `⏺ text` / `• text` for replies, one per line. A screen still holds the prompt line, so look for
  whole lines (`"⏺ ok: <nonce>"`). Wait for `✻ Worked for` / `─ Worked for` before checking what a turn did.
* For live status, point `FAKE_CLAUDE_PLUGIN_DIRS` / `FAKE_CODEX_PLUGIN_DIRS` at the product's own plugins (or
  let it pass `--plugin-dir`) and check what the product makes of the hook events; set
  `FAKE_CLAUDE_IDLE_SECS` to see `idle_prompt` quickly.
* After every test, assert that `$FAKE_AGENT_DIR/violations.log` does not exist or is empty.

## Self-tests and comparison with the real harnesses

* `python3 test_fakes.py` covers:
  * the original protocol scenarios;
  * chaos legality checks for seeds 1 to 3: lifecycle per message, result coverage, C9 completed-ordering,
    one `system/init` per turn, non-overlapping Codex turns, notifications inside their turn, response
    ordering, deltas adding up, `turn/completed.items` holding the last final answer, and receipts matching
    deliveries;
  * both injection outcomes, all four steering-race outcomes, and the early interrupt;
  * receipts, STATE and FAIL;
  * remembered approvals for both harnesses: session scope, persisted destinations and the resume/new-process cases;
  * every hostile trigger, RUN (env, cwd, exit code, trigger isolation, interrupt and SIGTERM kill the
    command) and slow start;
  * `WAKE`: the C11wake frames and shapes, the timing, no receipt plus one `self_turns.jsonl` line, the
    deferral behind a busy turn, a message queued behind a self-started turn, an interrupt during one, stdin
    EOF, chaos legality, and the Codex reply;
  * missing conversations (C12missing, X14missing) and resuming from another folder (C12othercwd);
  * `FAKE_MCP` for both harnesses (with and without chaos, after `thread/start` and `thread/resume`), unset,
    and malformed;
  * `cancel_queued` (and the C15cancelq frame sequence, replayed against `../reference/logs/C15cancelq.jsonl`
    when it exists), the capabilities, and `--plugin-dir` / `-n` in `-p` mode;
  * Claude hooks in `-p` mode: the `hook_started`/`hook_response` frames, the event order and inputs for a
    steered turn, WAKE (both Stops), FAIL (StopFailure), an interrupt (nothing), stdin EOF and SIGTERM
    (SessionEnd `other`), matchers, both plugin sources, `$PPID`, the plugin root variables and cwd;
  * the Claude transcript (lines, order, queue operations, slug, `CLAUDE_CONFIG_DIR`, never `~/.claude`);
  * the Claude TUI in a pty: history, title, RECALL across modes, injection, Ctrl-C (turn and prompt),
    permission y/n, questions, `/exit`, SIGHUP, Ctrl-D, idle and permission notifications, hooks with a terminal;
  * the Codex socket server: handshake and header, fragmented input with a ping, two and three clients seeing
    each other's turns, steering across clients, first answer wins, request replay, unsubscribe, a client
    leaving, 16 MiB fragments, protocol errors, 400, life without clients, socket removal, double `--listen`,
    and chaos legality over the socket for seeds 1 to 3 (two clients, steering across them);
  * the Codex TUI in a pty, remote (history, other client's turns, typed turns seen by the other client,
    steering, approvals answered here or elsewhere, Ctrl-C, SIGTERM) and local (hooks detached from the
    terminal with their inputs, approvals, Ctrl-C, `/exit`, resume, refusal plus violation when an app
    server holds the thread), hooks in the stdio app server, and hook timeouts;
  * the violations log: two `-p` processes, a TUI over a `-p` process, and no line for sequential, SIGTERM-ed
    or crashed predecessors; the last test checks that no other test logged an unexpected violation.
* The C10 and X13 scenarios (remembered approvals) were also replayed against the fakes with the same
  filters. Both are identical.
* `../reference/agent-probes/compare_fake.py` and `compare_fake_codex.py` replay real scenarios against the
  fakes with chaos off and diff the frame-type sequences. C1, C2, C3int, C9, X1, X2accept, X2decline, X3, X10
  and X12 are all identical. So are the 2026-10-08 additions: C11wake (also with `task_started` /
  `task_notification` kept, plus the key sets of the task frames, the background `tool_use_result`, the
  result's `origin` and the `mcp_servers` entries), C12missing (plus exit code and stderr), C12othercwd-1/-2,
  X14missing (plus the error code), and the Codex MCP notifications: order after `thread/start` (X2accept),
  order around `thread/resume` (X5c_b) and key set. The scripts expect the `fake_*.py` files (with
  `fake_common.py`) next to a `logs/` copy of `agent-logs/`, and themselves in a sibling folder. Run them from a
  scratch copy so they do not write into `reference/`. All of the above were re-run after the live-session
  work (2026-10-10) and are still identical.

# Protocol notes: Claude Code 2.1.289 (stream-json) and Codex 0.160.0 (app-server)

All findings below come from real runs on 2026-10-05: Claude `--model haiku`, Codex `gpt-6-luna` with effort low.
Every run's full event stream is in `logs/<scenario>.jsonl` (`{"t": secs, "k": in|out|err|meta, "m": msg}`).
`python3 probes/show.py C1` prints one compactly. To reproduce, run `python3 probes/probe_c.py C1` or `python3 probes/probe_x.py X1` (each costs a real model call).
The JSON below is abbreviated (`…`). Uuids are shortened.

**Bold** marks something surprising or that contradicts the "basics" in the brief.

---------------------------------------------------------------------------------------------------

## Part 1: Claude Code CLI (`claude -p --input-format stream-json … --permission-prompt-tool stdio`)

### General frame facts (from all runs)

* `initialize` → `{"type":"control_response","response":{"subtype":"success","request_id":"init1","response":{commands,agents,output_style,available_output_styles,user_output_styles_dir,models,account,pid,current_permission_mode,feedback_mode,analytics_disabled,remote_control_*,fast_mode_state,fast_mode_disabled_reason,session_state:"idle",capabilities:["ui_surface_v1"]}}}`. It does **not** include the session id.
* **`system/init` is emitted at the start of every turn, not once per process.** It is the first place `session_id` appears. Order for a turn started while idle (identical in every run):
  ```
  {"type":"system","subtype":"session_state_changed","state":"running","sdk_host_only":true,"uuid":…,"session_id":S}
  {"type":"command_lifecycle","command_uuid":U,"state":"queued","uuid":…,"session_id":S}
  {"type":"command_lifecycle","command_uuid":U,"state":"started",…}
  {"type":"system","subtype":"init","cwd":…,"session_id":S,"tools":[…],"model":"claude-haiku-4-5-20251001","permissionMode":"default","claude_code_version":"2.1.289",…}
  {"type":"user","message":{"role":"user","content":"<our text>"},"session_id":S,"parent_tool_use_id":null,"uuid":U,"timestamp":"…","isReplay":true}
  {"type":"assistant","message":{"id":"msg_…","content":[{"type":"thinking",…}],…},"user_message_uuid":U,"user_message_uuids":[U],"request_id":"req_…",…}
  {"type":"assistant","message":{"id":"msg_…"(same id),"content":[{"type":"text","text":"banana"}],…},…}
  {"type":"result","subtype":"success","is_error":false,"result":"banana","user_message_uuid":U,"user_message_uuids":[U],"result_index":1,…}
  {"type":"command_lifecycle","command_uuid":U,"state":"completed",…}
  {"type":"system","subtype":"session_state_changed","state":"idle","sdk_host_only":true,…}
  ```
  Each content block arrives as its own `assistant` frame, and frames from the same API response share `message.id`.
  `session_state_changed` frames carry `sdk_host_only:true` because the CLI only sends them when `CLAUDE_CODE_SDK_READS_SESSION_STATE=1` is set.
* The Bash tool also emits `system/task_started` (after about 3s) and `system/task_notification` with status `completed` or `stopped`. There are also `system/thinking_tokens` frames and `rate_limit_event` frames.
* **The CLI echoes our own `control_response` (the answer to `can_use_tool`) back on stdout.** It does this immediately after reading it (C3). A driver must ignore any `control_response` whose `request_id` is not one of its own outstanding requests.
* **A user message without `uuid` works, but gets no `command_lifecycle` frames** (C8d). The `result` then has no `user_message_uuid(s)`.
* **Back-to-back messages while idle are not merged** (C9b). Message 2 gets `queued` at once and runs as its own turn: result#1 → `completed`(1) → `started`(2) → `system/init` → … → result#2. There is no `idle` between the two turns.

### C1. Interrupt during a long Bash call (`logs/C1.jsonl`, `C1b.jsonl`)
```
→ {"type":"control_request","request_id":"int1","request":{"subtype":"interrupt"}}
← {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}   (~10 ms)
← {"type":"system","subtype":"task_notification","status":"stopped",…}        (only when task_started had already fired)
← {"type":"user","message":{"content":[{"type":"tool_result","content":"The user doesn't want to proceed with this tool use. The tool use was rejected …","is_error":true,"tool_use_id":T}]},"tool_use_result":"User rejected tool use","tool_result_meta":[{"id":T,"non_execution_kind":"user-rejected"}]}
← {"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}
← {"type":"result","subtype":"error_during_execution","is_error":true,"terminal_reason":"aborted_tools","stop_reason":"tool_use",
   "errors":["[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use"],"num_turns":3,"user_message_uuid":U,"user_message_uuids":[U],"result_index":0,…}   (no "result" key)
← {"type":"command_lifecycle","command_uuid":U,"state":"cancelled"}       ← **new state, not in the basics**
← {"type":"system","subtype":"session_state_changed","state":"idle"}
```
* The process stays alive and the next user message runs normally (result `success`, `result_index` 1).
* `interrupt` while idle (before any turn, or after one) → `{"still_queued":[]}` success, with no other frames.
* **Exit code = 1 if the last `result` had `is_error:true`, otherwise 0** (C1b, C3int). This holds even after a clean stdin close.

### C2. Interrupt with a second message queued (`logs/C2.jsonl`)
The second message was sent during `sleep 20` and got `lifecycle queued` only. Injection waits for the next tool boundary.
```
← control_response {"still_queued":["<U2>"]}          ← the response lists queued-but-not-started command uuids
← … tool_result rejected …, result(error_during_execution, user_message_uuids:[U1])
← lifecycle U1 cancelled
← lifecycle U2 started   (no idle in between)
← system/init, replay U2, assistant "banana", result(success, user_message_uuid:U2), lifecycle U2 completed, state idle
```
The queued message is **kept and delivered as its own new turn** right after the interrupt. It is not cancelled.

### Mid-turn injection, for reference (`logs/C9.jsonl`)
The second message was sent during `sleep 5`:
`lifecycle U2 queued` at send time → (tool finishes) → `tool_result` → replay U2 (`isReplay`) → `lifecycle U2 started` → assistant answer covering both →
**`lifecycle U2 completed` (before the result)** → `result{user_message_uuid:U1, user_message_uuids:[U1,U2], num_turns:2}` → `lifecycle U1 completed` → idle.
There is exactly one `result`. The first message's `completed` comes after the result and the injected one's comes before it.

### C3. Permissions (`--permission-mode default`; logs `C3deny`, `C3allow`, `C3int`, `CBash`)
The request comes right after the `tool_use` assistant frame and is preceded by `state:"requires_action"`:
```
{"type":"system","subtype":"session_state_changed","state":"requires_action","sdk_host_only":true,…}
{"type":"control_request","request_id":"88011c99-…","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write",
  "input":{"file_path":"/…/work/x_deny.txt","content":"hi"},"description":"x_deny.txt",
  "permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_01CE…"}}
```
Bash variant (`CBash`) adds `blocked_path` and richer suggestions:
`"input":{"command":"touch c3bash.txt","description":"Create a file named c3bash.txt"},"description":"Create a file named c3bash.txt","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"touch c3bash.txt"}],"behavior":"allow","destination":"localSettings"},{"type":"addDirectories","directories":["/…/work"],"destination":"session"},{"type":"setMode","mode":"acceptEdits","destination":"session"}],"blocked_path":"/…/work/c3bash.txt","tool_use_id":…`.
No `title`, `decision_reason` or `agent_id` appeared, although the SDK reads them if present.

* **deny** `{"behavior":"deny","message":"no"}` → `state running` → (our control_response echoed) → `user{tool_result content:"no", is_error:true}, tool_use_result:"Error: no", tool_result_meta:[{non_execution_kind:"permission-rule"}]` → the model answers → `result success` with `"permission_denials":[{"tool_name":"Write","tool_use_id":…,"tool_input":{…}}]`. The turn completes normally.
* **allow** `{"behavior":"allow","updatedInput":<input>}` → `state running` → echo → `tool_result "File created successfully…"` → `result success`, `permission_denials:[]`. The file was really created.
* While waiting, the session state is `requires_action`, and it goes back to `running` once answered.
* **Interrupt while a permission is pending → yes, `control_cancel_request`:**
  ```
  ← {"type":"control_cancel_request","request_id":"5a1c5931-…"}          (the can_use_tool id, sent before the interrupt ack)
  ← {"type":"control_response","response":{"subtype":"success","request_id":"int1","response":{"still_queued":[]}}}
  ← state running, tool_result "user doesn't want to proceed…", "[Request interrupted by user for tool use]",
    result{subtype:"error_during_execution",is_error:true,terminal_reason:"aborted_tools",permission_denials:[{Write…}]}, lifecycle cancelled, state idle
  ```
  A late answer to the cancelled request is silently ignored, and the file is not written.
* **No timeout:** an unanswered `can_use_tool` waited 66+ seconds (`logs/C3noanswer_stdinclose.jsonl`). Closing stdin while one is pending fails it with `tool_result "Tool permission request failed: AbortError: Tool permission stream closed before response received"`. The model then keeps going, and later tool calls fail with `"…AbortError: Stream closed"` and no request emitted. The turn ends `success` and the process exits 0.

### C4. Resume (`logs/C4a`…`C4g`)
* Process 1 ran `--session-id S`, and its stdin was closed after the result (exit 0). Process 2 ran `--resume S`. **Nothing is replayed on stdout**: no history frames before the first new message, and the initialize response is the same as usual. The first turn's `system/init.session_id == S` (same id). Context is preserved ("PAPAYA").
* `--resume S --session-id NEW` → **fails at startup**. stderr: `Error: --session-id can only be used with --continue or --resume if --fork-session is also specified.` stdout is empty, there is no initialize response, and exit is 1.
* `--resume S --fork-session --session-id NEW` → works. `system/init.session_id == NEW` and context is preserved.
* `--session-id S` where S already exists → stderr `Error: Session ID S is already in use.`, exit 1.
* `--session-id notauuid` → stderr `Error: Invalid session ID. Must be a valid UUID.`, exit 1.
* `--resume <unknown uuid>` → **no initialize response**. Instead a `result` is written to stdout about 0.9s after start, then exit 1:
  ```
  stderr: No conversation found with session ID: 415139b8-…
  {"type":"result","subtype":"error_during_execution","duration_ms":0,"duration_api_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,
   "session_id":"415139b8-…","total_cost_usd":0,"usage":{…},"modelUsage":{},"permission_denials":[],"uuid":…,
   "errors":["No conversation found with session ID: 415139b8-…"],"result_index":0}
  ```
  `--resume not-a-real-session` behaves the same, with `errors:["Error: --resume requires a valid session ID or session title when used with --print. … Provided value \"not-a-real-session\" is not a UUID and does not match any session title."]`, a random `session_id`, and exit 1.

### C5. Stdin closed while a turn is running (`logs/C5`, `C5b`)
**The CLI does not abort.** It finishes the turn: the Bash `sleep 8` completes, the model answers, and `result success` → `lifecycle completed` → `idle` are emitted. Only then does it exit, with code 0 (9.5s after the close).
Closing stdin right after sending a message also completes that turn (exit 0).
To actually stop, send `interrupt` and then close stdin, or kill the process.

### C6. `result` contents
* success: `type, subtype:"success", is_error, api_error_status, duration_ms, duration_api_ms, ttft_ms, ttft_stream_ms, time_to_request_ms, first_content_frame_ms, request_sent_wall_ms, first_request_input_tokens, num_turns, result (final text), stop_reason:"end_turn", session_id, total_cost_usd, usage, modelUsage, permission_denials, terminal_reason:"completed", fast_mode_state, fast_mode_disabled_reason, subagent_stats, uuid, user_message_uuid, user_message_uuids, queued_turn_count, result_index`.
* interrupted: there is no `result`/`api_error_status`/ttft keys. Instead it has `subtype:"error_during_execution", is_error:true, errors:[…], terminal_reason:"aborted_tools", stop_reason:"tool_use"`.
* Linking to our messages: **`user_message_uuid`** is the uuid that started the turn and **`user_message_uuids`** is all of them, including injected ones. `result_index` is a per-process counter (0, 1, …).
* `assistant` frames: **only the first assistant frame of a turn** (with haiku, the thinking frame) carries `user_message_uuid` + `user_message_uuids`. Later frames, including the text answer and the frames after an injection, do not. Correlate by turn order or `result`, not per frame.

### C7. `--dangerously-skip-permissions` (`logs/C7`)
`system/init.permissionMode == "bypassPermissions"`. Bash `echo hi > c7.txt; cat c7.txt` ran with no `can_use_tool` and no `requires_action`.
In `default` mode, read-only-ish Bash such as `sleep`/`echo` also ran without a permission request. Writes (`Write`, `touch`) triggered one.

### C8. Malformed stdin (`logs/C8a`…`C8e`)
| line sent | behaviour |
|---|---|
| `this is not json` | **fatal**: stderr `Error parsing streaming input line (type=unknown, 16 chars): SyntaxError`, stdout closes, **exit 1**. Nothing on stdout. |
| `{"type":"bogus_type"}` | silently ignored, and the session keeps working |
| unknown control subtype | `{"type":"control_response","response":{"subtype":"error","request_id":"bad1","error":"Unsupported control request subtype: no_such_subtype"}}` |
| user msg without uuid/session_id | works; there are no lifecycle frames |
| empty line | ignored |

---------------------------------------------------------------------------------------------------

## Part 2: Codex app-server (`codex app-server --listen stdio://`)

### General facts
* Output has no `"jsonrpc"` field. **Every notification carries a top-level `emittedAtMs`** (outside `params`).
* Requests before `initialize` → `{"error":{"code":-32600,"message":"Not initialized"},"id":1}`. A second initialize → `"Already initialized"`.
* Every error seen used code **-32600**, with the detail in the message string.
* Turn notification order (new turn while idle):
  `RESP {"turn":{id,items:[],itemsView:"notLoaded",status:"inProgress",startedAt:null,…}}` → `thread/status/changed {status:{type:"active",activeFlags:[]}}` → `turn/started` → `item/started`+`item/completed` userMessage (`clientId` = our `clientUserMessageId`, about 2s later) → [reasoning / commentary agentMessage / commandExecution items] → `item/started` agentMessage (`text:""`, phase already set) → `item/agentMessage/delta {itemId,delta}`… → `item/completed` agentMessage (full text) → `thread/status/changed {type:"idle"}` → `turn/completed`.
* `thread/start` result keys: `thread, model, modelProvider, serviceTier, disabledPluginIds, cwd, runtimeWorkspaceRoots, instructionSources, approvalPolicy, approvalsReviewer, sandbox{type:"workspaceWrite",…}, activePermissionProfile, reasoningEffort, multiAgentMode`. This is followed by a `thread/started {thread}` notification. `thread.id` is a UUIDv7, `sessionId == id`, and `thread.path` is the rollout file under `~/.codex/sessions/…`.

### X1. Interrupt during `sleep 20` (`logs/X1.jsonl`)
```
→ {"id":4,"method":"turn/interrupt","params":{"threadId":T,"turnId":TU}}
← {"id":4,"result":{}}                                                        (30 ms)
← {"method":"thread/status/changed","params":{"threadId":T,"status":{"type":"idle"}}}
← {"method":"turn/completed","params":{"threadId":T,"turn":{"id":TU,"items":[],"itemsView":"notLoaded","status":"interrupted","error":null,…,"durationMs":7539}}}
```
* **There is no `item/completed` for the in-flight `commandExecution`.** Treat open items as aborted when `turn/completed` arrives. A later resume shows that item with `status:"failed"`.
* A new `turn/start` sent immediately afterwards works.
* Interrupt with no active turn → `{"error":{"code":-32600,"message":"no active turn to interrupt"}}`.
* Wrong `turnId` while a turn is active → `"expected active turn id <given> but found <active>"`. The turn is not interrupted.

### X2. Approvals (`approvalPolicy:"untrusted"`, `sandbox:"read-only"`; logs `X2accept`, `X2decline`, `X12`)
```
← {"method":"thread/status/changed","params":{"threadId":T,"status":{"type":"active","activeFlags":["waitingOnApproval"]}}}
← {"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-552e…","command":"/bin/zsh -lc 'echo hi > y_accept.txt'","cwd":…,"processId":null,"source":"agent","status":"inProgress","commandActions":[{"type":"unknown","command":"echo hi > y_accept.txt"}],"aggregatedOutput":null,"exitCode":null,"durationMs":null},…}}
← {"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":T,"turnId":TU,"itemId":"exec-552e…","startedAtMs":…,"environmentId":"local",
    "command":"/bin/zsh -lc 'echo hi > y_accept.txt'","cwd":…,"commandActions":[…],"proposedExecpolicyAmendment":["/bin/zsh","-lc","echo hi > y_accept.txt"],
    "availableDecisions":["accept",{"acceptWithExecpolicyAmendment":{"execpolicy_amendment":[…]}},"cancel"]}}
```
* Server request ids are integers starting at **0**, counted per server process. `availableDecisions` is an **experimental** field (it is only in the `--experimental` bindings and we initialize with `experimentalApi:true`). It omits `decline`, but `decline` is accepted.
* **accept** `{"id":0,"result":{"decision":"accept"}}` → `serverRequest/resolved {threadId,requestId:0}` → `status active []` → `item/completed commandExecution status:"completed", exitCode:0, source:"unifiedExecStartup"` → agentMessage "done" → idle → `turn/completed completed`. The file exists.
* **decline** → `serverRequest/resolved` → `status active []` → `item/completed … status:"declined"` → the model replies ("The command was rejected…") → `turn/completed completed`. The file does not exist.
* **cancel** (X12) → `serverRequest/resolved` → `item/completed declined` → `active []` → `idle` → `turn/completed status:"interrupted"`.
* `serverRequest/resolved {threadId, requestId}` is the server's "this request is no longer pending" signal. It is sent after we answer and also when the server drops the request (X3). Use it to close any approval UI.

### X3. Interrupt while an approval is pending (`logs/X3.jsonl`)
`{"id":4,"result":{}}` → `status idle` → `turn/completed status:"interrupted"` → **`serverRequest/resolved {requestId:0}`**, which comes after `turn/completed`.
The pending request is abandoned. A late `{"id":0,"result":{"decision":"accept"}}` is silently ignored and the command never runs. There is no `item/completed` for the command item.

### X4. Steering timing and the queue
* `turn/start` while a turn is active steers into it. The response looks exactly like a new-turn response, with the same `turn.id` and `status:"inProgress"`, and **no `turn/started` follows**. Compare against the active turn id.
  The steered `userMessage` item (with our `clientId`) is delivered at the next tool boundary (X10: after the `commandExecution` completes).
* **Race test** (X4, X9: 7 attempts at 0–60 ms after the final `agentMessage` `item/completed`, while `turn/completed` comes about 30 ms later). **No message was lost.** At 0–15 ms it steered into the same turn: the turn got a second userMessage and a **second `final_answer` agentMessage**, then a single `turn/completed`. At 30 ms and later the turn had already finished, so `turn/start` started a new turn.
  **`turn/completed.turn.items` holds only the last final agentMessage (`itemsView:"summary"`)**, so collect agentMessages from `item/completed` to keep both answers. `thread/turns/list` summaries show only the first userMessage and the last agentMessage.
* `turn/steer {threadId, expectedTurnId, clientUserMessageId, input}` gives an unambiguous steer: `{"result":{"turnId":TU}}`. Errors are `"no active turn to steer"` and ``"expected active turn id `X` but found `Y`"``. The **recommended driver pattern is to try `turn/steer` and fall back to `turn/start` on the "no active turn" error.**
* **`thread/queue/changed {threadId}`** is a notification from an **experimental server-side queue**. It carries no data, so call `thread/queue/list`. The queue API is only in `generate-ts --experimental` (copy in `codex-ts-experimental/`), not in the provided bindings:
  `thread/queue/add {threadId,input,clientUserMessageId}` → `{queuedSubmission:{id,input,clientUserMessageId}}`; `thread/queue/list {threadId,cursor?,limit?}` → `{data:[QueuedSubmission],nextCursor}`; `thread/queue/update {threadId,queuedSubmissionId,input}`; `thread/queue/delete {threadId,queuedSubmissionId}` → `{deleted}`; `thread/queue/reorder {threadId,queuedSubmissionIds}`; `thread/queue/start {threadId,queuedSubmissionId?}` → `{turn}`.
  Observed (X4q):
  * **The queue auto-drains.** A submission added while a turn is active starts a **new turn** right after `turn/completed` (`thread/queue/changed`, `active`, `turn/started`, userMessage `clientId` = its clientUserMessageId).
  * A submission added while **idle starts a turn immediately**.
  * `thread/queue/start` on an empty queue → `"queue is empty"`.
  * **`thread/queue/changed` also fires about every 10s with no change** (at 10.09s, 20.09s and 30.09s). It looks like polling of a persisted queue.
  * Use the queue for "send after this turn" semantics, and `turn/start`/`turn/steer` for "inject now".

### X5. Resume while the thread is loaded in another process (`logs/X5a/b`, `X5c_*`)
* **Rejected.** `{"error":{"code":-32600,"message":"thread 01a10e2a-… already has an active writer"}}`. stderr also says `thread-store conflict`.
* The same happens when process A is merely idle with the thread loaded.
* `thread/unsubscribe` in A returns `{"status":"unsubscribed"}` but **does not release the lock**. Only A's exit releases it, after which B's resume succeeds and keeps context.
* In B, `turn/start` on that thread → `"thread not found: <id>"`. Process B never received A's notifications.

### X6. Stdin EOF with a turn running (`logs/X6.jsonl`)
The process exits **in about 0.2 s with code 0**, killing the running command (stderr: `exec_command failed: UnknownProcessId`). No `turn/completed` is emitted.
On a later resume the turn is persisted as `status:"interrupted"`, and its commandExecution is `status:"failed"`. This is the opposite of Claude, which finishes the turn.

### X7. Error shapes (`logs/X7`, `X7b`)
* `thread/resume` unknown uuid → `{"error":{"code":-32600,"message":"no rollout found for thread id 8b0533a1-…"}}`.
* `thread/resume "nope"` → ``"invalid session id: invalid character: expected an optional prefix of `urn:uuid:` followed by [0-9a-fA-F-], found `n` at 1"``.
* `turn/start` / `turn/interrupt` on an unknown or not-loaded thread → `"thread not found: <id>"`.
* Unknown method → ``"Invalid request: unknown variant `no/such/method`, expected one of `initialize`, …"``.
* A non-JSON line is **not fatal**. It is logged to stderr (`Failed to deserialize JSONRPCMessage`) and the server keeps going.
* **A bad model is not rejected up front.** `thread/start {model:"no-such-model-xyz"}` succeeds. `turn/start` with that model also succeeds, preceded by a `warning` notification (``"Model metadata for `no-such-model-xyz` not found. Defaulting to fallback metadata…"``). Then:
  ```
  ← thread/status/changed {"type":"systemError"}
  ← {"method":"error","params":{"error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"type\":\"invalid_request_error\",\"message\":\"The 'no-such-model-xyz' model is not supported when using Codex with a ChatGPT account.\"}}","codexErrorInfo":"other","additionalDetails":null,"misalignment":null},"willRetry":false,"threadId":T,"turnId":TU}}
  ← turn/completed {"turn":{"status":"failed","error":{…same…},"items":[]}}
  ```
  There is **no `idle`** after a failure; the status stays `systemError`. The next `turn/start` with a valid model works normally.

### X8. Where the final text lives
* `item/completed` with `item.type:"agentMessage"`, `phase:"final_answer"` holds the full text.
* `turn/completed.turn.items` holds only the **last** final agentMessage (summary view). It is empty for interrupted or failed turns.
* **`phase:"commentary"` agentMessages occur mid-turn** before tool calls, e.g. `"I'll run the requested shell command."` (X5a) and `"I'll list the current directory and count its entries."` (X8). Not every tool turn has one: X1 went straight to the command.
* `reasoning` items (`summary:[]`) also appear.
* Deltas `item/agentMessage/delta {threadId,turnId,itemId,delta}` stream the text of both phases.

---------------------------------------------------------------------------------------------------

## Part 3: recordings of 2026-10-08 (Claude Code 2.1.289 haiku, codex-cli 0.160.0)

Logs are in `agent-logs/`, the script is `agent-probes/probe_phase2.py` (C13projectmcp was recorded separately).

### C11. A turn the CLI starts by itself (`agent-logs/C11wake.jsonl`)
The model ran Bash `sleep 8; echo done-xyz` with `run_in_background: true` and replied `started`. 8 s later,
with nothing sent, the CLI ran another turn:
```
(turn 1) assistant tool_use Bash {"command":"sleep 8; echo done-xyz","run_in_background":true}
         system/background_tasks_changed {"tasks":[{"task_id":"bofgoz5j9","run_id":"0muzq2k5n-3c7b4f6b","task_type":"local_bash","description":"sleep 8; echo done-xyz"}]}
         system/task_started {task_id, run_id, tool_use_id, description, "is_backgrounded":true, "task_type":"local_bash"}
         user tool_result "Command running in background with ID: bofgoz5j9. Output is being written to: /private/tmp/claude-501/<cwd-slug>/<session>/tasks/bofgoz5j9.output. You will be notified when it completes. To check interim output, use Read on that file path."
              tool_use_result {"stdout":"","stderr":"","interrupted":false,"isImage":false,"noOutputExpected":false,"backgroundTaskId":"bofgoz5j9"}
         assistant "started" → result (num_turns 2) → lifecycle completed → idle
(8 s later, no input)
         system/task_updated {task_id, run_id, "patch":{"status":"completed","end_time":<ms>}}
         system/task_notification {task_id, run_id, tool_use_id, "status":"completed", output_file, "summary":"Background command \"sleep 8; echo done-xyz\" completed (exit code 0)"}
         system/background_tasks_changed {"tasks":[]}
         system/session_state_changed running
         system/init
         thinking_tokens (no user_message_uuid) → assistant thinking → assistant text (no user_message_uuid)
         result {"subtype":"success","result":"Background command completed with exit code 0. Output: `done-xyz`","num_turns":1,"result_index":1,
                 "origin":{"kind":"task-notification","producer":"session-task","runId":"0muzq2k5n-3c7b4f6b"}}   (no user_message_uuid(s))
         system/session_state_changed idle
```
No user replay and no `command_lifecycle` frames for the second turn. It took 1.55 s from `task_notification`
to `result`. **A `result` can belong to no message the client sent**: it then has `origin` and no
`user_message_uuid(s)`. Not probed: a background task finishing while another turn runs, stdin EOF with a
background task still running, and an interrupt while one runs.

### C12. Missing session, other folder (`agent-logs/C12missing.jsonl`, `C12othercwd-1/-2.jsonl`)
* `--resume <unknown uuid>` behaves exactly as C4e: stderr `No conversation found with session ID: <id>` and,
  at the same moment, the `result` error frame on stdout (`errors:["No conversation found with session ID: <id>"]`,
  `num_turns:0`, `result_index:0`). No `initialize` answer; stdout closes about 1.2 s after start, exit code 1, and later writes get EPIPE.
* `--resume <id>` from a different working directory works: same `session_id`, context kept ("kumquat"), and
  `system/init.cwd` is the new directory.

### C13. A project MCP server (`agent-logs/C13projectmcp.jsonl`)
A `.mcp.json` with `{"mcpServers":{"probe-srv":{"command":"/usr/bin/true"}}}` shows up in `system/init` as
`{"name":"probe-srv","status":"failed","source":"project"}`, next to the claude.ai connectors
(`source:"claudeai"`). Statuses seen across all C logs: `pending`, `connected`, `needs-auth`, `failed`. They
change between turns (connectors are `pending` on the first turn and `connected` later).

### X14. Resuming an unknown thread (`agent-logs/X14missing.jsonl`)
`thread/resume` → `{"error":{"code":-32600,"message":"no rollout found for thread id <id>"},"id":2}` with no
notifications. The server keeps running (same as X7).

### Codex MCP startup notifications (all X logs)
`{"method":"mcpServer/startupStatus/updated","params":{"threadId":T,"name":"codex_apps","status":"starting","error":null,"failureReason":null},"emittedAtMs":…}`.
After `thread/start`, every server reports `starting` right after `thread/started`, then `ready` 0.2 to 1.5 s
later, in varying order. After a `thread/resume` that loads the thread, `starting` comes before the response,
together with `thread/status/changed {"type":"idle"}` (X5c_b). Only `starting` and `ready` were recorded. The
0.160.0 schema allows `starting | ready | failed | cancelled` and `failureReason: "reauthenticationRequired" | null`.

---------------------------------------------------------------------------------------------------

## Surprises, and what the driver should do
1. **Claude: one malformed stdin line kills the process (exit 1).** Validate and serialize every line. Codex just logs it.
2. **Claude echoes our control_response for can_use_tool on stdout.** Ignore control_responses whose ids we didn't originate.
3. **Claude: a new `command_lifecycle` state `cancelled`**, and the interrupt ack carries `still_queued:[uuids]`. Queued messages survive an interrupt and run next.
4. **Claude: `system/init` arrives on every turn**, and the session id is unknown until the first turn starts. With `--session-id`/`--resume` we already know it.
5. **Claude: stdin EOF is graceful** (it finishes the turn). **Codex: stdin EOF is abrupt** (it kills the turn in 0.2s, exit 0).
6. **Claude: the exit code is 1 when the last result was an error**, for example an interrupted turn followed by stdin close. Don't treat that as a crash.
7. **Claude: `--resume` + `--session-id` is an error** unless `--fork-session` is also passed.
   A bad `--resume` id yields a `result` error frame, **without any initialize response**. Don't block forever on init; also watch for `result` and for exit.
8. **Claude: `user_message_uuid(s)` is only on the first assistant frame and on the result.** Lifecycle `completed` for an injected message arrives before the result, while the original's arrives after it.
9. **Claude: permission requests never time out.** An unanswered one waits indefinitely, and stdin close auto-fails it.
10. **Codex: the interrupt or a dropped approval leaves items without `item/completed`.** `serverRequest/resolved` for a dropped approval arrives after `turn/completed`.
11. **Codex: a thread can only be live in one app-server process at a time**, and unsubscribe doesn't free it: a second process that resumes the same thread is refused ("already has an active writer") until the first process exits.
12. **Codex: a steered turn can have several `final_answer` messages**, but `turn/completed.items` keeps only the last one.
13. **Codex: a failed turn leaves the thread status at `systemError`**, not `idle`, so use `turn/completed` as the end-of-turn signal. An experimental server-side queue exists and auto-drains.
14. **Claude can start a turn by itself** when a background command finishes (C11): `system/init` → assistant → `result` with `origin:{"kind":"task-notification",…}` and no `user_message_uuid(s)`, with no message sent and no lifecycle frames.

---------------------------------------------------------------------------------------------------

## Fakes (`fake_claude.py`, `fake_codex.py`, `test_fakes.py`)
* `python3 test_fakes.py` runs 15 scripted conversations. Use `-v` for a wire trace and a name filter to select tests. All tests pass in about 7s.
* `probes/compare_fake.py` and `probes/compare_fake_codex.py` replay the real scenarios against the fakes and diff the frame-type sequences. They are identical for C1, C2, C3int and C9 and for X1, X2accept, X2decline, X3, X10 and X12, after filtering thinking, rate-limit, task, commentary, reasoning and delta noise.
* Both fakes store state under `$FAKE_AGENT_DIR` (default `<tmp>/fake-agent`): `claude/<sid>.json` and `codex/threads/<id>.json` plus a `.lock` holding the pid. A lock owned by a dead pid is treated as stale, as happens after `CRASH`.
* Triggers are substrings of the user text:
  * `SLEEP n`: interruptible.
  * `ASK_PERMISSION` (Claude) / `ASK_APPROVAL` (Codex): the reply is `permission allowed`/`permission denied: <msg>`, or `approval accepted`/`approval declined`/`approval not needed` when the policy is `never`.
  * `CRASH`: exit 1 mid-turn.
  * `ECHO`.
  * `RECALL`: replies `history: …` with the earlier user texts, which is handy to prove a resume worked.
  * `FAIL`: Codex only; a model containing `no-such-model` behaves the same way.
  * default: `ok: <text>`.
* The "Fakes" notes here are historical; `acceptance/fakes/README.md` is current (it covers WAKE, FAKE_MCP and the C12/X14 checks).
* Known simplifications:
  * No thinking or rate-limit frames.
  * Claude's `task_started` is emitted immediately rather than after about 3s.
  * The final answer is one assistant text frame that joins the replies of injected messages with `\n`.
  * Codex always emits a commentary agentMessage before `SLEEP`, a single delta per message, and no reasoning items or token-usage notifications.
  * `turn/interrupt` / `set_model` / `set_permission_mode` are accepted, but the latter two only update what `system/init` reports.
  * The queue's periodic 10s `thread/queue/changed` is not emulated.

---------------------------------------------------------------------------------------------------

## Part 4: recordings of 2026-10-10 (Claude Code 2.1.296 haiku, codex-cli 0.162.1), for headless ↔ live

Script: `agent-probes/probe_phase3.py` (logs in `logs/X16*`, `C14*`, `C15*`, `X17*`).

### X16. Codex: one private app server, Tern's client and Codex's own interface together
* `codex app-server --listen unix://PATH` (exactly one `--listen` is accepted) creates PATH as a
  **symlink** to a socket in `/private/tmp/codex-daemon-<uid>/<hash>` and speaks **WebSocket** on it
  (`HTTP/1.1 101 Switching Protocols`, header `x-codex-websocket-max-unfragmented-message-bytes`), one
  JSON-RPC message per text frame. `codex app-server proxy --sock` does *not* speak it (raw bytes; broken
  pipe). A second server on the same PATH fails at once: `app-server control socket is already in use`.
* Client A (WebSocket) started a thread and a turn; then `codex resume THREAD --remote unix://PATH` (the
  TUI) attached and **showed the history**. A's next `turn/start` appeared live in the TUI; a prompt typed
  in the TUI reached A as `turn/started` + a `userMessage` item (with a `clientId` of the TUI's) +
  `agentMessage` + `turn/completed`; A's `turn/steer` into the TUI's turn worked (the TUI showed it); after
  the TUI exited, A kept using the thread.

### C14. Claude: hooks, and headless → live → headless
* In `-p` mode Claude runs plugin hooks (`--plugin-dir`): SessionStart (`source: startup`),
  UserPromptSubmit (also for a message injected mid-turn), PreToolUse, PostToolUse, Stop, SessionEnd
  (`reason: other` at stdin EOF). Hooks have no tty; their `$PPID` is the claude process.
* Stop input keys: `session_id, transcript_path, cwd, prompt_id, permission_mode, effort,
  hook_event_name, stop_hook_active, last_assistant_message, background_tasks, session_crons`.
* `claude --resume ID` (the TUI) in a folder never trusted shows **"Quick safety check … ❯ No, exit /
  Yes, I trust this folder"** first (default No); `-p` skips it. Trust is per project folder, not
  inherited from a trusted parent that isn't the project root.
* After the TUI is ended with SIGTERM while idle, `claude -p --resume ID` continues the conversation.
* Transcript (`~/.claude/projects/<cwd with / and . as ->/<id>.jsonl`): a message that starts a turn is a
  `user` entry whose `uuid` is the stream-json message's `uuid`; a message injected mid-turn is a
  `queue-operation enqueue`, then an `attachment` `{"type":"queued_command","prompt",…,"source_uuid": <its
  uuid>}`, then `queue-operation remove`. So after a crash, whether a message reached the conversation is
  answered by the transcript.

### C15. Claude: an interrupt that gives back what was queued
* `system/init.capabilities` lists `interrupt_receipt_v1`, `interrupt_cancel_queued_v1`,
  `interrupt_send_now_v1`, `msg_lifecycle_v1`, ….
* A message written during a long Bash call (lifecycle `queued`), then
  `{"subtype":"interrupt","cancel_queued":true}` → `{"still_queued":[],"cancelled":["<its uuid>"]}`; the
  message never runs. (A plain interrupt keeps C2's behaviour: `still_queued` lists it and it runs next.)

### X17. Codex: a steered message, then an interrupt before the next tool step
* `turn/steer` during `sleep 12` → `{"turnId": …}`; `turn/interrupt` a second later → the turn completes
  `interrupted`, and **its items include the steered `userMessage` with our clientId**; the next turn's
  model sees it (it's in `thread/read`). So a steered message is delivered (recorded) even when the turn is
  interrupted before acting on it: count it delivered, never send it again.

### Plugins (2026-10-10)
* Claude: `claude plugin marketplace add <dir>` (a directory marketplace: `.claude-plugin/marketplace.json`)
  and `claude plugin install tern@tern` write `settings.json` (`extraKnownMarketplaces`,
  `enabledPlugins`) and `plugins/installed_plugins.json` (`plugins["tern@tern"][0].version`) under
  `$CLAUDE_CONFIG_DIR` (default `~/.claude`); an update is `plugin marketplace update tern` +
  `plugin update tern@tern` ("restart to apply").
* Codex: `codex plugin marketplace add <dir>` (`.agents/plugins/marketplace.json`) and
  `codex plugin add tern@tern` write `config.toml` (`[marketplaces.tern]`, `[plugins."tern@tern"]`) and
  copy to `plugins/cache/tern/tern/<version>`. **Plugin hooks don't run until trusted**: app server
  `hooks/list {cwds}` lists them (`key` like `tern@tern:hooks/hooks.json:stop:0:0`, `currentHash`,
  `trustStatus: untrusted`, `pluginId`); `config/batchWrite` with
  `{"keyPath":"hooks.state","mergeStrategy":"upsert","value":{<key>:{"trusted_hash":<hash>}}}` makes them
  `trusted` (`[hooks.state."<key>"] trusted_hash = "sha256:…"` in config.toml).

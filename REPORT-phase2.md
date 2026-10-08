# Tern: phase 2 report (managed agents)

Phase 1's report follows this part, unchanged.

## What was built

Managed Claude Code and Codex sessions, controlled from `tern agent …` and shown in panes.

- **The real harnesses, headless.** Claude runs as `claude -p --input-format stream-json
  --output-format stream-json --verbose --replay-user-messages --permission-prompt-tool stdio`
  (the CLI itself, so it loads CLAUDE.md, settings, skills, MCP servers, plugins, hooks and
  subagents as in your terminal); Codex as a private `codex app-server --listen stdio://` per
  session (never your shared Codex daemon). Model, effort, access, extra arguments and `--env` are
  kept for every resume.
- **Exactly-once delivery, truthful status.** Tern keeps its own queue and hands a harness one
  message at a time; a message's id is the one the harness echoes back, and delivery is what the
  harness confirms. Redirects (`send --interrupt [--drop-queued]`) go first and interrupt only the
  turn that was running; a turn that doesn't stop within 30 s gets its harness restarted.
- **Send and it runs.** A message to a stopped, crashed or restarted session resumes the same
  conversation; a turn cut off by a quit, crash or update continues by itself at the next launch
  with a short note. A conversation the harness no longer has, or a folder that's gone, fails the
  message at once with the reason.
- **Nothing left running.** Every process a session starts is found by an environment tag (even
  detached ones), and stopped with SIGTERM then SIGKILL; leftovers of a killed app are stopped at
  the next launch.
- **Composition.** `self`, parents, `agent watch --notify` (a supervisor gets a follow-up when a
  worker's turn ends, needs input or exits), worker reports (`agent report`, `agent wait
  --report`), what each worker loaded (`startup`, with a warning line when an MCP server failed or
  needs auth), approvals and questions (allow once / always for the session / deny; one answer per
  question), MCP elicitation (Codex).
- **Workers know their situation.** A few appended system-prompt lines (Claude) or developer
  instructions (Codex): a managed session nobody may be watching, its name, id, parent and
  folder, and how to report and reach other sessions.
- **Sessions in panes.** A session is drawn over an ordinary terminal pane (its shell, in the
  session's folder, is a toggle away), so it splits, moves, swaps, zooms, closes and undoes, drags
  and comes back after a restart like any pane. The view shows both sides (Markdown replies, code
  set apart), tool calls that expand to their output, cards for approvals and questions, queued
  messages, and a composer (Enter sends, Shift+Enter adds a line, Esc interrupts; drafts are kept).
  `agent start` opens a new tab by default without taking focus; `--focus`, `--split`,
  `--new-window`, `--background`. The sidebar's second line shows a session's status and activity;
  ⌃⌘J jumps to the session that needs you; the command palette lists every session. Desktop
  notifications when a session needs you or finishes out of sight.
- **Phase 1's open item** fixed: the editor's tab row scrolls to the active file.

Where things are:

| Path | What |
|---|---|
| `app/macos/Sources/Features/Tern/Agents/` | the engine (`TernAgentSession`, `TernAgents`), drivers (`TernClaudeDriver`, `TernCodexDriver`), processes (`TernHarnessProcess`, `TernProcessTree`), environment (`TernAgentEnvironment`), storage (`TernAgentStore`), RPC (`TernAgentRPC`), panes (`TernAgentUI`, `TernAgentPane`, `TernAgentTranscriptRenderer`) |
| `app/macos/TernCLI/agent.swift` | `tern agent …` |
| `<state dir>/sessions/<id>/` | a session's `session.json` and `log.jsonl` |
| `acceptance/tests/test_tern_agents_extra.py` | tests added for this design's risks |
| `app/macos/TernTests/verify_agent_panes.py` | agent-pane UI paths checked without the accessibility tree |
| `acceptance/reference/agent-probes/probe_phase2b.py`, `agent-logs/X15wake*.jsonl` | the Codex self-started-turn probe |

## How your orchestrator uses the CLI

Inside a Tern pane or a managed session, `tern` is on PATH and reaches the right instance. Session
names make good slugs.

```sh
# Start (prints the session id). Full access, its own worktree, a model and effort; the pointer is
# the first message. Shown in a new tab without taking focus; --background shows nothing.
tern agent start claude --name fix-login --worktree fix-login --full-access --model opus --effort high \
  "Do the task in .supervise/fix-login/task.md"
tern agent start codex --name review-api --full-access --model gpt-6-luna --effort low \
  -- -c model_verbosity=low        # anything after -- goes to the harness

# Wait for the turn to end: DONE 0, NEEDS_INPUT 2, INTERRUPTED/FAILED/EXITED/ERROR/CANCELLED 3,
# TIMEOUT 124. Prints the status, then the reply (or the pending questions). It keeps waiting
# across a Tern restart.
tern agent wait fix-login --timeout 1200
# Or wait for the worker's own verdict: done 0, blocked 2, failed 3, timeout 124 (+ harness state).
tern agent wait fix-login --report --timeout 3600

# Read: the last reply, a given message's reply, or the transcript.
tern agent read fix-login
tern agent read fix-login --transcript --last 30

# Follow up (queued if it's busy; a stopped session resumes). Prints the message id.
m=$(tern agent send fix-login "The test still fails on CI; check the timezone handling.")
tern agent wait fix-login --message "$m"

# Redirect: interrupt what it's doing and make this next (--drop-queued drops older follow-ups).
tern agent send fix-login --interrupt "Stop: don't touch the schema. Revert that and continue."

# Answer what it asks (when not in full access): approvals and questions.
tern agent info fix-login                    # shows pending requests with their ids
tern agent approve fix-login [r3] [--always] # deny: tern agent deny fix-login --message "why"
tern agent answer fix-login --answer 1=blue --answer 2=L

# Get woken instead of polling: a follow-up message arrives in SUPERVISOR's session.
tern agent watch fix-login --notify self     # from inside a managed session
# Claude Code orchestrator in a pane: run `tern agent wait …` with run_in_background.

# Status, stop, list, resume after a restart.
tern agent ls                                 # every session, status, latest report
tern agent interrupt fix-login                # stop the turn, keep the session
tern agent stop fix-login                     # end its work and everything it started; resumable
tern agent rm fix-login --force               # forget it
```

Workers report with `tern agent report done|blocked|failed "summary"` (they're told how). An idle
harness only means nothing is running now, not that the task is done, and a Claude worker can start
working again by itself when a background command it started finishes; `agent wait --report` and
`agent info` show the worker's verdict next to what the harness says.

For the `supervise-workers` skill, the Tern track is: write the task file, `tern agent start … "Do
the task in .supervise/<slug>/task.md"`, `tern agent wait <slug>` (or `--report`), read the report,
check the evidence, `tern agent send <slug> …` to follow up, `tern agent stop <slug>` when accepted,
`tern agent ls` to rebuild state after a restart. A managed orchestrator can replace the watcher
scripts with `tern agent watch <slug> --notify self`.

## Decisions

Details, candidates, costs and evidence: DECISIONS.md §9–§17.

| # | Decision | Pick | Evidence |
|---|---|---|---|
| 9 | Controlling a harness | The real CLIs headless: `claude -p` stream-json (the CLI, not the SDK, so it loads the terminal's configuration) and a private `codex app-server` per session over stdio. Not Claude's background agents (no programmatic follow-up API, the user's shared daemon) and not the TUI (screen control). | The real-agent tests (project CLAUDE.md/AGENTS.md, a project skill, a project MCP server + hook + subagent in a never-opened folder and after a resume, approvals, interrupts, orchestration, cut-off turns); flags checked against Claude Code 2.1.292 and codex-cli 0.160.0 |
| 10 | Message and turn tracking | The product's own queue, one message in the harness at a time; ids the harness echoes; delivery = the harness's confirmation; redirects go first and interrupt only the running turn (30 s → restart); after a product crash Codex is asked which messages its thread has | `test_chaos.py` (Hypothesis + bursts under 8 chaos seeds per harness), the MA-4/MA-25 tests, extra tests for the crash and handover windows; the Codex probe (no self-started turns) |
| 11 | Where sessions live | The app owns the harnesses; sessions stop at quit; everything on disk; send-and-it-runs; cut-off turns continue with a note | The MA-24, R-2, R-3, R-8, R-10 tests (fakes and real) |
| 12 | Stopping everything | Session-leader harnesses with no inherited descriptors; every descendant found by an environment tag (detached ones too) plus the process group; SIGTERM then SIGKILL; leftovers of a killed app stopped at launch | MA-9, MA-10, R-1 tests (SIGTERM-ignoring harness and detached child) |
| 13 | Sessions in panes | Drawn over an ordinary terminal leaf (phase 1's door): every pane operation and restoration unchanged; the shell underneath is a toggle away | AP-2, AP-3, AP-4, AP-11 tests; `verify_agent_panes.py` |
| 14 | Focus | Non-focusing opens edit the model only; an agent pane's keyboard focus is its composer | `test_opening_without_focus_never_moves_the_users_focus`; `verify_agent_panes.py` |
| 15 | Environment and awareness | The login shell's environment (never the caller's), the app's own `tern` first on PATH, a few appended instructions about the session; startup report with flags | MA-20, MA-27, MA-29 tests (fakes and real) |
| 16 | Persistence | A folder per session (`session.json` + append-only `log.jsonl`), owner-only; tool output clipped in storage | R-2, R-8, R-9 tests |

## Compromises

Full table: COMPROMISES.md (phase 2 part). No fixed- or core-tier test fails, so none is an
accepted test failure. In short:

- **No steering:** a follow-up waits for the running turn to end (negotiable; it keeps exactly-once
  delivery and redirects exact).
- **The pane renders the session**, not the harness's own TUI (the shell is a toggle away).
- **Sessions stop when Tern quits** (your choice); running turns are interrupted cleanly and continue
  after the next launch, with a note.
- **After a crash of the whole product**, a message written to Claude in the instant before counts
  as delivered (Claude can't be asked; Codex is).
- **Codex:** a deny carries no message; MCP elicitation forms and links are Codex-only.
- `agent wait` on Codex holds its answer up to 5 s while MCP servers report in.
- Tool output is clipped in storage (first 12 KB and last 4 KB).
- `update --now` refuses while agent turns run unless `--force`.
- Agent notifications are off in isolated test instances; an agent pane drags by the grip in its
  header.

## Codex review

`codex review --base 4d4a1fe32 -c model_reasoning_effort="high"` in `app/` (logs:
`logs/p2-review1.log` … `p2-review5.log`). After each round, every high (P1) and moderate (P2)
finding was fixed, the app rebuilt, the full suite rerun (and the extra tests and
`verify_agent_panes.py`), and a regression test added where the finding could be scripted.

| Round | Findings | What was fixed |
|---|---|---|
| 1 | 2 P1, 9 P2 | "Allow always" for Codex permission requests matched on a truncated key (now the whole canonical JSON); `agent wait` evaluated and registered in two steps (now one step on the agent queue); recovered messages whose conversation can't resume now fail with the reason; a partial last log line left by a crash is cut off before new entries are appended; stale continuation notes are dropped from a restored queue; a redirect arriving before a turn is acknowledged interrupts that turn when it starts; MCP form answers take the schema's types; agent notifications are presented while Tern is active and clicks are handled on the main thread; waits end when their session is removed; an update download rechecks running turns. |
| 2 | 2 P1, 7 P2 | Writes to a harness happen on its own queue (a harness that stops reading can't block every session); after a crash a Codex message is only counted delivered if the thread's history has it (a fresh thread counts as "none"); a redirect is cleared when its harness exits; cut-off messages fail when the session can't start (folder gone, harness missing); `agent interrupt` before Codex names the turn is applied when it does; an invalid `--pane`/`--window` fails before anything starts; notification authorization is requested; `agent open` of a pane showing its shell shows the session; multi-select questions. |
| 3 | 1 P1, 3 P2 | The final process sweep at quit runs even when no harness is live (a detached child of a harness that just crashed survived a quit); a self-started turn's continuation keeps its recovery marker until it ends; an explicit `--pane`/`--window` overrides a stale caller identity (a regression from phase 1's round 5, in `tab new` and `tern claude`); no Decline button for Codex questions (its protocol can't decline). |
| 4 | 2 P1, 2 P2 | The process group a harness led is cleaned up after it exits (a child that cleared its environment escaped the tag), safely: only when no process holds the group's id; every session, not only live ones, is marked at quit (a launching session could start during the shutdown); a wait keeps the message that was latest when it began; notifications when the session's pane shows its shell or is behind a zoomed pane. |
| 5 | 1 P1, 4 P2 | A recovered turn whose resumed harness dies at startup is retried, then failed with the reason (it stayed pending); session files are owner-only (`--env` values may be secrets); background commands are tracked per harness process (a stopped one was counted again); timeout answers name their own message; a wait whose client disconnected is dropped. Also found while checking: `agent stop` now ends a pending recovery. |

Round 5 was the last round the brief allows, so its fixes haven't had a review of their own. They
have regression tests where they could be scripted, and the suite, the extra tests and both
verification scripts pass on the released build.

Found outside the reviews, while testing: Codex approval answers carried request id `0` as `false`
(a JSON conversion bug) and the real Codex ignored them; the fake accepted them (Python treats
`False == 0`). Fixed in the app, and the fake now matches ids by type, with a self-test. The agent
pane overflowed narrow panes, the screenshot command painted terminals over agent panes, and the
editor's tab row hid the active file in narrow panels (phase 1's open item); all fixed.

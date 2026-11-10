# Things to build on the primitives

Behaviour Alejo said he might want, written as skills, palette commands, key bindings, config and
scripts on top of the design. None of it is built into Umi; each piece uses commands from
[cli.md](cli.md). Skills go in `~/best/areas/dotfiles/skills/`; palette commands are executables in
`~/.config/umi/commands/` (both kept in dotfiles); config lines go in `~/.config/umi/config`.

| # | Idea | Built as | Needs from Umi beyond the design |
|---|---|---|---|
| 1 | Become the manager | skill | nothing |
| 2 | Defer this pane | skill and palette command | nothing |
| 3 | Hide until it needs me | palette command and key | nothing |
| 4 | Delegate to the manager | palette command and key | nothing |
| 5 | Important panes | config and key | nothing |
| 6 | Review walk | config and key | nothing |
| 7 | Status line from the agent | skill line and hook | nothing |
| 8 | Organize into tabs | skill and palette command | nothing |
| 9 | Split tab by project | palette command | nothing |
| 10 | End-of-day focus report | script | nothing |
| 11 | Return digest | script | an `app.activated` event |
| 12 | Project focus | palette command | a way to dim or collapse tabs |
| 13 | Links on panes | palette command | nothing |

## 1. Become the manager

A skill an agent runs to take the manager role, so ⌃⌘M brings it up in the drawer.

- `umi pane set role=manager` on its own pane (the role moves from whichever pane had it).
- Its loop: `umi events --filter pane.changed` to notice delegated panes whose agent stopped;
  `umi ls --where 'owner=manager'` to list them; `umi read` and `umi send` to answer what it can.
- What it can't settle, it hands back: `umi pane show P` or `umi pane move P --back`, plus
  `umi pane set P escalated=true`, which the user's `jump` list can include.
- It reports in its own pane, so its indicator shows its state like any other.

## 2. Defer this pane

"Move me out of the way": a skill an agent can run on itself, and a palette command for the user.

- If no tab is named Deferred, `umi tab new Deferred --no-focus` (new tabs opened in the background
  go last); then `umi pane move . --tab Deferred --no-focus`.
- Optionally `umi pane set . deferred_at=now note="…"`, so the Deferred tab's panes can be listed and
  sorted later.
- `umi pane move P --back` returns one to where it was.

## 3. Hide until it needs me

⌃⌘H hides the focused pane and brings it back by itself. It's one config line plus the condition:

```
key.ctrl+cmd+h = pane hide . --until 'agent.done=false or agent.status=needs_input'
```

- The pane leaves the layout, stays in its tab's strip, and keeps running.
- It comes back to its tab, without taking focus and with its indicator showing why, when the agent
  asks for something or ends a turn without `Status: done`.
- When the agent finishes with `Status: done`, it stays hidden; its chip in the strip shows it
  finished.

Variants, each its own key or palette command:

- back when the turn ends, done or not: `--until 'agent.status=idle or agent.status=needs_input'`;
- back after a time limit as well: add `--until 2h` (whichever holds first);
- for a pane with no agent, back when its command finishes: a script that waits for the prompt
  (`umi wait --pane P --idle 5`) and then runs `umi pane show P`.

⌃⌘H is free in Umi and macOS.

## 4. Delegate to the manager

A palette command bound to a key: `umi pane set . owner=manager` and `umi pane hide .`. The manager
skill handles the rest. Alternative without hiding: move the pane to a tab the manager watches.

## 5. Important panes

```
key.ctrl+cmd+i = pane set . priority=high      # toggled by a small command script instead, if preferred
list.important = priority=high | sort -priority, status_since
landing        = @important after 15m away
key.ctrl+cmd+] = go --next @important
```

(`cli.md` doesn't fix the config syntax for slots yet; the `landing` line shows the intent.)

## 6. Review walk

`key.ctrl+cmd+u = go --next @unseen` with `list.unseen = changed_at > seen_at | sort changed_at`.
Each visit sets `seen_at`, so the list shrinks as you go; ⌃⌘K returns.

## 7. Status line from the agent

A line in the user's CLAUDE.md or a small skill: "when you start a new phase of work, run
`umi pane set . status='…'`". With the `sidebar.line2` slot set to `{status or agent.title or command or
cwd}`, the sidebar shows it. A Stop hook can also write `agent.summary` from the agent's last line.

## 8. Organize into tabs

A skill started from ⌘P. It reads `umi ls --json` (folders, branches, files, agent titles,
attributes), proposes groups as a dry run the user approves, then applies them with `tab new`,
`pane move` and `tab rename`.

## 9. Split tab by project

A palette command, no agent needed: group the current tab's panes by git repository root (from
each pane's `cwd`), keep the largest group, and move each other group into a new tab named after
its repository. Panes outside any repository stay.

## 10. End-of-day focus report

A script over `umi focus-log --since 6am --json`, grouping time by file, agent session or
`project=`, and writing a short note (for example into the desk's day log). It counts keyboard
focus only.

## 11. Return digest

When Umi becomes active after a long absence, a script counts `@unseen`, `@needs-you` and
`agent.status=working` and shows them with `umi notify` or in the drawer. **Needs:** an event when
Umi becomes active (`app.activated`, with how long it was away); `cli.md` has none.

## 12. Project focus

A palette command that shows only the tabs with a pane matching `project=X`. **Needs:** a way to
dim, collapse or filter tabs in the sidebar. Tab search (`warp/parity`) filters by text; it could
take a query instead.

## 13. Links on panes

`umi pane set . pr=https://…` or `desk=…`; a palette command "Open link" opens the focused pane's
`pr` or `desk` attribute.

## 14. How agents feed the indicator

The indicator reads `agent.status`, which Umi's hook plugin writes from each agent's hooks. Tested
for real on 9 November 2026 with Claude Code 2.1.319 and codex-cli 0.164.0
(`acceptance/reference/agent-logs/2026-11-09-hooks/` has every hook input they sent). Umi 0.14.0
maps each state this way:

| State | Claude Code sends | Codex sends | Umi shows |
|---|---|---|---|
| started | `SessionStart` at launch | `SessionStart` only with the first prompt, also on `codex resume` | `idle`; a Codex pane shows nothing until its first prompt |
| working | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | the same, and `PreModelRequest` before each model request | `working` |
| a command fails | `PostToolUseFailure` | `PostToolUse` (the exit code is in its output) | `working`: the turn goes on |
| a question | `PreToolUse` and `PermissionRequest` for `AskUserQuestion` | `PreToolUse` for `request_user_input` (Plan mode only) | `needs_input` |
| a permission prompt | `PermissionRequest` (then `Notification` `permission_prompt` about 6 s later) | `PermissionRequest` | `needs_input` |
| the prompt answered "no" | nothing | `Interrupt` | Claude Code: stays `needs_input` until its next hook (Esc: `idle` as an interrupt); Codex: `idle` |
| finished | `Stop` | `Stop` | `idle` (`working` while Claude Code's background tasks run) |
| interrupted (Esc, Ctrl-C) | nothing | `PostModelRequest` `cancelled`, then `Interrupt` | Claude Code: `idle` two seconds after the key; Codex: `idle` at once |
| failed (API error, unknown model) | `StopFailure` with `error` (such as `model_not_found`) and the reason as `last_assistant_message` | `PostModelRequest` with `status: failed` and the API's error JSON in `error`; no `Stop` | `error` |
| a retried request | (inside one turn, no hook) | `PostModelRequest` `failed`, then `PreModelRequest` | `error`, then `working` again |
| idle a minute | `Notification` `idle_prompt` | nothing | no change |
| exited | `SessionEnd` (`prompt_input_exit`) | `SessionEnd` (`other`) | `stopped` |
| killed or crashed | nothing | nothing | `stopped` once the process is gone |

The other attributes come out the same for both:

- **`agent.summary` and `agent.done`**: both agents' `Stop` carries the reply as
  `last_assistant_message`, so neither needs its transcript. The summary is the reply's first line;
  `done` is whether its last line starts with `Status: done`. A failed turn has no reply: the
  summary is the reason (Claude Code's message, or the `message` in Codex's error JSON), and `done`
  is false.
- **`agent.title`**: the first `UserPromptSubmit`'s prompt, for both.
- **`agent.session`**: `session_id`, Claude Code's session and Codex's thread, for both.

What the agents can't report, so Umi doesn't show it (SPEC AG-19):

- **A Codex that hasn't had a prompt yet.** Codex runs no hook until its first prompt, so a freshly
  typed or resumed Codex isn't an agent to Umi until then. After a relaunch, a resumed Codex shows
  `stopped` until it gets a prompt.
- **A Claude Code permission prompt answered "No" from its list.** It sends nothing, so the pane
  stays `needs_input` until the next prompt. Esc on the prompt counts as an interrupt (below).
- **A Codex MCP server asking the user something** (an elicitation): no hook.
- **A Claude Code interrupt** sends nothing either: Umi takes a turn with no hook for two seconds
  after Esc or Ctrl-C as interrupted.

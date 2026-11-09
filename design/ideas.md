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

The indicator reads `agent.status`, which Umi's hook plugin writes from each agent's hooks. The two
agents report different things:

| State | Claude Code | Codex |
|---|---|---|
| working | `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | the same three |
| needs you: approval | `PermissionRequest` | `PermissionRequest` |
| needs you: a question or an idle prompt | `Notification` | no matching hook in Umi's Codex plugin |
| error | `StopFailure`, `PostToolUseFailure` | no matching hook |
| finished | `Stop` | `Stop` |

So with Codex, a question to the user or a failed turn may show as finished instead of "needs you".
To check before relying on it: which Codex events cover questions and failures, and whether each
agent's `Stop` hook input carries the last message (needed for `agent.done`) or only a transcript
path to read it from.

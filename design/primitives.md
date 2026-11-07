# Primitives

What the user, their scripts and their agents build on. Everything here is reachable from the `umi`
CLI, which is rewritten from scratch around it; `acceptance/CLI.md` is rewritten to match.

## Attributes

Panes, tabs and windows carry key–value pairs.

- **The user's and scripts':** `priority=high`, `project=impact-ops`, `status="reviewing PR"`.
- **Written by the agent hook plugin** (Claude Code and Codex): `agent.kind`, `agent.status`
  (working, needs_input, idle, stopped, error), `agent.title`, `agent.summary`, `agent.done`.
- **Kept by Umi, read-only:** `kind`, `cwd`, `branch`, `command`, `focused`, `hidden`, `seen_at`,
  `changed_at`, `status_since`, `idle_for`.

Attributes live and die with their pane; the next agent's hooks overwrite `agent.*`. Some
attributes have a single holder: `role=manager` can be on one pane only, and setting it moves it.

Attention is facts, not flags: "unseen" is `changed_at > seen_at`, and "needs you" is
`agent.status=needs_input`.

`umi pane set [PANE] key=value`, `umi pane unset [PANE] key`. Attributes appear in `ls --json`,
and each change is an event.

## Queries and lists

A query picks and orders panes, anywhere a selector is accepted:

```
priority=high and not hidden | sort -priority, status_since
```

A named list is a saved query in `~/.config/umi/config`:

```
list.needs-you = agent.status=needs_input | sort status_since
```

## Slots

The decisions Umi makes instantly. Each reads a list or a template; the defaults are Umi's current
behaviour. The set is fixed and documented, and grows one slot at a time.

| Slot | Default |
|---|---|
| `jump` (next pane that needs you) | `needs-you`, then unseen |
| `badge` (Dock count) | count of `needs-you` |
| `landing` (pane focused on returning after N minutes) | none |
| `tab.summary` (which pane speaks for a tab in the sidebar) | the focused pane's agent, else the one most in need, else the latest stop |
| `sidebar.line2` | `{agent.title or command or cwd}` |
| `strip.make-room` (which pane is hidden when one comes in) | least recently used, skipping `pinned` |
| `indicator.<state>` | the quiet colours in [attention-ui.md](attention-ui.md) |

## Actions

Every action takes a query as its target.

- `set` / `unset` an attribute.
- `hide` / `show`. `hide --until CONDITION` brings the pane back by itself.
- `move` to a tab by name, or back to where it came from.
- `go LIST`, `go --next LIST`, `go --back`: put a list's first pane in front of the user (its tab,
  its window, Umi), walk the list, return.
- `drawer show|hide|toggle QUERY`.
- Every layout action Umi has today.

## Keys and palette commands

`key.<keys> = <action>` binds any action, list or command. Each executable in
`~/.config/umi/commands/`, or a `command."Title" = …` line, is a ⌘P entry and can be bound to a key.
It runs with the calling pane, tab and window in its environment. Skills such as a manager or
"Organize into tabs" start from here.

## Rules

Reactions to events live in the user's own scripts, which read `umi events` and call `umi`, plus
`--until` conditions on actions. Umi has no rules engine.

## Logs

- **Activity log:** every change Umi makes or sees, with its cause (a key, the palette, a script, a
  hook, Umi itself): panes created, moved (from where to where), hidden, shown, closed; attributes
  set; agent status changes. `umi log --since … --json`; `umi events` streams it. "Move back" reads
  a pane's last move from it.
- **Focus log:** each stretch during which a pane had keyboard focus in Umi's front window, while
  Umi was the active app, the screen was unlocked and the user had typed or clicked in Umi within
  the last few minutes, with what the pane showed (file, agent session and title, cwd,
  attributes). `umi focus-log --since 9am --json`. It measures keyboard focus, not where the user
  looked.

## Open

- The query syntax: this small one, or an existing expression language.

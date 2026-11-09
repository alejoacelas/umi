# The `umi` CLI contract (proposed)

This replaces `acceptance/CLI.md` when the design in this folder is implemented. Agents and scripts
depend on this surface, so it is fixed: anything not listed here is free. Output for people is
free-form unless stated. With `--json`, the listed fields must be present; extra fields are fine.

## Choices made in this draft

These are not settled by the other design documents; each is marked "(decided here)" where it
appears.

1. Attribute values are strings. Comparisons are numeric when both sides read as numbers,
   durations (`5m`) or times; otherwise text.
2. In a query, `@NAME` stands for a named list, and a bare key (`pinned`) means the key is set and
   isn't `false`.
3. Commands that act on one pane (focus, info, read) take a query's first match; commands that
   change panes (set, hide, show, move, close) act on every match.
4. `--until` takes a query about the pane itself, a duration, or both; the first to hold wins.
5. `go` keeps one walk per window. `go --back` returns to the pane focused before the walk's first
   step.
6. A pane in the drawer leaves its tab. `drawer dock` puts it into the current tab's layout;
   hiding it puts it back in the tab it came from, hidden.
7. Agent status changes are ordinary `pane.changed` events with key `agent.status`.
8. Every event carries `cause.kind`: `key`, `mouse`, `palette`, `cli`, `hook`, `config` or `umi`.
   Commands run from the palette or a key binding get `UMI_CAUSE` in their environment, so their
   own `umi` calls are recorded with that cause.
9. The activity log and the focus log keep 30 days. A focus stretch ends after 3 minutes without
   typing or clicking in Umi.
10. The Docs tab is the tab with the tab attribute `role=docs`, which one tab at a time can hold.
11. `tab back` (the tabs visited, most recent first) is removed; `go --back` covers returning.
12. Read-only attribute names can't be set; setting one fails with exit 1.
13. Hiding the last pane on show in a tab fails with exit 1.
14. `wait --attr QUERY` waits until the pane matches a query, for scripts waiting on an agent.
15. The config defines a list `manager` (`role=manager`) by default, and ⌃⌘M runs
    `drawer toggle @manager`.

## General

- `--json` before the command, or anywhere before a `--` separator, prints JSON instead of text.
- Exit codes:

  | Code | Meaning |
  |---|---|
  | 0 | success |
  | 1 | usage error, unknown selector, a selector or list that matched nothing where something is required, failed action |
  | 124 | a wait timed out |

- Errors go to stderr, prefixed `umi: `.
- Inside Umi's panes, pane, tab and window arguments default to the calling pane and its tab and
  window (the pane named by `UMI_PANE`, which every Umi pane and every palette or key command
  has). Elsewhere they default to the focused ones.
- Text arguments: words are joined with spaces. `-` alone reads the text from stdin. Text after
  `--` is text even if it starts with dashes. No command reads stdin unless given `-`, except
  `send` with no text and a piped stdin, `edit` with no file, and `hook`.
- Times on the command line are ISO 8601, a clock time today (`9am`, `14:30`), or a duration back
  from now (`2h`). Times in JSON are ISO 8601 with a time zone.

### Selectors

`--pane`/`-p`, `--tab`/`-t` and `--window`/`-w`, and positional PANE, TAB and WINDOW arguments,
take a selector:

- an id or a unique id prefix; a name the user gave; `.` (the focused one); `#N` (tabs and windows,
  by index from 1);
- a **query**: any selector containing `=`, `<`, `>`, `|`, `@`, ` and `, ` or ` or `not `. Queries
  select panes; a tab or window selector that is a query selects the tabs or windows holding a
  matching pane.

An unknown or ambiguous id, prefix or name fails with exit 1 and changes nothing. A query that
matches nothing fails with exit 1 for commands that need a target, and succeeds with an empty
result for `ls`.

### Queries

```
QUERY  := EXPR [ "|" "sort" KEY ["," KEY]… ] [ "|" "limit" N ]
EXPR   := TERM | EXPR "and" EXPR | EXPR "or" EXPR | "not" EXPR | "(" EXPR ")"
TERM   := KEY OP VALUE | KEY | "@" LIST
OP     := "=" | "!=" | "<" | "<=" | ">" | ">="
KEY    := an attribute name (letters, digits, ".", "-", "_")
VALUE  := a word, or text in double quotes
```

- `and` binds tighter than `or`. Keys and list names are case-sensitive; values compare exactly.
- A bare `KEY` holds when the key is set and its value isn't `false` (decided here).
- `@NAME` holds for the panes in the named list `NAME` (decided here).
- Values compare as numbers when both sides read as numbers, as durations when both read as
  durations (`90s`, `5m`, `2h`), as times when the attribute holds a time and the value is a time
  or a duration back from now (`status_since < 10m` holds for a status older than 10 minutes);
  otherwise as text (decided here).
- `sort KEY` sorts ascending; `-KEY` descending. Panes missing the key sort last. Ties keep the
  order of `ls`.
- Without `sort`, matches come in `ls` order: windows by index, tabs in sidebar order, panes on show
  in layout order (left to right, top to bottom), then hidden panes in strip order.
- `tab.KEY` reads the attribute KEY of the pane's tab: `tab.archived=true` holds for the panes of
  archived tabs (design/archive.md). Panes can't hold keys starting with `tab.`.
- A query that doesn't parse fails with exit 1 and names the position of the error.

## Objects in JSON

- **Window**: `{"id", "index", "selected_tab": id, "tabs": [Tab], "drawer": {"open": bool,
  "panes": [Pane]}, "archive": {"open": bool, "tabs": [id]}, "attributes": {…}}`. The archive's
  `tabs` are in the order they were archived.
- **Tab**: `{"id", "index", "title", "name"?, "selected": bool, "pinned": bool, "archived": bool,
  "archive_until"?: [condition], "color"?, "group"?:
  its tab group's name, "focused_pane": id, "visible_limit": int, "strip": [id] (every pane's chip,
  in strip order), "panes": [Pane], "attributes": {…}}`. `panes` lists the panes on show in layout
  order, then hidden ones in strip order.
- **Pane**: `{"id", "kind": "terminal"|"file"|"web", "title", "name"?, "cwd", "focused": bool,
  "zoomed": bool, "hidden": bool, "in_drawer": bool, "indicator": "working"|"needs_you"|"finished"|"none",
  "frame"?: {"x", "y", "width", "height"} (points, top-left origin, in the window's terminal area;
  panes on show only), "file"?: path, "url"?: address, "attributes": {key: value}}`.
  `attributes` holds every attribute: the user's, `agent.*`, and Umi's read-only ones.
- **Event**: `{"event": name, "at": time, "cause": {"kind", "command"?, "key"?, "pane"?},
  "data": {…}}`.

Pane `title` is its name, else `agent.title`, else what its program set, else its folder.

## Attributes

| Command | Notes |
|---|---|
| `pane set [PANE] KEY=VALUE…` | sets each pair on every matching pane; `KEY=` with an empty value sets the empty string. JSON `{"panes": [id], "set": {key: value}}` |
| `pane unset [PANE] KEY…` | removes the keys; unsetting a missing key is not an error |
| `tab set\|unset [TAB] …`, `window set\|unset [WINDOW] …` | the same on tabs and windows |
| `pane get [PANE] [KEY…]` | prints the values (all attributes without KEY); JSON `{"pane": id, "attributes": {…}}` |

- **Read-only keys** (kept by Umi; setting one fails with exit 1, decided here): `kind`, `cwd`,
  `branch`, `command`, `focused`, `hidden`, `in_drawer`, `seen_at`, `changed_at`, `status_since`,
  `idle_for`, and on tabs `visible_count`.
- **Keys written by the hook plugin**: `agent.kind` (`claude`|`codex`), `agent.status` (`working`,
  `needs_input`, `idle`, `stopped`, `error`), `agent.title`, `agent.summary`, `agent.done`
  (`true`|`false`), `agent.session` (the harness's session id). Anyone may write them; the next
  hook event overwrites them.
- **Keys with a meaning to Umi**:
  - `pinned` (panes): never hidden to make room.
  - `role`: one holder per value, among panes for panes and among tabs for tabs. Setting
    `role=manager` on a pane removes it from the pane that had it. The Docs tab is the tab with
    `role=docs` (decided here).
  - `visible_limit` (tabs): how many panes the tab shows; default 3, at least 1.
  - `archived` (tabs): `true` while the tab is archived, else `false`. Setting it archives the tab or
    brings it back, as `tab archive|unarchive`.
- Attributes live and die with their pane (or tab, window). They are saved and restored with the
  layout.

## Layout

Kept from today unless noted.

| Command | Notes |
|---|---|
| `ls [--where QUERY]` | JSON `{"windows": [Window], "current_tab": id, "current_pane": id}`. With `--where`: `{"panes": [Pane + "tab", "window"]}`, in query order |
| `window new [--cwd D] [--cmd C] [--name N] [--worktree W [--base REF]] [--no-focus]` | prints the new pane's id; JSON `{"pane", "tab", "window"}` |
| `window focus\|close [WINDOW]` | |
| `tab new [NAME] [--window W] [--pane P] [--cwd D] [--cmd C] [--name N] [--color C] [--index I] [--worktree W [--base REF]] [--no-focus]` | as `window new`; the tab opens after the current tab, or last with `--no-focus`, or at `--index` |
| `tab focus\|close\|equalize [TAB]` | |
| `tab next\|prev [--window W]` | next or previous tab in sidebar order, wrapping (⇧⌘] / ⇧⌘[ and ⌃Tab / ⌃⇧Tab). JSON `{"tab", "window", "index", "title"}` |
| `tab rename [TAB] NAME` | `""` clears |
| `tab color [TAB] COLOR` | red green yellow blue magenta cyan purple pink orange teal graphite none |
| `tab pin\|unpin [TAB]` | an archived tab can't be pinned |
| `tab archive [TAB] [--until CONDITION]…` | (⌃⌘A) into the window's archive at the top of the sidebar, still running, out of its tab group and unpinned. `--until` as on `pane hide`, a query about any of the tab's panes or a duration. JSON `{"tab", "tabs": [id]}` |
| `tab unarchive [TAB]` | back to the top of the unpinned tabs; clears its conditions. JSON `{"tab", "tabs": [id]}` |
| `tab move [TAB] (--window W [--index I] \| --index I \| --up \| --down \| --new-window) [--no-focus]` | `--up`/`--down` (⌃⇧↑ / ⌃⇧↓): one place within the pin group and tab group, past a whole neighbouring group; fails at the end of the group. `--up` on the first tab archives it; `--down` on an archived tab brings it back |
| `split [right\|down\|left\|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus] [--worktree W]` | prints the new pane's id. When the tab already shows its limit, `strip.make-room` hides one; JSON `{"pane", "hid"?: id}` |
| `pane focus [PANE]` | a hidden pane is brought in first (it takes the right end of the tab; `strip.make-room` hides one); JSON `{"pane", "tab", "window", "hid"?}` |
| `pane close\|info\|zoom [PANE]` | `info` JSON: Pane plus `tab`, `window` |
| `pane rename [PANE] NAME` | `""` clears |
| `pane move [PANE] (--to PANE [--dir D] \| --tab T [--dir D] \| --window W [--dir D] \| --new-tab [--window W] \| --new-window \| --back) [--no-focus]` | the program keeps running. `--tab T` takes any tab selector, names included. `--back` returns the pane to the tab and place of its last move, read from the activity log; fails when there is none. Landing in a tab at its limit hides one there; JSON `{"pane", "tab", "window", "hid"?}` |
| `pane swap [PANE] TARGET` | |
| `pane resize [PANE] up\|down\|left\|right [AMOUNT]` | CLI only; no default keys |
| `reopen [--list]` | as today (60 s). A pane reopened into a tab at its limit hides one there |
| `sidebar [on\|off\|toggle\|status\|tabs\|files\|search] [--window W]` | as on `warp/parity` |
| `sidebar width [N] [--window W]` | as today |
| `screenshot [--window W] OUT.png` | |
| `worktree ls` | |
| `layout ls`, `layout save NAME [--replace]`, `layout open NAME [--no-focus]` | launch configurations, as on `warp/parity`. Saving includes hidden panes, marked hidden; opening a tab with more panes than its limit opens the rest hidden |

Removed: `jump` (use `go`), `tab back` (decided here), and every stack field and option.

## Hidden panes

| Command | Notes |
|---|---|
| `pane hide [PANE] [--until CONDITION]…` | takes each matching pane out of its tab's layout; it stays in its tab and keeps running. Hiding the last pane on show fails with exit 1 (decided here). JSON `{"panes": [id]}` |
| `pane show [PANE] [--focus]` | brings each pane back into its tab (the right end; `strip.make-room` hides one if the tab is at its limit). Keyboard focus stays where it is unless `--focus`. JSON `{"panes": [id], "hid": [id]}` |
| `pane until [PANE]` | lists the pane's pending conditions; JSON `{"pane", "until": [{"query"?, "at"?}]}` |

- `--until` takes a query about the pane itself (`--until 'agent.done=false or agent.status=needs_input'`),
  a duration (`--until 2h`), or both as two options; the first to hold shows the pane (decided
  here). The condition is checked whenever the pane's attributes change and once a minute. Showing
  the pane by any means clears its conditions.
- A pane shown by a condition never takes keyboard focus. Its `changed_at` is set, so it counts as
  unseen until looked at.

## Lists and `go`

| Command | Notes |
|---|---|
| `list ls` | named lists from the config, with their queries and match counts; JSON `{"lists": [{"name", "query", "count"}]}` |
| `list show NAME` | the list's panes, in order; JSON `{"panes": [Pane + "tab", "window"]}` |
| `go LIST\|QUERY` | puts the first pane in front of the user: its window in front, Umi active, its tab selected, the pane brought in if hidden (or the drawer opened if it is in the drawer), focused. JSON `{"pane", "tab", "window"}`. Exit 1 with "nothing in LIST" when empty; nothing moves |
| `go --next LIST\|QUERY` | the next pane of the walk: the first after the one the walk last went to, re-reading the list each time. A new walk starts when anything other than `go --next` moved focus since the last step |
| `go --back` | back to the pane focused before the walk's first step (decided here: one walk per window). Exit 1 when there is no walk |

⌃⌘J runs `go --next jump` and ⌃⌘K runs `go --back`. `jump` is a named list; its default is
"needs you, then unseen, oldest first in each", leaving out panes in archived tabs.

## Drawer

| Command | Notes |
|---|---|
| `drawer show [PANE] [--window W]` | moves the pane into the window's drawer (it leaves its tab) and opens the drawer with that pane on show and focused; without PANE, opens the drawer as it was |
| `drawer hide [--window W]` | closes the drawer; its panes stay in it, keep running, and focus returns to the pane focused before it opened |
| `drawer toggle [PANE] [--window W]` | `show` when closed or showing another pane, else `hide`. ⌃⌘M runs `drawer toggle @manager`, where `manager` is a default list, `role=manager` (decided here) |
| `drawer next\|prev [--window W]` | the next or previous pane in the drawer |
| `drawer dock [PANE]` | moves the pane from the drawer into the current tab's layout, to the right of the focused pane (`strip.make-room` applies) |
| `drawer ls [--window W]` | JSON `{"open": bool, "panes": [Pane]}` |

- A pane in the drawer leaves the drawer when hidden: it goes back, hidden, to the tab it came
  from, or the current tab when that tab is gone (decided here).
- While the drawer is closed, a drawer pane whose indicator is `needs_you` shows the thin line
  along the window's bottom edge with its title.

## Terminal input and output

Kept from today. They work on hidden panes and drawer panes too.

| Command | Notes |
|---|---|
| `send [--pane P] [--enter\|-e] TEXT…` | no TEXT plus a piped stdin sends stdin |
| `keys [--pane P] KEY…` | enter esc tab backspace up down left right ctrl+c shift+tab … |
| `read [--pane P] [--scrollback] [--lines N]` | the text as the shell and programs printed it |
| `wait [--pane P] (--pattern RE \| --idle SECS \| --attr QUERY) [--timeout T]` | prints the matched text; `--attr` (decided here) waits until the pane matches the query (for example `agent.status=idle`) and prints its attributes; 124 on timeout |
| `notify [--pane P] TITLE [BODY]` | a desktop notification |

## Events and logs

| Command | Notes |
|---|---|
| `events [--filter PREFIX]… [--pane P] [--since T]` | streams events as JSON lines (Event objects), with `--since` replaying from the activity log first |
| `log [--since T] [--until T] [--filter PREFIX]… [--pane P]` | the activity log: the same Event objects, oldest first. Kept 30 days (decided here) |
| `focus-log [--since T] [--until T] [--pane P]` | stretches of keyboard focus: JSON `{"stretches": [{"pane", "tab", "window", "start", "end", "seconds", "title", "kind", "cwd", "file"?, "url"?, "agent"?: {"kind", "session", "title"}, "attributes": {…}}]}`. A stretch counts only while Umi is the active app, the screen is unlocked, and the user typed or clicked in Umi within the last 3 minutes (decided here). Kept 30 days |

Event names:

| Event | `data` |
|---|---|
| `pane.created`, `pane.closed` | `pane`, `tab`, `window`, `reopened`? |
| `pane.moved` | `pane`, `from` and `to`: `{"tab", "window", "index"}` |
| `pane.hidden`, `pane.shown` | `pane`, `tab`, `by_condition`? (shown by `--until`) |
| `pane.focused` | `pane`, `tab`, `window` |
| `pane.changed` | `pane`, `key`, `old`, `new`. Agent status changes are this event with key `agent.status` (decided here) |
| `pane.renamed`, `pane.zoomed`, `pane.resized`, `pane.swapped` | as today |
| `tab.created`, `tab.closed`, `tab.moved`, `tab.renamed`, `tab.colored`, `tab.pinned`, `tab.selected`, `tab.changed` | `tab.changed` as `pane.changed`, for tab attributes |
| `tab.archived`, `tab.unarchived` | `tab`, `window`, `by_condition`? (brought back by `--until`) |
| `window.created`, `window.closed`, `window.changed` | |
| `drawer.opened`, `drawer.closed` | `window`, `pane`? |
| `sidebar.changed` | shown, hidden, or width changed |
| `editor.opened`, `editor.saved`, `editor.closed`, `editor.reloaded`, `comments.changed`, `comments.done` | as today |
| `palette.opened`, `palette.ran` | as today |
| `update.*` | as today |
| `layout.restored` | after launch |

`cause.kind` (decided here): `key` (with `key`), `mouse`, `palette` (with `command`), `cli` (with
`command` and the calling `pane`), `hook`, `config` (a `--until` condition or a slot), `umi` (Umi
on its own, such as making room). A command started from the palette or a key binding runs with
`UMI_CAUSE=palette` or `UMI_CAUSE=key:<keys>` in its environment, and the `umi` calls it makes are
recorded with that cause.

## Agent hooks

| Command | Notes |
|---|---|
| `hook EVENT --agent claude\|codex [--pid PID]` | run by Umi's plugins: reads the agent's hook input on stdin, writes `agent.*` on the pane the agent runs in; prints nothing; exit 0 even when no pane matches |
| `plugins [status\|install [--force]\|remove]` | Umi's plugins in Claude Code and Codex. JSON per agent `{"installed", "version"?, "bundled_version"?, "current", "enabled"? (Claude), "hooks_trusted"? (Codex), "agent_installed", "steps"? (install)}` |

`agent.done` is set at each Stop hook from the `done-check` slot. `agent.session` is what Umi uses
to resume the conversation when it relaunches the pane's agent after a quit, crash or update.

## Configuration

Lists, slots, key bindings and palette commands live in `~/.config/umi/config`. These commands
read them; editing is done in the file (⌘, opens it).

| Command | Notes |
|---|---|
| `slot ls` | every slot with its value and whether it is the default; JSON `{"slots": [{"name", "value", "default": bool}]}` |
| `command ls` | palette commands: JSON `{"commands": [{"title", "path"?, "line"?, "keys"?: [str]}]}` |
| `command run TITLE [--pane P]` | runs one as the palette would |
| `shortcuts [ls]`, `shortcuts set ID KEYS`, `shortcuts clear ID`, `shortcuts reset [ID]` | as today; key bindings from the config appear with `"source": "config"` |

A palette or key command runs with `UMI_PANE`, `UMI_TAB`, `UMI_WINDOW` (the caller's), `UMI_CAUSE`,
`UMI_CLI` (the path of `umi`) and `UMI_STATE_DIR` in its environment, in the calling pane's
folder. Its stdout shows in the palette; a non-zero exit shows its stderr as an error.

## Editor

Kept from today, with placement changed.

| Command | Notes |
|---|---|
| `edit FILE\|URL… [--source\|--preview] [--tab T \| --pane P]` | opens each file in a pane of its own, to the right of the calling pane (or the given pane, or the tab's focused pane), each next one to the right of the one before; in a tab at its limit, `strip.make-room` hides one for each. A file already open is shown where it is (brought in if hidden). Keyboard focus stays where it was. Run outside Umi's panes: Markdown goes to the Docs tab (created when missing), other text to the tab with the closest folder (E-10). JSON `{"documents": [{"path", "pane"}], "pages": [{"url", "pane"}], "tab", "window", "hid": [id]}`. `open` is the same command |
| `editor ls [--tab T \| --pane P]` | JSON `{"documents": [{"path", "pane", "mode", "dirty": bool, "hidden": bool}], "active"}` |
| `editor close [FILE] [--force]` | refuses dirty documents without `--force` |
| `editor mode [preview\|source] [FILE]` | |
| `editor default [--dry-run]` | |
| `comments …` | all of today's `comments` commands, unchanged (`ls`, `add`, `reply`, `edit`, `resolve`, `reopen`, `delete`, `wait`) |

## Updates and the app

| Command | Notes |
|---|---|
| `update --check`, `update [--now [--force]]`, `update --status`, `update --rollback [--force]`, `update --later \| --skip` | as today, with "managed-agent turns" read as "panes whose `agent.status` is `working`". In `--status`, `quiet.waiting_for` kinds are `pane`, `editor`, `dialog`, `input` |
| `doctor` | reports whether Umi's CLI is on PATH in its panes and whether the hook plugins are installed and current; exit 0 when they are |
| `help [--json]` | as today; `--json` describes every command above for the palette |

## Removed

Every `agent …` command, the `claude` and `codex` shortcuts, `jump`, `tab back`, the Session,
Report, Message, Request, Item and Startup objects, the `agent` and `stack` pane fields, `shown`,
the tab's `docs` field, and exit codes 2 and 3.

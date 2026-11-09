# CLI contract

`<cli>` is the product's command line tool (the name is the product's choice; see
`TEST_INTERFACE.md`). Agents and scripts depend on this surface, so it's fixed. Anything not listed
here is free. Output for humans is free-form unless stated. With `--json`, the listed fields must be
present. Extra fields are fine.

This is `design/cli.md` as far as the design's steps have landed (design/plan.md). Step 1 took Umi's
own agent sessions out: the `agent` commands are gone, and agents run in panes, reported by Umi's
plugin through `hook` ("Agent hooks" below). Step 2 brought pane data: attributes and `pane set`,
events with their cause, `log` and `focus-log` ("Attributes", "Events and logs"). Step 3 brought
queries in selectors and `ls --where`, named lists and `go`, slots, key bindings and palette commands
from the config ("Selectors", "Queries", "Lists and `go`", "Configuration"). Step 4 brought hidden
panes and the three-pane limit ("Hidden panes"; `hid` on `split`, `pane focus`, `pane move` and
`edit`; the tab's `visible_limit` and `strip`) and removed stacks and the tab's `docs` field. Step 6
removed `tab back` (design/cli.md, choice 11) and gave `tab next|prev` and `tab move --up|--down`
their keys. Step 7 brought the drawer ("Drawer"; the window's `drawer` and the pane's `in_drawer`).
The archive (design/archive.md) brought `tab archive|unarchive`, the tab's `archived`, the window's
`archive` and `tab.KEY` in queries. This now covers all of `design/cli.md`.

## General

- `--json` before the command, or anywhere before a `--` separator, prints JSON instead of human text.
- Exit codes:

  | Code | Meaning |
  |---|---|
  | 0 | success |
  | 1 | usage error, unknown selector, a selector or list that matched nothing where something is required, failed action |
  | 124 | a wait timed out |

- Errors go to stderr, prefixed `<cli>: `.
- Inside the app's panes, the pane, tab and window arguments default to the calling pane and its tab
  and window (the pane named by `UMI_PANE`, which every pane's shell and every palette or key
  command has). Elsewhere they default to the focused ones.
- Times on the command line (`--since`, `--until`) are ISO 8601, a clock time today (`9am`, `14:30`),
  or a duration back from now (`90s`, `5m`, `2h`, `3d`); anything else fails with exit 1. Times in
  JSON are ISO 8601 with a time zone.
- Text arguments: words are joined with spaces. `-` alone means "read the text from stdin". Text after
  `--` is text, even if it starts with dashes.
- No command ever waits for stdin unless given `-`. The exceptions are `send` (layout) with no text
  and a non-TTY stdin, `edit` with no file, and `hook`.

### Selectors

`--pane`/`-p`, `--tab`/`-t` and `--window`/`-w`, and positional PANE, TAB and WINDOW arguments, take a
selector:

- an id or a unique id prefix; a name the user gave; `.` (the focused one); `#N` (tabs and windows,
  by index from 1);
- a **query**: any selector containing `=`, `<`, `>`, `|`, `@`, ` and `, ` or `, `not ` or ` then `.
  Queries select panes; a tab or window selector that is a query selects the tabs or windows holding
  a matching pane.

Commands that act on one pane (`pane focus`, `info`, `get`, `read`, `send`, …) take a query's first
match; `pane set`, `pane unset`, `pane close` and `pane move` act on every match, in the query's
order. `tab close|equalize|color|pin|unpin|set|unset` and `window close|set|unset` act on every tab
or window holding a match; `tab focus|rename|move` and `window focus` take the one holding the first
match. An unknown or ambiguous id, prefix or name fails with exit 1 and
changes nothing. A query that matches nothing fails with exit 1 for commands that need a target, and
succeeds with an empty result for `ls --where`.

### Queries

```
QUERY  := PART [ "then" PART ]…
PART   := EXPR [ "|" "sort" KEY ["," KEY]… ] [ "|" "limit" N ]
EXPR   := TERM | EXPR "and" EXPR | EXPR "or" EXPR | "not" EXPR | "(" EXPR ")"
TERM   := KEY OP VALUE | KEY | "@" LIST
OP     := "=" | "!=" | "<" | "<=" | ">" | ">="
KEY    := an attribute name (letters, digits, ".", "-", "_")
VALUE  := a word, or text in double quotes
```

- `and` binds tighter than `or`. Keys and list names are case-sensitive; values compare exactly.
- A bare `KEY` holds when the key is set and its value isn't `false`. `KEY != VALUE` holds for a pane
  without the key; the other comparisons don't.
- `@NAME` holds for the panes of the named list `NAME`; a list that doesn't exist fails with exit 1.
  A part that is only `@NAME` (no `sort`) keeps the list's own order.
- Values compare as numbers when both sides read as numbers, as durations when both read as
  durations (`90s`, `5m`, `2h`, `1h30m`; a bare number beside a duration is seconds), as times when
  the attribute holds a time and the value is a time or a duration back from now (`status_since <
  10m` holds for a status older than 10 minutes); otherwise as text.
- `sort KEY` sorts ascending, `-KEY` descending, with the same comparisons. Panes missing the key
  sort last. Ties keep the order of `ls`.
- `tab.KEY` reads the attribute KEY of the pane's tab (`tab.archived=true`: the panes of archived
  tabs). A pane can't hold a key that starts with `tab.` (setting one fails with exit 1).
- `then` lists the panes of the next part after those of the parts before it, each pane once (the
  list `jump` is `@needs-you and tab.archived=false | sort status_since then @unseen and
  tab.archived=false | sort changed_at`).
- Without `sort`, matches come in `ls` order: windows by index, tabs in sidebar order, panes on show
  in layout order, then the others.
- A query that doesn't parse fails with exit 1 and names the character position of the error.

## Layout

| Command | Notes |
|---|---|
| `ls [--where QUERY]` | JSON: `{"windows": [Window], "current_tab": id, "current_pane": id}`; the text lists each pane's own attributes. With `--where`: `{"panes": [Pane + "tab", "window"]}`, in query order |
| `window new [--cwd D] [--cmd C] [--name N] [--worktree W [--base REF]] [--no-focus]` | prints the new pane's id; JSON has `pane`, `tab`, `window` |
| `window focus\|close [WINDOW]` | |
| `tab new [NAME] [--window W] [--pane P] [--cwd D] [--cmd C] [--name N] [--color C] [--index I] [--worktree W [--base REF]] [--no-focus]` | as `window new`; the tab opens right after the current tab, or last with `--no-focus`, or at `--index` (SPEC S-7) |
| `tab focus\|close\|equalize [TAB]` | |
| `tab next\|prev [--window W]` | the next or previous tab in sidebar order, wrapping (⇧⌘] / ⇧⌘[ and ⌃Tab / ⌃⇧Tab); JSON `{"tab", "window", "index", "title"}` |
| `tab rename [TAB] NAME` | `""` clears |
| `tab color [TAB] COLOR` | red green yellow blue magenta cyan (Warp's six, from the theme's ANSI colors), purple pink orange teal graphite, none |
| `tab pin\|unpin [TAB]` | pinning an archived tab fails with exit 1 |
| `tab archive [TAB] [--until CONDITION]…` | (⌃⌘A) puts every matching tab in its window's archive, at its end; it keeps running, leaves its tab group and is unpinned; the window shows instead the tab closing it would. `--until` as on `pane hide`: a query about any of the tab's panes, or a duration; the first to hold brings the tab back. JSON `{"tab": id, "tabs": [id]}` |
| `tab unarchive [TAB]` | (⌃⌘A on an archived tab) brings every matching tab back, to the top of the unpinned tabs; clears its `--until` conditions; selection doesn't change. JSON `{"tab": id, "tabs": [id]}` |
| `tab move [TAB] (--window W [--index I] \| --index I \| --up \| --down \| --new-window) [--no-focus]` | `--up`/`--down` (⌃⇧↑ / ⌃⇧↓): one place, within the tab's pin group and tab group (past a whole neighboring tab group); fails at the end of the group. The archive is the last place above the first tab: `--up` on the first tab archives it, `--down` on an archived tab brings it back |
| `split [right\|down\|left\|up] [--pane P] [--cwd D] [--cmd C] [--name N] [--ratio R] [--no-focus] [--worktree W]` | prints the new pane's id; R is the new pane's share of its row (or column), the others keep their proportions. When the tab already shows its limit, `strip.make-room` hides one; JSON `{"pane", "tab", "window", "hid"?: id}` |
| `pane focus [PANE]` | a hidden pane is brought in first (it takes the right end of the tab; `strip.make-room` hides one); JSON `{"pane", "tab", "window", "hid"?}` |
| `pane close\|info\|zoom [PANE]` | `info` JSON: Pane plus `tab`, `window`; `close` closes every pane a query matches |
| `pane rename [PANE] NAME` | |
| `pane move [PANE] (--to PANE [--dir D] \| --tab T [--dir D] \| --window W [--dir D] \| --new-tab [--window W] \| --new-window) [--no-focus]` | the pane's program keeps running. A query moves every match in its order: the first goes where the options say, each next one beside the one before it (`--to`'s own pane stays put). A hidden pane moves too. Landing in a tab at its limit hides one there; JSON `{"pane", "panes", "tab", "window", "hid"?}` |
| `pane swap [PANE] TARGET` | |
| `pane resize [PANE] up\|down\|left\|right [AMOUNT]` | CLI only; no default keys (⌃⌘ and the arrows move panes, SPEC KM-1) |
| `send [--pane P] [--enter\|-e] TEXT…` | no TEXT plus a piped stdin sends stdin |
| `keys [--pane P] KEY…` | enter esc tab backspace up down left right ctrl+c shift+tab … |
| `read [--pane P] [--scrollback] [--lines N]` | prints the text as the shell and programs printed it. With Umi's look (SPEC S-9 to S-12) a zsh prompt is two blank rows, the folder, and the command line; durations, lines and the folder box are drawn, not text |
| `wait [--pane P] (--pattern RE \| --idle SECS \| --attr QUERY) [--timeout T]` | prints the matched text (`--attr`: waits until the pane matches the query, for example `agent.status=idle`, and prints its attributes as `key=value` lines; JSON `{"pane", "attributes"}`); 124 on timeout. The pattern matches program output, never the prompt (the folder line) or the typed command |
| `events [--filter PREFIX]… [--pane P] [--since T]` | streams Event objects as JSON lines ("Events and logs"); a filter keeps events whose name starts with PREFIX; `--since` replays the activity log from T first |
| `notify [--pane P] TITLE [BODY]` | |
| `sidebar [on\|off\|toggle\|status\|tabs\|files\|search] [--window W]` | shown or hidden per window (the given one, else the caller's, else the current); JSON: `{"visible": bool, "mode": "tabs"\|"files"\|"search", "width": points, "window": id}` |
| `sidebar width [N] [--window W]` | prints the window's sidebar width in points; with N sets it (clamped to 180–600) |
| `reopen [--list]` | reopens the last closed pane, tab or window (closed in the last 60 s; a pane reopened into a tab at its limit hides one there); prints the pane's id (the window's for a window); JSON `{"kind": "pane"\|"tab"\|"window", "pane"?, "tab", "window"}`; exit 1 when there's nothing to reopen. `--list`: JSON `{"items": [{"kind", "closed_at", "expires_in", "panes": [id], "tab"?, "title"?, "tabs"?}]}`, most recent first |
| `screenshot [--window W] OUT.png` | an image of the window, terminal contents included |
| `worktree ls` | |
| `layout ls` | launch configurations (SPEC L-21) in `$XDG_CONFIG_HOME/umi/launch_configurations` (default `~/.config/umi/…`), by name; one per YAML document, so a file with several documents (separated by `---`) lists several; JSON `{"directory", "configs": [{"name", "file", "path", "document", "windows", "tabs"} or {"file", "path", "document", "error"}]}` (`document` counts from 0; a file that can't be read is listed once, with `error` and the line) |
| `layout save NAME [--replace]` | saves every window, hidden panes included (marked `is_hidden: true`), as `NAME.yaml` (unless NAME ends in `.yaml`/`.yml`), named after the file (`my_work` → "My Work"); prints the path; JSON `{"path", "name", "windows", "tabs"}`; fails when the file exists, unless `--replace` |
| `layout open NAME [--no-focus]` | NAME is a configuration's name or file name (case doesn't matter; a file holding several configurations fails and lists their names); opens each of its windows as a new window, the active one in front (a tab with more panes than its limit, or panes marked `is_hidden`, opens the rest hidden); prints the windows' ids; JSON `{"name", "windows": [id], "panes": [id]}` |

Objects in JSON:
- **Window**: `{"id", "index", "selected_tab": id, "tabs": [Tab], "drawer": {"open": bool, "panes":
  [Pane], "current"?: id (the pane the drawer shows, or showed last)}, "archive": {"open": bool,
  "tabs": [id] (its archived tabs, in the order they were archived)}, "attributes": {…}}`
- **Tab**: `{"id", "index", "title", "name"?, "selected": bool, "pinned": bool, "archived": bool,
  "archive_until"?: [{"query"} or {"at"}] (an archived tab's pending conditions), "color"?, "group"?:
  its tab group's name, "focused_pane": id, "visible_limit": int, "strip": [id] (every pane's chip,
  in strip order), "panes": [Pane], "attributes": {…}}`
- **Pane**: `{"id", "kind": "terminal"|"file"|"web", "cwd", "name"?, "focused": bool, "zoomed": bool,
  "hidden": bool, "in_drawer": bool,
  "indicator": "working"|"needs_you"|"finished"|"none", "attributes": {key: value} (every attribute:
  the user's, `agent.*`, and Umi's read-only ones; "Attributes" below), "file"?: path (a file pane),
  "frame"?: {"x", "y", "width", "height"} (points, top-left origin, in the window's terminal area;
  panes on show only), "url"?: the page's address and "title": its title (a web pane, SPEC
  E-12)}`. `indicator` is the pane indicator's state (SPEC PI-1): `working` while its agent works,
  `needs_you` while it needs input or failed, `finished` while it finished (`idle`, `stopped`) and
  the pane is `unseen`, else `none`.
  A tab's `panes` lists the panes on show in layout order, then the hidden ones in strip order. A
  pane in the drawer is in no tab: it is listed under its window's `drawer`, with `in_drawer: true`.

Events: `pane.created` and `tab.created` carry `"reopened": true` when `reopen` brought them back;
`sidebar.changed` is emitted when a window's sidebar is shown or hidden or its width changes. Events,
their causes and the logs are under "Events and logs" below.

Other commands:

| Command | Notes |
|---|---|
| `help [--json]` | `--json`: every command for programs: `{"cli", "product", "version": 1, "commands": [{"section", "usage", "summary", "actions": [{"title", "argv", "ask": [{"name", "prompt", "option"?, "choices"?, "optional", "kind", "words"?}]}]}]}` |
| `shortcuts [ls]` | JSON `{"shortcuts": [{"id", "title", "kind": "umi"\|"ghostty", "keys": [str], "display": [str], "default": [str], "changed": bool, "menu"?, "source"?}], "files": [str]}` |
| `shortcuts set ID KEYS`, `shortcuts clear ID`, `shortcuts reset [ID]` | ID from `shortcuts`: an Umi item (`tab.next`) or `ghostty:ACTION`; KEYS like `cmd+shift+]`; JSON of `set` has `notes`: the shortcuts the key was taken from |

Events also include `palette.opened` and `palette.ran`. Tabs change places only when moved (`tab.moved`) or
pinned; nothing reorders them on its own (SPEC S-7).

## Hidden panes

| Command | Notes |
|---|---|
| `pane hide [PANE] [--until CONDITION]…` | takes each matching pane out of its tab's layout; it stays in its tab and keeps running. Hiding the last pane on show fails with exit 1 and changes nothing. JSON `{"panes": [id]}` |
| `pane show [PANE] [--focus]` | brings each pane back into its tab, at the right end (`strip.make-room` hides one if the tab is at its limit). Keyboard focus stays where it is unless `--focus`. JSON `{"panes": [id], "hid": [id]}` |
| `pane until [PANE]` | the pane's pending conditions; JSON `{"pane", "until": [{"query"?, "at"?}]}` |

- `--until` takes a query about the pane itself (`--until 'agent.done=false or agent.status=needs_input'`),
  a duration (`--until 2h`), or both as two options; the first to hold shows the pane. A query that
  doesn't parse fails with exit 1. The condition is checked whenever the pane's attributes change and
  once a minute; conditions are saved with the layout. Showing the pane by any means clears them.
- A pane shown by a condition never takes keyboard focus. Its `changed_at` is set, so it counts as
  `unseen` until looked at; its `pane.shown` event has `"by_condition": true` and cause `config`.
- Events: `pane.hidden` and `pane.shown` `{"pane", "tab", "window", "by_condition"?}`, for every way a
  pane is hidden or shown (making room is caused by what made it). A ⌘[ ⌘] walk reports only where
  it lands.
- Closing the last pane on show of a tab with hidden panes brings in the hidden one used most
  recently; otherwise hidden panes never come in by themselves.

## Drawer

| Command | Notes |
|---|---|
| `drawer show [PANE] [--window W]` | moves each matching pane into the window's drawer (it leaves its tab; a tab left with no pane closes; the window's only pane fails with exit 1) and opens the drawer with the first on show and focused; without PANE, opens the drawer as it was (exit 1 when it is empty) |
| `drawer hide [--window W]` | closes the drawer; its panes stay in it, keep running, and focus returns to the pane focused before it opened |
| `drawer toggle [PANE] [--window W]` | `show` when closed or showing another pane, else `hide`. ⌃⌘M runs `drawer toggle @manager` (the default list `manager` is `role=manager`); with no such pane it only puts an open drawer away |
| `drawer next\|prev [--window W]` | the next or previous pane in the drawer, on show and focused (⌘] / ⌘[ while a drawer pane is focused) |
| `drawer dock [PANE]` | moves the pane (default: the calling drawer pane, else the one the drawer shows) from the drawer into the current tab's layout, to the right of the tab's focused pane, focused (`strip.make-room` applies); a pane not in a drawer fails with exit 1. JSON `{"pane", "tab", "window", "hid": [id]}` |
| `drawer ls [--window W]` | JSON `{"open": bool, "panes": [Pane], "window", "current"?}` |

`show`, `hide`, `toggle`, `next` and `prev` print the `drawer ls` JSON with `--json`. W defaults to the
calling pane's window (a drawer pane's too), else the current one.

- A pane in the drawer leaves the drawer when hidden: it goes back, hidden, to the tab it came from, or
  the current tab when that tab is gone. `pane move` takes it to wherever it says; `pane close` (or its
  program ending) ends it; `pane focus` and `go` open the drawer on it. `split`, `pane zoom`, `pane
  swap` and `pane resize` fail with exit 1 for a drawer pane.
- While the drawer is closed, a drawer pane whose indicator is `needs_you` shows a thin line along the
  bottom edge of the window's panes with its title.
- Events: `drawer.opened`, `drawer.closed` `{"window", "pane"?}`; a pane going into or out of a
  drawer is a `pane.moved` whose `to` or `from` is `{"window", "drawer": true}`.

## Attributes

| Command | Notes |
|---|---|
| `pane set [PANE] KEY=VALUE…` | sets each pair on every matching pane; `KEY=` sets the empty string; a bad pair changes nothing. JSON `{"panes": [id], "set": {key: value}}` |
| `pane unset [PANE] KEY…` | removes the keys; removing a missing key is not an error. JSON `{"panes": [id], "unset": [key]}` |
| `pane get [PANE] [KEY…]` | prints each KEY's value on a line (empty when unset), or every attribute as `key=value` lines without KEY. JSON `{"pane": id, "attributes": {…}}` (only the KEYs asked for, when given) |
| `tab set\|unset\|get [TAB] …`, `window set\|unset\|get [WINDOW] …` | the same on tabs and windows; JSON `{"tabs": [id], …}`, `{"windows": [id], …}`, `{"tab"\|"window": id, "attributes"}` |

- PANE (TAB, WINDOW) is a selector (`--pane`/`-p`, `--tab`/`-t`, `--window`/`-w`, or the first word).
  For `set`, a first word without `=` is the selector, and so is a query that doesn't read as
  `KEY=VALUE` (`@list`, `not hidden`, `(a=1 and b=2)`; `--pane` takes any query). For `unset` and
  `get`, the first word is the selector only when it is a full id, a name, `.`, `#N` (tabs, windows)
  or a query, so a key (`a`, `face`) is never read as an id prefix; otherwise every word is a key.
  `unset` with only a selector fails with exit 1. Without a selector: the calling pane (its tab, its
  window) inside the app's panes, else the focused one.
- Values are strings. Keys are letters, digits, `.`, `-` and `_`.
- **Read-only keys** (kept by Umi; setting one fails with exit 1): `kind` (`terminal`, `file`,
  `web`), `cwd`, `branch` (the git branch of the pane's folder), `command` (the command it runs, or
  last ran), `focused` (`true`/`false`: focused in its tab), `hidden`, `in_drawer`, `seen_at` (when the
  pane itself last had keyboard focus in the app's front window while the app was active; now while
  it has), `changed_at` (when its `agent.status` last changed, or it was last hidden or shown),
  `status_since` (when its `agent.status` last changed), `idle_for` (seconds since its terminal last
  printed, as `90s`), `unseen` (`true` while its agent's status changed since `seen_at`, or it came
  back on show since then; being hidden doesn't make a pane unseen), and on tabs
  `visible_count` (the panes it shows). Times are ISO 8601 with a time zone. A key Umi has nothing
  for is absent (`branch` outside git, `changed_at` on a pane with no agent that was never hidden).
- **Keys written by the hook plugin** ("Agent hooks" below): anyone may write them with `pane set`;
  the next hook event overwrites them. On a pane without an agent they need `agent.kind` (`claude` or
  `codex`) in the same command, else exit 1. `agent.status` is one of its five values and
  `agent.done` is `true` or `false`, else exit 1. `pane unset PANE agent.kind` takes the agent away;
  `agent.status` can't be unset on its own.
- **Keys with a meaning to Umi**: `role` has one holder per value, among panes for panes and among
  tabs for tabs: setting `role=manager` on a pane removes it from the pane that had it. The Docs tab
  (SPEC E-10) is the tab with `role=docs`. `pinned` (panes): never hidden to make room.
  `visible_limit` (tabs): how many panes the tab shows; default 3, at least 1; lowering it hides
  panes at once. `archived` (tabs): `true` while the tab is in its window's archive, else `false`;
  setting it to `true` or `false` (or unsetting it) archives the tab or brings it back, as `tab
  archive|unarchive`; any other value fails with exit 1.
- Attributes live and die with their pane (or tab, window). They are saved and restored with the
  layout.

## Lists and `go`

| Command | Notes |
|---|---|
| `list ls` | the named lists, Umi's and the config's: JSON `{"lists": [{"name", "query", "count", "default": bool, "error"?}], "problems": [str]}` |
| `list show NAME` | the list's panes, in order; JSON `{"panes": [Pane + "tab", "window"]}` |
| `go LIST\|QUERY` | puts the first pane in front of the user: its window in front, the app active, its tab selected, focused. JSON `{"pane", "tab", "window"}`. Exit 1 with "nothing in LIST" when empty; nothing moves |
| `go --next LIST\|QUERY` | the next pane of the walk: the first after the one the walk last went to (wrapping round), re-reading the list each time. A new walk starts when anything other than `go --next` moved focus since the last step; its first step skips the pane focused now |
| `go --back` | back to the pane focused before the walk's first step. One walk per window. Exit 1 when there is no walk |

⌃⌘J runs `go --next jump` and ⌃⌘K runs `go --back`. `jump` is a named list; its default is "needs you,
then unseen, oldest first in each". A LIST is a list's name; anything else is read as a query.

Umi's lists (the config can redefine each):

| List | Query |
|---|---|
| `needs-you` | `agent.status=needs_input \| sort status_since` |
| `unseen` | `unseen and agent.status!=working and agent.status!=needs_input \| sort changed_at` |
| `jump` | `@needs-you and tab.archived=false \| sort status_since then @unseen and tab.archived=false \| sort changed_at` (panes in archived tabs left out) |
| `manager` | `role=manager` |

## Configuration

Lists, slots, key bindings and palette commands live in `~/.config/umi/config` (`$XDG_CONFIG_HOME/umi/config`),
next to the Ghostty settings, and in the files it includes with `config-file`. Umi reads them again
when the file changes; Ghostty skips these keys. Editing is done in the file (⌘, opens it).

```
list.NAME = QUERY
slot.NAME = VALUE
key.KEYS = ACTION                       # KEYS as in `shortcuts` (ctrl+cmd+y)
command."Title" = SHELL COMMAND
```

| Command | Notes |
|---|---|
| `slot ls` | every slot with its value and whether it is the default; JSON `{"slots": [{"name", "value", "default": bool, "summary", "used_from"?, "error"?}], "problems": [str]}` |
| `command ls` | palette commands: JSON `{"commands": [{"title", "path"?, "line"?, "keys"?: [str]}]}` |
| `command run TITLE [--pane P]` | runs one as the palette would; prints its stdout (and stderr); exit 1 when it fails. JSON `{"title", "status", "stdout", "stderr"}` |
| `shortcuts [ls]` | key bindings from the config appear with `"kind": "config"`, `"source": "config"` |

Slots:

| Slot | Default | Notes |
|---|---|---|
| `jump` | the list `jump`'s default | the list `jump` (`slot.jump` sets it too) |
| `badge` | `@needs-you` | the Dock badge counts its matches |
| `landing` | `none` | a query: the pane focused when the app comes back to the front after `landing.after` |
| `landing.after` | `10m` | |
| `tab.summary` | `focused and agent.kind then (agent.status=needs_input or agent.status=error) \| sort -status_since then unseen \| sort -status_since then agent.kind \| sort -status_since` | the pane of a tab (its panes on show, then its hidden ones) that gives its sidebar row the agent logo, the pane indicator and line 2 |
| `sidebar.line2` | `{agent.title or command or cwd}` | a template: each `{…}` is the first of its keys that is set; the default keeps the built-in line |
| `strip.make-room` | `not pinned and not focused \| sort seen_at` | which pane on show is hidden when one comes into a tab at its limit: the first match among its panes on show, never one that is arriving. When nothing matches, the tab shows more than its limit |
| `indicator.working`, `indicator.needs_you`, `indicator.finished` | `muted`, `amber`, `muted` | the pane indicator's colour in each state: `muted` (that state's quiet colour), `amber`, `green`, `violet`, `grey`, `#RRGGBB`, or `none` (no mark) |
| `indicator.focus` | `3%` | how much brighter the focused pane of a split is: a percentage up to 20%, `0` for none |
| `done-check` | `^Status: done` | a regular expression; `agent.done=true` when the last line of the agent's last message matches |

- A key binding's ACTION is a palette command's title, `@LIST` (`go --next @LIST`), or a `<cli>`
  command line (`go --next @needs-you`, `pane set pinned=true`). It wins over Umi's own shortcut on
  the same keys.
- Each executable in `~/.config/umi/commands/` is a palette command titled from its file name
  (`organize-into-tabs.sh` is "Organize into tabs").
- A palette or key command runs with `UMI_PANE`, `UMI_TAB`, `UMI_WINDOW` (the caller's), `UMI_CAUSE`
  (`palette` or `key:<keys>`), `UMI_CLI` (the path of `<cli>`) and `UMI_STATE_DIR` in its environment,
  in the calling pane's folder. Its stdout shows in the palette; a non-zero exit shows its stderr.

## Events and logs

| Command | Notes |
|---|---|
| `events [--filter PREFIX]… [--pane P] [--since T]` | streams events as JSON lines (Event objects); `--since` replays the activity log from T first |
| `log [--since T] [--until T] [--filter PREFIX]… [--pane P]` | the activity log: the same Event objects, oldest first; JSON `{"events": [Event]}`; a line per event for people. Kept 30 days. P may be the id (or id prefix) of a pane that is gone |
| `focus-log [--since T] [--until T] [--pane P]` | stretches of keyboard focus overlapping the times: JSON `{"stretches": [{"pane", "tab", "window", "start", "end", "seconds", "title", "kind", "cwd", "file"?, "url"?, "agent"?: {"kind", "session"?, "title"}, "attributes": {…}, "open"?: true}]}`, oldest first; the stretch going on now is last, with `"open": true` and `end` now. Kept 30 days |

- **Event**: `{"event": name, "at": time, "cause": {"kind", "command"?, "key"?, "pane"?}, "data": {…}}`.
- `cause.kind`: `key` (with `key`, named as `shortcuts` names keys: `ctrl+cmd+t`), `mouse`, `palette`
  (with `command`), `cli` (with `command`: the words it was run with, `umi …`; and `pane` when run
  inside one of the app's panes), `hook` (an agent's hook), `config` (a condition or a slot) or `umi`
  (the app on its own). A command the palette runs (or a key binding, later) has `UMI_CAUSE=palette`
  (or `UMI_CAUSE=key:<keys>`) in its environment, and the `<cli>` calls it makes are recorded with
  that cause.
- `pane.changed` `{"pane", "key", "old", "new"}` (null for a key that wasn't set, or was removed), and
  `tab.changed` / `window.changed` the same with `tab` / `window`: one per changed key. An agent's
  status change is `pane.changed` with key `agent.status`, before its other `agent.*` keys.
- `tab.archived` `{"tab", "window"}` and `tab.unarchived` `{"tab", "window", "by_condition"?: true}`
  (true when an `--until` condition brought it back, caused by `config`). Archiving a pinned tab is
  also a `tab.unpinned`, and one in a tab group a `tab.ungrouped`.
- `pane.moved` has `from` and `to`: `{"tab", "window", "index"}` (the pane's place in its tab's
  layout, from 1), or `{"window", "drawer": true}` for a window's drawer.
- A focus stretch counts only while the app is active, the screen is unlocked, and the user typed or
  clicked in the app within the last 3 minutes; one that ends because the user stopped ends when the
  3 minutes passed.

## Editor

| Command | Notes |
|---|---|
| `edit FILE\|URL… [--source\|--preview] [--tab T \| --pane P]` | opens each file in a pane of its own: the first to the right of the pane (the calling pane, or the tab's focused pane; the right end of the tab when that pane is hidden), each next one to the right of the one before; in a tab at its limit, `strip.make-room` hides one for each. A file already open shows where it is (brought in if hidden). Keyboard focus stays where it was. An http(s) URL whose origin is an `umi-web-origin` opens the same way in a web pane (SPEC E-12); other URLs are refused. JSON: `{"documents": [{"path", "pane", …}], "pages": [{"url", "pane"}], "tab", "window", "hid": [id]}`. `open` is the same command |
| `editor ls [--tab T \| --pane P]` | JSON: `{"documents": [{"path", "pane", "mode": "preview"\|"source", "dirty": bool, "hidden": bool}], "active"}`: the files open in that tab's panes |
| `editor close [FILE] [--force]` | refuses dirty documents without `--force` |
| `editor mode [preview\|source] [FILE]` | toggles without a mode; FILE picks one of the tab's files (default: the focused one) |
| `editor default [--dry-run]` | make the app the default for Markdown, plain text, JSON, CSV, TSV and YAML; `--dry-run` prints the app bundle path |
| `comments [ls] FILE [--all]` | the file's open comments (E-11): id, line, the words each is on, its text, replies; `--all` adds resolved ones. JSON: `{"path", "comments": [{"id", "body", "by", "at", "status": "open"\|"resolved", "quote", "line", "detached", "anchor_deleted", "resolved_note"?, "replies": [{"id", "body", "by", "at"}]}]}`. Works on the file without the app |
| `comments add FILE --on TEXT [--nth N] TEXT… [--by NAME]` | comment on the first (or Nth) occurrence of TEXT outside code and other comments; prints `added ID` (JSON `{"id", "action", "path"}`) |
| `comments reply FILE ID TEXT… [--by NAME]` | reply to a thread (`-` reads stdin); `--by` defaults to `AI` |
| `comments edit FILE ID TEXT…` / `comments resolve FILE ID [--note TEXT]` / `comments reopen FILE ID` / `comments delete FILE ID` | change, resolve, reopen or delete (a thread goes with its replies and its markup; its words stay) |
| `comments wait FILE [--timeout SECS]` | block until the user presses Done on FILE's comments in the editor, then print its open comments as `comments ls` does; exits 124 on timeout. Needs the app |

## Updates

| Command | Notes |
|---|---|
| `update --check` | prints the installed and the newest version; JSON `{"installed", "latest", "update_available": bool}` |
| `update [--now [--force]]` | checks at once, then downloads and verifies the newest version. It installs at the next quiet moment (SPEC I-4; with `auto-update = check` or `download`, when the app quits), or with `--now` installs it and relaunches the app at once; `--now` refuses while a pane's `agent.status` is `working` unless `--force` |
| `update --status` | what is known without checking, and what a staged update waits for. JSON: `installed`, `latest`, `update_available`, `state` (`up_to_date`, `available`, `downloading`, `ready`, `installing`, `asking`, `later`, `skipped`, `agreed`, `held_back`, `failed`, `unknown`), `mode` (`install`, `download`, `check`, `off`), `ready` and `installs` (`quiet` or `quit`) for a staged update, `countdown` (seconds) while the notice counts down, `not_now_until`, `held_back` (why a newer version doesn't install by itself), `rolled_back_from`, `failed_install`, `rollback` (the version `--rollback` goes back to), `quiet` `{"quiet": bool, "waiting_for": [{"kind": "pane"\|"editor"\|"dialog"\|"input", "reason", "pane"?, "tab"?}], "idle_seconds"}`; without `--json`, a line per thing it waits for |
| `update --rollback [--force]` | installs the version installed before this one from its kept, verified zip and relaunches; the version gone back from doesn't install by itself again (`update` installs it). Fails when no earlier version is kept |
| `update --later \| --skip` | answers the update question (`auto-update = check`): ask again after a day \| not about this version |

## Agent hooks

Claude Code and Codex run in panes; Umi runs no agents of its own. Umi's plugins report each agent's
state on its pane.

| Command | Notes |
|---|---|
| `hook EVENT --agent claude\|codex [--pid PID]` | run by Umi's plugins: reads the agent's hook input (JSON) on stdin and writes `agent.*` on the pane the agent runs in (the caller's pane, `UMI_PANE`); prints nothing; exits 0 always, also when no pane matches or nothing runs |
| `plugins [status\|install [--force]\|remove]` | Umi's plugins in Claude Code and Codex (SPEC AG-18); JSON per agent `{"installed", "version"?, "bundled_version"?, "current", "enabled"? (Claude), "hooks_trusted"? (Codex), "agent_installed", "steps"? (install)}`; current means this app's version, from this copy of the app, enabled and (Codex) its hooks trusted; `--force` reinstalls even when current |
| `doctor` | reports whether `<cli>` is on the login PATH and whether the hook plugins are installed and current (for each agent that is installed); exits non-zero when a plugin isn't installed and current (SPEC I-2), and 0 otherwise, also when `<cli>` isn't on PATH (that is reported, not required); JSON `{"ok", "checks": [{"check", "ok", "detail", "required"}]}` |

Keys written by the hooks, in each pane's `attributes`:

| Key | Value |
|---|---|
| `agent.kind` | `claude` or `codex` |
| `agent.status` | `working`, `needs_input`, `idle`, `stopped` or `error` (SPEC AG-19) |
| `agent.title` | the conversation's first prompt, on one line |
| `agent.summary` | the first line of the agent's last reply |
| `agent.done` | `true` or `false`, set at the end of each turn by the `done-check` slot (default: the reply's last line starts with `Status: done`) |
| `agent.session` | the agent's own session (Claude Code) or thread (Codex) id; a relaunch resumes it |

Removed (design/cli.md): every `agent …` command (an old one fails with exit 1 and says what to do),
the `claude` and `codex` shortcuts, the Session, Report, Message, Request, Item and Startup objects,
the `agent` pane field, `jump` (use `go --next jump` and `go --back`), `tab back` (use `go --back`),
`UMI_PANE_ID` (now `UMI_PANE`), and exit codes 2 and 3.

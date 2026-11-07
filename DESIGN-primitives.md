# Umi's primitives, its built-in behavior, and a language for changing it

Draft for discussion, 2026-11-07. It describes Umi as it is today (0.6.x) and proposes how to make
its attention behavior something you configure and script, instead of something fixed in Swift.
Config and CLI syntax in sections 3 and 4 is illustrative: nothing there is decided yet.

## 1. What Umi is made of

### Things

| Thing | What it is | What it knows about itself today |
|---|---|---|
| **Window** | A macOS window with a sidebar and one tab on show. | id, index, its tabs, the selected tab, sidebar width and mode, frame. |
| **Tab** | A row in the sidebar; holds a layout of panes. | id, index (its real order), name, color (one of 9, or none), pinned, the focused pane, whether it is the Docs tab. |
| **Place** | One rectangle in a tab's split layout. Usually holds one pane; holds several when panes are **stacked** (a strip on top names them; one is on show). | its size share, whether a divider beside it was placed by hand. |
| **Pane** | What fills a place. Four kinds: **terminal**, **file** (Markdown/text editor), **web** (a page from your own servers), **agent view** (a read-only transcript drawn over a terminal). | id, name, cwd, kind, focused, zoomed, shown/stacked, frame; for terminals the running or last command, git branch; for files path, mode, dirty; for an agent pane the session. |
| **Agent in a pane** | Claude Code or Codex running in a terminal pane, reported by Umi's hook plugin. | kind, title, status (starting, working, idle, needs_input, stopped, error), live or read-only, its **mark**, when its turn last stopped. |
| **Mark** | Umi's only attention flag: `none`, `finished` (turn ended while you weren't looking), `needsYou` (waits on an approval or question). Set by the agent's state, cleared by looking. | |
| **Closed item** | A pane, tab or window closed in the last 60 s; its programs still run. | what it was, where it was, when it expires. |
| **Parked pane** | A live agent pane taken out of the layout while it finishes its turn. Exists only for hidden agent sessions today. | |
| **Comment thread** | A comment on a Markdown file, stored in the file. | id, anchor text, body, author, open or resolved, replies. |

Surfaces that show those things: the **sidebar** (Tabs or Files mode; each tab row has two lines, an
icon and a quiet color), the **strip** over a stack, the **command palette** (⌘P), the **pane
switcher** (⇧⌘P), the **Dock badge**, **desktop notifications**, the **update notice**.

### Actions

Every action below exists as a CLI command; most also have a key, a menu item and a palette entry.

| On | Actions |
|---|---|
| Window | new, focus, close, screenshot |
| Tab | new (at an index, with cwd, command, worktree), focus, close, rename, color, pin/unpin, move (up, down, to index, to window, to new window), equalize, back, next/prev |
| Pane | split (direction, ratio), focus, close, rename, zoom, resize, swap, move (next to a pane, into a tab, new tab, new window), stack (by drag), show next/previous stack member |
| Terminal content | send text, send keys, read screen or scrollback, wait for a pattern or for idleness |
| File | open (placed by the rules in §2), close, toggle preview/source, comment, reply, resolve, wait for Done |
| Navigation | jump to the next pane that needs you, jump back, tab back |
| Other | notify, reopen a closed item, sidebar on/off/mode/width, rebind shortcuts, update |

### Signals: how Umi learns things

| Signal | Source | Visible to scripts today? |
|---|---|---|
| Layout events: `pane.created/closed/moved/focused/stacked/shown/…`, `tab.created/renamed/moved/…`, `window.created` | the app | yes, `umi events` |
| Editor events: `editor.opened/saved/closed`, `comments.changed/done` | the app | yes |
| Agent hook events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, PermissionRequest, Stop, SessionEnd | Umi's plugin in Claude Code and Codex | partly, as `agent.status` events |
| "You looked at this pane": it has focus in the front window while Umi is active | the app | no event of its own |
| Idle time: no typing or clicking in Umi | the app | only through `update --status` |
| Process state: what runs in a terminal, whether it sits at the prompt | the app | partly, through `ls` |

## 2. What Umi does on its own today

Each built-in behavior is written as **when → which → do**: the trigger, the panes or tabs it picks
out, and the action it takes. The last column says whether it's attention policy, which you might
want to change, or layout mechanics, which can stay fixed.

| Behavior | When | Which | Do | Kind |
|---|---|---|---|---|
| Mark set | agent hook: Stop or a request | the agent's pane, if you aren't looking at it | mark `finished` or `needsYou` | attention |
| Mark cleared | you look at a pane | that pane | mark `none` | attention |
| Dock badge | any mark changes | panes and background sessions with `needsYou` | show their count | attention |
| Tab icon and color | any mark changes | the tab's agents: the focused pane's, else the strongest mark, else the most recent stop | show that agent's logo, quiet color if marked | attention |
| Sidebar line 2 | anything changes | the tab's agent (as above) | its title; else the running or last command; else the folder | attention |
| ⌃⌘J jump | key or `umi jump` | needs-you panes first, then finished-and-unseen, oldest stop first | focus the next one; remember where you started | attention |
| ⌃⌘K jump back | key | the pane before the first jump | focus it | attention |
| ⇧⌘[ tab back | key | tabs in visit order, closed ones skipped | walk back | navigation |
| ⇧⌘] / ⌃Tab next | key | tabs in sidebar order | next one, wrapping | navigation |
| ⌘1–9 | key | tabs in sidebar order | the Nth one, ⌘9 the last | navigation |
| ⇧⌘P pane list | key | every pane, most recently focused first | list; title = name, else agent title, else program title, else folder | navigation |
| Coming back to Umi | app activates | — | nothing: focus is where you left it | attention (missing) |
| Tab order | always | — | never reorder on its own; pinned tabs first | layout |
| New tab position | tab created | — | after the current tab if you go to it; last if created in the background | layout |
| Focus after close | pane closes | panes of that tab | focus the one used most recently | layout |
| File placement | `umi edit` or a click in Umi | the calling pane | open to its right; if the tab shows 3 places, a new tab after it | layout |
| Files from Finder | `open FILE` | Markdown: the Docs tab's stack. Other text: the tab whose pane cwd is the deepest folder containing the file | open there, most recent first | layout |
| Split sizing | split, close, drag | the row or column | equal shares; hand-placed dividers stay | layout |
| Reopen | ⇧⌘T within 60 s | the last closed item | bring it back in its old place | layout |
| Stacks | drop in a pane's middle; ⌘[ ⌘] | the stack | show a member; closing the one on show shows the next | layout |
| Agent hidden mid-turn | ⌃⌘W | the session's pane | park it; close it when its turn ends | attention |
| Restore after restart | launch | panes that ran an agent | relaunch it with the flags you typed | layout |
| Quiet moment for updates | every few seconds | all panes, sessions, editors, input | install only when nothing runs, nothing is unsaved, and you've been idle 2 min | app |

Everything marked **attention** is fixed in Swift. A script can see some of it but can't change any
of it, and there is nowhere to store your own facts about a pane (such as "this one is important").

## 3. Building blocks for a language over these primitives

Five layers, each usable without the ones after it.

### 3.1 Data: attributes

Key–value pairs on panes, tabs and windows. Three sources:

- **Yours**, written by you or your scripts: `priority=high`, `project=impact-ops`, `note="waiting on Ben"`, `url=…`.
- **Agent**, written by the hook plugin: `agent.kind`, `agent.status`, `agent.title`, `agent.summary`, `agent.done`.
- **App**, computed and read-only: `kind`, `cwd`, `branch`, `command`, `focused`, `shown`, `parked`, `seen_at`, `changed_at`, `status_since`, `idle_for`.

With `seen_at` and `changed_at` as plain facts, today's mark stops being a separate concept:
"unseen" is `changed_at > seen_at`, and "needs you" is `agent.status=needs_input`.

CLI shape: `umi pane set [PANE] priority=high`, `umi pane unset [PANE] priority`; attributes appear
in `ls --json` and every change emits `pane.changed {pane, key, old, new}`.

### 3.2 Selection: queries and named lists

A query picks panes by attribute and orders them:

```
agent.status=needs_input
priority=high and not parked | sort -priority, status_since
project=impact-ops | sort -changed_at | limit 5
```

Anywhere that takes a selector takes a query (`--pane 'priority=high'`, `umi ls --where …`). A
**named list** is a saved query in the config:

```
list.needs-you  = agent.status=needs_input | sort status_since
list.unseen     = changed_at > seen_at | sort changed_at
list.important  = priority=high | sort -priority, status_since
```

### 3.3 Actions

The existing verbs, plus a few new ones:

- `set` / `unset` an attribute;
- `park` (take a pane out of the layout; its program keeps running) and `unpark` (put it back where it was, or after the current tab);
- `seen` (mark looked at without focusing it);
- `go LIST` / `go --next LIST` / `go --back` (generalised `jump`).

Every action takes a query as its target, so `umi pane park 'project=old'` parks a group.

### 3.4 Bindings: slots the app fills from a list or template

Some decisions must happen instantly inside the app, so the app keeps a fixed set of **slots**.
Each slot is filled from a named list or a template:

| Slot | Today's behavior as the default value |
|---|---|
| `jump` (⌃⌘J) | `needs-you`, then `unseen` |
| `badge` (Dock count) | count of `needs-you` |
| `landing` (when you come back after N minutes) | none: stay where you were |
| `tab.next` / `tab.prev` | sidebar order |
| `pane-switcher` (⇧⌘P order) | most recently focused |
| `sidebar.line2` | template `{agent.title or command or cwd}` |
| `sidebar.icon`, `sidebar.tint` | from the strongest `agent.*` state in the tab |
| `style.<query>` | border color, sidebar dot, dim, for panes matching the query |
| `notify` | none |

Plus `key.<keys> = <action>` so any list gets a shortcut.

### 3.5 Rules: when something happens, do something

| Approach | How | Good for | Cost |
|---|---|---|---|
| **External script** | a program reads `umi events` and calls `umi …` | anything; any language; easy to change | runs a few hundred ms late; must be kept running (launchd); can miss events while it's down |
| **Conditions on an action** | `umi pane park P --until 'agent.done=false'` or `--until 2h` | one-off "come back when…" | each condition must be checkable by the app |
| **Rules in config** | `on agent.stop where … do unpark` | rules that must survive restarts and run instantly | the config grows into a programming language |
| **Policy command** | the app runs your command at a decision point and uses its answer, e.g. `park.done-check = ~/bin/is-done` | one rich decision without a language | a slow or broken command delays the app; needs a timeout |

### 3.6 Worked examples

**Important panes.** A key toggles `priority=high` on the focused pane. `list.important` sorts
them. `landing = important` after 15 minutes away. `key.ctrl+cmd+] = go --next important`.
`style.priority=high = sidebar-dot:orange`.

**Park until not done.** `umi pane park --until 'agent.done=false or agent.status=needs_input'`.
The Stop hook sets `agent.done` from the last message (by the `park.done-check` policy command, or a
regex). A pane that comes back gets `seen_at` older than `changed_at`, so it is in `unseen` and
`jump` reaches it.

**Return digest.** A script listening for `app.activated` after a long absence counts `unseen`,
`needs-you` and `agent.status=working`, and shows them through `notify` or a pane.

**Review walk.** `go --next unseen` bound to a key; each visit sets `seen_at`, so the list shrinks
as you go.

**Project focus.** `umi view project=impact-ops` dims or collapses tabs without a matching pane;
`umi view off` restores.

## 4. Big design decisions

Each has a recommendation; your input changes what gets built.

1. **Where policy lives.** Options: config only, scripts only, or both.
   *Recommend:* named lists, bindings and styles in the config, because the app needs them
   instantly; anything triggered by events lives in your scripts, plus `--until` conditions and one
   or two policy commands. No general rules engine in the app until scripts prove too slow.

2. **The query syntax.** Options: a small syntax of our own (`key=value and …  | sort`), jq over
   `ls --json`, or an established expression language (CEL).
   *Recommend:* our own small syntax. It has to be typed in the palette and in `--pane`, where jq
   is too heavy. Scripts that need more can run jq over `umi ls --json`.

3. **How long an attribute lives.** A pane outlives the programs in it: quit Claude, start another
   task, and "priority=high" may no longer apply.
   *Recommend:* two lifetimes. Your attributes stay with the pane until removed; `agent.*` ones
   reset when the agent in the pane changes. Option: let you set yours with `--until-program-exits`.

4. **Panes or tabs as the unit of attention.** Attributes, lists and marks naturally sit on panes,
   but the sidebar shows tabs.
   *Recommend:* attributes on panes; a tab shows the strongest of its panes (as today's marks
   do), and tabs can carry their own attributes too. Add a sidebar mode that lists panes from a
   named list later, if tab rows prove too coarse.

5. **Attention as facts, not flags.** Replace the `finished`/`needsYou` mark with `seen_at`,
   `changed_at` and `agent.status`, and derive "unseen" and "needs you" from them.
   *Recommend:* do. Every attention idea then reduces to queries over times and states.

6. **Fixed slots versus open-ended bindings.** The app can only hand over the decisions it
   exposes as slots.
   *Recommend:* a fixed, documented set of slots (§3.4), grown one at a time, rather than letting
   the config hook any internal decision.

7. **Where a pane can be.** Today: on show, stacked behind another, parked (agents only), closed
   for 60 s. *Recommend:* make `parked` an ordinary place any pane can be in, visible in `ls` and
   the pane switcher, so `park`, `--until` and `landing` work for every pane kind.

8. **Stability of the CLI contract.** `acceptance/CLI.md` is a fixed contract that agents rely on.
   *Recommend:* add the new surface under the same contract with tests, and give the query syntax
   a version in `help --json` so the palette and scripts can tell what this Umi understands.

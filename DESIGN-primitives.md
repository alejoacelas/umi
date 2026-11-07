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
| **Parked pane** | A live agent pane taken out of the layout while it finishes its turn. Exists only for hidden agent sessions {==today.==}{>>I’d like to have a consistent visual identity for ‘panes not visible’ so far I want to use them for tasks that I suspect will be done and don’t want to touch unless they need my attention, but it seems like a more general thing. maybe I want to delegate sessions from hidden panes to a manager agent also, I’d like the comment box to expand so that it shows the full text I type<<}{#c5} | |
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
| Other | notify, reopen a closed item, sidebar on/off/mode/width, rebind shor{==tcuts, update==}{>>write to sidebar?<<}{#c4} |

Nothing writes to the sidebar today: its text is worked out from the tab's agent, command and folder.
§3.4 makes line 2 a template over attributes, so `umi pane set status="reviewing PR"` writes to it.

### Signals: how Umi l{==earns things==}{>>I’d like to be able to extract at the end of the day the docuemtns and sessions I had on focus and for how much time, so I can track which tasks I devoted attention to<<}{#c1}

| Signal | Source | Visible to scripts today? |
|---|---|---|
| Layout events: `pane.created/closed/moved/focused/stacked/shown/…`, `tab.created/renamed/moved/…`, `window.created` | the app | yes, `umi events` |
| Editor events: `editor.opened/saved/closed`, `comments.changed/done` | the app | yes |
| Agent hook events: SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Notification, PermissionRequest, Stop, SessionEnd | Umi's plugin in Claude Code and Codex | partly, as `agent.status` events |
| "You looked at this pane": it has focus in the front window while Umi is active | the app | no event of its own |
| Idle time: no typing or clicking in Umi | the app | only through `update --status` |
| Process state: what runs in a terminal, whether it sits at the prompt | the app | partly, through `ls` |

Umi keeps no record of which panes had focus over time. §3.1 adds a focus log.

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
- **App**, computed and read-only: `kind`, `cwd`, `branch`, `command`, `focused`, `shown`, `hidden`, `seen_at`, `changed_at`, `status_since`, `idle_for`.

With `seen_at` and `changed_at` as plain facts, today's mark stops being a separate concept:
"unseen" is `changed_at > seen_at`, and "needs you" is `agent.status=needs_input`.

CLI shape: `umi pane set [PANE] priority=high`, `umi pane unset [PANE] priority`; attributes appear
in `ls --json` and every change emits `pane.changed {pane, key, old, new}`.

**Focus log.** The app records each stretch during which a pane had keyboard focus in Umi's front
window, while Umi was the active app, the screen was unlocked, and you had typed or clicked in Umi
within the last few minutes. Each stretch has its start, its end, the pane, its tab, and what the
pane showed (file path, agent session and title, cwd, your attributes at the time).
`umi focus-log --since 9am --json` returns the stretches; an end-of-day report is a script that
groups them by file, session or `project=`. It measures keyboard focus, not where you looked:
reading a pane you aren't typing in doesn't count.

**Activity log.** Beyond focus, the app keeps every change it makes or sees, with its cause: a pane
created, moved (from which tab and place, to which), hidden, shown, closed; an attribute set (by
you, a hook or a script); an agent's status change. Each entry says who caused it (a key, the
palette, a script, a hook, Umi itself). `umi log --since … --json` returns it and `umi events`
streams it. Scripts and agents use it to undo, to explain ("why did this pane move?"), and to
learn habits; "send back" reads a pane's last move from it.

### 3.2 Selection: queries and named lists

A query picks panes by attribute and orders them:

```
agent.status=needs_input
priority=high and not hidden | sort -priority, status_since
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
- `hide` (take a pane out of its tab's layout; it stays in that tab and its program keeps running; `--until CONDITION` brings it back by itself) and `show` (put it back in its tab). How it comes back is open: see decision 7;
- `move` to a named tab, so a tab can serve as a bucket ("Later", "Needs you");
- {==`seen` (mark looked at without focusing it);==}{>>is this a special case of attributes?<<}{#c2} this is only `set seen_at=now`, kept as a shorthand;
- {==`go LIST` / `go --next LIST`==}{>>Is this kind of “put tab X in front of user?”<<}{#c3} / `go --back` (generalised `jump`): put the first pane of a list in front of you, that is select its tab, bring its window and Umi forward, and focus it. `--next` walks the list; `--back` returns to where the walk started.

Every action takes a query as its target, so `umi pane hide 'project=old'` hides a group.

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
| `tab.summary` (which pane speaks for a tab in the sidebar) | the focused pane's agent, else the one most in need of you, else the most recent stop |
| `sidebar.icon`, `sidebar.tint` | from the pane `tab.summary` picks |
| `style.<query>` | border color, sidebar dot, dim, for panes matching the query |
| `notify` | none |

Plus `key.<keys> = <action>` so any list gets a shortcut, and palette commands: each executable in
`~/.config/umi/commands/` (or a `command."Title" = <shell command>` line) is an entry in ⌘P. It
runs with the calling pane, tab and window in its environment, and its output shows in the
palette. Scripts and agent skills, such as "Organize into tabs", are started from there.

### 3.5 Rules: when something happens, do something

| Approach | How | Good for | Cost |
|---|---|---|---|
| **External script** | a program reads `umi events` and calls `umi …` | anything; any language; easy to change | runs a few hundred ms late; must be kept running (launchd); can miss events while it's down |
| **Conditions on an action** | `umi pane hide P --until 'agent.done=false'` or `--until 2h` | one-off "come back when…" | each condition must be checkable by the app |
| **Rules in config** | `on agent.stop where … do show` | rules that must survive restarts and run instantly | the config grows into a programming language |
| **Policy command** | the app runs your command at a decision point and uses its answer, e.g. `hide.done-check = ~/bin/is-done` | one rich decision without a language | a slow or broken command delays the app; needs a timeout |

### 3.6 Worked examples

**Important panes.** A key toggles `priority=high` on the focused pane. `list.important` sorts
them. `landing = important` after 15 minutes away. `key.ctrl+cmd+] = go --next important`.
{==`style.priority=high = sidebar-dot:orange`.==}{>>Yeah, something we have not mentioned is a palette of visual primitives for example, we have the blue thing for focused panes, there’s some things we might want to do with the sidebar we want to keep these things mimimal and not too distracting, but it’s good to think about the space of options here<<}{#c8}

**Tabs as buckets.** Name a tab "Later". A palette command moves the focused pane there
(`umi pane move --tab Later`); a rule moves panes back to their project's tab when they need you.

**Hide until not done.** `umi pane hide --until 'agent.done=false or agent.status=needs_input'`.
The Stop hook sets `agent.done` from the last message (by the `hide.done-check` policy command, or a
regex). A pane that comes back gets `seen_at` older than `changed_at`, so it is in `unseen` and
`jump` reaches it.

**Return digest.** A script listening for `app.activated` after a long absence counts `unseen`,
`needs-you` and `agent.status=working`, and shows them through `notify` or a pane.

**Review walk.** `go --next unseen` bound to a key; each visit sets `seen_at`, so the list shrinks
as you go.

**Project focus.** `umi view project=impact-ops` dims or collapses tabs without a matching pane;
`umi view off` restores.

**Hand hidden panes to a manager.** Hide panes with `owner=manager`. A manager agent lists them
(`umi ls --where 'hidden and owner=manager'`), reads and answers them with `read` and `send`, and
calls `umi pane show` only for what it can't settle.

**Organize into tabs.** An agent reads `umi ls --json` (folders, branches, files, agent titles,
attributes), proposes groups, and applies them with `tab new`, `pane move` and `tab rename`.
Nothing new is needed in Umi beyond a dry run you approve first.

### 3.7 Visual vocabulary

Every attribute or list that shows on screen goes through a small set of visual channels. Keeping
the set small keeps Umi quiet. Today's channels: the cyan line on the focused pane's top edge, a
tab's color tint, the agent icon and its quiet color, sidebar line 2, the stack strip, the Dock
badge, the fade on tab switch. Direction: one small colour-coded indicator per pane replaces the focus line and the agent
marks. It shows focused, working, needs you, and finished but not seen, and appears wherever the
pane is represented (on the pane, its strip chip, its tab's sidebar row). Where it sits and how
it shows focus are open (`design/prototypes/pane-indicator.html`). The other candidates are
dropped. `style.<query>` sets the indicator's state colours and nothing else.

### 3.8 Arranging panes

New pieces for moving attention and panes around (prototypes in `design/prototypes/`):

- **Drawer.** A place that floats over the current tab without changing its layout, shown and put
  away by a key. Holds the manager pane (`key.ctrl+cmd+m = drawer toggle 'role=manager'`), a pane
  that resurfaces, or a pane you want for a moment. A pane can be docked from the drawer into the
  tab's split, or hidden again. *Decided:* a bottom drawer that rises over the lower half of
  the tab (option B in `drawer.html`). A pane waiting for it shows as a thin line along the bottom
  edge with a short label; the key brings it up.
- **Send back.** A pane moved to another tab can return to the tab and place it came from, read
  from the activity log.
- **Bucket tabs.** A tab you don't watch (such as `Delegated`, handled by the manager) can be
  collapsed at the bottom of the sidebar.
- **Moving panes from the keyboard with a preview.** A key lifts the focused pane; arrows move it
  over the sidebar's tabs while a preview shows where it would land in each (and which pane there
  would be hidden); Enter commits, Esc puts everything back. Targets include a new tab, bucket
  tabs and the tab it came from. Being explored in `keyboard-move.html`. Today ⌃⌘←/→ moves a
  pane to the previous or next tab at once, with no preview.
- **Split a tab by project.** A palette command groups a tab's panes by git repository and gives
  each group its own tab.
- **More panes than places.** A tab holds more panes than it shows. A switcher within the tab
  (most recent first) brings one in; the visible pane used least recently is hidden to make room,
  unless pinned in place. The limit of visible panes is per tab, three by default. The same rule
  decides where a resurfacing pane goes.

Selecting several panes at once is left out for now, to keep visual actions few.

## 4. Big design decisions

Each has a recommendation; your input changes what gets built.

1. **Where policy lives.** Options: config only, scripts only, or both.
   *Recommend:* named lists, bindings and styles in the config, because the app needs them
   instantly; anything triggered by events lives in your scripts, plus `--until` conditions and one
   or two policy commands. No general rules engine in the app until scripts prove too slow.
   *Decided:* agent tools such as the manager and "Organize into tabs" are skills that call
   `umi`, startable from ⌘P through palette commands.

2. **The query syntax.** Options: a small syntax of our own (`key=value and …  | sort`), jq over
   `ls --json`, or an established expression language (CEL).
   *Recommend:* our own small syntax. It has to be typed in the palette and in `--pane`, where jq
   is too heavy. Scripts that need more can run jq over `umi ls --json`.

3. **How long an attribute lives.** {==A pane outlives the programs in it: quit Claude==}{>>in practice I always quit panes instead of killing the current program, so let’s keep it simple<<}{#c9}.
   *Decided:* attributes live and die with the pane. `agent.*` ones are overwritten by the next
   agent's hooks.

4. **Panes or tabs as the unit of attention.** Attributes, lists and marks naturally sit on panes,
   but the sidebar shows tabs.
   *Recommend:* attributes on panes; {==a tab shows the strongest of its panes==}{>>this can be the default, but not hardcoded<<}{#c10} by default
   (the `tab.summary` slot, §3.4, so you can change it), and tabs can carry their own attributes too. Add a sidebar mode that lists panes from a
   named list later, if tab rows prove too coarse.

5. **Attention as facts, not flags.** Replace the `finished`/`needsYou` mark with `seen_at`,
   `changed_at` and `agent.status`, and derive "unseen" and "needs you" from them.
   *Recommend:* do. Every attention idea then reduces to queries over times and states.

6. **Fixed slots versus open-ended bindings.** The app can only hand over the decisions it
   exposes as slots.
   *Recommend:* a fixed, documented set of slots (§3.4), grown one at a time, rather than letting
   the config hook any internal decision.

7. **Where a pane can be.** Today{==: on show, stacked behind another, parked (agents only), cl==}{>>let’s make prototypes for how to express what we have and different visual options. this is one of the most important UI decisions we have<<}{#c11}osed
   for 60 s. *Decided:* any pane can be hidden, and a hidden pane stays inside its tab, visible
   in `ls` and the pane switcher. *Decided:* hidden panes show, and come back, through a pane strip along the top of the tab
   (option C in `design/prototypes/where-panes-live.html`). *Open:* the strip's order, where it sits
   among the other things at the top, and how ⌘[ and ⌘] move through it
   (`design/prototypes/pane-strip.html`). Coming back never moves keyboard focus.

8. **The CLI contract.** *{==Decided:* design the ==}{>>we can restart from scratch. I just want to get the best thing<<}{#c12}CLI from scratch around these
   primitives, then rewrite `acceptance/CLI.md` and its tests to match. Existing commands stay
   only where they fit.

---
comments:
  c1:
    by: user
    at: "2026-11-07T19:11:21.933Z"
    umi-quote: earns things
    umi-body: "I’d like to be able to extract at the end of the day the docuemtns and sessions I had on focus and for how much time, so I can track which tasks I devoted attention to"
    resolved: "Added an attention log (§3.1): focus stretches with what each pane showed; umi history --since … --json feeds an end-of-day report."
    status: resolved
  c2:
    by: user
    at: "2026-11-07T19:15:12.939Z"
    umi-quote: "`seen` (mark looked at without focusing it);"
    umi-body: "is this a special case of attributes?"
    resolved: "Yes: seen is set seen_at=now, kept as a shorthand."
    status: resolved
  c3:
    by: user
    at: "2026-11-07T19:18:03.238Z"
    umi-quote: "`go LIST` / `go --next LIST`"
    umi-body: "Is this kind of “put tab X in front of user?”"
    resolved: "Yes: put a list's first pane in front of you (tab, window, focus); --next walks the list."
    status: resolved
  c4:
    by: user
    at: "2026-11-07T19:19:29.054Z"
    umi-quote: "tcuts, update"
    umi-body: "write to sidebar?"
    resolved: "Nothing writes to it today. Line 2 becomes a template over attributes, so pane set writes to it."
    status: resolved
  c5:
    by: user
    at: "2026-11-07T19:23:28.099Z"
    umi-quote: today.
    umi-body: "I’d like to have a consistent visual identity for ‘panes not visible’ so far I want to use them for tasks that I suspect will be done and don’t want to touch unless they need my attention, but it seems like a more general thing. maybe I want to delegate sessions from hidden panes to a manager agent also, I’d like the comment box to expand so that it shows the full text I type"
  c6:
    body: hmmm
    by: user
    at: "2026-11-07T19:23:49.508Z"
    re: c5
  c7:
    body: "A thing with hidden panes is: sometimes I want to have a tab that has a unified purpose (e.g, editing my personal website) but that might have more than 3 panes and I want a view that makes it easy to have more panes on a tab without cluttering things\n\nanother affordance I imagine is having an ‘organize into tabs command’ where an agent looks at everything that’s open and puts it into meaningful tab groups"
    by: user
    at: "2026-11-07T19:26:37.045Z"
    re: c5
  c8:
    by: user
    at: "2026-11-07T19:29:09.670Z"
    umi-quote: "`style.priority=high = sidebar-dot:orange`."
    umi-body: "Yeah, something we have not mentioned is a palette of visual primitives for example, we have the blue thing for focused panes, there’s some things we might want to do with the sidebar we want to keep these things mimimal and not too distracting, but it’s good to think about the space of options here"
    resolved: "Added §3.7 Visual vocabulary; the prototypes page renders each channel with how loud it is."
    status: resolved
  c9:
    by: user
    at: "2026-11-07T19:30:31.535Z"
    umi-quote: "A pane outlives the programs in it: quit Claude"
    umi-body: "in practice I always quit panes instead of killing the current program, so let’s keep it simple"
    resolved: "Decided: attributes live and die with the pane."
    status: resolved
  c10:
    by: user
    at: "2026-11-07T19:31:22.247Z"
    umi-quote: a tab shows the strongest of its panes
    umi-body: "this can be the default, but not hardcoded"
    resolved: Made it the tab.summary slot with that default.
    status: resolved
  c11:
    by: user
    at: "2026-11-07T19:32:15.793Z"
    umi-quote: ": on show, stacked behind another, parked (agents only), cl"
    umi-body: "let’s make prototypes for how to express what we have and different visual options. this is one of the most important UI decisions we have"
  c12:
    by: user
    at: "2026-11-07T19:32:41.671Z"
    umi-quote: "Recommend:* add the ne"
    umi-body: we can restart from scratch. I just want to get the best thing
    resolved: "Decision 8 now: design the CLI from scratch, then rewrite CLI.md and tests."
    status: resolved
  c13:
    body: "Added 'hand hidden panes to a manager' and 'organize into tabs' to the worked examples (§3.6); both fit the primitives. The visual identity of hidden panes, including tabs with many panes, is what the prototypes cover; I'll resolve this once you've picked. The comment box that doesn't grow with your text is a separate editor fix, on the decision list."
    by: AI
    at: "2026-11-07T19:34:29.058Z"
    re: c5
  c14:
    body: "Building now: design/prototypes/where-panes-live.html, five options for hidden panes, each with a resurfacing demo, plus the visual vocabulary."
    by: AI
    at: "2026-11-07T19:34:29.068Z"
    re: c11

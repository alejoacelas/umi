# The archive

A place at the top of each window's sidebar for tabs Alejo will work on later, like WhatsApp's or
Telegram's archived chats. Archived tabs keep running; they are out of sight until he opens the
archive. Approved by Alejo on 2026-11-09.

## What it looks like

- An **Archived** row at the top of the sidebar, above the pinned tabs, showing how many tabs are in
  it ("Archived · 3"). It appears only while the window has an archived tab.
- It is closed by default. A click opens it in place, like a tab group: its tabs listed under the
  row in the same rounded box a tab group uses, in the order they were archived (latest last). A
  second click closes it. Whether it is open is remembered per window.
- The row shows no indicator: no mark and no `tab.summary` from the tabs inside. An archived tab's
  own row, when the archive is open, looks like any other tab's row.

## Archiving and bringing back

- ⌃⌘A archives the current tab; on an archived tab it brings the tab back. Focus moves to the tab
  the sidebar would select after closing it.
- A tab's right-click menu has Archive Tab (Unarchive Tab on an archived one); the Window menu and
  the palette have Archive Tab, Unarchive Tab and Show Archived (opens the archive and selects its
  first tab).
- An unarchived tab goes back to the top of the unpinned tabs. Archiving takes a tab out of its tab
  group and unpins it; unarchiving doesn't restore either.
- Selecting an archived tab (a click in the open archive, `tab focus`, ⌃⌘J landing on one of its
  panes) shows it without unarchiving it; it stays listed in the archive.
- In a ⌃⌘↑/↓ tab move, the Archived row is the last place above the first tab: landing there
  archives the tab.

## How it fits the primitives

- `archived` is an ordinary tab attribute (`archived=true`), so queries see it: `umi ls --where
  'tab.archived=true'`, and lists and scripts can use it.
- ⇧⌘[ ⇧⌘] and ⌘-number tab keys skip archived tabs. The default `jump` list leaves out panes in
  archived tabs.
- `tab archive [TAB] [--until CONDITION]…` and `tab unarchive [TAB]`. `--until` works as on `pane
  hide`: a query about any of the tab's panes, a duration, or both, and the first to hold brings the
  tab back. Example: `umi tab archive --until 'agent.status=needs_input'`.
- Events `tab.archived` and `tab.unarchived` (with `by_condition` when `--until` brought it back),
  recorded in the activity log.
- Archived tabs and their state survive a relaunch, and `--until` conditions do too.

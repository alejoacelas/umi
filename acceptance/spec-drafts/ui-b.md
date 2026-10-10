# UI-B: equal panes, reopen, sidebar rows, width, menu, drops, Markdown placement

Helper UI-B's notes for the lead. Code: worktree `~/dev/terminal-3/.worktrees/app-ui-b`, branch
`ui-b`. Tests: `acceptance/tests/test_tern_panes_ui.py`. Target: `acceptance/targets/tern-ui-b.json`.

---------------------------------------------------------------------------------------------------

## 1. SPEC text

All Fixed tier.

### L. Windows, tabs and panes (new)

- **L-19 [A]** Panes share the space equally, as in Warp. Panes in the same row (or column) share
  it equally after every split and close:
  - splitting a pane along its row adds a pane with an equal share: two panes are 50/50, a third
    makes 33/33/33, a fourth 25/25/25/25, whichever pane is split. Panes the user resized keep
    their proportions and the new pane gets 1/(N+1);
  - splitting across the row (a column in a row) halves only that pane; the row is unchanged;
  - closing a pane shares its space among the rest of its row in proportion to their sizes
    (33/33/33 → 50/50; 40/40/20 → 67/33 when a 40 closes);
  - this holds for every way of making or removing panes: the shortcuts and menus, `split`,
    dragging and dropping panes, `pane move`, and closes;
  - dragging a divider changes only the two panes beside it; double-clicking a divider gives its
    row (or column) equal shares and leaves the rest of the tab alone. ⌃⌘= and `tab equalize`
    still equalize the whole tab;
  - `split --ratio R` gives the new pane R of its row (or column); the others keep their
    proportions.

  `ls` and `pane info` report each pane's frame in its window's terminal area.

- **L-20 [A]** Reopen what was closed, as in Warp. ⇧⌘T (File ▸ Reopen Closed Pane/Tab/Window) and
  `<cli> reopen` bring back the last closed pane, tab or window, for 60 seconds after it closed:
  - a pane comes back in its tab, in the same place at the same size when the tab hasn't changed
    since, otherwise beside the pane it was next to, with its old share; if its tab is gone it
    comes back as a tab of its own where that tab was;
  - a tab comes back at its old position in its window, with its panes, name, color and pin; a
    window comes back with its tabs and frame;
  - for those 60 seconds the closed panes' programs keep running, with their scrollback, and they
    come back as they were. After 60 seconds they end, as closed panes always did;
  - the most recently closed item comes back first; something that already came back (by undo, say)
    or whose program ended is skipped. `<cli> reopen --list` shows what can come back;
  - closing a pane that shows an agent session never stops the session.

  ⇧⌘T is no longer a second Undo key. ⌘Z still undoes a close for Ghostty's `undo-timeout`.

### L-9 (one line to add, if UI-A doesn't already)
- ⇧⌘T reopens the last closed pane, tab or window (L-20).

### M. Moving live sessions (M-4 extended)

- **M-4 [W]** Panes can be dragged onto other panes, including in other windows. Tabs can be dragged
  in the sidebar to reorder them and onto another window's sidebar. Also, as in Warp:
  - a pane dropped on a tab's row moves into that tab (beside its focused pane, as ⌃⌘←/→ and
    `pane move --tab` place it); dropped between rows (the top or bottom quarter of a row) or below
    the rows, it becomes a new tab at that position. A thin accent line shows where it lands;
  - a tab dropped on the top or bottom half of a row lands before or after it, with the same line;
  - a tab dragged out of its window and dropped where nothing takes it becomes a window of its own
    at the drop point. Dropped back over its own window, nothing changes.

  Programs keep running through all of these (M-1, M-2).

### S. Sidebar and look

- **S-3 [W]** (rewritten) Tabs mode lists the window's tabs, grouped by tab, with pinned tabs first.
  Each row has two lines:
  - Line 1: the tab's folder (its focused pane's), or the name the user gave the tab. Then the git
    branch, a linked worktree shown differently from a normal checkout; a pane count when split;
    and close and pin affordances on hover.
  - Line 2: the title of the tab's agent session, when it has one. Otherwise what the focused pane
    is doing: the running command or the last one it ran, or an agent typed into it (running,
    exited); else the folder's path.
  - A tab with an agent session shows the agent's mark (Claude or Codex), small and monochrome, as
    its icon. When a session finished and the user hasn't looked at it yet, or it needs the user,
    the mark takes a quiet color. Looking at the pane (it has focus in the front window while the
    app is active, by a tab switch, a pane focus, or switching windows or apps) clears it; a session
    that finishes while the user looks at it leaves no mark. Colors and hints stay subtle. No desktop
    notifications. The Dock badge counts the sessions that need the user.

- **S-4 [W]** (extended) Rows can be clicked to select, double-clicked to rename, dragged to reorder
  (M-4), and right-clicked for Warp's menu: Pin/Unpin Tab; Copy Branch, Copy Working Directory,
  Copy Title; Rename Tab…, Reset Tab Name, Rename Pane…, Reset Pane Name (the tab's focused pane);
  Move Tab Up, Move Tab Down (within the pinned or unpinned group); Close Tab, Close Other Tabs, Close
  Tabs Below; Tab Color ▸; Move Tab to New Window, Move Tab to Window ▸. A tab's color tints its
  row, quietly.

- **S-8 [A+W]** Each window's sidebar can be made wider or narrower by dragging its edge, between
  180 points and the smaller of 600 points and half the window. The width is per window, saved and
  restored with the layout; a new window starts at the width last chosen. Double-clicking the edge
  goes back to the default. `<cli> sidebar width [N]` shows or sets it; `sidebar status` still
  answers `visible` and `mode` (and now the window's `width`).

### E. Editor and Markdown

- **E-10 [A]** A Markdown (or text) file opened from outside the app (Finder, `open FILE`, the app
  being the default for Markdown) opens in the tab whose folder is closest to the file: the tab with
  a pane whose working directory is the deepest folder containing the file. Any pane of a tab counts;
  `/` doesn't. A file already open somewhere shows there. Ties go to the current tab, then the
  current window's tabs in sidebar order, then other windows'. With no such tab it opens in a new
  tab in the file's folder, in the current window (a new window if there is none). The ⌘O Open
  panel still opens in the current tab.

### CHECKS.md text (written checks)

- **S-3: tab rows.** Setup: tabs named and unnamed; a git repo on a branch; a linked worktree; a split
  tab; a pinned tab; an agent session working, one finished while another tab was in front, one that
  needs the user; an interactive `claude --version` that has exited.
  - Pinned tabs are first.
  - Line 1 has the folder (or the tab's name), then the branch; the worktree looks different. Split
    tabs show a pane count.
  - Line 2 has the session's title for agent tabs; otherwise the running or last command or the
    interactive agent's state.
  - Agent tabs show a small monochrome Claude or Codex mark. The finished-unseen and needs-you marks
    have a quiet color; nothing is loud. Selecting the tab clears the color.
  - Close and pin controls appear on hover (by hand).
- **S-4: row interactions (by hand).** Click selects; double-click renames; right-click shows Warp's
  items (see S-4); dragging reorders with an insertion line.
- **S-8: sidebar width (by hand).** Drag the sidebar's edge: the cursor is a resize cursor; it stops
  at the limits; another window keeps its width; quitting and relaunching keeps both.
- **M-4: dragging (by hand).** Add: drag a pane's grab handle onto another tab's row (it moves into
  that tab) and between two rows (a new tab there, with an insertion line); drag a tab row out of
  the window and let go over the desktop (a new window there).

---------------------------------------------------------------------------------------------------

## 2. CLI.md text

Layout table, new rows:

| Command | Notes |
|---|---|
| `reopen [--list]` | reopens the last closed pane, tab or window (closed in the last 60 s); prints the pane's id (the window's for a window); JSON `{"kind": "pane"\|"tab"\|"window", "pane"?, "tab", "window"}`; exit 1 when there's nothing to reopen. `--list`: JSON `{"items": [{"kind", "closed_at", "expires_in", "panes": [id], "tab"?, "title"?, "tabs"?}]}`, most recent first |
| `sidebar width [N] [--window W]` | prints the window's sidebar width in points; with N sets it (clamped to 180–600) |

Changed rows:
- `sidebar [on|off|toggle|status|tabs|files] [--window W]`: JSON `{"visible": bool, "mode": "tabs"|"files", "width": points, "window": id}` (`width` and `window` are new; `width` is W's, else the calling or current window's). The CLI already accepted `--window` and the app ignored it; an unknown W is now an error that changes nothing (L-4).
- `split … [--ratio R]`: R is the new pane's share of its row (or column); the others keep their proportions.

Objects: **Pane** gains `"frame": {"x", "y", "width", "height"}` (points, top-left origin, in the
window's terminal area, from the split ratios; for a tab that isn't shown, where it will be when
shown). In `ls` and `pane info`.

Events: `pane.created` and `tab.created` carry `"reopened": true` when `reopen` brought them back.
`sidebar.changed` is also emitted when a window's sidebar width changes (with `width` and `window`).

---------------------------------------------------------------------------------------------------

## 3. Decisions

**D1. Equal panes on Ghostty's binary tree (L-19).** Options: (a) replace `SplitTree` with an n-ary
tree like Warp's; (b) keep the binary tree and treat a maximal chain of same-direction splits as
one row ("run"), as WARP-PARITY §2.1 proposes. Picked (b): every caller, the persistence format
(`ratio`), undo snapshots and SwiftUI's split views stay as they are. `SplitTree.inserting` and
`removing` (which every path goes through: ⌘D/menus, `split`, drops, `pane move`, closes, hidden-tab
splits, undo restores) now insert with share 1/(N+1) and remove proportionally, rebuilding the run
as a right-leaning chain. Evidence: `test_splits_along_a_row_share_it_equally`,
`test_closing_a_pane_shares_its_space_in_proportion`, `test_moves_and_drops_share_rows_equally`,
`test_splits_in_a_background_tab_share_equally_too`, the SplitTree unit tests. Known limit (as
WARP-PARITY says): closing D in `Row[A, Col[Row[B,C], D]]` joins B and C to A's row.

**D2. A divider drag moves only its two neighbors.** In a chain `A|(B|C)` the divider between A and
B is the split `A|rest`; moving its ratio would rescale B *and* C. Warp moves only A and B. Picked
Warp's behavior: the new shares are written back into the run's existing shape (no structural
change, so SwiftUI keeps the views and the drag isn't interrupted). Keyboard resize
(`pane resize`, ⌃⌘↑/↓) uses the same rule. Evidence:
`test_a_divider_moves_its_neighbors_and_double_click_equalizes_its_row`.

**D3. `--ratio`.** It used to set the ratio of the split holding the new pane. With runs, that would
mean a fraction of some sub-chain. Picked: R is the new pane's share of its row; the others keep
their proportions. Same result as before for a single pane (the old test still holds). Evidence:
`test_ratio_sets_the_new_panes_share_of_its_row`, `test_split_with_name_ratio_and_cwd`.

**D4. Pane sizes for tests: `frame` from ratios.** NSView frames lag right after a split and don't
exist for hidden tabs. Picked: frames computed from the ratios over the window's measured terminal
area (SwiftUI's GeometryReader around the split view). Extra field, backward compatible.

**D5. Reopen is its own stack (L-20).** Options: (a) set `undo-timeout = 60s` and make ⇧⌘T replay
only undo entries for closes (WARP-PARITY gap 3); (b) a separate stack whose entries hold the closed
panes, tabs and windows for 60 s. Picked (b): undo's stack is linear (a later move or pin is undone
first), and its entries can't be popped out of order. `undo-timeout` stays Ghostty's 5 s for ⌘Z.
Items on the stack keep their processes; when an item expires nothing holds its panes and they end.
The 60 s is Warp's default grace period, fixed (not a setting). Evidence:
`test_reopen_brings_a_closed_pane_back_to_its_slot_with_its_program`,
`test_closed_items_expire_after_60_seconds_and_their_programs_end` (slow).

**D6. What counts as a close.** Recorded: a user's close of a pane (⌘W, the menu, `pane close`,
also in hidden tabs), a tab (sidebar ✕, menu, `tab close`, Close Other Tabs/Below), a window (red
button, ⇧⌘W, `window close`); the last tab of a window records the window. Not recorded: moves
(drag, `pane move`, `tab move`), panes whose program exited (they can't come back running), closes
done by Undo of New Tab/New Window. An entry is skipped at reopen time if its panes are back in a
window (Undo brought them back) or all ended. Evidence:
`test_reopen_goes_last_closed_first_and_skips_what_came_back`,
`test_a_pane_whose_program_ended_is_not_reopened`.

**D7. Where a reopened pane goes.** Warp drops a pane's reopen entry once its tab is rearranged.
Picked a softer rule: if the tab's tree is as the close left it, the old tree comes back exactly
(same slot, same sizes); otherwise the pane goes beside the pane it was next to, in the same
direction, with its old share; failing that, beside the tab's focused pane; if the tab is gone, a
tab of its own at the old index (the current window if that window is gone). Reopening registers an
undo step ("Reopen Closed Pane/Tab/Window"). Evidence:
`test_a_pane_comes_back_beside_its_neighbor_after_its_tab_changed`,
`test_reopen_brings_back_closed_tabs_and_windows_in_their_place`.

**D8. Row line 1 and line 2 (S-3).** The user: "its folder and then its session's title". Picked:
line 1 is the folder, unless the user named the tab (a name is explicit, so it wins; clearing it
brings the folder back). Line 2: the agent session's title (TernAttention), falling back to its
status while it has no title; for a tab with no agent, what the old S-3 said (running or last
command, an interactive agent's running/exited, else the folder's path). The session shown is
`TernAttention.agent(for:in:)`'s choice (focused pane's, else the strongest mark, else the latest
stop). Evidence: `test_rows_show_the_folder_then_the_sessions_title`,
`test_a_tab_without_an_agent_shows_its_command_on_line_2`, `test_rows_keep_the_branch_and_pane_count`.

**D9. Agent data comes only from TernAttention.** The row used to read the old engine's
`TernAgentUI` snapshot (status · activity). It now reads only `TernAttention`, the interface the
lead's engine writes. Until the engine writes it, managed sessions show as plain terminals in rows.

**D10. Marks.** Claude: a starburst of rays; Codex: a hexagon around a dot (11 pt, stroked,
monochrome, drawn as SwiftUI shapes: no bundled logos). Colors: none → the chrome's tertiary ink;
finished-unseen → Tern's accent at 85 %; needs-you → a muted amber at 90 %. Line 2 is brighter while
the session works. No dots, badges or animation on rows.

**D11. Looking.** Defined as "focused in the key window while the app is active" (TernAttention's
words). Wired at: pane focus changes (`focusedSurfaceDidChange`), tab switches (`selectTab`),
`pane focus`/`tab focus` from the CLI (`TernLayout.focusPane`), window becoming key, the app becoming
active. A session that *finishes* while its pane is being looked at is cleared at once (Warp: a
notification raised while visible starts out read). A session that starts *needing the user*
while looked at isn't cleared by that alone, only by the next look event: TernAttention says the
engine re-marks a still-waiting session on its next update, so clearing needs-you on every change
could ping-pong with the engine. Evidence:
`test_looking_at_the_pane_clears_the_mark` (with `debug.ui.assume_active`), and the `ui` test
`test_looking_at_the_pane_clears_the_mark_ui` for real activation.

**D12. Tab color is a row tint.** The 7 pt color dot sat in the icon slot, which agent marks now
need. Picked Warp's way: the color tints the row (8 % at rest, 16 % hovered or selected).

**D13. Drop zones (M-4).** Panes: middle half of a row → into that tab; top or bottom quarter →
a new tab before or after; below the rows → a new tab at the end (Warp's zones). Into a tab, the
pane goes beside that tab's focused pane, to the right (as ⌃⌘←/→ and `pane move --tab`), rather than
at the tab's root as Warp does, so the drag, the shortcuts and the CLI agree. Tabs: top or bottom
half → before or after. A 2 pt accent line shows edge drops; the row tints for "into". A pane
dropped on its own one-pane tab, or a tab on itself, does nothing. Evidence:
`test_a_pane_dropped_on_a_row_moves_into_that_tab`, `test_a_pane_dropped_between_rows_makes_a_new_tab_there`,
`test_a_tab_dropped_between_rows_lands_there`.

**D14. Dragging a tab out (M-4).** SwiftUI's `onDrag` can't tell how a drag ended, so a row's drag
now starts an AppKit dragging session (from a SwiftUI `DragGesture`, minimum 5 pt) whose
`endedAt` sees drops nothing took. Such a drop outside the tab's own window makes a new window there
(the drop point lands on its sidebar near the top); Escape cancels; a drop back over its own window
does nothing (a missed reorder shouldn't tear the tab off). Warp detaches on any drop outside a tab
bar. A window's only tab dragged out moves the window. Evidence:
`test_a_tab_dragged_out_of_its_window_makes_a_window_at_the_drop_point` (the drop handler) and the
`ui` test `test_dragging_a_tab_row_out_of_the_window_makes_a_window_ui` (the real drag).

**D15. Sidebar width (S-8).** Warp: 200 px to 50 % of the window, not saved. Picked: 180–600 pt, and
at most half the window while dragging; saved per window in `layout.json` (`sidebar_width`) and the
last chosen width in `ui.json` for new windows; a tab moved to a new window takes its old window's width;
double-click resets. Per-window *visibility* (optional) is not done: ⌘B is UI-A's item and the
global `TernState.sidebarVisible` is read in several places; it stays app-wide. Evidence:
`test_each_window_has_its_own_sidebar_width`, `test_sidebar_widths_are_restored_with_the_layout`.

**D16. Row menu (S-4).** Warp's sections and order; "Close Other Tabs" and "Close Tabs Below" don't
spare pinned tabs (as Warp) and ask first if a program runs; each closed tab can be reopened. Colors
are a submenu with a checkmark (SwiftUI context menus can't show a row of color dots). "Rename Tab…"
starts the in-place edit; "Rename Pane…" asks with a sheet. Move Tab Up/Down stay within the pin
group: this overlaps UI-A's ⌃⇧←/→; both call `TerminalController.moveTab` inside
`TernLayout.undoable` and emit `tab.moved`, so either can call the other's at merge time. Evidence:
`test_the_row_menu_has_warps_items`, `test_move_tab_up_and_down_stay_in_their_pin_group`,
`test_close_other_tabs_and_tabs_below`.

**D17. The closest tab for a file (E-10).** "Closest": the deepest folder that contains the file
among every pane's working directory (symlinks resolved, so `/tmp` and `/private/tmp` match). Any
pane of a tab counts, not only the focused one (a tab is "in" the folders of all its panes). `/`
never counts (it contains everything); the home folder does. A file already open in some tab shows
there. Ties: the current tab, then the current window in sidebar order, then other windows oldest
first. No match: a new tab started in the file's folder, in the current window (so the next file
from that folder joins it), a new window if none. The Open panel (⌘O) keeps opening in the current
tab, since the person chose from there. Evidence: `test_markdown_opens_in_the_tab_whose_folder_is_closest`,
`test_ties_go_to_the_current_tab_and_any_pane_of_a_tab_counts`.

**D18. Scripted checks of mouse-only paths.** `debug.ui.*` control methods (internal, like
`debug.menu`) call the same functions the UI calls: rows (`TernSidebarRowModel`, which the view
renders), drops, the drag-end handler, the row menu (`TernTabMenu.items`, which the context menu
renders), split drops and dividers, the open-file path, and stand in for the engine's TernAttention
writes. `debug.ui.assume_active` counts the app as active (the CLI can't bring it to the front while
the person uses another app). The real gestures are `ui` tests.

---------------------------------------------------------------------------------------------------

## 4. Test changes

- `macos/Tests/Splits/SplitTreeTests.swift` (unit, upstream Ghostty's):
  `equalizedAdjustsRatioByLeafCount` expected the root ratio after two splits along a row to be
  0.5 before equalizing. L-19: "panes in the same row or column share it equally after every split"
  makes it 1/3 before equalizing too. Expectation changed; four tests added for runs.
  I couldn't run the unit tests through `xcodebuild test`: the test host is the app, and with the
  user's installed Tern running it loses the single-instance lock of the default state directory,
  asks that copy to show itself (P-3) and exits ("test runner exited with code 0"). I stopped after
  that one attempt (it may have brought the user's Tern to the front once). Instead the same
  assertions ran in a standalone program built from `SplitTree.swift` (all pass). The lead can run
  `GhosttyTests/SplitTreeTests` with the installed Tern quit.
- `acceptance/tests/test_layout.py`: no change needed. `test_split_with_name_ratio_and_cwd` splits a
  single pane with `--ratio 0.3`, which means the same thing under D3.
- CHECKS.md S-3, S-4, M-4 (and a new S-8): new text in §1 above. The old S-3 check expects line 2
  to show "the managed agent's status and activity"; now it's the session's title.

---------------------------------------------------------------------------------------------------

## 5. Tests added (`acceptance/tests/test_tern_panes_ui.py`)

CLI and `debug.ui.*` (run with `-m "not ui and not real"`; one is `slow`):

| Test | Proves |
|---|---|
| `test_splits_along_a_row_share_it_equally` | L-19: 33/33/33, then 25×4 with a split to the left; a split across halves only that pane |
| `test_closing_a_pane_shares_its_space_in_proportion` | L-19: 33×3 → 50/50; 40/40/20 → 67/33 |
| `test_ratio_sets_the_new_panes_share_of_its_row` | L-19, `--ratio`; `tab equalize` still evens a tab |
| `test_moves_and_drops_share_rows_equally` | L-19 through `pane move` and pane drops (cross-window and within) |
| `test_splits_in_a_background_tab_share_equally_too` | L-19 in hidden tabs, without focus changes |
| `test_a_divider_moves_its_neighbors_and_double_click_equalizes_its_row` | L-19 divider rules |
| `test_ls_and_pane_info_report_pane_frames` | the `frame` field |
| `test_reopen_brings_a_closed_pane_back_to_its_slot_with_its_program` | L-20: same slot and size, same program and scrollback |
| `test_a_pane_comes_back_beside_its_neighbor_after_its_tab_changed` | L-20 fallback placement |
| `test_reopen_brings_back_closed_tabs_and_windows_in_their_place` | L-20 tabs (index, name, panes) and windows (tabs, panes) |
| `test_reopen_goes_last_closed_first_and_skips_what_came_back` | L-20 order, `--list`, skipping |
| `test_a_pane_whose_program_ended_is_not_reopened` | L-20: exited panes aren't recorded |
| `test_shift_cmd_t_is_reopen_in_the_file_menu` | L-20/L-9: ⇧⌘T is the File menu item (and not Undo); its title; it reopens |
| `test_closed_items_expire_after_60_seconds_and_their_programs_end` (slow, ~75 s) | L-20 expiry; the shell lives while reopenable and ends after |
| `test_rows_show_the_folder_then_the_sessions_title` | S-3 lines and icons (Claude, Codex), name over folder |
| `test_a_tab_without_an_agent_shows_its_command_on_line_2` | S-3/S-6 for plain tabs |
| `test_rows_keep_the_branch_and_pane_count` | S-3 line 1 extras |
| `test_an_unseen_finish_or_a_question_colors_the_icon_and_counts_on_the_dock` | S-3 marks; the Dock badge still counts |
| `test_looking_at_the_pane_clears_the_mark` | S-3 looking (tab switch, pane focus, a finish while looking) with `assume_active` |
| `test_the_row_menu_has_warps_items` | S-4 items and actions (copies to a private pasteboard, resets, color, pin) |
| `test_move_tab_up_and_down_stay_in_their_pin_group` | S-4 Move Tab Up/Down, pin boundary |
| `test_close_other_tabs_and_tabs_below` | S-4 closes; reopenable |
| `test_each_window_has_its_own_sidebar_width` | S-8 per window, limits, `sidebar width`, `status` keeps its fields |
| `test_sidebar_widths_are_restored_with_the_layout` | S-8 persistence (restoration-safe build) |
| `test_a_pane_dropped_on_a_row_moves_into_that_tab` | M-4 into a tab; program kept; own row refuses |
| `test_a_pane_dropped_between_rows_makes_a_new_tab_there` | M-4 before/after/end; emptied tab closes |
| `test_a_tab_dropped_between_rows_lands_there` | M-4 tab reorder by halves |
| `test_a_tab_dragged_out_of_its_window_makes_a_window_at_the_drop_point` | M-4 drag-out handler: inside does nothing; outside makes a window at the point |
| `test_markdown_opens_in_the_tab_whose_folder_is_closest` | E-10 deepest folder, already-open, new tab in the file's folder |
| `test_ties_go_to_the_current_tab_and_any_pane_of_a_tab_counts` | E-10 ties and non-focused panes |

**AX UI tests the lead must run** (`ui` fixture; they move the mouse):
- `test_the_split_menu_items_share_equally` — Split Right / Split Down menu items (⌘D/⇧⌘D) on the
  focused pane give equal shares.
- `test_looking_at_the_pane_clears_the_mark_ui` — real activation clears marks.
- `test_dragging_a_tab_row_out_of_the_window_makes_a_window_ui` — real mouse drag of a row out of
  the window.
- `test_dragging_a_tab_row_reorders_and_the_row_menu_opens_ui` — real drag reorder with the
  insertion zones, and AXShowMenu on a row shows Warp's items.

---------------------------------------------------------------------------------------------------

**Runs.** Phase 1 without UI (`--phase 1 -m "not ui and not real"`, against this build): 101
passed; the 6 failures were all in UI-A's new `test_tern_nav.py`, whose features aren't in this
build. After the last changes: `test_tern_panes_ui.py`, `test_layout.py`, `test_tern_extra.py`,
`test_editor.py` (not slow): 76 passed; the slow expiry test passed (61 s). The four `ui` tests
collect; I didn't run them.

## 6. Left open / risks

- **Merge conflicts to expect** (small, mostly additive): `TerminalController.swift` (UI-A: tab
  history/order; mine: close hooks, `closeTabs(otherThan:)`, `closeTabs(below:)`, `sidebarWidth`,
  `terminalAreaSize`, looking calls in `selectTab`/`focusedSurfaceDidChange`/`windowDidBecomeKey`),
  `TernTheme.defaultsConfig` (my `keybind = super+shift+t=unbind` block; UI-A adds unbinds for tab
  keys), `AppDelegate` (two install lines after `TernShortcuts.install()`), `TernRPC.swift` (`sidebar`
  width, `reopen`, `debug.ui.*` routing), `TernLayout.swift` (`focusPane` looking call,
  `move(tab:…at:)`), `TernSidebar.swift` if UI-A reorders rows there (rows render `controller.tabs`
  in order, so ordering in the controller needs no sidebar change).
- **Move Tab Up/Down** exist twice after the merge (UI-A's ⌃⇧←/→ and my row menu); make the row menu
  call UI-A's function if it has one (`TernTabMenu.move(_:by:in:)` is the only call site).
- **The palette** doesn't list "Reopen Closed …" (it lists `TernShortcuts.items`; my item is a File
  menu item installed by `TernReopen.installMenu`). UI-A's ⌘P could list it, or `reopen` as a CLI command.
- **For the lead's engine (TernAttention):** no API change. The rows need `kind`, `title` (line 2),
  `status` (`working` brightens line 2) and `mark`. Keep a pane's session mapping while the pane is
  closed but reopenable (`TernReopen.shared.holds(paneID)`), so a reopened agent pane shows its
  session again; I didn't change `TernAgentUI`'s detaching. A session marked `needsYou` while its
  pane is looked at keeps its mark until the next look (D11).
- **Agent panes' grip** (`TernAgentPane.swift`) untouched: it already drags `.ghosttySurfaceId`, so
  dropping agent panes on rows works the same.
- **Real-mouse behavior** of the row drag (SwiftUI `DragGesture` starting an AppKit session) and the
  sidebar's resize edge (cursor, hit area 4 pt inside the edge) is only checked by the `ui` tests and
  by hand. If the gesture misbehaves, the fallback is an `NSView` drag source over the row.
- **Not done (optional or out of scope):** per-window sidebar visibility (D15); Warp's row gestures
  (middle-click close, double-click empty space for a new tab, ⌘-hold hints); the reopen grace period
  as a setting.
- **COMPROMISES.md, row "Undo of a closed pane or tab":** replace with: "⌘Z undoes a close for
  Ghostty's `undo-timeout` (5 s); ⇧⌘T / `reopen` bring a closed pane, tab or window back for 60 s,
  and its programs live that long; undo of a move lasts 10 minutes and holds no process." The
  phase-1 reason ("a closed pane's process stays alive only while its undo can bring it back") now
  reads "…while undo or reopen can bring it back".

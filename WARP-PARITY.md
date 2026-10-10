# Warp parity audit: windows, tabs, panes (and what hangs off them)

Audited 2026-10-10. Read-only: no code was changed, Warp was not launched, Tern's GUI was not driven.

- **Warp:** source at `~/dev/warp`, commit `6398d1e` (2026-10-03), treated as the truth. docs.warp.dev is cited only where used.
- **Tern:** `~/dev/terminal-3/app` at `2fa4d48ed` (the build released as 0.3.0, which is installed in /Applications), plus `acceptance/REQUESTS.md`, `SPEC.md`, `CHECKS.md`, `COMPROMISES.md`, `DECISIONS.md` and `REPORT.md`.

Path prefixes used below:

| Prefix | Path |
|---|---|
| `W:` | `~/dev/warp/app/src/` |
| `T:` | `~/dev/terminal-3/app/macos/Sources/` |
| `Z:` | `~/dev/terminal-3/app/src/config/Config.zig` (Ghostty's default keybindings; Tern doesn't change this file) |
| `TD:` | Tern's product defaults: `T:Features/Tern/TernTheme.swift` (`defaultsConfig`, loaded before the user's Ghostty config) |

**Warp's feature flags.** Warp ships some features behind flags. Unless a row says otherwise, everything compared here is on in a release build, either through the Cargo default features or through `RELEASE_FLAGS` (`crates/warp_features/src/lib.rs:1083-1095`).

**Warp's vertical tabs.** They are a release feature, but the user setting that turns them on is off by default (`W:workspace/tab_settings.rs:500-508`). Tern's sidebar is compared against Warp *with vertical tabs on*, since that's what the user asked for.

---------------------------------------------------------------------------------------------------

## 1. UI gaps, by how much they matter in daily use

"Spec" names the requirement a change would have to amend; a blank cell means the change fits the current spec. Details for each row are in §5.

| # | Gap | Warp | Tern now | Change | Spec |
|---|---|---|---|---|---|
| 1 | **Panes don't share space equally** | Panes are flex siblings. A same-direction split adds a sibling with flex 1, so 3 panes are 33/33/33. Closing one shares its space among the remaining siblings (`W:pane_group/tree.rs:927-979, 996-1030`). | Binary splits at 0.5. Splitting halves only the focused pane: a second split gives 50/25/25 (`T:Features/Splits/SplitTree.swift:542`). Closing gives all the space to the binary sibling (`:598-633`). | Make `SplitTree.inserting/removing` work on same-direction runs and redistribute proportionally (§2.1). | |
| 2 | **Tab-switch keys only work while a terminal has focus** | ⇧⌘[ / ⇧⌘], ⌘1–8, ⌘9 (last) and ⌃Tab are `Workspace`-context bindings, so they work whatever has focus in the window (`W:workspace/mod.rs:343-356, 549-640`). | These are Ghostty *surface* keybindings (`Z:6816-6821, 7064-7097, 7239-7244`) with no menu item. They are dead in the editor, sidebar, file tree, an agent pane's composer and the palette. | Add Window-menu items in `TernShortcuts` that select tabs through `TerminalController`, and unbind the Ghostty defaults in `TD:` (§2.2). | |
| 3 | **Reopening a closed pane/tab/window** | ⇧⌘T pops a stack that holds only closed windows, tabs and panes, each for **60 s** (`W:undo_close/settings.rs:17-26`, `stack.rs:59-69`). A pane comes back in the same slot at the same size. | ⇧⌘T is plain **undo** (`Z:7149`), so it may undo a move, pin or split instead of the close. A close can be undone for only **5 s** (`undo-timeout`, `Z:2733`; COMPROMISES phase 1). | Add a "Reopen Closed" item on ⇧⌘T that replays only close entries, and set `undo-timeout = 60s` in `TD:`. | COMPROMISES row on undo |
| 4 | **Drag a pane onto a tab row** | Middle half of a row: the pane moves into that tab. Top or bottom quarter: it becomes a new tab there, shown with a 3 px accent line (`W:pane_group/pane/view/header/mod.rs:333-391`; `W:workspace/view.rs:16886-16942, 17076-17131`). | A row only accepts tab drags (`T:Features/Tern/TernSidebar.swift:314`); a pane drop is ignored. | Accept `.ghosttySurfaceId` on rows and between rows; call `TernLayout.move(pane, to: .besidePane/.newTab)`. | M-4 (extend) |
| 5 | **⌃⌘← / ⌃⌘→ resize panes in Warp** | ⌃⌘←→↑↓ move a divider by 10 px (`W:pane_group/mod.rs:414-450`). | ⌃⌘←/→ move the pane to the previous/next tab, and Ghostty's resize-left/right is unbound for that (`TD:` lines 105-107; `T:Features/Tern/TernShortcuts.swift:47-50`). Only ⌃⌘↑/↓ resize. | Give ⌃⌘←/→ back to resizing; move "Move Pane to Previous/Next Tab" to other keys (for example ⌃⌥⌘←/→). | L-9 |
| 6 | **Move the tab up/down from the keyboard** | ⌃⇧← / ⌃⇧→ ("move tab up/down" in vertical mode). They don't cross pin or group boundaries (`W:util/bindings.rs:309-322`; `W:workspace/mod.rs:893-920`). | No key on macOS: Ghostty's `move_tab` is bound only on Linux (`Z:6800-6825` block). The sidebar menu has no move up/down either. | Add "Move Tab Up/Down" on ⌃⇧←/→ (menu and sidebar row menu), using `TerminalController.moveTab`, which already respects pins. | |
| 7 | **Palette keys and navigation palette** | ⌘P opens the command palette (actions, sessions, files and more). ⇧⌘P opens the navigation palette: every pane in every window, most-recent first, with the running or last command and a "Current" pill (`W:util/bindings.rs:285, 351`; `W:search/command_palette/navigation/render.rs:67-108`). | ⌘P does nothing. ⇧⌘P opens Ghostty's palette: actions plus alphabetical "Focus: …" rows. Those rows use the *selected* tab's name for every pane in the window (`T:Features/Command Palette/TerminalCommandPalette.swift:77, 99-135`). | Bind ⌘P to the existing palette. Make ⇧⌘P a sessions-only mode: MRU order, tab name, cwd, running or last command. | |
| 8 | **Attention indicators on tab rows** | 8 px unread dot when an agent finished, needs input or errored while unseen; cleared when its pane gets focus (`W:workspace/view/vertical_tabs.rs:3409-3530`). Red triangle when the last command failed (`W:terminal/view.rs:13024-13031`). "Maximized" tab indicator (`W:tab.rs:1203, 1227`). Desktop notification on a password prompt. | Line 2 shows a managed agent's status, but only when its pane is the focused one. Nothing marks unseen completion, a needed input, a failed command, a bell, a zoomed tab or a password prompt (`T:Features/Tern/TernSidebar.swift:176-310`). | Add a row badge: unseen managed-session completion/needs-input, a bell or OSC 9/777 notification while not visible, `passwordInput` while not visible, last exit code ≠ 0, zoomed. Clear on focus. | |
| 9 | **Search tabs** | The panel header has "Search tabs...". It matches title, cwd, branch, kind, PR and diff text, and ⇧⌘[ ] then cycle only through matches (`W:workspace/view/vertical_tabs.rs:1400-1452, 4253-4272`; `W:workspace/view.rs:12245-12295`). | None. | Add a filter field above the rows; make next/previous tab follow the filter. | |
| 10 | **Which pane gets focus after a close** | The previously focused pane (pane history); directional moves prefer the most recently used candidate (`W:pane_group/mod.rs:5687-5722, 5820-5835`). | The previous pane in tree order, or the next if the closed pane was leftmost (`T:Features/Terminal/BaseTerminalController.swift:520-530`). Ghostty picks the nearest pane for directional moves. | Keep a per-tab focus history; use it after a close and to break ties in directional moves. | |
| 11 | **Row menu and row gestures** | The menu has Close other tabs, Close tabs below, Copy branch/working directory/title/PR link, Rename pane/Reset name, Move tab up/down, plus a row of color dots (`W:tab.rs:456-465, 583-806, 951-1017`). A tab color tints the whole row. Middle-click closes. A ⋮ menu shows on hover. Double-click on empty space makes a new tab. Holding ⌘ shows ⌘1–9 hints (`W:workspace/view/vertical_tabs.rs:349-357, 1741-1750, 2549-2555, 3470-3486`). | The menu has Rename, Pin, Tab Color ▸, Move to new/other window, Close (`T:Features/Tern/TernSidebar.swift:334-363`). Color is a 7 px dot (`:192`). None of the gestures exist. `closeOtherTabs` and `closeTabsOnTheRight` exist but are reachable from nowhere (`T:Features/Terminal/TerminalController.swift:1170-1200`). | Add the missing items and gestures; tint the row with the tab color. | S-4 (extend) |
| 12 | **Drag a tab out of the window** | Dropping a tab outside any tab bar makes a new window at the drop point (`W:workspace/cross_window_tab_drag.rs:1379-1441`). | Only the context menu or ⌃⇧⌘N. Dropping onto another window's sidebar already works (M-4). | On a drag ending with no target, call `TernLayout.move(tab:…, newWindow: true)` at the drop point. | |
| 13 | **Sidebar width and per-window visibility** | The panel resizes from 200 px to 50 % of the window. Open/closed is per window (`W:workspace/view/vertical_tabs.rs:91-93, 1754-1763`; `W:workspace/view.rs:4320-4350`). | Fixed at 252 pt (`T:Features/Tern/TernTheme.swift:40`). One app-wide toggle (`T:Features/Tern/TernState.swift:13`). | A drag edge with min/max and a width saved in `ui.json`; visibility per window, saved in `layout.json`. | S-2 wording ("toggled with ⌘B") still holds |
| 14 | **⌘O** | Files palette: fuzzy search over the current repo, recent and git-changed files first, `path:line` understood (`W:search/files/model.rs:94-128`; `W:search/files/data_source.rs:23-30`). | macOS Open panel (`T:Features/Tern/TernEditor.swift:555`). | A files mode of the palette rooted at the focused pane's repo, with "Browse…" for the Open panel. | L-9 ("⌘O opens a file") still holds |
| 15 | **Project explorer** | Details in §5.15 (`W:code/file_tree/view.rs:144-172, 2327-2449, 3146-3181`): one tree per tab with a root for each pane's repo or cwd; reveals the file being edited; follows `cd`; arrow and Enter keys; New file, Rename, Delete, cd to directory, Copy relative path; drag a file onto a terminal to insert its path; hidden files toggled with ⇧⌘>; gitignored files dimmed; ⌃1 shows it. | One root: the focused pane's git root, re-polled every 1.5 s. Click only; no keyboard. Menu: Open in Editor, Open with Default App, Open Terminal Here, Insert Path, Copy Path, Reveal (`T:Features/Tern/TernFileTree.swift:79-92, 207-256`). | Add the missing items and keys. Delete should go to the Trash, not Warp's immediate delete. | |
| 16 | **Pane chrome in splits** | Split terminal panes get a 34 px header: title, ⋯ menu with Maximize/Minimize, ✕ close, an accent triangle on the active pane, and the whole header drags (`W:terminal/view/pane_impl.rs:727-739`; `W:pane_group/pane/view/header/mod.rs:47, 490-494, 1004-1025`). Inactive panes aren't dimmed by default (`W:settings/pane.rs:5-13`). Right-click has Maximize pane and Close pane (`W:terminal/view.rs:18022-18085`). | No header: a grab handle on hover; inactive panes dimmed to 0.8 (`TD:` line 102). Right-click has splits but no maximize or close (`T:Ghostty/Surface View/SurfaceView_AppKit.swift:1620-1645`). | A slim header in splits only (pane name or title, ⋯, ✕, drag), and drop the dimming. At minimum, add Zoom and Close Pane to the right-click menu. | S-1 says no containers or borders. A title row isn't a box, but confirm with the user. |
| 17 | **Editor details** | ⌘F opens the editor's find with replace and regex; ⌃G goes to a line. Editor tabs reorder by drag. The tab strip shows only with 2+ files (`W:code/editor/view/actions.rs:596-615`; `W:code/view.rs:2391-2426, 2482-2499`). | ⌘F probably opens the *terminal's* search: the menu sends `find:` to the controller (`T:App/MainMenu.xib:272`; `T:Features/Terminal/BaseTerminalController.swift` `find`), although the text view has a find bar (`T:Features/Tern/TernEditor.swift:871`). Verify by hand. No tab reorder. | Route ⌘F/⌘G/⇧⌘G to the editor when it has focus (in `TernEditorContainerView.performKeyEquivalent`); drag-reorder chips; hide the strip with one file. | |
| 18 | **Hover details on a tab row** | A popover with every pane: status, full cwd, branch, command, kind; code panes show file and "Unsaved" (`W:workspace/view/vertical_tabs.rs:6659-7148`). | A tooltip with the cwd. | A popover listing the tab's panes (name, cwd, branch, running/last command, agent state). | |
| 19 | **Keys while a pane is maximized** | ⌥⌘arrows and ⌃⌘arrows are inactive while maximized; ⌘[ ] and focus changes unmaximize (`W:pane_group/mod.rs:326-449`; `W:pane_group/focus_state.rs:95-105`). | ⌥⌘arrows unzoom and move (Ghostty default, `T:Features/Terminal/BaseTerminalController.swift:737-743`). | Optional: ignore directional moves and resizes while zoomed. Low value. | |
| 20 | **Rename shortcut** | Rename edits the row title in place (`W:workspace/view/vertical_tabs.rs:4783-4794`). Warp has no default key. | ⌃⌘R opens a modal alert (`T:Features/Tern/TernShortcuts.swift:189-225`); double-click already edits in place. | Make ⌃⌘R start the in-place edit when the sidebar is visible. | |
| 21 | **Synchronized input** | ⌥⌘I types into all panes of the tab; there are per-window and stop variants and a tab indicator (`W:util/bindings.rs:380-382`; `W:workspace/sync_inputs.rs:13-52`). | None. ⌥⌘I is Ghostty's inspector (`Z:7366`). | Add it by forwarding key input to every pane of the tab. It collides with the inspector key. | |
| 22 | **Full-screen state restored** | Restored (`crates/persistence` `windows` row; `W:persistence/sqlite.rs:982`). | `layout.json` stores frames but not full screen (`T:Features/Tern/TernPersistence.swift:77-110`). | Save and restore a `fullscreen` flag. | |
| 23 | **Launch and tab configurations** | YAML launch configs open from the ⌃⌘L palette, File menu or `warp://launch/`, and a "Save New…" modal captures them. TOML tab configs have parameters and worktree templates (⌃⌘T menu, "Save as new config"). Details in §5.23. | None. The CLI scripts layouts (`tab new`, `split`, `--worktree`). | If wanted: a "Save Layout as…" / "Open Layout…" pair built on the `layout.json` serializer, plus a palette mode. | |
| 24 | **Explorer and tabs side by side** | The project explorer sits in its own left panel, beside the vertical tabs panel (`W:workspace/view.rs:22962-22977`), resizable from 250 px to 75 % (`W:workspace/view/left_panel.rs:1415-1430`). | One sidebar with exclusive Tabs/Files modes. | Show Files as a second column, or a split inside the sidebar. | S-2 ("two modes") |
| 25 | **Diff and PR chips on rows** | `+N −M` and a PR link on rows (on by default) (`W:workspace/view/vertical_tabs.rs:5541-5648`). | Branch and worktree only. | A diff chip from `git diff --shortstat`; the PR chip needs `gh`. | S-3 (extend) |
| 26 | **Global search** | ⇧⌘F or ⌃3 opens a left-panel search across files (`W:workspace/mod.rs:842-850`). | None. ⇧⌘F is Ghostty's `end_search` (`Z:7340`). | Low priority; it collides with ⇧⌘F. | |

---------------------------------------------------------------------------------------------------

## 2. The two items the user flagged

### 2.1 Equal panes: how Warp sizes panes, and what to change

**Warp's model** (`W:pane_group/tree.rs`)

- **The tree is n-ary.** A `PaneBranch` has an axis and a list of `(PaneFlex, PaneNode)` children (`:132-136`). Every new child gets `DEFAULT_FLEX_VALUE = 1.0` (`:26-27`). Children are laid out with `Shrinkable::new(flex, …)`, so each child's share is its flex divided by the sum of its siblings' flex (`:1074-1093`).
- **Splitting** pane P toward D (`PaneBranch::split`, `:927-979`; `PaneBranch::new`, `:902-914`):
  - If P's parent branch has the same axis as D, the new pane is inserted as a **sibling** next to P (before it for left/up, after it for right/down) with flex 1.0. The existing siblings keep their flex.
    - With untouched sizes, N panes become N+1 **equal** panes: ⌘D, ⌘D gives 33/33/33, and a third ⌘D gives 25/25/25/25.
    - After manual resizing, the new pane gets 1/(N+1) and the others shrink proportionally.
  - If the axes differ, or P is the root, P is replaced by a two-child branch `[P:1, new:1]`. That halves P's slot, and P's share in its parent is unchanged.
  - The base pane is always the focused pane (`W:pane_group/mod.rs:3920-3936`). The minimum size isn't checked at split time.
- **Closing** (`PaneBranch::remove`, `:996-1030`) removes the child from its branch. The remaining siblings keep their flex, so **the closed pane's space is shared among all of them in proportion**: 33/33/33 becomes 50/50.
  - If one child is left, the branch collapses into that child, which takes the branch's slot.
  - During the 60 s undo grace period the closed pane is hidden but stays in the tree. Hidden nodes are skipped when laying out, so the space is shared at once, and undo puts the pane back with its old flex (`:1074-1080`; `W:pane_group/mod.rs:4823-4851, 5618-5637`).
- **Drag-moving** a pane removes it and splits again at the target, by the same rules (`W:pane_group/mod.rs:5664-5685`). Dropping on a whole-tab edge inserts at the root (`PaneData::split_root` / `PaneNode::insert`, `tree.rs:466-469, 703-711, 965-994`; `mod.rs:5642-5662`).
- **Double-clicking a divider** resets **only that branch** to equal flex (`:1191-1205, 1404-1419`).
- **There is no "equalize all" action.** Keyboard resize moves a divider by 10 px and is refused below the minimum pane size, which is 190 px with the default input mode (`W:pane_group/mod.rs:228-239, 6001-6045`; `tree.rs:1144-1189`).
- **Launch configs** always open their splits equal; pane sizes are restored only by session restoration.

**Tern's model** (Ghostty's `SplitTree`)

- **The tree is binary.** A split has a `ratio`, and `inserting` always replaces the target leaf with a new 0.5 split (`T:Features/Splits/SplitTree.swift:512-549`), so only the focused pane is halved.
- **Removing a leaf** replaces its parent split with the sibling subtree, and the grandparent keeps its ratio (`:598-633`). The closed pane's whole space goes to its **binary sibling**, which may be one pane or a subtree, not to the visual row or column.
- **Equalize exists, for the whole tab.** ⌃⌘= (`Z:7309`), Window ▸ Equalize Splits, `tern tab equalize` (`T:Features/Tern/TernLayout.swift:334-336`) and a double-click on *any* divider (`T:Features/Splits/SplitView.swift:62`) all call `equalized()` (`SplitTree.swift:676-730`).
- **Every layout path goes through these two functions:**
  - ⌘D / ⇧⌘D and the menu splits: `TerminalController.newSplit`, `T:Features/Terminal/TerminalController.swift:807-818`.
  - `tern split` and agent `--split`: `TernLayout.split`, `TernLayout.swift:140-174`.
  - Drag-and-drop moves: `BaseTerminalController.swift:1006-1046`.
  - `pane move`: `TernLayout.swift:384-430`.
  - Closes: `BaseTerminalController.removeSurfaceNode`, `:537-548`, and `TerminalController.swift:752, 782`.

**Side by side** (columns, left to right; "⌘D on X" means split X to the right):

| Sequence | Warp | Tern today |
|---|---|---|
| ⌘D on A | A 50 · B 50 | A 50 · B 50 |
| then ⌘D on B | 33 · 33 · 33 | A 50 · B 25 · C 25 |
| then ⌘D on C | 25 · 25 · 25 · 25 | 50 · 25 · 12.5 · 12.5 |
| A\|B, then ⌘D on A | 33 · 33 · 33 | A 25 · X 25 · B 50 |
| 3 equal columns (after ⌃⌘=), close the middle one | 50 · 50 | 33 · 67 |
| 3 columns resized to 50/30/20, close the 30 | 71 · 29 (proportional) | depends on which binary sibling it had: 50·50 or 80·20 |
| ⇧⌘D on the middle of 3 equal columns | columns stay 33; the middle one is split 50/50 vertically | same |

**The change** (UI layer: `SplitTree.swift`; nothing in persistence, because ratios are already saved)

- **Define a run** as a maximal chain of nested splits with the same direction; it is Warp's branch. Its members are the maximal subtrees not split in that direction. Each member's share is the product of the ratios along its path inside the run, and the shares sum to 1.
- **Inserting** pane `new` next to P in direction D:
  - If P's parent split has D's direction, P is a member of a run with N members. Insert `new` next to P (before it for left/up, after it for right/down).
  - Give `new` a share of 1/(N+1) and scale every other share by N/(N+1). This equals Warp exactly when sizes are untouched, and proportionally otherwise.
  - Rebuild the run's binary ratios from the shares, for example as a right-leaning chain: `rᵢ = sᵢ / (sᵢ + … + s_N)`.
  - Otherwise keep today's 0.5 split of P.
- **Removing** a member of a run with three or more members: drop it and rescale the rest by `1/(1 − s_removed)`. With two members, keep today's collapse.
- **Double-clicking a divider:** equalize only that divider's run, as Warp does. Keep ⌃⌘= and `tab equalize` for the whole tab; Warp has no equivalent, and it costs nothing.
- **Keep:** `--ratio R` still sets the new pane's share afterwards (`TernLayout.swift:153-155`); undo snapshots are unchanged; and the M-5 size rules for panes moved into new windows still apply.
- **Known edge case.** A binary tree can't tell a nested same-direction branch from a flat one. When Warp collapses `Row[A, Col[Row[B,C], D]]` by closing D, the result is `Row[A, Row[B,C]]` with the inner row kept separate. Tern would treat A, B and C as one run, so a later split there distributes over 4 panes instead of 3. This is rare and acceptable.
- **Tests:** only `test_split_with_name_ratio_and_cwd` checks a ratio (`acceptance/tests/test_layout.py:34`), and it splits a single pane, so it stays valid. Add tests for 3 equal splits, closing the middle pane, and a proportional close.

### 2.2 Tab switching: why ⇧⌘[ / ⇧⌘] die outside a terminal

**In Warp**
- `workspace:activate_prev_tab` / `activate_next_tab` are bound to `shift-cmd-{` / `shift-cmd-}` in the context `Workspace & Workspace_MultipleTabs & !Workspace_PaneDragging` (`W:workspace/mod.rs:620-640`). ⌘1–8 and ⌘9 are at `:548-619`; ⌃Tab and ⌃⇧Tab at `:343-356` and `W:util/bindings.rs:279-280`.
- The Workspace view is the ancestor of the terminal, the code editor, the file tree and the side panels, and key dispatch walks outward from the focused view. So these keys work **whatever has focus in the window**. A deeper view that binds the same key wins; none does for these keys.
- Both directions wrap. When the vertical-tabs search has a query, they cycle only through the matches (`W:workspace/view.rs:12245-12295`).

**In Tern**
- The keys are Ghostty's defaults:
  - `super+shift+[` / `]` → `previous_tab` / `next_tab` (`Z:7239-7244`)
  - `super+1…8` → `goto_tab`, `super+9` → `last_tab` (`Z:7064-7097`)
  - `ctrl+tab` / `ctrl+shift+tab` (`Z:6816-6821`)
- A Ghostty keybinding only fires when a terminal *surface* is the first responder. The action then goes through `Ghostty.App.gotoTab` (`T:Ghostty/Ghostty.App.swift:1311-1335`) to `TerminalController.onGotoTab`, which also requires the posting surface to be the window's focused surface (`T:Features/Terminal/TerminalController.swift:1308-1333`).
- **No menu item or app-level handler covers these keys.** MainMenu.xib has no tab-navigation items, and `TernShortcuts.items` has none (`T:Features/Tern/TernShortcuts.swift:21-67`). So with focus in any of these places the keys go nowhere:
  - the editor panel (its `performKeyEquivalent` handles only ⌘W/⌘S/⇧⌘M; `T:Features/Tern/TernEditor.swift:824-845`)
  - a sidebar rename field
  - the file tree
  - an agent pane's composer (DECISIONS §14: keyboard focus is the composer)
  - the command palette
- The same applies to `move_tab`, which isn't bound on macOS anyway.
- **A guard that doesn't fit Tern's tabs.** `Ghostty.App.gotoTab` also requires `window.tabGroup.windows.count > 1` (`Ghostty.App.swift:1326`). That check was written for AppKit tab groups, which Tern turned off (`tabbingMode = .disallowed`, `T:Features/Tern/TernTerminalWindow.swift:14`). The user reports the keys work while a terminal has focus, so something lets them through. Still, the fix shouldn't rely on that path.

**The change** (UI layer)
- **Add Window-menu items** in `TernShortcuts.items`, so they also appear in the palette:
  - Show Previous Tab ⇧⌘[ and Show Next Tab ⇧⌘], both wrapping.
  - Show Tab 1…8 on ⌘1…⌘8, and Show Last Tab on ⌘9.
  - Next/Previous Tab on ⌃Tab / ⌃⇧Tab.
  - Move Tab Up/Down on ⌃⇧← / ⌃⇧→ (gap 6).
- **Make them act on `TernTopology.currentWindow`** through `TerminalController.selectTab` / `moveTab`. Menu key equivalents work from any first responder.
- **Unbind the Ghostty defaults** for those keys in `TD:`, the way ⌃⌘←/→ are unbound today (`TernTheme.swift:105-107`). Then exactly one path handles them, and it doesn't depend on `gotoTab`'s tab-group guard.
- **Test by hand** with focus in the editor (source and preview), the file tree, the rename field, an agent composer and a terminal. The suite's `test_shortcuts_are_menu_items` can be extended to the new items.

---------------------------------------------------------------------------------------------------

## 3. Shortcuts: Warp next to Tern, and collisions

Warp's macOS defaults come from `W:util/bindings.rs:265-472`, `W:workspace/mod.rs` and `W:pane_group/mod.rs:317-480`. Tern's come from `Z:` plus `T:Features/Tern/TernShortcuts.swift`.

| Key | Warp | Tern | Verdict |
|---|---|---|---|
| ⌘T / ⌘N / ⌘W / ⇧⌘W | new tab / new window / close pane / close window | same | Same |
| ⌘D / ⇧⌘D | split right / down | same | Same |
| ⌥⌘arrows, ⌘[ / ⌘] | move between panes / previous–next pane | same | Same |
| ⇧⌘↩ | maximize pane | zoom split | Same |
| ⌘1–8, ⌘9 | tab N, last tab | same, but only with terminal focus | Gap 2 |
| ⇧⌘[ / ⇧⌘] / ⌃Tab | previous / next tab | same, but only with terminal focus | Gap 2 |
| ⌘B | toggle the vertical tabs panel | toggle the sidebar | Same |
| ⇧⌘T | reopen closed session (60 s) | undo (anything), 5 s for closes | **Collision in meaning** (gap 3) |
| ⌃⌘← / ⌃⌘→ | move divider left / right | move pane to previous / next tab | **Collision** (gap 5) |
| ⌃⌘↑ / ⌃⌘↓ | move divider | resize split | Same |
| ⌃⇧← / ⌃⇧→ | move tab | — (passed to the terminal) | Gap 6 |
| ⌘P | command palette | — | Gap 7 |
| ⇧⌘P | navigation palette | command palette | **Collision** (gap 7) |
| ⌘O | files palette | Open panel (L-9) | **Collision in meaning** (gap 14) |
| ⌃⌘T | tab configs menu | move pane to new tab (L-9) | **Collision** (Warp's is a tab-configs feature Tern lacks; gap 23) |
| ⇧⌘M | agent management view (AI) | toggle Markdown preview (L-9) | Collision with an AI feature Tern doesn't have; keep Tern's |
| ⌥⌘I | synchronize inputs in tab | terminal inspector | **Collision** (gap 21) |
| ⇧⌘F | global search | end terminal search | **Collision** (gap 26) |
| ⌃1 / ⌘\ | project explorer / left panel | — (Tern: ⇧⌘E, unbound in Warp) | Add ⌃1 as an alias (gap 15) |
| ⇧⌘> | toggle hidden files | — | Gap 15 |
| ⌃⌘L | launch config palette | — | Gap 23 |
| ⌃⌘F | full screen | full screen (also ⌘↩) | Same |
| ⌃⌘= | — | equalize splits | Tern extra; keep |
| ⌥⌘W | — | close tab | Tern extra |
| ⌃⌘N, ⌃⇧⌘N, ⌃⌘P, ⌃⌘R, ⌃⇧⌘R, ⌃⌘J, ⇧⌘E | — | Tern's L-9 keys | No collision |

---------------------------------------------------------------------------------------------------

## 4. Same (no change needed)

**Windows**
- ⌘N opens a window that inherits the focused session's folder (Warp: `W:workspace/view/startup_directory.rs:64-77`; Tern: `window-inherit-working-directory = true`, `Z:2089`).
- ⇧⌘W closes with a confirmation when a program runs.
- ⌃⌘F is native full screen.
- Window frames, the active tab, tab names, colors and pins, split layout and sizes, the focused pane and each pane's folder are restored, saved continuously (Warp: `W:persistence/sqlite.rs`; Tern: `T:Features/Tern/TernPersistence.swift`).
- Neither app has its own ⌘\` code.
- A hotkey or quick-terminal window exists with no default key: Warp's dedicated hotkey window is off by default; Tern has Ghostty's Quick Terminal.

**Tabs**
- New tabs go after the current one and inherit the source pane's folder (Warp: `W:workspace/view.rs:13065-13089`; Tern: `window-new-tab-position = current`, `Z:2313`, and `T:Features/Terminal/TerminalController.swift:582-599`).
- ⌘W closes the pane, then the tab, then the window.
- Closing the active tab selects the next tab, or the previous one if it was last (Warp: `W:workspace/view.rs:12419-12427`; Tern: `TerminalController.swift:202-224`).
- Closing a tab asks when a program runs.
- Pinned tabs come first and drags can't mix the groups.
- Double-click renames in place, and an empty name clears it.
- A close ✕ shows on hover and the selected row is tinted.
- Next/previous tab wraps; ⌘9 goes to the last tab.
- A tab dropped onto another window's sidebar moves there (M-4).
- Neither panel has keyboard navigation of its own.
- The "+" creates a tab; Warp's horizontal "+" does, and its vertical "+" opens a menu.

**Panes**
- ⌘D/⇧⌘D split the focused pane; split left/up exist in the menus with no key.
- The new pane takes focus and inherits the folder.
- Directional moves don't wrap.
- ⌃⌘↑/↓ and the menu items move a divider by 10.
- ⇧⌘↩ zooms per tab: splitting or focusing another pane unzooms (Warp: `W:pane_group/focus_state.rs:95-105`; Tern: `TernLayout.swift:201-207`).
- Closing a pane asks when a program runs.
- Dragging a pane onto another pane's edge splits it there.
- A lone pane can't be dragged.
- Dividers are 1 px with a wider invisible grab area (Warp: `W:pane_group/tree.rs:29-39`; Tern: `T:Features/Splits/SplitView.swift:33-34`).
- Neither draws a focus border.

**Editor and Markdown**
- Markdown opens rendered, with a visible Rendered/Source control (Warp: `W:notebooks/file/mod.rs:1222-1258`; Tern: E-2).
- ⌘S saves.
- Closing a file with unsaved edits asks first.
- A file changed on disk reloads when clean and shows a banner when dirty.

**Notifications**
- Notifications for finished commands are off by default.
  - Warp's mode is `Unset` with a banner offering to enable it (`W:terminal/session_settings.rs:38-54`); once on, the threshold is 30 s.
  - Tern has Ghostty's `notify-on-command-finish = never` (`Z:1214`). `= unfocused` with `notify-on-command-finish-after = 30s` reproduces Warp's enabled behaviour.
- OSC 9/777 from programs become desktop notifications.
- Clicking a notification focuses the pane.
- The bell bounces the Dock; neither app has a visual bell.

**Tern beyond Warp (keep).** Panes move between windows by drag; Warp can't (`W:pane_group/pane/view/header/mod.rs:988-990`). Panes move to a new tab or window or the next tab by keyboard, and tabs move between windows by menu. Swap, ⌃⌘= equalize, pane names as CLI selectors, the whole CLI, unsaved edits kept across quits, and a running-command marker on rows (Warp shows no spinner).

---------------------------------------------------------------------------------------------------

## 5. UI gaps in detail

Each gap has the same three parts: Warp's behavior, what Tern does now, and the change. Gaps 1 and 2 are in §2.

**3. Reopen closed (⇧⌘T, 60 s)**
- **Warp:**
  - `app:reopen_closed_session` pops a LIFO, unbounded stack of closed windows, tabs and panes. Each entry expires after `general.undo_close.grace_period`, 60 s by default (`W:undo_close/settings.rs:6-27`; `stack.rs:59-69, 161-164, 366-399`). It is also in File ▸ and the "+" menu.
  - A closed pane stays alive, hidden in its slot, and returns at the same position and size.
  - A closed tab keeps idle shells but kills running commands (`W:workspace/view.rs:12376-12395`).
  - Rearranging panes in that tab drops the pane's undo (`W:pane_group/mod.rs:5649-5651, 5675-5677`).
- **Tern now:**
  - ⇧⌘T and ⌘Z are both `undo` (`Z:7149, 7155`). Undo replays the most recent undoable action, which may be a move (10-minute expiry), a pin or a split rather than the close.
  - Closes expire after `undo-timeout`, 5 s (`Z:2733`; COMPROMISES phase 1, "Undo of a closed pane or tab").
- **Change:**
  - Keep a Tern-side "closed items" stack: the close paths already register restore closures (`TerminalController.swift:845-886`, `BaseTerminalController` close undo).
  - Bind a "Reopen Closed Pane/Tab/Window" item to ⇧⌘T in File, enabled only when the stack isn't empty.
  - Set `undo-timeout = 60s` in `TD:` (the user's Ghostty config can override it). This keeps closed panes' processes alive for 60 s, as Warp does; no new mechanism is needed.
  - Agent panes are unaffected: closing never touches the session (AP-4).
  - Update COMPROMISES' undo row.

**4. Drag a pane onto the sidebar**
- **Warp:**
  - The pane is dragged by its header (split panes only).
  - The middle half of a tab row activates that tab live and places the pane at its root; dropping there leaves it at the root on the left, or at the top in vertical mode.
  - The leading or trailing quarter of a row, or empty space below the rows, makes a new tab at that index. The drop is shown with a 3 px accent line.
  - A source tab left empty closes without an undo entry (`W:pane_group/pane/view/header/mod.rs:328-391`; `W:workspace/view.rs:16886-16942, 17076-17131`; `W:pane_group/mod.rs:4375-4379`).
- **Tern now:** rows accept only `tern-tab:` strings (`T:Features/Tern/TernSidebar.swift:40, 314`); a pane's drag item is `.ghosttySurfaceId` (`T:Features/Splits/TerminalSplitTreeView.swift:110`). The moves exist (`TernLayout.move(_:to:)` with `.besidePane` and `.newTab`, `TernLayout.swift:351-430`) and are undoable.
- **Change:**
  - Make tab rows and the gaps between them drop targets for `.ghosttySurfaceId`.
  - Middle: move beside the target tab's focused pane, or at the root. Edges: a new tab at that index. Below the rows: a new tab at the end.
  - Draw an insertion line for the edge drops. This also covers dragging agent panes, which use the same drag source (`T:Features/Tern/Agents/TernAgentPane.swift:79`).

**5. ⌃⌘←/→**
- **Warp:** `pane_group:resize_left/right/up/down` on ⌃⌘arrows move the divider by `KEYBOARD_RESIZE_DELTA = 10` (`W:pane_group/mod.rs:230, 414-450, 6001-6045`).
- **Tern now:** L-9 assigns ⌃⌘←/→ to "Move Pane to Previous/Next Tab", and `TD:` unbinds Ghostty's resize-left/right to make room (`TernTheme.swift:104-107`). The keys came from the reference UI (`.ref/WraithShortcuts.swift:67-70`), not from the user's words.
- **Change** (needs an L-9 amendment):
  - Remove the two `unbind` lines so ⌃⌘←/→ resize again.
  - Rebind the moves, for example to ⌃⌥⌘←/→, which are free in both apps.
  - Update `test_shortcuts_are_menu_items`, `verify_ui_paths.py:82` and CHECKS L-9.

**6. Move tab up/down**
- **Warp:**
  - `workspace:move_tab_left/right` are on ⌃⇧←/→ and labelled "move tab up/down" in vertical mode.
  - They are disabled at the ends and don't cross pin or group boundaries (`W:workspace/mod.rs:893-920`; `W:workspace/view.rs:14446-14536`).
  - The row menu has Move Tab Up/Down (`W:tab.rs:706-731`).
- **Tern now:** nothing on macOS. `onMoveTab` exists for Ghostty's `move_tab` (`TerminalController.swift:1297-1306`), but that action is bound only on Linux.
- **Change:** add menu and row-menu items that call `TerminalController.moveTab`, which already clamps to the pin group, wrapped in `TernLayout.undoable`. Emit `tab.moved`.

**7. Palettes**
- **Warp:**
  - ⌘P opens the command palette, which mixes actions (with their shortcut chips), sessions, files and launch configs. Its empty view shows recent items.
  - ⇧⌘P opens the navigation palette:
    - Every terminal pane in every window, most-recently-focused first.
    - Line 1 is the prompt or cwd. Line 2 is "Running…", "Completed N minutes ago" or "Empty Session". The current pane has a "Current" pill.
    - Selecting one raises its window, focuses the pane and activates the tab.
  - Pressing the same key again closes the palette (`W:search/command_palette/navigation/render.rs:67-108, 244-381`; `navigation/search.rs:226-232`; `W:workspace/view.rs:15057-15077`).
- **Tern now:**
  - One palette, on ⇧⌘P (`Z:7123`). It is sorted alphabetically and mixes Ghostty actions, Tern items and "Focus: <title>" rows.
  - Every "Focus:" row in a window shows the *selected* tab's custom name (`controller.titleOverride`) and the window-level tab color, not the pane's own (`TerminalCommandPalette.swift:99-135`).
  - It only opens when a surface was focused (`T:Features/Terminal/TerminalView.swift:111-118`).
- **Change:**
  - Bind ⌘P to the palette.
  - Make ⇧⌘P a sessions-only mode: MRU order; the pane's tab name, then folder and branch; running or last command (`TernPaneContext.command`); a "Current" marker.
  - Fix the per-pane title and color in the existing rows.
  - Agent sessions ("Show Agent: …") can stay in both modes.

**8. Attention indicators**
- **Warp:**
  - The unread dot is driven by agent notifications only (complete, needs input, error). A notification raised while the pane is visible starts out read, and the dot clears when the pane gains focus (`W:workspace/view/vertical_tabs.rs:3409-3530`; `W:workspace/view.rs:5580-5586`).
  - A red triangle shows when the last command failed. It clears when a new command starts, not when you look (`W:terminal/view.rs:13024-13031`; `W:workspace/view/vertical_tabs.rs:5434-5457`).
  - Agent status badges sit on the row icon.
  - A Maximized indicator shows on the tab (`W:tab.rs:1203-1231`).
  - Password prompts raise a "needs attention" notification (`W:terminal/view.rs:27170-27186`).
- **Tern now:**
  - Line 2 reflects only the *focused* pane: a managed agent's status, an interactive agent's running/exited state, or the running or last command (`TernSidebar.swift:176-300`).
  - AP-7 notifications and ⌃⌘J exist, but nothing on the row says a background pane or tab needs you.
- **Change** (all data is already in the UI layer):
  - A dot on a row when any pane in the tab:
    - has a managed session that finished or needs input since it was last visible (the AP-7 logic);
    - rang the bell or posted an OSC 9/777 notification while not visible;
    - is at a password prompt while not visible (`SurfaceView.passwordInput`, `T:Ghostty/Ghostty.App.swift:1777-1803`).
  - A red triangle when the focused pane's last exit code is non-zero. `TernInteractive.commandFinished` already receives `exitCode`; `TernCommandLog` would keep it.
  - A zoom glyph when the tab is zoomed.
  - Clear the dot when the pane is focused.

**9. Search tabs**
- **Warp:**
  - The header field filters rows by title, cwd, kind, branch, PR and diff text.
  - With no hits it says "No tabs match your search." Esc clears it and refocuses the active tab.
  - ⇧⌘[ ] cycle through the matches only.
  - No key focuses the field (`W:workspace/view/vertical_tabs.rs:1400-1452, 1907-1927, 4253-4272`).
- **Tern now:** none.
- **Change:** add a field above the rows in Tabs mode, matching name, folder, branch and command. Make gap 2's next/previous items follow the filter.

**10. Focus history**
- **Warp:** after a close it focuses `pane_history[len-2]` when there's enough history, falling back to tree order. Directional moves pick the most recently used candidate (`W:pane_group/mod.rs:5687-5722, 5745-5778, 5820-5835`).
- **Tern now:** previous or next in tree order (`BaseTerminalController.swift:520-530`).
- **Change:** keep a per-`TernTab` list of recently focused panes, and use it in `findNextFocusTargetAfterClosing` and for ties in `focusTarget(for:)`.

**11. Row menu and gestures**
- **Warp's menu sections** (`W:tab.rs:456-465`):
  1. Pin
  2. Groups (not applicable here; see N3)
  3. Share (not applicable)
  4. Copy branch / pane or tab title / working directory / PR link (only those with a value)
  5. Rename tab, Reset tab name, Rename pane / Reset pane name, Move Tab Up / Move Tab Down
  6. Close tab, Close other tabs, Close Tabs Below (pinned tabs aren't exempt)
  7. Save as new config
  8. A row of color dots, where the first means none
- **Warp's colors:** a tab color tints the row at 15 % at rest and 50 % when hovered or selected (`W:workspace/view/vertical_tabs.rs:118-121, 349-357`).
- **Warp's gestures:**
  - Middle-click closes (`:2549-2555`).
  - A ⋮ menu button shows on hover (`:2443-2461`).
  - Double-clicking empty panel space makes a tab; right-clicking it opens the new-session menu (`:1741-1750`).
  - Holding ⌘ shows ⌘N hints (`:3470-3486`).
- **Tern now:** `TernSidebar.swift:334-363` and `:192`.
- **Change:** add these menu items (Close Other Tabs and Close Tabs Below already exist as `TerminalController.closeOtherTabs` / `closeTabsOnTheRight`), color dots or a tint, middle-click, double-click on empty space, and the ⌘-hold hints.

**12. Drag a tab out to make a window**
- **Warp:** with `DragTabsToWindows`, which is in macOS `RELEASE_FLAGS`, a tab dragged 10 px off the panel detaches into a preview window, and dropping it outside any tab bar makes a new window there. Dropping it on another window's panel inserts it there, unpinned, after that window's pinned tabs (`W:workspace/view.rs:28349-28414, 28786-28986`).
- **Tern now:** only the drop onto another window's sidebar works (`TernSidebar.swift:40-46, 314-320`).
- **Change:**
  - Detect a tab drag that ends with no target, using `NSDraggingSession`'s `endedAt` as Ghostty does for panes (`T:Ghostty/Surface View/SurfaceDragSource.swift:231-250`).
  - Then call `TernLayout.move(tab:…, newWindow: true)` with the frame at the drop point.

**13. Sidebar width and per-window state**
- **Warp:** the panel's default width is 248 px, between 200 px and 50 % of the window; the width isn't saved. Open/closed is per window and restored (`W:workspace/view/vertical_tabs.rs:91-93, 739, 1754-1763`).
- **Tern now:** `TernTheme.sidebarWidth = 252`. Visibility is the global `TernState.sidebarVisible`, so ⌘B toggles every window.
- **Change:**
  - A drag edge with min/max.
  - Visibility per `TerminalController`, saved in `layout.json` and still reported by `tern sidebar status` for the current window.
  - Keep `TernTheme.chromeSize` in step so M-5's sizing holds.

**14. Files palette on ⌘O**
- **Warp:** fuzzy search over the git repo of the focused session's folder, or that folder without recursion when it isn't a repo. Up to 100 results; recently opened, then git-changed files first; `path:line:col` understood. Selecting a file opens Warp's editor (`W:search/files/model.rs:94-128`; `W:search/files/data_source.rs:23-30, 202-206, 272-297`).
- **Tern now:** NSOpenPanel.
- **Change:** a palette mode listing `git ls-files` plus untracked, non-ignored files of the focused pane's repo, recent files first. Enter opens the file with `tab.editor.open`. Keep "Open File…" (Browse) as an entry.

**15. Project explorer**
- **Warp:**
  - **Roots:** a tree per tab with a root for every terminal or editor pane in the tab: the repo root, else the cwd. Nested roots merge (`W:pane_group/working_directories.rs:285-349, 633-691`).
  - **Following:** focusing an editor file reveals and selects it, and `cd` into a subfolder expands to it (`W:code/file_tree/view.rs:753-830, 1140-1170`). Focusing another pane in the same tab doesn't change the roots.
  - **Keys:** arrows and Enter (`:144-172`).
  - **Single click** opens a file in a code pane to the right (`:2017-2024`).
  - **Menu:**
    - Open in new pane / Open in new tab
    - New file (inline name)
    - cd to directory (puts `cd <path>` into the input)
    - Open in new tab (folder)
    - Reveal in Finder
    - Rename (inline)
    - Delete — immediate, no confirmation, no Trash
    - Copy path / Copy relative path
    - There is no New folder (`:2327-2449, 2568-2614`).
  - **Drag:** dropping onto a terminal inserts the path, relative into the input or absolute into a running program (`:3146-3181`).
  - **Hidden files:** shown by default and toggled with ⇧⌘> (`W:settings/code.rs:67-77`; `W:workspace/mod.rs:817-824`). Gitignored files show in italics.
  - **Keys to open it:** ⌃1 for the explorer, ⌘\ for the left panel (`W:util/bindings.rs:393-413`).
  - **Width:** resizable from 250 px to 75 %.
- **Tern now:** `TernFileTree.swift` has one root (`projectRoot`, `:92-101`) from the focused pane, re-polled every 1.5 s (`:79-87`). It hides `.git`, `.DS_Store`, `.hg` and `.svn` and shows other dotfiles, with no toggle (`:17, 32-35`). It has click and the menu at `:231-256`, and nothing else.
- **Change:**
  - Arrow-key navigation, with Enter to open or expand.
  - New file and rename, both inline.
  - Delete that moves to the Trash and can be undone (deliberately safer than Warp).
  - "cd to Folder", which sends the `cd` text to the focused pane without Enter.
  - Copy relative path.
  - Drag a row onto a pane to insert the quoted path (`TernInput.send`).
  - ⇧⌘> toggles hidden files, and gitignored files are dimmed (from `git check-ignore`).
  - ⌃1 as an alias of ⇧⌘E.
  - Reveal the active editor document.
  - Optional: a root per pane folder in the tab.

**16. Pane chrome**
- **Warp:**
  - A terminal pane renders a header only when split, shared or in agent full view (`W:terminal/view/pane_impl.rs:727-739`). It is 34 px tall (`W:pane_group/pane/view/header/mod.rs:47`).
  - The header holds the title, a ⋯ menu (Maximize/Minimize) and ✕ when split. The active terminal gets a 16 px accent triangle top-left.
  - The header is the drag handle.
  - Inactive panes aren't dimmed unless `should_dim_inactive_panes` is on; it is off by default (`W:settings/pane.rs:5-13`).
- **Tern now:**
  - There is no header, and pane names aren't shown anywhere in the UI. They're only CLI selectors (`T:Features/Tern/TernTopology.swift:146, 279`).
  - Focus is shown by dimming others: `unfocused-split-opacity = 0.8` (`TD:` line 102).
  - Dragging uses Ghostty's hover grab handle (`T:Ghostty/Surface View/SurfaceGrabHandle.swift`).
- **Change** (check with the user against S-1's "no visible containers"):
  - In splits, an overlay strip about 22–28 pt tall with the pane name or title, ⋯ (Zoom, Rename Pane, Move to New Tab/Window, Close) and ✕, acting as the drag source. Mark the active pane with an accent, and set `unfocused-split-opacity = 1`.
  - At minimum, add "Zoom Split" and "Close Pane" to the terminal's right-click menu when split.

**17. Editor details**
- **Warp:** see the table row. In a code pane, ⌘W closes the active editor tab (`W:pane_group/mod.rs:5274-5291`). Tern already does this (`TernEditor.swift:830-832`).
- **Change:**
  - In `TernEditorContainerView.performKeyEquivalent`, map ⌘F/⌘G/⇧⌘G to `performTextFinderAction` for the source view, and to a find in the WKWebView for the preview.
  - Drag to reorder editor chips.
  - Hide the chip strip when only one file is open, showing the name in the header.

**18–26.** As in the §1 table. Two need more detail.

**§5.23 Launch configs**
- **Launch configs:**
  - YAML in `~/.warp/launch_configurations/`. The keys are `name`, `active_window_index`, `windows[].tabs[]` with `title`, `color` and `layout`, where `layout` is a `split_direction` tree of panes with `cwd`, `commands` and `is_focused`.
  - There are no size fields: splits open equal.
  - Opened from the ⌃⌘L palette, File ▸ Launch Configurations ▸, or `warp://launch/<name>`. Always new windows; ⌘↩ in the palette adds the tabs to the current window.
  - "Save New…" captures every window's tabs, titles, colors, splits, cwd and focus, but not commands or sizes (`W:launch_configs/launch_config.rs:15-367`; `W:root_view.rs:580-623`; `W:uri/mod.rs:746-811`).
- **Tab configs:** single-tab TOML templates with `{{param}}`, branch/repo pickers and worktree templates. Opened from the ⌃⌘T menu or "+", or used as ⌘T's default (`W:tab_configs/tab_config.rs:31-203`). Warp's docs call launch configs legacy (https://docs.warp.dev/terminal/windows/tab-configs).
- **For Tern:** reuse `TernPersistence`'s layout serializer, writing JSON, or YAML if a parser is acceptable. Add an "Open Layout" palette mode, and a CLI `tern layout save|open NAME` if wanted, since the CLI already has every primitive.

**§5.24 Tabs and explorer side by side.** Warp's default left-side order is the tabs panel, then the tools panel; with vertical tabs on they render side by side (`W:workspace/header_toolbar_item.rs:100-102`; `W:workspace/view.rs:22962-22977`). Tern's sidebar has two exclusive modes, by design (S-2).

---------------------------------------------------------------------------------------------------

## 6. Non-UI gaps (skipped for now)

| # | Warp behavior | Why it isn't UI-only |
|---|---|---|
| N1 | **The editor is a pane in the split tree.** A file opens as a "code pane" next to terminals, and later files become editor tabs in that pane. It can be split beside, maximized (⇧⌘↩) and dragged by its header like any pane; editor tabs can be dragged out into another pane or tab, and ⌘[ ] cycle through it (`W:pane_group/pane/mod.rs:133-153`; `W:workspace/view.rs:9035-9185`; `W:code/view.rs:2391-2426`). | Tern's leaf type is a terminal everywhere (DECISIONS §1, candidate C: about 150 call sites). A generic leaf changes `layout.json`'s schema (persistence), the `ls` pane objects, selectors and events that CLI.md fixes (protocol), and the agent-pane attachment model. COMPROMISES records the per-tab panel as a trade-off. A UI-only stopgap is possible: let ⇧⌘↩ widen the editor panel to the whole tab while it has focus, and include the panel in ⌘[ / ⌘] cycling. |
| N2 | **Scrollback comes back after a restart.** Warp keeps the last 100 finished blocks per pane, each cut to 5000 lines, and shows a "restored" separator. Running commands aren't re-run (`W:persistence/block_list.rs:19, 248-284`; `W:terminal/model/block.rs:111`). | It needs reading a pane's buffer out of libghostty, storing it, and replaying it into a new surface: terminal core plus persistence. COMPROMISES phase 1: "Restoration brings back the layout, not the programs… Not scrollback." |
| N3 | **Tab groups.** Named, colored, collapsible and pinnable groups with contiguous members; ⇧/⌘-click multi-select; "New group with tab", "Move to group ▸", "Remove from group"; groups move as a block and are persisted per window. Groups are on in release (`W:workspace/tab_group.rs:24-49`; `W:workspace/view/tab_grouping.rs:24-101, 525-649`). | A new persisted entity whose ordering rules interact with pins, undo snapshots and restoration (`layout.json`), plus new `ls` fields, CLI commands and events (protocol). Note that REQUESTS.md asks about moving a session "to another window/tab/tab group". That may mean Warp's groups, or AppKit's window tab groups, which the reference UI used. Worth asking the user. |
| N4 | **Live status of agents typed into a terminal.** Warp shows in-progress, done and needs-input states for Claude Code and Codex running in a terminal, through its CLI-agent plugin, on rows, in notifications and in the mailbox (`W:terminal/view.rs:14133-14165`; `W:workspace/view/vertical_tabs.rs:4274-4321`). | Tern sees only running/exited for `tern claude`/`tern codex` (IA-2). More would need hooks or plugins inside the harness, which IA-4 forbids ("never changes how the user's own claude/codex behave"), or new harness-protocol work. The skipped area is the agent harness. |

---------------------------------------------------------------------------------------------------

## 7. Discarded by the user or the spec

| Warp behavior | Quote |
|---|---|
| Vertical tabs with **pane** granularity, one row per pane (Warp's default) | REQUESTS: "sidebar should use the warp 'group by tab' instead of gropu by pane" |
| Warp's default row content (command first, branch as subtitle), and the View-options popover (density, Summary mode, "pane title as", additional metadata) | REQUESTS: "making it two lines (terminal command on the focus pane on the bottom line, folder name and branch/worktree on the top one)"; "keep sidebar simple, like warp". SPEC S-3 fixes the two lines. |
| The horizontal tab bar, alone or alongside the vertical panel | REQUESTS: "remove the open tabs section at the top so only the sidebar remains to show tabs"; SPEC S-1: "no native tab bar" |
| Header-toolbar or title-bar icons on the right: notifications mailbox, code review, agent management, tools buttons | REQUESTS: "remove the icons on the upper right corner"; SPEC S-1: "no titlebar icons on the upper right" |
| In-app agent creation: "+" menu entries for Agent / Cloud Agent / Docker sandbox, and the agent tab | REQUESTS: "remove the new agent sidebar button and that functionality"; SPEC AP-9: "There is no in-app 'new agent' form." |
| An agents/conversations section in the left panel (⌃2) | REQUESTS: "remove … the 'no agents running' section (keep sidebar simple, like warp)"; SPEC S-2: "no 'agents' section" |
| Background workers having a tab | REQUESTS ("Answers after phase 2"): "default workers to backgroud". The sidebar therefore never lists them; COMPROMISES lists where they are found instead. |

---------------------------------------------------------------------------------------------------

## 8. Not applicable

- **Warp Drive:** the ⌘\ default panel, ⌃4, notebooks, workflows, env-var collections and "Search Warp Drive".
- **Accounts:** log out, teams, referral, billing.
- **Warp AI:** agent panes (⌃Space), agent tabs, cloud agents, the conversation list (⌃2), the agent management view (⇧⌘M), the mailbox (⇧⌘U), jump to the latest agent task (⇧⌘G), in-app agent toasts, "use latest prompt as title", Oz/warpctrl installs. Tern's managed sessions use Window ▸ Agent Sessions, ⌃⌘J, notifications and the Dock badge instead (COMPROMISES, after phase 2).
- **Session sharing:** "Share session", "Copy link". Dogfood-only in Warp.
- **The code-review right panel** (⇧⌘+) and clicking a diff chip to open it.
- **Blocks:** ⌘B bookmark-block, block selection, ⌘K clear blocks, Warp's input editor (⌘L), command search (⌃R), workflows (⌃⇧R). Tern is a Ghostty terminal without blocks.
- **Warpify subshell and the shell selector** in the "+" menu.
- **Warp's settings UI and keybinding editor** (⌘,, ⌘/, ⌃⌘K). Tern uses Ghostty config files; its palette lists its shortcuts.
- **Open Repository** (⇧⌘O) and Open Recent. Tern opens folders with `tern window new --cwd` or `tab new --cwd`.
- **LSP and format-on-save** in Warp's code editor. Tern's editor is the Markdown/text editor the user asked for.
- **Warp's minimum pane size of 190 px.** This is a consequence of Warp's Universal Input bar, which Tern has no equivalent of.

---------------------------------------------------------------------------------------------------

## 9. Where Tern's spec deliberately differs from Warp, and the user may not have meant it

1. **L-9 takes Warp's pane-resize keys.**
   - ⌃⌘←/→ move a pane to the previous or next tab (Warp: move a divider), and ⌃⌘T moves a pane to a new tab (Warp: tab configs menu).
   - These keys came from the reference UI (`.ref/WraithShortcuts.swift:61-73`), not from the user's words. The user asked for Warp-like panes "accessible as shortcuts".
2. **E-1 makes the editor a per-tab panel, not a pane** (non-UI gap N1).
   - The user asked for an editor "similar to warp". Later, about agent panels, they asked that panels "behave as any other panel. e.g., should be able to open panels next to them".
   - The panel layout came from the reference UI and was recorded as a compromise.
3. **S-2 makes Tabs and Files exclusive modes of one sidebar** (gap 24).
   - Warp shows the project explorer next to the vertical tabs, roots it at every pane's repo, and reveals the file being edited.
   - The user asked only for "a warp analogue filetree/project explorer".
4. **Undo-close lasts 5 s and ⇧⌘T is generic undo** (gap 3). COMPROMISES kept Ghostty's `undo-timeout`, but Warp keeps closed items for 60 s on a dedicated stack, and the user never chose 5 s.
5. **L-9's ⌘O is an Open dialog, not Warp's files palette** (gap 14). The palette key is also ⇧⌘P (Ghostty's) instead of Warp's ⌘P, with ⇧⌘P being Warp's navigation palette (gap 7).
6. **Restoration without scrollback** (non-UI gap N2). This is a documented compromise rather than a user decision. Warp restores the last 100 blocks per pane.
7. **Product defaults that aren't in the spec:**
   - Tern dims inactive panes (`unfocused-split-opacity = 0.8`); Warp doesn't by default.
   - Tern's sidebar is a fixed 252 pt, and its visibility is shared by all windows.

   These are Tern's choices, not the user's (gaps 13 and 16).

# UI-A: shortcuts from anywhere, tab history and order, jumps, palettes, Settings, focus after close

Helper UI-A's notes for the lead. Code: worktree `~/dev/terminal-3/.worktrees/app-ui-a`, branch
`ui-a`. Tests: `acceptance/tests/test_tern_nav.py`. Target: `acceptance/targets/tern-ui-a.json`.

---------------------------------------------------------------------------------------------------

## 1. SPEC text

All Fixed tier. L-9 replaces the current L-9; the rest are new. (UI-B's L-9 line for ⇧⌘T fits in
the list below.)

### L. Windows, tabs and panes

- **L-9 [A+W]** Keyboard shortcuts:
  - ⌘B toggles the sidebar; ⇧⌘E shows the project explorer;
  - ⌘O opens a file (quick search, L-16; File ▸ Open File… keeps the Open panel);
  - ⇧⌘M toggles the Markdown preview and source;
  - ⌘P opens the command palette (L-14); ⇧⌘P lists panes (L-15); ⌘, opens Settings (L-17);
  - ⇧⌘[ goes back to the tab visited before; ⇧⌘] shows the next tab in sidebar order; ⌃Tab and
    ⌃⇧Tab cycle to the next and previous tab; ⌘1–⌘8 show that tab and ⌘9 the last one (L-11);
  - ⌃⇧← / ⌃⇧→ move the tab up or down (L-13);
  - ⌃⌘T / ⌃⌘N move the pane to a new tab or window;
  - ⌃⌘← / ⌃⌘→ move the pane into the previous or next tab;
  - ⌃⇧⌘N moves the tab to a new window;
  - ⌃⌘P pins or unpins the tab;
  - ⌃⌘R / ⌃⇧⌘R rename the tab or pane;
  - ⌃⌘J goes to the next session that needs the user, and ⌃⌘K goes back (L-12).

  Each is a menu item, and the command palette lists them. Settings changes them (L-17).

- **L-10 [A+W]** Shortcuts work from anywhere: with keyboard focus in a terminal, the editor (source
  or preview), the sidebar (its rename field and the file tree), a session's read-only view in a
  pane, the palette or the Settings window. A terminal never takes one of these keys first.

- **L-11 [A+W]** Moving between tabs:
  - ⇧⌘[ (`<cli> tab back`) goes to the tab the user was in before, in any window. Pressed again,
    it goes to the tab before that, and so on, like a browser's Back over the tabs visited. Tabs
    closed since are skipped. Visiting a tab any other way ends the walk.
  - ⇧⌘] (`<cli> tab next`) goes to the next tab in sidebar order, ⌃Tab too, and ⌃⇧Tab (`<cli> tab
    prev`) to the previous one; both wrap around. Pressed several times in a row they walk down
    (or up) the list as it was when the walk started (S-7 doesn't reorder it meanwhile).
  - ⌘1–⌘8 show the Nth tab of the window and ⌘9 its last tab.

- **L-12 [A+W]** ⌃⌘J (`<cli> jump`) goes to the next session that needs the user: sessions that
  need input first, then sessions that finished while the user wasn't looking, oldest first. A
  session shown in a pane gets that pane focused (its tab selected, its window in front); a
  session no pane shows is shown. Pressed again, it goes to the next one. ⌃⌘K (`<cli> jump back`)
  goes back to the pane the user was in before the first of those jumps. When nothing needs the
  user, `jump` fails with a message saying so.

- **L-13 [A+W]** ⌃⇧← and ⌃⇧→ (`<cli> tab move [TAB] --up|--down`, and the sidebar row's menu) move
  a tab up or down the sidebar, within its group: a tab never crosses into or out of the pinned
  tabs. At the end of its group nothing moves (the CLI fails with a message).

- **L-14 [A+W]** ⌘P opens a command palette offering the CLI's commands. The palette takes them
  from the CLI's own description of itself (`<cli> help --json`), so it follows the CLI as it
  changes. Choosing one runs it for the focused pane (as `<cli>` typed in that pane would), asking
  first for the values it needs (a name, a color among the allowed ones, a tab or pane among those
  open, …). Output, and errors, show in the palette. A `<cli>` command line typed into the palette
  runs as typed. The palette also lists the menu actions (with their shortcuts), the managed
  sessions, and Ghostty's actions on the focused terminal; each title appears once.

- **L-15 [A+W]** ⇧⌘P lists every pane of every window, the most recently used first, each with its
  own title: its name, else its agent session's title, else what its program set as its title,
  else its folder; then its folder and branch, what it runs (or last ran) and its tab. The pane the
  palette was opened from is marked Current. Choosing a pane focuses it, its tab and its window.

- **L-16 [A+W]** ⌘O opens a quick file search over the focused pane's git repository: its tracked
  files and the untracked files git doesn't ignore (outside a repository: the files of that
  folder). Fuzzy matching on the path, the file name counting most; files opened recently first,
  then changed ones. `path:line` opens the file at that line. Enter opens the file in the tab's
  editor; a "Browse…" entry opens the Open panel.

- **L-17 [A+W]** ⌘, opens Settings, where shortcuts are edited: every Tern menu shortcut and every
  Ghostty keybinding is listed, searchable, and each can be changed (press the new keys), cleared
  or reset to its default, or all reset at once. A change applies at once, without a restart, and
  is kept across restarts in Tern's state directory (`shortcuts.json`, and `keybindings.conf` for
  Ghostty keybindings, loaded after the user's Ghostty config files). The user's Ghostty config
  files are never changed; Settings says so and has a button that opens them. A key given to one
  shortcut is taken from any other that had it, and Settings says which. `<cli> shortcuts` lists,
  sets, clears and resets the same shortcuts.

- **L-18 [A]** After a pane closes (⌘W, `pane close`, its program exiting), focus goes to the pane
  of that tab the user used most recently, as in Warp; tree order only when there's no history.

### S. Sidebar and look

- **S-7 [A+W]** The sidebar's order, in the user's words: "current tab is at the top and then
  ordered by which one had an agent last stop/deliver":
  - pinned tabs first, in pin order (pins are explicit and stay where the user put them);
  - then the current (selected) tab;
  - then tabs whose agents stopped or delivered, the most recent first;
  - then the other tabs, keeping their order.

  This is the window's real tab order: `ls`, `#N` selectors and ⌘1–9 follow it. It is worked out
  again when the window's selected tab changes, when an agent stops or delivers, and when a tab is
  pinned or unpinned. A tab placed by hand (dragged, `tab move --index`, Move Tab Up/Down, `tab new
  --index`) stays where it was put until then, even though placing it selects it. After ⇧⌘], ⇧⌘[,
  ⌃Tab or ⌘1–9 the order stays as the user saw it until a moment (about a second) after the last
  press, so repeated presses walk the list instead of bouncing between the top two tabs.

### CHECKS.md (proposed written checks for the [W] parts)

- **L-9/L-10 (by hand).** Window with three tabs, one split, a Markdown file open. With focus in a
  terminal, the editor source, the preview, the sidebar's rename field (double-click a row), the
  file tree (click a file), the palette (⌘P) and Settings (⌘,): press ⇧⌘], ⇧⌘[, ⌃Tab, ⌘2,
  ⌃⇧→. Each changes or moves the tab; none types into the focused field or terminal.
- **L-14–L-16.** Screenshot of ⌘P with "tab" typed (CLI entries with their `tern …` line, menu
  actions with shortcuts), of a command asking for a value (Set Tab Color…), of ⇧⌘P (pane titles,
  Current marker) and of ⌘O in a repository (recent and changed files first).
- **L-17.** Screenshot of Settings: both sections, a changed shortcut with Reset, the note saying
  the Ghostty config file isn't changed.
- **S-7.** Four tabs, two of them with agents that stopped at different times: the current tab is
  at the top, then the most recent stop. Press ⇧⌘] three times quickly: the selection walks down
  the list, which reorders about a second after the last press.

---------------------------------------------------------------------------------------------------

## 2. CLI.md text

Layout table, new and changed rows:

| Command | Notes |
|---|---|
| `tab back` | the tab visited before (again: the one before that), in any window; JSON `{"tab", "window", "index", "title"}`; fails when there is none |
| `tab next\|prev [--window W]` | the next or previous tab in sidebar order (wraps); JSON as `tab back` |
| `tab move [TAB] (--window W [--index I] \| --index I \| --up \| --down \| --new-window) [--no-focus]` | `--up`/`--down`: one place, within the tab's pin group; fails at the end of the group |
| `jump [back]` | the next session that needs the user (prints the pane, or the session id when no pane shows it), or back to where the user was; JSON `{"pane", "tab", "window", …}` or `{"session"}`; fails when nothing needs the user |

General, new rows:

| Command | Notes |
|---|---|
| `help [--json]` | `--json`: every command for programs: `{"cli", "product", "version": 1, "commands": [{"section", "usage", "summary", "actions": [{"title", "argv", "ask": [{"name", "prompt", "option"?, "choices"?, "optional", "kind", "words"?}]}]}]}` |
| `shortcuts [ls]` | JSON `{"shortcuts": [{"id", "title", "kind": "tern"\|"ghostty", "keys": [str], "display": [str], "default": [str], "changed": bool, "menu"?, "source"?}], "files": [str]}`. Tern items' keys are written like `shift+cmd+]`; Ghostty's in Ghostty's trigger syntax |
| `shortcuts set ID KEYS`, `shortcuts clear ID`, `shortcuts reset [ID]` | ID from `shortcuts`: a Tern item (`tab.next`) or `ghostty:ACTION` (`ghostty:new_tab`). KEYS like `cmd+shift+]`, `ctrl+cmd+left` or `super+t`. JSON of `set` has `notes`: the shortcuts the key was taken from |

Events: `tab.reordered` `{"window", "tabs": [ids]}` when S-7 reorders a window; `palette.opened`
`{"mode", "window"}`; `palette.ran` `{"argv", "status"}`.

---------------------------------------------------------------------------------------------------

## 3. Decisions

**Shortcuts from anywhere (L-10): a key monitor in front of the menu items.** Menu key equivalents
alone (WARP-PARITY §2.2's suggestion) don't reach every case: a view's `performKeyEquivalent`
(Ghostty's terminal for its own bindings, WKWebView in the preview) runs before the menu, and AppKit
doesn't match ⇧⌘[ to a "[" + ⇧ menu item reliably (the event's character is "{"). So the items
stay menu items (shown, discoverable, in the palette), and `TernShortcuts.dispatch` performs them
from an app-local key-down monitor before any view sees the key. Tern's defaults also unbind
Ghostty's bindings for these keys (⇧⌘[ ⇧⌘] ⌘1–9 both digit forms, ⌃Tab ⌃⇧Tab ⇧⌘P ⌘,), so the
shortcuts editor shows them free; a binding the user puts in their own Ghostty config for one of
Tern's keys loses to Tern's item (Settings shows both, and changing either moves the key). Keys
without ⌘ or ⌃ (typing) never go to the monitor. Modal alerts and sheets keep their keys. The
monitor refreshes the menu's validation before performing (AppKit's enabled state can be stale).

**⇧⌘[ history.** A list of the tabs visited across windows, most recent last, each once. Back walks
down it with a cursor without reordering (so pressing again goes further back, never ping-pongs);
visiting a tab any other way ends the walk and counts the tab reached by walking as visited (so
Back from the new tab returns to it, as a browser would). A visit is a selection change in the
current window, or a window becoming current. Windows created with focus count at once, even
while the app is in the background.

**⇧⌘] / ⌃Tab** stay within the window (as in Warp); they wrap. **⌘1–8 / ⌘9** in a "Show Tab"
submenu of Window, to keep the menu short.

**S-7: how the user's order meets pins and manual moves.** I took the lead's suggestion: pins
first (explicit), then current, then last agent stop (most recent first), then never-stopped tabs
in their existing order; the real tab order changes, so `ls`, `#N` and ⌘1–9 follow what the user
sees. Details that weren't in the suggestion:
- *Ping-pong:* every tab-switching key or `tab next/prev/back` freezes the order for 1.2 s after
  the last press (one timer for the app); the reorder then runs for every window, animated.
  Sidebar clicks and `tab focus` reorder at once (the row moves to the top, animated), which is the
  literal ask; I considered waiting until the pointer leaves the sidebar but it needs UI-B's views
  and hides why rows didn't move.
- *Manual placement:* a placement (`tab move`, drag, Move Tab Up/Down, `tab new --index`) runs
  under `TernTabOrder.hold`, so the selection it makes doesn't reorder; the next selection change
  or agent stop does. Among tabs whose agents never stopped, a manual order survives reorders
  (their relative order is kept); among stopped tabs, last stop wins. M-2's test (move to
  `--index 2` and check index 2) passes because of the hold.
- *Pin/unpin* reorders at once (the unpinned tab goes to its place by the rules).
- *A tab with an old stop stays above a tab with no agent* that the user visited recently: the
  user's rule ranks by agent stop; tabs without agents keep a most-recently-current order among
  themselves because the previous current tab is first among them.
- Not configurable. If the user wants manual order back, a `sidebar order manual` switch would be
  the cheap door to add (one flag in `TernTabOrder`).

**⌃⌘K for "back".** ⌃⇧⌘J was the natural pair but Ghostty binds it (`write_screen_file:copy`);
⌃⌘K is free in Ghostty and macOS, and J/K read as next/back. "Back" returns to the pane focused
when a *run* of jumps started (a run continues while each ⌃⌘J starts from the previous jump's
destination), not one step back: the user's words were "goes back (to where you were before
jumping)". A `.session` target calls `TernAttention.shared.showSession` (the lead's); a later ⌃⌘J
from the pane that shows that session continues the run.

**Command palette from the CLI (L-14).** One table in `macos/TernCLI/commands.swift`: each help line
(section, usage, summary) and the palette actions it offers (title, words, values to ask). `tern
help` prints the table; `tern help --json` prints the same table; the palette reads the JSON
from the bundled CLI once per run and runs actions through the bundled CLI with the focused pane's
`TERN_PANE_ID`/`TERN_INSTANCE`/`TERN_STATE_DIR` and folder, so every command defaults to "this
pane" exactly as in a terminal. Commands that stream or block (`events`, `wait`) offer no action.
A typed `tern …` line (first word a known command) runs as typed, so commands without curated
actions are still reachable. Same-title entries are merged: a CLI action that asks for values
replaces the menu item (asked inline rather than in a dialog) and shows its shortcut; otherwise
the menu item wins, then Ghostty's action (which asks before closing a running program, unlike
`tab close`), then the CLI's. Ghostty's own "Command Palette" menu item and `toggle_command_palette`
open Tern's palette; Ghostty's palette remains only for non-Tern windows (Quick Terminal). The
build script now compiles every `.swift` file in `TernCLI/`.

**Pane palette (L-15).** A global most-recently-focused list of panes (`TernFocusHistory`), fed by
focus changes and by `pane focus`/`tab focus`; panes never focused follow in layout order.

**Quick open (L-16).** `git ls-files --cached --others --exclude-standard` from the repository
root of the focused pane's folder (outside a repository, that folder only, as Warp), indexed off the
main thread when the palette opens; up to 100 results; recency from files opened through the
editor (any path) or the palette; changed files from `git status`. `path:line` switches a Markdown
file to source and puts the cursor on the line (`TernDocument.revealLine`, a small editor hook).

**Settings (L-17).** A Settings window (⌘,; Ghostty's "Preferences…" item, which opens the
Ghostty config, is renamed "Open Ghostty Config File" and loses ⌘,). Storage: Tern items in
`<state>/shortcuts.json`; Ghostty keybindings as `keybind = …` lines in `<state>/keybindings.conf`,
which `Ghostty.Config.loadConfig` loads after the user's config files (so a change made in Tern wins
over the user's file, which the UI states), applied by reloading the config. The list of Ghostty
bindings in effect is worked out by replaying, in Tern's load order, Ghostty's built-in defaults
(from the app's own `+list-keybinds --default`), Tern's defaults, the user's config files (and
their `config-file` includes) and `keybindings.conf`, because libghostty has no API to list
keybindings and no Zig changes were allowed. Menu shortcuts need ⌘ or ⌃ (or a function key);
terminal bindings can be any key.

**L-18.** `BaseTerminalController.findNextFocusTargetAfterClosing` asks an overridable
`previouslyFocusedSurface(excluding:)` first; `TerminalController` answers from the focus history.
`TernTab.effectiveFocusedSurface` and the undo/hidden-tab close paths use the same history.

**Focus moves are guarded.** `TernLayout.moveFocus(to:in:)` replaces `Ghostty.moveFocus` in Tern's
focus paths: it retries until the pane's view is in the window, but only while the window still
wants that pane. With Ghostty's version, quick `pane focus A; pane focus B` across tabs could end
with A focused (A's retry landed after B) — found by the L-15 test.

**Looking clears marks.** `TernFocusHistory` calls `TernAttention.shared.looked(atPane:)` when a pane
gets focus in the key window of the active app (UI-B's sidebar may call it too; it's idempotent).

---------------------------------------------------------------------------------------------------

## 4. Test changes

- `tests/test_layout.py`, `SHORTCUTS` (used by `test_shortcuts_are_menu_items`, a UI test): added
  the ⌘ shortcuts of the rewritten L-9 (⇧⌘[, ⇧⌘], ⌘1, ⌘8, ⌘9, ⌘P, ⇧⌘P, ⌘,, ⌃⌘J, ⌃⌘K). Nothing
  removed. Requirement: L-9 as rewritten above ("Each is a menu item"). ⌃Tab and ⌃⇧← can't be
  looked up by `ui.shortcut` (it needs ⌘); `test_navigation_shortcuts_are_menu_items` checks them
  through `debug.menu`.
- `app/macos/TernTests/verify_ui_paths.py`: the same keys added to its L-9 list.
- **M-2 and L-2 tests unchanged and passing** with S-7: `test_move_tabs_between_windows_keeps_programs`
  places tabs with `--index` and checks the index right away (the hold keeps them there);
  `test_pinned_tabs_come_first_and_stay_grouped` only checks the pinned group, which S-7 never
  reorders.

---------------------------------------------------------------------------------------------------

## 5. Tests added (`acceptance/tests/test_tern_nav.py`)

Through the CLI and `debug.*` methods (run with `-m "not ui"`):
- `test_navigation_shortcuts_are_menu_items` (L-9): each new item, its key, no other item on it.
- `test_ghostty_no_longer_binds_the_tab_keys` (L-10): Ghostty's bindings for the keys are gone.
- `test_tab_keys_work_whatever_has_focus[terminal|editor|palette|settings]` (L-10): with focus put
  there, ⇧⌘] and ⌃Tab (through `debug.key`, which hands a key event to the same dispatcher the key
  monitor uses) change tabs.
- `test_tab_back_follows_the_tabs_visited_across_windows`, `test_tab_back_skips_closed_tabs_and_fails_clearly_at_the_start` (L-11).
- `test_next_tab_walks_the_sidebar_order_as_seen` (L-11, S-7): a burst walks the list as seen; it
  settles with the current tab on top; prev wraps.
- `test_tab_number_items_and_cycling` (L-11): Tab 2, Last Tab, Tab 1, cycling both ways.
- `test_jump_goes_to_sessions_needing_you_then_back`, `test_jump_to_a_session_no_pane_shows`
  (L-12), with `debug.attention.set/background` standing in for the agent engine.
- `test_move_tab_up_and_down_stays_in_its_pin_group` (L-13, L-2).
- `test_help_json_describes_the_cli`, `test_command_palette_offers_cli_commands_menu_actions_and_ghostty_actions`,
  `test_palette_runs_a_cli_command_for_the_focused_pane_and_asks_its_arguments` (L-14).
- `test_pane_palette_lists_panes_most_recent_first_with_their_own_titles` (L-15).
- `test_quick_open_searches_the_focused_panes_repository` (L-16): tracked + untracked, not ignored;
  ranking; `path:line`; Browse…; recent first.
- `test_settings_opens_from_the_menu`, `test_shortcuts_can_be_changed_cleared_and_reset_without_a_restart` (L-17).
- `test_closing_a_pane_focuses_the_pane_used_before` (L-18).
- `test_current_tab_first_then_by_last_agent_stop`, `test_pinned_tabs_stay_first_and_placements_hold_until_the_next_reorder` (S-7).

**AX UI tests the lead must run** (marked `ui`; they press real keys):
`test_tab_keys_from_the_editor_the_file_tree_and_the_palette` (L-10, L-11),
`test_cmd_p_runs_a_cli_command_typed_into_the_palette` (L-14),
`test_shift_cmd_p_goes_to_a_pane_by_its_title` (L-15), `test_cmd_o_opens_a_file_from_the_repository`
(L-16), `test_cmd_comma_opens_settings_where_a_shortcut_is_recorded` (L-17),
`test_jump_and_move_tab_keys` (L-12, L-13). Plus the existing `test_shortcuts_are_menu_items`.

---------------------------------------------------------------------------------------------------

## 6. Left open / risks

- **Why `debug.key` isn't the whole proof of L-10.** AppKit runs local key monitors only for events
  that come from the window server; an event the app posts to itself or sends with `sendEvent`
  skips them (checked). So `debug.key` calls the monitor's dispatcher directly after putting
  focus somewhere. The AX tests above press real keys; they are the honest check for the sidebar
  rename field, the file tree and a session's read-only view (the agent pane is the lead's; its
  composer had no special key handling I could find, and the monitor runs before it anyway).
- **Merge conflicts I expect:**
  - `TernShortcuts.swift`: rewritten (item ids, the monitor, editable shortcuts). UI-B's "Reopen
    Closed" block needs an `id:` (e.g. `file.reopen`) to compile in the new `Item`.
  - `TernCLI/main.swift`: the `help` string is gone, printed from `commands.swift`. Agent help lines
    changed by the lead belong in the table's "Managed agents" rows (and their palette actions); UI-B's
    `reopen` command needs a row too.
  - `TerminalView.swift` (palette overlay hunk), `TernRPC.swift` (one `tab.move` hunk, one
    `default:` hunk), `TerminalController.swift` (selectTab, setPinned, focus, palette), `TernLayout.swift`.
  - UI-B's row menu calls `TerminalController.moveTab` for Move Tab Up/Down: better
    `TernNavigation.moveTab(tab, by: ±1, in: controller)` (undo step, `tab.moved` event, pin-group
    check, S-7 hold) and `TernNavigation.canMoveTab` to disable at the ends.
- **TernAttention:** no API change. `showSession` must be set by the engine for ⌃⌘J to show a
  session no pane shows; until then such a jump does nothing visible. The old "Jump to Agent
  Needing Input" path (`TernAgentUI.jumpToAgentNeedingInput`) is no longer bound; ⌃⌘J reads only
  TernAttention, so it finds nothing until the new engine writes marks.
- `TernShortcuts.paletteOptions()` still lists sessions through `TernAgentMenu` (the old engine).
- Settings lists Ghostty bindings by replaying config files; an exotic config (keybind tables,
  `keybind = clear` in an included file loaded in a different order) can show a slightly different
  list than libghostty uses. Keys are matched as typed (US layout names in the CLI).
- The two `NSEvent` Sendable warnings (key monitors) are Swift 6 warnings only.
- The worktree has an untracked `zig-out` symlink to the main checkout's `zig-out` (the Xcode build
  copies its shell-integration resources from there); not committed.

## Results (last runs, build `b4425946c`)

- `test_tern_nav.py -m "not ui"`: 23 passed. The 6 AX tests collect (`-m ui`), not run.
- Regressions, `--phase 1 -m "not ui and not real"`: `test_layout.py`, `test_tern_extra.py`,
  `test_editor.py`, `test_interactive.py`, `test_tern_nav.py`: 82 passed; `test_robustness.py`,
  `test_install.py`, `test_chaos.py`: 11 passed. (An earlier run died when the lead's `pkill` took
  the instance down; rerun clean.)

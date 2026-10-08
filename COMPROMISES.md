# Compromises (phase 1)

What phase 1 gives up, why, and which requirement that protects. No fixed- or core-tier phase-1
test fails; nothing here turns a failing test into an accepted failure. These are the trade-offs
behind passing tests, and the things Ghostty did that Tern no longer does.

| What is given up | Why | What it protects |
|---|---|---|
| **AppKit window tabs.** Tern's tabs are its own model inside one window. Ghostty features built on native tab groups lose their meaning: the native tab bar and tab overview (`toggle_tab_overview`), "Merge All Windows", and AppleScript/Shortcuts objects that model tabs as windows (they see each Tern window as one tab). `goto_tab`, `move_tab`, `close_tab` and friends work on Tern's tabs. | Native tab groups select and activate windows as a side effect, so "don't focus" could only be undone after the fact; they reorder by removing and re-adding windows; and the system "prefer tabs" setting merges windows. | L-8 (no focus change at any moment), L-2 (pins grouped), M-2 and M-6 (tab moves, separate windows), M-4 (sidebar drag). |
| **Titlebar styles.** `macos-titlebar-style = native/tabs/hidden` don't change Tern's window: it always has the transparent titlebar with the full-height sidebar. | Tabs live in the sidebar; the native and tabs styles exist to show AppKit's tab bar. | S-1, S-2. |
| **The editor is a per-tab panel, not a split pane.** A file view can't be split, moved or zoomed on its own; it moves with its tab. | SPEC E-1 describes "an editor panel beside the tab's terminals" with editor tabs, and that is the layout the user liked in the reference UI. Making the split tree's leaf generic for phase 1 would have meant rewriting Ghostty's pane code for no requirement. | E-1; keeps every pane a terminal, which phase 2's agent views build on (DECISIONS.md §1). |
| **A quit requested by another process doesn't ask** about running programs (a quit Apple event from a script, an installer, the Dock, logout). ⌘Q inside Tern still asks. | An update installs "when the app quits"; a dialog would block it, and scripted quits (and the suite) can't answer one. Edits in the editor are saved or kept as recovery copies, and the layout is saved continuously. | I-4 (install on quit), E-3 (no silent loss of edits). |
| **Restoration brings back the layout, not the programs.** After a restart: windows, tabs (names, colors, pins, order), splits, each pane's folder and name, open editor documents. Not scrollback or running processes (Ghostty doesn't either). | Programs die with the app (the user chose that sessions may stop when the app quits). | R-3. |
| **Undo of a closed pane or tab** keeps Ghostty's `undo-timeout` (5 s by default); **undo of a move** lasts 10 minutes. | A closed pane's process stays alive only while its undo can bring it back; a move holds no process alive (its snapshot holds panes weakly), so it can last longer. | M-3 without hidden long-lived processes (R-1 in spirit). |
| **Background update checks** run only in release builds, and in an isolated instance only when `TERN_FEED_URL` is set. Development builds update only when asked (`tern update`). | A development build or a test instance must never replace itself with a published release. | I-4, P-1 (instances never affect each other). |
| **`wait --pattern` ignores the shell's prompt and the typed command line** (when the shell reports them through shell integration, which Ghostty injects for zsh, bash, fish and elvish). Text that only appears in a typed command never matches. | Otherwise `send "x && echo DONE"; wait --pattern DONE` can return before `x` ran, because the command line itself contains DONE. | T-3 ("a pane's output matches a pattern"). |
| **Undo steps for CLI changes** are closed by posting a harmless application-defined event after each request that registered undo. | AppKit closes undo groups only after a UI event; with the user away, every CLI change would otherwise pile into one undo step. | M-3. |

## Not done in this run (environment, not a trade-off)

The Mac's screen was locked for most of the run (from 17:26, while nobody was at the machine).
macOS then hides every window's accessibility tree, so the suite's six UI tests (`test_shortcuts_are_menu_items`,
`test_undo_redo_of_moves`, `test_toggle_shows_the_source`, `test_dirty_documents_are_not_closed_silently_and_save_works`,
`test_follows_changes_on_disk`, `test_non_utf8_files_keep_their_encoding`) were skipped. The same
behaviors were checked through Tern's internal `debug.*` control methods
(`app/macos/TernTests/verify_ui_paths.py`, 43/43 checks pass), but the UI tests themselves need an
unlocked screen. See REPORT.md, "Questions for the user".

# Compromises (phase 1)

What phase 1 gives up, why, and which requirement that protects. No fixed- or core-tier phase-1
test fails; nothing here turns a failing test into an accepted failure. These are the trade-offs
behind passing tests, and the things Ghostty did that Tern no longer does.

| What is given up | Why | What it protects |
|---|---|---|
| **AppKit window tabs.** Tern's tabs are its own model inside one window. Ghostty features built on native tab groups lose their meaning: the native tab bar and tab overview (`toggle_tab_overview`), "Merge All Windows", and AppleScript/Shortcuts objects that model tabs as windows (they see each Tern window as one tab). `goto_tab`, `move_tab`, `close_tab` and friends work on Tern's tabs. | Native tab groups select and activate windows as a side effect, so "don't focus" could only be undone after the fact; they reorder by removing and re-adding windows; and the system "prefer tabs" setting merges windows. | L-8 (no focus change at any moment), L-2 (pins grouped), M-2 and M-6 (tab moves, separate windows), M-4 (sidebar drag). |
| **Titlebar styles.** `macos-titlebar-style = native/tabs/hidden` don't change Tern's window: it always has the transparent titlebar with the full-height sidebar. | Tabs live in the sidebar; the native and tabs styles exist to show AppKit's tab bar. | S-1, S-2. |
| **The editor is a per-tab panel, not a split pane.** A file view can't be split, moved or zoomed on its own; it moves with its tab. | SPEC E-1 describes "an editor panel beside the tab's terminals" with editor tabs, and that is the layout the user liked in the reference UI. Making the split tree's leaf generic for phase 1 would have meant rewriting Ghostty's pane code for no requirement. | E-1; keeps every pane a terminal, which phase 2's agent views build on (DECISIONS.md §1). |
| **A quit requested by another process doesn't ask** about running programs (a quit Apple event from a script, an installer, the Dock, logout). ⌘Q inside Tern still asks. *After phase 2 the user confirmed this ("script quits should not ask"): it's their decision now, not a compromise.* | An update installs "when the app quits"; a dialog would block it, and scripted quits (and the suite) can't answer one. Edits in the editor are saved or kept as recovery copies, and the layout is saved continuously. | I-4 (install on quit), E-3 (no silent loss of edits). |
| **Restoration brings back the layout, not the programs.** After a restart: windows, tabs (names, colors, pins, order), splits, each pane's folder and name, open editor documents. Not scrollback or running processes (Ghostty doesn't either). | Programs die with the app (the user chose that sessions may stop when the app quits). | R-3. |
| **⌘Z undoes a close** for Ghostty's `undo-timeout` (5 s); **⇧⌘T / `tern reopen`** bring a closed pane, tab or window back for 60 s (L-20, after the user's decision), and its programs live that long; **undo of a move** lasts 10 minutes and holds no process. *(Updated in the agent-sessions run.)* | A closed pane's process stays alive only while undo or reopen can bring it back; a move holds no process alive (its snapshot holds panes weakly), so it can last longer. | M-3 and L-20 without hidden long-lived processes. |
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

===================================================================================================

# Compromises (phase 2: managed agents)

What phase 2 gives up, why, and which requirement that protects.

| What is given up | Why | What it protects |
|---|---|---|
| **Steering.** A follow-up sent while the agent works waits for the running turn to end; it is never injected into the turn (Claude's mid-turn injection, Codex's `turn/steer`). | A message handed to the harness early sits in a queue the product can't take back: a redirect couldn't go ahead of it, `--drop-queued` couldn't cancel it, Claude's interrupt (which names no turn) could hit its turn, and after a crash nobody could say whether the model saw it. One message at a time keeps every message in exactly one known place. SPEC lists steering as negotiable and says it must not weaken MA-4. | MA-4 (exactly once), MA-25 (redirect goes first, never interrupts its own turn), MA-8, R-2. |
| **A worker's pane shows the app's rendering of the session, not the harness's own TUI.** Slash-command pickers, Claude's spinner and Codex's diff viewer aren't there; the transcript, tool calls (expandable), approvals and questions (as cards), queued messages and a composer are. The real shell in the session's folder is one toggle away. | The TUI can only be driven by typing into and reading a screen, which the user ruled out for control, and its state has no ids. The harnesses' headless interfaces carry the same agent and configuration (MA-23). | MA-2, MA-4, MA-5, MA-7 (control on ids and events), MA-23 via the real CLIs. AP-10 (presentation) is negotiable. |
| **Sessions stop when the app quits** (the user's choice). A turn running at a quit is interrupted cleanly and continues by itself at the next launch, with a note; a crash cuts it off and it continues the same way. | Keeping harnesses alive needs a daemon that outlives app updates (R-8) and has its own crash and orphan story. The user asked for the effort to go into resumption. | MA-24, R-1 (one owner for every process), R-8, R-10. |
| **After a crash of the whole product, a message written to Claude in the instant before the crash counts as delivered** (it continues with the cut-off note, it isn't sent again). Codex is asked instead (`thread/resume` lists what the thread received). | Claude has no way to say which messages a conversation has; the window is the milliseconds between writing a message and Claude acknowledging it, and Claude reads stdin before anything else. Sending it again risks a double delivery. | MA-4 ("never twice"), R-2. |
| **Codex: a "deny" carries no message to the agent, and its questions can only be answered** (no Decline button for them; interrupting the turn withdraws them). | Codex's approval answer has no message field (`decline` only), and its user-input request has no "declined" answer. Claude's have both. | MA-14 (negotiable), MA-15. |
| **MCP elicitation forms and links are Codex-only.** | Claude's stream-json mode was never seen asking for elicitation (no recording, no probe); nothing to surface. Codex's are shown and answered (link: open then confirm; form: fields, a plain answer fills a one-field form). | MA-16 (negotiable). |
| **`agent wait` on Codex holds its answer up to 5 s after a (re)start** while MCP servers still report `starting`. | Codex reports server status after the thread opens; a fast first turn would otherwise end before the warning line could say what failed. | MA-29. |
| **Tool output kept in the transcript is clipped** to its first 12 KB and last 4 KB (the agent itself got all of it). | Storage grows with what the user keeps, not with what tools print; the view and the CLI stay fast. | R-9. |
| **`update --now` refuses while agent turns run** unless given `--force` (the "Install and Relaunch" dialog says how many turns it will interrupt; choosing it agrees). An update staged for "install on quit" installs at the next quit, which interrupts turns cleanly like any quit. | R-10: an update installs while turns run only if the user agrees. | R-10. |
| **Desktop notifications for agents are off in isolated instances** (test runs). | A test instance must not post notifications on the user's desktop. | P-1, R-5. |
| **Dragging an agent pane uses the grip in its header.** The terminal's own grab handle is under the session's view. | The session's view covers the terminal so keyboard and mouse go to it. | AP-1, AP-2. |

===================================================================================================

# Compromises (after phase 2: the user's answers)

The user's answers (REQUESTS.md, "Answers after phase 2") changed I-4 (updates ask first) and AP-3
(`agent start` runs in the background). They also settled two earlier items, which are no longer
compromises: a quit requested by another process doesn't ask (phase 1's table, above), and the MIT
license in the user's name.

| What is given up | Why | What it protects |
|---|---|---|
| **A yes covers one version.** While a downloaded update waits for the quit, background checks pause: a newer version published meanwhile is asked about after the staged one installs (`tern update` gets the newest at once). | One question and one staged update at a time; the notice never has to explain two versions. | I-4 (nothing downloaded without a yes; the notice stays simple and truthful). |
| **"Later" is a fixed 24 hours**, not a choice of times. | One button, like Sparkle's "Remind Me Later", which macOS users know. | I-4 (the question comes back by itself). |
| **An update an older build downloaded is downloaded again** after a yes, never installed from what the older build left. | Its zip and signature are gone, so it can't be verified again, and nobody agreed to it under the new rule. Costs one download (~22 MB). | I-4, P-2 (only verified, agreed builds install). |
| **The update notification can't be answered from Notification Center**; it says nothing downloads until the user says so and clicking it shows the sidebar's question. Isolated (test) instances post none. | The question lives in one place that stays until answered (the sidebar notice, plus `tern update`); notification buttons would be a second, less reliable place. | I-4 ("stays available until answered", "never takes focus"). |
| **While a managed session needs the user, the Dock badge counts those sessions** instead of Ghostty's bell count (`bell-features = attention`). | Background sessions have no tab to show "needs input"; the badge is the one place visible without opening anything. Bells show again when nothing needs the user. | Core: "a session that needs input is never silently stuck"; AP-3. |
| **Background sessions are found through the Window menu, the command palette, ⌃⌘J, notifications, the Dock badge and the CLI, not the sidebar.** | S-2 forbids an agents section in the sidebar, and the user asked for workers out of the sidebar. | S-2, AP-3. |

===================================================================================================

# Compromises (agent sessions, redone)

Phase 2's agent compromises above no longer apply where this part differs (BRIEF-agents.md: "None of
it is guidance"). What this design gives up:

| What is given up | Why | What it protects |
|---|---|---|
| **Taking over a running Claude turn interrupts it.** The user's "taking over is immediate" can't continue a Claude turn in its interface: Claude Code can't share a running turn between two processes. Codex's turn carries on in the interface. | Two processes on one Claude conversation would fork it; waiting for the turn would make taking over not immediate. | AG-6 ("immediate"), AG-11 (one process per conversation). |
| **A message to a live Claude session waits while the user has text typed in its interface** (typed with the keyboard or with `tern send`/`tern keys`; Enter, Ctrl-C or Ctrl-U ends the wait; text erased with Backspace still counts as typed until one of those), and it's delivered by briefly taking the session back (the pane shows the read-only view while it runs headless, then the interface returns). | Tern never types into an agent's interface, and Warp's hook mailbox loses messages; ending the interface while the user has a draft would lose the draft. | AG-9, AG-11, the user's own typing. |
| **Claude's "trust this folder" prompt appears when a session goes live in a folder Claude never opened**, although it already ran there headless. | Answering it writes the user's `~/.claude.json`; only installing Tern's plugins was approved. | BRIEF-agents.md §4 (the user's configuration). |
| **Status of a live interface is as good as its hooks**: an interrupt fires no hook, so Esc or Ctrl-C typed in the pane (keyboard, or `tern keys`) plus two quiet seconds counts as an interrupt; a live interface that hangs without hooks shows its last state. | Hooks are the only signal a live interface gives without screen reading (the user's rule). | AG-13, AG-19. |
| **Codex hooks are trusted for Tern's own plugin by Tern**, not by the user through `/hooks`. | Codex runs no plugin hook until trusted, so the plugin would do nothing; the user approved installing Tern's plugins for observing agents. Only `tern@tern`'s hooks are touched. | AG-18. |
| **Sessions still stop when Tern quits** (the user's earlier choice): a running turn is interrupted cleanly and continues by itself at the next launch; a live interface closes with the app and comes back live in its restored pane. | As before: a daemon that outlives app updates is a project of its own. | AG-22. |
| **Approvals and questions in a live session are answered in the agent's own interface**, not from Tern; Tern shows that the session needs the user. | The interface owns its prompts. | AG-17. |

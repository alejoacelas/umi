# Where Umi differs from Warp

Umi does what Warp does (commit `6398d1e`, vertical tabs on) for windows, tabs, panes, the sidebar,
the editor and the Markdown preview, except for the items below. Each says what Umi does instead.
Details of Umi's own features are in [attention-ui.md](attention-ui.md) and
[primitives.md](primitives.md).

## Chosen

| Area | Warp | Umi |
|---|---|---|
| More panes than fit | Every pane is on show. | A tab shows at most three panes; the others are hidden, listed in the pane strip, and keep running. |
| Pane chrome | Split terminal panes get a header with title, menu and close; the active pane gets an accent mark. | No pane headers for terminals. The pane strip in the window's title bar names every pane and is its drag handle. |
| Active pane and attention | An accent mark on the active pane; an 8 px unread dot on tab rows. | One small mark per pane, at its bottom right, for working, needs you, and finished but not seen. The focused pane's mark and the pane itself are slightly brighter. The same mark shows on strip chips and tab rows. |
| ⌘[ and ⌘] | Move to the previous or next pane. | The same over panes on show; past the end they peek at the next hidden pane, and Enter brings it in. |
| Moving panes between tabs | Drag a pane onto a tab row. | Hold ⌃⌘ and use the arrows, with the target tab shown as it would look and the sidebar listing every tab's panes. Dragging chips still works. |
| Moving tabs | ⌃⇧← / ⌃⇧→. | ⌃⇧↑ / ⌃⇧↓. |
| Resizing panes from the keyboard | ⌃⌘ arrows move a divider. | Not offered; ⌃⌘ arrows move panes. Dividers still drag. |
| A pane on demand | None. | A bottom drawer that rises over the tab, for the manager pane or anything a binding sends there. |
| Attention behaviour | Fixed. | Every decision (where "jump" goes, the Dock badge, which pane speaks for a tab) reads a list the user can redefine. |
| Comments on Markdown files | None. | Comments stored in the file, as in Umi's editor today. |
| Agents | Warp runs its own agents. | Umi runs none; Claude Code and Codex run in panes, and a hook plugin reports their state. |

## Because Umi is built on Ghostty

| Area | Warp | Umi |
|---|---|---|
| Terminal and keybindings | Warp's own terminal. | Ghostty's terminal and renderer. `umi shortcuts` lists and changes Umi's shortcuts and Ghostty's keybindings together. |
| Settings | Warp's settings UI. | `~/.config/umi/config`, in Ghostty's syntax. Ghostty's own config files are never read. |
| Undo | ⇧⌘T reopens closed panes, tabs and windows for 60 s. | The same, and ⌘Z keeps Ghostty's own undo. |

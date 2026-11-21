# umi-next: parity plan

The working plan for bringing Umi's features to umi-next, in four tracks built in parallel. Each
area says what Umi does, what Next has now and what Next will do. Keep it current: when a track
lands or changes an area, update its "Now" line (or mark it `[x] done`) in the same commit.

Sources: Umi's requirements are `acceptance/SPEC.md` (ids like E-11) and `acceptance/CLI.md`;
Next's departures are `next/DESIGN.md`. "Departure:" below marks a deliberate difference from Umi.

## Rules for every track

- Build in the web layer (`next/app/web`). Native Swift only for terminals and what a page can't
  do (file system, processes, sockets, the window). New native ops go through
  `Umi.bridge.request(op, args) → Promise`.
- A non-terminal pane is a pane whose `view` isn't `terminal` (as the picker is): add a renderer
  to `Umi.views.panes.renderers`; the web view has the keys while it is focused
  (`Umi.app.webWantsKeys`). New views: `file` (track a), `shortcuts` page and strip are chrome
  (track c).
- Global keys go in `Umi.shortcuts.table` (`web/shortcuts.js`); no Swift change per key. An entry
  is taken before any terminal or page sees the key; give keys an editor also wants (⌘F, ⌘G, ⌘/)
  `when: 'terminal'`, so a focused file pane gets them first.
- Change state only inside `Umi.app.update(fn)` / an `Umi.actions` entry, so it is saved, drawn
  and reported. Anything a key does is also an action the palette and the CLI can run.
- Keep DESIGN.md's rules: ⌘W closes a pane and ends its session; ⌥⌘H hides it and keeps it;
  ⌘D splits into the picker; nothing appears or disappears by itself; names at creation; no blue
  focus ring; Claude/Codex start with skip-permission flags.

## Track (a): editor, Markdown preview, comments

Uses `Umi.fs` (read, write with version, watch, root), `Umi.shortcuts.table` (editor keys).

**For other tracks:** `Umi.actions.openFile({path, line?, col?, pane?, mode?})` opens a file pane
(or focuses the one already showing `path`), to the right of `pane` (default: the focused pane).
`path` is absolute or relative to `Umi.fs.root()`; `line`/`col` are 1-based and put the caret
there in the source view (a Markdown file then opens in source); `mode` is `'rendered'` or `'raw'`.
Run it as any action: `Umi.app.run('openFile', {path, line})`; it returns the pane id. `focus: false` leaves the focus where it was. For the CLI: `Umi.editor.isDirty(paneId)`, `Umi.editor.discard(paneId)`; a pane's `mode` set from outside is followed. Third-party code (markdown-it,
CodeMirror, highlight.js, Mermaid) lives in `web/lib/` (the repository's `.gitignore` ignores
every `vendor/`).

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| File pane (E-1, E-9, E-24) | Markdown/text/JSON/CSV in a pane of its own; header with name, unsaved dot, Rendered/Raw, ⋯ menu, close | [x] done: `views/file.js`. Opens right of the pane it came from, one pane per file; Warp's header (name, dot, Rendered/Raw, ⋯ through the native menu, ✕); strip chip with the dot and the file's type icon (the explorer's). ⋯ has Warp's items, Maximize / Minimize pane first (track c's zoom). File views sit in `#files` over their slots, so a redraw keeps the editor | — |
| Closing a file pane | ⌘W closes; asks when unsaved | [x] done: ⌘W and ✕ close; unsaved edits ask Save / Don't Save / Cancel in the pane. No session, so it never goes to the hidden-pane strip | — |
| Source view (E-21, E-22, E-23) | Warp-like code editor: terminal font, gutter, git diff marks, tree-sitter colors, find/replace, ⌃G, ⌘/ line comments, ⇧⌘S | [x] CodeMirror 6 (`web/lib/codemirror.js`): 94 px gutter, active line, no wrap, Warp's ANSI colors by tag, find/replace panel at the top right, ⌃G go to line, ⌘/ comments, ⇧⌘S Save As (never replaces a file; another pane showing the name takes over); git marks at the gutter's left edge (added, changed, removed since HEAD: bridge `gitHead`, `web/gitmarks.js` = Umi's UmiGitDiff.marks), read again on open, save, a disk change and focus | Departure: Lezer/legacy grammars instead of tree-sitter; the font is Hack/JetBrains Mono/SF Mono (the page can't use Ghostty's built-in font) |
| Save, disk changes (E-3, E-4, E-5) | ⌘S saves with a toast; reloads an unmodified doc; "saved changes not reflected here" bar with Discard / Overwrite | [x] done: ⌘S writes with the read version and shows "File saved."; a watch reloads an unmodified file, shows Warp's bar on a modified one, says so when deleted and picks it up when recreated | Departure: UTF-8 only; other encodings are refused when opening (no re-encoding) |
| Refusals (E-6) | directories, devices, binaries, huge files refused clearly | [x] done: folders, non-UTF-8 and files over fs's 32 MB cap show a message in the pane | — |
| Unsaved edits on quit (E-3) | saved or a recovery copy | [x] done: unsaved edits live in the layout (`meta.drafts[path]`), kept across a web reload, quit or closed tab; opening the file again restores them (with the conflict bar if the file changed meanwhile) | — |
| Markdown preview (E-1, E-7, MD-1..MD-5) | Warp's look, Roboto, code blocks with language footer and Copy, Mermaid, relative links open files, #anchors, local images, find bar | [x] done: markdown-it with Umi's CSS, highlight.js, Mermaid (loaded on first diagram) with Raw/Rendered and full screen, Copy, Run in terminal, find bar (⌘F ⌘G ⇧⌘G), front matter table, task lists, heading anchors, local images through the bridge (`readData`), web links to the browser (`openURL`). The iframe is `sandbox="allow-same-origin allow-scripts"` with a CSP of `script-src 'none'`: the document runs nothing (scripts, handlers, javascript: links are blocked and stripped), and the parent page attaches all behaviour (a no-scripts sandbox also stops the parent's listeners)  Right-click in the preview: Copy (with a selection), Copy file path, Split pane right / down (into the picker), and in a split Maximize and Close pane, as Umi's | Departure: no Split left / up (Next has no left or up split) |
| Toggle (E-2) | ⇧⌘M and ⌘E toggle Rendered/Raw | [x] done | — |
| JSON / CSV preview (E-1) | JSON tree, CSV/TSV table | [x] done: `web/datapreview.js` (Umi's UmiDataPreview): JSON a folding tree in file order, CSV/TSV a table with row numbers, sticky header, numbers right-aligned; opens Rendered, Rendered / Raw as Markdown | — |
| Comments (E-11) | `{==words==}{>>comment<<}{#c1}` inline, YAML endmatter for author/time/replies/resolved; margin threads beside the words; reply, edit, resolve, reopen, delete; detached comments kept; Done button for `comments wait` | [x] done: `web/comments.js` (byte-identical output to `umi comments`; `tests/comments.test.js`), Umi's margin (`views/comments.js`) on the preview, ⌥⌘M in the preview and on a source selection. Every change goes to the file at once with its version (re-read and re-applied on a conflict); unsaved edits stay unsaved. Done calls `Umi.cli.commentsDone(path)`; the margin shows agents waiting with `comments wait` | — |
| Docs tab (E-10) | Markdown opened from Finder goes to a shared Docs tab | none | Later (needs the app as a document handler) |
| Web panes (E-12) | pages from `umi-web-origin` open in panes | none | Later |
| Settings (L-17 first half) | ⌘, opens the config file in the editor | none | Later: nothing to configure yet |

Checks: `tests/comments.test.js` (node), `tests/file_test.py` (debug socket, off screen),
`tests/file_keys_test.py` (real keys, under the screen lock).

## Track (b): file explorer, quick open, global search

Uses `Umi.fs` (list, watch, files + fuzzy, search, gitRoot), `Umi.shortcuts.table`; opens files
through track (a)'s `Umi.actions.openFile({path, line?, col?})`. Code: `web/views/modes.js`
(modes, header, shared helpers), `explorer.js`, `search.js`, `quickopen.js`, `vlist.js` (rows drawn
only in view), `web/icons.js` + `web/icons/` (Umi's Material file icons). Check:
`tests/files_test.py`.

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| Sidebar modes (S-2) | Tabs, Files, Search; ⌘B / ⌘\ toggle | [x] done: header buttons as Umi's; `S.layout.sidebarMode` | — |
| Search tabs (S-2 header) | "Search tabs..." field, ⌥⌘F | [x] done: matches the tab's name, folder, title, foreground program, session name; Esc clears, Enter shows the first | Branch and agent title once tabs show them |
| Explorer tree (S-2 Files) | git root of the focused pane's folder; follows disk changes; folders first, dotfiles first; ignored entries italic; `.git`, `.DS_Store` never shown; follows the focused file | [x] done. Root = git top folder of the focused pane's folder (`Umi.fs.gitRoot`: a worktree's own, not `Umi.fs.root()`'s main checkout). One recursive `Umi.fs.watch` on the root while Files shows; a change re-lists the open folders it touches | — |
| Explorer keys | ⇧⌘E / ⌃1 show it with focus (again: back); ↑↓ ← → Enter Esc; ⇧⌘> dotfiles | [x] done | — |
| Explorer menu | New File, Rename, Delete (to Trash), cd to Directory, Open in New Pane/Tab, Reveal in Finder, Copy Path, Copy Relative Path, Insert Path in Terminal | [x] done: Umi's items and order in a native menu (bridge `menu`); ops `trash`, `rename`, `reveal`, `openDefault`, `clipboard`, `sendText` (daemon `send`) | — |
| Quick open ⌘O (L-16) | fuzzy over tracked + untracked-not-ignored files, recent first, then changed; `path:line`; "Create a file named…" | [x] done: panel 117 from the top of the window (native clips terminals under it); Umi's scorer (`Umi.fs.fuzzy`); recent files in `layout.meta.recentFiles`. Changed files (bridge `gitStatus`) come after the recent ones with no query and get +10 with one, as Umi's. Departure: no Browse… / Open panel | — |
| Global search ⇧⌘F / ⌃3 (S-2 Search) | grouped by file, 300 ms debounce, regex/case toggles, 20,000-line cap, ↓ into results, ←/→ fold, Enter opens at line:col | [x] done, results streaming in; a new or empty query cancels the running search. Departure: rg (`--pcre2` for regexes, so Perl-style as Umi's) instead of `git grep`; bad-regex message is rg's | — |
| One palette (L-14 Warp parity) | ⌘P searches actions, sessions and files together with `files:` filters | bottom palette with `/` search over commands | Departure: the bottom palette stays the command palette (DESIGN); ⌘O is its own file picker, not a palette filter |

## Track (c): shortcuts page, hidden-pane strip, panes and tabs

Uses `Umi.shortcuts.table` and `Umi.shortcuts.format`.

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| Shortcuts page ⌘/ (L-17) | 361 px panel at the right, read-only, every Umi shortcut and Ghostty keybinding, searchable by name or keys ("cmd shift p", "⇧⌘P"); Esc closes | [x] done: 361 px at the right, drawn from `Umi.shortcuts.table` by `group` (live with the table), search by name or keys, Esc or ⌘/ closes; ⌘/ is `when: 'terminal'` so an editor keeps it. Panes reflow beside it. Ghostty's own keybindings in a Ghostty section after the table's, one row per action (bridge `ghosttyBindings`: this app's `+list-keybinds --default`, then the `keybind` lines of terminal.conf, the Umi config and their `config-file` includes, as Umi works them out); a key the table takes is struck through (the terminal never gets it); searchable as the rest | — |
| Changing shortcuts (`umi shortcuts set`) | kept in `shortcuts.json` | none | Departure: edit `web/shortcuts.js`; it reloads live |
| Hidden-pane strip (H-5) | chips for every pane above the panes; hidden ones dim; click brings back | [x] done: the top bar lists the open tabs (pane names moved to pane headers), then dim italic chips for the sessions ⌥⌘H hid from this tab (`tab.hidden`); clicking one shows it again at the right end of the top row (equal share), focused. Exit, the docket or showing the session elsewhere removes its chip. Closing a tab's last pane closes the tab (⇧⌘T brings it back) | Departure: no pane limit, so nothing else hides panes |
| Pane limit, make-room, `--until` (H-1, H-3) | 3 per tab, a pane hidden to make room; panes return by condition | none | Departure: none of it (DESIGN "Nothing appears or disappears by itself") |
| ⌘[ / ⌘] walk (H-6) | walks panes on show then hidden | ⌘[ ⌘] step through the tab's panes on show (2fb42775b) | Hidden ones: via the strip only |
| Tabs: new, select, next/prev (L-11) | ⌘T, ⌘1–9, ⇧⌘[ ⇧⌘], ⌃Tab | [x] done, ⌃Tab / ⌃⇧Tab included | — |
| Tab rename, close (S-4, L-2) | double-click / ⌃⌘R rename in place; close asks when a program runs | double-click and ⌃⌘R rename in place; × and ⌥⌘W stop showing the tab | [x] done. Closing a tab keeps its sessions (⌥⌘W hides, like ⌥⌘H), so no question |
| Tab move, pin, color, groups, search (L-13, S-4, S-13, S-14) | ⌃⇧↑↓, pin, colors, groups, Search tabs, right-click menu | [x] ⌃⇧↑↓ and dragging a row move a tab within its group; ⌃⌘P pins (pinned first, Warp's order); a new tab opens below the pinned ones. Right-click menu (S-4): Umi's items and order through the native menu, acting on the row's tab: Pin / Unpin tab, Archive Tab (Unarchive Tab for an archived one) · Copy branch, Copy tab title, Copy working directory, Copy pull request link (bridge `gitBranch`; the link from `gh pr view`, read in the background and kept 5 min) · Rename tab, Reset tab name, Rename active pane, Reset active pane name (the session's), Move Tab Down / Up · Close tab, Close other tabs, Close Tabs Below; what can't apply is left out | Departure: no colours or tab groups (not used), no Save as New Config (no launch configurations), no moves to other windows (one window). A tab never shown yet has no session, so no Rename active pane |
| Splits (L-1, L-19) | ⌘D / ⇧⌘D, panes share space equally | ⌘D / ⇧⌘D into the picker; dividers drag | [x] Equal sharing (L-19): a split along a row gives the new pane 1/(N+1) and keeps the others' proportions; a close shares the space in proportion. ⇧⌘D ⌘D left/up variants later |
| Pane focus by direction | ⌥⌘ arrows | ⌥⌘ arrows | [x] done |
| Zoom (L-3) | maximize/minimize a pane | [x] ⇧⌘↩ toggles `tab.zoomed`: only that pane shows, the others' sessions keep running; focusing another pane, a split or a close unzooms | — |
| Pane rename (L-3) | ⌃⇧⌘R in place | ⌃⇧⌘R and palette `r` rename the session | [x] done |
| Pane move (M-1, KM-1..5, ⌃⌘T) | ⌃⌘ arrows move panes within/between tabs; ⌃⌘T to new tab; drag | [x] ⌃⌘T to a new tab; ⌃⌘←→ swap with the neighbour in layout order; ⌃⌘↑↓ to the end of the tab above/below (a tab left empty closes); each step lands at once | KM's held-⌃⌘ preview and drag: later |
| Swap, resize, equalize (L-3) | CLI | divider drag; ⌃⌘= equalizes | Actions for the CLI track: `swapPanes`, `resizePane` |
| Reopen ⇧⌘T (L-20) | reopens a closed pane/tab/window | [x] ⇧⌘T brings back the last pane closed or hidden (in its old place and size when the tab hasn't changed, else at the right end) or the last tab closed (its position, name, pin, sessions). A pane whose session ⌘W ended comes back resuming the agent's transcript in a new session | Departure: no 60 s limit: hidden sessions keep running, ended agents resume from their transcript; an ended shell can't come back and is skipped |
| Attention: jump (L-12) | ⌃⌘J next pane needing you, ⌃⌘K back | `umi-next go --next` / `go --back` only | Departure: no keys and no palette entry (Alejo, 2026-11-21) |
| Pane indicator (PI-1..4) | small mark per pane: working, needs you, finished unseen | [x] a mark at each pane's bottom right (cut out of the terminal by native) and before its chip, hidden chips included, from `S.live[sid].agent`, in Umi's quiet palette and sizes. "Finished" lasts until the pane is focused (page memory, not persisted) | The sidebar row's mark: later |
| Notifications, Dock badge (T-6, `badge`) | desktop notification from panes; Dock badge counts needs-you | [x] Dock badge = Review items of the current project (`badge` message); `umi-next notify` posts a desktop notification (bridge `notify`), none from a snoozed or docketed session | Clicking a notification to focus its pane: later |
| Terminal right-click menu (L-31) | Warp's items with their keys, then Ghostty's; acts on the pane clicked | [x] `web/views/termmenu.js`, through the native menu (keys from the shortcut table and the terminal's Ghostty bindings): Copy (text selected) · Paste (greyed with an empty clipboard), Clear (neither with text selected before the click or in a full-screen program) · Split Pane Right, Split Pane Down, in a split Maximize / Minimize Pane and Close Pane (⌘W's) · Reset Terminal, Terminal Read-only (checked) · Change Tab Title..., Change Terminal Title... (renames the session). A program reading the mouse gets the right-click instead. Paste goes into synchronized panes too | Departure: no Split Pane Left / Up (Next splits right and down), no Toggle Terminal Inspector (no inspector) |
| Edit menu | Undo, Redo, Cut, Copy, Paste, Select All | [x] the same items; a terminal takes Copy, Paste and Select All, and the rest pass its keys on | — |
| Tab switch fade (L-11) | 140 ms fade on tab switch | [x] terminals (native) and the page's panes fade in over 140 ms; none with Reduce Motion | — |
| Find in terminal (Ghostty's search) | ⌘F bar at the top right, ⌘G ⇧⌘G, Esc | [x] ⌘F opens a bar at the pane's top right (drawn by the page, cut out of the terminal by native: `holes`); Ghostty searches and highlights; count "N of M"; ⌘G / ⇧⌘G / Enter / ⇧Enter step; Esc closes. Keys are `when: 'terminal'` | — |
| UI zoom, font size (L-33) | ⌘= ⌘- ⌘0; ⌥⇧> ⌥⇧< | [x] ⌘= ⌘- step Warp's levels, ⌘0 100%: the page's zoom and the terminals' text; ⌥⇧> ⌥⇧< one point (5–25, from the config's font-size). Kept in layout.json (`zoom`) | — |
| Sidebar width (S-8) | drag the edge, 180–600 pt | [x] drag the edge, 180–600 px, kept in the layout (`sidebarWidth`) | — |
| Drawer, manager pane (DR) | drawer with ⌃⌘M | none | Departure: the bottom palette, Review and snooze replace them (DESIGN) |
| Archive (AR-1..4, AR-6) | archived tabs under an Archived row | [x] ⌃⌘A archives the tab or brings it back (top of the unpinned); "Archived · N" row at the top opens in place; ⌘1–9, ⇧⌘[ ⇧⌘], ⌃Tab skip archived tabs; palette: Show archived tabs | Departure: no `--until` (DESIGN) |
| Synchronized input (L-32) | ⌥⌘I this tab, all tabs, ⌥⇧⌘I stop; link mark | [x] as Umi (Warp's rules); native types each key and ⌘V paste into every synced terminal; link mark #4A93FF on the row | Panes of other tabs not shown since launch have no terminal yet and miss the input |
| Command palette ⌘P, pane list ⇧⌘P (L-14, L-15) | palette from `umi help --json`; every pane, most recent first | bottom palette; picker lists sessions | Departure: bottom palette (Hyper) replaces both; ⌘P opens it too. Pane list = palette `s` |

## Track (d): `umi-next` CLI

Mirrors the `umi` commands that drive the UI. Same flags, `--json` shapes and exit codes as
CLI.md, so agents and the `umi:umi-comments` skill work by swapping the binary name. `umi-next
help` lists them. Checks: `next/app/tests/cli_test.py`.

How it works:

- **The binary** is `Contents/MacOS/umi-next` (source `next/app/cli/`, built by `build.sh`);
  `install.sh` links `~/.local/bin/umi-next` to it, as Umi links `umi`. Sessions get
  `UMI_NEXT_CLI` (this app's copy). It never talks to Umi: its state folder is
  `UMI_NEXT_STATE_DIR`, else the state folder of the app it ships in (a test copy's CLI drives
  that copy).
- **The UI control socket** `<state>/ui.sock` (`Sources/UmiNext/ControlServer.swift`), framed as
  the daemon's `J` messages: one request `{cmd, args, caller}` per connection, reply
  `{ok, result|error}`. Swift hands each request to the page (`{type: 'cli', id, req}`); `web/cli.js`
  answers (`cliReply`) through `Umi.app.update` and `Umi.actions`, so the CLI and keys share code.
  Requests wait up to 5 s for the page after a launch or reload; a reload fails the requests the
  old page was answering ("try again"), except `comments wait`, which goes to the new page.
- **The calling session.** Sessions have `UMI_NEXT_SESSION_ID`; PANE and TAB default to the pane
  showing that session and its tab (pane ids change when a session moves; session ids don't), else
  the focused ones. A PANE is a pane id or prefix, a session id or prefix, a session name, or `.`.
- **Sessions the CLI starts in a pane are `by: user`** (`start.by`): they show in the picker,
  Review and "next waiting". Only `umi-next-ctl new` (no pane) makes `by: cli` sessions (DESIGN
  "Sessions the user started").
- **Session I/O goes to the daemon**: `send`, `keys`, `read`, `wait` work while the UI is down.
- **Comments without the app** run `web/comments.js` (`UmiComments`) in JavaScriptCore, plus the
  CLI's lookup of `--on TEXT --nth N`; files written by `umi comments` and `umi-next comments`
  are byte-identical. `comments wait` needs the UI.
- **Focus log**: Next writes Umi's format to `<state>/logs/focus/YYYY-MM-DD.jsonl` (default
  `~/Library/Application Support/Umi-next/logs/focus/`; `Sources/UmiNext/FocusLog.swift`), and
  `umi-next focus-log [--by session]` reads it with Umi's own grouping code, so the `day` skill can
  read Next's as it reads Umi's.

What the CLI uses from the other tracks:

- Track a (in): `Umi.actions.openFile({path, pane, mode, focus: false})` (`edit`); file panes
  `{view: 'file', path, mode: 'rendered'|'raw'}`, shown as `preview`/`source`;
  `Umi.views.file.isDirty`, `.get(pane).setMode` (`editor`); the margin's Done event
  `umi:commentsDone` and `Umi.views.file.setWaiting` (`comments wait`).
- Track b: `Umi.actions.sidebarMode({mode})` and `layout.sidebarMode` (`sidebar tabs|files|search`).
- Track c: `Umi.actions.toggleZoom` and `tab.zoomed`, `Umi.actions.goBack` (⌃⌘K),
  `Umi.actions.showHidden({session})` and `Umi.model.hiddenOf(tab)` (the strip), bridge op
  `notify {title, body}`.

| Command (CLI.md) | Next |
|---|---|
| `ls [--json]` | [x] tabs, panes, each pane's session; `sessions` lists every live session with `by` and the pane showing it; `hidden` per tab once track c keeps it. Departure: no `--where` |
| `tab new [NAME] [--cwd] [--cmd] [--name] [--no-focus]` | [x] a new session (a shell without `--cmd`); NAME names the tab |
| `tab focus\|close\|rename\|next\|prev\|move --up/--down` | [x] `close` stops showing the tab's panes (sessions keep running) |
| `split [right\|down\|left\|up] [--pane] [--cwd] [--cmd] [--name] [--ratio] [--no-focus]` | [x] prints the pane; JSON adds `session`. Departure: without `--cmd`, the split shows the picker as ⌘D does |
| `pane focus\|close\|info\|rename\|swap\|resize\|move --new-tab` | [x] `close` = ⌘W: closes the pane and ends its session; `focus` on a session no pane shows opens it beside the focused pane; `rename` renames the session; `resize` moves the divider by cells |
| `pane exit` (new) | [x] ends the session, as the palette's Exit |
| `pane hide`, `pane show [--focus]` | [x] `hide` = ⌥⌘H: the session goes on the tab's strip; `show` brings it back through the strip at the right end of the tab, focus stays unless `--focus`. Departure: no `--until` |
| `pane zoom` | [x] toggles track c's zoom |
| `send [--enter]`, `keys`, `read [--scrollback] [--lines]`, `wait --pattern\|--idle [--timeout]` | [x] daemon-side; several lines go as a bracketed paste when the program asked for it; keys follow the session's cursor-key and kitty modes. `read --scrollback` adds the daemon's scrollback (10 MB / about 10,000 lines per session, as PROTOCOL.md says; a reattached pane gets the same history); a daemon started before it gives a clear error. Departures: `wait --pattern` matches the screen minus the line echoing the last `send` (no shell marks); no `wait --attr` |
| `sidebar on\|off\|toggle\|status\|tabs\|files\|search` | [x] |
| `notify [--pane P] TITLE [BODY]` | [x] none from a snoozed or docketed session (`suppressed` in `--json`) |
| `go --next jump`, `go --back` | [x] next waiting; back to where the walk started |
| `shortcuts [ls]` | [x] prints `Umi.shortcuts.table`. Departure: `shortcuts set` → edit `web/shortcuts.js` |
| `edit FILE… [--source\|--preview] [--pane\|--tab]`, `open` | [x] each file to the right of the one before; a file already open shows where it is; focus stays put. URLs refused until web panes |
| `editor ls\|close [--force]\|mode` | [x] `close` refuses unsaved edits without `--force`, which drops them and their draft |
| `comments [ls]\|add\|reply\|edit\|resolve\|reopen\|delete` | [x] on the file, without the app |
| `comments wait FILE [--timeout]` | [x] answered by the file margin's Done; survives a page reload; 124 on timeout |
| `focus-log [--since] [--until] [--pane] [--by]` | [x] Next's own focus log |
| `help [--json]` | [x] |

Not mirrored: `window …` (one window), `drawer …`, `tab archive|pin|color|equalize`, `pane
set|get|until` attributes and queries, `list`/`slot`/`command`, `events`, `log`, `layout`,
`reopen`, `screenshot`, `worktree`, `link` (the `umi-next://` handler covers it), `hook` (the
`umi-next-hook` script covers it), `update`, `plugins`, `doctor`. They exit 1 saying so.

## Not planned / later

- Updater and release (I-4, `update`): `next/install.sh` from a checkout is the install.
- Settings / config file, slots, named lists, queries, key bindings and palette commands from the
  config (Q-1..Q-8).
- Multiple windows, tab moves between windows (M-2, M-5, M-6).
- Launch configurations (L-21).
- Attributes, events and the activity log (D-1..D-8). The focus log is in (track d).
- Warp's terminal look (S-9..S-12) beyond what Ghostty's zsh integration already gives.
- Docs tab and default-app registration (E-10, `editor default`), web panes (E-12).

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
- Keep DESIGN.md's rules: ⌘W stops showing a pane and keeps its session; only Exit ends one;
  ⌘D splits into the picker; nothing appears or disappears by itself; names at creation; no blue
  focus ring; Claude/Codex start with skip-permission flags.

## Track (a): editor, Markdown preview, comments

Uses `Umi.fs` (read, write with version, watch, root), `Umi.shortcuts.table` (editor keys).

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| File pane (E-1, E-9, E-24) | Markdown/text/JSON/CSV in a pane of its own; header with name, unsaved dot, Rendered/Raw, ⋯ menu, close | none | `view: 'file'` pane `{path, mode}`; opens to the right of the pane it came from; one pane per file (opening again focuses it). Header as Umi's |
| Closing a file pane | ⌘W closes; asks when unsaved | — | ⌘W closes the file pane, asking when unsaved. A file pane has no session, so it doesn't go to the hidden-pane strip. **Open:** confirm with Alejo |
| Source view (E-21, E-22, E-23) | Warp-like code editor: terminal font, gutter, git diff marks, tree-sitter colors, find/replace, ⌃G, ⌘/ line comments, ⇧⌘S | none | CodeMirror 6, vendored as one prebuilt ESM file in `web/vendor/` (no bundler in the web layer). Find/replace, go to line, toggle comment come with it. Git marks: later (needs a `git diff` bridge op) |
| Save, disk changes (E-3, E-4, E-5) | ⌘S saves with a toast; reloads an unmodified doc; "saved changes not reflected here" bar with Discard / Overwrite | none | ⌘S → `Umi.fs.write(path, text, {version})`; a `conflict` shows Umi's bar. `Umi.fs.watch` reloads an unmodified doc. UTF-8 only; other encodings refused with a message. Departure: no re-encoding (rare; not worth porting) |
| Refusals (E-6) | directories, devices, binaries, huge files refused clearly | none | `Umi.fs.read` errors shown in the pane; size cap in fs.js |
| Unsaved edits on quit (E-3) | saved or a recovery copy | — | Drafts kept in the layout state per file pane; restored on reload. The web layer reloading on save must never lose an edit |
| Markdown preview (E-1, E-7, MD-1..MD-5) | Warp's look, Roboto, code blocks with language footer and Copy, Mermaid, relative links open files, #anchors, local images, find bar | none | markdown-it + highlight.js + Mermaid (vendored; Umi's `MarkdownAssets/` has highlight, Mermaid, Roboto to copy). Rendered into a sandboxed `<iframe sandbox="allow-same-origin">` (no scripts) so raw HTML in a document can't reach the bridge. Departure: Run in terminal (MD-2) later |
| Toggle (E-2) | ⇧⌘M and ⌘E toggle Rendered/Raw | none | Same keys while a file pane is focused |
| JSON / CSV preview (E-1) | JSON tree, CSV/TSV table | none | Later: source view first |
| Comments (E-11) | `{==words==}{>>comment<<}{#c1}` inline, YAML endmatter for author/time/replies/resolved; margin threads beside the words; reply, edit, resolve, reopen, delete; detached comments kept; Done button for `comments wait` | none | `web/comments.js`: parse/serialize Roughdraft markup (port `app/macos/UmiCLI/UmiComments.swift`, keep its tests as fixtures). Preview margin threads, ⌥⌘M on a selection. Every change writes the file at once via `Umi.fs.write` with version; on `conflict`, re-read and re-apply. Done posts to the CLI track's waiters |
| Docs tab (E-10) | Markdown opened from Finder goes to a shared Docs tab | none | Later (needs the app as a document handler) |
| Web panes (E-12) | pages from `umi-web-origin` open in panes | none | Later |
| Settings (L-17 first half) | ⌘, opens the config file in the editor | none | Later: nothing to configure yet |

## Track (b): file explorer, quick open, global search

Uses `Umi.fs` (root, list, watch, files + fuzzy, search), `Umi.shortcuts.table`; opens files
through track (a)'s `Umi.actions.openFile({path, line?, col?})`. Until (a) lands, a stub opens the
file in the default app.

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| Sidebar modes (S-2) | Tabs, Files, Search; ⌘B / ⌘\ toggle | Review + tabs; ⌘B toggles | Same three modes; Review stays above the tabs in Tabs mode |
| Explorer tree (S-2 Files) | git root of the focused pane's folder; follows disk changes; folders first, dotfiles first; ignored entries italic; `.git`, `.DS_Store` never shown; follows the focused file | none | `Umi.fs.list` per expanded folder, `Umi.fs.watch` on expanded folders. Root = `Umi.fs.root()`, which follows the focused pane |
| Explorer keys | ⇧⌘E / ⌃1 show it with focus (again: back); ↑↓ ← → Enter Esc; ⇧⌘> dotfiles | none | Same |
| Explorer menu | New File, Rename, Delete (to Trash), cd to Directory, Open in New Pane/Tab, Reveal in Finder, Copy Path, Copy Relative Path, Insert Path in Terminal | none | Same items. Needs bridge ops: `fs.trash`, `fs.rename`, `reveal`, `openDefault`, `clipboard`; Insert Path / cd send text to the focused session (daemon `send`) |
| Quick open ⌘O (L-16) | fuzzy over tracked + untracked-not-ignored files, recent first; `path:line`; "Create a file named…" | none | Panel at the top of the panes over `Umi.fs.files` + `Umi.fs.fuzzy`; recent files kept in layout meta; `path:line`; create via `Umi.fs.write(path, '', {version: null})`. Departure: no Browse… / Open panel |
| Global search ⇧⌘F / ⌃3 (S-2 Search) | grouped by file, 300 ms debounce, regex/case toggles, 20,000-line cap, ↓ into results, ←/→ fold, Enter opens at line:col | none | `Umi.fs.search` streamed (rg); same keys and toggles. Departure: rg instead of `git grep` (streams, faster); bad-regex message is rg's |
| One palette (L-14 Warp parity) | ⌘P searches actions, sessions and files together with `files:` filters | bottom palette with `/` search over commands | Departure: the bottom palette stays the command palette (DESIGN); ⌘O is its own file picker, not a palette filter |

## Track (c): shortcuts page, hidden-pane strip, panes and tabs

Uses `Umi.shortcuts.table` and `Umi.shortcuts.format`.

| Area | Umi | Next now | Planned Next |
|---|---|---|---|
| Shortcuts page ⌘/ (L-17) | 361 px panel at the right, read-only, every Umi shortcut and Ghostty keybinding, searchable by name or keys ("cmd shift p", "⇧⌘P"); Esc closes | none | Panel at the right drawn from `Umi.shortcuts.table`, grouped by `group`, same search. Ghostty's keybindings: later (needs a bridge op listing them). With focus in the editor's source, ⌘/ stays the editor's |
| Changing shortcuts (`umi shortcuts set`) | kept in `shortcuts.json` | none | Departure: edit `web/shortcuts.js`; it reloads live |
| Hidden-pane strip (H-5) | chips for every pane above the panes; hidden ones dim; click brings back | title-bar strip with a chip per shown pane, click focuses (a7855cae9) | Add chips for the sessions ⌘W hid from the current tab, after the shown ones; clicking one shows it again at the right end, focused. A tab remembers the sessions it hid; Exit or showing the session elsewhere removes its chip. Departure: no pane limit, so nothing else hides panes |
| Pane limit, make-room, `--until` (H-1, H-3) | 3 per tab, a pane hidden to make room; panes return by condition | none | Departure: none of it (DESIGN "Nothing appears or disappears by itself") |
| ⌘[ / ⌘] walk (H-6) | walks panes on show then hidden | none | ⌘[ ⌘] step focus through the tab's panes on show. Hidden ones: via the strip only |
| Tabs: new, select, next/prev (L-11) | ⌘T, ⌘1–9, ⇧⌘[ ⇧⌘], ⌃Tab | ⌘T, ⌘1–9, ⇧⌘[ ⇧⌘] | Add ⌃Tab / ⌃⇧Tab |
| Tab rename, close (S-4, L-2) | double-click / ⌃⌘R rename in place; close asks when a program runs | rename only at creation; × stops showing the tab | Double-click and ⌃⌘R rename in place (same field as at creation). Close keeps sessions (⌘W rule), so no question |
| Tab move, pin, color, groups, search (L-13, S-4, S-13, S-14) | ⌃⇧↑↓, pin, colors, groups, Search tabs, right-click menu | none | ⌃⇧↑↓ move and drag to reorder now. Pin, colors, groups, search, menu: later |
| Splits (L-1, L-19) | ⌘D / ⇧⌘D, panes share space equally | ⌘D / ⇧⌘D into the picker; dividers drag | Equal sharing within a row on split (L-19); ⇧⌘D ⌘D left/up variants later |
| Pane focus by direction | ⌥⌘ arrows | ⌥⌘ arrows | [x] done |
| Zoom (L-3) | maximize/minimize a pane | none | ⇧⌘↩ toggles zoom of the focused pane (layout flag, other panes hidden while zoomed; their sessions keep running) |
| Pane rename (L-3) | ⌃⇧⌘R in place | palette `r` renames the session | ⌃⇧⌘R opens the same rename |
| Pane move (M-1, KM-1..5, ⌃⌘T) | ⌃⌘ arrows move panes within/between tabs; ⌃⌘T to new tab; drag | palette `m` to new tab | ⌃⌘T = move to new tab. ⌃⌘←→ swap with neighbour; ⌃⌘↑↓ to the tab above/below. Drag: later |
| Swap, resize, equalize (L-3) | CLI | divider drag | Actions for the CLI track: `swapPanes`, `resizePane`, `equalize` |
| Reopen ⇧⌘T (L-20) | reopens a closed pane/tab/window | none | Departure: not needed: closed panes' sessions stay in the picker and the strip |
| Attention: jump (L-12) | ⌃⌘J next pane needing you, ⌃⌘K back | palette `w` next waiting | ⌃⌘J = next waiting; ⌃⌘K back to where the walk started |
| Pane indicator (PI-1..4) | small mark per pane: working, needs you, finished unseen | Review list; none on panes | A mark at each terminal slot's bottom right and on strip chips, from `S.live[sid].agent` |
| Notifications, Dock badge (T-6, `badge`) | desktop notification from panes; Dock badge counts needs-you | none | Bridge op `notify` and `badge(count)`; badge = Review items of the current project. Alerts follow DESIGN's snooze rules |
| Tab switch fade (L-11) | 140 ms fade on tab switch | none | Later |
| UI zoom, font size (L-33) | ⌘= ⌘- ⌘0; ⌥⇧> ⌥⇧< | none | Later |
| Sidebar width (S-8) | drag the edge, 180–600 pt | fixed | Drag the edge; width in layout |
| Drawer, manager pane, archive (DR, AR) | drawer with ⌃⌘M; archived tabs | none | Departure: the bottom palette, Review and snooze replace them (DESIGN) |
| Command palette ⌘P, pane list ⇧⌘P (L-14, L-15) | palette from `umi help --json`; every pane, most recent first | bottom palette; picker lists sessions | Departure: bottom palette (Hyper) replaces both; ⌘P opens it too. Pane list = palette `s` |

## Track (d): `umi-next` CLI

Mirrors the `umi` commands that drive the UI. Same flags, `--json` shapes and exit codes as
CLI.md, so agents and the `umi:umi-comments` skill work by swapping the binary name.

What it needs:

- **A UI control socket.** The UI has only the debug socket (`UMI_NEXT_DEBUG=1`). Add
  `<state>/ui.sock` in Swift, framed as the daemon's `J` messages (next/daemon/PROTOCOL.md). Swift
  passes each request to the page (`umiNative.receive({type: 'cli', id, req})`) and the page
  answers with `Umi.bridge.post({type: 'cliReply', id, …})`, because the layout lives in the page.
  The page's handler (`web/cli.js`) maps commands to `Umi.actions`, so the CLI and keys share code.
- **The calling session.** Sessions have `UMI_NEXT_SESSION_ID`; the CLI defaults PANE to the pane
  showing that session (Next's pane ids change when a session moves; session ids don't). Selectors
  accept a session id, a session name or `.`.
- **Session I/O goes to the daemon**, not the UI: `send`, `keys`, `read`, `wait` use the daemon
  socket as `umi-next-ctl` does, so they work while the UI is down.
- **Comments without the app**: `comments ls|add|reply|edit|resolve|reopen|delete` work on the file
  alone. Run the same `web/comments.js` in JavaScriptCore from the CLI, so the page and the CLI
  share one parser. `comments wait` needs the UI (blocks on the socket until Done).

| Command (CLI.md) | Next |
|---|---|
| `edit FILE… [--source\|--preview] [--pane P\|--tab T]`, `open` | opens file panes (track a); focus stays put; URLs refused until web panes |
| `editor ls`, `editor close [--force]`, `editor mode` | track a's file panes |
| `comments …` (all of them), `comments wait FILE [--timeout]` | as above; 124 on timeout |
| `ls [--json]` | tabs, panes, each pane's session; `hidden` lists the strip's sessions |
| `tab new\|focus\|close\|rename\|next\|prev\|move --up/--down` | tab actions; `tab new` takes a name (names at creation) |
| `split [right\|down] [--cwd] [--cmd] [--name] [--no-focus]` | Departure: without `--cmd`, the split shows the picker as ⌘D does |
| `pane focus\|close\|rename\|zoom\|swap\|resize\|move --new-tab` | `pane close` stops showing (⌘W rule); `pane exit` ends the session (new) |
| `pane hide`, `pane show [--focus]` | strip actions. Departure: no `--until` |
| `send`, `keys`, `read`, `wait --pattern\|--idle` | daemon-side |
| `sidebar on\|off\|toggle\|tabs\|files\|search` | track b's modes |
| `notify TITLE [BODY]` | track c's `notify` op |
| `go --next jump`, `go --back` | next waiting / back (track c) |
| `shortcuts [ls]` | prints `Umi.shortcuts.table` |
| `help --json` | yes: the palette may list CLI commands later |

Not mirrored: `window …` (one window), `drawer …`, `tab archive|pin|color`, `pane set|get`
attributes and queries, `list`/`slot`/`command`, `events`, `log`, `focus-log`, `layout`,
`reopen`, `screenshot`, `worktree`, `link` (the `umi-next://` handler covers it), `hook` (the
`umi-next-hook` script covers it), `update`, `plugins`, `doctor`.

## Not planned / later

- Updater and release (I-4, `update`): `next/install.sh` from a checkout is the install.
- Settings / config file, slots, named lists, queries, key bindings and palette commands from the
  config (Q-1..Q-8).
- Multiple windows, tab moves between windows (M-2, M-5, M-6).
- Launch configurations (L-21), synchronized input (L-32), the terminal's right-click menu (L-31).
- Attributes, events, activity log and focus log (D-1..D-8); the `day` skill reads Umi's focus log.
- Warp's terminal look (S-9..S-12) beyond what Ghostty's zsh integration already gives.
- Docs tab and default-app registration (E-10, `editor default`), web panes (E-12).

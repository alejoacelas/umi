# Product specification (outcomes only)

A macOS terminal, forked from Ghostty, for working with coding agents. This file says **what the
user and their agents must be able to observe**, never how it is built. Every requirement has an ID.
The tag after it says how it is checked:

- **[A]**: an automated test in `tests/` (grep for the ID).
- **[W]**: a written check in `CHECKS.md`. A scripted setup produces evidence, usually a screenshot,
  that a person or model judges against the stated outcome.
- **[A+W]**: both.

`<cli>` is the product's command line tool. Its exact command surface is fixed by `CLI.md`, because
agents and scripts depend on it. `TEST_INTERFACE.md` lists the few things a build must provide so it
can be tested in isolation.

The words come from the user's own requests. Their verbatim requests are in `REQUESTS.md`; when in
doubt, they win.

---------------------------------------------------------------------------------------------------

## How the product is used

This is what the requirements serve, and what decides between them when they compete.

- **The orchestrator.** The user keeps an orchestrator agent running all day, usually Claude Code
  and sometimes Codex, in one of the app's panes (live) or as a headless session.
  - It runs in full-access (bypass permissions) mode.
  - Otherwise it uses its harness's full feature set: the user's skills (notably
    `supervise-workers`), MCP servers, subagents, background tasks, plan mode and questions to the
    user.
- **The workers.** The orchestrator starts Claude Code and Codex workers through `<cli>`, usually with
  full access, in a folder or a fresh git worktree, on a chosen model and effort. Workers run
  headless, and use their harness's full feature set.
  - The `supervise-workers` loop: write a task file, start a worker pointing at it, wait for it to
    finish, read the report, check the evidence, follow up or steer.
  - Follow-ups come seconds or hours later. Sometimes the orchestrator steers, interrupts or stops a
    worker, starts more, or has workers start their own workers.
- **The user.** The user watches all of this in the app. They arrange panes, tabs and windows
  Warp-style, move live terminals and sessions around, read files in the editor, and now and then step
  in: locate a session in a pane, take it over in the agent's own interface, hand it back.
- **Long runs.** The app, the orchestrator and the workers run for days. Over that time the machine
  sleeps, the app quits or crashes, and new builds get installed.

## Priorities

Each requirement below belongs to one of three tiers.

### Fixed: not up for compromise
The Warp-like interface and everything about panes, tabs and windows: creating, arranging and moving
terminals (and agents shown in panes) between panes, tabs and windows, from the UI and the CLI. Also
the product's identity, packaging and editor.

Requirements: P-1 to P-4, I-1 to I-5, L-1 to L-21, L-31 to L-33, M-1 to M-6, T-1 to T-7, S-1 to S-14, E-1 to E-12, E-21 to E-24, MD-1 to MD-5.

### Core: agent sessions
These outcomes must hold every time, with both harnesses. How they are achieved is open. The user's
order: first, launching sessions that run reliably and that the user can interact with in the pane,
tab or window they choose; second, agents supervising and steering other agents.
- **Launch:** headless start, sessions the user will use going live in their chosen place, fidelity
  to the agent the user would get in their own terminal.
- **Headless and live:** a read-only view only where the user asks for one, taking over at once,
  handing back, removing a session from its pane without stopping it, messages that reach live
  sessions.
- **Supervision:** message ids, steering, exactly-once delivery, wait/read, truthful status,
  interrupt, stop, list, resume, watch, reports, orchestration from inside agents.
- **Observability:** the agents' own hooks report their state, Warp-style, for sessions the product
  started and agents the user typed.
- **A CLI agents can use with no instructions.**
- **Robustness:** crashes, restarts, upgrades, isolation, long runs, no orphans.

Requirements: AG-1 to AG-24, R-3 to R-7.

### Negotiable
Wanted, but these may be simplified, reworked or left out when keeping them would cost reliability in
the tiers above. Record every such compromise in `COMPROMISES.md`: what, why, and which requirement it
protects.
- How the read-only view presents a session, beyond AG-5.
- Approval flows for sessions that don't have full access, beyond surfacing and answering them
  (part of AG-17).

### Not requirements
These are open design decisions, not requirements. Make them on the merits and validate them with the
tests:
- how the read-only view presents a session;
- what process owns agents and sessions, and how the CLI finds the app;
- whether agents keep running while the app isn't. The user's call: sessions may stop when the app
  quits, as long as AG-10 and AG-22 hold. They would rather the effort go into making resumption
  reliable than into keeping agents alive across app restarts.

The user's instructions for agent sessions (BRIEF-agents.md §1, "Agent sessions") replace
`REQUESTS.md`'s "two launch modes": the product always launches and controls sessions headless;
sessions move from headless to live (the agent's own interface in a pane) and back. Control still
rests on identifiers and events the harness itself reports, never on reading or typing into a
screen; the one thing typed into a pane is the command that starts the agent's own interface there.

## Delivery phases

The product is delivered in two phases, each built against this suite. The tiers apply within each
phase.

- **Phase 1, the app:** everything that doesn't need managed agents. That's P, I, L, M, T, S, E and
  IA, and the parts of R-3 to R-7 about windows, panes and the CLI. Two items inside these groups
  wait for phase 2: L-9's ⌃⌘J (jump to the agent that needs the user) and S-3's managed-agent status
  line.
- **Phase 2, the harness:** managed agents, built on phase 1's app. That's MA, AP, the rest of R,
  and the agent parts above.

Tests that need managed agents carry the `harness` marker. `--phase 1` leaves them out, and the
traceability report marks requirements that only they cover as deferred.

Phase 2 requirements (since replaced by AG): MA-1 to MA-29, AP-1 to AP-11, R-1, R-2, R-8 to R-10.

A third run redid agent sessions (AG, replacing phase 2's MA, AP, IA, R-1, R-2 and R-8 to R-10)
and made the app changes the user decided after phase 2.

Phase 1 must not close doors on phase 2. Its decisions about panes, the CLI, control endpoints,
stored state and identity leave room for sessions shown in panes, agent commands in the CLI,
and agents reaching the app from their own processes.

---------------------------------------------------------------------------------------------------

## P. Product and identity

- **P-1 [A]** The app, its bundle id, its state directory, its control endpoints and its CLI name are
  distinct from Ghostty's, from Tern's (its own former name), from "Wraith"'s and from "Shade"'s.
  It can be installed and run next to them without either one affecting the other.
- **P-2 [A]** The app never offers another product's updates, upstream Ghostty's included. Its
  updates come only from the product's own release feed (I-4).
- **P-3 [A]** Only one instance of a given build runs at a time. A second launch of the same build,
  including two simultaneous launches, ends with exactly one running instance, and that instance keeps
  serving the CLI.
- **P-4 [A]** Inside the app's terminals, `<cli>` is on PATH and commands default to "this pane"
  (and its tab and window).

## I. Installation and packaging

- **I-1 [A]** A packaged build installs on another Apple Silicon Mac with only the package. Nothing
  else is required (no Zig, Xcode, Python or Homebrew). The installer:
  - copies the app;
  - clears the download quarantine;
  - links `<cli>` into `~/.local/bin`;
  - makes the app the default for Markdown, unless asked not to.
- **I-2 [A]** After install, `<cli> doctor` reports what is missing on this machine, for example
  `claude`, `codex` or `git` not on the login PATH, and exits non-zero if anything is.
- **I-3 [W]** `open README.md` (or double-clicking a `.md` file) opens it in the app's editor.
- **I-4 [A]** Updates. An installed copy updates itself from the product's own public release feed,
  without interrupting the user and without their having to act (REQUESTS.md, 2026-10-27):
  - it checks in the background (about every 15 minutes), from a "Check for Updates…" menu item and
    from `<cli> update`, which checks at once;
  - a check that finds a newer signed release downloads and verifies it without asking, then installs
    it at the first quiet moment and relaunches. Quiet means all of these hold, and anything the
    product can't be sure of counts as busy:
    - no agent turn runs in any session the product knows (started by it or typed in a pane, AG-18),
      and no message waits to be delivered;
    - every pane is at its own shell's prompt with nothing typed and nothing else running there
      (no foreground program, no job, no shell started from it), or shows an idle agent: its own
      interface with nothing typed in it, or a read-only view;
    - no editor or other window holds unsaved changes or a dialog that a relaunch would lose;
    - nobody has typed or clicked in the app for 2 minutes;
  - about 30 seconds before installing, a notice in the sidebar (never a dialog) says "Updating to
    X.Y.Z", with **Not now** (wait for the next quiet moment at least an hour later) and **Install
    now**. Anything the user does during the countdown stops it until the next quiet moment;
  - after the relaunch everything comes back as after a quit (AG-7, AG-22, R-3): windows, tabs,
    panes and their folders, and agent sessions in their panes, live ones live with the same
    conversation and flags (an agent the user typed in a pane included);
  - `<cli> update --now` installs at once (asking first, with `--force`, before cutting running
    turns off, AG-22); `<cli> update --status` says what is pending and why it isn't quiet yet (which
    pane or session); `<cli> update --rollback` installs the previously installed version again
    (its verified zip is kept when a new one installs), and the version gone back from doesn't
    install by itself again. An install that fails doesn't install by itself again either;
  - a config setting (`auto-update = check`) turns automatic installing off: then a background check
    asks the user before downloading or installing anything, with a question that never takes focus
    or blocks work and stays available until answered; the menu item and `<cli> update` count as a
    yes; the update installs when the app quits, or when the user asks;
  - it verifies what it downloads (signature, hash, bundle id, version, code signature), and a helper
    swaps the bundle and puts the old one back if that fails;
  - an isolated or test instance (its own state directory) never updates the user's installed app;
  - an older build updates to a newer one end to end;
  - *Warp parity, 2026-11-05:* after an update installs, the relaunched app says once, inside the
    window, "Umi updated to X.Y.Z" with that release's notes from the feed (Warp's "Warp updated!"
    toast); it stays until ⌃⌘U dismisses it, and a failed install shows nothing.

  `<cli> update --check` prints the installed and the newest version. Publishing a new version from
  the development Mac is one command.
- **I-5 [W]** One-line install. On another Mac, one command pasted into Terminal installs the latest
  release, with no Gatekeeper prompt and nothing to install first. The release repository's README
  gives the command.

## L. Windows, tabs and panes

All of these work from the CLI (see CLI.md), and the common ones also from keyboard shortcuts and
the menu.

- **L-1 [A]** Create windows, tabs and split panes, optionally in a given working directory or
  running a given command, and optionally named.
- **L-2 [A]** Focus, close, rename (and clear the name of), color, pin and unpin tabs. Pinned tabs
  come first in their window, in pin order, and moving a tab never mixes the pinned and unpinned
  groups.
- **L-3 [A]** Focus, close, rename, zoom (and unzoom), resize and swap panes.
- **L-4 [A]** Selectors: panes, tabs and windows can be named by id or unique id prefix, by user-given
  name, by `.` (the focused one) and by `#N` index (tabs and windows). Ambiguous or unknown selectors
  fail with a clear message and a non-zero exit, and change nothing.
- **L-5 [A]** `--worktree NAME` on tab, split and window creation starts the new pane in a git
  worktree. That's an existing worktree directory, or a worktree with that branch or folder name, or a
  new worktree created next to the repository on a new branch NAME. It works even when git hooks
  print noise.
- **L-6 [A]** Relative `--cwd` values are relative to where the CLI ran.
- **L-7 [A]** `ls` shows every window, tab and pane with their ids, names, working directories,
  focus, zoom and pins.
- **L-8 [A]** Commands that create things accept a "don't focus it" option. The user's selected tab
  and focused pane are then unchanged, at every moment, not just eventually. If the app is in the
  background, it stays in the background: the app that was in front stays in front.
- **L-9 [A+W]** Keyboard shortcuts:
  - ⌘B toggles the sidebar; ⇧⌘E and ⌃1 show the project explorer; ⇧⌘> shows or hides its dotfiles;
    ⇧⌘F and ⌃3 show global search (S-2);
  - ⌘O opens a file (quick search, L-16; File ▸ Open File… keeps the Open panel);
  - ⇧⌘M toggles the Markdown preview and source;
  - ⌘P opens the command palette (L-14); ⇧⌘P lists panes (L-15); ⌘, opens the config file (L-17);
    ⌘/ opens the shortcuts page (L-17);
  - ⇧⌘[ goes back to the tab visited before; ⇧⌘] shows the next tab in sidebar order; ⌃Tab and
    ⌃⇧Tab cycle to the next and previous tab; ⌘1–⌘8 show that tab and ⌘9 the last one (L-11);
  - ⌃⇧← / ⌃⇧→ move the tab up or down (L-13);
  - ⌃⌘T / ⌃⌘N move the pane to a new tab or window;
  - ⌃⌘← / ⌃⌘→ move the pane into the previous or next tab;
  - ⌃⇧⌘N moves the tab to a new window;
  - ⌃⌘P pins or unpins the tab;
  - ⌃⌘R / ⌃⇧⌘R rename the tab or pane;
  - ⌃⌘J goes to the next session that needs the user, and ⌃⌘K goes back (L-12);
  - ⇧⌘T reopens the last closed pane, tab or window (L-20);
  - ⌃⌘O takes over the focused pane's session, and ⌃⌘W removes the session from its pane, where
    it keeps running (AG-6, AG-8);
  - (Warp parity, 2026-11-05) ⌥⌘I and ⌥⇧⌘I synchronize input and stop it (L-32); ⌘= ⌘- ⌘0 zoom
    the interface and ⌥⇧> ⌥⇧< change the terminals' font size (L-33).
  - ⇧⌘U opens or closes the notifications inbox, and ⌃⌘U dismisses the toasts and the update note
    (AG-24, I-4; Warp parity, 2026-11-05).

  Each is a menu item, and the command palette lists them. `<cli> shortcuts` changes them (L-17).

- **L-10 [A+W]** Shortcuts work from anywhere: with keyboard focus in a terminal, the editor (source
  or preview), the sidebar (its rename field and the file tree), a session's read-only view in a
  pane or the palette. A terminal never takes one of these keys first.

- **L-11 [A+W]** Moving between tabs:
  - ⇧⌘[ (`<cli> tab back`) goes to the tab the user was in before, in any window. Pressed again,
    it goes to the tab before that, and so on, like a browser's Back over the tabs visited. Tabs
    closed since are skipped. Visiting a tab any other way ends the walk.
  - ⇧⌘] (`<cli> tab next`) goes to the next tab in sidebar order, ⌃Tab too, and ⌃⇧Tab (`<cli> tab
    prev`) to the previous one; both wrap around. Pressed several times in a row they walk down
    (or up) the list, which stays as it is (S-7).
  - ⌘1–⌘8 show the Nth tab of the window and ⌘9 its last tab.
  - Showing another tab fades its panes in from the window's background (about 140 ms, none with
    Reduce Motion), so a tab switch looks different from a window switch, which stays as macOS
    draws it. The fade never holds up typing or clicks.

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

  *Warp parity, 2026-11-05.* It is one palette, as Warp's: unfiltered it searches actions, managed
  sessions (Warp's conversations), panes and the files of L-16 together, at most 250 results. A
  query starting with `actions:`, `sessions:`, `files:`, `conversations:` or `tabs:` filters it to
  that source; the prefix leaves the query and shows before it as an italic filter word, and
  Backspace in the empty query removes the filter. A query that begins a filter word shows the
  rest of the word dimmed after it, and Tab applies that filter ("fi", Tab: `files:`). ⇧⌘P and ⌘O
  open it filtered to sessions and files. Empty and unfiltered it selects nothing, indexes no
  files, and shows filter chips (files, actions, sessions, conversations; each but actions with
  its filter's icon), Recent (the last three rows chosen from it, files opened from it included)
  and Suggested (Keyboard Shortcuts, Settings…, Show Project Explorer; a row can be in both); ↓
  selects the first, ↑ from the first selects nothing again, and the arrows stop at the ends. Its look is Warp's: 640 px wide, at most
  464 tall, 117 px below the window's top, on Warp's `surface_2` (the background with 10% of the
  foreground) with a 1 px border and radius 8; a magnifier (or the filter word) before the query in
  13 pt; one-line 28 px rows with a bold title whose matched characters are brighter, shortcuts in
  key boxes; the selected row in the accent at 90%, a hovered one at 20%; "No results found" when
  nothing matches.

- **L-15 [A+W]** ⇧⌘P lists every pane of every window, the most recently used first, each with its
  own title: its name, else its agent session's title, else what its program set as its title,
  else its folder; then its folder and branch, what it runs (or last ran) and its tab. The pane the
  palette was opened from is marked Current. Choosing a pane focuses it, its tab and its window.
  *Warp parity, 2026-11-05:* rows as Warp's navigation palette, 70 px with two lines: the title
  with folder and branch chips, then the command in monospace, "Running..." or "Completed", the
  tab, and a monospace "Current" pill.

- **L-16 [A+W]** ⌘O opens a quick file search over the focused pane's git repository: its tracked
  files and the untracked files git doesn't ignore (outside a repository: the files of that
  folder). Fuzzy matching on the path, the file name counting most; files opened recently first,
  then changed ones. `path:line` opens the file at that line. Enter opens the file in the tab's
  editor; a "Browse…" entry opens the Open panel. *Warp parity, 2026-11-05:* rows are one line: a
  file-type icon, the name, then its folder cut at the start, matched characters bold. When no
  file matches, a "Create a file named NAME…" entry makes that file (and its folders) in the
  pane's folder and opens it; a NAME starting with `~/` or `/` names the place itself.

- **L-17 [A]** ⌘, (Settings…) opens the user's config file (`~/.config/<cli>/config`) in the app's
  editor, as Ghostty opens its own config file; a missing one is made, empty, first. `<cli>
  shortcuts` lists every Umi menu shortcut and every Ghostty keybinding, and sets, clears or resets
  each, or all at once. A change applies at once, without a restart, and is kept across restarts in
  the app's state directory (`shortcuts.json`, and `keybindings.conf` for Ghostty keybindings,
  loaded after the user's config file); it never changes the user's config files. A key
  given to one shortcut is taken from any other that had it, and the command says which.
  *Warp parity, 2026-11-05:* ⌘/ (Help ▸ Keyboard Shortcuts) opens and closes a shortcuts page as
  Warp's keybindings panel: 361 px at the window's right, read-only, listing what `<cli>
  shortcuts` lists (every shortcut in effect), by menu and then "Terminal" for Ghostty's
  keybindings, searchable by name or keys as Warp's: modifier words or symbols in any order and
  at most one key ("cmd shift p", "shift cmd p", "⇧⌘P"), matching shortcuts that hold those
  modifiers and exactly that key, Ghostty's keybindings included; Esc closes it. With focus in the editor's
  source, ⌘/ is the editor's key and the page stays closed.

- **L-18 [A]** After a pane closes (⌘W, `pane close`, its program exiting), focus goes to the pane
  of that tab the user used most recently, as in Warp; tree order only when there's no history.
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
  - dragging a divider leaves it where it's dropped, and that divider now sizes its panes by hand.
    A pane between dividers placed by hand (or one such divider and the end of its row or
    column) keeps its size when another divider is dragged; only the panes not sized by hand
    grow or shrink, sharing equally the stretch between the dragged divider and the nearest
    divider placed by hand (or the row's end) on each side. In a row of three, dragging the first
    divider gives the first pane the width dragged to and the other two half the rest each;
    dragging the second divider then leaves the first pane as it is. In a row of four, dragging
    the first divider to 28% and the last to 78% gives 28/25/25/22. A pane split the other way (a
    column in a row) counts as one pane of the row and keeps its inside;
  - file panes (E-1) are panes like any other;
  - keyboard resizes (Ghostty's `resize_split`) and `pane resize` still move one pane's edge,
    changing only the two panes beside it, and that divider counts as placed by hand;
  - splits and closes share space as above and keep the other dividers placed by hand (the
    dividers beside the new or closed pane are not). Double-clicking a divider gives its row (or
    column) equal shares, leaves the rest of the tab alone, and forgets which of its dividers
    were placed by hand; ⌃⌘= and `tab equalize` equalize the whole tab and forget them all;
  - `split --ratio R` gives the new pane R of its row (or column); the others keep their
    proportions;
  - (Warp parity, 2026-11-05) no pane gets smaller than 190 points along the axis a divider
    moves, Warp's minimum: a dragged divider stops where the next step would take a pane below
    it, and a keyboard resize or `pane resize` that would is refused (the CLI says so). A pane
    already smaller (a small window) may grow;
  - (Warp parity, 2026-11-05) dividers are Warp's: a 1-point line at the foreground's 15%
    (`#262626` on Umi's dark theme) that can be grabbed 4 points either side (9 in all).

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

- **L-21 [A]** Launch configurations, as in Warp (Warp parity, 2026-11-05). Saved sets of windows,
  tabs and split panes are YAML files in `~/.config/umi/launch_configurations`
  (`$XDG_CONFIG_HOME/umi/…`), in Warp's format: `name`, `active_window_index`, `windows` with
  `active_tab_index` and `tabs`; a tab's `title`, `color` and `layout`; a layout is a pane (`cwd`,
  `commands` as `- exec: COMMAND`, `is_focused`) or a split (`split_direction: horizontal` for side
  by side, `vertical` for one above the other, and its `panes`, any number, in equal shares). A
  tab's own `commands` go to its focused pane, else its first. Colors are Umi's tab colors, or
  Warp's `magenta`, `cyan`, `black` and `white` (purple, teal, graphite, graphite). Saving writes
  Warp's names where Warp has the color (purple as `magenta`, teal as `cyan`, graphite as `white`),
  so Warp can read the file; pink and orange keep Umi's names. Warp requires `name`;
  Umi also reads a file without one and names it after the file (`my_work.yaml` → "My Work", the
  rule Warp uses for the names it saves under), and always writes `name`. A file can hold several
  configurations as YAML documents separated by `---`, as in Warp; each is listed and opened on its
  own.
  - File ▸ Launch Configurations lists them by name, as Warp's File menu does (choosing one opens
    it), then Open Launch Configuration… and Save New Launch Configuration….
  - ⌃⌘L (File ▸ Launch Configurations ▸ Open Launch Configuration…) lists them by name in the palette, with how many
    windows and tabs each opens; Return opens the chosen one: each window as a new window, the
    active one in front, with its tabs' titles, colors and selected tab, its panes in their folders
    and the focused pane focused. Each pane's commands are typed into its shell as it starts.
  - The command palette (⌘P) lists them by name too, as Warp's does; Return opens the chosen one.
  - File ▸ Launch Configurations ▸ Save New Launch Configuration… asks for a file name (`work` saves `work.yaml`) and saves
    every window: tabs with their names and colors, terminal panes with their folders, the focused
    pane and selected tab. File and web panes are left out, as Warp leaves out panes that aren't
    terminals. A name already used fails and says so, keeping the file.
  - A sidebar row's menu has "Save as New Config" where Warp has it (after the close items, before
    the colors): it saves that tab as `my_tab_config.yaml` (`my_tab_config_1.yaml`, … when taken)
    and opens the file in the editor.
  - `<cli> layout ls`, `layout save NAME [--replace]` and `layout open NAME` do the same from the
    CLI (CLI.md). A file that can't be read is listed with the reason and its line; opening it
    fails with them and opens nothing.
- **L-31 [A]** (Warp parity, 2026-11-05) The terminal's right-click menu has Warp's items, in Warp's
  order, each showing its key: Copy (when text is selected), Paste (disabled with nothing to
  paste) and Clear (⌘K) (neither when text is selected or a program's full-screen view, as vim's
  or less's, shows), Split Pane Right, Left, Down and Up, and, in a split, Maximize Pane (Minimize
  Pane when it is maximized; ⇧⌘↩) and Close Pane (⌘W). They act on the pane right-clicked, focused
  or not. Ghostty's Reset Terminal, Toggle Terminal Inspector, Terminal Read-only, Change Tab
  Title… and Change Terminal Title… follow.
- **L-32 [A]** (Warp parity, 2026-11-05) Synchronized input, as Warp's. ⌥⌘I (Window ▸ Synchronize
  Input ▸ Toggle Synchronizing All Panes in Current Tab) syncs the current tab, or stops syncing
  it; Toggle Synchronizing All Panes in All Tabs syncs every tab of the window, new ones included;
  ⌥⇧⌘I (Stop Synchronizing Any Panes) stops all of it in the window. Each window keeps its own.
  What is typed or pasted into a pane of a synced tab is typed into every terminal pane of every
  synced tab in that window; ⌘ shortcuts and text still being composed by an input method stay
  in the pane. A paste that needs confirming (Ghostty's paste protection) is confirmed once, in
  the pane it was pasted into, and then goes to every synced pane. Panes showing a file, a page
  or a session's read-only view don't take it. As in Warp, ⌥⌘I in a window syncing every tab
  leaves the other tabs synced and this one not, and syncing every tab one by one is the same as
  syncing all of them; ⌥⌘I in a window syncing nothing syncs only that tab, so a tab opened later
  isn't synced, even when it was the window's only one. A synced tab's sidebar row shows Warp's
  link mark (#4A93FF). The terminal inspector moves from ⌥⌘I to ⌃⌥⌘I.
- **L-33 [A]** (Warp parity, 2026-11-05) Zoom, as Warp's. ⌘= and ⌘- (View ▸ Zoom In, Zoom Out) step
  through Warp's levels (50, 60, 70, 80, 90, 100, 110, 125, 150, 175, 200, 225, 250, 300 and 350%),
  and ⌘0 (Actual Size) goes back to 100%. The zoom scales the sidebar, the palette, the editor's
  text, the Markdown preview and the terminals' text in every window. ⌥⇧> and ⌥⇧< (Increase and
  Decrease Font Size) change the terminals' font size by a point, between 5 and 25, and Reset
  Font Size goes back to the config's `font-size`; the terminals show that size times the zoom.
  New panes get it too. Both are kept across restarts.

## M. Moving live sessions

A "live session" is a pane with a running program, its scrollback and its state.

- **M-1 [A]** A pane can be moved next to another pane in the same tab, into another tab, into another
  window, into a new tab or into a new window. The program keeps running uninterrupted and the
  scrollback is preserved. The source tab or window closes if it becomes empty.
- **M-2 [A]** A tab, with all its panes, can be moved to another window (at a position) or to a new
  window, and reordered within its window. Its programs keep running.
- **M-3 [A]** Moves can be undone and redone. After undo, each tab's focused pane is what it was.
- **M-4 [W]** Panes can be dragged onto other panes, including in other windows. Tabs can be dragged
  in the sidebar to reorder them and onto another window's sidebar. Also, as in Warp:
  - a pane dropped on a tab's row moves into that tab (beside its focused pane, as ⌃⌘←/→ and
    `pane move --tab` place it); dropped between rows (the top or bottom quarter of a row) or below
    the rows, it becomes a new tab at that position. A thin accent line shows where it lands;
  - a tab dropped on the top or bottom half of a row lands before or after it, with the same line;
  - a tab dragged out of its window and dropped where nothing takes it becomes a window of its own
    at the drop point. Dropped back over its own window, nothing changes.

  Programs keep running through all of these (M-1, M-2).
- **M-5 [A]** A pane moved to a new window gets a window large enough to keep its columns and rows,
  and a window never ends up unusably small.
- **M-6 [A]** A new window created by moving is a separate window. It isn't merged into an existing
  window's tabs.
- **M-7 [A+W]** Stacks, in the user's words (2026-11-04): "if I drag a session on top of another, they
  should come to occupy the same pane space and be accessible through the cmd [] shortcuts + a small
  tab thing at the top similarly to what we currently do for files". A pane dropped on the middle of
  another pane (the middle third each way; "Stack here" shows) joins it in its place, on show and
  focused; its old place closes. Any panes can stack: terminals, file panes, agent sessions.
  - A strip along the top of the place names each member; clicking one shows it, its ✕ closes it.
  - ⌘[ and ⌘] show the previous and next member of the focused pane's stack. In a pane that isn't
    stacked they go to the previous and next pane, as before.
  - Members not on show keep running. Focusing one (`pane focus`, the palette, `jump`) shows it.
  - Closing the member on show, or moving it away, shows the next member in its place; a member
    whose program ends leaves its stack; a stack left with one pane is an ordinary pane again.
  - `ls` lists every member (M-7 fields in CLI.md); stacks survive a restart and undo.

## T. Terminal input and output, and events

- **T-1 [A]** Send text to a pane (optionally pressing Enter), including text piped on stdin. Send
  named keys (enter, esc, tab, arrows, ctrl+c, …).
- **T-2 [A]** Read a pane's screen or its full scrollback, or the last N lines.
- **T-3 [A]** Wait until a pane's output matches a pattern, or has been idle for N seconds, with a
  timeout. A timeout exits 124. A pane that closes while waited on ends the wait promptly with an
  error.
- **T-4 [A]** A stream of layout events (panes and tabs created, closed, renamed, moved, focused) can
  be followed as JSON lines, optionally filtered by kind or by pane. A consumer that stops reading
  never stalls the app: other commands keep working, and the stalled consumer is eventually
  disconnected.
- **T-5 [A]** Many concurrent CLI invocations all get correct answers.
- **T-6 [A]** Show a desktop notification from a pane.
- **T-7 [A]** The app can capture an image of a window, including terminal contents, through
  `<cli> screenshot`.

## S. Sidebar and look

- **S-1 [W]** No visible containers or borders around the content, Warp-like: the chrome blends into
  the terminal background. The window shows no native tab bar and no titlebar icons on the upper
  right. As in Warp, a 1 px line at foreground 10% separates the sidebar from the panes (Warp
  parity, 2026-11-05).
- **S-2 [A+W]** A left sidebar, full height, toggled with ⌘B. It has three modes: Tabs, Files and
  Search. It has no "agents" section, no "no agents running" text and no "new agent" button.
  Warp parity, 2026-11-05: each window shows or hides its own sidebar, at once (no slide), as Warp's
  left panel; ⌘\ (Warp's left-panel key) toggles it too. A new window starts as the window last
  toggled. `<cli> sidebar on|off|toggle` act on the given window, else the caller's, else the
  current one. Its list scrolls under Warp's 4 pt overlay scrollbar.
  - Files is the project explorer (Warp parity, 2026-11-05): the git root of the focused pane's
    folder (else that folder) as a tree whose root is an ordinary collapsible row. It follows the
    files on disk as they change, with no refresh. Rows as in Warp: 14 pt names, 16 pt indent per
    level, about 25 pt tall, 16 pt chevrons and colored file-type icons; folders first, dotfiles
    first within each group. The selected row is the foreground at 20% behind full-color text;
    hover is 10%. Dotfiles are shown and ⇧⌘> hides or shows them; entries git ignores are italic and
    lighter; `.git` and `.DS_Store` are never shown. When the focused pane shows a file, the tree
    opens its folders, selects it and scrolls to it, stopping (with nothing selected) at a folder
    the user closed. With no pane folder it says "Project explorer
    unavailable" with Warp's explanation.
  - Explorer keys: ⇧⌘E and ⌃1 show Files with keyboard focus in the tree (pressed again: Tabs, and
    focus back in the pane). In the tree ↑↓ select, → expands a folder, ← collapses it or goes to
    the parent folder, Enter opens a file (non-binary files in the editor, others with their
    default app) or opens or closes a folder, Esc goes back to the pane.
  - Explorer right-click menu, Warp's items with Umi's: on a folder New File, cd to Directory
    (replaces what is typed at the prompt of the tab's terminal with `cd` and the folder, not run;
    off while a program runs there), Open in New Tab (a terminal there); on a file Open
    in New Pane (the editor in a pane beside the focused pane), Open in New Tab (a tab of its own),
    Open with Default App; on both Reveal in Finder,
    Rename and Delete (not on the root), Insert Path in Terminal, Copy Path, Copy Relative Path
    (from the root). New File and Rename edit the name in the row: Enter commits, Esc or an empty
    name cancels; a new file opens in the editor. Delete moves the item to the Trash without asking
    and closes the panes showing it (or a file in it).
  - Search is global search (Warp parity, 2026-11-05). ⇧⌘F shows it with focus in the query, its
    text selected; ⌃3 shows or hides it. It searches the files of the focused pane's repository
    (the explorer's root), leaving out what git ignores, 300 ms after typing stops: literal and
    case-insensitive unless its Regex (Perl-style: `\d`, `\b`, lookarounds) or Case toggle is on,
    at most 20,000 matching lines (with Warp's note when
    capped). Results are grouped by file (name, folder, match count), then each matching
    line with the match highlighted, under "N results in M files" ("Searching…", "No results
    found. Review your gitignore files."). ↓ moves from the query into the results and ↑ on the
    first result goes back; ← / → fold and unfold a file; Enter opens the file in the editor with
    the cursor on the match (its line and column); Esc goes back to the pane. ⇧⌘F no longer ends
    a terminal search; Esc still does. A bad regex shows git's error under the query. Outside a
    git repository it searches the folder's files.
- **S-3 [W]** Tabs mode lists the window's tabs, grouped by tab, with pinned tabs first.
  Each row has two lines:
  - Line 1: the tab's folder (its focused pane's), or the name the user gave the tab. Then the git
    branch, a linked worktree shown differently from a normal checkout; a pane count when split;
    and close and pin affordances on hover.
  - Line 2: the title of the tab's agent session, when it has one (a session Umi started, or a
    `claude`/`codex` typed in the pane and reported by Umi's plugin, AG-18). Otherwise what the
    focused pane is doing: the running command or the last one it ran; else the folder's path.
  - Rows look like Warp's vertical tabs (Warp parity, 2026-11-05): line 1 at 12 pt regular, 90% ink,
    selected or not; line 2 at 10 pt, 60%; 1 pt between them. The icon is a 24 pt circle filled at
    10% with a terminal glyph at 90% in its middle 16 pt (Warp's 16 px icon box; the glyph drawn in
    it is about 12 pt across, as Warp's). Rows are 8 pt inside, 8 pt from icon to text, radius 4,
    4 pt apart; the list is 8 pt in from the sides and bottom. The selected row is filled at 10%
    with a 1 px border at 15%; a hovered row at 5%; both over the sidebar's 5%. A tab's color tints
    its row at 15%, and 50% when selected or hovered. A pinned tab shows a 16 pt diagonal pin 6 pt
    inside its row's top-right corner, hidden on hover; no line under the pinned tabs. When the
    focused pane's last command failed (an exit status other than 0, 130 or 141), a 12 pt red
    triangle (#BC362A) comes before the title. A running command has no mark of its own. A tab
    whose pane is zoomed shows "Maximized" (an icon) on line 1. While ⌘ is held for 750 ms (other
    modifiers held with it or added later don't hide them or restart the delay), each row shows
    the key that selects it at 12 pt, 60%: ⌘1–⌘8 for the first eight tabs, ⌘9 for the last.
  - The header (Warp's control bar) is 4 pt above and below, 8 pt at the sides, 4 pt between
    items: "Search tabs..." (S-13; Tabs mode), the Tabs, Files and Search buttons, and + (24 pt
    high, radius 4).
  - A tab with an agent session shows the agent's mark (Claude or Codex), small and monochrome, in
    the 24 pt circle instead of the terminal glyph. When a session finished and the user hasn't looked at it yet, or it needs the user,
    the mark's status badge says so (below). Looking at the pane (it has focus in the front window while the
    app is active, by a tab switch, a pane focus, or switching windows or apps) clears it; a session
    that finishes while the user looks at it leaves no mark. Colors and hints stay subtle. No desktop
    notifications. The Dock badge counts the sessions that need the user.
  - *Warp parity, 2026-11-05.* The mark wears Warp's status badge, 57% of the icon's size, its
    bottom-right corner 5% of the icon's size inside the icon's, in a ring of the terminal's
    background, in Warp's default Dark colors: working (magenta clock),
    finished and not seen yet (green check), needs the user (yellow stop), error (red triangle),
    stopped (grey stop). The mark itself stays monochrome; the badge carries the color. A finish
    counts as seen when the user looks at any pane of its tab as it finishes (Warp's rule), and the
    agent starting a new turn clears the mark. The agents' own desktop notifications (OSC 9 and
    777, which Claude Code and Codex send) are dropped while an agent session's own interface runs
    in the pane's terminal (one the product started or one its plugin reports, AG-18) and the
    session isn't stopped; other programs' notifications, including the shell's after the agent
    exits, are Ghostty's as before.
- **S-4 [A+W]** Rows can be clicked to select, double-clicked to rename, dragged to reorder
  (M-4), and right-clicked for Warp's menu, with Warp's labels and order (Warp parity, 2026-11-05):
  Pin tab (Unpin tab); New group with tab, Move to group ▸, Remove from group (S-14); Copy branch,
  Copy tab title, Copy working directory, Copy pull request link
  (the branch's pull request, found with `gh`); Rename tab, Reset tab name, Rename active pane,
  Reset active pane name (the tab's focused pane), Move Tab Down, Move Tab Up (within the pinned or
  unpinned group and, for a tab in a tab group, within that group; a tab next to another group
  moves past the whole group in one step, as Warp's); Close tab, Close other tabs, Close Tabs Below; Save as New Config (L-21); a row of color dots: "Default (no
  color)" and Warp's six tab colors, the theme's ANSI red, green, yellow, blue, magenta and cyan
  (picking the tab's color again clears it); then Umi's Move Tab to New Window, Move Tab to Window ▸.
  Sections are separated by lines; an item that can't apply (nothing to reset or copy, no pull
  request, a move or close past the end of its group) is left out, as in Warp. The pull request is
  looked up as soon as the row shows the branch, so the item is there at the first right-click. Renaming a tab or a pane (from
  the menu, a double-click, ⌃⌘R or ⌃⇧⌘R) happens in place in the row: Return keeps the name (empty
  goes back to the default), Esc leaves it as it was; the sidebar shows itself for it.
- **S-5 [W]** The theme's chrome text stays readable on light and dark backgrounds. The user's own
  config file (`~/.config/<cli>/config`, Ghostty's settings) and theme override the product's
  defaults. The app never reads Ghostty's own config files.
  The default colors are Warp's built-in Dark theme's: background `#050505`, white text, the cyan
  accent `#19AAD8` as the cursor and its 16 terminal colors, with the chrome on top of it, as in
  Warp. (Until 2026-11-05 this said `#000000`, which came from the themes repository's YAML, not
  the theme built into Warp; REQUESTS.md.)
  Warp parity, 2026-11-05: the terminal itself looks like Warp's by default (all overridable in the
  config file):
  - selection: Warp's blue `rgba(118,167,250,0.40)` laid over the selected cells, which keep their
    text colors;
  - minimum contrast: text in the default color or a named color (0–15) is raised to 4.5:1 against
    its background; text a program colors from the 256-color table or with RGB keeps its color;
  - font: Hack (bundled) at 13 points, rows 1.2× the font size, no ligatures;
  - padding: 16 points left and right, 20 below the last row, what's left over above the first row;
    full-screen programs (the alternate screen) get the whole pane, without padding: their grid
    starts at the pane's top left corner; a reset (`reset`, Reset Terminal) that leaves the alternate
    screen gives the shell its padding back;
  - cursor: a bar 3 points wide with fully rounded ends, a row tall, blinking every 500 ms;
  - scrollbar: a thumb 8 points wide with round ends and no track, 2 points in from the pane's
    right edge, the text color at 40%, 90% while the pointer is on it or it is dragged;
  - bell: silent: no sound, no Dock bounce or badge, no mark in the title.
- **S-6 [W]** The "running/last command" line updates for commands that finish instantly.
- **S-7 [A+W]** The sidebar's order, in the user's words (2026-10-27): "the standard behavior from warp
  that doesn't switch tab order depending on recency". Tabs stay where they are until the user moves
  them:
  - selecting a tab never moves it, whatever selects it: a click, ⌘1–9, ⇧⌘[ / ⇧⌘], ⌃Tab, `<cli> tab
    focus` (or `next`, `prev`, `back`), a pane focus, `jump` and `jump back`, a notification, reopen;
  - an agent finishing its turn (or asking for something) never moves its tab; the tab shows its
    mark (S-3);
  - tabs move only when the user moves them: dragging (M-4), `<cli> tab move`, Move Tab Up/Down
    (L-13), `<cli> tab new --index`, and pinning and unpinning. Pinned tabs come first, in pin order:
    pinning puts a tab at the end of the pinned tabs and unpinning at the top of the others, as in
    Warp;
  - a new tab the user goes to (⌘T, the sidebar's +, `<cli> tab new`, a session started with
    `--focus`) opens right after the current tab, below the pinned tabs, as in Warp (Ghostty's
    `window-new-tab-position = end` puts it last instead). A tab opened in the background
    (`--no-focus`, a session shown without `--focus`) goes last, so no tab shifts while the user isn't
    looking. A pane moved to a new tab gets one right after its own tab.

  This is the window's real tab order: `ls`, `#N` selectors and ⌘1–9 follow it. (Until 0.6.0 the
  current tab moved to the top and tabs whose agent stopped moved to just below it; REQUESTS.md.)
- **S-8 [A+W]** Each window's sidebar can be made wider or narrower by dragging its edge (Warp's
  5 pt strip inside the edge), between 180 points and the smaller of 600 points and half the
  window. It starts at Warp's 248 points (Warp parity, 2026-11-05). The width is per window, saved and
  restored with the layout; a new window starts at the width last chosen. Double-clicking the edge
  goes back to the default. `<cli> sidebar width [N]` shows or sets it; `sidebar status` still
  answers `visible` and `mode` (and now the window's `width`).

- **S-13 [A+W]** Search tabs (Warp parity, 2026-11-05), as Warp's vertical tabs: a "Search tabs..."
  field at the top of the sidebar's Tabs mode (a 12 pt magnifying glass, 24 pt high). A query lists
  only the tabs whose title, folder, branch, command or agent session title contain it (any case);
  with none, "No tabs match your search." (12 pt, 60%). While the window's sidebar has a query, ⇧⌘[
  and ⇧⌘] (previous and next) and ⌃Tab and ⌃⇧Tab go through the matching tabs only, wrapping
  around (also while the sidebar is hidden, as Warp's closed panel; not while it shows Files, which
  has no field to see or clear the query in). ⌥⌘F shows the sidebar in Tabs mode and puts the
  cursor in the field (except in a file pane, where ⌥⌘F is Find and Replace, E-22); Esc there
  clears the query and gives the keyboard back to the pane.
- **S-14 [A+W]** Tab groups (Warp parity, 2026-11-05), as Warp's: a row's menu has "New group with
  tab" (left out when the tab is its group's only tab), "Move to group ▸" (when another group
  exists) and "Remove from group" (when in one), after Pin tab. A new group holds just that tab,
  is called "New Group" until named, and its name is typed in place right away. The sidebar shows
  a group where its first tab is, as one rounded box (radius 4): its header (a 24 pt icon, a
  chevron while open; the name at 12 pt over "N tabs" at 10 pt; 8 pt inside, radius 4), then its
  tabs unless it is collapsed, 4 pt apart, 12 pt in from the box's left edge and 4 pt from its
  right, with 4 pt of box below them. The box takes the group's color at 15%, 25% while hovered
  or holding the selected tab; a group without a color, 5% then. Tabs keep only their own color.
  A click on the header collapses or expands it, a double-click only renames it, and its
  right-click menu has Ungroup tabs, New tab in group; Rename; Close all tabs in group, Close
  other tabs, Close tabs above, Close tabs below (each when there are such tabs); the color dots.
  A group's tabs stay next to each other: a tab moved away from them comes back to them, and a
  tab pinned leaves its group; an empty group goes. A tab taken out of its window (moved to
  another window, closed) leaves its group; undoing that, or reopening the tab or its window,
  brings it back into the group, and brings the group back if it went. A search for a group's
  name lists all its tabs. From the keyboard, the Window menu (and the palette) has New Group
  with Tab, Collapse or Expand Tab Group, Rename Tab Group, Move Tab to Group ▸ (the window's
  other groups; "Move Tab to Group: NAME" in the palette), Remove Tab from Group, New Tab in Group
  and Ungroup Tabs for the current tab. Groups are saved and restored with the layout; `ls` gives
  a grouped tab's `group` (its name).

### Warp's look for terminals

The user's request, their Warp screenshot (`reference/warp-blocks.png`) and their choice: an
imitation that keeps the shell underneath. zsh keeps editing the command line as it does today; Umi
changes how the terminal looks. Colors and spacing come from Warp's own source.

- **S-9 [A+W]** At the bottom. The prompt sits at the bottom of the pane from the start, and output
  builds upward above it, as in Warp. With more than a screenful the pane scrolls as usual. It stays at
  the bottom after `clear` and ⌘K. What the shell shows below the command line (a completion list) is
  shown.
- **S-10 [A+W]** Blocks. Each command and its output form a block, as in Warp:
  - a header with the folder it ran in and how long it took, in Warp's format (`(0.041s)`,
    `(1m 8.92s)`, `(3h 4m 12s)`; while it runs, the whole seconds so far, nothing in its first
    second). Warp parity, 2026-11-05: the header is Warp's whole line: the conda and Python
    environments (`(base) (venv) `), `user@host:` over SSH, the folder (in full when it fits) and
    ` git:(branch)` (the commit when no branch is checked out). These names are shown as text and
    never run as shell code, also with zsh's `prompt_subst` on;
  - the command, in bold;
  - its output;
  - a thin line and some space between blocks.

  A command that exits with an error is marked as Warp marks it: the theme's red at 10% over the block
  and a 5-point red bar along the pane's left edge. As in Warp (Warp parity, 2026-11-05), exit codes
  130 (stopped with Ctrl-C) and 141 (SIGPIPE, as when a pager quits early) count as success. Not shown: the "Lines: … Size: …" line of the
  user's Warp build, Warp's input editor, and block selection, copying and other block actions.
- **S-11 [A+W]** The folder box. At the prompt, a small rounded box with a folder icon and the current
  folder (`~` for the home folder), as at the bottom of the screenshot. Warp parity, 2026-11-05: the
  box shows the folder alone (not the header's environments or git branch), in bold (Warp's is
  semibold), cut from the left to its last 39 characters after `…` when longer than 40.
- **S-12 [A+W]** Where it applies:
  - only inside Umi: other terminals, and zsh started anywhere else, look as they did;
  - zsh only: other shells keep the usual look;
  - full-screen programs (the alternate screen: vim, an agent's full-screen interface) take the whole
    pane as before, with no block decorations, and (Warp parity, 2026-11-05) without padding;
  - programs and agents that read a pane (`read`, `wait --pattern`) see what the shell and programs
    printed (the folder line and the command line as the shell printed them), never what Umi draws;
  - `shell-integration-features = no-umi-blocks` in the user's config file turns it off.

## E. Editor and Markdown

- **E-1 [A+W]** Opening a Markdown or text file shows it in a pane of its own: a file pane, which
  splits, moves, stacks (M-7), closes and is restored like a terminal pane, with the file's name, the
  preview/source control and a close button along its top. Markdown opens rendered (headings, lists, task lists, tables, code blocks, links,
  images); JSON opens as a tree whose objects and arrays fold, keys in file order; CSV and TSV open
  as a table (row numbers, a header that stays in view, numbers right-aligned); other text opens as
  source.
- **E-2 [A+W]** Preview and source can be toggled with ⇧⌘M, with a visible control, and from the CLI.
  Warp parity (2026-11-05): the control says "Rendered / Raw", as Warp's does, and ⌘E (Warp's key)
  toggles too while a file pane with both views has focus; in a terminal ⌘E stays Ghostty's "Use
  Selection for Find".
- **E-3 [A+W]** Edits can be saved with ⌘S. Closing a file with unsaved changes asks first. Closing a
  tab or quitting never silently loses edits: they are saved, or a recovery copy is kept.
- **E-4 [A+W]** If the file changes on disk:
  - an unmodified document reloads;
  - a modified one shows that the disk changed and offers to reload; in Warp's words (Warp parity,
    2026-11-05): "This file has saved changes that are not reflected here.", with "Discard this
    version" (drop the edits, take the disk's file) and "Overwrite" (save the edits over it);
  - a file deleted and recreated is picked up again.
- **E-5 [A+W]** Saving keeps the file's encoding. A non-UTF-8 file stays in its encoding, or the save is
  refused with a message. It is never silently converted.
- **E-6 [A]** The editor refuses things it can't edit safely: directories, FIFOs and devices,
  binaries, files over a size limit. It refuses with a clear message and never hangs. Text whose
  first bytes cut a UTF-8 character at a sampling boundary still opens.
- **E-7 [W]** In the preview, relative links to other files open them, and `#anchor` links scroll
  within the document. Repeated headings get distinct anchors. Local images, relative to the
  document, in Markdown or raw HTML, display, and so do remote images and linked badges. Page
  scripts never run.
- **E-8 [W]** Editor shortcuts work regardless of Caps Lock.
- **E-9 [A]** Where a new file pane goes, in the user's words (2026-11-04): "by default new files
  should be opened on a new pane, up to three per tab, then go to new tab. and if opened from umi
  the file should show on a pane next to the pane that called to open it". A file opened from a
  pane (`<cli> edit FILE` in it, the palette, the file tree, a link in a preview) goes to the right
  of that pane, or of the given pane or the given tab's focused pane; several files go one after
  another. When the tab already shows three panes (a stack counts once), the file gets a new tab
  right after it. A file already open shows where it is, without a second pane. An explicitly named
  pane or tab that doesn't exist is an error, never a fallback to another tab.
- **E-10 [A]** A file opened from outside the app (Finder, `open FILE`, the app being the default
  for these types):
  - Markdown (asked 2026-11-05) opens in one shared tab, the docs tab (`docs: true` in `ls`, named
    Docs). Its documents share one place as a stack (M-7), the most recently opened first. The
    strip names the three most recent (and the one on show, if older), then "+N · ⌘[ ⌘]" for the
    rest, which ⌘[ and ⌘] reach. A new document goes first and on show; one already open anywhere shows where it
    is (in the docs tab it becomes the most recent). Without a docs tab, one is made in the current
    window (a new window if there is none). Closing the last document closes the tab.
  - Text, JSON, CSV, TSV and YAML files open in the tab whose folder is closest to the file: the
    tab with a pane whose working directory is the deepest folder containing the file. Any pane of
    a tab counts; `/` doesn't. A file already open somewhere shows there. Ties go to the current
    tab, then the current window's tabs in sidebar order, then other windows'. With no such tab it
    opens in a new tab in the file's folder, in the current window (a new window if there is none).
  - The ⌘O Open panel still opens in the current tab.
- **E-11 [A]** Comments on Markdown documents, as in Google Docs, so the user can react to what
  agents show them and agents can act on it:
  - selecting text in the preview offers Comment (a button by the selection, Edit ▸ Add Comment,
    ⌥⌘M); in the source view ⌥⌘M asks for the comment in a sheet. A comment shows in a margin beside
    the words it's on, level with them, which are highlighted; clicking either selects the thread.
    Comments can be replied to, edited, resolved (hidden until "Show resolved"), reopened and
    deleted (after a confirmation). In a panel too narrow for a margin, the selected thread shows
    under its words;
  - comments are stored in the file itself, in Roughdraft Flavored Markdown: the anchor and the
    comment inline (`{==words==}{>>comment<<}{#c1}`), and author, time, replies and resolved state
    in YAML endmatter at the end of the file. Every change is written to the file at once; unsaved
    edits stay unsaved. Roughdraft's own files (attribute blocks, comments without ids, suggestions)
    are read, and what Umi doesn't change is kept. Markup in code is literal text;
  - an anchor stays within one block (paragraph, list item, table cell), takes a partly selected
    link or code span whole, and never overlaps another comment (refused with a reason). Comments
    move with their words through edits by agents and git merges. When the words under an anchor
    are deleted but its markup stays, the comment stays at that spot ("the words were deleted");
    when an edit removes the markup itself, the comment is *detached*: it still shows, with the
    words it was on, from a copy kept in the endmatter, until it's resolved or deleted;
  - an agent given only the file path reads every comment and the words it's on by reading the
    file, or with `<cli> comments` (CLI.md), with or without the app running, and replies, resolves,
    edits, adds or deletes the same way;
  - the review loop: `<cli> comments wait FILE` blocks until the user presses Done on that file in
    the editor, then prints its open comments; while an agent waits the margin says so. A comment
    being written isn't lost when an agent changes the file meanwhile.
- **E-12 [A]** Web pages from the user's own servers open inside the app. The config key
  `umi-web-origin` (repeatable, no default) lists origins, such as
  `https://agent-server.tail622085.ts.net`. A link from a listed origin ⌘-clicked in a terminal pane,
  or given to `<cli> edit URL`, opens in a web pane instead of the browser: a pane placed as a file
  pane is (E-9) that splits, moves, stacks (M-7), closes and is restored like any other pane. It
  shows the page with its title, Reload (⌘R), Open in Browser and a close button along its top;
  there is no address bar. Pages run their scripts, and their cookies and local storage persist
  across relaunches. A relaunch restores the page by its URL. Links and navigation to other origins
  open in the default browser. `<cli> edit` refuses a URL from an origin that isn't listed. A web
  pane counts as quiet for updates (I-4): the pages it is for keep unsaved drafts in their local
  storage, which survives the relaunch.

- **E-21 [A+W]** The source view looks and reads like Warp's code editor (Warp parity, 2026-11-05):
  - the terminal's font at the terminal's size; no soft wrap: long lines scroll sideways;
  - a 94-point gutter with line numbers in that font, the current line's at 90% of the text color
    and the others at 60%; the current line has the 10% surface color behind it while nothing is
    selected;
  - marks along the gutter's left edge, 3 points wide, against the file's last commit: green for
    added lines, yellow for changed lines, red where lines were removed (the terminal's normal ANSI
    colors);
  - syntax colors from tree-sitter for the languages Warp's editor colors, picked by file name as
    Warp picks them (Warp's list less jq, Nix, Objective-C, PowerShell, Vue, HCL and SQL), in the
    terminal's ANSI colors as Warp maps them: keywords magenta, functions blue, strings and numbers
    green, types and tags red, comments and punctuation yellow, properties cyan.
- **E-22 [A+W]** Find and replace in a file pane, as Warp's (Warp parity, 2026-11-05). ⌘F, ⌘G and
  ⇧⌘G in a file pane act on the file, never on the terminal under it. ⌘F opens a bar floating at the
  top right (10 down, 20 in, 500 wide) with the selection (one line of it) as the query and its
  field focused. Enter or ⌘G goes to the next match, Shift-Enter or ⇧⌘G to the previous one,
  wrapping; the caret goes to the selected match's start and the match shows in orange, the others
  in yellow; the bar counts "n/N" ("?/N" with no selected match). With the bar closed, ⌘G opens it
  on the first match at or after the caret and ⇧⌘G on the last match before it. In a JSON or
  CSV preview these keys switch the pane to its source and find there; a Markdown preview has its
  own find bar (MD-4), and ⌥⌘F (replace) switches it to its source. Toggles: regex, case-sensitive, and preserve case for replacing. The replace row
  (the bar's toggle, or ⌥⌘F) replaces the selected match on Enter and every match with Replace all,
  as one undo step; Select all selects every match in the text. Esc closes the bar and returns to
  the text.
- **E-23 [A]** Editor keys, as Warp's (Warp parity, 2026-11-05): ⌃G opens "Go to line" (top centre,
  "Line number:Column"; Enter goes there, Esc closes; Warp's messages for empty or invalid input);
  ⌘/ comments or uncomments the selected lines with the language's line-comment prefix after their
  indentation (uncomments when every non-blank line has it); ⇧⌘S saves under a name the user picks
  and the pane then shows that file (when another pane already shows that file, that pane takes the
  text and focus and this one closes; with unsaved edits there, Save As refuses and says why); ⌘S shows a "File saved." toast at the top of the tab for 4
  seconds. Saving never reformats the file. When no file pane is focused these keys go to whatever
  is (a terminal gets ⌃G).
- **E-24 [A+W]** File pane header and stack chips, as Warp's (Warp parity, 2026-11-05): the file's
  name centred, with an 8-point dot 4 points before it while there are unsaved changes; on the right
  the preview/source control (E-2), ⋯ and close. ⋯ opens the pane menu, as Warp's for each view
  (W: `code/view.rs`, `notebooks/file/mod.rs`); a right-click on the header opens the same menu (an
  Umi addition: Warp's header has none). In the source view: Maximize pane (Minimize pane while
  maximized; outside a split it does nothing), Copy file path, Reveal in Finder, and View Markdown
  preview for Markdown. In a preview: Maximize pane, Refresh file (asks first when there are unsaved
  changes), Open in editor (the source view), Copy file path. A right-click in the source text offers
  Cut, Copy and Paste. A stack chip (M-7) for a file shows
  the file type's colored icon and the same dot, and is at most 300 points wide.
### The Markdown preview as Warp's (Warp parity, 2026-11-05)

Compared with Warp on macOS, default settings, default Dark theme. Front matter, comments (E-11)
and links (E-7) work as before.

- **MD-1 [A+W]** The preview looks like Warp's Markdown view: Roboto (bundled) at the terminal's
  font size (13 px by default; Warp's Markdown follows its terminal font size) with a line height of
  1.5, across the full width of the pane; headings at 2.25, 1.8, 1.5, 1, 0.83 and 0.67
  times the body size, h1–h4 semibold and h5–h6 regular; inline code in the terminal's red on
  `surface_3` (the foreground at 15% over the background); tables with 12 px cell padding, text in
  the secondary color (60%), lines between rows only, scrolling sideways when wider than the pane;
  a 3 px rule; task checkboxes filled with the accent when done. Bare URLs (`https://…`, `www.…`)
  in text are links.
- **MD-2 [A]** Code blocks have a 1 px `surface_3` border and a footer naming the language as Warp
  does (Python, Shell, Code…). Known languages are highlighted in Warp's colors (keywords magenta,
  functions blue, strings green, tags red, classes and types yellow, built-ins and regular
  expressions cyan; comments, numbers, constants and variables in the text color). Copy
  puts the block's text, trimmed, on the clipboard. Shell blocks (`sh`, `shell`, `bash`, `zsh`,
  `fish`) also have Run in terminal: the command goes to the input of the tab's terminal used most
  recently, which takes focus; it isn't run until the user presses Return, as Warp puts it in its
  input.
- **MD-3 [A]** Mermaid blocks show the diagram. Each has Raw / Rendered beside its language label
  and, while rendered, Open full screen, which shows the diagram larger over the page; Esc or a click outside closes it. A diagram that fails
  to parse shows its source and the error.
- **MD-4 [A]** ⌘F in the preview opens a find bar (Warp's: top right, up to 500 px). Matches are
  highlighted as typed, case-insensitively unless Aa is on, as a regular expression when `.*` is
  on; the bar says which match is current ("2/3") or "No matches". ⌘G and Return go to the next
  match, ⇧⌘G and ⇧Return to the previous, scrolling it into view; Esc closes the bar.
- **MD-5 [A]** Right-clicking the preview shows Warp's items: Copy (with a selection), Copy file
  path, Split pane right / left / down / up, and in a split Maximize pane (Minimize pane when
  maximized) and Close pane.

## AG. Agent sessions

A **session** is one Claude Code or Codex conversation the product knows. It runs in one of two ways:

- **Headless:** the product runs the agent without its interface (Claude Code's own headless mode,
  Codex's own app server) and controls it from events and ids the agent reports.
- **Live:** the agent's own interface (Claude Code's or Codex's) runs in a pane, on the same
  conversation.

The product always launches and controls sessions headless. A session moves from headless to live
when the user takes it over in a pane, and back to headless when its interface closes. Wherever it
runs, it is the same session: same id, conversation, folder and settings.

### Launching
- **AG-1 [A]** `agent start claude|codex PROMPT` starts a session headless and prints its id. It
  takes a name, a folder or a git worktree, a model and effort, full access (no approvals),
  environment variables and extra arguments for the agent. Without a placement nothing appears on
  screen. Text comes from arguments, from stdin with `-`, or after `--` where it isn't harness
  arguments; no command waits on stdin unless asked to with `-`.
- **AG-2 [A]** Sessions the user will interact with: with a placement (`--tab`, `--split [DIR]`,
  `--window`, `--pane P`), the session runs headless until its first turn finishes, and is then
  resumed live in that place, on the same conversation. Meanwhile the place shows the read-only
  view (AG-5). The user's focus doesn't move unless asked (`--focus`), as in L-8.
- **AG-3 [A]** Launches are reliable. A session's first turn starts within seconds. A session that
  can't start (the agent isn't installed, the folder is gone, the conversation no longer exists)
  fails at once, with the reason, in `agent start`/`send`/`wait`/`info`; it never silently starts a
  fresh conversation in its place.
- **AG-4 [A]** Fidelity. A session, headless or live, is the agent the user would get by typing the
  same command in their own terminal in that folder: their and the project's instructions
  (`CLAUDE.md`, `AGENTS.md`), skills, MCP servers, plugins, hooks and subagents; the login shell's
  environment, never the launching process's agent variables; their own logins. Running sessions
  never changes the user's own `claude`/`codex` configuration, except installing Umi's plugins
  (AG-18).

### Headless and live
- **AG-5 [A+W]** Read-only view. A headless session appears in a pane only when the user asks to
  locate it (`agent open`, the Window menu, the palette, the "next session that needs you"
  shortcut). The pane shows the session read-only: what was said on both sides, tool activity, its
  status and anything it waits on, and a **Take Over** button. Showing a session that is already
  shown focuses its pane.
- **AG-6 [A]** Take over. The button (or `agent open --live`) immediately replaces the read-only view
  with the agent's own interface on the same conversation, in that pane. A turn running at that
  moment continues in the live interface (Codex) or is interrupted (Claude Code, which can't share a
  running turn); either way nothing waits for the turn to end.
- **AG-7 [A]** Back to headless. When the live interface closes (the user quits it), the session is
  headless again with its whole conversation, and the pane shows the read-only view. A session cut
  off by a quit of the app comes back in the same place after a restart: live panes live, read-only
  panes read-only.
- **AG-8 [A]** Remove from a pane. A keyboard shortcut (and `agent hide`) removes the session from
  its pane without stopping it: the pane goes away (the user doesn't see it) and the session keeps
  running until it finishes. A live interface keeps running out of sight until its turn and any
  background work end; then the session is headless and idle.
- **AG-9 [A]** Messages reach live sessions. A message sent to a live session is delivered exactly
  once:
  - Codex: at once, through the conversation the live interface shows (steering a running turn, or
    starting one).
  - Claude Code: when its interface is idle and the user has nothing typed in it. The session runs
    the message headless (the pane shows the read-only view meanwhile) and then returns live to the
    same pane. Until then the message waits, and `agent info`/`ls` say why.

### Supervising and steering
- **AG-10 [A]** `agent send SESSION TEXT` prints a message id at once. While the session works, the
  agent sees TEXT during its current turn (steering, at its next step). Otherwise TEXT starts a turn.
  A session that is stopped, crashed, or from before an app restart or update resumes its
  conversation with the folder, model, effort, access, environment and arguments it was started
  with. `--interrupt` stops the running turn first, and TEXT is the next thing the agent sees.
  Message and session ids are the ones the agent itself reports or echoes; the agent's own session or
  thread id also selects the session.
- **AG-11 [A]** Exactly once. Every message is delivered to the agent exactly once, under any timing,
  including steering, interrupts, crashes and restarts. A message that can't be delivered ends in a
  failure state the caller sees; nothing is pending forever.
- **AG-12 [A]** `agent wait SESSION [--message ID] [--timeout S]` waits until the turn answering the
  latest (or given) message has ended and the session has settled (no background work of its own
  still pending), or until it needs input, and prints a status, then the reply. `DONE` 0;
  `NEEDS_INPUT` 2 (with what it waits on); `INTERRUPTED`, `FAILED`, `STOPPED`, `ERROR`,
  `CANCELLED` 3; `TIMEOUT` 124 (with what is still running). An old message's wait returns that
  message's own reply. `--report` waits for the worker's own report instead (AG-16).
- **AG-13 [A]** Truthful status: `starting`, `working`, `idle`, `needs_input`, `stopped` or `error`,
  for headless and live sessions alike. `stopped` is what `agent stop` leaves; a session whose
  interface closed or whose agent exited by itself is `idle` (a message resumes it). A session isn't `idle` while a turn runs, a message waits,
  or background work it started (that will wake it) is pending; it isn't `working` when it's done.
  Turns the agent starts by itself (a background task finished, a scheduled wake-up) show as
  `working`, appear in the transcript as their own turns, and are never taken as the reply to a
  message.
- **AG-14 [A]** `agent read` prints the last reply, a given message's reply, or the transcript in
  order. `agent ls` and `agent info` show each session's status and activity, where it is
  (`background`, a pane's read-only view, or live in a pane), its parent, its latest report, what it
  loaded when it last started (model, MCP servers and their state, flags for anything that failed or
  needs the user), and messages waiting.
- **AG-15 [A]** `agent interrupt` stops the running turn and keeps the session. `agent stop` ends the
  session's work completely: its agent process and everything it started, including detached
  processes and ones that ignore SIGTERM; a live interface closes; the conversation stays resumable.
  `agent rm` forgets a session (`--force` stops it first). `agent rename` renames; names are unique
  among running sessions.
- **AG-16 [A]** Agents supervise agents. Inside any session (headless or live), `<cli>` is on PATH
  and reaches the right instance; `self` names the session; sessions it starts record it as their
  parent (`agent ls --parent self`). `agent watch SESSION --notify OTHER` sends OTHER a message when
  SESSION finishes, needs input or stops. `agent report done|blocked|failed SUMMARY` records a
  worker's verdict, shown in `info`/`ls` and awaited by `agent wait --report` (done 0, blocked 2,
  failed 3). A session knows its situation without being told: its name and id, parent, folder, that
  nobody may be watching, and how to report and reach other sessions.
- **AG-17 [A]** Approvals and questions. Without full access, what the agent asks for (approvals,
  questions, several questions in one request) shows as pending requests that say exactly what
  would be allowed, answerable with `agent approve`/`deny`/`answer` and from the read-only view.
  Requests the agent withdraws disappear. In a live session the agent's own interface asks.

### Observability
- **AG-18 [A]** The product observes agents the way Warp does: Umi's plugins for Claude Code and
  Codex report each session's state from the agents' own hooks to the app. That covers sessions the
  product started, while live, and `claude`/`codex` the user starts by typing them in a pane, which
  then become sessions the product knows. The plugins are installed into the user's Claude Code and
  Codex and kept up to date (`agent plugins` shows their state). Outside the product (another
  terminal, or no app running) they're silent: no output and no effect.
- **AG-19 [A]** Live status is truthful through agent updates: a turn's end with background work
  still pending isn't "finished", an interrupted turn doesn't stay "working", and a session waiting
  on a permission prompt or a question is `needs_input`.
- **AG-24 [A]** *Warp parity, 2026-11-05.* Agent events inside the app, as Warp's notification
  mailbox and toasts:
  - an agent shown in a pane that finishes its turn, asks for the user or fails adds an item to an
    inbox, newest first, at most 100; a pane keeps only its newest item, and the agent starting a
    new turn takes it away. An item is read once the user looks at its pane, or if it happened
    while they looked at its tab. Items use Warp's words: the session's title, or "Claude
    completed" ("Task completed."; Codex: "Notification from Codex"), "Claude needs attention"
    (what the agent asks, or "Waiting for input."), "Claude failed" (the agent's error, or "The
    agent encountered an error.") and "Claude cancelled" ("Cancelled by user.") for a turn that
    was stopped;
  - ⇧⌘U opens the inbox over the window's top right: filters All tabs, Unread and Errors (the last
    two only while they have items), each item with the agent's icon and badge, title, message and
    age. ↑ ↓ choose, Return goes to the session's pane (the item is read), Tab or Shift-Tab change
    the filter, Escape or ⇧⌘U close it. A click outside it closes it too (the click still goes
    to what it hits, so typing then reaches the pane), and so does closing its window. It is open
    in one window at a time: ⇧⌘U in another window opens it there;
  - an unread item also shows as a toast in the window the user is looking at (the key window of
    the active app), for 8 seconds, at most two at once (the oldest goes), none while the inbox is
    open in that window; opening the inbox or ⌃⌘U dismisses them, and looking at the pane takes its toast away.
    No desktop notifications (S-3).

### CLI for agents
- **AG-20 [A]** An agent with no instructions about the product can use it: given only a task that
  needs other agents (and that `<cli>` exists), real Claude Code and Codex agents start sessions,
  wait for them, read their replies, steer them and stop them through `<cli>`, guided only by its
  help and its messages. The help is short and plain; errors say what to do instead.

### Robustness
- **AG-21 [A]** No orphans. Every process started for a session belongs to a session listed as
  running, or is gone: after `agent stop`, `agent rm --force`, a crash of the agent, a quit of the
  app, and after every process of the product is killed and the app started again. No zombies
  accumulate.
- **AG-22 [A]** Crash and restart. After the app quits, crashes (`kill -9` of every product process)
  or is updated, all sessions are listed; each resumes on its next message; no message is delivered
  twice or lost; transcripts keep every entry once. A turn cut off by the quit, crash or update
  continues by itself once the app runs again, with a short note saying when and why it was cut off
  and that what it had running was stopped; `agent wait` on the cut-off message returns the
  continued turn's reply. A normal quit or an update never cuts turns off silently: it interrupts
  them cleanly, and an update installs while turns run only if the user agrees (an update that
  installs by itself waits for a quiet moment, when none runs, I-4).
- **AG-23 [A]** Long runs. Many sessions, long transcripts, large tool outputs and days of uptime don't
  make the CLI or the app slow. Disk use grows only with what the user keeps.

## R. Robustness

- **R-3 [A]** Restart. After the app quits and restarts, pins and tab names come back. Sessions come
  back as AG-22 says, and their panes as AG-7 says.
- **R-4 [A]** Paths. Everything works with a state directory or working directory containing spaces,
  and with a long state-directory path (Unix socket paths are limited to 104 bytes). The product
  builds from a checkout path containing spaces.
- **R-5 [A]** Isolation. Two isolated instances (different state directories) never talk to each
  other: CLI calls, agents and the panes of one never reach the other.
- **R-6 [A]** The app and its CLI keep working, and tell the truth, while sessions are busy,
  approvals are pending, or event consumers are slow.
- **R-7 [A]** Stale environments. A CLI run with stale pane, socket or agent variables (for example
  from a terminal that outlived its app) either reaches the right instance or fails clearly. It
  never acts on the wrong one.

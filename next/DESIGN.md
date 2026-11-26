# umi-next: design

umi-next is the rebuild of Umi on two processes. A long-lived daemon owns every terminal and its
screen. A thin UI shows them and can be killed, reloaded or edited live without touching a session.
Umi's existing UI decisions (`design/`, `acceptance/SPEC.md`) carry over except where this file
changes them.

## Why the split

Alejo wants to change Umi's interface and use the change at once, without interrupting agents
(2026-11-17). In Umi every terminal lives inside the app, so a restart or crash ends running turns.
iTerm2 (session restoration servers) and VS Code (its pty host) show that terminals owned by a
separate process survive the UI; Warp and agent-emacs don't do this and lose replies in progress.

- **Daemon** (`next/daemon/`): forkpty per session, Ghostty's terminal engine (libghostty-vt)
  keeping each screen, the CLI's socket. It rarely changes, so it rarely restarts.
- **UI** (`next/app/`): a native window. A web view draws everything except terminals and reloads
  from the repository's files on save. Native Ghostty views (Metal) sit in the slots the web layout
  leaves, so typing and drawing stay as fast as Umi's.
- **Attach**: each Ghostty view runs `umi-next-attach <session>`, like `tmux attach`. On attach the
  daemon sends the screen as it is, then live output. Ghostty needs no patch.
- Ghostty is used as a library only, not forked as an app, so following upstream stays cheap.

## The model: sessions live in the daemon, panes are views

A session (an agent or a shell) exists in the daemon whether or not a pane shows it. A pane shows one
session; a session shows in at most one pane, because two views of one terminal would fight over its
size. Opening a session already on screen moves it.

- **⌘W closes the pane and ends its session**, whatever runs there: agents, shells, any program
  (Alejo, 2026-11-18, reversing the 2026-11-17 rule that ⌘W only stopped showing it). ⇧⌘T brings
  an agent back by resuming its transcript in a new session; a shell can't come back.
- **⌥⌘H hides the pane**: the session keeps running, stays under its project in the picker and
  goes on the tab's strip. ⌥⌘W does the same for a whole tab. Exit in the palette ends a session
  and leaves its pane. A session whose program ends by itself (`exit` in a shell) leaves its pane.
- **A daemon restart ends every session; panes come back resuming their agents.** Each pane
  showing a Claude or Codex session records its resume command in the layout, so after a restart the
  pane starts `claude … --resume <id>` / `codex … resume <id>` in the same place (Alejo, 2026-11-18).
  It resumes the conversation only; an interrupted turn doesn't continue by itself. Panes with other
  programs get a fresh shell. Sessions no pane showed (the hidden strip, `umi-next-ctl new`) are gone.
- **Sessions the user started** are the ones the picker lists and Review counts: those started from
  the picker, a new tab, a resume or a restart, and those an agent opens in a visible pane with
  `umi-next split` or `umi-next tab new` (Alejo asks for those; 2026-11-18). Sessions agents or
  scripts start without a pane, with `umi-next-ctl new`, run as usual but stay out of those lists
  (Alejo, 2026-11-17). The daemon records who started each session (`by`); one without a record
  counts as the user's.
- **Project**: the main folder of the git repository a session runs in, so worktrees count as their
  repository. Outside a repository, the session's folder.

## Nothing appears or disappears by itself

Removed from Umi: the per-tab pane limit and the pane it hides to make room (H-1), `pane hide
--until` and `tab archive --until` (H-3, AR), tabs and panes coming back by themselves, and the
manager pane in the drawer (DR-2), at Alejo's request (2026-11-17). The layout changes only when he
changes it; "tell me later" is snooze, whose finished sessions the Dock badge counts.

## Names at creation

- A new tab (⌘T, the sidebar's +, a folder's Open in New Tab, the first window) opens on the
  session switcher in the current folder, as ⌘D's split does (Alejo, 2026-11-23). ⌃⌘R names the tab.
  `umi-next tab new` without `--cmd` still starts a shell, since agents rely on getting a session back.
- Type a name and press Enter or `/` to choose a folder. The current directory is selected first.
  With an empty name, Claude Code and Codex supply their own conversation titles when available.

## ⌘D opens the session switcher

⌘D opens a column at the far right of the tab. ⇧⌘D opens it below the focused pane. The first
screen answers which session to return to across all projects. Each row shows the agent or shell icon, session name and project.
Sessions waiting for input and snoozes that have come due lead the list under **Needs you**, marked
in amber. **Running** follows. **Available** holds idle shells and finished sessions. **Snoozed**
and **On the docket** stay folded until opened or searched.

Typing a name selects the folder chooser and shows matching sessions below. Down and Enter or a
click opens a match. Enter on the first row keeps the typed name and opens the folder chooser.
An open session keeps its pane. A hidden session opens in the switcher's place.

The chooser shows the current project and working folder alongside the Claude Code, Codex,
Antigravity and shell icons. The highlighted icon is what Enter will launch there. Tab cycles
those choices. With an empty switcher, the first Tab also opens the **+ New** form.
**History** lists resumable conversations for the chosen project. Both screens offer a folder
chooser. Typing `/` in the switcher or the **+ New** form goes straight to choosing a folder for a
new session. Text typed before the `/` becomes the session's name: once a folder is chosen, the
form shows that name, Tab cycles the launch kinds and Enter starts it (Alejo, 2026-11-25).

- After the current directory, the folder list shows `proj`'s projects (`proj --list --here`): the folders directly in ~/best's projects,
  areas and orgs, newest first by the date in their names, the current area's first (Alejo,
  2026-11-23: listing every folder near every folder ever used was too much). Letters match within it.
- A path (`~/…`, `/…`, `./…`, `../…`, or anything containing a slash) lists its matching children.
  Tab fills in the selected folder, as a shell completes it, so the next letters search inside it;
  ⇧Tab goes up, and Enter takes the folder.
- **New project**: a name no folder contains puts "New project" first, and Enter runs
  `proj <name> --repo-later` from ~/best: `projects/<date>-<name>`, or inside the folder Tab filled
  in when it is within ~/best. When folders do match, the row comes last and ⌘Enter takes it. The
  session's folder is ready at once; the GitHub repo `proj` makes is created in the background
  (a taken name leaves the folder without a remote and posts a notification).
- Folder suggestions and path browsing exclude linked Git worktrees, worktree directories and
  the macOS temporary tree at `/private/tmp` (also reachable as `/tmp`).

## The palette at the bottom

Replaces the manager pane. A tap of Hyper alone (all four modifiers down and up with no key between)
opens it; Hyper+Space also does, in case the Hyper tool turns a lone tap into another key. It slides
up from the window's bottom edge, where the drawer was, like agent-emacs's menu (⌘E there).
It lies over the bottom of the panes: they keep their size and place, so no terminal reflows while
it is open.

- Columns of commands, each on one letter, the frequent ones under the left hand: Sessions (new,
  switch, open past, reopen the last closed, archived tabs), This session (rename, snooze, docket,
  restart, hide, exit, move), Review (clear finished snoozes),
  Options (sidebar, reload the web layer, keyboard shortcuts, `u` update and restart: runs `next/install.sh` from the
  app's checkout, which rebuilds, quits and reopens Umi next; sessions keep running in the daemon,
  and a failed build leaves the app running with a banner naming `<state>/update.log`).
- `/` searches every command by name instead.
- It is part of the web layer, so it can be changed live.

## Snooze and Review

- `z` in the palette snoozes the focused session, optionally for a time (`2h`): its pane closes while
  the session keeps running, `umi-next notify` from it fires no alert, and it is left out of Review.
  The switcher keeps it in the folded Snoozed group.
- A snoozed session's snooze finishes when its turn ends or its time runs out. It then counts in
  Review whatever its reply says: snoozing asked to be told. Showing the session again, or `c` in
  the palette, clears it.
- **Detached sessions that finish done stay out of the way** (Alejo, 2026-11-17). When a detached
  session's turn ends, its last reply's status line decides, read as agent-emacs's
  `agent-session-reply-status` does (the last line of the reply starting `Status:`, after list marks
  and emphasis, case ignored):
  - `done` or `done, pending verification`: it stays out of Review; the switcher lists it under Available.
  - `waiting on you`, a question or permission dialog on screen, or no readable status line: it
    counts in Review, since it can't be confirmed done, and the switcher lists it under Needs you.
  - `in progress` with the turn ended: the same.
- **Review** is what waits for Alejo, grouped by project, the current project first: sessions waiting
  for input, finished snoozes, and docketed sessions whose hook failed. The switcher shows them
  across projects. The Dock badge counts the current project's items, and `umi-next go --next` walks them in that order; it has no key or palette entry (Alejo, 2026-11-21).
- agent-emacs's snooze fades a session and silences its alert; grouping by project and scoping the
  badge to the current project is the addition.

## Snooze to docket

Alejo, 2026-11-17: a session sent to the docket shows only on the morning docket, never in the
session list. Hyper+D (or `d` in the palette) stops showing it and marks it docketed: it stays out
of Review however it ends, unless its hook fails; the picker lists it under "On the docket".

When its turn ends, UmiNext runs `~/.config/umi-next/docket-hook` (dotfiles
`umi-next/docket-session`) with the session as JSON on stdin. The hook drafts a queued
`desk/requested/` item from the end of the transcript with `claude -p`, makes a link with
`umi-link --app next`, and commits it to desk. Drafting from outside, not by typing `/queue` into
the session, works while a dialog blocks the input box and leaves the session's last reply as it
was. A failed hook puts the session in Review and under Needs you. Hovering the row shows the error.

The item's `umi-next://open?task=…` link reattaches the daemon session while it lives, and
resumes the agent session once it doesn't.

## Parity with Umi

Alejo, 2026-11-17: umi-next reaches Umi's features, editor and Markdown preview with comments
included, built in the web layer; native code only for terminals and what a page can't do.
`next/PARITY.md` is the plan, area by area.

- **Top bar and pane headers** (Alejo, 2026-11-18): the top bar lists the open tabs, each with its
  status dot (its most pressing pane's); each pane has a header with its status dot, icon and name,
  and in a tab showing several panes the focused pane's header is lit in the accent. Dots are
  always there, idle grey, and only change colour, so names never shift. No dots sit over the
  terminals. With the sidebar hidden, the top bar starts clear of the window's buttons.
- **Hidden-pane strip**: at the right end of the top bar, the sessions ⌥⌘H hid from the current tab; clicking one shows it
  again.
- **Shortcuts belong to the page.** `web/shortcuts.js` is the one table of global shortcuts; the
  page sends it to native on every load, native takes only the keys it lists and passes every
  other key on to the terminal or page. A new or changed shortcut is a saved file, not a rebuild,
  and the shortcuts page draws from the same table. Reload and quit run natively, so they work
  while the page is broken.
- **Services for the page**: `web/fs.js` reads, writes (atomic, refused when the file changed
  since it was read), lists folders (git-ignore aware), watches paths, lists files for quick open
  and searches with ripgrep, rooted at the focused pane's project. New native services go
  through the same `Umi.bridge.request`.
- **`umi-next` CLI** mirrors the `umi` commands that drive the UI (edit, split, tabs, panes,
  Markdown comments), so agents and skills move over by changing the command name.

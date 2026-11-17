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

- **⌘W stops showing the pane**, for every session, agents and shells alike: the session keeps
  running and stays under its project in the picker (Alejo, 2026-11-17: "cmd + w maps to stop
  showing the pane instead of to 'kill the process'"). Ending a session is only ever an explicit Exit
  in the palette. A session whose program ends by itself (`exit` in a shell) leaves its pane.
- **Project**: the main folder of the git repository a session runs in, so worktrees count as their
  repository. Outside a repository, the session's folder.

## Nothing appears or disappears by itself

Removed from Umi: the per-tab pane limit and the pane it hides to make room (H-1), `pane hide
--until` and `tab archive --until` (H-3, AR), tabs and panes coming back by themselves, and the
manager pane in the drawer (DR-2), at Alejo's request (2026-11-17). The layout changes only when he
changes it; "tell me later" is snooze and Review.

## Names at creation

- A new tab opens with its name in edit mode in the sidebar; Enter keeps the name, Escape keeps the
  folder name.
- A new session is named in the picker's first field. Left empty, it is named after its folder with a
  number, so naming never blocks starting.

## ⌘D: the pane picker

⌘D (⇧⌘D down) splits and shows the picker in the new pane itself, not in a dialog:

1. A name field, focused. Enter starts a Claude session with that name; Tab cycles Claude, Codex,
   shell.
2. Live sessions of the focused pane's project waiting for input, most recent first.
3. Live sessions of that project that are busy.
4. Past sessions of that project that can be resumed (Claude's and Codex's own transcripts).

↑↓ choose, Enter opens. agent-emacs splits these into a switcher, a new-session prompt and a history
browser; one list ordered by what needs Alejo is fewer steps.

## The palette at the bottom

Replaces the manager pane. A tap of Hyper alone (all four modifiers down and up with no key between)
opens it; Hyper+Space also does, in case the Hyper tool turns a lone tap into another key. It slides
up from the window's bottom edge, where the drawer was, like agent-emacs's menu (⌘E there).

- Columns of commands, each on one letter, the frequent ones under the left hand: Sessions (new,
  switch, next waiting, open past), This session (rename, snooze, restart, exit, move), Review,
  Options.
- `/` searches every command by name instead.
- It is part of the web layer, so it can be changed live.

## Snooze and Review

- `z` in the palette snoozes the focused session, optionally for a time (`2h`): it detaches, fires no
  alert, and leaves "next waiting".
- When a snoozed session's turn ends or its time runs out: in the project Alejo is in (the focused
  pane's), a quiet badge on its Review row; in another project, it joins that project's group in
  Review with no alert.
- **Detached sessions that finish done stay out of the way** (Alejo, 2026-11-17). When a detached
  session's turn ends, its last reply's status line decides, read as agent-emacs's
  `agent-session-reply-status` does (the last line of the reply starting `Status:`, after list marks
  and emphasis, case ignored):
  - `done` or `done, pending verification`: it leaves Review and "next waiting"; the picker still
    lists it, at the bottom, as finished.
  - `waiting on you`, a question or permission dialog on screen, or no readable status line: it
    shows in Review, since it can't be confirmed done.
  - `in progress` with the turn ended: it shows in Review.
  A snoozed session shows in Review when it finishes even if it says `done`: snoozing asked to be
  told.
- **Review** is a section of the sidebar listing what waits for Alejo, grouped by project, the current
  project first: sessions waiting for input, finished snoozes. "Next waiting" walks it in that order.
- agent-emacs's snooze fades a session and silences its alert; grouping by project and scoping alerts
  to the current project is the addition.

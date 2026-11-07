# The user's requests (verbatim)

These are the user's own words. `SPEC.md` restates them as checkable outcomes; when the two seem to
differ, these win.

## Original request

> I want to build an agent orchestrator as a fork of ghostty. the main features I care
> about are:
> - warp-like panes, tabs and windows. controlled from the cli and also accessible as
>   shortcuts. I want to move active sessions between tabs, panes, and windows. tab
>   naming and other visual features around those primitives should also be accessible
>   on the cli
> - allowing cross agent coordination, having agents start sessions, send follow-up
>   messages, monitor state, intervene, resume sessions, etc. claude code recently
>   launched new features for that, so we can build on them. the behaviour we can
>   implement in codex wihtout relying on acting on top of its UI (which is hard to
>   control programatically) we should implement as well
> - a warp-like aesthetic and interface.
>
> ignore the other folders on dev, as they contain projects with a different intent.
> once the build is done and tested,call codex on high effort for code review and
> iterate until it doesn't flag any high or moderate severity issues

(Later changes from the user: orchestration follows "Two launch modes" below, as relaxed by the last
request in this file; the review loop is capped; other folders in ~/dev are off limits.)

## Interface requests

On the interface (all are implemented in the reference UI):
> Cmd + B should toggle the left sidebar. sidebar should use the warp 'group by tab'
> instead of gropu by pane. add an in-app md/text file editor similar to warp, which
> should be the default on `open xxx.md`. the editor should render md files instead of
> showing the raw source, but it should be easy to toggle between the two with a
> shortcut or a ui commponent. remove the icons on the upper right corner and the 'no
> agents running' section (keep sidebar simple, like warp). add the option to pin tabs.
> add a warp analogue filetree/project explorer. remove the open tabs section at the top
> so only the sidebar remains to show tabs. copy closer the no visible containers
> aesthetic of warp […] add the possibility to launch tabs and panes in a different/new
> worktree to the cli

> for the sidebar, I think making it two lines (terminal command on the focus pane on
> the bottom line, folder name and branch/worktree on the top one) would be great

> I'll use this app here and on an m4 mac. so i want it to work out of the box once I
> install it on the other mac

On Codex:
> If you find a solution that has codex behave exactly as it would when I run 'codex' on
> an empty terminal apply it. I don't want to need to worry about commands/mcps/
> configuration failing because of this. if that's not possible I'd use the closest
> approximation we can to that for codexes called from the cli, and codex I invoke
> manually run as usual

## Orchestration: two launch modes (the user's specification)

(The user's last request below relaxes this: the split was their first guess at a simplification, and
is not meant to be baked in. See SPEC.md, "Priorities".)

Split the problem into **two launch modes**. Don't try to have both full native-TUI
fidelity and full control in the same session.

### A. Interactive sessions: no control after launch
- Open a pane running plain `claude` or `codex` (with any flags or prompt the user
  gives), exactly as if the user typed it in an empty terminal.
- After launch the app does **not** control, track or type into the session. At most it
  can show it in the sidebar and note when the process exits.
- Must not change how the user's own `claude`/`codex` behave: config, MCP servers,
  environment, shared daemons, and manually started sessions all stay as usual.

### B. Managed sessions: full control, rendered by the app
- Launch the agent in a programmatic mode where the orchestrator owns the session and
  receives structured events with IDs.
- Render the session in the app: a pane-like view showing the transcript, tool activity,
  status, and anything that needs the user (e.g. approvals). The user can follow up from
  that view, so the app is the single control plane.
- **Research the current programmatic interfaces** for Claude Code and Codex before
  choosing (for example the Claude Agent SDK or `claude -p` with streaming JSON, and
  Codex's `exec --json` or app-server). Compare authentication (the user's
  subscriptions), approval/permission handling, resume support and stability, then pick
  what gives reliable control.
- No screen scraping or keystroke injection in this mode.
- **Follow-ups, including delayed ones:** you can send a follow-up to a worker at any
  time:
  - while it's busy (queued);
  - right after it finishes;
  - hours later, after its process exited or the app restarted, by resuming the same
    conversation.
- **Capabilities:** status (working / idle / needs input / exited / error), interrupt,
  stop (which ends all of its work), read the last reply, wait for the reply to a
  specific message, resume, and list.
- **Everything is scriptable from the CLI**, so agents can orchestrate other agents
  (Claude starting Codex workers and vice versa, with follow-ups and waits).
- Identify sessions, turns and messages by IDs the harness provides, not by text or
  timing heuristics.
- **Fit the user's existing workflow.** The user supervises workers with this skill:
  https://github.com/alejoacelas/dotfiles/tree/main/skills/supervise-workers
  - It writes a task file per worker, starts the worker with a pointer to it, waits for
    the turn to end, reads the report, checks evidence, and follows up.
  - Make that flow easy from the CLI: start, wait, read, follow up, stop, list/resume.

## Later requests

> the worker control panels we implemented should behave as any other panel. e.g., should be able to
> open panels next to them, etc.

> and remove the new agent sidebar button and that functionality

> does our current app easily extend to moving an active terminal session on a pane to another
> window/tab/tab group? that's a feature I'd like

> nice, make sure to also specify what the core features are (by reasoning through the
> functionality that I want as an agent orchestrator that runs all the time on bypass permissions
> mode but that otherwise uses most of the agent features) and which might be optional/could be
> deliberately excluded/reworked if it's involving a tradeoff agasint reliability of core functions
> (e.g., having workers not be on the terminal was a quick guess of mine on how to simplify the
> problem by compromising something non-core. I don't actually want to bake that decision for the
> new run, but I want to allow it to make compromises). the behavior of manipulating panes and
> launching/moving terminals around them on the warp-like UI is not up for compromise

> I'd rather have you disregard some fo the details of my guidance rather than skirt the best
> practices there

## Delivery in two phases, updates, and the harness decisions

> actually, would it be easier to deliver first on the editor for now, and document the harness for
> later? also, what's the easiest way to install the editor in my other computer and receive updates
> as we keep working on it here?

> I'm okay with this being public, I just want whatever's most convenient for using it across
> computers

> things I care most about are reliability and no hidden traps where the agents are not eg., running
> a skill they're supposed to have access or confused about the environment they're running in etc.

On where sessions live, the user chose to let sessions stop when the app quits and resume them
after:
> A sounds good, and we should put effort in being able to reliably send a message to an agent
> session and have it running from there

> on the idle problem, what about having workers report their status once they're done and
> supervisors still have a signal that says 'harness says no work' and they're given a small hint so
> they know there are edge cases like this

> go ahead, write them, then launch the worker without asking me. subject it to 5 rounds of
> adversarial rewiew or until no high/moderate bugs are found

> do that for the editor only. once it's done, if it's done to your satisfaction, you can launch the
> worker to do the harness and subject to adversarial review as well. use headless workers for all
> this

("The editor" here means the whole app without managed agents: SPEC.md's phase 1.)

## Answers after phase 2

Asked whether quits requested by scripts should confirm, whether updates should keep downloading
without asking, whether the MIT license in the user's name is right, and whether `agent start` should
show workers by default:
> script quits should not ask, updates should ask. license is good. default workers to backgroudn

("updates should ask" is superseded on 2026-10-27, below: updates install themselves at a quiet
moment; `auto-update = check` brings the question back.)

## After 0.4.0: Warp's look for terminals, and the sidebar order (BRIEF-blocks.md)

> would it be easy to implement the look and placement from warp of terminals? notice that the
> terminal shows at the bottom, when it returns it does so in a block above, and it has a nice
> autocomplete suggestions feature

> also the box thing telling you the directory you're on

Their screenshot from Warp is `reference/warp-blocks.png`. After hearing the options they chose an
imitation that keeps the shell underneath: zsh keeps editing the command line as it does today, and
Tern changes how the terminal looks (the prompt at the bottom, blocks with a header, the command in
bold, its output and a line between blocks, the folder box). Suggestions are done already: their
`~/.zshrc` loads zsh-autosuggestions.

On the sidebar order (superseded on 2026-10-27, below):
> my idea was that other than the focused session, tabs should only move when an agent finishes
> their turn

## 2026-10-27: tabs keep their order, as in Warp (BRIEF-tab-order.md)

> fix the tab reordering? right now it has a custom logic and I want to have the standard behavior
> from warp that doesn't switch tab order depending on recency

This supersedes the request above: selecting a tab and an agent finishing its turn no longer move
tabs; only the user's own moves do (SPEC S-7).

## 2026-10-27: updates install themselves when nothing would be lost (BRIEF-quiet-updates.md)

Alejo develops Umi on one Mac and uses it all day on another; he wants each tested release to reach
the main Mac without interrupting his work and without having to act. Asked whether installing at a
quiet moment should be the default:
> yes let's make install when quiet the default

This supersedes "updates should ask" (above) and the rule that updates install only on quit or when
asked (SPEC I-4).

## 2026-10-31: `umi://open` links

Agents on the server write files into `~/best` repositories (for example
`desk/generated/2026-11/2026-11-01-lizzie-storage.md`), push them, and send Alejo a link. The brief
(relayed by Alejo's agent, not his own words): `umi://open?path=<path relative to ~/best>` opens the
file in Umi's editor as `open FILE` does, pulling the repository first if it is behind, and refuses
paths that escape `~/best` (SPEC I-6).

## 2026-11-02: comments on documents in the editor (BRIEF-comments-and-pane-sizes.md)

> when I select text in Umi I want it to offer me the option of leaving a comment on the doc, on a
> manner similar to google docs. see how roughdraft handles comments for inspiration and make sure
> comments are visible to you. main use case is reacting to the documents you present here.

(SPEC E-11.)

## 2026-11-04: even pane sizes after a resize (BRIEF-comments-and-pane-sizes.md)

> when I resize a panel, the remaining panels split the remaining screen equally.

Clarified the same day:
> only the panes that have not been manually resized shrink/grow in response to other pane resizing.

This supersedes "dragging a divider changes only the two panes beside it" (SPEC L-19): a pane sized
by hand keeps its size, and the panes not sized by hand on each side of a dragged divider share
that stretch equally.

## 2026-11-04: files open in panes; dragging a pane to the previous or next tab

> what I care about is that by default new files should be opened on a new pane, up to three per tab,
> then go to new tab. and if opened from umi the file should show on a pane next to the pane that
> called to open it
>
> also, dragging pane to top center should move to prev tab and to down center to next tab

## 2026-11-04: Warp's blacks

> also, make umi use the same blacks as the warp blacks I currenlty use (the defaults I think)

His Warp follows the system theme, which in dark mode is Warp's default "Dark" theme (background
`#000000`). Corrected 2026-11-05: the theme built into Warp (`themes/default_themes.rs`) is
`#050505` with the cursor `#19AAD8`; `#000000` came from the themes repository's YAML. His screenshot
`reference/warp-blocks.png` measures `#050505`.

Then:
> though let's use warp's terminal color config as well if it's straightforward to implement

## 2026-11-04: stacks

> also, if I drag a session on top of another, they should come to occupy the same pane space and be
> accessible through the cmd [] shortcuts + a small tab thing at the top similarly to what we
> currently do for files

With files in panes of their own (above), the editor's file tabs became this strip: any panes can
share a place, files included.

## 2026-11-04: three features removed

Relayed by Alejo's agent, not his own words; Alejo approved: remove the Settings shortcuts editor
(⌘, opens the config file in Umi's editor instead, as Ghostty does, and `umi shortcuts` stays;
SPEC L-17), the copy of Tern's state on the first launch (both Macs already have Umi state), and
`umi://open` links (documents from the server are read and edited on a web page the agent server
serves).

## 2026-11-05: the rest of Warp

> Implement, test, and ship ... to match all the unchosen gaps against warp features except those
> that would add actions on click ... I basically only use the warp features I can access from the
> keyboard

Then:
> go. let's add the warp right click options as well if that's not already included

Keyboard features, looks and Warp's right-click menu items are in; other click- or hover-only
gestures are out.

- The sidebar (SPEC S-1 to S-4, S-8, S-13, S-14): Warp's vertical tabs look, "Search tabs...",
  ⌘1–⌘9 hints while ⌘ is held, renames in the row, its row menu with tab groups, and each window
  showing or hiding its own sidebar (⌘B, ⌘\).
- The file editor (SPEC E-4, E-21 to E-24): Warp's code view (terminal font, no soft wrap, line
  numbers, current line, marks against the last commit, tree-sitter colors), its find and replace,
  ⌃G, ⌘/, ⇧⌘S, the "File saved." toast, the file pane header with Warp's ⋯ menu for each view (the
  same menu on a right-click of the header is an Umi addition), and file chips with type icons.
  Warp's right-click items in a file's text (Go to definition, Find references) need a language
  server and are not in (COMPROMISES).
- Project explorer and global search: the explorer's keys, look, file watching, hidden and ignored
  files, active-file reveal and Warp's right-click menu; global search on ⇧⌘F and ⌃3 (SPEC S-2).
- Palettes and the shortcuts page: one palette with Warp's filters (`files:`, `sessions:` …) and its
  empty state, Warp's look for the palette and its rows, "Create a file named …" in ⌘O, and ⌘/ for
  a shortcuts page (SPEC L-14 to L-17). Warp's palette has no right-click menu.
- How the terminal looks: Warp's built-in Dark colors (`#050505`, cursor `#19AAD8`), its selection
  and contrast rule, Hack 13 with rows 1.2× the font size and no ligatures, its padding (none for
  full-screen programs), its rounded 3-point bar cursor blinking every 500 ms, its scrollbar and
  silent bell; blocks that count Ctrl-C and SIGPIPE as success, show no running time in the first
  second and carry Warp's header (environments, user@host over SSH, git branch); the folder box
  with the folder alone, cut at 40 characters (SPEC S-5, S-10 to S-12).
- Panes, splits, the terminal's right-click menu, synchronized input and zoom (SPEC L-19, L-31,
  L-32, L-33).
- The Markdown preview (SPEC MD-1 to MD-5, E-2): Warp's look, code blocks with highlighting, Copy
  and Run in terminal, Mermaid diagrams, find (⌘F ⌘G ⇧⌘G), Rendered / Raw with ⌘E, and Warp's
  right-click items in the preview.
- Saved layouts (Warp's launch configurations; SPEC L-21): YAML files in
  `~/.config/umi/launch_configurations`, ⌃⌘L to open one, File ▸ Save New Launch Configuration…,
  "Save as New Config" in a sidebar row's right-click menu, `umi layout ls|save|open`. ⌃⌘T stays
  Umi's Move Pane to New Tab, so Warp's tab-configs menu key isn't added.
- Agent status, attention, inbox, toasts and the update note (SPEC S-3, AG-24, I-4, L-9).

## 2026-11-07: no previous/next tab targets over the panes

> let's remove the drag and drop to the center top or bottom to put on next or previous tab but keep
> the drop on sidebar

## 2026-11-07: front matter collapsed

> frontmatter takes too much vertical space

Of the prototypes shown, Alejo picked "collapsed to one line": the front matter shows as one muted
line with the title, the date and how many keys are left, and opens to a compact table.

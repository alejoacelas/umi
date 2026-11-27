# New-pane project ranking and agent icons

Projects with Claude Code or Codex transcript history rank before unused fuzzy matches. Exact path browsing keeps its existing ordering. History scanning runs separately from session monitoring and caches results for one minute, keeping repeated searches responsive.

The picker uses branded icons for Claude Code, Codex and Antigravity in session rows, creation buttons and the new-session row. Antigravity launches through `agy --dangerously-skip-permissions`; its exact executable identifies the session because it has no Umi hooks. The selector wraps in narrow panes and cycles all four choices in either direction with Tab.

Verified on mac-air-2 in an isolated native app: real Claude/Codex transcript fixtures affect rendered ordering, nonmatches stay excluded, path browsing and Enter selection work, icons load, every selector button works, Tab/Shift-Tab cycle correctly, and Enter routes the chosen command. The combined build's initial history scan took 1.93 seconds; a cached response took 0.11 seconds. Screenshot inspection found no clipping. Updated the signed installed Umi Next; all six existing live sessions survived its UI restart.

The follow-up reduces agent selectors to 24×24 icon-only buttons, with names retained as tooltips and accessible labels. The primary row says “New session” to keep attention on starting work. Re-ran the existing picker interactions on mac-air-2 and inspected the compact layout screenshot; all controls passed unchanged.

The folder path now appears only while searching folders, leaving the normal new-session view uncluttered. Codex past-session names now come from its title index or current user-message schema; the old reader missed both and exposed rollout filenames. Verified indexed names and a real prompt after a long preamble in the native picker on mac-air-2, plus hiding/restoring the folder path through slash, Escape and the folder hint. Installed the signed update with existing live sessions retained.

⌘D now opens the picker in a full-height column at the far right of its tab. The picker takes its folder and project from the pane that had focus. On mac-air-2, real ⌘D presses from a left pane and a lower-left pane reproduced the old placement before the change and opened the focused picker beyond every existing pane afterward.

⌘D now opens a session switcher across projects. A row shows the session name and project. Waiting work appears first, and a snoozed session returns there when its turn ends or its timer expires. New-session controls and past transcripts have their own views. On mac-air-2, keyboard and mouse checks confirmed that an open session kept its pane and a snoozed session reattached in the rightmost slot. A real shell launched from New in the same test.

The folder chooser gives the name its full width before allocating room to the parent path. In a 194 px row on mac-air-2, “Umi” previously had only 3.3 px of space. The same row now shows the full name, and a 115-character folder name wraps within the row.

Folder discovery now filters candidates before displaying them. On mac-air-2, the previous picker showed a remembered temporary folder under both aliases and suggested linked worktree descendants. The updated picker excluded those locations from suggestions and direct path searches while retaining the main checkout.

Typing a name in the switcher now selects creation, including for an exact match. The Air test confirmed the original project and subfolder, all four launch routes, and explicit selection of an existing session. The signed Umi Next update was installed on the main Mac and its six running sessions survived the UI restart.

## Session names in the pane creator

The picker gives each Claude Code or Codex conversation its Umi name before its first prompt. Codex needs a separate creation step because its terminal accepts a thread ID to resume but has no name argument. Umi records that ID when attaching the terminal because a shared Codex service can start with a different environment from the pane.

The pane header, switcher and history follow the agent’s saved name. Umi’s Rename writes through the agent’s naming mechanism so the next resume sees the same title. This keeps text a user has started typing in the terminal intact.

Verified on mac-air-2 with real sessions. Both agents accepted the picker name before their first prompt, reflected a native slash rename in Umi, and retained a Umi rename after a clean exit. Claude also accepted a rename from Umi before creating its first transcript. The history picker showed a Claude rename recorded after a long conversation.

## Choosing the folder before launch

Enter on a typed name opens the same chooser as slash. The current directory appears immediately so accepting it works while the rest of the folder list is loading. Choosing the folder keeps the name and agent for the final launch.

An unnamed Claude or Codex session starts with its native automatic naming enabled. For Codex, saving the empty thread in its existing unsectioned state gives the terminal an ID to resume without assigning a title. A real Codex terminal using a local model fixture generated a title after its first turn and saved it under that ID.

Confirming a typed name now commits to launching, so choosing the folder starts the session immediately. Opening the folder chooser with slash still lets the user set the folder before committing to launch. An isolated native app on mac-air-2 received two Enter key events through its web layer. The daemon reported the typed name and chosen working directory after the second event.

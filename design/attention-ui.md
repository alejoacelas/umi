# Attention UI

The visual pieces Umi adds over Warp. Each was chosen from prototypes in `prototypes/`, named in
brackets.

## Panes per tab

A tab shows at most three panes; the others are hidden. "Three" counts places on show, whatever the
direction of the splits. Anything that adds a pane to a tab already showing three (a split, opening
a file, a move, a reopen, a launch configuration, focusing a hidden pane from the palette or the
CLI) brings it in and the `strip.make-room` slot hides one. A launch configuration with more than
three panes per tab opens the rest hidden, and saving one includes hidden panes. After a close,
focus goes to the pane on show used most recently; hidden panes don't come in by themselves.

## Hidden panes

Any pane can be hidden. It leaves its tab's layout, stays in its tab, and its program keeps
running. `umi pane hide P --until 'agent.done=false or agent.status=needs_input'` brings it back
when the condition holds. Coming back never moves keyboard focus.

## The pane strip [where-panes-live.html, option C; pane-strip.html]

- It sits in the window's title bar, which is empty today, so it adds no height.
- It lists every pane of the tab: those on show, then hidden ones, dim.
- Chips keep their places. They change places only when a hidden pane is brought in and takes
  another pane's place: the two swap.
- A pane's chip is its drag handle. File and web headers lose their grip; terminals lose
  Ghostty's hover handle.
- ⌘[ and ⌘] walk every pane of the tab: those on show, then the hidden ones. Stepping onto a
  hidden pane shows it in the place it would take; releasing ⌘ there keeps it. Stepping on puts
  it back and shows the next one; releasing ⌘ back on a pane that was on show leaves the layout as
  it was. A pane brought in with ⌘] appears at the right end of the tab, with ⌘[ at the left end;
  the pane `strip.make-room` picks is hidden and the others close up. In the strip, the incoming
  and outgoing chips swap places.

## The pane indicator [pane-indicator.html]

One small mark per pane replaces the cyan focus line and the agent marks.

- **States:** working, needs you, finished and not seen, nothing. From `agent.status`: working is
  working; `needs_input` and `error` are needs you; `idle` and `stopped` are finished and not seen
  while `changed_at > seen_at`, then nothing. Quiet colours: only "needs you"
  (amber) is in full colour; working and finished are muted. Nothing animates.
- **Place:** the pane's bottom right, by the prompt. The same mark shows on the pane's strip chip;
  a tab's sidebar row shows the mark of the pane `tab.summary` picks.
- **Focus:** the focused pane's mark is a little larger and brighter, and the pane slightly
  brighter, subtle enough that other panes don't look dull. The amount is a setting, tuned in the
  dev build.

## The drawer [drawer.html, option B]

A place that rises over the lower half of the tab without changing its layout, shown and put away
by a key. It holds whatever a binding sends it. ⌃⌘M shows and hides the manager pane (the pane
with `role=manager`) in the drawer by default: `key.ctrl+cmd+m = drawer toggle 'role=manager'`. A pane waiting for the
drawer shows as a thin line along the window's bottom edge with a short label. A drawer pane can be
moved into the tab's layout or hidden. The drawer belongs to the window, not a tab: its panes
don't count toward a tab's three and don't appear in the strip.

## Moving panes [move-literal.html, option A]

- Hold ⌃⌘. The move starts at the first arrow press, so ⌃⌘ shortcuts with letters are unaffected.
  ←/→ move the pane within its tab. ↑/↓ carry it to another tab, where ←/→ pick its
  spot. Letting go of ⌃⌘ lands it; Esc cancels; ⌘Z undoes.
- The window shows the target tab exactly as it would look with the pane landed, including which
  pane would be hidden.
- The sidebar comes out for the move, even if hidden. Every row lists its tab's panes and their
  indicators; the target row shows where the pane lands.
- Targets include the tab the pane came from and a new tab, which is last in the ↑/↓ order. A
  collapsed tab group opens while the pane is over it.
- Tabs move with ⌃⇧↑/↓.

## Open

1. What the indicator shows for a pane with no agent (a long-running command, a file with unsaved
   changes).
2. Keys for sending other panes to the drawer and cycling through them.

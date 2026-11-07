# Attention UI

The visual pieces Umi adds over Warp. Each was chosen from prototypes in `prototypes/`, named in
brackets.

## Panes per tab

A tab shows at most three panes; the others are hidden.

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
  it was. A pane brought in with ⌘] appears on the right, with ⌘[ on the left. The
  `strip.make-room` slot picks the pane that leaves.

## The pane indicator [pane-indicator.html]

One small mark per pane replaces the cyan focus line and the agent marks.

- **States:** working, needs you, finished and not seen, nothing. Quiet colours: only "needs you"
  (amber) is in full colour; working and finished are muted. Nothing animates.
- **Place:** the pane's bottom right, by the prompt. The same mark shows on the pane's strip chip;
  a tab's sidebar row shows the mark of the pane `tab.summary` picks.
- **Focus:** the focused pane's mark is a little larger and brighter, and the pane slightly
  brighter, subtle enough that other panes don't look dull. The amount is a setting, tuned in the
  dev build.

## The drawer [drawer.html, option B]

A place that rises over the lower half of the tab without changing its layout, shown and put away
by a key. It holds whatever a binding sends it, such as the manager pane. A pane waiting for the
drawer shows as a thin line along the window's bottom edge with a short label. A drawer pane can be
moved into the tab's layout or hidden.

## Moving panes [move-literal.html, option A]

- Hold ⌃⌘. ←/→ move the pane within its tab. ↑/↓ carry it to another tab, where ←/→ pick its
  spot. Letting go of ⌃⌘ lands it; Esc cancels; ⌘Z undoes.
- The window shows the target tab exactly as it would look with the pane landed, including which
  pane would be hidden.
- The sidebar comes out for the move, even if hidden. Every row lists its tab's panes and their
  indicators; the target row shows where the pane lands.
- Targets include a new tab and the tab the pane came from.
- Tabs move with ⌃⇧↑/↓.

## Open

1. What the indicator shows for a pane with no agent (a long-running command, a file with unsaved
   changes).
2. Which keys show, hide and cycle the drawer.

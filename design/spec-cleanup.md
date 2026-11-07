# What leaves the current spec

Items in `acceptance/SPEC.md` (and the code behind them) that go, so the spec becomes Warp parity
plus the documents next to this one.

## Decided

- **Agent sessions, AG-1 to AG-17 and AG-20 to AG-23,** the orchestration parts of "How the
  product is used", the "Core: agent sessions" tier and the delivery-phase history: headless
  sessions, the read-only view, Take Over, `agent start/send/wait/…`. They move to scripts and
  skills outside Umi. AG-18 and AG-19 stay, reworded: the hook plugin writes `agent.*` on its pane
  and keeps its status truthful (see primitives.md).
- **Anything that depends on Umi's own sessions:** I-4's quiet moment counts panes (each at its
  prompt, or running an agent whose `agent.status` is idle with nothing typed), not sessions;
  `doctor` reports whether the hook plugins are installed and current instead of requiring
  `claude`, `codex` or `git`; R-3, R-6 and R-7 speak of panes, not sessions.
- **Warp's coloured status badges and Warp's tab-wide "seen" rule** (on `warp/parity`): the pane
  indicator and per-pane `seen_at` replace them.
- **The hand-placed divider rules in L-19.** Panes share space as in Warp; a dragged divider stays
  where it is dropped, with no further rules.
- **Keyboard resizing of splits** (⌃⌘ arrows).
- **The fixed attention behaviour:** S-3's agent marks, the cyan focus line and L-12's fixed jump
  order. They become slots and the pane indicator.
- **The inbox and toasts** (⇧⌘U, ⌃⌘U, AG-24, on `warp/parity`). The pane indicator, `jump` and
  the Dock badge cover them. The update note needs a home of its own.
- **Stacks (M-7)**, the "Stack here" drop zone and stack chips: hidden panes and the pane strip
  replace them. A file pane's chip keeps the file-type icon and the unsaved dot.
- **E-9's "three panes, then a new tab" rule for opening files:** a file opens to the right of the
  calling pane, and `strip.make-room` hides one if the tab already shows three.
- **The Docs tab as a stack (E-10).** It stays an ordinary tab named Docs: Markdown opened from
  Finder opens there, to the right of its panes, under the same three-pane rule. Other text files
  keep E-10's routing to the tab with the closest folder.
- **⇧⌘[ as "back through the tabs visited" (L-11).** ⇧⌘[ and ⇧⌘] are Warp's previous and next tab
  in sidebar order.
- **⌃⌘←/→ "move pane to the previous or next tab"** and **⌃⇧←/→ "move tab"**, replaced by the
  keyboard moves in [attention-ui.md](attention-ui.md).

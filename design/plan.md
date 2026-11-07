# Implementation plan

Builds the design in `design/` on top of the Warp parity work. Each step is one branch from main,
merged only when it passes the checks below, so main always works and every step can ship.

## How each step is checked

1. The step updates `acceptance/SPEC.md`, `acceptance/CLI.md` (from `design/cli.md`) and the tests
   for what it changes, and records changed tests in `acceptance/TEST_CHANGES.md`.
2. It runs in the dev build (`app/dist/dev.sh`): every key, click and CLI command the step adds is
   tried by hand and its result read back.
3. The acceptance suite passes on the other MacBook Air, in a worktree, under the screen lock.
4. It merges into main and is pushed. A release follows the steps marked "release".

## Steps

0. **Start from Warp parity.** After `2026-10-26-umi-e3` ships 0.9.0, merge `warp/parity` into
   main.

1. **Take orchestration out.** Remove Umi-run agent sessions: the session engine and drivers, the
   read-only view and Take Over, `agent *` commands, the Agent Sessions menu and palette entries,
   the inbox and toasts, the Warp-coloured badges and the tab-wide "seen" rule. Keep the hook
   plugin, now writing per-pane agent state through `umi hook`, and restarting agents in panes after
   a relaunch. Rewrite the update quiet-moment rules around panes. *Release.*

2. **Pane data.** Attributes on panes, tabs and windows, including single-holder attributes;
   `seen_at`, `changed_at` and `agent.*` as attributes; the activity log and focus log; events
   carrying their cause; `pane set/unset`, `ls` with attributes, `log`, `focus-log`.

3. **Queries, lists and slots.** The query syntax in selectors and `ls --where`; named lists, slots,
   key bindings and palette commands in `~/.config/umi/config` and `~/.config/umi/commands/`;
   `go`, with ⌃⌘J/K on `go --next jump` / `go --back`; today's attention behaviour rebuilt as the
   slots' defaults. *Release.*

4. **Hidden panes and the pane strip.** `hide`/`show [--until]`; the three-pane limit and
   `strip.make-room` for every way a pane arrives; the strip in the title bar, its chips as drag
   handles; ⌘[ ⌘] walking panes on show then hidden ones, landing on release of ⌘. Remove stacks,
   E-9's new-tab rule, the file and web headers' grips and Ghostty's hover handle; the Docs tab
   becomes ordinary.

5. **The pane indicator.** The mark at each pane's bottom right, on strip chips and on tab rows via
   `tab.summary`; the subtle focus treatment as a setting; remove the cyan focus line.
   *Release.*

6. **Moving panes and tabs.** Hold ⌃⌘ with arrows, with the landed-tab preview and the sidebar
   listing each tab's panes; ⌃⇧↑/↓ for tabs; ⇧⌘[ ⇧⌘] as Warp's; remove keyboard split resizing,
   ⌃⌘←/→ and L-19's hand-placed divider rules.

7. **The drawer.** The bottom drawer, its waiting line, `drawer` actions, ⌃⌘M for the
   `role=manager` pane. *Release.*

Steps 1–3 come first because everything after reads attributes and slots. Steps 4–7 touch the
same views (sidebar, split tree, title bar), so they run one after another.

## Who builds it

One worker per step, in its own worktree, supervised from a session that reviews each step against
the design before merging. Steps run in order.

## Decisions before starting

1. Run the steps as a workflow (one worker per step, each reviewed before merge). Recommend: do.
2. Release after steps 1, 3, 5 and 7, each with `release.sh` from this Mac and installed on both
   Macs. Recommend: do.
3. Merge `warp/parity` into main once 0.9.0 is out, as step 0. Recommend: do.
4. If a step finds the design unclear or unworkable, the worker stops that point and it comes back
   to Alejo in one list; the rest of the step carries on. Recommend: do.

# Umi's design

Umi is a macOS terminal for keeping track of many coding agents at once: Warp's windows, tabs and
panes on Ghostty's terminal, plus primitives that let the user and their scripts decide what
deserves attention. Running and steering agents lives outside Umi, in scripts and skills that use
the `umi` CLI.

The baseline is Warp parity: Warp's source at commit `6398d1e` (2026-10-03), `~/dev/warp`, vertical
tabs on, as written down in the "Warp parity" requirements of `acceptance/SPEC.md` and the audit in
`WARP-PARITY.md`. Each document below is self-contained:

| Document | What it covers |
|---|---|
| [warp-differences.md](warp-differences.md) | Every way Umi behaves differently from that Warp, and why |
| [primitives.md](primitives.md) | Pane data, queries, slots, actions and logs: what scripts and agents build on |
| [attention-ui.md](attention-ui.md) | The pane strip, the pane indicator, the drawer and keyboard moves |
| [spec-cleanup.md](spec-cleanup.md) | What leaves the current spec |
| [cli.md](cli.md) | The proposed `umi` CLI contract |
| [plan.md](plan.md) | The implementation steps and how each is checked |
| [ideas.md](ideas.md) | Skills, scripts and config to build on the primitives |

Prototypes for the visual choices are in `prototypes/`.

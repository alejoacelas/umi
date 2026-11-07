# Brief: build Umi's new design

Build the design in `design/`, following `design/plan.md` from step 0 to step 7, until the finished
product is ready for Alejo to review. Read `AGENTS.md` first for how to build, test and release.

## Sources of truth

- `design/README.md`, `warp-differences.md`, `primitives.md`, `attention-ui.md`,
  `spec-cleanup.md`: what Umi must do.
- `design/cli.md`: the CLI contract. It replaces `acceptance/CLI.md` as the steps land. Its
  "Choices made in this draft" were made without Alejo; build them as written.
- `design/plan.md`: the steps, their order and how each is checked.
- `design/prototypes/*.html`: the agreed look, named in brackets in `attention-ui.md`.

Where these and `acceptance/SPEC.md` disagree, the design wins; update the spec to match.

## What Alejo approved

In his words: "go. have clean session orchestrate the whole thing", and for unclear points: "it
should log those but keep building so I can review the final product at the end". With that, he
approved:

- running the steps as a workflow, one worker per step in its own worktree, each reviewed against
  the design before it merges into main;
- merging `warp/parity` into main as step 0, once session `2026-10-26-umi-e3` has published 0.9.0
  (check `gh release view v0.9.0 -R alejoacelas/umi`); leave that session's worktrees alone;
- releasing with `app/dist/release.sh` after steps 1, 3, 5 and 7, and installing each release on
  the other MacBook Air (`ssh mac-air-2`). On this Mac, leave the install to Umi's own updater,
  which waits for a quiet moment; never run `umi update --now` here, because Alejo is using it.

## How to work

- Each step: its own branch and worktree; update SPEC, CLI.md, tests and `TEST_CHANGES.md` for
  what it changes; try every new key, click and command in the dev build (`app/dist/dev.sh`) and
  read the result back; pass the acceptance suite on mac-air-2 under `lockf -k ~/umi-screen.lock`;
  merge into main and push. Never weaken a test to make it pass.
- When the design is unclear or a choice turns out unworkable, make the closest reasonable choice,
  record it in `design/build-log.md` (what, where, why, what Alejo should check), and keep
  building. Don't stop to ask.
- Keep `design/build-log.md` current: one section per step with its status, what changed, what
  was verified and how, and the open points.
- Come back to Alejo only for something that needs him in person (a permission grant, a login,
  a locked screen on mac-air-2 that blocks every test).

## Done

All eight steps merged and released, `design/build-log.md` complete, and a final message here
listing: what shipped in which release, every logged choice for Alejo to review, and how to try
the result.

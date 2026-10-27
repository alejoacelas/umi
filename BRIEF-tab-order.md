# Brief: tabs keep their order (Warp's behaviour)

Alejo will not supervise this run. Make reasonable decisions yourself, record them in
`DECISIONS.md`, and keep going until the finish criteria are met. Do not stop to ask
questions. Work in `~/best/projects/2026-10-26-umi` (read its `AGENTS.md` first). Commit
early and often, and push after every commit. Never commit or print secrets.

## The change

Alejo's words: "fix the tab reordering? right now it has a custom logic and I want to have the
standard behavior from warp that doesn't switch tab order depending on recency".

Today `UmiTabOrder` (`app/macos/Sources/Features/Umi/UmiNavigation.swift`, spec S-7) moves the
selected tab to the top of the unpinned tabs and moves tabs whose agent stopped to just below
it. Replace that with Warp's behaviour:

1. Selecting a tab never moves it, by any route (click, ⌘1–9, ⌘⇧[ / ⌘⇧], `umi tab focus`,
   notifications, going back/forward, reopen).
2. An agent finishing its turn never moves its tab. The tab still shows its attention mark.
3. Tabs move only when the user moves them: dragging, `umi tab move`, Move Tab Up/Down,
   `tab new --index`, pinning and unpinning (pinned tabs stay first).
4. New tabs open where Warp opens them by default. Check what Warp does and what Umi does
   today, and keep Umi's current placement if it already matches.

Remove the machinery that only existed for the old rule (the settle delay/freeze, pending
stops, placed-by-hand tracking) rather than leaving it dormant, and simplify its callers.
Update `acceptance/SPEC.md` (S-7 and anything that refers to it), `acceptance/REQUESTS.md`
(add Alejo's words above, dated 2026-10-27, superseding the earlier request), `CLI.md` if it
describes the order, the tests that assert the old order (`test_umi_nav.py`,
`test_umi_panes_ui.py`, others you find), and the Swift unit tests. Add tests that prove
selection and agent stops leave the order alone.

## Verify and release

1. Build, run the acceptance suite with fake agents and the Swift unit tests, and fix what
   breaks. If the screen is unlocked, also run the UI tests (`-m ui`); if it's locked, say so in
   the report.
2. Run Codex as an adversarial reviewer (`codex exec --dangerously-bypass-approvals-and-sandbox`
   or `codex review`) over the change: tabs that can still move on their own, broken
   drag/move/pin paths, stale references to the old rule. Verify each finding, fix the real
   ones, and repeat until a round finds nothing material.
3. Publish release 0.6.1 with `app/dist/release.sh` and update this Mac's installed Umi to it.
   Tern is still running on this Mac with a live agent session: do not quit, update or touch Tern.

Disk space is tight (about 5 GB free). If a build runs short, you may delete Xcode DerivedData
folders for Ghostty/Tern builds (regenerable caches); delete nothing else outside this run's
own files.

## Finish criteria

- Selecting tabs and agents finishing turns never reorder tabs; manual moves still work.
- Tests pass; Codex's last round finds nothing material; 0.6.1 is published and installed here.
- Spec, requests, docs and `DECISIONS.md` are current; everything is committed and pushed.
- A short `REPORT-tab-order.md` says what changed and anything you could not do.

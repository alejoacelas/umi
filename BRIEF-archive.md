# Brief: build the tab archive

Build `design/archive.md` and release it as 0.13.0. Read `AGENTS.md` first for how to build, test
and release, and `design/build-log.md` for how the last build went (the mac-air-2 signing setup,
dialogs that break UI tests).

Alejo approved the design as written and asked to carry it through to the release without checking
in. Where the design is unclear, make the closest reasonable choice, record it in a new "Archive"
section of `design/build-log.md` (what, where, why, what Alejo should check), and keep going.

- Work on a branch in its own worktree. Update `acceptance/SPEC.md`, `acceptance/CLI.md` and
  `design/cli.md`, the tests, and `acceptance/TEST_CHANGES.md`.
- Try every new key, click and command in the dev build (`app/dist/dev.sh`) and read the result back.
- Pass the full acceptance suite, UI tests included, and the Swift tests on mac-air-2, under
  `lockf -k ~/umi-screen.lock`. Never weaken a test.
- Merge into main, push, release 0.13.0 with `app/dist/release.sh`. Leave installing on this Mac to
  Umi's updater; never run `umi update --now` here.
- Come back to Alejo only for something that needs him in person (a locked screen on mac-air-2, a
  dialog only he can answer).

Done: 0.13.0 published, the build log's Archive section complete, and a final message listing what
shipped, the choices to check, and how to try it.

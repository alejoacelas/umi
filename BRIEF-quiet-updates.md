# Brief: updates install themselves when nothing would be lost

Alejo will not supervise this run. Make reasonable decisions yourself, record them in
`DECISIONS.md`, and keep going until the finish criteria are met. Do not stop to ask
questions. Work in `~/best/projects/2026-10-26-umi` (read its `AGENTS.md` first; the tab-order
change, release 0.6.1, has just landed). Commit early and often, and push after every commit.
Never commit or print secrets.

## Why

Alejo develops Umi on this Mac and uses it all day on his main Mac. He wants each tested
release to reach the main Mac without interrupting his work and without him having to act.
His words (2026-10-27): "yes let's make install when quiet the default". This replaces I-4's
"a background check asks first" and the rule that updates install only on quit or when asked.

## The change

1. **Default behaviour.** A background check that finds a newer signed release downloads and
   verifies it without asking, then installs it at the first quiet moment and relaunches.
   Check about every 15 minutes (keep `UMI_UPDATE_CHECK_SECONDS`). `umi update` checks at once.
2. **Quiet** means all of these hold:
   - no agent turn is running in any session the app knows (managed or typed, AG-18), and no
     message is waiting to be delivered;
   - every pane is either at a shell prompt with no foreground program and nothing typed, or
     shows an idle agent (a live Claude Code/Codex interface with nothing typed in its input, or
     a read-only view);
   - no editor or other window holds unsaved changes that a relaunch would lose;
   - the user hasn't typed or clicked in the app for 2 minutes.
   Decide how to detect each from the code (shell integration prompt marks, the pty's foreground
   process group, agent states); when a pane's state can't be determined, it is not quiet.
3. **Notice.** Shortly before installing (about 30 seconds), show a notice in the sidebar, not
   a dialog: "Updating to X.Y.Z" with **Not now** (wait for the next quiet moment after at least
   1 hour) and **Install now**. Any activity during the countdown cancels it until the next quiet
   moment.
4. **After relaunch** everything comes back as after a quit (AG-7, AG-22): layout, working
   folders, and agent sessions in their panes, live ones live. Write a test that a `claude`
   the user typed in a pane with flags (for example `--dangerously-skip-permissions --model X`)
   comes back with the same conversation and the same flags; fix it if it doesn't.
5. **Settings and CLI.** `umi update --now` installs immediately; `umi update --status` says
   what is pending and why it isn't quiet yet (which pane or session). A config setting turns
   automatic installing off (back to asking first). Add `umi update --rollback`, which installs
   the previously installed version (keep its verified zip when installing a new one).
6. Keep every existing safety check: signature, hash, bundle id, version, code signature, the
   helper that swaps the bundle and rolls back on failure. An isolated or test instance
   (`UMI_STATE_DIR`) never updates the user's installed app.

Update `acceptance/SPEC.md` (I-4 and anything that refers to it), `acceptance/REQUESTS.md`
(Alejo's words above), `CLI.md`, `README.md` and the tests. Test the quiet detection with
fake agents and fake time (a busy pane, a running turn, typing, unsaved editor, all quiet).

## Verify and release

1. Build, run the acceptance suite with fake agents, the real-agent tests, and the Swift unit
   tests; fix what breaks. Run the UI tests (`-m ui`) if the screen is unlocked; otherwise say
   so in the report.
2. Run Codex as an adversarial reviewer (`codex exec --dangerously-bypass-approvals-and-sandbox`
   or `codex review`) over the change: updates installing while something is running, quiet
   detection that guesses, lost drafts or unsaved files, sessions that don't come back,
   rollback and downgrade paths, update loops. Verify each finding, fix the real ones, and
   repeat until a round finds nothing material.
3. Publish release 0.6.2 with `app/dist/release.sh`. Update this Mac's installed Umi to it,
   then publish a 0.6.3 that changes nothing but the version and check that this Mac's Umi
   installs it by itself at a quiet moment and comes back with its tabs and sessions.
   Tern is still running on this Mac with a live agent session: do not quit, update or touch
   Tern.

Disk space is tight. If a build runs short, you may delete Xcode DerivedData folders for
Ghostty/Tern builds (regenerable caches); delete nothing else outside this run's own files.

## Finish criteria

- Automatic install at quiet moments is the default; the cases above are tested.
- Tests pass; Codex's last round finds nothing material; 0.6.3 installed itself on this Mac.
- Spec, requests, docs and `DECISIONS.md` are current; everything is committed and pushed.
- A short `REPORT-quiet-updates.md` says what changed, how "quiet" is decided, and anything
  you could not do.

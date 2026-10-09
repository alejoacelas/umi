# Brief: the user's answers after phase 2

You are making a small follow-up to the app that two previous runs built in this folder. This run is
headless: nobody is watching and nobody can answer questions. Make decisions yourself, record them,
and finish.
- When something is genuinely the user's call, choose the option that keeps the most doors open.
  Note it under "Questions for the user" in your report, and keep going.
- Don't end your turn until the definition of done in section 3 is met, or you've hit a blocker you
  can't get around. Your last message is a short summary that points to `REPORT.md`.

## 1. What changed

Phase 2's report asked the user some questions. Their answers are at the end of
`acceptance/REQUESTS.md` ("Answers after phase 2"):
> script quits should not ask, updates should ask. license is good. default workers to backgroudn

They became these changes to `acceptance/SPEC.md` and `acceptance/CLI.md`:
- **I-4:** when a background check finds a newer version, the app asks before downloading or
  installing anything. The question never takes focus or blocks work, and stays available until
  answered. The "Check for Updates…" menu item and `<cli> update` count as a yes.
- **AP-3:** `agent start` runs a session in the background by default and shows nothing until asked.
  `agent open` still defaults to a new tab.
- **Confirmed as they are:** a quit requested by another process doesn't ask (phase 1's
  `COMPROMISES.md` lists it; it's now the user's decision), and the MIT license in the user's name.

Read `BRIEF-phase1.md`, `BRIEF.md`, `REPORT.md`, `DECISIONS.md` and `COMPROMISES.md` first. Phase 1's
and phase 2's notes and boundaries still apply.

## 2. Decisions you must make

Record each one in `DECISIONS.md`, with the options you saw, the pick and the evidence.
- **The update question.** How and where the app asks, how it stays available without taking focus,
  and what each answer does over time. This includes what a "no" or "later" means for later checks,
  how the question relates to an update already downloaded or staged by an older build, and what
  `update --check` and the menu show meanwhile.
- **Sessions with no pane.** Now that most workers never get one, decide how the user finds them,
  sees their state and opens them. Do the same for the orchestrator. Everything the user and
  orchestrator could see about workers before must still be reachable.

Also update everything that tells people or agents about the old default: the CLI's help, the
awareness note given to agents, and `REPORT.md`'s orchestrator guide.

## 3. Definition of done

- The full suite passes with the fakes, every phase, and the real-agent tests pass on cheap models.
  Same rules as `BRIEF.md` section 2: don't weaken a test; fix a wrong test and explain it in
  `acceptance/TEST_CHANGES.md`; add tests for what your changes make risky. One new test,
  `test_start_shows_nothing_by_default`, already covers AP-3's default.
- Tests show that a background check asks and downloads nothing until the answer is yes. Put
  product-specific ones in `tests/test_tern_extra.py`.
- **UI tests:** check `acceptance/conftest.py`'s `screen_locked()` before relying on a UI result,
  and never count a skip as a pass.
  - All 15 UI tests passed on phase 2's build with the screen unlocked.
  - The user may be at this Mac while you work, and UI tests take over its keyboard and mouse for
    about 30 seconds. Run them (`-m ui`) only before each review and before the release, not while
    developing.
  - Run them under `caffeinate -d -i` so the display doesn't sleep and lock the screen.
  - If the screen is locked anyway, check the behavior another way, as phase 1 did, and list the
    skipped tests.
- **Written checks:** run the ones your changes touch and judge their screenshots.
- **Adversarial review:** in `app/`,
  `codex review --base 68a15e8c7 -c model_reasoning_effort="high"`. Fix high and moderate findings,
  rebuild, rerun the suite, and review again. Stop when a round reports no high or moderate
  findings, or after 5 rounds. List what remains.
- **Release:** publish the reviewed build as a new minor version. Check that the copy installed on
  this Mac updates itself to it. That copy runs the old update behavior, so it updates as before.
- **Report:** add a short "After phase 2" part to `REPORT.md`, at the top, and keep the rest. It
  covers what changed, the decisions, test changes, review rounds, release, and questions for the
  user.

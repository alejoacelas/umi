# Brief: make Claude Code and Codex report the same pane states

`design/ideas.md` item 14 lists how each agent's hooks feed the pane indicator (`agent.status`) and
where Codex falls short: no hook for a question to the user or an idle prompt (Claude's
`Notification`), none for a failed turn (Claude's `StopFailure`, `PostToolUseFailure`), and it is
unchecked whether each agent's `Stop` input carries the last message that `agent.summary` and
`agent.done` need. Alejo asked to test this for real and change the app so both agents behave the
same. He approved carrying it through to a release without checking in. Read `AGENTS.md` first.

## Do

1. **Test both agents for real**, in panes of a dev build (`app/dist/dev.sh`) or on mac-air-2, with
   the installed `claude` and `codex` (codex-cli 0.164.0 here). Use cheap models and short prompts.
   Capture the raw hook input for each event (log what `umi-hook.sh` receives) for: a turn that
   finishes, a turn ending with `Status: done`, a question back to the user, a permission prompt, an
   interrupted turn (Esc / Ctrl-C), a failed turn (e.g. an invalid model or no network), a tool
   failure, and the agent exiting. Read the current Codex hooks documentation and source for the
   full event list; don't rely on memory.
2. **Write down the result** in `design/ideas.md` item 14: for each state, which event each agent
   sends, what its input carries (last message, or only a transcript path), and what Umi now does.
3. **Change the plugins and `umi hook`** (`app/macos/UmiPlugins`, `UmiAgentHooks`) so each state
   maps the same way for both agents wherever the agents make it possible: register any Codex event
   that covers questions, idle prompts or failures; read the last message from the transcript where
   the hook input lacks it; make `agent.summary`, `agent.done`, `agent.title` and `agent.session`
   come out the same. Where Codex has no event for a state, say so in item 14 and in SPEC (AG-19)
   rather than guessing from timing. Bump the plugin versions so installed copies update.
4. **Tests**: acceptance tests with the fake agents for every mapping (`acceptance/fakes/`), and one
   real-agent check per agent behind `ACCEPTANCE_REAL=1`. Update SPEC, `acceptance/CLI.md`,
   `design/cli.md` and `TEST_CHANGES.md`. Pass the full suite, UI tests included, and the Swift tests
   on mac-air-2 under `lockf -k ~/umi-screen.lock`; another session (the tab archive, 0.13.0) uses
   that Mac too, and the lock makes runs take turns. Never weaken a test.
5. **Release**: wait until `gh release view v0.13.0 -R alejoacelas/umi` succeeds, rebase onto main,
   rerun the suite, merge, push, and release 0.14.0 with `app/dist/release.sh`. Leave this Mac's
   install to Umi's updater; never run `umi update --now` here.

Record unclear choices in a new "Agent hooks" section of `design/build-log.md` and keep going. Come
back to Alejo only for something that needs him in person. Done: 0.14.0 published, item 14 and the
build log updated, and a final message listing what changed per agent, what Codex still can't
report, and the choices to check.

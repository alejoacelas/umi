# Brief: links that open a working session in Umi

Alejo wants the agent server to produce links ("work on this in Umi") that he clicks from the
docket and from Slack, and that open an agent session in a new Umi tab. Sessions run on this Mac by
default, in the right local folder, or on the server when the link says so. He approved building it
through to a release without checking in. Read `AGENTS.md` here and `~/best/ops/clerk/AGENTS.md`
(the docket, the `/o` page and the Slack messages live in that repository and run on the server).

## The design

1. **Tasks live on the server.** A command on the server (`umi-link`, in clerk) takes: a title, the
   folder (a path relative to `~/best`, plus the repository's git remote and branch when it is a
   repository), where to run (`mac`, the default, or `server`), the agent (`claude` default, or
   `codex`), and either a prompt or an agent session id to resume. It saves the task (JSON, an
   unguessable id) and prints two links: the page `https://agent-server…/<path>/<id>` and
   `umi://open?task=<url of the task's JSON>`.
2. **The page** shows the task (title, folder, where it runs, the prompt or the session) and an
   "Open in Umi" button to the `umi://` link. Slack messages use the page link (Slack doesn't make
   custom schemes clickable); the docket's items use the `umi://` link directly. Serve it beside
   `/o` and `/docket` with Tailscale Serve; reading tasks needs no login beyond the tailnet.
3. **Umi registers `umi://`.** `umi://open?task=URL` is accepted only when URL's origin is listed in
   `umi-web-origin`; anything else is refused with a note saying why. Umi fetches the task JSON and
   never runs anything the link itself carries. The same applies to `umi://` links clicked in a web
   pane or ⌘-clicked in a terminal.
4. **Opening on the Mac.** Find the local folder: first a checkout under `~/best` whose git remote
   matches the task's (search `~/best/*/*` and `~/best/orgs/*/*`), else the same path relative to
   `~/best`. Open a new tab named after the task, in front, with the agent started there
   (`claude --dangerously-skip-permissions` with the prompt, or `--resume ID`; codex likewise with
   `--dangerously-bypass-approvals-and-sandbox`). Don't switch the checkout's branch; when the task
   names a branch the checkout isn't on, the first line of the prompt says so. When no local folder
   exists, open the task on the server instead and say so at the top of the pane.
5. **Opening on the server.** The new tab runs `ssh -t agent-server` into the task's folder there
   (as the `agent` user, as `~/.claude/CLAUDE.md` says for agent work), inside tmux so it survives
   the pane closing, with the agent started the same way.
6. **Use it.** The `queue` skill (`~/best/areas/dotfiles/skills/queue`) and the docket's items get
   these links in place of the resume command to paste. Add `umi://open` to `design/cli.md` and
   a short section to `design/primitives.md`.

## How to work

- Umi: a branch and worktree; SPEC, `acceptance/CLI.md`, tests (the URL handler, the origin check,
  folder resolution, Mac and server runs with fake agents), `TEST_CHANGES.md`. Try every path in the
  dev build. Pass the full suite, UI tests included, and the Swift tests on mac-air-2 under
  `lockf -k ~/umi-screen.lock`; two other sessions (`umi-archive`, `umi-hooks`) take turns on it.
  Never weaken a test. Release as the next minor version after 0.14.0 once
  `gh release view v0.14.0 -R alejoacelas/umi` succeeds: rebase onto main, rerun, merge, push,
  `app/dist/release.sh`. Never run `umi update --now` on this Mac.
- Clerk: follow its AGENTS.md for tests and deploying to the server; commit and push.
- Try the whole path for real once Umi is released and installed on mac-air-2: make a task with
  `umi-link` on the server, click its Slack-style page link and its docket link on mac-air-2, and
  check the session opens in the right folder, for a Mac task and a server task.
- Record unclear choices in a "Session links" section of `design/build-log.md` and keep going.
  Come back to Alejo only for something that needs him in person.

Done: released, clerk deployed, the real end-to-end check passed, and a final message listing how
to make a link, what was verified, and the choices to check.

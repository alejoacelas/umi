# Umi

```sh
curl -fsSL https://github.com/alejoacelas/umi/releases/latest/download/install.sh | bash
```

A macOS terminal for working with coding agents, built on [Ghostty](https://ghostty.org) and modelled
on Warp: tabs and panes in a sidebar, live terminals you can move between panes, tabs and windows, a
Markdown editor beside your terminals, Claude Code and Codex sessions you can start, watch and steer,
and an `umi` command line that agents (and you) can drive everything from. Apple Silicon Macs, macOS
13 or later.

The command above downloads the latest release (and checks it against the release's checksum), puts
`Umi.app` in `/Applications` (or `~/Applications`), clears the download quarantine so macOS opens it
without asking, links the `umi` command into `~/.local/bin`, makes Umi the app for Markdown files, and
opens it. Nothing else needs to be installed first. `umi doctor` shows what Umi can find on this
machine (`claude`, `codex`, `git`).

Umi is named after the heroine of *From Up on Poppy Hill*, who raises signal flags over the sea every
morning (*umi* is Japanese for "sea").

## Coming from Tern

Umi was called Tern until 0.5.0. Tern can stay installed next to it; they don't share anything.

- The first time Umi opens, it copies Tern's windows, tabs, panes, sidebar, shortcuts and agent
  sessions from `~/Library/Application Support/Tern` (a copy: Tern's folder is never changed). A
  session that Tern is still running at that moment stays Tern's: Umi shows it, and Take Over
  continues it in Umi.
- The command is `umi` (was `tern`), the state folder `~/Library/Application Support/Umi`, the
  environment variables `UMI_*` (were `TERN_*`), the bundle id `dev.umi.app`, and the agent plugins
  `umi@umi` (were `tern@tern`). Updates come from this repository's releases.
- To remove Tern afterwards: `tern agent plugins remove`, then
  `rm -rf /Applications/Tern.app ~/.local/bin/tern ~/Library/Application\ Support/Tern`.

## Command blocks

In zsh, Umi looks like Warp while your shell stays zsh: the prompt starts at the bottom and output
builds upward, each command is a block with the folder it ran in, how long it took, the command in
bold and its output, failed commands are marked in red, and the prompt shows the folder in a box.
Full-screen programs (vim, less, agents' interfaces) get the whole pane. To keep zsh's own look, add
`shell-integration-features = no-umi-blocks` to `~/.config/umi/config`.

## Settings

Umi reads your Ghostty config (`~/.config/ghostty/config`), then its own, `~/.config/umi/config`, for
settings that only Umi should see (Ghostty never reads it). Umi's Settings (⌘,) edits shortcuts.

## Agents

`umi claude "task"` and `umi codex "task"` start a Claude Code or Codex session that works in the
background and opens in its own interface in a new tab once its first turn is done. Agents can
supervise other agents with `umi agent` (`umi agent --help` explains it in one screen): start
sessions, wait for them, steer them with messages, read their replies, and show one to you.
`umi agent open SESSION` shows a session read-only in a pane, with a Take Over button.

To know what agents do in its terminals, Umi installs a small plugin for Claude Code and one for Codex
when it starts (marketplace `umi`, in `~/.claude` and `~/.codex`, with the agents' own commands). They
report to Umi only inside Umi and do nothing anywhere else. `umi agent plugins` shows their state.

## Updates

Umi checks this repository's latest release in the background. When there's a newer version it asks
first, in a note at the bottom of the sidebar (Download, Later, Skip), and downloads nothing until you
say yes. "Check for Updates…" in the Umi menu, or `umi update`, also count as a yes. A downloaded
update's signature is verified, and it installs when you quit Umi (`umi update --now` installs and
relaunches at once). `umi update --check` looks for a newer version and `umi update --status` says
where things stand. Umi never quits by itself to install an update.

## Uninstall

```sh
umi agent plugins remove
rm -rf /Applications/Umi.app ~/.local/bin/umi ~/Library/Application\ Support/Umi ~/.config/umi
```

## This repository

The source and the releases. `app/` is the app, a fork of Ghostty with Ghostty's full history;
`acceptance/` is the outcome-only acceptance suite (spec, CLI contract, tests); the Markdown files at
the root are the briefs, decisions, compromises and reports of the runs that built it (Tern's runs
say Tern). [AGENTS.md](AGENTS.md) explains how to build, test and release.

## License

MIT, like Ghostty: see [LICENSE](LICENSE). Fonts embedded in the app are under the licenses in
[licenses/](licenses/). Umi's icon is its own (`app/dist/icon/icon.swift` draws it).

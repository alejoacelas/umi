# Hook inputs from the real agents, 9 November 2026

Every hook input Claude Code 2.1.319 and codex-cli 0.164.0 sent, one JSON line each
(`{"ts", "agent", "event", "ppid", "input"}`), written by `logger.py` registered for every event
each agent has. Claude Code ran in tmux with `--plugin-dir`; Codex with the hooks in the project's
`.codex/hooks.json` and `--dangerously-bypass-hook-trust`. Cheap models (Haiku, gpt-6-luna), short
prompts, in this order: a plain turn, a turn ending `Status: done`, a question, a permission prompt
(accepted, then declined), a failing command, interrupts (Esc, Ctrl-C), a model that doesn't exist,
exit. `design/ideas.md` item 14 summarises them.

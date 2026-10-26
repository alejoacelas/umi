#!/bin/sh
# Tern's hook: when this agent runs inside Tern, tell Tern what it's doing (its session's
# state for the sidebar, `tern agent ls` and supervisors). Anywhere else it does nothing and
# prints nothing. Usage (from hooks.json): tern-hook.sh claude|codex EVENT, hook input on stdin.
agent="$1"
event="$2"
quiet() { cat >/dev/null 2>&1; exit 0; }
# Only inside Tern: its terminals set TERN_CLI and TERN_STATE_DIR.
[ -n "$TERN_CLI" ] && [ -n "$TERN_STATE_DIR" ] && [ -x "$TERN_CLI" ] || quiet
# A session Tern runs headless: Tern reads the agent's own output instead.
[ -n "$TERN_HEADLESS" ] && quiet
# Tern loads its own copy of this plugin into sessions it shows live; other copies stay quiet.
root="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}"
if [ -n "$TERN_PLUGIN_ROOT" ] && [ "$TERN_PLUGIN_ROOT" != "$root" ]; then quiet; fi
exec "$TERN_CLI" agent hook "$event" --agent "$agent" --pid "$PPID" >/dev/null 2>&1

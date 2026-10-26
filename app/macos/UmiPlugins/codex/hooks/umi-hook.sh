#!/bin/sh
# Umi's hook: when this agent runs inside Umi, tell Umi what it's doing (its session's
# state for the sidebar, `umi agent ls` and supervisors). Anywhere else it does nothing and
# prints nothing. Usage (from hooks.json): umi-hook.sh claude|codex EVENT, hook input on stdin.
agent="$1"
event="$2"
quiet() { cat >/dev/null 2>&1; exit 0; }
# Only inside Umi: its terminals set UMI_CLI and UMI_STATE_DIR.
[ -n "$UMI_CLI" ] && [ -n "$UMI_STATE_DIR" ] && [ -x "$UMI_CLI" ] || quiet
# A session Umi runs headless: Umi reads the agent's own output instead.
[ -n "$UMI_HEADLESS" ] && quiet
# Umi loads its own copy of this plugin into sessions it shows live; other copies stay quiet.
root="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}"
if [ -n "$UMI_PLUGIN_ROOT" ] && [ "$UMI_PLUGIN_ROOT" != "$root" ]; then quiet; fi
exec "$UMI_CLI" agent hook "$event" --agent "$agent" --pid "$PPID" >/dev/null 2>&1

#!/bin/sh
# Umi's hook: when this agent runs in one of Umi's panes, write what it's doing on that pane
# (`umi hook`, which sets the pane's agent.* attributes). Anywhere else it does nothing and
# prints nothing. Usage (from hooks.json): umi-hook.sh claude|codex EVENT, hook input on stdin.
agent="$1"
event="$2"
quiet() { cat >/dev/null 2>&1; exit 0; }
# Only inside Umi: its terminals set UMI_CLI, UMI_STATE_DIR and the pane's UMI_PANE_ID.
[ -n "$UMI_CLI" ] && [ -n "$UMI_STATE_DIR" ] && [ -n "$UMI_PANE_ID" ] && [ -x "$UMI_CLI" ] || quiet
exec "$UMI_CLI" hook "$event" --agent "$agent" --pid "$PPID" >/dev/null 2>&1

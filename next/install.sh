#!/bin/bash
# Builds UmiNext.app from this checkout and installs it as ~/Applications/UmiNext.app, next to Umi.
#
# - Bundle id dev.umi.next, state in ~/Library/Application Support/Umi-next (or $UMI_NEXT_STATE_DIR
#   at launch): it never touches Umi, its state or its panes.
# - The web layer loads live from <source>/next/app/web: editing those files changes the running
#   app within a second. <source> is this checkout unless --source names another one.
# - Signed with Umi's stable local identity (app/dist/signing.sh), so macOS keeps the permissions
#   given to it. --adhoc signs ad hoc instead (a test Mac without that identity).
# - Reinstalling quits a running UmiNext first and starts it again; its sessions live in the daemon
#   and keep running. A daemon already running keeps its old binary until it is stopped
#   (umi-next-ctl daemon-stop, which refuses while sessions are alive).
# - Links ~/.local/bin/umi-next to the installed app's CLI.
#
# Needs libghostty in the checkout (app/macos/GhosttyKit.xcframework and app/zig-out/share, see
# AGENTS.md), or GHOSTTY_KIT / GHOSTTY_SHARE pointing at another checkout's copies.
#
#   next/install.sh [--source DIR] [--adhoc] [--no-open]
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$repo"
build_args=()
open_after=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) source_dir="$(cd "$2" && pwd)"; shift 2 ;;
    --adhoc) build_args+=(--adhoc); shift ;;
    --no-open) open_after=0; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $1" >&2; exit 2 ;;
  esac
done
[[ -f "$source_dir/next/app/web/index.html" ]] || { echo "install.sh: no next/app/web in $source_dir" >&2; exit 1; }

"$repo/next/app/build.sh" ${build_args[@]+"${build_args[@]}"}
built="$repo/next/app/build/UmiNext.app"
dest="$HOME/Applications/UmiNext.app"
mkdir -p "$HOME/Applications"

# The web layer and terminal.conf come from the source checkout.
/usr/libexec/PlistBuddy -c "Set :UmiNextSourceDir $source_dir/next/app" "$built/Contents/Info.plist"
identity="$(codesign -dvv "$built" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
codesign --force --sign "${identity:--}" "$built" >/dev/null 2>&1

if pgrep -xq UmiNext; then
  echo "install.sh: quitting the running UmiNext (its sessions keep running in the daemon)" >&2
  osascript -e 'tell application id "dev.umi.next" to quit' >/dev/null 2>&1 || true
  for _ in $(seq 50); do pgrep -xq UmiNext || break; sleep 0.1; done
  pgrep -xq UmiNext && pkill -x UmiNext || true
fi
# The old copy goes to the Trash, not rm.
[[ -e "$dest" ]] && trash "$dest"
cp -R "$built" "$dest"
# The CLI on PATH, as Umi links ~/.local/bin/umi.
mkdir -p "$HOME/.local/bin"
ln -sf "$dest/Contents/MacOS/umi-next" "$HOME/.local/bin/umi-next"
echo "installed $dest (web layer: $source_dir/next/app/web; CLI: ~/.local/bin/umi-next)"
[[ $open_after == 1 ]] && open "$dest"
exit 0

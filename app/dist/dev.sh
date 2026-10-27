#!/bin/bash
# Build Umi and run it next to the installed one, to try a change.
#
#   app/dist/dev.sh              build what changed, then (re)start the dev copy
#   app/dist/dev.sh --no-build   just (re)start the dev copy
#   app/dist/dev.sh --lib        also rebuild libghostty even if nothing outside app/macos changed
#   app/dist/dev.sh --fresh      start the dev copy with empty state (no windows from last time)
#   app/dist/dev.sh stop         quit the dev copy
#   app/dist/dev.sh umi ARGS…    run the dev copy's CLI against it (ls, send, read, …)
#
# The dev copy is the Debug build (app/macos/build/Debug/Umi.app, bundle id dev.umi.app.debug),
# which compiles incrementally and doesn't touch the ReleaseLocal build the suite tests. It runs
# as an isolated instance with its own state directory, $UMI_DEV_STATE_DIR (default
# ~/Library/Application Support/Umi-dev), so it keeps its own windows between restarts and never
# acts as the user's Umi: no copy of Tern's state, no agent plugins registered, no update checks.
#
# libghostty (everything in app/ outside app/macos) is rebuilt only when it changed since the last
# dev build; it is built ReleaseFast, as for a release, so panes don't show the debug-build banner.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
app="$root/macos/build/Debug/Umi.app"
state="${UMI_DEV_STATE_DIR:-$HOME/Library/Application Support/Umi-dev}"
stamp="$root/macos/build/.dev-lib-stamp"
log="$root/macos/build/dev-build.log"

running_pid() {
    pgrep -f "^$app/Contents/MacOS/umi-app" | head -1 || true
}

stop() {
    local pid
    pid="$(running_pid)"
    [[ -n "$pid" ]] || return 0
    # Quit this process only. Addressing the app by name or bundle id can reach the installed
    # Umi instead: both are called Umi.
    osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid).terminate" >/dev/null 2>&1 \
        || kill "$pid" 2>/dev/null || true
    for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
    kill "$pid" 2>/dev/null || true
}

case "${1:-}" in
    stop) stop; exit 0 ;;
    umi) shift; UMI_STATE_DIR="$state" exec "$app/Contents/MacOS/umi" "$@" ;;
esac

build=1; lib=0; fresh=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-build) build=0; shift ;;
        --lib) lib=1; shift ;;
        --fresh) fresh=1; shift ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "dev.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

if [[ "$build" == 1 ]]; then
    mkdir -p "$root/macos/build"
    # What libghostty is built from: the committed tree outside app/macos plus uncommitted changes.
    lib_hash="$(cd "$root" && { git ls-tree -r HEAD . | grep -v $'\t''macos/'; git diff HEAD -- . ':(exclude)macos'; git ls-files --others --exclude-standard -- . ':(exclude)macos' | xargs -I{} shasum {} 2>/dev/null; } | shasum | cut -d' ' -f1)"
    if [[ "$lib" == 1 || ! -d "$root/macos/GhosttyKit.xcframework" || "$(cat "$stamp" 2>/dev/null)" != "$lib_hash" ]]; then
        zig="${ZIG:-$HOME/.local/zig/zig-aarch64-macos-0.16.0/zig}"
        command -v "$zig" >/dev/null 2>&1 || zig="$(command -v zig || true)"
        [[ -n "$zig" ]] || { echo "dev.sh: needs Zig 0.16 (set ZIG=/path/to/zig)" >&2; exit 1; }
        echo "building libghostty…"
        (cd "$root" && "$zig" build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=false)
        echo "$lib_hash" > "$stamp"
    fi
    echo "building Umi.app (Debug)…"
    start=$SECONDS
    (cd "$root/macos" && xcodebuild -target Ghostty -configuration Debug -arch arm64 build > "$log" 2>&1) \
        || { grep -E "error:" "$log" | head -20 >&2; echo "dev.sh: the build failed ($log)" >&2; exit 1; }
    echo "built in $((SECONDS - start)) s"
fi

[[ -d "$app" ]] || { echo "dev.sh: no dev build at $app (run without --no-build)" >&2; exit 1; }
stop
[[ "$fresh" == 1 ]] && rm -rf "$state"
mkdir -p "$state"
# A LaunchServices launch, so the dev copy doesn't inherit this terminal's environment (it may be a
# pane of the installed Umi, with its UMI_* variables).
for attempt in 1 2 3; do
    # Just after the old copy quits, LaunchServices can still refuse a new one (error -600):
    # wait and try again.
    open -n -a "$app" --env "UMI_STATE_DIR=$state" 2>/dev/null || { sleep 1; continue; }
    for _ in $(seq 40); do
        if UMI_STATE_DIR="$state" "$app/Contents/MacOS/umi" ls >/dev/null 2>&1; then
            echo "Umi (dev) is running with state in $state. Its CLI: app/dist/dev.sh umi ls"
            exit 0
        fi
        sleep 0.25
    done
    stop
done
echo "dev.sh: the dev copy didn't start (see Console.app, process umi-app)" >&2
exit 1

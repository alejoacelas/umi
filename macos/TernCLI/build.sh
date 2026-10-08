#!/bin/bash
# Build the tern CLI: build.sh --out PATH
# Self-contained: compiles main.swift (next to this script) with swiftc.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) out="$2"; shift 2 ;;
        *) echo "build.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ -n "$out" ]] || { echo "usage: build.sh --out PATH" >&2; exit 2; }
mkdir -p "$(dirname "$out")"
module_cache="$(mktemp -d "${TMPDIR:-/tmp}/tern-cli-build.XXXXXX")"
trap 'rm -rf "$module_cache"' EXIT
xcrun --sdk macosx swiftc -O -target arm64-apple-macos13.0 \
    -module-cache-path "$module_cache" \
    -o "$out" "$here/main.swift"

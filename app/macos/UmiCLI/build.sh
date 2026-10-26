#!/bin/bash
# Build the umi CLI: build.sh --out PATH
# Self-contained: compiles the .swift files next to this script with swiftc.
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
out_dir="$(dirname "$out")"
mkdir -p "$out_dir"
# Private scratch space next to the output: doesn't depend on $TMPDIR existing, and works
# with spaces anywhere in the paths.
scratch="$out_dir/.umi-cli-build.$$"
mkdir -p "$scratch/tmp"
trap 'rm -rf "$scratch"' EXIT
TMPDIR="$scratch/tmp/" xcrun --sdk macosx swiftc -O -target arm64-apple-macos13.0 \
    -module-cache-path "$scratch/module-cache" \
    -o "$out" "$here"/*.swift

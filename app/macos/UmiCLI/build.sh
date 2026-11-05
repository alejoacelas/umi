#!/bin/bash
# Build the umi CLI: build.sh --out PATH
# Self-contained: compiles the .swift files next to this script with swiftc. UmiComments.swift (the
# comment format) is shared with the app, whose Sources link to it.
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
# The identity the app signs with (Xcode's, else ../../dist/signing.sh's default).
source "$here/../../dist/signing.sh"
if [[ -n "${CODE_SIGN_IDENTITY:-}" && -z "${UMI_SIGN_IDENTITY:-}" ]]; then umi_sign_identity="$CODE_SIGN_IDENTITY"; fi
umi_require_sign_identity || { echo "build.sh: can't sign the umi CLI" >&2; exit 1; }
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
codesign --force --sign "$umi_sign_identity" "$out"

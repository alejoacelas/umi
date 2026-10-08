#!/bin/bash
# Install Tern, a Ghostty-based terminal for working with coding agents.
#
#   curl -fsSL https://github.com/alejoacelas/tern/releases/latest/download/install.sh | bash
#
# Downloads the latest release (checking its SHA-256 against the release feed), installs
# Tern.app in /Applications (or ~/Applications), clears the download quarantine so macOS
# doesn't block it, links the `tern` command into ~/.local/bin, makes Tern the app for
# Markdown files and opens it. Nothing else needs to be installed first.
#
# Options and environment:
#   --from PATH                     install this Tern.app instead of downloading one
#   TERN_INSTALL_DEST=PATH          where the app goes (default /Applications/Tern.app)
#   TERN_INSTALL_BIN=DIR            where `tern` is linked (default ~/.local/bin)
#   TERN_INSTALL_NO_DEFAULT=1       don't make Tern the default app for Markdown
#   TERN_INSTALL_NO_LAUNCH=1        don't open Tern afterwards
#   TERN_INSTALL_FEED=URL           the release feed to install from (default: the latest release)
set -euo pipefail

repo="alejoacelas/tern"
feed="${TERN_INSTALL_FEED:-https://github.com/$repo/releases/latest/download/appcast.json}"
from=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) from="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Tern runs on macOS only"
[[ "$(uname -m)" == arm64 ]] || die "this build of Tern is for Apple Silicon Macs"

dest="${TERN_INSTALL_DEST:-}"
if [[ -z "$dest" ]]; then
    if [[ -w /Applications ]]; then dest="/Applications/Tern.app"; else dest="$HOME/Applications/Tern.app"; fi
fi
bindir="${TERN_INSTALL_BIN:-$HOME/.local/bin}"

work="$(mktemp -d "${TMPDIR:-/tmp}/tern-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -n "$from" ]]; then
    [[ -d "$from" ]] || die "no app at $from"
    src="$from"
else
    say "Finding the latest Tern release…"
    curl -fsSL "$feed" -o "$work/appcast.json" || die "couldn't reach $feed"
    # plutil reads JSON, and (unlike python3) needs no developer tools on a fresh Mac.
    version="$(plutil -extract version raw -o - "$work/appcast.json" 2>/dev/null)" || die "the release feed is unreadable"
    url="$(plutil -extract url raw -o - "$work/appcast.json")"
    sha256="$(plutil -extract sha256 raw -o - "$work/appcast.json")"
    say "Downloading Tern ${version}…"
    curl -fsSL "$url" -o "$work/Tern.zip" || die "couldn't download $url"
    actual="$(shasum -a 256 "$work/Tern.zip" | awk '{print $1}')"
    [[ "$actual" == "$sha256" ]] || die "the download doesn't match the release's checksum"
    ditto -x -k "$work/Tern.zip" "$work/unpacked" || die "couldn't unpack the download"
    src="$work/unpacked/Tern.app"
    [[ -d "$src" ]] || die "the download has no Tern.app"
fi

# Don't replace a copy that is running.
if pgrep -f "^$dest/Contents/MacOS/" >/dev/null 2>&1; then
    die "Tern is running from $dest; quit it first (or update from inside it with \`tern update\`)"
fi

mkdir -p "$(dirname "$dest")"
staged="$dest.installing-$$"
rm -rf "$staged"
ditto "$src" "$staged" || die "couldn't copy the app to $(dirname "$dest")"
# The download quarantine is what makes macOS ask (or refuse) to open an unnotarized app.
xattr -cr "$staged" 2>/dev/null || true
if [[ -d "$dest" ]]; then
    old="$dest.old-$$"
    mv "$dest" "$old"
    mv "$staged" "$dest" || { mv "$old" "$dest"; die "couldn't install into $dest"; }
    rm -rf "$old"
else
    mv "$staged" "$dest"
fi
say "Installed $dest"

mkdir -p "$bindir"
ln -sfn "$dest/Contents/MacOS/tern" "$bindir/tern"
say "Linked $bindir/tern"

# Let LaunchServices know about the app (for `open`, the Dock and the default Markdown app).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true

if [[ -z "${TERN_INSTALL_NO_DEFAULT:-}" ]]; then
    "$dest/Contents/MacOS/tern" editor default >/dev/null 2>&1 && say "Tern now opens Markdown files" || true
fi

case ":$PATH:" in
    *":$bindir:"*) ;;
    *) say "Note: $bindir isn't on your PATH. Add it (for example: echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zprofile) to use \`tern\` outside Tern's own terminals." ;;
esac

"$dest/Contents/MacOS/tern" doctor || true

if [[ -z "${TERN_INSTALL_NO_LAUNCH:-}" ]]; then
    open "$dest"
fi

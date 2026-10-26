#!/bin/bash
# Install Umi, a Ghostty-based terminal for working with coding agents.
#
#   curl -fsSL https://github.com/alejoacelas/umi/releases/latest/download/install.sh | bash
#
# Downloads the latest release (checking its SHA-256 against the release feed), installs
# Umi.app in /Applications (or ~/Applications), clears the download quarantine so macOS
# doesn't block it, links the `umi` command into ~/.local/bin, makes Umi the app for
# Markdown files and opens it. Nothing else needs to be installed first.
#
# Options and environment:
#   --from PATH                    install this Umi.app instead of downloading one
#   UMI_INSTALL_DEST=PATH          where the app goes (default /Applications/Umi.app)
#   UMI_INSTALL_BIN=DIR            where `umi` is linked (default ~/.local/bin)
#   UMI_INSTALL_NO_DEFAULT=1       don't make Umi the default app for Markdown
#   UMI_INSTALL_NO_LAUNCH=1        don't open Umi afterwards
#   UMI_INSTALL_FEED=URL           the release feed to install from (default: the latest release)
#
# Umi was called Tern before 0.6.0. Tern can stay installed: Umi copies its tabs and agent
# sessions the first time it opens and leaves Tern's own files alone.
set -euo pipefail

repo="alejoacelas/umi"
feed="${UMI_INSTALL_FEED:-https://github.com/$repo/releases/latest/download/appcast.json}"
from=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) from="$2"; shift 2 ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

say() { printf '%s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "Umi runs on macOS only"
[[ "$(uname -m)" == arm64 ]] || die "this build of Umi is for Apple Silicon Macs"

dest="${UMI_INSTALL_DEST:-}"
if [[ -z "$dest" ]]; then
    if [[ -w /Applications ]]; then dest="/Applications/Umi.app"; else dest="$HOME/Applications/Umi.app"; fi
fi
bindir="${UMI_INSTALL_BIN:-$HOME/.local/bin}"

work="$(mktemp -d "${TMPDIR:-/tmp}/umi-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -n "$from" ]]; then
    [[ -d "$from" ]] || die "no app at $from"
    src="$from"
else
    say "Finding the latest Umi release…"
    curl -fsSL "$feed" -o "$work/appcast.json" || die "couldn't reach $feed"
    # plutil reads JSON, and (unlike python3) needs no developer tools on a fresh Mac.
    version="$(plutil -extract version raw -o - "$work/appcast.json" 2>/dev/null)" || die "the release feed is unreadable"
    url="$(plutil -extract url raw -o - "$work/appcast.json")"
    sha256="$(plutil -extract sha256 raw -o - "$work/appcast.json")"
    say "Downloading Umi ${version}…"
    curl -fsSL "$url" -o "$work/Umi.zip" || die "couldn't download $url"
    actual="$(shasum -a 256 "$work/Umi.zip" | awk '{print $1}')"
    [[ "$actual" == "$sha256" ]] || die "the download doesn't match the release's checksum"
    ditto -x -k "$work/Umi.zip" "$work/unpacked" || die "couldn't unpack the download"
    src="$work/unpacked/Umi.app"
    [[ -d "$src" ]] || die "the download has no Umi.app"
fi

# Don't replace a copy that is running.
if pgrep -f "^$dest/Contents/MacOS/" >/dev/null 2>&1; then
    die "Umi is running from $dest; quit it first (or update from inside it with \`umi update\`)"
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
ln -sfn "$dest/Contents/MacOS/umi" "$bindir/umi"
say "Linked $bindir/umi"

# Let LaunchServices know about the app (for `open`, the Dock and the default Markdown app).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$dest" >/dev/null 2>&1 || true

if [[ -z "${UMI_INSTALL_NO_DEFAULT:-}" ]]; then
    "$dest/Contents/MacOS/umi" editor default >/dev/null 2>&1 && say "Umi now opens Markdown files" || true
fi

case ":$PATH:" in
    *":$bindir:"*) ;;
    *) say "Note: $bindir isn't on your PATH. Add it (for example: echo 'export PATH=\"$bindir:\$PATH\"' >> ~/.zprofile) to use \`umi\` outside Umi's own terminals." ;;
esac

"$dest/Contents/MacOS/umi" doctor || true

if [[ -z "${UMI_INSTALL_NO_LAUNCH:-}" ]]; then
    open "$dest"
fi

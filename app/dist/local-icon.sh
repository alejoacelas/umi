#!/bin/bash
# Give Umi the poster icon on this Mac only.
#
#   app/dist/local-icon.sh             fetch the image from 1Password and apply it
#   app/dist/local-icon.sh --from IMG  use this square image instead
#   app/dist/local-icon.sh --remove    go back to Umi's own icon
#
# The icon is a crop of the *From Up on Poppy Hill* poster (Umi raising her signal flags). The art
# is Studio Ghibli's, so it never goes into this repository, its history or a release: the public
# build ships Umi's own icon (dist/icon/icon.swift), and this script applies the poster locally.
#
# It fetches the crop from 1Password (document "UMI_ICON — umi" in the mac-agents vault, read with
# op-agent or op), shapes it as a macOS icon on Apple's grid (dist/icon/icon.swift shape) into
# ~/.config/umi/icon.png, and sets these in ~/.config/umi/config, a config file only Umi reads:
#
#   macos-icon = custom
#   macos-custom-icon = ~/.config/umi/icon.png
#
# Umi applies it when it starts (or at once with Umi > Reload Configuration), the way Ghostty's
# `macos-icon = custom` does: Dock tile and Finder icon. The file and the setting live outside the
# app, so updates keep them (each launch applies the icon again) and nothing in the bundle is edited
# by hand. ($XDG_CONFIG_HOME is honoured in place of ~/.config.)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
document="${UMI_ICON_DOCUMENT:-gkm26qrhn7brei7p5lkcxjxlz4}"
vault="${UMI_ICON_VAULT:-mac-agents}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/umi"
config="$config_dir/config"
icon="$config_dir/icon.png"
from=""; remove=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --from) from="$2"; shift 2 ;;
        --remove) remove=1; shift ;;
        -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
        *) echo "local-icon.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done

# Drop the icon settings from Umi's config file (and nothing else).
strip_settings() {
    [[ -f "$config" ]] || return 0
    local kept
    kept="$(grep -v -E '^[[:space:]]*(macos-icon|macos-custom-icon)[[:space:]]*=|^# The poster icon \(app/dist/local-icon\.sh\)' "$config" || true)"
    printf '%s\n' "$kept" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$config.tmp"
    mv "$config.tmp" "$config"
}

if [[ "$remove" == 1 ]]; then
    strip_settings
    rm -f "$icon"
    echo "Umi uses its own icon again (next launch, or Umi > Reload Configuration)."
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/umi-local-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT

if [[ -z "$from" ]]; then
    op=""
    for candidate in "$HOME/.local/bin/op-agent" "$(command -v op-agent || true)" "$(command -v op || true)"; do
        if [[ -n "$candidate" && -x "$candidate" ]]; then op="$candidate"; break; fi
    done
    [[ -n "$op" ]] || { echo "local-icon.sh: needs op-agent or op (1Password CLI), or --from IMAGE" >&2; exit 1; }
    "$op" document get "$document" --vault "$vault" --out-file "$work/source.png" >/dev/null \
        || { echo "local-icon.sh: couldn't read document $document from 1Password vault $vault" >&2; exit 1; }
    from="$work/source.png"
fi
[[ -r "$from" ]] || { echo "local-icon.sh: can't read $from" >&2; exit 1; }

xcrun --sdk macosx swiftc -O -module-cache-path "$work/mc" -o "$work/icon" "$here/icon/icon.swift"
"$work/icon" shape "$from" "$work/icon.png"
mkdir -p "$config_dir"
install -m 0644 "$work/icon.png" "$icon"

strip_settings
{
    [[ -s "$config" ]] && echo
    echo "# The poster icon (app/dist/local-icon.sh): only on this Mac, never in the repository."
    echo "macos-icon = custom"
    echo "macos-custom-icon = $icon"
} >> "$config"
echo "Icon written to $icon and set in $config."
echo "Umi shows it from its next launch (or now: Umi > Reload Configuration)."

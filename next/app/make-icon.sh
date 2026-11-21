#!/bin/bash
# Build a complete macOS icon from Umi's public catalog, or an explicitly supplied local image.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
output="${1:?output ICNS required}"
custom="${2:-}"
work="$(mktemp -d "${TMPDIR:-/tmp}/umi-next-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir "$work/Umi.iconset"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        name="icon_${size}x${size}"
        if [[ "$scale" == 2 ]]; then name+="@2x"; fi
        png="$work/Umi.iconset/$name.png"
        if [[ -n "$custom" ]]; then
            pixels=$((size * scale))
            sips -z "$pixels" "$pixels" "$custom" --out "$png" >/dev/null
        else
            cp "$here/../../app/macos/Assets.xcassets/UmiIcon.appiconset/umi-${size}@${scale}x.png" "$png"
        fi
    done
done
iconutil -c icns "$work/Umi.iconset" -o "$output"

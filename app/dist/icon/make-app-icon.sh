#!/bin/bash
# Draw Umi's icon (icon.swift) and write every size the asset catalog needs:
# macos/Assets.xcassets/UmiIcon.appiconset (the app icon) and AppIconImage.imageset (the
# image the About window, Settings and the Dock tile plugin show).
#
#   app/dist/icon/make-app-icon.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assets="$here/../../macos/Assets.xcassets"
work="$(mktemp -d "${TMPDIR:-/tmp}/umi-icon.XXXXXX")"
trap 'rm -rf "$work"' EXIT

xcrun --sdk macosx swiftc -O -module-cache-path "$work/mc" -o "$work/icon" "$here/icon.swift"
"$work/icon" design "$work/icon.png"

for spec in 16:1:16 16:2:32 32:1:32 32:2:64 128:1:128 128:2:256 256:1:256 256:2:512 512:1:512 512:2:1024; do
    IFS=: read -r pt scale px <<<"$spec"
    sips -s format png -z "$px" "$px" "$work/icon.png" --out "$assets/UmiIcon.appiconset/umi-${pt}@${scale}x.png" >/dev/null
done
sips -z 256 256 "$work/icon.png" --out "$assets/AppIconImage.imageset/macOS-AppIcon-256px-128pt@2x.png" >/dev/null
sips -z 512 512 "$work/icon.png" --out "$assets/AppIconImage.imageset/macOS-AppIcon-512px.png" >/dev/null
cp "$work/icon.png" "$assets/AppIconImage.imageset/macOS-AppIcon-1024px.png"
echo "wrote the icon into $assets"

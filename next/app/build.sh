#!/bin/bash
# Builds next/app/build/UmiNext.app (bundle id dev.umi.next).
#
# Needs libghostty: app/macos/GhosttyKit.xcframework and app/zig-out/share (shell integration,
# terminfo) in this checkout, built per AGENTS.md, or GHOSTTY_KIT / GHOSTTY_SHARE pointing at a
# checkout's copies (e.g. the main checkout's app/macos/GhosttyKit.xcframework).
#
#   next/app/build.sh            # release build
#   next/app/build.sh --debug    # debug build
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
config=release
[[ "${1:-}" == "--debug" ]] && config=debug

kit="${GHOSTTY_KIT:-$repo/app/macos/GhosttyKit.xcframework}"
share="${GHOSTTY_SHARE:-$repo/app/zig-out/share}"
[[ -d "$kit" ]] || { echo "build.sh: no GhosttyKit.xcframework at $kit (build libghostty per AGENTS.md or set GHOSTTY_KIT)" >&2; exit 1; }
[[ -d "$share/ghostty" ]] || { echo "build.sh: no Ghostty resources at $share (set GHOSTTY_SHARE)" >&2; exit 1; }

mkdir -p "$here/vendor"
# SwiftPM wants the binary target inside the package; refresh the copy when the source changed.
if [[ ! -d "$here/vendor/GhosttyKit.xcframework" ]] || \
   [[ "$kit/macos-arm64/libghostty-internal.a" -nt "$here/vendor/GhosttyKit.xcframework/macos-arm64/libghostty-internal.a" ]]; then
  rm -rf "$here/vendor/GhosttyKit.xcframework"
  cp -R "$kit" "$here/vendor/GhosttyKit.xcframework"
fi

# The daemon's binaries (built from next/daemon) ship in Contents/MacOS next to the UI.
daemon="$here/../daemon"
"$daemon/build.sh" >&2

cd "$here"
swift build -c "$config" --arch arm64
bin="$(swift build -c "$config" --arch arm64 --show-bin-path)/UmiNext"

app="$here/build/UmiNext.app"
rm -rf "$app.tmp"
mkdir -p "$app.tmp/Contents/MacOS" "$app.tmp/Contents/Resources"
cp "$bin" "$app.tmp/Contents/MacOS/UmiNext"
for tool in daemon attach ctl; do cp "$daemon/bin/umi-next-$tool" "$app.tmp/Contents/MacOS/"; done
cp "$here/umi-next-hook" "$app.tmp/Contents/Resources/"
cp -R "$share/ghostty" "$app.tmp/Contents/Resources/ghostty"
cp -R "$share/terminfo" "$app.tmp/Contents/Resources/terminfo"
cat > "$app.tmp/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.umi.next</string>
  <key>CFBundleName</key><string>Umi next</string>
  <key>CFBundleExecutable</key><string>UmiNext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UmiNextSourceDir</key><string>$here</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$app.tmp" >/dev/null
rm -rf "$app"
mv "$app.tmp" "$app"
echo "$app"

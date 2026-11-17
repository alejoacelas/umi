#!/bin/bash
# Builds next/app/build/UmiNext.app (bundle id dev.umi.next, or a test copy's with --test).
#
# Needs libghostty: app/macos/GhosttyKit.xcframework and app/zig-out/share (shell integration,
# terminfo) in this checkout, built per AGENTS.md, or GHOSTTY_KIT / GHOSTTY_SHARE pointing at a
# checkout's copies (e.g. the main checkout's app/macos/GhosttyKit.xcframework).
#
# Signs with Umi's stable local identity (app/dist/signing.sh: "Switcher Local Code Signing", or
# UMI_SIGN_IDENTITY), so macOS keeps the privacy permissions given to the app across builds; the
# build fails when the identity is missing. --adhoc signs ad hoc instead, on purpose only (a test
# Mac without the identity; macOS then asks again for permissions after every build).
#
#   next/app/build.sh            # release build
#   next/app/build.sh --debug    # debug build
#   next/app/build.sh --adhoc    # ad-hoc signature (testing only)
#   next/app/build.sh --test NAME   # test copy: bundle id dev.umi.next.test.NAME, its own default
#                                   # state dir (Umi-next-test-NAME), so agents' copies can't quit,
#                                   # replace or share state with each other or the real UmiNext
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
config=release
adhoc=0
test_name=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) config=debug ;;
    --adhoc) adhoc=1 ;;
    --test) [[ "${2:-}" =~ ^[a-z0-9-]+$ ]] || { echo "build.sh: --test needs a name of a-z, 0-9, -" >&2; exit 2; }
            test_name="$2"; shift ;;
    *) echo "build.sh: unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
bundle_id="dev.umi.next${test_name:+.test.$test_name}"
bundle_name="Umi next${test_name:+ ($test_name)}"
state_name="Umi-next${test_name:+-test-$test_name}"
source "$repo/app/dist/signing.sh"
if [[ $adhoc == 1 ]]; then
  echo "build.sh: signing ad hoc (--adhoc): macOS will ask again for any permission after each build" >&2
  sign_identity=-
else
  umi_require_sign_identity || { echo "build.sh: can't sign UmiNext.app (use --adhoc only for a test build)" >&2; exit 1; }
  sign_identity="$umi_sign_identity"
fi

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

# The umi-next CLI (cli/), with Umi's focus-log grouping compiled in as is.
mkdir -p "$here/.build/cli"
swiftc -O -module-cache-path "$here/.build/cli/modules" "$here"/cli/*.swift "$repo/app/macos/UmiCLI/focusgroups.swift" \
  -framework JavaScriptCore -o "$here/.build/cli/umi-next"

app="$here/build/UmiNext.app"
rm -rf "$app.tmp"
mkdir -p "$app.tmp/Contents/MacOS" "$app.tmp/Contents/Resources"
cp "$bin" "$app.tmp/Contents/MacOS/UmiNext"
for tool in daemon attach ctl; do cp "$daemon/bin/umi-next-$tool" "$app.tmp/Contents/MacOS/"; done
cp "$here/.build/cli/umi-next" "$app.tmp/Contents/MacOS/umi-next"
cp "$here/umi-next-hook" "$app.tmp/Contents/Resources/"
cp -R "$share/ghostty" "$app.tmp/Contents/Resources/ghostty"
cp -R "$share/terminfo" "$app.tmp/Contents/Resources/terminfo"
cat > "$app.tmp/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$bundle_name</string>
  <key>UmiNextStateName</key><string>$state_name</string>
  <key>CFBundleExecutable</key><string>UmiNext</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>UmiNextSourceDir</key><string>$here</string>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>dev.umi.next.task</string>
    <key>CFBundleURLSchemes</key><array><string>umi-next</string></array>
  </dict></array>
</dict>
</plist>
PLIST
for tool in daemon attach ctl; do codesign --force --sign "$sign_identity" "$app.tmp/Contents/MacOS/umi-next-$tool" >/dev/null 2>&1; done
codesign --force --sign "$sign_identity" "$app.tmp/Contents/MacOS/umi-next" >/dev/null 2>&1
codesign --force --sign "$sign_identity" "$app.tmp" >/dev/null 2>&1
rm -rf "$app"
mv "$app.tmp" "$app"
echo "$app"

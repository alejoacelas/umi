#!/bin/bash
# Make (and publish) a Tern release.
#
#   dist/release.sh --version X.Y.Z [--build] [--out DIR] [--base-url URL] [--no-publish] [--notes TEXT]
#
# Stamps a copy of the built app with the version, signs it (ad hoc), zips it, signs the zip
# with the update-signing key (login keychain item "Tern Update Signing Key", backup in
# ~/.config/tern/update-signing-key) and writes the feed (appcast.json). Unless --no-publish,
# it then publishes a GitHub release with the zip, the feed and the installer.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
repo="alejoacelas/tern"
version=""; out=""; base_url=""; publish=1; build=0; notes=""
app="$root/macos/build/ReleaseLocal/Tern.app"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) version="$2"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --base-url) base_url="$2"; shift 2 ;;
        --no-publish) publish=0; shift ;;
        --build) build=1; shift ;;
        --app) app="$2"; shift 2 ;;
        --notes) notes="$2"; shift 2 ;;
        *) echo "release.sh: unknown argument $1" >&2; exit 2 ;;
    esac
done
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo "release.sh: --version X.Y.Z is required" >&2; exit 2; }
out="${out:-$root/dist/out/$version}"
zip_name="Tern-$version.zip"
if [[ -z "$base_url" ]]; then
    base_url="https://github.com/$repo/releases/download/v$version/"
fi
[[ "$base_url" == */ ]] || base_url="$base_url/"

if [[ "$build" == 1 ]]; then
    (cd "$root/macos" && xattr -cr build/ReleaseLocal/Tern.app 2>/dev/null || true
     xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64 build | grep -E "error:|BUILD" )
fi
[[ -d "$app" ]] || { echo "release.sh: no app at $app (build it, or pass --build)" >&2; exit 1; }

# The signing key: the login keychain first, then the backup file.
key="$(security find-generic-password -s "Tern Update Signing Key" -a tern -w 2>/dev/null || true)"
if [[ -z "$key" && -r "$HOME/.config/tern/update-signing-key" ]]; then
    key="$(sed -n 's/^private=//p' "$HOME/.config/tern/update-signing-key")"
fi
[[ -n "$key" ]] || { echo "release.sh: the update-signing key isn't in the keychain or ~/.config/tern" >&2; exit 1; }

mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/tern-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A stamped copy of the app.
rm -rf "$out/Tern.app"
ditto "$app" "$out/Tern.app"
plist="$out/Tern.app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
plutil -replace TernBuildKind -string release "$plist"
xattr -cr "$out/Tern.app"
codesign --force --deep --sign - "$out/Tern.app" >/dev/null 2>&1
codesign --verify --deep --strict "$out/Tern.app"

# The update archive and its signature.
rm -f "$out/$zip_name"
(cd "$out" && ditto -c -k --keepParent Tern.app "$zip_name")
xcrun --sdk macosx swiftc -O -module-cache-path "$work/mc" -o "$work/sign-update" "$here/sign-update.swift" 2>/dev/null
signed="$(TERN_SIGNING_KEY="$key" "$work/sign-update" "$out/$zip_name")"
signature="$(sed -n 's/^signature=//p' <<<"$signed")"
sha256="$(sed -n 's/^sha256=//p' <<<"$signed")"
size="$(stat -f %z "$out/$zip_name")"
published="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 - "$out/appcast.json" <<PY
import json, sys
json.dump({
    "product": "Tern",
    "version": "$version",
    "url": "$base_url$zip_name",
    "size": $size,
    "sha256": "$sha256",
    "signature": "$signature",
    "published": "$published",
    "minimum_macos": "13.0",
    "notes": """$notes""",
}, open(sys.argv[1], "w"), indent=2)
PY
cp "$here/install.sh" "$out/install.sh"
echo "release files for $version in $out"

if [[ "$publish" == 1 ]]; then
    tag="v$version"
    gh release create "$tag" "$out/$zip_name" "$out/appcast.json" "$out/install.sh" \
        --repo "$repo" --title "Tern $version" --notes "${notes:-Tern $version}" --latest
    echo "published $tag: https://github.com/$repo/releases/tag/$tag"
fi

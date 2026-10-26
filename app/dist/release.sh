#!/bin/bash
# Make (and publish) an Umi release.
#
#   dist/release.sh --version X.Y.Z [--build] [--out DIR] [--base-url URL] [--no-publish] [--notes TEXT]
#
# Publishing an update from this Mac:  app/dist/release.sh --version X.Y.Z --build
#
# Stamps a copy of the built app with the version, signs it (ad hoc), zips it, signs the zip
# with the update-signing key and writes the feed (appcast.json). Unless --no-publish, it then
# publishes a GitHub release with the zip, the feed and the installer.
#
# The update-signing key (Ed25519, the one Tern's releases used) is taken from, in order:
#   $UMI_UPDATE_SIGNING_KEY (for example from `op run`);
#   1Password: item "UMI_UPDATE_SIGNING_KEY — umi" in the mac-agents vault, read with
#     op-agent (or op) as $UMI_SIGNING_KEY_REF (default below);
#   the login keychain item "Tern Update Signing Key" (account tern), Tern's name for it;
#   the backup file ~/.config/tern/update-signing-key (line private=…).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
repo="alejoacelas/umi"
version=""; out=""; base_url=""; publish=1; build=0; notes=""
app="$root/macos/build/ReleaseLocal/Umi.app"
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
zip_name="Umi-$version.zip"
if [[ -z "$base_url" ]]; then
    base_url="https://github.com/$repo/releases/download/v$version/"
fi
[[ "$base_url" == */ ]] || base_url="$base_url/"

if [[ "$build" == 1 ]]; then
    zig="${ZIG:-$HOME/.local/zig/zig-aarch64-macos-0.16.0/zig}"
    command -v "$zig" >/dev/null 2>&1 || zig="$(command -v zig || true)"
    [[ -n "$zig" ]] || { echo "release.sh: --build needs Zig 0.16 (set ZIG=/path/to/zig)" >&2; exit 1; }
    echo "building libghostty…"
    (cd "$root" && "$zig" build -Doptimize=ReleaseFast -Dxcframework-target=native -Demit-macos-app=false)
    echo "building Umi.app…"
    (cd "$root/macos" && { xattr -cr build/ReleaseLocal/Umi.app 2>/dev/null || true; } \
        && xcodebuild -target Ghostty -configuration ReleaseLocal -arch arm64 build > "$root/dist/build.log" 2>&1) \
        || { grep -E "error:" "$root/dist/build.log" | head -20 >&2; echo "release.sh: the build failed (dist/build.log)" >&2; exit 1; }
fi
if [[ "$publish" == 1 && -n "$(git -C "$root" status --porcelain --untracked-files=no)" ]]; then
    echo "release.sh: the checkout has uncommitted changes; commit them before publishing" >&2
    exit 1
fi
[[ -d "$app" ]] || { echo "release.sh: no app at $app (build it, or pass --build)" >&2; exit 1; }

# The signing key (see the top of this file). It goes to sign-update through the environment,
# never as an argument, and is never printed.
key_ref="${UMI_SIGNING_KEY_REF:-op://mac-agents/vv5tqiflwseevf5w7shbhmwoae/credential}"
key="${UMI_UPDATE_SIGNING_KEY:-}"
if [[ -z "$key" ]]; then
    for op in "$HOME/.local/bin/op-agent" "$(command -v op-agent || true)" "$(command -v op || true)"; do
        [[ -n "$op" && -x "$op" ]] || continue
        key="$("$op" read "$key_ref" 2>/dev/null || true)"
        [[ -n "$key" ]] && break
    done
fi
if [[ -z "$key" ]]; then
    key="$(security find-generic-password -s "Tern Update Signing Key" -a tern -w 2>/dev/null || true)"
fi
if [[ -z "$key" && -r "$HOME/.config/tern/update-signing-key" ]]; then
    key="$(sed -n 's/^private=//p' "$HOME/.config/tern/update-signing-key")"
fi
[[ -n "$key" ]] || { echo "release.sh: no update-signing key (1Password $key_ref, \$UMI_UPDATE_SIGNING_KEY, the keychain or ~/.config/tern)" >&2; exit 1; }

mkdir -p "$out"
work="$(mktemp -d "${TMPDIR:-/tmp}/umi-release.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# A stamped copy of the app.
rm -rf "$out/Umi.app"
ditto "$app" "$out/Umi.app"
plist="$out/Umi.app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$plist"
plutil -replace CFBundleVersion -string "$version" "$plist"
plutil -replace UmiBuildKind -string release "$plist"
xattr -cr "$out/Umi.app"
codesign --force --deep --sign - "$out/Umi.app" >/dev/null 2>&1
codesign --verify --deep --strict "$out/Umi.app"

# The update archive and its signature.
rm -f "$out/$zip_name"
(cd "$out" && ditto -c -k --keepParent Umi.app "$zip_name")
xcrun --sdk macosx swiftc -O -module-cache-path "$work/mc" -o "$work/sign-update" "$here/sign-update.swift" 2>/dev/null
signed="$(UMI_SIGNING_KEY="$key" "$work/sign-update" "$out/$zip_name")"
signature="$(sed -n 's/^signature=//p' <<<"$signed")"
sha256="$(sed -n 's/^sha256=//p' <<<"$signed")"
# The app only installs updates signed with the key whose public half it carries.
expected="$(plutil -extract UmiUpdatePublicKey raw -o - "$plist" 2>/dev/null || true)"
if [[ "$(sed -n 's/^public=//p' <<<"$signed")" != "$expected" ]]; then
    echo "release.sh: the signing key doesn't match the app's UmiUpdatePublicKey; installed copies would reject this update" >&2
    exit 1
fi
size="$(stat -f %z "$out/$zip_name")"
published="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# Values go in as arguments, never as Python source, so any text (quotes, backslashes) is kept.
python3 - "$out/appcast.json" "$version" "$base_url$zip_name" "$size" "$sha256" "$signature" "$published" "$notes" <<'PY'
import json, sys
out, version, url, size, sha256, signature, published, notes = sys.argv[1:]
json.dump({
    "product": "Umi",
    "version": version,
    "url": url,
    "size": int(size),
    "sha256": sha256,
    "signature": signature,
    "published": published,
    "minimum_macos": "13.0",
    "notes": notes,
}, open(out, "w"), indent=2)
PY
cp "$here/install.sh" "$out/install.sh"
echo "release files for $version in $out"

if [[ "$publish" == 1 ]]; then
    tag="v$version"
    gh release create "$tag" "$out/$zip_name" "$out/appcast.json" "$out/install.sh" \
        --repo "$repo" --title "Umi $version" --notes "${notes:-Umi $version}" --latest
    echo "published $tag: https://github.com/$repo/releases/tag/$tag"
fi

#!/bin/bash
# Build umi-next-daemon, umi-next-attach and umi-next-ctl into next/daemon/bin/.
# Builds libghostty-vt (static) into next/daemon/.build/vt first if it is missing
# or older than the Zig sources. ZIG=/path/to/zig overrides the Zig binary.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$here/../../app" && pwd)"
zig="${ZIG:-$HOME/.local/zig/zig-aarch64-macos-0.16.0/zig}"
vt="$here/.build/vt"
lib="$vt/lib/libghostty-vt.a"

if [[ ! -f "$lib" || -n "$(find "$app/src" "$app/include" "$app/build.zig" -newer "$lib" -print -quit)" ]]; then
    echo "building libghostty-vt → $vt" >&2
    (cd "$app" && "$zig" build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix "$vt")
fi

obj="$here/.build/obj"
mkdir -p "$obj" "$here/bin"
clang -O2 -Wall -c "$here/csrc/umic.c" -I"$vt/include" -o "$obj/umic.o"
ar rcs "$obj/libumic.a" "$obj/umic.o"

# Link libghostty-vt statically: the search dir holds only the .a, not the dylib.
link_dir="$here/.build/link"
mkdir -p "$link_dir"
ln -sf "$lib" "$link_dir/libghostty-vt.a"
flags=(-O -I "$here/csrc" -Xcc "-I$vt/include" -L "$obj" -lumic -L "$link_dir"
       -module-cache-path "$here/.build/modules")
for tool in daemon attach ctl; do
    swiftc "${flags[@]}" "$here/Sources/Common/Common.swift" "$here/Sources/$tool/main.swift" \
        -o "$here/bin/umi-next-$tool"
done
echo "built: $(ls "$here/bin" | tr '\n' ' ')" >&2

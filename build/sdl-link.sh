#!/usr/bin/env bash
# Prints the link flags for the vendored static SDL3: its -L path and private static deps, from
# pkg-config with --define-prefix (the prefix is where sdl3.pc sits, so a moved repo still finds
# it). The Odin binding emits -lSDL3 itself. Fails when libSDL3.a is missing, so a link can never
# fall back to a system libSDL3.so.
set -euo pipefail

PREFIX="$(cd "$(dirname "$0")/.." && pwd)/vendor/sdl3"
lib=""
for d in lib lib64; do
    [ -f "$PREFIX/$d/libSDL3.a" ] && lib="$d"
done
[ -n "$lib" ] || { echo "error: vendored static SDL3 missing — run ./download-deps.sh first" >&2; exit 1; }
PKG_CONFIG_PATH="$PREFIX/$lib/pkgconfig" pkg-config --define-prefix --static --libs sdl3 |
    tr ' ' '\n' | grep -vx -- '-lSDL3' | tr '\n' ' '

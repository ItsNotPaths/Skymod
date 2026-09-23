#!/usr/bin/env bash
# Builds the vendored Lua source into vendor/lua/linux/liblua54.a, the path the copied
# lua.odin binding foreign-imports. Every build/lua-*.patch is applied to the source first,
# in name order. Rebuilds whenever a patch or this script is newer than the lib.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/lua"
LIB="$DEST/linux/liblua54.a"

[ -f "$DEST/src/lua.h" ] || { echo "error: vendor/lua missing — run ./download-deps.sh first" >&2; exit 1; }

stale=0
[ -f "$LIB" ] || stale=1
for f in "$0" "$ROOT"/build/lua-*.patch; do
    [ -f "$f" ] && [ "$f" -nt "$LIB" ] && stale=1
done
if [ "$stale" = 0 ]; then
    echo "  already present: vendor/lua/linux/liblua54.a"
    exit 0
fi

# Patch a pristine copy, so re-running never double-applies.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp -r "$DEST/src" "$work/src"
for p in "$ROOT"/build/lua-*.patch; do
    [ -f "$p" ] || continue
    echo "  applying $(basename "$p")"
    patch -s -d "$work" -p1 <"$p"
done

echo "==> building lua (static)"
# The library only: lua.c and luac.c are the standalone interpreter and compiler.
# LUA_USE_POSIX, not LUA_USE_LINUX: the engine never loads C modules, so no dlopen.
cd "$work/src"
ls ./*.c | grep -vE '/luac?\.c$' |
    xargs -P "$(nproc)" -I{} cc -std=gnu99 -O2 -fPIC -ffunction-sections -fdata-sections -DLUA_USE_POSIX -c {}
mkdir -p "$DEST/linux"
rm -f "$LIB"
ar rcs "$LIB" ./*.o
echo "  done: vendor/lua/linux/liblua54.a"

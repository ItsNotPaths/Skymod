#!/usr/bin/env bash
# Compiles Dear ImGui + the dcimgui C API + the SDL3/SDL_gpu backends into a
# single static lib that the (pre-generated, committed) odin-imgui bindings
# foreign-import. No python / dear_bindings codegen — the Odin bindings are
# already committed in vendor/odin-imgui (see download-deps.sh).
#
# Output: vendor/odin-imgui/imgui_linux_x64.a  (the name lib_name.odin expects).
# Idempotent: skips compilation if the lib already exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMGUI="$ROOT/vendor/imgui"
BIND="$ROOT/vendor/odin-imgui"
SDL_INC="$ROOT/vendor/sdl3/include" # we vendor SDL3 here (not a system path)
OUT="$BIND/imgui_linux_x64.a"

if [ ! -d "$IMGUI" ] || [ ! -d "$BIND" ]; then
    echo "error: vendor/imgui or vendor/odin-imgui missing — run ./download-deps.sh first" >&2
    exit 1
fi
if [ ! -d "$SDL_INC" ]; then
    echo "error: $SDL_INC missing — build SDL3 first (./download-deps.sh)" >&2
    exit 1
fi

# The committed binding links the LLVM C++ runtime ("system:c++" -> -lc++), but
# clang on this host compiles imgui against the GNU runtime (libstdc++). Point the
# binding at the matching runtime. Idempotent + self-healing on re-fetch.
if grep -q '"system:c++"' "$BIND/imgui.odin"; then
    echo "==> patching odin-imgui to link libstdc++ (system:stdc++)"
    sed -i 's/"system:c++"/"system:stdc++"/' "$BIND/imgui.odin"
fi

if [ -f "$OUT" ]; then
    echo "==> imgui static lib already built: $OUT"
    exit 0
fi

echo "==> compiling Dear ImGui (+ dcimgui + sdl3/sdlgpu3 backends) -> $(basename "$OUT")"

# Flags mirror odin-imgui's build.py (clang, non-wasm). IMGUI_IMPL_API=extern"C"
# gives the backend entry points C linkage so the Odin foreign bindings resolve;
# the double quotes are intentional and must survive to clang (hence single
# quotes around the whole flag here).
FLAGS=(
    -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS
    '-DIMGUI_IMPL_API=extern"C"'
    -fPIC -fno-exceptions -fno-rtti -fno-threadsafe-statics -std=c++11 -O2
    # Per-function/datum sections so the release link (-Wl,--gc-sections) drops what we never call —
    # e.g. the whole imgui_demo.cpp (ShowDemoWindow) when it isn't referenced.
    -ffunction-sections -fdata-sections
    -I"$IMGUI" -I"$IMGUI/backends" -I"$BIND/dcimgui" -I"$SDL_INC"
)

SOURCES=(
    "$IMGUI/imgui.cpp"
    "$IMGUI/imgui_draw.cpp"
    "$IMGUI/imgui_tables.cpp"
    "$IMGUI/imgui_widgets.cpp"
    "$IMGUI/imgui_demo.cpp"
    "$BIND/dcimgui/dcimgui_nodefaultargfunctions.cpp"
    "$BIND/dcimgui/dcimgui_nodefaultargfunctions_internal.cpp"
    "$IMGUI/backends/imgui_impl_sdl3.cpp"
    "$IMGUI/backends/imgui_impl_sdlgpu3.cpp"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# clang -c writes one .o per source into the cwd; do it in a temp dir so the repo
# tree stays clean (sources are referenced by absolute path).
cd "$WORK"
clang "${FLAGS[@]}" -c "${SOURCES[@]}"
echo "==> archiving objects -> $OUT"
ar rcs "$OUT" ./*.o

echo "==> imgui static lib done: $OUT"

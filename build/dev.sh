#!/usr/bin/env bash
# Debug build (ODIN_DEBUG on): bounds checks, debug symbols, and the
# Tracking_Allocator leak / bad-free report at exit (docs/memory.md — prints
# "[mem] clean" on a clean run). Output -> build/out/skymod (gitignored).
# Pass --run to launch it after building; args after --run go to the binary
# (e.g. ./build/dev.sh --run --persist-logs). Use ./release.sh for shipping.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_DIR/build/out"

SDL_LINK="$("$PROJECT_DIR/build/sdl-link.sh")"

echo "==> compiling shaders"
"$PROJECT_DIR/build/build_shaders.sh"

echo "==> baking input prompts"
"$PROJECT_DIR/build/bake_prompts.sh"

mkdir -p "$OUT_DIR"
echo "==> debug build -> build/out/skymod"
odin build "$PROJECT_DIR/src/app" -debug -out:"$OUT_DIR/skymod" \
    -extra-linker-flags:"$SDL_LINK"
echo "==> done: $OUT_DIR/skymod (debug; leak report at exit)"

if [ "${1:-}" = "--run" ]; then
    echo "==> running"
    "$OUT_DIR/skymod" "${@:2}"
fi

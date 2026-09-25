#!/usr/bin/env bash
# Compiles every GLSL shader in src/render/shaders to SPIR-V (.spv) for SDL3_gpu.
# Uses glslangValidator (vendored by download-deps.sh into vendor/bin, or a system
# one via $GLSLANG). The .spv files are #load'd into the binary via the renderer,
# so they must be built before `odin build`. Tolerates an empty shader dir (Phase 0
# step 4 adds the first triangle's shaders).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHADER_DIR="$ROOT/src/render/shaders"
GLSLANG="${GLSLANG:-$ROOT/vendor/bin/glslangValidator}"

if ! command -v "$GLSLANG" >/dev/null 2>&1 && [ ! -x "$GLSLANG" ]; then
    echo "error: glslangValidator not found ($GLSLANG) — run ./download-deps.sh" >&2
    exit 1
fi

# A shader recompiles only when its source is newer than its .spv (no shader #includes another).
shopt -s nullglob
found=0
built=0
for src in "$SHADER_DIR"/*.vert "$SHADER_DIR"/*.frag "$SHADER_DIR"/*.comp; do
    found=1
    out="$src.spv"
    [ "$out" -nt "$src" ] && continue
    echo "  $(basename "$src") -> $(basename "$out")"
    "$GLSLANG" -V "$src" -o "$out"
    built=$((built + 1))
done

if [ "$found" -eq 0 ]; then
    echo "  (no shaders yet in src/render/shaders — nothing to compile)"
else
    echo "  shaders ok ($built rebuilt)"
fi

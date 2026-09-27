#!/usr/bin/env bash
# Local self-contained build (no docker). Produces one artifact:
#
#   skymod -> ../skymod-release/skymod   static SDL3 + shaders (src/render/shaders)
#             compiled to SPIR-V and #load'd into the binary, so the shipped
#             binary reads no external SDL or shader files.
#
# Run ./download-deps.sh once first (SDL3 + glslang). Needs a Vulkan-capable
# desktop session to actually run. The CI gate is build/test.sh (no deps needed).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
RELEASE_DIR="$(cd "$PROJECT_DIR/.." && pwd)/${PROJECT_NAME}-release"

# Static SDL3: the vendor:sdl3 binding emits -lSDL3, resolving to our vendored libSDL3.a.
SDL_LINK="$("$PROJECT_DIR/build/sdl-link.sh")"

# Shaders are #load'd into the binary, so compile them to SPIR-V first.
echo "==> compiling shaders"
"$PROJECT_DIR/build/build_shaders.sh"

# The button-prompt glyph atlas is #load'd too (src/prompts/prompts.pak).
echo "==> baking input prompts"
"$PROJECT_DIR/build/bake_prompts.sh"

echo "==> build: $PROJECT_NAME -> $RELEASE_DIR"
# Don't wipe the release dir — `odin build` overwrites the binary in place, and we
# want the runtime logs (skymod.log / the persistent logs/ folder the app writes
# beside the executable) to survive a recompile. Only the files we emit are replaced.
mkdir -p "$RELEASE_DIR"
# --gc-sections drops every unreferenced function/datum (the vendored libs are built with
# -ffunction-sections/-fdata-sections to make this granular) — most of the win is the large slice
# of Jolt we never call + imgui's demo window. Safe: used symbols are kept transitively.
odin build "$PROJECT_DIR/src/app" -out:"$RELEASE_DIR/$PROJECT_NAME" -o:speed \
    -extra-linker-flags:"$SDL_LINK -Wl,--gc-sections"

# Optional ~1 MB more by stripping the symbol table — but that's what crash.odin's runtime backtrace
# uses to name frames in skymod.log, so we keep symbols for now (readable tester crash logs > 1 MB).
# For an end-user ship, uncomment: keep an unstripped copy for offline addr2line, strip the shipped one.
#   cp "$RELEASE_DIR/$PROJECT_NAME" "$RELEASE_DIR/$PROJECT_NAME.debug" && strip "$RELEASE_DIR/$PROJECT_NAME"

# Ship ONLY the executable. Everything else is generated at runtime beside it:
# the executable owns settings.txt — it creates <base>/profiles/vanilla/settings.txt
# on first run from the DEFAULTS embedded in the binary (settings.DEFAULTS), backfills
# new keys on later runs, and migrates any legacy base/settings.txt into vanilla. So the
# release script no longer seeds a settings file. content/, logs/, skymod.log likewise
# appear at runtime. (README/LICENSE get baked into the binary and drawn in-app later.)

echo "==> done: $RELEASE_DIR/$PROJECT_NAME (static; needs Vulkan)"

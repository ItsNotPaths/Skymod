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
SDL_PREFIX="$PROJECT_DIR/vendor/sdl3"

if [ ! -e "$SDL_PREFIX/lib/pkgconfig/sdl3.pc" ] && [ ! -e "$SDL_PREFIX/lib64/pkgconfig/sdl3.pc" ]; then
    echo "error: vendored SDL3 missing — run ./download-deps.sh first" >&2
    exit 1
fi

# Static SDL3: the vendor:sdl3 binding emits -lSDL3, resolving to our vendored
# libSDL3.a (no .so installed). Append SDL's private static deps + its -L path from
# pkg-config (the source of truth) so the archive's symbols resolve.
export PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig:$SDL_PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
SDL_LINK="$(pkg-config --static --libs sdl3 | tr ' ' '\n' | grep -vx -- '-lSDL3' | tr '\n' ' ')"

# Shaders are #load'd into the binary, so compile them to SPIR-V first.
echo "==> compiling shaders"
"$PROJECT_DIR/build/build_shaders.sh"

echo "==> build: $PROJECT_NAME -> $RELEASE_DIR"
# Don't wipe the release dir — `odin build` overwrites the binary in place, and we
# want the runtime logs (skymod.log / the persistent logs/ folder the app writes
# beside the executable) to survive a recompile. Only the files we emit are replaced.
mkdir -p "$RELEASE_DIR"
odin build "$PROJECT_DIR/src/app" -out:"$RELEASE_DIR/$PROJECT_NAME" -o:speed \
    -extra-linker-flags:"$SDL_LINK"

# Ship as few files as possible: just the executable + settings.txt. README and
# LICENSE get baked into the binary (drawn in-app) later, so they're not copied
# here. content/, logs/, skymod.log are all generated at runtime beside the exe.

# settings.txt: NEVER overwrite the release copy (it holds the user's source_game
# path and other edits). Seed it from the repo defaults on first build, and on
# later builds only append keys the repo added since — existing values are left
# untouched. Same merge the app does at runtime; this just front-loads it.
DEFAULTS_SRC="$PROJECT_DIR/settings.txt"
DEST="$RELEASE_DIR/settings.txt"
if [ -f "$DEFAULTS_SRC" ]; then
    if [ ! -f "$DEST" ]; then
        cp "$DEFAULTS_SRC" "$DEST"
        echo "==> settings.txt: seeded from defaults"
    else
        added=0
        while IFS= read -r line; do
            case "$line" in ''|'#'*) continue ;; esac   # skip blanks/comments
            key="$(printf '%s' "${line%%=*}" | xargs)"  # text before '=', trimmed
            [ -z "$key" ] && continue
            if ! grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$DEST"; then
                printf '%s\n' "$line" >> "$DEST"
                echo "==> settings.txt: added missing key '$key'"
                added=1
            fi
        done < "$DEFAULTS_SRC"
        [ "$added" -eq 0 ] && echo "==> settings.txt: up to date (kept your values)"
    fi
fi

echo "==> done: $RELEASE_DIR/$PROJECT_NAME (static; needs Vulkan)"

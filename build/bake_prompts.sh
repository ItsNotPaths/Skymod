#!/usr/bin/env bash
# Bakes the vendored Kenney input-prompt art (vendor/kenney-input-prompts, fetched by
# download-deps.sh) into src/prompts/prompts.pak — one QOI atlas + name→cell directory
# that src/prompts #load's into the binary (same pattern as the GLSL → .spv bake).
# Without the vendored art it writes an EMPTY stub pak once, so `odin check`/tests run
# with no downloads and the engine falls back to text hints. Gitignored output.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ART="$ROOT/vendor/kenney-input-prompts"
OUT="$ROOT/src/prompts/prompts.pak"
TOOL="$ROOT/tools/promptbake"
BIN="$ROOT/build/out/promptbake"

mkdir -p "$ROOT/build/out"

if [ -f "$ART/License.txt" ]; then
    # Rebake when the art or the baker is newer than the pak.
    if [ -f "$OUT" ] && [ "$OUT" -nt "$ART" ] && [ "$OUT" -nt "$TOOL/main.odin" ]; then
        echo "  prompts.pak up to date"
        exit 0
    fi
    odin run "$TOOL" -out:"$BIN" -- "$ART" "$OUT"
else
    if [ ! -f "$OUT" ]; then
        echo "  no vendored prompt art (run ./download-deps.sh) — writing empty stub pak"
        odin run "$TOOL" -out:"$BIN" -- --stub "$OUT"
    fi
fi

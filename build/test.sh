#!/usr/bin/env bash
# The CI gate (ROADMAP Phase 0, step 1): compile shaders, type-check every
# package, then run the unit tests against SYNTHETIC fixtures only. `odin check`
# type-checks (incl. the vendor:sdl3 bindings) WITHOUT linking, so this needs no
# SDL3 — but it does need glslang (vendored by download-deps, or a system one),
# since src/render #load's the compiled .spv. No game assets, ever.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> compiling shaders (src/render #load's the .spv)"
"$ROOT/build/build_shaders.sh"

# Warn (don't fail) if the local Odin differs from the pin.
if [ -f .odin-version ]; then
    want="$(cat .odin-version)"
    have="$(odin version 2>/dev/null | awk '{print $3}')"
    [ -n "$have" ] && [ "$have" != "$want" ] && \
        echo "  note: odin $have != pinned $want (.odin-version)" >&2 || true
fi

echo "==> odin check (every package)"
# Every directory under src/ that holds Odin source is its own package (incl.
# nested ones like formats/bsa, installer/converters).
mapfile -t pkgs < <(find src -name '*.odin' -printf '%h\n' | sort -u)
for pkg in "${pkgs[@]}"; do
    echo "  check $pkg"
    if [ "$pkg" = "src/app" ]; then
        odin check "$pkg"                  # the executable: has a main entry point
    else
        odin check "$pkg" -no-entry-point  # a library package
    fi
done

echo "==> odin test (tests/unit)"
odin test tests/unit

echo "==> all green"

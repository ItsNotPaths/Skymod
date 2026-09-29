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

echo "==> baking input prompts (src/prompts #load's the pak; stub without vendored art)"
"$ROOT/build/bake_prompts.sh"

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
        # The dev harnesses live behind `when DEVTOOLS` (off in a default/release check,
        # and Odin skips false when-branches entirely) — check them explicitly too.
        echo "  check $pkg (-define:DEVTOOLS=true)"
        odin check "$pkg" -define:DEVTOOLS=true
    else
        odin check "$pkg" -no-entry-point  # a library package
    fi
done

echo "==> holes (swiss sync: ws.md)"
(cd "$ROOT" && swiss sync)

# src/transpile must stay liftable into its own repo: core:* and formats/pex, nothing else
# (docs/papyrus-transpiler.md, "The detachable contract").
# The plugin seams see the world only through their Host (ws.md Workstream H): core:*, base:*,
# formid and plugin, nothing else; plugin's record views also use formats/esm's fixed format types.
echo "==> seam imports"
for pkg in plugin detection combat sight condfn actorstate magic graphics; do
    allowed='^(core:|base:|\.\./formid$|\.\./plugin$)'
    [ "$pkg" = plugin ] && allowed='^(core:|base:|\.\./formid$|\.\./formats/esm$)'
    bad="$(grep -hoP '^import(\s+\w+)?\s+"\K[^"]+' src/$pkg/*.odin \
           | grep -vE "$allowed" || true)"
    if [ -n "$bad" ]; then
        echo "  src/$pkg imports outside its seam:" >&2
        echo "$bad" | sed 's/^/    /' >&2
        exit 1
    fi
done
echo "  clean"

echo "==> transpile detachability"
bad="$(grep -hoP '^import(\s+\w+)?\s+"\K[^"]+' src/transpile/*.odin \
       | grep -vE '^(core:|base:|\.\./formats/pex$)' || true)"
if [ -n "$bad" ]; then
    echo "  src/transpile imports outside its contract:" >&2
    echo "$bad" | sed 's/^/    /' >&2
    exit 1
fi
echo "  clean"

echo "==> test plugins (tests/plugins -> build/out/test-plugins)"
mkdir -p build/out/test-plugins
for dir in tests/plugins/*/; do
    odin build "$dir" -build-mode:shared -out:"build/out/test-plugins/$(basename "$dir").so"
done

echo "==> odin test (tests/unit)"
# Unlike `odin check`, `odin test` LINKS a real binary, and the tests' import graph
# reaches render -> vendor:sdl3 (via assetdb/world), which emits -lSDL3. Resolve it against
# the vendored static SDL3 exactly like dev.sh/release.sh.
SDL_LINK="$("$ROOT/build/sdl-link.sh")"
odin test tests/unit -extra-linker-flags:"$SDL_LINK"

echo "==> all green"

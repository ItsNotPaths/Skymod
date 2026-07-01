#!/usr/bin/env bash
# Builds JoltC (amerkoleci/joltc) + Jolt Physics as STATIC libs into the vendored
# joltc-odin bindings' lib/ dir, where the bindings foreign-import them: with
# JOLTC_SHARED=false (the default) joltc.odin does
#   foreign import lib {"lib/libjoltc.a", "lib/libJolt.a"}   (+ -lstdc++)
# so no link patching is needed (unlike imgui). Physics (ROADMAP §2e).
#
# PRECISION: DOUBLE (the Tamriel-scale target) — this is the DEFAULT now. The committed
# bindings define RVec3 :: [3]f64, so Jolt MUST be built double or the RVec3 ABI mismatches
# (Odin passes 24-byte positions the single-precision C lib reads as 12) and every world
# position is garbage. Override with JOLT_DOUBLE=OFF only if you ALSO regenerate the bindings
# to single (RVec3 :: Vec3). See the physics scope + src/physics/physics.odin.
#
# Idempotent: skips if the static libs already exist. vendor/ is download-only.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIND="$ROOT/vendor/joltc-odin"
SRC="$BIND/joltc" # the joltc submodule (pinned by joltc-odin)
LIBDIR="$BIND/lib"
DOUBLE_PRECISION="${JOLT_DOUBLE:-ON}" # MUST match the bindings (RVec3 :: [3]f64) — see the note above

# JOLT_PROFILE=ON compiles Jolt's built-in hierarchical profiler into BOTH libs (defines
# JPH_PROFILE_ENABLED, which the Distribution config otherwise leaves off). This turns
# physics.profile_next_frame/profile_dump from no-ops into real per-phase HTML dumps — use it
# to diagnose step hitches (EPA runaway). It slightly slows the sim; rebuild WITHOUT it (delete
# the libs + re-run) before shipping. Forces a rebuild so the toggle always takes effect.
PROFILE="${JOLT_PROFILE:-OFF}"
PROFILE_DEF=""
if [ "$PROFILE" = "ON" ]; then PROFILE_DEF="-DJPH_PROFILE_ENABLED"; fi

if [ "$PROFILE" != "ON" ] && [ -f "$LIBDIR/libjoltc.a" ] && [ -f "$LIBDIR/libJolt.a" ]; then
    echo "  already present: vendor/joltc-odin/lib (libjoltc.a + libJolt.a)"
    exit 0
fi
if [ ! -d "$BIND" ]; then
    echo "error: vendor/joltc-odin missing — run ./download-deps.sh first" >&2
    exit 1
fi
command -v cmake >/dev/null || { echo "error: cmake is required to build Jolt" >&2; exit 1; }

# Ensure the joltc submodule (which itself vendors JoltPhysics) is checked out at the
# commit joltc-odin pins.
if [ ! -f "$SRC/CMakeLists.txt" ]; then
    echo "  fetching joltc submodule..."
    git -C "$BIND" submodule update --init --recursive joltc
fi

echo "==> building joltc + Jolt (static, double=$DOUBLE_PRECISION)"
# Distribution = Jolt's fully-optimized, assert-free config. PIC so the archives link
# into our (PIE) executable. Samples/tests/install off; shared off (we want the .a's).
# -ffunction-sections/-fdata-sections give every function + datum its own section so the release
# link (release.sh: -Wl,--gc-sections) can drop the large slice of Jolt we never call.
cmake -S "$SRC" -B "$BIND/build" \
    -DCMAKE_BUILD_TYPE=Distribution \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_FLAGS="-ffunction-sections -fdata-sections $PROFILE_DEF" \
    -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
    -DDOUBLE_PRECISION="$DOUBLE_PRECISION" \
    -DJPH_SAMPLES=OFF \
    -DJPH_TESTS=OFF \
    -DJPH_INSTALL=OFF \
    -DJPH_BUILD_SHARED=OFF \
    -DINTERPROCEDURAL_OPTIMIZATION=OFF \
    >/dev/null
cmake --build "$BIND/build" --config Distribution --parallel "$(nproc)" >/dev/null

mkdir -p "$LIBDIR"
# joltc emits libjoltc.a (libjoltc_double.a under double precision) + Jolt's libJolt.a.
# The binding imports lib/libjoltc.a, so normalize the C-wrapper name.
find "$BIND/build" -name 'libjoltc*.a' -exec cp {} "$LIBDIR/libjoltc.a" \;
find "$BIND/build" -name 'libJolt.a' -exec cp {} "$LIBDIR/libJolt.a" \;
[ -f "$LIBDIR/libjoltc.a" ] && [ -f "$LIBDIR/libJolt.a" ] || {
    echo "error: build did not produce the static libs (looked under $BIND/build)" >&2
    exit 1
}
echo "  done: vendor/joltc-odin/lib (libjoltc.a + libJolt.a)"

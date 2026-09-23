#!/usr/bin/env bash
# Fetches third-party deps into vendor/. Run once before ./release.sh.
#
#   - SDL3     : built as a static lib + installed into the vendor/sdl3 prefix
#                (so sdl3.pc lands there; release.sh reads its private static deps
#                from pkg-config). GPU (Vulkan) backend stays enabled.
#   - glslang  : prebuilt glslangValidator, to compile GLSL -> SPIR-V (the host
#                may have none). Vendored into vendor/bin/.
#   - imgui    : Dear ImGui source + the (pre-generated) odin-imgui bindings,
#                compiled into a static lib by build/build-imgui.sh. Dev tooling +
#                the MVP game UI (ROADMAP Phase 0 step 6).
#   - lua      : Lua 5.4 source, built into a static lib by build/build-lua.sh,
#                plus Odin's own lua.odin binding copied beside it. We build Lua
#                ourselves so it can be patched (build/lua-*.patch).
#   - kenney input prompts : CC0 button-prompt glyph art (keyboard/mouse + every
#                pad family Kenney draws). build/bake_prompts.sh packs the 64px
#                tier into src/prompts/prompts.pak, which the binary #load's.
#
# vendor/ is download-only: never hand-write code there. (.gitignore drops it.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
VENDOR="$ROOT/vendor"

# Pinned versions
SDL3_VERSION="3.4.10"
# Dear ImGui source tag + the odin-imgui commit whose committed bindings target
# it. The two must stay in lockstep (see build/build-imgui.sh).
IMGUI_TAG="v1.92.8-docking"
ODIN_IMGUI_COMMIT="daa7298c62995440fd1b484c0d2f05afde055b33"
# joltc-odin bindings (amerkoleci/joltc via its committed Odin bindings); its own
# joltc submodule (which vendors JoltPhysics) is pinned by this commit's gitlink.
JOLTC_ODIN_COMMIT="84ab78c32314a4bb9f9a2f897a4fcce320db825a"
# Lua source release + the sha256 lua.org publishes for it (https://www.lua.org/ftp/).
LUA_VERSION="5.4.9"
LUA_SHA256="2335b6c582a52654f94612bf10d2f4672805d05329aa6568b1d8cd9e5c6fb8e6"
# Kenney "Input Prompts" 1.5 (CC0 1.0 — https://kenney.nl/assets/input-prompts).
# The media hash in the URL pins the exact 1.5 artifact.
KENNEY_PROMPTS_URL="https://www.kenney.nl/media/pages/assets/input-prompts/8de120163f-1777890371/kenney_input-prompts_1.5.zip"

# Build SDL3 as a static lib and INSTALL it into the vendor/sdl3 prefix. We
# install (rather than just copying libSDL3.a) so the generated sdl3.pc lands in
# the prefix: release.sh reads SDL's private static deps from pkg-config, the
# source of truth. SDL still dlopens the windowing/GPU backend (X11/Wayland/
# Vulkan) at runtime, so libSDL3.a's own undefined symbols are just libc/libm/...
build_sdl3() {
    local dest="$VENDOR/sdl3"

    if [ -f "$dest/lib/pkgconfig/sdl3.pc" ] || [ -f "$dest/lib64/pkgconfig/sdl3.pc" ]; then
        echo "  already present: vendor/sdl3 (sdl3.pc)"
        return
    fi

    # A stale source-only extraction (no install) would collide with the install
    # tree; start clean.
    rm -rf "$dest"

    echo "  downloading + building SDL3 $SDL3_VERSION (static)..."
    command -v cmake >/dev/null || { echo "error: cmake is required to build SDL3" >&2; exit 1; }

    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN

    curl -fsSL "https://github.com/libsdl-org/SDL/releases/download/release-${SDL3_VERSION}/SDL3-${SDL3_VERSION}.tar.gz" \
        | tar xz --strip-components=1 -C "$work"

    # We need window + mouse/keyboard + the GPU (Vulkan) backend. Audio/camera are
    # off to keep the static archive self-contained. X11 extensions: XINPUT is
    # REQUIRED (SDL's X11 relative mouse mode = pointer lock is XInput2-only —
    # without it mouse-look on an Xorg session is a hard "not supported"); XFIXES
    # confines the locked pointer; XRANDR reads real display modes. Their headers
    # (libxi-dev, libxfixes-dev, libxrandr-dev) must be present at BUILD time —
    # the libs themselves are dlopened at runtime. The rest stay off.
    cmake -S "$work" -B "$work/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$dest" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL=ON \
        -DSDL_AUDIO=OFF \
        -DSDL_CAMERA=OFF \
        -DSDL_X11_XCURSOR=OFF \
        -DSDL_X11_XDBE=OFF \
        -DSDL_X11_XFIXES=ON \
        -DSDL_X11_XINPUT=ON \
        -DSDL_X11_XRANDR=ON \
        -DSDL_X11_XSCRNSAVER=OFF \
        -DSDL_X11_XSHAPE=OFF \
        -DSDL_X11_XSYNC=OFF \
        -DSDL_X11_XTEST=OFF \
        >/dev/null

    cmake --build "$work/build" --parallel "$(nproc)" >/dev/null
    cmake --install "$work/build" >/dev/null
    echo "  done: vendor/sdl3 (static lib + sdl3.pc)"
}

# Vendor a prebuilt glslangValidator (the host may have none, and shaders must be
# compiled to SPIR-V before `odin build` #load's them). The Khronos "main-tot"
# rolling release ships a static linux build.
fetch_glslang() {
    local bin="$VENDOR/bin/glslangValidator"
    if [ -x "$bin" ]; then
        echo "  already present: vendor/bin/glslangValidator"
        return
    fi
    if command -v glslangValidator >/dev/null 2>&1; then
        echo "  using system glslangValidator: $(command -v glslangValidator)"
        mkdir -p "$VENDOR/bin"
        ln -sf "$(command -v glslangValidator)" "$bin"
        return
    fi

    echo "  downloading glslang (prebuilt)..."
    command -v unzip >/dev/null || { echo "error: unzip is required to unpack glslang" >&2; exit 1; }
    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN
    curl -fsSL \
        "https://github.com/KhronosGroup/glslang/releases/download/main-tot/glslang-main-linux-Release.zip" \
        -o "$work/glslang.zip"
    unzip -q "$work/glslang.zip" -d "$work/glslang"
    mkdir -p "$VENDOR/bin"
    cp "$work/glslang/bin/glslangValidator" "$bin"
    chmod +x "$bin"
    echo "  done: vendor/bin/glslangValidator"
}

# Fetch Dear ImGui + the odin-imgui bindings, then compile the C++ into a static
# lib (build/build-imgui.sh). The Odin bindings are pre-generated and committed in
# odin-imgui (no python codegen); we only compile the C++. The imgui source tag
# must match the version the committed bindings target.
fetch_imgui() {
    _fetch_tarball() { # name url dest
        local name="$1" url="$2" dest="$3"
        if [ -d "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            echo "  already present: vendor/$(basename "$dest")"
            return
        fi
        echo "  downloading $name..."
        mkdir -p "$dest"
        curl -fsSL "$url" | tar xz --strip-components=1 -C "$dest"
        echo "  done."
    }

    _fetch_tarball "imgui $IMGUI_TAG" \
        "https://github.com/ocornut/imgui/archive/refs/tags/${IMGUI_TAG}.tar.gz" \
        "$VENDOR/imgui"
    _fetch_tarball "odin-imgui $ODIN_IMGUI_COMMIT" \
        "https://gitlab.com/L-4/odin-imgui/-/archive/${ODIN_IMGUI_COMMIT}/odin-imgui-${ODIN_IMGUI_COMMIT}.tar.gz" \
        "$VENDOR/odin-imgui"

    # Compile imgui + the dcimgui C API + the SDL3/SDL_gpu backends into the static
    # lib the bindings link against.
    command -v clang >/dev/null || { echo "error: clang is required to build imgui" >&2; exit 1; }
    bash "$ROOT/build/build-imgui.sh"
}

# Fetch the joltc-odin bindings (+ its joltc/JoltPhysics submodule) and build the
# STATIC libs into vendor/joltc-odin/lib (build/build-jolt.sh). Unlike the tarball
# deps this needs git (joltc pulls JoltPhysics as a submodule). The bindings static-
# link the .a's directly (no patch). Physics (ROADMAP §2e).
fetch_jolt() {
    local dest="$VENDOR/joltc-odin"
    if [ -f "$dest/lib/libjoltc.a" ] && [ -f "$dest/lib/libJolt.a" ]; then
        echo "  already present: vendor/joltc-odin (static libs)"
        return
    fi
    command -v git >/dev/null || { echo "error: git is required to fetch joltc" >&2; exit 1; }
    if [ ! -d "$dest/.git" ]; then
        echo "  cloning joltc-odin ($JOLTC_ODIN_COMMIT)..."
        rm -rf "$dest"
        git clone --quiet https://github.com/jrdurandt/joltc-odin.git "$dest"
        git -C "$dest" checkout --quiet "$JOLTC_ODIN_COMMIT"
    fi
    # DOUBLE PRECISION (decided for Tamriel-scale worlds): build joltc with double AND
    # patch the committed single-precision bindings to the double ABI. Only two types
    # change under JPH_DOUBLE_PRECISION — JPH_RVec3 (positions → f64) and JPH_RMat4
    # ({Vec4 column[3]; RVec3 column3}); the double-only RMat4_* helper API is unused.
    # A full odin-c-bindgen regen (libclang) would be the heavyweight alternative; this
    # targeted patch is exact for the ABI we touch. Idempotent (matches single-only lines).
    sed -i 's/^RVec3 :: Vec3$/RVec3 :: [3]f64/' "$dest/joltc.odin"
    sed -i 's/^RMat4 :: Mat4$/RMat4 :: struct {column: [3]Vec4, column3: RVec3}/' "$dest/joltc.odin"
    # Drop the upstream test file: it passes [3]f32 literals to ^RVec3 params, which no
    # longer type-checks once RVec3 is f64 (it's their test, not part of our binding use).
    rm -f "$dest/joltc-test.odin"
    # Profiler entry points: upstream joltc exposes none, so src/physics's
    # ProfileNextFrame/ProfileDump calls need these decls + the C shim that
    # build-jolt.sh compiles from build/jolt_profile_glue.cpp. Idempotent.
    if ! grep -q "ProfileNextFrame" "$dest/joltc.odin"; then
        cat >>"$dest/joltc.odin" <<'EOF'

// --- skymod addition (download-deps.sh): Jolt profiler entry points, implemented
// by build/jolt_profile_glue.cpp which build-jolt.sh appends to lib/libjoltc.a ---
@(default_calling_convention = "c", link_prefix = "JPH_")
foreign lib {
	ProfileNextFrame :: proc() ---
	ProfileDump :: proc(tag: cstring) ---
}
EOF
    fi
    JOLT_DOUBLE=ON bash "$ROOT/build/build-jolt.sh"
}

# Fetch the Lua source and Odin's lua.odin binding into vendor/lua, then build the static lib
# (build/build-lua.sh). The binding foreign-imports "linux/liblua54.a" relative to itself, so
# the build writes exactly there and the binding needs no edit.
fetch_lua() {
    local dest="$VENDOR/lua"
    if [ ! -f "$dest/src/lua.h" ]; then
        echo "  downloading lua $LUA_VERSION..."
        local work
        work="$(mktemp -d)"
        trap 'rm -rf "$work"' RETURN
        curl -fsSL "https://www.lua.org/ftp/lua-${LUA_VERSION}.tar.gz" -o "$work/lua.tar.gz"
        echo "$LUA_SHA256  $work/lua.tar.gz" | sha256sum -c --quiet - || {
            echo "error: lua-${LUA_VERSION}.tar.gz checksum mismatch" >&2
            exit 1
        }
        rm -rf "$dest"
        mkdir -p "$dest"
        tar xzf "$work/lua.tar.gz" --strip-components=1 -C "$dest"
    fi
    local binding
    binding="$(odin root)vendor/lua/5.4/lua.odin"
    [ -f "$binding" ] || { echo "error: Odin's lua binding not found at $binding" >&2; exit 1; }
    cp "$binding" "$dest/lua.odin"
    # C API our Lua patches add (build/lua-*.patch), declared beside Odin's own binding.
    cat >>"$dest/lua.odin" <<'EOF'

// --- skymod addition (download-deps.sh): C API from build/lua-03-falsy-userdata.patch ---
@(link_prefix="lua_")
@(default_calling_convention="c")
foreign lib {
	setfalsy :: proc(L: ^State, idx: c.int, falsy: c.int) ---
}
EOF
    bash "$ROOT/build/build-lua.sh"
}

# Vendor the Kenney input-prompt glyphs: the 64px "Default" tier of every device
# set + the license. (The zip also carries 128px/SVG/font tiers we don't bake —
# skipped to keep vendor/ lean.) The pak baker (build/bake_prompts.sh) reads this
# tree; the runtime never does.
fetch_input_prompts() {
    local dest="$VENDOR/kenney-input-prompts"
    if [ -f "$dest/License.txt" ]; then
        echo "  already present: vendor/kenney-input-prompts"
        return
    fi
    command -v unzip >/dev/null || { echo "error: unzip is required to unpack the input prompts" >&2; exit 1; }

    echo "  downloading kenney input prompts 1.5 (CC0)..."
    local work
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' RETURN
    curl -fsSL "$KENNEY_PROMPTS_URL" -o "$work/prompts.zip"
    rm -rf "$dest"
    mkdir -p "$dest"
    unzip -q "$work/prompts.zip" '*/Default/*.png' 'License.txt' -d "$dest"
    echo "  done: vendor/kenney-input-prompts ($(find "$dest" -name '*.png' | wc -l) glyphs)"
}

echo "Fetching dependencies into vendor/ ..."

echo "==> sdl3 ($SDL3_VERSION)"
build_sdl3

echo "==> glslang"
fetch_glslang

echo "==> imgui ($IMGUI_TAG)"
fetch_imgui

echo "==> jolt ($JOLTC_ODIN_COMMIT)"
fetch_jolt

echo "==> lua ($LUA_VERSION)"
fetch_lua

echo "==> kenney input prompts (1.5)"
fetch_input_prompts

echo ""
echo "All deps ready."

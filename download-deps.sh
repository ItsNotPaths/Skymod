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
    # off to keep the static archive self-contained; the optional X11 extensions
    # are off so it builds without a sprawling set of X11 -devel packages. (SDL
    # dlopens the windowing/GPU backend at runtime, so none of these are baked in.)
    cmake -S "$work" -B "$work/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$dest" \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF \
        -DSDL_INSTALL=ON \
        -DSDL_AUDIO=OFF \
        -DSDL_CAMERA=OFF \
        -DSDL_X11_XCURSOR=OFF \
        -DSDL_X11_XDBE=OFF \
        -DSDL_X11_XFIXES=OFF \
        -DSDL_X11_XINPUT=OFF \
        -DSDL_X11_XRANDR=OFF \
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

echo "Fetching dependencies into vendor/ ..."

echo "==> sdl3 ($SDL3_VERSION)"
build_sdl3

echo "==> glslang"
fetch_glslang

echo "==> imgui ($IMGUI_TAG)"
fetch_imgui

echo ""
echo "All deps ready."

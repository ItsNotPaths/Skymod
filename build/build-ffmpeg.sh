#!/usr/bin/env bash
# Builds libopus + a trimmed static ffmpeg into vendor/ffmpeg/{include,lib}, then compiles
# build/ffmpeg_glue.c into lib/libskyff.a, the only API src/formats/ffmpeg binds.
# Enabled: what the xWMA -> Ogg (Opus) converter and the WAV/Ogg decoder use, nothing more.
# Rebuilds ffmpeg when this script is newer than its libs, the glue when the glue is.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/ffmpeg"
LIB="$DEST/lib"

[ -f "$DEST/src/ffmpeg/configure" ] && [ -f "$DEST/src/opus/CMakeLists.txt" ] ||
    { echo "error: vendor/ffmpeg sources missing — run ./download-deps.sh first" >&2; exit 1; }

if [ ! -f "$LIB/libavformat.a" ] || [ "$0" -nt "$LIB/libavformat.a" ]; then
    command -v cmake >/dev/null || { echo "error: cmake is required to build opus" >&2; exit 1; }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    rm -rf "$DEST/include" "$LIB"

    echo "==> building opus (static)"
    cmake -S "$DEST/src/opus" -B "$work/opus" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$DEST" \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_C_FLAGS="-ffunction-sections -fdata-sections" \
        -DBUILD_SHARED_LIBS=OFF \
        -DOPUS_BUILD_TESTING=OFF \
        -DOPUS_BUILD_PROGRAMS=OFF \
        >/dev/null
    cmake --build "$work/opus" --parallel "$(nproc)" >/dev/null
    cmake --install "$work/opus" >/dev/null

    echo "==> building ffmpeg (static, trimmed)"
    # Out of tree, so the vendored source stays pristine.
    mkdir -p "$work/ffmpeg"
    (
        cd "$work/ffmpeg"
        PKG_CONFIG_PATH="$LIB/pkgconfig" "$DEST/src/ffmpeg/configure" \
            --prefix="$DEST" \
            --pkg-config-flags=--static \
            --enable-static --disable-shared --enable-pic \
            --extra-cflags="-ffunction-sections -fdata-sections" \
            --disable-programs --disable-doc --disable-network --disable-autodetect \
            --disable-x86asm \
            --disable-avdevice --disable-avfilter --disable-swscale \
            --disable-everything \
            --enable-libopus \
            --enable-demuxer=xwma,wav,ogg \
            --enable-muxer=ogg \
            --enable-decoder=wmav2,pcm_u8,pcm_s16le,pcm_s24le,pcm_f32le,opus,vorbis \
            --enable-encoder=libopus \
            --enable-parser=opus,vorbis \
            >/dev/null
        make -j"$(nproc)" >/dev/null
        make install >/dev/null
    )
fi

if [ ! -f "$LIB/libskyff.a" ] || [ "$ROOT/build/ffmpeg_glue.c" -nt "$LIB/libskyff.a" ]; then
    echo "==> building ffmpeg glue"
    cc -std=c11 -O2 -fPIC -ffunction-sections -fdata-sections -I"$DEST/include" \
        -c "$ROOT/build/ffmpeg_glue.c" -o "$LIB/ffmpeg_glue.o"
    rm -f "$LIB/libskyff.a"
    ar rcs "$LIB/libskyff.a" "$LIB/ffmpeg_glue.o"
    rm "$LIB/ffmpeg_glue.o"
fi
echo "  done: vendor/ffmpeg"

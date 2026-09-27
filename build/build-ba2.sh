#!/usr/bin/env bash
# Builds build/bsa_glue (a C ABI over the ba2 crate) offline from the crates download-deps.sh
# vendored into vendor/ba2/crates, into vendor/ba2/lib/libskybsa.a. Rebuilds when the glue changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GLUE="$ROOT/build/bsa_glue"
DEST="$ROOT/vendor/ba2"
LIB="$DEST/lib/libskybsa.a"

[ -d "$DEST/crates" ] || { echo "error: vendor/ba2 missing — run ./download-deps.sh first" >&2; exit 1; }
command -v cargo >/dev/null || { echo "error: cargo is required to build ba2" >&2; exit 1; }

stale=0
[ -f "$LIB" ] || stale=1
for f in "$0" "$GLUE/Cargo.toml" "$GLUE/Cargo.lock" "$GLUE/src/lib.rs"; do
    [ "$f" -nt "$LIB" ] && stale=1
done
if [ "$stale" = 0 ]; then
    echo "  already present: vendor/ba2/lib/libskybsa.a"
    exit 0
fi

echo "==> building ba2 glue (static)"
cargo build --release --offline --locked --quiet \
    --manifest-path "$GLUE/Cargo.toml" \
    --target-dir "$DEST/target" \
    --config "source.crates-io.replace-with='vendored'" \
    --config "source.vendored.directory='$DEST/crates'"
mkdir -p "$DEST/lib"
cp "$DEST/target/release/libskybsa.a" "$LIB"
strip --strip-debug "$LIB" # Rust std ships with debug info
echo "  done: vendor/ba2/lib/libskybsa.a"

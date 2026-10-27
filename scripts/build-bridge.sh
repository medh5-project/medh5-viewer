#!/usr/bin/env bash
# Builds the medh5 bridge (bridge/: the Rust crate `medh5-bridge`, a static
# library over the medh5 engine 2.2.3) and packages it as
#
#     Packages/MedH5Kit/Frameworks/MedH5Bridge.xcframework
#
# with the C header and a `module MedH5Bridge` module map, which MedH5Kit's
# binary target links.
#
#   scripts/build-bridge.sh
#
# There is one build configuration, `--release --target aarch64-apple-darwin`,
# which `cargo test` in bridge/ also uses (scripts/test.sh), so the engine and
# HDF5 are compiled once.
#
# Needs Rust (aarch64-apple-darwin), CMake (HDF5 is built from source the
# first time, which takes a few minutes) and Xcode's command line tools.
# Idempotent: cargo rebuilds only what changed, and the xcframework is
# replaced only when the library or the header did.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"   # CARGO_TARGET_DIR: outside an iCloud-synced checkout
BRIDGE="$ROOT/bridge"
TARGET="aarch64-apple-darwin"
PROFILE="release"

for arg in "$@"; do
    case "$arg" in
        -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
        *) echo "build-bridge.sh: unknown option $arg" >&2; exit 2 ;;
    esac
done

# The engine's C code (HDF5, Blosc2, zstd, lz4, zlib) and the Rust code are
# compiled for the app's minimum macOS.
export MACOSX_DEPLOYMENT_TARGET=14.0

step() { printf '==> %s\n' "$*"; }

command -v cargo >/dev/null || { echo "build-bridge.sh: cargo not found (install Rust)" >&2; exit 1; }
command -v cmake >/dev/null || { echo "build-bridge.sh: cmake not found (HDF5 is built with CMake)" >&2; exit 1; }
command -v xcodebuild >/dev/null || { echo "build-bridge.sh: xcodebuild not found" >&2; exit 1; }

if ! rustup target list --installed 2>/dev/null | grep -qx "$TARGET"; then
    if command -v rustup >/dev/null; then
        step "adding the Rust target $TARGET"
        rustup target add "$TARGET"
    fi
fi

# Only the static library: built beside the rlib (`crate-type` lists both,
# for the tests), it is linked without LTO and is ten times larger.
step "cargo rustc --release --lib --crate-type staticlib --target $TARGET (bridge/)"
cargo rustc --release --lib --crate-type staticlib --target "$TARGET" --manifest-path "$BRIDGE/Cargo.toml"

LIB="$CARGO_TARGET_DIR/$TARGET/$PROFILE/libmedh5_bridge.a"
HEADER="$BRIDGE/include/medh5_bridge.h"
[[ -f "$LIB" ]] || { echo "build-bridge.sh: $LIB was not built" >&2; exit 1; }

# The patched HDF5 the medh5 workspace ships must be the one linked.
if ! grep -q 'source = "git+https://github.com/medh5-project/medh5?tag=v2.2.3' "$BRIDGE/Cargo.lock"; then
    echo "build-bridge.sh: Cargo.lock does not take hdf5-metno-src from the medh5 v2.2.3 tag" >&2
    exit 1
fi

FRAMEWORKS="$ROOT/Packages/MedH5Kit/Frameworks"
OUT="$FRAMEWORKS/MedH5Bridge.xcframework"
STAMP="$FRAMEWORKS/.MedH5Bridge.stamp"
mkdir -p "$FRAMEWORKS"

# What the xcframework is made from: the library, the header and the profile.
fingerprint="$(shasum -a 256 "$LIB" "$HEADER" | shasum -a 256 | cut -d' ' -f1)-$PROFILE"
if [[ -d "$OUT" && -f "$STAMP" && "$(cat "$STAMP")" == "$fingerprint" ]]; then
    step "MedH5Bridge.xcframework is up to date ($PROFILE)"
    exit 0
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/medh5-bridge.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Headers"
cp "$HEADER" "$STAGE/Headers/medh5_bridge.h"
cat > "$STAGE/Headers/module.modulemap" <<'MODULEMAP'
module MedH5Bridge {
    header "medh5_bridge.h"
    export *
}
MODULEMAP

step "xcodebuild -create-xcframework -> ${OUT#"$ROOT/"}"
rm -rf "$OUT"
xcodebuild -create-xcframework -library "$LIB" -headers "$STAGE/Headers" -output "$OUT" >/dev/null
printf '%s' "$fingerprint" > "$STAMP"

size="$(du -sh "$OUT" | cut -f1)"
step "done: MedH5Bridge.xcframework ($PROFILE, $size); link with -liconv (Package.swift's linkerSettings)"

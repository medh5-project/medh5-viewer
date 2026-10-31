#!/usr/bin/env bash
# Runs every test suite: the bridge (cargo), each package, then the app.
#
#   scripts/test.sh [--skip-bridge] [--release]
#
# The bridge's xcframework is built first when it is missing.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"
SKIP_BRIDGE=0
SWIFT_CONFIG=debug
for arg in "$@"; do
  case "$arg" in
    --skip-bridge) SKIP_BRIDGE=1 ;;
    --release) SWIFT_CONFIG=release ;;
    *) echo "test: unknown option $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$*"; }

if [[ $SKIP_BRIDGE == 0 ]]; then
  step "bridge: cargo test"
  (cd "$ROOT/bridge" && MACOSX_DEPLOYMENT_TARGET=14.0 cargo test --release --target aarch64-apple-darwin)
fi

if [[ ! -d "$ROOT/Packages/MedH5Kit/Frameworks/MedH5Bridge.xcframework" ]]; then
  step "building the bridge xcframework"
  "$ROOT/scripts/build-bridge.sh"
fi

for package in MedH5Core MedH5Editing MedH5Render MedH5Kit; do
  step "$package: swift test"
  swift test --package-path "$ROOT/Packages/$package" --scratch-path "$(swift_scratch "$package")" -c "$SWIFT_CONFIG"
done

step "app: swift test"
swift test --package-path "$ROOT" --scratch-path "$(swift_scratch app)" -c "$SWIFT_CONFIG" "${SWIFT_LINK_SDK[@]}"

step "all suites passed"

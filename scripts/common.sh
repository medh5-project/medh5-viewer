# Sourced by the build scripts: where build products go.
#
# Everything a build makes goes under BUILD_ROOT — cargo's target directory
# (CARGO_TARGET_DIR, unless already set), Swift's scratch directories (one
# per package), the app bundle, the packaged artifacts. It
# is $ROOT/build, unless the repository lives in a folder a file provider
# syncs (iCloud Drive's Desktop & Documents, for one): there every build
# product would be uploaded, and the provider's extended attributes make
# codesign refuse bundles ("resource fork, Finder information, or similar
# detritus not allowed"), so builds go to ~/Library/Caches/medh5-viewer
# instead. MEDH5_VIEWER_BUILD_ROOT overrides both; MEDH5_VIEWER_DIST_DIR
# overrides where packages go ($BUILD_ROOT/dist).

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

in_file_provider() {
  local dir="$1"
  while [[ -n "$dir" && "$dir" != "/" ]]; do
    if xattr -p com.apple.file-provider-domain-id "$dir" >/dev/null 2>&1; then return 0; fi
    dir="$(dirname "$dir")"
  done
  return 1
}

if [[ -n "${MEDH5_VIEWER_BUILD_ROOT:-}" ]]; then
  BUILD_ROOT="$MEDH5_VIEWER_BUILD_ROOT"
elif in_file_provider "$ROOT"; then
  BUILD_ROOT="$HOME/Library/Caches/medh5-viewer/$(basename "$ROOT")-$(printf '%s' "$ROOT" | shasum | cut -c1-8)"
else
  BUILD_ROOT="$ROOT/build"
fi
DIST_DIR="${MEDH5_VIEWER_DIST_DIR:-$BUILD_ROOT/dist}"
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$BUILD_ROOT/cargo}"
APP_BUNDLE="$BUILD_ROOT/medh5 Viewer.app"

# The scratch directory `swift build/test --scratch-path` uses for a package
# ("app" for the root package, or a name under Packages/).
swift_scratch() { printf '%s/swift/%s' "$BUILD_ROOT" "$1"; }

# For `swift build/test` of the app: names the SDK to clang when linking.
# Swift 6.4's build system links with no SDKROOT in the environment, and clang
# then records the deployment target as the SDK's version, which is what AppKit
# and SwiftUI choose the design by: the app would look like macOS 14 on every
# system, and unlike what the same sources give with CI's Swift 6.3.
SWIFT_LINK_SDK=(-Xswiftc -Xclang-linker -Xswiftc -isysroot
                -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --sdk macosx --show-sdk-path)")

#!/usr/bin/env bash
# Builds "medh5 Viewer.app" (into build/, or the BUILD_ROOT common.sh picks).
#
#   scripts/build-app.sh [--debug] [--rebuild-bridge] [--no-sign]
#
# 1. the medh5 engine bridge (scripts/build-bridge.sh), when its
#    xcframework is missing or --rebuild-bridge is given;
# 2. the Swift app (`swift build`), in BUILD_ROOT (scripts/common.sh: build/,
#    or a cache folder when the repository is in iCloud Drive);
# 3. the bundle: executable, Info.plist (version from VERSION, build number
#    from the commit count), icons, licences, the user guide (Help);
# 4. code signing: ad hoc by default, or with CODESIGN_IDENTITY (a
#    "Developer ID Application: …" identity) and the hardened runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "$ROOT/scripts/common.sh"
CONFIG=release
REBUILD_BRIDGE=0
SIGN=1
for arg in "$@"; do
  case "$arg" in
    --debug) CONFIG=debug ;;
    --rebuild-bridge) REBUILD_BRIDGE=1 ;;
    --no-sign) SIGN=0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "build-app: unknown option $arg" >&2; exit 2 ;;
  esac
done

APP_NAME="medh5 Viewer"
EXECUTABLE="medh5-viewer"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
XCFRAMEWORK="$ROOT/Packages/MedH5Kit/Frameworks/MedH5Bridge.xcframework"
ENGINE_VERSION="$(awk '/^name = "medh5"$/{getline; gsub(/version = |"/, ""); print; exit}' "$ROOT/bridge/Cargo.lock" 2>/dev/null || true)"
ENGINE_VERSION="${ENGINE_VERSION:-2.2.4}"

step() { printf '\n==> %s\n' "$*"; }

if [[ $REBUILD_BRIDGE == 1 || ! -d "$XCFRAMEWORK" ]]; then
  step "Building the medh5 engine bridge"
  if [[ $CONFIG == debug ]]; then "$ROOT/scripts/build-bridge.sh" --debug; else "$ROOT/scripts/build-bridge.sh"; fi
fi

step "Building the app ($CONFIG)"
SCRATCH="$(swift_scratch app)"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG" --product "$EXECUTABLE" "${SWIFT_LINK_SDK[@]}"
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG" --show-bin-path)"

step "Assembling $APP_NAME.app $VERSION ($BUILD_NUMBER), engine $ENGINE_VERSION"
APP="$APP_BUNDLE"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
LINKED_SDK="$(xcrun vtool -show-build "$APP/Contents/MacOS/$EXECUTABLE" | awk '$1 == "sdk" { print $2 }')"
if [[ "$LINKED_SDK" != "$SDK_VERSION" ]]; then
  echo "build-app: the app records SDK $LINKED_SDK, not $SDK_VERSION: it would not get this SDK's design" >&2
  exit 1
fi
sed -e "s/__VERSION__/$VERSION/g" \
    -e "s/__BUILD__/$BUILD_NUMBER/g" \
    -e "s/__ENGINE_VERSION__/$ENGINE_VERSION/g" \
    "$ROOT/Resources/Info.plist" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
cp "$ROOT/Resources/AppIcon.icns" "$ROOT/Resources/DocumentIcon.icns" "$APP/Contents/Resources/"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp "$ROOT/THIRD_PARTY_NOTICES" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
# The user guide the Help window renders, with its images.
if [[ -f "$ROOT/docs/USER_GUIDE.md" ]]; then
  mkdir -p "$APP/Contents/Resources/Help"
  cp "$ROOT/docs/USER_GUIDE.md" "$APP/Contents/Resources/Help/USER_GUIDE.md"
  if [[ -d "$ROOT/docs/images" ]]; then cp -R "$ROOT/docs/images" "$APP/Contents/Resources/Help/images"; fi
fi
# SwiftPM resource bundles, should any target ever declare resources.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [[ $SIGN == 1 ]]; then
  # Extended attributes (Finder info, a file provider's) are not allowed in
  # a signed bundle.
  xattr -cr "$APP"
  IDENTITY="${CODESIGN_IDENTITY:--}"
  step "Signing with ${IDENTITY/#-/an ad hoc signature}"
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --entitlements "$ROOT/Resources/medh5-viewer.entitlements" "$APP"
  else
    codesign --force --options runtime --timestamp --sign "$IDENTITY" \
      --entitlements "$ROOT/Resources/medh5-viewer.entitlements" "$APP"
  fi
  codesign --verify --strict --verbose=1 "$APP"
fi

step "Done"
echo "$APP"
du -sh "$APP" | awk '{print "size: " $1}'

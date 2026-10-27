#!/usr/bin/env bash
# Packages build/medh5 Viewer.app as a disk image and a zip in dist/.
#
#   scripts/package-dmg.sh [--build]
#
# --build runs scripts/build-app.sh first. With CODESIGN_IDENTITY set the
# disk image is signed; with NOTARY_PROFILE set (a profile saved by
# `xcrun notarytool store-credentials`) it is notarized and stapled.
# SHA-256 checksums are written beside the artifacts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${1:-}" == "--build" ]]; then "$ROOT/scripts/build-app.sh"; fi

APP_NAME="medh5 Viewer"
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION")"
APP="$ROOT/build/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "package-dmg: $APP not found; run scripts/build-app.sh" >&2; exit 1; }

DIST="$ROOT/dist"
BASENAME="medh5-Viewer-$VERSION-macOS-arm64"
DMG="$DIST/$BASENAME.dmg"
ZIP="$DIST/$BASENAME.zip"
mkdir -p "$DIST"
rm -f "$DMG" "$ZIP"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/LICENSE.txt"

echo "==> $DMG"
hdiutil create -quiet -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO -fs HFS+ "$DMG"
if [[ -n "${CODESIGN_IDENTITY:-}" && "${CODESIGN_IDENTITY}" != "-" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> notarizing"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "==> $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > "$BASENAME.sha256")
cat "$DIST/$BASENAME.sha256"

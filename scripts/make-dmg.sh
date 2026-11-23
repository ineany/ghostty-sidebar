#!/usr/bin/env bash
# Builds a universal "Ghostty Sidebar.app" and packs it into a DMG.
#
#   scripts/make-dmg.sh    writes build/Ghostty-Sidebar-<version>.dmg
#
# The DMG holds the app and a link to /Applications for drag-and-drop install.
# Signing follows build-app.sh (SIGN_ID). An "Apple Development" signature is
# not notarized, so Gatekeeper on other Macs blocks the first launch; see
# README "배포본" for how to open it there.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Ghostty Sidebar"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"

# Building for two architectures needs Xcode; Command Line Tools alone cannot.
if [[ "$(xcode-select -p 2>/dev/null)" != *.app/Contents/Developer ]]; then
    echo "error: a universal build needs Xcode. Install Xcode, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

UNIVERSAL=1 "$ROOT/scripts/build-app.sh"

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="$BUILD_DIR/Ghostty-Sidebar-$VERSION.dmg"
STAGE="$BUILD_DIR/dmg"

echo "==> dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
rm -rf "$STAGE"

SIGN_ID=${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development/ { print $2; exit }')}
if [[ -n "$SIGN_ID" && "$SIGN_ID" != "-" ]]; then
    codesign --force --sign "$SIGN_ID" "$DMG"
fi
hdiutil verify "$DMG" >/dev/null
echo "dmg: $DMG ($(du -h "$DMG" | cut -f1))"

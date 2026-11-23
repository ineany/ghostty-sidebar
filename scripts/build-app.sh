#!/usr/bin/env bash
# Builds "Ghostty Sidebar.app" from the SwiftPM package.
#
#   scripts/build-app.sh            build into ./build
#   scripts/build-app.sh --install  also copy to ~/Applications and launch it
#   UNIVERSAL=1 scripts/build-app.sh  build for Apple Silicon and Intel
#
# Signing: macOS ties the Accessibility permission to the signature. An ad-hoc
# signature changes on every rebuild, so the permission silently stops working.
# The script therefore uses the first "Apple Development" identity in the
# keychain. Set SIGN_ID to pick another identity, or SIGN_ID=- for ad-hoc.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME="Ghostty Sidebar"
BUNDLE_ID="dev.local.ghostty-sidebar"
EXEC_NAME="GhosttySidebar"
BUILD_DIR="$ROOT/build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"
VERSION="0.1.0"
BUILD_NUMBER=$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)

install=false
[[ "${1:-}" == "--install" ]] && install=true

ARCH_FLAGS=()
[[ "${UNIVERSAL:-}" == "1" ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)

echo "==> swift build (release${ARCH_FLAGS:+, universal})"
swift build --package-path "$ROOT" -c release --product ghostty-sidebar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build --package-path "$ROOT" -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)/ghostty-sidebar"

echo "==> app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXEC_NAME"

echo "==> icon"
ICON_WORK="$BUILD_DIR/icon"
rm -rf "$ICON_WORK" && mkdir -p "$ICON_WORK/AppIcon.iconset"
swift "$ROOT/scripts/make-icon.swift" "$ICON_WORK/AppIcon-1024.png" >/dev/null
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICON_WORK/AppIcon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$ICON_WORK/AppIcon-1024.png" --out "$ICON_WORK/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICON_WORK/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Ghostty의 탭 목록을 읽고 탭을 전환하며, System Events로 Ghostty 창 위치를 정렬합니다.</string>
</dict>
</plist>
PLIST

if [[ -z "${SIGN_ID:-}" ]]; then
    SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F'"' '/Apple Development/ { print $2; exit }')
    SIGN_ID=${SIGN_ID:--}
fi
echo "==> codesign (${SIGN_ID/#-/ad-hoc})"
codesign --force --options runtime --sign "$SIGN_ID" \
    --entitlements /dev/stdin "$APP" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.automation.apple-events</key><true/>
</dict>
</plist>
ENT
codesign --verify --strict "$APP"
echo "built: $APP"

if $install; then
    echo "==> install to $INSTALL_DIR"
    pkill -x "$EXEC_NAME" 2>/dev/null || true
    mkdir -p "$INSTALL_DIR"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    ditto "$APP" "$INSTALL_DIR/$APP_NAME.app"
    open "$INSTALL_DIR/$APP_NAME.app"
    echo "installed: $INSTALL_DIR/$APP_NAME.app"
fi

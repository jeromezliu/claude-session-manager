#!/bin/bash
# Build ClaudeSessionManager into a runnable .app bundle.
#
#   ./build.sh          -> build (release) and package the .app
#   ./build.sh run      -> build, package, and launch
#   ./build.sh debug    -> build in debug config
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="release"
LAUNCH=0
for arg in "$@"; do
    case "$arg" in
        debug) CONFIG="debug" ;;
        run)   LAUNCH=1 ;;
    esac
done

APP_NAME="ClaudeSessionManager"
BUNDLE_ID="com.jerome.claudesessionmanager"

echo "▶ Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"
APP_DIR="build/${APP_NAME}.app"
MACOS_DIR="${APP_DIR}/Contents/MacOS"
RES_DIR="${APP_DIR}/Contents/Resources"

echo "▶ Packaging ${APP_DIR}…"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR"
cp "${BIN_PATH}/${APP_NAME}" "${MACOS_DIR}/${APP_NAME}"

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>Claude Session Manager</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# Ad-hoc signature so the GUI app launches without Gatekeeper complaints.
codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built ${APP_DIR}"

if [[ "$LAUNCH" == "1" ]]; then
    echo "▶ Launching…"
    open "$APP_DIR"
fi

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

# Version stamped into Info.plist. release.sh passes APP_VERSION; otherwise
# derive it from the latest v* tag: exactly on a tag → "1.3.0", past it →
# "1.3.0+2.fc9b2db" (2 commits later), plus ".dirty" for uncommitted changes.
if [[ -n "${APP_VERSION:-}" ]]; then
    SHORT_VERSION="$APP_VERSION"
    FULL_VERSION="$APP_VERSION"
else
    DESCRIBE="$(git describe --tags --match 'v*' --dirty 2>/dev/null || true)"
    if [[ "$DESCRIBE" =~ ^v([0-9][^-]*)(-([0-9]+)-g([0-9a-f]+))?(-dirty)?$ ]]; then
        SHORT_VERSION="${BASH_REMATCH[1]}"
        FULL_VERSION="$SHORT_VERSION"
        [[ -n "${BASH_REMATCH[3]}" ]] && FULL_VERSION+="+${BASH_REMATCH[3]}.${BASH_REMATCH[4]}"
        [[ -n "${BASH_REMATCH[5]}" ]] && FULL_VERSION+="$([[ "$FULL_VERSION" == *+* ]] && echo . || echo +)dirty"
    else
        SHORT_VERSION="0.0.0"
        FULL_VERSION="0.0.0+dev"
    fi
fi
# CFBundleVersion must be numeric: use the commit count.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

echo "▶ Building ${FULL_VERSION} ($CONFIG)…"
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
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
    <key>CSMFullVersion</key><string>${FULL_VERSION}</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
</dict>
</plist>
PLIST

echo "APPL????" > "${APP_DIR}/Contents/PkgInfo"

# App icon
if [[ -f "Resources/AppIcon.icns" ]]; then
    cp "Resources/AppIcon.icns" "${RES_DIR}/AppIcon.icns"
else
    echo "  (AppIcon.icns not found — run: swift Icon/GenerateIcon.swift Icon/AppIcon.iconset && iconutil -c icns Icon/AppIcon.iconset -o Resources/AppIcon.icns)"
fi

# Prefer a real signing identity (CSM_SIGN_IDENTITY, or the first valid one
# in the keychain): a stable identity keeps the Keychain's "Always Allow" for
# stored SSH passwords working across rebuilds. Fall back to ad-hoc, which
# still launches fine but counts as a "new app" to the Keychain every build.
SIGN_ID="${CSM_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')}"
if [[ -n "$SIGN_ID" ]]; then
    echo "▶ Signing as “${SIGN_ID}”…"
    codesign --force --sign "$SIGN_ID" "$APP_DIR" >/dev/null 2>&1 \
        || { echo "  (identity signing failed — falling back to ad-hoc)"; codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true; }
else
    codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || echo "  (codesign skipped)"
fi

echo "✓ Built ${APP_DIR}"

if [[ "$LAUNCH" == "1" ]]; then
    echo "▶ Launching…"
    open "$APP_DIR"
fi

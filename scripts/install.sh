#!/bin/bash
set -euo pipefail

APP_NAME="MidiDeck"
APP_PATH="/Applications/${APP_NAME}.app"
CONTENTS="${APP_PATH}/Contents"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "==> Building ${APP_NAME} (release)..."
cd "$PROJECT_DIR"
swift build -c release

echo "==> Stopping running ${APP_NAME} (if any)..."
killall "$APP_NAME" 2>/dev/null && sleep 1 || true

echo "==> Installing to ${APP_PATH}..."
mkdir -p "${CONTENTS}/MacOS" "${CONTENTS}/Resources"

# Copy binary
cp ".build/arm64-apple-macosx/release/${APP_NAME}" "${CONTENTS}/MacOS/${APP_NAME}"

# Write Info.plist (only if it doesn't exist yet)
if [ ! -f "${CONTENTS}/Info.plist" ]; then
    cat > "${CONTENTS}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>MidiDeck</string>
    <key>CFBundleIdentifier</key>
    <string>com.midideck.app</string>
    <key>CFBundleName</key>
    <string>MidiDeck</string>
    <key>CFBundleDisplayName</key>
    <string>MidiDeck</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST
    echo "    Created Info.plist"
fi

echo "==> Launching ${APP_NAME}..."
open "$APP_PATH"

echo "==> Done! ${APP_NAME} is running."

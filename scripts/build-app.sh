#!/bin/sh
# Builds TomTomSync.app (menu bar app) and the ttsync CLI.
# Usage: scripts/build-app.sh [--install]   (--install copies the app to ~/Applications)
set -eu
cd "$(dirname "$0")/.."

swift build -c release --product TomTomSyncApp
swift build -c release --product ttsync
BIN=$(swift build -c release --show-bin-path)

APP=build/TomTomSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TomTomSyncApp" "$APP/Contents/MacOS/TomTomSync"
cp "$BIN/ttsync" build/ttsync

VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>nl.takobruinsma.TomTomSync</string>
    <key>CFBundleName</key><string>TomTomSync</string>
    <key>CFBundleDisplayName</key><string>TomTomSync</string>
    <key>CFBundleExecutable</key><string>TomTomSync</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Built $APP and build/ttsync"

if [ "${1:-}" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    pkill -x TomTomSync 2>/dev/null || true
    rm -rf "$HOME/Applications/TomTomSync.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/TomTomSync.app"
fi

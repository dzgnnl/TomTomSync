#!/bin/sh
# Builds TomTomSync.app (menu bar app) and the ttsync CLI, as universal
# binaries (Apple Silicon + Intel) when Xcode is installed.
#
# Usage: scripts/build-app.sh [--install] [--zip]
#   --install  copy the app to ~/Applications (and quit the running copy first)
#   --zip      also create build/TomTomSync-<version>.zip for sharing
#
# Signing: by default the app is signed ad hoc, which is fine on the Mac that
# built it. For distribution set SIGN_IDENTITY to a "Developer ID Application"
# certificate and NOTARY_PROFILE to a `xcrun notarytool store-credentials`
# profile; --zip then notarizes and staples the app.
set -eu
cd "$(dirname "$0")/.."

INSTALL=0; ZIP=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --zip) ZIP=1 ;;
        *) echo "Unknown option: $arg" >&2; exit 2 ;;
    esac
done

# Universal binaries need full Xcode; with only the Command Line Tools build
# for this Mac's own architecture.
if xcode-select -p 2>/dev/null | grep -q CommandLineTools; then
    ARCHS=""
else
    ARCHS="--arch arm64 --arch x86_64"
fi
swift build -c release $ARCHS --product TomTomSyncApp
swift build -c release $ARCHS --product ttsync
BIN=$(swift build -c release $ARCHS --show-bin-path)

VERSION=$(git describe --tags --always 2>/dev/null || echo dev)
SHORT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
[ -n "$SHORT_VERSION" ] || SHORT_VERSION=0.1

APP=build/TomTomSync.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/TomTomSyncApp" "$APP/Contents/MacOS/TomTomSync"
cp "$BIN/ttsync" "$APP/Contents/MacOS/ttsync"   # Homebrew links this as `ttsync`
cp "$BIN/ttsync" build/ttsync

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
    <key>CFBundleShortVersionString</key><string>$SHORT_VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>© Tako Bruinsma. MIT License.</string>
</dict>
</plist>
EOF

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" build/ttsync "$APP/Contents/MacOS/ttsync"
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - build/ttsync "$APP/Contents/MacOS/ttsync"
    codesign --force --sign - "$APP"
fi
echo "Built $APP and build/ttsync ($VERSION)"

if [ "$ZIP" = 1 ]; then
    OUT="build/TomTomSync-$VERSION.zip"
    rm -f "$OUT"
    if [ -n "${SIGN_IDENTITY:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
        ditto -c -k --keepParent "$APP" build/notarize.zip
        xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$APP"
        rm build/notarize.zip
    fi
    ditto -c -k --keepParent "$APP" "$OUT"
    echo "Created $OUT"
fi

if [ "$INSTALL" = 1 ]; then
    mkdir -p "$HOME/Applications"
    pkill -x TomTomSync 2>/dev/null || true
    rm -rf "$HOME/Applications/TomTomSync.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "Installed to ~/Applications/TomTomSync.app"
fi

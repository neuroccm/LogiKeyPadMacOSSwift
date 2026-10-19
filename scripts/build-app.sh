#!/bin/zsh
# Builds LogiKeyPad.app (release) into ./build — ad-hoc signed, private use.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "== swift build (release) =="
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/LogiKeyPad.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/LogiKeyPad" "$APP/Contents/MacOS/LogiKeyPad"
[ -f assets/AppIcon.icns ] && cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundle (catalog.json) — place where Bundle.module looks.
cp -R "$BIN_DIR/LogiKeyPad_LogiKeyPad.bundle" "$APP/Contents/Resources/"
cp -R "$BIN_DIR/LogiKeyPad_LogiKeyPad.bundle" "$APP/Contents/MacOS/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>LogiKeyPad</string>
    <key>CFBundleDisplayName</key><string>LogiKeyPad</string>
    <key>CFBundleIdentifier</key><string>local.logikeypad.app</string>
    <key>CFBundleExecutable</key><string>LogiKeyPad</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LogiKeyPad opens Terminal sessions (for example Claude Code) in your repo when you press a key.</string>
    <key>NSHumanReadableCopyright</key><string>Private on-device use.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "== built: $APP =="
echo "Install with:  cp -R $APP /Applications/   (then launch LogiKeyPad)"

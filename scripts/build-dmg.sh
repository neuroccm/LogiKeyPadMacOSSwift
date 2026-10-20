#!/bin/zsh
# Full release build: app + a NEW timestamped DMG on the Desktop, every run.
# Old DMGs are kept (each filename is unique) — delete them at leisure.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' build/LogiKeyPad.app/Contents/Info.plist)"
STAMP="$(date +%Y%m%d-%H%M)"
DMG_NAME="LogiKeyPad-${VERSION}-${STAMP}.dmg"
STAGING="$(mktemp -d /tmp/logikeypad-dmg.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

cp -R build/LogiKeyPad.app "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/README.md"

hdiutil create -volname "LogiKeyPad" -srcfolder "$STAGING" -ov -format UDZO "/tmp/$DMG_NAME"
hdiutil verify "/tmp/$DMG_NAME" | tail -1

# Desktop placement: direct copy when permitted; Finder otherwise (sandboxed shells).
if cp "/tmp/$DMG_NAME" "$HOME/Desktop/$DMG_NAME" 2>/dev/null; then
  echo "== DMG: ~/Desktop/$DMG_NAME =="
else
  osascript -e "tell application \"Finder\" to duplicate (POSIX file \"/tmp/$DMG_NAME\" as alias) to desktop with replacing" >/dev/null
  echo "== DMG (via Finder): ~/Desktop/$DMG_NAME =="
fi
ls -la "$HOME/Desktop/$DMG_NAME"

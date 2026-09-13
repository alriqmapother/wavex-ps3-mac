#!/bin/zsh
# Packages build/Wave X.app into a drag-to-Applications disk image: build/Wave-X-<version>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Wave X.app"
[ -d "$APP" ] || { echo "Build the app first: Scripts/build-app.sh" >&2; exit 1; }
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
STAGE="build/dmg-stage"
DMG="build/Wave-X-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Wave X" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "DMG: $DMG ($(du -h "$DMG" | cut -f1))"

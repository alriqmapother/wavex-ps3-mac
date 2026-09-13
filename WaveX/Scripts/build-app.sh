#!/bin/zsh
# Builds Wave X.app with the Command Line Tools only (no Xcode required).
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Universal (Apple Silicon + Intel) when both SDK slices are available; falls back to native.
if swift build -c "$CONFIG" --arch arm64 --arch x86_64 && [ -f ".build/out/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/WaveX" ]; then
  BIN=".build/out/Products/$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}/WaveX"
else
  swift build -c "$CONFIG"
  BIN=".build/$CONFIG/WaveX"
fi

APP="build/Wave X.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WaveX"
cp Scripts/Info.plist "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

# App icon: use the committed one; otherwise render a still with the app itself and build an .icns.
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
elif "$BIN" --render-icon build/icon-1024.png; then
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s*2))
    sips -z $d $d build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
lipo -info "$APP/Contents/MacOS/WaveX" | sed 's/^/Binary: /'
echo "Built: $APP"

# Distributable archive (ditto keeps the bundle structure and resource forks intact).
rm -f "build/Wave X.zip"
ditto -c -k --keepParent "$APP" "build/Wave X.zip"
echo "Archive: build/Wave X.zip ($(du -h "build/Wave X.zip" | cut -f1))"

#!/bin/sh
# Builds dist/Keepwatch.app (universal: arm64 + x86_64) from the SwiftPM package.
# Usage: scripts/build-app.sh [--arm64-only]
set -eu
cd "$(dirname "$0")/.."
ARCHS="--arch arm64 --arch x86_64"
[ "${1:-}" = "--arm64-only" ] && ARCHS="--arch arm64"
# shellcheck disable=SC2086
swift build -c release $ARCHS
BINDIR="$(swift build -c release $ARCHS --show-bin-path)"
BIN="$BINDIR/Keepwatch"
APP=dist/Keepwatch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Keepwatch"
cp "$BINDIR/keepwatch-cli" "$APP/Contents/MacOS/keepwatch-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Icon: Resources/AppIcon-1024.png is rendered from assets/icon.svg
# (see assets/README.md). Build the .icns once and cache it in build/.
if [ ! -f build/AppIcon.icns ] || [ Resources/AppIcon-1024.png -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    d=$((s * 2)); sips -z $d $d Resources/AppIcon-1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
echo "Built $APP"

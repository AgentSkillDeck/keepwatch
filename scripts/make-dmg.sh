#!/bin/sh
# Builds a signed, notarized and stapled dist/Keepwatch-VERSION.dmg from the
# already notarized dist/Keepwatch.app (run scripts/notarize.sh first).
# The disk image opens to Keepwatch.app beside an Applications shortcut.
# Usage: scripts/make-dmg.sh [profile-name]   (default: keepwatch-notary)
set -eu
cd "$(dirname "$0")/.."
PROFILE="${1:-keepwatch-notary}"
APP=dist/Keepwatch.app
IDENTITY="${KEEPWATCH_SIGN_IDENTITY:-Developer ID Application: Laxman Khatri (S99G3X6RPM)}"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
DMG="dist/Keepwatch-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Keepwatch.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Keepwatch $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Notarized: $DMG"

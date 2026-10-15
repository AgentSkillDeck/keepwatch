#!/bin/sh
# Notarizes and staples dist/Keepwatch.app, then builds a zip for release.
# One-time setup (stores an app-specific password in your keychain):
#   xcrun notarytool store-credentials keepwatch-notary --apple-id YOU@EXAMPLE.COM --team-id S99G3X6RPM
# Any notarytool profile for team S99G3X6RPM works (the maintainer uses jobcairn-notary,
# an App Store Connect API key profile).
# Usage: scripts/notarize.sh [profile-name]   (default: keepwatch-notary)
set -eu
cd "$(dirname "$0")/.."
PROFILE="${1:-keepwatch-notary}"
APP=dist/Keepwatch.app
ZIP=dist/Keepwatch-notarize.zip
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
spctl -a -vv "$APP"
rm -f "$ZIP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
ditto -c -k --keepParent "$APP" "dist/Keepwatch-$VERSION.zip"
echo "Notarized: dist/Keepwatch-$VERSION.zip"

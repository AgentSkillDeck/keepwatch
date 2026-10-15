#!/bin/sh
# Signs dist/Keepwatch.app with Developer ID + hardened runtime.
# Usage: scripts/sign.sh ["Developer ID Application: Name (TEAMID)"]
# With no argument, uses the first Developer ID Application identity found.
set -eu
cd "$(dirname "$0")/.."
APP=dist/Keepwatch.app
ID="${1:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[ -n "$ID" ] || { echo "No Developer ID Application identity found" >&2; exit 1; }
# Inner binaries first, then the bundle (no --deep).
codesign --force --options runtime --timestamp -s "$ID" "$APP/Contents/MacOS/keepwatch-cli"
codesign --force --options runtime --timestamp \
  --entitlements Resources/Keepwatch.entitlements -s "$ID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Signed with: $ID"

#!/bin/sh
# Builds dist/keepwatch-cli-VERSION-macos.zip: the keepwatch command on its own,
# without the app (universal: arm64 + x86_64), plus LICENSE and NOTICE.
# It does not sign or notarize; it prints the maintainer's next steps.
# Usage: scripts/make-cli-zip.sh
set -eu
cd "$(dirname "$0")/.."
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCHS="--arch arm64 --arch x86_64"
# shellcheck disable=SC2086
swift build -c release $ARCHS --product keepwatch-cli
# shellcheck disable=SC2086
BINDIR="$(swift build -c release $ARCHS --show-bin-path)"
NAME="keepwatch-cli-$VERSION-macos"
ZIP="dist/$NAME.zip"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME" dist
cp "$BINDIR/keepwatch-cli" "$STAGE/$NAME/keepwatch"
cp LICENSE NOTICE "$STAGE/$NAME/"
chmod 755 "$STAGE/$NAME/keepwatch"
rm -f "$ZIP"
ditto -c -k --norsrc --noextattr --keepParent "$STAGE/$NAME" "$ZIP"
echo "Built $ZIP ($(lipo -archs "$STAGE/$NAME/keepwatch"))"
cat <<EOF

Not signed. Next steps for the maintainer:
  1. Unpack it and sign the binary with Developer ID and the hardened runtime:
       ditto -x -k $ZIP dist
       codesign --force --options runtime --timestamp -s "Developer ID Application: …" dist/$NAME/keepwatch
  2. Zip it again and notarize the zip:
       rm $ZIP && ditto -c -k --norsrc --noextattr --keepParent dist/$NAME $ZIP
       xcrun notarytool submit $ZIP --keychain-profile <profile> --wait
  3. A bare binary can't be stapled, so Gatekeeper checks it online the first
     time it runs. Upload the zip to the v$VERSION release and put its sha256
     (shasum -a 256 $ZIP) in packaging/homebrew/keepwatch-cli.rb.
EOF

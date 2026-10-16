#!/bin/sh
# Installs the keepwatch command on its own, without the app:
#   curl -fsSL https://raw.githubusercontent.com/AgentSkillDeck/keepwatch/main/scripts/install-cli.sh | sh
# It downloads keepwatch-cli-VERSION-macos.zip from the GitHub release, checks
# it against the release's SHA256SUMS.txt and checks that the binary is signed
# by Keepwatch's Developer ID team, then copies it to ~/.local/bin (or
# $KEEPWATCH_BIN). No sudo, nothing else changed.
# KEEPWATCH_VERSION=0.3.0 picks a version; the default is the latest release.
set -eu
REPO="https://github.com/AgentSkillDeck/keepwatch"
TEAM="S99G3X6RPM"
BIN="${KEEPWATCH_BIN:-$HOME/.local/bin}"

fail() { echo "keepwatch install: $*" >&2; exit 1; }
[ "$(uname -s)" = Darwin ] || fail "Keepwatch is for macOS."

VERSION="${KEEPWATCH_VERSION:-}"
if [ -z "$VERSION" ]; then
  # The latest-release page redirects to .../releases/tag/vX.Y.Z.
  TAG=$(curl -fsSI "$REPO/releases/latest" | tr -d '\r' | sed -n 's#^[Ll]ocation: .*/releases/tag/v\(.*\)$#\1#p' | tail -1)
  VERSION="$TAG"
fi
echo "$VERSION" | grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' || fail "couldn't find the latest version (got '$VERSION')."
BASE="${KEEPWATCH_BASE_URL:-$REPO/releases/download/v$VERSION}"
NAME="keepwatch-cli-$VERSION-macos"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "Downloading keepwatch ${VERSION}..."
curl -fsSL -o "$WORK/$NAME.zip" "$BASE/$NAME.zip" || fail "download failed: $BASE/$NAME.zip"
curl -fsSL -o "$WORK/SHA256SUMS.txt" "$BASE/SHA256SUMS.txt" || fail "download failed: $BASE/SHA256SUMS.txt"

EXPECTED=$(awk -v f="$NAME.zip" '$2 == f { print tolower($1) }' "$WORK/SHA256SUMS.txt")
ACTUAL=$(shasum -a 256 "$WORK/$NAME.zip" | awk '{ print $1 }')
[ -n "$EXPECTED" ] || fail "SHA256SUMS.txt doesn't list $NAME.zip."
[ "$EXPECTED" = "$ACTUAL" ] || fail "checksum mismatch; not installing."

ditto -x -k "$WORK/$NAME.zip" "$WORK" || fail "couldn't unzip."
CMD="$WORK/$NAME/keepwatch"
[ -f "$CMD" ] || fail "the zip has no keepwatch binary."
codesign --verify --strict "$CMD" 2>/dev/null || fail "the binary's signature is invalid; not installing."
codesign -dv "$CMD" 2>&1 | grep -qx "TeamIdentifier=$TEAM" || fail "the binary isn't signed by Keepwatch's team; not installing."

mkdir -p "$BIN"
cp "$CMD" "$BIN/keepwatch.new" && chmod 755 "$BIN/keepwatch.new" && mv -f "$BIN/keepwatch.new" "$BIN/keepwatch"
echo "Installed $("$BIN/keepwatch" version) to $BIN/keepwatch"
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "Add it to your PATH: echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && exec zsh" ;;
esac
echo "Lid-closed sessions (keepwatch lid start) need the app: $REPO/releases/latest"

#!/usr/bin/env bash
# Builds Frost.app (universal), signs it with Developer ID + hardened runtime,
# wraps it in a DMG, and notarizes + staples the DMG.
#
#   scripts/build.sh            # full release: build, sign, DMG, notarize
#   scripts/build.sh --dev      # build + ad-hoc-free local sign, no DMG/notarize
#
# Notarization reads APPLE_API_KEY / APPLE_API_KEY_ID / APPLE_API_ISSUER from
# $FROST_NOTARIZE_ENV (defaults to the vimyasa support env file).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Developer ID Application: Taesong Kim (SPJZZKVU87)}"
ENV_FILE="${FROST_NOTARIZE_ENV:-$HOME/DevProjects2/vimyasa support/notarize.env}"

DEV=0
[ "${1:-}" = "--dev" ] && DEV=1

OUT=dist
APP="$OUT/Frost.app"
rm -rf "$APP"
mkdir -p "$OUT"

echo "=== Compiling (universal, release) ==="
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Frost"

echo "=== Assembling bundle ==="
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Frost"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "=== Signing app ==="
codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [ "$DEV" = 1 ]; then
  echo "Dev build ready: $APP"
  exit 0
fi

DMG="$OUT/Frost-$VERSION.dmg"
echo "=== Building $DMG ==="
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Frost" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

if [ ! -f "$ENV_FILE" ]; then
  echo "No notarization env at $ENV_FILE — skipping notarization. DMG: $DMG"
  exit 0
fi
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

echo "=== Notarizing (usually a few minutes) ==="
xcrun notarytool submit "$DMG" \
  --key "$APPLE_API_KEY" \
  --key-id "$APPLE_API_KEY_ID" \
  --issuer "$APPLE_API_ISSUER" \
  --wait

echo "=== Stapling ==="
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG" || true

echo ""
echo "Done: $DMG"

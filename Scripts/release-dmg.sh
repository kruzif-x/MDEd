#!/bin/bash
#
# release-dmg.sh — sign, package, notarize, and staple an MDEd release DMG.
#
#   Usage:
#     ./Scripts/release-dmg.sh [path/to/MDEd.app] [version]
#
#   Env:
#     CERT_NAME       codesign identity, e.g. "Developer ID Application: Roland Chia (TEAMID)"
#     NOTARY_PROFILE  notarytool keychain profile (see `xcrun notarytool store-credentials --help`)
#                     e.g. "AC_PASSWORD"
#
#   Exit codes: 0 = fully signed + notarized + stapled; non-zero = something failed (see output).
#
set -euo pipefail

APP_PATH="${1:-}"
VERSION="${2:-0.1b}"
CERT_NAME="${CERT_NAME:?set CERT_NAME (Developer ID identity, e.g. 'Developer ID Application: Name (TEAMID)')}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile name)}"

if [ -z "$APP_PATH" ]; then
  APP_PATH="$(find "${DERIVED_DATA:-/tmp/mded-dd-universal}" -name 'MDEd.app' -maxdepth 6 2>/dev/null | head -1)"
fi
[ -d "$APP_PATH" ] || { echo "no app bundle at '$APP_PATH'" >&2; exit 2; }

OUT_DIR="$(cd "$(dirname "$APP_PATH")/.." && pwd)"
APP_NAME="$(basename "$APP_PATH" .app)"
DMG_NAME="${APP_NAME}-${VERSION}-universal.dmg"
DMG_PATH="${OUT_DIR}/${DMG_NAME}"
STAGE="$(mktemp -d)"

cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

echo "==> 1/8 codesign app (hardened runtime)"
codesign --deep --force --options=runtime --timestamp \
  --sign "$CERT_NAME" "$APP_PATH"

echo "==> 2/8 verify app signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E "Authority|Hardened" || true

echo "==> 3/8 verify universal slices"
lipo -archs "$APP_PATH/Contents/MacOS/MDEd" | grep -q "x86_64" || { echo "no x86_64 slice — not a universal build" >&2; exit 2; }

echo "==> 4/8 stage DMG layout"
mkdir -p "$STAGE"
ditto "$APP_PATH" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"

echo "==> 5/8 create DMG"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ "$DMG_PATH"

echo "==> 6/8 sign DMG"
codesign --force --sign "$CERT_NAME" "$DMG_PATH"

echo "==> 7/8 notarize ($DMG_PATH)"
xcrun notarytool submit "$DMG_PATH" \
  --keychain-profile "$NOTARY_PROFILE" \
  --wait --timeout 900

echo "==> 8/8 staple + verify"
xcrun notarytool staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG_PATH" || true

echo "==> OK: $DMG_PATH"
echo "    upload: gh release upload v${VERSION} '${DMG_PATH}'"

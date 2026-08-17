#!/bin/bash
#
# release-dmg.sh — build, sign, notarize, and staple MDEd release DMGs per architecture.
#
# Produces two DMGs: MDEd-<version>-arm64.dmg and MDEd-<version>-x86_64.dmg,
# each containing an app built for exactly that architecture. Each DMG gets its
# own notarization submission (notarization is per-file).
#
#   Usage:
#     ./Scripts/release-dmg.sh [version]
#
#   Env:
#     CERT_NAME       codesign identity, e.g. "Developer ID Application: Roland Chia (TEAMID)"
#     NOTARY_PROFILE  notarytool keychain profile (see `xcrun notarytool store-credentials --help`)
#     DERIVED_DATA    build root (default /tmp/mded-dd-<arch>)
#
#   Exit codes: 0 = both DMGs fully signed + notarized + stapled; non-zero = a step failed.
#
set -euo pipefail

VERSION="${1:-0.1b}"
CERT_NAME="${CERT_NAME:?set CERT_NAME (Developer ID identity, e.g. 'Developer ID Application: Name (TEAMID)')}"
NOTARY_PROFILE="${NOTARY_PROFILE:?set NOTARY_PROFILE (notarytool keychain profile name)}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHS=(arm64 x86_64)

for ARCH in "${ARCHS[@]}"; do
  echo "==================================================="
  echo "==> ARCH $ARCH"
  echo "==================================================="
  DD="${DERIVED_DATA:-/tmp/mded-dd-$ARCH}"
  APP_PATH="$DD/Build/Products/Release/MDEd.app"
  DMG_PATH="$REPO_ROOT/dist/MDEd-${VERSION}-${ARCH}.dmg"
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT

  echo "==> 1/8 build (ARCHS=$ARCH)"
  ( cd "$REPO_ROOT" && xcodebuild -scheme MDEd -configuration Release \
      -derivedDataPath "$DD" ARCHS="$ARCH" ONLY_ACTIVE_ARCH=NO build >/dev/null )

  echo "==> 2/8 codesign app (hardened runtime)"
  codesign --deep --force --options=runtime --timestamp \
    --sign "$CERT_NAME" "$APP_PATH"

  echo "==> 3/8 verify app signature"
  codesign --verify --deep --strict --verbose=2 "$APP_PATH"
  codesign -dv --verbose=2 "$APP_PATH" 2>&1 | grep -E "Authority|Hardened" || true

  echo "==> 4/8 verify single-arch slice"
  SLICES="$(lipo -archs "$APP_PATH/Contents/MacOS/MDEd")"
  [ "$SLICES" = "$ARCH" ] || { echo "expected slice '$ARCH', got '$SLICES'" >&2; exit 2; }

  echo "==> 5/8 stage DMG layout"
  mkdir -p "$(dirname "$DMG_PATH")" "$STAGE"
  cp -R "$APP_PATH" "$STAGE/MDEd.app"
  ln -s /Applications "$STAGE/Applications"

  echo "==> 6/8 create DMG"
  rm -f "$DMG_PATH"
  hdiutil create -volname MDEd -srcfolder "$STAGE" \
    -ov -format UDZO -fs HFS+ "$DMG_PATH"

  echo "==> 7/8 sign DMG + notarize"
  codesign --force --sign "$CERT_NAME" "$DMG_PATH"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait --timeout 900

  echo "==> 8/8 staple + verify"
  xcrun notarytool staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --verbose=4 --type open \
    --context context:primary-signature "$DMG_PATH" || true

  echo "==> OK: $DMG_PATH"
done

echo "==> ALL DONE:"
echo "    dist/MDEd-${VERSION}-arm64.dmg"
echo "    dist/MDEd-${VERSION}-x86_64.dmg"
echo "    upload: gh release upload v${VERSION} dist/MDEd-${VERSION}-arm64.dmg dist/MDEd-${VERSION}-x86_64.dmg"

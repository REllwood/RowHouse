#!/usr/bin/env bash
# Builds a universal, signed RowHouse and packages it as a DMG and a zip in .build/release-artifacts/.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=rowhouse-notary \
#   scripts/release.sh
#
# SIGN_IDENTITY  optional; without it the app is ad-hoc signed.
# NOTARY_PROFILE optional; a keychain profile created with `xcrun notarytool store-credentials`.
#                When set, the DMG is notarised and the ticket is stapled to the DMG and the app.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
OUT=".build/release-artifacts"
APP=".build/app/RowHouse.app"
DMG="$OUT/RowHouse-$VERSION.dmg"
ZIP="$OUT/RowHouse-$VERSION.zip"

CONFIG=release scripts/build-app.sh

rm -rf "$OUT"
mkdir -p "$OUT/stage"
cp -R "$APP" "$OUT/stage/"
ln -s /Applications "$OUT/stage/Applications"
hdiutil create -quiet -volname "RowHouse $VERSION" -srcfolder "$OUT/stage" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$OUT/stage"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler staple "$APP"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "Release artifacts:"
ls -lh "$OUT"

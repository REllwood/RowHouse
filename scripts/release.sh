#!/usr/bin/env bash
# Builds a universal, signed RowHouse and packages it as a DMG and a zip in .build/release-artifacts/.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=rowhouse-notary \
#   scripts/release.sh
#
# SIGN_IDENTITY  required; a Developer ID Application signing identity.
# NOTARY_PROFILE required; an existing `notarytool` keychain profile.
# The previous artifacts move to .build/release-artifacts-previous/. Use build-app.sh for development builds.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < VERSION)"
OUT=".build/release-artifacts"
APP=".build/app/RowHouse.app"
DMG="$OUT/RowHouse-$VERSION.dmg"
ZIP="$OUT/RowHouse-$VERSION.zip"
WORK=".build/release-work"

: "${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity.}"
: "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool keychain profile.}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "Release builds require a Developer ID Application identity, not ad-hoc signing." >&2
  exit 1
fi

echo "Checking notarisation credentials…"
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json > /dev/null

notarise() {
  local artifact="$1" report="$2" status
  echo "Waiting for Apple to notarise $(basename "$artifact")…"
  if ! xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$report"; then
    cat "$report" >&2
    return 1
  fi
  status=$(plutil -extract status raw -o - "$report")
  if [[ "$status" != "Accepted" ]]; then
    cat "$report" >&2
    echo "Apple did not accept this submission. Release stopped." >&2
    return 1
  fi
}

CONFIG=release scripts/build-app.sh

# One fixed scratch folder and one previous set of artifacts, replaced on every release.
rm -rf "${WORK:?}" "${OUT:?}-previous"
if [[ -e "$OUT" ]]; then
  mv "$OUT" "$OUT-previous"
fi
mkdir -p "$OUT" "$WORK/stage"

# Staple the app before packaging so both downloads contain its approval ticket.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$WORK/RowHouse-submission.zip"
notarise "$WORK/RowHouse-submission.zip" "$WORK/app-notary.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"

cp -R "$APP" "$WORK/stage/"
ln -s /Applications "$WORK/stage/Applications"
hdiutil create -quiet -volname "RowHouse $VERSION" -srcfolder "$WORK/stage" -fs HFS+ -format UDZO "$DMG"
codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
notarise "$DMG" "$WORK/dmg-notary.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)
echo "Release artifacts:"
ls -lh "$OUT"

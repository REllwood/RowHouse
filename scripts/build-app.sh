#!/usr/bin/env bash
# Builds RowHouse.app into .build/app/ (always the same path; each build replaces the last).
#
#   scripts/build-app.sh                 # universal release build, ad-hoc signed
#   CONFIG=debug scripts/build-app.sh    # fast single-arch debug build
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # hardened runtime + timestamp
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP=".build/app/RowHouse.app"

if [[ "$CONFIG" == "release" ]]; then
  swift build -c release --arch arm64 --arch x86_64 --product RowHouse
  BIN=".build/apple/Products/Release/RowHouse"
else
  swift build -c debug --product RowHouse
  BIN="$(swift build -c debug --show-bin-path)/RowHouse"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RowHouse"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Packaging/AppIcon.icns ]]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp \
    --entitlements Packaging/RowHouse.entitlements \
    --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - --entitlements Packaging/RowHouse.entitlements "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER, $CONFIG)"

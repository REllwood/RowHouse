#!/usr/bin/env bash
# Builds RowHouse.app into .build/app/; the previous bundle moves to .build/app-previous/.
# The app bundles the rowhouse-mcp helper (Contents/MacOS/rowhouse-mcp) for AI assistants.
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
HELPER="$APP/Contents/MacOS/rowhouse-mcp"

if [[ "$CONFIG" == "release" ]]; then
  swift build -c release --arch arm64 --arch x86_64 --product RowHouse
  swift build -c release --arch arm64 --arch x86_64 --product rowhouse-mcp
  BIN_DIR=".build/apple/Products/Release"
else
  swift build -c debug --product RowHouse
  swift build -c debug --product rowhouse-mcp
  BIN_DIR="$(swift build -c debug --show-bin-path)"
fi

# Keep exactly one previous bundle, at a fixed path, replaced on every build.
if [[ -e "$APP" ]]; then
  rm -rf .build/app-previous
  mkdir -p .build/app-previous
  mv "$APP" .build/app-previous/RowHouse.app
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/RowHouse" "$APP/Contents/MacOS/RowHouse"
cp "$BIN_DIR/rowhouse-mcp" "$HELPER"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" Packaging/Info.plist > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [[ -f Packaging/AppIcon.icns ]]; then
  cp Packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# The helper is signed first so the app's signature seals the signed helper.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  SIGN_ARGS=(--force --options runtime --timestamp --entitlements Packaging/RowHouse.entitlements --sign "$SIGN_IDENTITY")
else
  SIGN_ARGS=(--force --entitlements Packaging/RowHouse.entitlements --sign -)
fi
codesign "${SIGN_ARGS[@]}" --identifier com.rellwood.RowHouse.mcp "$HELPER"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict "$HELPER"
codesign --verify --strict "$APP"
echo "Built $APP ($VERSION build $BUILD_NUMBER, $CONFIG)"

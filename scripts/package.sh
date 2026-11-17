#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

./build.sh

APP="build/影桥.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP_NAME="Yingqiao-macOS-universal.zip"
DMG_NAME="Yingqiao-$VERSION-macOS-universal.dmg"
mkdir -p Distribution dist

ditto -c -k --keepParent --rsrc --extattr "$APP" "Distribution/$ZIP_NAME"
(
  cd Distribution
  shasum -a 256 "$ZIP_NAME" > SHA256SUMS
)

STAGING_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/yingqiao-package.XXXXXX")"
trap 'rm -rf "$STAGING_DIRECTORY"' EXIT
ditto --rsrc --extattr "$APP" "$STAGING_DIRECTORY/影桥.app"
ln -s /Applications "$STAGING_DIRECTORY/Applications"
hdiutil create -volname "影桥 $VERSION" -srcfolder "$STAGING_DIRECTORY" \
  -fs HFS+ -format UDZO -ov "dist/$DMG_NAME"

ZIP_CHECKSUM="$(shasum -a 256 "Distribution/$ZIP_NAME")"
DMG_CHECKSUM="$(shasum -a 256 "dist/$DMG_NAME")"
printf '%s  %s\n%s  %s\n' "${ZIP_CHECKSUM%% *}" "$ZIP_NAME" \
  "${DMG_CHECKSUM%% *}" "$DMG_NAME" > dist/SHA256SUMS

echo "Packaged: $PROJECT_ROOT/Distribution/$ZIP_NAME"
echo "Packaged: $PROJECT_ROOT/dist/$DMG_NAME"

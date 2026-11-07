#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh release
APP='build/Catch what you see.app'
codesign --verify --deep --strict "$APP"
lipo "$APP/Contents/MacOS/CatchWhatYouSee" -verify_arch arm64 x86_64
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
mkdir -p build/dist
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Catch what you see.app"
ln -s /Applications "$STAGE/Applications"
cp ../docs/INSTALL.md "$STAGE/安装说明.md"
cp ../LICENSE "$STAGE/LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$STAGE/THIRD_PARTY_NOTICES.md"
DMG="build/dist/Catch-what-you-see-${VERSION}-universal.dmg"
hdiutil create -volname 'Catch what you see' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
hdiutil verify "$DMG"
(cd build/dist && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
echo "$DMG"

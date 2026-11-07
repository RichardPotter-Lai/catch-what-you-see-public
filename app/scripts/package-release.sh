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
VERIFY_MOUNT=''
cleanup() {
  if [ -n "$VERIFY_MOUNT" ]; then
    hdiutil detach "$VERIFY_MOUNT" >/dev/null 2>&1 || true
    rmdir "$VERIFY_MOUNT" 2>/dev/null || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT
ditto "$APP" "$STAGE/Catch what you see.app"
ln -s /Applications "$STAGE/Applications"
cp ../docs/INSTALL.md "$STAGE/安装说明.md"
cp ../LICENSE "$STAGE/LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$STAGE/THIRD_PARTY_NOTICES.md"
DMG="build/dist/Catch-what-you-see-${VERSION}-universal.dmg"
hdiutil create -volname 'Catch what you see' -srcfolder "$STAGE" -format UDZO -ov "$DMG"
if ! hdiutil verify "$DMG"; then
  # Newer macOS can create a valid UDIF image while the legacy verifier fails.
  # Require a read-only mount and compare every shipped file before publishing.
  VERIFY_MOUNT=$(mktemp -d)
  diskutil image attach --readOnly --nobrowse --mountPoint "$VERIFY_MOUNT" "$DMG"
  diff -qr "$APP" "$VERIFY_MOUNT/Catch what you see.app"
  cmp ../docs/INSTALL.md "$VERIFY_MOUNT/安装说明.md"
  cmp ../LICENSE "$VERIFY_MOUNT/LICENSE"
  cmp ../THIRD_PARTY_NOTICES.md "$VERIFY_MOUNT/THIRD_PARTY_NOTICES.md"
  test "$(readlink "$VERIFY_MOUNT/Applications")" = /Applications
  codesign --verify --deep --strict "$VERIFY_MOUNT/Catch what you see.app"
  hdiutil detach "$VERIFY_MOUNT"
  rmdir "$VERIFY_MOUNT" 2>/dev/null || true
  VERIFY_MOUNT=''
fi
(cd build/dist && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)
echo "$DMG"

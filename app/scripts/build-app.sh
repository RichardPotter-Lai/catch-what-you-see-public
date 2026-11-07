#!/bin/bash
# Builds CatchWhatYouSee.app into ./build without needing Xcode.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/Catch what you see.app"
VERSION="0.1.1"

# Builds one architecture and prints the binary's path.
# The Command Line Tools for macOS 27 ship an SDK whose SwiftUI needs a macro
# plugin they do not include. If the default SDK fails, fall back to the
# newest macOS 26 SDK installed alongside it.
build_arch() {
  local triple="$1-apple-macosx14.0"
  if [ -z "${SDKROOT:-}" ] && ! swift build -c "$CONFIG" --triple "$triple" >&2; then
    FALLBACK="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)"
    if [ -z "$FALLBACK" ]; then exit 1; fi
    echo "Retrying with $FALLBACK" >&2
    export SDKROOT="$FALLBACK"
  fi
  if [ -n "${SDKROOT:-}" ]; then swift build -c "$CONFIG" --triple "$triple" >&2; fi
  cp "$(swift build -c "$CONFIG" --triple "$triple" --show-bin-path)/CatchWhatYouSee" "$OUT/CatchWhatYouSee-$1"
}

# A universal binary, so it runs on Apple silicon and on Intel Macs, from
# macOS 14 Sonoma onwards.
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
if [ "$CONFIG" = debug ]; then
  build_arch "$(uname -m)"
  cp "$OUT/CatchWhatYouSee-$(uname -m)" "$OUT/CatchWhatYouSee"
else
  build_arch arm64
  build_arch x86_64
  lipo -create "$OUT/CatchWhatYouSee-arm64" "$OUT/CatchWhatYouSee-x86_64" -output "$OUT/CatchWhatYouSee"
fi
BIN="$OUT/CatchWhatYouSee"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CatchWhatYouSee"
cp ../LICENSE "$APP/Contents/Resources/LICENSE"
cp ../THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"

# Icon
WORK="$(mktemp -d)"
swift scripts/make-capture-icon.swift "$WORK/icon.png"
ICONSET="$WORK/CatchWhatYouSee.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$WORK/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/CatchWhatYouSee.icns"
rm -rf "$WORK"

# This independent first release supports Simplified Chinese. Keep upstream
# translations in source; do not advertise languages with untranslated new UI.
LANGUAGES="<string>zh-Hans</string>"
cp -R Sources/Tendedero/Resources/zh-Hans.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Catch what you see</string>
  <key>CFBundleDisplayName</key><string>Catch what you see</string>
  <key>CFBundleIdentifier</key><string>local.catchwhatyousee.mac</string>
  <key>CFBundleExecutable</key><string>CatchWhatYouSee</string>
  <key>CFBundleIconFile</key><string>CatchWhatYouSee</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array>${LANGUAGES}</array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSDesktopFolderUsageDescription</key>
  <string>CatchWhatYouSee watches the folder where macOS saves your screenshots so it can hang them on the line.</string>
  <key>NSDocumentsFolderUsageDescription</key>
  <string>CatchWhatYouSee watches the folder you chose so it can hang new images on the line.</string>
  <key>NSDownloadsFolderUsageDescription</key>
  <string>CatchWhatYouSee watches the folder you chose so it can hang new images on the line.</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key><dict><key>default</key><string>收藏到 Catch what you see</string></dict>
      <key>NSMessage</key><string>collectText</string>
      <key>NSPortName</key><string>Catch what you see</string>
      <key>NSRequiredContext</key><dict/>
      <key>NSSendTypes</key><array><string>NSStringPboardType</string><string>public.utf8-plain-text</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# Sign with a Developer ID when one is in the keychain (or SIGN_IDENTITY is
# set), with the hardened runtime and a secure timestamp that notarization
# requires. Without one, sign ad hoc so the app still runs locally.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  echo "Signed with $IDENTITY"
else
  codesign --force --deep --sign - "$APP" >/dev/null
  echo "Signed ad hoc (no Developer ID found)"
fi
echo "Built $APP"

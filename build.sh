#!/bin/bash
# Builds Lelap.app next to this script with swiftc (no Xcode project).
#
#   bash build.sh               for this Mac's CPU
#   bash build.sh --universal   one app for Apple Silicon and Intel
set -e
cd "$(dirname "$0")"

case "${1:-}" in
    "" | --universal) ;;
    *) echo "Usage: bash build.sh [--universal]" >&2; exit 64 ;;
esac

APP=Lelap.app
BIN="$APP/Contents/MacOS/Lelap"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

# -target keeps the minimum at macOS 13. Without it, swiftc requires the
# macOS version of the Mac doing the build.
if [ "${1:-}" = --universal ]; then
    swiftc -O -parse-as-library -target arm64-apple-macos13 Lelap.swift -o "$BIN-arm64"
    swiftc -O -parse-as-library -target x86_64-apple-macos13 Lelap.swift -o "$BIN-x86_64"
    lipo -create "$BIN-arm64" "$BIN-x86_64" -output "$BIN"
    rm "$BIN-arm64" "$BIN-x86_64"
else
    swiftc -O -parse-as-library -target "$(uname -m)-apple-macos13" Lelap.swift -o "$BIN"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Lelap</string>
    <key>CFBundleIdentifier</key>
    <string>com.user.lelap</string>
    <key>CFBundleExecutable</key>
    <string>Lelap</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "$PWD/$APP"

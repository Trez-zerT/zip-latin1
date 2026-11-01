#!/bin/bash
# Build a universal release archive in dist/.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
APP="build/ZipLatin1.app"
ZIP="dist/ZipLatin1-$VERSION.zip"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

echo "Compiling (arm64 + x86_64)…"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 main.swift \
    -o build/ZipLatin1-arm64
swiftc -O -swift-version 5 -target x86_64-apple-macos14.0 main.swift \
    -o build/ZipLatin1-x86_64
lipo -create build/ZipLatin1-arm64 build/ZipLatin1-x86_64 \
    -output "$APP/Contents/MacOS/ZipLatin1"
chmod +x "$APP/Contents/MacOS/ZipLatin1"

cp zip_latin1.py AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"

codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Packing…"
xattr -cr "$APP" 2>/dev/null || true
ditto -c -k --keepParent --norsrc --noextattr "$APP" "$ZIP"

echo
echo "Built $ZIP"
file "$APP/Contents/MacOS/ZipLatin1"
shasum -a 256 "$ZIP"

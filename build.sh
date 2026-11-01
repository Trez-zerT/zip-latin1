#!/bin/bash
# Build ZipLatin1.app into ~/Applications (or the path given as $1).
set -euo pipefail
cd "$(dirname "$0")"

APP="${1:-$HOME/Applications/ZipLatin1.app}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Compiling…"
swiftc -O -swift-version 5 main.swift -o "$APP/Contents/MacOS/ZipLatin1"

cp zip_latin1.py "$APP/Contents/Resources/"
cp AppIcon.icns "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$APP" >/dev/null

echo "Built $APP"

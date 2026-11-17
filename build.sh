#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_ROOT"

mkdir -p build/arm64 build/x86_64
for architecture in arm64 x86_64; do
  xcrun swiftc -parse-as-library -swift-version 5 Sources/main.swift \
    -o "build/$architecture/PhoneMediaImporter" \
    -target "$architecture-apple-macosx14.0" \
    -framework AppKit \
    -framework SwiftUI \
    -framework AVFoundation \
    -framework ImageCaptureCore \
    -framework ImageIO \
    -framework Photos \
    -framework PhotosUI \
    -framework UniformTypeIdentifiers
done
xcrun lipo -create build/arm64/PhoneMediaImporter build/x86_64/PhoneMediaImporter \
  -output build/PhoneMediaImporter
xcrun lipo build/PhoneMediaImporter -verify_arch arm64 x86_64

APP="build/影桥.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/PhoneMediaImporter "$APP/Contents/MacOS/PhoneMediaImporter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/影桥.icns "$APP/Contents/Resources/影桥.icns"
codesign --force --deep --sign - "$APP" >/dev/null
codesign --verify --deep --strict "$APP"
echo "Built: $PROJECT_ROOT/$APP"

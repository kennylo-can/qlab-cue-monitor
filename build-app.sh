#!/bin/zsh
set -euo pipefail

APP_NAME="QLab OSC Dashboard"
APP_BUNDLE="QLabOSCWatch.app"
EXEC_NAME="QLabOSCWatch"
BUILD_DIR=".build-app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP_BUNDLE" "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$BUILD_DIR"

swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -O \
  MacOSApp/*.swift \
  -o "$BUILD_DIR/$EXEC_NAME" \
  -framework SwiftUI \
  -framework AppKit \
  -framework WebKit \
  -framework Network

cp "$BUILD_DIR/$EXEC_NAME" "$MACOS_DIR/$EXEC_NAME"
cp -R MacOSApp/Resources/* "$RES_DIR/"
cp MacOSApp/Info.plist "$CONTENTS/Info.plist"

plutil -replace CFBundleExecutable -string "$EXEC_NAME" "$CONTENTS/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$CONTENTS/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$CONTENTS/Info.plist" 2>/dev/null || true

chmod +x "$MACOS_DIR/$EXEC_NAME"
echo "Built app bundle: $APP_BUNDLE"

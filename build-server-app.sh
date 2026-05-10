#!/bin/zsh
set -euo pipefail

APP_NAME="QLab Dashboard Bridge"
APP_BUNDLE="QLabDashboardBridge.app"
EXEC_NAME="QLabDashboardBridge"
BUILD_DIR=".build-bridge"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$APP_BUNDLE" "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$BUILD_DIR"

cp server.js "$RES_DIR/server.js"
cp -R public "$RES_DIR/public"

swiftc \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -O \
  BridgeApp.swift \
  -o "$BUILD_DIR/$EXEC_NAME" \
  -framework AppKit

cp "$BUILD_DIR/$EXEC_NAME" "$MACOS_DIR/$EXEC_NAME"

cat > "$CONTENTS/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key><string>com.codex.qlabdashboard.bridge</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
EOF

chmod +x "$MACOS_DIR/$EXEC_NAME"
echo "Built app bundle: $APP_BUNDLE"

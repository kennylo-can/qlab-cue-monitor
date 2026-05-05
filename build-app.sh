#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="QLab Cue Monitor"
APP_BUNDLE="$ROOT_DIR/$APP_NAME.app"
EXEC_NAME="QLabCueMonitor"
BUILD_DIR="$ROOT_DIR/.build-app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
NODE_BIN="${NODE_BIN:-}"
export TMPDIR="$BUILD_DIR/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"

if [[ -z "$NODE_BIN" ]]; then
  if [[ -x "/Applications/Codex.app/Contents/Resources/node" ]]; then
    NODE_BIN="/Applications/Codex.app/Contents/Resources/node"
  else
    NODE_BIN="$(command -v node || true)"
  fi
fi

rm -rf "$APP_BUNDLE" "$BUILD_DIR"
mkdir -p "$MACOS_DIR" "$RES_DIR" "$BUILD_DIR"
mkdir -p "$TMPDIR" "$CLANG_MODULE_CACHE_PATH"

xcrun swiftc \
  -parse-as-library \
  -sdk "$SDK_PATH" \
  -target arm64-apple-macos13.0 \
  -O \
  "$ROOT_DIR/mac-app/QLabCueMonitorStatusApp.swift" \
  -o "$BUILD_DIR/$EXEC_NAME" \
  -framework AppKit

cp "$BUILD_DIR/$EXEC_NAME" "$MACOS_DIR/$EXEC_NAME"
cp "$ROOT_DIR/index.html" "$RES_DIR/index.html"
cp "$ROOT_DIR/server.js" "$RES_DIR/server.js"
cp "$ROOT_DIR/Distribution Notes.txt" "$RES_DIR/Distribution Notes.txt"
cp "$ROOT_DIR/mac-app/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT_DIR/assets/AppIcon.icns" "$RES_DIR/AppIcon.icns"
if [[ -n "$NODE_BIN" && -x "$NODE_BIN" ]]; then
  cp "$NODE_BIN" "$RES_DIR/node"
  chmod +x "$RES_DIR/node"
fi

plutil -replace CFBundleExecutable -string "$EXEC_NAME" "$CONTENTS/Info.plist"
plutil -replace CFBundleName -string "$APP_NAME" "$CONTENTS/Info.plist"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$CONTENTS/Info.plist" 2>/dev/null || true
plutil -replace CFBundleIconFile -string "AppIcon" "$CONTENTS/Info.plist"

chmod +x "$MACOS_DIR/$EXEC_NAME"
echo "Built app bundle: $APP_BUNDLE"

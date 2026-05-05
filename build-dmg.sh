#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$ROOT_DIR/.build-dmg"
DMG_PATH="$ROOT_DIR/release/QLab Cue Monitor.dmg"
APP_PATH="$ROOT_DIR/QLab Cue Monitor.app"

rm -rf "$STAGE_DIR" "$DMG_PATH"
mkdir -p "$STAGE_DIR" "$ROOT_DIR/release"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "QLab Cue Monitor" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
echo "Built DMG: $DMG_PATH"

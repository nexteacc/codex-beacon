#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Beacon.app"
APP_DIR="$ROOT/dist/$APP_NAME"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp ".build/release/CodexBeacon" "$MACOS/CodexBeacon"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/CodexBeacon.icns" "$RESOURCES/CodexBeacon.icns"
cp -R "$ROOT/Resources/Presets" "$RESOURCES/Presets"
cp -R "$ROOT/Resources/helper" "$RESOURCES/helper"
chmod +x "$MACOS/CodexBeacon"
chmod +x "$RESOURCES/helper/notify.sh"

echo "Built: $APP_DIR"

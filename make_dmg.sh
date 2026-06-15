#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Beacon.app"
VOLUME_NAME="Codex Beacon"
DIST_DIR="$ROOT/dist"
APP_SOURCE="$DIST_DIR/$APP_NAME"
DMG_PATH="$DIST_DIR/Codex Beacon.dmg"
STAGE="$ROOT/.dmg-stage"

[[ -d "$APP_SOURCE" ]] || { echo "Missing app: $APP_SOURCE"; exit 1; }

/bin/rm -rf "$STAGE" "$DMG_PATH"
/bin/mkdir -p "$STAGE"

/usr/bin/ditto "$APP_SOURCE" "$STAGE/$APP_NAME"
/bin/ln -s /Applications "$STAGE/Applications"

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

/bin/rm -rf "$STAGE"

echo "Built: $DMG_PATH"

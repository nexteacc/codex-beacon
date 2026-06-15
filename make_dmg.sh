#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Beacon.app"
VOLUME_NAME="Codex Beacon"
DIST_DIR="$ROOT/dist"
APP_SOURCE="$DIST_DIR/$APP_NAME"
DMG_PATH="$DIST_DIR/Codex Beacon.dmg"
STAGE="$ROOT/.dmg-stage"

safe_rm_stage() {
  [[ "$STAGE" == "$ROOT/.dmg-stage" ]] || { echo "Refusing to remove unexpected path: $STAGE"; exit 1; }
  [[ -e "$STAGE" || -L "$STAGE" ]] || return 0
  /bin/rm -rf "$STAGE"
}

safe_rm_dmg() {
  [[ "$DMG_PATH" == "$ROOT/dist/Codex Beacon.dmg" ]] || { echo "Refusing to remove unexpected path: $DMG_PATH"; exit 1; }
  [[ -e "$DMG_PATH" || -L "$DMG_PATH" ]] || return 0
  /bin/rm -f "$DMG_PATH"
}

[[ -d "$APP_SOURCE" ]] || { echo "Missing app: $APP_SOURCE"; exit 1; }

safe_rm_stage
safe_rm_dmg
/bin/mkdir -p "$STAGE"

/usr/bin/ditto "$APP_SOURCE" "$STAGE/$APP_NAME"
/bin/ln -s /Applications "$STAGE/Applications"

/usr/bin/hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

safe_rm_stage

echo "Built: $DMG_PATH"

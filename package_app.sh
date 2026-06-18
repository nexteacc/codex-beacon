#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Beacon.app"
APP_DIR="$ROOT/dist/$APP_NAME"
DERIVED_DATA="${DERIVED_DATA:-/tmp/codexbeacon-package-derived}"
CONFIGURATION="${CONFIGURATION:-Release}"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
ARCHS="${ARCHS:-arm64 x86_64}"

safe_rm_app_dir() {
  [[ "$APP_DIR" == "$ROOT/dist/Codex Beacon.app" ]] || { echo "Refusing to remove unexpected path: $APP_DIR"; exit 1; }
  [[ -e "$APP_DIR" || -L "$APP_DIR" ]] || return 0
  rm -rf "$APP_DIR"
}

cd "$ROOT"

xcodebuild \
  -project "$ROOT/CodexBeacon.xcodeproj" \
  -scheme "Codex Beacon" \
  -configuration "$CONFIGURATION" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="$ARCHS" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= \
  ENABLE_DEBUG_DYLIB=NO \
  clean build

safe_rm_app_dir
/usr/bin/ditto "$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME" "$APP_DIR"
/bin/chmod +x "$APP_DIR/Contents/Resources/helper/notify.sh"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

verify_universal_binary() {
  local binary="$1"
  local architectures
  architectures="$(/usr/bin/lipo -archs "$binary")"
  [[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || {
    echo "Expected a universal binary, got '$architectures': $binary"
    exit 1
  }
}

verify_universal_binary "$APP_DIR/Contents/MacOS/CodexBeacon"
verify_universal_binary "$APP_DIR/Contents/PlugIns/CodexBeaconWidget.appex/Contents/MacOS/CodexBeaconWidget"

DERIVED_WIDGET="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME/Contents/PlugIns/CodexBeaconWidget.appex"
if [[ -d "$DERIVED_WIDGET" ]]; then
  /usr/bin/pluginkit -r "$DERIVED_WIDGET" >/dev/null 2>&1 || true
fi

echo "Built universal app (arm64 + x86_64): $APP_DIR"

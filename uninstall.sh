#!/bin/zsh
set -euo pipefail

APP_DEST="/Applications/Codex Beacon.app"
WIDGET_DEST="$APP_DEST/Contents/PlugIns/CodexBeaconWidget.appex"
WIDGET_ID="com.codexbeacon.native.widget"
HOOKS_FILE="$HOME/.codex/hooks.json"
DATA_DIR="$HOME/Library/Application Support/Codex Beacon"
REMOVE_DATA=false

if [[ "${1:-}" == "--remove-data" ]]; then
  REMOVE_DATA=true
fi

safe_rm_app_dest() {
  [[ "$APP_DEST" == "/Applications/Codex Beacon.app" ]] || { echo "Refusing to remove unexpected path: $APP_DEST"; exit 1; }
  [[ -e "$APP_DEST" || -L "$APP_DEST" ]] || return 0
  /bin/rm -rf "$APP_DEST"
}

safe_rm_data_dir() {
  [[ "$DATA_DIR" == "$HOME/Library/Application Support/Codex Beacon" ]] || { echo "Refusing to remove unexpected path: $DATA_DIR"; exit 1; }
  [[ -e "$DATA_DIR" || -L "$DATA_DIR" ]] || return 0
  /bin/rm -rf "$DATA_DIR"
}

/usr/bin/osascript -e 'quit application "Codex Beacon"' >/dev/null 2>&1 || true

if [[ -d "$WIDGET_DEST" ]]; then
  /usr/bin/pluginkit -e ignore -i "$WIDGET_ID" >/dev/null 2>&1 || true
  /usr/bin/pluginkit -r "$WIDGET_DEST" >/dev/null 2>&1 || true
fi

if [[ -f "$HOOKS_FILE" ]]; then
  /bin/cp "$HOOKS_FILE" "$HOOKS_FILE.codex-beacon-backup"
  /usr/bin/osascript -l JavaScript - "$HOOKS_FILE" <<'JXA'
function run(argv) {
ObjC.import("Foundation");
const hooksPath = argv[0];

function readText(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return text ? ObjC.unwrap(text) : "";
}

function writeText(path, text) {
  const value = $.NSString.alloc.initWithUTF8String(text);
  value.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}

const root = JSON.parse(readText(hooksPath));

if (!root.hooks || typeof root.hooks !== "object") {
  return;
}

const ownedFragments = [
  "codex-beacon-native/notify.sh",
  "Codex Beacon.app/Contents/Resources/helper/notify.sh",
  "codex-beacon/run.sh",
  "codex-mac-attention"
];

function cleanHooks(items) {
  if (!Array.isArray(items)) return items;
  return items
    .map((entry) => {
      if (!entry || typeof entry !== "object") return entry;
      const hooks = Array.isArray(entry.hooks) ? entry.hooks : [];
      const nextHooks = hooks.filter((hook) => {
        const command = typeof hook?.command === "string" ? hook.command : "";
        return !ownedFragments.some((fragment) => command.includes(fragment));
      });
      return { ...entry, hooks: nextHooks };
    })
    .filter((entry) => !Array.isArray(entry?.hooks) || entry.hooks.length > 0);
}

for (const eventName of Object.keys(root.hooks)) {
  root.hooks[eventName] = cleanHooks(root.hooks[eventName]);
  if (Array.isArray(root.hooks[eventName]) && root.hooks[eventName].length === 0) {
    delete root.hooks[eventName];
  }
}

writeText(hooksPath, JSON.stringify(root, null, 2) + "\n");
}
JXA
fi

safe_rm_app_dest

if [[ "$REMOVE_DATA" == true ]]; then
  safe_rm_data_dir
fi

echo "Uninstalled Codex Beacon."
if [[ "$REMOVE_DATA" != true ]]; then
  echo "User presets were kept at: $DATA_DIR"
fi

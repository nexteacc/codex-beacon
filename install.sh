#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP_NAME="Codex Beacon.app"
APP_SOURCE="$ROOT/dist/$APP_NAME"
if [[ ! -d "$APP_SOURCE" ]]; then
  APP_SOURCE="$ROOT/$APP_NAME"
fi
APP_DEST="/Applications/$APP_NAME"
HOOKS_FILE="$HOME/.codex/hooks.json"
HELPER="$APP_DEST/Contents/Resources/helper/notify.sh"

safe_rm_app_dest() {
  [[ "$APP_DEST" == "/Applications/Codex Beacon.app" ]] || { echo "Refusing to remove unexpected path: $APP_DEST"; exit 1; }
  [[ -e "$APP_DEST" || -L "$APP_DEST" ]] || return 0
  /bin/rm -rf "$APP_DEST"
}

if [[ "${1:-}" == "--check" ]]; then
  [[ -d "$APP_SOURCE" ]] || { echo "Missing app: $APP_SOURCE"; exit 1; }
  [[ -x "$APP_SOURCE/Contents/Resources/helper/notify.sh" ]] || { echo "Missing helper in app bundle"; exit 1; }
  /usr/bin/plutil -lint "$APP_SOURCE/Contents/Info.plist" >/dev/null
  if [[ -f "$HOOKS_FILE" ]]; then
    /usr/bin/osascript -l JavaScript - "$HOOKS_FILE" <<'JXA' >/dev/null
function run(argv) {
  ObjC.import("Foundation");
  const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
  JSON.parse(ObjC.unwrap(text));
}
JXA
  fi
  echo "Codex Beacon is ready to install."
  exit 0
fi

[[ -d "$APP_SOURCE" ]] || { echo "Missing app: $APP_SOURCE"; exit 1; }
[[ -x "$APP_SOURCE/Contents/Resources/helper/notify.sh" ]] || { echo "Missing helper in app bundle"; exit 1; }

/usr/bin/osascript -e 'quit application "Codex Beacon"' >/dev/null 2>&1 || true
safe_rm_app_dest
/usr/bin/ditto "$APP_SOURCE" "$APP_DEST"
/bin/chmod +x "$HELPER"

/bin/mkdir -p "$HOME/.codex"
if [[ -f "$HOOKS_FILE" ]]; then
  /bin/cp "$HOOKS_FILE" "$HOOKS_FILE.codex-beacon-backup"
fi

/usr/bin/osascript -l JavaScript - "$HOOKS_FILE" "$HELPER" <<'JXA'
function run(argv) {
ObjC.import("Foundation");
const hooksPath = argv[0];
const helper = argv[1];
const commandHelper = `'${helper.replace(/'/g, "'\\''")}'`;

function fileExists(path) {
  return $.NSFileManager.defaultManager.fileExistsAtPath(path);
}

function readText(path) {
  const text = $.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null);
  return text ? ObjC.unwrap(text) : "";
}

function writeText(path, text) {
  const value = $.NSString.alloc.initWithUTF8String(text);
  value.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
}

let root = { hooks: {} };
if (fileExists(hooksPath)) {
  root = JSON.parse(readText(hooksPath));
}

if (!root || typeof root !== "object" || Array.isArray(root)) {
  root = { hooks: {} };
}
if (!root.hooks || typeof root.hooks !== "object" || Array.isArray(root.hooks)) {
  root.hooks = {};
}

const ownedFragments = [
  "codex-beacon-native/notify.sh",
  "Codex Beacon.app/Contents/Resources/helper/notify.sh",
  "codex-beacon/run.sh",
  "codex-mac-attention"
];

function cleanHooks(items) {
  if (!Array.isArray(items)) return [];
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

root.hooks.PermissionRequest = cleanHooks(root.hooks.PermissionRequest);
root.hooks.Stop = cleanHooks(root.hooks.Stop);

root.hooks.PermissionRequest.push({
  matcher: "*",
  hooks: [
    {
      type: "command",
      command: `${commandHelper} permission_request`,
      timeout: 3,
      statusMessage: "Signaling Codex Beacon"
    }
  ]
});

root.hooks.Stop.push({
  hooks: [
    {
      type: "command",
      command: `${commandHelper} turn_done`,
      timeout: 3,
      statusMessage: "Signaling Codex Beacon"
    }
  ]
});

writeText(hooksPath, JSON.stringify(root, null, 2) + "\n");
}
JXA

/usr/bin/open "$APP_DEST"

echo "Installed Codex Beacon."
echo "Restart Codex, then trust the updated hooks."

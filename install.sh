#!/bin/zsh
set -euo pipefail

SOURCE_DIR="${0:A:h}"
INSTALL_DIR="$HOME/.codex/codex-beacon"
HOOKS_FILE="$HOME/.codex/hooks.json"
BTT_WIDGET_UUID="C0DEC0DE-BEAC-4001-9000-C0DEC0DEC0DE"
BTT_PRESET_PATH="$SOURCE_DIR/btt/Codex Beacon.bttpreset"

mkdir -p "$INSTALL_DIR"

cp "$SOURCE_DIR/hooks/codex-beacon.js" "$INSTALL_DIR/codex-beacon.js"
chmod +x "$INSTALL_DIR/codex-beacon.js"

if [[ ! -f "$INSTALL_DIR/config.env" ]]; then
  cp "$SOURCE_DIR/config.example.env" "$INSTALL_DIR/config.env"
fi

if grep -q '^CODEX_ATTENTION_BTT_WIDGET_UUID=PASTE_YOUR_BTT_WIDGET_UUID_HERE$' "$INSTALL_DIR/config.env"; then
  perl -0pi -e "s/^CODEX_ATTENTION_BTT_WIDGET_UUID=PASTE_YOUR_BTT_WIDGET_UUID_HERE$/CODEX_ATTENTION_BTT_WIDGET_UUID=$BTT_WIDGET_UUID/m" "$INSTALL_DIR/config.env"
fi

cat > "$INSTALL_DIR/run.sh" <<'EOF'
#!/bin/zsh
set -euo pipefail

CONFIG_FILE="${CODEX_ATTENTION_CONFIG:-$HOME/.codex/codex-beacon/config.env}"
SCRIPT="$HOME/.codex/codex-beacon/codex-beacon.js"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  source "$CONFIG_FILE"
  set +a
fi

exec node "$SCRIPT" "$@"
EOF
chmod +x "$INSTALL_DIR/run.sh"

import_btt_preset() {
  if [[ ! -f "$BTT_PRESET_PATH" ]]; then
    echo "BetterTouchTool preset not found; skipping preset import."
    return
  fi

  if [[ ! -d "/Applications/BetterTouchTool.app" && ! -d "$HOME/Applications/BetterTouchTool.app" ]]; then
    echo "BetterTouchTool app not found; skipping preset import."
    return
  fi

  local existing
  existing=$(osascript -e "tell application \"BetterTouchTool\" to get_triggers trigger_uuid \"$BTT_WIDGET_UUID\"" 2>/dev/null || true)

  if [[ "$existing" == *"$BTT_WIDGET_UUID"* ]]; then
    echo "BetterTouchTool Codex Beacon widget already exists."
    return
  fi

  if osascript -e "tell application \"BetterTouchTool\" to import_preset \"$BTT_PRESET_PATH\"" >/dev/null 2>&1; then
    echo "Imported BetterTouchTool Codex Beacon preset."
  else
    echo "Could not import BetterTouchTool preset automatically."
    echo "You can import it manually from: $BTT_PRESET_PATH"
  fi
}

import_btt_preset

mkdir -p "$HOME/.codex"

node <<'NODE'
const fs = require("fs");
const os = require("os");
const path = require("path");

const hooksPath = path.join(os.homedir(), ".codex", "hooks.json");
let data = { hooks: {} };

if (fs.existsSync(hooksPath)) {
  data = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
  data.hooks ||= {};
}

const beaconCommandPrefix = `${os.homedir()}/.codex/codex-beacon/run.sh`;

function withoutExistingBeaconHooks(groups = []) {
  return groups
    .map((group) => ({
      ...group,
      hooks: (group.hooks || []).filter((hook) => {
        return !(typeof hook.command === "string" && hook.command.startsWith(beaconCommandPrefix));
      }),
    }))
    .filter((group) => (group.hooks || []).length > 0);
}

data.hooks.PermissionRequest = withoutExistingBeaconHooks(data.hooks.PermissionRequest);
data.hooks.PermissionRequest.push({
  matcher: "*",
  hooks: [
    {
      type: "command",
      command: `${beaconCommandPrefix} permission_request`,
      timeout: 6,
      statusMessage: "Signaling Codex attention",
    },
  ],
});

data.hooks.Stop = withoutExistingBeaconHooks(data.hooks.Stop);
data.hooks.Stop.push({
  hooks: [
    {
      type: "command",
      command: `${beaconCommandPrefix} turn_done`,
      timeout: 6,
      statusMessage: "Signaling Codex completion",
    },
  ],
});

fs.writeFileSync(hooksPath, JSON.stringify(data, null, 2) + "\n");
console.log(`Updated ${hooksPath}`);
NODE

echo
echo "Installed Codex Beacon."
echo
echo "Next steps:"
echo "1. Make sure BetterTouchTool webserver is enabled on 127.0.0.1:12345."
echo "2. Optional: edit $INSTALL_DIR/config.env to change text, colors, sounds, or durations."
echo "3. Test:"
echo "   $INSTALL_DIR/run.sh permission_request"
echo "   $INSTALL_DIR/run.sh turn_done"
echo "4. Restart Codex CLI/Desktop and run /hooks to review/trust the hooks."

# Codex Beacon

Native macOS MVP for a lightweight Codex attention surface.

## Build

```bash
./package_app.sh
./make_dmg.sh
```

Artifacts are created at:

```text
dist/Codex Beacon.app
dist/Codex Beacon.dmg
```

## Test Events

```bash
'/Applications/Codex Beacon.app/Contents/Resources/helper/notify.sh' permission_request
'/Applications/Codex Beacon.app/Contents/Resources/helper/notify.sh' turn_done
```

Direct localhost requests require the per-user token in `config.json`.

## Config

```text
~/Library/Application Support/Codex Beacon/config.json
~/Library/Application Support/Codex Beacon/Presets/default.json
```

```json
{
  "activePreset": "default",
  "authToken": "generated-per-user",
  "sound": true,
  "touchBarVisual": true
}
```

## Current Scope

- Menu bar app
- Minimal settings window
- Touch Bar visual toggle
- Sound toggle
- Localhost-only event server with per-user token
- Native Touch Bar presentation via private APIs
- DMG packaging with install/uninstall commands

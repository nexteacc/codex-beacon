# Codex Beacon

Codex Beacon is a small local-first macOS menu bar app for Codex signals: Touch Bar status, sounds, and usage.

## Requirements

- macOS 12 or later.
- macOS 14 or later for the Widget.
- A Mac with Touch Bar is only required for Touch Bar visuals; other Macs can use the menu bar app and Widget.
- Codex CLI or Codex Desktop with hooks support.
- Bark on iPhone for optional mobile usage notifications.
- Codex Beacon must be installed in `/Applications`.
- Codex Beacon runs on your Mac and receives Codex signals locally.

## Install

1. Download `Codex.Beacon.dmg` from Releases.
2. Open the DMG.
3. Drag `Codex Beacon` to `Applications`.
4. Open `Codex Beacon`.
5. Click `Install` for hooks.
6. Restart Codex and trust the hooks when prompted.

## iPhone Notifications

1. Install Bark on the iPhone and copy its Push URL.
2. Open Codex Beacon settings and paste the URL into `Bark URL`.
3. Click `Test` and confirm the notification arrives.

Codex Beacon accepts either the base URL or Bark's complete test URL and extracts the device key automatically. The device key is stored locally in `~/Library/Application Support/Codex Beacon/bark-device-key` with owner-only permissions and is never synchronized by Codex Beacon. Codex Beacon sends one notification when either the 5-hour or weekly allowance first reaches 50%, 10%, exhausted, or available again. Thresholds are recorded once per usage window to avoid duplicate notifications.

Users upgrading from the Keychain-backed preview will see `Reconnect Bark` once. Paste the Bark Push URL and run `Test` again; later launches use the owner-only local file without a Keychain prompt.

## First Launch

Preview builds are unsigned. macOS may show:

```text
"Codex Beacon" Not Opened
Apple could not verify "Codex Beacon" is free of malware.
```

Use one of these options:

- Right-click `/Applications/Codex Beacon.app` and choose `Open`.
- Or open System Settings -> Privacy & Security, then allow `Codex Beacon`.

If you already trust this app and macOS still blocks it, remove quarantine:

```bash
xattr -dr com.apple.quarantine "/Applications/Codex Beacon.app"
```

## Notes

- This preview is not signed or notarized.
- Release builds are universal binaries for Intel and Apple Silicon Macs.
- Hooks are installed into `~/.codex/hooks.json`.
- Config lives in `~/Library/Application Support/Codex Beacon/`.
- Touch Bar support uses private macOS APIs and activates only on supported Touch Bar Macs; it is optional for Widget users.

## Development

Run the mobile notification regression harness with:

```bash
scripts/test_mobile_notifications.sh
```

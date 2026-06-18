# Codex Beacon

Codex Beacon is a small local-first macOS menu bar app for Codex signals: Touch Bar status, sounds, and usage.

## Requirements

- macOS 12 or later.
- macOS 14 or later for the Widget.
- A Mac with Touch Bar is only required for Touch Bar visuals; other Macs can use the menu bar app and Widget.
- Codex CLI or Codex Desktop with hooks support.
- Codex Beacon must be installed in `/Applications`.
- Codex Beacon runs on your Mac and receives Codex signals locally.

## Install

1. Download `Codex.Beacon.dmg` from Releases.
2. Open the DMG.
3. Drag `Codex Beacon` to `Applications`.
4. Open `Codex Beacon`.
5. Click `Install` for hooks.
6. Restart Codex and trust the hooks when prompted.

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

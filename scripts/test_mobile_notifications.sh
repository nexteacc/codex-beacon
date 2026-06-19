#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CACHE="/tmp/codexbeacon-policy-module-cache"
BINARY="/tmp/codexbeacon-policy-harness-bin"

xcrun swiftc \
  -module-cache-path "$CACHE" \
  "$ROOT/Sources/CodexBeacon/MobileNotifications.swift" \
  "$ROOT/Tests/MobileNotificationsPolicyHarness.swift" \
  -o "$BINARY"

"$BINARY"

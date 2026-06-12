#!/bin/zsh
set -euo pipefail

EVENT="${1:-}"
CONFIG="$HOME/Library/Application Support/Codex Beacon/config.json"

case "$EVENT" in
  permission_request|turn_done)
    ;;
  *)
    exit 0
    ;;
esac

[[ -f "$CONFIG" ]] || exit 0

TOKEN="$(/usr/bin/plutil -extract authToken raw -o - "$CONFIG" 2>/dev/null || true)"

[[ "$TOKEN" =~ '^[0-9a-fA-F]{48}$' ]] || exit 0

/usr/bin/curl \
  --silent \
  --show-error \
  --max-time 2 \
  "http://127.0.0.1:17321/event?type=$EVENT&token=$TOKEN" \
  >/dev/null 2>&1 || true

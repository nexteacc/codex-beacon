#!/bin/zsh
set -euo pipefail

CONFIG_FILE="${CODEX_ATTENTION_CONFIG:-/Users/Sheng/.codex/codex-beacon/config.env}"
SCRIPT="/Users/Sheng/.codex/codex-beacon/codex-beacon.js"

if [[ -f "$CONFIG_FILE" ]]; then
  set -a
  source "$CONFIG_FILE"
  set +a
fi

exec node "$SCRIPT" "$@"

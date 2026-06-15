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

parent_pid() {
  /bin/ps -p "$1" -o ppid= 2>/dev/null | /usr/bin/tr -d '[:space:]'
}

bundle_identifier_for_pid() {
  local pid="$1"
  local command app bundle

  command="$(/bin/ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == *".app/"* ]] || return 1

  app="${command%%.app/*}.app"
  [[ -f "$app/Contents/Info.plist" ]] || return 1

  bundle="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$bundle" =~ '^[A-Za-z0-9.-]+$' ]] || return 1
  [[ "$bundle" != "com.codexbeacon.native" ]] || return 1

  print -r -- "$bundle"
}

host_app_target() {
  local pid="$$"
  local ppid bundle

  for _ in {1..40}; do
    ppid="$(parent_pid "$pid")"
    [[ "$ppid" =~ '^[0-9]+$' ]] || return 1
    [[ "$ppid" -gt 1 ]] || return 1

    bundle="$(bundle_identifier_for_pid "$ppid" || true)"
    if [[ -n "$bundle" ]]; then
      print -r -- "$ppid $bundle"
      return 0
    fi

    pid="$ppid"
  done

  return 1
}

RETURN_QUERY=""
HOST_TARGET="$(host_app_target || true)"
if [[ -n "$HOST_TARGET" ]]; then
  RETURN_PID="${HOST_TARGET%% *}"
  RETURN_BUNDLE="${HOST_TARGET#* }"
  RETURN_QUERY="&return_pid=$RETURN_PID&return_bundle=$RETURN_BUNDLE"
fi

/usr/bin/curl \
  --silent \
  --show-error \
  --max-time 2 \
  "http://127.0.0.1:17321/event?type=$EVENT&token=$TOKEN$RETURN_QUERY" \
  >/dev/null 2>&1 || true

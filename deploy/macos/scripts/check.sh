#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LABEL="org.aichat.codex-connector"
readonly STATE_ROOT="${HOME}/Library/Application Support/AIChat/codex-connector-launchagent"
readonly CURRENT_LINK="${STATE_ROOT}/current"
readonly SETTINGS_PATH="${STATE_ROOT}/settings.json"
readonly LAUNCHER_PATH="${STATE_ROOT}/launcher.py"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

node_binary="$(command -v node || true)"
python_binary="$(command -v python3 || true)"
[[ -n "$node_binary" && "$node_binary" == /* ]] || {
  printf 'node_ok=false\n'
  exit 1
}
[[ -n "$python_binary" && "$python_binary" == /* ]] || {
  printf 'python_ok=false\n'
  exit 1
}
[[ -L "$CURRENT_LINK" && -f "${CURRENT_LINK}/runtime/src/cli.js" ]] || {
  printf 'release_ok=false\n'
  exit 1
}
[[ -f "$PLIST_PATH" ]] || {
  printf 'plist_ok=false\n'
  exit 1
}
plutil -lint "$PLIST_PATH" >/dev/null
"$python_binary" "$LAUNCHER_PATH" \
  --settings "$SETTINGS_PATH" \
  --connector "${CURRENT_LINK}/runtime/src/cli.js" \
  --node "$node_binary" \
  --check-settings >/dev/null

printf 'release_ok=true\n'
printf 'plist_ok=true\n'
printf 'settings_ok=true\n'
printf 'token_read=false\n'
if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
  printf 'launchagent_loaded=true\n'
else
  printf 'launchagent_loaded=false\n'
fi

#!/usr/bin/env bash

set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LABEL="org.aichat.codex-connector"
readonly STATE_ROOT="${HOME}/Library/Application Support/AIChat/codex-connector-launchagent"
readonly CURRENT_LINK="${STATE_ROOT}/current"
readonly SETTINGS_PATH="${STATE_ROOT}/settings.json"
readonly LAUNCHER_PATH="${STATE_ROOT}/launcher.py"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOCK_PATH="${HOME}/Library/Application Support/AIChat/.codex-connector-operation.lock"

original_args=("$@")
original_arg_count=$#
stage_only=false
if [[ "${1:-}" == "--stage-only" ]]; then
  stage_only=true
  shift
fi
if (($# > 0)); then
  printf 'Usage: check.sh [--stage-only]\n' >&2
  exit 2
fi

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

state_present=false
if [[ -e "$STATE_ROOT" || -L "$STATE_ROOT" || -e "$PLIST_PATH" || -L "$PLIST_PATH" || -e "$LOCK_PATH" || -L "$LOCK_PATH" ]]; then
  state_present=true
fi
legacy_lock_absent=false
if [[ "$state_present" == true && -z "${AICHAT_MACOS_OPERATION_LOCK_FD:-}" ]]; then
  if [[ -e "$LOCK_PATH" || -L "$LOCK_PATH" ]]; then
    if ((original_arg_count > 0)); then
      exec "$python_binary" "$SCRIPT_DIR/operation-lock.py" \
        --home "$HOME" \
        --lock-path "$LOCK_PATH" \
        --shared \
        /bin/bash "$0" "${original_args[@]}"
    else
      exec "$python_binary" "$SCRIPT_DIR/operation-lock.py" \
        --home "$HOME" \
        --lock-path "$LOCK_PATH" \
        --shared \
        /bin/bash "$0"
    fi
  fi
  legacy_lock_absent=true
fi
if [[ -n "${AICHAT_MACOS_OPERATION_LOCK_FD:-}" ]]; then
  "$python_binary" "$SCRIPT_DIR/staged-package.py" verify-lock \
    --home "$HOME" \
    --state-root "$STATE_ROOT"
fi

if [[ "$stage_only" == true ]]; then
  if [[ ! -e "${STATE_ROOT}/staged/current" && ! -L "${STATE_ROOT}/staged/current" ]]; then
    printf 'staged=false\n'
    printf 'checked_scope=staged\n'
    printf 'launchagent_checked=false\n'
    printf 'token_read=false\n'
    printf 'state=absent\n'
    if [[ "$legacy_lock_absent" == true && ( -e "$LOCK_PATH" || -L "$LOCK_PATH" ) ]]; then
      printf 'ERROR: package state changed while the legacy check was running; retry\n' >&2
    fi
    exit 1
  fi
  exec "$python_binary" "$SCRIPT_DIR/staged-package.py" check \
    --home "$HOME" \
    --state-root "$STATE_ROOT"
fi

staged=false
staged_release=""
if [[ -e "${STATE_ROOT}/staged/current" || -L "${STATE_ROOT}/staged/current" ]]; then
  staged_summary="$(
    "$python_binary" "$SCRIPT_DIR/staged-package.py" check \
      --home "$HOME" \
      --state-root "$STATE_ROOT"
  )"
  staged=true
  staged_release="$(awk -F= '$1 == "staged_release" { print $2 }' <<<"$staged_summary")"
fi

if [[ ! -e "$CURRENT_LINK" && ! -L "$CURRENT_LINK" && ! -e "$SETTINGS_PATH" && ! -e "$LAUNCHER_PATH" && ! -e "$PLIST_PATH" ]]; then
  printf 'staged=%s\n' "$staged"
  if [[ -n "$staged_release" ]]; then
    printf 'staged_release=%s\n' "$staged_release"
  fi
  printf 'active_installed=false\n'
  printf 'launchagent_checked=false\n'
  printf 'token_read=false\n'
  if [[ "$legacy_lock_absent" == true && ( -e "$LOCK_PATH" || -L "$LOCK_PATH" ) ]]; then
    printf 'ERROR: package state changed while the legacy check was running; retry\n' >&2
    exit 1
  fi
  if [[ "$staged" == true ]]; then
    printf 'state=staged-only\n'
    exit 0
  fi
  printf 'state=absent\n'
  exit 1
fi

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
  --check-settings

printf 'release_ok=true\n'
printf 'plist_ok=true\n'
printf 'staged=%s\n' "$staged"
if [[ -n "$staged_release" ]]; then
  printf 'staged_release=%s\n' "$staged_release"
fi
printf 'active_installed=true\n'
if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
  printf 'launchagent_loaded=true\n'
  printf 'active=true\n'
  if [[ "$staged" == true ]]; then
    printf 'state=active-with-staged-candidate\n'
  else
    printf 'state=active\n'
  fi
else
  printf 'launchagent_loaded=false\n'
  printf 'active=false\n'
  if [[ "$staged" == true ]]; then
    printf 'state=active-unloaded-with-staged-candidate\n'
  else
    printf 'state=active-unloaded\n'
  fi
fi
if [[ "$legacy_lock_absent" == true && ( -e "$LOCK_PATH" || -L "$LOCK_PATH" ) ]]; then
  printf 'ERROR: package state changed while the legacy check was running; retry\n' >&2
  exit 1
fi

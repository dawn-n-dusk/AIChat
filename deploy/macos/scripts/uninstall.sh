#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LABEL="org.aichat.codex-connector"
readonly STATE_ROOT="${HOME}/Library/Application Support/AIChat/codex-connector-launchagent"
readonly LOCK_PATH="${HOME}/Library/Application Support/AIChat/.codex-connector-operation.lock"

original_args=("$@")
apply=false
stage_only=false

usage() {
  printf '%s\n' \
    "Usage: uninstall.sh --stage-only [--apply]" \
    "" \
    "Only the isolated staged candidate is supported; active installs are untouched."
}

while (($# > 0)); do
  case "$1" in
    --apply)
      apply=true
      shift
      ;;
    --stage-only)
      stage_only=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      printf 'ERROR: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$stage_only" != true ]]; then
  printf 'ERROR: --stage-only is required; this command never removes an active install\n' >&2
  exit 2
fi

python_binary="$(command -v python3 || true)"
[[ -n "$python_binary" && "$python_binary" == /* ]] || {
  printf 'ERROR: Python 3 is required on PATH\n' >&2
  exit 1
}

staged_state_present=false
if [[ -e "${STATE_ROOT}/staged/current" || -L "${STATE_ROOT}/staged/current" ]] || \
  compgen -G "${STATE_ROOT}/staged/.removed-*" >/dev/null; then
  staged_state_present=true
fi
if [[ ( "$staged_state_present" == true || -e "$LOCK_PATH" || -L "$LOCK_PATH" ) && -z "${AICHAT_MACOS_OPERATION_LOCK_FD:-}" ]]; then
  exec "$python_binary" "$SCRIPT_DIR/operation-lock.py" \
    --home "$HOME" \
    --lock-path "$LOCK_PATH" \
    --exclusive \
    /bin/bash "$0" "${original_args[@]}"
fi

staged=false
if [[ -e "${STATE_ROOT}/staged/current" || -L "${STATE_ROOT}/staged/current" ]]; then
  "$python_binary" "$SCRIPT_DIR/staged-package.py" check \
    --home "$HOME" \
    --state-root "$STATE_ROOT" >/dev/null
  staged=true
fi
if [[ "$staged" != true ]] && compgen -G "${STATE_ROOT}/staged/.removed-*" >/dev/null; then
  staged=true
fi
printf 'staged=%s\n' "$staged"
printf 'active_install_untouched=true\n'
printf 'token_read=false\n'
if [[ "$apply" != true ]]; then
  printf 'dry_run=true\n'
  exit 0
fi
if [[ "$staged" != true ]]; then
  printf 'staged_removed=false\n'
  exit 0
fi

if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
  printf 'ERROR: the LaunchAgent label is loaded; refusing to remove files that may be in use\n' >&2
  exit 1
fi
printf 'launchagent_checked=true\n'
printf 'launchagent_loaded=false\n'

"$python_binary" "$SCRIPT_DIR/staged-package.py" remove \
  --home "$HOME" \
  --state-root "$STATE_ROOT"

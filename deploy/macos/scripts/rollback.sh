#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly LABEL="org.aichat.codex-connector"
readonly STATE_ROOT="${HOME}/Library/Application Support/AIChat/codex-connector-launchagent"
readonly CURRENT_LINK="${STATE_ROOT}/current"
readonly SETTINGS_PATH="${STATE_ROOT}/settings.json"
readonly LAUNCHER_PATH="${STATE_ROOT}/launcher.py"
readonly LAST_BACKUP="${STATE_ROOT}/last-backup"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"

apply=false
if [[ "${1:-}" == "--apply" ]]; then
  apply=true
  shift
fi
if (($# > 0)); then
  printf 'Usage: rollback.sh [--apply]\n' >&2
  exit 2
fi
[[ -f "$LAST_BACKUP" ]] || {
  printf 'ERROR: no recorded macOS connector install is available to roll back\n' >&2
  exit 1
}
backup_id="$(<"$LAST_BACKUP")"
[[ "$backup_id" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]] || {
  printf 'ERROR: rollback identifier is invalid\n' >&2
  exit 1
}
backup_dir="${STATE_ROOT}/backups/${backup_id}"
[[ -d "$backup_dir" ]] || {
  printf 'ERROR: rollback snapshot is missing\n' >&2
  exit 1
}

restored_automatic_egress="absent"
if [[ -f "${backup_dir}/previous-current" ]]; then
  previous_target="$(<"${backup_dir}/previous-current")"
  [[ "$previous_target" == "${STATE_ROOT}/releases/"* && -f "${previous_target}/runtime/src/cli.js" ]] || {
    printf 'ERROR: previous release target is invalid\n' >&2
    exit 1
  }
  if [[ -f "${backup_dir}/settings" && -f "${backup_dir}/launcher" ]]; then
    node_binary="$(command -v node || true)"
    python_binary="$(command -v python3 || true)"
    [[ -n "$node_binary" && "$node_binary" == /* && -n "$python_binary" && "$python_binary" == /* ]] || {
      printf 'ERROR: Node.js and Python 3 are required to validate the rollback snapshot\n' >&2
      exit 1
    }
    settings_summary="$(
      "$python_binary" "${backup_dir}/launcher" \
        --settings "${backup_dir}/settings" \
        --connector "${previous_target}/runtime/src/cli.js" \
        --node "$node_binary" \
        --check-settings
    )"
    restored_automatic_egress="$(
      awk -F= '$1 == "automatic_egress" { print $2 }' <<<"$settings_summary"
    )"
    if [[ -z "$restored_automatic_egress" ]]; then
      restored_automatic_egress=false
    fi
    [[ "$restored_automatic_egress" == true || "$restored_automatic_egress" == false ]] || {
      printf 'ERROR: rollback settings summary is invalid\n' >&2
      exit 1
    }
  fi
fi

printf 'rollback_snapshot=%s\n' "$backup_id"
printf 'current_release_preserved=true\n'
printf 'restored_automatic_egress=%s\n' "$restored_automatic_egress"
if [[ "$apply" != true ]]; then
  printf 'dry_run=true\n'
  exit 0
fi

launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
if [[ -f "${backup_dir}/previous-current" ]]; then
  ln -sfn -- "$previous_target" "$CURRENT_LINK"
else
  rm -f -- "$CURRENT_LINK"
fi
for pair in "plist:${PLIST_PATH}" "settings:${SETTINGS_PATH}" "launcher:${LAUNCHER_PATH}"; do
  name="${pair%%:*}"
  path="${pair#*:}"
  if [[ -f "${backup_dir}/${name}" ]]; then
    cp -p -- "${backup_dir}/${name}" "$path"
  else
    rm -f -- "$path"
  fi
done
if [[ "$(<"${backup_dir}/service-was-loaded")" == true && -f "$PLIST_PATH" ]]; then
  launchctl bootstrap "gui/${UID}" "$PLIST_PATH"
fi
printf 'rollback_complete=true\n'

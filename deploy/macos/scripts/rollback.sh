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

printf 'rollback_snapshot=%s\n' "$backup_id"
printf 'current_release_preserved=true\n'
if [[ "$apply" != true ]]; then
  printf 'dry_run=true\n'
  exit 0
fi

launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
if [[ -f "${backup_dir}/previous-current" ]]; then
  previous_target="$(<"${backup_dir}/previous-current")"
  [[ "$previous_target" == "${STATE_ROOT}/releases/"* && -d "$previous_target" ]] || {
    printf 'ERROR: previous release target is invalid\n' >&2
    exit 1
  }
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

#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PACKAGE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LABEL="org.aichat.codex-connector"
readonly STATE_ROOT="${HOME}/Library/Application Support/AIChat/codex-connector-launchagent"
readonly RELEASES_DIR="${STATE_ROOT}/releases"
readonly CURRENT_LINK="${STATE_ROOT}/current"
readonly SETTINGS_PATH="${STATE_ROOT}/settings.json"
readonly LAUNCHER_PATH="${STATE_ROOT}/launcher.py"
readonly BACKUPS_DIR="${STATE_ROOT}/backups"
readonly LAST_BACKUP="${STATE_ROOT}/last-backup"
readonly PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
readonly LOG_DIR="${HOME}/Library/Logs/AIChat"

apply=false
settings_source=""
repository_root=""

usage() {
  printf '%s\n' \
    "Usage: install.sh --settings /absolute/settings.json --repository-root /absolute/AIChat [--apply]" \
    "" \
    "Without --apply, performs read-only preflight and prints the intended paths."
}

while (($# > 0)); do
  case "$1" in
    --apply)
      apply=true
      shift
      ;;
    --settings)
      settings_source="${2:-}"
      shift 2
      ;;
    --repository-root)
      repository_root="${2:-}"
      shift 2
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

[[ -n "$settings_source" && "$settings_source" == /* && -f "$settings_source" ]] || {
  printf 'ERROR: --settings must name an existing absolute file\n' >&2
  exit 1
}
[[ -n "$repository_root" && "$repository_root" == /* ]] || {
  printf 'ERROR: --repository-root must be absolute\n' >&2
  exit 1
}
readonly CONNECTOR_SOURCE="${repository_root}/adapters/codex-connector"
[[ -f "${CONNECTOR_SOURCE}/package-lock.json" && -f "${CONNECTOR_SOURCE}/src/cli.js" ]] || {
  printf 'ERROR: repository root does not contain adapters/codex-connector\n' >&2
  exit 1
}

node_binary="$(command -v node || true)"
npm_binary="$(command -v npm || true)"
python_binary="$(command -v python3 || true)"
[[ -n "$node_binary" && "$node_binary" == /* ]] || {
  printf 'ERROR: Node.js 20+ is required on PATH\n' >&2
  exit 1
}
[[ -n "$python_binary" && "$python_binary" == /* ]] || {
  printf 'ERROR: Python 3 is required on PATH\n' >&2
  exit 1
}
[[ -n "$npm_binary" && "$npm_binary" == /* ]] || {
  printf 'ERROR: npm is required on PATH\n' >&2
  exit 1
}
node_major="$($node_binary -p 'Number(process.versions.node.split(".")[0])')"
((node_major >= 20)) || {
  printf 'ERROR: Node.js 20+ is required\n' >&2
  exit 1
}

"$python_binary" "$SCRIPT_DIR/launcher.py" \
  --settings "$settings_source" \
  --connector "${CONNECTOR_SOURCE}/src/cli.js" \
  --node "$node_binary" \
  --check-settings

printf 'label=%s\n' "$LABEL"
printf 'state_root=%s\n' "$STATE_ROOT"
printf 'plist=%s\n' "$PLIST_PATH"
printf 'periodic_recovery=false\n'
printf 'driver=app-server\n'
printf 'automatic_egress=false\n'
if [[ "$apply" != true ]]; then
  printf 'dry_run=true\n'
  exit 0
fi

release_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
release_dir="${RELEASES_DIR}/${release_id}"
backup_dir="${BACKUPS_DIR}/${release_id}"
staging_root="$(mktemp -d "${TMPDIR:-/tmp}/aichat-macos-install.XXXXXX")"
staging_release="${staging_root}/release"
staging_plist="${staging_root}/${LABEL}.plist"
staging_settings="${staging_root}/settings.json"
staging_launcher="${staging_root}/launcher.py"
service_was_loaded=false

cleanup() {
  rm -rf -- "$staging_root"
}
trap cleanup EXIT

mkdir -p -- "$staging_release/runtime/src" "$release_dir" "$backup_dir" "$LOG_DIR" \
  "$(dirname "$PLIST_PATH")"
rmdir -- "$release_dir"
chmod 700 "$STATE_ROOT" "$RELEASES_DIR" "$BACKUPS_DIR" "$backup_dir" "$LOG_DIR"
cp -- "${CONNECTOR_SOURCE}/package.json" "${CONNECTOR_SOURCE}/package-lock.json" \
  "$staging_release/runtime/"
cp -R -- "${CONNECTOR_SOURCE}/src/." "$staging_release/runtime/src/"
(
  cd "$staging_release/runtime"
  "$npm_binary" ci --omit=dev --ignore-scripts
)
cp -- "$settings_source" "$staging_settings"
chmod 600 "$staging_settings"
cp -- "$SCRIPT_DIR/launcher.py" "$staging_launcher"
chmod 700 "$staging_launcher"

"$python_binary" "$SCRIPT_DIR/render-plist.py" \
  --output "$staging_plist" \
  --label "$LABEL" \
  --python "$python_binary" \
  --launcher "$LAUNCHER_PATH" \
  --settings "$SETTINGS_PATH" \
  --connector "${CURRENT_LINK}/runtime/src/cli.js" \
  --node "$node_binary" \
  --stdout "${LOG_DIR}/codex-connector.out.log" \
  --stderr "${LOG_DIR}/codex-connector.err.log"
plutil -lint "$staging_plist" >/dev/null

if launchctl print "gui/${UID}/${LABEL}" >/dev/null 2>&1; then
  service_was_loaded=true
fi
if [[ -L "$CURRENT_LINK" ]]; then
  readlink "$CURRENT_LINK" >"${backup_dir}/previous-current"
else
  : >"${backup_dir}/current-absent"
fi
for pair in "plist:${PLIST_PATH}" "settings:${SETTINGS_PATH}" "launcher:${LAUNCHER_PATH}"; do
  name="${pair%%:*}"
  path="${pair#*:}"
  if [[ -f "$path" ]]; then
    cp -p -- "$path" "${backup_dir}/${name}"
  else
    : >"${backup_dir}/${name}-absent"
  fi
done
printf '%s\n' "$service_was_loaded" >"${backup_dir}/service-was-loaded"

restore_snapshot() {
  launchctl bootout "gui/${UID}/${LABEL}" >/dev/null 2>&1 || true
  if [[ -f "${backup_dir}/previous-current" ]]; then
    previous_target="$(<"${backup_dir}/previous-current")"
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
  if [[ "$service_was_loaded" == true && -f "$PLIST_PATH" ]]; then
    launchctl bootstrap "gui/${UID}" "$PLIST_PATH" >/dev/null
  fi
}

transaction_active=false
restore_after_error() {
  status=$?
  trap - ERR
  if [[ "$transaction_active" == true ]]; then
    transaction_active=false
    printf 'ERROR: install failed after activation began; restoring previous package\n' >&2
    restore_snapshot || printf 'ERROR: automatic restore was incomplete\n' >&2
  fi
  exit "$status"
}
trap restore_after_error ERR

transaction_active=true
if [[ "$service_was_loaded" == true ]]; then
  launchctl bootout "gui/${UID}/${LABEL}"
fi

mv -- "$staging_release" "$release_dir"
cp -- "$staging_settings" "$SETTINGS_PATH"
cp -- "$staging_launcher" "$LAUNCHER_PATH"
cp -- "$staging_plist" "$PLIST_PATH"
chmod 600 "$SETTINGS_PATH" "$PLIST_PATH"
chmod 700 "$LAUNCHER_PATH"
ln -sfn -- "$release_dir" "$CURRENT_LINK"

if ! launchctl bootstrap "gui/${UID}" "$PLIST_PATH"; then
  printf 'ERROR: launchd bootstrap failed; restoring previous package\n' >&2
  transaction_active=false
  restore_snapshot
  exit 1
fi
printf '%s\n' "$release_id" >"$LAST_BACKUP"
transaction_active=false
printf 'installed_release=%s\n' "$release_id"
printf 'token_stored_in_plist=false\n'

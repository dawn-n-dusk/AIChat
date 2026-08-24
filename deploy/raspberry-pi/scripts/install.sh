#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_deploy_config "${1:-}"
require_root
for command in "$AICHAT_PYTHON" awk chmod chown cp curl env getent git groupadd install ln \
  mktemp mv rm runuser sed sleep systemctl test useradd; do
  require_command "$command"
done
[[ -x "$AICHAT_CADDY_BINARY" ]] || die "Caddy binary is not executable: $AICHAT_CADDY_BINARY"
[[ -f "$AICHAT_CADDY_CONFIG" ]] || die "Caddy config does not exist: $AICHAT_CADDY_CONFIG"

# AIChat's V0 WebSocket token is in the query string. A candidate Caddyfile must
# prove that the exact AIChat prefix is excluded from access logging before any
# package-owned service account, database, release, or live Caddyfile is changed.
# Existing access logs for the root/AeroLink site remain enabled.
preflight_root="$(mktemp -d)"
preflight_route="${preflight_root}/caddy-route.caddy"
preflight_global_options="${preflight_root}/caddy-global-options.caddy"
preflight_adapted="${preflight_root}/adapted.json"
preflight_candidate="$(mktemp "${AICHAT_CADDY_CONFIG}.aichat-candidate.XXXXXX")"
preflight_backup=""
cleanup_preflight() {
  rm -rf -- "$preflight_root"
  rm -f -- "$preflight_candidate"
  if [[ -n "$preflight_backup" && "$preflight_backup" != UNCHANGED ]]; then
    rm -f -- "$preflight_backup"
  fi
}
trap cleanup_preflight EXIT
cp -a "$AICHAT_CADDY_CONFIG" "$preflight_candidate"
render_caddy_route "$preflight_route"
render_caddy_global_options "$preflight_global_options"
if ! preflight_backup="$($AICHAT_PYTHON "$SCRIPT_DIR/patch-caddy.py" \
  --config "$preflight_candidate" \
  --mode install \
  --route "$preflight_route" \
  --global-options "$preflight_global_options" \
  --fallback "$AICHAT_CADDY_FALLBACK")"; then
  die "failed to construct the candidate Caddyfile"
fi
if ! "$AICHAT_CADDY_BINARY" adapt \
    --config "$preflight_candidate" --adapter caddyfile >"$preflight_adapted" ||
  ! "$AICHAT_PYTHON" "$SCRIPT_DIR/validate-caddy-route.py" \
    --adapted-json "$preflight_adapted" \
    --path-prefix "$AICHAT_PATH_PREFIX" \
    --relay-dial "127.0.0.1:${AICHAT_RELAY_PORT}" \
    --fallback-dial "${AICHAT_CADDY_FALLBACK#reverse_proxy }" \
    --public-provisioning "$AICHAT_PUBLIC_PROVISIONING" ||
  ! "$AICHAT_CADDY_BINARY" validate \
    --config "$preflight_candidate" --adapter caddyfile >/dev/null; then
  die "candidate Caddyfile failed AIChat route/log-safety preflight; live Caddyfile is unchanged"
fi
cleanup_preflight
trap - EXIT

readonly APP_ROOT=/opt/aichat-relay
readonly RELEASES_DIR=${APP_ROOT}/releases
readonly RELEASE_DIR=${RELEASES_DIR}/${AICHAT_RELEASE_ID}
readonly CURRENT_LINK=${APP_ROOT}/current
readonly PREVIOUS_LINK=${APP_ROOT}/previous
readonly ETC_DIR=/etc/aichat-relay
readonly LIBEXEC_DIR=/usr/local/libexec/aichat-relay
readonly CADDY_ROUTE=${ETC_DIR}/caddy-route.caddy
readonly CADDY_GLOBAL_OPTIONS=${ETC_DIR}/caddy-global-options.caddy

[[ ! -e "$RELEASE_DIR" && ! -L "$RELEASE_DIR" ]] ||
  die "release path already exists, including a dangling symlink: $RELEASE_DIR"

old_current=""
old_current_status=0
old_current="$(resolve_release_link CURRENT_LINK "$CURRENT_LINK" "$RELEASES_DIR")" ||
  old_current_status=$?
if ((old_current_status > 1)); then
  die "current release link failed validation before any package state was changed"
fi
old_previous=""
old_previous_status=0
old_previous="$(resolve_release_link PREVIOUS_LINK "$PREVIOUS_LINK" "$RELEASES_DIR")" ||
  old_previous_status=$?
if ((old_previous_status > 1)); then
  die "previous release link failed validation before any package state was changed"
fi

if command -v ss >/dev/null 2>&1 && ! systemctl is-active --quiet aichat-relay.service; then
  if ss -H -ltn | awk -v suffix=":${AICHAT_RELAY_PORT}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
    die "port ${AICHAT_RELAY_PORT} is already listening; choose another non-RustDesk port"
  fi
fi

service_was_active=false
service_was_enabled=false
timer_was_active=false
timer_was_enabled=false
if systemctl is-active --quiet aichat-relay.service; then
  service_was_active=true
fi
if systemctl is-enabled --quiet aichat-relay.service; then
  service_was_enabled=true
fi
if systemctl is-active --quiet aichat-relay-backup.timer; then
  timer_was_active=true
fi
if systemctl is-enabled --quiet aichat-relay-backup.timer; then
  timer_was_enabled=true
fi

TRANSACTION_BACKUP_ROOT="$(mktemp -d)"
readonly TRANSACTION_BACKUP_ROOT
cleanup_transaction_snapshot() {
  rm -rf -- "$TRANSACTION_BACKUP_ROOT"
}
trap cleanup_transaction_snapshot EXIT
readonly -a TRANSACTION_PATHS=(
  "$ETC_DIR/relay.env"
  "$CADDY_ROUTE"
  "$CADDY_GLOBAL_OPTIONS"
  "$LIBEXEC_DIR/backup.sh"
  "$LIBEXEC_DIR/backup.py"
  "$LIBEXEC_DIR/patch-caddy.py"
  "$LIBEXEC_DIR/seed-database.py"
  "$LIBEXEC_DIR/validate-caddy-route.py"
  /etc/systemd/system/aichat-relay.service
  /etc/systemd/system/aichat-relay-backup.service
  /etc/systemd/system/aichat-relay-backup.timer
)
for transaction_index in "${!TRANSACTION_PATHS[@]}"; do
  snapshot_path_state "$TRANSACTION_BACKUP_ROOT" "$transaction_index" \
    "${TRANSACTION_PATHS[$transaction_index]}"
done

old_relay_port="$AICHAT_RELAY_PORT"
if [[ -f "$ETC_DIR/relay.env" ]]; then
  captured_old_relay_port="$(awk -F= '$1 == "AICHAT_RELAY_PORT" {print substr($0, index($0, "=") + 1); exit}' \
    "$ETC_DIR/relay.env")"
  if [[ -n "$captured_old_relay_port" ]]; then
    [[ "$captured_old_relay_port" =~ ^[0-9]+$ ]] ||
      die "existing relay.env contains an invalid AICHAT_RELAY_PORT"
    old_relay_port="$captured_old_relay_port"
  fi
fi

runtime_tmp=""
route_tmp=""
global_options_tmp=""
adapted_caddy=""
caddy_backup=""
transaction_active=false
caddy_changed=false
units_loaded=false
transaction_backup_should_cleanup=true

cleanup_files() {
  [[ -z "$runtime_tmp" ]] || rm -f -- "$runtime_tmp"
  [[ -z "$route_tmp" ]] || rm -f -- "$route_tmp"
  [[ -z "$global_options_tmp" ]] || rm -f -- "$global_options_tmp"
  [[ -z "$adapted_caddy" ]] || rm -f -- "$adapted_caddy"
  if [[ "$transaction_backup_should_cleanup" == true ]]; then
    rm -rf -- "$TRANSACTION_BACKUP_ROOT"
  else
    printf 'ERROR: preserving transaction snapshot for manual recovery: %s\n' \
      "$TRANSACTION_BACKUP_ROOT" >&2
  fi
}
trap cleanup_files EXIT

restore_installed_files() {
  local failures=0 index
  for index in "${!TRANSACTION_PATHS[@]}"; do
    restore_path_state "$TRANSACTION_BACKUP_ROOT" "$index" \
      "${TRANSACTION_PATHS[$index]}" || failures=$((failures + 1))
  done
  ((failures == 0))
}

restore_enabled_state() {
  local unit="$1"
  local was_enabled="$2"
  if [[ "$was_enabled" == true ]]; then
    systemctl enable "$unit" >/dev/null
  else
    systemctl disable "$unit" >/dev/null
  fi
}

restore_caddy() {
  if [[ "$caddy_changed" != true ]]; then
    return 0
  fi
  if [[ -z "$caddy_backup" || "$caddy_backup" == UNCHANGED || ! -f "$caddy_backup" ]]; then
    if [[ "$caddy_backup" == UNCHANGED ]]; then
      return 0
    fi
    printf 'ERROR: Caddy changed but no usable atomic backup was recorded\n' >&2
    return 1
  fi
  if ! "$RELEASE_DIR/venv/bin/python" "$SCRIPT_DIR/patch-caddy.py" \
    --config "$AICHAT_CADDY_CONFIG" --mode restore --source "$caddy_backup"; then
    printf 'ERROR: failed to atomically restore Caddy backup %s\n' "$caddy_backup" >&2
    return 1
  fi
  if ! "$AICHAT_CADDY_BINARY" validate \
    --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
    printf 'ERROR: restored Caddy backup does not validate: %s\n' "$caddy_backup" >&2
    return 1
  fi
  if ! "$AICHAT_CADDY_BINARY" reload \
    --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
    printf 'ERROR: restored Caddy backup but reload failed: %s\n' "$caddy_backup" >&2
    return 1
  fi
}

rollback_transaction() {
  local failures=0

  trap - ERR
  set +e
  transaction_backup_should_cleanup=false
  if ! restore_caddy; then
    failures=$((failures + 1))
  fi
  if [[ "$units_loaded" == true || "$timer_was_active" == true ]]; then
    if ! systemctl stop aichat-relay-backup.timer; then
      printf 'ERROR: failed to stop aichat-relay-backup.timer during rollback\n' >&2
      failures=$((failures + 1))
    fi
  fi
  if [[ "$units_loaded" == true || "$service_was_active" == true ]]; then
    if ! systemctl stop aichat-relay.service; then
      printf 'ERROR: failed to stop aichat-relay.service during rollback\n' >&2
      failures=$((failures + 1))
    fi
  fi
  if [[ -f /etc/systemd/system/aichat-relay.service ]]; then
    restore_enabled_state aichat-relay.service "$service_was_enabled" ||
      failures=$((failures + 1))
  fi
  if [[ -f /etc/systemd/system/aichat-relay-backup.timer ]]; then
    restore_enabled_state aichat-relay-backup.timer "$timer_was_enabled" ||
      failures=$((failures + 1))
  fi
  restore_release_link_state CURRENT_LINK "$CURRENT_LINK" "$old_current" "$RELEASES_DIR" ||
    failures=$((failures + 1))
  restore_release_link_state PREVIOUS_LINK "$PREVIOUS_LINK" "$old_previous" "$RELEASES_DIR" ||
    failures=$((failures + 1))
  restore_installed_files || failures=$((failures + 1))
  if ! systemctl daemon-reload; then
    printf 'ERROR: systemd daemon-reload failed during rollback\n' >&2
    failures=$((failures + 1))
  fi
  if [[ "$service_was_enabled" == true ]]; then
    restore_enabled_state aichat-relay.service true || failures=$((failures + 1))
  fi
  if [[ "$timer_was_enabled" == true ]]; then
    restore_enabled_state aichat-relay-backup.timer true || failures=$((failures + 1))
  fi

  if [[ "$service_was_active" == true ]]; then
    if [[ -z "$old_current" ]] ||
      ! systemctl restart aichat-relay.service || ! wait_for_local_health 30 "$old_relay_port"; then
      printf 'ERROR: original Relay service did not recover health\n' >&2
      failures=$((failures + 1))
    fi
  fi
  if [[ "$timer_was_active" == true ]]; then
    if ! systemctl start aichat-relay-backup.timer; then
      printf 'ERROR: failed to restore active state for aichat-relay-backup.timer\n' >&2
      failures=$((failures + 1))
    fi
  fi

  transaction_active=false
  set -e
  if ((failures == 0)); then
    transaction_backup_should_cleanup=true
  fi
  ((failures == 0))
}

fail_transaction() {
  local reason="$1"
  if rollback_transaction; then
    die "$reason; Caddy, release links, installed files, and service state were rolled back"
  fi
  die "$reason and rollback was incomplete; inspect the preceding ERROR lines"
}

handle_unexpected_error() {
  local status="$1"
  local line="$2"
  if [[ "$transaction_active" == true ]]; then
    printf 'ERROR: unexpected installer failure at line %s; starting rollback\n' "$line" >&2
    if rollback_transaction; then
      printf 'ERROR: unexpected installer failure was rolled back\n' >&2
    else
      printf 'ERROR: unexpected installer failure rollback was incomplete\n' >&2
    fi
  fi
  exit "$status"
}
trap 'handle_unexpected_error $? $LINENO' ERR
transaction_active=true

note "creating the dedicated aichat-relay account and directories"
getent group aichat-relay >/dev/null || groupadd --system aichat-relay
getent passwd aichat-relay >/dev/null || useradd \
  --system --gid aichat-relay --home-dir /var/lib/aichat-relay \
  --no-create-home --shell /usr/sbin/nologin aichat-relay
install -d -o root -g root -m 0755 "$APP_ROOT" "$RELEASES_DIR"
install -d -o root -g aichat-relay -m 0750 "$ETC_DIR"
install -d -o root -g root -m 0755 "$LIBEXEC_DIR"
install -d -o aichat-relay -g aichat-relay -m 0700 "$(dirname "$AICHAT_DB_PATH")"
install -d -o aichat-relay -g aichat-relay -m 0700 "$AICHAT_BACKUP_DIR"

if [[ ! -e "$AICHAT_DB_PATH" ]]; then
  if [[ -n "$AICHAT_SEED_DB" ]]; then
    note "seeding the existing Relay identity database before first start"
    "$AICHAT_PYTHON" "$SCRIPT_DIR/seed-database.py" \
      --source "$AICHAT_SEED_DB" --destination "$AICHAT_DB_PATH"
    chown aichat-relay:aichat-relay "$AICHAT_DB_PATH"
    chmod 0600 "$AICHAT_DB_PATH"
  elif [[ "$AICHAT_REQUIRE_SEED_DB" == true ]]; then
    fail_transaction "first install requires AICHAT_SEED_DB; refusing to create an empty production identity database"
  else
    note "no seed database supplied; first start will create an empty loopback-only database"
  fi
else
  note "preserving existing Relay database at $AICHAT_DB_PATH"
fi

note "staging release ${AICHAT_RELEASE_ID}"
install -d -o root -g root -m 0755 "$RELEASE_DIR" "$RELEASE_DIR/server"
cp -a "$AICHAT_SOURCE_ROOT/server/app" "$RELEASE_DIR/server/app"
install -o root -g root -m 0644 "$AICHAT_SOURCE_ROOT/server/pyproject.toml" "$RELEASE_DIR/server/pyproject.toml"
install -o root -g root -m 0644 "$AICHAT_SOURCE_ROOT/server/README.md" "$RELEASE_DIR/server/README.md"
if git -C "$AICHAT_SOURCE_ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
  git -C "$AICHAT_SOURCE_ROOT" rev-parse HEAD >"$RELEASE_DIR/REVISION"
else
  printf 'unversioned-source\n' >"$RELEASE_DIR/REVISION"
fi
"$AICHAT_PYTHON" -m venv "$RELEASE_DIR/venv"
"$RELEASE_DIR/venv/bin/python" -m pip install --disable-pip-version-check --no-cache-dir "$RELEASE_DIR/server"
chown -R root:root "$RELEASE_DIR"
chmod -R u=rwX,go=rX "$RELEASE_DIR"
if ! runuser -u aichat-relay -- test -x "$RELEASE_DIR/server" ||
  ! runuser -u aichat-relay -- test -x "$RELEASE_DIR/venv/bin/uvicorn"; then
  fail_transaction "staged release paths are not traversable/executable by the aichat-relay service account"
fi
if ! runuser -u aichat-relay -- \
  env PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$RELEASE_DIR/server" \
  "$RELEASE_DIR/venv/bin/python" -c 'import app.main'; then
  fail_transaction "staged release is not executable/importable by the aichat-relay service account"
fi

note "installing runtime configuration and systemd units"
runtime_tmp="$(mktemp)"
route_tmp="$(mktemp)"
global_options_tmp="$(mktemp)"
{
  printf 'AICHAT_RELAY_PORT=%s\n' "$AICHAT_RELAY_PORT"
  printf 'AICHAT_DB_PATH=%s\n' "$AICHAT_DB_PATH"
  printf 'AICHAT_BACKUP_DIR=%s\n' "$AICHAT_BACKUP_DIR"
  printf 'AICHAT_BACKUP_RETENTION_DAYS=%s\n' "$AICHAT_BACKUP_RETENTION_DAYS"
  printf 'AICHAT_PRODUCTION_LOCKDOWN=%s\n' "$AICHAT_PRODUCTION_LOCKDOWN"
  printf 'AICHAT_DOCS_ENABLED=%s\n' "$AICHAT_DOCS_ENABLED"
  printf 'AICHAT_AGENT_REGISTRATION_ENABLED=%s\n' "$AICHAT_AGENT_REGISTRATION_ENABLED"
  printf 'AICHAT_CHANNEL_CREATE_ENABLED=%s\n' "$AICHAT_CHANNEL_CREATE_ENABLED"
  printf 'AICHAT_CHANNEL_JOIN_ENABLED=%s\n' "$AICHAT_CHANNEL_JOIN_ENABLED"
  printf 'AICHAT_HTTP_RATE_LIMIT_PER_MINUTE=%s\n' "$AICHAT_HTTP_RATE_LIMIT_PER_MINUTE"
  printf 'AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE=%s\n' "$AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE"
  printf 'AICHAT_WS_MAX_CONNECTIONS=%s\n' "$AICHAT_WS_MAX_CONNECTIONS"
  printf 'AICHAT_WS_MAX_CONNECTIONS_PER_AGENT=%s\n' "$AICHAT_WS_MAX_CONNECTIONS_PER_AGENT"
  printf 'AICHAT_TRUSTED_PROXY_CIDRS=%s\n' "$AICHAT_TRUSTED_PROXY_CIDRS"
  printf 'AICHAT_DOMAIN=%s\n' "$AICHAT_DOMAIN"
  printf 'AICHAT_PATH_PREFIX=%s\n' "$AICHAT_PATH_PREFIX"
  printf 'AICHAT_PUBLIC_BASE_URL=%s\n' "$AICHAT_PUBLIC_BASE_URL"
  printf 'AICHAT_PUBLIC_PROVISIONING=%s\n' "$AICHAT_PUBLIC_PROVISIONING"
  printf 'AICHAT_PYTHON_BIN=/opt/aichat-relay/current/venv/bin/python\n'
} >"$runtime_tmp"
install -o root -g aichat-relay -m 0640 "$runtime_tmp" "$ETC_DIR/relay.env"
render_caddy_route "$route_tmp"
render_caddy_global_options "$global_options_tmp"
install -o root -g root -m 0644 "$route_tmp" "$CADDY_ROUTE"
install -o root -g root -m 0644 "$global_options_tmp" "$CADDY_GLOBAL_OPTIONS"
install -o root -g root -m 0755 "$SCRIPT_DIR/backup.sh" "$LIBEXEC_DIR/backup.sh"
install -o root -g root -m 0755 "$SCRIPT_DIR/backup.py" "$LIBEXEC_DIR/backup.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/patch-caddy.py" "$LIBEXEC_DIR/patch-caddy.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/seed-database.py" "$LIBEXEC_DIR/seed-database.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/validate-caddy-route.py" "$LIBEXEC_DIR/validate-caddy-route.py"
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay.service" /etc/systemd/system/aichat-relay.service
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay-backup.service" /etc/systemd/system/aichat-relay-backup.service
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay-backup.timer" /etc/systemd/system/aichat-relay-backup.timer

atomic_symlink "$RELEASE_DIR" "$CURRENT_LINK"
systemctl daemon-reload
units_loaded=true
systemctl enable aichat-relay.service aichat-relay-backup.timer >/dev/null

note "starting loopback Relay on 127.0.0.1:${AICHAT_RELAY_PORT}"
if ! systemctl restart aichat-relay.service || ! wait_for_local_health 30; then
  fail_transaction "Relay failed local health acceptance"
fi

note "installing the path-prefixed route into the existing Caddyfile"
caddy_backup="$("$RELEASE_DIR/venv/bin/python" "$SCRIPT_DIR/patch-caddy.py" \
  --config "$AICHAT_CADDY_CONFIG" \
  --mode install \
  --route "$CADDY_ROUTE" \
  --global-options "$CADDY_GLOBAL_OPTIONS" \
  --fallback "$AICHAT_CADDY_FALLBACK")"
caddy_changed=true

adapted_caddy="$(mktemp)"
if ! "$AICHAT_CADDY_BINARY" adapt --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile >"$adapted_caddy" ||
  ! "$RELEASE_DIR/venv/bin/python" "$SCRIPT_DIR/validate-caddy-route.py" \
    --adapted-json "$adapted_caddy" \
    --path-prefix "$AICHAT_PATH_PREFIX" \
    --relay-dial "127.0.0.1:${AICHAT_RELAY_PORT}" \
    --fallback-dial "${AICHAT_CADDY_FALLBACK#reverse_proxy }" \
    --public-provisioning "$AICHAT_PUBLIC_PROVISIONING" ||
  ! "$AICHAT_CADDY_BINARY" validate --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
  fail_transaction "Caddy validation/adapted-route acceptance failed"
fi
rm -f -- "$adapted_caddy"
adapted_caddy=""
if ! "$AICHAT_CADDY_BINARY" reload --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
  fail_transaction "Caddy reload failed"
fi

if ! curl --fail --silent --show-error --max-time 15 "$AICHAT_PUBLIC_BASE_URL/health" >/dev/null; then
  fail_transaction "public HTTPS health check failed"
fi

if ! systemctl enable --now aichat-relay-backup.timer >/dev/null ||
  ! systemctl start aichat-relay-backup.service; then
  fail_transaction "initial backup or backup timer acceptance failed"
fi
if [[ -n "$old_current" ]]; then
  if ! atomic_symlink "$old_current" "$PREVIOUS_LINK"; then
    fail_transaction "deployment passed health checks but previous release link update failed"
  fi
fi

transaction_active=false
trap - ERR

note "deployment accepted"
printf 'Public Relay base: %s\n' "$AICHAT_PUBLIC_BASE_URL"
printf 'Local upstream: http://127.0.0.1:%s\n' "$AICHAT_RELAY_PORT"
printf 'Caddy backup: %s\n' "$caddy_backup"
printf 'RustDesk ports 21115-21119 and firewall policy were not modified.\n'

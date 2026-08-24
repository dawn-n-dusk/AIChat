#!/usr/bin/env bash

set -Eeuo pipefail
umask 027

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_deploy_config "${1:-}"
require_root
for command in "$AICHAT_PYTHON" curl getent install ln mv sed systemctl; do
  require_command "$command"
done
[[ -x "$AICHAT_CADDY_BINARY" ]] || die "Caddy binary is not executable: $AICHAT_CADDY_BINARY"
[[ -f "$AICHAT_CADDY_CONFIG" ]] || die "Caddy config does not exist: $AICHAT_CADDY_CONFIG"

# AIChat's V0 WebSocket token is in the query string. This package refuses a
# Caddyfile with access logging or global debug enabled because either can expose
# that URI before the application redacts its ASGI scope.
if grep -Eq '^[[:space:]]*log[[:space:]]*\{' "$AICHAT_CADDY_CONFIG"; then
  die "Caddy access logging is enabled; disable it or add a proven query-token redaction policy first"
fi
if grep -Eq '^[[:space:]]*debug([[:space:]]|$)' "$AICHAT_CADDY_CONFIG"; then
  die "Caddy global debug logging is enabled; disable it before public AIChat activation"
fi

readonly APP_ROOT=/opt/aichat-relay
readonly RELEASES_DIR=${APP_ROOT}/releases
readonly RELEASE_DIR=${RELEASES_DIR}/${AICHAT_RELEASE_ID}
readonly CURRENT_LINK=${APP_ROOT}/current
readonly PREVIOUS_LINK=${APP_ROOT}/previous
readonly ETC_DIR=/etc/aichat-relay
readonly LIBEXEC_DIR=/usr/local/libexec/aichat-relay
readonly CADDY_ROUTE=${ETC_DIR}/caddy-route.caddy

[[ ! -e "$RELEASE_DIR" ]] || die "release already exists: $RELEASE_DIR"

if command -v ss >/dev/null 2>&1 && ! systemctl is-active --quiet aichat-relay.service; then
  if ss -H -ltn | awk -v suffix=":${AICHAT_RELAY_PORT}" '$4 ~ suffix "$" {found=1} END {exit !found}'; then
    die "port ${AICHAT_RELAY_PORT} is already listening; choose another non-RustDesk port"
  fi
fi

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
    die "first install requires AICHAT_SEED_DB; refusing to create an empty production identity database"
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
chmod -R go-w "$RELEASE_DIR"

note "installing runtime configuration and systemd units"
runtime_tmp="$(mktemp)"
route_tmp="$(mktemp)"
cleanup_files() {
  rm -f "$runtime_tmp" "$route_tmp"
}
trap cleanup_files EXIT
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
if [[ -f "$ETC_DIR/relay.env" ]]; then
  cp -a "$ETC_DIR/relay.env" "$ETC_DIR/relay.env.previous"
fi
install -o root -g aichat-relay -m 0640 "$runtime_tmp" "$ETC_DIR/relay.env"
render_caddy_route "$route_tmp"
install -o root -g root -m 0644 "$route_tmp" "$CADDY_ROUTE"
install -o root -g root -m 0755 "$SCRIPT_DIR/backup.sh" "$LIBEXEC_DIR/backup.sh"
install -o root -g root -m 0755 "$SCRIPT_DIR/backup.py" "$LIBEXEC_DIR/backup.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/patch-caddy.py" "$LIBEXEC_DIR/patch-caddy.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/seed-database.py" "$LIBEXEC_DIR/seed-database.py"
install -o root -g root -m 0755 "$SCRIPT_DIR/validate-caddy-route.py" "$LIBEXEC_DIR/validate-caddy-route.py"
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay.service" /etc/systemd/system/aichat-relay.service
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay-backup.service" /etc/systemd/system/aichat-relay-backup.service
install -o root -g root -m 0644 "$AICHAT_DEPLOY_ROOT/templates/aichat-relay-backup.timer" /etc/systemd/system/aichat-relay-backup.timer

old_current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
if [[ -n "$old_current" && "$old_current" == "$RELEASES_DIR"/* ]]; then
  atomic_symlink "$old_current" "$PREVIOUS_LINK"
fi
atomic_symlink "$RELEASE_DIR" "$CURRENT_LINK"
systemctl daemon-reload
systemctl enable aichat-relay.service aichat-relay-backup.timer >/dev/null

rollback_release() {
  if [[ -n "$old_current" && -d "$old_current" ]]; then
    atomic_symlink "$old_current" "$CURRENT_LINK"
    systemctl restart aichat-relay.service || true
  else
    systemctl stop aichat-relay.service || true
  fi
}

note "starting loopback Relay on 127.0.0.1:${AICHAT_RELAY_PORT}"
if ! systemctl restart aichat-relay.service || ! wait_for_local_health 30; then
  rollback_release
  die "Relay failed local health acceptance; release link was rolled back"
fi

note "installing the path-prefixed route into the existing Caddyfile"
caddy_backup="$($RELEASE_DIR/venv/bin/python "$SCRIPT_DIR/patch-caddy.py" \
  --config "$AICHAT_CADDY_CONFIG" \
  --mode install \
  --route "$CADDY_ROUTE" \
  --fallback "$AICHAT_CADDY_FALLBACK")"

restore_caddy() {
  if [[ -n "$caddy_backup" && "$caddy_backup" != UNCHANGED && -f "$caddy_backup" ]]; then
    cp -a "$caddy_backup" "$AICHAT_CADDY_CONFIG"
    "$AICHAT_CADDY_BINARY" reload --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile || true
  fi
}

adapted_caddy="$(mktemp)"
if ! "$AICHAT_CADDY_BINARY" validate --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile ||
  ! "$AICHAT_CADDY_BINARY" adapt --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile >"$adapted_caddy" ||
  ! "$RELEASE_DIR/venv/bin/python" "$SCRIPT_DIR/validate-caddy-route.py" \
    --adapted-json "$adapted_caddy" \
    --path-prefix "$AICHAT_PATH_PREFIX" \
    --relay-dial "127.0.0.1:${AICHAT_RELAY_PORT}" \
    --fallback-dial "${AICHAT_CADDY_FALLBACK#reverse_proxy }" \
    --public-provisioning "$AICHAT_PUBLIC_PROVISIONING"; then
  rm -f "$adapted_caddy"
  restore_caddy
  rollback_release
  die "Caddy validation/adapted-route acceptance failed; Caddyfile and Relay release were rolled back"
fi
rm -f "$adapted_caddy"
if ! "$AICHAT_CADDY_BINARY" reload --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
  restore_caddy
  rollback_release
  die "Caddy reload failed; Caddyfile and Relay release were rolled back"
fi

if ! curl --fail --silent --show-error --max-time 15 "$AICHAT_PUBLIC_BASE_URL/health" >/dev/null; then
  restore_caddy
  rollback_release
  die "public HTTPS health check failed; Caddyfile and Relay release were rolled back"
fi

systemctl enable --now aichat-relay-backup.timer >/dev/null
systemctl start aichat-relay-backup.service

note "deployment accepted"
printf 'Public Relay base: %s\n' "$AICHAT_PUBLIC_BASE_URL"
printf 'Local upstream: http://127.0.0.1:%s\n' "$AICHAT_RELAY_PORT"
printf 'Caddy backup: %s\n' "$caddy_backup"
printf 'RustDesk ports 21115-21119 and firewall policy were not modified.\n'

#!/usr/bin/env bash

set -Eeuo pipefail

readonly AICHAT_DEPLOY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly AICHAT_RUSTDESK_PORT_MIN=21115
readonly AICHAT_RUSTDESK_PORT_MAX=21119

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '==> %s\n' "$*"
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "run this command as root"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is missing: $1"
}

require_absolute_path() {
  local name="$1"
  local value="$2"
  [[ "$value" == /* ]] || die "$name must be an absolute path"
}

load_deploy_config() {
  local config_path="${1:-${AICHAT_DEPLOY_ROOT}/config/deploy.env}"
  [[ -f "$config_path" ]] || die "deployment configuration does not exist: $config_path"

  set -a
  # shellcheck disable=SC1090
  source "$config_path"
  set +a

  : "${AICHAT_SOURCE_ROOT:?AICHAT_SOURCE_ROOT is required}"
  : "${AICHAT_RELEASE_ID:?AICHAT_RELEASE_ID is required}"
  : "${AICHAT_RELAY_PORT:?AICHAT_RELAY_PORT is required}"
  : "${AICHAT_DB_PATH:?AICHAT_DB_PATH is required}"
  : "${AICHAT_BACKUP_DIR:?AICHAT_BACKUP_DIR is required}"
  : "${AICHAT_BACKUP_RETENTION_DAYS:?AICHAT_BACKUP_RETENTION_DAYS is required}"
  : "${AICHAT_PRODUCTION_LOCKDOWN:?AICHAT_PRODUCTION_LOCKDOWN is required}"
  : "${AICHAT_DOCS_ENABLED:?AICHAT_DOCS_ENABLED is required}"
  : "${AICHAT_AGENT_REGISTRATION_ENABLED:?AICHAT_AGENT_REGISTRATION_ENABLED is required}"
  : "${AICHAT_CHANNEL_CREATE_ENABLED:?AICHAT_CHANNEL_CREATE_ENABLED is required}"
  : "${AICHAT_CHANNEL_JOIN_ENABLED:?AICHAT_CHANNEL_JOIN_ENABLED is required}"
  : "${AICHAT_HTTP_RATE_LIMIT_PER_MINUTE:?AICHAT_HTTP_RATE_LIMIT_PER_MINUTE is required}"
  : "${AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE:?AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE is required}"
  : "${AICHAT_WS_MAX_CONNECTIONS:?AICHAT_WS_MAX_CONNECTIONS is required}"
  : "${AICHAT_WS_MAX_CONNECTIONS_PER_AGENT:?AICHAT_WS_MAX_CONNECTIONS_PER_AGENT is required}"
  : "${AICHAT_TRUSTED_PROXY_CIDRS:?AICHAT_TRUSTED_PROXY_CIDRS is required}"
  : "${AICHAT_REQUIRE_SEED_DB:?AICHAT_REQUIRE_SEED_DB is required}"
  : "${AICHAT_DOMAIN:?AICHAT_DOMAIN is required}"
  : "${AICHAT_PATH_PREFIX:?AICHAT_PATH_PREFIX is required}"
  : "${AICHAT_PUBLIC_BASE_URL:?AICHAT_PUBLIC_BASE_URL is required}"
  : "${AICHAT_PUBLIC_PROVISIONING:?AICHAT_PUBLIC_PROVISIONING is required}"
  : "${AICHAT_CADDY_BINARY:?AICHAT_CADDY_BINARY is required}"
  : "${AICHAT_CADDY_CONFIG:?AICHAT_CADDY_CONFIG is required}"
  : "${AICHAT_CADDY_SERVICE:?AICHAT_CADDY_SERVICE is required}"
  : "${AICHAT_CADDY_FALLBACK:?AICHAT_CADDY_FALLBACK is required}"
  AICHAT_PYTHON="${AICHAT_PYTHON:-python3}"
  AICHAT_SEED_DB="${AICHAT_SEED_DB:-}"

  require_absolute_path AICHAT_SOURCE_ROOT "$AICHAT_SOURCE_ROOT"
  require_absolute_path AICHAT_DB_PATH "$AICHAT_DB_PATH"
  require_absolute_path AICHAT_BACKUP_DIR "$AICHAT_BACKUP_DIR"
  require_absolute_path AICHAT_CADDY_BINARY "$AICHAT_CADDY_BINARY"
  require_absolute_path AICHAT_CADDY_CONFIG "$AICHAT_CADDY_CONFIG"
  if [[ -n "$AICHAT_SEED_DB" ]]; then
    require_absolute_path AICHAT_SEED_DB "$AICHAT_SEED_DB"
  fi

  [[ "$AICHAT_RELEASE_ID" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "AICHAT_RELEASE_ID may contain only letters, digits, dot, underscore, and dash"
  [[ "$AICHAT_RELAY_PORT" =~ ^[0-9]+$ ]] || die "AICHAT_RELAY_PORT must be an integer"
  ((AICHAT_RELAY_PORT >= 1024 && AICHAT_RELAY_PORT <= 65535)) ||
    die "AICHAT_RELAY_PORT must be between 1024 and 65535"
  if ((AICHAT_RELAY_PORT >= AICHAT_RUSTDESK_PORT_MIN && AICHAT_RELAY_PORT <= AICHAT_RUSTDESK_PORT_MAX)); then
    die "AICHAT_RELAY_PORT must not use RustDesk ports 21115-21119"
  fi
  [[ "$AICHAT_BACKUP_RETENTION_DAYS" =~ ^[0-9]+$ ]] ||
    die "AICHAT_BACKUP_RETENTION_DAYS must be a non-negative integer"
  [[ "$AICHAT_PRODUCTION_LOCKDOWN" == true ]] ||
    die "AICHAT_PRODUCTION_LOCKDOWN must remain true for this public deployment package"
  [[ "$AICHAT_DOCS_ENABLED" == false ]] ||
    die "AICHAT_DOCS_ENABLED must remain false for this public deployment package"
  [[ "$AICHAT_AGENT_REGISTRATION_ENABLED" == false ]] ||
    die "AICHAT_AGENT_REGISTRATION_ENABLED must remain false outside a controlled bootstrap window"
  [[ "$AICHAT_CHANNEL_CREATE_ENABLED" == false ]] ||
    die "AICHAT_CHANNEL_CREATE_ENABLED must remain false outside a controlled bootstrap window"
  [[ "$AICHAT_CHANNEL_JOIN_ENABLED" == false ]] ||
    die "AICHAT_CHANNEL_JOIN_ENABLED must remain false outside a controlled bootstrap window"
  [[ "$AICHAT_HTTP_RATE_LIMIT_PER_MINUTE" == 120 ]] ||
    die "AICHAT_HTTP_RATE_LIMIT_PER_MINUTE must be 120"
  [[ "$AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE" == 30 ]] ||
    die "AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE must be 30"
  [[ "$AICHAT_WS_MAX_CONNECTIONS" == 128 ]] ||
    die "AICHAT_WS_MAX_CONNECTIONS must be 128"
  [[ "$AICHAT_WS_MAX_CONNECTIONS_PER_AGENT" == 4 ]] ||
    die "AICHAT_WS_MAX_CONNECTIONS_PER_AGENT must be 4"
  [[ "$AICHAT_TRUSTED_PROXY_CIDRS" == "127.0.0.0/8,::1/128" ]] ||
    die "AICHAT_TRUSTED_PROXY_CIDRS must trust loopback only"
  [[ "$AICHAT_REQUIRE_SEED_DB" == false || "$AICHAT_REQUIRE_SEED_DB" == true ]] ||
    die "AICHAT_REQUIRE_SEED_DB must be true or false"
  [[ "$AICHAT_DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$AICHAT_DOMAIN" == *.* ]] ||
    die "AICHAT_DOMAIN is not a valid DNS hostname"
  [[ "$AICHAT_PATH_PREFIX" =~ ^/[A-Za-z0-9._~-]+$ ]] ||
    die "AICHAT_PATH_PREFIX must be one path segment such as /aichat"
  [[ "$AICHAT_PUBLIC_BASE_URL" == "https://${AICHAT_DOMAIN}${AICHAT_PATH_PREFIX}" ]] ||
    die "AICHAT_PUBLIC_BASE_URL must equal https://AICHAT_DOMAIN/AICHAT_PATH_PREFIX"
  [[ "$AICHAT_PUBLIC_PROVISIONING" == false || "$AICHAT_PUBLIC_PROVISIONING" == true ]] ||
    die "AICHAT_PUBLIC_PROVISIONING must be true or false"
  [[ -d "$AICHAT_SOURCE_ROOT/server/app" && -f "$AICHAT_SOURCE_ROOT/server/pyproject.toml" ]] ||
    die "AICHAT_SOURCE_ROOT does not contain the AIChat server source"
}

atomic_symlink() {
  local target="$1"
  local link_path="$2"
  local temporary="${link_path}.new.$$"
  ln -s "$target" "$temporary"
  mv -Tf "$temporary" "$link_path"
}

render_caddy_route() {
  local output="$1"
  local temporary="${output}.registration.$$"
  sed \
    -e "s|__AICHAT_PATH_PREFIX__|${AICHAT_PATH_PREFIX}|g" \
    -e "s|__AICHAT_RELAY_PORT__|${AICHAT_RELAY_PORT}|g" \
    "${AICHAT_DEPLOY_ROOT}/templates/caddy-route.caddy" >"$output"
  if [[ "$AICHAT_PUBLIC_PROVISIONING" == true ]]; then
    awk '
      /# BEGIN AICHAT PUBLIC PROVISIONING DENY/ { skipping=1; next }
      /# END AICHAT PUBLIC PROVISIONING DENY/ { skipping=0; next }
      !skipping { print }
    ' "$output" >"$temporary"
    mv "$temporary" "$output"
  fi
}

render_caddy_global_options() {
  local output="$1"
  cp "${AICHAT_DEPLOY_ROOT}/templates/caddy-global-options.caddy" "$output"
}

wait_for_local_health() {
  local attempts="${1:-30}"
  local index
  for ((index = 1; index <= attempts; index += 1)); do
    if curl --fail --silent --show-error --max-time 2 \
      "http://127.0.0.1:${AICHAT_RELAY_PORT}/health" >/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

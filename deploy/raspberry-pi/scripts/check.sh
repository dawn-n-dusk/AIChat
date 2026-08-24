#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_deploy_config "${1:-}"
require_root
for command in curl grep mktemp rm runuser sha256sum ss systemctl; do
  require_command "$command"
done

failures=0
pass() { printf 'PASS: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }
info() { printf 'INFO: %s\n' "$*"; }

expect_http_status() {
  local expected="$1"
  local description="$2"
  shift 2
  local status_code
  status_code="$(curl --silent --output /dev/null --max-time 15 --write-out '%{http_code}' "$@" || true)"
  if [[ "$status_code" == "$expected" ]]; then
    pass "$description"
  else
    fail "$description returned HTTP ${status_code:-transport-error}, expected $expected"
  fi
}

expect_edge_http_status() {
  local expected="$1"
  local description="$2"
  shift 2
  local headers status_code
  headers="$(mktemp)"
  status_code="$(
    curl --silent --output /dev/null --dump-header "$headers" --max-time 15 \
      --write-out '%{http_code}' "$@" || true
  )"
  if [[ "$status_code" == "$expected" ]] &&
    grep -Eiq '^X-AIChat-Edge-Deny:[[:space:]]*provisioning[[:space:]]*$' "$headers"; then
    pass "$description"
  elif [[ "$status_code" != "$expected" ]]; then
    fail "$description returned HTTP ${status_code:-transport-error}, expected $expected from the edge"
  else
    fail "$description returned HTTP $expected without the AIChat edge-deny marker"
  fi
  rm -f -- "$headers"
}

expect_not_edge_denied() {
  local description="$1"
  shift
  local headers status_code
  headers="$(mktemp)"
  status_code="$(
    curl --silent --output /dev/null --dump-header "$headers" --max-time 15 \
      --write-out '%{http_code}' "$@" || true
  )"
  if [[ "$status_code" =~ ^[1-5][0-9][0-9]$ && "$status_code" != 403 ]] &&
    ! grep -Eiq '^X-AIChat-Edge-Deny:[[:space:]]*provisioning[[:space:]]*$' "$headers"; then
    pass "$description"
  else
    fail "$description was incorrectly rejected by the POST-only edge provisioning gate"
  fi
  rm -f -- "$headers"
}

readonly RUNTIME_ENV=/etc/aichat-relay/relay.env
runtime_expectations=(
  "AICHAT_PRODUCTION_LOCKDOWN=$AICHAT_PRODUCTION_LOCKDOWN"
  "AICHAT_DOCS_ENABLED=$AICHAT_DOCS_ENABLED"
  "AICHAT_AGENT_REGISTRATION_ENABLED=$AICHAT_AGENT_REGISTRATION_ENABLED"
  "AICHAT_CHANNEL_CREATE_ENABLED=$AICHAT_CHANNEL_CREATE_ENABLED"
  "AICHAT_CHANNEL_JOIN_ENABLED=$AICHAT_CHANNEL_JOIN_ENABLED"
  "AICHAT_HTTP_RATE_LIMIT_PER_MINUTE=$AICHAT_HTTP_RATE_LIMIT_PER_MINUTE"
  "AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE=$AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE"
  "AICHAT_WS_MAX_CONNECTIONS=$AICHAT_WS_MAX_CONNECTIONS"
  "AICHAT_WS_MAX_CONNECTIONS_PER_AGENT=$AICHAT_WS_MAX_CONNECTIONS_PER_AGENT"
  "AICHAT_TRUSTED_PROXY_CIDRS=$AICHAT_TRUSTED_PROXY_CIDRS"
)
for expectation in "${runtime_expectations[@]}"; do
  if grep -Fxq "$expectation" "$RUNTIME_ENV"; then
    pass "runtime setting ${expectation%%=*}"
  else
    fail "runtime setting is missing or different: ${expectation%%=*}"
  fi
done

if systemctl is-active --quiet aichat-relay.service; then
  pass "aichat-relay.service is active"
else
  fail "aichat-relay.service is not active"
fi
if systemctl is-active --quiet "$AICHAT_CADDY_SERVICE"; then
  pass "$AICHAT_CADDY_SERVICE is active"
else
  fail "$AICHAT_CADDY_SERVICE is not active"
fi
if systemctl is-enabled --quiet aichat-relay-backup.timer; then
  pass "backup timer is enabled"
else
  fail "backup timer is not enabled"
fi

mapfile -t relay_listeners < <(
  ss -H -ltn | awk -v suffix=":${AICHAT_RELAY_PORT}" '$4 ~ suffix "$" {print $4}'
)
if ((${#relay_listeners[@]} == 1)) && [[ "${relay_listeners[0]}" == "127.0.0.1:${AICHAT_RELAY_PORT}" ]]; then
  pass "Relay listens only on 127.0.0.1:${AICHAT_RELAY_PORT}"
else
  fail "unexpected Relay listener set: ${relay_listeners[*]:-(none)}"
fi

if curl --fail --silent --show-error --max-time 5 \
  "http://127.0.0.1:${AICHAT_RELAY_PORT}/health" >/dev/null; then
  pass "local Relay health"
else
  fail "local Relay health"
fi
if curl --fail --silent --show-error --max-time 15 "$AICHAT_PUBLIC_BASE_URL/health" >/dev/null; then
  pass "public HTTPS path-prefix health"
else
  fail "public HTTPS path-prefix health"
fi

expect_http_status 404 "local /docs is disabled" \
  "http://127.0.0.1:${AICHAT_RELAY_PORT}/docs"
expect_http_status 404 "local /openapi.json is disabled" \
  "http://127.0.0.1:${AICHAT_RELAY_PORT}/openapi.json"

expect_http_status 422 "invalid local registration probe cannot write an Agent" \
  -H 'Content-Type: application/json' \
  -d '{}' \
  "http://127.0.0.1:${AICHAT_RELAY_PORT}/v1/agents/register"

if [[ -n "${AICHAT_CHECK_TOKEN:-}" ]]; then
  expect_http_status 422 "invalid authenticated local channel-create probe cannot write a channel" \
    -H "Authorization: Bearer $AICHAT_CHECK_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "http://127.0.0.1:${AICHAT_RELAY_PORT}/v1/channels"
  expect_http_status 403 "application lockdown denies non-mutating authenticated channel join" \
    -H "Authorization: Bearer $AICHAT_CHECK_TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "http://127.0.0.1:${AICHAT_RELAY_PORT}/v1/channels/aichat-check-nonexistent/join"
else
  expect_http_status 401 "unauthenticated nonexistent channel join reaches the auth gate" \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "http://127.0.0.1:${AICHAT_RELAY_PORT}/v1/channels/aichat-check-nonexistent/join"
  info "the non-mutating application channel-join feature-gate 403 check requires AICHAT_CHECK_TOKEN"
fi

if [[ "$AICHAT_PUBLIC_PROVISIONING" == false ]]; then
  provisioning_paths=(
    v1/agents/register
    v1/channels
    v1/channels/nonexistent-channel/join
  )
  provisioning_bodies=(
    '{}'
    '{}'
    '{}'
  )
  provisioning_auth_names=(missing invalid)
  provisioning_auth_headers=("" "Authorization: Bearer aichat-invalid-acceptance-token")
  if [[ -n "${AICHAT_CHECK_TOKEN:-}" ]]; then
    provisioning_auth_names+=(valid)
    provisioning_auth_headers+=("Authorization: Bearer $AICHAT_CHECK_TOKEN")
  else
    info "valid-token edge provisioning probes require AICHAT_CHECK_TOKEN"
  fi

  for auth_index in "${!provisioning_auth_names[@]}"; do
    for path_index in "${!provisioning_paths[@]}"; do
      curl_arguments=(
        -H 'Content-Type: application/json'
        -d "${provisioning_bodies[$path_index]}"
      )
      if [[ -n "${provisioning_auth_headers[$auth_index]}" ]]; then
        curl_arguments+=(-H "${provisioning_auth_headers[$auth_index]}")
      fi
      expect_edge_http_status 403 \
        "edge denies ${provisioning_auth_names[$auth_index]}-token POST /${provisioning_paths[$path_index]}" \
        "${curl_arguments[@]}" \
        "$AICHAT_PUBLIC_BASE_URL/${provisioning_paths[$path_index]}?aichat_edge_probe=${provisioning_auth_names[$auth_index]}"
    done
  done

  for path in "${provisioning_paths[@]}"; do
    expect_not_edge_denied "GET /$path is outside the POST-only provisioning gate" \
      "$AICHAT_PUBLIC_BASE_URL/$path?aichat_edge_probe=get"
  done
else
  info "public provisioning is explicitly enabled; no mutating provisioning probe was sent"
fi

if "$AICHAT_CADDY_BINARY" validate --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile >/dev/null; then
  pass "Caddy configuration validates"
else
  fail "Caddy configuration validation"
fi
adapted_caddy="$(mktemp)"
if "$AICHAT_CADDY_BINARY" adapt --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile >"$adapted_caddy" &&
  /opt/aichat-relay/current/venv/bin/python "$SCRIPT_DIR/validate-caddy-route.py" \
    --adapted-json "$adapted_caddy" \
    --path-prefix "$AICHAT_PATH_PREFIX" \
    --relay-dial "127.0.0.1:${AICHAT_RELAY_PORT}" \
    --fallback-dial "${AICHAT_CADDY_FALLBACK#reverse_proxy }" \
    --public-provisioning "$AICHAT_PUBLIC_PROVISIONING"; then
  pass "adapted Caddy route/logging has AIChat log_skip and error-log token redaction"
else
  fail "adapted Caddy route ordering, log safety, or policy"
fi
rm -f "$adapted_caddy"
if grep -Fq '# BEGIN AICHAT RELAY (managed by AIChat deploy package)' "$AICHAT_CADDY_CONFIG"; then
  pass "managed AIChat Caddy route is present"
else
  fail "managed AIChat Caddy route is absent"
fi
if grep -Fq '# BEGIN AICHAT ERROR LOGGER REDACTION (managed by AIChat deploy package)' \
  "$AICHAT_CADDY_CONFIG"; then
  pass "managed scoped Caddy error-logger redaction is present"
else
  fail "managed scoped Caddy error-logger redaction is absent"
fi
if grep -Eq '^[[:space:]]*log([[:space:]]|$)' "$AICHAT_CADDY_CONFIG"; then
  info "existing Caddy access logging remains enabled outside the AIChat prefix"
else
  info "Caddy access logging is not enabled for this site"
fi

if grep -REn '21115|21116|21117|21118|21119' \
  /etc/systemd/system/aichat-relay.service \
  /etc/systemd/system/aichat-relay-backup.service \
  /etc/systemd/system/aichat-relay-backup.timer \
  /etc/aichat-relay/caddy-route.caddy \
  /etc/aichat-relay/caddy-global-options.caddy >/dev/null; then
  fail "AIChat installed configuration references a protected RustDesk port"
else
  pass "AIChat configuration does not reference RustDesk ports 21115-21119"
fi
rustdesk_listeners="$(ss -H -lntup | grep -E ':(21115|21116|21117|21118|21119)([[:space:]]|$)' || true)"
if [[ -n "$rustdesk_listeners" ]]; then
  info "RustDesk listeners remain present (informational, not modified):"
  printf '%s\n' "$rustdesk_listeners"
else
  info "no RustDesk listener was visible; investigate separately without changing AIChat"
fi

if runuser -u aichat-relay -- /opt/aichat-relay/current/venv/bin/python - "$AICHAT_DB_PATH" <<'PY'
import sqlite3
import sys
from pathlib import Path

database = Path(sys.argv[1])
if not database.is_file():
    raise SystemExit(1)
# The Relay account owns the database directory. A normal connection is needed
# so SQLite can participate in WAL shared-memory coordination across versions.
connection = sqlite3.connect(database, timeout=30)
try:
    result = connection.execute("PRAGMA quick_check").fetchone()
finally:
    connection.close()
raise SystemExit(0 if result and result[0] == "ok" else 1)
PY
then
  pass "SQLite quick_check"
else
  fail "SQLite quick_check"
fi

latest_checksum="$(find "$AICHAT_BACKUP_DIR" -maxdepth 1 -type f -name 'relay-*.sqlite3.gz.sha256' -print | sort | tail -1)"
if [[ -n "$latest_checksum" ]] && (cd "$AICHAT_BACKUP_DIR" && sha256sum --check "$(basename "$latest_checksum")" >/dev/null); then
  pass "latest backup checksum"
else
  fail "no verifiable Relay backup was found"
fi

if [[ -n "${AICHAT_CHECK_TOKEN:-}" ]]; then
  if AICHAT_CHECK_TOKEN="$AICHAT_CHECK_TOKEN" AICHAT_PUBLIC_BASE_URL="$AICHAT_PUBLIC_BASE_URL" \
    /opt/aichat-relay/current/venv/bin/python "$SCRIPT_DIR/check-websocket.py"; then
    pass "public WSS handshake"
  else
    fail "public WSS handshake"
  fi
else
  info "WSS handshake skipped; set AICHAT_CHECK_TOKEN in the process environment to test it"
fi

if ((failures > 0)); then
  printf 'AIChat deployment checks failed: %d\n' "$failures" >&2
  exit 1
fi
printf 'AIChat deployment checks passed.\n'

#!/usr/bin/env bash

set -Eeuo pipefail

scenario="${1:?scenario is required}"
repo_root="${2:-/workspace}"
[[ "${AICHAT_DISPOSABLE_CONTAINER_TEST:-}" == true && -f /.dockerenv ]] || {
  printf 'ERROR: this test mutates /opt and /etc and must run only in its disposable container\n' >&2
  exit 2
}

case "$scenario" in
  first-success) install_kind=first; fail_stage=none; expected=success ;;
  first-public-retry-success) install_kind=first; fail_stage=public-retry; expected=success ;;
  first-public-fail) install_kind=first; fail_stage=public-health; expected=failure ;;
  upgrade-success) install_kind=upgrade; fail_stage=none; expected=success ;;
  first-local-fail) install_kind=first; fail_stage=local-health; expected=failure ;;
  upgrade-daemon-fail) install_kind=upgrade; fail_stage=daemon-reload; expected=failure ;;
  upgrade-local-fail) install_kind=upgrade; fail_stage=local-health; expected=failure ;;
  upgrade-caddy-fail) install_kind=upgrade; fail_stage=caddy-reload; expected=failure ;;
  upgrade-public-retry-success) install_kind=upgrade; fail_stage=public-retry; expected=success ;;
  upgrade-public-fail) install_kind=upgrade; fail_stage=public-health; expected=failure ;;
  upgrade-public-network-fail) install_kind=upgrade; fail_stage=public-network; expected=failure ;;
  upgrade-backup-fail) install_kind=upgrade; fail_stage=backup; expected=failure ;;
  upgrade-previous-fail) install_kind=upgrade; fail_stage=previous-update; expected=failure ;;
  upgrade-rollback-incomplete) install_kind=upgrade; fail_stage=rollback-incomplete; expected=incomplete ;;
  *) printf 'ERROR: unknown scenario: %s\n' "$scenario" >&2; exit 2 ;;
esac

readonly mock_bin=/mockbin
readonly mock_state=/mock-state
readonly fixture=/fixture
readonly app_root=/opt/aichat-relay
readonly releases_dir=${app_root}/releases
readonly current_link=${app_root}/current
readonly previous_link=${app_root}/previous
readonly old_current=${releases_dir}/old-current
readonly old_previous=${releases_dir}/old-previous
readonly new_release=${releases_dir}/mock-new
readonly caddy_config=${fixture}/Caddyfile
readonly config=${fixture}/deploy.env
readonly output=${fixture}/install.output

mkdir -p "$mock_bin" "$mock_state" "$fixture" "$releases_dir"

write_state() {
  printf '%s\n' "$2" >"${mock_state}/$1"
}

read_state() {
  if [[ -f "${mock_state}/$1" ]]; then
    cat "${mock_state}/$1"
  else
    printf 'false\n'
  fi
}

assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'ASSERTION FAILED: expected %s, found %s\n' "$2" "$1" >&2
    printf '%s\n' '--- installer output ---' >&2
    cat "$output" >&2 || true
    exit 1
  fi
}

assert_file_text() {
  [[ -f "$1" ]] || {
    printf 'ASSERTION FAILED: missing file %s\n' "$1" >&2
    exit 1
  }
  assert_eq "$(cat "$1")" "$2"
}

cat >"${mock_bin}/python3" <<'SH'
#!/bin/sh
set -eu
if [ "${1:-}" = -m ] && [ "${2:-}" = venv ]; then
  target="$3"
  mkdir -p "$target/bin"
  cat >"$target/bin/python" <<'PY'
#!/bin/sh
set -eu
if [ "${1:-}" = -m ] && [ "${2:-}" = pip ]; then
  exit 0
fi
if [ "${1:-}" = -c ]; then
  exit 0
fi
exec /usr/local/bin/python3 "$@"
PY
  cat >"$target/bin/uvicorn" <<'UV'
#!/bin/sh
exit 0
UV
  chmod 0755 "$target/bin/python" "$target/bin/uvicorn"
  exit 0
fi
exec /usr/local/bin/python3 "$@"
SH

cat >"${mock_bin}/git" <<'SH'
#!/bin/sh
if [ "${1:-}" = -C ] && [ "${3:-}" = rev-parse ]; then
  printf 'mock-revision\n'
  exit 0
fi
exit 1
SH

cat >"${mock_bin}/sleep" <<'SH'
#!/bin/sh
set -eu
printf '%s\n' "${1:-missing}" >>/mock-state/sleep_arguments
SH

cat >"${mock_bin}/curl" <<'SH'
#!/bin/sh
set -eu
first_argument="${1:-}"
previous_argument=""
retry_count=0
retry_value=""
url=""
for argument in "$@"; do
  if [ "$previous_argument" = --retry ]; then
    retry_value="$argument"
  fi
  if [ "$argument" = --retry ]; then
    retry_count=$((retry_count + 1))
  fi
  case "$argument" in
    http://*|https://*) url="$argument" ;;
  esac
  previous_argument="$argument"
done
case "$url" in
  http://127.0.0.1:*)
    target="$(readlink /opt/aichat-relay/current 2>/dev/null || true)"
    case "$target" in
      */old-current)
        count=0
        [ -f /mock-state/old_service_health_count ] &&
          count="$(cat /mock-state/old_service_health_count)"
        count=$((count + 1))
        printf '%s\n' "$count" >/mock-state/old_service_health_count
        ;;
    esac
    if [ "${FAIL_STAGE:-}" = local-health ]; then
      case "$target" in
        */mock-new) exit 1 ;;
      esac
    fi
    exit 0
    ;;
  https://*)
    [ "$first_argument" = --disable ] || exit 91
    [ "$retry_count" -eq 1 ] || exit 92
    [ "$retry_value" = 0 ] || exit 93
    printf '%s\n' "$*" >>/mock-state/public_curl_arguments
    count=0
    [ -f /mock-state/public_health_count ] &&
      count="$(cat /mock-state/public_health_count)"
    count=$((count + 1))
    printf '%s\n' "$count" >/mock-state/public_health_count
    if [ "${FAIL_STAGE:-}" = public-retry ] && [ "$count" -le 3 ]; then
      exit 22
    fi
    if [ "${FAIL_STAGE:-}" = public-health ] ||
      [ "${FAIL_STAGE:-}" = rollback-incomplete ]; then
      exit 22
    fi
    if [ "${FAIL_STAGE:-}" = public-network ]; then
      exit 7
    fi
    exit 0
    ;;
esac
exit 1
SH

cat >"${mock_bin}/systemctl" <<'SH'
#!/bin/sh
set -eu
state=/mock-state
operation="$1"
shift
key_for() {
  case "$1" in
    aichat-relay.service) printf 'service' ;;
    aichat-relay-backup.timer) printf 'timer' ;;
    aichat-relay-backup.service) printf 'backup' ;;
    *) printf 'unknown' ;;
  esac
}
set_value() {
  printf '%s\n' "$3" >"${state}/$1_$2"
}
get_value() {
  if [ -f "${state}/$1_$2" ]; then cat "${state}/$1_$2"; else printf 'false\n'; fi
}
case "$operation" in
  is-active|is-enabled)
    [ "${1:-}" = --quiet ] && shift
    key="$(key_for "$1")"
    property=active
    [ "$operation" = is-enabled ] && property=enabled
    [ "$(get_value "$key" "$property")" = true ]
    ;;
  daemon-reload)
    count=0
    [ -f "${state}/daemon_count" ] && count="$(cat "${state}/daemon_count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"${state}/daemon_count"
    if [ "${FAIL_STAGE:-}" = daemon-reload ] && [ "$count" -eq 1 ]; then exit 1; fi
    if [ "${FAIL_STAGE:-}" = rollback-incomplete ] && [ "$count" -eq 2 ]; then exit 1; fi
    ;;
  enable|disable)
    value=true
    [ "$operation" = disable ] && value=false
    now=false
    for unit in "$@"; do
      if [ "$unit" = --now ]; then now=true; continue; fi
      key="$(key_for "$unit")"
      set_value "$key" enabled "$value"
      if [ "$now" = true ]; then set_value "$key" active true; fi
    done
    ;;
  restart)
    key="$(key_for "$1")"
    set_value "$key" active true
    ;;
  stop)
    key="$(key_for "$1")"
    set_value "$key" active false
    ;;
  start)
    key="$(key_for "$1")"
    if [ "$key" = backup ] && [ "${FAIL_STAGE:-}" = backup ] &&
      [ ! -f "${state}/backup_failed" ]; then
      : >"${state}/backup_failed"
      exit 1
    fi
    set_value "$key" active true
    ;;
  *) printf 'unsupported mock systemctl operation: %s\n' "$operation" >&2; exit 1 ;;
esac
SH

cat >"${mock_bin}/caddy" <<'SH'
#!/bin/sh
set -eu
state=/mock-state
operation="$1"
case "$operation" in
  adapt)
    count=0
    [ -f "${state}/caddy_adapt_count" ] && count="$(cat "${state}/caddy_adapt_count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"${state}/caddy_adapt_count"
    cat /fixture/adapted.json
    ;;
  validate)
    exit 0
    ;;
  reload)
    count=0
    [ -f "${state}/caddy_reload_count" ] && count="$(cat "${state}/caddy_reload_count")"
    count=$((count + 1))
    printf '%s\n' "$count" >"${state}/caddy_reload_count"
    if [ "${FAIL_STAGE:-}" = caddy-reload ] && [ "$count" -eq 1 ]; then exit 1; fi
    ;;
  *) exit 1 ;;
esac
SH

cat >"${mock_bin}/mv" <<'SH'
#!/bin/sh
set -eu
destination=""
for argument in "$@"; do destination="$argument"; done
if [ "${FAIL_STAGE:-}" = previous-update ] &&
  [ "$destination" = /opt/aichat-relay/previous ] &&
  [ ! -f /mock-state/previous_failed ]; then
  : >/mock-state/previous_failed
  exit 1
fi
exec /usr/bin/mv "$@"
SH

chmod 0755 "${mock_bin}"/*

/usr/local/bin/python3 - "$repo_root" "$fixture/adapted.json" <<'PY'
import importlib.util
import json
import pathlib
import sys

test_path = pathlib.Path(sys.argv[1]) / "deploy/raspberry-pi/tests/test_package.py"
spec = importlib.util.spec_from_file_location("aichat_pi_test_package", test_path)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
document = module.valid_adapted_document()
pathlib.Path(sys.argv[2]).write_text(json.dumps(document))
PY

cat >"$caddy_config" <<'EOF'
example.test {
    reverse_proxy 127.0.0.1:17300
}
EOF
chmod 0640 "$caddy_config"
cp -a "$caddy_config" "${fixture}/Caddyfile.initial"

cat >"$config" <<EOF
AICHAT_SOURCE_ROOT=${repo_root}
AICHAT_RELEASE_ID=mock-new
AICHAT_RELAY_PORT=8787
AICHAT_DB_PATH=/var/lib/aichat-relay/relay.db
AICHAT_BACKUP_DIR=/var/backups/aichat-relay
AICHAT_BACKUP_RETENTION_DAYS=14
AICHAT_PRODUCTION_LOCKDOWN=true
AICHAT_DOCS_ENABLED=false
AICHAT_AGENT_REGISTRATION_ENABLED=false
AICHAT_CHANNEL_CREATE_ENABLED=false
AICHAT_CHANNEL_JOIN_ENABLED=false
AICHAT_HTTP_RATE_LIMIT_PER_MINUTE=120
AICHAT_WS_HANDSHAKE_RATE_LIMIT_PER_MINUTE=30
AICHAT_WS_MAX_CONNECTIONS=128
AICHAT_WS_MAX_CONNECTIONS_PER_AGENT=4
AICHAT_TRUSTED_PROXY_CIDRS=127.0.0.0/8,::1/128
AICHAT_REQUIRE_SEED_DB=false
AICHAT_SEED_DB=
AICHAT_DOMAIN=example.test
AICHAT_PATH_PREFIX=/aichat
AICHAT_PUBLIC_BASE_URL=https://example.test/aichat
AICHAT_PUBLIC_PROVISIONING=false
AICHAT_CADDY_BINARY=${mock_bin}/caddy
AICHAT_CADDY_CONFIG=${caddy_config}
AICHAT_CADDY_SERVICE=mock-caddy.service
AICHAT_CADDY_FALLBACK="reverse_proxy 127.0.0.1:17300"
AICHAT_PYTHON=${mock_bin}/python3
EOF

if [[ "$install_kind" == upgrade ]]; then
  mkdir -p "$old_current/server" "$old_current/venv/bin" "$old_previous/server"
  ln -s "$old_current" "$current_link"
  ln -s "$old_previous" "$previous_link"
  mkdir -p /etc/aichat-relay /usr/local/libexec/aichat-relay /etc/systemd/system
  printf 'AICHAT_RELAY_PORT=8777\nOLD_ENV=1\n' >/etc/aichat-relay/relay.env
  printf 'old route\n' >/etc/aichat-relay/caddy-route.caddy
  printf 'old globals\n' >/etc/aichat-relay/caddy-global-options.caddy
  for name in backup.sh backup.py patch-caddy.py seed-database.py validate-caddy-route.py; do
    printf 'old %s\n' "$name" >"/usr/local/libexec/aichat-relay/$name"
  done
  printf 'old relay unit\n' >/etc/systemd/system/aichat-relay.service
  printf 'old backup unit\n' >/etc/systemd/system/aichat-relay-backup.service
  printf 'old timer unit\n' >/etc/systemd/system/aichat-relay-backup.timer
  write_state service_active true
  write_state service_enabled false
  write_state timer_active false
  write_state timer_enabled true
else
  write_state service_active false
  write_state service_enabled false
  write_state timer_active false
  write_state timer_enabled false
fi

set +e
installer=("$repo_root/deploy/raspberry-pi/scripts/install.sh" "$config")
if [[ "${AICHAT_MOCK_INSTALL_TRACE:-}" == true ]]; then
  installer=(bash -x "${installer[@]}")
fi
PATH="${mock_bin}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  FAIL_STAGE="$fail_stage" \
  "${installer[@]}" >"$output" 2>&1
installer_status=$?
set -e

if [[ "$expected" == success ]]; then
  assert_eq "$installer_status" 0
  assert_eq "$(readlink "$current_link")" "$new_release"
  if [[ "$install_kind" == upgrade ]]; then
    assert_eq "$(readlink "$previous_link")" "$old_current"
  else
    [[ ! -e "$previous_link" && ! -L "$previous_link" ]] || {
      printf 'ASSERTION FAILED: first install unexpectedly created previous\n' >&2
      exit 1
    }
  fi
  assert_eq "$(read_state service_active)" true
  assert_eq "$(read_state service_enabled)" true
  assert_eq "$(read_state timer_active)" true
  assert_eq "$(read_state timer_enabled)" true
  grep -q '^AICHAT_RELAY_PORT=8787$' /etc/aichat-relay/relay.env
  if [[ "$fail_stage" == public-retry ]]; then
    assert_file_text "${mock_state}/public_health_count" 4
    assert_eq "$(wc -l <"${mock_state}/sleep_arguments" | tr -d ' ')" 3
    [[ "$(sort -u "${mock_state}/sleep_arguments")" == 10 ]] || {
      printf 'ASSERTION FAILED: public health retry did not use 10-second sleeps\n' >&2
      exit 1
    }
    assert_file_text "${mock_state}/caddy_reload_count" 1
    [[ "$(grep -c '^--disable ' "${mock_state}/public_curl_arguments")" -eq 4 ]] || {
      printf 'ASSERTION FAILED: public curl did not disable curlrc first on every attempt\n' >&2
      exit 1
    }
    [[ "$(grep -c -- '--retry 0' "${mock_state}/public_curl_arguments")" -eq 4 ]] || {
      printf 'ASSERTION FAILED: public curl did not force retry 0 on every attempt\n' >&2
      exit 1
    }
    grep -q 'public HTTPS health accepted on attempt 4/5' "$output"
  fi
else
  [[ "$installer_status" -ne 0 ]] || {
    printf 'ASSERTION FAILED: failure scenario returned success\n' >&2
    exit 1
  }
  cmp -s "$caddy_config" "${fixture}/Caddyfile.initial" || {
    printf 'ASSERTION FAILED: Caddyfile was not restored\n' >&2
    exit 1
  }
  if [[ "$install_kind" == upgrade ]]; then
    assert_eq "$(readlink "$current_link")" "$old_current"
    assert_eq "$(readlink "$previous_link")" "$old_previous"
    assert_file_text /etc/aichat-relay/relay.env $'AICHAT_RELAY_PORT=8777\nOLD_ENV=1'
    assert_file_text /etc/systemd/system/aichat-relay.service 'old relay unit'
    assert_file_text /etc/systemd/system/aichat-relay-backup.service 'old backup unit'
    assert_file_text /etc/systemd/system/aichat-relay-backup.timer 'old timer unit'
    assert_eq "$(read_state service_active)" true
    assert_eq "$(read_state service_enabled)" false
    assert_eq "$(read_state timer_active)" false
    assert_eq "$(read_state timer_enabled)" true
  else
    [[ ! -e "$current_link" && ! -L "$current_link" ]] || {
      printf 'ASSERTION FAILED: failed first install retained current link\n' >&2
      exit 1
    }
    [[ ! -e "$previous_link" && ! -L "$previous_link" ]] || {
      printf 'ASSERTION FAILED: failed first install created previous link\n' >&2
      exit 1
    }
    for path in \
      /etc/aichat-relay/relay.env \
      /etc/aichat-relay/caddy-route.caddy \
      /etc/aichat-relay/caddy-global-options.caddy \
      /usr/local/libexec/aichat-relay/backup.sh \
      /usr/local/libexec/aichat-relay/backup.py \
      /usr/local/libexec/aichat-relay/patch-caddy.py \
      /usr/local/libexec/aichat-relay/seed-database.py \
      /usr/local/libexec/aichat-relay/validate-caddy-route.py \
      /etc/systemd/system/aichat-relay.service \
      /etc/systemd/system/aichat-relay-backup.service \
      /etc/systemd/system/aichat-relay-backup.timer; do
      [[ ! -e "$path" && ! -L "$path" ]] || {
        printf 'ASSERTION FAILED: failed first install retained %s\n' "$path" >&2
        exit 1
      }
    done
    assert_eq "$(read_state service_active)" false
    assert_eq "$(read_state service_enabled)" false
    assert_eq "$(read_state timer_active)" false
    assert_eq "$(read_state timer_enabled)" false
  fi

  if [[ "$fail_stage" == public-health || "$fail_stage" == public-network ]]; then
    assert_file_text "${mock_state}/public_health_count" 5
    assert_eq "$(wc -l <"${mock_state}/sleep_arguments" | tr -d ' ')" 4
    [[ "$(sort -u "${mock_state}/sleep_arguments")" == 10 ]] || {
      printf 'ASSERTION FAILED: failed public health retry did not use 10-second sleeps\n' >&2
      exit 1
    }
    assert_file_text "${mock_state}/caddy_reload_count" 2
    [[ "$(grep -c '^--disable ' "${mock_state}/public_curl_arguments")" -eq 5 ]] || {
      printf 'ASSERTION FAILED: failed public curl did not disable curlrc first on every attempt\n' >&2
      exit 1
    }
    [[ "$(grep -c -- '--retry 0' "${mock_state}/public_curl_arguments")" -eq 5 ]] || {
      printf 'ASSERTION FAILED: failed public curl did not force retry 0 on every attempt\n' >&2
      exit 1
    }
    if [[ "$install_kind" == upgrade ]]; then
      assert_file_text "${mock_state}/old_service_health_count" 1
    else
      [[ ! -e "${mock_state}/old_service_health_count" ]] || {
        printf 'ASSERTION FAILED: first-install rollback unexpectedly started an old Relay\n' >&2
        exit 1
      }
    fi
    grep -q 'public HTTPS health failed after 5 attempts' "$output"
  fi
fi

if [[ "$expected" == incomplete ]]; then
  grep -q 'rollback was incomplete' "$output"
  snapshot="$(sed -n 's/^ERROR: preserving transaction snapshot for manual recovery: //p' "$output" | tail -n 1)"
  [[ -n "$snapshot" && -d "$snapshot" ]] || {
    printf 'ASSERTION FAILED: incomplete rollback did not preserve its snapshot\n' >&2
    cat "$output" >&2
    exit 1
  }
elif [[ "$expected" == failure ]]; then
  grep -Eq 'were rolled back|unexpected installer failure was rolled back' "$output"
  if grep -q 'rollback was incomplete' "$output"; then
    printf 'ASSERTION FAILED: rollback was unexpectedly incomplete\n' >&2
    cat "$output" >&2
    exit 1
  fi
fi

printf 'PASS %s\n' "$scenario"

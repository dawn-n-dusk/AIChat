#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

load_deploy_config "${1:-}"
require_root
target_name="${2:-previous}"
caddy_backup="${3:-}"

readonly APP_ROOT=/opt/aichat-relay
readonly RELEASES_DIR=${APP_ROOT}/releases
readonly CURRENT_LINK=${APP_ROOT}/current
readonly PREVIOUS_LINK=${APP_ROOT}/previous

if [[ "$target_name" == previous ]]; then
  target="$(readlink -f "$PREVIOUS_LINK" 2>/dev/null || true)"
else
  [[ "$target_name" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release name"
  target="${RELEASES_DIR}/${target_name}"
fi
[[ -d "$target/server/app" && -x "$target/venv/bin/uvicorn" ]] ||
  die "rollback target is not a valid installed release: ${target:-missing}"
[[ "$target" == "$RELEASES_DIR"/* ]] || die "rollback target escaped the release directory"

current="$(readlink -f "$CURRENT_LINK" 2>/dev/null || true)"
[[ -n "$current" && -d "$current" ]] || die "current release link is invalid"

note "switching current release to $target"
atomic_symlink "$target" "$CURRENT_LINK"
if ! systemctl restart aichat-relay.service || ! wait_for_local_health 30; then
  atomic_symlink "$current" "$CURRENT_LINK"
  systemctl restart aichat-relay.service || true
  die "target release failed local health; original release was restored"
fi
atomic_symlink "$current" "$PREVIOUS_LINK"

if [[ -n "$caddy_backup" ]]; then
  require_absolute_path CADDY_BACKUP "$caddy_backup"
  [[ -f "$caddy_backup" ]] || die "Caddy backup does not exist: $caddy_backup"
  if ! "$AICHAT_CADDY_BINARY" validate --config "$caddy_backup" --adapter caddyfile; then
    die "requested Caddy backup does not validate"
  fi
  safety_backup="${AICHAT_CADDY_CONFIG}.before-rollback-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -a "$AICHAT_CADDY_CONFIG" "$safety_backup"
  cp -a "$caddy_backup" "$AICHAT_CADDY_CONFIG"
  if ! "$AICHAT_CADDY_BINARY" validate --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile ||
    ! "$AICHAT_CADDY_BINARY" reload --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile; then
    cp -a "$safety_backup" "$AICHAT_CADDY_CONFIG"
    "$AICHAT_CADDY_BINARY" reload --config "$AICHAT_CADDY_CONFIG" --adapter caddyfile || true
    atomic_symlink "$current" "$CURRENT_LINK"
    systemctl restart aichat-relay.service || true
    die "Caddy rollback failed; original Caddyfile and Relay release were restored"
  fi
fi

if ! curl --fail --silent --show-error --max-time 15 "$AICHAT_PUBLIC_BASE_URL/health" >/dev/null; then
  printf 'WARNING: local rollback is healthy but the public path check failed.\n' >&2
  exit 2
fi

printf 'Rollback accepted: %s\n' "$target"
printf 'The SQLite database was not replaced. Restore a database backup only as a separate, explicit maintenance action.\n'
printf 'RustDesk ports 21115-21119 and firewall policy were not modified.\n'

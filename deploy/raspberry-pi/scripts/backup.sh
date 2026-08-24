#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly ENV_FILE="${1:-/etc/aichat-relay/relay.env}"
[[ -r "$ENV_FILE" ]] || {
  printf 'AIChat backup environment is not readable: %s\n' "$ENV_FILE" >&2
  exit 1
}

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${AICHAT_DB_PATH:?AICHAT_DB_PATH is required}"
: "${AICHAT_BACKUP_DIR:?AICHAT_BACKUP_DIR is required}"
: "${AICHAT_BACKUP_RETENTION_DAYS:?AICHAT_BACKUP_RETENTION_DAYS is required}"
readonly PYTHON_BIN="${AICHAT_PYTHON_BIN:-/opt/aichat-relay/current/venv/bin/python}"

exec "$PYTHON_BIN" /usr/local/libexec/aichat-relay/backup.py \
  --database "$AICHAT_DB_PATH" \
  --output-dir "$AICHAT_BACKUP_DIR" \
  --retention-days "$AICHAT_BACKUP_RETENTION_DAYS"

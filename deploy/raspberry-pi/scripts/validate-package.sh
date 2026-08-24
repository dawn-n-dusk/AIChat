#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

for script in "$SCRIPT_DIR"/*.sh; do
  bash -n "$script"
done
for script in "$SCRIPT_DIR"/*.py; do
  python3 -m py_compile "$script"
done
python3 -m unittest discover -s "$DEPLOY_ROOT/tests" -p 'test_*.py' -v

if command -v caddy >/dev/null 2>&1; then
  printf 'Caddy binary found; production install/check scripts perform full validate+adapt acceptance.\n'
elif command -v docker >/dev/null 2>&1 && docker image inspect caddy:2.10.2 >/dev/null 2>&1; then
  printf 'Cached Caddy 2.10.2 image found; use it for an optional fixture adapt review.\n'
else
  printf 'Caddy executable not present locally; syntax/adapt is fail-closed on the target host before reload.\n'
fi

printf 'Raspberry Pi deployment package validation passed. No host was contacted.\n'

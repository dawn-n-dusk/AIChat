#!/usr/bin/env bash

set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TEST_DIR
REPO_ROOT="$(cd "${TEST_DIR}/../../.." && pwd)"
readonly REPO_ROOT
readonly IMAGE="${AICHAT_INSTALL_TEST_IMAGE:-python:3.13-slim}"
readonly -a SCENARIOS=(
  first-success
  upgrade-success
  first-local-fail
  upgrade-daemon-fail
  upgrade-local-fail
  upgrade-caddy-fail
  upgrade-public-fail
  upgrade-backup-fail
  upgrade-previous-fail
  upgrade-rollback-incomplete
)

command -v docker >/dev/null 2>&1 || {
  printf 'ERROR: docker is required for the disposable installer integration tests\n' >&2
  exit 1
}

for scenario in "${SCENARIOS[@]}"; do
  docker run --rm \
    -e AICHAT_DISPOSABLE_CONTAINER_TEST=true \
    -v "${REPO_ROOT}:/workspace:ro" \
    "$IMAGE" \
    bash /workspace/deploy/raspberry-pi/tests/mock-install-scenario.sh \
    "$scenario" /workspace
done

printf 'Raspberry Pi mocked installer integration tests passed: %s scenarios.\n' \
  "${#SCENARIOS[@]}"

#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/aichat-smoke.XXXXXX")"

cleanup() {
  rm -rf -- "$temporary_root"
}
trap cleanup EXIT

python_executable="${AICHAT_TEST_PYTHON:-python3.11}"
if ! command -v "$python_executable" >/dev/null 2>&1; then
  echo "error: Python 3.11+ is required (set AICHAT_TEST_PYTHON to its executable)" >&2
  exit 1
fi

if ! "$python_executable" -c 'import sys; raise SystemExit(sys.version_info < (3, 11))'; then
  echo "error: $python_executable must be Python 3.11 or newer" >&2
  exit 1
fi

"$python_executable" -m venv "$temporary_root/venv"
venv_python="$temporary_root/venv/bin/python"

PIP_DISABLE_PIP_VERSION_CHECK=1 "$venv_python" -m pip install --quiet \
  -e "$repository_root/server[test]" \
  -e "$repository_root/clients/python[test]"

if [[ "${AICHAT_RUN_ALL_TESTS:-0}" == "1" ]]; then
  "$venv_python" -m pytest \
    "$repository_root/server/tests" \
    "$repository_root/clients/python/tests"
fi

PATH="$temporary_root/venv/bin:$PATH" \
  "$venv_python" -m pytest -q -s "$repository_root/tests/e2e/test_real_relay.py"

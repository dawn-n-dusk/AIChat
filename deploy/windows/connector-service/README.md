# Windows Codex Connector service

This directory contains the hardened, default-disabled Windows Scheduled Task
package. See [`../README.md`](../README.md#disabled-codex-connector-service-package)
for preparation, install, check, rollback, uninstall, security boundaries, and
the supervised synthetic E2E gate.

The task is always installed as `\AIChat\CodexConnector`, disabled, without
triggers, and is never started by these scripts. Automatic result return is
also disabled in the example and requires the explicit fail-closed opt-in
documented in the parent README. Ordinary lifecycle status remains disabled
with compatible core; a permanent egress quarantine may emit one fixed,
redacted terminal `blocked` status.

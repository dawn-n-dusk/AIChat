# Windows Codex Connector service

This directory contains the hardened, default-disabled Windows Scheduled Task
package. See [`../README.md`](../README.md#disabled-codex-connector-service-package)
for preparation, install, check, rollback, uninstall, security boundaries, and
the supervised synthetic E2E gate.

In normal install mode, the task is installed as `\AIChat\CodexConnector`,
disabled, without triggers, and is never started by these scripts. Automatic
result return is also disabled in the example and requires the explicit
fail-closed opt-in documented in the parent README. Ordinary lifecycle status
remains disabled with compatible core; a permanent egress quarantine may emit
one fixed, redacted terminal `blocked` status.

For supervised foreground acceptance without any Task Scheduler access, the
installer, checker, and rollback entrypoints also accept `-StageOnly`. This
mode installs the runtime/settings/mapping/ACL package only, records
`task.mode=untouched` in its protected transaction, and leaves every existing
Scheduled Task object unchanged. See the parent README for the exact commands
and rollback boundary.

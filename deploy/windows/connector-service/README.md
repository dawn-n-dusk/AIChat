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

`recover-transaction.ps1` is the explicit fail-closed recovery path for a
protected `rollback_incomplete` journal. Verification is read-only; finalizing
requires `-Finalize -Apply` and archives the exact journal only after files,
connector-data ACLs, release placement, and staging absence all match the
prior-state snapshot. Schema-v3 managed journals require exact task XML;
schema-v4 stage-only journals require the exact `task.mode=untouched` shape and
never invoke Task Scheduler during either verification pass. It never performs
a Task Scheduler write.

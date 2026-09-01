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

`check.ps1 -StageOnly -RecoveryGateOnly` is the narrow read-only admission
gate for this flow. It checks the protected fixed state root and unfinished
transaction marker, exits before ConnectorData, settings, launcher,
credentials, or Task Scheduler checks, and reports no mutation. It does not
replace the full StageOnly package check.

`diagnose-recovery-protected-paths.ps1` is a separate, read-only diagnostic
for a recovery result whose `diagnostic_code` is `protected_paths_invalid`.
Run it directly with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File .\diagnose-recovery-protected-paths.ps1
```

It emits exactly one compact ASCII JSON object under contract version 1. The
fixed `level` values are `-1` for the unmanaged ancestor chain, `0` for the
LocalAppData `AIChat` protected root, and `1` for its fixed
`codex-connector-task` state root. The matching `layer` enum is included so a
wrapper never has to infer the meaning of the integer. `exact` and `mismatch`
are successful diagnoses and exit 0; `indeterminate` reports `status=blocked`
and exits 1. Reasons are fixed allowlisted enums only.

The diagnostic never returns a path, SID, SDDL, ACL/ACE data, credential,
token, or raw exception. It does not read the recovery journal, ConnectorData,
or identity configuration; access Task Scheduler or connector processes; or
change ACLs or files. It is intentionally outside the recovery JSON target and
runner contracts and cannot repair, finalize, retry, or otherwise advance a
recovery operation.

The default output remains the existing Human key/value stream. Automation
must invoke `invoke-recovery-json.ps1` with exactly one operation: `verify`,
`repair`, or `finalize`. The runner owns the Windows PowerShell 5.1 subprocess,
places the target script before its `-OutputFormat Json` argument, captures
stdout and stderr separately, and forwards only a fully validated contract
version 2 response. Failure responses add one fixed `diagnostic_code` that
identifies the failed read-only or mutation stage without reproducing paths,
ACL text, or exception messages. It accepts no arbitrary target arguments and never chains
one recovery operation into another.

Validated target responses remain exactly one compact ASCII-safe JSON object.
Pre-contract launch, parser, parameter-binding, stderr, timeout, malformed
output, field, enum, or exit-code failures are replaced by a fixed runner
failure object with no paths, raw exceptions, credential values, SID/SDDL data,
or untrusted text. Runner contract version 2 adds a fixed `rejection_code` for
`target_contract_invalid`, distinguishing only the rejected field-set,
version, type, error/diagnostic, operation/diagnostic, exit, status, or mutation
rule. A verification-stage `protected_paths_invalid` target result is valid
for verify, repair, and finalize and is forwarded without reclassification.
After a repair or finalize target has started, an
unverifiable outcome is conservatively marked `mutation_possible=true`.
`target_termination_failed` prohibits retry until local process state is
independently resolved. See
the parent README for the complete invocation and failure contract.

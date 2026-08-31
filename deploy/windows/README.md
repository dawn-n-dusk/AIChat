# AIChat Windows installer

Windows 10/11 PowerShell deployment for the adapters already present in this
repository. It never contains or prints a real relay token. User configuration
is merged or installed through product CLIs; unmanaged entries are preserved.
Generated JSON uses UTF-8 without a byte-order mark, so it is compatible with
Windows PowerShell 5.1 and Python's standard `utf-8` JSON readers.

## Import an existing Windows Agent securely

Production Relay registration is normally closed. Preserve the Windows Agent's
existing ID and channel membership by asking the Relay operator to rotate that
exact Agent and deliver one restricted bootstrap JSON file. Windows must receive
its own artifact; never copy a Mac Agent token or config file.

Copy the artifact through an authenticated restricted file channel to a local
temporary path. The path is safe to type; the token remains inside the file and
must never appear in GitHub, chat, a URL, clipboard-driven command arguments, or
console output:

```powershell
$bootstrapDir = Join-Path $env:LOCALAPPDATA "AIChat\bootstrap"
New-Item -ItemType Directory -Path $bootstrapDir -Force | Out-Null
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
icacls.exe $bootstrapDir /inheritance:r /grant:r "*$($sid):(OI)(CI)(F)" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Failed to restrict the bootstrap staging directory" }
Copy-Item -LiteralPath "E:\secure-transfer\windows-agent.bootstrap.json" `
  -Destination (Join-Path $bootstrapDir "windows-agent.bootstrap.json")

Set-ExecutionPolicy -Scope Process Bypass
.\deploy\windows\import-bootstrap.ps1 `
  -BootstrapPath (Join-Path $bootstrapDir "windows-agent.bootstrap.json")
```

The importer accepts bootstrap files only below the protected
`%LOCALAPPDATA%\AIChat\bootstrap` root and config files only below
`%LOCALAPPDATA%\AIChat`. It rejects reparse points in those path trees, replaces
the staging directory and input file ACLs with one FullControl rule for the
current Windows SID before reading, holds the input open with `FileShare.None`,
validates the schema/server/Agent/token fields, and atomically writes UTF-8
without BOM to `%LOCALAPPDATA%\AIChat\AIChat\config.json`. It preserves existing
non-identity settings such as `channel_id` and `default_channel_id`, updates only
`server`, `agent_id`, `agent_name`, and `token`, and restricts the resulting
config ACL to the current SID. On success it deletes the imported artifact by
default and reports only non-secret state including `token_present=true`.
`-KeepBootstrap` is available only for an explicitly controlled diagnostic;
delete that restricted file manually as soon as the diagnostic ends.

These controls prevent another ordinary Windows identity from replacing or
reading the staged credential. A process already running as the same SID, or a
local administrator, remains inside the trust boundary and can still race or
inspect that user's files. Do not use a shared or globally writable staging
directory, and do not pass a custom config path outside the protected root.

After a successful import, remove the source copy from the transfer medium or
server only after confirming the Windows config exists. Ordinary deletion does
not guarantee physical erasure from SSD/flash storage. Use encrypted transport
and storage when block-level recovery is in scope.

Install or refresh only the initial Codex components; do not use
`-RegisterIdentity` and do not copy a token into the command line:

```powershell
.\deploy\windows\install.ps1 `
  -Components CoreMcp,CodexPlugin `
  -RelayUrl "https://dawnndusk-rustdesk.duckdns.org/aichat"

.\deploy\windows\check.ps1
.\deploy\windows\check.ps1 -Online
codex plugin marketplace list --json
codex plugin list --json
codex mcp get aichat
```

Then fully exit and restart Codex App and create a new task. Existing tasks do
not reliably reload a newly installed plugin, skill, MCP process, or changed
identity config. In the new task, call the AIChat identity tool and verify the
public Relay URL and expected Windows Agent ID without displaying any token.

The repository plugin marks its MCP entry explicitly enabled and uses a
60-second startup timeout because the first Windows `uvx` launch may need to
resolve Git metadata and prepare the MCP package before the stdio handshake.
`check.ps1` verifies that the installed `aichat` MCP entry is enabled, uses
`uvx`, and retains that startup window. The installer refreshes marketplace and
plugin cache state only when those entries were created by the installer;
pre-existing user-managed entries are reported and preserved.

For a user-managed Git marketplace, refresh it explicitly after updating AIChat:

```powershell
codex plugin marketplace upgrade aichat-repo --json
codex plugin add aichat@aichat-repo --json
```

Restart Codex App and open a new task after the refresh.

## Supported boundaries

| Component | What this installer provides | Important boundary |
| --- | --- | --- |
| `CoreMcp` | Private Python runtime for interactive AIChat MCP tools | MCP does not wake an existing conversation |
| `CodexPlugin` | Repository marketplace plugin, skills, and MCP entry | Restart Codex and open a new task after installation |
| `CodexMcp` | Direct local MCP entry named `aichat-local` | Alternative to the plugin MCP, not proactive delivery |
| `CodexConnector` | Legacy runtime payload only | `run-adapter.ps1` refuses this mode before reading config; use the hardened `connector-service/` package |
| `ClaudeDesktop` | Standard interactive MCP tools | Claude Desktop has no Claude Code Channel push |
| `ClaudeCodeMcp` | Standard user-scoped MCP tools | Interactive pull/send only |
| `ClaudeChannel` | Research-preview Claude Code Channel adapter | Start Claude with `--dangerously-load-development-channels server:aichat-channel`; it targets that launched session only |
| `GrokBridge` | Dedicated Grok Build headless-session bridge | Cannot inject into an arbitrary existing Grok TUI or grok.com conversation |

## Disabled Codex Connector service package

`connector-service/` is the hardened Windows counterpart to the macOS
LaunchAgent package. It installs one current-user Scheduled Task named
`\AIChat\CodexConnector`, but atomically registers it disabled, without a
trigger, and never starts it. The task uses the current SID with
`InteractiveToken`, `LeastPrivilege`, and `IgnoreNew`; connector core supplies
the independent mapping lock.

This package deliberately fixes the runtime contract:

- one dedicated connector channel from private connector settings, never the
  identity config's default channel;
- exact sender IDs, `request` only by default, with one explicit
  `request,result` inbound opt-in; autonomous text remains off;
- Relay WebSocket wake plus startup/reconnect cursor recovery, periodic Relay
  polling off;
- independent Codex App Server, a connector-owned task marker, fixed cwd,
  `approvalPolicy=never`, and `readOnly` or bounded `workspaceWrite` with
  `networkAccess=false`;
- automatic result egress off by default and ordinary connector lifecycle
  status egress fixed off; optional result egress requires a compatible core,
  an exact channel
  acknowledgement, private canary, bounded output, and exact HTTPS reference
  hosts;
- fixed `%USERPROFILE%\.aichat\codex-connector` state/receipt directory, with
  connector state selected by a package-generated SHA-256 namespace over the
  trusted local `app-server`/Agent-identity/channel/task mapping; the instance lock
  metadata remains derived from that state path, while app-server receipts
  remain binding-scoped;
- fixed
  `%LOCALAPPDATA%\AIChat` package root, both current-SID-only and free of
  reparse points, junctions, and protected-file hardlink aliases.

`mapping-state.json` is generated by the installer and is not a user or Relay
input. A fresh mapping uses `state-<mapping-sha256>.json`. When upgrading an
older package that has no mapping metadata, an unchanged installed
Agent/channel/task mapping explicitly retains its existing `state.json`; a changed
mapping receives a new digest namespace. Installation and rollback never move,
copy, truncate, or delete the legacy state file, so a v2 mapping remains
available without allowing it to contaminate a fresh v3 mapping.

The Relay token stays in the existing private identity JSON. It is read only by
the launcher at actual service start, verified against both the locally pinned
Windows Agent ID and Relay `/v1/me`, and passed only to the connector process.
It is never placed in task XML, command arguments, logs, settings, manifests,
or the Codex App Server child environment.

### Prepare private settings

Create a dedicated Codex task, send one local user message containing a unique
16-200 character marker as one exact complete line, record that task UUID, and
use a dedicated project worktree. Copy and edit the example only inside the
protected AIChat root:

```powershell
$privateRoot = Join-Path $env:LOCALAPPDATA "AIChat"
$settings = Join-Path $privateRoot "codex-connector-settings.json"
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
New-Item -ItemType Directory -Path $privateRoot -Force | Out-Null
icacls.exe $privateRoot /inheritance:r /grant:r "*$($sid):(OI)(CI)(F)" | Out-Null
Copy-Item .\deploy\windows\connector-service\config.example.json $settings
icacls.exe $settings /inheritance:r /grant:r "*$($sid):(F)" | Out-Null
notepad.exe $settings
```

`node_binary` and `codex_app_server_binary` must be absolute native PE `.exe`
files without reparse or hardlink aliases. A normal npm `codex.cmd` shim is not
accepted because core starts App Server with `shell=false`. For a standard npm
Codex install, locate the platform package's native executable below
`@openai\codex-win32-x64` or `@openai\codex-win32-arm64` and its
`vendor\<triple>\bin\codex.exe`. Non-standard or ambiguous layouts fail closed;
do not replace this with `shell=true`.

The fixed current-user `%USERPROFILE%\.codex` directory must exist, have the
current SID as owner, and contain the intended signed-in Codex state. The
package pins and revalidates SHA-256 for both native binaries and hashes the
entire installed connector runtime tree.

The connector state root is `%USERPROFILE%\.aichat\codex-connector`. On a
fresh profile the installer creates `%USERPROFILE%\.aichat` with a
current-SID-only protected ACL, then gives the dedicated connector subdirectory
exactly two protected FullControl rules: the current SID and LocalSystem. ACL
normalization uses an owner-and-DACL-only Win32 update. It never requests or
writes a SACL, so this does not require `SeSecurityPrivilege`; the owner remains
the current SID, inheritance remains protected, and no additional principal is
accepted. The migration runs only after the deployment transaction journal is
durable. The connector writes state, app-server receipts, and transient lock
metadata through an atomic Windows path that removes inheritance from every
temporary file before rename. This prevents a durable checkpoint from becoming
unreadable merely because the newly renamed file inherited its parent DACL.

Apply-mode install, upgrade, and rollback normalize a legacy connector data
tree only when every existing entry is a regular, single-link file owned by the
current SID and its ACL contains no principal beyond the current SID or the new
current-SID-plus-LocalSystem contract. Inherited current-SID-only files from an
older package are migrated to protected explicit rules. Additional or broad
principals still fail closed and are never silently rewritten. If
`%USERPROFILE%\.aichat`
already exists with inherited, shared, or additional ACL entries, installation
fails closed. Before changing that existing root, back it up, inspect its
contents and ACLs, and confirm that no other application or Windows account
depends on shared access. Migrate it to the exact current-SID-only contract
only after that review; do not apply a blind recursive ACL rewrite from these
instructions.

### Preflight, install, and check

The default invocation and `-WhatIf` are zero-mutation plans: no ACL changes,
files, npm, Task Scheduler COM, process stop/start, or network access.

```powershell
.\deploy\windows\connector-service\install.ps1 `
  -SettingsPath $settings `
  -RepositoryRoot $PWD

.\deploy\windows\connector-service\install.ps1 `
  -SettingsPath $settings `
  -RepositoryRoot $PWD `
  -Apply -WhatIf

.\deploy\windows\connector-service\install.ps1 `
  -SettingsPath $settings `
  -RepositoryRoot $PWD `
  -Apply

.\deploy\windows\connector-service\check.ps1
.\deploy\windows\connector-service\check.ps1 -Online
```

Install writes a protected hash-bound transaction journal before activation,
stages `npm ci --omit=dev --ignore-scripts`, snapshots fixed allowlisted files
and prior task XML, then installs the runtime and atomically registers the task
disabled. Any failure attempts an inverse rollback; an incomplete rollback
leaves a protected journal and fails closed. `check.ps1` never displays a
token. `-Online` performs only the credential-bound identity GET.

For a supervised foreground acceptance on a host where Task Scheduler access
is unavailable or intentionally out of scope, use the transactional stage-only
mode:

```powershell
.\deploy\windows\connector-service\install.ps1 `
  -SettingsPath $settings `
  -RepositoryRoot $PWD `
  -StageOnly -Apply -WhatIf

.\deploy\windows\connector-service\install.ps1 `
  -SettingsPath $settings `
  -RepositoryRoot $PWD `
  -StageOnly -Apply

.\deploy\windows\connector-service\check.ps1 -StageOnly
```

`-StageOnly` installs and validates the same pinned package, protected settings,
mapping metadata, and connector-data ACL contract, but it never opens Task
Scheduler COM and never queries, creates, replaces, restores, or deletes
`\AIChat\CodexConnector`. Its schema-v4 journal records `task.mode=untouched`,
so install failure recovery and `rollback.ps1 -StageOnly -Apply` preserve the
same no-task boundary. `check.ps1 -StageOnly` deliberately skips the task and
credential-bound online check; `-StageOnly -Online` is rejected. The connector
remains stopped until the operator explicitly runs the installed launcher in
the foreground.

If Task Scheduler rejects a rollback write with `E_ACCESSDENIED`, the journal
correctly remains a blocker even when the files and task already appear
restored. A visible prior task or matching filenames are insufficient proof.
Use the recovery verifier from the same reviewed checkout; its default mode is
read-only and never registers, deletes, enables, or starts a Scheduled Task:

```powershell
.\deploy\windows\connector-service\recover-transaction.ps1
```

It accepts only an integrated schema-v3 managed-task journal or a schema-v4
stage-only journal with the exact single-property `task.mode=untouched`
contract. Schema-v3 recovery requires every fixed manifest target to match the
protected prior backup hash, every absent target to remain absent, and the task
XML hash/existence to match the prior snapshot. Schema-v4 stage-only recovery
checks the same files without calling a task provider or opening Task Scheduler.
Both modes require the connector-data owner/DACL snapshot to match the validated
semantic ACL identity and
the failed transaction to have no live release or staging directory. A
preserved failed release is validated as a private, reparse-free, hardlink-free
tree. Schema-v4 managed-task journals and historical schema-v1/v2 journals
remain fail-closed and are never auto-finalized by this tool.

One narrow exception is available for a schema-v3 managed-task
`rollback_incomplete` journal when the only mismatch is the ConnectorData
owner/DACL. The read-only verifier reports `repair_ready=true` only after every
deployment file and protected backup hash, prior Scheduled Task XML/existence,
release/staging condition, and failed-release tree is exact. The live
ConnectorData tree must have the same entry names and types as the journal.
Each entry must be either already at the exact journal ACL contract or still use the
protected current-SID plus LocalSystem FullControl forward contract, with at
least one forward entry remaining; this permits a hard-interrupted prefix to be
resumed without accepting any third ACL. The initial field repair-ready state
is the complete trusted forward contract; the mixed two-snapshot form is only
the narrowly recognized re-entry shape after an interrupted repair, not a
generic mixed-ACL allowance. The journal snapshot must be one of
the fixed legacy current-SID-only or current-SID-plus-LocalSystem contracts.
Extra principals, deny ACEs, lesser rights, an unexpected owner, reparse
points, hardlinks, changed files, or an untrusted inherited form remain blocked.
Each stored snapshot still validates its own raw SDDL SHA-256. Snapshot identity
is then strict owner/DACL semantics—same owner, protected state, ACE principals,
rights, and inheritance flags—so only Windows SDDL text aliases and ordering
differences among the all-Allow ACEs are ignored.

After reviewing that read-only result, restore only the snapshotted owner/DACL:

```powershell
.\deploy\windows\connector-service\recover-transaction.ps1 `
  -RepairConnectorAcl -Apply
```

This operation uses the no-SACL Owner+DACL API, pins the original transaction
journal SHA-256 across the mutation, verifies ConnectorData file hashes before
and after the change, and then reruns the full read-only rollback verifier. If
restore or any post-repair verification fails, it attempts to restore the exact
pre-run ACL snapshot through the same narrow API, rechecks content and journal
hashes, and leaves the journal blocking; a hard process interruption can be
resumed from the allowlisted mixed prefix on the next run. It never writes the
Scheduled Task, deployment files, Connector state/channel contents, token, or
journal, and it deliberately does not chain finalization.
`-RepairConnectorAcl` without `-Apply`, combining repair with `-Finalize`,
schema-v4 stage-only journals, and historical schema-v1/v2 journals all fail
closed. A successful repair reports `acl_repaired=true`,
`connector_state_content_mutated=false`, `connector_acl_mutated=true`,
`journal_retained=true`, and `finalize_performed=false`.

Run the verifier again as a separate operator decision:

```powershell
.\deploy\windows\connector-service\recover-transaction.ps1
```

Automation must use the repository-owned outer runner and pass exactly one
positional operation. It must not invoke `recover-transaction.ps1` directly or
construct a temporary parser/launcher:

```powershell
$runner = ".\deploy\windows\connector-service\invoke-recovery-json.ps1"
$ps51 = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $runner verify
```

After a reviewed `repair_ready` result, repair remains a separate operator
decision:

```powershell
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $runner repair
```

Run `verify` again and require `rollback_exact=true`. Only then may a separate
operator decision finalize the journal:

```powershell
& $ps51 -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass `
  -File $runner finalize
```

The canonical token order is always host arguments, `-File`, the runner path,
then the positional operation. The runner internally uses the same ordering
for the target: host arguments, `-File`, `recover-transaction.ps1`, then the
target's `-OutputFormat Json` and fixed operation flags. Windows
`powershell.exe` has its own `-OutputFormat Text|XML` host option. Placing the
target's `-OutputFormat Json` before `-File` makes the host reject `Json` before
the recovery script can emit its contract.

The runner accepts no arbitrary arguments and never chains verify, repair, or
finalize. It launches the fixed same-directory target under explicit Windows
PowerShell 5.1, captures stdout and stderr separately, applies a bounded
timeout, terminates the child before returning from timeout or internal-error
paths when Windows confirms termination, and validates raw framing, ASCII,
unique keys, field order/types,
operation, mode, status/error enums, mutation invariants, and native exit code.
Valid target success and failure JSON is forwarded byte-for-byte at the ASCII
text level with target exit code `0` or `1`.

All runner-level failures exit `2` and emit exactly these fields:

```text
runner_contract_version operation success error_code target_exit_code
mutation_possible
```

`runner_contract_version` is `1`, `success` is `false`, and `operation` is
`verify`, `repair`, `finalize`, or `unknown` when runner arguments were invalid.
`target_exit_code` is a native integer when a completed target supplied one and
JSON `null` when no trustworthy target exit code exists. Fixed `error_code`
values are:

- `invalid_runner_arguments`
- `target_missing`
- `powershell_51_unavailable`
- `target_start_failed`
- `target_timeout`
- `target_termination_failed`
- `target_capture_failed`
- `target_stderr`
- `target_output_invalid`
- `target_duplicate_key`
- `target_json_invalid`
- `target_contract_invalid`
- `runner_internal_error`

Runner failures never reproduce child stdout/stderr, paths, raw exceptions,
credentials, SID/SDDL data, or other untrusted text. For `verify`,
`mutation_possible=false` because the runner fixes a read-only invocation. For
`repair` or `finalize`, any failure after the target successfully starts is
reported with `mutation_possible=true`; this is deliberately conservative even
when the likely failure happened before the target body. The runner makes two
bounded kill-and-wait attempts. `target_termination_failed` means the child
state remains unknown; do not retry repair or finalize until the local process
state has been independently resolved.

`-OutputFormat Json` writes exactly one compact ASCII-safe JSON object to
stdout and no human `state_root`, task, or diagnostic lines. Contract version 2
includes `operation`, `mode`, native JSON boolean outcome fields, `success`, and
`status`; failures exit nonzero and return a fixed `error_code` instead of the
raw exception. JSON output never includes filesystem paths, credential values,
SIDs, SDDL, or untrusted exception text, and caught failures keep stderr empty.
Bootstrap failures while loading `common.ps1` or initializing protected paths
return the fixed `initialization_failed` code under the same single-object
contract; unsupported output-format values return `invalid_arguments`.
The same format is available for `-RepairConnectorAcl -Apply` and
`-Finalize -Apply`. On a failure, `mutation_performed` and
`connector_acl_mutated` mean that this invocation may already have attempted or
performed the target mutation, even if compensation restored the final ACL;
they are not a statement that final state still differs from the starting
state. `journal_retained` reports whether the live blocker was cleared.

Contract version 2 is a flat JSON object. Every success object contains exactly
these fields:

```text
contract_version operation mode success status transaction_id journal_schema
file_targets_exact task_snapshot_exact task_mode task_untouched
task_scheduler_accessed connector_data_acl_exact live_release_absent
staging_absent failed_release_preserved rollback_exact rollback_non_acl_exact
repair_ready acl_repaired finalize_requested finalize_performed
mutation_performed journal_retained token_read task_write_attempted
connector_state_mutated connector_state_content_mutated connector_acl_mutated
```

Every caught failure object contains exactly these fields:

```text
contract_version operation mode success status error_code diagnostic_code
mutation_performed journal_retained token_read task_write_attempted
connector_state_mutated connector_state_content_mutated connector_acl_mutated
finalize_performed
```

The fixed enums are:

- `operation`: `verify`, `repair`, `finalize`.
- `mode`: `read_only`, `what_if`, `apply`.
- Success `status`: `repair_ready`, `rollback_exact`, `finalize_ready`,
  `acl_repaired`, `finalized`.
- Failure `status` and `error_code`: `invalid_arguments`,
  `initialization_failed`, `verification_failed`, `acl_repair_failed`,
  `finalization_failed`, `internal_error`.
- Failure `diagnostic_code`: `arguments_invalid`, `common_load_failed`,
  `protected_paths_invalid`, `journal_invalid`, `journal_backup_invalid`,
  `manifest_invalid`, `file_snapshot_mismatch`, `task_snapshot_mismatch`,
  `release_layout_mismatch`, `acl_snapshot_mismatch`,
  `acl_repair_ineligible`, `acl_repair_not_required`, `acl_repair_required`,
  `concurrent_journal_change`, `concurrent_state_change`,
  `concurrent_acl_change`, `concurrent_content_change`,
  `acl_repair_apply_failed`, `finalize_archive_failed`,
  `finalize_reverification_failed`, `finalize_clear_failed`, or
  `internal_error`. The runner validates the code against both the operation
  and broad `error_code`; no code is derived from exception text.

The inner JSON guarantee starts only after PowerShell has successfully parsed
the target script and bound its command-line parameters. A syntax error in
`recover-transaction.ps1` itself, an unknown parameter, or another native
parameter-binding failure occurs before the script body and cannot be wrapped
by the inner contract. The outer runner converts those cases to its fixed,
redacted exit-2 failure object.

Only after the verifier reports `rollback_exact=true` may the operator archive
the original journal and clear the live blocker:

```powershell
.\deploy\windows\connector-service\recover-transaction.ps1 `
  -Finalize -Apply
```

Finalization revalidates all invariants immediately before removal and stores
the byte-identical protected journal as
`backups\<transaction-id>\rollback-incomplete.finalized.json`. It does not
delete the failed release, alter Connector state, read a token, or request Task
Scheduler write access. Any mismatch leaves `transaction.json` in place.

The task remains disabled after a successful install. Do not enable it until
the Mac/core PR is compatible and a supervised Windows acceptance verifies the
native `codex.exe app-server` initialize handshake, signed-in identity, and
process-tree shutdown behavior.

### Supervised durable one-shot acceptance

Use a new empty two-member channel, a new dedicated Codex task, and fresh
connector state. Keep the Scheduled Task disabled with zero triggers. Publish
exactly one synthetic request, capture its Relay message ID, then immediately
run the installed launcher in the foreground with that ID:

```powershell
$stateRoot = Join-Path $env:LOCALAPPDATA "AIChat\codex-connector-task"
& (Join-Path $stateRoot "launcher.ps1") `
  -StateRoot $stateRoot `
  -Once `
  -ExpectedMessageId "THE_SYNTHETIC_REQUEST_MESSAGE_GUID"
```

`-Once` disables WebSocket and periodic recovery, drains the accepted Codex
turn through `turn/completed`, waits for connector-side suppression handling,
then shuts down App Server. It succeeds only when the connector cursor and
receipt plus the app-server driver receipt all match `ExpectedMessageId`, with
exactly one seen inbound message and one delivery record in the fresh mapping,
and with the driver record successfully completed, connector-checkpointed, and
outbound-handled. When result egress is enabled, the checkpoint additionally
requires a model-declared `result`, an exact driver-to-connector outbound event
match, and a persisted Relay UUID; a locally suppressed lifecycle completion,
an older local checkpoint, or a different outbound event cannot pass as result
delivery. Supervised `-Once` therefore requires fresh connector state and no
pre-existing app-server receipt for the fixed mapping. A
failed, interrupted, or cancelled Codex turn does not pass this acceptance. A
successful run prints only non-secret booleans ending in
`durable_checkpoint_ready=true`; seeing a turn in the Codex UI is not this
checkpoint.

“Fresh connector state” means the state file selected by the installed mapping
metadata, not an empty shared directory. A prior `state.json` from another
mapping does not block a digest-scoped v3 acceptance, and the launcher never
accepts a message field, environment override, or command argument that can
select a different state filename. The per-state instance-lock metadata file is
derived by connector core as `<selected-state>.instance-lock.json`.

Do not press Ctrl+C merely because the UI turn appears. If the marker result
must be checked, read the dedicated task only after the durable line appears,
then verify the exact assistant output separately. Finally confirm the wrapper
exited and that neither Node nor the child `codex.exe app-server` remains. Do
not reuse a channel with queued history, edit a cursor, or skip a message to
force the test through.

### Optional result return path

The default example keeps `egress.enabled=false`, and the first synthetic E2E
must keep it disabled. After inbound delivery is accepted, a later supervised
test may enable automatic `result` return by setting all of the following in
the protected connector settings:

```json
"egress": {
  "enabled": true,
  "acknowledged_channel_id": "THE_EXACT_SAME_VALUE_AS_channel_id",
  "canary_path": "C:\\Users\\YOUR_USER\\AppData\\Local\\AIChat\\codex-egress-canary.txt",
  "allowed_reference_hosts": ["github.com"],
  "max_text_bytes": 8192
}
```

Create the canary directly in `%LOCALAPPDATA%\AIChat` without displaying it,
then protect it with the same current-SID-only ACL as the settings file. The
launcher rejects a canary outside the protected root, inherited or additional
ACL entries, reparse points, hardlink aliases, multiple lines, and values
outside 16–512 characters. The acknowledged channel must exactly equal the
fixed connector channel. References are either blocked entirely or restricted
to the configured exact public DNS names over HTTPS; IP, localhost, URL query,
fragment, credentials, and non-HTTPS references remain blocked by core.

This path requires connector core with durable lifecycle-off suppression (the
core fix beginning at `81412e1` and explicit interrupted coverage through
`c38c3d9`); do not enable it against older core. With that dependency, ordinary
completed, failed, or interrupted lifecycle events remain local durable
suppression records, while a model-declared, receipt-correlated `result` can
return to the fixed AIChat channel. The only independent status exception is a
fixed, redacted terminal `blocked` event for a permanent egress quarantine.
The connector does not send arbitrary task text or enable autonomous `text`
input. `reply_to` is correlation, not a private recipient: every channel member
can read the result. DLP and the canary are defense in depth, so sensitive use
still requires a separate OS user, VM, or container.

### Optional inbound result alignment

The default `deliver_results` setting remains `false`. After the one-way
request acceptance is durable, either host may opt in to showing peer results
inside its fixed dedicated Codex task:

```json
"deliver_results": true
```

The Windows launcher then fixes the core allowlist to `request,result`; it
cannot express `result`-only, `text`, `status`, or unknown values. Enabling result delivery does not relax the fixed
channel, exact sender IDs, task/thread/worktree binding, sender turn budget,
deduplication, cursor, state, receipt, or lock contracts.

Inbound results are never reply-eligible. Their App Server turn receives no
structured reply schema, any reply-shaped model output is retained locally
rather than sent to AIChat, and no lifecycle status is produced for that turn.
Only a durably recorded source type of `request` can authorize outbound result
or status handling. Keep automatic egress as the separate canary/audience/DLP
opt-in above; `request,result` inbound alone cannot create a relay loop.

### Rollback and uninstall

```powershell
.\deploy\windows\connector-service\rollback.ps1
.\deploy\windows\connector-service\rollback.ps1 -Apply -WhatIf
.\deploy\windows\connector-service\rollback.ps1 -Apply
.\deploy\windows\connector-service\rollback.ps1 -StageOnly -Apply -WhatIf
.\deploy\windows\connector-service\rollback.ps1 -StageOnly -Apply

.\deploy\windows\connector-service\uninstall.ps1
.\deploy\windows\connector-service\uninstall.ps1 -Apply -WhatIf
.\deploy\windows\connector-service\uninstall.ps1 -Apply
```

Rollback accepts only the protected schema, fixed target IDs (including mapping
metadata for new transactions), current-SID ACL,
no-reparse/no-hardlink files, and matching backup hashes. Uninstall removes only
the exactly managed task and recoverably moves package/runtime and connector
state; the identity config is preserved. Every install/check/rollback/uninstall
mutation boundary requires Task Scheduler state to be exactly `Disabled`, not
merely “not running”; queued, ready, running, or unknown states fail closed.
The scripts never attempt a process-name kill. Supervised Windows acceptance
must still prove that a previously started wrapper left no Node/Codex orphan.

`readOnly` prevents writes but does not limit what the connector user can read.
The first cross-host E2E must therefore use only synthetic, non-sensitive
requests and a disposable worktree. Sensitive deployments need a separate OS
user, VM, or container; the Relay and DLP heuristics are not a confidentiality
boundary.

Requirements depend on selected components: Python 3.11+, Node.js 20+, `uvx`
for the Codex plugin, and the corresponding signed-in `codex`, `claude`, or
`grok` CLI. The relay identity must already be joined to its channel.

## Dry run and install

PowerShell execution-policy changes are not made by the installer. From the
repository root:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\deploy\windows\install.ps1 -WhatIf
```

Minimal plugin plus MCP runtime:

```powershell
.\deploy\windows\install.ps1 `
  -Components CoreMcp,CodexPlugin `
  -RelayUrl "https://relay.example.org/aichat" `
  -RegisterIdentity
```

Registration saves the returned token only in the private PlatformDirs-compatible
file `%LOCALAPPDATA%\AIChat\AIChat\config.json`, restricts its ACL to the current
Windows identity, and prints only the agent ID. If a token already exists it is
preserved. Registration is disabled on the production Relay. Use the protected
bootstrap import above instead of editing example JSON or typing a token.

Prepare the remaining proactive adapters:

```powershell
.\deploy\windows\install.ps1 `
  -Components CoreMcp,ClaudeChannel,GrokBridge `
  -RelayUrl "https://relay.example.org/aichat" `
  -ChannelId "CHANNEL_ID" `
  -AllowedSenderIds "AGENT_ID_1,AGENT_ID_2" `
  -GrokWorkDir "C:\work\project"
```

Run prepared adapters from the private state directory:

```powershell
$root = "$env:LOCALAPPDATA\AIChat\deploy\windows"
& "$root\run-adapter.ps1" -Mode GrokBridge
claude --dangerously-load-development-channels server:aichat-channel
```

For Codex, use only the hardened `connector-service/` flow above. The legacy
`run-adapter.ps1 -Mode CodexConnector` path fails before it reads identity
configuration or starts Node, so it cannot bypass the task, sandbox, egress,
and binary-pinning contract.

## Check, rollback, uninstall

```powershell
.\deploy\windows\check.ps1
.\deploy\windows\check.ps1 -Online
.\deploy\windows\rollback.ps1 -WhatIf
.\deploy\windows\uninstall.ps1 -WhatIf
```

`check.ps1` never displays the token. `rollback.ps1` restores the latest backed-up
files and previous runtimes. `uninstall.ps1` removes only CLI entries recorded as
installer-owned and only removes the Claude Desktop entry when its management
marker still matches. Runtime removal is a recoverable move. Identity config is
preserved unless `-RemoveIdentityConfig` is explicitly supplied.

Backups, manifests, runners, and isolated runtimes live below
`%LOCALAPPDATA%\AIChat\deploy\windows`. Use `-StateRoot`, `-ConfigPath`, and
`-RepositoryRoot` only when a non-default layout is intentional.

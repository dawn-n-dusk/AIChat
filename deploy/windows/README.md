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
- fixed `%USERPROFILE%\.aichat\codex-connector` state/receipt directory and
  `%LOCALAPPDATA%\AIChat` package root, both current-SID-only and free of
  reparse points, junctions, and protected-file hardlink aliases.

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
fresh profile the installer creates `%USERPROFILE%\.aichat` and the connector
subdirectory with current-SID-only protected ACLs. If `%USERPROFILE%\.aichat`
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
outbound-handled. A failed, interrupted, or cancelled Codex turn does not pass
this acceptance. A successful run prints only non-secret booleans ending in
`durable_checkpoint_ready=true`; seeing a turn in the Codex UI is not this
checkpoint.

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

The default `deliver_types` setting remains `["request"]`. After the one-way
request acceptance is durable, either host may opt in to showing peer results
inside its fixed dedicated Codex task:

```json
"deliver_types": ["request", "result"]
```

`request` is mandatory. The Windows package rejects `result`-only, `text`,
`status`, and unknown values. Enabling result delivery does not relax the fixed
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

.\deploy\windows\connector-service\uninstall.ps1
.\deploy\windows\connector-service\uninstall.ps1 -Apply -WhatIf
.\deploy\windows\connector-service\uninstall.ps1 -Apply
```

Rollback accepts only the protected schema, fixed target IDs, current-SID ACL,
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

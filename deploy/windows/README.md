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
Copy-Item -LiteralPath "E:\secure-transfer\windows-agent.bootstrap.json" `
  -Destination (Join-Path $bootstrapDir "windows-agent.bootstrap.json")

Set-ExecutionPolicy -Scope Process Bypass
.\deploy\windows\import-bootstrap.ps1 `
  -BootstrapPath (Join-Path $bootstrapDir "windows-agent.bootstrap.json")
```

The importer rejects directories and reparse points, replaces the input file's
ACL with one FullControl rule for the current Windows SID before reading it,
validates the schema/server/Agent/token fields, and atomically writes UTF-8
without BOM to `%LOCALAPPDATA%\AIChat\AIChat\config.json`. It preserves existing
non-identity settings such as `channel_id` and `default_channel_id`, updates only
`server`, `agent_id`, `agent_name`, and `token`, and restricts the resulting
config ACL to the current SID. On success it deletes the imported artifact by
default and reports only non-secret state including `token_present=true`.
`-KeepBootstrap` is available only for an explicitly controlled diagnostic;
delete that restricted file manually as soon as the diagnostic ends.

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
```

Then fully exit and restart Codex App and create a new task. Existing tasks do
not reliably reload a newly installed plugin, skill, MCP process, or changed
identity config. In the new task, call the AIChat identity tool and verify the
public Relay URL and expected Windows Agent ID without displaying any token.

## Supported boundaries

| Component | What this installer provides | Important boundary |
| --- | --- | --- |
| `CoreMcp` | Private Python runtime for interactive AIChat MCP tools | MCP does not wake an existing conversation |
| `CodexPlugin` | Repository marketplace plugin, skills, and MCP entry | Restart Codex and open a new task after installation |
| `CodexMcp` | Direct local MCP entry named `aichat-local` | Alternative to the plugin MCP, not proactive delivery |
| `CodexConnector` | Event-driven fixed-task connector runtime | Windows uses separate `codex app-server`; it does not prove live attachment to the open Desktop UI task |
| `ClaudeDesktop` | Standard interactive MCP tools | Claude Desktop has no Claude Code Channel push |
| `ClaudeCodeMcp` | Standard user-scoped MCP tools | Interactive pull/send only |
| `ClaudeChannel` | Research-preview Claude Code Channel adapter | Start Claude with `--dangerously-load-development-channels server:aichat-channel`; it targets that launched session only |
| `GrokBridge` | Dedicated Grok Build headless-session bridge | Cannot inject into an arbitrary existing Grok TUI or grok.com conversation |

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

Prepare proactive adapters:

```powershell
.\deploy\windows\install.ps1 `
  -Components CoreMcp,CodexConnector,ClaudeChannel,GrokBridge `
  -RelayUrl "https://relay.example.org/aichat" `
  -ChannelId "CHANNEL_ID" `
  -AllowedSenderIds "AGENT_ID_1,AGENT_ID_2" `
  -CodexThreadId "CODEX_SESSION_UUID" `
  -GrokWorkDir "C:\work\project"
```

Run prepared adapters from the private state directory:

```powershell
$root = "$env:LOCALAPPDATA\AIChat\deploy\windows"
& "$root\run-adapter.ps1" -Mode CodexConnector
& "$root\run-adapter.ps1" -Mode GrokBridge
claude --dangerously-load-development-channels server:aichat-channel
```

Only one proactive adapter instance should own a given channel/task/state
mapping. Keep Codex Desktop from editing the same Windows task while the
app-server connector is delivering a turn.

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

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Mcp", "CodexConnector", "ClaudeChannel", "GrokBridge")]
    [string]$Mode,

    [string]$ConfigPath,
    [string]$SettingsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($Mode -eq "CodexConnector") {
    throw "Legacy CodexConnector runner is disabled; use deploy/windows/connector-service"
}

. (Join-Path $PSScriptRoot "common.ps1")

$paths = Get-AIChatWindowsPaths -StateRoot $PSScriptRoot -ConfigPath $ConfigPath
if (-not $SettingsPath) {
    $SettingsPath = $paths.SettingsPath
}
if (-not (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf)) {
    throw "AIChat identity config is missing: $($paths.ConfigPath)"
}

$config = Read-JsonObject -Path $paths.ConfigPath
foreach ($required in @("server", "token")) {
    if (-not $config.PSObject.Properties[$required] -or -not [string]$config.$required) {
        throw "AIChat config is missing $required"
    }
}
$settings = Read-JsonObject -Path $SettingsPath

# Values are injected only into this process tree. No secret value is printed or
# placed on a command line.
$env:AICHAT_CONFIG = $paths.ConfigPath
$env:AICHAT_SERVER = [string]$config.server
$env:AICHAT_TOKEN = [string]$config.token
if ($config.PSObject.Properties["channel_id"] -and [string]$config.channel_id) {
    $env:AICHAT_CHANNEL_ID = [string]$config.channel_id
} elseif ($config.PSObject.Properties["default_channel_id"] -and [string]$config.default_channel_id) {
    $env:AICHAT_CHANNEL_ID = [string]$config.default_channel_id
}

switch ($Mode) {
    "Mcp" {
        $executable = Join-Path $paths.RuntimeDirectory "mcp\Scripts\aichat-mcp.exe"
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
            throw "AIChat MCP runtime is not installed. Re-run install.ps1 with CoreMcp."
        }
        & $executable
        exit $LASTEXITCODE
    }
    "ClaudeChannel" {
        if (-not $env:AICHAT_CHANNEL_ID) {
            throw "AIChat config is missing channel_id/default_channel_id"
        }
        if (-not $settings.PSObject.Properties["allowed_sender_ids"] -or -not [string]$settings.allowed_sender_ids) {
            throw "Adapter settings are missing allowed_sender_ids"
        }
        $env:AICHAT_ALLOWED_SENDER_IDS = [string]$settings.allowed_sender_ids
        $directory = Join-Path $paths.RuntimeDirectory "claude-channel"
        Set-Location -LiteralPath $directory
        & node (Join-Path $directory "src\server.js")
        exit $LASTEXITCODE
    }
    "GrokBridge" {
        if (-not $env:AICHAT_CHANNEL_ID) {
            throw "AIChat config is missing channel_id/default_channel_id"
        }
        foreach ($property in @("allowed_sender_ids", "grok_workdir")) {
            if (-not $settings.PSObject.Properties[$property] -or -not [string]$settings.$property) {
                throw "Adapter settings are missing $property"
            }
        }
        $env:AICHAT_GROK_BRIDGE_ENABLED = "true"
        $env:AICHAT_ALLOWED_SENDER_IDS = [string]$settings.allowed_sender_ids
        $env:GROK_WORKDIR = [string]$settings.grok_workdir
        if ($settings.PSObject.Properties["grok_command"] -and [string]$settings.grok_command) {
            $env:GROK_COMMAND = [string]$settings.grok_command
        }
        $entry = Join-Path $paths.RuntimeDirectory "grok-bridge\src\cli.js"
        & node $entry
        exit $LASTEXITCODE
    }
}

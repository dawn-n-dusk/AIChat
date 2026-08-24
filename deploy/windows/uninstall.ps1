[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$StateRoot,
    [string]$ConfigPath,
    [switch]$RemoveIdentityConfig,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($DryRun) { $WhatIfPreference = $true }
. (Join-Path $PSScriptRoot "common.ps1")
$uninstallCmdlet = $PSCmdlet

$paths = Get-AIChatWindowsPaths -StateRoot $StateRoot -ConfigPath $ConfigPath
$ownership = Read-Ownership -Path $paths.OwnershipPath
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$removedRoot = Join-Path $paths.StateRoot "removed\$stamp"

function Remove-OwnedCliEntry {
    param([bool]$Owned, [string]$Command, [string[]]$Arguments, [string]$Label)
    if (-not $Owned -or -not (Test-ExternalCommand $Command)) { return }
    if ($uninstallCmdlet.ShouldProcess($Label, "Remove installer-owned entry")) {
        $result = Invoke-NativeCapture $Command $Arguments
        if ($result.ExitCode -ne 0) { Write-Warning "$Label removal failed; it may already be absent." }
    }
}

Remove-OwnedCliEntry $ownership.CodexMcpAdded "codex" @("mcp", "remove", "aichat-local") "Codex MCP aichat-local"
Remove-OwnedCliEntry $ownership.CodexPluginAdded "codex" @("plugin", "remove", "aichat@aichat-repo", "--json") "Codex plugin aichat"
Remove-OwnedCliEntry $ownership.CodexMarketplaceAdded "codex" @("plugin", "marketplace", "remove", "aichat-repo", "--json") "Codex marketplace aichat-repo"
Remove-OwnedCliEntry $ownership.ClaudeCodeMcpAdded "claude" @("mcp", "remove", "--scope", "user", "aichat-local") "Claude Code MCP aichat-local"
Remove-OwnedCliEntry $ownership.ClaudeChannelMcpAdded "claude" @("mcp", "remove", "--scope", "user", "aichat-channel") "Claude Code channel aichat-channel"

if ($ownership.ClaudeDesktopManaged -and $paths.ClaudeDesktopPath -and (Test-Path $paths.ClaudeDesktopPath)) {
    $desktop = Read-JsonObject $paths.ClaudeDesktopPath
    $entry = if ($desktop.PSObject.Properties["mcpServers"]) { $desktop.mcpServers.PSObject.Properties["aichat"] } else { $null }
    $managed = $entry -and $entry.Value.PSObject.Properties["env"] -and
        $entry.Value.env.PSObject.Properties["AICHAT_MANAGED_BY"] -and
        $entry.Value.env.AICHAT_MANAGED_BY -eq "AIChat-Windows-Installer"
    if ($managed -and $PSCmdlet.ShouldProcess($paths.ClaudeDesktopPath, "Remove managed aichat MCP entry while preserving all other JSON")) {
        $desktop.mcpServers.PSObject.Properties.Remove("aichat")
        Write-JsonAtomic $paths.ClaudeDesktopPath $desktop
    }
}

if (Test-Path $paths.RuntimeDirectory) {
    if ($PSCmdlet.ShouldProcess($paths.RuntimeDirectory, "Move installed runtimes to recoverable removed directory")) {
        New-Item -ItemType Directory -Path $removedRoot -Force | Out-Null
        Move-Item $paths.RuntimeDirectory (Join-Path $removedRoot "runtime")
    }
}
if ($RemoveIdentityConfig -and (Test-Path $paths.ConfigPath)) {
    if ($PSCmdlet.ShouldProcess($paths.ConfigPath, "Move identity config to recoverable removed directory")) {
        New-Item -ItemType Directory -Path $removedRoot -Force | Out-Null
        Move-Item $paths.ConfigPath (Join-Path $removedRoot "config.json")
    }
}
Write-Host "Uninstall completed. Identity config was preserved unless -RemoveIdentityConfig was supplied."
Write-Host "Recoverable removals: $removedRoot"

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param([string]$StateRoot, [string]$ConfigPath, [switch]$DryRun)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($DryRun) { $WhatIfPreference = $true }
. (Join-Path $PSScriptRoot "common.ps1")
$paths = Get-AIChatWindowsPaths -StateRoot $StateRoot -ConfigPath $ConfigPath
$manifestPath = Join-Path $paths.ManifestDirectory "latest.json"
if (-not (Test-Path $manifestPath)) { throw "No rollback manifest exists: $manifestPath" }
$manifest = Read-JsonObject $manifestPath
foreach ($item in @($manifest.file_backups)) {
    if (-not $PSCmdlet.ShouldProcess([string]$item.Path, "Restore pre-install file state")) { continue }
    if ([bool]$item.Existed) {
        if (-not (Test-Path ([string]$item.BackupPath))) { throw "Backup missing: $($item.BackupPath)" }
        New-Item -ItemType Directory -Path (Split-Path -Parent ([string]$item.Path)) -Force | Out-Null
        Copy-Item ([string]$item.BackupPath) ([string]$item.Path) -Force
    } elseif (Test-Path ([string]$item.Path)) {
        Move-Item ([string]$item.Path) "$([string]$item.Path).rolled-back-$([Guid]::NewGuid().ToString('N'))"
    }
}
foreach ($item in @($manifest.runtime_backups)) {
    if ($PSCmdlet.ShouldProcess([string]$item.Path, "Restore previous runtime")) {
        if (Test-Path ([string]$item.Path)) { Move-Item ([string]$item.Path) "$([string]$item.Path).rolled-back" }
        Move-Item ([string]$item.BackupPath) ([string]$item.Path)
    }
}
Write-Host "Restored the latest file/runtime backup manifest. CLI plugin/MCP entries are managed by uninstall.ps1."

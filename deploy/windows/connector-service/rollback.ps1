[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param([switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stateRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA "AIChat\codex-connector-task")
)
Write-Host "state_root=$stateRoot"
Write-Host "task=\AIChat\CodexConnector"
Write-Host "token_read=false"
if (-not $Apply -or $WhatIfPreference) {
    Write-Host "dry_run=true"
    Write-Host "mutation_performed=false"
    exit 0
}

. (Join-Path $PSScriptRoot "common.ps1")
$paths = Get-AIChatConnectorPaths
[void](Assert-AIChatPrivateDirectoryTree `
    -Path $paths.StateRoot `
    -ProtectedRoot $paths.ProtectedRoot)
if (Test-Path -LiteralPath $paths.TransactionPath) {
    throw "Refusing user rollback while an unfinished install transaction exists"
}
$task = Get-AIChatConnectorTask
if ($null -ne $task) {
    Assert-AIChatTaskContract -Task $task -Paths $paths
}

$pointer = Read-AIChatPrivateJson `
    -Path $paths.LastBackupPath `
    -ProtectedRoot $paths.ProtectedRoot
if (-not $pointer.PSObject.Properties["schema_version"] -or
    [int]$pointer.schema_version -ne 1 -or
    -not $pointer.PSObject.Properties["kind"] -or
    [string]$pointer.kind -ne "aichat-windows-connector-last-backup" -or
    -not $pointer.PSObject.Properties["transaction_id"] -or
    [string]$pointer.transaction_id -notmatch '^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$' -or
    -not $pointer.PSObject.Properties["manifest_sha256"]) {
    throw "Last-backup pointer schema is invalid"
}
$backupDirectory = Join-Path $paths.BackupsDirectory ([string]$pointer.transaction_id)
$manifestPath = Join-Path $backupDirectory "manifest.json"
[void](Assert-AIChatPrivateFile -Path $manifestPath -ProtectedRoot $paths.ProtectedRoot)
$manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($manifestHash -ne ([string]$pointer.manifest_sha256).ToLowerInvariant()) {
    throw "Last-backup manifest hash does not match its protected pointer"
}
$manifest = Read-AIChatPrivateJson `
    -Path $manifestPath `
    -ProtectedRoot $paths.ProtectedRoot
Assert-AIChatTransactionManifest `
    -Manifest $manifest `
    -Paths $paths `
    -BackupDirectory $backupDirectory `
    -AllowedStatuses @("committed")
Invoke-AIChatManifestRollback `
    -Manifest $manifest `
    -Paths $paths `
    -BackupDirectory $backupDirectory

[void](Assert-AIChatPrivateFile `
    -Path $paths.LastBackupPath `
    -ProtectedRoot $paths.ProtectedRoot)
Remove-Item -LiteralPath $paths.LastBackupPath -Force
Write-Host "rolled_back_transaction=$([string]$manifest.transaction_id)"
Write-Host "token_read=false"
Write-Host "task_started=false"

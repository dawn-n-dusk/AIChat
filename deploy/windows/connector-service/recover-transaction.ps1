[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [switch]$Finalize,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$paths = Get-AIChatConnectorPaths
Write-Host "state_root=$($paths.StateRoot)"
Write-Host "task=\AIChat\CodexConnector"
Write-Host "token_read=false"
Write-Host "task_write_attempted=false"
Write-Host "connector_state_mutated=false"

[void](Assert-AIChatPrivateDirectoryTree `
    -Path $paths.StateRoot `
    -ProtectedRoot $paths.ProtectedRoot)
[void](Assert-AIChatPrivateFile `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot)
$journal = Read-AIChatPrivateJson `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot
$backupDirectory = Join-Path $paths.BackupsDirectory ([string]$journal.transaction_id)
[void](Assert-AIChatPrivateDirectoryTree `
    -Path $backupDirectory `
    -ProtectedRoot $paths.ProtectedRoot)
$result = Assert-AIChatManifestRollbackComplete `
    -Manifest $journal `
    -Paths $paths `
    -BackupDirectory $backupDirectory

Write-Host "transaction_id=$($result.transaction_id)"
Write-Host "journal_schema=$($result.schema_version)"
Write-Host "file_targets_exact=$($result.file_targets_exact.ToString().ToLowerInvariant())"
Write-Host "task_snapshot_exact=$($result.task_snapshot_exact.ToString().ToLowerInvariant())"
Write-Host "connector_data_acl_exact=$($result.connector_data_acl_exact.ToString().ToLowerInvariant())"
Write-Host "live_release_absent=$($result.live_release_absent.ToString().ToLowerInvariant())"
Write-Host "staging_absent=$($result.staging_absent.ToString().ToLowerInvariant())"
Write-Host "failed_release_preserved=$($result.failed_release_preserved.ToString().ToLowerInvariant())"
Write-Host "rollback_exact=true"

if (-not $Finalize -or -not $Apply -or $WhatIfPreference) {
    Write-Host "finalize_requested=$($Finalize.ToString().ToLowerInvariant())"
    Write-Host "mutation_performed=false"
    Write-Host "journal_retained=true"
    exit 0
}

$archivePath = Join-Path $backupDirectory "rollback-incomplete.finalized.json"
$journalHash = (Get-FileHash -LiteralPath $paths.TransactionPath -Algorithm SHA256).Hash.ToLowerInvariant()
if (Test-Path -LiteralPath $archivePath) {
    [void](Assert-AIChatPrivateFile `
        -Path $archivePath `
        -ProtectedRoot $paths.ProtectedRoot)
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $journalHash) {
        throw "Existing finalized rollback archive does not match the live journal"
    }
} else {
    Copy-AIChatPrivateFileAtomic `
        -Source $paths.TransactionPath `
        -Destination $archivePath `
        -ProtectedRoot $paths.ProtectedRoot
}
[void](Assert-AIChatPrivateFile `
    -Path $archivePath `
    -ProtectedRoot $paths.ProtectedRoot)
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    $journalHash) {
    throw "Finalized rollback archive is not byte-identical to the live journal"
}

# Re-read both protected artifacts and revalidate every prior-state invariant
# immediately before clearing the live blocker. This path never registers,
# deletes, enables, starts, or otherwise mutates the Scheduled Task.
[void](Assert-AIChatPrivateFile `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot)
if ((Get-FileHash -LiteralPath $paths.TransactionPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
    $journalHash) {
    throw "Live transaction journal changed during finalization"
}
$journal = Read-AIChatPrivateJson `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot
[void](Assert-AIChatManifestRollbackComplete `
    -Manifest $journal `
    -Paths $paths `
    -BackupDirectory $backupDirectory)

Remove-Item -LiteralPath $paths.TransactionPath -Force
Write-Host "transaction_abandoned=true"
Write-Host "journal_archived=true"
Write-Host "journal_retained=false"
Write-Host "mutation_performed=true"
Write-Host "token_read=false"
Write-Host "task_write_attempted=false"

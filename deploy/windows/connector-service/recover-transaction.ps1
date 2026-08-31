[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [switch]$Finalize,
    [switch]$RepairConnectorAcl,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

function Read-AIChatRecoveryJournalUnchanged {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    [void](Assert-AIChatPrivateFile -Path $Path -ProtectedRoot $ProtectedRoot)
    $before = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($before -ne $ExpectedSha256) {
        throw "Live transaction journal changed before ACL repair"
    }
    $value = Read-AIChatPrivateJson -Path $Path -ProtectedRoot $ProtectedRoot
    $after = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($after -ne $ExpectedSha256) {
        throw "Live transaction journal changed while being revalidated"
    }
    return $value
}

$paths = Get-AIChatConnectorPaths
Write-Host "state_root=$($paths.StateRoot)"
Write-Host "task=\AIChat\CodexConnector"
Write-Host "token_read=false"
Write-Host "task_write_attempted=false"

if ($RepairConnectorAcl -and $Finalize) {
    throw "Connector ACL repair and transaction finalization must be separate operations"
}
if ($RepairConnectorAcl -and -not $Apply) {
    throw "Connector ACL repair requires both -RepairConnectorAcl and -Apply"
}
if ($Apply -and -not $RepairConnectorAcl -and -not $Finalize) {
    throw "-Apply requires either -RepairConnectorAcl or -Finalize"
}

[void](Assert-AIChatPrivateDirectoryTree `
    -Path $paths.StateRoot `
    -ProtectedRoot $paths.ProtectedRoot)
[void](Assert-AIChatPrivateFile `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot)
$journalHash = (Get-FileHash `
    -LiteralPath $paths.TransactionPath `
    -Algorithm SHA256).Hash.ToLowerInvariant()
$journal = Read-AIChatRecoveryJournalUnchanged `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot `
    -ExpectedSha256 $journalHash
$backupDirectory = Join-Path $paths.BackupsDirectory ([string]$journal.transaction_id)
[void](Assert-AIChatPrivateDirectoryTree `
    -Path $backupDirectory `
    -ProtectedRoot $paths.ProtectedRoot)
$result = $null
$repairEligible = $false
$currentAclSnapshot = $null
try {
    $result = Assert-AIChatManifestRollbackComplete `
        -Manifest $journal `
        -Paths $paths `
        -BackupDirectory $backupDirectory
} catch {
    # Do not classify an arbitrary verifier error as repairable. Re-run every
    # non-ACL invariant, then require a real ACL mismatch from the exact live
    # tree and both sides of the fixed repair allowlist.
    $nonAcl = Assert-AIChatManifestRollbackNonAclComplete `
        -Manifest $journal `
        -Paths $paths `
        -BackupDirectory $backupDirectory
    if ([int]$nonAcl.schema_version -ne 3 -or [string]$nonAcl.task_mode -ne "managed") {
        throw
    }
    $currentAclSnapshot = Get-AIChatConnectorDataAclSnapshot `
        -Path $paths.ConnectorDataRoot
    [void](Assert-AIChatConnectorDataAclRepairEligible `
        -Expected $journal.connector_data_acl `
        -Actual $currentAclSnapshot)
    $repairEligible = $true
    $result = [pscustomobject][ordered]@{
        transaction_id = [string]$nonAcl.transaction_id
        schema_version = [int]$nonAcl.schema_version
        file_targets_exact = [bool]$nonAcl.file_targets_exact
        task_mode = [string]$nonAcl.task_mode
        task_snapshot_exact = [bool]$nonAcl.task_snapshot_exact
        task_untouched = [bool]$nonAcl.task_untouched
        task_scheduler_accessed = [bool]$nonAcl.task_scheduler_accessed
        connector_data_acl_exact = $false
        live_release_absent = [bool]$nonAcl.live_release_absent
        staging_absent = [bool]$nonAcl.staging_absent
        failed_release_preserved = [bool]$nonAcl.failed_release_preserved
    }
}

function Write-AIChatRecoveryResult {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][bool]$RollbackExact
    )
    Write-Host "transaction_id=$($Value.transaction_id)"
    Write-Host "journal_schema=$($Value.schema_version)"
    Write-Host "file_targets_exact=$($Value.file_targets_exact.ToString().ToLowerInvariant())"
    Write-Host "task_snapshot_exact=$($Value.task_snapshot_exact.ToString().ToLowerInvariant())"
    Write-Host "task_mode=$($Value.task_mode)"
    Write-Host "task_untouched=$($Value.task_untouched.ToString().ToLowerInvariant())"
    Write-Host "task_scheduler_accessed=$($Value.task_scheduler_accessed.ToString().ToLowerInvariant())"
    Write-Host "connector_data_acl_exact=$($Value.connector_data_acl_exact.ToString().ToLowerInvariant())"
    Write-Host "live_release_absent=$($Value.live_release_absent.ToString().ToLowerInvariant())"
    Write-Host "staging_absent=$($Value.staging_absent.ToString().ToLowerInvariant())"
    Write-Host "failed_release_preserved=$($Value.failed_release_preserved.ToString().ToLowerInvariant())"
    Write-Host "rollback_exact=$($RollbackExact.ToString().ToLowerInvariant())"
}

if ($repairEligible) {
    if ($Finalize) {
        throw "Transaction finalization is blocked until Connector ACL repair is completed and reverified"
    }
    if (-not $RepairConnectorAcl -or $WhatIfPreference) {
        Write-AIChatRecoveryResult -Value $result -RollbackExact $false
        Write-Host "rollback_non_acl_exact=true"
        Write-Host "repair_ready=true"
        Write-Host "acl_repaired=false"
        Write-Host "finalize_performed=false"
        Write-Host "mutation_performed=false"
        Write-Host "journal_retained=true"
        Write-Host "connector_state_mutated=false"
        Write-Host "connector_state_content_mutated=false"
        Write-Host "connector_acl_mutated=false"
        exit 0
    }

    # Revalidate immediately before the only mutation, including Task and all
    # protected deployment targets. Re-read the journal only after proving its
    # original SHA-256 is unchanged; the ACL and file-content snapshots must
    # also be stable since the initial repair classification.
    $journal = Read-AIChatRecoveryJournalUnchanged `
        -Path $paths.TransactionPath `
        -ProtectedRoot $paths.ProtectedRoot `
        -ExpectedSha256 $journalHash
    [void](Assert-AIChatManifestRollbackNonAclComplete `
        -Manifest $journal `
        -Paths $paths `
        -BackupDirectory $backupDirectory)
    $aclBeforeMutation = Get-AIChatConnectorDataAclSnapshot `
        -Path $paths.ConnectorDataRoot
    Assert-AIChatConnectorDataAclMatchesSnapshot `
        -Expected $currentAclSnapshot `
        -Actual $aclBeforeMutation
    [void](Assert-AIChatConnectorDataAclRepairEligible `
        -Expected $journal.connector_data_acl `
        -Actual $aclBeforeMutation)
    $contentBefore = Get-AIChatConnectorDataContentSnapshot `
        -Path $paths.ConnectorDataRoot
    Assert-AIChatConnectorDataContentMatchesSnapshot `
        -Expected $contentBefore `
        -Actual (Get-AIChatConnectorDataContentSnapshot -Path $paths.ConnectorDataRoot)

    # The helper uses only the no-SACL Owner+DACL native restore. If restore or
    # any post-repair verification fails after a partial prefix was applied,
    # it compensates to the exact pre-mutation ACL snapshot and proves
    # content plus all non-ACL invariants again before returning an error.
    try {
        $result = Invoke-AIChatConnectorDataAclSnapshotRepair `
            -ExpectedSnapshot $journal.connector_data_acl `
            -CurrentSnapshot $aclBeforeMutation `
            -Path $paths.ConnectorDataRoot `
            -PostRepairVerifier {
                Assert-AIChatConnectorDataContentMatchesSnapshot `
                    -Expected $contentBefore `
                    -Actual (Get-AIChatConnectorDataContentSnapshot -Path $paths.ConnectorDataRoot)
                $verifiedJournal = Read-AIChatRecoveryJournalUnchanged `
                    -Path $paths.TransactionPath `
                    -ProtectedRoot $paths.ProtectedRoot `
                    -ExpectedSha256 $journalHash
                return Assert-AIChatManifestRollbackComplete `
                    -Manifest $verifiedJournal `
                    -Paths $paths `
                    -BackupDirectory $backupDirectory
            } `
            -PostCompensationVerifier {
                Assert-AIChatConnectorDataContentMatchesSnapshot `
                    -Expected $contentBefore `
                    -Actual (Get-AIChatConnectorDataContentSnapshot -Path $paths.ConnectorDataRoot)
                $verifiedJournal = Read-AIChatRecoveryJournalUnchanged `
                    -Path $paths.TransactionPath `
                    -ProtectedRoot $paths.ProtectedRoot `
                    -ExpectedSha256 $journalHash
                [void](Assert-AIChatManifestRollbackNonAclComplete `
                    -Manifest $verifiedJournal `
                    -Paths $paths `
                    -BackupDirectory $backupDirectory)
            }
    } catch {
        $repairMessage = $_.Exception.Message
        try {
            [void](Read-AIChatRecoveryJournalUnchanged `
                -Path $paths.TransactionPath `
                -ProtectedRoot $paths.ProtectedRoot `
                -ExpectedSha256 $journalHash)
        } catch {
            throw "Connector ACL repair failed and the transaction journal also changed; journal remains blocking; repair_error=$repairMessage; journal_error=$($_.Exception.Message)"
        }
        throw "Connector ACL repair did not complete; original journal remains blocking and byte-identical; repair_error=$repairMessage"
    }
    [void](Read-AIChatRecoveryJournalUnchanged `
        -Path $paths.TransactionPath `
        -ProtectedRoot $paths.ProtectedRoot `
        -ExpectedSha256 $journalHash)
    Write-AIChatRecoveryResult -Value $result -RollbackExact $true
    Write-Host "rollback_non_acl_exact=true"
    Write-Host "repair_ready=false"
    Write-Host "acl_repaired=true"
    Write-Host "finalize_performed=false"
    Write-Host "mutation_performed=true"
    Write-Host "journal_retained=true"
    Write-Host "token_read=false"
    Write-Host "task_write_attempted=false"
    Write-Host "connector_state_mutated=false"
    Write-Host "connector_state_content_mutated=false"
    Write-Host "connector_acl_mutated=true"
    exit 0
}

if ($RepairConnectorAcl) {
    throw "Connector data ACL already matches its rollback snapshot; no repair is allowed"
}

Write-AIChatRecoveryResult -Value $result -RollbackExact $true
Write-Host "rollback_non_acl_exact=true"
Write-Host "repair_ready=false"
Write-Host "acl_repaired=false"
Write-Host "finalize_performed=false"

if (-not $Finalize -or -not $Apply -or $WhatIfPreference) {
    Write-Host "finalize_requested=$($Finalize.ToString().ToLowerInvariant())"
    Write-Host "mutation_performed=false"
    Write-Host "journal_retained=true"
    Write-Host "connector_state_mutated=false"
    Write-Host "connector_state_content_mutated=false"
    Write-Host "connector_acl_mutated=false"
    exit 0
}

$archivePath = Join-Path $backupDirectory "rollback-incomplete.finalized.json"
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
$journal = Read-AIChatRecoveryJournalUnchanged `
    -Path $paths.TransactionPath `
    -ProtectedRoot $paths.ProtectedRoot `
    -ExpectedSha256 $journalHash
[void](Assert-AIChatManifestRollbackComplete `
    -Manifest $journal `
    -Paths $paths `
    -BackupDirectory $backupDirectory)

Remove-Item -LiteralPath $paths.TransactionPath -Force
Write-Host "transaction_abandoned=true"
Write-Host "journal_archived=true"
Write-Host "journal_retained=false"
Write-Host "finalize_performed=true"
Write-Host "mutation_performed=true"
Write-Host "token_read=false"
Write-Host "task_write_attempted=false"
Write-Host "connector_state_mutated=false"
Write-Host "connector_state_content_mutated=false"
Write-Host "connector_acl_mutated=false"

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [switch]$Finalize,
    [switch]$RepairConnectorAcl,
    [switch]$Apply,
    [string]$OutputFormat = "Human"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AIChatRecoveryJsonMode = $OutputFormat -ine "Human"
$script:AIChatRecoveryJsonEmitted = $false
$script:AIChatRecoveryOperation = if ($RepairConnectorAcl) {
    "repair"
} elseif ($Finalize) {
    "finalize"
} else {
    "verify"
}
$script:AIChatRecoveryMode = if ($WhatIfPreference) {
    "what_if"
} elseif ($Apply) {
    "apply"
} else {
    "read_only"
}
$script:AIChatRecoveryStage = "arguments"
$script:AIChatRecoveryMutationPerformed = $false
$script:AIChatRecoveryJournalRetained = $true
$script:AIChatRecoveryConnectorAclMutated = $false

function Write-AIChatRecoveryHuman {
    param([Parameter(Mandatory = $true)][string]$Message)
    if (-not $script:AIChatRecoveryJsonMode) {
        Write-Host $Message
    }
}

function ConvertTo-AIChatAsciiJson {
    param([Parameter(Mandatory = $true)]$Value)

    $raw = $Value | ConvertTo-Json -Compress -Depth 8
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $raw.ToCharArray()) {
        $code = [int][char]$character
        if ($code -gt 0x7f) {
            [void]$builder.Append(("\u{0:x4}" -f $code))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function Write-AIChatRecoveryJson {
    param([Parameter(Mandatory = $true)]$Value)

    if ($script:AIChatRecoveryJsonEmitted) {
        throw "Recovery JSON response was emitted more than once"
    }
    $serialized = ConvertTo-AIChatAsciiJson -Value $Value
    [Console]::Out.WriteLine($serialized)
    $script:AIChatRecoveryJsonEmitted = $true
}

function New-AIChatRecoveryJsonSuccess {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][bool]$RollbackExact,
        [Parameter(Mandatory = $true)][bool]$RepairReady,
        [Parameter(Mandatory = $true)][bool]$AclRepaired,
        [Parameter(Mandatory = $true)][bool]$FinalizePerformed,
        [Parameter(Mandatory = $true)][bool]$MutationPerformed,
        [Parameter(Mandatory = $true)][bool]$JournalRetained,
        [Parameter(Mandatory = $true)][bool]$ConnectorAclMutated,
        [bool]$FinalizeRequested = $false
    )

    return [pscustomobject][ordered]@{
        contract_version = 1
        operation = $script:AIChatRecoveryOperation
        mode = $script:AIChatRecoveryMode
        success = $true
        status = $Status
        transaction_id = [string]$Value.transaction_id
        journal_schema = [int]$Value.schema_version
        file_targets_exact = [bool]$Value.file_targets_exact
        task_snapshot_exact = [bool]$Value.task_snapshot_exact
        task_mode = [string]$Value.task_mode
        task_untouched = [bool]$Value.task_untouched
        task_scheduler_accessed = [bool]$Value.task_scheduler_accessed
        connector_data_acl_exact = [bool]$Value.connector_data_acl_exact
        live_release_absent = [bool]$Value.live_release_absent
        staging_absent = [bool]$Value.staging_absent
        failed_release_preserved = [bool]$Value.failed_release_preserved
        rollback_exact = $RollbackExact
        rollback_non_acl_exact = $true
        repair_ready = $RepairReady
        acl_repaired = $AclRepaired
        finalize_requested = $FinalizeRequested
        finalize_performed = $FinalizePerformed
        mutation_performed = $MutationPerformed
        journal_retained = $JournalRetained
        token_read = $false
        task_write_attempted = $false
        connector_state_mutated = $false
        connector_state_content_mutated = $false
        connector_acl_mutated = $ConnectorAclMutated
    }
}

function Complete-AIChatRecoverySuccess {
    param([Parameter(Mandatory = $true)]$Value)
    if ($script:AIChatRecoveryJsonMode) {
        Write-AIChatRecoveryJson -Value $Value
    }
    exit 0
}

function Assert-AIChatRecoveryArguments {
    if ($RepairConnectorAcl -and $Finalize) {
        throw "Connector ACL repair and transaction finalization must be separate operations"
    }
    if ($RepairConnectorAcl -and -not $Apply) {
        throw "Connector ACL repair requires both -RepairConnectorAcl and -Apply"
    }
    if ($Apply -and -not $RepairConnectorAcl -and -not $Finalize) {
        throw "-Apply requires either -RepairConnectorAcl or -Finalize"
    }
}

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

try {
if ($OutputFormat -ine "Human" -and $OutputFormat -ine "Json") {
    throw "OutputFormat must be Human or Json"
}
if ($script:AIChatRecoveryJsonMode) {
    Assert-AIChatRecoveryArguments
}

$script:AIChatRecoveryStage = "initialization"
. (Join-Path $PSScriptRoot "common.ps1")
$paths = Get-AIChatConnectorPaths
Write-AIChatRecoveryHuman "state_root=$($paths.StateRoot)"
Write-AIChatRecoveryHuman "task=\AIChat\CodexConnector"
Write-AIChatRecoveryHuman "token_read=false"
Write-AIChatRecoveryHuman "task_write_attempted=false"

if (-not $script:AIChatRecoveryJsonMode) {
    Assert-AIChatRecoveryArguments
}

$script:AIChatRecoveryStage = "verification"
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
    Write-AIChatRecoveryHuman "transaction_id=$($Value.transaction_id)"
    Write-AIChatRecoveryHuman "journal_schema=$($Value.schema_version)"
    Write-AIChatRecoveryHuman "file_targets_exact=$($Value.file_targets_exact.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "task_snapshot_exact=$($Value.task_snapshot_exact.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "task_mode=$($Value.task_mode)"
    Write-AIChatRecoveryHuman "task_untouched=$($Value.task_untouched.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "task_scheduler_accessed=$($Value.task_scheduler_accessed.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "connector_data_acl_exact=$($Value.connector_data_acl_exact.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "live_release_absent=$($Value.live_release_absent.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "staging_absent=$($Value.staging_absent.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "failed_release_preserved=$($Value.failed_release_preserved.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "rollback_exact=$($RollbackExact.ToString().ToLowerInvariant())"
}

if ($repairEligible) {
    if ($Finalize) {
        throw "Transaction finalization is blocked until Connector ACL repair is completed and reverified"
    }
    if (-not $RepairConnectorAcl -or $WhatIfPreference) {
        Write-AIChatRecoveryResult -Value $result -RollbackExact $false
        Write-AIChatRecoveryHuman "rollback_non_acl_exact=true"
        Write-AIChatRecoveryHuman "repair_ready=true"
        Write-AIChatRecoveryHuman "acl_repaired=false"
        Write-AIChatRecoveryHuman "finalize_performed=false"
        Write-AIChatRecoveryHuman "mutation_performed=false"
        Write-AIChatRecoveryHuman "journal_retained=true"
        Write-AIChatRecoveryHuman "connector_state_mutated=false"
        Write-AIChatRecoveryHuman "connector_state_content_mutated=false"
        Write-AIChatRecoveryHuman "connector_acl_mutated=false"
        Complete-AIChatRecoverySuccess -Value (New-AIChatRecoveryJsonSuccess `
            -Value $result `
            -Status "repair_ready" `
            -RollbackExact $false `
            -RepairReady $true `
            -AclRepaired $false `
            -FinalizePerformed $false `
            -MutationPerformed $false `
            -JournalRetained $true `
            -ConnectorAclMutated $false)
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
    $script:AIChatRecoveryStage = "repair_apply"
    $script:AIChatRecoveryMutationPerformed = $true
    $script:AIChatRecoveryConnectorAclMutated = $true
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
    Write-AIChatRecoveryHuman "rollback_non_acl_exact=true"
    Write-AIChatRecoveryHuman "repair_ready=false"
    Write-AIChatRecoveryHuman "acl_repaired=true"
    Write-AIChatRecoveryHuman "finalize_performed=false"
    Write-AIChatRecoveryHuman "mutation_performed=true"
    Write-AIChatRecoveryHuman "journal_retained=true"
    Write-AIChatRecoveryHuman "token_read=false"
    Write-AIChatRecoveryHuman "task_write_attempted=false"
    Write-AIChatRecoveryHuman "connector_state_mutated=false"
    Write-AIChatRecoveryHuman "connector_state_content_mutated=false"
    Write-AIChatRecoveryHuman "connector_acl_mutated=true"
    Complete-AIChatRecoverySuccess -Value (New-AIChatRecoveryJsonSuccess `
        -Value $result `
        -Status "acl_repaired" `
        -RollbackExact $true `
        -RepairReady $false `
        -AclRepaired $true `
        -FinalizePerformed $false `
        -MutationPerformed $true `
        -JournalRetained $true `
        -ConnectorAclMutated $true)
}

if ($RepairConnectorAcl) {
    throw "Connector data ACL already matches its rollback snapshot; no repair is allowed"
}

Write-AIChatRecoveryResult -Value $result -RollbackExact $true
Write-AIChatRecoveryHuman "rollback_non_acl_exact=true"
Write-AIChatRecoveryHuman "repair_ready=false"
Write-AIChatRecoveryHuman "acl_repaired=false"
Write-AIChatRecoveryHuman "finalize_performed=false"

if (-not $Finalize -or -not $Apply -or $WhatIfPreference) {
    Write-AIChatRecoveryHuman "finalize_requested=$($Finalize.ToString().ToLowerInvariant())"
    Write-AIChatRecoveryHuman "mutation_performed=false"
    Write-AIChatRecoveryHuman "journal_retained=true"
    Write-AIChatRecoveryHuman "connector_state_mutated=false"
    Write-AIChatRecoveryHuman "connector_state_content_mutated=false"
    Write-AIChatRecoveryHuman "connector_acl_mutated=false"
    $readOnlyStatus = if ($Finalize) { "finalize_ready" } else { "rollback_exact" }
    Complete-AIChatRecoverySuccess -Value (New-AIChatRecoveryJsonSuccess `
        -Value $result `
        -Status $readOnlyStatus `
        -RollbackExact $true `
        -RepairReady $false `
        -AclRepaired $false `
        -FinalizePerformed $false `
        -MutationPerformed $false `
        -JournalRetained $true `
        -ConnectorAclMutated $false `
        -FinalizeRequested ([bool]$Finalize))
}

$archivePath = Join-Path $backupDirectory "rollback-incomplete.finalized.json"
$script:AIChatRecoveryStage = "finalize_apply"
if (Test-Path -LiteralPath $archivePath) {
    [void](Assert-AIChatPrivateFile `
        -Path $archivePath `
        -ProtectedRoot $paths.ProtectedRoot)
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -ne $journalHash) {
        throw "Existing finalized rollback archive does not match the live journal"
    }
} else {
    $script:AIChatRecoveryMutationPerformed = $true
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
$script:AIChatRecoveryMutationPerformed = $true
$script:AIChatRecoveryJournalRetained = $false
Write-AIChatRecoveryHuman "transaction_abandoned=true"
Write-AIChatRecoveryHuman "journal_archived=true"
Write-AIChatRecoveryHuman "journal_retained=false"
Write-AIChatRecoveryHuman "finalize_performed=true"
Write-AIChatRecoveryHuman "mutation_performed=true"
Write-AIChatRecoveryHuman "token_read=false"
Write-AIChatRecoveryHuman "task_write_attempted=false"
Write-AIChatRecoveryHuman "connector_state_mutated=false"
Write-AIChatRecoveryHuman "connector_state_content_mutated=false"
Write-AIChatRecoveryHuman "connector_acl_mutated=false"
Complete-AIChatRecoverySuccess -Value (New-AIChatRecoveryJsonSuccess `
    -Value $result `
    -Status "finalized" `
    -RollbackExact $true `
    -RepairReady $false `
    -AclRepaired $false `
    -FinalizePerformed $true `
    -MutationPerformed $true `
    -JournalRetained $false `
    -ConnectorAclMutated $false `
    -FinalizeRequested $true)
} catch {
    if (-not $script:AIChatRecoveryJsonMode) {
        throw
    }
    $errorCode = switch ($script:AIChatRecoveryStage) {
        "arguments" { "invalid_arguments"; break }
        "initialization" { "initialization_failed"; break }
        "repair_apply" { "acl_repair_failed"; break }
        "finalize_apply" { "finalization_failed"; break }
        "verification" { "verification_failed"; break }
        default { "internal_error"; break }
    }
    $failure = [pscustomobject][ordered]@{
        contract_version = 1
        operation = $script:AIChatRecoveryOperation
        mode = $script:AIChatRecoveryMode
        success = $false
        status = $errorCode
        error_code = $errorCode
        mutation_performed = [bool]$script:AIChatRecoveryMutationPerformed
        journal_retained = [bool]$script:AIChatRecoveryJournalRetained
        token_read = $false
        task_write_attempted = $false
        connector_state_mutated = $false
        connector_state_content_mutated = $false
        connector_acl_mutated = [bool]$script:AIChatRecoveryConnectorAclMutated
        finalize_performed = $false
    }
    Write-AIChatRecoveryJson -Value $failure
    exit 1
}

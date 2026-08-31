[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This functional test requires Windows PowerShell"
}
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This functional test must run under Windows PowerShell 5.1"
}

$serviceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\connector-service")).Path
. (Join-Path $serviceRoot "common.ps1")

$snapshotAbsent = [pscustomobject][ordered]@{
    schema_version = 1
    existed = $false
    private_root_existed = $false
    entries = @()
}
$snapshotPrivateRootOnly = [pscustomobject][ordered]@{
    schema_version = 1
    existed = $false
    private_root_existed = $true
    entries = @()
}
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $snapshotAbsent `
    -Actual $snapshotAbsent
$aclMismatchBlocked = $false
try {
    Assert-AIChatConnectorDataAclMatchesSnapshot `
        -Expected $snapshotAbsent `
        -Actual $snapshotPrivateRootOnly
} catch {
    $aclMismatchBlocked = $true
}
if (-not $aclMismatchBlocked) {
    throw "ACL snapshot mismatch was not blocked"
}

# Exact task snapshots must return before any Schedule.Service write object is
# created. Override only inside this isolated PowerShell process.
$script:mockTask = [pscustomobject]@{ Xml = "<Task>prior</Task>" }
function Get-AIChatConnectorTask { return $script:mockTask }
function Assert-AIChatTaskContract { param($Task, $Paths) }
function New-Object { throw "Task Scheduler write path was reached" }
$taskSnapshot = [pscustomobject]@{
    existed = $true
    enabled = $false
    xml = "<Task>prior</Task>"
    xml_sha256 = Get-AIChatSha256Text -Value "<Task>prior</Task>"
}
Restore-AIChatTaskSnapshot -Snapshot $taskSnapshot -Paths ([pscustomobject]@{})
$script:mockTask = $null
Restore-AIChatTaskSnapshot `
    -Snapshot ([pscustomobject]@{ existed = $false }) `
    -Paths ([pscustomobject]@{})

# Restore cmdlet resolution for the filesystem-backed verifier below.
Remove-Item Function:\New-Object
$testId = [Guid]::NewGuid().ToString("N")
$protectedRoot = Get-AIChatProtectedRoot
$stateRoot = Join-Path $protectedRoot "ci-transaction-recovery-$testId"
$paths = [pscustomobject]@{
    ProtectedRoot = $protectedRoot
    StateRoot = $stateRoot
    CommonPath = Join-Path $stateRoot "common.ps1"
    LauncherPath = Join-Path $stateRoot "launcher.ps1"
    SettingsPath = Join-Path $stateRoot "settings.json"
    MappingStatePath = Join-Path $stateRoot "mapping-state.json"
    ActiveReleasePath = Join-Path $stateRoot "active-release.json"
    ReleasesDirectory = Join-Path $stateRoot "releases"
    BackupsDirectory = Join-Path $stateRoot "backups"
    StagingDirectory = Join-Path $stateRoot "staging"
    ConnectorDataRoot = Join-Path $stateRoot "unused-connector-data"
}
try {
    [void](Initialize-AIChatPrivateDirectory -Path $stateRoot -ProtectedRoot $protectedRoot)
    foreach ($directory in @($paths.ReleasesDirectory, $paths.BackupsDirectory, $paths.StagingDirectory)) {
        [void](Initialize-AIChatPrivateDirectory -Path $directory -ProtectedRoot $protectedRoot)
    }
    $transactionId = "20260831T000000Z-1234abcd"
    $backupDirectory = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $paths.BackupsDirectory $transactionId) `
        -ProtectedRoot $protectedRoot
    $files = @(
        "common", "launcher", "settings", "mapping_state", "active_release"
    ) | ForEach-Object { [pscustomobject]@{ id = $_; existed = $false } }
    $manifest = [pscustomobject][ordered]@{
        schema_version = 3
        kind = "aichat-windows-connector-transaction"
        transaction_id = $transactionId
        status = "rollback_incomplete"
        files = $files
        task = [pscustomobject]@{ existed = $false }
        new_release_id = $transactionId
        connector_data_acl = $snapshotAbsent
    }
    $result = Assert-AIChatManifestRollbackComplete `
        -Manifest $manifest `
        -Paths $paths `
        -BackupDirectory $backupDirectory `
        -TaskProvider { $null } `
        -ConnectorDataAclSnapshotProvider { $snapshotAbsent }
    if (-not $result.file_targets_exact -or -not $result.task_snapshot_exact) {
        throw "Exact rollback was not accepted"
    }
    if ([string]$result.task_mode -ne "managed" -or
        $result.task_untouched -or
        -not $result.task_scheduler_accessed) {
        throw "Schema-v3 managed recovery did not report exact task verification"
    }

    Write-AIChatPrivateJson `
        -Path $paths.SettingsPath `
        -Value ([pscustomobject]@{ changed = $true }) `
        -ProtectedRoot $protectedRoot
    $targetMismatchBlocked = $false
    try {
        [void](Assert-AIChatManifestRollbackComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider { $null } `
            -ConnectorDataAclSnapshotProvider { $snapshotAbsent })
    } catch {
        $targetMismatchBlocked = $true
    }
    if (-not $targetMismatchBlocked) {
        throw "Unexpected rollback target was not blocked"
    }

    if (Test-Path -LiteralPath $paths.SettingsPath) {
        Remove-Item -LiteralPath $paths.SettingsPath -Force
    }

    # Stage-only recovery is checked twice to model the read-only verification
    # and the immediate pre-finalization revalidation. The throwing provider
    # proves neither pass can query Task Scheduler.
    $manifest.schema_version = 4
    $manifest.task = [pscustomobject]@{ mode = "untouched" }
    $taskAccessAttempts = 0
    $denyTaskProvider = {
        $taskAccessAttempts += 1
        throw "Stage-only recovery accessed Task Scheduler"
    }
    foreach ($pass in 1..2) {
        $stageOnlyResult = Assert-AIChatManifestRollbackComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider $denyTaskProvider `
            -ConnectorDataAclSnapshotProvider { $snapshotAbsent }
        if ([string]$stageOnlyResult.task_mode -ne "untouched" -or
            -not $stageOnlyResult.task_untouched -or
            $stageOnlyResult.task_snapshot_exact -or
            $stageOnlyResult.task_scheduler_accessed) {
            throw "Schema-v4 untouched recovery reported an invalid task boundary"
        }
    }
    if ($taskAccessAttempts -ne 0) {
        throw "Schema-v4 untouched recovery invoked its TaskProvider"
    }

    $manifest.task = [pscustomobject]@{ mode = "managed"; existed = $false }
    $v4ManagedBlocked = $false
    try {
        [void](Assert-AIChatManifestRollbackComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider $denyTaskProvider `
            -ConnectorDataAclSnapshotProvider { $snapshotAbsent })
    } catch {
        $v4ManagedBlocked = $_.Exception.Message -match "schema-v3 managed or schema-v4 untouched"
    }
    if (-not $v4ManagedBlocked -or $taskAccessAttempts -ne 0) {
        throw "Schema-v4 managed recovery did not fail closed before TaskProvider access"
    }

    $manifest.task = [pscustomobject][ordered]@{
        mode = "untouched"
        existed = $false
    }
    $v4ExtraTaskPropertyBlocked = $false
    try {
        [void](Assert-AIChatManifestRollbackComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider $denyTaskProvider `
            -ConnectorDataAclSnapshotProvider { $snapshotAbsent })
    } catch {
        $v4ExtraTaskPropertyBlocked = $_.Exception.Message -match "must not contain a Scheduled Task snapshot"
    }
    if (-not $v4ExtraTaskPropertyBlocked -or $taskAccessAttempts -ne 0) {
        throw "Schema-v4 extra task properties did not fail closed before TaskProvider access"
    }

    $manifest.schema_version = 2
    $manifest.task = [pscustomobject]@{ existed = $false }
    $manifest.PSObject.Properties.Remove("connector_data_acl")
    $v2Blocked = $false
    try {
        [void](Assert-AIChatManifestRollbackComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider { $null } `
            -ConnectorDataAclSnapshotProvider { $snapshotAbsent })
    } catch {
        $v2Blocked = $_.Exception.Message -match "schema-v3 managed or schema-v4 untouched"
    }
    if (-not $v2Blocked) {
        throw "Historical schema-v2 journal was not left fail-closed"
    }
} finally {
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
}

Write-Host "transaction_recovery_tests=pass"

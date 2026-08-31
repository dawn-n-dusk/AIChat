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

function New-TestAclEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][bool]$IsDirectory,
        [Parameter(Mandatory = $true)][string]$Sddl
    )

    return [pscustomobject][ordered]@{
        name = $Name
        is_directory = $IsDirectory
        sddl = $Sddl
        sddl_sha256 = Get-AIChatSha256Text -Value $Sddl
    }
}

function New-TestAclSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$RootSddl,
        [Parameter(Mandatory = $true)][string]$FileSddl,
        [string]$FileName = "state.json"
    )

    return [pscustomobject][ordered]@{
        schema_version = 1
        existed = $true
        private_root_existed = $true
        entries = @(
            New-TestAclEntry -Name "." -IsDirectory $true -Sddl $RootSddl
            New-TestAclEntry -Name $FileName -IsDirectory $false -Sddl $FileSddl
        )
    }
}

function Assert-TestAclRepairBlocked {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $blocked = $false
    try {
        [void](Assert-AIChatConnectorDataAclRepairEligible `
            -Expected $Expected `
            -Actual $Actual)
    } catch {
        $blocked = $true
    }
    if (-not $blocked) {
        throw "ACL repair eligibility accepted $Label"
    }
}

# ACL repair accepts only a trusted forward current state and a fixed prior
# contract. These are synthetic owner/DACL snapshots; no live ACL is touched.
$currentSid = Get-AIChatCurrentSid
$forwardRoot = "O:$($currentSid)D:P(A;OICI;FA;;;$($currentSid))(A;OICI;FA;;;SY)"
$forwardFile = "O:$($currentSid)D:P(A;;FA;;;$($currentSid))(A;;FA;;;SY)"
$forwardSnapshot = New-TestAclSnapshot `
    -RootSddl $forwardRoot `
    -FileSddl $forwardFile
$legacyRoot = "O:$($currentSid)D:P(A;OICI;FA;;;$($currentSid))"
$legacyFile = "O:$($currentSid)D:P(A;;FA;;;$($currentSid))"
$legacySnapshot = New-TestAclSnapshot `
    -RootSddl $legacyRoot `
    -FileSddl $legacyFile
[void](Assert-AIChatConnectorDataAclRepairEligible `
    -Expected $legacySnapshot `
    -Actual $forwardSnapshot)

$reversePairSnapshot = New-TestAclSnapshot `
    -RootSddl "O:$($currentSid)D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;$($currentSid))" `
    -FileSddl "O:$($currentSid)D:P(A;;FA;;;SY)(A;;FA;;;$($currentSid))"
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $reversePairSnapshot `
    -Actual $forwardSnapshot
Assert-TestAclRepairBlocked `
    -Expected $reversePairSnapshot `
    -Actual $forwardSnapshot `
    -Label "an already-equivalent all-Allow ACE order"

$textAliasSnapshot = New-TestAclSnapshot `
    -RootSddl "O:$($currentSid)D:P(A;CIOI;0x1f01ff;;;$($script:AIChatLocalSystemSid))(A;CIOI;0x1f01ff;;;$($currentSid))" `
    -FileSddl "O:$($currentSid)D:P(A;;0x1f01ff;;;$($script:AIChatLocalSystemSid))(A;;0x1f01ff;;;$($currentSid))"
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $textAliasSnapshot `
    -Actual $forwardSnapshot
Assert-TestAclRepairBlocked `
    -Expected $textAliasSnapshot `
    -Actual $forwardSnapshot `
    -Label "an already-equivalent SDDL alias representation"

$inheritedLegacySnapshot = New-TestAclSnapshot `
    -RootSddl "O:$($currentSid)D:AI(A;OICIID;FA;;;$($currentSid))" `
    -FileSddl "O:$($currentSid)D:AI(A;ID;FA;;;$($currentSid))"
[void](Assert-AIChatConnectorDataAclRepairEligible `
    -Expected $inheritedLegacySnapshot `
    -Actual $forwardSnapshot)

Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual $legacySnapshot `
    -Label "a legacy current-only live ACL"
Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual (New-TestAclSnapshot `
        -RootSddl "O:$($currentSid)D:AI(A;OICIID;FA;;;$($currentSid))(A;OICIID;FA;;;SY)" `
        -FileSddl "O:$($currentSid)D:AI(A;ID;FA;;;$($currentSid))(A;ID;FA;;;SY)") `
    -Label "an inherited live ACL"
Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual (New-TestAclSnapshot `
        -RootSddl "O:$($currentSid)D:P(D;OICI;FA;;;$($currentSid))(A;OICI;FA;;;SY)" `
        -FileSddl "O:$($currentSid)D:P(D;;FA;;;$($currentSid))(A;;FA;;;SY)") `
    -Label "a deny ACE"
Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual (New-TestAclSnapshot `
        -RootSddl "O:$($currentSid)D:P(A;OICI;FR;;;$($currentSid))(A;OICI;FA;;;SY)" `
        -FileSddl "O:$($currentSid)D:P(A;;FR;;;$($currentSid))(A;;FA;;;SY)") `
    -Label "non-FullControl rights"
Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual (New-TestAclSnapshot `
        -RootSddl "O:SYD:P(A;OICI;FA;;;$($currentSid))(A;OICI;FA;;;SY)" `
        -FileSddl "O:SYD:P(A;;FA;;;$($currentSid))(A;;FA;;;SY)") `
    -Label "a non-current owner"
Assert-TestAclRepairBlocked `
    -Expected $legacySnapshot `
    -Actual (New-TestAclSnapshot `
        -RootSddl "O:$($currentSid)D:P(A;OICI;FA;;;$($currentSid))(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)" `
        -FileSddl "O:$($currentSid)D:P(A;;FA;;;$($currentSid))(A;;FA;;;SY)(A;;FA;;;BA)") `
    -Label "an extra live principal"
Assert-TestAclRepairBlocked `
    -Expected (New-TestAclSnapshot `
        -RootSddl "O:$($currentSid)D:P(A;OICI;FA;;;$($currentSid))(A;OICI;FA;;;BA)" `
        -FileSddl "O:$($currentSid)D:P(A;;FA;;;$($currentSid))(A;;FA;;;BA)") `
    -Actual $forwardSnapshot `
    -Label "an untrusted snapshot principal"
Assert-TestAclRepairBlocked `
    -Expected (New-TestAclSnapshot `
        -RootSddl $legacyRoot `
        -FileSddl $legacyFile `
        -FileName "other.json") `
    -Actual $forwardSnapshot `
    -Label "a changed connector data entry set"

# Failure injection proves a partial prefix is compensated to the exact
# pre-mutation snapshot, and that a hard-interruption mixed state is itself a
# safe, recognizable input for the next idempotent repair attempt.
$mixedSnapshot = New-TestAclSnapshot `
    -RootSddl ([string]$inheritedLegacySnapshot.entries[0].sddl) `
    -FileSddl $forwardFile
$script:syntheticAclSnapshot = $forwardSnapshot
$script:syntheticRestoreCalls = 0
$partialFailureRestore = {
    param($TargetSnapshot, $Path, $AllowedSnapshots)
    $script:syntheticRestoreCalls += 1
    if ($script:syntheticRestoreCalls -eq 1) {
        $script:syntheticAclSnapshot = $mixedSnapshot
        throw "injected partial restore failure"
    }
    $script:syntheticAclSnapshot = $TargetSnapshot
}
$syntheticSnapshotProvider = {
    param($Path)
    return $script:syntheticAclSnapshot
}
$partialFailureBlocked = $false
try {
    [void](Invoke-AIChatConnectorDataAclSnapshotRepair `
        -ExpectedSnapshot $inheritedLegacySnapshot `
        -CurrentSnapshot $forwardSnapshot `
        -Path "synthetic" `
        -RestoreInvoker $partialFailureRestore `
        -SnapshotProvider $syntheticSnapshotProvider)
} catch {
    $partialFailureBlocked = $_.Exception.Message -match "exact pre-repair ACL restored"
}
if (-not $partialFailureBlocked -or $script:syntheticRestoreCalls -ne 2) {
    throw "Partial ACL restore did not compensate and fail closed"
}
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $forwardSnapshot `
    -Actual $script:syntheticAclSnapshot

$script:syntheticAclSnapshot = $forwardSnapshot
$script:syntheticRestoreCalls = 0
$doubleFailureRestore = {
    param($TargetSnapshot, $Path, $AllowedSnapshots)
    $script:syntheticRestoreCalls += 1
    if ($script:syntheticRestoreCalls -eq 1) {
        $script:syntheticAclSnapshot = $mixedSnapshot
        throw "injected primary restore failure"
    }
    throw "injected compensation failure"
}
$doubleFailureBlocked = $false
try {
    [void](Invoke-AIChatConnectorDataAclSnapshotRepair `
        -ExpectedSnapshot $inheritedLegacySnapshot `
        -CurrentSnapshot $forwardSnapshot `
        -Path "synthetic" `
        -RestoreInvoker $doubleFailureRestore `
        -SnapshotProvider $syntheticSnapshotProvider)
} catch {
    $doubleFailureBlocked = $_.Exception.Message -match "compensation failed; journal retained"
}
if (-not $doubleFailureBlocked -or $script:syntheticRestoreCalls -ne 2) {
    throw "Double ACL restore failure did not preserve the fail-closed boundary"
}

$script:syntheticAclSnapshot = $mixedSnapshot
$resumeRestore = {
    param($TargetSnapshot, $Path, $AllowedSnapshots)
    $script:syntheticAclSnapshot = $TargetSnapshot
}
$resumedResult = Invoke-AIChatConnectorDataAclSnapshotRepair `
    -ExpectedSnapshot $inheritedLegacySnapshot `
    -CurrentSnapshot $mixedSnapshot `
    -Path "synthetic" `
    -RestoreInvoker $resumeRestore `
    -SnapshotProvider $syntheticSnapshotProvider
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $inheritedLegacySnapshot `
    -Actual $resumedResult

$script:syntheticAclSnapshot = $forwardSnapshot
$script:syntheticRestoreCalls = 0
$postVerifyFailureRestore = {
    param($TargetSnapshot, $Path, $AllowedSnapshots)
    $script:syntheticRestoreCalls += 1
    $script:syntheticAclSnapshot = $TargetSnapshot
}
$postVerifyFailureBlocked = $false
try {
    [void](Invoke-AIChatConnectorDataAclSnapshotRepair `
        -ExpectedSnapshot $inheritedLegacySnapshot `
        -CurrentSnapshot $forwardSnapshot `
        -Path "synthetic" `
        -RestoreInvoker $postVerifyFailureRestore `
        -SnapshotProvider $syntheticSnapshotProvider `
        -PostRepairVerifier { throw "injected post-repair verifier failure" })
} catch {
    $postVerifyFailureBlocked = $_.Exception.Message -match "exact pre-repair ACL restored"
}
if (-not $postVerifyFailureBlocked -or $script:syntheticRestoreCalls -ne 2) {
    throw "Post-repair verifier failure did not compensate and fail closed"
}
Assert-AIChatConnectorDataAclMatchesSnapshot `
    -Expected $forwardSnapshot `
    -Actual $script:syntheticAclSnapshot

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

    $taskMismatchBlocked = $false
    try {
        [void](Assert-AIChatManifestRollbackNonAclComplete `
            -Manifest $manifest `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -TaskProvider { [pscustomobject]@{ Xml = "<Task>unexpected</Task>" } })
    } catch {
        $taskMismatchBlocked = $true
    }
    if (-not $taskMismatchBlocked) {
        throw "Unexpected Scheduled Task state was not blocked before ACL repair"
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

    # Exercise the ACL-only native restore against an isolated connector-data
    # tree. The content hash must remain exact, the journal object is retained,
    # and the full schema-v3 verifier must pass after repair.
    $testProfile = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $stateRoot "acl-repair-profile") `
        -ProtectedRoot $protectedRoot
    $testPrivateRoot = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $testProfile ".aichat") `
        -ProtectedRoot $protectedRoot
    $testConnectorRoot = Join-Path $testPrivateRoot "connector-data"
    New-Item -ItemType Directory -Path $testConnectorRoot | Out-Null
    $testStateFile = Join-Path $testConnectorRoot "state.json"
    [IO.File]::WriteAllText(
        $testStateFile,
        '{"cursor":"unchanged"}',
        [Text.UTF8Encoding]::new($false)
    )
    $script:testAclRepairProfile = $testProfile
    $script:testAclRepairConnectorRoot = $testConnectorRoot
    function Get-AIChatUserProfile { return $script:testAclRepairProfile }
    function Get-AIChatConnectorDataRoot { return $script:testAclRepairConnectorRoot }

    # Capture the OS-canonical inherited legacy form before migrating the same
    # isolated tree to the forward ACL. Synthetic SDDL is used above only for
    # parser tests; native exact-restore coverage must use a real snapshot.
    $syntheticLegacyRootEntry = @($inheritedLegacySnapshot.entries | Where-Object {
        [string]$_.name -eq "."
    })[0]
    $syntheticLegacyFileEntry = @($inheritedLegacySnapshot.entries | Where-Object {
        [string]$_.name -eq "state.json"
    })[0]
    [AIChat.Windows.OwnerDacl]::RestoreSnapshot(
        $testConnectorRoot,
        [string]$syntheticLegacyRootEntry.sddl,
        $true
    )
    [AIChat.Windows.OwnerDacl]::RestoreSnapshot(
        $testStateFile,
        [string]$syntheticLegacyFileEntry.sddl,
        $false
    )
    $capturedLegacySnapshot = Get-AIChatConnectorDataAclSnapshot `
        -Path $testConnectorRoot
    Set-AIChatConnectorDataAcl -Path $testConnectorRoot
    Set-AIChatConnectorDataAcl -Path $testStateFile
    $currentForwardSnapshot = Get-AIChatConnectorDataAclSnapshot `
        -Path $testConnectorRoot
    $contentBeforeRepair = Get-AIChatConnectorDataContentSnapshot `
        -Path $testConnectorRoot

    # Model a process interruption after the root ACL was restored but before
    # the file ACL. The real transition-aware native path must recognize and
    # converge this mixed prefix on the next invocation.
    $expectedRootEntry = @($capturedLegacySnapshot.entries | Where-Object {
        [string]$_.name -eq "."
    })[0]
    [AIChat.Windows.OwnerDacl]::RestoreSnapshot(
        $testConnectorRoot,
        [string]$expectedRootEntry.sddl,
        $true
    )
    $mixedLiveSnapshot = Get-AIChatConnectorDataAclSnapshot `
        -Path $testConnectorRoot
    Assert-AIChatConnectorDataAclTransitionState `
        -Actual $mixedLiveSnapshot `
        -AllowedSnapshots @($currentForwardSnapshot, $capturedLegacySnapshot)
    $restoredSnapshot = Invoke-AIChatConnectorDataAclSnapshotRepair `
        -ExpectedSnapshot $capturedLegacySnapshot `
        -CurrentSnapshot $mixedLiveSnapshot `
        -Path $testConnectorRoot
    $contentAfterRepair = Get-AIChatConnectorDataContentSnapshot `
        -Path $testConnectorRoot
    Assert-AIChatConnectorDataContentMatchesSnapshot `
        -Expected $contentBeforeRepair `
        -Actual $contentAfterRepair
    Assert-AIChatConnectorDataAclMatchesSnapshot `
        -Expected $capturedLegacySnapshot `
        -Actual $restoredSnapshot

    $repairManifest = [pscustomobject][ordered]@{
        schema_version = 3
        kind = "aichat-windows-connector-transaction"
        transaction_id = $transactionId
        status = "rollback_incomplete"
        files = $files
        task = [pscustomobject]@{ existed = $false }
        new_release_id = $transactionId
        connector_data_acl = $capturedLegacySnapshot
    }
    $postRepairResult = Assert-AIChatManifestRollbackComplete `
        -Manifest $repairManifest `
        -Paths $paths `
        -BackupDirectory $backupDirectory `
        -TaskProvider { $null } `
        -ConnectorDataAclSnapshotProvider { $restoredSnapshot }
    if (-not $postRepairResult.connector_data_acl_exact -or
        -not $postRepairResult.file_targets_exact -or
        -not $postRepairResult.task_snapshot_exact) {
        throw "Full verifier did not pass after the isolated ACL repair"
    }

    $contentChangedBlocked = $false
    $changedContentSnapshot = [pscustomobject][ordered]@{
        entries = @(
            [pscustomobject][ordered]@{
                name = "state.json"
                length = 1
                sha256 = "changed"
            }
        )
    }
    try {
        Assert-AIChatConnectorDataContentMatchesSnapshot `
            -Expected $contentBeforeRepair `
            -Actual $changedContentSnapshot
    } catch {
        $contentChangedBlocked = $true
    }
    if (-not $contentChangedBlocked) {
        throw "Connector data content mutation was not blocked"
    }
} finally {
    if (Test-Path -LiteralPath $stateRoot) {
        Remove-Item -LiteralPath $stateRoot -Recurse -Force
    }
}

Write-Host "transaction_recovery_tests=pass"

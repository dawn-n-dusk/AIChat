[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This real-state recovery test requires Windows PowerShell 5.1"
}

$serviceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\connector-service")).Path
$runnerPath = Join-Path $serviceRoot "invoke-recovery-json.ps1"
$checkerPath = Join-Path $serviceRoot "check.ps1"
. (Join-Path $serviceRoot "common.ps1")

function ConvertTo-TestWindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-TestPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [string[]]$Arguments = @()
    )

    $childArguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", $ScriptPath
    ) + $Arguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $startInfo.Arguments = @($childArguments | ForEach-Object {
        ConvertTo-TestWindowsArgument ([string]$_)
    }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(120000)) {
        try { $process.Kill() } catch {}
        throw "Real-state recovery child timed out"
    }
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Read-RecoveryJsonResult {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($Result.ExitCode -ne 0 -or $Result.Stderr.Length -ne 0) {
        throw "Real-state recovery operation failed: $Operation"
    }
    $jsonText = $Result.Stdout.TrimEnd("`r", "`n")
    if (-not $jsonText -or
        $jsonText.Contains("`r") -or
        $jsonText.Contains("`n") -or
        -not $jsonText.StartsWith("{") -or
        -not $jsonText.EndsWith("}")) {
        throw "Real-state recovery operation did not emit one JSON object"
    }
    $value = $jsonText | ConvertFrom-Json
    if ([int]$value.contract_version -ne 2 -or
        [string]$value.operation -cne $Operation -or
        -not [bool]$value.success) {
        throw "Real-state recovery operation returned an invalid contract"
    }
    return $value
}

$paths = Get-AIChatConnectorPaths
$privateRoot = Join-Path (Get-AIChatUserProfile) ".aichat"
$privateRootExisted = Test-Path -LiteralPath $privateRoot -PathType Container
$protectedRootExisted = Test-Path -LiteralPath $paths.ProtectedRoot -PathType Container
$transactionId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") +
    "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$ownershipMarker = "aichat-real-recovery-$transactionId"
$stateMarkerPath = Join-Path $paths.StateRoot "real-recovery-e2e.marker"
$connectorMarkerPath = Join-Path $paths.ConnectorDataRoot "state.json"

if ((Test-Path -LiteralPath $paths.StateRoot) -or
    (Test-Path -LiteralPath $paths.ConnectorDataRoot) -or
    $null -ne (Get-AIChatConnectorTask)) {
    throw "Refusing real-state recovery CI because a fixed target already exists"
}

try {
    [void](Initialize-AIChatPrivateDirectory `
        -Path $paths.StateRoot `
        -ProtectedRoot $paths.ProtectedRoot)
    foreach ($directory in @(
        $paths.ReleasesDirectory,
        $paths.BackupsDirectory,
        $paths.StagingDirectory
    )) {
        [void](Initialize-AIChatPrivateDirectory `
            -Path $directory `
            -ProtectedRoot $paths.ProtectedRoot)
    }
    [IO.File]::WriteAllText(
        $stateMarkerPath,
        $ownershipMarker,
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatCurrentSidOnlyAcl -Path $stateMarkerPath

    if (-not $privateRootExisted) {
        [void](Initialize-AIChatPrivateDirectory `
            -Path $privateRoot `
            -ProtectedRoot $privateRoot `
            -AnchorRoot (Get-AIChatUserProfile))
    }
    New-Item -ItemType Directory -Path $paths.ConnectorDataRoot | Out-Null
    [IO.File]::WriteAllText(
        $connectorMarkerPath,
        $ownershipMarker,
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatCurrentSidOnlyAcl -Path $paths.ConnectorDataRoot
    Set-AIChatCurrentSidOnlyAcl -Path $connectorMarkerPath
    $legacyAcl = Get-AIChatConnectorDataAclSnapshot `
        -Path $paths.ConnectorDataRoot
    $contentBefore = Get-AIChatConnectorDataContentSnapshot `
        -Path $paths.ConnectorDataRoot
    $contentHashBefore = (Get-FileHash `
        -LiteralPath $connectorMarkerPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()

    Set-AIChatConnectorDataAcl -Path $paths.ConnectorDataRoot
    Set-AIChatConnectorDataAcl -Path $connectorMarkerPath
    $forwardAcl = Get-AIChatConnectorDataAclSnapshot `
        -Path $paths.ConnectorDataRoot
    [void](Assert-AIChatConnectorDataAclRepairEligible `
        -Expected $legacyAcl `
        -Actual $forwardAcl)

    $backupDirectory = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $paths.BackupsDirectory $transactionId) `
        -ProtectedRoot $paths.ProtectedRoot
    $files = @($((Get-AIChatDeploymentTargets -Paths $paths).Keys) |
        ForEach-Object {
            [pscustomobject][ordered]@{
                id = [string]$_
                existed = $false
            }
        })
    $journal = [pscustomobject][ordered]@{
        schema_version = 3
        kind = "aichat-windows-connector-transaction"
        transaction_id = $transactionId
        status = "rollback_incomplete"
        files = $files
        task = [pscustomobject]@{ existed = $false }
        new_release_id = $transactionId
        connector_data_acl = $legacyAcl
    }
    Write-AIChatPrivateJson `
        -Path $paths.TransactionPath `
        -Value $journal `
        -ProtectedRoot $paths.ProtectedRoot
    $journalHash = (Get-FileHash `
        -LiteralPath $paths.TransactionPath `
        -Algorithm SHA256).Hash.ToLowerInvariant()

    $diagnosticCode = ""
    $completeVerifierBlocked = $false
    try {
        [void](Assert-AIChatManifestRollbackComplete `
            -Manifest $journal `
            -Paths $paths `
            -BackupDirectory $backupDirectory `
            -DiagnosticCodeSink {
                param([string]$Code)
                $script:diagnosticCode = $Code
            })
    } catch {
        $completeVerifierBlocked = $true
    }
    if (-not $completeVerifierBlocked -or
        $diagnosticCode -cne "acl_snapshot_mismatch") {
        throw "Real verifier did not identify and block the ACL mismatch"
    }
    $nonAcl = Assert-AIChatManifestRollbackNonAclComplete `
        -Manifest $journal `
        -Paths $paths `
        -BackupDirectory $backupDirectory
    if (-not $nonAcl.file_targets_exact -or
        -not $nonAcl.task_snapshot_exact -or
        -not $nonAcl.task_scheduler_accessed -or
        -not $nonAcl.live_release_absent -or
        -not $nonAcl.staging_absent) {
        throw "Real non-ACL recovery invariants were not exact"
    }

    $blockedGate = Invoke-TestPowerShell `
        -ScriptPath $checkerPath `
        -Arguments @("-StageOnly", "-RecoveryGateOnly")
    if ($blockedGate.ExitCode -ne 1 -or
        $blockedGate.Stderr.Length -ne 0 -or
        $blockedGate.Stdout -notmatch '(?m)^\[FAIL\] transaction:' -or
        $blockedGate.Stdout -notmatch '(?m)^task_scheduler_accessed=false\s*$' -or
        $blockedGate.Stdout -notmatch '(?m)^connector_state_mutated=false\s*$' -or
        $blockedGate.Stdout -notmatch '(?m)^mutation_performed=false\s*$') {
        throw "StageOnly recovery gate did not block the real journal"
    }

    $diagnose = Read-RecoveryJsonResult `
        -Result (Invoke-TestPowerShell -ScriptPath $runnerPath -Arguments @("verify")) `
        -Operation "verify"
    if ([string]$diagnose.status -cne "repair_ready" -or
        [int]$diagnose.journal_schema -ne 3 -or
        [string]$diagnose.task_mode -cne "managed" -or
        -not [bool]$diagnose.file_targets_exact -or
        -not [bool]$diagnose.task_snapshot_exact -or
        -not [bool]$diagnose.task_scheduler_accessed -or
        [bool]$diagnose.connector_data_acl_exact -or
        [bool]$diagnose.rollback_exact -or
        -not [bool]$diagnose.repair_ready -or
        [bool]$diagnose.mutation_performed -or
        -not [bool]$diagnose.journal_retained) {
        throw "Real diagnose contract was not repair_ready"
    }

    $repair = Read-RecoveryJsonResult `
        -Result (Invoke-TestPowerShell -ScriptPath $runnerPath -Arguments @("repair")) `
        -Operation "repair"
    if ([string]$repair.status -cne "acl_repaired" -or
        -not [bool]$repair.rollback_exact -or
        -not [bool]$repair.connector_data_acl_exact -or
        -not [bool]$repair.mutation_performed -or
        -not [bool]$repair.connector_acl_mutated -or
        -not [bool]$repair.journal_retained) {
        throw "Real ACL repair contract was invalid"
    }
    Assert-AIChatConnectorDataAclMatchesSnapshot `
        -Expected $legacyAcl `
        -Actual (Get-AIChatConnectorDataAclSnapshot -Path $paths.ConnectorDataRoot)
    Assert-AIChatConnectorDataContentMatchesSnapshot `
        -Expected $contentBefore `
        -Actual (Get-AIChatConnectorDataContentSnapshot -Path $paths.ConnectorDataRoot)
    if ((Get-FileHash -LiteralPath $connectorMarkerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
        $contentHashBefore -or
        (Get-FileHash -LiteralPath $paths.TransactionPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
        $journalHash -or
        $null -ne (Get-AIChatConnectorTask)) {
        throw "Real ACL repair changed content, journal, or Scheduled Task state"
    }

    $verify = Read-RecoveryJsonResult `
        -Result (Invoke-TestPowerShell -ScriptPath $runnerPath -Arguments @("verify")) `
        -Operation "verify"
    if ([string]$verify.status -cne "rollback_exact" -or
        -not [bool]$verify.rollback_exact -or
        -not [bool]$verify.connector_data_acl_exact -or
        [bool]$verify.mutation_performed -or
        -not [bool]$verify.journal_retained) {
        throw "Real post-repair verification was not rollback_exact"
    }

    $finalize = Read-RecoveryJsonResult `
        -Result (Invoke-TestPowerShell -ScriptPath $runnerPath -Arguments @("finalize")) `
        -Operation "finalize"
    $archivePath = Join-Path $backupDirectory "rollback-incomplete.finalized.json"
    if ([string]$finalize.status -cne "finalized" -or
        -not [bool]$finalize.finalize_performed -or
        -not [bool]$finalize.mutation_performed -or
        [bool]$finalize.connector_acl_mutated -or
        [bool]$finalize.journal_retained -or
        (Test-Path -LiteralPath $paths.TransactionPath) -or
        -not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
        $journalHash -or
        (Get-FileHash -LiteralPath $connectorMarkerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne
        $contentHashBefore -or
        $null -ne (Get-AIChatConnectorTask)) {
        throw "Real finalization did not archive and clear only the journal"
    }

    $clearGate = Invoke-TestPowerShell `
        -ScriptPath $checkerPath `
        -Arguments @("-StageOnly", "-RecoveryGateOnly")
    if ($clearGate.ExitCode -ne 0 -or
        $clearGate.Stderr.Length -ne 0 -or
        $clearGate.Stdout -notmatch '(?m)^\[PASS\] transaction:' -or
        $clearGate.Stdout -notmatch '(?m)^recovery_gate_clear=true\s*$' -or
        $clearGate.Stdout -notmatch '(?m)^task_scheduler_accessed=false\s*$' -or
        $clearGate.Stdout -notmatch '(?m)^connector_state_mutated=false\s*$' -or
        $clearGate.Stdout -notmatch '(?m)^mutation_performed=false\s*$') {
        throw "StageOnly recovery gate did not admit the finalized real state"
    }

    Write-Host "recovery_real_state_e2e=pass"
} finally {
    if (Test-Path -LiteralPath $paths.StateRoot -PathType Container) {
        $marker = Get-Content -LiteralPath $stateMarkerPath -Raw -ErrorAction SilentlyContinue
        if ($marker -cne $ownershipMarker) {
            throw "Refusing cleanup because the real recovery state marker changed"
        }
        [void](Assert-AIChatPrivateDirectoryTree `
            -Path $paths.StateRoot `
            -ProtectedRoot $paths.ProtectedRoot)
        Remove-Item -LiteralPath $paths.StateRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $paths.ConnectorDataRoot -PathType Container) {
        $marker = Get-Content -LiteralPath $connectorMarkerPath -Raw -ErrorAction SilentlyContinue
        if ($marker -cne $ownershipMarker) {
            throw "Refusing cleanup because the connector recovery marker changed"
        }
        foreach ($item in @(
            Get-Item -LiteralPath $paths.ConnectorDataRoot -Force
        ) + @(
            Get-ChildItem -LiteralPath $paths.ConnectorDataRoot -Force
        )) {
            Assert-AIChatConnectorDataAcl `
                -Path $item.FullName `
                -AllowLegacyCurrentSidOnly
        }
        Remove-Item -LiteralPath $paths.ConnectorDataRoot -Recurse -Force
    }
    if (-not $privateRootExisted -and
        (Test-Path -LiteralPath $privateRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $privateRoot -Force).Count -eq 0) {
        [void](Assert-AIChatPrivateDirectoryTree `
            -Path $privateRoot `
            -ProtectedRoot $privateRoot)
        Remove-Item -LiteralPath $privateRoot -Force
    }
    if (-not $protectedRootExisted -and
        (Test-Path -LiteralPath $paths.ProtectedRoot -PathType Container) -and
        @(Get-ChildItem -LiteralPath $paths.ProtectedRoot -Force).Count -eq 0) {
        [void](Assert-AIChatPrivateDirectoryTree `
            -Path $paths.ProtectedRoot `
            -ProtectedRoot $paths.ProtectedRoot)
        Remove-Item -LiteralPath $paths.ProtectedRoot -Force
    }
}

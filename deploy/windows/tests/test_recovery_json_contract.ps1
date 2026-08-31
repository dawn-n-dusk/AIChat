[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This contract test requires Windows PowerShell 5.1"
}

$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\connector-service")).Path
$sourceRecovery = Join-Path $sourceRoot "recover-transaction.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "aichat-recovery-json-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

$syntheticCommon = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:syntheticRepaired = $false

function Get-AIChatConnectorPaths {
    $root = $env:AICHAT_RECOVERY_TEST_ROOT
    return [pscustomobject]@{
        StateRoot = $root
        ProtectedRoot = $root
        TransactionPath = Join-Path $root "transaction.json"
        BackupsDirectory = Join-Path $root "backups"
        ConnectorDataRoot = Join-Path $root "connector-data"
    }
}

function Assert-AIChatPrivateDirectoryTree { param($Path, $ProtectedRoot) return $Path }
function Assert-AIChatPrivateFile { param($Path, $ProtectedRoot) return $Path }
function Read-AIChatPrivateJson {
    param($Path, $ProtectedRoot)
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}
function New-SyntheticRecoveryResult {
    param([bool]$AclExact)
    return [pscustomobject][ordered]@{
        transaction_id = "20260901T000000Z-1234abcd"
        schema_version = 3
        file_targets_exact = $true
        task_mode = "managed"
        task_snapshot_exact = $true
        task_untouched = $false
        task_scheduler_accessed = $true
        connector_data_acl_exact = $AclExact
        live_release_absent = $true
        staging_absent = $true
        failed_release_preserved = $true
    }
}
function Assert-AIChatManifestRollbackComplete {
    param($Manifest, $Paths, $BackupDirectory)
    $scenario = $env:AICHAT_RECOVERY_TEST_SCENARIO
    if ($scenario -eq "verifier_failure") {
        $unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
        throw "synthetic verifier failure at $($env:AICHAT_RECOVERY_TEST_ROOT) $unicodeProbe$([char]0x2028) raw-sddl=O:BAD token=secret"
    }
    if (($scenario -eq "repair_ready" -or $scenario -eq "repair") -and
        -not $script:syntheticRepaired) {
        throw "synthetic ACL mismatch"
    }
    return New-SyntheticRecoveryResult -AclExact $true
}
function Assert-AIChatManifestRollbackNonAclComplete {
    param($Manifest, $Paths, $BackupDirectory)
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "verifier_failure") {
        throw "synthetic non-ACL verifier failure at $($env:AICHAT_RECOVERY_TEST_ROOT)"
    }
    return New-SyntheticRecoveryResult -AclExact $false
}
function Get-AIChatConnectorDataAclSnapshot { param($Path) return [pscustomobject]@{ marker = "forward" } }
function Assert-AIChatConnectorDataAclRepairEligible { param($Expected, $Actual) }
function Assert-AIChatConnectorDataAclMatchesSnapshot { param($Expected, $Actual) }
function Get-AIChatConnectorDataContentSnapshot { param($Path) return [pscustomobject]@{ entries = @() } }
function Assert-AIChatConnectorDataContentMatchesSnapshot { param($Expected, $Actual) }
function Invoke-AIChatConnectorDataAclSnapshotRepair {
    param(
        $ExpectedSnapshot,
        $CurrentSnapshot,
        $Path,
        [scriptblock]$PostRepairVerifier,
        [scriptblock]$PostCompensationVerifier
    )
    $script:syntheticRepaired = $true
    return & $PostRepairVerifier
}
function Copy-AIChatPrivateFileAtomic {
    param($Source, $Destination, $ProtectedRoot)
    Copy-Item -LiteralPath $Source -Destination $Destination
}
'@

function Invoke-RecoveryCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [string[]]$Arguments = @(),
        [int]$ExpectedExitCode = 0,
        [switch]$Human
    )

    $caseRoot = Join-Path $testRoot $Name
    $runnerRoot = Join-Path $caseRoot "runner"
    $stateRoot = Join-Path $caseRoot "private-sensitive"
    $backupRoot = Join-Path $stateRoot "backups\20260901T000000Z-1234abcd"
    New-Item -ItemType Directory -Path $runnerRoot | Out-Null
    New-Item -ItemType Directory -Path $backupRoot | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $stateRoot "connector-data") | Out-Null
    Copy-Item -LiteralPath $sourceRecovery -Destination (Join-Path $runnerRoot "recover-transaction.ps1")
    [IO.File]::WriteAllText(
        (Join-Path $runnerRoot "common.ps1"),
        $syntheticCommon,
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        (Join-Path $stateRoot "transaction.json"),
        '{"transaction_id":"20260901T000000Z-1234abcd","connector_data_acl":{}}',
        [Text.UTF8Encoding]::new($false)
    )

    $stdoutPath = Join-Path $caseRoot "stdout.txt"
    $stderrPath = Join-Path $caseRoot "stderr.txt"
    $argumentList = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $runnerRoot "recover-transaction.ps1")
    ) + $Arguments
    $quotedArguments = @($argumentList | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join " "
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Join-Path $PSHOME "powershell.exe")
    $startInfo.Arguments = $quotedArguments
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["AICHAT_RECOVERY_TEST_ROOT"] = $stateRoot
    $startInfo.EnvironmentVariables["AICHAT_RECOVERY_TEST_SCENARIO"] = $Scenario
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))

    if ($process.ExitCode -ne $ExpectedExitCode) {
        throw "$Name exit code was $($process.ExitCode), expected $ExpectedExitCode"
    }
    if ($Human) {
        if (-not $stdout.Contains("state_root=") -or
            -not $stdout.Contains("task=\AIChat\CodexConnector") -or
            $stderr.Trim()) {
            throw "Default Human output compatibility failed for $Name"
        }
        foreach ($humanKey in @(
            "token_read=", "task_write_attempted=", "transaction_id=",
            "journal_schema=", "file_targets_exact=", "task_snapshot_exact=",
            "task_mode=", "task_untouched=", "task_scheduler_accessed=",
            "connector_data_acl_exact=", "live_release_absent=",
            "staging_absent=", "failed_release_preserved=", "rollback_exact=",
            "rollback_non_acl_exact=", "repair_ready=", "acl_repaired=",
            "finalize_performed=", "finalize_requested=", "mutation_performed=",
            "journal_retained=", "connector_state_mutated=",
            "connector_state_content_mutated=", "connector_acl_mutated="
        )) {
            if (-not $stdout.Contains($humanKey)) {
                throw "Default Human output lost $humanKey"
            }
        }
        return $null
    }

    if ($stderr.Trim()) {
        throw "$Name leaked stderr output"
    }
    $trimmed = $stdout.Trim()
    if (-not $trimmed -or $trimmed.Contains("`n") -or $trimmed.Contains("`r")) {
        throw "$Name did not emit exactly one compact JSON line"
    }
    foreach ($character in $trimmed.ToCharArray()) {
        if ([int][char]$character -gt 0x7f) {
            throw "$Name JSON output was not ASCII-safe"
        }
    }
    foreach ($forbidden in @(
        $stateRoot,
        "state_root=",
        "task=\AIChat\CodexConnector",
        "S-1-",
        "raw-sddl",
        "token=secret",
        (([string][char]0x4e2d) + ([string][char]0x6587)),
        [string][char]0x2028
    )) {
        if ($trimmed.Contains($forbidden)) {
            throw "$Name JSON output contained forbidden diagnostic content"
        }
    }
    $parsed = $trimmed | ConvertFrom-Json
    if ([int]$parsed.contract_version -ne 1 -or
        $null -eq $parsed.success -or
        -not [string]$parsed.operation -or
        -not [string]$parsed.mode -or
        -not [string]$parsed.status) {
        throw "$Name JSON contract envelope is incomplete"
    }
    if ([bool]$parsed.success) {
        $successFields = @(
            "contract_version", "operation", "mode", "success", "status",
            "transaction_id", "journal_schema", "file_targets_exact",
            "task_snapshot_exact", "task_mode", "task_untouched",
            "task_scheduler_accessed", "connector_data_acl_exact",
            "live_release_absent", "staging_absent", "failed_release_preserved",
            "rollback_exact", "rollback_non_acl_exact", "repair_ready",
            "acl_repaired", "finalize_requested", "finalize_performed",
            "mutation_performed", "journal_retained", "token_read",
            "task_write_attempted", "connector_state_mutated",
            "connector_state_content_mutated", "connector_acl_mutated"
        )
        $actualFields = @($parsed.PSObject.Properties.Name)
        if ($actualFields.Count -ne $successFields.Count) {
            throw "$Name success contract field count changed"
        }
        foreach ($field in $successFields) {
            if ($actualFields -notcontains $field) {
                throw "$Name success contract is missing $field"
            }
        }
        foreach ($booleanField in @(
            "success", "file_targets_exact", "task_snapshot_exact",
            "task_untouched", "task_scheduler_accessed",
            "connector_data_acl_exact", "live_release_absent", "staging_absent",
            "failed_release_preserved", "rollback_exact",
            "rollback_non_acl_exact", "repair_ready", "acl_repaired",
            "finalize_requested", "finalize_performed", "mutation_performed",
            "journal_retained", "token_read", "task_write_attempted",
            "connector_state_mutated", "connector_state_content_mutated",
            "connector_acl_mutated"
        )) {
            if ($parsed.$booleanField -isnot [bool]) {
                throw "$Name field $booleanField is not a native JSON boolean"
            }
        }
    } else {
        $failureFields = @(
            "contract_version", "operation", "mode", "success", "status",
            "error_code", "mutation_performed", "journal_retained", "token_read",
            "task_write_attempted", "connector_state_mutated",
            "connector_state_content_mutated", "connector_acl_mutated",
            "finalize_performed"
        )
        $actualFields = @($parsed.PSObject.Properties.Name)
        if ($actualFields.Count -ne $failureFields.Count) {
            throw "$Name failure contract field count changed"
        }
        foreach ($field in $failureFields) {
            if ($actualFields -notcontains $field) {
                throw "$Name failure contract is missing $field"
            }
        }
        foreach ($booleanField in @(
            "success", "mutation_performed", "journal_retained", "token_read",
            "task_write_attempted", "connector_state_mutated",
            "connector_state_content_mutated", "connector_acl_mutated",
            "finalize_performed"
        )) {
            if ($parsed.$booleanField -isnot [bool]) {
                throw "$Name failure field $booleanField is not a native JSON boolean"
            }
        }
    }
    return $parsed
}

try {
    $human = Invoke-RecoveryCase -Name "human-exact" -Scenario "exact" -Human

    $repairReady = Invoke-RecoveryCase `
        -Name "repair-ready" `
        -Scenario "repair_ready" `
        -Arguments @("-OutputFormat", "Json")
    if (-not $repairReady.success -or $repairReady.status -ne "repair_ready" -or
        -not $repairReady.repair_ready -or $repairReady.rollback_exact) {
        throw "Read-only repair-ready JSON result is invalid"
    }

    $exact = Invoke-RecoveryCase `
        -Name "exact" `
        -Scenario "exact" `
        -Arguments @("-OutputFormat", "Json")
    if (-not $exact.success -or $exact.status -ne "rollback_exact" -or
        -not $exact.rollback_exact -or $exact.mutation_performed) {
        throw "Read-only exact JSON result is invalid"
    }

    $repair = Invoke-RecoveryCase `
        -Name "repair" `
        -Scenario "repair" `
        -Arguments @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json")
    if (-not $repair.success -or $repair.status -ne "acl_repaired" -or
        -not $repair.acl_repaired -or -not $repair.connector_acl_mutated -or
        $repair.connector_state_content_mutated) {
        throw "ACL repair JSON result is invalid"
    }

    $finalize = Invoke-RecoveryCase `
        -Name "finalize" `
        -Scenario "exact" `
        -Arguments @("-Finalize", "-Apply", "-OutputFormat", "Json")
    if (-not $finalize.success -or $finalize.status -ne "finalized" -or
        -not $finalize.finalize_performed -or $finalize.journal_retained) {
        throw "Finalization JSON result is invalid"
    }

    $invalid = Invoke-RecoveryCase `
        -Name "invalid-arguments" `
        -Scenario "exact" `
        -Arguments @(
            "-Finalize", "-RepairConnectorAcl", "-Apply",
            "-OutputFormat", "Json"
        ) `
        -ExpectedExitCode 1
    if ($invalid.success -or $invalid.error_code -ne "invalid_arguments" -or
        $invalid.mutation_performed) {
        throw "Invalid-arguments JSON failure is invalid"
    }

    $failure = Invoke-RecoveryCase `
        -Name "verifier-failure" `
        -Scenario "verifier_failure" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedExitCode 1
    if ($failure.success -or $failure.error_code -ne "verification_failed" -or
        $failure.mutation_performed) {
        throw "Verifier-failure JSON result is invalid"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host "recovery_json_contract_tests=pass"

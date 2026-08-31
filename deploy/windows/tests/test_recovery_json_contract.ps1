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
$sourceInstall = Join-Path $sourceRoot "install.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "aichat-recovery-json-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

$syntheticCommon = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-SyntheticRepairMarker {
    return Join-Path $env:AICHAT_RECOVERY_TEST_ROOT "acl-repaired.marker"
}

function Test-SyntheticRepaired {
    return Test-Path -LiteralPath (Get-SyntheticRepairMarker) -PathType Leaf
}

function Set-SyntheticDiagnosticCode {
    param([scriptblock]$DiagnosticCodeSink, [string]$Code)
    if ($null -ne $DiagnosticCodeSink) {
        & $DiagnosticCodeSink $Code
    }
}

function Get-AIChatConnectorPaths {
    $root = $env:AICHAT_RECOVERY_TEST_ROOT
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "path_initialization_failure") {
        $unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
        throw "synthetic path initialization failure at $root $unicodeProbe raw-sddl=O:BAD token=secret"
    }
    return [pscustomobject]@{
        StateRoot = $root
        ProtectedRoot = $root
        TransactionPath = Join-Path $root "transaction.json"
        BackupsDirectory = Join-Path $root "backups"
        ConnectorDataRoot = Join-Path $root "connector-data"
    }
}

function Assert-AIChatPrivateDirectoryTree {
    param($Path, $ProtectedRoot)
    $scenario = $env:AICHAT_RECOVERY_TEST_SCENARIO
    if ($scenario -eq "protected_path_failure" -and
        $Path -eq $env:AICHAT_RECOVERY_TEST_ROOT) {
        throw "synthetic protected path failure at $Path token=secret"
    }
    if ($scenario -eq "journal_backup_failure" -and
        $Path -like "*backups*") {
        throw "synthetic journal backup failure at $Path token=secret"
    }
    return $Path
}
function Assert-AIChatPrivateFile {
    param($Path, $ProtectedRoot)
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "journal_failure" -and
        $Path -like "*transaction.json") {
        throw "synthetic journal failure at $Path token=secret"
    }
    return $Path
}
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
    param($Manifest, $Paths, $BackupDirectory, [scriptblock]$DiagnosticCodeSink)
    $scenario = $env:AICHAT_RECOVERY_TEST_SCENARIO
    $diagnosticScenario = switch ($scenario) {
        "verifier_failure" { "manifest_invalid"; break }
        "manifest_failure" { "manifest_invalid"; break }
        "file_snapshot_failure" { "file_snapshot_mismatch"; break }
        "task_snapshot_failure" { "task_snapshot_mismatch"; break }
        "release_layout_failure" { "release_layout_mismatch"; break }
        "acl_snapshot_failure" { "acl_snapshot_mismatch"; break }
        default { ""; break }
    }
    if ($diagnosticScenario) {
        Set-SyntheticDiagnosticCode $DiagnosticCodeSink $diagnosticScenario
        $unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
        throw "synthetic verifier failure at $($env:AICHAT_RECOVERY_TEST_ROOT) $unicodeProbe$([char]0x2028) raw-sddl=O:BAD token=secret"
    }
    if (($scenario -eq "repair_ready" -or
        $scenario -eq "repair" -or
        $scenario -eq "repair_apply_failure" -or
        $scenario -eq "acl_repair_ineligible" -or
        $scenario -eq "stateful_recovery") -and
        -not (Test-SyntheticRepaired)) {
        Set-SyntheticDiagnosticCode $DiagnosticCodeSink "acl_snapshot_mismatch"
        throw "synthetic ACL mismatch"
    }
    return New-SyntheticRecoveryResult -AclExact $true
}
function Assert-AIChatManifestRollbackNonAclComplete {
    param($Manifest, $Paths, $BackupDirectory, [scriptblock]$DiagnosticCodeSink)
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "acl_snapshot_failure") {
        Set-SyntheticDiagnosticCode $DiagnosticCodeSink "acl_snapshot_mismatch"
        throw "synthetic stored ACL snapshot failure token=secret"
    }
    return New-SyntheticRecoveryResult -AclExact $false
}
function Get-AIChatConnectorDataAclSnapshot { param($Path) return [pscustomobject]@{ marker = "forward" } }
function Assert-AIChatConnectorDataAclRepairEligible {
    param($Expected, $Actual)
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "acl_repair_ineligible") {
        throw "synthetic ineligible ACL token=secret"
    }
}
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
    [IO.File]::WriteAllText(
        (Get-SyntheticRepairMarker),
        "repaired",
        [Text.UTF8Encoding]::new($false)
    )
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "repair_apply_failure") {
        throw "synthetic repair failure at $($env:AICHAT_RECOVERY_TEST_ROOT) raw-sddl=O:BAD token=secret"
    }
    return & $PostRepairVerifier
}
function Copy-AIChatPrivateFileAtomic {
    param($Source, $Destination, $ProtectedRoot)
    if ($env:AICHAT_RECOVERY_TEST_SCENARIO -eq "finalize_apply_failure") {
        throw "synthetic finalize failure at $Source raw-sddl=O:BAD token=secret"
    }
    Copy-Item -LiteralPath $Source -Destination $Destination
}
'@

function Invoke-RecoveryCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [string[]]$Arguments = @(),
        [int]$ExpectedExitCode = 0,
        [switch]$Human,
        [ValidateSet("valid", "missing", "syntax_error")]
        [string]$CommonFixture = "valid",
        [string]$ExpectedOperation = "",
        [string]$ExpectedMode = "",
        [bool]$ExpectedMutationPerformed = $false,
        [bool]$ExpectedJournalRetained = $true,
        [bool]$ExpectedConnectorAclMutated = $false,
        [bool]$ExpectedFinalizePerformed = $false,
        [string]$ExpectedDiagnosticCode = "",
        [string]$StateKey = "",
        [switch]$ReuseState
    )

    if (-not $StateKey) { $StateKey = $Name }
    $caseRoot = Join-Path $testRoot $StateKey
    $runnerRoot = Join-Path $caseRoot "runner"
    $stateRoot = Join-Path $caseRoot "private-sensitive"
    $backupRoot = Join-Path $stateRoot "backups\20260901T000000Z-1234abcd"
    $commonPath = Join-Path $runnerRoot "common.ps1"
    if (-not $ReuseState) {
        New-Item -ItemType Directory -Path $runnerRoot | Out-Null
        New-Item -ItemType Directory -Path $backupRoot | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $stateRoot "connector-data") | Out-Null
        Copy-Item -LiteralPath $sourceRecovery -Destination (Join-Path $runnerRoot "recover-transaction.ps1")
    }
    if (-not $ReuseState -and $CommonFixture -eq "valid") {
        [IO.File]::WriteAllText(
            $commonPath,
            $syntheticCommon,
            [Text.UTF8Encoding]::new($false)
        )
    } elseif (-not $ReuseState -and $CommonFixture -eq "syntax_error") {
        [IO.File]::WriteAllText(
            $commonPath,
            'function Broken-SyntheticCommon { if (',
            [Text.UTF8Encoding]::new($false)
        )
    }
    if (-not $ReuseState) {
        [IO.File]::WriteAllText(
            (Join-Path $stateRoot "transaction.json"),
            '{"transaction_id":"20260901T000000Z-1234abcd","connector_data_acl":{}}',
            [Text.UTF8Encoding]::new($false)
        )
    }

    $stdoutPath = Join-Path $caseRoot "$Name.stdout.txt"
    $stderrPath = Join-Path $caseRoot "$Name.stderr.txt"
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
    if ($stdout.EndsWith("`r`n")) {
        $jsonText = $stdout.Substring(0, $stdout.Length - 2)
        $expectedStdout = $jsonText + "`r`n"
    } elseif ($stdout.EndsWith("`n")) {
        $jsonText = $stdout.Substring(0, $stdout.Length - 1)
        $expectedStdout = $jsonText + "`n"
    } else {
        throw "$Name stdout did not end with exactly one native newline"
    }
    if (-not $jsonText -or
        $stdout -cne $expectedStdout -or
        $jsonText.Contains("`n") -or
        $jsonText.Contains("`r") -or
        -not $jsonText.StartsWith("{") -or
        -not $jsonText.EndsWith("}")) {
        throw "$Name did not emit exactly JSON plus one native newline"
    }
    foreach ($character in $jsonText.ToCharArray()) {
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
        if ($jsonText.Contains($forbidden)) {
            throw "$Name JSON output contained forbidden diagnostic content"
        }
    }
    $keyMatches = [regex]::Matches(
        $jsonText,
        '(?<=[{,])"(?<key>(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\])+)":'
    )
    $seenKeys = @{}
    foreach ($keyMatch in $keyMatches) {
        $key = $keyMatch.Groups["key"].Value
        if ($seenKeys.ContainsKey($key)) {
            throw "$Name JSON output contained duplicate key $key"
        }
        $seenKeys[$key] = $true
    }
    $parsed = $jsonText | ConvertFrom-Json
    if ($keyMatches.Count -ne @($parsed.PSObject.Properties).Count) {
        throw "$Name JSON key scanner did not match the parsed field set"
    }
    if ([int]$parsed.contract_version -ne 2 -or
        $null -eq $parsed.success -or
        -not [string]$parsed.operation -or
        -not [string]$parsed.mode -or
        -not [string]$parsed.status) {
        throw "$Name JSON contract envelope is incomplete"
    }
    if (-not $ExpectedOperation -or -not $ExpectedMode) {
        throw "$Name test case omitted expected operation or mode"
    }
    if ($parsed.operation -ne $ExpectedOperation -or
        $parsed.mode -ne $ExpectedMode) {
        throw "$Name operation or mode is invalid"
    }
    if ([bool]$parsed.success) {
        $successStatuses = @(
            "repair_ready", "rollback_exact", "finalize_ready",
            "acl_repaired", "finalized"
        )
        if ($successStatuses -notcontains [string]$parsed.status) {
            throw "$Name success status is outside the fixed enum"
        }
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
        $failureCodes = @(
            "invalid_arguments", "initialization_failed",
            "verification_failed", "acl_repair_failed",
            "finalization_failed", "internal_error"
        )
        $diagnosticCodes = @(
            "arguments_invalid", "common_load_failed", "protected_paths_invalid",
            "journal_invalid", "journal_backup_invalid", "manifest_invalid",
            "file_snapshot_mismatch", "task_snapshot_mismatch",
            "release_layout_mismatch", "acl_snapshot_mismatch",
            "acl_repair_ineligible", "acl_repair_not_required",
            "acl_repair_required", "concurrent_journal_change",
            "concurrent_state_change", "concurrent_acl_change",
            "concurrent_content_change", "acl_repair_apply_failed",
            "finalize_archive_failed", "finalize_reverification_failed",
            "finalize_clear_failed", "internal_error"
        )
        if ([string]$parsed.status -cne [string]$parsed.error_code -or
            $failureCodes -notcontains [string]$parsed.error_code -or
            $diagnosticCodes -notcontains [string]$parsed.diagnostic_code) {
            throw "$Name failure status or error_code is outside the fixed enum"
        }
        $failureFields = @(
            "contract_version", "operation", "mode", "success", "status",
            "error_code", "diagnostic_code", "mutation_performed",
            "journal_retained", "token_read", "task_write_attempted",
            "connector_state_mutated",
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
        if ($ExpectedDiagnosticCode -and
            [string]$parsed.diagnostic_code -cne $ExpectedDiagnosticCode) {
            throw "$Name diagnostic_code was not $ExpectedDiagnosticCode"
        }
    }
    if ([bool]$parsed.mutation_performed -ne $ExpectedMutationPerformed -or
        [bool]$parsed.journal_retained -ne $ExpectedJournalRetained -or
        [bool]$parsed.connector_acl_mutated -ne $ExpectedConnectorAclMutated -or
        [bool]$parsed.finalize_performed -ne $ExpectedFinalizePerformed) {
        throw "$Name critical mutation flags are invalid"
    }
    return $parsed
}

try {
    $human = Invoke-RecoveryCase -Name "human-exact" -Scenario "exact" -Human

    $repairReady = Invoke-RecoveryCase `
        -Name "repair-ready" `
        -Scenario "repair_ready" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only"
    if (-not $repairReady.success -or
        $repairReady.operation -ne "verify" -or
        $repairReady.mode -ne "read_only" -or
        $repairReady.status -ne "repair_ready" -or
        -not $repairReady.repair_ready -or $repairReady.rollback_exact) {
        throw "Read-only repair-ready JSON result is invalid"
    }

    $exact = Invoke-RecoveryCase `
        -Name "exact" `
        -Scenario "exact" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only"
    if (-not $exact.success -or
        $exact.operation -ne "verify" -or
        $exact.mode -ne "read_only" -or
        $exact.status -ne "rollback_exact" -or
        -not $exact.rollback_exact -or
        $exact.mutation_performed -or
        -not $exact.journal_retained) {
        throw "Read-only exact JSON result is invalid"
    }

    $repair = Invoke-RecoveryCase `
        -Name "repair" `
        -Scenario "repair" `
        -Arguments @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json") `
        -ExpectedOperation "repair" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedConnectorAclMutated $true
    if (-not $repair.success -or
        $repair.operation -ne "repair" -or
        $repair.mode -ne "apply" -or
        $repair.status -ne "acl_repaired" -or
        -not $repair.rollback_exact -or
        -not $repair.acl_repaired -or
        -not $repair.mutation_performed -or
        -not $repair.journal_retained -or
        -not $repair.connector_acl_mutated -or
        $repair.connector_state_content_mutated) {
        throw "ACL repair JSON result is invalid"
    }

    $finalize = Invoke-RecoveryCase `
        -Name "finalize" `
        -Scenario "exact" `
        -Arguments @("-Finalize", "-Apply", "-OutputFormat", "Json") `
        -ExpectedOperation "finalize" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedJournalRetained $false `
        -ExpectedFinalizePerformed $true
    if (-not $finalize.success -or
        $finalize.operation -ne "finalize" -or
        $finalize.mode -ne "apply" -or
        $finalize.status -ne "finalized" -or
        -not $finalize.rollback_exact -or
        -not $finalize.finalize_performed -or
        -not $finalize.mutation_performed -or
        $finalize.journal_retained -or
        $finalize.connector_acl_mutated) {
        throw "Finalization JSON result is invalid"
    }

    $invalid = Invoke-RecoveryCase `
        -Name "invalid-arguments" `
        -Scenario "exact" `
        -Arguments @(
            "-Finalize", "-RepairConnectorAcl", "-Apply",
            "-OutputFormat", "Json"
        ) `
        -ExpectedExitCode 1 `
        -ExpectedOperation "repair" `
        -ExpectedMode "apply" `
        -ExpectedDiagnosticCode "arguments_invalid"
    if ($invalid.success -or $invalid.error_code -ne "invalid_arguments" -or
        $invalid.mutation_performed) {
        throw "Invalid-arguments JSON failure is invalid"
    }

    $invalidFormat = Invoke-RecoveryCase `
        -Name "invalid-output-format" `
        -Scenario "exact" `
        -Arguments @("-OutputFormat", "Xml") `
        -ExpectedExitCode 1 `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only" `
        -ExpectedDiagnosticCode "arguments_invalid"
    if ($invalidFormat.success -or
        $invalidFormat.error_code -ne "invalid_arguments" -or
        $invalidFormat.mutation_performed) {
        throw "Invalid-output-format JSON failure is invalid"
    }

    $missingCommon = Invoke-RecoveryCase `
        -Name "missing-common" `
        -Scenario "exact" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -CommonFixture "missing" `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only" `
        -ExpectedDiagnosticCode "common_load_failed"
    if ($missingCommon.success -or
        $missingCommon.error_code -ne "initialization_failed" -or
        $missingCommon.mutation_performed) {
        throw "Missing-common JSON failure is invalid"
    }

    $brokenCommon = Invoke-RecoveryCase `
        -Name "broken-common" `
        -Scenario "exact" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -CommonFixture "syntax_error" `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only" `
        -ExpectedDiagnosticCode "common_load_failed"
    if ($brokenCommon.success -or
        $brokenCommon.error_code -ne "initialization_failed" -or
        $brokenCommon.mutation_performed) {
        throw "Broken-common JSON failure is invalid"
    }

    $pathInitializationFailure = Invoke-RecoveryCase `
        -Name "path-initialization-failure" `
        -Scenario "path_initialization_failure" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only" `
        -ExpectedDiagnosticCode "protected_paths_invalid"
    if ($pathInitializationFailure.success -or
        $pathInitializationFailure.error_code -ne "initialization_failed" -or
        $pathInitializationFailure.mutation_performed) {
        throw "Path-initialization JSON failure is invalid"
    }

    $repairApplyFailure = Invoke-RecoveryCase `
        -Name "repair-apply-failure" `
        -Scenario "repair_apply_failure" `
        -Arguments @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -ExpectedOperation "repair" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedConnectorAclMutated $true `
        -ExpectedDiagnosticCode "acl_repair_apply_failed"
    if ($repairApplyFailure.success -or
        $repairApplyFailure.operation -ne "repair" -or
        $repairApplyFailure.mode -ne "apply" -or
        $repairApplyFailure.error_code -ne "acl_repair_failed" -or
        -not $repairApplyFailure.mutation_performed -or
        -not $repairApplyFailure.journal_retained -or
        -not $repairApplyFailure.connector_acl_mutated -or
        $repairApplyFailure.finalize_performed) {
        throw "Repair-apply JSON failure is invalid"
    }

    $finalizeApplyFailure = Invoke-RecoveryCase `
        -Name "finalize-apply-failure" `
        -Scenario "finalize_apply_failure" `
        -Arguments @("-Finalize", "-Apply", "-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -ExpectedOperation "finalize" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedDiagnosticCode "finalize_archive_failed"
    if ($finalizeApplyFailure.success -or
        $finalizeApplyFailure.operation -ne "finalize" -or
        $finalizeApplyFailure.mode -ne "apply" -or
        $finalizeApplyFailure.error_code -ne "finalization_failed" -or
        -not $finalizeApplyFailure.mutation_performed -or
        -not $finalizeApplyFailure.journal_retained -or
        $finalizeApplyFailure.connector_acl_mutated -or
        $finalizeApplyFailure.finalize_performed) {
        throw "Finalize-apply JSON failure is invalid"
    }

    $failure = Invoke-RecoveryCase `
        -Name "verifier-failure" `
        -Scenario "verifier_failure" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedExitCode 1 `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only" `
        -ExpectedDiagnosticCode "manifest_invalid"
    if ($failure.success -or $failure.error_code -ne "verification_failed" -or
        $failure.mutation_performed) {
        throw "Verifier-failure JSON result is invalid"
    }

    foreach ($diagnosticCase in @(
        [pscustomobject]@{ Name = "journal-failure"; Scenario = "journal_failure"; Code = "journal_invalid" },
        [pscustomobject]@{ Name = "journal-backup-failure"; Scenario = "journal_backup_failure"; Code = "journal_backup_invalid" },
        [pscustomobject]@{ Name = "manifest-failure"; Scenario = "manifest_failure"; Code = "manifest_invalid" },
        [pscustomobject]@{ Name = "file-snapshot-failure"; Scenario = "file_snapshot_failure"; Code = "file_snapshot_mismatch" },
        [pscustomobject]@{ Name = "task-state-failure"; Scenario = "task_snapshot_failure"; Code = "task_snapshot_mismatch" },
        [pscustomobject]@{ Name = "release-layout-failure"; Scenario = "release_layout_failure"; Code = "release_layout_mismatch" },
        [pscustomobject]@{ Name = "acl-snapshot-failure"; Scenario = "acl_snapshot_failure"; Code = "acl_snapshot_mismatch" },
        [pscustomobject]@{ Name = "acl-repair-ineligible"; Scenario = "acl_repair_ineligible"; Code = "acl_repair_ineligible" }
    )) {
        $diagnosticFailure = Invoke-RecoveryCase `
            -Name ([string]$diagnosticCase.Name) `
            -Scenario ([string]$diagnosticCase.Scenario) `
            -Arguments @("-OutputFormat", "Json") `
            -ExpectedExitCode 1 `
            -ExpectedOperation "verify" `
            -ExpectedMode "read_only" `
            -ExpectedDiagnosticCode ([string]$diagnosticCase.Code)
        if ($diagnosticFailure.success -or
            $diagnosticFailure.error_code -ne "verification_failed") {
            throw "$($diagnosticCase.Name) did not use verification_failed"
        }
    }

    $statefulKey = "managed-recovery-to-stage-only"
    $statefulDiagnose = Invoke-RecoveryCase `
        -Name "stateful-diagnose" `
        -StateKey $statefulKey `
        -Scenario "stateful_recovery" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only"
    if ($statefulDiagnose.status -ne "repair_ready") {
        throw "Stateful managed recovery did not diagnose repair readiness"
    }
    $statefulRepair = Invoke-RecoveryCase `
        -Name "stateful-repair" `
        -StateKey $statefulKey `
        -ReuseState `
        -Scenario "stateful_recovery" `
        -Arguments @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json") `
        -ExpectedOperation "repair" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedConnectorAclMutated $true
    if ($statefulRepair.status -ne "acl_repaired") {
        throw "Stateful managed recovery did not repair the ACL"
    }
    $statefulVerify = Invoke-RecoveryCase `
        -Name "stateful-verify" `
        -StateKey $statefulKey `
        -ReuseState `
        -Scenario "stateful_recovery" `
        -Arguments @("-OutputFormat", "Json") `
        -ExpectedOperation "verify" `
        -ExpectedMode "read_only"
    if ($statefulVerify.status -ne "rollback_exact") {
        throw "Stateful managed recovery did not reverify exact rollback"
    }
    $statefulFinalize = Invoke-RecoveryCase `
        -Name "stateful-finalize" `
        -StateKey $statefulKey `
        -ReuseState `
        -Scenario "stateful_recovery" `
        -Arguments @("-Finalize", "-Apply", "-OutputFormat", "Json") `
        -ExpectedOperation "finalize" `
        -ExpectedMode "apply" `
        -ExpectedMutationPerformed $true `
        -ExpectedJournalRetained $false `
        -ExpectedFinalizePerformed $true
    $statefulRoot = Join-Path (Join-Path $testRoot $statefulKey) "private-sensitive"
    if ($statefulFinalize.status -ne "finalized" -or
        (Test-Path -LiteralPath (Join-Path $statefulRoot "transaction.json"))) {
        throw "Stateful managed recovery did not clear the finalized blocker"
    }
    $stageOnlyDryRun = & $sourceInstall `
        -SettingsPath (Join-Path $statefulRoot "not-read-in-whatif.json") `
        -RepositoryRoot (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path `
        -StageOnly -Apply -WhatIf *>&1 | Out-String
    if ($LASTEXITCODE -ne 0 -or
        $stageOnlyDryRun -notmatch '(?m)^stage_only=true\s*$' -or
        $stageOnlyDryRun -notmatch '(?m)^mutation_performed=false\s*$') {
        throw "StageOnly dry-run was not admissible after managed recovery finalization"
    }
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

Write-Host "recovery_json_contract_tests=pass"

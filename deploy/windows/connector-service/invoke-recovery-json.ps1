Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runnerContractVersion = 1
$runnerFailureExitCode = 2
$timeoutMilliseconds = 120000

function Write-AIChatRunnerFailure {
    $operation = [string]$args[0]
    $errorCode = [string]$args[1]
    $targetExitCode = $args[2]
    $mutationPossible = [bool]$args[3]

    $exitJson = if ($null -eq $targetExitCode) {
        "null"
    } else {
        [string][int]$targetExitCode
    }
    $mutationJson = if ($mutationPossible) { "true" } else { "false" }
    $json = "{`"runner_contract_version`":$runnerContractVersion," +
        "`"operation`":`"$operation`"," +
        "`"success`":false," +
        "`"error_code`":`"$errorCode`"," +
        "`"target_exit_code`":$exitJson," +
        "`"mutation_possible`":$mutationJson}"
    [Console]::Out.WriteLine($json)
    exit $runnerFailureExitCode
}

function ConvertTo-AIChatWindowsArgument {
    $value = [string]$args[0]
    if ($value.Length -gt 0 -and $value -notmatch '[\s"]') {
        return $value
    }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append([char]0x22)
    $backslashes = 0
    foreach ($character in $value.ToCharArray()) {
        if ($character -eq [char]0x5c) {
            $backslashes++
            continue
        }
        if ($character -eq [char]0x22) {
            for ($index = 0; $index -lt (($backslashes * 2) + 1); $index++) {
                [void]$builder.Append([char]0x5c)
            }
            [void]$builder.Append([char]0x22)
            $backslashes = 0
            continue
        }
        for ($index = 0; $index -lt $backslashes; $index++) {
            [void]$builder.Append([char]0x5c)
        }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashes * 2); $index++) {
        [void]$builder.Append([char]0x5c)
    }
    [void]$builder.Append([char]0x22)
    return $builder.ToString()
}

function Test-AIChatExactFields {
    $actual = @($args[0].PSObject.Properties.Name)
    $expected = @($args[1])
    if ($actual.Count -ne $expected.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expected.Count; $index++) {
        if ([string]$actual[$index] -cne [string]$expected[$index]) {
            return $false
        }
    }
    return $true
}

function Test-AIChatBooleanFields {
    $value = $args[0]
    foreach ($field in @($args[1])) {
        if ($value.$field -isnot [bool]) {
            return $false
        }
    }
    return $true
}

function Test-AIChatInteger {
    $value = $args[0]
    return $value -is [int] -or $value -is [long]
}

function Stop-AIChatRunnerTarget {
    $child = $args[0]
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            if ($child.HasExited) {
                return $true
            }
        } catch {
        }
        try {
            $child.Kill()
        } catch {
        }
        try {
            if ($child.WaitForExit(5000)) {
                return $true
            }
        } catch {
        }
    }
    try {
        return [bool]$child.HasExited
    } catch {
        return $false
    }
}

$operation = "unknown"
$mutationCapable = $false
$targetStarted = $false
$process = $null
try {
if ($args.Count -ne 1) {
    Write-AIChatRunnerFailure $operation "invalid_runner_arguments" $null $false
}
$operation = ([string]$args[0]).ToLowerInvariant()
if (@("verify", "repair", "finalize") -cnotcontains $operation) {
    Write-AIChatRunnerFailure "unknown" "invalid_runner_arguments" $null $false
}

$mutationCapable = $operation -ne "verify"
$targetPath = Join-Path $PSScriptRoot "recover-transaction.ps1"
if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
    Write-AIChatRunnerFailure $operation "target_missing" $null $false
}

$windowsPowerShell = if ($env:SystemRoot) {
    Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
} else {
    ""
}
if (-not $windowsPowerShell -or
    -not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    Write-AIChatRunnerFailure $operation "powershell_51_unavailable" $null $false
}

$scriptArguments = switch ($operation) {
    "verify" { @("-OutputFormat", "Json"); break }
    "repair" { @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json"); break }
    "finalize" { @("-Finalize", "-Apply", "-OutputFormat", "Json"); break }
}
$childArguments = @(
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy", "Bypass",
    "-File", $targetPath
) + $scriptArguments
$quotedArguments = @($childArguments | ForEach-Object {
    ConvertTo-AIChatWindowsArgument ([string]$_)
}) -join " "

$process = [Diagnostics.Process]::new()
$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $windowsPowerShell
$startInfo.Arguments = $quotedArguments
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$process.StartInfo = $startInfo

try {
    [void]$process.Start()
} catch {
    Write-AIChatRunnerFailure $operation "target_start_failed" $null $false
}
$targetStarted = $true

$stdoutTask = $process.StandardOutput.ReadToEndAsync()
$stderrTask = $process.StandardError.ReadToEndAsync()
if (-not $process.WaitForExit($timeoutMilliseconds)) {
    if (-not (Stop-AIChatRunnerTarget $process)) {
        Write-AIChatRunnerFailure `
            $operation `
            "target_termination_failed" `
            $null `
            $mutationCapable
    }
    Write-AIChatRunnerFailure $operation "target_timeout" $null $mutationCapable
}

try {
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
} catch {
    Write-AIChatRunnerFailure $operation "target_capture_failed" $process.ExitCode $mutationCapable
}
$targetExitCode = [int]$process.ExitCode
if ($stderr.Length -ne 0) {
    Write-AIChatRunnerFailure $operation "target_stderr" $targetExitCode $mutationCapable
}

if ($stdout.EndsWith("`r`n")) {
    $jsonText = $stdout.Substring(0, $stdout.Length - 2)
    $expectedStdout = $jsonText + "`r`n"
} elseif ($stdout.EndsWith("`n")) {
    $jsonText = $stdout.Substring(0, $stdout.Length - 1)
    $expectedStdout = $jsonText + "`n"
} else {
    Write-AIChatRunnerFailure $operation "target_output_invalid" $targetExitCode $mutationCapable
}
if (-not $jsonText -or
    $stdout -cne $expectedStdout -or
    $jsonText.Trim() -cne $jsonText -or
    $jsonText.Contains("`r") -or
    $jsonText.Contains("`n") -or
    -not $jsonText.StartsWith("{") -or
    -not $jsonText.EndsWith("}")) {
    Write-AIChatRunnerFailure $operation "target_output_invalid" $targetExitCode $mutationCapable
}
foreach ($character in $jsonText.ToCharArray()) {
    if ([int][char]$character -gt 0x7f) {
        Write-AIChatRunnerFailure $operation "target_output_invalid" $targetExitCode $mutationCapable
    }
}

$keyMatches = [regex]::Matches(
    $jsonText,
    '(?<=[{,])"(?<key>(?:\\["\\/bfnrt]|\\u[0-9a-fA-F]{4}|[^"\\])+)":')
$seenKeys = @{}
foreach ($keyMatch in $keyMatches) {
    $key = $keyMatch.Groups["key"].Value
    if ($seenKeys.ContainsKey($key)) {
        Write-AIChatRunnerFailure $operation "target_duplicate_key" $targetExitCode $mutationCapable
    }
    $seenKeys[$key] = $true
}
try {
    $parsed = $jsonText | ConvertFrom-Json
} catch {
    Write-AIChatRunnerFailure $operation "target_json_invalid" $targetExitCode $mutationCapable
}
if ($keyMatches.Count -ne @($parsed.PSObject.Properties).Count) {
    Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
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
$failureFields = @(
    "contract_version", "operation", "mode", "success", "status",
    "error_code", "diagnostic_code", "mutation_performed",
    "journal_retained", "token_read", "task_write_attempted",
    "connector_state_mutated",
    "connector_state_content_mutated", "connector_acl_mutated",
    "finalize_performed"
)
$commonBooleanFields = @(
    "success", "mutation_performed", "journal_retained", "token_read",
    "task_write_attempted", "connector_state_mutated",
    "connector_state_content_mutated", "connector_acl_mutated",
    "finalize_performed"
)
$expectedMode = if ($operation -eq "verify") { "read_only" } else { "apply" }
$propertyNames = @($parsed.PSObject.Properties.Name)
foreach ($envelopeField in @("contract_version", "operation", "mode", "success", "status")) {
    if ($propertyNames -cnotcontains $envelopeField) {
        Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
    }
}
if (-not (Test-AIChatInteger $parsed.contract_version) -or
    [int]$parsed.contract_version -ne 2 -or
    $parsed.operation -isnot [string] -or
    [string]$parsed.operation -cne $operation -or
    $parsed.mode -isnot [string] -or
    [string]$parsed.mode -cne $expectedMode -or
    $parsed.success -isnot [bool] -or
    $parsed.status -isnot [string]) {
    Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
}

if ([bool]$parsed.success) {
    $successBooleanFields = @(
        "file_targets_exact", "task_snapshot_exact", "task_untouched",
        "task_scheduler_accessed", "connector_data_acl_exact",
        "live_release_absent", "staging_absent", "failed_release_preserved",
        "rollback_exact", "rollback_non_acl_exact", "repair_ready",
        "acl_repaired", "finalize_requested"
    ) + $commonBooleanFields
    if (-not (Test-AIChatExactFields $parsed $successFields) -or
        -not (Test-AIChatBooleanFields $parsed $successBooleanFields) -or
        $parsed.status -isnot [string] -or
        $parsed.transaction_id -isnot [string] -or
        -not [string]$parsed.transaction_id -or
        -not (Test-AIChatInteger $parsed.journal_schema) -or
        $parsed.task_mode -isnot [string] -or
        -not (([int]$parsed.journal_schema -eq 3 -and
            [string]$parsed.task_mode -ceq "managed" -and
            [bool]$parsed.task_snapshot_exact -and
            (-not [bool]$parsed.task_untouched) -and
            [bool]$parsed.task_scheduler_accessed) -or
            ([int]$parsed.journal_schema -eq 4 -and
            [string]$parsed.task_mode -ceq "untouched" -and
            (-not [bool]$parsed.task_snapshot_exact) -and
            [bool]$parsed.task_untouched -and
            (-not [bool]$parsed.task_scheduler_accessed))) -or
        $targetExitCode -ne 0 -or
        -not [bool]$parsed.file_targets_exact -or
        -not [bool]$parsed.live_release_absent -or
        -not [bool]$parsed.staging_absent -or
        -not [bool]$parsed.rollback_non_acl_exact -or
        [bool]$parsed.token_read -or
        [bool]$parsed.task_write_attempted -or
        [bool]$parsed.connector_state_mutated -or
        [bool]$parsed.connector_state_content_mutated) {
        Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
    }

    $statusValid = switch ($operation) {
        "verify" {
            if ([string]$parsed.status -ceq "repair_ready") {
                [int]$parsed.journal_schema -eq 3 -and
                    [string]$parsed.task_mode -ceq "managed" -and
                    (-not [bool]$parsed.rollback_exact) -and
                    (-not [bool]$parsed.connector_data_acl_exact) -and
                    [bool]$parsed.repair_ready -and
                    (-not [bool]$parsed.acl_repaired) -and
                    (-not [bool]$parsed.finalize_requested) -and
                    (-not [bool]$parsed.finalize_performed) -and
                    (-not [bool]$parsed.mutation_performed) -and
                    [bool]$parsed.journal_retained -and
                    (-not [bool]$parsed.connector_acl_mutated)
            } elseif ([string]$parsed.status -ceq "rollback_exact") {
                [bool]$parsed.rollback_exact -and
                    [bool]$parsed.connector_data_acl_exact -and
                    (-not [bool]$parsed.repair_ready) -and
                    (-not [bool]$parsed.acl_repaired) -and
                    (-not [bool]$parsed.finalize_requested) -and
                    (-not [bool]$parsed.finalize_performed) -and
                    (-not [bool]$parsed.mutation_performed) -and
                    [bool]$parsed.journal_retained -and
                    (-not [bool]$parsed.connector_acl_mutated)
            } else {
                $false
            }
            break
        }
        "repair" {
            [string]$parsed.status -ceq "acl_repaired" -and
                [int]$parsed.journal_schema -eq 3 -and
                [string]$parsed.task_mode -ceq "managed" -and
                [bool]$parsed.rollback_exact -and
                [bool]$parsed.connector_data_acl_exact -and
                (-not [bool]$parsed.repair_ready) -and
                [bool]$parsed.acl_repaired -and
                (-not [bool]$parsed.finalize_requested) -and
                (-not [bool]$parsed.finalize_performed) -and
                [bool]$parsed.mutation_performed -and
                [bool]$parsed.journal_retained -and
                [bool]$parsed.connector_acl_mutated
            break
        }
        "finalize" {
            [string]$parsed.status -ceq "finalized" -and
                [bool]$parsed.rollback_exact -and
                [bool]$parsed.connector_data_acl_exact -and
                (-not [bool]$parsed.repair_ready) -and
                (-not [bool]$parsed.acl_repaired) -and
                [bool]$parsed.finalize_requested -and
                [bool]$parsed.finalize_performed -and
                [bool]$parsed.mutation_performed -and
                (-not [bool]$parsed.journal_retained) -and
                (-not [bool]$parsed.connector_acl_mutated)
            break
        }
    }
    if (-not $statusValid) {
        Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
    }
} else {
    $failureCodes = @(
        "invalid_arguments", "initialization_failed", "verification_failed",
        "acl_repair_failed", "finalization_failed", "internal_error"
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
    $allowedFailureCodes = switch ($operation) {
        "verify" {
            @("initialization_failed", "verification_failed", "internal_error")
            break
        }
        "repair" {
            @(
                "initialization_failed", "verification_failed",
                "acl_repair_failed", "internal_error"
            )
            break
        }
        "finalize" {
            @(
                "initialization_failed", "verification_failed",
                "finalization_failed", "internal_error"
            )
            break
        }
    }
    $failureMutationValid = switch ($operation) {
        "verify" {
            (-not [bool]$parsed.mutation_performed) -and
                (-not [bool]$parsed.connector_acl_mutated) -and
                [bool]$parsed.journal_retained
            break
        }
        "repair" {
            ([bool]$parsed.mutation_performed -eq
                [bool]$parsed.connector_acl_mutated) -and
                [bool]$parsed.journal_retained
            break
        }
        "finalize" {
            (-not [bool]$parsed.connector_acl_mutated) -and
                ([bool]$parsed.journal_retained -or
                ([bool]$parsed.mutation_performed -and
                (-not [bool]$parsed.journal_retained)))
            break
        }
    }
    $diagnosticAllowed = switch ([string]$parsed.error_code) {
        "invalid_arguments" {
            [string]$parsed.diagnostic_code -ceq "arguments_invalid"
            break
        }
        "initialization_failed" {
            @("common_load_failed", "protected_paths_invalid") -ccontains
                [string]$parsed.diagnostic_code
            break
        }
        "verification_failed" {
            @(
                "journal_invalid", "journal_backup_invalid",
                "manifest_invalid", "file_snapshot_mismatch",
                "task_snapshot_mismatch", "release_layout_mismatch",
                "acl_snapshot_mismatch", "acl_repair_ineligible",
                "acl_repair_not_required", "acl_repair_required",
                "concurrent_journal_change", "concurrent_state_change",
                "concurrent_acl_change", "concurrent_content_change"
            ) -ccontains [string]$parsed.diagnostic_code
            break
        }
        "acl_repair_failed" {
            @(
                "concurrent_journal_change", "concurrent_state_change",
                "concurrent_acl_change", "concurrent_content_change",
                "acl_repair_apply_failed"
            ) -ccontains [string]$parsed.diagnostic_code
            break
        }
        "finalization_failed" {
            @(
                "finalize_archive_failed", "finalize_reverification_failed",
                "finalize_clear_failed"
            ) -ccontains [string]$parsed.diagnostic_code
            break
        }
        "internal_error" {
            [string]$parsed.diagnostic_code -ceq "internal_error"
            break
        }
        default { $false; break }
    }
    $operationDiagnosticAllowed = if (
        [string]$parsed.error_code -cne "verification_failed"
    ) {
        $true
    } else {
        $baseVerificationCodes = @(
            "journal_invalid", "journal_backup_invalid", "manifest_invalid",
            "file_snapshot_mismatch", "task_snapshot_mismatch",
            "release_layout_mismatch", "acl_snapshot_mismatch",
            "acl_repair_ineligible"
        )
        $operationVerificationCodes = switch ($operation) {
            "verify" { $baseVerificationCodes; break }
            "repair" {
                $baseVerificationCodes + @(
                    "acl_repair_not_required", "concurrent_journal_change",
                    "concurrent_state_change", "concurrent_acl_change",
                    "concurrent_content_change"
                )
                break
            }
            "finalize" {
                $baseVerificationCodes + @("acl_repair_required")
                break
            }
        }
        $operationVerificationCodes -ccontains [string]$parsed.diagnostic_code
    }
    if (-not (Test-AIChatExactFields $parsed $failureFields) -or
        -not (Test-AIChatBooleanFields $parsed $commonBooleanFields) -or
        $parsed.status -isnot [string] -or
        $parsed.error_code -isnot [string] -or
        $parsed.diagnostic_code -isnot [string] -or
        [string]$parsed.status -cne [string]$parsed.error_code -or
        $failureCodes -cnotcontains [string]$parsed.error_code -or
        $allowedFailureCodes -cnotcontains [string]$parsed.error_code -or
        $diagnosticCodes -cnotcontains [string]$parsed.diagnostic_code -or
        -not $diagnosticAllowed -or
        -not $operationDiagnosticAllowed -or
        $targetExitCode -ne 1 -or
        -not $failureMutationValid -or
        [bool]$parsed.token_read -or
        [bool]$parsed.task_write_attempted -or
        [bool]$parsed.connector_state_mutated -or
        [bool]$parsed.connector_state_content_mutated -or
        [bool]$parsed.finalize_performed) {
        Write-AIChatRunnerFailure $operation "target_contract_invalid" $targetExitCode $mutationCapable
    }
}

[Console]::Out.Write($stdout)
exit $targetExitCode
} catch {
    $unexpectedExitCode = $null
    $terminationFailed = $false
    if ($targetStarted -and $null -ne $process) {
        try {
            if (-not $process.HasExited) {
                $terminationFailed = -not (Stop-AIChatRunnerTarget $process)
            }
            if (-not $terminationFailed -and $process.HasExited) {
                $unexpectedExitCode = [int]$process.ExitCode
            }
        } catch {
            $terminationFailed = $true
        }
    }
    if ($terminationFailed) {
        Write-AIChatRunnerFailure `
            $operation `
            "target_termination_failed" `
            $null `
            ($targetStarted -and $mutationCapable)
    }
    Write-AIChatRunnerFailure `
        $operation `
        "runner_internal_error" `
        $unexpectedExitCode `
        ($targetStarted -and $mutationCapable)
}

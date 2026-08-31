[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This runner test requires Windows PowerShell 5.1"
}

$serviceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\connector-service")).Path
$sourceRunner = Join-Path $serviceRoot "invoke-recovery-json.ps1"
$sourceRecovery = Join-Path $serviceRoot "recover-transaction.ps1"
$unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "aichat runner (&) $unicodeProbe $([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

$targetFixture = @'
[CmdletBinding()]
param(
    [switch]$Finalize,
    [switch]$RepairConnectorAcl,
    [switch]$Apply,
    [string]$OutputFormat = "Human"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($OutputFormat -cne "Json") {
    [Console]::Error.WriteLine("wrong output format")
    exit 9
}
$operation = if ($RepairConnectorAcl) {
    if (-not $Apply -or $Finalize) {
        [Console]::Error.WriteLine("wrong repair arguments")
        exit 9
    }
    "repair"
} elseif ($Finalize) {
    if (-not $Apply) {
        [Console]::Error.WriteLine("wrong finalize arguments")
        exit 9
    }
    "finalize"
} else {
    if ($Apply) {
        [Console]::Error.WriteLine("wrong verify arguments")
        exit 9
    }
    "verify"
}
$mode = if ($operation -eq "verify") { "read_only" } else { "apply" }
$scenario = [string]$env:AICHAT_RUNNER_TEST_SCENARIO

if ($scenario -eq "timeout") {
    [IO.File]::WriteAllText(
        $env:AICHAT_RUNNER_TEST_PID_PATH,
        [string][Diagnostics.Process]::GetCurrentProcess().Id,
        [Text.UTF8Encoding]::new($false)
    )
    Start-Sleep -Seconds 30
    exit 0
}

if ($scenario -eq "inner_failure" -or
    $scenario -eq "protected_paths_invalid" -or
    $scenario -eq "bad_diagnostic" -or
    $scenario -eq "bad_error_code" -or
    $scenario -eq "bad_operation_diagnostic" -or
    $scenario -eq "bad_mutation") {
    $errorCode = switch ($operation) {
        "verify" { "verification_failed"; break }
        "repair" { "acl_repair_failed"; break }
        "finalize" { "finalization_failed"; break }
    }
    $diagnosticCode = switch ($operation) {
        "verify" { "manifest_invalid"; break }
        "repair" { "acl_repair_apply_failed"; break }
        "finalize" { "finalize_archive_failed"; break }
    }
    if ($scenario -eq "protected_paths_invalid") {
        $errorCode = "verification_failed"
        $diagnosticCode = "protected_paths_invalid"
    } elseif ($scenario -eq "bad_error_code") {
        $errorCode = "acl_repair_failed"
        $diagnosticCode = "acl_repair_apply_failed"
    } elseif ($scenario -eq "bad_operation_diagnostic") {
        $errorCode = "verification_failed"
        $diagnosticCode = "acl_repair_not_required"
    }
    $value = [pscustomobject][ordered]@{
        contract_version = 2
        operation = $operation
        mode = $mode
        success = $false
        status = $errorCode
        error_code = $errorCode
        diagnostic_code = $diagnosticCode
        mutation_performed = if ($scenario -eq "protected_paths_invalid") {
            $false
        } else {
            $operation -ne "verify"
        }
        journal_retained = $true
        token_read = $false
        task_write_attempted = $false
        connector_state_mutated = $false
        connector_state_content_mutated = $false
        connector_acl_mutated = if ($scenario -eq "protected_paths_invalid") {
            $false
        } else {
            $operation -eq "repair"
        }
        finalize_performed = $false
    }
} else {
    $status = switch ($operation) {
        "verify" { "rollback_exact"; break }
        "repair" { "acl_repaired"; break }
        "finalize" { "finalized"; break }
    }
    $value = [pscustomobject][ordered]@{
        contract_version = 2
        operation = $operation
        mode = $mode
        success = $true
        status = $status
        transaction_id = "20260901T000000Z-1234abcd"
        journal_schema = 3
        file_targets_exact = $true
        task_snapshot_exact = $true
        task_mode = "managed"
        task_untouched = $false
        task_scheduler_accessed = $true
        connector_data_acl_exact = $true
        live_release_absent = $true
        staging_absent = $true
        failed_release_preserved = $true
        rollback_exact = $true
        rollback_non_acl_exact = $true
        repair_ready = $false
        acl_repaired = $operation -eq "repair"
        finalize_requested = $operation -eq "finalize"
        finalize_performed = $operation -eq "finalize"
        mutation_performed = $operation -ne "verify"
        journal_retained = $operation -ne "finalize"
        token_read = $false
        task_write_attempted = $false
        connector_state_mutated = $false
        connector_state_content_mutated = $false
        connector_acl_mutated = $operation -eq "repair"
    }
}

if ($scenario -eq "schema4") {
    $value.journal_schema = 4
    $value.task_mode = "untouched"
    $value.task_snapshot_exact = $false
    $value.task_untouched = $true
    $value.task_scheduler_accessed = $false
    $value.failed_release_preserved = $false
}

$json = $value | ConvertTo-Json -Compress -Depth 8
if ($scenario -eq "duplicate_key") {
    $json = $json.Replace(
        '{"contract_version":2,',
        '{"contract_version":2,"contract_version":2,'
    )
} elseif ($scenario -eq "bad_contract") {
    $json = $json.Replace('"contract_version":2', '"contract_version":1')
} elseif ($scenario -eq "bad_fields") {
    $json = $json.Replace(',"transaction_id":"20260901T000000Z-1234abcd"', '')
} elseif ($scenario -eq "bad_type") {
    $json = $json.Replace('"success":true', '"success":"true"')
} elseif ($scenario -eq "bad_mode") {
    $json = $json.Replace('"mode":"read_only"', '"mode":"apply"')
} elseif ($scenario -eq "bad_success_invariant") {
    $json = $json.Replace('"file_targets_exact":true', '"file_targets_exact":false')
} elseif ($scenario -eq "bad_enum") {
    $json = $json.Replace('"status":"rollback_exact"', '"status":"other"')
    $json = $json.Replace('"status":"acl_repaired"', '"status":"other"')
    $json = $json.Replace('"status":"finalized"', '"status":"other"')
} elseif ($scenario -eq "bad_diagnostic") {
    $json = $json.Replace('"diagnostic_code":"manifest_invalid"', '"diagnostic_code":"other"')
} elseif ($scenario -eq "bad_mutation") {
    $json = $json.Replace('"mutation_performed":false', '"mutation_performed":true')
}

if ($scenario -ne "empty") {
    [IO.File]::WriteAllText(
        $env:AICHAT_RUNNER_TEST_EXPECTED_PATH,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
}

switch ($scenario) {
    "empty" { exit 0 }
    "double_json" {
        [Console]::Out.WriteLine($json)
        [Console]::Out.WriteLine($json)
        exit 0
    }
    "extra_whitespace" {
        [Console]::Out.WriteLine(" $json")
        exit 0
    }
    "malformed" {
        [Console]::Out.WriteLine('{"bad":}')
        exit 0
    }
    "bom" {
        [Console]::Out.Write([char]0xfeff)
        [Console]::Out.WriteLine($json)
        exit 0
    }
    "stderr" {
        [Console]::Out.WriteLine($json)
        [Console]::Error.WriteLine("sensitive-path=C:\private token=secret SID=S-1-5 SDDL=O:BAD")
        exit 0
    }
    "exit_mismatch" {
        [Console]::Out.WriteLine($json)
        exit 1
    }
    default {
        [Console]::Out.WriteLine($json)
        if ($scenario -eq "inner_failure" -or
            $scenario -eq "protected_paths_invalid" -or
            $scenario -eq "bad_diagnostic" -or
            $scenario -eq "bad_error_code" -or
            $scenario -eq "bad_operation_diagnostic" -or
            $scenario -eq "bad_mutation") { exit 1 }
        exit 0
    }
}
'@

$realRecoveryCommonFixture = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-AIChatConnectorPaths {
    $root = [string]$env:AICHAT_RUNNER_REAL_RECOVERY_ROOT
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
    throw "synthetic protected path failure at C:\private token=secret SID=S-1-5 SDDL=O:BAD"
}
'@

function New-RunnerCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$TargetText = $targetFixture,
        [switch]$MissingTarget,
        [switch]$ShortTimeout,
        [switch]$InjectRunnerFailure,
        [switch]$InjectAfterStart
    )

    $caseRoot = Join-Path $testRoot $Name
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    $runnerText = Get-Content -LiteralPath $sourceRunner -Raw
    if ($ShortTimeout) {
        $runnerText = $runnerText.Replace(
            '$timeoutMilliseconds = 120000',
            '$timeoutMilliseconds = 500'
        )
    }
    if ($InjectRunnerFailure) {
        $runnerText = $runnerText.Replace(
            '$mutationCapable = $operation -ne "verify"',
            '$mutationCapable = $operation -ne "verify"' + "`n" +
                "throw 'sensitive-path=C:\private token=secret SID=S-1-5 SDDL=O:BAD'"
        )
    }
    if ($InjectAfterStart) {
        $runnerText = $runnerText.Replace(
            '$targetStarted = $true',
            '$targetStarted = $true' + "`n" +
                'Start-Sleep -Milliseconds 300' + "`n" +
                "throw 'sensitive-path=C:\private token=secret SID=S-1-5 SDDL=O:BAD'"
        )
    }
    [IO.File]::WriteAllText(
        (Join-Path $caseRoot "invoke-recovery-json.ps1"),
        $runnerText,
        [Text.UTF8Encoding]::new($false)
    )
    if (-not $MissingTarget) {
        [IO.File]::WriteAllText(
            (Join-Path $caseRoot "recover-transaction.ps1"),
            $TargetText,
            [Text.UTF8Encoding]::new($false)
        )
    }
    return $caseRoot
}

function New-RealRecoveryRunnerCase {
    param([Parameter(Mandatory = $true)][string]$Name)

    $caseRoot = New-RunnerCase `
        -Name $Name `
        -TargetText (Get-Content -LiteralPath $sourceRecovery -Raw)
    [IO.File]::WriteAllText(
        (Join-Path $caseRoot "common.ps1"),
        $realRecoveryCommonFixture,
        [Text.UTF8Encoding]::new($false)
    )
    $stateRoot = Join-Path $caseRoot "protected-state"
    New-Item -ItemType Directory -Path $stateRoot | Out-Null
    return [pscustomobject]@{
        CaseRoot = $caseRoot
        StateRoot = $stateRoot
    }
}

function Quote-WindowsArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-RealRecoveryTargetCase {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$StateRoot,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    $targetPath = Join-Path $CaseRoot "recover-transaction.ps1"
    $targetArguments = switch ($Operation) {
        "verify" { @("-OutputFormat", "Json"); break }
        "repair" { @("-RepairConnectorAcl", "-Apply", "-OutputFormat", "Json"); break }
        "finalize" { @("-Finalize", "-Apply", "-OutputFormat", "Json"); break }
        default { throw "Unsupported real recovery operation" }
    }
    $arguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", $targetPath
    ) + $targetArguments
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $startInfo.Arguments = @($arguments | ForEach-Object {
        Quote-WindowsArgument ([string]$_)
    }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["AICHAT_RUNNER_REAL_RECOVERY_ROOT"] = $StateRoot
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) {
        try { $process.Kill() } catch {}
        throw "Real recovery target case timed out"
    }
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
    }
}

function Assert-RealProtectedPathFailure {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation
    )

    if ($Result.ExitCode -ne 1 -or $Result.Stderr.Length -ne 0) {
        throw "$Operation real protected-path failure did not use target exit 1"
    }
    if ($Result.Stdout.EndsWith("`r`n")) {
        $jsonText = $Result.Stdout.Substring(0, $Result.Stdout.Length - 2)
        $expectedStdout = $jsonText + "`r`n"
    } elseif ($Result.Stdout.EndsWith("`n")) {
        $jsonText = $Result.Stdout.Substring(0, $Result.Stdout.Length - 1)
        $expectedStdout = $jsonText + "`n"
    } else {
        throw "$Operation real protected-path failure omitted its newline"
    }
    if (-not $jsonText -or
        $Result.Stdout -cne $expectedStdout -or
        $jsonText.Trim() -cne $jsonText -or
        $jsonText.Contains("`r") -or
        $jsonText.Contains("`n") -or
        -not $jsonText.StartsWith("{") -or
        -not $jsonText.EndsWith("}")) {
        throw "$Operation real protected-path failure framing was invalid"
    }
    foreach ($forbidden in @(
        "C:\private", "token=secret", "S-1-5", "SDDL=O:BAD",
        "state_root=", "task=\AIChat\CodexConnector"
    )) {
        if ($Result.Stdout.Contains($forbidden) -or
            $Result.Stderr.Contains($forbidden)) {
            throw "$Operation real protected-path failure leaked diagnostics"
        }
    }
    $parsed = $jsonText | ConvertFrom-Json
    $actualFields = @($parsed.PSObject.Properties.Name)
    $expectedFields = @(
        "contract_version", "operation", "mode", "success", "status",
        "error_code", "diagnostic_code", "mutation_performed",
        "journal_retained", "token_read", "task_write_attempted",
        "connector_state_mutated", "connector_state_content_mutated",
        "connector_acl_mutated", "finalize_performed"
    )
    if ($actualFields.Count -ne $expectedFields.Count) {
        throw "$Operation real protected-path field count changed"
    }
    for ($index = 0; $index -lt $expectedFields.Count; $index++) {
        if ([string]$actualFields[$index] -cne [string]$expectedFields[$index]) {
            throw "$Operation real protected-path field order changed"
        }
    }
    $expectedMode = if ($Operation -eq "verify") { "read_only" } else { "apply" }
    if ([int]$parsed.contract_version -ne 2 -or
        [string]$parsed.operation -cne $Operation -or
        [string]$parsed.mode -cne $expectedMode -or
        $parsed.success -isnot [bool] -or
        [bool]$parsed.success -or
        [string]$parsed.status -cne "verification_failed" -or
        [string]$parsed.error_code -cne "verification_failed" -or
        [string]$parsed.diagnostic_code -cne "protected_paths_invalid") {
        throw "$Operation real protected-path envelope was invalid"
    }
    foreach ($field in @(
        "mutation_performed", "token_read", "task_write_attempted",
        "connector_state_mutated", "connector_state_content_mutated",
        "connector_acl_mutated", "finalize_performed"
    )) {
        if ($parsed.$field -isnot [bool] -or [bool]$parsed.$field) {
            throw "$Operation real protected-path mutation flag $field was invalid"
        }
    }
    if ($parsed.journal_retained -isnot [bool] -or
        -not [bool]$parsed.journal_retained) {
        throw "$Operation real protected-path journal flag was invalid"
    }
    return $parsed
}

function Invoke-RunnerCase {
    param(
        [Parameter(Mandatory = $true)][string]$CaseRoot,
        [Parameter(Mandatory = $true)][string]$Operation,
        [string]$Scenario = "success",
        [hashtable]$Environment = @{}
    )

    $runnerPath = Join-Path $CaseRoot "invoke-recovery-json.ps1"
    $arguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-ExecutionPolicy", "Bypass", "-File", $runnerPath, $Operation
    )
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $startInfo.Arguments = @($arguments | ForEach-Object {
        Quote-WindowsArgument ([string]$_)
    }) -join " "
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["AICHAT_RUNNER_TEST_SCENARIO"] = $Scenario
    $startInfo.EnvironmentVariables["AICHAT_RUNNER_TEST_EXPECTED_PATH"] =
        (Join-Path $CaseRoot "expected.txt")
    $startInfo.EnvironmentVariables["AICHAT_RUNNER_TEST_PID_PATH"] =
        (Join-Path $CaseRoot "target.pid")
    foreach ($entry in $Environment.GetEnumerator()) {
        $startInfo.EnvironmentVariables[[string]$entry.Key] = [string]$entry.Value
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(15000)) {
        try { $process.Kill() } catch {}
        throw "Runner case timed out"
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    return [pscustomobject]@{
        ExitCode = [int]$process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
    }
}

function Read-RunnerFailure {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][string]$Operation,
        [Parameter(Mandatory = $true)][string]$ErrorCode,
        [Parameter(Mandatory = $true)][bool]$MutationPossible,
        [string]$RejectionCode = "not_applicable"
    )

    if ($Result.ExitCode -ne 2 -or $Result.Stderr.Length -ne 0) {
        throw "$ErrorCode did not use the runner failure channel"
    }
    $forbidden = @("C:\private", "token=secret", "S-1-5", "SDDL=O:BAD")
    foreach ($value in $forbidden) {
        if ($Result.Stdout.Contains($value) -or $Result.Stderr.Contains($value)) {
            throw "$ErrorCode leaked a forbidden diagnostic"
        }
    }
    if ($Result.Stdout.EndsWith("`r`n")) {
        $jsonText = $Result.Stdout.Substring(0, $Result.Stdout.Length - 2)
        $expectedStdout = $jsonText + "`r`n"
    } elseif ($Result.Stdout.EndsWith("`n")) {
        $jsonText = $Result.Stdout.Substring(0, $Result.Stdout.Length - 1)
        $expectedStdout = $jsonText + "`n"
    } else {
        throw "$ErrorCode omitted the JSON newline"
    }
    if (-not $jsonText -or
        $Result.Stdout -cne $expectedStdout -or
        $jsonText.Trim() -cne $jsonText -or
        $jsonText.Contains("`r") -or
        $jsonText.Contains("`n") -or
        -not $jsonText.StartsWith("{") -or
        -not $jsonText.EndsWith("}")) {
        throw "$ErrorCode emitted invalid raw JSON framing"
    }
    foreach ($character in $jsonText.ToCharArray()) {
        if ([int][char]$character -gt 0x7f) {
            throw "$ErrorCode runner JSON was not ASCII"
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
            throw "$ErrorCode runner JSON contained duplicate key $key"
        }
        $seenKeys[$key] = $true
    }
    $parsed = $jsonText | ConvertFrom-Json
    $fields = @($parsed.PSObject.Properties.Name)
    $expectedFields = @(
        "runner_contract_version", "operation", "success", "error_code",
        "rejection_code", "target_exit_code", "mutation_possible"
    )
    if ($fields.Count -ne $expectedFields.Count) {
        throw "$ErrorCode runner field count changed"
    }
    for ($index = 0; $index -lt $expectedFields.Count; $index++) {
        if ($fields[$index] -cne $expectedFields[$index]) {
            throw "$ErrorCode runner field order changed"
        }
    }
    if ([int]$parsed.runner_contract_version -ne 2 -or
        [string]$parsed.operation -cne $Operation -or
        $parsed.success -isnot [bool] -or
        [bool]$parsed.success -or
        [string]$parsed.error_code -cne $ErrorCode -or
        [string]$parsed.rejection_code -cne $RejectionCode -or
        $parsed.mutation_possible -isnot [bool] -or
        [bool]$parsed.mutation_possible -ne $MutationPossible) {
        throw "$ErrorCode runner contract values are invalid"
    }
    $nullExitCodes = @(
        "invalid_runner_arguments", "target_missing",
        "powershell_51_unavailable", "target_start_failed", "target_timeout",
        "target_termination_failed"
    )
    if ($null -eq $parsed.target_exit_code) {
        if ($nullExitCodes -cnotcontains $ErrorCode -and
            $ErrorCode -cne "runner_internal_error") {
            throw "$ErrorCode unexpectedly omitted target_exit_code"
        }
    } elseif ($parsed.target_exit_code -isnot [int] -and
        $parsed.target_exit_code -isnot [long]) {
        throw "$ErrorCode target_exit_code was not an integer or null"
    }
    return $parsed
}

try {
    $collisionRoot = New-RunnerCase -Name "host-outputformat-collision"
    $collisionTarget = Join-Path $collisionRoot "recover-transaction.ps1"
    $collisionArguments = @(
        "-NoLogo", "-NoProfile", "-NonInteractive",
        "-OutputFormat", "Json", "-File", $collisionTarget
    )
    $collisionStartInfo = [Diagnostics.ProcessStartInfo]::new()
    $collisionStartInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $collisionStartInfo.Arguments = @($collisionArguments | ForEach-Object {
        Quote-WindowsArgument ([string]$_)
    }) -join " "
    $collisionStartInfo.UseShellExecute = $false
    $collisionStartInfo.CreateNoWindow = $true
    $collisionStartInfo.RedirectStandardOutput = $true
    $collisionStartInfo.RedirectStandardError = $true
    $collisionProcess = [Diagnostics.Process]::new()
    $collisionProcess.StartInfo = $collisionStartInfo
    [void]$collisionProcess.Start()
    $collisionStdoutTask = $collisionProcess.StandardOutput.ReadToEndAsync()
    $collisionStderrTask = $collisionProcess.StandardError.ReadToEndAsync()
    if (-not $collisionProcess.WaitForExit(10000)) {
        try { $collisionProcess.Kill() } catch {}
        throw "Native host collision probe timed out"
    }
    $collisionStdout = $collisionStdoutTask.GetAwaiter().GetResult()
    $collisionStderr = $collisionStderrTask.GetAwaiter().GetResult()
    if ($collisionProcess.ExitCode -eq 0 -or
        $collisionStderr.Length -eq 0 -or
        $collisionStdout.Contains('"contract_version"')) {
        throw "Native powershell.exe did not reject host -OutputFormat Json"
    }

    foreach ($operation in @("verify", "repair", "finalize")) {
        $caseRoot = New-RunnerCase -Name "success-$operation"
        $result = Invoke-RunnerCase -CaseRoot $caseRoot -Operation $operation
        $expected = Get-Content -LiteralPath (Join-Path $caseRoot "expected.txt") -Raw
        if ($result.ExitCode -ne 0 -or $result.Stderr.Length -ne 0 -or
            $result.Stdout -cne $expected) {
            throw "$operation success was not forwarded exactly"
        }
    }

    foreach ($operation in @("verify", "repair", "finalize")) {
        $realCase = New-RealRecoveryRunnerCase `
            -Name "real-protected-paths-$operation"
        $environment = @{
            AICHAT_RUNNER_REAL_RECOVERY_ROOT = [string]$realCase.StateRoot
        }
        $direct = Invoke-RealRecoveryTargetCase `
            -CaseRoot ([string]$realCase.CaseRoot) `
            -StateRoot ([string]$realCase.StateRoot) `
            -Operation $operation
        [void](Assert-RealProtectedPathFailure $direct $operation)
        $forwarded = Invoke-RunnerCase `
            -CaseRoot ([string]$realCase.CaseRoot) `
            -Operation $operation `
            -Environment $environment
        [void](Assert-RealProtectedPathFailure $forwarded $operation)
        if ($forwarded.ExitCode -ne $direct.ExitCode -or
            $forwarded.Stdout -cne $direct.Stdout -or
            $forwarded.Stderr -cne $direct.Stderr) {
            throw "$operation real protected-path target was not forwarded byte-exactly"
        }
    }

    foreach ($operation in @("verify", "repair", "finalize")) {
        $caseRoot = New-RunnerCase -Name "protected-paths-$operation"
        $result = Invoke-RunnerCase `
            -CaseRoot $caseRoot `
            -Operation $operation `
            -Scenario "protected_paths_invalid"
        $expected = Get-Content -LiteralPath (Join-Path $caseRoot "expected.txt") -Raw
        if ($result.ExitCode -ne 1 -or $result.Stderr.Length -ne 0 -or
            $result.Stdout -cne $expected) {
            throw "$operation protected_paths_invalid was not forwarded exactly"
        }
    }

    foreach ($operation in @("verify", "finalize")) {
        $caseRoot = New-RunnerCase -Name "schema4-$operation"
        $result = Invoke-RunnerCase `
            -CaseRoot $caseRoot `
            -Operation $operation `
            -Scenario "schema4"
        $expected = Get-Content -LiteralPath (Join-Path $caseRoot "expected.txt") -Raw
        if ($result.ExitCode -ne 0 -or $result.Stderr.Length -ne 0 -or
            $result.Stdout -cne $expected) {
            throw "$operation schema4 success was not forwarded exactly"
        }
    }

    foreach ($operation in @("verify", "repair", "finalize")) {
        $caseRoot = New-RunnerCase -Name "failure-$operation"
        $result = Invoke-RunnerCase `
            -CaseRoot $caseRoot `
            -Operation $operation `
            -Scenario "inner_failure"
        $expected = Get-Content -LiteralPath (Join-Path $caseRoot "expected.txt") -Raw
        if ($result.ExitCode -ne 1 -or $result.Stderr.Length -ne 0 -or
            $result.Stdout -cne $expected) {
            throw "$operation failure was not forwarded exactly"
        }
    }

    $missingRoot = New-RunnerCase -Name "missing" -MissingTarget
    $missing = Invoke-RunnerCase -CaseRoot $missingRoot -Operation "verify"
    [void](Read-RunnerFailure $missing "verify" "target_missing" $false)

    $syntaxRoot = New-RunnerCase -Name "syntax" -TargetText 'function Broken { if ('
    $syntax = Invoke-RunnerCase -CaseRoot $syntaxRoot -Operation "repair"
    [void](Read-RunnerFailure $syntax "repair" "target_stderr" $true)

    $binderTarget = @'
[CmdletBinding()]
param([switch]$Different)
'@
    $binderRoot = New-RunnerCase -Name "binder" -TargetText $binderTarget
    $binder = Invoke-RunnerCase -CaseRoot $binderRoot -Operation "finalize"
    [void](Read-RunnerFailure $binder "finalize" "target_stderr" $true)

    foreach ($scenario in @(
        "stderr", "empty", "double_json", "extra_whitespace", "duplicate_key",
        "malformed", "bom", "bad_contract", "bad_fields", "bad_type",
        "bad_mode", "bad_success_invariant", "bad_enum", "bad_diagnostic",
        "bad_error_code",
        "bad_operation_diagnostic", "bad_mutation", "exit_mismatch"
    )) {
        $caseRoot = New-RunnerCase -Name $scenario
        $result = Invoke-RunnerCase `
            -CaseRoot $caseRoot `
            -Operation "verify" `
            -Scenario $scenario
        $expectedError = switch ($scenario) {
            "stderr" { "target_stderr"; break }
            "empty" { "target_output_invalid"; break }
            "double_json" { "target_output_invalid"; break }
            "extra_whitespace" { "target_output_invalid"; break }
            "duplicate_key" { "target_duplicate_key"; break }
            "malformed" { "target_json_invalid"; break }
            "bom" { "target_output_invalid"; break }
            "exit_mismatch" { "target_contract_invalid"; break }
            default { "target_contract_invalid"; break }
        }
        $expectedRejection = switch ($scenario) {
            "bad_contract" { "contract_version_invalid"; break }
            "bad_fields" { "field_set_invalid"; break }
            "bad_type" { "field_type_invalid"; break }
            "bad_mode" { "operation_mode_invalid"; break }
            "bad_success_invariant" { "success_invariant_invalid"; break }
            "bad_enum" { "status_invariant_invalid"; break }
            "bad_diagnostic" { "error_diagnostic_invalid"; break }
            "bad_error_code" { "error_code_invalid"; break }
            "bad_operation_diagnostic" { "operation_diagnostic_invalid"; break }
            "bad_mutation" { "mutation_invariant_invalid"; break }
            "exit_mismatch" { "exit_code_invalid"; break }
            default { "not_applicable"; break }
        }
        [void](Read-RunnerFailure `
            $result `
            "verify" `
            $expectedError `
            $false `
            $expectedRejection)
    }

    $timeoutRoot = New-RunnerCase -Name "timeout" -ShortTimeout
    $timeout = Invoke-RunnerCase `
        -CaseRoot $timeoutRoot `
        -Operation "repair" `
        -Scenario "timeout"
    [void](Read-RunnerFailure $timeout "repair" "target_timeout" $true)
    $pidPath = Join-Path $timeoutRoot "target.pid"
    if (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
        throw "Timeout target did not record its process ID"
    }
    $targetPid = [int](Get-Content -LiteralPath $pidPath -Raw)
    Start-Sleep -Milliseconds 200
    if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
        throw "Timeout left a powershell.exe orphan"
    }

    $internalRoot = New-RunnerCase -Name "internal" -InjectRunnerFailure
    $internal = Invoke-RunnerCase -CaseRoot $internalRoot -Operation "verify"
    [void](Read-RunnerFailure $internal "verify" "runner_internal_error" $false)

    $startedInternalRoot = New-RunnerCase `
        -Name "internal-after-start" `
        -InjectAfterStart
    $startedInternal = Invoke-RunnerCase `
        -CaseRoot $startedInternalRoot `
        -Operation "repair" `
        -Scenario "timeout"
    [void](Read-RunnerFailure `
        $startedInternal `
        "repair" `
        "runner_internal_error" `
        $true)
    $startedPidPath = Join-Path $startedInternalRoot "target.pid"
    if (-not (Test-Path -LiteralPath $startedPidPath -PathType Leaf)) {
        throw "Started internal failure target did not record its process ID"
    }
    $startedPid = [int](Get-Content -LiteralPath $startedPidPath -Raw)
    if (Get-Process -Id $startedPid -ErrorAction SilentlyContinue) {
        throw "Top-level catch left a powershell.exe orphan"
    }

    $invalidRoot = New-RunnerCase -Name "invalid"
    $invalid = Invoke-RunnerCase -CaseRoot $invalidRoot -Operation "other"
    [void](Read-RunnerFailure $invalid "unknown" "invalid_runner_arguments" $false)

    Write-Host "recovery_json_runner_contract=pass"
    Write-Host "host_outputformat_collision=pass"
    Write-Host "special_path_covered=true"
    Write-Host "timeout_orphan_count=0"
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

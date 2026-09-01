[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This contract test requires Windows PowerShell 5.1"
}

$serviceRoot = (Resolve-Path (
    Join-Path $PSScriptRoot "..\connector-service"
)).Path
$sourceDiagnostic = Join-Path $serviceRoot `
    "diagnose-recovery-protected-paths.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "aichat-protected-path-diagnostic-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $testRoot | Out-Null

$sensitiveCanaries = @(
    "S-1-5-21-111111111-222222222-333333333-4444",
    "O:SENSITIVE-G:SENSITIVE-D:(A;;FA;;;SENSITIVE)",
    "secret-token-canary-9f4cb55d",
    "private-sensitive-path-canary",
    ([string][char]0x4e2d) + ([string][char]0x6587)
)

$syntheticCommon = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:AICHAT_DIAGNOSTIC_TEST_SCENARIO -eq "common_failure") {
    $unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
    throw "private-sensitive-path-canary S-1-5-21-111111111-222222222-333333333-4444 O:SENSITIVE-G:SENSITIVE-D:(A;;FA;;;SENSITIVE) secret-token-canary-9f4cb55d $unicodeProbe"
}

function Get-AIChatProtectedRoot {
    if ($env:AICHAT_DIAGNOSTIC_TEST_SCENARIO -eq "resolution_failure") {
        $unicodeProbe = ([string][char]0x4e2d) + ([string][char]0x6587)
        throw "private-sensitive-path-canary S-1-5-21-111111111-222222222-333333333-4444 O:SENSITIVE-G:SENSITIVE-D:(A;;FA;;;SENSITIVE) secret-token-canary-9f4cb55d $unicodeProbe"
    }
    return $env:AICHAT_DIAGNOSTIC_TEST_PROTECTED_ROOT
}

function Get-AIChatCurrentSid {
    return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

function Get-AIChatConnectorPaths { throw "connector-path-canary" }
function Get-AIChatConnectorDataRoot { throw "connector-data-canary" }
function Get-AIChatConnectorTask { throw "scheduler-access-canary" }
function Read-AIChatPrivateJson { throw "journal-canary" }
'@

function Set-DiagnosticDirectoryAcl {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Security.AccessControl.FileSystemRights]$Rights =
            [Security.AccessControl.FileSystemRights]::FullControl,
        [switch]$AddSystem,
        [switch]$Unprotected
    )

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($identity.User)
    $security.SetAccessRuleProtection((-not $Unprotected), $false)
    $inheritance =
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $currentRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity.User,
        $Rights,
        $inheritance,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow
    )
    [void]$security.AddAccessRule($currentRule)
    if ($AddSystem) {
        $systemSid = [Security.Principal.SecurityIdentifier]::new("S-1-5-18")
        $systemRule = [Security.AccessControl.FileSystemAccessRule]::new(
            $systemSid,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
        [void]$security.AddAccessRule($systemRule)
    }
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-DiagnosticFixtureSnapshot {
    param([Parameter(Mandatory = $true)][string]$Path)

    $items = @(Get-Item -LiteralPath $Path -Force) +
        @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
    $entries = @()
    foreach ($item in $items) {
        $relative = $item.FullName.Substring($Path.Length)
        $acl = Get-Acl -LiteralPath $item.FullName
        $hash = if ($item.PSIsContainer) {
            ""
        } else {
            (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        }
        $entries += [pscustomobject][ordered]@{
            relative = $relative
            directory = [bool]$item.PSIsContainer
            attributes = [int]$item.Attributes
            hash = $hash
            security = $acl.GetSecurityDescriptorSddlForm(
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Access
            )
        }
    }
    return ($entries | ConvertTo-Json -Compress -Depth 5)
}

function Invoke-DiagnosticCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][string]$ExpectedResult,
        [Parameter(Mandatory = $true)][string]$ExpectedPhase,
        [Parameter(Mandatory = $true)][int]$ExpectedLevel,
        [Parameter(Mandatory = $true)][string]$ExpectedLayer,
        [Parameter(Mandatory = $true)][string]$ExpectedReason,
        [ValidateSet(
            "exact", "missing_state", "state_file", "unprotected_root",
            "state_extra_rule", "state_rule_shape"
        )]
        [string]$Fixture = "exact"
    )

    $caseRoot = Join-Path $testRoot $Name
    $runnerRoot = Join-Path $caseRoot "runner"
    $protectedRoot = Join-Path $caseRoot "private-sensitive-path-canary"
    $stateRoot = Join-Path $protectedRoot "codex-connector-task"
    New-Item -ItemType Directory -Path $runnerRoot | Out-Null
    New-Item -ItemType Directory -Path $protectedRoot | Out-Null
    if ($Fixture -eq "state_file") {
        [IO.File]::WriteAllText(
            $stateRoot,
            "fixed-content",
            [Text.UTF8Encoding]::new($false)
        )
    } elseif ($Fixture -ne "missing_state") {
        New-Item -ItemType Directory -Path $stateRoot | Out-Null
    }
    Set-DiagnosticDirectoryAcl -Path $protectedRoot `
        -Unprotected:($Fixture -eq "unprotected_root")
    if (Test-Path -LiteralPath $stateRoot -PathType Container) {
        Set-DiagnosticDirectoryAcl `
            -Path $stateRoot `
            -AddSystem:($Fixture -eq "state_extra_rule") `
            -Rights $(if ($Fixture -eq "state_rule_shape") {
                [Security.AccessControl.FileSystemRights]::ReadAndExecute
            } else {
                [Security.AccessControl.FileSystemRights]::FullControl
            })
    }

    Copy-Item -LiteralPath $sourceDiagnostic -Destination (
        Join-Path $runnerRoot "diagnose-recovery-protected-paths.ps1"
    )
    [IO.File]::WriteAllText(
        (Join-Path $runnerRoot "common.ps1"),
        $syntheticCommon,
        [Text.UTF8Encoding]::new($false)
    )

    $before = Get-DiagnosticFixtureSnapshot -Path $caseRoot
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $argumentList = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", (Join-Path $runnerRoot `
            "diagnose-recovery-protected-paths.ps1")
    )
    $startInfo.Arguments = (@($argumentList | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables[
        "AICHAT_DIAGNOSTIC_TEST_PROTECTED_ROOT"
    ] = $protectedRoot
    $startInfo.EnvironmentVariables[
        "AICHAT_DIAGNOSTIC_TEST_SCENARIO"
    ] = $Scenario
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()
    $after = Get-DiagnosticFixtureSnapshot -Path $caseRoot

    if ($process.ExitCode -ne $ExpectedExit) {
        throw "$Name exit code mismatch"
    }
    if ($stderr.Length -ne 0) {
        throw "$Name emitted stderr"
    }
    if ($before -cne $after) {
        throw "$Name mutated its fixture"
    }
    $trimmed = $stdout.TrimEnd([char[]]"`r`n")
    if (-not $trimmed -or $trimmed.Contains("`r") -or $trimmed.Contains("`n")) {
        throw "$Name did not emit exactly one JSON line"
    }
    foreach ($character in $trimmed.ToCharArray()) {
        if ([int][char]$character -gt 0x7f) {
            throw "$Name emitted non-ASCII output"
        }
    }
    foreach ($canary in $sensitiveCanaries) {
        if ($stdout.Contains($canary) -or $stderr.Contains($canary)) {
            throw "$Name exposed a sensitive canary"
        }
    }

    $value = $trimmed | ConvertFrom-Json
    $expectedNames = @(
        "contract_version", "operation", "mode", "success", "status",
        "result", "phase", "level", "layer", "reason",
        "mutation_performed", "token_read", "journal_read",
        "connector_data_accessed", "task_scheduler_accessed",
        "connector_process_accessed"
    )
    $actualNames = @($value.PSObject.Properties.Name)
    if (($actualNames -join "|") -cne ($expectedNames -join "|")) {
        throw "$Name field set or order mismatch"
    }
    if ([int]$value.contract_version -ne 1 -or
        [string]$value.operation -cne "diagnose_protected_paths" -or
        [string]$value.mode -cne "read_only" -or
        [string]$value.status -cne $ExpectedStatus -or
        [string]$value.result -cne $ExpectedResult -or
        [string]$value.phase -cne $ExpectedPhase -or
        [int]$value.level -ne $ExpectedLevel -or
        [string]$value.layer -cne $ExpectedLayer -or
        [string]$value.reason -cne $ExpectedReason -or
        [bool]$value.success -ne ($ExpectedResult -cne "indeterminate") -or
        [bool]$value.mutation_performed -or
        [bool]$value.token_read -or
        [bool]$value.journal_read -or
        [bool]$value.connector_data_accessed -or
        [bool]$value.task_scheduler_accessed -or
        [bool]$value.connector_process_accessed) {
        throw "$Name contract value mismatch"
    }
}

try {
    Invoke-DiagnosticCase `
        -Name "exact" -Scenario "normal" -Fixture "exact" `
        -ExpectedExit 0 -ExpectedStatus "exact" -ExpectedResult "exact" `
        -ExpectedPhase "acl" -ExpectedLevel 1 -ExpectedLayer "state_root" `
        -ExpectedReason "none"
    Invoke-DiagnosticCase `
        -Name "missing-state" -Scenario "normal" -Fixture "missing_state" `
        -ExpectedExit 0 -ExpectedStatus "mismatch" -ExpectedResult "mismatch" `
        -ExpectedPhase "directory_shape" -ExpectedLevel 1 `
        -ExpectedLayer "state_root" -ExpectedReason "layer_missing"
    Invoke-DiagnosticCase `
        -Name "state-file" -Scenario "normal" -Fixture "state_file" `
        -ExpectedExit 0 -ExpectedStatus "mismatch" -ExpectedResult "mismatch" `
        -ExpectedPhase "directory_shape" -ExpectedLevel 1 `
        -ExpectedLayer "state_root" -ExpectedReason "layer_not_directory"
    Invoke-DiagnosticCase `
        -Name "unprotected-root" -Scenario "normal" `
        -Fixture "unprotected_root" `
        -ExpectedExit 0 -ExpectedStatus "mismatch" -ExpectedResult "mismatch" `
        -ExpectedPhase "acl" -ExpectedLevel 0 -ExpectedLayer "protected_root" `
        -ExpectedReason "dacl_unprotected"
    Invoke-DiagnosticCase `
        -Name "state-extra-rule" -Scenario "normal" `
        -Fixture "state_extra_rule" `
        -ExpectedExit 0 -ExpectedStatus "mismatch" -ExpectedResult "mismatch" `
        -ExpectedPhase "acl" -ExpectedLevel 1 -ExpectedLayer "state_root" `
        -ExpectedReason "rule_count_mismatch"
    Invoke-DiagnosticCase `
        -Name "state-rule-shape" -Scenario "normal" `
        -Fixture "state_rule_shape" `
        -ExpectedExit 0 -ExpectedStatus "mismatch" -ExpectedResult "mismatch" `
        -ExpectedPhase "acl" -ExpectedLevel 1 -ExpectedLayer "state_root" `
        -ExpectedReason "rule_shape_mismatch"
    Invoke-DiagnosticCase `
        -Name "resolution-blocked" -Scenario "resolution_failure" `
        -Fixture "exact" -ExpectedExit 1 -ExpectedStatus "blocked" `
        -ExpectedResult "indeterminate" -ExpectedPhase "resolution" `
        -ExpectedLevel -1 -ExpectedLayer "ancestor_chain" `
        -ExpectedReason "resolution_failed"
    Invoke-DiagnosticCase `
        -Name "common-blocked" -Scenario "common_failure" -Fixture "exact" `
        -ExpectedExit 1 -ExpectedStatus "blocked" `
        -ExpectedResult "indeterminate" -ExpectedPhase "internal" `
        -ExpectedLevel -1 -ExpectedLayer "ancestor_chain" `
        -ExpectedReason "internal_error"

    Write-Host "Windows protected-path diagnostic contract tests passed"
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        $cleanupDirectories = @(
            Get-ChildItem -LiteralPath $testRoot -Force -Recurse -Directory |
                Sort-Object { $_.FullName.Length } -Descending
        )
        foreach ($cleanupDirectory in $cleanupDirectories) {
            Set-DiagnosticDirectoryAcl -Path $cleanupDirectory.FullName
        }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

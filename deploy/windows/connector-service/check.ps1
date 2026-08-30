[CmdletBinding()]
param([switch]$Online)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$failures = [Collections.Generic.List[string]]::new()
function Report-AIChatCheck {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $label = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Host "[$label] ${Name}: $Detail"
    if (-not $Passed) { $failures.Add($Name) }
}

$paths = Get-AIChatConnectorPaths
try {
    [void](Assert-AIChatPrivateDirectoryTree `
        -Path $paths.StateRoot `
        -ProtectedRoot $paths.ProtectedRoot)
    Report-AIChatCheck "state-acl" $true "current SID only; inheritance protected"
} catch {
    Report-AIChatCheck "state-acl" $false $_.Exception.Message
}
try {
    [void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)
    Report-AIChatCheck "connector-state-acl" $true "protected current-SID and LocalSystem state/receipt directory"
} catch {
    Report-AIChatCheck "connector-state-acl" $false $_.Exception.Message
}

if (Test-Path -LiteralPath $paths.TransactionPath) {
    Report-AIChatCheck "transaction" $false "unfinished protected transaction journal exists"
} else {
    Report-AIChatCheck "transaction" $true "no unfinished transaction"
}

$settings = $null
$mappingState = $null
try {
    $settings = Get-AIChatConnectorSettings `
        -Path $paths.SettingsPath `
        -ProtectedRoot $paths.ProtectedRoot `
        -RequirePinnedHashes
    Report-AIChatCheck "settings" $true "fixed mapping and binary hashes validated; values suppressed"
} catch {
    Report-AIChatCheck "settings" $false $_.Exception.Message
}
if ($null -ne $settings) {
    try {
        $mappingState = Read-AIChatPrivateJson `
            -Path $paths.MappingStatePath `
            -ProtectedRoot $paths.ProtectedRoot
        [void](Get-AIChatConnectorStatePath `
            -Paths $paths `
            -Settings $settings `
            -MappingState $mappingState)
        Report-AIChatCheck "mapping-state" $true "trusted mapping digest selects the local connector state namespace"
    } catch {
        Report-AIChatCheck "mapping-state" $false $_.Exception.Message
    }
} else {
    Report-AIChatCheck "mapping-state" $false "settings unavailable"
}

try {
    $launcherOutput = & $paths.LauncherPath -StateRoot $paths.StateRoot -CheckSettings *>&1 |
        Out-String
    if ($LASTEXITCODE -ne 0) { throw "installed launcher contract check failed" }
    $expectedEgress = if ($null -ne $settings -and [bool]$settings.egress.enabled) {
        "true"
    } else { "false" }
    $expectedDeliverTypes = if ($null -ne $settings) {
        if ([bool]$settings.deliver_results) { "request,result" } else { "request" }
    } else { "request" }
    if ($launcherOutput -notmatch '(?m)^token_read=false\s*$' -or
        $launcherOutput -notmatch "(?m)^deliver_types=$([regex]::Escape($expectedDeliverTypes))\s*`$" -or
        $launcherOutput -notmatch "(?m)^automatic_egress=$expectedEgress\s*`$" -or
        $launcherOutput -notmatch '(?m)^lifecycle_status_egress=false\s*$' -or
        $launcherOutput -notmatch '(?m)^state_file_fixed=true\s*$' -or
        $launcherOutput -notmatch '(?m)^state_file_mapping_scoped=true\s*$') {
        throw "installed launcher did not report the fixed connector contract"
    }
    Report-AIChatCheck "launcher" $true "fixed inbound types ($expectedDeliverTypes), request-only reply eligibility, controlled result egress, WebSocket, mapping-scoped state, app-server"
} catch {
    Report-AIChatCheck "launcher" $false $_.Exception.Message
}

try {
    $task = Get-AIChatConnectorTask
    if ($null -eq $task) { throw "fixed connector Scheduled Task is absent" }
    Assert-AIChatTaskContract -Task $task -Paths $paths
    Report-AIChatCheck "scheduled-task" $true "disabled, no triggers, current SID, LeastPrivilege, IgnoreNew"
} catch {
    Report-AIChatCheck "scheduled-task" $false $_.Exception.Message
}

try {
    $codexHome = Get-AIChatCodexHome
    Report-AIChatCheck "codex-home" $true "$codexHome; owner verified"
} catch {
    Report-AIChatCheck "codex-home" $false $_.Exception.Message
}

if ($Online -and $null -ne $settings) {
    try {
        $identity = Read-AIChatPrivateJson `
            -Path $settings.identity_config_path `
            -ProtectedRoot $paths.ProtectedRoot
        [void](Test-AIChatRelayIdentity `
            -Identity $identity `
            -ExpectedAgentId ([string]$settings.expected_agent_id))
        Report-AIChatCheck "relay-identity" $true ([string]$settings.expected_agent_id)
    } catch {
        Report-AIChatCheck "relay-identity" $false "authentication or identity binding failed; diagnostic suppressed"
    }
} else {
    Write-Host "[SKIP] relay-identity: use -Online for the credential-bound GET check"
}

Write-Host "token_value_displayed=false"
Write-Host "app_server_initialize_verified=false"
Write-Host "expected_service_enabled=false"
if ($failures.Count -gt 0) {
    Write-Host "AIChat Windows connector check found $($failures.Count) failure(s)."
    exit 1
}
Write-Host "AIChat Windows connector checks passed. Native app-server initialize remains a supervised Windows acceptance step."

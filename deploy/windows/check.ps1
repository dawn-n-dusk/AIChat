[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$StateRoot,
    [string]$ConfigPath,
    [switch]$Online
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

$failures = [Collections.Generic.List[string]]::new()
function Report-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $label = if ($Passed) { "PASS" } else { "FAIL" }
    Write-Host ("[{0}] {1}: {2}" -f $label, $Name, $Detail)
    if (-not $Passed) { $failures.Add($Name) }
}
function Report-Optional {
    param([string]$Name, [bool]$Present, [string]$Detail)
    $label = if ($Present) { "PRESENT" } else { "OPTIONAL/ABSENT" }
    Write-Host ("[{0}] {1}: {2}" -f $label, $Name, $Detail)
}

try {
    $repository = Resolve-AIChatRepositoryRoot -RequestedPath $RepositoryRoot
    Report-Check "repository" $true $repository
} catch {
    Report-Check "repository" $false $_.Exception.Message
    $repository = $null
}
$paths = Get-AIChatWindowsPaths -StateRoot $StateRoot -ConfigPath $ConfigPath
$ownership = Read-Ownership -Path $paths.OwnershipPath
$runtimePaths = @{
    "mcp-runtime"             = Join-Path $paths.RuntimeDirectory "mcp\Scripts\aichat-mcp.exe"
    "codex-connector-runtime" = Join-Path $paths.RuntimeDirectory "codex-connector\src\cli.js"
    "claude-channel-runtime"  = Join-Path $paths.RuntimeDirectory "claude-channel\src\server.js"
    "grok-bridge-runtime"     = Join-Path $paths.RuntimeDirectory "grok-bridge\src\cli.js"
}
$mcpExpected = (Test-Path (Join-Path $paths.RuntimeDirectory "mcp")) -or $ownership.CodexMcpAdded -or $ownership.ClaudeCodeMcpAdded -or $ownership.ClaudeDesktopManaged
$codexConnectorExpected = Test-Path (Join-Path $paths.RuntimeDirectory "codex-connector")
$claudeChannelExpected = (Test-Path (Join-Path $paths.RuntimeDirectory "claude-channel")) -or $ownership.ClaudeChannelMcpAdded
$grokBridgeExpected = Test-Path (Join-Path $paths.RuntimeDirectory "grok-bridge")
$codexExpected = $ownership.CodexMarketplaceAdded -or $ownership.CodexPluginAdded -or $ownership.CodexMcpAdded -or $codexConnectorExpected
$claudeExpected = $ownership.ClaudeCodeMcpAdded -or $ownership.ClaudeChannelMcpAdded
$runnerExpected = $ownership.CodexMcpAdded -or $ownership.ClaudeCodeMcpAdded -or $ownership.ClaudeDesktopManaged -or $codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected
$identityExpected = $Online -or $ownership.CodexPluginAdded -or $mcpExpected -or $codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected
Report-Check "operating-system" ($env:OS -eq "Windows_NT") "Windows 10/11 is required for execution"

if ($codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected) {
    if (Test-ExternalCommand "node") {
        $nodeVersion = (& node --version).Trim()
        $nodeOk = $nodeVersion -match '^v(?<major>\d+)\.' -and [int]$Matches.major -ge 20
        Report-Check "node" $nodeOk $nodeVersion
    } else {
        Report-Check "node" $false "required by an installed Node adapter but not on PATH"
    }
} elseif (Test-ExternalCommand "node") {
    $nodeVersion = (& node --version).Trim()
    Report-Optional "node" $true $nodeVersion
} else {
    Report-Optional "node" $false "required only for installed Node adapters"
}
Report-Optional "npm" (Test-ExternalCommand "npm") "needed to install or repair Node adapters, not to run an installed runtime"
if ($codexExpected) { Report-Check "codex" (Test-ExternalCommand "codex") "required by installed Codex components" } else { Report-Optional "codex" (Test-ExternalCommand "codex") "no Codex component is installer-owned or present" }
if ($ownership.CodexPluginAdded) { Report-Check "uvx" (Test-ExternalCommand "uvx") "required by the installed repository plugin MCP entry" } else { Report-Optional "uvx" (Test-ExternalCommand "uvx") "required only by CodexPlugin" }
if ($claudeExpected) { Report-Check "claude" (Test-ExternalCommand "claude") "required by installed Claude Code components" } else { Report-Optional "claude" (Test-ExternalCommand "claude") "no Claude Code component is installer-owned" }
if ($grokBridgeExpected) { Report-Check "grok" (Test-ExternalCommand "grok") "required by the installed Grok bridge" } else { Report-Optional "grok" (Test-ExternalCommand "grok") "no Grok bridge runtime is present" }

$config = $null
try {
    $config = Read-JsonObject -Path $paths.ConfigPath
    $hasServer = $config.PSObject.Properties["server"] -and [string]$config.server
    $hasToken = $config.PSObject.Properties["token"] -and [string]$config.token
    if ($identityExpected) {
        Report-Check "identity-config" ($hasServer -and $hasToken) "$($paths.ConfigPath); server/token presence checked without displaying token"
    } else {
        Report-Optional "identity-config" ($hasServer -and $hasToken) "$($paths.ConfigPath); no installed component currently requires it"
    }
} catch {
    if ($identityExpected) { Report-Check "identity-config" $false $_.Exception.Message } else { Report-Optional "identity-config" $false $_.Exception.Message }
}

if ($Online -and $null -ne $config -and $config.PSObject.Properties["server"] -and $config.PSObject.Properties["token"]) {
    try {
        $headers = @{ Authorization = "Bearer $([string]$config.token)" }
        $identity = Invoke-RestMethod -Method Get -Uri "$([string]$config.server)/v1/me" -Headers $headers
        $safeId = if ([string]$identity.agent_id) { [string]$identity.agent_id } else { "missing agent_id" }
        Report-Check "relay-identity" ([bool][string]$identity.agent_id) $safeId
    } catch {
        # Do not include the exception: some HTTP stacks include credential-bearing
        # diagnostics. Status detail is intentionally suppressed.
        Report-Check "relay-identity" $false "relay authentication failed; diagnostic suppressed to protect credentials"
    }
}

$runtimeExpected = @{
    "mcp-runtime"             = $mcpExpected
    "codex-connector-runtime" = $codexConnectorExpected
    "claude-channel-runtime"  = $claudeChannelExpected
    "grok-bridge-runtime"     = $grokBridgeExpected
}
foreach ($item in $runtimePaths.GetEnumerator() | Sort-Object Name) {
    $exists = Test-Path -LiteralPath $item.Value -PathType Leaf
    if ($runtimeExpected[$item.Name]) { Report-Check $item.Name $exists $item.Value } else { Report-Optional $item.Name $exists $item.Value }
}
if ($mcpExpected -and (Test-Path $runtimePaths["mcp-runtime"])) {
    $runtimePython = Join-Path $paths.RuntimeDirectory "mcp\Scripts\python.exe"
    if (Test-Path $runtimePython) {
        $probe = Invoke-NativeCapture $runtimePython @("-c", "import aichat_mcp")
        Report-Check "mcp-python" ($probe.ExitCode -eq 0) "installed runtime can import aichat_mcp"
    } else {
        Report-Check "mcp-python" $false "runtime python.exe is missing"
    }
}

if ($runnerExpected) { Report-Check "runner" (Test-Path -LiteralPath $paths.RunnerPath -PathType Leaf) $paths.RunnerPath } else { Report-Optional "runner" (Test-Path -LiteralPath $paths.RunnerPath -PathType Leaf) $paths.RunnerPath }
if (Test-Path -LiteralPath $paths.SettingsPath -PathType Leaf) {
    try {
        $settings = Read-JsonObject -Path $paths.SettingsPath
        $keys = @($settings.PSObject.Properties.Name | Sort-Object) -join ","
        if ($codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected) { Report-Check "adapter-settings" $true "keys=$keys; values not displayed" } else { Report-Optional "adapter-settings" $true "keys=$keys; values not displayed" }
    } catch {
        if ($codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected) { Report-Check "adapter-settings" $false $_.Exception.Message } else { Report-Optional "adapter-settings" $false $_.Exception.Message }
    }
} else {
    if ($codexConnectorExpected -or $claudeChannelExpected -or $grokBridgeExpected) { Report-Check "adapter-settings" $false "required by an installed proactive adapter" } else { Report-Optional "adapter-settings" $false "required only for proactive adapters" }
}

if (Test-ExternalCommand "codex") {
    $marketplaces = Invoke-NativeCapture "codex" @("plugin", "marketplace", "list", "--json")
    $marketplacePresent = $marketplaces.ExitCode -eq 0 -and (Test-OutputContainsName $marketplaces.Output "aichat-repo")
    if ($ownership.CodexMarketplaceAdded) { Report-Check "codex-marketplace" $marketplacePresent "aichat-repo" } else { Report-Optional "codex-marketplace" $marketplacePresent "aichat-repo" }
    $plugins = Invoke-NativeCapture "codex" @("plugin", "list", "--json")
    $pluginPresent = $plugins.ExitCode -eq 0 -and (Test-OutputContainsName $plugins.Output '"aichat"')
    if ($ownership.CodexPluginAdded) { Report-Check "codex-plugin" $pluginPresent "aichat@aichat-repo" } else { Report-Optional "codex-plugin" $pluginPresent "aichat@aichat-repo" }
    $codexMcp = Invoke-NativeCapture "codex" @("mcp", "get", "aichat-local")
    if ($ownership.CodexMcpAdded) { Report-Check "codex-mcp" ($codexMcp.ExitCode -eq 0) "aichat-local" } else { Report-Optional "codex-mcp" ($codexMcp.ExitCode -eq 0) "aichat-local" }
}

if (Test-ExternalCommand "claude") {
    foreach ($item in @(
        [pscustomobject]@{ Name = "aichat-local"; Expected = $ownership.ClaudeCodeMcpAdded },
        [pscustomobject]@{ Name = "aichat-channel"; Expected = $ownership.ClaudeChannelMcpAdded }
    )) {
        $name = $item.Name
        $entry = Invoke-NativeCapture "claude" @("mcp", "get", $name)
        if ($item.Expected) { Report-Check "claude-code-mcp-$name" ($entry.ExitCode -eq 0) $name } else { Report-Optional "claude-code-mcp-$name" ($entry.ExitCode -eq 0) $name }
    }
}

if ($paths.ClaudeDesktopPath -and (Test-Path -LiteralPath $paths.ClaudeDesktopPath -PathType Leaf)) {
    try {
        $desktop = Read-JsonObject -Path $paths.ClaudeDesktopPath
        $present = $desktop.PSObject.Properties["mcpServers"] -and $desktop.mcpServers.PSObject.Properties["aichat"]
        if ($ownership.ClaudeDesktopManaged) { Report-Check "claude-desktop-mcp" ([bool]$present) $paths.ClaudeDesktopPath } else { Report-Optional "claude-desktop-mcp" ([bool]$present) $paths.ClaudeDesktopPath }
    } catch {
        if ($ownership.ClaudeDesktopManaged) { Report-Check "claude-desktop-config" $false $_.Exception.Message } else { Report-Optional "claude-desktop-config" $false $_.Exception.Message }
    }
}

if ($failures.Count -gt 0) {
    Write-Host "AIChat Windows check found $($failures.Count) required failure(s)."
    exit 1
}
Write-Host "AIChat Windows required checks passed. Optional components may still be marked ABSENT."

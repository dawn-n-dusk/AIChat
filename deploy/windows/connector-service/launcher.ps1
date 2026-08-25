[CmdletBinding()]
param(
    [string]$StateRoot,
    [switch]$CheckSettings,
    [switch]$PrintEnvironmentContract
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedStateRoot = if ($StateRoot) {
    [IO.Path]::GetFullPath($StateRoot)
} else {
    [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AIChat\codex-connector-task"))
}
$commonPath = Join-Path $resolvedStateRoot "common.ps1"
if (-not (Test-Path -LiteralPath $commonPath -PathType Leaf)) {
    throw "Installed AIChat connector common module is missing"
}
. $commonPath

$paths = Get-AIChatConnectorPaths -StateRoot $resolvedStateRoot
[void](Assert-AIChatPrivateDirectoryTree -Path $paths.StateRoot -ProtectedRoot $paths.ProtectedRoot)
[void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)

$settings = Get-AIChatConnectorSettings `
    -Path $paths.SettingsPath `
    -ProtectedRoot $paths.ProtectedRoot `
    -RequirePinnedHashes
$active = Read-AIChatPrivateJson `
    -Path $paths.ActiveReleasePath `
    -ProtectedRoot $paths.ProtectedRoot
if (-not $active.PSObject.Properties["schema_version"] -or
    [int]$active.schema_version -ne 1 -or
    -not $active.PSObject.Properties["kind"] -or
    [string]$active.kind -ne "aichat-windows-connector-active-release" -or
    -not $active.PSObject.Properties["release_id"] -or
    [string]$active.release_id -notmatch '^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$') {
    throw "Installed active release metadata is invalid"
}
$releaseRoot = Join-Path $paths.ReleasesDirectory ([string]$active.release_id)
$connectorPath = Join-Path $releaseRoot "runtime\src\cli.js"
$packagePath = Join-Path $releaseRoot "runtime\package.json"
$lockPath = Join-Path $releaseRoot "runtime\package-lock.json"
foreach ($item in @(
    [pscustomobject]@{ Name = "connector_sha256"; Path = $connectorPath },
    [pscustomobject]@{ Name = "package_sha256"; Path = $packagePath },
    [pscustomobject]@{ Name = "package_lock_sha256"; Path = $lockPath }
)) {
    [void](Assert-AIChatNoReparsePath `
        -Path $item.Path `
        -StopAt ([IO.Path]::GetPathRoot($item.Path)))
    $details = Get-Item -LiteralPath $item.Path -Force -ErrorAction Stop
    if ($details.PSIsContainer -or
        ($details.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        (Get-AIChatHardLinkCount -Path $item.Path) -ne 1) {
        throw "Installed connector release contains an unsafe file"
    }
    if (-not $active.PSObject.Properties[$item.Name] -or
        (Get-FileHash -LiteralPath $item.Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne
            ([string]$active.($item.Name)).ToLowerInvariant()) {
        throw "Installed connector release hash validation failed"
    }
}
$tree = Get-AIChatTreeHash `
    -Root (Join-Path $releaseRoot "runtime") `
    -RequireCurrentSidOnlyAcl
if (-not $active.PSObject.Properties["runtime_file_count"] -or
    -not $active.PSObject.Properties["runtime_tree_sha256"] -or
    [int]$active.runtime_file_count -ne $tree.FileCount -or
    [string]$active.runtime_tree_sha256 -ne $tree.Sha256) {
    throw "Installed connector release tree hash validation failed"
}

if ($CheckSettings -or $PrintEnvironmentContract) {
    Write-Host "settings_ok=true"
    Write-Host "identity_content_read=false"
    Write-Host "token_read=false"
    Write-Host "channel_source=connector-settings"
    Write-Host "driver=app-server"
    Write-Host "deliver_types=request"
    Write-Host "automatic_egress=$(([bool]$settings.egress.enabled).ToString().ToLowerInvariant())"
    Write-Host "lifecycle_status_egress=false"
    Write-Host "periodic_recovery=false"
    Write-Host "websocket=true"
    Write-Host "state_file_fixed=true"
    Write-Host "task_owned=true"
    Write-Host "approval_policy=never"
    Write-Host "owner_ipc=false"
    Write-Host "codex_home_fixed=true"
    exit 0
}

$identity = Read-AIChatPrivateJson `
    -Path $settings.identity_config_path `
    -ProtectedRoot $paths.ProtectedRoot
try {
    $serverValue = Test-AIChatRelayIdentity `
        -Identity $identity `
        -ExpectedAgentId ([string]$settings.expected_agent_id)
} catch {
    throw "AIChat Relay identity verification failed; diagnostic suppressed"
}
$token = [string]$identity.token

$processInfo = [Diagnostics.ProcessStartInfo]::new()
$processInfo.FileName = [string]$settings.node_binary
$escapedConnector = '"' + $connectorPath.Replace('"', '\"') + '"'
$processInfo.Arguments = $escapedConnector
$processInfo.WorkingDirectory = $paths.StateRoot
$processInfo.UseShellExecute = $false
$processInfo.CreateNoWindow = $true
$processInfo.EnvironmentVariables.Clear()
foreach ($name in @(
    "SystemRoot", "SYSTEMROOT", "WINDIR", "ComSpec", "COMSPEC", "PATHEXT",
    "PATH", "Path", "TEMP", "TMP", "LANG", "LANGUAGE", "TERM",
    "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS", "NO_PROXY", "no_proxy"
)) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if ($value -and -not $processInfo.EnvironmentVariables.ContainsKey($name)) {
        $processInfo.EnvironmentVariables[$name] = $value
    }
}
$processInfo.EnvironmentVariables["CODEX_HOME"] = Get-AIChatCodexHome
$processInfo.EnvironmentVariables["AICHAT_CODEX_CONNECTOR_ENABLED"] = "true"
$processInfo.EnvironmentVariables["AICHAT_SERVER"] = $serverValue
$processInfo.EnvironmentVariables["AICHAT_TOKEN"] = $token
$processInfo.EnvironmentVariables["AICHAT_CHANNEL_ID"] = [string]$settings.channel_id
$processInfo.EnvironmentVariables["AICHAT_ALLOWED_SENDER_IDS"] = `
    (@($settings.allowed_sender_ids) -join ",")
$processInfo.EnvironmentVariables["AICHAT_DELIVER_TYPES"] = "request"
$processInfo.EnvironmentVariables["AICHAT_AUTONOMOUS_TEXT_ENABLED"] = "false"
$processInfo.EnvironmentVariables["AICHAT_WEBSOCKET_ENABLED"] = "true"
$processInfo.EnvironmentVariables["AICHAT_PERIODIC_RECOVERY_ENABLED"] = "false"
$processInfo.EnvironmentVariables["AICHAT_AUTO_REPLY_ENABLED"] = `
    ([bool]$settings.egress.enabled).ToString().ToLowerInvariant()
$processInfo.EnvironmentVariables["AICHAT_LIFECYCLE_STATUS_ENABLED"] = "false"
$processInfo.EnvironmentVariables["AICHAT_MAX_TURNS_PER_SENDER_PER_HOUR"] = `
    [string]$settings.max_turns_per_sender_per_hour
$processInfo.EnvironmentVariables["AICHAT_MAX_DELIVERIES_PER_RECOVERY"] = `
    [string]$settings.max_deliveries_per_recovery
$processInfo.EnvironmentVariables["AICHAT_STATE_FILE"] = $paths.ConnectorStatePath
$processInfo.EnvironmentVariables["CODEX_DRIVER"] = "app-server"
$processInfo.EnvironmentVariables["CODEX_CONNECTOR_TASK_OWNED"] = "true"
$processInfo.EnvironmentVariables["CODEX_CONNECTOR_TASK_MARKER"] = [string]$settings.task_marker
$processInfo.EnvironmentVariables["CODEX_TARGET_THREAD_ID"] = [string]$settings.target_thread_id
$processInfo.EnvironmentVariables["CODEX_APP_SERVER_CWD"] = [string]$settings.app_server_cwd
$processInfo.EnvironmentVariables["CODEX_APP_SERVER_APPROVAL_POLICY"] = "never"
$processInfo.EnvironmentVariables["CODEX_APP_SERVER_SANDBOX_POLICY_JSON"] = `
    ($settings.sandbox_policy | ConvertTo-Json -Compress -Depth 8)
$processInfo.EnvironmentVariables["CODEX_APP_SERVER_BINARY"] = `
    [string]$settings.codex_app_server_binary
$processInfo.EnvironmentVariables["CODEX_DESKTOP_OWNER_IPC_ENABLED"] = "false"
if ([bool]$settings.egress.enabled) {
    $processInfo.EnvironmentVariables["AICHAT_EGRESS_CHANNEL_AUDIENCE_ACK"] = "true"
    $processInfo.EnvironmentVariables["AICHAT_EGRESS_CANARY_FILE"] = `
        [string]$settings.egress.canary_path
    $processInfo.EnvironmentVariables["AICHAT_EGRESS_ALLOWED_REFERENCE_HOSTS"] = `
        (@($settings.egress.allowed_reference_hosts) -join ",")
    $processInfo.EnvironmentVariables["AICHAT_EGRESS_MAX_TEXT_BYTES"] = `
        [string]$settings.egress.max_text_bytes
}

$process = [Diagnostics.Process]::new()
$process.StartInfo = $processInfo
if (-not $process.Start()) {
    throw "AIChat connector process could not be started"
}
$process.WaitForExit()
exit $process.ExitCode

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [string]$RepositoryRoot,
    [string]$StateRoot,
    [string]$ConfigPath,

    [ValidateSet(
        "CoreMcp",
        "CodexPlugin",
        "CodexMcp",
        "CodexConnector",
        "ClaudeDesktop",
        "ClaudeCodeMcp",
        "ClaudeChannel",
        "GrokBridge"
    )]
    [string[]]$Components = @("CoreMcp", "CodexPlugin"),

    [string]$RelayUrl,
    [string]$ChannelId,
    [string]$AllowedSenderIds,
    [string]$CodexThreadId,
    [string]$GrokWorkDir,
    [string]$GrokCommand,
    [string]$AgentName = "$env:COMPUTERNAME-$env:USERNAME",
    [switch]$RegisterIdentity,

    [string]$MarketplaceSource = "dawn-n-dusk/AIChat",
    [string]$MarketplaceRef = "main",
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($DryRun) {
    $WhatIfPreference = $true
}

. (Join-Path $PSScriptRoot "common.ps1")
$installerCmdlet = $PSCmdlet

$repository = Resolve-AIChatRepositoryRoot -RequestedPath $RepositoryRoot
$paths = Get-AIChatWindowsPaths -StateRoot $StateRoot -ConfigPath $ConfigPath
$selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($component in $Components) {
    [void]$selected.Add($component)
}
if ($selected.Contains("CodexMcp") -or $selected.Contains("ClaudeDesktop") -or $selected.Contains("ClaudeCodeMcp")) {
    [void]$selected.Add("CoreMcp")
}

$runId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") + "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$runBackupDirectory = Join-Path $paths.BackupDirectory $runId
$fileBackups = [Collections.Generic.List[object]]::new()
$runtimeBackups = [Collections.Generic.List[object]]::new()
$ownership = Read-Ownership -Path $paths.OwnershipPath

function Save-FileBackup {
    param([string]$Path)
    $backup = Backup-FileForRun -Path $Path -RunBackupDirectory $runBackupDirectory
    $fileBackups.Add($backup)
}

function Install-NodeRuntime {
    param(
        [Parameter(Mandatory = $true)][string]$AdapterName,
        [Parameter(Mandatory = $true)][string]$RuntimeName
    )

    Assert-Node20
    $source = Join-Path $repository "adapters\$AdapterName"
    $destination = Join-Path $paths.RuntimeDirectory $RuntimeName
    if (-not $installerCmdlet.ShouldProcess($destination, "Install isolated Node adapter runtime from $source")) {
        return
    }

    New-Item -ItemType Directory -Path $paths.RuntimeDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $runBackupDirectory "runtime-$RuntimeName"
        New-Item -ItemType Directory -Path $runBackupDirectory -Force | Out-Null
        Move-Item -LiteralPath $destination -Destination $backup
        $runtimeBackups.Add([pscustomobject]@{ Path = $destination; BackupPath = $backup })
    }

    $temporary = "$destination.tmp-$([Guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory -Path $temporary -Force | Out-Null
    & robocopy.exe $source $temporary /E /XD node_modules coverage .git /XF *.log state.json | Out-Null
    if ($LASTEXITCODE -ge 8) {
        throw "robocopy failed while installing $AdapterName (exit $LASTEXITCODE)"
    }
    Push-Location $temporary
    try {
        & npm ci --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) {
            throw "npm ci failed for $AdapterName"
        }
    } finally {
        Pop-Location
    }
    Move-Item -LiteralPath $temporary -Destination $destination
}

function Install-McpRuntime {
    $source = Join-Path $repository "adapters\mcp"
    $destination = Join-Path $paths.RuntimeDirectory "mcp"
    $python = Resolve-Python311Command
    if (-not $installerCmdlet.ShouldProcess($destination, "Create isolated Python MCP runtime")) {
        return
    }

    New-Item -ItemType Directory -Path $paths.RuntimeDirectory -Force | Out-Null
    if (Test-Path -LiteralPath $destination) {
        $backup = Join-Path $runBackupDirectory "runtime-mcp"
        New-Item -ItemType Directory -Path $runBackupDirectory -Force | Out-Null
        Move-Item -LiteralPath $destination -Destination $backup
        $runtimeBackups.Add([pscustomobject]@{ Path = $destination; BackupPath = $backup })
    }

    $temporary = "$destination.tmp-$([Guid]::NewGuid().ToString('N'))"
    $venvArguments = @($python.Prefix) + @("-m", "venv", $temporary)
    & $python.FilePath @venvArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create the MCP Python virtual environment"
    }
    $runtimePython = Join-Path $temporary "Scripts\python.exe"
    & $runtimePython -m pip install --disable-pip-version-check --no-input $source
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to install the AIChat MCP package"
    }
    Move-Item -LiteralPath $temporary -Destination $destination
}

function Update-IdentityConfig {
    $hasRequestedUpdate = $RegisterIdentity -or $RelayUrl -or $ChannelId
    if (-not $hasRequestedUpdate) {
        return
    }
    $config = Read-JsonObject -Path $paths.ConfigPath
    if ($RelayUrl) {
        $parsed = [Uri]$RelayUrl
        if ($parsed.Scheme -notin @("http", "https") -or -not $parsed.Host) {
            throw "RelayUrl must be an absolute http or https URL"
        }
        Set-ObjectProperty -Object $config -Name "server" -Value $RelayUrl.TrimEnd("/")
    }
    if ($ChannelId) {
        Set-ObjectProperty -Object $config -Name "channel_id" -Value $ChannelId
    }

    $existingToken = $config.PSObject.Properties["token"] -and [string]$config.token
    if ($RegisterIdentity -and -not $existingToken) {
        if (-not $config.PSObject.Properties["server"] -or -not [string]$config.server) {
            throw "RegisterIdentity requires RelayUrl or an existing config.server"
        }
        if (-not $installerCmdlet.ShouldProcess([string]$config.server, "Register a new relay identity and save its token privately")) {
            return
        }
        $body = @{
            name         = $AgentName
            owner        = "$env:USERNAME@$env:COMPUTERNAME"
            capabilities = @($selected | Sort-Object)
        } | ConvertTo-Json -Depth 4
        $registration = Invoke-RestMethod -Method Post -Uri "$([string]$config.server)/v1/agents/register" -ContentType "application/json" -Body $body
        if (-not [string]$registration.agent_id -or -not [string]$registration.token) {
            throw "Relay registration returned an invalid response"
        }
        Set-ObjectProperty -Object $config -Name "agent_id" -Value ([string]$registration.agent_id)
        Set-ObjectProperty -Object $config -Name "agent_name" -Value ([string]$registration.name)
        Set-ObjectProperty -Object $config -Name "token" -Value ([string]$registration.token)
        Write-Host "Registered AIChat identity $([string]$registration.agent_id); token saved privately and not displayed."
    } elseif ($RegisterIdentity) {
        Write-Host "Existing AIChat token preserved; no replacement identity was created."
    }

    if ($installerCmdlet.ShouldProcess($paths.ConfigPath, "Back up and write AIChat identity config")) {
        Save-FileBackup -Path $paths.ConfigPath
        Write-JsonAtomic -Path $paths.ConfigPath -Value $config
        Protect-SecretFile -Path $paths.ConfigPath
    }
}

function Update-AdapterSettings {
    $requested = $AllowedSenderIds -or $CodexThreadId -or $GrokWorkDir -or $GrokCommand
    if (-not $requested) {
        return
    }
    $settings = Read-JsonObject -Path $paths.SettingsPath
    if ($AllowedSenderIds) { Set-ObjectProperty $settings "allowed_sender_ids" $AllowedSenderIds }
    if ($CodexThreadId) { Set-ObjectProperty $settings "codex_thread_id" $CodexThreadId }
    if ($GrokWorkDir) { Set-ObjectProperty $settings "grok_workdir" ([IO.Path]::GetFullPath($GrokWorkDir)) }
    if ($GrokCommand) { Set-ObjectProperty $settings "grok_command" $GrokCommand }
    if (-not $settings.PSObject.Properties["codex_driver"]) {
        Set-ObjectProperty $settings "codex_driver" "auto"
    }
    if ($installerCmdlet.ShouldProcess($paths.SettingsPath, "Back up and write non-secret adapter settings")) {
        Save-FileBackup -Path $paths.SettingsPath
        Write-JsonAtomic -Path $paths.SettingsPath -Value $settings
    }
}

function Install-StateScripts {
    if (-not $installerCmdlet.ShouldProcess($paths.StateRoot, "Install AIChat Windows runner scripts")) {
        return
    }
    New-Item -ItemType Directory -Path $paths.StateRoot -Force | Out-Null
    foreach ($name in @("common.ps1", "run-adapter.ps1")) {
        $destination = Join-Path $paths.StateRoot $name
        Save-FileBackup -Path $destination
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $destination -Force
    }
}

function Install-CodexPlugin {
    if (-not (Test-ExternalCommand "codex")) {
        throw "Codex CLI is required to install the AIChat Codex plugin"
    }
    if (-not (Test-ExternalCommand "uvx")) {
        throw "uvx is required because the repository plugin launches the AIChat MCP adapter through uvx"
    }
    $marketplaces = Invoke-NativeCapture "codex" @("plugin", "marketplace", "list", "--json")
    if ($marketplaces.ExitCode -ne 0) {
        throw "Cannot inspect Codex plugin marketplaces"
    }
    if (-not (Test-OutputContainsName $marketplaces.Output "aichat-repo")) {
        if ($installerCmdlet.ShouldProcess("Codex marketplace aichat-repo", "Add $MarketplaceSource at $MarketplaceRef")) {
            $added = Invoke-NativeCapture "codex" @("plugin", "marketplace", "add", $MarketplaceSource, "--ref", $MarketplaceRef, "--json")
            if ($added.ExitCode -ne 0) { throw "Codex marketplace installation failed: $($added.Output)" }
            $ownership.CodexMarketplaceAdded = $true
        }
    }

    $plugins = Invoke-NativeCapture "codex" @("plugin", "list", "--json")
    if ($plugins.ExitCode -ne 0) { throw "Cannot inspect installed Codex plugins" }
    if (-not (Test-OutputContainsName $plugins.Output '"aichat"')) {
        if ($installerCmdlet.ShouldProcess("aichat@aichat-repo", "Install Codex plugin")) {
            $added = Invoke-NativeCapture "codex" @("plugin", "add", "aichat@aichat-repo", "--json")
            if ($added.ExitCode -ne 0) { throw "Codex plugin installation failed: $($added.Output)" }
            $ownership.CodexPluginAdded = $true
        }
    }
}

function Install-CodexMcp {
    if (-not (Test-ExternalCommand "codex")) { throw "Codex CLI is required for CodexMcp" }
    $existing = Invoke-NativeCapture "codex" @("mcp", "get", "aichat-local")
    if ($existing.ExitCode -eq 0) {
        Write-Host "Codex MCP entry aichat-local already exists and was preserved."
        return
    }
    if ($installerCmdlet.ShouldProcess("Codex MCP aichat-local", "Add local AIChat MCP runner")) {
        $arguments = @(
            "mcp", "add", "aichat-local", "--",
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $paths.RunnerPath, "-Mode", "Mcp", "-ConfigPath", $paths.ConfigPath
        )
        $added = Invoke-NativeCapture "codex" $arguments
        if ($added.ExitCode -ne 0) { throw "Codex MCP installation failed: $($added.Output)" }
        $ownership.CodexMcpAdded = $true
    }
}

function Install-ClaudeCodeMcp {
    param([switch]$Channel)
    if (-not (Test-ExternalCommand "claude")) { throw "Claude Code CLI is required" }
    $name = if ($Channel) { "aichat-channel" } else { "aichat-local" }
    $mode = if ($Channel) { "ClaudeChannel" } else { "Mcp" }
    $existing = Invoke-NativeCapture "claude" @("mcp", "get", $name)
    if ($existing.ExitCode -eq 0) {
        Write-Host "Claude Code MCP entry $name already exists and was preserved."
        return
    }
    if ($installerCmdlet.ShouldProcess("Claude Code MCP $name", "Add local AIChat runner at user scope")) {
        $arguments = @(
            "mcp", "add", "--scope", "user", $name, "--",
            "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass",
            "-File", $paths.RunnerPath, "-Mode", $mode, "-ConfigPath", $paths.ConfigPath
        )
        $added = Invoke-NativeCapture "claude" $arguments
        if ($added.ExitCode -ne 0) { throw "Claude Code MCP installation failed: $($added.Output)" }
        if ($Channel) { $ownership.ClaudeChannelMcpAdded = $true } else { $ownership.ClaudeCodeMcpAdded = $true }
    }
}

function Install-ClaudeDesktopMcp {
    if (-not $paths.ClaudeDesktopPath) { throw "Cannot resolve Claude Desktop config path" }
    $desktop = Read-JsonObject -Path $paths.ClaudeDesktopPath
    if (-not $desktop.PSObject.Properties["mcpServers"] -or $null -eq $desktop.mcpServers) {
        Set-ObjectProperty $desktop "mcpServers" ([pscustomobject]@{})
    }
    $existing = $desktop.mcpServers.PSObject.Properties["aichat"]
    if ($existing) {
        $managed = $existing.Value.PSObject.Properties["env"] -and
            $existing.Value.env.PSObject.Properties["AICHAT_MANAGED_BY"] -and
            $existing.Value.env.AICHAT_MANAGED_BY -eq "AIChat-Windows-Installer"
        if (-not $managed) {
            Write-Host "Claude Desktop already has an unmanaged aichat MCP entry; it was preserved."
            return
        }
    }
    $entry = [pscustomobject]@{
        command = "powershell.exe"
        args = @(
            "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $paths.RunnerPath,
            "-Mode", "Mcp", "-ConfigPath", $paths.ConfigPath
        )
        env = [pscustomobject]@{ AICHAT_MANAGED_BY = "AIChat-Windows-Installer" }
    }
    Set-ObjectProperty $desktop.mcpServers "aichat" $entry
    if ($installerCmdlet.ShouldProcess($paths.ClaudeDesktopPath, "Back up and merge AIChat MCP entry")) {
        Save-FileBackup -Path $paths.ClaudeDesktopPath
        Write-JsonAtomic -Path $paths.ClaudeDesktopPath -Value $desktop
        $ownership.ClaudeDesktopManaged = $true
    }
}

Install-StateScripts
Update-IdentityConfig
Update-AdapterSettings

if ($selected.Contains("CoreMcp")) { Install-McpRuntime }
if ($selected.Contains("CodexConnector")) { Install-NodeRuntime "codex-connector" "codex-connector" }
if ($selected.Contains("ClaudeChannel")) { Install-NodeRuntime "claude-channel" "claude-channel" }
if ($selected.Contains("GrokBridge")) { Install-NodeRuntime "grok-bridge" "grok-bridge" }
if ($selected.Contains("CodexPlugin")) { Install-CodexPlugin }
if ($selected.Contains("CodexMcp")) { Install-CodexMcp }
if ($selected.Contains("ClaudeDesktop")) { Install-ClaudeDesktopMcp }
if ($selected.Contains("ClaudeCodeMcp")) { Install-ClaudeCodeMcp }
if ($selected.Contains("ClaudeChannel")) { Install-ClaudeCodeMcp -Channel }

if ($PSCmdlet.ShouldProcess($paths.OwnershipPath, "Write installer ownership record")) {
    Write-JsonAtomic -Path $paths.OwnershipPath -Value $ownership
}

$manifest = [pscustomobject]@{
    run_id          = $runId
    created_at      = (Get-Date).ToUniversalTime().ToString("o")
    repository_root = $repository
    components      = @($selected | Sort-Object)
    file_backups    = @($fileBackups)
    runtime_backups = @($runtimeBackups)
}
if ($PSCmdlet.ShouldProcess($paths.ManifestDirectory, "Write rollback manifest")) {
    New-Item -ItemType Directory -Path $paths.ManifestDirectory -Force | Out-Null
    Write-JsonAtomic -Path (Join-Path $paths.ManifestDirectory "$runId.json") -Value $manifest
    Write-JsonAtomic -Path (Join-Path $paths.ManifestDirectory "latest.json") -Value $manifest
}

Write-Host "AIChat Windows installation plan completed."
Write-Host "State: $($paths.StateRoot)"
Write-Host "Identity config: $($paths.ConfigPath) (token value never displayed)"
Write-Host "Run deploy\windows\check.ps1 to verify the installation."

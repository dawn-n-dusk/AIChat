[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "Medium")]
param(
    [Parameter(Mandatory = $true)][string]$SettingsPath,
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$settingsSource = [IO.Path]::GetFullPath($SettingsPath)
$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$connectorSource = Join-Path $repository "adapters\codex-connector"

$defaultState = [IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA "AIChat\codex-connector-task")
)
Write-Host "state_root=$defaultState"
Write-Host "task=\AIChat\CodexConnector"
Write-Host "service_enabled=false"
Write-Host "task_triggers=0"
Write-Host "automatic_egress_default=false"
Write-Host "token_read=false"

# WhatIf and the default no-Apply preflight return before ACL changes, file
# creation, npm, COM Task Scheduler access, native probes, or network access.
if (-not $Apply -or $WhatIfPreference) {
    Write-Host "dry_run=true"
    Write-Host "mutation_performed=false"
    Write-Host "security_runtime_checks=deferred_until_apply"
    exit 0
}

foreach ($required in @(
    $settingsSource,
    (Join-Path $connectorSource "package.json"),
    (Join-Path $connectorSource "package-lock.json"),
    (Join-Path $connectorSource "src\cli.js")
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Windows connector install preflight is missing a required file"
    }
}

. (Join-Path $PSScriptRoot "common.ps1")
$paths = Get-AIChatConnectorPaths
$transaction = $null
$backupDirectory = $null
$stage = $null

function Invoke-AIChatInstallFailurePoint {
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE -eq $Name) {
        throw "Injected Windows connector install failure at $Name"
    }
}

function Set-AIChatTransactionStatus {
    param([Parameter(Mandatory = $true)][string]$Status)
    $transaction.status = $Status
    Write-AIChatPrivateJson `
        -Path $paths.TransactionPath `
        -Value $transaction `
        -ProtectedRoot $paths.ProtectedRoot
}

function Remove-AIChatSafeTree {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    [void](Assert-AIChatPrivateDirectoryTree `
        -Path $Path `
        -ProtectedRoot $paths.ProtectedRoot)
    foreach ($item in @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName -Descending)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing to remove a staging tree containing a reparse point"
        }
        if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Refusing to remove a staging tree containing a hardlink alias"
        }
    }
    Remove-Item -LiteralPath $Path -Recurse -Force
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
    $profile = Get-AIChatUserProfile
    $connectorPrivateRoot = Join-Path $profile ".aichat"
    [void](Initialize-AIChatPrivateDirectory `
        -Path $paths.ConnectorDataRoot `
        -ProtectedRoot $connectorPrivateRoot `
        -AnchorRoot $profile)
    [void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)

    if (Test-Path -LiteralPath $paths.TransactionPath -PathType Leaf) {
        $unfinished = Read-AIChatPrivateJson `
            -Path $paths.TransactionPath `
            -ProtectedRoot $paths.ProtectedRoot
        $unfinishedBackup = Join-Path $paths.BackupsDirectory ([string]$unfinished.transaction_id)
        if ([string]$unfinished.status -eq "committed") {
            Assert-AIChatTransactionManifest `
                -Manifest $unfinished `
                -Paths $paths `
                -BackupDirectory $unfinishedBackup `
                -AllowedStatuses @("committed")
            $committedManifest = Join-Path $unfinishedBackup "manifest.json"
            Write-AIChatPrivateJson `
                -Path $committedManifest `
                -Value $unfinished `
                -ProtectedRoot $paths.ProtectedRoot
            $manifestHash = (Get-FileHash -LiteralPath $committedManifest -Algorithm SHA256).Hash.ToLowerInvariant()
            Write-AIChatPrivateJson `
                -Path $paths.LastBackupPath `
                -Value ([pscustomobject]@{
                    schema_version = 1
                    kind = "aichat-windows-connector-last-backup"
                    transaction_id = [string]$unfinished.transaction_id
                    manifest_sha256 = $manifestHash
                }) `
                -ProtectedRoot $paths.ProtectedRoot
        } else {
            Invoke-AIChatManifestRollback `
                -Manifest $unfinished `
                -Paths $paths `
                -BackupDirectory $unfinishedBackup
        }
        [void](Assert-AIChatPrivateFile `
            -Path $paths.TransactionPath `
            -ProtectedRoot $paths.ProtectedRoot)
        Remove-Item -LiteralPath $paths.TransactionPath -Force
    }

    $settings = Get-AIChatConnectorSettings `
        -Path $settingsSource `
        -ProtectedRoot $paths.ProtectedRoot
    Write-Host "automatic_egress=$(([bool]$settings.egress.enabled).ToString().ToLowerInvariant())"

    $existingTask = Get-AIChatConnectorTask
    if ($null -ne $existingTask) {
        Assert-AIChatTaskContract -Task $existingTask -Paths $paths
    }

    $transactionId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") +
        "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
    $backupDirectory = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $paths.BackupsDirectory $transactionId) `
        -ProtectedRoot $paths.ProtectedRoot
    $fileEntries = [Collections.Generic.List[object]]::new()
    $targets = Get-AIChatDeploymentTargets -Paths $paths
    foreach ($id in @($targets.Keys)) {
        $target = [string]$targets[$id]
        $exists = Test-Path -LiteralPath $target -PathType Leaf
        $entry = [ordered]@{ id = [string]$id; existed = $exists }
        if ($exists) {
            [void](Assert-AIChatPrivateFile -Path $target -ProtectedRoot $paths.ProtectedRoot)
            $backup = Join-Path $backupDirectory "$id.bak"
            Copy-AIChatPrivateFileAtomic `
                -Source $target `
                -Destination $backup `
                -ProtectedRoot $paths.ProtectedRoot
            $entry.sha256 = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $fileEntries.Add([pscustomobject]$entry)
    }
    $taskSnapshot = if ($null -eq $existingTask) {
        [pscustomobject]@{ existed = $false }
    } else {
        $taskXml = [string]$existingTask.Xml
        [pscustomobject]@{
            existed = $true
            enabled = [bool]$existingTask.Enabled
            xml = $taskXml
            xml_sha256 = Get-AIChatSha256Text -Value $taskXml
        }
    }
    $transaction = [pscustomobject][ordered]@{
        schema_version = 1
        kind = "aichat-windows-connector-transaction"
        transaction_id = $transactionId
        created_at = (Get-Date).ToUniversalTime().ToString("o")
        status = "prepared"
        files = @($fileEntries)
        task = $taskSnapshot
        new_release_id = $transactionId
    }
    Write-AIChatPrivateJson `
        -Path $paths.TransactionPath `
        -Value $transaction `
        -ProtectedRoot $paths.ProtectedRoot
    Invoke-AIChatInstallFailurePoint -Name "after-journal"

    $stage = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $paths.StagingDirectory $transactionId) `
        -ProtectedRoot $paths.ProtectedRoot
    $stageRuntime = Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $stage "runtime") `
        -ProtectedRoot $paths.ProtectedRoot
    foreach ($file in @("package.json", "package-lock.json")) {
        Copy-AIChatPrivateFileAtomic `
            -Source (Join-Path $connectorSource $file) `
            -Destination (Join-Path $stageRuntime $file) `
            -ProtectedRoot $paths.ProtectedRoot
    }
    $sourceDirectory = Join-Path $connectorSource "src"
    [void](Initialize-AIChatPrivateDirectory `
        -Path (Join-Path $stageRuntime "src") `
        -ProtectedRoot $paths.ProtectedRoot)
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse)) {
        [void](Assert-AIChatNoReparsePath `
            -Path $sourceFile.FullName `
            -StopAt ([IO.Path]::GetPathRoot($sourceFile.FullName)))
        if ((Get-AIChatHardLinkCount -Path $sourceFile.FullName) -ne 1) {
            throw "Connector source contains a hardlink alias"
        }
        $relative = $sourceFile.FullName.Substring($sourceDirectory.Length).TrimStart('\', '/')
        $destination = Join-Path (Join-Path $stageRuntime "src") $relative
        $destinationParent = Split-Path -Parent $destination
        [void](Initialize-AIChatPrivateDirectory `
            -Path $destinationParent `
            -ProtectedRoot $paths.ProtectedRoot)
        Copy-AIChatPrivateFileAtomic `
            -Source $sourceFile.FullName `
            -Destination $destination `
            -ProtectedRoot $paths.ProtectedRoot
    }

    Push-Location $stageRuntime
    try {
        & $settings.node_binary $settings.npm_cli_path ci --omit=dev --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "npm ci failed for the Windows connector runtime" }
    } finally {
        Pop-Location
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $stage -Recurse -Force | Sort-Object FullName)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Installed connector runtime contains a reparse point"
        }
        if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Installed connector runtime contains a hardlink alias"
        }
        Set-AIChatCurrentSidOnlyAcl -Path $item.FullName
    }
    Invoke-AIChatInstallFailurePoint -Name "after-stage"

    Set-AIChatTransactionStatus -Status "applying"
    $release = Join-Path $paths.ReleasesDirectory $transactionId
    if (Test-Path -LiteralPath $release) { throw "Connector release ID already exists" }
    Move-Item -LiteralPath $stage -Destination $release
    $stage = $null
    Invoke-AIChatInstallFailurePoint -Name "after-release"

    Copy-AIChatPrivateFileAtomic `
        -Source (Join-Path $PSScriptRoot "common.ps1") `
        -Destination $paths.CommonPath `
        -ProtectedRoot $paths.ProtectedRoot
    Copy-AIChatPrivateFileAtomic `
        -Source (Join-Path $PSScriptRoot "launcher.ps1") `
        -Destination $paths.LauncherPath `
        -ProtectedRoot $paths.ProtectedRoot
    Write-AIChatPrivateJson `
        -Path $paths.SettingsPath `
        -Value $settings `
        -ProtectedRoot $paths.ProtectedRoot

    $runtimeTree = Get-AIChatTreeHash `
        -Root (Join-Path $release "runtime") `
        -RequireCurrentSidOnlyAcl
    $active = [pscustomobject][ordered]@{
        schema_version = 1
        kind = "aichat-windows-connector-active-release"
        release_id = $transactionId
        connector_sha256 = (Get-FileHash `
            -LiteralPath (Join-Path $release "runtime\src\cli.js") `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        package_sha256 = (Get-FileHash `
            -LiteralPath (Join-Path $release "runtime\package.json") `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        package_lock_sha256 = (Get-FileHash `
            -LiteralPath (Join-Path $release "runtime\package-lock.json") `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        runtime_file_count = $runtimeTree.FileCount
        runtime_tree_sha256 = $runtimeTree.Sha256
    }
    Write-AIChatPrivateJson `
        -Path $paths.ActiveReleasePath `
        -Value $active `
        -ProtectedRoot $paths.ProtectedRoot
    Invoke-AIChatInstallFailurePoint -Name "after-files"

    Register-AIChatDisabledTask -Paths $paths
    Invoke-AIChatInstallFailurePoint -Name "after-task"
    Set-AIChatTransactionStatus -Status "applied"

    Set-AIChatTransactionStatus -Status "committed"
    $manifestPath = Join-Path $backupDirectory "manifest.json"
    Write-AIChatPrivateJson `
        -Path $manifestPath `
        -Value $transaction `
        -ProtectedRoot $paths.ProtectedRoot
    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-AIChatPrivateJson `
        -Path $paths.LastBackupPath `
        -Value ([pscustomobject]@{
            schema_version = 1
            kind = "aichat-windows-connector-last-backup"
            transaction_id = $transactionId
            manifest_sha256 = $manifestHash
        }) `
        -ProtectedRoot $paths.ProtectedRoot
    Remove-Item -LiteralPath $paths.TransactionPath -Force

    Write-Host "installed_release=$transactionId"
    Write-Host "service_enabled=false"
    Write-Host "task_triggers=0"
    Write-Host "token_read=false"
    Write-Host "restart_or_start_performed=false"
} catch {
    $original = $_.Exception.Message
    $rollbackError = $null
    if ($null -ne $transaction -and $null -ne $backupDirectory -and
        [string]$transaction.status -ne "committed") {
        try {
            Invoke-AIChatManifestRollback `
                -Manifest $transaction `
                -Paths $paths `
                -BackupDirectory $backupDirectory
            if (Test-Path -LiteralPath $paths.TransactionPath) {
                Remove-Item -LiteralPath $paths.TransactionPath -Force
            }
        } catch {
            $rollbackError = $_.Exception.Message
            try {
                $transaction.status = "rollback_incomplete"
                Write-AIChatPrivateJson `
                    -Path $paths.TransactionPath `
                    -Value $transaction `
                    -ProtectedRoot $paths.ProtectedRoot
            } catch {}
        }
    }
    if ($null -ne $stage -and (Test-Path -LiteralPath $stage)) {
        try { Remove-AIChatSafeTree -Path $stage } catch {}
    }
    if ($null -ne $transaction -and [string]$transaction.status -eq "committed") {
        throw "Windows connector deployment committed, but backup finalization is incomplete; rerun install to finalize the protected committed journal. Error: $original"
    }
    if ($rollbackError) {
        throw "Windows connector install failed and rollback is incomplete; inspect the protected transaction journal. Install error: $original; rollback error: $rollbackError"
    }
    throw "Windows connector install failed and prior state was restored: $original"
}

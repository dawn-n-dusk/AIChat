[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param([switch]$Apply)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stateRoot = [IO.Path]::GetFullPath(
    (Join-Path $env:LOCALAPPDATA "AIChat\codex-connector-task")
)
Write-Host "state_root=$stateRoot"
Write-Host "task=\AIChat\CodexConnector"
Write-Host "identity_config_preserved=true"
Write-Host "token_read=false"
if (-not $Apply -or $WhatIfPreference) {
    Write-Host "dry_run=true"
    Write-Host "mutation_performed=false"
    exit 0
}

. (Join-Path $PSScriptRoot "common.ps1")
$paths = Get-AIChatConnectorPaths
$statePresent = Test-Path -LiteralPath $paths.StateRoot -PathType Container
$dataPresent = Test-Path -LiteralPath $paths.ConnectorDataRoot -PathType Container
if ($statePresent) {
    [void](Assert-AIChatPrivateDirectoryTree `
        -Path $paths.StateRoot `
        -ProtectedRoot $paths.ProtectedRoot)
}
if ($dataPresent) {
    [void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)
}
if ($statePresent -and (Test-Path -LiteralPath $paths.TransactionPath)) {
    throw "Refusing uninstall while an unfinished install transaction exists"
}

$task = Get-AIChatConnectorTask
if ($null -eq $task -and -not $statePresent -and -not $dataPresent) {
    Write-Host "already_uninstalled=true"
    exit 0
}
if ($null -ne $task) {
    Assert-AIChatTaskContract -Task $task -Paths $paths
}
$taskSnapshot = if ($null -eq $task) {
    [pscustomobject]@{ existed = $false }
} else {
    $taskXml = [string]$task.Xml
    [pscustomobject]@{
        existed = $true
        enabled = [bool]$task.Enabled
        xml = $taskXml
        xml_sha256 = Get-AIChatSha256Text -Value $taskXml
    }
}

foreach ($root in @($paths.StateRoot, $paths.ConnectorDataRoot) | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) {
    foreach ($item in @(Get-ChildItem -LiteralPath $root -Recurse -Force)) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Refusing uninstall because a managed tree contains a reparse point"
        }
        if (-not $item.PSIsContainer -and (Get-AIChatHardLinkCount -Path $item.FullName) -ne 1) {
            throw "Refusing uninstall because a managed tree contains a hardlink alias"
        }
    }
}

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ") +
    "-" + [Guid]::NewGuid().ToString("N").Substring(0, 8)
$removedStateRoot = Initialize-AIChatPrivateDirectory `
    -Path (Join-Path $paths.ProtectedRoot "removed\$stamp") `
    -ProtectedRoot $paths.ProtectedRoot
$profile = Get-AIChatUserProfile
$aichatProfileRoot = Join-Path $profile ".aichat"
$removedDataRoot = Initialize-AIChatPrivateDirectory `
    -Path (Join-Path $aichatProfileRoot "removed\$stamp") `
    -ProtectedRoot $aichatProfileRoot `
    -AnchorRoot $profile
$removedState = Join-Path $removedStateRoot "codex-connector-task"
$removedData = Join-Path $removedDataRoot "codex-connector"
$stateMoved = $false
$dataMoved = $false
$taskDeleted = $false
try {
    $deleteTarget = Assert-AIChatTaskSnapshotForMutation `
        -Snapshot $taskSnapshot `
        -Paths $paths
    if ($null -ne $deleteTarget) {
        $service = New-Object -ComObject "Schedule.Service"
        $service.Connect()
        $folder = $service.GetFolder("\AIChat")
        $folder.DeleteTask("CodexConnector", 0)
        $taskDeleted = $true
        if ($null -ne (Get-AIChatConnectorTask)) {
            throw "Connector Scheduled Task still exists after deletion"
        }
    }

    if ($statePresent) {
        Move-Item -LiteralPath $paths.StateRoot -Destination $removedState
        $stateMoved = $true
    }
    if ($dataPresent) {
        Move-Item -LiteralPath $paths.ConnectorDataRoot -Destination $removedData
        $dataMoved = $true
    }
} catch {
    $original = $_.Exception.Message
    if (-not $taskDeleted -and -not $stateMoved -and -not $dataMoved) {
        throw "Windows connector uninstall precondition failed before managed state changed: $original"
    }
    try {
        if ($dataMoved -and -not (Test-Path -LiteralPath $paths.ConnectorDataRoot)) {
            Move-Item -LiteralPath $removedData -Destination $paths.ConnectorDataRoot
        }
        if ($stateMoved -and -not (Test-Path -LiteralPath $paths.StateRoot)) {
            Move-Item -LiteralPath $removedState -Destination $paths.StateRoot
        }
        if ([bool]$taskSnapshot.existed -and ($taskDeleted -or $stateMoved -or $dataMoved)) {
            Restore-AIChatTaskSnapshot -Snapshot $taskSnapshot -Paths $paths
        }
    } catch {
        throw "Windows connector uninstall failed and recovery is incomplete: $original"
    }
    throw "Windows connector uninstall failed and prior state was restored: $original"
}

Write-Host "uninstalled=true"
Write-Host "recoverable_package_removal=$removedStateRoot"
Write-Host "recoverable_connector_data_removal=$removedDataRoot"
Write-Host "identity_config_preserved=true"
Write-Host "task_started=false"
Write-Host "process_tree_orphan_check=not_applicable_task_was_not_running"

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This functional test requires Windows PowerShell 5.1"
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$runner = Join-Path $repositoryRoot "deploy\windows\run-adapter.ps1"
$testId = [Guid]::NewGuid().ToString("N")
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "aichat-legacy-runner-$testId"
$mockBin = Join-Path $testRoot "bin"
$configPath = Join-Path $testRoot "config.json"
$settingsPath = Join-Path $testRoot "settings.json"
$nodeCanary = Join-Path $testRoot "node-executed.canary"
$syntheticToken = "synthetic-legacy-runner-token-$testId"
$oldPath = $env:PATH
$lock = $null

try {
    New-Item -ItemType Directory -Path $mockBin -Force | Out-Null
    [IO.File]::WriteAllText(
        $configPath,
        (@{
            server = "https://relay.invalid/aichat"
            token = $syntheticToken
            channel_id = "synthetic-channel-$testId"
        } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
    [IO.File]::WriteAllText(
        $settingsPath,
        (@{ allowed_sender_ids = "synthetic-sender-$testId" } | ConvertTo-Json),
        [Text.UTF8Encoding]::new($false)
    )
    $nodeMock = "@echo off`r`necho executed>`"$nodeCanary`"`r`nexit /b 71`r`n"
    [IO.File]::WriteAllText(
        (Join-Path $mockBin "node.cmd"),
        $nodeMock,
        [Text.Encoding]::ASCII
    )

    $lock = [IO.FileStream]::new(
        $configPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $env:PATH = "$mockBin;$oldPath"
    $ErrorActionPreference = "Continue"
    $output = & powershell.exe `
        -NoProfile `
        -ExecutionPolicy Bypass `
        -File $runner `
        -Mode CodexConnector `
        -ConfigPath $configPath `
        -SettingsPath $settingsPath 2>&1 | Out-String
    $runnerExitCode = $LASTEXITCODE
    $ErrorActionPreference = "Stop"
    if ($runnerExitCode -eq 0 -or
        $output -notmatch [regex]::Escape(
            "Legacy CodexConnector runner is disabled; use deploy/windows/connector-service"
        )) {
        throw "Legacy CodexConnector runner did not fail with the migration boundary"
    }
    if ($output.Contains($syntheticToken) -or (Test-Path -LiteralPath $nodeCanary)) {
        throw "Legacy CodexConnector runner read or exposed config, or started Node"
    }
    Write-Host "Legacy Windows CodexConnector runner fail-closed test passed"
} finally {
    $ErrorActionPreference = "Stop"
    $env:PATH = $oldPath
    if ($null -ne $lock) { $lock.Dispose() }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

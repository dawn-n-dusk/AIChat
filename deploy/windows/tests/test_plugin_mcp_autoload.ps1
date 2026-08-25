[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This functional test requires Windows PowerShell"
}
if ($PSVersionTable.PSEdition -ne "Desktop" -or $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This functional test must run under Windows PowerShell 5.1"
}

$repositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
$installer = Join-Path $repositoryRoot "deploy\windows\install.ps1"
$testId = [Guid]::NewGuid().ToString("N")
$protectedRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA "AIChat"))
$protectedRootExisted = Test-Path -LiteralPath $protectedRoot
$testRoot = [IO.Path]::GetFullPath((Join-Path $protectedRoot "ci-plugin-mcp-$testId"))
if (-not $testRoot.StartsWith($protectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Resolved test path escaped the expected LocalAppData root"
}

$mockBin = Join-Path $testRoot "bin"
$commandLog = Join-Path $testRoot "codex-commands.log"
$ownedState = Join-Path $testRoot "owned"
$userState = Join-Path $testRoot "user"
$oldPath = $env:PATH
$oldLog = $env:AICHAT_CODEX_MOCK_LOG
$utf8NoBom = [Text.UTF8Encoding]::new($false)

New-Item -ItemType Directory -Path $mockBin -Force | Out-Null
$codexMock = @'
@echo off
echo %*>>"%AICHAT_CODEX_MOCK_LOG%"
if "%1 %2 %3"=="plugin marketplace list" (
  echo {"marketplaces":[{"name":"aichat-repo"}]}
  exit /b 0
)
if "%1 %2 %3"=="plugin marketplace upgrade" (
  echo {}
  exit /b 0
)
if "%1 %2"=="plugin list" (
  echo {"installed":[{"name":"aichat","enabled":true}]}
  exit /b 0
)
if "%1 %2"=="plugin add" (
  echo {}
  exit /b 0
)
echo Unexpected mock codex command 1>&2
exit /b 9
'@
$uvxMock = @'
@echo off
echo uvx 0.12.5
exit /b 0
'@
[IO.File]::WriteAllText((Join-Path $mockBin "codex.cmd"), $codexMock, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $mockBin "uvx.cmd"), $uvxMock, $utf8NoBom)

try {
    $env:PATH = "$mockBin;$oldPath"
    $env:AICHAT_CODEX_MOCK_LOG = $commandLog

    New-Item -ItemType Directory -Path $ownedState -Force | Out-Null
    $owned = [ordered]@{
        CodexMarketplaceAdded = $true
        CodexPluginAdded = $true
        CodexMcpAdded = $false
        ClaudeCodeMcpAdded = $false
        ClaudeChannelMcpAdded = $false
        ClaudeDesktopManaged = $false
    }
    [IO.File]::WriteAllText(
        (Join-Path $ownedState "ownership.json"),
        (($owned | ConvertTo-Json -Depth 4) + [Environment]::NewLine),
        $utf8NoBom
    )

    $ownedOutput = & $installer `
        -RepositoryRoot $repositoryRoot `
        -StateRoot $ownedState `
        -Components CodexPlugin 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Installer-owned refresh scenario failed; output suppressed"
    }
    $ownedCommands = @(Get-Content -LiteralPath $commandLog)
    if (-not ($ownedCommands -contains "plugin marketplace upgrade aichat-repo --json")) {
        throw "Installer did not refresh its owned marketplace snapshot"
    }
    if (-not ($ownedCommands -contains "plugin add aichat@aichat-repo --json")) {
        throw "Installer did not refresh its owned plugin cache"
    }

    [IO.File]::WriteAllText($commandLog, "", $utf8NoBom)
    $userOutput = & $installer `
        -RepositoryRoot $repositoryRoot `
        -StateRoot $userState `
        -Components CodexPlugin 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "User-managed preservation scenario failed; output suppressed"
    }
    $userCommands = @(Get-Content -LiteralPath $commandLog)
    if ($userCommands -contains "plugin marketplace upgrade aichat-repo --json" -or
        $userCommands -contains "plugin add aichat@aichat-repo --json") {
        throw "Installer modified user-managed plugin state"
    }
    Write-Host "Windows Codex plugin MCP refresh regression test passed"
} finally {
    $ownedOutput = $null
    $userOutput = $null
    $env:PATH = $oldPath
    $env:AICHAT_CODEX_MOCK_LOG = $oldLog
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedCleanup = [IO.Path]::GetFullPath($testRoot)
        if (-not $resolvedCleanup.StartsWith($protectedRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean up a path outside the expected LocalAppData root"
        }
        Remove-Item -LiteralPath $resolvedCleanup -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $protectedRootExisted -and (Test-Path -LiteralPath $protectedRoot -PathType Container)) {
        $remaining = @(Get-ChildItem -LiteralPath $protectedRoot -Force)
        if ($remaining.Count -ne 0) {
            throw "Refusing to remove the test-created AIChat root because it is no longer empty"
        }
        Remove-Item -LiteralPath $protectedRoot -Force
    }
}

$legacyRunnerTest = Join-Path $PSScriptRoot "test_legacy_codex_runner_disabled.ps1"
& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $legacyRunnerTest
if ($LASTEXITCODE -ne 0) {
    throw "Legacy Windows CodexConnector runner boundary test failed"
}

$connectorServiceTest = Join-Path $PSScriptRoot "test_connector_service.ps1"
& powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File $connectorServiceTest
if ($LASTEXITCODE -ne 0) {
    throw "Windows connector service functional test failed"
}

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BootstrapPath,
    [string]$StateRoot,
    [string]$ConfigPath,
    [switch]$KeepBootstrap
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "common.ps1")

if ($env:OS -ne "Windows_NT") {
    throw "AIChat bootstrap import must run as the target user on Windows"
}

$protectedRoot = Get-AIChatProtectedRoot
$protectedRootItem = Get-Item -LiteralPath $protectedRoot -Force -ErrorAction SilentlyContinue
if ($null -eq $protectedRootItem) {
    New-Item -ItemType Directory -Path $protectedRoot | Out-Null
    $protectedRootItem = Get-Item -LiteralPath $protectedRoot -Force
}
if (-not $protectedRootItem.PSIsContainer -or
    ($protectedRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "The protected AIChat LocalAppData root must be a regular directory"
}
Protect-SecretFile -Path $protectedRoot

$bootstrapRoot = Join-Path $protectedRoot "bootstrap"
$bootstrapRootItem = Get-Item -LiteralPath $bootstrapRoot -Force -ErrorAction SilentlyContinue
if ($null -eq $bootstrapRootItem) {
    New-Item -ItemType Directory -Path $bootstrapRoot | Out-Null
    $bootstrapRootItem = Get-Item -LiteralPath $bootstrapRoot -Force
}
if (-not $bootstrapRootItem.PSIsContainer -or
    ($bootstrapRootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "The AIChat bootstrap staging path must be a regular directory"
}
Protect-SecretFile -Path $bootstrapRoot
[void](Assert-AIChatPathWithinProtectedRoot -Path $bootstrapRoot -ProtectedRoot $protectedRoot)

function Get-BootstrapString {
    param(
        [Parameter(Mandatory = $true)][psobject]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $property.Value -isnot [string] -or -not $property.Value.Trim()) {
        throw "Bootstrap artifact is missing a valid $Name field"
    }
    return $property.Value.Trim()
}

$artifactPath = Assert-AIChatPathWithinProtectedRoot `
    -Path $BootstrapPath `
    -ProtectedRoot $bootstrapRoot
$artifactItem = Get-Item -LiteralPath $artifactPath -Force
if ($artifactItem.PSIsContainer -or ($artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "BootstrapPath must be a regular file, not a directory or reparse point"
}

# Restrict the trusted staging directory and transported artifact before parsing
# it. A same-SID process or administrator remains outside this local boundary.
Protect-SecretFile -Path $artifactPath

$artifactStream = $null
$artifactReader = $null
try {
    $artifactStream = [IO.FileStream]::new(
        $artifactPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::None
    )
    $artifactReader = [IO.StreamReader]::new(
        $artifactStream,
        [Text.UTF8Encoding]::new($false, $true),
        $true
    )
    $raw = $artifactReader.ReadToEnd()
    $bootstrap = $raw | ConvertFrom-Json
} catch {
    throw "Bootstrap JSON could not be parsed; diagnostic details were suppressed"
} finally {
    if ($null -ne $artifactReader) { $artifactReader.Dispose() }
    if ($null -ne $artifactStream) { $artifactStream.Dispose() }
}
if ($null -eq $bootstrap -or
    $bootstrap -is [Array] -or
    $bootstrap -isnot [System.Management.Automation.PSCustomObject]) {
    throw "Bootstrap JSON must contain one object"
}
$schema = $bootstrap.PSObject.Properties["schema_version"]
if ($null -eq $schema -or $schema.Value -ne 1) {
    throw "Unsupported bootstrap schema_version"
}
$kind = Get-BootstrapString -Object $bootstrap -Name "kind"
if ($kind -ne "aichat-agent-bootstrap") {
    throw "Unsupported bootstrap artifact kind"
}
$server = Get-BootstrapString -Object $bootstrap -Name "server"
$agentId = Get-BootstrapString -Object $bootstrap -Name "agent_id"
$agentName = Get-BootstrapString -Object $bootstrap -Name "agent_name"
$token = Get-BootstrapString -Object $bootstrap -Name "token"

[Uri]$serverUri = $null
if (-not [Uri]::TryCreate($server, [UriKind]::Absolute, [ref]$serverUri) -or
    $serverUri.Scheme -notin @("http", "https") -or
    -not $serverUri.Host -or
    $serverUri.UserInfo -or
    $serverUri.Query -or
    $serverUri.Fragment) {
    throw "Bootstrap server must be an absolute HTTP(S) base URL without credentials, query, or fragment"
}
if ($agentId.Length -gt 200 -or $agentName.Length -gt 120) {
    throw "Bootstrap identity fields exceed supported lengths"
}
if ($token.Length -lt 43 -or $token.Length -gt 512 -or $token -notmatch '^[A-Za-z0-9_-]+$') {
    throw "Bootstrap token has an invalid format"
}

$paths = Get-AIChatWindowsPaths -StateRoot $StateRoot -ConfigPath $ConfigPath
$paths.ConfigPath = Assert-AIChatPathWithinProtectedRoot `
    -Path $paths.ConfigPath `
    -ProtectedRoot $protectedRoot `
    -LeafMayBeMissing
$configParent = Split-Path -Parent $paths.ConfigPath
$configParentItem = Get-Item -LiteralPath $configParent -Force -ErrorAction SilentlyContinue
if ($null -eq $configParentItem) {
    New-Item -ItemType Directory -Path $configParent | Out-Null
    $configParentItem = Get-Item -LiteralPath $configParent -Force
}
if (-not $configParentItem.PSIsContainer -or
    ($configParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "AIChat config parent must be a regular directory"
}
Protect-SecretFile -Path $configParent
[void](Assert-AIChatPathWithinProtectedRoot -Path $configParent -ProtectedRoot $protectedRoot)
try {
    $config = Read-JsonObject -Path $paths.ConfigPath
} catch {
    throw "Existing AIChat config could not be parsed; diagnostic details were suppressed"
}
Set-ObjectProperty -Object $config -Name "server" -Value $server.TrimEnd("/")
Set-ObjectProperty -Object $config -Name "agent_id" -Value $agentId
Set-ObjectProperty -Object $config -Name "agent_name" -Value $agentName
Set-ObjectProperty -Object $config -Name "token" -Value $token

Write-SecretJsonAtomic -Path $paths.ConfigPath -Value $config -ProtectedRoot $protectedRoot

$raw = $null
$bootstrap = $null
$token = $null
$config = $null
$deleted = $false
if (-not $KeepBootstrap) {
    try {
        Remove-Item -LiteralPath $artifactPath -Force
        $deleted = -not (Test-Path -LiteralPath $artifactPath)
    } catch {
        Write-Error "bootstrap_imported=true token_present=true bootstrap_deleted=false; remove the restricted artifact manually"
        exit 2
    }
    if (-not $deleted) {
        Write-Error "bootstrap_imported=true token_present=true bootstrap_deleted=false; remove the restricted artifact manually"
        exit 2
    }
}

Write-Host "bootstrap_imported=true"
Write-Host "agent_id=$agentId"
Write-Host "config_path=$($paths.ConfigPath)"
Write-Host "token_present=true"
Write-Host "bootstrap_deleted=$($deleted.ToString().ToLowerInvariant())"

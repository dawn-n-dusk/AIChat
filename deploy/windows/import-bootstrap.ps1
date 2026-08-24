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

$artifactItem = Get-Item -LiteralPath $BootstrapPath -Force
if ($artifactItem.PSIsContainer -or ($artifactItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "BootstrapPath must be a regular file, not a directory or reparse point"
}
$artifactPath = $artifactItem.FullName

# Restrict the transported artifact before parsing it. This replaces the DACL
# with one FullControl rule for the current Windows SID.
Protect-SecretFile -Path $artifactPath

try {
    $raw = Get-Content -LiteralPath $artifactPath -Raw -Encoding UTF8
    $bootstrap = $raw | ConvertFrom-Json
} catch {
    throw "Bootstrap JSON could not be parsed; diagnostic details were suppressed"
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
try {
    $config = Read-JsonObject -Path $paths.ConfigPath
} catch {
    throw "Existing AIChat config could not be parsed; diagnostic details were suppressed"
}
Set-ObjectProperty -Object $config -Name "server" -Value $server.TrimEnd("/")
Set-ObjectProperty -Object $config -Name "agent_id" -Value $agentId
Set-ObjectProperty -Object $config -Name "agent_name" -Value $agentName
Set-ObjectProperty -Object $config -Name "token" -Value $token

Write-SecretJsonAtomic -Path $paths.ConfigPath -Value $config

$raw = $null
$bootstrap = $null
$token = $null
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

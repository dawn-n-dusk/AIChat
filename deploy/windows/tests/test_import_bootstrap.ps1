[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This functional test requires Windows PowerShell"
}

$windowsRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$importer = Join-Path $windowsRoot "import-bootstrap.ps1"
$testId = [Guid]::NewGuid().ToString("N")
$protectedRoot = Join-Path $env:LOCALAPPDATA "AIChat"
$bootstrapDirectory = Join-Path $protectedRoot "bootstrap\ci-$testId"
$configDirectory = Join-Path $protectedRoot "ci-$testId"
$artifactPath = Join-Path $bootstrapDirectory "windows-agent.bootstrap.json"
$configPath = Join-Path $configDirectory "config.json"
$freshConfigDirectory = Join-Path $protectedRoot "ci-fresh-$testId"
$freshArtifactPath = Join-Path $bootstrapDirectory "windows-agent-fresh.bootstrap.json"
$freshConfigPath = Join-Path $freshConfigDirectory "config.json"

New-Item -ItemType Directory -Path $bootstrapDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null

$random = [Security.Cryptography.RandomNumberGenerator]::Create()
$tokenBytes = New-Object byte[] 48
$random.GetBytes($tokenBytes)
$random.Dispose()
$token = [Convert]::ToBase64String($tokenBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
$oldToken = "synthetic-old-token-$testId"
$agentId = "ci-agent-$testId"

$bootstrap = [ordered]@{
    schema_version = 1
    kind = "aichat-agent-bootstrap"
    server = "https://relay.example.test/aichat"
    agent_id = $agentId
    agent_name = "Windows CI Agent"
    token = $token
    created_at = "2026-08-24T00:00:00.000Z"
}
$existingConfig = [ordered]@{
    server = "https://old.example.test"
    token = $oldToken
    channel_id = "preserved-channel"
    custom_key = "preserved-value"
}
$utf8NoBom = [Text.UTF8Encoding]::new($false)
[IO.File]::WriteAllText(
    $artifactPath,
    (($bootstrap | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom
)
[IO.File]::WriteAllText(
    $configPath,
    (($existingConfig | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
    $utf8NoBom
)

try {
    $captured = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importer `
        -BootstrapPath $artifactPath `
        -ConfigPath $configPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Bootstrap importer failed; captured output was suppressed"
    }
    if ($captured.Contains($token) -or $captured.Contains($oldToken)) {
        throw "Bootstrap importer exposed a credential in process output"
    }
    if (Test-Path -LiteralPath $artifactPath) {
        throw "Bootstrap artifact was not deleted after a successful import"
    }

    $imported = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($imported.server -ne "https://relay.example.test/aichat" -or
        $imported.agent_id -ne $agentId -or
        $imported.agent_name -ne "Windows CI Agent" -or
        $imported.token -ne $token -or
        $imported.channel_id -ne "preserved-channel" -or
        $imported.custom_key -ne "preserved-value") {
        throw "Imported config did not preserve and replace the expected fields"
    }

    $bytes = [IO.File]::ReadAllBytes($configPath)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Imported config unexpectedly contains a UTF-8 BOM"
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $acl = Get-Acl -LiteralPath $configPath
    $rules = @($acl.Access)
    if ($rules.Count -ne 1) {
        throw "Imported config ACL contains unexpected access rules"
    }
    $ruleSid = $rules[0].IdentityReference.Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($ruleSid -ne $identity.User.Value -or
        $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
        $rules[0].IsInherited) {
        throw "Imported config ACL is not restricted to the current SID"
    }

    $freshTokenBytes = New-Object byte[] 48
    $freshRandom = [Security.Cryptography.RandomNumberGenerator]::Create()
    $freshRandom.GetBytes($freshTokenBytes)
    $freshRandom.Dispose()
    $freshToken = [Convert]::ToBase64String($freshTokenBytes).TrimEnd("=").Replace("+", "-").Replace("/", "_")
    $freshBootstrap = [ordered]@{
        schema_version = 1
        kind = "aichat-agent-bootstrap"
        server = "https://relay.example.test/aichat"
        agent_id = "ci-fresh-agent-$testId"
        agent_name = "Windows Fresh CI Agent"
        token = $freshToken
        created_at = "2026-08-24T00:00:00.000Z"
    }
    [IO.File]::WriteAllText(
        $freshArtifactPath,
        (($freshBootstrap | ConvertTo-Json -Depth 8) + [Environment]::NewLine),
        $utf8NoBom
    )
    if (Test-Path -LiteralPath $freshConfigDirectory) {
        throw "Fresh config parent unexpectedly exists before import"
    }
    $freshCaptured = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importer `
        -BootstrapPath $freshArtifactPath `
        -ConfigPath $freshConfigPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Fresh bootstrap importer failed; captured output was suppressed"
    }
    if ($freshCaptured.Contains($freshToken)) {
        throw "Fresh bootstrap importer exposed a credential in process output"
    }
    if (-not (Test-Path -LiteralPath $freshConfigPath -PathType Leaf)) {
        throw "Fresh bootstrap importer did not create the default-style config parent"
    }
    $freshImported = Get-Content -LiteralPath $freshConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($freshImported.agent_id -ne "ci-fresh-agent-$testId" -or
        $freshImported.token -ne $freshToken) {
        throw "Fresh bootstrap import did not write the expected identity"
    }

    Write-Host "Windows bootstrap functional test passed"
} finally {
    $captured = $null
    $imported = $null
    $token = $null
    $oldToken = $null
    $freshCaptured = $null
    $freshImported = $null
    $freshToken = $null
    Remove-Item -LiteralPath $configDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $freshConfigDirectory -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $bootstrapDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

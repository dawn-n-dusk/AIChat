Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-AIChatRepositoryRoot {
    param([string]$RequestedPath)

    $candidate = if ($RequestedPath) {
        $RequestedPath
    } else {
        Join-Path $PSScriptRoot "..\.."
    }
    $resolved = (Resolve-Path -LiteralPath $candidate).Path
    $required = @(
        "adapters\mcp\pyproject.toml",
        "adapters\codex-connector\package.json",
        "plugins\aichat\.codex-plugin\plugin.json"
    )
    foreach ($relative in $required) {
        if (-not (Test-Path -LiteralPath (Join-Path $resolved $relative) -PathType Leaf)) {
            throw "RepositoryRoot is not an AIChat checkout: missing $relative"
        }
    }
    return $resolved
}

function Get-AIChatWindowsPaths {
    param(
        [string]$StateRoot,
        [string]$ConfigPath
    )

    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localAppData) {
        $localAppData = $env:LOCALAPPDATA
    }
    if (-not $localAppData) {
        throw "Cannot resolve the current user's LocalApplicationData directory"
    }
    $roamingAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if (-not $roamingAppData) {
        $roamingAppData = $env:APPDATA
    }

    $resolvedState = if ($StateRoot) {
        [IO.Path]::GetFullPath($StateRoot)
    } else {
        Join-Path $localAppData "AIChat\deploy\windows"
    }
    # This exactly matches platformdirs.user_config_dir("AIChat", "AIChat") on Windows.
    $resolvedConfig = if ($ConfigPath) {
        [IO.Path]::GetFullPath($ConfigPath)
    } else {
        Join-Path $localAppData "AIChat\AIChat\config.json"
    }

    return [pscustomobject]@{
        StateRoot          = $resolvedState
        ConfigPath         = $resolvedConfig
        SettingsPath       = Join-Path $resolvedState "adapter-settings.json"
        OwnershipPath      = Join-Path $resolvedState "ownership.json"
        ManifestDirectory  = Join-Path $resolvedState "manifests"
        BackupDirectory    = Join-Path $resolvedState "backups"
        RuntimeDirectory   = Join-Path $resolvedState "runtime"
        RunnerPath         = Join-Path $resolvedState "run-adapter.ps1"
        ClaudeDesktopPath  = if ($roamingAppData) {
            Join-Path $roamingAppData "Claude\claude_desktop_config.json"
        } else {
            $null
        }
    }
}

function Get-AIChatProtectedRoot {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localAppData) {
        $localAppData = $env:LOCALAPPDATA
    }
    if (-not $localAppData) {
        throw "Cannot resolve the current user's LocalApplicationData directory"
    }
    return [IO.Path]::GetFullPath((Join-Path $localAppData "AIChat"))
}

function Assert-AIChatPathWithinProtectedRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [switch]$LeafMayBeMissing,
        [switch]$MissingTailMayBeCreated
    )

    $root = [IO.Path]::GetFullPath($ProtectedRoot).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $resolved = [IO.Path]::GetFullPath($Path)
    $prefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Secret path must remain below the protected AIChat LocalAppData root"
    }

    $rootItem = Get-Item -LiteralPath $root -Force -ErrorAction SilentlyContinue
    if ($null -eq $rootItem -or -not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Protected AIChat root must be an existing regular directory"
    }

    $relative = $resolved.Substring($root.Length).TrimStart(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar
    )
    $segments = @(if ($relative) { $relative -split '[\\/]' })
    $current = $root
    $missingTail = $false
    for ($index = 0; $index -lt $segments.Count; $index++) {
        $current = Join-Path $current $segments[$index]
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($MissingTailMayBeCreated) {
                $missingTail = $true
                continue
            }
            if ($LeafMayBeMissing -and $index -eq $segments.Count - 1) {
                continue
            }
            throw "Protected secret path component does not exist: $current"
        }
        if ($missingTail) {
            throw "Protected secret path contains an unexpected object below a missing parent"
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Protected secret paths must not contain reparse points"
        }
    }
    return $resolved
}

function Test-ExternalCommand {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )

    $output = & $FilePath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Output   = $output.Trim()
    }
}

function Read-JsonObject {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{}
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    if (-not $raw.Trim()) {
        return [pscustomobject]@{}
    }
    $value = $raw | ConvertFrom-Json
    if ($null -eq $value -or $value -isnot [psobject]) {
        throw "JSON file must contain an object: $Path"
    }
    return $value
}

function Set-ObjectProperty {
    param(
        [Parameter(Mandatory = $true)][psobject]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Value
    )

    if ($Object.PSObject.Properties[$Name]) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [int]$Depth = 12
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    $json = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Protect-SecretFile {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ($env:OS -ne "Windows_NT") {
        return
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $item = Get-Item -LiteralPath $Path -Force
    $security = if ($item.PSIsContainer) {
        [Security.AccessControl.DirectorySecurity]::new()
    } else {
        [Security.AccessControl.FileSecurity]::new()
    }
    $security.SetOwner($identity.User)
    $security.SetAccessRuleProtection($true, $false)
    $rule = if ($item.PSIsContainer) {
        $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
            [Security.AccessControl.InheritanceFlags]::ObjectInherit
        [Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            $inheritance,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow
        )
    } else {
        [Security.AccessControl.FileSystemAccessRule]::new(
            $identity.User,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow
        )
    }
    [void]$security.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $security

    $applied = Get-Acl -LiteralPath $Path
    $rules = @($applied.Access)
    if ($rules.Count -ne 1) {
        throw "Failed to restrict ACLs on $Path"
    }
    $ruleSid = $rules[0].IdentityReference.Translate(
        [Security.Principal.SecurityIdentifier]
    ).Value
    if ($ruleSid -ne $identity.User.Value -or
        $rules[0].AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
        $rules[0].FileSystemRights -ne [Security.AccessControl.FileSystemRights]::FullControl -or
        $rules[0].IsInherited) {
        throw "Failed to restrict ACLs on $Path"
    }
}

function Write-SecretJsonAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string]$ProtectedRoot,
        [int]$Depth = 12
    )

    $Path = Assert-AIChatPathWithinProtectedRoot -Path $Path -ProtectedRoot $ProtectedRoot -LeafMayBeMissing
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        throw "Protected config parent must exist before writing secret JSON"
    }
    Protect-SecretFile -Path $parent
    [void](Assert-AIChatPathWithinProtectedRoot -Path $parent -ProtectedRoot $ProtectedRoot)
    $existing = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -ne $existing -and
        ($existing.PSIsContainer -or ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        throw "Secret JSON destination must be a regular file: $Path"
    }
    if ($null -ne $existing) {
        Protect-SecretFile -Path $Path
    }
    $temporary = "$Path.tmp-$([Guid]::NewGuid().ToString('N'))"
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $stream.Dispose()
        $stream = $null
        Protect-SecretFile -Path $temporary

        $json = ($Value | ConvertTo-Json -Depth $Depth) + [Environment]::NewLine
        $stream = [IO.FileStream]::new(
            $temporary,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream = $null

        if ($null -ne $existing) {
            [void](Assert-AIChatPathWithinProtectedRoot -Path $Path -ProtectedRoot $ProtectedRoot)
            [IO.File]::Replace($temporary, $Path, $null)
        } else {
            [IO.File]::Move($temporary, $Path)
        }
        [void](Assert-AIChatPathWithinProtectedRoot -Path $Path -ProtectedRoot $ProtectedRoot)
        Protect-SecretFile -Path $Path
    } finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Backup-FileForRun {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RunBackupDirectory
    )

    New-Item -ItemType Directory -Path $RunBackupDirectory -Force | Out-Null
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $backupPath = $null
    if ($exists) {
        $safeName = ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Path))).TrimEnd("=").Replace("/", "_").Replace("+", "-")
        $backupPath = Join-Path $RunBackupDirectory "$safeName.json.bak"
        Copy-Item -LiteralPath $Path -Destination $backupPath -Force
    }
    return [pscustomobject]@{
        Path       = $Path
        Existed    = $exists
        BackupPath = $backupPath
    }
}

function Get-DefaultOwnership {
    return [pscustomobject]@{
        CodexMarketplaceAdded = $false
        CodexPluginAdded      = $false
        CodexMcpAdded         = $false
        ClaudeCodeMcpAdded    = $false
        ClaudeChannelMcpAdded = $false
        ClaudeDesktopManaged  = $false
    }
}

function Read-Ownership {
    param([Parameter(Mandatory = $true)][string]$Path)

    $defaults = Get-DefaultOwnership
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $defaults
    }
    $saved = Read-JsonObject -Path $Path
    foreach ($property in $defaults.PSObject.Properties) {
        if ($saved.PSObject.Properties[$property.Name]) {
            $defaults.($property.Name) = [bool]$saved.($property.Name)
        }
    }
    return $defaults
}

function Test-OutputContainsName {
    param(
        [string]$Output,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Output) {
        return $false
    }
    return $Output -match [regex]::Escape($Name)
}

function Assert-Node20 {
    if (-not (Test-ExternalCommand "node")) {
        throw "Node.js 20 or newer is required for the selected adapter"
    }
    $version = (& node --version).Trim()
    if ($version -notmatch '^v(?<major>\d+)\.') {
        throw "Cannot parse Node.js version: $version"
    }
    if ([int]$Matches.major -lt 20) {
        throw "Node.js 20 or newer is required; found $version"
    }
    if (-not (Test-ExternalCommand "npm")) {
        throw "npm is required for the selected adapter"
    }
}

function Resolve-Python311Command {
    if (Test-ExternalCommand "py") {
        $probe = Invoke-NativeCapture -FilePath "py" -Arguments @("-3.11", "-c", "import sys; raise SystemExit(sys.version_info < (3, 11))")
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ FilePath = "py"; Prefix = @("-3.11") }
        }
    }
    if (Test-ExternalCommand "python") {
        $probe = Invoke-NativeCapture -FilePath "python" -Arguments @("-c", "import sys; raise SystemExit(sys.version_info < (3, 11))")
        if ($probe.ExitCode -eq 0) {
            return [pscustomobject]@{ FilePath = "python"; Prefix = @() }
        }
    }
    throw "Python 3.11 or newer is required for the AIChat MCP adapter"
}

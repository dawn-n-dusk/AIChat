[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function ConvertTo-AIChatProtectedPathAsciiJson {
    param([Parameter(Mandatory = $true)]$Value)

    $raw = $Value | ConvertTo-Json -Compress -Depth 4
    $builder = [Text.StringBuilder]::new()
    foreach ($character in $raw.ToCharArray()) {
        $code = [int][char]$character
        if ($code -gt 0x7f) {
            [void]$builder.Append(("\u{0:x4}" -f $code))
        } else {
            [void]$builder.Append($character)
        }
    }
    return $builder.ToString()
}

function New-AIChatProtectedPathDiagnostic {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("exact", "mismatch", "indeterminate")]
        [string]$Result,
        [Parameter(Mandatory = $true)]
        [ValidateSet("resolution", "ancestor_chain", "directory_shape", "acl", "internal")]
        [string]$Phase,
        [Parameter(Mandatory = $true)]
        [ValidateSet("-1", "0", "1")]
        [int]$Level,
        [Parameter(Mandatory = $true)]
        [ValidateSet("ancestor_chain", "protected_root", "state_root")]
        [string]$Layer,
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "none",
            "resolution_failed",
            "ancestor_missing",
            "ancestor_reparse",
            "layer_missing",
            "layer_not_directory",
            "layer_reparse",
            "acl_unreadable",
            "owner_mismatch",
            "dacl_unprotected",
            "rule_count_mismatch",
            "rule_shape_mismatch",
            "internal_error"
        )]
        [string]$Reason
    )

    $expectedLayer = switch ($Level) {
        -1 { "ancestor_chain"; break }
        0 { "protected_root"; break }
        1 { "state_root"; break }
    }
    if ($Layer -cne $expectedLayer) {
        throw "Protected-path diagnostic layer does not match its fixed level"
    }
    if (($Result -ceq "exact") -ne ($Reason -ceq "none")) {
        throw "Protected-path diagnostic exactness does not match its fixed reason"
    }
    $blockedReasons = @("resolution_failed", "acl_unreadable", "internal_error")
    if (($Result -ceq "indeterminate") -ne ($blockedReasons -ccontains $Reason)) {
        throw "Protected-path diagnostic result does not match its fixed reason class"
    }
    $reasonShapeValid = switch ($Reason) {
        "none" {
            $Phase -ceq "acl" -and $Level -eq 1
            break
        }
        "resolution_failed" {
            $Phase -ceq "resolution" -and $Level -eq -1
            break
        }
        { @("ancestor_missing", "ancestor_reparse") -ccontains $_ } {
            $Phase -ceq "ancestor_chain" -and $Level -eq -1
            break
        }
        { @("layer_missing", "layer_not_directory", "layer_reparse") -ccontains $_ } {
            $Phase -ceq "directory_shape" -and $Level -in @(0, 1)
            break
        }
        { @(
            "acl_unreadable", "owner_mismatch", "dacl_unprotected",
            "rule_count_mismatch", "rule_shape_mismatch"
        ) -ccontains $_ } {
            $Phase -ceq "acl" -and $Level -in @(0, 1)
            break
        }
        "internal_error" {
            $Phase -ceq "internal"
            break
        }
        default { $false; break }
    }
    if (-not $reasonShapeValid) {
        throw "Protected-path diagnostic reason does not match its fixed phase"
    }

    $success = $Result -cne "indeterminate"
    $status = switch ($Result) {
        "exact" { "exact"; break }
        "mismatch" { "mismatch"; break }
        default { "blocked"; break }
    }
    return [pscustomobject][ordered]@{
        contract_version = 1
        operation = "diagnose_protected_paths"
        mode = "read_only"
        success = [bool]$success
        status = $status
        result = $Result
        phase = $Phase
        level = [int]$Level
        layer = $Layer
        reason = $Reason
        mutation_performed = $false
        token_read = $false
        journal_read = $false
        connector_data_accessed = $false
        task_scheduler_accessed = $false
        connector_process_accessed = $false
    }
}

function Complete-AIChatProtectedPathDiagnostic {
    param([Parameter(Mandatory = $true)]$Value)

    $json = ConvertTo-AIChatProtectedPathAsciiJson -Value $Value
    [Console]::Out.WriteLine($json)
    if ([string]$Value.result -ceq "indeterminate") {
        exit 1
    }
    exit 0
}

function New-AIChatProtectedPathMismatch {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$Layer,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    return New-AIChatProtectedPathDiagnostic `
        -Result "mismatch" `
        -Phase $Phase `
        -Level $Level `
        -Layer $Layer `
        -Reason $Reason
}

function New-AIChatProtectedPathBlocked {
    param(
        [Parameter(Mandatory = $true)][string]$Phase,
        [Parameter(Mandatory = $true)][int]$Level,
        [Parameter(Mandatory = $true)][string]$Layer,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    return New-AIChatProtectedPathDiagnostic `
        -Result "indeterminate" `
        -Phase $Phase `
        -Level $Level `
        -Layer $Layer `
        -Reason $Reason
}

function Get-AIChatProtectedPathDiagnosticItem {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
}

function Get-AIChatProtectedPathDiagnosticAcl {
    param([Parameter(Mandatory = $true)][string]$Path)
    return Get-Acl -LiteralPath $Path -ErrorAction Stop
}

function Get-AIChatProtectedPathDiagnosticOwnerSid {
    param([Parameter(Mandatory = $true)]$Acl)
    return $Acl.GetOwner(
        [Security.Principal.SecurityIdentifier]
    ).Value
}

function Test-AIChatProtectedPathLayer {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$CurrentSid,
        [Parameter(Mandatory = $true)][ValidateSet("0", "1")][int]$Level,
        [Parameter(Mandatory = $true)]
        [ValidateSet("protected_root", "state_root")]
        [string]$Layer
    )

    try {
        if (-not (Test-Path -LiteralPath $Path -PathType Any -ErrorAction Stop)) {
            return New-AIChatProtectedPathMismatch `
                -Phase "directory_shape" -Level $Level -Layer $Layer `
                -Reason "layer_missing"
        }
        $item = Get-AIChatProtectedPathDiagnosticItem -Path $Path
    } catch {
        return New-AIChatProtectedPathBlocked `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "acl_unreadable"
    }

    if (-not $item.PSIsContainer) {
        return New-AIChatProtectedPathMismatch `
            -Phase "directory_shape" -Level $Level -Layer $Layer `
            -Reason "layer_not_directory"
    }
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        return New-AIChatProtectedPathMismatch `
            -Phase "directory_shape" -Level $Level -Layer $Layer `
            -Reason "layer_reparse"
    }

    try {
        $acl = Get-AIChatProtectedPathDiagnosticAcl -Path $Path
        $ownerSid = Get-AIChatProtectedPathDiagnosticOwnerSid -Acl $acl
    } catch {
        return New-AIChatProtectedPathBlocked `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "acl_unreadable"
    }

    if ($ownerSid -cne $CurrentSid) {
        return New-AIChatProtectedPathMismatch `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "owner_mismatch"
    }
    if (-not $acl.AreAccessRulesProtected) {
        return New-AIChatProtectedPathMismatch `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "dacl_unprotected"
    }

    try {
        $rules = @($acl.GetAccessRules(
            $true,
            $true,
            [Security.Principal.SecurityIdentifier]
        ))
    } catch {
        return New-AIChatProtectedPathBlocked `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "acl_unreadable"
    }
    if ($rules.Count -ne 1) {
        return New-AIChatProtectedPathMismatch `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "rule_count_mismatch"
    }

    $rule = $rules[0]
    $expectedInheritance =
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
        [Security.AccessControl.InheritanceFlags]::ObjectInherit
    if ($rule.IdentityReference.Value -cne $CurrentSid -or
        $rule.AccessControlType -ne
            [Security.AccessControl.AccessControlType]::Allow -or
        $rule.FileSystemRights -ne
            [Security.AccessControl.FileSystemRights]::FullControl -or
        $rule.InheritanceFlags -ne $expectedInheritance -or
        $rule.PropagationFlags -ne
            [Security.AccessControl.PropagationFlags]::None -or
        $rule.IsInherited) {
        return New-AIChatProtectedPathMismatch `
            -Phase "acl" -Level $Level -Layer $Layer `
            -Reason "rule_shape_mismatch"
    }
    return $null
}

try {
    try {
        . (Join-Path $PSScriptRoot "common.ps1") *> $null
    } catch {
        Complete-AIChatProtectedPathDiagnostic (
            New-AIChatProtectedPathBlocked `
                -Phase "internal" -Level -1 -Layer "ancestor_chain" `
                -Reason "internal_error"
        )
    }

    try {
        $currentSid = Get-AIChatCurrentSid
        $connectorCanonical = Get-AIChatConnectorCanonicalStatePaths
        $treeCanonical = Get-AIChatPrivateDirectoryTreeCanonicalPaths `
            -Path ([string]$connectorCanonical.StateRoot) `
            -ProtectedRoot ([string]$connectorCanonical.ProtectedRoot)
        $protectedRoot = [string]$treeCanonical.ProtectedRoot
        $stateRoot = [string]$treeCanonical.Target
        $volumeRoot = [IO.Path]::GetPathRoot($protectedRoot)
        if (-not $volumeRoot -or
            $protectedRoot.StartsWith("\\") -or
            -not $stateRoot.StartsWith(
                $protectedRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw "Protected path resolution failed"
        }
    } catch {
        Complete-AIChatProtectedPathDiagnostic (
            New-AIChatProtectedPathBlocked `
                -Phase "resolution" -Level -1 -Layer "ancestor_chain" `
                -Reason "resolution_failed"
        )
    }

    try {
        $relativeProtected = $protectedRoot.Substring($volumeRoot.Length).TrimStart(
            [IO.Path]::DirectorySeparatorChar,
            [IO.Path]::AltDirectorySeparatorChar
        )
        $segments = @(if ($relativeProtected) {
            $relativeProtected -split '[\\/]'
        })
        $ancestors = @($volumeRoot)
        $current = $volumeRoot
        for ($index = 0; $index -lt ($segments.Count - 1); $index++) {
            $current = Join-Path $current $segments[$index]
            $ancestors += $current
        }
        foreach ($ancestor in $ancestors) {
            if (-not (Test-Path `
                -LiteralPath $ancestor -PathType Container -ErrorAction Stop)) {
                Complete-AIChatProtectedPathDiagnostic (
                    New-AIChatProtectedPathMismatch `
                        -Phase "ancestor_chain" -Level -1 `
                        -Layer "ancestor_chain" -Reason "ancestor_missing"
                )
            }
            $ancestorItem = Get-Item `
                -LiteralPath $ancestor -Force -ErrorAction Stop
            if ($ancestorItem.Attributes -band
                [IO.FileAttributes]::ReparsePoint) {
                Complete-AIChatProtectedPathDiagnostic (
                    New-AIChatProtectedPathMismatch `
                        -Phase "ancestor_chain" -Level -1 `
                        -Layer "ancestor_chain" -Reason "ancestor_reparse"
                )
            }
        }
    } catch {
        Complete-AIChatProtectedPathDiagnostic (
            New-AIChatProtectedPathBlocked `
                -Phase "internal" -Level -1 -Layer "ancestor_chain" `
                -Reason "internal_error"
        )
    }

    $protectedDiagnosis = Test-AIChatProtectedPathLayer `
        -Path $protectedRoot -CurrentSid $currentSid `
        -Level 0 -Layer "protected_root"
    if ($null -ne $protectedDiagnosis) {
        Complete-AIChatProtectedPathDiagnostic $protectedDiagnosis
    }

    $stateDiagnosis = Test-AIChatProtectedPathLayer `
        -Path $stateRoot -CurrentSid $currentSid `
        -Level 1 -Layer "state_root"
    if ($null -ne $stateDiagnosis) {
        Complete-AIChatProtectedPathDiagnostic $stateDiagnosis
    }

    Complete-AIChatProtectedPathDiagnostic (
        New-AIChatProtectedPathDiagnostic `
            -Result "exact" -Phase "acl" -Level 1 `
            -Layer "state_root" -Reason "none"
    )
} catch {
    [Console]::Out.WriteLine('{"contract_version":1,"operation":"diagnose_protected_paths","mode":"read_only","success":false,"status":"blocked","result":"indeterminate","phase":"internal","level":-1,"layer":"ancestor_chain","reason":"internal_error","mutation_performed":false,"token_read":false,"journal_read":false,"connector_data_accessed":false,"task_scheduler_accessed":false,"connector_process_accessed":false}')
    exit 1
}

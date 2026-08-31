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
$serviceRoot = Join-Path $repositoryRoot "deploy\windows\connector-service"
$installer = Join-Path $serviceRoot "install.ps1"
$checker = Join-Path $serviceRoot "check.ps1"
$rollback = Join-Path $serviceRoot "rollback.ps1"
$uninstaller = Join-Path $serviceRoot "uninstall.ps1"
. (Join-Path $serviceRoot "common.ps1")

$paths = Get-AIChatConnectorPaths
if (Test-Path -LiteralPath $paths.StateRoot) {
    throw "Refusing connector service CI because the fixed state root already exists"
}
if (Test-Path -LiteralPath $paths.ConnectorDataRoot) {
    throw "Refusing connector service CI because the fixed connector data root already exists"
}
if ($null -ne (Get-AIChatConnectorTask)) {
    throw "Refusing connector service CI because the fixed Scheduled Task already exists"
}

$testId = [Guid]::NewGuid().ToString("N")
$protectedRoot = $paths.ProtectedRoot
$settingsPath = Join-Path $protectedRoot "ci-connector-settings-$testId.json"
$deliverResultsSettingsPath = Join-Path $protectedRoot "ci-connector-deliver-results-$testId.json"
$unsafeSettingsPath = Join-Path $protectedRoot "ci-connector-unsafe-$testId.json"
$identityPath = Join-Path $protectedRoot "ci-connector-identity-$testId.json"
$egressSettingsPath = Join-Path $protectedRoot "ci-connector-egress-$testId.json"
$egressCanary = Join-Path $protectedRoot "ci-connector-egress-canary-$testId.txt"
$hashMismatchSettingsPath = Join-Path $protectedRoot "ci-connector-hash-mismatch-$testId.json"
$networkCanary = Join-Path $protectedRoot "ci-connector-network-$testId.canary"
$toolsRoot = Join-Path $protectedRoot "ci-connector-tools-$testId"
$codexPath = Join-Path $toolsRoot "codex.exe"
$codexCanary = Join-Path $toolsRoot "codex-executed.canary"
$pathCanary = Join-Path $toolsRoot "path-npm-executed.canary"
$mockBin = Join-Path $toolsRoot "mock-bin"
$hardlinkAlias = Join-Path $protectedRoot "ci-connector-hardlink-$testId.json"
$junctionTarget = Join-Path $protectedRoot "ci-connector-junction-target-$testId"
$junctionPath = Join-Path $protectedRoot "ci-connector-junction-$testId"
$aclProbe = Join-Path $protectedRoot "ci-connector-acl-$testId.json"
$inheritedDataProbe = Join-Path $paths.ConnectorDataRoot "ci-inherited-$testId.json"
$broadDataProbe = Join-Path $paths.ConnectorDataRoot "ci-broad-$testId.json"
$nodeDataProbe = Join-Path $paths.ConnectorDataRoot "ci-node-$testId.json"
$allOutput = [Text.StringBuilder]::new()
$codexHome = Join-Path (Get-AIChatUserProfile) ".codex"
$createdCodexHome = -not (Test-Path -LiteralPath $codexHome)

$taskMissing = [Runtime.InteropServices.COMException]::new(
    "synthetic missing task",
    -2147024894
)
$taskDenied = [Runtime.InteropServices.COMException]::new(
    "synthetic task access denied",
    -2147024891
)
if (-not (Test-AIChatTaskSchedulerNotFoundException -Exception $taskMissing) -or
    (Test-AIChatTaskSchedulerNotFoundException -Exception $taskDenied)) {
    throw "Task Scheduler COM not-found classification is not fail closed"
}

function Add-CapturedOutput {
    param($Value)
    if ($null -ne $Value) { [void]$allOutput.AppendLine([string]$Value) }
}

function Invoke-ExpectedFailure {
    param([scriptblock]$Action, [string]$Label)
    $failed = $false
    try {
        # Windows PowerShell 5.1 emits Write-Host on the information stream.
        # Merge every stream so assertions and the token-leak canary inspect it.
        $captured = & $Action *>&1 | Out-String
        Add-CapturedOutput $captured
    } catch {
        $failed = $true
        Add-CapturedOutput $_.Exception.Message
    }
    if (-not $failed) { throw "$Label unexpectedly succeeded" }
}

$checkpointSettings = [pscustomobject]@{
    egress = [pscustomobject]@{ enabled = $true }
}
$checkpointEventId = "app-server-event-$testId"
$checkpointMessageId = [Guid]::NewGuid().ToString("D")
$checkpointReceipt = [pscustomobject]@{
    outbound_event_id = $checkpointEventId
    outbound_message_id = $checkpointMessageId
}
$checkpointDriver = [pscustomobject]@{
    outboundEvent = [pscustomobject]@{
        modelDeclared = $true
        messageType = "result"
        eventId = $checkpointEventId
    }
}
if (-not (Assert-AIChatSupervisedResultEgressCheckpoint `
    -Settings $checkpointSettings `
    -ConnectorReceipt $checkpointReceipt `
    -DriverRecord $checkpointDriver)) {
    throw "Matching supervised result egress checkpoint was rejected"
}
$disabledCheckpointSettings = [pscustomobject]@{
    egress = [pscustomobject]@{ enabled = $false }
}
if (Assert-AIChatSupervisedResultEgressCheckpoint `
    -Settings $disabledCheckpointSettings `
    -ConnectorReceipt ([pscustomobject]@{}) `
    -DriverRecord ([pscustomobject]@{})) {
    throw "Disabled egress was reported as a Relay result checkpoint"
}

$mismatchedCheckpointReceipt = [pscustomobject]@{
    outbound_event_id = "different-event-$testId"
    outbound_message_id = $checkpointMessageId
}
Invoke-ExpectedFailure `
    -Label "mismatched supervised outbound event" `
    -Action {
        Assert-AIChatSupervisedResultEgressCheckpoint `
            -Settings $checkpointSettings `
            -ConnectorReceipt $mismatchedCheckpointReceipt `
            -DriverRecord $checkpointDriver
    }
$suppressedCheckpointReceipt = [pscustomobject]@{
    outbound_event_id = $checkpointEventId
    outbound_message_id = "local-suppressed-$testId"
}
Invoke-ExpectedFailure `
    -Label "locally suppressed supervised outbound" `
    -Action {
        Assert-AIChatSupervisedResultEgressCheckpoint `
            -Settings $checkpointSettings `
            -ConnectorReceipt $suppressedCheckpointReceipt `
            -DriverRecord $checkpointDriver
    }

try {
    $uncProbe = "\\127.0.0.1\aichat-no-io-$testId"
    $uncWhatIfOutput = & $installer `
        -SettingsPath "$uncProbe\settings.json" `
        -RepositoryRoot $uncProbe `
        -Apply -WhatIf *>&1 | Out-String
    Add-CapturedOutput $uncWhatIfOutput
    if ($LASTEXITCODE -ne 0 -or
        $uncWhatIfOutput -notmatch '(?m)^mutation_performed=false\s*$' -or
        $uncWhatIfOutput -notmatch '(?m)^security_runtime_checks=deferred_until_apply\s*$') {
        throw "Connector WhatIf touched or validated a network-backed input path"
    }

    [void](Initialize-AIChatPrivateDirectory `
        -Path $protectedRoot `
        -ProtectedRoot $protectedRoot)
    [void](Initialize-AIChatPrivateDirectory `
        -Path $toolsRoot `
        -ProtectedRoot $protectedRoot)
    [void](Initialize-AIChatPrivateDirectory `
        -Path $mockBin `
        -ProtectedRoot $protectedRoot)
    if ($createdCodexHome) {
        New-Item -ItemType Directory -Path $codexHome | Out-Null
        # Hosted runners may assign BUILTIN\Administrators as the default owner
        # for objects created by their elevated test account. Normalize only this
        # synthetic directory to the owner contract expected from Codex Desktop.
        $codexHomeAcl = Get-Acl -LiteralPath $codexHome
        $codexHomeAcl.SetOwner(
            [Security.Principal.WindowsIdentity]::GetCurrent().User
        )
        Set-Acl -LiteralPath $codexHome -AclObject $codexHomeAcl
    }

    $nodeCommand = Get-Command "node.exe" -CommandType Application -ErrorAction Stop |
        Select-Object -First 1
    $nodePath = [IO.Path]::GetFullPath($nodeCommand.Source)
    $npmCliPath = Join-Path (Split-Path -Parent $nodePath) "node_modules\npm\bin\npm-cli.js"
    if (-not (Test-Path -LiteralPath $npmCliPath -PathType Leaf)) {
        throw "Hosted Windows Node installation does not expose the expected npm-cli.js"
    }

    $codexSource = @'
using System;
using System.IO;
public static class Program {
    public static int Main(string[] args) {
        string canary = Environment.GetEnvironmentVariable("AICHAT_CI_CODEX_EXEC_CANARY");
        if (!String.IsNullOrEmpty(canary)) File.WriteAllText(canary, "executed");
        Console.WriteLine("codex-cli 0.0.0-ci");
        return 0;
    }
}
'@
    Add-Type -TypeDefinition $codexSource -OutputAssembly $codexPath -OutputType ConsoleApplication
    Set-AIChatCurrentSidOnlyAcl -Path $codexPath

    $token = "synthetic-connector-token-$testId"
    $agentId = "windows-ci-agent-$testId"
    $identity = [pscustomobject][ordered]@{
        server = "http://127.0.0.1:9/aichat"
        token = $token
        agent_id = $agentId
        agent_name = "Windows Connector CI"
        channel_id = "identity-default-must-not-be-used"
    }
    Write-AIChatPrivateJson `
        -Path $identityPath `
        -Value $identity `
        -ProtectedRoot $protectedRoot
    $settingsA = [pscustomobject][ordered]@{
        identity_config_path = $identityPath
        expected_agent_id = $agentId
        channel_id = "dedicated-connector-channel-$testId"
        allowed_sender_ids = @("remote-agent-$testId")
        target_thread_id = "00000000-0000-0000-0000-000000000001"
        task_marker = "AIChat Windows CI connector marker $testId"
        app_server_cwd = $repositoryRoot
        sandbox_policy = [pscustomobject]@{
            type = "readOnly"
            networkAccess = $false
        }
        egress = [pscustomobject]@{
            enabled = $false
            acknowledged_channel_id = ""
            canary_path = ""
            allowed_reference_hosts = @()
            max_text_bytes = 8192
        }
        max_turns_per_sender_per_hour = 10
        max_deliveries_per_recovery = 20
        node_binary = $nodePath
        npm_cli_path = $npmCliPath
        codex_app_server_binary = $codexPath
    }
    $freshMappingState = New-AIChatConnectorMappingState -Settings $settingsA
    [void](Assert-AIChatConnectorMappingState `
        -MappingState $freshMappingState `
        -Settings $settingsA)
    if ([string]$freshMappingState.state_mode -ne "mapping-digest" -or
        [string]$freshMappingState.state_basename -notmatch '^state-[a-f0-9]{64}\.json$') {
        throw "Fresh connector mapping did not select a digest-scoped state file"
    }
    $legacyMappingState = New-AIChatConnectorMappingState `
        -Settings $settingsA `
        -PreviousSettings $settingsA
    if ([string]$legacyMappingState.state_mode -ne "legacy-default" -or
        [string]$legacyMappingState.state_basename -ne "state.json") {
        throw "Unchanged pre-namespace mapping did not retain legacy state.json"
    }
    $differentMappingSettings = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $differentMappingSettings.channel_id = "different-channel-$testId"
    $differentMappingState = New-AIChatConnectorMappingState `
        -Settings $differentMappingSettings `
        -PreviousSettings $settingsA
    if ([string]$differentMappingState.state_mode -ne "mapping-digest" -or
        [string]$differentMappingState.mapping_digest -eq [string]$freshMappingState.mapping_digest) {
        throw "Changed mapping reused the previous connector state namespace"
    }
    $differentIdentitySettings = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $differentIdentitySettings.expected_agent_id = [Guid]::NewGuid().ToString("D")
    $differentIdentityState = New-AIChatConnectorMappingState `
        -Settings $differentIdentitySettings `
        -PreviousSettings $settingsA
    if ([string]$differentIdentityState.state_mode -ne "mapping-digest" -or
        [string]$differentIdentityState.mapping_digest -eq [string]$freshMappingState.mapping_digest) {
        throw "Changed local Agent identity reused the previous connector state namespace"
    }
    Write-AIChatPrivateJson `
        -Path $settingsPath `
        -Value $settingsA `
        -ProtectedRoot $protectedRoot

    $resultInboundSettings = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $resultInboundSettings | Add-Member `
        -NotePropertyName deliver_results `
        -NotePropertyValue $true
    Write-AIChatPrivateJson `
        -Path $deliverResultsSettingsPath `
        -Value $resultInboundSettings `
        -ProtectedRoot $protectedRoot
    $validatedResultInbound = Get-AIChatConnectorSettings `
        -Path $deliverResultsSettingsPath `
        -ProtectedRoot $protectedRoot
    if (-not [bool]$validatedResultInbound.deliver_results) {
        throw "Result inbound opt-in did not validate"
    }
    $invalidInboundShape = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $invalidInboundShape | Add-Member `
        -NotePropertyName deliver_results `
        -NotePropertyValue "true"
    Write-AIChatPrivateJson `
        -Path $deliverResultsSettingsPath `
        -Value $invalidInboundShape `
        -ProtectedRoot $protectedRoot
    Invoke-ExpectedFailure `
        -Label "deliver_results string shape check" `
        -Action {
            Get-AIChatConnectorSettings `
                -Path $deliverResultsSettingsPath `
                -ProtectedRoot $protectedRoot
        }

    [IO.File]::WriteAllText(
        $egressCanary,
        "synthetic-egress-canary-$testId",
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatCurrentSidOnlyAcl -Path $egressCanary
    $egressSettings = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $egressSettings.egress = [pscustomobject]@{
        enabled = $true
        acknowledged_channel_id = [string]$settingsA.channel_id
        canary_path = $egressCanary
        allowed_reference_hosts = @("github.com")
        max_text_bytes = 4096
    }
    Write-AIChatPrivateJson `
        -Path $egressSettingsPath `
        -Value $egressSettings `
        -ProtectedRoot $protectedRoot
    $validatedEgress = Get-AIChatConnectorSettings `
        -Path $egressSettingsPath `
        -ProtectedRoot $protectedRoot
    if (-not [bool]$validatedEgress.egress.enabled -or
        [string]$validatedEgress.egress.acknowledged_channel_id -ne [string]$settingsA.channel_id -or
        @($validatedEgress.egress.allowed_reference_hosts).Count -ne 1 -or
        [string]$validatedEgress.egress.allowed_reference_hosts[0] -ne "github.com") {
        throw "Enabled result egress settings did not validate exactly"
    }
    $mismatchedEgress = $egressSettings | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $mismatchedEgress.egress.acknowledged_channel_id = "wrong-channel-$testId"
    Write-AIChatPrivateJson `
        -Path $egressSettingsPath `
        -Value $mismatchedEgress `
        -ProtectedRoot $protectedRoot
    Invoke-ExpectedFailure `
        -Label "egress channel acknowledgement check" `
        -Action { Get-AIChatConnectorSettings -Path $egressSettingsPath -ProtectedRoot $protectedRoot }

    $hashMismatchSettings = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $hashMismatchSettings | Add-Member `
        -NotePropertyName node_sha256 `
        -NotePropertyValue ((Get-FileHash -LiteralPath $nodePath -Algorithm SHA256).Hash.ToLowerInvariant())
    $hashMismatchSettings | Add-Member `
        -NotePropertyName npm_cli_sha256 `
        -NotePropertyValue ((Get-FileHash -LiteralPath $npmCliPath -Algorithm SHA256).Hash.ToLowerInvariant())
    $hashMismatchSettings | Add-Member `
        -NotePropertyName codex_sha256 `
        -NotePropertyValue ("0" * 64)
    Write-AIChatPrivateJson `
        -Path $hashMismatchSettingsPath `
        -Value $hashMismatchSettings `
        -ProtectedRoot $protectedRoot
    $env:AICHAT_CI_CODEX_EXEC_CANARY = $codexCanary
    Invoke-ExpectedFailure `
        -Label "binary hash-before-execute check" `
        -Action {
            Get-AIChatConnectorSettings `
                -Path $hashMismatchSettingsPath `
                -ProtectedRoot $protectedRoot `
                -RequirePinnedHashes
        }
    $env:AICHAT_CI_CODEX_EXEC_CANARY = $null
    if (Test-Path -LiteralPath $codexCanary) {
        throw "Hash-mismatched Codex binary executed before pin verification"
    }

    $unsafeHttpIdentity = $identity | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $unsafeHttpIdentity.server = "http://example.com/aichat"
    $networkProbe = {
        param([string]$Uri, [string]$Token)
        [IO.File]::WriteAllText($networkCanary, "network-called")
        return [pscustomobject]@{ agent_id = $agentId }
    }
    Invoke-ExpectedFailure `
        -Label "external HTTP identity zero-network check" `
        -Action {
            Test-AIChatRelayIdentity `
                -Identity $unsafeHttpIdentity `
                -ExpectedAgentId $agentId `
                -RequestInvoker $networkProbe
        }
    if (Test-Path -LiteralPath $networkCanary) {
        throw "Unsafe external HTTP identity reached the authorized network request"
    }

    $rootSddl = (Get-Acl -LiteralPath $protectedRoot).Sddl
    $settingsHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    $identityHash = (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash
    $env:AICHAT_CI_CODEX_EXEC_CANARY = $codexCanary
    $mockNpm = "@echo off`r`necho executed>`"$pathCanary`"`r`nexit /b 77`r`n"
    [IO.File]::WriteAllText(
        (Join-Path $mockBin "npm.cmd"),
        $mockNpm,
        [Text.Encoding]::ASCII
    )
    Set-AIChatCurrentSidOnlyAcl -Path (Join-Path $mockBin "npm.cmd")
    $oldPath = $env:PATH
    $env:PATH = "$mockBin;$oldPath"
    $whatIfOutput = & $installer `
        -SettingsPath $settingsPath `
        -RepositoryRoot $repositoryRoot `
        -Apply -WhatIf *>&1 | Out-String
    Add-CapturedOutput $whatIfOutput
    if ($whatIfOutput -notmatch '(?m)^mapping_state_selection=deferred_until_apply\s*$' -or
        $whatIfOutput -notmatch '(?m)^legacy_connector_state_mutated=false\s*$') {
        throw "Connector service WhatIf did not report the inert mapping-state boundary"
    }
    $env:PATH = $oldPath
    $env:AICHAT_CI_CODEX_EXEC_CANARY = $null
    if ((Test-Path -LiteralPath $paths.StateRoot) -or
        $null -ne (Get-AIChatConnectorTask) -or
        (Get-Acl -LiteralPath $protectedRoot).Sddl -ne $rootSddl -or
        (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $settingsHash -or
        (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash -ne $identityHash -or
        (Test-Path -LiteralPath $codexCanary) -or
        (Test-Path -LiteralPath $pathCanary)) {
        throw "Connector service WhatIf produced a side effect"
    }

    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = "after-connector-data-acl"
    Invoke-ExpectedFailure `
        -Label "first-install connector ACL rollback" `
        -Action { & $installer -SettingsPath $settingsPath -RepositoryRoot $repositoryRoot -Apply }
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
    if ((Test-Path -LiteralPath $paths.ConnectorDataRoot) -or
        (Test-Path -LiteralPath $paths.TransactionPath) -or
        $null -ne (Get-AIChatConnectorTask)) {
        throw "First-install ACL failure did not restore the absent connector data root"
    }

    $env:PATH = "$mockBin;$oldPath"
    $installAOutput = & $installer `
        -SettingsPath $settingsPath `
        -RepositoryRoot $repositoryRoot `
        -Apply *>&1 | Out-String
    $env:PATH = $oldPath
    Add-CapturedOutput $installAOutput
    if ($LASTEXITCODE -ne 0) { throw "First connector service install failed" }
    if (Test-Path -LiteralPath $pathCanary) {
        throw "Installer executed a PATH-prepended npm.cmd instead of pinned npm-cli.js"
    }
    $taskA = Get-AIChatConnectorTask
    Assert-AIChatTaskContract -Task $taskA -Paths $paths
    if ([int]$taskA.State -ne 1) { throw "Connector task is not exactly Disabled after install" }
    Invoke-ExpectedFailure `
        -Label "queued task state check" `
        -Action { Assert-AIChatTaskDisabledState -Task ([pscustomobject]@{ State = 2 }) }
    $taskASnapshot = [pscustomobject]@{
        existed = $true
        xml_sha256 = Get-AIChatSha256Text -Value ([string]$taskA.Xml)
    }
    [void](Assert-AIChatTaskSnapshotForMutation `
        -Snapshot $taskASnapshot `
        -Paths $paths `
        -TaskProvider { $taskA })
    Invoke-ExpectedFailure `
        -Label "task appeared before mutation check" `
        -Action {
            Assert-AIChatTaskSnapshotForMutation `
                -Snapshot ([pscustomobject]@{ existed = $false }) `
                -Paths $paths `
                -TaskProvider { $taskA }
        }
    [void](Assert-AIChatPrivateDirectoryTree `
        -Path $paths.StateRoot `
        -ProtectedRoot $paths.ProtectedRoot)
    [void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)
    $installedMappingState = Read-AIChatPrivateJson `
        -Path $paths.MappingStatePath `
        -ProtectedRoot $paths.ProtectedRoot
    $connectorStatePath = Get-AIChatConnectorStatePath `
        -Paths $paths `
        -Settings (Get-AIChatConnectorSettings `
            -Path $paths.SettingsPath `
            -ProtectedRoot $paths.ProtectedRoot `
            -RequirePinnedHashes) `
        -MappingState $installedMappingState
    if ([string]$installedMappingState.state_mode -ne "mapping-digest" -or
        (Split-Path -Leaf $connectorStatePath) -ne [string]$installedMappingState.state_basename -or
        (Test-Path -LiteralPath $paths.ConnectorLegacyStatePath)) {
        throw "Fresh install did not preserve an empty legacy state namespace"
    }
    $connectorDataAcl = Get-Acl -LiteralPath $paths.ConnectorDataRoot
    $connectorDataSids = @($connectorDataAcl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    ) | ForEach-Object { $_.IdentityReference.Value })
    if (-not $connectorDataAcl.AreAccessRulesProtected -or
        $connectorDataSids.Count -ne 2 -or
        $connectorDataSids -notcontains (Get-AIChatCurrentSid) -or
        $connectorDataSids -notcontains "S-1-5-18") {
        throw "Connector data root does not have the protected user and LocalSystem ACL"
    }

    [IO.File]::WriteAllText($inheritedDataProbe, "{}`n", [Text.UTF8Encoding]::new($false))
    # Elevated hosted runners may default a newly created file owner to the
    # Administrators group. Normalize only the synthetic probe owner while
    # preserving its inherited DACL so it matches a legacy user-process write.
    $inheritedProbeAcl = Get-Acl -LiteralPath $inheritedDataProbe
    $inheritedProbeAcl.SetOwner(
        [Security.Principal.WindowsIdentity]::GetCurrent().User
    )
    Set-Acl -LiteralPath $inheritedDataProbe -AclObject $inheritedProbeAcl
    Invoke-ExpectedFailure `
        -Label "inherited connector data ACL check" `
        -Action { Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot }
    [void](Initialize-AIChatConnectorDataDirectory -Path $paths.ConnectorDataRoot)
    [void](Assert-AIChatConnectorDataTree -Path $paths.ConnectorDataRoot)
    Remove-Item -LiteralPath $inheritedDataProbe -Force

    [IO.File]::WriteAllText($broadDataProbe, "{}`n", [Text.UTF8Encoding]::new($false))
    Set-AIChatConnectorDataAcl -Path $broadDataProbe
    icacls.exe $broadDataProbe /grant "*S-1-1-0:(R)" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create broad connector ACL probe" }
    Invoke-ExpectedFailure `
        -Label "broad connector data ACL migration check" `
        -Action { Initialize-AIChatConnectorDataDirectory -Path $paths.ConnectorDataRoot }
    Set-AIChatConnectorDataAcl -Path $broadDataProbe
    $trustedProbeSddl = (Get-Acl -LiteralPath $broadDataProbe).Sddl
    Invoke-ExpectedFailure `
        -Label "owner/DACL fixed-contract check" `
        -Action {
            Set-AIChatOwnerAndDacl `
                -Path $broadDataProbe `
                -AllowedSids @((Get-AIChatCurrentSid), "S-1-1-0") `
                -IsDirectory $false
        }
    if ((Get-Acl -LiteralPath $broadDataProbe).Sddl -ne $trustedProbeSddl) {
        throw "Rejected owner/DACL contract changed the protected file"
    }
    Remove-Item -LiteralPath $broadDataProbe -Force

    [IO.File]::WriteAllText($broadDataProbe, "{}`n", [Text.UTF8Encoding]::new($false))
    Set-AIChatCurrentSidOnlyAcl -Path $broadDataProbe
    $legacyAclSddl = Get-AIChatOwnerAndDaclSddl -Path $broadDataProbe
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = "after-connector-data-acl"
    Invoke-ExpectedFailure `
        -Label "legacy connector ACL rollback" `
        -Action { & $installer -SettingsPath $settingsPath -RepositoryRoot $repositoryRoot -Apply }
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
    if ((Get-AIChatOwnerAndDaclSddl -Path $broadDataProbe) -ne $legacyAclSddl -or
        (Test-Path -LiteralPath $paths.TransactionPath)) {
        throw "Connector ACL failure did not restore the exact legacy owner/DACL"
    }
    Assert-AIChatConnectorDataAcl -Path $broadDataProbe -AllowLegacyCurrentSidOnly
    Remove-Item -LiteralPath $broadDataProbe -Force

    $env:AICHAT_WINDOWS_PRIVATE_SID = Get-AIChatCurrentSid
    & $nodePath `
        (Join-Path $PSScriptRoot "fixtures\write_connector_checkpoint.mjs") `
        $nodeDataProbe
    $env:AICHAT_WINDOWS_PRIVATE_SID = $null
    if ($LASTEXITCODE -ne 0) { throw "Node Windows checkpoint ACL probe failed" }
    [void](Assert-AIChatConnectorDataFile -Path $nodeDataProbe)
    $nodeProbeAcl = Get-Acl -LiteralPath $nodeDataProbe
    $nodeProbeOwner = $nodeProbeAcl.GetOwner(
        [Security.Principal.SecurityIdentifier]
    ).Value
    $nodeProbeSids = @($nodeProbeAcl.GetAccessRules(
        $true,
        $true,
        [Security.Principal.SecurityIdentifier]
    ) | ForEach-Object { $_.IdentityReference.Value })
    if ($nodeProbeOwner -ne (Get-AIChatCurrentSid) -or
        -not $nodeProbeAcl.AreAccessRulesProtected -or
        $nodeProbeSids.Count -ne 2 -or
        $nodeProbeSids -notcontains (Get-AIChatCurrentSid) -or
        $nodeProbeSids -notcontains "S-1-5-18") {
        throw "Node Windows checkpoint ACL probe did not persist the exact trusted contract"
    }
    Remove-Item -LiteralPath $nodeDataProbe -Force
    $launcherOutput = & $paths.LauncherPath `
        -StateRoot $paths.StateRoot `
        -CheckSettings *>&1 | Out-String
    Add-CapturedOutput $launcherOutput
    foreach ($required in @(
        "deliver_types=request",
        "automatic_egress=false",
        "lifecycle_status_egress=false",
        "periodic_recovery=false",
        "websocket=true",
        "state_file_fixed=true",
        "state_file_mapping_scoped=true",
        "token_read=false"
    )) {
        if ($launcherOutput -notmatch "(?m)^$([regex]::Escape($required))\s*$") {
            throw "Launcher did not report required contract: $required"
        }
    }

    [IO.File]::WriteAllText(
        $connectorStatePath,
        (([pscustomobject]@{ version = 5 } | ConvertTo-Json) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatConnectorDataAcl -Path $connectorStatePath
    Invoke-ExpectedFailure `
        -Label "pre-existing supervised connector checkpoint" `
        -Action {
            & $paths.LauncherPath `
                -StateRoot $paths.StateRoot `
                -Once `
                -ExpectedMessageId ([Guid]::NewGuid().ToString("D"))
        }
    Remove-Item -LiteralPath $connectorStatePath -Force

    $priorDriverReceiptPath = Join-Path `
        $paths.ConnectorDataRoot `
        "app-server-ci-prior-$testId.json"
    $priorDriverReceipt = [pscustomobject]@{
            binding = [pscustomobject]@{
                channelId = [string]$settingsA.channel_id
                threadId = [string]$settingsA.target_thread_id
                hostId = $null
            }
            records = @()
        }
    [IO.File]::WriteAllText(
        $priorDriverReceiptPath,
        (($priorDriverReceipt | ConvertTo-Json -Depth 8) + "`n"),
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatConnectorDataAcl -Path $priorDriverReceiptPath
    Invoke-ExpectedFailure `
        -Label "pre-existing supervised app-server checkpoint" `
        -Action {
            & $paths.LauncherPath `
                -StateRoot $paths.StateRoot `
                -Once `
                -ExpectedMessageId ([Guid]::NewGuid().ToString("D"))
        }
    Remove-Item -LiteralPath $priorDriverReceiptPath -Force

    $checkOutput = & $checker *>&1 | Out-String
    Add-CapturedOutput $checkOutput
    if ($LASTEXITCODE -ne 0) {
        if ($checkOutput.Contains($token)) {
            throw "Connector service check exposed the synthetic Relay token"
        }
        $allowedFailedChecks = @(
            "state-acl",
            "connector-state-acl",
            "transaction",
            "settings",
            "mapping-state",
            "launcher",
            "scheduled-task",
            "codex-home",
            "relay-identity"
        )
        $failedCheckNames = [Collections.Generic.List[string]]::new()
        foreach ($line in @($checkOutput -split "`r?`n")) {
            if ($line -match '^\[FAIL\] ([a-z][a-z-]*):') {
                $failedCheck = [string]$Matches[1]
                if ($allowedFailedChecks -contains $failedCheck -and
                    -not $failedCheckNames.Contains($failedCheck)) {
                    [void]$failedCheckNames.Add($failedCheck)
                }
            }
        }
        $failedCheckSummary = if ($failedCheckNames.Count -gt 0) {
            [string]::Join(",", $failedCheckNames)
        } else { "unclassified" }
        throw "Connector service check failed after first install; failed_checks=$failedCheckSummary"
    }

    # Stage-only upgrade is the foreground acceptance path for hosts where
    # Task Scheduler registration is unavailable. The synthetic denial makes
    # any accidental query, registration, restore, or delete fail immediately.
    $stageOnlyTaskXml = [string](Get-AIChatConnectorTask).Xml
    $stageOnlyTaskXmlHash = Get-AIChatSha256Text -Value $stageOnlyTaskXml
    $stageOnlyTargetHashes = [ordered]@{}
    $stageOnlyTargets = Get-AIChatDeploymentTargets -Paths $paths
    foreach ($targetId in @($stageOnlyTargets.Keys)) {
        $targetPath = [string]$stageOnlyTargets[$targetId]
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Stage-only baseline target is absent: $targetId"
        }
        $stageOnlyTargetHashes[$targetId] = (Get-FileHash `
            -LiteralPath $targetPath `
            -Algorithm SHA256).Hash
    }
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_TASK_ACCESS = "deny"
    try {
        $stageOnlyWhatIf = & $installer `
            -SettingsPath $settingsPath `
            -RepositoryRoot $repositoryRoot `
            -StageOnly -Apply -WhatIf *>&1 | Out-String
        Add-CapturedOutput $stageOnlyWhatIf
        if ($LASTEXITCODE -ne 0 -or
            $stageOnlyWhatIf -notmatch '(?m)^stage_only=true\s*$' -or
            $stageOnlyWhatIf -notmatch '(?m)^mutation_performed=false\s*$' -or
            $stageOnlyWhatIf -notmatch '(?m)^task_scheduler_accessed=false\s*$') {
            throw "Stage-only WhatIf did not preserve the no-task boundary"
        }

        $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = "after-files"
        Invoke-ExpectedFailure `
            -Label "stage-only failure rollback without Task Scheduler" `
            -Action {
                & $installer `
                    -SettingsPath $settingsPath `
                    -RepositoryRoot $repositoryRoot `
                    -StageOnly -Apply
            }
        $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
        if (Test-Path -LiteralPath $paths.TransactionPath) {
            throw "Stage-only failure recovery did not restore the prior package"
        }
        foreach ($targetId in @($stageOnlyTargets.Keys)) {
            $targetPath = [string]$stageOnlyTargets[$targetId]
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -ne
                    [string]$stageOnlyTargetHashes[$targetId]) {
                throw "Stage-only failure recovery changed prior target: $targetId"
            }
        }

        $stageOnlyInstall = & $installer `
            -SettingsPath $settingsPath `
            -RepositoryRoot $repositoryRoot `
            -StageOnly -Apply *>&1 | Out-String
        Add-CapturedOutput $stageOnlyInstall
        if ($LASTEXITCODE -ne 0 -or
            $stageOnlyInstall -notmatch '(?m)^manual_launcher_ready=true\s*$' -or
            $stageOnlyInstall -notmatch '(?m)^task_scheduler_accessed=false\s*$' -or
            $stageOnlyInstall -notmatch '(?m)^task_mutation_performed=false\s*$') {
            throw "Stage-only install did not complete without Task Scheduler"
        }
        $stageOnlyManifestPointer = Read-AIChatPrivateJson `
            -Path $paths.LastBackupPath `
            -ProtectedRoot $paths.ProtectedRoot
        $stageOnlyManifest = Read-AIChatPrivateJson `
            -Path (Join-Path `
                (Join-Path $paths.BackupsDirectory ([string]$stageOnlyManifestPointer.transaction_id)) `
                "manifest.json") `
            -ProtectedRoot $paths.ProtectedRoot
        if ([int]$stageOnlyManifest.schema_version -ne 4 -or
            [string]$stageOnlyManifest.task.mode -ne "untouched" -or
            @($stageOnlyManifest.task.PSObject.Properties).Count -ne 1) {
            throw "Stage-only journal captured Scheduled Task state"
        }

        $stageOnlyCheck = & $checker -StageOnly *>&1 | Out-String
        Add-CapturedOutput $stageOnlyCheck
        if ($LASTEXITCODE -ne 0 -or
            $stageOnlyCheck -notmatch '(?m)^task_scheduler_accessed=false\s*$' -or
            $stageOnlyCheck -notmatch '(?m)^expected_service_enabled=unchanged\s*$') {
            throw "Stage-only package validation accessed Task Scheduler"
        }

        $stageOnlyRollbackWhatIf = & $rollback `
            -StageOnly -Apply -WhatIf *>&1 | Out-String
        Add-CapturedOutput $stageOnlyRollbackWhatIf
        if ($LASTEXITCODE -ne 0 -or
            $stageOnlyRollbackWhatIf -notmatch '(?m)^mutation_performed=false\s*$') {
            throw "Stage-only rollback WhatIf was not inert"
        }
        $stageOnlyRollback = & $rollback -StageOnly -Apply *>&1 | Out-String
        Add-CapturedOutput $stageOnlyRollback
        if ($LASTEXITCODE -ne 0 -or
            $stageOnlyRollback -notmatch '(?m)^task_scheduler_accessed=false\s*$' -or
            $stageOnlyRollback -notmatch '(?m)^task_mutation_performed=false\s*$') {
            throw "Stage-only rollback accessed Task Scheduler"
        }
    } finally {
        $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
        $env:AICHAT_WINDOWS_CONNECTOR_TEST_TASK_ACCESS = $null
    }
    $stageOnlyTaskXmlAfter = [string](Get-AIChatConnectorTask).Xml
    if ($stageOnlyTaskXmlAfter -ne $stageOnlyTaskXml -or
        (Get-AIChatSha256Text -Value $stageOnlyTaskXmlAfter) -ne
            $stageOnlyTaskXmlHash) {
        throw "Stage-only install/rollback changed the existing task XML"
    }
    foreach ($targetId in @($stageOnlyTargets.Keys)) {
        $targetPath = [string]$stageOnlyTargets[$targetId]
        if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -ne
                [string]$stageOnlyTargetHashes[$targetId]) {
            throw "Stage-only install/rollback changed prior target: $targetId"
        }
    }

    New-Item -ItemType HardLink -Path $hardlinkAlias -Target $paths.SettingsPath | Out-Null
    Invoke-ExpectedFailure `
        -Label "hardlink alias check" `
        -Action { Read-AIChatPrivateJson -Path $paths.SettingsPath -ProtectedRoot $paths.ProtectedRoot }
    Remove-Item -LiteralPath $hardlinkAlias -Force

    Write-AIChatPrivateJson `
        -Path $aclProbe `
        -Value ([pscustomobject]@{ value = 1 }) `
        -ProtectedRoot $protectedRoot
    icacls.exe $aclProbe /inheritance:e | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create inherited-ACL probe" }
    Invoke-ExpectedFailure `
        -Label "inherited ACL check" `
        -Action { Read-AIChatPrivateJson -Path $aclProbe -ProtectedRoot $protectedRoot }
    Remove-Item -LiteralPath $aclProbe -Force

    [void](Initialize-AIChatPrivateDirectory `
        -Path $junctionTarget `
        -ProtectedRoot $protectedRoot)
    Copy-AIChatPrivateFileAtomic `
        -Source $identityPath `
        -Destination (Join-Path $junctionTarget "identity.json") `
        -ProtectedRoot $protectedRoot
    & cmd.exe /d /c "mklink /J `"$junctionPath`" `"$junctionTarget`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not create junction security probe" }
    $unsafe = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $unsafe.identity_config_path = Join-Path $junctionPath "identity.json"
    Write-AIChatPrivateJson `
        -Path $unsafeSettingsPath `
        -Value $unsafe `
        -ProtectedRoot $protectedRoot
    Invoke-ExpectedFailure `
        -Label "junction path check" `
        -Action { Get-AIChatConnectorSettings -Path $unsafeSettingsPath -ProtectedRoot $protectedRoot }
    & cmd.exe /d /c "rmdir `"$junctionPath`"" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not remove junction security probe" }

    $activeHashA = (Get-FileHash -LiteralPath $paths.ActiveReleasePath -Algorithm SHA256).Hash
    $mappingHashA = (Get-FileHash -LiteralPath $paths.MappingStatePath -Algorithm SHA256).Hash
    $taskXmlA = [string](Get-AIChatConnectorTask).Xml
    $installedSettingsA = Read-AIChatPrivateJson `
        -Path $paths.SettingsPath `
        -ProtectedRoot $paths.ProtectedRoot
    $settingsB = $settingsA | ConvertTo-Json -Depth 12 | ConvertFrom-Json
    $settingsB.task_marker = "AIChat Windows CI updated marker $testId"
    $settingsB | Add-Member `
        -NotePropertyName deliver_results `
        -NotePropertyValue $true
    Write-AIChatPrivateJson `
        -Path $settingsPath `
        -Value $settingsB `
        -ProtectedRoot $protectedRoot
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = "after-files"
    Invoke-ExpectedFailure `
        -Label "failure injection install" `
        -Action { & $installer -SettingsPath $settingsPath -RepositoryRoot $repositoryRoot -Apply }
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
    if ((Get-FileHash -LiteralPath $paths.ActiveReleasePath -Algorithm SHA256).Hash -ne $activeHashA -or
        (Get-FileHash -LiteralPath $paths.MappingStatePath -Algorithm SHA256).Hash -ne $mappingHashA -or
        [string](Get-AIChatConnectorTask).Xml -ne $taskXmlA -or
        (Test-Path -LiteralPath $paths.TransactionPath)) {
        throw "Failure injection did not restore the prior package exactly"
    }
    $restoredSettings = Read-AIChatPrivateJson `
        -Path $paths.SettingsPath `
        -ProtectedRoot $paths.ProtectedRoot
    if ([string]$restoredSettings.task_marker -ne [string]$installedSettingsA.task_marker) {
        throw "Failure injection did not restore installed connector settings"
    }

    $installBOutput = & $installer `
        -SettingsPath $settingsPath `
        -RepositoryRoot $repositoryRoot `
        -Apply *>&1 | Out-String
    Add-CapturedOutput $installBOutput
    if ($LASTEXITCODE -ne 0) { throw "Second connector service install failed" }
    $launcherBOutput = & $paths.LauncherPath `
        -StateRoot $paths.StateRoot `
        -CheckSettings *>&1 | Out-String
    Add-CapturedOutput $launcherBOutput
    if ($launcherBOutput -notmatch '(?m)^deliver_types=request,result\s*$') {
        throw "Installed launcher did not expose the result inbound opt-in"
    }
    $preRollbackWhatIfActiveHash = (Get-FileHash `
        -LiteralPath $paths.ActiveReleasePath `
        -Algorithm SHA256).Hash
    $preRollbackWhatIfMappingHash = (Get-FileHash `
        -LiteralPath $paths.MappingStatePath `
        -Algorithm SHA256).Hash
    $preRollbackWhatIfTaskXml = [string](Get-AIChatConnectorTask).Xml
    $rollbackWhatIfOutput = & $rollback -Apply -WhatIf *>&1 | Out-String
    Add-CapturedOutput $rollbackWhatIfOutput
    if ($rollbackWhatIfOutput -notmatch '(?m)^mapping_state_rollback=deferred_until_apply\s*$' -or
        $rollbackWhatIfOutput -notmatch '(?m)^connector_data_mutated=false\s*$' -or
        (Get-FileHash -LiteralPath $paths.ActiveReleasePath -Algorithm SHA256).Hash -ne
            $preRollbackWhatIfActiveHash -or
        (Get-FileHash -LiteralPath $paths.MappingStatePath -Algorithm SHA256).Hash -ne
            $preRollbackWhatIfMappingHash -or
        [string](Get-AIChatConnectorTask).Xml -ne $preRollbackWhatIfTaskXml) {
        throw "Connector service rollback WhatIf produced a mapping or package side effect"
    }
    $rollbackOutput = & $rollback -Apply *>&1 | Out-String
    Add-CapturedOutput $rollbackOutput
    if ($LASTEXITCODE -ne 0) { throw "Connector service rollback failed" }
    $rolledBackSettings = Read-AIChatPrivateJson `
        -Path $paths.SettingsPath `
        -ProtectedRoot $paths.ProtectedRoot
    if ([string]$rolledBackSettings.task_marker -ne [string]$installedSettingsA.task_marker) {
        throw "Connector service rollback did not restore the first install"
    }
    if ((Get-FileHash -LiteralPath $paths.MappingStatePath -Algorithm SHA256).Hash -ne $mappingHashA) {
        throw "Connector service rollback did not restore mapping state metadata"
    }
    Assert-AIChatTaskContract -Task (Get-AIChatConnectorTask) -Paths $paths

    # Emulate an upgrade from the pre-namespace package: installed settings are
    # present, mapping-state.json is absent, and legacy state.json belongs to
    # that unchanged fixed mapping. The installer must retain it in place.
    [void](Assert-AIChatPrivateFile `
        -Path $paths.MappingStatePath `
        -ProtectedRoot $paths.ProtectedRoot)
    Remove-Item -LiteralPath $paths.MappingStatePath -Force
    $legacyStateContent = "{`"version`":5,`"cursor`":`"legacy-$testId`"}`n"
    [IO.File]::WriteAllText(
        $paths.ConnectorLegacyStatePath,
        $legacyStateContent,
        [Text.UTF8Encoding]::new($false)
    )
    Set-AIChatConnectorDataAcl -Path $paths.ConnectorLegacyStatePath
    $legacyStateHash = (Get-FileHash `
        -LiteralPath $paths.ConnectorLegacyStatePath `
        -Algorithm SHA256).Hash
    Write-AIChatPrivateJson `
        -Path $settingsPath `
        -Value $settingsA `
        -ProtectedRoot $protectedRoot
    $legacyUpgradeOutput = & $installer `
        -SettingsPath $settingsPath `
        -RepositoryRoot $repositoryRoot `
        -Apply *>&1 | Out-String
    Add-CapturedOutput $legacyUpgradeOutput
    if ($LASTEXITCODE -ne 0 -or
        $legacyUpgradeOutput -notmatch '(?m)^mapping_state_mode=legacy-default\s*$') {
        throw "Legacy unchanged-mapping upgrade failed"
    }
    $legacyUpgradeSettings = Get-AIChatConnectorSettings `
        -Path $paths.SettingsPath `
        -ProtectedRoot $paths.ProtectedRoot `
        -RequirePinnedHashes
    $legacyUpgradeMapping = Read-AIChatPrivateJson `
        -Path $paths.MappingStatePath `
        -ProtectedRoot $paths.ProtectedRoot
    $legacyUpgradeStatePath = Get-AIChatConnectorStatePath `
        -Paths $paths `
        -Settings $legacyUpgradeSettings `
        -MappingState $legacyUpgradeMapping
    if (-not $legacyUpgradeStatePath.Equals(
            $paths.ConnectorLegacyStatePath,
            [StringComparison]::OrdinalIgnoreCase
        ) -or
        (Get-FileHash -LiteralPath $paths.ConnectorLegacyStatePath -Algorithm SHA256).Hash -ne
            $legacyStateHash) {
        throw "Legacy unchanged-mapping upgrade moved or changed state.json"
    }

    Push-Location (Join-Path $repositoryRoot "adapters\codex-connector")
    try {
        & $nodePath $npmCliPath ci --ignore-scripts --no-audit --no-fund
        if ($LASTEXITCODE -ne 0) { throw "Windows connector npm ci failed" }
        $env:AICHAT_WINDOWS_PRIVATE_SID = Get-AIChatCurrentSid
        & $nodePath --test
        if ($LASTEXITCODE -ne 0) { throw "Windows connector Node test suite failed" }
    } finally {
        $env:AICHAT_WINDOWS_PRIVATE_SID = $null
        Pop-Location
    }

    $uninstallOutput = & $uninstaller -Apply *>&1 | Out-String
    Add-CapturedOutput $uninstallOutput
    if ($LASTEXITCODE -ne 0 -or
        $null -ne (Get-AIChatConnectorTask) -or
        (Test-Path -LiteralPath $paths.StateRoot) -or
        (Test-Path -LiteralPath $paths.ConnectorDataRoot) -or
        -not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw "Connector service uninstall did not preserve the expected boundary"
    }
    $secondUninstall = & $uninstaller -Apply *>&1 | Out-String
    Add-CapturedOutput $secondUninstall
    if ($secondUninstall -notmatch "already_uninstalled=true") {
        throw "Connector service uninstall is not idempotent"
    }

    if ($allOutput.ToString().Contains($token)) {
        throw "Connector service exposed the synthetic Relay token in output"
    }
    Write-Host "Windows connector service functional test passed"
} finally {
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_FAILURE = $null
    $env:AICHAT_WINDOWS_CONNECTOR_TEST_TASK_ACCESS = $null
    $env:AICHAT_CI_CODEX_EXEC_CANARY = $null
    $env:AICHAT_WINDOWS_PRIVATE_SID = $null
    if ($null -ne (Get-AIChatConnectorTask)) {
        try {
            $task = Get-AIChatConnectorTask
            if ([int]$task.State -eq 1) {
                $service = New-Object -ComObject "Schedule.Service"
                $service.Connect()
                $service.GetFolder("\AIChat").DeleteTask("CodexConnector", 0)
            }
        } catch {}
    }
    if (Test-Path -LiteralPath $junctionPath) {
        & cmd.exe /d /c "rmdir `"$junctionPath`"" | Out-Null
    }
    foreach ($path in @(
        $inheritedDataProbe,
        $broadDataProbe,
        $nodeDataProbe,
        $hardlinkAlias,
        $unsafeSettingsPath,
        $settingsPath,
        $deliverResultsSettingsPath,
        $egressSettingsPath,
        $egressCanary,
        $hashMismatchSettingsPath,
        $networkCanary,
        $identityPath,
        $aclProbe,
        $junctionTarget,
        $toolsRoot
    )) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    if ($createdCodexHome -and (Test-Path -LiteralPath $codexHome)) {
        Remove-Item -LiteralPath $codexHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}

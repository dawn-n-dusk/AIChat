[CmdletBinding()]
param(
    [ValidateRange(1000, 120000)]
    [int]$StartupTimeoutMilliseconds = 60000,
    [ValidateRange(1000, 60000)]
    [int]$ToolTimeoutMilliseconds = 30000,
    [ValidateRange(1000, 30000)]
    [int]$ShutdownTimeoutMilliseconds = 5000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:AIChatMcpProbeProcess = $null
$script:AIChatMcpProbeStderrTask = $null
$script:AIChatMcpProbeErrorCode = "none"
$script:AIChatMcpProbeFailedStage = "none"
$script:AIChatMcpProbeIdentityCallCount = 0
$script:AIChatMcpProbeForcedCleanup = $false
$script:AIChatMcpProbeChildRemaining = $false
$script:AIChatMcpProbeStderrObserved = $false
$script:AIChatMcpProbeIdentityAgentObject = $false
$script:AIChatMcpProbeIdentityRelayString = $false
$script:AIChatMcpProbeIdentityTokenNotExposed = $false

$script:AIChatMcpExpectedSource =
    "git+https://github.com/dawn-n-dusk/AIChat.git@main#subdirectory=adapters/mcp"
$script:AIChatMcpExpectedEnvironmentNames = @(
    "AICHAT_CONFIG",
    "AICHAT_SERVER",
    "AICHAT_TOKEN",
    "AICHAT_CHANNEL_ID",
    "AICHAT_TIMEOUT"
)

$script:AIChatMcpProbeStages = @(
    [pscustomobject][ordered]@{ name = "command_attestation"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "package_start"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "initialize"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "initialized"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "tools_list"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "dispatch"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "identity"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "result_frame"; status = "skipped"; elapsed_ms = 0 },
    [pscustomobject][ordered]@{ name = "shutdown"; status = "skipped"; elapsed_ms = 0 }
)

function ConvertTo-AIChatWindowsArgument {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append([char]0x22)
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq [char]0x5c) {
            $backslashes++
            continue
        }
        if ($character -eq [char]0x22) {
            for ($index = 0; $index -lt (($backslashes * 2) + 1); $index++) {
                [void]$builder.Append([char]0x5c)
            }
            [void]$builder.Append([char]0x22)
            $backslashes = 0
            continue
        }
        for ($index = 0; $index -lt $backslashes; $index++) {
            [void]$builder.Append([char]0x5c)
        }
        $backslashes = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashes * 2); $index++) {
        [void]$builder.Append([char]0x5c)
    }
    [void]$builder.Append([char]0x22)
    return $builder.ToString()
}

function New-AIChatProcessStartInfo {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$RedirectInput
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $extension = [IO.Path]::GetExtension($FilePath)
    if ($extension -ieq ".cmd" -or $extension -ieq ".bat") {
        $commandLine = (ConvertTo-AIChatWindowsArgument -Value $FilePath)
        if ($Arguments.Count -gt 0) {
            $commandLine += " " + (@($Arguments | ForEach-Object {
                ConvertTo-AIChatWindowsArgument -Value ([string]$_)
            }) -join " ")
        }
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = "/d /s /c `"$commandLine`""
    } else {
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = (@($Arguments | ForEach-Object {
            ConvertTo-AIChatWindowsArgument -Value ([string]$_)
        }) -join " ")
    }
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.RedirectStandardInput = [bool]$RedirectInput
    return $startInfo
}

function Set-AIChatMcpProbeStage {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)]
        [ValidateSet("ok", "failed", "skipped")]
        [string]$Status,
        [Parameter(Mandatory = $true)][long]$ElapsedMilliseconds
    )

    $matches = @($script:AIChatMcpProbeStages | Where-Object {
        [string]$_.name -ceq $Name
    })
    if ($matches.Count -ne 1) {
        throw "MCP probe stage is not allowlisted"
    }
    $matches[0].status = $Status
    $bounded = [Math]::Min([int64][int]::MaxValue, [Math]::Max(0, $ElapsedMilliseconds))
    $matches[0].elapsed_ms = [int]$bounded
}

function Set-AIChatMcpProbeFailure {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "command_attestation_failed",
            "uvx_unavailable",
            "package_start_failed",
            "package_bootstrap_failed",
            "timeout",
            "invalid_framing",
            "protocol_invalid",
            "identity_tool_missing",
            "dispatch_preflight_failed",
            "identity_call_failed",
            "identity_contract_invalid",
            "stderr_output",
            "shutdown_failed",
            "internal_error"
        )]
        [string]$ErrorCode,
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            "command_attestation", "package_start", "initialize",
            "initialized", "tools_list", "dispatch", "identity",
            "result_frame", "shutdown", "internal"
        )]
        [string]$Stage
    )

    if ($script:AIChatMcpProbeErrorCode -ceq "none" -or
        $ErrorCode -ceq "shutdown_failed") {
        $script:AIChatMcpProbeErrorCode = $ErrorCode
        $script:AIChatMcpProbeFailedStage = $Stage
    }
}

function Get-AIChatCommandApplication {
    param([Parameter(Mandatory = $true)][string]$Name)

    $matches = @(Get-Command $Name -CommandType Application -ErrorAction Stop)
    if ($matches.Count -lt 1) {
        throw "Required application is unavailable"
    }
    return [string]$matches[0].Source
}

function Stop-AIChatProcessTree {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    try {
        if ($Process.HasExited) {
            return $true
        }
    } catch {
        return $false
    }
    $script:AIChatMcpProbeForcedCleanup = $true
    $taskkillSucceeded = $false
    try {
        & (Join-Path $env:SystemRoot "System32\taskkill.exe") `
            /PID ([string]$Process.Id) /T /F *> $null
        $taskkillSucceeded = $LASTEXITCODE -eq 0
    } catch {
        # Verification below is authoritative; never forward taskkill diagnostics.
    }
    if (-not $taskkillSucceeded) {
        $script:AIChatMcpProbeChildRemaining = $true
        return $false
    }
    try {
        if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
            return $false
        }
    } catch {
        return $false
    }
    return $Process.HasExited
}

function Invoke-AIChatCapturedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $process = $null
    $started = $false
    try {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = New-AIChatProcessStartInfo `
            -FilePath $FilePath -Arguments $Arguments
        [void]$process.Start()
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            [void](Stop-AIChatProcessTree `
                -Process $process -TimeoutMilliseconds $ShutdownTimeoutMilliseconds)
            return [pscustomobject]@{
                success = $false
                timed_out = $true
                exit_code = $null
                stdout = ""
                stderr_seen = $false
            }
        }
        [void]$stdoutTask.Wait($ShutdownTimeoutMilliseconds)
        [void]$stderrTask.Wait($ShutdownTimeoutMilliseconds)
        return [pscustomobject]@{
            success = $true
            timed_out = $false
            exit_code = [int]$process.ExitCode
            stdout = if ($stdoutTask.IsCompleted) { [string]$stdoutTask.Result } else { "" }
            stderr_seen = $stderrTask.IsCompleted -and ([string]$stderrTask.Result).Length -gt 0
        }
    } catch {
        if ($null -ne $process -and $started) {
            [void](Stop-AIChatProcessTree `
                -Process $process -TimeoutMilliseconds $ShutdownTimeoutMilliseconds)
        }
        return [pscustomobject]@{
            success = $false
            timed_out = $false
            exit_code = $null
            stdout = ""
            stderr_seen = $false
        }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Test-AIChatMcpCommandAttestation {
    param([Parameter(Mandatory = $true)][string]$CodexPath)

    $capture = Invoke-AIChatCapturedCommand `
        -FilePath $CodexPath `
        -Arguments @("mcp", "get", "aichat") `
        -TimeoutMilliseconds 10000
    if (-not $capture.success -or $capture.timed_out -or
        $capture.exit_code -ne 0 -or $capture.stderr_seen) {
        return $false
    }
    $output = [string]$capture.stdout
    $expectedArgs = "--from " + $script:AIChatMcpExpectedSource + " aichat-mcp"
    $expectedEnvironment = @($script:AIChatMcpExpectedEnvironmentNames | ForEach-Object {
        $_ + "=*****"
    }) -join ", "
    $fields = @{}
    foreach ($line in @($output -split "`r?`n")) {
        if ($line -cmatch '^\s*(enabled|transport|command|args|cwd|env|startup_timeout_sec|tool_timeout_sec):\s*(.*?)\s*$') {
            $name = [string]$Matches[1]
            if ($fields.ContainsKey($name)) {
                return $false
            }
            $fields[$name] = [string]$Matches[2]
        }
    }
    if ($fields.Count -ne 8) {
        return $false
    }
    return (
        [string]$fields["enabled"] -ceq "true" -and
        [string]$fields["transport"] -ceq "stdio" -and
        [string]$fields["command"] -ceq "uvx" -and
        [string]$fields["args"] -ceq $expectedArgs -and
        [string]$fields["cwd"] -ceq "-" -and
        [string]$fields["env"] -ceq $expectedEnvironment -and
        [string]$fields["startup_timeout_sec"] -ceq "60" -and
        [string]$fields["tool_timeout_sec"] -ceq "30"
    )
}

function ConvertTo-AIChatMcpRequestJson {
    param([Parameter(Mandatory = $true)]$Value)
    return ($Value | ConvertTo-Json -Compress -Depth 10)
}

function Send-AIChatMcpMessage {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = ConvertTo-AIChatMcpRequestJson -Value $Value
    if ($json.Contains("`r") -or $json.Contains("`n")) {
        throw "MCP request framing is invalid"
    }
    $Process.StandardInput.WriteLine($json)
    $Process.StandardInput.Flush()
}

function Read-AIChatMcpResponse {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)][int]$ExpectedId,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $frameCount = 0
    while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        $remaining = [Math]::Max(
            1,
            $TimeoutMilliseconds - [int]$stopwatch.ElapsedMilliseconds
        )
        $readTask = $Process.StandardOutput.ReadLineAsync()
        if (-not $readTask.Wait($remaining)) {
            return [pscustomobject]@{ success = $false; code = "timeout"; value = $null }
        }
        $line = $readTask.Result
        if ($null -eq $line) {
            $earlyExit = $false
            try { $earlyExit = $Process.HasExited } catch { }
            return [pscustomobject]@{
                success = $false
                code = $(if ($earlyExit) { "process_early_exit" } else { "invalid_framing" })
                value = $null
            }
        }
        if ($line.Length -eq 0 -or $line.Length -gt 1048576) {
            return [pscustomobject]@{ success = $false; code = "invalid_framing"; value = $null }
        }
        $frameCount++
        if ($frameCount -gt 32) {
            return [pscustomobject]@{ success = $false; code = "protocol_invalid"; value = $null }
        }
        try {
            $value = $line | ConvertFrom-Json -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ success = $false; code = "invalid_framing"; value = $null }
        }
        if ($null -eq $value -or
            -not $value.PSObject.Properties["jsonrpc"] -or
            [string]$value.jsonrpc -cne "2.0") {
            return [pscustomobject]@{ success = $false; code = "protocol_invalid"; value = $null }
        }
        if ($value.PSObject.Properties["id"]) {
            $idIsInteger = $value.id -is [int] -or $value.id -is [long]
            $hasResult = $null -ne $value.PSObject.Properties["result"]
            $hasError = $null -ne $value.PSObject.Properties["error"]
            if (-not $idIsInteger -or [long]$value.id -ne [long]$ExpectedId -or
                $hasResult -eq $hasError) {
                return [pscustomobject]@{ success = $false; code = "protocol_invalid"; value = $null }
            }
            return [pscustomobject]@{ success = $true; code = "none"; value = $value }
        }
        if (-not $value.PSObject.Properties["method"] -or
            -not ([string]$value.method).StartsWith("notifications/")) {
            return [pscustomobject]@{ success = $false; code = "protocol_invalid"; value = $null }
        }
    }
    return [pscustomobject]@{ success = $false; code = "timeout"; value = $null }
}

function ConvertTo-AIChatAsciiJson {
    param([Parameter(Mandatory = $true)]$Value)

    $raw = $Value | ConvertTo-Json -Compress -Depth 10
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

try {
    $attestationTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $codexPath = Get-AIChatCommandApplication -Name "codex"
        $attested = Test-AIChatMcpCommandAttestation -CodexPath $codexPath
    } catch {
        $attested = $false
    }
    Set-AIChatMcpProbeStage `
        -Name "command_attestation" `
        -Status $(if ($attested) { "ok" } else { "failed" }) `
        -ElapsedMilliseconds $attestationTimer.ElapsedMilliseconds
    if (-not $attested) {
        Set-AIChatMcpProbeFailure `
            -ErrorCode "command_attestation_failed" `
            -Stage "command_attestation"
        throw "MCP command attestation failed"
    }

    $launchTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $uvxPath = Get-AIChatCommandApplication -Name "uvx"
    } catch {
        Set-AIChatMcpProbeStage `
            -Name "package_start" -Status "failed" `
            -ElapsedMilliseconds $launchTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "uvx_unavailable" -Stage "package_start"
        throw "uvx is unavailable"
    }
    $candidateProcess = $null
    try {
        $candidateProcess = [Diagnostics.Process]::new()
        $candidateProcess.StartInfo = New-AIChatProcessStartInfo `
            -FilePath $uvxPath `
            -Arguments @("--from", $script:AIChatMcpExpectedSource, "aichat-mcp") `
            -RedirectInput
        [void]$candidateProcess.Start()
        $script:AIChatMcpProbeProcess = $candidateProcess
        $candidateProcess = $null
        $script:AIChatMcpProbeProcess.StandardInput.NewLine = "`n"
        $script:AIChatMcpProbeStderrTask =
            $script:AIChatMcpProbeProcess.StandardError.ReadToEndAsync()
        Set-AIChatMcpProbeStage `
            -Name "package_start" -Status "ok" `
            -ElapsedMilliseconds $launchTimer.ElapsedMilliseconds
    } catch {
        if ($null -ne $candidateProcess) {
            $candidateProcess.Dispose()
        }
        Set-AIChatMcpProbeStage `
            -Name "package_start" -Status "failed" `
            -ElapsedMilliseconds $launchTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "package_start_failed" -Stage "package_start"
        throw "MCP package start failed"
    }

    $initializeTimer = [Diagnostics.Stopwatch]::StartNew()
    try {
        Send-AIChatMcpMessage `
            -Process $script:AIChatMcpProbeProcess `
            -Value ([pscustomobject][ordered]@{
                jsonrpc = "2.0"
                id = 1
                method = "initialize"
                params = [pscustomobject][ordered]@{
                    protocolVersion = "2025-06-18"
                    capabilities = [pscustomobject]@{}
                    clientInfo = [pscustomobject][ordered]@{
                        name = "aichat-windows-stdio-diagnostic"
                        version = "1.0"
                    }
                }
            })
    } catch {
        $exitedBeforeInitialize = $false
        try { $exitedBeforeInitialize = $script:AIChatMcpProbeProcess.HasExited } catch { }
        if ($exitedBeforeInitialize) {
            Set-AIChatMcpProbeStage `
                -Name "package_start" -Status "failed" `
                -ElapsedMilliseconds $launchTimer.ElapsedMilliseconds
            Set-AIChatMcpProbeFailure `
                -ErrorCode "package_bootstrap_failed" -Stage "package_start"
            throw "MCP package exited before protocol startup"
        }
        throw
    }
    $initializeResponse = Read-AIChatMcpResponse `
        -Process $script:AIChatMcpProbeProcess `
        -ExpectedId 1 `
        -TimeoutMilliseconds $StartupTimeoutMilliseconds
    if (-not $initializeResponse.success) {
        if ([string]$initializeResponse.code -ceq "process_early_exit") {
            Set-AIChatMcpProbeStage `
                -Name "package_start" -Status "failed" `
                -ElapsedMilliseconds $launchTimer.ElapsedMilliseconds
            Set-AIChatMcpProbeFailure `
                -ErrorCode "package_bootstrap_failed" -Stage "package_start"
            throw "MCP package exited before protocol startup"
        }
        Set-AIChatMcpProbeStage `
            -Name "initialize" -Status "failed" `
            -ElapsedMilliseconds $initializeTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode ([string]$initializeResponse.code) -Stage "initialize"
        throw "MCP initialize failed"
    }
    $initializeResult = if ($initializeResponse.value.PSObject.Properties["result"]) {
        $initializeResponse.value.result
    } else { $null }
    if ($null -eq $initializeResult -or
        -not $initializeResult.PSObject.Properties["protocolVersion"] -or
        -not [string]$initializeResult.protocolVersion -or
        -not $initializeResult.PSObject.Properties["capabilities"] -or
        -not $initializeResult.PSObject.Properties["serverInfo"]) {
        Set-AIChatMcpProbeStage `
            -Name "initialize" -Status "failed" `
            -ElapsedMilliseconds $initializeTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "protocol_invalid" -Stage "initialize"
        throw "MCP initialize contract failed"
    }
    Set-AIChatMcpProbeStage `
        -Name "initialize" -Status "ok" `
        -ElapsedMilliseconds $initializeTimer.ElapsedMilliseconds

    $initializedTimer = [Diagnostics.Stopwatch]::StartNew()
    Send-AIChatMcpMessage `
        -Process $script:AIChatMcpProbeProcess `
        -Value ([pscustomobject][ordered]@{
            jsonrpc = "2.0"
            method = "notifications/initialized"
        })
    Set-AIChatMcpProbeStage `
        -Name "initialized" -Status "ok" `
        -ElapsedMilliseconds $initializedTimer.ElapsedMilliseconds

    $toolsTimer = [Diagnostics.Stopwatch]::StartNew()
    Send-AIChatMcpMessage `
        -Process $script:AIChatMcpProbeProcess `
        -Value ([pscustomobject][ordered]@{
            jsonrpc = "2.0"
            id = 2
            method = "tools/list"
            params = [pscustomobject]@{}
        })
    $toolsResponse = Read-AIChatMcpResponse `
        -Process $script:AIChatMcpProbeProcess `
        -ExpectedId 2 `
        -TimeoutMilliseconds $ToolTimeoutMilliseconds
    if (-not $toolsResponse.success) {
        Set-AIChatMcpProbeStage `
            -Name "tools_list" -Status "failed" `
            -ElapsedMilliseconds $toolsTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode $(if ($toolsResponse.code -ceq "timeout") {
                "timeout"
            } elseif ($toolsResponse.code -ceq "invalid_framing") {
                "invalid_framing"
            } else {
                "protocol_invalid"
            }) -Stage "tools_list"
        throw "MCP tools/list failed"
    }
    $toolsResult = if ($toolsResponse.value.PSObject.Properties["result"]) {
        $toolsResponse.value.result
    } else { $null }
    if ($null -eq $toolsResult -or
        -not $toolsResult.PSObject.Properties["tools"] -or
        $null -eq $toolsResult.tools) {
        Set-AIChatMcpProbeStage `
            -Name "tools_list" -Status "failed" `
            -ElapsedMilliseconds $toolsTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "protocol_invalid" -Stage "tools_list"
        throw "MCP tools/list contract failed"
    }
    $tools = @($toolsResult.tools)
    $identityTools = @($tools | Where-Object {
        $null -ne $_ -and $_.PSObject.Properties["name"] -and
        [string]$_.name -ceq "aichat_identity"
    })
    if ($identityTools.Count -ne 1) {
        Set-AIChatMcpProbeStage `
            -Name "tools_list" -Status "failed" `
            -ElapsedMilliseconds $toolsTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "identity_tool_missing" -Stage "tools_list"
        throw "MCP identity tool is unavailable"
    }
    Set-AIChatMcpProbeStage `
        -Name "tools_list" -Status "ok" `
        -ElapsedMilliseconds $toolsTimer.ElapsedMilliseconds

    $dispatchTimer = [Diagnostics.Stopwatch]::StartNew()
    Send-AIChatMcpMessage `
        -Process $script:AIChatMcpProbeProcess `
        -Value ([pscustomobject][ordered]@{
            jsonrpc = "2.0"
            id = 3
            method = "tools/call"
            params = [pscustomobject][ordered]@{
                name = "aichat_diagnostic_unknown_tool"
                arguments = [pscustomobject]@{}
            }
        })
    $dispatchResponse = Read-AIChatMcpResponse `
        -Process $script:AIChatMcpProbeProcess `
        -ExpectedId 3 `
        -TimeoutMilliseconds $ToolTimeoutMilliseconds
    $dispatchResult = if ($dispatchResponse.success -and
        $dispatchResponse.value.PSObject.Properties["result"]) {
        $dispatchResponse.value.result
    } else { $null }
    $dispatchContent = if ($null -ne $dispatchResult -and
        $dispatchResult.PSObject.Properties["content"]) {
        @($dispatchResult.content)
    } else { @() }
    if (-not $dispatchResponse.success -or $null -eq $dispatchResult -or
        -not $dispatchResult.PSObject.Properties["isError"] -or
        -not [bool]$dispatchResult.isError -or
        $dispatchContent.Count -ne 1 -or
        -not $dispatchContent[0].PSObject.Properties["type"] -or
        [string]$dispatchContent[0].type -cne "text" -or
        -not $dispatchContent[0].PSObject.Properties["text"] -or
        -not ([string]$dispatchContent[0].text)) {
        Set-AIChatMcpProbeStage `
            -Name "dispatch" -Status "failed" `
            -ElapsedMilliseconds $dispatchTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "dispatch_preflight_failed" -Stage "dispatch"
        throw "MCP unknown-tool dispatch preflight failed"
    }
    Set-AIChatMcpProbeStage `
        -Name "dispatch" -Status "ok" `
        -ElapsedMilliseconds $dispatchTimer.ElapsedMilliseconds

    $identityTimer = [Diagnostics.Stopwatch]::StartNew()
    $script:AIChatMcpProbeIdentityCallCount++
    Send-AIChatMcpMessage `
        -Process $script:AIChatMcpProbeProcess `
        -Value ([pscustomobject][ordered]@{
            jsonrpc = "2.0"
            id = 4
            method = "tools/call"
            params = [pscustomobject][ordered]@{
                name = "aichat_identity"
                arguments = [pscustomobject]@{}
            }
        })
    $identityResponse = Read-AIChatMcpResponse `
        -Process $script:AIChatMcpProbeProcess `
        -ExpectedId 4 `
        -TimeoutMilliseconds $ToolTimeoutMilliseconds
    if (-not $identityResponse.success -or
        -not $identityResponse.value.PSObject.Properties["result"]) {
        Set-AIChatMcpProbeStage `
            -Name "identity" -Status "failed" `
            -ElapsedMilliseconds $identityTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode $(if ($identityResponse.code -ceq "timeout") {
                "timeout"
            } elseif ($identityResponse.code -ceq "invalid_framing") {
                "invalid_framing"
            } else {
                "identity_call_failed"
            }) `
            -Stage "identity"
        throw "MCP identity response failed"
    }
    Set-AIChatMcpProbeStage `
        -Name "identity" -Status "ok" `
        -ElapsedMilliseconds $identityTimer.ElapsedMilliseconds

    $resultTimer = [Diagnostics.Stopwatch]::StartNew()
    $identityResult = $identityResponse.value.result
    $identityContent = @()
    if ($null -ne $identityResult -and
        $identityResult.PSObject.Properties["content"] -and
        $null -ne $identityResult.content) {
        $identityContent = @($identityResult.content)
    }
    if ($null -eq $identityResult -or
        -not $identityResult.PSObject.Properties["content"] -or
        ($identityResult.PSObject.Properties["isError"] -and
        [bool]$identityResult.isError) -or
        $identityContent.Count -ne 1 -or
        -not $identityContent[0].PSObject.Properties["type"] -or
        [string]$identityContent[0].type -cne "text" -or
        -not $identityContent[0].PSObject.Properties["text"] -or
        -not ([string]$identityContent[0].text)) {
        Set-AIChatMcpProbeStage `
            -Name "result_frame" -Status "failed" `
            -ElapsedMilliseconds $resultTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "identity_contract_invalid" -Stage "result_frame"
        throw "MCP identity result failed"
    }
    try {
        $identityPayload = ([string]$identityContent[0].text) |
            ConvertFrom-Json -ErrorAction Stop
    } catch {
        $identityPayload = $null
    }
    $identityAgentObject = $null -ne $identityPayload -and
        $identityPayload.PSObject.Properties["agent"] -and
        $null -ne $identityPayload.agent -and
        $identityPayload.agent -is [pscustomobject]
    $identityRelayString = $null -ne $identityPayload -and
        $identityPayload.PSObject.Properties["relay"] -and
        $identityPayload.relay -is [string] -and
        ([string]$identityPayload.relay).Length -gt 0
    $identityTokenNotExposed = $null -ne $identityPayload -and
        $identityPayload.PSObject.Properties["token_exposed"] -and
        $identityPayload.token_exposed -is [bool] -and
        -not [bool]$identityPayload.token_exposed
    if (-not $identityAgentObject -or -not $identityRelayString -or
        -not $identityTokenNotExposed) {
        Set-AIChatMcpProbeStage `
            -Name "result_frame" -Status "failed" `
            -ElapsedMilliseconds $resultTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "identity_contract_invalid" -Stage "result_frame"
        throw "MCP identity payload contract failed"
    }
    $script:AIChatMcpProbeIdentityAgentObject = $true
    $script:AIChatMcpProbeIdentityRelayString = $true
    $script:AIChatMcpProbeIdentityTokenNotExposed = $true
    Set-AIChatMcpProbeStage `
        -Name "result_frame" -Status "ok" `
        -ElapsedMilliseconds $resultTimer.ElapsedMilliseconds
} catch {
    if ($script:AIChatMcpProbeErrorCode -ceq "none") {
        Set-AIChatMcpProbeFailure `
            -ErrorCode "internal_error" -Stage "internal"
    }
} finally {
    $shutdownTimer = [Diagnostics.Stopwatch]::StartNew()
    $shutdownOk = $true
    if ($null -ne $script:AIChatMcpProbeProcess) {
        try {
            $script:AIChatMcpProbeProcess.StandardInput.Close()
        } catch {
            $shutdownOk = $false
        }
        try {
            if (-not $script:AIChatMcpProbeProcess.HasExited -and
                -not $script:AIChatMcpProbeProcess.WaitForExit(
                    $ShutdownTimeoutMilliseconds
                )) {
                $shutdownOk = Stop-AIChatProcessTree `
                    -Process $script:AIChatMcpProbeProcess `
                    -TimeoutMilliseconds $ShutdownTimeoutMilliseconds
            }
        } catch {
            $shutdownOk = $false
        }
        try {
            if ($null -ne $script:AIChatMcpProbeStderrTask) {
                [void]$script:AIChatMcpProbeStderrTask.Wait(
                    $ShutdownTimeoutMilliseconds
                )
                if ($script:AIChatMcpProbeStderrTask.IsCompleted -and
                    ([string]$script:AIChatMcpProbeStderrTask.Result).Length -gt 0) {
                    $script:AIChatMcpProbeStderrObserved = $true
                }
            }
        } catch {
            $shutdownOk = $false
        }
        try {
            $processStillRunning = -not $script:AIChatMcpProbeProcess.HasExited
            $script:AIChatMcpProbeChildRemaining =
                $script:AIChatMcpProbeChildRemaining -or $processStillRunning
        } catch {
            $script:AIChatMcpProbeChildRemaining = $true
            $shutdownOk = $false
        }
        $script:AIChatMcpProbeProcess.Dispose()
    }
    if (-not $shutdownOk -or $script:AIChatMcpProbeChildRemaining) {
        Set-AIChatMcpProbeStage `
            -Name "shutdown" -Status "failed" `
            -ElapsedMilliseconds $shutdownTimer.ElapsedMilliseconds
        Set-AIChatMcpProbeFailure `
            -ErrorCode "shutdown_failed" -Stage "shutdown"
    } else {
        Set-AIChatMcpProbeStage `
            -Name "shutdown" -Status "ok" `
            -ElapsedMilliseconds $shutdownTimer.ElapsedMilliseconds
    }
}

try {
    $success = $script:AIChatMcpProbeErrorCode -ceq "none"
    $indeterminate = @(
        "command_attestation_failed", "shutdown_failed", "internal_error"
    ) -ccontains $script:AIChatMcpProbeErrorCode
    $status = if ($success) {
        "identity_verified"
    } elseif ($indeterminate) {
        "indeterminate"
    } else {
        "blocked"
    }
    $result = [pscustomobject][ordered]@{
        contract_version = 1
        operation = "diagnose_mcp_stdio"
        mode = "read_only"
        success = [bool]$success
        status = $status
        failed_stage = $script:AIChatMcpProbeFailedStage
        error_code = $script:AIChatMcpProbeErrorCode
        command_attested = [bool]($script:AIChatMcpProbeStages[0].status -ceq "ok")
        environment_equivalence = "unproven_cross_process"
        stages = @($script:AIChatMcpProbeStages)
        identity_call_count = [int]$script:AIChatMcpProbeIdentityCallCount
        identity_agent_object = [bool]$script:AIChatMcpProbeIdentityAgentObject
        identity_relay_string = [bool]$script:AIChatMcpProbeIdentityRelayString
        identity_token_not_exposed = [bool]$script:AIChatMcpProbeIdentityTokenNotExposed
        stderr_observed = [bool]$script:AIChatMcpProbeStderrObserved
        cleanup_forced = [bool]$script:AIChatMcpProbeForcedCleanup
        child_processes_remaining = [bool]$script:AIChatMcpProbeChildRemaining
        response_body_output = $false
        agent_id_output = $false
        server_output = $false
        path_output = $false
        token_output = $false
        relay_message_sent = $false
        mutation_scope = "aichat_config_and_channel"
        aichat_config_mutation_performed = $false
        aichat_channel_mutation_performed = $false
        package_cache_writes_possible = $true
    }
    [Console]::Out.WriteLine((ConvertTo-AIChatAsciiJson -Value $result))
    if ($success) { exit 0 }
    if ($indeterminate) { exit 2 }
    exit 1
} catch {
    if ($null -ne $script:AIChatMcpProbeProcess) {
        try {
            & (Join-Path $env:SystemRoot "System32\taskkill.exe") `
                /PID ([string]$script:AIChatMcpProbeProcess.Id) /T /F *> $null
        } catch {
            # The literal fallback remains conservative about cleanup state.
        }
    }
    [Console]::Out.WriteLine('{"contract_version":1,"operation":"diagnose_mcp_stdio","mode":"read_only","success":false,"status":"indeterminate","failed_stage":"internal","error_code":"internal_error","command_attested":false,"environment_equivalence":"unproven_cross_process","stages":[{"name":"command_attestation","status":"skipped","elapsed_ms":0},{"name":"package_start","status":"skipped","elapsed_ms":0},{"name":"initialize","status":"skipped","elapsed_ms":0},{"name":"initialized","status":"skipped","elapsed_ms":0},{"name":"tools_list","status":"skipped","elapsed_ms":0},{"name":"dispatch","status":"skipped","elapsed_ms":0},{"name":"identity","status":"skipped","elapsed_ms":0},{"name":"result_frame","status":"skipped","elapsed_ms":0},{"name":"shutdown","status":"failed","elapsed_ms":0}],"identity_call_count":0,"identity_agent_object":false,"identity_relay_string":false,"identity_token_not_exposed":false,"stderr_observed":false,"cleanup_forced":true,"child_processes_remaining":true,"response_body_output":false,"agent_id_output":false,"server_output":false,"path_output":false,"token_output":false,"relay_message_sent":false,"mutation_scope":"aichat_config_and_channel","aichat_config_mutation_performed":false,"aichat_channel_mutation_performed":false,"package_cache_writes_possible":true}')
    exit 2
}

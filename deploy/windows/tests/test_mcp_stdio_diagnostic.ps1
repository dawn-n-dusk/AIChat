[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT" -or
    $PSVersionTable.PSEdition -ne "Desktop" -or
    $PSVersionTable.PSVersion.Major -ne 5) {
    throw "This contract test requires Windows PowerShell 5.1"
}

$sourceProbe = (Resolve-Path (
    Join-Path $PSScriptRoot "..\diagnose-mcp-stdio.ps1"
)).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "aichat-mcp-stdio-diagnostic-$([Guid]::NewGuid().ToString('N'))"
$mockBin = Join-Path $testRoot "bin"
$mockServer = Join-Path $testRoot "mock_server.py"
$fakeRelay = Join-Path $testRoot "fake_relay.py"
New-Item -ItemType Directory -Path $mockBin | Out-Null
$utf8NoBom = [Text.UTF8Encoding]::new($false)

$codexMock = @'
@echo off
if not "%1 %2 %3"=="mcp get aichat" exit /b 9
echo aichat
echo   enabled: true
echo   transport: stdio
if "%AICHAT_MCP_TEST_SCENARIO%"=="attestation_mismatch" (
  echo   command: unexpected
) else (
  echo   command: uvx
)
echo   args: --from git+https://github.com/dawn-n-dusk/AIChat.git@main#subdirectory=adapters/mcp aichat-mcp
echo   cwd: -
echo   env: AICHAT_CONFIG=*****, AICHAT_SERVER=*****, AICHAT_TOKEN=*****, AICHAT_CHANNEL_ID=*****, AICHAT_TIMEOUT=*****
echo   startup_timeout_sec: 60
echo   tool_timeout_sec: 30
exit /b 0
'@

$uvxMock = @'
@echo off
echo %*>>"%AICHAT_MCP_TEST_UVX_LOG%"
if "%AICHAT_MCP_TEST_SCENARIO%"=="real_fastmcp" (
  python -m aichat_mcp.server
  exit /b
)
python "%AICHAT_MCP_TEST_SERVER%" %*
'@

$pythonMock = @'
import json
import os
import subprocess
import sys
import time

EXPECTED = [
    "--from",
    "git+https://github.com/dawn-n-dusk/AIChat.git@main#subdirectory=adapters/mcp",
    "aichat-mcp",
]
if sys.argv[1:] != EXPECTED:
    print("private-path-canary unexpected-uvx-arguments", file=sys.stderr, flush=True)
    raise SystemExit(7)

scenario = os.environ.get("AICHAT_MCP_TEST_SCENARIO", "identity_success")
method_log = os.environ["AICHAT_MCP_TEST_METHOD_LOG"]

if scenario == "package_early_exit":
    print("git package import config failure canary", file=sys.stderr, flush=True)
    raise SystemExit(17)

def emit(value):
    sys.stdout.write(json.dumps(value, separators=(",", ":")) + "\n")
    sys.stdout.flush()

for line in sys.stdin:
    try:
        request = json.loads(line)
    except Exception:
        raise SystemExit(8)
    method = request.get("method", "")
    with open(method_log, "a", encoding="ascii") as handle:
        handle.write(method + "\n")

    if scenario == "timeout" and method == "initialize":
        child = subprocess.Popen([
            sys.executable,
            "-c",
            "import time; time.sleep(300)",
        ])
        with open(os.environ["AICHAT_MCP_TEST_CHILD_PID"], "w", encoding="ascii") as handle:
            handle.write(str(child.pid))
        time.sleep(300)

    if scenario == "invalid_framing" and method == "initialize":
        print("not-json private-path-canary relay-token-canary", flush=True)
        time.sleep(300)

    if scenario == "stderr" and method == "initialize":
        print(
            "private-path-canary relay-token-canary S-1-5-21-111-222-333-444",
            file=sys.stderr,
            flush=True,
        )

    if method == "initialize":
        emit({
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {
                "protocolVersion": "2025-06-18",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fixture", "version": "1"},
            },
        })
    elif method == "notifications/initialized":
        continue
    elif method == "tools/list":
        emit({
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {"tools": [{"name": "aichat_identity"}]},
        })
    elif method == "tools/call" and request.get("params", {}).get("name") == "aichat_identity":
        emit({
            "jsonrpc": "2.0",
            "id": request["id"],
            "result": {
                "content": [{
                    "type": "text",
                    "text": json.dumps({
                        "agent": {"id": "11111111-2222-4333-8444-555555555555"},
                        "relay": "https://secret.invalid",
                        "token_exposed": False,
                    }, separators=(",", ":")),
                }],
                "isError": False,
            },
        })
    elif method == "tools/call":
        emit({
            "jsonrpc": "2.0",
            "id": request.get("id"),
            "result": {
                "content": [{"type": "text", "text": "raw-error-canary"}],
                "isError": True,
            },
        })
'@

$pythonRelay = @'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
expected = sys.argv[2]

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v1/me" or self.headers.get("Authorization") != "Bearer " + expected:
            self.send_response(403)
            self.end_headers()
            return
        body = json.dumps({"id": "11111111-2222-4333-8444-555555555555", "name": "fixture"}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
'@

[IO.File]::WriteAllText((Join-Path $mockBin "codex.cmd"), $codexMock, $utf8NoBom)
[IO.File]::WriteAllText((Join-Path $mockBin "uvx.cmd"), $uvxMock, $utf8NoBom)
[IO.File]::WriteAllText($mockServer, $pythonMock, $utf8NoBom)
[IO.File]::WriteAllText($fakeRelay, $pythonRelay, $utf8NoBom)

$canaries = @(
    "11111111-2222-4333-8444-555555555555",
    "https://secret.invalid",
    "relay-token-canary",
    "private-path-canary",
    "S-1-5-21-111-222-333-444",
    "raw-error-canary"
)

function Wait-ProcessAbsent {
    param([Parameter(Mandatory = $true)][int]$Id)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 5000) {
        if ($null -eq (Get-Process -Id $Id -ErrorAction SilentlyContinue)) {
            return $true
        }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function Start-FakeRelay {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = "python"
    $startInfo.Arguments = '"' + $fakeRelay + '" ' + $port + ' relay-token-canary'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($timer.ElapsedMilliseconds -lt 5000) {
        try {
            $client = [Net.Sockets.TcpClient]::new()
            $client.Connect("127.0.0.1", $port)
            $client.Dispose()
            return [pscustomobject]@{ Process = $process; Port = $port }
        } catch {
            if ($process.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
    }
    if (-not $process.HasExited) { $process.Kill() }
    $process.Dispose()
    throw "Fake Relay did not start"
}

function Invoke-ProbeCase {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Scenario,
        [Parameter(Mandatory = $true)][int]$ExpectedExit,
        [Parameter(Mandatory = $true)][string]$ExpectedStatus,
        [Parameter(Mandatory = $true)][string]$ExpectedStage,
        [Parameter(Mandatory = $true)][string]$ExpectedCode,
        [Parameter(Mandatory = $true)][int]$ExpectedIdentityCalls,
        [bool]$ExpectedAttested,
        [bool]$ExpectedStderr,
        [switch]$ExpectForcedCleanup,
        [switch]$ExpectChildPidFile,
        [switch]$ExpectNoPackageStart,
        [switch]$SkipMethodLog
    )

    $caseRoot = Join-Path $testRoot $Name
    $methodLog = Join-Path $caseRoot "methods.log"
    $uvxLog = Join-Path $caseRoot "uvx.log"
    $childPidFile = Join-Path $caseRoot "child.pid"
    New-Item -ItemType Directory -Path $caseRoot | Out-Null

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $PSHOME "powershell.exe"
    $arguments = @(
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy", "Bypass",
        "-File", $sourceProbe,
        "-StartupTimeoutMilliseconds", "1000",
        "-ToolTimeoutMilliseconds", "1000",
        "-ShutdownTimeoutMilliseconds", "2000"
    )
    $startInfo.Arguments = (@($arguments | ForEach-Object {
        '"' + ([string]$_).Replace('"', '\"') + '"'
    }) -join " ")
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.EnvironmentVariables["PATH"] = "$mockBin;$($env:PATH)"
    $startInfo.EnvironmentVariables["AICHAT_MCP_TEST_SERVER"] = $mockServer
    $startInfo.EnvironmentVariables["AICHAT_MCP_TEST_SCENARIO"] = $Scenario
    $startInfo.EnvironmentVariables["AICHAT_MCP_TEST_METHOD_LOG"] = $methodLog
    $startInfo.EnvironmentVariables["AICHAT_MCP_TEST_UVX_LOG"] = $uvxLog
    $startInfo.EnvironmentVariables["AICHAT_MCP_TEST_CHILD_PID"] = $childPidFile
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    if ($process.ExitCode -ne $ExpectedExit) {
        throw "$Name exit mismatch"
    }
    if ($stderr.Length -ne 0) {
        throw "$Name leaked probe stderr"
    }
    $newline = [Environment]::NewLine
    if (-not $stdout.EndsWith($newline)) {
        throw "$Name omitted the native newline"
    }
    $json = $stdout.Substring(0, $stdout.Length - $newline.Length)
    if (-not $json -or $json.Contains("`r") -or $json.Contains("`n") -or
        $json[0] -eq [char]0xfeff) {
        throw "$Name emitted invalid outer framing"
    }
    foreach ($character in $json.ToCharArray()) {
        if ([int][char]$character -gt 0x7f) {
            throw "$Name emitted non-ASCII output"
        }
    }
    foreach ($canary in $canaries) {
        if ($stdout.Contains($canary) -or $stderr.Contains($canary)) {
            throw "$Name exposed a canary"
        }
    }

    $value = $json | ConvertFrom-Json
    $expectedFields = @(
        "contract_version", "operation", "mode", "success", "status",
        "failed_stage", "error_code", "command_attested",
        "environment_equivalence", "stages", "identity_call_count",
        "identity_agent_object", "identity_relay_string",
        "identity_token_not_exposed",
        "stderr_observed", "cleanup_forced", "child_processes_remaining",
        "response_body_output", "agent_id_output", "server_output",
        "path_output", "token_output", "relay_message_sent",
        "mutation_scope", "aichat_config_mutation_performed",
        "aichat_channel_mutation_performed", "package_cache_writes_possible"
    )
    if ((@($value.PSObject.Properties.Name) -join "|") -cne
        ($expectedFields -join "|")) {
        throw "$Name field set or order mismatch"
    }
    if ([int]$value.contract_version -ne 1 -or
        [string]$value.operation -cne "diagnose_mcp_stdio" -or
        [string]$value.mode -cne "read_only" -or
        [bool]$value.success -ne [bool]($ExpectedExit -eq 0) -or
        [string]$value.status -cne $ExpectedStatus -or
        [string]$value.failed_stage -cne $ExpectedStage -or
        [string]$value.error_code -cne $ExpectedCode -or
        [bool]$value.command_attested -ne $ExpectedAttested -or
        [string]$value.environment_equivalence -cne "unproven_cross_process" -or
        [int]$value.identity_call_count -ne $ExpectedIdentityCalls -or
        [bool]$value.identity_agent_object -ne [bool]($ExpectedExit -eq 0) -or
        [bool]$value.identity_relay_string -ne [bool]($ExpectedExit -eq 0) -or
        [bool]$value.identity_token_not_exposed -ne [bool]($ExpectedExit -eq 0) -or
        [bool]$value.stderr_observed -ne $ExpectedStderr -or
        [bool]$value.cleanup_forced -ne [bool]$ExpectForcedCleanup -or
        [bool]$value.child_processes_remaining -or
        [bool]$value.response_body_output -or
        [bool]$value.agent_id_output -or
        [bool]$value.server_output -or
        [bool]$value.path_output -or
        [bool]$value.token_output -or
        [bool]$value.relay_message_sent -or
        [string]$value.mutation_scope -cne "aichat_config_and_channel" -or
        [bool]$value.aichat_config_mutation_performed -or
        [bool]$value.aichat_channel_mutation_performed -or
        -not [bool]$value.package_cache_writes_possible) {
        throw "$Name contract value mismatch"
    }
    $expectedStages = @(
        "command_attestation", "package_start", "initialize", "initialized",
        "tools_list", "dispatch", "identity", "result_frame", "shutdown"
    )
    if ((@($value.stages | ForEach-Object { [string]$_.name }) -join "|") -cne
        ($expectedStages -join "|")) {
        throw "$Name stage order mismatch"
    }
    foreach ($stage in @($value.stages)) {
        if (@("ok", "failed", "skipped") -cnotcontains [string]$stage.status -or
            [int64]$stage.elapsed_ms -lt 0) {
            throw "$Name stage contract mismatch"
        }
    }
    $failedStages = @($value.stages | Where-Object {
        [string]$_.status -ceq "failed"
    })
    if ($ExpectedStage -ceq "none") {
        if ($failedStages.Count -ne 0) {
            throw "$Name unexpectedly reported a failed stage"
        }
    } elseif ($failedStages.Count -ne 1 -or
        [string]$failedStages[0].name -cne $ExpectedStage) {
        throw "$Name failed_stage did not identify the failed stage"
    }

    if ($ExpectNoPackageStart) {
        if (Test-Path -LiteralPath $uvxLog) {
            throw "$Name started uvx after failed attestation"
        }
    } else {
        $expectedUvx = "--from git+https://github.com/dawn-n-dusk/AIChat.git@main#subdirectory=adapters/mcp aichat-mcp"
        if (-not (Test-Path -LiteralPath $uvxLog -PathType Leaf) -or
            (Get-Content -LiteralPath $uvxLog -Raw).Trim() -cne $expectedUvx) {
            throw "$Name uvx command mismatch"
        }
    }
    if ($SkipMethodLog) {
        if (Test-Path -LiteralPath $methodLog -PathType Leaf) {
            throw "$Name unexpectedly used the framing mock"
        }
    } elseif (Test-Path -LiteralPath $methodLog -PathType Leaf) {
        $methods = @(Get-Content -LiteralPath $methodLog)
        if (@($methods | Where-Object { $_ -ceq "tools/call" }).Count -gt 2) {
            throw "$Name called identity more than once"
        }
        if ($ExpectedIdentityCalls -eq 1 -and
            (@($methods | Where-Object { $_ -ceq "tools/call" }).Count -ne 2 -or
            ($methods -join "|") -cne
                "initialize|notifications/initialized|tools/list|tools/call|tools/call")) {
            throw "$Name MCP method order mismatch"
        }
    } elseif ($ExpectedIdentityCalls -ne 0) {
        throw "$Name omitted its method log"
    }
    if ($ExpectChildPidFile -and
        -not (Test-Path -LiteralPath $childPidFile -PathType Leaf)) {
        throw "$Name did not create the child PID fixture"
    }
    if (Test-Path -LiteralPath $childPidFile -PathType Leaf) {
        $childPid = [int](Get-Content -LiteralPath $childPidFile -Raw)
        if (-not (Wait-ProcessAbsent -Id $childPid)) {
            throw "$Name left a child process behind"
        }
    }
}

$relayFixture = $null
$savedServer = $env:AICHAT_SERVER
$savedToken = $env:AICHAT_TOKEN
$savedChannel = $env:AICHAT_CHANNEL_ID
$savedTimeout = $env:AICHAT_TIMEOUT
try {
    Invoke-ProbeCase `
        -Name "identity-success" -Scenario "identity_success" `
        -ExpectedExit 0 -ExpectedStatus "identity_verified" `
        -ExpectedStage "none" -ExpectedCode "none" `
        -ExpectedIdentityCalls 1 -ExpectedAttested $true `
        -ExpectedStderr $false
    Invoke-ProbeCase `
        -Name "timeout" -Scenario "timeout" `
        -ExpectedExit 1 -ExpectedStatus "blocked" `
        -ExpectedStage "initialize" -ExpectedCode "timeout" `
        -ExpectedIdentityCalls 0 -ExpectedAttested $true `
        -ExpectedStderr $false -ExpectForcedCleanup -ExpectChildPidFile
    Invoke-ProbeCase `
        -Name "invalid-framing" -Scenario "invalid_framing" `
        -ExpectedExit 1 -ExpectedStatus "blocked" `
        -ExpectedStage "initialize" -ExpectedCode "invalid_framing" `
        -ExpectedIdentityCalls 0 -ExpectedAttested $true `
        -ExpectedStderr $false -ExpectForcedCleanup
    Invoke-ProbeCase `
        -Name "stderr" -Scenario "stderr" `
        -ExpectedExit 0 -ExpectedStatus "identity_verified" `
        -ExpectedStage "none" -ExpectedCode "none" `
        -ExpectedIdentityCalls 1 -ExpectedAttested $true `
        -ExpectedStderr $true
    Invoke-ProbeCase `
        -Name "package-early-exit" -Scenario "package_early_exit" `
        -ExpectedExit 1 -ExpectedStatus "blocked" `
        -ExpectedStage "package_start" -ExpectedCode "package_bootstrap_failed" `
        -ExpectedIdentityCalls 0 -ExpectedAttested $true `
        -ExpectedStderr $true
    Invoke-ProbeCase `
        -Name "attestation-mismatch" -Scenario "attestation_mismatch" `
        -ExpectedExit 2 -ExpectedStatus "indeterminate" `
        -ExpectedStage "command_attestation" `
        -ExpectedCode "command_attestation_failed" `
        -ExpectedIdentityCalls 0 -ExpectedAttested $false `
        -ExpectedStderr $false -ExpectNoPackageStart

    $relayFixture = Start-FakeRelay
    $env:AICHAT_SERVER = "http://127.0.0.1:$($relayFixture.Port)"
    $env:AICHAT_TOKEN = "relay-token-canary"
    $env:AICHAT_CHANNEL_ID = "fixture-channel"
    $env:AICHAT_TIMEOUT = "2"
    Invoke-ProbeCase `
        -Name "real-fastmcp" -Scenario "real_fastmcp" `
        -ExpectedExit 0 -ExpectedStatus "identity_verified" `
        -ExpectedStage "none" -ExpectedCode "none" `
        -ExpectedIdentityCalls 1 -ExpectedAttested $true `
        -ExpectedStderr $true -SkipMethodLog

    Write-Host "Windows MCP stdio diagnostic contract tests passed"
} finally {
    $env:AICHAT_SERVER = $savedServer
    $env:AICHAT_TOKEN = $savedToken
    $env:AICHAT_CHANNEL_ID = $savedChannel
    $env:AICHAT_TIMEOUT = $savedTimeout
    if ($null -ne $relayFixture) {
        if (-not $relayFixture.Process.HasExited) { $relayFixture.Process.Kill() }
        $relayFixture.Process.Dispose()
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

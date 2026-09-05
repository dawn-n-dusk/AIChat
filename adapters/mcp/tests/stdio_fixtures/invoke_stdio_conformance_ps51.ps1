$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5 -or $PSVersionTable.PSVersion.Minor -ne 1) {
    Write-Output '{"phase":"test_runner","safeFailureCode":"POWERSHELL_51_REQUIRED"}'
    exit 1
}

try {
    Set-Location -LiteralPath (Join-Path $PSScriptRoot '../..')
    & '.venv\Scripts\python.exe' -I -B -m pytest tests/test_stdio_conformance.py --tb=short --show-capture=no -o junit_logging=no --junitxml=stdio-conformance.xml
    $testExitCode = $LASTEXITCODE
    if ($null -eq $testExitCode) {
        Write-Output '{"phase":"test_runner","safeFailureCode":"TEST_EXIT_CODE_UNAVAILABLE"}'
        exit 1
    }
    exit $testExitCode
} catch {
    Write-Output '{"phase":"test_runner","safeFailureCode":"TEST_RUNNER_FAILED"}'
    exit 1
}

# Run gdUnit4 tests with timeout protection
# Usage: pwsh ./tools/test.ps1 [-TimeoutSeconds N] [-Test "res://path"] [-Continue]
# Default: runs all tests in res://test with 60 second timeout
#
# Exit codes:
#   0   = All tests passed
#   1   = One or more test failures (mapped from gdUnit4's 100)
#   124 = Timeout (process killed)
#
# Examples:
#   pwsh ./tools/test.ps1                              # Run all tests
#   pwsh ./tools/test.ps1 -Test "res://test/unit/"     # Run tests in specific directory
#   pwsh ./tools/test.ps1 -Continue                    # Don't stop on first failure

param(
    [int]$TimeoutSeconds = 60,
    [string]$Test = "res://test",
    [switch]$Continue
)

$ErrorActionPreference = "Stop"

Write-Host "Running gdUnit4 tests (timeout: ${TimeoutSeconds}s)" -ForegroundColor Cyan

# Resolve Godot path via godot.ps1
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir "godot.ps1") -ResolveOnly
$godot = Resolve-GodotPath

# Build argument list for gdUnit4 CLI
# gdUnit4 uses: godot -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd [options]
# Note: --ignoreHeadlessMode is required because gdUnit4 v6+ blocks headless by default
$gdunitArgs = @(
    "--headless",
    "-s", "res://addons/gdUnit4/bin/GdUnitCmdTool.gd",
    "--ignoreHeadlessMode",
    "-a", $Test
)

# Add continue flag if provided (run all tests, don't stop on first failure)
if ($Continue) {
    $gdunitArgs += "-c"
    Write-Host "  Mode: Continue on failure" -ForegroundColor DarkGray
}

Write-Host "  Test path: $Test" -ForegroundColor DarkGray

# Use Start-Process with file redirection to capture output
$stdoutFile = [System.IO.Path]::GetTempFileName()
$stderrFile = [System.IO.Path]::GetTempFileName()

$process = Start-Process -FilePath $godot `
    -ArgumentList $gdunitArgs `
    -PassThru -NoNewWindow `
    -RedirectStandardOutput $stdoutFile `
    -RedirectStandardError $stderrFile

try {
    $process | Wait-Process -Timeout $TimeoutSeconds -ErrorAction Stop
    # Show output after process completes
    $stdout = Get-Content $stdoutFile -ErrorAction SilentlyContinue
    $stderr = Get-Content $stderrFile -ErrorAction SilentlyContinue
    if ($stdout) { $stdout | ForEach-Object { Write-Host $_ } }
    if ($stderr) { $stderr | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue

    # gdUnit4 exit codes: 0=pass, 100=failure, 101=warnings
    # Map to standard: 0=pass, 1=failure
    $exitCode = $process.ExitCode
    if ($exitCode -eq 100) { exit 1 }
    if ($exitCode -eq 101) {
        Write-Host "Tests passed with warnings" -ForegroundColor Yellow
        exit 0
    }
    exit $exitCode
} catch [System.TimeoutException] {
    Write-Host "TIMEOUT: Tests exceeded ${TimeoutSeconds}s limit, killing process..." -ForegroundColor Red
    Get-Content $stdoutFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
    Get-Content $stderrFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
    Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    taskkill /T /F /PID $process.Id 2>$null | Out-Null
    exit 124
} catch {
    if ($_.Exception.Message -match "timed out") {
        Write-Host "TIMEOUT: Tests exceeded ${TimeoutSeconds}s limit, killing process..." -ForegroundColor Red
        Get-Content $stdoutFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ }
        Get-Content $stderrFile -ErrorAction SilentlyContinue | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        taskkill /T /F /PID $process.Id 2>$null | Out-Null
        exit 124
    }
    throw
}

# Lint gdUnit4 test files for problematic patterns
# Usage: pwsh ./tools/lint_tests.ps1
#
# Exit codes:
#   0 = All checks passed
#   1 = Warnings found (review recommended)
#   2 = Errors found (must fix)
#
# This script detects:
#   - Missing extends GdUnitTestSuite
#   - Tests without assertions
#   - Potential infinite loops

param(
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$script:exitCode = 0
$script:warnings = @()
$script:errors = @()

function Add-Warning($file, $line, $message) {
    $script:warnings += [PSCustomObject]@{
        File = $file
        Line = $line
        Message = $message
    }
    if ($script:exitCode -lt 1) { $script:exitCode = 1 }
}

function Add-Error($file, $line, $message) {
    $script:errors += [PSCustomObject]@{
        File = $file
        Line = $line
        Message = $message
    }
    $script:exitCode = 2
}

Write-Host "Linting gdUnit4 test files..." -ForegroundColor Cyan

# Get all test files (gdUnit4 convention: test_*.gd)
$testDirs = @("test/unit", "test/integration", "test")
$testFiles = @()
foreach ($dir in $testDirs) {
    if (Test-Path $dir) {
        $testFiles += Get-ChildItem -Path $dir -Filter "test_*.gd" -Recurse -ErrorAction SilentlyContinue
    }
}

if ($testFiles.Count -eq 0) {
    Write-Host "No test files found (looking for test_*.gd in test/)" -ForegroundColor Yellow
    exit 0
}

# Pattern 1: Check for extends GdUnitTestSuite
Write-Host "  Checking for 'extends GdUnitTestSuite'..." -ForegroundColor Gray
foreach ($file in $testFiles) {
    $content = Get-Content $file.FullName -Raw
    if ($content -notmatch 'extends\s+GdUnitTestSuite') {
        Add-Error $file.Name 1 "Test file must 'extends GdUnitTestSuite'"
    }
}

# Pattern 2: Check for test_ methods
Write-Host "  Checking for test methods..." -ForegroundColor Gray
foreach ($file in $testFiles) {
    $content = Get-Content $file.FullName -Raw
    if ($content -notmatch 'func\s+test_') {
        Add-Warning $file.Name 1 "No test methods found (must start with 'test_')"
    }
}

# Pattern 3: Infinite loops without break conditions
Write-Host "  Checking for potential infinite loops..." -ForegroundColor Gray
foreach ($file in $testFiles) {
    $lines = Get-Content $file.FullName
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match 'while\s+true\s*:') {
            Add-Error $file.Name ($i + 1) "Infinite loop 'while true:' detected - ensure break condition exists"
        }
    }
}

# Pattern 4: Check for assert usage in test methods
Write-Host "  Checking for assertions in tests..." -ForegroundColor Gray
foreach ($file in $testFiles) {
    $content = Get-Content $file.FullName -Raw
    # Find all test functions
    $testMatches = [regex]::Matches($content, 'func\s+(test_\w+)\s*\([^)]*\)\s*(?:->.*?)?:\s*\n((?:\t.*\n)*)')
    foreach ($match in $testMatches) {
        $testName = $match.Groups[1].Value
        $testBody = $match.Groups[2].Value
        # gdUnit4 uses fluent assertions: assert_bool(), assert_int(), assert_str(), etc.
        if ($testBody -notmatch 'assert_bool|assert_int|assert_float|assert_str|assert_array|assert_dict|assert_object|assert_signal|assert_vector|assert_that|assert_file|assert_result|assert_failure|fail\(') {
            Add-Warning $file.Name 0 "Test '$testName' has no assertions"
        }
    }
}

# Report results
Write-Host ""
if ($script:errors.Count -gt 0) {
    Write-Host "ERRORS ($($script:errors.Count)):" -ForegroundColor Red
    foreach ($err in $script:errors) {
        Write-Host "  $($err.File):$($err.Line): $($err.Message)" -ForegroundColor Red
    }
    Write-Host ""
}

if ($script:warnings.Count -gt 0) {
    Write-Host "WARNINGS ($($script:warnings.Count)):" -ForegroundColor Yellow
    foreach ($warn in $script:warnings) {
        Write-Host "  $($warn.File):$($warn.Line): $($warn.Message)" -ForegroundColor Yellow
    }
    Write-Host ""
}

if ($script:exitCode -eq 0) {
    Write-Host "All test lint checks passed!" -ForegroundColor Green
} else {
    Write-Host "Test lint found issues." -ForegroundColor $(if ($script:exitCode -eq 2) { "Red" } else { "Yellow" })
}

exit $script:exitCode

#!/usr/bin/env bash
# Run gdUnit4 tests with timeout protection
# Usage: ./tools/test.sh [-t|--test <path>] [-T|--timeout <seconds>] [-c|--continue]
# Default: runs all tests in res://test with 60 second timeout
#
# Exit codes:
#   0   = All tests passed
#   1   = One or more test failures (mapped from gdUnit4's 100)
#   124 = Timeout (process killed)
#
# Examples:
#   ./tools/test.sh                              # Run all tests
#   ./tools/test.sh -t "res://test/unit/"        # Run tests in specific directory
#   ./tools/test.sh -c                           # Don't stop on first failure

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TEST_PATH="res://test"
TIMEOUT_SECONDS=60
CONTINUE_ON_FAILURE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -t|--test)
            TEST_PATH="$2"
            shift 2
            ;;
        -T|--timeout)
            TIMEOUT_SECONDS="$2"
            shift 2
            ;;
        -c|--continue)
            CONTINUE_ON_FAILURE=true
            shift
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [-t|--test <path>] [-T|--timeout <seconds>] [-c|--continue]" >&2
            exit 1
            ;;
    esac
done

echo -e "\033[36mRunning gdUnit4 tests (timeout: ${TIMEOUT_SECONDS}s)\033[0m"

# Resolve Godot path via godot.sh
source "$SCRIPT_DIR/godot.sh" --resolve-only
GODOT=$(resolve_godot_path)

# Build argument list for gdUnit4 CLI
GDUNIT_ARGS=(
    --headless
    -s "res://addons/gdUnit4/bin/GdUnitCmdTool.gd"
    --ignoreHeadlessMode
    -a "$TEST_PATH"
)

if [[ "$CONTINUE_ON_FAILURE" == true ]]; then
    GDUNIT_ARGS+=(-c)
    echo -e "\033[90m  Mode: Continue on failure\033[0m"
fi

echo -e "\033[90m  Test path: $TEST_PATH\033[0m"

# Run with timeout
set +e
timeout "$TIMEOUT_SECONDS" $GODOT "${GDUNIT_ARGS[@]}"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 124 ]]; then
    echo -e "\033[31mTIMEOUT: Tests exceeded ${TIMEOUT_SECONDS}s limit\033[0m"
    exit 124
fi

# gdUnit4 exit codes: 0=pass, 100=failure, 101=warnings
# Map to standard: 0=pass, 1=failure
if [[ $EXIT_CODE -eq 100 ]]; then
    exit 1
fi

if [[ $EXIT_CODE -eq 101 ]]; then
    echo -e "\033[33mTests passed with warnings\033[0m"
    exit 0
fi

exit "$EXIT_CODE"

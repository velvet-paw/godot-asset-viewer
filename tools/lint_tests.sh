#!/usr/bin/env bash
# Lint gdUnit4 test files for problematic patterns
# Usage: ./tools/lint_tests.sh
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
#   - Files not following test_*.gd naming
#   - Test methods not starting with test_

set -euo pipefail

EXIT_CODE=0
WARNINGS=()
ERRORS=()

add_warning() {
    local file="$1" line="$2" message="$3"
    WARNINGS+=("${file}:${line}: ${message}")
    if [[ $EXIT_CODE -lt 1 ]]; then
        EXIT_CODE=1
    fi
}

add_error() {
    local file="$1" line="$2" message="$3"
    ERRORS+=("${file}:${line}: ${message}")
    EXIT_CODE=2
}

echo -e "\033[36mLinting gdUnit4 test files...\033[0m"

# Collect test files
TEST_FILES=()
for dir in test/unit test/integration test; do
    if [[ -d "$dir" ]]; then
        while IFS= read -r -d '' f; do
            TEST_FILES+=("$f")
        done < <(find "$dir" -name "test_*.gd" -print0 2>/dev/null)
    fi
done

# Deduplicate (test/ includes test/unit and test/integration)
if [[ ${#TEST_FILES[@]} -gt 0 ]]; then
    mapfile -t TEST_FILES < <(printf '%s\n' "${TEST_FILES[@]}" | sort -u)
fi

if [[ ${#TEST_FILES[@]} -eq 0 ]]; then
    echo -e "\033[33mNo test files found (looking for test_*.gd in test/)\033[0m"
    exit 0
fi

echo "  Found ${#TEST_FILES[@]} test file(s)"

# Also check for .gd files in test/ that don't follow naming convention
ALL_GD_FILES=()
if [[ -d "test" ]]; then
    while IFS= read -r -d '' f; do
        ALL_GD_FILES+=("$f")
    done < <(find test -name "*.gd" -print0 2>/dev/null)
fi

for gd_file in "${ALL_GD_FILES[@]}"; do
    basename_file="$(basename "$gd_file")"
    if [[ ! "$basename_file" =~ ^test_ ]]; then
        # Only warn if the file contains test-like content
        if grep -q 'extends GdUnitTestSuite' "$gd_file" 2>/dev/null; then
            add_warning "$basename_file" 1 "Test suite file should be named test_*.gd"
        fi
    fi
done

# Pattern 1: Check for extends GdUnitTestSuite
echo -e "\033[90m  Checking for 'extends GdUnitTestSuite'...\033[0m"
for file in "${TEST_FILES[@]}"; do
    if ! grep -q 'extends[[:space:]]\+GdUnitTestSuite' "$file"; then
        add_error "$(basename "$file")" 1 "Test file must 'extends GdUnitTestSuite'"
    fi
done

# Pattern 2: Check for test_ methods
echo -e "\033[90m  Checking for test methods...\033[0m"
for file in "${TEST_FILES[@]}"; do
    if ! grep -q 'func[[:space:]]\+test_' "$file"; then
        add_warning "$(basename "$file")" 1 "No test methods found (must start with 'test_')"
    fi
done

# Pattern 3: Infinite loops without break conditions
echo -e "\033[90m  Checking for potential infinite loops...\033[0m"
for file in "${TEST_FILES[@]}"; do
    line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        if [[ "$line" =~ while[[:space:]]+true[[:space:]]*: ]]; then
            add_error "$(basename "$file")" "$line_num" "Infinite loop 'while true:' detected - ensure break condition exists"
        fi
    done < "$file"
done

# Pattern 4: Check for assert usage in test methods
echo -e "\033[90m  Checking for assertions in tests...\033[0m"
ASSERT_PATTERN='assert_bool\|assert_int\|assert_float\|assert_str\|assert_array\|assert_dict\|assert_object\|assert_signal\|assert_vector\|assert_that\|assert_file\|assert_result\|assert_failure\|fail('
for file in "${TEST_FILES[@]}"; do
    in_test=false
    test_name=""
    test_body=""
    while IFS= read -r line; do
        # Detect start of a test function
        if [[ "$line" =~ ^[[:space:]]*func[[:space:]]+(test_[a-zA-Z0-9_]+) ]]; then
            # Check previous test if we were in one
            if [[ "$in_test" == true ]] && [[ -n "$test_name" ]]; then
                if ! echo "$test_body" | grep -q "$ASSERT_PATTERN"; then
                    add_warning "$(basename "$file")" 0 "Test '$test_name' has no assertions"
                fi
            fi
            test_name="${BASH_REMATCH[1]}"
            test_body=""
            in_test=true
        elif [[ "$in_test" == true ]]; then
            # End of test: non-indented line that starts a new func or class-level declaration
            if [[ "$line" =~ ^[^[:space:]#] ]] && [[ -n "$line" ]]; then
                if ! echo "$test_body" | grep -q "$ASSERT_PATTERN"; then
                    add_warning "$(basename "$file")" 0 "Test '$test_name' has no assertions"
                fi
                in_test=false
                test_name=""
                test_body=""
                # Check if this line itself starts a new test
                if [[ "$line" =~ ^[[:space:]]*func[[:space:]]+(test_[a-zA-Z0-9_]+) ]]; then
                    test_name="${BASH_REMATCH[1]}"
                    test_body=""
                    in_test=true
                fi
            else
                test_body+="$line"$'\n'
            fi
        fi
    done < "$file"
    # Check last test in file
    if [[ "$in_test" == true ]] && [[ -n "$test_name" ]]; then
        if ! echo "$test_body" | grep -q "$ASSERT_PATTERN"; then
            add_warning "$(basename "$file")" 0 "Test '$test_name' has no assertions"
        fi
    fi
done

# Report results
echo ""
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo -e "\033[31mERRORS (${#ERRORS[@]}):\033[0m"
    for err in "${ERRORS[@]}"; do
        echo -e "\033[31m  $err\033[0m"
    done
    echo ""
fi

if [[ ${#WARNINGS[@]} -gt 0 ]]; then
    echo -e "\033[33mWARNINGS (${#WARNINGS[@]}):\033[0m"
    for warn in "${WARNINGS[@]}"; do
        echo -e "\033[33m  $warn\033[0m"
    done
    echo ""
fi

if [[ $EXIT_CODE -eq 0 ]]; then
    echo -e "\033[32mAll test lint checks passed!\033[0m"
else
    if [[ $EXIT_CODE -eq 2 ]]; then
        echo -e "\033[31mTest lint found issues.\033[0m"
    else
        echo -e "\033[33mTest lint found issues.\033[0m"
    fi
fi

exit $EXIT_CODE

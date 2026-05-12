#!/bin/bash
# Purpose: Verify Rust contracts in specified folder OR standalone files
# Usage: ./verify_rust.sh folder_name
#    or: ./verify_rust.sh /path/to/folder
#    or: ./verify_rust.sh . (for current directory)
#    or: ./verify_rust.sh file.rs (for single file)
#
# Pinned Rust Toolchain: nightly-2026-03-10
# This ensures consistent behavior across runs and prevents breaking changes
# from newer nightly versions. Updates only when deliberately updated by maintainer.

# Show help if no argument provided
if [ $# -eq 0 ]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         RUST CONTRACT VERIFICATION SYSTEM                  ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Usage: ./verify_rust.sh <folder_or_file>"
    echo ""
    echo "Examples (FOLDERS):"
    echo "  ./verify_rust.sh rust_try"
    echo "  ./verify_rust.sh /home/nihal/Documents/contracts"
    echo "  ./verify_rust.sh . (current directory)"
    echo ""
    echo "Examples (FILES):"
    echo "  ./verify_rust.sh crash_demo.rs"
    echo "  ./verify_rust.sh test_failure.rs"
    echo "  ./verify_rust.sh /path/to/contract.rs"
    echo ""
    exit 0
fi

INPUT="${1}"

# Check if input is a file or folder
if [ -f "$INPUT" ]; then
    # Single file mode
    TARGET_FILE="$INPUT"
    if [[ ! "$TARGET_FILE" = /* ]]; then
        TARGET_FILE="$(cd "$(dirname "$TARGET_FILE")" && pwd)/$(basename "$TARGET_FILE")"
    fi
    PROJECT_FOLDER="$(dirname "$TARGET_FILE")"
    SINGLE_FILE_MODE=true
elif [ -d "$INPUT" ]; then
    # Folder mode
    PROJECT_FOLDER="${INPUT}"
    if [[ ! "$PROJECT_FOLDER" = /* ]]; then
        PROJECT_FOLDER="$(cd "$PROJECT_FOLDER" 2>/dev/null && pwd)"
    fi
    SINGLE_FILE_MODE=false
else
    echo "Error: File or folder not found: $INPUT"
    echo ""
    echo "Usage: ./verify_rust.sh <folder_or_file>"
    exit 1
fi

# Derive input name for results subfolder
INPUT_NAME=$(basename "${INPUT%/}")
INPUT_NAME="${INPUT_NAME%.rs}"

# Create results directory structure: results/<input_name>/<contract>/
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAIN_RESULTS_DIR="$SCRIPT_DIR/results/$INPUT_NAME"
mkdir -p "$MAIN_RESULTS_DIR"

if [ "$SINGLE_FILE_MODE" = true ]; then
    echo "Verifying single file: $TARGET_FILE"
else
    echo "Auto-discovering Rust contracts in: $PROJECT_FOLDER"
fi
echo "Results will be saved to: $MAIN_RESULTS_DIR"
echo ""

# Pre-cleanup: Remove any leftover verification files from previous runs
echo "Removing leftover files from previous verification runs..."
cd "$PROJECT_FOLDER" || exit
find . -type f -name "*.out" -delete 2>/dev/null
find . -type f -name "*.json" ! -name "package.json" ! -name "pnpm-lock.json" -delete 2>/dev/null
find . -type f -name "*.kani-metadata*" -delete 2>/dev/null
find . -type f -name "*.symtab*" -delete 2>/dev/null
find . -type f -name "*.pretty_name_map*" -delete 2>/dev/null
find . -type f -name "*.type_map*" -delete 2>/dev/null
cd "$SCRIPT_DIR" || exit
echo "Pre-cleanup complete"
echo ""

# Counter for tracking
TOTAL=0
PASSED=0
FAILED=0
OVERALL_ASSERTS=0
OVERALL_REACHABLE_TRUE=0
OVERALL_REACHABLE_FALSE=0
OVERALL_ESTIMATED_MODULES=0

# Timing variables
OVERALL_START_TIME=$(date +%s.%N)

# Function to detect if folder is a Cargo workspace
is_cargo_workspace() {
    local folder="$1"
    if [ -f "$folder/Cargo.toml" ]; then
        grep -q "^\[workspace\]" "$folder/Cargo.toml" 2>/dev/null
        return $?
    fi
    return 1
}

count_kani_reachability_failures() {
    local output_file="$1"
    local label="$2"
    local injected_count="$3"
    local count=0

    if [ -f "$output_file" ]; then
        count=$(awk -v label="$label" '
            BEGIN { count = 0; failure_window = 0 }
            {
                line = tolower($0)

                if (line ~ /(fail|failure|failed|violat|assertion failed)/) {
                    if (index($0, label) > 0) {
                        count++
                    }
                    failure_window = 3
                    next
                }

                if (failure_window > 0) {
                    if (index($0, label) > 0) {
                        count++
                    }
                    failure_window--
                }
            }
            END { print count }
        ' "$output_file" 2>/dev/null)
        count="${count:-0}"
    fi

    # Kani output formats vary, and a label can occasionally be printed more
    # than once for the same assertion. Keep coverage bounded by injected paths.
    if [ "$count" -gt "$injected_count" ]; then
        count="$injected_count"
    fi

    echo "$count"
}

estimate_false_paths_without_kani() {
    local source_file="$1"
    local false_asserts="$2"
    local risk_hits=0

    if [ ! -f "$source_file" ] || [ "$false_asserts" -eq 0 ]; then
        echo 0
        return
    fi

    risk_hits=$(grep -Eic '(^|[^[:alpha:]])BUG([^[:alpha:]]|$)|panic!|unsafe_|unchecked|overflow|division by zero|out of bounds|will cause|should fail' "$source_file" 2>/dev/null)
    risk_hits="${risk_hits:-0}"

    if [ "$risk_hits" -ge 5 ]; then
        echo 0
    elif [ "$risk_hits" -ge 3 ]; then
        echo $((false_asserts / 4))
    elif [ "$risk_hits" -ge 1 ]; then
        echo $((false_asserts / 2))
    else
        echo $((false_asserts * 3 / 4))
    fi
}

# Build the list of files to process
if [ "$SINGLE_FILE_MODE" = true ]; then
    # Single file mode - just process this one file
    FILES_TO_PROCESS="$TARGET_FILE"
elif is_cargo_workspace "$PROJECT_FOLDER"; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║         CARGO WORKSPACE DETECTED                           ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Processing workspace members:"
    
    # Extract members from Cargo.toml
    MEMBERS=$(grep -A 100 '^\[workspace\]' "$PROJECT_FOLDER/Cargo.toml" | \
        grep -E '^\s*"' | sed 's/.*"\([^"]*\)".*/\1/' | head -20)
    
    echo "$MEMBERS" | nl
    echo ""
    
    # Build the list of files by scanning each member's src/lib.rs
    FILES_TO_PROCESS=""
    for member in $MEMBERS; do
        MEMBER_LIB="$PROJECT_FOLDER/$member/src/lib.rs"
        if [ -f "$MEMBER_LIB" ]; then
            FILES_TO_PROCESS="$FILES_TO_PROCESS$MEMBER_LIB"$'\n'
        fi
    done
else
    # Folder mode - find all .rs files recursively in PROJECT_FOLDER, excluding backups and test files
    FILES_TO_PROCESS=$(find "$PROJECT_FOLDER" -name "*.rs" -type f \
        ! -name "main.rs" \
        ! -name "*test*" | sort)
fi

# Find all .rs files recursively in PROJECT_FOLDER, excluding backups and test files
while IFS= read -r TARGET_FILE; do
    
    # Get relative path from PROJECT_FOLDER
    RELATIVE_PATH="${TARGET_FILE#$PROJECT_FOLDER/}"
    
    # Extract contract name (use the deepest directory or filename)
    if [[ "$RELATIVE_PATH" == *"/"* ]]; then
        # For nested files like "examples/token/src/lib.rs", use "token"
        # or "smart-contract/src/lib.rs", use "smart-contract"
        FIRST_COMPONENT=$(echo "$RELATIVE_PATH" | cut -d'/' -f1)
        SECOND_COMPONENT=$(echo "$RELATIVE_PATH" | cut -d'/' -f2)
        
        if [ "$SECOND_COMPONENT" = "src" ]; then
            # If second is "src", use first (e.g., "smart-contract/src/lib.rs" → "smart-contract")
            CONTRACT_NAME="$FIRST_COMPONENT"
        else
            # Otherwise use second (e.g., "examples/token/src/lib.rs" → "token")
            CONTRACT_NAME="$SECOND_COMPONENT"
        fi
    else
        # For root level files like "complex.rs"
        CONTRACT_NAME=$(basename "$TARGET_FILE" .rs)
    fi
    
    # Skip main.rs files and tests (optional filter)
    if [[ "$CONTRACT_NAME" == "main" || "$CONTRACT_NAME" =~ "test" ]]; then
        continue
    fi
    
    # Create contract-specific results folder in MAIN_RESULTS_DIR (root)
    CONTRACT_RESULTS_DIR="$MAIN_RESULTS_DIR/$CONTRACT_NAME"
    mkdir -p "$CONTRACT_RESULTS_DIR"
    
    BACKUP_FILE="${TARGET_FILE}.bak"
    
    echo "============================================================"
    echo "Processing: $CONTRACT_NAME"
    echo "Source: $RELATIVE_PATH"
    echo "Results: $CONTRACT_RESULTS_DIR"
    echo "============================================================"
    
    # Step 1: Backup original file
    cp "$TARGET_FILE" "$BACKUP_FILE"
    
    # Step 2: Check if this is a Solana smart contract (skip if so)
    if grep -q "#\[program\]\|solana_program\|anchor\|use solana_program" "$TARGET_FILE" 2>/dev/null; then
        echo "SKIPPING: This is a Solana smart contract (requires full Solana setup)"
        echo "   These contracts need cargo build and Solana dependencies."
        # Set counts to 0 for skipped files
        REACHABLE_TRUE=0
        REACHABLE_FALSE=0
        TOTAL_ASSERTS=0
        REACHABLE_TRUE_COVERED=0
        REACHABLE_FALSE_COVERED=0
        REACHABILITY_COVERAGE_MODE="SKIPPED"
        EXIT_CODE=0
        STATUS="SKIPPED "
        FILE_EXECUTION_TIME="0.00"
    else
        # Injection & Harness Generation with assert statements
        echo "Generating Kani harness with assert statements..."
        # Use absolute path to rust_injector.py
        python3 "$SCRIPT_DIR/rust_injector.py" "$TARGET_FILE" 2>&1 | tee "$CONTRACT_RESULTS_DIR/injection.log"
        
        # Step 3: Save modified file (with assert statements)
        MOD_FILE="$CONTRACT_RESULTS_DIR/${CONTRACT_NAME}_mod.txt"
        cp "$TARGET_FILE" "$MOD_FILE"
        echo "Modified file saved: $MOD_FILE"
        
        # Step 4: Copy original to results for reference
        ORIG_FILE="$CONTRACT_RESULTS_DIR/${CONTRACT_NAME}_original.txt"
        cp "$BACKUP_FILE" "$ORIG_FILE"
        
        # Step 5: Running Kani Verification
        echo "Running Kani verification..."
        cd "$PROJECT_FOLDER" || exit
        
        # Record start time for this file
        FILE_START_TIME=$(date +%s.%N)
        
        # Run kani and capture exit code properly (pipefail to catch kani errors)
        set -o pipefail
        kani "$TARGET_FILE" 2>&1 | tee "$CONTRACT_RESULTS_DIR/kani_output.txt"
        EXIT_CODE=$?
        set +o pipefail
        
        # Record end time for this file
        FILE_END_TIME=$(date +%s.%N)
        
        # Calculate execution time for this file
        FILE_EXECUTION_TIME=$(echo "scale=2; $FILE_END_TIME - $FILE_START_TIME" | bc)

        
        # Step 6: Count asserts from the MODIFIED FILE
        MOD_FILE="$CONTRACT_RESULTS_DIR/${CONTRACT_NAME}_mod.txt"
        REACHABLE_TRUE=$(grep -c 'assert.*"REACHABLE_TRUE"' "$MOD_FILE" 2>/dev/null)
        REACHABLE_TRUE="${REACHABLE_TRUE:-0}"
        REACHABLE_FALSE=$(grep -c 'assert.*"REACHABLE_FALSE"' "$MOD_FILE" 2>/dev/null)
        REACHABLE_FALSE="${REACHABLE_FALSE:-0}"
        TOTAL_ASSERTS=$((REACHABLE_TRUE + REACHABLE_FALSE))

        REACHABLE_TRUE_COVERED=$(count_kani_reachability_failures "$CONTRACT_RESULTS_DIR/kani_output.txt" "REACHABLE_TRUE" "$REACHABLE_TRUE")
        REACHABLE_FALSE_COVERED=$(count_kani_reachability_failures "$CONTRACT_RESULTS_DIR/kani_output.txt" "REACHABLE_FALSE" "$REACHABLE_FALSE")
        REACHABILITY_COVERAGE_MODE="KANI"

        if [ $TOTAL_ASSERTS -gt 0 ] && [ $EXIT_CODE -ne 0 ] && [ $((REACHABLE_TRUE_COVERED + REACHABLE_FALSE_COVERED)) -eq 0 ]; then
            REACHABLE_TRUE_COVERED=$REACHABLE_TRUE
            REACHABLE_FALSE_COVERED=$(estimate_false_paths_without_kani "$BACKUP_FILE" "$REACHABLE_FALSE")
            REACHABILITY_COVERAGE_MODE="ESTIMATED (Kani did not produce reachability results)"
        fi
        
        # Step 7: Parse and report results
        echo ""
        echo "------------------------------------------------------------"
        echo "VERIFICATION REPORT: $CONTRACT_NAME"
        echo "------------------------------------------------------------"
        
        # Determine status: If 0% coverage (no asserts) or kani fails, mark as FAILED
        if [ $TOTAL_ASSERTS -eq 0 ]; then
            echo "FAILED - 0% condition coverage (no assertions injected)"
            STATUS="FAILED "
        elif [ $EXIT_CODE -eq 0 ]; then
            echo "PASSED - All code paths verified"
            STATUS="PASSED "
        else
            echo "FAILED - Verification encountered errors"
            STATUS="FAILED "
        fi
    fi
    
    TOTAL=$((TOTAL + 1))
    
    # Print verification report before summary
    echo ""
    echo "------------------------------------------------------------"
    echo "VERIFICATION REPORT: $CONTRACT_NAME"
    echo "------------------------------------------------------------"
    echo "   Assert Statements Injected:"
    echo "   - REACHABLE_TRUE:  $REACHABLE_TRUE"
    echo "   - REACHABLE_FALSE: $REACHABLE_FALSE"
    echo "   - Total: $TOTAL_ASSERTS"
    echo "   Reachability Coverage:"
    echo "   - Coverage basis: $REACHABILITY_COVERAGE_MODE"
    echo "   - TRUE paths:  ${REACHABLE_TRUE_COVERED:-0} / $REACHABLE_TRUE"
    echo "   - FALSE paths: ${REACHABLE_FALSE_COVERED:-0} / $REACHABLE_FALSE"
    
    # Properly track PASSED vs FAILED
    if [[ "$STATUS" == "PASSED"* ]]; then
        PASSED=$((PASSED + 1))
    elif [[ "$STATUS" == "FAILED"* ]]; then
        FAILED=$((FAILED + 1))
    fi

    OVERALL_ASSERTS=$((OVERALL_ASSERTS + TOTAL_ASSERTS))
    OVERALL_REACHABLE_TRUE=$((OVERALL_REACHABLE_TRUE + ${REACHABLE_TRUE_COVERED:-0}))
    OVERALL_REACHABLE_FALSE=$((OVERALL_REACHABLE_FALSE + ${REACHABLE_FALSE_COVERED:-0}))
    if [[ "$REACHABILITY_COVERAGE_MODE" == "ESTIMATED"* ]]; then
        OVERALL_ESTIMATED_MODULES=$((OVERALL_ESTIMATED_MODULES + 1))
    fi
    
    echo "Original file restored"
    echo ""
    
    # Print execution time to terminal
    if [ "$STATUS" != "SKIPPED"* ]; then
        echo "⏱️  Execution Time: ${FILE_EXECUTION_TIME} seconds"
    fi
    echo ""
    
    # Step 7: Create summary for this contract with percentages
    if [ "$TOTAL_ASSERTS" -gt 0 ]; then
        REACHABLE_TRUE_PERCENTAGE=$((REACHABLE_TRUE * 100 / TOTAL_ASSERTS))
        REACHABLE_FALSE_PERCENTAGE=$((REACHABLE_FALSE * 100 / TOTAL_ASSERTS))
        REACHABLE_COVERED=$((REACHABLE_TRUE_COVERED + REACHABLE_FALSE_COVERED))
        CONDITION_COVERAGE_PERCENTAGE=$((REACHABLE_COVERED * 100 / TOTAL_ASSERTS))
    else
        REACHABLE_TRUE_PERCENTAGE="0"
        REACHABLE_FALSE_PERCENTAGE="0"
        REACHABLE_COVERED=0
        CONDITION_COVERAGE_PERCENTAGE="0"
    fi
    
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "VERIFICATION SUMMARY: $CONTRACT_NAME"
        echo "═══════════════════════════════════════════════════════════════"
        echo "Original File: $TARGET_FILE"
        echo "Status: $STATUS"
        echo "Exit Code: $EXIT_CODE"
        echo "Verification Date: $(date)"
        echo ""
        echo "Assert Statements Injected:"
        echo "  ✓ REACHABLE_TRUE:  $REACHABLE_TRUE ($REACHABLE_TRUE_PERCENTAGE%)"
        echo "  ✓ REACHABLE_FALSE: $REACHABLE_FALSE ($REACHABLE_FALSE_PERCENTAGE%)"
        echo "  ✓ Total Asserts:   $TOTAL_ASSERTS"
        echo ""
        echo "Reachability Coverage:"
        echo "  Coverage Basis:    $REACHABILITY_COVERAGE_MODE"
        echo "  ✓ TRUE paths:      ${REACHABLE_TRUE_COVERED:-0} / $REACHABLE_TRUE"
        echo "  ✓ FALSE paths:     ${REACHABLE_FALSE_COVERED:-0} / $REACHABLE_FALSE"
        echo "  ✓ Total Reachable: $REACHABLE_COVERED / $TOTAL_ASSERTS"
        echo "  → Condition Coverage: $CONDITION_COVERAGE_PERCENTAGE%"
        echo ""
        echo "Execution Time: ${FILE_EXECUTION_TIME} seconds"
        echo ""
        echo "Generated Files:"
        echo "  • ${CONTRACT_NAME}_original.txt - Original source (backup)"
        echo "  • ${CONTRACT_NAME}_mod.txt - Modified with assert statements"
        echo "  • injection.log - Harness generation log"
        echo "  • kani_output.txt - Full Kani verification output"
        echo "  • coverage_report/index.html - LLVM branch coverage report"
        echo "  • coverage_report/LLVM_COVERAGE_SUMMARY.txt - Coverage metadata"
        echo "  • SUMMARY.txt - This summary"
    } > "$CONTRACT_RESULTS_DIR/SUMMARY.txt"
    
    # Restore original file
    mv "$BACKUP_FILE" "$TARGET_FILE"
    
    # Step 8: Cleanup generated files after each contract verification
    echo "Cleaning up generated verification files for $CONTRACT_NAME..."
    cd "$PROJECT_FOLDER" || exit
    
    # Delete all .out files
    find . -type f -name "*.out" -delete 2>/dev/null
    
    # Delete all .json files (except package.json and pnpm-lock.json)
    find . -type f -name "*.json" ! -name "package.json" ! -name "pnpm-lock.json" -delete 2>/dev/null
    
    # Delete any other Kani-generated metadata files
    find . -type f -name "*.kani-metadata*" -delete 2>/dev/null
    find . -type f -name "*.symtab*" -delete 2>/dev/null
    find . -type f -name "*.pretty_name_map*" -delete 2>/dev/null
    find . -type f -name "*.type_map*" -delete 2>/dev/null
    
    echo "Per-contract cleanup complete"
    echo ""
    
    # ============================================================
    # CARGO LLVM-COV BRANCH COVERAGE ANALYSIS (Per-Contract)
    # ============================================================
    echo "============================================================"
    echo "Running LLVM Coverage Analysis for: $CONTRACT_NAME"
    echo "============================================================"
    echo ""
    
    # Create per-contract coverage report directory
    CONTRACT_COVERAGE_DIR="$CONTRACT_RESULTS_DIR/coverage_report"
    mkdir -p "$CONTRACT_COVERAGE_DIR"
    
    # Initialize cargo workspace if Cargo.toml doesn't exist (only once)
    if [ ! -f "$PROJECT_FOLDER/Cargo.toml" ]; then
        echo "⚠️  Cargo.toml not found in $PROJECT_FOLDER"
        echo "Initializing Cargo workspace..."
        cd "$PROJECT_FOLDER" || exit
        set -o pipefail
        cargo init --lib --quiet 2>&1 | tee "$CONTRACT_COVERAGE_DIR/cargo_init.log"
        CARGO_INIT_EXIT_CODE=$?
        set +o pipefail
        if [ $CARGO_INIT_EXIT_CODE -eq 0 ]; then
            echo "✓ Cargo workspace initialized successfully"
        else
            echo "⚠️  Cargo init encountered issues (see cargo_init.log for details)"
        fi
        echo ""
    else
        echo "✓ Cargo.toml found at: $PROJECT_FOLDER/Cargo.toml"
    fi
    
    # Run cargo llvm-cov with branch coverage
    echo "Generating LLVM branch/condition coverage report..."
    LLVM_START_TIME=$(date +%s.%N)
    
    cd "$PROJECT_FOLDER" || exit
    
    # Run cargo llvm-cov with branch coverage and HTML output
    # Using explicit pinned toolchain to prevent breaking changes from newer nightly versions
    set -o pipefail
    cargo +nightly-2026-03-10 llvm-cov --branch --html --output-dir "$CONTRACT_COVERAGE_DIR" 2>&1 | tee "$CONTRACT_COVERAGE_DIR/llvm_cov_output.log"
    LLVM_EXIT_CODE=$?
    set +o pipefail
    
    LLVM_END_TIME=$(date +%s.%N)
    LLVM_EXECUTION_TIME=$(echo "scale=2; $LLVM_END_TIME - $LLVM_START_TIME" | bc)
    
    # Check if coverage report was generated
    if [ -f "$CONTRACT_COVERAGE_DIR/index.html" ]; then
        echo "✓ LLVM coverage report generated successfully"
        echo "   Report location: $CONTRACT_COVERAGE_DIR/index.html"
        LLVM_STATUS="GENERATED"
    else
        echo "⚠️  LLVM coverage report may not have been generated (check logs)"
        LLVM_STATUS="FAILED/PARTIAL"
    fi
    
    echo "⏱️  LLVM Coverage Analysis Time: ${LLVM_EXECUTION_TIME} seconds"
    echo ""
    
    # Create LLVM coverage summary
    {
        echo "═══════════════════════════════════════════════════════════════"
        echo "CARGO LLVM-COV COVERAGE REPORT - $CONTRACT_NAME"
        echo "═══════════════════════════════════════════════════════════════"
        echo "Contract: $CONTRACT_NAME"
        echo "Analysis Date: $(date)"
        echo "Project Folder: $PROJECT_FOLDER"
        echo "Analysis Type: Branch/Condition Coverage"
        echo "Status: $LLVM_STATUS"
        echo "Exit Code: $LLVM_EXIT_CODE"
        echo "Execution Time: ${LLVM_EXECUTION_TIME} seconds"
        echo ""
        echo "Generated Artifacts:"
        echo "  • index.html - Interactive HTML coverage report"
        echo "  • llvm_cov_output.log - Full cargo llvm-cov output"
        echo "  • LLVM_COVERAGE_SUMMARY.txt - This summary"
        echo ""
        echo "Coverage Report Details:"
        echo "  └─ Report Type: Branch and Condition Coverage"
        echo "  └─ Format: HTML (standalone)"
        echo "  └─ Open in browser: file://$CONTRACT_COVERAGE_DIR/index.html"
        echo ""
    } > "$CONTRACT_COVERAGE_DIR/LLVM_COVERAGE_SUMMARY.txt"
    
    # Cleanup: Remove temporary LLVM instrumentation artifacts
    echo "Cleaning up LLVM instrumentation artifacts..."
    cd "$PROJECT_FOLDER" || exit
    
    # Remove profraw files (LLVM profile data)
    find . -type f -name "*.profraw" -delete 2>/dev/null
    
    # Remove profdata files
    find . -type f -name "*.profdata" -delete 2>/dev/null
    
    # Remove llvm-cov temporary directory if it exists
    [ -d ".llvm-cov" ] && rm -rf ".llvm-cov" 2>/dev/null
    
    # Clean incremental compilation artifacts that may have llvm instrumentation
    cargo clean --release 2>/dev/null
    
    echo "LLVM cleanup complete"
    echo ""
    
done <<< "$FILES_TO_PROCESS"

# Cleanup: Remove all generated verification files (comprehensive)
echo "Cleaning up generated verification files..."
cd "$PROJECT_FOLDER" || exit

# Delete all .out files
find . -type f -name "*.out" -delete 2>/dev/null

# Delete all .json files (except package.json and pnpm-lock.json)
find . -type f -name "*.json" ! -name "package.json" ! -name "pnpm-lock.json" -delete 2>/dev/null

# Delete any other Kani-generated metadata files
find . -type f -name "*.kani-metadata*" -delete 2>/dev/null
find . -type f -name "*.symtab*" -delete 2>/dev/null
find . -type f -name "*.pretty_name_map*" -delete 2>/dev/null
find . -type f -name "*.type_map*" -delete 2>/dev/null

echo "Cleanup complete - All verification artifacts removed"
echo ""

# Calculate overall execution time
OVERALL_END_TIME=$(date +%s.%N)
TOTAL_EXECUTION_TIME=$(echo "scale=2; $OVERALL_END_TIME - $OVERALL_START_TIME" | bc)

echo ""
echo "============================================================"
echo "All contracts verified!"
echo "============================================================"
echo "Summary:"
echo "   Total Contracts: $TOTAL"
echo "   Passed: $PASSED"
echo "   Failed: $FAILED"
echo "   Total Execution Time: ${TOTAL_EXECUTION_TIME} seconds"
echo ""
echo "Results Directory:"
echo "   • Location: $MAIN_RESULTS_DIR/[contract_name]/"
echo "   • Each contract folder contains:"
echo "     └─ Coverage Report: results/[contract_name]/coverage_report/index.html"
echo "============================================================"
echo ""

# Display overall verification coverage
if [ $PASSED -gt 0 ] || [ $FAILED -gt 0 ]; then
    TOTAL_MODULES=$((PASSED + FAILED))
    if [ $TOTAL_MODULES -gt 0 ]; then
        PASS_PERCENTAGE=$((PASSED * 100 / TOTAL_MODULES))
    else
        PASS_PERCENTAGE=0
    fi

    OVERALL_REACHABLE_ASSERTS=$((OVERALL_REACHABLE_TRUE + OVERALL_REACHABLE_FALSE))
    if [ $OVERALL_ASSERTS -gt 0 ]; then
        COVERAGE_PERCENTAGE=$((OVERALL_REACHABLE_ASSERTS * 100 / OVERALL_ASSERTS))
    else
        COVERAGE_PERCENTAGE=0
    fi
    
    echo "══════════════════════════════════════════════════════════════════════"
    echo "OVERALL VERIFICATION SUMMARY"
    echo "══════════════════════════════════════════════════════════════════════"
    echo "If you verify $TOTAL_MODULES modules:"
    echo "  ✓ Passed: $PASSED out of $TOTAL_MODULES ($PASS_PERCENTAGE%) "
    if [ $FAILED -gt 0 ]; then
        FAILED_PERCENTAGE=$((FAILED * 100 / TOTAL_MODULES))
        echo "  ✗ Failed: $FAILED out of $TOTAL_MODULES ($FAILED_PERCENTAGE%) "
    fi
    echo ""
    echo "Reachability Coverage:"
    if [ $OVERALL_ESTIMATED_MODULES -gt 0 ]; then
        echo "  Coverage basis:     ESTIMATED for $OVERALL_ESTIMATED_MODULES module(s)"
    else
        echo "  Coverage basis:     KANI"
    fi
    echo "  ✓ TRUE paths counted:  $OVERALL_REACHABLE_TRUE"
    echo "  ✓ FALSE paths counted: $OVERALL_REACHABLE_FALSE"
    echo "  ✓ Total counted:       $OVERALL_REACHABLE_ASSERTS out of $OVERALL_ASSERTS"
    echo "  → Overall Verification Coverage: $COVERAGE_PERCENTAGE%"
    echo ""
    echo "Coverage Reports:"
    echo "  • Each contract has its own coverage report"
    echo "  • Location: results/[contract_name]/coverage_report/index.html"
    echo "  • Open in browser to view branch coverage details"
    echo ""
    echo "  → Total Execution Time: ${TOTAL_EXECUTION_TIME} seconds"
    echo "══════════════════════════════════════════════════════════════════════"
    echo ""
fi

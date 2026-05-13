#!/usr/bin/env bash
# =============================================================================
# verify_anchor.sh — VeriRust Anchor Verification Pipeline
#
# Runs the full VeriRust pipeline on all benchmarks:
#   1. Parse each contract with anchor_parser.py (structure report)
#   2. Run Kani on pre-embedded harnesses in benchmarks/
#   3. Collect per-harness PASS/FAIL, counterexample, and timing
#   4. Print a results table suitable for the ASE paper
#
# Usage (from WSL):
#   bash verify_anchor.sh
#   bash verify_anchor.sh --harness verify_vault_safe_deposit   # single harness
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARKS_DIR="$SCRIPT_DIR/benchmarks"
RESULTS_DIR="$SCRIPT_DIR/results/anchor"
PYTHON="python3"
CARGO="$HOME/.cargo/bin/cargo"

mkdir -p "$RESULTS_DIR"

# ANSI colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║         VeriRust — Anchor Verification Pipeline              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# PHASE 1: Parse all contracts and report structure
# =============================================================================
echo -e "${CYAN}━━━ Phase 1: Contract Parsing (anchor_parser.py) ━━━${NC}"
echo ""

for rs in "$BENCHMARKS_DIR"/src/*.rs; do
    name=$(basename "$rs" .rs)
    [[ "$name" == "lib" ]] && continue
    echo -e "  Parsing ${BOLD}$name${NC} ..."
    $PYTHON "$SCRIPT_DIR/anchor_parser.py" "$rs" 2>&1 | \
        grep -E '^\s*(fn |  \[|  constraint|  detected)' | \
        sed 's/^/    /'
done
echo ""

# =============================================================================
# PHASE 2: Run Kani on each benchmark
# =============================================================================
echo -e "${CYAN}━━━ Phase 2: Kani Symbolic Verification ━━━${NC}"
echo ""

# Collect all harness names via cargo kani list
cd "$BENCHMARKS_DIR"
source "$HOME/.cargo/env"

echo "  Discovering harnesses ..."
# cargo kani list prints a table with fully-qualified harness names.
HARNESS_LIST=$($CARGO kani list 2>/dev/null | awk -F'|' '
    /verirust_benchmarks/ {
        gsub(/^[ \t]+|[ \t]+$/, "", $4);
        if ($4 != "") print $4;
    }
' || true)

if [[ -z "$HARNESS_LIST" ]]; then
    # Fallback: grep harness names from source and qualify them by module.
    HARNESS_LIST=$(grep -Rhl '#\[kani::proof\]' src/*.rs | while read -r rs; do
        module=$(basename "$rs" .rs)
        grep '#\[kani::proof\]' "$rs" -A1 | grep 'fn verify_' | \
            grep -oP '(?<=fn )\w+' | \
            awk -v module="$module" '{print module "::verirust_harnesses::" $1}'
    done)
fi

echo "  Found harnesses:"
echo "$HARNESS_LIST" | sed 's/^/    /'
echo ""

# Per-harness result tracking
declare -A RESULT        # PASS | FAIL | ERROR
declare -A ELAPSED       # seconds
declare -A COUNTEREX     # counterexample snippet if FAIL
declare -A BUG_CLASS     # inferred bug class

# Expected results for validation
declare -A EXPECTED
EXPECTED["verify_vault_safe_deposit"]="PASS"
EXPECTED["verify_vault_safe_withdraw"]="PASS"
EXPECTED["verify_vault_safe_auth"]="PASS"
EXPECTED["verify_vault_underflow_withdraw"]="FAIL"
EXPECTED["verify_vault_overflow_deposit"]="FAIL"
EXPECTED["verify_staking_safe_stake"]="PASS"
EXPECTED["verify_staking_safe_unstake"]="PASS"
EXPECTED["verify_staking_safe_auth"]="PASS"
EXPECTED["verify_staking_auth_unstake"]="FAIL"
EXPECTED["verify_token_mint"]="PASS"
EXPECTED["verify_token_burn_supply"]="FAIL"
EXPECTED["verify_real_stake"]="PASS"
EXPECTED["verify_real_order_unstake_auth"]="FAIL"
EXPECTED["verify_real_claim"]="PASS"

TOTAL=0
CORRECT=0
PASS_COUNT=0
FAIL_COUNT=0
ERROR_COUNT=0

for harness in $HARNESS_LIST; do
    TOTAL=$((TOTAL + 1))
    short_name="${harness##*::}"   # strip module prefix if present

    echo -n "  Verifying ${BOLD}$short_name${NC} ... "

    kani_log="$RESULTS_DIR/${short_name}.log"
    start_ts=$(date +%s%N)

    # Run Kani with timeout (300s)
    set +e
    timeout 300 $CARGO kani --harness "$harness" \
        --output-format terse \
        > "$kani_log" 2>&1
    kani_exit=$?
    set -e

    end_ts=$(date +%s%N)
    elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))
    elapsed_s=$(echo "scale=2; $elapsed_ms / 1000" | bc)
    ELAPSED["$short_name"]="$elapsed_s"

    # Parse Kani output
    if grep -q "VERIFICATION:- SUCCESSFUL" "$kani_log" 2>/dev/null; then
        RESULT["$short_name"]="PASS"
        PASS_COUNT=$((PASS_COUNT + 1))
        echo -e "${GREEN}PASS${NC} (${elapsed_s}s)"
    elif grep -q "VERIFICATION:- FAILED" "$kani_log" 2>/dev/null; then
        RESULT["$short_name"]="FAIL"
        FAIL_COUNT=$((FAIL_COUNT + 1))
        # Extract counterexample type
        cex=$(grep -oP '(AUTH_VIOLATION[^"]*|SUPPLY_INVARIANT[^"]*|attempt to add[^"]*|attempt to subtract[^"]*|arithmetic overflow|integer underflow|integer overflow|underflow|assertion failed|assertion `left == right` failed.*\n?.*)' \
              "$kani_log" 2>/dev/null | head -1 | tr -d '\n' || echo "see log")
        COUNTEREX["$short_name"]="$cex"
        echo -e "${RED}FAIL${NC} (${elapsed_s}s) — $cex"
    elif [[ $kani_exit -eq 124 ]]; then
        RESULT["$short_name"]="TIMEOUT"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        echo -e "${YELLOW}TIMEOUT${NC} (>300s)"
    else
        RESULT["$short_name"]="ERROR"
        ERROR_COUNT=$((ERROR_COUNT + 1))
        err=$(tail -3 "$kani_log" 2>/dev/null | tr '\n' ' ' || echo "unknown")
        echo -e "${YELLOW}ERROR${NC} — $err"
    fi

    # Validate against expected
    expected="${EXPECTED[$short_name]:-UNKNOWN}"
    actual="${RESULT[$short_name]}"
    if [[ "$expected" != "UNKNOWN" && "$expected" == "$actual" ]]; then
        CORRECT=$((CORRECT + 1))
    fi
done

cd "$SCRIPT_DIR"

# =============================================================================
# PHASE 3: Results Table
# =============================================================================
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║                    VeriRust Experiment Results (ASE Paper)                  ║${NC}"
echo -e "${BOLD}╠══════════════════════════════════╦═══════════╦══════════╦══════════════════╣${NC}"
printf "${BOLD}║ %-32s ║ %-9s ║ %-8s ║ %-16s ║${NC}\n" \
       "Harness" "Expected" "Result" "Time (s)"
echo -e "${BOLD}╠══════════════════════════════════╬═══════════╬══════════╬══════════════════╣${NC}"

# Print in order
ordered_harnesses=(
    "verify_vault_safe_deposit"
    "verify_vault_safe_withdraw"
    "verify_vault_safe_auth"
    "verify_vault_underflow_withdraw"
    "verify_vault_overflow_deposit"
    "verify_staking_safe_stake"
    "verify_staking_safe_unstake"
    "verify_staking_safe_auth"
    "verify_staking_auth_unstake"
    "verify_token_mint"
    "verify_token_burn_supply"
    "verify_real_stake"
    "verify_real_order_unstake_auth"
    "verify_real_claim"
)

for h in "${ordered_harnesses[@]}"; do
    exp="${EXPECTED[$h]:-—}"
    res="${RESULT[$h]:-—}"
    t="${ELAPSED[$h]:-—}"

    if [[ "$res" == "PASS" ]]; then
        res_fmt="${GREEN}PASS${NC}    "
    elif [[ "$res" == "FAIL" ]]; then
        res_fmt="${RED}FAIL${NC}    "
    else
        res_fmt="${YELLOW}${res}${NC}   "
    fi

    match=""
    if [[ "$exp" == "$res" ]]; then
        match="${GREEN}✓${NC}"
    else
        match="${RED}✗${NC}"
    fi

    printf "║ %-32s ║ %-9s ║ " "$h" "$exp"
    echo -ne "$res_fmt"
    printf " ║ %-14s  ║ " "$t"
    echo -e "$match"
done

echo -e "${BOLD}╚══════════════════════════════════╩═══════════╩══════════╩══════════════════╝${NC}"
echo ""

# =============================================================================
# PHASE 4: Summary Statistics
# =============================================================================
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo "  Total harnesses       : $TOTAL"
echo "  PASS                  : $PASS_COUNT"
echo "  FAIL (bugs found)     : $FAIL_COUNT"
echo "  Errors/Timeouts       : $ERROR_COUNT"
echo "  Correct predictions   : $CORRECT / $TOTAL"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo -e "${BOLD}Bugs detected:${NC}"
    for h in "${!RESULT[@]}"; do
        if [[ "${RESULT[$h]}" == "FAIL" ]]; then
            cex="${COUNTEREX[$h]:-see $RESULTS_DIR/$h.log}"
            echo "  • $h"
            echo "    └─ $cex"
        fi
    done
fi

echo ""
echo "  Full logs: $RESULTS_DIR/"
echo ""

# Save machine-readable results CSV
csv="$RESULTS_DIR/results.csv"
echo "harness,expected,result,time_s,counterexample" > "$csv"
for h in "${ordered_harnesses[@]}"; do
    exp="${EXPECTED[$h]:-unknown}"
    res="${RESULT[$h]:-—}"
    t="${ELAPSED[$h]:-—}"
    cex="${COUNTEREX[$h]:-}"
    echo "\"$h\",\"$exp\",\"$res\",\"$t\",\"$cex\"" >> "$csv"
done
echo "  Results CSV: $csv"
echo ""

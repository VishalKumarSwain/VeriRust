#!/usr/bin/env bash
set -euo pipefail

source "$HOME/.cargo/env"
PROJ="/mnt/d/TRUSTINN/Smart-Contract-Analyzer-VeriRust"
BENCH="$PROJ/benchmarks"
OUT="$PROJ/results/anchor"

mkdir -p "$OUT"

HARNESSES=(
  "vault_safe::verirust_harnesses::verify_vault_safe_deposit"
  "vault_safe::verirust_harnesses::verify_vault_safe_withdraw"
  "vault_safe::verirust_harnesses::verify_vault_safe_auth"
  "vault_underflow::verirust_harnesses::verify_vault_underflow_withdraw"
  "vault_overflow::verirust_harnesses::verify_vault_overflow_deposit"
  "staking_safe::verirust_harnesses::verify_staking_safe_stake"
  "staking_safe::verirust_harnesses::verify_staking_safe_unstake"
  "staking_safe::verirust_harnesses::verify_staking_safe_auth"
  "staking_missing_auth::verirust_harnesses::verify_staking_auth_unstake"
  "token_mint_bug::verirust_harnesses::verify_token_mint"
  "token_mint_bug::verirust_harnesses::verify_token_burn_supply"
)

echo "harness,expected,result,time_s,counterexample" > "$OUT/results.csv"

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

cd "$BENCH"

for h in "${HARNESSES[@]}"; do
  short="${h##*::}"
  exp="${EXPECTED[$short]:-unknown}"
  printf "  %-45s [expected: %-4s] ... " "$short" "$exp"

  start_ms=$(($(date +%s%N) / 1000000))
  set +e
  output=$(timeout 300 cargo kani --harness "$h" --output-format terse 2>&1)
  exit_code=$?
  set -e
  end_ms=$(($(date +%s%N) / 1000000))
  elapsed_s=$(awk "BEGIN{printf \"%.2f\", ($end_ms - $start_ms)/1000}")

  cex=""
  if echo "$output" | grep -q "VERIFICATION:- SUCCESSFUL"; then
    result="PASS"
    echo "PASS  (${elapsed_s}s)"
  elif echo "$output" | grep -q "VERIFICATION:- FAILED"; then
    result="FAIL"
    # Extract counterexample type from Kani output
    if echo "$output" | grep -qi "arithmetic overflow"; then
      cex="arithmetic overflow"
    elif echo "$output" | grep -qi "attempt to subtract"; then
      cex="integer underflow"
    elif echo "$output" | grep -qi "attempt to add"; then
      cex="integer overflow"
    elif echo "$output" | grep -qi "AUTH_VIOLATION"; then
      cex="AUTH_VIOLATION"
    elif echo "$output" | grep -qi "SUPPLY_INVARIANT"; then
      cex="SUPPLY_INVARIANT"
    elif echo "$output" | grep -qi "assertion.*failed"; then
      cex=$(echo "$output" | grep -i "assertion.*failed" | head -1 | sed 's/.*assertion/assertion/' | cut -c1-60)
    fi
    echo "FAIL  (${elapsed_s}s) — $cex"
  elif [ "$exit_code" -eq 124 ]; then
    result="TIMEOUT"
    echo "TIMEOUT (>300s)"
  else
    result="ERROR"
    err=$(echo "$output" | tail -3 | tr '\n' ' ')
    echo "ERROR — $err"
  fi

  echo "\"$short\",\"$exp\",\"$result\",\"$elapsed_s\",\"$cex\"" >> "$OUT/results.csv"
  echo "$output" > "$OUT/${short}.log"
done

echo ""
echo "━━━ Results CSV ━━━"
cat "$OUT/results.csv"
echo ""
echo "Logs saved to: $OUT/"

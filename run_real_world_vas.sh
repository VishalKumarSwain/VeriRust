#!/usr/bin/env bash
set -euo pipefail

PROJ="$(cd "$(dirname "$0")" && pwd)"
OUT="$PROJ/results/real_world_contracts"
PYTHON="${PYTHON:-python3}"

mkdir -p "$OUT"

declare -A SOURCES=(
  [marinade_liquid_staking]="$PROJ/real_world_contracts/marinade_liquid_staking/programs/marinade-finance/src"
  [orca_whirlpool]="$PROJ/real_world_contracts/orca_whirlpool/programs/whirlpool/src"
  [drift_v2]="$PROJ/real_world_contracts/drift_v2/programs/drift/src"
  [mango_v4]="$PROJ/real_world_contracts/mango_v4/programs/mango-v4/src"
  [squads_v4]="$PROJ/real_world_contracts/squads_v4/programs/squads_multisig_program/src"
  [metaplex_token_metadata]="$PROJ/real_world_contracts/metaplex_token_metadata/programs/token-metadata/program/src"
)

echo "contract,vas_file,vas_structs,vas_instructions,generated_harnesses" > "$OUT/converted_vas_summary.csv"

for name in "${!SOURCES[@]}"; do
  src="${SOURCES[$name]}"
  vas="$OUT/$name.vas.rs"
  parse_report="$OUT/$name.vas.parse.txt"
  harness_report="$OUT/$name.vas.harness.txt"

  if [[ ! -d "$src" ]]; then
    echo "Skipping $name: missing $src" >&2
    continue
  fi

  "$PYTHON" "$PROJ/anchor_to_vas.py" "$src" -o "$vas"
  "$PYTHON" "$PROJ/anchor_parser.py" "$vas" > "$parse_report"
  "$PYTHON" "$PROJ/harness_generator.py" "$vas" > "$harness_report"

  structs=$(grep -oP '^Structs \(\K[0-9]+' "$parse_report" || echo 0)
  instructions=$(grep -oP '^Instructions \(\K[0-9]+' "$parse_report" || echo 0)
  harnesses=$(grep -c '#\[kani::proof\]' "$harness_report" || true)

  echo "\"$name\",\"$vas\",\"$structs\",\"$instructions\",\"$harnesses\"" >> "$OUT/converted_vas_summary.csv"
  printf "%-24s structs=%-4s instructions=%-4s harnesses=%s\n" "$name" "$structs" "$instructions" "$harnesses"
done

echo "Summary: $OUT/converted_vas_summary.csv"

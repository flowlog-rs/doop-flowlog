#!/usr/bin/env bash
# Assemble standalone single-file DOOP programs (flowlog bare-grammar + souffle)
# from the sparse-checked-out doop-flowlog logic trees, via the C preprocessor.
# Mirrors the verified pipeline in doop-flowlog@flowlog-next-datalog-compat/verify/run_verify.sh.
# Output restricted to VarPointsTo. No DOOP/Java/gradle needed.
set -u
ROOT=/home/azureuser/doop-e2e/doop-logic
OUT=/home/azureuser/doop-e2e/programs
mkdir -p "$OUT/flowlog" "$OUT/souffle"

FAMILIES=(
  context-insensitive
  1-type-sensitive
  1-type-sensitive+heap
  1-call-site-sensitive
  1-call-site-sensitive+heap
  1-object-sensitive
  1-object-sensitive+heap
  1-object-1-type-sensitive+heap
  2-type-sensitive+heap
  2-type-object-sensitive+heap
  2-type-object-sensitive+2-heap
  2-object-sensitive+heap
  2-object-sensitive+2-heap
  adaptive-2-object-sensitive+heap
  3-type-sensitive+2-heap
  3-type-sensitive+3-heap
  3-object-sensitive+2-heap
  3-object-sensitive+3-heap
  4-object-sensitive+4-heap
)

for fam in "${FAMILIES[@]}"; do
  cfg=$(grep -hoE '\.comp +\w+ *: *AbstractConfiguration' "$ROOT/souffle-logic/analyses/$fam/analysis.dl" | head -1 | sed -E 's/\.comp +(\w+).*/\1/')
  if [ -z "$cfg" ]; then echo "!! $fam: could not extract CONFIGURATION"; continue; fi

  # ---- FlowLog (bare grammar, main-next compatible) ----
  A="$OUT/flowlog/$fam.dl"
  cpp -P -DCONFIGURATION=$cfg "$ROOT/flowlog-logic/facts/facts.dl"           >  "$A" 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg "$ROOT/flowlog-logic/basic/basic.dl"           >> "$A" 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg "$ROOT/flowlog-logic/analyses/$fam/analysis.dl" >> "$A" 2>/dev/null
  # keep only VarPointsTo among .output/.printsize directives
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' "$A"

  # ---- Souffle ----
  SA="$OUT/souffle/$fam.dl"
  cpp -P -DCONFIGURATION=$cfg "$ROOT/souffle-logic/facts/facts.dl"           >  "$SA" 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg "$ROOT/souffle-logic/basic/basic.dl"           >> "$SA" 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg "$ROOT/souffle-logic/analyses/$fam/analysis.dl" >> "$SA" 2>/dev/null
  # strip .plan directives (join scheduling only; affects perf not output) and stray plan lines
  sed -i -E '/^[[:space:]]*\.plan\b/d; /^[[:space:]]*[0-9]+:\(/d' "$SA"
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' "$SA"

  echo "assembled $fam  cfg=$cfg  fl=$(wc -l <"$A")L  sf=$(wc -l <"$SA")L"
done
echo "DONE: 19 families -> $OUT/{flowlog,souffle}"

#!/usr/bin/env bash
# generate.sh — produce STANDALONE single-file Datalog programs for the
# benchmark, one per (family × engine-variant), with the FULL DOOP output set
# wired in. Run ONCE (needs this repo + cpp); commit the results in programs/.
# Collaborators then run run.sh against programs/ with NO repo/cpp/DOOP needed.
#
# For each family it emits three self-contained programs (facts schema + basic
# logic + the family's analysis, C-preprocessed and concatenated):
#   programs/<family>.flowlog.dl        FlowLog dialect,  all .output kept
#   programs/<family>.souffle.dl        Soufflé dialect,  all .output + .plan kept
#   programs/<family>.souffle-noplan.dl Soufflé dialect,  all .output, .plan stripped
#
# The FlowLog logic comes from the branch whose grammar matches the compiler
# you will run (default: this working tree). To target current FlowLog
# main-next, generate from the `flowlog-next-datalog-compat` branch.
#
#   REPO=/path/to/doop-flowlog verify/bench/generate.sh [family ...]
set -uo pipefail
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
OUT="${OUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/programs}"
mkdir -p "$OUT"
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
FAMILIES=($FAMILIES)   # string -> array (word-split)
if [[ $# -gt 0 ]]; then FAMILIES=("$@"); fi

extra_defs(){ case "$1" in types-only) echo "-DDISABLE_POINTS_TO" ;; *) echo "" ;; esac; }

for fam in "${FAMILIES[@]}"; do
  ana="$REPO/souffle-logic/analyses/$fam/analysis.dl"
  [[ -f "$ana" ]] || { echo "SKIP $fam (no such family)"; continue; }
  cfg=$(grep -ahoE '\.comp +\w+ *: *AbstractConfiguration' "$REPO/flowlog-logic/analyses/$fam/analysis.dl" | head -1 | sed -E 's/\.comp +(\w+).*/\1/')
  [[ -n "$cfg" ]] || { echo "SKIP $fam (no AbstractConfiguration)"; continue; }
  defs="-DCONFIGURATION=$cfg $(extra_defs "$fam")"

  # FlowLog: facts + basic + analysis, full output kept
  fl="$OUT/$fam.flowlog.dl"
  cpp -P $defs "$REPO/flowlog-logic/facts/facts.dl"          >  "$fl" 2>/dev/null
  cpp -P $defs "$REPO/flowlog-logic/basic/basic.dl"          >> "$fl" 2>/dev/null
  cpp -P $defs "$REPO/flowlog-logic/analyses/$fam/analysis.dl" >> "$fl" 2>/dev/null

  # Soufflé (with .plan): facts + basic + analysis, full output + plan kept
  sf="$OUT/$fam.souffle.dl"
  cpp -P $defs "$REPO/souffle-logic/facts/facts.dl"          >  "$sf" 2>/dev/null
  cpp -P $defs "$REPO/souffle-logic/basic/basic.dl"          >> "$sf" 2>/dev/null
  cpp -P $defs "$REPO/souffle-logic/analyses/$fam/analysis.dl" >> "$sf" 2>/dev/null

  # Soufflé (no .plan): same, join-order hints stripped
  sfnp="$OUT/$fam.souffle-noplan.dl"
  sed -E '/^[[:space:]]*\.plan\b/d; /^[[:space:]]*[0-9]+:\(/d' "$sf" > "$sfnp"

  echo "OK  $fam  (cfg=$cfg)  fl=$(wc -l <"$fl")L sf=$(wc -l <"$sf")L"
done
echo "generated into $OUT"

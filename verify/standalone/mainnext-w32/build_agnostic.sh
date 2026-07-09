#!/usr/bin/env bash
# One-time: build DATASET-AGNOSTIC FlowLog binaries by baking the fact dir to the
# /datasets/facts/CURRENT symlink. After this, any dataset is run by repointing
# CURRENT and executing flbinX/<fam> -w N (no per-dataset recompile).
set -u
BASE=/home/azureuser/doop-e2e
FLC=/home/azureuser/flowlog-mn/target/release/flowlog-compiler
CUR=/datasets/facts/CURRENT
OUTROOT=/datasets/doop-e2e
export TMPDIR=/datasets/tmp
mkdir -p "$BASE/flbinX" "$OUTROOT/floutX" "$BASE/logs"
mapfile -t FAMILIES < "$BASE/families.txt"
for fam in "${FAMILIES[@]}"; do
  [ -x "$BASE/flbinX/$fam" ] && { echo "[$(date +%T)] skip $fam (built)"; continue; }
  mkdir -p "$OUTROOT/floutX/$fam"
  t=$SECONDS
  "$FLC" --mode datalog-batch --str-intern -F "$CUR" -D "$OUTROOT/floutX/$fam" \
     -o "$BASE/flbinX/$fam" "$BASE/programs/flowlog/$fam.dl" \
     > "$BASE/logs/$fam.flcompileX.log" 2>&1
  echo "[$(date +%T)] $fam rc=$? ($((SECONDS-t))s)"
done
echo "[$(date +%T)] DATASET-AGNOSTIC FL BINARIES: $(ls "$BASE/flbinX" | wc -l)/19"

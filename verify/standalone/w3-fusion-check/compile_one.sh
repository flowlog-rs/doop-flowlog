#!/usr/bin/env bash
# Compile one (compiler, family) pair for the w3 A/B. Usage: compile_one.sh <base|w3> <family>
set -u
which=$1; fam=$2
case "$which" in
  base) FLC=/datasets/fl-base/target/release/flowlog-compiler; tag=base;;
  w3)   FLC=/datasets/fl-w3/target/release/flowlog-compiler;   tag=w3;;
  *) echo "arg1 must be base|w3"; exit 2;;
esac
PROG=/home/azureuser/doop-e2e/standalone-progs/verify/standalone/flowlog/$fam.dl
FACTS=/datasets/facts/luindex     # only used to type EDBs at compile; binary bakes CURRENT via -F below
export TMPDIR=/datasets/tmp
BASE=/datasets/w3test
mkdir -p "$BASE/flout_$tag/$fam" "$BASE/logs"
t0=$SECONDS
"$FLC" --mode datalog-batch --str-intern -F "$FACTS" \
   -D "$BASE/flout_$tag/$fam" -o "$BASE/flbin_$tag/$fam" "$PROG" \
   > "$BASE/logs/$tag.$fam.compile.log" 2>&1
rc=$?
echo "[$(date +%T)] $tag/$fam compile rc=$rc ($((SECONDS-t0))s) $([ -x "$BASE/flbin_$tag/$fam" ] && echo OK || echo FAIL)"

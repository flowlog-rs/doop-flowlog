#!/bin/bash
# Rebuild each matched family and time flowlog at -w 16 and -w 32.
# Compare against known -w 1 (flowlog) and -j 1 (souffle) numbers.
ROOT=/users/zhhong/doop-flowlog
FLC=/dev/shm/fl-tuple/target/release/flowlog-compiler
FACTS=/dev/shm/curfacts
W=/dev/shm/verify
export TMPDIR=/dev/shm LC_ALL=C
RES=$W/bench_w32.tsv
echo -e "family\tbuild_s\tw16_s\tw32_s" > $RES

FAMILIES=(
  3-type-sensitive+2-heap
  2-type-sensitive+heap
  3-object-sensitive+2-heap
  1-object-1-type-sensitive+heap
  2-type-object-sensitive+heap
  2-object-sensitive+heap
  adaptive-2-object-sensitive+heap
)

wall(){ grep 'wall clock' "$1" | grep -oE '[0-9:.]+$' | tail -1 \
  | awk -F: '{if(NF==2)print $1*60+$2; else print $1}'; }

for fam in "${FAMILIES[@]}"; do
  echo "[$(date +%H:%M:%S)] === $fam ===" >&2
  cfg=$(grep -hoE '\.comp +\w+ *: *AbstractConfiguration' $ROOT/souffle-logic/analyses/$fam/analysis.dl|head -1|sed -E 's/\.comp +(\w+).*/\1/')
  A=$W/$fam.bench.dl
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/facts/facts.dl  > $A 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/basic/basic.dl >> $A 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/analyses/$fam/analysis.dl >> $A 2>/dev/null
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' $A
  mkdir -p $W/bout_$fam
  b0=$SECONDS
  $FLC --str-intern -F $FACTS -D $W/bout_$fam -o $W/bbin_$fam $A > $W/$fam.bbuild.log 2>&1
  bd=$((SECONDS-b0))
  w16=NA; w32=NA
  if [ -x "$W/bbin_$fam" ]; then
    /usr/bin/time -v $W/bbin_$fam -w 16 > $W/$fam.w16.log 2>&1 && w16=$(wall $W/$fam.w16.log)
    /usr/bin/time -v $W/bbin_$fam -w 32 > $W/$fam.w32.log 2>&1 && w32=$(wall $W/$fam.w32.log)
  fi
  echo -e "$fam\t$bd\t$w16\t$w32" | tee -a $RES >&2
  rm -rf $W/bout_$fam $W/bbin_$fam $W/$fam.bench.dl
done
echo "[$(date +%H:%M:%S)] DONE" >&2

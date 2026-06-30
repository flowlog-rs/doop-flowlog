#!/bin/bash
# Overnight correctness harness: for each supported family, build+run flowlog and
# souffle single-threaded on luindex, compare VarPointsTo byte-exact.
# Robust to OOM/timeout/disk: bounded to one family at a time, frees after each.

ROOT=/users/zhhong/doop-flowlog
FLC=/dev/shm/fl-tuple/target/release/flowlog-compiler
FACTS=/dev/shm/curfacts
W=/dev/shm/verify
RES=$W/results2.tsv
export TMPDIR=/dev/shm
export LC_ALL=C

BUILD_TO=3900
FL_RUN_TO=3600     # 60 min flowlog run cap
SF_RUN_TO=3600     # 60 min souffle run cap
MIN_AVAIL_KB=25000000   # 25G: below this, emergency clean / skip

FAMILIES=(
  1-object-1-type-sensitive+heap
  2-type-sensitive+heap
  2-type-object-sensitive+heap
  adaptive-2-object-sensitive+heap
  2-object-sensitive+heap
  3-type-sensitive+2-heap
  3-object-sensitive+2-heap
  2-call-site-sensitive+heap
  partitioned-2-object-sensitive+heap
)

VPT_OUT='.output VarPointsTo(IO="file",filename="VarPointsTo.csv",delimiter="\t")'

# canonicalize: unify record/tuple brackets, drop comma-spaces & trailing commas
canon(){ sed -e 's/\[/(/g; s/\]/)/g; s/, /,/g; s/,)/)/g' "$1" | sort --buffer-size=6G ; }

avail_kb(){ df --output=avail -k /dev/shm | tail -1 | tr -d ' '; }

echo -e "family\tfl_build\tfl_run\tfl_vpt\tsf_build\tsf_run\tsf_vpt\tonly_fl\tonly_sf\tboth\tverdict" > $RES
echo "[$(date +%H:%M:%S)] START verify batch, ${#FAMILIES[@]} families" >&2

for fam in "${FAMILIES[@]}"; do
  t0=$SECONDS
  echo "[$(date +%H:%M:%S)] === $fam  (avail $(($(avail_kb)/1024/1024))G) ===" >&2
  # emergency clean if disk low
  if [ "$(avail_kb)" -lt "$MIN_AVAIL_KB" ]; then
    echo "  LOW DISK: cleaning stale outputs" >&2
    rm -rf $W/out_* $W/sfout_* $W/bin_* $W/sfbin_* $W/*.fl.dl $W/*.sf.dl $W/a.txt $W/b.txt
  fi
  cfg=$(grep -hoE '\.comp +\w+ *: *AbstractConfiguration' $ROOT/souffle-logic/analyses/$fam/analysis.dl|head -1|sed -E 's/\.comp +(\w+).*/\1/')
  flb=NA; flr=NA; sfb=NA; sfr=NA; flvpt=NA; sfvpt=NA; onlyfl=NA; onlysf=NA; both=NA; verdict=NA

  # ---------- flowlog ----------
  A=$W/$fam.fl.dl
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/facts/facts.dl  > $A 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/basic/basic.dl >> $A 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/analyses/$fam/analysis.dl >> $A 2>/dev/null
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' $A
  mkdir -p $W/out_$fam
  timeout $BUILD_TO $FLC --str-intern -F $FACTS -D $W/out_$fam -o $W/bin_$fam $A > $W/$fam.flbuild.log 2>&1
  flb=$?
  if [ -x "$W/bin_$fam" ]; then
    timeout $FL_RUN_TO /usr/bin/time -v $W/bin_$fam -w 1 > $W/$fam.flrun.log 2>&1
    flr=$?
  fi
  [ -f "$W/out_$fam/VarPointsTo.csv" ] && flvpt=$(wc -l < $W/out_$fam/VarPointsTo.csv)

  # ---------- souffle ----------
  SA=$W/$fam.sf.dl
  cpp -P -DCONFIGURATION=$cfg $ROOT/souffle-logic/facts/facts.dl  > $SA 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/souffle-logic/basic/basic.dl >> $SA 2>/dev/null
  cpp -P -DCONFIGURATION=$cfg $ROOT/souffle-logic/analyses/$fam/analysis.dl >> $SA 2>/dev/null
  sed -i -E '/^[[:space:]]*\.plan\b/d; /^[[:space:]]*[0-9]+:\(/d' $SA
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' $SA
  timeout $BUILD_TO souffle -c -o $W/sfbin_$fam $SA > $W/$fam.sfbuild.log 2>&1
  sfb=$?
  mkdir -p $W/sfout_$fam
  if [ -x "$W/sfbin_$fam" ]; then
    timeout $SF_RUN_TO /usr/bin/time -v $W/sfbin_$fam -j 1 -F $FACTS -D $W/sfout_$fam > $W/$fam.sfrun.log 2>&1
    sfr=$?
  fi
  [ -f "$W/sfout_$fam/VarPointsTo.csv" ] && sfvpt=$(wc -l < $W/sfout_$fam/VarPointsTo.csv)

  # ---------- compare ----------
  if [ -f "$W/out_$fam/VarPointsTo.csv" ] && [ -f "$W/sfout_$fam/VarPointsTo.csv" ]; then
    canon $W/out_$fam/VarPointsTo.csv > $W/a.txt 2>>$W/$fam.cmp.log
    canon $W/sfout_$fam/VarPointsTo.csv > $W/b.txt 2>>$W/$fam.cmp.log
    onlyfl=$(comm -23 $W/a.txt $W/b.txt | wc -l)
    onlysf=$(comm -13 $W/a.txt $W/b.txt | wc -l)
    both=$(comm -12 $W/a.txt $W/b.txt | wc -l)
    if [ "$onlyfl" = 0 ] && [ "$onlysf" = 0 ]; then verdict=MATCH; else verdict=DIFF; fi
    rm -f $W/a.txt $W/b.txt
  else
    verdict=INCOMPLETE
  fi

  echo -e "$fam\t$flb\t$flr\t$flvpt\t$sfb\t$sfr\t$sfvpt\t$onlyfl\t$onlysf\t$both\t$verdict" >> $RES
  echo "[$(date +%H:%M:%S)] $fam -> $verdict (flvpt=$flvpt sfvpt=$sfvpt only_fl=$onlyfl only_sf=$onlysf) in $((SECONDS-t0))s" >&2

  # ---------- free ----------
  rm -rf $W/out_$fam $W/sfout_$fam $W/bin_$fam $W/sfbin_$fam $W/sfbin_$fam.cpp $W/$fam.fl.dl $W/$fam.sf.dl
done
echo "[$(date +%H:%M:%S)] DONE" >&2

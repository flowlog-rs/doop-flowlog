#!/usr/bin/env bash
# Parallel (-w32 / -j32) FlowLog-main-next vs Souffle benchmark on the DOOP
# standalone families (luindex). Companion to ../verify.sh, which measures the
# single-threaded (-w1 / -j1) nemo/tuple build; this one measures the *parallel*
# throughput of the current main-next engine.
#
#   FlowLog : flowlog-compiler --str-intern --mode datalog-batch -F FACTS -D out -o bin PROG ; ./bin -w 32
#   Souffle : souffle -j 32 -o bin PROG                                                       ; ./bin -j 32 -F FACTS -D out
#
# Oracle = Souffle. Verdict = byte-exact VarPointsTo after bracket-canonicalisation + sort.
# Phase A compiles every family (parallel, rolling cap); phase B runs them SERIALLY so the
# wall-clock and peak-RSS numbers are contention-free.
#
# Inputs (override via env):
#   FLC           flowlog-compiler built from flowlog-rs/flowlog main-next
#   FACTS         DOOP-generated fact dir (e.g. luindex)
#   FLOWLOG_PROGS dir of main-next-compatible FlowLog programs (bare-grammar, non-tuple-EDB;
#                 see README "Why the FlowLog programs differ"). One <family>.dl per family.
#   SOUFFLE_PROGS dir of Souffle programs (defaults to ../standalone/souffle)
#   W, J          worker/job counts (default 32); CAP compile concurrency; *_TO run timeouts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
FLC=${FLC:?set FLC to the main-next flowlog-compiler}
FACTS=${FACTS:?set FACTS to the DOOP fact dir}
FLOWLOG_PROGS=${FLOWLOG_PROGS:?set FLOWLOG_PROGS to the main-next-compatible FlowLog programs}
SOUFFLE_PROGS=${SOUFFLE_PROGS:-$HERE/../standalone/souffle}
OUT=${OUT:-$HERE/run}                 # working dir for binaries/outputs (keep OFF a small root disk)
W=${W:-32}; J=${J:-32}; CAP=${CAP:-12}
FLRUN_TO=${FLRUN_TO:-5400}; SFRUN_TO=${SFRUN_TO:-5400}
TIME=/usr/bin/time
mkdir -p "$OUT"/{flbin,sfbin,flout,sfout,logs,tmp}
export TMPDIR=$OUT/tmp
RES=$OUT/results.tsv
printf "family\tfl_compile_s\tfl_run_s\tfl_maxRSS_GB\tsf_compile_s\tsf_run_s\tsf_maxRSS_GB\tfl_vpt\tsf_vpt\tverdict\n" > "$RES"

canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1" | LC_ALL=C sort -T "$OUT/tmp" -S 8G; }
tsecs(){ grep -oE "Elapsed .*: .*" "$1" 2>/dev/null | grep -oE "[0-9:.]+$" | awk -F: 'NF==3{print $1*3600+$2*60+$3}NF==2{print $1*60+$2}NF==1{print $1}'; }
tgb(){ awk -v k="$(grep -oE "Maximum resident set size \(kbytes\): [0-9]+" "$1" 2>/dev/null | grep -oE "[0-9]+$")" 'BEGIN{printf "%.2f", (k?k:0)/1048576}'; }

compile_fam(){
  local fam=$1 fl=$OUT/flbin/$fam sf=$OUT/sfbin/$fam
  mkdir -p "$OUT/flout/$fam" "$OUT/sfout/$fam"
  local a="" b=""
  [ -x "$fl" ] || { $TIME -v -o "$OUT/logs/$fam.flc.time" "$FLC" --str-intern --mode datalog-batch \
        -F "$FACTS" -D "$OUT/flout/$fam" -o "$fl" "$FLOWLOG_PROGS/$fam.dl" > "$OUT/logs/$fam.flc.log" 2>&1 & a=$!; }
  [ -x "$sf" ] || { $TIME -v -o "$OUT/logs/$fam.sfc.time" souffle -j "$J" -o "$sf" \
        "$SOUFFLE_PROGS/$fam.dl" > "$OUT/logs/$fam.sfc.log" 2>&1 & b=$!; }
  [ -n "$a" ] && wait "$a"; [ -n "$b" ] && wait "$b"
  rm -rf "$OUT/flbin/.$fam.build" "$OUT/sfbin/$fam.cpp"
  echo "[$(date +%T)] compiled $fam (fl=$([ -x "$fl" ]&&echo ok||echo FAIL) sf=$([ -x "$sf" ]&&echo ok||echo FAIL))"
}

run_fam(){
  local fam=$1 flo=$OUT/flout/$fam sfo=$OUT/sfout/$fam
  rm -f "$flo"/VarPointsTo.csv "$sfo"/VarPointsTo.csv
  local flc sfc flr="NA" flm="NA" flv="NA" sfr="NA" sfm="NA" sfv="NA"
  flc=$(tsecs "$OUT/logs/$fam.flc.time"); sfc=$(tsecs "$OUT/logs/$fam.sfc.time")
  if [ -x "$OUT/flbin/$fam" ]; then
    echo "[$(date +%T)] $fam : FlowLog run -w $W"
    $TIME -v -o "$OUT/logs/$fam.flr.time" timeout "$FLRUN_TO" "$OUT/flbin/$fam" -w "$W" > "$OUT/logs/$fam.flr.log" 2>&1
    flr=$(tsecs "$OUT/logs/$fam.flr.time"); flm=$(tgb "$OUT/logs/$fam.flr.time")
    [ -f "$flo/VarPointsTo.csv" ] && flv=$(wc -l < "$flo/VarPointsTo.csv")
  fi
  if [ -x "$OUT/sfbin/$fam" ]; then
    echo "[$(date +%T)] $fam : Souffle run -j $J"
    $TIME -v -o "$OUT/logs/$fam.sfr.time" timeout "$SFRUN_TO" "$OUT/sfbin/$fam" -j "$J" -F "$FACTS" -D "$sfo" > "$OUT/logs/$fam.sfr.log" 2>&1
    sfr=$(tsecs "$OUT/logs/$fam.sfr.time"); sfm=$(tgb "$OUT/logs/$fam.sfr.time")
    [ -f "$sfo/VarPointsTo.csv" ] && sfv=$(wc -l < "$sfo/VarPointsTo.csv")
  fi
  local v="INCOMPLETE"
  if [ -f "$flo/VarPointsTo.csv" ] && [ -f "$sfo/VarPointsTo.csv" ]; then
    if diff -q <(canon "$flo/VarPointsTo.csv") <(canon "$sfo/VarPointsTo.csv") >/dev/null 2>&1; then v="MATCH"
    elif [ "$flv" = "$sfv" ]; then v="DIFF_SAMECOUNT"; else v="DIFF"; fi
  fi
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" "$flc" "$flr" "$flm" "$sfc" "$sfr" "$sfm" "$flv" "$sfv" "$v" | tee -a "$RES"
}

mapfile -t FAMS < <(cd "$SOUFFLE_PROGS" && ls *.dl | sed 's/\.dl$//')
[ $# -gt 0 ] && FAMS=("$@")

echo "=== PHASE A: compile ${#FAMS[@]} families (cap=$CAP) ==="
for fam in "${FAMS[@]}"; do
  compile_fam "$fam" &
  while [ "$(jobs -rp | wc -l)" -ge "$CAP" ]; do sleep 2; done
done
wait
echo "=== PHASE B: run serially ==="
for fam in "${FAMS[@]}"; do run_fam "$fam"; done
echo "=== DONE -> $RES ==="
column -t -s $'\t' "$RES"

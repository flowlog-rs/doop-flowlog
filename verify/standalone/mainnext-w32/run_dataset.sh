#!/usr/bin/env bash
# Run all 19 families on a given dataset using PRE-BUILT binaries:
#   FlowLog  -> flbinX/<fam> (fact dir baked to /datasets/facts/CURRENT symlink), run -w N
#   Soufflé  -> sfbin/<fam>, run -j N with runtime -F <dataset>
# Captures wall + peak RSS (min of REPEAT), byte-exact correctness. No compilation.
# Usage: ./run_dataset.sh <dataset-name>     (e.g. ./run_dataset.sh eclipse)
set -u
DS=${1:?usage: [env overrides] run_dataset.sh <dataset> [family ...]}
# ---- config (override via env) ----
BASE=${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}   # harness dir: flbinX/, sfbin/, families.txt
FACTS_ROOT=${FACTS_ROOT:-/datasets/facts}                    # dir holding <dataset>/ DOOP fact dirs
OUTROOT=${OUTROOT:-/datasets/doop-e2e}                       # scratch for large outputs (keep off small root fs)
CUR=${CUR:-$FACTS_ROOT/CURRENT}                              # symlink the FlowLog binaries' fact dir is baked to
export TMPDIR=${TMPDIR:-/datasets/tmp} LC_ALL=C
FACTS=$FACTS_ROOT/$DS
WORKERS=${WORKERS:-32}; JOBS=${JOBS:-32}; REPEAT=${REPEAT:-2}; RUN_TO=${RUN_TO:-7200}
[ -d "$FACTS" ] || { echo "no dataset $FACTS"; exit 1; }
mkdir -p "$OUTROOT/sfoutX" "$OUTROOT/tmp" "$BASE/results"
RES="$BASE/results/results_$DS.tsv"
printf "family\tVPT_rows\tFL_wall_s\tFL_RSS_GB\tSF_wall_s\tSF_RSS_GB\tSFxFL_speedup\tFLoverSF_mem\tcorrect\tonly_FL\tonly_SF\n" > "$RES"
mapfile -t FAMILIES < "$BASE/families.txt"
[ $# -gt 1 ] && FAMILIES=("${@:2}")

# point FlowLog's baked CURRENT symlink at this dataset for the whole run
ln -sfn "$FACTS" "$CUR"

wall(){ grep -oE "wall clock.*: .*" "$1"|grep -oE "[0-9:.]+$"|tail -1|awk -F: 'NF==3{print $1*3600+$2*60+$3}NF==2{print $1*60+$2}NF==1{print $1}'; }
rssgb(){ local kb=$(grep -oE "Maximum resident set size \(kbytes\): [0-9]+" "$1"|grep -oE "[0-9]+$"); awk -v k="${kb:-0}" 'BEGIN{printf "%.2f",k/1048576}'; }
canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1"|sort -S24G; }

echo "[$(date +%T)] ===== dataset=$DS  ($(du -sh $FACTS|cut -f1)) ====="
for fam in "${FAMILIES[@]}"; do
  flbin="$BASE/flbinX/$fam"; sfbin="$BASE/sfbin/$fam"
  flo="$OUTROOT/floutX/$fam/VarPointsTo.csv"; sfo="$OUTROOT/sfoutX/$fam"; mkdir -p "$sfo"
  if [ ! -x "$flbin" ] || [ ! -x "$sfbin" ]; then echo "$fam: missing binary, skip"; continue; fi
  echo "[$(date +%T)] --- $fam ---"
  fl_wall=1e18; fl_rss=0
  for i in $(seq 1 "$REPEAT"); do
    timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/tmp/fl.t" "$flbin" -w "$WORKERS" > "$BASE/logs/$DS.$fam.flrun.$i.log" 2>&1
    w=$(wall "$OUTROOT/tmp/fl.t"); r=$(rssgb "$OUTROOT/tmp/fl.t")
    awk -v a="$fl_wall" -v b="$w" 'BEGIN{exit !(b+0<a+0)}' && fl_wall=$w
    awk -v a="$fl_rss" -v b="$r" 'BEGIN{exit !(b+0>a+0)}' && fl_rss=$r
  done
  cp "$flo" "$OUTROOT/tmp/fl.csv"; fl_rows=$(wc -l < "$OUTROOT/tmp/fl.csv")
  sf_wall=1e18; sf_rss=0
  for i in $(seq 1 "$REPEAT"); do
    timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/tmp/sf.t" "$sfbin" -j "$JOBS" -F "$FACTS" -D "$sfo" > "$BASE/logs/$DS.$fam.sfrun.$i.log" 2>&1
    w=$(wall "$OUTROOT/tmp/sf.t"); r=$(rssgb "$OUTROOT/tmp/sf.t")
    awk -v a="$sf_wall" -v b="$w" 'BEGIN{exit !(b+0<a+0)}' && sf_wall=$w
    awk -v a="$sf_rss" -v b="$r" 'BEGIN{exit !(b+0>a+0)}' && sf_rss=$r
  done
  cp "$sfo/VarPointsTo.csv" "$OUTROOT/tmp/sf.csv"; sf_rows=$(wc -l < "$OUTROOT/tmp/sf.csv")
  canon "$OUTROOT/tmp/fl.csv" > "$OUTROOT/tmp/a.txt"; canon "$OUTROOT/tmp/sf.csv" > "$OUTROOT/tmp/b.txt"
  only_fl=$(comm -23 "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt"|wc -l); only_sf=$(comm -13 "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt"|wc -l)
  [ "$only_fl" = 0 ] && [ "$only_sf" = 0 ] && correct=MATCH || correct=DIFF
  [ "$fl_rows" = "$sf_rows" ] || correct="${correct}(rowdiff)"
  speed=$(awk -v s="$sf_wall" -v f="$fl_wall" 'BEGIN{if(f>0)printf "%.2f",s/f; else print "NA"}')
  mem=$(awk -v f="$fl_rss" -v s="$sf_rss" 'BEGIN{if(s>0)printf "%.2f",f/s; else print "NA"}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" "$fl_rows" "$fl_wall" "$fl_rss" "$sf_wall" "$sf_rss" "$speed" "$mem" "$correct" "$only_fl" "$only_sf" | tee -a "$RES"
  rm -f "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt" "$OUTROOT/tmp/fl.csv" "$OUTROOT/tmp/sf.csv" "$OUTROOT/tmp"/*.t "$flo" "$sfo/VarPointsTo.csv"
done
echo "[$(date +%T)] ===== $DS DONE ====="
column -t -s $'\t' "$RES"

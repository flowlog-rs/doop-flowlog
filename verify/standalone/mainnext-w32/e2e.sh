#!/usr/bin/env bash
# =====================================================================================
# End-to-end DOOP benchmark: FlowLog (main-next + ord-determinism fix, BATCH mode, -w N)
#                            vs  Soufflé (compiled + run with -j N), on luindex.
#
# Per family: compile both engines (in parallel) -> run both (REPEAT x, min wall taken)
#             -> verbatim byte-exact correctness compare -> record -> free big outputs.
# Resumable: families already present in results/results.tsv are skipped.
# All large artifacts live on /datasets (root fs is tiny); binaries kept for reuse.
# =====================================================================================
set -u
BASE=/home/azureuser/doop-e2e
FLC=/home/azureuser/flowlog-mn/target/release/flowlog-compiler
FACTS=${FACTS:-/datasets/facts/luindex}
OUTROOT=/datasets/doop-e2e
export TMPDIR=/datasets/tmp LC_ALL=C
WORKERS=${WORKERS:-32}          # FlowLog -w  (and Soufflé -j)
JOBS=${JOBS:-32}                # Soufflé -j at compile & run
REPEAT=${REPEAT:-2}             # timed repeats; min wall reported
BUILD_TO=${BUILD_TO:-2400}      # per-compile cap (s)
RUN_TO=${RUN_TO:-5400}          # per-run cap (s)
KEEP_OUTPUTS=${KEEP_OUTPUTS:-0} # 1 = keep VarPointsTo.csv per family

mkdir -p /datasets/tmp "$BASE/flbin" "$BASE/sfbin" "$BASE/logs" "$BASE/results" \
         "$OUTROOT/flout" "$OUTROOT/sfout" "$OUTROOT/tmp"
RES="$BASE/results/results.tsv"
HDR="family\tVPT_rows\tFL_wall_s\tFL_RSS_GB\tSF_wall_s\tSF_RSS_GB\tSFxFL_speedup\tFLoverSF_mem\tcorrect\tonly_FL\tonly_SF"
[ -f "$RES" ] || printf "$HDR\n" > "$RES"

mapfile -t FAMILIES < "$BASE/families.txt"
[ $# -gt 0 ] && FAMILIES=("$@")

wall(){ grep -oE "wall clock.*: .*" "$1" | grep -oE "[0-9:.]+$" | tail -1 \
  | awk -F: 'NF==3{print $1*3600+$2*60+$3} NF==2{print $1*60+$2} NF==1{print $1}'; }
rssgb(){ local kb=$(grep -oE "Maximum resident set size \(kbytes\): [0-9]+" "$1" | grep -oE "[0-9]+$"); awk -v k="${kb:-0}" 'BEGIN{printf "%.2f",k/1048576}'; }
canon(){ sed -e 's/\[/(/g; s/\]/)/g; s/, /,/g; s/,)/)/g' "$1" | sort -S 24G; }

for fam in "${FAMILIES[@]}"; do
  grep -qP "^\Q$fam\E\t" "$RES" && { echo "[$(date +%T)] skip $fam (already done)"; continue; }
  echo "[$(date +%T)] ===== $fam  (avail $(df --output=avail -BG /datasets|tail -1|tr -dc 0-9)G) ====="
  flbin="$BASE/flbin/$fam"; sfbin="$BASE/sfbin/$fam"
  flo="$OUTROOT/flout/$fam"; sfo="$OUTROOT/sfout/$fam"; mkdir -p "$flo" "$sfo"

  # ---------- compile both engines in parallel ----------
  ( t=$SECONDS; timeout $BUILD_TO "$FLC" --mode datalog-batch --str-intern -F "$FACTS" \
      -D "$flo" -o "$flbin" "$BASE/programs/flowlog/$fam.dl" > "$BASE/logs/$fam.flcompile.log" 2>&1
    echo "  FL  compile rc=$? ($((SECONDS-t))s)" ) &
  flcpid=$!
  ( t=$SECONDS; timeout $BUILD_TO souffle -o "$sfbin" -j "$JOBS" \
      "$BASE/programs/souffle/$fam.dl" > "$BASE/logs/$fam.sfcompile.log" 2>&1
    echo "  SF  compile rc=$? ($((SECONDS-t))s)" ) &
  sfcpid=$!
  wait $flcpid; wait $sfcpid
  if [ ! -x "$flbin" ] || [ ! -x "$sfbin" ]; then
    echo "  !! compile failed (FL:$([ -x "$flbin" ]&&echo ok||echo NO) SF:$([ -x "$sfbin" ]&&echo ok||echo NO)) -> skip"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" NA NA NA NA NA NA NA COMPILE_FAIL NA NA >> "$RES"; continue
  fi

  # ---------- FlowLog: batch, -w WORKERS ----------
  fl_wall=1e18; fl_rss=0
  for i in $(seq 1 "$REPEAT"); do
    timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/tmp/fl.t" "$flbin" -w "$WORKERS" > "$BASE/logs/$fam.flrun.$i.log" 2>&1
    w=$(wall "$OUTROOT/tmp/fl.t"); r=$(rssgb "$OUTROOT/tmp/fl.t")
    awk -v a="$fl_wall" -v b="$w" 'BEGIN{exit !(b+0<a+0)}' && fl_wall=$w
    awk -v a="$fl_rss"  -v b="$r" 'BEGIN{exit !(b+0>a+0)}' && fl_rss=$r
  done
  cp "$flo/VarPointsTo.csv" "$OUTROOT/tmp/fl.csv"; fl_rows=$(wc -l < "$OUTROOT/tmp/fl.csv")

  # ---------- Soufflé: -j JOBS ----------
  sf_wall=1e18; sf_rss=0
  for i in $(seq 1 "$REPEAT"); do
    timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/tmp/sf.t" "$sfbin" -j "$JOBS" -F "$FACTS" -D "$sfo" > "$BASE/logs/$fam.sfrun.$i.log" 2>&1
    w=$(wall "$OUTROOT/tmp/sf.t"); r=$(rssgb "$OUTROOT/tmp/sf.t")
    awk -v a="$sf_wall" -v b="$w" 'BEGIN{exit !(b+0<a+0)}' && sf_wall=$w
    awk -v a="$sf_rss"  -v b="$r" 'BEGIN{exit !(b+0>a+0)}' && sf_rss=$r
  done
  cp "$sfo/VarPointsTo.csv" "$OUTROOT/tmp/sf.csv"; sf_rows=$(wc -l < "$OUTROOT/tmp/sf.csv")

  # ---------- verbatim correctness (byte-exact) ----------
  canon "$OUTROOT/tmp/fl.csv" > "$OUTROOT/tmp/a.txt"
  canon "$OUTROOT/tmp/sf.csv" > "$OUTROOT/tmp/b.txt"
  only_fl=$(comm -23 "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt" | wc -l)
  only_sf=$(comm -13 "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt" | wc -l)
  [ "$only_fl" = 0 ] && [ "$only_sf" = 0 ] && correct=MATCH || correct=DIFF
  [ "$fl_rows" = "$sf_rows" ] || correct="${correct}(rowdiff)"

  speed=$(awk -v s="$sf_wall" -v f="$fl_wall" 'BEGIN{if(f>0)printf "%.2f",s/f; else print "NA"}')
  mem=$(awk -v f="$fl_rss" -v s="$sf_rss" 'BEGIN{if(s>0)printf "%.2f",f/s; else print "NA"}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$fam" "$fl_rows" "$fl_wall" "$fl_rss" "$sf_wall" "$sf_rss" "$speed" "$mem" "$correct" "$only_fl" "$only_sf" | tee -a "$RES"

  rm -f "$OUTROOT/tmp/a.txt" "$OUTROOT/tmp/b.txt" "$OUTROOT/tmp/fl.csv" "$OUTROOT/tmp/sf.csv" "$OUTROOT/tmp"/*.t
  if [ "$KEEP_OUTPUTS" = 0 ]; then rm -f "$flo/VarPointsTo.csv" "$sfo/VarPointsTo.csv"; fi
done
echo "[$(date +%T)] ===== ALL DONE ====="
column -t -s $'\t' "$RES"

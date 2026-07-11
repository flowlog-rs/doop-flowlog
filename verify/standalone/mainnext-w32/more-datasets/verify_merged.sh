#!/usr/bin/env bash
# Verify the MERGED #208 ord fix (flowlog main-next @7588f68) on a dataset:
#   (A) within-FlowLog determinism: -w32 run1 == run2 == -w1  (byte-exact, per family)
#   (B) cross-engine: FlowLog -w32 vs Souffle -j32           (byte-exact, per family)
# Uses pre-built flbinMERGED/<fam> (bake /datasets/facts/CURRENT) + sfbin/<fam>.
# Usage: ./verify_merged.sh <dataset> [family ...]
set -u
DS=${1:?usage: verify_merged.sh <dataset> [family ...]}
BASE=${BASE:-/home/azureuser/doop-e2e}
FACTS_ROOT=${FACTS_ROOT:-/datasets/facts}
CUR=$FACTS_ROOT/CURRENT
FACTS=$FACTS_ROOT/$DS
OUTROOT=${OUTROOT:-/datasets/doop-e2e/verifyMERGED}
BIN=$BASE/flbinMERGED
export TMPDIR=${TMPDIR:-/datasets/tmp} LC_ALL=C
WORKERS=32; JOBS=32; RUN_TO=${RUN_TO:-7200}
[ -d "$FACTS" ] || { echo "no dataset $FACTS"; exit 1; }
mkdir -p "$OUTROOT" "$BASE/results" "$BASE/logs"
RES="$BASE/results/verify_merged_$DS.tsv"
printf "family\tFL_w32_r1\tFL_w32_r2\tFL_w1\tSF_j32\tdeterministic\tcross_engine\tonly_FL\tonly_SF\tFL_RSS_GB\tSF_RSS_GB\n" > "$RES"
if [ $# -gt 1 ]; then FAMILIES=("${@:2}"); else mapfile -t FAMILIES < <(ls "$BIN"); fi

canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1" | sort -S16G; }
rssgb(){ local kb=$(grep -oE "Maximum resident set size \(kbytes\): [0-9]+" "$1"|grep -oE "[0-9]+$"); awk -v k="${kb:-0}" 'BEGIN{printf "%.2f",k/1048576}'; }

echo "[$(date +%T)] ===== VERIFY MERGED  dataset=$DS ($(du -sh $FACTS|cut -f1)) ====="
ln -sfn "$FACTS" "$CUR"    # exclusive: point FlowLog's baked symlink at this dataset
for fam in "${FAMILIES[@]}"; do
  flbin="$BIN/$fam"; sfbin="$BASE/sfbin/$fam"
  flo="/datasets/doop-e2e/floutMERGED/$fam/VarPointsTo.csv"
  [ -x "$flbin" ] && [ -x "$sfbin" ] || { echo "$fam: missing binary, skip"; continue; }
  echo "[$(date +%T)] --- $fam ---"
  # FL -w32 run1
  timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/fl1.t" "$flbin" -w $WORKERS > "$BASE/logs/$DS.$fam.m.fl1.log" 2>&1
  canon "$flo" > "$OUTROOT/fl1.txt"; r1=$(wc -l < "$OUTROOT/fl1.txt"); fl_rss=$(rssgb "$OUTROOT/fl1.t")
  # FL -w32 run2
  timeout $RUN_TO "$flbin" -w $WORKERS > "$BASE/logs/$DS.$fam.m.fl2.log" 2>&1
  canon "$flo" > "$OUTROOT/fl2.txt"; r2=$(wc -l < "$OUTROOT/fl2.txt")
  # FL -w1 (optional; NOW1=1 skips the slow single-thread leg — r1==r2 still tests MT determinism)
  if [ "${NOW1:-0}" = 1 ]; then
    cp "$OUTROOT/fl1.txt" "$OUTROOT/flw1.txt"; rw1="skip"
  else
    timeout $RUN_TO "$flbin" -w 1 > "$BASE/logs/$DS.$fam.m.flw1.log" 2>&1
    canon "$flo" > "$OUTROOT/flw1.txt"; rw1=$(wc -l < "$OUTROOT/flw1.txt")
  fi
  # Souffle -j32
  sfo="$OUTROOT/sf/$fam"; mkdir -p "$sfo"
  timeout $RUN_TO /usr/bin/time -v -o "$OUTROOT/sf.t" "$sfbin" -j $JOBS -F "$FACTS" -D "$sfo" > "$BASE/logs/$DS.$fam.m.sf.log" 2>&1
  canon "$sfo/VarPointsTo.csv" > "$OUTROOT/sf.txt"; sfr=$(wc -l < "$OUTROOT/sf.txt"); sf_rss=$(rssgb "$OUTROOT/sf.t")
  # (A) determinism: r1==r2==w1 byte-exact
  d12=$(cmp -s "$OUTROOT/fl1.txt" "$OUTROOT/fl2.txt" && echo Y || echo N)
  d1w=$(cmp -s "$OUTROOT/fl1.txt" "$OUTROOT/flw1.txt" && echo Y || echo N)
  [ "$d12" = Y ] && [ "$d1w" = Y ] && det="DET" || det="NONDET(r1==r2:$d12,r1==w1:$d1w)"
  # (B) cross-engine
  of=$(comm -23 "$OUTROOT/fl1.txt" "$OUTROOT/sf.txt"|wc -l); os=$(comm -13 "$OUTROOT/fl1.txt" "$OUTROOT/sf.txt"|wc -l)
  [ "$of" = 0 ] && [ "$os" = 0 ] && ce="BYTE-EXACT" || ce="DIFF"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" "$r1" "$r2" "$rw1" "$sfr" "$det" "$ce" "$of" "$os" "$fl_rss" "$sf_rss" | tee -a "$RES"
  rm -f "$OUTROOT"/fl1.txt "$OUTROOT"/fl2.txt "$OUTROOT"/flw1.txt "$OUTROOT"/sf.txt "$OUTROOT"/*.t "$flo" "$sfo/VarPointsTo.csv"
done
echo "[$(date +%T)] ===== $DS DONE ====="
column -t -s $'\t' "$RES"

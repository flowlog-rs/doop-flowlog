#!/usr/bin/env bash
# Correctness (deterministic): compare W3-fused FL at -w1 vs the Souffle oracle,
# byte-exact. Souffle output is thread-count-independent, so -j32 (fast) is used
# as the oracle. -w1 avoids the ord-nondeterminism of nemo/tuple's parallel path
# (it lacks flowlog #208), isolating the FUSED PLAN's correctness.
set -u
B=/datasets/w3test
FACTS=/datasets/facts/luindex
export TMPDIR=/datasets/tmp LC_ALL=C
mkdir -p "$B/sfout_o" "$B/results"
RES="$B/results/w3_correctness.tsv"
printf "family\tW3_w1_rows\tSF_rows\tonly_W3\tonly_SF\tverdict\n" > "$RES"

# family|w3_bin|w3_out_dir|sf_bin
SPECS=(
 "1-object-1-type-sensitive+heap|flbin_w3/1-object-1-type-sensitive+heap|flout_w3/1-object-1-type-sensitive+heap|sfbin/1-object-1-type-sensitive+heap"
 "2-type-object-sensitive+heap|flbin_w3/2-type-object-sensitive+heap|flout_w3/2-type-object-sensitive+heap|sfbin/2tobj"
 "2-type-object-sensitive+2-heap|flbin_w3/2-type-object-sensitive+2-heap|flout_w3/2-type-object-sensitive+2-heap|sfbin/2-type-object-sensitive+2-heap"
)
canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1"|sort -S16G; }

for spec in "${SPECS[@]}"; do
  IFS='|' read -r fam wbin wout sfbin <<< "$spec"
  sfo="$B/sfout_o/$fam"; mkdir -p "$sfo" "$B/$wout"
  echo "[$(date +%T)] === $fam ==="
  wcsv="$B/$wout/VarPointsTo.csv"
  if [ ! -s "$wcsv" ]; then
    echo "  running W3 -w1 ..."; "$B/$wbin" -w 1 > "$B/results/$fam.w3.w1b.log" 2>&1
  else
    echo "  reusing existing W3 -w1 output"
  fi
  wr=$(wc -l < "$wcsv")
  "$sfbin" -j 32 -F "$FACTS" -D "$sfo" > "$B/results/$fam.sf.j32o.log" 2>&1
  sr=$(wc -l < "$sfo/VarPointsTo.csv")
  canon "$wcsv" > "$TMPDIR/wc.txt"; canon "$sfo/VarPointsTo.csv" > "$TMPDIR/sc.txt"
  ow=$(comm -23 "$TMPDIR/wc.txt" "$TMPDIR/sc.txt" | wc -l)
  os=$(comm -13 "$TMPDIR/wc.txt" "$TMPDIR/sc.txt" | wc -l)
  v=$([ "$ow" = 0 ] && [ "$os" = 0 ] && echo BYTE_EXACT || echo DIFF)
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" "$wr" "$sr" "$ow" "$os" "$v" | tee -a "$RES"
  rm -f "$TMPDIR/wc.txt" "$TMPDIR/sc.txt" "$wcsv" "$sfo/VarPointsTo.csv"
done
echo "[$(date +%T)] === correctness DONE ==="
column -t -s $'\t' "$RES"

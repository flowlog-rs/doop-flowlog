#!/usr/bin/env bash
# w3 A/B run: for each of the 3 type-object families, run base FL, w3 FL, and
# Souffle at -w32/-j32; capture wall + peak RSS + rows; byte-exact compare
# (w3 vs Souffle, and w3 vs base — both should be identical output).
# FL binaries bake fact dir (luindex) + output dir at compile; just run -w N.
set -u
B=/datasets/w3test
FACTS=/datasets/facts/luindex
export TMPDIR=/datasets/tmp LC_ALL=C
W=${W:-32}
mkdir -p "$B/sfout" "$B/results" "$TMPDIR"
RES="$B/results/w3_ab.tsv"
printf "family\trows\tBASE_s\tBASE_GB\tW3_s\tW3_GB\tSF_s\tSF_GB\tW3_vs_BASE_speedup\tW3_vs_SF\tW3==SF\tW3==BASE\n" > "$RES"

# family : base_bin : base_out : w3_bin : w3_out   (out = dir holding VarPointsTo.csv)
SPECS=(
 "1-object-1-type-sensitive+heap|flbin_base/1-object-1-type-sensitive+heap|flout_base/1-object-1-type-sensitive+heap|flbin_w3/1-object-1-type-sensitive+heap|flout_w3/1-object-1-type-sensitive+heap"
 "2-type-object-sensitive+heap|flbin_base/2tobj|flout_base/2tobj|flbin_w3/2-type-object-sensitive+heap|flout_w3/2-type-object-sensitive+heap"
 "2-type-object-sensitive+2-heap|flbin_base/2-type-object-sensitive+2-heap|flout_base/2-type-object-sensitive+2-heap|flbin_w3/2-type-object-sensitive+2-heap|flout_w3/2-type-object-sensitive+2-heap"
)
wall(){ grep -oE "wall clock.*: .*" "$1"|grep -oE "[0-9:.]+$"|tail -1|awk -F: 'NF==3{print $1*3600+$2*60+$3}NF==2{print $1*60+$2}NF==1{print $1}'; }
rssgb(){ local kb=$(grep -oE "Maximum resident set size \(kbytes\): [0-9]+" "$1"|grep -oE "[0-9]+$"); awk -v k="${kb:-0}" 'BEGIN{printf "%.2f",k/1048576}'; }
canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1"|sort -S16G; }

for spec in "${SPECS[@]}"; do
  IFS='|' read -r fam bbin bout wbin wout <<< "$spec"
  sfbin="$B/sfbin/$fam"; [ -x "$sfbin" ] || sfbin="$B/sfbin/2tobj"   # 2-type-object-sensitive+heap SF binary is named 2tobj
  sfo="$B/sfout/$fam"; mkdir -p "$sfo" "$B/$bout" "$B/$wout"
  echo "[$(date +%T)] ===== $fam ====="

  # BASE FL (1 run; it's the slow cross-join baseline)
  /usr/bin/time -v -o "$TMPDIR/b.t" "$B/$bbin" -w "$W" > "$B/results/$fam.base.run.log" 2>&1
  bs=$(wall "$TMPDIR/b.t"); bg=$(rssgb "$TMPDIR/b.t"); cp "$B/$bout/VarPointsTo.csv" "$TMPDIR/base.csv"

  # W3 FL (2 runs, min)
  w3s=1e18; w3g=0
  for i in 1 2; do
    /usr/bin/time -v -o "$TMPDIR/w.t" "$B/$wbin" -w "$W" > "$B/results/$fam.w3.run.$i.log" 2>&1
    x=$(wall "$TMPDIR/w.t"); g=$(rssgb "$TMPDIR/w.t")
    awk -v a="$w3s" -v b="$x" 'BEGIN{exit !(b+0<a+0)}' && w3s=$x
    awk -v a="$w3g" -v b="$g" 'BEGIN{exit !(b+0>a+0)}' && w3g=$g
  done
  cp "$B/$wout/VarPointsTo.csv" "$TMPDIR/w3.csv"; rows=$(wc -l < "$TMPDIR/w3.csv")

  # Souffle (2 runs, min)
  sfs=1e18; sfg=0
  for i in 1 2; do
    /usr/bin/time -v -o "$TMPDIR/s.t" "$sfbin" -j "$W" -F "$FACTS" -D "$sfo" > "$B/results/$fam.sf.run.$i.log" 2>&1
    x=$(wall "$TMPDIR/s.t"); g=$(rssgb "$TMPDIR/s.t")
    awk -v a="$sfs" -v b="$x" 'BEGIN{exit !(b+0<a+0)}' && sfs=$x
    awk -v a="$sfg" -v b="$g" 'BEGIN{exit !(b+0>a+0)}' && sfg=$g
  done
  cp "$sfo/VarPointsTo.csv" "$TMPDIR/sf.csv"

  # byte-exact
  canon "$TMPDIR/w3.csv" > "$TMPDIR/w.txt"; canon "$TMPDIR/sf.csv" > "$TMPDIR/s.txt"; canon "$TMPDIR/base.csv" > "$TMPDIR/b.txt"
  w_sf=$([ "$(comm -3 "$TMPDIR/w.txt" "$TMPDIR/s.txt" | wc -l)" = 0 ] && echo MATCH || echo DIFF)
  w_b=$([ "$(comm -3 "$TMPDIR/w.txt" "$TMPDIR/b.txt" | wc -l)" = 0 ] && echo MATCH || echo DIFF)
  spd=$(awk -v b="$bs" -v w="$w3s" 'BEGIN{if(w>0)printf "%.1f",b/w; else print "NA"}')
  wsf=$(awk -v s="$sfs" -v w="$w3s" 'BEGIN{if(w>0)printf "%.2f",s/w; else print "NA"}')
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$fam" "$rows" "$bs" "$bg" "$w3s" "$w3g" "$sfs" "$sfg" "$spd" "$wsf" "$w_sf" "$w_b" | tee -a "$RES"
  rm -f "$TMPDIR"/*.csv "$TMPDIR"/*.txt "$TMPDIR"/*.t "$B/$bout/VarPointsTo.csv" "$B/$wout/VarPointsTo.csv" "$sfo/VarPointsTo.csv"
done
echo "[$(date +%T)] ===== w3 A/B DONE ====="
column -t -s $'\t' "$RES"

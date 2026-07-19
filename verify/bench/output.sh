#!/usr/bin/env bash
# output.sh — CORRECTNESS benchmark. Runs FlowLog and Soufflé (no .plan) with
# the FULL DOOP output set materialized to CSV, end to end, then compares every
# output relation BYTE-FOR-BYTE (after canonicalising record/tuple brackets and
# sorting). Single-threaded on both sides — heap representatives are
# intern/thread-order dependent, so byte equality requires one worker.
#
# (.plan is irrelevant to output, so only the no-plan Soufflé variant is used.)
#
# Consumes the STANDALONE programs in programs/ — no repo/cpp/DOOP needed.
# Correctness is already established for the core set; run this to re-confirm
# on a chosen (family, dataset), or as a spot-check on new inputs.
#
#   FLC=/path/to/flowlog-compiler FACTS_ROOT=/data/facts \
#     verify/bench/output.sh 2-object-sensitive+heap   # families as args
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"
FAMILIES=($FAMILIES); DATASETS=($DATASETS)
[[ $# -gt 0 ]] && FAMILIES=("$@")
PROG="$HERE/programs"
export LC_ALL=C
WORKERS=1; JOBS=1   # byte-exact requires single-threaded on both engines

FACTS_ROOT="${FACTS_ROOT:-}"
OUTDIR="${OUTDIR:-$PWD}"
WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/flout.XXXXXX")}"
RES="$OUTDIR/output_$(hostname -s 2>/dev/null || echo host).tsv"

die(){ echo "output.sh: $*" >&2; exit 2; }
[[ -n "$FACTS_ROOT" && -d "$FACTS_ROOT" ]] || die "set FACTS_ROOT to the dir holding your dataset subdirs."
[[ -n "$FLC" && -x "$FLC" ]] || die "need FLC=flowlog-compiler binary."
command -v "$SOUFFLE" >/dev/null 2>&1 || die "need souffle on PATH."
mkdir -p "$OUTDIR" "$WORKDIR"

facts_of(){ local d="$FACTS_ROOT/$1"; ls "$d"/*.facts >/dev/null 2>&1 && { echo "$d"; return; }
            ls "$d/facts"/*.facts >/dev/null 2>&1 && { echo "$d/facts"; return; }; echo ""; }
# souffle records [a,b] -> flowlog tuples (a,b); drop comma-spaces; sort
canon(){ sed -e 's/\[/(/g; s/\]/)/g; s/, /,/g; s/,)/)/g' "$1" | sort -S 20%; }

echo -e "dataset\tfamily\trelations\tmatched\tmismatched\tmissing\tverdict\tfirst_mismatch" > "$RES"
echo "[$(date +%H:%M:%S)] output START (byte-exact, -w1/-j1)  families=${#FAMILIES[@]} datasets=${DATASETS[*]}" >&2
LINK="$WORKDIR/facts.link"

for fam in "${FAMILIES[@]}"; do
  first=$(facts_of "${DATASETS[0]}"); [[ -n "$first" ]] || die "no facts for ${DATASETS[0]}."
  ln -sfn "$first" "$LINK"; mkdir -p "$WORKDIR/flo"
  flbin=""; sfbin=""
  timeout "$BUILD_TO" "$FLC" ${STR_INTERN:+--str-intern} ${FL_BUILD_DIR:+-B "$FL_BUILD_DIR"} $FLC_FLAGS -F "$LINK" -D "$WORKDIR/flo" -o "$WORKDIR/flbin" "$PROG/$fam.flowlog.dl" >"$WORKDIR/flb.log" 2>&1
  [[ -x "$WORKDIR/flbin" ]] && flbin="$WORKDIR/flbin"
  timeout "$BUILD_TO" "$SOUFFLE" $SOUFFLE_FLAGS -o "$WORKDIR/sfbin" "$PROG/$fam.souffle-noplan.dl" >"$WORKDIR/sfb.log" 2>&1
  [[ -x "$WORKDIR/sfbin" ]] && sfbin="$WORKDIR/sfbin"
  [[ -n "$flbin" && -n "$sfbin" ]] || { echo -e "${DATASETS[0]}\t$fam\tNA\tNA\tNA\tNA\tBUILD_FAIL\t-" >>"$RES"; echo "[$(date +%H:%M:%S)] $fam BUILD_FAIL" >&2; continue; }

  for ds in "${DATASETS[@]}"; do
    facts=$(facts_of "$ds"); [[ -n "$facts" ]] || { echo -e "$ds\t$fam\tNA\tNA\tNA\tNA\tNO_FACTS\t-" >>"$RES"; continue; }
    rm -rf "$WORKDIR/flo" "$WORKDIR/sfo"; mkdir -p "$WORKDIR/flo" "$WORKDIR/sfo"
    ln -sfn "$facts" "$LINK"
    timeout "$RUN_TO" "$flbin" -w 1 >/dev/null 2>&1; flrc=$?
    timeout "$RUN_TO" "$sfbin" -j 1 -F "$facts" -D "$WORKDIR/sfo" >/dev/null 2>&1; sfrc=$?
    if [[ $flrc -ne 0 || $sfrc -ne 0 ]]; then
      echo -e "$ds\t$fam\tNA\tNA\tNA\tNA\tRUN_FAIL(fl=$flrc,sf=$sfrc)\t-" >>"$RES"
      echo "[$(date +%H:%M:%S)] $fam @ $ds RUN_FAIL fl=$flrc sf=$sfrc" >&2; continue
    fi
    # compare every relation Souffle emitted; FlowLog may namespace (mainAnalysis.Rel.csv)
    rels=0; ok=0; bad=0; miss=0; firstbad="-"
    for sfcsv in "$WORKDIR/sfo"/*.csv; do
      [[ -e "$sfcsv" ]] || continue
      rel=$(basename "$sfcsv" .csv); rels=$((rels+1))
      flcsv="$WORKDIR/flo/$rel.csv"; [[ -e "$flcsv" ]] || flcsv=$(ls "$WORKDIR/flo/"*".$rel.csv" 2>/dev/null | head -1)
      if [[ -z "$flcsv" || ! -e "$flcsv" ]]; then
        # FlowLog doesn't materialize a CSV for an empty relation; a match iff
        # Soufflé's file is also empty (both zero tuples). Otherwise a real miss.
        if [[ ! -s "$sfcsv" ]]; then ok=$((ok+1)); else miss=$((miss+1)); [[ "$firstbad" == - ]] && firstbad="$rel(missing)"; fi
        continue
      fi
      if cmp -s <(canon "$flcsv") <(canon "$sfcsv"); then ok=$((ok+1)); else bad=$((bad+1)); [[ "$firstbad" == - ]] && firstbad="$rel"; fi
    done
    verdict=MATCH; { [[ $bad -gt 0 || $miss -gt 0 ]] && verdict=DIFF; }
    echo -e "$ds\t$fam\t$rels\t$ok\t$bad\t$miss\t$verdict\t$firstbad" >>"$RES"
    echo "[$(date +%H:%M:%S)] $fam @ $ds  $verdict  ($ok/$rels relations byte-exact; $bad diff, $miss missing)" >&2
  done
  rm -f "$WORKDIR/flbin" "$WORKDIR/sfbin" "$WORKDIR/sfbin.cpp"
done
echo "[$(date +%H:%M:%S)] output DONE -> $RES" >&2
if [[ "$KEEP_WORK" == 1 ]]; then echo "kept WORKDIR=$WORKDIR" >&2; else rm -f "$LINK"; rm -rf "$WORKDIR"; fi

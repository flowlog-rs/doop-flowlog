#!/usr/bin/env bash
# verify.sh — FlowLog vs Soufflé byte-exact correctness check.
#
# For every supported analysis family: assemble + build + run the analysis on
# BOTH FlowLog and Soufflé over the same DaCapo fact set, then byte-exact-diff
# the VarPointsTo output. Works on any DaCapo benchmark — just point FACTS at
# that benchmark's DOOP-generated fact directory.
#
# Self-contained and portable: writes only under $WORKDIR / $OUTDIR (no root, no
# system writes), tolerates per-family build/run failures (timeout/OOM/error),
# and frees scratch after each family. Configure entirely via env vars below.
#
#   Required:
#     FLC=/path/to/flowlog-compiler     # the FlowLog compiler binary
#     FACTS=/path/to/<benchmark>/facts  # DOOP-generated EDB for one benchmark
#       (or set FACTS_ROOT=/path/to/facts and BENCHMARK=luindex)
#   Common:
#     SOUFFLE=souffle      WORKERS=1 (flowlog -w)   JOBS=1 (souffle -j)
#     DATASET=<label>      (default: basename of FACTS, used in output filename)
#     OUTDIR=.             (where the results TSV is written)
#   Tuning (seconds): BUILD_TO=3600  FL_RUN_TO=3600  SF_RUN_TO=3600
#
#   Usage:  FLC=... FACTS=... ./verify.sh [family ...]
#           (no family args → runs the full supported set)
#
# Notes:
#  * Soufflé .plan directives are stripped (they don't affect OUTPUT, only join
#    scheduling, and the stripped single-output programs build reliably). For a
#    PERFORMANCE comparison rather than a correctness one, keep them
#    (SOUFFLE_KEEP_PLAN=1) and expect Soufflé to schedule differently.
#  * Both engines run single-threaded by default (WORKERS=1 / JOBS=1): heap
#    representatives are intern-order/thread-count dependent, so byte-exact
#    equality needs a single thread on both sides.
set -uo pipefail

# ---------------------------------------------------------------- configuration
REPO="${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
FLC="${FLC:-}"
SOUFFLE="${SOUFFLE:-souffle}"
if [[ -z "${FACTS:-}" && -n "${FACTS_ROOT:-}" ]]; then FACTS="${FACTS_ROOT%/}/${BENCHMARK:-}"; fi
FACTS="${FACTS:-}"
DATASET="${DATASET:-$( [[ -n "$FACTS" ]] && basename "$FACTS" || echo unknown )}"
WORKERS="${WORKERS:-1}"
JOBS="${JOBS:-1}"
OUTDIR="${OUTDIR:-$PWD}"
WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/flverify.XXXXXX")}"
BUILD_TO="${BUILD_TO:-3600}"
FL_RUN_TO="${FL_RUN_TO:-3600}"
SF_RUN_TO="${SF_RUN_TO:-3600}"
MIN_AVAIL_KB="${MIN_AVAIL_KB:-15000000}"   # free-space floor for $WORKDIR
SOUFFLE_KEEP_PLAN="${SOUFFLE_KEEP_PLAN:-0}"
export LC_ALL=C

# Supported "can-run" families (override by passing families as CLI args).
DEFAULT_FAMILIES=(
  context-insensitive
  1-type-sensitive 1-type-sensitive+heap
  1-call-site-sensitive 1-call-site-sensitive+heap
  1-object-sensitive 1-object-sensitive+heap
  1-object-1-type-sensitive+heap
  2-type-sensitive+heap
  2-type-object-sensitive+heap 2-type-object-sensitive+2-heap
  2-object-sensitive+heap 2-object-sensitive+2-heap
  2-call-site-sensitive+heap 2-call-site-sensitive+2-heap
  3-type-sensitive+2-heap 3-type-sensitive+3-heap
  3-object-sensitive+2-heap 3-object-sensitive+3-heap
  4-object-sensitive+4-heap
  adaptive-2-object-sensitive+heap
  sticky-2-object-sensitive
  selective-2-object-sensitive+heap
  partitioned-2-object-sensitive+heap
)
if [[ $# -gt 0 ]]; then FAMILIES=("$@"); else FAMILIES=("${DEFAULT_FAMILIES[@]}"); fi

# ------------------------------------------------------------------- preflight
die(){ echo "verify.sh: $*" >&2; exit 2; }
[[ -n "$FLC"   ]] || die "FLC is unset — point it at the flowlog-compiler binary."
[[ -x "$FLC"   ]] || die "FLC '$FLC' is not an executable."
[[ -n "$FACTS" ]] || die "FACTS is unset — point it at a benchmark's fact dir (or set FACTS_ROOT+BENCHMARK)."
[[ -d "$FACTS" ]] || die "FACTS '$FACTS' is not a directory."
ls "$FACTS"/*.facts >/dev/null 2>&1 || die "FACTS '$FACTS' contains no .facts files."
[[ -d "$REPO/flowlog-logic" && -d "$REPO/souffle-logic" ]] || die "REPO '$REPO' lacks flowlog-logic/ + souffle-logic/."
HAVE_SOUFFLE=1; command -v "$SOUFFLE" >/dev/null 2>&1 || { HAVE_SOUFFLE=0; echo "verify.sh: WARN '$SOUFFLE' not found — running FlowLog only, no comparison." >&2; }
TIME=""; command -v /usr/bin/time >/dev/null 2>&1 && TIME="/usr/bin/time -v"
mkdir -p "$OUTDIR" "$WORKDIR"
RES="$OUTDIR/verify_${DATASET}.tsv"

# unify souffle [a,b] records vs flowlog (a,b) tuples, drop comma-spaces; then sort
canon(){ sed -e 's/\[/(/g; s/\]/)/g; s/, /,/g; s/,)/)/g' "$1" | sort -S 25%; }
avail_kb(){ df -Pk "$WORKDIR" | tail -1 | awk '{print $4}'; }
wall_of(){ grep -i 'Elapsed (wall clock)' "$1" 2>/dev/null | grep -oE '[0-9:.]+$' | tail -1 \
           | awk -F: '{if(NF==2)printf "%.0f",$1*60+$2; else printf "%.0f",$1}'; }
# per-family extra cpp defines (types-only is a non-points-to config)
extra_defs(){ case "$1" in types-only) echo "-DDISABLE_POINTS_TO" ;; *) echo "" ;; esac; }

echo -e "family\tfl_build\tfl_run\tfl_sec\tfl_vpt\tsf_build\tsf_run\tsf_sec\tsf_vpt\tonly_fl\tonly_sf\tboth\tverdict" > "$RES"
echo "[$(date +%H:%M:%S)] verify START  dataset=$DATASET  families=${#FAMILIES[@]}  flowlog -w$WORKERS / souffle -j$JOBS" >&2
echo "  REPO=$REPO" >&2; echo "  FLC=$FLC" >&2; echo "  FACTS=$FACTS" >&2; echo "  results -> $RES" >&2

for fam in "${FAMILIES[@]}"; do
  t0=$SECONDS
  ana="$REPO/souffle-logic/analyses/$fam/analysis.dl"
  [[ -f "$ana" ]] || { echo -e "$fam\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNO_SUCH_FAMILY" >>"$RES"; echo "[$(date +%H:%M:%S)] $fam -> NO_SUCH_FAMILY" >&2; continue; }
  if [[ "$(avail_kb)" -lt "$MIN_AVAIL_KB" ]]; then rm -rf "$WORKDIR"/out_* "$WORKDIR"/sfout_* "$WORKDIR"/bin_* "$WORKDIR"/sfbin_*; fi
  cfg=$(grep -hoE '\.comp +\w+ *: *AbstractConfiguration' "$ana" | head -1 | sed -E 's/\.comp +(\w+).*/\1/')
  [[ -n "$cfg" ]] || { echo -e "$fam\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNA\tNO_CONFIG" >>"$RES"; echo "[$(date +%H:%M:%S)] $fam -> NO_CONFIG" >&2; continue; }
  defs="-DCONFIGURATION=$cfg $(extra_defs "$fam")"
  flb=NA; flr=NA; flsec=NA; flvpt=NA; sfb=NA; sfr=NA; sfsec=NA; sfvpt=NA; ofl=NA; osf=NA; both=NA; verdict=NA

  # ---------- FlowLog ----------
  A="$WORKDIR/$fam.fl.dl"
  cpp -P $defs "$REPO/flowlog-logic/facts/facts.dl"  >  "$A" 2>/dev/null
  cpp -P $defs "$REPO/flowlog-logic/basic/basic.dl"  >> "$A" 2>/dev/null
  cpp -P $defs "$REPO/flowlog-logic/analyses/$fam/analysis.dl" >> "$A" 2>/dev/null
  sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' "$A"
  mkdir -p "$WORKDIR/out_$fam"
  timeout "$BUILD_TO" "$FLC" --str-intern -F "$FACTS" -D "$WORKDIR/out_$fam" -o "$WORKDIR/bin_$fam" "$A" > "$WORKDIR/$fam.flbuild.log" 2>&1; flb=$?
  if [[ -x "$WORKDIR/bin_$fam" ]]; then
    timeout "$FL_RUN_TO" $TIME "$WORKDIR/bin_$fam" -w "$WORKERS" > "$WORKDIR/$fam.flrun.log" 2>&1; flr=$?
    flsec=$(wall_of "$WORKDIR/$fam.flrun.log"); flsec=${flsec:-NA}
  fi
  [[ -f "$WORKDIR/out_$fam/VarPointsTo.csv" ]] && flvpt=$(wc -l < "$WORKDIR/out_$fam/VarPointsTo.csv")

  # ---------- Soufflé ----------
  if [[ $HAVE_SOUFFLE -eq 1 ]]; then
    SA="$WORKDIR/$fam.sf.dl"
    cpp -P $defs "$REPO/souffle-logic/facts/facts.dl"  >  "$SA" 2>/dev/null
    cpp -P $defs "$REPO/souffle-logic/basic/basic.dl"  >> "$SA" 2>/dev/null
    cpp -P $defs "$REPO/souffle-logic/analyses/$fam/analysis.dl" >> "$SA" 2>/dev/null
    [[ "$SOUFFLE_KEEP_PLAN" -eq 1 ]] || sed -i -E '/^[[:space:]]*\.plan\b/d; /^[[:space:]]*[0-9]+:\(/d' "$SA"
    sed -i -E '/^[[:space:]]*\.(output|printsize)/{/VarPointsTo/!d}' "$SA"
    timeout "$BUILD_TO" "$SOUFFLE" -c -o "$WORKDIR/sfbin_$fam" "$SA" > "$WORKDIR/$fam.sfbuild.log" 2>&1; sfb=$?
    mkdir -p "$WORKDIR/sfout_$fam"
    if [[ -x "$WORKDIR/sfbin_$fam" ]]; then
      timeout "$SF_RUN_TO" $TIME "$WORKDIR/sfbin_$fam" -j "$JOBS" -F "$FACTS" -D "$WORKDIR/sfout_$fam" > "$WORKDIR/$fam.sfrun.log" 2>&1; sfr=$?
      sfsec=$(wall_of "$WORKDIR/$fam.sfrun.log"); sfsec=${sfsec:-NA}
    fi
    [[ -f "$WORKDIR/sfout_$fam/VarPointsTo.csv" ]] && sfvpt=$(wc -l < "$WORKDIR/sfout_$fam/VarPointsTo.csv")
  fi

  # ---------- compare ----------
  if [[ -f "$WORKDIR/out_$fam/VarPointsTo.csv" && -f "$WORKDIR/sfout_$fam/VarPointsTo.csv" ]]; then
    canon "$WORKDIR/out_$fam/VarPointsTo.csv" > "$WORKDIR/a.txt"
    canon "$WORKDIR/sfout_$fam/VarPointsTo.csv" > "$WORKDIR/b.txt"
    ofl=$(comm -23 "$WORKDIR/a.txt" "$WORKDIR/b.txt" | wc -l)
    osf=$(comm -13 "$WORKDIR/a.txt" "$WORKDIR/b.txt" | wc -l)
    both=$(comm -12 "$WORKDIR/a.txt" "$WORKDIR/b.txt" | wc -l)
    [[ "$ofl" -eq 0 && "$osf" -eq 0 ]] && verdict=MATCH || verdict=DIFF
    rm -f "$WORKDIR/a.txt" "$WORKDIR/b.txt"
  elif [[ -f "$WORKDIR/out_$fam/VarPointsTo.csv" && $HAVE_SOUFFLE -eq 0 ]]; then
    verdict=FLOWLOG_ONLY
  else
    verdict=INCOMPLETE
  fi

  echo -e "$fam\t$flb\t$flr\t$flsec\t$flvpt\t$sfb\t$sfr\t$sfsec\t$sfvpt\t$ofl\t$osf\t$both\t$verdict" >> "$RES"
  echo "[$(date +%H:%M:%S)] $fam -> $verdict  fl=$flvpt sf=$sfvpt (fl ${flsec}s / sf ${sfsec}s)  in $((SECONDS-t0))s" >&2
  rm -rf "$WORKDIR/out_$fam" "$WORKDIR/sfout_$fam" "$WORKDIR/bin_$fam" "$WORKDIR/sfbin_$fam" "$WORKDIR/sfbin_$fam.cpp" "$A" "${SA:-/nonexistent}"
done

echo "[$(date +%H:%M:%S)] verify DONE — results in $RES" >&2
echo "=== summary ($DATASET) ===" >&2
tail -n +2 "$RES" | cut -f13 | sort | uniq -c >&2
rmdir "$WORKDIR" 2>/dev/null || true

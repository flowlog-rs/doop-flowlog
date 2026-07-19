#!/usr/bin/env bash
# time.sh — TIMING benchmark. FlowLog vs Soufflé (with/without .plan) over the
# configured families × datasets, at 32 threads by default. Times the analysis
# with `.printsize` output (tuple count only, NO CSV serialization) so the
# number is pure fixpoint compute. A minimal correctness check compares the
# VarPointsTo tuple count across engines.
#
# Consumes the STANDALONE programs in programs/ — no repo/cpp/DOOP needed.
#
#   FLC=/path/to/flowlog-compiler FACTS_ROOT=/data/facts verify/bench/time.sh
#
# Writes time_<host>.tsv: one row per (dataset, family) with, per engine,
# compile wall/RSS and median run wall/RSS, plus VarPointsTo counts + verdict.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/config.sh"
FAMILIES=($FAMILIES); DATASETS=($DATASETS)
[[ $# -gt 0 ]] && FAMILIES=("$@")
PROG="$HERE/programs"
export LC_ALL=C

FACTS_ROOT="${FACTS_ROOT:-}"
OUTDIR="${OUTDIR:-$PWD}"
WORKDIR="${WORKDIR:-$(mktemp -d "${TMPDIR:-/tmp}/fltime.XXXXXX")}"
RES="$OUTDIR/time_$(hostname -s 2>/dev/null || echo host).tsv"

die(){ echo "time.sh: $*" >&2; exit 2; }
[[ -n "$FACTS_ROOT" && -d "$FACTS_ROOT" ]] || die "set FACTS_ROOT to the dir holding your dataset subdirs."
[[ "$RUN_FLOWLOG" == 1 ]] && { [[ -n "$FLC" && -x "$FLC" ]] || die "RUN_FLOWLOG=1 needs FLC=flowlog-compiler binary."; }
HAVE_SF=1; command -v "$SOUFFLE" >/dev/null 2>&1 || HAVE_SF=0
TIME=""; command -v /usr/bin/time >/dev/null 2>&1 && TIME="/usr/bin/time -v"
mkdir -p "$OUTDIR" "$WORKDIR"
# optional per-run memory cap (systemd-run --scope); --user when non-root
CAP=""
if [[ -n "$MEM_MAX" ]] && command -v systemd-run >/dev/null 2>&1; then
  [[ $EUID -ne 0 ]] && U="--user" || U=""
  CAP="systemd-run --scope -q $U -p MemoryMax=$MEM_MAX -p MemorySwapMax=0 --"
fi

# resolve a dataset name to its facts directory (dir, or dir/facts child)
facts_of(){ local d="$FACTS_ROOT/$1"; ls "$d"/*.facts >/dev/null 2>&1 && { echo "$d"; return; }
            ls "$d/facts"/*.facts >/dev/null 2>&1 && { echo "$d/facts"; return; }; echo ""; }
wall_of(){ grep -i 'Elapsed (wall clock)' "$1" 2>/dev/null | grep -oE '[0-9:.]+$' | tail -1 \
           | awk -F: '{if(NF==3)printf "%.0f",$1*3600+$2*60+$3; else if(NF==2)printf "%.0f",$1*60+$2; else printf "%.0f",$1}'; }
rss_of(){ grep -i 'Maximum resident' "$1" 2>/dev/null | grep -oE '[0-9]+' | tail -1 | awk '{printf "%d",$1/1024}'; }
median(){ printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{if(NR)print a[int((NR+1)/2)]}'; }
# turn every .output into .printsize (count only, no serialization)
to_printsize(){ sed -E 's/^[[:space:]]*\.output[[:space:]]+([A-Za-z0-9_.]+).*/.printsize \1/' "$1" > "$2"; }

hdr="dataset\tfamily"
for e in fl sfnp sfpl; do hdr="$hdr\t${e}_build_s\t${e}_build_rss\t${e}_run_s\t${e}_run_rss\t${e}_vpt"; done
hdr="$hdr\tverdict"
echo -e "$hdr" > "$RES"
echo "[$(date +%H:%M:%S)] time START  families=${#FAMILIES[@]} datasets=${DATASETS[*]}  -w$WORKERS/-j$JOBS REPS=$REPS  -> $RES" >&2

# build once per (family,engine) against a symlink; repoint per dataset
LINK="$WORKDIR/facts.link"; first=$(facts_of "${DATASETS[0]}")
[[ -n "$first" ]] || die "no facts for first dataset '${DATASETS[0]}' under $FACTS_ROOT."

fl_count(){ local d="$1"; local f; f=$(ls "$d"/*VarPointsTo.csv 2>/dev/null | head -1); [[ -n "$f" ]] && tr -dc '0-9' <"$f" || echo NA; }
sf_count(){ grep -aP '(^|\.)VarPointsTo\t' "$1" 2>/dev/null | head -1 | cut -f2 | tr -dc '0-9' || echo NA; }

for fam in "${FAMILIES[@]}"; do
  flb=NA;flbr=NA;sfnpb=NA;sfnpbr=NA;sfplb=NA;sfplbr=NA
  flbin=""; sfnpbin=""; sfplbin=""
  # ---- builds (once per family) ----
  if [[ "$RUN_FLOWLOG" == 1 ]]; then
    to_printsize "$PROG/$fam.flowlog.dl" "$WORKDIR/$fam.fl.ps.dl"
    ln -sfn "$first" "$LINK"; mkdir -p "$WORKDIR/flo_$fam"
    timeout "$BUILD_TO" $TIME "$FLC" ${STR_INTERN:+--str-intern} ${FL_BUILD_DIR:+-B "$FL_BUILD_DIR"} $FLC_FLAGS -F "$LINK" -D "$WORKDIR/flo_$fam" -o "$WORKDIR/flbin_$fam" "$WORKDIR/$fam.fl.ps.dl" >"$WORKDIR/$fam.flb.log" 2>&1
    [[ -x "$WORKDIR/flbin_$fam" ]] && { flbin="$WORKDIR/flbin_$fam"; flb=$(wall_of "$WORKDIR/$fam.flb.log"); flbr=$(rss_of "$WORKDIR/$fam.flb.log"); }
  fi
  if [[ "$HAVE_SF" == 1 && "$RUN_SOUFFLE_NOPLAN" == 1 ]]; then
    to_printsize "$PROG/$fam.souffle-noplan.dl" "$WORKDIR/$fam.sfnp.ps.dl"
    timeout "$BUILD_TO" $TIME "$SOUFFLE" -j "$JOBS" $SOUFFLE_FLAGS -o "$WORKDIR/sfnpbin_$fam" "$WORKDIR/$fam.sfnp.ps.dl" >"$WORKDIR/$fam.sfnpb.log" 2>&1
    [[ -x "$WORKDIR/sfnpbin_$fam" ]] && { sfnpbin="$WORKDIR/sfnpbin_$fam"; sfnpb=$(wall_of "$WORKDIR/$fam.sfnpb.log"); sfnpbr=$(rss_of "$WORKDIR/$fam.sfnpb.log"); }
  fi
  if [[ "$HAVE_SF" == 1 && "$RUN_SOUFFLE_PLAN" == 1 ]]; then
    to_printsize "$PROG/$fam.souffle.dl" "$WORKDIR/$fam.sfpl.ps.dl"
    timeout "$BUILD_TO" $TIME "$SOUFFLE" -j "$JOBS" $SOUFFLE_FLAGS -o "$WORKDIR/sfplbin_$fam" "$WORKDIR/$fam.sfpl.ps.dl" >"$WORKDIR/$fam.sfplb.log" 2>&1
    [[ -x "$WORKDIR/sfplbin_$fam" ]] && { sfplbin="$WORKDIR/sfplbin_$fam"; sfplb=$(wall_of "$WORKDIR/$fam.sfplb.log"); sfplbr=$(rss_of "$WORKDIR/$fam.sfplb.log"); }
  fi
  echo "[$(date +%H:%M:%S)] $fam built  fl=${flb}s sfnp=${sfnpb}s sfpl=${sfplb}s" >&2

  # ---- runs (per dataset) ----
  for ds in "${DATASETS[@]}"; do
    facts=$(facts_of "$ds"); [[ -n "$facts" ]] || { echo -e "$ds\t$fam$(printf '\tNA%.0s' {1..15})\tNO_FACTS" >>"$RES"; continue; }
    flr=NA;flrr=NA;flv=NA;sfnpr=NA;sfnprr=NA;sfnpv=NA;sfplr=NA;sfplrr=NA;sfplv=NA
    reps_run(){ # $1=bin $2=mode(fl|sf) $3=outdir ; echos "medsec medrss count"
      local bin="$1" mode="$2" od="$3" s r cnt=NA; local ss=() rs=()
      for ((i=1;i<=REPS;i++)); do
        rm -rf "$od"; mkdir -p "$od"
        if [[ "$mode" == fl ]]; then ln -sfn "$facts" "$LINK"; timeout "$RUN_TO" $CAP $TIME "$bin" -w "$WORKERS" >"$WORKDIR/r.log" 2>&1
        else timeout "$RUN_TO" $CAP $TIME "$bin" -j "$JOBS" -F "$facts" -D "$od" >"$WORKDIR/r.log" 2>&1; fi
        [[ $? -ne 0 ]] && { echo "FAIL NA NA"; return; }
        s=$(wall_of "$WORKDIR/r.log"); r=$(rss_of "$WORKDIR/r.log"); ss+=("${s:-0}"); rs+=("${r:-0}")
        [[ $i -eq 1 && "${s:-0}" -ge "$REP_LONG" ]] && break
      done
      [[ "$mode" == fl ]] && cnt=$(fl_count "$od") || cnt=$(sf_count "$WORKDIR/r.log")
      echo "$(median "${ss[@]}") $(median "${rs[@]}") $cnt"
    }
    [[ -n "$flbin"   ]] && read flr flrr flv     < <(reps_run "$flbin"   fl "$WORKDIR/flo_$fam")
    [[ -n "$sfnpbin" ]] && read sfnpr sfnprr sfnpv < <(reps_run "$sfnpbin" sf "$WORKDIR/sfnpo")
    [[ -n "$sfplbin" ]] && read sfplr sfplrr sfplv < <(reps_run "$sfplbin" sf "$WORKDIR/sfplo")
    # minimal correctness: FlowLog vs Soufflé-noplan VarPointsTo count
    verdict=NA
    if [[ "$flv" =~ ^[0-9]+$ && "$sfnpv" =~ ^[0-9]+$ ]]; then [[ "$flv" == "$sfnpv" ]] && verdict=COUNT_MATCH || verdict=COUNT_DIFF
    elif [[ "$flr" == FAIL || "$sfnpr" == FAIL ]]; then verdict=RUN_FAIL; fi
    echo -e "$ds\t$fam\t$flb\t$flbr\t$flr\t$flrr\t$flv\t$sfnpb\t$sfnpbr\t$sfnpr\t$sfnprr\t$sfnpv\t$sfplb\t$sfplbr\t$sfplr\t$sfplrr\t$sfplv\t$verdict" >>"$RES"
    echo "[$(date +%H:%M:%S)] $fam @ $ds  fl=${flr}s sfnp=${sfnpr}s sfpl=${sfplr}s  $verdict" >&2
    rm -rf "$WORKDIR/sfnpo" "$WORKDIR/sfplo" "$WORKDIR/flo_$fam"/*.csv
  done
  rm -f "$WORKDIR/flbin_$fam" "$WORKDIR/sfnpbin_$fam" "$WORKDIR/sfplbin_$fam" "$WORKDIR"/sf*bin_$fam.cpp
done
echo "[$(date +%H:%M:%S)] time DONE -> $RES" >&2
if [[ "$KEEP_WORK" == 1 ]]; then echo "kept WORKDIR=$WORKDIR" >&2; else rm -f "$LINK"; rm -rf "$WORKDIR"; fi

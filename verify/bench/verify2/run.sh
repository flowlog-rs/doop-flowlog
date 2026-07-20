#!/usr/bin/env bash
# [verify2] three-engine timing sweep (FlowLog main-next vs Soufflé ±.plan),
# .printsize, 32 threads, median of 3 — the exact invocation behind this dir.
#
# Point FLC at a flowlog-compiler built from flowlog-rs/flowlog main-next and
# FACTS_ROOT at a dir of DOOP fact subdirs. Keep WORKDIR/TMPDIR on a large,
# non-tmpfs disk (FlowLog builds peak ~11 GB RSS; -B cache grows ~20 GB).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${FLC:?set FLC=/path/to/flowlog-compiler (built from flowlog main-next)}"
: "${FACTS_ROOT:?set FACTS_ROOT=/path/to/dacapo-facts}"
export FLC FACTS_ROOT
export DATASETS="${DATASETS:-luindex}"
export THREADS="${THREADS:-32}"     # -> -w32 (FlowLog) and -j32 (Soufflé)
export REPS="${REPS:-3}"            # median of 3
export OUTDIR="${OUTDIR:-$HERE}"    # time_<host>.tsv lands here

FAMS=(
  context-insensitive
  1-type-sensitive
  1-type-sensitive+heap
  1-call-site-sensitive
  1-call-site-sensitive+heap
  1-object-sensitive
  1-object-sensitive+heap
  1-object-1-type-sensitive+heap
  2-type-sensitive+heap
  2-object-sensitive+heap
)

exec bash "$HERE/../time.sh" "${FAMS[@]}"

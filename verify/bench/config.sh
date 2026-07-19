# config.sh — the ONE place to choose what runs. Sourced by generate.sh, time.sh
# and output.sh. Every value is `: "${VAR:=default}"`, so ANY of them can be
# overridden from the environment without editing this file, e.g.:
#   FACTS_ROOT=/data THREADS=16 MEM_MAX=400G verify/bench/time.sh 1-object-sensitive

# ── Datasets: subdirectory names under $FACTS_ROOT (each a DOOP fact dir) ─────
# A dataset is $FACTS_ROOT/<name> containing *.facts (directly or in a facts/ child).
: "${DATASETS:=luindex eclipse batik h2o xalan spring}"

# ── Programs (analysis families) ─────────────────────────────────────────────
# The full set FlowLog runs (context-sensitivity hierarchy + specials). Trim to
# run a subset; or pass families as CLI args to override entirely.
: "${FAMILIES:=context-insensitive \
  1-type-sensitive 1-type-sensitive+heap \
  1-call-site-sensitive 1-call-site-sensitive+heap \
  1-object-sensitive 1-object-sensitive+heap 1-object-1-type-sensitive+heap \
  2-type-sensitive+heap 2-type-object-sensitive+heap 2-type-object-sensitive+2-heap \
  2-object-sensitive+heap 2-object-sensitive+2-heap \
  2-call-site-sensitive+heap 2-call-site-sensitive+2-heap \
  3-type-sensitive+2-heap 3-type-sensitive+3-heap \
  3-object-sensitive+2-heap 3-object-sensitive+3-heap \
  4-object-sensitive+4-heap \
  adaptive-2-object-sensitive+heap sticky-2-object-sensitive \
  selective-2-object-sensitive+heap partitioned-2-object-sensitive+heap}"

# ── Engine variants (time.sh runs all enabled; output.sh always FL vs SF-noplan) ─
: "${RUN_FLOWLOG:=1}"          # FlowLog
: "${RUN_SOUFFLE_NOPLAN:=1}"   # Soufflé, .plan stripped — the correctness oracle
: "${RUN_SOUFFLE_PLAN:=1}"     # Soufflé, DOOP's .plan kept — isolates the plan effect

# ── Parallelism & repetition ─────────────────────────────────────────────────
: "${THREADS:=32}"             # convenience: sets WORKERS and JOBS together
: "${WORKERS:=$THREADS}"       # FlowLog -w   (override alone for FL-only thread sweeps)
: "${JOBS:=$THREADS}"          # Soufflé -j
: "${REPS:=3}"                 # runs per cell; median reported
: "${REP_LONG:=900}"           # a first rep >= this many seconds stays a single measurement

# ── Resource guards (tune per machine) ───────────────────────────────────────
: "${BUILD_TO:=7200}"          # per-build timeout, seconds
: "${RUN_TO:=3600}"            # per-run   timeout, seconds
# Per-run memory cap. When set (MEM_MAX=200G) each run is wrapped in a
# systemd-run --scope (MemoryMax + MemorySwapMax=0): an OOM dies cleanly inside
# the scope, recorded RUN_FAIL, never the box. Needs systemd (root, or --user
# when non-root — auto-detected). Empty = uncapped.
: "${MEM_MAX:=}"               # e.g. 200G

# ── Tools ────────────────────────────────────────────────────────────────────
: "${FLC:=}"                   # REQUIRED for FlowLog: the flowlog-compiler binary
: "${SOUFFLE:=souffle}"        # Soufflé 2.x on PATH
: "${STR_INTERN:=1}"           # FlowLog --str-intern (REQUIRED: ord() needs interning)
: "${FL_BUILD_DIR:=}"          # FlowLog -B cache dir: reuse across builds = faster
                               #   rebuilds, but it grows (~3G/family) and lives wherever
                               #   you point it (keep OFF tmpfs if RAM is tight). Empty = ephemeral.
: "${FLC_FLAGS:=}"             # extra flags appended to every flowlog-compiler build
: "${SOUFFLE_FLAGS:=}"         # extra flags appended to every souffle build

# ── Paths ─────────────────────────────────────────────────────────────────────
: "${FACTS_ROOT:=}"            # REQUIRED: dir holding the dataset subdirs
: "${OUTDIR:=$PWD}"            # where the result TSV is written
# WORKDIR (scratch for binaries/outputs) and TMPDIR (sort temps) default to a
# fresh mktemp dir; point them at large/fast storage on a big box. Keep them OFF
# a memory-cgroup-capped tmpfs, since tmpfs pages count against MEM_MAX.
: "${WORKDIR:=}"               # empty = mktemp under $TMPDIR
: "${KEEP_WORK:=0}"            # 1 = keep WORKDIR (binaries, logs, outputs) for debugging

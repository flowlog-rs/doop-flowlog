# FlowLog vs Soufflé benchmark kit

A self-contained kit for timing and correctness-checking DOOP's points-to
analyses on **FlowLog** vs **Soufflé**, over your own DaCapo fact sets. Built to
hand to a collaborator: the analysis programs are **pre-generated standalone
files** — no DOOP, Java, `cpp`, or this repo's build machinery is needed to run.

## What's here

| file | role |
|---|---|
| `config.sh` | the one place to choose datasets, families, engines, threads, caps, tool paths — every value is env-overridable |
| `programs/*.dl` | **standalone** single-file programs: `<family>.flowlog.dl`, `<family>.souffle.dl` (with `.plan`), `<family>.souffle-noplan.dl`. Full DOOP output wired in. |
| `time.sh` | **timing** run — `.printsize` (no serialization), medians, 3 engine columns, tuple-count sanity check |
| `output.sh` | **correctness** run — full `.output` end-to-end, byte-for-byte comparison of every relation, single-threaded |
| `generate.sh` | regenerates `programs/` from the repo (only if you change the logic; needs `cpp` + repo) |

**24 analysis families** are shipped (the whole context-sensitivity hierarchy
plus adaptive / sticky / selective / partitioned).

## Prerequisites

- **FlowLog compiler** — build from `flowlog-rs/flowlog` `main-next`:
  `cargo build --release -p flowlog-compiler` → point `FLC` at the binary.
  (The shipped `*.flowlog.dl` use the `main-next`-compatible grammar.)
- **Soufflé 2.x** on `PATH` (`souffle`).
- **Fact sets**: a directory `$FACTS_ROOT` with one subdirectory per benchmark,
  each holding DOOP-generated `*.facts` (directly, or in a `facts/` child).

## Run it

```bash
# timing: all configured families × datasets, 32 threads, both souffle variants
FLC=/path/to/flowlog-compiler FACTS_ROOT=/data/dacapo-facts verify/bench/time.sh

# a subset of families (positional args override the config list)
FLC=… FACTS_ROOT=… verify/bench/time.sh 2-object-sensitive+heap 3-type-sensitive+2-heap

# byte-exact correctness on one family
FLC=… FACTS_ROOT=… verify/bench/output.sh 1-object-sensitive+heap
```

Results go to `time_<host>.tsv` / `output_<host>.tsv` in `$OUTDIR`.

**`time_*.tsv` columns**: `dataset, family`, then per engine (`fl`, `sfnp` =
Soufflé no-plan, `sfpl` = Soufflé with-plan) `build_s, build_rss(MB), run_s,
run_rss(MB), vpt`(VarPointsTo count), then `verdict` (`COUNT_MATCH` /
`COUNT_DIFF` / `RUN_FAIL`). Run time is the **median of `REPS`**; a run longer
than `REP_LONG`s is measured once.

**`output_*.tsv` columns**: `relations, matched, mismatched, missing, verdict`
(`MATCH` iff all relations byte-identical after canonicalisation), `first_mismatch`.

## Parameters (all env-overridable — see `config.sh`)

| param | default | meaning |
|---|---|---|
| `FACTS_ROOT` | — | **required**; dir of dataset subdirs |
| `FLC` | — | **required**; flowlog-compiler binary |
| `DATASETS` | 6 DaCapo apps | dataset subdir names to run |
| `FAMILIES` | 24 families | analyses to run (or pass as args) |
| `THREADS` | 32 | sets `WORKERS` (FlowLog `-w`) and `JOBS` (Soufflé `-j`) together |
| `REPS` / `REP_LONG` | 3 / 900 | repetitions for the median; long-run single-shot cutoff (s) |
| `BUILD_TO` / `RUN_TO` | 7200 / 3600 | per-build / per-run timeouts (s) |
| `MEM_MAX` | — | per-run memory cap (e.g. `200G`); OOM → clean `RUN_FAIL`, needs systemd |
| `RUN_SOUFFLE_PLAN` / `RUN_SOUFFLE_NOPLAN` / `RUN_FLOWLOG` | 1 | toggle engine variants |
| `FL_BUILD_DIR` | — | FlowLog `-B` cache dir: faster rebuilds, grows ~3G/family (keep off tmpfs) |
| `FLC_FLAGS` / `SOUFFLE_FLAGS` | — | extra flags appended to each engine's build |
| `OUTDIR` / `WORKDIR` / `TMPDIR` | `$PWD` / mktemp | results / scratch / sort-temp locations |
| `KEEP_WORK` | 0 | keep scratch (binaries, logs, outputs) for debugging |

## Protecting a shared machine

Deep context-sensitive analyses on large apps can need **>200 GB** (the
`2-call-site-sensitive+*heap` family exceeds ~220 GB on both engines regardless
of app size). To keep an OOM from taking down the box, set a per-run cap:

```bash
FLC=… FACTS_ROOT=… MEM_MAX=200G verify/bench/time.sh
```

Set `MEM_MAX` to `total_RAM − (facts resident in tmpfs) − ~15 GB headroom`.
Note: fact sets placed on a tmpfs (`/dev/shm`) count as RAM, so subtract them.

## Notes on methodology

- **Timing uses `.printsize`** (tuple count, no CSV write) so it measures pure
  fixpoint compute, not serialization. `output.sh` is the end-to-end
  (with-serialization) path used for byte-exact correctness.
- **`.plan`**: DOOP ships hand-tuned Soufflé join orders. They change execution
  time but never output, so `time.sh` measures both `sfpl` (with) and `sfnp`
  (without) to isolate the effect, while `output.sh` only needs `sfnp`.
- **Byte-exact needs one thread** on both engines: heap-merge representatives
  depend on `ord()`/interning order, which is thread-count dependent. `time.sh`
  at 32 threads therefore only checks *counts*; `output.sh` runs single-threaded
  for the full byte comparison.
- The FlowLog logic differs from Soufflé's only by the documented mechanical
  grammar categories (records→tuples, head aggregates, etc.) — see
  [`../../flowlog-logic/README.md`](../../flowlog-logic/README.md).

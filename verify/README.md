# Verifying & benchmarking the FlowLog port

This directory has everything to run DOOP's points-to analyses on **FlowLog**
and compare them against **Soufflé** — for both **correctness** (identical
output) and **performance** (wall-clock, memory). It is self-contained: the
analysis programs are pre-generated, so nothing here needs DOOP, Java, `cpp`, or
this repo's build machinery at run time.

What changed in the Datalog itself (the FlowLog port is a near-mechanical mirror
of `souffle-logic/`) is documented in
[`../flowlog-logic/README.md`](../flowlog-logic/README.md).

## Layout

| path | what |
|---|---|
| [`bench/`](bench) | the benchmark kit — config-driven `time.sh` (timing) and `output.sh` (byte-exact correctness), plus **72 standalone programs** in `bench/programs/` (24 families × FlowLog / Soufflé±`.plan`), generated from `flowlog-logic/` + `souffle-logic/` by `bench/generate.sh`. Start here. |

The programs in `bench/programs/` are the same self-contained single-file form
as before — assembled straight from `flowlog-logic/`, so a collaborator can feed
one `.dl` + a fact dir to a compiler with no repo/`cpp`/DOOP needed. They are
byte-identical to what the DOOP driver assembles at run time, so running via
`doop` and running a standalone program produce the same analysis.

## Quick start

```bash
# build the FlowLog compiler (flowlog-rs/flowlog, main-next)
cargo build --release -p flowlog-compiler     # -> target/release/flowlog-compiler

# timing sweep: all families × your datasets, FlowLog vs Soufflé (±.plan), 32 threads
FLC=/path/to/flowlog-compiler FACTS_ROOT=/data/dacapo-facts verify/bench/time.sh

# byte-exact correctness on one family
FLC=… FACTS_ROOT=… verify/bench/output.sh 2-object-sensitive+heap
```

Full parameters (datasets, families, threads, timeouts, memory cap, tool paths)
and result-column formats are in [`bench/README.md`](bench/README.md).

## What it establishes

- **Correctness** — every analysis' output is compared to Soufflé's. Run
  single-threaded (`output.sh`) the comparison is **byte-for-byte** over all
  output relations (heap-merge representatives are intern/thread-order
  dependent, so byte-equality needs one worker); at 32 threads (`time.sh`) the
  check is tuple-count equality.
- **Performance** — `time.sh` records compile and run wall-clock + peak RSS per
  engine, timing the analysis with `.printsize` (tuple count, no CSV
  serialization) so the number is pure fixpoint compute.

## Coverage

FlowLog runs **24 analysis families** — the full context-sensitivity hierarchy
(k-call-site, k-object, k-type, hybrids) plus adaptive / sticky / selective /
partitioned. `2-call-site-sensitive+*heap` is intractable in ≤~220 GB on **both**
engines, independent of app size; everything else runs on a well-resourced box.

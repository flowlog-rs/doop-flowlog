# Parallel (`-w32` / `-j32`) FlowLog main-next vs Soufflé — DOOP standalone, luindex

**TL;DR — on all 19 standalone families, current FlowLog `main-next` is byte-for-byte
identical to Soufflé and ~3× faster in parallel.**

The sibling [`../verify.sh`](../verify.sh) + [`../timing_summary.tsv`](../timing_summary.tsv)
measured the **single-threaded** (`-w1` / `-j1`) `nemo/tuple` build. This run is the
**parallel** counterpart on the **current `main-next` engine**: FlowLog batch `-w 32`
vs Soufflé `-j 32` (compiled with `-j 32` too).

| | result |
|---|---|
| **Correctness** | **19 / 19 byte-exact** `VarPointsTo` (identical counts *and* empty `diff` after bracket-canonicalisation) — see [`timing_summary.tsv`](timing_summary.tsv) |
| **Speed (run)** | FlowLog faster on **all 19** families — **1.67× → 6.35×** per family, **3.01× aggregate** (Σ FlowLog 627 s vs Σ Soufflé 1 890 s) |
| **Peak memory** | FlowLog lower on 4/19 (min 0.88×), higher on the rest, up to **2.47×** on deep type-sensitive families — it trades RSS for speed |
| **One-time compile** | FlowLog 275–1363 s (rustc on the generated crate) vs Soufflé 139–148 s; amortised by DOOP's compile-once / run-many model |

> **Why this matters.** The main [`../README.md`](../README.md) notes that `main-next`
> **panics on 18/19 families** with `unreachable!("tuple-typed columns cannot appear in
> EDB input relations")`. That is still true for the raw `nemo/tuple` programs in
> [`../standalone/flowlog/`](../standalone/flowlog). **This run shows the other half of
> the story:** once you feed `main-next` the bare-grammar / non-tuple-EDB programs it
> *can* compile, it is not only correct but **byte-exact at `-w32`** — i.e. the
> multi-threaded non-determinism that older `main-next` showed on type-sensitive
> families is **gone**, and it is materially faster than Soufflé.

---

## What was compared

| component | version / value |
|---|---|
| FlowLog | `flowlog-rs/flowlog` **`main-next` @ `70c99a8`** ("Migrate to differential-dataflow 0.25 / timely 0.31", #227) |
| Soufflé | **2.5** (64-bit) |
| Facts (EDB) | **luindex** (DaCapo), DOOP-generated |
| Machine | 64 cores / 503 GiB RAM |
| Oracle | Soufflé; verdict = byte-exact `VarPointsTo` |

Exact commands (see [`bench.sh`](bench.sh)):

```bash
# FlowLog — compile once to a native batch binary, then run with 32 workers
flowlog-compiler --str-intern --mode datalog-batch -F "$FACTS" -D out -o bin  flowlog/<family>.dl
./bin -w 32                                   # writes out/VarPointsTo.csv

# Soufflé — compile with -j 32, run with -j 32
souffle -j 32 -o bin  ../standalone/souffle/<family>.dl
./bin -j 32 -F "$FACTS" -D sfout               # writes sfout/VarPointsTo.csv

# Byte-exact compare (unify record/tuple brackets, then sort)
canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1" | LC_ALL=C sort; }
diff <(canon out/VarPointsTo.csv) <(canon sfout/VarPointsTo.csv) && echo MATCH
```

Compiles run in parallel; the **timed runs are serial** so wall-clock and peak-RSS are
contention-free. Peak memory is `/usr/bin/time -v` "Maximum resident set size".

## Why the FlowLog programs differ (important for reviewers)

The Soufflé side uses [`../standalone/souffle/`](../standalone/souffle) **as-is**.

The FlowLog side **cannot** use [`../standalone/flowlog/`](../standalone/flowlog) directly:
those are the `nemo/tuple` (`= True` grammar) programs, and every context-*sensitive*
family declares tuple-typed EDB inputs, which `main-next` still rejects with
`relation.rs: unreachable!("tuple-typed columns cannot appear in EDB input relations")`
— **18 of 19 panic; only `context-insensitive` compiles** (confirmed on `70c99a8`).

So for `main-next` we run the **bare-grammar / non-tuple-EDB variant** of each analysis —
the same programs the [`flowlog-next-datalog-compat`](https://github.com/flowlog-rs/doop-flowlog/tree/flowlog-next-datalog-compat)
branch produces (contexts encoded without tuple-typed EDB inputs; `match(...) = True` /
`= False` rewritten to `match(...)` / `!match(...)`). These encode the **identical analyses**
— the 19/19 byte-exact match against the standalone Soufflé programs is the proof.
`context-insensitive` uses the (transformed) standalone program directly.

## Results (`-w32` / `-j32`, luindex)

Sorted by FlowLog run time. `speedup = souffle_run / flowlog_run`; `mem = FL peak / SF peak`.

| family | VarPointsTo | FL run s | SF run s | speedup | FL peak GB | SF peak GB | mem FL/SF | verdict |
|---|--:|--:|--:|--:|--:|--:|--:|:--:|
| 3-type-sensitive+3-heap | 1 484 975 | 12.68 | 27.05 | 2.13× | 3.63 | 1.47 | 2.47 | MATCH |
| 3-type-sensitive+2-heap | 1 483 057 | 12.83 | 27.29 | 2.13× | 3.52 | 1.46 | 2.41 | MATCH |
| context-insensitive | 5 396 536 | 14.23 | 39.97 | 2.81× | 4.24 | 2.82 | 1.50 | MATCH |
| 4-object-sensitive+4-heap | 3 212 708 | 16.12 | 55.79 | 3.46× | 5.69 | 2.57 | 2.21 | MATCH |
| 3-object-sensitive+2-heap | 3 411 656 | 16.15 | 56.39 | 3.49× | 5.11 | 2.67 | 1.91 | MATCH |
| 3-object-sensitive+3-heap | 3 417 156 | 16.29 | 57.07 | 3.50× | 5.28 | 2.66 | 1.98 | MATCH |
| 2-type-sensitive+heap | 4 859 195 | 16.97 | 48.74 | 2.87× | 4.31 | 2.84 | 1.52 | MATCH |
| 1-type-sensitive | 9 206 109 | 18.75 | 77.02 | 4.11× | 5.13 | 4.40 | 1.17 | MATCH |
| 1-call-site-sensitive | 17 075 710 | 23.40 | 120.76 | 5.16× | 6.96 | 7.60 | 0.92 | MATCH |
| 1-call-site-sensitive+heap | 17 573 686 | 24.48 | 124.06 | 5.07× | 6.98 | 7.80 | 0.89 | MATCH |
| 1-object-sensitive | 15 093 978 | 28.28 | 179.70 | 6.35× | 6.87 | 7.05 | 0.97 | MATCH |
| 1-type-sensitive+heap | 11 736 906 | 30.42 | 96.80 | 3.18× | 5.99 | 5.65 | 1.06 | MATCH |
| 2-type-object-sensitive+heap | 8 719 851 | 36.37 | 108.69 | 2.99× | 7.29 | 5.09 | 1.43 | MATCH |
| 1-object-1-type-sensitive+heap | 8 719 851 | 36.77 | 108.15 | 2.94× | 7.20 | 5.19 | 1.39 | MATCH |
| adaptive-2-object-sensitive+heap | 8 741 742 | 42.75 | 118.45 | 2.77× | 7.63 | 5.43 | 1.41 | MATCH |
| 2-object-sensitive+heap | 8 741 742 | 43.26 | 118.91 | 2.75× | 7.72 | 5.42 | 1.42 | MATCH |
| 1-object-sensitive+heap | 20 036 177 | 52.52 | 201.30 | 3.83× | 8.27 | 9.39 | 0.88 | MATCH |
| 2-type-object-sensitive+2-heap | 9 788 238 | 73.56 | 137.83 | 1.87× | 10.28 | 5.83 | 1.76 | MATCH |
| 2-object-sensitive+2-heap | 11 281 640 | 111.21 | 185.53 | 1.67× | 10.51 | 6.71 | 1.57 | MATCH |

Full per-family numbers incl. compile times: [`results.tsv`](results.tsv).
Curated summary: [`timing_summary.tsv`](timing_summary.tsv).

## How to read it

- **Speed.** FlowLog wins every family; the margin is largest on the biggest workloads
  (`1-object-sensitive` 6.35×, the `1-call-site` pair ~5×) and smallest on the two
  `2-object-sensitive` deep families (1.67–1.87×), where it still wins.
- **Memory.** FlowLog's peak RSS is comparable-to-lower on the `1-*` families (0.88–1.17×)
  but grows relative to Soufflé as context depth increases (up to 2.47×). The
  time-vs-memory trade-off is the headline caveat, not correctness.
- **Compile.** FlowLog's rustc compile (275–1363 s) dwarfs Soufflé's (~140 s), but it is a
  one-time cost per analysis; DOOP compiles once and runs many.

## Reproduce

```bash
export FLC=/path/to/flowlog/target/release/flowlog-compiler   # built from main-next
export FACTS=/path/to/luindex                                 # DOOP facts (transferred, not in-repo)
export FLOWLOG_PROGS=/path/to/main-next-compatible/flowlog    # bare-grammar programs (see above)
export OUT=/big/disk/run                                      # keep off a small root disk
verify/main-next-w32/bench.sh                                 # Souffle progs default to ../standalone/souffle
```

Notes: the DOOP-generated facts must be transferred alongside (they cannot be regenerated
without DOOP/Java). Put `OUT` (binaries + the multi-GB `VarPointsTo` outputs + sort temp)
on a large volume — the full 19-family run produced ~134 GiB of intermediate output.

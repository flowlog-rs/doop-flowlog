# verify1 — FlowLog vs Soufflé timing & RSS (recorded run)

A recorded `time.sh` run comparing **FlowLog** (`main-next`) against **Soufflé with `.plan`** and **Soufflé without `.plan`** on DOOP points-to analyses, using `.printsize` only (no IDB serialization). This directory holds the raw TSV plus this summary. Regenerate with the command below.

## Environment

| | |
|---|---|
| FlowLog | `flowlog-rs/flowlog` `main-next` @ `ef3be32`, `cargo build --release -p flowlog-compiler` |
| Soufflé | 2.5 (OpenMP), `g++` 11.4 |
| Threads | **32** — FlowLog `-w 32`; Soufflé `-j 32` at **both compile and run** |
| Mode | `.printsize` (tuple counts only, no `.output` serialization) |
| Reps | 2 (median; a run longer than `REP_LONG`s measured once) |
| Host | `flowlog-west1` |
| Facts | DOOP fact sets from HF `NemoYuu/flowlog_benchmark`; missing synthetic DOOP inputs stubbed empty so Soufflé and FlowLog read identical inputs |

## Reproduce

```bash
# from repo root; FACTS_ROOT has one subdir per dataset of DOOP *.facts
FLC=/path/to/flowlog-compiler FACTS_ROOT=/path/to/facts \
  DATASETS="luindex xalan eclipse" THREADS=32 REPS=2 \
  verify/bench/time.sh \
    context-insensitive 1-call-site-sensitive 1-type-sensitive 1-object-sensitive+heap 2-type-sensitive+heap 2-object-sensitive+heap
```

Scope of this run: **6 families × 3 datasets = 18 cells × 3 engines**. `time.sh` and `programs/` are used unmodified (kit @ master). To run the full default matrix, drop the positional families and set `DATASETS` to all six DaCapo apps (`luindex eclipse batik h2o xalan spring`) — note the deepest families (e.g. `3-object+3-heap`, `4-object+4-heap`, `2-call-site`) can need >200 GB / hours.

## Correctness — all 18 cells `COUNT_MATCH`

Every cell reports identical `VarPointsTo` across FlowLog, Soufflé+plan, and Soufflé no-plan. No timeouts or failures.

## Compile time / RSS (per family — built once, dataset-independent)

| family | FlowLog | Soufflé +plan | Soufflé no-plan |
|---|--:|--:|--:|
| `context-insensitive` | 225 s / 7.6 G | 151 s / 2.2 G | 139 s / 2.2 G |
| `1-call-site-sensitive` | 248 s / 9.3 G | 153 s / 2.2 G | 142 s / 2.2 G |
| `1-type-sensitive` | 254 s / 9.5 G | 155 s / 2.2 G | 150 s / 2.2 G |
| `1-object-sensitive+heap` | 251 s / 9.6 G | 150 s / 2.2 G | 142 s / 2.2 G |
| `2-type-sensitive+heap` | 267 s / 11.0 G | 153 s / 2.2 G | 150 s / 2.2 G |
| `2-object-sensitive+heap` | 263 s / 10.9 G | 150 s / 2.2 G | 140 s / 2.2 G |

Soufflé compiles ~1.7× faster at ~2.2 G; FlowLog pays a one-time Rust/cargo build cost.

## Run time (s) — with speedup [Soufflé ÷ FlowLog]

| family | dataset | FlowLog | SF +plan | SF no-plan | +plan/FL | no-plan/FL | VarPointsTo |
|---|---|--:|--:|--:|--:|--:|--:|
| `context-insensitive` | luindex | 13 | 26 | 37 | 2.0× | 2.8× | 5,396,536 |
| `context-insensitive` | xalan | 16 | 25 | 31 | 1.6× | 1.9× | 2,387,458 |
| `context-insensitive` | eclipse | 17 | 40 | 66 | 2.4× | 3.9× | 10,539,055 |
| `1-call-site-sensitive` | luindex | 19 | 58 | 105 | 3.1× | 5.5× | 17,075,710 |
| `1-call-site-sensitive` | xalan | 20 | 46 | 77 | 2.3× | 3.9× | 9,499,690 |
| `1-call-site-sensitive` | eclipse | 36 | 150 | 306 | 4.2× | 8.5× | 51,467,403 |
| `1-type-sensitive` | luindex | 17 | 40 | 71 | 2.4× | 4.2× | 9,206,109 |
| `1-type-sensitive` | xalan | 18 | 33 | 43 | 1.8× | 2.4× | 4,489,202 |
| `1-type-sensitive` | eclipse | 28 | 79 | 272 | 2.8× | 9.7× | 19,852,573 |
| `1-object-sensitive+heap` | luindex | 45 | 100 | 176 | 2.2× | 3.9× | 20,036,177 |
| `1-object-sensitive+heap` | xalan | 27 | 53 | 71 | 2.0× | 2.6× | 8,688,754 |
| `1-object-sensitive+heap` | eclipse | 183 | 418 | 1115 | 2.3× | 6.1× | 62,080,248 |
| `2-type-sensitive+heap` | luindex | 16 | 29 | 44 | 1.8× | 2.8× | 4,859,195 |
| `2-type-sensitive+heap` | xalan | 18 | 28 | 34 | 1.6× | 1.9× | 1,866,950 |
| `2-type-sensitive+heap` | eclipse | 30 | 71 | 159 | 2.4× | 5.3× | 16,425,925 |
| `2-object-sensitive+heap` | luindex | 40 | 80 | 108 | 2.0× | 2.7× | 8,741,742 |
| `2-object-sensitive+heap` | xalan | 36 | 63 | 69 | 1.8× | 1.9× | 4,316,079 |
| `2-object-sensitive+heap` | eclipse | 103 | 253 | 587 | 2.5× | 5.7× | 43,929,737 |

## Run RSS (GB)

| family | dataset | FlowLog | SF +plan | SF no-plan |
|---|---|--:|--:|--:|
| `context-insensitive` | luindex | 4.1 | 3.3 | 2.8 |
| `context-insensitive` | xalan | 3.8 | 2.8 | 2.6 |
| `context-insensitive` | eclipse | 5.6 | 5.5 | 4.8 |
| `1-call-site-sensitive` | luindex | 6.8 | 8.5 | 7.5 |
| `1-call-site-sensitive` | xalan | 5.8 | 6.2 | 5.6 |
| `1-call-site-sensitive` | eclipse | 14.1 | 23.3 | 20.7 |
| `1-type-sensitive` | luindex | 5.1 | 5.2 | 4.4 |
| `1-type-sensitive` | xalan | 4.4 | 3.9 | 3.5 |
| `1-type-sensitive` | eclipse | 8.0 | 10.5 | 8.7 |
| `1-object-sensitive+heap` | luindex | 8.4 | 11.2 | 9.3 |
| `1-object-sensitive+heap` | xalan | 6.8 | 6.3 | 5.6 |
| `1-object-sensitive+heap` | eclipse | 19.3 | 33.4 | 27.3 |
| `2-type-sensitive+heap` | luindex | 4.3 | 3.3 | 2.8 |
| `2-type-sensitive+heap` | xalan | 4.1 | 2.8 | 2.6 |
| `2-type-sensitive+heap` | eclipse | 7.8 | 9.3 | 7.7 |
| `2-object-sensitive+heap` | luindex | 7.8 | 6.3 | 5.4 |
| `2-object-sensitive+heap` | xalan | 6.8 | 4.8 | 4.3 |
| `2-object-sensitive+heap` | eclipse | 18.9 | 25.8 | 21.1 |

## Aggregate run-time speedup of FlowLog (18 cells)

- vs Soufflé **+plan**: min 1.6×, median 2.3×, max 4.2×
- vs Soufflé **no-plan**: min 1.9×, median 3.9×, max 9.7×

## Takeaways

- **Correctness parity is exact** across all cells and all three engines.
- **Runtime:** FlowLog is fastest everywhere; the gap widens on the largest workloads (`eclipse 1-object+heap`: 183 s vs 418 s vs 1115 s).
- **`.plan` matters for Soufflé:** +plan is ~1.5–2× faster than no-plan, but still trails FlowLog.
- **Run memory:** comparable; FlowLog is leaner on the heavy cells (`eclipse 1-object+heap`: 19.3 G vs 33.4 G vs 27.3 G), slightly heavier on light context-insensitive runs.
- **Compile:** Soufflé compiles faster (~140–155 s, 2.2 G) than FlowLog (~225–267 s, 7.6–11 G); one-time per family for both.

Raw data: [`time_flowlog-west1.tsv`](./time_flowlog-west1.tsv).

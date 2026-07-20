# [verify3] FlowLog vs Soufflé — timing sweep

Results of `verify/bench/time.sh` comparing three engines on DOOP points-to
analyses, timed with `.printsize` (tuple count only — **no IDB/CSV
serialization**, so the number is pure fixpoint compute).

> **Status: in-progress snapshot — 5 of 24 families complete.** All completed
> cells are `COUNT_MATCH` (identical VarPointsTo across engines). The heavy
> context-sensitive tail (2-call-site, 3-object/type, 4-object, ...) is still
> running; this file will be updated as families finish.

## Engines

| id | engine | notes |
|---|---|---|
| `fl`   | **FlowLog** (`flowlog-rs/flowlog` `main-next` @ `ef3be32`) | `--str-intern`; `-w 32` |
| `sfnp` | **Soufflé 2.5, `.plan` stripped** | `-j 32` at **compile and run** |
| `sfpl` | **Soufflé 2.5, DOOP `.plan` kept** | `-j 32` at **compile and run** |

## Configuration

- **Threads: 32** — FlowLog `-w 32`; Soufflé `-j 32` passed at **both compile
  and run** (a Soufflé binary compiled without `-j` ignores runtime `-j` and
  runs serial, so both stages need it for a fair 32-thread comparison).
- **Timing metric:** `.printsize` (every `.output` rewritten to `.printsize`);
  no relation is serialized to disk.
- **Repetitions:** `REPS=3` (median reported); a first rep >= `REP_LONG=900 s`
  is kept as a single measurement.
- **Guards:** `MEM_MAX=450G` (per-run `systemd` scope), `RUN_TO=1800 s`,
  `BUILD_TO=7200 s`.
- **Host:** `flowlog-west3` — 64 cores, 503 GB RAM, facts on ext4 (not tmpfs).
- **Datasets:** `luindex eclipse batik h2o xalan spring` — DOOP DaCapo fact
  sets (`NemoYuu/flowlog_benchmark`).

### Dataset note (empty-relation stubs)

DOOP does not emit `.facts` files for relations that are empty for a given
program (here: `KeepClass`, `KeepClassMembers`, `KeepClassesWithMembers`,
`KeepMethod`, `RootCodeElement`, `PrimaryPartition`, `TypeToPartition`).
FlowLog treats a missing `.input` as empty; **Soufflé errors** (`Cannot open
fact file ...`). Empty stub files were created for these declared inputs so all
three engines run against identical inputs. This changes no result (the
relations are genuinely empty) - VarPointsTo counts match across engines.

## Column legend

`*_build_s` / `*_build_rss` = compile wall-clock (s) / peak RSS (MB), measured
once per family. `*_run_s` / `*_run_rss` = median run wall-clock (s) / peak RSS
(MB). `vpt` = VarPointsTo tuple count. `verdict` = `COUNT_MATCH` when FlowLog
and Soufflé agree on VarPointsTo.

## Compile time & RSS (once per family)

| family | fl build s | fl build MB | sf-noplan build s | MB | sf-plan build s | MB |
|---|--:|--:|--:|--:|--:|--:|
| `context-insensitive` | 204 | 7,008 | 145 | 2,279 | 152 | 2,267 |
| `1-type-sensitive` | 243 | 9,261 | 153 | 2,267 | 154 | 2,273 |
| `1-type-sensitive+heap` | 239 | 9,753 | 151 | 2,268 | 151 | 2,274 |
| `1-call-site-sensitive` | 233 | 9,319 | 141 | 2,242 | 152 | 2,280 |
| `1-call-site-sensitive+heap` | 237 | 9,655 | 143 | 2,243 | 164 | 2,286 |

## Run time & RSS (per dataset x family, 32 threads, `.printsize`)

| dataset | family | fl run s | fl MB | sf-np run s | sf-np MB | sf-pl run s | sf-pl MB | VarPointsTo | verdict |
|---|---|--:|--:|--:|--:|--:|--:|--:|:--|
| luindex | `context-insensitive` | 13 | 4,269 | 37 | 2,882 | 26 | 3,336 | 5,396,536 | COUNT_MATCH |
| eclipse | `context-insensitive` | 17 | 5,880 | 67 | 4,879 | 41 | 5,649 | 10,539,055 | COUNT_MATCH |
| batik | `context-insensitive` | 37 | 10,811 | 244 | 12,991 | 114 | 14,874 | 28,249,074 | COUNT_MATCH |
| h2o | `context-insensitive` | 88 | 24,356 | 206 | 29,545 | 185 | 30,208 | 8,348,153 | COUNT_MATCH |
| xalan | `context-insensitive` | 17 | 3,896 | 31 | 2,690 | 25 | 2,871 | 2,387,458 | COUNT_MATCH |
| spring | `context-insensitive` | 32 | 10,869 | 213 | 12,563 | 102 | 15,165 | 27,878,606 | COUNT_MATCH |
| luindex | `1-type-sensitive` | 17 | 5,184 | 73 | 4,509 | 41 | 5,376 | 9,206,109 | COUNT_MATCH |
| eclipse | `1-type-sensitive` | 28 | 8,168 | 277 | 8,915 | 81 | 10,774 | 19,852,573 | COUNT_MATCH |
| batik | `1-type-sensitive` | 105 | 31,730 | 1299 | 48,869 | 433 | 56,553 | 111,708,068 | COUNT_MATCH |
| h2o | `1-type-sensitive` | 95 | 24,237 | 280 | 33,100 | 209 | 34,836 | 17,063,830 | COUNT_MATCH |
| xalan | `1-type-sensitive` | 18 | 4,518 | 43 | 3,618 | 33 | 4,009 | 4,489,202 | COUNT_MATCH |
| spring | `1-type-sensitive` | 67 | 19,271 | 1048 | 27,224 | 245 | 33,447 | 64,774,266 | COUNT_MATCH |
| luindex | `1-type-sensitive+heap` | 28 | 6,267 | 86 | 5,778 | 59 | 6,963 | 11,736,906 | COUNT_MATCH |
| eclipse | `1-type-sensitive+heap` | 66 | 11,108 | 378 | 13,633 | 156 | 16,647 | 30,087,958 | COUNT_MATCH |
| batik | `1-type-sensitive+heap` | 240 | 39,333 | 1638 | 58,586 | 663 | 69,461 | 133,591,421 | COUNT_MATCH |
| h2o | `1-type-sensitive+heap` | 120 | 24,494 | 320 | 35,594 | 254 | 38,027 | 22,055,530 | COUNT_MATCH |
| xalan | `1-type-sensitive+heap` | 22 | 4,993 | 49 | 4,135 | 40 | 4,640 | 5,355,043 | COUNT_MATCH |
| spring | `1-type-sensitive+heap` | 154 | 23,722 | 1040 | 34,056 | 405 | 42,370 | 77,597,754 | COUNT_MATCH |
| luindex | `1-call-site-sensitive` | 19 | 6,984 | 105 | 7,759 | 59 | 8,736 | 17,075,710 | COUNT_MATCH |
| eclipse | `1-call-site-sensitive` | 36 | 14,335 | 311 | 21,137 | 151 | 23,979 | 51,467,403 | COUNT_MATCH |
| batik | `1-call-site-sensitive` | 89 | 35,050 | 1075 | 59,889 | 471 | 67,266 | 147,130,198 | COUNT_MATCH |
| h2o | `1-call-site-sensitive` | 105 | 28,665 | 375 | 42,759 | 273 | 44,728 | 43,111,749 | COUNT_MATCH |
| xalan | `1-call-site-sensitive` | 21 | 6,013 | 79 | 5,737 | 47 | 6,371 | 9,499,690 | COUNT_MATCH |
| spring | `1-call-site-sensitive` | 91 | 38,435 | 1254 | 62,488 | 475 | 71,518 | 160,376,993 | COUNT_MATCH |
| luindex | `1-call-site-sensitive+heap` | 20 | 7,048 | 107 | 7,975 | 61 | 9,020 | 17,573,686 | COUNT_MATCH |
| eclipse | `1-call-site-sensitive+heap` | 44 | 17,469 | 395 | 27,318 | 200 | 31,166 | 68,151,180 | COUNT_MATCH |
| batik | `1-call-site-sensitive+heap` | 121 | 51,006 | 1569 | 89,061 | 692 | 99,820 | 223,455,772 | COUNT_MATCH |
| h2o | `1-call-site-sensitive+heap` | 111 | 31,024 | 439 | 50,180 | 308 | 52,950 | 62,617,880 | COUNT_MATCH |
| xalan | `1-call-site-sensitive+heap` | 20 | 6,184 | 80 | 5,890 | 48 | 6,493 | 9,802,668 | COUNT_MATCH |
| spring | `1-call-site-sensitive+heap` | 93 | 38,724 | 1260 | 66,101 | 488 | 75,817 | 169,388,627 | COUNT_MATCH |

## Observations (over the completed families)

- **FlowLog is fastest at run time on every completed cell** - often several x
  faster than Soufflé. Extreme case `1-call-site-sensitive+heap @ batik`:
  FlowLog **121 s** vs Soufflé no-plan **1569 s** / with-plan **692 s**.
- **DOOP `.plan` matters:** Soufflé with-plan is consistently ~2x faster than
  no-plan on the heavier cells (join-order tuning; identical output).
- **Compile cost trades the other way:** FlowLog's build (Rust codegen + rustc,
  ~200-245 s, 7-10 GB RSS) is slower and heavier than Soufflé's (~140-165 s,
  ~2.3 GB), but it is paid once per family.
- **Correctness:** all 30 completed cells `COUNT_MATCH`.

Raw data: [`time_flowlog-west3.tsv`](./time_flowlog-west3.tsv).

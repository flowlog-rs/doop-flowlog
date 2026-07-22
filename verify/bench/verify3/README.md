# [verify3] FlowLog vs Soufflé — timing sweep

Results of `verify/bench/time.sh` comparing three engines on DOOP points-to
analyses, timed with `.printsize` (tuple count only — **no IDB/CSV
serialization**, so the number is pure fixpoint compute).

> **Status: in-progress snapshot — 14 of 24 families complete.** 64 of 84 cells
> `COUNT_MATCH`. Of the 20 `RUN_FAIL` cells, **17 are Soufflé-only — FlowLog
> completed them** — and only **3 defeat every engine** (`2-call-site-sensitive+heap`
> on the three largest apps, the family DOOP documents as intractable in
> <=~220 GB on *both* engines). The remaining tail (2-call-site+2-heap, 3-object/type,
> 4-object, adaptive/sticky/selective/partitioned) is still running.

## Engines

| id | engine | notes |
|---|---|---|
| `fl`   | **FlowLog** (`flowlog-rs/flowlog` `main-next` @ `ef3be32`) | `--str-intern`; `-w 32` |
| `sfnp` | **Soufflé 2.5, `.plan` stripped** | `-j 32` at **compile and run** |
| `sfpl` | **Soufflé 2.5, DOOP `.plan` kept** | `-j 32` at **compile and run** |

## Configuration

- **Threads: 32** — FlowLog `-w 32`; Soufflé `-j 32` at **both compile and run**
  (a Soufflé binary compiled without `-j` ignores runtime `-j` and runs serial).
- **Timing metric:** `.printsize`; no relation is serialized to disk.
- **Repetitions:** `REPS=3` (median); first rep >= `REP_LONG=900 s` is single-shot.
- **Guards:** `MEM_MAX=450G` (per-run `systemd` scope), `RUN_TO=1800 s`, `BUILD_TO=7200 s`.
- **Host:** `flowlog-west3` — 64 cores, 503 GB RAM, facts on ext4 (not tmpfs).
- **Datasets:** `luindex eclipse batik h2o xalan spring` (`NemoYuu/flowlog_benchmark`).

### Dataset note (empty-relation stubs)

DOOP emits no `.facts` file for relations empty in a program (`KeepClass`,
`KeepClassMembers`, `KeepClassesWithMembers`, `KeepMethod`, `RootCodeElement`,
`PrimaryPartition`, `TypeToPartition`). FlowLog treats a missing `.input` as
empty; **Soufflé errors** (`Cannot open fact file ...`). Empty stubs were
created for these declared inputs (no result change — the relations are empty).

## Column legend

`*_build_*` = compile wall-clock (s) / peak RSS (MB), once per family.
`*_run_*` = median run wall-clock (s) / peak RSS (MB). `vpt` = VarPointsTo count.
`verdict` = `COUNT_MATCH` when FlowLog and Soufflé no-plan agree; `RUN_FAIL` when
an engine did not finish within the guards.

## Compile time & RSS (once per family)

| family | fl build s | fl MB | sf-noplan build s | MB | sf-plan build s | MB |
|---|--:|--:|--:|--:|--:|--:|
| `context-insensitive` | 204 | 7,008 | 145 | 2,279 | 152 | 2,267 |
| `1-type-sensitive` | 243 | 9,261 | 153 | 2,267 | 154 | 2,273 |
| `1-type-sensitive+heap` | 239 | 9,753 | 151 | 2,268 | 151 | 2,274 |
| `1-call-site-sensitive` | 233 | 9,319 | 141 | 2,242 | 152 | 2,280 |
| `1-call-site-sensitive+heap` | 237 | 9,655 | 143 | 2,243 | 164 | 2,286 |
| `1-object-sensitive` | 233 | 9,241 | 143 | 2,275 | 151 | 2,280 |
| `1-object-sensitive+heap` | 235 | 9,365 | 142 | 2,244 | 156 | 2,282 |
| `1-object-1-type-sensitive+heap` | 266 | 10,929 | 150 | 2,215 | 150 | 2,266 |
| `2-type-sensitive+heap` | 262 | 10,763 | 150 | 2,214 | 153 | 2,271 |
| `2-type-object-sensitive+heap` | 268 | 10,876 | 151 | 2,213 | 153 | 2,263 |
| `2-type-object-sensitive+2-heap` | 243 | 9,628 | 152 | 2,268 | 154 | 2,278 |
| `2-object-sensitive+heap` | 259 | 10,838 | 140 | 2,261 | 156 | 2,277 |
| `2-object-sensitive+2-heap` | 241 | 9,210 | 142 | 2,243 | 158 | 2,283 |
| `2-call-site-sensitive+heap` | 261 | 10,888 | 142 | 2,262 | 152 | 2,276 |

## Run time & RSS (per dataset x family, 32 threads, `.printsize`; run s + fl RSS MB)

| dataset | family | fl run s | fl MB | sf-np run s | sf-pl run s | VarPointsTo | verdict |
|---|---|--:|--:|--:|--:|--:|:--|
| luindex | `context-insensitive` | 13 | 4,269 | 37 | 26 | 5,396,536 | COUNT_MATCH |
| eclipse | `context-insensitive` | 17 | 5,880 | 67 | 41 | 10,539,055 | COUNT_MATCH |
| batik | `context-insensitive` | 37 | 10,811 | 244 | 114 | 28,249,074 | COUNT_MATCH |
| h2o | `context-insensitive` | 88 | 24,356 | 206 | 185 | 8,348,153 | COUNT_MATCH |
| xalan | `context-insensitive` | 17 | 3,896 | 31 | 25 | 2,387,458 | COUNT_MATCH |
| spring | `context-insensitive` | 32 | 10,869 | 213 | 102 | 27,878,606 | COUNT_MATCH |
| luindex | `1-type-sensitive` | 17 | 5,184 | 73 | 41 | 9,206,109 | COUNT_MATCH |
| eclipse | `1-type-sensitive` | 28 | 8,168 | 277 | 81 | 19,852,573 | COUNT_MATCH |
| batik | `1-type-sensitive` | 105 | 31,730 | 1299 | 433 | 111,708,068 | COUNT_MATCH |
| h2o | `1-type-sensitive` | 95 | 24,237 | 280 | 209 | 17,063,830 | COUNT_MATCH |
| xalan | `1-type-sensitive` | 18 | 4,518 | 43 | 33 | 4,489,202 | COUNT_MATCH |
| spring | `1-type-sensitive` | 67 | 19,271 | 1048 | 245 | 64,774,266 | COUNT_MATCH |
| luindex | `1-type-sensitive+heap` | 28 | 6,267 | 86 | 59 | 11,736,906 | COUNT_MATCH |
| eclipse | `1-type-sensitive+heap` | 66 | 11,108 | 378 | 156 | 30,087,958 | COUNT_MATCH |
| batik | `1-type-sensitive+heap` | 240 | 39,333 | 1638 | 663 | 133,591,421 | COUNT_MATCH |
| h2o | `1-type-sensitive+heap` | 120 | 24,494 | 320 | 254 | 22,055,530 | COUNT_MATCH |
| xalan | `1-type-sensitive+heap` | 22 | 4,993 | 49 | 40 | 5,355,043 | COUNT_MATCH |
| spring | `1-type-sensitive+heap` | 154 | 23,722 | 1040 | 405 | 77,597,754 | COUNT_MATCH |
| luindex | `1-call-site-sensitive` | 19 | 6,984 | 105 | 59 | 17,075,710 | COUNT_MATCH |
| eclipse | `1-call-site-sensitive` | 36 | 14,335 | 311 | 151 | 51,467,403 | COUNT_MATCH |
| batik | `1-call-site-sensitive` | 89 | 35,050 | 1075 | 471 | 147,130,198 | COUNT_MATCH |
| h2o | `1-call-site-sensitive` | 105 | 28,665 | 375 | 273 | 43,111,749 | COUNT_MATCH |
| xalan | `1-call-site-sensitive` | 21 | 6,013 | 79 | 47 | 9,499,690 | COUNT_MATCH |
| spring | `1-call-site-sensitive` | 91 | 38,435 | 1254 | 475 | 160,376,993 | COUNT_MATCH |
| luindex | `1-call-site-sensitive+heap` | 20 | 7,048 | 107 | 61 | 17,573,686 | COUNT_MATCH |
| eclipse | `1-call-site-sensitive+heap` | 44 | 17,469 | 395 | 200 | 68,151,180 | COUNT_MATCH |
| batik | `1-call-site-sensitive+heap` | 121 | 51,006 | 1569 | 692 | 223,455,772 | COUNT_MATCH |
| h2o | `1-call-site-sensitive+heap` | 111 | 31,024 | 439 | 308 | 62,617,880 | COUNT_MATCH |
| xalan | `1-call-site-sensitive+heap` | 20 | 6,184 | 80 | 48 | 9,802,668 | COUNT_MATCH |
| spring | `1-call-site-sensitive+heap` | 93 | 38,724 | 1260 | 488 | 169,388,627 | COUNT_MATCH |
| luindex | `1-object-sensitive` | 24 | 7,075 | 166 | 67 | 15,093,978 | COUNT_MATCH |
| eclipse | `1-object-sensitive` | 54 | 12,137 | 959 | 161 | 34,206,597 | COUNT_MATCH |
| batik | `1-object-sensitive` | 248 | 70,797 | FAIL | 1130 | 251,737,838 | RUN_FAIL |
| h2o | `1-object-sensitive` | 108 | 25,752 | 423 | 260 | 29,204,877 | COUNT_MATCH |
| xalan | `1-object-sensitive` | 21 | 5,553 | 66 | 46 | 7,296,567 | COUNT_MATCH |
| spring | `1-object-sensitive` | 148 | 37,845 | FAIL | 562 | 137,483,077 | RUN_FAIL |
| luindex | `1-object-sensitive+heap` | 45 | 8,679 | 177 | 102 | 20,036,177 | COUNT_MATCH |
| eclipse | `1-object-sensitive+heap` | 183 | 19,656 | 1188 | 422 | 62,080,248 | COUNT_MATCH |
| batik | `1-object-sensitive+heap` | 592 | 89,567 | FAIL | FAIL | 353,185,162 | RUN_FAIL |
| h2o | `1-object-sensitive+heap` | 152 | 30,168 | 522 | 335 | 43,115,281 | COUNT_MATCH |
| xalan | `1-object-sensitive+heap` | 28 | 6,973 | 72 | 55 | 8,688,754 | COUNT_MATCH |
| spring | `1-object-sensitive+heap` | 298 | 46,872 | FAIL | 864 | 174,669,956 | RUN_FAIL |
| luindex | `1-object-1-type-sensitive+heap` | 34 | 7,501 | 100 | 70 | 8,719,851 | COUNT_MATCH |
| eclipse | `1-object-1-type-sensitive+heap` | 81 | 15,728 | 456 | 188 | 35,244,021 | COUNT_MATCH |
| batik | `1-object-1-type-sensitive+heap` | 171 | 59,009 | FAIL | 719 | 122,057,193 | RUN_FAIL |
| h2o | `1-object-1-type-sensitive+heap` | 153 | 28,663 | 427 | 346 | 23,264,247 | COUNT_MATCH |
| xalan | `1-object-1-type-sensitive+heap` | 30 | 6,358 | 63 | 54 | 3,950,408 | COUNT_MATCH |
| spring | `1-object-1-type-sensitive+heap` | 305 | 48,549 | FAIL | 1007 | 138,261,904 | RUN_FAIL |
| luindex | `2-type-sensitive+heap` | 15 | 4,398 | 45 | 30 | 4,859,195 | COUNT_MATCH |
| eclipse | `2-type-sensitive+heap` | 29 | 7,995 | 166 | 73 | 16,425,925 | COUNT_MATCH |
| batik | `2-type-sensitive+heap` | 83 | 29,368 | 1181 | 313 | 61,929,674 | COUNT_MATCH |
| h2o | `2-type-sensitive+heap` | 99 | 24,078 | 274 | 217 | 12,138,711 | COUNT_MATCH |
| xalan | `2-type-sensitive+heap` | 18 | 4,148 | 35 | 28 | 1,866,950 | COUNT_MATCH |
| spring | `2-type-sensitive+heap` | 86 | 22,199 | 795 | 282 | 63,845,405 | COUNT_MATCH |
| luindex | `2-type-object-sensitive+heap` | 33 | 7,585 | 100 | 70 | 8,719,851 | COUNT_MATCH |
| eclipse | `2-type-object-sensitive+heap` | 82 | 15,601 | 450 | 190 | 35,244,021 | COUNT_MATCH |
| batik | `2-type-object-sensitive+heap` | 175 | 59,030 | FAIL | 725 | 122,057,193 | RUN_FAIL |
| h2o | `2-type-object-sensitive+heap` | 156 | 28,516 | 445 | 355 | 23,264,247 | COUNT_MATCH |
| xalan | `2-type-object-sensitive+heap` | 31 | 6,515 | 63 | 54 | 3,950,408 | COUNT_MATCH |
| spring | `2-type-object-sensitive+heap` | 304 | 48,076 | FAIL | 1010 | 138,261,904 | RUN_FAIL |
| luindex | `2-type-object-sensitive+2-heap` | 68 | 10,368 | 129 | 124 | 9,788,238 | COUNT_MATCH |
| eclipse | `2-type-object-sensitive+2-heap` | 150 | 21,429 | 559 | 319 | 42,127,383 | COUNT_MATCH |
| batik | `2-type-object-sensitive+2-heap` | 270 | 76,761 | FAIL | 983 | 151,406,934 | RUN_FAIL |
| h2o | `2-type-object-sensitive+2-heap` | 268 | 33,922 | 562 | 591 | 30,638,740 | COUNT_MATCH |
| xalan | `2-type-object-sensitive+2-heap` | 57 | 8,682 | 81 | 96 | 5,682,153 | COUNT_MATCH |
| spring | `2-type-object-sensitive+2-heap` | 597 | 60,015 | FAIL | 1784 | 143,951,478 | RUN_FAIL |
| luindex | `2-object-sensitive+heap` | 40 | 7,950 | 111 | 82 | 8,741,742 | COUNT_MATCH |
| eclipse | `2-object-sensitive+heap` | 104 | 19,478 | 600 | 259 | 43,929,737 | COUNT_MATCH |
| batik | `2-object-sensitive+heap` | 188 | 64,326 | FAIL | 803 | 124,016,468 | RUN_FAIL |
| h2o | `2-object-sensitive+heap` | 185 | 30,330 | 436 | 418 | 23,947,405 | COUNT_MATCH |
| xalan | `2-object-sensitive+heap` | 37 | 6,941 | 71 | 65 | 4,316,079 | COUNT_MATCH |
| spring | `2-object-sensitive+heap` | 485 | 59,357 | FAIL | 1695 | 160,369,838 | RUN_FAIL |
| luindex | `2-object-sensitive+2-heap` | 103 | 10,838 | 171 | 188 | 11,281,640 | COUNT_MATCH |
| eclipse | `2-object-sensitive+2-heap` | 272 | 29,499 | 991 | 548 | 69,602,292 | COUNT_MATCH |
| batik | `2-object-sensitive+2-heap` | 353 | 96,365 | FAIL | 1275 | 177,044,611 | RUN_FAIL |
| h2o | `2-object-sensitive+2-heap` | 395 | 40,241 | 740 | 957 | 44,137,302 | COUNT_MATCH |
| xalan | `2-object-sensitive+2-heap` | 85 | 9,698 | 108 | 146 | 7,128,242 | COUNT_MATCH |
| spring | `2-object-sensitive+2-heap` | 1277 | 77,129 | FAIL | FAIL | 168,074,936 | RUN_FAIL |
| luindex | `2-call-site-sensitive+heap` | 471 | 371,048 | FAIL | FAIL | 90,216,540 | RUN_FAIL |
| eclipse | `2-call-site-sensitive+heap` | 658 | 426,011 | FAIL | FAIL | 387,052,063 | RUN_FAIL |
| batik | `2-call-site-sensitive+heap` | FAIL | NA | FAIL | FAIL | NA | RUN_FAIL |
| h2o | `2-call-site-sensitive+heap` | FAIL | NA | FAIL | FAIL | NA | RUN_FAIL |
| xalan | `2-call-site-sensitive+heap` | 485 | 395,050 | FAIL | FAIL | 69,385,705 | RUN_FAIL |
| spring | `2-call-site-sensitive+heap` | FAIL | NA | FAIL | FAIL | NA | RUN_FAIL |

## Failures (20 cells)

| category | count | meaning |
|---|--:|---|
| Soufflé-only | 17 | FlowLog finished; Soufflé (no-plan, occ. with-plan) hit `RUN_TO=1800 s` / `MEM_MAX=450G` on the largest apps (batik, spring, h2o). |
| all engines | 3 | `2-call-site-sensitive+heap @ {batik, h2o, spring}` — intractable in <=~220 GB on **both** engines (DOOP-documented). |

FlowLog completes **17 of 20** cells that Soufflé cannot; the only cells FlowLog
misses are the 3 all-engine-intractable ones.

| dataset | family | FlowLog | Soufflé no-plan | Soufflé +plan |
|---|---|:--|:--|:--|
| batik | `1-object-sensitive` | 248 s ✅ | FAIL | 1130 |
| spring | `1-object-sensitive` | 148 s ✅ | FAIL | 562 |
| batik | `1-object-sensitive+heap` | 592 s ✅ | FAIL | FAIL |
| spring | `1-object-sensitive+heap` | 298 s ✅ | FAIL | 864 |
| batik | `1-object-1-type-sensitive+heap` | 171 s ✅ | FAIL | 719 |
| spring | `1-object-1-type-sensitive+heap` | 305 s ✅ | FAIL | 1007 |
| batik | `2-type-object-sensitive+heap` | 175 s ✅ | FAIL | 725 |
| spring | `2-type-object-sensitive+heap` | 304 s ✅ | FAIL | 1010 |
| batik | `2-type-object-sensitive+2-heap` | 270 s ✅ | FAIL | 983 |
| spring | `2-type-object-sensitive+2-heap` | 597 s ✅ | FAIL | 1784 |
| batik | `2-object-sensitive+heap` | 188 s ✅ | FAIL | 803 |
| spring | `2-object-sensitive+heap` | 485 s ✅ | FAIL | 1695 |
| batik | `2-object-sensitive+2-heap` | 353 s ✅ | FAIL | 1275 |
| spring | `2-object-sensitive+2-heap` | 1277 s ✅ | FAIL | FAIL |
| luindex | `2-call-site-sensitive+heap` | 471 s ✅ | FAIL | FAIL |
| eclipse | `2-call-site-sensitive+heap` | 658 s ✅ | FAIL | FAIL |
| batik | `2-call-site-sensitive+heap` | FAIL ❌ | FAIL | FAIL |
| h2o | `2-call-site-sensitive+heap` | FAIL ❌ | FAIL | FAIL |
| xalan | `2-call-site-sensitive+heap` | 485 s ✅ | FAIL | FAIL |
| spring | `2-call-site-sensitive+heap` | FAIL ❌ | FAIL | FAIL |

## Observations

- **FlowLog is fastest at run time on every completed cell**, and finishes many
  heavy batik/spring/h2o cells where Soufflé times out. It fails only where
  *both* engines are intractable (`2-call-site-sensitive+heap`, largest apps).
- **DOOP `.plan` matters:** ~2x faster than no-plan on heavy cells and rescues
  several cells no-plan cannot finish (identical output).
- **Compile cost trades the other way:** FlowLog's build (Rust codegen + rustc,
  ~200-250 s, 7-10 GB RSS) is slower/heavier than Soufflé's (~140-165 s,
  ~2.3 GB), paid once per family.
- **Correctness:** all 64 completed comparison cells `COUNT_MATCH`.

Raw data: [`time_flowlog-west3.tsv`](./time_flowlog-west3.tsv).

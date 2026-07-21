# [verify3] FlowLog vs Soufflé — timing sweep

Results of `verify/bench/time.sh` comparing three engines on DOOP points-to
analyses, timed with `.printsize` (tuple count only — **no IDB/CSV
serialization**, so the number is pure fixpoint compute).

> **Status: in-progress snapshot — 10 of 24 families complete.** 52 of 60 cells
> `COUNT_MATCH`; the 8 `RUN_FAIL` cells are all **Soufflé** exceeding the run
> guards on the two largest datasets (batik, spring) — **FlowLog completed every
> one of them** (see *Failures* below). The heavy context-sensitive tail
> (2-object+2-heap, 2-call-site, 3-object/type, 4-object, adaptive/…) is still
> running; this file is refreshed as families finish.

## Engines

| id | engine | notes |
|---|---|---|
| `fl`   | **FlowLog** (`flowlog-rs/flowlog` `main-next` @ `ef3be32`) | `--str-intern`; `-w 32` |
| `sfnp` | **Soufflé 2.5, `.plan` stripped** | `-j 32` at **compile and run** |
| `sfpl` | **Soufflé 2.5, DOOP `.plan` kept** | `-j 32` at **compile and run** |

## Configuration

- **Threads: 32** — FlowLog `-w 32`; Soufflé `-j 32` at **both compile and run**
  (a Soufflé binary compiled without `-j` ignores runtime `-j` and runs serial).
- **Timing metric:** `.printsize` (every `.output` rewritten to `.printsize`);
  no relation is serialized to disk.
- **Repetitions:** `REPS=3` (median); a first rep >= `REP_LONG=900 s` is a
  single measurement.
- **Guards:** `MEM_MAX=450G` (per-run `systemd` scope), `RUN_TO=1800 s`,
  `BUILD_TO=7200 s`.
- **Host:** `flowlog-west3` — 64 cores, 503 GB RAM, facts on ext4 (not tmpfs).
- **Datasets:** `luindex eclipse batik h2o xalan spring` (`NemoYuu/flowlog_benchmark`).

### Dataset note (empty-relation stubs)

DOOP emits no `.facts` file for relations that are empty for a program
(`KeepClass`, `KeepClassMembers`, `KeepClassesWithMembers`, `KeepMethod`,
`RootCodeElement`, `PrimaryPartition`, `TypeToPartition`). FlowLog treats a
missing `.input` as empty; **Soufflé errors** (`Cannot open fact file ...`).
Empty stubs were created for these declared inputs so all three engines run on
identical inputs (no result change — the relations are genuinely empty).

## Column legend

`*_build_s` / `*_build_rss` = compile wall-clock (s) / peak RSS (MB), once per
family. `*_run_s` / `*_run_rss` = median run wall-clock (s) / peak RSS (MB).
`vpt` = VarPointsTo count. `verdict` = `COUNT_MATCH` when FlowLog and Soufflé
no-plan agree; `RUN_FAIL` when the Soufflé no-plan oracle did not finish.

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
| luindex | `1-object-sensitive` | 24 | 7,075 | 166 | 7,208 | 67 | 8,573 | 15,093,978 | COUNT_MATCH |
| eclipse | `1-object-sensitive` | 54 | 12,137 | 959 | 15,420 | 161 | 18,616 | 34,206,597 | COUNT_MATCH |
| batik | `1-object-sensitive` | 248 | 70,797 | FAIL | NA | 1130 | 129,544 | 251,737,838 | RUN_FAIL |
| h2o | `1-object-sensitive` | 108 | 25,752 | 423 | 38,303 | 260 | 40,694 | 29,204,877 | COUNT_MATCH |
| xalan | `1-object-sensitive` | 21 | 5,553 | 66 | 4,954 | 46 | 5,546 | 7,296,567 | COUNT_MATCH |
| spring | `1-object-sensitive` | 148 | 37,845 | FAIL | NA | 562 | 68,656 | 137,483,077 | RUN_FAIL |
| luindex | `1-object-sensitive+heap` | 45 | 8,679 | 177 | 9,619 | 102 | 11,556 | 20,036,177 | COUNT_MATCH |
| eclipse | `1-object-sensitive+heap` | 183 | 19,656 | 1188 | 27,940 | 422 | 34,269 | 62,080,248 | COUNT_MATCH |
| batik | `1-object-sensitive+heap` | 592 | 89,567 | FAIL | NA | FAIL | NA | 353,185,162 | RUN_FAIL |
| h2o | `1-object-sensitive+heap` | 152 | 30,168 | 522 | 44,591 | 335 | 48,555 | 43,115,281 | COUNT_MATCH |
| xalan | `1-object-sensitive+heap` | 28 | 6,973 | 72 | 5,721 | 55 | 6,479 | 8,688,754 | COUNT_MATCH |
| spring | `1-object-sensitive+heap` | 298 | 46,872 | FAIL | NA | 864 | 87,989 | 174,669,956 | RUN_FAIL |
| luindex | `1-object-1-type-sensitive+heap` | 34 | 7,501 | 100 | 5,310 | 70 | 6,186 | 8,719,851 | COUNT_MATCH |
| eclipse | `1-object-1-type-sensitive+heap` | 81 | 15,728 | 456 | 16,975 | 188 | 20,906 | 35,244,021 | COUNT_MATCH |
| batik | `1-object-1-type-sensitive+heap` | 171 | 59,009 | FAIL | NA | 719 | 85,400 | 122,057,193 | RUN_FAIL |
| h2o | `1-object-1-type-sensitive+heap` | 153 | 28,663 | 427 | 37,968 | 346 | 40,294 | 23,264,247 | COUNT_MATCH |
| xalan | `1-object-1-type-sensitive+heap` | 30 | 6,358 | 63 | 4,090 | 54 | 4,525 | 3,950,408 | COUNT_MATCH |
| spring | `1-object-1-type-sensitive+heap` | 305 | 48,549 | FAIL | NA | 1007 | 76,864 | 138,261,904 | RUN_FAIL |
| luindex | `2-type-sensitive+heap` | 15 | 4,398 | 45 | 2,914 | 30 | 3,386 | 4,859,195 | COUNT_MATCH |
| eclipse | `2-type-sensitive+heap` | 29 | 7,995 | 166 | 7,884 | 73 | 9,573 | 16,425,925 | COUNT_MATCH |
| batik | `2-type-sensitive+heap` | 83 | 29,368 | 1181 | 34,599 | 313 | 41,077 | 61,929,674 | COUNT_MATCH |
| h2o | `2-type-sensitive+heap` | 99 | 24,078 | 274 | 31,842 | 217 | 33,220 | 12,138,711 | COUNT_MATCH |
| xalan | `2-type-sensitive+heap` | 18 | 4,148 | 35 | 2,678 | 28 | 2,862 | 1,866,950 | COUNT_MATCH |
| spring | `2-type-sensitive+heap` | 86 | 22,199 | 795 | 28,221 | 282 | 35,270 | 63,845,405 | COUNT_MATCH |
| luindex | `2-type-object-sensitive+heap` | 33 | 7,585 | 100 | 5,303 | 70 | 6,175 | 8,719,851 | COUNT_MATCH |
| eclipse | `2-type-object-sensitive+heap` | 82 | 15,601 | 450 | 17,084 | 190 | 20,899 | 35,244,021 | COUNT_MATCH |
| batik | `2-type-object-sensitive+heap` | 175 | 59,030 | FAIL | NA | 725 | 85,249 | 122,057,193 | RUN_FAIL |
| h2o | `2-type-object-sensitive+heap` | 156 | 28,516 | 445 | 37,897 | 355 | 40,356 | 23,264,247 | COUNT_MATCH |
| xalan | `2-type-object-sensitive+heap` | 31 | 6,515 | 63 | 4,077 | 54 | 4,520 | 3,950,408 | COUNT_MATCH |
| spring | `2-type-object-sensitive+heap` | 304 | 48,076 | FAIL | NA | 1010 | 77,261 | 138,261,904 | RUN_FAIL |

## Failures (8 cells)

Every `RUN_FAIL` is **Soufflé** (always no-plan; with-plan too on
`1-object-sensitive+heap @ batik`) exceeding a per-run guard (`RUN_TO=1800 s`
wall-clock and/or `MEM_MAX=450G`) on the two datasets with the largest
points-to sets (**batik**, **spring**). **FlowLog finished all of them**, so
these are Soufflé-only limits, not correctness gaps.

| dataset | family | fl run s | sf-noplan | sf-plan |
|---|---|--:|:--|:--|
| batik | `1-object-sensitive` | 248 ✓ | FAIL | 1130 |
| spring | `1-object-sensitive` | 148 ✓ | FAIL | 562 |
| batik | `1-object-sensitive+heap` | 592 ✓ | FAIL | FAIL |
| spring | `1-object-sensitive+heap` | 298 ✓ | FAIL | 864 |
| batik | `1-object-1-type-sensitive+heap` | 171 ✓ | FAIL | 719 |
| spring | `1-object-1-type-sensitive+heap` | 305 ✓ | FAIL | 1007 |
| batik | `2-type-object-sensitive+heap` | 175 ✓ | FAIL | 725 |
| spring | `2-type-object-sensitive+heap` | 304 ✓ | FAIL | 1010 |

## Observations (over the completed families)

- **FlowLog is fastest at run time on every completed cell** - often several x
  faster than Soufflé, and it finishes heavy batik/spring cells where Soufflé
  no-plan times out. E.g. `1-call-site-sensitive+heap @ batik`: FlowLog
  **121 s** vs no-plan **1569 s** / with-plan **692 s**.
- **DOOP `.plan` matters:** with-plan is ~2x faster than no-plan on heavy cells
  and rescues several cells that no-plan cannot finish (identical output).
- **Compile cost trades the other way:** FlowLog's build (Rust codegen + rustc,
  ~200-245 s, 7-10 GB RSS) is slower/heavier than Soufflé's (~140-165 s,
  ~2.3 GB), but is paid once per family.
- **Correctness:** all 52 completed comparison cells `COUNT_MATCH`.

Raw data: [`time_flowlog-west3.tsv`](./time_flowlog-west3.tsv).

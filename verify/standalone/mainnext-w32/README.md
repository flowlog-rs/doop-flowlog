# FlowLog (main-next + ord fix) vs Soufflé — multithreaded `-w32`/`-j32`, byte-exact, 2 datasets

Multithreaded correctness + performance study of **FlowLog** against **Soufflé** on the 19
byte-exact-verified DOOP `VarPointsTo` families, run end-to-end on two DaCapo fact sets
(**luindex**, **eclipse**). Extends the single-thread study in `../../results.tsv` /
`../../timing_summary.tsv` to 32 threads and a second dataset.

## TL;DR

- **Correctness: 19/19 byte-exact identical to Soufflé on BOTH datasets** (38/38 program×dataset
  runs; 0 tuples unique to either engine). FlowLog's `-w 32` output matches the single-thread
  Soufflé oracle exactly — the **ord-determinism fix ([flowlog#208]) makes parallel FlowLog
  deterministic and correct**.
- **Performance: FlowLog faster on 16/19 families** on each dataset (geomean **1.6×** on luindex,
  **2.9×** on eclipse; up to **12.5×**). The **only** 3 losses are the *object+type-combined*
  sensitivities, on both datasets — a structural scaling gap, not a correctness issue.
- **FlowLog's advantage grows with workload size** (every winning family is faster on the larger
  eclipse app) and its **peak memory scales better** (median FL/SF 1.48× on luindex → **0.92×**
  on eclipse, i.e. less than Soufflé).

## What was done

1. Built FlowLog at **`main-next` (`b87c99e`) + PR [flowlog#208]** (deterministic `ord` via
   single-thread fact interning; cherry-picked → `1a49e90`).
2. Assembled the 19 families as single-file programs via `cpp` from this repo's
   `flowlog-logic/` (bare grammar, main-next-compatible) and `souffle-logic/` — see `assemble.sh`.
   *(The `../flowlog/*.dl` standalone programs use the `= True` nemo/tuple grammar and panic on
   `main-next`; the bare-grammar encoding is required and byte-exact-equivalent.)*
3. Compiled each: FlowLog `--mode datalog-batch --str-intern`; Soufflé `-c -j 32`.
4. Ran FlowLog `-w 32` (batch) vs Soufflé `-j 32` on each dataset; captured wall clock and peak
   RSS (`/usr/bin/time -v`, min of 2 runs); compared `VarPointsTo` **byte-exact** after bracket
   canonicalisation + sort (`comm`).
5. Repeated on a second dataset (eclipse) by repointing a `/datasets/facts/CURRENT` symlink that
   FlowLog's fact dir is baked against — one compile per program serves any dataset.

## Benchmark configuration

| | |
|---|---|
| FlowLog | `flowlog-rs/flowlog` `main-next` `b87c99e` **+ [flowlog#208]** (`1a49e90`) |
| FlowLog run | **batch** (`--mode datalog-batch`), `--str-intern`, **`-w 32`** |
| Soufflé | v2.5 (openmp), compiled **`-j 32`**, run **`-j 32`** |
| Programs | 19 verified DOOP families, `VarPointsTo` only, assembled via `cpp` from `flowlog-logic/` + `souffle-logic/` |
| Datasets | DaCapo **luindex** (713 MB EDB) and **eclipse** (685 MB EDB) |
| Host | 64-core, 503 GB RAM |
| Metrics | end-to-end wall clock, peak RSS; byte-exact `VarPointsTo` (FL vs SF) |

## Correctness (headline)

**19/19 byte-exact MATCH on both luindex and eclipse.** Every family: `only_FL = only_SF = 0`.
Determinism spot-check: `1-type-sensitive` @ `-w 32` byte-identical across repeated runs
(the family that *drifted* before [flowlog#208]).

## Performance — luindex (713 MB)

| family | VPT rows | FL s | SF s | FL GB | SF GB | SF/FL | winner |
|---|--:|--:|--:|--:|--:|--:|:--:|
| context-insensitive | 5396536 | 20 | 41 | 4.49 | 2.82 | **2.03×** | FL 2.03× |
| 1-type-sensitive | 9206109 | 25 | 78 | 5.34 | 4.40 | **3.05×** | FL 3.05× |
| 1-type-sensitive+heap | 11736906 | 38 | 95 | 6.29 | 5.65 | **2.53×** | FL 2.53× |
| 1-call-site-sensitive | 17075710 | 28 | 117 | 7.23 | 7.61 | **4.12×** | FL 4.12× |
| 1-call-site-sensitive+heap | 17573686 | 31 | 126 | 7.30 | 7.82 | **4.10×** | FL 4.10× |
| 1-object-sensitive | 15093978 | 35 | 178 | 7.16 | 7.09 | **5.04×** | FL 5.04× |
| 1-object-sensitive+heap | 20036177 | 66 | 208 | 8.53 | 9.40 | **3.15×** | FL 3.15× |
| 1-object-1-type-sensitive+heap | 8719851 | 665 | 109 | 7.55 | 5.18 | **0.16×** | SF 6.25× |
| 2-type-sensitive+heap | 4859195 | 24 | 50 | 4.55 | 2.85 | **2.07×** | FL 2.07× |
| 2-type-object-sensitive+heap | 8719851 | 633 | 110 | 7.55 | 5.18 | **0.17×** | SF 5.88× |
| 2-type-object-sensitive+2-heap | 9788238 | 701 | 140 | 10.67 | 5.80 | **0.20×** | SF 5.00× |
| 2-object-sensitive+heap | 8741742 | 55 | 117 | 7.92 | 5.44 | **2.11×** | FL 2.11× |
| 2-object-sensitive+2-heap | 11281640 | 131 | 190 | 11.76 | 6.73 | **1.45×** | FL 1.45× |
| adaptive-2-object-sensitive+heap | 8741742 | 56 | 117 | 8.04 | 5.44 | **2.10×** | FL 2.10× |
| 3-type-sensitive+2-heap | 1483057 | 19 | 26 | 3.81 | 1.47 | **1.36×** | FL 1.36× |
| 3-type-sensitive+3-heap | 1484975 | 18 | 27 | 3.97 | 1.46 | **1.51×** | FL 1.51× |
| 3-object-sensitive+2-heap | 3411656 | 22 | 57 | 5.40 | 2.67 | **2.65×** | FL 2.65× |
| 3-object-sensitive+3-heap | 3417156 | 21 | 59 | 5.55 | 2.67 | **2.76×** | FL 2.76× |
| 4-object-sensitive+4-heap | 3212708 | 21 | 57 | 5.92 | 2.57 | **2.71×** | FL 2.71× |

## Performance — eclipse (685 MB EDB; much larger analysis)

| family | VPT rows | FL s | SF s | FL GB | SF GB | SF/FL | winner |
|---|--:|--:|--:|--:|--:|--:|:--:|
| context-insensitive | 10539055 | 24 | 75 | 6.06 | 4.77 | **3.14×** | FL 3.14× |
| 1-type-sensitive | 19852573 | 39 | 290 | 8.15 | 8.71 | **7.36×** | FL 7.36× |
| 1-type-sensitive+heap | 30087958 | 83 | 417 | 11.01 | 13.30 | **5.03×** | FL 5.03× |
| 1-call-site-sensitive | 51467403 | 53 | 393 | 14.32 | 20.63 | **7.46×** | FL 7.46× |
| 1-call-site-sensitive+heap | 68151180 | 83 | 558 | 17.36 | 26.93 | **6.71×** | FL 6.71× |
| 1-object-sensitive | 34206597 | 76 | 944 | 12.13 | 15.07 | **12.48×** | FL 12.48× |
| 1-object-sensitive+heap | 62080248 | 258 | 1310 | 19.74 | 27.20 | **5.08×** | FL 5.08× |
| 1-object-1-type-sensitive+heap | 35244021 | 2303 | 539 | 15.30 | 16.73 | **0.23×** | SF 4.35× |
| 2-type-sensitive+heap | 16425925 | 42 | 181 | 8.07 | 7.70 | **4.35×** | FL 4.35× |
| 2-type-object-sensitive+heap | 35244021 | 2335 | 532 | 15.31 | 16.63 | **0.23×** | SF 4.35× |
| 2-type-object-sensitive+2-heap | 42127383 | 2957 | 669 | 20.73 | 19.73 | **0.23×** | SF 4.35× |
| 2-object-sensitive+heap | 43929737 | 162 | 729 | 19.04 | 21.17 | **4.50×** | FL 4.50× |
| 2-object-sensitive+2-heap | 69602292 | 409 | 1243 | 28.62 | 32.15 | **3.04×** | FL 3.04× |
| adaptive-2-object-sensitive+heap | 43929737 | 157 | 730 | 19.25 | 21.25 | **4.64×** | FL 4.64× |
| 3-type-sensitive+2-heap | 4443710 | 22 | 62 | 5.15 | 2.80 | **2.80×** | FL 2.80× |
| 3-type-sensitive+3-heap | 4598065 | 22 | 65 | 5.43 | 2.87 | **2.94×** | FL 2.94× |
| 3-object-sensitive+2-heap | 7352446 | 29 | 117 | 7.25 | 4.72 | **4.08×** | FL 4.08× |
| 3-object-sensitive+3-heap | 8127441 | 30 | 124 | 7.94 | 5.07 | **4.14×** | FL 4.14× |
| 4-object-sensitive+4-heap | 7486106 | 31 | 124 | 8.95 | 4.83 | **4.04×** | FL 4.04× |

## Cross-dataset speedup (Soufflé wall / FlowLog wall — higher = FlowLog faster)

| family | luindex | eclipse | byte-exact (lu / ec) |
|---|--:|--:|:--:|
| 1-object-1-type-sensitive+heap | 0.16× | 0.23× | ✅ / ✅ |
| 2-type-object-sensitive+2-heap | 0.20× | 0.23× | ✅ / ✅ |
| 2-type-object-sensitive+heap | 0.17× | 0.23× | ✅ / ✅ |
| 3-type-sensitive+2-heap | 1.36× | 2.80× | ✅ / ✅ |
| 3-type-sensitive+3-heap | 1.51× | 2.94× | ✅ / ✅ |
| 2-object-sensitive+2-heap | 1.45× | 3.04× | ✅ / ✅ |
| context-insensitive | 2.03× | 3.14× | ✅ / ✅ |
| 4-object-sensitive+4-heap | 2.71× | 4.04× | ✅ / ✅ |
| 3-object-sensitive+2-heap | 2.65× | 4.08× | ✅ / ✅ |
| 3-object-sensitive+3-heap | 2.76× | 4.14× | ✅ / ✅ |
| 2-type-sensitive+heap | 2.07× | 4.35× | ✅ / ✅ |
| 2-object-sensitive+heap | 2.11× | 4.50× | ✅ / ✅ |
| adaptive-2-object-sensitive+heap | 2.10× | 4.64× | ✅ / ✅ |
| 1-type-sensitive+heap | 2.53× | 5.03× | ✅ / ✅ |
| 1-object-sensitive+heap | 3.15× | 5.08× | ✅ / ✅ |
| 1-call-site-sensitive+heap | 4.10× | 6.71× | ✅ / ✅ |
| 1-type-sensitive | 3.05× | 7.36× | ✅ / ✅ |
| 1-call-site-sensitive | 4.12× | 7.46× | ✅ / ✅ |
| 1-object-sensitive | 5.04× | 12.48× | ✅ / ✅ |

*Sorted by luindex speedup. The top 3 rows (object+type combos) are the only Soufflé wins — on
both datasets. All 19 are byte-exact identical on both.*

## Aggregates

| metric | luindex | eclipse |
|---|--:|--:|
| Byte-exact correctness | **19/19 MATCH** | **19/19 MATCH** |
| FlowLog faster / slower | 16 / 3 | 16 / 3 |
| Speedup geomean · median · max | 1.64× · 2.11× · 5.04× | 2.92× · 4.14× · 12.48× |
| Peak-RSS FL/SF geomean · median | 1.52× · 1.48× | 1.05× · 0.92× |
| FL peak RSS range · SF peak RSS range | 3.8–11.8 · 1.5–9.4 GB | 5.2–28.6 · 2.8–32.1 GB |
| Σ VarPointsTo rows (19 families) | 170.0 M | 594.9 M |

## Implications

- **Parallel FlowLog is safe to trust.** With [flowlog#208], `-w 32` reproduces the Soufflé oracle
  byte-for-byte on every family and both datasets — no count drift, no nondeterminism.
- **FlowLog is the faster engine for pointer analysis at scale**, winning 16/19 families and pulling
  further ahead as the input grows (up to 12.5× on eclipse's `1-object-sensitive`), while using
  comparable-or-less peak memory on large inputs.
- **One known weakness: object+type-combined context.** `1-object-1-type-sensitive+heap`,
  `2-type-object-sensitive+heap`, `2-type-object-sensitive+2-heap` are ~4–6× slower than Soufflé on
  both datasets (still byte-exact). FlowLog's wall time on these barely improves with more workers —
  a scheduling/scaling gap specific to this context flavour, and the clear target for optimisation.

## Reproduce

```bash
# 1. FlowLog compiler = main-next + PR #208:
#    git checkout -B bench origin/main-next && git cherry-pick 82b1049 && cargo build --release
# 2. assemble 19 bare-grammar + souffle programs from this repo's logic trees:
./assemble.sh
# 3. dataset-agnostic FlowLog binaries (fact dir = /datasets/facts/CURRENT symlink):
./build_agnostic.sh
# 4. run one dataset (FL -w32 vs SF -j32, byte-exact compare):
./run_dataset.sh luindex   # or eclipse, tomcat, … any DOOP fact dir
```

Raw data: `results_luindex.tsv`, `results_eclipse.tsv`. Scripts carry absolute paths from the
benchmark host (`/home/azureuser/doop-e2e`, `/datasets/facts/<dataset>`); adjust the `BASE`/`FACTS`
variables at the top of each for another environment.

[flowlog#208]: https://github.com/flowlog-rs/flowlog/pull/208

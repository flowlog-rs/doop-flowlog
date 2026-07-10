# Multi-dataset extension — FlowLog (main-next + #208) vs Soufflé, 3 more DaCapo programs

Extends the two-dataset study (`../results_luindex.tsv`, `../results_eclipse.tsv`) to **five** DaCapo
fact sets, running the same 19 DOOP families, FlowLog batch `-w32` vs Soufflé `-j32`, byte-exact.

## Summary — all five datasets

| dataset | byte-exact | FlowLog faster | geomean SF/FL | speedup range |
|---|:--:|:--:|--:|--:|
| luindex  | **19/19** | 16/19 | 1.64× | 0.16–5.04× |
| eclipse  | **19/19** | 16/19 | 2.92× | 0.23–12.48× |
| tomcat   | **19/19** | 16/19 | 1.43× | 0.18–3.75× |
| lusearch | **19/19** | 16/19 | 1.65× | 0.16–4.90× |
| cassandra | see note | 16/19 | 1.34× | 0.20–3.57× |

**The performance story is identical on every dataset:** FlowLog wins **16/19** families; the only
losses are the same 3 object+type-combined analyses (0.16–0.23×, the target of PR flowlog#218).
FlowLog's edge scales with program size (geomean 1.34× on small cassandra → 2.92× on large eclipse).

## Correctness

- **luindex, eclipse, tomcat, lusearch: 19/19 byte-exact** vs Soufflé (`only_FL = only_SF = 0`).
- **cassandra: all 19 families differ by a small margin** (~0.05–0.3%). This is **not** contamination
  and **not** parallel nondeterminism — it reproduces **deterministically at `-w1`** (verified on
  `context-insensitive`: 2 545 822 rows both engines, 2341 tuples each way). It is the known
  FlowLog↔Soufflé **representative-choice** difference (object/call-site families have **identical
  counts**, symmetric set-diff) plus the **ord count-drift** on type-sensitive families — both benign
  analysis-equivalence differences that cassandra's facts happen to trigger where the other four
  DaCapo programs do not. Counts and diffs per family in `results_cassandra.tsv`.

## Cross-dataset speedup (Soufflé wall / FlowLog wall — higher = FlowLog faster)

| family | luindex | eclipse | tomcat | lusearch | cassandra |
|---|--:|--:|--:|--:|--:|
| 1-object-1-type-sensitive+heap | 0.16× | 0.23× | 0.19× | 0.17× | 0.20× |
| 2-type-object-sensitive+heap | 0.17× | 0.23× | 0.18× | 0.16× | 0.20× |
| 2-type-object-sensitive+2-heap | 0.20× | 0.23× | 0.20× | 0.19× | 0.23× |
| 3-type-sensitive+2-heap | 1.36× | 2.80× | 1.47× | 1.46× | 1.19× |
| 2-object-sensitive+2-heap | 1.45× | 3.04× | 1.20× | 1.49× | 1.14× |
| 3-type-sensitive+3-heap | 1.51× | 2.94× | 1.59× | 1.52× | 1.31× |
| context-insensitive | 2.03× | 3.14× | 1.56× | 1.96× | 1.45× |
| 2-type-sensitive+heap | 2.07× | 4.35× | 1.75× | 2.15× | 1.55× |
| adaptive-2-object-sensitive+heap | 2.10× | 4.64× | 1.81× | 2.22× | 1.51× |
| 2-object-sensitive+heap | 2.11× | 4.50× | 1.79× | 2.15× | 1.57× |
| 1-type-sensitive+heap | 2.53× | 5.03× | 1.89× | 2.80× | 2.06× |
| 3-object-sensitive+2-heap | 2.65× | 4.08× | 2.19× | 2.40× | 1.91× |
| 4-object-sensitive+4-heap | 2.71× | 4.04× | 2.48× | 2.41× | 2.04× |
| 3-object-sensitive+3-heap | 2.76× | 4.14× | 2.34× | 2.47× | 2.12× |
| 1-type-sensitive | 3.05× | 7.36× | 2.32× | 3.00× | 2.05× |
| 1-object-sensitive+heap | 3.15× | 5.08× | 2.44× | 3.27× | 2.37× |
| 1-call-site-sensitive+heap | 4.10× | 6.71× | 3.75× | 4.90× | 3.57× |
| 1-call-site-sensitive | 4.12× | 7.46× | 3.60× | 4.26× | 3.42× |
| 1-object-sensitive | 5.04× | 12.48× | 2.74× | 4.67× | 2.89× |

*Sorted by luindex. The top 3 rows (object+type combos) are the only losses — on **every** dataset —
which PR flowlog#218 fixes (see `../w3-fusion-check/`). The other 16 families: FlowLog wins on all five.*

## Files

`results_tomcat.tsv`, `results_lusearch.tsv`, `results_cassandra.tsv` — per-family rows, wall, peak
RSS, SF/FL speedup, byte-exact verdict, and the `only_FL`/`only_SF` diff counts.

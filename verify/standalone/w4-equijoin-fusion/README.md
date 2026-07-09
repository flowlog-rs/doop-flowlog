# [w4] Equi-join fusion (flowlog#218) verified — before/after vs Soufflé, 7 DaCapo datasets

Follow-up to **[w2]** (`../mainnext-w32`), which verified FlowLog byte-exact against Soufflé
but found the three **object+type-combined** analyses lose by **5–6×**, and to the **[w3]**
equi-join fusion ([flowlog#218]) that fixes the root cause. This study measures the fusion
end-to-end: FlowLog **without** vs **with** #218, both against the Soufflé oracle, on **7
DaCapo fact sets**.

[flowlog#218]: https://github.com/flowlog-rs/flowlog/pull/218

## TL;DR

- **Correctness — the fusion changes speed only.** The optimized output is **byte-identical to
  the baseline on all 16/16 runs** (same `VarPointsTo`, same count, same `sha256`). Byte-exact
  vs Soufflé on **6/7 datasets**; `cassandra` shows a *pre-existing, deterministic* FlowLog-vs-
  Soufflé **port** difference (−103 / 4.2 M = **0.002 %**) that is present in the baseline and
  untouched by the fusion (see [Correctness detail](#correctness-detail)).
- **Performance — 7.4–24.3× faster** (geomean **12.9×**). FlowLog flips from **~5× slower** than
  Soufflé (the [w2] losses; FL/SF 0.11–0.23×) to **1.4–4.6× faster** (geomean **2.2×**) — it now
  **beats Soufflé on every one of these workloads**.
- **The win grows with program size:** `pmd` 984 → 40 s (**24×**), `eclipse` 2303 → 104 s (**22×**).

## The three analyses [w2] lost, now won

`luindex`, `-w 32` / `-j 32`:

| Analysis | Baseline FL | **Fused FL** | Soufflé | Speedup | vs Soufflé (before → after) |
|---|---|---|---|---|---|
| 1-object-1-type-sensitive+heap | 621 s | **37.5 s** | 109 s | **16.6×** | 0.18× → **2.9× faster** |
| 2-type-object-sensitive+heap | 631 s | **37.6 s** | 110 s | **16.8×** | 0.17× → **2.9× faster** |
| 2-type-object-sensitive+2-heap | 696 s | **76.5 s** | 136 s | **9.1×** | 0.19× → **1.8× faster** |

## Full results — 7 datasets × 3 analyses (`-w 32` / `-j 32`)

`speedup` = baseline / fused. `vs Soufflé` = Soufflé / fused (**> 1 ⇒ FlowLog faster**).
`byte-exact` = fused output identical to Soufflé after bracket-canonicalization + sort.

| Dataset | Analysis | Baseline | Fused | Soufflé | Speedup | vs Soufflé | byte-exact |
|---|---|---:|---:|---:|:---:|:---:|:---:|
| luindex | 1obj-1type+heap | 621 | 37.5 | 109 | **16.6×** | **2.91×** | ✓ |
| luindex | 2type-obj+heap | 631 | 37.6 | 110 | **16.8×** | **2.92×** | ✓ |
| luindex | 2type-obj+2heap | 696 | 76.5 | 136 | **9.1×** | **1.77×** | ✓ |
| tomcat | 1obj-1type+heap | 335 | 27.9 | 63 | **12.0×** | **2.28×** | ✓ |
| tomcat | 2type-obj+heap | 337 | 27.4 | 61 | **12.3×** | **2.22×** | ✓ |
| tomcat | 2type-obj+2heap | 402 | 54.5 | 84 | **7.4×** | **1.54×** | ✓ |
| eclipse | 1obj-1type+heap | 2303 | 103.6 | 479 | **22.2×** | **4.63×** | ✓ |
| cassandra | 1obj-1type+heap | 298 | 30.3 | 58 | **9.8×** | **1.92×** | ✗ −103 |
| cassandra | 2type-obj+heap | 301 | 30.4 | 59 | **9.9×** | **1.95×** | ✗ −103 |
| cassandra | 2type-obj+2heap | 370 | 63.0 | 85 | **5.9×** | **1.35×** | ✗ −103 |
| lusearch | 1obj-1type+heap | 561 | 33.7 | 95 | **16.6×** | **2.81×** | ✓ |
| lusearch | 2type-obj+heap | 574 | 34.1 | 94 | **16.8×** | **2.76×** | ✓ |
| avrora | 1obj-1type+heap | 465 | 29.6 | 60 | **15.8×** | **2.02×** | ✓ |
| avrora | 2type-obj+heap | 469 | 29.6 | 59 | **15.9×** | **1.99×** | ✓ |
| avrora | 2type-obj+2heap | 552 | 56.4 | 80 | **9.8×** | **1.41×** | ✓ |
| pmd | 1obj-1type+heap | 984 | 40.4 | 107 | **24.3×** | **2.66×** | ✓ |

Raw numbers (seconds, `VarPointsTo` counts, `sha256`): [`results.tsv`](results.tsv).

## Why it works

[w2]'s deep-dive pinned the 5–6× loss to a **single recursive join that fully serializes onto
one worker** — 599 s on worker 5, ~0 on the other 31. The DOOP context-response rule
`hctx = (hctxValue,), Value_DeclaringType(hctxValue, type)` desugars to a cross-atom equality
`hctx.0 == hctxValue` whose two sides share no bare variable, so FlowLog planned it as an
**empty-key cross-join + post-join filter**: every tuple hashes to `hash(()) →` one fixed
partition, and the join runs `O(|L|·|R|)` on a single thread.

**[w3] #218 fuses that spanning equality into the join key** — each side is arranged on its own
computed expression (`hctx.0` vs `hctxValue`), turning the cross-product into a real hash join
that spreads across all 32 workers. Fresh-variable equalities (`z = g(x)`) are left as bindings
by desugaring, so only both-sides-grounded equalities are fused; the equality is also kept as a
redundant residual, so the result is byte-identical to the baseline.

## Cross-check to [w2] / [w3]

- **Baseline (before) reproduces [w2].** Same environment, `-w 32`/`-j 32`, opt-level 3: e.g.
  `luindex 1-object-1-type-sensitive+heap` 621 s (mine) vs [w2] 665 s / [flowlog#217] 620.7 s,
  Soufflé ~109 s all round; `eclipse` `VarPointsTo` = **35,244,021** identical.
- **Fused (after) reproduces [w3] #218.** Rebuilding one workload at #218's exact **opt-level 1**
  (generated crate opt-1, deps opt-3) gives **42.6 s** vs #218's reported **44.6 s**. My headline
  numbers above are ~14 % faster only because they use the cargo-default **opt-level 3** (which
  #218 handicapped to opt-1 for LLVM-compile tractability). Soufflé, compiled identically, matches
  across all three studies.

## Correctness detail

All 16 fused runs are **byte-identical to the FlowLog baseline** (same `sha256`) — the fusion is
semantics-preserving. Against Soufflé, 13/16 match exactly; the 3 `cassandra` rows differ by a
constant **−103 tuples** (0.002 %). This is **not** the optimization and **not** `-w32`
nondeterminism: running the fused binary at **`-w 1`** yields the *same* 4,213,679 as `-w 32`
(FlowLog is deterministic here), while Soufflé yields 4,213,782 at both `-j1` and `-j32`. It is a
**deterministic discrepancy between the DOOP `flowlog-logic` and `souffle-logic` ports** that
`cassandra`'s facts happen to exercise — present in the baseline, orthogonal to this fusion, and
worth a separate look.

## Setup / reproduction

| | |
|---|---|
| **Host** | 64-core, 503 GB RAM |
| **FlowLog** | `main-next` **without** (baseline) vs **with** the #218 equi-join fusion; `--mode datalog-batch --str-intern`, `-w 32`; both carry the ord-determinism fix ([flowlog#208]) |
| **Soufflé** | 2.5, `souffle -c -j 32`, run `-j 32` |
| **Programs** | 3 object+type analyses assembled via `cpp` from `flowlog-logic/` (bare grammar, main-next-compatible) and `souffle-logic/`, exactly as [w2] |
| **Datasets** | DaCapo 23.11 facts: `luindex, tomcat, eclipse, cassandra, lusearch, avrora, pmd` |
| **Metric** | end-to-end wall clock (`/usr/bin/time -v`); `VarPointsTo` compared byte-exact after `(a,b)`→`[a,b]` bracket canonicalization + `LC_ALL=C sort` → `sha256` |

[flowlog#208]: https://github.com/flowlog-rs/flowlog/pull/208
[flowlog#217]: https://github.com/flowlog-rs/flowlog/pull/217

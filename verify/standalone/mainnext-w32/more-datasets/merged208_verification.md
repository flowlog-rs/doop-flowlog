# Post-merge verification: does the merged `ord` fix (#208) fix the nondeterminism?

**Context.** flowlog#208 (deterministic `ord` via single-thread fact interning) was **merged
into `main-next` at `7588f68`** (2026-07-10). This re-runs the DOOP standalone families with a
compiler **built from the merged code** (not the earlier cherry-pick), to answer two questions:

1. Does it fix FlowLog's **multithreaded (`-w32`) nondeterminism**?
2. Does it change the **cassandra FlowLog↔Soufflé divergence**?

**Method.** For each (dataset × family): FlowLog `-w32` **run1 vs run2** (byte-exact ⇒ MT
determinism); on cassandra+xalan also `-w1` (⇒ thread-count invariance); then FlowLog `-w32` vs
Soufflé `-j32` (cross-engine). 5 datasets × 4 families = **20 cells**. Binaries built from
`main-next@7588f68`; Soufflé `-j32` oracle. Raw data: `merged208_results.tsv`; runner:
`verify_merged.sh`.

## Result — determinism: 20/20 deterministic

| | context-insensitive | 1-object-sens. | 1-type-sens. | 1-call-site-sens. |
|---|:--:|:--:|:--:|:--:|
| **cassandra** | DET | DET | DET | DET |
| **xalan** | DET | DET | DET | DET |
| **avrora** | DET | DET | DET | DET |
| **zxing** | DET | DET | DET | DET |
| **sunflow** | DET | DET | DET | DET |

`-w32` run1 == run2 in **every** cell (and `-w1 == -w32` on cassandra + xalan). Pre-#208,
`-w32` was run-to-run nondeterministic on these families; the merged fix eliminates it. **Yes —
the merged `ord` fix fixes FlowLog's multithreaded nondeterminism.**

## Result — cross-engine: 16/16 byte-exact on fresh datasets; cassandra still 4/4 DIFF

| dataset | vs Soufflé `-j32` |
|---|---|
| xalan, avrora, zxing, sunflow (4 fresh) | **16/16 BYTE-EXACT** (`only_FL = only_SF = 0`) |
| cassandra | 4/4 **DIFF** — identical to the pre-merge diffs |

**Interpretation.** The four fresh datasets are byte-exact **and** deterministic, so the merged
fix is correct and stable. cassandra still differs by exactly the same margins as before — and,
crucially, it does so **deterministically** (`-w1 == -w32`, run1 == run2). That is the point: the
cassandra divergence was never nondeterminism. It is the `min ord(?heapRepr)` merged-heap
representative choice (see `cassandra_rootcause.md`), which is an **engine-internal interning
ordinal, not portable across engines**. The `ord` fix makes FlowLog's choice *deterministic within
FlowLog*; it does not (and cannot) make FlowLog's interning order equal Soufflé's, so the
representative — and hence the byte difference — persists on the one dataset where the tie-break
falls differently. **No engine-side fix is warranted.**

> Operational note: large `-w32` runs need `vm.max_map_count` raised above the 65530 default
> (`sudo sysctl -w vm.max_map_count=1048576`) or FlowLog's mimalloc aborts with "memory allocation
> failed" despite ample free RAM (cf. flowlog#177). jython/biojava were skipped here as
> pathologically heavy for *both* engines (reflection-driven blow-up), unrelated to determinism.

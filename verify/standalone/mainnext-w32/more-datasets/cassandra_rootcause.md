# cassandra FlowLog↔Soufflé divergence — root cause

**Question.** Is the cassandra byte-level difference (all 19 DOOP families, `-w32`/`-j32`) a
real FlowLog consistency/correctness bug?

**Answer. No.** It is a benign, fully deterministic, cross-engine divergence caused by the DOOP
program selecting a **merged-exception-heap representative** via `min ord(?heapRepr)`, where
`ord()` is an engine-internal string-interning ordinal that is **not portable across engines**.
FlowLog's analysis is sound and semantically equivalent to Soufflé's.

## The mechanism (type-based exception-heap merge)

DOOP merges every allocation of a heavily-allocated type (exceptions like
`java.lang.NullPointerException` clear the `MethodAllocationMergeThreshold(50)`) into a single
representative, chosen by **`min(ord(heap))`** over the merged sites:

```prolog
MinHeapOrdinalPerType(min(ord(heap)), type) :- TypeToMergedHeap(heap, type).
TypeToRepresentative(type, representativeHeap) :-
  isHeapAllocation(representativeHeap),
  MinHeapOrdinalPerType(minHeapOrd, type),
  ord(representativeHeap) = minHeapOrd.
HeapRepresentative(representativeHeap, heap) :-
  TypeToRepresentative(type, representativeHeap), TypeToMergedHeap(heap, type).
```

(An analogous `MinHeapOrdinalPerPackageAndType` rule does the same per package+type.) The
representative is the merged site with the **smallest `ord`**. `ord()` returns the engine's
interning ordinal — in FlowLog literally the `Spur` interner key
(`flowlog-build/src/codegen/arg.rs`: `ord(s) = s.into_inner().get()`), i.e. the string's
**load/interning order**; in Soufflé the symbol-table index. FlowLog interns during a serial
worker-0 fact load (post-#208) in its own EDB/file order; Soufflé in its own. The orders differ,
so `min(ord(heap))` selects a different — but equally valid — representative. On
luindex/eclipse/tomcat/lusearch the tie-break coincides (byte-exact); on cassandra it does not.

## Decisive experiment — same merge class, different `min ord` pick (not an upstream bug)

Both programs were instrumented (`.output HeapAllocation_Merge`, `.output
RepresentativesToPickFrom`) and re-run on cassandra:

| check | FlowLog | Soufflé |
|---|--:|--:|
| NPE allocation-sites merged (`HeapAllocation_Merge` LHS) | 664 | 664 — **byte-identical set** (only_FL=0, only_SF=0) |
| distinct representative chosen | 1 (`TlsPrfParameterSpec`) | 1 (`UnmodifiableCollection`) |

Both engines fold the **exact same 664 sites** into one object — so the *analysis* (what gets
merged) is identical; only the `min(ord)` label differs. Because the set is identical but the
argmin differs, the two engines necessarily assign **inverted `ord`** to these strings:
`ord_FL(TlsPrf) < ord_FL(Unmodifiable)` but `ord_SF(TlsPrf) > ord_SF(Unmodifiable)`. That single
inversion is the entire cause.

## The single diverging heap

All `new java.lang.NullPointerException` allocation sites merge into **one** object. Each engine
emits **exactly one** NPE representative — they just differ:

| engine | chosen representative |
|---|---|
| FlowLog | `<sun.security.internal.spec.TlsPrfParameterSpec: void <init>(...)>/new java.lang.NullPointerException/0` |
| Soufflé | `<java.util.Collections$UnmodifiableCollection: void <init>(java.util.Collection)>/new java.lang.NullPointerException/0` |

## Evidence

### context-insensitive (no type-context → no cascade; isolates the cause)

| check | FlowLog | Soufflé |
|---|--:|--:|
| VarPointsTo rows | 2 545 822 | 2 545 822 (**equal**) |
| full-tuple diff | only_FL = 2 341 | only_SF = 2 341 (**symmetric**) |
| differing rows carrying the NPE heap | 2 341 / 2 341 | 2 341 / 2 341 (**100 %**) |
| variable set | 90 676 | 90 676 (**0 / 0 identical**) |
| distinct NPE representative | 1 (`TlsPrfParameterSpec`) | 1 (`UnmodifiableCollection`) |

Pure symmetric relabel of one heap. Nothing else differs.

### 1-type-sensitive (representative's *type* is the context → cascade)

| check | FlowLog | Soufflé |
|---|--:|--:|
| determinism | `-w1` == `-w32` = 4 627 255 | `-j1` == `-j32` = 4 629 551 |
| full-tuple diff | only_FL = 6 324 | only_SF = 8 620 (asymmetric, +2 296) |
| **variable set** | 89 471 | 89 471 (**0 / 0 identical**) |
| heap (value) set | 5 343 | 5 343 (differ by **exactly 1** = the NPE representative) |
| `(value,var)` points-to | 1 523 236 | 1 523 236 |

Because 1-type-sensitivity uses the **type of the representative** as the calling context, the
arbitrary NPE pick fixes a different type-context (`TlsPrfParameterSpec` vs
`UnmodifiableCollection`), which flows downstream into a different context-sensitive fixpoint —
hence the asymmetric +2 296. Remapping the single representative collapses most of the diff
(6 324/8 620 → 1 237/3 533); the residual is the downstream cascade of that one choice, not an
independent difference.

## Why this is not a bug

- **Sound & equivalent:** identical variable set; identical points-to modulo one `ord`-chosen
  representative label.
- **Deterministic on both sides:** FlowLog `-w1 == -w32` (after flowlog#208); Soufflé `-j1 == -j32`.
- **Faithful comparison:** the assembled FlowLog/Soufflé programs are byte-exact on four other
  DaCapo datasets, and the assembled Soufflé binary matches the *official* standalone program
  (`-j32` == `-j1` == 4 629 551) — ruling out an assembly artifact.
- **Relationship to flowlog#208:** that PR made `ord()` deterministic *within* FlowLog (across
  threads). Cross-**engine** `ord()` agreement is not guaranteed by Datalog semantics; it is an
  interning artifact. cassandra is the dataset where the two engines' interning orders disagree on
  the `min ord` tie-break for the merged NPE heap.

**Bottom line.** Byte-exact FlowLog↔Soufflé agreement on DOOP holds wherever the `min ord`
representative tie-break coincides. cassandra is the case where it doesn't. The result is benign
cross-engine underspecification inherent to `ord()`-based canonicalization — no engine-side fix is
warranted.

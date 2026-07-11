# Independent verification of FlowLog PR #218 (`[w3]` equality→join-key fusion)

Does [flowlog#218] ("Fuse spanning equalities into join keys") deliver **real** gains
on the DOOP standalone programs/datasets? **Yes** — reproduced independently below.

PR #218 targets exactly the weakness the `-w32` study (`../mainnext-w32/`) exposed: the three
**object+type-combined** analyses where FlowLog was 4–6× *slower* than Soufflé. The PR claims the
fusion makes them 11–16× faster and beats Soufflé. This is an independent A/B reproduction.

## Method (clean controlled A/B)

The fusion branch `w3/equijoin-fusion` (`3a14b67`) sits **one commit** on top of its base
`nemo/tuple` (`32cbc00`) — the fusion is the *only* difference. Both compilers were built from
those refs with **identical** environment patches (so the fusion stays the sole variable):

- **tuple-typed EDB handler** — stock `nemo/tuple` `unreachable!()`s on the DOOP `= True` grammar's
  tuple-typed IDB relations (e.g. `mainAnalysis.OptInterproceduralAssign`, which has no `.facts`);
  patched to emit empty input handlers. Identical file in base + w3 (`relation.rs`).
- **generated-crate `opt-level = 1`** (deps stay at 3) — the ~29k-line generated function is
  otherwise intractable to compile. Identical in base + w3 (`scaffold.rs`).

- **Programs:** the 19 `= True` standalone flowlog programs from `../flowlog/` (this repo) + the
  Soufflé programs from `../souffle/`. Focus: the 3 object+type-combined families.
- **Run:** FlowLog `--mode datalog-batch --str-intern -w 32`; Soufflé `-c -j 32`, run `-j 32`; luindex.
- **Perf:** wall + peak RSS, `/usr/bin/time -v` (base 1 run; w3/Soufflé min of 2), under a steady
  concurrent 32-worker background load (64-core host) — a uniform handicap; ratios are robust.
- **Correctness:** `nemo/tuple` lacks the ord-determinism fix ([flowlog#208]), so its **parallel**
  output is nondeterministic. Correctness is therefore checked at **`-w1` (deterministic)** vs the
  thread-independent Soufflé oracle, byte-exact.

## Performance — `-w32`/`-j32`, luindex (the 3 target families)

| Family | Base FL (s) | **W3 FL (s)** | Soufflé (s) | **W3 vs base** | W3 vs Soufflé | PR claim (base / SF) |
|---|--:|--:|--:|--:|--:|--:|
| 1-object-1-type-sensitive+heap | 940 | **60.9** | 136.5 | **15.4×** | **2.24×** | 15.9× / 2.5× |
| 2-type-object-sensitive+heap | 918 | **50.5** | 118.9 | **18.2×** | **2.36×** | 16.3× / 2.4× |
| 2-type-object-sensitive+2-heap | 1174 | **94.5** | 191.9 | **12.4×** | **2.03×** | 11.0× / 1.6× |

**Reproduced.** The fusion gives **12–18×** over baseline and makes FlowLog **beat Soufflé ~2×** on all
three families — matching the PR's 11–16× / ~1.6–2.5×. (Base times run ~1.3× higher than the PR's
because of the concurrent background load; the *ratios* — which cancel it — line up.)

## Correctness — `-w1` deterministic, byte-exact vs Soufflé

| Family | W3 rows | Soufflé rows | only_W3 | only_SF | verdict |
|---|--:|--:|--:|--:|:--:|
| 1-object-1-type-sensitive+heap | 8719851 | 8719851 | 0 | 0 | **BYTE_EXACT** |
| 2-type-object-sensitive+heap | 8719851 | 8719851 | 0 | 0 | **BYTE_EXACT** |
| 2-type-object-sensitive+2-heap | 9788238 | 9788238 | 0 | 0 | **BYTE_EXACT** |

**Byte-exact on all three** (0 tuples unique to either engine) — the fused plan computes the correct
answer. (Row counts equal the ord-fixed reference exactly: 8 719 851 / 8 719 851 / 9 788 238.)
At `-w32` the raw output differs by a tiny ord-nondeterministic margin (nemo/tuple lacks #208); that
is unrelated to the fusion (base vs w3 differ by the same margin), which is why correctness is
established at `-w1`.

## Verdict

The `[w3]` fusion's gains are **real and reproduced independently** on the DOOP standalone suite:

- **12–18× faster than the pre-fusion baseline** on the three object+type analyses (`-w32`, luindex).
- **Beats Soufflé ~2.0–2.4×** on all three — turning FlowLog's only DOOP losses into wins.
- **Byte-exact correct** vs the Soufflé oracle (`-w1`).

Combined with `../mainnext-w32/` (FlowLog already wins the other 16 families), this fusion closes the
gap: **FlowLog is faster than Soufflé across the whole DOOP standalone suite, byte-exact.**

[flowlog#218]: https://github.com/flowlog-rs/flowlog/pull/218
[flowlog#208]: https://github.com/flowlog-rs/flowlog/pull/208

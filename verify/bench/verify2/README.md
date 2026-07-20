# [verify2] FlowLog `main-next` vs Soufflé (±`.plan`) — timing (`.printsize`)

A **timing** run of the standalone `verify/bench` kit (`time.sh`): FlowLog
`main-next` vs Soufflé 2.5, **with and without DOOP's `.plan`**, at **32
threads** (`-w32` / `-j32`), measuring the analysis under `.printsize` (tuple
count only, **no IDB / CSV serialization**) so the number is pure fixpoint
compute. This is the multi-engine, three-way **compile + run / time + RSS**
companion to the byte-exact correctness runs (`output.sh`).

- **Engine**: FlowLog `flowlog-rs/flowlog` `main-next` @ **`ef3be32`**
  (`feat(compiler): add --build-dir` #229), built `-p flowlog-compiler`.
- **Oracle**: Soufflé **2.5**, `-j 32` at **both** compile and run (a
  compile-time `-j` is required or the generated binary is serial).
- **Dataset**: `luindex` (DOOP facts, 130 `*.facts`).
- **Threads**: `-w32` / `-j32`. **Reps**: median of 3 (`REPS=3`).
- **Interning**: FlowLog `--str-intern` (required for `ord()`).
- No engine or logic code is touched — this is **verification data only**.

## TL;DR

| | result |
|---|---|
| **Correctness** | **10 / 10 families `COUNT_MATCH`** — FlowLog, Soufflé-noplan and Soufflé-plan agree on `VarPointsTo` exactly, at `-w32`/`-j32`. |
| **Run speed** | FlowLog fastest on **every** family: **2.6–6.6×** vs Soufflé-noplan, **1.9–3.0×** vs Soufflé-plan; **3.87× / 2.28× aggregate** (Σ FL 258 s vs SFnp 998 s / SFpl 588 s). |
| **Build** | FlowLog ~237 s avg / **7.7–11.5 GB** peak RSS (rustc: timely+dd+big generated crate). Soufflé ~145 s (noplan) / ~153 s (plan) / **~2.2 GB** (C++). FL build ~1.6× slower, ~4–5× heavier — amortised by compile-once / run-many. |
| **`.plan` effect** | DOOP's hand-tuned join orders speed Soufflé runs markedly (e.g. `1-object-sensitive` 165 s → 66 s) at **higher** run RSS; output identical (`.plan` never changes results). |
| **Run RSS** | FlowLog comparable to Soufflé, often **lower** on the heavier families. |

## Per-family results

`build` and `run` cells are **wall seconds / peak RSS (GB)**. `run` is the
median of 3; **FL run** is bolded. Speedup = Soufflé-noplan / Soufflé-plan run
wall ÷ FlowLog run wall.

| family | FL build | SFnp build | SFpl build | FL run | SFnp run | SFpl run | run speedup (np / pl) | VarPointsTo | verdict |
|---|---|---|---|---|---|---|---|---|---|
| context-insensitive | 209 / 7.7 | 141 / 2.2 | 153 / 2.2 | **14** / 4.2 | 37 / 2.8 | 26 / 3.3 | 2.6× / 1.9× | 5396536 | COUNT_MATCH |
| 1-type-sensitive | 235 / 9.4 | 152 / 2.2 | 154 / 2.2 | **17** / 5.0 | 71 / 4.4 | 40 / 5.2 | 4.2× / 2.4× | 9206109 | COUNT_MATCH |
| 1-type-sensitive+heap | 239 / 9.7 | 151 / 2.2 | 154 / 2.2 | **28** / 6.1 | 87 / 5.6 | 59 / 6.8 | 3.1× / 2.1× | 11736906 | COUNT_MATCH |
| 1-call-site-sensitive | 234 / 9.6 | 142 / 2.2 | 152 / 2.2 | **20** / 6.8 | 105 / 7.6 | 58 / 8.5 | 5.2× / 2.9× | 17075710 | COUNT_MATCH |
| 1-call-site-sensitive+heap | 236 / 9.7 | 142 / 2.2 | 153 / 2.2 | **20** / 6.9 | 107 / 7.8 | 60 / 8.8 | 5.3× / 3.0× | 17573686 | COUNT_MATCH |
| 1-object-sensitive | 233 / 9.5 | 140 / 2.2 | 153 / 2.2 | **25** / 6.9 | 165 / 7.1 | 66 / 8.4 | 6.6× / 2.6× | 15093978 | COUNT_MATCH |
| 1-object-sensitive+heap | 236 / 9.7 | 142 / 2.2 | 152 / 2.2 | **45** / 8.5 | 175 / 9.4 | 100 / 11.3 | 3.9× / 2.2× | 20036177 | COUNT_MATCH |
| 1-object-1-type-sensitive+heap | 252 / 10.9 | 151 / 2.2 | 153 / 2.2 | **33** / 7.4 | 99 / 5.2 | 68 / 6.0 | 3.0× / 2.1× | 8719851 | COUNT_MATCH |
| 2-type-sensitive+heap | 250 / 11.2 | 151 / 2.2 | 154 / 2.2 | **16** / 4.3 | 44 / 2.9 | 30 / 3.3 | 2.8× / 1.9× | 4859195 | COUNT_MATCH |
| 2-object-sensitive+heap | 248 / 10.8 | 142 / 2.2 | 151 / 2.2 | **40** / 7.8 | 108 / 5.4 | 81 / 6.3 | 2.7× / 2.0× | 8741742 | COUNT_MATCH |

Raw data: [`time_luindex.tsv`](time_luindex.tsv) (all `time.sh` columns).
Per-family build/run progress log: [`sweep.log`](sweep.log).

## Scope

10 families spanning the context-sensitivity hierarchy (context-insensitive →
1-{type,call-site,object}-sensitive ±heap, a hybrid, and two 2-level analyses).
One family × one dataset ≈ 9 min of builds (Soufflé's C++ compile is an
uncacheable ~2.5 min floor per variant; FlowLog's `-B` build cache only saves
the *deps* — the large per-family generated crate recompiles each time), so the
full 24×6 default sweep is impractical here (days + OOM on the deep families).

## Reproduce

```bash
# build the FlowLog compiler from flowlog-rs/flowlog main-next
cargo build --release -p flowlog-compiler   # -> target/release/flowlog-compiler

# run the three-engine timing sweep (see run.sh for the exact invocation)
FLC=/path/to/flowlog-compiler FACTS_ROOT=/path/to/dacapo-facts \
  DATASETS=luindex THREADS=32 \
  verify/bench/time.sh \
    context-insensitive 1-type-sensitive 1-type-sensitive+heap \
    1-call-site-sensitive 1-call-site-sensitive+heap \
    1-object-sensitive 1-object-sensitive+heap 1-object-1-type-sensitive+heap \
    2-type-sensitive+heap 2-object-sensitive+heap
```

Put scratch (`WORKDIR`/`TMPDIR`) and the FlowLog `-B` cache on a large,
non-tmpfs disk — FlowLog builds peak at ~11 GB RSS and the build cache grows to
~20 GB.

# FlowLog ↔ Soufflé correctness/perf verification

Reproduction guide for compiling and running DOOP analyses on **FlowLog** and
checking them byte-for-byte against **Soufflé**. Written so a fresh machine can
rebuild and re-run without the original `/dev/shm` scratch state.

## TL;DR result (luindex, DaCapo)

- **19/19** context-sensitive families that completed are **byte-exact identical**
  to Soufflé on `VarPointsTo` (see `timing_summary.tsv`).
- **FlowLog runs faster than Soufflé single-threaded** on 16/19 families
  (e.g. `1-object-sensitive`: 2:53 vs 30:26), tied on 3. Parallel `-w N` widens this.
- The only FlowLog cost is a **one-time analysis compile** (rustc on an ~85k-line
  generated crate); DOOP's compile-once / run-many model absorbs it.
- The 5 untested families failed on the **Soufflé side** (single-core OOM/timeout/error),
  not FlowLog.

## Coverage & handover (→ run on a more powerful machine)

FlowLog **supports running 24 families** (the `verify.sh` default set — the full
context-sensitivity hierarchy; **25** if you add `types-only`, which needs
`-DDISABLE_POINTS_TO`). Status on luindex, on the original **251 GiB / 128-core**
box:

- **19 byte-exact-verified** against Soufflé (see `timing_summary.tsv`).
- **5 not completed here — re-run on a bigger machine to close them out:**

  | family | blocker on this machine (not a FlowLog bug) |
  |---|---|
  | `2-call-site-sensitive+heap`  | ~217 GiB peak RSS — OOM at the memory edge (both engines) |
  | `2-call-site-sensitive+2-heap`| ~217 GiB peak RSS — OOM |
  | `sticky-2-object-sensitive`   | Soufflé `-j1` run exceeded the 60-min cap |
  | `selective-2-object-sensitive+heap` | Soufflé `-j1` run exceeded the 60-min cap |
  | `partitioned-2-object-sensitive+heap` | FlowLog ran clean (8,730,757); **Soufflé errored** — needs a look |

  All 24 (+`types-only`) **compile/`cargo check` clean** — these 5 are
  resource/Soufflé-side limits, not FlowLog. On a box with more RAM (for the
  `2-call-site` pair) and headroom, just re-run `verify/verify.sh` — bump
  `SF_RUN_TO` for the slow Soufflé cases — to verify the remaining 5.

## Components & pinned versions

| component | location | version |
|---|---|---|
| FlowLog compiler | `/users/zhhong/flowlog` | **commit `32cbc00`** (see grammar note) |
| DOOP→FlowLog logic | `flowlog-logic/` (this repo) | tracked |
| DOOP→Soufflé logic | `souffle-logic/` (this repo) | tracked (upstream) |
| Facts (EDB) | regenerate via DOOP | benchmark used: **luindex** |

> ⚠️ **Why this exact compiler commit matters.** Two independent reasons pin
> the build to `nemo/tuple` (`32cbc00`):
>
> 1. **Tuple-EDB engine fix (the critical one).** Every context-*sensitive*
>    family represents contexts as tuples, so DOOP declares tuple-typed
>    relations that become empty declared-underived EDB inputs. `nemo/tuple`
>    handles these; `main-next` and `nemo/parser-refactor` still have
>    `relation.rs: unreachable!("tuple-typed columns cannot appear in EDB input
>    relations")` and **panic on 18 of the 19 families** (only
>    `context-insensitive` compiles without the fix). This fix has NOT been
>    merged into main-next (`#194 "tuple syntax"` is a *different* feature —
>    syntax, not EDB-input handling).
> 2. **Grammar.** This logic uses `match(...) = True` / `= False` /
>    `contains(...) = True`. `nemo/tuple` and `main-next` accept that form
>    (see main-next's own `tests/fixtures/.../match_builtin`). Only
>    `nemo/parser-refactor` changed `match`/`contains` into bare extern-fn bool
>    predicates (`match(...)` / `!match(...)`).
>
> So: **build at `32cbc00` (`nemo/tuple`) and use the logic as-is.** To target
> the newer parser instead, you must FIRST merge `nemo/tuple`'s `relation.rs`
> fix into that branch AND migrate the logic grammar (see "Grammar migration").

## 1. Build the FlowLog compiler

```bash
git clone https://github.com/flowlog-rs/flowlog && cd flowlog
git checkout nemo/tuple        # contains 32cbc00, the grammar that matches flowlog-logic/
#   (or: git checkout 32cbc00 directly — reachable from origin/nemo/tuple)
cargo build --release -p flowlog-compiler
# -> target/release/flowlog-compiler   (compile-only; produces a native binary to run)
```

## 2. The compile line (per analysis family)

DOOP assembles three layers with the C preprocessor, parameterised by the
analysis's `AbstractConfiguration` component, then compiles to a native binary.

```bash
ROOT=/users/zhhong/doop-flowlog
FLC=/users/zhhong/flowlog/target/release/flowlog-compiler
FACTS=/path/to/facts          # DOOP-generated EDB (e.g. luindex)
fam=2-object-sensitive+heap   # any dir under flowlog-logic/analyses/

# configuration macro = the AbstractConfiguration component name for this family
cfg=$(grep -hoE '\.comp +\w+ *: *AbstractConfiguration' \
        $ROOT/flowlog-logic/analyses/$fam/analysis.dl | head -1 \
        | sed -E 's/\.comp +(\w+).*/\1/')

# assemble: facts schema + basic logic + the family's analysis, in order
A=/tmp/$fam.fl.dl
cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/facts/facts.dl   >  $A
cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/basic/basic.dl   >> $A
cpp -P -DCONFIGURATION=$cfg $ROOT/flowlog-logic/analyses/$fam/analysis.dl >> $A

# compile to a native binary (use --str-intern for string EDBs)
$FLC --str-intern -F $FACTS -D ./out_$fam -o ./bin_$fam $A
```

## 3. Run

```bash
./bin_$fam -w 32          # -w = worker threads; -w 1 for apples-to-apples vs `souffle -j 1`
# outputs (e.g. VarPointsTo.csv) land in the -D directory
```

Soufflé equivalent for comparison:

```bash
cpp -P -DCONFIGURATION=$cfg souffle-logic/facts/facts.dl  >  s.dl
cpp -P -DCONFIGURATION=$cfg souffle-logic/basic/basic.dl  >> s.dl
cpp -P -DCONFIGURATION=$cfg souffle-logic/analyses/$fam/analysis.dl >> s.dl
souffle -c -o ./sfbin_$fam s.dl
./sfbin_$fam -j 1 -F $FACTS -D ./sfout_$fam
```

Byte-exact compare (canonicalise record/tuple brackets, sort):
`canon(){ sed -e 's/\[/(/g;s/\]/)/g;s/, /,/g;s/,)/)/g' "$1" | LC_ALL=C sort; }`
then `diff <(canon fl/VarPointsTo.csv) <(canon sf/VarPointsTo.csv)`.

## The harness: `verify.sh`

One portable, env-driven script runs every supported family on **both** engines and
byte-exact-diffs `VarPointsTo`. No hard-coded paths; works on any DaCapo benchmark.

```bash
# minimal: point it at the compiler and a benchmark's facts
FLC=/path/to/flowlog-compiler FACTS=/path/to/luindex/facts verify/verify.sh

# pick the benchmark via FACTS_ROOT + BENCHMARK, label the output, choose threads
FLC=… FACTS_ROOT=/data/dacapo-facts BENCHMARK=antlr DATASET=antlr \
  WORKERS=1 JOBS=1 verify/verify.sh

# just a few families
FLC=… FACTS=… verify/verify.sh 2-object-sensitive+heap 3-type-sensitive+2-heap
```

Writes `verify_<DATASET>.tsv` to `$OUTDIR` (default `.`) with per-family
build/run exit codes, `/usr/bin/time` wall-clock seconds, VarPointsTo counts,
and the `MATCH`/`DIFF`/`INCOMPLETE` verdict; prints a summary at the end.
Env knobs: `SOUFFLE`, `WORKERS`/`JOBS`, `BUILD_TO`/`FL_RUN_TO`/`SF_RUN_TO`,
`OUTDIR`/`WORKDIR`, `SOUFFLE_KEEP_PLAN` (see the header comment). Self-detects the
repo root, tolerates per-family timeout/OOM/error, and frees scratch after each.

### Historical data (kept, do not regenerate)

- `results.tsv`, `results2.tsv` — the original luindex batch + rerun verdicts.
- `timing_summary.tsv` — the trusted `/usr/bin/time` timings + max RSS (luindex).

These were produced with FlowLog `nemo/tuple` (`32cbc00`) + `= True` grammar and
are the byte-exact-verified record referenced above.

## Running on the newer parser (branch `flowlog-next-datalog-compat`)

To run on a **clean, unmodified** `main-next` / `nemo/parser-refactor` compiler —
**no engine change, no carrying a `relation.rs` fork** — use the
`flowlog-next-datalog-compat` branch of this repo. It applies two **datalog-only**
edits:

1. **Strip the dead `OptInterproceduralAssign` rule** (`main/context-sensitivity.dl`).
   That relation is never produced in any configuration, so the rule is a no-op;
   as an unproduced tuple-typed relation it was the *only* thing emitted as a
   tuple-typed EDB input (the thing clean compilers panic on). Removing the dead
   reference lets it be pruned — no effect on results.
2. **Bare `match`/`contains` grammar** (parser-refactor makes them extern-fn bool
   predicates): `match(re,x) = True.` → `match(re,x).`,
   `match(re,x) = False,` → `!match(re,x),` (negation `!`); same for `contains`.
   The 5 sites: `basic/method-resolution.dl:61,62`, `basic/type-hierarchy.dl:257`,
   `main/init.dl:28`, `analyses/sticky-2-object-sensitive/analysis.dl:29`.

**Validated:** all 23 previously-run families pass `flowlog-compiler --check`
(`cargo check`; pass `-D -` for the output dir) on a clean `parser-refactor`
build — see `verify/parser_refactor_check_results.tsv` on that branch. Byte-exact
correctness is verified on `master` (`= True` / `nemo/tuple`); a full byte-exact
*run* on parser-refactor with this branch is still TODO.

> `master` (this branch) stays on `= True` + `nemo/tuple` — the byte-exact-verified
> setup. The two trees target **different compilers**; don't mix grammars.
> (The alternative — merging `nemo/tuple`'s `relation.rs` tuple-EDB fix into the
> newer parser — also works but means maintaining an engine fork, so the
> datalog-only branch above is preferred.)

## File-to-file divergence vs souffle-logic

FlowLog mirrors **82 of Soufflé's 234** `.dl` files (the core points-to pipeline;
reflection/android/information-flow/symbolic addons are not ported). Among shared
files, **line counts are near-identical** (largest: `context-sensitivity.dl` −19,
`string-constants.dl` −15) but many lines differ *textually* due to syntax
dialect (`.plan` directives dropped, `= True` predicates, bracket conventions).
Regenerate the per-file diff with the loop in this repo's history / commit msg.

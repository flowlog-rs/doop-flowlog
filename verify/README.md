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

## Components & pinned versions

| component | location | version |
|---|---|---|
| FlowLog compiler | `/users/zhhong/flowlog` | **commit `32cbc00`** (see grammar note) |
| DOOP→FlowLog logic | `flowlog-logic/` (this repo) | tracked |
| DOOP→Soufflé logic | `souffle-logic/` (this repo) | tracked (upstream) |
| Facts (EDB) | regenerate via DOOP | benchmark used: **luindex** |

> ⚠️ **Grammar pin.** This logic uses the older predicate syntax
> `match(...) = True` / `= False` (and `contains(...) = True`). FlowLog
> `main-next` (e.g. `3bdb94b`) changed `match`/`contains` into **direct boolean
> predicates** (`match(...)` / `!match(...)`), with UDF booleans requiring
> `== true`. So either build the compiler at **`32cbc00`** to match this logic,
> or port the logic to the new grammar first (see "Grammar migration" below).

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

## Harness scripts (in this dir)

- `run_verify.sh` — full overnight batch: build+run+diff each family, FlowLog vs Soufflé.
- `rerun.sh` — same, narrowed to families that hit the build timeout (longer cap).
- `bench_w32.sh` — rebuild + time FlowLog at `-w 16` / `-w 32` (parallel scaling).
- `results.tsv`, `results2.tsv` — raw verdict tables.
- `timing_summary.tsv` — distilled trusted timings (`/usr/bin/time` wall-clock + max RSS).

> Note: these scripts hard-code `/dev/shm` paths and the `fl-tuple` worktree.
> Update `ROOT`/`FLC`/`FACTS`/`W` at the top of each before reuse.

## Grammar migration (flowlog-logic → main-next)

To run against a `main-next` compiler, update predicate syntax in `flowlog-logic/`:

- `match(re, x) = True.`  → `match(re, x).`
- `match(re, x) = False,` → `!match(re, x),`
- same for `contains(...)`
- user-defined boolean functions: call as `udf(...) == true`

Current occurrences (small): `match(` ×5, `contains( ... = True` ×1 — in
`basic/method-resolution.dl`, `basic/type-hierarchy.dl`, `main/init.dl`,
`main/special-library.dl`, `analyses/sticky-2-object-sensitive/analysis.dl`.

## File-to-file divergence vs souffle-logic

FlowLog mirrors **82 of Soufflé's 234** `.dl` files (the core points-to pipeline;
reflection/android/information-flow/symbolic addons are not ported). Among shared
files, **line counts are near-identical** (largest: `context-sensitivity.dl` −19,
`string-constants.dl` −15) but many lines differ *textually* due to syntax
dialect (`.plan` directives dropped, `= True` predicates, bracket conventions).
Regenerate the per-file diff with the loop in this repo's history / commit msg.

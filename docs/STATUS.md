# doop-flowlog status — hand-off

Where the project stands at the end of this session, so the next machine can pick up without conversation context.

## Snapshot

**Done in this repo:**

- `bin/flowlog-mirror.py` — mirrors `souffle-logic/` → `flowlog-logic/` for one analysis, preserving folder structure, only the files actually needed (uses `cpp -M` to honor `#ifdef`). Applies per-file transforms: strip `.plan` directives, strip the `?varname` LogiQL-era variable prefix, strip the `overridable` annotation. Run with `python3 bin/flowlog-mirror.py context-insensitive --clean`.
- `flowlog-logic/` — generated mirror for context-insensitive (44 .dl files under `basic/`, `main/`, `facts/`, `analyses/context-insensitive/`, plus `commonMacros.dl`). This is a build artifact; regenerate from `souffle-logic/` rather than hand-editing.
- Three FlowLog engine hand-off specs in `docs/`:
  - [`flowlog-components-spec.md`](flowlog-components-spec.md) — `.comp` / `.init` / parametric / inheritance. **Implemented on `main-next`.**
  - [`flowlog-v1-grammar-gaps.md`](flowlog-v1-grammar-gaps.md) — multi-head rules with `,` separator, parenthesized disjunction nested in conjunction. **Implemented on `main-next`.**
  - [`flowlog-override-spec.md`](flowlog-override-spec.md) — `.override Foo` directive inside `.comp` bodies (verified against Soufflé 2.4). **Implemented on `main-next`.**

**FlowLog engine state (`flowlog-rs/flowlog` `main-next`):**

| Feature | Status |
| --- | --- |
| `.comp` / `.init` / parametric / inheritance | ✅ |
| Subtypes (`<:`) | ✅ (gravy — DOOP doesn't actually use them) |
| Records `[a:T1, b:T2]` | ✅ |
| String builtins (cat/ord/substr/strlen/match/contains/to_string/to_number) | ✅ |
| Aggregates (count/min/max/sum) | ✅ |
| Negation `!atom`, anonymous `_`, top-level disjunction `;` | ✅ |
| Parametric `.input` / `.output` (`filename=`, `IO=`, `delimiter=`) | ✅ |
| Multi-head rules with `,` separator | ✅ (just landed) |
| Parenthesized disjunction nested in conjunction `(A ; B)` | ✅ (just landed) |
| `.override` directive | ✅ (just landed) |
| `overridable` annotation | ✅ (accepted natively) |

**doop-flowlog transform passes (`bin/flowlog-mirror.py`):**

| Transform | Reason it exists |
| --- | --- |
| `strip_plan` | `.plan N:(...)` is Soufflé scheduler hint; FlowLog plans its own. Handles the multi-line form (`1:(...), 2:(...)` wrapped over several lines) too |
| `strip_qmark_vars` | `?varname` is DOOP's LogiQL-era variable prefix; FlowLog rejects `?` in idents because it codegens to Rust (`proc_macro2::Ident`). Stripping is semantically a no-op — every variable consistently has `?`, so no collisions |
| `strip_overridable` | `overridable` annotation; engine now accepts it natively, so this strip can be removed once we re-test |
| `rewrite_bool_builtins` | `match(p,s)` and `contains(n,h)` are bare boolean constraints in Soufflé. FlowLog types both as `bool`-returning value functors, so each must be equated: `f(...)` → `f(...) = True`, `!f(...)` → `f(...) = False`. Comment- and string-literal-aware, so a builtin name inside a `//`/`/* */` comment or a `"..."` fact (e.g. `"boolean contains(java.lang.Object)"`) is never touched. Aggregates are deliberately *not* transformed — FlowLog accepts Soufflé-style `v = min e : {...}` natively |

## Next concrete actions

In priority order:

### 1. Re-run the v1 smoke test against updated `main-next`

The previous smoke found two grammar gaps in batch one. Both should now be fixed. There are probably more error classes we haven't seen yet — the iteration pattern is "find next error, write spec, hand off, repeat".

```bash
# rebuild the engine
cd /tmp && git clone https://github.com/flowlog-rs/flowlog.git
cd flowlog && git checkout main-next && cargo build --release
export FLOWLOG_BIN=$PWD/target/release/flowlog-compiler

# refresh the mirror
cd /path/to/doop-flowlog
python3 bin/flowlog-mirror.py context-insensitive --clean

# assemble + run
mkdir -p /tmp/v1-smoke
cpp -P flowlog-logic/facts/facts.dl > /tmp/v1-smoke/01-facts.dl
cpp -P flowlog-logic/basic/basic.dl > /tmp/v1-smoke/02-basic.dl
cpp -P flowlog-logic/analyses/context-insensitive/analysis.dl > /tmp/v1-smoke/03-analysis.dl
cat /tmp/v1-smoke/{01-facts,02-basic,03-analysis}.dl > /tmp/v1-smoke/assembled.dl
$FLOWLOG_BIN /tmp/v1-smoke/assembled.dl
```

If new error classes appear, write a `flowlog-v2-grammar-gaps.md` (or similar) batch and hand off. The smoke produced one fix per iteration in the previous round; expect a few more rounds.

The cpp-assemble step matches what DOOP's `CPreprocessor.groovy` does today (per-file preprocess + concatenate to a throwaway flat file). The flat file goes to `/tmp`; `flowlog-logic/` stays untouched.

### 2. Drop the now-redundant `strip_overridable` transform

`bin/flowlog-mirror.py` currently strips `overridable`. Engine handles it natively now. Remove the `strip_overridable` function and its `TRANSFORMS` entry, re-mirror, confirm smoke still passes.

### 3. Wire `FlowLogAnalysis.groovy` backend in DOOP

Parallel to `src/main/groovy/org/clyze/doop/core/SouffleAnalysis.groovy`. Reuse `CPreprocessor` for assembly (same calls, just pointed at `flowlog-logic/` instead of `souffle-logic/`). Replace the Soufflé invocation with a new `FlowLogScript.groovy` parallel to `SouffleScript.groovy` that calls the `flowlog` binary.

Dispatch from `DoopAnalysisFactory.groovy`: a new analysis-engine option (e.g., `--engine flowlog`) picks `FlowLogAnalysis` over `SouffleAnalysis`. Outputs go to the same `outDir/database/` layout so downstream tooling is unchanged.

Sketch:

```
src/main/groovy/org/clyze/doop/core/FlowLogAnalysis.groovy   # ~150 LOC, mirror of SouffleAnalysis
src/main/groovy/org/clyze/doop/utils/FlowLogScript.groovy    # ~80 LOC, mirror of SouffleScript
```

`mainAnalysis()` should call into `flowlog-logic/` instead of `souffle-logic/` — that path needs to be added to `Doop.groovy` alongside the existing `souffleLogicPath`.

### 4. Pin `FLOWLOG_REF`

Once the engine has the four features above and the smoke parses clean, create `FLOWLOG_REF` at the repo root containing the engine commit hash. This is what the README quickstart instructs users to check out.

### 5. End-to-end run on one DaCapo app

The 20-app DaCapo fact corpus lives at `https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/`. Pick `batik` (smallest, fastest to iterate). Run `FlowLogAnalysis` over it, get a `VarPointsTo.csv`.

### 6. Cross-check vs Soufflé baseline

Run the same `context-insensitive` analysis through DOOP's existing `SouffleAnalysis` backend on the same `batik` corpus. Compare row counts per output relation; a script that does `wc -l` on each pair plus a sampled tuple-set diff is enough for v1 acceptance.

This is what the README's `make compare` target should eventually wrap.

## v1 acceptance criteria (from the README target)

- Context-insensitive PTA: `VarPointsTo` row counts match Soufflé on all 20 DaCapo apps; sampled tuple set matches exactly.
- 1-call-site context-sensitive PTA: matches on `avrora`, `batik`, `eclipse`, `pmd`, `xalan`.
- String-constants analysis: matches on the same five apps.
- `make flowlog-logic` rebuilds the entire transformed corpus from a fresh upstream `souffle-logic/` in one invocation. (Today this is `python3 bin/flowlog-mirror.py <analysis>` per analysis; a make wrapper is small.)

## v2 deferred — don't tackle in this round

These came out of the corpus audit. All sites are in v2-deferred analyses, so v1 is unaffected.

- **Sum-type ADTs** (`= A {} | B { x: number }`) — 12 sites, all in `analyses/sound-may-point-to/`. Either scalarize (tag column + nullable payload columns) or add tagged-union support to FlowLog. Spec when sound-may-point-to is on the roadmap.
- **`inline` annotation on `.decl`** — 10 sites, all in `analyses/xtractor/`. Strip in transform (it's a perf hint; FlowLog plans its own) or implement in engine. Whichever comes first when xtractor is on the roadmap.
- **`.functor` user-defined functors** — 11 sites in `analyses/dependency-context/deco.dl`. The C++ implementation is *not* in this repo — DOOP expects `libfunctors.so` on `LD_LIBRARY_PATH` and `dlopen`s it. Two paths: FFI from FlowLog UDF layer to the existing `.so`, or hand-port to Rust. FFI is the recommended start.
- **`nil` record literal** — 119 sites in `xtractor/`, `sound-may-point-to/`, `dependency-context/`. Records are already supported on `main-next`; just need a way to express the empty/null record literal. Small extension to the records grammar.
- **`as()` casts** — 2 sites, location TBD. Probably trivially handled when subtypes come into play.
- **`float` types** — 5 sites, all in `addons/information-flow/`. Check if `main-next` already has float; if not, small addition.
- **Other analysis families** — object-sensitive, type-sensitive, reflection, threads, exceptions, Android, sound-may-point-to. README's v1 ships only context-insensitive, 1-call-site CS, and string-constants. The rest is v2 by design.

## Project memory

Auto-memory has the two project-level facts:
- Project goal (Souffle → FlowLog port; cross-check against Soufflé baseline)
- Decision to add `.comp` to the engine rather than pre-flatten in transform

Both stored under `/users/zhhong/.claude/projects/-users-zhhong-doop-flowlog/memory/` and will follow into the next session if it runs on the same project path.

## Quick links

- Mirror script: [`bin/flowlog-mirror.py`](../bin/flowlog-mirror.py)
- Generated mirror: [`flowlog-logic/`](../flowlog-logic/) (44 files for context-insensitive)
- Engine spec 1: [`docs/flowlog-components-spec.md`](flowlog-components-spec.md)
- Engine spec 2: [`docs/flowlog-v1-grammar-gaps.md`](flowlog-v1-grammar-gaps.md)
- Engine spec 3: [`docs/flowlog-override-spec.md`](flowlog-override-spec.md)
- Upstream FlowLog: https://github.com/flowlog-rs/flowlog (branch `main-next`)
- Upstream DOOP: https://github.com/plast-lab/doop
- DaCapo fact corpus: https://huggingface.co/datasets/NemoYuu/flowlog_benchmark

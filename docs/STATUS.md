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

**FlowLog engine state (`flowlog-rs/flowlog`):**

Base features on `main-next`, plus the DOOP gap-fill PR stack
#126 (`feat/doop-gap-fills`) → #127 (`…-round2`) → #128 (`…-round3`):

| Feature | Status |
| --- | --- |
| `.comp` / `.init` / parametric / inheritance | ✅ |
| Subtypes (`<:`) | ✅ (gravy — DOOP doesn't actually use them) |
| Records `[a:T1, b:T2]` | ✅ |
| String builtins (cat/ord/substr/strlen/match/contains/to_string/to_number) | ✅ |
| Aggregates (count/min/max/sum) | ✅ |
| Negation `!atom`, anonymous `_`, top-level disjunction `;` | ✅ |
| Parametric `.input` / `.output` (`filename=`, `IO=`, `delimiter=`) | ✅ |
| Multi-head rules with `,` separator | ✅ |
| Parenthesized disjunction nested in conjunction `(A ; B)` | ✅ |
| `.override` directive / `overridable` annotation | ✅ |
| Body-position aggregates `r = op [e] : { body }` | ✅ (#126) |
| Parenthesized arith at boundary `(a - b) <= 15`; `!(Atom)`; bare bool builtins | ✅ (#126) |
| `match(re, s)` regex builtin (anchored, Soufflé semantics) | ✅ (#126) |
| Enclosing-component relation resolution (ancestor-chain visibility) | ✅ (#127) |
| Expression-valued atom args `R(idx - 1, x)`, `ord(h)`, `as(x,T)` | ✅ (#127) |
| Declared-but-underived relations as empty EDBs (`!Empty(x)` always true) | ✅ (#128) |
| **Assignment binding** `t = "boolean"`, `calleeCtx = callerCtx` | ⏭️ next gap (see action #2) |

See the "Gap chain" table under Next concrete actions for the empirically
mapped error sequence and which fix closed each.

**doop-flowlog transform passes (`bin/flowlog-mirror.py`):**


| Transform | Reason it exists |
| --- | --- |
| `strip_plan` | `.plan N:(...)` is Soufflé scheduler hint; FlowLog plans its own. Handles the multi-line form (`1:(...), 2:(...)` wrapped over several lines) too |
| `strip_qmark_vars` | `?varname` is DOOP's LogiQL-era variable prefix; FlowLog rejects `?` in idents because it codegens to Rust (`proc_macro2::Ident`). Stripping is semantically a no-op — every variable consistently has `?`, so no collisions |
| `strip_overridable` | `overridable` annotation; engine now accepts it natively, so this strip can be removed once we re-test |
| `rewrite_bool_builtins` | `match(p,s)` and `contains(n,h)` are bare boolean constraints in Soufflé. FlowLog types both as `bool`-returning value functors, so each must be equated: `f(...)` → `f(...) = True`, `!f(...)` → `f(...) = False`. Comment- and string-literal-aware, so a builtin name inside a `//`/`/* */` comment or a `"..."` fact (e.g. `"boolean contains(java.lang.Object)"`) is never touched. Aggregates are deliberately *not* transformed — FlowLog accepts Soufflé-style `v = min e : {...}` natively |

## Next concrete actions

In priority order:

### 1. Re-run the v1 smoke test against the gap-fill engine branches

The iteration pattern is "find next error, fix, repeat". The gap chain below
was mapped empirically against the engine's `feat/doop-gap-fills-round3`
branch (PRs #126 → #127 → #128 on `flowlog-rs/flowlog`).

**Two driver-side flags the earlier smoke procedure was missing** — without
them the analysis fails on what *looks* like an engine bug but is actually
how DOOP invokes the toolchain:

- `cpp` must define the configuration macro the analysis selects. DOOP's
  `DoopAnalysisFactory.groovy` maps `context-insensitive →
  ContextInsensitiveConfiguration` and passes it as `-DCONFIGURATION=...`.
  Without it, `.init mainAnalysis = BasicContextSensitivity<CONFIGURATION>`
  leaves `CONFIGURATION` unexpanded and the engine reports
  `unknown component CONFIGURATION`.
- the compiler needs `--str-intern` (DOOP uses `ord(...)`, which requires it).

```bash
# build the engine at the gap-fill head
cd /tmp && git clone https://github.com/flowlog-rs/flowlog.git
cd flowlog && git checkout feat/doop-gap-fills-round3 && cargo build --release
export FLOWLOG_BIN=$PWD/target/release/flowlog-compiler

# refresh the mirror
cd /path/to/doop-flowlog
python3 bin/flowlog-mirror.py context-insensitive --clean

# assemble + run (note the -D define and --str-intern flag)
mkdir -p /tmp/v1-smoke
DEF=-DCONFIGURATION=ContextInsensitiveConfiguration
cpp -P $DEF flowlog-logic/facts/facts.dl                          > /tmp/v1-smoke/01-facts.dl
cpp -P $DEF flowlog-logic/basic/basic.dl                          > /tmp/v1-smoke/02-basic.dl
cpp -P $DEF flowlog-logic/analyses/context-insensitive/analysis.dl > /tmp/v1-smoke/03-analysis.dl
cat /tmp/v1-smoke/{01-facts,02-basic,03-analysis}.dl > /tmp/v1-smoke/assembled.dl
$FLOWLOG_BIN --str-intern /tmp/v1-smoke/assembled.dl
```

The cpp-assemble step matches what DOOP's `CPreprocessor.groovy` does today
(per-file preprocess + concatenate to a throwaway flat file). The flat file
goes to `/tmp`; `flowlog-logic/` stays untouched. When the `FlowLogAnalysis`
backend lands (action #3), it must pass `-DCONFIGURATION=<config>` and
`--str-intern` the same way `SouffleAnalysis` does.

### Gap chain (empirically mapped on `feat/doop-gap-fills-round3`)

Running the smoke above, in order encountered:

| # | Symptom | Nature | Status |
| - | ------- | ------ | ------ |
| 1 | `unknown component CONFIGURATION` | driver: missing `-DCONFIGURATION=ContextInsensitiveConfiguration` cpp define | ✅ fixed in smoke/driver (above) |
| 2 | `built-in 'ord' requires '--str-intern'` | driver: missing `--str-intern` flag | ✅ fixed in smoke/driver (above) |
| 3 | `... not yet defined at this point` on `!HeapAllocation_Keep(h)` | engine: a declared-but-underived relation used in negation. Soufflé treats it as empty; FlowLog errored | ✅ fixed — **engine PR #128** (`feat/doop-gap-fills-round3`): prune registers declared-underived-but-referenced relations as empty EDBs. Soufflé-parity fixture `empty_relation_negation` |
| 4 | `unsafe variable 't' in comparison 't == "boolean"` | engine: **assignment binding** (`t = "boolean"`, `calleeCtx = callerCtx`, …) — a variable defined by an equality, range-restricted by no positive atom | ⏭️ **next gap** (see below) |

After fixes 1–3 the smoke reaches the assignment-binding gap (#4).

### 2. Engine gap: assignment binding (the current blocker)

`isPrimitiveType(t), Type_boolean(t) :- t = "boolean".` and friends bind a
variable purely by equality. FlowLog requires every body variable to be
range-restricted by a positive atom, so it rejects these. This is the gap
PR #127 deferred. A **substitution-based desugar draft exists** on the engine
repo's local `main-next` (`crates/flowlog-build/src/parser/grounding.rs`,
unpushed) — it rewrites `v = w` / `v = const` / `v = expr` by substitution.
Two pieces still needed before it lands cleanly on the PR stack:

- adapt it to PR #127's `Predicate` enum (add the `BodyAggregate` arm to
  `subst_pred` / `pred_mentions`);
- **empty-body → fact conversion + multi-head split**: after grounding,
  `A(t), B(t) :- t = "boolean".` becomes `A("boolean"), B("boolean").` — a
  multi-head *fact* with an empty body. FlowLog parses single bare facts
  (`A("boolean").`) but not the multi-head fact form, so the desugar must
  emit one single-head fact per head. Validate byte-for-byte against
  Soufflé 2.5, same as PRs #126–#128.

### 3. Drop the now-redundant `strip_overridable` transform

`bin/flowlog-mirror.py` currently strips `overridable`. Engine handles it natively now. Remove the `strip_overridable` function and its `TRANSFORMS` entry, re-mirror, confirm smoke still passes.


### 4. Wire `FlowLogAnalysis.groovy` backend in DOOP

Parallel to `src/main/groovy/org/clyze/doop/core/SouffleAnalysis.groovy`. Reuse `CPreprocessor` for assembly (same calls, just pointed at `flowlog-logic/` instead of `souffle-logic/`). Replace the Soufflé invocation with a new `FlowLogScript.groovy` parallel to `SouffleScript.groovy` that calls the `flowlog` binary.

Dispatch from `DoopAnalysisFactory.groovy`: a new analysis-engine option (e.g., `--engine flowlog`) picks `FlowLogAnalysis` over `SouffleAnalysis`. Outputs go to the same `outDir/database/` layout so downstream tooling is unchanged.

Sketch:

```
src/main/groovy/org/clyze/doop/core/FlowLogAnalysis.groovy   # ~150 LOC, mirror of SouffleAnalysis
src/main/groovy/org/clyze/doop/utils/FlowLogScript.groovy    # ~80 LOC, mirror of SouffleScript
```

`mainAnalysis()` should call into `flowlog-logic/` instead of `souffle-logic/` — that path needs to be added to `Doop.groovy` alongside the existing `souffleLogicPath`.

### 5. Pin `FLOWLOG_REF`

Once the engine has the four features above and the smoke parses clean, create `FLOWLOG_REF` at the repo root containing the engine commit hash. This is what the README quickstart instructs users to check out.

### 6. End-to-end run on one DaCapo app

The 20-app DaCapo fact corpus lives at `https://huggingface.co/datasets/NemoYuu/flowlog_benchmark/`. Pick `batik` (smallest, fastest to iterate). Run `FlowLogAnalysis` over it, get a `VarPointsTo.csv`.

### 7. Cross-check vs Soufflé baseline

Run the same `context-insensitive` analysis through Soufflé on the same `batik`
corpus and diff the outputs with **`bin/compare-flowlog-souffle.py`** — the
correctness oracle (pairs output relations case-insensitively, checks tuple-set
equality, with a `--partition` mode for the `ord`-renaming representative
relations and a hard failure when an expected relation is missing). This is what
the README's `make compare` target should wrap.

**Result (this session): 21/21 exact on batik.** FlowLog (the complete
end-to-end engine — local draft `3c7c090`, which carries assignment-binding +
the orphan-EDB fix) vs Soufflé 2.5 over the same DOOP fact corpus:
`21 compared, 21 matched, 0 differ`, including `VarPointsTo` (28,249,074),
`InstanceFieldPointsTo` (4,124,124) and `Instruction_Method` (1,724,131). Run
single-threaded (`-w 1`): DOOP picks heap-merge representatives by
`min ord(?heap)` and `ord` is the load-time intern order, so a single worker
interns in fact-file order — matching Soufflé's symbol table — and both engines
pick identical representatives. Under `-w 64` parallel loading the intern order
shifts, so `min ord` picks a *different member of the same merge class*: the
three representative-embedding relations (`VarPointsTo`, `InstanceFieldPointsTo`,
`StaticFieldPointsTo`) then differ with *identical tuple counts* (same
partitions, different representative). The `--partition` modes of the compare
script check that equivalence directly for the 2-column representative relations.

> Engine-track caveat: this 21/21 is on the *old* combination — the
> mirror-pre-desugaring tree (`rewrite_aggregates`/`rewrite_atom_arith_args`,
> tag `wip/session-old-approach`) on the complete draft engine. The *current*
> mirror on `master` is the thin, engine-native one, which targets the
> `feat/doop-gap-fills-*` PR stack. That stack is gap-complete through #128
> (orphan-EDB) but still blocked at **assignment-binding** (action #2 / the gap
> chain), so the thin mirror does not yet compile end-to-end on the PR engine.
> Closing assignment-binding (the draft's `parser/desugar.rs` substitution pass
> — `as_assignment`/`subst_head`/`subst_arith` — is a working reference) makes
> the canonical track reproduce this 21/21.


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

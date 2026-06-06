# doop-flowlog status — hand-off

Where the project stands at the end of this session, so the next machine can pick up without conversation context.

## Snapshot

**Done in this repo:**

- `bin/flowlog-mirror.py` — mirrors `souffle-logic/` → `flowlog-logic/` for one analysis, preserving folder structure, only the files actually needed (uses `cpp -M` to honor `#ifdef`). Applies per-file transforms that lower Soufflé-specific syntax to FlowLog-native form (clean-engine approach): strip `.plan`/`inline` hints and the `?varname` LogiQL-era prefix, normalize type decls, equate bare bool builtins, **lower Soufflé body aggregates to FlowLog head aggregates** (`rewrite_aggregates`), and hoist compound atom args to body equalities (`rewrite_atom_arith_args`). Run with `python3 bin/flowlog-mirror.py context-insensitive --clean`.
- `flowlog-logic/` — generated mirror for context-insensitive (44 .dl files under `basic/`, `main/`, `facts/`, `analyses/context-insensitive/`, plus `commonMacros.dl`). This is a build artifact; regenerate from `souffle-logic/` rather than hand-editing.
- FlowLog engine hand-off specs. `flowlog-v1-grammar-gaps.md` and
  `flowlog-records-spec.md` are checked into `docs/`; the `.comp`/`.init` and
  `.override` specs were folded into the engine PRs on `main-next` and are not
  tracked in this repo:
  - `flowlog-components-spec` — `.comp` / `.init` / parametric / inheritance. **Implemented on `main-next`** (spec not in this repo).
  - [`flowlog-v1-grammar-gaps.md`](flowlog-v1-grammar-gaps.md) — multi-head rules with `,` separator, parenthesized disjunction nested in conjunction. **Implemented on `main-next`.**
  - [`flowlog-records-spec.md`](flowlog-records-spec.md) — record types `[a:T1, b:T2]`, the gap blocking the context-sensitive analysis family.
  - `flowlog-override-spec` — `.override Foo` directive inside `.comp` bodies (verified against Soufflé 2.4). **Implemented on `main-next`** (spec not in this repo).

**FlowLog engine state (`flowlog-rs/flowlog`):**

**Canonical approach — clean engine.** We keep FlowLog's *native* aggregate
syntax (head-position `r = op : { … }`) and do **not** adopt Soufflé-style body
aggregates. `bin/flowlog-mirror.py` lowers every Soufflé-specific construct
(body aggregates, expression-valued atom args, bare bool builtins) to its
FlowLog-native form, so the engine evaluates only native head aggregation and
stays minimal. The rows below marked *mirror* are handled by the adapter, not
required of the engine.

Canonical engine: the **clean engine `flowlog-rs#130`** (commit `3c7c090`) —
`main-next` plus the *non-aggregate* DOOP gap-fills (assignment binding,
orphan-EDB-as-empty, enclosing-component resolution), but **without** the
engine-side body-aggregate desugar from `#129`. That desugar mishandles
multi-witness Soufflé `count` (under-produces ~7.3M `VarPointsTo`, 13/21); the
mirror's lowering is correct (21/21 on batik, §7) — that is the concrete reason
for the clean-engine split. The `#126→#129` (`feat/doop-gap-fills-round4`) fat-
engine track below is kept only as the empirical map of the non-aggregate gaps.

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
| Body-position aggregates `r = op [e] : { body }` | *mirror* — lowered to native head aggregates by `rewrite_aggregates`; engine not required |
| Parenthesized arith at boundary `(a - b) <= 15`; `!(Atom)` | ✅ — bare bool builtins are instead lowered by the mirror (`rewrite_bool_builtins`) |
| `match(re, s)` regex builtin (anchored, Soufflé semantics) | ✅ |
| Enclosing-component relation resolution (ancestor-chain visibility) | ✅ |
| Expression-valued atom args `R(idx - 1, x)`, `ord(h)`, `as(x,T)` | *mirror* — hoisted to body equalities by `rewrite_atom_arith_args`; engine not required |
| Declared-but-underived relations as empty EDBs (`!Empty(x)` always true) | ✅ |
| **Assignment binding** `t = "boolean"`, `calleeCtx = callerCtx` | ✅ |

**End-to-end status:** the clean-engine mirror emits a purely FlowLog-native
program (native head aggregates, no Soufflé body aggregates), which the engine
**compiles end-to-end** (parse → ground → stratify → codegen → `cargo build` →
binary) and **runs** (`-w N`), emitting all 21 DOOP output relations
(`VarPointsTo`, `CallGraphEdge`, `Reachable`, …). On `batik` the output is
**21/21 bit-exact vs Soufflé** (see §7). Remaining for a true Soufflé swap-in:
wire the DOOP `FlowLogAnalysis` backend + run the rest of the corpus + diff
outputs vs Soufflé (actions below).

See the "Gap chain" table under Next concrete actions for the empirically
mapped error sequence and which fix closed each.

**doop-flowlog transform passes (`bin/flowlog-mirror.py`):**


| Transform | Reason it exists |
| --- | --- |
| `strip_plan` | `.plan N:(...)` is Soufflé scheduler hint; FlowLog plans its own. Handles the multi-line form (`1:(...), 2:(...)` wrapped over several lines) too |
| `strip_qmark_vars` | `?varname` is DOOP's LogiQL-era variable prefix; FlowLog rejects `?` in idents because it codegens to Rust (`proc_macro2::Ident`). Stripping is semantically a no-op — every variable consistently has `?`, so no collisions |
| `strip_overridable` | `overridable` annotation; engine now accepts it natively, so this strip can be removed once we re-test |
| `strip_inline` | `inline` is a Soufflé performance hint asking for rule inlining at use sites; no effect on the computed relation, and FlowLog plans its own evaluation, so it is dropped (scoped to `.decl` lines) |
| `normalize_type_decls` | Lower Soufflé type-decl forms FlowLog's grammar rejects onto its single-`type_ref` `.type` alias: `.number_type X`→`.type X = number`, and `.symbol_type X` / bare `.type X` / symbol-union `.type X = A \| B`→`.type X = symbol` (execution-faithful — Soufflé erases all of these to the symbol table). Records (`.type X = [ … ]`) and subtypes (`<:`) are left untouched |
| `rewrite_bool_builtins` | `match(p,s)` and `contains(n,h)` are bare boolean constraints in Soufflé. FlowLog types both as `bool`-returning value functors, so each must be equated: `f(...)` → `f(...) = True`, `!f(...)` → `f(...) = False`. Comment- and string-literal-aware, so a builtin name inside a `//`/`/* */` comment or a `"..."` fact (e.g. `"boolean contains(java.lang.Object)"`) is never touched |
| `rewrite_aggregates` | **The clean-engine core.** Lowers each Soufflé *body* aggregate (`v = op e : { body }`) to a FlowLog *head* aggregate over a fresh auxiliary IDB relation, so the engine only ever evaluates native head aggregation. Groups by the clause's outer variables and types the group var from the body atoms; numeric ops (`min/max/sum/count`) yield numbers |
| `rewrite_atom_arith_args` | A FlowLog body atom takes only a variable, constant or `_`; Soufflé allows arbitrary expressions (`FormalParam(idx - 1, m, f)`, `ord(h)`, `as(x,T)`). Each non-trivial atom argument is replaced by a fresh variable with a prepended `freshVar = <expr>` body equality (the exact Soufflé desugaring). Heads are left untouched — FlowLog already permits arithmetic there |

## Next concrete actions

In priority order:

### 1. Re-run the v1 smoke test against the gap-fill engine branches

The iteration pattern is "find next error, fix, repeat". The gap chain below
was mapped empirically against the `#126→#129` (`feat/doop-gap-fills-round4`)
fat-engine track on `flowlog-rs/flowlog`. It is retained as the record of the
*non-aggregate* gaps (driver flags, orphan-EDB, assignment binding) — all of
which the canonical clean engine `#130` also carries. The aggregate handling of
that track is **not** used (it mis-counts; see the engine-state note above).

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
cd flowlog && git checkout feat/doop-gap-fills-round4 && cargo build --release
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

### Gap chain (empirically mapped on `feat/doop-gap-fills-round4`)

Running the smoke above, in order encountered:

| # | Symptom | Nature | Status |
| - | ------- | ------ | ------ |
| 1 | `unknown component CONFIGURATION` | driver: missing `-DCONFIGURATION=ContextInsensitiveConfiguration` cpp define | ✅ fixed in smoke/driver (above) |
| 2 | `built-in 'ord' requires '--str-intern'` | driver: missing `--str-intern` flag | ✅ fixed in smoke/driver (above) |
| 3 | `... not yet defined at this point` on `!HeapAllocation_Keep(h)` | engine: a declared-but-underived relation used in negation. Soufflé treats it as empty; FlowLog errored | ✅ fixed — **engine PR #129** (consolidated): prune registers declared-underived-but-referenced relations as empty EDBs. Soufflé-parity fixture `empty_relation_negation` |
| 4 | `unsafe variable 't' in comparison 't == "boolean"` | engine: **assignment binding** (`t = "boolean"`, `calleeCtx = callerCtx`, …) — a variable defined by an equality, range-restricted by no positive atom | ✅ fixed — **engine PR #129** (consolidated): grounding desugar (substitute + empty-body→fact). Soufflé-parity fixture `assignment_binding` |
| 5 | `error[E0282]` (uninferrable EDB) + 18× `unused variable` | codegen: empty/intern EDB element types unpinned; grounding resurrected pruned-dead fact relations | ✅ fixed in #129 — EDB element-type pinning + fact-liveness pruning + `unused_variables` lint exemption |

After PR #129 the smoke compiles **all the way through `cargo build`** to a
168 MB binary that runs (`-w N`, EXIT 0) and emits all 21 DOOP output
relations (`VarPointsTo`, `CallGraphEdge`, `Reachable`, …) — but with `#129`'s
engine-side aggregate desugar the *counts are wrong* (multi-witness `count`
under-produces, 13/21). The canonical clean engine `#130` fed by the mirror's
aggregate lowering is bit-exact (21/21, §7). The remaining work is integration,
not language gaps (see below).

### 2. What remains: integration, not language gaps

The engine/language side for context-insensitive is **done** — DOOP compiles
and runs (above). A true Soufflé swap-in now needs only integration work,
detailed in the actions below: wire the `FlowLogAnalysis` backend (#4), pin
`FLOWLOG_REF` (#5), run one DaCapo app (#6), and diff outputs vs Soufflé (#7).

For reference, the manual end-to-end probe (no facts) is:

```bash
DEF=-DCONFIGURATION=ContextInsensitiveConfiguration
cpp -P $DEF flowlog-logic/facts/facts.dl                          > /tmp/v1-smoke/01.dl
cpp -P $DEF flowlog-logic/basic/basic.dl                          > /tmp/v1-smoke/02.dl
cpp -P $DEF flowlog-logic/analyses/context-insensitive/analysis.dl > /tmp/v1-smoke/03.dl
cat /tmp/v1-smoke/0{1,2,3}.dl > /tmp/v1-smoke/assembled.dl
$FLOWLOG_BIN --str-intern -F <facts-dir> --output-dir <out> /tmp/v1-smoke/assembled.dl
```

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

**Result (this session): 21/21 exact on batik.** FlowLog (the clean engine
`flowlog-rs#130`, commit `3c7c090`, which carries assignment-binding + the
orphan-EDB fix but **no** body-aggregate desugar) vs Soufflé 2.5 over the same
DOOP fact corpus:
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

> This 21/21 is on the **canonical clean-engine track**: the mirror's
> `rewrite_aggregates` / `rewrite_atom_arith_args` desugaring (now the committed
> `bin/flowlog-mirror.py`) feeding the clean engine `flowlog-rs#130` (`3c7c090`).
> Because the mirror lowers body aggregates and compound atom args to native
> FlowLog forms, the engine needs no Soufflé-aggregate or boundary-arith support
> — only the orthogonal gap-fills that are *not* about aggregate syntax
> (orphan-EDB-as-empty and assignment binding), which `#130` carries. Crucially
> the mirror's lowering also fixes `#129`'s multi-witness `count` bug (which
> under-produced to 13/21). Pin the engine ref in `FLOWLOG_REF` (action #5) once
> the backend lands so this result is reproducible from a tagged commit.


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

Both are recorded in the agent's machine-local project memory (path is
machine-specific, e.g. `~/.claude/projects/.../memory/`); they are not part of
this repo and will only follow into a next session that runs on the same box.

## Quick links

- Mirror script: [`bin/flowlog-mirror.py`](../bin/flowlog-mirror.py)
- Correctness oracle: [`bin/compare-flowlog-souffle.py`](../bin/compare-flowlog-souffle.py)
- Generated mirror: [`flowlog-logic/`](../flowlog-logic/) (44 files for context-insensitive)
- Engine specs (in repo): [`docs/flowlog-v1-grammar-gaps.md`](flowlog-v1-grammar-gaps.md), [`docs/flowlog-records-spec.md`](flowlog-records-spec.md)
- Engine specs `flowlog-components-spec` and `flowlog-override-spec` — folded into the `main-next` engine PRs; not tracked in this repo.
- Upstream FlowLog: https://github.com/flowlog-rs/flowlog (branch `main-next`)
- Upstream DOOP: https://github.com/plast-lab/doop
- DaCapo fact corpus: https://huggingface.co/datasets/NemoYuu/flowlog_benchmark

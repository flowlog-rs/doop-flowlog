# FlowLog engine spec — record types for DOOP context-sensitive analyses

Hand-off spec for the FlowLog engine (`flowlog-rs/flowlog`, branch `main-next`),
in the same shape as the three specs already implemented
([`flowlog-components-spec.md`](flowlog-components-spec.md),
[`flowlog-v1-grammar-gaps.md`](flowlog-v1-grammar-gaps.md),
[`flowlog-override-spec.md`](flowlog-override-spec.md)).

**This is the single gap blocking the entire context-sensitive analysis family.**
With it, ~30 of DOOP's 37 analyses become reachable; without it, only the
context-insensitive family compiles (5 analyses today: `context-insensitive`,
`context-insensitive-plus`, `basic-only`, `types-only`, `micro`).

> Note: `docs/STATUS.md` previously listed records as "✅ supported on
> `main-next`". That was aspirational — the grammar has no record form (verified
> against `crates/flowlog-build/src/parser/grammar.pest`, where
> `type_ref = { data_type | alias_name }` and there is no record production).
> STATUS.md has been corrected.

## Setup to reproduce

```bash
# in the doop-flowlog repo, with FLOWLOG_BIN pointing at the main-next compiler:
python3 bin/flowlog-mirror.py 1-call-site-sensitive --clean
CONF=OneCallSiteSensitiveConfiguration
for f in facts/facts basic/basic analyses/1-call-site-sensitive/analysis; do
  cpp -P -DCONFIGURATION=$CONF flowlog-logic/$f.dl
done > /tmp/1cs.dl
$FLOWLOG_BIN --str-intern /tmp/1cs.dl -o /tmp/exec -D /tmp/out
# error: syntax error: expected type_ref
#   .type Context = [ invocation:MethodInvocation ]
```

## What DOOP writes (and Soufflé accepts)

DOOP encodes a calling/heap context as a **record** — a fixed-arity tuple of
symbol-rooted components. Three surface forms appear:

**1. Record type declaration** (in a `.comp` configuration body):

```souffle
.type Context  = [ invocation:MethodInvocation ]                 // 1-call-site
.type Context  = [ value1:Value, value2:Value ]                  // 2-object
.type Context  = [ type1:Type, type2:Type, type3:Type ]          // 3-type
.type HContext = [ value:Value ]
```

**2. Record construction** — a record literal that *binds* a value, either as
the RHS of an equality or as a head atom argument:

```souffle
ContextResponse(?callerCtx, ?hctx, ?invo, ?value, ?tomethod, ?calleeCtx) :-
  ContextRequest(?callerCtx, ?hctx, ?invo, ?value, ?tomethod, _),
  ?calleeCtx = [?invo].                       //  <- construct from one component

DynamicContextToContext([?value], ?dynCtx) :- ...   //  <- construct in head
```

**3. Record destructuring / pattern match** — the *same* literal syntax with the
record value already bound, extracting (or constraining) its components. This is
the k-CFA window shift at the heart of k-object/k-call-site sensitivity:

```souffle
Special_TwoCallSiteCtx(?callerCtx, ?invo, ?calleeCtx) :-
  SomeRel(?callerCtx, ?invo),
  ?callerCtx = [?invocation1, ?invocation2],   //  <- DESTRUCTURE bound callerCtx
  ?calleeCtx = [?invocation2, ?invo].          //  <- CONSTRUCT shifted context

isContext([?value, ?any]).                     //  <- match in a body atom arg
```

There is **no field subscripting** (`ctx.0`, `ctx$1`) anywhere — records are
only ever built whole and matched whole. Components are always symbol-rooted
(`Type`, `Value`, `MethodInvocation`, and — after the mirror's union/bare-type
lowering — every `ContextComponent`/`UniqueContext` is `symbol`).

### Site counts (across `analyses/*/analysis.dl`)

| Construct | Count |
| --- | --- |
| Record `.type` declarations | 60 (28 analyses declare a record `Context`/`HContext`) |
| Record literals (`[ ... ]` as value/pattern) | ~289 |
| Distinct arities | 1, 2, 3, 4 (arity ≤ 4; arity 2 most common) |

## Current FlowLog grammar (`crates/flowlog-build/src/parser/grammar.pest`)

```pest
type_ref = { data_type | alias_name }          // no record production
type_alias_decl = { ".type" ~ identifier ~ type_decl_op ~ type_ref }
```

A `.type X = [ ... ]` fails at the `[` (`expected type_ref`); a record literal in
a rule fails at the `[` too. There is no record type, no record value, no
construction, no destructuring.

## Required semantics

A record type `T = [f0:T0, …, fk:Tk]` is a value type whose values are in
bijection with k+1-tuples of component values. The only operations DOOP needs:

* **equality** — two records are equal iff componentwise equal;
* **construction** — `[a0,…,ak]` produces the record value for those components
  (the components are bound; the record becomes bound);
* **destructuring** — matching a *bound* record against `[x0,…,xk]` binds each
  free `xi` to the corresponding component and filters on each already-bound one.

Records flow as ordinary single-column values through every downstream relation
(`VarPointsTo`'s `?ctx` column, `CallGraphEdge`, …), so a record **must have a
single-column representation** — flattening a context into multiple columns
would change the arity of dozens of relations and is not viable.

## Fix — two strategies

### Strategy A (recommended): content-addressed string id + codegen split

Represent a record value as the reserved-delimiter concatenation of its
components, with a separator byte DOOP symbols never contain (e.g. `\x01`):

```
[a, b]   ⟶   a ⟨0x01⟩ b           // a single `symbol`/`Spur` value
```

* **type**: lower `T = [f0:T0,…]` to `T = symbol` internally; remember the field
  arity k+1 for `T`.
* **construction** (`x = [a,b]`, or `[a,b]` in a head arg): emit
  `x = concat(a, SEP, b)`. The engine already concatenates strings in codegen and
  already has the equality-as-assignment desugar pass (`parser/desugar.rs`) that
  substitutes such a computed value into the head/comparisons — construction
  needs no new machinery beyond recognising the record literal.
* **destructuring** (`x = [a,b]` with `x` bound, or `[a,b]` in a body atom): emit
  a fixed-arity split of `x` on `SEP` into exactly k+1 pieces, binding each free
  component and equality-filtering each bound one. This is the one new runtime
  primitive — `split_fixed(s, SEP, k+1) -> [field; k+1]` — and it is exactly why
  records belong in the **engine**, not the doop-flowlog mirror: the mirror has
  no `index-of`/split builtin and cannot invert a concatenation, but the engine
  owns codegen and the runtime and can emit the split directly.

Pros: a record stays one column and flows transparently; no global record table;
fully deterministic and **engine-independent** (unlike `ord`, the encoding does
not depend on interning order, so it sidesteps the representative-renaming
non-portability entirely). Components must be string-rooted — true for DOOP;
a numeric component would round-trip through `to_string`/`to_number`.

### Strategy B: Soufflé-style record table

Maintain a per-type collection `_RecordTable_T(id, f0,…,fk)` keyed by an interned
id; construction is insert-or-lookup, destructuring is a join. Faithful to
Soufflé and supports arbitrary component types, but heavier: a maintained
collection plus a join on every record use, and id allocation must be
content-addressed (not a counter) to stay deterministic across workers/runs.

For DOOP's fixed-arity, symbol-rooted, opaque-key usage, **Strategy A is simpler,
deterministic, and avoids any interning-order dependence**, so it is recommended.

## Test case (smallest reproducer)

```souffle
.type Pair = [ a:symbol, b:symbol ]
.decl In(x:symbol, y:symbol)
.decl Out(p:Pair)
.decl Back(a:symbol, b:symbol)
In("p", "q").
Out(?p) :- In(?x, ?y), ?p = [?x, ?y].        // construct
Back(?a, ?b) :- Out(?p), ?p = [?a, ?b].      // destructure
.output Back
```

Expected post-evaluation: `Back = { ("p", "q") }`. (Round-trips a record through
construction and destructuring; passes iff both directions work.)

## Adjacent, smaller engine gaps (for the same context-sensitive push)

These surface *after* records in the deeper analyses; recording them here so the
next engine pass can batch them:

* **Double-underscore relation names.** `identifier = @{ "_"? ~ ASCII_ALPHA+ … }`
  allows at most one leading `_`, so DOOP's `__OperatorAt` (data-flow, xtractor)
  fails with `expected relation_name`. One-character grammar fix: `"_"?` → `"_"*`.
* **`nil` record literal, `as(x,T)` casts, sum-type ADTs (`= A {} | B {x}`).**
  Needed only by `xtractor`, `sound-may-point-to`, `dependency-context`. Out of
  scope for the PTA family; spec separately when those analyses are scheduled.

## What the mirror already handles, so the engine never sees it

`bin/flowlog-mirror.py` lowers the type-declaration forms FlowLog's grammar does
not accept but DOOP's string world makes trivial (so the engine only has to
implement records, above, not these):

* `.number_type X` / `.symbol_type X` → `.type X = number` / `= symbol`
* bare `.type X` (uninterpreted primitive) → `.type X = symbol`
* union `.type X = A | B | …` (symbol-rooted members) → `.type X = symbol`
* `inline` annotation on `.decl` (perf hint) → stripped
* `.plan`, `overridable`, `?`-variable prefixes, body-aggregates, boolean
  builtins, arithmetic in atom args → see the mirror's transform table.

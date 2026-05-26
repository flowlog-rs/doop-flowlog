# FlowLog v1 grammar gaps for DOOP context-insensitive

Hand-off spec for the FlowLog engine team. Found by feeding the
context-insensitive analysis entry through `main-next`'s
`flowlog-compiler`. Two grammar gaps so far; more will surface as
the smoke test progresses, so treat this as the first batch.

## Setup to reproduce

```bash
# in the doop-flowlog repo:
python3 bin/flowlog-mirror.py context-insensitive --clean
cpp -P flowlog-logic/analyses/context-insensitive/analysis.dl > /tmp/entry.dl
flowlog-compiler /tmp/entry.dl
```

The `bin/flowlog-mirror.py` step already applies the doop-flowlog-side
transforms (strip `.plan`, strip the `?` variable prefix DOOP inherits
from LogiQL, strip the unused `overridable` annotation). What flowlog
parses below is the result *after* those strips.

## Gap 1 — multi-head rules use `,` not `;`

### What DOOP writes (and Soufflé accepts)

```souffle
AssignInvokedynamic(insn, ret, heap, "java.lang.String"),
VarPointsTo(hctx, heap, ctx, ret),
Value_isMock(heap), isValue(heap),
Value_Type(heap, "java.lang.String"),
Value_DeclaringType(heap, "java.lang.Object") :-
  DynamicMethodInvocation_Bootstrap(insn, "..."),
  Instruction_Method(insn, method),
  ...
```

Six head atoms separated by `,`. Each head atom is independently
derived from the (single) body. Equivalent to writing six separate
rules sharing the same body.

### Current FlowLog grammar (`crates/flowlog-build/src/parser/grammar.pest`)

```pest
// Rule with optional multi-head and multi-body (Souffle-style).
// Semicolons separate alternative heads and alternative bodies:
//   h1; h2 :- b1; b2.  →  h1:-b1. h1:-b2. h2:-b1. h2:-b2.
rule = { rule_heads ~ ":-" ~ rule_bodies ~ "." }

// One or more semicolon-separated heads
rule_heads = { head ~ (";" ~ head)* }
```

The grammar comment claims Soufflé compatibility but uses the wrong
separator: real Soufflé uses `,` between heads, `;` between body
alternatives.

### Fix

```pest
// Accept either ; or , as the head separator. Souffle uses ',' historically;
// allow ';' too so existing FlowLog programs keep working.
rule_heads = { head ~ ((";" | ",") ~ head)* }
```

Then update the comment to describe the actual semantics:
"multi-head rule: each head is derived independently from the body".

### Test case (smallest reproducer)

```souffle
.decl A(x: number)
.decl B(x: number)
.decl Source(x: number)
Source(1). Source(2).
A(x), B(x) :- Source(x).
.output A
.output B
```

Expected post-evaluation: `A = B = {1, 2}`.

### Site count in DOOP context-insensitive corpus

143+ multi-head rule sites across the 44 transformed `.dl` files.
Cannot ship v1 without this fix (or a transform-side rewrite, which
needs a paren-depth-aware state machine — engine fix is much smaller).

---

## Gap 2 — parenthesized disjunction in rule bodies

### What DOOP writes

```souffle
MethodHandleCallGraphEdge_Candidate(callerCtx, invo, method, mh, name) :-
  ReachableContext(callerCtx, containingMethod),
  ( _VirtualMethodInvocation(invo, _, _, base, containingMethod)
  ; _SpecialMethodInvocation(invo, _, _, base, containingMethod) ),
  _PolymorphicInvocation(invo, name),
  VarPointsTo(_, mh, callerCtx, base),
  MethodHandle_Method(mh, method).
```

The `( A ; B )` between two conjuncts is a disjunctive sub-expression.
The whole body reads: `Reachable AND (Virtual OR Special) AND Polymorphic
AND VarPointsTo AND MethodHandle_Method`.

### Current FlowLog grammar

```pest
// One or more semicolon-separated bodies (disjunction)
rule_bodies = { predicates ~ (";" ~ predicates)* }
```

`;` is only legal at the *top level* of a body. A nested `(A ; B)`
inside a conjunction is rejected with "expected predicate" at `(`.

### Fix

Allow a parenthesized body expression as a literal inside a
conjunction. Approximate grammar shape:

```pest
predicates    = { literal ~ ("," ~ literal)* }
literal       = { atom | negative_atom | comparison | "(" ~ rule_bodies ~ ")" }
rule_bodies   = { predicates ~ (";" ~ predicates)* }
```

(Adapt to FlowLog's existing rule names — the point is to give
`literal` a "parenthesized rule_bodies" alternative so disjunction
nests inside conjunction.)

Semantically, `(A ; B)` should expand to the two-rule form during
flattening:

```
H :- ..., (A ; B), ... .
// expands to:
H :- ..., A, ... .
H :- ..., B, ... .
```

That matches Soufflé semantics and DDlog semantics.

### Test case

```souffle
.decl A(x:number) .decl B(x:number) .decl C(x:number) .decl R(x:number)
A(1). B(2). C(3).
R(x) :- A(x), (B(x) ; C(x)).
.output R
```

Expected: `R = {1}` only if both `A` and `B|C` have `1`; given the
facts above, `R = {}` because `A` has only `1` while `B|C` has only
`{2, 3}`. Change to `A(1). A(2). B(2). C(3).` and you get `R = {2}`.

### Site count

Found in at least `main/method-handles.dl`, `main/api-mocking.dl`,
`main/implicit-reachable.dl`, `basic/type-hierarchy.dl`. Exact count
across the corpus is on the order of dozens; will tighten with the
next smoke iteration.

---

## What's already known to work in `main-next`

- `.comp` / `.init` / parametric / inheritance (the work just landed)
- Subtypes (`<:`) — gravy, DOOP doesn't actually use them
- Records (`[a:T1, b:T2]`)
- String builtins (`cat`, `ord`, `substr`, `strlen`, `match`, `contains`,
  `to_string`, `to_number`)
- Aggregates (`count`, `min`, `max`, `sum`)
- Negation (`!atom`)
- Anonymous `_` variable
- Top-level disjunction (`H :- A ; B.`) — gap 2 is only about *nested* `(A;B)`
- Parametric `.input`/`.output` (`filename=`, `IO=`, `delimiter=`)

## What doop-flowlog already strips, so the engine never sees

- `?varname` (DOOP's LogiQL-era variable prefix) — `bin/flowlog-mirror.py`
- `overridable` annotation on `.decl` — only used as a forward-compat marker;
  no `.override` directive actually exists anywhere in DOOP
- `.plan N:(...)` scheduling hints

## Iteration plan

After both grammar fixes ship on `main-next`, I re-run the smoke and
write a v2 follow-up doc with whatever the next error class is. The
goal is to grind through the gaps one batch at a time rather than
guessing at them up front.

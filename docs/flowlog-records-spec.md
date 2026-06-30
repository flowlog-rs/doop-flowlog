# FlowLog engine spec — record types (fixed-tuple representation) for DOOP context-sensitive analyses

Hand-off spec for the FlowLog engine (`flowlog-rs/flowlog`), in the same shape
as the implemented specs (`flowlog-components-spec.md`,
`flowlog-v1-grammar-gaps.md`, `flowlog-override-spec.md`).

**This is the single gap blocking the entire context-sensitive analysis family.**
With it, ~30 of DOOP's 37 analyses become reachable; without it, only the
context-insensitive family compiles (`context-insensitive`,
`context-insensitive-plus(plus)`, `basic-only`, `types-only`, `micro`).

> Note: an earlier draft of this spec recommended a **string-encoding**
> representation (mirroring Soufflé's interned record-table id). After analysis
> (below), the decision is a **fixed-tuple** representation for the flat
> context-sensitive family, which is faster on DOOP's long-signature components
> (no per-op interning) and reuses FlowLog's existing tuple-row codegen. The
> string-encoding is reserved, behind a representation seam, for the recursive
> niche families only.

## Scope

- **Ship now:** flat record types via a **fixed-tuple** representation. This
  covers the entire mainstream points-to hierarchy (all `Context`/`HContext`
  records — arity ≤ 4, every field symbol-typed, no recursion).
- **Build the front-end general:** grammar / type-system / IR must *parse and
  type* recursive record declarations too (they cost nothing extra to parse),
  and codegen must go through a **`RecordRepr` seam**, so the recursive niche
  families (`sound-may-point-to`, `xtractor`) can later be added as a *second*
  codegen lowering (string-encoding) **without a front-end rewrite**.
- **Do not build now:** the recursive/string lowering, trees, `nil`, sum-type
  ADTs, `.functor`, double-underscore relation names. All niche, all separate.

## Semantics (the whole feature)

A record type `T = [f0:T0, …, fk:Tk]` is a **fixed-arity, immutable tuple** — a
single-column value. It supports exactly three operations; there is **no
indexing, no field access, no length, no iteration**:

1. **construct (whole):** `x = [a, b]` — as the RHS of an equality or a head-atom
   argument; builds the value from its (bound) components.
2. **destructure (whole):** `[a, b]` matched against a **bound** `x` — binds free
   components positionally and equality-filters already-bound ones (exactly like
   Rust `let (a, b) = x`). This is the k-CFA context shift.
3. **equality / join key:** componentwise equality. The record is a **join key**
   in nearly every context-sensitive rule (the `ctx`/`hctx` column), so it must
   hash and compare by content.

`ord(record)` must be supported: two analyses (`2-object-sensitive+heap`,
`3-object-sensitive+2-heap`) compute `(ord(value) * ord(hctx)) % 101` as a hash
bound, where `hctx` is a record.

**Input:** records never appear in EDB facts — contexts are *constructed* by
rules at runtime. **The fact reader needs no record logic.**

**Output:** a record column must be serialized as **`[a, b]`** (Soufflé's bracket
form, each component resolved to its string) so the correctness oracle matches.

## What DOOP writes (audited across the whole framework)

- **Mainstream (the ~30 CS families):** only `Context` / `HContext`, all **flat,
  arity 1–4**, every field **symbol-rooted** (`MethodInvocation`, `Value`,
  `Type`, `symbol`, `ContextComponent`). **No nesting, no recursion.** Field
  *types* may differ (`[type:Type, value:Value]`), but every field erases to
  `Spur` under `--str-intern`.
- **Recursive records:** exactly **6 types, only in 2 niche families** —
  `sound-may-point-to` (`MayContext`, `AccessPathSuffix`, `AccessPath`) and
  `xtractor` (`Cond`, `GroupCond`, `Expr`). Cons-lists (unbounded) plus one tree
  (`Expr`). **Out of scope; handled later by the string lowering.**

Site counts: ~60 record `.type` declaration sites (the same few names redeclared
per analysis), ~289 record literals, arities 1–4 (2 most common).

## Representation: fixed tuple `(T0, …, Tk)`

A flat record lowers to a **fixed-arity Rust tuple of the fields' erased types**.
For DOOP that is `(Spur, …, Spur)` (every field is symbol-rooted), but a `number`
field would be `i64` — the tuple handles heterogeneous fields correctly, whereas
a homogeneous `[Spur; k]` array would not. The tuple is **inline** (`Copy`,
contiguous, no heap, no interner entry, no side table) and FlowLog already lowers
every relation row to a Rust tuple of typed columns, so a record column is just a
nested tuple — reusing existing `tuple_type` / `tuple_tokens` codegen.

Lowering:

| construct | source | lowering |
| --- | --- | --- |
| type decl | `.type T = [f0:T0,…,fk:Tk]` | internal `RecordType{ fields, recursive }`; Rust type = `(T0',…,Tk')` (erased per-field) |
| construct | `x = [a, b]` | `let x = (a, b);` |
| destructure | `x = [a, b]` (`x` bound) | `let (a, b) = x;` — bind free components; for an already-bound component emit an equality filter |
| equality / join | `x = y`, join on `x` | derived `Ord`/`Hash`/`Eq`/`Clone`/`Copy` on the tuple — DD joins on it natively (same as FlowLog's existing multi-column tuple keys) |
| `ord(record)` | `ord(x)` | a content hash of the tuple (deterministic, worker-independent); used only for bucketing — won't equal Soufflé's id, which is fine (those 2 families are heuristic/non-exact regardless) |
| output | print column | `[c0, …, ck]` with each `Spur` resolved to its string |

Construct/destructure **direction** (which side is bound) is decided by
range-restriction, exactly as `parser/desugar.rs` already does for `x = <expr>`
assignment-binding — extend that pass to recognize record literals.

### Why fixed-tuple (not string-encoding, not Soufflé's id)

- **No per-op interning.** The string-encoding *and* Soufflé's record table both
  pay a hash-table op on every construct **and** destructure; DOOP components are
  long method signatures, so that is hashing 50–800 chars per context op. The
  inline tuple just copies already-interned `Spur`s. This is the dominant win.
- **No heap** (unlike `Vec<Spur>`), **no side table** (unlike Soufflé), **small
  inline key** (k ≤ 4).
- Soufflé uses an interned 1-word id because its uniform-word value model
  *forces* it — not because it is fastest. FlowLog's richer value model lets it
  inline the tuple, which Soufflé cannot express.

## Required work (itemized)

1. **Grammar** (`crates/flowlog-build/src/parser/grammar.pest`):
   - record type: `record_type = { "[" ~ record_field ~ ("," ~ record_field)* ~ "]" }`,
     `record_field = { identifier ~ ":" ~ type_ref }`; allow `record_type` in the
     `.type` RHS (`type_ref = { data_type | record_type | alias_name }`).
   - record literal (value/pattern): `record_literal = { "[" ~ arithmetic_expr ~ ("," ~ arithmetic_expr)* ~ "]" }`,
     usable as a `factor` and as an atom argument.
   - *Recursion parses for free:* a field type `rest:MayContext` is just
     `alias_name` — no extra grammar work.
2. **Type system:** first-class `RecordType { fields: Vec<Type>, recursive: bool }`;
   track arity; type-check construct/destructure against per-field types; set
   `recursive` when the type (transitively) references itself — this is the seam's
   dispatch key.
3. **IR / desugar:** abstract `Pack` / `Unpack`; recognize record literals in
   equalities and head args; extend the assignment-binding desugar for direction.
4. **Codegen — `RecordRepr` seam:** an enum/trait with a **`FixedTuple{ fields }`
   variant implemented now**, and a reserved **`StringEncoded` variant
   (unimplemented)** for `recursive: true`. Dispatch on `RecordType.recursive`.
   For `FixedTuple`: construct → tuple literal, destructure → tuple pattern,
   column Rust type → `(T0,…,Tk)`.
5. **`ord`:** content hash for the `FixedTuple` repr.
6. **Output formatting:** record column → `[a, b]` with resolved strings.

## Forward-compat (do NOT build now, just don't foreclose)

- Front-end (grammar/type-system/IR) accepts recursive record decls and literals.
- The `RecordRepr` seam reserves `StringEncoded` for `recursive: true` types,
  added later for `sound-may-point-to` / `xtractor` (construct = `concat`,
  destructure = `split`, absorbs unbounded depth + trees as one interned `Spur`).
- So the recursive families later need only a **second codegen lowering**, not a
  redesign — the front-end never changes.

## Test cases (must pass)

**1. Round-trip unit test (smallest reproducer):**

```souffle
.type Pair = [ a:symbol, b:symbol ]
.decl In(x:symbol, y:symbol)
.decl Out(p:Pair)
.decl Back(a:symbol, b:symbol)
In("p","q").
Out(p)    :- In(x,y), p = [x,y].     // construct
Back(a,b) :- Out(p), p = [a,b].      // destructure
.output Back
// expect Back = { ("p","q") }
```

**2. End-to-end 1-call-site (the real target):**

```bash
DEF=-DCONFIGURATION=OneCallSiteSensitiveConfiguration
cpp -P $DEF flowlog-logic/facts/facts.dl                              > 01.dl
cpp -P $DEF flowlog-logic/basic/basic.dl                              > 02.dl
cpp -P $DEF flowlog-logic/analyses/1-call-site-sensitive/analysis.dl  > 03.dl
cat 0{1,2,3}.dl > assembled.dl
$FLOWLOG_BIN --str-intern -F <batik-facts> -D <out> -o <bin> assembled.dl
<bin> -w 1
# then diff vs Soufflé:
bin/compare-flowlog-souffle.py <out> <souffle-out>   # expect exact (representative relations under --partition / -w 1)
```

## Non-goals (explicitly out of scope now)

- String-encoding / recursive lowering (`sound-may-point-to`, `xtractor`).
- Trees, `nil`, sum-type ADTs, `.functor`, double-underscore relation names.
- A general indexable array/collection type — records are **only**
  pack-whole / unpack-whole / equality.

## What the mirror already handles (so the engine never sees it)

`bin/flowlog-mirror.py` lowers the forms FlowLog's grammar does not accept but
DOOP's string world makes trivial: `.number_type`/`.symbol_type` → `= number`/
`= symbol`; bare `.type X` → `= symbol`; union `.type X = A | B` (symbol-rooted)
→ `= symbol`; `inline` stripped; `.plan`, `overridable`, `?`-prefixes,
body-aggregates, boolean builtins, arithmetic-in-atom-args per its transform
table. The engine only has to implement **records**, above.

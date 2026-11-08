# flowlog-logic — DOOP's analyses on FlowLog

A mirror of [`souffle-logic/`](../souffle-logic) (the DOOP points-to pipeline:
facts schema, `basic/`, `main/`, and 24 analysis families), translated to the
FlowLog dialect for FlowLog `main`. Rule structure and
stratification are identical to Soufflé; only the **grammar** differs, in five
ways:

**1. Variable names — drop the `?` prefix.**
```prolog
Superinterface(?k, ?c) :- DirectSuperinterface(?c, ?k).   // Soufflé
Superinterface(k,  c ) :- DirectSuperinterface(c,  k ).   // FlowLog
```

**2. Records → tuples** — `[a, b]` → `(a, b)`, and a 1-record `[x]` → `(x,)`.
```prolog
.type Context = [ v1:Value, v2:Value ]   →   .type Context = ( v1:Value, v2:Value )
hctx = [hctxValue]                        →   hctx = (hctxValue,)
```

**3. Aggregates name the columns they range over** — an aggregate is written
as in Soufflé, but `_` binds nothing: it ranges over the distinct bindings of
its named variables, where Soufflé's ranges over the matching tuples. So a
column Soufflé counts or sums over through `_` gets a name.
```prolog
A(t, m, n) :- R(_,t,m), n = count : R(_,t,m).   // Soufflé
A(t, m, n) :- R(_,t,m), n = count : R(h,t,m).   // FlowLog
```

**4. `.plan` join-order hints dropped** — FlowLog schedules its own joins.
```prolog
.plan 1:(4,3,2,1)   →   (removed)
```

**5. No arithmetic inside atom arguments** — hoist to a fresh variable.
```prolog
FormalParam(?idx - 1, ?m, ?f),          // Soufflé
FormalParam(fidx, m, f), fidx = idx - 1 // FlowLog
```

Everything else is byte-identical to Soufflé: rule bodies, `.decl`/`.type`,
the `.output` set, `match`/`contains`, `overridable`, `.comp`/`.init`
components, functors (`ord`, `cat`, `substr`), negation and disjunction.

## Supported

**24 families run** — the full context-sensitivity hierarchy (k-call-site,
k-object, k-type, hybrids) plus adaptive / sticky / selective / partitioned.
**Not ported**: families needing orthogonal Soufflé features — union/sum types,
`inline`, external `.functor` (context-insensitive-plus(plus), fully-guided,
sound-may-point-to, xtractor, blacklist, dependency-context).


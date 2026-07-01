# Standalone single-file programs (19 verified families × 2 engines)

Each `.dl` here is **one fully self-contained Datalog program** — the DOOP
`facts + basic + analysis` layers already assembled by the C preprocessor for a
specific analysis configuration, with output restricted to `VarPointsTo`. **No
DOOP, no Java, no `cpp`, and not even this repo's directory layout are needed to
use them** — feed a file straight to the compiler.

- `flowlog/<family>.dl` — 19 FlowLog programs (`= True` grammar).
- `souffle/<family>.dl` — 19 Soufflé programs (`.plan` directives stripped —
  affects only join scheduling, not output).

These are the **19 byte-exact-verified families** (see `../timing_summary.tsv`),
assembled from the verified `master` state of this repo.

## You still need the facts (EDB)

These programs are the *rules*; they read the input relations (the `.facts`
files) at run time via `-F`. The remote machine **cannot regenerate them without
DOOP/Java**, so the DOOP-generated fact directory for the benchmark (e.g.
luindex) **must be transferred** alongside these programs. Point `-F` at it.

## Run — FlowLog

Build the compiler that matches the `= True` grammar: **`flowlog-rs/flowlog` @
`nemo/tuple` (`32cbc00`)** — it has the tuple-EDB handling the context-sensitive
families need. (`main-next` / `parser-refactor` will panic; for those use the
bare-grammar variant on this repo's `flowlog-next-datalog-compat` branch.)

```bash
FLC=/path/to/flowlog/target/release/flowlog-compiler
FACTS=/path/to/luindex/facts
fam=2-object-sensitive+heap

$FLC --str-intern -F "$FACTS" -D ./out -o ./bin  flowlog/$fam.dl
./bin -w 1        # single-thread for apples-to-apples; raise -w N to go faster
# -> ./out/VarPointsTo.csv
```

## Run — Soufflé

```bash
FACTS=/path/to/luindex/facts
fam=2-object-sensitive+heap

souffle -c -o ./sfbin  souffle/$fam.dl
./sfbin -j 1 -F "$FACTS" -D ./sfout
# -> ./sfout/VarPointsTo.csv
```

## Compare (byte-exact)

Soufflé writes records as `[a,b]`, FlowLog as `(a,b)`; canonicalise then sort:

```bash
canon(){ sed -e 's/\[/(/g; s/\]/)/g; s/, /,/g; s/,)/)/g' "$1" | LC_ALL=C sort; }
diff <(canon out/VarPointsTo.csv) <(canon sfout/VarPointsTo.csv) && echo MATCH
```

## The 19 families

context-insensitive · 1-type-sensitive · 1-type-sensitive+heap ·
1-call-site-sensitive · 1-call-site-sensitive+heap · 1-object-sensitive ·
1-object-sensitive+heap · 1-object-1-type-sensitive+heap · 2-type-sensitive+heap ·
2-type-object-sensitive+heap · 2-type-object-sensitive+2-heap ·
2-object-sensitive+heap · 2-object-sensitive+2-heap · adaptive-2-object-sensitive+heap ·
3-type-sensitive+2-heap · 3-type-sensitive+3-heap · 3-object-sensitive+2-heap ·
3-object-sensitive+3-heap · 4-object-sensitive+4-heap

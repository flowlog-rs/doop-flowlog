# Running the context-insensitive analysis on Soufflé

Doop's `context-insensitive` pointer analysis always works the same way: the
Soot front-end **generates facts** from the input program against a chosen
**platform**, then Doop assembles + compiles + runs the Soufflé logic over
those facts. There is no separate "prefetched" mode — a saved fact directory is
just the output of an earlier generation, reused.

What makes a run **sparse** or **dense** is the full generation provenance —
**Doop version + platform + fact-gen options + the program** — not how the facts
were obtained:

- a **modular JDK** platform (`java_17`) resolves less library code → **sparser**
  result (fewer points-to per var); an **older/fuller** platform (e.g. `java_8`
  with a full `rt.jar`) resolves more concrete library classes → **denser**;
- different **Doop versions** generate facts differently (front-end/SSA changes,
  fact-schema evolution, different default entrypoints/options), so the same
  program+platform can yield different fact sets across versions.

> **Note — this checkout is a fork.** `flowlog-rs/doop-flowlog` is a fork of
> upstream `plast-lab/doop` (see `git remote`). Its Soot front-end produces a
> *different* fact set than the most-updated upstream Doop — e.g. its java_17
> run gives ~2.07M `Var-Type` rows / 6.1M VarPointsTo, whereas a dense corpus
> from a newer upstream Doop has fewer vars (~1.23M) but denser points-to
> (~21.7M). So a "modern, dense" corpus is typically produced by **upstream Doop
> (latest)**, not by this fork.

So to get either, you **generate the facts by hand** with the desired config
(§1) using *this* checkout's (forked) Doop. To reproduce a corpus from a
different Doop — e.g. the modern dense one — generate with **that** Doop
(upstream latest) or reuse its saved fact directory (§2); don't assume this fork
regenerates it identically.

---

## 0. One-time setup (fill these in)

```bash
# --- paths you provide ---
DOOP=/path/to/doop-flowlog            # this Doop checkout
JDK=/path/to/jdk-17                    # a JDK 17+ install (Doop requires it to run)
SCRATCH=/path/to/scratch              # roomy/fast dir for outputs (e.g. a tmpfs)
APP_JAR=/path/to/app.jar              # program to analyze (e.g. dacapo batik.jar)
APP_DEPS=/path/to/app-deps.jar        # its dependency jar(s), optional

export JAVA_HOME="$JDK"
export PATH="$JAVA_HOME/bin:$PATH"
which souffle                          # Soufflé (2.4+) must be installed & on PATH
export DOOP_OUT="$SCRATCH/doop-out"    # keep large databases off the root fs
export DOOP_CACHE="$SCRATCH/doop-cache"
cd "$DOOP"
```

---

## 1. Generate facts and run (the by-hand path)

### 1a. Sparse — modular platform, no extra platform jars needed

```bash
./doop -a context-insensitive \
  -i "$APP_JAR" -l "$APP_DEPS" \
  --platform java_17 --use-local-java-platform "$JDK" \
  --id ci-sparse --stats none --souffle-jobs 64
```

`--use-local-java-platform <jdk>` builds the platform from the JDK's `jmods/`,
so no platform-jar download is needed — but a modular JDK exposes less library
code, giving the sparser result.

### 1b. Dense — fuller/older platform

Pick an older platform that ships a full `rt.jar` (more library code → denser):

```bash
# Either: point at an older JDK install with rt.jar
./doop -a context-insensitive -i "$APP_JAR" -l "$APP_DEPS" \
  --platform java_8 --use-local-java-platform /path/to/jdk-8 \
  --id ci-dense --stats none --souffle-jobs 64

# Or: provide platform jars and let Doop resolve `java_8` from them
export DOOP_PLATFORMS_LIB=/path/to/doop-benchmarks   # has JREs/ for java_N
./doop -a context-insensitive -i "$APP_JAR" -l "$APP_DEPS" \
  --platform java_8 --id ci-dense --stats none --souffle-jobs 64
```

Other knobs also change density/precision (reflection handling, entrypoints,
app-vs-library scope, `--main`, `--dacapo`, …) — see `./doop -h`. To reproduce a
*specific* corpus exactly you need its exact generation config — **Doop version
+ platform + options** — since fact generation differs across Doop versions and
this checkout may not match the version that produced a foreign corpus.

Either run writes results to `$DOOP_OUT/<id>/database/*.csv` (tab-separated),
e.g. `VarPointsTo.csv`; per-phase times in `database/Stats_Runtime.csv`. It also
caches the compiled Soufflé binary under
`$DOOP_CACHE/souffle-analyses/context-insensitive/<checksum>`.

---

## 2. (Shortcut) Re-run on an already-generated fact directory

If you already have a `.facts` directory from a previous generation (e.g. copied
out of a prior `database/`, or shared by a colleague — possibly from a different
Doop version/platform) and don't want to (or can't exactly) regenerate it, run
the compiled Soufflé binary straight at it. As long as the fact **schema**
(relation names/arities) matches what this checkout's logic expects, it just
works:

```bash
FACTS=/path/to/facts        # a directory of *.facts

# (a) the compiled binary cached by any earlier §1 run:
SBIN=$(find "$DOOP_CACHE/souffle-analyses/context-insensitive" -type f \
        -exec sh -c 'file "$1" | grep -q ELF && echo "$1"' _ {} \; | head -1)
#     (none yet? run §1 once on any jar to produce it.)

# (b) Soufflé errors on a missing input fact file (FlowLog tolerates them);
#     create the empty defaults a copied fact dir may omit:
for f in Dacapo KeepClass KeepClassMembers KeepClassesWithMembers \
         KeepMethod RootCodeElement TaintSpec Tamiflex; do
  [ -f "$FACTS/$f.facts" ] || : > "$FACTS/$f.facts"
done

# (c) run (the binary reads -F at run time, so any compatible fact dir works):
mkdir -p "$SCRATCH/ci-out"
/usr/bin/time -v "$SBIN" -F "$FACTS" -D "$SCRATCH/ci-out" -j 64
#     Results: $SCRATCH/ci-out/VarPointsTo.csv
```

---

## Notes

- **FlowLog equivalent:** identical commands with `--engine flowlog` (and
  `--flowlog-jobs N` instead of `--souffle-jobs N`). Point Doop at a
  `flowlog-compiler` binary **you already have** — Doop does **not** download
  one:
  ```bash
  export FLOWLOG_BIN=/path/to/flowlog/target/release/flowlog-compiler
  ```
  Build it from source (needs `cargo`/`rustc` + `cc` on `PATH`, since it
  compiles a generated Rust crate at run time):
  ```bash
  (cd /path/to/flowlog && cargo build --release -p flowlog-compiler)
  ```
  Avoid the published GitHub release binary on older distros: it may be linked
  against a newer glibc than the host (e.g. needs `GLIBC_2.39`), failing with
  `version 'GLIBC_2.39' not found`. A source build links against the local
  glibc. Output goes to the same `database/*.csv` layout.
- **Worker count:** `64` is a starting point; the sweet spot is often lower
  (e.g. `32`) — past it, coordination overhead can outweigh extra cores.
- **Row counts:** `wc -l database/VarPointsTo.csv`. Soufflé and the FlowLog port
  agree to within the small `ord()`/string-constant non-determinism.

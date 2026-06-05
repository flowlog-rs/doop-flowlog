#!/usr/bin/env python3
"""Mirror the subset of souffle-logic/ needed for one analysis into flowlog-logic/.

Walks `#include` directives transitively from DOOP's standard assembly entry
points (facts/facts.dl, basic/basic.dl, analyses/<analysis>/analysis.dl) plus
any analysis-specific addons we wire in later. Each reached file is copied to
the matching path under flowlog-logic/, preserving the source-tree layout so
humans can diff the two trees side by side.

Per-file transforms (see `TRANSFORMS`) normalize Soufflé syntax FlowLog does
not accept verbatim: `.plan` scheduler hints are stripped, the `?` variable
prefix is removed, the `overridable` annotation is dropped, and the boolean
string functors `match`/`contains` are equated (`f(...)` → `f(...) = True`).
Soufflé-style aggregates (`v = min e : {...}`) are left untouched — FlowLog
parses them natively.

Usage:
  bin/flowlog-mirror.py <analysis-name>          # e.g. context-insensitive
  bin/flowlog-mirror.py <analysis-name> --clean  # wipe flowlog-logic/ first
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SOUFFLE_LOGIC = REPO_ROOT / "souffle-logic"
FLOWLOG_LOGIC = REPO_ROOT / "flowlog-logic"


# --- per-file transforms ----------------------------------------------------
#
# Each transform takes the file's text and returns the rewritten text. Order
# matters: passes higher up run first. Passes are kept narrow so the diff
# against the corresponding souffle-logic/ file stays readable.


# A `.plan` directive may span several lines when its per-overload clauses
# (`1:(...), 2:(...), ...`) are wrapped. Strip the `.plan` line *and* any
# trailing continuation clause lines so multi-version plans are fully removed.
_PLAN_RE = re.compile(
    r"^\s*\.plan\b.*(?:\n[ \t]*\d+:\([^)]*\)[ \t]*,?[ \t]*)*\n?",
    re.MULTILINE,
)
_QMARK_VAR_RE = re.compile(r"\?(?=[A-Za-z_])")
_OVERRIDABLE_RE = re.compile(r"\boverridable\b\s*")


def strip_plan(text: str) -> str:
    """Drop `.plan` scheduling hints — FlowLog ignores them."""
    return _PLAN_RE.sub("", text)


def strip_qmark_vars(text: str) -> str:
    """Drop DOOP's `?` variable-marker prefix.

    The convention is historical (from LogiQL); semantically `?x` and `x` are
    the same variable. FlowLog codegens to Rust idents and won't accept `?`,
    so we normalize here. Only strip the `?` when it directly precedes a
    letter or underscore so `?` inside other contexts (none in the corpus,
    but defensive) is left alone.
    """
    return _QMARK_VAR_RE.sub("", text)


def strip_overridable(text: str) -> str:
    """Remove the `overridable` annotation from `.decl` lines.

    Soufflé uses `overridable` to mark a predicate whose rules a subcomponent
    may replace via `.override`. Context-insensitive declares one
    (`CallGraphEdge`) but never overrides it; FlowLog doesn't implement the
    feature yet, so we just drop the annotation.
    """
    return _OVERRIDABLE_RE.sub("", text)


# The only two builtins FlowLog types as `bool` (engine:
# `BuiltinOperator::Contains | BuiltinOperator::Match => DataType::Bool`).
# Soufflé writes them as bare body constraints; FlowLog needs them equated.
_BOOL_BUILTINS = ("match", "contains")
_HSPACE = " \t"  # horizontal whitespace separating a `!`, keyword, `(` or `=`


def _ident_char(ch: str) -> bool:
    """True for characters that can be part of an identifier token."""
    return ch.isalnum() or ch == "_"


def _skip_protected(text: str, i: int) -> int | None:
    """If a string literal or comment starts at `text[i]`, return the index
    just past it; otherwise return None.

    "Protected" regions are spans the boolean-builtin rewrite must copy
    verbatim — a `match`/`contains` token inside them is not real code (e.g.
    the fact `CollectionMethodSig("boolean contains(java.lang.Object)", "")`).
    Strings honour `\\"` escapes; block comments run to `*/` (or EOF); line
    comments stop *before* the newline so the newline itself is preserved.
    """
    n = len(text)
    if text[i] == '"':
        j = i + 1
        while j < n:
            if text[j] == "\\":
                j += 2  # skip the escaped character
            elif text[j] == '"':
                return j + 1
            else:
                j += 1
        return n  # unterminated string — protect to EOF
    if text.startswith("//", i):
        nl = text.find("\n", i)
        return n if nl == -1 else nl
    if text.startswith("/*", i):
        end = text.find("*/", i + 2)
        return n if end == -1 else end + 2
    return None


def _scan_bool_call(text: str, i: int) -> int | None:
    """If a boolean-builtin call (`match(...)`/`contains(...)`) starts exactly
    at `text[i]`, return the index just past its closing `)`; otherwise None.

    The keyword must stand alone (word boundaries on both sides) and be
    followed — across optional horizontal whitespace — by a parenthesised
    argument list. The argument scan is protected-region aware, so a `)` inside
    a string or comment argument does not close the call early.
    """
    n = len(text)
    kw = next((k for k in _BOOL_BUILTINS if text.startswith(k, i)), None)
    if kw is None:
        return None
    before = text[i - 1] if i > 0 else ""
    j = i + len(kw)
    after = text[j] if j < n else ""
    if _ident_char(before) or _ident_char(after):
        return None  # keyword is part of a longer identifier

    while j < n and text[j] in _HSPACE:
        j += 1
    if j >= n or text[j] != "(":
        return None  # not a call

    depth = 0
    while j < n:
        skip = _skip_protected(text, j)
        if skip is not None:
            j = skip
            continue
        if text[j] == "(":
            depth += 1
        elif text[j] == ")":
            depth -= 1
            if depth == 0:
                return j + 1
        j += 1
    return None  # unbalanced parentheses — leave untouched


def _already_equated(text: str, end: int) -> bool:
    """True if the first non-space character at/after `end` is `=` — i.e. the
    call is already written as `f(...) = ...`, so re-running is idempotent."""
    j = end
    while j < len(text) and text[j] in _HSPACE:
        j += 1
    return j < len(text) and text[j] == "="


def _match_bool_constraint(text: str, i: int) -> tuple[str, int] | None:
    """At `text[i]`, match an optionally-negated bare boolean-builtin call and
    return `(equated_form, end_index)`, or None if there is none.

    A leading `!` (with optional whitespace before the keyword) flips the value
    the call is equated against:

        match(pat, s)     ->  match(pat, s) = True
        !contains(n, hay) ->  contains(n, hay) = False

    Calls already written as `f(...) = ...` return None so the pass is
    idempotent.
    """
    negated = text[i] == "!"
    call = i + 1 if negated else i
    while negated and call < len(text) and text[call] in _HSPACE:
        call += 1
    end = _scan_bool_call(text, call)
    if end is None or _already_equated(text, end):
        return None
    value = "False" if negated else "True"
    return f"{text[call:end]} = {value}", end


def rewrite_bool_builtins(text: str) -> str:
    """Equate Soufflé's boolean string functors to FlowLog's value-functor form.

    Soufflé writes `match(pat, s)` and `contains(needle, hay)` as bare boolean
    body constraints (and `!...` to negate them). FlowLog types both as value
    functors returning `bool`, so each bare use must become a comparison.
    Occurrences inside string literals or comments are copied verbatim, and
    already-equated calls are left alone (so the pass is idempotent).
    """
    out: list[str] = []
    i = 0
    n = len(text)
    while i < n:
        # Copy string literals and comments through untouched.
        skip = _skip_protected(text, i)
        if skip is not None:
            out.append(text[i:skip])
            i = skip
            continue

        # Rewrite a bare (optionally negated) boolean builtin to its equated form.
        match = _match_bool_constraint(text, i)
        if match is not None:
            equated, i = match
            out.append(equated)
            continue

        out.append(text[i])
        i += 1
    return "".join(out)


TRANSFORMS = [
    ("strip_plan", strip_plan),
    ("strip_qmark_vars", strip_qmark_vars),
    ("strip_overridable", strip_overridable),
    ("rewrite_bool_builtins", rewrite_bool_builtins),
]


def apply_transforms(text: str) -> str:
    for _name, fn in TRANSFORMS:
        text = fn(text)
    return text


def cpp_deps(root: Path, defines: list[str]) -> list[Path]:
    """Use `cpp -M` to list every .dl reached from root, honoring #ifdef."""
    cpp = os.environ.get("DOOP_CPP", "cpp")
    cmd = [cpp, "-M"] + [f"-D{d}" for d in defines] + [str(root)]
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    # Strip the Makefile target prefix ("foo.o:") and line continuations.
    body = out.split(":", 1)[1] if ":" in out else out
    body = body.replace("\\\n", " ")
    deps = []
    for tok in body.split():
        if not tok.endswith(".dl"):
            continue  # skip stdc-predef.h and the like
        deps.append(Path(tok).resolve())
    return deps


def walk_includes(roots: list[Path], defines: list[str]) -> set[Path]:
    seen: set[Path] = set()
    for r in roots:
        for f in cpp_deps(r, defines):
            seen.add(f)
    return seen


def mirror(files: set[Path]) -> int:
    """Transform each souffle-logic file and write it to flowlog-logic/."""
    count = 0
    for src in sorted(files):
        try:
            rel = src.relative_to(SOUFFLE_LOGIC)
        except ValueError:
            print(f"warn: file outside souffle-logic/, skipping: {src}", file=sys.stderr)
            continue
        dst = FLOWLOG_LOGIC / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(apply_transforms(src.read_text(errors="replace")))
        count += 1
    return count


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("analysis", help="analysis name under souffle-logic/analyses/")
    p.add_argument("--clean", action="store_true", help="remove flowlog-logic/ first")
    p.add_argument(
        "-D",
        dest="defines",
        action="append",
        default=[],
        metavar="MACRO[=VAL]",
        help="cpp macro define (repeatable) — lets optional addons in",
    )
    args = p.parse_args()

    entry = SOUFFLE_LOGIC / "analyses" / args.analysis / "analysis.dl"
    if not entry.is_file():
        sys.exit(f"flowlog-mirror: no such analysis: {entry}")

    # DOOP's SouffleAnalysis assembles facts.dl + basic.dl + analysis.dl in that
    # order (see src/main/groovy/.../SouffleAnalysis.groovy). Every analysis run
    # needs all three, so they are the roots for the include walk.
    roots = [
        SOUFFLE_LOGIC / "facts" / "facts.dl",
        SOUFFLE_LOGIC / "basic" / "basic.dl",
        entry,
    ]

    if args.clean and FLOWLOG_LOGIC.exists():
        shutil.rmtree(FLOWLOG_LOGIC)

    files = walk_includes(roots, args.defines)
    n = mirror(files)
    print(f"mirrored {n} files to {FLOWLOG_LOGIC.relative_to(REPO_ROOT)}/ for analysis '{args.analysis}'")


if __name__ == "__main__":
    main()

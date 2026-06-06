#!/usr/bin/env python3
"""Mirror the subset of souffle-logic/ needed for one analysis into flowlog-logic/.

Walks `#include` directives transitively from DOOP's standard assembly entry
points (facts/facts.dl, basic/basic.dl, analyses/<analysis>/analysis.dl) plus
any analysis-specific addons we wire in later. Each reached file is copied to
the matching path under flowlog-logic/, preserving the source-tree layout so
humans can diff the two trees side by side.

Per-file transforms (see `TRANSFORMS`, applied in order) normalize Soufflé
syntax FlowLog does not accept verbatim:

  * strip `.plan` scheduler hints, the `?` variable prefix, the `overridable`
    and `inline` annotations (FlowLog plans/inlines on its own);
  * normalize `.type`/`.number_type`/`.symbol_type` declarations;
  * equate the boolean string functors `match`/`contains`
    (`f(...)` → `f(...) = True`);
  * lower Soufflé body aggregates (`v = op [e] : {...}`) to FlowLog head
    aggregates (a fresh auxiliary IDB relation), so the engine stays clean and
    only ever evaluates native head aggregation;
  * hoist arithmetic out of positive-atom arguments (`R(idx - 1, x)`).

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



# ---------------------------------------------------------------------------
# Soufflé body-aggregate rewriting (`v = op [e] : body` -> FlowLog head
# aggregate via a fresh auxiliary IDB relation). Ported verbatim from the
# verified mirror; the clean engine keeps only FlowLog-native head
# aggregates, so this Soufflé->FlowLog lowering lives here in the adapter.
# ---------------------------------------------------------------------------
_INLINE_DECL_RE = re.compile(r"^([ \t]*\.decl\b[^\n]*\))[ \t]+inline\b", re.MULTILINE)

_TYPE_DECL_RE = re.compile(
    r"^(?P<indent>[ \t]*)\.(?P<kw>number_type|symbol_type|type)[ \t]+(?P<name>\w+)"
    r"(?:[ \t]*=[ \t]*(?P<rhs>.*?))?"
    r"(?P<tail>[ \t]*(?://[^\n]*)?)$",
    re.MULTILINE,
)

_NUMERIC_PRIMS = frozenset(
    "number unsigned float int8 int16 int32 int64 "
    "uint8 uint16 uint32 uint64 float32 float64".split()
)

def _is_symbol_union(rhs: str) -> bool:
    """True when every `|`-separated member of `rhs` is a symbol-rooted type
    (no numeric primitive, no record `[..]`, no empty/trailing-`|` member)."""
    members = [m.strip() for m in rhs.split("|")]
    return all(members) and not any(
        "[" in m or m in _NUMERIC_PRIMS for m in members
    )

_DECL_RE = re.compile(r"\.decl\s+(\w+)\s*\(([^)]*)\)")

_AGG_HEAD_RE = re.compile(
    r"(?P<res>\w+)\s*=\s*(?P<op>min|max|sum|count|mean)\b"
    r"(?P<target>[^:{]*?)\s*:\s*"
)

_AGG_OP_NATIVE = {
    "min": "min",
    "max": "max",
    "sum": "sum",
    "count": "count",
    "mean": "average",
}

def strip_inline(text: str) -> str:
    """Drop Soufflé's `inline` annotation on `.decl`s.

    `inline` asks Soufflé to inline a relation's rules at use sites — a
    performance hint with no bearing on the computed relation. FlowLog plans
    its own evaluation, so the annotation is dropped (scoped to `.decl` lines).
    """
    return _INLINE_DECL_RE.sub(r"\1", text)

def normalize_type_decls(text: str) -> str:
    """Lower Soufflé type-declaration forms FlowLog's grammar rejects onto its
    single-`type_ref` `.type` alias form, faithfully for DOOP's string world:

        .number_type X          ->  .type X = number
        .symbol_type X          ->  .type X = symbol
        .type X                 ->  .type X = symbol   (bare uninterpreted type)
        .type X = A | B | ...   ->  .type X = symbol   (union of symbol types)

    A bare `.type X` declares an uninterpreted primitive; DOOP's unions only
    ever combine symbol-rooted reference types (Type, Value, MethodInvocation,
    UniqueContext, ...). Soufflé erases both to the underlying symbol table at
    run time, so `= symbol` is the execution-faithful representation. Aliases,
    subtypes (`<:`), and record declarations (`.type X = [ ... ]`) are left
    untouched — records have no native FlowLog form, so they surface as a clear
    error rather than being silently mis-lowered.
    """
    return _TYPE_DECL_RE.sub(_lower_type_decl, text)

def _lower_type_decl(m: re.Match) -> str:
    """Map one matched type declaration to its `= <primitive>` form, or return
    it unchanged when no faithful primitive lowering applies."""
    rhs = m["rhs"]
    if m["kw"] == "number_type":
        target = "number"
    elif m["kw"] == "symbol_type" or rhs is None:        # symbol primitive / bare
        target = "symbol"
    elif "|" in rhs and _is_symbol_union(rhs):           # union of symbol types
        target = "symbol"
    else:                                                # alias / record — keep
        return m[0]
    return f"{m['indent']}.type {m['name']} = {target}{m['tail']}"

_IDENT_RE = re.compile(r"[A-Za-z_]\w*")

_ATOM_RE = re.compile(r"([A-Za-z_][\w.]*)\s*\((.*)\)\s*$", re.DOTALL)

_DIRECTIVE_LINE_RE = re.compile(
    r"^\s*\.(decl|type|input|output|comp|init|override|plan|pragma|functor"
    r"|number_type|symbol_type)\b"
)

class AggContext:
    """Carries cross-file state the aggregate pass needs.

    `decls` maps a relation name to its ordered column types; `counter` is a
    shared, monotonically increasing source of unique auxiliary-relation names.
    """

    def __init__(self, decls: dict[str, list[str]]) -> None:
        self.decls = decls
        self.counter = 0

    def fresh(self, op: str) -> str:
        self.counter += 1
        return f"_FlowLogAgg_{op}_{self.counter}"

def collect_decls(texts: list[str]) -> dict[str, list[str]]:
    """Index every `.decl` as relation-name -> [column type, ...]."""
    index: dict[str, list[str]] = {}
    for text in texts:
        for m in _DECL_RE.finditer(text):
            name, params = m.group(1), m.group(2).strip()
            cols: list[str] = []
            if params:
                for param in params.split(","):
                    # `col : Type` — keep the type half.
                    cols.append(param.split(":", 1)[-1].strip() if ":" in param else "symbol")
            index[name] = cols
    return index

def _mask(text: str) -> str:
    """Return a same-length copy with comments, string bodies and `#` lines
    blanked to spaces (newlines preserved).

    Structural scanning runs on the mask so commas/braces/dots inside strings
    or comments never confuse clause boundaries; slices use the original text.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out[i] = '"'
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\" and i + 1 < n:
                    out[i] = " "
                    out[i + 1] = " "
                    i += 2
                    continue
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:  # consume the closing quote so the next char isn't
                i += 1  # mis-read as a new opening quote (which would blank
            continue   # the real code sitting between two string literals)
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            while i < n and not (text[i] == "*" and i + 1 < n and text[i + 1] == "/"):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i < n:
                out[i] = " "
                if i + 1 < n:
                    out[i + 1] = " "
                i += 2
            continue
        if c == "#":  # preprocessor line (with backslash continuation)
            while i < n:
                if text[i] == "\n" and not (i > 0 and text[i - 1] == "\\"):
                    break
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            continue
        i += 1
    return "".join(out)

def _match_brace(mask: str, open_idx: int) -> int:
    """Index of the `}` matching the `{` at `open_idx` (or -1)."""
    depth = 0
    for i in range(open_idx, len(mask)):
        if mask[i] == "{":
            depth += 1
        elif mask[i] == "}":
            depth -= 1
            if depth == 0:
                return i
    return -1

def _match_paren(mask: str, open_idx: int) -> int:
    """Index of the `)` matching the `(` at `open_idx` (or -1). Runs on the
    mask so parens inside string literals/comments are already blanked away."""
    depth = 0
    for i in range(open_idx, len(mask)):
        if mask[i] == "(":
            depth += 1
        elif mask[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return -1

def _is_clause_terminator(mask: str, i: int) -> bool:
    """A `.` at `i` ends a rule/fact: at paren/brace depth 0 and followed only
    by horizontal space before a newline or EOF (excludes `.kw`, `a.b`, floats)."""
    j = i + 1
    while j < len(mask) and mask[j] in " \t\r":
        j += 1
    return j >= len(mask) or mask[j] == "\n"

def _scan_head_start(mask: str, impl_pos: int) -> int:
    """Start index of the head for the clause whose `:-` is at `impl_pos`.

    Walks back to the nearest boundary: a previous rule terminator, a `{`/`}`
    (component scope), or start of file.
    """
    paren = 0
    i = impl_pos - 1
    while i >= 0:
        c = mask[i]
        if c in ")]":
            paren += 1
        elif c in "([":
            paren -= 1
        elif paren == 0:
            if c in "{}":
                return i + 1
            if c == "." and _is_clause_terminator(mask, i):
                return i + 1
        i -= 1
    return 0

def _split_top_level(mask: str, text: str, start: int, end: int) -> list[tuple[int, int]]:
    """Spans of comma-separated items in text[start:end], respecting () [] {}."""
    spans: list[tuple[int, int]] = []
    depth = 0
    seg_start = start
    for i in range(start, end):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            spans.append((seg_start, i))
            seg_start = i + 1
    spans.append((seg_start, end))
    return spans

def _atom_args(text: str) -> tuple[str, list[str]] | None:
    """Split an atom `Name(a, b, c)` into (base name, [arg, ...]).

    The base name drops any component qualifier (`comp.Rel` -> `Rel`) so it can
    be looked up in the decl index.
    """
    m = _ATOM_RE.match(text.strip())
    if not m:
        return None
    name = m.group(1).rsplit(".", 1)[-1]
    inner = m.group(2)
    # Reuse the top-level splitter on the argument list.
    mask = _mask(inner)
    args = [inner[s:e].strip() for s, e in _split_top_level(mask, inner, 0, len(inner))]
    args = [a for a in args if a != ""]
    return name, args

def _vars(text: str) -> set[str]:
    """Identifier-like variables, dropping the anonymous `_`."""
    return {v for v in _IDENT_RE.findall(text) if v != "_"}

def _lookup_type(var: str, body_atoms: list[tuple[str, list[str]]],
                 decls: dict[str, list[str]]) -> str | None:
    """Type of `var`, recovered from the first body atom that binds it."""
    for name, args in body_atoms:
        for pos, arg in enumerate(args):
            if arg == var:
                cols = decls.get(name)
                if cols and pos < len(cols):
                    return cols[pos]
    return None

def _braceless_body_end(mask: str, start: int) -> int:
    """End index of a brace-less aggregate body beginning at `start`.

    A brace-less Soufflé aggregate body is a single literal, so it runs to the
    next top-level `,` (separating it from a following body literal) or the
    clause-terminating `.`, whichever comes first.
    """
    depth = 0
    for i in range(start, len(mask)):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c == ",":
            return i
        elif depth == 0 and c == "." and _is_clause_terminator(mask, i):
            return i
    return len(mask)

_SIMPLE_ATOM_ARG_RE = re.compile(
    r'^(?:[A-Za-z_]\w*|_|[+-]?\d+|[+-]?\d+\.\d+|"(?:[^"\\]|\\.)*")$'
)

def _clause_end(mask: str, start: int) -> int:
    """Index of the `.` terminating the clause whose body begins at `start`."""
    depth = 0
    for i in range(start, len(mask)):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c == "." and _is_clause_terminator(mask, i):
            return i
    return len(mask)

def _split_body_predicates(mask: str, start: int, end: int) -> list[tuple[int, int]]:
    """Top-level predicate spans in a body, split on `,` and `;` (the body
    conjunction / disjunction separators), respecting `()` `[]` `{}`."""
    spans: list[tuple[int, int]] = []
    depth = 0
    seg_start = start
    for i in range(start, end):
        c = mask[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif depth == 0 and c in ",;":
            spans.append((seg_start, i))
            seg_start = i + 1
    spans.append((seg_start, end))
    return spans

def _pure_atom_span(mask: str, text: str, s: int, e: int):
    """If `text[s:e]` is a single, optionally `!`-negated, atom `Name(...)`
    and nothing else, return `(negated, name_start, open_idx, close_idx)`;
    otherwise `None`. A trailing comparison (`ord(x) = y`) disqualifies it."""
    i = s
    while i < e and text[i] in " \t\r\n":
        i += 1
    negated = False
    if i < e and text[i] == "!":
        negated = True
        i += 1
        while i < e and text[i] in " \t\r\n":
            i += 1
    name_start = i
    while i < e and (text[i].isalnum() or text[i] in "_."):
        i += 1
    if i == name_start:
        return None
    while i < e and text[i] in " \t\r\n":
        i += 1
    if i >= e or text[i] != "(":
        return None
    open_idx = i
    close_idx = _match_paren(mask, open_idx)
    if close_idx < 0 or close_idx >= e:
        return None
    j = close_idx + 1
    while j < e and text[j] in " \t\r\n":
        j += 1
    if j != e:
        return None
    return negated, name_start, open_idx, close_idx

def rewrite_atom_arith_args(text: str) -> str:
    """Hoist compound atom arguments into equality bindings.

    Soufflé lets a body atom carry arbitrary expressions as arguments
    (`FormalParam(idx - 1, m, f)`); a FlowLog atom takes only a variable,
    constant or `_`. For every body atom we replace each non-trivial argument
    with a fresh variable and prepend `freshVar = <expr>` to the body — the
    exact desugaring of the Soufflé form. Rule heads are left untouched;
    FlowLog already permits arithmetic there.
    """
    mask = _mask(text)
    edits: list[tuple[int, int, str]] = []
    counter = 0
    pos = 0
    while True:
        arrow = mask.find(":-", pos)
        if arrow < 0:
            break
        body_start = arrow + 2
        body_end = _clause_end(mask, body_start)
        for s, seg_end in _split_body_predicates(mask, body_start, body_end):
            span = _pure_atom_span(mask, text, s, seg_end)
            if span is None:
                continue
            negated, name_start, open_idx, close_idx = span
            inner = text[open_idx + 1:close_idx]
            inner_mask = mask[open_idx + 1:close_idx]
            bindings: list[str] = []
            new_args: list[str] = []
            changed = False
            for a0, a1 in _split_top_level(inner_mask, inner, 0, len(inner)):
                arg = inner[a0:a1].strip()
                if arg == "":
                    continue
                if _SIMPLE_ATOM_ARG_RE.match(arg):
                    new_args.append(arg)
                else:
                    fresh = f"_atomArg{counter}"
                    counter += 1
                    bindings.append(f"{fresh} = {arg}")
                    new_args.append(fresh)
                    changed = True
            if not changed:
                continue
            prefix = "!" if negated else ""
            name = text[name_start:open_idx].strip()
            atom = f"{prefix}{name}({', '.join(new_args)})"
            edits.append((s, seg_end, " " + ", ".join(bindings + [atom])))
        pos = body_end
    if not edits:
        return text
    out: list[str] = []
    last = 0
    for s, e, repl in edits:
        out.append(text[last:s])
        out.append(repl)
        last = e
    out.append(text[last:])
    return "".join(out)

def _locate_agg_clause(
    mask: str, text: str, agg_start: int, body_pos: int
) -> tuple[int, int, str, int, int] | None:
    """Locate the clause surrounding a body aggregate.

    `agg_start` is where the `res = op ... :` match starts and `body_pos` is the
    first character after the `:`. Returns
    `(impl_pos, head_start, body_text, replace_end, dot_pos)` where the rule head
    is `text[head_start:impl_pos]`, the aggregate literal spans
    `[agg_start, replace_end)`, and `dot_pos` is the clause-terminating `.` (the
    end of the body's variable scope). Returns None when the `:-` or a braced
    body cannot be resolved.
    """
    impl_pos = mask.rfind(":-", 0, agg_start)
    if impl_pos < 0:
        return None
    head_start = _scan_head_start(mask, impl_pos)

    # Braced `{ ... }` body vs. brace-less single-literal body.
    if body_pos < len(mask) and mask[body_pos] == "{":
        brace_close = _match_brace(mask, body_pos)
        if brace_close < 0:
            return None
        body_text = text[body_pos + 1:brace_close].strip()
        replace_end = brace_close + 1
    else:
        replace_end = _braceless_body_end(mask, body_pos)
        body_text = text[body_pos:replace_end].strip()

    # The clause terminator `.` (end of the body's variable scope).
    dot_pos = replace_end
    while dot_pos < len(mask) and not (
        mask[dot_pos] == "." and _is_clause_terminator(mask, dot_pos)
    ):
        dot_pos += 1
    return impl_pos, head_start, body_text, replace_end, dot_pos

def rewrite_aggregates(text: str, ctx: AggContext) -> str:
    """Lower every Soufflé body aggregate to a FlowLog head aggregate."""
    mask = _mask(text)
    # Right-to-left so earlier edits don't shift later match offsets.
    matches = list(_AGG_HEAD_RE.finditer(mask))
    for m in reversed(matches):
        op = m.group("op")
        res = m.group("res")
        target = m.group("target").strip()

        located = _locate_agg_clause(mask, text, m.start(), m.end())
        if located is None:
            continue
        impl_pos, head_start, body_text, replace_end, dot_pos = located

        # Variables bound in the enclosing clause (head + the other body
        # literals), with directive/blank lines in the head region dropped.
        head_lines = [
            ln for ln in text[head_start:impl_pos].splitlines()
            if not _DIRECTIVE_LINE_RE.match(ln) and ln.strip()
        ]
        outer_vars = _vars(" ".join(head_lines))
        for s, e in _split_top_level(mask, text, impl_pos + 2, dot_pos):
            if s <= m.start() < e:  # skip the aggregate literal itself
                continue
            outer_vars |= _vars(text[s:e])

        # Parse the aggregate body's atoms for grouping + typing.
        body_atoms: list[tuple[str, list[str]]] = []
        for s, e in _split_top_level(_mask(body_text), body_text, 0, len(body_text)):
            parsed = _atom_args(body_text[s:e])
            if parsed:
                body_atoms.append(parsed)

        target_vars = _vars(target)
        # Group-by = body vars that are injected from the outer scope (and are
        # not the aggregated value), in first-appearance order.
        seen: list[str] = []
        for _name, args in body_atoms:
            for a in args:
                if a != "_" and a not in seen:
                    seen.append(a)
        group_vars = [v for v in seen if v in outer_vars and v not in target_vars]

        # Synthesize the auxiliary relation's column types.
        col_types: list[str] = []
        ok = True
        for g in group_vars:
            t = _lookup_type(g, body_atoms, ctx.decls)
            if t is None:
                ok = False
                break
            col_types.append(t)
        if not ok:
            print(f"warn: aggregate '{res} = {op} {target}': could not type group var; "
                  "left unchanged", file=sys.stderr)
            continue

        if op == "count":
            res_type = "number"
            # Soufflé `count` counts witness tuples — the body bindings that vary
            # within a group. FlowLog `count(v)` counts DISTINCT v, so the
            # argument must be a witness variable (one that varies per tuple),
            # never a group-by var: a group-by var is constant within its group
            # and would make every group count to 1. Prefer a named non-group
            # witness; otherwise name the first anonymous `_` slot and count it.
            witness = next((v for v in seen if v != "_" and v not in group_vars), None)
            if witness:
                agg_arg, agg_body = witness, body_text
            else:
                # Witness sits in an anonymous `_` slot: name the first standalone
                # `_` token (not an underscore inside an identifier) and count it.
                agg_arg = "_agg_one"
                agg_body = re.sub(r"(?<!\w)_(?!\w)", "_agg_one", body_text, count=1)
        else:
            # min/max/sum over a bare numeric var inherit that var's type;
            # over an expression (e.g. `ord(x)`) the result is a number, as
            # Soufflé's numeric aggregates always yield numbers.
            if re.fullmatch(r"\w+", target):
                res_type = _lookup_type(target, body_atoms, ctx.decls) or "number"
            else:
                res_type = "number"
            agg_arg = target
            agg_body = body_text
        col_types.append(res_type)

        rel = ctx.fresh(op)
        decl_cols = ", ".join(f"g{i}:{t}" for i, t in enumerate(col_types[:-1]))
        decl_cols = (decl_cols + ", " if decl_cols else "") + f"r:{col_types[-1]}"
        native = _AGG_OP_NATIVE[op]
        head_cols = ", ".join(group_vars + [f"{native}({agg_arg})"])
        atom_cols = ", ".join(group_vars + [res])

        aux = (
            f".decl {rel}({decl_cols})\n"
            f"{rel}({head_cols}) :-\n  {agg_body}.\n"
        )
        replacement = f"{rel}({atom_cols})"

        # Splice: insert the auxiliary rule before the clause head, and replace
        # the aggregate literal in place.
        text = (
            text[:head_start]
            + "\n" + aux
            + text[head_start:m.start()]
            + replacement
            + text[replace_end:]
        )
        mask = _mask(text)
    return text

_CTX_TRANSFORMS = {"rewrite_aggregates"}


TRANSFORMS = [
    ("strip_plan", strip_plan),
    ("strip_qmark_vars", strip_qmark_vars),
    ("strip_overridable", strip_overridable),
    ("strip_inline", strip_inline),
    ("normalize_type_decls", normalize_type_decls),
    ("rewrite_bool_builtins", rewrite_bool_builtins),
    ("rewrite_aggregates", rewrite_aggregates),
    ("rewrite_atom_arith_args", rewrite_atom_arith_args),
]


def apply_transforms(text: str, ctx: AggContext) -> str:
    for name, fn in TRANSFORMS:
        text = fn(text, ctx) if name in _CTX_TRANSFORMS else fn(text)
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
    sources = {src: src.read_text(errors="replace") for src in sorted(files)}
    # Aggregate rewriting needs every relation's column types, so collect all
    # .decl signatures across the whole mirrored set before transforming.
    ctx = AggContext(collect_decls(list(sources.values())))
    count = 0
    for src, text in sources.items():
        try:
            rel = src.relative_to(SOUFFLE_LOGIC)
        except ValueError:
            print(f"warn: file outside souffle-logic/, skipping: {src}", file=sys.stderr)
            continue
        dst = FLOWLOG_LOGIC / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        dst.write_text(apply_transforms(text, ctx))
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

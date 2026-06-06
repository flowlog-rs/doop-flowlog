#!/usr/bin/env python3
"""Mirror the subset of souffle-logic/ needed for one analysis into flowlog-logic/.

Walks `#include` directives transitively from DOOP's standard assembly entry
points (facts/facts.dl, basic/basic.dl, analyses/<analysis>/analysis.dl) plus
any analysis-specific addons we wire in later. Each reached file is copied to
the matching path under flowlog-logic/, preserving the source-tree layout so
humans can diff the two trees side by side.

This first cut is identity-copy: no transforms applied yet. The
FlowLog-specific passes (.comp/.init flatten, .plan strip, range rewrite,
as()/<: erase, inline/overridable strip) layer in here as we build them.

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


_PLAN_RE = re.compile(
    # `.plan` is a Soufflé planner hint that may span multiple lines:
    #
    #   .plan 1:(2,1,3,4,5,6,7),
    #          2:(3,1,2,4,5,6,7),
    #          3:(4,1,2,3,5,6,7)
    #
    # The keyword line is followed by zero or more indented
    # `<digit>:( ... )` continuation entries. We need to consume all of
    # them — leaving an orphan continuation behind produces a syntax
    # error in the consumer.
    r"^\s*\.plan\b[^\n]*\n"
    r"(?:[ \t]+\d+\s*:\s*\([^)]*\)\s*,?\s*\n)*",
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


TRANSFORMS = [
    ("strip_plan", strip_plan),
    ("strip_qmark_vars", strip_qmark_vars),
    ("strip_overridable", strip_overridable),
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

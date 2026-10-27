#!/usr/bin/env python3
"""gate-hard-checks-lint.py — ga-ymc1052: the doc-rules lint of gate-hard-checks.sh step 2c, run without letting it read this host's disk for an @import.

  gate-hard-checks-lint.py <doc-rules-lint.py> <tree-root> <the lint's own arguments...>

WHY. The lint counts a named doc's @imports into its 200-line cap by following each one with os.stat and open (resolve_import). An
absolute path, a ~ path and a relative path that climbs out of the extracted tree all land on THIS host's disk, not on the branch. What the
lint then prints is what the submitter reads back from the marker (the verdict label, the refusal comment), and the submitter can be a
session that cannot read this disk (the Hetzner dog): "effective 259 lines > 200 (own 9 + imported 250 from big.txt)", the names that
host file imports itself, "cannot stat @import target (Permission denied)" with the resolved path, exit 2 for a file the guard may not
read. A CLAUDE.md that imports @/some/path was an oracle for which files exist on the guard's host, how long they are and what they
import. This loads the lint (the copy already merged in the city, never the branch's) as a module, makes its resolve_import answer
"not a file" for every import that points outside <tree-root> BEFORE any stat, and runs the lint's own main(): the same checks, the same
output lines, the same exit codes. An import that stays inside the tree is resolved by the lint itself.

What the lint no longer counts is only what the branch cannot vouch for: an import line that points outside the tree counts as one line of
text, like a dangling import. gate-hard-checks.sh does not let such a line pass for clean (it is a special there, so a clean lint is
unmeasured), and a real finding of the doc's own lines stays a finding.

Nothing of the branch is executed: the lint is loaded from the path the checker gives, the branch is only data under <tree-root>. If the lint
cannot be loaded, or no longer has resolve_import / main, this exits 2 and the checker reads that as unmeasured: the lint is never run
unpatched. Python 3.9 compatible, like the lint.
"""
from __future__ import annotations

import importlib.util
import os
import sys
from typing import Callable, List, Optional


def host_blind(real: Callable[[str, str], Optional[str]], root: str) -> Callable[[str, str], Optional[str]]:
    """resolve_import that answers None (not a file, the lint counts the line as text) for any import that points outside <root>."""

    def resolve_import(tok: str, host_dir: str) -> Optional[str]:
        # An absolute or ~ import is a path on this host, never in the branch.
        if tok.startswith("~") or os.path.isabs(tok):
            return None
        # A relative one is placed on the path first, without touching the disk: one that climbs out of the tree would be stat'ed against the
        # scratch dir's parents, which is this host again. Inside the tree the lint resolves it itself, through the tree's own directories.
        cand = os.path.normpath(os.path.join(host_dir, tok))
        if cand != root and not cand.startswith(root + os.sep):
            return None
        return real(tok, host_dir)

    return resolve_import


def main(argv: List[str]) -> int:
    if len(argv) < 4:
        print("usage: gate-hard-checks-lint.py <doc-rules-lint.py> <tree-root> <lint arguments...>", file=sys.stderr)
        return 2
    try:
        sys.dont_write_bytecode = True   # the merged tools dir must not grow a __pycache__ from the guard
        # vazio/falhou → no spec (no such file, not python) or an error while the lint loads: the exception ends the run as exit 2, never a lint run
        spec = importlib.util.spec_from_file_location("doc_rules_lint", argv[1])
        lint = importlib.util.module_from_spec(spec)   # type: ignore[arg-type]
        spec.loader.exec_module(lint)                  # type: ignore[union-attr]
        # vazio/falhou → a lint without resolve_import or main is not the one this was written for: AttributeError, exit 2, never run unpatched
        lint.resolve_import = host_blind(lint.resolve_import, os.path.realpath(argv[2]))
        run = lint.main
    except Exception as exc:   # unknown is not clean: any failure ends the run and the checker reads exit 2 as unmeasured
        print("gate-hard-checks-lint: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 2
    return run(argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv))

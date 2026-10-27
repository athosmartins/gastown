#!/usr/bin/env python3
"""gate-hard-checks-imports.py — ga-vywjzsp: the files a changed CLAUDE.md / CLAUDE.local.md / AGENTS.md reaches through @imports.

  gate-hard-checks-imports.py <doc-rules-lint.py> <git-top> <tip-sha> <roots-file>

WHY. gate-hard-checks.sh step 2c hands doc-rules-lint.py an extracted copy of the tip, and the lint counts a named doc's @imports into
its 200-line cap by following each one to ANY regular file (resolve_import only tests S_ISREG), whatever the suffix. A copy that holds
only the .md files makes an imported .txt vanish, the count comes out short, and the checker would answer "lint-limpo" for a doc the lint
refuses on the whole tree (gate_run ga-h3scrqt). This walks the imports the way the lint does over the tip's git objects, using the
lint's OWN tokenizer (so a code span, a prose @word or an e-mail is judged exactly as the lint judges it), and says which files to extract.

OUTPUT (stdout): the first line `IMPORTS-OK special=<n> files=<m>`, then the <m> tree paths to extract, one per line. Anything else, or a
non-zero exit, means the walk did not finish: the caller reads that as unmeasured, never as an empty closure. `special` counts the reaches
this cannot show as data: a symlink or a submodule where an import points or that sits on its way, a `..` that follows a descent (the lint
stats the path through the scratch tree's own directories, and the tip may have one there that the scratch tree does not), a path that climbs
above the tree (the lint resolves it against the scratch dir, not the repo), and every absolute or ~ import (the lint would read the host's
file, not the branch's). That last one counts whether or not this host has such a file: the disk is never asked, because an answer that
changes the output would tell a builder who cannot read this disk what is on it (ga-ymc1052; gate-hard-checks-lint.py keeps the lint from
asking either).

Nothing of the branch is executed: the lint is the copy already merged, the branch is read as git objects. Python 3.9 compatible, like the lint.
"""
from __future__ import annotations

import importlib.util
import posixpath
import subprocess
import sys
from typing import Dict, List, Optional, Set, Tuple

REGULAR = ("100644", "100755")
MAX_FILES = 200   # a closure this size is not a CLAUDE.md anyone reads: unmeasured beats a runaway walk


def git(top: str, *args: str) -> bytes:
    # falhou → CalledProcessError, not caught here: main() turns every exception into exit 2 (unmeasured), never into an empty answer
    return subprocess.run(["git", "-C", top] + list(args), check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout


def load_lint(path: str):
    # falhou/ilegível → spec None or an import error: the exception reaches main(), exit 2. The lint guards its main() by __name__, so importing runs nothing.
    sys.dont_write_bytecode = True   # the merged tools dir must not grow a __pycache__ from the guard
    spec = importlib.util.spec_from_file_location("doc_rules_lint", path)
    mod = importlib.util.module_from_spec(spec)   # type: ignore[arg-type]
    spec.loader.exec_module(mod)                  # type: ignore[union-attr]
    return mod


def tree(top: str, tip: str) -> Dict[str, Tuple[str, str]]:
    # vazio → {} (a tip with no files: nothing is reachable); falhou → git() raises, exit 2
    out: Dict[str, Tuple[str, str]] = {}
    for rec in git(top, "ls-tree", "-r", "-z", tip).split(b"\0"):
        if not rec:
            continue
        meta, path = rec.split(b"\t", 1)
        mode, _kind, obj = meta.decode("ascii").split(" ")
        out[path.decode("utf-8", "surrogateescape")] = (mode, obj)
    return out


def reach(tok: str, host: str, entries: Dict[str, Tuple[str, str]]) -> Tuple[Optional[str], int]:
    """(the tip path the lint would read for this import, or None; 1 when the answer on the whole tree may differ from the scratch tree's)."""
    if tok.startswith("~") or posixpath.isabs(tok):
        # The disk is not asked (ga-ymc1052). A special that depended on whether the host HAS the file would give a builder who cannot read
        # this disk an oracle for it: the verdict label, the reason and a stat error's text would all change with the answer. Every such
        # token is the same special, found or not, and a clean verdict that carries one is unmeasured either way.
        return None, 1
    # The lint stats the path through the REAL directories of the scratch tree, which holds only the extracted files, so the walk goes one
    # component at a time like the filesystem does (a text normpath would not): a `..` after a descent passes through a directory that exists
    # in the tip but maybe not there, and a link on the way leads somewhere the tip listing does not show. Both are odd = 1: unmeasured.
    stack = [c for c in posixpath.dirname(host).split("/") if c]
    odd, descended = 0, False
    for seg in tok.split("/"):
        if seg in ("", "."):
            continue
        if seg == "..":
            if not stack:
                return None, 1   # climbs above the tree: the lint resolves it against the scratch dir, not the repo
            odd = odd or int(descended)
            stack.pop()
            continue
        descended = True
        stack.append(seg)
        # vazio → not an entry: a plain directory (or nothing) on the way, no oddity; a link or a submodule on the way (or as the target) is odd
        step = entries.get("/".join(stack))
        if step is not None and step[0] not in REGULAR:
            odd = 1
    cand = "/".join(stack)
    if "\n" in cand:
        return None, 1
    # vazio → (None, odd): the tip has no such file, so it is not an import; a link or a submodule there cannot be extracted: (None, 1)
    hit = entries.get(cand)
    if hit is None:
        return None, odd
    return (cand, odd) if hit[0] in REGULAR else (None, 1)


def closure(lint, top: str, entries: Dict[str, Tuple[str, str]], roots: List[str]) -> Tuple[Set[str], int]:
    need: Set[str] = set()
    seen: Set[str] = set()
    special = 0
    # vazio → a root that is not a regular tip entry (a link) is left to the caller's extract, which refuses it
    queue = [r for r in roots if entries.get(r, ("", ""))[0] in REGULAR]
    while queue:
        cur = queue.pop()
        if cur in seen:
            continue
        seen.add(cur)
        if len(seen) > MAX_FILES:
            raise RuntimeError("more than %d files reached through @imports" % MAX_FILES)
        # falhou → git() raises, exit 2; the file is read from the object id, so no path is ever resolved against the repository
        text = git(top, "cat-file", "blob", entries[cur][1]).decode("utf-8", "surrogateescape")
        doc = lint.Doc(lint.split_lines(text)[0])
        for i, line in enumerate(doc.lines):
            if doc.kinds[i] not in ("text", "heading"):
                continue
            for tok in lint.import_tokens(line)[0]:
                target, odd = reach(tok, cur, entries)
                special += odd
                if target is not None:
                    need.add(target)
                    queue.append(target)
    return need, special


def main(argv: List[str]) -> int:
    if len(argv) != 5:
        print("usage: gate-hard-checks-imports.py <doc-rules-lint.py> <git-top> <tip-sha> <roots-file>", file=sys.stderr)
        return 2
    try:
        lint = load_lint(argv[1])
        # vazio → no roots, an empty closure (the caller only asks when a named doc changed); falhou/ilegível → open() raises, exit 2
        with open(argv[4], "rb") as fh:
            roots = [r.decode("utf-8", "surrogateescape") for r in fh.read().split(b"\n") if r]
        need, special = closure(lint, argv[2], tree(argv[2], argv[3]), roots)
    except Exception as exc:   # unknown is not empty: any failure ends the walk and the caller reads it as unmeasured
        print("gate-hard-checks-imports: %s: %s" % (type(exc).__name__, exc), file=sys.stderr)
        return 2
    out = sys.stdout.buffer
    out.write(("IMPORTS-OK special=%d files=%d\n" % (special, len(need))).encode("ascii"))
    for p in sorted(need):
        out.write(p.encode("utf-8", "surrogateescape") + b"\n")
    out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

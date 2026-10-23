#!/usr/bin/env python3
"""plist-comment-lint.py — fail when a plist source cannot be parsed by Python's plist reader (ga-taa25c).

WHY: XML forbids a double hyphen inside a comment. `plutil -lint` and launchd accept it, so the job
loads and nothing looks wrong, but plistlib (expat) rejects the whole file. The WA pre-push lint
(gen_daemon_deps.plist_daemon_labels) then drops that plist and warns "varredura degradada" on every
push: it goes blind to that daemon. Four plists carried it unnoticed because every other check said OK.

The verdict is plistlib.loads, the SAME reader the WA lint uses, so this cannot disagree with it.
The comment scan only LOCATES the offending text, so the message says which line to reword.

Usage:  plist-comment-lint.py [FILE ...]
        no FILE: every plist git tracks under the city this script lives in
        (PLIST_LINT_ROOT=<dir> points the discovery somewhere else; the selftest uses it).
Exit:   0  every plist parses
        1  at least one does not (named on stdout, with the line when the cause is a comment)
        2  could not decide: git failed, no plist found, or a file could not be read
           (never reported as clean; a finding in the same run still wins and exits 1)
"""
from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys

COMMENT = re.compile(r"<!--(.*?)-->", re.S)


def comment_hits(text):
    """[(line, snippet)] for every comment line holding a double hyphen, or a comment that ends in '-'."""
    hits = []
    for m in COMMENT.finditer(text):
        body = m.group(1)
        first = text.count("\n", 0, m.start()) + 1
        for i, line in enumerate(body.split("\n")):
            if "--" in line:
                hits.append((first + i, line.strip()))
        if body.endswith("-"):
            # '--->' closes the comment with a double hyphen too
            hits.append((first + body.count("\n"), "comment ends in '-', so it closes with '--->'"))
    return hits


def tracked_plists(root):
    """(files, why). files is None when git could not answer; [] when git answered with nothing."""
    # vazio → git respondeu sem nenhum plist: devolve [] e o main recusa (rc 2), uma cidade com dezenas de plists não está "limpa";
    # falhou/ilegível → git não rodou ou saiu != 0: devolve None e o main sai com rc 2 — nunca vira "nada a checar"
    try:
        r = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", "*.plist"],
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
    except (OSError, subprocess.SubprocessError) as e:
        return None, f"git did not run: {e}"
    if r.returncode != 0:
        return None, f"git ls-files rc={r.returncode}: {r.stderr.decode('utf-8', 'replace').strip()[:200]}"
    names = [n for n in r.stdout.decode("utf-8", "surrogateescape").split("\0") if n]
    return [os.path.join(root, n) for n in names], ""


def main(argv):
    root = os.environ.get("PLIST_LINT_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    files = argv[1:]
    if not files:
        found, why = tracked_plists(root)
        if found is None:
            print(f"plist-comment-lint: cannot list the plists: {why}", file=sys.stderr)
            return 2
        if not found:
            print(f"plist-comment-lint: no plist tracked under {root}; refusing to call that clean", file=sys.stderr)
            return 2
        files = found

    failed, undecided = [], []
    for path in files:
        # vazio → arquivo de 0 bytes chega ao plistlib e reprova (não é "limpo");
        # falhou/ilegível → entra em `undecided` (rc 2), nunca conta como ok
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError as e:
            undecided.append((path, str(e)))
            continue
        try:
            plistlib.loads(data)
        except Exception as e:  # ExpatError, InvalidFileException, ValueError: all mean "this reader refuses it"
            failed.append((path, str(e), comment_hits(data.decode("utf-8", "replace"))))

    def shown(p):
        return os.path.relpath(p, root) if p.startswith(root + os.sep) else p

    for path, err, hits in failed:
        print(f"FAIL {shown(path)}: {err}")
        for line, snippet in hits:
            print(f"  line {line}: double hyphen inside an XML comment: {snippet}")
    for path, err in undecided:
        print(f"UNREADABLE {shown(path)}: {err}", file=sys.stderr)

    print(f"plist-comment-lint: {len(files)} file(s), {len(failed)} fail, {len(undecided)} unreadable")
    if failed:
        print("XML forbids two hyphens inside a comment (launchd accepts it, Python does not): "
              "reword the flag as words, e.g. 'the parent option' instead of the flag itself. See ga-taa25c.")
        return 1
    return 2 if undecided else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))

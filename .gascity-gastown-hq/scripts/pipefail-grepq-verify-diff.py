#!/usr/bin/env python3
"""pipefail-grepq-verify-diff.py — independent check of a pipefail-grepq-codemod.py rewrite (ga-5bxuam).

It does NOT share the codemod's lexer: it only looks at the changed line pairs of `git diff BASE_REF`,
so a bug in the codemod cannot approve its own output.

For every changed line pair (base -> head):
  1. count('>/dev/null') must not DECREASE (we may add redirects, never lose one)
  2. after removing every ' ?>/dev/null' fragment from BOTH sides, the two lines may differ
     only by deleting a 'q' from a leading-dash option cluster, or a whole -q/--quiet/--silent word.
Anything else (a replace, a second kind of edit, an unequal hunk) is a failure.

usage: pipefail-grepq-verify-diff.py WORKTREE [BASE_REF]   (BASE_REF defaults to origin/main; exit 1 on any failure)
"""
import difflib
import re
import subprocess
import sys

wt = sys.argv[1]
base = sys.argv[2] if len(sys.argv) > 2 else "origin/main"
DN = re.compile(r" ?>/dev/null")


def git(*a):
    return subprocess.run(["git", "-C", wt, *a], capture_output=True, text=True, errors="surrogateescape").stdout


def _flag_removal_candidates(s):
    """one-step reductions of s matching a single codemod edit: drop one 'q' from
    inside a flag cluster, or drop a whole -q/--quiet/--silent word (one adjacent space)."""
    out = []
    for i, c in enumerate(s):
        if c == "q" and re.search(r"(?:^|[\s\"'])-[A-Za-z]*$", s[:i]):
            out.append(s[:i] + s[i + 1:])
    for pat in (" -q", "-q ", " --quiet", "--quiet ", " --silent", "--silent "):
        idx = s.find(pat)
        while idx != -1:
            out.append(s[:idx] + s[idx + len(pat):])
            idx = s.find(pat, idx + 1)
    return out


def is_q_only_edit(o, n, depth=0):
    """True iff n is reachable from o via zero or more single-flag q-removals.

    Checked by direct reconstruction (try every legal single-step removal and
    recurse) rather than by pattern-matching a difflib opcode: with a repeated
    '-' right after the removed flag (e.g. "-q --pat"), SequenceMatcher can
    represent the very same net edit as deleting 'q -' instead of ' -q' —
    an alignment artifact, not a different edit — which a fixed-shape check
    on its opcodes would misreport as unrecognized."""
    if o == n:
        return True
    if depth > 4:                      # a real line never needs more than a couple of removals
        return False
    return any(is_q_only_edit(cand, n, depth + 1) for cand in _flag_removal_candidates(o))


def only_q_edits(o, n):
    if is_q_only_edit(o, n):
        return None
    sm = difflib.SequenceMatcher(None, o, n, autojunk=False)
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag != "equal":
            return f"{tag} {o[i1:i2]!r} -> {n[j1:j2]!r}"
    return None


files = [f for f in git("diff", "--name-only", base).split("\n") if f]
bad = pairs = n_ins = n_q = 0
for f in files:
    old, new, hdr = [], [], None

    def flush():
        global bad, pairs, n_ins, n_q
        if hdr is None:
            return
        if len(old) != len(new):
            print(f"FAIL {f} {hdr}: unequal hunk -{len(old)} +{len(new)}")
            bad += 1
            return
        for o, n in zip(old, new):
            pairs += 1
            if n.count(">/dev/null") < o.count(">/dev/null"):
                print(f"FAIL {f} {hdr}: a >/dev/null was LOST\n   - {o.strip()[:140]}\n   + {n.strip()[:140]}")
                bad += 1
                continue
            n_ins += n.count(">/dev/null") - o.count(">/dev/null")
            why = only_q_edits(DN.sub("", o), DN.sub("", n))
            if why:
                print(f"FAIL {f} {hdr}: {why}\n   - {o.strip()[:140]}\n   + {n.strip()[:140]}")
                bad += 1
            else:
                n_q += 1 if DN.sub("", o) != DN.sub("", n) else 0

    for ln in git("diff", "-U0", "--no-color", base, "--", f).split("\n"):
        if ln.startswith("@@"):
            flush()
            old, new = [], []
            hdr = ln.split("@@")[1].strip()
        elif ln.startswith(("---", "+++", "diff ", "index ")):
            continue
        elif ln.startswith("-"):
            old.append(ln[1:])
        elif ln.startswith("+"):
            new.append(ln[1:])
    flush()

print(f"# files={len(files)} line-pairs={pairs} pairs-with-q-removal={n_q} '>/dev/null'-added={n_ins} failures={bad}")
sys.exit(1 if bad else 0)

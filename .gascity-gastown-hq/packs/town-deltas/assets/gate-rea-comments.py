#!/usr/bin/env python3
"""gate-rea-comments.py — ga-jdzri9: reads `bd comments <bead> --json` on stdin and reports the comments that answer the REA rule.

A comment ANSWERS the rule when one of its lines starts with `REA:` (leading blanks allowed) followed by something other than blanks —
an empty `REA:` is not an answer. For each such comment, in the order bd lists them, one line goes to stdout:

    <comment id><TAB><labels>          labels = comma-separated shapes found in that comment, or `-` when it is clean

Labels name the SHAPE, never the value (the comment is already in the bead; echoing a token into the gate log would publish it a second
time): private-key jwt bearer authorization cookie credential key url-credentials cpf cnpj.

exit 0  the list was read. No stdout line = no comment answers the rule (the caller reads that as "missing").
exit 2  could not read: stdin is not JSON, not a list, or it holds an element whose text cannot be read AND no readable comment
        answers the rule — the unreadable one may be the answer, so "I could not tell" must not read as "missing".

Why this is NOT gate-fastlane-scan.py: that scanner is written for diffs and treats ANY run of 8+ digits as a finding. A REA line carries
dates (2026-10-12) and ids, so that rule would reject honest comments. Here a number is only a finding if it is shaped like a CPF/CNPJ:
written with the punctuation (flagged as it looks), or bare with valid check digits (11 / 14 digits that happen to check out).
What this does NOT cover: an e-mail, a name, an address, a password that is only letters, a secret in a shape not listed below.
"""
import json
import re
import sys

_REA_LINE = re.compile(r"(?m)^[ \t]*REA:[ \t]*\S")

# (label, pattern). Patterns are deliberately narrow: a false positive costs one more comment, a false negative publishes a credential.
_SHAPES = (
    ("private-key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}")),
    ("bearer", re.compile(r"(?i)bearer\s+[A-Za-z0-9._~+/=-]{16,}")),
    ("authorization", re.compile(r"(?i)authorization\s*:\s*(?:basic|token)\s+[A-Za-z0-9._~+/=-]{12,}")),
    ("cookie", re.compile(r"(?i)\b(?:set-)?cookie\s*:\s*[^\s=;]+=[^\s;]{6,}")),
    ("key", re.compile(r"AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|xox[abprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}")),
    ("url-credentials", re.compile(r"[a-zA-Z][a-zA-Z0-9+.-]*://[^\s/@:]+:[^\s/@]+@")),
)
# `name = value` where the NAME says secret and the VALUE is 16+ token characters mixing letters and digits (a path or a word is not a token).
_NAMED = re.compile(
    r"(?i)(?<![A-Za-z0-9])(?:access|refresh|id|auth|csrf|session)?[_-]?(?:token|secret|password|passwd|api[_-]?key|apikey|session[_-]?id|sessionid|jsessionid|phpsessid|sid)"
    r"[\"']?\s*[:=]\s*[\"']?([A-Za-z0-9._~+/%-]{16,})"
)
_CPF_FMT = re.compile(r"(?<!\d)\d{3}\.\d{3}\.\d{3}-\d{2}(?!\d)")
_CNPJ_FMT = re.compile(r"(?<!\d)\d{2}\.\d{3}\.\d{3}/\d{4}-\d{2}(?!\d)")
_DIGITS = re.compile(r"\d+")


def _cpf_ok(d):
    if len(set(d)) == 1:
        return False
    for n in (9, 10):
        s = sum(int(d[i]) * (n + 1 - i) for i in range(n))
        if (s * 10) % 11 % 10 != int(d[n]):
            return False
    return True


def _cnpj_ok(d):
    if len(set(d)) == 1:
        return False
    w = (5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2)
    for n, ws in ((12, w), (13, (6,) + w)):
        r = sum(int(d[i]) * ws[i] for i in range(n)) % 11
        if int(d[n]) != (0 if r < 2 else 11 - r):
            return False
    return True


def shapes(text):
    found = set()
    for label, rx in _SHAPES:
        if rx.search(text):
            found.add(label)
    for m in _NAMED.finditer(text):
        v = m.group(1)
        if re.search(r"\d", v) and re.search(r"[A-Za-z]", v):
            found.add("credential")
    if _CPF_FMT.search(text):
        found.add("cpf")
    if _CNPJ_FMT.search(text):
        found.add("cnpj")
    for m in _DIGITS.finditer(text):
        run = m.group(0)
        if len(run) == 11 and _cpf_ok(run):
            found.add("cpf")
        elif len(run) == 14 and _cnpj_ok(run):
            found.add("cnpj")
    return found


def main():
    try:
        data = json.loads(sys.stdin.read())
    except ValueError:
        return 2
    if not isinstance(data, list):
        return 2
    rows, unreadable = [], 0
    for c in data:
        text = c.get("text") if isinstance(c, dict) else None
        if not isinstance(text, str):
            text = c.get("body") if isinstance(c, dict) else None
        if not isinstance(text, str):
            unreadable += 1
            continue
        if _REA_LINE.search(text):
            ident = str(c.get("id", "")).replace("\t", " ").replace("\n", " ") or "?"
            rows.append((ident, ",".join(sorted(shapes(text))) or "-"))
    if not rows and unreadable:
        return 2
    for ident, labels in rows:
        sys.stdout.write("%s\t%s\n" % (ident, labels))
    return 0


if __name__ == "__main__":
    sys.exit(main())

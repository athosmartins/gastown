#!/usr/bin/env python3
"""gate-fastlane-scan.py — ga-atsahv: the mechanical content check of the gate's DOC/TEST fast lane.

The fast lane merges a docs/tests-only diff WITHOUT an LLM reviewer. What the reviewer would have caught in
such a diff is a person's data or a credential pasted into a document, so this scans exactly that, on the
ADDED lines only (a line the diff does not add cannot be what this branch publishes).

    git diff -U0 --no-color --no-renames <base>...<head> | gate-fastlane-scan.py [--max-bytes N]

stdout: one finding per line, `LABEL<TAB>path<TAB>line` — NEVER the matched text. The caller writes this into
bead comments and the dispatcher log; echoing the value would publish the very secret the scan exists to stop.

exit 0  clean.
exit 1  at least one finding  -> the caller sends the diff to the NORMAL gate.
exit 2  could not scan (binary file in the diff, input over --max-bytes, unreadable/garbled diff, bug) ->
        the caller ALSO sends it to the normal gate. "Could not scan" must never read as "clean": that is the
        third state, and under doubt the lane stays the inert (normal-gate) one.

A false positive costs one ordinary review; a false negative publishes data. So every pattern errs wide.
The patterns are defined here, once. (The story cites "the same patterns as publicar-estudo"; no copy of that
skill is reachable from the gate, so this is an independent set — keep it as the single place to unify them.)
"""
import re
import sys

MAX_BYTES_DEFAULT = 2 * 1024 * 1024

# --- personal data (Brazil) -------------------------------------------------------------------------------
_CPF_FORMATTED = re.compile(r"(?<![0-9.])\d{3}\.\d{3}\.\d{3}-\d{2}(?![0-9])")
_ELEVEN_DIGITS = re.compile(r"(?<![0-9])\d{11}(?![0-9])")
_PHONE_SHAPES = [
    # country code + DDD + number:  +55 31 99999-8888, +5531999998888, +55 (31) 3333-4444
    re.compile(r"(?<![0-9])\+55[\s.-]?\(?\d{2}\)?[\s.-]?9?\d{4}[\s.-]?\d{4}(?![0-9])"),
    # DDD in parentheses:  (31) 99999-8888, (31)3333-4444
    re.compile(r"\(\d{2}\)[\s.-]?9?\d{4}[\s.-]?\d{4}(?![0-9])"),
    # DDD + separator + number:  31 99999-8888, 31 3333-4444
    re.compile(r"(?<![0-9])\d{2}[\s.-]9\d{4}[\s.-]?\d{4}(?![0-9])"),
    re.compile(r"(?<![0-9])\d{2}\s\d{4}-\d{4}(?![0-9])"),
    # mobile without DDD:  99999-8888
    re.compile(r"(?<![0-9])9\d{4}-\d{4}(?![0-9])"),
    # bare WhatsApp-style id:  5531999998888 (@s.whatsapp.net / @c.us), 12-13 digits, country 55 + valid DDD
    re.compile(r"(?<![0-9])55[1-9]\d9?\d{8}(?![0-9])"),
]

# --- credentials ------------------------------------------------------------------------------------------
_SECRET_SHAPES = [
    ("private-key", re.compile(r"-----BEGIN (?:[A-Z]+ )*PRIVATE KEY")),
    ("aws-key", re.compile(r"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])")),
    ("github-token", re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}")),
    ("slack-token", re.compile(r"xox[abprs]-[A-Za-z0-9-]{10,}")),
    ("slack-webhook", re.compile(r"hooks\.slack\.com/services/[A-Za-z0-9/]{20,}")),
    ("api-key", re.compile(r"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}")),
    ("google-key", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("jwt", re.compile(r"eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}")),
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/=-]{24,}")),
    ("url-credentials", re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:[^\s/@]{3,}@")),
]
# name = value, where the NAME says secret and the VALUE is long and token-shaped.
_ASSIGN = re.compile(
    r"(?i)[\w.-]*(?:api[_-]?key|secret|token|passw(?:or)?d|pwd|credential|private[_-]?key)[\w.-]*"
    r"\s*[:=]\s*[\"']?([A-Za-z0-9/+_=.-]{20,})[\"']?"
)
_PLACEHOLDER = re.compile(r"(?i)x{4,}|\*{3,}|<[^>]*>|\$\{|\$\(|^\$|example|placeholder|your[_-]|changeme|dummy|redacted|\.\.\.")


def _cpf_valid(d: str) -> bool:
    """True when `d` (11 digits) carries valid CPF check digits and is not a repeated digit."""
    if len(d) != 11 or d == d[0] * 11:
        return False
    for n in (9, 10):
        s = sum(int(d[i]) * (n + 1 - i) for i in range(n))
        if (s * 10 % 11) % 10 != int(d[n]):
            return False
    return True


def scan_text(text: str):
    """Labels found in ONE piece of text (no positions, no values)."""
    labels = []
    if _CPF_FORMATTED.search(text):
        labels.append("cpf")
    elif any(_cpf_valid(m.group(0)) for m in _ELEVEN_DIGITS.finditer(text)):
        labels.append("cpf")
    if any(p.search(text) for p in _PHONE_SHAPES):
        labels.append("telefone")
    for label, pat in _SECRET_SHAPES:
        if pat.search(text):
            labels.append(label)
    for m in _ASSIGN.finditer(text):
        v = m.group(1)
        if _PLACEHOLDER.search(v):
            continue
        # a word-like value ("some_descriptive_name") is not a credential; require letters AND digits
        if re.search(r"[A-Za-z]", v) and re.search(r"\d", v):
            labels.append("secret-assignment")
            break
    return labels


def scan_diff(lines):
    """Yield (label, path, lineno) for every ADDED line of a `-U0` unified diff. Raises ValueError on a diff it
    cannot trust (binary file, an added line before any file header)."""
    path = None
    lineno = 0
    for raw in lines:
        line = raw.rstrip("\n")
        if line.startswith("Binary files ") or line.startswith("GIT binary patch"):
            raise ValueError("binary content in the diff — cannot be scanned")
        if line.startswith("+++ "):
            tgt = line[4:]
            path = tgt[2:] if tgt.startswith("b/") else tgt
            if path == "/dev/null":
                path = None
            else:
                for label in scan_text(path):  # the file NAME can carry a CPF/phone too
                    yield (label, path, 0)
            continue
        if line.startswith("--- ") or line.startswith("diff --git") or line.startswith("index "):
            continue
        if line.startswith("@@"):
            m = re.match(r"@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@", line)
            if not m:
                raise ValueError("unparseable hunk header")
            lineno = int(m.group(1))
            continue
        if line.startswith("+"):
            if path is None:
                raise ValueError("added line outside any file header")
            for label in scan_text(line[1:]):
                yield (label, path, lineno)
            lineno += 1
        # '-' lines and '\ No newline' markers add nothing


def main(argv):
    max_bytes = MAX_BYTES_DEFAULT
    if "--max-bytes" in argv:
        try:
            max_bytes = int(argv[argv.index("--max-bytes") + 1])
        except (IndexError, ValueError):
            print("bad --max-bytes", file=sys.stderr)
            return 2
    data = sys.stdin.buffer.read(max_bytes + 1)
    if len(data) > max_bytes:
        print(f"input over {max_bytes} bytes — cannot be scanned in full", file=sys.stderr)
        return 2
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        print("diff is not valid UTF-8 — cannot be scanned reliably", file=sys.stderr)
        return 2
    try:
        findings = list(scan_diff(text.splitlines()))
    except ValueError as e:
        print(str(e), file=sys.stderr)
        return 2
    for label, path, lineno in findings:
        print(f"{label}\t{path}\t{lineno}")
    return 1 if findings else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as e:  # any bug here must read as "could not scan", never as "clean"
        print(f"scanner crashed: {e!r}", file=sys.stderr)
        sys.exit(2)

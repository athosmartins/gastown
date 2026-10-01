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
        third state, and under doubt the lane stays the inert (normal-gate) one. The parser therefore knows
        every line it may meet and consumes exactly the line counts each `@@` header declares; a line it cannot
        classify, or a hunk that ends early, is exit 2 — never "adds nothing".

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
    # bare, unformatted national number — the shape a CSV export in reports/ carries:
    #   mobile   31999998888  (DDD 11-99, then 9, then 8 digits)
    #   landline 3133334444   (DDD 11-99, then 2-5, then 7 digits)
    re.compile(r"(?<![0-9])[1-9][1-9]9\d{8}(?![0-9])"),
    re.compile(r"(?<![0-9])[1-9][1-9][2-5]\d{7}(?![0-9])"),
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
    # the lookbehind lets a scheme start only at the beginning of a run: without it every position of a long
    # alphanumeric line is a fresh start and the match is quadratic (64 000 chars took 3.6 s)
    ("url-credentials", re.compile(r"(?<![A-Za-z0-9+.-])[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:[^\s/@]{3,}@")),
]
# name = value, where the NAME says secret and the VALUE is long and token-shaped.
# No leading `[\w.-]*` (finditer already finds the keyword anywhere) and the trailing run is capped: both made the
# match quadratic on a long line of word characters (32 000 chars took 18 s; "token" x 400 000 never finished) —
# a scan that holds the citywide gate lock must not hang. No credential NAME runs 64 characters past its keyword.
_ASSIGN = re.compile(
    r"(?i)(?:api[_-]?key|secret|token|passw(?:or)?d|pwd|credential|private[_-]?key)[\w.-]{0,64}"
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


_HUNK = re.compile(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?")
# the extended-header lines git prints between `diff --git` and the first hunk; none of them adds content
_FILE_HEADERS = ("index ", "--- ", "new file mode ", "deleted file mode ", "old mode ", "new mode ",
                 "similarity index ", "dissimilarity index ", "rename from ", "rename to ", "copy from ", "copy to ")
_NO_NEWLINE = "\\ "   # "\ No newline at end of file" (any wording): a content line starts with + - or a space, never "\"


def scan_diff(lines):
    """Yield (label, path, lineno) for every ADDED line of a unified diff. `lines` are split on "\\n" ONLY (never
    str.splitlines(): U+2028, U+0085, form feed... are routine in pasted text and would cut an added line in two,
    leaving a tail that no longer starts with "+").

    Raises ValueError on a diff it cannot trust: a binary file, an added line before any file header, a line that is
    none of the shapes git emits, a hunk whose lines do not match the counts its `@@` header declares, or a diff
    that ends inside a hunk. The parser tracks those counts so that what counts as CONTENT is decided by the hunk
    header, never by what the line looks like — an added line whose text starts with "++ " is a `+++ ` line on
    the wire, and is still content.

    A path that itself carries a CPF/phone/credential is never yielded as a path (the caller prints it): it is
    reported as <redacted-name#N>, N being the file's position in the diff."""
    path = None          # the b-side path of the current file (None for /dev/null)
    shown = None         # what a finding may call that file
    nfile = 0
    name_seen = set()    # labels already reported for the current file's NAME
    old_left = new_left = 0
    lineno = 0
    last_was_body = False

    def name_findings(text):
        for label in scan_text(text):
            if label not in name_seen:
                name_seen.add(label)
                yield (label, f"<redacted-name#{nfile}>", 0)

    for line in lines:
        in_hunk = old_left > 0 or new_left > 0
        if in_hunk:
            c = line[:1]
            if c == "+":
                if new_left <= 0 or path is None:
                    raise ValueError("added line that its hunk header does not account for")
                new_left -= 1
                for label in scan_text(line[1:]):
                    yield (label, shown, lineno)
                lineno += 1
            elif c == "-":
                if old_left <= 0:
                    raise ValueError("removed line that its hunk header does not account for")
                old_left -= 1
            elif c == " ":
                if old_left <= 0 or new_left <= 0:
                    raise ValueError("context line that its hunk header does not account for")
                old_left -= 1
                new_left -= 1
                lineno += 1
            elif line.startswith(_NO_NEWLINE):
                pass
            else:
                raise ValueError("unrecognized line inside a hunk — cannot be classified")
            last_was_body = c in ("+", "-", " ")
            continue

        if line.startswith(_NO_NEWLINE) and last_was_body:   # the marker follows the hunk's last line
            last_was_body = False
            continue
        last_was_body = False
        if line.startswith("Binary files ") or line.startswith("GIT binary patch"):
            raise ValueError("binary content in the diff — cannot be scanned")
        if line.startswith("diff --git "):
            nfile += 1
            path = shown = None
            name_seen = set()
            yield from name_findings(line[len("diff --git "):])   # an empty/mode-only/deleted file has no +++ line
            continue
        if line.startswith("+++ "):
            tgt = line[4:]
            path = tgt[2:] if tgt.startswith("b/") else tgt
            if path == "/dev/null":
                path = shown = None
            else:
                yield from name_findings(path)
                shown = f"<redacted-name#{nfile}>" if name_seen else path
            continue
        if line.startswith(_FILE_HEADERS):
            continue
        if line.startswith("@@"):
            m = _HUNK.fullmatch(line)
            if not m:
                raise ValueError("unparseable hunk header")
            old_left = int(m.group(2)) if m.group(2) is not None else 1
            new_left = int(m.group(4)) if m.group(4) is not None else 1
            lineno = int(m.group(3))
            continue
        raise ValueError("unrecognized diff line — cannot be classified")
    if old_left > 0 or new_left > 0:
        raise ValueError("diff ends inside a hunk — truncated, cannot be scanned in full")


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
    lines = text.split("\n")
    if lines and lines[-1] == "":   # git ends every line, the last one included, with "\n"
        lines.pop()
    try:
        findings = list(scan_diff(lines))
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

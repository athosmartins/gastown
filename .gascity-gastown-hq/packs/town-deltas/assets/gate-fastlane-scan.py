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

WHAT IT COVERS, AND WHAT IT DOES NOT. Where a choice exists it errs toward a finding (a false positive costs one
ordinary review; a false negative publishes data), but it is a net for the ACCIDENTAL paste of a lead's number or
a token into a document, not proof that a document is clean.
  covered
    * personal numbers — CPF, phone (with or without DDD / country code), WhatsApp id, RG, CNPJ and any other long
      identifier — by ONE rule, not a list of notations (four gate rounds each found one more notation a list did
      not hold): once the characters between digits are ignored, ANY run of 8 or more digits is a finding. "Ignored"
      means every character that is neither a letter nor a digit: space, . - / ( ) + _ , | * ` quotes, markdown
      emphasis, zero-width marks, a line break between two ADJACENT added lines (a number wrapped across lines). The
      price is accepted: a date (2026-10-01), a timestamp, a long id or a numeric table row is a finding too, and
      costs one ordinary review, which is the status quo.
    * credentials — the shapes in _SECRET_SHAPES (private-key header, AWS / GitHub / Slack / Google / sk- keys, JWT,
      bearer token, credentials inside a URL) and `name = value` where the name says secret and the value is 20+
      token characters mixing letters and digits.
  NOT covered
    * an e-mail address; a name; an address; any personal data that carries no long number
    * a password that is letters-only or digits-only, or whose symbols end the value run (`Hunter2!Hunter2!Hunter2!`)
    * a number a LETTER interrupts (`31x99999x8888`) or one written in words
    * a number wrapped across lines that are not adjacent in the new file (separate hunks, or an unchanged line
      between them) — only a run of consecutive ADDED lines is joined
    * a secret in a shape _SECRET_SHAPES does not list
The patterns are defined here, once. (The story cites "the same patterns as publicar-estudo"; no copy of that
skill is reachable from the gate, so this is an independent set — keep it as the single place to unify them.)
"""
import bisect
import re
import sys

MAX_BYTES_DEFAULT = 2 * 1024 * 1024

# --- personal numbers -------------------------------------------------------------------------------------
# One digit, then seven or more of (any run of non-letter-non-digit characters, one digit). \d and \W are Unicode-aware
# (fullwidth digits count as digits; NBSP, U+2028 and zero-width marks count as separators); \W leaves out "_", hence it.
# `[\W_]*` and `\d` are disjoint, so there is no nesting ambiguity: a start position costs the length of the (at most
# eight) separator runs it walks, and the scan stays linear overall. It holds the citywide gate lock, so that matters;
# selftest §1f feeds it the worst shapes (a digit followed by a 1.5 MB separator run, 7-digit near misses, 7 digits
# over 1000-long separator runs).
_LONG_NUMBER = re.compile(r"\d(?:[\W_]*\d){7,}")

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


def scan_text(text: str, numbers: bool = True):
    """Labels found in ONE piece of text (no positions, no values). `numbers=False` leaves the long-number rule to
    the caller: for ADDED lines scan_diff applies it to the whole run of adjacent added lines instead (a number
    wrapped across a line break), so a line is not asked the same question twice."""
    labels = []
    if numbers and _LONG_NUMBER.search(text):
        labels.append("numero-longo")
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
    run = []             # (lineno, text) of the added lines seen since the last line that is not an added one

    def name_findings(text):
        for label in scan_text(text):
            if label not in name_seen:
                name_seen.add(label)
                yield (label, f"<redacted-name#{nfile}>", 0)

    def number_findings():
        """The long-number rule over one run of ADJACENT added lines (consecutive lines of the new file), joined with
        a line break — a number wrapped across the break is one number. One finding per line a number starts on."""
        joined = "\n".join(t for _, t in run)
        starts, pos = [], 0
        for _, t in run:
            starts.append(pos)
            pos += len(t) + 1
        seen = set()
        for m in _LONG_NUMBER.finditer(joined):
            ln = run[bisect.bisect_right(starts, m.start()) - 1][0]
            if ln not in seen:
                seen.add(ln)
                yield ("numero-longo", shown, ln)

    for line in lines:
        in_hunk = old_left > 0 or new_left > 0
        if in_hunk:
            c = line[:1]
            if c == "+":
                if new_left <= 0 or path is None:
                    raise ValueError("added line that its hunk header does not account for")
                new_left -= 1
                for label in scan_text(line[1:], numbers=False):
                    yield (label, shown, lineno)
                run.append((lineno, line[1:]))
                lineno += 1
            else:
                if run:   # the run of adjacent added lines ends here
                    yield from number_findings()
                    run = []
                if c == "-":
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
            if run and old_left <= 0 and new_left <= 0:   # the hunk's last line was an added one
                yield from number_findings()
                run = []
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
            # git ends this line with a TAB when the path holds a space (`+++ b/docs/a b.md<TAB>`). The TAB is the
            # separator, never part of the name: a real TAB in a path is C-quoted, so an unquoted name cannot end in one.
            # Left in, it made the finding line `label<TAB>path<TAB><TAB>line` (4 fields), and the caller read the
            # scanner's own output as malformed — a real finding reported as "the scanner crashed".
            tgt = line[4:].rstrip("\t")
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

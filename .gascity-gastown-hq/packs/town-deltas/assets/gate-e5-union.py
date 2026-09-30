#!/usr/bin/env python3
"""gate-e5-union.py — union of the blocking issues of N independent gate reviewers.

E5 (ga-syxaki, P0 ga-ufskhy). When the gate runs a 2nd independent reviewer, the verdict
handed back to the builder is the UNION of both reviewers' blocking issues, deduplicated —
not two paragraphs pasted one after the other, and not "whichever FAIL came first".

Input  (stdin, JSON):  {"reviewers": [{"index": 1, "text": "<the FAIL verdict comment>"}, ...]}
Output (stdout, JSON): {"text": "<merged feedback>", "stats": {...}}

DEDUPE — what counts as "the same issue" (the bead says "por arquivo+linha+classe"):
  * file+line: both issues cite the same file, and the cited lines overlap (±LINE_SLACK);
    if either side cites the file without a line, the file alone is a WEAK match.
  * classe: reviewers do not emit a class (E4 assigns classes after the fact, with an LLM),
    so the class is approximated by the defect DESCRIPTION: the overlap coefficient of the
    two issues' significant tokens (identifiers, words >= 4 chars). Two different defects on
    the same line (a swallowed error and a lying comment) share the citation but not the
    description, so they stay separate. If BOTH issues carry an explicit "class: <x>" tag
    and the tags differ, that decides it: not duplicates.
  * thresholds are deliberately conservative: a false MERGE drops a real finding from what
    the builder sees (harmful); a false KEEP only shows the same defect twice (harmless).
    Every doubt resolves to KEEP BOTH.
  * an issue with no citation at all is merged only with a textually identical one.
  * issues of the SAME reviewer are never merged with each other.

Nothing else is dropped: each reviewer's preamble and non-blocking findings / coverage tail
are kept verbatim under "other notes".

Stdlib only; safe on the python3 that launchd's PATH finds. Any failure is the CALLER's cue
to fall back to the legacy concatenation — this script never guesses a partial answer.
"""
import json
import re
import sys

LINE_SLACK = 3
STRONG_THRESHOLD = 0.50   # both sides cite a line range and the ranges overlap
WEAK_THRESHOLD = 0.65     # the file matches but a side has no line number

ISSUE_RE = re.compile(r'^[ \t]*(?:#{1,6}[ \t]*)?(?:\*\*)?[ \t]*Blocking[ \t]+issue[ \t]+(\d+)\b', re.I)
NONBLOCK_RE = re.compile(r'^[ \t]*(?:#{1,6}[ \t]*)?(?:\*\*)?[ \t]*Non-?[ \t]*blocking\b', re.I)
COVERAGE_RE = re.compile(r'^[ \t]*(?:\*\*)?[ \t]*Coverage[ \t]*(?:\*\*)?[ \t]*:', re.I)
TERMINATOR_RE = re.compile(
    r'^[ \t]*(?:#{1,3}[ \t]+\S|(?:Verified|Checked)\b|Summary[ \t]*:|Lens[ \t]*:)', re.I)
VERDICT_LINE_RE = re.compile(r'^[ \t]*VERDICT[ \t]*:[ \t]*FAIL\b.*$', re.I)
CITE_RE = re.compile(
    r'(?<![\w/.-])((?:[\w.-]+/)*[\w.-]+\.(?:py|sh|js|jsx|ts|tsx|toml|json|md|yaml|yml|html|css|sql|go|plist|txt|cfg|ini))'
    r'(?::(\d+)(?:-(\d+))?)?', re.I)
CLASS_TAG_RE = re.compile(r'\bclass[ \t]*:[ \t]*([A-Za-z0-9_.\- ]{1,40}?)(?=[,);:\]]|$)', re.I)
TOKEN_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]{3,}')
STOPWORDS = frozenset("""
this that with from have which because there their then than when where while would could should
into onto over under also only each both other such these those will does done being been were
what about after before again same more most some very just like make made used uses using line
lines code file files test tests case cases issue issues blocking diff branch reviewer review
""".split())


class UnionError(Exception):
    pass


def parse_comment(text):
    """Split one FAIL verdict comment into (preamble, issues, tail).

    issues: list of {"header": str, "body": str (whole issue text incl. header line)}
    Returns issues == [] when the comment carries no 'Blocking issue N' marker (the caller
    then treats the whole comment as one opaque issue)."""
    lines = text.splitlines()
    preamble, tail = [], []
    issues = []
    cur = None
    state = "pre"
    for ln in lines:
        if ISSUE_RE.match(ln):
            if cur is not None:
                issues.append(cur)
            cur = {"lines": [ln]}
            state = "issue"
            continue
        if state == "issue":
            if NONBLOCK_RE.match(ln) or COVERAGE_RE.match(ln) or TERMINATOR_RE.match(ln):
                issues.append(cur)
                cur = None
                state = "tail"
                tail.append(ln)
            else:
                cur["lines"].append(ln)
        elif state == "tail":
            tail.append(ln)
        else:
            preamble.append(ln)
    if cur is not None:
        issues.append(cur)
    out = []
    for it in issues:
        body = "\n".join(it["lines"]).rstrip()
        out.append({"header": it["lines"][0], "body": body})
    pre_txt = "\n".join(l for l in preamble if not VERDICT_LINE_RE.match(l)).strip()
    return pre_txt, out, "\n".join(tail).strip()


def cites_of(body):
    """[(file_key, lo|None, hi|None)] — every file citation in the issue text."""
    out = []
    for m in CITE_RE.finditer(body):
        path = m.group(1)
        if path.startswith("./"):
            path = path[2:]
        lo = int(m.group(2)) if m.group(2) else None
        hi = int(m.group(3)) if m.group(3) else lo
        if lo is not None and hi is not None and hi < lo:
            lo, hi = hi, lo
        out.append((path, lo, hi))
    return out


def same_file(a, b):
    if a == b:
        return True
    # one side may cite a bare basename, the other the full path
    return a.rsplit("/", 1)[-1] == b.rsplit("/", 1)[-1] and ("/" not in a or "/" not in b)


def cite_strength(ca, cb):
    """'strong' (same file, overlapping lines), 'weak' (same file, a side has no line), or ''."""
    best = ""
    for fa, loa, hia in ca:
        for fb, lob, hib in cb:
            if not same_file(fa, fb):
                continue
            if loa is None or lob is None:
                best = best or "weak"
                continue
            if loa - LINE_SLACK <= hib and lob - LINE_SLACK <= hia:
                return "strong"
    return best


def tokens_of(body):
    toks = set()
    for t in TOKEN_RE.findall(body):
        t = t.lower()
        if t not in STOPWORDS:
            toks.add(t)
    return toks


def overlap(ta, tb):
    if not ta or not tb:
        return 0.0
    return len(ta & tb) / float(min(len(ta), len(tb)))


def class_tag(body):
    m = CLASS_TAG_RE.search(body)
    return m.group(1).strip().lower() if m else None


def norm_text(body):
    return re.sub(r'\s+', ' ', re.sub(r'^[ \t]*(?:#{1,6}[ \t]*)?Blocking issue[ \t]+\d+', '', body, flags=re.I)).strip().lower()


def is_duplicate(a, b):
    """a, b: prepared issue dicts from different reviewers."""
    ta, tb = class_tag(a["body"]), class_tag(b["body"])
    if ta is not None and tb is not None and ta != tb:
        return False
    if not a["cites"] and not b["cites"]:
        return a["norm"] == b["norm"] and a["norm"] != ""
    strength = cite_strength(a["cites"], b["cites"])
    if not strength:
        return False
    sim = overlap(a["tokens"], b["tokens"])
    return sim >= (STRONG_THRESHOLD if strength == "strong" else WEAK_THRESHOLD)


def prepare(body, reviewer):
    return {"body": body, "cites": cites_of(body), "tokens": tokens_of(body),
            "norm": norm_text(body), "reviewers": [reviewer]}


def renumber(body, n):
    return re.sub(r'(Blocking[ \t]+issue[ \t]+)\d+', lambda m: m.group(1) + str(n), body, count=1, flags=re.I)


def union(reviewers):
    if not isinstance(reviewers, list) or not reviewers:
        raise UnionError("no reviewers")
    merged = []          # prepared issues, in first-seen order
    per_reviewer = {}    # index -> count of issues
    notes = []           # (index, preamble, tail)
    duplicates = 0
    order = []
    for r in reviewers:
        idx = r.get("index")
        text = r.get("text")
        if not isinstance(idx, int) or not isinstance(text, str) or not text.strip():
            raise UnionError("reviewer entry without an integer index / non-empty text: %r" % (r,))
        order.append(idx)
        pre, issues, tail = parse_comment(text)
        if not issues:
            # no 'Blocking issue N' marker: keep the WHOLE comment as one opaque issue —
            # never drop a FAIL because its format is unfamiliar.
            body = text.strip()
            issues_b = [body]
            pre, tail = "", ""
        else:
            issues_b = [i["body"] for i in issues]
        per_reviewer[idx] = len(issues_b)
        if pre or tail:
            notes.append((idx, pre, tail))
        for body in issues_b:
            cand = prepare(body, idx)
            hit = None
            for m in merged:
                if idx in m["reviewers"]:
                    continue          # never merge two issues of the same reviewer
                if is_duplicate(m, cand):
                    hit = m
                    break
            if hit is None:
                merged.append(cand)
            else:
                duplicates += 1
                hit["reviewers"].append(idx)
                if len(cand["body"]) > len(hit["body"]):   # keep the more informative wording
                    hit["body"] = cand["body"]
                    hit["cites"] = cand["cites"]
                    hit["tokens"] = hit["tokens"] | cand["tokens"]
    first = order[0]
    counts = ", ".join("reviewer %d: %d" % (i, per_reviewer[i]) for i in order)
    head = ("Reviewer %d FAIL: VERDICT: FAIL — E5: union of %d independent reviews (%s blocking issue(s)); "
            "%d duplicate(s) merged (same file:line, same defect), %d distinct issue(s) below. "
            "Nothing else was dropped." % (first, len(order), counts, duplicates, len(merged)))
    parts = [head, ""]
    for n, m in enumerate(merged, 1):
        who = " and ".join("reviewer %d" % i for i in m["reviewers"])
        parts.append(renumber(m["body"], n))
        parts.append("  [found by %s%s]" % (who, " — independently confirmed" if len(m["reviewers"]) > 1 else ""))
        parts.append("")
    for idx, pre, tail in notes:
        parts.append("--- reviewer %d — other notes (kept verbatim) ---" % idx)
        if pre:
            parts.append(pre)
        if tail:
            parts.append(tail)
        parts.append("")
    text = "\n".join(parts).rstrip() + "\n"
    stats = {"reviewers": len(order), "issues_by_reviewer": {str(i): per_reviewer[i] for i in order},
             "duplicates_merged": duplicates, "distinct_issues": len(merged)}
    return text, stats


def main():
    try:
        payload = json.load(sys.stdin)
        text, stats = union(payload.get("reviewers"))
    except (UnionError, ValueError, AttributeError, TypeError) as exc:
        sys.stderr.write("gate-e5-union: %s\n" % exc)
        return 2
    json.dump({"text": text, "stats": stats}, sys.stdout)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())

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
    so the class is approximated by the defect DESCRIPTION: the words of the issue text with
    the file citations and the "Blocking issue N" header REMOVED (a path is not a description:
    two different defects in scripts/gate-e5-switch.sh share "scripts", "gate", "switch"), kept
    as significant tokens (identifiers, words >= 4 chars). Two issues are the same defect only
    when they share at least MIN_SHARED_TOKENS of those tokens AND the symmetric overlap
    (Jaccard: shared / union) reaches the threshold. A symmetric measure on purpose: overlap
    divided by the SMALLER side lets a terse finding be swallowed whole by a long one about
    another defect that merely names the same identifier. If BOTH issues carry an explicit
    "class: <x>" tag and the tags differ, that decides it: not duplicates.
  * thresholds are deliberately conservative: a false MERGE hides a real finding behind another
    issue's text (harmful); a false KEEP only shows the same defect twice (harmless). Measured on
    the fixtures of gate-e5-second-reviewer.selftest.sh: different defects in one file score
    0.00-0.05, the same defect in different words 0.41-0.50; the thresholds sit between.
    When the evidence is thin the two issues stay separate.
  * an issue with no citation at all is merged only with a textually identical one.
  * issues of the SAME reviewer are never merged with each other.

What a merge keeps: the more detailed wording of the two issues (tagged with every reviewer that
found it) PLUS whatever the other wording carries that the kept one lacks — a file:line citation
the kept text does not cover, a sentence that says something the kept text does not — appended
under "also from reviewer N". Two reviewers describing ONE defect do not necessarily cite the same
sites or make the same point (the second one often names the sibling call site), and the builder
reads the merged text as the whole finding: a duplicate is noise, a lost finding is a defect. The
other wording is dropped only when everything in it is already in the kept text. Each reviewer's
preamble — including any text on its "VERDICT: FAIL" line — and its non-blocking findings /
coverage tail are kept verbatim under "other notes".

Stdlib only; safe on the python3 that launchd's PATH finds. Any failure is the CALLER's cue
to fall back to the legacy concatenation — this script never guesses a partial answer.
"""
import json
import re
import sys

LINE_SLACK = 3
STRONG_THRESHOLD = 0.35   # both sides cite a line range and the ranges overlap (Jaccard of the descriptions)
WEAK_THRESHOLD = 0.50     # the file matches but a side has no line number
MIN_SHARED_TOKENS = 3     # fewer shared description words than this is never "the same defect"

ISSUE_RE = re.compile(r'^[ \t]*(?:#{1,6}[ \t]*)?(?:\*\*)?[ \t]*Blocking[ \t]+issue[ \t]+(\d+)\b', re.I)
NONBLOCK_RE = re.compile(r'^[ \t]*(?:#{1,6}[ \t]*)?(?:\*\*)?[ \t]*Non-?[ \t]*blocking\b', re.I)
COVERAGE_RE = re.compile(r'^[ \t]*(?:\*\*)?[ \t]*Coverage[ \t]*(?:\*\*)?[ \t]*:', re.I)
TERMINATOR_RE = re.compile(
    r'^[ \t]*(?:#{1,3}[ \t]+\S|(?:Verified|Checked)\b|Summary[ \t]*:|Lens[ \t]*:)', re.I)
VERDICT_LINE_RE = re.compile(r'^[ \t]*VERDICT[ \t]*:[ \t]*FAIL\b[ \t]*[-—–:,;.]*[ \t]*', re.I)
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
    # the keyword alone is noise (the merged header says it); anything else on that line is the
    # reviewer's own text (the SHA it reviewed, the lens, a caveat) and stays
    pre_txt = "\n".join(VERDICT_LINE_RE.sub("", l, count=1) for l in preamble).strip()
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


def description_of(body):
    """The defect description: the issue text without its 'Blocking issue N' header and without
    any file citation (path tokens say WHERE, not WHAT — and two different defects in one file
    share every one of them)."""
    return CITE_RE.sub(" ", ISSUE_RE.sub("", body, count=1))


def tokens_of(body):
    toks = set()
    for t in TOKEN_RE.findall(description_of(body)):
        t = t.lower()
        if t not in STOPWORDS:
            toks.add(t)
    return toks


def similarity(ta, tb):
    """(shared token count, Jaccard) of two token sets. Symmetric: a short issue cannot be
    'contained' in a long one just because the long one is long."""
    if not ta or not tb:
        return 0, 0.0
    shared = len(ta & tb)
    return shared, shared / float(len(ta | tb))


def class_tag(body):
    m = CLASS_TAG_RE.search(body)
    return m.group(1).strip().lower() if m else None


def norm_text(body):
    return re.sub(r'\s+', ' ', re.sub(r'^[ \t]*(?:#{1,6}[ \t]*)?Blocking issue[ \t]+\d+', '', body, flags=re.I)).strip().lower()


def duplicate_score(a, b):
    """a, b: prepared issue dicts from different reviewers. None when they are NOT the same
    defect (the default under any doubt); otherwise a score in (0, 1] — the Jaccard of their
    descriptions, or 1.0 for two citation-less issues with identical text — used to pick the
    BEST match when an issue resembles several."""
    ta, tb = class_tag(a["body"]), class_tag(b["body"])
    if ta is not None and tb is not None and ta != tb:
        return None
    if not a["cites"] and not b["cites"]:
        return 1.0 if (a["norm"] == b["norm"] and a["norm"] != "") else None
    strength = cite_strength(a["cites"], b["cites"])
    if not strength:
        return None
    shared, jac = similarity(a["tokens"], b["tokens"])
    if shared < MIN_SHARED_TOKENS:
        return None
    return jac if jac >= (STRONG_THRESHOLD if strength == "strong" else WEAK_THRESHOLD) else None


def is_duplicate(a, b):
    return duplicate_score(a, b) is not None


def prepare(body, reviewer):
    return {"body": body, "cites": cites_of(body), "tokens": tokens_of(body),
            "norm": norm_text(body), "reviewers": [reviewer],
            "parts": [(reviewer, body)], "notes": []}


def renumber(body, n):
    return re.sub(r'(Blocking[ \t]+issue[ \t]+)\d+', lambda m: m.group(1) + str(n), body, count=1, flags=re.I)


# ── what a merge must not lose ────────────────────────────────────────────────
SENTENCE_SPLIT_RE = re.compile(r'(?<=[.;!?])[ \t]+|\n+')


def cite_covered(c, kept_cites):
    """True when the kept text already says where citation c points: the same file and — if c names
    a line — a kept citation of that file whose line range overlaps it (±LINE_SLACK). A line number
    the kept text lacks (it cites the file bare, or another line) is information it does not have."""
    fc, loc, hic = c
    for fk, lok, hik in kept_cites:
        if not same_file(fc, fk):
            continue
        if loc is None:
            return True
        if lok is not None and loc - LINE_SLACK <= hik and lok - LINE_SLACK <= hic:
            return True
    return False


def squash(text):
    return re.sub(r'\s+', ' ', text).strip().lower().rstrip('.;!? ')


def sentences_of(body):
    """The issue's own sentences / clauses, its 'Blocking issue N' header removed (the merged text
    numbers its issues itself). File citations stay inside the sentence that carries them."""
    text = ISSUE_RE.sub("", body, count=1)
    text = re.sub(r'^[\s:*—–-]+', '', text)
    return [p.strip() for p in SENTENCE_SPLIT_RE.split(text) if p.strip()]


def sentence_covered(sent, kept_norm, kept_cites, kept_tokens):
    """The kept text already says everything this sentence says: every citation it makes is covered,
    and either its wording occurs in the kept text or every significant word of it does. Under any
    doubt the answer is False — the sentence is kept (a repeated sentence is noise, a lost one is a
    lost finding)."""
    if any(not cite_covered(c, kept_cites) for c in cites_of(sent)):
        return False
    s = squash(sent)
    if s and s in kept_norm:
        return True
    toks = tokens_of(sent)
    return bool(toks) and toks <= kept_tokens


def settle(item):
    """(Re)compute what is SHOWN for an issue found by several reviewers: the most detailed wording
    (longest; the earliest on a tie) plus, for every other wording, the sentences the shown text does
    not already contain — tagged with the reviewer who wrote them. Recomputed from item["parts"] on
    every merge, so a later and longer wording that takes over the headline pushes the previous one
    into 'also from' instead of dropping it."""
    parts = item["parts"]
    keep = max(range(len(parts)), key=lambda i: (len(parts[i][1]), -i))
    body = parts[keep][1]
    cites, tokens, norm = list(cites_of(body)), set(tokens_of(body)), squash(body)
    notes = []
    for i, (rev, text) in enumerate(parts):
        if i == keep:
            continue
        novel = []
        for s in sentences_of(text):
            if sentence_covered(s, norm, cites, tokens):
                continue
            novel.append(s)
            cites += cites_of(s)
            tokens |= tokens_of(s)
            norm += " " + squash(s)
        if novel:
            notes.append((rev, novel))
    item["body"], item["notes"], item["cites"], item["tokens"] = body, notes, cites, tokens


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
            hit, best = None, 0.0
            for m in merged:
                if idx in m["reviewers"]:
                    continue          # never merge two issues of the same reviewer
                score = duplicate_score(m, cand)
                if score is not None and score > best:     # the BEST match, not the first one seen
                    hit, best = m, score
            if hit is None:
                merged.append(cand)
            else:
                duplicates += 1
                hit["reviewers"].append(idx)
                hit["parts"].append((idx, body))
                settle(hit)       # the longest wording is shown; what the other adds is appended, not dropped
    first = order[0]
    counts = ", ".join("reviewer %d: %d" % (i, per_reviewer[i]) for i in order)
    appended = sum(len(sents) for m in merged for _, sents in m["notes"])
    head = ("Reviewer %d FAIL: VERDICT: FAIL — E5: union of %d independent reviews (%s blocking issue(s)); "
            "%d duplicate(s) merged (same file:line and same defect description; the more detailed wording is shown and "
            "anything the other wording adds — another citation, another point — is appended as 'also from reviewer N'), "
            "%d distinct issue(s) below. Each reviewer's other notes follow verbatim." % (first, len(order), counts, duplicates, len(merged)))
    parts = [head, ""]
    for n, m in enumerate(merged, 1):
        who = " and ".join("reviewer %d" % i for i in m["reviewers"])
        parts.append(renumber(m["body"], n))
        for rev, sents in m["notes"]:
            parts.append("  also from reviewer %d (not in the wording above): %s" % (rev, " ".join(sents)))
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
             "duplicates_merged": duplicates, "distinct_issues": len(merged), "sentences_appended": appended}
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

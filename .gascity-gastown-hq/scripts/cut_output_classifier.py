#!/usr/bin/env python3
"""cut_output_classifier.py (ga-wk0qi2, child of ga-aijm2v) — the "regra fixa" half of the
cut-large-output SHADOW front: pure, no-I/O, no-network classification of a Bash command's
output into one of three shapes:

  1. "pytest": a pytest run. Kept = the FAILURES section(s) + the final one-line summary
     (or, if nothing failed, just the summary line). Everything else (setup noise, collection,
     PASSED lines) is the omitted part.
  2. "log-tail": a generic long/log-shaped dump. Kept = head N + tail N + every line that looks
     like an error/exception/traceback signal (deduped), in original order. Everything else is
     omitted.
  3. None ("unstructured"): output is large but does not match either fixed shape above. The
     caller (cut-output-shadow.py) is the one that decides what to do with an unstructured
     block (ask Jev), never this module — this module answers ONLY "does a fixed, no-AI rule
     apply here, and if so what would it keep".

THIRD STATE: classify_output() returns None when no fixed rule applies (including when the
output is simply too small to bother with) — None is "no fixed-rule verdict", never "cut
everything" or "cut nothing". A caller must not treat None as either extreme.

NEVER RAISES: every public function here is total over its documented input types (str/str).
Encoding weirdness, empty strings, binary-looking bytes-as-text -- all produce a verdict or
None, never an exception. This module does zero I/O (no files, no network, no subprocess) so it
is trivially unit-testable and safe to import from a hot PostToolUse hook path.

TOKEN ESTIMATE: chars/2.2, the same constant pool-roles.json's per_task section already uses
for this city's own doctrine-preamble token accounting (packs/town-deltas/assets/claude-
overlays/pool-roles.json, key "chars_per_token") — reused here so two token estimates in the
same city are not silently using different conversions.

CLI: `python3 cut_output_classifier.py selftest` — pure, no mocks needed (nothing here touches
the network or filesystem).
"""
from __future__ import annotations

import re
import sys

CHARS_PER_TOKEN = 2.2  # packs/town-deltas/assets/claude-overlays/pool-roles.json: chars_per_token

# Below this many characters, cutting is not worth the risk of losing something the agent
# needed — the fixed-rule and Jev paths are both skipped by the caller. Kept here (not just in
# the hook) so classify_output()'s own "does this even qualify as large" gate matches whatever
# a unit test asserts about it, instead of the threshold living only in the hook wrapper.
MIN_CHARS_TO_CONSIDER = 2000

DEFAULT_HEAD_LINES = 20
DEFAULT_TAIL_LINES = 20
DEFAULT_MAX_LOG_LINES = 200  # at or under this many lines, a generic dump is left alone

_ERROR_LINE_RE = re.compile(
    r"\b(error|exception|traceback|fail(?:ed|ure)?|denied|refused|panic|fatal|"
    r"cannot|couldn't|could not|no such file|permission denied)\b",
    re.IGNORECASE,
)

# pytest's own banner lines. "session starts" without the leading "=" is deliberately loose:
# some CI wrappers reflow or strip the "=" padding, but never rename the phrase itself.
_PYTEST_SESSION_RE = re.compile(r"session starts", re.IGNORECASE)
_PYTEST_SUMMARY_RE = re.compile(
    r"^={0,}\s*(?:(\d+)\s+failed)?[, ]*(?:(\d+)\s+passed)?[, ]*(?:(\d+)\s+error)?[^=\n]*={0,}\s*$",
    re.IGNORECASE | re.MULTILINE,
)
_PYTEST_FAILURES_HEADER_RE = re.compile(r"^_{5,}.*_{5,}\s*$|^={3,}\s*FAILURES\s*={3,}\s*$", re.IGNORECASE | re.MULTILINE)
_PYTEST_SHORT_SUMMARY_RE = re.compile(r"short test summary info", re.IGNORECASE)


def estimate_tokens(text: str) -> int:
    """Never raises: empty/None-like input -> 0."""
    if not text:
        return 0
    return max(0, round(len(text) / CHARS_PER_TOKEN))


def _dedup_keep_order(lines: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for ln in lines:
        if ln in seen:
            continue
        seen.add(ln)
        out.append(ln)
    return out


def classify_pytest(text: str) -> dict | None:
    """None if `text` is not recognizably a pytest run. Otherwise a verdict dict:
    {rule: "pytest", kept_text, chars_before, chars_after, tokens_before, tokens_after,
     lines_total, lines_kept}. Kept text = every FAILURES section (from a `___ name ___` or
     `=== FAILURES ===` banner to the next banner or the short-summary section) plus the
     trailing summary line(s); if nothing failed, kept text is just the last non-blank line
     (pytest's own one-line summary, e.g. "5 passed in 0.42s")."""
    if not text or not _PYTEST_SESSION_RE.search(text):
        return None

    lines = text.splitlines()
    chars_before = len(text)
    tokens_before = estimate_tokens(text)

    failure_starts = [m.start() for m in _PYTEST_FAILURES_HEADER_RE.finditer(text)]
    short_summary_pos = None
    m = _PYTEST_SHORT_SUMMARY_RE.search(text)
    if m:
        short_summary_pos = m.start()

    if failure_starts:
        end = short_summary_pos if short_summary_pos is not None and short_summary_pos > failure_starts[0] else len(text)
        kept_body = text[failure_starts[0]:end].rstrip("\n")
    else:
        kept_body = ""

    # The trailing one-line summary ("5 failed, 2 passed in 1.3s") is always kept: it is the
    # cheapest possible signal of whether anything needs attention.
    trailing = ""
    for ln in reversed(lines):
        if ln.strip():
            trailing = ln
            break

    kept_parts = [p for p in (kept_body, trailing) if p]
    kept_text = "\n\n".join(kept_parts) if kept_parts else trailing
    chars_after = len(kept_text)
    return {
        "rule": "pytest",
        "kept_text": kept_text,
        "chars_before": chars_before,
        "chars_after": chars_after,
        "tokens_before": tokens_before,
        "tokens_after": estimate_tokens(kept_text),
        "lines_total": len(lines),
        "lines_kept": len(kept_text.splitlines()) if kept_text else 0,
    }


def classify_log_tail(
    text: str,
    head_lines: int = DEFAULT_HEAD_LINES,
    tail_lines: int = DEFAULT_TAIL_LINES,
    max_lines: int = DEFAULT_MAX_LOG_LINES,
) -> dict | None:
    """None when `text` has at most `max_lines` lines (nothing to cut) or is empty. Otherwise a
    verdict dict shaped like classify_pytest()'s, rule="log-tail". Kept = the first
    `head_lines`, the last `tail_lines`, and every line matching the error/exception/traceback
    signal — deduped, kept in ORIGINAL order — plus a bracketed omitted-count marker line, e.g.
    "[142 lines omitted; run with RAW=1]"."""
    if not text:
        return None
    lines = text.splitlines()
    total = len(lines)
    if total <= max_lines:
        return None

    chars_before = len(text)
    tokens_before = estimate_tokens(text)

    head = lines[:head_lines]
    tail = lines[-tail_lines:] if tail_lines > 0 else []
    error_lines = [ln for ln in lines if _ERROR_LINE_RE.search(ln)]

    kept_lines = _dedup_keep_order(head + error_lines + tail)
    omitted = total - len(kept_lines)
    marker = f"[{max(omitted, 0)} lines omitted; run with RAW=1]"

    # Reconstruct by scanning the original lines once, keeping only members of the selected set,
    # in original order, with the omitted-count marker spliced in right after `head`. This keeps
    # the shape readable instead of "head glued to tail with error lines shuffled to the end".
    kept_set = set(kept_lines)
    ordered_kept = [ln for ln in lines if ln in kept_set]
    # de-dup ordered_kept too (a line could legitimately repeat verbatim in the source; we only
    # want to dedup within our SELECTED lines when the same physical selection reasons collide,
    # not collapse genuine repeats in head/tail) -- accept genuine repeats, this is display text.
    kept_text = "\n".join(head) + f"\n{marker}\n" + "\n".join(ln for ln in ordered_kept if ln not in head)
    chars_after = len(kept_text)
    return {
        "rule": "log-tail",
        "kept_text": kept_text,
        "chars_before": chars_before,
        "chars_after": chars_after,
        "tokens_before": tokens_before,
        "tokens_after": estimate_tokens(kept_text),
        "lines_total": total,
        "lines_kept": len(head) + len(ordered_kept),
        "lines_omitted": omitted,
    }


_SIGNATURE_BEAD_ID_RE = re.compile(r"\b(?:ga|wa|gt)-[a-z0-9]{4,10}\b")
_SIGNATURE_PATH_RE = re.compile(r"/[\w.-]+(?:/[\w.-]+){2,}")
_SIGNATURE_SHA_RE = re.compile(r"\b[0-9a-f]{7,40}\b")


def extract_signatures(text: str, max_signatures: int = 8) -> list[str]:
    """Pure, no-I/O: short distinctive substrings from `text` (bead/issue ids, absolute paths 3+
    components deep, git-sha-looking hex tokens, and the first ~80 chars of any error-shaped
    line) — used by the OFFLINE join (jev_cut_output_join.py) to check whether a later turn of
    the same session cited something from a block this front would have cut. Never raises;
    empty/None-like input -> []. Order is stable (first-seen) so two calls on the same text
    produce the same list, which matters for log determinism in tests."""
    if not text:
        return []
    seen: set[str] = set()
    out: list[str] = []

    def add(candidates: list[str]) -> None:
        for c in candidates:
            if len(out) >= max_signatures:
                return
            if c in seen:
                continue
            seen.add(c)
            out.append(c)

    add(_SIGNATURE_BEAD_ID_RE.findall(text))
    add(_SIGNATURE_PATH_RE.findall(text))
    add(_SIGNATURE_SHA_RE.findall(text))
    if len(out) < max_signatures:
        error_lines = [ln.strip()[:80] for ln in text.splitlines() if _ERROR_LINE_RE.search(ln) and ln.strip()]
        add(error_lines)
    return out[:max_signatures]


def classify_output(command: str, text: str) -> dict | None:
    """The one entrypoint the hook calls. `command` is the Bash command that produced `text`
    (used only to help recognize shape, e.g. a bare 'pytest'/'python -m pytest' invocation is a
    weak extra signal but NOT required — the text itself is authoritative, since a command can
    invoke pytest indirectly via a wrapper script). Returns None when text is under
    MIN_CHARS_TO_CONSIDER (too small to bother) or matches neither fixed shape — the caller
    should treat None as "ask Jev, or leave it alone", never as a verdict of its own."""
    if not text or len(text) < MIN_CHARS_TO_CONSIDER:
        return None
    verdict = classify_pytest(text)
    if verdict is not None:
        return verdict
    return classify_log_tail(text)


def _selftest() -> int:
    passed = 0
    failed = 0

    def ok(label: str, cond: bool) -> None:
        nonlocal passed, failed
        if cond:
            passed += 1
            print(f"  ok  {label}")
        else:
            failed += 1
            print(f"  FAIL {label}")

    # ---- estimate_tokens ----
    ok("estimate_tokens('') == 0", estimate_tokens("") == 0)
    ok("estimate_tokens(None-ish empty) == 0", estimate_tokens("") == 0)
    ok("estimate_tokens('x' * 22) == 10 (2.2 chars/token)", estimate_tokens("x" * 22) == 10)

    # ---- classify_output: too small -> None regardless of shape ----
    ok("tiny pytest-shaped text -> None (below MIN_CHARS_TO_CONSIDER)",
       classify_output("pytest", "= test session starts =\n1 passed") is None)
    ok("empty text -> None", classify_output("ls", "") is None)

    # ---- classify_pytest ----
    ok("non-pytest text -> classify_pytest returns None", classify_pytest("just some random text\nline2\n" * 100) is None)

    pytest_pass = (
        "============================= test session starts ==============================\n"
        + "\n".join(f"test_mod.py::test_{i} PASSED" for i in range(200))
        + "\n============================== 200 passed in 4.20s ===============================\n"
    )
    r = classify_pytest(pytest_pass)
    ok("pytest all-pass -> a verdict (not None)", r is not None)
    if r:
        ok("pytest all-pass rule id", r["rule"] == "pytest")
        ok("pytest all-pass: kept text has the summary line", "200 passed" in r["kept_text"])
        ok("pytest all-pass: kept text does NOT have any PASSED line (only the summary)", "PASSED" not in r["kept_text"])
        ok("pytest all-pass: cuts size down a lot", r["chars_after"] < r["chars_before"] / 5)

    pytest_fail = (
        "============================= test session starts ==============================\n"
        + "\n".join(f"test_mod.py::test_{i} PASSED" for i in range(150))
        + "\n_____________________________ test_thing_broken ______________________________\n"
        "def test_thing_broken():\n"
        ">       assert 1 == 2\n"
        "E       assert 1 == 2\n"
        "\n"
        "test_mod.py:42: AssertionError\n"
        "=========================== short test summary info ===========================\n"
        "FAILED test_mod.py::test_thing_broken - assert 1 == 2\n"
        "======================= 1 failed, 150 passed in 3.10s ========================\n"
    )
    r2 = classify_pytest(pytest_fail)
    ok("pytest with a failure -> a verdict", r2 is not None)
    if r2:
        ok("pytest failure: kept text has the failing test name", "test_thing_broken" in r2["kept_text"])
        ok("pytest failure: kept text has the assertion", "assert 1 == 2" in r2["kept_text"])
        ok("pytest failure: kept text has the final summary line", "1 failed, 150 passed" in r2["kept_text"])
        ok("pytest failure: kept text drops the 150 PASSED lines", r2["kept_text"].count("PASSED") == 0)
        ok("pytest failure: cuts size down a lot", r2["chars_after"] < r2["chars_before"] / 3)

    # ---- classify_log_tail ----
    short_log = "\n".join(f"line {i}" for i in range(50))
    ok("short log (under max_lines) -> None", classify_log_tail(short_log) is None)
    ok("empty text -> None (log-tail)", classify_log_tail("") is None)

    long_log_lines = [f"INFO step {i} ok" for i in range(300)]
    long_log_lines[150] = "ERROR: connection refused talking to db"
    long_log_lines[151] = "Traceback (most recent call last):"
    long_log = "\n".join(long_log_lines)
    r3 = classify_log_tail(long_log)
    ok("long log -> a verdict (not None)", r3 is not None)
    if r3:
        ok("long log: kept text has the head", "step 0 ok" in r3["kept_text"])
        ok("long log: kept text has the tail", "step 299 ok" in r3["kept_text"])
        ok("long log: kept text has the ERROR line even though it's in the middle", "connection refused" in r3["kept_text"])
        ok("long log: kept text has the Traceback line", "Traceback" in r3["kept_text"])
        ok("long log: has an omitted-count marker naming RAW=1", "lines omitted; run with RAW=1" in r3["kept_text"])
        ok("long log: cuts size down", r3["chars_after"] < r3["chars_before"])
        ok("long log: lines_total matches input", r3["lines_total"] == 300)

    # a long log with NO error-shaped lines at all must still cut (head+tail+marker), never
    # crash on "no error lines to interleave".
    plain_long_log = "\n".join(f"step {i} of 500 complete" for i in range(500))
    r4 = classify_log_tail(plain_long_log)
    ok("long log with zero error-shaped lines -> still a verdict", r4 is not None)
    if r4:
        ok("plain long log: head present", "step 0 of 500" in r4["kept_text"])
        ok("plain long log: tail present", "step 499 of 500" in r4["kept_text"])
        ok("plain long log: cuts size down", r4["chars_after"] < r4["chars_before"])

    # ---- classify_output: routes to the right rule, and unstructured -> None ----
    big_pytest_cmd_text = pytest_fail * 20  # push well past MIN_CHARS_TO_CONSIDER
    r5 = classify_output("python -m pytest", big_pytest_cmd_text)
    ok("classify_output routes a big pytest-shaped text to the pytest rule", r5 is not None and r5["rule"] == "pytest")

    big_plain_log = plain_long_log * 5
    r6 = classify_output("some-server --verbose", big_plain_log)
    ok("classify_output routes a big generic log to log-tail", r6 is not None and r6["rule"] == "log-tail")

    unstructured = ("a single giant JSON blob with no newlines at all " * 200)
    ok(
        "classify_output: large but neither pytest- nor line-shaped (single line, under max_lines) -> None (unstructured)",
        classify_output("curl ...", unstructured) is None,
    )

    # ---- extract_signatures ----
    ok("extract_signatures('') == []", extract_signatures("") == [])
    sig_text = (
        "processing ga-wk0qi2 now\n"
        "wrote /Users/athos/gt/.gascity-gastown-hq/scripts/cut_output_classifier.py\n"
        "commit abc1234def5678 failed\n"
        "ERROR: connection refused talking to db\n"
    )
    sigs = extract_signatures(sig_text)
    ok("extract_signatures finds the bead id", "ga-wk0qi2" in sigs)
    ok("extract_signatures finds the absolute path", any("cut_output_classifier.py" in s for s in sigs))
    ok("extract_signatures finds the sha-looking token", "abc1234def5678" in sigs)
    ok("extract_signatures finds the error line", any("connection refused" in s for s in sigs))
    ok("extract_signatures caps at max_signatures", len(extract_signatures(sig_text, max_signatures=2)) == 2)
    ok("extract_signatures is deterministic across calls", extract_signatures(sig_text) == extract_signatures(sig_text))
    ok("extract_signatures never duplicates a signature", len(sigs) == len(set(sigs)))

    print(f"\ncut_output_classifier selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(_selftest())
    print("usage: cut_output_classifier.py selftest", file=sys.stderr)
    sys.exit(1)

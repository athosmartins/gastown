#!/usr/bin/env python3
"""cut_output_classifier.py (ga-wk0qi2, child of ga-aijm2v) — the "regra fixa" half of the
cut-large-output SHADOW front: pure, no-I/O, no-network classification of a Bash command's
output into one of these shapes:

  1. "pytest": a pytest run whose last session reached its final summary banner. The rule only
     judges that session's own block (last "test session starts" header to its first banner) and keeps
     EVERYTHING outside it (an earlier run, a build step before it, `echo rc=$?` or stderr after the
     banner). Inside the block, kept = the FAILURES section and/or the short test summary, up to the
     banner (nothing failed -> nothing kept but the banner). Only setup noise, collection and PASSED
     lines inside the block are the omitted part.
  2. "log-tail": a generic long/log-shaped dump. Kept = head N + tail N + every line that looks
     like an error/exception/traceback signal, in original order. Everything else is omitted.
  3. "unknown": recognizably pytest, but not in a shape the rule can cut safely (killed/truncated
     mid-run, no final banner after the last session; or a banner that says failed/error while
     nothing in the output lists what failed). Nothing is omitted, everything is kept --
     the shadow log records it as unknown, distinct from both "cut" and "nothing to cut".
  4. "no-gain": a shape a rule recognized, but cutting it would not make the output shorter (every
     omitted run costs a "[N lines omitted]" marker). Nothing is omitted; a live rule would leave it
     alone. Its own state, so it is neither a phantom "0-token cut" nor an error.
  5. None ("unstructured"): output is large but does not match any fixed shape above. The
     caller (cut-output-shadow.py) is the one that decides what to do with an unstructured
     block (ask Jev), never this module — this module answers ONLY "does a fixed, no-AI rule
     apply here, and if so what would it keep".

SINGLE SOURCE (ga-wk0qi2 gate attempt 4): a classifier only chooses WHICH LINES to keep, and
_verdict_from_kept_lines() derives everything else from that one partition -- kept_text,
omitted_text, kept_spans/omitted_spans, rendered_text (what the agent would see, with omitted-run
markers), the counts. For every verdict each input line is in exactly one of kept/omitted, and
the two rebuild the input exactly; a classifier cannot report text as kept that it did not pick
from the input. The selftest checks this over real and synthetic outputs cut at many points.

THIRD STATE: classify_output() returns None when no fixed rule applies (including when the
output is simply too small to bother with) — None is "no fixed-rule verdict", never "cut
everything" or "cut nothing". A caller must not treat None as either extreme. Likewise rule
"unknown" is "could not read this, so did not cut", never "examined, nothing worth cutting".

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

# The `mode` of the rows this front writes to the shared jev-experiment.jsonl, and of the offline join's
# rows. Defined HERE because this module has no dependencies and is already imported by the hook
# (cut-output-shadow.py), the join and (through it) the report -- one definition, nothing to keep in sync.
# NOT "shadow": jev_experiment_report.summarize_shadow() owns every mode=="shadow" row and reads F0's
# agree/would_dispense fields, so this front's rows under that mode printed false "Jev unavailable" and
# negative-savings lines in the daily report (gate_run ga-75ya0i). Every sibling front has its own mode.
RECORD_MODE = "cut-output"
JOIN_MODE = "cut-output-join"
# A row that says "a large-output call was NOT measured, and why" (cut-output-shadow.py's engine and
# cut-output-shadow.sh's wrapper both write them). Without it a hook that dies on every call reads in the
# report exactly like a quiet day: "0 cases". Same mode as the measurement rows, its own experiment name.
ERROR_EXPERIMENT = "cut-output-error"

# The two hook events that carry a Bash call's output. PostToolUse fires only for a call that SUCCEEDED
# (exit 0) and carries tool_response.{stdout,stderr}; a call that exits non-zero fires PostToolUseFailure
# INSTEAD, with no tool_response and the whole merged output in `error` as "Exit code N\n<output>". Verified
# live on Claude Code 2.1.284 (gate_run ga-vrv1tz): registering only PostToolUse measured only the commands
# that worked, so any rate said nothing about the failed-command half (where a cut is most plausibly costly).
EVENT_SUCCESS = "PostToolUse"
EVENT_FAILURE = "PostToolUseFailure"

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

# pytest's own header line: "=== test session starts ===". The "=" padding is optional (some CI
# wrappers strip it) but the line must BE the header -- nothing else on it. The bare phrase anywhere in
# any line was too loose: a non-pytest log that merely said "new session starts here" became an
# "unreadable pytest run" (rule "unknown"), never reaching log-tail. Anchored with no nested quantifier,
# so it stays linear on a hostile 100k-wide "=====x" line.
_PYTEST_SESSION_RE = re.compile(r"^[\s=_-]*test session starts[\s=_-]*$", re.IGNORECASE)
# pytest's own trailing one-line summary banner, e.g. "===== 5 passed in 0.12s =====",
# "=== 2 failed, 3 passed in 1.02s ===", "==== no tests ran in 0.01s ====" (no digit-count phrase
# at all, printed whenever 0 tests are collected) or "=== 1 failed in 65.32s (0:01:05) ===" (runs
# over a minute append an H:MM:SS suffix). Matched against ONE LINE at a time and anchored on the
# STRUCTURAL shape pytest uses for every one of its final-summary variants -- "=" padding wrapping
# some text that ends in "in X.XXs" -- rather than enumerating outcome words or assuming "the last
# non-blank line of text", so anything a caller appends after the real pytest output (e.g. stderr)
# cannot displace it. A pytest run whose last session has no such line after it is NOT cut at all
# (classify_pytest returns rule "unknown"): a shape this regex misses degrades to "don't cut",
# never to a guessed summary.
# LINEAR on hostile lines: the "=" run must be followed by whitespace (`=+\s`), which fixes where
# `=+` ends. Without it `=+` and the following `.*` can split a long "=====" line n ways and each
# split rescans the line -- quadratic, tens of seconds on one 20k-char line inside a hook that runs
# on every pool Bash call.
_PYTEST_FINAL_SUMMARY_RE = re.compile(
    r"^=+\s.*\bin\s+[\d.]+s(?:\s*\(\d+:\d{2}:\d{2}\))?\s*=+\s*$",
    re.IGNORECASE,
)
# pytest's failure-section headers, matched per line: "=== FAILURES ===" and the per-test
# "___ test_name ___". Same linearity rule as above (`_{5,}\s` pins where the underscore run ends).
_PYTEST_FAILURES_HEADER_RE = re.compile(r"^_{5,}\s.*\s_{5,}\s*$|^={3,}\s*FAILURES\s*={3,}\s*$", re.IGNORECASE)
_PYTEST_SHORT_SUMMARY_RE = re.compile(r"short test summary info", re.IGNORECASE)
# The banner's own outcome words that mean "look at what failed": "2 failed", "1 error", "3 errors".
# \b keeps "xfailed" (an expected failure) from counting -- x and f are both word characters.
_PYTEST_BANNER_FAILURE_RE = re.compile(r"\b(?:failed|errors?)\b", re.IGNORECASE)


# The header Claude Code puts in front of a failed Bash call's output. ONE newline belongs to it; a blank
# first line of the output itself survives. Anchored at the very start: the same words further down are output.
# At most 4 digits: real codes are 0-255 (or a small negative). An unbounded \d+ handed int() a 5000-digit string
# from an error that merely STARTS with "Exit code 9999..." and int() refuses that (Python's digit limit) -- a
# "never raises" helper that raised. cut-output-shadow.sh's jq prefilter uses the same bound, so both agree.
_EXIT_CODE_HEADER_RE = re.compile(r"\AExit code (-?\d{1,4})(?:\n|\Z)")


def strip_exit_code_header(error: str) -> tuple[int | None, str]:
    """Pure. `error` is a PostToolUseFailure payload's `error` string. Returns (exit_code, output): the code
    and the output with the header removed, or (None, error) when the text does not start with the header.
    None means "the payload did not say", never 0 -- a timeout or an interrupted call carries no exit code,
    and not knowing it must not read as "exited 0". Never raises."""
    if not isinstance(error, str):
        return None, ""
    m = _EXIT_CODE_HEADER_RE.match(error)
    if not m:
        return None, error
    return int(m.group(1)), error[m.end():]


def estimate_tokens(text: str) -> int:
    """Never raises: empty/None-like input -> 0."""
    if not text:
        return 0
    return max(0, round(len(text) / CHARS_PER_TOKEN))


def _split_lines(text: str) -> tuple[list[str], list[int]]:
    """Pure. `text` as lines WITH their terminators (so "".join(lines) == text exactly, for any
    line-ending style splitlines() knows -- \\n, \\r\\n, \\x0c, \\u2028 ...) plus the char offset at
    which each line starts (`offsets[i]` .. `offsets[i+1]` is line i; len(offsets) == len(lines)+1)."""
    lines = text.splitlines(keepends=True)
    offsets = [0]
    for ln in lines:
        offsets.append(offsets[-1] + len(ln))
    return lines, offsets


def _verdict_from_kept_lines(rule: str, text: str, lines: list[str], offsets: list[int], kept_idx: set[int], **extra) -> dict:
    """The ONE place a verdict is built (ga-wk0qi2 gate feedback, attempt 4 + Mayor's directive).
    A classifier's whole job is to decide WHICH LINES of `text` to keep (`kept_idx`); everything
    else -- kept_text, omitted_text, the spans, the agent-facing rendered_text, every count -- is
    derived here from that single partition. Earlier versions built kept_text from ad-hoc pieces
    (kept_parts) and omitted_text from spans, two sources that any branch could make disagree: text
    reported as kept AND omitted, or a "kept" line that was never in the input.

    By construction, for every verdict: each line of `text` is in exactly one of kept/omitted;
    kept_spans + omitted_spans tile [0, len(text)) with no gap or overlap; kept_text and
    omitted_text are exactly the concatenation of their spans (no synthetic text -- a classifier
    cannot add a "kept" line that is not in the input, because it can only pick indices).
    `rendered_text` is what the agent WOULD see: kept lines in order, with one
    "[N lines omitted; run with RAW=1]" marker per omitted run. chars_after/tokens_after measure
    THAT, so the shadow number includes the marker's own cost."""
    total = len(lines)
    kept_spans: list[tuple[int, int]] = []
    omitted_spans: list[tuple[int, int]] = []
    rendered: list[str] = []
    lines_kept = 0
    i = 0
    while i < total:
        is_kept = i in kept_idx
        j = i
        while j < total and (j in kept_idx) == is_kept:
            j += 1
        span = (offsets[i], offsets[j])
        if is_kept:
            kept_spans.append(span)
            rendered.append(text[span[0]:span[1]])
            lines_kept += j - i
        else:
            omitted_spans.append(span)
            rendered.append(f"[{j - i} lines omitted; run with RAW=1]\n")
        i = j
    kept_text = "".join(text[s:e] for s, e in kept_spans)
    omitted_text = "".join(text[s:e] for s, e in omitted_spans)
    rendered_text = "".join(rendered)
    verdict = {
        "rule": rule,
        "kept_text": kept_text,
        "omitted_text": omitted_text,
        "rendered_text": rendered_text,
        "kept_spans": kept_spans,
        "omitted_spans": omitted_spans,
        "chars_before": len(text),
        "chars_after": len(rendered_text),
        "tokens_before": estimate_tokens(text),
        "tokens_after": estimate_tokens(rendered_text),
        "lines_total": total,
        "lines_kept": lines_kept,
        "lines_omitted": total - lines_kept,
    }
    verdict.update(extra)
    if rule not in ("unknown", "no-gain") and len(rendered_text) >= len(text):
        # A rule that would hand back as much text as it was given, or MORE, is not a cut: every omitted run
        # costs a "[N lines omitted; run with RAW=1]" marker, and on a log of alternating error/ok lines each
        # marker is longer than the one short line it replaces. A live rule would leave that output alone, so
        # the verdict says exactly that -- everything kept, nothing omitted (so the join has nothing to look
        # for), its own rule name, and 0 saved tokens that are TRUE rather than a max(0, negative) clamp.
        # (gate_run ga-vrv1tz: such cases were logged as "0-token cuts" and their omitted lines sent to the join.)
        return _verdict_from_kept_lines("no-gain", text, lines, offsets, set(range(total)), reason=f"{rule}-would-not-shrink")
    return verdict


def _unknown_verdict(text: str, reason: str) -> dict:
    """The third state, made explicit: the text is recognizably the kind of thing a rule handles
    but not in a shape that rule can cut safely (e.g. a pytest run with no final summary banner --
    killed or truncated mid-run). Nothing is omitted, everything is kept, rule == "unknown". Never
    an invented "trailing" line: not knowing how to cut means not cutting (the shadow log then
    records the case as unknown, distinct from both "cut" and "nothing to cut")."""
    lines, offsets = _split_lines(text)
    return _verdict_from_kept_lines("unknown", text, lines, offsets, set(range(len(lines))), reason=reason)


def classify_pytest(text: str) -> dict | None:
    """None if `text` is not recognizably a pytest run (no "test session starts" line). Otherwise
    a verdict dict from _verdict_from_kept_lines().

    The rule understands ONE thing: a pytest session block, from the LAST "test session starts" header to the
    FIRST final-summary banner after it (pytest's own "=== ... in X.XXs ===" line, matched by shape, never
    assumed to be the last line of `text`). It may cut lines INSIDE that block and nothing else: every line
    before the header (an earlier pytest run, a build step) and every line from the banner on (the banner
    itself, `echo rc=$?`, stderr appended by the caller) is kept, because the rule did not recognize it.
    The FIRST banner, not the last: a banner-shaped line printed after the real one by some later command
    must not become "the summary" and pull the real one into the cut region.

    Inside the block: kept = everything from the first FAILURES header (or, with no FAILURES section, the
    "short test summary info" header) up to the banner -- the tracebacks AND pytest's own compact failure
    list. Omitted = the setup/collection noise and the routine PASSED lines before that point. The banner
    says failed/error but nothing in the block lists what failed (`-rN --tb=no`) -> we do not know what
    failed, so the rule does not cut (rule "unknown").

      * rule "pytest": the block above was cut (something inside it omitted).
      * rule "unknown" (keep everything, omit nothing): the last session has NO banner after it -- output
        killed/truncated mid-run, or a banner that belongs to an earlier, already-finished run -- or the
        banner says failed/error with no failure listing of any kind. Nothing to anchor on, so no cut.
      * rule "no-gain" (from _verdict_from_kept_lines): the cut would not have made the output shorter."""
    if not text:
        return None
    lines, offsets = _split_lines(text)

    session_idx = None
    for i, ln in enumerate(lines):
        if _PYTEST_SESSION_RE.search(ln):
            session_idx = i
    if session_idx is None:
        return None
    banner_idx = next(
        (i for i in range(session_idx + 1, len(lines)) if _PYTEST_FINAL_SUMMARY_RE.match(lines[i])),
        None,
    )
    if banner_idx is None:
        return _unknown_verdict(text, "pytest-no-final-summary")

    # Everything outside [session_idx, banner_idx) is kept: before the header, and the banner onwards.
    kept_idx: set[int] = set(range(0, session_idx)) | set(range(banner_idx, len(lines)))
    failure_idx = next(
        (i for i in range(session_idx + 1, banner_idx) if _PYTEST_FAILURES_HEADER_RE.match(lines[i])),
        None,
    )
    short_idx = next(
        (i for i in range(session_idx + 1, banner_idx) if _PYTEST_SHORT_SUMMARY_RE.search(lines[i])),
        None,
    )
    listing_start = failure_idx if failure_idx is not None else short_idx
    if listing_start is not None:
        kept_idx.update(range(listing_start, banner_idx))
    elif _PYTEST_BANNER_FAILURE_RE.search(lines[banner_idx]):
        # The banner says something failed/errored, yet the block has no FAILURES section and no short
        # summary either. "No FAILURES header" is NOT "nothing failed": we do not know what failed, so we do
        # not cut (rule "unknown") instead of keeping a banner that hides it.
        return _unknown_verdict(text, "pytest-failed-no-failure-listing")
    return _verdict_from_kept_lines("pytest", text, lines, offsets, kept_idx)


def classify_log_tail(
    text: str,
    head_lines: int = DEFAULT_HEAD_LINES,
    tail_lines: int = DEFAULT_TAIL_LINES,
    max_lines: int = DEFAULT_MAX_LOG_LINES,
) -> dict | None:
    """None when `text` has at most `max_lines` lines (nothing to cut) or is empty. Otherwise a
    verdict dict shaped like classify_pytest()'s, rule="log-tail". Kept = the first
    `head_lines`, the last `tail_lines`, and every line matching the error/exception/traceback
    signal, chosen by LINE INDEX (never by re-matching line content -- a physically-omitted line
    that happens to share text with a kept line must still count as omitted; ga-wk0qi2 gate
    feedback, attempt 1, blocking issue 2). The verdict itself is built by
    _verdict_from_kept_lines(), so its rendered_text carries one "[N lines omitted; run with
    RAW=1]" marker per omitted run, e.g. "[142 lines omitted; run with RAW=1]"."""
    if not text:
        return None
    lines, offsets = _split_lines(text)
    total = len(lines)
    if total <= max_lines:
        return None

    head_end = min(head_lines, total)
    tail_start = max(total - tail_lines, head_end) if tail_lines > 0 else total

    kept_idx: set[int] = set(range(0, head_end))
    if tail_lines > 0:
        kept_idx.update(range(tail_start, total))
    kept_idx.update(i for i, ln in enumerate(lines) if _ERROR_LINE_RE.search(ln))
    return _verdict_from_kept_lines("log-tail", text, lines, offsets, kept_idx)


_SIGNATURE_BEAD_ID_RE = re.compile(r"\b(?:ga|wa|gt)-[a-z0-9]{4,10}\b")
_SIGNATURE_PATH_RE = re.compile(r"/[\w.-]+(?:/[\w.-]+){2,}")
# A sha-looking token has BOTH a hex letter and a digit. A bare digit run (byte count, epoch, id) filled
# the 8-signature budget ahead of real error-line snippets and substring-matched unrelated later lines
# (JSON usage counters), pushing referenced_later up; a letters-only word ("defaced") is a word.
_SIGNATURE_SHA_RE = re.compile(r"\b(?=[0-9a-f]*[a-f])(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\b")


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

    # ---- classify_pytest: regression, ga-wk0qi2 gate feedback attempt 1, blocking issue 1.
    # cut-output-shadow.py's process() builds `text` as stdout + "\n" + stderr whenever stderr is
    # non-empty -- i.e. ANYTHING after pytest's own stdout, including a routine stderr warning on
    # an all-pass run, used to become "the last non-blank line" and silently replace the real
    # summary. The fix must find the summary by its own banner shape, not by position. ----
    pytest_pass_with_stderr = pytest_pass + "\nDeprecationWarning: something something"
    r_stderr = classify_pytest(pytest_pass_with_stderr)
    ok("pytest + trailing stderr-shaped text -> still a verdict", r_stderr is not None)
    if r_stderr:
        ok("regression (blocking issue 1): kept text still has the real summary", "200 passed" in r_stderr["kept_text"])
        ok(
            "regression (blocking issue 1): kept text is not just the stderr line",
            r_stderr["kept_text"].strip() != "DeprecationWarning: something something",
        )
    # same repro but with a FAILURE present too, since the trailing-summary logic runs regardless
    pytest_fail_with_stderr = pytest_fail + "\nDeprecationWarning: something something"
    r2_stderr = classify_pytest(pytest_fail_with_stderr)
    ok("pytest failure + trailing stderr-shaped text -> still a verdict", r2_stderr is not None)
    if r2_stderr:
        ok("regression (blocking issue 1): failure case summary survives trailing stderr", "1 failed, 150 passed" in r2_stderr["kept_text"])

    # ---- classify_pytest: regression, ga-wk0qi2 gate feedback attempt 3, blocking issue 1.
    # attempt 1's fix only recognized pytest's DIGIT-COUNT summary banners ("N passed", "N
    # failed, M passed", ...). pytest's "no tests ran in X.XXs" banner (printed when 0 tests are
    # collected) has no digit-count phrase at all, so it fell through to the same "last non-blank
    # line" fallback that a trailing stderr line displaces -- reproducing the exact bug class on
    # an uncovered shape, not a new bug. The fix generalizes to ANY "=" + "in X.XXs" pytest
    # banner shape, so this must survive the identical trailing-stderr scenario. ----
    pytest_no_tests_ran = (
        "============================= test session starts ==============================\n"
        "collected 0 items\n"
        + "\n".join(f"DeprecationWarning: warning {i}" for i in range(40))
        + "\n=================================== no tests ran in 0.01s ===================================\n"
        "\nDeprecationWarning: something unrelated printed to stderr by a plugin"
    )
    r_no_tests = classify_pytest(pytest_no_tests_ran)
    ok("pytest 'no tests ran' + trailing stderr-shaped text -> still a verdict", r_no_tests is not None)
    if r_no_tests:
        ok(
            "regression (attempt 3, blocking issue 1): kept text has the 'no tests ran' banner",
            "no tests ran" in r_no_tests["kept_text"],
        )
        ok(
            "regression (attempt 3, blocking issue 1): kept text is not just the trailing stderr line",
            r_no_tests["kept_text"].strip() != "DeprecationWarning: something unrelated printed to stderr by a plugin",
        )

    # ---- classify_pytest: omitted_text is position-based, not content-based ----
    ok(
        "pytest all-pass: omitted_text does not contain the summary line",
        r is not None and "200 passed" not in r["omitted_text"],
    )
    ok(
        "pytest all-pass: omitted_text contains the dropped PASSED lines",
        r is not None and "PASSED" in r["omitted_text"],
    )

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
        ok("long log: rendered_text has an omitted-count marker naming RAW=1", "lines omitted; run with RAW=1" in r3["rendered_text"])
        ok("long log: kept_text is pure source text -- no synthetic marker in it", "lines omitted" not in r3["kept_text"])
        ok("long log: cuts size down", r3["chars_after"] < r3["chars_before"])
        ok("long log: lines_total matches input", r3["lines_total"] == 300)
        ok("long log: omitted_text has the dropped middle noise", "step 200 ok" in r3["omitted_text"])
        ok("long log: omitted_text does not have a head line", "step 0 ok" not in r3["omitted_text"])
        ok("long log: omitted_text does not have a tail line", "step 299 ok" not in r3["omitted_text"])

    # ---- classify_log_tail: regression, ga-wk0qi2 gate feedback attempt 1, blocking issue 2.
    # A line placed once in the (kept) head and again, verbatim, deep in the (should-be-omitted)
    # middle must still count that middle occurrence as omitted -- selection by index, not by
    # re-matching line text against the whole file. ----
    dup_line = "processing ga-dupe99 at /Users/athos/gt/dup/path.py"
    dup_lines = [dup_line] + [f"noise {i}" for i in range(300)]
    dup_lines[150] = dup_line  # exact same text as the head line, physically in the omitted middle
    dup_log = "\n".join(dup_lines)
    r_dup = classify_log_tail(dup_log)
    ok("duplicate-line log -> a verdict (not None)", r_dup is not None)
    if r_dup:
        ok(
            "regression (blocking issue 2): the middle occurrence of a head-duplicated line is still in omitted_text",
            r_dup["omitted_text"].count(dup_line) == 1,
        )
        ok(
            "regression (blocking issue 2): kept_text still has exactly the head's one occurrence",
            r_dup["kept_text"].count(dup_line) == 1,
        )

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

    # =========================================================================================
    # ga-wk0qi2 gate feedback, attempt 4 (gate_run ga-1k8gzc) + Mayor's class-level directive:
    # kept_text and omitted_text used to come from TWO independent sources (kept_parts vs. spans),
    # so any branch that added kept text without adding its span reported the same text as kept AND
    # omitted. The invariant below is the class, not the reported instance: for EVERY verdict,
    # every line of the input is in exactly one of kept / omitted, and the two together rebuild the
    # input. Checked over real + synthetic texts cut at many points (mid-test, no FAILURES, no
    # banner, mid-banner, mid-line), through every classify_* entrypoint.
    # =========================================================================================
    from collections import Counter
    import random

    marker_line_re = re.compile(r"^\[\d+ lines omitted; run with RAW=1\]$")

    def overlap_problems(text: str, verdict: dict) -> list[str]:
        """Text-level oracle, deliberately independent of how a verdict is built: a multiset of
        non-blank stripped lines. kept + omitted must equal the original -- an EXTRA line means the
        same content was reported as both kept and omitted; a MISSING line means content was lost."""
        def norm(s: str) -> Counter:
            return Counter(ln.strip() for ln in s.splitlines() if ln.strip())
        kept = Counter({k: v for k, v in norm(verdict["kept_text"]).items() if not marker_line_re.match(k)})
        omitted = norm(verdict["omitted_text"])
        original = norm(text)
        combined = kept + omitted
        problems = []
        if combined != original:
            extra = combined - original
            missing = original - combined
            if extra:
                problems.append(f"reported as kept AND omitted (or invented): {list(extra)[:2]!r}")
            if missing:
                problems.append(f"lost (neither kept nor omitted): {list(missing)[:2]!r}")
        return problems

    def span_problems(text: str, verdict: dict) -> list[str]:
        """Structural oracle: kept_spans + omitted_spans tile [0, len(text)) exactly (no gap, no
        overlap, no empty span), every span starts on a line boundary, and kept_text/omitted_text
        are EXACTLY the concatenation of their spans (no synthetic text, single source)."""
        ks, os_ = verdict.get("kept_spans"), verdict.get("omitted_spans")
        if ks is None or os_ is None:
            return ["verdict carries no kept_spans/omitted_spans"]
        problems = []
        line_starts = {0}
        pos = 0
        for ln in text.splitlines(keepends=True):
            pos += len(ln)
            line_starts.add(pos)
        cursor = 0
        for s, e in sorted(list(ks) + list(os_)):
            if s != cursor:
                problems.append(f"gap or overlap: expected span to start at {cursor}, got {s}")
            if e <= s:
                problems.append(f"empty/inverted span ({s},{e})")
            if s not in line_starts:
                problems.append(f"span starts mid-line at {s}")
            cursor = e
        if cursor != len(text):
            problems.append(f"spans end at {cursor}, text is {len(text)} chars")
        if "".join(text[s:e] for s, e in ks) != verdict["kept_text"]:
            problems.append("kept_text is not exactly the concatenation of kept_spans")
        if "".join(text[s:e] for s, e in os_) != verdict["omitted_text"]:
            problems.append("omitted_text is not exactly the concatenation of omitted_spans")
        return problems

    real_pytest_fail = (
        "============================= test session starts ==============================\n"
        "platform darwin -- Python 3.14.5, pytest-9.0.3, pluggy-1.6.0\n"
        "rootdir: /work/proj\n"
        "plugins: anyio-4.13.0\n"
        "collected 34 items\n"
        "\n"
        "test_real.py ................................FF                          [100%]\n"
        "\n"
        "=================================== FAILURES ===================================\n"
        "_________________________________ test_broken __________________________________\n"
        "\n"
        "    def test_broken():\n"
        '        data = {"a": 1}\n'
        '>       assert data["a"] == 2\n'
        "E       assert 1 == 2\n"
        "\n"
        "test_real.py:14: AssertionError\n"
        "_________________________________ test_raises __________________________________\n"
        "\n"
        "    def test_raises():\n"
        '>       raise ValueError("boom in fixture setup")\n'
        "E       ValueError: boom in fixture setup\n"
        "\n"
        "test_real.py:17: ValueError\n"
        "=============================== warnings summary ===============================\n"
        "test_real.py::test_ok_2\n"
        "  /work/proj/test_real.py:6: DeprecationWarning: legacy thing\n"
        '    warnings.warn("legacy thing", DeprecationWarning)\n'
        "\n"
        "-- Docs: https://docs.pytest.org/en/stable/how-to/capture-warnings.html\n"
        "=========================== short test summary info ============================\n"
        "FAILED test_real.py::test_broken - assert 1 == 2\n"
        "FAILED test_real.py::test_raises - ValueError: boom in fixture setup\n"
        "=================== 2 failed, 32 passed, 1 warning in 0.12s ====================\n"
    )

    # ---- the reported case (gate_run ga-1k8gzc, blocking issue 1): pytest session start, no
    # FAILURES section, and NO final banner (output killed/truncated mid-run). The old fallback
    # invented a "trailing" line, kept it, and never gave it a span -- so omitted_text was the
    # ENTIRE text while kept_text was one of its own lines. Now: "don't know how to cut" -> keep
    # everything, rule "unknown", nothing omitted. ----
    truncated_no_banner = pytest_pass[: pytest_pass.index("test_mod.py::test_120")] + "test_mod.py::test_12"
    r_trunc = classify_pytest(truncated_no_banner)
    ok("reported case: truncated pytest (no failures, no banner) -> a verdict, not None", r_trunc is not None)
    if r_trunc:
        ok("reported case: state is 'unknown' (cannot cut), not a pytest cut", r_trunc["rule"] == "unknown")
        ok("reported case: nothing is omitted", r_trunc["omitted_text"] == "")
        ok("reported case: everything is kept, verbatim", r_trunc["kept_text"] == truncated_no_banner)
        ok("reported case: no line is both kept and omitted", overlap_problems(truncated_no_banner, r_trunc) == [])
        ok("reported case: chars_after == chars_before (no cut claimed)", r_trunc["chars_after"] == r_trunc["chars_before"])

    # sibling shape: cut inside a failure body, no banner. The FAILURES-present sub-case used to keep the
    # last line twice (body span AND trailing); now it is the same 'unknown' state.
    fail_body_cut = pytest_fail[: pytest_fail.index("short test summary")]
    fail_body_cut = fail_body_cut[: fail_body_cut.rindex("\n")]  # drop the partial banner line
    r_fail_cut = classify_pytest(fail_body_cut)
    ok("failure-body cut, no banner -> unknown, keep everything",
       r_fail_cut is not None and r_fail_cut["rule"] == "unknown" and r_fail_cut["kept_text"] == fail_body_cut and r_fail_cut["omitted_text"] == "")

    # sibling shape: a COMPLETE earlier run followed by a new session that never finished. The old run's
    # banner must not be taken as the summary of the run that is actually incomplete.
    stale_banner_then_new_session = pytest_pass + "\n============ test session starts ============\ntest_mod.py::test_0 PASSED\n"
    r_stale = classify_pytest(stale_banner_then_new_session)
    ok("stale banner from an earlier run + new unfinished session -> unknown",
       r_stale is not None and r_stale["rule"] == "unknown" and r_stale["omitted_text"] == "")

    # classify_output must surface 'unknown' as the verdict (not fall through to log-tail, which would
    # quietly reassign a pytest-shaped output the classifier could not read).
    big_truncated = pytest_pass[: pytest_pass.index("test_mod.py::test_150")] + "test_mod.py::test_15"
    r_big_trunc = classify_output("pytest", big_truncated)
    ok("classify_output: big truncated pytest -> 'unknown' (not silently re-routed to log-tail)",
       r_big_trunc is not None and r_big_trunc["rule"] == "unknown" and r_big_trunc["omitted_text"] == "")

    # ---- pytest's own "(H:MM:SS)" suffix on long runs is part of the banner shape ----
    long_run_banner = pytest_fail.replace("1 failed, 150 passed in 3.10s", "1 failed, 150 passed in 65.32s (0:01:05)")
    r_long_run = classify_pytest(long_run_banner)
    ok("long-run banner '... in 65.32s (0:01:05) ===' is recognized as the pytest summary",
       r_long_run is not None and r_long_run["rule"] == "pytest" and "65.32s (0:01:05)" in r_long_run["kept_text"])

    # ---- FAILURES present, NO short-summary section, trailing stderr after the banner: the body
    # must stop at the banner (not swallow it + the stderr), and the banner must be kept exactly once ----
    fail_no_short = (
        pytest_fail[: pytest_fail.index("=========================== short test summary info")]
        + "======================= 1 failed, 150 passed in 3.10s ========================\n"
        + "StderrNoise: something a plugin printed to stderr\n"
    )
    r_no_short = classify_pytest(fail_no_short)
    ok("failures + no short-summary + trailing stderr -> a pytest verdict", r_no_short is not None and r_no_short["rule"] == "pytest")
    if r_no_short and r_no_short["rule"] == "pytest":
        ok("banner is kept exactly once (body span does not swallow it)", r_no_short["kept_text"].count("1 failed, 150 passed") == 1)
        # what follows pytest's own banner is not pytest output: the rule does not recognize it, so it keeps it
        # (it used to omit it -- gate_run ga-vrv1tz, medium finding)
        ok("trailing stderr after the banner is KEPT (not pytest output, not the rule's to judge) and kept exactly once",
           r_no_short["kept_text"].count("StderrNoise") == 1 and "StderrNoise" not in r_no_short["omitted_text"])

    # ---- real captured pytest output ----
    r_real = classify_pytest(real_pytest_fail)
    ok("real pytest capture -> pytest rule", r_real is not None and r_real["rule"] == "pytest")
    if r_real and r_real["rule"] == "pytest":
        ok("real capture: both failures kept", "test_broken" in r_real["kept_text"] and "boom in fixture setup" in r_real["kept_text"])
        ok("real capture: final summary kept", "2 failed, 32 passed, 1 warning in 0.12s" in r_real["kept_text"])
        ok("real capture: collection/rootdir noise omitted", "rootdir:" in r_real["omitted_text"] and "rootdir:" not in r_real["kept_text"])
        original_lines = set(real_pytest_fail.splitlines())
        ok("real capture: kept_text only ever contains WHOLE lines of the original (no partial banner)",
           all(ln in original_lines for ln in r_real["kept_text"].splitlines()))

    # ---- gate_run ga-qxm60a, medium finding (third state): "no FAILURES section found" was read as
    # "nothing failed". `pytest --tb=no` (or any run whose only failure listing is the "short test
    # summary info" section) has failures but no FAILURES header, so kept was the banner alone and the
    # FAILED test names went to omitted_text -- while a module comment promised "a shape this misses
    # degrades to don't cut". The banner itself says whether something failed; when it does, the failure
    # listing must be in kept, in whichever form pytest printed it, or the rule does not cut at all. ----
    tb_no_head = (
        "============================= test session starts ==============================\n"
        "platform darwin -- Python 3.14.5, pytest-9.0.3, pluggy-1.6.0\n"
        "rootdir: /work/proj\n"
        "collected 120 items\n"
        "\n"
    )
    tb_no_body = "".join(f"test_x.py::test_{i} {'FAILED' if i in (7, 63) else 'PASSED'}  [{i}%]\n" for i in range(120))
    tb_no_short = (
        "=========================== short test summary info ============================\n"
        "FAILED test_x.py::test_7 - assert 1 == 2\n"
        "FAILED test_x.py::test_63 - ValueError: boom\n"
    )
    tb_no_banner = "=================== 2 failed, 118 passed in 0.50s ====================\n"
    pytest_tb_no = tb_no_head + tb_no_body + tb_no_short + tb_no_banner
    r_tb = classify_output("pytest --tb=no -v", pytest_tb_no)
    ok("--tb=no run with failures -> a pytest verdict", r_tb is not None and r_tb["rule"] == "pytest")
    if r_tb and r_tb["rule"] == "pytest":
        ok("--tb=no: the FAILED test names (short test summary) are KEPT", "FAILED test_x.py::test_7 - assert 1 == 2" in r_tb["kept_text"] and "FAILED test_x.py::test_63 - ValueError: boom" in r_tb["kept_text"])
        ok("--tb=no: the banner is kept", "2 failed, 118 passed" in r_tb["kept_text"])
        ok("--tb=no: the failed test names are NOT left only in omitted_text", "test_7 - assert 1 == 2" not in r_tb["omitted_text"])
        ok("--tb=no: the 118 routine PASSED lines are still cut", "PASSED" not in r_tb["kept_text"] and "PASSED" in r_tb["omitted_text"])
        ok("--tb=no: no line is both kept and omitted", overlap_problems(pytest_tb_no, r_tb) == [] and span_problems(pytest_tb_no, r_tb) == [])
    pytest_tb_no_no_listing = tb_no_head + tb_no_body + tb_no_banner  # e.g. -rN --tb=no: the banner says failed, nothing lists what
    r_tb_none = classify_output("pytest --tb=no -rN -v", pytest_tb_no_no_listing)
    ok(
        "banner says 'failed' but no failure listing exists anywhere -> 'unknown' (do not cut), not a banner-only cut",
        r_tb_none is not None and r_tb_none["rule"] == "unknown" and r_tb_none["omitted_text"] == "" and r_tb_none["kept_text"] == pytest_tb_no_no_listing,
    )
    pytest_collect_error = (
        tb_no_head + tb_no_body
        + "=========================== short test summary info ============================\n"
        "ERROR test_y.py - ImportError: no module named thing\n"
        "=================================== 1 error in 0.10s ===================================\n"
    )
    r_err = classify_output("pytest --tb=no", pytest_collect_error)
    ok("banner says 'error' -> the ERROR line of the short summary is kept",
       r_err is not None and r_err["rule"] == "pytest" and "ERROR test_y.py - ImportError" in r_err["kept_text"])
    pytest_x_only = tb_no_head + tb_no_body.replace("FAILED", "XFAIL") + "=================== 118 passed, 2 xfailed, 1 xpassed in 0.50s ====================\n"
    r_x = classify_output("pytest -v", pytest_x_only)
    ok("'xfailed'/'xpassed' in the banner are not failures: still a plain pytest cut (banner only), not 'unknown'",
       r_x is not None and r_x["rule"] == "pytest" and "118 passed, 2 xfailed" in r_x["kept_text"] and r_x["kept_text"].count("\n") == 1)

    # ---- gate_run ga-qxm60a, low findings: signatures and the pytest-shape gate were both too loose ----
    sig_noise = extract_signatures("size 104857600 bytes at epoch 1790626971, sha abc1234def5678, count 1234567, word defaced")
    ok("signatures: a bare digit run (byte count, epoch) is not a sha-looking token", not any(s.isdigit() for s in sig_noise))
    ok("signatures: a word made only of a-f letters ('defaced') is not a sha-looking token", "defaced" not in sig_noise)
    ok("signatures: a real short/long sha (letters AND digits) is still found", "abc1234def5678" in sig_noise)
    log_mentions_phrase = "\n".join(["tmux: new session starts here"] + [f"INFO step {i} ok" for i in range(400)])
    r_phrase = classify_output("cmd", log_mentions_phrase)
    ok(
        "a non-pytest log that merely MENTIONS 'session starts' is a log-tail cut, not an 'unreadable pytest run'",
        r_phrase is not None and r_phrase["rule"] == "log-tail" and r_phrase["omitted_text"] != "",
    )
    pytest_stripped_padding = pytest_pass.replace("============================= test session starts ==============================", "test session starts")
    r_stripped = classify_pytest(pytest_stripped_padding)
    ok("a pytest header whose '=' padding was stripped by a wrapper is still recognized",
       r_stripped is not None and r_stripped["rule"] == "pytest" and "200 passed" in r_stripped["kept_text"])

    # ---- gate_run ga-vrv1tz, medium finding: the pytest rule judged the WHOLE output but only understands ONE
    # pytest session. Everything outside the block it recognized -- an earlier run's failures, text before the
    # session header, and whatever follows the banner (`echo rc=$?`, stderr) -- was silently omitted, and a
    # banner-SHAPED line printed after the real one ("=== build finished in 5s ===") replaced the real summary
    # (the LAST banner-shaped line won). The rule now claims only [last session header, that session's FIRST
    # banner) and keeps every other line: the one thing it may cut is what it positively recognized. ----
    r_two = classify_pytest(pytest_fail + pytest_pass)
    ok("two pytest runs (failing, then passing) -> a pytest verdict", r_two is not None and r_two["rule"] == "pytest")
    if r_two and r_two["rule"] == "pytest":
        ok("two runs: the EARLIER run's failure and summary are kept (the rule only judges the last session)",
           "test_thing_broken" in r_two["kept_text"] and "1 failed, 150 passed" in r_two["kept_text"])
        ok("two runs: the last run's summary is kept", "200 passed" in r_two["kept_text"])
        ok("two runs: the last run's routine PASSED lines are still cut", "test_mod.py::test_199 PASSED" in r_two["omitted_text"])
        ok("two runs: nothing of the earlier run is in omitted_text",
           "test_thing_broken" not in r_two["omitted_text"] and "150 passed" not in r_two["omitted_text"])
    r_rc = classify_pytest(pytest_fail + "rc=1\n")
    ok("`pytest; echo rc=$?`: the exit-code line after the banner is kept, not omitted",
       r_rc is not None and r_rc["rule"] == "pytest" and "rc=1" in r_rc["kept_text"] and "rc=1" not in r_rc["omitted_text"])
    r_pre = classify_pytest("cd /work/proj && make build\nbuild step 1 ok\nbuild step 2 ok\n" + pytest_pass)
    ok("output BEFORE the pytest session header (a build step) is kept, not omitted",
       r_pre is not None and r_pre["rule"] == "pytest" and "build step 2 ok" in r_pre["kept_text"] and "build step" not in r_pre["omitted_text"])
    r_fake = classify_pytest(pytest_fail + "=== build finished in 5.0s ===\n")
    ok("a banner-SHAPED line after the real banner does not replace it: the real summary is kept AND the later line is kept",
       r_fake is not None and r_fake["rule"] == "pytest" and "1 failed, 150 passed" in r_fake["kept_text"]
       and "build finished in 5.0s" in r_fake["kept_text"] and "1 failed, 150 passed" not in r_fake["omitted_text"])
    r_fail_short = classify_pytest(pytest_fail)
    ok("FAILURES present: pytest's own compact failure list (short test summary info) is kept along with the tracebacks",
       r_fail_short is not None and "FAILED test_mod.py::test_thing_broken" in r_fail_short["kept_text"]
       and "FAILED test_mod.py::test_thing_broken" not in r_fail_short["omitted_text"])

    # ---- gate_run ga-vrv1tz, low finding: a rule that would hand back MORE text than it was given is not a cut.
    # 400 alternating ERROR/ok lines: every 'ok' line between two kept ERROR lines became its own
    # "[1 lines omitted; run with RAW=1]" marker, longer than the line it replaced -- logged as a 0-token "cut"
    # (max(0, ...) hid the negative) whose omitted lines fed the join as if something had been cut. ----
    alternating = "\n".join(f"ERROR: step {i} failed" if i % 2 else f"INFO ok {i}" for i in range(400))
    r_alt = classify_log_tail(alternating)
    ok("alternating ERROR/ok log: the rule would ENLARGE the output -> 'no-gain' (an explicit state), not a cut",
       r_alt is not None and r_alt["rule"] == "no-gain")
    if r_alt:
        ok("no-gain: nothing is omitted and the output is unchanged", r_alt["omitted_text"] == "" and r_alt["kept_text"] == alternating
           and r_alt["chars_after"] == r_alt["chars_before"] and r_alt["tokens_after"] == r_alt["tokens_before"])
        ok("no-gain: says which rule it was and why", r_alt.get("reason") == "log-tail-would-not-shrink")
    r_alt_out = classify_output("cmd", alternating)
    ok("classify_output surfaces 'no-gain' (not None: the shape was recognized, it is just not worth cutting)",
       r_alt_out is not None and r_alt_out["rule"] == "no-gain")
    r_real_cut = classify_log_tail(long_log)
    ok("a log that does shrink is still a plain log-tail cut", r_real_cut is not None and r_real_cut["rule"] == "log-tail"
       and r_real_cut["chars_after"] < r_real_cut["chars_before"])

    # ---- gate_run ga-vrv1tz, blocking issue 1: a Bash call that exits non-zero reaches the hook as
    # PostToolUseFailure, whose only payload is `error` = "Exit code N\n<merged stdout+stderr>" (verified live
    # on Claude Code 2.1.284). strip_exit_code_header() is the one place that header is understood. ----
    ok("strip_exit_code_header: 'Exit code 1' header is split off, output preserved exactly",
       strip_exit_code_header("Exit code 1\nabc\ndef") == (1, "abc\ndef"))
    ok("strip_exit_code_header: multi-digit and negative codes", strip_exit_code_header("Exit code 137\nx") == (137, "x")
       and strip_exit_code_header("Exit code -1\nx") == (-1, "x"))
    ok("strip_exit_code_header: only ONE newline belongs to the header (a blank first output line survives)",
       strip_exit_code_header("Exit code 2\n\nfoo") == (2, "\nfoo"))
    ok("strip_exit_code_header: a header with no output at all", strip_exit_code_header("Exit code 3") == (3, ""))
    ok("strip_exit_code_header: an error that is not an exit-code error -> (None, the whole text): not knowing the code is None, not 0",
       strip_exit_code_header("Command timed out after 120s\nstuff") == (None, "Command timed out after 120s\nstuff"))
    ok("strip_exit_code_header: the header is only recognized at the START", strip_exit_code_header("x\nExit code 1\ny") == (None, "x\nExit code 1\ny"))
    ok("strip_exit_code_header: never raises on odd input", strip_exit_code_header("") == (None, "")
       and strip_exit_code_header(None) == (None, ""))  # type: ignore[arg-type]
    huge_digits = "Exit code " + "9" * 5000 + "\nz"
    try:
        huge_result, huge_raised = strip_exit_code_header(huge_digits), None
    except Exception as e:  # noqa: BLE001
        huge_result, huge_raised = None, type(e).__name__
    ok(f"strip_exit_code_header: a 5000-digit 'exit code' is not a header and does not raise (raised: {huge_raised})",
       huge_raised is None and huge_result == (None, huge_digits))
    ok("strip_exit_code_header: a 4-digit code is still a header, a 5-digit one is not",
       strip_exit_code_header("Exit code 1234\nx") == (1234, "x") and strip_exit_code_header("Exit code 12345\nx")[0] is None)

    # ---- the property, over every classifier, over many cut points ----
    log_odd_separators = "\r\n".join(
        ["head line"] + [f"noise {i}\x0cmore text {i}" for i in range(80)] + ["ERROR: boom", "tail line"]
    )
    corpus = {
        "real-pytest-fail": real_pytest_fail,
        "real-pytest-fail+stderr": real_pytest_fail + "\nDeprecationWarning: something unrelated",
        "synthetic-pytest-pass": pytest_pass,
        "synthetic-pytest-fail": pytest_fail,
        "pytest-no-tests-ran": pytest_no_tests_ran,
        "long-log-with-errors": long_log,
        "duplicate-line-log": dup_log,
        "crlf-and-odd-separators": log_odd_separators,
        "pytest-tb-no": pytest_tb_no,
        "pytest-tb-no-no-listing": pytest_tb_no_no_listing,
        "pytest-collect-error": pytest_collect_error,
        "two-pytest-runs": pytest_fail + pytest_pass,
        "pytest-then-rc-line": pytest_fail + "rc=1\n",
        "pytest-then-fake-banner": pytest_fail + "=== build finished in 5.0s ===\n",
        "alternating-error-log": alternating,
    }
    rng = random.Random(20260928)
    exercised = {"classify_pytest": 0, "classify_log_tail": 0, "classify_output": 0}
    violations: list[str] = []
    for name, full in corpus.items():
        starts = [0]
        for ln in full.splitlines(keepends=True):
            starts.append(starts[-1] + len(ln))
        step = max(1, len(starts) // 40)
        points = {1, len(full) - 1, len(full)}
        points.update(starts[::step])
        points.update(min(len(full), s + 3) for s in starts[::step])  # cut mid-line
        points.update(rng.randrange(1, len(full) + 1) for _ in range(25))
        for m in re.finditer(r"session starts|FAILURES|short test summary|warnings summary|passed|failed|no tests ran", full):
            points.update({m.start(), m.start() + 4, m.end()})  # right at / inside / just after key banners
        for p in sorted(q for q in points if 0 < q <= len(full)):
            for variant, text in (("prefix", full[:p]), ("prefix+stderr", full[:p] + "\nSomeWarning: from stderr")):
                calls = {
                    "classify_pytest": classify_pytest(text),
                    "classify_log_tail": classify_log_tail(text, head_lines=5, tail_lines=5, max_lines=30),
                    "classify_output": classify_output("cmd", text),
                }
                for fn, verdict in calls.items():
                    if verdict is None:
                        continue
                    exercised[fn] += 1
                    problems = overlap_problems(text, verdict) + span_problems(text, verdict)
                    # a rule never hands back MORE text than it was given, and a verdict that names a cut really
                    # is smaller (unknown / no-gain keep everything, so they are exactly as long)
                    if verdict["chars_after"] > verdict["chars_before"]:
                        problems.append(f"chars_after {verdict['chars_after']} > chars_before {verdict['chars_before']}: the rule ENLARGES the output")
                    if verdict["rule"] in ("pytest", "log-tail") and verdict["chars_after"] >= verdict["chars_before"]:
                        problems.append(f"rule {verdict['rule']!r} names a cut that is not smaller than its input")
                    if problems:
                        violations.append(f"{name}[{variant}@{p}] {fn} rule={verdict.get('rule')}: {problems[0]}")
    for fn, n in exercised.items():
        ok(f"property: {fn} was actually exercised on >= 40 cut texts (got {n})", n >= 40)
    ok(f"property: kept/omitted never overlap and always rebuild the text ({len(violations)} violation(s))", not violations)
    for v in violations[:8]:
        print(f"    violation: {v}")

    # ---- rendered_text / chars_after: the agent-facing text is derived from the SAME partition ----
    r_render = classify_log_tail(long_log)
    if r_render:
        marker_total = sum(int(m.group(1)) for m in re.finditer(r"^\[(\d+) lines omitted; run with RAW=1\]$", r_render["rendered_text"], re.MULTILINE))
        ok("rendered_text: per-gap omitted-line markers add up to lines_omitted", marker_total == r_render["lines_omitted"])
        ok("rendered_text: stripping the markers leaves exactly kept_text",
           "".join(ln for ln in r_render["rendered_text"].splitlines(keepends=True) if not marker_line_re.match(ln.strip())) == r_render["kept_text"])
        ok("chars_after measures what the agent would see (rendered_text), markers included", r_render["chars_after"] == len(r_render["rendered_text"]))

    # ---- ga-wk0qi2 full-diff sweep: the banner/header regexes must stay LINEAR on hostile lines.
    # This runs in a PostToolUse hook on every pool Bash call; `^=+.*\bin...` had an ambiguous split
    # between `=+` and `.*`, so a single very long '='/'_' line (a progress bar, a separator someone
    # printed 100k wide) made matching quadratic -- tens of seconds of CPU stalling the agent's call
    # until the wrapper's watchdog killed it. ----
    import time as _time

    def timed(fn, *args):
        t0 = _time.monotonic()
        result = fn(*args)
        return result, _time.monotonic() - t0

    hostile = (
        "============ test session starts ============\n"
        + "=" * 12000 + "x\n"
        + "_" * 12000 + "x\n"
        + "ordinary line\n"
        + "============ 1 passed in 0.10s ============\n"
    )
    r_hostile, took = timed(classify_pytest, hostile)
    ok(f"hostile 12k-char '='/'_' lines classify quickly (took {took:.2f}s, limit 2s)", took < 2.0)
    ok("hostile lines: the real banner is still found and kept",
       r_hostile is not None and r_hostile["rule"] == "pytest" and "1 passed in 0.10s" in r_hostile["kept_text"])
    ok("hostile lines: a 12k '=' line is not mistaken for the summary banner", r_hostile is not None and "=" * 12000 not in r_hostile["kept_text"])
    hostile_log = "\n".join(["start"] + ["=" * 12000 + "x"] * 3 + [f"noise {i}" for i in range(300)])
    _, took_log = timed(classify_output, "cmd", hostile_log)
    ok(f"hostile lines through classify_output stay fast (took {took_log:.2f}s, limit 2s)", took_log < 2.0)

    print(f"\ncut_output_classifier selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(_selftest())
    print("usage: cut_output_classifier.py selftest", file=sys.stderr)
    sys.exit(1)

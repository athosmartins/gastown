#!/usr/bin/env python3
"""cut-output-shadow.py (ga-wk0qi2, child of ga-aijm2v) — PostToolUse:Bash AND PostToolUseFailure:Bash
hook, SHADOW MODE ONLY. Measures what a "cut large tool output before it enters the agent's context" FIXED RULE
WOULD do, for every pool session (dog/wa-worker/ps-worker/reviewer — see pool-roles.json), and logs that to
jev-experiment.jsonl. It NEVER modifies the real tool output, and it sends nothing anywhere: no network, no
credential lookup, no AI.

Per Athos's own authorization (AskUserQuestion in the Mayor session, 28/09 11:3x, cited in this
bead's own description): the four new Jev shadow fronts start in SHADOW. The rule decides and
records; NOTHING changes in real behavior until there is a number and a NEW decision. This
script's stdout is therefore ALWAYS the literal two characters `{}` (a no-op hookSpecificOutput)
-- regardless of what the classifier concludes. See PASSO 0 below for why a real cut,
WHEN one is eventually authorized, cannot just be a string.

SCOPE, decided by the Mayor (28/09 23:1x) after the gate rejected this bead seven times: THIS bead ships the fixed
rule only. Every rejection found another "could not know reads as measured nothing" hole, and every one was in the
tier that asked Jev to judge the output the fixed rule does not cut. That tier is ga-d0hm85 (it starts once the fixed
rule has about a week of data); it is not here, not switched off behind a constant, and nothing in the report or the
log reads a Jev field. Its code lives in this branch's history (a2d6a71f0) for whoever picks that bead up.

PASSO 0 (mandatory prerequisite, done once, NOT wired into this script): proven live against
the installed Claude Code 2.1.283 that a PostToolUse hook CAN replace Bash's tool output before
the model sees it via hookSpecificOutput.updatedToolOutput -- but ONLY when updatedToolOutput is
an OBJECT matching Bash's own tool_response shape ({stdout, stderr, interrupted, isImage,
noOutputExpected}), never a bare string. A bare-string replacement is silently REJECTED (the
installed binary's own log line: "PostToolUse hook returned updatedToolOutput that does not
match ...'s output shape ...; using original output") and the ORIGINAL output reaches the model
unchanged -- which would have made a naive live rollout silently do nothing while looking active.
This is pinned here so whoever eventually flips this from shadow to live does not rediscover it
the hard way.

TWO EVENTS (gate_run ga-vrv1tz; payloads captured live from Claude Code 2.1.284): a Bash call's output
reaches a hook on ONE of two events. PostToolUse fires only when the call SUCCEEDED (exit 0), carrying
tool_response.{stdout, stderr}. A call that exits non-zero fires PostToolUseFailure INSTEAD -- no tool_response;
the merged output is in `error` as "Exit code N\n<output>". Registered on PostToolUse alone this hook measured
only the commands that worked (never a failing pytest run, a killed command, ...), so any rate it produced said
nothing about the failed-command half -- where a cut is most plausibly costly (whether it really is: that is
what this front measures). read_bash_output() understands both shapes; every record carries hook_event and
exit_code (None when the payload does not say -- a success carries no code, and a timeout has none; never 0),
and the report shows the failed-command population apart. SCOPE: the RESULT of a foreground Bash call only --
not Monitor/BashOutput, Read, Grep or MCP tool output.

THE RULE, no AI, no network: cut_output_classifier.classify_output() recognizes a pytest run or a generic
long/log-shaped dump and would keep head+tail+error-lines+summary. Every large output gets exactly ONE row,
experiment "cut-output-fixed", and the row's `rule` says which of the five things happened:
  * "pytest" / "log-tail": a cut it would make; tokens_would_save is the measured difference, and the row carries
    the signatures of what would be omitted, for the offline join (referenced_later);
  * "no-gain": a shape it recognizes but could not make SHORTER (each omitted run costs a marker): nothing omitted,
    a measured tokens_would_save of 0 (it did evaluate it), nothing for the join to look for;
  * "unknown": a pytest run it cannot read (killed or truncated, no final summary): nothing would be cut, and
    tokens_would_save is None -- a third state, not a zero-token cut;
  * "unmatched": a large output NO fixed rule applies to (prose, one long line, a JSON blob, `bd show`, a short
    diff...): nothing would be cut, tokens_would_save None, nothing for the join. It is a row instead of silence so
    that the report can say how much large output the rule never reaches -- without it that population would read
    exactly like calls too small to consider, and the case count would pass for the count of large outputs.

RECORD MODE: every row goes to jev-experiment.jsonl with mode "cut-output" (cut_output_classifier.
RECORD_MODE), never "shadow". That mode belongs to jev_experiment_report.summarize_shadow(), which
reads F0's agree/would_dispense fields -- this front's rows under it made the daily report print a
"Jev unavailable" section for a tier that never calls Jev and subtract Jev's token cost from savings that section
never credits (gate_run ga-75ya0i). The measurement has its own report (jev_cut_output_report.py, wired into
jev-daily-report.sh) and its own offline join (jev_cut_output_join.py, mode "cut-output-join").

FAIL-OPEN, by construction, but COUNTED: this script is on the Bash hot path of every pool session in the
city (matcher "^Bash$" in pool-roles.json), so EVERY exception -- JSON parse, missing field, a bug in this file --
is caught and turns into printing "{}" and exit(0). Nothing this script does can block or corrupt a real tool call:
the worst case is a lost shadow measurement, never a lost or altered tool result. That is not "free": the hook is
SYNCHRONOUS -- the agent waits for it after every Bash call. Below the size gate that is one jq call in the wrapper;
above it, a python start plus the classifier, bounded by the wrapper's 12s watchdog and the 15s hook timeout in
pool-roles.json. Measured on this machine (29/09, one run each): 1.0s for a 6.3 MB single line, 6.3s for an 8.9 MB
pytest-shaped output, 11.0s for a 6.3 MB log-shaped dump -- so an output that size lands at the watchdog (it is then
killed and counted as engine_rc_137, not lost silently). How large a payload Claude Code really hands a hook is NOT
verified; settle that before this ever graduates past shadow. A lost measurement is not silent, though: main() writes
one row (experiment "cut-output-error", stage "engine", the exception CLASS, never its message) and
cut-output-shadow.sh writes the same shape for its own failure paths (stage "wrapper"), so a hook that dies
on every call shows up in the report instead of reading like a quiet day. The one failure that cannot be
recorded is the log itself being unwritable -- there is nowhere left to write it (the report says so).
A CUT_OUTPUT_SHADOW_DISABLED sentinel file (if present) short-circuits everything before any work is
done, as an emergency kill switch.

CLI:
  python3 cut-output-shadow.py             (no args) -- the real hook entrypoint, reads the
      PostToolUse / PostToolUseFailure hook JSON from stdin, ALWAYS prints "{}" to stdout, exit 0 always.
  python3 cut-output-shadow.py selftest    -- pure (writes only to throwaway logs), no network.
"""
from __future__ import annotations

import json
import os
import sys
import time
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import cut_output_classifier as coc  # noqa: E402
import jev_experiment as je  # noqa: E402

EXPERIMENT_FIXED = "cut-output-fixed"
COMMAND_LOG_CHARS = 300  # the logged command is a fingerprint for the report, not a full replay

DISABLED_SENTINEL = Path(
    os.environ.get(
        "CUT_OUTPUT_SHADOW_DISABLED",
        "/Users/athos/gt/.gascity-gastown-hq/.gc/logs/cut-output-shadow.disabled",
    )
)


def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _entity_id(meta: dict) -> str:
    """The record's join key: the real tool_use_id when the hook input had one, otherwise a fresh
    unique id. A shared placeholder would make every id-less record collide on one key, so the first
    join would mark all of them as already joined."""
    tool_use_id = meta.get("tool_use_id")
    return tool_use_id if tool_use_id else f"no-tool-use-id-{uuid.uuid4().hex[:12]}"


def build_fixed_log_record(verdict: dict, meta: dict) -> dict:
    """Pure. `verdict` is classify_output()'s return, which now carries its own POSITION-based
    `omitted_text` (never re-derived here by content-diffing kept_text against the original —
    that silently miscounted a genuinely-repeated line as "kept" wherever else it occurred;
    ga-wk0qi2 gate feedback, attempt 1, blocking issue 2). `meta` carries session/tool
    identifiers."""
    omitted_text = verdict.get("omitted_text", "")
    # rule "unknown" = the classifier recognized the shape but cannot cut it safely (e.g. a pytest
    # run with no final summary); rule "unmatched" = no fixed rule applies to this output at all. In both nothing
    # is cut, and that is NOT the same fact as "cutting saves 0 tokens" (nothing was evaluated) -- so
    # tokens_would_save is None (third state), which the report keeps out of its average.
    not_evaluated = verdict["rule"] in ("unknown", "unmatched")
    return {
        "ts": _now_iso(),
        "mode": coc.RECORD_MODE,
        "experiment": EXPERIMENT_FIXED,
        "entity_id": _entity_id(meta),
        "session_id": meta.get("session_id"),
        "transcript_path": meta.get("transcript_path"),
        "tool_use_id": meta.get("tool_use_id"),
        "command": meta.get("command", "")[:COMMAND_LOG_CHARS],
        "hook_event": meta.get("hook_event"),
        "exit_code": meta.get("exit_code"),
        "rule": verdict["rule"],
        "reason": verdict.get("reason"),
        "chars_before": verdict["chars_before"],
        "chars_after": verdict["chars_after"],
        "tokens_before": verdict["tokens_before"],
        "tokens_after": verdict["tokens_after"],
        # No max(0, ...) clamp: a classifier verdict is never longer than its input (a cut that would not
        # shrink the text is the explicit rule "no-gain", saving exactly 0), so the difference cannot be
        # negative -- and if a future rule ever broke that, the number should SHOW it, not be hidden as 0.
        "tokens_would_save": None if not_evaluated else verdict["tokens_before"] - verdict["tokens_after"],
        "omitted_signatures": coc.extract_signatures(omitted_text),
        "referenced_later": None,  # filled in by the offline join (jev_cut_output_join.py)
    }


def _log(record: dict) -> None:
    je.JEV_LOG.parent.mkdir(parents=True, exist_ok=True)
    with je.JEV_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def build_error_record(stage: str, exc: BaseException, hook_input: object) -> dict:
    """Pure. One row that says "a call this hook should have looked at was NOT measured, and this is what
    broke". `stage` is who failed ("engine" here; the bash wrapper writes "wrapper" rows of the same shape).
    `error` is the exception's CLASS only, never its message: a message can quote command output, and this
    row goes into a log that several daily reports read. The tool_use_id / session_id are kept when the hook
    input had them, so a lost measurement can be matched to its call."""
    def _str_field(name: str) -> str | None:
        value = hook_input.get(name) if isinstance(hook_input, dict) else None
        return value if isinstance(value, str) and value else None

    tool_use_id = _str_field("tool_use_id")
    return {
        "ts": _now_iso(),
        "mode": coc.RECORD_MODE,
        "experiment": coc.ERROR_EXPERIMENT,
        "entity_id": _entity_id({"tool_use_id": tool_use_id}),
        "stage": stage,
        "error": type(exc).__name__,
        "tool_use_id": tool_use_id,
        "session_id": _str_field("session_id"),
    }


def _record_engine_failure(exc: BaseException, hook_input: object) -> None:
    """Never raises. Writes the error row for an exception main() is about to swallow. If THE LOG is what
    failed (unwritable, disk full) there is nowhere left to write "I could not write": that one case stays
    invisible here, and the report says so instead of pretending a zero is a healthy zero."""
    try:
        _log(build_error_record("engine", exc, hook_input))
    except Exception:  # noqa: BLE001 -- see docstring: the failed log cannot record its own failure
        pass


def read_bash_output(hook_input: dict) -> tuple[str, str, int | None] | None:
    """Pure. (text, hook_event, exit_code) for a Bash hook payload, or None when it carries no output text
    this script can read (not a Bash call, or neither payload shape). The shape decides, and it has to be
    both, because Claude Code sends a Bash call's output on ONE of two events (verified live, 2.1.284):

      * PostToolUse -- the call succeeded (exit 0): tool_response.{stdout, stderr}. stderr is appended after
        stdout with one newline between them. The payload carries no exit code -> exit_code None.
      * PostToolUseFailure -- the call exited non-zero: NO tool_response; `error` holds the merged output as
        "Exit code N\n<output>". The header is not output and is not counted (a live cut would keep it);
        N goes into the record. An error without the header (a timeout, an interrupt) is still output the
        agent reads: measured, exit_code None.

    cut-output-shadow.sh's prefilter computes this same length in jq; the two must agree at the boundary."""
    if hook_input.get("tool_name") != "Bash":
        return None
    tool_response = hook_input.get("tool_response")
    if isinstance(tool_response, dict):
        stdout = tool_response.get("stdout") or ""
        stderr = tool_response.get("stderr") or ""
        text = stdout if not stderr else f"{stdout}\n{stderr}"
        if not isinstance(text, str):
            return None
        return text, coc.EVENT_SUCCESS, None
    error = hook_input.get("error")
    if isinstance(error, str):
        exit_code, output = coc.strip_exit_code_header(error)
        return output, coc.EVENT_FAILURE, exit_code
    return None


def process(hook_input: dict) -> None:
    """Does the actual work (classification, logging). Raises freely --
    main() is the only place that catches. Kept separate from main() so tests can call this
    directly and assert on what got logged without going through stdin/stdout plumbing."""
    parsed = read_bash_output(hook_input)
    if parsed is None:
        return
    text, hook_event, exit_code = parsed
    if len(text) < coc.MIN_CHARS_TO_CONSIDER:
        return

    command = hook_input.get("tool_input", {}).get("command", "") if isinstance(hook_input.get("tool_input"), dict) else ""
    if not isinstance(command, str):
        command = ""  # only a fingerprint for the report: not knowing it must not cost the whole measurement
    raw_tool_use_id = hook_input.get("tool_use_id")
    tool_use_id = raw_tool_use_id if isinstance(raw_tool_use_id, str) and raw_tool_use_id else None
    meta = {
        "session_id": hook_input.get("session_id"),
        "transcript_path": hook_input.get("transcript_path"),
        # None (not knowing) when the hook input carries no usable id -- never a placeholder string:
        # the offline join would go looking for that string in the transcript as if it were a real
        # call id. Each record still gets its own entity_id (see _entity_id).
        "tool_use_id": tool_use_id,
        "command": command,
        "hook_event": hook_event,
        "exit_code": exit_code,
    }

    verdict = coc.classify_output(command, text)
    if verdict is None:
        # Large, but no fixed rule applies. Nothing else is asked about it (the Jev tier is ga-d0hm85's): it is
        # recorded as the rule's own third state, so the report can say how much large output the rule never
        # reaches instead of letting that population vanish into "too small to consider".
        verdict = coc.unmatched_verdict(text)
    _log(build_fixed_log_record(verdict, meta))


def main() -> int:
    # The kill switch is checked BEFORE any parsing: a bad shadow deploy should be silenceable
    # with `touch` alone, no JSON, no python import, nothing else that could itself misbehave.
    try:
        if DISABLED_SENTINEL.exists():
            print("{}")
            return 0
    except OSError:
        pass  # an unreadable sentinel path must not become "guard is on" by accident here either

    hook_input: object = None
    try:
        raw = sys.stdin.read()
        hook_input = json.loads(raw) if raw else {}
        if isinstance(hook_input, dict):
            process(hook_input)
    except Exception as e:  # noqa: BLE001
        # SHADOW MODE, fail-open: a bug here must never affect the real tool call. It is COUNTED, though: one
        # error row (the exception's class), so a hook that dies on every call shows in the report instead of
        # reading like a quiet day.
        _record_engine_failure(e, hook_input)
    print("{}")
    return 0


def _selftest() -> int:
    """Runs the whole suite with jev_experiment.JEV_LOG pointed at a throwaway file. main() writes an error row
    whenever it swallows an exception, so any test that reaches it without its own temp log would append to the
    LIVE jev-experiment.jsonl -- the way a stress run once left 40 junk rows in it. Individual tests still patch
    their own log; this is the net under the ones that forget."""
    import tempfile
    from unittest import mock

    with tempfile.TemporaryDirectory() as guard_dir, \
         mock.patch.object(je, "JEV_LOG", Path(guard_dir) / "selftest-default-log.jsonl"):
        return _selftest_suite()


def _selftest_suite() -> int:
    import tempfile
    from unittest import mock

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

    ok("selftest isolation: the suite's default log is a throwaway file, never the live jev-experiment.jsonl",
       "selftest-default-log" in str(je.JEV_LOG) and str(je.JEV_LOG) != "/Users/athos/gt/.gascity-gastown-hq/.gc/logs/jev-experiment.jsonl")

    # ---- build_fixed_log_record ----
    text = "line1\nline2\nERROR boom /Users/athos/gt/x.py\n" + "\n".join(f"noise {i}" for i in range(300))
    verdict = coc.classify_output("cat log.txt", text)
    ok("setup: classify_output found a log-tail verdict for the fixture", verdict is not None and verdict["rule"] == "log-tail")
    if verdict:
        rec = build_fixed_log_record(verdict, {"session_id": "s1", "transcript_path": "/tmp/t.jsonl", "tool_use_id": "tu1", "command": "cat log.txt"})
        ok("fixed record has the right experiment name", rec["experiment"] == EXPERIMENT_FIXED)
        ok("fixed record echoes tool_use_id/session_id", rec["tool_use_id"] == "tu1" and rec["session_id"] == "s1")
        ok("fixed record has referenced_later=None (filled in later, offline)", rec["referenced_later"] is None)
        ok("fixed record's tokens_would_save is non-negative", rec["tokens_would_save"] >= 0)
        ok("fixed record extracted a signature from the omitted noise", isinstance(rec["omitted_signatures"], list))

    # ---- regression, ga-wk0qi2 gate feedback attempt 1, blocking issue 1: an all-pass pytest run
    # with non-empty stderr must NOT lose the "N passed" summary just because process() appends
    # stderr after stdout (the exact repro the reviewer used) ----
    all_pass_stdout = (
        "============================= test session starts ==============================\n"
        + "\n".join(f"test_mod.py::test_{i} PASSED" for i in range(300))
        + "\n============================== 300 passed in 1.00s ===============================\n"
    )
    kept_verdict = coc.classify_pytest(all_pass_stdout + "\nDeprecationWarning: something something")
    ok(
        "regression (blocking issue 1): kept_text has the real summary even with trailing stderr-shaped text",
        kept_verdict is not None and "300 passed" in kept_verdict["kept_text"],
    )
    ok(
        "regression (blocking issue 1): kept_text does NOT pick the stderr line as the summary",
        kept_verdict is not None and kept_verdict["kept_text"].strip() != "DeprecationWarning: something something",
    )
    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("pytest case must not call Jev")):
            process({
                "tool_name": "Bash",
                "tool_response": {"stdout": all_pass_stdout, "stderr": "DeprecationWarning: something something"},
                "tool_use_id": "tu-pytest-stderr",
                "tool_input": {"command": "pytest"},
            })
        end_to_end_rec = json.loads(log_path.read_text().splitlines()[0])
        ok(
            "regression (blocking issue 1): end-to-end process() still classifies this as pytest, not a fallback",
            end_to_end_rec["rule"] == "pytest" and end_to_end_rec["tokens_would_save"] > 0,
        )

    # ---- regression, ga-wk0qi2 gate feedback attempt 1, blocking issue 2: a line that is
    # genuinely repeated once in the (kept) head and again in the (omitted) middle must still show
    # up in omitted_signatures for its middle occurrence ----
    dup_line = "processing ga-dupe99 at /Users/athos/gt/dup/path.py"
    log_lines = [dup_line] + [f"noise {i}" for i in range(300)]
    log_lines[150] = dup_line  # exact same text, deep in the middle -- should still be "omitted"
    dup_text = "\n".join(log_lines)
    dup_verdict = coc.classify_output("cat dup.log", dup_text)
    ok("setup: classify_output found a log-tail verdict for the duplicate-line fixture", dup_verdict is not None and dup_verdict["rule"] == "log-tail")
    if dup_verdict:
        dup_rec = build_fixed_log_record(dup_verdict, {"tool_use_id": "tu-dup", "command": "cat dup.log"})
        ok(
            "regression (blocking issue 2): the middle occurrence of a repeated line is still captured as an omitted signature",
            "ga-dupe99" in dup_rec["omitted_signatures"],
        )

    # ---- ga-wk0qi2 gate feedback attempt 4 (+ Mayor's directive): a pytest run the fixed rule cannot
    # read (killed/truncated, no final summary banner) is the explicit 'unknown' state -- logged as
    # its own thing, never as a cut of 0 tokens (which would drag the average down as if the rule had
    # examined it and found nothing worth cutting) and never re-routed to Jev. ----
    truncated_pytest = all_pass_stdout[: all_pass_stdout.index("test_mod.py::test_250")] + "test_mod.py::test_25"
    unk_verdict = coc.classify_output("pytest", truncated_pytest)
    ok("setup: truncated pytest -> classify_output returns the 'unknown' verdict", unk_verdict is not None and unk_verdict["rule"] == "unknown")
    if unk_verdict:
        unk_rec = build_fixed_log_record(unk_verdict, {"tool_use_id": "tu-unk", "command": "pytest"})
        ok("unknown record: rule is logged as 'unknown'", unk_rec["rule"] == "unknown")
        ok("unknown record: tokens_would_save is None (third state), not 0", unk_rec["tokens_would_save"] is None)
        ok("unknown record: nothing omitted -> no omitted_signatures to join on", unk_rec["omitted_signatures"] == [])
        ok("unknown record: chars_after == chars_before (nothing was cut)", unk_rec["chars_after"] == unk_rec["chars_before"])
    # ---- gate_run ga-vrv1tz, low finding: tokens_would_save was clamped with max(0, before - after), which hid a
    # rule that ENLARGES the output (400 alternating ERROR/ok lines: each omitted 'ok' line became a longer
    # marker) and logged it as a 0-token "cut" whose omitted lines went to the join. That verdict is now the
    # explicit rule "no-gain": nothing omitted, a measured zero (not None -- the rule DID evaluate it), and
    # nothing for the join to look for. The clamp is gone: a negative number would now show up as one. ----
    alt_text = "\n".join(f"ERROR: step {i} failed" if i % 2 else f"INFO ok {i}" for i in range(400))
    alt_verdict = coc.classify_output("cmd", alt_text)
    ok("setup: the alternating ERROR/ok log is a 'no-gain' verdict", alt_verdict is not None and alt_verdict["rule"] == "no-gain")
    if alt_verdict:
        alt_rec = build_fixed_log_record(alt_verdict, {"tool_use_id": "tu-alt", "command": "cmd"})
        ok("no-gain record: rule is logged as 'no-gain' and its reason says which rule gave up", alt_rec["rule"] == "no-gain" and alt_rec["reason"] == "log-tail-would-not-shrink")
        ok("no-gain record: tokens_would_save is a measured 0 (the rule evaluated it), not None and not a clamped negative", alt_rec["tokens_would_save"] == 0)
        ok("no-gain record: nothing omitted, so no omitted_signatures for the join to look for", alt_rec["omitted_signatures"] == [])
        ok("no-gain record: chars_after == chars_before (the output is not enlarged)", alt_rec["chars_after"] == alt_rec["chars_before"])

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("unknown pytest case must not call Jev")):
            process({
                "tool_name": "Bash",
                "tool_response": {"stdout": truncated_pytest, "stderr": ""},
                "tool_use_id": "tu-pytest-truncated",
                "tool_input": {"command": "pytest"},
            })
        unk_lines = log_path.read_text().splitlines()
        ok("process(): truncated pytest writes exactly one fixed-rule record", len(unk_lines) == 1)
        unk_e2e = json.loads(unk_lines[0])
        ok(
            "process(): truncated pytest is logged as 'unknown' with no would-save number",
            unk_e2e["experiment"] == EXPERIMENT_FIXED and unk_e2e["rule"] == "unknown" and unk_e2e["tokens_would_save"] is None,
        )

    # ---- ga-wk0qi2 full-diff sweep: a hook input WITHOUT a tool_use_id must not be logged under the
    # literal string "unknown". The offline join would then search the transcript for the WORD
    # "unknown" (found almost anywhere -> a wrong split point and a wrong referenced_later), and
    # every id-less record would share one entity_id, so the first join would mark all of them as
    # already joined. Not knowing the id is None, and each record still gets its own entity_id. ----
    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("pytest case must not call Jev")):
            for _ in range(2):
                process({
                    "tool_name": "Bash",
                    "tool_response": {"stdout": all_pass_stdout, "stderr": ""},
                    "transcript_path": "/tmp/t.jsonl",
                    "tool_input": {"command": "pytest"},
                })
        idless = [json.loads(ln) for ln in log_path.read_text().splitlines()]
        ok("id-less hook input: still logs one record per call", len(idless) == 2)
        ok("id-less hook input: tool_use_id is None (not knowing), never the string 'unknown'", all(r["tool_use_id"] is None for r in idless))
        ok("id-less hook input: entity_id is never the literal 'unknown'", all(r["entity_id"] != "unknown" for r in idless))
        ok("id-less hook input: two records get DIFFERENT entity_ids", len({r["entity_id"] for r in idless}) == 2)

    # ---- gate_run ga-vrv1tz, blocking issue 1: PostToolUse does NOT fire for a Bash call that exits non-zero.
    # Claude Code fires PostToolUseFailure instead, with no tool_response: the merged output is in `error`,
    # as "Exit code N\n<output>" (payload captured live from Claude Code 2.1.284; keys: session_id,
    # transcript_path, cwd, prompt_id, permission_mode, hook_event_name, tool_name, tool_input, tool_use_id,
    # error, is_interrupt, duration_ms). Registered only for PostToolUse, every failing pytest run, killed
    # command or masked-exit-code failure was silently outside the measurement -- the half of the population
    # where a cut is most plausibly costly. The selftests above hand-built tool_response dicts for the
    # failing-pytest shapes, which production could never deliver to this hook. ----
    failing_pytest_out = (
        "=" * 30 + " test session starts " + "=" * 30 + "\n"
        + "\n".join(f"test_mod.py::test_{i} PASSED" for i in range(200))
        + "\n" + "_" * 20 + " test_boom " + "_" * 20 + "\nE   assert 1 == 2\ntest_mod.py:42: AssertionError\n"
        + "=" * 20 + " short test summary info " + "=" * 20 + "\nFAILED test_mod.py::test_boom - assert 1 == 2\n"
        + "=" * 20 + " 1 failed, 200 passed in 3.10s " + "=" * 20 + "\n"
    ).rstrip("\n")  # the live payload's error has no trailing newline: 'x'*2500 + "\n" arrived as 2500 chars

    def _failure_hook(error, **kw) -> dict:
        h = {
            "session_id": "s-fail", "transcript_path": "/tmp/s-fail.jsonl", "cwd": "/tmp", "prompt_id": "p1",
            "permission_mode": "bypassPermissions", "hook_event_name": "PostToolUseFailure", "tool_name": "Bash",
            "tool_input": {"command": "pytest", "description": "run the tests"}, "tool_use_id": "toolu_fail1",
            "error": error, "is_interrupt": False, "duration_ms": 2375,
        }
        h.update(kw)
        return h

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("pytest case must not call Jev")):
            process(_failure_hook("Exit code 1\n" + failing_pytest_out))
        fail_lines = log_path.read_text().splitlines() if log_path.exists() else []
        ok("PostToolUseFailure: a failing pytest run (exit 1) IS measured -- exactly one record", len(fail_lines) == 1)
        fail_rec = json.loads(fail_lines[0]) if fail_lines else {}
        ok("PostToolUseFailure: classified by the fixed rule as pytest, with a real would-save number",
           fail_rec.get("experiment") == EXPERIMENT_FIXED and fail_rec.get("rule") == "pytest" and (fail_rec.get("tokens_would_save") or 0) > 0)
        ok("PostToolUseFailure: the record says which event it came from and the exit code",
           fail_rec.get("hook_event") == coc.EVENT_FAILURE and fail_rec.get("exit_code") == 1)
        ok("PostToolUseFailure: the 'Exit code N' header is not part of the measured text (chars_before == the output's length)",
           fail_rec.get("chars_before") == len(failing_pytest_out))
        ok("PostToolUseFailure: the tool_use_id/session are carried for the offline join",
           fail_rec.get("tool_use_id") == "toolu_fail1" and fail_rec.get("session_id") == "s-fail" and fail_rec.get("entity_id") == "toolu_fail1")

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("pytest case must not call Jev")):
            process({"tool_name": "Bash", "tool_response": {"stdout": all_pass_stdout, "stderr": ""}, "tool_use_id": "toolu_ok1",
                     "tool_input": {"command": "pytest"}})
        ok_rec = json.loads(log_path.read_text().splitlines()[0])
        ok("PostToolUse (success): the record says PostToolUse; the payload carries no exit code, so exit_code is None (not 0)",
           ok_rec.get("hook_event") == coc.EVENT_SUCCESS and ok_rec.get("exit_code") is None)

    # a failure payload that is NOT an "Exit code N" error (a timeout, an interrupt) is still output the agent
    # reads: measured, with exit_code None -- not knowing the code is not "0" and not a reason to skip it
    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("pytest case must not call Jev")):
            process(_failure_hook("Command timed out after 120000ms\n" + all_pass_stdout, is_interrupt=True))
        to_rec = json.loads(log_path.read_text().splitlines()[0]) if log_path.exists() else {}
        ok("PostToolUseFailure without an 'Exit code N' header: still measured, exit_code None",
           to_rec.get("hook_event") == coc.EVENT_FAILURE and to_rec.get("exit_code") is None and to_rec.get("experiment") == EXPERIMENT_FIXED)

    # the size gate is applied to the OUTPUT (header stripped), same number the wrapper's prefilter computes
    for out_len, expect_rows in ((coc.MIN_CHARS_TO_CONSIDER - 1, 0), (coc.MIN_CHARS_TO_CONSIDER, 1)):
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "jev-experiment.jsonl"
            with mock.patch.object(je, "JEV_LOG", log_path), \
                 mock.patch.object(je, "call_jev_multi", return_value={"ok": False, "error": "no_credentials"}):
                process(_failure_hook("Exit code 2\n" + "z" * out_len))
            n_rows = len(log_path.read_text().splitlines()) if log_path.exists() else 0
            ok(f"PostToolUseFailure size gate: header + {out_len} chars of output -> {expect_rows} row(s) (the header does not count)",
               n_rows == expect_rows)

    # payloads with NO readable output: nothing is logged and nothing raises (this hook must never fail a call)
    for label, odd in (
        ("neither tool_response nor error", {"tool_name": "Bash", "tool_use_id": "t"}),
        ("error that is not a string", _failure_hook({"message": "x" * 5000})),
        ("error null", _failure_hook(None)),
        ("tool_response that is not an object", {"tool_name": "Bash", "tool_response": "x" * 5000}),
        ("a failure payload for another tool", _failure_hook("Exit code 1\n" + "z" * 5000, tool_name="Read")),
    ):
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "jev-experiment.jsonl"
            raised_odd = False
            with mock.patch.object(je, "JEV_LOG", log_path), \
                 mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("must not call Jev")):
                try:
                    process(odd)
                except Exception:
                    raised_odd = True
            ok(f"unreadable payload ({label}): process() does not raise and logs nothing",
               not raised_odd and not log_path.exists())

    # ---- gate_run ga-vrv1tz, medium finding: fail-open was SILENT and UNCOUNTED. main() turned any exception into
    # a bare "{}" and the wrapper threw python's stderr away, so a hook that died on every call read in the
    # report exactly like a quiet day ("0 case(s)"). A failure now leaves one row -- the class of the exception,
    # never its message (that can quote command output) -- and STILL prints "{}" and returns 0. ----
    import contextlib
    import io

    def _run_main(stdin_text: str, sentinel_dir: str, jev_log: Path, boom: Exception | None = None) -> tuple[int, str]:
        buf = io.StringIO()
        patches = [
            mock.patch.object(je, "JEV_LOG", jev_log),
            mock.patch(f"{__name__}.DISABLED_SENTINEL", Path(sentinel_dir) / "does-not-exist"),
            mock.patch.object(sys, "stdin", mock.MagicMock(read=mock.Mock(return_value=stdin_text))),
        ]
        if boom is not None:
            patches.append(mock.patch(f"{__name__}.process", side_effect=boom))
        with contextlib.ExitStack() as stack:
            for pt in patches:
                stack.enter_context(pt)
            with contextlib.redirect_stdout(buf):
                rc_ = main()
        return rc_, buf.getvalue()

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        rc_e, out_e = _run_main(json.dumps({"tool_name": "Bash", "tool_use_id": "toolu_boom", "session_id": "s-boom"}), td, log_path, boom=RuntimeError("secret output text"))
        err_lines = log_path.read_text().splitlines() if log_path.exists() else []
        ok("an exception inside process(): main() still prints {} and returns 0", rc_e == 0 and out_e.strip() == "{}")
        ok("an exception inside process(): exactly one ERROR row is logged (the failure is countable, not silent)", len(err_lines) == 1)
        err_rec = json.loads(err_lines[0]) if err_lines else {}
        ok("error row: own experiment name and this front's mode, stage 'engine', the exception CLASS",
           err_rec.get("experiment") == coc.ERROR_EXPERIMENT and err_rec.get("mode") == coc.RECORD_MODE
           and err_rec.get("stage") == "engine" and err_rec.get("error") == "RuntimeError")
        ok("error row: never carries the exception's MESSAGE (it can quote command output)", "secret output text" not in err_lines[0])
        ok("error row: keeps the tool_use_id/session for correlation", err_rec.get("tool_use_id") == "toolu_boom" and err_rec.get("session_id") == "s-boom")

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        rc_j, out_j = _run_main("not json {{{", td, log_path)
        j_lines = log_path.read_text().splitlines() if log_path.exists() else []
        ok("malformed JSON on stdin: {} / rc 0 and ONE error row naming the exception class",
           rc_j == 0 and out_j.strip() == "{}" and len(j_lines) == 1 and json.loads(j_lines[0]).get("error") == "JSONDecodeError")

    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        _run_main("", td, log_path)
        _run_main(json.dumps({"tool_name": "Read", "tool_response": {"stdout": "x" * 5000}}), td, log_path)
        _run_main(json.dumps({"tool_name": "Bash", "tool_response": {"stdout": "ok", "stderr": ""}}), td, log_path)
        ok("no error row for the normal quiet paths: empty stdin, another tool, a small output", not log_path.exists())

    with tempfile.TemporaryDirectory() as td:
        # the log path is a DIRECTORY: nothing can be written, including the error row. That is the one failure
        # this script cannot record -- it must still be silent for the agent: {} and rc 0, never a traceback.
        rc_u, out_u = _run_main(json.dumps({"tool_name": "Bash"}), td, Path(td), boom=RuntimeError("x"))
        ok("when even the error row cannot be written: {} / rc 0, no exception escapes", rc_u == 0 and out_u.strip() == "{}")

    # ---- process(): end to end, with a temp log file, verifying the hook NEVER emits anything other than
    # the caller printing "{}" (main() owns the print; process() only logs) ----
    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path):
            # small output: below MIN_CHARS_TO_CONSIDER -> no log line at all
            process({"tool_name": "Bash", "tool_response": {"stdout": "ok", "stderr": ""}, "tool_use_id": "tu-small"})
            ok("process(): small output writes no log line", not log_path.exists())

            # non-Bash tool -> ignored even with huge output
            process({"tool_name": "Read", "tool_response": {"stdout": "x" * 5000}, "tool_use_id": "tu-read"})
            ok("process(): non-Bash tool_name is ignored", not log_path.exists())

            # large pytest-shaped output -> fixed-rule log line
            pytest_text = (
                "============================= test session starts ==============================\n"
                + "\n".join(f"t{i} PASSED" for i in range(300))
                + "\n============================== 300 passed in 1.0s ================================\n"
            )
            with mock.patch.object(je, "call_jev_multi", side_effect=AssertionError("fixed-rule case must not call Jev")):
                process({
                    "tool_name": "Bash",
                    "tool_response": {"stdout": pytest_text, "stderr": ""},
                    "tool_use_id": "tu-pytest",
                    "session_id": "sess1",
                    "transcript_path": "/tmp/sess1.jsonl",
                    "tool_input": {"command": "pytest"},
                })
            lines = log_path.read_text().splitlines()
            ok("process(): pytest case wrote exactly one log line", len(lines) == 1)
            rec = json.loads(lines[0])
            ok("process(): pytest case logged experiment cut-output-fixed", rec["experiment"] == EXPERIMENT_FIXED)
            ok("process(): pytest case logged the right tool_use_id", rec["tool_use_id"] == "tu-pytest")

    # ---- Mayor 28/09 23:1x, after the 7th gate rejection: THIS bead ships the FIXED RULE only. Every rejection found
    # a new "could not know reads as measured nothing" hole in the Jev tier, so that tier moved to ga-d0hm85. A large
    # output no fixed rule applies to is therefore sent NOWHERE: it is one 'unmatched' row, the rule's own third
    # state ("I do not know how to cut this, so I do not cut it"). Not a silent skip (that would read exactly like a
    # call too small to consider, so the report could not say how much large output the rule never reaches), and
    # not a zero-token cut (nothing was evaluated). ----
    prose_big = "\n\n".join(f"random unstructured paragraph number {i} with no test/log shape at all, just prose padding to grow it" for i in range(80))

    def _unmatched_hook(stdout: str, tuid: str = "tu-unm", **kw) -> dict:
        h = {"tool_name": "Bash", "tool_response": {"stdout": stdout, "stderr": ""}, "tool_use_id": tuid,
             "session_id": "s-unm", "transcript_path": "/tmp/s-unm.jsonl", "tool_input": {"command": "some-tool --verbose"}}
        h.update(kw)
        return h

    for label, out_text in (
        ("prose", prose_big),
        ("one 50k-char line", "y" * 50_000),
        ("150 lines of 395 chars (~59k, the size the Jev tier used to sample)", "\n".join(f"{i:04d} " + "x" * 390 for i in range(150))),
    ):
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "jev-experiment.jsonl"
            with mock.patch.object(je, "JEV_LOG", log_path), \
                 mock.patch.object(je, "call_jev_multi", return_value={"ok": True, "answers": {}, "bad": {}}) as m_unm:
                process(_unmatched_hook(out_text))
            unm_lines = log_path.read_text().splitlines() if log_path.exists() else []
            unm_rec = json.loads(unm_lines[0]) if unm_lines else {}
            ok(f"unmatched ({label}): Jev is NEVER called -- nothing leaves the machine and nothing waits on a network", m_unm.call_count == 0)
            ok(f"unmatched ({label}): exactly one row, in the fixed-rule experiment (there is no other tier), this front's mode",
               len(unm_lines) == 1 and unm_rec.get("experiment") == EXPERIMENT_FIXED and unm_rec.get("mode") == coc.RECORD_MODE)
            ok(f"unmatched ({label}): rule 'unmatched' with its own reason -- not 'unknown' (that one means a recognized shape)",
               unm_rec.get("rule") == "unmatched" and unm_rec.get("reason") == "no-fixed-rule-applies")
            ok(f"unmatched ({label}): tokens_would_save is None (third state), never a measured 0 and never a guess",
               "tokens_would_save" in unm_rec and unm_rec["tokens_would_save"] is None)
            ok(f"unmatched ({label}): nothing cut -> chars/tokens after == before, nothing omitted, no signature for the join",
               unm_rec.get("chars_before") == len(out_text) and unm_rec.get("chars_after") == unm_rec.get("chars_before")
               and unm_rec.get("tokens_after") == unm_rec.get("tokens_before") and unm_rec.get("omitted_signatures") == [])
            ok(f"unmatched ({label}): the row still carries what the report splits on and the join keys on",
               unm_rec.get("hook_event") == coc.EVENT_SUCCESS and unm_rec.get("exit_code") is None and unm_rec.get("entity_id") == "tu-unm"
               and unm_rec.get("session_id") == "s-unm")

    # a failing command's unstructured output is the same 'unmatched' row, and the row says where it came from
    with tempfile.TemporaryDirectory() as td:
        log_path = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(je, "JEV_LOG", log_path), \
             mock.patch.object(je, "call_jev_multi", return_value={"ok": True, "answers": {}, "bad": {}}) as m_unm_f:
            process(_failure_hook("Exit code 3\n" + prose_big, tool_input={"command": "some-tool"}))
        unm_f = json.loads(log_path.read_text().splitlines()[0]) if log_path.exists() else {}
        ok("unmatched, PostToolUseFailure: no Jev call, one 'unmatched' row carrying hook_event and exit_code",
           m_unm_f.call_count == 0 and unm_f.get("rule") == "unmatched" and unm_f.get("hook_event") == coc.EVENT_FAILURE and unm_f.get("exit_code") == 3)

    # a hook input whose tool_input.command is not a string (null / missing / odd type) is still a measurable large
    # output: the command is only a fingerprint for the report, so "don't know" is an empty command, not a TypeError
    # that silently drops the whole record
    for odd_cmd in (None, 123, ["ls"]):
        with tempfile.TemporaryDirectory() as td:
            log_path = Path(td) / "jev-experiment.jsonl"
            raised_cmd = False
            with mock.patch.object(je, "JEV_LOG", log_path):
                try:
                    process(_unmatched_hook(prose_big, tool_input={"command": odd_cmd}))
                except Exception:
                    raised_cmd = True
            cmd_lines = log_path.read_text().splitlines() if log_path.exists() else []
            ok(f"non-string tool_input.command ({odd_cmd!r}): process() does not raise and still logs the measurement",
               not raised_cmd and len(cmd_lines) == 1 and json.loads(cmd_lines[0]).get("command") == "")

    _mod = sys.modules[__name__]
    ok("no Jev tier left in this module for a report to read: no record builder, no experiment name, no deadline caller",
       not any(hasattr(_mod, n) for n in ("EXPERIMENT_JEV", "build_jev_log_record", "build_jev_state_and_questions", "call_jev_with_deadline", "chunk_text")))

    # ---- gate_run ga-75ya0i, blocking issue 2: this front's rows must not be read as F0 shadow rows. The daily
    # Jev report (jev_experiment_report.py) aggregates EVERY mode=="shadow" row by experiment name, expecting
    # F0's agree / would_dispense fields; records logged under that mode printed "Jev unavailable" for a front
    # that never calls Jev and subtracted Jev's token cost from savings the section never credits. The
    # only test that can prove they stay out is one that pushes the REAL records through the real report. ----
    import jev_experiment_report as jer

    def _real_records() -> list[dict]:
        big_pytest = (
            "============================= test session starts ==============================\n"
            + "\n".join(f"t{i} PASSED" for i in range(300))
            + "\n============================== 300 passed in 1.0s ================================\n"
        )
        prose = "\n\n".join(f"random unstructured paragraph number {i} with no test/log shape at all, just prose padding to grow it" for i in range(80))

        def _hook(stdout: str, tuid: str) -> dict:
            return {"tool_name": "Bash", "tool_response": {"stdout": stdout, "stderr": ""}, "tool_use_id": tuid,
                    "session_id": "s-rep", "transcript_path": "/tmp/s-rep.jsonl", "tool_input": {"command": "x"}}

        with tempfile.TemporaryDirectory() as td_rep:
            lp = Path(td_rep) / "jev-experiment.jsonl"
            with mock.patch.object(je, "JEV_LOG", lp):
                process(_hook(big_pytest, "toolu_fixed"))
                process(_hook(prose, "toolu_unmatched"))
            return [json.loads(ln) for ln in lp.read_text().splitlines()]

    real_recs = _real_records()
    ok("setup: the hook logged a cut (pytest) and an unmatched output, both under the one fixed-rule experiment",
       [(r["experiment"], r["rule"]) for r in real_recs] == [(EXPERIMENT_FIXED, "pytest"), (EXPERIMENT_FIXED, "unmatched")])
    ok("every record this front logs carries its own mode (coc.RECORD_MODE), never 'shadow'",
       all(r["mode"] == coc.RECORD_MODE for r in real_recs) and coc.RECORD_MODE != "shadow")
    join_like = {"mode": coc.JOIN_MODE, "experiment": EXPERIMENT_FIXED, "entity_id": "toolu_fixed", "referenced_later": False}
    error_like = build_error_record("engine", RuntimeError("x"), {"tool_use_id": "toolu_err", "session_id": "s-err"})
    ok("setup: an error row has this front's mode and its own experiment name",
       error_like["mode"] == coc.RECORD_MODE and error_like["experiment"] == coc.ERROR_EXPERIMENT)
    ev_all = real_recs + [join_like, error_like]
    ok("jev_experiment_report.summarize_shadow() sees none of this front's records (it read them as F0 rows before)",
       jer.summarize_shadow(ev_all) == {})
    ok("jev_experiment_report.summarize() sees none of them either", jer.summarize(ev_all) == {})
    rep_text = jer.format_report(jer.summarize(ev_all), jer.summarize_shadow(ev_all), "selftest")
    rep_pt = jer.format_resumo_pt(jer.summarize(ev_all), jer.summarize_shadow(ev_all), "selftest")
    ok("the daily report prints no section, no 'Jev-unavailable' line and no negative savings for this front",
       "cut-output" not in rep_text and "Jev-unavailable" not in rep_text and "~-" not in rep_text)
    ok("the daily Portuguese summary (the phone text) prints nothing for this front either",
       "cut-output" not in rep_pt and "indisponível" not in rep_pt and "~-" not in rep_pt)

    # ...and through load_events(), against a log that ALSO holds the 40 rows an earlier stress run left behind
    # (mode "shadow", experiment "cut-output-jev" -- the name those rows carry in the live log, kept as a literal now that
    # nothing here writes it -- entity_id "t", command "c") next to a genuine F0 shadow row
    with tempfile.TemporaryDirectory() as td_ev:
        lp = Path(td_ev) / "jev-experiment.jsonl"
        junk = [{"ts": f"2026-09-28T21:{17 + i // 40:02d}:{i:02d}Z", "mode": "shadow", "experiment": "cut-output-jev", "entity_id": "t",
                 "command": "c", "session_id": None, "jev_ok": False, "tokens_would_save": None, "jev_tokens_in": 1692, "jev_tokens_out": 0}
                for i in range(40)]
        f0 = {"ts": "2026-09-28T12:00:00Z", "mode": "shadow", "experiment": "F-synthetic", "agree": True, "would_dispense": False}
        lp.write_text("\n".join(json.dumps(r) for r in junk + [f0] + real_recs) + "\n")
        with mock.patch.object(jer, "JEV_LOG", lp):
            loaded = jer.load_events(None, None)
        ok("load_events: the legacy stress-run rows (mode 'shadow', a cut-output experiment) are dropped at the source",
           not any(e.get("entity_id") == "t" for e in loaded))
        ok("load_events: a genuine F0 shadow row still reaches summarize_shadow, and it is the only thing there",
           sorted(jer.summarize_shadow(loaded)) == ["F-synthetic"])

    # ---- main(): disabled sentinel short-circuits everything, even malformed stdin ----
    with tempfile.TemporaryDirectory() as td:
        sentinel = Path(td) / "disabled"
        sentinel.write_text("off")
        with mock.patch.object(sys, "stdin", mock.MagicMock(read=mock.Mock(side_effect=AssertionError("must not read stdin when disabled")))), \
             mock.patch(f"{__name__}.DISABLED_SENTINEL", sentinel):
            rc = main()
        ok("main(): disabled sentinel -> rc 0, never reads stdin", rc == 0)

    # ---- main(): malformed JSON on stdin -> still prints {} and returns 0 (fail-open) ----
    with tempfile.TemporaryDirectory() as td:
        sentinel = Path(td) / "does-not-exist"
        with mock.patch(f"{__name__}.DISABLED_SENTINEL", sentinel), \
             mock.patch.object(sys, "stdin", mock.MagicMock(read=mock.Mock(return_value="not json {{{"))):
            rc = main()
        ok("main(): malformed JSON on stdin -> rc 0 (fail-open)", rc == 0)

    # ---- main(): process() raising an internal bug -> still rc 0 (fail-open) ----
    with tempfile.TemporaryDirectory() as td:
        sentinel = Path(td) / "does-not-exist"
        with mock.patch(f"{__name__}.DISABLED_SENTINEL", sentinel), \
             mock.patch.object(sys, "stdin", mock.MagicMock(read=mock.Mock(return_value='{"tool_name": "Bash"}'))), \
             mock.patch(f"{__name__}.process", side_effect=RuntimeError("boom")):
            rc = main()
        ok("main(): an internal bug in process() -> rc 0 (fail-open), never propagates", rc == 0)

    print(f"\ncut-output-shadow selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "selftest":
        sys.exit(_selftest())
    sys.exit(main())

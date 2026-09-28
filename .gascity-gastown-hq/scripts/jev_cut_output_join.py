#!/usr/bin/env python3
"""jev_cut_output_join.py (ga-wk0qi2, child of ga-aijm2v) — OFFLINE join for the cut-large-
output SHADOW front. cut-output-shadow.py (the live PostToolUse hook) logs, for every large Bash
output, what a fixed rule or Jev WOULD have cut and a handful of "signatures" (bead ids, absolute
paths, sha-looking tokens, error-line snippets) extracted from the cut/would-cut portion. That
alone cannot say whether the agent actually needed the cut content later -- the only way to know
is to look at what the SAME session did in LATER turns, which does not exist yet at hook time.
This script does that lookup, after the fact, exactly like jev_gate_fail_classify_experiment.py's
and jev_quem_pensa_experiment.py's own offline joins (see their DESIGN sections).

PROXY, deliberately loose (this bead's own text): "did a later turn of the same session mention
one of the cut block's ids/paths/error snippets". This is a substring search over the RAW TEXT of
every transcript line after the tool call in question -- not a structured re-parse of Claude
Code's own transcript schema, which is not a public contract and can change across versions. A
false positive here (the signature happens to appear for an unrelated reason) biases the
"referenced later" rate UP, i.e. toward UNDERSTATING how safe a cut would have been -- the
conservative direction for a front that is deciding whether it is safe to ever go live.

APPEND-ONLY, never mutates: jev-experiment.jsonl is a shared log written by many processes
across the whole city. This script never rewrites an existing line (racy, and every other
consumer of that file assumes it is append-only) -- it APPENDS a new record per case, with
mode="shadow-join" and the SAME experiment name as the record it is about, keyed by entity_id
(the original record's tool_use_id) so the report can join the two by entity_id + experiment
without ever touching the original line.

THIRD STATE: a case with no extracted signatures (nothing distinctive was cut -- e.g. an
all-passed pytest run) is SKIPPED, not joined with referenced_later=False -- there was nothing to
look for, which is not the same as looking and finding nothing. A missing/unreadable transcript,
or a tool_use_id this script cannot locate inside it (already rotated/reaped, or the hook fired
on a transcript path that no longer exists), yields referenced_later=None, never False.

CLI:
  python3 jev_cut_output_join.py run [--log PATH] [--since-hours N] [--limit N] [--dry-run]
    Single-instance (flock). Idempotent: skips any (experiment, entity_id) that already has a
    shadow-join record in the log.
  python3 jev_cut_output_join.py selftest
    Pure filesystem (tmp dirs), no network, no live jev-experiment.jsonl touched.
"""
from __future__ import annotations

import argparse
import calendar
import fcntl
import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment as je  # noqa: E402

SOURCE_EXPERIMENTS = ("cut-output-fixed", "cut-output-jev")
JOIN_MODE = "shadow-join"

DEFAULT_LOG_DIR = Path(os.environ.get("JEV_CUT_OUTPUT_JOIN_DIR", "/Users/athos/gt/.gascity-gastown-hq/.gc/logs"))
LOCK_PATH = DEFAULT_LOG_DIR / "jev-cut-output-join.lock"
DEFAULT_LIMIT = 200
DEFAULT_SINCE_HOURS = 24.0 * 7  # a week: long enough that a slow report cron still catches most cases


def read_jsonl(path: Path) -> list[dict]:
    """Never raises. Missing file -> []. Any line that is not valid JSON, or not an object, is
    silently skipped (a shared, append-only, multi-writer log is not assumed to be pristine)."""
    out: list[dict] = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(rec, dict):
                    out.append(rec)
    except OSError:
        return []
    return out


def _ts_to_epoch(ts: str) -> float | None:
    """`ts` is always UTC (the "Z" suffix). calendar.timegm() interprets the struct_time as UTC
    directly and returns its epoch -- unlike time.mktime() - time.timezone, which is wrong by up
    to 1h on a host in a DST-observing zone during DST (time.timezone is always the STANDARD-time
    offset, never the DST-adjusted one)."""
    try:
        return float(calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")))
    except (ValueError, TypeError):
        return None


def select_candidates(records: list[dict], since_hours: float, limit: int) -> list[dict]:
    """Records that (a) are a source shadow record for this front, (b) have at least one
    omitted_signatures entry, (c) are newer than `since_hours`, and (d) do not already have a
    shadow-join counterpart. Oldest first (so a bounded --limit makes progress across runs
    instead of re-scanning the same newest N forever)."""
    joined_keys: set[tuple[str, str]] = set()
    sources: list[dict] = []
    cutoff = time.time() - since_hours * 3600 if since_hours > 0 else None

    for rec in records:
        if rec.get("mode") == JOIN_MODE and rec.get("experiment") in SOURCE_EXPERIMENTS:
            eid = rec.get("entity_id")
            if eid is not None:
                joined_keys.add((rec["experiment"], eid))
            continue
        if rec.get("mode") != "shadow" or rec.get("experiment") not in SOURCE_EXPERIMENTS:
            continue
        sigs = rec.get("omitted_signatures")
        if not sigs:
            continue  # nothing to look for -- not a candidate, not a "no" either
        if not rec.get("transcript_path") or not rec.get("tool_use_id") or not rec.get("entity_id"):
            continue  # jev-experiment.jsonl is shared/multi-writer -- a malformed line missing
            # any of these must be skipped here, not crash later on r["entity_id"]/rec["entity_id"]
        ts_epoch = _ts_to_epoch(rec.get("ts", ""))
        if cutoff is not None and ts_epoch is not None and ts_epoch < cutoff:
            continue
        sources.append(rec)

    candidates = [r for r in sources if (r["experiment"], r["entity_id"]) not in joined_keys]
    candidates.sort(key=lambda r: r.get("ts", ""))
    return candidates[:limit] if limit > 0 else candidates


def scan_transcript_for_signatures(transcript_path: str, tool_use_id: str, signatures: list[str]) -> tuple[bool | None, str | None]:
    """(referenced_later, matched_signature). None when the transcript is missing/unreadable or
    `tool_use_id` cannot be located in it (unknown, never coerced to False). Otherwise True/False
    depending on whether any signature appears, as a raw substring, in any line AFTER the split
    point.

    The split point is the END of the CONTIGUOUS run of lines (starting at the first occurrence)
    that mention `tool_use_id` -- not just the first such line. A real tool call's own tool_use
    and tool_result entries are typically two ADJACENT lines that both embed the id (the result
    carries it back for correlation), and the tool_result line's `content` is exactly the raw
    stdout/stderr the omitted_signatures were extracted from in the first place. Splitting after
    only the FIRST of that pair would leave the tool's own result line inside the "later" window,
    so every signature (which by construction is a substring of that same result) would match on
    its own call -- referenced_later would fire on essentially every candidate, regardless of
    whether the agent ever actually looked at it again. Extending the split point across the
    whole contiguous id-bearing run treats that adjacent call+result block as "at the call", and
    only a genuinely later line counts."""
    try:
        lines = Path(transcript_path).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return None, None

    split_idx = None
    for i, ln in enumerate(lines):
        if tool_use_id in ln:
            split_idx = i
        elif split_idx is not None:
            break  # contiguous run of id-bearing lines has ended
    if split_idx is None:
        return None, None

    for ln in lines[split_idx + 1 :]:
        for sig in signatures:
            if sig and sig in ln:
                return True, sig
    return False, None


def _log(record: dict) -> None:
    je.JEV_LOG.parent.mkdir(parents=True, exist_ok=True)
    with je.JEV_LOG.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def run(since_hours: float, limit: int, dry_run: bool) -> int:
    records = read_jsonl(je.JEV_LOG)
    candidates = select_candidates(records, since_hours, limit)
    processed = 0
    for rec in candidates:
        referenced_later, matched = scan_transcript_for_signatures(
            rec["transcript_path"], rec["tool_use_id"], rec["omitted_signatures"]
        )
        join_rec = {
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "mode": JOIN_MODE,
            "experiment": rec["experiment"],
            "entity_id": rec["entity_id"],
            "referenced_later": referenced_later,
            "matched_signature": matched,
        }
        if dry_run:
            print(json.dumps(join_rec, ensure_ascii=False))
        else:
            _log(join_rec)
        processed += 1
    print(f"jev_cut_output_join: processed {processed} candidate(s) (dry_run={dry_run})")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selftest")
    r = sub.add_parser("run")
    r.add_argument("--log", default=None, help="override jev-experiment.jsonl path (test seam)")
    r.add_argument("--since-hours", type=float, default=DEFAULT_SINCE_HOURS)
    r.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    r.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    if args.cmd == "selftest":
        return _selftest()

    if args.log:
        je.JEV_LOG = Path(args.log)

    DEFAULT_LOG_DIR.mkdir(parents=True, exist_ok=True)
    lock_fd = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("jev_cut_output_join: another instance holds the lock, exiting", file=sys.stderr)
        return 0  # not an error: the daily report tolerates a skipped join (best-effort)
    try:
        return run(args.since_hours, args.limit, args.dry_run)
    finally:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        lock_fd.close()


def _selftest() -> int:
    import tempfile

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

    with tempfile.TemporaryDirectory() as td:
        transcript = Path(td) / "t.jsonl"
        transcript.write_text(
            "\n".join(
                [
                    '{"type":"assistant","text":"running the command now"}',
                    '{"type":"tool_result","tool_use_id":"tu-1","content":"big output here"}',
                    '{"type":"assistant","text":"nothing interesting"}',
                    '{"type":"assistant","text":"ah, ga-wk0qi2 is the bead I need"}',
                ]
            )
        )
        r_hit, sig_hit = scan_transcript_for_signatures(str(transcript), "tu-1", ["ga-wk0qi2", "/some/other/path"])
        ok("signature referenced in a later line -> True", r_hit is True and sig_hit == "ga-wk0qi2")

        r_miss, sig_miss = scan_transcript_for_signatures(str(transcript), "tu-1", ["/never/appears", "no-such-id"])
        ok("no signature appears later -> False", r_miss is False and sig_miss is None)

        r_notfound, _ = scan_transcript_for_signatures(str(transcript), "tu-does-not-exist", ["ga-wk0qi2"])
        ok("tool_use_id not found in transcript -> None (unknown, not False)", r_notfound is None)

        r_missing, _ = scan_transcript_for_signatures(str(Path(td) / "no-such-file.jsonl"), "tu-1", ["x"])
        ok("missing transcript file -> None", r_missing is None)

        # a signature BEFORE the split point (e.g. in the tool call's own line) must not count
        transcript2 = Path(td) / "t2.jsonl"
        transcript2.write_text(
            "\n".join(
                [
                    '{"type":"tool_use","tool_use_id":"tu-2","input":"mentions ga-early already"}',
                    '{"type":"tool_result","tool_use_id":"tu-2","content":"output"}',
                    '{"type":"assistant","text":"done, nothing more said"}',
                ]
            )
        )
        r_before, _ = scan_transcript_for_signatures(str(transcript2), "tu-2", ["ga-early"])
        ok(
            "a signature that only appears in lines AT/BEFORE the split point does not count as 'referenced later'",
            r_before is False,
        )

        # the real-transcript shape this front actually runs against: tool_use and tool_result
        # are ADJACENT lines sharing the same tool_use_id, and the tool_result's own `content` IS
        # the raw stdout/stderr the omitted_signatures were extracted from -- so it embeds the
        # signature by construction. This must NOT count as "referenced later": it is the call's
        # own result, not a later turn looking back at it. (This is the exact case gate_run
        # ga-qksyc3 found unguarded by the prior transcript2 case above, whose tool_result content
        # was the literal string "output" and so never exercised the bug at all.)
        transcript3 = Path(td) / "t3.jsonl"
        transcript3.write_text(
            "\n".join(
                [
                    '{"type":"tool_use","tool_use_id":"tu-3","input":"run pytest"}',
                    '{"type":"tool_result","tool_use_id":"tu-3","content":"...300 passed... ga-adjacent-sig ..."}',
                    '{"type":"assistant","text":"nothing more said about it"}',
                ]
            )
        )
        r_own_result, _ = scan_transcript_for_signatures(str(transcript3), "tu-3", ["ga-adjacent-sig"])
        ok(
            "a signature that appears only inside the call's own ADJACENT tool_result content "
            "does not count as 'referenced later' (the bug gate_run ga-qksyc3 found)",
            r_own_result is False,
        )

        # ...but a signature in a line genuinely AFTER that same adjacent call+result pair must
        # still be detected -- the fix must not overcorrect into never finding real later uses.
        transcript4 = Path(td) / "t4.jsonl"
        transcript4.write_text(
            "\n".join(
                [
                    '{"type":"tool_use","tool_use_id":"tu-4","input":"run pytest"}',
                    '{"type":"tool_result","tool_use_id":"tu-4","content":"...300 passed... ga-adjacent-sig ..."}',
                    '{"type":"assistant","text":"I still need ga-adjacent-sig for the next step"}',
                ]
            )
        )
        r_genuine_later, sig_genuine_later = scan_transcript_for_signatures(
            str(transcript4), "tu-4", ["ga-adjacent-sig"]
        )
        ok(
            "a signature genuinely referenced AFTER the adjacent call+result pair is still "
            "detected as 'referenced later'",
            r_genuine_later is True and sig_genuine_later == "ga-adjacent-sig",
        )

        # ---- read_jsonl: tolerant of garbage lines ----
        garbage = Path(td) / "garbage.jsonl"
        garbage.write_text('{"a":1}\nnot json\n\n{"b":2}\n[1,2,3]\n')
        recs = read_jsonl(garbage)
        ok("read_jsonl skips malformed/non-object lines, keeps valid ones", recs == [{"a": 1}, {"b": 2}])
        ok("read_jsonl on a missing file -> []", read_jsonl(Path(td) / "nope.jsonl") == [])

        # ---- _ts_to_epoch: must be a true UTC->epoch conversion, independent of host timezone
        # or DST (the old time.mktime(...) - time.timezone always used the STANDARD-time offset,
        # off by up to 1h on a DST-observing host during DST) ----
        ok("_ts_to_epoch: UTC epoch zero round-trips exactly", _ts_to_epoch("1970-01-01T00:00:00Z") == 0.0)
        ok("_ts_to_epoch: malformed timestamp -> None", _ts_to_epoch("not-a-timestamp") is None)

        # ---- select_candidates ----
        base_ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        recs2 = [
            {"mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "e1", "omitted_signatures": ["s1"], "transcript_path": "/tmp/a", "tool_use_id": "tu-a", "ts": base_ts},
            {"mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "e2", "omitted_signatures": [], "transcript_path": "/tmp/b", "tool_use_id": "tu-b", "ts": base_ts},
            {"mode": "shadow", "experiment": "cut-output-jev", "entity_id": "e3", "omitted_signatures": ["s3"], "transcript_path": "/tmp/c", "tool_use_id": "tu-c", "ts": base_ts},
            {"mode": "shadow-join", "experiment": "cut-output-fixed", "entity_id": "e1", "referenced_later": False},
            {"mode": "shadow", "experiment": "some-other-front", "entity_id": "e4", "omitted_signatures": ["s4"], "transcript_path": "/tmp/d", "tool_use_id": "tu-d", "ts": base_ts},
            # malformed record (shared multi-writer log, "not assumed to be pristine"): otherwise
            # a valid shadow candidate but missing entity_id -- must be skipped here, not crash
            # r["entity_id"] later in select_candidates or rec["entity_id"] in run().
            {"mode": "shadow", "experiment": "cut-output-fixed", "omitted_signatures": ["s5"], "transcript_path": "/tmp/e", "tool_use_id": "tu-e", "ts": base_ts},
        ]
        cands = select_candidates(recs2, since_hours=0, limit=10)
        cand_ids = {c["entity_id"] for c in cands}
        ok("select_candidates: e1 already joined -> excluded", "e1" not in cand_ids)
        ok("select_candidates: e2 has no signatures -> excluded", "e2" not in cand_ids)
        ok("select_candidates: e3 (unjoined, has signatures) -> included", "e3" in cand_ids)
        ok("select_candidates: e4 belongs to a different experiment -> excluded", "e4" not in cand_ids)
        ok("select_candidates: record missing entity_id -> excluded, does not raise", len(cands) == 1)

        cands_limited = select_candidates(recs2, since_hours=0, limit=1)
        ok("select_candidates respects --limit", len(cands_limited) == 1)

        # ---- run(): end to end against a temp log, idempotent on rerun ----
        log_path = Path(td) / "jev-experiment.jsonl"
        orig_log = je.JEV_LOG
        try:
            je.JEV_LOG = log_path
            src_transcript = Path(td) / "src.jsonl"
            src_transcript.write_text(
                '{"tool_use_id":"tu-src"}\n{"text":"later mentions ga-found-me"}\n'
            )
            with log_path.open("w") as f:
                f.write(json.dumps({
                    "mode": "shadow", "experiment": "cut-output-fixed", "entity_id": "e-src",
                    "omitted_signatures": ["ga-found-me"], "transcript_path": str(src_transcript),
                    "tool_use_id": "tu-src", "ts": base_ts,
                }) + "\n")
            run(since_hours=0, limit=10, dry_run=False)
            lines_after = log_path.read_text().splitlines()
            ok("run(): appended exactly one join record", len(lines_after) == 2)
            joined = json.loads(lines_after[1])
            ok("run(): join record has referenced_later=True", joined["referenced_later"] is True)
            ok("run(): join record mode is shadow-join", joined["mode"] == JOIN_MODE)

            run(since_hours=0, limit=10, dry_run=False)
            lines_after2 = log_path.read_text().splitlines()
            ok("run(): rerun is idempotent (no duplicate join record)", len(lines_after2) == 2)
        finally:
            je.JEV_LOG = orig_log

    print(f"\njev_cut_output_join selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""jev_gate_verdict_experiment.py (ga-aijm2v.3/F5) — SHADOW MODE: does Jev predict a
quality-gate REJECTION before the expensive reviewer session runs?

WHY (see ga-aijm2v epic): every gate review is a full Claude session reading the whole
diff; a bead can burn several of those on repeated FAILs (e.g. wa-qeorh, 3 reviews for
one fix). Hypothesis to measure (low expectation — Jev only reads text, it never
executes code): given the commit message + diff summary + the kinds of things this
gate's reviewers usually reject on, does Jev's yes/no lean toward "will fail" agree
with the real verdict? NOTHING here changes gate behavior — this only measures
agreement, exactly like every other SOMBRA front built on jev_experiment.py's
evaluate_shadow() (F0, ga-aijm2v.1).

DESIGN — why this joins PAST verdicts instead of hooking the dispatcher directly:
evaluate_shadow() needs `decisao_atual` (the real verdict) at call time, but the real
verdict for a gate run isn't known until minutes after submission (a reviewer session
has to finish) — by which point quality-gate-dispatcher.sh's own diff-building
variables (DIFF_SUMMARY/DIFF_FULL) may not even be in scope (Phase C, the common path,
finalizes a run in a LATER sweep's process, which never ran that submission's Step 7).
Rather than add a live Jev call inside that 13k-line, heavily-scarred dispatcher (real
blast radius: it is launchd-driven infra shared by every rig), this script runs
separately (wired into the existing daily jev-daily-report.sh cadence — see that file)
and reconstructs each gate run's exact diff AFTER the fact from two SHAs that are
already durably recorded at submission time: `base_commit` on the /gate-done MARKER
bead and `branch_sha` on the GATE_RUN bead (see gate-done.md's marker-creation dump and
quality-gate-dispatcher.sh's Step 6 gate-run-bead dump). Those commits stay reachable in
the rig's git history (merged into main, or still on an unmerged branch) for long enough
that a same-day-or-next-day batch join is reliable, and — because Jev is asked using
only the diff/commit text, the exact same inputs a human reviewer would have seen before
reviewing — calling it after the verdict is known is scientifically equivalent to
calling it before: the verdict itself is never part of Jev's prompt. Net effect: ZERO
lines changed in quality-gate-dispatcher.sh or /gate-done, and evaluate_shadow() (F0) is
used completely unmodified.

Idempotent: re-running against the same quality-gate.jsonl never double-logs (dedup by
`gate_run`, checked against jev-experiment.jsonl's own existing "gate-verdict" entries).
Every git/bd/network call is best-effort and skips (never raises) on failure — a rig
this script can't resolve, a marker bead it can't read, or a SHA git no longer has just
means that one gate run is left unmeasured, never a crash of the batch.

CLI:
  python3 jev_gate_verdict_experiment.py run [--gc-city PATH] [--qg-log PATH]
      [--dry-run] [--limit N] [--since-days N]
    Scans quality-gate.jsonl for new dispatcher_complete PASS/FAIL events from the
    last --since-days days (default 4 — see DEFAULT_SINCE_DAYS), reconstructs each
    one's diff, calls jev_experiment.evaluate_shadow(), and logs (unless --dry-run)
    via jev_experiment's own _log() — same file, same format, same JEV_EXPERIMENT_LOG
    override every other front already uses.
  python3 jev_gate_verdict_experiment.py selftest
    Mocked (git/bd/gc/network) — no live credential or repo needed.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import jev_experiment  # noqa: E402

DEFAULT_GC_CITY = os.environ.get("JEV_GC_CITY", "/Users/athos/gt/.gascity-gastown-hq")
EXPERIMENT = "gate-verdict"
QUESTION_KEY = "would_fail"
CONFIDENCE_THRESHOLD = 0.85
DIFF_LINE_BUDGET = 250
# ga-aijm2v.3: quality-gate.jsonl is an ever-growing append-only log; measured live
# against this city's real file, a run with NO recency filter churned through
# thousands of historical entries whose marker/gate-run beads were long since reaped
# -- the base_commit/branch_sha those beads held are gone with them, so those gate
# runs are structurally unmeasurable now, no matter how the diff is reconstructed.
# A daily job re-paying that full-history bd/git cost every single day, for entries
# it will never be able to log, is pure waste. Default window is generous (a few
# missed daily runs still get fully covered) without re-walking history.
DEFAULT_SINCE_DAYS = 4.0

INSTRUCTIONS = (
    "You are shown the commit log and diff for a code change submitted to an "
    "automated quality gate. You cannot run the code -- judge from the text alone. "
    "Predict whether the gate's reviewer will REJECT (FAIL) this change. Common "
    "reasons this gate rejects a change: (1) a 'third state' bug -- code treats "
    "'error' and 'empty/not found' as the same value; (2) an unverified claim -- the "
    "diff or its own comments assert something works with no evidence in the diff; "
    "(3) a comment that promises more than the code actually does; (4) a fix that "
    "only patches the one instance a reviewer might name, not the whole class of the "
    "bug; (5) a new test that would also pass against the OLD, buggy code, proving "
    "nothing; (6) error handling, a fallback, or validation for a scenario that "
    "cannot actually happen; (7) refactoring or abstraction beyond what the task "
    "required; (8) editing a shared/critical file without isolating the change or "
    "checking for a concurrent edit."
)
TRUE_DESC = "The gate reviewer will REJECT this change (a FAIL verdict)."
FALSE_DESC = "The gate reviewer will APPROVE this change (a PASS verdict)."


def _run(cmd: list[str], timeout: float | None = None) -> subprocess.CompletedProcess | None:
    """The one seam all git/bd/gc calls go through -- tests mock this single function
    instead of every individual call site."""
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return None


def _parse_ts(ts) -> datetime | None:
    if not ts or not isinstance(ts, str):
        return None
    try:
        return datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        return None


def iter_dispatcher_complete(qg_log_path, since_days: float | None = None):
    """Yields dispatcher_complete events with a real PASS/FAIL result and a gate_run id.
    Malformed lines and non-terminal/other events (guard_queued, REQUEUED, ...) are
    silently skipped -- this is a best-effort scan of an append-only log, not a strict
    parser.

    since_days, when given, additionally skips any event older than that many days by
    its own `ts` field -- BEFORE any bd/git resolution is attempted. A missing or
    unparseable `ts` is treated as "too old to trust" (excluded), same fail-toward-
    skip discipline as everywhere else in this script; every real dispatcher_complete
    line observed in production always carries a well-formed `ts`, so this only ever
    matters for a line so malformed it has bigger problems anyway."""
    cutoff = datetime.now(timezone.utc) - timedelta(days=since_days) if since_days is not None else None
    p = Path(qg_log_path)
    if not p.exists():
        return
    with p.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(ev, dict):
                continue
            if ev.get("event") != "dispatcher_complete":
                continue
            if ev.get("result") not in ("PASS", "FAIL"):
                continue
            if not ev.get("gate_run"):
                continue
            if cutoff is not None:
                ts = _parse_ts(ev.get("ts"))
                if ts is None or ts < cutoff:
                    continue
            yield ev


def already_processed(jev_log_path, experiment: str) -> set[str]:
    """entity_ids already fully logged (mode=='shadow') for this experiment. Missing
    log file -> empty set (first run ever), never an error."""
    seen: set[str] = set()
    p = Path(jev_log_path)
    if not p.exists():
        return seen
    with p.open("r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(ev, dict) and ev.get("mode") == "shadow" and ev.get("experiment") == experiment and ev.get("entity_id"):
                seen.add(ev["entity_id"])
    return seen


def _field(description: str | None, field: str) -> str | None:
    """Pulls one `key: value` line out of a bead description (the /gate-done and
    Step-6 gate-run-bead dumps are always this shape). Only captures the first
    physical line of the value -- fine for base_commit/branch_sha (always a bare
    SHA) but would silently truncate a self_audit note an agent happened to write
    with embedded newlines. Acceptable: self_audit is supplementary context for
    Jev's prompt, not load-bearing like the two SHA fields are."""
    if not description:
        return None
    m = re.search(rf"^{re.escape(field)}:\s*(.*)$", description, re.MULTILINE)
    return m.group(1).strip() if m else None


def _bd_show(gc_city: str, bead_id: str) -> dict | None:
    r = _run(["bd", "-C", gc_city, "show", bead_id, "--json"], timeout=30)
    if r is None or r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    if isinstance(data, list):
        for item in data:
            if isinstance(item, dict) and item.get("id") == bead_id:
                return item
        return None
    if isinstance(data, dict):
        return data
    return None


def _rig_paths() -> dict[str, str]:
    # gc rig list --json can legitimately take many seconds under Dolt load (ga-eu2x) --
    # this is a daily batch job, not latency-sensitive, so give it room rather than risk
    # a tight bound reading a slow-but-healthy answer as "no rigs".
    r = _run(["gc", "rig", "list", "--json"], timeout=90)
    if r is None or r.returncode != 0:
        return {}
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}
    out: dict[str, str] = {}
    for rig in data.get("rigs", []) or []:
        name, path = rig.get("name"), rig.get("path")
        if name and path:
            out[name] = path
    return out


def resolve_rig_root(rig_name: str, rig_paths: dict[str, str]) -> str | None:
    """A rig's `path` (from `gc rig list`) is not always its git repo root -- e.g. the
    'gascity' rig's path is a subdirectory of the actual repo root one level up. Always
    ask git, never assume `path` IS the root (see this city's own CLAUDE.md doctrine on
    the 3 things named 'gascity')."""
    path = rig_paths.get(rig_name)
    if not path:
        return None
    r = _run(["git", "-C", path, "rev-parse", "--show-toplevel"])
    if r is None or r.returncode != 0:
        return None
    top = r.stdout.strip()
    return top or None


def _commit_exists(repo_root: str, sha: str) -> bool:
    r = _run(["git", "-C", repo_root, "cat-file", "-e", f"{sha}^{{commit}}"])
    return r is not None and r.returncode == 0


def ensure_commits_available(repo_root: str, *shas: str) -> bool:
    if all(_commit_exists(repo_root, s) for s in shas):
        return True
    _run(["git", "-C", repo_root, "fetch", "origin", "--quiet"], timeout=60)
    return all(_commit_exists(repo_root, s) for s in shas)


def _git_text(repo_root: str, args: list[str]) -> str | None:
    r = _run(["git", "-C", repo_root] + args)
    if r is None or r.returncode != 0:
        return None
    return r.stdout


def build_state_text(repo_root: str, base_sha: str, head_sha: str, self_audit: str | None,
                      diff_line_budget: int = DIFF_LINE_BUDGET) -> str:
    log_out = (_git_text(repo_root, ["log", "--format=%H %s", f"{base_sha}..{head_sha}"]) or "(no commits found)").strip()
    stat_out = (_git_text(repo_root, ["diff", "--stat", f"{base_sha}...{head_sha}"]) or "(empty)").strip()
    diff_out = _git_text(repo_root, ["diff", f"{base_sha}...{head_sha}"]) or ""
    diff_lines = diff_out.splitlines()
    truncated = len(diff_lines) > diff_line_budget
    shown = "\n".join(diff_lines[:diff_line_budget])
    header = (
        f"DIFF (first {diff_line_budget} of {len(diff_lines)} lines, truncated):"
        if truncated else "DIFF (complete):"
    )
    parts = ["COMMIT LOG:", log_out, "", "DIFF STAT:", stat_out, "", header, shown]
    if self_audit:
        parts += ["", "SUBMITTER'S SELF-AUDIT NOTE:", self_audit]
    return "\n".join(parts)


def process_event(ev: dict, gc_city: str, rig_paths: dict[str, str]):
    """Returns (status, detail). status=='logged' -> detail is the shadow-mode dict
    ready for jev_experiment._log(); any other status -> detail is a short reason
    string and Jev was never called."""
    gate_run = ev["gate_run"]
    marker = ev.get("marker")
    rig = ev.get("rig")
    result = ev["result"]

    repo_root = resolve_rig_root(rig, rig_paths) if rig else None
    if not repo_root:
        return "skip_no_rig", f"rig={rig!r} not resolvable to a git repo root"

    marker_bead = _bd_show(gc_city, marker) if marker else None
    if not marker_bead:
        return "skip_no_marker", f"marker={marker!r} unreadable"
    base_commit = _field(marker_bead.get("description", ""), "base_commit")
    self_audit = _field(marker_bead.get("description", ""), "self_audit")
    if not base_commit:
        return "skip_no_base_commit", f"marker={marker} has no base_commit field"

    gate_run_bead = _bd_show(gc_city, gate_run)
    branch_sha = _field(gate_run_bead.get("description", "") if gate_run_bead else "", "branch_sha")
    if not branch_sha:
        return "skip_no_branch_sha", f"gate_run={gate_run} has no branch_sha field"

    if not ensure_commits_available(repo_root, base_commit, branch_sha):
        return "skip_commits_unavailable", f"{base_commit[:12]}..{branch_sha[:12]} not resolvable in {repo_root}"

    state = build_state_text(repo_root, base_commit, branch_sha, self_audit)

    entry = jev_experiment.evaluate_shadow(
        entity_id=gate_run,
        experiment=EXPERIMENT,
        state=state,
        question_key=QUESTION_KEY,
        instructions=INSTRUCTIONS,
        true_desc=TRUE_DESC,
        false_desc=FALSE_DESC,
        decisao_atual=(result == "FAIL"),
        confidence_threshold=CONFIDENCE_THRESHOLD,
    )
    return "logged", entry


def run(gc_city: str | None = None, qg_log: str | None = None, dry_run: bool = False,
        limit: int | None = None, since_days: float | None = DEFAULT_SINCE_DAYS) -> dict:
    gc_city = gc_city or DEFAULT_GC_CITY
    qg_log = qg_log or f"{gc_city}/.gc/quality-gate.jsonl"
    seen = already_processed(jev_experiment.JEV_LOG, EXPERIMENT)
    rig_paths = _rig_paths()
    counts: dict[str, int] = {"considered": 0, "skipped_dup": 0}

    for ev in iter_dispatcher_complete(qg_log, since_days=since_days):
        counts["considered"] += 1
        gate_run = ev["gate_run"]
        if gate_run in seen:
            counts["skipped_dup"] += 1
            continue
        if limit is not None and counts.get("logged", 0) >= limit:
            break
        status, detail = process_event(ev, gc_city, rig_paths)
        counts[status] = counts.get(status, 0) + 1
        if status == "logged":
            if not dry_run:
                jev_experiment._log(detail)
            seen.add(gate_run)
            print(
                f"[{status}] gate_run={gate_run} bead={ev.get('bead')} "
                f"decisao_atual={detail['decisao_atual']} jev_ok={detail['jev_ok']} "
                f"jev_noul={detail.get('jev_noul')} agree={detail.get('agree')}"
            )
        else:
            print(f"[{status}] gate_run={gate_run} bead={ev.get('bead')} -- {detail}")

    other_skips = sum(v for k, v in counts.items() if k not in ("considered", "logged", "skipped_dup"))
    print(
        f"jev_gate_verdict_experiment: considered={counts['considered']} "
        f"logged={counts.get('logged', 0)} skipped_dup={counts['skipped_dup']} "
        f"other_skips={other_skips}"
    )
    return counts


def _selftest() -> int:
    import tempfile
    from unittest import mock

    this = sys.modules[__name__]
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

    def cp(returncode=0, stdout="", stderr=""):
        return subprocess.CompletedProcess(args=[], returncode=returncode, stdout=stdout, stderr=stderr)

    with tempfile.TemporaryDirectory() as td:
        qg = Path(td) / "quality-gate.jsonl"
        qg.write_text(
            '{"event":"guard_queued","gate_run":"ga-x1"}\n'
            '{"event":"dispatcher_complete","result":"PASS","gate_run":"ga-x2","marker":"ga-m2","bead":"b2","rig":"gascity"}\n'
            "not json at all\n"
            '{"event":"dispatcher_complete","result":"REQUEUED","gate_run":"ga-x3"}\n'
            '{"event":"dispatcher_complete","result":"FAIL","gate_run":"ga-x4","marker":"ga-m4","bead":"b4","rig":"whatsapp_automation"}\n'
        )
        events = list(iter_dispatcher_complete(qg))
        ok(
            "iter_dispatcher_complete: skips non-terminal events, non-JSON lines, and non PASS/FAIL results",
            [e["gate_run"] for e in events] == ["ga-x2", "ga-x4"],
        )
        ok(
            "iter_dispatcher_complete: since_days=None (default) does not require a ts field at all",
            all("ts" not in e for e in events),
        )

        qg_ts = Path(td) / "quality-gate-ts.jsonl"
        now = datetime.now(timezone.utc)
        recent_ts = (now - timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ")
        old_ts = (now - timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ")
        qg_ts.write_text(
            json.dumps({"event": "dispatcher_complete", "result": "PASS", "gate_run": "ga-recent", "ts": recent_ts}) + "\n"
            + json.dumps({"event": "dispatcher_complete", "result": "FAIL", "gate_run": "ga-old", "ts": old_ts}) + "\n"
            + json.dumps({"event": "dispatcher_complete", "result": "PASS", "gate_run": "ga-no-ts"}) + "\n"
        )
        with_filter = [e["gate_run"] for e in iter_dispatcher_complete(qg_ts, since_days=4.0)]
        ok(
            "iter_dispatcher_complete: since_days excludes an old event and one with no ts, keeps a recent one",
            with_filter == ["ga-recent"],
        )
        without_filter = [e["gate_run"] for e in iter_dispatcher_complete(qg_ts, since_days=None)]
        ok(
            "iter_dispatcher_complete: since_days=None still includes everything, ts or not",
            without_filter == ["ga-recent", "ga-old", "ga-no-ts"],
        )

        jl = Path(td) / "jev-experiment.jsonl"
        jl.write_text(
            '{"mode":"shadow","experiment":"gate-verdict","entity_id":"ga-x2"}\n'
            '{"mode":"shadow","experiment":"other-front","entity_id":"ga-x4"}\n'
            '{"mode":"shadow_pending","experiment":"gate-verdict","entity_id":"ga-x9"}\n'
        )
        ok("already_processed: only counts mode=shadow entries for the right experiment",
           already_processed(jl, "gate-verdict") == {"ga-x2"})
        ok("already_processed: missing log file -> empty set, not an error",
           already_processed(Path(td) / "nope.jsonl", "gate-verdict") == set())

    desc = "branch: fix/x\nbase_commit: deadbeef\nself_audit: multi word note here\n"
    ok("_field: extracts base_commit", _field(desc, "base_commit") == "deadbeef")
    ok("_field: missing field -> None", _field(desc, "branch_sha") is None)
    ok("_field: None description -> None, never raises", _field(None, "base_commit") is None)

    def fake_run_happy(cmd, timeout=None):
        if cmd[:2] == ["git", "-C"] and cmd[3:5] == ["rev-parse", "--show-toplevel"]:
            return cp(0, "/repo\n")
        if cmd[:3] == ["git", "-C", "/repo"]:
            if cmd[3] == "cat-file":
                return cp(0)
            if cmd[3:5] == ["log", "--format=%H %s"]:
                return cp(0, "abc123 fix(x): thing\n")
            if cmd[3:5] == ["diff", "--stat"]:
                return cp(0, " f.py | 2 +-\n")
            if cmd[3] == "diff":
                return cp(0, "diff --git a/f.py b/f.py\n+x\n")
        raise AssertionError(f"unexpected command in happy-path fake_run: {cmd}")

    with mock.patch.object(this, "_run", side_effect=fake_run_happy):
        ok("resolve_rig_root: uses git rev-parse --show-toplevel, not the raw rig path",
           resolve_rig_root("gascity", {"gascity": "/whatever"}) == "/repo")
        ok("ensure_commits_available: both SHAs already present -> True, no fetch needed",
           ensure_commits_available("/repo", "aaa", "bbb"))
        state = build_state_text("/repo", "aaa", "bbb", None)
        ok("build_state_text: includes commit log and diff stat",
           "abc123 fix(x): thing" in state and "f.py | 2 +-" in state)
        ok("build_state_text: omits self-audit section when none given", "SELF-AUDIT" not in state)
        ok("build_state_text: includes self-audit note when given",
           "checked X and Y" in build_state_text("/repo", "aaa", "bbb", "checked X and Y"))

    ok("resolve_rig_root: unknown rig name -> None, no git call attempted",
       resolve_rig_root("nope", {"gascity": "/whatever"}) is None)

    calls = []

    def fake_run_missing_then_fetch(cmd, timeout=None):
        calls.append(cmd)
        if cmd[3] == "cat-file":
            fetched = any(c[3:5] == ["fetch", "origin"] for c in calls[:-1])
            return cp(0 if fetched else 1)
        if cmd[3:5] == ["fetch", "origin"]:
            return cp(0)
        raise AssertionError(f"unexpected command: {cmd}")

    with mock.patch.object(this, "_run", side_effect=fake_run_missing_then_fetch):
        ok("ensure_commits_available: missing SHA -> fetches once, re-checks, succeeds",
           ensure_commits_available("/repo", "ccc"))
        ok("ensure_commits_available: fetch attempted exactly once",
           sum(1 for c in calls if c[3:5] == ["fetch", "origin"]) == 1)

    def fake_run_always_missing(cmd, timeout=None):
        if cmd[3] == "cat-file":
            return cp(1)
        if cmd[3:5] == ["fetch", "origin"]:
            return cp(0)
        raise AssertionError(f"unexpected command: {cmd}")

    with mock.patch.object(this, "_run", side_effect=fake_run_always_missing):
        ok("ensure_commits_available: still missing after fetch -> False, never raises",
           ensure_commits_available("/repo", "ddd") is False)

    def fake_run_bd(cmd, timeout=None):
        if cmd[:2] == ["bd", "-C"] and "show" in cmd:
            bead_id = cmd[cmd.index("show") + 1]
            if bead_id == "ga-good":
                return cp(0, json.dumps([{"id": "ga-good", "description": "base_commit: xyz\n"}, {"id": "ga-good.parent"}]))
            if bead_id == "ga-missing":
                return cp(1, "", "not found")
            if bead_id == "ga-badjson":
                return cp(0, "not json")
        raise AssertionError(f"unexpected command: {cmd}")

    with mock.patch.object(this, "_run", side_effect=fake_run_bd):
        b = _bd_show("/city", "ga-good")
        ok("_bd_show: finds the matching id inside the returned array",
           b is not None and b.get("description", "").startswith("base_commit"))
        ok("_bd_show: bd show failure (nonzero exit) -> None, not a crash", _bd_show("/city", "ga-missing") is None)
        ok("_bd_show: unparseable JSON -> None, not a crash", _bd_show("/city", "ga-badjson") is None)

    ev = {"gate_run": "ga-run1", "marker": "ga-mark1", "bead": "b1", "rig": "gascity", "result": "FAIL"}

    def fake_run_e2e(cmd, timeout=None):
        if cmd[:2] == ["gc", "rig"]:
            return cp(0, json.dumps({"rigs": [{"name": "gascity", "path": "/whatever"}]}))
        if cmd[:3] == ["git", "-C", "/whatever"] and cmd[3:5] == ["rev-parse", "--show-toplevel"]:
            return cp(0, "/repo\n")
        if cmd[:2] == ["bd", "-C"] and "show" in cmd:
            bead_id = cmd[cmd.index("show") + 1]
            if bead_id == "ga-mark1":
                return cp(0, json.dumps([{"id": "ga-mark1", "description": "base_commit: base1\nself_audit: looked at it\n"}]))
            if bead_id == "ga-run1":
                return cp(0, json.dumps([{"id": "ga-run1", "description": "branch_sha: head1\n"}]))
        if cmd[:3] == ["git", "-C", "/repo"]:
            if cmd[3] == "cat-file":
                return cp(0)
            if cmd[3:5] == ["log", "--format=%H %s"]:
                return cp(0, "head1 fix(x): thing\n")
            if cmd[3:5] == ["diff", "--stat"]:
                return cp(0, " f.py | 2 +-\n")
            if cmd[3] == "diff":
                return cp(0, "diff --git a/f.py b/f.py\n+x\n")
        raise AssertionError(f"unexpected command in e2e fake_run: {cmd}")

    live_shape = json.dumps(
        {"result": {"result": {"answers": {QUESTION_KEY: {"type": "noul", "noul": 0.7}},
                                "usage": {"input_tokens": 5, "output_tokens": 1}}}}
    ).encode()

    def _fake_response(body: bytes):
        cm = mock.MagicMock()
        cm.read.return_value = body
        cm.__enter__.return_value = cm
        cm.__exit__.return_value = False
        return cm

    with mock.patch.object(this, "_run", side_effect=fake_run_e2e), \
         mock.patch.object(jev_experiment, "CF_ACCOUNT_ID", "0123456789abcdef0123456789abcdef"), \
         mock.patch.object(jev_experiment, "CF_API_TOKEN", "tok"), \
         mock.patch("urllib.request.urlopen", return_value=_fake_response(live_shape)):
        status, detail = process_event(ev, "/city", _rig_paths())
    ok(
        "process_event: end-to-end happy path logs a shadow entry with decisao_atual=True (FAIL)",
        status == "logged" and detail["decisao_atual"] is True
        and detail["entity_id"] == "ga-run1" and detail["experiment"] == EXPERIMENT,
    )

    with mock.patch("urllib.request.urlopen", side_effect=AssertionError("must not call Jev on a skip path")):
        with mock.patch.object(this, "_run", side_effect=lambda cmd, timeout=None: cp(0, json.dumps({"rigs": []}))):
            status, _detail = process_event({**ev, "rig": "unknown-rig"}, "/city", {})
        ok("process_event: unresolvable rig -> skip_no_rig, never calls Jev", status == "skip_no_rig")

        def fake_run_no_marker(cmd, timeout=None):
            if cmd[:2] == ["gc", "rig"]:
                return cp(0, json.dumps({"rigs": [{"name": "gascity", "path": "/whatever"}]}))
            if "rev-parse" in cmd:
                return cp(0, "/repo\n")
            if cmd[:2] == ["bd", "-C"]:
                return cp(1, "", "not found")
            raise AssertionError(cmd)

        with mock.patch.object(this, "_run", side_effect=fake_run_no_marker):
            status, _detail = process_event(ev, "/city", {"gascity": "/whatever"})
        ok("process_event: marker bead unreadable -> skip_no_marker, never calls Jev", status == "skip_no_marker")

    with tempfile.TemporaryDirectory() as td:
        qg = Path(td) / "quality-gate.jsonl"
        # A realistic recent ts -- run()'s default since_days filtering would otherwise
        # exclude a ts-less fixture, same as it would a real ts-less (or stale) line.
        recent_ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        qg.write_text(json.dumps({**ev, "event": "dispatcher_complete", "ts": recent_ts}) + "\n")
        jl = Path(td) / "jev-experiment.jsonl"
        with mock.patch.object(this, "_run", side_effect=fake_run_e2e), \
             mock.patch.object(jev_experiment, "JEV_LOG", jl), \
             mock.patch.object(jev_experiment, "CF_ACCOUNT_ID", "0123456789abcdef0123456789abcdef"), \
             mock.patch.object(jev_experiment, "CF_API_TOKEN", "tok"), \
             mock.patch("urllib.request.urlopen", return_value=_fake_response(live_shape)):
            counts1 = run(gc_city="/city", qg_log=str(qg), dry_run=True)
            ok("run(): dry-run reports one logged item but writes nothing",
               counts1.get("logged") == 1 and not jl.exists())

            counts2 = run(gc_city="/city", qg_log=str(qg), dry_run=False)
            ok("run(): real run writes exactly one line to the jev log",
               counts2.get("logged") == 1 and len(jl.read_text().strip().splitlines()) == 1)

            counts3 = run(gc_city="/city", qg_log=str(qg), dry_run=False)
            ok(
                "run(): re-running against the same quality-gate.jsonl does not double-log (dedup by gate_run)",
                counts3.get("logged", 0) == 0 and counts3.get("skipped_dup") == 1
                and len(jl.read_text().strip().splitlines()) == 1,
            )

            # since_days=-1 sets the cutoff a day in the FUTURE, so any real (past) ts is
            # deterministically excluded -- avoids a flaky race against wall-clock
            # precision that a near-zero-but-positive window would have.
            counts4 = run(gc_city="/city", qg_log=str(qg), dry_run=True, since_days=-1.0)
            ok(
                "run(): since_days honored end-to-end -- a window that excludes everything sees nothing",
                counts4.get("considered", 0) == 0,
            )

    print(f"\njev_gate_verdict_experiment selftest: PASS={passed} FAIL={failed}")
    return 1 if failed else 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("selftest", help="mocked, no live repo/credential/Dolt needed")

    r = sub.add_parser("run", help="scan quality-gate.jsonl and log new gate-verdict shadow predictions")
    r.add_argument("--gc-city", default=None)
    r.add_argument("--qg-log", default=None)
    r.add_argument("--dry-run", action="store_true", help="compute and print, but do not write to the jev log")
    r.add_argument("--limit", type=int, default=None, help="max number of NEW gate runs to log this invocation")
    r.add_argument(
        "--since-days", type=float, default=DEFAULT_SINCE_DAYS,
        help=f"ignore dispatcher_complete events older than this many days (default {DEFAULT_SINCE_DAYS}; "
        "quality-gate.jsonl is append-only and grows forever, and old markers get reaped anyway)",
    )

    args = ap.parse_args()

    if args.cmd == "selftest":
        return _selftest()

    if args.cmd == "run":
        run(gc_city=args.gc_city, qg_log=args.qg_log, dry_run=args.dry_run, limit=args.limit,
            since_days=args.since_days)
        return 0

    return 1  # pragma: no cover -- argparse's required=True on sub already prevents this


if __name__ == "__main__":
    sys.exit(main())

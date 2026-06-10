#!/usr/bin/env python3
"""Problem-only gate/loop health monitor.

Emits a line ONLY for actionable problems (silence = healthy):
  [GATE FAIL]      a review genuinely failed
  [REAL-JAM]       a gate marker is queued/claimed but not completing (true wedge)
  [GATE-ERROR]     one or more gate markers stuck in gate-status:error (spawn/dispatch failure)
  [DELIVERY-FAIL]  a delivery failed or HALTed

Deliberately does NOT emit routine GATE PASS / PILOT dispatch / DELIVERY PASS —
those are normal operation and were the source of the old monitor's noise.
The old JAMMED heuristic (no merge in 20min + >=3 in-flight) fired on a
saturated-but-busy gate; this one keys off a marker that is actually stuck.

[GATE-ERROR] closes the blind spot exposed by the 2026-06-06 town-wide outage:
markers landing in gate-status:error (spawn/dispatch failure) were invisible
to the old four checks. Now alerts when any open error marker stays in error
past ERROR_STUCK_SEC (10min). Uses first-seen tracking to avoid alerting on
normal churn (error→queued→error during rebase-attempt cycles).
"""
import json, time, datetime, subprocess, os

QG = ".gc/quality-gate.jsonl"
SD = ".gc/story-delivery.jsonl"
DISPATCH_LOG = ".gc/logs/quality-gate-dispatcher.log"  # sweeps every ~3min
STUCK_SEC = 1500        # 25min queued-with-no-completion = real wedge
REALERT_SEC = 900       # re-warn a still-stuck marker every 15min
ENGINE_STALL_SEC = 900  # dispatcher log silent >15min = engine dead/hung
ERROR_STUCK_SEC = 600   # 10min in gate-status:error = dispatch failure worth alarming
VERDICT_STALL_SEC = 1500  # 25min of a gate-run's pending verdicts not changing = idle reviewer(s) (ga-noxbv)
NOMERGE_STALL_SEC = 900   # 15min: queue has not ADVANCED + work queued + no review in flight = stuck (ga-hl0gq)
# QG events that ADVANCE the queue (a marker reached a handled/terminal state).
# autorebase_retry + guard_queued do NOT count — they are the non-advancing re-queue loop.
PROGRESS_EVENTS = {"dispatcher_complete", "dispatcher_superseded", "dispatcher_needs_rebase"}


def age(ts):
    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
        return time.time() - t
    except Exception:
        return 0


def count(path):
    try:
        return sum(1 for _ in open(path))
    except FileNotFoundError:
        return 0


def still_queued(bead):
    """True only if the bead is CURRENTLY a genuinely-stuck gate marker
    (gate-status:queued = accepted but not picked up by the dispatcher). If it's
    dispatching (actively under review, verdicts coming), passed/failed/superseded/
    terminal, or absent -> NOT a wedge. Unknown -> False (don't alert)."""
    try:
        out = subprocess.run(["gc", "bd", "show", bead], capture_output=True,
                             text=True, timeout=15).stdout.lower()
    except Exception:
        return False
    return "gate-status:queued" in out


def list_error_markers():
    """Return list of open quality-gate markers currently in gate-status:error.
    Returns list of dicts with keys: id, branch, source_bead.
    Markers that are also 'superseded' are excluded — they are terminal.
    Uses no --all so only open (non-closed) markers are returned."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-marker",
             "-l", "gate-status:error", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        markers = json.loads(result.stdout)
        out = []
        for m in markers:
            labels = m.get("labels", [])
            # Belt-and-suspenders: skip superseded (open-only query should already exclude)
            if "gate-status:superseded" in labels:
                continue
            branch = next((l[len("branch:"):] for l in labels if l.startswith("branch:")), "")
            source_bead = next((l[len("source-bead:"):] for l in labels if l.startswith("source-bead:")), "")
            out.append({"id": m["id"], "branch": branch, "source_bead": source_bead})
        return out
    except Exception:
        return []


def pending_verdicts_by_run():
    """Map gate-run id -> sorted list of its still-OPEN verdict bead ids.

    Each reviewer gets an ephemeral verdict bead labelled gate-run:<id> +
    verdict:pending; it closes (drops out of this open-only query) the moment the
    reviewer records its verdict. So a run whose set of pending verdict beads is
    UNCHANGED over time = reviewers that have made no progress (idle/stuck) —
    today's ga-noxbv hang signature (stuck at 1/3 for 38min). Returns {} on any
    failure so the caller simply skips this cycle's idle-reviewer check."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-verdict", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return {}
        runs = {}
        for v in json.loads(result.stdout):
            labels = v.get("labels", [])
            if "verdict:pending" not in labels:
                continue
            run = next((l[len("gate-run:"):] for l in labels if l.startswith("gate-run:")), "")
            if run:
                runs.setdefault(run, []).append(v["id"])
        return {r: sorted(ids) for r, ids in runs.items()}
    except Exception:
        return {}


def dolt_responsive():
    """Quick probe: can we read beads in <5s? Verdicts travel through Dolt, so a
    slow/unreachable server makes 'no verdict progress' Dolt's fault, not an idle
    reviewer. We suppress the idle-reviewer alert in that case (false-positive
    guard required by ga-noxbv)."""
    try:
        t0 = time.time()
        r = subprocess.run(["gc", "bd", "list", "-l", "type:quality-gate-marker", "--json"],
                           capture_output=True, text=True, timeout=8)
        return r.returncode == 0 and (time.time() - t0) < 5
    except Exception:
        return False


def queued_marker_ids():
    """IDs of open gate markers currently in gate-status:queued (work waiting to be
    picked up). Used by the GATE-NOMERGE throughput check to confirm there IS work
    the gate is failing to advance. Returns [] on any failure (skip the check)."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-marker",
             "-l", "gate-status:queued", "--json"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        return [m["id"] for m in json.loads(result.stdout)
                if "gate-status:superseded" not in m.get("labels", [])]
    except Exception:
        return []


def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash on failure)."""
    print(msg, flush=True)
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Gate health", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


def count(path):
    try:
        return sum(1 for _ in open(path))
    except FileNotFoundError:
        return 0


qg_seen = count(QG)
sd_seen = count(SD)
alerted = {}          # bead_id -> last-alerted timestamp (queued wedge alerts)
engine_alerted = 0
error_first_seen = {}  # bead_id -> first-seen timestamp (for error-stuck tracking)
error_alerted = {}     # bead_id -> last-alerted timestamp (for error re-alert cadence)
verdict_progress = {}  # gate-run -> {"sig": tuple(pending ids), "since": ts, "alerted": ts} (ga-noxbv idle-reviewer)
nomerge_alerted = 0    # last-alerted ts for the GATE-NOMERGE throughput check (ga-hl0gq)

while True:
    # --- engine liveness: dispatcher log must keep sweeping ---
    try:
        m = os.path.getmtime(DISPATCH_LOG)
        stale = time.time() - m
        if stale > ENGINE_STALL_SEC and time.time() - engine_alerted > REALERT_SEC:
            emit("[ENGINE-STALL] gate dispatcher log silent %dmin - dispatcher may be "
                 "dead/hung" % int(stale / 60))
            engine_alerted = time.time()
    except OSError:
        pass

    # --- gate: new FAILs + stuck-marker detection ---
    try:
        lines = open(QG).read().splitlines()
    except FileNotFoundError:
        lines = []
    for l in lines[qg_seen:]:
        try:
            r = json.loads(l)
        except Exception:
            continue
        if r.get("event") == "dispatcher_complete" and str(r.get("result", "")).upper() == "FAIL":
            emit("[GATE FAIL] %s %s — %s" % (
                r.get("bead"), r.get("branch", ""), (r.get("reason") or "")[:80]))
    qg_seen = len(lines)

    last = {}
    for l in lines:
        try:
            r = json.loads(l)
        except Exception:
            continue
        b = r.get("bead")
        if b:
            last[b] = r
    for b, r in last.items():
        if r.get("event") == "guard_queued":
            a = age(r.get("ts", ""))
            if a > STUCK_SEC and (b not in alerted or time.time() - alerted[b] > REALERT_SEC):
                if not still_queued(b):
                    alerted[b] = time.time()  # dispatched/failed/done — not a wedge; skip
                    continue
                emit("[REAL-JAM] gate marker %s stuck %dmin (queued, no completion) "
                     "- gate may be wedged" % (b, int(a / 60)))
                alerted[b] = time.time()

    # --- GATE-ERROR: markers stuck in gate-status:error (dispatch/spawn failure) ---
    # This is the blind spot from the 2026-06-06 outage: the dispatcher kept logging
    # (no ENGINE-STALL), markers were :error not :queued (no REAL-JAM), no review FAIL.
    # Strategy: query open error markers each cycle; track first-seen per marker.
    # Alert only after ERROR_STUCK_SEC (10min) to absorb normal rebase-attempt churn
    # (error→queued→error). Re-alert every REALERT_SEC (15min) until resolved.
    current_error_ids = set()
    for em in list_error_markers():
        mid = em["id"]
        current_error_ids.add(mid)
        now = time.time()
        if mid not in error_first_seen:
            error_first_seen[mid] = now  # just appeared, start the clock
        stuck_for = now - error_first_seen[mid]
        if stuck_for > ERROR_STUCK_SEC:
            last_alert = error_alerted.get(mid, 0)
            if now - last_alert > REALERT_SEC:
                emit("[GATE-ERROR] marker %s (%s) stuck in gate-status:error for %dmin "
                     "— branch: %s source: %s" % (
                         mid, em["source_bead"], int(stuck_for / 60),
                         em["branch"], em["source_bead"]))
                error_alerted[mid] = now
    # Prune markers that are no longer in error (resolved/superseded/closed)
    gone = set(error_first_seen.keys()) - current_error_ids
    for mid in gone:
        error_first_seen.pop(mid, None)
        error_alerted.pop(mid, None)

    # --- IDLE-REVIEWER: a gate-run's verdicts not progressing (ga-noxbv) ---
    # Closes the 38min observability blind spot from today's hang: the marker was
    # in gate-status:dispatching (not :queued, so still_queued()/REAL-JAM missed
    # it) and the dispatcher kept logging "Verdicts 1/3" (so ENGINE-STALL missed
    # it). We watch the verdict beads directly: if a run's set of still-pending
    # verdicts is UNCHANGED for VERDICT_STALL_SEC, the reviewer(s) are idle/stuck.
    # Reset the clock whenever the pending set shrinks (a verdict landed = real
    # progress). Sample Dolt before alarming — a slow write != a dead reviewer.
    runs_now = pending_verdicts_by_run()
    now = time.time()
    for run, pend_ids in runs_now.items():
        sig = tuple(pend_ids)
        st = verdict_progress.get(run)
        if st is None or st["sig"] != sig:
            verdict_progress[run] = {"sig": sig, "since": now, "alerted": 0}
            continue
        stalled = now - st["since"]
        if stalled > VERDICT_STALL_SEC and now - st["alerted"] > REALERT_SEC:
            if not dolt_responsive():
                continue  # Dolt slow/unreachable — not the reviewer's fault; skip
            emit("[IDLE-REVIEWER] gate-run %s: %d verdict(s) pending with no progress "
                 "for %dmin — reviewer(s) idle/stuck; dispatcher re-queues, else gate "
                 "will FAIL at verdict timeout" % (run, len(pend_ids), int(stalled / 60)))
            verdict_progress[run]["alerted"] = now
    # Prune runs whose verdicts are all in (run complete / superseded)
    for run in set(verdict_progress.keys()) - set(runs_now.keys()):
        verdict_progress.pop(run, None)

    # --- GATE-NOMERGE: queue not advancing while work is queued (ga-hl0gq) ---
    # The 2026-06-10 49min stall was invisible to every check above: the marker kept
    # re-queuing (dispatcher_autorebase_retry, a dead-author stale-branch rebase loop)
    # so its guard_queued event-ts kept refreshing and REAL-JAM's age never crossed
    # STUCK_SEC; no run reached verdicts (IDLE-REVIEWER blind); the dispatcher kept
    # logging (ENGINE-STALL blind); no review FAILed (GATE FAIL blind). This check is
    # mechanism-agnostic: if NO queue-ADVANCING event (complete/superseded/needs-rebase)
    # has landed for NOMERGE_STALL_SEC while >=1 marker is queued AND nothing is being
    # actively reviewed, the gate is stuck regardless of the underlying cause. The
    # "no review in flight" + "queued work exists" guards keep a healthy long-running
    # review (15-45min) from false-firing. Dolt-guarded (a slow server != a stuck gate).
    now = time.time()
    last_prog_age = None
    for l in lines:
        try:
            r = json.loads(l)
        except Exception:
            continue
        if r.get("event") in PROGRESS_EVENTS:
            a = age(r.get("ts", ""))
            if a and (last_prog_age is None or a < last_prog_age):
                last_prog_age = a
    if (last_prog_age is not None and last_prog_age > NOMERGE_STALL_SEC
            and not runs_now and now - nomerge_alerted > REALERT_SEC):
        qids = queued_marker_ids()
        if qids and dolt_responsive():
            emit("[GATE-NOMERGE] gate queue has not advanced in %dmin while %d marker(s) "
                 "queued and no review in flight — dispatcher stuck (e.g. head-of-line "
                 "stale branch); queue not draining" % (int(last_prog_age / 60), len(qids)))
            nomerge_alerted = now

    # --- delivery: failures / halts only ---
    try:
        slines = open(SD).read().splitlines()
    except FileNotFoundError:
        slines = []
    for l in slines[sd_seen:]:
        try:
            r = json.loads(l)
        except Exception:
            continue
        res = str(r.get("result", "")).upper()
        if "FAIL" in res or "HALT" in res:
            emit("[DELIVERY-FAIL] %s %s" % (
                r.get("story") or r.get("bead", ""), res))
    sd_seen = len(slines)

    time.sleep(60)

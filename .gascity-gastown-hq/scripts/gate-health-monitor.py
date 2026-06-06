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

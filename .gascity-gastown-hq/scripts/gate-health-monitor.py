#!/usr/bin/env python3
"""Problem-only gate/loop health monitor.

Emits a line ONLY for actionable problems (silence = healthy):
  [GATE FAIL]      a review genuinely failed
  [REAL-JAM]       a gate marker is queued/claimed but not completing (true wedge)
  [GATE-ERROR]     one or more gate markers stuck in gate-status:error (spawn/dispatch failure)
  [DELIVERY-FAIL]  a delivery failed or HALTed
  [ENGINE-STALL]   gate dispatcher log silent >15min (dispatcher dead/hung)
  [GUARDIAN-STALL] guardian-dispatch.sh heartbeat stale >15min (the watcher is dead)

Each alert line is also pushed via the notify CLI so it reaches Athos on mobile.

Deliberately does NOT emit routine GATE PASS / PILOT dispatch / DELIVERY PASS —
those are normal operation and were the source of the old monitor's noise.
The old JAMMED heuristic (no merge in 20min + >=3 in-flight) fired on a
saturated-but-busy gate; this one keys off a marker that is actually stuck.

[GATE-ERROR] closes the blind spot exposed by the 2026-06-06 town-wide outage:
markers landing in gate-status:error (spawn/dispatch failure) were invisible
to the old checks. Now alerts when any open error marker stays in error past
ERROR_STUCK_SEC (10min). Uses first-seen tracking to avoid alerting on normal
churn (error→queued→error during rebase-attempt cycles).

[GUARDIAN-STALL] enforces "O VIGIA É VIGIADO" (story ga-0wxg): the guardian
(guardian-dispatch.sh) writes .gc/guardian.heartbeat on every sweep; if that
file goes stale (or never appears), the guardian itself is dead/hung and the
auto-heal loop is blind — so this monitor raises the alarm.
"""
import json, time, datetime, subprocess, os

# Derive city root from this script's location: scripts/ → city-root/.
# This makes every path absolute regardless of the launchd working directory
# (launchd defaults CWD=/, which would silently break relative paths).
_CITY_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

QG = os.path.join(_CITY_ROOT, ".gc/quality-gate.jsonl")
SD = os.path.join(_CITY_ROOT, ".gc/story-delivery.jsonl")
DISPATCH_LOG = os.path.join(_CITY_ROOT, ".gc/logs/quality-gate-dispatcher.log")  # sweeps every ~3min
GUARDIAN_HEARTBEAT = os.path.join(_CITY_ROOT, ".gc/guardian.heartbeat")           # guardian writes each sweep

STUCK_SEC = 1500          # 25min queued-with-no-completion = real wedge
REALERT_SEC = 900         # re-warn a still-stuck marker every 15min
ENGINE_STALL_SEC = 900    # dispatcher log silent >15min = engine dead/hung
GUARDIAN_STALL_SEC = 900  # guardian heartbeat stale >15min = guardian dead/hung
ERROR_STUCK_SEC = 600     # 10min in gate-status:error = dispatch failure worth alarming

NOTIFY = "/Users/athos/.local/bin/notify"


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
    terminal, or absent -> NOT a wedge. Raises on subprocess failure so the caller
    can distinguish 'not queued' from 'gc unavailable' and avoid silencing a real
    alert during a transient outage."""
    out = subprocess.run(["gc", "bd", "show", bead], capture_output=True,
                         text=True, timeout=15).stdout.lower()
    return "gate-status:queued" in out


def list_error_markers():
    """Return open quality-gate markers currently in gate-status:error.
    Each item: {id, branch, source_bead}. Superseded markers are excluded
    (terminal). No --all => only open (non-closed) markers. Returns [] on any
    failure so a transient gc/Dolt outage never crashes the loop."""
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
        subprocess.run([NOTIFY, "-t", "Gate health", "-p", "4", msg],
                       timeout=10, capture_output=True)
    except Exception:
        pass


qg_seen = count(QG)
sd_seen = count(SD)
alerted = {}            # bead_id -> last-alerted ts (queued-wedge alerts)
engine_alerted = 0
guardian_alerted = 0
error_first_seen = {}   # bead_id -> first-seen ts (error-stuck clock)
error_alerted = {}      # bead_id -> last-alerted ts (error re-alert cadence)
monitor_start = time.time()  # baseline used when the heartbeat file is absent

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

    # --- guardian liveness: heartbeat must be fresh ("the watcher is watched") ---
    try:
        m = os.path.getmtime(GUARDIAN_HEARTBEAT)
        stale = time.time() - m
    except OSError:
        # File absent (not yet created or deleted) — treat as stale since monitor
        # start so GUARDIAN-STALL still fires on initial deployment (the guardian
        # plist has RunAtLoad=false, guaranteeing a >0s window before first beat).
        stale = time.time() - monitor_start
    if stale > GUARDIAN_STALL_SEC and time.time() - guardian_alerted > REALERT_SEC:
        emit("[GUARDIAN-STALL] guardian-dispatch.sh heartbeat stale %dmin - guardian may "
             "be dead/hung; start com.gascity.guardian" % int(stale / 60))
        guardian_alerted = time.time()

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
                try:
                    queued = still_queued(b)
                except Exception:
                    continue  # gc unavailable — don't silence alert, retry next cycle
                if not queued:
                    alerted[b] = time.time()  # dispatched/failed/done — not a wedge; skip
                    continue
                emit("[REAL-JAM] gate marker %s stuck %dmin (queued, no completion) "
                     "- gate may be wedged" % (b, int(a / 60)))
                alerted[b] = time.time()

    # --- GATE-ERROR: markers stuck in gate-status:error (dispatch/spawn failure) ---
    # The blind spot from the 2026-06-06 outage: the dispatcher kept logging
    # (no ENGINE-STALL), markers were :error not :queued (no REAL-JAM), no review FAIL.
    # Query open error markers each cycle; track first-seen per marker. Alert only
    # after ERROR_STUCK_SEC (10min) to absorb normal rebase-attempt churn
    # (error→queued→error). Re-alert every REALERT_SEC (15min) until resolved.
    current_error_ids = set()
    for marker in list_error_markers():
        mid = marker["id"]
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
                         mid, marker["source_bead"], int(stuck_for / 60),
                         marker["branch"], marker["source_bead"]))
                error_alerted[mid] = now
    # Prune markers no longer in error (resolved/superseded/closed)
    for mid in set(error_first_seen.keys()) - current_error_ids:
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

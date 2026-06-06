#!/usr/bin/env python3
"""Problem-only gate/loop health monitor.

Emits a line ONLY for actionable problems (silence = healthy):
  [GATE FAIL]      a review genuinely failed
  [REAL-JAM]       a gate marker is queued/claimed but not completing (true wedge)
  [DELIVERY-FAIL]  a delivery failed or HALTed
  [ENGINE-STALL]   gate dispatcher log silent >15min
  [GUARDIAN-STALL] guardian-dispatch.sh heartbeat stale >15min (watcher is dead)

Deliberately does NOT emit routine GATE PASS / PILOT dispatch / DELIVERY PASS —
those are normal operation and were the source of the old monitor's noise.
The old JAMMED heuristic (no merge in 20min + >=3 in-flight) fired on a
saturated-but-busy gate; this one keys off a marker that is actually stuck.
"""
import json, time, datetime, subprocess, os

QG = ".gc/quality-gate.jsonl"
SD = ".gc/story-delivery.jsonl"
DISPATCH_LOG = ".gc/logs/quality-gate-dispatcher.log"  # sweeps every ~3min
GUARDIAN_HEARTBEAT = ".gc/guardian.heartbeat"           # guardian writes on each sweep
STUCK_SEC = 1500        # 25min queued-with-no-completion = real wedge
REALERT_SEC = 900       # re-warn a still-stuck marker every 15min
ENGINE_STALL_SEC = 900  # dispatcher log silent >15min = engine dead/hung
GUARDIAN_STALL_SEC = 900  # guardian heartbeat stale >15min = guardian dead/hung


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


qg_seen = count(QG)
sd_seen = count(SD)
alerted = {}
engine_alerted = 0
guardian_alerted = 0

while True:
    # --- engine liveness: dispatcher log must keep sweeping ---
    try:
        m = os.path.getmtime(DISPATCH_LOG)
        stale = time.time() - m
        if stale > ENGINE_STALL_SEC and time.time() - engine_alerted > REALERT_SEC:
            print("[ENGINE-STALL] gate dispatcher log silent %dmin - dispatcher may be "
                  "dead/hung" % int(stale / 60), flush=True)
            engine_alerted = time.time()
    except OSError:
        pass

    # --- guardian liveness: heartbeat must be fresh ("the watcher is watched") ---
    try:
        m = os.path.getmtime(GUARDIAN_HEARTBEAT)
        stale = time.time() - m
        if stale > GUARDIAN_STALL_SEC and time.time() - guardian_alerted > REALERT_SEC:
            print("[GUARDIAN-STALL] guardian-dispatch.sh heartbeat stale %dmin - "
                  "guardian may be dead/hung; start com.gascity.guardian" % int(stale / 60),
                  flush=True)
            guardian_alerted = time.time()
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
            print("[GATE FAIL] %s %s — %s" % (
                r.get("bead"), r.get("branch", ""), (r.get("reason") or "")[:80]), flush=True)
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
                print("[REAL-JAM] gate marker %s stuck %dmin (queued, no completion) "
                      "- gate may be wedged" % (b, int(a / 60)), flush=True)
                alerted[b] = time.time()

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
            print("[DELIVERY-FAIL] %s %s" % (
                r.get("story") or r.get("bead", ""), res), flush=True)
    sd_seen = len(slines)

    time.sleep(60)

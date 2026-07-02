#!/usr/bin/env python3
"""
machine-utilization-sampler.py — one point-in-time reading of the machine's duty
cycle, appended to a JSONL. The report script aggregates it into the metric Athos
defined (2026-07-02):

    UTILIZATION = % of time the machine was WORKING, **counted only over the time
                  there was work available**.

"Working" = at least ONE of these, with REAL liveness (never a label alone — a bead
labelled story:in-flight whose session is dead does NOT count; that trap made the
old imparavel-check say "healthy" while nothing ran):

  (1) reviewing — the gate is actively reviewing something (a live gate-reviewer
      process, or an open marker in an actively-processing gate-status).
  (2) building  — something is actively being built (a bead story:in-flight that
      was TOUCHED recently, i.e. a live builder — stale >BUILD_FRESH_SEC = zombie,
      excluded, mirroring the Pilot's own stale-in-flight rule).
  (3) refining  — something is being refined/triaged toward story:approved (a live
      auto-refino process).

"Work available" = there is buildable/reviewable/refinable work waiting (queued gate
markers, story:approved, ctx:ready+exec:auto bugs, or beads awaiting refinement).

The four cells the report cares about:
  working + had_work  -> PRODUCTIVE
  !working + had_work -> IDLE-STALLED   <- the real failure (22h dispatch loop, gate crash)
  working + !had_work -> winding down   (fine)
  !working + !had_work-> IDLE-CORRECT   (fine — empty backlog is not a failure)

Runs 1x/min via launchd (com.gascity.machine-utilization-sampler). Cheap + read-only:
a few `bd list` + one `ps` + one `gc session list`. Never mutates anything.
"""
import json
import os
import subprocess
import sys
import time

HQ = "/Users/athos/gt/.gascity-gastown-hq"
RIG_STORES = [
    "/Users/athos/gt/whatsapp_automation",
    "/Users/athos/gt/property_scrapers",
]
OUT = os.path.join(HQ, ".gc", "machine-utilization.jsonl")
BUILD_FRESH_SEC = int(os.environ.get("UTIL_BUILD_FRESH_SEC", "7200"))  # 2h: matches Pilot stale-in-flight
SAMPLE_EPOCH = int(os.environ.get("UTIL_SAMPLE_EPOCH", str(int(time.time()))))


def sh(args, timeout=20):
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def bd_list(store, *labels, status="open"):
    args = ["bd", "-C", store, "list", "--status", status, "--json"]
    for l in labels:
        args += ["-l", l]
    out = sh(args)
    try:
        d = json.loads(out or "[]")
        return d if isinstance(d, list) else d.get("issues", d.get("beads", []))
    except Exception:
        return []


def age_sec(iso):
    if not iso:
        return 1 << 30
    try:
        import datetime
        t = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
        return SAMPLE_EPOCH - t
    except Exception:
        return 1 << 30


def labels_of(b):
    return b.get("labels") or []


# ── liveness sources ──────────────────────────────────────────────────────────
def ps_count(pattern):
    out = sh(["bash", "-c", f"ps aux 2>/dev/null | grep -acE '{pattern}'"])
    try:
        return int(out.strip() or "0")
    except Exception:
        return 0


def active_sessions():
    """gc session list rows with STATE=active, grouped by template. STATE reflects
    the session-manager heartbeat, so a dead/zombie session is asleep/drained, not
    active — this is the authoritative liveness signal (not a proc grep)."""
    out = sh(["gc", "session", "list"], timeout=25)
    tmpl_active = {}
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 3 or parts[0] == "ID":
            continue
        tmpl, state = parts[1], parts[2]
        if state == "active":
            tmpl_active[tmpl] = tmpl_active.get(tmpl, 0) + 1
    return tmpl_active


# ── the reading ───────────────────────────────────────────────────────────────
def dolt_ok():
    """Fast reachability probe. When Dolt is transiently unreachable (CPU burst /
    connection pressure), bd reads time out and return [] — which would otherwise
    mislabel the minute (had_work=0 -> 'idle_correct', OR working from procs ->
    'winding_down'). Neither is true: the machine may be working AND have work; we
    simply couldn't MEASURE it. So on a failed probe we emit state='unknown' and the
    report/panel EXCLUDE it (a measurement gap, never counted as machine failure)."""
    out = sh(["bash", "-c",
              "timeout 6 env DOLT_CLI_PASSWORD='' dolt --host 127.0.0.1 --port 52756 "
              "--user root --no-tls sql -q 'SELECT 1;' 2>/dev/null"], timeout=10)
    return "1" in out


def sample():
    if not dolt_ok():
        # measurement gap — do NOT blame the machine for our own read failure.
        return {
            "ts": SAMPLE_EPOCH, "working": 0, "had_work": 0, "state": "unknown",
            "dolt_ok": False, "reviewing": 0, "building": 0, "refining": 0,
        }
    hq_markers = bd_list(HQ, "type:quality-gate-marker")
    def marker_status(b):
        for l in labels_of(b):
            if l.startswith("gate-status:"):
                return l.split(":", 1)[1]
        return ""
    active_review_markers = sum(
        1 for b in hq_markers if marker_status(b) in ("reviewing", "running", "dispatching")
    )
    queued_markers = sum(1 for b in hq_markers if marker_status(b) in ("queued", "ready", "claimed"))

    reviewer_procs = ps_count(r"[c]laude.*gate-reviewer")
    refino_procs = ps_count(r"[c]laude.*(refino|refin)")

    # in-flight, fresh (a genuinely-live builder touches its bead; stale = zombie)
    building = 0
    inflight_total = 0
    for store in [HQ] + RIG_STORES:
        for b in bd_list(store, "story:in-flight"):
            inflight_total += 1
            if age_sec(b.get("updated_at", "")) < BUILD_FRESH_SEC:
                building += 1

    # available work
    approved = 0
    ready_bugs = 0
    refine_pending = 0
    for store in [HQ] + RIG_STORES:
        approved += len(bd_list(store, "story:approved"))
        for b in bd_list(store, "ctx:ready"):
            ls = labels_of(b)
            if "exec:auto" in ls and "story:in-flight" not in ls:
                ready_bugs += 1
        for lbl in ("story:triage", "story:unrefined", "story:refino-escalado"):
            refine_pending += len(bd_list(store, lbl))

    reviewing = 1 if (reviewer_procs > 0 or active_review_markers > 0) else 0
    is_building = 1 if building > 0 else 0
    refining = 1 if refino_procs > 0 else 0
    working = 1 if (reviewing or is_building or refining) else 0

    had_work = 1 if (queued_markers + approved + ready_bugs + refine_pending) > 0 else 0

    return {
        "ts": SAMPLE_EPOCH,
        "working": working,
        "had_work": had_work,
        "dolt_ok": True,
        "state": (
            "productive" if (working and had_work)
            else "idle_stalled" if (had_work and not working)
            else "winding_down" if (working and not had_work)
            else "idle_correct"
        ),
        "reviewing": reviewing,
        "building": is_building,
        "refining": refining,
        # diagnostics (so a bad reading can be explained after the fact)
        "n_active_review_markers": active_review_markers,
        "n_reviewer_procs": reviewer_procs,
        "n_building_fresh": building,
        "n_inflight_total": inflight_total,
        "n_refino_procs": refino_procs,
        "avail_queued_markers": queued_markers,
        "avail_approved": approved,
        "avail_ready_bugs": ready_bugs,
        "avail_refine_pending": refine_pending,
    }


def main():
    rec = sample()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "a") as f:
        f.write(json.dumps(rec) + "\n")
    if "--print" in sys.argv:
        print(json.dumps(rec, indent=2))


if __name__ == "__main__":
    main()

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
# ga-xwza2: read-cache shim (ga-48xcv) — this sampler polls every 60s, the
# tightest cadence found city-wide; bd_list() is a pure telemetry read (never
# gates a decision that writes), so a short cache TTL is pure win here.
BD_LIST_CACHED = os.path.join(HQ, "scripts/bd-list-cached.sh")
OUT = os.environ.get("UTIL_OUT", os.path.join(HQ, ".gc", "machine-utilization.jsonl"))
NOTIFY = os.environ.get("UTIL_NOTIFY", "/Users/athos/.local/bin/notify")
BUILD_FRESH_SEC = int(os.environ.get("UTIL_BUILD_FRESH_SEC", "7200"))  # 2h: matches Pilot stale-in-flight
# Gate-stall threshold: a marker queued longer than this means the gate is NOT keeping
# up — counted as gate-stalled even if one reviewer is breathing on another branch.
# Kept IDENTICAL to imparavel-check's gate-stall threshold (165min) so the panel's
# gate sub-metric and the imparável check can never disagree about a gate stall.
GATE_STALL_MIN = int(os.environ.get("UTIL_GATE_STALL_MIN", "165"))
SAMPLE_EPOCH = int(os.environ.get("UTIL_SAMPLE_EPOCH", str(int(time.time()))))


def sh(args, timeout=20):
    try:
        # ga-30xi3: errors="replace" — a session title truncated mid multi-byte
        # UTF-8 char makes `gc session list`'s table output invalid UTF-8; a
        # strict (default) decode raises UnicodeDecodeError here, collapsing
        # into the same "" a clean-but-empty read produces (active_sessions()
        # would then report EVERY template as zero-active, not just the one
        # corrupted line).
        r = subprocess.run(args, capture_output=True, text=True, errors="replace", timeout=timeout)
        return r.stdout
    except Exception:
        return ""


def bd_list(store, *labels, status="open", include_infra=False):
    # include_infra (ga-vm20x, Mayor 07/08): pass True for gate-marker/-run
    # labels — those beads are born --ephemeral (INFRA), hidden from `bd
    # list` by default under bd 1.1.0. Defaults False so the other callers
    # here (story:in-flight, story:approved, ctx:ready, refino:* — none
    # ever ephemeral) keep their existing query shape.
    args = ["bash", BD_LIST_CACHED, "-C", store, "list", "--status", status, "--json"]
    if include_infra:
        args.append("--include-infra")
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


def dolt_cpu_pct():
    """Best-effort total %CPU of the dolt sql-server process(es) — summed across
    matching procs (can exceed 100% = multi-core). FREE: reads `ps`, never queries
    Dolt (so this health probe never adds to the load it measures). Returns a float
    or None on failure (the panel shows '—' for None). This is what surfaces the
    Dolt-heat KPI the Mayor tracks (the 280%→21% cooling)."""
    # LC_ALL=C forces period decimals — this is a pt-BR box where ps prints "196,9",
    # which float() can't parse (silently yielded None before this guard).
    out = sh(["bash", "-c",
              "LC_ALL=C ps aux | grep '[d]olt sql-server' | LC_ALL=C awk '{s+=$3} END{printf \"%.1f\", s}'"],
             timeout=8)
    try:
        return round(float(out.strip()), 1)
    except Exception:
        return None


def sample():
    if not dolt_ok():
        # measurement gap — do NOT blame the machine for our own read failure. Still
        # record dolt_cpu (ps is independent of Dolt reachability) so the heat KPI keeps
        # ticking even while Dolt is too busy to serve queries (exactly when it matters).
        return {
            "ts": SAMPLE_EPOCH, "working": 0, "had_work": 0, "state": "unknown",
            "dolt_ok": False, "reviewing": 0, "building": 0, "refining": 0,
            "dolt_cpu": dolt_cpu_pct(),
        }
    hq_markers = bd_list(HQ, "type:quality-gate-marker", include_infra=True)
    def marker_status(b):
        for l in labels_of(b):
            if l.startswith("gate-status:"):
                return l.split(":", 1)[1]
        return ""
    active_review_markers = sum(
        1 for b in hq_markers if marker_status(b) in ("reviewing", "running", "dispatching")
    )
    queued_markers = sum(1 for b in hq_markers if marker_status(b) in ("queued", "ready", "claimed"))
    # oldest waiting marker's age (the gate SLA signal — a starved head marker is the
    # exact failure the whole-machine metric masked while builders stayed busy).
    gate_oldest_queued_min = 0
    for b in hq_markers:
        if marker_status(b) in ("queued", "ready", "claimed"):
            a = int(age_sec(b.get("updated_at", "")) / 60)
            if a > gate_oldest_queued_min:
                gate_oldest_queued_min = a

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

    # ── per-pipeline states (so a stall in ONE pipeline lights red even when the
    #    others are busy — a busy build/refino must NOT mask a starved gate). ──────
    # GATE: had-work = queued markers exist. Working requires a live reviewer AND no
    # marker starved past GATE_STALL_MIN. A marker waiting longer than that = the gate
    # is NOT keeping up = stalled, even if a reviewer breathes on another branch. This
    # is the reading the whole-machine metric hid; threshold matches imparavel-check.
    gate_had_work = 1 if queued_markers > 0 else 0
    gate_live = 1 if (reviewer_procs > 0 or active_review_markers > 0) else 0
    gate_starved = 1 if gate_oldest_queued_min > GATE_STALL_MIN else 0
    gate_working = 1 if (gate_had_work and gate_live and not gate_starved) else 0
    gate_state = (
        "productive" if (gate_had_work and gate_working)
        else "idle_stalled" if gate_had_work        # work waiting but starved or no reviewer
        else "winding_down" if gate_live
        else "idle_correct"
    )
    # BUILD: had-work = dispatchable approved/ready bugs. Working = a fresh builder.
    build_had_work = 1 if (approved + ready_bugs) > 0 else 0
    build_state = (
        "productive" if (build_had_work and is_building)
        else "idle_stalled" if (build_had_work and not is_building)
        else "winding_down" if is_building
        else "idle_correct"
    )
    # REFINO: had-work = refinement pending. Working = a live refino process.
    refino_had_work = 1 if refine_pending > 0 else 0
    refino_state = (
        "productive" if (refino_had_work and refining)
        else "idle_stalled" if (refino_had_work and not refining)
        else "winding_down" if refining
        else "idle_correct"
    )

    return {
        "ts": SAMPLE_EPOCH,
        "working": working,
        "had_work": had_work,
        "dolt_ok": True,
        "dolt_cpu": dolt_cpu_pct(),
        "state": (
            "productive" if (working and had_work)
            else "idle_stalled" if (had_work and not working)
            else "winding_down" if (working and not had_work)
            else "idle_correct"
        ),
        "gate_state": gate_state,
        "build_state": build_state,
        "refino_state": refino_state,
        "gate_oldest_queued_min": gate_oldest_queued_min,
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


def notify_fail(msg):
    try:
        subprocess.run([NOTIFY, "-t", "Machine Utilization Sampler", "-p", "4", f"🚨 {msg}"],
                        capture_output=True, timeout=10)
    except Exception:
        pass


def main():
    try:
        rec = sample()
        os.makedirs(os.path.dirname(OUT), exist_ok=True)
        with open(OUT, "a") as f:
            f.write(json.dumps(rec) + "\n")
        if "--print" in sys.argv:
            print(json.dumps(rec, indent=2))
    except Exception as e:
        notify_fail(f"machine-utilization-sampler: crash inesperado — {type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    main()

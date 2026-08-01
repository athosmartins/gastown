#!/usr/bin/env python3
"""Throughput-stall watchdog — escalates a "ready work exists but nothing is flowing" condition.

WHY THIS EXISTS (2026-06-23): on 2026-06-23 the pipeline shipped 0 product beads for
~13h despite a full backlog of ready (story:approved / ctx:ready) work, and NO existing
monitor caught it. The existing resilience layer covers:

  • pipeline-throughput-heartbeat.py — detects dispatched=0 ONLY when the PILOT LOG
    shows "Dispatch tier: X (N candidate(s))" with free slots. When the Pilot's BD query
    MISSES the ready backlog (wrong rig scope, filter bug, BD timeout), it logs "No
    dispatchable candidates" — heartbeat treats that as a LEGITIMATELY empty backlog and
    stays quiet. The heartbeat is blind to the "pilot can't see the backlog" mode.

  • production-stall-watchdog.py — merge-stall dimension fires only when gate markers are
    queued (queued>0). If work never gets dispatched, there are no queued markers, and this
    check explicitly returns None ("starved/idle, not merge-stalled"). Story:approved count
    alone is not enough for it to fire because that was a known false-positive vector.

  • Neither monitor does an INDEPENDENT cross-check: "actual dispatchable beads in Dolt"
    vs "what the Pilot actually dispatched/merged in the last N hours". That comparison is
    the gap this watchdog fills.

THE GAP (root cause of the 13h stall):
  The Pilot's BD query for story:approved candidates was scoped to the WRONG rig or omitted
  ctx:ready entirely, returning 0 candidates each sweep. The Pilot logged "No dispatchable
  candidates. Exiting." → heartbeat's pilot_dispatch_stall() returned None (demand==0 →
  idle ≠ stalled) → no escalation. In parallel, the gate had 0 queued markers (nothing
  dispatched = nothing to gate) → production-stall-watchdog merge-stall returned None.
  Both monitors were individually correct given their assumptions — but together they created
  a blind spot for the "real backlog exists but Pilot cannot see it" failure mode.

  The fix: independently query the bead stores for actually-dispatchable work, then ask
  "has the Pilot dispatched anything, AND has anything shipped, in the last TSW_STALL_HOURS?
  If not, and the real backlog is non-empty, that is a THROUGHPUT STALL."

DESIGN:
  • DISPATCH SIGNAL — parse pilot-dispatcher.log for "dispatched=N" (N>0) sweep lines
    within the window. Optionally cross-check via pilot-dispatchable.json in-flight count.
  • MERGE SIGNAL — git log --since on each rig store's origin/main (product output, not
    infra) AND/OR "Gate PASSED" lines in the dispatcher log within the window.
  • BACKLOG SIGNAL — bd list across HQ + WA + PS rig stores for open story:approved and
    ctx:ready beads that are NOT braked (gate:needs-human | exec:manual | blocked | in-flight).
    This is the key gate against false alarms on a legitimately idle pipeline.
  • STALL = ANY rig has backlog[rig] >= TSW_BACKLOG_MIN AND merge[rig] == 0 AND not
    suspended (TSW_PER_RIG=1, default). Cross-rig git merges no longer mask a dead rig/pool
    (ga-dbibq: 2026-06-27 WA worker pool dead 5h while HQ merging). Gate-PASSED events
    (no rig tag) remain a global flow signal: if any Gate PASSED in the window, no per-rig
    stall fires. TSW_PER_RIG=0 reverts to the old global sum behaviour. dispatch_count is
    NO LONGER part of the flow check — a dispatch that builds nothing must not mask a stall.
  • ANTI-FLAP: TSW_CONFIRM_SWEEPS consecutive detections before escalating; a non-stall
    sweep resets the counter; re-escalation suppressed while cooldown active.
  • FAIL-SAFE: any error in any signal → treat that signal as "flow present" (fail-open,
    never false-alarm). An idle pipeline with 0 ready work NEVER fires.
  • ESCALATION: notify (high priority) + gc mail send mayor with backlog count, hours since
    last dispatch, hours since last merge, and up to 5 starved bead ids + titles.
  • SELF-TEST: --selftest flag, hermetic (stubs all I/O).
  • KILL-SWITCH: TSW_ENABLED=0 → no-op.

DPW_CRITICAL note: add com.gascity.throughput-stall-watchdog to DPW_CRITICAL after Mayor
deploys (do not edit daemon-presence-watchdog.sh here — Mayor reconciles).
"""
import json
import os
import re
import subprocess
import time
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _tsw_ledger
import datetime as _tsw_datetime
import park_labels

# ── paths ────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_DISPATCHABLE_JSON = os.path.join(os.path.expanduser("~"), ".gc/pilot-dispatchable.json")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")
# Path of the Dolt-probe bash script (imp07 shared probe).
DOLT_PROBE_SH = os.path.join(CITY, "scripts/gc-dolt-probe.sh")

# Rig roots for git-log merge signal and bd backlog queries.
# IMPORTANT: each root must be the BEAD STORE path (bd -C <root>), NOT the git repo root.
# For HQ the bead store is .gascity-gastown-hq (== CITY), NOT /Users/athos/gt — those are
# different paths even though git -C .gascity-gastown-hq resolves to the same repo (subdir).
# Using the bare git root (/Users/athos/gt) causes bd -C to fail silently (rc=1, fail-open).
RIG_ROOTS = os.environ.get(
    "TSW_RIG_ROOTS",
    "/Users/athos/gt/.gascity-gastown-hq:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers",
).split(":")

MAYOR_ADDR = os.environ.get("TSW_MAYOR_ADDR", "mayor")
STATE_FILE = os.environ.get("TSW_STATE_FILE",
                            os.path.join(CITY, ".gc/throughput-stall-watchdog-state.json"))

# ── knobs (all env-overridable) ───────────────────────────────────────────────
ENABLED = os.environ.get("TSW_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("TSW_DRY_RUN", "0") == "1"
# 4h (was 6h): the merge window must be tight enough that a completion several hours ago
# does NOT read as "recent flow". With the 6h window + merge-based flow check, the 2 merges
# from 5h ago (the 2026-06-27 outage) kept merge_count>0 → no alarm. 4h + CONFIRM_SWEEPS
# means an alarm after ~5h of zero completions against a real backlog.
STALL_HOURS = float(os.environ.get("TSW_STALL_HOURS", "4"))
BACKLOG_MIN = int(os.environ.get("TSW_BACKLOG_MIN", "1"))
CONFIRM_SWEEPS = int(os.environ.get("TSW_CONFIRM_SWEEPS", "2"))
ESCALATE_COOLDOWN_SEC = int(os.environ.get("TSW_COOLDOWN_SEC", "21600"))  # 6h cooldown
POLL_SEC = int(os.environ.get("TSW_POLL_SEC", "1800"))                    # 30min cadence
BD_TIMEOUT = int(os.environ.get("TSW_BD_TIMEOUT", "25"))
# ga-dbibq per-rig: when 1 (default) a stall fires if ANY rig has backlog>=MIN AND merge==0
# (cross-rig git merges no longer mask a dead rig/pool). TSW_PER_RIG=0 → old global sum.
PER_RIG = os.environ.get("TSW_PER_RIG", "1") == "1"
GIT_TIMEOUT = int(os.environ.get("TSW_GIT_TIMEOUT", "30"))
LOG_TAIL = int(os.environ.get("TSW_LOG_TAIL", "3000"))   # lines to tail from pilot log

# ── imp08: blind-floor and Dolt-health knobs ──────────────────────────────────
# BLIND: 2+ signals ERROR in same sweep → the watchdog cannot assess flow at all.
# After BLIND_CONFIRM_SWEEPS consecutive blind sweeps, escalate "cannot assess".
# DOLT: confirmed unreachable → a distinct "dolt" stall episode, escalated independently.
BLIND_SIGNAL_THRESHOLD = int(os.environ.get("TSW_BLIND_THRESHOLD", "2"))  # 2+ errors = blind
BLIND_CONFIRM_SWEEPS = int(os.environ.get("TSW_BLIND_CONFIRM_SWEEPS", "2"))
BLIND_COOLDOWN_SEC = int(os.environ.get("TSW_BLIND_COOLDOWN_SEC", "10800"))  # 3h cooldown
# DOLT transient-resistance (fixes chronic false "Dolt UNREACHABLE" pages during CPU bursts):
#   The Dolt reachability verdict now comes from `gc-dolt-probe.sh --robust`, which retries
#   the health probe with backoff and, if every attempt fails, does a raw SELECT 1
#   serve-confirm (see GC_DOLT_PROBE_RETRIES / GC_DOLT_PROBE_RETRY_SLEEP / GC_DOLT_PROBE_TIMEOUT
#   / GC_DOLT_SERVE_CONFIRM_TIMEOUT in gc-dolt-probe.sh, set via the plist). A slow-but-alive
#   Dolt therefore reads as rc=0 (healthy), never counting toward the escalation.
#   • TSW_DOLT_PROBE_TIMEOUT: OUTER subprocess bound for the whole robust probe — must exceed
#     RETRIES×probe-timeout + backoffs + serve-confirm (~52s worst case) so we never kill a
#     legitimately-slow-but-answering probe. 90s. On a healthy Dolt it returns in ~4s.
#   • TSW_DOLT_CONFIRM_SWEEPS: consecutive fully-failed sweeps required before paging. Raised
#     2→3: at the 30-min sweep cadence a page now needs ~90 min of CONTINUOUS confirmed-down
#     (every retry AND SELECT 1 failing). A burst lasts seconds and never sustains that; a
#     genuine outage does. The dedicated dolt-hang-watchdog.sh (every 60s) is the FAST detector.
DOLT_PROBE_TIMEOUT = int(os.environ.get("TSW_DOLT_PROBE_TIMEOUT", "90"))
DOLT_CONFIRM_SWEEPS = int(os.environ.get("TSW_DOLT_CONFIRM_SWEEPS", "3"))
DOLT_COOLDOWN_SEC = int(os.environ.get("TSW_DOLT_COOLDOWN_SEC", "10800"))   # 3h cooldown

# ── imp23: delivery-stall knobs ───────────────────────────────────────────────
# DELIVERY: in-flight beads not updated for > DELIVERY_STALL_HOURS → delivery stall.
# Catches: (1) merged-but-undeployed pile-up (delivery daemon didn't close after gate PASSED),
# (2) dispatched-but-abandoned (crew died silently, no branch push, no heartbeat).
DELIVERY_STALL_HOURS = float(os.environ.get("TSW_DELIVERY_STALL_HOURS", "3"))
DELIVERY_STALL_MIN_BEADS = int(os.environ.get("TSW_DELIVERY_STALL_MIN_BEADS", "1"))
DELIVERY_CONFIRM_SWEEPS = int(os.environ.get("TSW_DELIVERY_CONFIRM_SWEEPS", "2"))
DELIVERY_COOLDOWN_SEC = int(os.environ.get("TSW_DELIVERY_COOLDOWN_SEC", "10800"))  # 3h cooldown

# ── imp24: heal-action branch knobs ──────────────────────────────────────────
# When TSW_HEAL_ENABLED=1, before escalating a confirmed throughput or delivery
# stall the watchdog first attempts auto-heal by invoking funnel-flow-healer.sh.
# Success is validated on stall-cleared (dispatch/merge resumes on the NEXT tick),
# NOT on daemon-green status — a kicked daemon may still not move work.
# TSW_HEAL_SUPPRESS_SEC: after a heal attempt, suppress re-escalation for this
# long to give the system time to recover before re-evaluating.
HEAL_ENABLED = os.environ.get("TSW_HEAL_ENABLED", "0") == "1"
HEAL_SUPPRESS_SEC = int(os.environ.get("TSW_HEAL_SUPPRESS_SEC", "600"))  # 10min
FUNNEL_FLOW_HEALER = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "funnel-flow-healer.sh")

# ── imp11: anti-thrash budget + circuit-breaker ───────────────────────────────
# TSW_HEAL_BUDGET: max lifetime heal attempts before the circuit-breaker triggers.
# After budget is exhausted the watchdog stops attempting heals and escalates
# directly so a human gets paged instead of a retry loop that never converges.
# Set TSW_HEAL_BUDGET=0 to disable the budget ceiling.
# TSW_CIRCUIT_BREAK_ESCALATIONS: after this many CONSECUTIVE escalations (healer
# fired but stall re-confirmed) extend the suppress window by 4× to slow down the
# thrash cycle and give more time for the system to recover. 0 = disabled.
HEAL_BUDGET = int(os.environ.get("TSW_HEAL_BUDGET", "3"))
CIRCUIT_BREAK_ESCALATIONS = int(os.environ.get("TSW_CIRCUIT_BREAK_ESCALATIONS", "2"))

# ── imp12: quota-aware suppression ────────────────────────────────────────────
# When TSW_QUOTA_AWARE=1, the watchdog queries claude-quota-check.sh before each
# heal attempt. If the quota is exhausted (exit 2 = LIMITED) the attempt is
# SKIPPED (suppresses escalation for this tick) WITHOUT consuming a budget slot
# — no point invoking funnel-flow-healer.sh when no Claude sessions can run.
# Default=0 (off) for safety; enable after verifying quota-check.sh is stable.
QUOTA_AWARE = os.environ.get("TSW_QUOTA_AWARE", "0") == "1"
QUOTA_CHECK_SH = os.environ.get(
    "TSW_QUOTA_CHECK_SH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "claude-quota-check.sh"))

# ── log-line patterns ─────────────────────────────────────────────────────────
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Pilot sweep complete: dispatched=N ..."
PILOT_COMPLETE_RE = re.compile(r"Pilot sweep complete: dispatched=(\d+)")
# "Gate PASSED:" in gate dispatcher log
GATE_PASS_RE = re.compile(r"Gate PASSED")
# Exclude labels for the backlog query: a bead with ANY of these is not "ready to dispatch"
# ga-* (2026-07-15): the set below was INCOMPLETE — it excluded gate:needs-human but NOT the
# generic story:needs-human, and nothing for story:refinement-in-progress (a bead still IN
# refino, not yet approved-ready). Result: a FALSE "THROUGHPUT STALL" fired against 6 "ready"
# beads while the falsifiable imparavel-check reported 0 genuinely buildable. The 6 broke down
# as: wa-x7ndm/wa-3sxpm (story:needs-human), wa-v89e3.4/wa-0nm4v (story:refinement-in-progress),
# ga-3r41 (framework — no brake label, handled separately), + 1. False alarms erode the signal
# (the Mayor learns to ignore the watchdog). The brake set now mirrors the painel's non-
# dispatchable ("travada") taxonomy so backlog == what the Pilot can actually dispatch NOW.
# ga-hzt8s (2026-07-20): sourced from the canonical park_labels.py vocabulary
# (shared with approved-state-reconciler.py + imparavel-check.py) instead of a
# fourth hand-maintained copy that had drifted from the other three — see
# park_labels.py for what's in each group. This ADDS labels this file was
# missing: needs-label-review, waiting-on (standalone — previously only the
# blocked-on:*/blocked-reason:* prefixes were covered), framework:engine,
# story:awaiting-external-merge, pilot:no-auto-dispatch, on-device, and
# (via the wider ":"-or-"-" matcher below) pilot:held-until:* — pilot:held was
# already listed but the OLD colon-only matcher never matched its real dash-
# suffixed form. "pilot:reclaim-count:3" is NOT a member here anymore — it
# only ever matched the exact string "3", so a bumped cap would have silently
# stopped excluding; _bead_is_braked() now checks reclaim-exhaustion
# numerically via park_labels.is_reclaim_exhausted() instead (deliverable 2).
EXCLUDE_LABELS_BACKLOG = (
    park_labels.PARK_LABELS | park_labels.GATE_PARK_LABELS
    | park_labels.FLOWING_OR_DONE_LABELS
)


def _bead_is_braked(labels):
    """True iff any bead label marks it not-ready-to-dispatch. Matches an exclude
    label EXACTLY or as a ":"- or "-"-suffixed VARIANT (e.g. EXCLUDE
    'gate:needs-human' also matches the real labels 'gate:needs-human:product' /
    ':technical'; EXCLUDE 'pilot:held' also matches 'pilot:held-until:<epoch>' —
    ga-hzt8s widened this from colon-only to park_labels.label_matches's rule,
    since several real label shapes use a dash suffix, e.g. needs:rehome-property).
    The old exact set-intersection MISSED suffixed variants → product/technical-
    braked + story:blocked beads were counted as dispatchable backlog → false STALL
    (observed 2026-06-27: wa-43k needs-human:product, wa-el8t/n0vv story:blocked,
    wa-f5q4 story:done all miscounted). Also excludes reclaim-exhausted beads
    (pilot:reclaim-count:N >= cap) via a numeric check, not a label-string match."""
    if park_labels.any_labeled(labels, EXCLUDE_LABELS_BACKLOG):
        return True
    return park_labels.is_reclaim_exhausted(labels)

# ── test seams (monkeypatched in --selftest) ──────────────────────────────────
# These are module-level callables so tests can substitute them without patching subprocess.
_read_pilot_log_lines = None   # () -> [str]; None = read from disk
_read_gate_log_lines = None    # () -> [str]; None = read from disk
_git_log_count = None          # (root, since_iso) -> int; None = run git
_bd_backlog = None             # (rig_root) -> list[dict]; None = run bd
_bd_delivery = None            # (rig_root) -> list[dict]; None = run bd (imp23 delivery)
_bd_marker_for_bead = None     # (root, bead_id) -> ("found"|"absent"|"error", marker_dict|None); None = run bd (ga-g0v96)
_bd_sling_state = None         # (sling_id) -> ("live"|"stale"|"absent"|"error", stall_hours|None); None = run bd (ga-ebm7c)
_do_dolt_cpu = None            # () -> float pct or None; None = run ps (ga-g0v96 headroom annotation)
_do_notify = None              # (msg, prio) -> None; None = run notify binary
_do_mail_mayor = None          # (subject, body) -> bool; None = run gc mail

# imp14: flow-authority advisory file — TSW is the elected flow authority. When TSW
# escalates to Mayor, it writes this file so PSW/PTH/FFF can check and defer their own
# Mayor mail (avoiding the "4 daemons page Mayor for the same stall" storm).
FLOW_AUTHORITY_FILE = os.environ.get(
    "TSW_FLOW_AUTHORITY_FILE",
    os.path.join(CITY, ".gc/runtime/flow-authority.json"))
FLOW_AUTHORITY_TTL_SEC = int(os.environ.get("TSW_FLOW_AUTHORITY_TTL_SEC", "7200"))  # 2h


def _write_flow_authority(now, dimension):
    """Write the flow-authority marker file (imp14). Called after TSW mails Mayor."""
    try:
        import json as _json
        runtime_dir = os.path.dirname(FLOW_AUTHORITY_FILE)
        os.makedirs(runtime_dir, exist_ok=True)
        with open(FLOW_AUTHORITY_FILE, "w") as f:
            _json.dump({"escalated_at": now, "dimension": dimension,
                        "authority": "throughput-stall-watchdog",
                        "expires_at": now + FLOW_AUTHORITY_TTL_SEC}, f)
        _log("imp14: wrote flow-authority marker (dimension=%s, expires in %dh)" % (
            dimension, FLOW_AUTHORITY_TTL_SEC // 3600))
    except Exception as e:
        _log("imp14: WARNING: failed to write flow-authority marker: %s" % e)
_do_dolt_probe = None          # () -> int; 0=healthy 1=unhealthy 2=unknown; None = run probe
_do_heal_throughput = None     # () -> bool; True=heal attempted; None = call funnel-flow-healer.sh
_do_check_quota = None         # () -> bool; True=quota available; None = call quota-check.sh (imp12)
_suspended_rigs = None         # () -> set[str]; None = query via gc rig list (ga-dbibq per-rig)


# ── guarded subprocess ────────────────────────────────────────────────────────
def _sh(args, timeout=20, stdin=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              input=stdin)
    except Exception:
        return None


def _log(msg):
    print("[tsw] %s" % msg, flush=True)


def _rig_name(root):
    """Map a rig root path to a canonical rig name for per-rig keying."""
    root = root.rstrip("/")
    if "whatsapp" in root:
        return "whatsapp_automation"
    if "property_scrapers" in root:
        return "property_scrapers"
    # HQ rig: its bead store is the city dir (.gascity-gastown-hq); the git repo
    # root (/Users/athos/gt) maps here too. Both are the HQ/"gascity" rig — not unknown.
    if "gascity-gastown-hq" in root or root == "/Users/athos/gt" or "gascity" in root:
        return "gascity"
    _log("_rig_name: unrecognized root %r — falling back to 'gascity'" % root)
    return "gascity"


def _query_suspended_rigs_via_gc():
    """Query gc rig list for suspended rigs. Fail-open: return empty set on any error."""
    try:
        r = _sh([GC_BIN, "rig", "list", "--json"], timeout=10)
        if r is None or r.returncode != 0:
            return set()
        data = json.loads(r.stdout or "{}")
        # gc rig list --json returns {"rigs":[{"name":..,"suspended":bool}, ...]};
        # tolerate a bare list too, just in case.
        rigs = data.get("rigs", []) if isinstance(data, dict) else (data if isinstance(data, list) else [])
        return {d["name"] for d in rigs
                if isinstance(d, dict) and d.get("suspended") is True and d.get("name")}
    except Exception:
        return set()


def suspended_rigs():
    """Return the set of currently suspended rig names. Fail-open: returns empty set on error."""
    if _suspended_rigs is not None:
        return _suspended_rigs()
    return _query_suspended_rigs_via_gc()


def _ts_epoch(line):
    """Epoch from a dispatcher-log timestamp prefix, or None."""
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def _tail(path, n):
    try:
        # errors='replace' handles non-UTF8 bytes in the log (accented characters in bead
        # titles are written by bd/gc and may appear in log lines). The replacement char (U+FFFD)
        # never appears in the timestamp or keyword patterns we match, so it is safe to use.
        with open(path, errors="replace") as f:
            return f.readlines()[-n:]
    except Exception:
        return []


def _parse_bd_json(raw):
    """Parse bd --json output (array or {issues:[]} envelope). Returns [] on any failure."""
    if not raw or not raw.strip():
        return []
    try:
        d = json.loads(raw)
    except json.JSONDecodeError as e:
        try:
            d = json.loads(raw[:e.pos])
        except Exception:
            return []
    except Exception:
        return []
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        return d.get("issues") or d.get("beads") or d.get("items") or []
    return []


# ── ga-g0v96: Dolt CPU% reading (headroom annotation, distinct from health probe) ──
def _dolt_cpu_pct():
    """Best-effort total %CPU of the dolt sql-server process(es), or None on failure.

    Reads `ps` only — never queries Dolt (same technique as
    machine-utilization-sampler.py's dolt_cpu_pct()). Used only to annotate a
    delivery-stall bead that turns out to be explained by a healthy queued gate
    marker (AC1: "aguardando headroom há Nh (Dolt cpu=X%)") — not a health
    verdict, so no retry/median-of-N sampling is needed here. Test seam: _do_dolt_cpu."""
    if _do_dolt_cpu is not None:
        return _do_dolt_cpu()
    r = _sh(["bash", "-c",
             "LC_ALL=C ps aux | grep '[d]olt sql-server' | LC_ALL=C awk '{s+=$3} END{printf \"%.1f\", s}'"],
            timeout=8)
    if r is None or r.returncode != 0:
        return None
    try:
        return round(float(r.stdout.strip()), 1)
    except Exception:
        return None


# ── imp08: Dolt-health probe (Dolt-independent path) ─────────────────────────
def _dolt_probe_rc():
    """Probe Dolt via `gc-dolt-probe.sh --robust`. Returns 0=healthy 1=unhealthy 2=unknown.

    --robust retries the health probe with backoff and falls back to a raw SELECT 1
    serve-confirm: a slow-but-alive Dolt (CPU burst) reads as 0 (healthy), so a transient
    NEVER counts toward the "Dolt UNREACHABLE" escalation. Only a sustained health-fail +
    SELECT-1-refused returns 1. Test seam: if _do_dolt_probe is set, its return value IS
    the robust rc (bash is never spawned)."""
    if _do_dolt_probe is not None:
        return _do_dolt_probe()
    r = _sh(["bash", DOLT_PROBE_SH, "--robust"], timeout=DOLT_PROBE_TIMEOUT)
    if r is None:
        return 2  # spawn failed / outer timeout → unknown (fail-open, never a false page)
    return r.returncode  # 0=healthy 1=unhealthy 2=unknown


def _dolt_probe_is_confirmed_unhealthy():
    """True only on a confirmed UNHEALTHY result (rc=1). rc=2 (unknown) is NOT confirmed."""
    return _dolt_probe_rc() == 1


def _escalate_blind(signals_errored, now, state):
    """Fire a 'blind, cannot assess flow' escalation via notify (PRIMARY)."""
    names = ", ".join(signals_errored)
    msg = ("TSW BLIND: %d/%d throughput signals errored (%s) — cannot assess flow. "
           "City-down? Investigate." % (len(signals_errored), 3, names))
    _tsw_ledger("flow-ledger", {
        "ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stage": "blind-sweep",
        "signals_errored": signals_errored,
        "blind_pending": state.get("blind_pending", 0),
        "escalated": True,
    }, fail_open=True)
    if DRY_RUN:
        _log("DRY_RUN: would escalate blind: %s" % msg)
        return True
    # PRIMARY: notify (Dolt-independent, always fires first)
    if _do_notify is not None:
        _do_notify(msg, 4)
    else:
        _sh([NOTIFY_BIN, "-t", "TSW BLIND", "-p", "4", msg], timeout=10)
    return True


def _escalate_dolt(now, state):
    """Fire a Dolt-unreachable escalation via notify (PRIMARY) + gc mail (SECONDARY)."""
    msg = "TSW: Dolt UNREACHABLE — data plane down, bd/gc/mail all at risk."
    _tsw_ledger("flow-ledger", {
        "ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "stage": "dolt",
        "dolt_reachable": False,
        "dolt_pending": state.get("dolt_pending", 0),
        "escalated": True,
    }, fail_open=True)
    if DRY_RUN:
        _log("DRY_RUN: would escalate dolt: %s" % msg)
        return True
    # PRIMARY: notify unconditionally (Dolt is DOWN so gc mail may not work)
    if _do_notify is not None:
        _do_notify(msg, 5)
    else:
        _sh([NOTIFY_BIN, "-t", "Dolt UNREACHABLE", "-p", "5", msg], timeout=10)
    # SECONDARY: gc mail best-effort (may fail if Dolt is down — that's OK)
    body = ("Dolt confirmed UNREACHABLE by throughput-stall-watchdog probe.\n\n"
            "The data plane is down. bd/gc/mail calls will fail until Dolt is restored.\n"
            "gc dolt status — collect diagnostics before restarting.\n"
            "See CLAUDE.md §Dolt troubleshooting for the goroutine-dump protocol.")
    subject = "Watchdog: Dolt UNREACHABLE (confirmed %d sweeps)" % state.get("dolt_pending", 1)
    if _do_mail_mayor is not None:
        _do_mail_mayor(subject, body)
    else:
        _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
            timeout=45)
    return True


def _tick_blind_and_dolt(signals_errored, now, state):
    """Handle the blind-floor (imp08) and Dolt-health dimensions.

    signals_errored: list of signal names that ERRORed this sweep.

    Updates state in-place:
      state["blind_pending"]        — consecutive blind sweep count
      state["blind_last_escalate"]  — epoch of last blind escalation
      state["dolt_pending"]         — consecutive confirmed-unhealthy Dolt count
      state["dolt_last_escalate"]   — epoch of last Dolt escalation

    Returns (is_blind, dolt_escalated) booleans so the caller can decide
    whether to skip the normal stall logic (blind sweep = no stall verdict)."""

    # Ensure state keys exist (backward-compat with pre-imp08 state files)
    state.setdefault("blind_pending", 0)
    state.setdefault("blind_last_escalate", 0.0)
    state.setdefault("dolt_pending", 0)
    state.setdefault("dolt_last_escalate", 0.0)

    # ── Blind-floor check ────────────────────────────────────────────────────
    is_blind = len(signals_errored) >= BLIND_SIGNAL_THRESHOLD
    if is_blind:
        state["blind_pending"] += 1
        _tsw_ledger("flow-ledger", {
            "ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "stage": "blind-sweep",
            "signals_errored": signals_errored,
            "blind_pending": state["blind_pending"],
            "escalated": False,
        }, fail_open=True)
        _log("imp08 BLIND: %d/%d signals errored (%s) — blind sweep %d/%d" % (
             len(signals_errored), 3, ", ".join(signals_errored),
             state["blind_pending"], BLIND_CONFIRM_SWEEPS))
        if state["blind_pending"] >= BLIND_CONFIRM_SWEEPS:
            cooldown_ok = (now - state["blind_last_escalate"]) > BLIND_COOLDOWN_SEC
            if cooldown_ok:
                _escalate_blind(signals_errored, now, state)
                state["blind_last_escalate"] = now
                _log("imp08 BLIND escalated after %d consecutive blind sweeps" % state["blind_pending"])
            else:
                _log("imp08 BLIND: confirmed but within cooldown — suppressing")
    else:
        if state["blind_pending"] > 0:
            _log("imp08 BLIND: cleared (signals readable again)")
        state["blind_pending"] = 0

    # ── Dolt-health check (Dolt-independent robust probe) ────────────────────
    # dolt_rc comes from `gc-dolt-probe.sh --robust`: rc=1 means EVERY health retry failed
    # AND a raw SELECT 1 was refused this sweep (a burst that recovers on retry, or a Dolt
    # that still serves SELECT 1, already returned rc=0 and never lands here). rc=2 (unknown/
    # transient — e.g. no MySQL client) never counts. Escalation still needs DOLT_CONFIRM_SWEEPS
    # such fully-failed sweeps in a row, so only a SUSTAINED outage pages.
    dolt_escalated = False
    dolt_rc = _dolt_probe_rc()
    if dolt_rc == 1:
        # Confirmed unreachable this sweep (all retries failed + SELECT 1 refused).
        state["dolt_pending"] += 1
        _tsw_ledger("flow-ledger", {
            "ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "stage": "dolt",
            "dolt_reachable": False,
            "dolt_pending": state["dolt_pending"],
            "escalated": False,
        }, fail_open=True)
        _log("imp08 DOLT: confirmed unhealthy sweep %d/%d" % (
             state["dolt_pending"], DOLT_CONFIRM_SWEEPS))
        if state["dolt_pending"] >= DOLT_CONFIRM_SWEEPS:
            cooldown_ok = (now - state["dolt_last_escalate"]) > DOLT_COOLDOWN_SEC
            if cooldown_ok:
                _escalate_dolt(now, state)
                state["dolt_last_escalate"] = now
                dolt_escalated = True
            else:
                _log("imp08 DOLT: confirmed but within cooldown — suppressing")
    elif dolt_rc == 2:
        _log("imp08 DOLT: probe returned unknown (transient?) — not counting")
        # Do NOT reset dolt_pending on unknown — only a healthy (rc=0) clears it.
    else:
        # rc=0 → healthy
        if state["dolt_pending"] > 0:
            _log("imp08 DOLT: healthy again — clearing dolt_pending")
        state["dolt_pending"] = 0

    return is_blind, dolt_escalated


# ── SIGNAL 1: dispatch signal ─────────────────────────────────────────────────
# Return convention for all three signals:
#   (None, None)  → ERROR: the signal could not be read at all (fail-open + counted for blind-floor)
#   (0, ...)      → readable, genuinely zero (idle, no false alarm)
#   (N>0, ...)    → readable, flow present
_SIGNAL_ERROR = (None, None)

def dispatch_signal(now, window_sec):
    """Returns (count, last_dispatch_epoch) where count is dispatches in window.
    On any ERROR returns _SIGNAL_ERROR — caller treats as fail-open (count present) AND counts
    toward the blind-floor (imp08). count=0 + last_dispatch_epoch=None means "zero dispatches,
    no evidence of ever having dispatched in the tail". last_dispatch_epoch may be an epoch
    OUTSIDE the window (most recent historical)."""
    if _read_pilot_log_lines is not None:
        lines = _read_pilot_log_lines()
    else:
        lines = _tail(PILOT_LOG, LOG_TAIL)

    if not lines:
        _log("dispatch_signal: pilot log empty/missing — ERROR (fail-open; counted for blind-floor)")
        return _SIGNAL_ERROR  # ERROR: can't read log = can't claim stall

    count = 0
    last_epoch = None
    for line in lines:
        m = PILOT_COMPLETE_RE.search(line)
        if not m:
            continue
        dispatched = int(m.group(1))
        epoch = _ts_epoch(line)
        if epoch is not None:
            if last_epoch is None or epoch > last_epoch:
                last_epoch = epoch
            if now - epoch <= window_sec and dispatched > 0:
                count += 1

    return count, last_epoch


# ── SIGNAL 2: merge signal ────────────────────────────────────────────────────
def merge_signal(now, window_sec):
    """Returns (result, last_merge_epoch) of gate-PASSED events and/or git commits in window.
    On any error returns (None, None) — fail-open.

    When TSW_PER_RIG=1 (default): result is a dict mapping rig name → git-commit count plus
    a special "_gate_passed" key for unattributed gate-PASSED events (no clean rig tag in log
    line). Gate-PASSED is a global flow signal — it suppresses per-rig stall detection when
    present. Per-rig STALL uses only the per-root git counts.

    When TSW_PER_RIG=0: result is an int (sum of all counts) — original behaviour.

    Fail-open: if gate log is missing AND all git queries fail → (None, None)."""
    gate_passed = 0   # gate-PASSED events in window (unattributed — no clean rig tag)
    last_epoch = None
    gate_log_read = False   # True once we have a gate log list (even if empty)

    # 2a. Gate PASSED lines in dispatcher log (most direct signal).
    if _read_gate_log_lines is not None:
        # Test seam: stub provided — treat as authoritative readable log.
        gate_lines = _read_gate_log_lines()
        gate_log_read = True
    else:
        # Production: read the real file; an OS error → not read.
        gate_lines = _tail(DISPATCH_LOG, LOG_TAIL)
        # _tail returns [] on error OR truly empty file. Consider it "read" if the file exists.
        gate_log_read = os.path.exists(DISPATCH_LOG)

    for line in gate_lines:
        if GATE_PASS_RE.search(line):
            epoch = _ts_epoch(line)
            if epoch is not None:
                if last_epoch is None or epoch > last_epoch:
                    last_epoch = epoch
                if now - epoch <= window_sec:
                    gate_passed += 1

    # 2b. Git commits to rig origin/main in the window — tracked per rig.
    since_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - window_sec))
    git_any_success = False
    per_rig_git = {}   # rig_name -> int commit count in window
    git_ok_rigs = set()  # rigs whose git read succeeded; absent rig = fail-open (skip in stall check)
    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue
        rig = _rig_name(root)
        if _git_log_count is not None:
            # Test seam: stub provided. None return means "simulated git failure".
            n = _git_log_count(root, since_iso)
            if n is not None:
                git_any_success = True
                git_ok_rigs.add(rig)
        else:
            r = _sh(["git", "-C", root, "log", "--oneline",
                     "--since=%s" % since_iso, "origin/main"],
                    timeout=GIT_TIMEOUT)
            if r is None or r.returncode != 0:
                _log("merge_signal: git log failed for %s — skipping rig" % root)
                continue
            git_any_success = True
            git_ok_rigs.add(rig)
            n = len([l for l in (r.stdout or "").splitlines() if l.strip()])
        if n is None:
            continue
        per_rig_git[rig] = per_rig_git.get(rig, 0) + n

    # Fail-open ONLY when we genuinely could not read either signal source.
    # If the gate log was readable (even empty) or git succeeded for at least one rig,
    # we have a valid (possibly-zero) count and should NOT treat it as fail-open.
    if not gate_log_read and not git_any_success:
        _log("merge_signal: gate log missing/unreadable AND all git queries failed — "
             "ERROR (fail-open; counted for blind-floor)")
        return _SIGNAL_ERROR

    if PER_RIG:
        # Per-rig dict: each rig mapped to its git commit count.
        # Gate-PASSED (no rig tag) stored under "_gate_passed" — caller uses it as
        # a global "flow present" signal that does NOT defeat per-rig stall detection
        # but DOES suppress per-rig stalls globally (same as current: any gate-PASS = flow).
        # "_git_ok_rigs": set of rigs whose git read succeeded; a rig absent from this set
        # had a git failure and is treated as fail-open (not eligible for the stall check).
        per_rig_git["_gate_passed"] = gate_passed
        per_rig_git["_git_ok_rigs"] = git_ok_rigs
        return per_rig_git, last_epoch

    # PER_RIG=0: original global sum
    count = gate_passed + sum(per_rig_git.values())
    return count, last_epoch


# ── SIGNAL 3: backlog signal ──────────────────────────────────────────────────
def backlog_signal():
    """Returns (count, sample_beads) of dispatchable ready beads across all rig stores.
    A bead is dispatchable if it is:
      - status: open (not in_progress, not closed)
      - labels: (story:approved OR ctx:ready) AND NOT any of EXCLUDE_LABELS_BACKLOG
    sample_beads: list of up to 5 dicts (id, title) for the escalation message.

    On any error returns (None, []) — caller treats as fail-open (backlog absent =
    no alert). An error reading any single rig is logged and skipped, not fatal.
    A completely empty/unreachable Dolt returns (None, []) = fail-open."""
    all_beads = []
    at_least_one_success = False

    per_rig_raw = {}   # rig_name -> unbraked bead count (per-root, pre cross-rig dedup)

    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue
        rig = _rig_name(root)

        if _bd_backlog is not None:
            # Test seam: stub provided. A stub returning [] is a valid "empty rig",
            # not a query failure — mark success so backlog=0 is treated as legitimate idle.
            beads = _bd_backlog(root)
            at_least_one_success = True
        else:
            # Query story:approved OR ctx:ready, open, across each rig store.
            # We run two queries (story:approved, ctx:ready) and union them,
            # deduplicating by id — bd doesn't support OR across --label.
            rig_beads = {}
            for label in ("story:approved", "ctx:ready"):
                r = _sh([BD_BIN, "-C", root, "list", "-l", label,
                         "--status", "open", "--json", "-n", "100"],
                        timeout=BD_TIMEOUT)
                if r is None or r.returncode != 0:
                    _log("backlog_signal: bd list %s in %s failed (rc=%s) — skipping" % (
                         label, root, r.returncode if r else "err"))
                    continue
                at_least_one_success = True
                for b in _parse_bd_json(r.stdout):
                    if not isinstance(b, dict):
                        continue
                    bid = b.get("id") or b.get("issue_id") or ""
                    if bid:
                        rig_beads[bid] = b
            beads = list(rig_beads.values())

        if beads is None:
            continue
        if beads:
            at_least_one_success = True

        rig_unbraked = 0
        for b in beads:
            if not isinstance(b, dict):
                continue
            labels = set()
            raw_labels = b.get("labels") or b.get("label") or []
            if isinstance(raw_labels, list):
                labels = {str(l).strip() for l in raw_labels}
            elif isinstance(raw_labels, str):
                labels = {x.strip() for x in raw_labels.split(",") if x.strip()}
            # Exclude braked beads (variant-aware: catches gate:needs-human:product,
            # story:blocked, etc. — not just exact base labels)
            if _bead_is_braked(labels):
                continue
            all_beads.append(b)
            rig_unbraked += 1
        per_rig_raw[rig] = per_rig_raw.get(rig, 0) + rig_unbraked

    if not at_least_one_success:
        _log("backlog_signal: all bd queries failed — ERROR (fail-open; counted for blind-floor)")
        return None, []   # (None,[]) is the backlog-error sentinel; [] is never confused with results

    # Deduplicate across rigs (same bead id)
    seen = {}
    for b in all_beads:
        bid = b.get("id") or b.get("issue_id") or ""
        if bid and bid not in seen:
            seen[bid] = b

    unique = list(seen.values())
    sample = [{"id": b.get("id", "?"), "title": (b.get("title") or b.get("name") or "?")[:80]}
              for b in unique[:5]]

    if PER_RIG:
        # per_rig_raw already has per-root unbraked counts. Each rig has its own bd store
        # so cross-rig dedup is not needed per rig. Return raw per-rig counts.
        return per_rig_raw, sample

    return len(unique), sample


# ── ga-g0v96: healthy-queued-marker check (AC1/AC2) ──────────────────────────
def _queued_marker_state(root, bead_id):
    """Tri-state: is there a HEALTHY (gate-status:queued) type:quality-gate-marker
    bead with label source-bead:<bead_id> in root's bd store?

    Returns ("found", {"id": marker_id}) | ("absent", None) | ("error", None).

    ga-g0v96 (AC1): a bead legitimately queued behind gate headroom (Dolt CPU
    saturation) is NOT a delivery anomaly — it is the gate working as designed
    under load. Distinguishing this from a genuinely-abandoned bead requires a
    direct point-query for the marker, never a paginated/windowed bd list scan
    (ga-g0v96's own reporter fell into exactly that trap once: "not in my
    150-row query" was misread as "does not exist").

    error vs absent stay distinguishable here (never collapse — see
    [[error-and-empty-must-not-produce-the-same-value]]) even though the
    caller currently treats both the same way (fall back to unexplained): a
    query failure must never be misread as "confirmed no marker exists".
    Test seam: _bd_marker_for_bead."""
    if _bd_marker_for_bead is not None:
        return _bd_marker_for_bead(root, bead_id)
    r = _sh([BD_BIN, "-C", root, "list",
             "-l", "type:quality-gate-marker",
             "-l", "source-bead:%s" % bead_id,
             "-l", "gate-status:queued",
             "--status", "open", "--json", "-n", "5"],
            timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return ("error", None)
    markers = _parse_bd_json(r.stdout)
    if not markers:
        return ("absent", None)
    m = markers[0] if isinstance(markers[0], dict) else {}
    return ("found", {"id": m.get("id") or m.get("issue_id") or "?"})


def _parse_ts_epoch(raw):
    """Parse a bd timestamp ('%Y-%m-%dT%H:%M:%S' or '%Y-%m-%d %H:%M:%S') to epoch, or None."""
    if not raw:
        return None
    for fmt in ("%Y-%m-%dT%H:%M:%S", "%Y-%m-%d %H:%M:%S"):
        try:
            return time.mktime(time.strptime(raw[:19], fmt))
        except Exception:
            pass
    return None


# ── ga-9ni9w/ga-ebm7c: pilot.sling_bead liveness check ───────────────────────
def _sling_bead_state(sling_id, now):
    """Tri-state: is a story's recorded pilot.sling_bead still open, and is it
    itself within the delivery-stall window?

    Returns ("live", stall_hours) | ("stale", stall_hours) | ("absent", None) | ("error", None).

    ga-9ni9w: a story's own updated_at freezes BY CONSTRUCTION once the Pilot
    dispatches it — the actual work happens on the sling/wrapper task bead
    (pilot.sling_bead), whose updated_at moves as the builder progresses. The
    pre-fix delivery_signal() only ever looked at the story, so every story
    with a fix in flight >3h read as "stalled" even mid-build. This mirrors
    the canonical read of pilot.sling_bead already used by pilot-dispatcher.sh's
    ga-cnvy1 dedup guard: the sling bead always lives in GC_CITY (gc sling
    creates it in HQ) — the caller never reaches this function for the
    rig-native self-reference case (pilot.sling_bead == the story's own id,
    i.e. no separate wrapper bead to look up).
    Test seam: _bd_sling_state(sling_id) -> tri-state tuple; None = run bd."""
    if _bd_sling_state is not None:
        return _bd_sling_state(sling_id)
    r = _sh([BD_BIN, "-C", CITY, "show", sling_id, "--json"], timeout=BD_TIMEOUT)
    if r is None or r.returncode != 0:
        return ("error", None)
    beads = _parse_bd_json(r.stdout)
    if not beads or not isinstance(beads[0], dict):
        return ("error", None)
    s = beads[0]
    status = s.get("status") or ""
    if status in ("closed", "done"):
        return ("absent", None)
    updated_epoch = _parse_ts_epoch(s.get("updated_at") or s.get("updated") or "")
    if updated_epoch is None:
        return ("live", 0.0)   # unparseable → cannot prove stale → LIVE (fail conservative)
    stall_hours = (now - updated_epoch) / 3600.0
    return ("stale", stall_hours) if stall_hours > DELIVERY_STALL_HOURS else ("live", stall_hours)


# ── imp23: delivery-stall signal ─────────────────────────────────────────────
def delivery_signal(now):
    """Returns (count, sample_beads, explained) of story:in-flight beads stalled
    past DELIVERY_STALL_HOURS.

    A bead is delivery-stalled when it carries story:in-flight AND its updated_at is older
    than DELIVERY_STALL_HOURS — the delivery daemon (or the gate itself) has not closed it
    despite the branch presumably being merged (or the crew having abandoned work).

    ga-g0v96 (AC1/AC2): stalled beads explained by a healthy queued gate marker
    (see _queued_marker_state) are split into `explained` and EXCLUDED from
    count/sample — they are not an anomaly, so they must never drive escalation
    or get lumped in with genuinely-abandoned beads.

    On any error returns (None, [], []) — fail-open (no false alert).
    Test seam: _bd_delivery(rig_root) -> list[dict]; None = run bd."""
    stall_sec = DELIVERY_STALL_HOURS * 3600
    stalled = {}
    stall_root = {}   # bid -> root that produced it (needed for the marker point-query)
    at_least_one_success = False

    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue
        if _bd_delivery is not None:
            beads = _bd_delivery(root)
            at_least_one_success = True
        else:
            r = _sh([BD_BIN, "-C", root, "list", "-l", "story:in-flight",
                     "--status", "open", "--json", "-n", "100"],
                    timeout=BD_TIMEOUT)
            if r is None or r.returncode != 0:
                _log("delivery_signal: bd list story:in-flight in %s failed (rc=%s) — skipping" % (
                     root, r.returncode if r else "err"))
                continue
            at_least_one_success = True
            beads = _parse_bd_json(r.stdout)

        if beads is None:
            continue

        for b in beads:
            if not isinstance(b, dict):
                continue
            bid = b.get("id") or b.get("issue_id") or ""
            if not bid or bid in stalled:
                continue
            updated_raw = (b.get("updated_at") or b.get("updated") or
                           b.get("created_at") or b.get("created") or "")
            if not updated_raw:
                continue
            updated_epoch = _parse_ts_epoch(updated_raw)
            if updated_epoch is None:
                continue
            if now - updated_epoch > stall_sec:
                stalled[bid] = b
                stall_root[bid] = root
                b["_tsw_stall_hours"] = (now - updated_epoch) / 3600.0

    if not at_least_one_success:
        _log("delivery_signal: all bd queries failed — ERROR (fail-open)")
        return None, [], []

    # ga-g0v96 (AC1/AC2): split out beads explained by a healthy queued marker —
    # they are not an anomaly and must never count toward the escalation threshold.
    unexplained = {}
    explained = []
    for bid, b in stalled.items():
        root = stall_root[bid]

        # ga-9ni9w: the story's own updated_at freezes by construction once a
        # sling/wrapper task is dispatched for it — check pilot.sling_bead
        # BEFORE trusting the story's staleness. A live (open + recent) sling
        # means real work is in flight; silence entirely (no mail, no count).
        # A stale sling means the story really is stuck — fall through so the
        # existing marker check still gets a chance, but stamp the sling id so
        # the eventual alert names it. No sling_bead, a closed sling, or a
        # failed sling lookup all fall through UNCHANGED — that is exactly
        # today's (accidentally correct) behavior for those cases.
        sling_id = ((b.get("metadata") or {}).get("pilot.sling_bead") or "").strip()
        if sling_id and sling_id != bid:
            sling_verdict, sling_hours = _sling_bead_state(sling_id, now)
            if sling_verdict == "live":
                continue
            if sling_verdict == "stale":
                b["_tsw_sling_id"] = sling_id
            elif sling_verdict == "error":
                _log("delivery_signal: sling check for %s (%s) errored — "
                     "falling through to marker check" % (bid, sling_id))

        marker_verdict, marker = _queued_marker_state(root, bid)
        if marker_verdict == "found":
            explained.append({
                "id": bid,
                "title": (b.get("title") or b.get("name") or "?")[:80],
                "stall_hours": b.get("_tsw_stall_hours", 0.0),
                "marker_id": marker["id"],
            })
        else:
            # "absent" (checked, no marker) and "error" (couldn't check) both fall
            # back to pre-fix behavior (unexplained) — an error must never SUPPRESS
            # a real anomaly just because this diagnostic probe itself failed.
            if marker_verdict == "error":
                _log("delivery_signal: marker check for %s errored — treating as unexplained" % bid)
            unexplained[bid] = b

    unique = list(unexplained.values())
    sample = [{"id": b.get("id", "?"), "title": (b.get("title") or b.get("name") or "?")[:80],
               "sling_id": b.get("_tsw_sling_id")}
              for b in unique[:5]]
    return len(unique), sample, explained


def _escalate_delivery(count, sample, explained, now):
    """Notify + mail Mayor on a confirmed delivery stall (imp23).

    ga-g0v96 (AC1/AC2): `explained` lists beads that ARE stalled but carry a
    healthy gate-status:queued marker — appended as its own annotated section,
    never merged into the anomaly "amostra"/"POSSÍVEIS CAUSAS" framing, and
    with an explicit "don't touch gate:queued" warning (AC2)."""
    notify_msg = ("DELIVERY STALL: %d bead(s) story:in-flight > %.0fh sem atualização — "
                  "possível merged-but-undeployed. Mayor notificado." % (count, DELIVERY_STALL_HOURS))
    subject = ("Watchdog: DELIVERY STALL — %d bead(s) in-flight > %.0fh sem atualização"
               % (count, DELIVERY_STALL_HOURS))
    lines = [
        "WATCHDOG DE ENTREGA: beads in-flight parados sem progresso — DELIVERY STALL",
        "",
        "Beads com story:in-flight não atualizados há > %.0fh (amostra):" % DELIVERY_STALL_HOURS,
    ]
    for b in sample:
        if b.get("sling_id"):
            lines.append("  • %s — %s (sling parado: %s)" % (b["id"], b["title"], b["sling_id"]))
        else:
            lines.append("  • %s — %s" % (b["id"], b["title"]))
    lines += [
        "",
        "POSSÍVEIS CAUSAS:",
        "1. Branch mergeado mas o daemon de entrega não fechou o bead (merged-but-undeployed).",
        "2. Entregável fora do git (habilidade em ~/.claude/) — sem merge path, loop de re-despacho.",
        "3. Crew falhou silenciosamente — sem heartbeat, sem branch push.",
        "",
        "INVESTIGAÇÃO:",
        "  bd -C <rig> show <bead_id>  — confirme labels e última atualização",
        "  git -C <rig> branch -r --merged origin/main | grep <bead_id>  — branch já merged?",
        "  Se merged+não-fechado: gc bd close <id> --reason 'entrega manual (delivery stall)'",
        "  Se fora do git: adicione gate:needs-human para freiar o Pilot (imp13 :technical)",
    ]
    if explained:
        cpu = _dolt_cpu_pct()
        cpu_str = ("%.0f%%" % cpu) if cpu is not None else "?%"
        lines += [
            "",
            "OUTROS %d bead(s) com marker gate-status:queued SAUDÁVEL — NÃO é anomalia, NÃO remova "
            "gate:queued nestes (auto-refino re-ingere o bead como história crua se você remover):" % len(explained),
        ]
        for e in explained:
            lines.append("  • %s — %s (aguardando headroom há %.0fh; Dolt cpu=%s; marker %s)" % (
                e["id"], e["title"], e["stall_hours"], cpu_str, e["marker_id"]))
    body = "\n".join(lines)

    _tsw_ledger("human-touch", {
        "ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source_daemon": "throughput-stall-watchdog",
        "stage": "entrega",
        "kind": "technical",
        "bead_id": sample[0]["id"] if sample else "",
        "reason": notify_msg,
    }, fail_open=True)

    if DRY_RUN:
        _log("DRY_RUN: would escalate delivery stall: %r" % notify_msg)
        return

    if _do_notify is not None:
        _do_notify(notify_msg, 4)
    else:
        _sh([NOTIFY_BIN, "-t", "Delivery stall", "-p", "4", notify_msg], timeout=10)

    if _do_mail_mayor is not None:
        _do_mail_mayor(subject, body)
    else:
        _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
            timeout=45)


def _tick_delivery(now, state):
    """Handle the delivery-stall dimension (imp23).

    Fires when story:in-flight beads go stale for > DELIVERY_STALL_HOURS.
    Runs every tick independently of the main throughput-stall logic.
    Updates state["delivery_pending"] and state["delivery_last_escalate"].
    Returns True if a delivery stall was escalated this tick."""
    state.setdefault("delivery_pending", 0)
    state.setdefault("delivery_last_escalate", 0.0)

    count, sample, explained = delivery_signal(now)
    if count is None:
        _log("delivery_signal ERROR → fail-open (no delivery verdict)")
        state["delivery_pending"] = 0
        return False

    if explained:
        _log("delivery: %d bead(s) explained by a healthy queued gate marker (ga-g0v96: "
             "not an anomaly, excluded from count)" % len(explained))

    if count < DELIVERY_STALL_MIN_BEADS:
        if state["delivery_pending"] > 0:
            _log("delivery: no stalled beads (count=%d) — cleared" % count)
        state["delivery_pending"] = 0
        return False

    state["delivery_pending"] += 1
    _log("delivery: %d in-flight bead(s) stalled > %.0fh (pending=%d/%d)" % (
         count, DELIVERY_STALL_HOURS, state["delivery_pending"], DELIVERY_CONFIRM_SWEEPS))

    if state["delivery_pending"] < DELIVERY_CONFIRM_SWEEPS:
        return False

    if (now - state["delivery_last_escalate"]) <= DELIVERY_COOLDOWN_SEC:
        _log("delivery: stall confirmed but within cooldown — suppressing")
        return False

    _log("DELIVERY ESCALATING: %d in-flight bead(s) stalled (confirmed %d sweeps)" % (
         count, state["delivery_pending"]))
    # imp24: attempt auto-heal before escalating; success = stall-cleared next tick
    if _attempt_heal(now, state):
        return False
    _escalate_delivery(count, sample, explained, now)
    state["delivery_last_escalate"] = now
    return True


# ── imp12: quota check ────────────────────────────────────────────────────────
def _check_quota():
    """Return True if Claude quota is available (not exhausted). imp12.

    Calls claude-quota-check.sh: exit 2 = LIMITED, 0 = OK, else = unknown.
    Fail-open on errors so quota check never false-blocks a heal."""
    if _do_check_quota is not None:
        return _do_check_quota()
    r = _sh([QUOTA_CHECK_SH], timeout=10)
    return not (r and r.returncode == 2)  # exit 2 = LIMITED; fail-open on error


# ── imp24+imp11+imp12: heal-action branch ────────────────────────────────────
def _attempt_heal(now, state):
    """Attempt auto-heal before escalating a confirmed stall (imp24+imp11+imp12).

    imp11 adds a lifetime budget ceiling (HEAL_BUDGET) and a consecutive-escalation
    circuit-breaker (CIRCUIT_BREAK_ESCALATIONS). imp12 adds quota awareness: skip
    heal if Claude quota is exhausted (preserves budget for when it resets)."""
    if not HEAL_ENABLED:
        return False
    heal_last = state.get("heal_last_attempt", 0.0)
    heal_count = state.get("heal_attempt_count", 0)

    # imp11: budget ceiling — stop healing so a human gets paged
    if HEAL_BUDGET > 0 and heal_count >= HEAL_BUDGET:
        _log("imp11 CIRCUIT-BREAK: heal budget exhausted (%d/%d lifetime attempts) — "
             "escalating; set TSW_HEAL_BUDGET=0 to disable" % (heal_count, HEAL_BUDGET))
        return False

    # imp11: consecutive-escalation circuit-breaker → extended suppress window
    consec = state.get("consecutive_escalations", 0)
    if CIRCUIT_BREAK_ESCALATIONS > 0 and consec >= CIRCUIT_BREAK_ESCALATIONS:
        extended = HEAL_SUPPRESS_SEC * 4
        if heal_last > 0.0 and (now - heal_last) <= extended:
            _log("imp11 CIRCUIT-BREAK: %d consecutive escalations — extended suppress window "
                 "(%.0fmin remaining)" % (consec, (extended - (now - heal_last)) / 60))
            return True  # suppress escalation during extended cooling window

    # Standard suppress window (imp24)
    if heal_last > 0.0 and (now - heal_last) <= HEAL_SUPPRESS_SEC:
        _log("imp24 HEAL: suppress window active (%.0fmin remaining) — suppress escalation" % (
             (HEAL_SUPPRESS_SEC - (now - heal_last)) / 60))
        return True   # suppress escalation; stall-cleared validation window still open

    # imp12: quota-aware gate — skip heal (suppress this tick) if quota=0
    if QUOTA_AWARE and not _check_quota():
        _log("imp12 QUOTA-AWARE: quota exhausted — skipping heal attempt (budget preserved)")
        return True  # suppress; stall may clear when quota resets

    _log("imp24 HEAL: stall confirmed — attempting auto-heal via funnel-flow-healer.sh")
    if _do_heal_throughput is not None:
        healed = _do_heal_throughput()
    else:
        r = _sh([FUNNEL_FLOW_HEALER], timeout=30)
        healed = bool(r and r.returncode == 0)

    state["heal_last_attempt"] = now
    state["heal_attempt_count"] = heal_count + 1  # imp11: consume one budget slot
    if healed:
        _log("imp24 HEAL: healer returned success — suppressing escalation for %.0fmin; "
             "stall-cleared validated on next tick (not daemon-green)" % (HEAL_SUPPRESS_SEC / 60))
    else:
        _log("imp24 HEAL: healer returned non-zero — no fix applied, proceeding to escalate")
    return healed


# ── state persistence ─────────────────────────────────────────────────────────
def _load_state():
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
            if isinstance(d, dict):
                d.setdefault("pending", 0)
                d.setdefault("last_escalate", 0.0)
                d.setdefault("escalations", 0)
                # imp08 keys (backward-compat: absent in pre-imp08 state files)
                d.setdefault("blind_pending", 0)
                d.setdefault("blind_last_escalate", 0.0)
                d.setdefault("dolt_pending", 0)
                d.setdefault("dolt_last_escalate", 0.0)
                # imp23 keys (backward-compat: absent in pre-imp23 state files)
                d.setdefault("delivery_pending", 0)
                d.setdefault("delivery_last_escalate", 0.0)
                # imp24 keys (backward-compat: absent in pre-imp24 state files)
                d.setdefault("heal_last_attempt", 0.0)
                # imp11 keys (backward-compat: absent in pre-imp11 state files)
                d.setdefault("heal_attempt_count", 0)
                d.setdefault("consecutive_escalations", 0)
                return d
    except Exception:
        pass
    return {"pending": 0, "last_escalate": 0.0, "escalations": 0,
            "blind_pending": 0, "blind_last_escalate": 0.0,
            "dolt_pending": 0, "dolt_last_escalate": 0.0,
            "delivery_pending": 0, "delivery_last_escalate": 0.0,
            "heal_last_attempt": 0.0,
            "heal_attempt_count": 0, "consecutive_escalations": 0}


def _save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception as e:
        _log("WARN: failed to save state: %r" % e)


# ── escalation ────────────────────────────────────────────────────────────────
def _format_body(backlog_count, dispatch_count, last_dispatch_epoch,
                 merge_count, last_merge_epoch, sample_beads, now, window_sec,
                 stalled_rigs=None):
    hrs = window_sec / 3600
    def _age(epoch):
        if epoch is None:
            return "desconhecido (nenhum registro no tail)"
        return "%.1fh atrás" % ((now - epoch) / 3600)

    rig_line = ("  Rigs parados: %s" % ", ".join(stalled_rigs)) if stalled_rigs else ""
    lines = [
        "WATCHDOG DE THROUGHPUT: pipeline parado com backlog pronto — STALL CONFIRMADO",
        "",
        "Janela de análise: %.0fh" % hrs,
        "Backlog real (story:approved + ctx:ready, não-braked): %d bead(s)" % backlog_count,
        "Dispatches no período: %d  (último: %s)" % (dispatch_count or 0, _age(last_dispatch_epoch)),
        "Merges/Gate-PASSED no período: %d  (último: %s)" % (merge_count or 0, _age(last_merge_epoch)),
        "",
        "CONDIÇÃO DE STALL: backlog[rig] >= %d E merge[rig] == 0 E não suspenso em %.0fh." % (BACKLOG_MIN, hrs)
            if stalled_rigs else
            "CONDIÇÃO DE STALL: backlog >= %d E 0 dispatches E 0 merges em %.0fh." % (BACKLOG_MIN, hrs),
    ] + ([rig_line] if rig_line else []) + [
        "O Pilot está varrendo mas não consegue ver ou despachar o backlog real.",
        "",
        "BEADS PRONTOS NÃO DESPACHADOS (amostra — até 5):",
    ]
    for b in sample_beads:
        lines.append("  • %s — %s" % (b["id"], b["title"]))
    if not sample_beads:
        lines.append("  (sem amostra — bd query falhou ou backlog vazio por alguma dimensão)")
    lines += [
        "",
        "INVESTIGAÇÃO SUGERIDA:",
        "1. tail -40 .gc/logs/pilot-dispatcher.log — confirme 'No dispatchable candidates'",
        "   com 'No candidate(s)' em TODAS as queries de rig? Ou 'Dispatch tier: X (N)'",
        "   mas 'dispatched=0' repetido? Esses são assinaturas distintas.",
        "2. bd -C /Users/athos/gt/.gascity-gastown-hq list -l story:approved --status open",
        "   bd -C /Users/athos/gt/whatsapp_automation list -l story:approved --status open",
        "   bd -C /Users/athos/gt/property_scrapers list -l story:approved --status open",
        "   Quantos aparecem? Se mais de 0 mas Pilot diz 0 → bug de query de BD no Pilot.",
        "3. gc dolt status — BD saudável? Se wedged, coleta diagnostico antes de restart.",
        "4. Verifique se alguma das histórias do backlog tem exec:manual, blocked ou",
        "   gate:needs-human (o watchdog deveria excluí-las; se o backlog conta é bug).",
        "5. Se BD ok + beads ok + Pilot logando 0 → check pilot-dispatchable.json count",
        "   e cross-referencie com as queries de rig no pilot-dispatcher.sh.",
        "",
        "NÃO auto-reconcilie sem investigar — um reset cego pode perder edits uncommitted.",
    ]
    return "\n".join(lines)


def _escalate(backlog_count, dispatch_count, last_dispatch_epoch,
              merge_count, last_merge_epoch, sample_beads, now, window_sec,
              stalled_rigs=None):
    subject = "Watchdog: THROUGHPUT STALL — %d bead(s) prontos, 0 dispatches + 0 merges em %.0fh" % (
        backlog_count, window_sec / 3600)
    body = _format_body(backlog_count, dispatch_count, last_dispatch_epoch,
                        merge_count, last_merge_epoch, sample_beads, now, window_sec,
                        stalled_rigs=stalled_rigs)
    notify_msg = ("THROUGHPUT STALL: %d bead(s) prontos, 0 dispatches + 0 merges em %.0fh"
                  " — Mayor notificado p/ investigar." % (backlog_count, window_sec / 3600))

    if DRY_RUN:
        _log("DRY_RUN: would escalate: subject=%r" % subject)
        _log("DRY_RUN: body=\n%s" % body)
        return True

    # imp07 Dolt-INDEPENDENT invariant: notify is PRIMARY (zero Dolt dependency),
    # fired FIRST and unconditionally. gc mail send mayor is SECONDARY (best-effort);
    # its failure NEVER blocks or follows the notify. If Dolt is down, notify still fires.
    if _do_notify is not None:
        _do_notify(notify_msg, 4)
    else:
        _sh([NOTIFY_BIN, "-t", "Throughput stall", "-p", "4", notify_msg], timeout=10)

    _tsw_ledger("human-touch", {"ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "throughput-stall-watchdog", "stage": "executa", "kind": "technical", "bead_id": "", "reason": notify_msg}, fail_open=True)

    ok_mail = False
    if _do_mail_mayor is not None:
        ok_mail = _do_mail_mayor(subject, body)
    else:
        r = _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
                timeout=45)
        ok_mail = bool(r and r.returncode == 0)

    if not ok_mail:
        _log("WARN: gc mail send mayor FAILED — notify still sent (imp07 invariant)")

    # imp14: write flow-authority marker so PSW/PTH/FFF can defer their own Mayor mail.
    dimension = ("throughput:" + stalled_rigs[0]) if stalled_rigs else "throughput"
    _write_flow_authority(now, dimension)

    return ok_mail


# ── main detection tick ───────────────────────────────────────────────────────
def run_tick(now, state):
    """One evaluation cycle. Mutates state in-place. Returns True if a stall was confirmed
    and escalated this tick; False otherwise.

    FAIL-OPEN (readable-but-zero): a signal that is readable but returns 0 is treated as
    genuine idle — no alert. This preserves the original behavior for a legitimately quiet
    pipeline.

    FAIL-CLOSED (blind-floor, imp08): if 2+ signals ERROR in the same sweep, the system is
    BLIND — we call _tick_blind_and_dolt which escalates after BLIND_CONFIRM_SWEEPS consecutive
    blind sweeps. A blind sweep still returns False (no stall verdict) but the blind escalation
    fires via notify (PRIMARY).

    DOLT-HEALTH (imp08): Dolt is probed every tick independently of the three throughput signals.
    A confirmed unhealthy Dolt → distinct "dolt" escalation after DOLT_CONFIRM_SWEEPS sweeps."""
    window_sec = STALL_HOURS * 3600
    signals_errored = []   # names of signals that ERROR this sweep (for imp08 blind-floor)

    # SIGNAL 1: dispatch
    dispatch_count, last_dispatch_epoch = dispatch_signal(now, window_sec)
    if dispatch_count is None:
        # ERROR: fail-open for stall logic; count for blind-floor
        _log("tick: dispatch_signal ERROR → fail-open (treat as dispatched)")
        signals_errored.append("dispatch")

    # SIGNAL 2: merge
    merge_count, last_merge_epoch = merge_signal(now, window_sec)
    if merge_count is None:
        _log("tick: merge_signal ERROR → fail-open (treat as merged)")
        signals_errored.append("merge")

    # imp08: blind-floor + Dolt-health check (runs every tick regardless of signal state)
    is_blind, _dolt_esc = _tick_blind_and_dolt(signals_errored, now, state)

    # imp23: delivery-stall check (runs every tick, independent of throughput stall)
    _tick_delivery(now, state)

    if is_blind:
        # Blind sweep: skip stall logic entirely (can't make a verdict).
        # Stall pending counter is NOT reset — we don't know if it's a stall or not.
        _log("tick: BLIND SWEEP — skipping stall verdict (signals_errored=%s)" % signals_errored)
        return False

    # If dispatch or merge errored but we're NOT blind (only one errored), treat it as
    # fail-open (flow present) for the stall detector — same as before imp08.
    if dispatch_count is None:
        _log("tick: dispatch_signal fail-open → treating as dispatched, resetting stall counter")
        _maybe_recover(state, "dispatch-signal unavailable")
        return False

    if merge_count is None:
        _log("tick: merge_signal fail-open → treating as merged, resetting stall counter")
        _maybe_recover(state, "merge-signal unavailable")
        return False

    # ── per-rig path (TSW_PER_RIG=1, default) ────────────────────────────────────
    # merge_signal returns a dict when PER_RIG=1. Gate-PASSED (global, no rig tag) is
    # a global flow signal: when present it suppresses all per-rig stalls. Only when
    # gate-PASSED==0 do we check each rig's git count individually — this removes the
    # cross-rig masking where HQ git commits were hiding a dead WA worker pool.
    if PER_RIG and isinstance(merge_count, dict):
        gate_passed = merge_count.get("_gate_passed", 0)
        merge_ok_rigs = merge_count.get("_git_ok_rigs", set())  # fail-open guard: only check rigs read ok
        merge_per_rig = {k: v for k, v in merge_count.items()
                         if k not in ("_gate_passed", "_git_ok_rigs")}
        total_git = sum(merge_per_rig.values())

        if gate_passed > 0:
            # Global gate activity → flow present, no stall possible this tick
            if state["pending"] > 0 or state["escalations"] > 0:
                _log("tick: per-rig: gate-PASSED=%d → global flow, stall cleared" % gate_passed)
                _maybe_recover(state, "flow resumed (gate-PASSED global)")
            else:
                _log("tick: per-rig: gate-PASSED=%d (dispatched=%d) in %.0fh — healthy" % (
                     gate_passed, dispatch_count, STALL_HOURS))
            return False

        # No gate-PASSED events. Evaluate backlog per rig.
        backlog_count, sample_beads = backlog_signal()
        if backlog_count is None:
            signals_errored.append("backlog")
            _log("tick: backlog_signal ERROR → fail-open (treat as no backlog)")
            is_blind, _ = _tick_blind_and_dolt(signals_errored, now, state)
            if is_blind:
                _log("tick: BLIND SWEEP (all 3 signals errored) — skipping stall verdict")
                return False
            _maybe_recover(state, "backlog-signal unavailable")
            return False

        # backlog_count is a dict[rig_name, int] when PER_RIG=1
        backlog_per_rig = backlog_count if isinstance(backlog_count, dict) else {}
        susp = suspended_rigs()

        # STALL iff any rig has backlog >= MIN AND git-merges == 0 AND not suspended.
        # A rig with 0 backlog is not a stall source even if merge==0.
        stalled_rigs = sorted([
            rig for rig in backlog_per_rig
            if backlog_per_rig.get(rig, 0) >= BACKLOG_MIN
            and rig in merge_ok_rigs              # fail-open: skip rigs whose git read failed
            and merge_per_rig.get(rig, 0) == 0
            and rig not in susp
        ])

        if not stalled_rigs:
            total_backlog = sum(backlog_per_rig.values())
            if total_backlog < BACKLOG_MIN:
                if state["pending"] > 0 or state["escalations"] > 0:
                    _log("tick: per-rig: backlog=0 → legitimately idle, resetting")
                    _maybe_recover(state, "backlog empty (legitimate idle)")
                else:
                    _log("tick: per-rig: 0 gate-PASSED + 0 git-merges in %.0fh but "
                         "backlog=%d < %d — legitimate idle" % (STALL_HOURS, total_backlog, BACKLOG_MIN))
            else:
                # Backlog present but all stalled rigs either have git merges or are suspended
                if state["pending"] > 0 or state["escalations"] > 0:
                    _log("tick: per-rig: all backlogged rigs have merges or are suspended → stall cleared "
                         "(backlog=%d git=%d susp=%s)" % (total_backlog, total_git, sorted(susp)))
                    _maybe_recover(state, "flow resumed (per-rig)")
                else:
                    _log("tick: per-rig: backlog=%d but all rigs merging or suspended — healthy "
                         "(git=%d susp=%s)" % (total_backlog, total_git, sorted(susp)))
            return False

        # Per-rig stall: at least one rig has backlog >= MIN and 0 git-merges and not suspended
        stall_backlog = sum(backlog_per_rig.get(r, 0) for r in stalled_rigs)
        state["pending"] += 1
        _log("tick: per-rig STALL DETECTED (%d/%d): stalled_rigs=%s backlog=%d "
             "git=%d dispatched=%d in %.0fh" % (
             state["pending"], CONFIRM_SWEEPS, stalled_rigs, stall_backlog,
             total_git, dispatch_count, STALL_HOURS))

        if state["pending"] < CONFIRM_SWEEPS:
            _log("tick: awaiting confirmation (%d/%d sweeps)" % (state["pending"], CONFIRM_SWEEPS))
            return False

        if (state["last_escalate"] > 0 and
                now - state["last_escalate"] <= ESCALATE_COOLDOWN_SEC):
            _log("tick: per-rig STALL confirmed but within cooldown — suppressing")
            return False

        _log("ESCALATING: per-rig THROUGHPUT STALL (%d sweeps), stalled_rigs=%s backlog=%d" % (
             state["pending"], stalled_rigs, stall_backlog))

        if _attempt_heal(now, state):
            return False

        ok = _escalate(stall_backlog, dispatch_count, last_dispatch_epoch,
                       total_git, last_merge_epoch, sample_beads, now, window_sec,
                       stalled_rigs=stalled_rigs)
        state["last_escalate"] = now
        state["escalations"] += 1
        state["consecutive_escalations"] = state.get("consecutive_escalations", 0) + 1
        _log("escalation %s (total: %d, consecutive: %d)" % (
             "OK" if ok else "FAILED (notify still sent)",
             state["escalations"], state["consecutive_escalations"]))
        return True

    # ── global path (TSW_PER_RIG=0 or merge_count is int) ────────────────────────
    # Short-circuit: FLOW == actual COMPLETIONS (merges / gate-PASSED), NOT dispatches.
    # ga-dbibq lesson (2026-06-27): a dispatch that builds NOTHING still increments
    # dispatch_count, so keying "flow" on dispatch let a fully-stalled pipeline (workers
    # churning, 0 builds, 0 merges for 5h) read as "flow detected — healthy". Only a merge
    # in the window proves work is actually reaching done. dispatch_count is still reported
    # in the escalation body as context ("N dispatches but 0 completions = broken downstream").
    if merge_count > 0:
        if state["pending"] > 0 or state["escalations"] > 0:
            _log("tick: flow detected (merged=%d, dispatched=%d) — stall cleared" % (
                 merge_count, dispatch_count))
            _maybe_recover(state, "flow resumed")
        else:
            _log("tick: flow present (merged=%d dispatched=%d in %.0fh) — healthy" % (
                 merge_count, dispatch_count, STALL_HOURS))
        return False

    # SIGNAL 3: backlog (only evaluate when merge_count == 0 — i.e. nothing completed —
    # to save BD load on a healthy system; dispatch activity no longer suppresses this)
    backlog_count, sample_beads = backlog_signal()
    if backlog_count is None:
        # ERROR: backlog signal failed — count toward blind-floor too
        signals_errored.append("backlog")
        _log("tick: backlog_signal ERROR → fail-open (treat as no backlog)")
        # Re-check blind-floor with the newly errored backlog signal
        is_blind, _ = _tick_blind_and_dolt(signals_errored, now, state)
        if is_blind:
            _log("tick: BLIND SWEEP (all 3 signals errored) — skipping stall verdict")
            return False
        _maybe_recover(state, "backlog-signal unavailable")
        return False

    if backlog_count < BACKLOG_MIN:
        if state["pending"] > 0 or state["escalations"] > 0:
            _log("tick: backlog=0 → pipeline legitimately idle, resetting")
            _maybe_recover(state, "backlog empty (legitimate idle)")
        else:
            _log("tick: 0 dispatches + 0 merges in %.0fh but backlog=%d < %d — legitimate idle" % (
                 STALL_HOURS, backlog_count, BACKLOG_MIN))
        return False

    # STALL DETECTED: backlog >= BACKLOG_MIN, 0 dispatches, 0 merges in window
    state["pending"] += 1
    _log("tick: STALL DETECTED (%d/%d): backlog=%d, dispatched=%d, merged=%d in %.0fh" % (
         state["pending"], CONFIRM_SWEEPS, backlog_count, dispatch_count, merge_count, STALL_HOURS))

    if state["pending"] < CONFIRM_SWEEPS:
        _log("tick: awaiting confirmation (%d/%d sweeps)" % (state["pending"], CONFIRM_SWEEPS))
        return False

    # Confirmed stall. Check cooldown.
    if (state["last_escalate"] > 0 and
            now - state["last_escalate"] <= ESCALATE_COOLDOWN_SEC):
        _log("tick: STALL confirmed but within cooldown (last escalation %.0fmin ago) — suppressing" % (
             (now - state["last_escalate"]) / 60))
        return False

    # Escalate
    _log("ESCALATING: THROUGHPUT STALL confirmed (%d sweeps), backlog=%d, "
         "dispatched=%d, merged=%d in %.0fh" % (
         state["pending"], backlog_count, dispatch_count, merge_count, STALL_HOURS))

    # imp24: attempt auto-heal before escalating; success = stall-cleared next tick
    if _attempt_heal(now, state):
        return False

    ok = _escalate(backlog_count, dispatch_count, last_dispatch_epoch,
                   merge_count, last_merge_epoch, sample_beads, now, window_sec)
    state["last_escalate"] = now
    state["escalations"] += 1
    state["consecutive_escalations"] = state.get("consecutive_escalations", 0) + 1  # imp11
    _log("escalation %s (total escalations: %d, consecutive: %d)" % (
         "OK" if ok else "FAILED (notify still sent)",
         state["escalations"], state["consecutive_escalations"]))
    return True


def _maybe_recover(state, reason):
    if state["pending"] > 0 or state["escalations"] > 0:
        _log("RECOVERED (%s): stall cleared (was pending=%d escalations=%d)" % (
             reason, state["pending"], state["escalations"]))
        state["pending"] = 0
        state["consecutive_escalations"] = 0  # imp11: reset circuit-breaker on recovery
        # Note: do NOT reset last_escalate — cooldown still applies on recovery+redetect.
        # (If the stall immediately re-appears after recovery, we want the cooldown to hold.)


# ── main ──────────────────────────────────────────────────────────────────────
def main():
    if not ENABLED:
        _log("disabled via TSW_ENABLED=0 — no-op")
        return

    _log("throughput-stall watchdog started — backlog cross-check vs dispatch+merge "
         "(window=%.0fh, confirm=%d sweeps, backlog_min=%d, poll=%ds, cooldown=%ds)" % (
         STALL_HOURS, CONFIRM_SWEEPS, BACKLOG_MIN, POLL_SEC, ESCALATE_COOLDOWN_SEC))

    state = _load_state()
    _log("loaded state: pending=%d last_escalate=%.0f escalations=%d" % (
         state["pending"], state["last_escalate"], state["escalations"]))

    while True:
        try:
            run_tick(time.time(), state)
            _save_state(state)
        except Exception as e:
            _log("loop error (continuing): %r" % e)
        time.sleep(POLL_SEC)


# ── selftest ─────────────────────────────────────────────────────────────────
def _selftest():
    """Hermetic selftests — stubs all I/O via module globals. Exit 0 if all pass.

    The test seams (_read_pilot_log_lines, _read_gate_log_lines, _git_log_count,
    _bd_backlog, _do_mail_mayor, _do_notify) are module-level globals already checked
    by every production function; setting them here redirects I/O without spawning
    any real subprocess or touching the filesystem.
    """
    import sys
    # We are executing in __main__ context, so the module globals ARE our globals.
    # Use `global` to inject into the correct namespace.
    global _read_pilot_log_lines, _read_gate_log_lines, _git_log_count
    global _bd_backlog, _bd_delivery, _do_mail_mayor, _do_notify, _do_dolt_probe
    global _suspended_rigs, _bd_marker_for_bead, _do_dolt_cpu, _bd_sling_state

    ok_count = [0]
    fail_count = [0]
    mail_calls = []
    notify_calls = []

    def _ok(label):
        ok_count[0] += 1
        print("  ok  %s" % label)

    def _bad(label, detail=""):
        fail_count[0] += 1
        print("  FAIL %s%s" % (label, ": " + detail if detail else ""))

    NOW = 1_750_000_000.0
    WIN = 6 * 3600  # 6h, matches default TSW_STALL_HOURS

    def _pilot_lines(dispatched, n):
        """n sweep-complete lines with dispatched=<dispatched>, all within WIN of NOW."""
        out = []
        for i in range(n):
            e = NOW - WIN / 2 + i * 60
            ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(e))
            out.append("%s [pilot-dispatcher] === Pilot sweep complete: dispatched=%d "
                       "(small_slots=4 big_slots=2 dolt_saturated_at_start=0) ===\n" % (ts, dispatched))
        return out

    def _gate_lines(n):
        """n Gate PASSED lines within WIN of NOW."""
        out = []
        for i in range(n):
            e = NOW - WIN / 2 + i * 60
            ts = time.strftime("[%Y-%m-%d %H:%M:%S]", time.localtime(e))
            out.append("%s [quality-gate-dispatcher] Gate PASSED: branch=crew/x tier=CODE\n" % ts)
        return out

    def _backlog(count):
        return [{"id": "wa-%04d" % i, "title": "Test story %d" % i,
                 "labels": ["story:approved"]} for i in range(count)]

    def _reset():
        return {"pending": 0, "last_escalate": 0.0, "escalations": 0,
                "blind_pending": 0, "blind_last_escalate": 0.0,
                "dolt_pending": 0, "dolt_last_escalate": 0.0,
                "delivery_pending": 0, "delivery_last_escalate": 0.0,
                "heal_last_attempt": 0.0,
                "heal_attempt_count": 0, "consecutive_escalations": 0}

    def _stub_mail(subject, body):
        mail_calls.append((subject, body))
        return True

    def _stub_notify(msg, prio):
        notify_calls.append((msg, prio))

    _do_mail_mayor = _stub_mail
    _do_notify = _stub_notify
    # imp08: stub Dolt probe as healthy by default so existing scenarios A-G are
    # not affected by whatever the live Dolt state is during the selftest.
    _do_dolt_probe = lambda: 0   # 0=healthy — overridden per imp08 scenario as needed
    # imp23: stub delivery signal as no stalled beads by default so existing scenarios
    # are not affected.
    _bd_delivery = lambda root: []   # no stalled beads — overridden in L/M/N scenarios
    # ga-g0v96: stub the marker check as "absent" by default (pre-fix behavior:
    # every stalled bead is unexplained) — overridden in the ga-g0v96 scenarios below.
    _bd_marker_for_bead = lambda root, bead_id: ("absent", None)
    _do_dolt_cpu = lambda: 42.0
    # imp24: heal disabled by default so existing scenarios are not affected.
    _do_heal_throughput = None   # overridden in P/Q scenarios
    # imp12: quota check stubbed as available by default
    globals()["_do_check_quota"] = lambda: True
    globals()["QUOTA_AWARE"] = False
    # ga-dbibq: stub suspended_rigs as empty set to avoid real gc subprocess calls.
    # Per-rig scenarios PR1/PR2 override this as needed.
    _suspended_rigs = lambda: set()

    print("\n[tsw selftest] running scenarios...\n")

    # ── A: backlog>0, 0 dispatches, 0 merges → stall after CONFIRM_SWEEPS ────────
    print("Scenario A: stall confirms after %d sweeps" % CONFIRM_SWEEPS)
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(3)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()

    run_tick(NOW, st)
    if st["pending"] == 1 and st["escalations"] == 0 and not mail_calls:
        _ok("A1: first sweep → pending=1, no escalation yet")
    else:
        _bad("A1", "pending=%d escalations=%d mails=%d" % (st["pending"], st["escalations"], len(mail_calls)))

    run_tick(NOW + 1800, st)
    if st["escalations"] >= 1 and mail_calls and notify_calls:
        _ok("A2: second sweep → confirmed + escalated (mail+notify sent)")
    else:
        _bad("A2", "escalations=%d mails=%d notifies=%d" % (st["escalations"], len(mail_calls), len(notify_calls)))

    if mail_calls and "stall" in mail_calls[0][0].lower():
        _ok("A3: escalation subject mentions stall")
    else:
        _bad("A3: subject", mail_calls[0][0] if mail_calls else "no mail")

    mail_calls.clear(); notify_calls.clear()
    run_tick(NOW + 3600, st)
    if not mail_calls:
        _ok("A4: cooldown suppresses re-escalation while still stalled")
    else:
        _bad("A4: cooldown should suppress", "%d mails sent" % len(mail_calls))

    # ── B: backlog>0, dispatches>0 but merges=0 → IS a stall (ga-dbibq: dispatch≠throughput)
    print("\nScenario B: recent dispatch but 0 merges → IS a stall (dispatch no longer masks stall)")
    _read_pilot_log_lines = lambda: _pilot_lines(1, 2)  # dispatched=1, but builds nothing
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(5)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if st["escalations"] >= 1 and mail_calls:
        _ok("B: dispatch-only (0 merges) → stall confirmed and escalated (pending=%d escalations=%d)" % (
            st["pending"], st["escalations"]))
    else:
        _bad("B", "pending=%d escalations=%d mails=%d" % (st["pending"], st["escalations"], len(mail_calls)))

    # ── C: backlog>0 but recent merge (gate PASSED) → NO stall ───────────────────
    print("\nScenario C: recent merge → no stall")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: _gate_lines(1)   # 1 gate PASSED in window
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(5)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not st["pending"] and not st["escalations"] and not mail_calls:
        _ok("C: recent merge → no stall")
    else:
        _bad("C", "pending=%d escalations=%d mails=%d" % (st["pending"], st["escalations"], len(mail_calls)))

    # ── D: empty backlog + 0 dispatches + 0 merges → legitimate idle, NO stall ───
    print("\nScenario D: empty backlog → legitimate idle, no stall")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []   # no ready work
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not st["pending"] and not st["escalations"] and not mail_calls:
        _ok("D: empty backlog → legitimate idle, no alert")
    else:
        _bad("D", "pending=%d escalations=%d mails=%d" % (st["pending"], st["escalations"], len(mail_calls)))

    # ── E: confirm-reset on a non-stall sweep ────────────────────────────────────
    # Flow is now MERGE-only (ga-dbibq). Use a merge in the "flow" sweep to reset
    # the counter; dispatch alone no longer qualifies as flow.
    print("\nScenario E: confirm-reset: stall T0, merge-flow T1, stall T2 → counter starts over")
    _calls = [0]
    def _gate_e():
        _calls[0] += 1
        return _gate_lines(1) if _calls[0] == 2 else []   # merge only on 2nd call
    _read_pilot_log_lines = lambda: _pilot_lines(0, 2)
    _read_gate_log_lines  = _gate_e
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(3)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()

    run_tick(NOW, st)        # sweep 1: stall detected
    if st["pending"] == 1:
        _ok("E1: first stall sweep → pending=1")
    else:
        _bad("E1", "expected pending=1, got %d" % st["pending"])

    run_tick(NOW + 1800, st)  # sweep 2: flow → reset
    if st["pending"] == 0 and st["escalations"] == 0:
        _ok("E2: flow sweep → counter reset to 0")
    else:
        _bad("E2", "pending=%d escalations=%d" % (st["pending"], st["escalations"]))

    run_tick(NOW + 3600, st)  # sweep 3: stall again → pending=1, NOT 2
    if st["pending"] == 1:
        _ok("E3: stall after reset → counter starts from 1 (not 2)")
    else:
        _bad("E3", "expected pending=1, got %d" % st["pending"])

    # ── F: fail-open — pilot log missing → no alert ───────────────────────────────
    print("\nScenario F: fail-open — pilot log unreadable → no alert")
    _read_pilot_log_lines = lambda: []    # empty list = unreadable log
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(5)
    mail_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    if not mail_calls and not st["escalations"]:
        _ok("F: empty pilot log → fail-open, no alert")
    else:
        _bad("F: should fail-open on unreadable pilot log")

    # ── G: braked beads excluded from backlog ─────────────────────────────────────
    # 2026-07-15: extended to cover story:needs-human and story:refinement-in-progress —
    # the two brake classes that leaked and caused the false THROUGHPUT STALL against a
    # correctly-idle pipeline (wa-x7ndm/wa-3sxpm needs-human, wa-v89e3.4/wa-0nm4v in-refino).
    print("\nScenario G: braked beads (gate/story:needs-human / in-flight / refino / manual) → excluded, no alarm")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: [
        {"id": "wa-0001", "title": "Braked",     "labels": ["story:approved", "gate:needs-human"]},
        {"id": "wa-0002", "title": "In-flight",  "labels": ["story:in-flight"]},
        {"id": "wa-0003", "title": "Manual",     "labels": ["story:approved", "exec:manual"]},
        {"id": "wa-0004", "title": "NeedsHuman", "labels": ["story:approved", "ctx:ready", "story:needs-human"]},
        {"id": "wa-0005", "title": "InRefino",   "labels": ["ctx:ready", "story:refinement-in-progress"]},
        {"id": "wa-0006", "title": "DepBlock",   "labels": ["story:approved", "blocked-on:wa-9999"]},
        {"id": "wa-0007", "title": "Thin",       "labels": ["ctx:ready", "ctx:thin"]},
    ]
    mail_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not st["escalations"] and not mail_calls:
        _ok("G: all braked/needs-human/refino/dep-blocked/manual beads excluded → no false alarm")
    else:
        _bad("G", "escalations=%d mails=%d" % (st["escalations"], len(mail_calls)))

    # ── imp08-H: 2 signals error → blind, escalates after BLIND_CONFIRM_SWEEPS ─────
    print("\nimp08 Scenario H: 2-signal error → blind-floor escalates after %d sweeps" % BLIND_CONFIRM_SWEEPS)
    # To make dispatch_signal ERROR: return [] (empty = unreadable log)
    _read_pilot_log_lines = lambda: []
    # To make merge_signal ERROR: stub returns empty list but set gate_log_read=False by
    # temporarily overriding DISPATCH_LOG to a non-existent path AND making git fail.
    import sys as _h_sys
    _saved_dispatch_log = globals().get("DISPATCH_LOG", "")
    # Inject a non-existent DISPATCH_LOG into the module's global namespace
    _h_sys.modules[__name__]  # no-op; we're in __main__ so globals() IS module globals
    _orig_DISPATCH_LOG = DISPATCH_LOG
    # We can't rebind the module-level name from inside a function easily without globals().
    # But _read_gate_log_lines=None means merge_signal uses _tail(DISPATCH_LOG).
    # _tail returns [] on any exception; gate_log_read = os.path.exists(DISPATCH_LOG).
    # Solution: provide the stub as a list-returning callable, but also make git fail.
    # The merge_signal considers itself "read" if _read_gate_log_lines is not None (stub).
    # But an empty gate-log stub + no git = count=0, not an error. We need BOTH to fail.
    # Correct approach: the merge_signal seam _read_gate_log_lines returns a list
    # (even empty). To force _SIGNAL_ERROR we need gate_log_read=False AND git to fail.
    # Use a workaround: make _read_gate_log_lines=None (no stub) so _tail runs on a bogus
    # path (which returns []) but gate_log_read becomes os.path.exists(bogus_path)=False.
    # We do this by patching DISPATCH_LOG in our globals() temporarily.
    _read_gate_log_lines  = None   # use _tail(DISPATCH_LOG) path in merge_signal
    _git_log_count        = lambda root, since: None   # all git fail → git_any_success=False
    _bd_backlog           = lambda root: _backlog(3)   # backlog present (readable)
    _do_dolt_probe        = lambda: 0                  # healthy Dolt (don't conflate)
    # Patch DISPATCH_LOG to a guaranteed non-existent path so gate_log_read=False
    globals()["DISPATCH_LOG"] = "/tmp/__tsw_selftest_nonexistent_dispatch_log__"
    mail_calls.clear(); notify_calls.clear()
    st = _reset()

    # sweep 1: dispatch+merge error (2 signals) → blind_pending=1, no escalation yet
    run_tick(NOW, st)
    if st["blind_pending"] >= 1 and not notify_calls:
        _ok("H1: 2-signal error sweep 1 → blind_pending incremented, no escalation yet")
    else:
        _bad("H1", "blind_pending=%d notifies=%d" % (st.get("blind_pending", -1), len(notify_calls)))

    # sweep 2: same errors → blind_pending=2 >= BLIND_CONFIRM_SWEEPS → escalate
    run_tick(NOW + 1800, st)
    if notify_calls and "BLIND" in notify_calls[-1][0].upper():
        _ok("H2: 2nd blind sweep → notify escalation fired (BLIND in message)")
    else:
        _bad("H2", "expected notify with BLIND, got: %r" % notify_calls)
    # Restore DISPATCH_LOG
    globals()["DISPATCH_LOG"] = _orig_DISPATCH_LOG

    # ── imp08-I: 1 signal error (not blind) → no blind escalation ────────────────
    print("\nimp08 Scenario I: 1-signal error → NOT blind, no blind escalation")
    _read_pilot_log_lines = lambda: []   # dispatch: ERROR
    # merge: readable (gate log has lines)
    _read_gate_log_lines  = lambda: []   # empty but readable
    _git_log_count        = lambda root, since: 0  # git works, returns 0
    _bd_backlog           = lambda root: []   # empty backlog → legitimate idle
    _do_dolt_probe        = lambda: 0         # Dolt healthy
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    blind_notifies = [n for n in notify_calls if "BLIND" in n[0].upper()]
    if not blind_notifies and st.get("blind_pending", 0) == 0:
        _ok("I: 1-signal error → blind_pending=0, no BLIND notification")
    else:
        _bad("I", "blind_pending=%d blind_notifies=%d" % (st.get("blind_pending", 0), len(blind_notifies)))

    # ── imp08-J: all-readable-zero → idle, no stall, no blind alert ──────────────
    print("\nimp08 Scenario J: all signals readable and zero → legitimate idle, no alert")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)   # readable, 0 dispatches
    _read_gate_log_lines  = lambda: []                    # readable, 0 gate-pass
    _git_log_count        = lambda root, since: 0         # readable, 0 commits
    _bd_backlog           = lambda root: []               # readable, 0 backlog
    _do_dolt_probe        = lambda: 0                     # Dolt healthy
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not mail_calls and not notify_calls and st.get("blind_pending", 0) == 0:
        _ok("J: all-readable-zero → idle, no escalation, no blind alert")
    else:
        _bad("J", "mails=%d notifies=%d blind_pending=%d" % (
             len(mail_calls), len(notify_calls), st.get("blind_pending", 0)))

    # ── imp08-K: Dolt confirmed unreachable (SUSTAINED) → dolt stall escalation ───
    # The seam returns the ROBUST verdict per sweep (gc-dolt-probe.sh --robust already
    # collapses transient bursts to rc=0; rc=1 here = a fully-failed sweep: every health
    # retry failed AND SELECT 1 refused). Escalation requires DOLT_CONFIRM_SWEEPS such
    # sweeps IN A ROW — this direction proves a genuine outage STILL pages.
    print("\nimp08 Scenario K: Dolt unreachable rc=1 SUSTAINED → page on sweep %d (DOLT_CONFIRM_SWEEPS)" % DOLT_CONFIRM_SWEEPS)
    _read_pilot_log_lines = lambda: _pilot_lines(1, 3)   # dispatch readable (flow present → no throughput stall)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []
    _do_dolt_probe        = lambda: 1   # every sweep: robust probe says UNREACHABLE
    mail_calls.clear(); notify_calls.clear()
    st = _reset()

    # sweeps 1..K-1: dolt_pending climbs but NO page yet (sustained-failure requirement)
    for i in range(DOLT_CONFIRM_SWEEPS - 1):
        run_tick(NOW + i * 1800, st)
    pre = [n for n in notify_calls if "DOLT" in n[0].upper() or "dolt" in n[0].lower()]
    if st.get("dolt_pending", 0) == DOLT_CONFIRM_SWEEPS - 1 and not pre:
        _ok("K1: %d unhealthy sweep(s) < K=%d → no Dolt page yet (dolt_pending=%d)" % (
            DOLT_CONFIRM_SWEEPS - 1, DOLT_CONFIRM_SWEEPS, st.get("dolt_pending", 0)))
    else:
        _bad("K1", "dolt_pending=%d notifies=%d (expected pending=%d, 0 notifies)" % (
            st.get("dolt_pending", 0), len(pre), DOLT_CONFIRM_SWEEPS - 1))

    # sweep K: dolt_pending == DOLT_CONFIRM_SWEEPS → escalate
    run_tick(NOW + (DOLT_CONFIRM_SWEEPS - 1) * 1800, st)
    dolt_notifies = [n for n in notify_calls if "DOLT" in n[0].upper() or "dolt" in n[0].lower()]
    if dolt_notifies:
        _ok("K2: %d-th sustained unhealthy sweep → Dolt escalation notify fired (real outage still pages)" % DOLT_CONFIRM_SWEEPS)
    else:
        _bad("K2", "expected Dolt notify on sweep %d, got: %r" % (DOLT_CONFIRM_SWEEPS, notify_calls))

    # ── imp08-K3 (transient): unhealthy sweeps interrupted by a healthy one → NO page ──
    # Models the CPU-burst false alarm: some sweeps read rc=1 but a healthy sweep (robust
    # probe returned rc=0 — SELECT 1 served) resets dolt_pending before K accumulate in a
    # row. This direction proves a transient NEVER pages.
    print("\nimp08 Scenario K3: transient (rc=1..1,0 repeating) never reaches K consecutive → NO Dolt page")
    _read_pilot_log_lines = lambda: _pilot_lines(1, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []
    _probe_seq = ([1] * (DOLT_CONFIRM_SWEEPS - 1) + [0]) * 3   # (K-1 bad, 1 healthy) × 3
    _seq_idx = [0]
    def _probe_transient():
        v = _probe_seq[min(_seq_idx[0], len(_probe_seq) - 1)]
        _seq_idx[0] += 1
        return v
    _do_dolt_probe = _probe_transient
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    for i in range(len(_probe_seq)):
        run_tick(NOW + i * 1800, st)
    dolt_notifies3 = [n for n in notify_calls if "DOLT" in n[0].upper() or "dolt" in n[0].lower()]
    if not dolt_notifies3 and st.get("dolt_pending", 0) < DOLT_CONFIRM_SWEEPS:
        _ok("K3: transient bursts (healthy sweep resets counter) → no false Dolt page (dolt_pending=%d < %d)" % (
            st.get("dolt_pending", 0), DOLT_CONFIRM_SWEEPS))
    else:
        _bad("K3", "false Dolt page on transient: notifies=%d dolt_pending=%d" % (
            len(dolt_notifies3), st.get("dolt_pending", 0)))
    _do_dolt_probe = lambda: 0   # restore healthy for subsequent scenarios

    # ── imp23-L: delivery stall confirms after DELIVERY_CONFIRM_SWEEPS ──────────
    print("\nimp23 Scenario L: %d stalled in-flight beads → delivery stall after %d sweeps" % (
          2, DELIVERY_CONFIRM_SWEEPS))

    def _stale_bead(bid, hours_ago):
        stale_epoch = NOW - hours_ago * 3600
        ts = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(stale_epoch))
        return {"id": bid, "title": "Stale in-flight %s" % bid,
                "labels": ["story:in-flight", "pilot:dispatched"],
                "updated_at": ts}

    def _stale_bead_with_sling(bid, hours_ago, sling_id):
        """Same as _stale_bead but carrying pilot.sling_bead metadata (ga-ebm7c)."""
        b = _stale_bead(bid, hours_ago)
        b["metadata"] = {"pilot.sling_bead": sling_id}
        return b

    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)   # no dispatch
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []               # no ready work (avoid throughput stall noise)
    _bd_delivery          = lambda root: [_stale_bead("wa-d001", DELIVERY_STALL_HOURS + 1),
                                          _stale_bead("wa-d002", DELIVERY_STALL_HOURS + 2)]
    _do_dolt_probe        = lambda: 0
    mail_calls.clear(); notify_calls.clear()
    st = _reset()

    run_tick(NOW, st)
    if st.get("delivery_pending", 0) == 1 and not notify_calls:
        _ok("L1: first delivery-stall sweep → delivery_pending=1, no notify yet")
    else:
        _bad("L1", "delivery_pending=%d notifies=%d" % (st.get("delivery_pending", 0), len(notify_calls)))

    run_tick(NOW + 1800, st)
    delivery_notifies = [n for n in notify_calls if "DELIVERY" in n[0].upper() or "delivery" in n[0].lower()]
    if delivery_notifies:
        _ok("L2: second sweep → delivery stall escalated (notify fired)")
    else:
        _bad("L2", "expected delivery notify, got: %r" % notify_calls)
    delivery_mails = [m for m in mail_calls if "delivery" in m[0].lower() or "DELIVERY" in m[0]]
    if delivery_mails:
        _ok("L3: delivery stall escalation sent Mayor mail")
    else:
        _bad("L3", "expected delivery mail, got: %r" % mail_calls)

    # Cooldown: re-running should not re-escalate
    mail_calls.clear(); notify_calls.clear()
    run_tick(NOW + 3600, st)
    delivery_notifies2 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if not delivery_notifies2:
        _ok("L4: cooldown suppresses re-escalation on delivery stall")
    else:
        _bad("L4: cooldown should suppress delivery re-escalation", str(notify_calls))

    # ── imp23-M: fresh in-flight beads → no delivery stall ───────────────────────
    print("\nimp23 Scenario M: fresh in-flight beads → no delivery stall")
    _bd_delivery = lambda root: [_stale_bead("wa-f001", 0.5)]  # only 30min old — under threshold
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    delivery_notifies3 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if not delivery_notifies3 and st.get("delivery_pending", 0) == 0:
        _ok("M: fresh in-flight beads (< %.0fh) → no delivery stall alert" % DELIVERY_STALL_HOURS)
    else:
        _bad("M", "delivery_pending=%d delivery_notifies=%d" % (
             st.get("delivery_pending", 0), len(delivery_notifies3)))

    # ── imp23-N: delivery signal error → fail-open, no false alert ───────────────
    print("\nimp23 Scenario N: delivery signal error → fail-open, no alert")
    _bd_delivery = None                   # use real bd path (will fail in selftest context)
    _bd_delivery = lambda root: None      # stub returning None = error sentinel
    # But delivery_signal converts None-per-bead to skips. For ERROR: return None from _bd_delivery
    # The actual test seam check is: if _bd_delivery is not None: beads = _bd_delivery(root);
    # at_least_one_success = True. Even returning None from stub → beads=None → continue (no stall).
    # To simulate full signal failure we need at_least_one_success=False. We do this by
    # making _bd_delivery raise (not return None), but that bypasses at_least_one_success.
    # Simplest: keep _bd_delivery=None (use real bd which will fail in selftest) for one rig.
    # Actually: the cleanest approach is a stub that sets at_least_one_success=False via
    # returning a sentinel. The existing code: `beads = _bd_delivery(root); at_least_one_success=True`.
    # So any _bd_delivery call sets at_least_one_success=True. To force ERROR (None, []) return
    # from delivery_signal, we need all RIG_ROOTS to be skipped. We can do this by temporarily
    # overriding RIG_ROOTS to empty.
    _saved_rig_roots = globals().get("RIG_ROOTS", [])
    globals()["RIG_ROOTS"] = []    # empty → at_least_one_success stays False → (None, [])
    _bd_delivery = lambda root: []  # irrelevant when RIG_ROOTS=[]
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["RIG_ROOTS"] = _saved_rig_roots
    delivery_notifies4 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if not delivery_notifies4:
        _ok("N: delivery signal error (empty RIG_ROOTS) → fail-open, no delivery alert")
    else:
        _bad("N", "should not fire delivery alert on signal error, got: %r" % notify_calls)

    # ── ga-g0v96 Scenario O1: bead explained by a healthy queued marker never
    # escalates, no matter how many sweeps (AC1: not an anomaly) ────────────────
    print("\nga-g0v96 Scenario O1: explained-by-marker bead never escalates")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []
    _bd_delivery = lambda root: [_stale_bead("wa-o001", DELIVERY_STALL_HOURS + 1)]
    _bd_marker_for_bead = lambda root, bead_id: ("found", {"id": "ga-wisp-o001"})
    _do_dolt_probe = lambda: 0
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    for i in range(5):
        run_tick(NOW + i * 1800, st)
    delivery_notifies_o1 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if not delivery_notifies_o1 and st.get("delivery_pending", 0) == 0:
        _ok("O1: bead with a healthy queued marker never triggers delivery-stall escalation (ga-g0v96 AC1)")
    else:
        _bad("O1", "delivery_pending=%d notifies=%d" % (st.get("delivery_pending", 0), len(delivery_notifies_o1)))

    # ── ga-g0v96 Scenario O2: mixed explained+unexplained — escalates for the
    # real anomaly only; explained bead is annotated (not hidden, not conflated) ─
    print("\nga-g0v96 Scenario O2: mixed explained+unexplained — escalates, annotates correctly")
    _bd_delivery = lambda root: [_stale_bead("wa-o002-explained", DELIVERY_STALL_HOURS + 2),
                                 _stale_bead("wa-o003-real", DELIVERY_STALL_HOURS + 3)]

    def _marker_o2(root, bead_id):
        if bead_id == "wa-o002-explained":
            return ("found", {"id": "ga-wisp-o002"})
        return ("absent", None)
    _bd_marker_for_bead = _marker_o2
    _do_dolt_cpu = lambda: 210.0
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)
    delivery_mails_o2 = [m for m in mail_calls if "DELIVERY" in m[0]]
    if delivery_mails_o2:
        o2_body = delivery_mails_o2[0][1]
        amostra_section = o2_body.split("POSSÍVEIS CAUSAS")[0]
        annotated = ("aguardando headroom" in o2_body and "ga-wisp-o002" in o2_body and "210" in o2_body
                     and "wa-o002-explained" in o2_body)
        not_in_amostra = "wa-o002-explained" not in amostra_section
        real_anomaly_present = "wa-o003-real" in amostra_section
        if annotated and not_in_amostra and real_anomaly_present:
            _ok("O2: escalates for the real anomaly only; explained bead annotated separately "
                "with headroom hours + Dolt cpu% (ga-g0v96 AC1)")
        else:
            _bad("O2", "annotated=%s not_in_amostra=%s real_anomaly_present=%s body=%r" % (
                 annotated, not_in_amostra, real_anomaly_present, o2_body))
        if "NÃO remova" in o2_body:
            _ok("O2b: mail explicitly warns not to remove gate:queued from explained beads (ga-g0v96 AC2)")
        else:
            _bad("O2b", "expected an explicit 'do not remove gate:queued' warning in the mail body")
    else:
        _bad("O2", "expected a delivery mail for the unexplained bead, got: %r" % mail_calls)

    # ── ga-g0v96 Scenario O3: the marker-check itself ERRORS → fail-open to the
    # OLD behavior (treated as unexplained) — an error must never SUPPRESS a
    # genuine stall just because this diagnostic probe failed ──────────────────
    print("\nga-g0v96 Scenario O3: marker-check error falls back to unexplained (fail-open)")
    _bd_delivery = lambda root: [_stale_bead("wa-o004-errcheck", DELIVERY_STALL_HOURS + 1)]
    _bd_marker_for_bead = lambda root, bead_id: ("error", None)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)
    delivery_notifies_o3 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if delivery_notifies_o3:
        _ok("O3: marker-check ERROR does not suppress a genuine stall — still escalates (fail-open, ga-g0v96)")
    else:
        _bad("O3", "marker-check error incorrectly suppressed escalation: %r" % notify_calls)

    _bd_marker_for_bead = lambda root, bead_id: ("absent", None)   # restore default
    _do_dolt_cpu = lambda: 42.0

    # ── ga-9ni9w/ga-ebm7c: sling-aware delivery stall. FALSIFYING TEST (per the
    # bug's own Aceite): pair a story stale well past the window with a FRESH
    # open sling → must be SILENT (this is exactly the gap the pre-fix watchdog
    # had: it looked only at the story). Then age the SAME sling past the
    # window too → must ALERT, and the alert must name the sling, not just the
    # story, else an investigator starts at the wrong bead ─────────────────────
    print("\nga-ebm7c Scenario Q1: story stale but its pilot.sling_bead is open+recent → SILENCE")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: []
    _bd_delivery = lambda root: [_stale_bead_with_sling("ga-q001", DELIVERY_STALL_HOURS + 3, "ga-q001-sling")]
    _bd_marker_for_bead = lambda root, bead_id: ("absent", None)
    _bd_sling_state = lambda sling_id: ("live", 10 / 60.0)   # sling updated 10min ago
    _do_dolt_probe = lambda: 0
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    for i in range(5):
        run_tick(NOW + i * 1800, st)
    delivery_notifies_q1 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if not delivery_notifies_q1 and st.get("delivery_pending", 0) == 0:
        _ok("Q1: story stalled but its pilot.sling_bead is open+recent → no delivery-stall "
            "alert, no matter how many sweeps (ga-9ni9w)")
    else:
        _bad("Q1", "delivery_pending=%d notifies=%d — the story-only staleness check regressed "
                    "(this is today's bug)" % (st.get("delivery_pending", 0), len(delivery_notifies_q1)))

    print("\nga-ebm7c Scenario Q2: same story, sling ALSO stale → ALERT, names the sling")
    _bd_sling_state = lambda sling_id: ("stale", DELIVERY_STALL_HOURS + 1)   # sling itself now stale
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)
    delivery_notifies_q2 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    delivery_mails_q2 = [m for m in mail_calls if "DELIVERY" in m[0]]
    if delivery_notifies_q2 and delivery_mails_q2 and "ga-q001-sling" in delivery_mails_q2[0][1]:
        _ok("Q2: story + its sling both stale → delivery-stall alert fires and NAMES the sling "
            "bead (ga-9ni9w Aceite)")
    else:
        _bad("Q2", "notifies=%d mails=%d body=%r" % (
             len(delivery_notifies_q2), len(delivery_mails_q2),
             delivery_mails_q2[0][1] if delivery_mails_q2 else None))

    print("\nga-ebm7c Scenario Q3: no pilot.sling_bead at all → unchanged (real stall, as before)")
    _bd_delivery = lambda root: [_stale_bead("ga-q003", DELIVERY_STALL_HOURS + 1)]   # no metadata
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)
    delivery_notifies_q3 = [n for n in notify_calls if "DELIVERY" in n[0].upper()]
    if delivery_notifies_q3:
        _ok("Q3: story with no pilot.sling_bead at all still alerts exactly as before (no regression)")
    else:
        _bad("Q3", "expected the no-sling-metadata case to still alert: %r" % notify_calls)

    _bd_sling_state = lambda sling_id: ("absent", None)   # restore default (no live sling)

    # ── imp24-P: heal-action branch wiring ───────────────────────────────────────
    print("\nimp24 Scenario P1: HEAL_ENABLED=0 → heal not attempted, stall escalates normally")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(3)
    _bd_delivery          = lambda root: []
    _do_dolt_probe        = lambda: 0
    heal_calls_p1 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_p1.append(1), True)[1]
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    globals()["HEAL_ENABLED"] = False
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if st["escalations"] >= 1 and not heal_calls_p1:
        _ok("P1: HEAL_ENABLED=0 → stall escalates normally, healer not called")
    else:
        _bad("P1", "escalations=%d heal_calls=%d" % (st["escalations"], len(heal_calls_p1)))

    print("\nimp24 Scenario P2: HEAL_ENABLED=1 + healer succeeds → escalation suppressed this tick")
    heal_calls_p2 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_p2.append(1), True)[1]
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    globals()["HEAL_ENABLED"] = True
    run_tick(NOW, st)            # first sweep: pending=1, no escalation yet
    run_tick(NOW + 1800, st)     # second sweep: stall confirmed, healer fires, escalation suppressed
    globals()["HEAL_ENABLED"] = False
    if heal_calls_p2 and not mail_calls:
        _ok("P2: HEAL_ENABLED=1 + healer ok → escalation suppressed; heal attempted")
    else:
        _bad("P2", "heal_calls=%d mail_calls=%d" % (len(heal_calls_p2), len(mail_calls)))

    print("\nimp24 Scenario P3: HEAL_ENABLED=1 + healer fails → stall escalates anyway")
    heal_calls_p3 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_p3.append(1), False)[1]
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    globals()["HEAL_ENABLED"] = True
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["HEAL_ENABLED"] = False
    if heal_calls_p3 and mail_calls:
        _ok("P3: HEAL_ENABLED=1 + healer fails → stall still escalates")
    else:
        _bad("P3", "heal_calls=%d mail_calls=%d" % (len(heal_calls_p3), len(mail_calls)))

    print("\nimp24 Scenario P4: suppress window — heal attempted once, re-run within window skips re-heal")
    heal_calls_p4 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_p4.append(1), True)[1]
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    globals()["HEAL_ENABLED"] = True
    run_tick(NOW, st)              # pending=1
    run_tick(NOW + 1800, st)       # confirmed → heal fires at NOW+1800, suppressed until NOW+1800+600=NOW+2400
    run_tick(NOW + 2200, st)       # NOW+2200 < NOW+2400 → still in suppress window → no re-heal
    globals()["HEAL_ENABLED"] = False
    if len(heal_calls_p4) == 1 and not mail_calls:
        _ok("P4: suppress window active → healer called only once, escalation still suppressed")
    else:
        _bad("P4", "heal_calls=%d mail_calls=%d (expected 1 heal, 0 mails)" % (len(heal_calls_p4), len(mail_calls)))

    # Reset imp24 global knobs
    globals()["HEAL_ENABLED"] = False
    globals()["_do_heal_throughput"] = None

    # ── imp11 Scenario Q: anti-thrash budget + circuit-breaker ───────────────────
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(3)
    _bd_delivery          = lambda root: []
    _do_dolt_probe        = lambda: 0

    print("\nimp11 Scenario Q1: budget=1 — after 1 heal, second stall escalates (budget exhausted)")
    heal_calls_q1 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_q1.append(1), True)[1]
    globals()["HEAL_ENABLED"] = True
    globals()["HEAL_BUDGET"] = 1
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)   # heal fires, consumes budget slot
    run_tick(NOW + 5400, st)   # beyond suppress window, budget=1/1 → circuit-break → escalates
    globals()["HEAL_ENABLED"] = False
    globals()["HEAL_BUDGET"] = 3
    if len(heal_calls_q1) == 1 and mail_calls:
        _ok("Q1: budget=1 exhausted → second confirmed stall escalates directly")
    else:
        _bad("Q1", "heal_calls=%d mail_calls=%d" % (len(heal_calls_q1), len(mail_calls)))

    print("\nimp11 Scenario Q2: CIRCUIT_BREAK_ESCALATIONS=1 → extended suppress window after 1 escalation")
    heal_calls_q2 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_q2.append(1), False)[1]  # healer fails → escalates
    globals()["HEAL_ENABLED"] = True
    globals()["CIRCUIT_BREAK_ESCALATIONS"] = 1
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)   # stall confirmed → heal attempted (fails) → escalates → consec=1
    mail_calls.clear(); notify_calls.clear()
    # Re-check at NOW+2000: WITHIN extended window (HEAL_SUPPRESS_SEC*4=2400s from first heal at NOW+1800)
    run_tick(NOW + 3000, st)   # 1200s after first heal: within extended 2400s window → suppress
    globals()["HEAL_ENABLED"] = False
    globals()["CIRCUIT_BREAK_ESCALATIONS"] = 2
    globals()["_do_heal_throughput"] = None
    if not mail_calls and st.get("consecutive_escalations", 0) >= 1:
        _ok("Q2: circuit-break extended suppress window → re-run within window suppressed")
    else:
        _bad("Q2", "mail_calls=%d consec=%d" % (len(mail_calls), st.get("consecutive_escalations", 0)))

    # ── imp12 Scenario R: quota-aware suppression ─────────────────────────────────
    print("\nimp12 Scenario R1: quota exhausted → heal skipped (budget preserved), escalation suppressed")
    heal_calls_r1 = []
    globals()["_do_heal_throughput"] = lambda: (heal_calls_r1.append(1), True)[1]
    globals()["_do_check_quota"] = lambda: False  # quota exhausted
    globals()["HEAL_ENABLED"] = True
    globals()["QUOTA_AWARE"] = True
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st)
    run_tick(NOW + 1800, st)  # stall confirmed but quota=0 → suppress without healing
    globals()["HEAL_ENABLED"] = False
    globals()["QUOTA_AWARE"] = False
    globals()["_do_check_quota"] = None
    globals()["_do_heal_throughput"] = None
    if not heal_calls_r1 and not mail_calls and st.get("heal_attempt_count", 0) == 0:
        _ok("R1: quota exhausted → heal skipped, budget preserved (attempt_count=0), escalation suppressed")
    else:
        _bad("R1", "heal_calls=%d mail_calls=%d attempt_count=%d" % (
             len(heal_calls_r1), len(mail_calls), st.get("heal_attempt_count", 0)))

    # ── PR1/PR2: per-rig stall decision (ga-dbibq) ───────────────────────────────
    # These scenarios require TSW_PER_RIG=1 (the default in production).
    # RIG_ROOTS is overridden in PR1 so the HQ root (.gascity-gastown-hq) matches
    # the stub condition ("gascity" in root OR root.endswith(".gascity-gastown-hq")).
    _saved_rig_roots_pr = globals().get("RIG_ROOTS", [])
    PR_RIG_ROOTS = [
        "/Users/athos/gt/.gascity-gastown-hq",
        "/Users/athos/gt/whatsapp_automation",
        "/Users/athos/gt/property_scrapers",
    ]
    globals()["PER_RIG"] = True
    _bd_delivery = lambda root: []   # no delivery stalls in per-rig scenarios
    _do_dolt_probe = lambda: 0       # Dolt healthy

    # ── PR1 (ga-dbibq resilience): per-rig — one rig stalled while another merges → STALL ──
    print("\nScenario PR1: per-rig — WA backlog + 0 WA merges, HQ merging → STALL (no cross-rig mask)")
    globals()["RIG_ROOTS"] = PR_RIG_ROOTS
    _read_pilot_log_lines = lambda: _pilot_lines(0, 2)      # dispatch aggregate irrelevant
    _read_gate_log_lines  = lambda: []                       # no gate-PASSED lines in the log tail
    # git merges only on the HQ root; WA root has zero:
    _git_log_count        = lambda root, since: (3 if ("gascity" in root or root.rstrip("/").endswith(".gascity-gastown-hq")) else 0)
    _bd_backlog           = lambda root: (_backlog(5) if "whatsapp" in root else [])   # only WA has ready backlog
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["RIG_ROOTS"] = _saved_rig_roots_pr
    if st["escalations"] >= 1:
        _ok("PR1: WA stall (backlog + 0 merges) escalates despite HQ merging (cross-rig mask removed)")
    else:
        _bad("PR1", "pending=%d esc=%d — HQ merges masked the WA-rig stall" % (st["pending"], st["escalations"]))

    # ── PR2: per-rig — a rig with backlog but SUSPENDED must NOT false-alarm ──
    print("\nScenario PR2: per-rig — suspended rig with backlog → no alarm")
    _bd_backlog           = lambda root: (_backlog(5) if "whatsapp" in root else [])
    _git_log_count        = lambda root, since: 0            # nobody merging
    # mark WA suspended via the seam the impl must add (see Step 3): _suspended_rigs returns a set
    globals()["_suspended_rigs"] = lambda: {"whatsapp_automation"}
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["_suspended_rigs"] = None
    if not st["escalations"] and not mail_calls:
        _ok("PR2: suspended rig with backlog does not false-alarm")
    else:
        _bad("PR2", "esc=%d mails=%d — suspended rig false-alarmed" % (st["escalations"], len(mail_calls)))

    # ── PR3: per-rig fail-open — partial git failure on a backlogged rig must NOT false-alarm ──
    print("\nScenario PR3: per-rig — WA git fails (None), WA backlog >= MIN → NO alarm (fail-open)")
    globals()["RIG_ROOTS"] = PR_RIG_ROOTS
    _read_pilot_log_lines = lambda: _pilot_lines(0, 2)
    _read_gate_log_lines  = lambda: []
    # WA git fails (returns None); HQ git succeeds (returns 3) — WA must not false-alarm
    _git_log_count        = lambda root, since: (3 if ("gascity" in root or root.rstrip("/").endswith(".gascity-gastown-hq")) else None)
    _bd_backlog           = lambda root: (_backlog(5) if "whatsapp" in root else [])
    globals()["_suspended_rigs"] = lambda: set()
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    globals()["RIG_ROOTS"] = _saved_rig_roots_pr
    if st["escalations"] == 0 and not mail_calls:
        _ok("PR3: WA git failure + WA backlog → fail-open, no false STALL alarm")
    else:
        _bad("PR3", "esc=%d mails=%d — partial git failure caused false alarm" % (st["escalations"], len(mail_calls)))

    # ── PR4: _query_suspended_rigs_via_gc parses the real gc rig list --json shape ──
    print("\nScenario PR4a: _query_suspended_rigs_via_gc — real JSON shape, wa suspended → {\"whatsapp_automation\"}")
    _real_gc_json = (
        '{"city_name":"gascity","ok":true,"rigs":['
        '{"name":"gascity","prefix":"ga","hq":true,"suspended":false,"running":true},'
        '{"name":"property_scrapers","suspended":false},'
        '{"name":"whatsapp_automation","suspended":true}'
        ']}'
    )
    import types as _types
    _fake_ok = _types.SimpleNamespace(returncode=0, stdout=_real_gc_json)
    _saved_sh = globals().get("_sh")
    globals()["_sh"] = lambda *a, **kw: _fake_ok
    _result_pr4a = _query_suspended_rigs_via_gc()
    globals()["_sh"] = _saved_sh
    if _result_pr4a == {"whatsapp_automation"}:
        _ok("PR4a: real gc rig list JSON parsed correctly → {\"whatsapp_automation\"}")
    else:
        _bad("PR4a", "got %r — expected {\"whatsapp_automation\"}" % (_result_pr4a,))

    print("\nScenario PR4b: _query_suspended_rigs_via_gc — returncode=1 (error) → fail-open set()")
    _fake_err = _types.SimpleNamespace(returncode=1, stdout="")
    globals()["_sh"] = lambda *a, **kw: _fake_err
    _result_pr4b = _query_suspended_rigs_via_gc()
    globals()["_sh"] = _saved_sh
    if _result_pr4b == set():
        _ok("PR4b: gc rig list error → fail-open set()")
    else:
        _bad("PR4b", "got %r — expected set()" % (_result_pr4b,))

    # ── PR5: default HQ rig root must equal CITY (bead store), not bare git root ──
    # _saved_rig_roots_pr was captured from the module-level RIG_ROOTS before any PR override,
    # so it reflects the real default (un-overridden). The HQ root is the entry whose
    # _rig_name returns "gascity" (the else-branch fall-through). Asserting it equals CITY
    # catches a future regression that accidentally points HQ back at /Users/athos/gt (git
    # root, no bead store there → bd -C fails silently, TSW blind to HQ backlog/delivery).
    print("\nScenario PR5: default RIG_ROOTS HQ entry == CITY (bead store), not bare git root")
    _hq_roots_pr5 = [r for r in _saved_rig_roots_pr if _rig_name(r) == "gascity"]
    if _hq_roots_pr5 and _hq_roots_pr5[0] == CITY:
        _ok("PR5: default HQ rig root == CITY (%s) — bead store path confirmed" % CITY)
    else:
        _bad("PR5", "HQ root=%r  CITY=%r — HQ root does NOT equal bead store (bd -C will fail)" % (
             _hq_roots_pr5[0] if _hq_roots_pr5 else None, CITY))

    print("\nScenario ga-hzt8s-1: _bead_is_braked — newly-added park labels (deliverable 2, "
          "sourced from the canonical park_labels.py) now excluded from backlog")
    _ghz_cases = [
        (["story:approved", "needs-label-review"], True, "needs-label-review"),
        (["ctx:ready", "waiting-on:wa-9999"], True, "waiting-on:* (standalone, previously "
         "only blocked-on:*/blocked-reason:* were covered)"),
        (["story:approved", "framework:engine"], True, "framework:engine"),
        (["story:approved", "story:awaiting-external-merge"], True, "story:awaiting-external-merge"),
        (["ctx:ready", "pilot:no-auto-dispatch"], True, "pilot:no-auto-dispatch"),
        (["ctx:ready", "on-device"], True, "on-device"),
        (["story:approved", "pilot:held-until:9999999999"], True,
         "pilot:held-until:* (dash-suffix of pilot:held — the OLD colon-only "
         "matcher never matched this despite listing bare pilot:held)"),
        (["story:approved", "ctx:ready"], False, "no park label — genuinely backlog"),
    ]
    for _ghz_labs, _ghz_expect, _ghz_desc in _ghz_cases:
        _ghz_got = _bead_is_braked(set(_ghz_labs))
        if _ghz_got == _ghz_expect:
            _ok("ga-hzt8s-1: %s → braked=%s" % (_ghz_desc, _ghz_expect))
        else:
            _bad("ga-hzt8s-1", "%s: expected braked=%s got %s" % (_ghz_desc, _ghz_expect, _ghz_got))

    print("\nScenario ga-hzt8s-2: _bead_is_braked — reclaim-count is now a NUMERIC >= cap "
          "check (park_labels.is_reclaim_exhausted), not the old hardcoded exact-string "
          "'pilot:reclaim-count:3' — a bumped/higher count is still correctly excluded")
    _ghz_over_cap = _bead_is_braked({"story:approved", "pilot:reclaim-count:4"})
    _ghz_under_cap = _bead_is_braked({"story:approved", "pilot:reclaim-count:2"})
    if _ghz_over_cap is True:
        _ok("ga-hzt8s-2: pilot:reclaim-count:4 (>= DEFAULT_RECLAIM_CAP=3) → braked "
            "(old exact-string match for '3' would have MISSED this)")
    else:
        _bad("ga-hzt8s-2", "pilot:reclaim-count:4 should be braked (numeric >=), got %s"
             % _ghz_over_cap)
    if _ghz_under_cap is False:
        _ok("ga-hzt8s-2: pilot:reclaim-count:2 (< cap) → NOT braked (still genuinely retrying)")
    else:
        _bad("ga-hzt8s-2", "pilot:reclaim-count:2 should NOT be braked yet, got %s"
             % _ghz_under_cap)

    # ── cleanup ───────────────────────────────────────────────────────────────────
    _read_pilot_log_lines = None
    _read_gate_log_lines  = None
    _git_log_count        = None
    _bd_backlog           = None
    _bd_delivery          = None
    _do_notify            = None
    _do_mail_mayor        = None
    _do_dolt_probe        = None
    _do_heal_throughput   = None
    _suspended_rigs       = None
    globals()["_do_check_quota"] = None

    print("\n[tsw selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    sys.exit(0 if fail_count[0] == 0 else 1)


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()

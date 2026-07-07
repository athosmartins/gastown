#!/usr/bin/env python3
"""Self-healing gate watchdog — SPAWNS A DEDICATED REPAIR AGENT, Athos is FYI-only.

Philosophy (per Athos, 2026-06-07; sharpened 2026-06-11 / ga-afytf): a serious
problem must not merely ping the human who can't fix it. Autonomy does not require
a 100%-automatic fix — it requires WAKING AN AGENT that investigates and resolves
without depending on the Mayor being awake. So on detect this watchdog now SPAWNS
a dedicated repair agent (a gastown.dog) and hands it the runbook + diagnostics;
the agent runs the recovery ladder itself and escalates to the human only if it
fails. The Mayor is a FALLBACK (woken only if a repair agent could not be spawned),
not the primary actor. Athos is notified as a courtesy FYI ("detectei X, despachei
reparo") and paged LOUDLY only as a last resort if recovery never lands.

This is the "automatic crew member" that the 2026-06-07 outage lacked: the gate
died at ~20:00 and was only fixed hours later because a human crew member happened
to notice and mailed the Mayor. This watchdog is that noticer — in minutes — and
now also the dispatcher of the fixer, so recovery does not wait on the Mayor.

DETECTS (gate not producing verdicts — the tonight signature):
  - 2+ "Gate FAILED: TIMEOUT" in the dispatcher log within TIMEOUT_WINDOW, OR
  - a marker stuck gate-status:dispatching past DISPATCH_STUCK_SEC while every
    gate-reviewer session sits non-active (spawned but never materialized).
  Corroborated by Dolt instability lines in the supervisor log (connection reset /
  bead store closed / invalid connection) — the root cause that night.

DETECTS (head-of-line stale-branch block — the ga-hl0gq signature, 2026-06-10):
  - the dispatcher keeps re-picking the SAME oldest branch every sweep, its
    auto-rebase conflicts (dead author), it re-queues gate-status:queued, and the
    whole queue behind it stops draining (zero merges). Signature: the last
    >=HEADOFLINE_MIN_SWEEPS "Dispatcher sweep complete" lines are all
    "verdict=QUEUED (retry ...)" naming the SAME branch.
  This mode is INVISIBLE to the two checks above: no run reaches verdict
  collection, so there is no TIMEOUT and no "Verdicts 0/N" poll line — which is
  exactly why the 2026-06-10 stall ran 49min before a human asked for status.
  Detected here in ~2 sweeps (~6min). The permanent dispatcher-level auto-skip is
  ga-q3ig2; this wake is the detection+recovery bridge until it lands.

DETECTS (orphaned queued marker — the gt-mqkwj signature, 2026-06-12):
  - a gate-status:queued marker created during a dispatcher OUTAGE (a gap with no
    'sweep complete' lines) whose gate_run was dropped, so on recovery the
    dispatcher LEAPFROGS it for newer markers — it never gets dispatched, its
    source bead sits in_progress forever, and the pool reconciler re-spawns a
    worker onto already-finished work ~6x. INVISIBLE to all three checks above:
    not 'dispatching' (stuck_dispatching blind), no TIMEOUT (recent_timeouts
    blind), and not head-of-line (the queue drains for OTHER branches, so
    headofline_stall sees verdicts advancing for those).
  Signature (orphaned_queued_marker): a queued marker that is (a) older than
    ORPHAN_MIN_AGE_SEC, (b) NEVER mentioned in the recent dispatcher log, while
    (c) the dispatcher is actively draining (newest 'sweep complete' is fresh)
    and (d) a strictly-NEWER queued marker's branch IS mentioned — proof the
    dispatcher leapfrogged the older one. The leapfrog proof (d) is what keeps a
    normal FIFO backlog behind a slow run — many markers older than the newest
    completed sweep, but none actually skipped — from false-firing.

ON DETECT:
  1. snapshot diagnostics to /tmp/gate-watchdog-diag-<ts>.txt
  2. SPAWN a dedicated repair agent: route the runbook (referencing the
     gate-reviewer-spawn-failure-playbook memory + the known fix) as a task bead to
     the gastown.dog pool AND spawn a dog directly (gc session new) so recovery does
     not depend on the demand-reconciler, which the gate-down failure mode can itself
     wedge. The agent collects diagnostics, runs the runbook (kickstart supervisor,
     kill+re-convene a frozen reviewer, check rig-path/Dolt), and escalates to Athos
     via notify if it cannot recover. If spawning fails, FALL BACK to waking the Mayor.
  3. notify Athos FYI (low priority): "gate travou, despachei agente de reparo".
  4. cooldown WAKE_COOLDOWN before dispatching another repair cycle.

ESCALATE (last resort): if still broken after ESCALATE_AFTER_WAKES repair-cycles,
fire ntfy 🚨 -p 5 to Athos — autonomous recovery couldn't fix it, a human is needed.

Recovers silently: when a Gate PASSED appears after a dispatch, reset state (solved).
Never crashes (every external call guarded); silence = healthy.
"""
import json, time, datetime, subprocess, os, re
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _grw_ledger

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
SUPERVISOR_LOG = "/Users/athos/.gc/supervisor.log"
SITE_TOML = os.path.join(CITY, ".gc/site.toml")
NOTIFY = "/Users/athos/.local/bin/notify"
DOG_TEMPLATE = "gastown.dog"   # utility pool the repair agent is spawned into (ga-afytf)
QUOTA_CHECK = os.path.join(CITY, "scripts/claude-quota-check.sh")  # ground-truth quota verdict (ga-wjlv9)

POLL_SEC = 120  # ga-8smq3: was 60; all thresholds below are 12-40min, so 120s loses no detection latency while halving this daemon's Dolt poll load
TIMEOUT_WINDOW_SEC = 1800      # 2+ timeouts within 30min = gate not producing verdicts
DISPATCH_STUCK_SEC = 720       # marker dispatching >12min w/ no active reviewers = spawn fail
PILOT_JAM_WINDOW_SEC = 900     # 2+ sweep-aborts within 15min = Pilot jammed on a bad bead
PILOT_STALL_SEC = 2400         # pilot log silent >40min = Pilot dead/not sweeping
GRW_WAKE_GRACE = os.environ.get("GRW_WAKE_GRACE", "1") != "0"  # ga-m1o5: suppress a stall verdict a machine sleep can fully explain (mirrors daemon-presence-watchdog.sh's DPW_WAKE_GRACE)
HEADOFLINE_MIN_SWEEPS = 2      # >=2 consecutive QUEUED-retry sweeps on the SAME branch = head-of-line block
HEADOFLINE_LOG_FRESH_SEC = 600 # ignore if dispatcher log is staler than this (that's ENGINE-STALL's job)
ORPHAN_LOG_FRESH_SEC = 600     # dispatcher log must be live (process still writing) — else ENGINE-STALL's job
ORPHAN_DRAIN_FRESH_SEC = 1200  # newest COMPLETED sweep within 20min = dispatcher actively draining (not wedged on one run)
ORPHAN_MIN_AGE_SEC = 1800      # a queued marker must sit >=30min unmentioned before we call it skipped (rules out a just-created marker)
WAKE_COOLDOWN_SEC = int(os.environ.get("WAKE_COOLDOWN_SEC", "1200"))   # base: don't dispatch a new repair for the SAME condition more than once per 20min
ESCALATE_AFTER_WAKES = int(os.environ.get("ESCALATE_AFTER_WAKES", "2"))  # after N unresolved repair-cycles for one condition, page Athos 🚨

# ---- RUNAWAY GOVERNOR knobs (ga-wisp-q9b3as2: the watchdog spawned ~28 repair
#      dogs — 6 for the SAME marker — because nothing deduped, capped, or backed
#      off; their collective bd/gc poll load became a PRIMARY Dolt-CPU driver that
#      WORSENED the reviewer boot-stall the watchdog was reacting to → it spawned
#      MORE. These bound the loop. All env-overridable; defaults are conservative). ----
GRW_ENABLED = os.environ.get("GRW_ENABLED", "1") != "0"          # kill switch: "0" = detect+log only, never spawn/wake
GRW_DRY_RUN = os.environ.get("GRW_DRY_RUN", "0") == "1"          # "1" = log the spawn decision but do not actually spawn (observability/test)
MAX_ACTIVE_REPAIR_DOGS = int(os.environ.get("MAX_ACTIVE_REPAIR_DOGS", "3"))   # hard cap: never spawn while >= this many watchdog repair dogs are already live
MAX_SPAWNS_PER_CONDITION = int(os.environ.get("MAX_SPAWNS_PER_CONDITION", "3"))  # after N spawns for the SAME condition (no recovery), stop spawning; notify-once only
REPAIR_DOG_STALE_SEC = int(os.environ.get("REPAIR_DOG_STALE_SEC", "3600"))    # a repair dog older than this no longer counts (assumed done/reaped) for dedup+cap
WAKE_BACKOFF_MAX_SEC = int(os.environ.get("WAKE_BACKOFF_MAX_SEC", "7200"))    # exponential per-condition cooldown backoff is capped here (2h)
REPAIR_DUAL_SPAWN = os.environ.get("REPAIR_DUAL_SPAWN", "0") == "1"           # "0" (default) = direct-spawn first, sling durable bead ONLY if direct fails (halves load); "1" = legacy always-both

# ---- DIRECT SELF-HEAL knobs (the two toils the Mayor fixed BY HAND ~6x/day) ----
# Unlike the spawn-a-dog / wake-the-Mayor detectors above, these two features
# perform the recovery MUTATION DIRECTLY (the same `bd close/update/label` +
# `gc session close` the Mayor ran by hand) so the gate self-heals without waiting
# on a dog (which itself can hang) or a Mayor (who may be asleep). Both are bounded,
# fail-SAFE (any query error → skip, never a blind mutation), honor GRW_DRY_RUN
# (log the decision, mutate nothing — used for the live sanity pass) and the
# GRW_ENABLED master kill-switch. They are cheap bd ops, so they run every sweep
# even while the spawn-detectors are infra-throttled (a reap FREES load; a fail-safe
# skip fires automatically if Dolt is wedged and the queries fail).
#
# FIX 1 — auto-reap a HUNG gate-reviewer / stale gate-status:running gate-run.
GRW_REAP_HUNG_ENABLED = os.environ.get("GRW_REAP_HUNG_ENABLED", "1") != "0"
REVIEW_HANG_MINUTES = int(os.environ.get("GRW_REVIEW_HANG_MINUTES", "18"))       # a run must be >this old before reap is even considered — well above a normal 9-min review and below the guard's 55m/90m TTLs so the toil is caught EARLY, not after 30-40m
REAP_MAX_PER_SWEEP = int(os.environ.get("GRW_REAP_MAX_PER_SWEEP", "3"))          # hard cap on hung-run reaps per sweep
LIVENESS_RESAMPLE_SEC = int(os.environ.get("GRW_LIVENESS_RESAMPLE_SEC", "8"))    # gap between the two liveness samples that confirm SUSTAINED-idle (never reap on a single snapshot — a real review can blip asleep between heartbeats)
# FIX 2 — auto-requeue a STUCK gate-status:error marker (error → queued).
GRW_REQUEUE_ERROR_ENABLED = os.environ.get("GRW_REQUEUE_ERROR_ENABLED", "1") != "0"
ERROR_REQUEUE_MINUTES = int(os.environ.get("GRW_ERROR_REQUEUE_MINUTES", "8"))    # a marker must sit in error >this before requeue, so a transient error self-clears on the dispatcher's own next sweep first
ERROR_REQUEUE_MAX_PER_SWEEP = int(os.environ.get("GRW_ERROR_REQUEUE_MAX_PER_SWEEP", "5"))
ERROR_REQUEUE_MAX_ATTEMPTS = int(os.environ.get("GRW_ERROR_REQUEUE_MAX_ATTEMPTS", "3"))  # after K watchdog-requeues of the SAME marker (it keeps re-erroring), STOP and escalate to the Mayor — mirror the gate's own fix-attempt cap philosophy instead of an infinite requeue loop
# FIX 3 — kill a FROZEN gate-reviewer (state=active but last_active silent past the
# threshold). reap_hung_runs (FIX 1) CANNOT catch this: its reviewer reads active, so
# hung_run_verdict returns skip:reviewer-active. The dispatcher's own ga-q8tmn detects
# the freeze and re-convenes, but only MAX_RESPAWNS_PER_SLOT (2) times — after that it
# waits the full 45m outer timeout. That is the ~90-min stall the Mayor cleared by hand
# with `gc session kill` (2026-07-02: reviewer 6ohacd silent 34m, queue starved to
# 531m). A working reviewer refreshes last_active on EVERY tool call, so >this-many
# seconds of silence is a wedged Claude. `gc session kill` makes the reconciler revive
# it in place (same id, fresh runtime → the dispatcher's slot ref stays valid). This is
# the BACKSTOP after the dispatcher gives up, so the threshold sits WELL past its
# ~9-min diff-scaled detection + 2 respawns.
GRW_REAP_FROZEN_ENABLED = os.environ.get("GRW_REAP_FROZEN_ENABLED", "1") != "0"
FROZEN_KILL_SECS = int(os.environ.get("GRW_FROZEN_KILL_SECS", "900"))            # 15min of last_active silence on a STILL-active reviewer = definitively wedged (past the dispatcher's own detect+respawn cycle); SUSTAINED-confirmed on a resample before any kill
FROZEN_KILL_MAX_PER_SWEEP = int(os.environ.get("GRW_FROZEN_KILL_MAX_PER_SWEEP", "2"))  # blast-radius cap: if MANY reviewers are silent at once (systemic Dolt/quota outage) killing them only churns — cap it and let the infra detectors + Mayor escalation handle a mass outage
# FIX 4 — reap a QUEUED marker whose SOURCE is done, and clear a STALE gate:reviewing
# label that STARVES a queued marker. Root (2026-07-02, a 9h head-of-line stall): a
# reviewer that DRAINS during startup leaves `gate:reviewing` on its SOURCE bead with
# NO terminal path to clear it → the dispatcher skips re-dispatch ("already in review")
# → the marker starves forever (wa-ya17c queued 572min). Separately, several markers'
# SOURCES had already CLOSED (work merged) but the queued markers were never reaped —
# phantom queue depth that inflates the "oldest queued" alarm. FIX 1/2 don't cover a
# gate-status:queued marker (they handle running-run reaps + gate-status:error). The
# Mayor cleaned both by hand; this makes it durable.
GRW_REAP_ORPHAN_ENABLED = os.environ.get("GRW_REAP_ORPHAN_ENABLED", "1") != "0"
ORPHAN_MARKER_MIN_MINUTES = int(os.environ.get("GRW_ORPHAN_MARKER_MIN_MINUTES", "15"))  # a marker must be queued >this before FIX4 touches it — so a normal spin-up (source briefly gate:reviewing before the marker flips to dispatching) is never mistaken for a stale leak
ORPHAN_MAX_PER_SWEEP = int(os.environ.get("GRW_ORPHAN_MAX_PER_SWEEP", "8"))
# FIX 5 — recover a STRANDED-VERDICT run: gate-status:running with ALL required verdicts
# DELIVERED but never finalized (the managing dispatcher sweep died post-verdict → the
# run sits 'running' forever, the source keeps a stale gate:reviewing → the kanban shows
# a phantom 'em revisão' with NO live reviewer; wa-99jug 2026-07-02). reap_hung_runs
# (FIX 1) SKIPS this — it requires 0 delivered verdicts (a delivered verdict reads as
# 'producing'). Recovery = supersede the run + clear the source's stale gate:reviewing +
# re-queue the marker so a fresh sweep re-reviews and finalizes cleanly (merge on PASS,
# needs-fix on FAIL — the watchdog never duplicates that crown-jewel logic). Per-marker
# attempt cap → escalate to needs-human if a marker keeps stranding.
GRW_REAP_STRANDED_ENABLED = os.environ.get("GRW_REAP_STRANDED_ENABLED", "1") != "0"
STRANDED_RUN_MINUTES = int(os.environ.get("GRW_STRANDED_RUN_MINUTES", "15"))      # a healthy finalize is seconds after the last verdict; 15min (~5 dispatcher sweeps) past = the managing sweep is dead. SUSTAINED-confirmed on a resample first.
STRANDED_MAX_ATTEMPTS = int(os.environ.get("GRW_STRANDED_MAX_ATTEMPTS", "2"))     # after K recoveries of the SAME marker (finalize keeps dying), escalate to needs-human instead of another futile re-review
GRW_STRANDED_LABEL_RE = re.compile(r"^grw-stranded:(\d+)$")                        # restart-safe per-marker stranded-recovery counter
RECOVERY_LOG = os.path.join(CITY, ".gc/logs/gate-recovery-actions.jsonl")        # durable jsonl audit of every direct reap/requeue (evidence)
GRW_REQUEUE_LABEL_RE = re.compile(r"^grw-requeue:(\d+)$")                          # restart-safe per-marker requeue counter, stamped on the marker as a label
# FIX 6 — requeue a STRANDED dispatching|reviewing MARKER whose reviewer DIED leaving
# NO open running gate-run (wa-ppe5v, 3× in one session 2026-07-07: wa-b7z7c/wa-jpuu6/
# wa-u3ay1). When a reviewer dies mid-review (drain / machine-sleep / quota / crash),
# the dispatcher does not always leave a running gate-run for FIX 1/5 to reap — it died
# DURING dispatch (marker gate-status:dispatching, run never created) OR the run was
# already closed while the marker never advanced — so the marker sits dispatching|
# reviewing FOREVER. FIX 1 only reaps running RUNS, FIX 4 only touches queued/ready/
# claimed MARKERS, FIX 3 only kills active-but-silent reviewers, and stuck_dispatching()
# only fires while the dispatcher is ACTIVELY polling a live run. Meanwhile the Pilot's
# _beadid_has_active_gate_artifact counts dispatching|reviewing as ACTIVE → it DROPS the
# gate:needs-fix source bead as 'already gating' → the bead is orphaned (never re-
# dispatched NOR re-reviewed) until the Mayor re-slings by hand. Recovery = requeue the
# marker (→ gate-status:queued: a fresh dispatcher sweep re-reviews the EXISTING branch,
# no rebuild) + clear the source's leaked gate:reviewing. A live/hung RUN (has_open_run)
# hands off to FIX 1/5 untouched; a per-marker attempt cap escalates to needs-human if
# reviewers keep dying on the same branch. Sustained-confirmed on a resample; fail-safe.
GRW_REAP_STALE_REVIEW_ENABLED = os.environ.get("GRW_REAP_STALE_REVIEW_ENABLED", "1") != "0"
STALE_REVIEW_MARKER_MINUTES = int(os.environ.get("GRW_STALE_REVIEW_MARKER_MINUTES", "15"))  # a marker must sit dispatching|reviewing >this WITH NO open run before requeue — well past a normal spin-up (a run is created within seconds), so an in-flight dispatch is never mistaken for a dead one
STALE_REVIEW_MAX_PER_SWEEP = int(os.environ.get("GRW_STALE_REVIEW_MAX_PER_SWEEP", "5"))
STALE_REVIEW_MAX_ATTEMPTS = int(os.environ.get("GRW_STALE_REVIEW_MAX_ATTEMPTS", "3"))  # after K requeues of the SAME marker (reviewers keep dying on this branch), escalate to needs-human instead of an infinite re-review loop
GRW_STALE_REVIEW_LABEL_RE = re.compile(r"^grw-stale-review:(\d+)$")                 # restart-safe per-marker stale-review requeue counter
# A repair dog's session title (set by the watchdog's --title-hint, and kept by the
# dog after it self-renames because the dog naturally echoes the branch/condition)
# matched broadly so we also catch dogs spawned before this process started (restart
# amnesia) or pre-fix pile-ups. Over-matching is the SAFE direction (more skips).
REPAIR_DOG_TITLE_RE = re.compile(
    r"gate[- ]orphan|gate[- ]watchdog|\bREPAIR\b|\breparo\b|marker stuck|marcador .*travado|"
    r"head[- ]of[- ]line|branch stale|branch travado|pilot trav|pilot .*jam|supervisor init|"
    r"init[- ]failure|init failure|gate stall|gate heartbeat|zero merges|sem revisores",
    re.IGNORECASE)
DOLT_SIG = re.compile(r"connection reset|bead store closed|unexpected EOF|invalid connection|provider-health registry unavailable")
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Dispatcher sweep complete: branch=<X> verdict=QUEUED (retry N/M, dead author) ==="
SWEEP_QUEUED_RETRY_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=QUEUED \(retry")
SWEEP_COMPLETE_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=")
MARKER_BRANCH_RE = re.compile(r"^branch:(.+)$")  # marker label form: branch:crew/<rig>-<name>/<bead>  (gt-mqkwj)
# supervisor init-failure loop (ga-h3w2y): a rig with no `path` in site.toml makes
# the supervisor cycle "init failure #N" / "validate rigs: rig \"X\": path is
# required" and NOTHING spawns town-wide. The supervisor.log lines carry no
# [timestamp] prefix, so freshness is judged by the recent tail + a config cross-
# check (the config is STILL broken now) to avoid firing on stale post-fix tails.
SUP_INIT_FAIL_RE = re.compile(r"init failure #\d+")
SUP_VALIDATE_RIGS_RE = re.compile(r"validate rigs:\s*(.+?)(?:\s+see:|\s*\(skipping\)|$)")
SUP_INIT_FAIL_MIN = 2          # >=2 'init failure #' lines in the recent tail = active loop
RIG_HEADER_RE = re.compile(r"^\s*\[\[\s*rig\s*\]\]\s*$")
RIG_TABLE_RE = re.compile(r"^\s*\[")
RIG_KV_RE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"')


def sh(args, timeout=20, stdin=None):
    try:
        return subprocess.run(args, input=stdin, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def quota_verdict():
    """Ground-truth Claude-quota line for the Mayor's wake-up (ga-wjlv9).

    The 2026-06-10 night was lost diagnosing a gate stall as 'quota exhausted'
    without being able to verify it (it was NOT quota — only 22% used). Every
    wake message below tells the Mayor to go fix the INFRA; lead each one with
    the real quota verdict so the Mayor can rule quota in/out FIRST instead of
    chasing the wrong cause. Fail-safe: any error returns an explicit unknown
    line, never blocks the wake."""
    r = sh([QUOTA_CHECK, "--line"], timeout=18)
    if r is not None and r.returncode in (0, 2):
        line = (r.stdout or "").strip().splitlines()
        if line and line[0].startswith("QUOTA:"):
            tag = "🔴" if r.returncode == 2 else "🟢"
            return "%s %s\n   (fonte: claude-quota-check.sh --line — sinal de verdade do transcript, não chute)\n\n" % (tag, line[0])
    return ("QUOTA: (check indisponível — rode `%s` manualmente p/ confirmar antes de assumir cota)\n\n"
            % QUOTA_CHECK)


def log_ts_epoch(line):
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        # dispatcher log is local time (UTC-3); compare via naive local epoch
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


_SYSCTL_SEC_RE = re.compile(r" sec = (\d+)")  # leading space anchors the `sec` field, not `usec`'s


def secs_since_avail(now):
    """Seconds the machine has been awake-and-up since it last became available,
    i.e. now - max(boot_epoch, wake_epoch). Ports daemon-presence-watchdog.sh's
    _secs_since_avail (ga-m1o5) so the Pilot-silence stall check gets the same
    sleep/wake grace its heartbeat-WEDGE check already has: while asleep, launchd
    suspends every StartInterval timer (Pilot's included), so a stale pilot log
    proves nothing about Pilot's health until the machine has been up at least as
    long as the stall threshold. Returns None if neither sysctl parses (caller
    must fail OPEN — no grace, not a false 'never stalls' suppression)."""
    latest = 0
    for key in ("kern.boottime", "kern.waketime"):
        r = sh(["sysctl", "-n", key], timeout=5)
        if r is None or r.returncode != 0:
            continue
        m = _SYSCTL_SEC_RE.search(r.stdout or "")
        if m:
            v = int(m.group(1))
            if v > latest:
                latest = v
    return (now - latest) if latest > 0 else None


def recent_timeouts():
    """count of 'Gate FAILED: TIMEOUT' in dispatcher log within TIMEOUT_WINDOW_SEC."""
    try:
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-4000:]
    except Exception:
        return 0, None
    now = time.time()
    hits = []
    for l in lines:
        if "Gate FAILED: TIMEOUT" in l:
            e = log_ts_epoch(l)
            if e and now - e < TIMEOUT_WINDOW_SEC:
                hits.append(e)
    return len(hits), (max(hits) if hits else None)


def last_pass_epoch():
    try:
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-4000:]
    except Exception:
        return 0
    for l in reversed(lines):
        if "Gate PASSED:" in l:
            return log_ts_epoch(l) or 0
    return 0


def stuck_dispatching():
    """True only if the dispatcher is ACTIVELY polling a run that is stuck: the most
    recent dispatcher-log line is a 'Verdicts: 0/N (elapsed: Y)' with Y past threshold,
    the log is fresh (dispatcher still polling, not moved on / between runs), AND no
    gate-reviewer session is active. Keying on the LIVE poll (not a marker label) means a
    stranded 'gate-status:dispatching' marker — e.g. left by a killed dispatcher during
    maintenance — does NOT false-fire. A slow-but-working run (reviewers still active) is
    also not flagged here; the consecutive-TIMEOUT signal covers alive-but-not-delivering."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > 120:
            return False  # dispatcher not actively writing → between runs (ENGINE-STALL covers dead)
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-15:]
    except Exception:
        return False
    vm = None
    for l in reversed(lines):
        if "sweep complete" in l:   # the most recent run already concluded → not stuck
            return False
        mm = re.search(r"Verdicts:\s*(\d+)/(\d+)\s*received\s*\(elapsed:\s*(\d+)s\)", l)
        if mm:
            vm = mm
            break
    if not vm:
        return False
    got, elapsed = int(vm.group(1)), int(vm.group(3))
    if not (got == 0 and elapsed > DISPATCH_STUCK_SEC):
        return False
    # corroborate: reviewers spawned for this run are NOT active (dead/start-pending)
    rs = sh(["gc", "session", "list", "--json"])
    try:
        sessions = json.loads(rs.stdout).get("sessions", []) if rs else []
    except Exception:
        return False
    active = [s for s in sessions if s.get("template") == "gate-reviewer" and s.get("state") == "active"]
    return len(active) == 0


def gate_infra_throttled():
    """True if the gate dispatcher is ALIVE but currently DEFERRING on INFRA
    (Dolt-CPU hot or quota), i.e. throttled — NOT wedged. A repair dog cannot
    lower Dolt CPU or restore quota, so the gate-repair detectors (gate:down,
    head-of-line, orphan) must NOT fire while this is true — that is the source
    of the futile 'taskless' dogs (ga-htjni follow-up / dog investigation
    2026-06-15). Requires a FRESH log: a dead/wedged dispatcher has a stale log
    → returns False → ENGINE-STALL / gate:down still fire (a real wedge is never
    masked). Reads the most-recent headroom decision: a fresh 'Headroom OK' or
    'sweep complete' seen first means the gate is admitting/progressing → False."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > 180:
            return False  # stale log → not actively throttling; let other detectors judge
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-25:]
    except Exception:
        return False
    for l in reversed(lines):
        if "Headroom OK" in l or "sweep complete" in l:
            return False  # most recent decision = admitting / concluded → not throttled now
        if "Headroom DEFER" in l and ("dolt-hot" in l or "quota-limited" in l or "cota=LIMITED" in l):
            return True
    return False


def headofline_stall():
    """Detect the stale-branch FIFO head-of-line block (ga-hl0gq).

    The dispatcher picks the oldest queued marker every sweep; if that branch is
    stale vs origin/main and its auto-rebase conflicts with a dead/empty author,
    the marker is re-queued gate-status:queued and the SAME branch is re-picked
    next sweep — the queue behind it never drains (zero merges). The dispatcher
    keeps logging (no ENGINE-STALL) and no run reaches verdicts (no TIMEOUT, no
    'Verdicts 0/N' poll line), so recent_timeouts()/stuck_dispatching() are blind.

    Signature: walking the dispatcher log's 'sweep complete' lines from newest to
    oldest, the trailing run names the SAME branch with 'verdict=QUEUED (retry'.
    Returns (branch, count) when count >= HEADOFLINE_MIN_SWEEPS, else (None, 0).
    Requires a fresh log (dispatcher actively sweeping) — a stale log is dead-
    engine territory, covered by the health-monitor's ENGINE-STALL."""
    try:
        if time.time() - os.path.getmtime(DISPATCH_LOG) > HEADOFLINE_LOG_FRESH_SEC:
            return (None, 0)
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-400:]
    except Exception:
        return (None, 0)
    branch = None
    count = 0
    for l in reversed(lines):
        if "Dispatcher sweep complete:" not in l:
            continue
        mq = SWEEP_QUEUED_RETRY_RE.search(l)
        if not mq:
            # most-recent completion is NOT a QUEUED-retry (a real PASS/FAIL/merge
            # happened, or a different terminal verdict) → not stalled right now.
            break
        b = mq.group(1)
        if branch is None:
            branch = b
        if b != branch:
            break  # head-of-line moved to a different branch → not a single-branch wedge
        count += 1
    if branch and count >= HEADOFLINE_MIN_SWEEPS:
        return (branch, count)
    return (None, 0)


def _iso_epoch(s):
    """Parse a bd ISO-8601 UTC timestamp ('2026-06-12T23:09:12Z') to a true Unix
    epoch, comparable with log_ts_epoch() (which returns the true epoch of a
    LOCAL dispatcher-log timestamp). Both are absolute Unix epochs, so they
    compare directly across the timezone difference. Returns None on failure."""
    if not s:
        return None
    try:
        dt = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ")
        return dt.replace(tzinfo=datetime.timezone.utc).timestamp()
    except Exception:
        return None


def _last_active_epoch(s):
    """Parse a `gc session list --json` last_active to a true Unix epoch. Unlike bd's
    UTC-'Z' timestamps (handled by _iso_epoch), session last_active carries a tz OFFSET
    ('2026-07-02T16:06:29-03:00') — fromisoformat handles both. Returns None on
    empty/unparseable (fail-safe: a session we cannot age is NEVER treated as frozen)."""
    if not s:
        return None
    try:
        t = s.strip()
        if t.endswith("Z"):
            t = t[:-1] + "+00:00"
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt.timestamp()
    except Exception:
        return None


def frozen_reviewer_verdict(state, silence_sec, threshold_sec):
    """PURE decision (no I/O, set -e safe, unit-tested) for FIX 3. 'kill' iff the
    reviewer session is state=active AND has been silent (no last_active refresh) for
    >= threshold; else 'keep'. Fail-safe toward KEEP: a non-active state (the hung-run
    reaper / dispatcher own it), or a None/negative silence (unparseable/future
    last_active) never kills."""
    if str(state or "").lower() != "active":
        return "keep"
    if silence_sec is None or silence_sec < 0:
        return "keep"
    return "kill" if silence_sec >= threshold_sec else "keep"


def _queued_markers():
    """[(id, branch, created_epoch), ...] for every gate-status:queued marker.
    Returns [] on any error (fail-safe: no markers → no orphan fire)."""
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
            "-l", "gate-status:queued", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return []
    try:
        rows = json.loads(r.stdout)
    except Exception:
        return []
    out = []
    for row in rows or []:
        branch = None
        for lb in (row.get("labels") or []):
            m = MARKER_BRANCH_RE.match(lb)
            if m:
                branch = m.group(1)
                break
        out.append((row.get("id"), branch, _iso_epoch(row.get("created_at"))))
    return out


def _dispatcher_log_state(tail=3000):
    """(sweep_complete_epochs, log_text, log_fresh) for the dispatcher log.

    sweep_complete_epochs: every 'sweep complete' timestamp in the tail (used to
      judge whether the dispatcher is actively DRAINING vs wedged on one run).
    log_text: the joined tail (scanned for branch mentions — substring match).
    log_fresh: the log file was written within ORPHAN_LOG_FRESH_SEC (process alive)."""
    try:
        fresh = time.time() - os.path.getmtime(DISPATCH_LOG) <= ORPHAN_LOG_FRESH_SEC
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-tail:]
    except Exception:
        return ([], "", False)
    epochs = []
    for l in lines:
        if "sweep complete" in l:
            e = log_ts_epoch(l)
            if e:
                epochs.append(e)
    return (epochs, "".join(lines), fresh)


def _detect_orphan_markers(markers, sweep_epochs, log_text, now):
    """Pure core of orphaned_queued_marker() (separated for the selftest).

    Returns the orphaned queued markers as [(id, branch, age_sec), ...], oldest
    first. A marker is an orphan when ALL hold:
      (drain) the dispatcher is actively draining — the newest 'sweep complete'
              is within ORPHAN_DRAIN_FRESH_SEC. If the last completed sweep is
              stale, the dispatcher is wedged on its CURRENT run (a different
              failure mode: timeout / drained-reviewer / engine-stall), not
              leapfrogging — so we stay silent.
      (a)     the marker has sat queued >= ORPHAN_MIN_AGE_SEC (not just created).
      (b)     its branch is NEVER mentioned in the recent dispatcher log (zero
              dispatch attempts — its gate_run was dropped during the outage).
      (d)     a strictly-NEWER queued marker's branch IS mentioned — PROOF the
              dispatcher leapfrogged this older one. This is the guard that
              distinguishes a true orphan from a normal FIFO backlog stuck behind
              a slow run: in a healthy backlog the OLDEST unmentioned marker is
              simply next-up and no newer marker is being worked ahead of it.
      (head)  ONLY the FIFO-oldest queued marker is eligible. A non-head marker is
              by definition FIFO-blocked behind an older one (the dispatcher takes
              one marker per sweep, oldest-first) — NOT orphaned. This is the guard
              that kills the recurring false positive (wa-68su / ga-te7es: a #2
              marker flagged 'orphan' while the OLDER head was being actively gated
              or yielding to a live sibling run; refs
              [[gate-orphan-watchdog-false-positive-headofline-block]],
              [[ga-te7es-gate-orphan-falsepos-sibling-headofline]]). A true
              gt-mqkwj orphan (its gate_run dropped in an outage) is always the
              oldest still-queued marker, so this loses no real detection."""
    if not sweep_epochs:
        return []
    if now - max(sweep_epochs) > ORPHAN_DRAIN_FRESH_SEC:
        return []  # dispatcher not actively draining → not this failure mode
    valid = [(mid, b, c) for (mid, b, c) in markers if mid and b and c]
    valid.sort(key=lambda m: m[2])  # oldest first
    if not valid:
        return []
    # (head) only the FIFO-oldest queued marker can be an orphan; everything newer
    # is FIFO-blocked behind it, not skipped. Evaluating only valid[0] is what
    # suppresses the head-of-line false positive that drove the 6x-same-marker loop.
    mid, branch, created = valid[0]
    if now - created < ORPHAN_MIN_AGE_SEC:
        return []
    if branch in log_text:
        return []  # head mentioned → being / already dispatched (or actively gated), not orphaned
    leapfrogged = any(c2 > created and b2 != branch and b2 in log_text
                      for (_m2, b2, c2) in valid)
    if not leapfrogged:
        return []
    return [(mid, branch, int(now - created))]


def orphaned_queued_marker():
    """Detect a gate-status:queued marker whose gate_run was dropped during a
    dispatcher outage and is now being leapfrogged (gt-mqkwj). Returns
    (marker_id, branch, age_sec) for the OLDEST orphan, else (None, None, 0).
    Fail-safe: any gather error returns no orphan (never wakes spuriously)."""
    sweep_epochs, log_text, log_fresh = _dispatcher_log_state()
    if not log_fresh or not sweep_epochs:
        return (None, None, 0)  # log not live → dead engine, ENGINE-STALL's job
    orphans = _detect_orphan_markers(_queued_markers(), sweep_epochs, log_text, time.time())
    if not orphans:
        return (None, None, 0)
    orphans.sort(key=lambda o: o[2], reverse=True)  # oldest (largest age) first
    return orphans[0]


def dolt_instability():
    """count of Dolt-instability signature lines in the tail of the supervisor log."""
    try:
        with open(SUPERVISOR_LOG) as f:
            try:
                f.seek(0, os.SEEK_END)
                size = f.tell()
                f.seek(max(0, size - 200000))
            except Exception:
                pass
            tail = f.read()
    except Exception:
        return 0
    return len(DOLT_SIG.findall(tail))


def _rig_paths_invalid():
    """Return a short description of site.toml rig-path problems, or "" if valid.

    Self-contained zero-dependency parse (no tomllib) so this works on the
    plist's /usr/bin/python3. Mirrors the engine's `ValidateRigs` ("path is
    required") plus a path-exists check. Used to cross-check the supervisor
    init-failure tail: we only treat the loop as actionable while the config is
    STILL broken — when the Mayor restores the path, this returns "" and the
    signal clears (recovery)."""
    rigs = []
    cur = None
    try:
        with open(SITE_TOML, errors="replace") as f:
            for line in f:
                if RIG_HEADER_RE.match(line):
                    if cur is not None:
                        rigs.append(cur)
                    cur = {"name": None, "path": None, "has_path": False}
                    continue
                if RIG_TABLE_RE.match(line):
                    if cur is not None:
                        rigs.append(cur)
                    cur = None
                    continue
                if cur is None:
                    continue
                m = RIG_KV_RE.match(line)
                if m:
                    if m.group(1) == "name":
                        cur["name"] = m.group(2)
                    elif m.group(1) == "path":
                        cur["path"] = m.group(2)
                        cur["has_path"] = True
        if cur is not None:
            rigs.append(cur)
    except Exception:
        return ""  # unreadable config → don't fire (avoid false positive)
    probs = []
    for r in rigs:
        name = r.get("name") or "(unnamed)"
        p = r.get("path")
        if not r.get("has_path") or not p:
            probs.append("%s: sem path" % name)
        elif not os.path.isdir(p):
            probs.append("%s: path inexistente (%s)" % (name, p))
    return "; ".join(probs)


def supervisor_init_failure():
    """Detect the ga-h3w2y spawn-outage: the supervisor cycling on init-failure
    because a rig lacks a `path` in site.toml. Returns (reason, detail) when the
    recent supervisor.log tail shows the loop AND the config is STILL invalid
    now; else (None, ""). The config cross-check is what keeps a stale post-fix
    tail (or a non-config init failure already handled elsewhere) from firing."""
    try:
        with open(SUPERVISOR_LOG, errors="replace") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - 200000))
            lines = f.read().splitlines()[-400:]
    except Exception:
        return (None, "")
    fails = sum(1 for l in lines if SUP_INIT_FAIL_RE.search(l))
    if fails < SUP_INIT_FAIL_MIN:
        return (None, "")
    invalid = _rig_paths_invalid()
    if not invalid:
        return (None, "")  # loop in tail but config valid now → resolved / not config
    verr = ""
    for l in reversed(lines):
        m = SUP_VALIDATE_RIGS_RE.search(l)
        if m:
            verr = m.group(1).strip()
            break
    return ("supervisor init-failure loop (%s)" % (verr or "validate rigs"), invalid)


def mayor_session():
    rs = sh(["gc", "session", "list", "--json"])
    if not rs or rs.returncode != 0:
        return None
    try:
        for s in json.loads(rs.stdout).get("sessions", []):
            if s.get("template") == "gastown.mayor":
                return s.get("id")
    except Exception:
        return None
    return None


def pilot_stall_verdict(silence_sec, avail_age_sec, threshold_sec, wake_grace=True):
    """PURE decision (no I/O, unit-tested) for the pilot-log-silence half of
    pilot_jammed(). True iff the pilot log has been silent >= threshold_sec AND
    that silence is NOT fully explained by the machine having just woken/booted.
    A wake/boot less than threshold_sec ago (avail_age_sec < threshold_sec) means
    the log could not possibly have advanced yet regardless of Pilot's health —
    suppress (False). avail_age_sec is None (neither sysctl parsed) fails OPEN:
    no grace, judge on silence alone — same fail-safe direction as the other
    *_verdict helpers in this file, just inverted (missing data must never mask
    a real stall)."""
    if silence_sec is None or silence_sec <= threshold_sec:
        return False
    if wake_grace and avail_age_sec is not None and avail_age_sec < threshold_sec:
        return False
    return True


def pilot_jammed():
    """(jammed, reason). Detects the Pilot failing to dispatch — the gap that left a
    jam undetected for ~8h on 2026-06-08. Two modes:
      (a) sweep-abort: 2+ 'aborting dispatch' / 'gc sling failed' lines in the pilot log
          within PILOT_JAM_WINDOW (one bad bead — e.g. accented title — jams every sweep).
      (b) stall: pilot log silent > PILOT_STALL_SEC (Pilot dead / not sweeping), unless
          a machine sleep/wake fully explains the silence (ga-m1o5 — see
          pilot_stall_verdict / secs_since_avail)."""
    try:
        mtime = os.path.getmtime(PILOT_LOG)
    except Exception:
        return (False, "")
    now = time.time()
    if pilot_stall_verdict(now - mtime, secs_since_avail(now), PILOT_STALL_SEC, GRW_WAKE_GRACE):
        return (True, "Pilot parou de varrer (log silencioso >%dmin) — pode estar morto" % (PILOT_STALL_SEC // 60))
    try:
        with open(PILOT_LOG) as f:
            lines = f.readlines()[-80:]
    except Exception:
        return (False, "")
    aborts = 0
    for l in lines:
        if ("aborting dispatch" in l) or ("gc sling failed" in l):
            e = log_ts_epoch(l)
            if e and now - e < PILOT_JAM_WINDOW_SEC:
                aborts += 1
    if aborts >= 2:
        return (True, "Pilot abortou a varredura %dx em %dmin (gc sling falhou num bead) — nao despacha"
                % (aborts, PILOT_JAM_WINDOW_SEC // 60))
    return (False, "")


def snapshot(reason, dolt_hits):
    ts = time.strftime("%Y%m%d-%H%M%S")
    path = "/tmp/gate-watchdog-diag-%s.txt" % ts
    try:
        with open(path, "w") as f:
            f.write("GATE WATCHDOG DIAGNOSTIC %s\nreason: %s\ndolt_instability_lines: %d\n\n"
                    % (ts, reason, dolt_hits))
            for title, args in [
                ("queued markers", ["bd", "-C", CITY, "list", "--all", "-l",
                                    "type:quality-gate-marker", "-l", "gate-status:queued", "--json"]),
                ("dispatching markers", ["bd", "-C", CITY, "list", "--all", "-l",
                                         "type:quality-gate-marker", "-l", "gate-status:dispatching", "--json"]),
                ("sessions", ["gc", "session", "list"]),
            ]:
                r = sh(args)
                f.write("== %s ==\n%s\n\n" % (title, (r.stdout if r else "(failed)")))
            r = sh(["tail", "-30", SUPERVISOR_LOG], timeout=10)
            f.write("== supervisor.log tail ==\n%s\n" % (r.stdout if r else "(failed)"))
            r = sh(["tail", "-20", DISPATCH_LOG], timeout=10)
            f.write("== dispatcher.log tail ==\n%s\n" % (r.stdout if r else "(failed)"))
    except Exception:
        pass
    return path


# Prepended to the runbook when it is handed to a freshly-spawned repair dog so it
# knows the bead IS its task (not a formula to look up) and how to close out cleanly.
REPAIR_HEADER = (
    "🔧 TAREFA DE REPARO AUTÔNOMO — despachada automaticamente pelo gate-recovery-watchdog.\n"
    "Você é o agente de reparo dedicado deste incidente. NÃO procure uma fórmula: a sua "
    "tarefa é executar o RUNBOOK abaixo do início ao fim, verificando entre os passos. "
    "Trabalhe sozinho e com autonomia — o Mayor pode estar dormindo, NÃO dependa dele. "
    "Sequência: (1) colete o diagnóstico (já há um snapshot no caminho citado abaixo; "
    "aprofunde com os greps do runbook), (2) rode o runbook, (3) se RESOLVER, avise via "
    "`notify -p 3 'gate recuperado'`, (4) se NÃO conseguir, escale pro humano com "
    "`notify 🚨 -p 5` E mande mail pro Mayor com o diagnóstico. Ao terminar (resolvido OU "
    "escalado), feche este bead (`gc bd close <id> --reason ...`) e saia "
    "(`gc runtime drain-ack && exit`).\n\n"
    "========== RUNBOOK ==========\n"
)


def repair_runbook(reason, diag_path, dolt_hits, kind="gate"):
    """The per-kind recovery runbook text. Shared by spawn_repair_agent() (as the
    repair bead's description) and wake_mayor() (as the fallback nudge body) so the
    instructions never drift between the two paths."""
    if kind == "pilot":
        return (
            "O Pilot parou de despachar trabalho. Motivo detectado: %s.\nDiagnóstico já coletado em: %s\n\n"
            "Causa-raiz mais provável (lição de 2026-06-08): o `gc sling` rejeita títulos com acento/travessão "
            "('Incorrect string value \\xC3 for column title') e o Pilot ABORTA a varredura inteira por causa de "
            "um bead ruim → não despacha nada. Veja a memória [[post-outage-remaining-tech-debt]] item 6.\n\n"
            "CONSERTO (verificando entre os passos):\n"
            "1. tail -20 .gc/logs/pilot-dispatcher.log → ache 'gc sling failed for <bead> — aborting dispatch'.\n"
            "2. Se for charset: bd -C . update <bead-culpado> --title '<versão SEM acento/travessão>' (de-acentue).\n"
            "3. Se o log estiver silencioso (Pilot morto): launchctl kickstart -k gui/$(id -u)/com.gascity.pilot.\n"
            "4. Dispare: launchctl kickstart gui/$(id -u)/com.gascity.pilot ; confirme 'dispatched=N' (N>0) na próxima varredura.\n\n"
            "Se destravar, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir destravar."
        ) % (reason, diag_path)
    if kind == "gate-loop":
        return (
            "O gate está preso no MESMO branch stale há vários sweeps: %s. "
            "O auto-rebase bate em conflito (autor morto/ausente), o marker re-enfileira gate-status:queued, "
            "e a FILA INTEIRA atrás dele NÃO drena — zero merges. Foi exatamente o stall de 49min de 2026-06-10 (ga-hl0gq).\n\n"
            "CONSERTO (re-anchor OU supersede — memória [[gate-rebase-error-stale-branch]]):\n"
            "1. Ache o marker do branch travado:\n"
            "   bd -C . list --all -l type:quality-gate-marker -l gate-status:queued --json | "
            "jq -r '.[] | select((.labels//[])[]|contains(\"branch:%s\")) | .id'\n"
            "2. DECIDA o caminho:\n"
            "   (a) Branch ainda quer mergear → RE-ANCHOR: num worktree em origin/main, cherry-pick o commit do branch, "
            "keep-both em conflito de teste, verifique diff additivo (0 deleções), force-push sobre o branch stale, e RE-QUEUE o MESMO marker "
            "(remove gate-status:error/queued antigo, add gate-status:queued) — NÃO duplique.\n"
            "   (b) Branch é zombie/obsoleto → SUPERSEDE: set_gate_status do marker p/ superseded + close, e re-despache fresh se a história ainda vale.\n"
            "3. O objetivo imediato é TIRAR o branch quebrado da cabeça da fila pra os markers saudáveis atrás dele drenarem JÁ.\n"
            "4. Confirme: nos próximos sweeps aparecem 'Gate PASSED' / outros branches avançando (não só QUEUED-retry no mesmo branch).\n\n"
            "Diagnóstico salvo em: %s\n"
            "Se destravar, avise (notify -p 4). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir.\n"
            "(Fix permanente do auto-skip no dispatcher = ga-q3ig2 — este reparo é a ponte de detecção+recuperação até ele aterrissar. "
            "Cuidado: o contador gate:rebase-attempt reseta a 0 todo sweep, então o escape de 3-strikes do dispatcher nunca dispara — por isso loopa pra sempre.)"
        ) % (reason, reason, diag_path)
    if kind == "supervisor":
        return (
            "O supervisor está ciclando em init-failure: %s. Config inválido detectado em site.toml: %s.\n"
            "Diagnóstico: %s\n\n"
            "Causa-raiz (incidente ga-h3w2y de 2026-06-10): um rig sem `path` no .gc/site.toml (esquecido numa "
            "migração city.toml→site.toml) faz o supervisor falhar `validate rigs: rig \"X\": path is required` "
            "e entrar em loop → NADA spawna town-wide (gate-reviewers + dogs presos em start-pending). "
            "Achar isso à mão custou ~1h; quota/Dolt/bd-hooks foram pistas FALSAS.\n\n"
            "CONSERTO (verificando entre os passos):\n"
            "1. Confirme o rig culpado: `gc doctor --json | jq '.checks[] | select(.name==\"config-valid\")'` "
            "ou `grep 'validate rigs' ~/.gc/supervisor.log | tail`.\n"
            "2. Restaure o `path` do rig em .gc/site.toml — cada `[[rig]]` precisa de `name=` E "
            "`path=\"/Users/athos/gt/<rig>\"` (o path TEM que existir no disco). NÃO invente; use o diretório canônico.\n"
            "3. Re-valide com `gc doctor` (check config-valid verde) e dispare o supervisor: "
            "`launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor`.\n"
            "4. Confirme: as sessões voltam a spawnar (saem de start-pending). "
            "(O supervisor-config-guard já tenta `gc doctor --fix` sozinho; se a config exige um path que só você "
            "sabe, este wake é pra você restaurá-lo.)\n"
        ) % (reason, dolt_hits, diag_path)
    if kind == "gate-orphan":
        # `reason` carries the orphan branch; `dolt_hits` carries the marker id.
        return (
            "Um marker gate-status:queued ÓRFÃO foi detectado: branch %s (marker %s). "
            "O gate_run dele foi DERRUBADO durante uma janela de outage do dispatcher (um buraco "
            "sem linhas 'sweep complete' no log), então na recuperação o dispatcher PULA esse marker "
            "antigo e despacha os mais novos — ele nunca roda, o bead de origem fica in_progress pra "
            "SEMPRE, e o reconciler re-spawna worker em cima de trabalho já feito ~6x (incidente gt-mqkwj, "
            "irmão de [[ga-hl0gq-gate-stall-detection-fix]]).\n\n"
            "DIAGNÓSTICO (confirme que É órfão antes de agir):\n"
            "1. Veja o marker: `bd -C . show %s --json | jq '.[0]|{id,status,created_at,labels}'` "
            "(deve estar gate-status:queued, antigo, com source-bead:<X>).\n"
            "2. Confirme ZERO menções do branch no log: "
            "`grep -c '%s' .gc/logs/quality-gate-dispatcher.log` → se 0, o dispatcher nunca tentou despachá-lo.\n"
            "3. Confirme que o dispatcher está DRENANDO outros branches (há 'sweep complete' recente p/ branches "
            "DIFERENTES) — senão NÃO é órfão, é o run atual travado (outro modo de falha; não mexa).\n\n"
            "CONSERTO — DECIDA pelo estado do branch:\n"
            "  (a) Branch AINDA quer mergear (código não landou): RE-QUEUE o MESMO marker p/ o dispatcher "
            "redespachá-lo com um run fresco — remova e re-adicione gate-status:queued "
            "(`bd -C . update %s --remove-label gate-status:queued && bd -C . update %s --add-label gate-status:queued`) "
            "pra refrescar o created_at e tirá-lo da cabeça órfã da fila. NÃO duplique o marker. "
            "Confirme no próximo sweep que o branch aparece sendo despachado.\n"
            "  (b) Branch JÁ mergeou / é zumbi (código já está em origin/main): SUPERSEDE — feche o marker "
            "(`bd -C . close %s --reason 'orphan run dropped; work already landed (gt-mqkwj)'`) E feche o "
            "source-bead in_progress (veja o label source-bead:<X> do marker; `bd -C . close <X> --reason "
            "'merged; orphan marker superseded (gt-mqkwj)'`) pra PARAR o reconciler de re-spawnar worker.\n"
            "3. O objetivo é tirar o marker órfão do limbo: ou ele roda (re-queue) ou some (supersede+close) — "
            "em ambos os casos o bead de origem deixa de ficar preso in_progress.\n\n"
            "Diagnóstico salvo em: %s\n"
            "Se resolver, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir.\n"
            "(Fix permanente seria o dispatcher detectar markers sem gate_run e re-criar o run — esta detecção+reparo "
            "é a ponte até lá.)"
        ) % (reason, dolt_hits, dolt_hits, reason, dolt_hits, dolt_hits, dolt_hits, diag_path)
    return (
        "O gate parou de produzir vereditos. Motivo detectado: %s. "
        "Linhas de instabilidade do Dolt no supervisor.log: %d.\n"
        "Diagnóstico já coletado em: %s\n\n"
        "Causa-raiz mais provável (lição de 2026-06-07): instabilidade de conexão do Dolt da cidade (:52756) "
        "→ supervisor não computa a demanda de gate-reviewer → revisores nascem e morrem (start-pending) → "
        "todo run dá TIMEOUT. Rode o diagnostic ladder COMPLETO da memória [[gate-reviewer-spawn-failure-playbook]].\n\n"
        "CONSERTO (na ordem, verificando entre os passos):\n"
        "0. COTA PRIMEIRO (lição de 2026-06-10, ga-wjlv9): rode `scripts/claude-quota-check.sh --line` (ou --json). "
        "Se disser LIMITED, É cota — espere o reset, NÃO persiga infra (a noite de 2026-06-10 foi perdida diagnosticando "
        "um stall como cota sem poder confirmar — e NÃO era cota). Se 'not limited', NÃO é cota → siga pros passos de infra abaixo.\n"
        "1. Colete diagnóstico: grep -E 'connection reset|bead store closed|invalid connection' ~/.gc/supervisor.log | tail\n"
        "2. Reviewer congelado/boot-wedged? `gc session list | grep gate-reviewer` — se algum está start-pending/asleep "
        "segurando o slot, mate-o (`gc session kill <id>`) e deixe o dispatcher re-convocá-lo; veja [[ga-mepb0]] (re-convene + stagger spawns).\n"
        "3. Menos invasivo: launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor ; espere 30s ; "
        "dispare um gate run (launchctl kickstart gui/$(id -u)/com.gascity.quality-gate-dispatcher) e veja se os "
        "revisores ficam 'active' e os vereditos sobem.\n"
        "4. Ainda quebrado? Cheque rig-path/hooks/binário (passos 1-3 do ladder da memória acima) e então "
        "gc dolt restart (da pasta da cidade) — preserva dados, bd volta na hora — depois kickstart do supervisor de novo, e re-verifique um run.\n"
        "5. Confirme com um run REAL passando ponta-a-ponta (3/3 vereditos → PASS). "
        "Sondas ad-hoc (gc session new sem tarefa) saem sozinhas, não servem de teste.\n\n"
        "Se recuperar, avise (notify -p 3). Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir recuperar."
    ) % (reason, dolt_hits, diag_path)


def spawn_repair_agent(reason, diag_path, dolt_hits, kind="gate"):
    """PRIMARY recovery action (ga-afytf): dispatch a dedicated autonomous repair
    agent that runs the runbook itself, instead of depending on the Mayor being
    awake. GUARANTEES that some actor is engaged and returns a short status string
    for the operator notification. Never raises — every external call is guarded.

    Recovery ladder:
      1. Route a DURABLE repair task bead to the dog pool (`gc sling --stdin`:
         first line = title, rest = the runbook the dog executes).
      2. DIRECTLY spawn a repair dog (`gc session new --no-attach`) so recovery does
         not wait on the demand-reconciler — which the gate-down failure mode (Dolt
         instability → supervisor can't compute pool demand) can itself wedge. A
         racing reconciler-spawned dog simply finds no work and exits (claims atomic).
      3. If a worker could NOT be directly materialized, WAKE THE MAYOR as the
         human-judgment fallback. Otherwise a routed-but-unworked bead would sit idle
         behind a wedged reconciler in exactly the failure mode this targets. (The
         earlier version returned on sling-success alone and DISCARDED the direct
         spawn's result, so a failed insurance spawn went unnoticed and the Mayor
         fallback never fired — the gate could stay down with no actor at all.)

    The sling title is kept ASCII — rich/emoji detail lives in the body — because the
    `title` column has rejected non-ASCII before (the Pilot charset abort that aborts
    a whole dispatch sweep; the description body carries no such constraint).

    Returns (status_str, session_id_or_None). The session_id lets the caller record
    the spawned dog in the governor ledger so a follow-up detection for the SAME
    condition dedups against THIS dog instead of spawning a sibling (the 6x-same-
    marker root). When REPAIR_DUAL_SPAWN is off (default) the durable sling bead is
    only routed if the direct spawn FAILED — so a healthy spawn produces ONE dog,
    not two, halving the load this watchdog adds."""
    safe_reason = reason.encode("ascii", "replace").decode("ascii")
    title = "REPAIR gate-watchdog (%s): %s" % (kind, safe_reason)
    payload = title + "\n\n" + REPAIR_HEADER + repair_runbook(reason, diag_path, dolt_hits, kind)

    def _sling():
        r = sh(["gc", "sling", DOG_TEMPLATE, "--stdin", "--json"], stdin=payload, timeout=45)
        return r is not None and r.returncode == 0

    def _direct():
        # ga-0bigf ROOT FIX: a dog spawned via `gc session new` carries ONLY a
        # title hint — NO bead is routed to it, and `gc session new` sets
        # GC_SESSION_ORIGIN=manual, so the dog's Step-1c routed-pool probe is a
        # no-op (the dog peeks confirm: "Routed pool work (1c): skipped — origin=
        # manual"). Step 1a/1b find nothing either, because nothing was assigned to
        # the session. Result: the repair dog boots TASKLESS with an empty hook and
        # sits idle (the exact ga-0bigf complaint), while the real mission lived only
        # in the _sling() payload that — with REPAIR_DUAL_SPAWN off (default) — was
        # never routed because _direct() "succeeded".
        #
        # The three spawners that DO deliver reliably (gate-reviewer, refino-gate
        # reviewer, auto-refiner) all wire the ga-67hae DURABLE-PULL channel after
        # `gc session new`: capture the new session_name, create a task bead, assign
        # it to that session_name (status in_progress) and embed the task as a
        # comment. Step 1a/1b match `assignee` against $GC_SESSION_NAME/$GC_ALIAS and
        # are NOT origin-gated, so a manual-origin session pulls the work durably.
        # Mirror that here: spawn → create durable repair bead → assign to the
        # session_name + embed the runbook. The dog now boots WITH its mission.
        s = sh(["gc", "session", "new", DOG_TEMPLATE, "--no-attach", "--json",
                "--title-hint", "reparo %s: %s" % (kind, safe_reason[:50])], timeout=45)
        if not s or s.returncode != 0:
            return (False, None)
        sid = None
        sname = None
        try:
            j = json.loads(s.stdout) or {}
            sid = j.get("session_id")
            # `gc session new --json` returns session_name; fall back to alias/agent_name.
            sname = j.get("session_name") or j.get("alias") or j.get("agent_name")
        except Exception:
            sid = None
            sname = None
        # ga-0bigf durable-pull wiring: without a session_name we cannot assign the
        # task, so the dog would boot taskless — treat that as a FAILED direct spawn
        # so the caller falls through to _sling() (durable routed bead) + Mayor
        # fallback rather than leaving an idle dog. The spawned session is harmless:
        # finding no work, a dog drain-acks/exits (or, manual-origin, sits idle
        # briefly until reaped) — far better than the silent taskless-forever state.
        if not sname:
            return (False, sid)
        # Create the durable repair bead and assign it to THIS session so the dog's
        # Step 1a/1b deliver it. The runbook is large, so pass the description via
        # --stdin (NOT argv) to dodge arg-length limits and quoting. `bd create` has
        # no --status flag (this bd version), so set in_progress in a follow-up
        # `bd update` — exactly what the gate/refino/auto-refino spawners do. Best-
        # effort + guarded: if the CREATE fails we report the spawn as un-delivered
        # (False) so the caller routes the _sling() insurance bead + Mayor fallback;
        # the in_progress update is non-fatal (an assigned `open` bead is still found
        # by Step 1b — status only affects Step 1a).
        body = REPAIR_HEADER + repair_runbook(reason, diag_path, dolt_hits, kind)
        cr = sh(["bd", "-C", CITY, "create", title, "-t", "task",
                 "--assignee", sname, "--stdin", "--json"], stdin=body, timeout=45)
        if not cr or cr.returncode != 0:
            return (False, sid)
        repair_bead_id = None
        try:
            cj = json.loads(cr.stdout)
            repair_bead_id = (cj[0] if isinstance(cj, list) and cj else cj).get("id")
        except Exception:
            repair_bead_id = None
        if repair_bead_id:
            # in_progress + (re)assert assignee so Step 1a (assigned in-progress) is
            # the dog's first hit, mirroring the verdict-bead durable-pull wiring.
            sh(["bd", "-C", CITY, "update", repair_bead_id,
                "--assignee", sname, "--status", "in_progress", "-q"], timeout=30)
        return (True, sid)

    routed = False
    if REPAIR_DUAL_SPAWN:
        routed = _sling()   # legacy: always route a durable bead first
    materialized, sid = _direct()
    if materialized:
        return ("agente de reparo despachado" + ("" if (routed or not REPAIR_DUAL_SPAWN) else " (aviso: bead nao enfileirou)"), sid)
    # No worker materialized directly — route the durable bead now (insurance) and do
    # NOT trust a possibly-wedged reconciler to pick it up: wake the Mayor as fallback.
    if not routed:
        routed = _sling()
    woke = wake_mayor(reason, diag_path, dolt_hits, kind)
    if woke:
        return ("reparo enfileirado + Mayor acordado (fallback)" if routed else "Mayor acordado (fallback)", None)
    return ("reparo so enfileirado — sem worker, Mayor ausente" if routed else "FALHA: sem worker e sem Mayor", None)


def wake_mayor(reason, diag_path, dolt_hits, kind="gate"):
    """FALLBACK only: used when a dedicated repair agent could NOT be spawned. Wakes
    the Mayor (if awake) and hands off the same runbook for manual recovery."""
    mid = mayor_session()
    if not mid:
        return False
    task = (
        quota_verdict()  # lead the wake with the real quota verdict (ga-wjlv9): rule quota in/out FIRST
        + "🔧 ALERTA AUTOMÁTICO DO WATCHDOG — não consegui spawnar um agente de reparo, "
        "então te acordei como FALLBACK. Conserta agora, não escale pro Athos a menos que falhe.\n\n"
        + repair_runbook(reason, diag_path, dolt_hits, kind)
    )
    sh(["gc", "session", "wake", mid], timeout=20)
    r = sh(["gc", "session", "nudge", mid, task], timeout=25)
    return r is not None and r.returncode == 0


def notify(msg, prio):
    sh([NOTIFY, "-t", "Gate watchdog", "-p", str(prio), msg], timeout=10)


def _session_list_json():
    """[session-dict, ...] or None on query failure (None is distinct from an empty
    list — the governor treats None as 'cannot verify' and fail-safe SKIPS spawning,
    so a Dolt/gc outage can never become a blind-spawn amplifier)."""
    rs = sh(["gc", "session", "list", "--json"])
    if not rs or rs.returncode != 0:
        return None
    try:
        return json.loads(rs.stdout).get("sessions", [])
    except Exception:
        return None


def cond_for(kind, reason, marker_id=None, branch=None):
    """(cond_key, dedup_tokens) for a detected condition. cond_key keys the
    cooldown/backoff/spawn-count state; dedup_tokens are substrings whose presence
    in a LIVE repair-dog title means 'already being worked' (skip). For branch/
    marker-bearing kinds the tokens are the branch + marker id (precise, and they
    survive the dog's self-rename because the dog echoes the branch). For singleton
    kinds the key is fixed (one repair at a time) and tokens are kind signatures."""
    if kind == "gate-orphan":
        key = "gate-orphan:%s" % (branch or marker_id or "?")
        return (key, [t for t in (branch, marker_id) if t])
    if kind == "gate-loop":
        return ("gate-loop:%s" % (branch or reason or "?"), [t for t in (branch,) if t])
    if kind == "pilot":
        return ("pilot:jam", ["pilot"])
    if kind == "supervisor":
        return ("supervisor:initfail", ["supervisor init", "init-failure", "init failure"])
    return ("gate:down", ["marker stuck", "marcador", "sem revisores", "no active reviewer", "stuck"])


def _is_repair_dog(s):
    return s.get("template") == DOG_TEMPLATE and not s.get("closed") \
        and bool(REPAIR_DOG_TITLE_RE.search(s.get("title") or ""))


def _session_fresh(s, now):
    e = _iso_epoch(s.get("created_at"))
    if e is None:
        return True  # unknown age → assume fresh (counts toward cap = safe direction)
    return (now - e) <= REPAIR_DOG_STALE_SEC


class Governor:
    """Bounds watchdog repair-dog spawning: dedup (same condition already worked),
    a hard concurrent cap, and a per-condition cooldown with exponential back-off +
    spawn-count self-limit. Holds in-memory ledger of session_ids it spawned
    (keyed by cond) so dedup is exact go-forward; title matching is the secondary
    net for pre-fix pile-ups / restart amnesia. Pure-decision methods are unit-tested."""

    def __init__(self):
        self.ledger = {}        # cond_key -> [(session_id, spawn_epoch), ...]
        self.last_spawn = {}    # cond_key -> epoch of last spawn
        self.spawn_count = {}   # cond_key -> spawns since last recovery
        self.cooldown = {}      # cond_key -> current effective cooldown sec (back-off)
        self.escalated = {}     # cond_key -> epoch of last 🚨 (rate-limit the page)

    # ---- live repair-dog accounting ----
    def _ledger_live(self, cond_key, sessions, now):
        """session_ids this governor spawned for cond_key that are still present,
        not closed, and not stale."""
        by_id = {s.get("id"): s for s in sessions}
        live = []
        for (sid, _ts) in self.ledger.get(cond_key, []):
            s = by_id.get(sid)
            if s and not s.get("closed") and _session_fresh(s, now):
                live.append(sid)
        return live

    def active_repair_dogs(self, sessions, now):
        """Set of session_ids that are live watchdog repair dogs (ledger ∪ title-
        matched), for the concurrent cap. Union → robust across restart + rename."""
        ids = set()
        for s in sessions:
            if _is_repair_dog(s) and _session_fresh(s, now):
                ids.add(s.get("id"))
        for cond, entries in self.ledger.items():
            by_id = {s.get("id"): s for s in sessions}
            for (sid, _ts) in entries:
                s = by_id.get(sid)
                if s and not s.get("closed") and _session_fresh(s, now):
                    ids.add(sid)
        return ids

    def _dedup_hit(self, cond_key, dedup_tokens, sessions, now):
        if self._ledger_live(cond_key, sessions, now):
            return True
        toks = [t.lower() for t in (dedup_tokens or []) if t]
        if not toks:
            return False
        for s in sessions:
            if s.get("template") != DOG_TEMPLATE or s.get("closed"):
                continue
            if not _session_fresh(s, now):
                continue
            title = (s.get("title") or "").lower()
            if any(t in title for t in toks):
                return True
        return False

    def decide(self, cond_key, dedup_tokens, sessions, now):
        """(allow: bool, reason: str). Order: kill-switch → unavailable-session-list
        fail-safe → cooldown/back-off → per-condition spawn cap (self-limit) → dedup
        → global concurrent cap."""
        if not GRW_ENABLED:
            return (False, "disabled (GRW_ENABLED=0)")
        if sessions is None:
            return (False, "session-list unavailable — fail-safe skip (no blind spawn)")
        cd = self.cooldown.get(cond_key, WAKE_COOLDOWN_SEC)
        last = self.last_spawn.get(cond_key, 0)
        if now - last < cd:
            return (False, "cooldown %ds left" % int(cd - (now - last)))
        if self.spawn_count.get(cond_key, 0) >= MAX_SPAWNS_PER_CONDITION:
            return (False, "maxspawn (%d reached for condition; self-limiting — a repair dog can't fix this root)" % MAX_SPAWNS_PER_CONDITION)
        if self._dedup_hit(cond_key, dedup_tokens, sessions, now):
            return (False, "dedup (live repair dog already targeting %s)" % cond_key)
        n = len(self.active_repair_dogs(sessions, now))
        if n >= MAX_ACTIVE_REPAIR_DOGS:
            return (False, "at repair-dog cap (%d/%d) — deferring" % (n, MAX_ACTIVE_REPAIR_DOGS))
        return (True, "ok")

    def record_spawn(self, cond_key, session_id, now):
        if session_id:
            self.ledger.setdefault(cond_key, []).append((session_id, now))
        self.last_spawn[cond_key] = now
        self.spawn_count[cond_key] = self.spawn_count.get(cond_key, 0) + 1
        # exponential back-off: each repeat for the same condition waits longer
        self.cooldown[cond_key] = min(WAKE_COOLDOWN_SEC * (2 ** (self.spawn_count[cond_key] - 1)),
                                      WAKE_BACKOFF_MAX_SEC)

    def spawns(self, cond_key):
        return self.spawn_count.get(cond_key, 0)

    def should_escalate(self, cond_key, now):
        """True at most once per WAKE_BACKOFF_MAX_SEC for a condition that hit the
        per-condition spawn cap — page the human ONCE, don't spam."""
        if self.spawn_count.get(cond_key, 0) < MAX_SPAWNS_PER_CONDITION:
            return False
        if now - self.escalated.get(cond_key, 0) < WAKE_BACKOFF_MAX_SEC:
            return False
        self.escalated[cond_key] = now
        return True

    def reset_prefix(self, prefix):
        """On recovery, clear all per-condition state for a kind (keys start with
        prefix) so the next genuine incident starts fresh (cooldown + counts)."""
        for d in (self.last_spawn, self.spawn_count, self.cooldown, self.ledger, self.escalated):
            for k in [k for k in d if k.startswith(prefix)]:
                del d[k]


def governed_spawn(gov, sessions, now, kind, reason, diag, dolt_hits, label,
                   marker_id=None, branch=None):
    """Single entry point for every detection block: apply the governor, then spawn
    (or skip / escalate). Returns a short status string for logging, or None if the
    spawn was suppressed. Centralizing this is what makes dedup+cap+back-off apply
    uniformly to all five detectors instead of each re-implementing a coarse per-kind
    cooldown (the old design, which gated by KIND only — so 6 different orphan
    markers, or one marker seen 6 times across cooldown windows, each spawned)."""
    cond_key, dedup_tokens = cond_for(kind, reason, marker_id=marker_id, branch=branch)
    allow, why = gov.decide(cond_key, dedup_tokens, sessions, now)
    if not allow:
        print("[watchdog] %s repair SKIPPED (%s) cond=%s" % (label, why, cond_key), flush=True)
        if gov.should_escalate(cond_key, now):
            notify("🚨 %s: reparo autônomo já tentou %dx p/ %s e não resolveu — precisa de você. Diag: %s"
                   % (label, MAX_SPAWNS_PER_CONDITION, cond_key, diag), 5)
            _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical", "bead_id": "", "reason": "%s: reparo autônomo %dx não resolveu cond=%s" % (label, MAX_SPAWNS_PER_CONDITION, cond_key)}, fail_open=True)
            print("[watchdog] ESCALATED to Athos (%s self-limit reached)" % cond_key, flush=True)
        return None
    if GRW_DRY_RUN:
        print("[watchdog] DRY_RUN would spawn repair: kind=%s cond=%s reason=%s diag=%s"
              % (kind, cond_key, reason, diag), flush=True)
        gov.record_spawn(cond_key, None, now)
        return "DRY_RUN (no spawn)"
    how, sid = spawn_repair_agent(reason, diag, dolt_hits, kind)
    gov.record_spawn(cond_key, sid, now)
    n = gov.spawns(cond_key)
    if n >= ESCALATE_AFTER_WAKES:
        notify("🚨 %s ainda quebrado após %dx de reparo autônomo (cond %s). Precisa de você. Diag: %s"
               % (label, n, cond_key, diag), 5)
        _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical", "bead_id": "", "reason": "%s ainda quebrado após %dx reparo autônomo cond=%s" % (label, n, cond_key)}, fail_open=True)
        print("[watchdog] ESCALATED to Athos (%s, %d cycles)" % (cond_key, n), flush=True)
    else:
        notify("%s (%s) — %s. Você não precisa agir." % (label, reason, how), 3)
    print("[watchdog] repair dispatch (%s) kind=%s cond=%s reason=%s diag=%s"
          % (how, kind, cond_key, reason, diag), flush=True)
    return how


# ═══════════════════════════════════════════════════════════════════════════════
# DIRECT SELF-HEAL — the two toils the Mayor fixed BY HAND ~6x/day
# (1) reap a HUNG gate-reviewer / stale gate-status:running gate-run, and
# (2) auto-requeue a STUCK gate-status:error marker.
# These perform the recovery MUTATION themselves (no dog, no Mayor). Every pure
# DECISION is factored into a *_verdict() function so the selftest unit-tests the
# reap/keep + requeue/close/escalate logic against synthetic fixtures with no live
# Dolt — mirroring reconcile_gaterun_action / classify_sibling_run / gatefix_recovery_decide.
# ═══════════════════════════════════════════════════════════════════════════════

def _recovery_ledger(event, fields):
    """Append a durable jsonl evidence record for every direct reap/requeue.
    Best-effort; never raises (audit must never break recovery)."""
    try:
        rec = {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "event": event}
        rec.update(fields or {})
        with open(RECOVERY_LOG, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception:
        pass


def _parse_run_field(desc, field):
    """Extract a `field: value` line from a gate-run bead description (the same
    key=value block the guard/dispatcher write: source_bead, marker_id, started_at,
    required_reviewers). Canonical, whitespace-tolerant. '' if absent."""
    if not desc:
        return ""
    for line in desc.splitlines():
        if line.startswith(field + ":"):
            return line[len(field) + 1:].strip()
    return ""


def _label_value(bead, prefix):
    """First label value for a `prefix` (e.g. 'source-bead:'), or '' — reads the
    label list already present on a bead dict (no extra query)."""
    for lb in (bead.get("labels") or []):
        if lb.startswith(prefix):
            return lb[len(prefix):]
    return ""


def set_gate_status_py(bead_id, new_status):
    """Python mirror of the shell set_gate_status (byte-for-byte SEMANTICS, ga-jhyu):
    strip EVERY gate-status:* label currently on the bead, then add exactly the one
    target — so a bead never leaks two gate-status labels (observed live: done+failed,
    passed+superseded). Best-effort; never raises."""
    if not bead_id:
        return
    r = sh(["bd", "-C", CITY, "show", bead_id, "--json"])
    cur = []
    try:
        j = json.loads(r.stdout) if (r and r.returncode == 0) else None
        row = (j[0] if isinstance(j, list) and j else j) or {}
        cur = [l for l in (row.get("labels") or []) if str(l).startswith("gate-status:")]
    except Exception:
        cur = []
    for lbl in cur:
        if lbl == "gate-status:%s" % new_status:
            continue
        sh(["bd", "-C", CITY, "label", "remove", bead_id, lbl, "-q"])
    sh(["bd", "-C", CITY, "label", "add", bead_id, "gate-status:%s" % new_status, "-q"])


def _bead_is_open(bead_id):
    """True/False if a bead is open; None on query failure (caller fail-safe)."""
    if not bead_id:
        return None
    r = sh(["bd", "-C", CITY, "show", bead_id, "--json"])
    if not r or r.returncode != 0:
        return None
    try:
        j = json.loads(r.stdout)
        row = (j[0] if isinstance(j, list) and j else j) or {}
        return row.get("status") != "closed"
    except Exception:
        return None


def _bead_labels(bead_id):
    """A bead's label list ([] on failure) — used by FIX 5's per-marker stranded cap."""
    if not bead_id:
        return []
    r = sh(["bd", "-C", CITY, "show", bead_id, "--json"])
    if not r or r.returncode != 0:
        return []
    try:
        j = json.loads(r.stdout)
        row = (j[0] if isinstance(j, list) and j else j) or {}
        return row.get("labels") or []
    except Exception:
        return []


_RIG_PATHS = {"ts": 0.0, "map": {}}


def _rig_paths():
    """{rig_name: repo_path} from `gc rig list`, cached ~10min. A marker's source
    bead lives in its RIG store, not HQ, so resolving 'is the source bead closed'
    needs the rig path (mirrors gatefix-deadworker-recovery). {} on failure."""
    if time.time() - _RIG_PATHS["ts"] < 600 and _RIG_PATHS["map"]:
        return _RIG_PATHS["map"]
    r = sh(["gc", "--city", CITY, "rig", "list", "--json"])
    m = {}
    try:
        j = json.loads(r.stdout) if (r and r.returncode == 0) else {}
        for rg in (j.get("rigs", []) if isinstance(j, dict) else []):
            nm, p = rg.get("name"), rg.get("path")
            if nm and p:
                m[nm] = p
    except Exception:
        m = {}
    if m:
        _RIG_PATHS["map"] = m
        _RIG_PATHS["ts"] = time.time()
    return _RIG_PATHS["map"]


def _source_bead_state(bead_id, rig_name=""):
    """(resolved, closed, needs_human) for a marker's source bead. Tries HQ first,
    then the bead's rig store. resolved=False on any failure → the caller treats the
    source as UNKNOWN and proceeds to requeue (fail toward recovery; the dispatcher
    re-validates the branch, and the oscillation cap bounds a bad requeue)."""
    if not bead_id:
        return (False, False, False)
    rigp = _rig_paths().get(rig_name) if rig_name else None
    tries = [[CITY]]
    if rigp and rigp != CITY:
        tries.append([rigp])
    for st in tries:
        r = sh(["bd", "-C", st[0], "show", bead_id, "--json"])
        if not r or r.returncode != 0:
            continue
        try:
            j = json.loads(r.stdout)
            row = (j[0] if isinstance(j, list) and j else j) or {}
        except Exception:
            continue
        if not row or not row.get("id"):
            continue
        closed = (row.get("status") == "closed")
        nh = any(str(l).startswith("gate:needs-human") for l in (row.get("labels") or []))
        return (True, closed, nh)
    return (False, False, False)


def _source_review_state(bead_id, rig_name=""):
    """(resolved, closed, has_reviewing, store) for a marker's source bead — ONE read,
    used by FIX 4 both to decide (close-source-done vs clear-stale-reviewing) and to know
    WHICH store to clear the label in (the source lives in its RIG, not HQ). resolved=
    False on any failure → FIX 4 fail-safe keeps the marker untouched."""
    if not bead_id:
        return (False, False, False, CITY)
    rigp = _rig_paths().get(rig_name) if rig_name else None
    tries = [CITY] + ([rigp] if (rigp and rigp != CITY) else [])
    for st in tries:
        r = sh(["bd", "-C", st, "show", bead_id, "--json"])
        if not r or r.returncode != 0:
            continue
        try:
            j = json.loads(r.stdout)
            row = (j[0] if isinstance(j, list) and j else j) or {}
        except Exception:
            continue
        if not row or not row.get("id"):
            continue
        labs = row.get("labels") or []
        return (True, row.get("status") == "closed", "gate:reviewing" in labs, st)
    return (False, False, False, CITY)


def _branch_merged_state(branch, rig_name=""):
    """Classify a marker's branch vs the rig's origin/main — the TRUTH about whether the
    work landed (a source bead being closed does NOT prove it, ga-w5agg/ga-d2jil):
      'merged'   — origin/<branch> is an ancestor of origin/main (landed).
      'unmerged' — origin/<branch> exists but is NOT an ancestor (STRANDED — fix pending).
      'missing'  — no such branch on origin (abandoned/renamed → marker is truly moot).
      'unknown'  — rig unresolved / git error → caller MUST NOT treat as done (fail-safe).
    Bounded git ops in the branch's rig repo (or HQ if rig unresolved)."""
    if not branch:
        return "unknown"
    repo = (_rig_paths().get(rig_name) if rig_name else None) or CITY
    sh(["git", "-C", repo, "fetch", "origin", "--quiet"], timeout=30)
    ex = sh(["git", "-C", repo, "rev-parse", "--verify", "-q", "origin/%s^{commit}" % branch], timeout=15)
    if not ex or ex.returncode != 0 or not (ex.stdout or "").strip():
        return "missing"
    anc = sh(["git", "-C", repo, "merge-base", "--is-ancestor",
              "origin/%s" % branch, "origin/main"], timeout=15)
    if anc is None:
        return "unknown"
    if anc.returncode == 0:
        return "merged"
    if anc.returncode == 1:
        return "unmerged"
    return "unknown"


def orphan_marker_verdict(age_sec, min_sec, resolved, source_closed, source_reviewing,
                          branch_state="unknown"):
    """PURE decision (no I/O, unit-tested) for FIX 4, on a gate-status:queued marker:
      'close-source-done'     — source CLOSED **and the branch actually merged** (or is
                                gone) → the marker is moot; close it (phantom depth).
      'recover-stranded'      — source CLOSED but the branch EXISTS and is NOT merged →
                                a FALSE close (the sling-task-janitor closes fix-task
                                beads as 'orphan' without the branch merging, which used
                                to make FIX 4 false-close the marker as 'merged' and
                                STRAND a complete fix — ga-w5agg/ga-d2jil 2026-07-02).
                                Re-land it, NEVER close.
      'clear-stale-reviewing' — source OPEN + carries gate:reviewing while the marker
                                sits QUEUED (contradictory) → leaked label; clear it.
      'wait'                  — younger than min_sec.
      'keep'                  — source unreadable / branch state unknown (fail-safe) or
                                nothing to do — NEVER close on a can't-verify.
    branch_state ∈ {'merged','unmerged','missing','unknown'}: a source being closed does
    NOT prove the work landed — the branch's ancestry vs origin/main is the truth."""
    if age_sec < min_sec:
        return "wait"
    if not resolved:
        return "keep"
    if source_closed:
        if branch_state in ("merged", "missing"):
            return "close-source-done"   # truly landed, or abandoned (no branch) → close phantom
        if branch_state == "unmerged":
            return "recover-stranded"    # real branch, not merged → stranded fix, never false-close
        return "keep"                    # unknown → fail-safe, NEVER false-close as 'merged'
    if source_reviewing:
        return "clear-stale-reviewing"
    return "keep"


def _session_index(sessions):
    """{identifier: session-dict} across every name field a verdict-bead assignee
    could carry (session_name/name/alias/agent_name/id — verified equal live)."""
    idx = {}
    for s in (sessions or []):
        for k in ("session_name", "name", "alias", "agent_name", "id"):
            v = s.get(k)
            if v:
                idx[str(v)] = s
    return idx


def _any_reviewer_active(sessions, names):
    """True if ANY of a run's reviewer sessions (by verdict-bead assignee name) is
    state=='active' (the authoritative session-manager liveness signal — NOT a
    session-id proc grep, which is unreliable because a reviewer's claude cmdline
    carries no session id). False if all non-active/absent. None if the session
    list is unavailable → caller fail-safe SKIPS (a gc/Dolt outage can never
    become a blind reaper)."""
    if sessions is None:
        return None
    if not names:
        return False
    idx = _session_index(sessions)
    for nm in names:
        s = idx.get(str(nm))
        if s and not s.get("closed") and str(s.get("state", "")).lower() == "active":
            return True
    return False


def _run_verdicts(run_id):
    """(reviewer_names:set, delivered:int, total:int) for a gate-run's verdict beads
    (label gate-run:<id>). delivered = CLOSED verdict beads (a closed verdict bead =
    a verdict was recorded; open/in_progress = pending). Returns (set(), -1, -1) on
    query failure so the caller fail-safe skips."""
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "gate-run:%s" % run_id, "--json"])
    if not r or r.returncode != 0:
        return (set(), -1, -1)
    try:
        rows = json.loads(r.stdout) or []
    except Exception:
        return (set(), -1, -1)
    names, delivered = set(), 0
    for row in rows:
        a = row.get("assignee")
        if a:
            names.add(a)
        if row.get("status") == "closed":
            delivered += 1
    return (names, delivered, len(rows))


def hung_run_verdict(age_sec, hang_sec, n_verdict_beads, n_delivered,
                     reviewer_active, delivered_after_resample):
    """PURE decision: should a gate-status:running gate-run be reaped as HUNG?
    Returns 'reap' or 'skip:<reason>'. Ordered fail-SAFE — every branch that could
    be a genuinely-working (just slow) review returns skip:

      skip:young            — younger than REVIEW_HANG_MINUTES (a real review takes 9+m)
      skip:verdict-query-failed — could not read verdict beads (never reap blind)
      skip:not-a-review-run — 0 verdict beads = a guard CLAIM-time tracking run, not a
                              dispatcher review run; leave it to the guard's own reconcile
      skip:producing        — >=1 verdict already delivered → reviewers ARE working
      skip:liveness-unknown — session list unavailable → never reap blind
      skip:reviewer-active  — a reviewer session is state=active → working, not hung
      skip:verdict-landed   — a verdict landed between the two samples → working
      reap                  — old AND a real review run AND 0 delivered AND the reviewer
                              is dead/idle SUSTAINED across both samples.
    """
    if age_sec <= hang_sec:
        return "skip:young"
    if n_verdict_beads < 0:
        return "skip:verdict-query-failed"
    if n_verdict_beads == 0:
        return "skip:not-a-review-run"
    if n_delivered > 0:
        return "skip:producing"
    if reviewer_active is None:
        return "skip:liveness-unknown"
    if reviewer_active:
        return "skip:reviewer-active"
    if delivered_after_resample and delivered_after_resample > 0:
        return "skip:verdict-landed"
    return "reap"


def error_requeue_verdict(age_sec, threshold_sec, source_resolved, source_closed,
                          source_needs_human, requeue_count, max_attempts):
    """PURE decision for a gate-status:error marker. Returns:
      close:source-done      — the source bead is CLOSED (work merged/abandoned) → the
                               marker is a leftover; close it, do NOT requeue (checked
                               FIRST, before the age gate: a done marker never waits)
      skip:young             — in error < threshold; let a transient self-clear first
      skip:parked-needs-human— source bead carries gate:needs-human (ga-acb permanent
                               park) → deliberately awaiting a human; never requeue
      escalate:oscillating   — already requeued max_attempts times and it keeps
                               re-erroring → stop the infinite loop, page the Mayor
      requeue                — genuinely stuck transient error → error→queued
    """
    if source_resolved and source_closed:
        return "close:source-done"
    if age_sec <= threshold_sec:
        return "skip:young"
    if source_resolved and source_needs_human:
        return "skip:parked-needs-human"
    if requeue_count >= max_attempts:
        return "escalate:oscillating"
    return "requeue"


class RecoveryState:
    """Tiny in-memory state for the two direct-action features: a per-marker requeue
    counter (backs the durable grw-requeue:N label so oscillation detection survives
    even mid-process) and an escalate-once dedup so a stuck condition pages the Mayor
    at most once per back-off window."""
    def __init__(self):
        self.error_requeues = {}   # marker_id -> requeues this process has done
        self.escalated = {}        # key -> last-escalation epoch

    def escalate_once(self, key, now, window=None):
        w = WAKE_BACKOFF_MAX_SEC if window is None else window
        if now - self.escalated.get(key, 0) < w:
            return False
        self.escalated[key] = now
        return True


def _open_running_runs():
    """[gate-run dicts] with type:quality-gate-run + gate-status:running + open.
    None on query failure (fail-safe: caller skips — never reap during a Dolt glitch)."""
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "type:quality-gate-run",
            "-l", "gate-status:running", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def reap_hung_runs(sessions, now, rstate):
    """FIX 1: reap a HUNG gate-reviewer. For every open gate-status:running gate-run
    past REVIEW_HANG_MINUTES with 0 verdicts delivered whose reviewer session is
    dead/idle SUSTAINED across two samples, do the FULL manual reap the Mayor did by
    hand: drain the zombie reviewer session(s), supersede+close the run, and re-queue
    its marker so a fresh run reviews it. Bounded, dry-run-aware, fully fail-safe."""
    if not GRW_ENABLED or not GRW_REAP_HUNG_ENABLED:
        return
    runs = _open_running_runs()
    if runs is None:
        print("[watchdog] reap: gate-run query unavailable — fail-safe skip (no blind reap)", flush=True)
        return
    reaped = 0
    for run in runs:
        if reaped >= REAP_MAX_PER_SWEEP:
            break
        rid = run.get("id")
        if not rid:
            continue
        desc = run.get("description") or ""
        started = _parse_run_field(desc, "started_at")
        se = _iso_epoch(started)
        if not se:
            continue  # no parseable started_at → cannot age → fail-safe skip
        age = int(now - se)
        if age <= REVIEW_HANG_MINUTES * 60:
            continue  # too young — a real review can take 9+ min; never reap early
        names, delivered, total = _run_verdicts(rid)
        active1 = _any_reviewer_active(sessions, names)
        v1 = hung_run_verdict(age, REVIEW_HANG_MINUTES * 60, total, delivered, active1, 0)
        if v1 != "reap":
            if GRW_DRY_RUN:
                print("[watchdog] reap DRY skip run=%s (%s) age=%dm beads=%d delivered=%d reviewers=%r"
                      % (rid, v1, age // 60, total, delivered, sorted(names)), flush=True)
            continue
        # CANDIDATE — confirm SUSTAINED-idle: re-sample liveness + verdicts after a gap.
        # A genuinely-working reviewer that blipped asleep will read active on the
        # second sample, or will have LANDED a verdict — either aborts the reap.
        time.sleep(LIVENESS_RESAMPLE_SEC)
        sessions2 = _session_list_json()
        names2, delivered2, total2 = _run_verdicts(rid)
        active2 = _any_reviewer_active(sessions2, names2)
        both_active = None if (active1 is None or active2 is None) else (active1 or active2)
        eff_total = total2 if total2 >= 0 else total
        eff_delivered = delivered2 if delivered2 >= 0 else delivered
        v2 = hung_run_verdict(age, REVIEW_HANG_MINUTES * 60, eff_total, eff_delivered,
                              both_active, eff_delivered)
        if v2 != "reap":
            print("[watchdog] reap: run=%s NOT reaped after resample (%s) age=%dm — fail-safe KEPT (working/slow review)"
                  % (rid, v2, age // 60), flush=True)
            continue
        marker_id = _parse_run_field(desc, "marker_id")
        source_bead = _parse_run_field(desc, "source_bead") or _label_value(run, "source-bead:")
        if GRW_DRY_RUN:
            print("[watchdog] REAP DRY-RUN would reap HUNG run=%s age=%dm 0/%d verdicts reviewers=%r → supersede+close run, drain session(s), re-queue marker=%s"
                  % (rid, age // 60, eff_total, sorted(names), marker_id), flush=True)
            _recovery_ledger("would_reap_hung_run", {"run": rid, "age_min": age // 60,
                             "verdict_beads": eff_total, "delivered": eff_delivered,
                             "reviewers": sorted(names), "marker": marker_id, "dry_run": True})
            reaped += 1
            continue
        # 1) drain the zombie reviewer session(s) — only the NON-active ones (freeing
        #    the max_active_sessions / LIVE_REVIEWERS slot the hung reviewer occupied).
        idx = _session_index(sessions2 if sessions2 is not None else sessions)
        drained = []
        for nm in names:
            s = idx.get(str(nm))
            if s and not s.get("closed") and str(s.get("state", "")).lower() != "active":
                sid = s.get("id")
                if sid:
                    sh(["gc", "session", "close", sid], timeout=20)
                    drained.append(sid)
        # 2) supersede + close the run (mirrors the dispatcher's own ga-jhyu close).
        set_gate_status_py(rid, "superseded")
        sh(["bd", "-C", CITY, "comment", rid,
            "gate-recovery-watchdog: reaped HUNG run (age=%dm, 0/%d verdicts delivered, reviewer session(s) [%s] dead/idle SUSTAINED across 2 samples %ds apart). Superseding + closing so marker %s re-reviews fresh. (grw hung-reviewer self-heal — the manual toil the Mayor did ~6x/day)"
            % (age // 60, eff_total, ",".join(sorted(names)) or "none", LIVENESS_RESAMPLE_SEC, marker_id or "unknown")], timeout=25)
        sh(["bd", "-C", CITY, "close", rid,
            "-r", "gate-run superseded: reviewer hung (grw auto-reap — 0 verdicts, dead reviewer, age %dm)" % (age // 60)], timeout=25)
        # 3) re-queue the marker (with the same carve-outs as FIX 2).
        marker_action = "no-marker"
        if marker_id:
            m_open = _bead_is_open(marker_id)
            if m_open is False:
                marker_action = "marker-already-closed"
            elif m_open is None:
                marker_action = "marker-state-unknown-skip"
            else:
                resolved, sclosed, needs_human = _source_bead_state(
                    source_bead, _label_value(run, "bead-rig:"))
                if resolved and sclosed:
                    set_gate_status_py(marker_id, "superseded")
                    sh(["bd", "-C", CITY, "close", marker_id,
                        "-r", "source bead %s closed — gate work done/abandoned; marker superseded (grw)" % source_bead], timeout=25)
                    marker_action = "closed:source-done"
                elif resolved and needs_human:
                    marker_action = "left:needs-human"
                else:
                    set_gate_status_py(marker_id, "queued")
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog: re-queued (→gate-status:queued) after reaping its HUNG run %s (reviewer dead, 0 verdicts, %dm). A fresh dispatcher sweep will re-review this branch. (grw hung-reviewer self-heal)"
                        % (rid, age // 60)], timeout=25)
                    marker_action = "requeued"
        _recovery_ledger("reap_hung_run", {"run": rid, "age_min": age // 60,
                         "verdict_beads": eff_total, "delivered": eff_delivered,
                         "reviewers": sorted(names), "drained_sessions": drained,
                         "marker": marker_id, "marker_action": marker_action,
                         "source_bead": source_bead})
        notify("Gate self-heal: revisor travado reapado (run %s, %dmin, 0 vereditos) — marker %s %s. Você não precisa agir."
               % (rid, age // 60, marker_id or "?", marker_action), 3)
        print("[watchdog] REAPED hung run=%s age=%dm 0/%d verdicts reviewers=%r drained=%r marker=%s action=%s"
              % (rid, age // 60, eff_total, sorted(names), drained, marker_id, marker_action), flush=True)
        reaped += 1
    if reaped:
        print("[watchdog] reap sweep: %d hung run(s) reaped%s" % (reaped, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def stranded_verdict_verdict(age_sec, threshold_sec, delivered, total):
    """PURE decision (unit-tested) for FIX 5: should a gate-status:running run be
    RECOVERED as a STRANDED-VERDICT run — all required verdicts DELIVERED but the run
    never finalized (managing sweep died post-verdict; wa-99jug 2026-07-02)? Returns
    'recover' or 'skip:<reason>'. Fail-safe: any ambiguity → skip.
      skip:young        younger than threshold (a healthy finalize is seconds after the
                        last verdict — wait well past so a mid-finalize run is never touched)
      skip:query-failed verdict counts unreadable (never act blind)
      skip:not-a-run    0 verdict beads (a guard claim-tracking run, not a review)
      skip:collecting   delivered < total (a REAL in-progress review still gathering verdicts)
      recover           age>=threshold AND total>=1 AND delivered==total (all in, still running, stale)
    """
    if age_sec < threshold_sec:
        return "skip:young"
    if total < 0 or delivered < 0:
        return "skip:query-failed"
    if total == 0:
        return "skip:not-a-run"
    if delivered < total:
        return "skip:collecting"
    return "recover"


def reap_stranded_verdict_runs(now):
    """FIX 5: recover a STRANDED-VERDICT run (all required verdicts delivered, still
    gate-status:running, managing sweep dead). See stranded_verdict_verdict. Supersede
    the run + clear the source's stale gate:reviewing (the phantom 'em revisão') +
    re-queue the marker so a fresh sweep re-reviews and finalizes cleanly. The watchdog
    NEVER duplicates the dispatcher's merge/FAIL finalization — it hands the completed
    branch back to the gate. Per-marker cap → escalate to needs-human on repeat. No
    reviewer-liveness needed (the reviewers already delivered). Bounded, dry-run-aware,
    fully fail-safe (query failure / run finalized between samples → skip)."""
    if not GRW_ENABLED or not GRW_REAP_STRANDED_ENABLED:
        return
    runs = _open_running_runs()
    if runs is None:
        return  # gate-run query unavailable → fail-safe skip
    acted = 0
    for run in runs:
        if acted >= REAP_MAX_PER_SWEEP:
            break
        rid = run.get("id")
        if not rid:
            continue
        desc = run.get("description") or ""
        se = _iso_epoch(_parse_run_field(desc, "started_at"))
        if not se:
            continue  # no parseable started_at → cannot age → skip
        age = int(now - se)
        _names, delivered, total = _run_verdicts(rid)
        if stranded_verdict_verdict(age, STRANDED_RUN_MINUTES * 60, delivered, total) != "recover":
            continue
        # SUSTAINED confirm: re-read after a gap. If the run finalized (no longer open),
        # or verdict counts changed, a live sweep is handling it → abort (never race it).
        time.sleep(LIVENESS_RESAMPLE_SEC)
        if _bead_is_open(rid) is False:
            print("[watchdog] FIX5: run=%s finalized between samples — a live sweep handled it, no action" % rid, flush=True)
            continue
        _n2, delivered2, total2 = _run_verdicts(rid)
        if stranded_verdict_verdict(age, STRANDED_RUN_MINUTES * 60,
                                    delivered2 if delivered2 >= 0 else delivered,
                                    total2 if total2 >= 0 else total) != "recover":
            print("[watchdog] FIX5: run=%s not stranded after resample — kept (fail-safe)" % rid, flush=True)
            continue
        marker_id = _parse_run_field(desc, "marker_id")
        source_bead = _parse_run_field(desc, "source_bead") or _label_value(run, "source-bead:")
        rig = _label_value(run, "bead-rig:")
        if GRW_DRY_RUN:
            print("[watchdog] FIX5 DRY would recover STRANDED run=%s age=%dm %d/%d verdicts → supersede + clear gate:reviewing + re-queue marker=%s"
                  % (rid, age // 60, delivered, total, marker_id), flush=True)
            _recovery_ledger("would_recover_stranded_run", {"run": rid, "age_min": age // 60,
                             "delivered": delivered, "total": total, "marker": marker_id, "dry_run": True})
            acted += 1
            continue
        # 1) supersede + close the stranded run.
        set_gate_status_py(rid, "superseded")
        sh(["bd", "-C", CITY, "comment", rid,
            "gate-recovery-watchdog FIX5: STRANDED-VERDICT run — %d/%d required verdicts DELIVERED but the run stayed gate-status:running %dm (managing sweep died post-verdict; SUSTAINED across 2 samples). Superseding + re-queuing marker %s so a fresh sweep re-reviews and finalizes cleanly. (the wa-99jug phantom-'em revisão' class)"
            % (delivered, total, age // 60, marker_id or "unknown")], timeout=25)
        sh(["bd", "-C", CITY, "close", rid,
            "-r", "gate-run superseded: stranded verdict (grw FIX5 — %d/%d delivered, never finalized, %dm)" % (delivered, total, age // 60)], timeout=25)
        # 2) clear the stale gate:reviewing on the source (the phantom 'em revisão').
        resolved, sclosed, reviewing, store = _source_review_state(source_bead, rig)
        cleared_reviewing = False
        if resolved and reviewing:
            sh(["bd", "-C", store, "label", "remove", source_bead, "gate:reviewing", "-q"], timeout=20)
            cleared_reviewing = True
        # 3) re-queue the marker (source-state carve-outs + per-marker stranded cap).
        marker_action = "no-marker"
        if marker_id:
            m_open = _bead_is_open(marker_id)
            if m_open is False:
                marker_action = "marker-already-closed"
            elif m_open is None:
                marker_action = "marker-state-unknown-skip"
            elif resolved and sclosed:
                set_gate_status_py(marker_id, "superseded")
                sh(["bd", "-C", CITY, "close", marker_id, "-r",
                    "source bead %s closed — gate work done; stranded marker superseded (grw FIX5)" % source_bead], timeout=25)
                marker_action = "closed:source-done"
            else:
                n = 0
                for lb in _bead_labels(marker_id):
                    m = GRW_STRANDED_LABEL_RE.match(str(lb))
                    if m:
                        n = max(n, int(m.group(1)))
                if n + 1 >= STRANDED_MAX_ATTEMPTS:
                    set_gate_status_py(marker_id, "error")
                    sh(["bd", "-C", CITY, "label", "add", marker_id, "gate:needs-human", "-q"], timeout=20)
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog FIX5: stranded-verdict recovery hit the cap (%d) — this marker's run keeps delivering verdicts then failing to finalize. Escalating to gate:needs-human; a human/Mayor must finalize by hand (the finalize path itself is likely broken)."
                        % STRANDED_MAX_ATTEMPTS], timeout=25)
                    notify("Gate: marker %s estranha repetidamente (veredito entregue mas run não finaliza, %dx) — escalado p/ needs-human. Precisa de você." % (marker_id, STRANDED_MAX_ATTEMPTS), 4)
                    marker_action = "escalated:needs-human"
                else:
                    if n > 0:
                        sh(["bd", "-C", CITY, "label", "remove", marker_id, "grw-stranded:%d" % n, "-q"], timeout=15)
                    sh(["bd", "-C", CITY, "label", "add", marker_id, "grw-stranded:%d" % (n + 1), "-q"], timeout=15)
                    set_gate_status_py(marker_id, "queued")
                    sh(["bd", "-C", CITY, "comment", marker_id,
                        "gate-recovery-watchdog FIX5: re-queued (->queued) after superseding its STRANDED run %s (%d/%d verdicts delivered but never finalized, %dm). A fresh sweep re-reviews + finalizes. (recovery %d/%d)"
                        % (rid, delivered, total, age // 60, n + 1, STRANDED_MAX_ATTEMPTS)], timeout=25)
                    marker_action = "requeued"
        _recovery_ledger("recover_stranded_run", {"run": rid, "age_min": age // 60,
                         "delivered": delivered, "total": total, "marker": marker_id,
                         "marker_action": marker_action, "source_bead": source_bead,
                         "cleared_gate_reviewing": cleared_reviewing})
        notify("Gate self-heal: run com veredito órfão recuperado (%s, %d/%d entregues, %dmin, nunca finalizou) — marker %s %s. Você não precisa agir."
               % (rid, delivered, total, age // 60, marker_id or "?", marker_action), 3)
        print("[watchdog] FIX5 RECOVERED stranded run=%s age=%dm %d/%d verdicts marker=%s action=%s cleared_reviewing=%s"
              % (rid, age // 60, delivered, total, marker_id, marker_action, cleared_reviewing), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX5 stranded-verdict sweep: %d run(s) recovered%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def reap_frozen_reviewers(sessions, now):
    """FIX 3: kill a FROZEN gate-reviewer — state=active but last_active silent past
    FROZEN_KILL_SECS. This is the gap reap_hung_runs (FIX 1) can't see: a frozen
    reviewer reads active, so hung_run_verdict returns skip:reviewer-active and the
    run is KEPT; meanwhile the dispatcher's ga-q8tmn re-convene runs out of respawn
    budget (2) and waits the full 45m outer timeout — the exact 90-min stall the Mayor
    cleared by hand (2026-07-02: 6ohacd silent 34m, queue starved to 531m). `gc session
    kill` makes the reconciler revive the reviewer in place. SUSTAINED-confirmed (a
    reviewer mid-think that resumes between samples is never killed) + bounded +
    dry-run-aware + fully fail-safe (unparseable/future/fresh last_active → never
    killed; a gc/Dolt outage returns sessions=None → skip)."""
    if not GRW_ENABLED or not GRW_REAP_FROZEN_ENABLED:
        return
    if sessions is None:
        return  # cannot verify liveness → fail-safe skip (never a blind kill)
    # candidates: active gate-reviewer sessions silent past the threshold
    cand = []
    for s in sessions:
        if s.get("template") != "gate-reviewer" or s.get("closed"):
            continue
        la = _last_active_epoch(s.get("last_active"))
        if la is None:
            continue
        silence = int(now - la)
        if frozen_reviewer_verdict(s.get("state"), silence, FROZEN_KILL_SECS) == "kill":
            cand.append((s.get("id"), s.get("last_active"), silence))
    if not cand:
        return
    # SUSTAINED confirm: re-sample after a gap. A reviewer whose last_active ADVANCED
    # (it was mid-think, not wedged) is dropped — only STILL-silent sessions are killed.
    time.sleep(LIVENESS_RESAMPLE_SEC)
    s2 = _session_list_json()
    idx2 = {str(s.get("id")): s for s in s2} if s2 else None
    killed = 0
    for sid, la_iso, silence in cand:
        if killed >= FROZEN_KILL_MAX_PER_SWEEP:
            break
        if not sid:
            continue
        if idx2 is not None:
            s = idx2.get(str(sid))
            if s is None:
                continue  # session gone on its own (reconciler/dispatcher acted) → done
            la2 = _last_active_epoch(s.get("last_active"))
            now2 = time.time()
            if frozen_reviewer_verdict(s.get("state"),
                                       (int(now2 - la2) if la2 is not None else None),
                                       FROZEN_KILL_SECS) != "kill":
                print("[watchdog] frozen-reviewer %s RESUMED/changed on resample — NOT killing (fail-safe)" % sid, flush=True)
                continue
        if GRW_DRY_RUN:
            print("[watchdog] FROZEN DRY-RUN would kill reviewer %s (last_active=%s, silent %dm) → reconciler revives fresh"
                  % (sid, la_iso, silence // 60), flush=True)
            _recovery_ledger("would_kill_frozen_reviewer",
                             {"session": sid, "last_active": la_iso, "silent_min": silence // 60, "dry_run": True})
            killed += 1
            continue
        sh(["gc", "session", "kill", sid], timeout=20)
        _recovery_ledger("kill_frozen_reviewer",
                         {"session": sid, "last_active": la_iso, "silent_min": silence // 60})
        notify("Gate self-heal: revisor CONGELADO morto (%s, %dmin sem atividade, active-mas-mudo) — reconciler sobe fresco. Você não precisa agir."
               % (sid, silence // 60), 3)
        print("[watchdog] KILLED frozen reviewer %s (last_active=%s, silent %dm) — reconciler revives fresh (grw FIX3 frozen-reviewer self-heal)"
              % (sid, la_iso, silence // 60), flush=True)
        killed += 1
    if killed:
        print("[watchdog] frozen-reviewer sweep: %d killed%s" % (killed, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def reap_orphan_and_stale_markers(now):
    """FIX 4: for each open gate-status:queued/ready/claimed marker older than
    ORPHAN_MARKER_MIN_MINUTES, either close it (SOURCE already closed → orphaned/phantom
    depth) or clear a leaked gate:reviewing on its OPEN source (the head-of-line
    STARVATION root — a reviewer drained during startup and left the label, so the
    dispatcher skips re-dispatch forever). FIX 1/2 don't cover this (they handle
    running-run reaps + gate-status:error). Bounded, dry-run-aware, fully fail-safe:
    an unreadable source → keep; a query failure → skip the whole sweep."""
    if not GRW_ENABLED or not GRW_REAP_ORPHAN_ENABLED:
        return
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
            "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return  # query failure → fail-safe skip (no blind action)
    try:
        markers = json.loads(r.stdout) or []
    except Exception:
        return
    acted = 0
    for m in markers:
        if acted >= ORPHAN_MAX_PER_SWEEP:
            break
        mid = m.get("id")
        if not mid:
            continue
        if _label_value(m, "gate-status:") not in ("queued", "ready", "claimed"):
            continue
        age = int(now - (_iso_epoch(m.get("updated_at")) or now))
        src = _label_value(m, "source-bead:")
        rig = _label_value(m, "bead-rig:") or _label_value(m, "rig:")
        resolved, closed, reviewing, store = _source_review_state(src, rig)
        branch = _label_value(m, "branch:")
        # Pay for the git-ancestry check ONLY when the source is CLOSED — the sole case
        # where 'source closed' could be a FALSE 'merged' (the sling-task-janitor closes
        # fix-task beads without the branch landing). Otherwise it's irrelevant.
        branch_state = _branch_merged_state(branch, rig) if (resolved and closed) else "unknown"
        v = orphan_marker_verdict(age, ORPHAN_MARKER_MIN_MINUTES * 60, resolved, closed,
                                  reviewing, branch_state)
        if v in ("wait", "keep"):
            continue
        if GRW_DRY_RUN:
            print("[watchdog] FIX4 DRY would %s marker=%s src=%s age=%dm" % (v, mid, src, age // 60), flush=True)
            _recovery_ledger("would_" + v.replace("-", "_"),
                             {"marker": mid, "source_bead": src, "age_min": age // 60, "dry_run": True})
            acted += 1
            continue
        if v == "recover-stranded":
            # Source CLOSED but branch NOT merged → a FALSE 'merged' close stranded a
            # complete fix (ga-w5agg/ga-d2jil). Re-land it: reopen the source (so the
            # janitor/dispatcher treat it as live) + re-queue the marker so a fresh sweep
            # re-reviews and merges. NEVER close a marker whose fix hasn't landed.
            if src:
                sh(["bd", "-C", store, "update", src, "--status", "open"], timeout=20)
            set_gate_status_py(mid, "queued")
            sh(["bd", "-C", CITY, "comment", mid,
                "gate-recovery-watchdog FIX4-recover: source %s is CLOSED but branch %s is NOT merged into origin/main — a false-'merged' close (the janitor orphaned the fix-task without it landing). Reopened the source + re-queued so the fix RE-LANDS instead of being stranded. (the ga-w5agg/ga-d2jil class)" % (src, branch or "?")], timeout=25)
            _recovery_ledger("recover_stranded_marker", {"marker": mid, "source_bead": src,
                             "branch": branch, "age_min": age // 60})
            notify("Gate self-heal: fix ENCALHADO recuperado (marker %s — fonte %s fechada mas branch %s NÃO-mergeado) — reaberto + re-enfileirado. Você não precisa agir." % (mid, src, branch or "?"), 3)
            print("[watchdog] FIX4-recover RE-LANDED stranded marker=%s (source %s closed but branch %s unmerged) — reopened+requeued" % (mid, src, branch), flush=True)
        elif v == "close-source-done":
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid, "-r",
                "source bead %s CLOSED and branch %s VERIFIED merged/absent (grw FIX4 phantom-depth self-heal — merge confirmed via git ancestry, not assumed from a closed source)" % (src, branch or "?")], timeout=25)
            _recovery_ledger("close_orphan_marker", {"marker": mid, "source_bead": src, "branch": branch, "branch_state": branch_state, "age_min": age // 60})
            notify("Gate self-heal: marker órfão fechado (%s — fonte %s concluída, merge confirmado). Profundidade-fantasma removida." % (mid, src), 3)
            print("[watchdog] FIX4 CLOSED orphan marker=%s (source %s closed, branch %s, %dm) — phantom depth removed" % (mid, src, branch_state, age // 60), flush=True)
        else:  # clear-stale-reviewing
            sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
            sh(["bd", "-C", store, "comment", src,
                "grw FIX4: cleared STALE gate:reviewing (marker %s sat QUEUED %dm while source carried gate:reviewing — a reviewer drained during startup and left the label, no terminal path cleared it). The dispatcher can re-dispatch this branch now (was head-of-line starved)." % (mid, age // 60)], timeout=20)
            _recovery_ledger("clear_stale_reviewing", {"marker": mid, "source_bead": src, "store": store, "age_min": age // 60})
            notify("Gate self-heal: gate:reviewing fantasma limpo em %s (marker %s estava faminto %dmin). Volta a despachar." % (src, mid, age // 60), 3)
            print("[watchdog] FIX4 CLEARED stale gate:reviewing on %s (marker %s starved %dm) — starvation self-heal" % (src, mid, age // 60), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX4 orphan/stale sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def stale_review_marker_verdict(status, age_sec, min_sec, has_open_run):
    """PURE decision (no I/O, unit-tested) for FIX 6, on an OPEN gate-marker whose
    gate-status is dispatching|reviewing:
      'requeue'                — sits dispatching|reviewing past min_sec with NO open
                                 running run (reviewer dead, no hung RUN for FIX 1/5 to
                                 own) → requeue so the dispatcher re-reviews the branch.
      'wait'                   — younger than min_sec (normal dispatch→run-create spin-up).
      'skip:not-review-status' — not a dispatching|reviewing marker (FIX 4 owns queued/
                                 ready/claimed; every other state is terminal).
      'skip:live-run'          — an open running run exists for it → FIX 1/5 own the reap;
                                 FIX 6 never double-handles a live/hung review.
      'skip:run-query-failed'  — has_open_run is None (the run query failed) → fail-safe,
                                 NEVER requeue blind (a Dolt glitch must not duplicate a
                                 live review by falsely concluding 'no run')."""
    if status not in ("dispatching", "reviewing"):
        return "skip:not-review-status"
    if age_sec < min_sec:
        return "wait"
    if has_open_run is None:
        return "skip:run-query-failed"
    if has_open_run:
        return "skip:live-run"
    return "requeue"


def _markers_with_open_run(runs):
    """Set of marker_ids that currently have an OPEN gate-status:running gate-run
    (parsed from each run's `marker_id:` description field). None if runs is None
    (query failure) so the caller fail-safe treats liveness as UNKNOWN and skips."""
    if runs is None:
        return None
    out = set()
    for run in runs:
        mid = _parse_run_field(run.get("description") or "", "marker_id")
        if mid:
            out.add(mid)
    return out


def reap_stale_review_markers(now, rstate):
    """FIX 6: requeue a marker STRANDED at gate-status:dispatching|reviewing whose
    reviewer DIED leaving NO open running run — the wa-ppe5v orphan (the Pilot counts
    dispatching|reviewing as active and DROPS the gate:needs-fix source forever). Each
    sweep, for an open dispatching|reviewing marker older than STALE_REVIEW_MARKER_MINUTES
    with NO open running run (confirmed across a resample): requeue → gate-status:queued
    (the dispatcher re-reviews the EXISTING branch, no rebuild) + clear the source's
    leaked gate:reviewing. A per-marker attempt cap escalates to needs-human. Bounded,
    dry-run-aware, fully fail-safe (unreadable → skip; a live/hung run → defer to FIX 1/5)."""
    if not GRW_ENABLED or not GRW_REAP_STALE_REVIEW_ENABLED:
        return
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
            "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return  # query failure → fail-safe skip (no blind action)
    try:
        markers = json.loads(r.stdout) or []
    except Exception:
        return
    open_run_markers = _markers_with_open_run(_open_running_runs())
    acted = 0
    for m in markers:
        if acted >= STALE_REVIEW_MAX_PER_SWEEP:
            break
        mid = m.get("id")
        if not mid:
            continue
        status = _label_value(m, "gate-status:")
        if status not in ("dispatching", "reviewing"):
            continue
        age = int(now - (_iso_epoch(m.get("updated_at")) or now))
        has_open_run = None if open_run_markers is None else (mid in open_run_markers)
        v = stale_review_marker_verdict(status, age, STALE_REVIEW_MARKER_MINUTES * 60, has_open_run)
        if v != "requeue":
            if GRW_DRY_RUN and v != "skip:not-review-status":
                print("[watchdog] FIX6 DRY skip marker=%s status=%s age=%dm (%s)"
                      % (mid, status, age // 60, v), flush=True)
            continue
        # SUSTAINED-confirm: a dispatch CREATING its run right now (or a transient
        # run-query blip) will show an open run — or the marker will have advanced —
        # on a second sample after a short gap → abort. Never requeue a live review.
        time.sleep(LIVENESS_RESAMPLE_SEC)
        open_run_markers2 = _markers_with_open_run(_open_running_runs())
        if open_run_markers2 is None or (mid in open_run_markers2):
            print("[watchdog] FIX6 marker=%s NOT requeued after resample (run appeared / query failed) — fail-safe KEPT"
                  % mid, flush=True)
            continue
        status2 = _label_value({"labels": _bead_labels(mid)}, "gate-status:")
        if status2 not in ("dispatching", "reviewing"):
            print("[watchdog] FIX6 marker=%s advanced to '%s' during resample — fail-safe KEPT"
                  % (mid, status2 or "?"), flush=True)
            continue
        src = _label_value(m, "source-bead:")
        rig = _label_value(m, "bead-rig:") or _label_value(m, "rig:")
        branch = _label_value(m, "branch:")
        attempts = 0
        for lb in (m.get("labels") or []):
            mm = GRW_STALE_REVIEW_LABEL_RE.match(str(lb))
            if mm:
                try:
                    attempts = int(mm.group(1))
                except Exception:
                    attempts = 0
        resolved, sclosed, reviewing, store = _source_review_state(src, rig)
        if GRW_DRY_RUN:
            print("[watchdog] FIX6 DRY would %s STALE %s marker=%s src=%s age=%dm attempts=%d"
                  % ("ESCALATE" if attempts >= STALE_REVIEW_MAX_ATTEMPTS else "requeue",
                     status, mid, src, age // 60, attempts), flush=True)
            _recovery_ledger("would_requeue_stale_review_marker",
                             {"marker": mid, "source_bead": src, "status": status,
                              "age_min": age // 60, "attempts": attempts, "dry_run": True})
            acted += 1
            continue
        if attempts >= STALE_REVIEW_MAX_ATTEMPTS:
            # reviewers keep dying on this branch → stop re-reviewing, hand to a human.
            set_gate_status_py(mid, "parked-needs-human")
            sh(["bd", "-C", CITY, "comment", mid,
                "gate-recovery-watchdog FIX6: marker re-stranded at %s %d× (reviewers keep dying mid-review, no run) on branch %s — escalating to parked-needs-human instead of another futile re-review. Cleared the phantom gate:reviewing so the Pilot stops seeing a live review. (grw stale-review cap)"
                % (status, attempts, branch or "?")], timeout=25)
            if resolved and reviewing:
                sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
            _recovery_ledger("escalate_stale_review_marker",
                             {"marker": mid, "source_bead": src, "status": status,
                              "attempts": attempts, "branch": branch})
            if rstate.escalate_once("stale-review-osc:%s" % mid, now):
                notify("🚨 Gate: marker %s encalhou em %s %d× (revisor morre repetido, sem run) — parkeado p/ needs-human. Precisa de você (branch %s)."
                       % (mid, status, attempts, branch or "?"), 5)
                _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                            "bead_id": src or "", "reason": "stale-review marker %s re-stranded %d× (reviewers keep dying, no run) — parked needs-human" % (mid, attempts)}, fail_open=True)
            print("[watchdog] FIX6 ESCALATED marker=%s (re-stranded %d× at %s) → parked-needs-human"
                  % (mid, attempts, status), flush=True)
            acted += 1
            continue
        # 1) stamp the restart-safe counter FIRST (a crash mid-op must not lose the
        #    oscillation history and loop forever), then requeue the marker → the
        #    dispatcher re-reviews the EXISTING branch (no rebuild).
        for lb in (m.get("labels") or []):
            if GRW_STALE_REVIEW_LABEL_RE.match(str(lb)):
                sh(["bd", "-C", CITY, "label", "remove", mid, str(lb), "-q"])
        sh(["bd", "-C", CITY, "label", "add", mid, "grw-stale-review:%d" % (attempts + 1), "-q"])
        set_gate_status_py(mid, "queued")
        sh(["bd", "-C", CITY, "comment", mid,
            "gate-recovery-watchdog FIX6: marker sat gate-status:%s %dm with NO open running run (reviewer died mid-review — drain/sleep/quota/crash — leaving no hung RUN for FIX 1/5). Re-queued so a fresh dispatcher sweep re-reviews branch %s (the existing fix, no rebuild). The Pilot was DROPPING the gate:needs-fix source %s as 'actively gating' on this dead marker (wa-ppe5v). attempt %d/%d."
            % (status, age // 60, branch or "?", src or "?", attempts + 1, STALE_REVIEW_MAX_ATTEMPTS)], timeout=25)
        # 2) clear the source's leaked gate:reviewing (the phantom 'em revisão').
        cleared_reviewing = False
        if resolved and reviewing:
            sh(["bd", "-C", store, "label", "remove", src, "gate:reviewing", "-q"], timeout=20)
            cleared_reviewing = True
        _recovery_ledger("requeue_stale_review_marker",
                         {"marker": mid, "source_bead": src, "status": status, "age_min": age // 60,
                          "attempt": attempts + 1, "cleared_gate_reviewing": cleared_reviewing, "branch": branch})
        notify("Gate self-heal: marker travado em %s reapado (%s, %dmin, revisor morto sem run) — re-enfileirado p/ re-revisão. Você não precisa agir."
               % (status, mid, age // 60), 3)
        print("[watchdog] FIX6 REQUEUED stale %s marker=%s src=%s age=%dm attempt=%d cleared_reviewing=%s"
              % (status, mid, src, age // 60, attempts + 1, cleared_reviewing), flush=True)
        acted += 1
    if acted:
        print("[watchdog] FIX6 stale-review sweep: %d marker(s) requeued/escalated%s"
              % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def _open_error_markers():
    """[marker dicts] type:quality-gate-marker + gate-status:error + open, in HQ (the
    dispatcher's domain — it only re-processes HQ queued markers). None on query
    failure (fail-safe skip)."""
    r = sh(["bd", "-C", CITY, "list", "--all", "-l", "type:quality-gate-marker",
            "-l", "gate-status:error", "--status", "open", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout) or []
    except Exception:
        return None


def requeue_error_markers(now, rstate):
    """FIX 2: auto-requeue a STUCK gate-status:error marker (error → queued) — the
    error→queued flip the Mayor did by hand ~6x today. Bounded per sweep, dry-run
    aware, fully fail-safe. Carve-outs: a marker whose SOURCE BEAD is closed is
    closed (not requeued); a ga-acb needs-human park is left alone; a marker that
    keeps re-erroring past ERROR_REQUEUE_MAX_ATTEMPTS is escalated to the Mayor
    instead of looped forever."""
    if not GRW_ENABLED or not GRW_REQUEUE_ERROR_ENABLED:
        return
    markers = _open_error_markers()
    if markers is None:
        print("[watchdog] requeue: error-marker query unavailable — fail-safe skip", flush=True)
        return
    # oldest-error first (created_at asc) so the longest-stuck marker is served first
    markers.sort(key=lambda m: _iso_epoch(m.get("created_at")) or 0.0)
    acted = 0
    for mk in markers:
        if acted >= ERROR_REQUEUE_MAX_PER_SWEEP:
            break
        mid = mk.get("id")
        if not mid:
            continue
        upd = _iso_epoch(mk.get("updated_at")) or _iso_epoch(mk.get("created_at"))
        age = int(now - upd) if upd else 0
        labels = mk.get("labels") or []
        source_bead = _label_value(mk, "source-bead:")
        rig_name = _label_value(mk, "bead-rig:")
        branch = _label_value(mk, "branch:")
        label_count = 0
        for l in labels:
            m = GRW_REQUEUE_LABEL_RE.match(l)
            if m:
                try:
                    label_count = int(m.group(1))
                except Exception:
                    label_count = 0
        req_count = max(label_count, rstate.error_requeues.get(mid, 0))
        resolved, sclosed, needs_human = _source_bead_state(source_bead, rig_name)
        verdict = error_requeue_verdict(age, ERROR_REQUEUE_MINUTES * 60, resolved,
                                        sclosed, needs_human, req_count, ERROR_REQUEUE_MAX_ATTEMPTS)

        if verdict == "skip:young":
            continue
        if verdict == "skip:parked-needs-human":
            if rstate.escalate_once("error-parked:%s" % mid, now):
                print("[watchdog] error marker %s parked (source %s needs-human) — left for human (grw)"
                      % (mid, source_bead), flush=True)
            continue

        if verdict == "close:source-done":
            if GRW_DRY_RUN:
                print("[watchdog] requeue DRY-RUN would CLOSE error marker %s (source bead %s closed — work done)"
                      % (mid, source_bead), flush=True)
                _recovery_ledger("would_close_done_marker", {"marker": mid, "source_bead": source_bead, "branch": branch, "dry_run": True})
                acted += 1
                continue
            set_gate_status_py(mid, "superseded")
            sh(["bd", "-C", CITY, "close", mid,
                "-r", "source bead %s closed — gate work done/abandoned; error marker superseded (grw error-marker self-heal)" % source_bead], timeout=25)
            _recovery_ledger("closed_done_marker", {"marker": mid, "source_bead": source_bead, "branch": branch})
            print("[watchdog] CLOSED done error marker %s (source %s closed)" % (mid, source_bead), flush=True)
            acted += 1
            continue

        if verdict == "escalate:oscillating":
            if rstate.escalate_once("error-osc:%s" % mid, now):
                notify("🚨 Gate: marker %s (branch %s) re-erra em loop — já re-enfileirei %dx e continua falhando. Precisa de você (não é transiente). (grw)"
                       % (mid, branch or "?", req_count), 5)
                _grw_ledger("human-touch", {"ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
                            "source_daemon": "gate-recovery-watchdog", "stage": "revisa", "kind": "technical",
                            "bead_id": source_bead or "", "reason": "error marker %s oscillating (%d watchdog requeues, still re-errors) — needs human" % (mid, req_count)}, fail_open=True)
                print("[watchdog] ESCALATED oscillating error marker %s (%d requeues, still re-errors) — NOT requeued again" % (mid, req_count), flush=True)
            continue

        # verdict == "requeue"
        if GRW_DRY_RUN:
            print("[watchdog] requeue DRY-RUN would re-queue error marker %s (branch %s, %dm in error, attempt %d/%d) → gate-status:queued"
                  % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), flush=True)
            _recovery_ledger("would_requeue_error", {"marker": mid, "branch": branch, "age_min": age // 60,
                             "attempt": req_count + 1, "dry_run": True})
            acted += 1
            continue
        # stamp the restart-safe counter FIRST (so a crash mid-op cannot lose the
        # oscillation history and loop forever), then flip error→queued.
        for l in labels:
            if GRW_REQUEUE_LABEL_RE.match(l):
                sh(["bd", "-C", CITY, "label", "remove", mid, l, "-q"])
        sh(["bd", "-C", CITY, "label", "add", mid, "grw-requeue:%d" % (req_count + 1), "-q"])
        rstate.error_requeues[mid] = req_count + 1
        set_gate_status_py(mid, "queued")
        sh(["bd", "-C", CITY, "comment", mid,
            "gate-recovery-watchdog: auto-requeued gate-status:error→queued after %dm stuck in error (attempt %d/%d). A transient dispatcher error/ghost-yield/reclaim left this marker stranded; the dispatcher only re-processes queued markers. (grw error-marker self-heal — the manual error→queued the Mayor did ~6x/day)"
            % (age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS)], timeout=25)
        _recovery_ledger("requeue_error", {"marker": mid, "branch": branch, "source_bead": source_bead,
                         "age_min": age // 60, "attempt": req_count + 1})
        notify("Gate self-heal: marker %s re-enfileirado (error→queued, branch %s, %dmin travado, tentativa %d/%d). Você não precisa agir."
               % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), 3)
        print("[watchdog] REQUEUED error marker %s (branch %s, %dm, attempt %d/%d)"
              % (mid, branch or "?", age // 60, req_count + 1, ERROR_REQUEUE_MAX_ATTEMPTS), flush=True)
        acted += 1
    if acted:
        print("[watchdog] error-requeue sweep: %d marker(s) actioned%s" % (acted, " (DRY_RUN)" if GRW_DRY_RUN else ""), flush=True)


def main():
  # ---- state ----
  gov = Governor()       # dedup + concurrent cap + per-condition cooldown/back-off
  rstate = RecoveryState()  # direct self-heal: per-marker requeue count + escalate-once
  saw_gate = False       # we dispatched at least one gate-down repair since last recovery
  saw_pilot = False
  saw_loop = False
  saw_sup = False
  saw_orphan = False
  last_gate_spawn = 0
  last_pilot_spawn = 0
  last_loop_spawn = 0
  last_orphan_spawn = 0

  print("[watchdog] gate+pilot watchdog started — governed repair-agent spawner "
        "(dedup + cap=%d + per-condition back-off + self-limit=%d; enabled=%s dry_run=%s) "
        "on gate-down OR pilot-jam OR head-of-line block OR supervisor init-failure OR orphaned queued marker"
        % (MAX_ACTIVE_REPAIR_DOGS, MAX_SPAWNS_PER_CONDITION, GRW_ENABLED, GRW_DRY_RUN), flush=True)
  print("[watchdog] + DIRECT self-heal each sweep: reap HUNG reviewers (run>%dm, 0 verdicts, dead reviewer sustained; enabled=%s) "
        "AND recover STRANDED-VERDICT runs (run>%dm, all verdicts delivered but stuck running/unfinalized, cap %d attempts; enabled=%s) "
        "AND kill FROZEN reviewers (active-but-last_active-silent>%ds, cap %d/sweep, sustained-confirmed; enabled=%s) "
        "AND reap ORPHAN/STALE markers (queued>%dm w/ source closed→close, or leaked gate:reviewing→clear, cap %d/sweep; enabled=%s) "
        "AND requeue STRANDED dispatching|reviewing markers w/ NO open run (dead reviewer, >%dm, cap %d/sweep, esc after %d; enabled=%s) "
        "AND auto-requeue STUCK gate-status:error markers (>%dm in error, cap %d/sweep, osc-escalate after %d; enabled=%s). "
        "All bounded + fail-safe + dry_run=%s."
        % (REVIEW_HANG_MINUTES, GRW_REAP_HUNG_ENABLED, STRANDED_RUN_MINUTES, STRANDED_MAX_ATTEMPTS, GRW_REAP_STRANDED_ENABLED,
           FROZEN_KILL_SECS, FROZEN_KILL_MAX_PER_SWEEP, GRW_REAP_FROZEN_ENABLED,
           ORPHAN_MARKER_MIN_MINUTES, ORPHAN_MAX_PER_SWEEP, GRW_REAP_ORPHAN_ENABLED,
           STALE_REVIEW_MARKER_MINUTES, STALE_REVIEW_MAX_PER_SWEEP, STALE_REVIEW_MAX_ATTEMPTS, GRW_REAP_STALE_REVIEW_ENABLED,
           ERROR_REQUEUE_MINUTES, ERROR_REQUEUE_MAX_PER_SWEEP, ERROR_REQUEUE_MAX_ATTEMPTS, GRW_REQUEUE_ERROR_ENABLED, GRW_DRY_RUN), flush=True)

  while True:
    try:
        now = time.time()
        # One session-list query per loop, shared by every detector's governor check
        # (replaces the per-block coarse cooldown; bounds this daemon's own gc load).
        sessions = _session_list_json()
        lp = last_pass_epoch()

        # ===== DIRECT SELF-HEAL (no dog, no Mayor) — runs EVERY sweep, independent
        # of the infra-throttle gate below (these are cheap bounded bd mutations that
        # DIRECTLY heal the two toils the Mayor fixed by hand; a reap FREES load, and
        # if Dolt is wedged the queries fail → fail-safe skip). Each is fully guarded.
        try:
            reap_hung_runs(sessions, now, rstate)
        except Exception as e:
            print("[watchdog] reap_hung_runs error (continuing): %r" % e, flush=True)
        try:
            reap_stranded_verdict_runs(now)
        except Exception as e:
            print("[watchdog] reap_stranded_verdict_runs error (continuing): %r" % e, flush=True)
        try:
            reap_frozen_reviewers(sessions, now)
        except Exception as e:
            print("[watchdog] reap_frozen_reviewers error (continuing): %r" % e, flush=True)
        try:
            reap_orphan_and_stale_markers(now)
        except Exception as e:
            print("[watchdog] reap_orphan_and_stale_markers error (continuing): %r" % e, flush=True)
        try:
            reap_stale_review_markers(now, rstate)
        except Exception as e:
            print("[watchdog] reap_stale_review_markers error (continuing): %r" % e, flush=True)
        try:
            requeue_error_markers(now, rstate)
        except Exception as e:
            print("[watchdog] requeue_error_markers error (continuing): %r" % e, flush=True)

        # ga-htjni follow-up (dog investigation 2026-06-15): if the gate is
        # ALIVE-but-infra-throttled (Dolt-hot or quota DEFER), a repair dog cannot
        # fix CPU/quota — suppress the three GATE-repair detectors (gate:down /
        # head-of-line / orphan) this cycle so we stop spawning futile taskless
        # dogs. Pilot + supervisor detectors are unaffected (different conditions).
        # A truly wedged dispatcher has a stale log → infra=False → detectors fire.
        infra = gate_infra_throttled()
        if infra:
            print("[watchdog] gate infra-throttled (Dolt-hot/quota DEFER) — alive but throttled; "
                  "skipping gate-repair detectors this cycle (a dog can't fix infra).", flush=True)

        # ===== gate down: 2+ timeouts OR a marker stuck dispatching w/ no reviewers =====
        n_to, last_to = recent_timeouts()
        stuck = stuck_dispatching()
        problem = ((n_to >= 2) or stuck) and not infra
        if saw_gate and lp and lp > last_gate_spawn:
            print("[watchdog] gate recovered (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate recuperou (agente de reparo/Mayor) — voltou a passar revisões. Tudo certo.", 3)
            gov.reset_prefix("gate:"); saw_gate = False
        if problem:
            reason = ("%d timeouts em %dmin" % (n_to, TIMEOUT_WINDOW_SEC // 60)) if n_to >= 2 \
                     else "marcador dispatching travado sem revisores ativos"
            dolt_hits = dolt_instability()
            diag = snapshot(reason, dolt_hits)
            how = governed_spawn(gov, sessions, now, "gate", reason, diag, dolt_hits, "Gate travou")
            if how is not None:
                last_gate_spawn = now; saw_gate = True

        # --- PILOT coverage (closes the gap that hid the 2026-06-08 ~8h jam) ---
        pj, pj_reason = pilot_jammed()
        if saw_pilot and not pj:
            print("[watchdog] pilot recovered — resetting", flush=True)
            notify("Pilot voltou a despachar — resolvido.", 3)
            gov.reset_prefix("pilot:"); saw_pilot = False
        if pj:
            pdiag = snapshot(pj_reason, 0)
            phow = governed_spawn(gov, sessions, now, "pilot", pj_reason, pdiag, 0, "Pilot travou")
            if phow is not None:
                last_pilot_spawn = now; saw_pilot = True

        # --- HEAD-OF-LINE block (closes the ga-hl0gq blind spot: 49min undetected) ---
        hb, hcount = headofline_stall()
        if saw_loop and lp and lp > last_loop_spawn:
            print("[watchdog] head-of-line cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate destravou — fila voltou a drenar (head-of-line resolvido).", 3)
            gov.reset_prefix("gate-loop:"); saw_loop = False
        if hb and not infra:
            ldiag = snapshot("head-of-line block: %dx QUEUED-retry no branch %s" % (hcount, hb), 0)
            lhow = governed_spawn(gov, sessions, now, "gate-loop", hb, ldiag, 0,
                                  "Gate preso em branch stale (head-of-line)", branch=hb)
            if lhow is not None:
                last_loop_spawn = now; saw_loop = True

        # --- SUPERVISOR init-failure loop (closes the ga-h3w2y blind spot:
        #     a rig with no path in site.toml → spawn-outage town-wide, ~1h to
        #     find by hand). First-class durable signal; the proactive guard is
        #     supervisor-config-guard, this is the always-on backstop. ---
        sup_reason, sup_detail = supervisor_init_failure()
        if saw_sup and not sup_reason:
            print("[watchdog] supervisor recovered (config valid, no init-failure loop) — resetting", flush=True)
            notify("Supervisor voltou — config válido e spawn normalizado.", 3)
            gov.reset_prefix("supervisor:"); saw_sup = False
        if sup_reason:
            sdiag = snapshot("%s | config inválido: %s" % (sup_reason, sup_detail), 0)
            # 3rd positional carries the config-invalid detail for the kind=supervisor task
            show = governed_spawn(gov, sessions, now, "supervisor", sup_reason, sdiag, sup_detail,
                                  "Supervisor em init-failure (spawn-outage)")
            if show is not None:
                saw_sup = True

        # --- ORPHANED queued marker (closes the gt-mqkwj blind spot: a marker
        #     whose gate_run was dropped in an outage is leapfrogged forever →
        #     bead stuck in_progress → reconciler re-spawns a worker ~6x). The
        #     leapfrog proof + FIFO-head guard keep a normal backlog / head-of-line
        #     block from false-firing (the 6x-same-marker driver). ---
        orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()
        if saw_orphan and lp and lp > last_orphan_spawn:
            print("[watchdog] orphaned marker cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Marker órfão resolvido — gate voltou a passar (gt-mqkwj).", 3)
            gov.reset_prefix("gate-orphan:"); saw_orphan = False
        if orphan_id and not infra:
            odiag = snapshot("orphaned queued marker %s (branch %s, %dmin sem despacho)"
                             % (orphan_id, orphan_branch, orphan_age // 60), 0)
            # reason=branch (title), marker id carried for the runbook + dedup key
            ohow = governed_spawn(gov, sessions, now, "gate-orphan", orphan_branch, odiag, orphan_id,
                                  "Marker órfão (run derrubado num outage)",
                                  marker_id=orphan_id, branch=orphan_branch)
            if ohow is not None:
                last_orphan_spawn = now; saw_orphan = True
    except Exception as e:
        print("[watchdog] loop error (continuing): %r" % e, flush=True)
    time.sleep(POLL_SEC)


def _selftest():
    """Pure-logic regression checks for FIX 3/4/5/6 (no I/O). Run: --selftest."""
    p = f = 0
    def ok(c, m):
        nonlocal p, f
        if c: p += 1; print("  ✓", m)
        else: f += 1; print("  ✗", m)
    # frozen_reviewer_verdict — the kill/keep core
    ok(frozen_reviewer_verdict("active", 900, 900) == "kill", "active + silent==threshold → kill")
    ok(frozen_reviewer_verdict("active", 2040, 900) == "kill", "active + silent 34m (the live incident) → kill")
    ok(frozen_reviewer_verdict("active", 300, 900) == "keep", "active + silent 5m (< threshold) → keep")
    ok(frozen_reviewer_verdict("asleep", 5000, 900) == "keep", "non-active state → keep (hung-run reaper/dispatcher own it)")
    ok(frozen_reviewer_verdict("active", None, 900) == "keep", "unparseable silence → keep (fail-safe)")
    ok(frozen_reviewer_verdict("active", -10, 900) == "keep", "future last_active (negative silence) → keep (fail-safe)")
    ok(frozen_reviewer_verdict("", 5000, 900) == "keep", "empty state → keep")
    # _last_active_epoch — must parse the tz-OFFSET form (session JSON), not just UTC-Z
    ok(_last_active_epoch("2026-07-02T16:06:29-03:00") is not None, "tz-offset last_active parses (the session-JSON form)")
    ok(_last_active_epoch("2026-07-02T19:06:29Z") is not None, "UTC-Z last_active parses too")
    ok(_last_active_epoch("") is None and _last_active_epoch("garbage") is None, "empty/garbage → None (never frozen)")
    # the two forms above name the SAME instant → equal epochs (offset math correct)
    a = _last_active_epoch("2026-07-02T16:06:29-03:00"); b = _last_active_epoch("2026-07-02T19:06:29Z")
    ok(a is not None and b is not None and abs(a - b) < 1, "-03:00 and its UTC-Z equivalent map to the same epoch")
    # FIX 4 — orphan_marker_verdict (queued-marker cleanup; now branch-merge-aware)
    M = 15 * 60
    ok(orphan_marker_verdict(9 * 60, M, True, True, True, "merged") == "wait", "young marker (9m<15m) → wait (spin-up race window)")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "merged") == "close-source-done", "old + source CLOSED + branch MERGED → close orphan")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "missing") == "close-source-done", "old + source CLOSED + branch MISSING (abandoned) → close orphan")
    ok(orphan_marker_verdict(600 * 60, M, True, True, True, "merged") == "close-source-done", "closed+merged WINS over reviewing (done regardless)")
    # the ga-w5agg/ga-d2jil bug: source closed by janitor but branch NOT merged → NEVER false-close
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "unmerged") == "recover-stranded", "old + source CLOSED but branch UNMERGED → recover, NEVER false-close (the ga-w5agg/ga-d2jil bug)")
    ok(orphan_marker_verdict(600 * 60, M, True, True, False, "unknown") == "keep", "source closed but branch state UNKNOWN → keep (fail-safe, never blind-close as merged)")
    ok(orphan_marker_verdict(572 * 60, M, True, False, True) == "clear-stale-reviewing", "old + source OPEN + gate:reviewing → clear stale (the wa-ya17c case)")
    ok(orphan_marker_verdict(572 * 60, M, True, False, False) == "keep", "old + source open + no reviewing → keep (nothing stale)")
    ok(orphan_marker_verdict(600 * 60, M, False, False, False) == "keep", "source UNREADABLE → keep (fail-safe, never blind-close)")
    # FIX 5 — stranded_verdict_verdict (delivered==total stuck run recovery)
    S = 15 * 60
    ok(stranded_verdict_verdict(9 * 60, S, 1, 1) == "skip:young", "young run (9m<15m) → skip (a finalize is seconds after last verdict)")
    ok(stranded_verdict_verdict(38 * 60, S, 1, 1) == "recover", "old + 1/1 delivered → recover (the wa-99jug case)")
    ok(stranded_verdict_verdict(38 * 60, S, 3, 3) == "recover", "old + 3/3 delivered → recover")
    ok(stranded_verdict_verdict(38 * 60, S, 0, 1) == "skip:collecting", "0/1 delivered → skip (still collecting — a real in-progress review)")
    ok(stranded_verdict_verdict(38 * 60, S, 1, 3) == "skip:collecting", "1/3 delivered → skip (partial — not fully terminal-ready)")
    ok(stranded_verdict_verdict(38 * 60, S, 0, 0) == "skip:not-a-run", "0 verdict beads → skip (guard claim-tracking run, not a review)")
    ok(stranded_verdict_verdict(38 * 60, S, -1, -1) == "skip:query-failed", "unreadable verdict counts → skip (never act blind)")
    # boundary: FIX 1 (delivered==0) and FIX 5 (delivered==total) are mutually exclusive
    ok(stranded_verdict_verdict(38 * 60, S, 0, 2) != "recover", "delivered==0 is FIX 1's domain, NOT FIX 5 (no double-handling)")
    # FIX 6 — stale_review_marker_verdict (dispatching|reviewing marker, dead reviewer, NO run)
    R = 15 * 60
    ok(stale_review_marker_verdict("reviewing", 9 * 60, R, False) == "wait", "young reviewing marker (9m<15m) → wait (dispatch→run-create spin-up)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, False) == "requeue", "old reviewing + NO open run → requeue (the wa-b7z7c dead-reviewer orphan)")
    ok(stale_review_marker_verdict("dispatching", 40 * 60, R, False) == "requeue", "old dispatching + NO open run → requeue (reviewer never materialized)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, True) == "skip:live-run", "reviewing + OPEN running run → skip (FIX 1/5 own it)")
    ok(stale_review_marker_verdict("dispatching", 40 * 60, R, True) == "skip:live-run", "dispatching + open run → skip (a live review, not stale)")
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, None) == "skip:run-query-failed", "run-query failed (None) → skip (never requeue blind on a Dolt glitch)")
    ok(stale_review_marker_verdict("queued", 40 * 60, R, False) == "skip:not-review-status", "queued marker → not FIX 6's domain (FIX 4 owns queued/ready/claimed)")
    ok(stale_review_marker_verdict("passed", 40 * 60, R, False) == "skip:not-review-status", "terminal (passed) marker → skip")
    # boundary: FIX 6 (no run) and FIX 1/5 (open run) partition the dead-reviewer space
    ok(stale_review_marker_verdict("reviewing", 40 * 60, R, True) != "requeue", "an OPEN run is FIX 1/5's domain, NOT FIX 6 (no double-handling)")
    print("gate-recovery-watchdog FIX3+FIX4+FIX5+FIX6 selftest: PASS=%d FAIL=%d" % (p, f))
    return 0 if f == 0 else 1


if __name__ == "__main__":
    if "--selftest" in _sys.argv:
        _sys.exit(_selftest())
    main()

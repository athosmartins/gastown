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


def pilot_jammed():
    """(jammed, reason). Detects the Pilot failing to dispatch — the gap that left a
    jam undetected for ~8h on 2026-06-08. Two modes:
      (a) sweep-abort: 2+ 'aborting dispatch' / 'gc sling failed' lines in the pilot log
          within PILOT_JAM_WINDOW (one bad bead — e.g. accented title — jams every sweep).
      (b) stall: pilot log silent > PILOT_STALL_SEC (Pilot dead / not sweeping)."""
    try:
        mtime = os.path.getmtime(PILOT_LOG)
    except Exception:
        return (False, "")
    if time.time() - mtime > PILOT_STALL_SEC:
        return (True, "Pilot parou de varrer (log silencioso >%dmin) — pode estar morto" % (PILOT_STALL_SEC // 60))
    try:
        with open(PILOT_LOG) as f:
            lines = f.readlines()[-80:]
    except Exception:
        return (False, "")
    now = time.time()
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


def main():
  # ---- state ----
  gov = Governor()       # dedup + concurrent cap + per-condition cooldown/back-off
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

  while True:
    try:
        now = time.time()
        # One session-list query per loop, shared by every detector's governor check
        # (replaces the per-block coarse cooldown; bounds this daemon's own gc load).
        sessions = _session_list_json()
        lp = last_pass_epoch()

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


if __name__ == "__main__":
    main()

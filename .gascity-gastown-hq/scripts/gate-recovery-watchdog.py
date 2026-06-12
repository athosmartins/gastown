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

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
SUPERVISOR_LOG = "/Users/athos/.gc/supervisor.log"
SITE_TOML = os.path.join(CITY, ".gc/site.toml")
NOTIFY = "/Users/athos/.local/bin/notify"
DOG_TEMPLATE = "gastown.dog"   # utility pool the repair agent is spawned into (ga-afytf)
QUOTA_CHECK = os.path.join(CITY, "scripts/claude-quota-check.sh")  # ground-truth quota verdict (ga-wjlv9)

POLL_SEC = 60
TIMEOUT_WINDOW_SEC = 1800      # 2+ timeouts within 30min = gate not producing verdicts
DISPATCH_STUCK_SEC = 720       # marker dispatching >12min w/ no active reviewers = spawn fail
PILOT_JAM_WINDOW_SEC = 900     # 2+ sweep-aborts within 15min = Pilot jammed on a bad bead
PILOT_STALL_SEC = 2400         # pilot log silent >40min = Pilot dead/not sweeping
HEADOFLINE_MIN_SWEEPS = 2      # >=2 consecutive QUEUED-retry sweeps on the SAME branch = head-of-line block
HEADOFLINE_LOG_FRESH_SEC = 600 # ignore if dispatcher log is staler than this (that's ENGINE-STALL's job)
ORPHAN_LOG_FRESH_SEC = 600     # dispatcher log must be live (process still writing) — else ENGINE-STALL's job
ORPHAN_DRAIN_FRESH_SEC = 1200  # newest COMPLETED sweep within 20min = dispatcher actively draining (not wedged on one run)
ORPHAN_MIN_AGE_SEC = 1800      # a queued marker must sit >=30min unmentioned before we call it skipped (rules out a just-created marker)
WAKE_COOLDOWN_SEC = 1200       # don't dispatch a new repair cycle more than once per 20min (per kind)
ESCALATE_AFTER_WAKES = 2       # after 2 unresolved repair-cycles, page Athos 🚨
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
              simply next-up and no newer marker is being worked ahead of it."""
    if not sweep_epochs:
        return []
    if now - max(sweep_epochs) > ORPHAN_DRAIN_FRESH_SEC:
        return []  # dispatcher not actively draining → not this failure mode
    valid = [(mid, b, c) for (mid, b, c) in markers if mid and b and c]
    valid.sort(key=lambda m: m[2])  # oldest first
    orphans = []
    for (mid, branch, created) in valid:
        if now - created < ORPHAN_MIN_AGE_SEC:
            continue
        if branch in log_text:
            continue  # mentioned → being / already dispatched, not orphaned
        leapfrogged = any(c2 > created and b2 != branch and b2 in log_text
                          for (_m2, b2, c2) in valid)
        if not leapfrogged:
            continue
        orphans.append((mid, branch, int(now - created)))
    return orphans


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
    a whole dispatch sweep; the description body carries no such constraint)."""
    safe_reason = reason.encode("ascii", "replace").decode("ascii")
    title = "REPAIR gate-watchdog (%s): %s" % (kind, safe_reason)
    payload = title + "\n\n" + REPAIR_HEADER + repair_runbook(reason, diag_path, dolt_hits, kind)
    r = sh(["gc", "sling", DOG_TEMPLATE, "--stdin", "--json"], stdin=payload, timeout=45)
    routed = r is not None and r.returncode == 0
    s = sh(["gc", "session", "new", DOG_TEMPLATE, "--no-attach",
            "--title-hint", "reparo %s: %s" % (kind, safe_reason[:50])], timeout=45)
    materialized = s is not None and s.returncode == 0
    if materialized:
        return "agente de reparo despachado" + ("" if routed else " (aviso: bead nao enfileirou)")
    # No worker materialized directly — do NOT trust a possibly-wedged reconciler to
    # pick up the routed bead; wake the Mayor as the human-judgment fallback.
    woke = wake_mayor(reason, diag_path, dolt_hits, kind)
    if woke:
        return "reparo enfileirado + Mayor acordado (fallback)" if routed else "Mayor acordado (fallback)"
    return "reparo so enfileirado — sem worker, Mayor ausente" if routed else "FALHA: sem worker e sem Mayor"


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


def main():
  # ---- state ----
  last_wake = 0
  wakes_since_recovery = 0
  last_pass_at_wake = 0
  last_pilot_wake = 0
  pilot_wakes = 0
  last_loop_wake = 0
  loop_wakes = 0
  last_sup_wake = 0
  sup_wakes = 0
  last_orphan_wake = 0
  orphan_wakes = 0

  print("[watchdog] gate+pilot watchdog started — spawns a repair agent (Mayor=fallback) on gate-down OR pilot-jam OR head-of-line block OR supervisor init-failure OR orphaned queued marker", flush=True)

  while True:
    try:
        n_to, last_to = recent_timeouts()
        stuck = stuck_dispatching()
        problem = (n_to >= 2) or stuck

        # recovery: a PASS landed after our last dispatch → reset
        lp = last_pass_epoch()
        if wakes_since_recovery > 0 and lp and lp > last_wake:
            print("[watchdog] gate recovered (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate recuperou (agente de reparo/Mayor) — voltou a passar revisões. Tudo certo.", 3)
            wakes_since_recovery = 0
            last_pass_at_wake = 0

        if problem and (time.time() - last_wake > WAKE_COOLDOWN_SEC):
            reason = ("%d timeouts em %dmin" % (n_to, TIMEOUT_WINDOW_SEC // 60)) if n_to >= 2 \
                     else "marcador dispatching travado sem revisores ativos"
            dolt_hits = dolt_instability()
            diag = snapshot(reason, dolt_hits)
            how = spawn_repair_agent(reason, diag, dolt_hits)   # routes + spawns + Mayor-fallback
            last_wake = time.time()
            wakes_since_recovery += 1

            if wakes_since_recovery >= ESCALATE_AFTER_WAKES:
                # last resort — the prior repair dispatch didn't fix it
                notify("🚨 GATE AINDA QUEBRADO após %dx de reparo autônomo. Precisa de você. Diag: %s"
                       % (wakes_since_recovery, diag), 5)
                print("[watchdog] ESCALATED to Athos (repair failed to recover, %d cycles)" % wakes_since_recovery, flush=True)
            else:
                notify("Gate travou (%s) — %s. Você não precisa agir." % (reason, how), 3)
                print("[watchdog] repair dispatch (%s) reason=%s dolt_hits=%d diag=%s"
                      % (how, reason, dolt_hits, diag), flush=True)

        # --- PILOT coverage (closes the gap that hid the 2026-06-08 ~8h jam) ---
        pj, pj_reason = pilot_jammed()
        if pilot_wakes > 0 and not pj:
            print("[watchdog] pilot recovered — resetting", flush=True)
            notify("Pilot voltou a despachar — resolvido.", 3)
            pilot_wakes = 0
        if pj and (time.time() - last_pilot_wake > WAKE_COOLDOWN_SEC):
            pdiag = snapshot(pj_reason, 0)
            phow = spawn_repair_agent(pj_reason, pdiag, 0, kind="pilot")   # routes + spawns + Mayor-fallback
            last_pilot_wake = time.time()
            pilot_wakes += 1
            if pilot_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 PILOT AINDA TRAVADO após %dx de reparo autônomo. Precisa de você. Diag: %s"
                       % (pilot_wakes, pdiag), 5)
                print("[watchdog] ESCALATED to Athos (pilot jam, %d cycles)" % pilot_wakes, flush=True)
            else:
                notify("Pilot travou (%s) — %s. Você não precisa agir." % (pj_reason, phow), 3)
                print("[watchdog] repair dispatch for PILOT (%s) reason=%s diag=%s"
                      % (phow, pj_reason, pdiag), flush=True)

        # --- HEAD-OF-LINE block (closes the ga-hl0gq blind spot: 49min undetected) ---
        hb, hcount = headofline_stall()
        # recovery: a PASS landed after our last loop dispatch → the queue drained
        if loop_wakes > 0 and lp and lp > last_loop_wake:
            print("[watchdog] head-of-line cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Gate destravou — fila voltou a drenar (head-of-line resolvido).", 3)
            loop_wakes = 0
        if hb and (time.time() - last_loop_wake > WAKE_COOLDOWN_SEC):
            ldiag = snapshot("head-of-line block: %dx QUEUED-retry no branch %s" % (hcount, hb), 0)
            lhow = spawn_repair_agent(hb, ldiag, 0, kind="gate-loop")   # routes + spawns + Mayor-fallback
            last_loop_wake = time.time()
            loop_wakes += 1
            if loop_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 GATE AINDA TRAVADO em branch stale (head-of-line: %s) após %dx de reparo autônomo. Precisa de você. Diag: %s"
                       % (hb, loop_wakes, ldiag), 5)
                print("[watchdog] ESCALATED to Athos (head-of-line %s, %d cycles)" % (hb, loop_wakes), flush=True)
            else:
                notify("Gate preso em branch stale (head-of-line: %s, %dx sweeps) — %s pra destravar (supersede/re-anchor). Você não precisa agir."
                       % (hb, hcount, lhow), 4)
                print("[watchdog] repair dispatch for HEAD-OF-LINE (%s) branch=%s count=%d diag=%s"
                      % (lhow, hb, hcount, ldiag), flush=True)

        # --- SUPERVISOR init-failure loop (closes the ga-h3w2y blind spot:
        #     a rig with no path in site.toml → spawn-outage town-wide, ~1h to
        #     find by hand). First-class durable signal; the proactive guard is
        #     supervisor-config-guard, this is the always-on backstop. ---
        sup_reason, sup_detail = supervisor_init_failure()
        if sup_wakes > 0 and not sup_reason:
            print("[watchdog] supervisor recovered (config valid, no init-failure loop) — resetting", flush=True)
            notify("Supervisor voltou — config válido e spawn normalizado.", 3)
            sup_wakes = 0
        if sup_reason and (time.time() - last_sup_wake > WAKE_COOLDOWN_SEC):
            sdiag = snapshot("%s | config inválido: %s" % (sup_reason, sup_detail), 0)
            # 3rd positional carries the config-invalid detail for the kind=supervisor task
            show = spawn_repair_agent(sup_reason, sdiag, sup_detail, kind="supervisor")   # routes + spawns + Mayor-fallback
            last_sup_wake = time.time()
            sup_wakes += 1
            if sup_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 SUPERVISOR ainda em init-failure (spawn-outage town-wide) após %dx de reparo autônomo: %s. Precisa de você. Diag: %s"
                       % (sup_wakes, sup_detail, sdiag), 5)
                print("[watchdog] ESCALATED to Athos (supervisor init-failure, %d cycles): %s" % (sup_wakes, sup_detail), flush=True)
            else:
                notify("Supervisor em init-failure (spawn-outage: %s) — %s pra restaurar o path do rig. Você não precisa agir."
                       % (sup_detail, show), 4)
                print("[watchdog] repair dispatch for SUPERVISOR (%s) detail=%s diag=%s"
                      % (show, sup_detail, sdiag), flush=True)

        # --- ORPHANED queued marker (closes the gt-mqkwj blind spot: a marker
        #     whose gate_run was dropped in an outage is leapfrogged forever →
        #     bead stuck in_progress → reconciler re-spawns a worker ~6x). The
        #     leapfrog proof keeps a normal FIFO backlog from false-firing. ---
        orphan_id, orphan_branch, orphan_age = orphaned_queued_marker()
        # recovery: a PASS landed after our last orphan dispatch (the re-queued
        # marker ran, or the queue otherwise moved) → reset
        if orphan_wakes > 0 and lp and lp > last_orphan_wake:
            print("[watchdog] orphaned marker cleared (Gate PASSED after repair dispatch) — resetting", flush=True)
            notify("Marker órfão resolvido — gate voltou a passar (gt-mqkwj).", 3)
            orphan_wakes = 0
        if orphan_id and (time.time() - last_orphan_wake > WAKE_COOLDOWN_SEC):
            odiag = snapshot("orphaned queued marker %s (branch %s, %dmin sem despacho)"
                             % (orphan_id, orphan_branch, orphan_age // 60), 0)
            # reason=branch (title), 3rd positional carries the marker id for the runbook
            ohow = spawn_repair_agent(orphan_branch, odiag, orphan_id, kind="gate-orphan")
            last_orphan_wake = time.time()
            orphan_wakes += 1
            if orphan_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 MARKER ÓRFÃO ainda preso (%s, branch %s) após %dx de reparo autônomo. Precisa de você. Diag: %s"
                       % (orphan_id, orphan_branch, orphan_wakes, odiag), 5)
                print("[watchdog] ESCALATED to Athos (orphan marker %s, %d cycles)" % (orphan_id, orphan_wakes), flush=True)
            else:
                notify("Marker órfão (run derrubado num outage): %s branch %s, %dmin sem despacho — %s pra re-queue/supersede. Você não precisa agir."
                       % (orphan_id, orphan_branch, orphan_age // 60, ohow), 4)
                print("[watchdog] repair dispatch for ORPHAN (%s) marker=%s branch=%s age=%ds diag=%s"
                      % (ohow, orphan_id, orphan_branch, orphan_age, odiag), flush=True)
    except Exception as e:
        print("[watchdog] loop error (continuing): %r" % e, flush=True)
    time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()

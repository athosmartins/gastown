#!/usr/bin/env python3
"""Pipeline throughput heartbeat — detects flow==0-under-demand the other monitors miss.

WHY THIS EXISTS (ga-kcb2b). The two existing monitors key on gate FAILURE
SIGNATURES — gate-health-monitor on JSONL events (TIMEOUT, REAL-JAM, GATE-NOMERGE),
gate-recovery-watchdog on dispatcher-log signatures (2+ TIMEOUT, head-of-line,
spawn-outage, >40min pilot-log silence). Both are BLIND to three real failure modes
that slipped every monitor on 2026-06-11:

  (a) Pilot running-but-dispatching-zero. The Pilot keeps sweeping and logs a line
      every sweep, so the watchdog's >40min log-silence detector never trips — yet
      `dispatched=0` sweep after sweep while bugs sit ready and lane slots are free.
  (b) The bare-main false-fail storm. A run can FF-merge to GitHub yet FAIL the
      durable-landing audit (merge SHA not an ancestor of rig-canonical/origin main —
      a shared-remote clobber). Runs COMPLETE, so to a pure outcome-counter it looks
      like flow; nothing merges durably. This needs its OWN log signature.
  (c) Per-session rot. A single in-flight worker (gate-reviewer / dog) can freeze for
      hours with zero transitions while AGGREGATE flow is nonzero, so no flow-based
      check sees it.

DESIGN (adversarially hardened — pure outcome-based is INSUFFICIENT):
  - Built from APPEND-ONLY LOG timestamps (pilot/gate dispatcher logs) and the runtime
    session list — NOT live bead/Dolt queries. A monitor that polls Dolt would wedge
    on the very data-plane stall it is meant to police. (`gc session list` reads the
    supervisor runtime, not Dolt, so it stays safe when Dolt is sick.)
  - Primary signal = FLOW-UNDER-DEMAND, checked independently for each pipeline stage:
      * Pilot dispatch: every completed sweep in the window dispatched 0, the most
        recent sweep HAD candidates (a `Dispatch tier: X (N candidate(s))` line, not
        `No dispatchable candidates`), AND lane slots were free. The slots+demand
        guards prevent false positives on an empty backlog or a saturated pool.
      * Gate merge: zero `Gate PASSED` in the window WHILE queued markers exist AND no
        review is legitimately in-flight younger than its own timeout AND the gate is not
        deliberately throttling reviews via the ga-cw4pm headroom logic (a fresh `Headroom
        DEFER` line — Dolt protection, not a stall; ga-r1u20). The in-flight + throttle
        guards are what stop a single honest 40-minute review, or an intentional Dolt-hot
        deferral, from tripping the alarm.
  - SPECIFIC assertion for the bare-main storm (pure-outcome cannot see it): alert on
    the `Durable-landing ... FAILED / not ancestor` log pattern within the window.
  - Per-session liveness: alert on any ephemeral worker session (gate-reviewer / dog)
    that is active-but-frozen — `last_active` older than the rot threshold.
  - ON ALERT → hand off to the ga-afytf repair-agent mechanism: route the runbook to
    the gastown.dog pool (`gc sling --stdin`) and spawn a dog directly
    (`gc session new --no-attach`) so recovery does not depend on the demand
    reconciler the stall may itself have wedged. Spawns are RATE-LIMITED per kind AND
    globally — the repair agent needs Dolt + `gc prime` to boot, so during saturation
    a swarm of repair dogs would just fail to boot and add load. Mayor/Athos get a
    notify only; escalate 🚨 to Athos only after repeated unresolved cycles.

Recovers silently: when the corresponding flow resumes, that kind's state resets.
Never crashes (every external call guarded); silence = healthy.
"""
import json, time, subprocess, os, re
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _ledger

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
NOTIFY = "/Users/athos/.local/bin/notify"
DOG_TEMPLATE = "gastown.dog"   # utility pool the repair agent is spawned into (ga-afytf)

# ── cadence / thresholds ─────────────────────────────────────────────────────
POLL_SEC = 300                 # throughput cadence (matches Pilot/delivery 5-min sweep)
FLOW_WINDOW_SEC = 1800         # rolling window for flow-under-demand judgements (30min)
MIN_PILOT_SWEEPS = 2           # need >=2 all-zero completes before calling a pilot stall
                               # (filters a single benign lane-race sweep)
REVIEW_FRESH_SEC = 2700        # a gate review with elapsed < this is "legitimately running"
                               # → suppresses the gate-merge stall (a single 45min review
                               # must NOT fire; the gate's own TIMEOUT handles longer)
LOG_FRESH_SEC = 600            # ignore a stage whose log is staler than this — a dead
                               # engine is ENGINE-STALL's job, not throughput's
DURABLE_FAIL_WINDOW_SEC = 1800 # look-back for the durable-landing-FAIL signature
SESSION_ROT_SEC = 7200         # ephemeral worker active+frozen > 2h = rotting
REPAIR_COOLDOWN_SEC = 1200     # per-kind: at most one repair cycle per 20min
GLOBAL_SPAWN_COOLDOWN_SEC = 300  # never spawn two repair agents back-to-back (anti-swarm)
ESCALATE_AFTER = 2             # after N unresolved cycles of a kind, page Athos 🚨
# Anti-flap hysteresis (ga-vym2m / ga-hwhtt). The gate-merge check flapped: it fired
# on a single momentary gap (no `Gate PASSED` in the exact 30min window at the instant
# of the poll) and RECOVERED on the very next tick — proven by every historical spawn in
# the launchd log being immediately followed by `gate-merge recovered — resetting`. The
# gate was draining the whole time (slow under Dolt CPU 247%, ~12min/run), not stalled.
# Require the SAME kind to be detected on CONFIRM_TICKS consecutive ticks before spawning;
# a stall that clears within one poll never spawns a repair dog (AC1).
CONFIRM_TICKS = 2              # consecutive detections required before a repair-spawn
# A heartbeat-spawned repair dog carries this signature in its session title (from the
# `--title-hint "reparo heartbeat: ..."` at spawn). Used as a restart-resilient fallback
# to recognise our own live repair dogs when the in-memory tracked-id set was lost to a
# process restart. Specific enough not to match normal pool dogs ("gastown.dog-N").
REPAIR_DOG_TITLE_RE = re.compile(r"reparo\s+heartbeat", re.I)

# ── log-line patterns (verified against the live dispatchers) ─────────────────
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Pilot sweep complete: dispatched=N (small_slots=X big_slots=Y) ==="
PILOT_COMPLETE_RE = re.compile(
    r"Pilot sweep complete: dispatched=(\d+) \(small_slots=(\d+) big_slots=(\d+)\)")
PILOT_START_RE = re.compile(r"Pilot sweep start")
# "Dispatch tier: <tier> (N candidate(s))" — logged ONLY when backlog>0 (after the
# "No dispatchable candidates ... Exiting" early-return), so it is a clean demand flag.
PILOT_DEMAND_RE = re.compile(r"Dispatch tier: \S+ \((\d+) candidate\(s\)\)")
PILOT_NO_DEMAND = "No dispatchable candidates"
# "Gate PASSED:" and "Gate PASSED (origin=Pilot):" both contain this substring.
GATE_PASS = "Gate PASSED"
GATE_QUEUED_RE = re.compile(r"Found (\d+) queued marker\(s\)")
# "  Verdicts: G/N received (elapsed: Ys)"
VERDICTS_RE = re.compile(r"Verdicts:\s*(\d+)/(\d+)\s*received\s*\(elapsed:\s*(\d+)s\)")
GATE_MERGING = "proceeding to merge branch"
# ga-cw4pm headroom decision (gate's own throttle self-assessment, one per sweep):
#   "Headroom DEFER: gate em N runs (...) — dolt-hot; ceiling=0 reviewers, leaving M
#    marker(s) queued (ga-cw4pm)."   ← consciously NOT admitting a review (Dolt protection)
#   "Headroom OK:    gate em N runs (...) — dolt-calm; ceiling=6 reviewers, admitting a new
#    run (ga-cw4pm)."                ← admitting reviews normally
# A fresh DEFER as the latest decision is throttled-not-stalled (ga-r1u20).
HEADROOM_DECISION_RE = re.compile(r"Headroom (OK|DEFER)\b")
# Durable-landing FAIL signatures (quality-gate-dispatcher.sh ~lines 1840/1846/1857/1863):
#   "Durable-landing AUDIT FAILED: merge <sha> not in rig-canonical main ..."
#   "Durable-landing AUDIT FAILED: merge <sha> not in origin/main ... shared-remote clobber"
#   "Durable-landing: update-ref of bare main -> <sha> FAILED"
#   "Durable-landing: bare main (<sha>) not ancestor of merge (<sha>) — refusing non-FF ref move"
DURABLE_FAIL_RE = re.compile(r"Durable-landing.*(FAILED|not ancestor)")
# Ephemeral worker templates that should finish in minutes — an active one frozen for
# hours is genuinely rotting. Persistent coordinators (mayor/deacon/witness) and crew
# (handled by crew-hang-detector) are deliberately excluded to avoid false positives.
EPHEMERAL_WORKER_TEMPLATES = ("gate-reviewer", "gastown.dog")


def sh(args, timeout=20, stdin=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              input=stdin)
    except Exception:
        return None


def log_ts_epoch(line):
    """Epoch of a dispatcher log line's [YYYY-MM-DD HH:MM:SS] prefix (local time)."""
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def parse_iso_epoch(s):
    """Epoch of an ISO-8601 timestamp, tolerant of 'Z' and '+/-HH:MM' offsets and a
    bare (naive, local) timestamp. Returns None on anything unparseable."""
    if not s:
        return None
    s = s.strip()
    try:
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        dt = __import__("datetime").datetime.fromisoformat(s)
        if dt.tzinfo is None:
            return time.mktime(dt.timetuple())
        return dt.timestamp()
    except Exception:
        return None


def tail_lines(path, n):
    try:
        with open(path) as f:
            return f.readlines()[-n:]
    except Exception:
        return []


def file_fresh(path, max_age=LOG_FRESH_SEC, now=None):
    """True if the file was written within max_age seconds (engine actively logging)."""
    now = now if now is not None else time.time()
    try:
        return (now - os.path.getmtime(path)) <= max_age
    except Exception:
        return False


# ── CHECK A: Pilot dispatching-zero under demand (blind spot a) ───────────────
def pilot_dispatch_stall(now=None):
    """Returns a reason string when the Pilot is running but dispatching nothing while
    work is ready and lane slots are free; else None.

    Signature: within FLOW_WINDOW, every completed sweep dispatched 0 (>=MIN_PILOT_SWEEPS
    of them, to clear a one-off lane race), the most recent sweep HAD candidates
    (a `Dispatch tier: X (N>=1 candidate(s))` line, not `No dispatchable candidates`),
    and that sweep's lane slots were free. Requires a fresh log (a dead Pilot is the
    watchdog's PILOT_STALL job, not ours)."""
    now = now if now is not None else time.time()
    if not file_fresh(PILOT_LOG, now=now):
        return None
    lines = tail_lines(PILOT_LOG, 600)
    if not lines:
        return None

    completes = []  # (epoch, dispatched, small_slots, big_slots, line_index)
    for i, l in enumerate(lines):
        m = PILOT_COMPLETE_RE.search(l)
        if not m:
            continue
        e = log_ts_epoch(l)
        if e is None or now - e > FLOW_WINDOW_SEC:
            continue
        completes.append((e, int(m.group(1)), int(m.group(2)), int(m.group(3)), i))
    if len(completes) < MIN_PILOT_SWEEPS:
        return None
    if any(c[1] > 0 for c in completes):
        return None  # at least one sweep dispatched real work → flow exists

    # All completed sweeps in the window dispatched 0. Inspect the most recent sweep
    # for demand + free slots.
    _, _, s_slots, b_slots, last_idx = completes[-1]
    free_slots = (s_slots > 0) or (b_slots > 0)
    if not free_slots:
        return None  # zero dispatch is CORRECT when the pool is saturated

    # Walk back from the last complete line to its matching sweep start.
    start_idx = 0
    for j in range(last_idx, -1, -1):
        if PILOT_START_RE.search(lines[j]):
            start_idx = j
            break
    sweep = lines[start_idx:last_idx + 1]
    if any(PILOT_NO_DEMAND in l for l in sweep):
        return None  # backlog genuinely empty → not a stall
    demand = 0
    for l in sweep:
        dm = PILOT_DEMAND_RE.search(l)
        if dm:
            demand = max(demand, int(dm.group(1)))
    if demand <= 0:
        return None

    return ("Pilot despachou 0 em %d sweeps consecutivos (%dmin) com %d candidato(s) "
            "prontos e slots livres (small=%d big=%d) — pipeline parado sob demanda"
            % (len(completes), FLOW_WINDOW_SEC // 60, demand, s_slots, b_slots))


# ── CHECK B: Gate not merging under demand (with live-review guard) ───────────
def _fresh_review_in_progress(lines, now):
    """True if the gate is legitimately mid-flight: a Verdicts poll younger than
    REVIEW_FRESH_SEC, a 'proceeding to merge' line, or a partial verdict (G>0) appears
    recently. This is the guard that keeps a single honest long review — or a slow run
    that is still making progress under Dolt load — from tripping the alarm.

    ga-vym2m: scan by TIMESTAMP, not a fixed 40-line tail. Under Dolt CPU saturation the
    dispatcher logs many headroom-defer / retry lines per sweep, so the in-flight review's
    last Verdicts poll routinely scrolls past a 40-line window — which made the guard miss
    a live review and the check false-fire. Walk the recent tail and consider every line
    whose own timestamp is within the freshness horizon; partial verdicts (G>0) recently
    received are themselves proof the run is progressing (verdicts rising X/3, not stuck)."""
    for l in reversed(lines):
        e = log_ts_epoch(l)
        # Stop once we walk past the freshness horizon — lines are chronological, so
        # anything older cannot make the review "fresh" and bounds the scan.
        if e is not None and now - e > REVIEW_FRESH_SEC:
            break
        if GATE_MERGING in l:
            if e and now - e < REVIEW_FRESH_SEC:
                return True
        vm = VERDICTS_RE.search(l)
        if vm:
            got = int(vm.group(1))
            elapsed = int(vm.group(3))
            # A recent poll under its own timeout → review legitimately running. A recent
            # poll that has already received >=1 verdict → run is progressing (draining),
            # not stalled, even if its elapsed is large under Dolt-hot slowness.
            if e and now - e < POLL_SEC * 2 and (elapsed < REVIEW_FRESH_SEC or got > 0):
                return True
    return False


def _headroom_deferring(lines, now):
    """True if the gate's MOST RECENT headroom decision within FLOW_WINDOW is a DEFER — i.e.
    it is DELIBERATELY throttling reviews to protect Dolt (ga-cw4pm), not stalled (ga-r1u20).

    When Dolt is hot the dispatcher defers every review (ceiling=0 / cap-reached), so it
    emits no Verdicts polls and _fresh_review_in_progress() sees nothing in flight — which
    made gate_merge_stall() mistake a healthy intentional throttle for a stall and spawn
    repair dogs (observed live 2026-06-12 17:00-17:09 under Dolt CPU 102-297%).

    The latest OK/DEFER line is the gate's current self-assessment: a fresh DEFER means 'I
    chose not to admit a run'. A subsequent OK (gate resumed admitting) does NOT suppress —
    if it admitted and STILL isn't merging, that is a genuine stall worth surfacing. A
    decision older than the window is ignored (don't suppress on a stale throttle)."""
    for l in reversed(lines):
        m = HEADROOM_DECISION_RE.search(l)
        if not m:
            continue
        e = log_ts_epoch(l)
        if e is None or now - e > FLOW_WINDOW_SEC:
            return False  # most recent decision is stale/undated → don't suppress on it
        return m.group(1) == "DEFER"
    return False


def gate_merge_stall(now=None):
    """Returns a reason string when the gate has queued work but produced no merge in
    the window and no review is legitimately running; else None. Independent of the
    Pilot check (a gate that stops merging while the Pilot still dispatches is its own
    failure). Conservative by design — overlaps existing GATE-NOMERGE but the per-kind
    cooldown keeps it from double-spawning."""
    now = now if now is not None else time.time()
    if not file_fresh(DISPATCH_LOG, now=now):
        return None  # dead engine = ENGINE-STALL's job
    lines = tail_lines(DISPATCH_LOG, 800)
    if not lines:
        return None

    # any merge in the window? → flow.
    for l in lines:
        if GATE_PASS in l:
            e = log_ts_epoch(l)
            if e and now - e <= FLOW_WINDOW_SEC:
                return None

    # backlog: latest "Found N queued marker(s)".
    backlog = 0
    for l in reversed(lines):
        qm = GATE_QUEUED_RE.search(l)
        if qm:
            backlog = int(qm.group(1))
            break
    if backlog <= 0:
        return None  # empty queue → no demand

    if _fresh_review_in_progress(lines, now):
        return None  # a real review is in flight (incl. a legit long one) → not a stall

    if _headroom_deferring(lines, now):
        return None  # ga-r1u20: gate is deliberately deferring reviews to protect Dolt
                     # (ga-cw4pm headroom throttle) → no Verdicts polls is EXPECTED, not a
                     # stall. Suppress the false-positive at the source.

    return ("Gate com %d marker(s) na fila e ZERO merges em %dmin, sem revisão ativa "
            "em andamento — fila não drena sob demanda" % (backlog, FLOW_WINDOW_SEC // 60))


# ── CHECK C: durable-landing FAIL (the bare-main storm, blind spot b) ─────────
def durable_landing_fail(now=None):
    """Returns a reason string when a run FF-merged to GitHub but FAILED the
    durable-landing audit (merge SHA not an ancestor of rig-canonical/origin main) in
    the window; else None. Pure outcome-counting cannot see this — the run 'completes',
    so it must be matched by its own log signature."""
    now = now if now is not None else time.time()
    lines = tail_lines(DISPATCH_LOG, 800)
    hits = 0
    last = None
    for l in lines:
        if DURABLE_FAIL_RE.search(l):
            e = log_ts_epoch(l)
            if e and now - e <= DURABLE_FAIL_WINDOW_SEC:
                hits += 1
                last = l.strip()
    if hits <= 0:
        return None
    return ("durable-landing FAILOU %dx em %dmin (FF-merge pro GitHub OK mas merge não "
            "atercou em rig-canonical/origin main — possível clobber de remote "
            "compartilhado). Última: %s" % (hits, DURABLE_FAIL_WINDOW_SEC // 60,
                                            (last or "")[:200]))


# ── CHECK D: per-session rot (blind spot c) ───────────────────────────────────
def session_list():
    """Runtime session list (NOT Dolt). Tolerates both the bare-array and {sessions:[]}
    JSON shapes."""
    r = sh(["gc", "session", "list", "--json"])
    if not r or r.returncode != 0:
        return []
    try:
        data = json.loads(r.stdout)
    except Exception:
        return []
    if isinstance(data, dict):
        return data.get("sessions", [])
    return data if isinstance(data, list) else []


def live_repair_dogs(sessions, tracked_ids):
    """Identifiers of heartbeat-spawned repair dogs that are still ALIVE (ga-vym2m).

    A repair dog is "ours and live" when it is a non-closed gastown.dog session that
    either (a) was spawned by us this process lifetime — its id/session_name is in the
    in-memory tracked_ids set, or (b) carries the `reparo heartbeat` title signature (the
    restart-resilient fallback for when tracked_ids was lost to a process restart).

    This is the durable break in the feedback loop: time-based cooldowns alone cannot stop
    a SECOND repair dog from being spawned while the FIRST is still booting/working — and
    under the very Dolt saturation that triggers the false alarm, `gc prime` boots slowly,
    so a 20min cooldown routinely expires before the prior dog finishes. Spawning while a
    sibling is live is exactly the load-amplifying loop ga-hwhtt describes. Reads the
    runtime session list (NOT Dolt), so it stays safe when the data plane is sick."""
    out = []
    for s in sessions or []:
        if s.get("closed"):
            continue
        if s.get("template") != DOG_TEMPLATE:
            continue
        if s.get("state") in ("closed", "exited", "dead", "stopped"):
            continue
        ident = s.get("id") or s.get("session_name") or s.get("name") or ""
        name = s.get("session_name") or s.get("name") or ""
        title = s.get("title") or ""
        is_tracked = bool(tracked_ids) and (
            ident in tracked_ids or name in tracked_ids
            or s.get("id") in tracked_ids or s.get("name") in tracked_ids)
        is_signature = bool(REPAIR_DOG_TITLE_RE.search(title))
        if is_tracked or is_signature:
            if ident:
                out.append(ident)
    return out


def rotting_sessions(now=None, self_name=None, sessions=None):
    """List of (agent, age_sec) for ephemeral worker sessions that are active but frozen
    (last_active older than SESSION_ROT_SEC). Excludes attached/closed sessions, this
    process's own session, and non-ephemeral templates (crew is the crew-hang-detector's
    job; coordinators idle legitimately)."""
    now = now if now is not None else time.time()
    self_name = self_name or os.environ.get("GC_SESSION_NAME") or os.environ.get("GC_ALIAS")
    out = []
    sessions = sessions if sessions is not None else session_list()
    for s in sessions:
        if s.get("closed") or s.get("attached"):
            continue
        if s.get("template") not in EPHEMERAL_WORKER_TEMPLATES:
            continue
        if s.get("state") != "active":
            continue
        name = s.get("session_name") or s.get("name") or s.get("id") or ""
        if self_name and name in (self_name, s.get("alias"), s.get("name")):
            continue
        if name == os.environ.get("GC_SESSION_NAME") or name == os.environ.get("GC_ALIAS"):
            continue
        e = parse_iso_epoch(s.get("last_active"))
        if e is None:
            continue
        age = now - e
        if age > SESSION_ROT_SEC:
            label = s.get("alias") or s.get("name") or name
            out.append((label, name, int(age)))
    return out


# ── repair-agent handoff (ga-afytf mechanism), rate-limited ───────────────────
REPAIR_HEADER = (
    "Você é um agente de REPARO autônomo despachado pelo pipeline-throughput-heartbeat. "
    "Rode o runbook abaixo SOZINHO (colete diag, conserte, verifique). Só acione o humano "
    "(notify 🚨 -p 5) se NÃO conseguir resolver. Quando terminar, feche seu bead e saia.\n\n")


def repair_runbook(kind, reason):
    if kind == "pilot":
        body = (
            "PROBLEMA: o Pilot está VARRENDO mas despachando ZERO com backlog pronto e "
            "slots livres (blind spot que escapou de todos os monitores em 2026-06-11).\n"
            "Motivo: %s\n\n"
            "CONSERTO:\n"
            "1. tail -40 .gc/logs/pilot-dispatcher.log — confirme 'dispatched=0' repetido "
            "com 'Dispatch tier: X (N candidate(s))' N>=1 e slots livres.\n"
            "2. Causa comum: o `gc sling` rejeita o bead-alvo (título com acento/travessão "
            "→ 'Incorrect string value \\xC3') e a varredura aborta antes de despachar — "
            "de-acentue o título do candidato (bd update <id> --title '...').\n"
            "3. Ou o reconciler/Dolt está lento: gc dolt status; se wedged, gc dolt restart.\n"
            "4. Force uma varredura: launchctl kickstart gui/$(id -u)/com.gascity.pilot ; "
            "confirme 'dispatched=N' N>0 na próxima.\n" % reason)
    elif kind == "gate-merge":
        body = (
            "PROBLEMA: o gate tem markers na fila mas ZERO merges, sem revisão ativa — a "
            "fila não drena sob demanda.\n"
            "Motivo: %s\n\n"
            "CONSERTO:\n"
            "1. tail -40 .gc/logs/quality-gate-dispatcher.log — veja se o dispatcher re-pega "
            "o MESMO branch (head-of-line) ou se revisores nascem e morrem (spawn-fail).\n"
            "2. Head-of-line: re-anchor OU supersede o marker do branch stale na cabeça da "
            "fila (memória [[gate-rebase-error-stale-branch]]).\n"
            "3. Spawn-fail: gc dolt status; kickstart supervisor + quality-gate-dispatcher; "
            "confirme revisores 'active' e vereditos subindo.\n" % reason)
    elif kind == "durable":
        body = (
            "PROBLEMA: runs FF-mergeram pro GitHub mas FALHARAM a auditoria de durable-landing "
            "(merge SHA não é ancestral de rig-canonical/origin main) — bare-main false-fail.\n"
            "Motivo: %s\n\n"
            "CONSERTO:\n"
            "1. grep 'Durable-landing' .gc/logs/quality-gate-dispatcher.log | tail -20.\n"
            "2. Verifique divergência rig-canonical vs origin main (clobber de remote "
            "compartilhado — memória [[town-gastown-shared-remote]]); re-sincronize a main "
            "bare/origin e re-gate o branch afetado.\n"
            "3. Confirme um merge que aterre durável (audit ancestral em AMBOS).\n" % reason)
    elif kind == "session-rot":
        body = (
            "PROBLEMA: sessão(ões) de worker efêmero (gate-reviewer/dog) ATIVA mas congelada "
            ">2h sem transições — segura o slot e trava o pipeline.\n"
            "Motivo: %s\n\n"
            "CONSERTO:\n"
            "1. gc session peek <id> --lines 60 — confirme que está parada (sem output novo).\n"
            "2. Rode o shutdown-dance (3 nudges com timeout) — se não responder, "
            "gc session kill <id> pra liberar o slot; o controller recicla.\n"
            "3. Confirme que o slot voltou e o trabalho foi re-despachado.\n" % reason)
    else:
        body = "Motivo: %s\n" % reason
    return body


def _parse_spawned_id(r):
    """Best-effort extraction of the new session id/name from `gc session new --json`
    output, tolerant of several envelope shapes. Returns a string id or None — the live
    sibling guard's primary signal is this id, so a parse miss degrades gracefully to the
    title-signature fallback rather than breaking suppression."""
    if r is None or r.returncode != 0 or not (r.stdout or "").strip():
        return None
    try:
        data = json.loads(r.stdout)
    except Exception:
        return None
    if isinstance(data, dict):
        node = data.get("session") if isinstance(data.get("session"), dict) else data
        for k in ("id", "session_name", "name", "session_id"):
            v = node.get(k)
            if isinstance(v, str) and v:
                return v
    return None


def spawn_repair_agent(kind, reason, diag_path):
    """PRIMARY recovery (ga-afytf mechanism): route the runbook to the gastown.dog pool
    AND spawn a dog directly so recovery doesn't depend on the demand reconciler the
    stall may have wedged.

    Returns the spawned dog's session id/name (str) on success so the caller can track it
    as a live sibling (ga-vym2m), the literal string "routed" if the bead routed but the
    spawned id could not be parsed (still a success — the title signature will catch the
    dog), or None if routing itself failed."""
    title = "🔧 REPARO AUTÔNOMO heartbeat (%s): %s" % (kind, reason[:80])
    payload = (title + "\n\n" + REPAIR_HEADER + repair_runbook(kind, reason)
               + "\nDiagnóstico salvo em: %s\n" % diag_path)
    r = sh(["gc", "sling", DOG_TEMPLATE, "--stdin", "--json"], stdin=payload, timeout=45)
    routed = r is not None and r.returncode == 0
    if not routed:
        return None
    nr = sh(["gc", "session", "new", DOG_TEMPLATE, "--no-attach", "--json",
             "--title-hint", "reparo heartbeat: " + reason[:50]], timeout=45)
    return _parse_spawned_id(nr) or "routed"


def snapshot(kind, reason):
    """Diagnostics bundle — logs + session list only (NO Dolt query, to stay independent
    of the data-plane stalls this monitor polices)."""
    ts = time.strftime("%Y%m%d-%H%M%S")
    path = "/tmp/heartbeat-diag-%s-%s.txt" % (kind, ts)
    try:
        with open(path, "w") as f:
            f.write("PIPELINE THROUGHPUT HEARTBEAT DIAG %s\nkind: %s\nreason: %s\n\n"
                    % (ts, kind, reason))
            for title, pth in [("pilot-dispatcher.log tail", PILOT_LOG),
                               ("quality-gate-dispatcher.log tail", DISPATCH_LOG)]:
                f.write("== %s ==\n%s\n\n" % (title, "".join(tail_lines(pth, 30))))
            r = sh(["gc", "session", "list"], timeout=15)
            f.write("== sessions ==\n%s\n" % (r.stdout if r else "(failed)"))
    except Exception:
        pass
    return path


def notify(msg, prio):
    sh([NOTIFY, "-t", "Pipeline heartbeat", "-p", str(prio), msg], timeout=10)


def new_state():
    """Fresh per-kind recovery state: last spawn epoch, unresolved-cycle counter, and the
    consecutive-detection counter (`pending`) that drives the anti-flap hysteresis."""
    return {k: {"last_spawn": 0.0, "cycles": 0, "pending": 0}
            for k in ("pilot", "gate-merge", "durable", "session-rot")}


def detect(now, sessions=None):
    """Run all four checks; return a list of (kind, reason) findings. Pure detection —
    no side effects — so it is straightforward to unit-test. `sessions` is the already
    fetched runtime session list (passed in so the per-tick fetch is shared with the
    live-sibling guard); None means fetch on demand."""
    findings = []
    r = pilot_dispatch_stall(now)
    if r:
        findings.append(("pilot", r))
    r = gate_merge_stall(now)
    if r:
        findings.append(("gate-merge", r))
    r = durable_landing_fail(now)
    if r:
        findings.append(("durable", r))
    rot = rotting_sessions(now, sessions=sessions)
    if rot:
        reason = "; ".join("%s congelada há %dmin" % (lbl, age // 60)
                           for lbl, _name, age in rot)
        findings.append(("session-rot", reason))
    return findings


def run_tick(now, state, last_global_spawn, tracked=None):
    """One evaluation cycle: detect, reset recovered kinds, and fire repair-spawns gated by
    anti-flap hysteresis (ga-vym2m), a live-sibling guard, and the per-kind/global
    cooldowns. Returns the updated last_global_spawn epoch. `tracked` is a mutable set of
    live repair-dog ids carried across ticks by the caller (pruned + extended here). All
    spawn/notify/snapshot/session_list go through module functions so a test can
    monkeypatch them."""
    if tracked is None:
        tracked = set()
    sessions = session_list()
    findings = detect(now, sessions)
    fired = {k for k, _ in findings}

    # Prune the tracked set to repair dogs still alive, and learn the full live set
    # (tracked ids + title-signature, restart-resilient). One live sibling suppresses ALL
    # new spawns this tick — the hard guarantee of "at most 1 recovery-dog alive" (AC2)
    # and the durable break in the load-amplifying feedback loop (AC3).
    live = live_repair_dogs(sessions, tracked)
    tracked.clear()
    tracked.update(live)

    # recovery: a kind that previously alerted OR was mid-confirmation but is now clear
    # resets both counters. A kind that recovers before confirming never spawned — exactly
    # the historical flapping case (detected at tick T, recovered at T+1).
    for kind, st in state.items():
        if kind not in fired and (st["cycles"] > 0 or st["pending"] > 0):
            if st["cycles"] > 0:
                print("[heartbeat] %s recovered — resetting" % kind, flush=True)
                if kind in ("pilot", "gate-merge"):
                    notify("Fluxo recuperado (%s)." % kind, 3)
            else:
                print("[heartbeat] %s cleared before confirmation (flap suppressed)"
                      % kind, flush=True)
            st["cycles"] = 0
            st["pending"] = 0

    for kind, reason in findings:
        st = state[kind]
        # Anti-flap hysteresis (AC1): require CONFIRM_TICKS consecutive detections. A stall
        # that clears within one poll (the gate was slow-but-draining, not stuck) never
        # reaches the spawn path.
        st["pending"] += 1
        if st["pending"] < CONFIRM_TICKS:
            print("[heartbeat] %s detected (%d/%d) — awaiting confirmation: %s"
                  % (kind, st["pending"], CONFIRM_TICKS, reason), flush=True)
            continue
        # Live-sibling guard (AC2/AC3): never run two repair dogs at once.
        if live:
            print("[heartbeat] %s confirmed but a repair dog is still alive (%s) — "
                  "suppressing spawn (anti feedback-loop)" % (kind, ",".join(live)),
                  flush=True)
            continue
        # per-kind cooldown AND global anti-swarm cooldown
        if now - st["last_spawn"] <= REPAIR_COOLDOWN_SEC:
            continue
        if now - last_global_spawn <= GLOBAL_SPAWN_COOLDOWN_SEC:
            continue
        diag = snapshot(kind, reason)
        spawned = spawn_repair_agent(kind, reason, diag)
        if not spawned:
            print("[heartbeat] %s spawn FAILED to route — will retry next tick" % kind,
                  flush=True)
            continue
        # Track the new dog so the live-sibling guard suppresses further spawns until it
        # finishes — including for OTHER kinds later in this same tick.
        tracked.add(spawned)
        live = list(tracked)
        st["last_spawn"] = now
        last_global_spawn = now
        st["cycles"] += 1
        if st["cycles"] >= ESCALATE_AFTER:
            notify("🚨 PIPELINE ainda parado (%s) após %d ciclos de reparo. "
                   "Precisa de você. Diag: %s" % (kind, st["cycles"], diag), 5)
            _ledger("human-touch", {"ts": __import__("datetime").datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "pipeline-throughput-heartbeat", "stage": "executa", "kind": "technical", "bead_id": "", "reason": "PIPELINE parado %s após %d ciclos de reparo" % (kind, st["cycles"])}, fail_open=True)
            print("[heartbeat] ESCALATED to Athos (%s, %d cycles)"
                  % (kind, st["cycles"]), flush=True)
        else:
            notify("Pipeline parado (%s) — agente de reparo despachado. "
                   "Você não precisa agir." % kind, 3)
            print("[heartbeat] repair spawned kind=%s id=%s reason=%s diag=%s"
                  % (kind, spawned, reason, diag), flush=True)
    return last_global_spawn


def main():
    state = new_state()
    tracked = set()           # live repair-dog ids, carried across ticks (ga-vym2m)
    last_global_spawn = 0.0
    print("[heartbeat] pipeline throughput heartbeat started — flow-under-demand + "
          "durable-landing-FAIL + session-rot; anti-flap hysteresis + live-sibling guard "
          "+ rate-limited repair-spawn", flush=True)
    while True:
        try:
            last_global_spawn = run_tick(time.time(), state, last_global_spawn, tracked)
        except Exception as e:
            print("[heartbeat] loop error (continuing): %r" % e, flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()

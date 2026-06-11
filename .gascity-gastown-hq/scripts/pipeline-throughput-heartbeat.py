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
        review is legitimately in-flight younger than its own timeout. The last guard
        is what stops a single honest 40-minute review from tripping the alarm.
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
    REVIEW_FRESH_SEC, or a 'proceeding to merge' line, appears recently in the tail.
    This is the guard that keeps a single honest long review from tripping the alarm."""
    for l in reversed(lines[-40:]):
        if GATE_MERGING in l:
            e = log_ts_epoch(l)
            if e and now - e < REVIEW_FRESH_SEC:
                return True
        vm = VERDICTS_RE.search(l)
        if vm:
            elapsed = int(vm.group(3))
            e = log_ts_epoch(l)
            # the poll line is recent AND the review's own elapsed is under its timeout
            if e and now - e < POLL_SEC * 2 and elapsed < REVIEW_FRESH_SEC:
                return True
            return False  # most-recent verdict poll is stale/over-timeout → not fresh
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


def rotting_sessions(now=None, self_name=None):
    """List of (agent, age_sec) for ephemeral worker sessions that are active but frozen
    (last_active older than SESSION_ROT_SEC). Excludes attached/closed sessions, this
    process's own session, and non-ephemeral templates (crew is the crew-hang-detector's
    job; coordinators idle legitimately)."""
    now = now if now is not None else time.time()
    self_name = self_name or os.environ.get("GC_SESSION_NAME") or os.environ.get("GC_ALIAS")
    out = []
    for s in session_list():
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


def spawn_repair_agent(kind, reason, diag_path):
    """PRIMARY recovery (ga-afytf mechanism): route the runbook to the gastown.dog pool
    AND spawn a dog directly so recovery doesn't depend on the demand reconciler the
    stall may have wedged. Returns True if the repair bead was routed."""
    title = "🔧 REPARO AUTÔNOMO heartbeat (%s): %s" % (kind, reason[:80])
    payload = (title + "\n\n" + REPAIR_HEADER + repair_runbook(kind, reason)
               + "\nDiagnóstico salvo em: %s\n" % diag_path)
    r = sh(["gc", "sling", DOG_TEMPLATE, "--stdin", "--json"], stdin=payload, timeout=45)
    routed = r is not None and r.returncode == 0
    if routed:
        sh(["gc", "session", "new", DOG_TEMPLATE, "--no-attach",
            "--title-hint", "reparo heartbeat: " + reason[:50]], timeout=45)
    return routed


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
    """Fresh per-kind recovery state: last spawn epoch + unresolved-cycle counter."""
    return {k: {"last_spawn": 0.0, "cycles": 0}
            for k in ("pilot", "gate-merge", "durable", "session-rot")}


def detect(now):
    """Run all four checks; return a list of (kind, reason) findings. Pure detection —
    no side effects — so it is straightforward to unit-test."""
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
    rot = rotting_sessions(now)
    if rot:
        reason = "; ".join("%s congelada há %dmin" % (lbl, age // 60)
                           for lbl, _name, age in rot)
        findings.append(("session-rot", reason))
    return findings


def run_tick(now, state, last_global_spawn):
    """One evaluation cycle: detect, reset recovered kinds, and fire rate-limited
    repair-spawns. Returns the updated last_global_spawn epoch. All spawn/notify/snapshot
    go through module functions so a test can monkeypatch them."""
    findings = detect(now)
    fired = {k for k, _ in findings}

    # recovery: a kind that previously alerted but is now clear resets its counter.
    for kind, st in state.items():
        if kind not in fired and st["cycles"] > 0:
            print("[heartbeat] %s recovered — resetting" % kind, flush=True)
            if kind in ("pilot", "gate-merge"):
                notify("Fluxo recuperado (%s)." % kind, 3)
            st["cycles"] = 0

    for kind, reason in findings:
        st = state[kind]
        # per-kind cooldown AND global anti-swarm cooldown (AC5)
        if now - st["last_spawn"] <= REPAIR_COOLDOWN_SEC:
            continue
        if now - last_global_spawn <= GLOBAL_SPAWN_COOLDOWN_SEC:
            continue
        diag = snapshot(kind, reason)
        routed = spawn_repair_agent(kind, reason, diag)
        st["last_spawn"] = now
        last_global_spawn = now
        st["cycles"] += 1
        if st["cycles"] >= ESCALATE_AFTER:
            notify("🚨 PIPELINE ainda parado (%s) após %d ciclos de reparo. "
                   "Precisa de você. Diag: %s" % (kind, st["cycles"], diag), 5)
            print("[heartbeat] ESCALATED to Athos (%s, %d cycles)"
                  % (kind, st["cycles"]), flush=True)
        else:
            notify("Pipeline parado (%s) — agente de reparo despachado. "
                   "Você não precisa agir." % kind, 3)
            print("[heartbeat] repair spawned kind=%s routed=%s reason=%s diag=%s"
                  % (kind, routed, reason, diag), flush=True)
    return last_global_spawn


def main():
    state = new_state()
    last_global_spawn = 0.0
    print("[heartbeat] pipeline throughput heartbeat started — flow-under-demand + "
          "durable-landing-FAIL + session-rot; rate-limited repair-spawn", flush=True)
    while True:
        try:
            last_global_spawn = run_tick(time.time(), state, last_global_spawn)
        except Exception as e:
            print("[heartbeat] loop error (continuing): %r" % e, flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()

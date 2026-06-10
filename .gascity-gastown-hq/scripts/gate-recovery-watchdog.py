#!/usr/bin/env python3
"""Self-healing gate watchdog — WAKES THE MAYOR to fix, Athos is FYI-only.

Philosophy (per Athos, 2026-06-07): a serious problem must not merely ping the
human who can't fix it. It must PRIMARILY wake the Mayor (an agent with judgment +
the recovery playbook) to fix it autonomously, notify Athos as a courtesy FYI, and
escalate LOUDLY to Athos only as a last resort if the Mayor fails to recover.

This is the "automatic crew member" that the 2026-06-07 outage lacked: the gate
died at ~20:00 and was only fixed hours later because a human crew member happened
to notice and mailed the Mayor. This watchdog is that noticer — in minutes.

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

ON DETECT:
  1. snapshot diagnostics to /tmp/gate-watchdog-diag-<ts>.txt
  2. WAKE the gastown.mayor session + deliver a precise fix task (references the
     gate-reviewer-spawn-failure-playbook memory + the known fix).
  3. notify Athos FYI (low priority): "gate travou, Mayor foi acordado pra consertar".
  4. cooldown WAKE_COOLDOWN before waking again.

ESCALATE (last resort): if still broken after ESCALATE_AFTER_WAKES wake-cycles,
fire ntfy 🚨 -p 5 to Athos — the Mayor couldn't recover, a human is needed.

Recovers silently: when a Gate PASSED appears after a wake, reset state (problem solved).
Never crashes (every external call guarded); silence = healthy.
"""
import json, time, datetime, subprocess, os, re

CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
SUPERVISOR_LOG = "/Users/athos/.gc/supervisor.log"
NOTIFY = "/Users/athos/.local/bin/notify"

POLL_SEC = 60
TIMEOUT_WINDOW_SEC = 1800      # 2+ timeouts within 30min = gate not producing verdicts
DISPATCH_STUCK_SEC = 720       # marker dispatching >12min w/ no active reviewers = spawn fail
PILOT_JAM_WINDOW_SEC = 900     # 2+ sweep-aborts within 15min = Pilot jammed on a bad bead
PILOT_STALL_SEC = 2400         # pilot log silent >40min = Pilot dead/not sweeping
HEADOFLINE_MIN_SWEEPS = 2      # >=2 consecutive QUEUED-retry sweeps on the SAME branch = head-of-line block
HEADOFLINE_LOG_FRESH_SEC = 600 # ignore if dispatcher log is staler than this (that's ENGINE-STALL's job)
WAKE_COOLDOWN_SEC = 1200       # don't re-wake the Mayor more than once per 20min (per kind)
ESCALATE_AFTER_WAKES = 2       # after 2 unresolved wake-cycles, page Athos 🚨
DOLT_SIG = re.compile(r"connection reset|bead store closed|unexpected EOF|invalid connection|provider-health registry unavailable")
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Dispatcher sweep complete: branch=<X> verdict=QUEUED (retry N/M, dead author) ==="
SWEEP_QUEUED_RETRY_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=QUEUED \(retry")
SWEEP_COMPLETE_RE = re.compile(r"Dispatcher sweep complete: branch=(\S+) verdict=")


def sh(args, timeout=20):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


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


def wake_mayor(reason, diag_path, dolt_hits, kind="gate"):
    mid = mayor_session()
    if not mid:
        return False
    if kind == "pilot":
        task = (
            "🔧 ALERTA AUTOMÁTICO DO WATCHDOG — Pilot travado. Conserta agora, não escale pro Athos a menos que falhe.\n\n"
            "O Pilot parou de despachar trabalho. Motivo detectado: %s.\nDiagnóstico: %s\n\n"
            "Causa-raiz mais provável (lição de 2026-06-08): o `gc sling` rejeita títulos com acento/travessão "
            "('Incorrect string value \\xC3 for column title') e o Pilot ABORTA a varredura inteira por causa de "
            "um bead ruim → não despacha nada. Veja a memória [[post-outage-remaining-tech-debt]] item 6.\n\n"
            "CONSERTO (verificando entre os passos):\n"
            "1. tail -20 .gc/logs/pilot-dispatcher.log → ache 'gc sling failed for <bead> — aborting dispatch'.\n"
            "2. Se for charset: bd -C . update <bead-culpado> --title '<versão SEM acento/travessão>' (de-acentue).\n"
            "3. Se o log estiver silencioso (Pilot morto): launchctl kickstart -k gui/$(id -u)/com.gascity.pilot.\n"
            "4. Dispare: launchctl kickstart gui/$(id -u)/com.gascity.pilot ; confirme 'dispatched=N' (N>0) na próxima varredura.\n\n"
            "Só acione o Athos (notify 🚨 -p 5) se NÃO conseguir destravar."
        ) % (reason, diag_path)
        sh(["gc", "session", "wake", mid], timeout=20)
        r = sh(["gc", "session", "nudge", mid, task], timeout=25)
        return r is not None and r.returncode == 0
    if kind == "gate-loop":
        task = (
            "🔧 ALERTA AUTOMÁTICO DO WATCHDOG — gate em HEAD-OF-LINE BLOCK. Conserta agora, não escale pro Athos a menos que falhe.\n\n"
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
            "(Fix permanente do auto-skip no dispatcher = ga-q3ig2 — este wake é a ponte de detecção+recuperação até ele aterrissar. "
            "Cuidado: o contador gate:rebase-attempt reseta a 0 todo sweep, então o escape de 3-strikes do dispatcher nunca dispara — por isso loopa pra sempre.)"
        ) % (reason, reason, diag_path)
        sh(["gc", "session", "wake", mid], timeout=20)
        r = sh(["gc", "session", "nudge", mid, task], timeout=25)
        return r is not None and r.returncode == 0
    task = (
        "🔧 ALERTA AUTOMÁTICO DO WATCHDOG (gate-recovery-watchdog) — conserta agora, não escale pro Athos a menos que falhe.\n\n"
        "O gate parou de produzir vereditos. Motivo detectado: %s. "
        "Linhas de instabilidade do Dolt no supervisor.log: %d.\n"
        "Diagnóstico salvo em: %s\n\n"
        "Causa-raiz mais provável (lição de 2026-06-07): instabilidade de conexão do Dolt da cidade (:52756) "
        "→ supervisor não computa a demanda de gate-reviewer → revisores nascem e morrem (start-pending) → "
        "todo run dá TIMEOUT. Veja a memória [[gate-reviewer-spawn-failure-playbook]].\n\n"
        "CONSERTO (na ordem, verificando entre os passos):\n"
        "1. Colete diagnóstico: grep -E 'connection reset|bead store closed|invalid connection' ~/.gc/supervisor.log | tail\n"
        "2. Menos invasivo primeiro: launchctl kickstart -k gui/$(id -u)/com.gascity.supervisor ; espere 30s ; "
        "dispare um gate run (launchctl kickstart gui/$(id -u)/com.gascity.quality-gate-dispatcher) e veja se os "
        "revisores ficam 'active' e os vereditos sobem.\n"
        "3. Se ainda quebrado: gc dolt restart (da pasta da cidade) — preserva dados, bd volta na hora — depois "
        "kickstart do supervisor de novo, e re-verifique um run.\n"
        "4. Confirme com um run REAL passando ponta-a-ponta (3/3 vereditos → PASS). "
        "Sondas ad-hoc (gc session new sem tarefa) saem sozinhas, não servem de teste.\n\n"
        "Quando resolver, mande um nudge pro crew se preciso e siga. Só acione o Athos (notify 🚨 -p 5) se NÃO "
        "conseguir recuperar."
    ) % (reason, dolt_hits, diag_path)
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

  print("[watchdog] gate+pilot watchdog started — wakes Mayor on gate-down OR pilot-jam OR head-of-line block", flush=True)

  while True:
    try:
        n_to, last_to = recent_timeouts()
        stuck = stuck_dispatching()
        problem = (n_to >= 2) or stuck

        # recovery: a PASS landed after our last wake → reset
        lp = last_pass_epoch()
        if wakes_since_recovery > 0 and lp and lp > last_wake:
            print("[watchdog] gate recovered (Gate PASSED after wake) — resetting", flush=True)
            notify("Gate recuperou sozinho/Mayor — voltou a passar revisões. Tudo certo.", 3)
            wakes_since_recovery = 0
            last_pass_at_wake = 0

        if problem and (time.time() - last_wake > WAKE_COOLDOWN_SEC):
            reason = ("%d timeouts em %dmin" % (n_to, TIMEOUT_WINDOW_SEC // 60)) if n_to >= 2 \
                     else "marcador dispatching travado sem revisores ativos"
            dolt_hits = dolt_instability()
            diag = snapshot(reason, dolt_hits)
            woke = wake_mayor(reason, diag, dolt_hits)
            last_wake = time.time()
            wakes_since_recovery += 1

            if wakes_since_recovery >= ESCALATE_AFTER_WAKES:
                # last resort — the Mayor's prior wake didn't fix it
                notify("🚨 GATE AINDA QUEBRADO após o Mayor tentar consertar (%dx). Precisa de você. Diag: %s"
                       % (wakes_since_recovery, diag), 5)
                print("[watchdog] ESCALATED to Athos (Mayor failed to recover, %d wakes)" % wakes_since_recovery, flush=True)
            else:
                notify("Gate travou (%s) — Mayor foi acordado pra consertar (playbook Dolt). Você não precisa agir."
                       % reason, 3)
                print("[watchdog] woke Mayor (woke=%s) reason=%s dolt_hits=%d diag=%s"
                      % (woke, reason, dolt_hits, diag), flush=True)

        # --- PILOT coverage (closes the gap that hid the 2026-06-08 ~8h jam) ---
        pj, pj_reason = pilot_jammed()
        if pilot_wakes > 0 and not pj:
            print("[watchdog] pilot recovered — resetting", flush=True)
            notify("Pilot voltou a despachar — resolvido.", 3)
            pilot_wakes = 0
        if pj and (time.time() - last_pilot_wake > WAKE_COOLDOWN_SEC):
            pdiag = snapshot(pj_reason, 0)
            pwoke = wake_mayor(pj_reason, pdiag, 0, kind="pilot")
            last_pilot_wake = time.time()
            pilot_wakes += 1
            if pilot_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 PILOT AINDA TRAVADO após o Mayor tentar consertar (%dx). Precisa de você. Diag: %s"
                       % (pilot_wakes, pdiag), 5)
                print("[watchdog] ESCALATED to Athos (pilot jam, %d wakes)" % pilot_wakes, flush=True)
            else:
                notify("Pilot travou (%s) — Mayor foi acordado pra consertar. Você não precisa agir." % pj_reason, 3)
                print("[watchdog] woke Mayor for PILOT (woke=%s) reason=%s diag=%s"
                      % (pwoke, pj_reason, pdiag), flush=True)

        # --- HEAD-OF-LINE block (closes the ga-hl0gq blind spot: 49min undetected) ---
        hb, hcount = headofline_stall()
        # recovery: a PASS landed after our last loop-wake → the queue drained
        if loop_wakes > 0 and lp and lp > last_loop_wake:
            print("[watchdog] head-of-line cleared (Gate PASSED after loop-wake) — resetting", flush=True)
            notify("Gate destravou — fila voltou a drenar (head-of-line resolvido).", 3)
            loop_wakes = 0
        if hb and (time.time() - last_loop_wake > WAKE_COOLDOWN_SEC):
            ldiag = snapshot("head-of-line block: %dx QUEUED-retry no branch %s" % (hcount, hb), 0)
            lwoke = wake_mayor(hb, ldiag, 0, kind="gate-loop")
            last_loop_wake = time.time()
            loop_wakes += 1
            if loop_wakes >= ESCALATE_AFTER_WAKES:
                notify("🚨 GATE AINDA TRAVADO em branch stale (head-of-line: %s) após o Mayor tentar (%dx). Precisa de você. Diag: %s"
                       % (hb, loop_wakes, ldiag), 5)
                print("[watchdog] ESCALATED to Athos (head-of-line %s, %d wakes)" % (hb, loop_wakes), flush=True)
            else:
                notify("Gate preso em branch stale (head-of-line: %s, %dx sweeps) — Mayor acordado pra destravar (supersede/re-anchor). Você não precisa agir."
                       % (hb, hcount), 4)
                print("[watchdog] woke Mayor for HEAD-OF-LINE (woke=%s) branch=%s count=%d diag=%s"
                      % (lwoke, hb, hcount, ldiag), flush=True)
    except Exception as e:
        print("[watchdog] loop error (continuing): %r" % e, flush=True)
    time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()

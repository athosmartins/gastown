#!/usr/bin/env python3
"""Production-stall watchdog — escalates a STALLED Gas City pipeline to the MAYOR.

WHY THIS EXISTS (Athos, 2026-06-18: "a gente não tem um dog que fica vigiando e se
vê o sistema idle dispara você ou alguém pra investigar?").

On 2026-06-18 the whole system sat ~2h producing NOTHING. Root: the WA rig root was
AHEAD of origin/main (unpushed commits) → the deploy cron's `git pull --ff-only`
aborted → no daemon got deployed → silent stall. EVERY existing monitor missed it:

  • town-root-reconciler.sh only ntfy-alerts a (sleeping) HUMAN on divergence and
    deliberately will NOT auto-reconcile an ahead/diverged root (correct — a blind
    reset is dangerous), so nothing ACTS on it.
  • pipeline-throughput-heartbeat.py watches gate-merge / pilot-dispatch FLOW only;
    a deploy-block upstream of the gate, or stuck in-flight execution, is invisible
    to it.

THE GAP this fills: nothing auto-dispatches an ACTIVE AGENT (the Mayor) to
investigate when production stalls across the deploy / merge / execution
dimensions. This watchdog detects those stalls and ESCALATES TO THE MAYOR
(`gc mail send mayor` — durable, an agent that can ACT), plus a `notify -p 4` to
Athos. It does NOT auto-reconcile anything (uncommitted live edits make a blind
reset destructive — Athos hit a token-revert doing it by hand); the Mayor
reconciles deliberately.

DESIGN — mirrors pipeline-throughput-heartbeat.py's proven safety machinery:
  • Anti-flap HYSTERESIS: a single-tick detection is PENDING; only CONFIRM_TICKS
    consecutive detections of the SAME dimension ESCALATE. A stall that clears
    within one tick never pages anyone.
  • RECOVER → reset: a dimension that was escalating/pending but is now clear
    resets its counters (and sends a 'recovered' notify if it had escalated).
  • SUPPRESS while handled: after escalating a dimension, a per-dimension
    cooldown (ESCALATE_COOLDOWN_SEC) suppresses re-escalation so the Mayor is not
    spammed while already working a stall.
  • FAIL-SAFE: every external call is guarded; ANY ambiguity (unparseable output,
    failed git fetch, missing log) → treat as HEALTHY (no escalation). An empty or
    idle-because-no-work system NEVER false-alarms — each dimension requires
    positive evidence of pending demand before flagging.
  • Kill-switch: PROD_STALL_WATCHDOG_ENABLED=0 → no-op.
  • Reads git (per-rig, reliable across rigs — `bd -C` is NOT) + dispatcher logs +
    `bd list` from the HQ subdir + `gc session list` (runtime, not Dolt). It uses
    `bd` only for stuck-execution/demand reads, with short timeouts and fail-open.

DETECTION DIMENSIONS:
  1. DEPLOY-BLOCK — for each rig root, `git -C <root> rev-list --count
     origin/main..HEAD` > 0 (unpushed commits = ff-pull deploy blocked: the EXACT
     thing that stalled us). Fetches origin/main first (best-effort). Also flags a
     true divergence (rev-list --left-right shows both ahead AND behind).
  2. MERGE-STALL — no `Gate PASSED` / `merged sha=` in the dispatcher log for
     MERGE_STALL_SEC, AND there is pending work (queued markers in the log OR open
     story:approved beads). Suppressed when the queue is empty (idle ≠ stalled) or
     the dispatcher log is stale (a dead engine is the engine-stall monitors' job).
  3. STUCK-EXECUTION — a bead in_progress whose updated_at is older than
     STUCK_EXEC_SEC (assigned but not progressing).

Recovers silently; silence = healthy. Never crashes the loop.
"""
import json
import os
import re
import subprocess
import time
import sys as _sys
_sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__))))
from gc_ledger import gc_ledger_append as _ledger
import datetime as _datetime

# ── paths / identities ───────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
NOTIFY = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC = os.environ.get("GC_BIN", "gc")
BD = os.environ.get("BD_BIN", "bd")

# Rig roots to check for deploy-block. `git -C <path>` is reliable across rigs;
# `bd -C` is NOT (per-rig metadata pins it to dead ports) — so we use git only here.
RIG_ROOTS = os.environ.get(
    "PROD_STALL_RIG_ROOTS",
    "/Users/athos/gt:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers",
).split(":")

REMOTE = os.environ.get("PROD_STALL_REMOTE", "origin")
BRANCH = os.environ.get("PROD_STALL_BRANCH", "main")

# ── cadence / thresholds (all env-overridable; fail-safe defaults) ─────────────
POLL_SEC = int(os.environ.get("PROD_STALL_POLL_SEC", "1500"))          # 25min cadence
DEPLOY_BLOCK_MIN_AHEAD = int(os.environ.get("PROD_STALL_MIN_AHEAD", "1"))  # >=N unpushed = block
MERGE_STALL_SEC = int(os.environ.get("PROD_STALL_MERGE_SEC", "10800"))  # 3h no merge under demand
LOG_FRESH_SEC = int(os.environ.get("PROD_STALL_LOG_FRESH_SEC", "1800"))  # dead engine ≠ our job
STUCK_EXEC_SEC = int(os.environ.get("PROD_STALL_STUCK_SEC", "28800"))   # 8h in_progress no update
CONFIRM_TICKS = int(os.environ.get("PROD_STALL_CONFIRM_TICKS", "2"))    # consecutive before escalate
ESCALATE_COOLDOWN_SEC = int(os.environ.get("PROD_STALL_COOLDOWN_SEC", "10800"))  # per-dim, 3h
GIT_FETCH_TIMEOUT = int(os.environ.get("PROD_STALL_FETCH_TIMEOUT", "30"))
MAYOR_ADDR = os.environ.get("PROD_STALL_MAYOR_ADDR", "mayor")

DIMENSIONS = ("deploy-block", "merge-stall", "stuck-exec")

# ── log-line patterns (verified against the live dispatcher) ──────────────────
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
GATE_PASS_RE = re.compile(r"Gate PASSED|merged sha=")
QUEUED_RE = re.compile(r"Found (\d+) queued marker\(s\)")


# ── guarded subprocess ────────────────────────────────────────────────────────
def sh(args, timeout=20):
    """Run a command; return CompletedProcess or None on any failure. Never raises."""
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    except Exception:
        return None


def log_ts_epoch(line):
    m = TS_RE.search(line)
    if not m:
        return None
    try:
        return time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def parse_iso_epoch(s):
    """Epoch of an ISO-8601 timestamp ('Z' / offset / naive-local). None if unparseable."""
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


def file_fresh(path, max_age, now):
    try:
        return (now - os.path.getmtime(path)) <= max_age
    except Exception:
        return False


def parse_bd_json(raw):
    """bd --json emits a JSON array, sometimes followed by a trailing non-JSON summary
    line. Isolate and parse the array; return [] on any failure (FAIL-OPEN)."""
    if not raw or not raw.strip():
        return []
    try:
        d = json.loads(raw)
    except json.JSONDecodeError as e:
        try:
            d = json.loads(raw[: e.pos])
        except Exception:
            return []
    except Exception:
        return []
    if isinstance(d, list):
        return d
    if isinstance(d, dict):
        return d.get("issues") or d.get("beads") or d.get("items") or []
    return []


# ── DIMENSION 1: deploy-block (the exact thing that stalled us) ───────────────
def deploy_block(now=None):
    """Return a reason string if any rig root has unpushed commits (ahead of
    origin/main) — which blocks the deploy cron's `git pull --ff-only` — or has truly
    diverged. Else None. Fetches origin/main first (best-effort: a failed fetch on a
    rig is skipped, never flagged — FAIL-SAFE). Uses `git -C <root>` only (reliable
    across rigs; `bd -C` is not)."""
    blocked = []
    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue
        # Must be a real git work tree; otherwise skip (never flag a non-repo).
        if not sh(["git", "-C", root, "rev-parse", "--is-inside-work-tree"]):
            continue
        chk = sh(["git", "-C", root, "rev-parse", "--is-inside-work-tree"])
        if not chk or chk.returncode != 0 or "true" not in (chk.stdout or ""):
            continue
        # Refresh origin/<branch> (best-effort; a transient fetch failure is NOT a stall).
        sh(["git", "-C", root, "fetch", "--quiet", REMOTE, BRANCH], timeout=GIT_FETCH_TIMEOUT)
        # ahead\tbehind relative to the remote tracking ref.
        lr = sh(["git", "-C", root, "rev-list", "--left-right", "--count",
                 "%s/%s...HEAD" % (REMOTE, BRANCH)])
        if not lr or lr.returncode != 0:
            continue  # can't resolve (remote ref missing / detached) → don't flag
        parts = (lr.stdout or "").split()
        if len(parts) != 2:
            continue
        try:
            behind, ahead = int(parts[0]), int(parts[1])
        except ValueError:
            continue
        if ahead >= DEPLOY_BLOCK_MIN_AHEAD and behind > 0:
            blocked.append("%s DIVERGIDO (ahead=%d unpushed, behind=%d) — ff-pull do deploy "
                           "ABORTA; precisa rebase deliberado" % (root, ahead, behind))
        elif ahead >= DEPLOY_BLOCK_MIN_AHEAD:
            blocked.append("%s AHEAD de %s/%s por %d commit(s) não-pushados — ff-pull do "
                           "deploy bloqueado (nada é deployado)" % (root, REMOTE, BRANCH, ahead))
    if not blocked:
        return None
    return "; ".join(blocked)


# ── DIMENSION 2: merge-stall under demand ─────────────────────────────────────
def merge_stall(now=None):
    """Return a reason string if the gate has produced no merge for MERGE_STALL_SEC
    WHILE there is pending work (queued markers in the dispatcher log OR open
    story:approved beads); else None.

    FAIL-SAFE guards (any → None):
      • dispatcher log missing/stale  → a dead engine is the engine-stall monitors' job
      • a merge happened within the window → flow exists
      • no pending demand (zero queued markers AND zero approved beads) → idle ≠ stalled
    """
    now = now if now is not None else time.time()
    if not file_fresh(DISPATCH_LOG, LOG_FRESH_SEC, now):
        return None
    lines = tail_lines(DISPATCH_LOG, 2000)
    if not lines:
        return None

    # Any merge within the window? → flow.
    last_merge = None
    for l in lines:
        if GATE_PASS_RE.search(l):
            e = log_ts_epoch(l)
            if e is not None:
                last_merge = e if last_merge is None else max(last_merge, e)
    if last_merge is not None and (now - last_merge) <= MERGE_STALL_SEC:
        return None  # merged recently → flowing

    # Pending demand? latest "Found N queued marker(s)" in the log.
    queued = 0
    for l in reversed(lines):
        m = QUEUED_RE.search(l)
        if m:
            queued = int(m.group(1))
            break

    # Also count open story:approved beads (work waiting to be dispatched/gated).
    approved = 0
    r = sh([BD, "list", "-l", "story:approved", "--status", "open", "--json"], timeout=20)
    if r and r.returncode == 0:
        approved = len(parse_bd_json(r.stdout))

    # A MERGE-stall means markers QUEUED in the gate are not draining. Approved beads
    # that never reached the gate (no marker) are a DISPATCH concern, not a merge one —
    # counting them false-fired this dimension on a healthy-but-STARVED gate (braked or
    # undispatched approved beads sitting upstream + 0 markers). Require queued>0 so this
    # only fires on a genuine gate-queue stall. (ga-mfeip 2026-06-19: starved ≠ stalled.)
    if queued <= 0:
        return None  # nothing queued in the gate → starved/idle, not merge-stalled

    age_min = int((now - last_merge) / 60) if last_merge is not None else None
    age_txt = ("último merge há %dmin" % age_min) if age_min is not None \
        else ("nenhum merge no tail (≥%dmin)" % (MERGE_STALL_SEC // 60))
    return ("Gate sem merge há >%dmin (%s) com demanda pendente "
            "(%d marker(s) na fila, %d bead(s) story:approved abertos) — fila não drena"
            % (MERGE_STALL_SEC // 60, age_txt, queued, approved))


# ── DIMENSION 3: stuck-execution ──────────────────────────────────────────────
def stuck_execution(now=None):
    """Return a reason string if any in_progress bead has updated_at older than
    STUCK_EXEC_SEC (assigned but not progressing); else None. FAIL-OPEN: a failed
    `bd list` or an unparseable timestamp yields no finding."""
    now = now if now is not None else time.time()
    r = sh([BD, "list", "--status", "in_progress", "--json"], timeout=25)
    if not r or r.returncode != 0:
        return None
    beads = parse_bd_json(r.stdout)
    if not beads:
        return None
    stuck = []
    for b in beads:
        if not isinstance(b, dict):
            continue
        e = parse_iso_epoch(b.get("updated_at") or b.get("updated") or b.get("updatedAt"))
        if e is None:
            continue  # can't age it → don't flag (fail-safe)
        age = now - e
        if age > STUCK_EXEC_SEC:
            who = b.get("owner") or b.get("assignee") or "?"
            stuck.append("%s (owner=%s) parado há %dh" % (b.get("id", "?"), who, int(age // 3600)))
    if not stuck:
        return None
    return ("bead(s) in_progress sem update há >%dh — atribuídos mas sem progresso: %s"
            % (STUCK_EXEC_SEC // 3600, "; ".join(stuck)))


# ── escalation: Mayor mail (durable, an agent that ACTS) + Athos ntfy ─────────
MAYOR_HEADER = (
    "WATCHDOG DE PRODUÇÃO: detectei um STALL CONFIRMADO no pipeline (2 ticks "
    "consecutivos). Investigue e RECONCILIE com cuidado — NÃO foi feito reconcile "
    "automático (reset cego é perigoso com edits uncommitted). Detalhe abaixo.\n\n")

REMEDY = {
    "deploy-block": (
        "REMÉDIO (deploy-block — a causa do stall de 2h em 2026-06-18):\n"
        "1. Para cada root listado: cd <root> && git -C <root> status; rev-list "
        "--left-right --count origin/main...HEAD.\n"
        "2. AHEAD (commits não-pushados): se forem commits legítimos, push deles "
        "(o gate/delivery normalmente faz isso); senão, rebase deliberado. Isso "
        "destrava o `git pull --ff-only` do cron de deploy.\n"
        "3. DIVERGIDO: stash → rebase origin/main → stash pop → push (procedimento "
        "[[hq-root-divergence-reconcile-stash-rebase-pop]]). NUNCA reset --hard cego.\n"
        "4. Confirme rev-list 0 0 e que o deploy voltou a rodar."),
    "merge-stall": (
        "REMÉDIO (merge-stall):\n"
        "1. tail -60 .gc/logs/quality-gate-dispatcher.log — veja head-of-line "
        "(mesmo branch re-pego) ou revisores natimortos.\n"
        "2. gc dolt status; se wedged, colete diag e restart.\n"
        "3. kickstart supervisor + quality-gate-dispatcher; confirme 'Gate PASSED'."),
    "stuck-exec": (
        "REMÉDIO (stuck-exec):\n"
        "1. gc session peek <owner/sessão> — confirme se está realmente parado.\n"
        "2. Shutdown-dance (3 nudges) ou kill pra liberar o slot; re-despache o bead.\n"
        "3. Se for misroute, circuit-break + reassine o dono correto."),
}


def escalate_mayor(dimension, reason):
    """Durable escalation to the Mayor. Returns True if the mail send reported success."""
    subject = "Watchdog: STALL de produção (%s)" % dimension
    body = MAYOR_HEADER + ("DIMENSÃO: %s\nMOTIVO: %s\n\n" % (dimension, reason)) \
        + REMEDY.get(dimension, "")
    r = sh([GC, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"], timeout=45)
    return bool(r and r.returncode == 0)


def notify_athos(msg, prio):
    sh([NOTIFY, "-t", "Watchdog produção", "-p", str(prio), msg], timeout=10)


# ── detection + tick loop (pure detect, hysteresis-gated escalation) ──────────
def detect(now):
    """Run all three checks; return list of (dimension, reason). Pure (no side effects)."""
    findings = []
    for dim, fn in (("deploy-block", deploy_block),
                    ("merge-stall", merge_stall),
                    ("stuck-exec", stuck_execution)):
        try:
            r = fn(now)
        except Exception as e:
            print("[prod-stall] check %s errored (treating as healthy): %r" % (dim, e),
                  flush=True)
            r = None
        if r:
            findings.append((dim, r))
    return findings


def new_state():
    return {d: {"last_escalate": 0.0, "escalations": 0, "pending": 0} for d in DIMENSIONS}


def run_tick(now, state):
    """One evaluation cycle: detect, reset recovered dimensions, escalate confirmed
    stalls gated by anti-flap hysteresis + per-dimension cooldown. All escalate/notify
    go through module functions so a test can monkeypatch them."""
    findings = detect(now)
    fired = {d for d, _ in findings}

    # recovery: a dimension that was pending/escalating but is now clear → reset.
    for dim, st in state.items():
        if dim not in fired and (st["escalations"] > 0 or st["pending"] > 0):
            if st["escalations"] > 0:
                print("[prod-stall] %s recovered — resetting" % dim, flush=True)
                notify_athos("Produção recuperada (%s)." % dim, 3)
            else:
                print("[prod-stall] %s cleared before confirmation (flap suppressed)" % dim,
                      flush=True)
            st["escalations"] = 0
            st["pending"] = 0

    for dim, reason in findings:
        st = state[dim]
        # Anti-flap hysteresis: require CONFIRM_TICKS consecutive detections.
        st["pending"] += 1
        if st["pending"] < CONFIRM_TICKS:
            print("[prod-stall] %s detected (%d/%d) — awaiting confirmation: %s"
                  % (dim, st["pending"], CONFIRM_TICKS, reason), flush=True)
            continue
        # Per-dimension cooldown: don't re-page the Mayor while a prior escalation is
        # still being handled.
        if now - st["last_escalate"] <= ESCALATE_COOLDOWN_SEC and st["last_escalate"] > 0:
            print("[prod-stall] %s confirmed but within cooldown — suppressing re-escalation"
                  % dim, flush=True)
            continue
        ok = escalate_mayor(dim, reason)
        if not ok:
            print("[prod-stall] %s mail to mayor FAILED — will retry next tick" % dim,
                  flush=True)
            # still ntfy Athos so a stall is never fully silent if mail is down
            notify_athos("⚠ STALL de produção (%s) mas o mail pro Mayor falhou: %s"
                         % (dim, reason[:120]), 4)
            _ledger("human-touch", {"ts": _datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "production-stall-watchdog", "stage": "executa", "kind": "technical", "bead_id": "", "reason": "STALL de produção (%s): %s" % (dim, reason[:120])}, fail_open=True)
            continue
        st["last_escalate"] = now
        st["escalations"] += 1
        notify_athos("STALL de produção (%s) — escalei pro Mayor investigar. Motivo: %s"
                     % (dim, reason[:140]), 4)
        _ledger("human-touch", {"ts": _datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "production-stall-watchdog", "stage": "executa", "kind": "technical", "bead_id": "", "reason": "STALL de produção (%s): %s" % (dim, reason[:120])}, fail_open=True)
        print("[prod-stall] ESCALATED to mayor dim=%s reason=%s" % (dim, reason), flush=True)


def main():
    if os.environ.get("PROD_STALL_WATCHDOG_ENABLED", "1") == "0":
        print("[prod-stall] disabled via PROD_STALL_WATCHDOG_ENABLED=0 — no-op", flush=True)
        return
    state = new_state()
    print("[prod-stall] production-stall watchdog started — deploy-block + merge-stall + "
          "stuck-exec; anti-flap hysteresis + per-dim cooldown; escalates to MAYOR "
          "(poll=%ds)" % POLL_SEC, flush=True)
    while True:
        try:
            run_tick(time.time(), state)
        except Exception as e:
            print("[prod-stall] loop error (continuing): %r" % e, flush=True)
        time.sleep(POLL_SEC)


if __name__ == "__main__":
    main()

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
    `bd` only for stuck-execution/demand/gate-queue reads, with short timeouts and fail-open.

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
     STUCK_EXEC_SEC (assigned but not progressing). Skips beads whose canonical
     state (bead_state.py) says the next move is not the executor's — parked, or
     awaiting the Athos (ga-teljci). If that model is unavailable it falls back to
     skipping beads labeled story:awaiting-external-merge or
     pilot:no-auto-dispatch — they already declare they're not
     dispatchable/actionable here (ga-e5tn8). A bead waiting in the gate's
     review queue is not an execution stall either — it is the gate's turn
     (an OPEN active marker/run names it): left out of the alarm and listed
     apart as "aguardando revisão no gate" (ga-z5311j).

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
import quiet_hours
from lib import rig_stores as rig_stores_lib

# ga-qhca1: scripts/bead_state.py is the city's single canonical park
# vocabulary (10 consumers used to each keep their own copy; every state bug
# measured 2026-08-09 was a disagreement between two of them). Import is
# DEFENSIVE and FAIL-OPEN to the old local list below — never crashes the
# loop, matching this module's own design principle.
_CANONICAL_STATE_FN = None
try:
    from bead_state import derive as _CANONICAL_STATE_FN  # type: ignore
except Exception:
    _CANONICAL_STATE_FN = None

# ga-z5311j: the canonical gate-queue label vocabulary (gate:queued / gate:reviewing /
# gate:needs-rebase). Used ONLY as the fallback when the gate itself could not be read —
# see _in_gate_queue(). Imported apart from derive() above so a bead_state without
# GATE_ACTIVE never takes the whole canonical model down with it.
try:
    from bead_state import GATE_ACTIVE as _GATE_LABELS  # type: ignore
except Exception:
    _GATE_LABELS = frozenset({"gate:queued", "gate:reviewing", "gate:needs-rebase"})

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
GATE_LOOKUP_TIMEOUT = int(os.environ.get("PROD_STALL_GATE_LOOKUP_TIMEOUT", "25"))  # per bd list of a gate artifact type
MAYOR_ADDR = os.environ.get("PROD_STALL_MAYOR_ADDR", "mayor")

# imp14: flow-authority advisory file path (shared with TSW, the elected authority).
# When TSW has already escalated a stall, PSW defers its own Mayor mail to avoid the
# "4 daemons independently page Mayor" escalation storm.
FLOW_AUTHORITY_FILE = os.environ.get(
    "PROD_STALL_FLOW_AUTHORITY_FILE",
    os.path.join(CITY, ".gc/runtime/flow-authority.json"))
FLOW_AUTHORITY_DEFER = os.environ.get("PROD_STALL_FLOW_AUTHORITY_DEFER", "1") == "1"

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


def _resolve_dynamic_rig_roots():
    """ga-vjybz8: replace the static RIG_ROOTS default with the live rig list —
    same bug class as ga-wz03iq's shell family: a rig added to `gc rig list`
    since the static default was written (lexbh, marketing, gastown, deacon)
    was silently never checked for deploy-block/merge-stall/stuck-exec here.

    Called ONCE from main(), before the sweep loop — deliberately NOT at import
    time, so test_production_stall_watchdog.py's importlib-based module loading
    (which never sets PROD_STALL_RIG_ROOTS and never calls main()) never
    triggers a live `gc rig list` call; it only ever sees the static default,
    then overrides RIG_ROOTS itself per-test exactly as it already does. No-op
    if PROD_STALL_RIG_ROOTS was set explicitly — RIG_ROOTS already honors that
    operator override from its module-level assignment above, and an explicit
    override always wins over derivation."""
    global RIG_ROOTS
    if "PROD_STALL_RIG_ROOTS" in os.environ:
        return
    roots = rig_stores_lib.rig_store_paths(GC)
    if roots:
        RIG_ROOTS = roots
        print("[prod-stall] resolved %d live rig root(s) via gc rig list: %s" % (
              len(RIG_ROOTS), ", ".join(RIG_ROOTS)), flush=True)
    else:
        print("[prod-stall] DEGRADED production-stall-watchdog-roots: gc rig list "
              "failed/timed out/empty — using static fallback (%s)" % ":".join(RIG_ROOTS),
              flush=True)
        sh([NOTIFY, "-t", "Production watchdog", "-p", "4",
            "gc rig list falhou/vazio — usando lista estatica de fallback"], timeout=10)


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
        # ga-b1iulk: errors="replace" — the dispatcher log holds lines cut mid-multibyte-character
        # (11 since 2026-09-15); a strict read raised UnicodeDecodeError, and the [] below made
        # merge_stall() answer None = "no stall" for every poll. Same idiom as the sibling
        # watchdogs' _tail() (throughput-stall-watchdog.py, gate_queue_backlog.py).
        with open(path, errors="replace") as f:
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
        # ga-1tj73: a SHALLOW checkout (e.g. a sibling worktree of this root's
        # common-dir did a --depth fetch, which marks $GIT_COMMON_DIR/shallow for
        # every worktree sharing it, this root included) makes the rev-list counts
        # below meaningless — ancestry past the shallow boundary reads as "no
        # common history", which rev-list --left-right reports as bogus large
        # ahead/behind numbers (seen in production: ahead=4869 behind=6). Detect
        # it FIRST and report the real condition instead of a fake "DIVERGIDO —
        # precisa rebase deliberado" that would send whoever acts on it toward a
        # dangerous manual rebase for something `git fetch --unshallow` fixes
        # safely. This watchdog only detects/reports (see module docstring); the
        # actual cure now runs automatically in deploy_daemons.sh /
        # viewer-deploy-sync.sh (ga-1tj73 part A).
        shallow = sh(["git", "-C", root, "rev-parse", "--is-shallow-repository"])
        if shallow and shallow.returncode == 0 and "true" in (shallow.stdout or ""):
            blocked.append("%s SHALLOW (git worktree common-dir marcado shallow por um checkout "
                           "irmão) — rode 'git -C %s fetch %s --unshallow'; NÃO é divergência "
                           "real, não precisa de rebase (ga-1tj73)" % (root, root, REMOTE))
            continue
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
    if last_merge is not None:
        # ga-lda92s: discount time the city spent in QUIET hours (deliberate
        # admission pause) from the elapsed clock — NOT a blanket silence for
        # the whole window (that would trade this false-positive for a
        # false-negative: a real stall starting 00h30 would go unseen for
        # 7h30). A stall that begins during quiet hours and is still
        # unresolved once the discount runs out still alarms, just correctly
        # later.
        quiet_adj = quiet_hours.elapsed_adjustment(last_merge, now, now=now)
        effective_elapsed = max(0, (now - last_merge) - quiet_adj)
        if effective_elapsed <= MERGE_STALL_SEC:
            return None  # merged recently (quiet-hours-adjusted) → flowing

    # Pending demand? latest "Found N queued marker(s)" in the log.
    queued = 0
    for l in reversed(lines):
        m = QUEUED_RE.search(l)
        if m:
            queued = int(m.group(1))
            break

    # Also count open story:approved beads (work waiting to be dispatched/gated).
    approved = 0
    r = sh([BD, "list", "-l", "story:approved", "--status", "open", "--json", "--limit", "0"], timeout=20)
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


# ga-e5tn8: labels that mean "in_progress but not actually stuck" — the bead
# itself declares it's waiting on something outside this rig's control (an
# external upstream PR review, days by construction) or has explicitly opted
# out of the auto-dispatch remedy this dimension's REMEDY text recommends
# (kill+redispatch). Flagging either as STUCK-EXECUTION contradicts what the
# bead already says about its own state — see ga-5ksp5, flagged after 15h
# while carrying both labels.
#
# ga-qhca1: this 2-label set is now a FALLBACK ONLY, used when the canonical
# model (bead_state.py) is unavailable. It went stale hours after ga-e5tn8
# created it: ga-w4k2z carried needs:engine-window, no-auto-dispatch (no
# 'pilot:' prefix) and pool:refused:engine-rebuild-required — none in this
# list — and still alarmed "STALL CONFIRMADO". See _canonical_turn_is_elsewhere().
STUCK_EXEC_EXCLUDE_LABELS = {"story:awaiting-external-merge", "pilot:no-auto-dispatch"}

# ga-teljci: the canonical model also says "in_progress, but the next move is not
# the executor's" for a bead that is NOT 'parked' — a bead waiting on a decision or
# action only the Athos can take is state=awaiting_athos/turn=athos (bead_state.derive
# rule 3, which runs BEFORE the park rule). Skipping on state=='parked' alone let it
# through to the age check, so ga-ormexj (the Mayor's mission bead, waiting on the
# Athos to buy an SSD) was flagged as "STALL CONFIRMADO stuck-exec" on every cycle
# it sat there, and the REMEDY (shutdown-dance/kill/redispatch) would be wrong.
# turn=='external' is the other not-the-executor turn; derive() only pairs it with
# state=='parked' today, so listing it is defensive, not a behavior change.
NOT_EXECUTOR_STATES = frozenset({"parked", "awaiting_athos"})
NOT_EXECUTOR_TURNS = frozenset({"athos", "external"})


def _canonical_turn_is_elsewhere(bead: dict):
    """True/False via scripts/bead_state.py: does the canonical model say the next
    move on this bead belongs to someone other than the executor holding it
    (deliberately parked, or the Athos's / an external party's turn)? None if the
    model is unavailable, erroring, or returned neither a state nor a turn (no
    verdict is not "executing normally") — the caller falls back to
    STUCK_EXEC_EXCLUDE_LABELS on None. No live_sessions passed: this check only
    reads labels, never a liveness verdict."""
    if _CANONICAL_STATE_FN is None:
        return None
    try:
        d = _CANONICAL_STATE_FN(bead)
        state, turn = d.get("state"), d.get("turn")
        if state is None and turn is None:
            return None
        return state in NOT_EXECUTOR_STATES or turn in NOT_EXECUTOR_TURNS
    except Exception:
        return None


# ga-z5311j: bd stamps `owner` with the git user.email of the clone that ran `bd create`;
# in the HQ that is a placeholder identity (test@example.com) — not a person and not a
# session. Printing it as the party holding the stuck slot sent the Mayor looking for
# someone to peek/kill who does not exist (07/10 mails: "ga-gm5rv5 (owner=test@example.com)").
PLACEHOLDER_OWNERS = frozenset({"test@example.com"})

# ga-z5311j: a bead can sit in_progress for hours, untouched, and be perfectly healthy
# because it is WAITING IN THE GATE'S REVIEW QUEUE (depth 25-30 on 07/10, waits of 9-13h
# were real). That is the gate's turn, not an executor's, and this dimension's REMEDY
# (shutdown-dance / kill / re-dispatch) would be wrong and destructive for it.
# "In the queue" is only believed with evidence: an OPEN type:quality-gate-marker or
# type:quality-gate-run in an active gate-status that names the bead (or its
# pilot.sling_bead — a wrapper dispatch keys the marker on the sling bead, ga-lrglm).
# A gate:queued label on its own is NOT evidence: a closed marker with a leftover label
# is exactly a bead nobody is working (ga-zltsr), so that case still alarms.
# Active vocabulary = pilot-dispatcher.sh::_beadid_has_active_gate_artifact and
# inflight-reclaim-guard.py::list_gate_active_source_beads; the guard's fail-safe is
# kept too (quality-gate-guard.sh::marker_active_from_labels): a marker with no
# gate-status label at all reads as active.
GATE_MARKER_ACTIVE = frozenset({"ready", "claimed", "queued", "dispatching", "reviewing", "running"})
GATE_RUN_TERMINAL = frozenset({"superseded", "aborted", "passed", "failed"})


def _parse_bd_array(raw):
    """Strict reader for a `bd list --json` body: the parsed list, or None when the body
    cannot be trusted. Unlike parse_bd_json() (fail-open: unreadable → []), an empty
    body, junk, or a JSON value that is not an array is NOT "nothing matched" — bd
    prints `[]` for that (quality-gate-guard.sh::verdict_count_from_query's contract).
    A trailing non-JSON summary line after the array is tolerated, same as parse_bd_json."""
    if not raw or not raw.strip():
        return None
    try:
        d, _end = json.JSONDecoder().raw_decode(raw.lstrip())
    except Exception:
        return None
    return d if isinstance(d, list) else None


def _gate_artifact_active(art, is_run):
    """Is this OPEN gate marker/run in an active gate-status? Mirrors the canonical
    classifiers (see the vocabulary note above): a marker is active when it carries no
    gate-status label at all or any of GATE_MARKER_ACTIVE (a mid-transition marker with
    two labels counts if either is active; needs-rebase / error / terminal ones do not —
    the gate stepped back onto an external actor, it is not "waiting for review"); a run
    is active unless it carries at least one gate-status and every one of them is
    terminal (a run with no gate-status label at all reads as active, same fail-safe)."""
    # vazio (sem labels / labels []) → statuses=[]: o fail-safe de cada tipo decide (ativo);
    # ilegível (labels que não é lista) → idem, nunca levanta
    raw = art.get("labels")
    statuses = [str(l).split(":", 1)[1] for l in raw
                if str(l).startswith("gate-status:")] if isinstance(raw, list) else []
    if is_run:
        return not (statuses and all(s in GATE_RUN_TERMINAL for s in statuses))
    return not statuses or any(s in GATE_MARKER_ACTIVE for s in statuses)


def _gate_active_source_beads():
    """frozenset of the source-bead ids that have an OPEN gate marker/run in an active
    gate-status, or None when the gate could not be read ("não sei"). Two bulk reads (one
    per artifact type), never one per bead: --include-infra because gate markers/runs are
    INFRA beads that bd hides by default (ga-vm20x), --limit 0 because bd silently cuts a
    list at 50 rows (ga-21kmp). A frozenset — even an empty one — is a CONFIRMED answer;
    None is the third state and must never be read as "nobody is at the gate"."""
    active = set()
    for gate_type, is_run in (("type:quality-gate-marker", False), ("type:quality-gate-run", True)):
        # vazio ([] confirmado, rc 0) → ninguém desse tipo no gate: nada entra em `active`;
        # falhou/ilegível (sh() sem resposta, rc != 0, corpo vazio ou que não é array JSON) →
        # devolve None já aqui, sem terminar o outro tipo: nunca vira [] confirmado
        r = sh([BD, "list", "--include-infra", "--label", gate_type, "--status", "open",
                "--json", "--limit", "0"], timeout=GATE_LOOKUP_TIMEOUT)
        if not r or r.returncode != 0:
            return None
        arts = _parse_bd_array(r.stdout)
        if arts is None:
            return None
        for art in arts:
            if not isinstance(art, dict) or not _gate_artifact_active(art, is_run):
                continue
            # vazio (sem labels / sem source-bead:) → o artefato não aponta bead nenhuma e não
            # entra; ilegível (labels que não é lista) → idem
            labels = art.get("labels")
            for l in (labels if isinstance(labels, list) else []):
                if str(l).startswith("source-bead:"):
                    active.add(str(l)[len("source-bead:"):])
    return frozenset(active)


def _in_gate_queue(bead, gate_sources):
    """Three-way verdict for a stale bead: True = confirmed in the gate queue (an active
    artifact names the bead or its pilot.sling_bead); False = confirmed NOT in it (the gate
    was read and nothing names the bead — a leftover gate:* label decides nothing); None =
    the gate could not be read (gate_sources is None)."""
    if gate_sources is None:
        return None
    ids = {bead.get("id")}
    # vazio (sem metadata / sem pilot.sling_bead) → só o id da própria bead; ilegível
    # (metadata que não é dict, sling que não é string) → idem
    meta = bead.get("metadata")
    sling = meta.get("pilot.sling_bead") if isinstance(meta, dict) else None
    if isinstance(sling, str) and sling.strip():
        ids.add(sling.strip())
    return bool(ids & gate_sources)


def _has_gate_label(bead):
    """Does the bead itself carry a gate-queue label? Only consulted when the gate could
    not be read: the same label heuristic bead_state.derive() falls back to when its
    caller did not resolve gate_active."""
    # vazio (sem labels) → False; ilegível (labels que não é lista) → False: sem prova, a
    # bead segue sob o teste de idade
    raw = bead.get("labels")
    return isinstance(raw, list) and any(isinstance(l, str) and l in _GATE_LABELS for l in raw)


# ── DIMENSION 3: stuck-execution ──────────────────────────────────────────────
def stuck_execution(now=None):
    """Return a reason string if any in_progress bead has updated_at older than
    STUCK_EXEC_SEC (assigned but not progressing); else None. FAIL-OPEN: a failed
    `bd list` or an unparseable timestamp yields no finding. Beads whose canonical
    state is parked / awaiting_athos (or whose turn is the Athos's or external) are
    skipped regardless of age — see ga-teljci; when the canonical model is
    unavailable, beads carrying a STUCK_EXEC_EXCLUDE_LABELS label are skipped
    instead — see ga-e5tn8.

    ga-z5311j: a stale bead waiting in the gate's review queue is not an execution stall
    either — it is the gate's turn. It is left out of the alarm and listed apart
    ("aguardando revisão no gate"): in the log on every sweep that has one, and also in the
    reason when other beads do alarm. The gate is read lazily (only once a bead is already stale; one
    marker query + one run query per sweep) and the answer has three outcomes —
    confirmed in the queue → listed apart; confirmed NOT in it (gate read, nothing
    names the bead) → a leftover gate:* label decides nothing and the bead still
    alarms; gate unreadable → the bead's own gate:* label decides, as bead_state.derive()
    does when its caller did not resolve gate_active, the bead is listed as "marker não
    verificado" and a DEGRADED line goes to the log."""
    now = now if now is not None else time.time()
    r = sh([BD, "list", "--status", "in_progress", "--json", "--limit", "0"], timeout=25)
    if not r or r.returncode != 0:
        return None
    beads = parse_bd_json(r.stdout)
    if not beads:
        return None
    stuck, waiting = [], []
    gate_sources, gate_read = None, False  # the gate is read once per sweep, and only for a bead already stale
    for b in beads:
        if not isinstance(b, dict):
            continue
        elsewhere = _canonical_turn_is_elsewhere(b)
        if elsewhere is True:
            continue  # bead_state.py: parked, or the Athos's/an external turn — not an execution stall
        if elsewhere is None and STUCK_EXEC_EXCLUDE_LABELS.intersection(b.get("labels") or []):
            continue  # canonical model unavailable — fall back to the old local list
        e = parse_iso_epoch(b.get("updated_at") or b.get("updated") or b.get("updatedAt"))
        if e is None:
            continue  # can't age it → don't flag (fail-safe)
        age = now - e
        if age > STUCK_EXEC_SEC:
            if not gate_read:
                gate_sources, gate_read = _gate_active_source_beads(), True
                if gate_sources is None:
                    print("[prod-stall] DEGRADED stuck-exec-gate-lookup: fila do gate ilegível "
                          "(bd list de marker/run falhou, estourou o tempo ou veio ilegível) — beads "
                          "com label gate:* ficam fora do alarme como 'marker não verificado'; as "
                          "sem label seguem sob o teste de idade", flush=True)
            in_queue = _in_gate_queue(b, gate_sources)
            if in_queue is True or (in_queue is None and _has_gate_label(b)):
                waiting.append("%s (há %dh%s)" % (b.get("id", "?"), int(age // 3600),
                                                  "" if in_queue else ", marker não verificado"))
                continue
            # ga-5r96t: assignee is who's actually holding the stuck slot (the
            # thing "gc session peek/kill" can act on) — owner is just who
            # created the bead, often a human with no session to peek/kill.
            # vazio (assignee e owner ausentes) → "?"; owner placeholder do HQ → "sem dono"
            # (ga-z5311j), nunca o e-mail de teste como se fosse alguém; ilegível (valor que
            # não é texto) → mostrado como veio, sem levantar
            assignee, owner = b.get("assignee"), b.get("owner")
            placeholder_owner = isinstance(owner, str) and owner in PLACEHOLDER_OWNERS
            if placeholder_owner:
                owner = None
            if assignee:
                label = "assignee=%s" % assignee
                if owner and owner != assignee:
                    label += " (owner=%s)" % owner
            elif owner:
                label = "owner=%s" % owner
            elif placeholder_owner:
                label = "sem dono"
            else:
                label = "?"
            stuck.append("%s (%s) parado há %dh" % (b.get("id", "?"), label, int(age // 3600)))
    if waiting:
        print("[prod-stall] stuck-exec: %d bead(s) aguardando revisão no gate (fora do alarme): %s"
              % (len(waiting), "; ".join(waiting)), flush=True)
    if not stuck:
        return None
    reason = ("bead(s) in_progress sem update há >%dh — atribuídos mas sem progresso: %s"
              % (STUCK_EXEC_SEC // 3600, "; ".join(stuck)))
    if waiting:
        shown = waiting[:5]
        reason += (" | aguardando revisão no gate (fila do gate, fora do alarme — não aplicar o "
                   "remédio a elas): %s%s" % ("; ".join(shown),
                                              " (+%d)" % (len(waiting) - len(shown))
                                              if len(waiting) > len(shown) else ""))
    return reason


# ── escalation: Mayor mail (durable, an agent that ACTS) + Athos ntfy ─────────
MAYOR_HEADER = (
    "WATCHDOG DE PRODUÇÃO: detectei um STALL CONFIRMADO no pipeline (2 ticks "
    "consecutivos). Investigue e RECONCILIE com cuidado — NÃO foi feito reconcile "
    "automático (reset cego é perigoso com edits uncommitted). Detalhe abaixo.\n\n")

REMEDY = {
    "deploy-block": (
        "REMÉDIO (deploy-block — a causa do stall de 2h em 2026-06-18):\n"
        "0. Se o motivo acima diz SHALLOW: rode o 'git fetch --unshallow' indicado "
        "e confirme 'git -C <root> rev-parse --is-shallow-repository' -> false. "
        "NÃO é divergência real — não faça rebase/stash por isso (ga-1tj73).\n"
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
        "0. Bead citada em 'aguardando revisão no gate' está na FILA DO GATE (vez do gate, "
        "não do executor): NÃO aplique os passos abaixo a ela (ga-z5311j).\n"
        "1. gc session peek <owner/sessão> — confirme se está realmente parado.\n"
        "2. Shutdown-dance (3 nudges) ou kill pra liberar o slot; re-despache o bead.\n"
        "3. Se for misroute, circuit-break + reassine o dono correto."),
}


def _tsw_flow_authority_active(now):
    """imp14: return True if TSW has already escalated and is the active flow authority."""
    if not FLOW_AUTHORITY_DEFER:
        return False
    try:
        with open(FLOW_AUTHORITY_FILE) as f:
            data = json.load(f)
        expires_at = float(data.get("expires_at", 0))
        if expires_at > now:
            print("[prod-stall] imp14: TSW flow-authority active (expires in %.0fmin) — "
                  "deferring Mayor mail to avoid escalation storm" % ((expires_at - now) / 60),
                  flush=True)
            return True
    except Exception:
        pass
    return False


def escalate_mayor(dimension, reason):
    """Durable escalation to the Mayor. Returns True if the mail send reported success."""
    # imp14: check if TSW (the elected flow authority) has already escalated.
    # If yes, suppress this Mayor mail to prevent the escalation storm.
    if _tsw_flow_authority_active(time.time()):
        return False  # suppressed; TSW is handling it
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
        # imp07 Dolt-INDEPENDENT invariant: notify is PRIMARY (zero Dolt dependency),
        # fired FIRST and unconditionally. gc mail send mayor is SECONDARY (best-effort).
        # If Dolt is down, notify fires regardless; mail failure never silences the alert.
        notify_athos("STALL de produção (%s) — escalando pro Mayor investigar. Motivo: %s"
                     % (dim, reason[:140]), 4)
        _ledger("human-touch", {"ts": _datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "production-stall-watchdog", "stage": "executa", "kind": "technical", "bead_id": "", "reason": "STALL de produção (%s): %s" % (dim, reason[:120])}, fail_open=True)
        ok = escalate_mayor(dim, reason)
        if not ok:
            print("[prod-stall] %s mail to mayor FAILED — notify already sent (imp07 invariant)" % dim,
                  flush=True)
            continue
        st["last_escalate"] = now
        st["escalations"] += 1
        print("[prod-stall] ESCALATED to mayor dim=%s reason=%s" % (dim, reason), flush=True)


def main():
    if os.environ.get("PROD_STALL_WATCHDOG_ENABLED", "1") == "0":
        print("[prod-stall] disabled via PROD_STALL_WATCHDOG_ENABLED=0 — no-op", flush=True)
        return
    try:
        _resolve_dynamic_rig_roots()
    except Exception as e:
        print("[prod-stall] _resolve_dynamic_rig_roots failed unexpectedly (%r) — "
              "keeping static RIG_ROOTS" % e, flush=True)
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

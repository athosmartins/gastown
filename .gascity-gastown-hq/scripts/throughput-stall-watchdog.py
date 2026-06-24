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
  • STALL = backlog_count >= TSW_BACKLOG_MIN AND dispatch_count == 0 AND merge_count == 0.
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

# ── paths ────────────────────────────────────────────────────────────────────
CITY = os.environ.get("GC_CITY_PATH", "/Users/athos/gt/.gascity-gastown-hq")
PILOT_LOG = os.path.join(CITY, ".gc/logs/pilot-dispatcher.log")
DISPATCH_LOG = os.path.join(CITY, ".gc/logs/quality-gate-dispatcher.log")
PILOT_DISPATCHABLE_JSON = os.path.join(os.path.expanduser("~"), ".gc/pilot-dispatchable.json")
NOTIFY_BIN = os.environ.get("NOTIFY_BIN", "/Users/athos/.local/bin/notify")
GC_BIN = os.environ.get("GC_BIN", "gc")
BD_BIN = os.environ.get("BD_BIN", "bd")

# Rig roots for git-log merge signal and bd backlog queries.
RIG_ROOTS = os.environ.get(
    "TSW_RIG_ROOTS",
    "/Users/athos/gt:/Users/athos/gt/whatsapp_automation:/Users/athos/gt/property_scrapers",
).split(":")

MAYOR_ADDR = os.environ.get("TSW_MAYOR_ADDR", "mayor")
STATE_FILE = os.environ.get("TSW_STATE_FILE",
                            os.path.join(CITY, ".gc/throughput-stall-watchdog-state.json"))

# ── knobs (all env-overridable) ───────────────────────────────────────────────
ENABLED = os.environ.get("TSW_ENABLED", "1") == "1"
DRY_RUN = os.environ.get("TSW_DRY_RUN", "0") == "1"
STALL_HOURS = float(os.environ.get("TSW_STALL_HOURS", "6"))
BACKLOG_MIN = int(os.environ.get("TSW_BACKLOG_MIN", "1"))
CONFIRM_SWEEPS = int(os.environ.get("TSW_CONFIRM_SWEEPS", "2"))
ESCALATE_COOLDOWN_SEC = int(os.environ.get("TSW_COOLDOWN_SEC", "21600"))  # 6h cooldown
POLL_SEC = int(os.environ.get("TSW_POLL_SEC", "1800"))                    # 30min cadence
BD_TIMEOUT = int(os.environ.get("TSW_BD_TIMEOUT", "25"))
GIT_TIMEOUT = int(os.environ.get("TSW_GIT_TIMEOUT", "30"))
LOG_TAIL = int(os.environ.get("TSW_LOG_TAIL", "3000"))   # lines to tail from pilot log

# ── log-line patterns ─────────────────────────────────────────────────────────
TS_RE = re.compile(r"\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]")
# "=== Pilot sweep complete: dispatched=N ..."
PILOT_COMPLETE_RE = re.compile(r"Pilot sweep complete: dispatched=(\d+)")
# "Gate PASSED:" in gate dispatcher log
GATE_PASS_RE = re.compile(r"Gate PASSED")
# Exclude labels for the backlog query: a bead with ANY of these is not "ready to dispatch"
EXCLUDE_LABELS_BACKLOG = frozenset({
    "gate:needs-human", "exec:manual", "blocked", "story:in-flight",
    "pilot:dispatched", "pilot:dispatching", "story:done",
})

# ── test seams (monkeypatched in --selftest) ──────────────────────────────────
# These are module-level callables so tests can substitute them without patching subprocess.
_read_pilot_log_lines = None   # () -> [str]; None = read from disk
_read_gate_log_lines = None    # () -> [str]; None = read from disk
_git_log_count = None          # (root, since_iso) -> int; None = run git
_bd_backlog = None             # (rig_root) -> list[dict]; None = run bd
_do_notify = None              # (msg, prio) -> None; None = run notify binary
_do_mail_mayor = None          # (subject, body) -> bool; None = run gc mail


# ── guarded subprocess ────────────────────────────────────────────────────────
def _sh(args, timeout=20, stdin=None):
    try:
        return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                              input=stdin)
    except Exception:
        return None


def _log(msg):
    print("[tsw] %s" % msg, flush=True)


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


# ── SIGNAL 1: dispatch signal ─────────────────────────────────────────────────
def dispatch_signal(now, window_sec):
    """Returns (count, last_dispatch_epoch) where count is dispatches in window.
    On any error returns (None, None) — caller treats as fail-open (count present).
    count=0 + last_dispatch_epoch=None means "zero dispatches, no evidence of ever having dispatched
    in the tail". last_dispatch_epoch may be an epoch OUTSIDE the window (most recent historical)."""
    if _read_pilot_log_lines is not None:
        lines = _read_pilot_log_lines()
    else:
        lines = _tail(PILOT_LOG, LOG_TAIL)

    if not lines:
        _log("dispatch_signal: pilot log empty/missing — fail-open (treating as dispatched)")
        return None, None  # fail-open: can't read log = can't claim stall

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
    """Returns (count, last_merge_epoch) of gate-PASSED events and/or git commits in window.
    On any error returns (None, None) — fail-open.

    The gate-log read is the authoritative signal. If both the gate log is truly
    unavailable (not stubbed, not a fresh file) AND all git queries fail, we return
    (None, None) to be fail-open. An empty-but-readable log (stub returns [] or file is
    just empty) combined with working git stubs returns (0, None) — a real zero, not a
    read failure."""
    count = 0
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
                    count += 1

    # 2b. Git commits to rig origin/main in the window.
    since_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now - window_sec))
    git_any_success = False
    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue
        if _git_log_count is not None:
            # Test seam: stub provided.
            n = _git_log_count(root, since_iso)
            git_any_success = True
        else:
            r = _sh(["git", "-C", root, "log", "--oneline",
                     "--since=%s" % since_iso, "origin/main"],
                    timeout=GIT_TIMEOUT)
            if r is None or r.returncode != 0:
                _log("merge_signal: git log failed for %s — skipping rig" % root)
                continue
            git_any_success = True
            n = len([l for l in (r.stdout or "").splitlines() if l.strip()])
        if n is None:
            continue
        count += n
        # We don't have exact epoch from git count, but presence of commits means recent flow.

    # Fail-open ONLY when we genuinely could not read either signal source.
    # If the gate log was readable (even empty) or git succeeded for at least one rig,
    # we have a valid (possibly-zero) count and should NOT treat it as fail-open.
    if not gate_log_read and not git_any_success:
        _log("merge_signal: gate log missing/unreadable AND all git queries failed — "
             "fail-open (treating as merged)")
        return None, None

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

    for root in RIG_ROOTS:
        root = root.strip()
        if not root:
            continue

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

        for b in beads:
            if not isinstance(b, dict):
                continue
            labels = set()
            raw_labels = b.get("labels") or b.get("label") or []
            if isinstance(raw_labels, list):
                labels = {str(l).strip() for l in raw_labels}
            elif isinstance(raw_labels, str):
                labels = {x.strip() for x in raw_labels.split(",") if x.strip()}
            # Exclude braked beads
            if labels & EXCLUDE_LABELS_BACKLOG:
                continue
            all_beads.append(b)

    if not at_least_one_success:
        _log("backlog_signal: all bd queries failed — fail-open (treating as backlog=0)")
        return None, []

    # Deduplicate across rigs (same bead id)
    seen = {}
    for b in all_beads:
        bid = b.get("id") or b.get("issue_id") or ""
        if bid and bid not in seen:
            seen[bid] = b

    unique = list(seen.values())
    sample = [{"id": b.get("id", "?"), "title": (b.get("title") or b.get("name") or "?")[:80]}
              for b in unique[:5]]
    return len(unique), sample


# ── state persistence ─────────────────────────────────────────────────────────
def _load_state():
    try:
        with open(STATE_FILE) as f:
            d = json.load(f)
            if isinstance(d, dict):
                d.setdefault("pending", 0)
                d.setdefault("last_escalate", 0.0)
                d.setdefault("escalations", 0)
                return d
    except Exception:
        pass
    return {"pending": 0, "last_escalate": 0.0, "escalations": 0}


def _save_state(state):
    try:
        os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
    except Exception as e:
        _log("WARN: failed to save state: %r" % e)


# ── escalation ────────────────────────────────────────────────────────────────
def _format_body(backlog_count, dispatch_count, last_dispatch_epoch,
                 merge_count, last_merge_epoch, sample_beads, now, window_sec):
    hrs = window_sec / 3600
    def _age(epoch):
        if epoch is None:
            return "desconhecido (nenhum registro no tail)"
        return "%.1fh atrás" % ((now - epoch) / 3600)

    lines = [
        "WATCHDOG DE THROUGHPUT: pipeline parado com backlog pronto — STALL CONFIRMADO",
        "",
        "Janela de análise: %.0fh" % hrs,
        "Backlog real (story:approved + ctx:ready, não-braked): %d bead(s)" % backlog_count,
        "Dispatches no período: %d  (último: %s)" % (dispatch_count or 0, _age(last_dispatch_epoch)),
        "Merges/Gate-PASSED no período: %d  (último: %s)" % (merge_count or 0, _age(last_merge_epoch)),
        "",
        "CONDIÇÃO DE STALL: backlog >= %d E 0 dispatches E 0 merges em %.0fh." % (BACKLOG_MIN, hrs),
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
        "2. bd -C /Users/athos/gt list -l story:approved --status open",
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
              merge_count, last_merge_epoch, sample_beads, now, window_sec):
    subject = "Watchdog: THROUGHPUT STALL — %d bead(s) prontos, 0 dispatches + 0 merges em %.0fh" % (
        backlog_count, window_sec / 3600)
    body = _format_body(backlog_count, dispatch_count, last_dispatch_epoch,
                        merge_count, last_merge_epoch, sample_beads, now, window_sec)
    notify_msg = ("THROUGHPUT STALL: %d bead(s) prontos, 0 dispatches + 0 merges em %.0fh"
                  " — Mayor notificado p/ investigar." % (backlog_count, window_sec / 3600))

    if DRY_RUN:
        _log("DRY_RUN: would escalate: subject=%r" % subject)
        _log("DRY_RUN: body=\n%s" % body)
        return True

    ok_mail = False
    if _do_mail_mayor is not None:
        ok_mail = _do_mail_mayor(subject, body)
    else:
        r = _sh([GC_BIN, "mail", "send", MAYOR_ADDR, "-s", subject, "-m", body, "--notify"],
                timeout=45)
        ok_mail = bool(r and r.returncode == 0)

    if _do_notify is not None:
        _do_notify(notify_msg, 4)
    else:
        _sh([NOTIFY_BIN, "-t", "Throughput stall", "-p", "4", notify_msg], timeout=10)

    _tsw_ledger("human-touch", {"ts": _tsw_datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"), "source_daemon": "throughput-stall-watchdog", "stage": "executa", "kind": "technical", "bead_id": "", "reason": notify_msg}, fail_open=True)

    if not ok_mail:
        _log("WARN: gc mail send mayor FAILED — notify still sent")
    return ok_mail


# ── main detection tick ───────────────────────────────────────────────────────
def run_tick(now, state):
    """One evaluation cycle. Mutates state in-place. Returns True if a stall was confirmed
    and escalated this tick; False otherwise. All signals are fail-open: an error in reading
    any signal is treated as 'flow present', never false-alarming."""
    window_sec = STALL_HOURS * 3600

    # SIGNAL 1: dispatch
    dispatch_count, last_dispatch_epoch = dispatch_signal(now, window_sec)
    if dispatch_count is None:
        # Fail-open: can't read pilot log
        _log("tick: dispatch_signal fail-open → treating as dispatched, resetting stall counter")
        _maybe_recover(state, "dispatch-signal unavailable")
        return False

    # SIGNAL 2: merge
    merge_count, last_merge_epoch = merge_signal(now, window_sec)
    if merge_count is None:
        # Fail-open: can't read gate log or git
        _log("tick: merge_signal fail-open → treating as merged, resetting stall counter")
        _maybe_recover(state, "merge-signal unavailable")
        return False

    # Short-circuit: if there's any dispatch or merge, no stall
    if dispatch_count > 0 or merge_count > 0:
        if state["pending"] > 0 or state["escalations"] > 0:
            _log("tick: flow detected (dispatched=%d merged=%d) — stall cleared" % (
                 dispatch_count, merge_count))
            _maybe_recover(state, "flow resumed")
        else:
            _log("tick: flow present (dispatched=%d merged=%d in %.0fh) — healthy" % (
                 dispatch_count, merge_count, STALL_HOURS))
        return False

    # SIGNAL 3: backlog (only evaluate if dispatch+merge are both 0 to save BD load on healthy system)
    backlog_count, sample_beads = backlog_signal()
    if backlog_count is None:
        # Fail-open: can't read BD
        _log("tick: backlog_signal fail-open → treating as no backlog, resetting stall counter")
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

    ok = _escalate(backlog_count, dispatch_count, last_dispatch_epoch,
                   merge_count, last_merge_epoch, sample_beads, now, window_sec)
    state["last_escalate"] = now
    state["escalations"] += 1
    _log("escalation %s (total escalations: %d)" % ("OK" if ok else "FAILED (notify still sent)",
                                                     state["escalations"]))
    return True


def _maybe_recover(state, reason):
    if state["pending"] > 0 or state["escalations"] > 0:
        _log("RECOVERED (%s): stall cleared (was pending=%d escalations=%d)" % (
             reason, state["pending"], state["escalations"]))
        state["pending"] = 0
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
    global _bd_backlog, _do_mail_mayor, _do_notify

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
        return {"pending": 0, "last_escalate": 0.0, "escalations": 0}

    def _stub_mail(subject, body):
        mail_calls.append((subject, body))
        return True

    def _stub_notify(msg, prio):
        notify_calls.append((msg, prio))

    _do_mail_mayor = _stub_mail
    _do_notify = _stub_notify

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

    # ── B: backlog>0 but recent dispatch → NO stall ───────────────────────────────
    print("\nScenario B: recent dispatch → no stall")
    _read_pilot_log_lines = lambda: _pilot_lines(1, 2)  # dispatched=1
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: _backlog(5)
    mail_calls.clear(); notify_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not st["pending"] and not st["escalations"] and not mail_calls:
        _ok("B: recent dispatch → no stall")
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
    print("\nScenario E: confirm-reset: stall T0, flow T1, stall T2 → counter starts over")
    _calls = [0]
    def _pilot_e():
        _calls[0] += 1
        return _pilot_lines(0, 2) if _calls[0] != 2 else _pilot_lines(1, 1)
    _read_pilot_log_lines = _pilot_e
    _read_gate_log_lines  = lambda: []
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
    print("\nScenario G: braked beads (gate:needs-human / story:in-flight) → excluded, no alarm")
    _read_pilot_log_lines = lambda: _pilot_lines(0, 3)
    _read_gate_log_lines  = lambda: []
    _git_log_count        = lambda root, since: 0
    _bd_backlog           = lambda root: [
        {"id": "wa-0001", "title": "Braked",    "labels": ["story:approved", "gate:needs-human"]},
        {"id": "wa-0002", "title": "In-flight", "labels": ["story:in-flight"]},
        {"id": "wa-0003", "title": "Manual",    "labels": ["story:approved", "exec:manual"]},
    ]
    mail_calls.clear()
    st = _reset()
    run_tick(NOW, st); run_tick(NOW + 1800, st)
    if not st["escalations"] and not mail_calls:
        _ok("G: all braked/in-flight/manual beads excluded → no false alarm")
    else:
        _bad("G", "escalations=%d mails=%d" % (st["escalations"], len(mail_calls)))

    print("\n[tsw selftest] %d passed, %d failed" % (ok_count[0], fail_count[0]))
    sys.exit(0 if fail_count[0] == 0 else 1)


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        _selftest()
    else:
        main()

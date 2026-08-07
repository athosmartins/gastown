#!/usr/bin/env python3
"""Problem-only gate/loop health monitor.

Emits a line ONLY for actionable problems (silence = healthy):
  [GATE FAIL]           a review genuinely failed
  [REAL-JAM]            a gate marker is queued/claimed but not completing (true wedge)
  [GATE-ERROR]          one or more gate markers stuck in gate-status:error (spawn/dispatch failure)
  [DELIVERY-FAIL]       a delivery failed or HALTed
  [ASYNC-START-REGRESS] the stale_async_start race fix is MISSING from the live gc binary
  [ASYNC-START-RACE]    stale_async_start race rate spiked above threshold
  [VERDICT-ASSIGNEE-GAP] a pending verdict bead has had no assignee for too long (ga-mo7q)

Deliberately does NOT emit routine GATE PASS / PILOT dispatch / DELIVERY PASS —
those are normal operation and were the source of the old monitor's noise.
The old JAMMED heuristic (no merge in 20min + >=3 in-flight) fired on a
saturated-but-busy gate; this one keys off a marker that is actually stuck.

[GATE-ERROR] closes the blind spot exposed by the 2026-06-06 town-wide outage:
markers landing in gate-status:error (spawn/dispatch failure) were invisible
to the old four checks. Now alerts when any open error marker stays in error
past ERROR_STUCK_SEC (10min). Uses first-seen tracking to avoid alerting on
normal churn (error→queued→error during rebase-attempt cycles).

[ASYNC-START-REGRESS] + [ASYNC-START-RACE] close the regression blind spot for
the stale_async_start race fix shipped in gc-patched-asyncstart (4f57fbac4):
the fix adds a 3rd config-drift-drain exemption for gate-reviewers in state=
creating, identified by 'async-start (fresh creating)' in the binary. If the
binary is rebuilt without the fix, reviewer-spawn flakiness resurges silently.
Env: GATE_REVIEWER_RACE_CHECK=1 (default on), GATE_REVIEWER_RACE_MAX (default 8/h).

[VERDICT-ASSIGNEE-GAP] (ga-mo7q) closes the blind spot measured at 30% of
verdict beads: quality-gate-dispatcher.sh creates the verdict bead, then
SEPARATELY assigns it to the reviewer's session name (assign_verdict_bead_verified,
ga-vdurb) — that second write can fail silently, leaving a bead the reviewer's
`--assignee` poll can never find. The reviewer now also falls back to
`metadata.gc.session_name` (ga-mo7q fix b) so most cases self-heal, but this
check gives an independent, bead-content-level signal for the residual cases —
any open verdict:pending bead with no assignee past ASSIGNEE_GAP_STUCK_SEC
(1min) is a defect worth surfacing, not routine churn (a fresh bead's assignee
write is near-instant, so first-seen tracking exists only to skip the write's
own brief in-flight window, not to absorb genuine multi-minute staleness).
"""
import json, time, datetime, subprocess, os, re

QG = ".gc/quality-gate.jsonl"
SD = ".gc/story-delivery.jsonl"
DISPATCH_LOG = ".gc/logs/quality-gate-dispatcher.log"  # sweeps every ~3min
STUCK_SEC = 1500        # 25min queued-with-no-completion = real wedge
REALERT_SEC = 900       # re-warn a still-stuck marker every 15min
ENGINE_STALL_SEC = 900  # dispatcher log silent >15min = engine dead/hung
ERROR_STUCK_SEC = 600   # 10min in gate-status:error = dispatch failure worth alarming
VERDICT_STALL_SEC = 1500  # 25min of a gate-run's pending verdicts not changing = idle reviewer(s) (ga-noxbv)
NOMERGE_STALL_SEC = 900   # 15min: queue has not ADVANCED + work queued + no review in flight = stuck (ga-hl0gq)
RACE_WINDOW_SEC = 3600    # 1h rolling window for stale_async_start race-rate check
ASSIGNEE_GAP_STUCK_SEC = 60  # ga-mo7q: >60s with no assignee on a pending verdict bead = defect, escalate
# QG events that ADVANCE the queue (a marker reached a handled/terminal state).
# autorebase_retry + guard_queued do NOT count — they are the non-advancing re-queue loop.
PROGRESS_EVENTS = {"dispatcher_complete", "dispatcher_superseded", "dispatcher_needs_rebase"}

# Env knobs for the async-start regression checks.
# GATE_REVIEWER_RACE_CHECK=0 disables both checks (default on = "1").
# GATE_REVIEWER_RACE_MAX sets the per-hour spike threshold (default 8).
_RACE_CHECK = os.environ.get("GATE_REVIEWER_RACE_CHECK", "1") != "0"
_RACE_MAX   = int(os.environ.get("GATE_REVIEWER_RACE_MAX", "8"))


def age(ts):
    try:
        t = datetime.datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=datetime.timezone.utc).timestamp()
        return time.time() - t
    except Exception:
        return 0


def count(path):
    try:
        return sum(1 for _ in open(path))
    except FileNotFoundError:
        return 0


def still_queued(bead):
    """True only if the bead is CURRENTLY a genuinely-stuck gate marker
    (gate-status:queued = accepted but not picked up by the dispatcher). If it's
    dispatching (actively under review, verdicts coming), passed/failed/superseded/
    terminal, or absent -> NOT a wedge. Unknown -> False (don't alert)."""
    try:
        out = subprocess.run(["gc", "bd", "show", bead], capture_output=True,
                             text=True, timeout=15).stdout.lower()
    except Exception:
        return False
    return "gate-status:queued" in out


def list_error_markers():
    """Return list of open quality-gate markers currently in gate-status:error.
    Returns list of dicts with keys: id, branch, source_bead.
    Markers that are also 'superseded' are excluded — they are terminal.
    Uses no --all so only open (non-closed) markers are returned."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-marker",
             "-l", "gate-status:error", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        markers = json.loads(result.stdout)
        out = []
        for m in markers:
            labels = m.get("labels", [])
            # Belt-and-suspenders: skip superseded (open-only query should already exclude)
            if "gate-status:superseded" in labels:
                continue
            branch = next((l[len("branch:"):] for l in labels if l.startswith("branch:")), "")
            source_bead = next((l[len("source-bead:"):] for l in labels if l.startswith("source-bead:")), "")
            out.append({"id": m["id"], "branch": branch, "source_bead": source_bead})
        return out
    except Exception:
        return []


def pending_verdicts_by_run():
    """Map gate-run id -> sorted list of its still-OPEN verdict bead ids.

    Each reviewer gets an ephemeral verdict bead labelled gate-run:<id> +
    verdict:pending; it closes (drops out of this open-only query) the moment the
    reviewer records its verdict. So a run whose set of pending verdict beads is
    UNCHANGED over time = reviewers that have made no progress (idle/stuck) —
    today's ga-noxbv hang signature (stuck at 1/3 for 38min). Returns {} on any
    failure so the caller simply skips this cycle's idle-reviewer check."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-verdict", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return {}
        runs = {}
        for v in json.loads(result.stdout):
            labels = v.get("labels", [])
            if "verdict:pending" not in labels:
                continue
            run = next((l[len("gate-run:"):] for l in labels if l.startswith("gate-run:")), "")
            if run:
                runs.setdefault(run, []).append(v["id"])
        return {r: sorted(ids) for r, ids in runs.items()}
    except Exception:
        return {}


def verdict_beads_missing_assignee():
    """Return open verdict beads (type:quality-gate-verdict, verdict:pending)
    that have no assignee set (ga-mo7q). Returns a list of bead ids on success
    (possibly empty — genuinely no gap), or None if the query itself failed
    (non-zero exit, timeout, unparseable output). Callers MUST treat None as
    "unknown" and skip both alerting and prune-tracking that cycle — conflating
    query failure with genuine-empty here would corrupt first-seen tracking the
    same way this detector exists to catch (gate feedback on ga-mo7q attempt 1)."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-verdict",
             "-l", "verdict:pending", "--no-assignee", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0:
            return None
        if not result.stdout.strip():
            return []
        return [b["id"] for b in json.loads(result.stdout)]
    except Exception:
        return None


def dolt_responsive():
    """Quick probe: can we read beads in <5s? Verdicts travel through Dolt, so a
    slow/unreachable server makes 'no verdict progress' Dolt's fault, not an idle
    reviewer. We suppress the idle-reviewer alert in that case (false-positive
    guard required by ga-noxbv)."""
    try:
        t0 = time.time()
        r = subprocess.run(["gc", "bd", "list", "-l", "type:quality-gate-marker", "--json"],
                           capture_output=True, text=True, timeout=8)
        return r.returncode == 0 and (time.time() - t0) < 5
    except Exception:
        return False


def queued_marker_ids():
    """IDs of open gate markers currently in gate-status:queued (work waiting to be
    picked up). Used by the GATE-NOMERGE throughput check to confirm there IS work
    the gate is failing to advance. Returns [] on any failure (skip the check)."""
    try:
        result = subprocess.run(
            ["gc", "bd", "list", "-l", "type:quality-gate-marker",
             "-l", "gate-status:queued", "--json", "--limit", "0"],
            capture_output=True, text=True, timeout=20)
        if result.returncode != 0 or not result.stdout.strip():
            return []
        return [m["id"] for m in json.loads(result.stdout)
                if "gate-status:superseded" not in m.get("labels", [])]
    except Exception:
        return []


# ── ga-kpv48: per-alert cooldown on the notify path ──────────────────────────
# emit() had NO dedup: a condition that stays true re-fired every loop (120s)
# forever. The first-seen trackers upstream gate only the START of an alert,
# never its repetition. Measured 2026-07-30: ~5-8k notifies/day, ~96k since
# 06-06, from ~7 persistent conditions x 720 cycles/day. Two consequences:
#   1. it rate-limited the city's ENTIRE ntfy channel (429s) — alerting went
#      100% blind from 04:03, and this monitor was the top talker;
#   2. notify blocks when transport is dead (measured: 76s/call), so at ~360
#      emits/h the monitor spent ~100% of its wall-clock inside notify. It was
#      queueing on curl, not watching the gate — the alert loop starved the
#      very check it exists to run.
# Fix: suppress a REPEAT of the same alert inside EMIT_COOLDOWN_SEC. The key
# normalizes digits away, so a drifting counter ("stuck 140min" -> "142min")
# does not defeat dedup while distinct entities stay distinct. stdout is ALWAYS
# printed — the local log keeps full fidelity and the digest still sees every
# cycle; only the outbound notify is gated. Cooldown is the mechanism the
# module docstring already implied ("silence = healthy") but never had.
EMIT_COOLDOWN_SEC = int(os.environ.get("GATE_HEALTH_EMIT_COOLDOWN_SEC", "3600"))
_emit_last_notified = {}


def emit_key(msg):
    """Identity of an alert, ignoring volatile counters. PURE (no I/O)."""
    return re.sub(r"\d+", "#", msg)


def emit_should_notify(msg, now, last_notified, cooldown=None):
    """True iff this alert may reach notify now. PURE (no I/O, no clock, no
    mutation) — `now` and the state dict are injected so this is testable."""
    cd = EMIT_COOLDOWN_SEC if cooldown is None else cooldown
    prev = last_notified.get(emit_key(msg))
    return prev is None or (now - prev) >= cd


def emit(msg):
    """Print alert line and fire notify CLI (best-effort, never crash on failure).

    The print is unconditional; the notify is rate-limited per distinct alert
    (ga-kpv48) so a persistent condition alerts hourly instead of every 120s.
    """
    print(msg, flush=True)
    now = time.time()
    if not emit_should_notify(msg, now, _emit_last_notified):
        return
    _emit_last_notified[emit_key(msg)] = now
    try:
        subprocess.run(
            ["/Users/athos/.local/bin/notify", "-t", "Gate health", "-p", "4", msg],
            timeout=10, capture_output=True)
    except Exception:
        pass


def count(path):
    try:
        return sum(1 for _ in open(path))
    except FileNotFoundError:
        return 0


# ---------------------------------------------------------------------------
# Async-start race regression helpers (4f57fbac4 / gc-patched-asyncstart)
# ---------------------------------------------------------------------------

def _disp_log_ts(line):
    """Parse the local-time epoch from a dispatcher log line '[YYYY-MM-DD HH:MM:SS]'.
    Returns None on any failure (missing prefix, malformed timestamp, etc.)."""
    try:
        if not line.startswith("["):
            return None
        ts = line[1:20]  # "YYYY-MM-DD HH:MM:SS"
        return time.mktime(time.strptime(ts, "%Y-%m-%d %H:%M:%S"))
    except Exception:
        return None


def _gc_binary_path():
    """Resolve the live gc binary path (follows symlinks). Returns None on failure."""
    try:
        r = subprocess.run(["which", "gc"], capture_output=True, text=True, timeout=5)
        if r.returncode != 0 or not r.stdout.strip():
            return None
        rl = subprocess.run(["readlink", "-f", r.stdout.strip()],
                             capture_output=True, text=True, timeout=5)
        p = (rl.stdout or "").strip()
        return p if p else r.stdout.strip()
    except Exception:
        return None


def _binary_has_async_start_fix(path):
    """Check if the gc binary at `path` contains the async-start race fix string.

    The fix (4f57fbac4, generalized by ee6999666) emits a config-drift-drain
    exemption message containing the substring 'async-start (fresh creating'
    for any fresh-wake ephemeral worker, e.g.:
      "Skipping config-drift drain for '%s': ephemeral worker in async-start
      (fresh creating, wake_mode=fresh)"
    We deliberately do NOT include the closing paren in the probe: ee6999666
    inserted ", wake_mode=fresh)" between "fresh creating" and the paren, so
    the original probe (which matched through the closing paren) went stale
    the moment that wording changed, firing ~275 false [ASYNC-START-REGRESS]
    alerts (ga-4bai6) even though the fix was intact. Truncating before the
    paren keeps the match anchored to the stable prefix both the old and
    current message share.

    Returns:
      True  — fix is present (binary is patched)
      False — fix is absent (regression: binary was rebuilt/reverted without the fix)
      None  — binary unreadable / `strings` failed (fail-open: do NOT alert)
    """
    if not path:
        return None
    try:
        r = subprocess.run(["strings", path], capture_output=True, text=True, timeout=30)
        if r.returncode != 0:
            return None
        return "async-start (fresh creating" in r.stdout
    except Exception:
        return None


def _count_async_start_races_in_text(lines, window_sec, now=None):
    """Pure core: count 'stale_async_start race' occurrences in `lines` that fall
    within the last `window_sec` seconds. `now` defaults to time.time().
    Separated from I/O so the selftest can drive it with synthetic log lines."""
    if now is None:
        now = time.time()
    hits = 0
    for l in lines:
        if "stale_async_start race" not in l:
            continue
        ts = _disp_log_ts(l)
        if ts and now - ts <= window_sec:
            hits += 1
    return hits


def _count_async_start_races(window_sec=RACE_WINDOW_SEC):
    """Count 'stale_async_start race' occurrences in DISPATCH_LOG within the last
    `window_sec` seconds. Returns 0 on any error (fail-open: log absent or
    unreadable → no alert, never false-alarm)."""
    try:
        with open(DISPATCH_LOG) as f:
            lines = f.readlines()[-4000:]
    except Exception:
        return 0
    return _count_async_start_races_in_text(lines, window_sec)


if __name__ == "__main__":
    qg_seen = count(QG)
    sd_seen = count(SD)
    alerted = {}          # bead_id -> last-alerted timestamp (queued wedge alerts)
    engine_alerted = 0
    error_first_seen = {}  # bead_id -> first-seen timestamp (for error-stuck tracking)
    error_alerted = {}     # bead_id -> last-alerted timestamp (for error re-alert cadence)
    verdict_progress = {}  # gate-run -> {"sig": tuple(pending ids), "since": ts, "alerted": ts} (ga-noxbv idle-reviewer)
    nomerge_alerted = 0    # last-alerted ts for the GATE-NOMERGE throughput check (ga-hl0gq)
    binary_regress_alerted = 0  # last-alerted ts for ASYNC-START-REGRESS binary check
    race_spike_alerted = 0      # last-alerted ts for ASYNC-START-RACE spike check
    assignee_gap_first_seen = {}  # bead_id -> first-seen timestamp (ga-mo7q assignee-gap tracking)
    assignee_gap_alerted = {}     # bead_id -> last-alerted timestamp (ga-mo7q re-alert cadence)

    while True:
        # --- engine liveness: dispatcher log must keep sweeping ---
        try:
            m = os.path.getmtime(DISPATCH_LOG)
            stale = time.time() - m
            if stale > ENGINE_STALL_SEC and time.time() - engine_alerted > REALERT_SEC:
                emit("[ENGINE-STALL] gate dispatcher log silent %dmin - dispatcher may be "
                     "dead/hung" % int(stale / 60))
                engine_alerted = time.time()
        except OSError:
            pass

        # --- gate: new FAILs + stuck-marker detection ---
        try:
            lines = open(QG).read().splitlines()
        except FileNotFoundError:
            lines = []
        for l in lines[qg_seen:]:
            try:
                r = json.loads(l)
            except Exception:
                continue
            if r.get("event") == "dispatcher_complete" and str(r.get("result", "")).upper() == "FAIL":
                emit("[GATE FAIL] %s %s — %s" % (
                    r.get("bead"), r.get("branch", ""), (r.get("reason") or "")[:80]))
        qg_seen = len(lines)

        last = {}
        for l in lines:
            try:
                r = json.loads(l)
            except Exception:
                continue
            b = r.get("bead")
            if b:
                last[b] = r
        for b, r in last.items():
            if r.get("event") == "guard_queued":
                a = age(r.get("ts", ""))
                if a > STUCK_SEC and (b not in alerted or time.time() - alerted[b] > REALERT_SEC):
                    if not still_queued(b):
                        alerted[b] = time.time()  # dispatched/failed/done — not a wedge; skip
                        continue
                    emit("[REAL-JAM] gate marker %s stuck %dmin (queued, no completion) "
                         "- gate may be wedged" % (b, int(a / 60)))
                    alerted[b] = time.time()

        # --- GATE-ERROR: markers stuck in gate-status:error (dispatch/spawn failure) ---
        # This is the blind spot from the 2026-06-06 outage: the dispatcher kept logging
        # (no ENGINE-STALL), markers were :error not :queued (no REAL-JAM), no review FAIL.
        # Strategy: query open error markers each cycle; track first-seen per marker.
        # Alert only after ERROR_STUCK_SEC (10min) to absorb normal rebase-attempt churn
        # (error→queued→error). Re-alert every REALERT_SEC (15min) until resolved.
        current_error_ids = set()
        for em in list_error_markers():
            mid = em["id"]
            current_error_ids.add(mid)
            now = time.time()
            if mid not in error_first_seen:
                error_first_seen[mid] = now  # just appeared, start the clock
            stuck_for = now - error_first_seen[mid]
            if stuck_for > ERROR_STUCK_SEC:
                last_alert = error_alerted.get(mid, 0)
                if now - last_alert > REALERT_SEC:
                    emit("[GATE-ERROR] marker %s (%s) stuck in gate-status:error for %dmin "
                         "— branch: %s source: %s" % (
                             mid, em["source_bead"], int(stuck_for / 60),
                             em["branch"], em["source_bead"]))
                    error_alerted[mid] = now
        # Prune markers that are no longer in error (resolved/superseded/closed)
        gone = set(error_first_seen.keys()) - current_error_ids
        for mid in gone:
            error_first_seen.pop(mid, None)
            error_alerted.pop(mid, None)

        # --- VERDICT-ASSIGNEE-GAP: pending verdict bead created with no assignee (ga-mo7q) ---
        # Measured 30% of verdict beads: the durable-pull assign write
        # (assign_verdict_bead_verified, ga-vdurb) can fail silently after the bead
        # itself was created fine, leaving the reviewer's --assignee poll blind to
        # it. The reviewer now also falls back to metadata.gc.session_name (ga-mo7q
        # fix b) so most cases self-heal without ever reaching this alert — this is
        # the independent, bead-content-level backstop for the residual cases (and
        # for the rarer case where the fallback also can't resolve it, e.g. spawn
        # never delivered a session_name at all). Same first-seen + re-alert
        # cadence as GATE-ERROR above, just a much shorter threshold since a
        # healthy write completes in well under a second.
        gap_ids = verdict_beads_missing_assignee()
        # None means the query itself failed (Dolt hiccup/timeout) — skip alert-check
        # AND prune this cycle; treating that like "no gap" would silently reset
        # first-seen tracking and could mask a real stuck bead for the outage's duration.
        if gap_ids is not None:
            current_gap_ids = set()
            for vid in gap_ids:
                current_gap_ids.add(vid)
                now = time.time()
                if vid not in assignee_gap_first_seen:
                    assignee_gap_first_seen[vid] = now  # just appeared, start the clock
                stuck_for = now - assignee_gap_first_seen[vid]
                if stuck_for > ASSIGNEE_GAP_STUCK_SEC:
                    last_alert = assignee_gap_alerted.get(vid, 0)
                    if now - last_alert > REALERT_SEC:
                        emit("[VERDICT-ASSIGNEE-GAP] verdict bead %s has no assignee %dmin after "
                             "first seen (ga-mo7q) — reviewer's --assignee poll is blind to it; "
                             "the metadata.gc.session_name fallback should rescue it, but "
                             "verify verdicts are still landing: gc bd show %s" % (
                                 vid, int(stuck_for / 60), vid))
                        assignee_gap_alerted[vid] = now
            # Prune beads no longer missing an assignee (fixed/closed/resolved)
            gone_gap = set(assignee_gap_first_seen.keys()) - current_gap_ids
            for vid in gone_gap:
                assignee_gap_first_seen.pop(vid, None)
                assignee_gap_alerted.pop(vid, None)

        # --- IDLE-REVIEWER: a gate-run's verdicts not progressing (ga-noxbv) ---
        # Closes the 38min observability blind spot from today's hang: the marker was
        # in gate-status:dispatching (not :queued, so still_queued()/REAL-JAM missed
        # it) and the dispatcher kept logging "Verdicts 1/3" (so ENGINE-STALL missed
        # it). We watch the verdict beads directly: if a run's set of still-pending
        # verdicts is UNCHANGED for VERDICT_STALL_SEC, the reviewer(s) are idle/stuck.
        # Reset the clock whenever the pending set shrinks (a verdict landed = real
        # progress). Sample Dolt before alarming — a slow write != a dead reviewer.
        runs_now = pending_verdicts_by_run()
        now = time.time()
        for run, pend_ids in runs_now.items():
            sig = tuple(pend_ids)
            st = verdict_progress.get(run)
            if st is None or st["sig"] != sig:
                verdict_progress[run] = {"sig": sig, "since": now, "alerted": 0}
                continue
            stalled = now - st["since"]
            if stalled > VERDICT_STALL_SEC and now - st["alerted"] > REALERT_SEC:
                if not dolt_responsive():
                    continue  # Dolt slow/unreachable — not the reviewer's fault; skip
                emit("[IDLE-REVIEWER] gate-run %s: %d verdict(s) pending with no progress "
                     "for %dmin — reviewer(s) idle/stuck; dispatcher re-queues, else gate "
                     "will FAIL at verdict timeout" % (run, len(pend_ids), int(stalled / 60)))
                verdict_progress[run]["alerted"] = now
        # Prune runs whose verdicts are all in (run complete / superseded)
        for run in set(verdict_progress.keys()) - set(runs_now.keys()):
            verdict_progress.pop(run, None)

        # --- GATE-NOMERGE: queue not advancing while work is queued (ga-hl0gq) ---
        # The 2026-06-10 49min stall was invisible to every check above: the marker kept
        # re-queuing (dispatcher_autorebase_retry, a dead-author stale-branch rebase loop)
        # so its guard_queued event-ts kept refreshing and REAL-JAM's age never crossed
        # STUCK_SEC; no run reached verdicts (IDLE-REVIEWER blind); the dispatcher kept
        # logging (ENGINE-STALL blind); no review FAILed (GATE FAIL blind). This check is
        # mechanism-agnostic: if NO queue-ADVANCING event (complete/superseded/needs-rebase)
        # has landed for NOMERGE_STALL_SEC while >=1 marker is queued AND nothing is being
        # actively reviewed, the gate is stuck regardless of the underlying cause. The
        # "no review in flight" + "queued work exists" guards keep a healthy long-running
        # review (15-45min) from false-firing. Dolt-guarded (a slow server != a stuck gate).
        now = time.time()
        last_prog_age = None
        for l in lines:
            try:
                r = json.loads(l)
            except Exception:
                continue
            if r.get("event") in PROGRESS_EVENTS:
                a = age(r.get("ts", ""))
                if a and (last_prog_age is None or a < last_prog_age):
                    last_prog_age = a
        if (last_prog_age is not None and last_prog_age > NOMERGE_STALL_SEC
                and not runs_now and now - nomerge_alerted > REALERT_SEC):
            qids = queued_marker_ids()
            if qids and dolt_responsive():
                emit("[GATE-NOMERGE] gate queue has not advanced in %dmin while %d marker(s) "
                     "queued and no review in flight — dispatcher stuck (e.g. head-of-line "
                     "stale branch); queue not draining" % (int(last_prog_age / 60), len(qids)))
                nomerge_alerted = now

        # --- ASYNC-START-REGRESS: verify the stale_async_start race fix is in the binary ---
        # The engine fix (gc-patched-asyncstart, 4f57fbac4) adds a config-drift-drain
        # exemption for gate-reviewers in state=creating, logged as:
        #   "Skipping config-drift drain for ...: gate-reviewer in async-start (fresh creating)"
        # If the gc binary is rebuilt from an unpatched commit or reverted, this string
        # disappears and reviewer-spawn flakiness will resurge silently. This check catches
        # the regression the moment the binary changes, before reviews start failing.
        # Highest-value signal: directly catches the fix disappearing from the binary.
        # Fail-open: if the binary cannot be read (None), the check is skipped.
        # Env: GATE_REVIEWER_RACE_CHECK=0 disables; no env override for binary path
        # (the live binary is always resolved via `which gc` + `readlink -f`).
        if _RACE_CHECK:
            _gc_path = _gc_binary_path()
            _fix_present = _binary_has_async_start_fix(_gc_path)
            if _fix_present is False:  # explicitly absent (not None = unreadable)
                now = time.time()
                if now - binary_regress_alerted > REALERT_SEC:
                    emit("[ASYNC-START-REGRESS] gate-reviewer async-start fix MISSING from "
                         "live gc binary (%s) — regression: binary rebuilt/reverted without "
                         "the stale_async_start race fix; reviewer-spawn flakiness will "
                         "resurge" % (_gc_path or "unknown path"))
                    binary_regress_alerted = now

        # --- ASYNC-START-RACE: alert on elevated stale_async_start race rate (1h window) ---
        # After the engine fix, the race count should be ~0 per hour. A spike (> _RACE_MAX
        # in the past RACE_WINDOW_SEC) means the fix may be ineffective, partially reverted,
        # or a new code path reintroduced the condition. Complements the binary check above:
        # the binary check catches a full regression; this catches a partial/novel one where
        # the fix string is still present but not exercised on the active code path.
        # The dispatcher logs the race as:
        #   "... drained during startup (stale_async_start race) — re-convene will re-spawn"
        # Tune threshold via GATE_REVIEWER_RACE_MAX env var (default 8/hour).
        # Fail-open: log absent or unreadable returns 0 (no alert).
        if _RACE_CHECK:
            _race_count = _count_async_start_races()
            if _race_count > _RACE_MAX:
                now = time.time()
                if now - race_spike_alerted > REALERT_SEC:
                    emit("[ASYNC-START-RACE] stale_async_start race spiked: %d occurrence(s) "
                         "in the last %dmin (threshold: %d/h) — reviewer-spawn reliability "
                         "degraded; check if binary regression is partial or a new code path "
                         "triggers the race (GATE_REVIEWER_RACE_MAX to tune)"
                         % (_race_count, RACE_WINDOW_SEC // 60, _RACE_MAX))
                    race_spike_alerted = now

        # --- delivery: failures / halts only ---
        try:
            slines = open(SD).read().splitlines()
        except FileNotFoundError:
            slines = []
        for l in slines[sd_seen:]:
            try:
                r = json.loads(l)
            except Exception:
                continue
            res = str(r.get("result", "")).upper()
            if "FAIL" in res or "HALT" in res:
                emit("[DELIVERY-FAIL] %s %s" % (
                    r.get("story") or r.get("bead", ""), res))
        sd_seen = len(slines)

        time.sleep(120)  # ga-8smq3: was 60; alert thresholds are all >=600s (10-40min), so 120s loses no real detection latency while halving Dolt poll load

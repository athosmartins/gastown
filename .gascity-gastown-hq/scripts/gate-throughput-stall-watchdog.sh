#!/usr/bin/env bash
# gate-throughput-stall-watchdog.sh — catches a silently-stalled quality gate.
#
# WHY THIS EXISTS (2026-06-24, ga-ozcr4 root-cause):
#   The quality gate froze ~15h undetected. Root cause: a code bug skipped the
#   rebase then hung inside the gate sweep. The DPW (daemon-presence-watchdog)
#   could NOT catch it because the gate dispatcher writes its heartbeat at the
#   VERY START of every run (anti-false-WEDGE during quota-defer), so the
#   heartbeat stayed fresh even while the gate hung AFTER it. DPW checks
#   heartbeat freshness, not OUTPUT. This creates a blind spot: DPW = liveness,
#   this watchdog = throughput.
#
# LOGIC (runs every ~600s via launchd):
#   1. Query LIVE gate-marker state directly via `bd` for evidence of a
#      non-empty ACTIVE queue: count type:quality-gate-marker beads whose
#      gate-status label is queued/dispatching/ready/claimed/running.
#      EXCLUDES needs-rebase/parked-needs-human/deferred/error — those wait on
#      a human/author, never on the gate, and must never read as "congested"
#      (ga-4cb2: 7 needs-rebase markers were being counted as a non-empty
#      queue, crying wolf on an idle gate).
#   2. Scan the dispatcher log (last GTSW_LOG_TAIL lines) for evidence of
#      progress: a "Gate PASSED" line within GTSW_STALL_MINUTES (default
#      165min; data: inter-merge p95=127min, p99=240min). Matches the literal
#      substring "Gate PASSED" (no fixed suffix) so it survives the dispatcher
#      appending metadata before the colon — e.g. "Gate PASSED (origin=Pilot):"
#      — as it started doing partway through 2026-07 (ga-4cb2: the old
#      "Gate PASSED:" pattern silently stopped matching ANY current-format
#      line, so the "last pass" calculation fell back to the last OLD-format
#      line, hours stale, and reported a stall that wasn't one).
#   3. FALSE-POSITIVE GUARDS (all must fail to declare a stall):
#      a. No ACTIVE markers → NOT a stall (idle pipeline, possibly with
#         parked/needs-human markers sitting untouched — that's expected).
#      b. "cota=LIMITED" or "quota-limited" in any Headroom DEFER line in the
#         tail (B1), OR claude-quota-check.sh's hard verdict (B2, SESSION
#         scope) → quota-limited, self-heals on window reset; suppress.
#      b3. (ga-sdkqs) claude-quota-check.sh --json .weekly.active (WEEKLY
#         scope) → quota-limited (semanal); suppress. B1/B2 only ever see the
#         SESSION-scope hard limit — by ga-ot735 design a WEEKLY-only
#         exhaustion never trips them (correct for the scheduler, which should
#         keep sweeping on the still-available 5h window), so without this
#         guard a citywide weekly exhaustion reads as "not quota-limited" and
#         the watchdog escalates + kickstarts, burning the very quota that is
#         scarce. weekly.active is freshness-guarded upstream (self-disarms
#         once the account stops re-hitting the cap), so this guard does not
#         stay stuck suppressing after a real recovery.
#      c. A "Gate PASSED" line within the window → progress; not a stall.
#      d. An active gate-reviewer session running (gc session list shows a live
#         session named gate-reviewer*) → reviewer in-flight; not a stall.
#      e. (ga-p62tl) The OLDEST active marker is younger than
#         GTSW_SWEEP_GRACE_MULTIPLIER x the dispatcher's REAL measured sweep
#         cadence (from consecutive "Dispatcher sweep start" gaps in the log
#         tail, NOT the launchd-configured StartInterval — launchd skips ticks
#         while a sweep is still running, so real cadence runs minutes longer
#         than the configured 60s) → the dispatcher hasn't had a fair chance
#         yet; not a stall. Measured incident: watchdog sampled 7s before the
#         dispatcher's own sweep claimed the same marker.
#      f. (ga-p62tl) A type:quality-gate-run bead is gate-status:running and
#         still within its OWN persisted verdict_timeout_minutes+margin →
#         run genuinely in flight; not a stall. Mirrors
#         daemon-presence-watchdog.sh's proven `_gate_run_in_flight` (ga-2vf9b)
#         — more robust than guard D's `gc session list` grep, which can miss
#         a live reviewer (measured: a session with 1s-old activity did not
#         suppress).
#      g. (ga-p62tl) Right before escalating, cross-check with
#         gate-queue-composition.sh (REAL/PHANTOM/UNKNOWN git-level analysis)
#         — if it reports zero REAL work, don't escalate on a raw label count.
#   4. STALL = active queue non-empty AND 0 Gate PASSED in window AND not
#      quota-limited AND no active reviewer AND no in-flight gate-run AND the
#      oldest active marker has had a fair sweep chance AND deeper queue
#      composition confirms real work.
#   5. On stall: notify -p 4 + gc mail send mayor.
#      If GTSW_AUTORECOVER=1 (default): kickstart -k supervisor AND
#      quality-gate-dispatcher to unstick the gate.
#
# FAIL-SAFE: any signal read/query error → UNKNOWN, never "flow present" nor
# "stalled" — always fail toward "no stall verdict" (ga-p5q3 defense (a): a
# failed query is not the same value as zero). An idle gate (no active
# markers) NEVER fires.
#
# KILL-SWITCH: GTSW_ENABLED=0 → no-op.
# DRY-RUN: GTSW_DRY_RUN=1 → log decisions but skip notify/mail/kickstart.
#
# Selftest: bash gate-throughput-stall-watchdog.sh --selftest
#   Scenarios: stall→alert, empty-queue→no-alert, quota-limited→no-alert,
#   recent-progress→no-alert, active-reviewer→no-alert, autorecover-path,
#   weekly-quota-limited→no-alert/no-kickstart, unreadable-quota-check→UNKNOWN
#   fail-open, weekly-not-active→stall-still-fires (ga-sdkqs), young-marker→
#   sweep-cadence-grace, old-marker-still-alerts, gate-run-in-flight→no-alert
#   (ga-p62tl), gate-run-past-budget→still-alerts, queue-composition-real0→
#   no-alert, queue-composition-real1→still-alerts.
set -uo pipefail

# ── config (all env-overridable) ──────────────────────────────────────────────
GTSW_ENABLED="${GTSW_ENABLED:-1}"
GTSW_DRY_RUN="${GTSW_DRY_RUN:-0}"
GTSW_STALL_MINUTES="${GTSW_STALL_MINUTES:-165}"  # minutes without Gate PASSED = stall (p95=127min, p99=240min)
GTSW_AUTORECOVER="${GTSW_AUTORECOVER:-1}"        # 1=kickstart supervisor+dispatcher on stall
GTSW_LOG_TAIL="${GTSW_LOG_TAIL:-2000}"           # lines to tail from the dispatcher log

HQ="${GTSW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
DISPATCH_LOG="${GTSW_DISPATCH_LOG:-$HQ/.gc/logs/quality-gate-dispatcher.log}"
QUOTA_CHECK="${GTSW_QUOTA_CHECK:-$HQ/scripts/claude-quota-check.sh}"
LOG="${GTSW_LOG:-$HQ/.gc/logs/gate-throughput-stall-watchdog.log}"
NOTIFY_BIN="${GTSW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${GTSW_GC_BIN:-gc}"
BD_BIN="${GTSW_BD_BIN:-bd}"
BD_LIST_CACHED="${GTSW_BD_LIST_CACHED:-$HQ/scripts/bd-list-cached.sh}"  # ga-xwza2: read-cache shim (ga-48xcv)
UID_NUM="$(id -u)"

GATE_STALL_COOLDOWN_S="${GATE_STALL_COOLDOWN_S:-7200}"    # 2h dedup window between Athos pages
GTSW_STATE_DIR="${GTSW_STATE_DIR:-$HOME/.gastown/state}"
COOLDOWN_FILE="${GTSW_COOLDOWN_FILE:-$GTSW_STATE_DIR/gate-stall-watchdog-last-alert}"
# ── recover-first escalation (gate-recovery philosophy) ───────────────────────
# A confirmed stall does NOT immediately page Athos's phone — most are transient and
# the auto-recovery (kickstart) clears them. On FIRST detection we mail the Mayor (who
# can fix infra) + auto-recover and stamp a recover-marker; Athos's phone (notify -p4)
# fires ONLY when the stall PERSISTS past GTSW_RECOVER_GRACE_SECS after that recovery
# attempt — i.e. recovery demonstrably failed and a human is genuinely needed. This
# kills the false-positive phone noise of paging Athos for stalls the machine self-heals
# (Athos 2026-06-30: "só me notifique quando a máquina precisar de mim"). The marker is
# reset (with the cooldown) by the stall-clear guards so a new episode starts fresh.
RECOVER_MARKER_FILE="${GTSW_RECOVER_MARKER_FILE:-$GTSW_STATE_DIR/gate-stall-watchdog-recover-attempted}"
GTSW_RECOVER_GRACE_SECS="${GTSW_RECOVER_GRACE_SECS:-420}"   # 7min for a kickstart to land before paging Athos
case "$GTSW_RECOVER_GRACE_SECS" in ''|*[!0-9]*) GTSW_RECOVER_GRACE_SECS=420 ;; esac

# Launchd labels for auto-recover kickstart
SUPERVISOR_LABEL="${GTSW_SUPERVISOR_LABEL:-com.gascity.supervisor}"
GATE_LABEL="${GTSW_GATE_LABEL:-com.gascity.quality-gate-dispatcher}"

# ga-lda92s: quiet-hours elapsed-clock adjustment — shared sibling-source
# convention this pack already uses (see pilot-dispatcher.sh). Readability
# checked BEFORE sourcing (not `2>/dev/null || true` after) so a missing
# sibling fails loud via the sentinel check below instead of leaving
# _quiet_elapsed_adjustment silently undefined.
_GTSW_QHC_SIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../packs/town-deltas/assets/quiet-hours-check.sh"
if [ -r "$_GTSW_QHC_SIB" ]; then
  source "$_GTSW_QHC_SIB"
fi
unset _GTSW_QHC_SIB
# Plain stderr echo, not log() — log() is not defined yet at this point in
# this file (same ordering trap pilot-dispatcher.sh's own sourcing block
# documents), and this check must not depend on definition order.
[ -n "${QUIET_HOURS_LEVEL_FILE:-}" ] || echo "WARN: ga-lda92s: quiet-hours-check.sh failed to source — elapsed-clock adjustment is INERT this run (fail-open: stall detection proceeds on raw wall-clock elapsed, same as before this fix)" >&2

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [gtsw] $*" >> "$LOG" 2>/dev/null || true; }

# ── ga-p62tl: sweep-cadence + in-flight-run config ────────────────────────────
# GTSW_DEFAULT_SWEEP_CADENCE_SEC is a FALLBACK ONLY, used when fewer than 2
# "Dispatcher sweep start" lines are in the log tail to measure from. Do NOT
# read this from the dispatcher's launchd StartInterval (60s, confirmed live in
# ~/Library/LaunchAgents/com.gascity.quality-gate-dispatcher.plist) — launchd
# skips a tick while the previous sweep is still running, and a real sweep
# (claim+rebase+spawn under live Dolt latency) takes minutes, so the REAL
# cadence lands far above the configured interval
# (gate-throughput-model-sweep-serialization: sweep ~210s, StartInterval
# rounds up to the next multiple ⇒ ~6min real-world). 360s reflects that
# measured reality, not the configured knob.
GTSW_DEFAULT_SWEEP_CADENCE_SEC="${GTSW_DEFAULT_SWEEP_CADENCE_SEC:-360}"
GTSW_SWEEP_GRACE_MULTIPLIER="${GTSW_SWEEP_GRACE_MULTIPLIER:-2}"
GTSW_GATE_RUN_DEFAULT_TIMEOUT_MIN="${GTSW_GATE_RUN_DEFAULT_TIMEOUT_MIN:-50}"  # mirrors dispatcher's VERDICT_TIMEOUT_MAX_MINUTES default
GTSW_GATE_RUN_MARGIN_MIN="${GTSW_GATE_RUN_MARGIN_MIN:-10}"                    # mirrors daemon-presence-watchdog.sh's DPW_GATE_RUN_MARGIN_MIN
GTSW_QUEUE_COMPOSITION="${GTSW_QUEUE_COMPOSITION:-}"                          # resolved lazily against $HQ inside run_sweep (HQ can be test-overridden)
GTSW_QUEUE_COMPOSITION_TIMEOUT_SEC="${GTSW_QUEUE_COMPOSITION_TIMEOUT_SEC:-60}"

# Echoes the measured dispatcher sweep cadence in seconds: the LARGEST gap
# between consecutive "Dispatcher sweep start" timestamps found in the given
# log text. Largest, not most-recent/average — under-measuring the cadence is
# exactly what re-creates the ga-p62tl false positive (a too-short grace window
# is no grace at all). Echoes nothing (caller falls back to the default) when
# fewer than 2 such lines are present or every parse attempt fails — same
# fail-open direction as every other signal-read in this file: an
# unmeasurable cadence must never collapse to "0s" (which would make the grace
# window 0 and every young marker "old").
_gtsw_measure_sweep_cadence_sec() {
  local lines="$1"
  local prev="" best=0 line ts_str ep gap
  while IFS= read -r line; do
    case "$line" in *"Dispatcher sweep start"*) ;; *) continue ;; esac
    ts_str="$(printf '%s' "$line" | grep -oE '^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | tr -d '[]')"
    [ -z "$ts_str" ] && continue
    ep="$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null)" || continue
    if [ -n "$prev" ]; then
      gap=$(( ep - prev ))
      if [ "$gap" -gt "$best" ] 2>/dev/null; then
        best="$gap"
      fi
    fi
    prev="$ep"
  done <<< "$lines"
  [ "$best" -gt 0 ] 2>/dev/null && printf '%s' "$best"
  return 0
}

# ── main sweep function (pure-ish; all I/O goes through overrideable vars) ───
# Test seams: override these vars to inject fake data without touching disk/net.
#   GTSW_TEST_ACTIVE_MARKERS_JSON — fake `bd list` JSON (replaces the live query)
#   GTSW_TEST_LOG_LINES    — newline-separated fake log content (replaces tail)
#   GTSW_TEST_QUOTA_RC     — fake exit code for quota-check (0=ok, 2=limited)
#   GTSW_TEST_QUOTA_JSON   — fake `claude-quota-check.sh --json` output (ga-sdkqs guard B3;
#                            drives .weekly.active/.weekly.reset_time_text)
#   GTSW_TEST_SESSIONS     — fake gc session list output
#   GTSW_TEST_KICKSTARTS   — file to record kickstart calls (for assertions)
#   GTSW_TEST_NOTIFIED     — file to record notify calls
#   GTSW_TEST_MAILED       — file to record gc mail calls
#   GTSW_TEST_NOW          — fake `date +%s` for "now" (ga-lda92s) — without this,
#                            quiet-hours scenarios would need real wall-clock time
#                            to fall inside/outside the night window, making the
#                            selftest's result depend on what time it happens to run.

run_sweep() {
  # Kill-switch
  if [ "${GTSW_ENABLED:-1}" != "1" ]; then
    log "disabled (GTSW_ENABLED=0) — no-op"
    return 0
  fi

  local now; now="${GTSW_TEST_NOW:-$(date +%s)}"
  local stall_window_sec; stall_window_sec=$(( ${GTSW_STALL_MINUTES:-165} * 60 ))

  # ── SIGNAL READ: tail the dispatcher log ─────────────────────────────────
  local log_lines
  if [ -n "${GTSW_TEST_LOG_LINES+x}" ]; then
    # Test seam: use injected lines
    log_lines="${GTSW_TEST_LOG_LINES}"
  elif [ ! -f "$DISPATCH_LOG" ]; then
    log "WARN: dispatcher log not found ($DISPATCH_LOG) — fail-open (no stall verdict)"
    return 0
  else
    log_lines="$(tail -n "${GTSW_LOG_TAIL:-2000}" "$DISPATCH_LOG" 2>/dev/null)" || {
      log "WARN: could not tail dispatcher log — fail-open"
      return 0
    }
  fi

  if [ -z "$log_lines" ]; then
    log "WARN: dispatcher log empty/unreadable — fail-open"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD A: no ACTIVE markers ─────────────────────────────
  # ga-4cb2: query LIVE gate-marker state directly via bd instead of parsing
  # the dispatcher log's "Found N queued marker(s)" text. That text-parsing
  # approach raced the independently-scheduled dispatcher sweep (this
  # watchdog's tail can land a few seconds either side of the dispatcher's own
  # write) and had no way to distinguish a genuinely active marker from one
  # PARKED at needs-rebase/parked-needs-human/deferred/error — those wait on a
  # human/author, never on the gate, and must never read as queue congestion.
  # Count ONLY the states the gate itself owns: queued/dispatching/ready/
  # claimed/running.
  local markers_json=""
  if [ -n "${GTSW_TEST_ACTIVE_MARKERS_JSON+x}" ]; then
    markers_json="${GTSW_TEST_ACTIVE_MARKERS_JSON}"
  elif command -v "$BD_BIN" >/dev/null 2>&1; then
    # ga-xwza2: routed through the read-cache shim — a count-only liveness check
    # (active marker count for stall detection), not a read-after-write.
    # --include-infra (ga-vm20x, Mayor 07/08): markers are born --ephemeral
    # (INFRA), hidden from `bd list` by default under bd 1.1.0. Without this
    # flag a genuinely backed-up gate reads as empty, and this watchdog's
    # whole job is detecting exactly that stall.
    markers_json="$(bash "$BD_LIST_CACHED" -C "$HQ" list --json --include-infra -l type:quality-gate-marker --status open --limit 0 2>/dev/null)" || markers_json=""
  else
    log "WARN: bd not on PATH — cannot read gate-marker state — fail-open (no stall verdict)"
    return 0
  fi

  local active_count=""
  if [ -n "$markers_json" ]; then
    active_count="$(printf '%s' "$markers_json" | jq '[.[] | select(.labels[]? | test("^gate-status:(queued|dispatching|ready|claimed|running)$"))] | length' 2>/dev/null)"
  fi
  case "$active_count" in ''|*[!0-9]*) active_count="" ;; esac

  if [ -z "$active_count" ]; then
    # ga-p5q3 defense (a): a query/parse FAILURE is UNKNOWN, not zero — fail
    # open rather than let "couldn't ask" masquerade as "nothing's queued" (or,
    # worse, fall through and get misread as a stall).
    log "WARN: could not read active gate-marker count (bd query or jq parse failed) — fail-open (no stall verdict)"
    return 0
  fi

  if [ "$active_count" -eq 0 ]; then
    # COOLDOWN RESET: queue empty → stall cleared; disarm so next episode re-alerts immediately
    [ -f "${COOLDOWN_FILE}" ] && { rm -f "${COOLDOWN_FILE}" 2>/dev/null || true; log "COOLDOWN RESET: queue empty — cooldown disarmed"; }
    # ga-evjs2: also clear the recover-marker so a NEW episode starts recover-first (no stale escalation)
    [ -f "${RECOVER_MARKER_FILE}" ] && { rm -f "${RECOVER_MARKER_FILE}" 2>/dev/null || true; log "RECOVER-MARKER RESET: queue empty — next episode recovers before paging Athos"; }
    log "OK: 0 active gate markers (queued/dispatching/ready/claimed/running) — gate idle (not a stall)"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD B: quota-limited ────────────────────────────────
  # Three sub-checks:
  # B1. Scan the log tail for Headroom DEFER lines with "cota=LIMITED" or
  #     "quota-limited". If the MOST RECENT queued-markers line is followed
  #     (or accompanied) by such a DEFER line, quota is the reason — suppress.
  # B2. Run claude-quota-check.sh (exit 2 = LIMITED). Use B1 as primary (faster,
  #     no disk scan) and B2 as confirmation. Either → suppress.
  # B3 (ga-sdkqs). claude-quota-check.sh's ga-ot735 design deliberately never
  #     trips B2 for a WEEKLY-only exhaustion (the 5h window usually still has
  #     headroom, and hard-pausing the gate for a multi-day ceiling was the
  #     exact false-pause ga-ot735 killed). That is correct for the SCHEDULER
  #     (gate/pilot should keep sweeping) but wrong for THIS watchdog: when the
  #     account is weekly-exhausted, kickstarting the gate burns the very quota
  #     that is scarce, and escalating "stall" is noise with a harmful
  #     suggested remedy. B1/B2 above genuinely found nothing (ga-sdkqs's own
  #     incident: 23 escalations from a citywide weekly exhaustion the existing
  #     guards structurally cannot see). Read the same check's --json
  #     weekly.active as an INDEPENDENT suppression signal — advisory for the
  #     scheduler, but a hard suppression for the escalate-and-kickstart
  #     decision here. weekly.active is itself freshness-guarded upstream
  #     (claude-quota-check.sh's CLAUDE_QUOTA_WEEKLY_FRESHNESS_SECS) so it
  #     self-disarms once the account stops re-hitting the cap — this watchdog
  #     does not need its own staleness logic, only to read the field.
  local quota_limited=0

  # B1: log-pattern check (fast, Dolt-independent)
  if echo "$log_lines" | grep -qE "(cota=LIMITED|quota-limited)"; then
    quota_limited=1
    log "FALSE-POSITIVE GUARD B1: dispatcher log shows quota-limited — suppressing stall alert"
  fi

  # B2: live quota-check (only if B1 didn't already confirm)
  if [ "$quota_limited" -eq 0 ]; then
    local quota_rc
    if [ -n "${GTSW_TEST_QUOTA_RC+x}" ]; then
      quota_rc="${GTSW_TEST_QUOTA_RC}"
    elif [ -x "$QUOTA_CHECK" ]; then
      "$QUOTA_CHECK" --quiet >/dev/null 2>&1; quota_rc=$?
    else
      quota_rc=0  # quota-check not available → fail-open (don't suppress on missing tool)
      log "WARN: quota-check not available ($QUOTA_CHECK) — skipping B2 guard (fail-open)"
    fi
    if [ "$quota_rc" -eq 2 ]; then
      quota_limited=1
      log "FALSE-POSITIVE GUARD B2: claude-quota-check.sh exit 2 (LIMITED) — suppressing"
    fi
  fi

  # B3: weekly-quota advisory via claude-quota-check.sh --json (only if B1/B2 didn't
  # already confirm). CLAUDE_QUOTA_SKIP_WINDOW=1 skips the slow 5h token scan this
  # watchdog doesn't need — B3 only reads the ground-truth exhaustion verdict.
  if [ "$quota_limited" -eq 0 ]; then
    local weekly_probe_ran=0 weekly_json=""
    if [ -n "${GTSW_TEST_QUOTA_JSON+x}" ]; then
      weekly_json="${GTSW_TEST_QUOTA_JSON}"
      weekly_probe_ran=1
    elif [ -x "$QUOTA_CHECK" ]; then
      weekly_json="$(CLAUDE_QUOTA_SKIP_WINDOW=1 "$QUOTA_CHECK" --json 2>/dev/null)" || weekly_json=""
      weekly_probe_ran=1
    fi

    if [ "$weekly_probe_ran" -eq 1 ]; then
      local weekly_active=""
      [ -n "$weekly_json" ] && weekly_active="$(printf '%s' "$weekly_json" \
        | jq -r 'if (.weekly.active == true) then "true" elif (.weekly.active == false) then "false" else "" end' 2>/dev/null)"
      case "$weekly_active" in
        true)
          quota_limited=1
          local weekly_reset; weekly_reset="$(printf '%s' "$weekly_json" | jq -r '.weekly.reset_time_text // "unknown"' 2>/dev/null)"
          log "FALSE-POSITIVE GUARD B3: claude-quota-check.sh reports quota-limited (semanal), reset ${weekly_reset} — suppressing stall alert (ga-sdkqs)"
          ;;
        false)
          : # confirmed not weekly-limited; no suppression from this guard
          ;;
        *)
          # ga-sdkqs (AC2): the probe ran but produced no readable .weekly.active
          # (crash, empty stdout, malformed JSON) — a READ FAILURE, not
          # confirmation of "not weekly-limited". Fail toward no-stall-verdict
          # this sweep rather than let an unreadable signal pass as OK
          # (error-vs-empty — this file's own FAIL-SAFE header rule).
          log "WARN: claude-quota-check.sh --json unreadable (.weekly.active) — quota state UNKNOWN, fail-open (no stall verdict this sweep)"
          return 0
          ;;
      esac
    fi
    # weekly_probe_ran=0 (tool not executable, no test seam): no weekly signal
    # available; B1/B2 above already independently guard the hard-limit case.
  fi

  if [ "$quota_limited" -eq 1 ]; then
    log "OK: gate queue non-empty but quota-limited — self-heals on window reset (not a stall)"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD C: recent gate progress ──────────────────────────
  # Scan the tail for "Gate PASSED" lines. Parse the timestamp and check if
  # any falls within the stall window. A PASSED within GTSW_STALL_MINUTES → OK.
  # ga-4cb2: match the substring "Gate PASSED" with NO fixed suffix — the
  # dispatcher started emitting "Gate PASSED (origin=Pilot): branch=..." partway
  # through 2026-07 (previously plain "Gate PASSED: branch=..."), and the old
  # literal "Gate PASSED:" pattern silently stopped matching any current-format
  # line. That left last_passed_epoch permanently pinned to the last OLD-format
  # line still in the tail (hours stale) even while the gate was merging every
  # few minutes, so a real recent pass never suppressed the alert. The
  # timestamp extraction below is a separate regex on the leading `[...]`
  # bracket, so broadening this match cannot pick up a wrong timestamp — it can
  # only stop missing right ones. (The "Logged for digest ...: 🤖 Pilot Gate
  # PASSED" summary line also contains this substring but carries no leading
  # bracket, so ts_str comes back empty and it's skipped, same as always.)
  local last_passed_epoch=0
  while IFS= read -r line; do
    if echo "$line" | grep -q "Gate PASSED"; then
      # Timestamp format: [2026-06-23 17:33:31]
      local ts_str; ts_str="$(echo "$line" | grep -oE '\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\]' | tr -d '[]')"
      if [ -n "$ts_str" ]; then
        local ep; ep="$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts_str" +%s 2>/dev/null)" || ep=0
        if [ "$ep" -gt "$last_passed_epoch" ] 2>/dev/null; then
          last_passed_epoch="$ep"
        fi
      fi
    fi
  done <<< "$log_lines"

  # ga-lda92s: discount time the city spent in QUIET hours (deliberate
  # admission pause) from the elapsed clock — NOT a blanket silence for the
  # whole window (that would trade this false-positive for a false-negative:
  # a real stall starting 00h30 would go unseen for 7h30). A stall that
  # begins during quiet hours and is still unresolved once the discount runs
  # out still alarms, just correctly later.
  local quiet_adj_sec=0 wall_elapsed_sec=0 effective_elapsed_sec=0
  if [ "$last_passed_epoch" -gt 0 ] 2>/dev/null; then
    wall_elapsed_sec=$(( now - last_passed_epoch ))
    quiet_adj_sec="$(_quiet_elapsed_adjustment "$last_passed_epoch" "$now" 2>/dev/null)"
    case "$quiet_adj_sec" in ''|*[!0-9]*) quiet_adj_sec=0 ;; esac
    effective_elapsed_sec=$(( wall_elapsed_sec - quiet_adj_sec ))
    [ "$effective_elapsed_sec" -lt 0 ] && effective_elapsed_sec=0
  fi

  if [ "$last_passed_epoch" -gt 0 ] && [ "$effective_elapsed_sec" -le "$stall_window_sec" ] 2>/dev/null; then
    local age_min; age_min=$(( wall_elapsed_sec / 60 ))
    # COOLDOWN RESET: Gate PASSED recently → stall cleared; disarm so next episode re-alerts immediately
    [ -f "${COOLDOWN_FILE}" ] && { rm -f "${COOLDOWN_FILE}" 2>/dev/null || true; log "COOLDOWN RESET: Gate PASSED ${age_min}min ago — cooldown disarmed"; }
    # ga-evjs2: also clear the recover-marker so a NEW episode starts recover-first (no stale escalation)
    [ -f "${RECOVER_MARKER_FILE}" ] && { rm -f "${RECOVER_MARKER_FILE}" 2>/dev/null || true; log "RECOVER-MARKER RESET: Gate PASSED ${age_min}min ago — next episode recovers before paging Athos"; }
    if [ "$quiet_adj_sec" -gt 0 ] && [ "$wall_elapsed_sec" -gt "$stall_window_sec" ] 2>/dev/null; then
      # Raw elapsed alone WOULD have crossed the window — quiet hours is what
      # explains the silence. Say so explicitly (not just "OK") so a human
      # reading the log later sees the detector ran and decided, not that it
      # went dead.
      log "SUPPRESSED (quiet hours): raw ${age_min}min, quiet-adjusted $((effective_elapsed_sec / 60))min (within ${GTSW_STALL_MINUTES}min window) — not a stall"
    else
      log "OK: Gate PASSED ${age_min}min ago (within ${GTSW_STALL_MINUTES}min window) — not a stall"
    fi
    return 0
  fi

  # ── FALSE-POSITIVE GUARD D: active gate-reviewer session ─────────────────
  # If a gate-reviewer* session is live in gc session list, a reviewer is
  # actively working — the gate is not stalled, just slow.
  local active_reviewer=0
  local session_output
  if [ -n "${GTSW_TEST_SESSIONS+x}" ]; then
    session_output="${GTSW_TEST_SESSIONS}"
    active_reviewer=0
    if echo "$session_output" | grep -q "gate-reviewer"; then
      active_reviewer=1
    fi
  elif command -v "$GC_BIN" >/dev/null 2>&1; then
    session_output="$("$GC_BIN" session list 2>/dev/null)" || session_output=""
    if echo "$session_output" | grep -q "gate-reviewer"; then
      active_reviewer=1
    fi
  else
    log "WARN: gc not on PATH — skipping guard D (active-reviewer check); fail-open (no suppression)"
    # Don't set active_reviewer=1 on error — could mask a real stall
  fi

  if [ "$active_reviewer" -eq 1 ]; then
    log "OK: active gate-reviewer session detected — reviewer in-flight (not a stall)"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD E (ga-p62tl): sweep-cadence grace ────────────────
  # The oldest ACTIVE marker (reusing markers_json from Guard A — no extra
  # query) may simply not have had a fair dispatcher cycle yet. Only engages
  # when a usable timestamp exists (real `bd` JSON always has updated_at; test
  # fixtures that don't set one are unaffected, by construction of the jq
  # filter below).
  local oldest_active_epoch=""
  if [ -n "$markers_json" ]; then
    oldest_active_epoch="$(printf '%s' "$markers_json" | jq -r \
      '[.[] | select(.labels[]? | test("^gate-status:(queued|dispatching|ready|claimed|running)$")) | (.updated_at // .created_at // empty)]
       | map(select(. != "")) | sort | .[0] // empty' 2>/dev/null)"
  fi
  if [ -n "$oldest_active_epoch" ]; then
    local oae_ep=""
    # -u is required: bd's timestamp already carries a literal "Z" (UTC), but
    # -f's format spec matches "Z" as a literal character, not a timezone
    # indicator — without -u, -j parses the numeric fields as LOCAL time and
    # silently shifts the epoch by the system's UTC offset (confirmed live:
    # 3h off on this box, which made every marker's age come out negative and
    # this guard never engage). Guard C's own timestamp parsing a few lines
    # up never hit this because dispatcher log lines have no "Z" — they are
    # already local-format strings by construction.
    oae_ep="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$oldest_active_epoch" +%s 2>/dev/null)" || oae_ep=""
    if [ -n "$oae_ep" ] && [ "$oae_ep" -gt 0 ] 2>/dev/null; then
      local oldest_active_age_sec=$(( now - oae_ep ))
      if [ "$oldest_active_age_sec" -ge 0 ] 2>/dev/null; then
        local measured_cadence cadence_sec grace_sec
        measured_cadence="$(_gtsw_measure_sweep_cadence_sec "$log_lines")"
        if [ -n "$measured_cadence" ] && [ "$measured_cadence" -gt 0 ] 2>/dev/null; then
          cadence_sec="$measured_cadence"
        else
          cadence_sec="$GTSW_DEFAULT_SWEEP_CADENCE_SEC"
        fi
        grace_sec=$(( cadence_sec * GTSW_SWEEP_GRACE_MULTIPLIER ))
        if [ "$oldest_active_age_sec" -lt "$grace_sec" ] 2>/dev/null; then
          log "OK: oldest active marker is ${oldest_active_age_sec}s old, within sweep-cadence grace (cadence=${cadence_sec}s x${GTSW_SWEEP_GRACE_MULTIPLIER}=${grace_sec}s) — dispatcher hasn't had a fair chance yet, not a stall (ga-p62tl)"
          return 0
        fi
      fi
    fi
  fi

  # ── FALSE-POSITIVE GUARD F (ga-p62tl): gate-run in flight within its own
  # persisted verdict budget ────────────────────────────────────────────────
  # Guard D's `gc session list` grep can miss a genuinely live reviewer
  # (measured: a session with 1s-old activity did not suppress). Mirrors
  # daemon-presence-watchdog.sh's proven `_gate_run_in_flight` (ga-2vf9b):
  # read the run's OWN persisted verdict_timeout_minutes from its bead
  # description rather than a shared constant, so this stays correct if the
  # dispatcher's timeout scaling changes independently of this file.
  local gate_run_json=""
  if [ -n "${GTSW_TEST_GATE_RUN_JSON+x}" ]; then
    gate_run_json="${GTSW_TEST_GATE_RUN_JSON}"
  elif command -v "$BD_BIN" >/dev/null 2>&1; then
    gate_run_json="$(bash "$BD_LIST_CACHED" -C "$HQ" list --json --include-infra -l type:quality-gate-run -l gate-status:running 2>/dev/null)" || gate_run_json=""
  fi
  if [ -n "$gate_run_json" ]; then
    if printf '%s' "$gate_run_json" | jq -e \
        --argjson now "$now" \
        --argjson marginmin "$GTSW_GATE_RUN_MARGIN_MIN" \
        --argjson defaultmin "$GTSW_GATE_RUN_DEFAULT_TIMEOUT_MIN" \
        'any(.[]?;
          (((.created_at // "") | fromdateiso8601?) // 0) as $created
          | ($created > 0) and
            ((((.description // "") | capture("(?m)^verdict_timeout_minutes: *(?<m>[0-9]+)"; "").m) // ($defaultmin | tostring) | tonumber) as $vtm
              | ($now - $created) < (($vtm + $marginmin) * 60))
        )' >/dev/null 2>&1; then
      log "OK: a quality-gate-run bead is gate-status:running and within its own verdict-timeout+margin window — run in flight, not a stall (ga-p62tl, mirrors ga-2vf9b)"
      return 0
    fi
  fi

  # ── FALSE-POSITIVE GUARD G (ga-p62tl): queue-composition cross-check ─────
  # Right before actually declaring a stall, cross-check against
  # gate-queue-composition.sh's git-level REAL/PHANTOM/UNKNOWN analysis.
  # Guard A's label filter already excludes needs-rebase/parked states, but
  # cannot see phantom that only shows up at the git level (branch already
  # merged, duplicate branch, closed source bead). Deliberately run LAST
  # (git fetches are the most expensive check in this file) so the common
  # healthy path never pays for it.
  local _gtsw_qc_bin="$GTSW_QUEUE_COMPOSITION"
  [ -n "$_gtsw_qc_bin" ] || _gtsw_qc_bin="$HQ/scripts/gate-queue-composition.sh"
  local composition_json="" composition_real=""
  if [ -n "${GTSW_TEST_QUEUE_COMPOSITION_JSON+x}" ]; then
    composition_json="${GTSW_TEST_QUEUE_COMPOSITION_JSON}"
  elif [ -x "$_gtsw_qc_bin" ]; then
    composition_json="$(timeout "$GTSW_QUEUE_COMPOSITION_TIMEOUT_SEC" bash "$_gtsw_qc_bin" --json 2>/dev/null)" || composition_json=""
  fi
  if [ -n "$composition_json" ]; then
    composition_real="$(printf '%s' "$composition_json" | jq -r '.real // empty' 2>/dev/null)"
    case "$composition_real" in ''|*[!0-9]*) composition_real="" ;; esac
  fi
  if [ -n "$composition_real" ] && [ "$composition_real" -eq 0 ] 2>/dev/null; then
    log "OK: gate-queue-composition.sh reports real=0 (active markers are phantom/unknown under git-level analysis) — not escalating on a raw label count (ga-p62tl)"
    return 0
  fi

  # ── STALL CONFIRMED ───────────────────────────────────────────────────────
  local last_passed_desc
  if [ "$last_passed_epoch" -gt 0 ] 2>/dev/null; then
    local hours_ago; hours_ago=$(( (now - last_passed_epoch) / 3600 ))
    last_passed_desc="${hours_ago}h ago"
  else
    last_passed_desc="not found in log tail"
  fi

  # ── COOLDOWN CHECK: suppress dup alerts within GATE_STALL_COOLDOWN_S ─────
  # Returns 1 (stall still detected) but skips notify/mail so Athos doesn't
  # get 16 copies of the same alert during a sustained stall episode.
  # Cooldown is RESET (file deleted) by Guards A and C when the stall clears,
  # so a genuinely new stall episode re-alerts immediately.
  local cooldown_s="${GATE_STALL_COOLDOWN_S:-7200}"
  if [ -f "${COOLDOWN_FILE}" ]; then
    local last_alert_ep; last_alert_ep="$(cat "${COOLDOWN_FILE}" 2>/dev/null)" || last_alert_ep=0
    if [ -n "$last_alert_ep" ] && [ "$last_alert_ep" -gt 0 ] 2>/dev/null; then
      local cd_elapsed; cd_elapsed=$(( now - last_alert_ep ))
      if [ "$cd_elapsed" -lt "$cooldown_s" ] 2>/dev/null; then
        local cd_remain; cd_remain=$(( (cooldown_s - cd_elapsed) / 60 ))
        log "STALL PERSISTS (cooldown active — ${cd_elapsed}s elapsed / ${cooldown_s}s window, ${cd_remain}min remaining — suppressing dup alert). Last pass: ${last_passed_desc}"
        return 1
      fi
    fi
  fi

  local msg="GATE THROUGHPUT STALL: queue non-empty, 0 Gate PASSED in ${GTSW_STALL_MINUTES}min, not quota-limited, no active reviewer. Last pass: ${last_passed_desc}."
  log "STALL DETECTED: $msg"

  if [ "${GTSW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would mail mayor + autorecover (+ page Athos only if it persists past ${GTSW_RECOVER_GRACE_SECS}s)"
    return 1
  fi

  mkdir -p "${GTSW_STATE_DIR}" 2>/dev/null || true

  # ── RECOVER-FIRST escalation (gate-recovery philosophy) ─────────────────────
  # FIRST detection → stamp a recover-marker, mail the Mayor + auto-recover, and do
  # NOT page Athos. While within GTSW_RECOVER_GRACE_SECS of that attempt → just wait
  # (the kickstart needs time to land). Only when the stall PERSISTS past the grace
  # do we page Athos's phone (recovery demonstrably failed → a human is genuinely
  # needed). _page_athos gates the phone notify; the mail+autorecover below run on
  # both the first detection and the escalation.
  local recovered_at=0
  [ -f "${RECOVER_MARKER_FILE}" ] && recovered_at="$(cat "${RECOVER_MARKER_FILE}" 2>/dev/null || echo 0)"
  case "$recovered_at" in ''|*[!0-9]*) recovered_at=0 ;; esac

  local _page_athos=0
  if [ "$recovered_at" = "0" ]; then
    echo "$now" > "${RECOVER_MARKER_FILE}" 2>/dev/null || true
    log "STALL (first detection): auto-recovering + mailing Mayor; Athos NOT paged — recovery has ${GTSW_RECOVER_GRACE_SECS}s to land before escalation."
  else
    local _recover_age=$(( now - recovered_at ))
    if [ "$_recover_age" -lt "$GTSW_RECOVER_GRACE_SECS" ] 2>/dev/null; then
      log "STALL persists but recovery is within grace (${_recover_age}s/${GTSW_RECOVER_GRACE_SECS}s) — not paging Athos yet."
      return 1
    fi
    # recovery had its grace window and the stall PERSISTS → page Athos (cooldown-deduped)
    local cooldown_s="${GATE_STALL_COOLDOWN_S:-7200}"
    if [ -f "${COOLDOWN_FILE}" ]; then
      local _last_pg; _last_pg="$(cat "${COOLDOWN_FILE}" 2>/dev/null)" || _last_pg=0
      case "$_last_pg" in ''|*[!0-9]*) _last_pg=0 ;; esac
      if [ "$_last_pg" -gt 0 ] 2>/dev/null && [ "$(( now - _last_pg ))" -lt "$cooldown_s" ] 2>/dev/null; then
        log "STALL PERSISTS post-recovery (${_recover_age}s) but Athos already paged (cooldown) — suppressing dup page."
        return 1
      fi
    fi
    _page_athos=1
  fi

  # ── PAGE ATHOS (phone) — ONLY on escalation: recovery failed past the grace ─────
  if [ "$_page_athos" = "1" ]; then
    local page="GATE STALL PERSISTE após auto-recuperação: ${msg} O kickstart NÃO resolveu — precisa de intervenção."
    if [ -n "${GTSW_TEST_NOTIFIED+x}" ]; then
      echo "notify:$page" >> "${GTSW_TEST_NOTIFIED}" 2>/dev/null || true
    else
      command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
        "${NOTIFY_BIN}" -t "Gate stall (recovery failed)" -p 4 "$page" 2>/dev/null || true
    fi
    echo "$now" > "${COOLDOWN_FILE}" 2>/dev/null || true
    log "ESCALATED to Athos (notify -p4): auto-recovery did not clear the stall within ${GTSW_RECOVER_GRACE_SECS}s. Athos-page cooldown armed (${GATE_STALL_COOLDOWN_S}s)."
  fi

  # ── MAIL MAYOR (can fix infra — informed on first detection AND on escalation) ──
  local mail_subject="Watchdog: GATE THROUGHPUT STALL — ${GTSW_STALL_MINUTES}min sem Gate PASSED com fila cheia"
  [ "$_page_athos" = "1" ] && mail_subject="Watchdog: GATE STALL PERSISTE após auto-recuperação (${GTSW_STALL_MINUTES}min) — precisa de intervenção"
  local mail_body
  mail_body="$(cat <<BODY
GATE THROUGHPUT STALL detectado pelo gate-throughput-stall-watchdog.

CONDIÇÃO: queue não-vazia + 0 Gate PASSED em ${GTSW_STALL_MINUTES}min + não quota-limited + sem gate-reviewer ativo.

Último Gate PASSED: ${last_passed_desc}
Janela de análise: ${GTSW_STALL_MINUTES}min
Escalado ao Athos: $([ "$_page_athos" = "1" ] && echo "SIM (auto-recuperação falhou após ${GTSW_RECOVER_GRACE_SECS}s)" || echo "NÃO (auto-recuperando; Athos só é paginado se persistir)")

POR QUE O DPW NÃO PEGOU: o heartbeat do gate é tocado no INÍCIO de cada sweep
(anti-false-WEDGE durante quota-defer) — então o heartbeat fica fresco mesmo quando
o gate trava DEPOIS. DPW mede liveness; este watchdog mede throughput.

INVESTIGAÇÃO:
1. tail -40 $DISPATCH_LOG
   Procure: sweep sem "Gate PASSED:" seguido de silêncio vs. linhas de erro (merge conflict? rebase hung?)
2. ls -la $HQ/scripts/gate-lock/ 2>/dev/null  — lock preso?
3. gc session list | grep gate  — sessão de reviewer ativa ou travada?
4. gc dolt status  — coleta antes de reiniciar
5. Se o GTSW_AUTORECOVER=1 kickstart já foi feito (ver log abaixo), confirme se
   o gate voltou: grep 'Gate PASSED' $DISPATCH_LOG | tail -3

SE A RECUPERAÇÃO FALHAR: investigue o lock (gate-lock-hygiene.sh) e/ou faça
kickstart manual do supervisor + quality-gate-dispatcher.
BODY
)"

  if [ -n "${GTSW_TEST_MAILED+x}" ]; then
    echo "mail:gate-throughput-stall:$msg" >> "${GTSW_TEST_MAILED}" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "$mail_subject" \
        -m "$mail_body" 2>/dev/null || true
  fi

  # ── AUTO-RECOVER ──────────────────────────────────────────────────────────
  if [ "${GTSW_AUTORECOVER:-1}" = "1" ]; then
    log "AUTORECOVER: kickstarting supervisor ($SUPERVISOR_LABEL) + gate ($GATE_LABEL)"

    if [ -n "${GTSW_TEST_KICKSTARTS+x}" ]; then
      echo "kickstart:$SUPERVISOR_LABEL" >> "${GTSW_TEST_KICKSTARTS}" 2>/dev/null || true
      echo "kickstart:$GATE_LABEL" >> "${GTSW_TEST_KICKSTARTS}" 2>/dev/null || true
    else
      # Kickstart supervisor first (it manages crew lifecycle)
      if launchctl kickstart -k "gui/$UID_NUM/$SUPERVISOR_LABEL" 2>/dev/null; then
        log "AUTORECOVER: supervisor kickstarted OK"
      else
        log "AUTORECOVER: supervisor kickstart FAILED (may not be loaded)"
      fi
      # Then kickstart the gate dispatcher
      if launchctl kickstart -k "gui/$UID_NUM/$GATE_LABEL" 2>/dev/null; then
        log "AUTORECOVER: quality-gate-dispatcher kickstarted OK"
      else
        log "AUTORECOVER: quality-gate-dispatcher kickstart FAILED (may not be loaded)"
      fi
    fi
  else
    log "AUTORECOVER disabled (GTSW_AUTORECOVER=0) — alert only"
  fi

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${GTSW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  # Override all I/O paths to the temp dir
  LOG="$TMP/gtsw.log"
  GTSW_LOG="$LOG"
  DISPATCH_LOG="$TMP/gate-dispatcher.log"   # not used in tests (log injected via env)
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  GTSW_ENABLED=1
  GTSW_DRY_RUN=0
  GTSW_STALL_MINUTES=165
  GTSW_AUTORECOVER=1
  GTSW_SUPERVISOR_LABEL="com.gascity.supervisor"
  GTSW_GATE_LABEL="com.gascity.quality-gate-dispatcher"
  COOLDOWN_FILE="$TMP/cooldown"
  RECOVER_MARKER_FILE="$TMP/recover-marker"
  GTSW_STATE_DIR="$TMP"
  # ga-sdkqs: default guard-B3 seam to "weekly not active" for every scenario below.
  # Without this, any scenario that doesn't set GTSW_TEST_QUOTA_RC=2/B1-suppress falls
  # through to the REAL, live $QUOTA_CHECK (claude-quota-check.sh exists and is
  # executable on a real checkout) — making the selftest's result depend on whatever
  # this machine's actual Claude quota state happens to be right now. Scenarios that
  # specifically exercise B3 (14/15/16) override this locally.
  GTSW_TEST_QUOTA_JSON='{"weekly":{"active":false}}'
  # ga-p62tl: same reasoning as the quota default above, for the two NEW guards
  # (F, G) — without a seam default, every EXISTING scenario below (none of
  # which sets GTSW_TEST_GATE_RUN_JSON/GTSW_TEST_QUEUE_COMPOSITION_JSON) would
  # fall through to the LIVE bd query / LIVE gate-queue-composition.sh (git
  # fetches against real rigs) using this machine's actual $HQ, making the
  # selftest depend on live production state instead of the fixtures it
  # declares. Defaults are chosen to be NEUTRAL w.r.t. every existing
  # "stall confirmed" scenario: "no gate-run in flight" (doesn't suppress) and
  # "composition confirms real work" (doesn't suppress) — i.e. guards F/G stay
  # silent no-ops unless a scenario explicitly overrides them to exercise the
  # new suppression path.
  GTSW_TEST_GATE_RUN_JSON='[]'
  GTSW_TEST_QUEUE_COMPOSITION_JSON='{"total":1,"real":1,"phantom":0,"unknown":0}'
  GATE_STALL_COOLDOWN_S=7200

  # Stub notify and gc so they record calls but have no side effects
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$GTSW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$TMP/notify"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$GTSW_TEST_MAILED" 2>/dev/null; [ "$1" = "session" ] && echo "${GTSW_TEST_SESSIONS:-}" ; exit 0\n' > "$TMP/gc"
  chmod +x "$TMP/notify" "$TMP/gc"

  # Helper: generate realistic dispatcher log filler plus optionally a
  # "Gate PASSED" line at a given age in seconds. ga-4cb2: Guard A no longer
  # reads queue state from this text (see make_markers below) — this is now
  # ONLY for guards B (quota) and C (recent progress). fmt=new reproduces the
  # CURRENT dispatcher format "Gate PASSED (origin=Pilot): ..."; fmt=old
  # reproduces the format every pre-2026-07 log line used, "Gate PASSED: ..."
  # (no origin tag) — both must suppress via Guard C.
  make_log() {
    local passed_age_sec="${1:-}" fmt="${2:-new}"
    local now; now="$(date +%s)"
    local ts_now; ts_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
    echo "[${ts_now}] [quality-gate-dispatcher] === Dispatcher sweep start (DRY_RUN=0) ==="
    if [ -n "$passed_age_sec" ] && [ "$passed_age_sec" -gt 0 ]; then
      local ts_p; ts_p="$(date -u -r $((now - passed_age_sec)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$((now - passed_age_sec))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
      if [ -n "$ts_p" ]; then
        if [ "$fmt" = "old" ]; then
          echo "[${ts_p}] [quality-gate-dispatcher] Gate PASSED: branch=crew/test/ga-test tier=CODE merge_sha=abc123 elapsed=300s"
        else
          echo "[${ts_p}] [quality-gate-dispatcher] Gate PASSED (origin=Pilot): branch=fix/ga-test tier=CODE merge_sha=abc123 elapsed=300s"
        fi
      fi
    fi
  }

  # Helper: build a fake `bd list --json` marker array — one bead per
  # gate-status arg, e.g. `make_markers queued queued needs-rebase` → 2 active
  # + 1 parked. No args → "[]" (empty queue). Feeds GTSW_TEST_ACTIVE_MARKERS_JSON,
  # exercising the SAME jq filter the real bd-query path uses.
  make_markers() {
    local out="[" first=1 st i=0
    for st in "$@"; do
      if [ "$first" -eq 1 ]; then first=0; else out="${out},"; fi
      i=$((i+1))
      out="${out}{\"id\":\"m${i}\",\"status\":\"open\",\"labels\":[\"type:quality-gate-marker\",\"gate-status:${st}\"]}"
    done
    out="${out}]"
    printf '%s' "$out"
  }

  # ── Scenario 1: STALL FIRST DETECTION → recover + mail Mayor, do NOT page Athos ──
  # ga-evjs2 recover-first: a confirmed stall on FIRST sight auto-recovers + informs the
  # Mayor but does NOT buzz Athos's phone (most stalls self-heal). The phone fires only
  # if it persists past the grace (scenario 1b).
  echo "Scenario 1: first stall detection → auto-recover + mail Mayor, Athos NOT paged (recover-first)"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true   # fresh episode
  KICKS1="$TMP/kicks1"; : > "$KICKS1"
  NOTIF1="$TMP/notif1"; : > "$NOTIF1"
  MAIL1="$TMP/mail1";   : > "$MAIL1"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS1"
  GTSW_TEST_NOTIFIED="$NOTIF1"
  GTSW_TEST_MAILED="$MAIL1"
  run_sweep && bad "scenario 1: stall should return 1 (alert)" || ok "scenario 1: stall detected (return 1)"
  grep -q "notify:" "$NOTIF1" 2>/dev/null && bad "scenario 1: Athos paged on FIRST detection (should recover-first)" || ok "scenario 1: Athos NOT paged on first detection (recover-first)"
  grep -q "mail:" "$MAIL1" 2>/dev/null && ok "scenario 1: Mayor mailed on first detection" || bad "scenario 1: Mayor NOT mailed"
  grep -q "kickstart:$GTSW_SUPERVISOR_LABEL" "$KICKS1" 2>/dev/null && ok "scenario 1: supervisor kickstarted" || bad "scenario 1: supervisor NOT kickstarted"
  grep -q "kickstart:$GTSW_GATE_LABEL" "$KICKS1" 2>/dev/null && ok "scenario 1: gate kickstarted" || bad "scenario 1: gate NOT kickstarted"
  [ -f "$TMP/recover-marker" ] && ok "scenario 1: recover-marker stamped" || bad "scenario 1: recover-marker NOT stamped"

  # ── Scenario 1b: STALL PERSISTS past recover-grace → PAGE ATHOS ───────────
  echo "Scenario 1b: stall persists past recover-grace → Athos paged + cooldown armed"
  rm -f "$TMP/cooldown" 2>/dev/null || true
  KICKS1B="$TMP/kicks1b"; : > "$KICKS1B"
  NOTIF1B="$TMP/notif1b"; : > "$NOTIF1B"
  MAIL1B="$TMP/mail1b";   : > "$MAIL1B"
  GTSW_RECOVER_GRACE_SECS=420
  echo "$(( $(date +%s) - 420 - 100 ))" > "$TMP/recover-marker"   # recovery attempted, grace elapsed
  GTSW_TEST_KICKSTARTS="$KICKS1B"
  GTSW_TEST_NOTIFIED="$NOTIF1B"
  GTSW_TEST_MAILED="$MAIL1B"
  run_sweep && bad "scenario 1b: stall should return 1" || ok "scenario 1b: stall detected (return 1)"
  grep -q "notify:" "$NOTIF1B" 2>/dev/null && ok "scenario 1b: Athos PAGED (recovery failed past grace)" || bad "scenario 1b: Athos NOT paged despite persistent stall"
  [ -f "$TMP/cooldown" ] && ok "scenario 1b: Athos-page cooldown armed" || bad "scenario 1b: cooldown NOT armed"

  # ── Scenario 1c: stall WITHIN recover-grace → do NOT page Athos yet ───────
  echo "Scenario 1c: stall within recover-grace → Athos NOT paged yet (recovery still landing)"
  rm -f "$TMP/cooldown" 2>/dev/null || true
  NOTIF1C="$TMP/notif1c"; : > "$NOTIF1C"
  GTSW_RECOVER_GRACE_SECS=420
  echo "$(date +%s)" > "$TMP/recover-marker"   # recovery JUST attempted (age ~0 < grace)
  GTSW_TEST_KICKSTARTS="$TMP/kicks1c"; : > "$TMP/kicks1c"
  GTSW_TEST_NOTIFIED="$NOTIF1C"
  GTSW_TEST_MAILED="$TMP/mail1c"; : > "$TMP/mail1c"
  run_sweep && bad "scenario 1c: stall should return 1" || ok "scenario 1c: stall detected (return 1)"
  grep -q "notify:" "$NOTIF1C" 2>/dev/null && bad "scenario 1c: Athos paged too early (within grace)" || ok "scenario 1c: Athos NOT paged within grace (correct)"
  # restore a clean slate for downstream scenarios
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true

  # ── Scenario 2: EMPTY QUEUE → no alert ───────────────────────────────────
  echo "Scenario 2: empty queue (0 active markers) → NOT a stall"
  NOTIF2="$TMP/notif2"; : > "$NOTIF2"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers)"    # no markers at all
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF2"
  GTSW_TEST_MAILED="$TMP/mail2"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 2: empty queue returns 0 (no alert)" || bad "scenario 2: empty queue falsely alerted"
  [ ! -s "$NOTIF2" ] && ok "scenario 2: no notify on empty queue" || bad "scenario 2: notify fired on empty queue (false positive)"

  # ── Scenario 2b (ga-4cb2 regression): PARKED markers must NOT count ──────
  # The exact reported incident: 7 markers sit at gate-status:needs-rebase
  # (waiting on their AUTHORS to resolve a real conflict, never on the gate).
  # A watchdog that counts them as "queue non-empty" cries wolf on an idle
  # gate forever, since parked markers never clear themselves.
  echo "Scenario 2b (ga-4cb2): 7 needs-rebase markers, 0 active → NOT a stall"
  NOTIF2B="$TMP/notif2b"; : > "$NOTIF2B"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF2B"
  GTSW_TEST_MAILED="$TMP/mail2b"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 2b: 7 needs-rebase markers return 0 (no alert)" || bad "scenario 2b: parked markers falsely alerted (the exact ga-4cb2 bug)"
  [ ! -s "$NOTIF2B" ] && ok "scenario 2b: no notify with only parked markers" || bad "scenario 2b: notify fired on parked-only queue (false positive)"

  # ── Scenario 2c: parked markers coexist with ONE active marker → DOES count ──
  # Proves the fix counts precisely, not just the empty-array trivial case:
  # mixing 7 parked (ignored) with 1 genuinely active marker and no recent
  # pass must still surface as a real stall.
  echo "Scenario 2c: 7 needs-rebase + 1 queued (active) + no recent pass → STILL a stall"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true   # fresh episode
  NOTIF2C="$TMP/notif2c"; : > "$NOTIF2C"
  MAIL2C="$TMP/mail2c"; : > "$MAIL2C"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase needs-rebase queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF2C"
  GTSW_TEST_MAILED="$MAIL2C"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && bad "scenario 2c: 1 active marker among parked ones should still return 1" || ok "scenario 2c: 1 genuinely active marker still detected (return 1, under-reporting avoided)"
  grep -q "mail:" "$MAIL2C" 2>/dev/null && ok "scenario 2c: Mayor mailed (real stall, not masked by parked markers)" || bad "scenario 2c: Mayor NOT mailed"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true   # clean slate for downstream scenarios

  # ── Scenario 3: QUOTA-LIMITED (B1: log pattern) → suppress ───────────────
  echo "Scenario 3: quota-limited via log pattern (B1) → suppressed"
  NOTIF3="$TMP/notif3"; : > "$NOTIF3"
  _sc3_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="[${_sc3_now}] [quality-gate-dispatcher] Headroom DEFER: gate em 0 runs (Dolt cpu=200% lat=100ms / cota=LIMITED) — quota-limited; ceiling=0 reviewers, leaving 8 marker(s) queued (ga-cw4pm)."
  GTSW_TEST_QUOTA_RC=0   # B2 says OK but B1 catches it
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF3"
  GTSW_TEST_MAILED="$TMP/mail3"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 3: quota-limited (B1) suppresses alert (return 0)" || bad "scenario 3: quota-limited B1 did NOT suppress (false positive)"
  [ ! -s "$NOTIF3" ] && ok "scenario 3: no notify on quota-limited" || bad "scenario 3: notify fired despite quota-limited (false positive)"

  # ── Scenario 4: QUOTA-LIMITED (B2: live check) → suppress ────────────────
  echo "Scenario 4: quota-limited via live quota-check (B2) → suppressed"
  NOTIF4="$TMP/notif4"; : > "$NOTIF4"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=2   # B2: quota check returns LIMITED
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF4"
  GTSW_TEST_MAILED="$TMP/mail4"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 4: quota-limited (B2) suppresses alert (return 0)" || bad "scenario 4: quota-limited B2 did NOT suppress (false positive)"
  [ ! -s "$NOTIF4" ] && ok "scenario 4: no notify when quota exit=2" || bad "scenario 4: notify fired despite quota exit=2 (false positive)"

  # ── Scenario 5: RECENT PROGRESS → no alert ───────────────────────────────
  # ga-4cb2: uses fmt=new — "Gate PASSED (origin=Pilot): ..." — the CURRENT
  # dispatcher format. This is the exact reported bug: Guard C's old literal
  # "Gate PASSED:" pattern did not match this format at all, so a real pass 30
  # minutes ago would have been invisible and the stall would have fired anyway.
  echo "Scenario 5: Gate PASSED (origin=Pilot) within the stall window → NOT a stall"
  NOTIF5="$TMP/notif5"; : > "$NOTIF5"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued)"
  # Gate PASSED 30 minutes ago (well within the 2h window)
  GTSW_TEST_LOG_LINES="$(make_log 1800 new)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF5"
  GTSW_TEST_MAILED="$TMP/mail5"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 5: recent Gate PASSED (origin=Pilot) suppresses alert (return 0)" || bad "scenario 5: recent Gate PASSED (origin=Pilot) did NOT suppress (the exact ga-4cb2 bug)"
  [ ! -s "$NOTIF5" ] && ok "scenario 5: no notify when Gate PASSED recently" || bad "scenario 5: notify fired despite recent Gate PASSED (false positive)"

  # ── Scenario 5b: RECENT PROGRESS, OLD log format → no alert (backward-compat) ──
  # Historical log lines (pre-format-change, still in the tail on a live box)
  # must keep suppressing too — the broadened match must not have narrowed.
  echo "Scenario 5b: Gate PASSED (old format, no origin tag) within the stall window → NOT a stall"
  NOTIF5B="$TMP/notif5b"; : > "$NOTIF5B"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log 1800 old)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF5B"
  GTSW_TEST_MAILED="$TMP/mail5b"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 5b: recent Gate PASSED (old format) suppresses alert (return 0)" || bad "scenario 5b: old-format Gate PASSED did NOT suppress (backward-compat regression)"
  [ ! -s "$NOTIF5B" ] && ok "scenario 5b: no notify when old-format Gate PASSED recent" || bad "scenario 5b: notify fired despite recent old-format Gate PASSED (false positive)"

  # ── Scenario 6: ACTIVE REVIEWER → no alert ───────────────────────────────
  echo "Scenario 6: active gate-reviewer session → NOT a stall"
  NOTIF6="$TMP/notif6"; : > "$NOTIF6"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS="gate-reviewer-adhoc-abc123 (running)"
  GTSW_TEST_NOTIFIED="$NOTIF6"
  GTSW_TEST_MAILED="$TMP/mail6"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 6: active reviewer suppresses alert (return 0)" || bad "scenario 6: active reviewer did NOT suppress (false positive)"
  [ ! -s "$NOTIF6" ] && ok "scenario 6: no notify when reviewer active" || bad "scenario 6: notify fired despite active reviewer (false positive)"

  # ── Scenario 7: AUTORECOVER disabled → alert but no kickstart ────────────
  echo "Scenario 7: stall detected with GTSW_AUTORECOVER=0 → alert but no kickstart"
  KICKS7="$TMP/kicks7"; : > "$KICKS7"
  NOTIF7="$TMP/notif7"; : > "$NOTIF7"
  GTSW_AUTORECOVER=0
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS7"
  GTSW_TEST_NOTIFIED="$NOTIF7"
  GTSW_TEST_MAILED="$TMP/mail7"
  rm -f "$TMP/recover-marker" 2>/dev/null || true   # fresh episode (first detection)
  run_sweep && bad "scenario 7: stall should return 1" || ok "scenario 7: stall detected (return 1) with AUTORECOVER=0"
  # recover-first: first detection mails the Mayor but does NOT page Athos; AUTORECOVER=0 also means no kickstart
  [ ! -s "$NOTIF7" ] && ok "scenario 7: Athos NOT paged on first detection" || bad "scenario 7: Athos paged on first detection (should recover-first)"
  [ ! -s "$KICKS7" ] && ok "scenario 7: no kickstart when AUTORECOVER=0" || bad "scenario 7: kickstart fired despite AUTORECOVER=0"
  GTSW_AUTORECOVER=1   # restore

  # ── Scenario 8: KILL-SWITCH → no-op ─────────────────────────────────────
  echo "Scenario 8: GTSW_ENABLED=0 → no-op (return 0, no notify)"
  NOTIF8="$TMP/notif8"; : > "$NOTIF8"
  GTSW_ENABLED=0
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF8"
  GTSW_TEST_MAILED="$TMP/mail8"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 8: GTSW_ENABLED=0 returns 0 (no-op)" || bad "scenario 8: ENABLED=0 unexpectedly non-zero"
  [ ! -s "$NOTIF8" ] && ok "scenario 8: no notify when disabled" || bad "scenario 8: notify fired despite ENABLED=0"
  GTSW_ENABLED=1   # restore

  # ── Scenario 9: DRY-RUN → logs but no side effects ───────────────────────
  echo "Scenario 9: GTSW_DRY_RUN=1 → stall detected, logs intent, no notify/mail/kickstart"
  rm -f "$TMP/cooldown" 2>/dev/null || true   # scenario 7 wrote cooldown file; clear so DRY_RUN path runs
  KICKS9="$TMP/kicks9"; : > "$KICKS9"
  NOTIF9="$TMP/notif9"; : > "$NOTIF9"
  GTSW_DRY_RUN=1
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS9"
  GTSW_TEST_NOTIFIED="$NOTIF9"
  GTSW_TEST_MAILED="$TMP/mail9"
  run_sweep && bad "scenario 9: stall+DRY_RUN should still return 1" || ok "scenario 9: DRY_RUN returns 1 (stall confirmed, dry)"
  [ ! -s "$NOTIF9" ] && ok "scenario 9: no notify in DRY_RUN" || bad "scenario 9: notify fired in DRY_RUN"
  [ ! -s "$KICKS9" ] && ok "scenario 9: no kickstart in DRY_RUN" || bad "scenario 9: kickstart fired in DRY_RUN"
  grep -q "DRY_RUN" "$LOG" 2>/dev/null && ok "scenario 9: DRY_RUN logged intent" || bad "scenario 9: DRY_RUN intent not logged"
  GTSW_DRY_RUN=0   # restore

  # ── Scenario 10: BASH -N CHECK ───────────────────────────────────────────
  echo "Scenario 10: bash -n syntax check (catch regressions)"
  bash -n "$0" 2>/dev/null && ok "scenario 10: bash -n syntax check passes" || bad "scenario 10: bash -n FAILED — syntax error"

  # ── Scenario 11: ATHOS-PAGE COOLDOWN DEDUP ────────────────────────────────
  # Recover-first: the cooldown dedups the ATHOS PAGE, which only fires on ESCALATION
  # (recovery failed past grace). Pre-stamp an old recover-marker so the 1st run takes
  # the escalation path (pages Athos + arms cooldown); the 2nd run is then suppressed.
  echo "Scenario 11: Athos-page cooldown dedup — page fires once on escalation, 2nd run suppressed"
  rm -f "$TMP/cooldown" 2>/dev/null || true  # ensure clean slate
  GTSW_RECOVER_GRACE_SECS=420
  echo "$(( $(date +%s) - 420 - 100 ))" > "$TMP/recover-marker"   # recovery attempted, grace elapsed → escalation
  NOTIF11a="$TMP/notif11a"; : > "$NOTIF11a"
  MAIL11a="$TMP/mail11a";   : > "$MAIL11a"
  KICKS11a="$TMP/kicks11a"; : > "$KICKS11a"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS11a"
  GTSW_TEST_NOTIFIED="$NOTIF11a"
  GTSW_TEST_MAILED="$MAIL11a"
  run_sweep && bad "scenario 11a: 1st stall should return 1" || ok "scenario 11a: 1st stall detected (return 1)"
  grep -q "notify:" "$NOTIF11a" 2>/dev/null && ok "scenario 11a: Athos paged on escalation (1st run)" || bad "scenario 11a: Athos NOT paged on escalation"
  [ -f "$TMP/cooldown" ] && ok "scenario 11a: cooldown file written after page" || bad "scenario 11a: cooldown file NOT written after page"
  # 2nd run — same stall conditions, cooldown should suppress notify+mail
  NOTIF11b="$TMP/notif11b"; : > "$NOTIF11b"
  MAIL11b="$TMP/mail11b";   : > "$MAIL11b"
  KICKS11b="$TMP/kicks11b"; : > "$KICKS11b"
  GTSW_TEST_NOTIFIED="$NOTIF11b"
  GTSW_TEST_MAILED="$MAIL11b"
  GTSW_TEST_KICKSTARTS="$KICKS11b"
  run_sweep && bad "scenario 11b: 2nd stall should return 1 (stall persists)" || ok "scenario 11b: 2nd stall still returns 1 (cooldown suppressed dup)"
  [ ! -s "$NOTIF11b" ] && ok "scenario 11b: notify suppressed by cooldown" || bad "scenario 11b: notify fired despite cooldown (dup alert!)"
  [ ! -s "$MAIL11b" ] && ok "scenario 11b: mail suppressed by cooldown" || bad "scenario 11b: mail fired despite cooldown (dup alert!)"
  [ ! -s "$KICKS11b" ] && ok "scenario 11b: kickstart suppressed by cooldown" || bad "scenario 11b: kickstart fired despite cooldown"
  grep -q "cooldown active" "$LOG" 2>/dev/null && ok "scenario 11b: cooldown suppression logged" || bad "scenario 11b: cooldown suppression NOT logged"

  # ── Scenario 12: COOLDOWN RESET ON STALL-CLEAR ────────────────────────────
  echo "Scenario 12: stall-clear resets cooldown → next stall episode re-alerts immediately"
  # Pre-condition: cooldown file from 1 minute ago (within 2h window → would suppress)
  echo "$(( $(date +%s) - 60 ))" > "$TMP/cooldown"
  # Stall CLEARS via 0 active markers (Guard A should delete the cooldown file).
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 12a: stall-clear (empty queue) returns 0" || bad "scenario 12a: stall-clear should return 0"
  [ ! -f "$TMP/cooldown" ] && ok "scenario 12a: cooldown file deleted on stall-clear (Guard A)" || bad "scenario 12a: cooldown file NOT deleted on stall-clear"
  # Fresh stall after clear — cooldown was reset, alert should fire again immediately
  NOTIF12b="$TMP/notif12b"; : > "$NOTIF12b"
  KICKS12b="$TMP/kicks12b"; : > "$KICKS12b"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS12b"
  GTSW_TEST_NOTIFIED="$NOTIF12b"
  GTSW_TEST_MAILED="$TMP/mail12b"
  run_sweep && bad "scenario 12b: fresh stall after clear should return 1" || ok "scenario 12b: fresh stall after clear detected (return 1)"
  # recover-first: the clear (Guard A) reset BOTH cooldown and recover-marker, so the
  # fresh episode re-engages recovery (re-stamps the marker + re-mails the Mayor) rather
  # than staying stale-suppressed. Athos is paged only if THIS episode persists past grace.
  [ -f "$TMP/recover-marker" ] && ok "scenario 12b: recovery re-engaged after clear (marker re-stamped — not stale-suppressed)" || bad "scenario 12b: marker NOT re-stamped (clear-reset failed!)"
  [ ! -s "$NOTIF12b" ] && ok "scenario 12b: Athos NOT paged on the fresh episode's first detection (recover-first)" || bad "scenario 12b: Athos paged on first detection of fresh episode"

  # ── Scenario 13 (ga-p5q3 defense (a)): bd/jq query FAILURE → fail-open ────
  # A query failure must read as UNKNOWN, never as "0 active" nor "stalled".
  # Both an empty bd response (query error swallowed by 2>/dev/null) and a
  # malformed/non-JSON response (jq parse failure) must fail toward "no stall
  # verdict" rather than either false-alarming or silently under-reporting.
  echo "Scenario 13 (ga-p5q3): active-marker query failure → fail-open, no alert"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF13a="$TMP/notif13a"; : > "$NOTIF13a"
  GTSW_TEST_ACTIVE_MARKERS_JSON=""    # simulates a failed/empty bd query response
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF13a"
  GTSW_TEST_MAILED="$TMP/mail13a"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 13a: empty bd response fails open (return 0)" || bad "scenario 13a: empty bd response should fail open, not alert"
  [ ! -s "$NOTIF13a" ] && ok "scenario 13a: no notify on query failure" || bad "scenario 13a: notify fired despite unreadable marker state"
  grep -q "could not read active gate-marker count" "$LOG" 2>/dev/null && ok "scenario 13a: failure logged as WARN (distinguishable from a real empty queue)" || bad "scenario 13a: failure not logged"

  echo "Scenario 13b (ga-p5q3): malformed bd JSON → fail-open, no alert"
  NOTIF13b="$TMP/notif13b"; : > "$NOTIF13b"
  GTSW_TEST_ACTIVE_MARKERS_JSON="not valid json{{{"    # simulates a jq parse failure
  GTSW_TEST_NOTIFIED="$NOTIF13b"
  GTSW_TEST_MAILED="$TMP/mail13b"
  run_sweep && ok "scenario 13b: malformed JSON fails open (return 0)" || bad "scenario 13b: malformed JSON should fail open, not alert"
  [ ! -s "$NOTIF13b" ] && ok "scenario 13b: no notify on malformed JSON" || bad "scenario 13b: notify fired despite malformed marker JSON"

  # ── Scenario 14 (ga-sdkqs): WEEKLY quota-limited (fresh) → NOT a stall, no kickstart ──
  # The exact reported incident: the city was weekly-exhausted (5/7 agent panes showed
  # "You've hit your weekly limit"). B1 (log grep for cota=LIMITED) never fires for this —
  # only the gate/pilot's own SESSION-scope defer line does. B2 (claude-quota-check.sh
  # hard verdict) also stays "not limited" for a weekly-only exhaustion BY DESIGN
  # (ga-ot735: weekly is advisory, doesn't hard-pause the scheduler). So pre-fix, NEITHER
  # existing guard suppresses, and the watchdog escalates + kickstarts — which burns the
  # very quota that is scarce. This is the exact bug ga-sdkqs reports.
  echo "Scenario 14 (ga-sdkqs): weekly quota-limited (fresh, via claude-quota-check.sh --json) → NOT a stall, no kickstart"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true   # fresh episode
  KICKS14="$TMP/kicks14"; : > "$KICKS14"
  NOTIF14="$TMP/notif14"; : > "$NOTIF14"
  MAIL14="$TMP/mail14"; : > "$MAIL14"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"    # no "cota=LIMITED" in the tail — B1 does not catch this
  GTSW_TEST_QUOTA_RC=0                 # B2 (session-scope hard verdict): NOT limited, by ga-ot735 design
  GTSW_TEST_QUOTA_JSON='{"limited":false,"weekly":{"active":true,"reset_time_text":"Aug 13 at 9pm"}}'
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS14"
  GTSW_TEST_NOTIFIED="$NOTIF14"
  GTSW_TEST_MAILED="$MAIL14"
  run_sweep && ok "scenario 14: weekly-limited suppresses alert (return 0)" || bad "scenario 14: weekly-limited did NOT suppress (the exact ga-sdkqs bug — kickstart would burn the scarce quota)"
  [ ! -s "$NOTIF14" ] && ok "scenario 14: no Athos page when weekly-limited" || bad "scenario 14: Athos paged despite weekly-limited"
  [ ! -s "$KICKS14" ] && ok "scenario 14: no kickstart when weekly-limited (kickstart would burn scarce quota)" || bad "scenario 14: kickstart fired despite weekly-limited"
  [ ! -s "$MAIL14" ] && ok "scenario 14: no Mayor mail when weekly-limited (quiet, per AC1)" || bad "scenario 14: mail fired despite weekly-limited"
  grep -q "quota-limited (semanal)" "$LOG" 2>/dev/null && ok "scenario 14: logged as weekly quota-limited with reset ETA (AC1)" || bad "scenario 14: weekly suppression not logged with the required wording"

  # ── Scenario 15 (ga-sdkqs AC2): claude-quota-check.sh --json unreadable → UNKNOWN ──
  # "Couldn't determine the weekly state" must never collapse into "confirmed not
  # quota-limited" (the exact error-vs-empty class this file's own FAIL-SAFE header rule
  # already names). A crashed/garbled quota-check must fail TOWARD no-stall-verdict, same
  # direction as every other read-failure guard in this file (A, C-timestamp, D).
  echo "Scenario 15 (ga-sdkqs AC2): claude-quota-check.sh --json unreadable → quota state UNKNOWN, fail-open (NOT treated as 'not quota-limited')"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  KICKS15="$TMP/kicks15"; : > "$KICKS15"
  NOTIF15="$TMP/notif15"; : > "$NOTIF15"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_QUOTA_JSON="not valid json{{{"   # simulates a crashed/garbled quota-check
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS15"
  GTSW_TEST_NOTIFIED="$NOTIF15"
  GTSW_TEST_MAILED="$TMP/mail15"
  run_sweep && ok "scenario 15: unreadable quota-check fails open (return 0, no stall verdict)" || bad "scenario 15: unreadable quota-check should fail open, not alert"
  [ ! -s "$KICKS15" ] && ok "scenario 15: no kickstart when quota state is unknown" || bad "scenario 15: kickstart fired despite unknown quota state"
  grep -q "quota state UNKNOWN" "$LOG" 2>/dev/null && ok "scenario 15: unreadable quota-check logged as UNKNOWN (distinguishable from confirmed-OK)" || bad "scenario 15: unreadable quota-check not logged distinctly"

  # ── Scenario 16 (ga-sdkqs AC4, disarm): weekly.active=false → normal stall logic ──
  # claude-quota-check.sh owns the staleness/disarm decision (its own freshness guard
  # clears WEEKLY_ACTIVE once the account stops re-hitting the cap — see its selftest).
  # This watchdog's job is simply to NOT get stuck suppressing once upstream reports
  # weekly.active=false — proving it stays able to detect a REAL stall after quota
  # recovers, rather than trading the false-negative for a permanent false-positive.
  echo "Scenario 16 (ga-sdkqs AC4): weekly.active=false (claude-quota-check.sh's own freshness guard already cleared it) → stall fires normally, watchdog not permanently blind"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true   # fresh episode
  KICKS16="$TMP/kicks16"; : > "$KICKS16"
  MAIL16="$TMP/mail16"; : > "$MAIL16"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_QUOTA_JSON='{"limited":false,"weekly":{"active":false,"reset_time_text":""}}'
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$KICKS16"
  GTSW_TEST_NOTIFIED="$TMP/notif16"; : > "$TMP/notif16"
  GTSW_TEST_MAILED="$MAIL16"
  run_sweep && bad "scenario 16: weekly.active=false should NOT suppress — real stall must still fire" || ok "scenario 16: weekly.active=false does not block a real stall (return 1) — watchdog stays able to detect stalls after quota recovers"
  grep -q "mail:" "$MAIL16" 2>/dev/null && ok "scenario 16: Mayor mailed (real stall, not masked by a stale/cleared weekly signal)" || bad "scenario 16: Mayor NOT mailed"
  [ -s "$KICKS16" ] && ok "scenario 16: kickstart fires for a real stall once weekly is confirmed not-active" || bad "scenario 16: kickstart withheld despite weekly.active=false"

  # ── Scenario 17 (ga-lda92s): quiet hours explain a raw-stale Gate PASSED → NOT a stall ──
  # Helper: build a "Gate PASSED" log line at an ABSOLUTE local timestamp (not
  # relative to real now like make_log — GTSW_TEST_NOW pins "now" independently,
  # so the embedded timestamp must be constructed independently too).
  make_log_at() {
    local hms="$1"  # "YYYY-MM-DD HH:MM:SS"
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] === Dispatcher sweep start (DRY_RUN=0) ==="
    echo "[${hms}] [quality-gate-dispatcher] Gate PASSED (origin=Pilot): branch=fix/ga-test tier=CODE merge_sha=abc123 elapsed=300s"
  }
  TODAY="$(date +%Y-%m-%d)"

  echo "Scenario 17 (ga-lda92s): last Gate PASSED at 00:30, now=08:05 (raw 455min > 165min window) — quiet hours (00h-08h) explains it → NOT a stall"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  unset QUIET_HOURS_OVERRIDE
  GTSW_TEST_NOW="$(date -j -f "%Y-%m-%d %H:%M:%S" "${TODAY} 08:05:00" +%s)"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log_at "${TODAY} 00:30:00")"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  NOTIF17="$TMP/notif17"; : > "$NOTIF17"
  MAIL17="$TMP/mail17"; : > "$MAIL17"
  GTSW_TEST_KICKSTARTS="$TMP/kicks17"; : > "$TMP/kicks17"
  GTSW_TEST_NOTIFIED="$NOTIF17"
  GTSW_TEST_MAILED="$MAIL17"
  run_sweep && ok "scenario 17: quiet-hours-explained gap suppresses alert (return 0)" || bad "scenario 17: should NOT alert — raw gap is fully explained by quiet hours"
  [ ! -s "$MAIL17" ] && ok "scenario 17: no Mayor mail (quiet-hours suppressed)" || bad "scenario 17: Mayor mailed despite quiet-hours-explained gap"
  grep -q "SUPPRESSED (quiet hours): raw 455min, quiet-adjusted 5min" "$LOG" 2>/dev/null && ok "scenario 17: suppression logged distinctly with raw+adjusted minutes (detector ran and decided, not silent)" || bad "scenario 17: suppression not logged with expected raw/adjusted figures"

  # ── Scenario 17b: SAME timestamps, but the live signal says OPEN (override
  # engaged) while "now" is still inside tonight's calendar window → the
  # override-safety check must NOT trust today's portion → stall fires anyway.
  # This is the literal bug-AC bidirectional pair: QUIET must not mail, OPEN
  # must — proving the fix is conditional, not a blanket mute.
  echo "Scenario 17b (ga-lda92s): same-night gap, but live signal reads OPEN (override) at a 'now' still inside the window → stall still fires"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  QUIET_HOURS_OVERRIDE=OPEN
  GTSW_TEST_NOW="$(date -j -f "%Y-%m-%d %H:%M:%S" "${TODAY} 03:00:00" +%s)"
  GTSW_TEST_LOG_LINES="$(make_log_at "${TODAY} 00:00:01")"
  NOTIF17B="$TMP/notif17b"; : > "$NOTIF17B"
  MAIL17B="$TMP/mail17b"; : > "$MAIL17B"
  GTSW_TEST_KICKSTARTS="$TMP/kicks17b"; : > "$TMP/kicks17b"
  GTSW_TEST_NOTIFIED="$NOTIF17B"
  GTSW_TEST_MAILED="$MAIL17B"
  run_sweep && bad "scenario 17b: should alert — override means the window was NOT actually enforced" || ok "scenario 17b: OPEN-override gap still alerts (return 1) — quiet-hours fix is not a blanket mute"
  grep -q "mail:" "$MAIL17B" 2>/dev/null && ok "scenario 17b: Mayor mailed (real stall, override means quiet hours does not apply)" || bad "scenario 17b: Mayor NOT mailed despite override-confirmed non-quiet gap"
  unset QUIET_HOURS_OVERRIDE

  # ── Scenario 17c: gap entirely in daytime hours (no quiet-window overlap
  # at all) → adjustment is a no-op, real stall fires exactly as before this
  # fix — proves ordinary daytime stalls are untouched.
  echo "Scenario 17c (ga-lda92s): raw-stale gap entirely during the day (no quiet-hours overlap) → stall fires unaffected"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  GTSW_TEST_NOW="$(date -j -f "%Y-%m-%d %H:%M:%S" "${TODAY} 12:30:00" +%s)"
  GTSW_TEST_LOG_LINES="$(make_log_at "${TODAY} 09:00:00")"
  NOTIF17C="$TMP/notif17c"; : > "$NOTIF17C"
  MAIL17C="$TMP/mail17c"; : > "$MAIL17C"
  GTSW_TEST_KICKSTARTS="$TMP/kicks17c"; : > "$TMP/kicks17c"
  GTSW_TEST_NOTIFIED="$NOTIF17C"
  GTSW_TEST_MAILED="$MAIL17C"
  run_sweep && bad "scenario 17c: should alert — daytime gap has nothing to discount" || ok "scenario 17c: daytime stall (no quiet-hours overlap) still alerts (return 1)"
  grep -q "mail:" "$MAIL17C" 2>/dev/null && ok "scenario 17c: Mayor mailed (ordinary daytime stall unaffected by this fix)" || bad "scenario 17c: Mayor NOT mailed for an ordinary daytime stall"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  unset GTSW_TEST_NOW

  # ── Scenario 18 (ga-p62tl, disparo 2): YOUNG marker within sweep-cadence
  # grace → NOT a stall ─────────────────────────────────────────────────────
  # The exact reported fixture: one marker queued 5s ago, a healthy dispatcher
  # logging normal sweep-start lines ~200s apart (well within a single cycle),
  # 0 Gate PASSED in the window, no active reviewer. Pre-fix this alarms.
  echo "Scenario 18 (ga-p62tl): marker queued 5s ago, healthy dispatcher cadence ~200s → sweep-cadence grace, NOT a stall"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  make_markers_ts() {
    # Like make_markers, but each bead also carries updated_at at now-<age_sec>.
    # Usage: make_markers_ts age_sec status [status...]
    local age="$1"; shift
    local now; now="$(date +%s)"
    local upd; upd="$(date -u -r $((now - age)) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$((now - age))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
    local out="[" first=1 st i=0
    for st in "$@"; do
      if [ "$first" -eq 1 ]; then first=0; else out="${out},"; fi
      i=$((i+1))
      out="${out}{\"id\":\"m${i}\",\"status\":\"open\",\"updated_at\":\"${upd}\",\"labels\":[\"type:quality-gate-marker\",\"gate-status:${st}\"]}"
    done
    out="${out}]"
    printf '%s' "$out"
  }
  make_dispatcher_log_cadence() {
    # N "Dispatcher sweep start" lines, gap_sec apart, most recent ending "now".
    local gap_sec="${1:-200}" n="${2:-5}" now; now="$(date +%s)"
    local i t
    for i in $(seq "$n" -1 0); do
      t="$(date -u -r $((now - i * gap_sec)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$((now - i * gap_sec))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
      echo "[${t}] [quality-gate-dispatcher] === Dispatcher sweep start (DRY_RUN=0) ==="
    done
  }
  NOTIF18="$TMP/notif18"; : > "$NOTIF18"
  MAIL18="$TMP/mail18"; : > "$MAIL18"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers_ts 5 queued)"
  GTSW_TEST_LOG_LINES="$(make_dispatcher_log_cadence 200 5)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$TMP/kicks18"; : > "$TMP/kicks18"
  GTSW_TEST_NOTIFIED="$NOTIF18"
  GTSW_TEST_MAILED="$MAIL18"
  run_sweep && ok "scenario 18: young marker (5s) within sweep-cadence grace returns 0 (no alert)" || bad "scenario 18: young marker falsely alerted (the exact ga-p62tl disparo-2 bug)"
  [ ! -s "$MAIL18" ] && ok "scenario 18: Mayor NOT mailed (grace, not a stall)" || bad "scenario 18: Mayor mailed despite sweep-cadence grace"
  grep -q "sweep-cadence grace" "$LOG" 2>/dev/null && ok "scenario 18: suppression logged distinctly (sweep-cadence grace)" || bad "scenario 18: grace suppression not logged distinctly"

  # ── Scenario 19 (ga-p62tl): OLD marker past grace → stall STILL fires ────
  # Proves guard E is not a blanket mute: a marker stuck for far longer than
  # 2x the measured cadence, on the same healthy-looking dispatcher log, must
  # still alert normally.
  echo "Scenario 19 (ga-p62tl): marker queued 40min ago (>> 2x measured ~200s cadence) → stall still fires"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF19="$TMP/notif19"; : > "$NOTIF19"
  MAIL19="$TMP/mail19"; : > "$MAIL19"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers_ts 2400 queued)"
  GTSW_TEST_LOG_LINES="$(make_dispatcher_log_cadence 200 5)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_KICKSTARTS="$TMP/kicks19"; : > "$TMP/kicks19"
  GTSW_TEST_NOTIFIED="$NOTIF19"
  GTSW_TEST_MAILED="$MAIL19"
  run_sweep && bad "scenario 19: old marker (40min) should still return 1" || ok "scenario 19: old marker past sweep-cadence grace still detected (return 1)"
  grep -q "mail:" "$MAIL19" 2>/dev/null && ok "scenario 19: Mayor mailed (real stall, grace does not mask a genuinely stuck marker)" || bad "scenario 19: Mayor NOT mailed for a genuinely stuck old marker"

  # ── Scenario 20 (ga-p62tl, disparo 1): gate-run bead in flight within its
  # own budget → NOT a stall, even with NO active session in `gc session
  # list` (the exact disparo-1 shape: a live reviewer that guard D's session
  # grep did not see) ───────────────────────────────────────────────────────
  echo "Scenario 20 (ga-p62tl): quality-gate-run bead running+in-budget, session list empty → guard F catches it, NOT a stall"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF20="$TMP/notif20"; : > "$NOTIF20"
  MAIL20="$TMP/mail20"; : > "$MAIL20"
  _sc20_created="$(date -u -r $(( $(date +%s) - 337 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( $(date +%s) - 337 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""    # empty on purpose — reproduces guard D missing a live reviewer
  GTSW_TEST_GATE_RUN_JSON="[{\"id\":\"ga-py9am\",\"created_at\":\"${_sc20_created}\",\"description\":\"verdict_timeout_minutes: 50\\nbranch: fix/ga-test\"}]"
  GTSW_TEST_KICKSTARTS="$TMP/kicks20"; : > "$TMP/kicks20"
  GTSW_TEST_NOTIFIED="$NOTIF20"
  GTSW_TEST_MAILED="$MAIL20"
  run_sweep && ok "scenario 20: in-flight gate-run (within budget) returns 0 (no alert) despite empty session list" || bad "scenario 20: in-flight gate-run did NOT suppress (the exact ga-p62tl disparo-1 bug)"
  [ ! -s "$MAIL20" ] && ok "scenario 20: Mayor NOT mailed (run genuinely in flight)" || bad "scenario 20: Mayor mailed despite in-flight run"
  grep -q "run in flight, not a stall" "$LOG" 2>/dev/null && ok "scenario 20: suppression logged distinctly (gate-run in flight)" || bad "scenario 20: gate-run-in-flight suppression not logged distinctly"
  # RESET (not unset!) — an unset here would fall through downstream scenarios
  # to the LIVE bd query against this machine's real $HQ (guard F's own
  # elif branch), making them depend on whatever gate-run happens to be
  # running in production right now. Confirmed live: this exact gap made
  # scenario 22/23 flaky against real production state before this fix.
  GTSW_TEST_GATE_RUN_JSON='[]'

  # ── Scenario 21 (ga-p62tl): gate-run bead PAST its own budget → stall
  # still fires (guard F is not a blanket mute either) ─────────────────────
  echo "Scenario 21 (ga-p62tl): quality-gate-run bead exists but is PAST its own verdict-timeout+margin → stall still fires"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF21="$TMP/notif21"; : > "$NOTIF21"
  MAIL21="$TMP/mail21"; : > "$MAIL21"
  _sc21_created="$(date -u -r $(( $(date +%s) - 4200 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "@$(( $(date +%s) - 4200 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"  # 70min ago
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_GATE_RUN_JSON="[{\"id\":\"ga-zombie\",\"created_at\":\"${_sc21_created}\",\"description\":\"verdict_timeout_minutes: 50\\nbranch: fix/ga-test\"}]"  # 50+10min budget < 70min age
  GTSW_TEST_KICKSTARTS="$TMP/kicks21"; : > "$TMP/kicks21"
  GTSW_TEST_NOTIFIED="$NOTIF21"
  GTSW_TEST_MAILED="$MAIL21"
  run_sweep && bad "scenario 21: past-budget gate-run should still return 1" || ok "scenario 21: gate-run past its own budget does not mask the stall (return 1)"
  grep -q "mail:" "$MAIL21" 2>/dev/null && ok "scenario 21: Mayor mailed (zombie run does not count as in-flight progress)" || bad "scenario 21: Mayor NOT mailed despite a past-budget gate-run"
  GTSW_TEST_GATE_RUN_JSON='[]'   # reset, not unset — see scenario 20's comment on why

  # ── Scenario 22 (ga-p62tl): queue-composition says real=0 → NOT a stall ──
  # Guard A's label filter thinks the queue is active, but deeper git-level
  # analysis (gate-queue-composition.sh) says every one of those markers is
  # phantom (e.g. branch already merged) — must not escalate on the raw count.
  echo "Scenario 22 (ga-p62tl): gate-queue-composition.sh reports real=0 → NOT a stall despite label-active markers"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF22="$TMP/notif22"; : > "$NOTIF22"
  MAIL22="$TMP/mail22"; : > "$MAIL22"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_QUEUE_COMPOSITION_JSON='{"total":2,"real":0,"phantom":2,"unknown":0}'
  GTSW_TEST_KICKSTARTS="$TMP/kicks22"; : > "$TMP/kicks22"
  GTSW_TEST_NOTIFIED="$NOTIF22"
  GTSW_TEST_MAILED="$MAIL22"
  run_sweep && ok "scenario 22: composition real=0 returns 0 (no alert)" || bad "scenario 22: composition real=0 did NOT suppress (escalated on phantom-only queue)"
  [ ! -s "$MAIL22" ] && ok "scenario 22: Mayor NOT mailed (all-phantom queue per deep analysis)" || bad "scenario 22: Mayor mailed despite composition real=0"
  grep -q "gate-queue-composition.sh reports real=0" "$LOG" 2>/dev/null && ok "scenario 22: suppression logged distinctly (queue composition)" || bad "scenario 22: composition suppression not logged distinctly"

  # ── Scenario 23 (ga-p62tl): queue-composition says real>=1 → stall fires ──
  # Guard G is a cross-check, not a blanket mute: confirmed real work must
  # still alert exactly as before this fix.
  echo "Scenario 23 (ga-p62tl): gate-queue-composition.sh reports real=1 → stall still fires normally"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true
  NOTIF23="$TMP/notif23"; : > "$NOTIF23"
  MAIL23="$TMP/mail23"; : > "$MAIL23"
  GTSW_TEST_ACTIVE_MARKERS_JSON="$(make_markers queued)"
  GTSW_TEST_LOG_LINES="$(make_log)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_QUEUE_COMPOSITION_JSON='{"total":1,"real":1,"phantom":0,"unknown":0}'
  GTSW_TEST_KICKSTARTS="$TMP/kicks23"; : > "$TMP/kicks23"
  GTSW_TEST_NOTIFIED="$NOTIF23"
  GTSW_TEST_MAILED="$MAIL23"
  run_sweep && bad "scenario 23: composition real=1 should still return 1" || ok "scenario 23: composition-confirmed real work still alerts (return 1)"
  grep -q "mail:" "$MAIL23" 2>/dev/null && ok "scenario 23: Mayor mailed (confirmed real backlog, guard G is not a blanket mute)" || bad "scenario 23: Mayor NOT mailed despite composition-confirmed real work"
  rm -f "$TMP/cooldown" "$TMP/recover-marker" 2>/dev/null || true

  # ── CLEANUP / SUMMARY ─────────────────────────────────────────────────────
  # Unset test seams so no state leaks
  unset GTSW_TEST_ACTIVE_MARKERS_JSON GTSW_TEST_LOG_LINES GTSW_TEST_QUOTA_RC GTSW_TEST_QUOTA_JSON GTSW_TEST_SESSIONS
  unset GTSW_TEST_KICKSTARTS GTSW_TEST_NOTIFIED GTSW_TEST_MAILED GTSW_TEST_NOW QUIET_HOURS_OVERRIDE
  unset GTSW_TEST_GATE_RUN_JSON GTSW_TEST_QUEUE_COMPOSITION_JSON

  echo ""
  echo "gate-throughput-stall-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; stall result already sent via notify+mail

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
#   1. Parse the gate dispatcher log (last GTSW_LOG_TAIL lines) for evidence of
#      a non-empty queue: "Found N queued marker(s)" with N>0.
#   2. Scan the same window for evidence of progress: "Gate PASSED:" within
#      GTSW_STALL_MINUTES (default 165min; data: inter-merge p95=127min, p99=240min).
#   3. FALSE-POSITIVE GUARDS (all must fail to declare a stall):
#      a. Empty queue → NOT a stall (idle pipeline).
#      b. "cota=LIMITED" or "quota-limited" in any Headroom DEFER line in the
#         tail → quota-limited, self-heals on window reset; suppress.
#      c. A "Gate PASSED:" line within the window → progress; not a stall.
#      d. An active gate-reviewer session running (gc session list shows a live
#         session named gate-reviewer*) → reviewer in-flight; not a stall.
#   4. STALL = queue non-empty AND 0 Gate PASSED in window AND not quota-limited
#      AND no active reviewer.
#   5. On stall: notify -p 4 + gc mail send mayor.
#      If GTSW_AUTORECOVER=1 (default): kickstart -k supervisor AND
#      quality-gate-dispatcher to unstick the gate.
#
# FAIL-SAFE: any signal read error → treat as "flow present" (never false-alarm).
# An idle gate (empty queue) NEVER fires.
#
# KILL-SWITCH: GTSW_ENABLED=0 → no-op.
# DRY-RUN: GTSW_DRY_RUN=1 → log decisions but skip notify/mail/kickstart.
#
# Selftest: bash gate-throughput-stall-watchdog.sh --selftest
#   Scenarios: stall→alert, empty-queue→no-alert, quota-limited→no-alert,
#   recent-progress→no-alert, active-reviewer→no-alert, autorecover-path.
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

# ── helpers ───────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [gtsw] $*" >> "$LOG" 2>/dev/null || true; }

# ── main sweep function (pure-ish; all I/O goes through overrideable vars) ───
# Test seams: override these vars to inject fake data without touching disk/net.
#   GTSW_TEST_LOG_LINES    — newline-separated fake log content (replaces tail)
#   GTSW_TEST_QUOTA_RC     — fake exit code for quota-check (0=ok, 2=limited)
#   GTSW_TEST_SESSIONS     — fake gc session list output
#   GTSW_TEST_KICKSTARTS   — file to record kickstart calls (for assertions)
#   GTSW_TEST_NOTIFIED     — file to record notify calls
#   GTSW_TEST_MAILED       — file to record gc mail calls

run_sweep() {
  # Kill-switch
  if [ "${GTSW_ENABLED:-1}" != "1" ]; then
    log "disabled (GTSW_ENABLED=0) — no-op"
    return 0
  fi

  local now; now="$(date +%s)"
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

  # ── FALSE-POSITIVE GUARD A: empty queue ───────────────────────────────────
  # Use the MOST RECENT "Found N queued marker(s)" line — that is the CURRENT
  # queue state. The old code matched ANY N>0 anywhere in the tail and broke on
  # the FIRST (oldest) hit, so a transient marker that already CLEARED left a stale
  # "Found 1" line and the watchdog treated an idle gate as a non-empty queue →
  # false STALL on an idle gate (observed 06-27: queued=0 now, but a brief marker
  # earlier in the tail tripped it). Scan all lines, keep the LAST N, test that.
  local queued_found=0 latest_found_n=""
  while IFS= read -r line; do
    if echo "$line" | grep -qE "Found [0-9]+ queued marker"; then
      latest_found_n=$(echo "$line" | grep -oE "Found [0-9]+ queued marker" | grep -oE "[0-9]+" | head -1)
    fi
  done <<< "$log_lines"
  [ -n "$latest_found_n" ] && [ "$latest_found_n" -gt 0 ] 2>/dev/null && queued_found=1

  if [ "$queued_found" -eq 0 ]; then
    # COOLDOWN RESET: queue empty → stall cleared; disarm so next episode re-alerts immediately
    [ -f "${COOLDOWN_FILE}" ] && { rm -f "${COOLDOWN_FILE}" 2>/dev/null || true; log "COOLDOWN RESET: queue empty — cooldown disarmed"; }
    # ga-evjs2: also clear the recover-marker so a NEW episode starts recover-first (no stale escalation)
    [ -f "${RECOVER_MARKER_FILE}" ] && { rm -f "${RECOVER_MARKER_FILE}" 2>/dev/null || true; log "RECOVER-MARKER RESET: queue empty — next episode recovers before paging Athos"; }
    log "OK: no queued markers found in tail — gate idle (not a stall)"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD B: quota-limited ────────────────────────────────
  # Two sub-checks:
  # B1. Scan the log tail for Headroom DEFER lines with "cota=LIMITED" or
  #     "quota-limited". If the MOST RECENT queued-markers line is followed
  #     (or accompanied) by such a DEFER line, quota is the reason — suppress.
  # B2. Run claude-quota-check.sh (exit 2 = LIMITED). Use B1 as primary (faster,
  #     no disk scan) and B2 as confirmation. Either → suppress.
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

  if [ "$quota_limited" -eq 1 ]; then
    log "OK: gate queue non-empty but quota-limited — self-heals on window reset (not a stall)"
    return 0
  fi

  # ── FALSE-POSITIVE GUARD C: recent gate progress ──────────────────────────
  # Scan the tail for "Gate PASSED:" lines. Parse the timestamp and check if
  # any falls within the stall window. A PASSED within GTSW_STALL_MINUTES → OK.
  local last_passed_epoch=0
  while IFS= read -r line; do
    if echo "$line" | grep -q "Gate PASSED:"; then
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

  if [ "$last_passed_epoch" -gt 0 ] && [ $(( now - last_passed_epoch )) -le "$stall_window_sec" ] 2>/dev/null; then
    local age_min; age_min=$(( (now - last_passed_epoch) / 60 ))
    # COOLDOWN RESET: Gate PASSED recently → stall cleared; disarm so next episode re-alerts immediately
    [ -f "${COOLDOWN_FILE}" ] && { rm -f "${COOLDOWN_FILE}" 2>/dev/null || true; log "COOLDOWN RESET: Gate PASSED ${age_min}min ago — cooldown disarmed"; }
    # ga-evjs2: also clear the recover-marker so a NEW episode starts recover-first (no stale escalation)
    [ -f "${RECOVER_MARKER_FILE}" ] && { rm -f "${RECOVER_MARKER_FILE}" 2>/dev/null || true; log "RECOVER-MARKER RESET: Gate PASSED ${age_min}min ago — next episode recovers before paging Athos"; }
    log "OK: Gate PASSED ${age_min}min ago (within ${GTSW_STALL_MINUTES}min window) — not a stall"
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
  GATE_STALL_COOLDOWN_S=7200

  # Stub notify and gc so they record calls but have no side effects
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$GTSW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$TMP/notify"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$GTSW_TEST_MAILED" 2>/dev/null; [ "$1" = "session" ] && echo "${GTSW_TEST_SESSIONS:-}" ; exit 0\n' > "$TMP/gc"
  chmod +x "$TMP/notify" "$TMP/gc"

  # Helper: generate realistic gate log lines with a given queue count and
  # optionally a "Gate PASSED" line at a given age in seconds.
  make_log() {
    local queue_n="$1" passed_age_sec="${2:-}"
    local now; now="$(date +%s)"
    # Queued-markers line (always present if queue_n > 0)
    if [ "$queue_n" -gt 0 ]; then
      local ts_q; ts_q="$(date -u -r $((now - 60)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$((now - 60))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u '+%Y-%m-%d %H:%M:%S')"
      echo "[${ts_q}] [quality-gate-dispatcher] Found ${queue_n} queued marker(s)"
    fi
    # Gate PASSED line (if requested)
    if [ -n "$passed_age_sec" ] && [ "$passed_age_sec" -gt 0 ]; then
      local ts_p; ts_p="$(date -u -r $((now - passed_age_sec)) '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "@$((now - passed_age_sec))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
      if [ -n "$ts_p" ]; then
        echo "[${ts_p}] [quality-gate-dispatcher] Gate PASSED: branch=crew/test/ga-test tier=CODE merge_sha=abc123 elapsed=300s"
      fi
    fi
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
  GTSW_TEST_LOG_LINES="$(make_log 5)"
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
  echo "Scenario 2: empty queue (0 queued markers) → NOT a stall"
  NOTIF2="$TMP/notif2"; : > "$NOTIF2"
  GTSW_TEST_LOG_LINES="$(make_log 0)"    # no queued-markers line at all
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF2"
  GTSW_TEST_MAILED="$TMP/mail2"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 2: empty queue returns 0 (no alert)" || bad "scenario 2: empty queue falsely alerted"
  [ ! -s "$NOTIF2" ] && ok "scenario 2: no notify on empty queue" || bad "scenario 2: notify fired on empty queue (false positive)"

  # ── Scenario 3: QUOTA-LIMITED (B1: log pattern) → suppress ───────────────
  echo "Scenario 3: quota-limited via log pattern (B1) → suppressed"
  NOTIF3="$TMP/notif3"; : > "$NOTIF3"
  _sc3_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
  GTSW_TEST_LOG_LINES="[${_sc3_now}] [quality-gate-dispatcher] Found 8 queued marker(s)
[${_sc3_now}] [quality-gate-dispatcher] Headroom DEFER: gate em 0 runs (Dolt cpu=200% lat=100ms / cota=LIMITED) — quota-limited; ceiling=0 reviewers, leaving 8 marker(s) queued (ga-cw4pm)."
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
  _sc4_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
  GTSW_TEST_LOG_LINES="[${_sc4_now}] [quality-gate-dispatcher] Found 5 queued marker(s)"
  GTSW_TEST_QUOTA_RC=2   # B2: quota check returns LIMITED
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF4"
  GTSW_TEST_MAILED="$TMP/mail4"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 4: quota-limited (B2) suppresses alert (return 0)" || bad "scenario 4: quota-limited B2 did NOT suppress (false positive)"
  [ ! -s "$NOTIF4" ] && ok "scenario 4: no notify when quota exit=2" || bad "scenario 4: notify fired despite quota exit=2 (false positive)"

  # ── Scenario 5: RECENT PROGRESS → no alert ───────────────────────────────
  echo "Scenario 5: Gate PASSED within the stall window → NOT a stall"
  NOTIF5="$TMP/notif5"; : > "$NOTIF5"
  # Gate PASSED 30 minutes ago (well within the 2h window)
  GTSW_TEST_LOG_LINES="$(make_log 3 1800)"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  GTSW_TEST_NOTIFIED="$NOTIF5"
  GTSW_TEST_MAILED="$TMP/mail5"
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 5: recent Gate PASSED suppresses alert (return 0)" || bad "scenario 5: recent Gate PASSED did NOT suppress (false positive)"
  [ ! -s "$NOTIF5" ] && ok "scenario 5: no notify when Gate PASSED recently" || bad "scenario 5: notify fired despite recent Gate PASSED (false positive)"

  # ── Scenario 6: ACTIVE REVIEWER → no alert ───────────────────────────────
  echo "Scenario 6: active gate-reviewer session → NOT a stall"
  NOTIF6="$TMP/notif6"; : > "$NOTIF6"
  GTSW_TEST_LOG_LINES="$(make_log 4)"
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
  GTSW_TEST_LOG_LINES="$(make_log 6)"
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
  GTSW_TEST_LOG_LINES="$(make_log 10)"
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
  GTSW_TEST_LOG_LINES="$(make_log 3)"
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
  GTSW_TEST_LOG_LINES="$(make_log 5)"
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
  # Stall CLEARS via empty queue (Guard A should delete the cooldown file).
  # make_log 0 produces empty output which hits fail-open before Guard A; use a
  # non-empty log line with 0 queued markers so Guard A path actually executes.
  _sc12_now="$(date -u '+%Y-%m-%d %H:%M:%S')"
  GTSW_TEST_LOG_LINES="[${_sc12_now}] [quality-gate-dispatcher] Found 0 queued marker(s) — gate idle"
  GTSW_TEST_QUOTA_RC=0
  GTSW_TEST_SESSIONS=""
  unset GTSW_TEST_KICKSTARTS
  run_sweep && ok "scenario 12a: stall-clear (empty queue) returns 0" || bad "scenario 12a: stall-clear should return 0"
  [ ! -f "$TMP/cooldown" ] && ok "scenario 12a: cooldown file deleted on stall-clear (Guard A)" || bad "scenario 12a: cooldown file NOT deleted on stall-clear"
  # Fresh stall after clear — cooldown was reset, alert should fire again immediately
  NOTIF12b="$TMP/notif12b"; : > "$NOTIF12b"
  KICKS12b="$TMP/kicks12b"; : > "$KICKS12b"
  GTSW_TEST_LOG_LINES="$(make_log 3)"
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

  # ── CLEANUP / SUMMARY ─────────────────────────────────────────────────────
  # Unset test seams so no state leaks
  unset GTSW_TEST_LOG_LINES GTSW_TEST_QUOTA_RC GTSW_TEST_SESSIONS
  unset GTSW_TEST_KICKSTARTS GTSW_TEST_NOTIFIED GTSW_TEST_MAILED

  echo ""
  echo "gate-throughput-stall-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; stall result already sent via notify+mail

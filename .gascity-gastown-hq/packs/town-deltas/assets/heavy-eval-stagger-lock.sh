#!/usr/bin/env bash
# heavy-eval-stagger-lock.sh (ga-m2gqb) — serialize + backpressure-gate the
# city's 3 heavy weekly eval jobs (lexbh, WhatsApp eval-sampler, quality-gate-eval).
#
# WHY: 2026-07-27 these 3 launchd jobs converged (lexbh's eval_answers.py alone
# is 1.35GB RAM) with concurrent agent-pool load and drove the mini into 13
# jetsam kills / a hard reboot (ga-7xne1, this bead's parent). Two independent
# fixes, both applied by THIS wrapper so neither eval script needs to know
# about the other or about RAM pressure:
#
#   1. STAGGER: a single shared mkdir-based lock (LOCKDIR) so at most ONE of
#      the 3 jobs runs at a time — the others WAIT their turn (AC: "no máximo
#      uma roda por vez, as outras esperam a vez"), never skip on lock contention
#      alone. quality-gate-eval uses StartInterval (not StartCalendarInterval
#      like the other two), so its fire time DRIFTS relative to wall-clock —
#      calendar offsetting alone cannot guarantee separation; the lock is the
#      only mechanism that holds regardless of drift.
#   2. BACKPRESSURE: before even trying for the lock, consult
#      ram-pressure-monitor.sh's durable level file (same contract
#      pilot-dispatcher.sh's _pilot_ram_pressure_blocks reads) — WARN or
#      EMERGENCY defers starting a NEW heavy eval, same as it defers a new
#      agent-pool spawn (AC: "aviso ou emergência" get the identical response).
#      Never redefines what counts as pressure — reads the monitor's own
#      already-computed level verbatim.
#
# NEVER interrupts work already running (AC) — this wrapper only gates the
# START of a NEW invocation; the lock is held for the wrapped command's FULL
# duration (not just at start, so a genuine "wait your turn" — not two heavy
# evals running concurrently just because the second one merely delayed ITS
# OWN start).
#
# Usage: heavy-eval-stagger-lock.sh <real-command> [args...]
# Exit codes: the wrapped command's own exit code on success; 75 (EX_TEMPFAIL)
# if HESL_MAX_WAIT_SECS was exceeded without ever starting the real command
# (deliberately skipped this cycle — the job's own next scheduled fire
# retries); 64 (EX_USAGE) if invoked with no command.
#
# TEST (no real multi-hour waits, no lock contention with production, NOTIFY
# disabled, hermetic paths):
#   bash heavy-eval-stagger-lock.sh --selftest
# Library mode: `HEAVY_EVAL_STAGGER_LOCK_LIB=1 source heavy-eval-stagger-lock.sh`
# defines the pure decision functions WITHOUT running the wrapper flow.
set -uo pipefail

NOTIFY="${HESL_NOTIFY:-${HOME}/.local/bin/notify}"
LOG="${HESL_LOG:-${HOME}/.gastown/logs/heavy-eval-stagger-lock.log}"
ts_now() { date '+%Y-%m-%d %H:%M:%S'; }
log() {
  mkdir -p "$(dirname "${LOG}")" 2>/dev/null
  echo "[$(ts_now)] [heavy-eval-stagger-lock] $*" >> "${LOG}" 2>/dev/null
  echo "[$(ts_now)] [heavy-eval-stagger-lock] $*"
}

LOCKDIR="${HESL_LOCKDIR:-${HOME}/.gastown/run/.heavy-eval-stagger.lock.d}"
# 6h stale-reclaim bound: generous vs. a legitimately long heavy eval (crash
# recovery only, mirrors ram-pressure-monitor.sh's own LOCK_STALE_MIN pattern
# — this is a defensive floor, not a response to an observed collision).
LOCK_STALE_MIN="${HESL_LOCK_STALE_MIN:-360}"

RAM_LEVEL_FILE="${HESL_RAM_LEVEL_FILE:-${HOME}/.gastown/run/ram-pressure-monitor.level}"
RAM_MAX_AGE_SECS="${HESL_RAM_MAX_AGE_SECS:-7200}"   # mirrors PILOT_RAM_MAX_AGE_SECS (pilot-dispatcher.sh)

MAX_WAIT_SECS="${HESL_MAX_WAIT_SECS:-14400}"   # 4h bound; giving up skips this cycle, next scheduled fire retries
POLL_SECS="${HESL_POLL_SECS:-60}"
LOG_EVERY_SECS="${HESL_LOG_EVERY_SECS:-300}"   # rate-limit "still waiting" lines to every 5min, not every poll

# Test-only seams (selftest / library use — never set in prod):
HESL_TEST_RAM_LEVEL="${HESL_TEST_RAM_LEVEL:-}"
HESL_TEST_RAM_AGE_SECS="${HESL_TEST_RAM_AGE_SECS:-}"

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by --selftest. No side effects other
# than the read-only file/mtime probes documented per-function.
# ════════════════════════════════════════════════════════════════════════════

# _ram_pressure_blocks → return 0 (true/block) iff the monitor's durable level
# file reads WARN/EMERGENCY and is fresh; return 1 (false/proceed) otherwise.
# FAIL-OPEN on every unreadable path — same rationale as pilot-dispatcher.sh's
# _pilot_ram_pressure_blocks: a missing/stale file usually means the monitor
# hasn't run, not that the machine is under pressure. Never redefines what
# counts as pressure — reads the monitor's own already-computed level verbatim.
_ram_pressure_blocks() {
  local level ts now
  if [ -n "${HESL_TEST_RAM_LEVEL}" ]; then
    level="${HESL_TEST_RAM_LEVEL}"
    ts=$(( $(date +%s) - ${HESL_TEST_RAM_AGE_SECS:-0} ))
  else
    [ -f "${RAM_LEVEL_FILE}" ] || return 1
    level="$(sed -n '1p' "${RAM_LEVEL_FILE}" 2>/dev/null | tr -d '[:space:]')"
    ts="$(sed -n '2p' "${RAM_LEVEL_FILE}" 2>/dev/null | tr -d '[:space:]')"
  fi
  case "${ts}" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $(( now - ts )) -gt "${RAM_MAX_AGE_SECS}" ] && return 1
  case "${level}" in WARN|EMERGENCY) return 0 ;; *) return 1 ;; esac
}

# _ram_pressure_unreadable → return 0 (true) iff the signal is missing/stale/
# corrupt (the fail-open path — this wrapper proceeds either way), return 1
# iff a genuine OK/WARN/EMERGENCY reading was read. Exists purely so the
# caller can LOG "couldn't tell, proceeding anyway" distinctly from
# "confirmed clear, proceeding" — a silent fail-open on a path that starts
# real work is the exact shape the third-state self-audit flags, even though
# the DEFAULT (proceed) is the correct decision. Duplicated from
# _ram_pressure_blocks's own reads rather than shared, matching this file's
# self-contained-pure-function convention.
_ram_pressure_unreadable() {
  [ -n "${HESL_TEST_RAM_LEVEL}" ] && return 1
  [ -f "${RAM_LEVEL_FILE}" ] || return 0
  local ts now
  ts="$(sed -n '2p' "${RAM_LEVEL_FILE}" 2>/dev/null | tr -d '[:space:]')"
  case "${ts}" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  [ $(( now - ts )) -gt "${RAM_MAX_AGE_SECS}" ] && return 0
  return 1
}

# _lock_is_stale <lockdir> <stale_min> → return 0 (true) iff lockdir exists and
# its mtime is older than stale_min minutes (crash-recovery reclaim only).
_lock_is_stale() {
  local dir="$1" stale_min="$2"
  [ -n "$(find "${dir}" -maxdepth 0 -mmin "+${stale_min}" 2>/dev/null)" ]
}

# _deadline_exceeded <start_epoch> <now_epoch> <max_wait_secs> → return 0
# (true) once the wait bound has elapsed (inclusive: >=).
_deadline_exceeded() {
  local start="$1" now="$2" max="$3"
  [ $(( now - start )) -ge "${max}" ]
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting) — the mkdir/rmdir mutate real lock state; the
# selftest exercises these against a hermetic HESL_LOCKDIR, never production's.
# ════════════════════════════════════════════════════════════════════════════

# _try_acquire_lock → return 0 on success (LOCKDIR now exists and is ours),
# return 1 if another live holder has it. Reclaims a STALE lock (crash
# recovery) rather than waiting out a dead holder forever.
_try_acquire_lock() {
  mkdir -p "$(dirname "${LOCKDIR}")" 2>/dev/null || true
  if mkdir "${LOCKDIR}" 2>/dev/null; then
    return 0
  fi
  if _lock_is_stale "${LOCKDIR}" "${LOCK_STALE_MIN}"; then
    log "reclaiming stale lock (> ${LOCK_STALE_MIN}min — likely a crashed prior run): ${LOCKDIR}"
    rmdir "${LOCKDIR}" 2>/dev/null && mkdir "${LOCKDIR}" 2>/dev/null && return 0
  fi
  return 1
}

main() {
  [ "$#" -ge 1 ] || { log "ERROR: no command given (usage: heavy-eval-stagger-lock.sh <cmd> [args...])"; exit 64; }
  local cmd_desc="$*"
  # Re-check the env vars fresh (not the script-top-level globals, which were
  # resolved ONCE at load time) so a per-call override — an env-prefixed call
  # to main(), as the selftest below uses for fast bounds — actually takes
  # effect. Normal single-invocation production use is unaffected either way
  # (the script loads fresh per launchd invocation).
  local max_wait="${HESL_MAX_WAIT_SECS:-${MAX_WAIT_SECS}}"
  local poll_secs="${HESL_POLL_SECS:-${POLL_SECS}}"
  local log_every="${HESL_LOG_EVERY_SECS:-${LOG_EVERY_SECS}}"

  local start_epoch; start_epoch=$(date +%s)
  local last_log_epoch=0
  while true; do
    local now; now=$(date +%s)
    if _deadline_exceeded "${start_epoch}" "${now}" "${max_wait}"; then
      log "GAVE UP after $(( now - start_epoch ))s (bound=${max_wait}s) waiting for lock+clear-pressure — SKIPPING this cycle: ${cmd_desc}. Next scheduled fire will retry."
      "${NOTIFY}" -t "Heavy-eval stagger: skipped" -p 3 "Pulou este ciclo (esperou ${max_wait}s sem conseguir vaga/pressão OK): ${cmd_desc}" 2>/dev/null || true
      exit 75
    fi

    local blocked_reason=""
    if _ram_pressure_blocks; then
      blocked_reason="RAM pressure"
    elif ! _try_acquire_lock; then
      blocked_reason="another heavy eval is running"
    fi

    if [ -z "${blocked_reason}" ]; then
      break
    fi
    if [ $(( now - last_log_epoch )) -ge "${log_every}" ]; then
      log "waiting ($(( now - start_epoch ))s so far, bound=${max_wait}s) — blocked on: ${blocked_reason}"
      last_log_epoch="${now}"
    fi
    sleep "${poll_secs}"
  done

  # Lock held for the FULL run (trap fires on normal exit, Ctrl-C, or TERM) —
  # this is what makes "at most one runs at a time" true for the whole
  # duration, not just at start.
  trap 'rmdir "${LOCKDIR}" 2>/dev/null || true' EXIT INT TERM
  if _ram_pressure_unreadable; then
    log "RAM-pressure signal UNREADABLE (missing/stale/corrupt ${RAM_LEVEL_FILE}) — fail-open, proceeding anyway (ga-m2gqb)."
  fi
  log "acquired lock after $(( $(date +%s) - start_epoch ))s wait — starting: ${cmd_desc}"
  local run_start; run_start=$(date +%s)
  "$@"
  local rc=$?
  log "finished after $(( $(date +%s) - run_start ))s, exit=${rc}: ${cmd_desc}"
  exit "${rc}"
}

# ── selftest (hermetic; no real waits beyond seconds, NOTIFY disabled) ────────
if [ "${1:-}" = "--selftest" ]; then
  PASS=0; FAIL=0; ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }; bad(){ FAIL=$((FAIL+1)); echo "  ✗ $1"; }
  export HESL_NOTIFY=/nonexistent
  _ST_LOG="$(mktemp /tmp/hesl-selftest-log.XXXXXX)"
  _ST_LOCKROOT="$(mktemp -d /tmp/hesl-selftest-lock.XXXXXX)"
  _ST_LOCKDIR="${_ST_LOCKROOT}/lock.d"
  _ST_RAMFILE="$(mktemp /tmp/hesl-selftest-ram.XXXXXX)"
  rm -f "${_ST_RAMFILE}"   # start absent — most scenarios want "file doesn't exist yet"
  export HESL_LOG="${_ST_LOG}" HESL_LOCKDIR="${_ST_LOCKDIR}" HESL_RAM_LEVEL_FILE="${_ST_RAMFILE}"
  trap 'rm -rf "${_ST_LOG}" "${_ST_LOCKROOT}" "${_ST_RAMFILE}"' EXIT
  # Re-read the (now-exported) config so the functions below see the hermetic paths.
  LOG="${HESL_LOG}"; LOCKDIR="${HESL_LOCKDIR}"; RAM_LEVEL_FILE="${HESL_RAM_LEVEL_FILE}"

  echo "S1: _ram_pressure_blocks — pure decision function"
  HESL_TEST_RAM_LEVEL=OK        HESL_TEST_RAM_AGE_SECS=0 _ram_pressure_blocks && bad "level=OK should not block" || ok "level=OK → does not block"
  HESL_TEST_RAM_LEVEL=WARN      HESL_TEST_RAM_AGE_SECS=0 _ram_pressure_blocks && ok "level=WARN → blocks" || bad "level=WARN should block"
  HESL_TEST_RAM_LEVEL=EMERGENCY HESL_TEST_RAM_AGE_SECS=0 _ram_pressure_blocks && ok "level=EMERGENCY → blocks" || bad "level=EMERGENCY should block"
  HESL_TEST_RAM_LEVEL="" _ram_pressure_blocks && bad "missing level file should fail-open" || ok "missing level file → fail-OPEN (does not block)"
  HESL_TEST_RAM_LEVEL=WARN HESL_TEST_RAM_AGE_SECS=10000 _ram_pressure_blocks && bad "stale (10000s>7200s) WARN should fail-open" || ok "stale reading → fail-OPEN"
  printf 'WARN\nnot-a-number\n' > "${_ST_RAMFILE}"
  HESL_TEST_RAM_LEVEL="" _ram_pressure_blocks && bad "corrupt timestamp should fail-open" || ok "corrupt timestamp in real file → fail-OPEN"
  rm -f "${_ST_RAMFILE}"

  echo "S1b: _ram_pressure_unreadable — visibility for the fail-open path (self-audit: 'couldn't tell' must not look like 'confirmed clear')"
  HESL_TEST_RAM_LEVEL=OK   HESL_TEST_RAM_AGE_SECS=0 _ram_pressure_unreadable && bad "confirmed OK should not read as unreadable" || ok "confirmed OK reading → NOT unreadable"
  HESL_TEST_RAM_LEVEL=WARN HESL_TEST_RAM_AGE_SECS=0 _ram_pressure_unreadable && bad "confirmed WARN should not read as unreadable" || ok "confirmed WARN reading → NOT unreadable (blocking is orthogonal to readability)"
  HESL_TEST_RAM_LEVEL="" _ram_pressure_unreadable && ok "missing level file → unreadable (VISIBLE, not silent)" || bad "missing file should read as unreadable"
  printf 'WARN\n%s\n' "$(( $(date +%s) - 10000 ))" > "${_ST_RAMFILE}"
  HESL_TEST_RAM_LEVEL="" _ram_pressure_unreadable && ok "stale reading (10000s old) → unreadable" || bad "stale reading should read as unreadable"
  rm -f "${_ST_RAMFILE}"

  echo "S2: _lock_is_stale + _deadline_exceeded — pure arithmetic/mtime functions"
  _fresh_dir="${_ST_LOCKROOT}/fresh.d"; mkdir -p "${_fresh_dir}"
  _lock_is_stale "${_fresh_dir}" 360 && bad "freshly-created dir should not read stale" || ok "fresh lock dir → not stale"
  _stale_dir="${_ST_LOCKROOT}/stale.d"; mkdir -p "${_stale_dir}"
  touch -t "$(date -v-7H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '7 hours ago' '+%Y%m%d%H%M.%S')" "${_stale_dir}"
  _lock_is_stale "${_stale_dir}" 360 && ok "7h-old lock dir (> 360min bound) → stale" || bad "7h-old lock dir should read stale"
  rm -rf "${_fresh_dir}" "${_stale_dir}"
  _deadline_exceeded 1000 1399 400 && bad "399s elapsed < 400s max should not be exceeded" || ok "elapsed < max → not exceeded"
  _deadline_exceeded 1000 1400 400 && ok "400s elapsed == 400s max → exceeded (inclusive boundary)" || bad "elapsed == max should be exceeded"

  echo "S3: _try_acquire_lock — mkdir-based mutual exclusion + stale-reclaim"
  rm -rf "${_ST_LOCKDIR}"
  _try_acquire_lock && ok "fresh (absent) lockdir → acquired" || bad "should acquire when lockdir absent"
  [ -d "${_ST_LOCKDIR}" ] && ok "lockdir now exists on disk after acquire" || bad "lockdir missing after acquire"
  ( _try_acquire_lock ) && bad "REGRESSION: acquired an already-held, fresh lock" || ok "already-held fresh lock → acquire fails (mutual exclusion holds)"
  touch -t "$(date -v-7H '+%Y%m%d%H%M.%S' 2>/dev/null || date -d '7 hours ago' '+%Y%m%d%H%M.%S')" "${_ST_LOCKDIR}"
  ( _try_acquire_lock ) && ok "stale (7h-old) held lock → reclaimed and acquired" || bad "should reclaim a stale lock"
  rmdir "${_ST_LOCKDIR}" 2>/dev/null || true

  echo "S4: main() end-to-end — wrapped command actually runs when clear, exit code + stdout propagate"
  rm -rf "${_ST_LOCKDIR}"; rm -f "${_ST_RAMFILE}"
  _S4_OUT="$(HESL_MAX_WAIT_SECS=5 HESL_POLL_SECS=1 main bash -c 'echo ran-ok; exit 7' 2>&1)"; _s4_rc=$?
  echo "${_S4_OUT}" | grep -q "ran-ok" && ok "wrapped command's stdout reached the caller" || bad "wrapped command output missing — got: ${_S4_OUT}"
  [ "${_s4_rc}" = "7" ] && ok "wrapped command's exit code (7) propagated through the wrapper" || bad "exit code did not propagate — got ${_s4_rc}, expected 7"
  [ -d "${_ST_LOCKDIR}" ] && bad "lock still held after the wrapped command finished (leak)" || ok "lock released after the wrapped command finished"

  echo "S5: main() end-to-end — RAM pressure defers, wrapped command NEVER runs, exit=75"
  rm -rf "${_ST_LOCKDIR}"
  _S5_MARKER="$(mktemp -u /tmp/hesl-selftest-marker.XXXXXX)"
  rm -f "${_S5_MARKER}"
  ( HESL_MAX_WAIT_SECS=2 HESL_POLL_SECS=1 HESL_TEST_RAM_LEVEL=EMERGENCY HESL_TEST_RAM_AGE_SECS=0 \
    main bash -c "touch '${_S5_MARKER}'" ) >/dev/null 2>&1
  _s5_rc=$?
  [ "${_s5_rc}" = "75" ] && ok "gives up with EX_TEMPFAIL (75) under sustained RAM pressure" || bad "wrong exit code under RAM pressure — got ${_s5_rc}, expected 75"
  [ -f "${_S5_MARKER}" ] && bad "REGRESSION: wrapped command ran despite RAM pressure never clearing" || ok "wrapped command never started while RAM pressure was signaled (AC: nenhuma avaliação nova começa)"

  echo "S6: main() end-to-end — lock pre-held by 'another job' → this invocation waits, gives up, and does NOT touch the other holder's lock"
  rm -rf "${_ST_LOCKDIR}"; mkdir -p "${_ST_LOCKDIR}"   # simulate a live sibling holding the lock
  _S6_MARKER="$(mktemp -u /tmp/hesl-selftest-marker6.XXXXXX)"
  rm -f "${_S6_MARKER}"
  ( HESL_MAX_WAIT_SECS=2 HESL_POLL_SECS=1 main bash -c "touch '${_S6_MARKER}'" ) >/dev/null 2>&1
  _s6_rc=$?
  [ "${_s6_rc}" = "75" ] && ok "gives up with EX_TEMPFAIL (75) when the lock stays held by a live sibling" || bad "wrong exit code under lock contention — got ${_s6_rc}, expected 75"
  [ -f "${_S6_MARKER}" ] && bad "REGRESSION: wrapped command ran while another heavy eval held the lock (AC: no máximo uma roda por vez)" || ok "wrapped command never started while the lock was held (AC honored)"
  [ -d "${_ST_LOCKDIR}" ] && ok "the OTHER holder's lock is left intact (this invocation never released a lock it didn't acquire)" || bad "REGRESSION: this invocation released a lock it never held — would break the sibling's mutual exclusion"
  rmdir "${_ST_LOCKDIR}" 2>/dev/null || true

  echo ""; echo "heavy-eval-stagger-lock selftest: PASS=$PASS FAIL=$FAIL"; [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

if [ "${HEAVY_EVAL_STAGGER_LOCK_LIB:-0}" != "1" ]; then
  main "$@"
fi

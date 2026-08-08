#!/bin/bash
#
# ga-d81-hotpath-restart.sh
# ---------------------------------------------------------------------------
# GUARDED, one-at-a-time restart of the 4 long-lived WhatsApp hot-path daemons
# so they pick up already-merged story ga-d81 code (origin/main + rig HEAD
# a87f047f). These daemons handle REAL WhatsApp messaging, so this script is
# built to run in a low-traffic window (~04:07 local) with care:
#   - least-sensitive -> most-sensitive order
#   - best-effort drain (quiesce check), no risky custom drain logic
#   - launchctl kickstart -k (all 4 are KeepAlive -> they respawn)
#   - per-daemon health verification (new start time + alive + health/port)
#   - STOP the whole sequence + emergency notify on any failure (never bounce
#     central_sender if an earlier daemon is unhealthy)
#   - idempotent-ish: a sentinel makes a successful run a no-op afterwards
#
# Modes:
#   --dry-run   Resolve labels, validate sequence, log what it WOULD do.
#               Does NOT kickstart anything.
#   (no flag)   Real guarded restart.
#
# Self-disable: after a successful real run, writes a sentinel AND boots out
# its own launchd schedule job so it will not re-fire on later days.
# ---------------------------------------------------------------------------

set -uo pipefail

# ------------------------- constants / paths -------------------------------
WA_BASE="/Users/athos/gt/whatsapp_automation"
LOG_DIR="/Users/athos/gt/.gascity-gastown-hq/logs"
LOGFILE="$LOG_DIR/ga-d81-hotpath-restart.log"
SENTINEL="$LOG_DIR/ga-d81-hotpath-restart.done"
SCHED_LABEL="com.gascity.ga-d81-hotpath-restart"
NOTIFY="/Users/athos/.local/bin/notify"

# ga-d81 merge commit (rig HEAD). Daemons started before this commit's time
# are stale. The real check is "process start time AFTER the kickstart", but
# we also record this for the log.
GA_D81_SHA="a87f047f96d370065373e667c47dd3f52e7e0b60"

# Per-daemon recovery wait budget (seconds) and drain budget (seconds).
RECOVER_WAIT=20
DRAIN_WAIT=6

DRY_RUN=0
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1

mkdir -p "$LOG_DIR"

# ------------------------- daemon table ------------------------------------
# Restart order: least-sensitive -> most-sensitive.
#   1. conversation-monitor  (monitor)        -> no port, log-based health
#   2. slot-scheduler        (scheduling)     -> no port, log-based health
#   3. webhook-receiver      (live inbound)   -> HTTP /health on :5555
#   4. central-sender        (live SEND)      -> no port, log-based health  [MOST SENSITIVE]
ORDER=(conversation-monitor slot-scheduler webhook-receiver central-sender)

label_for()  { echo "com.whatsapp.$1"; }
script_for() { # python entrypoint, for log/identity only
  case "$1" in
    conversation-monitor) echo "$WA_BASE/daemons/conversation_monitor.py" ;;
    slot-scheduler)       echo "$WA_BASE/daemons/slot_scheduler.py" ;;
    webhook-receiver)     echo "$WA_BASE/daemons/webhook_receiver.py" ;;
    central-sender)       echo "$WA_BASE/daemons/central_sender.py" ;;
  esac
}
stdoutlog_for() {
  case "$1" in
    conversation-monitor) echo "$WA_BASE/logs/conversation_monitor_stdout.log" ;;
    slot-scheduler)       echo "$WA_BASE/logs/slot_scheduler_stdout.log" ;;
    webhook-receiver)     echo "$WA_BASE/logs/webhook_receiver_stdout.log" ;;
    central-sender)       echo "$WA_BASE/logs/central_sender_stdout.log" ;;
  esac
}
stderrlog_for() {
  case "$1" in
    conversation-monitor) echo "$WA_BASE/logs/conversation_monitor_stderr.log" ;;
    slot-scheduler)       echo "$WA_BASE/logs/slot_scheduler_stderr.log" ;;
    webhook-receiver)     echo "$WA_BASE/logs/webhook_receiver_stderr.log" ;;
    central-sender)       echo "$WA_BASE/logs/central_sender_stderr.log" ;;
  esac
}
# Health: for webhook-receiver we have a real HTTP endpoint. Others are
# worker daemons with no listening socket -> health = alive + new start time.
healthport_for() {
  case "$1" in
    webhook-receiver) echo "5555" ;;
    *)                echo "" ;;
  esac
}

# ------------------------- helpers -----------------------------------------
log() {
  local line="[$(date '+%Y-%m-%d %H:%M:%S %z')] $*"
  echo "$line" | tee -a "$LOGFILE"
}

notify_fail() {
  local msg="$1"
  log "EMERGENCY: $msg"
  if [[ -x "$NOTIFY" ]]; then
    "$NOTIFY" -p 5 -t "ga-d81 hot-path FAILED" "🚨 $msg" >/dev/null 2>&1 || true
  fi
}

notify_ok() {
  local msg="$1"
  log "SUCCESS: $msg"
  if [[ -x "$NOTIFY" ]]; then
    "$NOTIFY" "$msg" >/dev/null 2>&1 || true
  fi
}

# launchd PID for a label ("-" or empty => not running)
pid_of() {
  local label="$1" pid
  pid=$(launchctl list "$label" 2>/dev/null | awk -F'= ' '/"PID"/ {gsub(/[;]/,"",$2); print $2}')
  [[ -n "$pid" && "$pid" != "-" ]] && echo "$pid" || echo ""
}

# epoch start time of a pid (0 if not found)
start_epoch_of() {
  local pid="$1"
  [[ -z "$pid" ]] && { echo 0; return; }
  # macOS ps lstart -> parse to epoch
  local lstart
  lstart=$(ps -o lstart= -p "$pid" 2>/dev/null)
  [[ -z "$lstart" ]] && { echo 0; return; }
  date -j -f "%a %b %d %T %Y" "$lstart" "+%s" 2>/dev/null || echo 0
}

# best-effort drain: if stdout log was written within the last DRAIN_WAIT
# seconds, treat as "recent activity / possibly in-flight" and wait (capped)
# for it to quiesce. No invented risky drain logic.
drain() {
  local d="$1" slog now mtime age waited=0
  slog=$(stdoutlog_for "$d")
  [[ ! -f "$slog" ]] && { log "  drain($d): no stdout log to observe -> proceed"; return; }
  while (( waited < DRAIN_WAIT )); do
    now=$(date +%s)
    # ga-qb6yg self-review before resubmission: a stat failure on a log file we
    # just confirmed exists (transient race, not "file doesn't exist") used to
    # collapse to mtime=0 -> age=huge -> immediate "quiescent, proceed", the
    # same outcome as a genuinely idle log. Treat "couldn't read mtime" as
    # possibly-still-active instead, so it falls through to the bounded wait
    # loop below rather than skipping the drain entirely.
    if ! mtime=$(stat -f %m "$slog" 2>/dev/null); then
      log "  drain($d): couldn't stat log (transient?) — treating as still-active, waiting 1s (waited ${waited}s/${DRAIN_WAIT}s)"
      sleep 1
      waited=$(( waited + 1 ))
      continue
    fi
    age=$(( now - mtime ))
    if (( age >= 3 )); then
      log "  drain($d): quiescent (log idle ${age}s) -> proceed"
      return
    fi
    log "  drain($d): recent activity (log ${age}s old), waiting 1s (waited ${waited}s/${DRAIN_WAIT}s)"
    sleep 1
    waited=$(( waited + 1 ))
  done
  log "  drain($d): drain budget (${DRAIN_WAIT}s) reached -> proceed (low-traffic window is the mitigation)"
}

# A stderr line is a REAL fatal only if it matches a hard-failure pattern AND
# is not a known-benign macOS/Python noise line. The canonical false-positive
# here is the macOS malloc-stack-logging warning that Python emits to stderr
# under certain malloc env settings; it is NOT a failure:
#   "Python(NNNN) MallocStackLogging: can't turn off malloc stack logging ..."
# Python's logging subsystem also prints bare "--- Logging error ---" banners
# that are noise, not a daemon crash. We strip those before testing for fatals.
stderr_has_real_fatal() {
  local d="$1" raw filtered
  # ga-qb6yg self-review before resubmission: a tail failure (log rotated /
  # briefly unreadable right after kickstart) used to `return 1` — the exact
  # same code as "read 40 lines, found no fatal" — which verify_healthy()
  # treats as license to declare the daemon healthy for worker daemons with no
  # HTTP port. "Couldn't check" must not look like "checked, clean": return 0
  # (possible-fatal) so the caller keeps waiting/retries instead of confirming
  # health off a check that never actually ran.
  raw=$(tail -n 40 "$(stderrlog_for "$d")" 2>/dev/null) || return 0
  # Drop known-benign lines so they can never trip the fatal detector.
  filtered=$(printf '%s\n' "$raw" \
    | grep -viE 'MallocStackLogging' \
    | grep -vE '^-+ Logging error -+$')
  # A real fatal: an actual Python traceback, an explicit FATAL, a bind clash,
  # or an OSError code. (Anchored to reduce accidental matches on log text.)
  printf '%s\n' "$filtered" | grep -qE 'Traceback \(most recent call last\)|^[A-Za-z_]+Error:|\bFATAL\b|Address already in use|OSError|\[Errno [0-9]+\]'
}

# health check for a daemon AFTER kickstart. Returns 0 healthy, 1 unhealthy.
#
# Freshness signal (the daemon was genuinely swapped):
#   PRIMARY:   launchd PID differs from the pre-restart PID (definitive proof
#              the process was replaced).
#   FALLBACK:  if launchd happens to reissue the SAME PID, accept a start time
#              at or after the kickstart instant. We use ">= ks_epoch - 2" (not
#              strict ">") because `ps lstart` has 1-second resolution and the
#              new process almost always starts in the SAME wall-clock second
#              that ks_epoch was sampled — a strict ">" then ties forever and
#              reports a perfectly-healthy restart as UNHEALTHY. (This off-by-
#              one-second tie is exactly what made the 04:07 run false-fail.)
#
# Health signal: process alive; HTTP /health=200 if it has a port; for worker
# daemons (no port) alive + fresh + no REAL fatal in stderr (benign
# MallocStackLogging / "--- Logging error ---" noise is ignored).
verify_healthy() {
  local d="$1" ks_epoch="$2" pre_pid="${3:-}" label port waited=0 pid sepoch fresh
  label=$(label_for "$d")
  port=$(healthport_for "$d")
  while (( waited < RECOVER_WAIT )); do
    pid=$(pid_of "$label")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      sepoch=$(start_epoch_of "$pid")
      # genuinely-swapped if PID changed, OR (same/unknown pid) start time is
      # at/after the kickstart instant within ps's 1s resolution.
      fresh=0
      if [[ -n "$pre_pid" && "$pid" != "$pre_pid" ]]; then
        fresh=1
      elif (( sepoch >= ks_epoch - 2 )); then
        fresh=1
      fi
      if (( fresh == 1 )); then
        if [[ -n "$port" ]]; then
          if curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null | grep -q '^200$'; then
            log "  health($d): OK pid=$pid (was ${pre_pid:-none}) started=$(date -r "$sepoch" '+%H:%M:%S') /health=200 (after ${waited}s)"
            return 0
          fi
        else
          # worker daemon: alive + fresh start is our health signal; also
          # make sure stderr didn't just record a REAL fatal post-ks (benign
          # MallocStackLogging / logging-error noise is filtered out).
          if stderr_has_real_fatal "$d"; then
            : # keep waiting; could be a transient line from the old process
          else
            log "  health($d): OK pid=$pid (was ${pre_pid:-none}) started=$(date -r "$sepoch" '+%H:%M:%S') (worker, alive+fresh, after ${waited}s)"
            return 0
          fi
        fi
      fi
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
  log "  health($d): UNHEALTHY after ${RECOVER_WAIT}s (pid='${pid:-none}', pre_pid='${pre_pid:-none}')"
  return 1
}

# restart one daemon end-to-end. Returns 0 ok, 1 failed.
restart_one() {
  local d="$1" label pre_pid pre_epoch ks_epoch
  label=$(label_for "$d")
  pre_pid=$(pid_of "$label")
  pre_epoch=$(start_epoch_of "$pre_pid")
  log "--- $d ($label): pre-restart pid=${pre_pid:-none} started=$( [[ "$pre_epoch" -gt 0 ]] && date -r "$pre_epoch" '+%Y-%m-%d %H:%M:%S' || echo unknown )"

  if [[ -z "$pre_pid" ]]; then
    log "  WARN($d): not currently running per launchd; will still kickstart to (re)launch"
  fi

  drain "$d"

  ks_epoch=$(date +%s)
  if [[ "$DRY_RUN" == "1" ]]; then
    log "  DRY-RUN($d): WOULD run: launchctl kickstart -k gui/$(id -u)/$label"
    log "  DRY-RUN($d): WOULD then verify recovery within ${RECOVER_WAIT}s (health=$( [[ -n "$(healthport_for "$d")" ]] && echo "HTTP :$(healthport_for "$d")/health" || echo "alive+fresh-start" ))"
    return 0
  fi

  log "  $d: launchctl kickstart -k gui/$(id -u)/$label"
  if ! launchctl kickstart -k "gui/$(id -u)/$label" 2>>"$LOGFILE"; then
    log "  ERROR($d): kickstart command returned non-zero"
    return 1
  fi
  # give launchd a moment to swap the process before verifying
  sleep 2

  if verify_healthy "$d" "$ks_epoch" "$pre_pid"; then
    return 0
  fi
  return 1
}

self_disable() {
  # idempotency sentinel
  date '+%Y-%m-%d %H:%M:%S %z' > "$SENTINEL"
  log "self-disable: wrote sentinel $SENTINEL"
  # boot out the schedule job so it never re-fires on later days
  if launchctl list "$SCHED_LABEL" >/dev/null 2>&1; then
    if launchctl bootout "gui/$(id -u)/$SCHED_LABEL" 2>>"$LOGFILE"; then
      log "self-disable: booted out $SCHED_LABEL"
    else
      log "self-disable: bootout of $SCHED_LABEL failed (sentinel still guards re-run)"
    fi
  else
    log "self-disable: $SCHED_LABEL not loaded (nothing to bootout); sentinel guards re-run"
  fi
}

# best-effort, NON-FATAL bead label flip (Dolt may be down; we never block on it)
flip_bead_label() {
  if command -v bd >/dev/null 2>&1; then
    if bd label add ga-d81 hot-path-verified >/dev/null 2>&1 \
       || bd update ga-d81 --add-label hot-path-verified >/dev/null 2>&1; then
      log "bead: added label hot-path-verified to ga-d81"
    else
      log "bead: could not flip ga-d81 label (best-effort; Dolt may be down) — skipping, non-fatal"
    fi
  else
    log "bead: bd not available — skipping label flip (non-fatal)"
  fi
}

# ------------------------- main --------------------------------------------
main() {
  log "=========================================================="
  log "MARKER ga-d81 hot-path restart START (mode=$( [[ "$DRY_RUN" == 1 ]] && echo DRY-RUN || echo LIVE ))"
  log "rig HEAD / ga-d81 sha: $GA_D81_SHA"

  # idempotency: if already done successfully and all 4 are fresh, no-op.
  if [[ "$DRY_RUN" != "1" && -f "$SENTINEL" ]]; then
    log "sentinel present ($SENTINEL) -> already completed; re-verifying freshness only (no kickstart)"
    local all_fresh=1
    local sentinel_epoch sentinel_epoch_unknown=0
    # ga-qb6yg self-review before resubmission: a stat failure on the
    # just-confirmed-present $SENTINEL used to collapse to epoch 0, which makes
    # `sepoch >= sentinel_epoch - 120` trivially true for any running daemon —
    # "couldn't read sentinel mtime" silently reading as "confirmed fresh",
    # the opposite of the fail-safe direction the merge_epoch check below
    # takes for the equivalent unknown case. Track it explicitly instead.
    if ! sentinel_epoch=$(stat -f %m "$SENTINEL" 2>/dev/null); then
      sentinel_epoch=0
      sentinel_epoch_unknown=1
    fi
    for d in "${ORDER[@]}"; do
      local pid sepoch
      pid=$(pid_of "$(label_for "$d")")
      sepoch=$(start_epoch_of "$pid")
      if (( sentinel_epoch_unknown )); then
        log "  reverify($d): sentinel mtime unreadable — cannot confirm freshness (pid=${pid:-none})"
        all_fresh=0
      elif (( sepoch > 0 && sepoch >= sentinel_epoch - 120 )); then
        log "  reverify($d): fresh (pid=$pid started=$(date -r "$sepoch" '+%H:%M:%S'))"
      else
        log "  reverify($d): NOT fresh (pid=${pid:-none}) — but sentinel says done; leaving untouched"
        all_fresh=0
      fi
    done
    log "MARKER ga-d81 hot-path restart END (idempotent no-op; all_fresh=$all_fresh)"
    exit 0
  fi

  # validate all labels resolve before doing anything
  log "validating daemon labels resolve..."
  local missing=0
  for d in "${ORDER[@]}"; do
    local label pid
    label=$(label_for "$d")
    pid=$(pid_of "$label")
    if launchctl list "$label" >/dev/null 2>&1; then
      log "  label OK: $label (current pid=${pid:-none}, entrypoint=$(script_for "$d"))"
    else
      log "  label MISSING: $label"
      missing=1
    fi
  done
  if (( missing == 1 )); then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "DRY-RUN: one or more labels did not resolve (see above)."
    else
      notify_fail "ga-d81 restart aborted: a daemon launchd label did not resolve. Nada foi reiniciado."
      log "MARKER ga-d81 hot-path restart END (ABORTED: label missing)"
      exit 2
    fi
  fi

  # guarded sequence, one at a time, stop on first failure
  for d in "${ORDER[@]}"; do
    if ! restart_one "$d"; then
      local label pid slog
      label=$(label_for "$d")
      pid=$(pid_of "$label")
      slog=$(stderrlog_for "$d")
      local evidence="daemon=$d label=$label pid=${pid:-none}; tail stderr: $(tail -n 3 "$slog" 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
      notify_fail "ga-d81 restart PAROU em '$d'. Daemons seguintes (incl. central_sender) NÃO foram tocados. $evidence"
      log "MARKER ga-d81 hot-path restart END (FAILED at $d; sequence stopped, remaining untouched)"
      exit 1
    fi
  done

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY-RUN complete: all 4 labels resolved, sequence valid, no kickstart performed."
    log "MARKER ga-d81 hot-path restart END (DRY-RUN OK)"
    exit 0
  fi

  # all 4 restarted healthy -> confirm all now run code newer than the merge
  log "all 4 restarted healthy; confirming fresh start times (newer than merge)..."
  # ga-ebgw9 gate-feedback: `git show` failing (unresolvable SHA, git missing from
  # launchd's minimal PATH, etc.) used to silently collapse to merge_epoch=0 via
  # `|| echo 0` — every real process start-epoch is a large positive number, so
  # `sepoch > merge_epoch` was then trivially true for EVERY daemon regardless of
  # whether the freshness comparison was ever actually performed. That let a
  # confirmed-fresh claim (flip_bead_label + notify_ok "todos saudaveis") through
  # indistinguishable from an unverified one. Fail the same way the file already
  # fails a genuine "not fresh" result (notify_fail + exit 1) instead of silently
  # treating "couldn't check" as "checked and fine".
  local merge_epoch
  if ! merge_epoch=$(cd "$WA_BASE" && git show -s --format=%ct "$GA_D81_SHA" 2>/dev/null); then
    notify_fail "ga-d81 restart: não foi possível determinar o merge_epoch de $GA_D81_SHA (git show falhou) — freshness check abortado, NÃO é possível confirmar que os daemons rodam código pós-merge. Verificar manualmente."
    log "MARKER ga-d81 hot-path restart END (FAILED — could not resolve merge_epoch for $GA_D81_SHA)"
    exit 1
  fi
  local fresh_ok=1
  for d in "${ORDER[@]}"; do
    local pid sepoch
    pid=$(pid_of "$(label_for "$d")")
    sepoch=$(start_epoch_of "$pid")
    if (( sepoch > merge_epoch )); then
      log "  fresh($d): pid=$pid started=$(date -r "$sepoch" '+%Y-%m-%d %H:%M:%S') > merge -> OK"
    else
      log "  fresh($d): pid=$pid started=$(date -r "$sepoch" '+%Y-%m-%d %H:%M:%S') NOT > merge"
      fresh_ok=0
    fi
  done
  if (( fresh_ok == 0 )); then
    notify_fail "ga-d81 restart: daemons bounced mas um start time não é mais novo que o merge. Verificar manualmente."
    log "MARKER ga-d81 hot-path restart END (FAILED freshness check)"
    exit 1
  fi

  flip_bead_label
  self_disable
  notify_ok "✨ ga-d81 100% ativa: 4 daemons do WhatsApp (conversation_monitor, slot_scheduler, webhook_receiver, central_sender) reiniciados na madrugada, um a um, todos saudáveis."
  log "MARKER ga-d81 hot-path restart END (SUCCESS, all 4 healthy & fresh)"
  exit 0
}

main "$@"

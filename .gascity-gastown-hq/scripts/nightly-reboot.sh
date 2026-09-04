#!/bin/bash
# nightly-reboot.sh — recurring nightly reboot to reclaim the macOS swap
# ratchet that never releases on its own (ga-i9q44).
#
# ⚠️ STATUS (updated 2026-09-04, ga-g5bzf): INSTALLED AND ARMED. Stale claim
# corrected — this comment previously said "NOT INSTALLED, NOT ARMED", which
# was true when written (2026-09-03 morning) but not anymore: Athos ran the
# sudo install himself the same day at 11:35 -03, choosing via AskUserQuestion
# to go straight to unattended (no supervised first fire). Citable trail +
# Mayor's live-artifact verification: ga-i9q44 comments 2026-09-03 10:27/14:35.
# This IS now a PERMANENT, RECURRING, UNATTENDED reboot of the shared
# production machine, firing nightly 01:00-01:19 via
# /Library/LaunchDaemons/com.gascity.nightly-reboot.plist. First real fire
# (2026-09-04 01:00:01) correctly SKIPPED — fail-closed — on a transient
# gate-queue-composition.sh hiccup; that single-shot-costs-the-whole-night gap
# is exactly what ga-g5bzf/this commit's Guard 2 retry fixes below.
# ga-i9q44 itself stays open pending two consecutive clean nights of log
# evidence before it accepts — do not close it from this bug alone.
#
# WHY A REAL-TIME PRE-CHECK, NOT JUST A QUIET TIMER SLOT: city-night-window
# (the mechanism that would guarantee the whole city is quiet 00:00-08:00) is
# OFF by deliberate Athos decision since 2026-08-20, for token-cost reasons —
# see scripts/city-night-window.sh's own header. So no calendar slot is
# structurally guaranteed idle; this script checks REAL in-flight state at
# fire-time instead. The two hard gates below mirror exactly what the
# 2026-08-29 human-supervised reboot actually required
# (docs/runbooks/reboot-20260829-pre.txt): zero gate markers in flight, zero
# hq beads in_progress. Non-hq in-progress beads (e.g. wa crew work) are
# logged but NOT blocking — that precedent already treated those as fine,
# since inflight-reclaim-guard reclaims them afterward regardless of reboot.
#
# Runs as root (LaunchDaemon, no UserName key) so it can call /sbin/shutdown
# directly, same as the proven com.athos.reboot-once-0700 /
# reboot_once_0700.sh precedent — this sidesteps any TCC/GUI-session
# ambiguity an osascript-from-a-LaunchAgent approach would carry.
#
# FAIL-CLOSED: any check this script cannot complete (bd/gc unreachable, gate
# composition script errors) is treated as "unknown → do not reboot", never
# as "zero → safe". An error and an empty result must not collapse to the
# same value (see [[error-empty-must-not-produce-same-value]]).

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC_BIN:-/opt/homebrew/bin/gc}"
BD="${BD_BIN:-/opt/homebrew/bin/bd}"
LOG="${CITY}/.gc/logs/nightly-reboot.log"
NOTIFY_AS_USER="${NOTIFY_AS_USER:-athos}"
NOTIFY_BIN="${NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
# Unique per-invocation temp files (not fixed /tmp names): a fixed name
# reused night after night ends up owned by whichever user first created it
# (root, in production) — a later run under a different user (e.g. testing
# this script by hand) then gets a silent "Permission denied" on the stderr
# redirect instead of the diagnostic it's there to capture.
GATE_ERR="$(mktemp -t nightly-reboot-gate-err)"
HQ_ERR="$(mktemp -t nightly-reboot-hq-err)"
trap 'rm -f "${GATE_ERR}" "${HQ_ERR}"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}" 2>/dev/null; }
notify_athos() {
  # Root can sudo to another user with no password — same trick
  # reboot_once_0700.sh used for its pre-reboot heads-up.
  sudo -u "${NOTIFY_AS_USER}" "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
}

log "=== fired (uptime: $(uptime | sed 's/.*up //; s/,.*users.*//') ) ==="

# --- Guard 1: window sanity ---------------------------------------------
# Only fire inside 01:00-01:19. Catches a late replay if the box was
# down/asleep at the scheduled StartCalendarInterval hit (this mini runs
# sleep=0, but a power loss or panic can still cause a late catch-up fire).
# 01:00-01:19 sits inside the empty 00:30-01:30 gap measured against every
# other StartCalendarInterval job on this box (2026-09-03 survey) — a replay
# up to 01:19 stays clear of whatsapp.anuncios-refresh at 01:30.
HOUR=$(date +%-H)
MINUTE=$(date +%-M)
if [ "${HOUR}" -ne 1 ] || [ "${MINUTE}" -ge 20 ]; then
    log "SKIP: fired at ${HOUR}:$(printf '%02d' "${MINUTE}") — outside the 01:00-01:19 firing window, likely a late replay. Not rebooting."
    exit 0
fi

# --- Guard 2: gate markers in flight must be zero -----------------------
# 1 retry with a short backoff before giving up on the whole night (ga-g5bzf):
# the 2026-09-04 first real run hit a single transient hiccup at 01:00:00
# under load average 13-17 (bd/Dolt were confirmed healthy — the same script
# ran fine 9min later in 10.4s) and burned the entire night, since the next
# chance is tomorrow. Fail-closed on the LAST attempt is unchanged — this
# only protects against a one-shot blip, never trades away the
# "unknown → don't reboot" guarantee.
GATE_RETRIES="${NIGHTLY_REBOOT_GATE_RETRIES:-2}"
GATE_RETRY_SLEEP="${NIGHTLY_REBOOT_GATE_RETRY_SLEEP:-10}"
GATE_ATTEMPT=1
while true; do
    GATE_JSON=$("${CITY}/scripts/gate-queue-composition.sh" --json 2>"${GATE_ERR}")
    GATE_RC=$?
    [ "${GATE_RC}" -eq 0 ] && [ -n "${GATE_JSON}" ] && break
    [ "${GATE_ATTEMPT}" -ge "${GATE_RETRIES}" ] && break
    log "gate-queue-composition.sh attempt ${GATE_ATTEMPT}/${GATE_RETRIES} failed (rc=${GATE_RC}: $(cat "${GATE_ERR}" 2>/dev/null)) — retrying in ${GATE_RETRY_SLEEP}s before giving up on the night."
    sleep "${GATE_RETRY_SLEEP}"
    GATE_ATTEMPT=$((GATE_ATTEMPT+1))
done
if [ "${GATE_RC}" -ne 0 ] || [ -z "${GATE_JSON}" ]; then
    log "SKIP: gate-queue-composition.sh failed after ${GATE_ATTEMPT}/${GATE_RETRIES} attempts (rc=${GATE_RC}: $(cat "${GATE_ERR}" 2>/dev/null)) — unknown gate state treated as NOT safe. Not rebooting."
    notify_athos "Reboot noturno pulado" "gate-queue-composition.sh falhou (${GATE_ATTEMPT}/${GATE_RETRIES} tentativas) às $(date '+%H:%M') — não consegui confirmar fila do gate vazia. Ver ${LOG}."
    exit 0
fi
GATE_REAL=$(printf '%s' "${GATE_JSON}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("real","?"))' 2>/dev/null)
if [ "${GATE_REAL}" != "0" ]; then
    log "SKIP: gate real-work markers in flight = ${GATE_REAL} (raw: ${GATE_JSON}). Not rebooting."
    notify_athos "Reboot noturno pulado" "${GATE_REAL} marker(s) reais na fila do gate às $(date '+%H:%M') — reboot adiado pra próxima janela. Ver ${LOG}."
    exit 0
fi
log "gate check OK: 0 real markers in flight (raw: ${GATE_JSON}, attempt ${GATE_ATTEMPT}/${GATE_RETRIES})"

# --- Guard 3: hq beads in_progress must be zero --------------------------
HQ_INPROGRESS_JSON=$("${BD}" -C "${CITY}" list --status in_progress --json --limit 0 2>"${HQ_ERR}")
HQ_RC=$?
if [ "${HQ_RC}" -ne 0 ] || ! printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
    log "SKIP: bd list --status in_progress (hq) failed (rc=${HQ_RC}: $(cat "${HQ_ERR}" 2>/dev/null)) — unknown state treated as NOT safe. Not rebooting."
    notify_athos "Reboot noturno pulado" "não consegui ler beads in_progress do hq às $(date '+%H:%M'). Ver ${LOG}."
    exit 0
fi
HQ_INPROGRESS_COUNT=$(printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
if [ "${HQ_INPROGRESS_COUNT}" != "0" ]; then
    log "SKIP: hq beads in_progress = ${HQ_INPROGRESS_COUNT}. Not rebooting."
    notify_athos "Reboot noturno pulado" "${HQ_INPROGRESS_COUNT} bead(s) hq in_progress às $(date '+%H:%M') — reboot adiado pra próxima janela. Ver ${LOG}."
    exit 0
fi
log "hq in_progress check OK: 0"

# --- Informational only: other rigs' in_progress count (not a gate) ------
# Precedent (2026-08-29 runbook) treated non-hq in-progress as non-blocking —
# inflight-reclaim-guard reclaims stale crew claims regardless of reboot.
for RIG_DIR in "${CITY%/.gascity-gastown-hq}"/*/; do
    RIG_NAME=$(basename "${RIG_DIR}")
    [ -d "${RIG_DIR}/.beads" ] || continue
    CNT=$("${BD}" -C "${RIG_DIR}" list --status in_progress --json --limit 0 2>/dev/null | /usr/bin/python3 -c 'import json,sys
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print("?")' 2>/dev/null)
    log "info: ${RIG_NAME} in_progress = ${CNT} (non-blocking, logged only)"
done

# --- All clear: record pre-reboot state, then reboot ----------------------
log "disk before: $(df -h /System/Volumes/Data | tail -1 | awk '{print $4" free ("$5" used)"}')"
log "swap before: $(sysctl -n vm.swapusage 2>/dev/null)"
log "swapfiles before: $(ls /System/Volumes/VM/ 2>/dev/null | grep -c swapfile)"

notify_athos "Reboot noturno" "Reiniciando às $(date '+%H:%M') pra liberar swap acumulado. Volto em ~2min (auto-login)." 3

log "rebooting now"
sync
/sbin/shutdown -r now >>"${LOG}" 2>&1
RC=$?
log "ERROR: shutdown returned ${RC} — reboot did NOT happen"
exit 1

#!/bin/bash
# nightly-reboot.sh — recurring nightly reboot to reclaim the macOS swap
# ratchet that never releases on its own (ga-i9q44).
#
# ⚠️ STATUS (updated 2026-09-05, ga-nnp5b): the 2026-09-04 AND 2026-09-05
# fires both SKIPPED — kern.boottime never advanced past 2026-09-02 despite
# firing two nights running. Root cause: the LaunchDaemon fires at 01:00:00,
# squarely in the tail of the 00:00-00:30 nightly job burst (7 jobs hitting
# Dolt/disk); bd/Dolt were still too busy to answer at 01:00:00 both nights,
# gate-queue-composition.sh returned rc=2 (UNKNOWN), and this script
# correctly fail-closed — but did so EVERY night, silently, so the reboot
# that exists specifically to relieve swap pressure never relieved it: swap
# rose 14336M->15360M in ~30min on the night of 04->05, until disk hit
# ENOSPC and took Dolt down city-wide (ga-nnp5b).
#
# THE FIX BELOW, AND WHY IT DOES NOT MOVE THE 01:00 SLOT: ga-nnp5b's own
# text asks to move the LaunchDaemon's StartCalendarInterval to a slot
# outside the burst. That plist lives at /Library/LaunchDaemons/, owned
# root:wheel, and reinstalling it needs `sudo launchctl bootout`+`bootstrap`
# — a step this bug's autonomous builder session cannot perform
# (`Bash(sudo:*)` is an "ask" rule in ~/.claude/settings.json; an unattended
# session that hits it just hangs forever waiting for an approval that will
# never come — the same class of trap as the documented ga-gkap9p `rm -rf`
# incident). Rather than leave that half of the fix as a "someone should
# sudo this" doc that may never get executed — which is literally how
# ga-i9q44 itself was born, an authorization that never became a live
# mechanism — Guards 2+3 below are rewritten to retry the WHOLE pre-flight
# evaluation, together, patiently, for up to ~90 minutes past the 01:00
# fire. That's long enough to span BOTH gaps a fresh 2026-09-05 survey of
# every StartCalendarInterval job on this box found genuinely clear of
# other jobs (01:41-02:14 and 02:18-02:59), and to stop comfortably short of
# the dense Dolt/backup cluster starting at 03:00 (dolthub-backup,
# dolt-s3-backup, dolt-compact-routine, backup-all-dbs, pbh-freshness, a
# 6-way pileup at 04:00). Net effect is the same as moving the fire time —
# the actual reboot decision lands wherever the night turns out to be quiet
# — without touching a root-owned file this session has no way to safely
# change. Guard 1's 01:00-01:19 window is UNCHANGED: it only gates the
# initial fire (rejecting a late launchd replay), not how long the retry
# loop below may then run once that initial fire is accepted.
#
# A separate, additive fix for item 4 of ga-nnp5b ("alarme quando o job
# pular N noites seguidas — hoje falha em silêncio"): the existing
# per-night notify_athos() SKIP push already fired both nights and went
# unnoticed. record_skip()/reset_streak() below track how many nights IN A
# ROW ended in a skip (any guard, any reason — the swap ratchet doesn't
# care WHY the reboot didn't happen) and escalate louder + durably (mail to
# mayor, which the doctrine already uses for automated Dolt-trouble
# escalation) once that streak crosses NIGHTLY_REBOOT_ALARM_THRESHOLD.
#
# ga-i9q44 itself stays open pending two consecutive clean nights of log
# evidence (fired -> real reboot, kern.boottime advances) before it accepts
# — do not close it from this bug alone.
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
# same value (see [[error-empty-must-not-produce-same-value]]). The retry
# loop only buys TIME for a transient condition to clear — the LAST attempt
# in the budget still fail-closes exactly like before if nothing ever clears.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC_BIN:-/opt/homebrew/bin/gc}"
BD="${BD_BIN:-/opt/homebrew/bin/bd}"
SHUTDOWN_BIN="${SHUTDOWN_BIN:-/sbin/shutdown}"
LOG="${CITY}/.gc/logs/nightly-reboot.log"
STREAK_FILE="${CITY}/.gc/logs/nightly-reboot.streak"
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

# --- Consecutive-skip streak (ga-nnp5b item 4) ----------------------------
# Every SKIP below already pushes a per-night notify — but two nights of
# exactly that went unnoticed while swap climbed to ENOSPC (ga-nnp5b). This
# tracks how many nights IN A ROW ended in a skip (any guard, any reason —
# the swap ratchet does not care WHY the reboot didn't happen) and escalates
# louder + durably once that streak is long enough to matter, instead of
# relying on a push notification that can go unread forever.
#
# nightly-reboot.selftest.sh:STREAK-FUNCTIONS-START — sentinel for the
# selftest, which extracts exactly this block (via sed, to this file's
# matching END sentinel below) to unit-test the streak logic in total
# isolation from Guards 1-3 and the reboot call. Deliberate: those guards
# and the final /sbin/shutdown invocation must NEVER execute during a test
# (see the selftest's own header for why — the short version is that the
# quality gate replays this exact test file, unmodified, against the
# PRE-FIX commit of this script as part of an automated check, and that
# older script has no override hook for the reboot call at all). Keep this
# block self-contained (no reference to CITY/GC/BD/etc. beyond what's
# already visible above it) if you touch it, so the extraction keeps working.
ALARM_THRESHOLD="${NIGHTLY_REBOOT_ALARM_THRESHOLD:-2}"
read_streak() {
  local n
  n=$(cat "${STREAK_FILE}" 2>/dev/null)
  case "${n}" in (''|*[!0-9]*) n=0 ;; esac
  printf '%s' "${n}"
}
reset_streak() { printf '0\n' > "${STREAK_FILE}" 2>/dev/null || true; }
record_skip() {
  local reason="$1" n
  n=$(( $(read_streak) + 1 ))
  printf '%s\n' "${n}" > "${STREAK_FILE}" 2>/dev/null || true
  log "skip streak: ${n} consecutive night(s) without a reboot (reason: ${reason})"
  if [ "${n}" -gt 0 ] && [ $((n % ALARM_THRESHOLD)) -eq 0 ]; then
    log "ALARM: ${n} consecutive skipped nights (threshold ${ALARM_THRESHOLD}) — escalating to mayor"
    notify_athos "🚨 Reboot noturno: ${n} noites seguidas sem reiniciar" "Motivo mais recente: ${reason}. Swap pode estar acumulando sem alívio. Ver ${LOG}." 5
    "${GC}" --city "${CITY}" mail send mayor --from nightly-reboot.sh \
      -s "nightly-reboot: ${n} noites seguidas sem reiniciar (ga-nnp5b)" \
      -m "$(printf 'O reboot noturno pulou %s noites seguidas (fail-closed, correto por si so, mas nunca chega a aliviar o swap).\nMotivo mais recente: %s\nLog: %s\nSe isto continuar, investigar se a causa e estrutural (nao so um hiccup transiente) antes que vire ENOSPC de novo.' "${n}" "${reason}" "${LOG}")" \
      >/dev/null 2>&1 || true
  fi
}
# nightly-reboot.selftest.sh:STREAK-FUNCTIONS-END

# --- macOS update install-before-reboot (ga-l5m50) -------------------------
# ga-i9q44 reboots nightly to reclaim swap; separately, AutomaticDownload=1
# means macOS downloads recommended updates in the background on its own
# (AutomaticallyInstallMacOSUpdates stays 0 — deliberately: Athos chose to
# install in OUR nightly window, not delegate the policy to macOS). Without
# this, a fully-downloaded update sits on disk forever (measured: ~2.7GB,
# macOS Tahoe 26.6.2) because nothing ever tells it to install. This installs
# it right before the existing reboot, reusing that reboot rather than
# triggering a second one.
#
# nightly-reboot.selftest.sh:MACOS-UPDATE-FUNCTIONS-START — sentinel for the
# selftest, which extracts exactly this block (via sed) to unit-test this
# logic in total isolation from Guards 1-3 and the reboot call — same reason
# as the streak block above (see its own comment): the quality gate replays
# this selftest, unmodified, against the pre-fix commit, which has no
# override hook for a real `softwareupdate --install` call either. Keep this
# block self-contained (log()/notify_athos() already defined above,
# SOFTWAREUPDATE_BIN overridable) if you touch it.
SOFTWAREUPDATE_BIN="${SOFTWAREUPDATE_BIN:-/usr/sbin/softwareupdate}"
macos_update_ready() {
  # --no-scan: report from the catalog the AutomaticDownload daemon already
  # scanned in the background — never triggers a fresh scan/download of our
  # own at 01:00. Only a label whose Action includes "restart" counts as
  # ready: that is the distinction this bead asks for between "an update
  # exists" (could be a Safari/config-data-only entry that needs no reboot,
  # or one still downloading) and "ready to install".
  SU_LIST_OUT=$("${SOFTWAREUPDATE_BIN}" --list --no-scan 2>/dev/null)
  SU_LIST_RC=$?
  if [ "${SU_LIST_RC}" -ne 0 ]; then
    MACOS_UPDATE_REASON="softwareupdate --list --no-scan failed (rc=${SU_LIST_RC})"
    return 1
  fi
  if ! printf '%s' "${SU_LIST_OUT}" | grep -q "Action: restart"; then
    MACOS_UPDATE_REASON="no update with Action: restart pending"
    return 1
  fi
  return 0
}
macos_update_install_if_ready() {
  if ! macos_update_ready; then
    log "macOS update: ${MACOS_UPDATE_REASON} — reboot normal (sem instalar)"
    return 0
  fi
  log "macOS update pendente (Action: restart) — instalando antes do reboot; pode demorar mais que o normal (ga-l5m50)"
  notify_athos "Reboot noturno" "Instalando atualização de macOS antes de reiniciar — pode levar mais tempo que o normal." 3
  "${SOFTWAREUPDATE_BIN}" --install --all --no-scan --agree-to-license >>"${LOG}" 2>&1
  local su_rc=$?
  if [ "${su_rc}" -eq 0 ]; then
    log "macOS update instalado com sucesso"
  else
    log "ERROR: macOS update falhou ao instalar (rc=${su_rc}) — prosseguindo com o reboot mesmo assim"
    notify_athos "Reboot noturno: update falhou" "softwareupdate retornou ${su_rc} — reiniciando sem instalar. Ver ${LOG}." 4
  fi
  return 0
}
# nightly-reboot.selftest.sh:MACOS-UPDATE-FUNCTIONS-END

log "=== fired (uptime: $(uptime | sed 's/.*up //; s/,.*users.*//') ) ==="

# --- Guard 1: window sanity ---------------------------------------------
# Only fire inside 01:00-01:19. Catches a late replay if the box was
# down/asleep at the scheduled StartCalendarInterval hit (this mini runs
# sleep=0, but a power loss or panic can still cause a late catch-up fire).
# This window is INDEPENDENT of the retry budget below: it only gates
# whether tonight's run is accepted as a real scheduled fire at all, not how
# long that run may then spend retrying once accepted.
HOUR=$(date +%-H)
MINUTE=$(date +%-M)
if [ "${HOUR}" -ne 1 ] || [ "${MINUTE}" -ge 20 ]; then
    log "SKIP: fired at ${HOUR}:$(printf '%02d' "${MINUTE}") — outside the 01:00-01:19 firing window, likely a late replay. Not rebooting."
    exit 0
fi

# --- Guards 2+3, retried together as one unit (ga-nnp5b) ------------------
# ga-g5bzf's 2-attempt/10s retry (Guard 2 only) was not enough: the very
# next night (2026-09-05) failed both attempts again. This session cannot
# move the root-owned LaunchDaemon that would sidestep the collision
# directly (see header — needs sudo). So instead: retry the FULL pre-flight
# evaluation — gate markers AND hq in-progress, re-read together on every
# attempt, never just the first failing half, so a guard that clears late
# doesn't get judged on stale state from 90 minutes earlier — every
# RETRY_INTERVAL seconds, for up to RETRY_MAX_ATTEMPTS tries. Sized
# (5min x 18 = 90min) to span both windows the 2026-09-05 survey found clear
# of every other StartCalendarInterval job on this box (01:41-02:14 and
# 02:18-02:59) while stopping well short of the dense Dolt/backup cluster
# starting at 03:00. A healthy night still finishes on attempt 1 in seconds,
# same as before — this budget only spends time on a night that would
# otherwise have silently skipped.
RETRY_INTERVAL="${NIGHTLY_REBOOT_RETRY_INTERVAL:-300}"
RETRY_MAX_ATTEMPTS="${NIGHTLY_REBOOT_RETRY_MAX_ATTEMPTS:-18}"

# Runs Guard 2 (gate markers) + Guard 3 (hq in-progress) once. Sets
# BLOCK_REASON on failure. Returns 0 only if BOTH guards pass.
check_guards_once() {
    GATE_JSON=$("${CITY}/scripts/gate-queue-composition.sh" --json 2>"${GATE_ERR}")
    GATE_RC=$?
    if [ "${GATE_RC}" -ne 0 ] || [ -z "${GATE_JSON}" ]; then
        BLOCK_REASON="gate-queue-composition.sh failed (rc=${GATE_RC}: $(cat "${GATE_ERR}" 2>/dev/null)) — unknown gate state treated as NOT safe"
        return 1
    fi
    GATE_REAL=$(printf '%s' "${GATE_JSON}" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("real","?"))' 2>/dev/null)
    if [ "${GATE_REAL}" != "0" ]; then
        BLOCK_REASON="gate real-work markers in flight = ${GATE_REAL} (raw: ${GATE_JSON})"
        return 1
    fi
    HQ_INPROGRESS_JSON=$("${BD}" -C "${CITY}" list --status in_progress --json --limit 0 2>"${HQ_ERR}")
    HQ_RC=$?
    if [ "${HQ_RC}" -ne 0 ] || ! printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; then
        BLOCK_REASON="bd list --status in_progress (hq) failed (rc=${HQ_RC}: $(cat "${HQ_ERR}" 2>/dev/null)) — unknown state treated as NOT safe"
        return 1
    fi
    HQ_INPROGRESS_COUNT=$(printf '%s' "${HQ_INPROGRESS_JSON}" | /usr/bin/python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
    if [ "${HQ_INPROGRESS_COUNT}" != "0" ]; then
        BLOCK_REASON="hq beads in_progress = ${HQ_INPROGRESS_COUNT}"
        return 1
    fi
    return 0
}

ATTEMPT=1
while true; do
    if check_guards_once; then
        break
    fi
    if [ "${ATTEMPT}" -ge "${RETRY_MAX_ATTEMPTS}" ]; then
        log "SKIP: guards still blocked after ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} attempts over ~$(( (ATTEMPT-1) * RETRY_INTERVAL / 60 ))min (last: ${BLOCK_REASON}). Not rebooting."
        notify_athos "Reboot noturno pulado" "bloqueado após ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} tentativas às $(date '+%H:%M') — ${BLOCK_REASON}. Ver ${LOG}."
        record_skip "${BLOCK_REASON}"
        exit 0
    fi
    log "attempt ${ATTEMPT}/${RETRY_MAX_ATTEMPTS} blocked (${BLOCK_REASON}) — retrying in ${RETRY_INTERVAL}s."
    sleep "${RETRY_INTERVAL}"
    ATTEMPT=$((ATTEMPT+1))
done
log "guards OK on attempt ${ATTEMPT}/${RETRY_MAX_ATTEMPTS}: 0 real gate markers, 0 hq in_progress"

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

# --- macOS update: install before reboot if one is ready (ga-l5m50) -------
macos_update_install_if_ready

# --- All clear: record pre-reboot state, then reboot ----------------------
reset_streak
log "disk before: $(df -h /System/Volumes/Data | tail -1 | awk '{print $4" free ("$5" used)"}')"
log "swap before: $(sysctl -n vm.swapusage 2>/dev/null)"
log "swapfiles before: $(ls /System/Volumes/VM/ 2>/dev/null | grep -c swapfile)"

notify_athos "Reboot noturno" "Reiniciando às $(date '+%H:%M') pra liberar swap acumulado. Volto em ~2min (auto-login)." 3

log "rebooting now"
sync
"${SHUTDOWN_BIN}" -r now >>"${LOG}" 2>&1
RC=$?
log "ERROR: shutdown returned ${RC} — reboot did NOT happen"
exit 1

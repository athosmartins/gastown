#!/bin/bash
# disk-snapshot-guard.sh — proactively thins local Time Machine snapshots
# before they push /System/Volumes/Data into a Dolt-crashing ENOSPC crisis
# (ga-g5bzf follow-up, 2026-09-04, Mayor).
#
# WHY THIS EXISTS: twice in one night (2026-09-04, ~01:00 and ~07:17) local
# TM snapshots accumulated fast enough to take Dolt's data volume from >7GB
# free to 0 in well under an hour, crashing dolt sql-server with "no space
# left on device: error writing to database journal file". Both times the
# fix was the same Apple-sanctioned, non-destructive command:
#   tmutil thinlocalsnapshots / <bytes> 4
# — but it requires root, so a human (Athos) had to run it by hand each time,
# reactively, after the crash already happened. This script does the same
# command proactively, on a timer, as root, before the crisis — so nobody
# has to be woken up for it again.
#
# SAFETY: tmutil thinlocalsnapshots only purges local snapshot backing store
# (APFS purgeable space from TM's local snapshots) — it does not touch user
# files, does not touch .beads/dolt, does not touch any city data. It is the
# same command a human already ran twice tonight with no ill effect. It is a
# no-op (prints "Thinned local snapshots:" with nothing after the colon) when
# there is nothing to purge — safe to run on a timer even when not needed.
#
# THIS DOES NOT FIX THE UNDERLYING QUESTION of why local snapshots pile up
# this fast (no working TM backup destination reachable? see ga-ff6t9-adjacent
# discussion) — it only keeps the symptom from reaching Dolt's floor. If TM
# gets a real destination, this becomes a cheap no-op forever, not a wasted
# mechanism.

set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="${CITY}/.gc/logs/disk-snapshot-guard.log"
NOTIFY_AS_USER="athos"
NOTIFY_BIN="/Users/athos/.local/bin/notify"

# Proactive floor: act well above Dolt's own documented ~3GB crash floor, so
# there's real margin left when this fires (not another race to zero).
FLOOR_GB=12
# Target: try to reclaim up to this many bytes when the floor is breached.
RECLAIM_TARGET_BYTES=40000000000

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG}" 2>/dev/null; }
notify_athos() {
  sudo -u "${NOTIFY_AS_USER}" "${NOTIFY_BIN}" -t "$1" -p "${3:-3}" "$2" >/dev/null 2>&1 || true
}

AVAIL_KB=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
if [ -z "${AVAIL_KB}" ]; then
    log "SKIP: nao consegui ler df de /System/Volumes/Data — unknown state, nao age."
    exit 0
fi
AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))

if [ "${AVAIL_GB}" -ge "${FLOOR_GB}" ]; then
    # Healthy — nothing to do, don't even log every tick (would just be noise
    # every 10min forever). Only log the boundary-crossing runs below.
    exit 0
fi

log "=== piso furado: ${AVAIL_GB}GB livre (< ${FLOOR_GB}GB) — tentando thin ==="
BEFORE_KB="${AVAIL_KB}"

THIN_OUT=$(tmutil thinlocalsnapshots / "${RECLAIM_TARGET_BYTES}" 4 2>&1)
THIN_RC=$?
log "tmutil rc=${THIN_RC}: ${THIN_OUT}"

sleep 3
AFTER_KB=$(df -k /System/Volumes/Data 2>/dev/null | tail -1 | awk '{print $4}')
AFTER_GB=$(( AFTER_KB / 1024 / 1024 ))
FREED_MB=$(( (AFTER_KB - BEFORE_KB) / 1024 ))
log "resultado: ${AVAIL_GB}GB -> ${AFTER_GB}GB livre (freed ~${FREED_MB}MB)"

if [ "${FREED_MB}" -ge 500 ]; then
    notify_athos "Disco: guard liberou espaço" "${AVAIL_GB}GB -> ${AFTER_GB}GB (snapshot local do TM, automático)." 2
elif [ "${AFTER_GB}" -lt 3 ]; then
    # Thinning ran but didn't help enough and we're still at Dolt's real
    # crash floor — this is the one case worth waking a human for.
    log "ALERTA: piso critico mesmo apos thin — pode nao ser TM desta vez."
    notify_athos "Disco AINDA crítico após thin" "${AFTER_GB}GB livre — thin não resolveu. Precisa olhar (não é só snapshot desta vez)." 5
fi

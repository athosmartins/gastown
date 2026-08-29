#!/usr/bin/env bash
# wisp-table-reaper.sh — periodic drain of the Dolt `wisps` table (the
# mail/hook ephemeral store behind `gc mail`/`gc hook`) via the already-vetted
# `gt reaper reap`/`purge` Go operations.
#
# WHY THIS EXISTS (ga-xo035): reading a wisp (`gc mail read`) never
# transitions `wisps.status` — nothing periodically ran `gt reaper reap`/
# `purge` against it, so the table grew without bound. Confirmed live
# 2026-08-29: hq alone had 1827 open wisps (some 2 months old), 689 of them
# sitting read-but-unarchived under gastown.mayor alone — degrading `gc hook`,
# the first step of every autonomous agent's startup protocol, into a queue no
# real session would ever drain sequentially. `gt reaper run --help`'s own
# text says the full cycle is "normally" dispatched to a Dog via the
# mol-dog-reaper formula — but no daemon ever created that periodic dispatch;
# `gt reaper run` was only ever an on-demand fallback nobody scheduled.
#
# SCOPE — reap+purge ONLY. Deliberately does NOT run `gt reaper run` (which
# bundles a 4th step, auto-close, with no flag to exclude it) and does NOT
# call `gt reaper auto-close` directly either. AutoClose() has its own
# separate, confirmed-live bug (ga-cwfpq): as of this writing it lacks the
# `issue_type NOT IN ('agent','session')` exclusion its sibling Reap() already
# has, so it would close every open agent/session identity bead (crew/
# witness/refinery workspaces for lexbh, property_scrapers, gastown, deacon)
# in hq. Do NOT widen this script to auto-close until ga-cwfpq's patch
# (docs/pending-engine-window/ga-cwfpq-autoclose-exclude-agent-session.patch)
# is deployed AND verified live — re-check that bead's status first.
#
# SAFETY: `gt reaper reap`/`purge` already encapsulate all eligibility logic
# (issue_type agent/session exclusion and open-parent-molecule exclusion for
# reap; age-gated unconditional delete for purge, batched internally) — this
# wrapper only adds a pre-flight Dolt-health check (never operate against a
# struggling server, same convention as wisp-reaper.sh) and logging/
# notification. Uses an explicit --db per known-active database rather than
# gt's own bare auto-discover form, so a stray test/orphan database
# (e.g. fixdepkeys_*) can never silently enter scope.
#
# Idempotent (a sweep that finds nothing is a clean no-op). Kill switch:
# WTR_ENABLED=0 → no-op, touches nothing.
set -uo pipefail

HQ="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
LOG="${WTR_LOG:-$HQ/.gc/logs/wisp-table-reaper.log}"
WTR_ENABLED="${WTR_ENABLED:-1}"
# Static, deliberately explicit list of known-real production databases —
# same rationale as pilot-missing-route-watchdog.sh's PMRW_STORES: a live
# `gt reaper databases` auto-discover call would also sweep transient
# test-pollution databases (fixdepkeys_* observed live 2026-08-29) that
# DiscoverDatabases()'s prefix filter doesn't catch. Override via env if a
# rig is added.
WTR_DBS="${WTR_DBS:-hq whatsapp_automation property_scrapers dc gastown lexbh marketing}"
GT_BIN="${WTR_GT_BIN:-gt}"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [wtr] $*" >> "$LOG" 2>/dev/null || true; }
notify_athos() { command -v notify >/dev/null 2>&1 || return 0; notify "$@" >/dev/null 2>&1 || true; }

if [ "$WTR_ENABLED" != "1" ]; then
  log "disabled (WTR_ENABLED=0) — no-op"
  exit 0
fi

# Anti-Dolt-spike: never pile load onto a struggling server (same convention
# as wisp-reaper.sh's DOLT_HEALTH_GATE).
if ! gc --city "$HQ" dolt status >/dev/null 2>&1; then
  log "SKIP: gc dolt status unhealthy"
  exit 0
fi

TOTAL_REAPED=0
TOTAL_PURGED=0
ANY_FAILURE=0

for DB in $WTR_DBS; do
  REAP_OUT=$("$GT_BIN" reaper reap --db="$DB" --json 2>&1)
  REAP_RC=$?
  if [ "$REAP_RC" -ne 0 ]; then
    log "REAP FAILED db=$DB rc=$REAP_RC: $REAP_OUT"
    ANY_FAILURE=1
  else
    REAPED=$(printf '%s' "$REAP_OUT" | jq -r '.[0].reaped // 0' 2>/dev/null)
    case "$REAPED" in ''|*[!0-9]*) REAPED=0 ;; esac
    [ "$REAPED" -gt 0 ] && log "REAPED db=$DB count=$REAPED"
    TOTAL_REAPED=$((TOTAL_REAPED + REAPED))
  fi

  PURGE_OUT=$("$GT_BIN" reaper purge --db="$DB" --json 2>&1)
  PURGE_RC=$?
  if [ "$PURGE_RC" -ne 0 ]; then
    log "PURGE FAILED db=$DB rc=$PURGE_RC: $PURGE_OUT"
    ANY_FAILURE=1
  else
    WPURGED=$(printf '%s' "$PURGE_OUT" | jq -r '.[0].wisps_purged // 0' 2>/dev/null)
    case "$WPURGED" in ''|*[!0-9]*) WPURGED=0 ;; esac
    [ "$WPURGED" -gt 0 ] && log "PURGED db=$DB wisps=$WPURGED"
    TOTAL_PURGED=$((TOTAL_PURGED + WPURGED))
  fi
done

log "sweep complete: reaped=$TOTAL_REAPED purged=$TOTAL_PURGED failures=$ANY_FAILURE"

if [ "$TOTAL_REAPED" -gt 0 ] || [ "$TOTAL_PURGED" -gt 0 ]; then
  notify_athos -t "wisp-table-reaper" "reaped $TOTAL_REAPED, purged $TOTAL_PURGED old wisp(s) across ${WTR_DBS}"
fi

exit 0

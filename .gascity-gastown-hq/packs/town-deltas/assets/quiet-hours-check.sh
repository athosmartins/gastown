# quiet-hours-check.sh — shared "is the city in quiet hours" READ-side helper
# (ga-dxyvxr). Athos, 2026-08-16: 00h-08h "todo mundo dorme" — the city pauses
# ADMISSION of new work to stop burning token overnight, without killing
# anything already in flight. "gc suspend" (scripts/city-night-window.sh)
# already covers the reconciler (pool dogs, min_active_sessions, wake-reason
# wakes) but NOT the launchd dispatchers (Pilot, quality-gate, auto-refino,
# refino-gate), which spawn sessions directly and would keep dispatching all
# night. This file is the read side every dispatcher sources; the write side
# is scripts/city-night-window.sh, which already runs every 10min and already
# computes the exact same window+override logic — it just also stamps this
# signal now, so nobody has a second copy of the window math.
#
# Mirrors the RAM-pressure-monitor.level pattern already proven in
# pilot-dispatcher.sh (_pilot_ram_pressure_blocks/_level/_unreadable): same
# 2-line file shape ("<STATE>\n<unix_ts>\n"), same staleness+override
# semantics, same 3-function split (decision / raw-value-for-logging /
# explicitly-unreadable-for-logging) so a caller can log "confirmed OPEN" and
# "couldn't tell, proceeding anyway" as the visibly DIFFERENT states they are
# — collapsing them into the same silence is exactly the third-state defect
# class this city's own gate-done self-audit exists to catch.
#
# FAIL-OPEN is the correct direction here, same reasoning as RAM-pressure:
# a missing/stale signal usually just means city-night-window.sh has not run
# yet (job not loaded, first boot, clock skew) — not evidence the city
# actually needs to go quiet. This fix must never be able to freeze dispatch
# harder than the problem it closes.
#
# Sourced by: pilot-dispatcher.sh, quality-gate-dispatcher.sh,
# auto-refino-dispatcher.sh, refino-gate-dispatcher.sh.

QUIET_HOURS_LEVEL_FILE="${QUIET_HOURS_LEVEL_FILE:-${HOME}/.gastown/run/city-quiet-hours.level}"
# city-night-window.sh runs every 10min; 1800s (30min = 3 missed cycles) gives
# real slack for a single missed/delayed run without the signal going stale
# under normal jitter, while still catching a genuinely dead writer well
# inside one quiet-hours window.
QUIET_HOURS_MAX_AGE_SECS="${QUIET_HOURS_MAX_AGE_SECS:-1800}"

# _quiet_hours_blocks → "1" iff the level file says QUIET and is fresh, else
# "0" (covers OPEN, missing, stale, and corrupt — all fail open the same way).
# Honors QUIET_HOURS_OVERRIDE (test seam, mirrors PILOT_RAM_PRESSURE_OVERRIDE)
# — set to "QUIET" to force the blocked path, anything else to force open.
_quiet_hours_blocks() {
  if [ -n "${QUIET_HOURS_OVERRIDE:-}" ]; then
    case "$QUIET_HOURS_OVERRIDE" in
      QUIET) printf '1'; return 0 ;;
      *) printf '0'; return 0 ;;
    esac
  fi
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf '0'; return 0; }
  local _state _ts _now
  _state=$(sed -n '1p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  _ts=$(sed -n '2p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  _now=$(date +%s)
  [ $(( _now - _ts )) -gt "$QUIET_HOURS_MAX_AGE_SECS" ] && { printf '0'; return 0; }
  if [ "$_state" = "QUIET" ]; then printf '1'; else printf '0'; fi
}

# _quiet_hours_state → raw state string ("QUIET"/"OPEN"/"") for LOGGING only —
# deliberately skips the staleness/override short-circuiting _quiet_hours_blocks
# applies to its decision, so a caller can log what the file literally says
# even on the fail-open path.
_quiet_hours_state() {
  [ -n "${QUIET_HOURS_OVERRIDE:-}" ] && { printf '%s' "$QUIET_HOURS_OVERRIDE"; return 0; }
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf ''; return 0; }
  sed -n '1p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]'
}

# _quiet_hours_unreadable → "1" iff the signal is missing/stale/corrupt (the
# fail-open path — dispatch proceeds either way), "0" iff a genuine QUIET/OPEN
# reading was read (confirmed, not assumed).
_quiet_hours_unreadable() {
  [ -n "${QUIET_HOURS_OVERRIDE:-}" ] && { printf '0'; return 0; }
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf '1'; return 0; }
  local _ts _now
  _ts=$(sed -n '2p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_ts" in ''|*[!0-9]*) printf '1'; return 0 ;; esac
  _now=$(date +%s)
  if [ $(( _now - _ts )) -gt "$QUIET_HOURS_MAX_AGE_SECS" ]; then printf '1'; return 0; fi
  printf '0'
}

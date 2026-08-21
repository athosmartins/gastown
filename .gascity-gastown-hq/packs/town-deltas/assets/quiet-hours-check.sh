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
# auto-refino-dispatcher.sh, refino-gate-dispatcher.sh, and
# context-check-dispatcher.sh — 5 consumers, not 4 (ga-w8kbf: this list
# itself was stale, missing context-check-dispatcher.sh, until that bead's
# fix corrected it here alongside the actual bug).

QUIET_HOURS_LEVEL_FILE="${QUIET_HOURS_LEVEL_FILE:-${HOME}/.gastown/run/city-quiet-hours.level}"
# city-night-window.sh runs every 10min; 1800s (30min = 3 missed cycles) gives
# real slack for a single missed/delayed run without the signal going stale
# under normal jitter, while still catching a genuinely dead writer well
# inside one quiet-hours window.
QUIET_HOURS_MAX_AGE_SECS="${QUIET_HOURS_MAX_AGE_SECS:-1800}"
# Mirrors city-night-window.sh's own NIGHT_START_HOUR/NIGHT_END_HOUR defaults
# (00h-08h local, end exclusive) — the calendar-overlap math below needs the
# same boundary the writer uses, or a caller could discount a range the writer
# never actually paused.
NIGHT_START_HOUR="${NIGHT_START_HOUR:-0}"
NIGHT_END_HOUR="${NIGHT_END_HOUR:-8}"

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

# _quiet_hours_unreadable → "1" iff the signal is STALE or CORRUPT (the
# fail-open path — dispatch proceeds either way; this is purely a LOGGING
# signal, distinct from the dispatch decision _quiet_hours_blocks already
# makes correctly for every case), "0" iff a genuine QUIET/OPEN reading was
# read (confirmed, not assumed) OR the file is simply ABSENT.
#
# ga-w8kbf: ABSENT is not the same third state as STALE/CORRUPT, and
# collapsing them here was the bug — a missing file is the SILENT, EXPECTED
# shape when the night-window mechanism itself is disabled (no writer
# running by design, e.g. after `launchctl bootout` of
# com.gascity.city-night-window — see scripts/city-night-window.sh), while
# a file that EXISTS but carries a stale timestamp or an unparseable one
# means a writer that WAS running has since broken or hung: a real anomaly
# worth a log line. Before this fix both produced "1", so 4 dispatchers
# (pilot, quality-gate, auto-refino, refino-gate) logged "UNREADABLE
# (missing/stale/corrupt)" every single sweep, forever, for a state that is
# both permanent and correct — training the reader to ignore the message,
# which is exactly the day a REAL stale/corrupt writer would also go
# unnoticed. Absence now returns "0": nothing to report, matches
# _quiet_hours_blocks' own (already-correct) treatment of "no file" as
# "not blocking, not an anomaly". Stale/corrupt still return "1" — this fix
# must not blind the genuine-anomaly case, only the deliberately-off one.
_quiet_hours_unreadable() {
  [ -n "${QUIET_HOURS_OVERRIDE:-}" ] && { printf '0'; return 0; }
  [ -f "$QUIET_HOURS_LEVEL_FILE" ] || { printf '0'; return 0; }
  local _ts _now
  _ts=$(sed -n '2p' "$QUIET_HOURS_LEVEL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$_ts" in ''|*[!0-9]*) printf '1'; return 0 ;; esac
  _now=$(date +%s)
  if [ $(( _now - _ts )) -gt "$QUIET_HOURS_MAX_AGE_SECS" ]; then printf '1'; return 0; fi
  printf '0'
}

# ── elapsed-clock adjustment (ga-lda92s) ────────────────────────────────────
# The three functions above answer "is it quiet RIGHT NOW" — the admission
# gate's only question. A STALL WATCHDOG asks a different question: "how much
# of [event_ts, now] was the city actually expected to be flowing?" A watchdog
# that just calls _quiet_hours_blocks and silences itself for the WHOLE window
# trades a false-positive for a false-negative (a real stall starting 00h30
# would go unseen for 7h30 — see ga-lda92s). The fix is to discount ONLY the
# quiet portion of the elapsed clock, not the whole verdict.

# _quiet_window_overlap_seconds <start_ts> <end_ts> — PURE calendar math: total
# seconds of [start_ts, end_ts) that fall within local
# [NIGHT_START_HOUR:00, NIGHT_END_HOUR:00) on any day. No file I/O, no live
# state — deterministic and safe to unit-test directly with constructed
# timestamps. Does NOT know about a live override; see
# _quiet_elapsed_adjustment below for the safety wrapper that does.
_quiet_window_overlap_seconds() {
  local start_ts="${1:-}" end_ts="${2:-}"
  case "$start_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  case "$end_ts" in ''|*[!0-9]*) printf '0'; return 0 ;; esac
  [ "$end_ts" -le "$start_ts" ] 2>/dev/null && { printf '0'; return 0; }

  local nsh="${NIGHT_START_HOUR:-0}" neh="${NIGHT_END_HOUR:-8}"
  local day day_str total=0 iterations=0
  day_str="$(date -j -f "%s" "$start_ts" "+%Y-%m-%d" 2>/dev/null)"
  [ -z "$day_str" ] && { printf '0'; return 0; }
  day="$(date -j -f "%Y-%m-%d %H:%M:%S" "${day_str} 00:00:00" +%s 2>/dev/null)"
  [ -z "$day" ] && { printf '0'; return 0; }

  # Bounded to 32 days (real callers span at most a few hours) — defensive,
  # never meant to trip, just a hard stop against a date-arithmetic bug
  # turning into an infinite loop.
  while [ "$day" -lt "$end_ts" ] && [ "$iterations" -lt 32 ]; do
    local win_start=$(( day + nsh * 3600 ))
    local win_end=$(( day + neh * 3600 ))
    local ov_start=$(( start_ts > win_start ? start_ts : win_start ))
    local ov_end=$(( end_ts < win_end ? end_ts : win_end ))
    [ "$ov_end" -gt "$ov_start" ] && total=$(( total + (ov_end - ov_start) ))
    day=$(( day + 86400 ))
    iterations=$(( iterations + 1 ))
  done
  printf '%s' "$total"
}

# _quiet_elapsed_adjustment <start_ts> <end_ts> — seconds to SUBTRACT from a
# raw (end_ts - start_ts) elapsed duration to discount legitimate quiet-hours
# pause. Composes the pure calendar overlap above with a live-signal safety
# check: if end_ts's own calendar day says "still in tonight's window" but the
# LIVE signal disagrees (a human override is active — see
# city-night-window.sh's ESCAPE PARA TRABALHAR DE MADRUGADA — or the writer is
# stale/down), we cannot confirm TODAY's portion was actually enforced, so we
# don't discount it — only prior days (if the range spans more than one
# night) stay discounted. Errs toward NOT discounting, i.e. toward the
# wall-clock elapsed a real stall would need anyway — never toward silence.
_quiet_elapsed_adjustment() {
  local start_ts="${1:-}" end_ts="${2:-}"
  local raw; raw="$(_quiet_window_overlap_seconds "$start_ts" "$end_ts")"
  case "$raw" in ''|0) printf '0'; return 0 ;; esac

  local nsh="${NIGHT_START_HOUR:-0}" neh="${NIGHT_END_HOUR:-8}"
  local day_str end_midnight
  day_str="$(date -j -f "%s" "$end_ts" "+%Y-%m-%d" 2>/dev/null)"
  [ -z "$day_str" ] && { printf '%s' "$raw"; return 0; }
  end_midnight="$(date -j -f "%Y-%m-%d %H:%M:%S" "${day_str} 00:00:00" +%s 2>/dev/null)"
  [ -z "$end_midnight" ] && { printf '%s' "$raw"; return 0; }

  local win_start=$(( end_midnight + nsh * 3600 ))
  local win_end=$(( end_midnight + neh * 3600 ))
  if [ "$end_ts" -ge "$win_start" ] && [ "$end_ts" -lt "$win_end" ] && [ "$(_quiet_hours_blocks)" != "1" ]; then
    if [ "$win_start" -gt "$start_ts" ] 2>/dev/null; then
      raw="$(_quiet_window_overlap_seconds "$start_ts" "$win_start")"
    else
      raw=0
    fi
  fi
  printf '%s' "$raw"
}

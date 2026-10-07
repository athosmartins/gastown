#!/usr/bin/env bash
# gate-focus-lib.sh (ga-kqa08j) — READ side of the gate focus mode.
#
# The mode itself is decided by ONE owner, gate-focus-mode.sh (launchd, every 5 min),
# which writes $GC_CITY/.gc/gate-focus.state. Everything else (Pilot, the dog-cap
# writer) only READS it through gate_focus_active, so no consumer re-derives the rule.
#
# gate_focus_active prints exactly one of:
#   1        the mode is ON and the state was written recently
#   0        the mode is OFF and the state was written recently
#   unknown  no file, a corrupt file, or a state older than GATE_FOCUS_STALE_S
# Consumers treat "unknown" as OFF (fail-open: an unreadable signal must never stop
# the city from building, same contract as every other Pilot pause) but they must
# LOG it, so "the mode is off" and "nobody could tell" never look the same.
#
# Source this file; it defines functions only and has no side effects.

GATE_FOCUS_STATE_FILE="${GATE_FOCUS_STATE_FILE:-${GC_CITY:-${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}}/.gc/gate-focus.state}"
# How long a state is trusted without a fresh measurement. The queue moves ~1 item/hour,
# so a 2 h hold is safe; a short window made every slow bd probe flip readers to
# "unknown" and back (each flip = a dog-cap rewrite + gc reload) — ga-kqa08j review.
GATE_FOCUS_STALE_S="${GATE_FOCUS_STALE_S:-7200}"

# _gate_focus_field <name> — value of name=... in the state file (empty if absent).
_gate_focus_field() {
  [ -r "$GATE_FOCUS_STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$GATE_FOCUS_STATE_FILE" 2>/dev/null | head -n 1
}

gate_focus_active() {
  local active at now
  if [ -n "${GATE_FOCUS_ACTIVE_OVERRIDE:-}" ]; then
    printf '%s' "$GATE_FOCUS_ACTIVE_OVERRIDE"; return 0
  fi
  active="$(_gate_focus_field active)"
  at="$(_gate_focus_field at)"
  now="${GATE_FOCUS_NOW:-$(date +%s)}"
  case "$active" in 0|1) ;; *) printf 'unknown'; return 0 ;; esac
  case "$at" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  if [ $(( now - at )) -gt "$GATE_FOCUS_STALE_S" ] || [ "$at" -gt $(( now + 60 )) ]; then
    printf 'unknown'; return 0
  fi
  printf '%s' "$active"
}

# gate_focus_depth — the queue depth the owner last measured (empty if unknown).
gate_focus_depth() { _gate_focus_field depth; }

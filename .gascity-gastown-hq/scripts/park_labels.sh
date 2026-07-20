#!/usr/bin/env bash
# park_labels.sh — shell-sourceable mirror of park_labels.py's PARK_LABELS +
# GATE_PARK_LABELS + FLOWING_OR_DONE_LABELS union and matching rule.
#
# WHY THIS EXISTS (ga-hzt8s, 2026-07-20): park_labels.py is canonical for the
# three Python consumers (approved-state-reconciler.py, imparavel-check.py,
# throughput-stall-watchdog.py). This file exists so a future shell daemon
# (e.g. quality-gate-dispatcher.sh) can check the same vocabulary without
# reimplementing its own list. Hand-kept in sync with park_labels.py — there is
# no build step that generates one from the other, so a label added to one
# MUST be added to the other too (this is exactly the drift this bug fixed;
# don't recreate it here).
#
# Usage:
#   source scripts/park_labels.sh
#   if bead_is_parked "${labels[@]}"; then ...; fi

PARK_LABEL_BASES=(
  # human-in-the-loop
  "gate:needs-human" "story:needs-human" "needs-human" "needs-label-review"
  # manual/device execution
  "exec:manual" "on-device" "story:needs-device" "phone-proxy"
  # explicitly blocked
  "blocked" "story:blocked" "blocked-on" "blocked-reason" "waiting-on"
  "next-action" "needs:rehome"
  # not ready / not current
  "story:refinement-in-progress" "ctx:thin" "story:cancelled"
  "framework:engine" "story:awaiting-external-merge" "pool:refused"
  # pilot deliberately withheld dispatch
  "pilot:held" "pilot:no-auto-dispatch"
  # gate-fix retry loop / already in the gate pipeline
  "gate:needs-fix" "gate:failed" "gate:needs-rebase" "gate:queued" "gate:reviewing"
  # already dispatched/building, or finished
  "story:in-flight" "pilot:dispatched" "pilot:dispatching" "story:done"
)

PARK_LABEL_DEFAULT_RECLAIM_CAP=3

# park_label_matches <label> <base> — exact match, or a ":"- or "-"-suffixed
# variant (mirrors park_labels.py's label_matches).
park_label_matches() {
  local label="$1" base="$2"
  [ "$label" = "$base" ] && return 0
  case "$label" in
    "$base":*|"$base"-*) return 0 ;;
  esac
  return 1
}

# bead_is_parked <label1> [label2 ...] — true (exit 0) if any label matches a
# PARK_LABEL_BASES entry, or is a pilot:reclaim-count:N with N >= the cap.
bead_is_parked() {
  local label base n
  for label in "$@"; do
    for base in "${PARK_LABEL_BASES[@]}"; do
      park_label_matches "$label" "$base" && return 0
    done
    case "$label" in
      pilot:reclaim-count:*)
        n="${label##*:}"
        case "$n" in
          ''|*[!0-9]*) : ;;
          *) [ "$n" -ge "$PARK_LABEL_DEFAULT_RECLAIM_CAP" ] && return 0 ;;
        esac
        ;;
    esac
  done
  return 1
}

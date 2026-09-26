#!/bin/bash
# scratchpad-sweep.sh (ga-hynohs) — cadence wrapper the `scratchpad-sweep` order runs.
#
# WHY: scripts/scratchpad-reaper.sh only ever ran from inside dolt-disk-floor-guard, and
# there only once the disk was already WARN/CRITICAL, behind a 24h age gate (the CRITICAL
# size-escape wants one dir >= 2GB). Gate reviewers copy the branch under review into their
# scratchpad (tree/, tree_base/, exp/... — 130-830MB per session), so on 2026-09-26 the
# collector sat idle while /private/tmp/claude-501 went 27MB -> 3.5GB in 3h. This wrapper
# gives it an always-on cadence with a 30-minute idle gate (dead sessions only).
#
# WHAT IT DOES: nothing but set the two things only a real, scheduled caller may set and
# hand over to the reaper —
#   SCRATCHPAD_REAPER_PROD=1  the production opt-in of the reaper's ga-h565g sentinel: with
#                             it unset, a run against the real /private/tmp/claude-<uid> is
#                             forced to dry-run. This wrapper is the second real caller
#                             (the first is dolt-disk-floor-guard's _reap_dead_scratch).
#   SCRATCHPAD_REAPER_MIN_IDLE_MINUTES  the idle gate; 30 unless SCRATCHPAD_SWEEP_MIN_IDLE_MINUTES
#                             says otherwise. Everything that makes a reap safe — liveness
#                             from gc AND from running claude processes, self-protection,
#                             fail-closed process scan, safe-clean, the single-instance
#                             lock — lives in the reaper, not here, so there is one copy.
#
# CADENCE: 10m order interval, 300s timeout. One run measured 2026-09-26 at load ~60 took
# 1m50s (12-37s of it `gc session list`, the rest ~0.4s per dead candidate) — well inside
# the timeout and the interval. The reaper's own lock stops a slow run from stacking.
#
# A missing reaper is a FAILED sweep (exit 1, stderr), never a quiet success: a sweep that
# cannot run must not look like a sweep that found nothing.
#
# TEST: bash packs/town-deltas/assets/scripts/scratchpad-sweep.selftest.sh
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
REAPER="${SCRATCHPAD_SWEEP_REAPER:-$CITY/scripts/scratchpad-reaper.sh}"

if [ ! -f "$REAPER" ]; then
  echo "scratchpad-sweep: reaper not found at $REAPER — nothing was swept" >&2
  exit 1
fi

export SCRATCHPAD_REAPER_PROD=1
export SCRATCHPAD_REAPER_MIN_IDLE_MINUTES="${SCRATCHPAD_SWEEP_MIN_IDLE_MINUTES:-30}"
exec bash "$REAPER"

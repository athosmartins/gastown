#!/usr/bin/env bash
# prod-tests/gascity/run.sh — rig-level prod test entry for the gascity HQ
# framework. Called by story-delivery.sh after deploy. Exits 0 on pass.
#
# STORY_ID (set by story-delivery.sh) selects a story-specific test. A baseline
# always-run check verifies the skill-publish integrity mechanism is live, since
# that is core framework health.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STORY_ID="${STORY_ID:-}"

log()  { echo "[prod-test:gascity] $*"; }
fail() { echo "[prod-test:gascity] FAIL: $*" >&2; exit 1; }

# ── Baseline: skill-publish integrity is always part of framework health ───────
if [[ -x "$HERE/story-ga-5lx.sh" ]]; then
    log "Baseline: skill-publish integrity (ga-5lx) ..."
    "$HERE/story-ga-5lx.sh" || fail "skill-publish integrity test failed"
fi

# ── Story-specific dispatch ───────────────────────────────────────────────────
if [[ -n "$STORY_ID" && -x "$HERE/story-$STORY_ID.sh" && "$STORY_ID" != "ga-5lx" ]]; then
    log "Running story-specific test: story-$STORY_ID.sh"
    "$HERE/story-$STORY_ID.sh" || fail "story-$STORY_ID test failed"
fi

log "PASS"
exit 0

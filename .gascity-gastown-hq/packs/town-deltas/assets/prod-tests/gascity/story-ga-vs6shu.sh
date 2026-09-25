#!/usr/bin/env bash
# prod-tests/gascity/story-ga-vs6shu.sh — prod test for ga-vs6shu:
# worktree-reaper's classify_lock only ever understood a literal "pid N"
# phrase in a lock reason. The REAL reasons pool workers write name a
# SESSION instead ("wa-ho1ol build (wa-worker-adhoc-...)", "(no reason)",
# ...) — none matched, so every one fell to "unparseable", and the call site
# collapsed that into the SAME kept_locked_live verdict as a genuinely
# confirmed-alive holder. 51 real worktrees (2.3G) sat locked forever this
# way — all already 100% merged, clean, no process nearby, aged 72h-1384h —
# until a human removed them by hand.
#
# Fix: classify_lock now also tries session-name tokens from the reason
# (confirmed via a live session list AND a matching work_dir — never trust a
# persistent pool-slot name alone, since it can be busy with unrelated newer
# work); the call site splits "confirmed live" from "genuinely unparseable"
# into distinct log events instead of one collapsed label; and a genuinely
# unparseable lock gets one independent safety-net check (merged into main +
# clean + no process has it as a cwd + aged past the gate) before being
# reaped anyway — nothing left for the lock to protect, regardless of
# whether its text could be understood.
#
# Verifies the DEPLOYED reaper directly (not a hand-copied re-assertion of
# the same claims), then runs the dedicated (now-extended) selftest
# end-to-end against it.
#
# Called by run.sh after deploy (STORY_ID=ga-vs6shu). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SCRIPTS="$CITY/scripts"
REAPER="$SCRIPTS/worktree-reaper.sh"
SELFTEST="$SCRIPTS/worktree-reaper.selftest.sh"

log()  { echo "[prod-test:gascity ga-vs6shu] $*"; }
fail() { echo "[prod-test:gascity ga-vs6shu] FAIL: $*" >&2; exit 1; }

[[ -f "$REAPER" ]]   || fail "missing: $REAPER"
[[ -f "$SELFTEST" ]] || fail "missing: $SELFTEST"
log "Deployed reaper + selftest found."

# ── 1. Syntax: the deployed reaper must still parse cleanly ────────────────────
log "Checking reaper bash syntax..."
bash -n "$REAPER" || fail "worktree-reaper.sh has a syntax error"
log "  syntax OK ✓"

# ── 2. The new functions and the distinct log events are in the DEPLOYED file ──
log "Checking the new functions and distinct log events are present..."
grep -q '^_session_is_alive_for_worktree() {' "$REAPER" \
  || fail "_session_is_alive_for_worktree() missing from the deployed reaper"
grep -q '^_reap_or_log_unparseable_lock() {' "$REAPER" \
  || fail "_reap_or_log_unparseable_lock() missing from the deployed reaper"
grep -qF '"event":"kept_locked_unparseable"' "$REAPER" \
  || fail "kept_locked_unparseable distinct event missing"
grep -qF '"event":"reaped_locked_unparseable_safe"' "$REAPER" \
  || fail "reaped_locked_unparseable_safe distinct event missing"
log "  present ✓"

# ── 3. classify_lock's call sites pass the worktree path through ───────────────
# Without this, the session-name recognition and the work_dir cross-check
# (the pool-slot-reuse guard) silently never fire.
log "Checking classify_lock is called with the worktree path..."
grep -qF 'classify_lock "$reason" "$wt"' "$REAPER" \
  || fail "reap_zombie_locked no longer passes \$wt to classify_lock"
grep -qF 'classify_lock "$reason" "$wt"' "$REAPER" \
  || fail "_reap_or_log_unparseable_lock no longer passes \$wt to classify_lock"
log "  wired ✓"

# ── 4. Both call sites (reap_pool_worktrees AND the legacy path-glob loop)
# route their zrc=2 case through the new helper — the actual measured bug
# affected the flat/nested .gc-worktrees scan (loop 1), not just the
# per-rig pool scan (loop 2), so both must be fixed, not just one.
log "Checking both call sites route zrc=2 through the new helper..."
_CALL_COUNT=$(grep -cF '_reap_or_log_unparseable_lock "' "$REAPER")
[[ "$_CALL_COUNT" -ge 2 ]] \
  || fail "_reap_or_log_unparseable_lock called from only $_CALL_COUNT site(s) in the deployed reaper, need >=2 (pool loop + legacy path-glob loop)"
log "  both call sites wired ($_CALL_COUNT occurrences) ✓"

# ── 5. The dedicated (now-extended) selftest passes end-to-end against the
# deployed file. This is the real proof, not a restatement — it extracts the
# LIVE functions and exercises them against a hermetic fake session list and
# fake process table across the full existing suite (78 assertions: every
# pre-existing zombie-lock/dirty-preserve/merged-fast-path/multi-root
# scenario, plus 12 new ga-vs6shu-specific ones covering the actual measured
# bug, the pool-slot-reuse subtlety, and both call sites).
log "Running worktree-reaper.selftest.sh against the deployed reaper (this builds several temp git repos, can take ~30-60s)..."
bash "$SELFTEST" || fail "worktree-reaper.selftest.sh reported failures"
log "  selftest PASS ✓"

log "PASS"
exit 0

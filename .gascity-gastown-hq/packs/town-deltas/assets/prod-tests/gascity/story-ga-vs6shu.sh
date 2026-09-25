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
grep -q 'kept_locked_unparseable' "$REAPER" \
  || fail "kept_locked_unparseable distinct event missing"
grep -q 'reaped_locked_unparseable_safe' "$REAPER" \
  || fail "reaped_locked_unparseable_safe distinct event missing"
# gate ga-wpdmj6: the THIRD state. An unavailable `gc session list` must have its own
# fetch function, its own distinct kept event, and its own counter — not be folded into
# kept_locked_unparseable (the error-vs-empty collapse that let a gc timeout read as "no
# session is alive" and reap a possibly-live session's worktree).
grep -q '^_session_list_ensure() {' "$REAPER" \
  || fail "_session_list_ensure() missing — the session-list fetch/three-state memo is gone"
grep -qF 'kept_locked_session_list_unavailable' "$REAPER" \
  || fail "kept_locked_session_list_unavailable (the could-not-know event) missing"
grep -qF '"session_list_unavailable"' "$REAPER" \
  || fail "session_list_unavailable (the fetch-failure event carrying rc/why) missing"
grep -qF 'kept_session_list_unavailable' "$REAPER" \
  || fail "kept_session_list_unavailable counter missing from the sweep summary"
# gate ga-x7lbcr: only the exact verdict "unparseable" may reach the independent-proof (destructive) path —
# an empty / stray / unnamed verdict is KEPT with its own event; and the gc fetch has a KILL grace, so a gc
# that ignores TERM cannot hold the sweep past its bound.
grep -qF 'kept_locked_unrecognized_verdict' "$REAPER" \
  || fail "kept_locked_unrecognized_verdict (the default-arm KEEP) missing from the deployed reaper"
grep -qE 'timeout -k "\$SESSION_LIST_KILL_GRACE" "\$SESSION_LIST_TIMEOUT" gc ' "$REAPER" \
  || fail "the gc session-list fetch no longer runs as 'timeout -k <grace> <bound> gc' (a gc that ignores TERM would hang the sweep)"
log "  present ✓"

# ── 3. classify_lock's call sites pass the worktree path through ───────────────
# Without this, the session-name recognition and the work_dir cross-check
# (the pool-slot-reuse guard) silently never fire. Each function's body is
# extracted and checked on its OWN — a whole-file grep for the same string
# passes as long as ONE of the two call sites still has it, so dropping "$wt"
# from the other would go unnoticed.
log "Checking classify_lock is called with the worktree path (per function)..."
_body() { sed -n "/^$1() {/,/^}/p" "$REAPER"; }
_body reap_zombie_locked | grep -qF 'classify_lock "$reason" "$wt"' \
  || fail "reap_zombie_locked no longer passes \$wt to classify_lock"
_body _reap_or_log_unparseable_lock | grep -qF 'classify_lock "$reason" "$wt"' \
  || fail "_reap_or_log_unparseable_lock no longer passes \$wt to classify_lock"
log "  wired ✓"

# ── 3b. The session list is fetched ONCE per sweep, in the MAIN shell ─────────
# classify_lock always runs as `$(classify_lock ...)` — a subshell — so a fetch (and
# its memo) made INSIDE it is lost, and every locked worktree paid for two gc calls.
# The callers must fetch before opening that subshell, and hand the verdict on
# instead of recomputing it.
log "Checking the fetch happens before the classify subshell, and the verdict is handed on..."
_body reap_zombie_locked | grep -qF '_session_list_ensure' \
  || fail "reap_zombie_locked does not call _session_list_ensure in the main shell (memo would die in the subshell)"
_body reap_zombie_locked | grep -qF '_ZL_VERDICT="$verdict"' \
  || fail "reap_zombie_locked no longer hands its verdict to the caller via _ZL_VERDICT"
[[ "$(grep -cF '"$_ZL_VERDICT"' "$REAPER")" -ge 2 ]] \
  || fail "the call sites no longer pass \$_ZL_VERDICT into _reap_or_log_unparseable_lock (lock classified twice again)"
log "  main-shell fetch + verdict hand-off ✓"

# ── 3c. Free text in the log goes through the escaper ─────────────────────────
# A lock reason with a quote or backslash used to write invalid JSON into the log.
log "Checking lock events are built by the escaping helper (no raw printf of the reason)..."
grep -q '^_json_esc() {' "$REAPER" || fail "_json_esc() missing"
grep -q '^_log_lock_event() {' "$REAPER" || fail "_log_lock_event() missing"
if _body _reap_or_log_unparseable_lock | grep -q 'printf .*event'; then
  fail "_reap_or_log_unparseable_lock builds a log line with a raw printf — free text (the lock reason) must go through _log_lock_event"
fi
log "  escaped ✓"

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
# LIVE functions and exercises them against a hermetic fake session list, a
# fake `gc` on PATH (counting calls; healthy / failing / hanging / garbage),
# and a fake process table across the full existing suite: every pre-existing
# zombie-lock/dirty-preserve/merged-fast-path/multi-root scenario, plus the
# ga-vs6shu ones (the measured bug, the pool-slot-reuse subtlety, both call
# sites, the unavailable-session-list third state, one fetch per sweep, JSON
# log escaping, bare locks). The selftest pins disk-pressure OFF itself
# (WORKTREE_REAPER_PRESSURE_FREE_GB=0), so this step no longer goes red merely
# because the box is short of disk — the state this reaper exists for.
log "Running worktree-reaper.selftest.sh against the deployed reaper (this builds many temp git repos, can take a few minutes under load)..."
bash "$SELFTEST" || fail "worktree-reaper.selftest.sh reported failures"
log "  selftest PASS ✓"

log "PASS"
exit 0

#!/usr/bin/env bash
# prod-tests/gascity/story-ga-7f6cmc.sh — prod test for ga-7f6cmc:
# git-deploy-pull.selftest.sh's D2/G2 (and D1/G1/H) race loops background two
# real processes per iteration and `wait` on each with NO ceiling — under
# sustained high system load (observed load avg ~36-38 while verifying
# ga-4vb24i) either racer can wedge for minutes, hanging the whole
# 30-iteration loop until something outside the script kills it. Confirmed
# unrelated to any git-deploy-pull.sh code defect: reproduced on the
# unchanged script under the same load.
#
# Fix: every racer/interloper across D/D1/D2/G1/G2/H is now wrapped in a
# run_bounded() helper (gtimeout/timeout, falling back to a python3
# subprocess bound, fail-closed if neither exists — mirrors the dolt pack's
# own run_bounded idiom without sourcing its unrelated port-resolution
# dependency). A bound trip (rc=124) is treated as a third, distinct state —
# "environment overload, inconclusive" — never collapsed into pass or fail
# (same discipline as ga-gquc1's run_bounded-timeout-vs-real-failure fix).
#
# Verifies the fix on the DEPLOYED git-deploy-pull.selftest.sh: the helper
# and its config are present, then — the load-bearing check — extracts and
# runs the REAL deployed run_bounded against a deliberately-hung command,
# proving it actually gets killed within its bound rather than merely
# "looking right" structurally. Finally re-runs the feature's own selftest
# end-to-end as a regression guard (itself time-boxed, so a regression here
# can't re-hang the delivery pipeline that is verifying the anti-hang fix).
#
# Called by run.sh after deploy (STORY_ID=ga-7f6cmc). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
SELFTEST="$CITY/packs/town-deltas/assets/scripts/git-deploy-pull.selftest.sh"

log()  { echo "[prod-test:gascity ga-7f6cmc] $*"; }
fail() { echo "[prod-test:gascity ga-7f6cmc] FAIL: $*" >&2; exit 1; }

[[ -f "$SELFTEST" ]] || fail "selftest missing: $SELFTEST"

log "Checking the bounded-execution helper is present..."
grep -qF 'run_bounded()' "$SELFTEST" \
  || fail "run_bounded() not found in deployed git-deploy-pull.selftest.sh — the fix did not deploy"
grep -qF 'RACE_STEP_TIMEOUT_SEC' "$SELFTEST" \
  || fail "RACE_STEP_TIMEOUT_SEC not found in deployed git-deploy-pull.selftest.sh"
log "  run_bounded() + RACE_STEP_TIMEOUT_SEC present ✓"

log "Checking every race loop actually calls run_bounded (not just defines it)..."
# D/D1, G1's own racers, and G2/H's raw interloper fetch call run_bounded
# directly; D2/G2/H's wrapper-script racers get it for free via run_script()
# itself. Count MATCHING LINES (grep -c), not just presence — so a partial
# revert (helper added but not wired into a loop) is caught. NOTE: this counts
# lines, not raw occurrences — G1's `fetch && merge` racer calls run_bounded
# twice on one line, which grep -c counts once. Exactly 7 lines exist today
# (run_script, D1's pull, D1's fetch, G1's combined fetch&&merge, G1's
# interloper fetch, G2's interloper fetch, H's interloper fetch) — pinned
# exactly, not >=, so dropping any one of them (including the easy-to-miss
# double-call G1 line) is caught, not just a wholesale revert.
CALL_SITES=$(grep -c 'run_bounded "\$RACE_STEP_TIMEOUT_SEC"' "$SELFTEST" || true)
[[ "$CALL_SITES" -eq 7 ]] \
  || fail "expected run_bounded to be called on exactly 7 lines (run_script + D1's 2 racers + G1's combined racer line + G1's interloper + G2's interloper + H's interloper), found $CALL_SITES — looks like a partial revert"
log "  $CALL_SITES call sites ✓"

log "Falsifying check: the REAL deployed run_bounded must kill a hung command within its bound (not just look right)..."
# Extract the exact deployed TIMEOUT_BIN-resolution + run_bounded block
# (between the ga-7f6cmc marker comment and the RACE_STEP_TIMEOUT_SEC
# config line that follows it) and run it standalone — this proves the
# SHIPPED code enforces the bound, not a reimplementation of it here.
EXTRACT="/tmp/.story-ga-7f6cmc-run_bounded.$$.sh"
awk '/^if command -v gtimeout/{p=1} p{print} /^RACE_STEP_TIMEOUT_SEC=/{exit}' "$SELFTEST" > "$EXTRACT"
if ! grep -qF 'run_bounded()' "$EXTRACT"; then
  rm -f "$EXTRACT"
  fail "could not extract run_bounded from the deployed selftest (marker/structure changed) — cannot run the falsifying check"
fi
FALSIFY_OUT=$(bash -c '
  source "'"$EXTRACT"'"
  START=$(date +%s)
  run_bounded 2 sleep 30
  RC=$?
  ELAPSED=$(( $(date +%s) - START ))
  echo "rc=$RC elapsed=${ELAPSED}s"
' 2>&1)
rm -f "$EXTRACT"
log "  $FALSIFY_OUT"
FALSIFY_RC=$(printf '%s' "$FALSIFY_OUT" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')
FALSIFY_ELAPSED=$(printf '%s' "$FALSIFY_OUT" | sed -n 's/.*elapsed=\([0-9]*\)s.*/\1/p')
[[ "$FALSIFY_RC" == "124" ]] \
  || fail "run_bounded did not return rc=124 for a 30s sleep bounded to 2s (got rc=$FALSIFY_RC) — the deployed helper is not actually bounding anything"
[[ -n "$FALSIFY_ELAPSED" && "$FALSIFY_ELAPSED" -lt 10 ]] \
  || fail "run_bounded took ${FALSIFY_ELAPSED}s to kill a 2s-bounded command (expected well under the unbounded 30s) — --kill-after grace or timeout resolution is broken"
log "  hung command killed in ${FALSIFY_ELAPSED}s (rc=124), not left to run its full 30s ✓"

log "Running the feature's own selftest (regression guard, itself time-boxed)..."
SELFTEST_LOG="/tmp/.story-ga-7f6cmc-selftest.$$.log"
if command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; else TIMEOUT_BIN="timeout"; fi
# NOTE: deliberately not `if ! cmd; then RC=$?; ...` — `$?` inside that
# `then` block reflects the `!` negation's own synthesized status (always 0
# there, since entering `then` means the negated condition was true), never
# the wrapped command's real exit code. Run it as a plain statement instead
# so `$?` right after is genuinely the timeout/gtimeout exit status.
"$TIMEOUT_BIN" --kill-after=5 240 bash "$SELFTEST" >"$SELFTEST_LOG" 2>&1
RC=$?
if [[ "$RC" -ne 0 ]]; then
  tail -30 "$SELFTEST_LOG" >&2
  rm -f "$SELFTEST_LOG"
  if [[ "$RC" -eq 124 ]]; then
    fail "selftest itself hung past its 240s time-box — this would be exactly the class of bug ga-7f6cmc fixes, regressed"
  fi
  fail "selftest did not pass on the deployed artifact"
fi
rm -f "$SELFTEST_LOG"
log "  selftest PASS ✓"

log "PASS — race-loop timeout bound deployed, proven to kill a hung process, and full selftest still green"
exit 0

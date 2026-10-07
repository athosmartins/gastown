#!/usr/bin/env bash
# prod-tests/gascity/story-ga-9t9acg.10.sh — prod test for ga-9t9acg.10: the context-check sweep judges the beads of ALL
# stores in ONE order (priority > type > age, scripts/work-order.sh) and applies its per-sweep cap AFTER that order.
#
# Before: the sweep took the stores one after the other (HQ first), FIFO inside each, and stopped at the global cap, so a
# P0 feature of the WA store was never judged while HQ had a backlog (measured 2026-10-06: HQ 103 open, WA 214, cap 8).
#
# The dispatcher is not a resident daemon: launchd starts a fresh bash for every sweep, so once the file is on disk the next
# sweep runs the new code — nothing to restart. This test checks the DEPLOYED copy (the live tree, run in place):
#   1. structural: it sources the lib, orders with work_order_sort, fetches with --limit 0, has no sort of its own left;
#   2. the registry row of this consumer is gone and the registry lint is clean;
#   3. behavioral: the deployed selftest (two stores, backlog > cap, mutation controls, degraded-lib paths) passes.
#
# Called by run.sh after deploy (STORY_ID=ga-9t9acg.10). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISP="$ASSETS/context-check-dispatcher.sh"
SELFTEST="$ASSETS/context-check-dispatcher.selftest.sh"
LIB="$ASSETS/scripts/work-order.sh"
REGISTRY="$ASSETS/scripts/work-order.registry.tsv"

log()  { echo "[prod-test:gascity ga-9t9acg.10] $*"; }
fail() { echo "[prod-test:gascity ga-9t9acg.10] FAIL: $*" >&2; exit 1; }

[[ -f "$DISP" ]]     || fail "deployed context-check-dispatcher.sh missing: $DISP"
[[ -f "$SELFTEST" ]] || fail "deployed context-check-dispatcher.selftest.sh missing: $SELFTEST"
[[ -r "$LIB" ]]      || fail "deployed work-order.sh missing/unreadable: $LIB (the dispatcher would fall back to the gathered order)"
log "Deployed dispatcher + lib found: $DISP"

# Comment lines are not code: a comment may name the old idiom to explain the change.
CODE="$(grep -vE '^[[:space:]]*#' "$DISP")"

# ── 1. Structural ───────────────────────────────────────────────────────────────
grep -qF 'scripts/work-order.sh' <<<"$CODE" \
  || fail "deployed dispatcher does not source scripts/work-order.sh"
grep -qF 'work_order_sort --age created' <<<"$CODE" \
  || fail "deployed dispatcher does not order with 'work_order_sort --age created'"
grep -qE 'sort_by\(\.created_at' <<<"$CODE" \
  && fail "deployed dispatcher still carries an ad-hoc sort_by(.created_at ...) — the old per-store FIFO is back"
FETCH="$(awk '/^_fetch_type\(\)/{f=1} f{print} /^}/{if(f)exit}' "$DISP")"
grep -qF -- '--limit 0' <<<"$FETCH" \
  || fail "deployed _fetch_type does not pass --limit 0 (a window taken before the order hides P0 features)"
grep -qF 'for CC_STORE in $CONTEXT_CHECK_STORES; do' <<<"$CODE" || fail "gather loop over the stores not found (file changed shape?)"
# The cap check must not sit in the store-gathering loop any more: that is what let store order beat priority.
GATHER="$(awk '/^for CC_STORE in \$CONTEXT_CHECK_STORES; do/{f=1} f{print} /^done/{if(f)exit}' "$DISP")"
grep -qF 'CONTEXT_CHECK_MAX_PER_SWEEP' <<<"$GATHER" \
  && fail "the per-sweep cap is checked inside the store-gathering loop again — a store would be cut off before the order"
log "dispatcher sources the lib, orders with it, fetches with --limit 0, cap applied after the order ✓"

# ── 2. Registry: this consumer's row is gone, the lint is clean ────────────────────
grep -qE '^consumer[[:space:]]+packs/town-deltas/assets/context-check-dispatcher\.sh[[:space:]]' "$REGISTRY" \
  && fail "the context-check-dispatcher.sh consumer row is still in work-order.registry.tsv"
( cd "$CITY" && python3 -I scripts/work_order.py lint >/dev/null 2>&1 ) \
  || fail "work_order.py lint is not clean on the deployed tree (run: cd $CITY && python3 -I scripts/work_order.py lint)"
log "registry row removed, lint clean ✓"

# ── 3. Behavioral: the deployed selftest, which runs the real dispatcher on a two-store fixture ──
OUT="$(timeout 280 bash "$SELFTEST" 2>&1)"
RC=$?
SUMMARY="$(grep -E 'selftest: PASS=' <<<"$OUT" | tail -1)"
[[ $RC -eq 0 ]] || { echo "$OUT" | grep -E '✗|FATAL' | head -20 >&2; fail "deployed context-check-dispatcher.selftest.sh failed (rc=$RC): ${SUMMARY:-no summary line}"; }
grep -qE 'Scenario 14: ga-9t9acg\.10' <<<"$OUT" || fail "deployed selftest has no Scenario 14 (ga-9t9acg.10) — the story's test did not deploy"
log "deployed selftest passes with Scenario 14: $SUMMARY ✓"

log "PASS"
exit 0

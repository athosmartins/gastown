#!/usr/bin/env bash
# prod-tests/gascity/story-ga-9t9acg.9.sh — prod test for ga-9t9acg.9: the refino-review queue (refino-gate-dispatcher.sh, R10)
# picks the story to review first by the town's work order (priority > type > age, scripts/work-order.sh), not by plain FIFO.
#
# Before: `sort_by(.created_at // .id) | .[0]` — a P0 story refined today waited behind every older P2 one.
#
# The dispatcher is not a resident daemon: launchd starts a fresh bash for every sweep, so once the file is on disk the next
# sweep runs the new code — nothing to restart. This test checks the DEPLOYED copy (the live tree, run in place):
#   1. structural: it sources the lib, orders with work_order_sort + work_order_head, fetches the queue with --limit 0 and
#      has no ad-hoc sort of the queue left;
#   2. the registry row of this consumer is gone and the registry lint is clean;
#   3. behavioral: the deployed selftest (P0 vs old P2, two P0s, unreadable priority, degraded-lib paths, mutation controls)
#      passes.
#
# Called by run.sh after deploy (STORY_ID=ga-9t9acg.9). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISP="$ASSETS/refino-gate-dispatcher.sh"
SELFTEST="$ASSETS/refino-gate-dispatcher.selftest.sh"
LIB="$ASSETS/scripts/work-order.sh"
REGISTRY="$ASSETS/scripts/work-order.registry.tsv"

log()  { echo "[prod-test:gascity ga-9t9acg.9] $*"; }
fail() { echo "[prod-test:gascity ga-9t9acg.9] FAIL: $*" >&2; exit 1; }

[[ -f "$DISP" ]]     || fail "deployed refino-gate-dispatcher.sh missing: $DISP"
[[ -f "$SELFTEST" ]] || fail "deployed refino-gate-dispatcher.selftest.sh missing: $SELFTEST"
[[ -r "$LIB" ]]      || fail "deployed work-order.sh missing/unreadable: $LIB (the dispatcher would fall back to the gathered order)"
log "Deployed dispatcher + lib found: $DISP"

# Comment lines are not code: a comment may name the old idiom to explain the change.
CODE="$(grep -vE '^[[:space:]]*#' "$DISP")"

# ── 1. Structural ───────────────────────────────────────────────────────────────
grep -qF 'scripts/work-order.sh' <<<"$CODE" \
  || fail "deployed dispatcher does not source scripts/work-order.sh"
grep -qF 'work_order_sort --age created' <<<"$CODE" \
  || fail "deployed dispatcher does not order with 'work_order_sort --age created'"
grep -qE '\| work_order_head' <<<"$CODE" \
  || fail "deployed dispatcher does not take the first story with work_order_head"
grep -qE 'sort_by\(\.created_at // \.id\)' <<<"$CODE" \
  && fail "deployed dispatcher still carries 'sort_by(.created_at // .id)' — the old FIFO pick is back"
# The queue list (the one with the exclusions that keep a story out of the queue) must ask for the whole queue.
QLIST="$(awk '/list --label story:refino-review --type feature --status open/{f=1} f{print} f && /--json/{exit}' "$DISP")"
grep -qF -- '--limit 0' <<<"$QLIST" \
  || fail "deployed queue list does not pass --limit 0 (a window taken before the order hides a P0 story)"
log "dispatcher sources the lib, orders with it, fetches with --limit 0, has no sort of its own ✓"

# ── 2. Registry: this consumer's row is gone, the lint is clean ────────────────────
grep -qE '^consumer[[:space:]]+packs/town-deltas/assets/refino-gate-dispatcher\.sh[[:space:]]' "$REGISTRY" \
  && fail "the refino-gate-dispatcher.sh consumer row is still in work-order.registry.tsv"
( cd "$CITY" && python3 -I scripts/work_order.py lint >/dev/null 2>&1 ) \
  || fail "work_order.py lint is not clean on the deployed tree (run: cd $CITY && python3 -I scripts/work_order.py lint)"
log "registry row removed, lint clean ✓"

# ── 3. Behavioral: the deployed selftest, which runs the real dispatcher end to end on fixture bd/gc ──
TO=""; command -v timeout >/dev/null 2>&1 && TO="timeout 280"   # optional on a box without it, like the selftest itself
OUT="$($TO bash "$SELFTEST" 2>&1)"
RC=$?
SUMMARY="$(grep -E 'selftest: PASS=' <<<"$OUT" | tail -1)"
[[ $RC -eq 0 ]] || { echo "$OUT" | grep -E '✗|FATAL' | head -20 >&2; fail "deployed refino-gate-dispatcher.selftest.sh failed (rc=$RC): ${SUMMARY:-no summary line}"; }
grep -qE 'ga-9t9acg\.9 \(B9a\)' <<<"$OUT" || fail "deployed selftest has no B9a (ga-9t9acg.9) — the story's test did not deploy"
grep -qE 'ga-9t9acg\.9 \(B9g\)' <<<"$OUT" || fail "deployed selftest has no B9g mutation controls (ga-9t9acg.9)"
log "deployed selftest passes with the B9 order tests: $SUMMARY ✓"

log "PASS"
exit 0

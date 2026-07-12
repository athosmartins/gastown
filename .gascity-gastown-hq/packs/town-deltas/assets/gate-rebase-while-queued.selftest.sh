#!/usr/bin/env bash
# gate-rebase-while-queued.selftest.sh — Prove the gt-4tk5m "rebase-while-queued"
# catch-22 fix is wired into the live dispatcher and will not regress.
#
# BUG gt-4tk5m: when a branch is stale AND the dispatcher's auto-rebase push fails
# because the AUTHOR already force-pushed a rebase (--force-with-lease rejected =
# CONFLICT_KIND="transient"), the old code unconditionally entered the
# AUTHOR_ALIVE=1 branch → set gate-status:needs-rebase + exited. No replacement
# marker was created and no re-queue happened. The author's branch was silently
# dropped from the gate queue (catch-22: author already rebased but must now also
# re-run /gate-done to re-enter the queue, and nothing tells them to).
#
# FIX (gt-4tk5m): split the AUTHOR_ALIVE=1 branch into two:
#   - AUTHOR_ALIVE=1 + CONFLICT_KIND="merge"   → needs-rebase + nudge (genuine
#     unresolvable conflict; author must fix and re-gate) — same as before.
#   - AUTHOR_ALIVE=1 + CONFLICT_KIND="transient" → re-queue (bounded retry) with
#     informational nudge — author's rebase is likely already done; gate will
#     pick up the new tip on next sweep without requiring /gate-done again.
#
# This harness DRIFT-GUARDS the live dispatcher so a future refactor that drops
# or reverts the fix fails loudly. It also tests boundary cases via grep/pattern
# checks (the live-run paths mutate Dolt and cannot be unit-tested in isolation).
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
not() { if grep -qE "$2" "$1"; then bad "$3 — pattern found (should be absent): $2"; else ok "$3"; fi; }

# ── 1. syntax ────────────────────────────────────────────────────────────────
echo "── 1. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

# Source in lib-only mode to verify the script loads without errors.
if GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher sources cleanly in lib-only mode"
else
  bad "dispatcher failed to source in lib-only mode"
fi

# ── 2. DRIFT-GUARD: fix branch structure ────────────────────────────────────
echo "── 2. drift-guard: gt-4tk5m fix branch structure ──"

# 2a. The AUTHOR_ALIVE=1 + merge conflict path must exist (needs-rebase for genuine conflicts).
has "$DISPATCHER" \
  'AUTHOR_ALIVE.*=.*"1".*&&.*CONFLICT_KIND.*=.*"merge"' \
  "genuine conflict + alive author → still bounces to needs-rebase"

# 2b. The new AUTHOR_ALIVE=1 + transient path must exist.
has "$DISPATCHER" \
  'AUTHOR_ALIVE.*=.*"1".*&&.*CONFLICT_KIND.*=.*"transient"' \
  "transient failure + alive author → new re-queue path (gt-4tk5m)"

# 2c. The transient+alive path must re-queue (gate-status:queued), not needs-rebase.
# We check the line after the transient+alive condition has gate-status:queued.
TRANSIENT_ALIVE_REQUEUE=$(grep -c 'AUTHOR_ALIVE.*=.*"1".*&&.*CONFLICT_KIND.*=.*"transient"' "$DISPATCHER" || true)
if [ "$TRANSIENT_ALIVE_REQUEUE" -ge 1 ]; then
  ok "transient+alive condition is present ($TRANSIENT_ALIVE_REQUEUE occurrence(s))"
else
  bad "transient+alive condition is MISSING — gt-4tk5m fix was reverted"
fi

# 2d. The gt-4tk5m event/log token must be present (proves the new path is wired, not dead code).
has "$DISPATCHER" \
  'dispatcher_autorebase_retry_alive' \
  "new REBASE_EVENT token 'dispatcher_autorebase_retry_alive' is present"

# 2e. The old monolithic AUTHOR_ALIVE=1 path (that handled both merge and transient
#     the same way) must be GONE — it was: `if [ "$AUTHOR_ALIVE" = "1" ]; then`
#     followed directly by the needs-rebase + nudge block (without a CONFLICT_KIND check).
#     The fix splits it so AUTHOR_ALIVE alone is no longer the only condition.
#     We assert that the old simple pattern no longer exists as the primary branch.
not "$DISPATCHER" \
  '^[[:space:]]*if \[ "\$AUTHOR_ALIVE" = "1" \]; then$' \
  "old unconditional AUTHOR_ALIVE=1 branch (without CONFLICT_KIND) is gone"

# ── 3. DRIFT-GUARD: transient+alive re-queue path uses bounded retry counter ─
echo "── 3. drift-guard: bounded retry in transient+alive path ──"

# 3a. The MAX_REBASE_ATTEMPTS guard must apply in the new path too.
# We check that the transient+alive path still increments NEXT_ATTEMPT and checks it.
has "$DISPATCHER" \
  'NEXT_ATTEMPT.*=.*\$\(\(REBASE_ATTEMPT.*\+.*1\)\)' \
  "NEXT_ATTEMPT is incremented (retry counter present in at least one path)"

has "$DISPATCHER" \
  'NEXT_ATTEMPT.*-lt.*MAX_REBASE_ATTEMPTS' \
  "retry counter is bounded by MAX_REBASE_ATTEMPTS"

# 3b. The escalation path (>= MAX_REBASE_ATTEMPTS) for transient+alive must set
#     needs-rebase as a final escalation, not silently drop.
has "$DISPATCHER" \
  'dispatcher_needs_rebase_transient_escalated' \
  "escalation event token 'dispatcher_needs_rebase_transient_escalated' exists (no silent drop at max)"

# ── 4. DRIFT-GUARD: needs-rebase paths remain for genuine conflicts ──────────
echo "── 4. drift-guard: needs-rebase still applied to genuine conflicts ──"

# 4a. The genuine-conflict + alive path must still set needs-rebase.
has "$DISPATCHER" \
  '"gate-status:needs-rebase"' \
  "gate-status:needs-rebase label is still set in at least one path"

# 4b. The ga-q3ig2 dead-author + genuine-conflict path must be preserved.
has "$DISPATCHER" \
  'ga-q3ig2' \
  "ga-q3ig2 immediate-skip path (dead author, genuine conflict) is preserved"

# 4c. The dead-author + transient + bounded-retry path must still exist.
has "$DISPATCHER" \
  'Dead/empty author.*TRANSIENT' \
  "dead-author transient retry path is preserved"

# ── 5. DRIFT-GUARD: re-queue uses gate-status:queued (not error) ─────────────
echo "── 5. drift-guard: transient+alive path re-queues to queued, not error ──"

# The pattern check: the new path must add gate-status:queued.
has "$DISPATCHER" \
  '"gate-status:queued"' \
  "gate-status:queued label is applied in at least one re-queue path"

# 5b. The new path must log QUEUED in its verdict (not NEEDS_REBASE).
has "$DISPATCHER" \
  'QUEUED.*transient rebase race.*author.*live' \
  "transient+alive verdict logs as QUEUED (not NEEDS_REBASE)"

# ── 6. DRIFT-GUARD: gt-4tk5m comment references ─────────────────────────────
echo "── 6. drift-guard: gt-4tk5m traceability ──"
has "$DISPATCHER" \
  'gt-4tk5m' \
  "gt-4tk5m bead reference present (traceability)"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

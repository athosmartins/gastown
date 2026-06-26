#!/usr/bin/env bash
# quality-gate-park-unapproved.selftest.sh — Prove the gate gap fix (Step 5a) that
# parks markers whose source-bead is story:needs-approval or gate:needs-human.
#
# Problem (wa-x9ooo class): a crew re-submitted a gate marker for a bead carrying
# story:needs-approval + gate:needs-human 3+ times. Each re-submit created a fresh
# marker, the guard claimed it, spawned reviewers, they failed, the cycle repeated.
# The 4 duplicate markers HOL-blocked the gate (merge-stall).
#
# Fix (Step 5a in quality-gate-guard.sh): after AUTHOR is resolved but BEFORE the
# gate-run tracking bead is created (Step 6), fetch the source-bead's labels from
# BEAD_RAW (already in scope from Step 5) and run check_source_bead_park.
# If the result is not "ok", park the marker (gate-status:parked-needs-human +
# bd close) and exit without creating the gate-run or spawning reviewers.
#
# gate:needs-fix ALONE must NOT be parked — it is the normal fix-iterate path
# (the crew fixed the bead and re-submitted; the gate should review it).
#
# This harness SOURCES the guard in lib-only mode to unit-test the REAL pure
# function (check_source_bead_park), then drift-guards the live script.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the pure function from the guard (no live sweep) ────────────────────
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type check_source_bead_park >/dev/null 2>&1 \
  || { echo "FATAL: check_source_bead_park not defined by guard (Step 5a missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. story:needs-approval → always park (never approved) ───────────────────
echo "── 1. story:needs-approval → park ──"
eq "needs-approval alone → park" \
  "$(check_source_bead_park 'story:needs-approval')" \
  "park:needs-approval"
eq "needs-approval + gate:needs-fix → park (approval blocks, not fix)" \
  "$(check_source_bead_park 'story:needs-approval gate:needs-fix')" \
  "park:needs-approval"
eq "needs-approval + gate:needs-human → park (needs-approval checked first)" \
  "$(check_source_bead_park 'story:needs-approval gate:needs-human')" \
  "park:needs-approval"
eq "other labels + needs-approval → park" \
  "$(check_source_bead_park 'lane:small tech-debt story:needs-approval gate:fix-attempt:3')" \
  "park:needs-approval"

# ── 2. gate:needs-human → always park (circuit-broken) ───────────────────────
echo "── 2. gate:needs-human → park ──"
eq "gate:needs-human alone → park" \
  "$(check_source_bead_park 'gate:needs-human')" \
  "park:needs-human"
eq "gate:needs-human:fix-attempt:3 (wildcard suffix) → park" \
  "$(check_source_bead_park 'gate:needs-human:fix-attempt:3')" \
  "park:needs-human"
eq "gate:needs-human + gate:needs-fix → park (needs-human checked before needs-fix)" \
  "$(check_source_bead_park 'gate:needs-human gate:needs-fix')" \
  "park:needs-human"
eq "story:approved + gate:needs-human → park (circuit-break wins over approval)" \
  "$(check_source_bead_park 'story:approved gate:needs-human')" \
  "park:needs-human"

# ── 3. CRITICAL safety: story:approved path MUST pass through (no false park) ─
echo "── 3. story:approved → ok (normal gate path must not be blocked) ──"
eq "story:approved alone → ok" \
  "$(check_source_bead_park 'story:approved')" \
  "ok"
eq "story:approved + lane:small → ok" \
  "$(check_source_bead_park 'story:approved lane:small')" \
  "ok"
eq "story:approved + gate:needs-fix → ok (fix-iterate path, must pass)" \
  "$(check_source_bead_park 'story:approved gate:needs-fix')" \
  "ok"
eq "story:approved + gate:needs-fix + gate:fix-attempt:2 → ok" \
  "$(check_source_bead_park 'story:approved gate:needs-fix gate:fix-attempt:2')" \
  "ok"

# ── 4. gate:needs-fix alone → ok (fix-iterate path, must pass) ───────────────
echo "── 4. gate:needs-fix alone → ok (distinguish from gate:needs-human) ──"
eq "gate:needs-fix alone → ok" \
  "$(check_source_bead_park 'gate:needs-fix')" \
  "ok"
eq "gate:needs-fix + gate:fix-attempt:1 → ok" \
  "$(check_source_bead_park 'gate:needs-fix gate:fix-attempt:1')" \
  "ok"
eq "gate:needs-fix + gate:fix-attempt:3 (at-cap) → ok (dispatch still ok)" \
  "$(check_source_bead_park 'gate:needs-fix gate:fix-attempt:3')" \
  "ok"

# ── 5. Edge cases: empty / unknown labels → ok (fail-open) ───────────────────
echo "── 5. edge cases → ok (fail-open: unknown=no block) ──"
eq "empty labels → ok (fail-open)" \
  "$(check_source_bead_park '')" \
  "ok"
eq "unrelated labels only → ok" \
  "$(check_source_bead_park 'lane:small type:feature priority:high')" \
  "ok"
eq "label that is a PREFIX of needs-approval → ok (no substring match)" \
  "$(check_source_bead_park 'story:needs')" \
  "ok"
eq "label that is a PREFIX of needs-human → ok (no substring match)" \
  "$(check_source_bead_park 'gate:needs')" \
  "ok"

# ── 6. Drift-guards: guard implements Step 5a in the live sweep ───────────────
echo "── 6. drift-guard: guard implements Step 5a park check ──"
grep -q 'check_source_bead_park()'           "$GUARD" \
  && ok "guard defines check_source_bead_park" \
  || bad "guard missing check_source_bead_park def"
grep -q 'story:needs-approval'               "$GUARD" \
  && ok "guard checks story:needs-approval in check_source_bead_park" \
  || bad "guard missing story:needs-approval check"
grep -qE 'gate:needs-human\|gate:needs-human:\*' "$GUARD" \
  && ok "guard checks gate:needs-human (exact + wildcard suffix)" \
  || bad "guard missing gate:needs-human wildcard check"
grep -q 'park:needs-approval'                "$GUARD" \
  && ok "guard emits park:needs-approval" \
  || bad "guard missing park:needs-approval return"
grep -q 'park:needs-human'                   "$GUARD" \
  && ok "guard emits park:needs-human" \
  || bad "guard missing park:needs-human return"
grep -q 'Step 5a'                            "$GUARD" \
  && ok "guard has Step 5a annotation" \
  || bad "guard missing Step 5a annotation"
grep -q 'PARK_ACTION'                        "$GUARD" \
  && ok "guard wires PARK_ACTION in live sweep" \
  || bad "guard does not use PARK_ACTION variable"
grep -q 'parked-needs-human'                 "$GUARD" \
  && ok "guard uses gate-status:parked-needs-human terminal label" \
  || bad "guard missing parked-needs-human label"
# The park path must close the marker (terminal ⇒ closed, ga-jhyu invariant).
# close and the reason string are on separate lines (bash line continuation),
# so grep separately: one for 'close "$MARKER_ID"' and one for the Step 5a tag.
grep -q 'close "\$MARKER_ID"'               "$GUARD" \
  && ok "guard closes the marker at park (ga-jhyu terminal invariant)" \
  || bad "guard does not close the marker in Step 5a — stranded open"
grep -q 'marker parked (terminal)'          "$GUARD" \
  && ok "guard close carries 'marker parked (terminal)' reason string" \
  || bad "guard missing 'marker parked (terminal)' in close reason"
# The check fires BEFORE Step 6 (gate-run creation) — verify ordering by checking
# that the Step 5a section header precedes the canonical "# ── Step 6:" header.
STEP5A_LINE=$(grep -n '# ── Step 5a:' "$GUARD" | head -1 | cut -d: -f1)
STEP6_LINE=$(grep -n '# ── Step 6:' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$STEP5A_LINE" ] && [ -n "$STEP6_LINE" ] && [ "$STEP5A_LINE" -lt "$STEP6_LINE" ]; then
  ok "Step 5a park check fires BEFORE Step 6 (gate-run creation) — no reviewer spawned"
else
  bad "Step 5a/Step 6 ordering wrong (5a must precede 6): 5a=${STEP5A_LINE:-missing} 6=${STEP6_LINE:-missing}"
fi
# FAIL-OPEN guard: the check is wrapped in `if [ -n "$BEAD_RAW" ]` so a lookup
# failure never blocks a legitimate submission.
grep -qE 'if \[ -n "\$BEAD_RAW" \]' "$GUARD" \
  && ok "park check is FAIL-OPEN (guarded by non-empty BEAD_RAW)" \
  || bad "park check is NOT fail-open (no BEAD_RAW guard — could block on lookup failure)"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

#!/usr/bin/env bash
# gate-6aj348-recall-bar.selftest.sh — Drift-guard for ga-6aj348: replace the
# reviewer's "DROP it" / "be conservative" refutation-pass framing with a
# concrete blocking bar, per the Sonnet 5 review-harness guidance (ga-ttwzqd):
# an instruction like "report only high severity / be conservative" measurably
# hurts recall. The fix is a concrete bar of what blocks (WHAT BLOCKS / WHAT
# DOES NOT BLOCK), a low-confidence directive to re-read instead of silencing
# a finding, and a place for non-blocking findings to be reported (severity-
# tagged) instead of silently dropped. The refutation pass itself stays — but
# only as a FACT check ("does the defect exist?"), never as a severity filter.
#
# This harness statically greps quality-gate-dispatcher.sh's REVIEW_TASK
# heredoc (the literal prompt text nudged to each reviewer session) so a
# future refactor that reintroduces the suppressive framing, or drops the
# concrete bar, fails loudly. No live Dolt/gc/launchd — pure grep + bash -n.
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has()    { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
hasnot() { if grep -qE "$2" "$1"; then bad "$3 — forbidden pattern present: $2"; else ok "$3"; fi; }

echo "── 1. COMPILE-GUARD: dispatcher parses cleanly ──"
if bash -n "$GATE" 2>/dev/null; then ok "dispatcher: bash -n clean"; else bad "dispatcher: bash -n FAILED"; fi

echo "── 2. OLD SUPPRESSIVE FRAMING IS GONE ──"
hasnot "$GATE" 'If you cannot ground a blocking issue in specific' \
  "the ungrounded 'DROP it' instruction is gone"
hasnot "$GATE" 'REFUTATION PASS — MANDATORY BEFORE ANY FAIL' \
  "old 'MANDATORY BEFORE ANY FAIL' heading is gone"

echo "── 3. CONCRETE BLOCKING BAR REACHES THE REVIEWER PROMPT ──"
has "$GATE" 'WHAT BLOCKS \(verdict FAIL\)' \
  "concrete WHAT BLOCKS bar is present"
has "$GATE" 'incorrect behavior, a failing test, data loss, or a' \
  "blocking bar names incorrect behavior / failing test / data loss"
has "$GATE" 'misleading result/log/comment' \
  "blocking bar names misleading result/log/comment"
has "$GATE" 'WHAT DOES NOT BLOCK' \
  "explicit non-blocking bar (style/naming) is present"

echo "── 4. REFUTATION PASS IS A FACT-CHECK, NOT A SEVERITY FILTER ──"
has "$GATE" 'FACT-CHECK, NOT A SEVERITY FILTER' \
  "refutation-pass heading names it a fact-check, not a severity filter"
has "$GATE" 'never a filter on how severe or' \
  "prompt states the refutation pass never filters on severity"

echo "── 5. LOW CONFIDENCE ⇒ RE-READ, NEVER SILENCE ──"
has "$GATE" 'never silence' \
  "low-confidence directive tells the reviewer to re-read, never silence a finding"

echo "── 6. NON-BLOCKING FINDINGS ARE REPORTED, NOT DROPPED SILENTLY ──"
has "$GATE" 'nothing you found gets dropped silently' \
  "prompt states findings are never dropped silently"
has "$GATE" "Non-blocking findings: <one per line" \
  "verdict-recording template has a Non-blocking findings slot"
# The slot must exist in BOTH the PASS and the FAIL comment templates — a
# single has() only proves >=1 occurrence, so count explicitly.
_NBF_COUNT=$(grep -cE "Non-blocking findings: <one per line" "$GATE")
if [ "$_NBF_COUNT" -ge 2 ]; then
  ok "Non-blocking findings slot present in BOTH PASS and FAIL templates ($_NBF_COUNT occurrences)"
else
  bad "Non-blocking findings slot present in BOTH PASS and FAIL templates — found $_NBF_COUNT, need >=2"
fi

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

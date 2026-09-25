#!/usr/bin/env bash
# prod-tests/gascity/story-ga-6aj348.sh — prod test for ga-6aj348: replace the
# gate reviewer's "DROP it" / "be conservative" refutation-pass framing with a
# concrete blocking bar.
#
# Origin: ga-ttwzqd (the Sonnet 5 prompting guide's code-review-harness
# section) — an instruction like "report only high severity / be
# conservative" measurably hurts Sonnet 5's recall. The old REVIEW_TASK
# heredoc in quality-gate-dispatcher.sh told each reviewer session to DROP any
# blocking issue it couldn't fully ground, with no concrete bar for what
# actually counts as blocking, and no place for a non-blocking finding to
# survive — a false negative (a missed real bug) had nowhere to go but
# silence. The fix keeps the refutation pass, but only as a FACT check ("does
# the defect exist?"), adds a concrete WHAT BLOCKS / WHAT DOES NOT BLOCK bar,
# tells the reviewer to re-read (never silence) on low confidence, and gives
# non-blocking findings an explicit severity-tagged slot in both the PASS and
# FAIL verdict-comment templates so they are recorded, not dropped.
#
# Verifies the DEPLOYED dispatcher directly (not a hand-copied re-assertion of
# the same claims), then runs the dedicated selftest end-to-end against it.
#
# Called by run.sh after deploy (STORY_ID=ga-6aj348). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/quality-gate-dispatcher.sh"
SELFTEST="$ASSETS/gate-6aj348-recall-bar.selftest.sh"

log()  { echo "[prod-test:gascity ga-6aj348] $*"; }
fail() { echo "[prod-test:gascity ga-6aj348] FAIL: $*" >&2; exit 1; }

[[ -f "$DISPATCHER" ]] || fail "missing: $DISPATCHER"
[[ -f "$SELFTEST" ]]   || fail "missing: $SELFTEST"
log "Deployed dispatcher + selftest found."

# ── 1. Syntax: the deployed dispatcher must still parse cleanly ────────────────
log "Checking dispatcher bash syntax..."
bash -n "$DISPATCHER" || fail "quality-gate-dispatcher.sh has a syntax error"
log "  syntax OK ✓"

# ── 2. The old suppressive instruction is gone from the DEPLOYED file ──────────
log "Checking the ungrounded 'DROP it' instruction is gone..."
grep -qF 'If you cannot ground a blocking issue in specific' "$DISPATCHER" \
  && fail "old ungrounded 'DROP it' sentence still present in the deployed dispatcher"
log "  gone ✓"

# ── 3. The concrete blocking bar reaches the deployed reviewer prompt ──────────
log "Checking the concrete WHAT BLOCKS / WHAT DOES NOT BLOCK bar is present..."
grep -qE 'WHAT BLOCKS \(verdict FAIL\)' "$DISPATCHER" \
  || fail "WHAT BLOCKS bar missing from the deployed dispatcher"
grep -qF 'WHAT DOES NOT BLOCK' "$DISPATCHER" \
  || fail "WHAT DOES NOT BLOCK bar missing from the deployed dispatcher"
log "  present ✓"

# ── 4. Non-blocking findings have a reporting slot in BOTH verdict templates ───
log "Checking the Non-blocking findings slot is wired into both PASS and FAIL..."
_NBF_COUNT=$(grep -cF "Non-blocking findings: <one per line" "$DISPATCHER")
[[ "$_NBF_COUNT" -ge 2 ]] \
  || fail "Non-blocking findings slot found in only $_NBF_COUNT template(s) of the deployed dispatcher, need >=2 (PASS + FAIL)"
log "  present in both ($_NBF_COUNT occurrences) ✓"

# ── 5. The dedicated selftest passes end-to-end against the deployed file ──────
# This is the real proof, not a restatement — gate-6aj348-recall-bar.selftest.sh
# statically drift-guards the full set of claims above (plus the fact-check-vs-
# severity-filter framing and the low-confidence re-read directive) against
# whatever quality-gate-dispatcher.sh is actually deployed at $ASSETS.
log "Running gate-6aj348-recall-bar.selftest.sh against the deployed dispatcher..."
bash "$SELFTEST" || fail "gate-6aj348-recall-bar.selftest.sh reported failures"
log "  selftest PASS ✓"

log "PASS"
exit 0

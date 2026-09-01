#!/usr/bin/env bash
# prod-tests/gascity/story-ga-faw5o.sh — prod test for ga-faw5o defeito 3:
# rebase-fail exile escalation watchdog.
#
# ga-faw5o's own DEFEITO 3 said gate:exiled-tier5 markers can sit starved
# forever in a queue that never empties, because the existing attempt-based
# escalation only runs when the marker is actually re-selected — which
# requires every healthy tier to be empty first. The fix adds
# gate_exile_watchdog_sweep(), a selection-independent wall-clock backstop
# wired into Step 0b of quality-gate-dispatcher.sh, before the quiet-hours/
# headroom admission gates.
#
# Verifies the DEPLOYED dispatcher: the function and its call site are
# present and correctly ordered, the file is still syntactically valid, and
# the dedicated selftest (which exercises the actual extracted function
# logic against mocked bd/gc/warn/set_gate_status) passes end-to-end against
# the live file — not a hand-copied re-assertion of the same claims.
#
# Called by run.sh after deploy (STORY_ID=ga-faw5o). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/quality-gate-dispatcher.sh"
SELFTEST="$ASSETS/gate-exile-watchdog.selftest.sh"

log()  { echo "[prod-test:gascity ga-faw5o] $*"; }
fail() { echo "[prod-test:gascity ga-faw5o] FAIL: $*" >&2; exit 1; }

[[ -f "$DISPATCHER" ]] || fail "missing: $DISPATCHER"
[[ -x "$SELFTEST" ]]   || fail "missing or not executable: $SELFTEST"

# ── 1. Syntax: the deployed dispatcher must still parse cleanly ────────────────
log "Checking dispatcher bash syntax..."
bash -n "$DISPATCHER" || fail "quality-gate-dispatcher.sh has a syntax error"
log "  syntax OK ✓"

# ── 2. The watchdog function and its SELFTEST-EXTRACT sentinels are present ────
log "Checking gate_exile_watchdog_sweep is defined and sentinel-wrapped..."
grep -q "^gate_exile_watchdog_sweep() {" "$DISPATCHER" \
  || fail "gate_exile_watchdog_sweep() definition missing"
grep -q "# SELFTEST-EXTRACT gate-exile-watchdog: BEGIN" "$DISPATCHER" \
  || fail "SELFTEST-EXTRACT gate-exile-watchdog BEGIN sentinel missing"
grep -q "# SELFTEST-EXTRACT gate-exile-watchdog: END" "$DISPATCHER" \
  || fail "SELFTEST-EXTRACT gate-exile-watchdog END sentinel missing"
log "  function + sentinels present ✓"

# ── 3. Step 0b-0 call site present, wired to the live MARKERS_JSON ─────────────
log "Checking the Step 0b-0 call site..."
grep -q 'gate_exile_watchdog_sweep "\$MARKERS_JSON"' "$DISPATCHER" \
  || fail "Step 0b-0 call site missing or not passing \$MARKERS_JSON"
log "  call site present ✓"

# ── 4. Ordering: watchdog runs BEFORE the quiet-hours admission pause ──────────
# This is the whole point of the fix — it must not be blocked by an admission
# gate, since it never admits new work, only notices/escalates existing exile
# state. A future edit that reorders these would silently reintroduce a
# window where quiet hours also suppress escalation.
log "Checking watchdog call precedes the quiet-hours admission gate..."
WATCHDOG_LINE=$(grep -n 'gate_exile_watchdog_sweep "\$MARKERS_JSON"' "$DISPATCHER" | head -1 | cut -d: -f1)
QUIET_HOURS_LINE=$(grep -n 'quiet-hours admission gate — PAUSE new-run admission' "$DISPATCHER" | head -1 | cut -d: -f1)
[[ -n "$WATCHDOG_LINE" && -n "$QUIET_HOURS_LINE" ]] || fail "could not locate both ordering anchors"
[[ "$WATCHDOG_LINE" -lt "$QUIET_HOURS_LINE" ]] \
  || fail "watchdog call (line $WATCHDOG_LINE) no longer precedes quiet-hours gate (line $QUIET_HOURS_LINE) — escalation could now be silently paused overnight"
log "  ordering OK (watchdog=$WATCHDOG_LINE < quiet-hours=$QUIET_HOURS_LINE) ✓"

# ── 5. The dedicated selftest passes end-to-end against this deployed file ─────
# This is the real proof, not a restatement — gate-exile-watchdog.selftest.sh
# extracts the LIVE function via the sentinels above and exercises it with
# mocked bd/gc/warn/set_gate_status across 14 scenarios (first-seen stamp,
# under/over/at-threshold, dedup, legacy label name, multi-marker sweep,
# malformed input, default threshold, mutation check, drift guards,
# mail-failure retry).
log "Running gate-exile-watchdog.selftest.sh against the deployed dispatcher..."
"$SELFTEST" || fail "gate-exile-watchdog.selftest.sh reported failures"
log "  selftest PASS ✓"

log "PASS"
exit 0

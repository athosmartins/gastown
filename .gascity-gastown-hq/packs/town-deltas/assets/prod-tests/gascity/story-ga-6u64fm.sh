#!/usr/bin/env bash
# prod-tests/gascity/story-ga-6u64fm.sh — prod test for ga-6u64fm: auto-
# migrate a rig-native bead the dog pool can never see, instead of only
# parking + asking a human to move it by hand (ga-cszxcf, 3rd occurrence).
#
# Adds two functions to pilot-dispatcher.sh:
#   _pilot_dog_store_blind_migrate_dest   — picks the destination rig
#   _pilot_migrate_dog_store_blind_bead   — the migration itself, with
#     TOCTOU re-check + orphan-copy retraction on a raced close (the exact
#     failure mode documented by the bead-migration-copy-races memory)
# and wires an attempt at the ga-cszxcf call site, BEFORE the pre-existing
# park behavior, which stays fully intact as the fallback on any abort.
#
# Verifies the DEPLOYED dispatcher directly (not a hand-copied re-assertion
# of the same claims), then runs the dedicated selftest end-to-end against
# it.
#
# Called by run.sh after deploy (STORY_ID=ga-6u64fm). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/pilot-dispatcher.sh"
SELFTEST="$ASSETS/pilot-dispatcher.dog-store-migrate.selftest.sh"

log()  { echo "[prod-test:gascity ga-6u64fm] $*"; }
fail() { echo "[prod-test:gascity ga-6u64fm] FAIL: $*" >&2; exit 1; }

[[ -f "$DISPATCHER" ]] || fail "missing: $DISPATCHER"
[[ -f "$SELFTEST" ]]   || fail "missing: $SELFTEST"
log "Deployed dispatcher + selftest found."

# ── 1. Syntax: the deployed dispatcher must still parse cleanly ────────────────
log "Checking dispatcher bash syntax..."
bash -n "$DISPATCHER" || fail "pilot-dispatcher.sh has a syntax error"
log "  syntax OK ✓"

# ── 2. Both new functions are defined in the DEPLOYED file ─────────────────────
log "Checking both new functions are defined..."
grep -q '^_pilot_dog_store_blind_migrate_dest() {' "$DISPATCHER" \
  || fail "_pilot_dog_store_blind_migrate_dest() definition missing from the deployed dispatcher"
grep -q '^_pilot_migrate_dog_store_blind_bead() {' "$DISPATCHER" \
  || fail "_pilot_migrate_dog_store_blind_bead() definition missing from the deployed dispatcher"
log "  present ✓"

# ── 3. Call-site wiring: attempt precedes the pre-existing park fallback ───────
log "Checking the migration attempt is wired in BEFORE the pre-existing park logic..."
grep -qE 'PILOT_DOG_STORE_AUTOMIGRATE:-1' "$DISPATCHER" \
  || fail "PILOT_DOG_STORE_AUTOMIGRATE kill switch missing from the deployed dispatcher"
grep -qF 'DISPATCH_RESULT="rig_native_dog_store_migrated"' "$DISPATCHER" \
  || fail "rig_native_dog_store_migrated DISPATCH_RESULT missing from the deployed dispatcher"
MIGRATE_LINE=$(grep -n '_pilot_migrate_dog_store_blind_bead "\$STORY_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
PARK_LINE=$(grep -n 'ga-cszxcf: REFUSING rig-native dispatch' "$DISPATCHER" | head -1 | cut -d: -f1)
[[ -n "$MIGRATE_LINE" && -n "$PARK_LINE" ]] || fail "could not locate both ordering anchors (migrate call site, park warn)"
[[ "$MIGRATE_LINE" -lt "$PARK_LINE" ]] \
  || fail "migration attempt (line $MIGRATE_LINE) no longer precedes the park logic (line $PARK_LINE) — a successful migration would no longer short-circuit parking"
log "  ordering OK (migrate=$MIGRATE_LINE < park=$PARK_LINE) ✓"

# ── 4. The pre-existing park fallback is still fully intact ────────────────────
# This is the safety net every abort path in the new code relies on — must
# never regress just because migration was added in front of it.
log "Checking the pre-existing park fallback is unchanged..."
grep -qF 'pilot:no-auto-dispatch' "$DISPATCHER" || fail "pilot:no-auto-dispatch park label missing"
grep -qF 'next-action:mayor' "$DISPATCHER" || fail "next-action:mayor park label missing"
grep -qF 'DISPATCH_RESULT="rig_native_dog_store_blind"' "$DISPATCHER" || fail "rig_native_dog_store_blind DISPATCH_RESULT missing"
log "  park fallback intact ✓"

# ── 5. The dedicated selftest passes end-to-end against the deployed file ──────
# This is the real proof, not a restatement — pilot-dispatcher.dog-store-
# migrate.selftest.sh extracts the LIVE functions via awk and exercises them
# against a PATH-stubbed fake bd across 11 scenarios (destination picking,
# TOCTOU re-check abort, create/readback/close failure handling, and the
# race-retraction recovery), plus drift-guards on the call-site wiring.
log "Running pilot-dispatcher.dog-store-migrate.selftest.sh against the deployed dispatcher..."
bash "$SELFTEST" || fail "pilot-dispatcher.dog-store-migrate.selftest.sh reported failures"
log "  selftest PASS ✓"

log "PASS"
exit 0

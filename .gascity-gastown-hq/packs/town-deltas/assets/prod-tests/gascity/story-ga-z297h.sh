#!/usr/bin/env bash
# prod-tests/gascity/story-ga-z297h.sh — prod test for ga-z297h: monthly
# storage inventory (Mac mini + key dirs + S3 + Drive SA quota + MotherDuck
# compute verdict), auto-written into the Atlas Part 0 doc + surfaced in the
# digest.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-z297h). Exits 0 on
# pass. Asserts against the LIVE deployed tree (gascity's scripts run in
# place — see delivery-runbooks.toml's own gascity rig comment) and against
# real, external, live state (launchd, and a durable bead record) where a
# file check alone can't prove the thing actually took effect.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BD_BIN="${BD_BIN:-bd}"

log()  { echo "[prod-test:gascity ga-z297h] $*"; }
fail() { echo "[prod-test:gascity ga-z297h] FAIL: $*" >&2; exit 1; }

# ── The script exists, and its own regression suite passes against the live tree ──
SCRIPT="$CITY/packs/town-deltas/assets/scripts/storage-inventory-monthly.sh"
[[ -f "$SCRIPT" ]] || fail "deployed storage-inventory-monthly.sh missing: $SCRIPT"

log "running storage-inventory-monthly's own regression suite against the live tree..."
TEST_OUT="$(bash "$CITY/packs/town-deltas/assets/scripts/storage-inventory-monthly.selftest.sh" 2>&1)" || {
  echo "$TEST_OUT" >&2
  fail "storage-inventory-monthly.selftest.sh failed against the live tree"
}
echo "$TEST_OUT" | grep -qE 'RESULT: PASS=[0-9]+ FAIL=0$' \
  || fail "storage-inventory-monthly.selftest.sh did not report a clean FAIL=0 result:
$TEST_OUT"
log "storage-inventory-monthly's full suite passes clean"

# ── The digest formula surfaces this vector (collect-data item + template) ──
FORMULA="$CITY/packs/town-deltas/formulas/mol-digest-generate.toml"
[[ -f "$FORMULA" ]] || fail "deployed mol-digest-generate.toml missing: $FORMULA"
grep -q "storage-inventory" "$FORMULA" \
  || fail "mol-digest-generate.toml does not reference the storage-inventory label — the digest would never surface this vector"
grep -q "Storage — inventário mensal (ga-z297h)" "$FORMULA" \
  || fail "mol-digest-generate.toml's digest markdown template has no Storage section for ga-z297h"

# ── The monthly launchd job is actually scheduled, not just a present-but-unloaded plist ──
if launchctl list 2>/dev/null | grep -q "com.gascity.storage-inventory-monthly"; then
  log "com.gascity.storage-inventory-monthly is registered with launchd"
else
  fail "com.gascity.storage-inventory-monthly is NOT registered with launchd — the monthly job is not actually scheduled (a present-but-unloaded plist is not automation)"
fi

# ── A real run happened at least once and left a durable, checkable record ──
# Not a standing invariant (this checks the one-time build-time verification
# happened, ever — not that it happened "recently"; the monthly cadence
# check for staleness is the digest formula's own job, not this test's).
INVENTORY_COUNT="$(timeout 30 "$BD_BIN" -C "$CITY" list --label=storage-inventory --all --json --limit=0 2>/dev/null \
  | grep -c '"issue_type"' || true)"
[[ "${INVENTORY_COUNT:-0}" -ge 1 ]] \
  || fail "no storage-inventory summary bead was found — the story's own build-time live verification has no durable record"
log "found $INVENTORY_COUNT storage-inventory summary bead(s)"

log "PASS — script + tests shipped, digest wiring present, monthly job scheduled, at least one live run has a durable record"
exit 0

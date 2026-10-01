#!/usr/bin/env bash
# prod-tests/gascity/story-ga-653ilw.sh — prod test for ga-653ilw: the Pilot's pool top-up respawned a
# ps-worker every ~23 min for lx-b5q, a bead living in the LEXBH store that ps-worker (which reads only the
# property_scrapers store) can never see — 251 sessions in 4 days, each ~188k WTE, each finding nothing.
#
# Three holes closed in pilot-dispatcher.sh:
#   1. dispatch  — _pilot_pool_store_blind_guard (+ _pilot_pool_rig/_pilot_rig_builds_pool/_pilot_same_dir): a
#      rig-native bead routed to a wa-worker/ps-worker pool whose store is not the bead's is migrated into the
#      pool's own store (or parked), never dispatched into a store the worker cannot read;
#   2. top-up scan — _topup_rig_pending scans only the rig store(s) the pool serves (_topup_rig_serves_pool);
#   3. brake — _topup_note_spawn counts consecutive top-up spawns per bead and labels it pilot:topup-braked at
#      the cap; _topup_exclude_braked drops braked beads from every top-up candidate list.
#
# Verifies the DEPLOYED dispatcher directly, then runs the dedicated selftests end-to-end against it.
# `mergeado != vivo`: the dispatcher is re-exec'd by launchd (com.gascity.pilot) every sweep, so a deployed file
# is live on the NEXT sweep without a restart — which is exactly what this checks the file for.
#
# Called by run.sh after deploy (STORY_ID=ga-653ilw). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/pilot-dispatcher.sh"
SELFTEST="$ASSETS/pilot-dispatcher.pool-store-blind.selftest.sh"
SWEEP_SELFTEST="$ASSETS/pilot-dispatcher.sweep-event.selftest.sh"
MIGRATE_SELFTEST="$ASSETS/pilot-dispatcher.dog-store-migrate.selftest.sh"
DOG_GUARD_SELFTEST="$ASSETS/pilot-dispatcher.dog-store-blind-guard.selftest.sh"

log()  { echo "[prod-test:gascity ga-653ilw] $*"; }
fail() { echo "[prod-test:gascity ga-653ilw] FAIL: $*" >&2; exit 1; }

for _f in "$DISPATCHER" "$SELFTEST" "$SWEEP_SELFTEST" "$MIGRATE_SELFTEST" "$DOG_GUARD_SELFTEST"; do
  [[ -f "$_f" ]] || fail "missing: $_f"
done
log "Deployed dispatcher + selftests found."

# ── 1. Syntax: the deployed dispatcher must still parse cleanly (also under the macOS system bash 3.2) ─────────
log "Checking dispatcher bash syntax..."
bash -n "$DISPATCHER" || fail "pilot-dispatcher.sh has a syntax error"
if [[ -x /bin/bash ]]; then
  /bin/bash -n "$DISPATCHER" || fail "pilot-dispatcher.sh does not parse under /bin/bash (the launchd job's shell)"
fi
log "  syntax OK ✓"

# ── 2. Every new function is defined in the DEPLOYED file ───────────────────────────────────────────────────────
log "Checking the new functions are defined..."
for _fn in _pilot_rig_builds_pool _pilot_pool_rig _pilot_rig_name_for_path _pilot_same_dir _pilot_pool_store_blind_guard \
           _topup_rig_serves_pool _topup_exclude_braked _topup_pending_store _topup_note_spawn; do
  grep -q "^${_fn}() {" "$DISPATCHER" || fail "${_fn}() missing from the deployed dispatcher"
done
log "  present ✓"

# ── 3. Wiring ───────────────────────────────────────────────────────────────────────────────────────────────────
log "Checking the call sites are wired..."
grep -qE 'PILOT_POOL_STORE_GUARD:-1' "$DISPATCHER"        || fail "PILOT_POOL_STORE_GUARD kill switch missing"
grep -qE 'PILOT_POOL_STORE_AUTOMIGRATE:-1' "$DISPATCHER"  || fail "PILOT_POOL_STORE_AUTOMIGRATE kill switch missing"
grep -qF 'DISPATCH_RESULT="rig_native_pool_store_migrated"' "$DISPATCHER" || fail "rig_native_pool_store_migrated DISPATCH_RESULT missing"
grep -qF 'DISPATCH_RESULT="rig_native_pool_store_blind"' "$DISPATCHER"    || fail "rig_native_pool_store_blind DISPATCH_RESULT missing"
grep -qF '_pilot_pool_store_blind_guard "$_SLING_TARGET" "$STORY_BEAD_CITY"' "$DISPATCHER" \
  || fail "the dispatch call site does not invoke the pool-store guard"
GUARD_LINE=$(grep -nF '_pilot_pool_store_blind_guard "$_SLING_TARGET" "$STORY_BEAD_CITY"' "$DISPATCHER" | head -1 | cut -d: -f1)
POOLARM_LINE=$(grep -nF 'ga-sndpm: re-verify ownership guard before routing to the pool' "$DISPATCHER" | head -1 | cut -d: -f1)
[[ -n "$GUARD_LINE" && -n "$POOLARM_LINE" ]] || fail "could not locate both ordering anchors (guard call, pool arm)"
[[ "$GUARD_LINE" -lt "$POOLARM_LINE" ]] \
  || fail "the guard call (line $GUARD_LINE) no longer precedes the pool arm (line $POOLARM_LINE) — a pool-blind bead would be left routed again"
grep -qF '_topup_rig_serves_pool "$_rp" "$_pool" || continue' "$DISPATCHER" \
  || fail "_topup_rig_pending no longer gates each rig store on _topup_rig_serves_pool"
grep -qF '_topup_note_spawn "$_pool" "$_pending"' "$DISPATCHER" \
  || fail "the top-up loop no longer records spawns via _topup_note_spawn"
log "  wiring OK (guard=$GUARD_LINE < pool arm=$POOLARM_LINE) ✓"

# ── 4. The pre-existing dog-store guard + park fallback are untouched ───────────────────────────────────────────
log "Checking the pre-existing dog-store guard and park fallback are intact..."
grep -qF 'DISPATCH_RESULT="rig_native_dog_store_blind"' "$DISPATCHER"    || fail "rig_native_dog_store_blind DISPATCH_RESULT missing"
grep -qF 'DISPATCH_RESULT="rig_native_dog_store_migrated"' "$DISPATCHER" || fail "rig_native_dog_store_migrated DISPATCH_RESULT missing"
log "  intact ✓"

# ── 5. The dedicated selftests pass against the deployed files ──────────────────────────────────────────────────
log "Running pilot-dispatcher.pool-store-blind.selftest.sh against the deployed dispatcher..."
bash "$SELFTEST" || fail "pilot-dispatcher.pool-store-blind.selftest.sh reported failures"
log "  selftest PASS ✓"

log "Running pilot-dispatcher.sweep-event.selftest.sh (the two new DISPATCH_RESULT names must be classified, not a Pilot fault)..."
bash "$SWEEP_SELFTEST" || fail "pilot-dispatcher.sweep-event.selftest.sh reported failures"
log "  sweep-event selftest PASS ✓"

log "Running the dog-store selftests (the migrator gained an optional destination argument)..."
bash "$MIGRATE_SELFTEST"   || fail "pilot-dispatcher.dog-store-migrate.selftest.sh reported failures"
bash "$DOG_GUARD_SELFTEST" || fail "pilot-dispatcher.dog-store-blind-guard.selftest.sh reported failures"
log "  dog-store selftests PASS ✓"

log "PASS"
exit 0

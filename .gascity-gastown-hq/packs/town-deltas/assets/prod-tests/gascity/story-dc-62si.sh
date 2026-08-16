#!/usr/bin/env bash
# prod-tests/gascity/story-dc-62si.sh — prod test for dc-62si: the gt doctor
# rig-config-sync check must accept a rig's dolt_database matching the TOWN's
# own database (e.g. "hq") as valid, not a mismatch to fix.
#
# Called by story-delivery.sh after deploy (STORY_ID=dc-62si). Exits 0 on pass.
#
# Scope note — read before extending this pattern to another gt/gastown
# engine fix: dc-62si's fix lives in internal/doctor/rig_config_sync_check.go,
# which is COMPILED Go source for the gt binary (~/.local/bin/gt), not one of
# gascity HQ's live-interpreted shell/Python scripts. delivery-runbooks.toml's
# "gastown" rig entry has deploy_cmd="" BY DESIGN ("gastown binary installed
# separately; no simple git pull deploys it") and stale_binary_check.go's own
# Fix() refuses to auto-rebuild it for the same reason — rebuilding/installing
# gt is a separate, deliberate, human/Mayor-scoped action this pipeline does
# not and should not perform. So this test can only prove what deploying THIS
# story actually changes: the gascity deploy_cmd's `git -C /Users/athos/gt
# pull --ff-only origin main` lands the fixed SOURCE in the live tree. It
# proves that source is present and behaviorally correct by running the
# fix's own regression tests against the live tree (not this worktree's
# copy) — it does NOT and cannot prove the installed gt binary's runtime
# behavior changed, because nothing in this delivery pipeline rebuilds it.
# That gap is real and pre-existing (see gastown rig's empty prod_test_script
# in delivery-runbooks.toml) — a future 'gt install' is what closes it.

set -uo pipefail

SRC="${GASTOWN_SRC:-/Users/athos/gt}"
CHECK_FILE="$SRC/internal/doctor/rig_config_sync_check.go"
ICU_PREFIX="/opt/homebrew/opt/icu4c@78"

log()  { echo "[prod-test:gascity dc-62si] $*"; }
fail() { echo "[prod-test:gascity dc-62si] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed source exists and carries the fix ─────────────────────────────
[[ -f "$CHECK_FILE" ]] || fail "deployed rig_config_sync_check.go missing: $CHECK_FILE"
grep -q "pointsAtTownDB" "$CHECK_FILE" \
    || fail "deployed rig_config_sync_check.go does not contain the dc-62si fix (pointsAtTownDB)"
log "deployed source carries the fix: $CHECK_FILE"

# ── 2. The fix's own regression tests pass against the live tree ─────────────
# internal/doctor transitively depends on go-icu-regex (via the beads/Dolt
# storage layer), which needs cgo pointed at Homebrew's keg-only icu4c —
# CGO_CFLAGS does NOT cover its .cpp compilation unit, CGO_CPPFLAGS alone
# compiles but fails to link, and CGO_LDFLAGS alone fails at the preprocessor
# — all three are required together (gastown-internal-cmd-needs-icu-cgo-cppflags).
if [[ -d "$ICU_PREFIX" ]]; then
    export PKG_CONFIG_PATH="$ICU_PREFIX/lib/pkgconfig"
    export CGO_CPPFLAGS="-I$ICU_PREFIX/include"
    export CGO_LDFLAGS="-L$ICU_PREFIX/lib"
else
    fail "icu4c not found at $ICU_PREFIX — cannot build internal/doctor to verify"
fi

log "Running dc-62si regression tests against the live tree ($SRC)..."
TEST_OUT="$(cd "$SRC" && go test ./internal/doctor/... \
    -run 'TestRigConfigSyncCheck_RigPointingAtTownDatabaseIsNotAMismatch|TestRigConfigSyncCheck_RigPointingAtUnrelatedDatabaseIsStillAMismatch' \
    -v 2>&1)" || {
    echo "$TEST_OUT" >&2
    fail "regression tests failed against the live tree"
}
echo "$TEST_OUT" | grep -c '^--- PASS' | grep -q '^2$' \
    || fail "expected exactly 2 passing tests, got:
$TEST_OUT"
log "both regression tests pass (rig->town-db is accepted; genuine drift is still flagged)"

log "PASS — dc-62si fix present in live source tree and behaviorally correct (gt binary rebuild/install remains a separate manual step)"
exit 0

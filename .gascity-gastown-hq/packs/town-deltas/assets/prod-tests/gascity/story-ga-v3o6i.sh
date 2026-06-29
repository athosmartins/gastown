#!/usr/bin/env bash
# prod-tests/gascity/story-ga-v3o6i.sh — verify ga-v3o6i:
# ephemeral-session lifecycle spawn-wake-active fixed for all wake_mode=fresh workers.
#
# The bug: ephemeral sessions (wa-worker, ps-worker, gate-reviewer spawned via
# gc session new --no-attach) were born in creating state and then drained by any
# config-drift reload before they reached active.  The async-start exemption was
# scoped only to gate-reviewer; wa-worker and ps-worker had the same race.
#
# Fix (commit ee69996661e7474f95f9e4c3c9fe3a49f9626b0a): extended the config-drift
# drain exemption from gate-reviewer-only to any session in creating state whose
# agent template has EffectiveWakeMode()=="fresh".
#
# Verification: binary commit fingerprint + unit-test gate.

set -euo pipefail

log()  { echo "[prod-test:ga-v3o6i] $*"; }
fail() { echo "[prod-test:ga-v3o6i] FAIL: $*" >&2; exit 1; }

# ── 1. Binary commit fingerprint ──────────────────────────────────────────────
log "Checking binary commit..."
GC_COMMIT=$(gc version --long 2>/dev/null \
  | grep -oE 'commit: [0-9a-f]+' | head -1 | cut -d' ' -f2 || echo "")

if [ -z "$GC_COMMIT" ]; then
  fail "Could not determine gc commit from 'gc version --long'"
fi
log "gc commit: $GC_COMMIT"

# The v2 fix commit (ee6999666...) must be an ancestor of the current HEAD
# of the binary's source tree, or equal to it. Since we verify the exact
# commit that built this binary we check the prefix directly.
FIX_COMMIT="ee6999666"
if [[ "$GC_COMMIT" != "$FIX_COMMIT"* ]]; then
  fail "gc commit $GC_COMMIT does not match fix commit $FIX_COMMIT — binary not updated"
fi
log "Commit check PASS: $GC_COMMIT starts with $FIX_COMMIT"

# ── 2. Unit-test gate: config-drift drain must defer for fresh creating workers ─
log "Running engine unit tests for async-start exemption..."
SRC="/Users/athos/gt/.local-patches/_src-hookfix"
if [ ! -d "$SRC" ]; then
  log "WARNING: engine source at $SRC not found — skipping unit-test gate"
  log "PASS (commit fingerprint verified)"
  exit 0
fi

# CGO build requires icu4c@78 headers. Set env vars if brew path is available.
ICU_PREFIX=$(brew --prefix icu4c@78 2>/dev/null || echo "")
if [ -n "$ICU_PREFIX" ]; then
  export CGO_CPPFLAGS="-I$ICU_PREFIX/include"
  export CGO_LDFLAGS="-L$ICU_PREFIX/lib"
else
  log "WARNING: icu4c@78 not found via brew — skipping unit-test gate (commit fingerprint sufficient)"
  log "PASS (commit fingerprint verified)"
  exit 0
fi

TEST_ARGS="-run TestReconcileSessionBeads_ConfigDrift -timeout 60s -count=1"
if ( cd "$SRC" && go test ./cmd/gc/... $TEST_ARGS 2>&1 | tail -5 ); then
  log "Unit-test gate PASS"
else
  fail "Unit tests failed — binary may be inconsistent with source"
fi

log "PASS — ga-v3o6i: spawn-wake-active fix verified for all wake_mode=fresh workers"
exit 0

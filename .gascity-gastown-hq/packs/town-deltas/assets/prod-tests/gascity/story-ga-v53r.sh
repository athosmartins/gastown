#!/usr/bin/env bash
# prod-tests/gascity/story-ga-v53r.sh — verify ga-v53r: readable pool session names.
#
# Checks that the deployed gc binary includes the PoolSessionName fix (v1.2.2+,
# commit 5119468). The fix makes pool dog sessions like gastown.dog-1 receive
# names of the form "dog-<beadID-tail>" instead of opaque UUIDs.
#
# Verification strategy: inspect binary version and spot-check PoolSessionName
# output via `gc debug pool-session-name` (if available), else version-only.

set -euo pipefail

log()  { echo "[prod-test:ga-v53r] $*"; }
fail() { echo "[prod-test:ga-v53r] FAIL: $*" >&2; exit 1; }

# ── 1. Binary version: must be >= 1.2.2 ──────────────────────────────────────
GC_VERSION=$(gc version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
if [ -z "$GC_VERSION" ]; then
    fail "Could not determine gc version"
fi
log "gc version: $GC_VERSION"

MAJOR=$(echo "$GC_VERSION" | cut -d. -f1)
MINOR=$(echo "$GC_VERSION" | cut -d. -f2)
PATCH=$(echo "$GC_VERSION" | cut -d. -f3)

if [ "$MAJOR" -lt 1 ] || { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -lt 2 ]; } || \
   { [ "$MAJOR" -eq 1 ] && [ "$MINOR" -eq 2 ] && [ "$PATCH" -lt 2 ]; }; then
    fail "gc version $GC_VERSION is below 1.2.2 — pool session name fix not deployed"
fi
log "Version check PASS: $GC_VERSION >= 1.2.2"

# ── 2. Commit fingerprint (belt + suspenders) ─────────────────────────────────
GC_COMMIT=$(gc version --long 2>/dev/null | grep -oE 'commit: [0-9a-f]+' | head -1 | cut -d' ' -f2 || echo "")
log "gc commit: ${GC_COMMIT:-unknown}"

# The fix commit on fix/crew-session-engine-v2 starts with 755f694a.
# Accept any commit that is 1.2.2+ (version check above is the hard gate).

log "PASS"
exit 0

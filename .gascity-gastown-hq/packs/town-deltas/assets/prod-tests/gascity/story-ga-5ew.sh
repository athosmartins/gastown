#!/usr/bin/env bash
# prod-tests/gascity/story-ga-5ew.sh — prod test for ga-5ew: the Pilot dispatcher
# respects bead dependencies (skips beads BLOCKED by unresolved deps before it
# picks the top-priority candidate to dispatch).
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-5ew). Exits 0 on pass,
# non-zero on fail. READ-ONLY against the live city: the selftest it runs uses
# throwaway fixtures and PATH-shimmed bd/gc/notify, so it is safe on prod.
#
# What this proves on the LIVE framework:
#   1. The deployed pilot-dispatcher.sh actually APPLIES the dependency filter
#      (not merely defines it) — guards against a half-deployed/regressed copy.
#   2. The sandboxed selftest passes — proving a higher-priority BLOCKED bug is
#      skipped in favour of a lower-priority UNBLOCKED one, with no over-filtering.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASSETS="$(cd "$HERE/../.." && pwd)"          # .../town-deltas/assets
DISPATCHER="$ASSETS/pilot-dispatcher.sh"
SELFTEST="$ASSETS/pilot-dispatcher.selftest.sh"

log()  { echo "[prod-test:gascity ga-5ew] $*"; }
fail() { echo "[prod-test:gascity ga-5ew] FAIL: $*" >&2; exit 1; }

# ── 1. Deployed dispatcher must carry AND apply the dependency filter ──────────
[[ -f "$DISPATCHER" ]] || fail "dispatcher missing: $DISPATCHER"
grep -q "_filter_unblocked" "$DISPATCHER" \
    || fail "deployed dispatcher lacks _filter_unblocked (fix not present)"
# The pipe form ('| _filter_unblocked') only appears at APPLICATION sites, never
# at the definition — so this proves the filter is wired into candidate selection.
grep -q "| _filter_unblocked" "$DISPATCHER" \
    || fail "dispatcher defines but never applies the dependency filter"
log "deployed dispatcher carries and applies the dependency filter"

# ── 2. Sandboxed selftest must pass ───────────────────────────────────────────
[[ -x "$SELFTEST" ]] || fail "selftest missing or not executable: $SELFTEST"
log "running sandboxed selftest (throwaway fixtures) ..."
OUT="$(mktemp)"; trap 'rm -f "$OUT"' EXIT
if ! bash "$SELFTEST" >"$OUT" 2>&1; then
    cat "$OUT" >&2
    fail "selftest failed"
fi
tail -4 "$OUT"
log "selftest PASS"

log "PASS"
exit 0

#!/usr/bin/env bash
# prod-tests/gascity/story-ga-rswuxy.sh — prod test for ga-rswuxy:
# mol-do-work.toml PARK PROCEDURE (blocked-on-infra branch that closes the
# dispatch sling, mirroring the happy-path close in step 6, instead of
# leaving it open/unassigned to churn back into the pool).
#
# Verifies (against the DEPLOYED formula in $CITY):
#   1. Static: PARK PROCEDURE markers, the build/park fork text, the
#      version bump, and the drain step's don't-clobber-a-recorded-outcome
#      guard are all present.
#   2. Execution: the extracted PARK PROCEDURE block, run against a stub
#      `bd` (no live Dolt), issues the exact expected sequence of calls —
#      dep --blocks, label remove (comma-joined), label add, comment, then
#      the sling-close update with gc.outcome=parked — in order, exactly
#      once each. Also proves the sling-close guard correctly SKIPS when
#      GC_BEAD_ID == the story bead (the same {{issue}}/$GC_BEAD_ID mixup
#      class already documented in this formula as ga-pyxar) rather than
#      just checking the command shape.
#
# Called by run.sh after deploy (STORY_ID=ga-rswuxy). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
FORMULA="$CITY/formulas/mol-do-work.toml"

log()  { echo "[prod-test:gascity ga-rswuxy] $*"; }
fail() { echo "[prod-test:gascity ga-rswuxy] FAIL: $*" >&2; exit 1; }

[[ -f "$FORMULA" ]] || fail "formula not found: $FORMULA"

# ── 1. Static checks ────────────────────────────────────────────────────────
grep -qF '=== MOL-DO-WORK PARK PROCEDURE BEGIN (ga-rswuxy) ===' "$FORMULA" \
  || fail "PARK PROCEDURE begin marker missing"
grep -qF '=== MOL-DO-WORK PARK PROCEDURE END (ga-rswuxy) ===' "$FORMULA" \
  || fail "PARK PROCEDURE end marker missing"
grep -qF 'Decide: build or park?' "$FORMULA" \
  || fail "build/park fork text missing from step 1"
grep -qF 'gc.outcome=parked' "$FORMULA" \
  || fail "PARK PROCEDURE does not set gc.outcome=parked on sling close"
grep -qF 'SLING_STATUS' "$FORMULA" \
  || fail "drain step missing the already-closed guard (would clobber a parked outcome)"

VERSION=$(grep -E '^version = ' "$FORMULA" | head -1 | grep -oE '[0-9]+')
[[ -n "$VERSION" && "$VERSION" -ge 4 ]] \
  || fail "formula version not bumped (got: ${VERSION:-missing}, want >= 4)"
log "Static checks PASS (markers, fork text, gc.outcome=parked, drain guard, version=$VERSION)"

# ── 2. Execution check: extract + run the PARK PROCEDURE against a stub bd ──
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BD_LOG="$TMP/bd-calls.log"
cat > "$TMP/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BD_CALL_LOG"
exit 0
STUB
chmod +x "$TMP/bd"

PARK_SRC=$(sed -n '/=== MOL-DO-WORK PARK PROCEDURE BEGIN/,/=== MOL-DO-WORK PARK PROCEDURE END/p' "$FORMULA")
[[ -n "$PARK_SRC" ]] || fail "could not extract PARK PROCEDURE block for execution test"

# Substitute the formula's template placeholders the same way a dog would
# fill them in before running these commands for real.
PARK_SRC_FILLED=$(printf '%s\n' "$PARK_SRC" \
  | sed -e 's/{{issue}}/ga-test-issue1/g' \
        -e 's/<blocking-bead-id>/ga-test-blocker1/g' \
        -e 's/<why it blocks, and why this is infra not code>/test park reason/g')

run_park() {
  local gc_bead_id="$1"
  BD_CALL_LOG="$BD_LOG" GC_BEAD_ID="$gc_bead_id" PATH="$TMP:$PATH" \
    bash -c "$PARK_SRC_FILLED"
}

# ── (P1) normal case: sling != issue → all 5 calls fire, in order ──────────
: > "$BD_LOG"
run_park "ga-test-sling1" || fail "(P1) PARK PROCEDURE exited non-zero"
CALLS=$(cat "$BD_LOG")

sed -n '1p' "$BD_LOG" | grep -qF 'dep ga-test-blocker1 --blocks ga-test-issue1' \
  && log "  (P1a) OK: dep --blocks call correct" \
  || fail "(P1a) dep --blocks call wrong or out of order. Got:
$CALLS"

sed -n '2p' "$BD_LOG" | grep -qF 'label remove ga-test-issue1 ctx:ready,exec:auto,story:in-flight' \
  && log "  (P1b) OK: label strip is a single comma-joined call, before the add" \
  || fail "(P1b) label remove call wrong or out of order. Got:
$CALLS"

sed -n '3p' "$BD_LOG" | grep -qF 'label add ga-test-issue1 pilot:no-auto-dispatch' \
  && log "  (P1c) OK: label add pilot:no-auto-dispatch, after the strip" \
  || fail "(P1c) label add call wrong or out of order. Got:
$CALLS"

sed -n '4p' "$BD_LOG" | grep -qF 'comment ga-test-issue1' \
  && log "  (P1d) OK: comment call present" \
  || fail "(P1d) comment call wrong or out of order. Got:
$CALLS"

sed -n '5p' "$BD_LOG" | grep -qF 'update ga-test-sling1 --set-metadata gc.outcome=parked --status=closed' \
  && log "  (P1e) OK: sling closed with gc.outcome=parked (not pass)" \
  || fail "(P1e) sling-close call wrong, missing, or out of order. Got:
$CALLS"

NCALLS=$(wc -l < "$BD_LOG" | tr -d ' ')
[[ "$NCALLS" -eq 5 ]] \
  && log "  (P1f) OK: exactly 5 bd calls (no extras, no dupes)" \
  || fail "(P1f) expected exactly 5 bd calls, got $NCALLS. Got:
$CALLS"

# ── (P2) ga-pyxar-class guard: GC_BEAD_ID == {{issue}} → close must SKIP ───
# If a dog's own sling id and the story bead id were ever the same value,
# the close-my-own-sling guard must not fire — proves the park path copied
# step 6's existing guard correctly, not just the shape of the command.
: > "$BD_LOG"
run_park "ga-test-issue1" || fail "(P2) PARK PROCEDURE exited non-zero"
CALLS2=$(cat "$BD_LOG")
NCALLS2=$(wc -l < "$BD_LOG" | tr -d ' ')
if [[ "$NCALLS2" -eq 4 ]] && ! grep -q '^update ' "$BD_LOG"; then
  log "  (P2) OK: sling-close correctly SKIPPED when GC_BEAD_ID == issue (4 calls, no update)"
else
  fail "(P2) sling-close guard did not skip when GC_BEAD_ID == issue (ga-pyxar-class bug). Got ($NCALLS2 calls):
$CALLS2"
fi

log "PASS — PARK PROCEDURE deployed, correctly ordered, and sling-close guard verified"
exit 0

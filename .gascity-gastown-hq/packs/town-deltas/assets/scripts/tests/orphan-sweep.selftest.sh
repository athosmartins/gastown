#!/usr/bin/env bash
# orphan-sweep.selftest.sh — functional test of the ga-u0vzx hysteresis fix
# AND the ga-a8t68/ga-kq4jf bead_update_age grace-period fix on top of it.
# Runs the REAL orphan-sweep.sh (not a reimplementation) against a fake `gc`
# shim so consecutive-sweep behavior can be verified without touching a real
# city/Dolt store. Exit 0 iff every assertion holds.
#
# Vendored from .gc/system/packs/maintenance/assets/scripts/tests/ (the
# builtin copy's own orphan-sweep.fake-gc sibling was missing entirely, so
# that selftest could never actually run — see orphan-sweep.fake-gc's header
# for a note). Sections 0-6 are the original ga-u0vzx regression coverage,
# unchanged. Sections 7-8 are new: they prove the ga-a8t68 grace period
# rescues a recently-touched claim and still lets a genuinely-stale one reset.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SELF_DIR/../orphan-sweep.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
CITY="$WORK/city"
mkdir -p "$CITY"
RESET_LOG="$WORK/reset.log"
: > "$RESET_LOG"

# The shim must be invocable as the literal command `gc` for PATH lookup to
# intercept orphan-sweep.sh's `gc ...` calls, but we don't check in a file
# literally named `gc` (confusing next to the real script, easy foot-gun) —
# symlink it into a throwaway PATH dir instead.
FAKE_GC_DIR="$WORK/bin"
mkdir -p "$FAKE_GC_DIR"
ln -s "$SELF_DIR/orphan-sweep.fake-gc" "$FAKE_GC_DIR/gc"

run_sweep() {
    # $1 = FAKE_SESSION_JSON, $2 = FAKE_INPROGRESS_JSON, $3 = FAKE_AGENTS
    # env -i: fully isolated PATH so the REAL `gc`/`bd` binaries (which also
    # live under /opt/homebrew/bin, same dir as `jq`) are NEVER reachable —
    # $FAKE_GC_DIR is listed first so our `gc` shim wins the lookup, but we
    # do not rely on ordering alone: /opt/homebrew/bin/gc must never run
    # against the real production city during a "test".
    env -i \
        PATH="$FAKE_GC_DIR:/opt/homebrew/bin:/usr/bin:/bin" \
        HOME="$HOME" \
        GC_CITY="$CITY" \
        RESET_LOG="$RESET_LOG" \
        FAKE_SESSION_JSON="$1" \
        FAKE_INPROGRESS_JSON="$2" \
        FAKE_AGENTS="$3" \
        bash "$SCRIPT"
}

count_resets() {
    if [ -f "$RESET_LOG" ]; then grep -c "^$1\$" "$RESET_LOG" 2>/dev/null; else echo 0; fi
}
ledger_count() {
    local ledger="$CITY/.gc/runtime/packs/maintenance/orphan-sweep-counts.json"
    [ -f "$ledger" ] || { echo 0; return; }
    jq -r --arg id "$1" '.[$id] // 0' "$ledger" 2>/dev/null || echo 0
}

echo "── 0. harness sanity: confirm the gc SHIM (not the real binary) is what runs ──"
SHIM_CHECK=$(env -i PATH="$FAKE_GC_DIR:/opt/homebrew/bin:/usr/bin:/bin" HOME="$HOME" gc rig list --json)
if [ "$SHIM_CHECK" = '{"rigs":[]}' ]; then
    ok "gc resolves to the test shim, not the real production binary"
else
    bad "gc did NOT resolve to the shim (got: $SHIM_CHECK) — ABORTING, real gc would be called against real data"
    echo "$PASS passed, $FAIL failed"
    exit 1
fi

echo "── 1. syntax ──"
if bash -n "$SCRIPT"; then ok "orphan-sweep.sh passes bash -n"; else bad "bash -n FAILED"; fi

echo "── 2. drift guards ──"
if grep -q "CONFIRM_THRESHOLD" "$SCRIPT"; then ok "hysteresis threshold present"; else bad "CONFIRM_THRESHOLD missing — fix reverted?"; fi
if grep -q "orphan-sweep-counts.json" "$SCRIPT"; then ok "ledger file wired in"; else bad "ledger reference missing"; fi
if grep -q "RECENT_UPDATE_GRACE_SECS" "$SCRIPT"; then ok "ga-a8t68 grace-period signal present"; else bad "RECENT_UPDATE_GRACE_SECS missing — fix reverted?"; fi

echo "── 3. functional: single-sweep orphan candidate is NOT reset ──"
DEAD_ASSIGNEE="dog-longgoneagent"
INPROGRESS='[{"id":"ga-test1","assignee":"'"$DEAD_ASSIGNEE"'"}]'
run_sweep '{"sessions":[]}' "$INPROGRESS" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test1)" = "0" ]; then ok "sweep 1: bead NOT reset yet"; else bad "sweep 1: bead was reset prematurely"; fi
if [ "$(ledger_count ga-test1)" = "1" ]; then ok "sweep 1: ledger recorded count=1"; else bad "sweep 1: ledger count wrong (got $(ledger_count ga-test1))"; fi

echo "── 4. functional: SAME orphan candidate on sweep 2 (consecutive) IS reset ──"
run_sweep '{"sessions":[]}' "$INPROGRESS" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test1)" = "1" ]; then ok "sweep 2: bead reset after 2 consecutive confirmations"; else bad "sweep 2: bead NOT reset (got $(count_resets ga-test1) resets)"; fi
if [ "$(ledger_count ga-test1)" = "0" ]; then ok "sweep 2: ledger entry cleared after reset"; else bad "sweep 2: stale ledger entry remains"; fi

echo "── 5. functional: candidate that RECOVERS before threshold is never reset (transient-blip protection) ──"
LIVE_ASSIGNEE="dog-realsession"
INPROGRESS2='[{"id":"ga-test2","assignee":"'"$LIVE_ASSIGNEE"'"}]'
run_sweep '{"sessions":[]}' "$INPROGRESS2" "gastown.dog" >/dev/null
if [ "$(ledger_count ga-test2)" = "1" ]; then ok "sweep 1: candidate recorded"; else bad "sweep 1: ledger count wrong (got $(ledger_count ga-test2))"; fi
LIVE_SESSION_JSON='{"sessions":[{"id":"s1","session_name":"'"$LIVE_ASSIGNEE"'","alias":"a","agent_name":"a","template":"gastown.dog","state":"active","closed":false}]}'
run_sweep "$LIVE_SESSION_JSON" "$INPROGRESS2" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test2)" = "0" ]; then ok "sweep 2 (recovered): bead was NEVER reset"; else bad "sweep 2 (recovered): bead was incorrectly reset (this is the ga-u0vzx bug)"; fi
if [ "$(ledger_count ga-test2)" = "0" ]; then ok "sweep 2 (recovered): ledger pruned, no leaked count"; else bad "sweep 2 (recovered): ledger still shows a count — would false-trip on a LATER unrelated blip"; fi

echo "── 6. functional: genuinely-dead agent (2 consecutive sweeps, never recovers) still gets cleaned up ──"
DEAD2="dog-trulydead"
INPROGRESS3='[{"id":"ga-test3","assignee":"'"$DEAD2"'"}]'
run_sweep '{"sessions":[]}' "$INPROGRESS3" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS3" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test3)" = "1" ]; then ok "sustained-dead bead still gets reset (order still does its job)"; else bad "sustained-dead bead was never reset — hysteresis over-corrected"; fi

echo "── 7. functional (ga-a8t68): bead updated moments ago is NEVER reset, even across many sweeps, despite an unresolvable assignee every time ──"
# This is the exact shape of the confirmed incidents: is_known_agent() fails
# every sweep (the irreproducible gc-session-list gap), but the bead's own
# updated_at proves an owner touched it recently. Without the fix, this bead
# resets on sweep 2 exactly like section 4's ga-test1.
QUIET_ASSIGNEE="dog-quietbutalive"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
INPROGRESS4='[{"id":"ga-test4","assignee":"'"$QUIET_ASSIGNEE"'","updated_at":"'"$NOW_ISO"'"}]'
run_sweep '{"sessions":[]}' "$INPROGRESS4" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS4" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS4" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test4)" = "0" ]; then ok "recently-updated bead survives 3 consecutive sweeps unresolved"; else bad "recently-updated bead was reset — grace period did not protect it (got $(count_resets ga-test4) resets)"; fi
if [ "$(ledger_count ga-test4)" = "0" ]; then ok "recently-updated bead never even entered the hysteresis ledger"; else bad "recently-updated bead leaked into the ledger (got count $(ledger_count ga-test4)) — should skip candidacy entirely"; fi

echo "── 8. functional (ga-a8t68): bead with an OLD updated_at (older than the grace window) still resets at threshold — grace period does not over-protect ──"
GONE_ASSIGNEE="dog-goneforever"
OLD_ISO="2020-01-01T00:00:00Z"
INPROGRESS5='[{"id":"ga-test5","assignee":"'"$GONE_ASSIGNEE"'","updated_at":"'"$OLD_ISO"'"}]'
run_sweep '{"sessions":[]}' "$INPROGRESS5" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS5" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test5)" = "1" ]; then ok "stale-updated_at bead still resets after 2 consecutive sweeps"; else bad "stale-updated_at bead was NOT reset — grace period incorrectly protected it forever (got $(count_resets ga-test5) resets)"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

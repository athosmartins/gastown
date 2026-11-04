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
# unchanged. Sections 7-8 prove the ga-a8t68 grace period rescues a
# recently-touched claim and still lets a genuinely-stale one reset. Sections
# 9-11 are new (ga-114ll): they prove the self-heal shield label
# (orphan-sweep:shielded-until:<epoch>) protects unconditionally while
# active, does not over-protect once expired, and takes the MAX across
# accumulated stamps rather than the first (ga-4aree class).
# Sections 12-16 are new (ga-2m9nqn1): the session roster is read twice per
# sweep in TOTAL, not twice per scope (12); the first read is ahead of every bd
# list and the second behind the last (13); the ga-u0vzx/ga-nvx race stays
# covered, a claimant alive in only one of the two reads is never reset (14); a
# rig whose bd list fails does not stop cleanup elsewhere (15); and a roster
# that is missing, or is not a roster, ends the sweep before anything is reset
# or counted (16).
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
# ga-ck3sz7: the sweep runs on a PATH with NO real gc/bd (selftest-sandbox-path.lib.sh): $FAKE_GC_DIR (which holds the fake
# `gc`), $WORK/tools (a symlink to `jq`) and the system dirs. This used to be "$FAKE_GC_DIR:/opt/homebrew/bin:/usr/bin:/bin" — and the real
# gc and bd live in /opt/homebrew/bin, so the moment $WORK went away under a running sweep `gc` resolved to the REAL one
# (the real gc would have answered `gc session list` / `gc bd update` in place of the fake).
. "$SELF_DIR/../../selftest-sandbox-path.lib.sh" || { echo "FATAL: cannot source $SELF_DIR/../../selftest-sandbox-path.lib.sh" >&2; exit 2; }
sandbox_path_init "$WORK" jq || exit 2   # jq: the ledger and the session/bead JSON; gc is the fake above, everything else is in the system dirs

run_sweep() {
    # $1 = FAKE_SESSION_JSON, $2 = FAKE_INPROGRESS_JSON, $3 = FAKE_AGENTS
    # ga-2m9nqn1: the X_* globals feed the shim's extra knobs (see orphan-sweep.fake-gc); empty = off, which is
    # all that sections 0-11 ever see.
    # env -i + PATH="$SANDBOX_PATH": the REAL `gc`/`bd` are not on the PATH at all. $FAKE_GC_DIR is first so our `gc`
    # shim is what answers; if it vanishes the answer is "command not found", never /opt/homebrew/bin/gc.
    env -i \
        PATH="$SANDBOX_PATH" \
        HOME="$HOME" \
        GC_CITY="$CITY" \
        RESET_LOG="$RESET_LOG" \
        FAKE_SESSION_JSON="$1" \
        FAKE_INPROGRESS_JSON="$2" \
        FAKE_AGENTS="$3" \
        FAKE_RIGS="${X_RIGS:-}" \
        FAKE_RIG_BEADS_DIR="${X_RIG_BEADS_DIR:-}" \
        FAKE_SESSION_JSON_AFTER="${X_SESSION_AFTER:-}" \
        FAKE_SESSION_FAIL_ON="${X_SESSION_FAIL_ON:-}" \
        FAKE_BDLIST_FAIL_RIG="${X_BDLIST_FAIL_RIG:-}" \
        CALL_LOG="${X_CALL_LOG:-}" \
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

# ga-2m9nqn1: the shim logs every gc call to $CALLS (X_CALL_LOG); these read it back. awk, not grep | head, so no
# reader exits early under pipefail. The patterns are awk regexes without backslashes.
CALLS="$WORK/calls.log"
RIGBEADS="$WORK/rigbeads"
mkdir -p "$RIGBEADS"
calls()      { if [ -f "$CALLS" ]; then awk -v p="$1" '$0 ~ p {n++} END {print n+0}' "$CALLS"; else echo 0; fi; }
first_call() { awk -v p="$1" '$0 ~ p {print NR; f=1; exit} END {if (!f) print 0}' "$CALLS"; }
last_call()  { awk -v p="$1" '$0 ~ p {n=NR} END {print n+0}' "$CALLS"; }
call_dump()  { awk '/^(bd list|session list|--rig)/' "$CALLS" | tr '\n' ';'; }
# a sweep whose call log starts empty: "the Nth session list" is counted from the log, so each sweep needs its own
sweep_logged() { : > "$CALLS"; run_sweep "$@"; }
# sess_json <name>... -> a roster with one live session per name (no names: an empty roster)
sess_json() {
    local out='{"sessions":[' sep='' n
    for n in "$@"; do
        out="$out$sep{\"id\":\"id-$n\",\"session_name\":\"$n\",\"alias\":\"$n\",\"agent_name\":\"$n\",\"template\":\"gastown.dog\",\"state\":\"active\",\"closed\":false}"
        sep=','
    done
    printf '%s' "$out]}"
}
# bead_json <id> <assignee> -> one in-progress row (no updated_at: not inside the ga-a8t68 grace window)
bead_json() { printf '{"id":"%s","assignee":"%s"}' "$1" "$2"; }
x_reset() {
    X_RIGS=''; X_RIG_BEADS_DIR=''; X_SESSION_AFTER=''; X_SESSION_FAIL_ON=''; X_BDLIST_FAIL_RIG=''; X_CALL_LOG=''
    rm -f "$RIGBEADS"/*.json
}
x_reset

echo "── 0. harness sanity: confirm the gc SHIM (not the real binary) is what runs ──"
SHIM_CHECK=$(env -i PATH="$SANDBOX_PATH" HOME="$HOME" gc rig list --json)
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
if grep -q "orphan-sweep:shielded-until:" "$SCRIPT"; then ok "ga-114ll self-heal shield signal present"; else bad "orphan-sweep:shielded-until: missing — fix reverted?"; fi

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

echo "── 9. functional (ga-114ll): an active self-heal shield protects a bead across MANY sweeps, even with an unresolvable assignee every time — and it never enters the ledger ──"
SHIELDED_ASSIGNEE="dog-shieldedbutalive"
FUTURE_EPOCH=$(($(date -u +%s) + 3600))
INPROGRESS6='[{"id":"ga-test6","assignee":"'"$SHIELDED_ASSIGNEE"'","labels":["orphan-sweep:shielded","orphan-sweep:shielded-until:'"$FUTURE_EPOCH"'"]}]'
run_sweep '{"sessions":[]}' "$INPROGRESS6" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS6" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS6" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test6)" = "0" ]; then ok "shielded bead survives 3 consecutive sweeps unresolved"; else bad "shielded bead was reset despite an active shield (got $(count_resets ga-test6) resets)"; fi
if [ "$(ledger_count ga-test6)" = "0" ]; then ok "shielded bead never even entered the hysteresis ledger"; else bad "shielded bead leaked into the ledger (got count $(ledger_count ga-test6)) — shield should skip candidacy entirely"; fi

echo "── 10. functional (ga-114ll): an EXPIRED shield does not over-protect — bead still resets after threshold ──"
EXPIRED_ASSIGNEE="dog-expiredshield"
PAST_EPOCH=$(($(date -u +%s) - 3600))
INPROGRESS7='[{"id":"ga-test7","assignee":"'"$EXPIRED_ASSIGNEE"'","labels":["orphan-sweep:shielded","orphan-sweep:shielded-until:'"$PAST_EPOCH"'"]}]'
run_sweep '{"sessions":[]}' "$INPROGRESS7" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS7" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test7)" = "1" ]; then ok "expired-shield bead still resets after 2 consecutive sweeps"; else bad "expired-shield bead was NOT reset — shield incorrectly protected it forever (got $(count_resets ga-test7) resets)"; fi

echo "── 11. functional (ga-114ll): accumulated shield labels (ga-4aree class) — MAX taken, not the first/oldest ──"
MULTI_ASSIGNEE="dog-multishield"
FUTURE_EPOCH2=$(($(date -u +%s) + 3600))
INPROGRESS8='[{"id":"ga-test8","assignee":"'"$MULTI_ASSIGNEE"'","labels":["orphan-sweep:shielded-until:1000000000","orphan-sweep:shielded-until:'"$FUTURE_EPOCH2"'","orphan-sweep:shielded-until:1000000001"]}]'
run_sweep '{"sessions":[]}' "$INPROGRESS8" "gastown.dog" >/dev/null
run_sweep '{"sessions":[]}' "$INPROGRESS8" "gastown.dog" >/dev/null
if [ "$(count_resets ga-test8)" = "0" ]; then ok "MAX of multiple shielded-until labels wins (not the first/an expired one) — bead stays protected"; else bad "took the wrong shielded-until label instead of the MAX — bead was incorrectly reset"; fi

echo "── 12. functional (ga-2m9nqn1): the session roster is read TWICE per sweep in total, not twice per scope (5 rigs = the production shape) ──"
# Before the fix every scope bracketed its own bd list with two reads: 2 x (HQ + 5 rigs) = 12 reads at ~37 s each
# (load 44) = ~450 s against the order's 300 s deadline. The shim logs every call; count them.
RIGS5="property_scrapers marketing lexbh gastown whatsapp_automation"
x_reset
X_RIGS="$RIGS5"; X_RIG_BEADS_DIR="$RIGBEADS"; X_CALL_LOG="$CALLS"
sweep_logged '{"sessions":[]}' '[]' "gastown.dog" >/dev/null
if [ "$(calls '^session list')" = "2" ]; then ok "5 rigs: exactly 2 city-wide session list reads in the whole sweep"; else bad "5 rigs: $(calls '^session list') city-wide session list reads, want 2 (calls: $(call_dump))"; fi
if [ "$(calls '^--rig .*session list')" = "0" ]; then ok "5 rigs: no rig-scoped session list read"; else bad "5 rigs: $(calls '^--rig .*session list') rig-scoped session list reads, want 0 - the 2(N+1) shape is back (calls: $(call_dump))"; fi
BD_OK=1
[ "$(calls '^bd list --status')" = "1" ] || BD_OK=0
for r in $RIGS5; do [ "$(calls "^bd list --rig $r ")" = "1" ] || BD_OK=0; done
[ "$(calls '^bd list')" = "6" ] || BD_OK=0
if [ "$BD_OK" = "1" ]; then ok "HQ and each of the 5 rigs listed exactly once (6 bd lists)"; else bad "bd list is not HQ + 5 rigs once each (calls: $(call_dump))"; fi

echo "── 13. functional (ga-2m9nqn1): the first read is AHEAD of every bd list and the second BEHIND the last one ──"
# The race guard (ga-nvx: a session spawns and claims work after the first read but before a bd list) needs the
# second read to come after the bd lists it protects; with one pair for the whole sweep that means after the LAST one.
FIRST_SESS=$(first_call '^session list'); LAST_SESS=$(last_call '^session list')
FIRST_BD=$(first_call '^bd list');        LAST_BD=$(last_call '^bd list')
if [ "$FIRST_SESS" -gt 0 ] && [ "$FIRST_SESS" -lt "$FIRST_BD" ]; then ok "the first read (call #$FIRST_SESS) is ahead of the first bd list (#$FIRST_BD)"; else bad "the first read is not ahead of every bd list (calls: $(call_dump))"; fi
if [ "$LAST_BD" -gt 0 ] && [ "$LAST_SESS" -gt "$LAST_BD" ]; then ok "the second read (call #$LAST_SESS) is behind the last bd list (#$LAST_BD)"; else bad "the second read is not behind every bd list (calls: $(call_dump))"; fi

echo "── 14. functional (ga-2m9nqn1, ga-u0vzx/ga-nvx race): a claimant alive in only ONE of the two reads is never reset; one alive in neither still is ──"
# 'early' is alive only in the first read (gone by the second); 'late' only in the second (it spawned after the first
# read and claimed work before its scope was listed: the race the second read exists for). Rig beads are judged too.
x_reset
printf '[%s,%s]' "$(bead_json wa-race4 claimant-late-rig)" "$(bead_json wa-race5 claimant-ghost-rig)" > "$RIGBEADS/whatsapp_automation.json"
INPROGRESS_R="[$(bead_json ga-race1 claimant-late),$(bead_json ga-race2 claimant-early),$(bead_json ga-race3 claimant-ghost)]"
ROSTER_FIRST=$(sess_json claimant-early)
ROSTER_SECOND=$(sess_json claimant-late claimant-late-rig)
X_RIGS="$RIGS5"; X_RIG_BEADS_DIR="$RIGBEADS"; X_SESSION_AFTER="$ROSTER_SECOND"; X_CALL_LOG="$CALLS"
sweep_logged "$ROSTER_FIRST" "$INPROGRESS_R" "gastown.dog" >/dev/null
sweep_logged "$ROSTER_FIRST" "$INPROGRESS_R" "gastown.dog" >/dev/null
if [ "$(count_resets ga-race1)" = "0" ] && [ "$(ledger_count ga-race1)" = "0" ]; then ok "claimant alive only in the SECOND read (the race) is not reset and not counted"; else bad "claimant alive only in the second read was reset or counted (resets $(count_resets ga-race1), ledger $(ledger_count ga-race1)) - the ga-nvx race is open"; fi
if [ "$(count_resets ga-race2)" = "0" ] && [ "$(ledger_count ga-race2)" = "0" ]; then ok "claimant alive only in the FIRST read is not reset and not counted"; else bad "claimant alive only in the first read was reset or counted (resets $(count_resets ga-race2), ledger $(ledger_count ga-race2))"; fi
if [ "$(count_resets wa-race4)" = "0" ] && [ "$(ledger_count wa-race4)" = "0" ]; then ok "a RIG bead's claimant alive only in the second read is not reset and not counted"; else bad "rig bead with a claimant alive in the second read was reset or counted (resets $(count_resets wa-race4), ledger $(ledger_count wa-race4))"; fi
if [ "$(count_resets ga-race3)" = "1" ]; then ok "claimant alive in neither read is reset after 2 sweeps (the order still works)"; else bad "claimant alive in neither read: $(count_resets ga-race3) resets, want 1"; fi
if [ "$(count_resets wa-race5)" = "1" ]; then ok "a RIG bead with nobody alive is reset after 2 sweeps (rig scopes are still judged)"; else bad "rig bead with nobody alive: $(count_resets wa-race5) resets, want 1 - rig scopes are no longer swept"; fi

echo "── 15. functional (ga-2m9nqn1): a rig whose bd list fails adds no rows (not judged, not counted) and does not stop cleanup elsewhere ──"
x_reset
printf '[%s]' "$(bead_json mk-down1 claimant-ghost-mk)" > "$RIGBEADS/marketing.json"
printf '[%s]' "$(bead_json lx-up1 claimant-ghost-lx)" > "$RIGBEADS/lexbh.json"
INPROGRESS_H="[$(bead_json ga-hq-dead claimant-ghost-hq)]"
X_RIGS="$RIGS5"; X_RIG_BEADS_DIR="$RIGBEADS"; X_BDLIST_FAIL_RIG="marketing"; X_CALL_LOG="$CALLS"
sweep_logged '{"sessions":[]}' "$INPROGRESS_H" "gastown.dog" >/dev/null
sweep_logged '{"sessions":[]}' "$INPROGRESS_H" "gastown.dog" >/dev/null
if [ "$(count_resets mk-down1)" = "0" ] && [ "$(ledger_count mk-down1)" = "0" ]; then ok "the rig whose bd list failed is neither judged nor counted"; else bad "bead of a rig whose bd list failed was reset or counted (resets $(count_resets mk-down1), ledger $(ledger_count mk-down1))"; fi
if [ "$(count_resets ga-hq-dead)" = "1" ]; then ok "HQ is still swept when a rig is unreachable"; else bad "HQ bead: $(count_resets ga-hq-dead) resets, want 1 - one unreachable rig disabled cleanup"; fi
if [ "$(count_resets lx-up1)" = "1" ]; then ok "the rig listed AFTER the unreachable one is still swept"; else bad "rig after the unreachable one: $(count_resets lx-up1) resets, want 1"; fi

echo "── 16. functional (ga-2m9nqn1): a roster that is missing, or is not a roster, ends the sweep before anything is reset or counted ──"
x_reset
INPROGRESS_D="[$(bead_json ga-inert1 claimant-ghost-d)]"
X_RIGS="$RIGS5"; X_RIG_BEADS_DIR="$RIGBEADS"; X_CALL_LOG="$CALLS"
inert_case() {
    # $1 label, $2 = what the 1st read answers, $3 = bd list calls the first sweep may make, $4 = text expected on stderr.
    # Two sweeps: enough to cross CONFIRM_THRESHOLD if a failed sweep counted for anything.
    local rc=0
    sweep_logged "$2" "$INPROGRESS_D" "gastown.dog" >/dev/null 2>"$WORK/err.txt" || rc=$?
    if [ "$rc" = "0" ]; then ok "$1: the sweep exits 0"; else bad "$1: the sweep exited $rc"; fi
    if [ "$(calls '^bd list')" = "$3" ]; then ok "$1: $3 bd list call(s) before it stopped"; else bad "$1: $(calls '^bd list') bd list calls, want $3 (calls: $(call_dump))"; fi
    if grep -q -- "$4" "$WORK/err.txt"; then ok "$1: the reason is on stderr"; else bad "$1: stderr does not say why: $(cat "$WORK/err.txt")"; fi
    sweep_logged "$2" "$INPROGRESS_D" "gastown.dog" >/dev/null 2>&1 || true
    if [ "$(count_resets ga-inert1)" = "0" ]; then ok "$1: bead NOT reset after 2 sweeps"; else bad "$1: bead reset on an unreadable roster"; fi
    if [ "$(ledger_count ga-inert1)" = "0" ]; then ok "$1: nothing counted toward the threshold"; else bad "$1: ledger count $(ledger_count ga-inert1) - the unreadable sweep counted"; fi
}
X_SESSION_FAIL_ON=1
inert_case "first read fails (rc 1)" '{"sessions":[]}' 0 "before the bead lists"
X_SESSION_FAIL_ON=2
inert_case "second read fails (rc 1)" '{"sessions":[]}' 6 "after the bead lists"
X_SESSION_FAIL_ON=''
inert_case "first read answers no bytes (rc 0)" '' 0 "before the bead lists"
inert_case "first read answers garbage (rc 0)" 'not a roster' 0 "before the bead lists"
inert_case "first read answers JSON with no .sessions (rc 0)" '{"ok":false}' 0 "before the bead lists"
inert_case "first read answers sessions=null (rc 0)" '{"sessions":null}' 0 "before the bead lists"
inert_case "first read answers sessions as an object (rc 0)" '{"sessions":{"a":1}}' 0 "before the bead lists"
X_SESSION_AFTER='not a roster'
inert_case "second read answers garbage (rc 0)" '{"sessions":[]}' 6 "after the bead lists"
X_SESSION_AFTER='{"ok":false}'
inert_case "second read answers JSON with no .sessions (rc 0)" '{"sessions":[]}' 6 "after the bead lists"
X_SESSION_AFTER=''
sweep_logged '{"sessions":[]}' "$INPROGRESS_D" "gastown.dog" >/dev/null
if [ "$(ledger_count ga-inert1)" = "1" ]; then ok "a healthy sweep right after counts exactly 1: the unreadable ones left no residue"; else bad "healthy sweep after the unreadable ones: ledger count $(ledger_count ga-inert1), want 1"; fi
sweep_logged '{"sessions":[]}' "$INPROGRESS_D" "gastown.dog" >/dev/null
if [ "$(count_resets ga-inert1)" = "1" ]; then ok "and the next healthy sweep resets it (the threshold still works)"; else bad "second healthy sweep: $(count_resets ga-inert1) resets, want 1"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# gate-guard-ga-8upzkk-asleep-owner.selftest.sh — Drift-guard for ga-8upzkk.
#
# Bug (measured 25-26/09, wa-qbwxm — an Athos P0 owned by the persistent crew
# batista-wa): the GAP-1 never-branched reconciler in quality-gate-guard.sh
# stripped `story:in-flight` from an open bead whose owner was a persistent
# crew that had merely gone to sleep before pushing a branch. The decision
# asked session_matches_author "is the assignee alive?", and that predicate
# counts `asleep` as DEAD — correct for a branch AUTHOR at the gate, wrong for
# a crew that owns a bead and wakes on its own. The card fell into Travadas
# while its owner was still the owner; the Mayor re-added the label by hand
# twice.
#
# The fix is one pure decision (gap1_never_branched_action, over the pure
# three-state bead_owner_session_state) that both never-branched call sites —
# the HQ sweep and the rig-DB sweep — act on. Owner live (asleep included) →
# skip; owner gone (no session, or closed/archived/drained/quarantined/
# failed-create) → still strip; owner UNREADABLE (bead or session list) → skip,
# never strip. This harness covers:
#   1. bead_owner_session_state's three states,
#   2. gap1_never_branched_action end to end (the acceptance cases),
#   3. a mutation-lock replaying the OLD decision on the same fixture — it must
#      strip, proving the fixture reproduces the bug and the new asserts are
#      not tautologies,
#   4. session_matches_author left alone for its other callers (ga-625z4),
#   5. drift-guards that BOTH call sites really call the new decision.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "── gate-guard GAP-1 asleep-owner drift-guard (ga-8upzkk) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with set -euo pipefail; this harness counts its own pass/fail

for fn in bead_owner_session_state gap1_never_branched_action classify_inflight_gap1 session_matches_author; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by guard (ga-8upzkk)"; exit 1; }
done

# ── Fixtures ────────────────────────────────────────────────────────────────
# bd show shape after the guard's own normalisation (object, not array). The
# assignee is the named-crew session_name form, as bd stores it.
SHOW_CREW='{"id":"wa-qbwxm","status":"in_progress","assignee":"batista-wa"}'
SHOW_CREW_ARRAY='[{"id":"wa-qbwxm","status":"in_progress","assignee":"batista-wa"}]'
SHOW_UNASSIGNED='{"id":"wa-qbwxm","status":"open"}'
SHOW_NULL_ASSIGNEE='{"id":"wa-qbwxm","status":"open","assignee":null}'

# A session list in the real `gc session list --json` shape: a non-empty list
# with an unrelated live row, plus the crew row in whatever state the case sets.
sessions_with_crew_state() {
  printf '{"sessions":[{"session_name":"gastown__mayor","name":"gastown.mayor","alias":"gastown.mayor","id":"gh-050","closed":false,"state":"active"},{"session_name":"batista-wa","name":"batista-wa","alias":"batista-wa","id":"ga-crew1","closed":false,"state":"%s"}]}' "$1"
}
SESS_NO_CREW='{"sessions":[{"session_name":"gastown__mayor","name":"gastown.mayor","alias":"gastown.mayor","id":"gh-050","closed":false,"state":"active"}]}'

echo "── 1. bead_owner_session_state: three states ──"
eq "crew row asleep → live (the wa-qbwxm shape)"        "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state asleep)")"        "live"
eq "crew row active → live"                             "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state active)")"        "live"
eq "crew row with an unlisted state (awake) → live"     "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state awake)")"         "live"
eq "crew row drained → gone"                            "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state drained)")"       "gone"
eq "crew row closed (state) → gone"                     "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state closed)")"        "gone"
eq "crew row archived → gone"                           "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state archived)")"      "gone"
eq "crew row quarantined → gone"                        "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state quarantined)")"   "gone"
eq "crew row failed-create → gone"                      "$(bead_owner_session_state "$SHOW_CREW" "$(sessions_with_crew_state failed-create)")" "gone"
eq "crew row closed:true + state asleep → gone (closed wins)" \
   "$(bead_owner_session_state "$SHOW_CREW" '{"sessions":[{"session_name":"x","closed":false},{"session_name":"batista-wa","closed":true,"state":"asleep"}]}')" "gone"
eq "no session for the assignee in a non-empty list → gone" "$(bead_owner_session_state "$SHOW_CREW" "$SESS_NO_CREW")" "gone"
eq "bd show as an array is accepted"                    "$(bead_owner_session_state "$SHOW_CREW_ARRAY" "$(sessions_with_crew_state asleep)")" "live"
eq "matches on .alias when session_name differs" \
   "$(bead_owner_session_state '{"id":"b","assignee":"gastown.mayor"}' '{"sessions":[{"session_name":"gastown__mayor","alias":"gastown.mayor","closed":false,"state":"asleep"}]}')" "live"

eq "no assignee (bead read fine) → gone"                "$(bead_owner_session_state "$SHOW_UNASSIGNED" "$SESS_NO_CREW")"                       "gone"
eq "assignee:null (bead read fine) → gone"              "$(bead_owner_session_state "$SHOW_NULL_ASSIGNEE" "$SESS_NO_CREW")"                    "gone"
eq "no assignee needs no session list at all → gone"    "$(bead_owner_session_state "$SHOW_UNASSIGNED" "")"                                    "gone"

# The unknowns — every way the read can fail or come back with nothing.
eq "session list '{}' (the callers' failed-read fallback) → unknown" "$(bead_owner_session_state "$SHOW_CREW" '{}')"                    "unknown"
eq "session list empty string → unknown"                "$(bead_owner_session_state "$SHOW_CREW" '')"                                          "unknown"
eq "session list unparseable → unknown"                 "$(bead_owner_session_state "$SHOW_CREW" 'not json at all')"                          "unknown"
eq "session list {\"sessions\":[]} (empty) → unknown"   "$(bead_owner_session_state "$SHOW_CREW" '{"sessions":[]}')"                         "unknown"
eq "session list bare [] → unknown"                     "$(bead_owner_session_state "$SHOW_CREW" '[]')"                                        "unknown"
eq "session list {\"sessions\":null} → unknown"         "$(bead_owner_session_state "$SHOW_CREW" '{"sessions":null}')"                        "unknown"
eq "session list {\"sessions\":\"x\"} → unknown"        "$(bead_owner_session_state "$SHOW_CREW" '{"sessions":"x"}')"                         "unknown"
eq "bd show empty (bd failed) → unknown, NOT 'no assignee'" "$(bead_owner_session_state '' "$SESS_NO_CREW")"                                   "unknown"
eq "bd show unparseable → unknown"                      "$(bead_owner_session_state 'garbage' "$SESS_NO_CREW")"                               "unknown"
eq "bd show an object with no id → unknown"             "$(bead_owner_session_state '{"assignee":"batista-wa"}' "$SESS_NO_CREW")"             "unknown"

echo "── 2. gap1_never_branched_action: the acceptance cases ──"
eq "ASLEEP crew owns the bead, no branch → skip (was strip)" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state asleep)")" "skip:live-builder"
eq "control: crew session drained → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state drained)")" "strip:no-branch"
eq "control: crew session closed → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state closed)")" "strip:no-branch"
eq "control: crew session archived → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state archived)")" "strip:no-branch"
eq "control: crew session quarantined → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state quarantined)")" "strip:no-branch"
eq "control: crew session failed-create → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state failed-create)")" "strip:no-branch"
eq "control: assignee has no session at all → still strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$SESS_NO_CREW")" "strip:no-branch"
eq "control: unassigned bead (the original never-started shape) → still strip" \
   "$(gap1_never_branched_action "$SHOW_UNASSIGNED" "$SESS_NO_CREW")" "strip:no-branch"
eq "control: live (active) owner → skip" \
   "$(gap1_never_branched_action "$SHOW_CREW" "$(sessions_with_crew_state active)")" "skip:live-builder"

eq "session-list read FAILED ('{}' fallback) → skip, never strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" '{}')" "skip:indeterminate"
eq "session list comes back EMPTY → skip, never strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" '{"sessions":[]}')" "skip:indeterminate"
eq "session list unparseable → skip, never strip" \
   "$(gap1_never_branched_action "$SHOW_CREW" 'oops')" "skip:indeterminate"
eq "bd show FAILED (empty) → skip, never read as 'unassigned → strip'" \
   "$(gap1_never_branched_action '' "$SESS_NO_CREW")" "skip:indeterminate"

echo "── 3. mutation-lock: the OLD decision strips the asleep crew (the bug) ──"
# Replays the pre-fix call site verbatim: session_matches_author → HAS_LIVE, then
# classify_inflight_gap1 ... "none". On the very fixture the new function skips,
# this must strip — otherwise the asserts above prove nothing about the fix.
_old_decision() {
  local show="$1" sessions="$2" assignee has_live=0
  assignee=$(printf '%s' "$show" | jq -r '(if type=="array" then .[0] else . end) | .assignee // ""' 2>/dev/null)
  if [ -n "$assignee" ] && [ "$assignee" != "null" ]; then
    [ "$(session_matches_author "$assignee" "$sessions")" = "1" ] && has_live=1
  fi
  classify_inflight_gap1 "open" "0" "$has_live" "none"
}
eq "OLD path on an asleep crew → strip:no-branch (reproduces the wa-qbwxm strip)" \
   "$(_old_decision "$SHOW_CREW" "$(sessions_with_crew_state asleep)")" "strip:no-branch"
eq "OLD path on a FAILED session-list read ('{}') → strip:no-branch (the error==empty collapse)" \
   "$(_old_decision "$SHOW_CREW" '{}')" "strip:no-branch"

echo "── 4. classify_inflight_gap1 'unknown' owner + session_matches_author untouched ──"
eq "unknown owner + no branch → skip:indeterminate"          "$(classify_inflight_gap1 open   0 unknown none)" "skip:indeterminate"
eq "unknown owner + merged branch → skip:indeterminate"      "$(classify_inflight_gap1 open   0 unknown 1)"    "skip:indeterminate"
eq "closed still wins over an unknown owner"                 "$(classify_inflight_gap1 closed 0 unknown none)" "skip:already-handled"
eq "gate:passed still wins over an unknown owner"            "$(classify_inflight_gap1 open   1 unknown none)" "skip:already-handled"
eq "live owner (1) still wins over 'none'"                   "$(classify_inflight_gap1 open   0 1 none)"       "skip:live-builder"
eq "confirmed-gone owner (0) + none → strip:no-branch unchanged" "$(classify_inflight_gap1 open 0 0 none)"     "strip:no-branch"
eq "session_matches_author STILL reads asleep as dead (other callers, ga-625z4)" \
   "$(session_matches_author "batista-wa" "$(sessions_with_crew_state asleep)")" "0"

echo "── 5. drift-guard: BOTH never-branched call sites use the new decision ──"
if grep -Fq 'gap1_never_branched_action "$OI_SHOW" "$SESSION_JSON"' "$GUARD"; then
  ok "HQ sweep decides via gap1_never_branched_action (bead show + session list)"
else
  bad "HQ GAP-1 never-branched path does not call gap1_never_branched_action — regressed to the asleep-blind decision"
fi
if grep -Fq 'gap1_never_branched_action "$RIGSCAN_OI_SHOW" "$RIGSCAN_SESSION_JSON"' "$GUARD"; then
  ok "rig-DB sweep decides via gap1_never_branched_action (bead show + session list)"
else
  bad "rig-DB GAP-1 never-branched path does not call gap1_never_branched_action — the rig twin regressed (wa-* beads are exactly this path)"
fi
if grep -Fq 'classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "none"' "$GUARD" \
   || grep -Fq 'classify_inflight_gap1 "open" "0" "$RIGSCAN_HAS_LIVE_ASSIGNEE" "none"' "$GUARD"; then
  bad "a never-branched call site still classifies with the strict HAS_LIVE_ASSIGNEE (asleep = dead) — the old decision is back"
else
  ok "no never-branched call site classifies with the strict asleep-is-dead flag any more"
fi
_SKIP_LIVE_ARMS=$(grep -c 'skip:live-builder)' "$GUARD")
_SKIP_INDET_ARMS=$(grep -c 'skip:indeterminate)' "$GUARD")
if [ "$_SKIP_LIVE_ARMS" -ge 2 ] && [ "$_SKIP_INDET_ARMS" -ge 2 ]; then
  ok "both call sites have explicit skip:live-builder / skip:indeterminate arms (found $_SKIP_LIVE_ARMS / $_SKIP_INDET_ARMS), so the new outcomes are logged, not lost in the catch-all"
else
  bad "expected >=2 skip:live-builder) and >=2 skip:indeterminate) case arms, found $_SKIP_LIVE_ARMS / $_SKIP_INDET_ARMS"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

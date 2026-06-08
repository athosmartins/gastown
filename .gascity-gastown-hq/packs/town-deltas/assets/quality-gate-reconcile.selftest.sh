#!/usr/bin/env bash
# quality-gate-reconcile.selftest.sh — Prove the ga-tmug gate reconciler logic in
# isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-tmug: a crashed/aborted gate run strands beads forever via two vectors:
#   Vector A — a marker stuck in a TRANSIENT state (gate-status:dispatching from a
#              dead dispatcher, or gate-status:claimed from a dead guard) is never
#              reclaimed because no SINGLE sweep reclaims BOTH past a TTL.
#   Vector B — the guard's `quality-gate:` gate-run bead is left pinned in
#              gate-status:running forever: the dispatcher only drives its OWN
#              `gate-run:` bead to terminal, so the guard's sibling orphans (9 such
#              beads observed live, each with a terminal `passed` sibling).
#
# The fix lives in quality-gate-guard.sh (the guard is an engine INDEPENDENT of
# the dispatcher, and already runs every 120s in-place — so the recovery activates
# with zero deploy steps, avoiding the ga-iwv0 dormant-daemon trap a NEW launchd
# engine would hit). Two pure decision functions drive it:
#   reconcile_marker_action  — Vector A: requeue dispatching→queued / claimed→ready
#                              past TTL, capping re-queues to avoid thrash (→error).
#   reconcile_gaterun_action — Vector B: supersede a running gate-run once its
#                              OWN marker is terminal/gone (keying on the marker —
#                              NOT a bare sibling-terminal check, which would
#                              false-positive on a re-dispatched live run that
#                              shares a source bead with an older failed attempt).
#
# This harness SOURCES the guard for its pure functions (single source of truth,
# no copy-drift) and unit-tests every branch, then DRIFT-GUARDS the real script so
# a future refactor that drops the labels/queries fails loudly. Exit 0 iff every
# assertion holds.

# set -e is intentional: an unexpected command failure in any test helper is a
# harness bug, not a graceful FAIL — we want a hard abort, not silent skips.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL pure functions from the guard (lib-only mode = no live sweep) ──
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type reconcile_marker_action  >/dev/null 2>&1 || { echo "FATAL: reconcile_marker_action not defined by guard"; exit 1; }
type reconcile_gaterun_action >/dev/null 2>&1 || { echo "FATAL: reconcile_gaterun_action not defined by guard"; exit 1; }
type age_minutes_of           >/dev/null 2>&1 || { echo "FATAL: age_minutes_of not defined by guard"; exit 1; }
type parse_marker_id          >/dev/null 2>&1 || { echo "FATAL: parse_marker_id not defined by guard"; exit 1; }
type classify_inflight_gap1   >/dev/null 2>&1 || { echo "FATAL: classify_inflight_gap1 not defined by guard"; exit 1; }
type classify_parent_gap2     >/dev/null 2>&1 || { echo "FATAL: classify_parent_gap2 not defined by guard"; exit 1; }

# ── 0. age_minutes_of must read the bead 'Z' timestamps as UTC (not local) ───
# Regression lock for the TZ bug that made every age negative (off by the host's
# UTC offset), silently disabling all reclaim/abort TTLs. Both args are fixed, so
# the result is deterministic regardless of the host clock or timezone.
echo "── 0. age_minutes_of (UTC parse, TZ-independent) ──"
# 2026-06-05T13:27:29Z = epoch 1780666049; +84m later = now 1780671107.
eq "UTC ts parsed as UTC → +84m"  "$(age_minutes_of '2026-06-05T13:27:29Z' 1780671107)" "84"
eq "same instant → 0m"            "$(age_minutes_of '2026-06-05T13:27:29Z' 1780666049)" "0"
eq "empty timestamp → 0 (safe)"   "$(age_minutes_of '' 1780671107)" "0"

# ── 0b. parse_marker_id — whitespace normalisation (the DRY fix for ga-b92q) ─
# The same description is parsed in two places (guard Step 0b, dispatcher
# supersede_sibling_runs). A divergent sed pattern (' *' vs '[[:space:]]*' and
# presence/absence of trailing tr -d) caused silent mismatch on tab separators
# or trailing whitespace. parse_marker_id is the single canonical implementation.
echo "── 0b. parse_marker_id (whitespace normalisation) ──"
eq "plain id → stripped"           "$(parse_marker_id $'marker_id: ga-abc123\nbranch: foo')" "ga-abc123"
eq "tab separator → stripped"      "$(parse_marker_id $'marker_id:\tga-xyz\nbranch: foo')"   "ga-xyz"
eq "trailing whitespace → stripped" "$(parse_marker_id $'marker_id: ga-tst  \nbranch: foo')" "ga-tst"
eq "tab + trailing space → stripped" "$(parse_marker_id $'marker_id:\tga-tst  \nbranch: foo')" "ga-tst"
eq "no marker_id line → empty"     "$(parse_marker_id $'branch: foo\nauthor: bar')"           ""
eq "empty description → empty"     "$(parse_marker_id '')"                                    ""

# ── 1. Vector A — marker reclaim decision ────────────────────────────────────
# Signature: reconcile_marker_action <status> <age_min> <ttl_min> <count> <max>
echo "── 1. reconcile_marker_action (Vector A: dispatching+claimed reclaim) ──"
eq "dispatching within TTL → skip"            "$(reconcile_marker_action dispatching 10 30 0 3)" "skip"
eq "claimed within TTL → skip"                "$(reconcile_marker_action claimed     29 30 0 3)" "skip"
eq "age == TTL boundary → skip (not >)"       "$(reconcile_marker_action dispatching 30 30 0 3)" "skip"
eq "dispatching past TTL, fresh → requeue:queued" "$(reconcile_marker_action dispatching 31 30 0 3)" "requeue:queued"
eq "claimed past TTL, fresh → requeue:ready"  "$(reconcile_marker_action claimed     31 30 0 3)" "requeue:ready"
eq "dispatching past TTL, count=2<3 → requeue" "$(reconcile_marker_action dispatching 99 30 2 3)" "requeue:queued"
eq "past TTL, count == cap → error (thrash)"  "$(reconcile_marker_action dispatching 99 30 3 3)" "error"
eq "past TTL, count > cap → error"            "$(reconcile_marker_action claimed     99 30 9 3)" "error"
eq "unknown status past TTL → skip (safe)"    "$(reconcile_marker_action queued      99 30 0 3)" "skip"

# ── 2. Vector B — gate-run reconcile decision ────────────────────────────────
# Signature: reconcile_gaterun_action <age_min> <ttl_min> <marker_active 0|1>
echo "── 2. reconcile_gaterun_action (Vector B: orphan gate-run cleanup) ──"
eq "marker active, young → skip (in-flight)"      "$(reconcile_gaterun_action 5  90 1)" "skip"
eq "marker active, age==TTL → skip (not >)"       "$(reconcile_gaterun_action 90 90 1)" "skip"
eq "marker terminal/gone, young → supersede"      "$(reconcile_gaterun_action 1  90 0)" "supersede:marker"
eq "marker terminal/gone, old → supersede"        "$(reconcile_gaterun_action 999 90 0)" "supersede:marker"
eq "marker active but age>TTL → abort:age"        "$(reconcile_gaterun_action 91 90 1)" "abort:age"
# The killer real-world case (ga-twp8): an orphan whose marker is still
# 'dispatching' must NOT be killed just because a SIBLING attempt failed —
# marker_active=1 protects the possibly-live re-dispatch.
eq "re-dispatch live run (marker active) → skip"  "$(reconcile_gaterun_action 3 90 1)" "skip"

# ── 3. Drift-guard: the guard still wires both vectors into the live sweep ────
echo "── 3. drift-guard: guard implements both reconciler vectors ──"
grep -q 'GATE_GUARD_LIB_ONLY'                "$GUARD" && ok "guard is sourceable in lib-only mode"        || bad "guard missing lib-only guard"
grep -q 'reconcile_marker_action()'          "$GUARD" && ok "guard defines reconcile_marker_action"      || bad "guard missing reconcile_marker_action def"
grep -q 'reconcile_gaterun_action()'         "$GUARD" && ok "guard defines reconcile_gaterun_action"     || bad "guard missing reconcile_gaterun_action def"
# Vector A: unified reclaim must scan BOTH transient states in ONE place.
grep -q 'gate-status:dispatching'            "$GUARD" && ok "guard reclaims dispatching markers"         || bad "guard does not scan dispatching"
grep -q 'gate-status:claimed'                "$GUARD" && ok "guard reclaims claimed markers"             || bad "guard does not scan claimed"
grep -q 'gate-reclaim-count:'                "$GUARD" && ok "guard tracks reclaim-count (thrash cap)"    || bad "guard missing reclaim-count label"
grep -q 'MAX_RECLAIMS'                       "$GUARD" && ok "guard caps re-queues (MAX_RECLAIMS)"        || bad "guard missing MAX_RECLAIMS"
# Vector B: supersede orphans by marker state + keep the age fallback.
# (ga-jhyu: terminal transitions now flow through set_gate_status, which emits
#  the gate-status:superseded/aborted label at runtime — assert the call sites.)
grep -q 'set_gate_status "$GR_ID" "superseded"' "$GUARD" && ok "guard supersedes orphan gate-runs (via set_gate_status)" || bad "guard missing set_gate_status superseded"
grep -q 'set_gate_status "$GR_ID" "aborted"'    "$GUARD" && ok "guard keeps age-TTL abort fallback (via set_gate_status)" || bad "guard missing set_gate_status aborted"
grep -q 'marker_id'                          "$GUARD" && ok "guard keys gate-run cleanup on marker_id"   || bad "guard missing marker_id linkage"
grep -q 'date -j -u -f'                      "$GUARD" && ok "guard parses bead timestamps as UTC (-u)"   || bad "guard missing -u (TZ bug regressed)"
# Dispatcher Step 0a (D_EPOCH) + reviewer janitor (R_EPOCH) must ALL parse UTC.
# A bare `grep 'date -j -u -f'` would false-pass (R_EPOCH already has it), so we
# assert the buggy non-UTC form is absent everywhere in the dispatcher (ga-35zp1).
grep -q 'date -j -f "%Y-%m-%dT%H:%M:%S"'     "$DISPATCHER" && bad "dispatcher has a non-UTC BSD date parse (date -j -f without -u — TZ age bug, ga-35zp1)" || ok "dispatcher BSD date parses are all UTC (-u)"
# parse_marker_id: single canonical definition in guard, both scripts converge on it.
grep -q 'parse_marker_id()'                  "$GUARD" && ok "guard defines parse_marker_id (canonical)"   || bad "guard missing parse_marker_id def"
grep -q 'parse_marker_id'                    "$GUARD" && ok "guard Step 0b uses parse_marker_id"          || bad "guard Step 0b not using parse_marker_id"
grep -q 'GATE_GUARD_LIB_ONLY=1.*quality-gate-guard' "$DISPATCHER" \
  && ok "dispatcher sources guard lib for parse_marker_id" \
  || bad "dispatcher not sourcing guard lib (DRY violation)"
grep -q 'parse_marker_id'                    "$DISPATCHER" && ok "dispatcher supersede_sibling_runs uses parse_marker_id" || bad "dispatcher not using parse_marker_id"

# ── 4. drift-guard: dispatcher proactively supersedes the guard's sibling run ─
echo "── 4. drift-guard: dispatcher proactive sibling supersede ──"
grep -q 'supersede_sibling_runs()'           "$DISPATCHER" && ok "dispatcher defines supersede_sibling_runs"        || bad "dispatcher missing supersede_sibling_runs def"
eq "dispatcher calls it on BOTH terminal paths (PASS+FAIL)" \
   "$(grep -c 'supersede_sibling_runs "' "$DISPATCHER")" "2"
grep -q 'set_gate_status "$sibling_id" "superseded"' "$DISPATCHER" && ok "dispatcher supersedes (not deletes) siblings (via set_gate_status)" || bad "dispatcher missing set_gate_status sibling supersede"

# ── 5. classify_inflight_gap1 (ga-pa36 GAP-1: merged-but-OPEN beads) ─────────
# Signature: classify_inflight_gap1 <status> <has_gate_passed> <has_live_assignee> <branch_merged>
echo "── 5. classify_inflight_gap1 (GAP-1: merged-but-OPEN) ──"
eq "closed bead → already-handled"         "$(classify_inflight_gap1 closed 0 0 1)"   "skip:already-handled"
eq "open+gate:passed → already-handled"    "$(classify_inflight_gap1 open   1 0 1)"   "skip:already-handled"
eq "live builder → safe-skip"              "$(classify_inflight_gap1 open   0 1 1)"   "skip:live-builder"
eq "branch merged, no builder → strip"     "$(classify_inflight_gap1 open   0 0 1)"   "strip:merged"
eq "branch not merged → skip"              "$(classify_inflight_gap1 open   0 0 0)"   "skip:not-merged"
eq "branch state unknown → safe-skip"      "$(classify_inflight_gap1 open   0 0 x)"   "skip:indeterminate"
eq "live builder trumps merged branch"     "$(classify_inflight_gap1 open   0 1 1)"   "skip:live-builder"
eq "already-handled before live check"     "$(classify_inflight_gap1 closed 0 1 1)"   "skip:already-handled"

# ── 6. classify_parent_gap2 (ga-pa36 GAP-2: parent-story stranding) ──────────
# Signature: classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed>
echo "── 6. classify_parent_gap2 (GAP-2: parent-story stranding) ──"
eq "not pilot:dispatched → skip"                       "$(classify_parent_gap2 0 0 1 0 0)"  "skip:not-dispatched"
eq "live assignee on parent → safe-skip"               "$(classify_parent_gap2 1 1 1 0 0)"  "skip:live-assignee"
eq "no sling bead found → safe-skip"                   "$(classify_parent_gap2 1 0 0 0 0)"  "skip:no-sling"
eq "sling gate:needs-fix → free FAIL-stranded"         "$(classify_parent_gap2 1 0 1 1 0)"  "free:fail-stranded"
eq "sling gate:needs-fix beats sling closed"           "$(classify_parent_gap2 1 0 1 1 1)"  "free:fail-stranded"
eq "sling closed (PASS) → free PASS-stranded"          "$(classify_parent_gap2 1 0 1 0 1)"  "free:pass-stranded"
eq "sling still active → skip"                         "$(classify_parent_gap2 1 0 1 0 0)"  "skip:active-sling"

# ── 7. drift-guard: guard implements both GAP-1 and GAP-2 sweeps ──────────────
echo "── 7. drift-guard: guard implements ga-pa36 GAP-1 + GAP-2 sweeps ──"
grep -q 'classify_inflight_gap1()'  "$GUARD" && ok "guard defines classify_inflight_gap1"  || bad "guard missing classify_inflight_gap1 def"
grep -q 'classify_parent_gap2()'    "$GUARD" && ok "guard defines classify_parent_gap2"    || bad "guard missing classify_parent_gap2 def"
grep -q 'Step 0c.1'                 "$GUARD" && ok "guard implements GAP-1 sweep (Step 0c.1)"  || bad "guard missing Step 0c.1"
grep -q 'Step 0c.2'                 "$GUARD" && ok "guard implements GAP-2 sweep (Step 0c.2)"  || bad "guard missing Step 0c.2"
grep -q 'pilot:dispatched'          "$GUARD" && ok "guard sweeps pilot:dispatched beads (GAP-2)" || bad "guard does not check pilot:dispatched"
grep -q 'Sling task bead'           "$GUARD" && ok "guard parses 'Sling task bead' comment"  || bad "guard missing Sling-task-bead parse"
grep -q 'gate:needs-fix'            "$GUARD" && ok "guard checks gate:needs-fix on sling bead"  || bad "guard missing gate:needs-fix check"
grep -q 'free:fail-stranded'        "$GUARD" && ok "guard handles free:fail-stranded action"    || bad "guard missing free:fail-stranded handler"
grep -q 'free:pass-stranded'        "$GUARD" && ok "guard handles free:pass-stranded action"    || bad "guard missing free:pass-stranded handler"
grep -q 'merge-base --is-ancestor'  "$GUARD" && ok "guard uses merge-base for branch check (GAP-1)" || bad "guard missing merge-base check"
# Fix: reconcile_marker_action must remove BOTH transient labels before target state (ga-pa36 gate-feedback)
[ "$(grep -c 'label remove.*gate-status:dispatching' "$GUARD")" -ge 2 ] \
  && ok "requeue:ready removes gate-status:dispatching (both transient labels cleared)" \
  || bad "requeue:ready missing label remove gate-status:dispatching — must clear BOTH transients"
[ "$(grep -c 'label remove.*gate-status:claimed' "$GUARD")" -ge 2 ] \
  && ok "requeue:queued removes gate-status:claimed (both transient labels cleared)" \
  || bad "requeue:queued missing label remove gate-status:claimed — must clear BOTH transients"
# Fix: live-builder check must use exact match, not substring contains (ga-pa36 gate-feedback)
! grep -q '| contains(\.' "$GUARD" \
  && ok "live-builder checks use exact match (no substring contains)" \
  || bad "live-builder check still uses substring contains — must use exact match"

echo ""
# ── 8. ga-jhyu: terminal gate beads are CLOSED (not just relabeled), and
#       set_gate_status leaves EXACTLY ONE gate-status:* label ────────────────
# Bug ga-jhyu: terminal transitions relabeled markers/gate-runs (passed/failed/
# superseded/aborted) but NEVER `bd close`d them — 55+ beads stranded OPEN, then
# promoted to persistent by wisp-compact. Fix (A): close at every terminal site.
# Fix (D): a single set_gate_status() that strips ALL gate-status:* then adds one
# (the legacy remove-then-add leaked dual labels: passed+superseded, done+failed).
echo "── 8. ga-jhyu: close-at-terminal + atomic set_gate_status ──"

# (D) Single source of truth: guard defines set_gate_status; dispatcher inherits
#     it via the guard lib source (same DRY contract as parse_marker_id). No
#     second copy in the dispatcher → impossible to drift.
grep -q 'set_gate_status()'                  "$GUARD"      && ok "guard defines set_gate_status (canonical)"        || bad "guard missing set_gate_status def"
! grep -q '^set_gate_status() {'             "$DISPATCHER" && ok "dispatcher does NOT redefine set_gate_status (DRY, sourced from guard)" || bad "dispatcher redefines set_gate_status — drift risk"
grep -qE 'startswith\("gate-status:"\)'      "$GUARD"      && ok "set_gate_status strips ALL gate-status:* (atomic)"  || bad "set_gate_status not stripping all gate-status:* labels"

# (A) Every terminal transition is followed by a bd close on the SAME id.
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: PASSED'      "$DISPATCHER" && ok "PASS closes the marker"            || bad "PASS path does not close the marker"
grep -q 'close "$GATE_RUN_ID" -r "gate-run terminal: PASSED'       "$DISPATCHER" && ok "PASS closes the gate-run"           || bad "PASS path does not close the gate-run"
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: FAILED'     "$DISPATCHER" && ok "FAIL closes the marker"            || bad "FAIL path does not close the marker"
grep -q 'close "$GATE_RUN_ID" -r "gate-run terminal: FAILED'      "$DISPATCHER" && ok "FAIL closes the gate-run"          || bad "FAIL path does not close the gate-run"
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: SUPERSEDED' "$DISPATCHER" && ok "already-merged closes the marker"  || bad "already-merged path does not close the marker"
grep -q 'close "$sibling_id"'                "$DISPATCHER" && ok "supersede_sibling_runs closes the sibling gate-run"     || bad "sibling supersede does not close the gate-run"
[ "$(grep -c 'close "$GR_ID"' "$GUARD")" -ge 2 ] && ok "guard Vector B closes superseded+aborted gate-runs" || bad "guard Vector B does not close terminal gate-runs (need >=2)"

# (A-invariant) gate-status:error is terminal-FAILED but must stay OPEN so
# gate-health-monitor.py can page a human (ga-piscg). Closing it would blind the
# escalation — assert NO close follows the error transitions.
! grep -A2 'set_gate_status "$T_ID" "error"'     "$GUARD" | grep -q 'close "$T_ID"'     && ok "Vector A error marker NOT closed (gate-health-monitor invariant)"    || bad "Vector A error marker is closed — breaks human paging (ga-piscg)"
! grep -A2 'set_gate_status "$MARKER_ID" "error"' "$GUARD" | grep -q 'close "$MARKER_ID"' && ok "validation-error marker NOT closed (gate-health-monitor invariant)" || bad "validation-error marker is closed — breaks human paging (ga-piscg)"

# (D-unit) EXERCISE set_gate_status with a mock bd: a bead carrying TWO leaked
# gate-status labels must end with exactly ONE (the target), non-gate labels kept.
echo "── 8b. set_gate_status unit-test (mock bd, real fn from guard) ──"
# Run inline (NOT a subshell) so ok/bad update the real PASS/FAIL counters. This
# is the last section; the mock bd is unset immediately after.
GC_CITY=/tmp/ga-jhyu-fake-city
_MOCK_LABELS="gate-status:running gate-status:dispatching other:keepme"
bd() {
  local verb="$3"
  if [ "$verb" = "show" ]; then
    local arr="" l
    for l in $_MOCK_LABELS; do arr="${arr}\"$l\","; done
    printf '[{"labels":[%s]}]' "${arr%,}"
    return 0
  fi
  if [ "$verb" = "label" ]; then
    local op="$4" lbl="$6"
    case "$op" in
      remove) _MOCK_LABELS=$(printf '%s\n' $_MOCK_LABELS | grep -vx "$lbl" | tr '\n' ' ' || true) ;;
      add)    printf '%s\n' $_MOCK_LABELS | grep -qx "$lbl" || _MOCK_LABELS="$_MOCK_LABELS $lbl" ;;
    esac
    return 0
  fi
  return 0
}
set_gate_status fake-bead passed
_n=$(printf '%s\n' $_MOCK_LABELS | grep -c '^gate-status:' || true)
eq "exactly ONE gate-status:* label after transition" "$_n" "1"
printf '%s\n' $_MOCK_LABELS | grep -qx 'gate-status:passed' && ok "surviving gate-status label is the target (passed)" || bad "target label gate-status:passed missing after transition"
printf '%s\n' $_MOCK_LABELS | grep -qx 'other:keepme'       && ok "non-gate-status labels left untouched"            || bad "set_gate_status clobbered a non-gate-status label"
unset -f bd

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

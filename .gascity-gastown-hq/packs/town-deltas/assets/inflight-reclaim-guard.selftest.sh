#!/usr/bin/env bash
# Selftest for inflight-reclaim-guard.py — pure reclaim_decision() logic.
#
# Feeds mock inputs to the Python decision function via inline invocation.
# Does NOT call bd, gc, git, notify, or actuate anything live.
#
# Test cases (per spec):
#   1. no_builder + no_branch + TTL_met → reclaim
#   2. live_session → noop
#   3. recent_branch → noop
#   4. needs_human → noop
#   5. dispatching_marker → noop
#   6. stranded_but_TTL_not_met → noop
#   7. reclaim_count >= MAX_RECLAIMS → escalate
#   8. escalate_then_reclaim_boundary (count == MAX-1, TTL met → reclaim; count == MAX → escalate)
#   9. no_builder + no_branch + seconds_stranded=0 → noop (hysteresis, not yet tracked)
#  10. needs_human overrides everything (even past TTL with no builder)
#
# Plus real-module tests: ga-7m191 (coordinator-parked), ga-6ow4v (escalate →
# needs-human), ga-vw26y (in_progress sweep scope + status-reset on reclaim).
#
# Exit: 0 = all pass, 1 = any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SCRIPT="${SCRIPT_DIR}/../../../scripts/inflight-reclaim-guard.py"

if [[ ! -f "$GUARD_SCRIPT" ]]; then
  echo "FAIL: cannot locate inflight-reclaim-guard.py (looked at $GUARD_SCRIPT)"
  exit 1
fi

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local code="$2"
  local expected="$3"   # exact string expected in output

  result=$(python3 -c "$code" 2>&1) || true
  if echo "$result" | grep -qF "$expected"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name"
    echo "  expected substring: $expected"
    echo "  got: $result"
    ((FAIL++)) || true
  fi
}

# ---------------------------------------------------------------------------
# Inline the pure decision function so we don't import the full module
# (which would start the main loop and call gc/bd/git).
# Keep in sync with inflight-reclaim-guard.py — these constants must match.
# ---------------------------------------------------------------------------

HELPERS=$(cat <<'PYEOF'
RECLAIM_TTL = 1500
MAX_RECLAIMS = 3

def reclaim_decision(has_live_session, has_recent_branch, seconds_stranded,
                     reclaim_count, has_needs_human, has_dispatching_marker):
    if has_needs_human:
        return "noop"
    if has_dispatching_marker:
        return "noop"
    if has_live_session:
        return "noop"
    if has_recent_branch:
        return "noop"
    if seconds_stranded < RECLAIM_TTL:
        return "noop"
    if reclaim_count >= MAX_RECLAIMS:
        return "escalate"
    return "reclaim"
PYEOF
)

# ---------------------------------------------------------------------------
# Test 1: no builder + no recent branch + TTL met → reclaim
# ---------------------------------------------------------------------------
run_test "no_builder+no_branch+TTL_met → reclaim" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=1600.0,   # > 1500s TTL
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'reclaim', f'expected reclaim, got {result!r}'
print('OK result=' + result)
" "OK result=reclaim"

# ---------------------------------------------------------------------------
# Test 2: live session → noop (even if past TTL)
# ---------------------------------------------------------------------------
run_test "live_session → noop" "
$HELPERS
result = reclaim_decision(
    has_live_session=True,
    has_recent_branch=False,
    seconds_stranded=9999.0,   # way past TTL
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 3: recent branch commit → noop (even with no session + past TTL)
# ---------------------------------------------------------------------------
run_test "recent_branch → noop" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=True,
    seconds_stranded=9999.0,
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 4: needs_human → noop (always, overrides all other signals)
# ---------------------------------------------------------------------------
run_test "needs_human → noop" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=9999.0,   # well past TTL
    reclaim_count=0,
    has_needs_human=True,
    has_dispatching_marker=False,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 5: dispatching_marker → noop (bead actively in gate pipeline)
# ---------------------------------------------------------------------------
run_test "dispatching_marker → noop" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=9999.0,
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=True,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 6: stranded but TTL not met → noop (hysteresis, too soon to act)
# ---------------------------------------------------------------------------
run_test "stranded_but_TTL_not_met → noop" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=900.0,    # < 1500s TTL
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 7: reclaim_count >= MAX_RECLAIMS → escalate
# ---------------------------------------------------------------------------
run_test "reclaim_count>=MAX_RECLAIMS → escalate" "
$HELPERS
for count in (3, 4, 10):
    result = reclaim_decision(
        has_live_session=False,
        has_recent_branch=False,
        seconds_stranded=9999.0,
        reclaim_count=count,
        has_needs_human=False,
        has_dispatching_marker=False,
    )
    assert result == 'escalate', f'count={count}: expected escalate, got {result!r}'
print('OK escalated for counts 3,4,10')
" "OK escalated for counts 3,4,10"

# ---------------------------------------------------------------------------
# Test 8: reclaim_count == MAX-1 (count=2, < MAX=3) → still reclaim
# ---------------------------------------------------------------------------
run_test "reclaim_count=MAX-1 → reclaim (not yet exhausted)" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=1600.0,
    reclaim_count=2,           # MAX_RECLAIMS-1 = still below cap
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'reclaim', f'expected reclaim, got {result!r}'
print('OK result=' + result)
" "OK result=reclaim"

# ---------------------------------------------------------------------------
# Test 9: seconds_stranded=0 (just first noticed) → noop (hysteresis)
# ---------------------------------------------------------------------------
run_test "seconds_stranded=0 → noop (just first observed stranded)" "
$HELPERS
result = reclaim_decision(
    has_live_session=False,
    has_recent_branch=False,
    seconds_stranded=0.0,
    reclaim_count=0,
    has_needs_human=False,
    has_dispatching_marker=False,
)
assert result == 'noop', f'expected noop, got {result!r}'
print('OK result=' + result)
" "OK result=noop"

# ---------------------------------------------------------------------------
# Test 10: needs_human overrides stranded+past-TTL (belt-and-suspenders)
# ---------------------------------------------------------------------------
run_test "needs_human+past_TTL → noop (human-parked, never reclaim)" "
$HELPERS
# Even with reclaim_count=0, past TTL, and no builder — needs_human wins
for reclaim_count in (0, 1, 2):
    result = reclaim_decision(
        has_live_session=False,
        has_recent_branch=False,
        seconds_stranded=9999.0,
        reclaim_count=reclaim_count,
        has_needs_human=True,
        has_dispatching_marker=False,
    )
    assert result == 'noop', f'reclaim_count={reclaim_count}: expected noop, got {result!r}'
print('OK needs_human always noop')
" "OK needs_human always noop"

# ---------------------------------------------------------------------------
# ga-7m191: coordinator-parked + in-flight-alone behavior. These load the REAL
# module via importlib (main() is guarded by __name__=='__main__', so import is
# side-effect-free — no gc/bd/git/notify calls) and exercise the real functions.
# ---------------------------------------------------------------------------

LOAD_REAL=$(cat <<PYEOF
import importlib.util
spec = importlib.util.spec_from_file_location("irg", "${GUARD_SCRIPT}")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
PYEOF
)

# ga-7m191 (a): bead parked under always-live Mayor must NOT count as live builder
run_test "mayor-parked → not live builder (reclaimable)" "
$LOAD_REAL
sess = [{'state':'active','name':'gastown.mayor','session_name':'mayor-gawispabc','agent_name':'mayor'}]
assert m.session_is_live('gastown.mayor', sess) is False, 'mayor-parked must be False'
assert m.session_is_live('mayor-gawispabc', sess) is False, 'mayor session_name must be False'
print('OK mayor-parked not live')
" "OK mayor-parked not live"

# ga-7m191 (a): deacon (other always-on coordinator) also excluded
run_test "deacon-parked → not live builder" "
$LOAD_REAL
sess = [{'state':'active','name':'gastown.deacon','session_name':'deacon-gawispxx'}]
assert m.session_is_live('gastown.deacon', sess) is False, 'deacon-parked must be False'
print('OK deacon-parked not live')
" "OK deacon-parked not live"

# Control: a genuine live dog/builder session is STILL live (no false reclaim)
run_test "live dog builder → still live (control)" "
$LOAD_REAL
sess = [{'state':'active','name':'gastown.dog-1','session_name':'dog-gawispxyz','agent_name':'gastown.dog'}]
assert m.session_is_live('dog-gawispxyz', sess) is True, 'live dog must be True'
assert m.session_is_live('gastown.dog-1', sess) is True, 'live dog by name must be True'
print('OK live dog still live')
" "OK live dog still live"

# Control: dead builder (assignee matches no session) → not live
run_test "dead builder (no matching session) → not live" "
$LOAD_REAL
sess = [{'state':'active','name':'gastown.dog-2','session_name':'dog-other'}]
assert m.session_is_live('dog-deadbuilder', sess) is False, 'dead builder must be False'
print('OK dead builder not live')
" "OK dead builder not live"

# is_coordinator helper classifies correctly
run_test "is_coordinator helper classification" "
$LOAD_REAL
assert m.is_coordinator('gastown.mayor') is True
assert m.is_coordinator('mayor-gawispabc') is True
assert m.is_coordinator('gastown.deacon') is True
assert m.is_coordinator('gastown.dog-1') is False
assert m.is_coordinator('dog-gawispxyz') is False
assert m.is_coordinator('') is False
assert m.is_coordinator(None) is False
print('OK is_coordinator')
" "OK is_coordinator"

# ga-7m191 (b): the in-flight query keys on story:in-flight ALONE
run_test "query keys on story:in-flight alone (no pilot:dispatched req)" "
$LOAD_REAL
import inspect
src = inspect.getsource(m.list_inflight_beads)
# Check the actual bd-list label ARGS, not docstring prose (which may mention
# pilot:dispatched when explaining the fix). Arg form is the quoted literal.
assert '\"story:in-flight\"' in src, 'must query --label story:in-flight'
assert '\"pilot:dispatched\"' not in src, 'must NOT pass pilot:dispatched as a query label'
print('OK in-flight-alone query')
" "OK in-flight-alone query"

# ga-6ow4v: on reclaim-cap exhaustion, escalation must ADD gate:needs-human and
# must NOT re-clear story:in-flight (re-clearing caused the dispatch↔reclaim
# loop the spec warns about). Inspect the real do_escalate body (the loop-break
# rail is has_needs_human, exercised by reclaim_decision tests 4 + 10 above).
run_test "ga-6ow4v: escalate adds gate:needs-human, no re-clear" "
$LOAD_REAL
import inspect
src = inspect.getsource(m.do_escalate)
assert 'gate:needs-human' in src, 'do_escalate must add gate:needs-human'
assert '\"add\"' in src, 'do_escalate must ADD the needs-human label'
# Must NOT issue any bd label-remove / assign-clear in escalation — those would
# re-clear the bead and re-arm the loop. The reclaim path (do_reclaim) clears;
# escalation deliberately does not.
assert '\"remove\"' not in src, 'escalate must not remove labels (no re-clear loop)'
print('OK escalate adds needs-human, no re-clear')
" "OK escalate adds needs-human, no re-clear"

# ---------------------------------------------------------------------------
# ga-vw26y: status blind spot. `bd list` defaults to open-only, so a story
# stuck in status:in_progress without story:in-flight was invisible to both the
# guard and the Pilot's re-dispatch query. Detection is widened (in_progress
# sweep, scoped to Pilot markers) and do_reclaim now resets status to open.
# ---------------------------------------------------------------------------

# ga-vw26y (a): the Pilot-story scope predicate keeps ONLY Pilot-marked,
# non-terminal beads — never crew/gate/dog task beads.
run_test "ga-vw26y: is_reclaimable_inprogress_story scope predicate" "
$LOAD_REAL
f = m.is_reclaimable_inprogress_story
# Pilot markers → reclaimable
assert f(['pilot:dispatched']) is True
assert f(['pilot:reclaim-count:2']) is True
assert f(['story:in-flight']) is True
# No Pilot marker → NOT reclaimable (crew/gate/dog task beads are safe)
assert f([]) is False
assert f(['lane:small']) is False
# Terminal/parked → NOT reclaimable even with a Pilot marker
assert f(['pilot:dispatched','story:done']) is False
assert f(['pilot:dispatched','gate:passed']) is False
assert f(['pilot:dispatched','gate:needs-human']) is False
assert f(['pilot:dispatched','needs:engine-window']) is False
# gate:needs-fix is a send-back, NOT terminal → still reclaimable
assert f(['pilot:dispatched','gate:needs-fix']) is True
print('OK in_progress scope predicate')
" "OK in_progress scope predicate"

# ga-vw26y (b): the in_progress sweep queries status=in_progress explicitly.
run_test "ga-vw26y: in_progress sweep queries status in_progress" "
$LOAD_REAL
import inspect
src = inspect.getsource(m.list_stranded_inprogress_beads)
assert '\"in_progress\"' in src, 'sweep must query --status in_progress'
assert '\"--status\"' in src, 'sweep must pass --status'
print('OK in_progress sweep query')
" "OK in_progress sweep query"

# ga-vw26y (c): list_inflight_beads now includes in_progress (was open-only by
# bd default), so an in_progress story:in-flight bead is no longer invisible.
run_test "ga-vw26y: inflight query includes in_progress status" "
$LOAD_REAL
import inspect
src = inspect.getsource(m.list_inflight_beads)
assert 'in_progress' in src, 'inflight query must explicitly include in_progress status'
assert '\"story:in-flight\"' in src, 'inflight query must still key on story:in-flight'
print('OK inflight includes in_progress')
" "OK inflight includes in_progress"

# ga-vw26y (d): do_reclaim resets status to open so the bead is re-dispatchable.
run_test "ga-vw26y: do_reclaim resets status to open" "
$LOAD_REAL
import inspect
src = inspect.getsource(m.do_reclaim)
assert '\"update\"' in src, 'do_reclaim must call bd update'
assert '\"--status\"' in src and '\"open\"' in src, 'do_reclaim must reset status to open'
print('OK do_reclaim resets status open')
" "OK do_reclaim resets status open"

# ---------------------------------------------------------------------------
# ga-64usm: alive != working. A credit-limited / hung builder keeps
# state=active in `gc session list` but produces ZERO output → its last_active
# timestamp goes stale. The old session_is_live() treated any matched
# active/awake session as a healthy owner, so a frozen builder's in-flight bead
# was NEVER reclaimable (it sat story:in-flight for 3h46 on 2026-06-09). The fix
# adds a freshness gate: a matched live session counts as a HEALTHY owner only
# if it shows a recent progress signal — terminal activity within
# STALE_ACTIVITY_TTL, OR a bd update on the bead itself within the same window.
# ---------------------------------------------------------------------------

# ga-64usm (a): session_owner_is_healthy pure decision matrix.
run_test "ga-64usm: session_owner_is_healthy decision matrix" "
$LOAD_REAL
f = m.session_owner_is_healthy
TTL = m.STALE_ACTIVITY_TTL
# No matched live session → never a healthy owner (delegates to dead-builder rail)
assert f(False, None, None) is False
assert f(False, 10, 10) is False
# Matched live, but activity age unknown → conservative: treat as healthy
assert f(True, None, None) is True
# Matched live with FRESH terminal activity → healthy (normal working builder)
assert f(True, 10, None) is True
assert f(True, TTL, None) is True            # boundary: == TTL still fresh
# Matched live, STALE activity, NO recent bead update → FROZEN zombie (reclaimable)
assert f(True, TTL + 1, None) is False
assert f(True, TTL + 1, TTL + 1) is False    # bead also stale → frozen
# Matched live, STALE activity, but bead bd-updated recently → progress (keep)
assert f(True, TTL + 1, 60) is True
assert f(True, TTL + 1, TTL) is True         # boundary: bead update == TTL still fresh
print('OK session_owner_is_healthy matrix')
" "OK session_owner_is_healthy matrix"

# ga-64usm (b): parse_iso_epoch handles offset AND bare-Z (py3.9 fromisoformat
# rejects bare Z — bd emits Z timestamps, gc session emits offset timestamps).
run_test "ga-64usm: parse_iso_epoch handles offset and Z" "
$LOAD_REAL
p = m.parse_iso_epoch
a = p('2026-06-10T11:33:28-03:00')
b = p('2026-06-10T14:33:28Z')
assert a is not None and b is not None, 'both forms must parse'
assert abs(a - b) < 1.0, f'offset and Z forms must agree: {a} vs {b}'
assert p('') is None and p(None) is None and p('garbage') is None, 'bad input → None'
print('OK parse_iso_epoch')
" "OK parse_iso_epoch"

# ga-64usm (c): a FROZEN live session (state=active, last_active stale) with no
# recent bead update is NOT a live owner → bead becomes reclaimable. THE BUG.
run_test "ga-64usm: frozen active session → not live owner (reclaimable)" "
$LOAD_REAL
now   = m.parse_iso_epoch('2026-06-10T12:00:00+00:00')
stale = '2026-06-10T11:00:00+00:00'   # 60min before now → > 30min STALE_ACTIVITY_TTL
sess  = [{'state':'active','name':'gastown.dog-1','session_name':'dog-x','last_active': stale}]
# Frozen + no recent bead update → not a live owner (the bug: must be reclaimable)
assert m.session_is_live('dog-x', sess, now) is False, 'frozen session must NOT count as live'
# Frozen BUT bead bd-updated 2min ago → progress signal → keep (conservative)
assert m.session_is_live('dog-x', sess, now, bead_update_age=120) is True, 'recent bead update → keep'
print('OK frozen session reclaimable')
" "OK frozen session reclaimable"

# ga-64usm (d): control — a FRESH live session (recent last_active) is STILL a
# live owner (no false reclaim of a genuinely-working builder).
run_test "ga-64usm: fresh active session → still live owner (control)" "
$LOAD_REAL
now   = m.parse_iso_epoch('2026-06-10T12:00:00+00:00')
fresh = '2026-06-10T11:58:00+00:00'   # 2min before now → fresh
sess  = [{'state':'active','name':'gastown.dog-1','session_name':'dog-x','last_active': fresh}]
assert m.session_is_live('dog-x', sess, now) is True, 'fresh session must stay live'
print('OK fresh session still live')
" "OK fresh session still live"

# ga-64usm (e): backward-compat — sessions WITHOUT last_active (e.g. mock data,
# or gc output that omits it) fall back to the conservative pre-fix behavior:
# matched live session → live (no spurious reclaim from a missing timestamp).
run_test "ga-64usm: missing last_active → conservative (stays live)" "
$LOAD_REAL
sess = [{'state':'active','name':'gastown.dog-1','session_name':'dog-x'}]
assert m.session_is_live('dog-x', sess) is True, 'no last_active → conservative live'
print('OK missing last_active conservative')
" "OK missing last_active conservative"

# ---------------------------------------------------------------------------
# Drift-guard: verify RECLAIM_TTL, MAX_RECLAIMS, and key safety guards are
# present in the live script (source-of-truth check).
# ---------------------------------------------------------------------------

check_pattern() {
  local name="$1"
  local pattern="$2"
  if grep -qE "$pattern" "$GUARD_SCRIPT"; then
    echo "PASS: $name"
    ((PASS++)) || true
  else
    echo "FAIL: $name — pattern not found in guard script"
    ((FAIL++)) || true
  fi
}

check_pattern "RECLAIM_TTL constant present" "RECLAIM_TTL\s*=\s*1500"
check_pattern "MAX_RECLAIMS constant present" "MAX_RECLAIMS\s*=\s*3"
check_pattern "needs_human safety guard present" "has_needs_human"
check_pattern "live session check covers session_name" "session_name"
check_pattern "gate dispatching marker check present" "gate-status:dispatching"
check_pattern "branch recency check for fix/ prefix" '"fix"'
check_pattern "branch recency check for feature/ prefix" '"feature"'
check_pattern "fail-safe: skip cycle on bd list failure" "bd list failed"
check_pattern "fail-safe: skip cycle on session list failure" "session list failed"
check_pattern "fail-safe: skip cycle on gate-marker failure" "gate-marker query failed"
check_pattern "ga-7m191: coordinator markers defined" "COORDINATOR_MARKERS"
check_pattern "ga-7m191: is_coordinator helper present" "def is_coordinator"
check_pattern "ga-7m191: in-flight-alone query function present" "def list_inflight_beads"
check_pattern "ga-7m191: epic exclusion in run_cycle" '"epic"'
check_pattern "ga-vw26y: in_progress sweep function present" "def list_stranded_inprogress_beads"
check_pattern "ga-vw26y: scope predicate present" "def is_reclaimable_inprogress_story"
check_pattern "ga-vw26y: pilot-story markers defined" "PILOT_STORY_MARKERS"
check_pattern "ga-vw26y: terminal/parked exclusion set defined" "TERMINAL_PARKED_LABELS"
check_pattern "ga-vw26y: do_reclaim resets status open" 'bd.*update|"update"'
check_pattern "ga-64usm: STALE_ACTIVITY_TTL constant present" "STALE_ACTIVITY_TTL\s*=\s*1800"
check_pattern "ga-64usm: session_owner_is_healthy helper present" "def session_owner_is_healthy"
check_pattern "ga-64usm: parse_iso_epoch helper present" "def parse_iso_epoch"
check_pattern "ga-64usm: session_activity_age helper present" "def session_activity_age"
check_pattern "ga-64usm: session_is_live consults last_active" "last_active"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

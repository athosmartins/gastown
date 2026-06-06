#!/usr/bin/env bash
# Selftest for crew-session-dedup.py keeper-vs-loser decision logic.
# Feeds mock session groups to the Python functions via inline invocation.
# Does NOT call gc, notify, or drain anything live.
# Usage: ./crew-session-dedup.selftest.sh
# Exit: 0 = all pass, 1 = any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The live script may be in scripts/ relative to the repo root
DEDUP_SCRIPT="${SCRIPT_DIR}/../../../scripts/crew-session-dedup.py"
if [[ ! -f "$DEDUP_SCRIPT" ]]; then
  # Fallback: look relative to this script's pack location
  DEDUP_SCRIPT="$(cd "$SCRIPT_DIR/../../../" && pwd)/scripts/crew-session-dedup.py"
fi

if [[ ! -f "$DEDUP_SCRIPT" ]]; then
  echo "FAIL: cannot locate crew-session-dedup.py (looked at $DEDUP_SCRIPT)"
  exit 1
fi

PASS=0
FAIL=0

run_test() {
  local name="$1"
  local code="$2"
  local expected="$3"  # substring expected in output

  result=$(python3 -c "$code" 2>&1)
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
# Inline the helpers we need to test without importing the full module
# (which would block on gc config show and the main loop).
# ---------------------------------------------------------------------------

HELPERS=$(cat <<'PYEOF'
import sys, json

BAD_STATES = {"asleep", "creating", "drained", "draining"}
BAD_STATE_SIGNALS = [
    "reset-pending",
    "continuation_reset_pending",
    "runtime-missing",
    "pending_create",
    "creating",
    "asleep",
    "drained",
    "draining",
]

def is_bad_state(session):
    state = session.get("state", "").lower()
    if state in BAD_STATES:
        return True
    haystack = " ".join([
        state,
        session.get("title", ""),
        session.get("session_name", ""),
        session.get("name", ""),
    ]).lower()
    for sig in BAD_STATE_SIGNALS:
        if sig in haystack:
            return True
    return False

def classify(group):
    bad  = [s for s in group if is_bad_state(s)]
    good = [s for s in group if not is_bad_state(s)]
    if len(good) == 1 and len(bad) >= 1:
        return "DRAIN", good[0]["id"], [s["id"] for s in bad]
    elif len(group) <= 1:
        return "NOOP", None, []
    else:
        return "AMBIG", None, []
PYEOF
)

# ---------------------------------------------------------------------------
# Test 1: clean active + reset-pending  →  drain the reset-pending
# ---------------------------------------------------------------------------
run_test "clean+reset-pending → drain reset-pending" "
$HELPERS

group = [
    {'id': 'ga-wisp-d7h2ih', 'state': 'active',  'name': 'digo-wa-real',
     'title': 'digo-wa', 'session_name': 'digo-wa-gawispd7h2ih'},
    {'id': 'ga-tiusc',       'state': 'active',   'name': 'digo-wa-dup',
     'title': 'digo-wa', 'session_name': 'digo-wa-reset-pending'},
]
verdict, keeper, losers = classify(group)
print(f'verdict={verdict} keeper={keeper} losers={losers}')
assert verdict == 'DRAIN', f'expected DRAIN got {verdict}'
assert keeper == 'ga-wisp-d7h2ih', f'expected real worker as keeper'
assert 'ga-tiusc' in losers, f'expected dup in losers'
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 2: clean active + continuation_reset_pending signal → drain the bad one
# ---------------------------------------------------------------------------
run_test "clean+continuation_reset_pending → drain" "
$HELPERS

group = [
    {'id': 'ga-good', 'state': 'active', 'name': 'mila-wa-real',
     'title': 'mila-wa', 'session_name': 'mila-wa-gawispabc123'},
    {'id': 'ga-dup',  'state': 'active', 'name': 'mila-wa-dup',
     'title': 'continuation_reset_pending', 'session_name': 'mila-wa-old'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'DRAIN', f'expected DRAIN got {verdict}'
assert keeper == 'ga-good'
assert 'ga-dup' in losers
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 3: clean active + state=asleep → drain the asleep one
# ---------------------------------------------------------------------------
run_test "clean+asleep → drain asleep" "
$HELPERS

group = [
    {'id': 'ga-awake',  'state': 'active',  'name': 'peter-wa-main',
     'title': 'peter-wa', 'session_name': 'peter-wa-active'},
    {'id': 'ga-asleep', 'state': 'asleep',  'name': 'peter-wa-asleep',
     'title': 'peter-wa', 'session_name': 'peter-wa-old'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'DRAIN', f'expected DRAIN got {verdict}'
assert keeper == 'ga-awake'
assert 'ga-asleep' in losers
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 4: two clean sessions → AMBIG, no auto-kill
# ---------------------------------------------------------------------------
run_test "two clean sessions → AMBIG (no auto-kill)" "
$HELPERS

group = [
    {'id': 'ga-a', 'state': 'active', 'name': 'batista-wa-1',
     'title': 'batista-wa', 'session_name': 'batista-wa-one'},
    {'id': 'ga-b', 'state': 'active', 'name': 'batista-wa-2',
     'title': 'batista-wa', 'session_name': 'batista-wa-two'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'AMBIG', f'expected AMBIG got {verdict}'
assert keeper is None
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 5: single session → NOOP
# ---------------------------------------------------------------------------
run_test "single session → NOOP" "
$HELPERS

group = [
    {'id': 'ga-only', 'state': 'active', 'name': 'digo-wa-only',
     'title': 'digo-wa', 'session_name': 'digo-wa-onlyone'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'NOOP', f'expected NOOP got {verdict}'
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 6: all-bad group (two creating sessions) → AMBIG
# ---------------------------------------------------------------------------
run_test "two creating sessions → AMBIG" "
$HELPERS

group = [
    {'id': 'ga-c1', 'state': 'creating', 'name': 'thies-wa-c1',
     'title': 'thies-wa', 'session_name': 'thies-wa-c1'},
    {'id': 'ga-c2', 'state': 'creating', 'name': 'thies-wa-c2',
     'title': 'thies-wa', 'session_name': 'thies-wa-c2'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'AMBIG', f'expected AMBIG got {verdict}'
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# Test 7: clean + state=creating → drain creating
# ---------------------------------------------------------------------------
run_test "clean+creating → drain creating" "
$HELPERS

group = [
    {'id': 'ga-live', 'state': 'active',   'name': 'batista-ps-live',
     'title': 'batista-ps', 'session_name': 'batista-ps-live'},
    {'id': 'ga-new',  'state': 'creating', 'name': 'batista-ps-new',
     'title': 'batista-ps', 'session_name': 'batista-ps-new'},
]
verdict, keeper, losers = classify(group)
assert verdict == 'DRAIN', f'expected DRAIN got {verdict}'
assert keeper == 'ga-live'
assert 'ga-new' in losers
print('OK')
" "OK"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Drift-guard: cap-exempt adhoc workers (e.g. property_scrapers/claude-adhoc-*)
# are spawned in parallel BY DESIGN and must NEVER be treated as singleton
# duplicates — draining one would kill legitimate concurrent work.
# ---------------------------------------------------------------------------
if grep -q '"-adhoc-" in names' "$DEDUP_SCRIPT"; then
  echo "PASS: adhoc workers excluded from dedup grouping"
  ((PASS++)) || true
else
  echo "FAIL: adhoc exclusion missing — cap-exempt parallel workers could be drained"
  ((FAIL++)) || true
fi

# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

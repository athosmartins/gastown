#!/usr/bin/env bash
# Selftest for pool-autoscale-watchdog.py scale_decision() logic.
# Feeds mock inputs to the pure decision function via inline Python invocation.
# Does NOT call gc, bd, notify, wake, pin, or unpin anything live.
# Usage: ./pool-autoscale-watchdog.selftest.sh
# Exit: 0 = all pass, 1 = any failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG_SCRIPT="${SCRIPT_DIR}/../../../scripts/pool-autoscale-watchdog.py"
if [[ ! -f "$WATCHDOG_SCRIPT" ]]; then
  echo "FAIL: cannot locate pool-autoscale-watchdog.py (looked at $WATCHDOG_SCRIPT)"
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
# Inline the pure decision function for isolated testing.
# Does NOT import the full module (which would start the poll loop).
# ---------------------------------------------------------------------------

DECISION_FN=$(cat <<'PYEOF'
import sys

SCALE_UP_AFTER = 180
SCALE_DOWN_AFTER = 300

def scale_decision(demand, active, max_active, asleep_available, stuck_count,
                   secs_demand_present, secs_demand_absent, watchdog_pins_count):
    if demand < 0 or active < 0 or max_active <= 0:
        return "noop", "bad_data"
    if demand > 0:
        if secs_demand_present < SCALE_UP_AFTER:
            return "noop", (
                f"demand={demand} hysteresis_not_met "
                f"{secs_demand_present:.0f}s/{SCALE_UP_AFTER}s"
            )
        if active >= max_active:
            return "stuck_alert", (
                f"demand={demand} queued but pool at max capacity "
                f"({max_active} active)"
            )
        if asleep_available > 0:
            return "wake_and_pin", (
                f"demand={demand} active={active}/{max_active} "
                f"asleep_available={asleep_available}"
            )
        return "stuck_alert", (
            f"demand={demand} active={active}/{max_active} "
            f"no_clean_asleep_members stuck={stuck_count}"
        )
    else:
        if watchdog_pins_count > 0 and secs_demand_absent >= SCALE_DOWN_AFTER:
            return "unpin", (
                f"demand=0 for {secs_demand_absent:.0f}s "
                f"(>= {SCALE_DOWN_AFTER}s) releasing {watchdog_pins_count} watchdog pins"
            )
        return "noop", (
            f"demand=0 pins={watchdog_pins_count} "
            f"idle={secs_demand_absent:.0f}s/{SCALE_DOWN_AFTER}s"
        )
PYEOF
)

# ---------------------------------------------------------------------------
# Test 1: demand > 0, capacity available, hysteresis met → wake_and_pin
# ---------------------------------------------------------------------------
run_test "demand>0 + capacity + hysteresis-met → wake_and_pin" "
$DECISION_FN

action, reason = scale_decision(
    demand=4, active=1, max_active=3, asleep_available=2, stuck_count=0,
    secs_demand_present=200, secs_demand_absent=0, watchdog_pins_count=0
)
assert action == 'wake_and_pin', f'expected wake_and_pin got {action}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 2: demand > 0, pool at max → stuck_alert
# ---------------------------------------------------------------------------
run_test "demand>0 active==max → stuck_alert" "
$DECISION_FN

action, reason = scale_decision(
    demand=3, active=3, max_active=3, asleep_available=0, stuck_count=0,
    secs_demand_present=300, secs_demand_absent=0, watchdog_pins_count=1
)
assert action == 'stuck_alert', f'expected stuck_alert got {action}'
assert 'max capacity' in reason, f'expected max capacity in reason: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 3: demand > 0 but hysteresis NOT met → noop
# ---------------------------------------------------------------------------
run_test "demand>0 hysteresis-not-met → noop" "
$DECISION_FN

action, reason = scale_decision(
    demand=2, active=0, max_active=3, asleep_available=3, stuck_count=0,
    secs_demand_present=60, secs_demand_absent=0, watchdog_pins_count=0
)
assert action == 'noop', f'expected noop got {action}'
assert 'hysteresis_not_met' in reason, f'expected hysteresis_not_met in reason: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 4: demand == 0, watchdog pins exist, drain-hysteresis met → unpin
# ---------------------------------------------------------------------------
run_test "demand==0 + pins + drain-hysteresis → unpin" "
$DECISION_FN

action, reason = scale_decision(
    demand=0, active=1, max_active=3, asleep_available=0, stuck_count=0,
    secs_demand_present=0, secs_demand_absent=400, watchdog_pins_count=1
)
assert action == 'unpin', f'expected unpin got {action}'
assert 'releasing' in reason, f'expected releasing in reason: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 5: demand == 0, no watchdog pins → noop
# ---------------------------------------------------------------------------
run_test "demand==0 no pins → noop" "
$DECISION_FN

action, reason = scale_decision(
    demand=0, active=1, max_active=3, asleep_available=2, stuck_count=0,
    secs_demand_present=0, secs_demand_absent=600, watchdog_pins_count=0
)
assert action == 'noop', f'expected noop got {action}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 6: bad/empty data (demand=-1) → noop
# ---------------------------------------------------------------------------
run_test "bad data (demand=-1) → noop" "
$DECISION_FN

action, reason = scale_decision(
    demand=-1, active=0, max_active=3, asleep_available=2, stuck_count=0,
    secs_demand_present=999, secs_demand_absent=0, watchdog_pins_count=0
)
assert action == 'noop', f'expected noop got {action}'
assert reason == 'bad_data', f'expected bad_data reason: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 7: demand > 0, hysteresis met, capacity available but NO asleep members
#         (all stuck) → stuck_alert
# ---------------------------------------------------------------------------
run_test "demand>0 hysteresis-met active<max no-asleep → stuck_alert" "
$DECISION_FN

action, reason = scale_decision(
    demand=2, active=1, max_active=3, asleep_available=0, stuck_count=2,
    secs_demand_present=200, secs_demand_absent=0, watchdog_pins_count=0
)
assert action == 'stuck_alert', f'expected stuck_alert got {action}'
assert 'no_clean_asleep' in reason, f'expected no_clean_asleep in reason: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 8: demand == 0, pins exist but drain-hysteresis NOT met → noop
# ---------------------------------------------------------------------------
run_test "demand==0 pins exist but drain-hysteresis not met → noop" "
$DECISION_FN

action, reason = scale_decision(
    demand=0, active=1, max_active=3, asleep_available=0, stuck_count=0,
    secs_demand_present=0, secs_demand_absent=100, watchdog_pins_count=2
)
assert action == 'noop', f'expected noop got {action}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Test 9: max_active <= 0 (bad config) → noop
# ---------------------------------------------------------------------------
run_test "bad data (max_active=0) → noop" "
$DECISION_FN

action, reason = scale_decision(
    demand=5, active=0, max_active=0, asleep_available=3, stuck_count=0,
    secs_demand_present=300, secs_demand_absent=0, watchdog_pins_count=0
)
assert action == 'noop', f'expected noop got {action}'
assert reason == 'bad_data', f'expected bad_data: {reason}'
print(f'OK: {action} {reason}')
" "OK"

# ---------------------------------------------------------------------------
# Drift-guard: verify SCALE_UP_AFTER and SCALE_DOWN_AFTER are production values
# (no test-only small values left in the script)
# ---------------------------------------------------------------------------
if grep -q 'SCALE_UP_AFTER = 180' "$WATCHDOG_SCRIPT"; then
  echo "PASS: SCALE_UP_AFTER=180 (production value)"
  ((PASS++)) || true
else
  echo "FAIL: SCALE_UP_AFTER is not 180 — test-only value may have been left in"
  ((FAIL++)) || true
fi

if grep -q 'SCALE_DOWN_AFTER = 300' "$WATCHDOG_SCRIPT"; then
  echo "PASS: SCALE_DOWN_AFTER=300 (production value)"
  ((PASS++)) || true
else
  echo "FAIL: SCALE_DOWN_AFTER is not 300 — test-only value may have been left in"
  ((FAIL++)) || true
fi

# ---------------------------------------------------------------------------
# Drift-guard: verify safety invariant — MANAGED_POOLS excludes mayor/singleton agents
# ---------------------------------------------------------------------------
if grep -q 'MANAGED_POOLS = \["gastown.dog"\]' "$WATCHDOG_SCRIPT"; then
  echo "PASS: MANAGED_POOLS only contains gastown.dog (safe scope)"
  ((PASS++)) || true
else
  echo "FAIL: MANAGED_POOLS does not match expected safe scope"
  ((FAIL++)) || true
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0

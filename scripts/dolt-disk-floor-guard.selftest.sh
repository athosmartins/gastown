#!/bin/bash
# dolt-disk-floor-guard.selftest.sh — unit tests for the PURE decision logic of
# dolt-disk-floor-guard.sh: avail-GB df-parsing, floor classification, worsening
# detection, and cooldown + worsening-bypass notify gating.
#
# Hermetic: sources the script as a LIBRARY (DOLT_DISK_FLOOR_GUARD_LIB=1) so main()
# never runs, points the log at a throwaway path. Never calls `gc dolt cleanup`,
# `gc mail send`, or `notify`; nothing is deleted, nothing is sent, nothing in
# Dolt's data dir is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-disk-floor-guard.sh"

export DOLT_DISK_FLOOR_GUARD_LIB=1
export DOLT_DISK_FLOOR_GUARD_LOG="/tmp/dolt-disk-floor-guard-selftest-$$.log"
# shellcheck disable=SC1090
. "$SCRIPT"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-disk-floor-guard.selftest.sh ==="

# ── _avail_gb: real df parsing (NOT stubbed — proves the -k/1024/1024 math matches
#    this machine's actual df output format; the decision-function tests below
#    stub avail directly and don't depend on this) ────────────────────────────────
g="$(_avail_gb /tmp)"
case "$g" in
  ''|*[!0-9]*) bad "_avail_gb(/tmp) did not return an integer (got: '$g')" ;;
  *) [ "$g" -gt 0 ] && ok "_avail_gb(/tmp) returns a positive integer GB ($g)" || bad "_avail_gb(/tmp) returned non-positive: $g" ;;
esac

# ── _avail_gb: nonexistent path → "" (surfaces as UNKNOWN, never a silent 0 —
#    ga-p5q3: error and empty must not collapse to the same value as "fine") ──────
g="$(_avail_gb "/nonexistent/path/$$/does-not-exist")"
[ "$g" = "" ] && ok "_avail_gb(nonexistent path) → '' (df failure surfaces, not masked)" || bad "_avail_gb(nonexistent) got: '$g' (expected empty)"

# ── _floor_class: NONE / WARN / CRITICAL / UNKNOWN boundaries (warn=8 crit=3) ─────
[ "$(_floor_class 20 8 3)" = "NONE" ]      && ok "class: 20GB avail, floors(8,3) → NONE"                    || bad "class 20/8/3 wrong: $(_floor_class 20 8 3)"
[ "$(_floor_class 8  8 3)" = "WARN" ]      && ok "class: avail==warn floor → WARN (boundary inclusive)"     || bad "class 8/8/3 wrong: $(_floor_class 8 8 3)"
[ "$(_floor_class 5  8 3)" = "WARN" ]      && ok "class: between crit and warn → WARN"                      || bad "class 5/8/3 wrong: $(_floor_class 5 8 3)"
[ "$(_floor_class 3  8 3)" = "CRITICAL" ]  && ok "class: avail==crit floor → CRITICAL (boundary inclusive)" || bad "class 3/8/3 wrong: $(_floor_class 3 8 3)"
[ "$(_floor_class 0  8 3)" = "CRITICAL" ]  && ok "class: avail=0 → CRITICAL"                                || bad "class 0/8/3 wrong: $(_floor_class 0 8 3)"
[ "$(_floor_class ""  8 3)" = "UNKNOWN" ]  && ok "class: empty avail (df failed) → UNKNOWN, never NONE"     || bad "class empty wrong: $(_floor_class "" 8 3)"
[ "$(_floor_class abc 8 3)" = "UNKNOWN" ]  && ok "class: non-numeric avail → UNKNOWN"                       || bad "class abc wrong: $(_floor_class abc 8 3)"

# ── _worsening: avail-GB FALLING = worsening (inverse framing of
#    disk-pressure-monitor's usage-% rising; same idiom) ─────────────────────────
_worsening 5 8  && ok "worsening: 5GB < last-notified 8GB → true (pressure increased)"              || bad "worsening 5<8 should be true"
_worsening 8 5  && bad "worsening: 8GB > last-notified 5GB should be FALSE (avail improved)"         || ok "worsening: improved avail → false"
_worsening 5 5  && bad "worsening: unchanged avail should be FALSE (no new info)"                    || ok "worsening: unchanged avail → false"
_worsening 5 "" && bad "worsening: no prior value should be FALSE (unknown trend isn't a bypass)"    || ok "worsening: no prior notified value → false"

# ── _cooldown_elapsed: fail-open on no/invalid prior timestamp ───────────────────
_cooldown_elapsed "" 1000 3600   && ok "cooldown: no prior timestamp → elapsed (fail-open)"        || bad "cooldown empty should fail-open"
_cooldown_elapsed 1000 1000 3600 && bad "cooldown: 0s elapsed should NOT be elapsed"                 || ok "cooldown: just-notified → still cooling down"
_cooldown_elapsed 1000 4601 3600 && ok "cooldown: 3601s elapsed >= 3600s window → elapsed"          || bad "cooldown: should have elapsed"
_cooldown_elapsed 1000 4600 3600 && ok "cooldown: exactly 3600s elapsed → elapsed (boundary >=)"    || bad "cooldown: boundary should be inclusive"

# ── _should_notify: composed gate — cooldown-elapsed OR worsening (ga-vs55 furo #2
#    lesson: a cooldown blind to trend silenced a real emergency 28min before Dolt
#    died; this MUST NOT regress that fix onto the new guard) ────────────────────
_should_notify 1000 1100 3600 5 8  && ok "should_notify: within cooldown BUT worsening (5<8) → notify anyway"      || bad "should_notify: worsening should bypass cooldown"
_should_notify 1000 1100 3600 8 5  && bad "should_notify: within cooldown, improved, no bypass → should suppress" || ok "should_notify: within cooldown + improved avail → suppressed"
_should_notify 1000 4601 3600 8 8  && ok "should_notify: cooldown elapsed, stable avail → notify (repeat allowed)" || bad "should_notify: elapsed cooldown should notify regardless of trend"
_should_notify "" 1100 3600 8 ""   && ok "should_notify: never notified before → notify (fail-open)"               || bad "should_notify: first-ever call should notify"

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]

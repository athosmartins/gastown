#!/usr/bin/env bash
# Selftest for gate_dolt_cpu() median sampling (R3 / ga-ftmci burst-robustness).
#
# Dolt %cpu is violently bursty (the supervisor's per-rig full-table hydration scan
# of hq.issues spikes it 5%<->400% every few seconds). The headroom gate probes it
# and DEFERs reviewers when hot (>GATE_DOLT_CPU_HOT). A SINGLE ps sample caused a
# false DEFER ~1 sweep in 4 on a transient spike even when the plane was calm at the
# median — the "gate keeps failing" symptom. gate_dolt_cpu() now samples 5x and
# returns the MEDIAN. This locks in: spikes are smoothed, hot planes still read hot.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$DIR/quality-gate-dispatcher.sh"
TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
sed -n '/^gate_dolt_cpu() {/,/^}/p' "$SRC" > "$TMP"
# shellcheck disable=SC1090
source "$TMP"

pass=0; fail=0
check() { # name got want
  if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $1 got=[$2] want=[$3]"; fi
}

# transient spike must NOT dominate — median reflects the calm sustained load
check "calm+1spike"        "$(GATE_DOLT_CPU_SAMPLES='60 400 55 70 65' gate_dolt_cpu 999)"      "65"
check "spike-heavy-median-calm" "$(GATE_DOLT_CPU_SAMPLES='400 400 60 55 50' gate_dolt_cpu 999)" "60"
# genuinely-hot plane still reads hot (booting reviewers stay protected)
check "genuinely-hot"      "$(GATE_DOLT_CPU_SAMPLES='300 320 290 400 310' gate_dolt_cpu 999)"  "310"
check "all-calm"           "$(GATE_DOLT_CPU_SAMPLES='55 60 58 62 59' gate_dolt_cpu 999)"        "59"
# seams and edge cases
check "override-seam"      "$(GATE_DOLT_CPU_OVERRIDE='42' gate_dolt_cpu TEST)"                  "42"
check "empty-no-crash"     "$(GATE_DOLT_CPU_SAMPLES='   ' gate_dolt_cpu 999)"                   ""
check "non-numeric-filtered" "$(GATE_DOLT_CPU_SAMPLES='x 70 y 60 65' gate_dolt_cpu 999)"        "65"

echo "gate-dolt-cpu-median selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]

#!/usr/bin/env bash
# dolt-latency-alarm.selftest.sh (ga-7j5vf) — hermetic test of the pre-collapse
# latency/concurrency alarm's decision logic.
#
# Stubs `gc`, `pgrep`, `lsof`, `python3` (the pymysql-probe shape only — the
# `-c ...` JSON-parsing shape used internally by gc-dolt-probe.sh delegates to the
# REAL python3, see run_tick()) and `notify`, and points all mutable state at an
# isolated scratch dir via DOLT_LATENCY_ALARM_STATE_DIR, so ZERO real calls hit
# live Dolt, live gc, or a real phone. Mirrors the DOLT_WATCHDOG_SOURCE_ONLY /
# PATH-stub conventions dolt-hang-watchdog.sh's own harness already uses.
#
# Covers:
#   1. Pure helpers (median_of, sample_count, gt_threshold, record_reading)
#   2. live_dolt_port / conn_count via stubbed pgrep+lsof
#   3. get_latency_ms: primary path (gc_dolt_probe_json) AND fallback path
#      (timed_serve_confirm), independently forced
#   4. Full-sweep integration: cold-start min-samples gate, alarm-on-transition,
#      no-duplicate-notify while still degraded, clear-on-recovery, kill switch,
#      lock contention (live holder skips / dead holder reclaims)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DLA_SCRIPT_PATH:-$SCRIPT_DIR/dolt-latency-alarm.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

REAL_PYTHON3="$(command -v python3)"

# ══ 1. pure helpers — source with SOURCE_ONLY so nothing real gets touched ══════
STATE1="$WORK/state-unit"
mkdir -p "$STATE1"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE1"
  # shellcheck disable=SC1090
  source "$SCRIPT"

  [ -d "$STATE1/dolt-latency-alarm.lock.d" ] && echo "BUG: lock dir created during source" >&2
  declare -f median_of >/dev/null 2>&1 || echo "BUG: median_of not defined after source" >&2

  f="$WORK/nums"
  : > "$f"
  echo "median_of empty=[$(median_of "$f")]"
  printf '5\n7\n3\n' > "$f"; echo "median_of odd=$(median_of "$f")"
  printf '10\n20\n' > "$f"; echo "median_of even=$(median_of "$f")"
  printf '42\n' > "$f"; echo "median_of single=$(median_of "$f")"

  : > "$f"; echo "sample_count empty=$(sample_count "$f")"
  printf '1\n2\n3\n' > "$f"; echo "sample_count three=$(sample_count "$f")"

  gt_threshold 10 5 && echo "gt_threshold 10>5=yes" || echo "gt_threshold 10>5=no"
  gt_threshold 5 10 && echo "gt_threshold 5>10=yes" || echo "gt_threshold 5>10=no"
  gt_threshold 10 10 && echo "gt_threshold 10>10=yes" || echo "gt_threshold 10>10=no"
  gt_threshold 15.5 15 && echo "gt_threshold 15.5>15=yes" || echo "gt_threshold 15.5>15=no"

  rf="$WORK/window"
  rm -f "$rf"
  # shellcheck disable=SC2034  # read by record_reading() across the `source "$SCRIPT"` boundary above
  LATENCY_ALARM_WINDOW=3
  for v in 1 2 3 4 5; do record_reading "$rf" "$v"; done
  echo "record_reading window=[$(tr '\n' ',' < "$rf")]"
) > "$WORK/unit.out" 2>"$WORK/unit.err"

grep -q "BUG:" "$WORK/unit.err" && { nope "unit: $(cat "$WORK/unit.err")"; } || ok "unit: source-only touched nothing real"
grep -q "^median_of empty=\[\]$"    "$WORK/unit.out" && ok "median_of: empty file → empty string"        || nope "median_of empty mismatch: $(grep "median_of.*empty" "$WORK/unit.out")"
grep -q "^median_of odd=5$"         "$WORK/unit.out" && ok "median_of: [5,7,3] → 5"                      || nope "median_of odd mismatch"
grep -q "^median_of even=15$"       "$WORK/unit.out" && ok "median_of: [10,20] → 15"                     || nope "median_of even mismatch"
grep -q "^median_of single=42$"     "$WORK/unit.out" && ok "median_of: [42] → 42 (no protection alone — MIN_SAMPLES is what guards this)" || nope "median_of single mismatch"
grep -q "^sample_count empty=0$"    "$WORK/unit.out" && ok "sample_count: missing/empty → 0"             || nope "sample_count empty mismatch"
grep -q "^sample_count three=3$"    "$WORK/unit.out" && ok "sample_count: 3 lines → 3"                   || nope "sample_count three mismatch"
grep -q "^gt_threshold 10>5=yes$"   "$WORK/unit.out" && ok "gt_threshold: 10>5 → true"                   || nope "gt_threshold 10>5 mismatch"
grep -q "^gt_threshold 5>10=no$"    "$WORK/unit.out" && ok "gt_threshold: 5>10 → false"                  || nope "gt_threshold 5>10 mismatch"
grep -q "^gt_threshold 10>10=no$"   "$WORK/unit.out" && ok "gt_threshold: equal → false"                 || nope "gt_threshold equal mismatch"
grep -q "^gt_threshold 15.5>15=yes$" "$WORK/unit.out" && ok "gt_threshold: handles decimal median (even-window)" || nope "gt_threshold decimal mismatch"
grep -q "^record_reading window=\[3,4,5,\]$" "$WORK/unit.out" && ok "record_reading: truncates to last WINDOW readings" || nope "record_reading window mismatch: $(grep record_reading "$WORK/unit.out")"

# ══ 2+3. stubbed pgrep/lsof/gc/python3 for live_dolt_port / conn_count / get_latency_ms ══
STUBS="$WORK/stubs"
mkdir -p "$STUBS"

cat > "$STUBS/pgrep" <<'STUB'
#!/usr/bin/env bash
[ -n "${DLA_PGREP_PID:-}" ] && { echo "$DLA_PGREP_PID"; exit 0; }
exit 1
STUB

cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"-p "*)
    if [ -n "${DLA_LISTEN_PORT:-}" ]; then
      echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
      echo "dolt    ${DLA_PGREP_PID:-1} athos 8u IPv4 0x0 0t0 TCP *:${DLA_LISTEN_PORT} (LISTEN)"
    fi
    ;;
  *"-iTCP:"*)
    echo "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME"
    n="${DLA_CONN_COUNT:-0}"
    i=0
    while [ "$i" -lt "$n" ]; do
      echo "dolt    1 athos ${i}u IPv4 0x0 0t0 TCP 127.0.0.1:52756->127.0.0.1:9 (ESTABLISHED)"
      i=$((i+1))
    done
    ;;
esac
exit 0
STUB

cat > "$STUBS/gc" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${GC_CALLS:-/dev/null}"
case "$*" in
  *"dolt health --json"*)
    if [ "${DLA_GC_UNREACHABLE:-0}" = "1" ]; then
      exit 7   # simulate gc itself failing / unreachable — forces get_latency_ms fallback
    fi
    printf '{"server":{"reachable":true,"latency_ms":%s}}\n' "${DLA_GC_LATENCY_MS:-150}"
    exit 0
    ;;
esac
exit 0
STUB

cat > "$STUBS/python3" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "-c" ]; then
  exec "$REAL_PYTHON3" "\$@"
fi
# else: the pymysql SELECT-1 probe shape (script feeds it via heredoc on stdin,
# which we ignore — behavior is fully controlled by env, not by executing it).
[ "\${DLA_PY_FAIL:-0}" = "1" ] && exit 1
echo "\${DLA_PY_LATENCY_MS:-100}"
exit 0
STUB

chmod +x "$STUBS"/pgrep "$STUBS"/lsof "$STUBS"/gc "$STUBS"/python3

# 2a. live_dolt_port / conn_count via direct function calls (SOURCE_ONLY + stub PATH)
STATE2="$WORK/state-unit2"; mkdir -p "$STATE2"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE2"
  export PATH="$STUBS:$PATH"
  # shellcheck disable=SC1090
  source "$SCRIPT"

  DLA_PGREP_PID=555 DLA_LISTEN_PORT=52756 echo "port_found=$(DLA_PGREP_PID=555 DLA_LISTEN_PORT=52756 live_dolt_port)"
  echo "port_fallback=$(live_dolt_port)"   # no pgrep hit → DOLT_PORT_DEFAULT
  echo "conns=$(DLA_PGREP_PID=555 DLA_LISTEN_PORT=52756 DLA_CONN_COUNT=7 conn_count)"
) > "$WORK/probe.out" 2>&1

grep -q "^port_found=52756$"    "$WORK/probe.out" && ok "live_dolt_port: derives port from live pgrep+lsof, not config default" || nope "live_dolt_port found mismatch: $(cat "$WORK/probe.out")"
grep -q "^port_fallback=52756$" "$WORK/probe.out" && ok "live_dolt_port: falls back to DOLT_PORT_DEFAULT when no process found" || nope "live_dolt_port fallback mismatch"
grep -q "^conns=7$"             "$WORK/probe.out" && ok "conn_count: reports lsof ESTABLISHED count on the derived port" || nope "conn_count mismatch: $(grep conns= "$WORK/probe.out")"

# 2b. get_latency_ms: primary (gc_dolt_probe_json) vs fallback (timed_serve_confirm)
STATE3="$WORK/state-unit3"; mkdir -p "$STATE3"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE3"
  export PATH="$STUBS:$PATH"
  # gc-dolt-probe.sh resolves its gc call via "${GC_BIN:-gc}" — this AGENT SESSION
  # has GC_BIN pre-set to the real absolute binary (verified live: bypasses PATH
  # entirely), so PATH-stubbing alone is not enough here; point GC_BIN at the stub
  # directly, the same override knob gc-dolt-probe.sh's own internal selftest uses.
  export GC_BIN="$STUBS/gc"
  export GC_CALLS="$WORK/gc.calls.probe"; : > "$GC_CALLS"
  # shellcheck disable=SC1090
  source "$SCRIPT"

  declare -f gc_dolt_probe_json >/dev/null 2>&1 && echo "probe_sourced=yes" || echo "probe_sourced=no"

  echo "primary=$(DLA_GC_LATENCY_MS=321 get_latency_ms)"
  echo "fallback=$(DLA_GC_UNREACHABLE=1 DLA_PY_LATENCY_MS=888 get_latency_ms)"
  echo "both_fail=[$(DLA_GC_UNREACHABLE=1 DLA_PY_FAIL=1 get_latency_ms)]"
) > "$WORK/latency.out" 2>&1

grep -q "^probe_sourced=yes$" "$WORK/latency.out" && ok "gc-dolt-probe.sh sourced (gc_dolt_probe_json available)" || nope "gc-dolt-probe.sh not sourced — check CITY path: $(cat "$WORK/latency.out")"
grep -q "^primary=321$"   "$WORK/latency.out" && ok "get_latency_ms: uses gc_dolt_probe_json when it yields a reachable latency" || nope "primary path mismatch: $(grep '^primary=' "$WORK/latency.out")"
grep -q "^fallback=888$"  "$WORK/latency.out" && ok "get_latency_ms: falls back to timed_serve_confirm when gc probe is unreachable" || nope "fallback path mismatch: $(grep '^fallback=' "$WORK/latency.out")"
grep -q "^both_fail=\[\]$" "$WORK/latency.out" && ok "get_latency_ms: empty (not 0, not a fabricated number) when BOTH probes fail" || nope "both-fail mismatch: $(grep both_fail "$WORK/latency.out")"

# ══ 4. full-sweep integration — real subprocess execution, stubbed world ════════
NOTIFY_STUB="$STUBS/notify"
cat > "$NOTIFY_STUB" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${NOTIFY_CALLS:-/dev/null}"
exit 0
STUB
chmod +x "$NOTIFY_STUB"

run_tick() {  # run_tick — one script invocation with the stub PATH + isolated state
  PATH="$STUBS:$PATH" \
    GC_BIN="$STUBS/gc" \
    DOLT_LATENCY_ALARM_STATE_DIR="$TICK_STATE" \
    DOLT_LATENCY_ALARM_ENABLED="${TICK_ENABLED:-1}" \
    NOTIFY_CALLS="$NOTIFY_CALLS" \
    GC_CALLS="$GC_CALLS" \
    DLA_PGREP_PID=555 DLA_LISTEN_PORT=52756 \
    DLA_GC_LATENCY_MS="${DLA_GC_LATENCY_MS:-150}" \
    DLA_CONN_COUNT="${DLA_CONN_COUNT:-2}" \
    bash "$SCRIPT" >/dev/null 2>&1
}

# 4a. cold start: two degraded ticks must NOT notify (n < MIN_SAMPLES=3 default)
TICK_STATE="$WORK/sweep-a"; mkdir -p "$TICK_STATE"
NOTIFY_CALLS="$WORK/notify-a.calls"; GC_CALLS="$WORK/gc-a.calls"; : > "$NOTIFY_CALLS"; : > "$GC_CALLS"
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$NOTIFY_CALLS" ] && nope "cold-start: must NOT notify before MIN_SAMPLES readings" || ok "cold-start: 2 degraded ticks (n<3) → no notify yet"

# 4b. third tick (n=3) crosses MIN_SAMPLES → alarm fires exactly once
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$NOTIFY_CALLS" ] && ok "3rd degraded tick (n=3) → alarm notify fires" || nope "3rd tick should have notified"
grep -q "Dolt degradando" "$NOTIFY_CALLS" 2>/dev/null && ok "alarm notify uses the pre-collapse 'Dolt degradando' title" || nope "unexpected notify content: $(cat "$NOTIFY_CALLS" 2>/dev/null)"
[ -f "$TICK_STATE/dolt-latency-alarm.active" ] && ok "alarm-active marker file created" || nope "active marker missing after alarm"

# 4c. still-degraded 4th tick must NOT re-notify (state-transition-only, no spam)
: > "$NOTIFY_CALLS"
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$NOTIFY_CALLS" ] && nope "still-degraded tick must NOT re-notify while already active" || ok "still-degraded: no duplicate notify while alarm already active"

# 4d. recovery: window fills with healthy readings → alarm clears, notify fires once
for _ in 1 2 3 4 5; do DLA_CONN_COUNT=2 DLA_GC_LATENCY_MS=150 run_tick; done
[ -s "$NOTIFY_CALLS" ] && ok "recovery: healthy window → clear notify fires" || nope "recovery should have notified"
grep -q "Dolt normalizou" "$NOTIFY_CALLS" 2>/dev/null && ok "clear notify uses 'Dolt normalizou' title" || nope "unexpected clear-notify content: $(cat "$NOTIFY_CALLS" 2>/dev/null)"
[ -f "$TICK_STATE/dolt-latency-alarm.active" ] && nope "active marker should be removed after clear" || ok "active marker removed after clear"

# 4e. LATENCY-ONLY degradation (conns stay LOW/healthy) must independently trigger
# the alarm — this is the whole point of ga-7j5vf (availability/single-signal
# checks miss exactly this shape: a slow-but-serving Dolt with few held
# connections). Isolated sweep dir so it can't inherit 4a-4d's conn-based state.
TICK_STATE="$WORK/sweep-lat"; mkdir -p "$TICK_STATE"
NOTIFY_CALLS="$WORK/notify-lat.calls"; GC_CALLS="$WORK/gc-lat.calls"; : > "$NOTIFY_CALLS"; : > "$GC_CALLS"
DLA_CONN_COUNT=2 DLA_GC_LATENCY_MS=900 run_tick
DLA_CONN_COUNT=2 DLA_GC_LATENCY_MS=900 run_tick
DLA_CONN_COUNT=2 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$NOTIFY_CALLS" ] && ok "latency-only (conns healthy at 2): alarm fires on latency alone" || nope "latency-only degradation should have alarmed"
# (Not asserting against $LOG content: LOG uses the hardcoded CITY path, same
# awkward-to-isolate tradeoff dolt-hang-watchdog.selftest.sh's own header notes —
# the notify-call assertion above already fully proves this tick's decision.)

# 4f. kill switch: degraded readings still detected (state updates) but never notify
TICK_STATE="$WORK/sweep-e"; mkdir -p "$TICK_STATE"
NOTIFY_CALLS="$WORK/notify-e.calls"; GC_CALLS="$WORK/gc-e.calls"; : > "$NOTIFY_CALLS"; : > "$GC_CALLS"
TICK_ENABLED=0
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
TICK_ENABLED=1
[ -s "$NOTIFY_CALLS" ] && nope "kill switch (ENABLED=0): must never call notify" || ok "kill switch: degraded but ENABLED=0 → no notify"
[ -f "$TICK_STATE/dolt-latency-alarm.active" ] && ok "kill switch: still tracks active state internally (log/state unaffected by the switch)" || nope "kill switch should still mark active state"

# 4g. lock contention: a LIVE holder PID → tick is skipped (window does not grow)
TICK_STATE="$WORK/sweep-f"; mkdir -p "$TICK_STATE" "$TICK_STATE/dolt-latency-alarm.lock.d"
echo $$ > "$TICK_STATE/dolt-latency-alarm.lock.d/pid"   # this test process — guaranteed alive
NOTIFY_CALLS="$WORK/notify-f.calls"; GC_CALLS="$WORK/gc-f.calls"; : > "$NOTIFY_CALLS"
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$TICK_STATE/dolt-latency-alarm.conn-window" ] && nope "live-lock-holder: tick should have been skipped (window grew anyway)" || ok "lock: live holder PID → tick skipped, window untouched"
rm -rf "$TICK_STATE/dolt-latency-alarm.lock.d"

# 4h. lock contention: a DEAD holder PID → lock is reclaimed, tick proceeds
mkdir -p "$TICK_STATE/dolt-latency-alarm.lock.d"
( : ) & deadpid=$!; wait "$deadpid" 2>/dev/null   # spawn+reap: PID is now guaranteed not alive
echo "$deadpid" > "$TICK_STATE/dolt-latency-alarm.lock.d/pid"
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 run_tick
[ -s "$TICK_STATE/dolt-latency-alarm.conn-window" ] && ok "lock: dead holder PID → reclaimed, tick proceeded" || nope "dead-holder lock should have been reclaimed"

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]

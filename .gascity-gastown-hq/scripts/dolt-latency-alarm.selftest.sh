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
#   5. (ga-0k78d4) Dolt scheduling-priority (nice) detector — the three states
#      ok / alarm / unknown, at four levels:
#        5a. proc_nice against the REAL ps on real processes, checked against the
#            kernel's own getpriority(2) (read through python, not through ps)
#        5b. proc_nice's parse contract (padding, sign, empty, garbage, multi-line)
#        5c. dolt_nice_state classification (incl. "no live Dolt" and "ps broken")
#        5d. full ticks through the REAL script (not SOURCE_ONLY): one alarm per
#            episode, clear on recovery, healthy = silent, unknown != ok, unknown
#            never clears an active alarm, kill switch, independence from the
#            latency alarm (separate markers, and a failing latency probe does not
#            stop the nice check)
#      Every tick's log goes to a scratch file (DOLT_LATENCY_ALARM_LOG) so nothing
#      here writes fake ALARM/CLEARED lines into the live log.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${DLA_SCRIPT_PATH:-$SCRIPT_DIR/dolt-latency-alarm.sh}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'ok   - %s\n' "$1"; }
nope() { FAIL=$((FAIL+1)); printf 'FAIL - %s\n' "$1"; }

WORK=$(mktemp -d)

# ga-0bjqix: live_dolt_port() now resolves its PID via the shared dolt_server_pid()
# (dolt-pid-lib.sh), which liveness-checks its candidate with a REAL `kill -0` —
# a fictional PID literal (the old "555") would just fail that check silently.
# Spawn one real, harmless, long-lived process to stand in for "the dolt process
# pgrep found"; its comm/listen-socket identity is still faked via the ps/lsof
# stubs below, keyed off this real PID. (No GC_CITY scratch override needed for
# dolt_server_pid()'s pidfile step: the ps/lsof stubs arbitrate purely by
# exact-PID-match against DLA_PGREP_PID, so a real dolt.pid -- if the host
# running this test happens to have one -- is harmless; its PID just never
# matches and that candidate is correctly rejected.)
sleep 300 & DLA_REAL_PID=$!
# ga-0k78d4: extra long-lived helpers (section 5a spawns two); reaped by the trap below
# even if the run is interrupted, so a stray `sleep 300` cannot outlive the test.
DLA_EXTRA_PIDS=""

trap 'kill "$DLA_REAL_PID" $DLA_EXTRA_PIDS 2>/dev/null; rm -rf "$WORK"' EXIT

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

# ga-0bjqix: dolt_server_pid()'s _dolt_pid_is_server checks `ps -o comm= -p PID`
# before trusting a pgrep candidate -- only DLA_PGREP_PID reports comm=dolt.
cat > "$STUBS/ps" <<'STUB'
#!/usr/bin/env bash
pid=""
for a in "$@"; do case "$a" in [0-9]*) pid="$a" ;; esac; done
case " $* " in
  # ga-0k78d4: `ps -o ni= -p PID` (matched by substring, not by argv position, so a flag
  # inserted before it cannot silently route it to the wrong branch). Real ps pads the
  # value ("[ 0]" measured live), so the default reply is padded too.
  *"ni="*)
    [ "${DLA_PS_FAIL:-0}" = "1" ] && exit 1                                  # ps broken: no output, rc 1
    [ -n "${DLA_PS_NI_RAW+x}" ] && { printf '%s\n' "$DLA_PS_NI_RAW"; exit 0; }  # verbatim override (garbage / multi-line)
    printf '%3s\n' "${DLA_PS_NI:-0}" ;;
  *"%cpu"*) echo "0.0" ;;
  *) if [ -n "${DLA_PGREP_PID:-}" ] && [ "$pid" = "${DLA_PGREP_PID:-}" ]; then echo "dolt"; else echo "?"; fi ;;
esac
exit 0
STUB

cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
case " $* " in
  *" -iTCP -sTCP:LISTEN"*)
    # dolt_server_pid()'s own is-this-really-the-server check (exit code only,
    # no output parsed) -- distinct from live_dolt_port()'s own port-scrape
    # lsof call below (same lsof, different invocation shape).
    pid="" prev=""
    for a in "$@"; do
      [ "$prev" = "-p" ] && pid="$a"
      prev="$a"
    done
    if [ -n "${DLA_LISTEN_PORT:-}" ] && [ "$pid" = "${DLA_PGREP_PID:-}" ]; then exit 0; else exit 1; fi
    ;;
esac
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

chmod +x "$STUBS"/pgrep "$STUBS"/ps "$STUBS"/lsof "$STUBS"/gc "$STUBS"/python3

# 2a. live_dolt_port / conn_count via direct function calls (SOURCE_ONLY + stub PATH)
STATE2="$WORK/state-unit2"; mkdir -p "$STATE2"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE2"
  export PATH="$STUBS:$PATH"
  # NOTE: no GC_CITY override here -- the ps/lsof stubs below arbitrate purely
  # by exact-PID-match against DLA_PGREP_PID, so a real dolt.pid on the host
  # running this test is harmless either way (its PID just never matches).
  # gc-dolt-probe.sh separately needs GC_CITY for its own `cd "$CITY"` before
  # calling `gc dolt health` -- overriding it here breaks THAT, unrelated to
  # PID resolution (see the 2b block below, which learned this the hard way).
  # shellcheck disable=SC1090
  source "$SCRIPT"

  echo "port_found=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_LISTEN_PORT=52756 live_dolt_port)"
  echo "port_fallback=$(live_dolt_port)"   # no pgrep hit → DOLT_PORT_DEFAULT
  echo "conns=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_LISTEN_PORT=52756 DLA_CONN_COUNT=7 conn_count)"
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
  # ga-0k78d4: TICK_LOG -> a scratch log (default /dev/null, so no tick ever writes into the
  # live log); DLA_PS_NI / DLA_PS_FAIL drive the ps stub; TICK_NO_DOLT=1 -> pgrep finds no
  # server; DLA_GC_UNREACHABLE / DLA_PY_FAIL fail the latency probes. All explicit, all
  # defaulted, so a knob set for one scenario cannot leak into the next.
  local _dolt_pid="$DLA_REAL_PID"
  [ "${TICK_NO_DOLT:-0}" = "1" ] && _dolt_pid=""
  PATH="$STUBS:$PATH" \
    GC_BIN="$STUBS/gc" \
    DOLT_LATENCY_ALARM_STATE_DIR="$TICK_STATE" \
    DOLT_LATENCY_ALARM_LOG="${TICK_LOG:-/dev/null}" \
    DOLT_LATENCY_ALARM_ENABLED="${TICK_ENABLED:-1}" \
    NOTIFY_CALLS="$NOTIFY_CALLS" \
    GC_CALLS="$GC_CALLS" \
    DLA_PGREP_PID="$_dolt_pid" DLA_LISTEN_PORT=52756 \
    DLA_GC_LATENCY_MS="${DLA_GC_LATENCY_MS:-150}" \
    DLA_CONN_COUNT="${DLA_CONN_COUNT:-2}" \
    DLA_PS_NI="${DLA_PS_NI:-0}" DLA_PS_FAIL="${DLA_PS_FAIL:-0}" \
    DLA_GC_UNREACHABLE="${DLA_GC_UNREACHABLE:-0}" DLA_PY_FAIL="${DLA_PY_FAIL:-0}" \
    DOLT_NICE_UNKNOWN_NOTIFY_AFTER="${DLA_NICE_NOTIFY_AFTER:-}" \
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
# (Not asserting against the log here: the notify-call assertion above already fully
# proves this tick's decision. The log IS assertable now -- run_tick points it at
# TICK_LOG via DOLT_LATENCY_ALARM_LOG -- and section 5 does assert on it.)

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

# ══ 5. (ga-0k78d4) Dolt scheduling-priority (nice) detector ═════════════════════════
# The why is in the SECOND SIGNAL block of dolt-latency-alarm.sh's header. Three states, never
# collapsed: ok (nice 0) / alarm (nice != 0) / unknown (could not read -- and that is NOT nice 0).

expect_line() {  # expect_line FILE EXACT-LINE DESCRIPTION — pass iff FILE holds EXACT-LINE verbatim
  if grep -qxF -- "$2" "$1" 2>/dev/null; then ok "$3"; else nope "$3 [want: $2 | got: $(grep -F -- "${2%%=*}=" "$1" 2>/dev/null | head -1)]"; fi
}
ncalls() {  # ncalls FILE PATTERN — how many lines of FILE match PATTERN (0 when none, or FILE missing)
  local _n
  _n="$(grep -c -- "$2" "$1" 2>/dev/null)" || true
  echo "${_n:-0}"
}
nice_scenario() {  # nice_scenario NAME — fresh isolated state + notify log + detector log for one scenario
  TICK_STATE="$WORK/nice-$1"; mkdir -p "$TICK_STATE"
  NOTIFY_CALLS="$WORK/nice-$1.notify"; GC_CALLS="$WORK/nice-$1.gc"; TICK_LOG="$WORK/nice-$1.log"
  : > "$NOTIFY_CALLS"; : > "$GC_CALLS"; : > "$TICK_LOG"
}

# 5a. proc_nice against the REAL ps, on REAL processes (no ps stub on PATH), checked against the
# kernel's own answer -- getpriority(2), read through python: an independent path. The expected
# value is asked of the kernel and never hard-coded: zsh runs a background job at nice +5
# (BG_NICE) and `nice -n 15` ADDS to its parent's nice (clamped at 20), so a literal 0 or 15
# would be wrong on some runner.
kernel_nice() {  # kernel_nice PID — PID's nice per getpriority(2); empty when unreadable
  "$REAL_PYTHON3" -c 'import os,sys; print(os.getpriority(os.PRIO_PROCESS, int(sys.argv[1])))' "$1" 2>/dev/null
}
sleep 300 & DLA_NICE_P0=$!
nice -n 15 sleep 300 & DLA_NICE_P15=$!
DLA_EXTRA_PIDS="$DLA_NICE_P0 $DLA_NICE_P15"
# `nice` applies its priority a moment AFTER the fork: wait (bounded) until the kernel reports it,
# so the comparison below cannot race the setpriority call.
_i=0
while [ "$_i" -lt 60 ]; do
  _k="$(kernel_nice "$DLA_NICE_P15")"
  { [ -n "$_k" ] && [ "$_k" -ge 15 ]; } 2>/dev/null && break
  sleep 0.1; _i=$((_i+1))
done
( : ) & DLA_NICE_GONE=$!; wait "$DLA_NICE_GONE" 2>/dev/null   # spawn+reap: a PID that WAS live and is not anymore
STATE5A="$WORK/state-nice-real"; mkdir -p "$STATE5A"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE5A"
  # shellcheck disable=SC1090
  source "$SCRIPT"
  declare -f proc_nice >/dev/null 2>&1 && echo "defined=yes" || echo "defined=no"
  echo "plain_proc=$(proc_nice "$DLA_NICE_P0")"
  echo "plain_kernel=$(kernel_nice "$DLA_NICE_P0")"
  echo "niced_proc=$(proc_nice "$DLA_NICE_P15")"
  echo "niced_kernel=$(kernel_nice "$DLA_NICE_P15")"
  _g="$(proc_nice "$DLA_NICE_GONE")"; _grc=$?
  echo "gone=[$_g] rc=$_grc"
  _g="$(proc_nice 99999999)"; _grc=$?
  echo "toolarge=[$_g] rc=$_grc"
) > "$WORK/nice-real.out" 2>&1
nice_field() { sed -n "s/^$1=//p" "$WORK/nice-real.out" | head -1; }
expect_line "$WORK/nice-real.out" "defined=yes" "5a: proc_nice is defined by the script (SOURCE_ONLY reaches it)"
_pp="$(nice_field plain_proc)"; _pk="$(nice_field plain_kernel)"
{ [ -n "$_pk" ] && [ "$_pp" = "$_pk" ]; } && ok "5a: real ps, plain process: proc_nice ($_pp) == kernel getpriority ($_pk)" || nope "5a: plain process: proc_nice='$_pp' kernel='$_pk'"
_np="$(nice_field niced_proc)"; _nk="$(nice_field niced_kernel)"
{ [ -n "$_nk" ] && [ "$_np" = "$_nk" ] && [ "$_nk" -ge 15 ]; } 2>/dev/null && ok "5a: real ps, 'nice -n 15' process: proc_nice ($_np) == kernel ($_nk) and >= 15 (the reading is not vacuously 0)" || nope "5a: niced process: proc_nice='$_np' kernel='$_nk' (want equal, and >= 15)"
expect_line "$WORK/nice-real.out" "gone=[] rc=1" "5a: a PID that was live and is gone → prints nothing, rc 1 (unreadable — never 0)"
expect_line "$WORK/nice-real.out" "toolarge=[] rc=1" "5a: a PID ps rejects outright → prints nothing, rc 1"
kill "$DLA_NICE_P0" "$DLA_NICE_P15" 2>/dev/null
wait "$DLA_NICE_P0" "$DLA_NICE_P15" 2>/dev/null   # reap: keeps bash 3.2's "Terminated" job notices out of the log
DLA_EXTRA_PIDS=""

# 5b. proc_nice's parse contract, driven through the ps stub (DLA_PS_NI = a padded reply, like real
# ps; DLA_PS_NI_RAW = a verbatim reply; DLA_PS_FAIL = ps exits 1 with no output). Only exactly ONE
# line holding exactly ONE integer is a nice value. Anything else must print nothing and return 1,
# and must never be glued into a number.
STATE5B="$WORK/state-nice-parse"; mkdir -p "$STATE5B"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE5B"
  export PATH="$STUBS:$PATH"
  # shellcheck disable=SC1090
  source "$SCRIPT"
  pn() {  # pn LABEL — proc_nice on a fixed PID; prints "LABEL=[stdout] rc=N" (the stub's reply comes from the caller's DLA_PS_* env)
    local _o _rc
    _o="$(proc_nice 4242)"; _rc=$?
    echo "$1=[$_o] rc=$_rc"
  }
  DLA_PS_NI=0   pn pad_zero
  DLA_PS_NI=15  pn pad_15
  DLA_PS_NI=-5  pn neg_5
  DLA_PS_NI=-15 pn neg_15
  DLA_PS_NI_RAW=""       pn empty_line
  DLA_PS_NI_RAW="abc"    pn alpha
  DLA_PS_NI_RAW="1x"     pn digit_then_alpha
  DLA_PS_NI_RAW="5-"     pn trailing_minus
  DLA_PS_NI_RAW="--5"    pn double_minus
  DLA_PS_NI_RAW="-"      pn lone_minus
  DLA_PS_NI_RAW="+5"     pn plus_sign
  DLA_PS_NI_RAW="0 15"   pn two_fields
  DLA_PS_NI_RAW=$'0\n15' pn two_lines
  DLA_PS_NI_RAW="ps: process id too large: 1" pn error_text_on_stdout
  DLA_PS_FAIL=1          pn ps_failed
  _o="$(proc_nice "")"; _rc=$?; echo "no_pid=[$_o] rc=$_rc"
) > "$WORK/nice-parse.out" 2>&1
expect_line "$WORK/nice-parse.out" "pad_zero=[0] rc=0"    "5b: padded '  0' → 0, rc 0"
expect_line "$WORK/nice-parse.out" "pad_15=[15] rc=0"     "5b: padded ' 15' → 15, rc 0"
expect_line "$WORK/nice-parse.out" "neg_5=[-5] rc=0"      "5b: '-5' → -5 (a negative nice is a value, not an error)"
expect_line "$WORK/nice-parse.out" "neg_15=[-15] rc=0"    "5b: '-15' → -15"
expect_line "$WORK/nice-parse.out" "empty_line=[] rc=1"   "5b: an empty reply → nothing, rc 1 (never 0)"
expect_line "$WORK/nice-parse.out" "alpha=[] rc=1"        "5b: 'abc' → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "digit_then_alpha=[] rc=1" "5b: '1x' → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "trailing_minus=[] rc=1"   "5b: '5-' → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "double_minus=[] rc=1"     "5b: '--5' → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "lone_minus=[] rc=1"       "5b: a lone '-' → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "plus_sign=[] rc=1"        "5b: '+5' → nothing, rc 1 (ps never prints a plus; refuse rather than guess)"
expect_line "$WORK/nice-parse.out" "two_fields=[] rc=1"       "5b: '0 15' (two fields on one line) → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "two_lines=[] rc=1"        "5b: two lines → nothing, rc 1 (never glued into 015)"
expect_line "$WORK/nice-parse.out" "error_text_on_stdout=[] rc=1" "5b: an error message that lands on stdout is not a nice value"
expect_line "$WORK/nice-parse.out" "ps_failed=[] rc=1"        "5b: ps exiting non-zero with no output → nothing, rc 1"
expect_line "$WORK/nice-parse.out" "no_pid=[] rc=1"           "5b: an empty PID argument → nothing, rc 1"

# 5c. dolt_nice_state — the three-state classification. The PID goes through the REAL
# dolt_server_pid (only its ps/pgrep/lsof inputs are stubbed).
STATE5C="$WORK/state-nice-state"; mkdir -p "$STATE5C"
(
  export DOLT_LATENCY_ALARM_SOURCE_ONLY=1 DOLT_LATENCY_ALARM_STATE_DIR="$STATE5C"
  export PATH="$STUBS:$PATH"
  export DLA_LISTEN_PORT=52756
  # shellcheck disable=SC1090
  source "$SCRIPT"
  echo "ok=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_PS_NI=0 dolt_nice_state)"
  echo "alarm=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_PS_NI=15 dolt_nice_state)"
  echo "alarm_negative=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_PS_NI=-5 dolt_nice_state)"
  echo "no_dolt=$(DLA_PGREP_PID='' dolt_nice_state)"
  echo "ps_failed=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_PS_FAIL=1 dolt_nice_state)"
  echo "ps_garbage=$(DLA_PGREP_PID=$DLA_REAL_PID DLA_PS_NI_RAW=abc dolt_nice_state)"
) > "$WORK/nice-state.out" 2>&1
expect_line "$WORK/nice-state.out" "ok=ok ni=0 pid=$DLA_REAL_PID"                      "5c: nice 0 → ok"
expect_line "$WORK/nice-state.out" "alarm=alarm ni=15 pid=$DLA_REAL_PID"               "5c: nice 15 → alarm"
expect_line "$WORK/nice-state.out" "alarm_negative=alarm ni=-5 pid=$DLA_REAL_PID"      "5c: nice -5 → alarm (any deviation from the default is worth a line)"
expect_line "$WORK/nice-state.out" "no_dolt=unknown no-live-dolt-server"               "5c: no live Dolt → unknown (not ok, not alarm)"
expect_line "$WORK/nice-state.out" "ps_failed=unknown nice-unreadable pid=$DLA_REAL_PID"  "5c: Dolt live but ps broken → unknown (NOT ok)"
expect_line "$WORK/nice-state.out" "ps_garbage=unknown nice-unreadable pid=$DLA_REAL_PID" "5c: Dolt live but ps prints garbage → unknown (NOT ok)"

# 5d. full ticks through the REAL script (a real subprocess, stubbed world).
RUNBOOK="${DLA_RUNBOOK_PATH:-$SCRIPT_DIR/../docs/runbooks/dolt-priority-nice.md}"

# 5d-1. healthy Dolt (nice 0): silent -- and the tick still ran to the end, so silence is not a crash
nice_scenario healthy
run_tick; run_tick; run_tick
[ -s "$NOTIFY_CALLS" ] && nope "5d healthy (nice 0): must be silent, got: $(cat "$NOTIFY_CALLS")" || ok "5d healthy (nice 0): 3 ticks → no notify"
{ [ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && [ ! -f "$TICK_STATE/dolt-latency-alarm.nice-unknown" ]; } && ok "5d healthy: no nice marker written" || nope "5d healthy: a nice marker exists"
[ "$(ncalls "$TICK_LOG" 'NICE')" = "0" ] && ok "5d healthy: nothing NICE-related in the log" || nope "5d healthy: unexpected NICE log line: $(grep NICE "$TICK_LOG")"
[ -s "$TICK_STATE/dolt-latency-alarm.conn-window" ] && ok "5d healthy: the tick ran to the end (latency window recorded)" || nope "5d healthy: latency window empty — the tick did not complete"

# 5d-2. nice 15: ONE alarm per episode
nice_scenario alarm
DLA_PS_NI=15 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt em prioridade baixa')" = "1" ] && ok "5d alarm: nice 15 → exactly one 'Dolt em prioridade baixa' notify" || nope "5d alarm: notify calls: $(cat "$NOTIFY_CALLS")"
[ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && ok "5d alarm: episode marker written" || nope "5d alarm: episode marker missing"
grep -q "NICE ALARM" "$TICK_LOG" && ok "5d alarm: logged as NICE ALARM" || nope "5d alarm: no NICE ALARM line in the log"
grep -q 'docs/runbooks/dolt-priority-nice.md' "$NOTIFY_CALLS" && ok "5d alarm: the notify names the runbook" || nope "5d alarm: the notify does not name the runbook"
[ -s "$RUNBOOK" ] && ok "5d alarm: the runbook the alert points at exists" || nope "5d alarm: the alert points at docs/runbooks/dolt-priority-nice.md but $RUNBOOK is missing/empty"
grep -q 'ps -o ni=' "$RUNBOOK" 2>/dev/null && ok "5d alarm: the runbook carries the post-start check (ps -o ni=)" || nope "5d alarm: the runbook lacks the 'ps -o ni=' post-start check"
DLA_PS_NI=15 run_tick; DLA_PS_NI=15 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt em prioridade baixa')" = "1" ] && ok "5d alarm: 2 more ticks still at nice 15 → no repeat notify (one per episode)" || nope "5d alarm: re-notified inside one episode: $(cat "$NOTIFY_CALLS")"

# 5d-3. recovery, then a NEW episode (continues the same scenario)
DLA_PS_NI=0 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt voltou a nice 0')" = "1" ] && ok "5d recovery: nice back to 0 → one 'Dolt voltou a nice 0' notify" || nope "5d recovery: notify calls: $(cat "$NOTIFY_CALLS")"
[ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && ok "5d recovery: episode marker removed" || nope "5d recovery: episode marker still there"
grep -q "NICE alarm CLEARED" "$TICK_LOG" && ok "5d recovery: logged as CLEARED" || nope "5d recovery: no CLEARED line in the log"
DLA_PS_NI=0 run_tick
[ "$(wc -l < "$NOTIFY_CALLS" | tr -d ' ')" = "2" ] && ok "5d recovery: healthy again → silent (2 notifies in total: alarm + clear)" || nope "5d recovery: unexpected extra notify: $(cat "$NOTIFY_CALLS")"
DLA_PS_NI=15 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt em prioridade baixa')" = "2" ] && ok "5d recovery: a NEW episode after recovery alarms again" || nope "5d recovery: a second episode did not alarm: $(cat "$NOTIFY_CALLS")"

# 5d-4. unknown != ok: ps broken while Dolt is live
nice_scenario unknown
DLA_PS_FAIL=1 run_tick; DLA_PS_FAIL=1 run_tick
[ ! -s "$NOTIFY_CALLS" ] && ok "5d unknown: 2 unreadable ticks (< threshold 3) → silent" || nope "5d unknown: notified too early: $(cat "$NOTIFY_CALLS")"
[ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && ok "5d unknown: unreadable is NOT an alarm (no episode marker)" || nope "5d unknown: unreadable raised the alarm"
[ "$(cat "$TICK_STATE/dolt-latency-alarm.nice-unknown" 2>/dev/null)" = "2" ] && ok "5d unknown: the unreadable streak is counted (2)" || nope "5d unknown: streak counter = '$(cat "$TICK_STATE/dolt-latency-alarm.nice-unknown" 2>/dev/null)'"
grep -q "NICE UNKNOWN" "$TICK_LOG" && ok "5d unknown: logged as NICE UNKNOWN" || nope "5d unknown: no NICE UNKNOWN line in the log"
[ "$(ncalls "$TICK_LOG" 'CLEARED')" = "0" ] && ok "5d unknown: never logged as CLEARED (unreadable is not 'nice 0')" || nope "5d unknown: logged a CLEARED"
DLA_PS_FAIL=1 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "1" ] && ok "5d unknown: 3rd consecutive unreadable tick → one 'detector is blind' notify" || nope "5d unknown: notify calls: $(cat "$NOTIFY_CALLS")"
DLA_PS_FAIL=1 run_tick; DLA_PS_FAIL=1 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "1" ] && ok "5d unknown: 2 more unreadable ticks → still just the one notify (escalates once)" || nope "5d unknown: repeated the blind notify: $(cat "$NOTIFY_CALLS")"
[ "$(ncalls "$NOTIFY_CALLS" 'prioridade baixa')" = "0" ] && ok "5d unknown: never raised the nice alarm" || nope "5d unknown: raised the nice alarm: $(cat "$NOTIFY_CALLS")"
DLA_PS_NI=0 run_tick
grep -q "NICE readable again after 5 unknown tick" "$TICK_LOG" && ok "5d unknown: a readable tick logs the end of the streak (5)" || nope "5d unknown: no 'readable again' line: $(grep NICE "$TICK_LOG")"
[ ! -f "$TICK_STATE/dolt-latency-alarm.nice-unknown" ] && ok "5d unknown: the streak counter is removed once readable" || nope "5d unknown: streak counter survived a readable tick"

# 5d-5. unknown must NEVER clear an active alarm (an unreadable Dolt is not a healthy one)
nice_scenario keeps-alarm
DLA_PS_NI=15 run_tick
DLA_PS_FAIL=1 run_tick; DLA_PS_FAIL=1 run_tick; DLA_PS_FAIL=1 run_tick
[ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && ok "5d keeps-alarm: 3 unreadable ticks while alarmed → the alarm marker is NOT cleared" || nope "5d keeps-alarm: unreadable cleared an active alarm"
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt voltou a nice 0')" = "0" ] && ok "5d keeps-alarm: ...and no 'back to nice 0' notify" || nope "5d keeps-alarm: announced recovery from an unreadable state: $(cat "$NOTIFY_CALLS")"
DLA_PS_NI=15 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'Dolt em prioridade baixa')" = "1" ] && ok "5d keeps-alarm: back to a readable nice 15 → same episode, no re-notify" || nope "5d keeps-alarm: the episode was reset by the unreadable gap: $(cat "$NOTIFY_CALLS")"
DLA_PS_NI=0 run_tick
{ [ "$(ncalls "$NOTIFY_CALLS" 'Dolt voltou a nice 0')" = "1" ] && [ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ]; } && ok "5d keeps-alarm: only a readable nice 0 clears it" || nope "5d keeps-alarm: final clear missing: $(cat "$NOTIFY_CALLS")"

# 5d-6. no live Dolt at all: unknown as well -- not ok, not alarm
nice_scenario nodolt
TICK_NO_DOLT=1 run_tick; TICK_NO_DOLT=1 run_tick; TICK_NO_DOLT=1 run_tick
{ [ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && [ "$(cat "$TICK_STATE/dolt-latency-alarm.nice-unknown" 2>/dev/null)" = "3" ]; } && ok "5d no-dolt: no live server → unknown (streak 3), not alarm, not ok" || nope "5d no-dolt: markers wrong (unknown='$(cat "$TICK_STATE/dolt-latency-alarm.nice-unknown" 2>/dev/null)')"
grep -q "no-live-dolt-server" "$TICK_LOG" && ok "5d no-dolt: the log names the reason" || nope "5d no-dolt: reason missing from the log"
[ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "1" ] && ok "5d no-dolt: the blind-detector notify fires once at the threshold" || nope "5d no-dolt: notify calls: $(cat "$NOTIFY_CALLS")"

# 5d-7. kill switch: still detected, marked and logged -- never notified
nice_scenario killswitch
TICK_ENABLED=0 DLA_PS_NI=15 run_tick
[ ! -s "$NOTIFY_CALLS" ] && ok "5d kill switch (ENABLED=0): the nice alarm never notifies" || nope "5d kill switch: notified anyway: $(cat "$NOTIFY_CALLS")"
{ [ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && grep -q "NICE ALARM" "$TICK_LOG"; } && ok "5d kill switch: the alarm is still tracked and logged" || nope "5d kill switch: the detector went blind with the switch off"

# 5d-8. independence from the latency alarm
nice_scenario indep-probes-fail
DLA_GC_UNREACHABLE=1 DLA_PY_FAIL=1 DLA_PS_NI=15 run_tick
{ [ "$(ncalls "$NOTIFY_CALLS" 'Dolt em prioridade baixa')" = "1" ] && [ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ]; } && ok "5d independence: both latency probes failing does not stop the nice check" || nope "5d independence: nice check lost when the probes fail: $(cat "$NOTIFY_CALLS")"

nice_scenario indep-lat-clears
for _ in 1 2 3; do DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 DLA_PS_NI=15 run_tick; done
{ [ -f "$TICK_STATE/dolt-latency-alarm.active" ] && [ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ]; } && ok "5d independence: both alarms can be active at once" || nope "5d independence: setup failed (latency active? $([ -f "$TICK_STATE/dolt-latency-alarm.active" ] && echo y || echo n), nice active? $([ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && echo y || echo n))"
for _ in 1 2 3 4 5; do DLA_CONN_COUNT=2 DLA_GC_LATENCY_MS=150 DLA_PS_NI=15 run_tick; done
{ [ ! -f "$TICK_STATE/dolt-latency-alarm.active" ] && [ -f "$TICK_STATE/dolt-latency-alarm.nice-active" ]; } && ok "5d independence: the latency alarm clearing does NOT clear the nice alarm" || nope "5d independence: latency clear touched the nice marker"
{ [ "$(ncalls "$NOTIFY_CALLS" 'Dolt normalizou')" = "1" ] && [ "$(ncalls "$NOTIFY_CALLS" 'Dolt voltou a nice 0')" = "0" ]; } && ok "5d independence: only 'Dolt normalizou' was announced" || nope "5d independence: notify calls: $(cat "$NOTIFY_CALLS")"

nice_scenario indep-nice-clears
for _ in 1 2 3; do DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 DLA_PS_NI=15 run_tick; done
DLA_CONN_COUNT=50 DLA_GC_LATENCY_MS=900 DLA_PS_NI=0 run_tick
{ [ ! -f "$TICK_STATE/dolt-latency-alarm.nice-active" ] && [ -f "$TICK_STATE/dolt-latency-alarm.active" ]; } && ok "5d independence: nice back to 0 clears ONLY the nice alarm — the latency alarm stays" || nope "5d independence: nice clear touched the latency marker"
{ [ "$(ncalls "$NOTIFY_CALLS" 'Dolt voltou a nice 0')" = "1" ] && [ "$(ncalls "$NOTIFY_CALLS" 'Dolt normalizou')" = "0" ]; } && ok "5d independence: only 'Dolt voltou a nice 0' was announced" || nope "5d independence: notify calls: $(cat "$NOTIFY_CALLS")"

# 5d-9. the DOLT_NICE_UNKNOWN_NOTIFY_AFTER knob: honoured when valid, defaulted (3) when not
nice_scenario after2
DLA_NICE_NOTIFY_AFTER=2 DLA_PS_FAIL=1 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "0" ] && ok "5d knob: NOTIFY_AFTER=2 → 1st unreadable tick is silent" || nope "5d knob: notified on tick 1"
DLA_NICE_NOTIFY_AFTER=2 DLA_PS_FAIL=1 run_tick
[ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "1" ] && ok "5d knob: NOTIFY_AFTER=2 → notifies on the 2nd" || nope "5d knob: no notify on tick 2"
for _bad in abc 0; do
  nice_scenario "bad-$_bad"
  DLA_NICE_NOTIFY_AFTER="$_bad" DLA_PS_FAIL=1 run_tick; DLA_NICE_NOTIFY_AFTER="$_bad" DLA_PS_FAIL=1 run_tick
  _b2="$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')"
  DLA_NICE_NOTIFY_AFTER="$_bad" DLA_PS_FAIL=1 run_tick
  { [ "$_b2" = "0" ] && [ "$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')" = "1" ]; } && ok "5d knob: NOTIFY_AFTER='$_bad' (invalid) → falls back to 3, and still notifies (the blind alert cannot be silenced by a bad value)" || nope "5d knob: NOTIFY_AFTER='$_bad': after 2 ticks=$_b2 notifies, after 3=$(ncalls "$NOTIFY_CALLS" 'nao consegui ler o nice')"
done

echo
echo "==== $PASS passed, $FAIL failed ===="
[ "$FAIL" -eq 0 ]

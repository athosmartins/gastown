#!/usr/bin/env bash
# reconciler-stall-detector.selftest.sh — ga-srp8hk
#
# Hermetic: builds a fake trace tree under a scratch dir, stubs `launchctl`
# (supervisor liveness), `notify` and `gc` (so a "STALLED" scenario can be
# exercised WITHOUT ever sending a real mail or push -- these fakes just
# record that they were called), and points RSD_BD_LIST_CACHED at a fake
# too. Never touches the real .gc/runtime/session-reconciler-trace, the
# real com.gascity.supervisor, or sends a real alert. Time is frozen via
# RSD_NOW_EPOCH so age-based state transitions are deterministic.
#
# Uso: bash reconciler-stall-detector.selftest.sh
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  ok  $*"; PASS=$((PASS+1)); }
bad() { echo "  BAD $*"; FAIL=$((FAIL+1)); }

SRC="$(cd "$(dirname "$0")" && pwd)/reconciler-stall-detector.sh"
if [ ! -f "$SRC" ]; then
  echo "FATAL: reconciler-stall-detector.sh not found next to this selftest"
  exit 1
fi

SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT

FAKE_BIN="$SCRATCH_ROOT/fakebin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/launchctl" <<'FAKE'
#!/usr/bin/env bash
if [ "${1:-}" = "print" ]; then
  if [ "${FAKE_SUPERVISOR_ALIVE:-1}" = "1" ]; then
    printf '\tpid = 4242\n'
    printf '\truns = 1\n'
    exit 0
  fi
  exit 1
fi
exit 1
FAKE
chmod +x "$FAKE_BIN/launchctl"

# Records each call (one line per invocation) instead of doing anything —
# this is both the safety net (no real mail/push ever sent by this
# selftest) and the assertion surface ("was the alert path reached").
cat > "$FAKE_BIN/notify" <<'FAKE'
#!/usr/bin/env bash
echo "notify $*" >> "$FAKE_CALL_LOG"
exit 0
FAKE
chmod +x "$FAKE_BIN/notify"

cat > "$FAKE_BIN/gc" <<'FAKE'
#!/usr/bin/env bash
echo "gc $*" >> "$FAKE_CALL_LOG"
if [ "${FAKE_GC_MAIL_FAILS:-0}" = "1" ] && [ "${1:-}" = "mail" ]; then
  exit 1
fi
exit 0
FAKE
chmod +x "$FAKE_BIN/gc"

FAKE_BD_LIST_CACHED="$SCRATCH_ROOT/fake-bd-list-cached.sh"
cat > "$FAKE_BD_LIST_CACHED" <<'FAKE'
#!/usr/bin/env bash
echo "bd-list-cached $*" >> "$FAKE_CALL_LOG"
echo '[]'
FAKE
chmod +x "$FAKE_BD_LIST_CACHED"

# epoch_to_iso <epoch> -> ISO8601 UTC with Z suffix, matching the real
# trace's `ts` field shape.
epoch_to_iso() {
  python3 -c "
import datetime, sys
print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.%fZ'))
" "$1"
}

# mk_segment <city> <epoch_of_last_record> [extra_line_before]
# Writes one segment file with a single (or two, if extra_line_before is
# given) JSON record(s), the last one timestamped at <epoch_of_last_record>,
# under <city>/.gc/runtime/session-reconciler-trace/segments/... — matching
# exactly what run_detector's SESSION_RECONCILER_TRACE_ROOT points at.
mk_segment() {
  local city="$1" epoch="$2" extra="${3:-}" dir ts
  ts="$(epoch_to_iso "$epoch")"
  dir="$city/.gc/runtime/session-reconciler-trace/segments/2026/09/19"
  mkdir -p "$dir"
  : > "$dir/segment-000001.jsonl"
  if [ -n "$extra" ]; then
    printf '%s\n' "$extra" >> "$dir/segment-000001.jsonl"
  fi
  printf '{"trace_schema_version":1,"seq":1,"record_type":"batch_commit","ts":"%s"}\n' "$ts" >> "$dir/segment-000001.jsonl"
}

# run_detector <city> <now_epoch> [extra env assignments...]
#
# ISOLATION GOTCHA (env-fallback-chain-ambient-leak-breaks-test-isolation):
# a live Gas Town agent shell already exports GC_BIN=/opt/homebrew/bin/gc
# (absolute path, not the bare word "gc") as part of the standard agent
# environment. The script's own `GC_BIN="${GC_BIN:-gc}"` fallback never
# reaches its "gc" default when GC_BIN is already non-empty in the ambient
# environment — it would exec the REAL gc binary against a fake
# GC_CITY_PATH instead of the fake one on $FAKE_BIN's PATH. Hit this live
# while writing this selftest: a bare repro (no PATH override at all)
# actually reached the real Mayor. Pin GC_BIN to the bare word "gc" so PATH
# resolution (with $FAKE_BIN first) is what decides, exactly as the memory
# prescribes: override the MOST SPECIFIC var the chain reads, in the same
# invocation, rather than trusting PATH prepending alone.
run_detector() {
  local city="$1" now_ep="$2"; shift 2
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$city" GC_BIN=gc NOTIFY_BIN=notify \
      SESSION_RECONCILER_TRACE_ROOT="$city/.gc/runtime/session-reconciler-trace" \
      GC_SUPERVISOR_LOG="$city/fake-supervisor.log" \
      RSD_BD_LIST_CACHED="$FAKE_BD_LIST_CACHED" \
      RSD_NOW_EPOCH="$now_ep" \
      FAKE_CALL_LOG="$SCRATCH_ROOT/calls.log" \
      TMPDIR="$SCRATCH_ROOT/tmp" \
      RSD_ALERT_COOLDOWN_SEC=900 \
      "$@" bash "$SRC"
}

mkdir -p "$SCRATCH_ROOT/tmp"
NOW=1789780000   # arbitrary fixed epoch, reproducible across runs

echo "== ga-srp8hk AC1: three synthetic states =="

# A. Last lap 6 min ago, supervisor alive -> STALLED, and it alerts.
CITY_A="$SCRATCH_ROOT/city-a"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_A" "$(( NOW - 360 ))"
OUT_A="$(run_detector "$CITY_A" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_A" | grep -q '^reconciler-stall-detector: STALLED' && ok "A: last lap 6min ago -> STALLED" || bad "A: expected STALLED, got: $OUT_A"
echo "$OUT_A" | grep -q 'age_sec=360' && ok "A: age_sec=360 reported exactly" || bad "A: age mismatch: $OUT_A"
grep -q '^notify ' "$SCRATCH_ROOT/calls.log" && ok "A: notify was called" || bad "A: notify not called"
grep -q '^gc mail send' "$SCRATCH_ROOT/calls.log" && ok "A: gc mail send was called" || bad "A: gc mail send not called"
[ -f "$CITY_A/.gc/state/reconciler-stall-detector-last-alert" ] && ok "A: cooldown file written after alert" || bad "A: cooldown file missing"

# B. Last lap 1 min ago, supervisor alive -> OK, no alert.
CITY_B="$SCRATCH_ROOT/city-b"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_B" "$(( NOW - 60 ))"
OUT_B="$(run_detector "$CITY_B" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_B" | grep -q '^reconciler-stall-detector: OK' && ok "B: last lap 1min ago -> OK" || bad "B: expected OK, got: $OUT_B"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "B: no notify/mail/bd-list call on OK" || bad "B: unexpected call(s) on OK path: $(cat "$SCRATCH_ROOT/calls.log")"

# C. Segments dir entirely absent -> UNKNOWN, no alert.
CITY_C="$SCRATCH_ROOT/city-c"
: > "$SCRATCH_ROOT/calls.log"
mkdir -p "$CITY_C"
OUT_C="$(run_detector "$CITY_C" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_C" | grep -q '^reconciler-stall-detector: UNKNOWN' && ok "C: missing segments dir -> UNKNOWN" || bad "C: expected UNKNOWN, got: $OUT_C"
echo "$OUT_C" | grep -q 'no_segments_dir' && ok "C: reason names no_segments_dir" || bad "C: reason missing: $OUT_C"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "C: no alert on UNKNOWN" || bad "C: unexpected alert on UNKNOWN: $(cat "$SCRATCH_ROOT/calls.log")"

# D. Segment file present but every line corrupted -> UNKNOWN, no alert.
CITY_D="$SCRATCH_ROOT/city-d"
: > "$SCRATCH_ROOT/calls.log"
DIR_D="$CITY_D/.gc/runtime/session-reconciler-trace/segments/2026/09/19"
mkdir -p "$DIR_D"
printf 'not json at all\n{"also": "not valid"\nstill garbage\n' > "$DIR_D/segment-000001.jsonl"
OUT_D="$(run_detector "$CITY_D" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_D" | grep -q '^reconciler-stall-detector: UNKNOWN' && ok "D: corrupted segment content -> UNKNOWN" || bad "D: expected UNKNOWN, got: $OUT_D"
echo "$OUT_D" | grep -q 'unparseable_tail' && ok "D: reason names unparseable_tail" || bad "D: reason missing: $OUT_D"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "D: no alert on corrupted trace" || bad "D: unexpected alert: $(cat "$SCRATCH_ROOT/calls.log")"

echo "== ga-srp8hk: 'supervisor sem processo' is its own UNKNOWN cause, and is NEVER duplicated as an alert (ga-b0gltl's job) =="

# E. Supervisor not running, even with a trace that LOOKS perfectly fresh
#    -> UNKNOWN must win over a fresh-looking trace, and must not page.
CITY_E="$SCRATCH_ROOT/city-e"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_E" "$(( NOW - 5 ))"
OUT_E="$(run_detector "$CITY_E" "$NOW" env FAKE_SUPERVISOR_ALIVE=0)"
echo "$OUT_E" | grep -q '^reconciler-stall-detector: UNKNOWN' && ok "E: supervisor not running -> UNKNOWN even with a fresh trace" || bad "E: expected UNKNOWN, got: $OUT_E"
echo "$OUT_E" | grep -q 'supervisor_not_running' && ok "E: reason names supervisor_not_running" || bad "E: reason missing: $OUT_E"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "E: no alert sent (ga-b0gltl's job, not duplicated here)" || bad "E: unexpected alert: $(cat "$SCRATCH_ROOT/calls.log")"

echo "== ga-srp8hk: partial trailing write tolerance =="

# H. Last line in the segment is a truncated/garbage partial write, but the
#    second-to-last line is a valid, recent record -> must resolve on that
#    line, not collapse to UNKNOWN.
CITY_H="$SCRATCH_ROOT/city-h"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_H" "$(( NOW - 30 ))"
DIR_H="$CITY_H/.gc/runtime/session-reconciler-trace/segments/2026/09/19"
printf '{"seq":2,"record_type":"cycle_start","ts":"2026-09-19T99:99:99.999999Z' >> "$DIR_H/segment-000001.jsonl"
OUT_H="$(run_detector "$CITY_H" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_H" | grep -q '^reconciler-stall-detector: OK' && ok "H: valid line behind a truncated trailing write -> resolves OK, not UNKNOWN" || bad "H: expected OK, got: $OUT_H"

echo "== ga-srp8hk: alert cooldown suppresses duplicate pages, and clears on recovery =="

# F. Two STALLED runs back-to-back (same simulated moment) -> exactly ONE
#    alert; the second is suppressed by the cooldown just written by the
#    first.
CITY_F="$SCRATCH_ROOT/city-f"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_F" "$(( NOW - 360 ))"
run_detector "$CITY_F" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null
OUT_F2="$(run_detector "$CITY_F" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
NOTIFY_CALLS_F="$(grep -c '^notify ' "$SCRATCH_ROOT/calls.log" || true)"
[ "$NOTIFY_CALLS_F" = "1" ] && ok "F: second STALLED tick within cooldown -> still exactly 1 notify call total" || bad "F: expected 1 notify call, got $NOTIFY_CALLS_F"
echo "$OUT_F2" | grep -q 'cooldown' && ok "F: second run's own output names the cooldown suppression" || bad "F: $OUT_F2"

# G. Recovery (OK) clears the cooldown, so a FRESH stall right after alerts
#    again immediately rather than waiting out the window.
CITY_G="$SCRATCH_ROOT/city-g"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_G" "$(( NOW - 360 ))"
run_detector "$CITY_G" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null   # 1st STALLED -> alerts, writes cooldown
mk_segment "$CITY_G" "$NOW"                                            # recovers
run_detector "$CITY_G" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null   # OK -> clears cooldown
mk_segment "$CITY_G" "$(( NOW - 360 ))"                                 # stalls again, moments later
OUT_G3="$(run_detector "$CITY_G" "$(( NOW + 30 ))" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_G3" | grep -q '^reconciler-stall-detector: STALLED' && ok "G: fresh stall right after a recovery alerts again (cooldown was cleared on OK)" || bad "G: $OUT_G3"
NOTIFY_CALLS_G="$(grep -c '^notify ' "$SCRATCH_ROOT/calls.log" || true)"
[ "$NOTIFY_CALLS_G" = "2" ] && ok "G: two distinct episodes -> two notify calls total" || bad "G: expected 2 notify calls across both episodes, got $NOTIFY_CALLS_G"

echo "== ga-srp8hk: mail fallback to concrete session name on alias failure =="

# Mail-alias-trailing-slash memory: the bare-alias form can fail under real
# Dolt flakiness (exactly the condition this alert fires under). On
# failure, retry once against the concrete session name rather than giving
# up or hammering the same form.
CITY_MF="$SCRATCH_ROOT/city-mf"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_MF" "$(( NOW - 360 ))"
run_detector "$CITY_MF" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 FAKE_GC_MAIL_FAILS=1 >/dev/null
MAIL_ATTEMPTS="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_ATTEMPTS" = "2" ] && ok "mail-fallback: alias failure triggers exactly one retry against the concrete name (2 attempts total)" \
  || bad "mail-fallback: expected 2 mail attempts, got $MAIL_ATTEMPTS: $(cat "$SCRATCH_ROOT/calls.log")"
grep -q '^gc mail send gastown.mayor' "$SCRATCH_ROOT/calls.log" && ok "mail-fallback: retry used the concrete session name" || bad "mail-fallback: no retry with concrete name found"
grep -q '^notify ' "$SCRATCH_ROOT/calls.log" && ok "mail-fallback: notify still fires independent of mail's outcome" || bad "mail-fallback: notify missing"

echo "== ga-srp8hk (ga-y0g5x pattern): single-instance lock under real concurrency =="

# I. Two truly concurrent invocations -> exactly one alert (one notify
#    call), the loser reports it backed off rather than silently no-op'ing.
CITY_I="$SCRATCH_ROOT/city-i"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_I" "$(( NOW - 360 ))"
OUT_I1="$SCRATCH_ROOT/i1.out"; OUT_I2="$SCRATCH_ROOT/i2.out"
(
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_I" GC_BIN=gc NOTIFY_BIN=notify \
      SESSION_RECONCILER_TRACE_ROOT="$CITY_I/.gc/runtime/session-reconciler-trace" \
      GC_SUPERVISOR_LOG="$CITY_I/fake-supervisor.log" RSD_BD_LIST_CACHED="$FAKE_BD_LIST_CACHED" \
      RSD_NOW_EPOCH="$NOW" FAKE_CALL_LOG="$SCRATCH_ROOT/calls.log" TMPDIR="$SCRATCH_ROOT/tmp" \
      RSD_ALERT_COOLDOWN_SEC=900 FAKE_SUPERVISOR_ALIVE=1 \
      bash "$SRC" >"$OUT_I1" 2>&1 &
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_I" GC_BIN=gc NOTIFY_BIN=notify \
      SESSION_RECONCILER_TRACE_ROOT="$CITY_I/.gc/runtime/session-reconciler-trace" \
      GC_SUPERVISOR_LOG="$CITY_I/fake-supervisor.log" RSD_BD_LIST_CACHED="$FAKE_BD_LIST_CACHED" \
      RSD_NOW_EPOCH="$NOW" FAKE_CALL_LOG="$SCRATCH_ROOT/calls.log" TMPDIR="$SCRATCH_ROOT/tmp" \
      RSD_ALERT_COOLDOWN_SEC=900 FAKE_SUPERVISOR_ALIVE=1 \
      bash "$SRC" >"$OUT_I2" 2>&1 &
  wait
)
NOTIFY_CALLS_I="$(grep -c '^notify ' "$SCRATCH_ROOT/calls.log" || true)"
[ "$NOTIFY_CALLS_I" = "1" ] && ok "I: two concurrent STALLED runs -> exactly 1 notify call (no duplicate paging)" \
  || bad "I: expected 1 notify call under concurrency, got $NOTIFY_CALLS_I"
if grep -q "holds the lock" "$OUT_I1" "$OUT_I2" 2>/dev/null; then
  ok "I: the losing invocation names the lock explicitly (not a silent no-op)"
else
  bad "I: neither concurrent invocation reported backing off — lock may not be contending at all"
fi
[ -d "$SCRATCH_ROOT/tmp/reconciler-stall-detector.lock.d" ] \
  && bad "I: lock dir still present after both runs completed — release/trap did not fire" \
  || ok "I: lock dir released after completion (EXIT trap fired)"

echo "== ga-srp8hk: detection-only — static guard against scope creep into repair actions =="

# J. Grep, not a live check — there is no safe way to dynamically prove
#    "never restarts the real supervisor" without risking doing so.
if grep -qE 'launchctl[[:space:]]+(kickstart|bootout|unload|stop|kill)|pkill|kill[[:space:]]+-(9|QUIT|TERM)' "$SRC"; then
  bad "J: found a mutating launchctl/kill invocation in the script — violates detection-only scope"
else
  ok "J: no mutating launchctl/kill/pkill invocation found (detection-only, as scoped)"
fi

echo "== ga-srp8hk AC3: execution duration vs. the chosen launchd StartInterval =="

# K. Time a full STALLED run (real diagnostic gathering against the fake
#    bd-list-cached/log/sysctl -- only the actual SEND calls are faked) and
#    assert it stays comfortably under the plist's StartInterval, so this
#    guard can never become the load it observes.
CITY_K="$SCRATCH_ROOT/city-k"
mk_segment "$CITY_K" "$(( NOW - 360 ))"
T0=$(date +%s%N 2>/dev/null || echo 0)
run_detector "$CITY_K" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null
T1=$(date +%s%N 2>/dev/null || echo 0)
if [ "$T0" != "0" ] && [ "$T1" != "0" ]; then
  DURATION_MS=$(( (T1 - T0) / 1000000 ))
  echo "  measured STALLED-path duration: ${DURATION_MS}ms"
  PLIST="$(cd "$(dirname "$0")" && pwd)/reconciler-stall-detector.plist"
  START_INTERVAL=$(grep -A1 'StartInterval' "$PLIST" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  if [ -n "$START_INTERVAL" ]; then
    START_INTERVAL_MS=$(( START_INTERVAL * 1000 ))
    # 10x headroom, not just >, to absorb real-world variance (Dolt under
    # load, disk contention) beyond this quiet sandbox measurement.
    THRESHOLD_MS=$(( START_INTERVAL_MS / 10 ))
    [ "$DURATION_MS" -lt "$THRESHOLD_MS" ] \
      && ok "K: duration ${DURATION_MS}ms is well under StartInterval=${START_INTERVAL}s (10x headroom: ${THRESHOLD_MS}ms)" \
      || bad "K: duration ${DURATION_MS}ms is NOT comfortably under StartInterval=${START_INTERVAL}s -- reconsider the cadence"
  else
    bad "K: could not read StartInterval from $PLIST"
  fi
else
  echo "  (nanosecond date unavailable, skipping precise timing assertion)"
fi

echo
echo "reconciler-stall-detector selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

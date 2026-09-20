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

# A. REGRESSION LOCK (ga-srp8hk reopen): last lap 6min ago (360s) used to be
#    STALLED under the old 300s threshold -- this is exactly the "every
#    degraded-but-alive tick pages" bug that made this alert fire all night.
#    Under the new 900s threshold it must read OK, mail-only-eligible or
#    not, no calls at all.
CITY_A="$SCRATCH_ROOT/city-a"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_A" "$(( NOW - 360 ))"
OUT_A="$(run_detector "$CITY_A" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_A" | grep '^reconciler-stall-detector: OK' >/dev/null && ok "A: last lap 6min ago (360s) -> OK under the new 900s threshold (was the night-long-pages bug)" || bad "A: expected OK, got: $OUT_A"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "A: no notify/mail call on a merely-slow-but-alive tick" || bad "A: unexpected call(s): $(cat "$SCRATCH_ROOT/calls.log")"

# A2. Genuinely stalled: last lap 16min ago (960s, past the 900s threshold)
#     -> STALLED, and it alerts (mail; notify withheld -- see the L section
#     below for the escalation-bar tests, 960s is under the 1800s bar).
CITY_A2="$SCRATCH_ROOT/city-a2"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_A2" "$(( NOW - 960 ))"
OUT_A2="$(run_detector "$CITY_A2" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_A2" | grep '^reconciler-stall-detector: STALLED' >/dev/null && ok "A2: last lap 16min ago (960s) -> STALLED" || bad "A2: expected STALLED, got: $OUT_A2"
echo "$OUT_A2" | grep 'age_sec=960' >/dev/null && ok "A2: age_sec=960 reported exactly" || bad "A2: age mismatch: $OUT_A2"
grep -q '^gc mail send' "$SCRATCH_ROOT/calls.log" && ok "A2: gc mail send was called" || bad "A2: gc mail send not called"
[ -f "$CITY_A2/.gc/state/reconciler-stall-detector-last-alert" ] && ok "A2: cooldown file written after alert" || bad "A2: cooldown file missing"

# B. Last lap 1 min ago, supervisor alive -> OK, no alert.
CITY_B="$SCRATCH_ROOT/city-b"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_B" "$(( NOW - 60 ))"
OUT_B="$(run_detector "$CITY_B" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_B" | grep '^reconciler-stall-detector: OK' >/dev/null && ok "B: last lap 1min ago -> OK" || bad "B: expected OK, got: $OUT_B"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "B: no notify/mail/bd-list call on OK" || bad "B: unexpected call(s) on OK path: $(cat "$SCRATCH_ROOT/calls.log")"

# C. Segments dir entirely absent -> UNKNOWN, no alert.
CITY_C="$SCRATCH_ROOT/city-c"
: > "$SCRATCH_ROOT/calls.log"
mkdir -p "$CITY_C"
OUT_C="$(run_detector "$CITY_C" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_C" | grep '^reconciler-stall-detector: UNKNOWN' >/dev/null && ok "C: missing segments dir -> UNKNOWN" || bad "C: expected UNKNOWN, got: $OUT_C"
echo "$OUT_C" | grep 'no_segments_dir' >/dev/null && ok "C: reason names no_segments_dir" || bad "C: reason missing: $OUT_C"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "C: no alert on UNKNOWN" || bad "C: unexpected alert on UNKNOWN: $(cat "$SCRATCH_ROOT/calls.log")"

# D. Segment file present but every line corrupted -> UNKNOWN, no alert.
CITY_D="$SCRATCH_ROOT/city-d"
: > "$SCRATCH_ROOT/calls.log"
DIR_D="$CITY_D/.gc/runtime/session-reconciler-trace/segments/2026/09/19"
mkdir -p "$DIR_D"
printf 'not json at all\n{"also": "not valid"\nstill garbage\n' > "$DIR_D/segment-000001.jsonl"
OUT_D="$(run_detector "$CITY_D" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_D" | grep '^reconciler-stall-detector: UNKNOWN' >/dev/null && ok "D: corrupted segment content -> UNKNOWN" || bad "D: expected UNKNOWN, got: $OUT_D"
echo "$OUT_D" | grep 'unparseable_tail' >/dev/null && ok "D: reason names unparseable_tail" || bad "D: reason missing: $OUT_D"
[ ! -s "$SCRATCH_ROOT/calls.log" ] && ok "D: no alert on corrupted trace" || bad "D: unexpected alert: $(cat "$SCRATCH_ROOT/calls.log")"

echo "== ga-srp8hk: 'supervisor sem processo' is its own UNKNOWN cause, and is NEVER duplicated as an alert (ga-b0gltl's job) =="

# E. Supervisor not running, even with a trace that LOOKS perfectly fresh
#    -> UNKNOWN must win over a fresh-looking trace, and must not page.
CITY_E="$SCRATCH_ROOT/city-e"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_E" "$(( NOW - 5 ))"
OUT_E="$(run_detector "$CITY_E" "$NOW" env FAKE_SUPERVISOR_ALIVE=0)"
echo "$OUT_E" | grep '^reconciler-stall-detector: UNKNOWN' >/dev/null && ok "E: supervisor not running -> UNKNOWN even with a fresh trace" || bad "E: expected UNKNOWN, got: $OUT_E"
echo "$OUT_E" | grep 'supervisor_not_running' >/dev/null && ok "E: reason names supervisor_not_running" || bad "E: reason missing: $OUT_E"
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
echo "$OUT_H" | grep '^reconciler-stall-detector: OK' >/dev/null && ok "H: valid line behind a truncated trailing write -> resolves OK, not UNKNOWN" || bad "H: expected OK, got: $OUT_H"

echo "== ga-srp8hk: alert cooldown suppresses duplicate pages, and clears on recovery =="

# F. Two STALLED runs back-to-back (same simulated moment) -> exactly ONE
#    alert; the second is suppressed by the cooldown just written by the
#    first. Uses age=960s (past the new 900s threshold).
CITY_F="$SCRATCH_ROOT/city-f"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_F" "$(( NOW - 960 ))"
run_detector "$CITY_F" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null
OUT_F2="$(run_detector "$CITY_F" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
MAIL_CALLS_F="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_CALLS_F" = "1" ] && ok "F: second STALLED tick within cooldown -> still exactly 1 mail send total" || bad "F: expected 1 mail send, got $MAIL_CALLS_F"
echo "$OUT_F2" | grep 'cooldown' >/dev/null && ok "F: second run's own output names the cooldown suppression" || bad "F: $OUT_F2"

echo "== ga-srp8hk reopen: hysteresis -- a LONE healthy tick must not re-arm immediate paging =="

# G1. REGRESSION LOCK for the exact night-long-pages bug: 1st STALLED tick
#     alerts and writes the cooldown; ONE recovery tick (OK) lands, but that
#     alone is below RSD_REQUIRED_OK_STREAK (default 3) -- the cooldown must
#     be LEFT STANDING; a fresh stall moments later must stay SUPPRESSED
#     (still within the original cooldown window), not re-alert. This is the
#     precise behavior that was missing and caused a page every ~6-7min.
CITY_G1="$SCRATCH_ROOT/city-g1"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_G1" "$(( NOW - 960 ))"
run_detector "$CITY_G1" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null    # 1st STALLED -> alerts, writes cooldown
mk_segment "$CITY_G1" "$NOW"                                             # one healthy tick lands
OUT_G1_OK="$(run_detector "$CITY_G1" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)" # OK, streak=1 (< 3) -> cooldown left standing
echo "$OUT_G1_OK" | grep 'ok_streak=1/3' >/dev/null && ok "G1: single OK reports streak 1/3, cooldown left standing" || bad "G1: $OUT_G1_OK"
[ -f "$CITY_G1/.gc/state/reconciler-stall-detector-last-alert" ] && ok "G1: cooldown file still present after only 1 OK" || bad "G1: cooldown file was cleared after just 1 OK -- hysteresis not applied"
mk_segment "$CITY_G1" "$(( NOW - 960 ))"                                  # stalls again, moments later
OUT_G1_RESTALL="$(run_detector "$CITY_G1" "$(( NOW + 30 ))" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_G1_RESTALL" | grep 'cooldown' >/dev/null && ok "G1: fresh stall right after a single OK stays SUPPRESSED by the original cooldown (the exact bug this fix closes)" || bad "G1: $OUT_G1_RESTALL"
MAIL_CALLS_G1="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_CALLS_G1" = "1" ] && ok "G1: still exactly 1 mail send total across the whole sequence (1 alert, not 2)" || bad "G1: expected 1 mail send, got $MAIL_CALLS_G1"

# G2. Sustained recovery (RSD_REQUIRED_OK_STREAK consecutive OK ticks) DOES
#     end the episode early: a fresh stall right after alerts again
#     immediately, even though the original cooldown window has not
#     naturally elapsed yet.
CITY_G2="$SCRATCH_ROOT/city-g2"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_G2" "$(( NOW - 960 ))"
run_detector "$CITY_G2" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null     # 1st STALLED -> alerts, writes cooldown
for i in 1 2 3; do
  mk_segment "$CITY_G2" "$(( NOW + i ))"
  run_detector "$CITY_G2" "$(( NOW + i ))" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null
done
OK_STREAK_FILE_G2="$CITY_G2/.gc/state/reconciler-stall-detector-ok-streak"
[ -f "$OK_STREAK_FILE_G2" ] && [ "$(cat "$OK_STREAK_FILE_G2")" = "3" ] && ok "G2: streak file reads 3 after 3 consecutive OK ticks" || bad "G2: streak file: $(cat "$OK_STREAK_FILE_G2" 2>/dev/null || echo MISSING)"
[ ! -f "$CITY_G2/.gc/state/reconciler-stall-detector-last-alert" ] && ok "G2: cooldown cleared after 3 consecutive OK ticks (sustained recovery)" || bad "G2: cooldown still present after sustained recovery"
mk_segment "$CITY_G2" "$(( NOW - 960 ))"                                   # stalls again, moments later
OUT_G2_RESTALL="$(run_detector "$CITY_G2" "$(( NOW + 4 ))" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_G2_RESTALL" | grep '^reconciler-stall-detector: STALLED' >/dev/null && ok "G2: fresh stall right after SUSTAINED recovery alerts again immediately" || bad "G2: $OUT_G2_RESTALL"
MAIL_CALLS_G2="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_CALLS_G2" = "2" ] && ok "G2: two distinct episodes (separated by a genuinely sustained recovery) -> 2 mail sends total" || bad "G2: expected 2 mail sends, got $MAIL_CALLS_G2"

# G3. Any single STALLED reading resets the streak back to 0 -- OK, OK,
#     STALLED, OK must NOT be one tick away from clearing (it must take 3
#     FRESH consecutive OKs after the STALLED, not 2 old + 1 new).
CITY_G3="$SCRATCH_ROOT/city-g3"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_G3" "$(( NOW - 960 ))"
run_detector "$CITY_G3" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null      # STALLED -> alerts
mk_segment "$CITY_G3" "$(( NOW + 1 ))"; run_detector "$CITY_G3" "$(( NOW + 1 ))" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null   # OK streak=1
mk_segment "$CITY_G3" "$(( NOW + 2 ))"; run_detector "$CITY_G3" "$(( NOW + 2 ))" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null   # OK streak=2
mk_segment "$CITY_G3" "$(( NOW - 960 ))"; run_detector "$CITY_G3" "$(( NOW + 3 ))" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null # STALLED again (within cooldown, suppressed) -> streak reset to 0
OK_STREAK_FILE_G3="$CITY_G3/.gc/state/reconciler-stall-detector-ok-streak"
[ -f "$OK_STREAK_FILE_G3" ] && [ "$(cat "$OK_STREAK_FILE_G3")" = "0" ] && ok "G3: a STALLED reading resets the OK streak to 0, discarding the prior 2" || bad "G3: streak file: $(cat "$OK_STREAK_FILE_G3" 2>/dev/null || echo MISSING)"

echo "== ga-srp8hk: mail fallback to concrete session name on alias failure =="

# Mail-alias-trailing-slash memory: the bare-alias form can fail under real
# Dolt flakiness (exactly the condition this alert fires under). On
# failure, retry once against the concrete session name rather than giving
# up or hammering the same form. Age is set past the 1800s escalation bar
# so notify's independence from mail's outcome stays meaningfully tested
# alongside the fallback.
CITY_MF="$SCRATCH_ROOT/city-mf"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_MF" "$(( NOW - 1860 ))"
run_detector "$CITY_MF" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 FAKE_GC_MAIL_FAILS=1 >/dev/null
MAIL_ATTEMPTS="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_ATTEMPTS" = "2" ] && ok "mail-fallback: alias failure triggers exactly one retry against the concrete name (2 attempts total)" \
  || bad "mail-fallback: expected 2 mail attempts, got $MAIL_ATTEMPTS: $(cat "$SCRATCH_ROOT/calls.log")"
grep -q '^gc mail send gastown.mayor' "$SCRATCH_ROOT/calls.log" && ok "mail-fallback: retry used the concrete session name" || bad "mail-fallback: no retry with concrete name found"
grep -q '^notify ' "$SCRATCH_ROOT/calls.log" && ok "mail-fallback: notify (escalated, age past 1800s bar) still fires independent of mail's outcome" || bad "mail-fallback: notify missing"

echo "== ga-srp8hk (ga-y0g5x pattern): single-instance lock under real concurrency =="

# I. Two truly concurrent invocations -> exactly one alert (one mail send),
#    the loser reports it backed off rather than silently no-op'ing. Age
#    only needs to be past the 900s STALLED threshold -- lock contention is
#    orthogonal to the notify escalation bar, so mail send count (which
#    always fires once STALLED+cooldown allow it) is the assertion surface.
CITY_I="$SCRATCH_ROOT/city-i"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_I" "$(( NOW - 960 ))"
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
MAIL_CALLS_I="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_CALLS_I" = "1" ] && ok "I: two concurrent STALLED runs -> exactly 1 mail send (no duplicate paging)" \
  || bad "I: expected 1 mail send under concurrency, got $MAIL_CALLS_I"
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
#    guard can never become the load it observes. Includes the new
#    episode-window i/o-timeout filter (a python3 subprocess over up to
#    RSD_SUPERVISOR_LOG_TAIL_BYTES of tail) in the timed path.
CITY_K="$SCRATCH_ROOT/city-k"
mk_segment "$CITY_K" "$(( NOW - 960 ))"
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

echo "== ga-srp8hk reopen: notify (Athos's phone) is a SEPARATE, higher bar than mail (Mayor) =="

# L1. Just past the STALLED threshold (960s) but well under the 1800s
#     escalation bar -> mail fires, notify does NOT.
CITY_L1="$SCRATCH_ROOT/city-l1"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_L1" "$(( NOW - 960 ))"
OUT_L1="$(run_detector "$CITY_L1" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_L1" | grep 'escalated_to_notify=0' >/dev/null && ok "L1: 960s stall reports escalated_to_notify=0" || bad "L1: $OUT_L1"
grep -q '^gc mail send' "$SCRATCH_ROOT/calls.log" && ok "L1: mail fires at 960s (past the 900s STALLED bar)" || bad "L1: mail did not fire"
grep -q '^notify ' "$SCRATCH_ROOT/calls.log" && bad "L1: notify fired at 960s -- should be withheld under the 1800s escalation bar" || ok "L1: notify correctly withheld -- Mayor-only, Athos's phone not paged"

# L2. Past the 1800s escalation bar -> BOTH mail and notify fire.
CITY_L2="$SCRATCH_ROOT/city-l2"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_L2" "$(( NOW - 1860 ))"
OUT_L2="$(run_detector "$CITY_L2" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_L2" | grep 'escalated_to_notify=1' >/dev/null && ok "L2: 1860s stall reports escalated_to_notify=1" || bad "L2: $OUT_L2"
grep -q '^gc mail send' "$SCRATCH_ROOT/calls.log" && ok "L2: mail fires at 1860s" || bad "L2: mail did not fire"
grep -q '^notify ' "$SCRATCH_ROOT/calls.log" && ok "L2: notify ALSO fires past the 1800s escalation bar -- Athos's phone paged" || bad "L2: notify did not fire"

# L3. Exact boundary: age_sec == RSD_NOTIFY_ESCALATION_SEC (1800) escalates
#     (>=, not >) -- a stall landing EXACTLY on the bar still reaches Athos
#     rather than needing one more tick past it.
CITY_L3="$SCRATCH_ROOT/city-l3"
: > "$SCRATCH_ROOT/calls.log"
mk_segment "$CITY_L3" "$(( NOW - 1800 ))"
OUT_L3="$(run_detector "$CITY_L3" "$NOW" env FAKE_SUPERVISOR_ALIVE=1)"
echo "$OUT_L3" | grep 'escalated_to_notify=1' >/dev/null && ok "L3: age_sec exactly 1800 escalates (boundary is >=, not >)" || bad "L3: $OUT_L3"

echo "== ga-srp8hk reopen: i/o-timeout lines are filtered to the CURRENT episode window =="

# M. A supervisor.log with one line from a much-earlier, unrelated episode
#    and one line from WITHIN the current episode -- the alert body (as
#    captured in the notify/mail call args) must include the current-
#    episode line and must NOT include the stale one. This is the exact
#    "alert at 22:36 showed 21:05-21:25 lines from an already-resolved
#    episode" confusion named in Mayor's reopen comment.
CITY_M="$SCRATCH_ROOT/city-m"
: > "$SCRATCH_ROOT/calls.log"
STALL_AGE_M=960
mk_segment "$CITY_M" "$(( NOW - STALL_AGE_M ))"
# Episode window is [NOW-STALL_AGE_M, NOW]. NEW_TS sits well inside it,
# OLD_TS sits 2h before it starts. date -r reads an epoch and formats in
# THIS HOST's local time, matching how the script's own filter (time.mktime
# on a naive local datetime) will interpret the line back into an epoch.
NEW_TS="$(date -r "$(( NOW - 100 ))" '+%Y/%m/%d %H:%M:%S')"
OLD_TS="$(date -r "$(( NOW - STALL_AGE_M - 7200 ))" '+%Y/%m/%d %H:%M:%S')"
mkdir -p "$CITY_M"
{
  echo "[mysql] $OLD_TS packets.go:58 read tcp 127.0.0.1:OLDMARKER->127.0.0.1:52756: i/o timeout"
  echo "[mysql] $NEW_TS packets.go:58 read tcp 127.0.0.1:NEWMARKER->127.0.0.1:52756: i/o timeout"
} > "$CITY_M/fake-supervisor.log"
run_detector "$CITY_M" "$NOW" env FAKE_SUPERVISOR_ALIVE=1 >/dev/null
grep -q 'NEWMARKER' "$SCRATCH_ROOT/calls.log" && ok "M: current-episode i/o-timeout line IS included in the alert body" || bad "M: NEWMARKER missing from alert body"
grep -q 'OLDMARKER' "$SCRATCH_ROOT/calls.log" && bad "M: stale (2h-earlier, unrelated-episode) i/o-timeout line leaked into the alert body -- exactly the confusion flagged in Mayor's reopen comment" || ok "M: stale i/o-timeout line correctly excluded from the alert body"

echo "== ga-srp8hk: REAL-DATA REPLAY (2026-09-18 incident) =="

# Real tick end-timestamps (UTC epoch seconds), extracted while fixing this
# bead from the ACTUAL production trace at
# .gc/runtime/session-reconciler-trace/segments/2026/09/{18,19}/, covering
# local 20:20-23:44 (this machine's tz, UTC-3) on 2026-09-18 -- exactly the
# window Mayor's bead measured: an 18.8min gap ending local 20:56 (index
# 12), a 12.7min sub-threshold gap ending 21:09 (index 13), a 19.3min gap
# ending 21:31 (index 15), then normal-to-degraded 60s-7min ticks the rest
# of the way including the 6-7min-cadence run after local 22:05 that paged
# Athos all night under the old 300s-threshold, no-hysteresis code.
REPLAY_TICKS_EP=(
  1789773612 1789773721 1789773781 1789773883 1789773944 1789774071 1789774152 1789774246
  1789774413 1789774481 1789774558 1789774656 1789775783 1789776543 1789776712 1789777873
  1789777980 1789778044 1789778159 1789778272 1789778332 1789778396 1789778470 1789778547
  1789778644 1789778710 1789778760 1789778845 1789778921 1789779053 1789779269 1789779437
  1789779546 1789779640 1789779740 1789779821 1789779947 1789780292 1789780702 1789781043
  1789781408 1789782229 1789782248
)
N_TICKS=${#REPLAY_TICKS_EP[@]}

CITY_REPLAY="$SCRATCH_ROOT/city-replay"
: > "$SCRATCH_ROOT/calls.log"
REPLAY_ALERT_LOG="$SCRATCH_ROOT/replay-alerts.log"
: > "$REPLAY_ALERT_LOG"

FIRST_EP=${REPLAY_TICKS_EP[0]}
LAST_EP=${REPLAY_TICKS_EP[$(( N_TICKS - 1 ))]}
LATEST_IDX=0
POLL_EP=$FIRST_EP
# Poll every 120s, matching the real plist's StartInterval, simulating "the
# trace file's latest known tick as of this poll" -- exactly what the real
# launchd job samples.
while [ "$POLL_EP" -le "$LAST_EP" ]; do
  while [ $(( LATEST_IDX + 1 )) -lt "$N_TICKS" ] && [ "${REPLAY_TICKS_EP[$(( LATEST_IDX + 1 ))]}" -le "$POLL_EP" ]; do
    LATEST_IDX=$(( LATEST_IDX + 1 ))
  done
  mk_segment "$CITY_REPLAY" "${REPLAY_TICKS_EP[$LATEST_IDX]}"
  OUT_POLL="$(run_detector "$CITY_REPLAY" "$POLL_EP" env FAKE_SUPERVISOR_ALIVE=1)"
  echo "$OUT_POLL" | grep 'alerted' >/dev/null && echo "poll=$POLL_EP $OUT_POLL" >> "$REPLAY_ALERT_LOG"
  POLL_EP=$(( POLL_EP + 120 ))
done

ALERT_COUNT_REPLAY="$(wc -l < "$REPLAY_ALERT_LOG" | tr -d ' ')"
[ "$ALERT_COUNT_REPLAY" = "2" ] && ok "N: real-data replay -> exactly 2 alert episodes (the two 18-19min gaps; NOT the 12.7min/13.7min sub-threshold gaps or any 6-7min degraded tick)" \
  || bad "N: expected exactly 2 alert episodes, got $ALERT_COUNT_REPLAY: $(cat "$REPLAY_ALERT_LOG")"

# The two alerts must fall within the two windows Mayor's reopen comment
# named: local 20:37-20:56 and 21:11-21:31 (tick[12]->tick[12] and
# tick[15]->tick[15] landing epochs, with a 300s margin for poll alignment).
WINDOW1_END=1789775783
WINDOW2_END=1789777873
BAD_WINDOW_ALERTS=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  poll_ep="$(echo "$line" | sed -n 's/^poll=\([0-9]*\).*/\1/p')"
  in_w1=0; in_w2=0
  { [ "$poll_ep" -le "$WINDOW1_END" ] && [ "$poll_ep" -ge "$(( WINDOW1_END - 300 ))" ]; } && in_w1=1
  { [ "$poll_ep" -le "$WINDOW2_END" ] && [ "$poll_ep" -ge "$(( WINDOW2_END - 300 ))" ]; } && in_w2=1
  [ "$in_w1" = "0" ] && [ "$in_w2" = "0" ] && BAD_WINDOW_ALERTS=$(( BAD_WINDOW_ALERTS + 1 ))
done < "$REPLAY_ALERT_LOG"
[ "$BAD_WINDOW_ALERTS" = "0" ] && ok "N: both alerts fall inside the two expected windows, none elsewhere" || bad "N: $BAD_WINDOW_ALERTS alert(s) fell outside the two expected windows: $(cat "$REPLAY_ALERT_LOG")"

# Neither real episode reached 30min (max was ~19.3min) -> both alerts
# should be mail-only; Athos's phone never paged for this specific
# incident under the new tiering.
NOTIFY_CALLS_REPLAY="$(grep -c '^notify ' "$SCRATCH_ROOT/calls.log" || true)"
[ "$NOTIFY_CALLS_REPLAY" = "0" ] && ok "N: neither real episode (max ~19.3min) crossed the 30min notify bar -- Athos's phone never paged, Mayor mailed both times" || bad "N: expected 0 notify calls, got $NOTIFY_CALLS_REPLAY"
MAIL_CALLS_REPLAY="$(grep -c '^gc mail send' "$SCRATCH_ROOT/calls.log" || true)"
[ "$MAIL_CALLS_REPLAY" = "2" ] && ok "N: exactly 2 mail sends to Mayor across the whole replay" || bad "N: expected 2 mail sends, got $MAIL_CALLS_REPLAY"

echo
echo "reconciler-stall-detector selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

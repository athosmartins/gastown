#!/usr/bin/env bash
# supervisor-restart-watchdog.selftest.sh — ga-b0gltl
#
# The watchdog exists to answer ONE question this city currently cannot
# answer: how many times did com.gascity.supervisor die today, and why. That
# answer comes entirely from a `runs` delta computed across samples — get the
# delta math wrong (fabricate a value across a counter reset, misattribute a
# reason to a restart that didn't happen, double-write under concurrent
# cron overlap) and the ledger becomes a second thing nobody trusts, same as
# the "no source of truth" state this bug was filed against. This selftest
# stubs `launchctl print` for deterministic runs/exit-code fixtures — no real
# supervisor process is ever touched, sampled state lives under a scratch
# GC_CITY_PATH, and the concurrency test uses a scratch TMPDIR so it cannot
# collide with a real production lock at /tmp/supervisor-restart-watchdog.lock.d.
#
# Uso: bash supervisor-restart-watchdog.selftest.sh
set -uo pipefail
PASS=0; FAIL=0
ok()  { echo "  ok  $*"; PASS=$((PASS+1)); }
bad() { echo "  BAD $*"; FAIL=$((FAIL+1)); }

SRC="$(cd "$(dirname "$0")" && pwd)/supervisor-restart-watchdog.sh"
if [ ! -f "$SRC" ]; then
  echo "FATAL: supervisor-restart-watchdog.sh not found next to this selftest"
  exit 1
fi

SCRATCH_ROOT="$(mktemp -d)"
trap 'rm -rf "$SCRATCH_ROOT"' EXIT

FAKE_BIN="$SCRATCH_ROOT/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/launchctl" <<'FAKE'
#!/usr/bin/env bash
# Fake `launchctl print` — deterministic runs/exit-code fixtures for the
# selftest. Never touches a real launchd job.
if [ "${1:-}" = "print" ]; then
  if [ "${FAKE_LAUNCHCTL_EMPTY:-0}" = "1" ]; then
    exit 1
  fi
  if [ "${FAKE_LAUNCHCTL_NO_RUNS_LINE:-0}" != "1" ]; then
    printf '\truns = %s\n' "${FAKE_LAUNCHCTL_RUNS:-1}"
  fi
  if [ "${FAKE_LAUNCHCTL_EXIT_NEVER:-0}" = "1" ]; then
    printf '\tlast exit code = (never exited)\n'
  else
    printf '\tlast exit code = %s\n' "${FAKE_LAUNCHCTL_EXIT:-0}"
  fi
  exit 0
fi
exit 1
FAKE
chmod +x "$FAKE_BIN/launchctl"

# run_watchdog <city_dir> <log_file> [extra env assignments...]
# Isolates PATH (fake launchctl wins), GC_CITY_PATH, GC_SUPERVISOR_LOG, and
# TMPDIR (so the single-instance lock never touches the real production
# lock path) for one invocation.
run_watchdog() {
  local city="$1" log="$2"; shift 2
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$city" GC_SUPERVISOR_LOG="$log" \
      TMPDIR="$SCRATCH_ROOT/tmp" "$@" bash "$SRC" >"$SCRATCH_ROOT/last.out" 2>&1
}

ledger_file() { echo "$1/.gc/logs/supervisor-restart-watchdog.jsonl"; }
ledger_lines() { local f; f=$(ledger_file "$1"); [ -f "$f" ] && wc -l < "$f" | tr -d ' ' || echo 0; }
last_record() { local f; f=$(ledger_file "$1"); tail -1 "$f"; }
field() { echo "$2" | jq -r ".$1"; }

mkdir -p "$SCRATCH_ROOT/tmp"

echo "== ga-b0gltl: baseline sample + delta math =="

CITY_ABC="$SCRATCH_ROOT/city-abc"
LOG_ABC="$SCRATCH_ROOT/supervisor-abc.log"
: > "$LOG_ABC"

# A. First-ever sample: no prior state -> delta=0, counter_reset=false, not a
#    fabricated "5 restarts" out of thin air.
FAKE_LAUNCHCTL_RUNS=5 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
  run_watchdog "$CITY_ABC" "$LOG_ABC" env FAKE_LAUNCHCTL_RUNS=5 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_ABC")
[ "$(ledger_lines "$CITY_ABC")" = "1" ] && ok "A: first sample writes exactly 1 ledger record" \
  || bad "A: expected 1 ledger record, got $(ledger_lines "$CITY_ABC")"
[ "$(field runs "$REC")" = "5" ] && ok "A: runs=5 recorded" || bad "A: runs mismatch: $REC"
[ "$(field delta_since_last "$REC")" = "0" ] && ok "A: baseline delta=0 (no prior state to diff against)" \
  || bad "A: baseline should not fabricate a delta: $REC"
[ "$(field counter_reset "$REC")" = "false" ] && ok "A: counter_reset=false on baseline" || bad "A: $REC"
[ "$(field last_exit_code "$REC")" = "null" ] && ok "A: '(never exited)' parses to null, not a fake 0" \
  || bad "A: expected null last_exit_code: $REC"

# B. Second sample, runs advances by 3 -> delta=3.
FAKE_LAUNCHCTL_RUNS=8 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
  run_watchdog "$CITY_ABC" "$LOG_ABC" env FAKE_LAUNCHCTL_RUNS=8 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_ABC")
[ "$(field delta_since_last "$REC")" = "3" ] && ok "B: runs 5->8 computes delta=3" || bad "B: $REC"
[ "$(field counter_reset "$REC")" = "false" ] && ok "B: counter_reset=false on a forward delta" || bad "B: $REC"

# C. Third sample, runs goes BACKWARDS (job reload/reboot) -> counter_reset,
#    delta must stay 0, never negative or fabricated.
FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
  run_watchdog "$CITY_ABC" "$LOG_ABC" env FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_ABC")
[ "$(field counter_reset "$REC")" = "true" ] && ok "C: runs 8->2 (backwards) flags counter_reset=true" || bad "C: $REC"
[ "$(field delta_since_last "$REC")" = "0" ] && ok "C: reset does not fabricate a negative/garbage delta" \
  || bad "C: expected delta=0 on reset: $REC"

echo "== ga-b0gltl: exit-code reason detection =="

# D. Non-zero exit code on a real restart (delta>0) -> reason_exit_nonzero.
CITY_D="$SCRATCH_ROOT/city-d"; LOG_D="$SCRATCH_ROOT/supervisor-d.log"; : > "$LOG_D"
FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1 run_watchdog "$CITY_D" "$LOG_D" \
  env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
run_watchdog "$CITY_D" "$LOG_D" env FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT=134
REC=$(last_record "$CITY_D")
[ "$(field reason_exit_nonzero "$REC")" = "true" ] && ok "D: exit code 134 on a restart -> reason_exit_nonzero=true" \
  || bad "D: $REC"
[ "$(field last_exit_code "$REC")" = "134" ] && ok "D: last_exit_code=134 recorded verbatim" || bad "D: $REC"

# E. Exit code 0 -> reason_exit_nonzero stays false (0 is not a crash).
CITY_E="$SCRATCH_ROOT/city-e"; LOG_E="$SCRATCH_ROOT/supervisor-e.log"; : > "$LOG_E"
run_watchdog "$CITY_E" "$LOG_E" env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
run_watchdog "$CITY_E" "$LOG_E" env FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT=0
REC=$(last_record "$CITY_E")
[ "$(field reason_exit_nonzero "$REC")" = "false" ] && ok "E: exit code 0 -> reason_exit_nonzero=false" || bad "E: $REC"

echo "== ga-b0gltl: supervisor.log reason-matching is scoped to the byte window since last sample, and gated on an actual restart =="

# F. codesign/OS_REASON text appended to the log SINCE the previous sample,
#    on a real restart (delta>0) -> reason_log_matches>0.
CITY_F="$SCRATCH_ROOT/city-f"; LOG_F="$SCRATCH_ROOT/supervisor-f.log"; : > "$LOG_F"
run_watchdog "$CITY_F" "$LOG_F" env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
echo "2026-08-18 fatal: OS_REASON_CODESIGNING invalidated signature" >> "$LOG_F"
run_watchdog "$CITY_F" "$LOG_F" env FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_F")
MATCHES=$(field reason_log_matches "$REC")
[ "$MATCHES" -ge 1 ] 2>/dev/null && ok "F: OS_REASON_CODESIGNING appended since last offset -> reason_log_matches=$MATCHES" \
  || bad "F: expected reason_log_matches>=1: $REC"
[ "$(field log_checked "$REC")" = "true" ] && ok "F: log_checked=true (the grep actually ran)" || bad "F: $REC"

# G. Same log content, but delta=0 (no restart happened) -> must NOT
#    attribute a reason to a restart that never occurred.
CITY_G="$SCRATCH_ROOT/city-g"; LOG_G="$SCRATCH_ROOT/supervisor-g.log"; : > "$LOG_G"
run_watchdog "$CITY_G" "$LOG_G" env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
echo "2026-08-18 fatal: OS_REASON_CODESIGNING invalidated signature" >> "$LOG_G"
run_watchdog "$CITY_G" "$LOG_G" env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_G")
[ "$(field delta_since_last "$REC")" = "0" ] && [ "$(field reason_log_matches "$REC")" = "0" ] \
  && ok "G: matching text present but delta=0 -> reason_log_matches stays 0 (no restart, no reason)" \
  || bad "G: reason must not attach to a non-event: $REC"
[ "$(field log_checked "$REC")" = "false" ] \
  && ok "G: log_checked=false (delta=0, the grep never ran — distinct from '0 confirmed')" \
  || bad "G: $REC"

# G2. A real restart (delta>0) but the log file is MISSING entirely (rotated
#     away, path broken) -> reason_log_matches=0 same as a genuine
#     zero-match, but log_checked=false must say "we have no idea" instead
#     of silently asserting "confirmed, not codesign". This is the exact
#     absent-vs-zero collapse the mandatory gate-done self-audit exists to
#     catch — reason_log_matches alone cannot tell these two states apart.
CITY_G2="$SCRATCH_ROOT/city-g2"; LOG_G2="$SCRATCH_ROOT/supervisor-g2-MISSING.log"
run_watchdog "$CITY_G2" "$LOG_G2" env FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1
run_watchdog "$CITY_G2" "$LOG_G2" env FAKE_LAUNCHCTL_RUNS=2 FAKE_LAUNCHCTL_EXIT_NEVER=1
REC=$(last_record "$CITY_G2")
[ "$(field delta_since_last "$REC")" = "1" ] && [ "$(field reason_log_matches "$REC")" = "0" ] \
  && [ "$(field log_checked "$REC")" = "false" ] \
  && ok "G2: real restart, log file missing -> reason_log_matches=0 but log_checked=false (not conflated with a confirmed zero)" \
  || bad "G2: $REC"

echo "== ga-b0gltl: unreadable/empty launchctl output is skipped, never crashes, never fabricates a record =="

# H. `launchctl print` empty (job not loaded, or the internal `timeout 10`
#    fired) -> skip sample, no new ledger line, exit 0.
CITY_H="$SCRATCH_ROOT/city-h"; LOG_H="$SCRATCH_ROOT/supervisor-h.log"; : > "$LOG_H"
run_watchdog "$CITY_H" "$LOG_H" env FAKE_LAUNCHCTL_EMPTY=1
[ "$(ledger_lines "$CITY_H")" = "0" ] && ok "H: empty launchctl output -> no ledger record written" \
  || bad "H: expected 0 ledger lines, got $(ledger_lines "$CITY_H")"

# I. Output present but no parseable 'runs = ' line -> same skip behavior.
CITY_I="$SCRATCH_ROOT/city-i"; LOG_I="$SCRATCH_ROOT/supervisor-i.log"; : > "$LOG_I"
run_watchdog "$CITY_I" "$LOG_I" env FAKE_LAUNCHCTL_NO_RUNS_LINE=1
[ "$(ledger_lines "$CITY_I")" = "0" ] && ok "I: unparseable 'runs =' -> no ledger record written" \
  || bad "I: expected 0 ledger lines, got $(ledger_lines "$CITY_I")"

echo "== ga-b0gltl (ga-y0g5x pattern): single-instance lock under real concurrency =="

# J. Two truly concurrent invocations -> exactly ONE ledger record, the
#    loser's own stdout names the lock explicitly (not a silent no-op).
CITY_J="$SCRATCH_ROOT/city-j"; LOG_J="$SCRATCH_ROOT/supervisor-j.log"; : > "$LOG_J"
OUT1="$SCRATCH_ROOT/j1.out"; OUT2="$SCRATCH_ROOT/j2.out"
(
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_J" GC_SUPERVISOR_LOG="$LOG_J" \
      TMPDIR="$SCRATCH_ROOT/tmp" FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
      bash "$SRC" >"$OUT1" 2>&1 &
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_J" GC_SUPERVISOR_LOG="$LOG_J" \
      TMPDIR="$SCRATCH_ROOT/tmp" FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
      bash "$SRC" >"$OUT2" 2>&1 &
  wait
)
[ "$(ledger_lines "$CITY_J")" = "1" ] && ok "J: two concurrent runs -> exactly 1 ledger record (no duplicate/racing writes)" \
  || bad "J: expected exactly 1 ledger record under concurrency, got $(ledger_lines "$CITY_J")"
if grep -q "holds the lock" "$OUT1" "$OUT2" 2>/dev/null; then
  ok "J: the losing invocation names the lock explicitly (not a silent no-op)"
else
  bad "J: neither concurrent invocation reported backing off — lock may not be contending at all"
fi
[ -d "$SCRATCH_ROOT/tmp/supervisor-restart-watchdog.lock.d" ] \
  && bad "J: lock dir still present after both runs completed — release/trap did not fire" \
  || ok "J: lock dir released after completion (EXIT trap fired)"

echo "== ga-b0gltl: detection-only — static guard against scope creep into repair actions =="

# K. The bead is explicit: detection-only, no automatic repair. A future edit
#    that adds a "helpful" kickstart/restart call would silently turn this
#    into the exact kind of unreviewed mutation the bead's own scope
#    excludes. Grep, not a live check — there is no safe way to dynamically
#    prove "never restarts the real supervisor" without risking doing so.
if grep -qE 'launchctl[[:space:]]+(kickstart|bootout|unload|stop|kill)|pkill|kill[[:space:]]+-(9|QUIT|TERM)' "$SRC"; then
  bad "K: found a mutating launchctl/kill invocation in the script — violates detection-only scope"
else
  ok "K: no mutating launchctl/kill/pkill invocation found (detection-only, as scoped)"
fi

echo
echo "supervisor-restart-watchdog selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

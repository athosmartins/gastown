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
# ga-xuo89c extends the same stubs with `lsof`, `tmux`, `notify` and
# `launchctl kickstart`, so the fd guard's thresholds, 30-min cooldown and
# "unreadable count never restarts" rule are all proven without touching the
# real supervisor. The script runs under /bin/bash (3.2) here, like the plist.
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
# Fake launchctl — deterministic runs/exit-code/pid fixtures for the selftest.
# Never touches a real launchd job. $FAKE_DIR holds the fake supervisor's
# current pid (file `pid`) and the kickstart ledger (`kickstart.log`).
D="${FAKE_DIR:-/nonexistent-fake-dir}"
if [ "${1:-}" = "print" ]; then
  { echo x >> "$D/print.log"; } 2>/dev/null     # how many times the script asked (the restart wait must not spin)
  if [ "${FAKE_LAUNCHCTL_EMPTY:-0}" = "1" ]; then
    exit 1
  fi
  if [ "${FAKE_LAUNCHCTL_NO_RUNS_LINE:-0}" != "1" ]; then
    printf '\truns = %s\n' "${FAKE_LAUNCHCTL_RUNS:-1}"
  fi
  if [ "${FAKE_LAUNCHCTL_NO_PID:-0}" != "1" ]; then
    printf '\tpid = %s\n' "$(cat "$D/pid" 2>/dev/null || echo 4242)"
  fi
  if [ "${FAKE_LAUNCHCTL_EXIT_NEVER:-0}" = "1" ]; then
    printf '\tlast exit code = (never exited)\n'
  else
    printf '\tlast exit code = %s\n' "${FAKE_LAUNCHCTL_EXIT:-0}"
  fi
  exit 0
fi
if [ "${1:-}" = "kickstart" ]; then
  printf '%s\n' "$*" >> "$D/kickstart.log"
  [ "${FAKE_KICKSTART_FAIL:-0}" = "1" ] && exit 1
  # FAKE_KICKSTART_RC: the client exits with this status (124 = it timed out, 137 = it was killed).
  # Unless FAKE_KICKSTART_LANDS=1 the job was NOT touched; with it, launchd did the kill although
  # the client never said so — the case the script cannot tell from the exit status alone.
  if [ -n "${FAKE_KICKSTART_RC:-}" ] && [ "${FAKE_KICKSTART_LANDS:-0}" != "1" ]; then exit "$FAKE_KICKSTART_RC"; fi
  : > "$D/kicked"
  # the respawned job gets a new pid, unless the scenario says it never came back
  [ "${FAKE_KICKSTART_NO_NEWPID:-0}" = "1" ] || echo $(( $(cat "$D/pid" 2>/dev/null || echo 4242) + 1 )) > "$D/pid"
  # the state directory goes read-only right after the kick: whatever the script writes next must fail
  [ "${FAKE_KICKSTART_LOCK_STATE:-0}" = "1" ] && chmod 555 "${GC_CITY_PATH:-/nonexistent}/.gc/state"
  exit "${FAKE_KICKSTART_RC:-0}"
fi
exit 1
FAKE
chmod +x "$FAKE_BIN/launchctl"

cat > "$FAKE_BIN/lsof" <<'FAKE'
#!/usr/bin/env bash
# Fake `lsof -n -P -p <pid>`: header + $FAKE_LSOF_FDS numeric-fd rows + three
# rows that are NOT descriptors (cwd/txt/mem), so a count that includes them
# is off by exactly 3. After a kickstart the count drops to $FAKE_LSOF_FDS_AFTER.
D="${FAKE_DIR:-/nonexistent-fake-dir}"
printf '%s\n' "$*" >> "$D/lsof.log"
N="${FAKE_LSOF_FDS:-100}"
[ -e "$D/kicked" ] && N="${FAKE_LSOF_FDS_AFTER:-300}"
rows() {
  printf 'COMMAND     PID  USER   FD     TYPE             DEVICE  SIZE/OFF                NODE NAME\n'
  # mode/lock suffixes vary like real lsof (3r, 5w, 7uW): every row is one descriptor whatever its suffix
  awk -v n="$N" 'BEGIN { for (i = 0; i < n; i++) { s = "r"; if (i % 5 == 0) s = "w"; if (i % 7 == 0) s = "uW"; printf "gc      4242 athos %d%s  REG 1,4 0 1 /x/%d\n", i + 3, s, i } }'
  printf 'gc      4242 athos cwd    DIR 1,4 0 2 /\n'
  printf 'gc      4242 athos txt    REG 1,4 0 3 /bin/gc\n'
  printf 'gc      4242 athos mem    REG 1,4 0 4 /lib/x.dylib\n'
}
case "${FAKE_LSOF_MODE:-ok}" in
  ok)        rows ;;
  rc1)       rows; exit 1 ;;                                   # warnings, rows still complete
  empty)     exit 1 ;;                                         # no such pid / nothing printed
  fail)      rows; echo "lsof: boom" >&2; exit 2 ;;               # plausible rows, but a failing status: the rows must not count
  slow)      rows; sleep 30 ;;                                 # partial output, then hangs past the timeout
  nohdr)     rows | tail -n +2 ;;                              # rows without the COMMAND header
  nonum)     printf 'COMMAND PID USER FD TYPE\ngc 4242 athos cwd DIR\n' ;;   # header, but no descriptor rows
esac
FAKE
chmod +x "$FAKE_BIN/lsof"

cat > "$FAKE_BIN/tmux" <<'FAKE'
#!/usr/bin/env bash
D="${FAKE_DIR:-/nonexistent-fake-dir}"
printf '%s\n' "$*" >> "$D/tmux.log"
[ "${FAKE_TMUX_FAIL:-0}" = "1" ] && { echo "no server running" >&2; exit 1; }
N="${FAKE_TMUX_SESSIONS:-8}"
[ -e "$D/kicked" ] && N="${FAKE_TMUX_SESSIONS_AFTER:-$N}"
awk -v n="$N" 'BEGIN { for (i = 0; i < n; i++) print "x" }'
FAKE
chmod +x "$FAKE_BIN/tmux"

cat > "$FAKE_BIN/notify" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_DIR:-/nonexistent-fake-dir}/notify.log"
FAKE
chmod +x "$FAKE_BIN/notify"

# run_watchdog <city_dir> <log_file> [extra env assignments...]
# Isolates PATH (fake launchctl wins), GC_CITY_PATH, GC_SUPERVISOR_LOG, and
# TMPDIR (so the single-instance lock never touches the real production
# lock path) for one invocation.
run_watchdog() {
  local city="$1" log="$2"; shift 2
  mkdir -p "$city/.fake"
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$city" GC_SUPERVISOR_LOG="$log" FAKE_DIR="$city/.fake" \
      TMPDIR="$SCRATCH_ROOT/tmp" "$@" /bin/bash "$SRC" >"$SCRATCH_ROOT/last.out" 2>&1
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
  mkdir -p "$CITY_J/.fake"
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_J" GC_SUPERVISOR_LOG="$LOG_J" \
      TMPDIR="$SCRATCH_ROOT/tmp" FAKE_DIR="$CITY_J/.fake" FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
      /bin/bash "$SRC" >"$OUT1" 2>&1 &
  env PATH="$FAKE_BIN:$PATH" GC_CITY_PATH="$CITY_J" GC_SUPERVISOR_LOG="$LOG_J" \
      TMPDIR="$SCRATCH_ROOT/tmp" FAKE_DIR="$CITY_J/.fake" FAKE_LAUNCHCTL_RUNS=1 FAKE_LAUNCHCTL_EXIT_NEVER=1 \
      /bin/bash "$SRC" >"$OUT2" 2>&1 &
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

echo "== ga-xuo89c: the fd guard — fixtures =="

# One city per scenario: the fake supervisor's pid / "was kickstarted" marker /
# call logs live in <city>/.fake, so scenarios cannot leak into each other.
guard_file() { echo "$1/.gc/state/supervisor-fds-guard.json"; }
count_lines() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
kicks()   { count_lines "$1/.fake/kickstart.log"; }
notifies() { count_lines "$1/.fake/notify.log"; }
# the fake supervisor "reboots" to the pre-restart fixture (old pid, original fd count)
fake_reset() { rm -f "$1/.fake/kicked" "$1/.fake/pid"; }
# rewrite the cooldown stamp as if the last guard restart was <age> seconds ago
set_stamp_age() {
  local city="$1" age="$2" f
  f=$(guard_file "$city")
  jq -n --argjson e "$(( $(date +%s) - age ))" \
    '{last_restart_epoch:$e, last_restart_ts:"fixture", runs_at_restart:1, pid_before:4242, fds_before:50000, inferred:false}' > "$f"
}
new_city() { # new_city <name> -> sets CITY_X / LOG_X
  CITY_X="$SCRATCH_ROOT/city-$1"; LOG_X="$SCRATCH_ROOT/supervisor-$1.log"; : > "$LOG_X"
}
wd() { # wd <fake env assignments...> — one run against $CITY_X
  run_watchdog "$CITY_X" "$LOG_X" env FAKE_LAUNCHCTL_RUNS="${RUNS_X:-1}" FAKE_LAUNCHCTL_EXIT_NEVER=1 "$@"
}

echo "== ga-xuo89c AC1: thresholds — <30k nothing, 30-40k records only, >40k restarts =="

# L1. A small count is recorded, and counts DESCRIPTORS only: the fake prints
#     cwd/txt/mem rows as well, so counting every row would read 103.
new_city l1
wd FAKE_LSOF_FDS=100
REC=$(last_record "$CITY_X")
[ "$(field fds "$REC")" = "100" ] && ok "L1: fds=100 recorded (cwd/txt/mem rows and the header are not descriptors; mode/lock suffixes like 7uW are)" \
  || bad "L1: expected fds=100: $REC"
[ "$(field fds_state "$REC")" = "ok" ] && [ "$(field guard_action "$REC")" = "none" ] && [ "$(field pid "$REC")" = "4242" ] \
  && ok "L1: fds_state=ok, guard_action=none, pid=4242" || bad "L1: $REC"
[ "$(kicks "$CITY_X")" = "0" ] && [ "$(notifies "$CITY_X")" = "0" ] \
  && ok "L1: <30k -> no kickstart, no notify" || bad "L1: kicks=$(kicks "$CITY_X") notifies=$(notifies "$CITY_X")"
grep -qx -- '-n -P -p 4242' "$CITY_X/.fake/lsof.log" \
  && ok "L1: lsof is asked for exactly the supervisor's pid, without DNS/service lookups (-n -P -p 4242)" \
  || bad "L1: unexpected lsof args: $(cat "$CITY_X/.fake/lsof.log" 2>/dev/null)"

# L2. The boundaries. > 30,000 is "warn" (30,000 itself is not), > 40,000 is
#     "restart" (40,000 itself is not). Off-by-one here would restart a healthy
#     supervisor or sit on a dying one.
for N in 29999 30000; do
  new_city "l2-$N"; wd FAKE_LSOF_FDS=$N; REC=$(last_record "$CITY_X")
  [ "$(field fds "$REC")" = "$N" ] && [ "$(field guard_action "$REC")" = "none" ] && [ "$(kicks "$CITY_X")" = "0" ] \
    && ok "L2: fds=$N -> recorded, guard_action=none, no kickstart" || bad "L2: fds=$N: $REC"
done
for N in 30001 40000; do
  new_city "l2-$N"; wd FAKE_LSOF_FDS=$N; REC=$(last_record "$CITY_X")
  [ "$(field fds "$REC")" = "$N" ] && [ "$(field guard_action "$REC")" = "warn" ] \
    && [ "$(kicks "$CITY_X")" = "0" ] && [ "$(notifies "$CITY_X")" = "0" ] && [ ! -e "$(guard_file "$CITY_X")" ] \
    && ok "L2: fds=$N -> guard_action=warn, no kickstart, no notify, no cooldown stamp" || bad "L2: fds=$N: $REC"
done
new_city l2-rc1; wd FAKE_LSOF_FDS=35000 FAKE_LSOF_MODE=rc1; REC=$(last_record "$CITY_X")
[ "$(field fds "$REC")" = "35000" ] && [ "$(field guard_action "$REC")" = "warn" ] \
  && ok "L2: lsof exiting 1 (warnings) with a complete table still counts" || bad "L2 rc1: $REC"

echo "== ga-xuo89c AC3: a >40k event restarts once and leaves the evidence =="

new_city m
wd FAKE_LSOF_FDS=40001 FAKE_LSOF_FDS_AFTER=412 FAKE_TMUX_SESSIONS=9 FAKE_TMUX_SESSIONS_AFTER=9
REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "1" ] && ok "M: fds=40001 -> exactly one kickstart" || bad "M: kicks=$(kicks "$CITY_X")"
grep -qx "kickstart -k gui/$(id -u)/com.gascity.supervisor" "$CITY_X/.fake/kickstart.log" \
  && ok "M: it is 'launchctl kickstart -k gui/<uid>/com.gascity.supervisor' (what the bead specifies)" \
  || bad "M: kickstart args: $(cat "$CITY_X/.fake/kickstart.log" 2>/dev/null)"
[ "$(field guard_action "$REC")" = "restart_ok" ] && [ "$(field fds "$REC")" = "40001" ] && [ "$(field pid "$REC")" = "4242" ] \
  && ok "M: ledger says restart_ok on pid 4242 with fds=40001" || bad "M: $REC"
[ "$(field restart_new_pid "$REC")" = "4243" ] && [ "$(field fds_after "$REC")" = "412" ] \
  && ok "M: evidence: new pid 4243, fds_after=412 (counted on the NEW process)" || bad "M: $REC"
[ "$(field sessions_before "$REC")" = "9" ] && [ "$(field sessions_after "$REC")" = "9" ] \
  && ok "M: evidence: tmux sessions 9 before, 9 after (sessions preserved)" || bad "M: $REC"
grep -q -- '-L gascity list-sessions' "$CITY_X/.fake/tmux.log" \
  && ok "M: sessions are counted on the city's tmux socket (-L gascity)" || bad "M: tmux args: $(cat "$CITY_X/.fake/tmux.log" 2>/dev/null)"
grep -qx -- '-n -P -p 4243' "$CITY_X/.fake/lsof.log" && ok "M: fds_after comes from lsof on the new pid" || bad "M: lsof log: $(cat "$CITY_X/.fake/lsof.log")"
[ "$(notifies "$CITY_X")" = "1" ] && grep -q -- '-p 4 ' "$CITY_X/.fake/notify.log" && grep -q '40001' "$CITY_X/.fake/notify.log" \
  && ok "M: exactly one notify, priority 4, carrying the fd count" || bad "M: notify log: $(cat "$CITY_X/.fake/notify.log" 2>/dev/null)"
G=$(cat "$(guard_file "$CITY_X")" 2>/dev/null)
[ "$(field runs_at_restart "$G")" = "1" ] && [ "$(field pid_before "$G")" = "4242" ] && [ "$(field fds_before "$G")" = "40001" ] && [ "$(field inferred "$G")" = "false" ] \
  && ok "M: cooldown state records runs/pid/fds at the restart (inferred=false)" || bad "M: guard state: $G"

echo "== ga-xuo89c AC1: never restarts twice within 30 minutes =="

# N. Same city as M: the supervisor "reboots" to a leaking fixture right away.
fake_reset "$CITY_X"
wd FAKE_LSOF_FDS=45000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "1" ] && [ "$(field guard_action "$REC")" = "cooldown" ] \
  && ok "N: >40k again right after the restart -> guard_action=cooldown, still 1 kickstart" || bad "N: kicks=$(kicks "$CITY_X") $REC"
R=$(field cooldown_remaining_s "$REC")
[ "$R" -gt 1500 ] 2>/dev/null && [ "$R" -le 1800 ] && ok "N: cooldown_remaining_s=$R (of 1800)" || bad "N: cooldown_remaining_s=$R"
[ "$(notifies "$CITY_X")" = "2" ] && grep -q 'NOT restarting' "$CITY_X/.fake/notify.log" \
  && ok "N: the refused restart is announced (notify #2), not silent" || bad "N: notifies=$(notifies "$CITY_X")"
# 1500s ago -> still inside the window (300s left, minus however long this run
# took on a loaded box); 1900s ago -> outside. Margins this wide are deliberate:
# the stamp is set before the run, the run reads the clock after.
fake_reset "$CITY_X"; set_stamp_age "$CITY_X" 1500
wd FAKE_LSOF_FDS=45000; REC=$(last_record "$CITY_X")
R=$(field cooldown_remaining_s "$REC")
[ "$(kicks "$CITY_X")" = "1" ] && [ "$(field guard_action "$REC")" = "cooldown" ] && [ "$R" -ge 150 ] && [ "$R" -le 300 ] \
  && ok "N: last restart 1500s ago -> still cooling down ($R s left), no kickstart" || bad "N: 1500s: kicks=$(kicks "$CITY_X") $REC"
fake_reset "$CITY_X"; set_stamp_age "$CITY_X" 1900
wd FAKE_LSOF_FDS=45000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "2" ] && [ "$(field guard_action "$REC")" = "restart_ok" ] \
  && ok "N: last restart 1900s ago -> window over, restarts again (kickstart #2)" || bad "N: 1900s: kicks=$(kicks "$CITY_X") $REC"
# A reading inside the cooldown that is NOT >40k must not be nagged about.
fake_reset "$CITY_X"; N0=$(notifies "$CITY_X")
wd FAKE_LSOF_FDS=35000; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "warn" ] && [ "$(notifies "$CITY_X")" = "$N0" ] \
  && ok "N: inside the cooldown, a 30-40k reading is just 'warn' (no extra notify)" || bad "N: $REC"

echo "== ga-xuo89c: a count that could not be read is not a big count =="

# O. 50,000 would restart if it were believed. Every way of not knowing the
#    number must land on fds:null, a named state, and NO kickstart.
for CASE in "empty:lsof_unparsable" "fail:lsof_failed" "slow:lsof_timeout" "nohdr:lsof_unparsable" "nonum:lsof_unparsable"; do
  MODE="${CASE%%:*}"; WANT="${CASE##*:}"
  new_city "o-$MODE"
  # Only the hanging lsof gets a short timeout. The others keep the default: at
  # load ~70 the fake took up to ~2s to print 50000 rows, and a 2s bound turned
  # "unparsable" into "timeout" for the wrong reason (seen once, nohdr).
  TMO=120; [ "$MODE" = "slow" ] && TMO=2
  wd FAKE_LSOF_FDS=50000 FAKE_LSOF_MODE="$MODE" SRW_LSOF_TIMEOUT=$TMO
  REC=$(last_record "$CITY_X")
  if [ "$(field fds "$REC")" = "null" ] && [ "$(field fds_state "$REC")" = "$WANT" ] && [ "$(field guard_action "$REC")" = "unreadable" ] \
     && [ "$(kicks "$CITY_X")" = "0" ] && [ "$(notifies "$CITY_X")" = "0" ] && [ ! -e "$(guard_file "$CITY_X")" ]; then
    ok "O: lsof $MODE (50000 rows on offer) -> fds:null, fds_state=$WANT, no kickstart, no cooldown stamp"
  else
    bad "O: lsof $MODE: kicks=$(kicks "$CITY_X") $REC"
  fi
done
new_city o-nopid
wd FAKE_LSOF_FDS=50000 FAKE_LAUNCHCTL_NO_PID=1
REC=$(last_record "$CITY_X")
if [ "$(field fds "$REC")" = "null" ] && [ "$(field fds_state "$REC")" = "no_pid" ] && [ "$(field pid "$REC")" = "null" ] \
   && [ "$(kicks "$CITY_X")" = "0" ] && [ ! -e "$CITY_X/.fake/lsof.log" ]; then
  ok "O: no 'pid =' line (job between runs) -> pid:null, fds:null, fds_state=no_pid, lsof never called, no kickstart"
else
  bad "O: no pid: $REC"
fi
# a non-numeric threshold override falls back to the default instead of becoming 0
new_city o-badenv
wd FAKE_LSOF_FDS=100 SRW_FDS_RESTART=abc SRW_FDS_WARN=
REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "none" ] && [ "$(kicks "$CITY_X")" = "0" ] \
  && ok "O: garbage SRW_FDS_RESTART / empty SRW_FDS_WARN -> defaults (40000/30000), not a threshold of 0" || bad "O: badenv: $REC"

echo "== ga-xuo89c: a cooldown state that cannot be trusted stops the restart, not the guard =="

# P1. corrupt file
new_city p1; wd FAKE_LSOF_FDS=1; printf 'this is not json' > "$(guard_file "$CITY_X")"
wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
if [ "$(kicks "$CITY_X")" = "0" ] && [ "$(field guard_action "$REC")" = "cooldown_state_unreadable" ] && [ "$(notifies "$CITY_X")" = "1" ]; then
  ok "P1: corrupt guard state + 50000 fds -> no kickstart, guard_action=cooldown_state_unreadable, notified"
else
  bad "P1: kicks=$(kicks "$CITY_X") $REC"
fi
ls "$CITY_X/.gc/state/" | grep -q '^supervisor-fds-guard.json.unreadable\.[0-9]*$' \
  && ok "P1: the bad file is kept (.unreadable.<epoch>) for whoever looks" || bad "P1: no quarantine copy: $(ls "$CITY_X/.gc/state/")"
[ "$(field inferred "$(cat "$(guard_file "$CITY_X")")")" = "true" ] \
  && ok "P1: state is re-stamped (inferred=true) so the guard heals itself" || bad "P1: $(cat "$(guard_file "$CITY_X")")"
fake_reset "$CITY_X"; wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "0" ] && [ "$(field guard_action "$REC")" = "cooldown" ] \
  && ok "P1: next cycle reads the healed state -> an ordinary cooldown" || bad "P1 next: $REC"
fake_reset "$CITY_X"; set_stamp_age "$CITY_X" 1900; wd FAKE_LSOF_FDS=50000
[ "$(kicks "$CITY_X")" = "1" ] && ok "P1: after the window the guard acts again" || bad "P1 later: kicks=$(kicks "$CITY_X")"

# P2. valid JSON that has no stamp; P3. a stamp from the far future (clock stepped back / garbage)
new_city p2; wd FAKE_LSOF_FDS=1; echo '{}' > "$(guard_file "$CITY_X")"
wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "0" ] && [ "$(field guard_action "$REC")" = "cooldown_state_unreadable" ] \
  && ok "P2: JSON without last_restart_epoch is unreadable, not 'never restarted'" || bad "P2: $REC"
new_city p3; wd FAKE_LSOF_FDS=1; set_stamp_age "$CITY_X" -864000
wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "0" ] && [ "$(field guard_action "$REC")" = "cooldown_state_unreadable" ] \
  && ok "P3: a stamp 10 days in the future is unreadable (quarantined), no kickstart" || bad "P3: $REC"

# P4. the stamp cannot be written -> no restart (a restart that cannot be rate-limited could loop)
new_city p4; wd FAKE_LSOF_FDS=1
chmod 555 "$CITY_X/.gc/state"
if touch "$CITY_X/.gc/state/.probe" 2>/dev/null; then
  # root (or an ACL) ignores the mode bits: the fault cannot be injected, so say so instead of passing vacuously
  rm -f "$CITY_X/.gc/state/.probe"
  echo "  skip P4: cannot make the state dir unwritable here (running as uid $(id -u))"
else
  wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
  [ "$(kicks "$CITY_X")" = "0" ] && [ "$(field guard_action "$REC")" = "state_unwritable" ] && [ "$(field fds "$REC")" = "50000" ] \
    && ok "P4: cooldown stamp unwritable -> no kickstart, guard_action=state_unwritable (the ledger still records fds=50000)" || bad "P4: kicks=$(kicks "$CITY_X") $REC"
fi
chmod 755 "$CITY_X/.gc/state"

echo "== ga-xuo89c: failures of the restart itself are named, and still rate-limited =="

new_city r1
wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_FAIL=1; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "1" ] && [ "$(field guard_action "$REC")" = "restart_failed" ] && [ "$(field restart_new_pid "$REC")" = "null" ] \
  && grep -q 'FAILED' "$CITY_X/.fake/notify.log" \
  && ok "R1: kickstart exits non-zero -> restart_failed, no new pid claimed, notified" || bad "R1: $REC"
fake_reset "$CITY_X"; wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(kicks "$CITY_X")" = "1" ] && [ "$(field guard_action "$REC")" = "cooldown" ] \
  && ok "R1: a failed attempt still opens the cooldown (no retry loop every 15 min)" || bad "R1 retry: $REC"
new_city r2
wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_NO_NEWPID=1 SRW_RESTART_WAIT=2 SRW_RESTART_POLL=1; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_unconfirmed" ] && [ "$(field restart_new_pid "$REC")" = "null" ] && [ "$(field fds_after "$REC")" = "null" ] \
  && grep -q 'no new pid' "$CITY_X/.fake/notify.log" \
  && ok "R2: kickstart accepted but the pid never changes -> restart_unconfirmed, new pid/fds_after stay null, notified" || bad "R2: $REC"
new_city r3
wd FAKE_LSOF_FDS=50000 FAKE_TMUX_FAIL=1; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_ok" ] && [ "$(field sessions_before "$REC")" = "null" ] && [ "$(field sessions_after "$REC")" = "null" ] \
  && ok "R3: tmux not answering -> sessions are null (unknown), never 0, and the restart still goes ahead" || bad "R3: $REC"

echo "== ga-xuo89c (gate-fix 1): the guard is credited with a restart only when one happened =="

deaths() { jq -s 'map(.delta_since_last - (.delta_guard_restart // 0)) | add' "$(ledger_file "$1")"; }
# the credit lives in the guard state file: null = "no restart to credit"
credited_runs() { jq -c '.runs_at_restart' "$(guard_file "$1")"; }

# S1. The reviewer's reproduction, verbatim: the kick FAILS, then launchd's own
#     respawn (a genuine death) bumps runs. That death is not the guard's.
new_city s1
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_FAIL=1; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_failed" ] && [ "$(field guard_stamp "$REC")" = "unattributed" ] && [ "$(credited_runs "$CITY_X")" = "null" ] \
  && ok "S1: a failed kick leaves nothing credited (guard_stamp=unattributed, runs_at_restart=null in the state file)" \
  || bad "S1: stamp=$(field guard_stamp "$REC") credited=$(credited_runs "$CITY_X") $REC"
fake_reset "$CITY_X"
RUNS_X=11 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_since_last "$REC")" = "1" ] && [ "$(field delta_guard_restart "$REC")" = "0" ] \
  && ok "S1: the first genuine death after the failed kick is NOT credited to the guard (delta_guard_restart=0)" || bad "S1: $REC"
[ "$(deaths "$CITY_X")" = "1" ] && ok "S1: the header's jq query counts that death (deaths=1, not 0)" || bad "S1: deaths=$(deaths "$CITY_X")"
# ...and the failed attempt still holds the cooldown: crediting nothing must not mean retrying every cycle
fake_reset "$CITY_X"; RUNS_X=11 wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "cooldown" ] && [ "$(kicks "$CITY_X")" = "1" ] \
  && ok "S1: the cooldown of the failed attempt is intact (still 1 kickstart)" || bad "S1 cooldown: $REC kicks=$(kicks "$CITY_X")"

# S2. Exit status other than 1 and not a timeout: still "launchctl said no, nothing was killed".
new_city s2
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_RC=5; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_failed" ] && [ "$(field guard_stamp "$REC")" = "unattributed" ] && [ "$(credited_runs "$CITY_X")" = "null" ] \
  && grep -q 'exit 5, nothing was killed' "$CITY_X/.fake/notify.log" \
  && ok "S2: kickstart exit 5 -> restart_failed, uncredited, and the notify names the exit status" || bad "S2: $REC $(cat "$CITY_X/.fake/notify.log" 2>/dev/null)"

# S3. The call timed out (124) and nothing happened: not "failed", not "restarted" — unknown.
new_city s3
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_RC=124 SRW_RESTART_WAIT=2 SRW_RESTART_POLL=1; REC=$(last_record "$CITY_X")
if [ "$(field guard_action "$REC")" = "restart_unknown" ] && [ "$(field guard_stamp "$REC")" = "unattributed" ] && [ "$(credited_runs "$CITY_X")" = "null" ] \
   && [ "$(field restart_new_pid "$REC")" = "null" ] && [ "$(kicks "$CITY_X")" = "1" ]; then
  ok "S3: kickstart timed out (124), pid unchanged -> restart_unknown, uncredited, no new pid claimed"
else
  bad "S3: $REC"
fi
grep -q 'may or may not have restarted' "$CITY_X/.fake/notify.log" && ! grep -q 'FAILED' "$CITY_X/.fake/notify.log" \
  && ok "S3: the notify says 'may or may not', not FAILED (a timeout is not a refusal)" || bad "S3 notify: $(cat "$CITY_X/.fake/notify.log" 2>/dev/null)"
fake_reset "$CITY_X"; RUNS_X=11 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_since_last "$REC")" = "1" ] && [ "$(field delta_guard_restart "$REC")" = "0" ] && [ "$(deaths "$CITY_X")" = "1" ] \
  && ok "S3: the next +1 is counted as a death, not swallowed (an unknown kick is never credited)" || bad "S3 next: $REC deaths=$(deaths "$CITY_X")"
fake_reset "$CITY_X"; RUNS_X=11 wd FAKE_LSOF_FDS=50000; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "cooldown" ] && ok "S3: the unknown attempt holds the cooldown too" || bad "S3 cooldown: $REC"

# S4. Killed by a signal (137): the same third state.
new_city s4
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_RC=137 SRW_RESTART_WAIT=2 SRW_RESTART_POLL=1; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_unknown" ] && [ "$(credited_runs "$CITY_X")" = "null" ] \
  && ok "S4: kickstart killed by a signal (137) -> restart_unknown, uncredited" || bad "S4: $REC"

# S5. The call timed out but launchd DID restart the job: a different pid is proof.
new_city s5
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_RC=124 FAKE_KICKSTART_LANDS=1 SRW_RESTART_WAIT=2 SRW_RESTART_POLL=1; REC=$(last_record "$CITY_X")
if [ "$(field guard_action "$REC")" = "restart_ok" ] && [ "$(field guard_stamp "$REC")" = "attributed" ] && [ "$(credited_runs "$CITY_X")" = "10" ] \
   && [ "$(field restart_new_pid "$REC")" = "4243" ]; then
  ok "S5: kickstart timed out but the pid changed -> restart_ok, credited (runs_at_restart=10)"
else
  bad "S5: credited=$(credited_runs "$CITY_X") $REC"
fi
fake_reset "$CITY_X"; RUNS_X=11 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_guard_restart "$REC")" = "1" ] && [ "$(deaths "$CITY_X")" = "0" ] \
  && ok "S5: and that restart is not counted as a death (delta_guard_restart=1, deaths=0)" || bad "S5 next: $REC deaths=$(deaths "$CITY_X")"

# S6. The kick is accepted (exit 0) but the new pid is never seen: launchd took the
#     request, so it is credited (restart_unconfirmed is about the pid, not the kick).
new_city s6
RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_NO_NEWPID=1 SRW_RESTART_WAIT=2 SRW_RESTART_POLL=1; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_unconfirmed" ] && [ "$(field guard_stamp "$REC")" = "attributed" ] && [ "$(credited_runs "$CITY_X")" = "10" ] \
  && ok "S6: kickstart exit 0, pid unchanged -> restart_unconfirmed, still credited (launchd accepted the kill)" || bad "S6: credited=$(credited_runs "$CITY_X") $REC"

# S7. The restart happened but the credit cannot be written: the record says so,
#     instead of reporting a credit that is not in the state file.
new_city s7; wd FAKE_LSOF_FDS=1                                   # create the dirs first
PROBE_DIR="$SCRATCH_ROOT/probe-ro"; mkdir -p "$PROBE_DIR"; chmod 555 "$PROBE_DIR"
if touch "$PROBE_DIR/.p" 2>/dev/null; then
  rm -f "$PROBE_DIR/.p"
  echo "  skip S7: cannot make a directory unwritable here (running as uid $(id -u))"
else
  RUNS_X=10 wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_LOCK_STATE=1; REC=$(last_record "$CITY_X")
  chmod 755 "$CITY_X/.gc/state"
  if [ "$(field guard_action "$REC")" = "restart_ok" ] && [ "$(field guard_stamp "$REC")" = "unattributed" ] && [ "$(credited_runs "$CITY_X")" = "null" ] \
     && grep -q 'could not be written' "$SCRATCH_ROOT/last.out"; then
    ok "S7: restart_ok but the credit could not be written -> guard_stamp=unattributed, a WARN line, nothing credited"
  else
    bad "S7: credited=$(credited_runs "$CITY_X") $REC $(cat "$SCRATCH_ROOT/last.out")"
  fi
fi
chmod 755 "$PROBE_DIR"

# S8. A successful kick is credited, and the cycles with no kick say so.
new_city s8
wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field guard_stamp "$REC")" = "none" ] && ok "S8: no kickstart attempted -> guard_stamp=none" || bad "S8: $REC"
wd FAKE_LSOF_FDS=40001; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "restart_ok" ] && [ "$(field guard_stamp "$REC")" = "attributed" ] && [ "$(credited_runs "$CITY_X")" = "1" ] \
  && ok "S8: kick landed -> guard_stamp=attributed, runs_at_restart=1 in the state file" || bad "S8: $REC"
fake_reset "$CITY_X"; wd FAKE_LSOF_FDS=45000; REC=$(last_record "$CITY_X")
[ "$(field guard_action "$REC")" = "cooldown" ] && [ "$(field guard_stamp "$REC")" = "none" ] \
  && ok "S8: a refused restart (cooldown) attempted no kickstart -> guard_stamp=none" || bad "S8 cooldown: $REC"

# S9. A garbage SRW_RESTART_POLL falls back to the default; it must not turn the wait into a busy loop.
new_city s9
wd FAKE_LSOF_FDS=50000 FAKE_KICKSTART_NO_NEWPID=1 SRW_RESTART_WAIT=3 SRW_RESTART_POLL=abc; REC=$(last_record "$CITY_X")
PRINTS=$(count_lines "$CITY_X/.fake/print.log")
[ "$(field guard_action "$REC")" = "restart_unconfirmed" ] && [ "$PRINTS" -le 8 ] \
  && ok "S9: SRW_RESTART_POLL=abc -> default poll, $PRINTS launchctl-print calls over a 3s wait (a busy loop makes hundreds)" || bad "S9: prints=$PRINTS $REC"
eval "$(grep -E '^_srw_dec\(\)' "$SRC")"
DEC_OK=1
for CASE in "abc:2" ":2" "1.5:1.5" "1.2.3:2" ".:2" "0.5:0.5" "3:3" "-1:2" "1e3:2"; do
  GOT=$(_srw_dec "${CASE%%:*}" 2); [ "$GOT" = "${CASE##*:}" ] || { DEC_OK=0; bad "S9: _srw_dec '${CASE%%:*}' -> '$GOT', expected '${CASE##*:}'"; }
done
[ "$DEC_OK" = "1" ] && ok "S9: _srw_dec accepts digits with one dot (3, 0.5, 1.5) and falls back on everything else (abc, empty, 1.2.3, ., -1, 1e3)"

echo "== ga-xuo89c: restarts the guard caused are not counted as deaths =="

new_city q
RUNS_X=10 wd FAKE_LSOF_FDS=100
RUNS_X=10 wd FAKE_LSOF_FDS=50000                      # guard restarts at runs=10 -> launchd's counter becomes 11
fake_reset "$CITY_X"
RUNS_X=11 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_since_last "$REC")" = "1" ] && [ "$(field delta_guard_restart "$REC")" = "1" ] \
  && ok "Q: next sample sees runs 10->11: delta_since_last=1, delta_guard_restart=1 (the guard's own kick)" || bad "Q: $REC"
RUNS_X=12 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_since_last "$REC")" = "1" ] && [ "$(field delta_guard_restart "$REC")" = "0" ] \
  && ok "Q: a later 11->12 is a real death: delta_guard_restart=0" || bad "Q: $REC"
DEATHS=$(jq -s 'map(.delta_since_last - (.delta_guard_restart // 0)) | add' "$(ledger_file "$CITY_X")")
[ "$DEATHS" = "1" ] && ok "Q: the header's jq query gives deaths=1 over the 4 samples (2 restarts, one of them ours)" || bad "Q: deaths=$DEATHS"
new_city q2
RUNS_X=10 wd FAKE_LSOF_FDS=100
RUNS_X=10 wd FAKE_LSOF_FDS=50000
fake_reset "$CITY_X"
RUNS_X=12 wd FAKE_LSOF_FDS=100; REC=$(last_record "$CITY_X")
[ "$(field delta_since_last "$REC")" = "2" ] && [ "$(field delta_guard_restart "$REC")" = "1" ] \
  && ok "Q: kick + a real death in one window: delta=2, delta_guard_restart=1 -> 1 death" || bad "Q2: $REC"

echo "== ga-xuo89c AC2: every record carries the fds field =="

ALL=0; BAD_REC=0
for L in $(find "$SCRATCH_ROOT" -name supervisor-restart-watchdog.jsonl); do
  ALL=$((ALL + $(wc -l < "$L")))
  BAD_REC=$((BAD_REC + $(jq -c 'select((has("fds") and has("fds_state") and has("guard_action") and has("guard_stamp") and has("pid") and has("delta_guard_restart")) | not)' "$L" | wc -l)))
done
[ "$ALL" -gt 20 ] && [ "$BAD_REC" = "0" ] \
  && ok "AC2: $ALL ledger records across every scenario (ok, warn, restart, unreadable, no_pid...) all carry fds/fds_state/guard_action/guard_stamp/pid" \
  || bad "AC2: $BAD_REC of $ALL records miss a guard field"

echo "== ga-xuo89c: the script is only allowed ONE mutation, and it has to be the guarded one =="

# K. (was: "no kickstart anywhere", ga-b0gltl). The fd guard is the single
#    sanctioned exception; everything else the old test forbade stays forbidden.
#    A static grep on code lines only (comments describe the kickstart freely).
#    It is the backstop — the behavioural proof is L-R above, where every
#    scenario that must not restart asserts kicks=0 against a fake launchctl.
CODE="$SCRATCH_ROOT/code-only.sh"
grep -vE '^[[:space:]]*#' "$SRC" > "$CODE"
if grep -qE 'launchctl[[:space:]]+(bootout|bootstrap|unload|load|stop|start|kill|remove|disable|enable)|pkill|killall|kill[[:space:]]+-(9|QUIT|TERM|KILL)' "$CODE"; then
  bad "K: found a launchctl bootout/unload/stop/kill-style call or a kill in the script — only 'kickstart -k' on the supervisor is sanctioned"
else
  ok "K: no bootout/unload/stop/kill/pkill anywhere in the code"
fi
KS=$(grep -cE 'launchctl[[:space:]]+kickstart' "$CODE")
if [ "$KS" = "1" ] && grep -qE 'launchctl kickstart -k "gui/\$\{UID_NUM\}/\$\{SUPERVISOR_LABEL\}"' "$CODE"; then
  ok "K: exactly one kickstart in the code, -k on gui/\${UID_NUM}/\${SUPERVISOR_LABEL} and nothing else"
else
  bad "K: expected exactly one 'launchctl kickstart -k gui/\${UID_NUM}/\${SUPERVISOR_LABEL}', found $KS kickstart line(s)"
fi
L_KICK=$(grep -n 'launchctl kickstart' "$CODE" | head -1 | cut -d: -f1)
L_COOL=$(grep -n '_srw_guard_state_write null "\${SUP_PID' "$CODE" | head -1 | cut -d: -f1)
[ -n "$L_COOL" ] && [ -n "$L_KICK" ] && [ "$L_COOL" -lt "$L_KICK" ] \
  && ok "K: the cooldown stamp (runs_at_restart=null) is written before the kickstart (a run that dies mid-restart still leaves its cooldown)" \
  || bad "K: cooldown stamp line ${L_COOL:-none} vs kickstart line ${L_KICK:-none}"
# The credit ("this +1 in runs was ours") must come strictly AFTER the kick, and
# nothing before the kick may carry a runs value: a stamp for a restart that has
# not happened yet is exactly what swallowed a real death (gate-fix 1).
L_CREDIT=$(grep -n '_srw_guard_state_write "\$RUNS"' "$CODE" | head -1 | cut -d: -f1)
N_CREDIT=$(grep -c '_srw_guard_state_write "\$RUNS"' "$CODE")
[ "$N_CREDIT" = "1" ] && [ -n "$L_CREDIT" ] && [ -n "$L_KICK" ] && [ "$L_CREDIT" -gt "$L_KICK" ] \
  && ok "K: the only write that carries a runs value comes after the kickstart (nothing is credited before it happened)" \
  || bad "K: $N_CREDIT credit write(s); first at line ${L_CREDIT:-none} vs kickstart line ${L_KICK:-none}"
/bin/bash -n "$SRC" && ok "K: the script parses under /bin/bash $(/bin/bash -c 'echo $BASH_VERSION') (what the plist runs)" || bad "K: syntax error under /bin/bash"

echo
echo "supervisor-restart-watchdog selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1

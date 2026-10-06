#!/usr/bin/env bash
# config-drift-watcher-reload-policy.selftest.sh — ga-mc42px.
#
# The drift watcher's heartbeat used to request "gc reload --soft" every 20s, unconditionally.
# An accepted reload holds the controller's single reload slot until the reconciler tick that
# processes it ends (8-10 min under load), so the watcher kept the slot ~100% occupied and every
# other caller (gc agent resume, the Mayor) was refused "already in progress".
#
# Proves, against the real watcher functions (sourced with CONFIG_DRIFT_WATCHER_LIB=1) and a
# stub `gc`:
#   A. slot_cooldown_secs: duty-cap formula, floor, ceiling, garbage input
#   B. finish_reload: what each outcome schedules (heartbeat / file-change, ok / busy / fail)
#   C. poll_reload_result: result-file hand-off, dead runner, watchdog
#   D. start_reload: really issues the SYNC "gc reload --soft --timeout" (never --async) and
#      maps ok / busy / fail from the client's exit status and text
#   E. reload-stats persistence across a daemon restart
#   F. file-detected drift (acceptance 3): a changed skill file is picked up, debounced and
#      reloaded; a busy slot never drops it; a failing reload is retried a bounded number of
#      times; it outranks the heartbeat and never runs concurrently with one
#   G. before/after slot-occupancy simulation at the measured reload duration (acceptance 1, 2)
#   H. end to end: the real daemon loop against a stub gc (startup marker, log proof, stats)
#
# Run it against another copy of the watcher with WATCHER_UNDER_TEST=<path> (the pre-fix
# watcher must FAIL this file). Works under /bin/bash 3.2 and bash 5.x.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL_CLOSED_LIB="$SELF_DIR/../packs/town-deltas/assets/selftest-fail-closed.lib.sh"
. "$FAIL_CLOSED_LIB" || { echo "FATAL: cannot source $FAIL_CLOSED_LIB" >&2; exit 2; }

WATCHER="${WATCHER_UNDER_TEST:-$SELF_DIR/config-drift-watcher.sh}"
[ -f "$WATCHER" ] || { echo "FATAL: watcher not found: $WATCHER" >&2; exit 2; }

TMP="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/cdw-policy.XXXXXX")" && pwd -P)"
DUMMY_PIDS=""
cleanup() {
    local p
    for p in $DUMMY_PIDS; do kill "$p" 2>/dev/null || true; done
    chflags -R nouchg "$TMP" 2>/dev/null || true   # the e2e daemon leaves .beads/hooks uchg-locked
    rm -rf "$TMP"
}
selftest_fail_closed_arm cleanup

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi; }
le()  { if [ "$2" -le "$3" ] 2>/dev/null; then ok "$1 ($2 <= $3)"; else bad "$1 (got '$2', want <= $3)"; fi; }
ge()  { if [ "$2" -ge "$3" ] 2>/dev/null; then ok "$1 ($2 >= $3)"; else bad "$1 (got '$2', want >= $3)"; fi; }
has() { if grep -F -- "$2" "$3" >/dev/null 2>&1; then ok "$1"; else bad "$1 (no '$2' in $3)"; fi; }
hasnt() { if grep -F -- "$2" "$3" >/dev/null 2>&1; then bad "$1 ('$2' present in $3)"; else ok "$1"; fi; }

echo "config-drift-watcher reload policy selftest (bash $BASH_VERSION, watcher: $WATCHER)"

# ── Source the watcher as a library, with every path inside $TMP ─────────────
export CITY="$TMP/city"
export CONFIG_DRIFT_WATCHER_WA="$TMP/wa"
mkdir -p "$CITY/.gc/state" "$CITY/.gc/logs" "$CITY/skills" "$CITY/agents" "$CITY/scripts" \
         "$CONFIG_DRIFT_WATCHER_WA/crew" "$TMP/bin"
cat > "$TMP/bin/gc" <<'EOF'
#!/bin/sh
# stub gc: records its argv, behaves per $GCSTUB_MODE
echo "$*" >> "${GCSTUB_ARGS:-/dev/null}"
case "${GCSTUB_MODE:-ok}" in
  ok)   sleep 1; echo "Reload complete"; exit 0 ;;
  busy) echo "Reload request could not be accepted because another reload is already in progress."; exit 1 ;;
  fail) echo "controller unreachable"; exit 1 ;;
esac
EOF
cat > "$TMP/bin/notify" <<'EOF'
#!/bin/sh
echo "$*" >> "${NOTIFY_LOG:-/dev/null}"
exit 0
EOF
chmod +x "$TMP/bin/gc" "$TMP/bin/notify"
export GC="$TMP/bin/gc" GCSTUB_ARGS="$TMP/gc.args"
export CONFIG_DRIFT_WATCHER_LIB=1
# shellcheck disable=SC1090
. "$WATCHER" || { echo "FATAL: cannot source $WATCHER" >&2; exit 2; }
unset CONFIG_DRIFT_WATCHER_LIB

# A pre-fix watcher defines none of the reload-policy variables (and STATE_DIR only outside lib
# mode): default them so such a watcher is reported assertion by assertion instead of aborting.
: "${STATE_DIR:=$CITY/.gc/state}"
: "${RELOAD_CLIENT_TIMEOUT:=900}"

# Guard: nothing below may ever write into the real city.
case "${STATE_DIR:-}" in
    "$TMP"/*) ;;
    *) echo "FATAL: STATE_DIR='${STATE_DIR:-}' is outside the temp dir — refusing to run" >&2; exit 2 ;;
esac

# Fake clock + hook/hash seams (the daemon loop itself only adds a sleep around watcher_tick).
FAKE_NOW=1800000000
epoch_now() { echo "$FAKE_NOW"; }
HOOK_CALLS=0
check_hooks_guard() { HOOK_CALLS=$((HOOK_CALLS + 1)); }
HASH_MODE=real
FAKE_HASH=h0
if declare -F compute_hash >/dev/null; then
    eval "$(declare -f compute_hash | sed '1s/compute_hash/real_compute_hash/')"
fi
compute_hash() { if [ "$HASH_MODE" = real ]; then real_compute_hash; else echo "$FAKE_HASH"; fi; }

START_LOG=""
reset_state() {
    rm -f "$RELOAD_STATS_FILE" "$RELOAD_RESULT_FILE" "$RELOAD_RESULT_FILE.tmp" 2>/dev/null || true
    prev_hash=""; last_change_time=0; pending_reload=false; last_beat_time=0; last_hooks_check=0
    RELOAD_PID=""; RELOAD_TRIGGER=""; RELOAD_STARTED=0
    hb_next_allowed=0; file_next_allowed=0; file_fail_count=0; file_busy_streak=0
    last_reload_secs=0; reload_held_total=0; reload_count=0; watcher_started_at=$FAKE_NOW
    stats_carried_over=false
    HOOK_CALLS=0; START_LOG=""
}
TICKLOG="$TMP/tick.log"
: > "$TICKLOG"

echo "== precondition: the watcher exposes the reload-policy functions"
HAVE_POLICY=1
for fn in slot_cooldown_secs finish_reload poll_reload_result start_reload watcher_tick \
          heartbeat_due file_reload_due load_reload_stats slot_duty_line; do
    if declare -F "$fn" >/dev/null; then ok "function $fn exists"; else bad "function $fn missing (pre-fix watcher?)"; HAVE_POLICY=0; fi
done
if [ "$HAVE_POLICY" = 1 ]; then   # groups A-G (not re-indented): unit + simulation tests need the policy functions

# ── A. slot_cooldown_secs ────────────────────────────────────────────────────
echo "== A. slot_cooldown_secs (duty cap formula)"
eq "no history (held 0) -> floor"                 20   "$(slot_cooldown_secs 0 10 20)"
eq "fast reload (2s) stays at the 20s floor"      20   "$(slot_cooldown_secs 2 10 20)"
eq "3s reload -> 27s (9x)"                        27   "$(slot_cooldown_secs 3 10 20)"
eq "60s reload -> 540s"                           540  "$(slot_cooldown_secs 60 10 20)"
eq "600s reload (the incident) -> 5400s"          5400 "$(slot_cooldown_secs 600 10 20)"
eq "absurd reload is capped at HEARTBEAT_MAX_INTERVAL" "$HEARTBEAT_MAX_INTERVAL" "$(slot_cooldown_secs 36000 10 20)"
eq "50% duty, 600s -> 600s (file-change cap)"     600  "$(slot_cooldown_secs 600 50 2)"
eq "garbage held -> floor, no crash"              20   "$(slot_cooldown_secs abc 10 20)"
eq "empty held -> floor, no crash"                20   "$(slot_cooldown_secs '' 10 20)"
eq "negative held -> floor, no crash"             20   "$(slot_cooldown_secs -5 10 20)"
eq "duty 0 is clamped to 1 (no division by zero)" "$HEARTBEAT_MAX_INTERVAL" "$(slot_cooldown_secs 600 0 20)"
eq "duty 100 -> no cooldown beyond the floor"     20   "$(slot_cooldown_secs 600 100 20)"
eq "duty >100 is clamped to 100"                  20   "$(slot_cooldown_secs 600 250 20)"
worst=0
d=3
while [ "$d" -le 800 ]; do
    cdn=$(slot_cooldown_secs "$d" 10 20)
    duty=$(( d * 100 / (d + cdn) ))
    [ "$duty" -gt "$worst" ] && worst=$duty
    d=$((d + 1))
done
le "for every held time 3..800s the resulting slot duty never exceeds the 10% cap" "$worst" 10

# ── B. finish_reload ─────────────────────────────────────────────────────────
echo "== B. finish_reload scheduling"
N=$FAKE_NOW
reset_state
finish_reload heartbeat ok 600 0 "Reload complete" "$N" >> "$TICKLOG"
eq "heartbeat ok(600s): next heartbeat +5400s"     $((N + 5400)) "$hb_next_allowed"
eq "heartbeat ok(600s): next file reload +600s"    $((N + 600))  "$file_next_allowed"
eq "heartbeat ok: D remembered"                    600 "$last_reload_secs"
eq "heartbeat ok: counted"                         1 "$reload_count"
eq "heartbeat ok: held time accumulated"           600 "$reload_held_total"
has "heartbeat ok: log carries the cumulative slot-duty proof" "own slot duty since start" "$TICKLOG"

reset_state
finish_reload heartbeat ok 1 0 "" "$N" >> "$TICKLOG"
eq "fast reload (1s): heartbeat cadence stays at the 20s floor" $((N + 20)) "$hb_next_allowed"

reset_state; last_reload_secs=600
finish_reload heartbeat busy 0 1 "already in progress" "$N" >> "$TICKLOG"
eq "heartbeat refused as busy: backs off a full cooldown (not 20s)" $((N + 5400)) "$hb_next_allowed"
eq "heartbeat busy: a refusal is not a hold (count unchanged)"      0 "$reload_count"
eq "heartbeat busy: D not overwritten"                              600 "$last_reload_secs"

reset_state
finish_reload heartbeat busy 0 1 "already in progress" "$N" >> "$TICKLOG"
eq "heartbeat busy with no history: floor"        $((N + 20)) "$hb_next_allowed"

reset_state
pending_reload=false
finish_reload file-change busy 0 1 "already in progress" "$N" >> "$TICKLOG"
eq "file change refused as busy: stays pending"        true "$pending_reload"
eq "file change busy: retry in FILE_RETRY_WAIT"        $((N + FILE_RETRY_WAIT)) "$file_next_allowed"
eq "file change busy: heartbeat embargo untouched"     0 "$hb_next_allowed"

reset_state
n=0
while [ "$n" -lt 3 ]; do
    pending_reload=false
    finish_reload file-change fail 2 1 "controller unreachable" "$N" >> "$TICKLOG"
    n=$((n + 1))
    eq "file change failure $n/3: retried (pending)" true "$pending_reload"
done
pending_reload=false
finish_reload file-change fail 2 1 "controller unreachable" "$N" >> "$TICKLOG"
eq "file change 4th failure: gives up (heartbeat covers it)" false "$pending_reload"
eq "file change give-up resets the failure streak"           0 "$file_fail_count"

reset_state; file_fail_count=2
finish_reload file-change ok 5 0 "ok" "$N" >> "$TICKLOG"
eq "file change success clears the failure streak" 0 "$file_fail_count"

# ── C. poll_reload_result ────────────────────────────────────────────────────
echo "== C. poll_reload_result"
reap_start() {   # a stand-in runner: writes a result file after a pause, then exits (like start_reload's subshell)
    ( trap - EXIT; sleep "$1"; printf '%s\n%s\n' "$2" "$3" > "$RELOAD_RESULT_FILE.tmp" && mv "$RELOAD_RESULT_FILE.tmp" "$RELOAD_RESULT_FILE" ) &
    RELOAD_PID=$!
}
reset_state; RELOAD_TRIGGER=heartbeat; RELOAD_STARTED=$FAKE_NOW
reap_start 2 "ok 42 0" "Reload complete"
poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
if [ -n "$RELOAD_PID" ]; then ok "in flight: no result yet, runner left alone"; else bad "in flight reload was reaped early"; fi
sleep 3
poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
eq "finished: runner reaped"            "" "$RELOAD_PID"
eq "finished: D taken from the result"  42 "$last_reload_secs"
eq "finished: heartbeat cooled down"    $((FAKE_NOW + 378)) "$hb_next_allowed"
eq "finished: result file consumed"     "no" "$([ -e "$RELOAD_RESULT_FILE" ] && echo yes || echo no)"

reset_state; RELOAD_TRIGGER=file-change; RELOAD_STARTED=$FAKE_NOW
reap_start 0 "garbage" "x"
sleep 1
poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
eq "unreadable result counts as a failed file-change reload (retried)" true "$pending_reload"

reset_state; RELOAD_TRIGGER=heartbeat; RELOAD_STARTED=$((FAKE_NOW - 5))
( trap - EXIT; exit 0 ) &   # (a subshell's explicit exit would otherwise run THIS script's EXIT trap and wipe $TMP)
RELOAD_PID=$!
sleep 1
poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
eq "runner died without a result: slot freed for the next decision" "" "$RELOAD_PID"
eq "runner died without a result: counted as a held failure"        1 "$reload_count"
has "runner died without a result: logged" "exited without a result" "$TICKLOG"

reset_state; RELOAD_TRIGGER=heartbeat
RELOAD_STARTED=$((FAKE_NOW - RELOAD_CLIENT_TIMEOUT - RELOAD_WATCHDOG_GRACE - 1))
# A hung client. It must have exec'd `sleep` before it is killed: a bash child that gets SIGTERM
# between fork and exec runs this script's inherited EXIT trap (cleanup + FATAL) — seen on 3.2 under load.
( trap - EXIT; exec sleep 60 ) &
RELOAD_PID=$!
DUMMY_PIDS="$DUMMY_PIDS $RELOAD_PID"
HUNG=$RELOAD_PID
sleep 0.5
poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
sleep 0.3
if kill -0 "$HUNG" 2>/dev/null; then bad "watchdog: stuck client was not killed"; else ok "watchdog: stuck client killed"; fi
eq "watchdog: slot freed" "" "$RELOAD_PID"
has "watchdog: logged" "killed" "$TICKLOG"

# ── D. start_reload against the stub gc ──────────────────────────────────────
echo "== D. start_reload (real runner, stub gc)"
wait_reload() {   # poll until the background reload is reaped (max ~15s)
    local i=0
    while [ -n "$RELOAD_PID" ] && [ "$i" -lt 60 ]; do
        sleep 0.25
        poll_reload_result "$FAKE_NOW" >> "$TICKLOG"
        i=$((i + 1))
    done
}
reset_state; : > "$GCSTUB_ARGS"
export GCSTUB_MODE=ok; start_reload heartbeat "$FAKE_NOW" >> "$TICKLOG"
wait_reload
eq "ok: reaped" "" "$RELOAD_PID"
ge "ok: D measured from the real wall time (stub sleeps 1s)" "$last_reload_secs" 1
eq "ok: counted" 1 "$reload_count"
has   "gc is called synchronously with a timeout above the controller TTL" "reload --soft --timeout ${RELOAD_CLIENT_TIMEOUT}s --city $CITY" "$GCSTUB_ARGS"
hasnt "gc is never called with --async (its wall time would not be the slot hold time)" "--async" "$GCSTUB_ARGS"

reset_state
export GCSTUB_MODE=busy; start_reload heartbeat "$FAKE_NOW" >> "$TICKLOG"
wait_reload
eq "busy: no hold counted"                 0 "$reload_count"
eq "busy: heartbeat backs off (floor, no history)" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"

reset_state
export GCSTUB_MODE=busy; start_reload file-change "$FAKE_NOW" >> "$TICKLOG"
wait_reload
eq "busy on a file-change reload: file change stays pending" true "$pending_reload"

reset_state
export GCSTUB_MODE=fail; start_reload file-change "$FAKE_NOW" >> "$TICKLOG"
wait_reload
eq "fail on a file-change reload: counted and retried" "1 true" "$reload_count $pending_reload"

# ── E. persistence across restarts ───────────────────────────────────────────
echo "== E. reload-stats persistence (delivery restarts the daemon)"
reset_state
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG"
saved_hb=$hb_next_allowed
last_reload_secs=0                                   # a fresh process knows nothing…
hb_next_allowed=$((FAKE_NOW + HEARTBEAT_INTERVAL))   # …but its own startup default
load_reload_stats "$FAKE_NOW"
eq "restart: last reload duration carried over" 600 "$last_reload_secs"
eq "restart: heartbeat embargo carried over (a restart does not re-open the slot to the watcher)" "$saved_hb" "$hb_next_allowed"
eq "restart: the stats are reported as carried over" true "$stats_carried_over"

reset_state; hb_next_allowed=$((FAKE_NOW + 20))
echo "not numbers at all" > "$RELOAD_STATS_FILE"
load_reload_stats "$FAKE_NOW"
eq "garbage stats file is ignored" "0 $((FAKE_NOW + 20))" "$last_reload_secs $hb_next_allowed"
eq "garbage stats file is NOT reported as carried over" false "$stats_carried_over"

reset_state; hb_next_allowed=$((FAKE_NOW + 20))
echo "600 $((FAKE_NOW + 99999999))" > "$RELOAD_STATS_FILE"
load_reload_stats "$FAKE_NOW"
eq "an embargo far beyond the ceiling is ignored (clock skew / corruption)" $((FAKE_NOW + 20)) "$hb_next_allowed"

# ── F. file-detected drift through watcher_tick ──────────────────────────────
echo "== F. file-detected drift (acceptance 3): real compute_hash, fake clock + slot"
SIM_T0=$FAKE_NOW
SLOT_BUSY_UNTIL=0; SIM_DONE_AT=0; SIM_OUTCOME=ok; SIM_HELD=0; SIM_D=600; SIM_FORCE=""; DUP_STARTS=0
start_reload() {
    local trigger="$1" now="$2"
    [ -z "$RELOAD_PID" ] || DUP_STARTS=$((DUP_STARTS + 1))
    RELOAD_TRIGGER="$trigger"; RELOAD_STARTED="$now"; RELOAD_PID=sim
    if [ "$SIM_FORCE" = fail ]; then
        SIM_OUTCOME=fail; SIM_HELD=2; SIM_DONE_AT=$((now + 2))
    elif [ "$now" -ge "$SLOT_BUSY_UNTIL" ]; then
        SIM_OUTCOME=ok; SIM_HELD=$SIM_D; SLOT_BUSY_UNTIL=$((now + SIM_D)); SIM_DONE_AT=$((now + SIM_D))
    else
        SIM_OUTCOME=busy; SIM_HELD=0; SIM_DONE_AT=$now
    fi
    START_LOG="$START_LOG ${trigger}@$((now - SIM_T0))=$SIM_OUTCOME"
}
poll_reload_result() {
    local now="$1"
    [ -n "$RELOAD_PID" ] || return 0
    if [ "$now" -ge "$SIM_DONE_AT" ]; then
        RELOAD_PID=""
        finish_reload "$RELOAD_TRIGGER" "$SIM_OUTCOME" "$SIM_HELD" 0 "sim" "$now"
    fi
}
sim_reset() {   # fresh daemon at SIM_T0, slot free, nothing pending
    FAKE_NOW=$SIM_T0
    reset_state
    SLOT_BUSY_UNTIL=0; SIM_DONE_AT=0; SIM_OUTCOME=ok; SIM_HELD=0; SIM_FORCE=""; DUP_STARTS=0
    prev_hash=$(compute_hash)
    last_beat_time=$FAKE_NOW
    hb_next_allowed=$((FAKE_NOW + HEARTBEAT_INTERVAL))   # what the daemon does at startup
}
ticks() { local i=0; while [ "$i" -lt "$1" ]; do FAKE_NOW=$((FAKE_NOW + POLL_INTERVAL)); watcher_tick "$FAKE_NOW" >> "$TICKLOG"; i=$((i + 1)); done; }
starts_matching() { printf '%s\n' $START_LOG | grep -c "$1" || true; }

# F1. a changed skill file is detected, debounced, reloaded — the original protection
: > "$TICKLOG"
HASH_MODE=real
sim_reset; SIM_D=1
echo "# skill v1" > "$CITY/skills/demo.md"
prev_hash=$(compute_hash)
ticks 2
eq "no file change, heartbeat not yet due: no reload at all" "" "$(printf '%s' "$START_LOG" | tr -d ' ')"
echo "# skill v2 — a longer body so the size differs" >> "$CITY/skills/demo.md"
ticks 1
has "changed skill file is noticed" "Hash changed" "$TICKLOG"
eq "…but debounced: no reload in the same tick" "" "$(printf '%s' "$START_LOG" | tr -d ' ')"
ticks 1
eq "…and requested one tick later, as a file-change reload" "1" "$(starts_matching '^file-change@')"
ticks 3
eq "the file-change reload was accepted" "1" "$(starts_matching '^file-change@[0-9]*=ok')"
eq "nothing is left pending afterwards" false "$pending_reload"

# F2. drift while the heartbeat's reload is in flight: no second concurrent reload; the file
#     change waits for the slot-duty cooldown, then runs BEFORE the next heartbeat
HASH_MODE=fake; FAKE_HASH=h0
sim_reset; SIM_D=600
ticks 10                                     # heartbeat starts at +21s and holds the slot 600s
eq "heartbeat reload started at +21s" "heartbeat@21=ok" "$(printf '%s' "$START_LOG" | tr -d ' ')"
FAKE_HASH=h1; ticks 50                       # file change at ~+51s, mid-hold
eq "file change during an in-flight reload does not start a second one" 0 "$DUP_STARTS"
eq "…and only the heartbeat has started so far" 1 "$(printf '%s\n' $START_LOG | grep -c .)"
eq "…the change is held pending" true "$pending_reload"
ticks 400                                    # past hold (+621s) and file cooldown (600s -> +1221s)
eq "file change ran after the cooldown, before any new heartbeat" "heartbeat@21=ok file-change@1221=ok" "$(printf '%s' "$START_LOG" | sed 's/^ //')"
eq "no concurrent reloads at any point" 0 "$DUP_STARTS"

# F3. a busy slot never drops a file change (retried every FILE_RETRY_WAIT until accepted),
#     and the heartbeat stays out of the way meanwhile
sim_reset; SIM_D=600
hb_next_allowed=$((FAKE_NOW + 100000))
SLOT_BUSY_UNTIL=$((FAKE_NOW + 100))          # someone else (peter's job, the Mayor) holds the slot
FAKE_HASH=h2; ticks 60
busy_n=$(starts_matching '^file-change@[0-9]*=busy')
ge "file change retried while the slot is busy" "$busy_n" 5
le "…without hammering the controller (>= ${FILE_RETRY_WAIT}s apart)" "$busy_n" 8
eq "file change accepted once the slot freed" "1" "$(starts_matching '^file-change@[0-9]*=ok')"
first_ok=$(printf '%s\n' $START_LOG | sed -n 's/^file-change@\([0-9]*\)=ok$/\1/p' | head -1)
ge "accepted no earlier than the slot freeing"      "$first_ok" 100
le "accepted within one retry interval of the slot freeing" "$first_ok" $((100 + FILE_RETRY_WAIT + 2 * POLL_INTERVAL))
eq "no heartbeat started while the file change was pending" 0 "$(starts_matching '^heartbeat@')"
eq "nothing left pending" false "$pending_reload"

# F4. a failing reload is retried a bounded number of times, then left to the backstop
sim_reset; SIM_FORCE=fail; SIM_D=600
FAKE_HASH=h3; ticks 80
eq "failing file-change reload: 1 try + $FILE_MAX_FAIL_RETRIES retries" $((FILE_MAX_FAIL_RETRIES + 1)) "$(starts_matching '^file-change@')"
eq "…then not pending any more (no retry storm)" false "$pending_reload"

# F5. the hooks guard keeps its 20s beat even while reloads are throttled
sim_reset; SIM_D=600; HOOK_CALLS=0
ticks 100                                    # 300 s
ge "hooks guard ran on the heartbeat beat during 300s" "$HOOK_CALLS" 15

# ── G. before/after slot occupancy at the measured reload duration ───────────
echo "== G. simulation: the controller's single reload slot, reload duration D=600s (measured 05/10)"
SIM_HOURS="${SIM_HOURS:-6}"
sim_dims() {   # $1 = tick length (s): ticks in the horizon, a probe every 60s, 20 min tail so each probe can find the slot free
    SIM_STEP=$1
    G_TICKS=$(( SIM_HOURS * 3600 / SIM_STEP ))
    PROBE_EVERY=$(( 60 / SIM_STEP ))
    TAIL_TICKS=$(( 1200 / SIM_STEP ))
}
SIM_FREE=()
sim_stats() {   # from SIM_FREE[0..G_TICKS-1]: duty, and how long a caller arriving at each probe waits for a free slot
    local n="$1" a j held=0 w tot=0 cnt=0 max=0 fast=0
    j=0
    while [ "$j" -lt "$n" ]; do [ "${SIM_FREE[$j]}" = 0 ] && held=$((held + 1)); j=$((j + 1)); done
    SIM_DUTY=$(( held * 100 / n ))
    a=0
    while [ "$a" -lt $((n - TAIL_TICKS)) ]; do
        j=$a
        while [ "$j" -lt "$n" ] && [ "${SIM_FREE[$j]}" = 0 ]; do j=$((j + 1)); done
        w=$(( (j - a) * SIM_STEP ))
        tot=$((tot + w)); cnt=$((cnt + 1))
        [ "$w" -gt "$max" ] && max=$w
        [ "$w" -le 120 ] && fast=$((fast + 1))
        a=$((a + PROBE_EVERY))
    done
    SIM_MAXWAIT=$max
    SIM_MEANWAIT=$(( tot / cnt ))
    SIM_FAST_PCT=$(( fast * 100 / cnt ))
}

# G1. BEFORE: the old policy — try a reload every 20s (3s poll), unconditionally; accepted when the slot is free
sim_dims "$POLL_INTERVAL"   # the old loop really ticks every POLL_INTERVAL (3s) and costs nothing to simulate
FAKE_NOW=$SIM_T0; SLOT_BUSY_UNTIL=0; SIM_D=600; last_hb=$FAKE_NOW; legacy_accepted=0
SIM_FREE=()
i=0
while [ "$i" -lt "$G_TICKS" ]; do
    FAKE_NOW=$((FAKE_NOW + SIM_STEP))
    if [ "$FAKE_NOW" -ge "$SLOT_BUSY_UNTIL" ]; then SIM_FREE[$i]=1; else SIM_FREE[$i]=0; fi
    if [ $((FAKE_NOW - last_hb)) -ge 20 ]; then
        last_hb=$FAKE_NOW
        if [ "$FAKE_NOW" -ge "$SLOT_BUSY_UNTIL" ]; then SLOT_BUSY_UNTIL=$((FAKE_NOW + SIM_D)); legacy_accepted=$((legacy_accepted + 1)); fi
    fi
    i=$((i + 1))
done
sim_stats "$G_TICKS"
LEGACY_DUTY=$SIM_DUTY; LEGACY_MAX=$SIM_MAXWAIT; LEGACY_MEAN=$SIM_MEANWAIT; LEGACY_FAST=$SIM_FAST_PCT
echo "  before (unconditional 20s heartbeat): slot held ${LEGACY_DUTY}% of ${SIM_HOURS}h, ${legacy_accepted} watcher reloads; a caller arriving every 60s waits mean ${LEGACY_MEAN}s / max ${LEGACY_MAX}s, ${LEGACY_FAST}% served within 2 min"

# G2. AFTER: the real watcher_tick, real finish_reload/cooldown logic, simulated slot
# 9s ticks (the daemon ticks every 3s): the cadence is set by the cooldown, a coarser tick only
# delays a start by <= 6s, and each tick of the real watcher_tick costs a fork under load.
sim_dims $(( POLL_INTERVAL * 3 ))
HASH_MODE=fake; FAKE_HASH=h0
sim_reset; SIM_D=600
SIM_FREE=()
: > "$TICKLOG"
i=0
while [ "$i" -lt "$G_TICKS" ]; do
    FAKE_NOW=$((FAKE_NOW + SIM_STEP))
    if [ "$FAKE_NOW" -ge "$SLOT_BUSY_UNTIL" ]; then SIM_FREE[$i]=1; else SIM_FREE[$i]=0; fi
    watcher_tick "$FAKE_NOW" >> "$TICKLOG"
    i=$((i + 1))
done
sim_stats "$G_TICKS"
NEW_DUTY=$SIM_DUTY; NEW_MAX=$SIM_MAXWAIT; NEW_MEAN=$SIM_MEANWAIT; NEW_FAST=$SIM_FAST_PCT
new_accepted=$(starts_matching '^heartbeat@[0-9]*=ok')
echo "  after  (duty-capped heartbeat):       slot held ${NEW_DUTY}% of ${SIM_HOURS}h, ${new_accepted} watcher reloads; a caller arriving every 60s waits mean ${NEW_MEAN}s / max ${NEW_MAX}s, ${NEW_FAST}% served within 2 min"

ge "before: the old policy keeps the slot occupied nearly all the time (model reproduces the incident)" "$LEGACY_DUTY" 90
le "after: the watcher holds the slot at most ~10% of the time (cap + boundary effects)" "$NEW_DUTY" 12
le "after: a caller waits at most for the remaining hold of ONE reload (D + a tick)" "$NEW_MAX" $((SIM_D + 2 * SIM_STEP))
ge "after: most external callers get the slot within 2 min" "$NEW_FAST" 80
le "before: the old policy served few callers within 2 min" "$LEGACY_FAST" 40
ge "after: the backstop heartbeat is still alive (not disabled)" "$new_accepted" 3
if [ "$LEGACY_MEAN" -ge $(( NEW_MEAN * 5 )) ]; then ok "mean wait ${LEGACY_MEAN}s -> ${NEW_MEAN}s (>= 5x)"; else bad "mean wait ${LEGACY_MEAN}s -> ${NEW_MEAN}s is not >= 5x better"; fi
eq "after: never two reloads of the watcher in flight" 0 "$DUP_STARTS"
min_gap=999999; prev_t=""
for t in $(printf '%s\n' $START_LOG | sed -n 's/^heartbeat@\([0-9]*\)=ok$/\1/p'); do
    if [ -n "$prev_t" ] && [ $((t - prev_t)) -lt "$min_gap" ]; then min_gap=$((t - prev_t)); fi
    prev_t=$t
done
ge "after: consecutive heartbeat reloads leave a free window (>= D*9 = 5400s)" "$min_gap" $((SIM_D * 9 - SIM_STEP))
has "after: the log shows the cumulative slot duty" "own slot duty since start" "$TICKLOG"

else
    bad "groups A-G skipped: the watcher under test has no reload policy (pre-fix watcher)"
fi

# ── H. end to end: the real daemon loop, stub gc ─────────────────────────────
echo "== H. end to end (real daemon loop, ~10s)"
E2E="$TMP/e2e"
mkdir -p "$E2E/.gc/state" "$E2E/.gc/logs" "$E2E/skills" "$TMP/e2e-wa"
E2E_LOG="$E2E/.gc/logs/config-drift-watcher.log"
: > "$TMP/e2e.gc.args"
(
    CITY="$E2E" CONFIG_DRIFT_WATCHER_WA="$TMP/e2e-wa" GC="$TMP/bin/gc" GCSTUB_ARGS="$TMP/e2e.gc.args" \
    GCSTUB_MODE=ok NOTIFY_LOG="$TMP/notify.log" PATH="$TMP/bin:$PATH" \
        exec "$BASH" "$WATCHER"
) >/dev/null 2>&1 &
DPID=$!
DUMMY_PIDS="$DUMMY_PIDS $DPID"
i=0
while [ "$i" -lt 60 ]; do    # the daemon takes its initial hash at startup; only change a file after that
    grep -F "Initial hash" "$E2E_LOG" >/dev/null 2>&1 && break
    sleep 0.5; i=$((i + 1))
done
echo "# new skill" > "$E2E/skills/e2e.md"
i=0
while [ "$i" -lt 60 ]; do
    grep -F "own slot duty since start" "$E2E_LOG" >/dev/null 2>&1 && break   # the last line finish_reload logs
    sleep 0.5; i=$((i + 1))
done
kill "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null || true
has "daemon started" "config-drift-watcher started" "$E2E_LOG"
has "startup marker written (delivery freshness check, ga-fbjg)" "$DPID " "$E2E/.gc/state/config-drift-watcher.startup"
has "file change detected" "Hash changed" "$E2E_LOG"
has "file-change reload requested" "reload[file-change] requested" "$E2E_LOG"
has "file-change reload completed, hold time logged" "reload[file-change] OK after" "$E2E_LOG"
has "slot-duty proof line in the log" "own slot duty since start" "$E2E_LOG"
has   "gc called as sync reload with timeout" "reload --soft --timeout ${RELOAD_CLIENT_TIMEOUT}s --city $E2E" "$TMP/e2e.gc.args"
hasnt "gc never called with --async" "--async" "$TMP/e2e.gc.args"
if [ -s "$E2E/.gc/state/config-drift-watcher.reload-stats" ]; then ok "reload stats persisted"; else bad "reload stats not persisted"; fi

echo
echo "PASS=$PASS FAIL=$FAIL"
selftest_summary_reached
[ "$FAIL" -eq 0 ]

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
#   A. slot_cooldown_secs: duty-cap formula, floor, ceiling, garbage input (incl. leading zeros)
#   B. finish_reload: what each outcome schedules (heartbeat / file-change, ok / busy / fail), and
#      that an UNKNOWN hold time is never read as "0s" (the third state) and a failure never
#      overwrites the learned D; B5: a D that was NEVER learned travels save -> load -> startup log
#      as "not learned" ('-' on disk), never as a measured 0s
#   C. poll_reload_result: result-file hand-off, the runner-finished-between-two-checks race, dead
#      runner, and the watchdog against the REAL runner topology (a hanging stub gc: no process
#      of the tree may survive; and when pgrep cannot enumerate the tree the log says the client
#      is NOT confirmed killed instead of "killed")
#   D. start_reload: really issues the SYNC "gc reload --soft --timeout" (never --async) and
#      maps ok / busy / fail from the client's exit status and text; a stale result it cannot
#      clear is said, not swallowed
#   E. the restart gap: reload stats persist across a daemon restart (a failed save is logged,
#      never silent, and the log says what the restart will do WITH or WITHOUT an earlier record on
#      disk), and drift that straddles the restart (files changed while down, or a reload still
#      pending) is NOT dropped and NOT hidden behind the carried-over embargo
#   F. file-detected drift (acceptance 3): a changed skill file is picked up, debounced and
#      reloaded; a busy slot never drops it; a failing reload is retried a bounded number of
#      times; it outranks the heartbeat and never runs concurrently with one; a restart with an
#      active embargo does not delay it
#   G. before/after slot-occupancy simulation at the measured reload duration (acceptance 1, 2)
#   H. end to end: the real daemon loop against a stub gc, over three lives of the daemon
#      (startup marker, log proof, stats, restart gap unchanged / changed)
#
# Run it against another copy of the watcher with WATCHER_UNDER_TEST=<path> (the pre-fix
# watcher must FAIL this file). Works under /bin/bash 3.2 and bash 5.x.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FAIL_CLOSED_LIB="$SELF_DIR/../packs/town-deltas/assets/selftest-fail-closed.lib.sh"
. "$FAIL_CLOSED_LIB" || { echo "FATAL: cannot source $FAIL_CLOSED_LIB" >&2; exit 2; }

WATCHER="${WATCHER_UNDER_TEST:-$SELF_DIR/config-drift-watcher.sh}"
[ -f "$WATCHER" ] || { echo "FATAL: watcher not found: $WATCHER" >&2; exit 2; }

# $TMP is rm -rf'd on exit, so it must be a directory this run really created. On bash 3.2
# `cd "$(mktemp -d ...)"` with a failing mktemp is `cd ""`, which succeeds and leaves TMP=$PWD.
TMP_MADE="$(mktemp -d "${TMPDIR:-/tmp}/cdw-policy.XXXXXX")" || { echo "FATAL: mktemp -d failed" >&2; exit 2; }
if [ -z "$TMP_MADE" ] || [ ! -d "$TMP_MADE" ]; then echo "FATAL: mktemp -d gave no directory ('$TMP_MADE')" >&2; exit 2; fi
TMP="$(cd "$TMP_MADE" && pwd -P)" || { echo "FATAL: cannot enter $TMP_MADE" >&2; exit 2; }
case "$TMP" in
    ''|/|"$PWD"|"$HOME"|"$SELF_DIR") echo "FATAL: refusing to use '$TMP' as the scratch dir" >&2; exit 2 ;;
esac
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
  ok)   sleep "${GCSTUB_SLEEP:-1}"; echo "Reload complete"; exit 0 ;;
  hang) # a client that never returns: record its pid and its child's, like a real hung gc + helper
        echo $$ >> "${GCSTUB_PIDS:-/dev/null}"
        sleep 300 &
        echo $! >> "${GCSTUB_PIDS:-/dev/null}"
        wait ;;
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
reset_state() {   # a fresh in-memory state; "keep-files" = a fresh PROCESS (the stats file on disk survives)
    if [ "${1:-}" != keep-files ]; then
        rm -f "$RELOAD_STATS_FILE" "$RELOAD_RESULT_FILE" "$RELOAD_RESULT_FILE.tmp" 2>/dev/null || true
    fi
    prev_hash=""; last_change_time=0; pending_reload=false; last_beat_time=0; last_hooks_check=0
    RELOAD_PID=""; RELOAD_TRIGGER=""; RELOAD_STARTED=0; RELOAD_COVERS_HASH=""
    hb_next_allowed=0; file_next_allowed=0; file_fail_count=0; file_busy_streak=0
    last_reload_secs=""; reload_held_total=0; reload_count=0; reload_unknown_count=0   # D "" = never learned (NOT 0s)
    watcher_started_at=$FAKE_NOW
    stats_carried_over=false
    covered_hash=""; startup_gap_verdict=""; startup_gap_note=""
    HOOK_CALLS=0; START_LOG=""
}
TICKLOG="$TMP/tick.log"
: > "$TICKLOG"

# kill seams. RACE_ON=1: the next `kill -0` first lets the runner "finish" (writes its result)
# and then reports it gone — a runner that ends between poll_reload_result's two looks.
# SHIELD_PID: TERM/KILL aimed at it are swallowed — a process that survives SIGKILL.
RACE_ON=0
SHIELD_PID=""
kill() {
    local a
    if [ "$RACE_ON" = 1 ] && [ "${1:-}" = "-0" ]; then
        RACE_ON=0
        printf 'ok 42 0\nReload complete\n' > "$RELOAD_RESULT_FILE"
        return 1
    fi
    if [ -n "$SHIELD_PID" ] && [ "${1:-}" != "-0" ]; then
        for a in "$@"; do [ "$a" = "$SHIELD_PID" ] && return 0; done
    fi
    builtin kill "$@"
}

need_fn() {   # need_fn <name> — true when the watcher under test has it; else ONE failing assertion naming it
    if declare -F "$1" >/dev/null; then return 0; fi
    bad "function $1 missing in the watcher under test"
    return 1
}

startup_replay() {   # what the daemon does at startup, on the fake clock
    if declare -F init_watcher_state >/dev/null; then
        init_watcher_state "$FAKE_NOW"
    else   # the reviewed watcher (gate FAIL 1/3) kept this inline below its library guard: replay it literally
        watcher_started_at=$FAKE_NOW
        prev_hash=$(compute_hash)
        last_beat_time=$FAKE_NOW
        hb_next_allowed=$(( FAKE_NOW + HEARTBEAT_INTERVAL ))
        load_reload_stats "$FAKE_NOW"
    fi
}

real_reload() {   # start_reload, with this script's EXIT trap off while its runner subshell is forked:
    # on bash 3.2 a subshell inherits the trap, so SIGTERMing the runner tree (the watchdog test) would run
    # cleanup() and delete $TMP under the rest of the run. The trap is re-armed right after.
    trap - EXIT
    start_reload "$@"
    selftest_fail_closed_arm cleanup
}

: "${HEARTBEAT_BUSY_RETRY_MAX:=300}"   # a watcher without these gets the intended values, and is judged against them
: "${RELOAD_UNKNOWN_HELD_ASSUMED:=600}"
: "${RELOAD_WATCHDOG_GRACE:=120}"

echo "== precondition: the watcher exposes the reload-policy functions"
HAVE_POLICY=1
for fn in slot_cooldown_secs finish_reload poll_reload_result start_reload watcher_tick \
          heartbeat_due file_reload_due load_reload_stats slot_duty_line; do
    if declare -F "$fn" >/dev/null; then ok "function $fn exists"; else bad "function $fn missing (pre-fix watcher?)"; HAVE_POLICY=0; fi
done
# the helpers of the gate-FAIL-1/3 fix: absent (reviewed watcher), the tests that need them say so by name
for fn in uint_or_empty hash_is_known clamp_duty_pct init_watcher_state descendants_of kill_process_tree consume_reload_result \
          secs_txt startup_stats_line clear_stale_reload_result; do
    need_fn "$fn" && ok "function $fn exists"
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
# Leading zeros are DECIMAL. "08" in $(( )) is an octal error that aborts a bash 3.2 daemon (KeepAlive: a crash loop).
eq "duty '08' is 8%, not an octal error: 600s -> 6900s" 6900 "$(slot_cooldown_secs 600 08 20)"
eq "held '0600' is 600s"                          5400 "$(slot_cooldown_secs 0600 10 20)"
eq "a digit string too long to be seconds -> floor" 20 "$(slot_cooldown_secs 99999999999999999999 10 20)"
if need_fn uint_or_empty; then
    eq "uint_or_empty 007 -> 7"                 7  "$(uint_or_empty 007)"
    eq "uint_or_empty 0 -> 0 (zero is a number)" 0 "$(uint_or_empty 0)"
    eq "uint_or_empty '' -> nothing (not zero)" "" "$(uint_or_empty '')"
    eq "uint_or_empty -5 -> nothing"            "" "$(uint_or_empty -5)"
    eq "uint_or_empty 12x -> nothing"           "" "$(uint_or_empty 12x)"
fi
if need_fn clamp_duty_pct; then
    eq "clamp_duty_pct 0 -> 1"        1   "$(clamp_duty_pct 0)"
    eq "clamp_duty_pct 250 -> 100"    100 "$(clamp_duty_pct 250)"
    eq "clamp_duty_pct garbage -> 10" 10  "$(clamp_duty_pct banana)"
    eq "clamp_duty_pct 08 -> 8"       8   "$(clamp_duty_pct 08)"
fi
if need_fn hash_is_known; then
    if hash_is_known 0123456789abcdef0123456789abcdef; then ok "hash_is_known: an md5 is known"; else bad "hash_is_known rejected an md5"; fi
    for h in "" "-" "hash-error" "a b"; do
        if hash_is_known "$h"; then bad "hash_is_known accepted '$h' (cannot-tell must not count as a hash)"; else ok "hash_is_known rejects '$h'"; fi
    done
fi
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
eq "heartbeat refused as busy: re-probes after HEARTBEAT_BUSY_RETRY_MAX (a refusal holds nothing — not 9*D)" $((N + 300)) "$hb_next_allowed"
eq "heartbeat busy: a refusal is not a hold (count unchanged)"      0 "$reload_count"
eq "heartbeat busy: D not overwritten"                              600 "$last_reload_secs"

reset_state; last_reload_secs=10
finish_reload heartbeat busy 0 1 "already in progress" "$N" >> "$TICKLOG"
eq "heartbeat busy, short D: cooldown below the cap is kept (9*10)"  $((N + 90)) "$hb_next_allowed"

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
: > "$TMP/giveup.log"
while [ "$n" -lt 3 ]; do
    pending_reload=false
    finish_reload file-change fail 2 1 "controller unreachable" "$N" >> "$TMP/giveup.log" 2>&1
    n=$((n + 1))
    eq "file change failure $n/3: retried (pending)" true "$pending_reload"
done
pending_reload=false
finish_reload file-change fail 2 1 "controller unreachable" "$N" >> "$TMP/giveup.log" 2>&1
eq "file change 4th failure: gives up (heartbeat covers it)" false "$pending_reload"
eq "file change give-up resets the failure streak"           0 "$file_fail_count"
has   "give-up log says WHEN the heartbeat is due, instead of promising it will cover" "which is not due for 20s" "$TMP/giveup.log"
hasnt "give-up log makes no 'will cover it' promise" "will cover it" "$TMP/giveup.log"
# the give-up is the 4th failure (1 try + FILE_MAX_FAIL_RETRIES retries): the log counts them as such
has   "give-up log counts the failures right: $((FILE_MAX_FAIL_RETRIES + 1)) (1 try + $FILE_MAX_FAIL_RETRIES retries)" "gave up after $((FILE_MAX_FAIL_RETRIES + 1)) failures" "$TMP/giveup.log"
hasnt "give-up log does not say it gave up after only $FILE_MAX_FAIL_RETRIES" "gave up after $FILE_MAX_FAIL_RETRIES failures" "$TMP/giveup.log"
has   "retry log numbers the RETRIES (the first failure schedules retry 1 of $FILE_MAX_FAIL_RETRIES)" "retry 1 of $FILE_MAX_FAIL_RETRIES" "$TMP/giveup.log"
has   "…up to the last one" "retry $FILE_MAX_FAIL_RETRIES of $FILE_MAX_FAIL_RETRIES" "$TMP/giveup.log"

reset_state; file_fail_count=2
finish_reload file-change ok 5 0 "ok" "$N" >> "$TICKLOG"
eq "file change success clears the failure streak" 0 "$file_fail_count"

# B3. THE THIRD STATE (gate FAIL 1/3, blocking 4): "how long did it hold the slot?" can be unknown
#     (unreadable result, runner killed, wall clock stepped). Unknown must not behave as "it was instant".
echo "-- B3. unknown hold time is not 0s; a failure is not a measurement of D"
for bad_held in "" "-5" "abc" "99999" "12x"; do
    reset_state; last_reload_secs=300; : > "$TMP/unk.log"
    finish_reload heartbeat ok "$bad_held" 0 "Reload complete" "$N" >> "$TMP/unk.log" 2>&1
    eq "held='$bad_held': the learned D is left untouched"            300 "$last_reload_secs"
    eq "held='$bad_held': cooldown assumes max(D, ${RELOAD_UNKNOWN_HELD_ASSUMED}s) -> heartbeat +5400s, NOT the 20s floor" $((N + 5400)) "$hb_next_allowed"
    eq "held='$bad_held': file-change reloads keep off the slot for the assumed hold too" $((N + 600)) "$file_next_allowed"
    eq "held='$bad_held': not added to the measured hold total"      0 "$reload_held_total"
    eq "held='$bad_held': counted as an unknown-duration reload"     1 "${reload_unknown_count-}"
    has   "held='$bad_held': the log says the duration is unknown" "UNKNOWN" "$TMP/unk.log"
    hasnt "held='$bad_held': the log does not claim a measured 0s" "after 0s" "$TMP/unk.log"
    hasnt "held='$bad_held': …nor 'took 0s'" "took 0s" "$TMP/unk.log"
done
reset_state; last_reload_secs=900
finish_reload heartbeat ok "" 0 "ok" "$N" >> "$TICKLOG"
eq "unknown hold, learned D=900 (> assumed 600): the larger of the two is used (7200 ceiling)" $((N + 7200)) "$hb_next_allowed"
reset_state; : > "$TMP/unk-nod.log"
finish_reload heartbeat ok "" 0 "ok" "$N" >> "$TMP/unk-nod.log" 2>&1
eq "unknown hold with NO learned D: assumes ${RELOAD_UNKNOWN_HELD_ASSUMED}s" $((N + 5400)) "$hb_next_allowed"
eq "…and still does not invent a D (it stays 'never learned', not 0)" "[]" "[$last_reload_secs]"
has   "…the log says no D was learned yet" "no D learned yet" "$TMP/unk-nod.log"
hasnt "…and never prints a learned D=0s for a D nobody measured" "D=0s" "$TMP/unk-nod.log"
hasnt "…nor 'D=<1s'" "D=<1s" "$TMP/unk-nod.log"
reset_state; last_reload_secs=300; : > "$TMP/unk-d.log"
finish_reload heartbeat ok "" 0 "ok" "$N" >> "$TMP/unk-d.log" 2>&1
has "unknown hold WITH a learned D: the log names it (left untouched)" "learned D=300s left untouched" "$TMP/unk-d.log"

# B3b. a MEASURED sub-second hold is a real measurement, and is shown as such: "<1s", never a bare 0s
reset_state; : > "$TMP/zero.log"
finish_reload heartbeat ok 0 0 "Reload complete" "$N" >> "$TMP/zero.log" 2>&1
eq "a measured 0s hold IS learned (it is a number, unlike never-learned)" 0 "$last_reload_secs"
has   "…and is logged as '<1s' (the clock has 1s resolution)" "took <1s" "$TMP/zero.log"
hasnt "…not as 'took 0s'" "took 0s" "$TMP/zero.log"
reset_state; last_reload_secs=600
finish_reload heartbeat fail 1 1 "controller restarting" "$N" >> "$TICKLOG" 2>&1
eq "a fast failure does NOT overwrite the learned D" 600 "$last_reload_secs"
eq "…and the retry is at the floor (it held nothing)" $((N + 20)) "$hb_next_allowed"
reset_state; last_reload_secs=600
finish_reload heartbeat fail 900 1 "client timed out" "$N" >> "$TICKLOG" 2>&1
eq "a failure after the client timeout does not overwrite D either" 600 "$last_reload_secs"
eq "…it may have held the slot up to the controller TTL: cooldown assumes 600s, not 900s" $((N + 5400)) "$hb_next_allowed"
eq "…and no more than the TTL is added to the measured hold total" 600 "$reload_held_total"
reset_state; last_reload_secs=600
finish_reload file-change fail "" 1 "runner killed" "$N" >> "$TICKLOG" 2>&1
eq "failed reload of UNKNOWN duration: D untouched" 600 "$last_reload_secs"
eq "…counted as unknown" 1 "${reload_unknown_count-}"

# B4. what the last reload that finished OK covered (the restart gap needs it)
reset_state; RELOAD_COVERS_HASH=hX
finish_reload heartbeat fail 1 1 "x" "$N" >> "$TICKLOG" 2>&1
finish_reload heartbeat busy 0 1 "x" "$N" >> "$TICKLOG" 2>&1
eq "a failed or refused reload does not mark the hash as covered" "" "${covered_hash-}"
finish_reload heartbeat ok 1 0 "x" "$N" >> "$TICKLOG" 2>&1
eq "a reload that finished OK marks the hash it was requested against as covered" hX "${covered_hash-}"
finish_reload heartbeat ok "" 0 "x" "$N" >> "$TICKLOG" 2>&1
eq "…also when its duration is unknown (it did finish OK)" hX "${covered_hash-}"

# B5. THE THIRD STATE ON THE PERSISTED PATH (gate FAIL 2/3, blocking 1 and 3): a D that was NEVER learned
#     must travel save -> load -> startup log as "not learned", never as a measured 0s
echo "-- B5. a D that was never learned is persisted as '-', loaded as 'not learned', and logged as such"
HASH_MODE=fake; FAKE_HASH=hN
( trap - EXIT; CONFIG_DRIFT_WATCHER_LIB=1; . "$WATCHER" >/dev/null 2>&1; printf '[%s]' "${last_reload_secs-UNSET}" ) > "$TMP/fresh-d.out" 2>&1
eq "a freshly started watcher has learned no D (empty, not 0)" "[]" "$(cat "$TMP/fresh-d.out")"
reset_state; RELOAD_COVERS_HASH=hN
finish_reload heartbeat fail "" "?" "runner killed" "$N" >> "$TICKLOG" 2>&1   # the first life's first reload: unknown duration, no D yet
eq "never-learned D is persisted as '-' (not '0')" "-" "$(awk '{print $1}' "$RELOAD_STATS_FILE" 2>/dev/null)"
eq "…the record still has the embargo and the hash fields in place" "3" "$(awk '{print NF}' "$RELOAD_STATS_FILE" 2>/dev/null)"
reset_state keep-files
startup_replay >> "$TICKLOG" 2>&1
eq "restart: a '-' D is loaded as 'not learned'" "[]" "[$last_reload_secs]"
eq "restart: …and is NOT reported as carried over" false "$stats_carried_over"
if need_fn startup_stats_line; then
    startup_stats_line > "$TMP/b5-line.out"
    has   "restart: the startup line says no hold time is learned yet" "No hold time learned yet" "$TMP/b5-line.out"
    hasnt "restart: …and never claims the last reload held the slot 0s" "held the slot" "$TMP/b5-line.out"
    hasnt "restart: …nor 'Carried over'" "Carried over" "$TMP/b5-line.out"
fi
# an OK reload that measured a hold turns '-' into a number, and that number is what a restart carries over
reset_state; RELOAD_COVERS_HASH=hN
finish_reload heartbeat ok 42 0 "ok" "$N" >> "$TICKLOG" 2>&1
eq "a measured hold is persisted as a number" 42 "$(awk '{print $1}' "$RELOAD_STATS_FILE" 2>/dev/null)"
reset_state keep-files
startup_replay >> "$TICKLOG" 2>&1
eq "restart: a measured D is carried over" "42 true" "$last_reload_secs $stats_carried_over"
if need_fn startup_stats_line; then
    startup_stats_line > "$TMP/b5-line.out"
    has "restart: the startup line states the measured hold" "Carried over from the previous run: the last reload that could be measured held the slot 42s" "$TMP/b5-line.out"
fi
# a record written by anything that stored 0 for 'never learned' (a hand-edited file, an older build): the
# startup line must not print a bare number for it. 0 is a real sub-second measurement, so say so as "<1s".
reset_state
echo "0 $((FAKE_NOW + 5400)) hN" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG" 2>&1
if need_fn startup_stats_line; then
    startup_stats_line > "$TMP/b5-zero.out"
    hasnt "stats '0 <embargo> <hash>': the startup line never claims 'held the slot 0s'" "held the slot 0s" "$TMP/b5-zero.out"
    has   "…it says '<1s' for what is, at best, a sub-second measurement" "held the slot <1s" "$TMP/b5-zero.out"
fi
# the same bound as a fresh measurement: a D no reload can have held is not credible, so it is not carried over
reset_state
echo "5000 $((FAKE_NOW + 5400)) hN" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG" 2>&1
eq "a saved D above RELOAD_CLIENT_TIMEOUT+RELOAD_WATCHDOG_GRACE is not credible: not carried over" "[] false" "[$last_reload_secs] $stats_carried_over"
reset_state
echo "- $((FAKE_NOW + 5400)) hN" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG" 2>&1
eq "a '-' D with unchanged files: verdict unchanged, the embargo is still carried (D and embargo are independent)" "unchanged $((FAKE_NOW + 5400))" "${startup_gap_verdict-} $hb_next_allowed"
HASH_MODE=real; FAKE_HASH=h0

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

reset_state; RELOAD_TRIGGER=file-change; RELOAD_STARTED=$FAKE_NOW; last_reload_secs=77
reap_start 0 "garbage" "x"
sleep 1
poll_reload_result "$FAKE_NOW" >> "$TICKLOG" 2>&1
eq "unreadable result counts as a failed file-change reload (retried)" true "$pending_reload"
eq "unreadable result: D left alone (its hold time is unknown, not 0s)" 77 "$last_reload_secs"

reset_state; RELOAD_TRIGGER=heartbeat; RELOAD_STARTED=$((FAKE_NOW - 5)); last_reload_secs=77
( trap - EXIT; exit 0 ) &   # (a subshell's explicit exit would otherwise run THIS script's EXIT trap and wipe $TMP)
RELOAD_PID=$!
sleep 1
: > "$TMP/dead.log"
poll_reload_result "$FAKE_NOW" >> "$TMP/dead.log" 2>&1
eq "runner died without a result: slot freed for the next decision" "" "$RELOAD_PID"
eq "runner died without a result: counted as a failed reload"       1 "$reload_count"
eq "runner died without a result: its hold time is UNKNOWN, D untouched" "77 1" "$last_reload_secs ${reload_unknown_count-}"
has "runner died without a result: logged" "exited without a result" "$TMP/dead.log"

# C2. the runner that finishes BETWEEN the result-file check and the liveness check is a success
reset_state; RELOAD_TRIGGER=file-change; RELOAD_STARTED=$FAKE_NOW; last_reload_secs=""
( trap - EXIT; exit 0 ) &
RELOAD_PID=$!
sleep 1
: > "$TMP/race.log"
RACE_ON=1
poll_reload_result "$FAKE_NOW" >> "$TMP/race.log" 2>&1
RACE_ON=0
eq "race: a result that lands between the two looks is consumed, not called a failure" 42 "$last_reload_secs"
eq "race: no needless retry of a file change that was accepted" false "$pending_reload"
hasnt "race: not logged as 'exited without a result'" "exited without a result" "$TMP/race.log"
has   "race: logged as the OK reload it was" "reload[file-change] OK" "$TMP/race.log"

# C3. the WATCHDOG, against the production process topology: a hung stub gc under the REAL runner
#     (start_reload's subshell -> $(...) -> gc -> its helper). Killing only the runner leaves the gc
#     client orphaned — the leak of gate FAIL 1/3 (blocking 2 and 3).
hung_start() {   # the real runner over a hung stub gc: sets HUNG_PIDS (the stub gc and its helper), RELOAD_PID, a past RELOAD_STARTED
    reset_state; RELOAD_TRIGGER=heartbeat; last_reload_secs=77
    : > "$TMP/hang.pids"
    export GCSTUB_MODE=hang GCSTUB_PIDS="$TMP/hang.pids"
    real_reload heartbeat "$FAKE_NOW" >> "$TICKLOG" 2>&1
    local i=0
    while [ "$(wc -l < "$TMP/hang.pids" | tr -d ' ')" -lt 2 ] && [ "$i" -lt 40 ]; do sleep 0.25; i=$((i + 1)); done
    HUNG_PIDS="$(tr '\n' ' ' < "$TMP/hang.pids")"
    DUMMY_PIDS="$DUMMY_PIDS $HUNG_PIDS"   # safety net: whatever survives is killed at exit
    RELOAD_STARTED=$((FAKE_NOW - RELOAD_CLIENT_TIMEOUT - RELOAD_WATCHDOG_GRACE - 1))
}
alive_of() {   # alive_of <pids…> — the ones that are still running, space separated, leading space
    local p out=""
    for p in "$@"; do builtin kill -0 "$p" 2>/dev/null && out="$out $p"; done
    printf '%s' "$out"
}
hung_start
eq "watchdog setup: the hung gc stub and its helper are running" 2 "$(printf '%s\n' $HUNG_PIDS | grep -c .)"
alive_before=$(alive_of $HUNG_PIDS)
eq "watchdog setup: both are alive before the watchdog fires" "$(printf '%s' " $HUNG_PIDS" | sed 's/ *$//')" "$alive_before"
: > "$TMP/watchdog.log"
poll_reload_result "$FAKE_NOW" >> "$TMP/watchdog.log" 2>&1
sleep 0.3
alive_after=$(alive_of $HUNG_PIDS)
eq "watchdog: NO process of the hung gc tree survives (stub gc and its helper)" "" "$alive_after"
for p in $alive_after; do builtin kill -KILL "$p" 2>/dev/null || true; done   # leave nothing behind, whatever happened
eq "watchdog: slot freed" "" "$RELOAD_PID"
has   "watchdog: logged as killed, runner and client" "were killed" "$TMP/watchdog.log"
hasnt "watchdog: no leak claimed when none happened" "leaked" "$TMP/watchdog.log"
hasnt "watchdog: bash's job-control 'Terminated' dump (the whole runner script) stays out of the log" "Terminated" "$TMP/watchdog.log"
eq "watchdog: how long it held the slot is unknown: D untouched, counted as unknown" "77 1" "$last_reload_secs ${reload_unknown_count-}"
# the verdict names what was seen: the pids of the gc client and its helper are in the log, so "killed" is checkable
hung_pid_list=$(printf '%s' "$HUNG_PIDS" | sed 's/ *$//')
ok_pids=1
for p in $HUNG_PIDS; do grep -F -- "$p" "$TMP/watchdog.log" >/dev/null 2>&1 || ok_pids=0; done
eq "watchdog: the log lists the pids it killed (the gc stub and its helper: '$hung_pid_list')" 1 "$ok_pids"

# C3b. THE THIRD STATE (gate FAIL 2/3, blocking 4): pgrep cannot enumerate the tree (missing from PATH: rc 127;
#      or any rc >= 2). "I could not list the descendants" must not read as "there were none, all dead".
#      Only the runner is signalled then — the gc client really survives — so the log must say so.
hung_start
pgrep() { return 127; }                           # shadows the binary for the watcher's own calls only
: > "$TMP/watchdog-nopgrep.log"
poll_reload_result "$FAKE_NOW" >> "$TMP/watchdog-nopgrep.log" 2>&1
unset -f pgrep
sleep 0.3
alive_after=$(alive_of $HUNG_PIDS)
ge "control: with the tree unenumerable the gc stub really is still alive (a 'killed' claim would be a lie)" "$(printf '%s\n' $alive_after | grep -c .)" 1
for p in $alive_after; do builtin kill -KILL "$p" 2>/dev/null || true; done
eq "pgrep unavailable: the slot is still freed (the loop is not held)" "" "$RELOAD_PID"
has   "pgrep unavailable: the log says the descendants could not be enumerated" "could NOT be enumerated" "$TMP/watchdog-nopgrep.log"
has   "pgrep unavailable: …and the gc client is NOT confirmed killed" "NOT confirmed killed" "$TMP/watchdog-nopgrep.log"
hasnt "pgrep unavailable: …and it does NOT claim anything was killed" "were killed" "$TMP/watchdog-nopgrep.log"
hasnt "pgrep unavailable: …nor 'the gc client was killed'" "gc client were killed" "$TMP/watchdog-nopgrep.log"
eq "pgrep unavailable: the hold time is unknown all the same (D untouched, counted)" "77 1" "$last_reload_secs ${reload_unknown_count-}"

# C3c. an erroring pgrep is not trusted for what it printed either: never signal a pid out of a failed enumeration
( trap - EXIT; exec sleep 60 ) &
BYSTANDER=$!
( trap - EXIT; exec sleep 60 ) &
VICTIM=$!
DUMMY_PIDS="$DUMMY_PIDS $BYSTANDER $VICTIM"
sleep 0.3
pgrep() { [ "${2:-}" = "$VICTIM" ] && echo "$BYSTANDER"; return 2; }
if need_fn kill_process_tree; then
    kill_process_tree "$VICTIM" > "$TMP/c3c.out" 2>&1; C3C_RC=$?
else
    C3C_RC=0
fi
unset -f pgrep
wait "$VICTIM" 2>/dev/null || true
eq "failed pgrep: a pid it printed is NOT signalled (the bystander is still running)" " $BYSTANDER" "$(alive_of "$BYSTANDER")"
eq "failed pgrep: the victim (the runner itself) is dead" "" "$(alive_of "$VICTIM")"
if [ "$C3C_RC" -ne 0 ]; then ok "failed pgrep: kill_process_tree does not report a confirmed kill (rc $C3C_RC)"; else bad "failed pgrep: kill_process_tree reported success although it could not enumerate"; fi
eq "failed pgrep: …the tree is flagged incomplete" false "${KILL_TREE_COMPLETE-unset}"
builtin kill -KILL "$BYSTANDER" 2>/dev/null || true

# C3d. a runner with NO descendants (pgrep answers rc 1 = none: a real answer) is killed and the log says exactly that —
#      it must not claim a gc client was killed
( trap - EXIT; exec sleep 60 ) &
LEAF=$!
DUMMY_PIDS="$DUMMY_PIDS $LEAF"
sleep 0.3
reset_state; RELOAD_TRIGGER=heartbeat; RELOAD_STARTED=$((FAKE_NOW - RELOAD_CLIENT_TIMEOUT - RELOAD_WATCHDOG_GRACE - 1))
RELOAD_PID=$LEAF
: > "$TMP/watchdog-leaf.log"
poll_reload_result "$FAKE_NOW" >> "$TMP/watchdog-leaf.log" 2>&1
sleep 0.3
eq "leaf runner: dead" "" "$(alive_of "$LEAF")"
has   "leaf runner: the log says the runner was killed and no descendant was found" "no descendant" "$TMP/watchdog-leaf.log"
hasnt "leaf runner: …and does not claim a gc client was killed" "gc client" "$TMP/watchdog-leaf.log"
hasnt "leaf runner: …nor that descendants were" "descendants (pids" "$TMP/watchdog-leaf.log"
hasnt "leaf runner: …nor that enumeration failed" "could NOT be enumerated" "$TMP/watchdog-leaf.log"
export GCSTUB_MODE=ok; unset GCSTUB_PIDS

# C3e. descendants_of: the whole tree (depth > 1), and "could not enumerate" (rc 2) apart from "none" (rc 0, no output)
if need_fn descendants_of; then
    ( trap - EXIT; ( sleep 60 & wait ) & wait ) &
    TREE_ROOT=$!
    DUMMY_PIDS="$DUMMY_PIDS $TREE_ROOT"
    sleep 0.5
    TREE_LIST=$(descendants_of "$TREE_ROOT"); TREE_RC=$?
    eq "descendants_of: a root -> subshell -> sleep tree lists both levels" 2 "$(printf '%s\n' $TREE_LIST | grep -c .)"
    eq "descendants_of: a complete enumeration returns 0" 0 "$TREE_RC"
    pgrep() { return 127; }
    descendants_of "$TREE_ROOT" > "$TMP/c3e.out" 2>/dev/null; NOPGREP_RC=$?
    unset -f pgrep
    eq "descendants_of: pgrep failing returns 2 (the list cannot be trusted as complete)" 2 "$NOPGREP_RC"
    pgrep() { return 1; }                         # rc 1 is pgrep's answer for "no process matches"
    descendants_of "$TREE_ROOT" > "$TMP/c3e.out" 2>/dev/null; NONE_RC=$?
    unset -f pgrep
    eq "descendants_of: pgrep rc 1 ('none') is an answer: returns 0 with nothing listed" "0 0" "$NONE_RC $(wc -c < "$TMP/c3e.out" | tr -d ' ')"
    for p in $TREE_LIST $TREE_ROOT; do builtin kill -KILL "$p" 2>/dev/null || true; done
fi

# C4. a process that survives SIGKILL is reported as leaked — never as killed — and cannot freeze the loop
if need_fn kill_process_tree; then
    ( trap - EXIT; trap '' TERM; exec sleep 60 ) &
    STUBBORN=$!
    DUMMY_PIDS="$DUMMY_PIDS $STUBBORN"
    sleep 0.3
    # kill_process_tree reports through KILL_TREE_SEEN / KILL_TREE_COMPLETE / KILL_TREE_SURVIVORS and its status:
    # 0 only when the tree was fully enumerated AND nothing in it survived (called directly, not in $(...))
    kill_process_tree "$STUBBORN" > /dev/null 2>&1; KT_RC=$?
    wait "$STUBBORN" 2>/dev/null || true
    eq "kill_process_tree: a TERM-ignoring process dies of the KILL that follows" "" "${KILL_TREE_SURVIVORS-unset}"
    eq "kill_process_tree: …and that is a confirmed kill (status 0)" 0 "$KT_RC"
    eq "kill_process_tree: …after a complete enumeration" true "${KILL_TREE_COMPLETE-unset}"
    ( trap - EXIT; exec sleep 60 ) &
    SHIELDED=$!
    DUMMY_PIDS="$DUMMY_PIDS $SHIELDED"
    sleep 0.3
    SHIELD_PID=$SHIELDED
    kill_process_tree "$SHIELDED" > /dev/null 2>&1; KT_RC=$?
    eq "kill_process_tree: reports the pid that survived SIGKILL" "$SHIELDED" "${KILL_TREE_SURVIVORS-unset}"
    if [ "$KT_RC" -ne 0 ]; then ok "kill_process_tree: …and is not a confirmed kill (status $KT_RC)"; else bad "kill_process_tree: a survivor was reported as a confirmed kill"; fi
    reset_state; RELOAD_TRIGGER=heartbeat; RELOAD_STARTED=$((FAKE_NOW - RELOAD_CLIENT_TIMEOUT - RELOAD_WATCHDOG_GRACE - 1))
    RELOAD_PID=$SHIELDED
    : > "$TMP/leak.log"
    poll_reload_result "$FAKE_NOW" >> "$TMP/leak.log" 2>&1   # a wait() on the survivor would hang right here
    has   "watchdog: a survivor is logged as leaked" "leaked" "$TMP/leak.log"
    hasnt "watchdog: …and NOT as killed" "were killed" "$TMP/leak.log"
    eq "watchdog: the loop is not held by the survivor (slot freed)" "" "$RELOAD_PID"
    SHIELD_PID=""
    builtin kill -KILL "$SHIELDED" 2>/dev/null || true
fi

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
prev_hash=hD0
export GCSTUB_MODE=ok; start_reload heartbeat "$FAKE_NOW" >> "$TICKLOG"
wait_reload
eq "ok: reaped" "" "$RELOAD_PID"
ge "ok: D measured from the real wall time (stub sleeps 1s)" "$last_reload_secs" 1
eq "ok: counted" 1 "$reload_count"
eq "ok: the reload is recorded as covering the hash it was requested against" hD0 "${covered_hash-}"
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

reset_state; last_reload_secs=600; prev_hash=hD1
export GCSTUB_MODE=fail; start_reload file-change "$FAKE_NOW" >> "$TICKLOG" 2>&1
wait_reload
eq "fail on a file-change reload: counted and retried" "1 true" "$reload_count $pending_reload"
eq "fail on a file-change reload: learned D not overwritten by the 1s failure" 600 "$last_reload_secs"
eq "fail: the hash is not marked covered" "" "${covered_hash-}"
export GCSTUB_MODE=ok

# D2. start_reload clears the previous result before it launches the runner. A stale one that survives would be
#     consumed as THIS reload's result, and consume_reload_result would then wait() on a runner that is still
#     running. A failed removal used to be swallowed (|| true): it is checked and SAID now.
if need_fn clear_stale_reload_result; then
    reset_state
    printf 'ok 7 0\nstale\n' > "$RELOAD_RESULT_FILE"; printf 'half written' > "$RELOAD_RESULT_FILE.tmp"
    clear_stale_reload_result > "$TMP/stale-ok.out" 2>&1; S_RC=$?
    eq "a stale result and its temp file are removed (status 0)" "0 no no" "$S_RC $([ -e "$RELOAD_RESULT_FILE" ] && echo yes || echo no) $([ -e "$RELOAD_RESULT_FILE.tmp" ] && echo yes || echo no)"
    hasnt "…and nothing is said about it" "cannot remove" "$TMP/stale-ok.out"
    mkdir -p "$RELOAD_RESULT_FILE"; : > "$RELOAD_RESULT_FILE/keep"        # rm -f cannot remove a non-empty directory
    clear_stale_reload_result > "$TMP/stale-bad.out" 2>&1; S_RC=$?
    eq "a stale result that cannot be removed: reported through the status (1)" 1 "$S_RC"
    has "…and logged, naming the file" "cannot remove the stale reload result '$RELOAD_RESULT_FILE'" "$TMP/stale-bad.out"
    has "…with what that risks" "mistaken for the result of the reload being started" "$TMP/stale-bad.out"
    # start_reload itself says it (and still starts the reload: a change must not be dropped over a leftover file)
    : > "$GCSTUB_ARGS"; export GCSTUB_MODE=ok
    start_reload heartbeat "$FAKE_NOW" > "$TMP/stale-start.out" 2>&1
    wait_reload
    has "start_reload logs a result it could not clear" "cannot remove the stale reload result" "$TMP/stale-start.out"
    has "…and still issues the reload" "reload --soft" "$GCSTUB_ARGS"
    rm -f "$RELOAD_RESULT_FILE"/* 2>/dev/null; rmdir "$RELOAD_RESULT_FILE" 2>/dev/null || true
    eq "stale-result scratch removed" "no" "$([ -e "$RELOAD_RESULT_FILE" ] && echo yes || echo no)"
fi

# ── E. the restart gap ───────────────────────────────────────────────────────
echo "== E. restart gap (delivery restarts the daemon): stats persist; drift that straddles the restart is not dropped"
HASH_MODE=fake

# E1. nothing changed since the last reload that finished OK: the embargo is carried over
FAKE_HASH=hA
reset_state; prev_hash=hA; RELOAD_COVERS_HASH=hA
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG"
saved_hb=$hb_next_allowed
eq "the stats file carries the hash the last OK reload covered" hA "$(awk '{print $3}' "$RELOAD_STATS_FILE" 2>/dev/null)"
reset_state keep-files                                  # a fresh process: nothing in memory, the stats file on disk
startup_replay >> "$TICKLOG"
eq "restart, files unchanged: last reload duration carried over" 600 "$last_reload_secs"
eq "restart, files unchanged: heartbeat embargo carried over (a restart does not re-open the slot to the watcher)" "$saved_hb" "$hb_next_allowed"
eq "restart, files unchanged: nothing queued" false "$pending_reload"
eq "restart, files unchanged: verdict" unchanged "${startup_gap_verdict-}"
eq "restart: the stats are reported as carried over" true "$stats_carried_over"

# E2. THE reviewer scenario (gate FAIL 1/3, blocking 1): embargo active, a skill file changes, the daemon restarts
HASH_MODE=real
rm -f "$CITY/skills/restart.md"
echo "# skill v1" > "$CITY/skills/restart.md"
reset_state; prev_hash=$(compute_hash); RELOAD_COVERS_HASH=$prev_hash
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG"          # previous life: D=600, heartbeat embargo +5400
echo "# skill v2 — changed while the daemon was down (or detected, but its reload still pending)" >> "$CITY/skills/restart.md"
reset_state keep-files
startup_replay >> "$TICKLOG"
eq "restart + changed file: a file-change reload is queued" true "$pending_reload"
eq "restart + changed file: verdict" changed "${startup_gap_verdict-}"
eq "restart + changed file: the embargo is NOT carried over (it would hide the backstop for 5400s)" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"
: > "$GCSTUB_ARGS"; export GCSTUB_MODE=ok
FAKE_NOW=$((FAKE_NOW + POLL_INTERVAL)); watcher_tick "$FAKE_NOW" >> "$TICKLOG" 2>&1
eq "restart + changed file: the very first tick requests it, as a file-change reload" file-change "$RELOAD_TRIGGER"
wait_reload
has "restart + changed file: gc was really asked to reload" "reload --soft" "$GCSTUB_ARGS"
rm -f "$CITY/skills/restart.md"

# E3. the previous life had SEEN the change (prev_hash == new) but its reload was still pending (slot busy)
HASH_MODE=fake; FAKE_HASH=hB
reset_state; prev_hash=hA; RELOAD_COVERS_HASH=hA
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG"
reset_state keep-files
startup_replay >> "$TICKLOG"
eq "restart with a file change that was still pending: queued again" "true changed" "$pending_reload ${startup_gap_verdict-}"

# E4. unknown is not "covered": no record, a legacy record, garbage, an unreadable hash
FAKE_HASH=hA
reset_state
startup_replay >> "$TICKLOG"
eq "first start (no stats file): unknown -> a file-change reload is queued (what the old 20s heartbeat did)" "true unknown" "$pending_reload ${startup_gap_verdict-}"
eq "…and no D is claimed" false "$stats_carried_over"
reset_state
echo "600 $((FAKE_NOW + 5400))" > "$RELOAD_STATS_FILE"        # the format of the previous version (no hash)
startup_replay >> "$TICKLOG"
eq "legacy 2-field stats (no hash): unknown, queued, embargo NOT carried" "true unknown $((FAKE_NOW + HEARTBEAT_INTERVAL))" "$pending_reload ${startup_gap_verdict-} $hb_next_allowed"
eq "legacy 2-field stats: the learned D is still usable" 600 "$last_reload_secs"
reset_state
echo "not numbers at all" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG"
eq "garbage stats file: D not carried (stays 'never learned', not 0), embargo not carried, queued" "[] $((FAKE_NOW + HEARTBEAT_INTERVAL)) true" "[$last_reload_secs] $hb_next_allowed $pending_reload"
eq "garbage stats file is NOT reported as carried over" false "$stats_carried_over"
reset_state
echo "600 $((FAKE_NOW + 5400)) -" > "$RELOAD_STATS_FILE"       # saved while the covered hash was unknown
startup_replay >> "$TICKLOG"
eq "saved hash unknown ('-'): not covered" "true unknown" "$pending_reload ${startup_gap_verdict-}"
FAKE_HASH=hash-error
reset_state
echo "600 $((FAKE_NOW + 5400)) hash-error" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG"
eq "hash computation failed (hash-error == hash-error is not 'unchanged')" "true unknown $((FAKE_NOW + HEARTBEAT_INTERVAL))" "$pending_reload ${startup_gap_verdict-} $hb_next_allowed"
FAKE_HASH=hA

# E5. hostile numbers in the stats file
reset_state; hb_next_allowed=$((FAKE_NOW + 20))
echo "600 $((FAKE_NOW + 99999999)) hA" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG"
eq "an embargo far beyond the ceiling is ignored (clock skew / corruption)" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"
reset_state
echo "0600 0099 hA" > "$RELOAD_STATS_FILE"
startup_replay >> "$TICKLOG" 2>&1   # "0099" in $(( )) is an octal error that aborts a bash 3.2 daemon
eq "leading zeros in the stats file are decimal: '0600' is read as 600, no octal abort" 600 "$last_reload_secs"

# E6. a stats file that cannot be written is SAID in the log (not a silent "fine"), and never aborts the loop
reset_state; covered_hash=hA; last_reload_secs=600; hb_next_allowed=$((FAKE_NOW + 5400))
save_reload_stats > "$TMP/e6-ok.out" 2>&1; E6_RC=$?
eq "a save that works returns 0" 0 "$E6_RC"
hasnt "a save that works says nothing" "could not save" "$TMP/e6-ok.out"
E6_REAL_STATS_FILE=$RELOAD_STATS_FILE
: > "$TMP/not-a-dir"
RELOAD_STATS_FILE="$TMP/not-a-dir/stats"      # its parent is a regular file: the .tmp write cannot happen
save_reload_stats > "$TMP/e6-fail.out" 2>&1; E6_RC=$?
RELOAD_STATS_FILE=$E6_REAL_STATS_FILE
eq "a save that cannot write still returns 0 (a full disk must not stop the watcher)" 0 "$E6_RC"
has "a save that cannot write says so, naming the file" "could not save the reload stats to '$TMP/not-a-dir/stats'" "$TMP/e6-fail.out"
# What the next restart does depends on what is ALREADY on disk (gate FAIL 2/3, blocking 2): the message must say
# so, not promise the one outcome that holds only when there is no earlier record.
has   "...and that the next restart reads the last record that WAS saved" "the last record that WAS saved" "$TMP/e6-fail.out"
has   "...none on disk: the gap is unknown and a reload is queued" "no record: the restart gap is unknown and a file-change reload is queued" "$TMP/e6-fail.out"
has   "...an older record on disk: its older D and embargo apply, this reload's cooldown is lost" "the cooldown of this reload is lost" "$TMP/e6-fail.out"
hasnt "...and it does NOT promise a queued reload as if it were the only outcome" "re-learns D and queues a file-change reload" "$TMP/e6-fail.out"

# E6b. THE CASE THE MESSAGE USED TO GET WRONG: an earlier record IS on disk (every save after the first has one),
#      the files are unchanged, and a later save fails. The restart reads the OLD record: verdict unchanged,
#      nothing queued, the OLD D, and the cooldown of the reload whose save failed is gone.
FAKE_HASH=hA; E6B_BASE=$FAKE_NOW
reset_state; prev_hash=hA; RELOAD_COVERS_HASH=hA
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG" 2>&1              # record 1: D=600, embargo +5400
E6B_T2=$((E6B_BASE + 6000))                                                        # record 1's embargo is over by then
mkdir "$RELOAD_STATS_FILE.tmp"                                                     # a directory where the temp file goes: the NEXT save fails, record 1 stays
finish_reload heartbeat ok 300 0 "ok" "$E6B_T2" > "$TMP/e6b-fail.out" 2>&1
rmdir "$RELOAD_STATS_FILE.tmp"
E6B_SECOND_EMBARGO=$hb_next_allowed
has "an earlier record on disk, a later save fails: the failure is logged" "could not save the reload stats" "$TMP/e6b-fail.out"
eq "…record 1 is still what is on disk (D=600)" 600 "$(awk '{print $1}' "$RELOAD_STATS_FILE" 2>/dev/null)"
FAKE_NOW=$((E6B_T2 + 30))
reset_state keep-files
startup_replay >> "$TICKLOG" 2>&1
eq "…restart: verdict unchanged, nothing queued (no reload is queued by a failed save)" "unchanged false" "${startup_gap_verdict-} $pending_reload"
eq "…restart: the OLD D (600) is carried, not the 300 that was measured and lost" 600 "$last_reload_secs"
eq "…restart: the cooldown of the reload whose save failed is LOST — the heartbeat floor applies, not +5400s" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"
ge "…(what was lost: that reload's own embargo reached well beyond the restart's)" "$E6B_SECOND_EMBARGO" $((FAKE_NOW + 1000))
FAKE_NOW=$E6B_BASE; FAKE_HASH=hA

# E7. the restart-gap NOTE in the log says only what the code did: "embargo carried over" is claimed
# when a saved embargo really was applied, and not when it was over already / absent / not credible
FAKE_HASH=hA
reset_state; prev_hash=hA; RELOAD_COVERS_HASH=hA
finish_reload heartbeat ok 600 0 "ok" "$FAKE_NOW" >> "$TICKLOG"
reset_state keep-files
startup_replay >> "$TICKLOG"
printf '%s\n' "$startup_gap_note" > "$TMP/e7-applied.note"
eq "E7 applied: the embargo really was carried over" $((FAKE_NOW + 5400)) "$hb_next_allowed"
has "E7 applied: the note says the embargo was carried over" "heartbeat embargo carried over" "$TMP/e7-applied.note"
reset_state
echo "600 $((FAKE_NOW - 100)) hA" > "$RELOAD_STATS_FILE"         # unchanged files, but the saved embargo ended 100s ago
startup_replay >> "$TICKLOG"
printf '%s\n' "$startup_gap_note" > "$TMP/e7-expired.note"
eq "E7 expired embargo: verdict is still unchanged, nothing queued" "unchanged false" "${startup_gap_verdict-} $pending_reload"
eq "E7 expired embargo: the heartbeat floor applies, not the saved value" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"
hasnt "E7 expired embargo: the note does NOT claim it was carried over" "embargo carried over" "$TMP/e7-expired.note"
has "E7 expired embargo: the note says no saved embargo applies" "no saved heartbeat embargo applies" "$TMP/e7-expired.note"
reset_state
echo "600 $((FAKE_NOW + 99999999)) hA" > "$RELOAD_STATS_FILE"    # beyond the ceiling: clock skew / corruption
startup_replay >> "$TICKLOG"
printf '%s\n' "$startup_gap_note" > "$TMP/e7-skew.note"
eq "E7 embargo beyond the ceiling: the heartbeat floor applies" $((FAKE_NOW + HEARTBEAT_INTERVAL)) "$hb_next_allowed"
hasnt "E7 embargo beyond the ceiling: the note does NOT claim it was carried over" "embargo carried over" "$TMP/e7-skew.note"
has "E7 embargo beyond the ceiling: the note says no saved embargo applies" "no saved heartbeat embargo applies" "$TMP/e7-skew.note"

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

# F6. THE restart-gap scenario through the sim slot (gate FAIL 1/3, blocking 1): the previous life
#     had just finished a 600s heartbeat reload (embargo +5400s); a skill file changes while the
#     daemon is down; the restarted daemon must request that change at once, not ~90 min later
HASH_MODE=fake; FAKE_HASH=h6
sim_reset; SIM_D=600
prev_hash=h6; RELOAD_COVERS_HASH=h6
finish_reload heartbeat ok 600 0 "sim" "$FAKE_NOW" >> "$TICKLOG"
FAKE_HASH=h7
reset_state keep-files                       # the restarted process: memory gone, stats file kept
START_LOG=""; SLOT_BUSY_UNTIL=0; SIM_DONE_AT=0; DUP_STARTS=0
startup_replay >> "$TICKLOG"
ticks 5
f6_first=$(printf '%s\n' $START_LOG | sed -n 's/^file-change@\([0-9]*\)=ok$/\1/p' | head -1)
le "restart with an active embargo + a file that changed meanwhile: accepted within the first ticks (not ~5400s later)" "${f6_first:-99999}" 10
eq "…by the file-change path, not by a heartbeat" 0 "$(starts_matching '^heartbeat@')"
# …and the same restart with NO change leaves the slot alone for the whole embargo
FAKE_HASH=h6
sim_reset; SIM_D=600
prev_hash=h6; RELOAD_COVERS_HASH=h6
finish_reload heartbeat ok 600 0 "sim" "$FAKE_NOW" >> "$TICKLOG"
reset_state keep-files
START_LOG=""; SLOT_BUSY_UNTIL=0; SIM_DONE_AT=0; DUP_STARTS=0
startup_replay >> "$TICKLOG"
ticks 100                                    # 300 s
eq "restart with an active embargo and NO change: no reload at all for 300s (the embargo does its job)" "" "$(printf '%s' "$START_LOG" | tr -d ' ')"
HASH_MODE=real

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
echo "== H. end to end (real daemon loop, three lives, ~30s)"
E2E="$TMP/e2e"
mkdir -p "$E2E/.gc/state" "$E2E/.gc/logs" "$E2E/skills" "$E2E/agents" "$E2E/scripts" "$TMP/e2e-wa"   # a complete tree: compute_hash needs scripts/ (see below)
E2E_LOG="$E2E/.gc/logs/config-drift-watcher.log"
E2E_STATS="$E2E/.gc/state/config-drift-watcher.reload-stats"
: > "$TMP/e2e.gc.args"
start_daemon() {   # the real daemon, as launchd would run it
    : > "$E2E_LOG"
    (
        CITY="$E2E" CONFIG_DRIFT_WATCHER_WA="$TMP/e2e-wa" GC="$TMP/bin/gc" GCSTUB_ARGS="$TMP/e2e.gc.args" \
        GCSTUB_MODE=ok GCSTUB_SLEEP=2 NOTIFY_LOG="$TMP/notify.log" PATH="$TMP/bin:$PATH" \
            exec "$BASH" "$WATCHER"
    ) >/dev/null 2>&1 &
    DPID=$!
    DUMMY_PIDS="$DUMMY_PIDS $DPID"
}
wait_for_log() {   # wait_for_log <fixed string> [tries of 0.5s] — poll the daemon's log
    local i=0
    while [ "$i" -lt "${2:-60}" ]; do
        grep -F -- "$1" "$E2E_LOG" >/dev/null 2>&1 && return 0
        sleep 0.5; i=$((i + 1))
    done
    return 1
}
stop_daemon() { kill "$DPID" 2>/dev/null || true; wait "$DPID" 2>/dev/null || true; }

# life 1: first start, no stats. The restart gap is UNKNOWN, so a file-change reload is queued.
start_daemon
wait_for_log "Initial hash" 60   # the daemon takes its initial hash at startup; only change a file after that
echo "# new skill" > "$E2E/skills/e2e.md"
wait_for_log "own slot duty since start" 60   # the last line finish_reload logs
stop_daemon
has "daemon started" "config-drift-watcher started" "$E2E_LOG"
has "startup marker written (delivery freshness check, ga-fbjg)" "$DPID " "$E2E/.gc/state/config-drift-watcher.startup"
has "first life, no stats: the restart gap is reported as unknown" "Restart gap: unknown" "$E2E_LOG"
has "file change detected" "Hash changed" "$E2E_LOG"
has "file-change reload requested" "reload[file-change] requested" "$E2E_LOG"
has "file-change reload completed, hold time logged" "reload[file-change] OK, took" "$E2E_LOG"
has "slot-duty proof line in the log" "own slot duty since start" "$E2E_LOG"
has "startup log shows the EFFECTIVE duty caps" "slot duty <= 10% [configured '10']" "$E2E_LOG"
has   "first life, no stats: the startup log says no hold time is learned yet" "No hold time learned yet" "$E2E_LOG"
hasnt "first life: the startup log never claims a hold time nobody measured" "held the slot" "$E2E_LOG"
has   "gc called as sync reload with timeout" "reload --soft --timeout ${RELOAD_CLIENT_TIMEOUT}s --city $E2E" "$TMP/e2e.gc.args"
hasnt "gc never called with --async" "--async" "$TMP/e2e.gc.args"
if [ -s "$E2E_STATS" ]; then ok "reload stats persisted"; else bad "reload stats not persisted"; fi
eq "stats carry the covered hash (3rd field, a 32-char md5)" 32 "$(awk '{print length($3)}' "$E2E_STATS" 2>/dev/null | head -1)"

# life 2: restarted with the files exactly as they were: the restart gap is 'unchanged', nothing is requested
start_daemon
wait_for_log "Restart gap:" 40
sleep 7                                       # two more ticks: a wrongly queued reload would be requested by now
stop_daemon
has   "life 2: previous reload stats carried over" "Carried over from the previous run" "$E2E_LOG"
has   "life 2: …stated as a measured hold" "the last reload that could be measured held the slot" "$E2E_LOG"
hasnt "life 2: …and not as a hold that was never learned" "No hold time learned yet" "$E2E_LOG"
has   "life 2: restart gap reported as unchanged" "Restart gap: unchanged" "$E2E_LOG"
hasnt "life 2: no reload requested for an unchanged restart" "requested" "$E2E_LOG"

# life 3: a skill file changes WHILE the daemon is down. The restart gap is 'changed': it is requested at once
echo "# edited while the daemon was down — a longer body" >> "$E2E/skills/e2e.md"
start_daemon
wait_for_log "own slot duty since start" 60
stop_daemon
has "life 3: restart gap reported as changed" "Restart gap: changed" "$E2E_LOG"
has "life 3: the change is requested as a file-change reload straight after the restart" "reload[file-change] requested" "$E2E_LOG"
has "life 3: …and accepted" "reload[file-change] OK, took" "$E2E_LOG"
hasnt "life 3: no heartbeat in the way" "reload[heartbeat] requested" "$E2E_LOG"

echo
echo "PASS=$PASS FAIL=$FAIL"
selftest_summary_reached
[ "$FAIL" -eq 0 ]

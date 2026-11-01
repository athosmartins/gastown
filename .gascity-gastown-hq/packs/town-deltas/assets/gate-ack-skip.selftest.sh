#!/usr/bin/env bash
# gate-ack-skip.selftest.sh — ga-86aie91: the Step 7b ACK loop is not run when it has nothing to act on, so the gate lock is not held ~150 s per admission.
#
# WHAT IT PROVES (each guard has a mutation that must turn it red — section 6):
#   1. gate_ack_loop_needed (the REAL function, extracted by its SELFTEST-EXTRACT markers): rc 1 ("skip") only when every slot not yet ACKed has
#      REVIEWER_NUDGE_SENT exactly "1". A refused first send (0), an unset slot (the E5 extra before ga-g3m45n), junk, a mixed run, no slots, an
#      undeclared array: all rc 0 ("run the loop"). A slot already ACKed needs nothing. GATE_ACK_SKIP=0 and the file .gc/gate-ack-skip.off give the
#      old loop back; a typo keeps the skip ON.
#   2. The REAL Step 7b region (extracted whole) with every nudge accepted: returns at once with ACK_WAIT_SECS=20 (the old loop took >= 60 s), reads
#      nothing (no `gc session peek/list`, no `bd show`), logs why, prints no "never ACKed" (it tried nothing), and makes ONE gate_midsweep_collect
#      call, labelled step-7b-skip and never step-7b-ack.
#   3. The same region with a slot the loop CAN still re-queue (refused / unset / junk / mixed) or with a kill switch on: the loop runs exactly as
#      before — gate_deliver_review_task retry is called, step-7b-ack collects, "never ACKed" is reported, no skip line, no step-7b-skip call.
#   4. Static wiring on the live file: the lines other selftests pin (the step-7b-ack call right before the sleep) are untouched, the function is
#      defined before Step 7b, the skip call is one column-0 simple list, and NOTHING outside the loop READS REVIEWER_ACKED (the claim that makes the
#      wait useless — if a reader appears, this goes red and the skip has to be rethought).
#   5. bash -n on both bash 5 and the macOS /bin/bash 3.2.
# Exit 0 iff every assertion holds.  Run it against another dispatcher with GATE_ACK_SKIP_SELFTEST_DISPATCHER=<file> (the pre-change file must go red).

set -Eeuo pipefail
trap 'echo "FATAL: selftest aborted at line $LINENO (rc=$?) — a command failed outside an assertion"; exit 1' ERR

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${GATE_ACK_SKIP_SELFTEST_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"

PASS=0; FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

[ -r "$DISPATCHER" ] || { echo "FATAL: missing $DISPATCHER"; exit 2; }
command -v jq >/dev/null 2>&1      || { echo "FATAL: jq missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 missing"; exit 2; }
HB=/bin/bash   # the harness runs under the shell the dispatcher is written for (3.2 on the mini)

SB="$(mktemp -d "${TMPDIR:-/tmp}/gate-ack-skip-selftest.XXXXXX")"
CITY="$SB/city"; FAKEBIN="$SB/bin"; mkdir -p "$CITY/.gc" "$CITY/scripts" "$FAKEBIN" "$SB/mut"
cleanup() { rm -rf "$SB" 2>/dev/null || true; }
trap cleanup EXIT

# fakes: gc logs every call (a `session peek` answers a fixed line, `session list --json` answers []), bd-list-cached.sh answers a still-pending verdict bead
cat > "$FAKEBIN/gc" <<'EOF'
#!/bin/bash
echo "gc $*" >> "$FAKE_GC_LOG"
case "$*" in
  *"session peek"*) printf 'quiet\n' ;;
  *"session list"*) printf '[]\n' ;;
esac
exit 0
EOF
cat > "$CITY/scripts/bd-list-cached.sh" <<'EOF'
#!/bin/bash
echo "bd-list-cached $*" >> "$FAKE_BD_LOG"
printf '{"labels":["verdict:pending"]}\n'
EOF
chmod +x "$FAKEBIN/gc" "$CITY/scripts/bd-list-cached.sh"
export FAKE_GC_LOG="$SB/gc.log" FAKE_BD_LOG="$SB/bd.log"
QUIET_CKSUM="$(printf 'quiet\n' | cksum | awk '{print $1}')"

FN_REAL="$SB/fn-real.txt"; BLK_REAL="$SB/blk-real.txt"
sed -n '/# SELFTEST-EXTRACT gate-ack-loop-needed-fn: BEGIN/,/# SELFTEST-EXTRACT gate-ack-loop-needed-fn: END/p' "$DISPATCHER" > "$FN_REAL"
sed -n '/# SELFTEST-EXTRACT step-7b-ack-block: BEGIN/,/# SELFTEST-EXTRACT step-7b-ack-block: END/p' "$DISPATCHER" > "$BLK_REAL"
echo "== gate-ack-skip.selftest (ga-86aie91) =="
if [ ! -s "$FN_REAL" ] || [ ! -s "$BLK_REAL" ]; then
  bad "the dispatcher has no 'gate-ack-loop-needed-fn' and/or 'step-7b-ack-block' SELFTEST-EXTRACT block ($DISPATCHER) — the ACK skip is not there"
  trap - ERR; echo "RESULT: PASS=$PASS FAIL=$FAIL"; exit 1
fi

# mk_unit <name> <fn-file> <setup> <env-prefix> → a script that defines the arrays per <setup>, calls gate_ack_loop_needed and prints its rc
mk_unit() {
  local n="$1" fn="$2" setup="$3" envp="$4"
  { printf '#!/bin/bash\nset -euo pipefail\nexport GC_CITY="%s"\n%s\n%s\n' "$CITY" "$envp" "$setup"
    cat "$fn"
    printf 'rc=0; gate_ack_loop_needed || rc=$?\necho "RC=$rc"\n'; } > "$SB/unit-$n.sh"
  echo "$SB/unit-$n.sh"
}
unit_rc() {  # unit_rc <name> <fn-file> <setup> <env-prefix> → prints the rc of gate_ack_loop_needed, or CRASH (shell: $UNIT_SH, else /bin/bash)
  local f out; f=$(mk_unit "$@")
  if out=$(${UNIT_SH:-$HB} "$f" 2>/dev/null); then printf '%s' "${out##*RC=}"; else printf 'CRASH'; fi
}
unit_expect() {  # unit_expect <name> <fn-file> <setup> <env-prefix> <expected rc> → rc 0 iff gate_ack_loop_needed answered exactly that (quiet)
  [ "$(unit_rc "$1" "$2" "$3" "$4")" = "$5" ]
}

# mk_block <name> <fn-file> <blk-file> <setup> <env-prefix> → a harness: stubs + the arrays of <setup> + the function + the Step 7b region
mk_block() {
  local n="$1" fn="$2" blk="$3" setup="$4" envp="$5"
  { cat <<EOF
#!/bin/bash
set -euo pipefail
export GC_CITY="$CITY" PATH="$FAKEBIN:\$PATH" FAKE_GC_LOG="$SB/gc.log" FAKE_BD_LOG="$SB/bd.log"
OUT="$SB/out-$n.log"; : > "\$OUT"
log()  { echo "LOG \$*"  >> "\$OUT"; }
warn() { echo "WARN \$*" >> "\$OUT"; }
gc_json_or_unknown() { "\$@"; }
session_is_booting() { echo 0; }
session_peek_reports_dead() { echo 0; }
gate_midsweep_collect() { echo "MIDSWEEP \$1" >> "\$OUT"; return 0; }
# the real contract (ga-g3m45n): a retry for a slot whose nudge the queue already accepted does nothing and answers 10
gate_deliver_review_task() { echo "DELIVER slot=\$1 mode=\$6" >> "\$OUT"; if [ "\$6" = retry ] && [ "\${REVIEWER_NUDGE_SENT[\$1]:-0}" = 1 ]; then return 10; fi; REVIEWER_NUDGE_SENT[\$1]=1; return 0; }
RECONVENE_GRACE_SECS=360
$envp
$setup
EOF
    cat "$fn"; cat "$blk"
    printf 'echo "BLOCK_DONE" >> "$OUT"\n'; } > "$SB/blk-$n.sh"
  echo "$SB/blk-$n.sh"
}
# run_block <...mk_block args...> <max-secs> → runs the harness (killed after <max-secs>), prints "<rc>:<elapsed>"; the log is $SB/out-<name>.log
run_block() {
  local n="$1" max="${6:-30}" f t0 pid rc i=0
  f=$(mk_block "$1" "$2" "$3" "$4" "$5")
  : > "$FAKE_GC_LOG"; : > "$FAKE_BD_LOG"
  t0=$(date +%s)
  $HB "$f" >/dev/null 2>"$SB/err-$n.log" & pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $((max * 5)) ]; do sleep 0.2; i=$((i+1)); done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null || true; sleep 0.2; kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rc=124
  else wait "$pid" 2>/dev/null && rc=0 || rc=$?; fi
  echo "$rc:$(( $(date +%s) - t0 ))"
}
out_has()  { grep -q -- "$2" "$SB/out-$1.log" 2>/dev/null; }
out_cnt()  { grep -c -- "$2" "$SB/out-$1.log" 2>/dev/null || true; }

# slot setups: 1 reviewer, nudge flag <v>
slot1() { printf 'VERDICT_BEAD_IDS=(vb1); SESSION_IDS=(s1); REVIEWER_ACKED=(0); REVIEWER_PEEK_BASELINE=(%s); REVIEW_TASKS=(task); SLOT_SPAWN_EPOCH=(%s); %s\n' "$QUIET_CKSUM" "$(date +%s)" "$1"; }

# ── 1. the decision, unit level ─────────────────────────────────────────────────────────────────────────────────────
echo "-- 1. gate_ack_loop_needed"
S_ACC="$(slot1 'REVIEWER_NUDGE_SENT=(1)')"
S_REF="$(slot1 'REVIEWER_NUDGE_SENT=(0)')"
S_UNS="$(slot1 'REVIEWER_NUDGE_SENT=()')"
S_JNK="$(slot1 'REVIEWER_NUDGE_SENT=(x)')"
S_TWO='VERDICT_BEAD_IDS=(vb1 vb2); SESSION_IDS=(s1 s2); REVIEWER_ACKED=(0 0); REVIEWER_NUDGE_SENT=(1 1)'
S_MIX="VERDICT_BEAD_IDS=(vb1 vb2); SESSION_IDS=(s1 s2); REVIEWER_ACKED=(0 0); REVIEWER_NUDGE_SENT=(1 0); REVIEWER_PEEK_BASELINE=($QUIET_CKSUM $QUIET_CKSUM); REVIEW_TASKS=(t1 t2); SLOT_SPAWN_EPOCH=($(date +%s) $(date +%s))"
S_ACKD='VERDICT_BEAD_IDS=(vb1); SESSION_IDS=(s1); REVIEWER_ACKED=(1); REVIEWER_NUDGE_SENT=(0)'
S_NONE='VERDICT_BEAD_IDS=(); SESSION_IDS=(); REVIEWER_ACKED=(); REVIEWER_NUDGE_SENT=()'
S_UNDECL='REVIEWER_ACKED=(0); REVIEWER_NUDGE_SENT=(1)'
unit_u() {   # unit_u <label> <name> <setup> <env> <expected rc>   (real function)
  if unit_expect "$2" "$FN_REAL" "$3" "${4:-}" "$5"; then ok "$1 → rc $5"; else bad "$1 → expected rc $5, got $(unit_rc "$2" "$FN_REAL" "$3" "${4:-}")"; fi
}
unit_u "every nudge accepted (1 slot) = skip"                         u1  "$S_ACC"    ""                       1
unit_u "every nudge accepted (2 slots) = skip"                        u2  "$S_TWO"    ""                       1
unit_u "first send refused (0) = the loop runs"                       u3  "$S_REF"    ""                       0
unit_u "slot nobody filled in (unset) = the loop runs"                u4  "$S_UNS"    ""                       0
unit_u "junk flag = the loop runs"                                    u5  "$S_JNK"    ""                       0
unit_u "one accepted + one refused = the loop runs"                   u6  "$S_MIX"    ""                       0
unit_u "refused but already ACKed = nothing to do = skip"             u7  "$S_ACKD"   ""                       1
unit_u "no slots = the loop runs (old behaviour, the inert state)"    u8  "$S_NONE"   ""                       0
unit_u "array not declared (set -u, /bin/bash) = the loop runs, no crash" u9  "$S_UNDECL" ""                    0
if UNIT_SH=bash unit_expect u9b "$FN_REAL" "$S_UNDECL" "" 0; then ok "array not declared (set -u, $(bash --version | head -1 | cut -c1-24)) → rc 0, no crash"; else bad "array not declared crashes or skips under $(bash --version | head -1 | cut -c1-24)"; fi
unit_u "GATE_ACK_SKIP=0 = the loop runs"                              u10 "$S_ACC"    "export GATE_ACK_SKIP=0" 0
unit_u "GATE_ACK_SKIP=1 = skip"                                       u11 "$S_ACC"    "export GATE_ACK_SKIP=1" 1
unit_u "GATE_ACK_SKIP typo = the skip stays ON"                       u12 "$S_ACC"    "export GATE_ACK_SKIP=banana" 1
touch "$CITY/.gc/gate-ack-skip.off"
unit_u "off-file present = the loop runs"                             u13 "$S_ACC"    ""                       0
rm -f "$CITY/.gc/gate-ack-skip.off"
mkdir "$CITY/.gc/gate-ack-skip.off"
unit_u "off-file is a directory (cannot be read as a file) = the loop runs" u14 "$S_ACC" ""                    0
rmdir "$CITY/.gc/gate-ack-skip.off"
unit_u "off-file removed = skip again"                                u15 "$S_ACC"    ""                       1

# ── 2/3. the Step 7b region, behaviour ──────────────────────────────────────────────────────────────────────────────
# Each scenario function returns 0 iff its property holds on the files given (so section 6 can run them on mutated copies).
sc_skip_all_accepted() {   # <fn-file> <blk-file> <name>   all nudges accepted, ACK_WAIT_SECS=20 as in production
  local r; r=$(run_block "$3" "$1" "$2" "$S_ACC" "export ACK_WAIT_SECS=20" 8)
  [ "${r%%:*}" = "0" ] || return 1                                    # finished (not killed, not crashed)
  [ "${r##*:}" -le 5 ] || return 2                                    # …without the 4 x (reads + 20 s) the old loop spent
  out_has "$3" 'Step 7b (ga-86aie91)' || return 3                     # says why
  [ "$(out_cnt "$3" 'No ACK from reviewer')" = "0" ] || return 4
  [ "$(out_cnt "$3" 'never ACKed')" = "0" ] || return 5               # it tried nothing, so it reports no attempts
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-skip')" = "1" ] || return 6     # the stand-in safe point, once
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-ack')" = "0" ] || return 7
  [ "$(out_cnt "$3" 'DELIVER')" = "0" ] || return 8
  [ ! -s "$FAKE_GC_LOG" ] || return 9                                 # no `gc session peek/list`
  [ ! -s "$FAKE_BD_LOG" ] || return 10                                # no bd read
  out_has "$3" 'BLOCK_DONE' || return 11
  return 0
}
sc_loop_runs() {   # <fn-file> <blk-file> <name> <setup> <env> <expect-deliver-slot>   the loop must run as before
  local r; r=$(run_block "$3" "$1" "$2" "$4" "export ACK_MAX_RETRIES=3 ACK_WAIT_SECS=1; $5" 20)
  [ "${r%%:*}" = "0" ] || return 1
  [ "${r##*:}" -ge 2 ] || return 2                                    # it waited (3 attempts, 1 s between)
  ! out_has "$3" 'Step 7b (ga-86aie91)' || return 3
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-skip')" = "0" ] || return 4
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-ack')" -ge 1 ] || return 5      # the loop's own safe point
  out_has "$3" "DELIVER slot=$6 mode=retry" || return 6               # the retry that is the loop's one real effect
  out_has "$3" 'never ACKed after 3 attempts' || return 7             # nothing ACKed: still reported
  [ -s "$FAKE_GC_LOG" ] || return 8                                   # it read (peek/list)
  out_has "$3" 'BLOCK_DONE' || return 9
  return 0
}
echo "-- 2. every nudge accepted: the region does not wait"
if sc_skip_all_accepted "$FN_REAL" "$BLK_REAL" s_skip; then ok "returns at once (ACK_WAIT_SECS=20), no reads, one step-7b-skip collect, no 'never ACKed', says why"
else bad "skip scenario failed (code $?) — see $SB/out-s_skip.log"; sed -n 1,12p "$SB/out-s_skip.log" 2>/dev/null | cut -c1-200; fi
echo "-- 3. a slot the loop can still re-queue (or a kill switch): the loop runs as before"
if sc_loop_runs "$FN_REAL" "$BLK_REAL" s_ref  "$S_REF" "" 0; then ok "first send refused → retry delivered, step-7b-ack collects, 'never ACKed' reported"; else bad "refused-slot scenario failed (code $?)"; fi
if sc_loop_runs "$FN_REAL" "$BLK_REAL" s_uns  "$S_UNS" "" 0; then ok "unset slot (E5-like) → the loop runs"; else bad "unset-slot scenario failed (code $?)"; fi
if sc_loop_runs "$FN_REAL" "$BLK_REAL" s_jnk  "$S_JNK" "" 0; then ok "junk flag → the loop runs"; else bad "junk-flag scenario failed (code $?)"; fi
if sc_loop_runs "$FN_REAL" "$BLK_REAL" s_mix  "$S_MIX" "" 1; then ok "one accepted + one refused → the loop runs and re-queues the refused one (slot 1)"; else bad "mixed scenario failed (code $?)"; fi
if sc_loop_runs "$FN_REAL" "$BLK_REAL" s_ksw  "$S_REF" "export GATE_ACK_SKIP=0" 0; then ok "GATE_ACK_SKIP=0 with a refused slot → the loop runs"; else bad "kill-switch (env) scenario failed (code $?)"; fi
# a kill switch must restore the OLD loop even when every nudge was accepted (that is its whole point): it waits, its retry is dismissed with rc 10
sc_old_loop_all_accepted() {   # <fn-file> <blk-file> <name> <env>
  local r; r=$(run_block "$3" "$1" "$2" "$S_ACC" "export ACK_MAX_RETRIES=3 ACK_WAIT_SECS=1; $4" 20)
  [ "${r%%:*}" = "0" ] || return 1
  [ "${r##*:}" -ge 2 ] || return 2
  out_has "$3" 'NOT stacking another copy' || return 3
  out_has "$3" 'DELIVER slot=0 mode=retry' || return 4
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-ack')" -ge 1 ] || return 5
  [ "$(out_cnt "$3" 'MIDSWEEP step-7b-skip')" = "0" ] || return 6
  ! out_has "$3" 'Step 7b (ga-86aie91)' || return 7
  return 0
}
if sc_old_loop_all_accepted "$FN_REAL" "$BLK_REAL" s_ksw2 "export GATE_ACK_SKIP=0"; then ok "GATE_ACK_SKIP=0 with every nudge accepted → the old loop (waits, retry dismissed with rc 10)"; else bad "kill switch (env) did not bring the old loop back (code $?)"; fi
touch "$CITY/.gc/gate-ack-skip.off"
if sc_old_loop_all_accepted "$FN_REAL" "$BLK_REAL" s_ksw3 ""; then ok "off-file with every nudge accepted → the old loop"; else bad "off-file did not bring the old loop back (code $?)"; fi
rm -f "$CITY/.gc/gate-ack-skip.off"

# ── 4. the live wiring ──────────────────────────────────────────────────────────────────────────────────────────────
echo "-- 4. the live file"
D="$DISPATCHER"
_ack_line="$(grep -n '^  gate_midsweep_collect "step-7b-ack"' "$D" | cut -d: -f1 || true)"
_sleep_line="$(grep -n '^  sleep "\$ACK_WAIT_SECS" || true' "$D" | cut -d: -f1 || true)"
if [ -n "$_ack_line" ] && [ -n "$_sleep_line" ] && [ "$(printf '%s\n' "$_ack_line" | wc -l | tr -d ' ')" = "1" ] && [ "$_ack_line" -lt "$_sleep_line" ] && [ $((_sleep_line - _ack_line)) -le 2 ]; then
  ok "the loop's step-7b-ack call is still the one line right before its sleep (other selftests pin it)"; else bad "step-7b-ack/sleep lines moved or duplicated (call=$_ack_line sleep=$_sleep_line)"; fi
_fn_line="$(grep -n '^gate_ack_loop_needed()' "$D" | head -1 | cut -d: -f1 || true)"; _use_line="$(grep -n '^if ! gate_ack_loop_needed; then' "$D" | head -1 | cut -d: -f1 || true)"
if [ -n "$_fn_line" ] && [ -n "$_use_line" ] && [ "$_fn_line" -lt "$_use_line" ]; then ok "gate_ack_loop_needed is defined before Step 7b uses it"; else bad "gate_ack_loop_needed is not defined before its use (def=$_fn_line use=$_use_line)"; fi
_skip_calls="$(grep -c '^\[ "\$ACK_LOOP_SKIPPED" != "1" \] || gate_midsweep_collect "step-7b-skip" || true$' "$D" || true)"
if [ "$_skip_calls" = "1" ]; then ok "exactly one column-0 'A || safe-point || true' step-7b-skip call"; else bad "expected one step-7b-skip call at column 0, found $_skip_calls"; fi
_nested="$(grep -n '^[[:space:]]\+gate_midsweep_collect ' "$D" | grep -v 'step-7b-ack' | grep -v '^[0-9]*:[[:space:]]*#' | wc -l | tr -d ' ' || true)"
if [ "$_nested" = "0" ]; then ok "no other safe-point call is nested in a block"; else bad "$_nested nested safe-point call(s) other than step-7b-ack"; fi
# nothing outside the loop READS the ACK flag (the premise of the skip). Assignments (`REVIEWER_ACKED[…]=`, `+=(`, `=()`) are writes, not reads.
_b0="$(grep -n 'SELFTEST-EXTRACT step-7b-ack-block: BEGIN' "$D" | head -1 | cut -d: -f1 || true)"; _b1="$(grep -n 'SELFTEST-EXTRACT step-7b-ack-block: END' "$D" | head -1 | cut -d: -f1 || true)"
_f0="$(grep -n 'SELFTEST-EXTRACT gate-ack-loop-needed-fn: BEGIN' "$D" | head -1 | cut -d: -f1 || true)"; _f1="$(grep -n 'SELFTEST-EXTRACT gate-ack-loop-needed-fn: END' "$D" | head -1 | cut -d: -f1 || true)"
_readers=""
while IFS= read -r _l; do
  [ -n "$_l" ] || continue
  _n="${_l%%:*}"; _txt="${_l#*:}"
  case "$_txt" in [[:space:]]*"#"*) case "${_txt#"${_txt%%[![:space:]]*}"}" in "#"*) continue ;; esac ;; esac
  if { [ "$_n" -ge "${_b0:-0}" ] && [ "$_n" -le "${_b1:-0}" ]; } || { [ "$_n" -ge "${_f0:-0}" ] && [ "$_n" -le "${_f1:-0}" ]; }; then continue; fi
  _readers="$_readers $_n"
done <<EOF2
$(grep -nE '\$\{[#!]?REVIEWER_ACKED' "$D" || true)
EOF2
_readers_other="$(grep -nE '\$\{[#!]?REVIEWER_ACKED' "$SELF_DIR"/*.sh 2>/dev/null | grep -v 'selftest.sh' | grep -v 'quality-gate-dispatcher.sh' | cut -c1-140 || true)"
if [ -z "$_readers" ] && [ -z "$_readers_other" ]; then ok "REVIEWER_ACKED is read only inside the Step 7b region and the skip function (the wait changes nothing anyone else sees)"
else bad "REVIEWER_ACKED has a reader outside the loop — the skip's premise no longer holds: ${_readers:-}${_readers_other:-}"; fi

# ── 5. syntax ───────────────────────────────────────────────────────────────────────────────────────────────────────
echo "-- 5. syntax"
if bash -n "$D" 2>/dev/null; then ok "bash -n (default bash)"; else bad "bash -n failed"; fi
if $HB -n "$D" 2>/dev/null; then ok "/bin/bash -n ($($HB --version | head -1 | cut -c1-34))"; else bad "/bin/bash -n failed"; fi

# ── 6. mutants: each guard must turn something red ─────────────────────────────────────────────────────────────────
echo "-- 6. mutants (each must be caught)"
mutate() {   # mutate <src-file> <dst-file> <old> <new>   → rc 0 iff <old> was found exactly once and replaced (a vacuous mutant is a test bug)
  OLD="$3" NEW="$4" SRC="$1" DST="$2" python3 -I - <<'PYEOF'
import os, sys
s = open(os.environ['SRC']).read(); o = os.environ['OLD']
if s.count(o) != 1:
    sys.stderr.write("mutant pattern found %d times: %r\n" % (s.count(o), o)); sys.exit(3)
open(os.environ['DST'], 'w').write(s.replace(o, os.environ['NEW']))
PYEOF
}
catch() {   # catch <label> <rc-of-scenario-on-mutant>   (non-zero = the suite noticed)
  if [ "$2" != "0" ]; then ok "mutant caught: $1"; else bad "mutant SURVIVED: $1"; fi
}
mk_mut() {  # mk_mut <name> <which: fn|blk> <old> <new> → sets MFN / MBLK
  MFN="$FN_REAL"; MBLK="$BLK_REAL"
  if [ "$2" = fn ]; then mutate "$FN_REAL" "$SB/mut/$1.fn" "$3" "$4" || { bad "mutant $1 is vacuous"; return 1; }; MFN="$SB/mut/$1.fn"
  else mutate "$BLK_REAL" "$SB/mut/$1.blk" "$3" "$4" || { bad "mutant $1 is vacuous"; return 1; }; MBLK="$SB/mut/$1.blk"; fi
}
m_rc() { local rc=0; "$@" || rc=$?; echo "$rc"; }

# M1 the function always says "skip": a refused slot is no longer re-queued
if mk_mut m1 fn '    [ "${REVIEWER_NUDGE_SENT[$_k]:-0}" = "1" ] || return 0' '    :'; then catch "always skip (a refused slot is never re-queued)" "$(m_rc sc_loop_runs "$MFN" "$MBLK" m1 "$S_REF" "" 0)"; fi
# M2 the function never says "skip": the wait is back
if mk_mut m2 fn '  return 1
}' '  return 0
}'; then catch "never skip (the 150 s wait is back)" "$(m_rc sc_skip_all_accepted "$MFN" "$MBLK" m2)"; fi
# M3 an unset flag counts as accepted
if mk_mut m3 fn '"${REVIEWER_NUDGE_SENT[$_k]:-0}" = "1" ] || return 0' '"${REVIEWER_NUDGE_SENT[$_k]:-1}" = "1" ] || return 0'; then catch "unset flag read as accepted (E5-like slot loses its retry)" "$(m_rc sc_loop_runs "$MFN" "$MBLK" m3 "$S_UNS" "" 0)"; fi
# M4 any non-empty flag counts as accepted
if mk_mut m4 fn '"${REVIEWER_NUDGE_SENT[$_k]:-0}" = "1" ] || return 0' '"${REVIEWER_NUDGE_SENT[$_k]:-0}" != "0" ] || return 0'; then catch "junk flag read as accepted" "$(m_rc sc_loop_runs "$MFN" "$MBLK" m4 "$S_JNK" "" 0)"; fi
# M5 the env kill switch is ignored
if mk_mut m5 fn '  case "${GATE_ACK_SKIP:-1}" in 0) return 0 ;; esac' '  :'; then catch "GATE_ACK_SKIP=0 ignored (checked where only the switch can bring the loop back)" "$(m_rc sc_old_loop_all_accepted "$MFN" "$MBLK" m5 "export GATE_ACK_SKIP=0")"; fi
# M6 the off-file is ignored (checked with every nudge accepted, where only the switch can bring the loop back)
if mk_mut m6 fn '  if [ -e "${GC_CITY:-/nonexistent}/.gc/gate-ack-skip.off" ]; then return 0; fi' '  :'; then
  touch "$CITY/.gc/gate-ack-skip.off"; r6=$(run_block m6 "$MFN" "$MBLK" "$S_ACC" "export ACK_MAX_RETRIES=3 ACK_WAIT_SECS=1" 20); rm -f "$CITY/.gc/gate-ack-skip.off"
  if [ "${r6##*:}" -ge 2 ]; then bad "mutant SURVIVED: off-file ignored"; else ok "mutant caught: off-file ignored"; fi
fi
# M7 a slot already ACKed no longer counts as done
if mk_mut m7 fn '    [ "${REVIEWER_ACKED[$_k]:-0}" = "1" ] && continue' '    :'; then catch "ACKed slot with a refused flag keeps the loop alive" "$(m_rc unit_expect m7 "$MFN" "$S_ACKD" "" 1)"; fi
# M8 no-slot / undeclared-array guards removed
if mk_mut m8 fn '  declare -p VERDICT_BEAD_IDS >/dev/null 2>&1 || return 0' '  :'; then catch "undeclared array crashes under set -u (bash 5; /bin/bash 3.2 is covered by the next guard)" "$(UNIT_SH=bash m_rc unit_expect m8 "$MFN" "$S_UNDECL" "" 0)"; fi
if mk_mut m9 fn '  [ "${#VERDICT_BEAD_IDS[@]}" -gt 0 ] || return 0' '  :'; then catch "no slots reads as 'skip'" "$(m_rc unit_expect m9 "$MFN" "$S_NONE" "" 0)"; fi
# M10 the loop still runs although the decision said skip
if mk_mut m10 blk '  [ "$ACK_LOOP_SKIPPED" != "1" ] || break' '  :'; then catch "skip decided but the loop still runs" "$(m_rc sc_skip_all_accepted "$MFN" "$MBLK" m10)"; fi
# M11 the 'never ACKed' report is not guarded: a loop that was not run reports attempts it did not make
if mk_mut m11 blk 'if [ "$ACK_LOOP_SKIPPED" != "1" ] && [ "${REVIEWER_ACKED[$k]:-0}" != "1" ]; then' 'if [ "${REVIEWER_ACKED[$k]:-0}" != "1" ]; then'; then catch "'never ACKed after N attempts' printed for a loop that never ran" "$(m_rc sc_skip_all_accepted "$MFN" "$MBLK" m11)"; fi
# M12 the stand-in safe point is dropped: deferred finished runs are not collected once the last marker is admitted
if mk_mut m12 blk '[ "$ACK_LOOP_SKIPPED" != "1" ] || gate_midsweep_collect "step-7b-skip" || true' ':'; then catch "step-7b-skip collect dropped" "$(m_rc sc_skip_all_accepted "$MFN" "$MBLK" m12)"; fi
# M13 the stand-in runs although the loop ran (a second collect on top of the loop's own)
if mk_mut m13 blk '[ "$ACK_LOOP_SKIPPED" != "1" ] || gate_midsweep_collect "step-7b-skip" || true' 'gate_midsweep_collect "step-7b-skip" || true'; then catch "step-7b-skip collect also after a loop that ran" "$(m_rc sc_loop_runs "$MFN" "$MBLK" m13 "$S_REF" "" 0)"; fi
# M14 the decision is never taken (the call is dropped): the flag stays 0 and the loop runs
if mk_mut m14 blk 'if ! gate_ack_loop_needed; then' 'if false; then'; then catch "decision never taken" "$(m_rc sc_skip_all_accepted "$MFN" "$MBLK" m14)"; fi

trap - ERR
echo "RESULT: PASS=$PASS FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi

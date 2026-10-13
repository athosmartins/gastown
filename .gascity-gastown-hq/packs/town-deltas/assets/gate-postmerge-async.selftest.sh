#!/usr/bin/env bash
# gate-postmerge-async.selftest.sh — ga-qmymjm: the post-merge tail runs beside the sweep, not inside it.
#
# WHAT IT PROVES (each with a mutation that must turn it red — section 7):
#   1. The REAL fork block of quality-gate-dispatcher.sh (extracted by its SELFTEST-EXTRACT markers) returns to the sweep without waiting for the
#      tail, the tail runs in its OWN process group (launchd kills the sweep's group when it exits), and it finishes and leaves one postmerge_done.
#   2. A tail that fails (errexit mid-way, TERM) leaves postmerge_failed + a failed/ job + label/comment on the bead + a nudge, and stops at the
#      failing command. A tail that vanishes (SIGKILL) is found by the next sweep: reported ONCE (event, label, comment, nudge), never re-run,
#      and a LIVE tail or one inside its start grace is never reported.
#   3. Switch off (env / file), DRY_RUN=1, no lib, an unwritable job directory: the tail runs INLINE in the sweep's own shell (a variable it sets is
#      visible afterwards), with no job file and no event.
#   4. The deploy lock serialises two tails, takes over a dead / over-age / ownerless-and-old owner, gives up with rc 75 on a live one, and only
#      releases its own lock.
#   5. Static wiring on the live file: what must stay synchronous (merge, integrity check, marker/run terminal, supersede) is outside the tail, what
#      moved (deploy, hold-or-close, verify, reap, notify) is inside it, the sweep calls gate_pm_sweep, both files pass bash -n (3.2).
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
LIB="$SELF_DIR/gate-postmerge.lib.sh"

PASS=0; FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }

for f in "$DISPATCHER" "$LIB"; do [ -r "$f" ] || { echo "FATAL: missing $f"; exit 2; }; done
command -v jq >/dev/null 2>&1      || { echo "FATAL: jq missing"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 missing"; exit 2; }

SB="$(mktemp -d "${TMPDIR:-/tmp}/gate-pm-selftest.XXXXXX")"
CITY="$SB/city"; FAKEBIN="$SB/bin"; mkdir -p "$CITY/.gc" "$FAKEBIN" "$SB/logs" "$SB/mut"
cleanup() {
  # stray tails / sleepers started by this run all carry the sandbox path in their command line
  pkill -f "$SB" 2>/dev/null || true
  sleep 0.2
  rm -rf "$SB" 2>/dev/null || true
}
trap cleanup EXIT

cat > "$FAKEBIN/bd" <<'EOF'
#!/bin/bash
echo "bd $*" >> "$FAKE_BD_LOG"
exit "${FAKE_BD_RC:-0}"
EOF
cat > "$FAKEBIN/gc" <<'EOF'
#!/bin/bash
echo "gc $*" >> "$FAKE_GC_LOG"
exit 0
EOF
chmod +x "$FAKEBIN/bd" "$FAKEBIN/gc"
export FAKE_BD_LOG="$SB/bd.log" FAKE_GC_LOG="$SB/gc.log"
: > "$FAKE_BD_LOG"; : > "$FAKE_GC_LOG"
export GC_CITY="$CITY" QG_LOG="$CITY/.gc/quality-gate.jsonl" PATH="$FAKEBIN:$PATH"
: > "$QG_LOG"
PMDIR="$CITY/.gc/runtime/gate-postmerge"

TW=20   # seconds a scenario waits for each thing it expects (the mutation section lowers it: a mutant that never gets there should fail fast)
wait_until() { local t="$1" i=0; shift; while [ "$i" -lt $((t * 10)) ]; do if "$@"; then return 0; fi; sleep 0.1; i=$((i+1)); done; return 1; }
ev_count() { jq -c --arg e "$1" --arg r "$2" 'select(.event==$e and .gate_run==$r)' "$QG_LOG" 2>/dev/null | wc -l | tr -d ' '; }
ev_field() { jq -r --arg e "$1" --arg r "$2" --arg f "$3" 'select(.event==$e and .gate_run==$r) | .[$f] // empty' "$QG_LOG" 2>/dev/null | head -n1; }
file_has() { grep -q -- "$2" "$1" 2>/dev/null; }
pid_gone() { [ -z "$(ps -p "$1" -o pid= 2>/dev/null | tr -d ' ')" ]; }

# mk_harness <name> <lib-path|NONE> <fork-block-file> <tail-body> <after-body>  → path of a runnable "sweep" script.
# The script is what gate_finalize_run looks like around the fork block: the lib sourced (or not), the job identity globals, a stand-in
# _gate_pm_tail, then the REAL fork block, then <after-body>.
mk_harness() {
  H_NAME="$1" H_LIB="$2" H_FORK="$3" H_TAIL="$4" H_AFTER="$5" H_SB="$SB" H_CITY="$CITY" H_FAKEBIN="$FAKEBIN" python3 -I - <<'PYEOF'
import os
e=os.environ
n=e['H_NAME']
fork=open(e['H_FORK']).read()
src='. "%s"' % e['H_LIB'] if e['H_LIB']!='NONE' else ':'
libok='1' if e['H_LIB']!='NONE' else '0'
out='''#!/bin/bash
set -euo pipefail
export GC_CITY="{city}" QG_LOG="{city}/.gc/quality-gate.jsonl" GATE_PM_PROC_PATTERN="{n}.sh"
export PATH="{fb}:$PATH" FAKE_BD_LOG="{sb}/bd.log" FAKE_GC_LOG="{sb}/gc.log"
LOG_DIR="{sb}/logs"
log()  {{ echo "LOG $*" >> "{sb}/{n}.log"; }}
warn() {{ echo "WARN $*" >> "{sb}/{n}.log"; }}
err()  {{ echo "ERR $*" >> "{sb}/{n}.log"; }}
{src}
GATE_PM_LIB_OK={libok}
GATE_RUN_ID="${{PM_RUN:-ga-run-{n}}}"; MARKER_ID="ga-mk-{n}"; BEAD_ID="ga-bead-{n}"; BEAD_CITY="$GC_CITY"; RIG="rig1"; BRANCH="fix/x"; MERGE_SHA="deadbeef"; DRY_RUN="${{PM_DRY:-0}}"
ps -o pgid= -p $$ | tr -d ' ' > "{sb}/{n}.parent.pgid"
echo $$ > "{sb}/{n}.parent.pid"
_gate_pm_tail() {{
{tail}
}}
{fork}
{after}
'''.format(city=e['H_CITY'],n=n,fb=e['H_FAKEBIN'],sb=e['H_SB'],src=src,libok=libok,tail=e['H_TAIL'],fork=fork,after=e['H_AFTER'])
open('%s/%s.sh' % (e['H_SB'],n),'w').write(out)
PYEOF
  echo "$SB/$1.sh"
}

FORK_REAL="$SB/fork-real.txt"
sed -n '/# SELFTEST-EXTRACT postmerge-fork: BEGIN/,/# SELFTEST-EXTRACT postmerge-fork: END/p' "$DISPATCHER" > "$FORK_REAL"
[ -s "$FORK_REAL" ] || { echo "FATAL: no 'postmerge-fork' block in $DISPATCHER"; exit 2; }

echo "== gate-postmerge-async.selftest (ga-qmymjm) =="

# ── scenario runners: return 0 iff the property holds. Section 1-3 call them with the real files; section 7 with mutated copies. ──
# $1 = lib path, $2 = fork-block file, $3 = unique name
sc_async_detach() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3"
  h=$(mk_harness "$n" "$lib" "$fork" \
'gate_pm_step "source-bead"; IS_STORY=1
sh -c "ps -o pgid= -p \$PPID" | tr -d " " > "'"$SB/$n"'.tail.pgid"
echo $(exec sh -c "echo \$PPID") > "'"$SB/$n"'.tail.pid"
cat "'"$PMDIR"'/pending/'"$run"'.pid" > "'"$SB/$n"'.tail.pidfile"
echo "${_GATE_HB_FILE:-unset}" > "'"$SB/$n"'.tail.hb"
sleep 3; date +%s > "'"$SB/$n"'.tail.end"; echo ran >> "'"$SB/$n"'.tail.runs"' \
'date +%s > "'"$SB/$n"'.fork.ret"; echo "INLINE_SET=${IS_STORY:-unset}" > "'"$SB/$n"'.after"')
  /bin/bash "$h" >/dev/null 2>&1 &
  wait_until "$TW" test -e "$SB/$n.tail.end" || return 1
  wait_until "$TW" test ! -e "$PMDIR/pending/$run.job" || return 1
  [ "$(cat "$SB/$n.tail.runs" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] || return 2
  [ "$(cat "$SB/$n.fork.ret")" -le $(( $(cat "$SB/$n.tail.end") - 2 )) ] || return 3          # the sweep did not wait for the 3 s tail
  [ "$(cat "$SB/$n.tail.pgid")" != "$(cat "$SB/$n.parent.pgid")" ] || return 4                # own process group
  [ "$(cat "$SB/$n.tail.pgid")" = "$(cat "$SB/$n.tail.pid")" ] || return 5                    # …and it leads it
  [ "$(cat "$SB/$n.tail.pidfile")" = "$(cat "$SB/$n.tail.pid")" ] || return 13                 # the pid file holds the tail's OWN pid (not a transient fork of it)
  [ "$(cat "$SB/$n.after")" = "INLINE_SET=unset" ] || return 6                                  # a subshell: nothing it set comes back
  [ "$(ev_count postmerge_deferred "$run")" = "1" ] || return 7
  [ "$(ev_count postmerge_done "$run")" = "1" ] || return 8
  [ "$(ev_field postmerge_done "$run" outcome)" = "handoff" ] || return 9
  [ "$(ev_count postmerge_failed "$run")" = "0" ] || return 10
  [ ! -e "$PMDIR/pending/$run.pid" ] && [ ! -e "$PMDIR/pending/$run.step" ] || return 11
  case "$(cat "$SB/$n.tail.hb")" in *quality-gate-postmerge.heartbeat) : ;; *) return 12 ;; esac    # log() in the tail must not vouch for the sweep
  return 0
}

sc_failure_errexit() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3"
  h=$(mk_harness "$n" "$lib" "$fork" \
'gate_pm_step "deploy"; false; echo unreachable >> "'"$SB/$n"'.unreachable"' \
'sleep 0.2')
  /bin/bash "$h" >/dev/null 2>&1 &
  wait_until "$TW" test -e "$PMDIR/failed/$run.job" || return 1
  [ "$(ev_count postmerge_failed "$run")" = "1" ] || return 2
  [ "$(ev_field postmerge_failed "$run" step)" = "deploy" ] || return 3
  [ "$(ev_field postmerge_failed "$run" rc)" = "1" ] || return 4
  [ ! -e "$SB/$n.unreachable" ] || return 5                                                      # errexit stopped the tail at the failing command
  [ "$(ev_count postmerge_done "$run")" = "0" ] || return 6
  [ ! -e "$PMDIR/pending/$run.job" ] || return 7
  file_has "$PMDIR/failed/$run.job" "step=deploy" || return 8
  # the exit handler moves the job file first and flags the bead after: wait for the flags too
  wait_until "$TW" file_has "$FAKE_GC_LOG" "session nudge mayor Gate post-merge tail FAILED for ga-bead-$n" || return 11
  file_has "$FAKE_BD_LOG" "label add ga-bead-$n gate:postmerge-failed" || return 9
  file_has "$FAKE_BD_LOG" "comment ga-bead-$n GATE POST-MERGE TAIL FAILED" || return 10
  return 0
}

sc_failure_term() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3" pid
  h=$(mk_harness "$n" "$lib" "$fork" \
'gate_pm_step "notify"; i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done' 'sleep 0.2')
  /bin/bash "$h" >/dev/null 2>&1 &
  wait_until "$TW" test -s "$PMDIR/pending/$run.pid" || return 1
  wait_until 5 test -s "$PMDIR/pending/$run.step" || return 1
  pid=$(cat "$PMDIR/pending/$run.pid")
  kill -TERM "$pid" 2>/dev/null || return 2
  wait_until "$TW" test -e "$PMDIR/failed/$run.job" || return 3
  [ "$(ev_field postmerge_failed "$run" rc)" = "143" ] || return 4
  [ "$(ev_field postmerge_failed "$run" step)" = "notify" ] || return 5
  return 0
}

# the sweep that finds a tail killed with SIGKILL. Runs gate_pm_sweep in a fresh process, as the next dispatcher sweep would.
run_sweep() { # <name> [env assignments...]
  local n="$1"; shift
  ( env "$@" GC_CITY="$CITY" QG_LOG="$QG_LOG" PATH="${SWEEP_PATH:-$PATH}" FAKE_BD_LOG="$FAKE_BD_LOG" FAKE_GC_LOG="$FAKE_GC_LOG" LIB="$LIB_UNDER_TEST" SBX="$SB" NAME="$n" \
      /bin/bash -c 'set -euo pipefail; log(){ echo "LOG $*" >> "$SBX/$NAME.sweep.log"; }; warn(){ echo "WARN $*" >> "$SBX/$NAME.sweep.log"; }; . "$LIB"; gate_pm_sweep' ) >/dev/null 2>&1
}

sc_lost_sigkill() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3" pid
  LIB_UNDER_TEST="$lib"
  h=$(mk_harness "$n" "$lib" "$fork" \
'gate_pm_step "deploy"; i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done' 'sleep 0.2')
  /bin/bash "$h" >/dev/null 2>&1 &
  wait_until "$TW" test -s "$PMDIR/pending/$run.pid" || return 1
  wait_until 5 test -s "$PMDIR/pending/$run.step" || return 1
  pid=$(cat "$PMDIR/pending/$run.pid")
  # a LIVE tail must not be reported
  run_sweep "$n" "GATE_PM_PROC_PATTERN=$n.sh"
  [ "$(ev_count postmerge_lost "$run")" = "0" ] || return 2
  [ -e "$PMDIR/pending/$run.job" ] || return 3
  kill -9 "$pid" 2>/dev/null || return 4
  wait_until 5 pid_gone "$pid" || return 14
  run_sweep "$n" "GATE_PM_PROC_PATTERN=$n.sh"
  [ "$(ev_count postmerge_lost "$run")" = "1" ] || return 5
  [ "$(ev_field postmerge_lost "$run" step)" = "deploy" ] || return 6
  [ -e "$PMDIR/lost/$run.job" ] && [ ! -e "$PMDIR/pending/$run.job" ] || return 7
  file_has "$PMDIR/lost/$run.job" "step=deploy" || return 8
  file_has "$FAKE_BD_LOG" "label add ga-bead-$n gate:postmerge-lost" || return 9
  file_has "$FAKE_BD_LOG" "comment ga-bead-$n GATE POST-MERGE TAIL LOST" || return 10
  file_has "$FAKE_GC_LOG" "session nudge mayor Gate post-merge tail LOST for ga-bead-$n" || return 11    # run_sweep is synchronous: all three are written by now
  run_sweep "$n" "GATE_PM_PROC_PATTERN=$n.sh"                                                    # once: a second sweep says nothing more
  [ "$(ev_count postmerge_lost "$run")" = "1" ] || return 12
  [ "$(ev_count postmerge_done "$run")" = "0" ] || return 13                                     # and it was not re-run
  pkill -f "$SB/$n" 2>/dev/null || true
  return 0
}

# a live tail whose command line ps cannot give: "lost" is a claim the sweep cannot back → stay quiet. A readable command line that is NOT the
# dispatcher (pid reused by something else) → the tail is gone → lost.
sc_ps_unreadable() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3" pid
  LIB_UNDER_TEST="$lib"
  mkdir -p "$SB/psbin"; printf '#!/bin/sh\nexit 1\n' > "$SB/psbin/ps"; chmod +x "$SB/psbin/ps"
  h=$(mk_harness "$n" "$lib" "$fork" 'gate_pm_step "deploy"; i=0; while [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done' 'sleep 0.2')
  /bin/bash "$h" >/dev/null 2>&1 &
  wait_until "$TW" test -s "$PMDIR/pending/$run.pid" || return 1
  SWEEP_PATH="$SB/psbin:$PATH" run_sweep "$n" "GATE_PM_PROC_PATTERN=not-the-dispatcher"
  [ "$(ev_count postmerge_lost "$run")" = "0" ] || return 2                                      # ps said nothing: not reported
  [ -e "$PMDIR/pending/$run.job" ] || return 3
  run_sweep "$n" "GATE_PM_PROC_PATTERN=not-the-dispatcher"                                       # ps works, the command line is not ours: reused pid
  [ "$(ev_count postmerge_lost "$run")" = "1" ] || return 4
  pkill -f "$SB/$n" 2>/dev/null || true
  return 0
}

# a job file whose registered_at is damaged is aged by the file's own mtime, not by "now"
sc_corrupt_registered_at() {
  local lib="$1" fork="$2" n="$3" run="ga-run-$3"
  LIB_UNDER_TEST="$lib"
  ( export GC_CITY QG_LOG; . "$lib"; log(){ :; }; warn(){ :; }
    gate_pm_begin "$run" "ga-mk-$n" "ga-bead-$n" "$CITY" rig1 fix/x deadbeef ) >/dev/null 2>&1 || return 1
  sed -i '' 's/^registered_at=.*/registered_at=garbage/' "$PMDIR/pending/$run.job" || return 2
  run_sweep "$n" "GATE_PM_PROC_PATTERN=zzz"                                                      # fresh mtime, inside the start grace: quiet
  [ "$(ev_count postmerge_lost "$run")" = "0" ] || return 3
  touch -t 200001010000 "$PMDIR/pending/$run.job"
  run_sweep "$n" "GATE_PM_PROC_PATTERN=zzz"                                                      # ancient mtime: it never started, long ago
  [ "$(ev_count postmerge_lost "$run")" = "1" ] || return 4
  return 0
}

sc_survives_sweep_group_kill() {
  local lib="$1" fork="$2" n="$3" h run="ga-run-$3" spid
  h=$(mk_harness "$n" "$lib" "$fork" \
'gate_pm_step "deploy"; sleep 2; echo ran >> "'"$SB/$n"'.tail.runs"' \
'echo forked > "'"$SB/$n"'.fork.ret"; sleep 30')
  set -m
  /bin/bash "$h" >/dev/null 2>&1 &
  spid=$!
  set +m                                                                                          # the sweep leads its own group, as under launchd
  wait_until "$TW" test -e "$SB/$n.fork.ret" || return 1
  kill -TERM -- "-$spid" 2>/dev/null || return 2                                                  # what launchd does when the job's main process exits
  wait_until "$TW" test -e "$SB/$n.tail.runs" || return 3                                             # the tail still ran to its end
  wait_until "$TW" test ! -e "$PMDIR/pending/$run.job" || return 4
  [ "$(ev_count postmerge_done "$run")" = "1" ] || return 5
  return 0
}

echo "── 1. async detach: real fork block, fake tail ──"
if sc_async_detach "$LIB" "$FORK_REAL" s1; then ok "returns without waiting, own process group (leader), exactly one run, one postmerge_deferred + one postmerge_done(handoff), nothing left in pending/"
else bad "async detach scenario failed (rc=$?)"; fi
if sc_survives_sweep_group_kill "$LIB" "$FORK_REAL" s1b; then ok "the tail finishes (and records postmerge_done) after the sweep's whole process group is TERMed — the launchd case"
else bad "tail did not survive the sweep's process group being killed (rc=$?)"; fi

echo "── 2. failure and loss are never silent ──"
if sc_failure_errexit "$LIB" "$FORK_REAL" s2; then ok "errexit mid-tail: postmerge_failed(step=deploy, rc=1), stopped at the failing command, failed/ job, bead label+comment, Mayor nudge, no postmerge_done"
else bad "errexit failure scenario failed (rc=$?)"; fi
if sc_failure_term "$LIB" "$FORK_REAL" s2b; then ok "TERM: postmerge_failed(rc=143, step=notify) — the exit handler runs"
else bad "TERM failure scenario failed (rc=$?)"; fi
if sc_lost_sigkill "$LIB" "$FORK_REAL" s2c; then ok "SIGKILL: a live tail is left alone; the dead one is reported ONCE (event, lost/ job with last step, label, comment, nudge) and never re-run"
else bad "lost-tail scenario failed (rc=$?)"; fi

# a job with no pid yet is inside its start grace; past it, it is a tail that never started
LIB_UNDER_TEST="$LIB"
( export GC_CITY QG_LOG; . "$LIB"; log(){ :; }; warn(){ :; }
  gate_pm_begin ga-run-grace ga-mk-grace ga-bead-grace "$CITY" rig1 fix/x deadbeef ) >/dev/null 2>&1 || true
run_sweep s2d "GATE_PM_PROC_PATTERN=zzz"
if [ "$(ev_count postmerge_lost ga-run-grace)" = "0" ] && [ -e "$PMDIR/pending/ga-run-grace.job" ]; then ok "a job without a pid yet is not reported inside GATE_PM_START_GRACE_S"; else bad "grace window not honoured"; fi
run_sweep s2d "GATE_PM_PROC_PATTERN=zzz" "GATE_PM_START_GRACE_S=0"
if [ "$(ev_count postmerge_lost ga-run-grace)" = "1" ] && [ "$(ev_field postmerge_lost ga-run-grace step)" = "none" ]; then ok "past the grace it is reported lost (step none = it never started)"; else bad "never-started tail not reported"; fi

if sc_ps_unreadable "$LIB" "$FORK_REAL" s2e; then ok "ps unreadable for a live pid: not reported lost; a readable command line that is not the dispatcher (reused pid): reported"
else bad "ps-unreadable scenario failed (rc=$?)"; fi
if sc_corrupt_registered_at "$LIB" "$FORK_REAL" s2f; then ok "damaged registered_at: aged by the job file's mtime (quiet inside the grace, reported once it is old)"
else bad "corrupt registered_at scenario failed (rc=$?)"; fi

echo "── 3. inline paths: same shell, no job, no event ──"
inline_case() { # <name> <lib|NONE> [env...]
  local n="$1" lib="$2" h; shift 2
  h=$(mk_harness "$n" "$lib" "$FORK_REAL" 'INLINE_SET=yes; echo ran >> "'"$SB/$n"'.tail.runs"' 'echo "INLINE_SET=${INLINE_SET:-unset}" > "'"$SB/$n"'.after"')
  ( env "$@" /bin/bash "$h" ) >/dev/null 2>&1 || return 1
  [ "$(cat "$SB/$n.after")" = "INLINE_SET=yes" ] || return 2
  [ "$(wc -l < "$SB/$n.tail.runs" | tr -d ' ')" = "1" ] || return 3
  [ ! -e "$PMDIR/pending/ga-run-$n.job" ] || return 4
  [ "$(ev_count postmerge_deferred "ga-run-$n")" = "0" ] || return 5
  return 0
}
if inline_case i1 "$LIB" GATE_POSTMERGE_ASYNC=0; then ok "GATE_POSTMERGE_ASYNC=0: inline, in the sweep's own shell"; else bad "env kill-switch (rc=$?)"; fi
touch "$CITY/.gc/gate-postmerge.off"
if inline_case i2 "$LIB"; then ok "\$GC_CITY/.gc/gate-postmerge.off: inline (no redeploy needed)"; else bad "file kill-switch (rc=$?)"; fi
rm -f "$CITY/.gc/gate-postmerge.off"
if inline_case i3 "$LIB" PM_DRY=1; then ok "DRY_RUN=1: inline"; else bad "dry-run (rc=$?)"; fi
if inline_case i4 NONE; then ok "lib not loaded: inline"; else bad "no-lib (rc=$?)"; fi
if inline_case i5 "$LIB" GATE_PM_DIR=/dev/null/not-a-dir; then ok "job directory not writable: inline (no registration = no async)"; else bad "unwritable dir (rc=$?)"; fi
if grep -q "post-merge tail of ga-run-i5 runs INLINE (async not possible" "$SB/i5.log" 2>/dev/null; then ok "…and the fall-back to inline is said out loud, not silent"; else bad "async->inline degradation was silent"; fi
if [ ! -s "$SB/i1.log" ] || ! grep -q "runs INLINE" "$SB/i1.log" 2>/dev/null; then ok "…while a deliberate switch-off stays quiet"; else bad "kill-switch should not warn"; fi
if inline_case i6 "$LIB" GATE_POSTMERGE_ASYNC=banana; then bad "a garbage switch value must not mean OFF"; else ok "a garbage switch value is not OFF (only a literal 0 is): it went async, not inline"; fi

echo "── 4. deploy lock ──"
(
  . "$LIB"
  log(){ echo "LOG $*" >> "$SB/lock.log"; }; warn(){ echo "WARN $*" >> "$SB/lock.log"; }
  export GATE_PM_DEPLOY_LOCK_POLL_S=0.2 GATE_PM_DIR="$SB/lockdir"
  RT=/some/rig/runtime
  h=$(printf '%s' "$RT" | cksum | cut -d' ' -f1); LK="$SB/lockdir/deploy-lock/$h.d"
  res=""
  # L1 basic + live holder → 75 + release
  gate_pm_deploy_lock_acquire "$RT"; [ -d "$LK" ] && res="$res L1a"
  owner=$(head -n1 "$LK/owner"); case "$owner" in "$$":*) res="$res L1b" ;; esac
  rc=0; ( export GATE_PM_DEPLOY_LOCK_WAIT_S=1 GATE_PM_CHILD_PID=999990; gate_pm_deploy_lock_acquire "$RT" ) || rc=$?; [ "$rc" = "75" ] && res="$res L1c"
  gate_pm_deploy_lock_release; [ ! -d "$LK" ] && res="$res L1d"
  # L2 dead owner
  mkdir -p "$LK"; printf '999999:%s:x\n' "$(date +%s)" > "$LK/owner"
  rc=0; gate_pm_deploy_lock_acquire "$RT" || rc=$?; [ "$rc" = "0" ] && grep -q "dead or over-age" "$SB/lock.log" && res="$res L2"
  gate_pm_deploy_lock_release
  # L3 over-age owner with a LIVE pid
  mkdir -p "$LK"; printf '%s:%s:x\n' "$$" "$(( $(date +%s) - 5000 ))" > "$LK/owner"
  rc=0; GATE_PM_DEPLOY_LOCK_MAX_AGE_S=1800 gate_pm_deploy_lock_acquire "$RT" || rc=$?; [ "$rc" = "0" ] && res="$res L3"
  gate_pm_deploy_lock_release
  # L4 ownerless dir: fresh → waits (75); old → taken over
  mkdir -p "$LK"; rc=0; GATE_PM_DEPLOY_LOCK_WAIT_S=1 gate_pm_deploy_lock_acquire "$RT" || rc=$?; [ "$rc" = "75" ] && res="$res L4a"
  touch -t 200001010000 "$LK"; rc=0; gate_pm_deploy_lock_acquire "$RT" || rc=$?; [ "$rc" = "0" ] && res="$res L4b"
  gate_pm_deploy_lock_release
  # L5 release only removes its own lock
  mkdir -p "$LK"; printf '4242:%s:other\n' "$(date +%s)" > "$LK/owner"; GATE_PM_LOCK_DIR="$LK"; gate_pm_deploy_lock_release; [ -d "$LK" ] && res="$res L5"
  rm -f "$LK/owner"; rmdir "$LK"
  # L6 unwritable lock directory → rc 2 (the caller carries on, as before the lock existed)
  rc=0; ( GATE_PM_DIR=/dev/null/x; gate_pm_deploy_lock_acquire "$RT" ) || rc=$?; [ "$rc" = "2" ] && res="$res L6"
  # L7 two tails, one lock: no interleaving
  : > "$SB/order.txt"
  for who in A B; do
    ( export GATE_PM_CHILD_PID; GATE_PM_CHILD_PID=$(exec sh -c 'echo $PPID'); export GATE_PM_DEPLOY_LOCK_WAIT_S=30
      gate_pm_deploy_lock_acquire "$RT"; echo "$who-start" >> "$SB/order.txt"; sleep 1; echo "$who-end" >> "$SB/order.txt"; gate_pm_deploy_lock_release ) &
  done
  wait
  [ "$(awk '{s=s substr($0,3)" "} END{print s}' "$SB/order.txt")" = "start end start end " ] && res="$res L7"
  echo "$res" > "$SB/lock.res"
) >/dev/null 2>&1 || true
LR=" $(cat "$SB/lock.res" 2>/dev/null)"
chk() { case "$LR" in *" $1"*) ok "$2" ;; *) bad "$2 (missing $1; got:$LR)" ;; esac; }
chk L1a "acquire creates the lock dir with an owner file"
chk L1b "owner file is <pid>:<epoch>:<key>"
chk L1c "a LIVE holder: the waiter gives up with rc 75 after GATE_PM_DEPLOY_LOCK_WAIT_S"
chk L1d "release removes the lock"
chk L2  "dead owner pid: taken over (and said so)"
chk L3  "over-age owner (live pid, older than GATE_PM_DEPLOY_LOCK_MAX_AGE_S): taken over"
chk L4a "ownerless dir younger than a minute: not called dead (rc 75)"
chk L4b "ownerless dir older than a minute: taken over"
chk L5  "release leaves a lock owned by someone else"
chk L6  "unwritable lock directory: rc 2 (carry on as before)"
chk L7  "two tails, one lock: A-start A-end B-start B-end — never interleaved"

echo "── 5. event shapes ──"
if jq -e -s 'map(select(.event=="postmerge_done")) | .[0] | has("ts") and has("gate_run") and has("marker") and has("bead") and has("rig") and has("branch") and has("merge_sha") and (.rc|type=="number") and (.elapsed_s|type=="number") and (.lock_wait_s|type=="number") and (.outcome|type=="string")' "$QG_LOG" >/dev/null 2>&1; then
  ok "postmerge_done: identity fields + numeric rc / elapsed_s / lock_wait_s + outcome string"
else bad "postmerge_done event shape"; fi
if jq -e -s 'map(select(.event=="postmerge_lost")) | .[0] | (.age_s|type=="number") and (.step|type=="string")' "$QG_LOG" >/dev/null 2>&1; then ok "postmerge_lost: numeric age_s + step"; else bad "postmerge_lost event shape"; fi
OUTC=$( (. "$LIB"; BEAD_ID=b DRY_RUN=0 IS_STORY=0 IS_DAEMON_HOLD=1 DAEMON_HOLD_VERDICT=VERIFY_FAILED gate_pm_outcome; echo; BEAD_ID=b DRY_RUN=0 gate_pm_outcome; echo; BEAD_ID=b DRY_RUN=0 RESPAWN_HITS=" pilot:open-bug" gate_pm_outcome; echo; BEAD_ID= gate_pm_outcome; echo; BEAD_ID=b DRY_RUN=0 GATE_PM_CLOSE_FAILED=1 gate_pm_outcome; echo ) 2>/dev/null | tr '\n' ' ')
if [ "$OUTC" = "held:daemon:VERIFY_FAILED closed unresolved:respawn-vector skipped unresolved:close-failed " ]; then ok "outcome: held:daemon:<VERDICT> | closed | unresolved:respawn-vector | skipped | unresolved:close-failed (a failed close is never called closed)"; else bad "outcome strings: '$OUTC'"; fi
if grep -q 'GATE_PM_CLOSE_FAILED=1' "$DISPATCHER" && [ "$(grep -c 'GATE_PM_CLOSE_FAILED=1' "$DISPATCHER")" = "1" ]; then ok "the dispatcher raises GATE_PM_CLOSE_FAILED exactly where gate_close_source_terminal fails"; else bad "GATE_PM_CLOSE_FAILED not wired once"; fi

echo "── 6. static wiring on the live dispatcher ──"
lno() { grep -n -- "$1" "$DISPATCHER" | head -n1 | cut -d: -f1; }
L_INTEG=$(lno 'Post-merge diff-integrity check (Bug 1b belt-and-suspenders)')
L_MARK=$(lno 'set_gate_status "\$MARKER_ID" "passed"')
L_RUNCL=$(lno 'gate-run terminal: PASSED (branch \$BRANCH sha=\$MERGE_SHA)')
L_TAIL=$(lno '^    _gate_pm_tail() {')
L_ESBG=$(lno 'ga-esbg: DRIVE THE SOURCE BEAD TO ITS TERMINAL')
L_DEPLOY=$(lno 'SELFTEST-EXTRACT deploy-retry-loop: BEGIN')
L_HOLD=$(lno 'SELFTEST-EXTRACT daemon-hold-block: BEGIN')
L_CLOSE=$(lno 'SELFTEST-EXTRACT pass-close-decision: BEGIN')
L_VERIFY=$(lno 'POST-MERGE VERIFICATION (ga-esbg)')
L_REAP=$(lno 'ga-dcclose: REAP THE ORIGINATING')
L_PASSLOG=$(lno 'log "Gate PASSED: branch=\$BRANCH tier=\$TIER merge_sha')
L_FORKB=$(lno 'SELFTEST-EXTRACT postmerge-fork: BEGIN')
L_FORKE=$(lno 'SELFTEST-EXTRACT postmerge-fork: END')
L_SUPER=$(lno '^    supersede_sibling_runs "\$MARKER_ID" "\$BRANCH" "\$BEAD_ID" "\$RIG"')
L_FAIL=$(lno 'FAIL path ──')
L_SWEEPSTART=$(lno 'Dispatcher sweep start (DRY_RUN')
L_PMSWEEP=$(lno 'gate_pm_sweep || true')
L_PHASEC=$(lno 'Phase C (ga-eqjo): finalize any in-flight')
seq_ok() { local prev=0 v; for v in "$@"; do [ -n "$v" ] && [ "$v" -gt "$prev" ] || return 1; prev="$v"; done; return 0; }
if seq_ok "$L_INTEG" "$L_MARK" "$L_RUNCL" "$L_TAIL" "$L_ESBG" "$L_DEPLOY" "$L_HOLD" "$L_CLOSE" "$L_VERIFY" "$L_REAP" "$L_PASSLOG" "$L_FORKB" "$L_FORKE" "$L_SUPER" "$L_FAIL"; then
  ok "order: integrity check < marker passed < gate-run closed < [ _gate_pm_tail { source-bead < deploy < hold < close < verify < reap < Gate PASSED } ] < fork block < supersede < FAIL path"
else bad "order of sync part / tail / fork block / supersede is wrong ($L_INTEG $L_MARK $L_RUNCL $L_TAIL $L_ESBG $L_DEPLOY $L_HOLD $L_CLOSE $L_VERIFY $L_REAP $L_PASSLOG $L_FORKB $L_FORKE $L_SUPER $L_FAIL)"; fi
if [ "$(grep -c '^    _gate_pm_tail() {' "$DISPATCHER")" = "1" ] && [ "$(grep -c 'set_gate_status "\$MARKER_ID" "passed"' "$DISPATCHER")" = "1" ]; then ok "one tail function, one terminal marker transition"; else bad "tail function / marker transition count"; fi
if seq_ok "$L_SWEEPSTART" "$L_PMSWEEP" "$L_PHASEC"; then ok "gate_pm_sweep runs right after 'sweep start', before Phase C"; else bad "gate_pm_sweep not between sweep start and Phase C"; fi
# what must NOT be in the tail: anything another component needs the moment the merge is confirmed
TAILF="$SB/tail.txt"; sed -n "${L_TAIL},$((L_FORKB-1))p" "$DISPATCHER" > "$TAILF"
leak=""
for pat in 'set_gate_status "\$MARKER_ID"' 'set_gate_status "\$GATE_RUN_ID"' 'close_open_run_verdicts' 'merge-survival-ledger' 'git_rig push' 'supersede_sibling_runs "' 'Post-merge diff-integrity'; do
  if grep -q -- "$pat" "$TAILF"; then leak="$leak [$pat]"; fi
done
if [ -z "$leak" ]; then ok "nothing synchronous leaked into the tail (marker/run terminal, verdict beads, ledger, push, supersede, integrity check)"; else bad "in the tail but must be synchronous:$leak"; fi
need=""
for pat in 'gate_close_source_terminal' 'daemon-refresh.sh' 'ga-dcclose' 'gate_sibling_hold_check' 'NOTIFY_FORCE_DIGEST=1 notify -k gate-pass' 'DEPLOY_LOCK_TIMEOUT' 'gate_pm_deploy_lock_release'; do
  grep -q -- "$pat" "$TAILF" || need="$need [$pat]"
done
if [ -z "$need" ]; then ok "the deploy, daemon-refresh, holds, close, reap, notify and the lock release are all inside the tail"; else bad "missing from the tail:$need"; fi
if /bin/bash -n "$DISPATCHER" && /bin/bash -n "$LIB"; then ok "dispatcher and lib pass bash -n on the production bash ($(/bin/bash --version | head -n1 | sed 's/.*version //; s/(.*//'))"; else bad "bash -n"; fi

echo "── 7. mutations: each must turn its property red ──"
TW=8
# mutation <label> <lib|fork> <name> <old-text> <new-text> <scenario-fn>: copy the file, replace <old> by <new> once, and require the scenario to FAIL on
# the copy. A target that is not found is a FAIL of this selftest (a stale mutation proves nothing, and must not count as "caught").
mutation() {
  local label="$1" kind="$2" n="$3" old="$4" new="$5" fn="$6" src dst libp forkp
  if [ "$kind" = lib ]; then src="$LIB"; dst="$SB/mut/$n.lib.sh"; else src="$FORK_REAL"; dst="$SB/mut/$n.fork.txt"; fi
  if ! python3 -I - "$src" "$dst" "$old" "$new" <<'PYEOF'
import sys
src,dst,old,new=sys.argv[1:5]
s=open(src).read()
if s.count(old)<1:
    sys.exit(3)
open(dst,'w').write(s.replace(old,new,1))
PYEOF
  then bad "STALE MUTATION '$label': target text not found in $kind (update the selftest)"; return 0; fi
  libp="$LIB"; forkp="$FORK_REAL"
  if [ "$kind" = lib ]; then libp="$dst"; else forkp="$dst"; fi
  if "$fn" "$libp" "$forkp" "$n" >/dev/null 2>&1; then bad "MUTATION SURVIVED: $label (the test cannot tell)"; else ok "mutation caught: $label"; fi
}
mutation "no 'set -m' (same process group as the sweep)" fork m1 'set -m' ':' sc_async_detach
mutation "tail forked in the foreground (the sweep waits)" fork m2 ') </dev/null &' ') </dev/null; true &' sc_async_detach
mutation "a failed tail leaves its job in pending/ instead of failed/" lib m3 'mv -f "$d/pending/$key.job" "$d/failed/$key.job"' ':' sc_failure_errexit
mutation "no exit handler (a failed tail leaves nothing)" lib m4 "trap 'gate_pm_child_exit \$?' EXIT" ':' sc_failure_errexit
mutation "the sweep never reports a lost tail" lib m5 'if ! mv "$f" "$d/lost/$key.job" 2>/dev/null; then continue; fi' ':' sc_lost_sigkill
mutation "the sweep calls a live tail lost" lib m6 '*"${GATE_PM_PROC_PATTERN:-quality-gate-dispatcher}"*) alive=1 ;;' '*"${GATE_PM_PROC_PATTERN:-quality-gate-dispatcher}"*) : ;;' sc_lost_sigkill
mutation "the tail keeps refreshing the DISPATCHER's liveness file (it would vouch for a wedged sweep)" lib m7 '_GATE_HB_FILE="${LOG_DIR:-${GC_CITY:-/tmp}/.gc/logs}/quality-gate-postmerge.heartbeat"' ':' sc_async_detach
mutation "a pid ps cannot describe is called lost" lib m8 "'') alive=1 ;;      # the process exists but ps would not say" "'') : ;;      # the process exists but ps would not say" sc_ps_unreadable
mutation "a damaged registered_at is aged as 'just now' (never reported)" lib m9 'reg=$(stat -f %m "$f" 2>/dev/null || echo "$now")' 'reg="$now"' sc_corrupt_registered_at
mutation "the tail's pid is taken without exec (a transient fork, off by one from \$!)" lib m10 "GATE_PM_CHILD_PID=\$(exec sh -c 'echo \$PPID'" "GATE_PM_CHILD_PID=\$(sh -c 'echo \$PPID'" sc_lost_sigkill

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

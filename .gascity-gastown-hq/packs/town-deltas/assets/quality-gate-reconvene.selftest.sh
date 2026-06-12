#!/usr/bin/env bash
# quality-gate-reconvene.selftest.sh — Prove the ga-4u16h "re-convene a DEAD
# reviewer slot mid-collection" logic in isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-4u16h: when the Dolt :52756 server resets a connection and kills a
# gate-reviewer SESSION mid-review, the reviewer's verdict bead stays
# verdict:pending. Pre-fix, quality-gate-dispatcher.sh waited the FULL outer
# timeout (45m) and then counted the missing verdict as a FAIL — bouncing a GOOD
# fix on INFRA, not code (proven live on fix/ga-jhyu: 1/3 with 2 reviewers dead).
#
# The fix re-spawns THAT reviewer slot (bounded by MAX_RESPAWNS_PER_SLOT),
# reusing the still-pending verdict bead and re-delivering the same review task,
# while keeping the verdicts already collected. Real verdict:FAIL still fails
# immediately; a live-but-slow reviewer is never re-convened; healthy runs are
# unaffected; a permanently-broken Dolt converges to FAIL within
# (1 + MAX_RESPAWNS_PER_SLOT) cohorts via the unchanged outer timeout.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test its REAL pure decision functions (classify_slot_action,
# session_is_dead) and its REAL respawn helper (respawn_reviewer_slot, driven by
# in-shell gc/bd mocks), then composes them in a bounded loop simulation to prove
# the five adversary-mandated scenarios (a–e), and finally DRIFT-GUARDS the live
# script so a future refactor that drops the wiring fails loudly.
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type classify_slot_action  >/dev/null 2>&1 || { echo "FATAL: classify_slot_action not defined by dispatcher"; exit 1; }
type session_is_dead       >/dev/null 2>&1 || { echo "FATAL: session_is_dead not defined by dispatcher"; exit 1; }
type respawn_reviewer_slot >/dev/null 2>&1 || { echo "FATAL: respawn_reviewer_slot not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. session_is_dead — terminal-state classification ───────────────────────
# A reviewer session is DEAD iff absent from the list OR explicitly closed.
# `asleep`/`active` (present, not closed) = ALIVE: a finished or between-turns
# reviewer is asleep, so asleep must NEVER read as dead.
echo "── 1. session_is_dead (absent OR closed = dead; present+not-closed = alive) ──"
eq "absent from list → dead"              "$(session_is_dead 0 false)" "1"
eq "absent (closed irrelevant) → dead"    "$(session_is_dead 0 true)"  "1"
eq "present + closed=true → dead"         "$(session_is_dead 1 true)"  "1"
eq "present + closed=1 → dead"            "$(session_is_dead 1 1)"     "1"
eq "present + closed=false → alive"       "$(session_is_dead 1 false)" "0"
eq "present + closed=0 → alive (asleep)"  "$(session_is_dead 1 0)"     "0"

# ── 2. classify_slot_action — the single per-slot decision ───────────────────
# Encodes adversary scenarios a–e at the decision level.
# Signature: classify_slot_action <bead_closed 0|1> <session_dead 0|1> <budget>
echo "── 2. classify_slot_action (received | respawn | wait) ──"
eq "(e) bead closed (PASS/FAIL) → received, never respawn"   "$(classify_slot_action 1 0 2)" "received"
eq "(c) bead closed even if session also dead → received"    "$(classify_slot_action 1 1 2)" "received"
eq "(a) pending + dead + budget>0 → respawn"                 "$(classify_slot_action 0 1 2)" "respawn"
eq "(b) pending + dead + budget==0 → wait (outer timeout)"   "$(classify_slot_action 0 1 0)" "wait"
eq "(d) pending + alive → wait (slow reviewer, no respawn)"  "$(classify_slot_action 0 0 2)" "wait"
eq "pending + dead + budget negative (sanitized) → wait"     "$(classify_slot_action 0 1 -3)" "wait"
eq "pending + dead + budget garbage → wait"                  "$(classify_slot_action 0 1 xx)" "wait"

# ── 2b. slot_effectively_dead — ga-mepb0 boot-wedge deadness fold-in ──────────
# session_is_dead only sees absent/closed sessions. A reviewer wedged at boot
# (gc prime hung on the Dolt circuit-breaker) is present + asleep
# (session_dead=0) yet never ACKs — pre-fix it survived to the 45m timeout and
# FALSE-FAILed a good branch. slot_effectively_dead folds the ACK signal in:
# effectively-dead iff session is dead OR the slot never showed a sign of life.
# Signature: slot_effectively_dead <session_dead 0|1> <acked 0|1> → 1|0
type slot_effectively_dead >/dev/null 2>&1 || { echo "FATAL: slot_effectively_dead not defined by dispatcher (ga-mepb0)"; exit 1; }
echo "── 2b. slot_effectively_dead (boot-wedge: present-but-never-acked = dead) ──"
eq "session dead + acked → dead (session wins)"              "$(slot_effectively_dead 1 1)" "1"
eq "session dead + never-acked → dead"                       "$(slot_effectively_dead 1 0)" "1"
eq "(ga-mepb0) present + never-acked → effectively DEAD"     "$(slot_effectively_dead 0 0)" "1"
eq "(safety) present + ACKed → alive (slow reviewer spared)" "$(slot_effectively_dead 0 1)" "0"

# ── 2c. session_peek_reports_dead — ga-h9o17 drained-but-listed discriminator ──
# A reviewer that DRAINS stays in `gc session list` (present + not-closed → both
# session_is_dead and slot_effectively_dead read it ALIVE, since it ACKed before
# draining) yet is functionally gone — its pending verdict would wait the full
# outer timeout → false-FAIL of a good branch. `gc session peek` is the signal
# the list lacks: a drained session exits non-zero with
# "gc session peek: session not found" on STDERR; a live asleep reviewer's peek
# succeeds with STDOUT scrollback. The helper matches ONLY the gc-emitted
# not-found stderr string, so a live reviewer's scrollback (which the caller
# routes to /dev/null) and a bare transient error can NEVER reap a live reviewer.
# Signature: session_peek_reports_dead <peek_stderr_text> → 1|0
type session_peek_reports_dead >/dev/null 2>&1 || { echo "FATAL: session_peek_reports_dead not defined by dispatcher (ga-h9o17)"; exit 1; }
echo "── 2c. session_peek_reports_dead (peek 'session not found' = drained/dead) ──"
eq "peek 'session not found' → DEAD"                          "$(session_peek_reports_dead 'gc session peek: session not found: "ga-wisp-x"')" "1"
eq "peek not-found amid a WARN line → DEAD (substring match)" "$(session_peek_reports_dead "$(printf '%s\n%s' 'WARN native_store_unavailable' 'gc session peek: session not found: "ga-wisp-x"')")" "1"
eq "live reviewer stdout scrollback (empty stderr) → ALIVE"   "$(session_peek_reports_dead '')" "0"
eq "transient connection error (NOT not-found) → ALIVE"       "$(session_peek_reports_dead 'connection refused')" "0"
eq "scrollback words 'not found' w/o 'session' → ALIVE"       "$(session_peek_reports_dead 'build error: file not found')" "0"

# ── 3. respawn_reviewer_slot — real spawn/nudge wiring (mock gc) ──────────────
# Proves the helper spawns a FRESH session, swaps SESSION_IDS[idx] in place,
# re-delivers the SAME stored task, and REUSES the still-pending verdict bead
# (it must NOT create a new verdict bead).
echo "── 3. respawn_reviewer_slot (array swap + bead reuse + spawn-fail safety) ──"

# In-shell mocks (everything runs in one sourced shell, so functions win).
MOCK_NEW_SID="ga-resp-NEW"
MOCK_SPAWN_OK=1
# respawn_reviewer_slot calls `gc` inside $(...) (a subshell), so a shell-var
# counter would be lost. Count spawns via a temp file that survives subshells.
GC_NEW_CALL_FILE="$(mktemp)"
gc_new_calls() { wc -l < "$GC_NEW_CALL_FILE" | tr -d ' '; }
gc() {
  case " $* " in
    *" session new "*)
      echo x >> "$GC_NEW_CALL_FILE"
      if [ "$MOCK_SPAWN_OK" = "1" ]; then echo "{\"session_id\":\"$MOCK_NEW_SID\"}"; else echo "{}"; fi
      ;;
    *" session list "*) echo "$MOCK_SESS_JSON" ;;
    *) : ;;  # wake / nudge / submit → no-op success
  esac
  return 0
}
bd() { return 0; }

GC_CITY="/tmp/reconvene-test-city"
BRANCH="fix/ga-test"
VERDICT_BEAD_IDS=( "vb0" "vb1" "vb2" )
SESSION_IDS=( "ga-old0" "ga-old1" "ga-old2" )
REVIEW_TASKS=( "task-0" "task-1" "task-2" )

# Success path: slot 2 re-convened.
MOCK_SPAWN_OK=1; : > "$GC_NEW_CALL_FILE"
respawn_reviewer_slot 2
eq "respawn swaps SESSION_IDS[2] to the fresh session id" "${SESSION_IDS[2]}" "$MOCK_NEW_SID"
eq "respawn did NOT touch SESSION_IDS[0]"                  "${SESSION_IDS[0]}" "ga-old0"
eq "respawn spawned exactly one new session"              "$(gc_new_calls)" "1"

# Failure path: spawn returns {} → SESSION_IDS unchanged, returns non-zero.
SESSION_IDS=( "ga-old0" "ga-old1" "ga-keep2" )
MOCK_SPAWN_OK=0
_rc=0; respawn_reviewer_slot 2 || _rc=$?
eq "spawn failure → returns non-zero"            "$_rc" "1"
eq "spawn failure → SESSION_IDS[2] unchanged"    "${SESSION_IDS[2]}" "ga-keep2"

# ── 4. Bounded loop simulation — composes the REAL helpers (a,b,c,d,e) ────────
# A faithful re-creation of the dispatcher's poll-loop decision flow (grace +
# dead-streak gating → classify_slot_action → respawn_reviewer_slot), driven by
# scripted per-slot bead+session timelines via the gc/bd mocks. Proves end-state
# OVERALL, that re-spawns are bounded, and that the loop ALWAYS terminates within
# an iteration cap (no infinite spin).
echo "── 4. bounded poll-loop simulation (scenarios a–e) ──"

# Build the gc session-list JSON from the per-slot liveness model.
# SLOT_LIVE[j]: "alive" (present,not-closed) | "absent" | "closed".
build_sess_json() {
  local out="[" first=1 j sid
  for j in "${!SESSION_IDS[@]}"; do
    case "${SLOT_LIVE[$j]}" in
      alive)  sid="${SESSION_IDS[$j]}"; cl="false" ;;
      closed) sid="${SESSION_IDS[$j]}"; cl="true"  ;;
      absent) continue ;;  # not in the list at all
      *)      sid="${SESSION_IDS[$j]}"; cl="false" ;;
    esac
    [ "$first" = "1" ] || out="$out,"
    out="$out{\"id\":\"$sid\",\"state\":\"active\",\"closed\":$cl}"
    first=0
  done
  echo "$out]"
}

# One poll iteration. Returns via globals: SIM_RECEIVED, SIM_ANYFAIL.
# Re-implements the dispatcher's per-slot flow using the REAL helpers.
sim_poll() {
  local now="$1" j
  SIM_RECEIVED=0; SIM_ANYFAIL=0
  MOCK_SESS_JSON="$(build_sess_json)"
  for j in "${!VERDICT_BEAD_IDS[@]}"; do
    case "${SLOT_BEAD[$j]}" in
      PASS) SIM_RECEIVED=$((SIM_RECEIVED+1)) ;;
      FAIL) SIM_RECEIVED=$((SIM_RECEIVED+1)); SIM_ANYFAIL=1 ;;
      pending)
        # mirror the else-branch gating in the dispatcher
        local sid present_n present_flag closed_flag dead spawn_age action k
        sid="${SESSION_IDS[$j]}"
        spawn_age=$(( now - ${SLOT_SPAWN_EPOCH[$j]:-$now} ))
        present_n=$(echo "$MOCK_SESS_JSON" | jq -r --arg s "$sid" 'map(select(.id==$s)) | length')
        if [ "$present_n" -ge 1 ]; then
          present_flag=1
          closed_flag=$(echo "$MOCK_SESS_JSON" | jq -r --arg s "$sid" 'map(select(.id==$s)) | .[0].closed // false')
        else
          present_flag=0; closed_flag=false
        fi
        dead=$(session_is_dead "$present_flag" "$closed_flag")
        # ga-h9o17: model the drained-but-listed peek probe through the REAL
        # helper. SLOT_PEEK[j]="gone" makes `gc session peek` report
        # session-not-found even though the list still shows the session present
        # + not-closed (dead=0); default "found" = a live asleep reviewer whose
        # peek succeeds. Probe only when the list says alive and past grace —
        # exactly the dispatcher's bounding.
        local peek_dead=0
        if [ "$dead" = "0" ] && [ "$spawn_age" -ge "$RECONVENE_GRACE_SECS" ]; then
          case "${SLOT_PEEK[$j]:-found}" in
            gone) peek_dead=$(session_peek_reports_dead "gc session peek: session not found: \"$sid\"") ;;
            *)    peek_dead=$(session_peek_reports_dead "live terminal scrollback for $sid") ;;
          esac
        fi
        local eff_dead="$dead"
        [ "$peek_dead" = "1" ] && eff_dead=1
        if [ "$eff_dead" = "1" ] && [ "$spawn_age" -ge "$RECONVENE_GRACE_SECS" ]; then
          SLOT_DEAD_STREAK[$j]=$(( ${SLOT_DEAD_STREAK[$j]:-0} + 1 ))
        else
          SLOT_DEAD_STREAK[$j]=0
        fi
        local confirmed=0
        if [ "$eff_dead" = "1" ] && [ "${SLOT_DEAD_STREAK[$j]:-0}" -ge "$RECONVENE_DEAD_STREAK_MIN" ]; then confirmed=1; fi
        action=$(classify_slot_action 0 "$confirmed" "${RESPAWN_BUDGET[$j]:-0}")
        if [ "$action" = "respawn" ]; then
          RESPAWN_BUDGET[$j]=$(( ${RESPAWN_BUDGET[$j]:-0} - 1 ))
          SLOT_SPAWN_EPOCH[$j]="$now"
          SLOT_DEAD_STREAK[$j]=0
          SIM_RESPAWNS=$((SIM_RESPAWNS+1))
          respawn_reviewer_slot "$j" || true
          # scenario driver may revive the slot after respawn (see hooks below).
          # ga-h9o17: a re-convened slot also gets a LIVE peek (fresh session) so
          # the drained-peek scenario converges instead of re-firing forever.
          if [ -n "${REVIVE_ON_RESPAWN:-}" ]; then SLOT_LIVE[$j]="alive"; SLOT_PEEK[$j]="found"; SLOT_BEAD[$j]="$REVIVE_VERDICT"; fi
        fi
        ;;
    esac
  done
}

# Generic bounded runner. Globals SLOT_BEAD/SLOT_LIVE describe the timeline;
# the scenario pre-seeds them and may mutate via REVIVE_ON_RESPAWN. Stops when
# all verdicts are in OR an injected timeout fires; FAILS if the cap is exceeded.
ITER_CAP=20
run_sim() {
  local now=1000 iters=0
  SIM_RESPAWNS=0
  SIM_OVERALL="PASS"
  while true; do
    iters=$((iters+1))
    if [ "$iters" -gt "$ITER_CAP" ]; then SIM_OVERALL="INFLOOP"; break; fi
    sim_poll "$now"
    if [ "$SIM_RECEIVED" -eq "${#VERDICT_BEAD_IDS[@]}" ]; then
      [ "$SIM_ANYFAIL" = "1" ] && SIM_OVERALL="FAIL"
      break
    fi
    # Injected outer-timeout backstop (stands in for the real 45m wall clock):
    # once every slot has exhausted its budget and is still pending+dead, the
    # real dispatcher would hit VERDICT_TIMEOUT → FAIL. Model that here so the
    # simulation can't run forever.
    if [ "$now" -ge "$SIM_TIMEOUT_AT" ]; then SIM_OVERALL="FAIL"; break; fi
    now=$((now + 600))   # advance the simulated clock one poll
  done
  SIM_ITERS="$iters"
}

reset_slots() {
  RESPAWN_BUDGET=(); SLOT_SPAWN_EPOCH=(); SLOT_DEAD_STREAK=(); SLOT_BEAD=(); SLOT_LIVE=(); SLOT_PEEK=()
  local j
  for j in 0 1 2; do
    RESPAWN_BUDGET[$j]="$MAX_RESPAWNS_PER_SLOT"
    SLOT_SPAWN_EPOCH[$j]=0          # spawned long ago → past grace immediately
    SLOT_DEAD_STREAK[$j]=0
  done
}

MOCK_SPAWN_OK=1                    # spawns succeed for the convergence scenarios
MAX_RESPAWNS_PER_SLOT=2
RECONVENE_GRACE_SECS=0             # grace tested separately (scenario d/grace)
RECONVENE_DEAD_STREAK_MIN=2

# (e) Happy path: all 3 PASS first poll → 0 respawns, OVERALL PASS, 1 iteration.
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS PASS ); SLOT_LIVE=( alive alive alive )
SIM_TIMEOUT_AT=99999; unset REVIVE_ON_RESPAWN
run_sim
eq "(e) happy path → OVERALL=PASS"          "$SIM_OVERALL" "PASS"
eq "(e) happy path → 0 respawns"            "$SIM_RESPAWNS" "0"
eq "(e) happy path → converges in 1 poll"   "$SIM_ITERS" "1"

# (a) Slot 2 session DEAD (absent) → re-convened → then PASS → OVERALL PASS.
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS pending ); SLOT_LIVE=( alive alive absent )
SIM_TIMEOUT_AT=99999; REVIVE_ON_RESPAWN=1; REVIVE_VERDICT="PASS"
run_sim
unset REVIVE_ON_RESPAWN
eq "(a) dead slot re-convened then PASS → OVERALL=PASS"  "$SIM_OVERALL" "PASS"
eq "(a) exactly ONE respawn fired (streak_min=2)"        "$SIM_RESPAWNS" "1"
eq "(a) slot 2 session id was swapped"                   "${SESSION_IDS[2]}" "$MOCK_NEW_SID"

# (b) Slot 2 permanently DEAD, MAX=1 → at most 1 respawn, NO infinite loop, FAIL.
MAX_RESPAWNS_PER_SLOT=1
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS pending ); SLOT_LIVE=( alive alive absent )
SIM_TIMEOUT_AT=4000; unset REVIVE_ON_RESPAWN    # stays dead forever
run_sim
eq "(b) permanent-dead slot → OVERALL=FAIL (outer timeout backstop)"  "$SIM_OVERALL" "FAIL"
eq "(b) respawns bounded to MAX_RESPAWNS_PER_SLOT (=1)"               "$SIM_RESPAWNS" "1"
[ "$SIM_OVERALL" != "INFLOOP" ] && ok "(b) loop terminated (no infinite spin, iters=$SIM_ITERS)" \
                                  || bad "(b) loop exceeded ITER_CAP — INFINITE LOOP"
MAX_RESPAWNS_PER_SLOT=2

# (c) Explicit verdict:FAIL → NO respawn, immediate FAIL (even though session gone).
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS FAIL ); SLOT_LIVE=( alive alive absent )
SIM_TIMEOUT_AT=99999; unset REVIVE_ON_RESPAWN
run_sim
eq "(c) explicit FAIL → OVERALL=FAIL"        "$SIM_OVERALL" "FAIL"
eq "(c) explicit FAIL → 0 respawns"          "$SIM_RESPAWNS" "0"
eq "(c) explicit FAIL → converges in 1 poll" "$SIM_ITERS" "1"

# (d) Slow-but-ALIVE reviewer (present, not closed, bead pending then PASS):
# must NOT be re-convened.
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS pending ); SLOT_LIVE=( alive alive alive )
SIM_TIMEOUT_AT=99999; unset REVIVE_ON_RESPAWN
# revive the slow reviewer's bead to PASS after 2 polls (still alive throughout)
_orig_sim_poll_d=1
# drive manually: poll once (no respawn), then flip bead PASS, poll again.
run_sim_d() {
  local now=1000 iters=0
  SIM_RESPAWNS=0; SIM_OVERALL="PASS"
  while true; do
    iters=$((iters+1))
    if [ "$iters" -gt "$ITER_CAP" ]; then SIM_OVERALL="INFLOOP"; break; fi
    [ "$iters" -eq 3 ] && SLOT_BEAD[2]="PASS"   # slow reviewer finally finishes
    sim_poll "$now"
    if [ "$SIM_RECEIVED" -eq "${#VERDICT_BEAD_IDS[@]}" ]; then
      [ "$SIM_ANYFAIL" = "1" ] && SIM_OVERALL="FAIL"; break
    fi
    now=$((now + 600))
  done
  SIM_ITERS="$iters"
}
run_sim_d
eq "(d) slow-but-alive → OVERALL=PASS"           "$SIM_OVERALL" "PASS"
eq "(d) slow-but-alive → 0 respawns"             "$SIM_RESPAWNS" "0"
eq "(d) slow-but-alive → session id NOT swapped" "${SESSION_IDS[2]}" "s2"

# (f) ga-h9o17: slot 2 reviewer DRAINED — still LISTED + not-closed, so
# session_is_dead reads it ALIVE (dead=0), but `gc session peek` reports
# session-gone (SLOT_PEEK=gone). This is the exact false-FAIL the list-only check
# missed (observed live: 2/3-PASS, reviewer-2 drained with verdict:pending, no
# re-convene for 37min). The peek probe must treat it DEAD → re-convene → PASS.
VERDICT_BEAD_IDS=( vb0 vb1 vb2 ); SESSION_IDS=( s0 s1 s2 ); REVIEW_TASKS=( t0 t1 t2 )
reset_slots
SLOT_BEAD=( PASS PASS pending ); SLOT_LIVE=( alive alive alive ); SLOT_PEEK=( found found gone )
SIM_TIMEOUT_AT=99999; REVIVE_ON_RESPAWN=1; REVIVE_VERDICT="PASS"
run_sim
unset REVIVE_ON_RESPAWN
eq "(f) drained-but-listed slot re-convened then PASS → OVERALL=PASS" "$SIM_OVERALL" "PASS"
eq "(f) exactly ONE respawn fired (streak_min=2)"                    "$SIM_RESPAWNS" "1"
eq "(f) slot 2 session id was swapped (drained reviewer replaced)"   "${SESSION_IDS[2]}" "$MOCK_NEW_SID"

# (g) SAFETY: the ga-h9o17 peek path must reap ONLY a drained peek — a genuinely
# asleep-but-ALIVE reviewer (LISTED + not-closed AND peek SUCCEEDS) is NEVER
# re-convened. Single-poll, streak_min=1 so the decision is immediate either way.
VERDICT_BEAD_IDS=( vb0 ); SESSION_IDS=( s0 ); REVIEW_TASKS=( t0 )
RESPAWN_BUDGET=( 2 ); SLOT_DEAD_STREAK=( 0 ); SLOT_SPAWN_EPOCH=( 0 )
RECONVENE_GRACE_SECS=0; RECONVENE_DEAD_STREAK_MIN=1
SLOT_BEAD=( pending ); SLOT_LIVE=( alive ); SLOT_PEEK=( found )
SIM_RESPAWNS=0
sim_poll 1000
eq "(g) listed + peek-found (asleep, alive) → 0 respawns (never reaped)" "$SIM_RESPAWNS" "0"
eq "(g) asleep-but-alive → session id NOT swapped"                      "${SESSION_IDS[0]}" "s0"
# Converse: SAME slot, peek now reports session-gone (drained) → respawn fires.
SLOT_PEEK=( gone ); SLOT_DEAD_STREAK=( 0 ); SLOT_SPAWN_EPOCH=( 0 ); SIM_RESPAWNS=0
sim_poll 1000
eq "(g) listed + peek-gone (drained) → respawn fires (the fix)"         "$SIM_RESPAWNS" "1"
RECONVENE_GRACE_SECS=0; RECONVENE_DEAD_STREAK_MIN=2

# Grace gate: a dead session inside its grace window is NOT re-convened.
VERDICT_BEAD_IDS=( vb0 ); SESSION_IDS=( s0 ); REVIEW_TASKS=( t0 )
RESPAWN_BUDGET=( 2 ); SLOT_DEAD_STREAK=( 0 )
RECONVENE_GRACE_SECS=300; RECONVENE_DEAD_STREAK_MIN=1
SLOT_SPAWN_EPOCH=( 1000 ); SLOT_BEAD=( pending ); SLOT_LIVE=( absent )
SIM_RESPAWNS=0
sim_poll 1100   # only 100s after spawn, grace=300 → must NOT respawn
eq "grace gate: dead within grace window → no respawn" "$SIM_RESPAWNS" "0"
sim_poll 1500   # 500s after spawn, past grace, streak_min=1 → respawn
eq "grace gate: dead past grace window → respawn"      "$SIM_RESPAWNS" "1"
RECONVENE_GRACE_SECS=0; RECONVENE_DEAD_STREAK_MIN=2

# ── 5. Drift-guard: the live dispatcher wires the re-convene path in ──────────
echo "── 5. drift-guard: dispatcher wires ga-4u16h re-convene ──"
grep -q 'classify_slot_action()'   "$DISPATCHER" && ok "dispatcher defines classify_slot_action"   || bad "missing classify_slot_action def"
grep -q 'session_is_dead()'        "$DISPATCHER" && ok "dispatcher defines session_is_dead"        || bad "missing session_is_dead def"
grep -q 'respawn_reviewer_slot()'  "$DISPATCHER" && ok "dispatcher defines respawn_reviewer_slot"  || bad "missing respawn_reviewer_slot def"
grep -q 'GATE_DISPATCHER_LIB_ONLY' "$DISPATCHER" && ok "dispatcher is sourceable in lib-only mode" || bad "missing lib-only hook"
grep -q 'MAX_RESPAWNS_PER_SLOT'    "$DISPATCHER" && ok "dispatcher reads MAX_RESPAWNS_PER_SLOT"     || bad "missing MAX_RESPAWNS_PER_SLOT"
grep -q 'RECONVENE_GRACE_SECS'     "$DISPATCHER" && ok "dispatcher applies grace window"           || bad "missing RECONVENE_GRACE_SECS"
grep -q 'RECONVENE_DEAD_STREAK_MIN' "$DISPATCHER" && ok "dispatcher applies dead-streak guard"     || bad "missing RECONVENE_DEAD_STREAK_MIN"
# the poll loop must CALL the classifier on a pending slot and re-spawn:
grep -q 'classify_slot_action 0 ' "$DISPATCHER" && ok "poll loop calls classify_slot_action on a pending (bead_closed=0) slot" || bad "poll loop not calling classify_slot_action"
grep -q 'respawn_reviewer_slot "\$j"' "$DISPATCHER" && ok "poll loop re-spawns the dead slot"      || bad "poll loop not calling respawn_reviewer_slot"
grep -q 'Re-convening dead reviewer slot' "$DISPATCHER" && ok "poll loop logs the re-convene event" || bad "missing 'Re-convening dead reviewer slot' log"
grep -q 'RESPAWN_BUDGET\[\$j\]=\$(( ' "$DISPATCHER" && ok "poll loop decrements per-slot budget"   || bad "budget not decremented (unbounded!)"
grep -q 'SLOT_SPAWN_EPOCH\[\$j\]="\$NOW_EPOCH"' "$DISPATCHER" && ok "poll loop resets slot grace clock on respawn" || bad "slot grace clock not reset on respawn"
grep -q 'session list --json' "$DISPATCHER" && ok "poll loop snapshots session liveness"          || bad "missing session list snapshot"
grep -q 'REVIEW_TASKS\[\$_idx\]' "$DISPATCHER" && ok "respawn reuses the stored review task"       || bad "respawn does not reuse stored review task"
# the outer 45m timeout backstop must still exist (do NOT remove it):
grep -q 'Verdict timeout after' "$DISPATCHER" && ok "outer verdict timeout backstop preserved"     || bad "outer verdict timeout REMOVED (ultimate backstop gone!)"
grep -q 'VERDICT_TIMEOUT_SECS' "$DISPATCHER" && ok "VERDICT_TIMEOUT_SECS cap preserved"            || bad "VERDICT_TIMEOUT_SECS cap removed"
# happy-path counting must be untouched:
grep -q 'VERDICTS_RECEIVED=$((VERDICTS_RECEIVED + 1))' "$DISPATCHER" && ok "verdict-received counting unchanged (happy path)" || bad "verdict counting changed"
# re-convene must NOT add a `bd ... create`: the 2 pre-existing creates (gate-run
# tracking bead + initial verdict bead) are unchanged — re-convene reuses the
# still-pending verdict bead, so the count must stay at the baseline of 2.
eq "no new 'bd ... create' added by re-convene (baseline 2: gate-run + verdict bead)" \
   "$(grep -cE 'bd -C "\$GC_CITY" create' "$DISPATCHER")" "2"

# ── 5b. drift-guard: the live dispatcher wires the ga-mepb0 boot-wedge fix ─────
# These assertions fail LOUDLY if a future refactor drops the present-but-never-
# acked re-convene path (the false-FAIL fix) or the spawn stagger.
echo "── 5b. drift-guard: dispatcher wires ga-mepb0 boot-wedge + stagger ──"
grep -q 'slot_effectively_dead()' "$DISPATCHER" && ok "dispatcher defines slot_effectively_dead" || bad "missing slot_effectively_dead def (ga-mepb0 fix dropped)"
# The poll loop must gate the dead-streak + confirmed-dead on _eff_dead, NOT the
# raw _dead — otherwise a boot-wedged (present) reviewer is never re-convened.
grep -q '_eff_dead=$(slot_effectively_dead' "$DISPATCHER" && ok "poll loop computes _eff_dead from slot_effectively_dead" || bad "poll loop does not fold ACK into deadness (ga-mepb0)"
eq "poll loop gates streak/confirmed-dead on _eff_dead (>=2 sites), not raw _dead" \
   "$(grep -cE '\[ "\$_eff_dead" = "1" \]' "$DISPATCHER")" "2"
# Late-life re-check must run so a slow-but-alive reviewer is never killed:
grep -q 'Late ACK (verdict-progressed)' "$DISPATCHER" && ok "poll loop has strong late-ACK (verdict progressed) re-check" || bad "missing strong late-ACK re-check (slow reviewer at risk)"
grep -q 'Late ACK (session-alive)' "$DISPATCHER" && ok "poll loop has soft late-ACK (new output) re-check" || bad "missing soft late-ACK re-check (slow reviewer at risk)"
# respawn must re-arm the ACK gate AND snapshot a real (non-empty) peek baseline
# so a re-wedged respawn is caught — not falsely ACKed on its boot banner.
grep -q 'REVIEWER_ACKED\[\$_idx\]=0' "$DISPATCHER" && ok "respawn clears ACK flag for fresh session" || bad "respawn does not re-arm ACK gate (stale ACK masks re-wedge)"
grep -q 'REVIEWER_PEEK_BASELINE\[\$_idx\]=$(gc' "$DISPATCHER" && ok "respawn snapshots a REAL peek baseline (not empty)" || bad "respawn leaves empty baseline → boot banner falsely soft-ACKs a re-wedge"
# EDIT #2: spawn stagger so N reviewers do not boot-herd Dolt :52756 at once.
grep -q 'GATE_SPAWN_STAGGER_SECS' "$DISPATCHER" && ok "dispatcher defines spawn stagger (Dolt boot-herd guard)" || bad "missing GATE_SPAWN_STAGGER_SECS"
grep -q 'sleep "\$GATE_SPAWN_STAGGER_SECS"' "$DISPATCHER" && ok "spawn loop actually applies the stagger sleep" || bad "GATE_SPAWN_STAGGER_SECS defined but never applied"

# ── 5c. drift-guard: the live dispatcher wires the ga-h9o17 drained-peek fix ───
# Fail LOUDLY if a future refactor drops the drained-but-listed peek probe (the
# fix for a reviewer that DRAINS after ACKing — invisible to both the list-only
# session_is_dead and the ACK-folding slot_effectively_dead).
echo "── 5c. drift-guard: dispatcher wires ga-h9o17 drained-peek probe ──"
grep -q 'session_peek_reports_dead()' "$DISPATCHER" && ok "dispatcher defines session_peek_reports_dead" || bad "missing session_peek_reports_dead def (ga-h9o17 fix dropped)"
# The probe must run a peek and fold its verdict into _eff_dead in the poll loop.
grep -q '_peek_dead=$(session_peek_reports_dead' "$DISPATCHER" && ok "poll loop computes _peek_dead via session_peek_reports_dead" || bad "poll loop does not probe peek for drained reviewers (ga-h9o17)"
grep -q '\[ "\$_peek_dead" = "1" \] && _eff_dead=1' "$DISPATCHER" && ok "poll loop folds _peek_dead into _eff_dead" || bad "poll loop does not treat a drained peek as dead (ga-h9o17)"
# The peek must capture STDERR ONLY (2>&1 >/dev/null) so a live reviewer's STDOUT
# scrollback can never false-trigger the not-found match.
grep -q 'session peek "\$_sid" --lines 5 2>&1 >/dev/null' "$DISPATCHER" && ok "drained probe captures peek STDERR only (stdout→/dev/null)" || bad "drained probe does not isolate stderr (live scrollback could false-match)"
# The probe must be bounded to the suspicious window: list-alive (_dead=0) + past
# grace — NOT run on a session the list already calls dead.
grep -q '\[ "\$_dead" = "0" \] && \[ "\$_spawn_age" -ge "\$RECONVENE_GRACE_SECS" \]' "$DISPATCHER" && ok "drained probe bounded to list-alive + past-grace slots" || bad "drained probe not bounded (runs every poll / inside grace)"
grep -q 'Drained reviewer detected (ga-h9o17)' "$DISPATCHER" && ok "poll loop logs the drained-reviewer detection" || bad "missing 'Drained reviewer detected' log"

# ── 6. dispatcher still parses + lib-only return is a no-op in normal flow ─────
echo "── 6. syntax + lib-only safety ──"
bash -n "$DISPATCHER" && ok "dispatcher passes bash -n" || bad "dispatcher syntax error"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

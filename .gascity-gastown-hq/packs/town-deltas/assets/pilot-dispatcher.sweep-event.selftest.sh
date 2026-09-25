#!/usr/bin/env bash
# pilot-dispatcher.sweep-event.selftest.sh — the Pilot's per-sweep aggregate event (ga-ov3gow).
#
# Bug ga-ov3gow: pilot-dispatcher.jsonl only ever received a `pilot_dispatch` line from the END of
# dispatch_one(). Every exit that does `DISPATCH_RESULT=...; return 1` — a pool/global session-cap
# queue, a failed spawn, a guard refusal, a failed assign/sling — left no trace, so the painel's
# "Sucesso" tile could not see saturation or failure: it measured "of the dispatches that reached
# the end, how many succeeded", not the health of the Pilot.
#
# Mayor's decision (bead comment, 2026-09-20): ONE aggregate event per sweep, as its OWN event type
# `pilot_sweep` — NEVER as new `result` values inside `pilot_dispatch`. The painel's Ritmo, sparkline,
# lane split and Sucesso all count `pilot_dispatch` lines (daemons/painel_visibilidade.py
# _load_pilot_activity filters on event == "pilot_dispatch"), so queue/failure lines written under that
# name would inflate the very tiles this is meant to make honest — a blind tile replaced by a lying one.
#
# What this file proves, fast (no full dispatcher run — that is the runtime scenario "SWEEP" in
# pilot-dispatcher.selftest.sh, which drives the real dispatch_one() through the rig-native arm):
#   Part A — the emitter: every real DISPATCH_RESULT name lands in the right bucket, the buckets add up to
#            `candidates`, a bead re-walked by the rig fallback counts once (as it ended), an unknown or
#            missing result is NEVER read as a success, the line has no ids and a size independent of the
#            queue depth, and a failing write never kills the sweep.
#   Part B — the wiring + drift guards: dispatch_lane() can actually SEE the result (DISPATCH_RESULT is not
#            local to dispatch_one), notes every exit, and a new DISPATCH_RESULT literal cannot silently
#            fall into "failed" (the classification vocabulary must be updated with it).
#
# Only a sweep that reaches the dispatch loops emits; every early exit (pauses, no candidates, both lanes
# full) writes nothing, so a missing line is not a liveness signal — see the header block above dispatch_lane()
# in pilot-dispatcher.sh and the runtime scenario SWEEP-D.
#
# Falsifiable: neither function exists before this fix, so the awk extraction below fails hard
# (FATAL, exit 2) against pre-fix HEAD — this selftest cannot pass without the fix landed, and it fails in
# milliseconds there, which keeps the gate's A/B base-commit check (it re-runs changed selftests against the
# base under a short time budget) well inside that budget.
#
# Run:  bash packs/town-deltas/assets/pilot-dispatcher.sweep-event.selftest.sh
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Extract the two functions verbatim from the live file ──────────────────────
extract_fn() {
  local _name="$1"
  awk "/^${_name}\\(\\)/{f=1} f{print} f&&/^}\$/{exit}" "$DISPATCHER"
}
NOTE_FN="$(extract_fn '_pilot_sweep_note')"
EMIT_FN="$(extract_fn '_pilot_sweep_emit')"
if [ -z "$NOTE_FN" ]; then
  echo "FATAL: _pilot_sweep_note() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi
if [ -z "$EMIT_FN" ]; then
  echo "FATAL: _pilot_sweep_emit() not found in $DISPATCHER (pre-fix HEAD, or extraction pattern drifted)" >&2
  exit 2
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-sweep-event-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
LOG="$WORK/pilot-dispatcher.jsonl"

# run_sweep <notes> — one sweep under PRODUCTION shell semantics (/bin/bash 3.2, set -euo pipefail, no
# associative arrays). <notes> = one "<bead_id> <rc> [<result>]" per line; an omitted result is the
# "dispatch_one() returned non-zero WITHOUT naming a reason" case. Extra knobs come from the environment
# of the call: DRY (DRY_RUN), SAT (_pool_saturated_sweep), SMALL / BIG (free lane slots), EMIT_LOG.
# The emitted jsonl line(s) land in $LOG; the exit status is the emitter's, so a caller can prove that a
# failing write does not abort the sweep.
run_sweep() {
  local _notes="$1" _out="${EMIT_LOG:-$LOG}"
  : > "$LOG"
  /bin/bash -c '
set -euo pipefail
PILOT_LOG="$1"; DRY_RUN="$2"; _pool_saturated_sweep="$3"; SMALL_SLOTS="$4"; BIG_SLOTS="$5"
SWEEP_OUTCOMES=""
warn() { echo "WARN: $*" >&2; }
'"$NOTE_FN"'
'"$EMIT_FN"'
while IFS=" " read -r _id _rc _res; do
  [ -z "$_id" ] && continue
  _pilot_sweep_note "$_id" "$_rc" "${_res:-}"
done <<< "$6"
_pilot_sweep_emit
echo "emit-returned-and-script-still-running"
' _ "$_out" "${DRY:-0}" "${SAT:-0}" "${SMALL:-5}" "${BIG:-2}" "$_notes"
}

# NEVER `printf|echo ... | grep -q` (or `| awk '...exit'`) under pipefail: the reader exits at the first match, the
# writer gets SIGPIPE, and pipefail turns a successful match into a failure — measured 61/400 (15%) false
# negatives on a 1.9 KB payload. Every text check below reads its input through a here-string instead.
# jq over the single emitted line
f() { jq -rc "$1" "$LOG" 2>/dev/null; }
expect() { # expect <jq-expr> <expected> <description>
  local _got; _got="$(f "$1")"
  if [ "$_got" = "$2" ]; then ok "$3"; else bad "$3 — expected '$2', got '$_got'"; fi
}

echo "pilot-dispatcher.sweep-event.selftest — ga-ov3gow"
echo ""
echo "=== Part A: the emitter ==="

# A1 — a sweep that REACHED the end but had nothing to count (e.g. candidates only for a lane with no free
# slots) still writes its line, with every bucket a present 0: the emitter never goes silent just because there
# was nothing to tally. (Sweeps that exit BEFORE the dispatch loops — pauses, "no dispatchable candidates",
# "both lanes full" — never call it at all; that is the runtime scenario SWEEP-D, and it means a missing
# line is NOT a liveness signal.)
out="$(run_sweep "" 2>&1)"
[ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] && ok "A1: a sweep with nothing to tally still writes exactly ONE line" \
                                          || bad "A1: a sweep with nothing to tally did not write exactly one line"
expect '.event' 'pilot_sweep'      "A1: event type is its own name — never pilot_dispatch (Ritmo/sparkline/Sucesso count that one)"
expect '.candidates' '0'           "A1: candidates=0"
expect '(.dispatched+.queued_pool_cap+.queued_global_cap+.spawn_failed+.failed_other+.unclassified)' '0' "A1: every bucket is a present, numeric 0 (not absent: absent vs 0 would be two states)"
expect '.refused_by_guard | type' 'object' "A1: refused_by_guard is an (empty) object, not null"
expect '.results | length' '0'     "A1: results is empty"
grep -q 'emit-returned-and-script-still-running' <<< "$out" && ok "A1: the emitter returns 0 under set -euo pipefail (the sweep goes on)" \
                                                              || bad "A1: the emitter killed the shell under set -euo pipefail: $out"
grep -q 'WARN:' <<< "$out" && bad "A1: a healthy emit announced a failure: $out" \
                          || ok "A1: a healthy emit is quiet (no WARN)"
expect '.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' 'true' "A1: ts is UTC ISO-8601 like pilot_dispatch.ts"
expect '.dry_run' '0'              "A1: dry_run is carried as the same '0'/'1' string pilot_dispatch uses"

# A2 — every REAL DISPATCH_RESULT name (the exits ga-ov3gow is about), one bead each, lands in ITS bucket.
BATCH='b01 0 rig_native_ok
b02 0 sling_ok
b03 1 rig_native_pool_session_cap_queued
b04 1 rig_native_pool_session_cap_queued
b05 1 rig_native_global_session_cap_queued
b06 1 rig_native_spawn_failed
b07 1 rig_native_pool_target_only
b08 1 pool_ownership_refuse
b09 1 rig_native_dog_store_blind
b10 1 rig_dedup_skip
b11 1 rig_assign_failed
b12 1 sling_no_bead_id
b13 1 sling_phantom_bead
b14 1 inflight_unconfirmed
b15 1
b16 1 some_future_result
b17 1 rig_native_dog_store_migrated'
run_sweep "$BATCH" >/dev/null 2>&1
echo "=== A2: one bead per real exit ==="
expect '.candidates' '17'          "A2: 17 candidates evaluated"
expect '.dispatched' '2'           "A2: rc=0 → dispatched (rig_native_ok, sling_ok)"
expect '.queued_pool_cap' '2'      "A2: pool session cap → queued_pool_cap, counted per bead"
expect '.queued_global_cap' '1'    "A2: global (ga-jezvn) cap → queued_global_cap, SEPARATE from the pool cap (different causes)"
expect '.spawn_failed' '1'         "A2: rig_native_spawn_failed → spawn_failed"
expect '.refused_by_guard' '{"pool_ownership_refuse":1,"rig_dedup_skip":1,"rig_native_dog_store_blind":1,"rig_native_dog_store_migrated":1,"rig_native_pool_target_only":1}' \
                                   "A2: each guard refusal is counted UNDER THE GUARD'S NAME (incl. ga-6u64fm's migrated: the guard RESOLVED the refusal)"
expect '.refused_by_guard.rig_native_dog_store_migrated' '1' "A2: a successful auto-migration (ga-6u64fm) is a guard outcome, NOT a Pilot fault (B4 caught it landing in failed_other)"
expect '.failed_other' '5'         "A2: assign/sling/inflight failures and an UNKNOWN name → failed_other (unknown is never a success; rig_native_dog_store_migrated is NOT in it)"
expect '.unclassified' '1'         "A2: non-zero exit with NO named result → unclassified (not dropped, not called a success)"
expect '.results.some_future_result' '1' "A2: an unknown result still shows up BY NAME in results (the next vocabulary drift explains itself)"
expect '.results.rig_native_pool_session_cap_queued' '2' "A2: results is the per-name ground truth (same vocabulary as pilot_dispatch.result)"
expect '.results | has("")' 'false' "A2: the nameless exit has no results key (it is only in unclassified)"

# A3 — the buckets add up to candidates: nothing is dropped and nothing is counted twice.
expect '.candidates == (.dispatched + .queued_pool_cap + .queued_global_cap + .spawn_failed + ([.refused_by_guard[]] | add // 0) + .failed_other + .unclassified)' 'true' \
       "A3: candidates == sum of every bucket (accounting closes)"

# A4 — a bead the rig fallback re-walks counts ONCE, as it ended (last outcome wins).
run_sweep 'r1 1 sling_no_bead_id
r1 0 rig_native_ok' >/dev/null 2>&1
expect '.candidates' '1'           "A4: the same bead noted twice is ONE candidate"
expect '.dispatched' '1'           "A4: … and it counts as it ENDED (dispatched), not as its first failed attempt"
expect '.failed_other' '0'         "A4: the superseded failure is not also counted"

# A5 — a bead queued in two passes is one queued bead (capacity demand, not attempts).
run_sweep 'q1 1 rig_native_pool_session_cap_queued
q1 1 rig_native_pool_session_cap_queued
q2 1 rig_native_pool_session_cap_queued' >/dev/null 2>&1
expect '.queued_pool_cap' '2'      "A5: 3 notes for 2 distinct beads → queued_pool_cap=2"

# A6/A7 — the line carries NO ids and its size does not depend on the queue depth (the point of an
# aggregate: the painel reads only a 256 KiB tail, so a 3-bead and a 300-bead queue must cost the same).
SMALLQ="$(for i in 1 2 3; do echo "wa-x$i 1 rig_native_pool_session_cap_queued"; done)"
BIGQ="$(for i in $(seq 1 300); do echo "wa-x$i 1 rig_native_pool_session_cap_queued"; done)"
run_sweep "$SMALLQ" >/dev/null 2>&1; size_small="$(wc -c < "$LOG" | tr -d ' ')"
run_sweep "$BIGQ"   >/dev/null 2>&1; size_big="$(wc -c < "$LOG" | tr -d ' ')"
[ "$(wc -l < "$LOG" | tr -d ' ')" = "1" ] && ok "A6: a 300-bead queue is still ONE line (never one line per bead)" \
                                          || bad "A6: a 300-bead queue produced $(wc -l < "$LOG" | tr -d ' ') lines"
expect '.queued_pool_cap' '300'    "A6: … carrying queued_pool_cap=300"
if [ "$((size_big - size_small))" -le 8 ]; then
  # only the digit width of the three counters (candidates, queued_pool_cap, results.<name>) may grow
  ok "A6: line size is independent of queue depth ($size_small B for 3 beads vs $size_big B for 300 — only counter digits differ)"
else
  bad "A6: line size grows with the queue ($size_small B → $size_big B) — would flood the painel's 256 KiB tail"
fi
[ "$size_big" -le 512 ] && ok "A6: a saturated sweep line is small ($size_big B ≤ 512)" || bad "A6: line is $size_big B (> 512)"
grep -q 'wa-x' "$LOG" && bad "A7: a bead id leaked into the aggregate line (the goal is Pilot health, not per-bead audit)" \
                      || ok "A7: no bead id appears in the line"

# A8 — pool_saturated / lane slots / dry_run are passed through verbatim from the sweep's own state.
SAT=1 SMALL=3 BIG=0 DRY=1 run_sweep 'q1 1 rig_native_pool_session_cap_queued' >/dev/null 2>&1
expect '.pool_saturated' '1'       "A8: pool_saturated carries the sweep's ONE saturation predicate (_pool_saturated_sweep) — consumers do not re-derive it"
expect '.small_slots' '3'          "A8: small_slots (free lane capacity — needed to tell a stall from saturation from idle)"
expect '.big_slots' '0'            "A8: big_slots"
expect '.dry_run' '1'              "A8: dry_run '1' is carried (a simulation must be excludable, as for pilot_dispatch)"
SAT=0 run_sweep '' >/dev/null 2>&1
expect '.pool_saturated' '0'       "A8: pool_saturated=0 when the sweep was not saturated"
# A value that is NOT a number is UNKNOWN. It is written as null — never as a 0 the consumer would read as
# "no free slot" / "not saturated" (a third state must not collapse into a verdict).
SAT=oops SMALL=abc BIG=2 run_sweep '' >/dev/null 2>&1
expect '.small_slots' 'null'       "A8: a non-numeric small_slots is null (unknown), NOT 0 free slots"
expect '.pool_saturated' 'null'    "A8: a non-numeric saturation flag is null (unknown), NOT 'not saturated'"
expect '.big_slots' '2'            "A8: a valid sibling value is unaffected by the unknown one"

# A9 — a write that fails must NEVER abort the sweep (observability is not allowed to become an outage).
out="$(EMIT_LOG=/dev/null/no/such/dir/pilot.jsonl run_sweep 'a 0 rig_native_ok' 2>&1)"
grep -q 'emit-returned-and-script-still-running' <<< "$out" && ok "A9: an unwritable log leaves the sweep running (write is best-effort)" \
                                                              || bad "A9: an unwritable PILOT_LOG killed the shell: $out"
grep -q 'could not append the pilot_sweep line' <<< "$out" \
  && ok "A9: … and the lost line is ANNOUNCED (WARN), never silent — a missing line would otherwise read as 'no sweep evaluated candidates'" \
  || bad "A9: an unwritable PILOT_LOG failed SILENTLY (no WARN): $out"

echo ""
echo "=== Part B: wiring and drift guards ==="

# B1 — dispatch_lane() reads DISPATCH_RESULT after dispatch_one() returns; a `local` in dispatch_one would
# make it invisible there (the exact reason the exits left no trace to tally).
if grep -nE '^[[:space:]]*local[[:space:]].*DISPATCH_RESULT' "$DISPATCHER" >/dev/null; then
  bad "B1: DISPATCH_RESULT is declared local — dispatch_lane() cannot see why dispatch_one() returned 1"
else
  ok "B1: DISPATCH_RESULT is not local to dispatch_one (dispatch_lane can read it after the call)"
fi
# It must be reset on entry, or an early exit inherits the PREVIOUS candidate's result and is
# mis-tallied under a name it never had.
ONE_FN="$(extract_fn 'dispatch_one')"
grep -qE '^[[:space:]]*DISPATCH_RESULT=""' <<< "$(sed -n '1,60p' <<< "$ONE_FN")" \
  && ok "B1: dispatch_one resets DISPATCH_RESULT on entry (an early exit reads as 'unnamed', not as the previous candidate's result)" \
  || bad "B1: dispatch_one does not reset DISPATCH_RESULT on entry — an early return would inherit the previous candidate's result"

LANE_FN="$(extract_fn 'dispatch_lane')"
[ -n "$LANE_FN" ] || { echo "FATAL: dispatch_lane() not found" >&2; exit 2; }
grep -qE '_pilot_sweep_note "\$pick_id" 0 ' <<< "$LANE_FN" \
  && ok "B2: dispatch_lane notes a dispatch_one() success (rc 0)" \
  || bad "B2: dispatch_lane does not note a successful dispatch_one()"
grep -qE '_pilot_sweep_note "\$pick_id" 1 "\$\{DISPATCH_RESULT:-\}"' <<< "$LANE_FN" \
  && ok "B2: dispatch_lane notes a dispatch_one() non-zero exit WITH its DISPATCH_RESULT (every return 1 that named a reason)" \
  || bad "B2: dispatch_lane does not carry DISPATCH_RESULT into the note for a non-zero dispatch_one()"
# The pre-claim skip never calls dispatch_one at all — without its own note the most common queue path
# (ga-in9ebr AC2: a routed bead whose pool is at cap) would be invisible.
awk '/_pilot_pool_cap_full_for "\$pick"/{f=1} f&&/_pilot_sweep_note "\$pick_id" 1 "rig_native_pool_session_cap_queued"/{found=1} f&&/continue/{exit} END{exit !found}' <<< "$LANE_FN" \
  && ok "B2: the pre-claim pool-cap skip (which bypasses dispatch_one) is noted as a pool-cap queue" \
  || bad "B2: the pre-claim pool-cap skip is not noted — the commonest queue path would leave no trace"
# The behaviour of the caller's counters is unchanged: a non-queue failure still feeds NONQUEUE_FAILS.
grep -q 'NONQUEUE_FAILS=\$((NONQUEUE_FAILS + 1))' <<< "$LANE_FN" \
  && ok "B2: NONQUEUE_FAILS accounting (Step 5 stall gate) is intact" \
  || bad "B2: NONQUEUE_FAILS accounting was lost from dispatch_lane"

# B3 — emitted once per sweep: after the saturation predicate exists (the event carries it), before the
# closing 'sweep complete' line, and NOT from inside a lane loop (that would be per-candidate again).
# EVERY call site counts, indented ones included: an emit inside a lane loop would be per-candidate again.
n_calls="$(grep -E '_pilot_sweep_emit' "$DISPATCHER" | grep -vE '^[[:space:]]*#' | grep -vE '^_pilot_sweep_emit\(\)' | wc -l | tr -d ' ')"
n_top="$(grep -cE '^_pilot_sweep_emit([[:space:]]|$)' "$DISPATCHER")"
[ "$n_calls" = "1" ] && [ "$n_top" = "1" ] \
  && ok "B3: _pilot_sweep_emit has exactly ONE call site and it is at top level (per sweep, never per candidate)" \
  || bad "B3: expected exactly one call site, at top level — found $n_calls call site(s), $n_top at top level"
l_sat="$(grep -n '^_pool_saturated_sweep=0' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_emit="$(grep -nE '^_pilot_sweep_emit([[:space:]]|$)' "$DISPATCHER" | head -1 | cut -d: -f1)"
l_done="$(grep -n '^log "=== Pilot sweep complete: dispatched=\$DISPATCHED' "$DISPATCHER" | tail -1 | cut -d: -f1)"
if [ -n "$l_sat" ] && [ -n "$l_emit" ] && [ -n "$l_done" ] && [ "$l_sat" -lt "$l_emit" ] && [ "$l_emit" -lt "$l_done" ]; then
  ok "B3: the event is emitted after _pool_saturated_sweep is computed (L$l_sat) and before the closing sweep-complete line (L$l_done)"
else
  bad "B3: emission order is wrong (saturation predicate L${l_sat:-?}, emit L${l_emit:-?}, sweep-complete L${l_done:-?})"
fi

# B4 — drift guard. A new DISPATCH_RESULT literal that is not classified would silently land in
# failed_other: a BENIGN new state (e.g. another kind of queue) would then read as a Pilot failure on
# the painel. Adding a result now means classifying it in _pilot_sweep_emit AND listing it here.
KNOWN_RESULTS=" sling_ok rig_native_ok dry_run rig_native_pool_session_cap_queued rig_native_global_session_cap_queued rig_native_spawn_failed pool_ownership_refuse rig_native_dog_store_blind rig_native_dog_store_migrated rig_native_pool_target_only rig_dedup_skip rig_assign_failed sling_no_bead_id sling_phantom_bead inflight_unconfirmed rig_native_pool_count_unreadable "
# (rig_native_pool_count_unreadable, ga-oa004t: the session count could not be READ, so the spawn was not
#  attempted — a FAULT, deliberately left in failed_other and NOT in a *_queued bucket: a dead `session list`
#  is not a busy pool, and filing it as saturation would hide it from the Step 5 stall gate.)
unclassified_names=""
for _lit in $(grep -oE 'DISPATCH_RESULT="[a-z_0-9]+"' "$DISPATCHER" | sed 's/.*="//; s/"$//' | sort -u); do
  case "$KNOWN_RESULTS" in *" $_lit "*) : ;; *) unclassified_names="$unclassified_names $_lit" ;; esac
done
[ -z "$unclassified_names" ] && ok "B4: every DISPATCH_RESULT literal in the dispatcher is classified (no silent drift into failed_other)" \
                             || bad "B4: DISPATCH_RESULT name(s) not classified:$unclassified_names — classify in _pilot_sweep_emit, then add to KNOWN_RESULTS here"
# … and the names the emitter classifies explicitly must still be REAL names (a rename in dispatch_one
# would otherwise leave the emitter matching nothing and everything falling into failed_other).
for _nm in rig_native_pool_session_cap_queued rig_native_global_session_cap_queued rig_native_spawn_failed \
           pool_ownership_refuse rig_native_dog_store_blind rig_native_dog_store_migrated rig_native_pool_target_only rig_dedup_skip; do
  if grep -q "DISPATCH_RESULT=\"$_nm\"" "$DISPATCHER" && grep -q "$_nm" <<< "$EMIT_FN"; then
    :
  else
    bad "B4: '$_nm' is not BOTH assigned in dispatch_one and classified in _pilot_sweep_emit (renamed on one side?)"
    _b4_bad=1
  fi
done
[ -z "${_b4_bad:-}" ] && ok "B4: every explicitly classified result name still exists in dispatch_one (and vice-versa)"

echo ""
echo "pilot-dispatcher.sweep-event.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1

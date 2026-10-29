#!/usr/bin/env bash
# gate-yjrg7n6-preadmit-budget.selftest.sh (ga-yjrg7n6, part b)
#
# A queued marker is admitted without waiting for ALL of Phase C. Measured before this change (29/10 00:49-01:03, the dispatcher
# log): one round held the lock ~13 min with 9 markers queued and admitted none — Phase C walked every in-flight run in series
# (~35-48 s each), one finalize took ~2.5 min, and two mid-sweep Phase-C-only passes (ga-bk5j8u.1) took 3m46s and 2m47s, all
# before "Found N queued marker(s)".
#
# What this proves (no live Dolt / gc / launchd; real functions of the real dispatcher, and the real script as a real process in a
# scratch city):
#   1. gate_preadmit_budget_spent: spent / not spent / budget 0 = off / a clock, start time or budget that is not a number is
#      "not spent" (never a Phase C cut short on a guess); leading zeros are decimal.
#   2. gate_phase_c_order_deferred_first: the runs the last round did not reach go first, the order inside each group is kept,
#      unknown ids are ignored, nothing is lost or duplicated; an unreadable array comes back untouched, never as an empty list.
#   3. the deferred-run file: absent / empty / unreadable read as "none" (the last one says so); an atomic write; a write that
#      fails says so and does not stop the sweep; nothing is written when there is nothing to record.
#   4. gate_midsweep_collect: with a marker waiting, or the budget spent, a closed verdict is NOT collected by a child pass (no bd
#      read either), the candidate is kept and collected as soon as the pass is allowed again, and the line is said once per
#      sweep; budget 0 is the old behaviour (the child starts regardless); a start time that cannot be read does not defer.
#   5. the REAL dispatcher as a real process, with four in-flight runs that cost 3 s each to check and a 5 s budget: the round
#      stops starting runs once the budget is spent, writes the ones it did not reach, the NEXT round checks those first (so the
#      two rounds cover all four), budget 0 checks all four in the first round (old behaviour), and a Phase-C-only child ignores
#      the budget (it was handed exactly the runs to collect).
#   6. the wiring has teeth: removing the `break` from Phase C, or the deferral from gate_midsweep_collect, turns a check red.
#
# Exit 0 iff every assertion holds.
# Test seam: QG_YJRG7N6_DISPATCHER points the checks at another dispatcher file. Run on the previous HEAD's dispatcher this FAILS
# (the functions do not exist there, and its Phase C checks all four runs).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${QG_YJRG7N6_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
REPO_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gate-yjrg7n6.XXXXXX")"
trap '[ -n "${ROOT:-}" ] && rm -rf "$ROOT"' EXIT
# The dispatcher puts its lock dir under $TMPDIR at source time: keep it in the scratch dir, never the real one.
export TMPDIR="$ROOT/tmp"
mkdir -p "$TMPDIR"

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" >/dev/null 2>&1 \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
set +e   # the dispatcher turns errexit on; the harness counts failures instead

# None of these existed before ga-yjrg7n6: an unpatched dispatcher stops here instead of silently skipping every check below.
for _fn in gate_preadmit_budget_spent gate_phase_c_order_deferred_first gate_phase_c_deferred_read gate_phase_c_deferred_write \
           gate_preadmit_defer_midsweep gate_midsweep_collect; do
  type "$_fn" >/dev/null 2>&1 || { echo "FATAL: $_fn not defined by the dispatcher (ga-yjrg7n6 missing?)"; exit 1; }
done

LOGF="$ROOT/log.txt"; : > "$LOGF"
log()  { printf '%s\n' "$*" >> "$LOGF"; }
warn() { printf 'WARN %s\n' "$*" >> "$LOGF"; }
err()  { printf 'ERR %s\n' "$*" >> "$LOGF"; }

# ── 1. gate_preadmit_budget_spent (pure) ───────────────────────────────────────
echo "── 1. the pre-admission budget: spent, not spent, off, unreadable ──"
spent() { if gate_preadmit_budget_spent "$@"; then echo spent; else echo "not-spent"; fi; }
eq "elapsed 150 of 150 → spent"                     "$(spent 1000 1150 150)" "spent"
eq "elapsed 149 of 150 → not spent"                 "$(spent 1000 1149 150)" "not-spent"
eq "elapsed 0 → not spent"                          "$(spent 1000 1000 150)" "not-spent"
eq "budget 0 = off, however long it has been"       "$(spent 1000 99999 0)"  "not-spent"
eq "budget '000' = off too"                         "$(spent 1000 99999 000)" "not-spent"
eq "leading zeros are decimal, not octal (08 s)"    "$(spent 1000 1008 08)"  "spent"
eq "start time empty → not spent"                   "$(spent '' 1150 150)"   "not-spent"
eq "start time not a number → not spent"            "$(spent abc 1150 150)"  "not-spent"
eq "clock empty → not spent"                        "$(spent 1000 '' 150)"   "not-spent"
eq "clock not a number → not spent"                 "$(spent 1000 12x 150)"  "not-spent"
eq "budget empty → not spent"                       "$(spent 1000 1150 '')"  "not-spent"
eq "budget not a number → not spent"                "$(spent 1000 1150 -5)"  "not-spent"
eq "no arguments → not spent"                       "$(spent)"               "not-spent"
eq "a clock that went backwards → not spent"        "$(spent 2000 1000 150)" "not-spent"

# ── 2. gate_phase_c_order_deferred_first (pure) ────────────────────────────────
echo "── 2. the deferred runs go first, nothing is lost ──"
_RUNS='[{"id":"r1"},{"id":"r2"},{"id":"r3"},{"id":"r4"},{"id":"r5"}]'
ids() { jq -r '[.[].id] | join(" ")' 2>/dev/null; }
eq "r4 r5 deferred → r4 r5 r1 r2 r3 (the others keep the order they came in)" "$(gate_phase_c_order_deferred_first "$_RUNS" "r4 r5" | ids)" "r4 r5 r1 r2 r3"
eq "the deferred group follows the file's order (r5 r4 → r5 r4 r1 r2 r3), not the array's: that is what makes the rounds a rotation" "$(gate_phase_c_order_deferred_first "$_RUNS" "r5 r4" | ids)" "r5 r4 r1 r2 r3"
# the rotation, round by round: a round that reached only the head leaves the tail PLUS the runs it had moved behind (r3 r4 r1 after
# r2 was started from "r2 r3 r4 r1"); the next round must start with r3, not with r1 (which is first in the array)
eq "round 2 order from the file 'r2 r3 r4' → r2 r3 r4 r1"  "$(gate_phase_c_order_deferred_first "$_RUNS" "r2 r3 r4" | jq -c '[.[:4][].id]' | tr -d '[]"' | tr ',' ' ')" "r2 r3 r4 r1"
eq "round 3 order from the file 'r3 r4 r1' → r3 r4 r1 r2 (starts with r3, not with the array's r1)" "$(gate_phase_c_order_deferred_first '[{"id":"r1"},{"id":"r2"},{"id":"r3"},{"id":"r4"}]' "r3 r4 r1" | ids)" "r3 r4 r1 r2"
eq "ids on separate lines / tabs are read too"                     "$(gate_phase_c_order_deferred_first "$_RUNS" "r3
r2	r5" | ids)" "r3 r2 r5 r1 r4"
eq "an id that is no longer running is ignored (nothing invented)" "$(gate_phase_c_order_deferred_first "$_RUNS" "r9 r2" | ids)" "r2 r1 r3 r4 r5"
eq "every id deferred → the same order"                            "$(gate_phase_c_order_deferred_first "$_RUNS" "r1 r2 r3 r4 r5" | ids)" "r1 r2 r3 r4 r5"
eq "nothing deferred ('') → the array untouched, byte for byte"    "$(gate_phase_c_order_deferred_first "$_RUNS" "")" "$_RUNS"
eq "only blanks → untouched"                                       "$(gate_phase_c_order_deferred_first "$_RUNS" "  ")" "$_RUNS"
eq "no second argument → untouched"                                "$(gate_phase_c_order_deferred_first "$_RUNS")" "$_RUNS"
eq "the count is kept (no run lost or doubled)"                    "$(gate_phase_c_order_deferred_first "$_RUNS" "r5 r5 r2" | jq 'length')" "5"
eq "…a repeated id counts once (r5 r5 r2 → r5 r2 r1 r3 r4)"        "$(gate_phase_c_order_deferred_first "$_RUNS" "r5 r5 r2" | ids)" "r5 r2 r1 r3 r4"
eq "an empty array stays an empty array"                           "$(gate_phase_c_order_deferred_first "[]" "r1")" "[]"
# unreadable input is returned as it came — never as an empty list (an empty Phase C would read as "nothing in flight")
for _bad in "garbage" "" "null" '{"id":"r1"}' "[1,2"; do
  eq "unreadable first argument [$_bad] → returned unchanged" "$(gate_phase_c_order_deferred_first "$_bad" "r1")" "$_bad"
done

# ── 3. the deferred-run file ───────────────────────────────────────────────────
echo "── 3. the deferred-run file: read, write, failure ──"
GATE_PHASE_C_DEFERRED_FILE="$ROOT/state/deferred"
: > "$LOGF"
eq "no file → none"                      "$(gate_phase_c_deferred_read)" ""
eq "…and no warning for a missing file"  "$(grep -c 'cannot be read' "$LOGF")" "0"
eq "nothing to record and no file → no file is created" "$(gate_phase_c_deferred_write ""; [ -e "$GATE_PHASE_C_DEFERRED_FILE" ] && echo created || echo none)" "none"
mkdir -p "$ROOT/state"
gate_phase_c_deferred_write "r3 r4"
eq "written, read back"                  "$(gate_phase_c_deferred_read)" "r3 r4"
eq "no temp file is left behind"         "$(ls "$ROOT/state" | tr '\n' ' ')" "deferred "
gate_phase_c_deferred_write "r7"
eq "a later write replaces it"           "$(gate_phase_c_deferred_read)" "r7"
gate_phase_c_deferred_write ""
eq "recording 'none' clears it"          "$(gate_phase_c_deferred_read)" ""
printf 'r1\nr2\t r3\n' > "$GATE_PHASE_C_DEFERRED_FILE"
eq "newlines and tabs read as blanks"    "$(gate_phase_c_deferred_read)" "r1 r2  r3"
# unreadable: a directory where the file should be
rm -f "$GATE_PHASE_C_DEFERRED_FILE"; mkdir "$GATE_PHASE_C_DEFERRED_FILE"
: > "$LOGF"
eq "a directory in its place → none (natural order)" "$(gate_phase_c_deferred_read 2>/dev/null)" ""
eq "…and it is said, not silent"         "$(grep -c 'exists but cannot be read' "$LOGF")" "1"
: > "$LOGF"
gate_phase_c_deferred_write "r1"; _rc=$?
eq "a write that cannot land → rc 0 (the sweep goes on)" "$_rc" "0"
eq "…and says so"                        "$(grep -c 'could not record the deferred run' "$LOGF")" "1"
eq "…and leaves no temp file"            "$(ls "$ROOT/state" | tr '\n' ' ')" "deferred "
rm -rf "$GATE_PHASE_C_DEFERRED_FILE"
GATE_PHASE_C_DEFERRED_FILE="$ROOT/no-such-dir/deferred"
: > "$LOGF"
gate_phase_c_deferred_write "r1"; _rc=$?
eq "a missing state dir → rc 0 and a warning" "$_rc|$(grep -c 'could not record the deferred run' "$LOGF")" "0|1"
GATE_PHASE_C_DEFERRED_FILE=""
eq "no path configured → read is empty"  "$(gate_phase_c_deferred_read)" ""
eq "no path configured → write is a no-op, rc 0" "$(gate_phase_c_deferred_write "r1"; echo $?)" "0"

# ── 4. gate_midsweep_collect: a waiting marker / a spent budget keep the child away ──
echo "── 4. the mid-sweep pass waits for admission ──"
ev_verdict_closed() {   # $1 = run id
  printf '{"seq":1,"type":"bead.closed","ts":"2026-10-29T00:55:00-03:00","actor":"x","subject":"ga-v","payload":{"id":"ga-v","status":"closed","labels":["gate-run:%s","type:quality-gate-verdict"]}}\n' "$1"
}
# probe_midsweep <dispatcher> → one line per scenario, "name|children|bd-reads|defer-lines|pending-after-the-last-call". Runs in its own
# shell: the dispatcher is sourced lib-only ONCE, bd and the child launcher are fakes, and the only thing that varies is the round's state.
SCENARIOS="young waiting waiting-then-free spent off unmeasured garbage-start"
probe_midsweep() {
  (
    export TMPDIR="$ROOT/tmp-probe"; mkdir -p "$TMPDIR"
    GATE_DISPATCHER_LIB_ONLY=1 source "$1" >/dev/null 2>&1 || { echo "SOURCE_FAIL"; exit 0; }
    set +e
    GC_CITY="$ROOT/city-probe"; mkdir -p "$GC_CITY/scripts" "$GATE_LOCK_DIR"
    for SC in $SCENARIOS; do
      F="$ROOT/probe-$SC"; rm -rf "$F"; mkdir -p "$F"; : > "$F/reads"; : > "$F/log"
      log()  { printf '%s\n' "$*" >> "$F/log"; }
      warn() { printf 'WARN %s\n' "$*" >> "$F/log"; }
      bd() { echo x >> "$F/reads"; case "$*" in *gate-status:running*) echo '[{"id":"r1"}]' ;; *) echo '[]' ;; esac; }
      CHILD_N=0
      _gate_run_phase_c_child() { CHILD_N=$((CHILD_N+1)); return 0; }
      GATE_EVENTS_FILE="$F/events.jsonl"; : > "$GATE_EVENTS_FILE"
      GATE_LOCK_ENABLED=1; GATE_MIDSWEEP_ENABLED=1; GATE_PHASE_C_ONLY=0; GATE_PHASE_C_ENABLED=1
      GATE_PREADMIT_BUDGET_SECS=150; GATE_ADMISSION_WAITING=0; GATE_ROUND_T0=$(date +%s)
      case "$SC" in
        young) ;;
        waiting|waiting-then-free) GATE_ADMISSION_WAITING=1 ;;
        spent) GATE_ROUND_T0=$(( $(date +%s) - 400 )) ;;
        off) GATE_PREADMIT_BUDGET_SECS=0; GATE_ADMISSION_WAITING=1; GATE_ROUND_T0=$(( $(date +%s) - 400 )) ;;
        unmeasured) GATE_ROUND_T0="" ;;
        garbage-start) GATE_ROUND_T0="soon" ;;
      esac
      gate_midsweep_arm
      ev_verdict_closed r1 >> "$GATE_EVENTS_FILE"
      gate_midsweep_collect "p1"
      gate_midsweep_collect "p2"
      if [ "$SC" = "waiting-then-free" ]; then GATE_ADMISSION_WAITING=0; gate_midsweep_collect "p3"; fi
      echo "$SC|$CHILD_N|$(wc -l < "$F/reads" | tr -d ' ')|$(grep -c 'NOT collecting now' "$F/log")|${GATE_MIDSWEEP_PENDING:+pending}"
    done
  )
}
PM_REAL="$(probe_midsweep "$DISPATCHER")"
pm() { printf '%s\n' "$1" | grep "^$2|" | head -1 | cut -d'|' -f2-; }   # pm <probe-output> <scenario>
eq "control: a young round, nothing waiting → the child starts once (2 confirming reads)" "$(pm "$PM_REAL" young)" "1|2|0|"
eq "a marker is waiting → NO child, NO bd read, the candidate is kept, said once for two safe points" "$(pm "$PM_REAL" waiting)" "0|0|1|pending"
eq "…and when the marker has been admitted (not waiting any more) the kept candidate is collected, not lost" "$(pm "$PM_REAL" waiting-then-free)" "1|2|1|"
eq "the round spent its budget → NO child, the candidate is kept" "$(pm "$PM_REAL" spent)" "0|0|1|pending"
eq "budget 0 (the kill switch) → the old behaviour: the child starts although a marker waits and the budget is long spent" "$(pm "$PM_REAL" off)" "1|2|0|"
eq "round start unknown (lib-only / a clock that could not be read) → no deferral" "$(pm "$PM_REAL" unmeasured)" "1|2|0|"
eq "round start not a number → no deferral" "$(pm "$PM_REAL" garbage-start)" "1|2|0|"
case "$(cat "$ROOT/probe-spent/log")" in
  *"this round already spent its 150s pre-admission budget"*"next round's Phase C does (ga-yjrg7n6)"*) ok "the log line says why and who collects instead" ;;
  *) bad "the deferral line does not say why / who collects: $(cat "$ROOT/probe-spent/log")" ;;
esac
case "$(cat "$ROOT/probe-waiting/log")" in *"a queued marker is waiting for admission"*) ok "…and for a waiting marker, that reason" ;; *) bad "no 'queued marker is waiting' reason" ;; esac

# ── 5. the real dispatcher as a real process ───────────────────────────────────
echo "── 5. Phase C, as a real process: four in-flight runs, 3 s to check each, a 5 s budget (the preamble of a real sweep is ~2 s of it) ──"
CITY2="$ROOT/city2"; A2="$CITY2/packs/town-deltas/assets"
mkdir -p "$A2" "$CITY2/.gc/logs" "$ROOT/fakebin" "$ROOT/tmp5"
ln -s "$REPO_ROOT/scripts" "$CITY2/scripts"
ln -s "$REPO_ROOT/agents" "$CITY2/agents"
for _f in "$SELF_DIR"/*; do
  _b="$(basename "$_f")"
  case "$_b" in quality-gate-dispatcher.sh) continue ;; esac
  if [ -f "$_f" ] && grep -q '^GC_CITY="/Users/athos/gt/.gascity-gastown-hq"' "$_f" 2>/dev/null; then
    sed "s|^GC_CITY=\"/Users/athos/gt/.gascity-gastown-hq\"|GC_CITY=\"$CITY2\"|" "$_f" > "$A2/$_b"
  else
    ln -s "$_f" "$A2/$_b"
  fi
done
stage_dispatcher() {   # stage_dispatcher <file> <name> → path of that file aimed at the scratch city (the real city is never run)
  sed "s|^GC_CITY=.*|GC_CITY=\"$CITY2\"|" "$1" > "$A2/$2"
  echo "$A2/$2"
}
STAGED="$(stage_dispatcher "$DISPATCHER" quality-gate-dispatcher.sh)"
# fakes: no bd/gc call may reach the real city. Four runs are "running", each with every field Phase C requires; the rig they name does
# not exist, so each run costs exactly one `gc rig list` (3 s here) and ends in "could not resolve rig context" — a per-run line
# that says which runs were reached, in what order.
cat > "$ROOT/fakebin/bd" <<'FAKEBD'
#!/bin/bash
case "$*" in
  *gate-status:running*)
    for i in 1 2 3 4; do
      d="source_bead: b$i\nauthor: x\nrig: norig\nbranch: br$i\ntier: code\nrequired_reviewers: 1\nbranch_sha: abc\nmarker_id: m$i\nstarted_at: 2026-10-29T00:00:00Z\nverdict_timeout_minutes: 22"
      s="${s:+$s,}{\"id\":\"r$i\",\"title\":\"gate-run: br$i (b$i)\",\"description\":\"$d\"}"
    done
    echo "[$s]" ;;
  *"--json"*) echo "[]" ;;
esac
exit 0
FAKEBD
cat > "$ROOT/fakebin/gc" <<'FAKEGC'
#!/bin/bash
case "$*" in *"rig list"*) sleep 3; echo '{"rigs":[]}' ;; esac
exit 0
FAKEGC
chmod +x "$ROOT/fakebin/bd" "$ROOT/fakebin/gc"
LOG2="$CITY2/.gc/logs/quality-gate-dispatcher.log"
DEFERRED2="$CITY2/.gc/gate-phase-c-deferred"
sweep() {   # sweep <script> <budget> [child-runs] → runs one sweep (or, with child-runs, a Phase-C-only child of THIS shell); leaves the log in $LOG2
  : > "$LOG2"
  local _script="$1" _budget="$2" _child="${3:-}" p n=0
  if [ -n "$_child" ]; then
    printf '%s\n' "$$:tok" > "$LOCK2/heartbeat"
    PATH="$ROOT/fakebin:$PATH" TMPDIR="$ROOT/tmp5" GC_CITY="$CITY2" BD_CACHE_OFF=1 BD_CACHE_DIR="$ROOT/cache5" DRAIN_WINDOW_OVERRIDE="OPEN" \
      GATE_PREADMIT_BUDGET_SECS="$_budget" GATE_PHASE_C_ONLY=1 GATE_PHASE_C_ONLY_RUNS="$_child" GATE_LOCK_BORROW_TOKEN="$$:tok" \
      bash "$_script" >/dev/null 2>&1 &
  else
    PATH="$ROOT/fakebin:$PATH" TMPDIR="$ROOT/tmp5" GC_CITY="$CITY2" BD_CACHE_OFF=1 BD_CACHE_DIR="$ROOT/cache5" DRAIN_WINDOW_OVERRIDE="OPEN" \
      GATE_PREADMIT_BUDGET_SECS="$_budget" bash "$_script" >/dev/null 2>&1 &
  fi
  p=$!
  while kill -0 "$p" 2>/dev/null && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n+1)); done   # 2 min watchdog
  if kill -0 "$p" 2>/dev/null; then kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; return 124; fi
  wait "$p"
}
LOCK2="$ROOT/tmp5/quality-gate-dispatcher$(printf '%s' "$CITY2" | tr '/ ' '__').lock.d"
reached() {   # the runs the last sweep started, in order: "r1 r2"
  grep -o 'gate-run r[0-9] — could not resolve rig context' "$LOG2" | sed 's/gate-run \(r[0-9]\) .*/\1/' | tr '\n' ' ' | sed 's/ $//'
}
n_words() { printf '%s' "$1" | wc -w | tr -d ' '; }

# ROUND 1: budget 5 s, 3 s per run → it starts one run, or two if the preamble was quick; never all four.
rm -f "$CITY2/.gc/gate-phase-c-deferred"
sweep "$STAGED" 5; _rc=$?
R1="$(reached)"
eq "round 1 ends normally" "$_rc" "0"
[ "$(n_words "$R1")" -ge 1 ] && ok "round 1 started at least one run (a round never makes zero progress): [$R1]" || bad "round 1 started no run: [$R1]"
[ "$(n_words "$R1")" -le 3 ] && ok "round 1 did NOT check all four in-flight runs (the budget stopped it): [$R1]" || bad "round 1 checked every in-flight run although the budget was 5 s: [$R1]"
D1="$(cat "$DEFERRED2" 2>/dev/null | tr -d '\n')"
eq "the runs it started plus the runs it wrote down are the four, each once" "$(printf '%s %s' "$R1" "$D1" | tr ' ' '\n' | grep '^r' | sort -u | wc -l | tr -d ' ')|$(n_words "$R1")+$(n_words "$D1")" "4|$(n_words "$R1")+$(n_words "$D1")"
eq "…and they add up (nothing started AND deferred, nothing in neither)" "$(( $(n_words "$R1") + $(n_words "$D1") ))" "4"
case "$(cat "$LOG2")" in *"pre-admission budget of 5s spent after"*"left for the next round, which checks them first: $D1 (ga-yjrg7n6)"*) ok "the log says the budget was spent and which runs wait" ;; *) bad "no 'budget spent … left for the next round: $D1' line" ;; esac
case "$(cat "$LOG2")" in *"Pre-admission: reached admission"*"Phase C left $D1 for the next round"*|*"No queued markers. Exiting."*) ok "the round ends or reaches admission (nothing is queued in the scratch city)" ;; *) bad "round 1 did not reach the end of Step 0b" ;; esac

# FURTHER ROUNDS: the deferred runs go first, so the rounds walk the whole list instead of re-checking the head of it
PREV_D="$D1"; COVER="$R1"; ROUNDS=1; FIRST_OK=1
while [ "$ROUNDS" -lt 5 ] && [ "$(printf '%s' "$COVER" | tr ' ' '\n' | sort -u | grep -c '^r')" -lt 4 ]; do
  sweep "$STAGED" 5; _rc=$?; ROUNDS=$((ROUNDS+1))
  RN="$(reached)"
  [ "$_rc" = "0" ] || bad "round $ROUNDS did not end normally (rc=$_rc)"
  [ "$(printf '%s' "$RN" | awk '{print $1}')" = "$(printf '%s' "$PREV_D" | awk '{print $1}')" ] \
    || { FIRST_OK=0; bad "round $ROUNDS started with [$(printf '%s' "$RN" | awk '{print $1}')], not with the run the round before left unchecked [$(printf '%s' "$PREV_D" | awk '{print $1}')]"; }
  COVER="$COVER $RN"
  PREV_D="$(cat "$DEFERRED2" 2>/dev/null | tr -d '\n')"
done
[ "$FIRST_OK" = "1" ] && ok "every later round started with the run the round before left unchecked"
eq "…and the rounds covered all four runs within four rounds (none is starved behind the head of the list)" "$(printf '%s' "$COVER" | tr ' ' '\n' | sort -u | grep '^r' | tr '\n' ' ' | sed 's/ $//')" "r1 r2 r3 r4"
[ "$ROUNDS" -le 4 ] && ok "…in $ROUNDS round(s)" || bad "it took $ROUNDS rounds to cover four runs"

# CONTROL: budget 0 is the old behaviour
rm -f "$CITY2/.gc/gate-phase-c-deferred"
sweep "$STAGED" 0; _rc=$?
eq "budget 0: one round checks all four in-flight runs (the old behaviour)" "$(reached)" "r1 r2 r3 r4"
eq "…and writes no deferred file" "$([ -e "$DEFERRED2" ] && echo exists || echo none)" "none"
case "$(cat "$LOG2")" in *"pre-admission budget of"*) bad "budget 0 still logged a budget line" ;; *) ok "…and logs no budget line" ;; esac

# THE CHILD: handed exactly the runs to collect, it does not stop for the budget and does not reorder
mkdir -p "$LOCK2"
sweep "$STAGED" 1 "r4 r2"; _rc=$?
eq "a Phase-C-only child with a 1 s budget still reaches BOTH runs it was handed" "$(reached)" "r2 r4"
eq "…and exits 0" "$_rc" "0"
case "$(cat "$LOG2")" in *"pre-admission budget of"*) bad "the child applied the budget" ;; *) ok "…without a budget line" ;; esac
rm -rf "$LOCK2"

# ── 6. the checks have teeth ───────────────────────────────────────────────────
echo "── 6. mutants ──"
mutant_sub() {   # mutant_sub <name> <from> <to> → path of the dispatcher with exactly one occurrence of <from> replaced by <to> ("" if not exactly one)
  local out="$ROOT/mutant-$1.sh"
  MS_FROM="$2" MS_TO="$3" awk '{ i = index($0, ENVIRON["MS_FROM"]); if (i > 0) { $0 = substr($0, 1, i - 1) ENVIRON["MS_TO"] substr($0, i + length(ENVIRON["MS_FROM"])); n++ } print } END { exit (n == 1 ? 0 : 3) }' "$DISPATCHER" > "$out" \
    && echo "$out" || echo ""
}
M="$(mutant_sub nodefer 'if gate_preadmit_defer_midsweep; then' 'if false; then')"
if [ -n "$M" ]; then
  PM_MUT="$(probe_midsweep "$M")"
  eq "mutant: gate_midsweep_collect never defers → the child starts although a marker waits (the check goes red)" "$(pm "$PM_MUT" waiting)" "1|2|0|"
  eq "…and when the budget is spent" "$(pm "$PM_MUT" spent)" "1|2|0|"
else bad "mutant nodefer: the anchor line is not there exactly once"; fi
M="$(mutant_sub nobreak '&& gate_preadmit_budget_spent' '&& false && gate_preadmit_budget_spent')"
if [ -n "$M" ]; then
  MS="$(stage_dispatcher "$M" mutant-nobreak.sh)"
  rm -f "$CITY2/.gc/gate-phase-c-deferred"
  sweep "$MS" 5
  eq "mutant: a Phase C whose budget never fires checks all four runs again (the check goes red)" "$(reached)" "r1 r2 r3 r4"
else bad "mutant nobreak: the anchor line is not there exactly once"; fi
rm -f "$DEFERRED2"

# wiring that no run of the scratch city reaches (nothing is queued there): the round start is stamped at the banner, the waiting flag
# is raised after "Found N" and before the first safe point that can start a child with a marker waiting.
_ln() { grep -n -F -- "$1" "$DISPATCHER" | head -1 | cut -d: -f1; }
_L_T0="$(_ln 'GATE_ROUND_T0=$(date +%s)')"; _L_BAN="$(_ln 'log "=== Dispatcher sweep start')"
_L_FOUND="$(_ln 'log "Found $COUNT queued marker(s)"')"; _L_WAIT="$(_ln 'GATE_ADMISSION_WAITING=1')"; _L_SP="$(_ln 'gate_midsweep_collect "step-0b-1"')"
[ -n "$_L_T0" ] && [ -n "$_L_BAN" ] && [ "$_L_T0" -gt "$_L_BAN" ] && [ "$_L_T0" -lt "$((_L_BAN + 6))" ] \
  && ok "the round clock is stamped right after the sweep banner" || bad "GATE_ROUND_T0 is not set right after the sweep banner ($_L_BAN / $_L_T0)"
[ -n "$_L_FOUND" ] && [ -n "$_L_WAIT" ] && [ -n "$_L_SP" ] && [ "$_L_WAIT" -gt "$_L_FOUND" ] && [ "$_L_WAIT" -lt "$_L_SP" ] \
  && ok "the waiting flag is raised after 'Found N queued marker(s)' and before the first safe point that follows it" \
  || bad "GATE_ADMISSION_WAITING=1 is not between the Found line and step-0b-1 ($_L_FOUND / $_L_WAIT / $_L_SP)"
grep -qF 'Pre-admission: reached admission' "$DISPATCHER" && ok "the measurement line exists (seconds from the banner to admission)" || bad "no 'Pre-admission: reached admission' line"

echo
echo "gate-yjrg7n6-preadmit-budget: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

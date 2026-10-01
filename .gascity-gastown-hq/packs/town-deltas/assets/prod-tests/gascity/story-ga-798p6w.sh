#!/usr/bin/env bash
# prod-tests/gascity/story-ga-798p6w.sh — prod test for ga-798p6w (E9 of the P0 ga-ufskhy): the refiner/builder-start PLANNER and a
# complexity level, as an A/B that ships INERT.
#
# What "deployed and correct" means for an experiment that must not change anything until the Mayor turns it on:
#   (1) the pieces are on disk in the LIVE tree and parse;
#   (2) with no conf the experiment is provably OFF: no arm printed, no roster row, no spend — the property every other dispatch
#       relies on, so it is the one worth checking after a deploy;
#   (3) the arm is the documented, recomputable function of the bead id (checked here by an independent SHA-256, not by the script
#       agreeing with itself);
#   (4) the kill switch beats an active conf;
#   (5) the complexity scale is computed from facts and REFUSES what it cannot size;
#   (6) the Pilot's dispatch hook is in the deployed dispatcher;
#   (7) the readout refuses to invent when there is nothing to read.
# Everything runs against a scratch E9_STATE_DIR: it never reads or writes the live .gc/e9-roster.jsonl, calls no API and spends nothing
# (e9-plan.sh returns before it reaches claude in every case checked here). Whether the LIVE city is switched on is reported, never
# asserted: turning it on is the Mayor's decision and either state is a valid deploy.
#
# Called by run.sh after deploy (STORY_ID=ga-798p6w). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
ARMS="$ASSETS/e9-arms.sh"
PLAN="$ASSETS/e9-plan.sh"
DISPATCHER="$ASSETS/pilot-dispatcher.sh"
APUR="$CITY/scripts/e9-apuracao.py"
DOC="$CITY/docs/e9-planner-complexity.md"

log()  { echo "[prod-test:gascity ga-798p6w] $*"; }
fail() { echo "[prod-test:gascity ga-798p6w] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────────────────────
for f in "$ARMS" "$PLAN" "$DISPATCHER" "$APUR" "$DOC"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
done
for f in "$ARMS" "$PLAN" "$DISPATCHER"; do
  bash -n "$f" || fail "does not parse under bash: $f"
done
python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$APUR" || fail "does not parse under python3: $APUR"
log "e9-arms.sh, e9-plan.sh, pilot-dispatcher.sh, e9-apuracao.py and the doc are deployed and parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-798p6w.XXXXXX")" || fail "no scratch dir"
trap 'rm -rf "$S"' EXIT
export E9_STATE_DIR="$S"

# ── 2. with no conf the experiment is OFF, provably ───────────────────────────────────────────────────────────
st="$(bash "$ARMS" state)" || fail "e9-arms.sh state failed"
[[ "$st" == absent ]] || fail "no conf must read 'absent', got '$st'"
out="$(bash "$ARMS" assign ga-prodtest "$CITY" prod-test)" || fail "assign with no conf must exit 0"
[[ -z "$out" ]] || fail "assign with no conf must print NOTHING, got '$out'"
[[ ! -e "$S/e9-roster.jsonl" ]] || fail "assign with no conf wrote a roster row — an absent experiment records nothing"
res="$(bash "$PLAN" run ga-prodtest --store "$CITY")"; rc=$?
[[ "$rc" -eq 0 ]] || fail "e9-plan.sh run with no conf must exit 0 (INERT), got rc=$rc"
case "$res" in *"E9_PLAN_RESULT arm=- verdict=INERT reason=absent "*) ;; *) fail "e9-plan.sh run with no conf must say INERT/absent, got: $res" ;; esac
[[ ! -e "$S/e9-roster.jsonl" ]] || fail "e9-plan.sh run with no conf wrote a roster row"
log "no conf → state=absent, assign prints nothing, plan run is INERT, no roster row ✓"

# ── 3. the arm is the documented function of the bead id (independent recomputation) ─────────────────────────────
printf 'planner_pct=50\nsalt=e9a\n' > "$S/e9-ab.conf"
[[ "$(bash "$ARMS" state)" == "active planner_pct=50 complexity=off salt=e9a" ]] || fail "active conf misread: $(bash "$ARMS" state)"
n_on=0; n_off=0
for id in ga-t1 ga-t2 ga-t3 ga-t4 ga-t5 ga-t6; do
  d="$(printf '%s' "e9-planner:e9a:$id" | shasum -a 256 | cut -c1-8)"
  want=off; [[ $(( 16#$d % 100 )) -lt 50 ]] && want=on
  got="$(bash "$ARMS" arm planner "$id")" || fail "arm planner $id failed"
  [[ "$got" == "$want" ]] || fail "arm for $id is '$got' but SHA-256(e9-planner:e9a:$id) mod 100 says '$want' — the deployed rule is not the documented one"
  [[ "$want" == on ]] && n_on=$((n_on+1)) || n_off=$((n_off+1))
done
[[ "$n_on" -ge 1 && "$n_off" -ge 1 ]] || fail "six sample ids all landed in one arm (on=$n_on off=$n_off): the check cannot tell the arms apart"
log "arm = SHA-256(\"e9-planner:e9a:<id>\") mod 100 < planner_pct, recomputed independently for 6 ids (on=$n_on off=$n_off) ✓"

# ── 4. the kill switch beats an active conf; a malformed conf is its own state ───────────────────────────────────
: > "$S/no-e9-ab"
[[ "$(bash "$ARMS" state)" == killed ]] || fail "kill switch not honoured: $(bash "$ARMS" state)"
res="$(bash "$PLAN" run ga-t1 --store "$CITY")"; rc=$?
[[ "$rc" -eq 0 ]] && case "$res" in *"verdict=INERT reason=killed "*) true ;; *) false ;; esac || fail "plan run under the kill switch must be INERT/killed (rc=$rc): $res"
rm -f "$S/no-e9-ab"
printf 'planner_pct=abc\n' > "$S/e9-ab.conf"
case "$(bash "$ARMS" state)" in invalid:*) ;; *) fail "a malformed conf must read invalid:*, got '$(bash "$ARMS" state)'" ;; esac
# the Pilot drops assign's stderr and logs only a non-zero exit: an invalid conf must not answer like "no conf" (exit 0, silent) or a typo
# at turn-on runs the experiment at 0% with nobody told (gate ga-shag3i, blocking issue 2)
rc=0; out="$(bash "$ARMS" assign ga-prodtest "$CITY" prod-test 2>/dev/null)" || rc=$?
[[ "$rc" -eq 6 && -z "$out" ]] || fail "assign under a malformed conf must print nothing and exit 6, got rc=$rc out='$out'"
[[ ! -e "$S/e9-roster.jsonl" ]] || fail "the kill-switch / malformed-conf checks wrote a roster row"
log "kill switch → killed/INERT; malformed conf → invalid (not 'no conf'), assign exits 6, nothing recorded ✓"

# ── 5. the complexity scale: computed from facts, refuses what it cannot size ────────────────────────────────────
declare -a CASES=("1 1 0 0:S" "2 1 0 0:S" "3 1 0 0:M" "2 2 0 0:M" "1 3 0 0:L" "8 1 0 0:L" "1 1 1 0:L" "1 1 0 1:L")
for c in "${CASES[@]}"; do
  args="${c%%:*}"; want="${c##*:}"
  # shellcheck disable=SC2086
  got="$(bash "$ARMS" complexity $args)" || fail "complexity $args failed"
  [[ "$got" == "$want" ]] || fail "complexity $args = '$got', the scale says '$want'"
done
for bad in "0 1 0 0" "1 0 0 0" "1 1 2 0" "x 1 0 0" "1 1 0"; do
  # shellcheck disable=SC2086
  if bash "$ARMS" complexity $bad >/dev/null 2>&1; then fail "complexity '$bad' must be REFUSED (exit 2), it printed a level"; fi
done
log "complexity: 8 sized cases match the scale; 5 unsizable inputs are refused, none defaulted to S ✓"

# ── 6. the Pilot's hook is in the deployed dispatcher ─────────────────────────────────────────────────────────────
grep -q '^_e9_dispatch_line() {' "$DISPATCHER" || fail "_e9_dispatch_line() missing from the deployed pilot-dispatcher.sh"
grep -q '_e9_dispatch_line "\$STORY_ID" "\$STORY_BEAD_CITY"' "$DISPATCHER" || fail "the call site of _e9_dispatch_line is missing from the deployed dispatch_one()"
log "pilot-dispatcher.sh carries the E9 hook and its call site ✓"

# ── 7. the readout refuses to invent ──────────────────────────────────────────────────────────────────────────────
mkdir -p "$S/hq/.gc"
ro="$(python3 "$APUR" --hq "$S/hq" 2>&1)"; rc=$?
[[ "$rc" -eq 2 ]] || fail "the readout with no roster must exit 2, got rc=$rc: $ro"
case "$ro" in *"NADA foi apurado"*) ;; *) fail "the readout with no roster must say 'NADA foi apurado', got: $ro" ;; esac
log "readout with no roster → exit 2, \"NADA foi apurado\" (no empty report passed off as a result) ✓"

# ── informational: is the LIVE city switched on? (never a failure — that is the Mayor's call) ─────────────────────
unset E9_STATE_DIR
live="$(E9_STATE_DIR="$CITY/.gc" bash "$ARMS" state 2>/dev/null)" || live="unreadable"
log "live city experiment state: $live (informational)"

log "PASS"
exit 0

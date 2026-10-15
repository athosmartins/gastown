#!/usr/bin/env bash
# prod-tests/gascity/story-ga-dzzqvw.1.sh — prod test for ga-dzzqvw.1 (slice 2/2 of the gate's "task-rapida" lane): the weekly tally counts the lane
# (how many, why not, first review, time, bugs opened after). Verifies the DEPLOYED tally: it compiles, it reads the LIVE log (exit 2 would be
# 'could not read', never '0'), its JSON carries the lane's numbers, its code list is the lane lib's list, and its own selftest passes end to end
# (the lane's selftest is slice 1's prod test).
# Called by run.sh after deploy (STORY_ID=ga-dzzqvw.1). Exits 0 on pass.
set -uo pipefail
CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"; A="$CITY/packs/town-deltas/assets"; TALLY="$A/gate-lane-tally.py"; B32=/bin/bash
log()  { echo "[prod-test:gascity ga-dzzqvw.1] $*"; }
fail() { echo "[prod-test:gascity ga-dzzqvw.1] FAIL: $*" >&2; exit 1; }
for f in "$TALLY" "$A/gate-lane-tally.selftest.sh" "$A/gate-taskrapida.lib.sh" "$A/gate-taskrapida.selftest.sh"; do [[ -f "$f" ]] || fail "missing: $f"; done
python3 -m py_compile "$TALLY" || fail "gate-lane-tally.py does not compile"
J=$(python3 "$TALLY" --days 7 --json) || fail "the tally could not read the live log (exit $?)"
printf '%s' "$J" | python3 -c "import sys,json; d=json.load(sys.stdin); [d[k] for k in ('tr_granted','tr_refused','tr_refusals','tr_first_pass','tr_first_fail','tr_elapsed_median_s','tr_bugs_after','tr_stores','tr_bugs_uncovered','tr_grant_rigs','tr_ended_no_verdict')]; assert d['unreadable_lines']==0" \
  || fail "the tally's JSON on the live log lacks the task-rapida numbers, or counts unreadable lines (look at them before the weekly warns on every run): $J"
# the bugs-after number is only a number when it looked where the answer lives (gate_run ga-lkohfb): a number means no grant was left un-looked-up and a store was
# read for every rig the grants came from; a null says how many were not. A transient bd failure under load is a null WITH its count (not a failure of this test).
printf '%s' "$J" | python3 -c "
import sys, json
d = json.load(sys.stdin)
assert (d['tr_bugs_after'] is None) == (d['tr_bugs_uncovered'] > 0), 'bugs-after and its coverage disagree'
if d['tr_bugs_after'] is not None:
    assert len(d['tr_stores']) >= len(d['tr_grant_rigs']), 'a bug count that did not read one store per rig of the grants'
" || fail "the tally's bugs-after number does not account for the stores the lane's tasks live in: $J"
LIB_CODES=$("$B32" -c 'source "$1"; gate_taskrapida_codes | cut -f1' _ "$A/gate-taskrapida.lib.sh" 2>/dev/null | sort) || LIB_CODES=""
TALLY_CODES=$(python3 "$TALLY" --list-tr-codes | cut -f1 | sort)
[[ -n "$LIB_CODES" && "$LIB_CODES" = "$TALLY_CODES" ]] || fail "the tally's task-rapida codes are not the lane lib's (lib: $(echo $LIB_CODES | wc -w), tally: $(echo $TALLY_CODES | wc -w))"
OUT=$("$B32" "$A/gate-lane-tally.selftest.sh" 2>&1) || fail "gate-lane-tally.selftest.sh failed: $(printf '%s' "$OUT" | grep '✗' | head -5 | tr '\n' ' ')"
log "PASS"

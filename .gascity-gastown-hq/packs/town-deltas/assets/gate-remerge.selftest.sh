#!/usr/bin/env bash
# gate-remerge.selftest.sh (ga-mzw9dt) — the LIB's own tests (the dispatcher wiring has gate-remerge-wiring.selftest.sh).
#
# Proves the decision behind "remerge sem nova revisão": content the reviewers APPROVED that failed only at the merge (push race,
# merge-time rebase, merge-time conflict) is merged on resubmission WITHOUT a new full review, and everything else, from one changed
# line to a label nobody can read, still gets the normal gate. Executed, not described:
#   1. the approval label: shape, newest wins, malformed is "could not tell";
#   2. gate_remerge_decide against REAL git history in a temp repo (git merge-tree): the tip IS the approved commit; its clean rebase
#      onto a main that moved; one line added; the SAME line at ANOTHER position (what a rebase-stable digest cannot tell apart); the
#      approved commit conflicting with main (and the author's hand-made resolution); an approved commit git no longer has; an
#      approval expired / future / malformed / absent / not on the dispatcher's record; the kill switch; failing, unrunnable or too many
#      directed tests; an unreadable clock; git that errors. Each ends in the normal gate with a stable code, and only the first two grant;
#   3. gate_remerge_confirm (the push-time re-ask) on the same repo;
#   4. stamp / unstamp / record with a stateful fake `bd`: labels are READ BACK, the dispatcher's own record is written first, an old
#      approval is superseded, a failed write is reported, gate.remerge is 1 on a grant and 0 on a revocation.
# Exit 0 iff every assertion holds.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-remerge.fixture.lib.sh" || { echo "FATAL: cannot source the fixture lib"; exit 2; }

echo "── 1. the approval label ──"
GATE_REMERGE_LABEL_PREFIX_CHECK=""
# shellcheck disable=SC1090
( source "$RMLIB" ) >/dev/null 2>&1 || { bad "gate-remerge.lib.sh does not source cleanly"; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }
# shellcheck disable=SC1090
source "$RMLIB"
source "$RMLIB"
eq "label shape" "$(gate_remerge_label "$S40" 1700000000)" "gate-approved:$S40:1700000000"
gate_remerge_parse_labels "story:approved gate-approved:$S40:1700000000 gate:needs-fix"; rc=$?
eq "a well-formed approval is found" "$rc|$GATE_RM_SHA|$GATE_RM_EPOCH" "0|$S40|1700000000"
gate_remerge_parse_labels "gate-approved:$S40:100 gate-approved:$S64:300 gate-approved:$S40:200"; rc=$?
eq "the NEWEST approval wins (a 64-hex sha is a sha too)" "$rc|$GATE_RM_SHA|$GATE_RM_EPOCH" "0|$S64|300"
gate_remerge_parse_labels "story:approved gate:needs-fix"; rc=$?
eq "no approval label at all → 1" "$rc" "1"
gate_remerge_parse_labels ""; rc=$?
eq "no labels at all → 1" "$rc" "1"
gate_remerge_parse_labels "gate-approved:zzzz:100"; rc=$?
eq "an approval label with a non-hex sha → 2 (could not tell)" "$rc" "2"
gate_remerge_parse_labels "gate-approved:abc123:100"; rc=$?
eq "a short sha → 2" "$rc" "2"
gate_remerge_parse_labels "gate-approved:$S40:12x4"; rc=$?
eq "a non-numeric epoch → 2" "$rc" "2"
gate_remerge_parse_labels "gate-approved:$S40"; rc=$?
eq "no epoch → 2" "$rc" "2"
gate_remerge_parse_labels "gate-approved:$S40:100:extra"; rc=$?
eq "a trailing field → 2" "$rc" "2"
gate_remerge_parse_labels "gate-approved:zzzz:100 gate-approved:$S40:50"; rc=$?
eq "a bad label beside a good one: the good one is used" "$rc|$GATE_RM_EPOCH" "0|50"

echo "── 2. gate_remerge_decide against REAL git (git merge-tree: the three-way merge a rebase uses) ──"
# dec <name> <main_ref> <head> <labels> <now> <want_flag> <want_code> [VAR=val ...]
dec() {
  local name="$1" main="$2" head="$3" labels="$4" now="$5" wantg="$6" wantc="$7" out got
  shift 7
  case " $* " in *" DEC_NOLOG=1 "*) : ;; *) mklog "$labels" ;; esac   # DEC_NOLOG=1: the caller prepared $QG_FIX (a label added by hand)
  out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$@" "$B32" -c '
set -euo pipefail
git_rig() { git -C "$RM_REPO" "$@"; }
log(){ :; }; warn(){ :; }; err(){ :; }
source "$1"; source "$2"
gate_remerge_decide git_rig "$3" "$4" "$5" "$6" "$7" || true
printf "\nRESULT\t%s\t%s\t%s\n" "$GATE_REMERGE" "$GATE_REMERGE_CODE" "$GATE_REMERGE_WHY"' _ "$FLLIB" "$RMLIB" "$main" "$head" "$labels" "$now" "$QG_FIX" 2>&1) || true
  got=$(printf '%s\n' "$out" | grep -a '^RESULT' | tail -1)
  DEC_WHY=$(printf '%s' "$got" | cut -f4-)
  if [ "$(printf '%s' "$got" | cut -f2,3 | tr '\t' '|')" = "$wantg|$wantc" ]; then ok "$name → $wantg ($wantc)"; else bad "$name → expected $wantg|$wantc, got [$(printf '%s' "$got" | cut -f2,3 | tr '\t' '|')] out=[$(printf '%s' "$out" | tail -3)]"; fi
}

dec "the tip IS the approved commit (main moved on)"        "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 1 granted-exact
has "…and the reason says what was compared and what ran"   "$DEC_WHY" "directed tests: 1 test file(s) exited 0"
mklog ""
dec "a label added BY HAND: nothing on the dispatcher's log → the normal gate (not a grant)" "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 0 approval-unverified DEC_NOLOG=1
has "…and the reason says a label alone is not proof"        "$DEC_WHY" "no matching gate_approval record"
mklog "$(lbl "$AR" "$FRESH")"
dec "the log holds an approval of ANOTHER commit → still unverified"  "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 0 approval-unverified DEC_NOLOG=1
mklog "$(lbl "$A" $((FRESH - 5)))"
dec "…or of the same commit stamped at ANOTHER time"              "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 0 approval-unverified DEC_NOLOG=1
dec "…while the record of exactly this approval grants (control)"   "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 1 granted-exact
dec "the tip is the clean REBASE of the approved commit"    "$M1" "$AR" "$(lbl "$A" "$FRESH")" "$NOW" 1 granted-rebase
has "…and says it lands exactly what the approved commit lands" "$DEC_WHY" "lands exactly what the approved commit"
dec "labels carry other labels too"                          "$M1" "$AR" "story:approved gate:needs-fix $(lbl "$A" "$FRESH") park:x" "$NOW" 1 granted-rebase
dec "one more line on top of the approved commit"            "$M1" "$AP" "$(lbl "$A" "$FRESH")" "$NOW" 0 content-changed
dec "the SAME added line at ANOTHER position (a -U0 digest cannot tell these apart)" "$M0" "$P2" "$(lbl "$P1" "$FRESH")" "$NOW" 0 content-changed
dec "…and the identical commit is still a grant (control)"   "$M0" "$P1" "$(lbl "$P1" "$FRESH")" "$NOW" 1 granted-exact
dec "the approved commit CONFLICTS with main (a real conflict)" "$M2" "$A"   "$(lbl "$A" "$FRESH")" "$NOW" 0 real-conflict
dec "…and the author's hand-made resolution is NOT the approved content" "$M2" "$RES" "$(lbl "$A" "$FRESH")" "$NOW" 0 real-conflict
dec "an approved commit git no longer has"                   "$M1" "$AR" "$(lbl cccccccccccccccccccccccccccccccccccccccc "$FRESH")" "$NOW" 0 object-missing
dec "an approval older than its limit (8 days)"              "$M1" "$A"  "$(lbl "$A" "$((NOW - 8*86400))")" "$NOW" 0 expired
dec "…but 6 days old is still good (control)"                "$M1" "$A"  "$(lbl "$A" "$((NOW - 6*86400))")" "$NOW" 1 granted-exact
dec "a limit set by the operator is honored"                 "$M1" "$A"  "$(lbl "$A" "$((NOW - 400))")" "$NOW" 0 expired GATE_REMERGE_TTL_SECS=300
dec "a garbage limit falls back to the default, never to 0"  "$M1" "$A"  "$(lbl "$A" "$((NOW - 400))")" "$NOW" 1 granted-exact GATE_REMERGE_TTL_SECS=abc
dec "an approval stamped in the FUTURE"                      "$M1" "$A"  "$(lbl "$A" "$((NOW + 3600))")" "$NOW" 0 approval-unreadable
dec "a malformed approval label"                             "$M1" "$A"  "gate-approved:nothex:123" "$NOW" 0 approval-unreadable
dec "the labels could not be read at all (?)"                "$M1" "$A"  "?" "$NOW" 0 approval-unreadable
dec "no approval on the bead — the ordinary first review"    "$M1" "$A"  "story:approved" "$NOW" 0 no-approval
dec "no labels"                                              "$M1" "$A"  "" "$NOW" 0 no-approval
dec "the clock cannot be read"                               "$M1" "$A"  "$(lbl "$A" "$FRESH")" "" 0 cannot-compare
dec "the clock reads garbage"                                "$M1" "$A"  "$(lbl "$A" "$FRESH")" "yesterday" 0 cannot-compare
dec "a directed test FAILS on the approved content"          "$M0" "$BT" "$(lbl "$BT" "$FRESH")" "$NOW" 0 tests-failed
has "…and the reason names the test"                         "$DEC_WHY" "bad.selftest.sh"
dec "a changed test has no runner here"                      "$M0" "$LUA" "$(lbl "$LUA" "$FRESH")" "$NOW" 0 tests-unrunnable
dec "more tests than the cap allows"                         "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 0 tests-cannot-run GATE_REMERGE_TEST_MAX_FILES=0
dec "no test in the diff: nothing to run is a real zero (control)" "$M0" "$NT" "$(lbl "$NT" "$FRESH")" "$NOW" 1 granted-exact
touch "$T/city/.gc/gate-remerge.off"
dec "kill switch: the flag file"                             "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 0 switched-off
rm -f "$T/city/.gc/gate-remerge.off"
dec "…gone again → on (the dispatcher is a fresh process every sweep)" "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 1 granted-exact
dec "kill switch: GATE_REMERGE_ENABLED=0"                    "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 0 switched-off GATE_REMERGE_ENABLED=0
dec "explicit flag path that does NOT exist yet is not a switch (control)" "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 1 granted-exact GATE_REMERGE_OFF_FILE="$T/bin/bd.nonexistent-but-created-below"
: > "$T/bin/bd.nonexistent-but-created-below"
dec "kill switch: …(that file exists now)"                   "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 0 switched-off GATE_REMERGE_OFF_FILE="$T/bin/bd.nonexistent-but-created-below"
dec "kill switch whose LOCATION is unknown reads as OFF"     "$M1" "$A"  "$(lbl "$A" "$FRESH")" "$NOW" 0 switched-off GC_CITY=
has "…and the reason says it could not find the switch"      "$DEC_WHY" "cannot find its kill switch"
# git itself failing: merge-tree answers an error / diff --raw fails — "could not tell" is the normal gate
mklog "$(lbl "$A" "$FRESH")"
out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$B32" -c '
set -euo pipefail
git_bad() { case "$*" in *merge-tree*) return 2 ;; *) git -C "$RM_REPO" "$@" ;; esac; }
log(){ :; }; warn(){ :; }; err(){ :; }
source "$1"; source "$2"
gate_remerge_decide git_bad "$3" "$4" "$5" "$6" "$7" || true
printf "\nRESULT\t%s\t%s\n" "$GATE_REMERGE" "$GATE_REMERGE_CODE"' _ "$FLLIB" "$RMLIB" "$M1" "$AR" "$(lbl "$A" "$FRESH")" "$NOW" "$QG_FIX" 2>&1 | grep -a '^RESULT' | tail -1 | tr '\t' '|')
eq "git merge-tree ERRORS (not a conflict) → could not tell" "$out" "RESULT|0|cannot-compare"
mklog "$(lbl "$A" "$FRESH")"
out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$B32" -c '
set -euo pipefail
git_bad() { case "$*" in *"diff --raw"*|*"diff"*"--raw"*) return 128 ;; *) git -C "$RM_REPO" "$@" ;; esac; }
log(){ :; }; warn(){ :; }; err(){ :; }
source "$1"; source "$2"
gate_remerge_decide git_bad "$3" "$4" "$5" "$6" "$7" || true
printf "\nRESULT\t%s\t%s\n" "$GATE_REMERGE" "$GATE_REMERGE_CODE"' _ "$FLLIB" "$RMLIB" "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" "$QG_FIX" 2>&1 | grep -a '^RESULT' | tail -1 | tr '\t' '|')
eq "git diff --raw FAILS → the tests to re-run cannot be listed → normal gate" "$out" "RESULT|0|cannot-compare"
out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$B32" -c '
set -euo pipefail
git_rig() { git -C "$RM_REPO" "$@"; }
source "$1"
gate_remerge_decide git_rig "$2" "$3" "$4" "$5" || true
printf "\nRESULT\t%s\t%s\n" "$GATE_REMERGE" "$GATE_REMERGE_CODE"' _ "$RMLIB" "$M1" "$A" "$(lbl "$A" "$FRESH")" "$NOW" 2>&1 | grep -a '^RESULT' | tail -1 | tr '\t' '|')
eq "gate-fastlane.lib.sh NOT loaded → the tests cannot be re-run → normal gate" "$out" "RESULT|0|lib-missing"
out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$B32" -c '
set -euo pipefail
git_rig() { git -C "$RM_REPO" "$@"; }
source "$1"
gate_remerge_decide git_rig "$2" "$3" "story:approved" "$4" || true
printf "\nRESULT\t%s\t%s\n" "$GATE_REMERGE" "$GATE_REMERGE_CODE"' _ "$RMLIB" "$M1" "$A" "$NOW" 2>&1 | grep -a '^RESULT' | tail -1 | tr '\t' '|')
eq "…but with NO approval the missing lib does not even matter (nothing to decide)" "$out" "RESULT|0|no-approval"

echo "── 3. gate_remerge_confirm (the push-time re-ask) ──"
conf() { # <name> <decide-head> <confirm-main> <confirm-head> <want_rc> <want_code> [VAR=val ...]
  local name="$1" dh="$2" cm="$3" ch="$4" wr="$5" wc="$6" out; shift 6
  mklog "$(lbl "$A" "$FRESH")"
  out=$(env GATE_FS_TMPDIR="$T/tmp" GC_CITY="$T/city" RM_REPO="$R" "$@" "$B32" -c '
set -euo pipefail
git_rig() { git -C "$RM_REPO" "$@"; }
log(){ :; }; warn(){ :; }; err(){ :; }
source "$1"; source "$2"
gate_remerge_decide git_rig "$3" "$4" "$5" "$6" "$9" || true
eval "${CONF_AFTER_DECIDE:-:}"
rc=0; gate_remerge_confirm git_rig "$7" "$8" || rc=$?
printf "\nRESULT\t%s\t%s\t%s\n" "$rc" "${GATE_REMERGE_CONFIRM_CODE:-}" "$GATE_REMERGE"' _ "$FLLIB" "$RMLIB" "$M1" "$dh" "$(lbl "$A" "$FRESH")" "$NOW" "$cm" "$ch" "$QG_FIX" 2>&1 | grep -a '^RESULT' | tail -1 | tr '\t' '|')
  if [ "$out" = "RESULT|$wr|$wc|$([ "$wr" = 0 ] && echo 1 || echo 0)" ]; then ok "$name → rc=$wr${wc:+ ($wc)}"; else bad "$name → expected rc=$wr code=[$wc], got [$out]"; fi
}
conf "same commit about to be pushed"                          "$A"  "$M1" "$A"  0 ""
conf "…the clean rebase of it, onto the main it fast-forwards from" "$AR" "$M1" "$AR" 0 ""
conf "the tip MOVED between decision and push (one line added)" "$AR" "$M1" "$AP" 1 content-changed
conf "main moved to a conflicting state before the push"       "$A"  "$M2" "$A"  1 content-changed
conf "the operator threw the switch after the grant"           "$A"  "$M1" "$A"  1 switched-off CONF_AFTER_DECIDE=GATE_REMERGE_ENABLED=0
out=$(env RM_REPO="$R" "$B32" -c '
set -euo pipefail
git_rig() { git -C "$RM_REPO" "$@"; }
source "$1"
rc=0; gate_remerge_confirm git_rig "$2" "$3" || rc=$?
printf "\nRESULT|%s|%s\n" "$rc" "${GATE_REMERGE_CONFIRM_CODE:-}"' _ "$RMLIB" "$M1" "$A" 2>&1 | grep -a '^RESULT' | tail -1)
eq "no remerge decision in this run → cannot confirm (never a quiet yes)" "$out" "RESULT|1|cannot-confirm"

echo "── 4. stamp / unstamp / record with a stateful fake bd ──"
QS="$T/qg-stamp.jsonl"; rm -f "$QS"
reset_bd
r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-1 "$2" 1700000000 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$QS")
eq "stamp writes the label and READS IT BACK" "$r|$(labels_of ga-1)" "STAMPED|gate-approved:$S40:1700000000"
r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-1 "$2" 1700000500 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S64" "$QS")
eq "a newer approval SUPERSEDES the old one (one at a time)" "$r|$(labels_of ga-1)" "STAMPED|gate-approved:$S64:1700000500"
# the dispatcher's own record (the label is only a pointer to it): written by stamp, and the ONLY thing decide trusts
rec_ok() { "$B32" -c 'source "$1"; if _gate_remerge_approval_recorded "$2" "$3" "$4"; then echo yes; else echo no; fi' _ "$RMLIB" "$@"; }
eq "stamp wrote the gate_approval record: sha + epoch are on the dispatcher's log" "$(rec_ok "$QS" "$S40" 1700000000)|$(rec_ok "$QS" "$S64" 1700000500)" "yes|yes"
eq "…but not for another epoch, another sha, or a log that is not there" "$(rec_ok "$QS" "$S40" 1700000001)|$(rec_ok "$QS" "$S64" 1700000000)|$(rec_ok "$T/nope.jsonl" "$S40" 1700000000)" "no|no|no"
printf 'not json at all %s\n' "$S40" >> "$QS"; printf '{"event":"gate_approval","sha":"%s","epoch":7}\n' "$S40" >> "$QS"
eq "a line that is not JSON does not blind the check (and a record is found after it)" "$(rec_ok "$QS" "$S40" 7)" "yes"
reset_bd; r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-9 "$2" 1700000000 ""; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40")
eq "no log to record into → NOT stamped, and no label is left behind (a label without a record is worthless)" "$r|$(labels_of ga-9)" "NOT|"
: > "$T/afile"; r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-9 "$2" 1700000000 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$T/afile/qg.jsonl")
eq "a log that cannot be written → NOT stamped, no label" "$r|$(labels_of ga-9)" "NOT|"
reset_bd; echo "story:approved" > "$T/fakebd/labels.ga-2"
r=$(bdenv FAKE_BD_FAIL_LABEL_ADD=1 "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-2 "$2" 1700000000 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$QS")
eq "a label write that did not stick is reported (\"the command ran\" is not \"the label is there\")" "$r" "NOT"
r=$(bdenv FAKE_BD_FAIL_SHOW=1 "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-2 "$2" 1700000000 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$QS")
eq "a read-back that fails is reported as not stamped" "$r" "NOT"
r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp /city ga-2 "$2" notanumber "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$QS")
eq "a non-numeric epoch is refused" "$r" "NOT"
r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_stamp "" ga-2 "$2" 1700000000 "$3"; then echo STAMPED; else echo NOT; fi' _ "$RMLIB" "$S40" "$QS")
eq "no city → not stamped" "$r" "NOT"
reset_bd; printf 'story:approved\ngate-approved:%s:5\n' "$S40" > "$T/fakebd/labels.ga-3"
r=$(bdenv "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_unstamp /city ga-3 "$2"; then echo GONE; else echo STILL; fi' _ "$RMLIB" "gate-approved:$S40:5")
eq "unstamp removes exactly that label and reads back" "$r|$(labels_of ga-3)" "GONE|story:approved"
r=$(bdenv FAKE_BD_FAIL_LABEL_REMOVE=1 "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_unstamp /city ga-3 "$2"; then echo GONE; else echo STILL; fi' _ "$RMLIB" "story:approved")
eq "a label that cannot be removed is reported" "$r" "STILL"
# gate_remerge_consume: EVERY approval label comes off (a later reviewer FAIL ends the earlier approval), read back; "could not tell" is not "gone"
cons() { bdenv "$@" "$B32" -c 'set -euo pipefail; source "$1"; if gate_remerge_consume "$2" "$3"; then echo GONE; else echo STILL; fi' _ "$RMLIB" "${CONS_CITY-/city}" "${CONS_BEAD-ga-4}"; }   # no colon: an EMPTY value must stay empty (that is the case under test)
reset_bd; printf 'story:approved\ngate-approved:%s:5\ngate-approved:%s:9\ngate:needs-fix\n' "$S40" "$S64" > "$T/fakebd/labels.ga-4"
eq "consume removes EVERY approval label (the old and the new one), leaves the others, and reads back" "$(cons X=1)|$(labels_of ga-4)" "GONE|story:approved gate:needs-fix"
reset_bd; echo "story:approved" > "$T/fakebd/labels.ga-5"
eq "a bead with no approval: nothing to remove is success, and nothing else is touched" "$(CONS_BEAD=ga-5 cons X=1)|$(labels_of ga-5)" "GONE|story:approved"
reset_bd
eq "a bead with NO labels at all is also 'nothing to remove'" "$(CONS_BEAD=ga-7 cons X=1)" "GONE"
reset_bd; printf 'gate-approved:%s:5\n' "$S40" > "$T/fakebd/labels.ga-6"
eq "labels that cannot be removed → STILL (reported, never 'gone')" "$(CONS_BEAD=ga-6 cons FAKE_BD_FAIL_LABEL_REMOVE=1)|$(labels_of ga-6)" "STILL|gate-approved:$S40:5"
eq "labels that cannot be READ → STILL (could not tell is not gone)" "$(CONS_BEAD=ga-6 cons FAKE_BD_FAIL_SHOW=1)" "STILL"
eq "no city → STILL" "$(CONS_CITY= CONS_BEAD=ga-6 cons X=1)" "STILL"
eq "no bead → STILL" "$(CONS_BEAD= cons X=1)" "STILL"

reset_bd; QL="$T/qg.jsonl"; rm -f "$QL"
rec() { # <decision> [VAR=val ...] — gate_remerge_record on a marker, with the decision globals a real decide leaves behind
  local dec="$1"; shift
  bdenv "$@" "$B32" -c 'set -euo pipefail; source "$1"
GATE_REMERGE=1; GATE_REMERGE_CODE=granted-rebase; GATE_REMERGE_WHY="the tip lands what the approved commit lands"; GATE_REMERGE_SHA="$2"; GATE_REMERGE_AGE_S=120
gate_remerge_record /city mk-1 ga-9 feat/x gascity "$3" 2 "$4" cafebabe' _ "$RMLIB" "$A" "$QL" "$dec" 2>&1
}
rec granted >/dev/null
eq "granted: the marker carries gate.remerge=1" "$(jq -r '.[0].metadata["gate.remerge"]' <<<"$(bdenv FAKE_BD_DIR="$T/fakebd" bd -C /city show mk-1 --json)")" "1"
has "…and the phrase 'remerge sem nova revisão' is on the marker" "$(jq -r '.[0].metadata["gate.remerge_reason"]' <<<"$(bdenv bd -C /city show mk-1 --json)")" "remerge sem nova revisão"
eq "granted: ONE gate_remerge event with what the count needs" "$(jq -r '[.event,.decision,.code,.bead,.marker,.approved_sha,.head_sha,.approved_age_s,.would_have_reviewers,.dry_run]|map(tostring)|join("|")' "$QL")" "gate_remerge|granted|granted-rebase|ga-9|mk-1|$A|cafebabe|120|2|0"
rec revoked >/dev/null
eq "revoked: the marker's gate.remerge is set back to 0" "$(jq -r '.[0].metadata["gate.remerge"]' <<<"$(bdenv bd -C /city show mk-1 --json)")" "0"
eq "revoked: a second event, decision=revoked" "$(jq -rs 'map(.decision)|join(",")' "$QL")" "granted,revoked"
reset_bd; rm -f "$QL"; rec declined >/dev/null
eq "declined: the marker is left alone (gate.remerge never set)" "$(jq -r '.[0].metadata["gate.remerge"] // "unset"' <<<"$(bdenv bd -C /city show mk-1 --json)")" "unset"
eq "declined: the event is still written (the count has the declines too)" "$(jq -r '.decision' "$QL")" "declined"
r=$(rec granted "GATE_REMERGE_UNUSED=1" 2>&1 | head -1); : "$r"
bdenv "$B32" -c 'set -euo pipefail; source "$1"; GATE_REMERGE_CODE=x; GATE_REMERGE_WHY=y; gate_remerge_record /city mk-1 ga-9 b g "/nonexistent-$$/dir/qg.jsonl" notanumber declined; echo SURVIVED' _ "$RMLIB" > "$T/rec.out" 2>&1
has "an unwritable log does not kill the daemon; the lost line is said on stderr" "$(cat "$T/rec.out")" "SURVIVED"
has "…and the warning says the count will miss it" "$(cat "$T/rec.out")" "count will miss"
rm -f "$QL"; bdenv "$B32" -c 'set -euo pipefail; source "$1"; GATE_REMERGE_CODE=x; GATE_REMERGE_WHY=y; gate_remerge_record /city "" ga-9 b g "$2" notanumber declined' _ "$RMLIB" "$QL" >/dev/null 2>&1
eq "a reviewer count that is not a number is written as null (unknown), not as a measured 0" "$(jq -r '.would_have_reviewers|tostring' "$QL")" "null"
echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

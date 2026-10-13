#!/usr/bin/env bash
# gate-remerge-wiring.selftest.sh (ga-mzw9dt) — the dispatcher's LIVE remerge blocks, extracted by SELFTEST-EXTRACT sentinels and run
# under /bin/bash 3.2 (the daemon's shell) with `set -euo pipefail`, against the real lib and real git: lib load (a half-written lib
# reads as "no lib"), the claim-time decision, the record, the push-time confirm, the revoked requeue, the approval stamp (merge-side
# failures of a run that had reviewers only), and the drift guards (the bypass takes a granted remerge, the retry loop does not retry a
# revocation, Step 11 and the run bead say "remerge", and the chain failed merge -> stamp -> next claim exists end to end).
# DISPATCHER= points the file under test at another copy of quality-gate-dispatcher.sh. Exit 0 iff every assertion holds.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate-remerge.fixture.lib.sh" || { echo "FATAL: cannot source the fixture lib"; exit 2; }

echo "── 5. the dispatcher's LIVE blocks, under /bin/bash 3.2 with set -euo pipefail ──"
LOADBLK=$(extract_block "$DISPATCHER" remerge-lib-load)
DECBLK=$(extract_block "$DISPATCHER" remerge-decide)
RECBLK=$(extract_block "$DISPATCHER" remerge-record)
PCBLK=$(extract_block "$DISPATCHER" remerge-push-confirm)
REVBLK=$(extract_block "$DISPATCHER" remerge-revoked)
STAMPBLK=$(extract_block "$DISPATCHER" remerge-stamp)
CONBLK=$(extract_block "$DISPATCHER" remerge-consume-on-fail)
for b in LOADBLK DECBLK RECBLK PCBLK REVBLK STAMPBLK CONBLK; do
  if [ -n "$(eval "echo \"\${$b}\"")" ]; then ok "block located in the dispatcher: $b"; else bad "block $b not found — the dispatcher has no remerge wiring (SELFTEST-EXTRACT sentinel missing)"; fi
done

echo "  ·· lib load ··"
mkdir -p "$T/ld/good" "$T/ld/bad" "$T/ld/none" "$T/ld/empty" "$T/ld/fail"
cp "$RMLIB" "$T/ld/good/gate-remerge.lib.sh"
printf 'gate_remerge_decide() {\n  if then fi ((\n' > "$T/ld/bad/gate-remerge.lib.sh"
printf ': a lib that loads and defines nothing\n' > "$T/ld/empty/gate-remerge.lib.sh"
printf 'return 7\n' > "$T/ld/fail/gate-remerge.lib.sh"
for k in good bad none empty fail; do
  { printf 'set -euo pipefail\n'; printf '%s\n' "$LOADBLK"; printf 'if declare -F gate_remerge_decide >/dev/null 2>&1; then echo "LOADED:${GATE_RM_LIB_WHY:-}"; else echo "NOLIB:${GATE_RM_LIB_WHY:-}"; fi\n'; } > "$T/ld/$k/run.sh"
done
eq "a good lib next to the dispatcher is loaded (and there is no reason to give)" "$("$B32" "$T/ld/good/run.sh" 2>&1 | tail -1)" "LOADED:"
eq "a lib with a SYNTAX error reads as 'no lib' — it does not kill the daemon — and SAYS why" "$("$B32" "$T/ld/bad/run.sh" 2>&1 | tail -1)" "NOLIB:gate-remerge.lib.sh has a syntax error"
eq "no lib file at all reads as 'no lib' and says why" "$("$B32" "$T/ld/none/run.sh" 2>&1 | tail -1)" "NOLIB:gate-remerge.lib.sh is missing or unreadable"
eq "a lib that loads but defines no decision reads as 'no lib' and says why" "$("$B32" "$T/ld/empty/run.sh" 2>&1 | tail -1)" "NOLIB:gate-remerge.lib.sh did not define gate_remerge_decide"
eq "a lib that fails WHILE loading reads as 'no lib' and says why" "$("$B32" "$T/ld/fail/run.sh" 2>&1 | tail -1)" "NOLIB:gate-remerge.lib.sh failed while loading"

echo "  ·· decision ··"
dcase() { # <name> <header/stub code> <want line>
  { printf 'set -euo pipefail\n'
    printf 'git_rig() { :; }\nDEFAULT_BRANCH=main; BEAD_CITY=/city; BEAD_ID=ga-x; BRANCH_SHA=abc123; GC_CITY=/city; QG_LOG=/q\n'
    printf 'GATE_LANE=normal; REQUIRED_REVIEWERS=2; TIER=CODE; GATE_REMERGE=0\n'
    printf '%s\n' "$2"
    printf '%s\n' "$DECBLK"
    printf 'echo "RESULT remerge=$GATE_REMERGE code=${GATE_REMERGE_CODE:-} rev=$REQUIRED_REVIEWERS tier=$TIER seen=${SEEN:-none}"\n'
  } > "$T/dc.sh"
  local out; out=$(bdenv "${4:-X=1}" "$B32" "$T/dc.sh" 2>&1 | tail -1) || out="DIED"
  if [ "$out" = "RESULT $3" ]; then ok "decision block: $1 → ${3%% seen=*}"; else bad "decision block: $1 → '$out', want 'RESULT $3'"; fi
}
reset_bd; printf 'story:approved gate:needs-fix\n' | tr ' ' '\n' > "$T/fakebd/labels.ga-x"
dcase "lib says yes"                       'gate_remerge_decide() { SEEN="$4"; GATE_REMERGE=1; GATE_REMERGE_CODE=granted-exact; GATE_REMERGE_SHA=abc; }' "remerge=1 code=granted-exact rev=0 tier=REMERGE seen=story:approved gate:needs-fix"
dcase "lib says no"                        'gate_remerge_decide() { SEEN="$4"; GATE_REMERGE=0; GATE_REMERGE_CODE=content-changed; }'                  "remerge=0 code=content-changed rev=2 tier=CODE seen=story:approved gate:needs-fix"
dcase "lib ERRORS after saying yes"        'gate_remerge_decide() { GATE_REMERGE=1; GATE_REMERGE_CODE=granted-exact; return 7; }'                     "remerge=0 code=decision-errored rev=2 tier=CODE seen=none"
dcase "lib returns garbage as the answer"  'gate_remerge_decide() { GATE_REMERGE=banana; GATE_REMERGE_CODE=x; }'                                       "remerge=0 code=x rev=2 tier=CODE seen=none"
dcase "lib not loaded at all (an eligible run) → SAYS so, and takes the normal gate" ':'                                                          "remerge=0 code=lib-not-loaded rev=2 tier=CODE seen=none"
dcase "lib absent, but the run was never eligible (fast lane) → no noise"           'GATE_LANE=fast; REQUIRED_REVIEWERS=0; TIER=FAST-LANE'          "remerge=0 code= rev=0 tier=FAST-LANE seen=none"
dcase "lib absent, a run with no reviewer anyway → no noise"                         'REQUIRED_REVIEWERS=0'                                          "remerge=0 code= rev=0 tier=CODE seen=none"
dcase "lib absent, no source bead id → no noise"                                     'BEAD_ID=""'                                                    "remerge=0 code= rev=2 tier=CODE seen=none"
dcase "the fast lane is untouched (no second decision)" 'GATE_LANE=fast; REQUIRED_REVIEWERS=0; TIER=FAST-LANE; gate_remerge_decide() { SEEN=called; GATE_REMERGE=1; }' "remerge=0 code= rev=0 tier=FAST-LANE seen=none"
dcase "a run that would have no reviewer anyway is untouched" 'REQUIRED_REVIEWERS=0; gate_remerge_decide() { SEEN=called; GATE_REMERGE=1; }'          "remerge=0 code= rev=0 tier=CODE seen=none"
dcase "no source bead id → no decision"    'BEAD_ID=""; gate_remerge_decide() { SEEN=called; GATE_REMERGE=1; }'                                       "remerge=0 code= rev=2 tier=CODE seen=none"
dcase "labels that cannot be read reach the decision as '?'" 'gate_remerge_decide() { SEEN="$4"; GATE_REMERGE=0; GATE_REMERGE_CODE=approval-unreadable; }' "remerge=0 code=approval-unreadable rev=2 tier=CODE seen=?" FAKE_BD_FAIL_SHOW=1
reset_bd
dcase "a bead with NO labels reaches the decision as an empty list, not as '?'" 'gate_remerge_decide() { SEEN="[$4]"; GATE_REMERGE=0; GATE_REMERGE_CODE=no-approval; }' "remerge=0 code=no-approval rev=2 tier=CODE seen=[]" X=1
reset_bd; printf 'story:approved\n' > "$T/fakebd/labels.ga-x"
{ printf 'set -euo pipefail\ngit_rig() { :; }\nDEFAULT_BRANCH=main; BEAD_CITY=/city; BEAD_ID=ga-x; BRANCH_SHA=abc; GC_CITY=/city; QG_LOG=/q\nGATE_LANE=normal; REQUIRED_REVIEWERS=2; TIER=CODE; GATE_REMERGE=0\nGATE_RM_LIB_WHY="gate-remerge.lib.sh has a syntax error"\n'; printf '%s\n' "$DECBLK"; printf 'echo "WHY=$GATE_REMERGE_WHY"\n'; } > "$T/dw.sh"
has "lib absent: the reason the lib did not load reaches the log line's text" "$(bdenv X=1 "$B32" "$T/dw.sh" 2>&1 | tail -1)" "gate-remerge.lib.sh has a syntax error"

echo "  ·· the real decision block + the real libs + real git ··"
real_dec() { # <head> <labels...> -> RESULT line from the dispatcher's own block
  local head="$1"; shift
  reset_bd; for l in "$@"; do echo "$l" >> "$T/fakebd/labels.ga-x"; done
  case "${REAL_DEC_NOLOG:-}" in 1) : > "$QG_FIX" ;; *) mklog "$*" ;; esac   # REAL_DEC_NOLOG=1: the label is there, the dispatcher's record is not
  { printf 'set -euo pipefail\n'
    printf 'git_rig() { git -C "$RM_REPO" "$@"; }\nlog(){ :; }; warn(){ :; }; err(){ :; }\n'
    printf 'DEFAULT_BRANCH=main; BEAD_CITY=/city; BEAD_ID=ga-x; GC_CITY="%s"; GATE_LANE=normal; REQUIRED_REVIEWERS=2; TIER=CODE; GATE_REMERGE=0; QG_LOG="%s"\n' "$T/city" "$QG_FIX"
    printf 'source "%s"; source "%s"\n' "$FLLIB" "$RMLIB"
    printf 'BRANCH_SHA=%s\n' "$head"
    printf '%s\n' "$DECBLK"
    printf 'echo "RESULT remerge=$GATE_REMERGE code=${GATE_REMERGE_CODE:-} rev=$REQUIRED_REVIEWERS tier=$TIER"\n'
  } > "$T/rdc.sh"
  git -C "$R" update-ref refs/remotes/origin/main "$M1"
  bdenv RM_REPO="$R" GATE_FS_TMPDIR="$T/tmp" "$B32" "$T/rdc.sh" 2>&1 | tail -1
}
eq "real block: the clean rebase of an approved commit → 0 reviewers, tier REMERGE" "$(real_dec "$AR" "$(lbl "$A" "$FRESH")")" "RESULT remerge=1 code=granted-rebase rev=0 tier=REMERGE"
eq "real block: one line added after the approval → the normal gate (2 reviewers)"  "$(real_dec "$AP" "$(lbl "$A" "$FRESH")")" "RESULT remerge=0 code=content-changed rev=2 tier=CODE"
eq "real block: a label added BY HAND (no record on the dispatcher's log) → the normal gate, 2 reviewers" "$(REAL_DEC_NOLOG=1 real_dec "$AR" "$(lbl "$A" "$FRESH")")" "RESULT remerge=0 code=approval-unverified rev=2 tier=CODE"
eq "real block: no approval on the bead → the normal gate"                         "$(real_dec "$AR" "story:approved")" "RESULT remerge=0 code=no-approval rev=2 tier=CODE"
git -C "$R" update-ref -d refs/remotes/origin/main

echo "  ·· record ··"
rcase() { # <name> <code> <remerge> <want>
  { printf 'set -euo pipefail\n'
    printf 'GC_CITY=/city; MARKER_ID=mk-1; BEAD_ID=ga-x; BRANCH=feat/x; RIG=gascity; QG_LOG=/q; BRANCH_SHA=abc\n'
    printf 'log(){ echo "LOG: $*"; }\nGATE_REMERGE_WHY=why; GATE_REMERGE_WOULD_REVIEWERS=2\n'
    printf 'GATE_REMERGE_CODE=%q; GATE_REMERGE=%q\n' "$2" "$3"
    printf 'gate_remerge_record() { echo "CALLED:$8:$9"; }\n'
    printf '%s\n' "$RECBLK"
    printf 'echo END\n'
  } > "$T/rc.sh"
  local out; out=$("$B32" "$T/rc.sh" 2>&1 | grep -v '^LOG:' | tr '\n' ' ' | sed 's/ $//') || out="DIED"
  if [ "$out" = "$4" ]; then ok "record block: $1"; else bad "record block: $1 → '$out', want '$4'"; fi
}
rcase "no approval → nothing recorded (the ordinary first review is not an event)" no-approval 0 "END"
rcase "no code at all → nothing recorded"                                          ""          0 "END"
rcase "a decline is recorded"                                                      content-changed 0 "CALLED:declined:abc END"
rcase "a grant is recorded"                                                        granted-exact 1 "CALLED:granted:abc END"
{ printf 'set -euo pipefail\nlog(){ :; }\nGATE_REMERGE_CODE=expired; GATE_REMERGE=0; GATE_REMERGE_WHY=w\n'; printf '%s\n' "$RECBLK"; printf 'echo SURVIVED\n'; } > "$T/rc2.sh"
eq "recorder missing (lib did not load): the block survives set -euo pipefail" "$("$B32" "$T/rc2.sh" 2>&1 | tail -1)" "SURVIVED"
# …and it is NOT silent: the lib that did not load is a period the count must be able to see, so the event is written inline
QGE="$T/rec-event.jsonl"; : > "$QGE"
{ printf 'set -euo pipefail\nlog(){ :; }\nGATE_REMERGE_CODE=lib-not-loaded; GATE_REMERGE=0; GATE_REMERGE_WHY="remerge lib not loaded (x)"; GATE_REMERGE_WOULD_REVIEWERS=%q\nMARKER_ID=mk-9; BEAD_ID=ga-x; BRANCH=feat/x; RIG=gascity; BRANCH_SHA=abc123; QG_LOG=%q\n' 2 "$QGE"; printf '%s\n' "$RECBLK"; printf 'echo DONE\n'; } > "$T/rc3.sh"
eq "recorder missing: the block still ends cleanly while writing the event" "$("$B32" "$T/rc3.sh" 2>&1 | tail -1)" "DONE"
ev() { jq -r '[.event,.decision,.code,.bead,.marker,.head_sha,(.would_have_reviewers|tostring),(.approved_age_s|tostring),.approved_sha] | join("|")' "$QGE" 2>/dev/null | tail -1; }
eq "recorder missing: an inline gate_remerge event is still written (declined, lib-not-loaded, the reviewers a normal run uses, no approval age)" "$(ev)" "gate_remerge|declined|lib-not-loaded|ga-x|mk-9|abc123|2|null|"
: > "$QGE"; sed -i.bak 's/GATE_REMERGE_WOULD_REVIEWERS=2/GATE_REMERGE_WOULD_REVIEWERS=abc/' "$T/rc3.sh"
eq "…a reviewer count that is not a number is null (unknown), never a measured 0, and never kills the block" "$("$B32" "$T/rc3.sh" 2>&1 | tail -1)|$(ev)" "DONE|gate_remerge|declined|lib-not-loaded|ga-x|mk-9|abc123|null|null|"

echo "  ·· push-time confirm (inside do_merge_ff, before the push) ··"
pcase() { # <name> <stub> <want>
  { printf 'set -euo pipefail\n'
    printf 'MERGE_ATTEMPT=0; CUR_MAIN=m1; CUR_BRANCH=b1; MERGE_RESULT=""; GATE_REMERGE=%q\n' "${4:-1}"
    printf 'err(){ echo "ERR: $*"; }\ngit_rig(){ :; }\n'
    printf '%s\n' "$2"
    printf 'one() {\n%s\n  MERGE_RESULT="reached-push"\n  return 0\n}\n' "$PCBLK"
    printf 'one || true\necho "RESULT result=$MERGE_RESULT remerge=$GATE_REMERGE"\n'
  } > "$T/pc.sh"
  local out; out=$("$B32" "$T/pc.sh" 2>&1 | tail -1) || out="DIED"
  if [ "$out" = "RESULT $3" ]; then ok "push-confirm block: $1"; else bad "push-confirm block: $1 → '$out', want 'RESULT $3'"; fi
}
pcase "confirmed → goes on to the push"             'gate_remerge_confirm() { return 0; }'                                              "result=reached-push remerge=1"
pcase "NOT confirmed → NOT pushed, failed_remerge_revoked" 'gate_remerge_confirm() { GATE_REMERGE_CONFIRM_CODE=content-changed; GATE_REMERGE_CONFIRM_WHY=moved; return 1; }' "result=failed_remerge_revoked remerge=0"
pcase "confirmation function missing → NOT pushed"  ':'                                                                                 "result=failed_remerge_revoked remerge=0"
pcase "confirmation function errors → NOT pushed"   'gate_remerge_confirm() { return 9; }'                                               "result=failed_remerge_revoked remerge=0"
pcase "a reviewed (non-remerge) run never enters the block" 'gate_remerge_confirm() { return 1; }'                                       "result=reached-push remerge=0" 0

echo "  ·· revoked at the push → a re-queue, never a FAIL ··"
vcase() { # <name> <MERGE_RESULT> <unstamp rc> <want>
  { printf 'set -euo pipefail\n'
    printf 'GC_CITY=/city; BEAD_CITY=/city; BEAD_ID=ga-x; MARKER_ID=mk-1; GATE_RUN_ID=run-1; BRANCH=feat/x; RIG=gascity; QG_LOG=/q; BRANCH_SHA=abc\n'
    printf 'GATE_REMERGE=1; GATE_REMERGE_LABEL=gate-approved:%s:1; GATE_REMERGE_CONFIRM_CODE=content-changed; GATE_REMERGE_CONFIRM_WHY=moved; GATE_REMERGE_WOULD_REVIEWERS=2\n' "$S40"
    printf 'MERGE_RESULT=%q\n' "$2"
    printf 'warn(){ :; }\nbd(){ echo "BD:$*" >> "$LOGF"; }\n'
    printf 'gate_remerge_unstamp() { echo "UNSTAMP:$3" >> "$LOGF"; return %s; }\n' "$3"
    printf 'gate_remerge_record() { echo "RECORD:$8" >> "$LOGF"; }\n'
    printf 'gate_requeue_respecting_external() { echo "REQUEUE:$1:$2:$3" >> "$LOGF"; return 0; }\ngate_requeue_narrate() { :; }\n_RQ_SKIPPED=0; _RQ_WHY=""\n'
    printf 'set_gate_status() { echo "STATUS:$1:$2" >> "$LOGF"; }\n'
    printf 'one() {\n%s\n  echo FELL-THROUGH >> "$LOGF"\n  return 5\n}\n' "$REVBLK"
    printf 'rc=0; one || rc=$?\necho "rc=$rc"\n'
  } > "$T/rv.sh"
  : > "$T/rv.log"
  local out; out=$(LOGF="$T/rv.log" "$B32" "$T/rv.sh" 2>&1 | tail -1) || out="DIED"
  local seen; seen=$(sed 's/BD:.*comment.*/BD:comment/; s/BD:.*close.*/BD:close/; s/BD:.*label remove.*/BD:label-remove/' "$T/rv.log" | tr '\n' ' ' | sed 's/ $//')
  if [ "$out|$seen" = "$4" ]; then ok "revoked block: $1"; else bad "revoked block: $1 → '$out|$seen', want '$4'"; fi
}
vcase "revoked: approval consumed, recorded, marker re-queued, run superseded, handler returns 0 (no FAIL)" failed_remerge_revoked 0 "rc=0|UNSTAMP:gate-approved:$S40:1 RECORD:revoked REQUEUE:mk-1:queued:dispatching BD:label-remove BD:comment BD:comment STATUS:run-1:superseded BD:close"
vcase "revoked, and the label cannot be removed: still re-queued, and the marker comment says so" failed_remerge_revoked 1 "rc=0|UNSTAMP:gate-approved:$S40:1 RECORD:revoked REQUEUE:mk-1:queued:dispatching BD:label-remove BD:comment BD:comment STATUS:run-1:superseded BD:close"
vcase "any other merge result falls through (the generic failed* handling is still the one that runs)" failed_push_race 0 "rc=5|FELL-THROUGH"
grep -q 'COULD NOT be removed\|could NOT be removed' "$DISPATCHER" && ok "the comment text for an approval that could not be removed is in the dispatcher" || bad "no text for an approval that could not be removed"

echo "  ·· the approval stamp (in the failed* block of gate_finalize_run) ··"
scase() { # <name> <MERGE_RESULT> <REQUIRED_REVIEWERS> <GATE_LANE> <GATE_REMERGE> <stamp rc> <want>
  { printf 'set -euo pipefail\n'
    printf 'BEAD_CITY=/city; BEAD_ID=ga-x; BRANCH_SHA=%s; DEFAULT_BRANCH=main; QG_LOG=/q\n' "$S40"
    printf 'MERGE_RESULT=%q; REQUIRED_REVIEWERS=%q; GATE_LANE=%q; GATE_REMERGE=%q\n' "$2" "$3" "$4" "$5"
    printf 'FAIL_REASONS="base reasons"\nlog(){ echo "LOG: $*" >> "$LOGF"; }\nwarn(){ echo "WARN: $*" >> "$LOGF"; }\n'
    printf 'gate_remerge_stamp() { echo "STAMP:$2:$3" >> "$LOGF"; return %s; }\n' "$6"
    printf '%s\n' "$STAMPBLK"
    printf 'echo "RESULT"; printf "%%s\\n" "$FAIL_REASONS"\n'
  } > "$T/st.sh"
  : > "$T/st.log"
  local out; out=$(LOGF="$T/st.log" "$B32" "$T/st.sh" 2>&1 | tr '\n' '~') || out="DIED"
  local stamped="no"; grep -q '^STAMP:' "$T/st.log" && stamped="yes"
  local warned="no"; grep -q '^WARN:' "$T/st.log" && warned="yes"
  local fr="plain"; case "$out" in *"RESULT~base reasons~The reviewers APPROVED commit ${S40:0:12}"*) fr="approval-line" ;; esac
  if [ "$stamped|$warned|$fr" = "$7" ]; then ok "stamp block: $1"; else bad "stamp block: $1 → $stamped|$warned|$fr, want $7 (out=$out)"; fi
}
scase "push race after an ALL-PASS review → stamped, and the hand-off tells the author"  failed_push_race             2 normal 0 0 "yes|no|approval-line"
scase "merge-time rebase failure → stamped"                                                  failed_merge_time_rebase     2 normal 0 0 "yes|no|approval-line"
scase "merge-time conflict → stamped (decide declines it while it still conflicts)"           failed_merge_time_conflict   1 normal 0 0 "yes|no|approval-line"
scase "a hook refusal → stamped (the fix may be the hook's policy, not the code)"             failed_push_hook_rejected    2 normal 0 0 "yes|no|approval-line"
scase "the bead was closed/parked late → NOT stamped (a human decision, not a merge race)"  failed_bead_blocked_late     2 normal 0 0 "no|no|plain"
scase "the branch does not reference its bead → NOT stamped (the content is in doubt)"      failed_branch_content_mismatch 2 normal 0 0 "no|no|plain"
scase "sha could not be resolved → NOT stamped"                                              failed_sha_resolution        2 normal 0 0 "no|no|plain"
scase "a fast-lane run (no reviewer approved anything) → NOT stamped"                        failed_push_race             0 fast   0 0 "no|no|plain"
scase "a run with 0 reviewers → NOT stamped"                                                 failed_push_race             0 normal 0 0 "no|no|plain"
scase "a REMERGE run that fails again must not refresh the approval it was granted on"       failed_push_race             0 normal 1 0 "no|no|plain"
scase "…even if a reviewer count were left over"                                             failed_push_race             2 normal 1 0 "no|no|plain"
scase "stamp fails (label did not stick) → warned, hand-off text unchanged"                  failed_push_race             2 normal 0 1 "yes|yes|plain"
{ printf 'set -euo pipefail\nBEAD_CITY=/c; BEAD_ID=ga-x; BRANCH_SHA=%s; DEFAULT_BRANCH=main; MERGE_RESULT=failed_push_race; REQUIRED_REVIEWERS=2; GATE_LANE=normal; GATE_REMERGE=0; FAIL_REASONS=x\nlog(){ :; }; warn(){ :; }\n' "$S40"; printf '%s\n' "$STAMPBLK"; printf 'echo "SURVIVED:$FAIL_REASONS"\n'; } > "$T/st2.sh"
eq "stamper missing (lib did not load): the block survives set -euo pipefail and changes nothing" "$("$B32" "$T/st2.sh" 2>&1 | tail -1)" "SURVIVED:x"
stlib() { # <MERGE_RESULT> <REQUIRED_REVIEWERS> <GATE_LANE> -> the WARN lines of a run whose stamper is missing
  { printf 'set -euo pipefail\nBEAD_CITY=/c; BEAD_ID=ga-x; BRANCH_SHA=%s; DEFAULT_BRANCH=main; MERGE_RESULT=%q; REQUIRED_REVIEWERS=%q; GATE_LANE=%q; GATE_REMERGE=0; FAIL_REASONS=x; GATE_RM_LIB_WHY="gate-remerge.lib.sh is missing or unreadable"\n' "$S40" "$1" "$2" "$3"
    printf 'log(){ :; }; warn(){ echo "WARN: $*" >> "$LOGF"; }\n'; printf '%s\n' "$STAMPBLK"; printf 'echo "SURVIVED:$FAIL_REASONS"\n'; } > "$T/st3.sh"
  : > "$T/st3.log"; LOGF="$T/st3.log" "$B32" "$T/st3.sh" 2>&1 | tail -1 > "$T/st3.out"; cat "$T/st3.out" "$T/st3.log" | tr '\n' '~'
}
r=$(stlib failed_push_race 2 normal)
case "$r" in "SURVIVED:x~WARN: "*"missing or unreadable"*"NOT recorded"*) ok "stamper missing: a WARN says the approval was NOT recorded and why — the author's text is untouched" ;; *) bad "stamper missing is silent or wrong: [$r]" ;; esac
eq "stamper missing, but the run was never stampable (fast lane) → no WARN" "$(stlib failed_push_race 0 fast)" "SURVIVED:x~"
eq "stamper missing, but the failure is not about the merge → no WARN" "$(stlib failed_bead_blocked_late 2 normal)" "SURVIVED:x~"
# the text the author reads promises what decide can deliver, no more
{ printf 'set -euo pipefail\nBEAD_CITY=/c; BEAD_ID=ga-x; BRANCH_SHA=%s; DEFAULT_BRANCH=main; QG_LOG=/q; MERGE_RESULT=failed_merge_time_conflict; REQUIRED_REVIEWERS=2; GATE_LANE=normal; GATE_REMERGE=0; FAIL_REASONS=base\nlog(){ :; }; warn(){ :; }\ngate_remerge_stamp() { return 0; }\n' "$S40"; printf '%s\n' "$STAMPBLK"; printf 'printf "%%s" "$FAIL_REASONS"\n'; } > "$T/st4.sh"
r=$("$B32" "$T/st4.sh" 2>&1)
has "author text: says the dispatcher CHECKS at the next claim (a conflict that is still there is declined)" "$r" "checks at the next claim whether it can merge WITHOUT a new review"
case "$r" in *"is merged WITHOUT a new review"*) bad "author text still promises an unconditional skip: [$r]" ;; *) ok "author text no longer promises an unconditional skip" ;; esac

echo "  ·· a reviewer FAIL ends any earlier approval (and a merge failure, which WRITES it, does not) ··"
ccase() { # <name> <ANY_FAIL> <BEAD_ID> <consume: rc | NONE> <want>
  { printf 'set -euo pipefail\nBEAD_CITY=/city; BEAD_ID=%q; ANY_FAIL=%q\n' "$3" "$2"
    printf 'warn(){ echo "WARN: $*" >> "$LOGF"; }\n'
    if [ "$4" != "NONE" ]; then printf 'gate_remerge_consume() { echo "CONSUME:$1:$2" >> "$LOGF"; return %s; }\n' "$4"; fi
    printf 'one() {\n%s\n  echo AFTER >> "$LOGF"\n}\none\n' "$CONBLK"
  } > "$T/cn.sh"
  : > "$T/cn.log"
  local out; out=$(LOGF="$T/cn.log" "$B32" "$T/cn.sh" 2>&1 | tr '\n' ' ' | sed 's/ $//'); out="$out$(sed 's/^WARN:.*/WARN/' "$T/cn.log" | tr '\n' ' ' | sed 's/ $//')"
  if [ "$out" = "$5" ]; then ok "consume block: $1"; else bad "consume block: $1 → '$out', want '$5'"; fi
}
ccase "a reviewer FAIL (ANY_FAIL=1) consumes the earlier approval, and the run goes on"       1 ga-x 0    "CONSUME:/city:ga-x AFTER"
ccase "a merge failure degraded to FAIL (ANY_FAIL=0) must NOT consume — it is what WRITES the approval" 0 ga-x 0    "AFTER"
ccase "consume could not finish (rc 1) → a WARN says the earlier approval may still stand"     1 ga-x 1    "CONSUME:/city:ga-x WARN AFTER"
ccase "no source bead id → nothing to consume"                                                  1 ""   0    "AFTER"
ccase "the lib is not loaded → nothing to call (the claim already said so), and the FAIL path goes on" 1 ga-x NONE "AFTER"

echo "── 6. drift guards ──"
grep -qF 'gate_remerge_decide git_rig "origin/$DEFAULT_BRANCH" "$BRANCH_SHA" "$_RM_LABELS" "$(date +%s 2>/dev/null || true)" "$QG_LOG"' "$DISPATCHER" \
  && grep -qF 'gate_remerge_stamp "$BEAD_CITY" "$BEAD_ID" "$BRANCH_SHA" "$(date +%s 2>/dev/null || true)" "$QG_LOG"' "$DISPATCHER" \
  && ok "decide and stamp are both handed the dispatcher's own log (without it a stamp writes no record and a decide verifies nothing)" || bad "the dispatcher does not pass \$QG_LOG to gate_remerge_decide and gate_remerge_stamp"
grep -q '^if \[ "\$GATE_LANE" = "fast" \] || \[ "\${GATE_REMERGE:-0}" = "1" \]; then$' "$DISPATCHER" && ok "the zero-reviewer bypass takes a granted remerge" || bad "the bypass does not take GATE_REMERGE=1 (a granted remerge would spawn reviewers anyway)"
grep -q '\[ "\$MERGE_RESULT" = "failed_remerge_revoked" \] || \\' "$DISPATCHER" && ok "retry loop: failed_remerge_revoked is in the NON-retryable list" || bad "retry loop does not list failed_remerge_revoked as non-retryable (the same revoked push would be retried)"
grep -q 'REASON="remerge_sem_nova_revisao_approved_' "$DISPATCHER" && ok "Step 11 gives a remerge run its own reason (not 'quorum 0 of 0')" || bad "Step 11 has no remerge reason"
grep -q -- '--arg remerge "\${GATE_REMERGE:-0}"' "$DISPATCHER" && grep -q 'lane: \$lane, remerge: \$remerge' "$DISPATCHER" && ok "dispatcher_complete carries a remerge field (merged vs merely granted)" || bad "dispatcher_complete has no remerge field"
grep -q 'GATE_REMERGE_RUN_DESC_LINE:-' "$DISPATCHER" && ok "the gate-run bead's description says 'remerge' for a granted one" || bad "the gate-run bead does not say it was a remerge"
LN_DEC=$(grep -n 'SELFTEST-EXTRACT remerge-decide: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_RUNBEAD=$(grep -n '^GATE_RUN_ID=\$(bd -C "\$GC_CITY" create' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_BYPASS=$(grep -n 'SELFTEST-EXTRACT fastlane-bypass: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_SPAWN=$(grep -n '^# ── Step 7: Create verdict beads' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_DEC" ] && [ -n "$LN_BYPASS" ] && [ -n "$LN_SPAWN" ] && [ "$LN_DEC" -lt "$LN_RUNBEAD" ] && [ "$LN_RUNBEAD" -lt "$LN_BYPASS" ] && [ "$LN_BYPASS" -lt "$LN_SPAWN" ]; then
  ok "order: remerge decision → gate-run bead → zero-reviewer bypass → Step 7 (no reviewer can be spawned before the decision)"
else bad "order is wrong: decide=$LN_DEC runbead=$LN_RUNBEAD bypass=$LN_BYPASS step7=$LN_SPAWN"; fi
LN_FL=$(grep -n 'SELFTEST-EXTRACT fastlane-record: END' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_FL" ] && [ -n "$LN_DEC" ] && [ "$LN_FL" -lt "$LN_DEC" ]; then ok "the fast lane decides first; remerge only looks at what the fast lane left for a reviewer"; else bad "remerge is not after the fast-lane decision"; fi
LN_LIB_FL=$(grep -n 'SELFTEST-EXTRACT fastlane-lib-load: END' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_LIB_RM=$(grep -n 'SELFTEST-EXTRACT remerge-lib-load: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_LIB_FL" ] && [ -n "$LN_LIB_RM" ] && [ "$LN_LIB_FL" -lt "$LN_LIB_RM" ]; then ok "the remerge lib is loaded after the fast-lane lib it depends on"; else bad "lib load order: fastlane=$LN_LIB_FL remerge=$LN_LIB_RM"; fi
# the stamp is BEFORE the generic failed* warn, i.e. inside the failed* block, and AFTER FAIL_REASONS is chosen
LN_ST=$(grep -n 'SELFTEST-EXTRACT remerge-stamp: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_FR=$(grep -n 'FAIL_REASONS="Merge failed after all-PASS verdict' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_ST" ] && [ -n "$LN_FR" ] && [ "$LN_FR" -lt "$LN_ST" ]; then ok "the stamp comes after the hand-off text is chosen (it appends to it)"; else bad "stamp order: FAIL_REASONS=$LN_FR stamp=$LN_ST"; fi
# a remerge must not be able to be a verdict: the lib never sets OVERALL_VERDICT / FAIL_REASONS / a label other than its own
if grep -n 'OVERALL_VERDICT\|FAIL_REASONS\|gate:needs-fix\|gate:needs-human\|set_gate_status' "$RMLIB" | grep -v '^[0-9]*:#' >/dev/null; then bad "the remerge lib touches a verdict (it must only ever grant)"; else ok "the remerge lib never touches a verdict, a fix label or a gate status — it only grants"; fi
# no read of the rebase-stable digest: the equality is the landing tree
if grep -v '^[[:space:]]*#' "$RMLIB" | grep -q '_gate_fastlane_digest_file\|GATE_LANE_DIGEST'; then bad "the remerge lib uses the fast lane's -U0 digest (it cannot tell a moved line)"; else ok "the remerge lib compares landing TREES, not the -U0 digest"; fi
# the fast lane (ga-atsahv) promises NOTHING executable between its push-time confirmation and the push; the remerge confirmation therefore sits AHEAD of
# it (the two never both act). gate-fastlane.selftest.sh pins the property too, but takes 20+ minutes — this is the quick guard for the region.
LN_RMC_B=$(grep -n 'SELFTEST-EXTRACT remerge-push-confirm: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_RMC_E=$(grep -n 'SELFTEST-EXTRACT remerge-push-confirm: END' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_FLC_B=$(grep -n 'SELFTEST-EXTRACT fastlane-push-confirm: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_FLC_E=$(grep -n 'SELFTEST-EXTRACT fastlane-push-confirm: END' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_LATE=$(grep -n 'LIVE re-check #2 — AUTHORITATIVE' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_PUSH=$(grep -n -F 'git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH"' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_LATE" ] && [ -n "$LN_RMC_B" ] && [ -n "$LN_RMC_E" ] && [ -n "$LN_FLC_B" ] && [ "$LN_LATE" -lt "$LN_RMC_B" ] && [ "$LN_RMC_E" -lt "$LN_FLC_B" ]; then
  ok "order inside do_merge_ff: late bead re-check → remerge confirm → fast-lane confirm (the fast lane's stays last before the push)"
else bad "confirm order is wrong: late=$LN_LATE remerge=$LN_RMC_B-$LN_RMC_E fastlane=$LN_FLC_B"; fi
if [ -n "$LN_FLC_E" ] && [ -n "$LN_PUSH" ] && [ "$LN_FLC_E" -lt "$LN_PUSH" ]; then
  GAPCODE=$(sed -n "$((LN_FLC_E+1)),$((LN_PUSH-1))p" "$DISPATCHER" | grep -v -E '^[[:space:]]*(#.*)?$' || true)
  if [ -z "$GAPCODE" ]; then ok "nothing executable between the fast-lane confirmation and the FF push (the fast lane's own promise holds)"; else bad "executable code between the fast-lane confirmation and the push: $GAPCODE"; fi
else bad "could not locate the fast-lane confirm END ($LN_FLC_E) and the FF push ($LN_PUSH)"; fi
# consume-on-fail sits in the FAIL path, after the verdict is logged
LN_CON=$(grep -n 'SELFTEST-EXTRACT remerge-consume-on-fail: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
LN_FAILLOG=$(grep -n '^  log "Gate FAILED: \$FAIL_REASONS"' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$LN_CON" ] && [ -n "$LN_FAILLOG" ] && [ "$LN_FAILLOG" -lt "$LN_CON" ]; then ok "the consume block is in the FAIL path (after the FAIL is logged)"; else bad "consume placement: faillog=$LN_FAILLOG consume=$LN_CON"; fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
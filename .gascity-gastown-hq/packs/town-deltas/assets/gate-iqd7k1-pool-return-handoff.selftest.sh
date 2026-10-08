#!/usr/bin/env bash
# gate-iqd7k1-pool-return-handoff.selftest.sh (ga-iqd7k1, 2026-10-08)
#
# BUG (wa-ev549x, 07/10): the gate returns a source bead to the pool when its branch needs a
# rebase and the author is ephemeral (ga-tz0op, pre-review) or when the merge itself hits a
# textual conflict after ALL-PASS (ga-39l9z2) — and leaves it wearing gate:needs-rebase. The
# Pilot's _filter_built drops any bead with a gate:* lifecycle label other than
# gate:needs-fix / gate:fix-attempt:N as "already built / in the gate", so nobody ever rebased
# it: the ephemeral author was gone, the pool saw nothing to do, the Pilot excluded the bead.
#
# FIX: both pool-return arms call gate_pool_return_rebase_handoff — GATE-FEEDBACK comment FIRST
# (the Pilot injects the latest ^GATE-FEEDBACK comment into the builder prompt and refuses a
# gate:needs-fix bead that has none, ga-e2n96), then gate:needs-fix, then drop gate:needs-rebase.
# A failed write must leave gate:needs-rebase as it was (the inert, pre-fix state).
#
# What this locks:
#   H*  the helper on its own, against a stateful bd stub with injectable failures
#   A*  the two REAL arms (sentinel blocks extracted from the live dispatcher) end with a bead that
#       wears gate:needs-fix and a latest-GATE-FEEDBACK comment, and not gate:needs-rebase
#   P*  the REAL Pilot _filter_built, fed the bead exactly as the arm left it, keeps it as a
#       candidate (and still drops the old gate:needs-rebase shape / an actively re-gated bead)
#
# QG_DISPATCHER=<path> runs the same checks against another copy of the dispatcher — point it at
# the pre-fix file to watch A*/P* fail.
# Exit 0 iff every assertion holds. Runs under /bin/bash 3.2 (launchd's bash).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${QG_DISPATCHER:-$SELF_DIR/quality-gate-dispatcher.sh}"
PILOT="$SELF_DIR/pilot-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }   # has <haystack> <needle> — no pipe (pipefail + grep -q races SIGPIPE)

echo "== gate-iqd7k1-pool-return-handoff.selftest =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$PILOT" ] || { echo "FATAL: pilot-dispatcher not found at $PILOT" >&2; exit 2; }

if /bin/bash -n "$DISPATCHER" 2>/dev/null; then
  ok "dispatcher parses under /bin/bash (3.2) — the interpreter launchd actually runs"
else
  bad "dispatcher does NOT parse under /bin/bash 3.2"
fi

GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode" >&2; exit 2; }
set +e

extract_block() {
  sed -n "/# SELFTEST-EXTRACT ${2}: BEGIN/,/# SELFTEST-EXTRACT ${2}: END/p" "$1" | sed '1d;$d'
}

# ── stateful bd stub ───────────────────────────────────────────────────────────
BEAD_ID="bead-iqd7k1"; MARKER_ID="m-iqd7k1"; BEAD_CITY="bead-city"; GC_CITY="test-city"
BRANCH="fix/ga-wa-iqd7k1-fixture"
ST_LABELS=""; ST_ASSIGNEE=""; ST_STATUS="open"; ST_ROUTE=""; ST_CMTS=""; ST_MCMTS=""; ST_SEQ=""
F_COMMENT=0; F_DROP_CMT=0; F_ADD_FIX=0; F_ADD_FIX_SILENT=0; F_RM_REBASE=0; F_SHOW=0; F_SHOW_GARBAGE=0

reset_state() { # <labels> [assignee] [status]
  ST_LABELS="$1"; ST_ASSIGNEE="${2:-}"; ST_STATUS="${3:-open}"; ST_ROUTE=""; ST_CMTS=""; ST_MCMTS=""; ST_SEQ=""
  F_COMMENT=0; F_DROP_CMT=0; F_ADD_FIX=0; F_ADD_FIX_SILENT=0; F_RM_REBASE=0; F_SHOW=0; F_SHOW_GARBAGE=0
  GATE_HANDOFF_OBS=""
}
labs_json() { local l first=1 out=""; for l in $1; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$l\""; done; printf '%s' "$out"; }
state_json() {
  printf '[{"id":"%s","status":"%s","assignee":"%s","labels":[%s],"metadata":{"gc.routed_to":"%s"},"comments":%s}]' \
    "$BEAD_ID" "$ST_STATUS" "$ST_ASSIGNEE" "$(labs_json "$ST_LABELS")" "$ST_ROUTE" \
    "$(printf '%s' "$ST_CMTS" | jq -Rs '[split("\n")[] | select(length>0) | {text: .}]')"
}
bd() { # bd -C <city> <cmd> <id> ...
  case "${3:-}" in
    comment)
      ST_SEQ="$ST_SEQ comment;"
      if [ "${4:-}" != "$BEAD_ID" ]; then ST_MCMTS="$ST_MCMTS"$'\n'"$(printf '%s' "${5:-}" | tr '\n' ' ')"; return 0; fi
      # F_COMMENT fails ONLY the hand-off comment: the arm's own verified-write comment must still land so the test can read what it says.
      if [ "$F_COMMENT" = 1 ]; then case "${5:-}" in "GATE-FEEDBACK (rebase-handoff"*) return 1 ;; esac; fi
      [ "$F_DROP_CMT" = 1 ] && return 0
      ST_CMTS="$ST_CMTS"$'\n'"$(printf '%s' "${5:-}" | tr '\n' ' ')"; return 0 ;;
    label)
      local out l
      case "${4:-}" in
        add)
          ST_SEQ="$ST_SEQ add:${6:-};"
          if [ "${6:-}" = "gate:needs-fix" ]; then
            [ "$F_ADD_FIX" = 1 ] && return 1
            [ "$F_ADD_FIX_SILENT" = 1 ] && return 0
          fi
          has_label "${6:-}" || ST_LABELS="${ST_LABELS:+$ST_LABELS }${6:-}" ;;
        remove)
          ST_SEQ="$ST_SEQ rm:${6:-};"
          if [ "${6:-}" = "gate:needs-rebase" ] && [ "$F_RM_REBASE" = 1 ]; then return 0; fi
          out=""; for l in $ST_LABELS; do [ "$l" = "${6:-}" ] || out="$out $l"; done; ST_LABELS="${out# }" ;;
      esac
      return 0 ;;
    assign) ST_ASSIGNEE="${5:-}"; return 0 ;;
    update)
      case "${5:-}" in
        --set-metadata) case "${6:-}" in gc.routed_to=*) ST_ROUTE="${6#gc.routed_to=}" ;; esac ;;
        --status) ST_STATUS="${6:-}" ;;
      esac
      return 0 ;;
    show)
      ST_SEQ="$ST_SEQ show;"
      [ "$F_SHOW" = 1 ] && return 1
      if [ "$F_SHOW_GARBAGE" = 1 ]; then printf 'this is not json'; return 0; fi
      state_json; return 0 ;;
  esac
  return 0
}
log()  { return 0; }
warn() { return 0; }
err()  { return 0; }
has_label() { local l; for l in $ST_LABELS; do [ "$l" = "$1" ] && return 0; done; return 1; }
first_cmt() { printf '%s\n' "$ST_CMTS" | sed -n '2p'; }
# What the Pilot hands the builder: pilot-dispatcher.sh:10661 — the LAST comment whose text starts with GATE-FEEDBACK.
pilot_feedback() { state_json | jq -r '.[0].comments | [ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""'; }

HFILES="a.sh b.sh"
run_helper() { gate_pool_return_rebase_handoff "$BEAD_CITY" "$BEAD_ID" "$BRANCH" "main" "abc1234" "$1"; }

# ── H. the helper on its own ───────────────────────────────────────────────────
echo "── H. gate_pool_return_rebase_handoff, on its own ──"
if ! declare -F gate_pool_return_rebase_handoff >/dev/null 2>&1; then
  bad "gate_pool_return_rebase_handoff is not defined in the dispatcher (the pool-return arms have no way to hand the bead to the Pilot)"
else
  reset_state "gate:failed gate:needs-rebase story:approved"
  run_helper "$HFILES"; RC=$?
  C1="$(first_cmt)"
  if [ "$RC" = "0" ] && [ "$ST_SEQ" = " comment; add:gate:needs-fix; rm:gate:needs-rebase;" ]; then
    ok "H1 normal: GATE-FEEDBACK comment FIRST, then gate:needs-fix, then drop gate:needs-rebase — nothing else written (the read-back runs in a \$(...) subshell, so it is asserted through the observation below)"
  else
    bad "H1 write order/shape wrong: rc=$RC seq=[$ST_SEQ]"
  fi
  case "$C1" in
    "GATE-FEEDBACK (rebase-handoff, ga-iqd7k1; branch=$BRANCH): "*) ok "H1 the comment OPENS with GATE-FEEDBACK — the anchor the Pilot's ^GATE-FEEDBACK extraction needs" ;;
    *) bad "H1 comment does not open with GATE-FEEDBACK: [$C1]" ;;
  esac
  if has "$C1" "REBASE" && has "$C1" "origin/main (at abc1234)" && has "$C1" "Conflicting files (the gate's merge-tree check): a.sh b.sh." \
     && has "$C1" "NOT counted as a gate:fix-attempt" && has "$C1" "run /gate-done"; then
    ok "H1 the comment tells the builder what to do: rebase (not rewrite) onto origin/main@sha, the conflicting files, resubmit via /gate-done"
  else
    bad "H1 comment is missing the instruction/branch/sha/files: [$C1]"
  fi
  if has_label gate:needs-fix && ! has_label gate:needs-rebase && has_label gate:failed && has_label story:approved && ! has "$ST_SEQ" "fix-attempt"; then
    ok "H1 bead ends needs-fix, not needs-rebase; unrelated labels untouched; gate:fix-attempt:* never touched"
  else
    bad "H1 label state wrong: [$ST_LABELS] seq=[$ST_SEQ]"
  fi
  if has "$GATE_HANDOFF_OBS" "GATE-FEEDBACK comment=present; gate:needs-fix=present; gate:needs-rebase=removed" && has "$GATE_HANDOFF_OBS" "verified post-write"; then
    ok "H1 the observation is read back from the bead, not assumed"
  else
    bad "H1 observation wrong: [$GATE_HANDOFF_OBS]"
  fi

  for noinfo in "" "merge conflict (files unavailable)"; do
    reset_state "gate:needs-rebase"
    run_helper "$noinfo"; C="$(first_cmt)"
    if has "$C" "captured no conflicting-file list" && ! has "$C" "Conflicting files" && ! has "$C" "files unavailable"; then
      ok "H2 no usable file list [${noinfo:-empty}] → says so plainly, never an empty 'Conflicting files ():' or the raw sentinel"
    else
      bad "H2 no-file-list wording wrong for [${noinfo:-empty}]: [$C]"
    fi
  done

  reset_state "gate:needs-rebase story:approved"; F_COMMENT=1
  run_helper "$HFILES"; RC=$?
  if [ "$RC" = "0" ] && [ "$ST_SEQ" = " comment;" ] && has_label gate:needs-rebase && ! has_label gate:needs-fix && has "$GATE_HANDOFF_OBS" "NOT applied"; then
    ok "H3 comment write FAILS → no label touched: gate:needs-rebase kept (inert), no gate:needs-fix without feedback, reported as NOT applied"
  else
    bad "H3 failed comment must leave the labels alone: rc=$RC seq=[$ST_SEQ] labels=[$ST_LABELS] obs=[$GATE_HANDOFF_OBS]"
  fi

  reset_state "gate:needs-rebase story:approved"; F_ADD_FIX=1
  run_helper "$HFILES"; RC=$?
  if [ "$RC" = "0" ] && [ "$ST_SEQ" = " comment; add:gate:needs-fix;" ] && has_label gate:needs-rebase && ! has_label gate:needs-fix && has "$GATE_HANDOFF_OBS" "PARTIAL"; then
    ok "H4 gate:needs-fix add FAILS → gate:needs-rebase NOT removed (never leaves the bead with neither label), reported PARTIAL"
  else
    bad "H4 failed needs-fix add must keep needs-rebase: rc=$RC seq=[$ST_SEQ] labels=[$ST_LABELS] obs=[$GATE_HANDOFF_OBS]"
  fi

  for mode in F_SHOW F_SHOW_GARBAGE; do
    reset_state "gate:needs-rebase story:approved"; eval "$mode=1"
    run_helper "$HFILES"; RC=$?
    if [ "$RC" = "0" ] && has "$GATE_HANDOFF_OBS" "UNVERIFIED" && has "$GATE_HANDOFF_OBS" "NOT a claim the swap failed" \
       && ! has "$GATE_HANDOFF_OBS" "verified post-write" && ! has "$GATE_HANDOFF_OBS" "NOT applied"; then
      ok "H5 post-write read unusable ($mode) → UNVERIFIED: neither 'done' nor 'failed' — a third state"
    else
      bad "H5 unreadable read-back ($mode) must be its own state: rc=$RC obs=[$GATE_HANDOFF_OBS]"
    fi
  done

  reset_state "gate:needs-rebase"; F_RM_REBASE=1
  run_helper "$HFILES"
  if has "$GATE_HANDOFF_OBS" "gate:needs-rebase=STILL PRESENT" && has "$GATE_HANDOFF_OBS" "gate:needs-fix=present" && ! has "$GATE_HANDOFF_OBS" "gate:needs-rebase=removed"; then
    ok "H6 a gate:needs-rebase removal that did not stick is reported STILL PRESENT, not 'removed'"
  else
    bad "H6 silent remove failure not caught: obs=[$GATE_HANDOFF_OBS]"
  fi

  reset_state "gate:needs-rebase"; F_ADD_FIX_SILENT=1
  run_helper "$HFILES"
  if has "$GATE_HANDOFF_OBS" "gate:needs-fix=MISSING"; then
    ok "H7 a gate:needs-fix add that returned 0 but is not on the bead is reported MISSING"
  else
    bad "H7 silent add failure not caught: obs=[$GATE_HANDOFF_OBS]"
  fi

  reset_state "gate:needs-rebase"; F_DROP_CMT=1
  run_helper "$HFILES"
  if has "$GATE_HANDOFF_OBS" "GATE-FEEDBACK comment=NOT VISIBLE" && has "$GATE_HANDOFF_OBS" "ga-e2n96"; then
    ok "H8 a comment write that returned 0 but is not on the bead is reported NOT VISIBLE (the zero-feedback case the Pilot refuses)"
  else
    bad "H8 missing comment on read-back not caught: obs=[$GATE_HANDOFF_OBS]"
  fi

  for mode in F_COMMENT F_ADD_FIX F_SHOW F_SHOW_GARBAGE; do
    reset_state "gate:needs-rebase"; eval "$mode=1"
    SE_OUT="$( set -e; run_helper "$HFILES"; echo "reached" )"
    if [ "$SE_OUT" = "reached" ]; then
      ok "H9 $mode: the helper returns 0 and does not abort a set -e caller"
    else
      bad "H9 $mode: the helper aborted a set -e caller: [$SE_OUT]"
    fi
  done
fi

# ── A. the two real arms ───────────────────────────────────────────────────────
echo "── A. the real pool-return arms end with a bead the Pilot can pick up ──"
DEFAULT_BRANCH="main"; MAIN_HEAD_SHA="abc1234"; CONFLICT_FILES="a.sh b.sh"
REBASE_AUTHOR="wa-worker-1"; _TZ0OP_ROUTE="gastown.dog"; _TZ0OP_ROUTE_UNKNOWN=0
GATE_SHA_FAIL_CLASS="hold"; RIG_LIST_JSON="[]"
REBASE_EVENT=""; REBASE_VERDICT=""
# Marker compare-before-write is locked by gate-8dehbc-park-external.selftest.sh; here it just succeeds.
gate_requeue_respecting_external() { return 0; }
gate_park_note_skipped() { return 0; }
gate_clear_assignee_if_holder() { ST_ASSIGNEE=""; return 0; }
gate_fail_restore_route() { printf 'gastown.dog'; }

PA_SRC="$(extract_block "$DISPATCHER" "ga-8dehbc-park-pool-author")"
NR_SRC="$(extract_block "$DISPATCHER" "ga-iqd7k1-nr-pool-return")"
[ -n "$PA_SRC" ] || { echo "FATAL: sentinel block ga-8dehbc-park-pool-author not found (moved/renamed?)" >&2; exit 2; }
eval "run_pool_author() {
$PA_SRC
}"
if [ -n "$NR_SRC" ]; then
  eval "run_nr_pool_return() {
$NR_SRC
}"
fi
FAIL_FB='GATE-FEEDBACK (gate_run=ga-wisp-fixture branch=fix/ga-wa-iqd7k1-fixture): quality gate FAILED. Fix THESE specific blocking issues, then run /gate-done to re-gate. Merge failed after all-PASS verdict.'

reset_state "gate:failed gate:needs-rebase gate:queued gate:reviewing story:in-flight story:approved" "wa-worker-1" "in_progress"
ST_CMTS=$'\n'"$FAIL_FB"
run_pool_author >/dev/null 2>&1
PA_LABELS="$ST_LABELS"; PA_CMTS="$ST_CMTS"
if has_label gate:needs-fix && ! has_label gate:needs-rebase && ! has_label story:in-flight && ! has_label gate:queued && ! has_label gate:reviewing \
   && [ -z "$ST_ASSIGNEE" ] && [ "$ST_ROUTE" = "gastown.dog" ] && has_label gate:failed && has_label story:approved; then
  ok "A1 pool-author arm: bead returned to the pool (unassigned, routed, un-queued) AND wearing gate:needs-fix, not gate:needs-rebase"
else
  bad "A1 pool-author arm left the bead as [$ST_LABELS] assignee=[$ST_ASSIGNEE] route=[$ST_ROUTE] — the Pilot drops a gate:needs-rebase bead as already built (wa-ev549x)"
fi
PF="$(pilot_feedback)"
case "$PF" in
  "GATE-FEEDBACK (rebase-handoff, ga-iqd7k1; branch=$BRANCH): "*) ok "A1 the comment the Pilot injects (latest ^GATE-FEEDBACK) is the rebase hand-off, superseding the earlier FAIL feedback" ;;
  *) bad "A1 the Pilot would inject the wrong feedback: [$PF]" ;;
esac
if has "$ST_CMTS" "rebase hand-off to the Pilot's fix-loop, verified post-write on the raw bead: GATE-FEEDBACK comment=present; gate:needs-fix=present; gate:needs-rebase=removed"; then
  ok "A1 the arm's verified-write comment carries the hand-off observation"
else
  bad "A1 the arm's verified-write comment lost the hand-off observation: [$ST_CMTS]"
fi

reset_state "gate:failed gate:needs-rebase gate:queued story:in-flight" "wa-worker-1" "in_progress"; F_COMMENT=1
run_pool_author >/dev/null 2>&1
if has_label gate:needs-rebase && ! has_label gate:needs-fix && [ -z "$ST_ASSIGNEE" ] && has "$ST_CMTS" "NOT applied"; then
  ok "A2 pool-author arm, hand-off write fails → the bead keeps gate:needs-rebase (inert, pre-fix state), is still returned to the pool, and the comment says NOT applied"
else
  bad "A2 failed hand-off must be inert and visible: labels=[$ST_LABELS] assignee=[$ST_ASSIGNEE] cmts=[$ST_CMTS]"
fi

if [ -z "$NR_SRC" ]; then
  bad "A3 sentinel block ga-iqd7k1-nr-pool-return not found — the merge-time (ga-39l9z2) pool-return arm is not under test"
else
  reset_state "gate:failed gate:needs-rebase gate:queued story:in-flight story:approved" "dog-x" "in_progress"
  ST_CMTS=$'\n'"$FAIL_FB"
  run_nr_pool_return >/dev/null 2>&1
  NR_LABELS="$ST_LABELS"
  if has_label gate:needs-fix && ! has_label gate:needs-rebase && ! has_label story:in-flight && ! has_label gate:queued \
     && [ -z "$ST_ASSIGNEE" ] && [ "$ST_STATUS" = "open" ] && [ "$ST_ROUTE" = "gastown.dog" ] && has_label gate:failed; then
    ok "A3 merge-time arm: bead returned to the pool (reopened, unassigned, un-queued) AND wearing gate:needs-fix, not gate:needs-rebase"
  else
    bad "A3 merge-time arm left the bead as [$ST_LABELS] status=[$ST_STATUS] assignee=[$ST_ASSIGNEE] route=[$ST_ROUTE]"
  fi
  PF="$(pilot_feedback)"
  case "$PF" in
    "GATE-FEEDBACK (rebase-handoff, ga-iqd7k1; branch=$BRANCH): "*) ok "A3 the latest ^GATE-FEEDBACK is the rebase hand-off — it supersedes the generic 'Merge failed after all-PASS' feedback" ;;
    *) bad "A3 the Pilot would inject the wrong feedback: [$PF]" ;;
  esac
  if ! has "$ST_SEQ" "fix-attempt"; then
    ok "A3 gate:fix-attempt:* untouched — a merge-time conflict is still not a fix attempt"
  else
    bad "A3 the arm touched a gate:fix-attempt label: seq=[$ST_SEQ]"
  fi

  reset_state "gate:failed gate:needs-rebase gate:queued story:in-flight" "dog-x" "in_progress"; F_ADD_FIX=1
  run_nr_pool_return >/dev/null 2>&1
  if has_label gate:needs-rebase && ! has_label gate:needs-fix && [ -z "$ST_ASSIGNEE" ] && has "$ST_CMTS" "PARTIAL"; then
    ok "A4 merge-time arm, gate:needs-fix add fails → gate:needs-rebase kept (inert), still returned to the pool, comment says PARTIAL"
  else
    bad "A4 failed hand-off must be inert and visible: labels=[$ST_LABELS] assignee=[$ST_ASSIGNEE] cmts=[$ST_CMTS]"
  fi
fi

# ── P. the real Pilot filter, fed the bead as the arm left it ───────────────────
echo "── P. the real Pilot _filter_built keeps the bead the arm hands over ──"
_FB_FN="$(grep '^log()' "$PILOT")
$(sed -n '/^_log_exclusions() {/,/^}$/p' "$PILOT")
$(awk '/^_beadid_has_active_gate_artifact\(\)/{f=1} /^_beadid_has_open_gate_marker\(\)/{f=1} /^_beadid_matched_crew_branch_ref\(\)/{f=1} /^_beadid_branch_signal\(\)/{f=1} /^_filter_built\(\)/{f=1} f{print} f&&/^}$/{f=0}' "$PILOT")"
labels_arr() { local l first=1 out=""; for l in $1; do [ "$first" = 1 ] || out="$out,"; first=0; out="$out\"$l\""; done; printf '[{"id":"wa-x","labels":[%s]}]' "$out"; }
# branch exists + a parked (open, non-active) gate marker names the bead — wa-ev549x's shape.
fb() { # fb <labels> <active-beads>
  ( eval "$_FB_FN"; export PILOT_TEST_BRANCH_BEADS="wa-x" PILOT_TEST_GATE_OPEN_BEADS="wa-x" PILOT_TEST_GATE_ACTIVE_BEADS="$2"
    labels_arr "$1" | _filter_built 2>/dev/null | jq -rc '[.[].id]' 2>/dev/null )
}
R="$(fb "$PA_LABELS" "")"
if [ "$R" = '["wa-x"]' ]; then
  ok "P1 the bead as the pool-author arm left it (branch exists, parked marker open) IS a Pilot candidate — it gets rebased"
else
  bad "P1 the Pilot still drops the bead the pool-author arm returned ('$R') for labels [$PA_LABELS] — wa-ev549x: nobody rebases it"
fi
if [ -n "${NR_LABELS:-}" ]; then
  R="$(fb "$NR_LABELS" "")"
  [ "$R" = '["wa-x"]' ] && ok "P2 the bead as the merge-time arm left it IS a Pilot candidate" \
    || bad "P2 the Pilot still drops the bead the merge-time arm returned ('$R') for labels [$NR_LABELS]"
fi
R="$(fb "gate:failed gate:needs-rebase story:approved" "")"
if [ "$R" = '[]' ]; then
  ok "P3 control: the OLD shape (gate:needs-rebase, no gate:needs-fix) is dropped as already built — the mechanism this fix works around"
else
  bad "P3 control broke: the Pilot no longer drops a gate:needs-rebase bead ('$R') — re-read whether the hand-off is still needed"
fi
R="$(fb "gate:failed gate:needs-fix story:approved" "wa-x")"
if [ "$R" = '[]' ]; then
  ok "P4 control: a gate:needs-fix bead that a marker is ACTIVELY re-gating is still dropped (no double dispatch)"
else
  bad "P4 control broke: an actively re-gated needs-fix bead is a candidate ('$R')"
fi

echo ""
echo "gate-iqd7k1-pool-return-handoff.selftest: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1

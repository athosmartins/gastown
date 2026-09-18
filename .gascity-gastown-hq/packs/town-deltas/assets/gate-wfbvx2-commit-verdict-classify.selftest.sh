#!/usr/bin/env bash
# gate-wfbvx2-commit-verdict-classify.selftest.sh (ga-wfbvx2)
#
# Proves the ga-wfbvx2 fix in quality-gate-dispatcher.sh's Step 4c
# classification block (the same "SELFTEST-EXTRACT gate-10uqmi-rebase-fail-
# classify" block ga-10uqmi already extends) — the missing sibling of that
# bead's own fix.
#
# THE BUG (root-caused live by the Mayor, 2026-09-17, marker for branch
# fix/wa-aoznq-scheduled-job-opt-out): ga-10uqmi taught this block that
# rebase_content_verdict()="no" (ga-m07gc — content silently lost though the
# commit survived) is DETERMINISTIC and must route to CONFLICT_KIND="merge"
# (immediate gate-status:needs-rebase, no retry counter, no tier5 exile)
# instead of the generic "transient" bucket. It never taught the block about
# branch_bead_commit_verdict()="no" (ga-y9a1d — none of the branch's own
# commits mention the bead) — the OTHER verdict computed at every one of the
# 6 push-attempt call sites just above this block, and just as deterministic:
# the commit message does not change on retry, so re-running the identical
# rebase/merge reproduces the identical "no" every time. Pre-fix, THIS
# verdict fell straight through to the "else" (transient) branch, unchanged,
# and re-entered the exact bounded-retry/exile machinery ga-10uqmi already
# proved resonates without ever escalating.
#
# Measured cost of the gap (Mayor's live controlled experiment, 2026-09-17
# 20:3x-20:55): the wa-aoznq branch failed identically from 19:01 onward; by
# the time it reached review it PASSED (20:06, 884s of reviewer time), then
# was refused again at 20:11 on a condition already true since 19:01, with
# at least 4 auto-rebase rounds between 19:46-20:28 — one full review cycle
# burned and ~2h of queue time on a one-line, already-diagnosable cause. The
# ONLY change that fixed it live was rewriting the commit subject (tree
# unchanged, git diff = 0 lines) and pushing by hand.
#
# THE FIX: PR_COMMIT_VERDICT="no" now routes to CONFLICT_KIND="merge" too —
# the SAME classification ga-10uqmi's own verdict already gets, sharing the
# SAME already-proven downstream disposition (immediate gate-status:
# needs-rebase for a live author, immediate skip+mail-Mayor for a dead/pool
# one — see gate-10uqmi-rebase-fail-classify.selftest.sh Section F, which
# this file deliberately does not re-duplicate). CONFLICT_FILES reuses
# _gate_push_skip_reason() (ga-744kvc, already shipped, already tested by
# gate-744kvc-push-skip-reason.selftest.sh) instead of a second hand-written
# copy of the same fact — the log line and the marker-facing text this bead
# adds are now composed by the identical function call.
#
# NOT in this file's scope (already covered elsewhere, verified un-touched
# by this bead, not re-duplicated here):
#   - Admission-time refusal (branch whose commit never cites its bead is
#     refused AT SUBMISSION, before a reviewer is ever spent) already ships
#     as quality-gate-guard.sh's Step 5b-pre (ga-pj5va, merged 2026-08-11,
#     over a month before the incident this bead fixes) — proven by
#     gate-guard-submission-time-coherence.selftest.sh (28/28 passing against
#     this bead's own diff, confirmed in the same session that wrote this
#     file). The wa-aoznq incident slipped past it for a reason this bead
#     does not change (ga-pj5va's own documented fail-open posture on
#     fetch/rev-parse uncertainty) — Step 4c, tested here, is the SECOND,
#     deeper safety net for whatever reaches it regardless of why.
#   - "no stderr captured" naming (ga-744kvc, already shipped and tested by
#     gate-744kvc-push-skip-reason.selftest.sh, reused not reimplemented).
#
# Strategy mirrors gate-10uqmi-rebase-fail-classify.selftest.sh exactly
# (extract the classification block via its own SELFTEST-EXTRACT sentinel,
# eval under `bash -c` with the minimal inputs it reads) plus
# gate-744kvc-push-skip-reason.selftest.sh's lib-only source (this bead's own
# new code, unlike ga-10uqmi's, calls _gate_push_skip_reason FROM INSIDE the
# extracted block, so that function must be exported into the subshell, not
# just available in this test's own shell).
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-wfbvx2-commit-verdict-classify.selftest (ga-wfbvx2) =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# Load the REAL _gate_push_skip_reason/branch_bead_commit_verdict from the
# live dispatcher (lib-only = no live run), then export the one this bead's
# new code calls so the sentinel-extracted block (run in its own `bash -c`
# subshell below) can actually resolve it — a plain `source` alone only
# reaches THIS shell, never a child `bash -c`.
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
type _gate_push_skip_reason >/dev/null 2>&1 \
  || { echo "FATAL: _gate_push_skip_reason not defined by dispatcher (lib-only) — this bead's new code depends on it"; exit 1; }
type branch_bead_commit_verdict >/dev/null 2>&1 \
  || { echo "FATAL: branch_bead_commit_verdict not defined by dispatcher (lib-only)"; exit 1; }
export -f _gate_push_skip_reason

BLOCK=$(sed -n '/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: BEGIN/,/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: END/p' "$DISPATCHER")
if [ -z "$BLOCK" ]; then
  echo "FATAL: could not extract gate-10uqmi-rebase-fail-classify block (sentinels missing?) — ga-wfbvx2 extends this same block" >&2
  exit 2
fi
ok "located live rebase-fail classification block via sentinel extraction (same block ga-10uqmi already extends)"

case "$BLOCK" in
  *'elif [ "${PR_COMMIT_VERDICT:-}" = "no" ]; then'*)
    ok "extracted block contains this bead's new elif branch — testing live code, not a stale copy" ;;
  *)
    bad "FATAL: extracted block does not contain the ga-wfbvx2 elif — block sentinels may have drifted ahead of this bead's edit"
    echo "$BLOCK"
    exit 2
    ;;
esac

# classify <pr_commit_verdict> <pr_content_verdict> <branch> <bead_id> [push_err]
# Runs the REAL extracted block with AUTO_REBASE_OK=0/BRANCH_IS_CURRENT=0
# (forces the classification "else", exactly like gate-10uqmi's own harness).
# BRANCH/BEAD_ID are threaded through because this bead's new CONFLICT_FILES
# interpolates both via _gate_push_skip_reason.
STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/gate-wfbvx2-classify-stderr.XXXXXX" 2>/dev/null || echo "/tmp/gate-wfbvx2-classify-stderr.$$")"
classify() {
  local pcmv="$1" pcov="$2" branch="$3" bead="$4" push_err="${5:-}"
  AUTO_REBASE_OK=0 BRANCH_IS_CURRENT=0 \
  PR_COMMIT_VERDICT="$pcmv" PR_CONTENT_VERDICT="$pcov" BRANCH="$branch" BEAD_ID="$bead" \
  AUTO_REBASE_PUSH_ERR="$push_err" AUTO_REBASE_PUSH_RC="1" \
  AUTO_MERGE_FALLBACK_ERR="" AUTO_REBASE_SETUP_ERR="" _LOST_PATHS="" \
  bash -c "set -euo pipefail; $BLOCK"$'\nprintf "%s|%s|%s" "$CONFLICT_KIND" "$CONFLICT_FILES" "$HAS_CONFLICT"' \
    2>"$STDERR_FILE"
}
# classify_unset — mirrors gate-10uqmi Section E: PR_COMMIT_VERDICT truly
# never assigned this sweep (not even ""), e.g. the mutex-held / worktree-add
# -failed early-exit paths above this block, which never compute either
# verdict at all. Must not crash under set -u; must fall through exactly like
# a plain unset PR_CONTENT_VERDICT already does (untouched by this bead).
classify_unset() {
  AUTO_REBASE_OK=0 BRANCH_IS_CURRENT=0 BRANCH="some-branch" BEAD_ID="ga-xxxxx" \
  AUTO_REBASE_PUSH_ERR="worktree add failed" AUTO_REBASE_PUSH_RC="1" \
  AUTO_MERGE_FALLBACK_ERR="" AUTO_REBASE_SETUP_ERR="" _LOST_PATHS="" \
  bash -c "set -euo pipefail; $BLOCK"$'\nprintf "%s|%s|%s" "$CONFLICT_KIND" "$CONFLICT_FILES" "$HAS_CONFLICT"' \
    2>"$STDERR_FILE"
}

echo "── SECTION A: commit-verdict=no (ga-y9a1d), content fine — the fix's core claim ──"

OUT=$(classify "no" "yes" "fix/wa-aoznq-scheduled-job-opt-out" "wa-aoznq")
RC=$?
KIND="${OUT%%|*}"
if [ "$RC" = "0" ] && [ "$KIND" = "merge" ]; then
  ok "PR_COMMIT_VERDICT=no -> CONFLICT_KIND=merge (was unconditionally 'transient' pre-fix — this is the incident's own exact shape)"
else
  bad "PR_COMMIT_VERDICT=no -> expected CONFLICT_KIND=merge, got rc=$RC out='$OUT' stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi
case "$OUT" in
  *"no commit on this branch mentions bead wa-aoznq"*"fix(wa-aoznq)"*"cite the id in the body"*)
    ok "diagnostic names the missing bead id AND the concrete fix (rename subject / cite in body) — invariant (a)" ;;
  *)
    bad "diagnostic text missing the actionable fix instruction — got '$OUT'" ;;
esac
case "$OUT" in
  *"no stderr captured"*) bad "diagnostic still says 'no stderr captured' for a gate-decision refusal — got '$OUT'" ;;
  *) ok "diagnostic never says 'no stderr captured' (invariant d, via the reused ga-744kvc helper)" ;;
esac
case "$OUT" in
  *"ga-y9a1d"*"ga-wfbvx2"*) ok "diagnostic cites both the original check (ga-y9a1d) and this bead (ga-wfbvx2) for traceability" ;;
  *) bad "diagnostic missing traceability tags — got '$OUT'" ;;
esac
HAS_C="${OUT##*|}"
[ "$HAS_C" = "1" ] && ok "HAS_CONFLICT=1 (still routes through the proven bounce/needs-rebase disposition below)" \
                    || bad "expected HAS_CONFLICT=1, got '$HAS_C'"

echo "── SECTION B: commit-verdict=skip is NOT treated as a confirmed mismatch ──"

OUT=$(classify "skip" "yes" "some-branch" "ga-xxxxx" "")
KIND="${OUT%%|*}"
if [ "$KIND" = "transient" ]; then
  ok "PR_COMMIT_VERDICT=skip falls through to CONFLICT_KIND=transient — 'nothing to verify' is never a confirmed 'no' (mirrors ga-pgxs78's discrimination for the sibling verdict)"
else
  bad "PR_COMMIT_VERDICT=skip -> expected CONFLICT_KIND=transient, got '$KIND' (out='$OUT')"
fi
case "$OUT" in
  *"nothing to verify"*) ok "transient path still names the skip reason (via _gate_push_skip_reason, when AUTO_REBASE_PUSH_ERR was empty)" ;;
  *) : ;;  # AUTO_REBASE_PUSH_ERR was pre-populated by the caller in production; not this test's concern
esac

echo "── SECTION C: commit-verdict=yes never misroutes into the deterministic/merge path ──"

OUT=$(classify "yes" "yes" "some-branch" "ga-xxxxx" "some push error")
KIND="${OUT%%|*}"
[ "$KIND" = "transient" ] && ok "PR_COMMIT_VERDICT=yes (both verdicts yes) never misroutes into merge — a real, contentless plumbing failure stays transient/retryable" \
                          || bad "PR_COMMIT_VERDICT=yes -> expected transient, got '$KIND'"

echo "── SECTION D: PR_COMMIT_VERDICT entirely unset does not crash under set -u ──"

OUT=$(classify_unset)
RC=$?
KIND="${OUT%%|*}"
if [ "$RC" = "0" ] && [ "$KIND" = "transient" ]; then
  ok "PR_COMMIT_VERDICT never assigned this sweep (not even empty-string) does not abort under set -u — the \${PR_COMMIT_VERDICT:-} guard is real, not decorative"
else
  bad "unset PR_COMMIT_VERDICT crashed or misclassified under set -u (rc=$RC out='$OUT') — stderr: $(cat "$STDERR_FILE" 2>/dev/null)"
fi

echo "── SECTION E: both verdicts=no — content-verdict (the more severe, silent-data-loss case) takes priority ──"

OUT=$(classify "no" "no" "some-branch" "ga-xxxxx" "")
KIND="${OUT%%|*}"
case "$OUT" in
  merge\|*"3-way merge"*)
    ok "both verdicts=no -> CONFLICT_KIND=merge, content-verdict's message wins (documents/locks the chosen precedence — a future edit that flips this silently changes which incident class a reader sees first)" ;;
  *)
    bad "both verdicts=no -> expected content-verdict message to win, got '$OUT'" ;;
esac

echo "── SECTION F: regression guard — ga-10uqmi's own sibling case is untouched by this bead's elif insertion ──"

OUT=$(classify "" "no" "some-branch" "ga-xxxxx" "")
case "$OUT" in
  merge\|*"3-way merge"*"content silently diverged"*)
    ok "PR_COMMIT_VERDICT unset + PR_CONTENT_VERDICT=no still classifies exactly as ga-10uqmi shipped it (this bead's elif does not shadow it)" ;;
  *)
    bad "ga-10uqmi's own case drifted after this bead's edit — got '$OUT'" ;;
esac

echo "── SECTION G: drift guard — the fix actually lives in the elif branch and calls the ga-744kvc helper, not a hand-written duplicate ──"

WFBVX2_SPAN=$(awk '/elif \[ "\$\{PR_COMMIT_VERDICT:-\}" = "no" \]; then/{flag=1} flag{print} /^      else$/{if(flag && NR>1) exit}' "$DISPATCHER")
if [ -z "$WFBVX2_SPAN" ]; then
  bad "could not isolate the ga-wfbvx2 elif span for drift-checking"
else
  case "$WFBVX2_SPAN" in
    *'CONFLICT_KIND="merge"'*) ok "ga-wfbvx2 elif span sets CONFLICT_KIND=merge" ;;
    *) bad "ga-wfbvx2 elif span does not set CONFLICT_KIND=merge — got: $WFBVX2_SPAN" ;;
  esac
  case "$WFBVX2_SPAN" in
    *'_gate_push_skip_reason "$PR_COMMIT_VERDICT"'*) ok "ga-wfbvx2 elif span reuses _gate_push_skip_reason (ga-744kvc) rather than a second hand-written message" ;;
    *) bad "ga-wfbvx2 elif span does not call _gate_push_skip_reason — may have drifted into a hand-written duplicate" ;;
  esac
fi

echo "── SECTION H: acceptance criterion 2 (ga-wfbvx2) — bead cited only in the commit BODY, not the subject, is accepted ──"
# branch_bead_commit_verdict is the pure function BOTH the admission-time
# check (quality-gate-guard.sh Step 5b-pre, ga-pj5va) and this dispatcher's
# Step 4c share (identical 3-arg copy, drift-guarded by
# gate-guard-submission-time-coherence.selftest.sh Section 3b/3c) — proving
# it here against the copy THIS bead's fix depends on directly covers the
# acceptance criterion for both surfaces without re-testing guard.sh (this
# bead does not touch that file).
BODY_ONLY_MSG='chore: unrelated-looking subject line

This is a follow-up to the earlier work.
Fixes wa-500 as discussed in review.'
eq "bead cited ONLY in the body (never the subject) -> yes, not no" \
  "$(branch_bead_commit_verdict "1" "$BODY_ONLY_MSG" "wa-500")" "yes"

SUBJECT_CITES_OTHER_MSG='fix(ga-gjum0y): record the two scheduled-job OPT-IN decisions machine-readably

Related to wa-waxw8 as well.'
eq "acceptance criterion 1's negative control: subject+body cite OTHER beads only, never the target -> no (this is the exact wa-aoznq incident shape)" \
  "$(branch_bead_commit_verdict "1" "$SUBJECT_CITES_OTHER_MSG" "wa-aoznq")" "no"

echo "── SECTION I: real-git — the exact wa-aoznq incident shape, end to end through THIS bead's fix ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-wfbvx2-selftest.XXXXXX")"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

git -C "$TMPD" init -q -b main 2>/dev/null || { mkdir -p "$TMPD"; git -C "$TMPD" init -q; git -C "$TMPD" checkout -q -b main; }
git -C "$TMPD" config user.email "test@gascity.local"
git -C "$TMPD" config user.name "Test"
echo "base" > "$TMPD/f.txt"; git -C "$TMPD" add f.txt; git -C "$TMPD" commit -q -m "base"
BASE_SHA="$(git -C "$TMPD" rev-parse HEAD)"

git -C "$TMPD" branch aoznq-branch "$BASE_SHA"
git -C "$TMPD" checkout -q aoznq-branch
echo "opt-in" >> "$TMPD/f.txt"
git -C "$TMPD" commit -qam "fix(ga-gjum0y): record the two scheduled-job OPT-IN decisions machine-readably"
INCIDENT_TIP="$(git -C "$TMPD" rev-parse HEAD)"
git -C "$TMPD" checkout -q main

INCIDENT_COUNT="$(git -C "$TMPD" rev-list --count "${BASE_SHA}..${INCIDENT_TIP}")"
INCIDENT_MSGS="$(git -C "$TMPD" log --format='%B' "${BASE_SHA}..${INCIDENT_TIP}")"
INCIDENT_COMMIT_VERDICT="$(branch_bead_commit_verdict "$INCIDENT_COUNT" "$INCIDENT_MSGS" "wa-aoznq")"
eq "real-git: incident branch's own commit-verdict vs bead wa-aoznq" "$INCIDENT_COMMIT_VERDICT" "no"

# Content is fine in this reproduction (no actual data loss — only the
# message is wrong), matching the real incident: Mayor's fix was a subject
# rewrite with git diff = 0 lines, i.e. content_verdict was never the issue.
OUT=$(classify "$INCIDENT_COMMIT_VERDICT" "yes" "aoznq-branch" "wa-aoznq")
KIND="${OUT%%|*}"
if [ "$KIND" = "merge" ]; then
  ok "end-to-end: the real wa-aoznq commit shape now classifies as CONFLICT_KIND=merge (deterministic) instead of transient — this is what breaks the 19:46-20:28 / 4-round auto-rebase loop the bead documents"
else
  bad "end-to-end: real incident shape still classifies as '$KIND', not merge — the fix does not close the loop this bead exists to fix"
fi

rm -rf "$TMPD"
trap - EXIT

echo ""
echo "== gate-wfbvx2-commit-verdict-classify.selftest: PASS=$PASS FAIL=$FAIL =="
rm -f "$STDERR_FILE" 2>/dev/null || true
[ "$FAIL" -eq 0 ]

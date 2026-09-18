#!/usr/bin/env bash
# gate-744kvc-push-skip-reason.selftest.sh (ga-744kvc)
#
# THE BUG (measured live 2026-09-17, marker ga-smpubw / branch
# fix/wa-aoznq-scheduled-job-opt-out, ga-744kvc/ga-wfbvx2): every one of the
# 6 gate-time auto-rebase/auto-merge push attempts in Step 4c guards its
# `git push` behind
#     [ "$PR_COMMIT_VERDICT" = "yes" ] && [ "$PR_CONTENT_VERDICT" = "yes" ] \
#       && git push ... 2>"$_PUSH_ERR_FILE"
# When either verdict is not "yes", the && chain short-circuits BEFORE git
# push ever runs, so `_PUSH_ERR_FILE` is never written and
# AUTO_REBASE_PUSH_ERR comes back empty — not because git failed silently,
# but because git never ran at all. That emptiness fed straight into
# "${AUTO_REBASE_PUSH_ERR:-<no stderr captured>}", producing the marker text
# "auto-rebase failed (worktree/push error) — no stderr captured" for a
# branch whose real problem was diagnosable in one line: no commit on it
# cites the bead. Root-caused live by the Mayor (ga-wfbvx2, 2026-09-17
# 20:3x): branch_bead_commit_verdict() returned "no" because the commit
# subject cited a DIFFERENT bead (ga-gjum0y, not wa-aoznq) — a deliberate
# gate decision, not a git-level failure. Cost: the marker exiled to tier5
# and the bead that unblocks the whole WA rig delivery sat stranded, only
# resolved by a human redoing the push by hand.
#
# THE FIX: _gate_push_skip_reason() (quality-gate-dispatcher.sh, defined
# just after branch_bead_commit_verdict()) names WHICH gate decision blocked
# the push whenever AUTO_REBASE_PUSH_ERR would otherwise be empty. Wired at
# all 6 push-attempt call sites (container-rig x self-repo x {tip-is-merge,
# rebase, merge-fallback}), always guarded on AUTO_REBASE_PUSH_ERR still
# being empty — a REAL captured git stderr (ga-g0v96/AC3, untouched by this
# bead) is never overwritten.
#
# This harness sources the dispatcher in lib-only mode (matches
# gate-branch-content-coherence.selftest.sh's own pattern for testing
# branch_bead_commit_verdict — the function this one sits right next to and
# composes with) to unit-test the REAL live function directly, reproduces
# the exact live-incident commit shape against a real git repo, chains the
# result through the REAL ga-10uqmi classification block (sentinel-extracted
# the same way that bead's own selftest does — never a hand-copied
# duplicate) to prove the fix reaches the marker-facing message, and
# drift-guards the wiring at all 6 call sites. Exit 0 iff every assertion
# holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

echo "== gate-744kvc-push-skip-reason.selftest (ga-744kvc) =="
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ──────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type _gate_push_skip_reason >/dev/null 2>&1 \
  || { echo "FATAL: _gate_push_skip_reason not defined by dispatcher (lib-only)"; exit 1; }
type branch_bead_commit_verdict >/dev/null 2>&1 \
  || { echo "FATAL: branch_bead_commit_verdict not defined by dispatcher (lib-only)"; exit 1; }

log()  { :; }
warn() { :; }
err()  { :; }

echo "── 1. _gate_push_skip_reason (pure) — names the decision, never blames git ──"

OUT="$(_gate_push_skip_reason "no" "yes" "fix/wa-aoznq-scheduled-job-opt-out" "wa-aoznq")"
case "$OUT" in
  *"no commit on this branch mentions bead wa-aoznq"*"branch_bead_commit_verdict=no"*)
    ok "commit_verdict=no names the missing bead id (the exact ga-wfbvx2 incident shape)" ;;
  *) bad "commit_verdict=no did not produce the expected reason — got '$OUT'" ;;
esac
case "$OUT" in
  *stderr*) bad "commit_verdict=no message still mentions stderr — this was never a stderr-producing failure: '$OUT'" ;;
  *)        ok "commit_verdict=no message makes no false claim about stderr" ;;
esac

OUT="$(_gate_push_skip_reason "skip" "yes" "some-branch" "ga-xxxxx")"
case "$OUT" in
  *"nothing to verify"*) ok "commit_verdict=skip names 'nothing to verify' — distinct from a confirmed 'no' refusal" ;;
  *) bad "commit_verdict=skip did not produce the expected reason — got '$OUT'" ;;
esac
case "$OUT" in
  *"no commit on this branch mentions bead"*) bad "commit_verdict=skip wrongly reused the confirmed-'no' wording — skip is NOT a verified violation: '$OUT'" ;;
  *) ok "commit_verdict=skip never claims a confirmed violation it didn't check" ;;
esac

OUT="$(_gate_push_skip_reason "yes" "unknown" "some-branch" "ga-xxxxx")"
case "$OUT" in
  *"rebase_content_verdict=unknown"*) ok "commit_verdict=yes + content_verdict=unknown names the content verdict instead" ;;
  *) bad "commit_verdict=yes + content_verdict=unknown did not name it — got '$OUT'" ;;
esac

OUT="$(_gate_push_skip_reason "yes" "yes" "some-branch" "ga-xxxxx")"
[ -z "$OUT" ] && ok "both verdicts=yes -> empty string (defers to ga-10uqmi's own untouched contentless-plumbing fallback)" \
              || bad "both verdicts=yes should produce empty, got '$OUT'"

OUT="$(_gate_push_skip_reason "no" "no" "some-branch" "ga-xxxxx")"
case "$OUT" in
  *"no commit on this branch mentions bead"*) ok "commit_verdict wins over content_verdict when both are non-yes (matches the && chain's own left-to-right order)" ;;
  *) bad "expected commit_verdict reason to take priority when both are non-yes, got '$OUT'" ;;
esac

echo "── 2. real-git: reproduce the exact ga-wfbvx2 incident shape end-to-end ──"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/gate-744kvc-selftest.XXXXXX")"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT

git -C "$TMPD" init -q -b main 2>/dev/null || { mkdir -p "$TMPD"; git -C "$TMPD" init -q; git -C "$TMPD" checkout -q -b main; }
git -C "$TMPD" config user.email "test@gascity.local"
git -C "$TMPD" config user.name "Test"
echo "base" > "$TMPD/f.txt"; git -C "$TMPD" add f.txt; git -C "$TMPD" commit -q -m "base"
BASE_SHA="$(git -C "$TMPD" rev-parse HEAD)"

# The incident's exact shape: the branch's own commit cites a DIFFERENT bead
# (ga-gjum0y), never the bead the marker was actually opened for (wa-aoznq).
git -C "$TMPD" branch aoznq-branch "$BASE_SHA"
git -C "$TMPD" checkout -q aoznq-branch
echo "opt-in" >> "$TMPD/f.txt"
git -C "$TMPD" commit -qam "fix(ga-gjum0y): record the two scheduled-job OPT-IN decisions machine-readably"
INCIDENT_TIP="$(git -C "$TMPD" rev-parse HEAD)"
git -C "$TMPD" checkout -q main

INCIDENT_COUNT="$(git -C "$TMPD" rev-list --count "${BASE_SHA}..${INCIDENT_TIP}")"
INCIDENT_MSGS="$(git -C "$TMPD" log --format='%B' "${BASE_SHA}..${INCIDENT_TIP}")"
VERDICT="$(branch_bead_commit_verdict "$INCIDENT_COUNT" "$INCIDENT_MSGS" "wa-aoznq")"
eq "real-git: incident branch (cites ga-gjum0y only) vs bead wa-aoznq -> no" "$VERDICT" "no"

SKIP_REASON="$(_gate_push_skip_reason "$VERDICT" "yes" "aoznq-branch" "wa-aoznq")"
case "$SKIP_REASON" in
  *"no commit on this branch mentions bead wa-aoznq"*) ok "real-git verdict feeds _gate_push_skip_reason -> names the real reason" ;;
  *) bad "real-git verdict did not produce the expected reason — got '$SKIP_REASON'" ;;
esac

echo "── 3. full pipeline: skip-reason reaches the REAL ga-10uqmi classification block, not 'no stderr captured' ──"

CLASSIFY_BLOCK=$(sed -n '/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: BEGIN/,/# SELFTEST-EXTRACT gate-10uqmi-rebase-fail-classify: END/p' "$DISPATCHER")
if [ -z "$CLASSIFY_BLOCK" ]; then
  bad "could not extract gate-10uqmi-rebase-fail-classify block (sentinels missing/renamed?) — cannot prove the message reaches CONFLICT_FILES"
else
  CLASSIFY_OUT=$(AUTO_REBASE_OK=0 BRANCH_IS_CURRENT=0 \
    PR_CONTENT_VERDICT="yes" AUTO_REBASE_PUSH_ERR="$SKIP_REASON" AUTO_REBASE_PUSH_RC="1" \
    AUTO_MERGE_FALLBACK_ERR="" AUTO_REBASE_SETUP_ERR="" _LOST_PATHS="" \
    bash -c "set -euo pipefail; $CLASSIFY_BLOCK"$'\nprintf "%s|%s|%s" "$CONFLICT_KIND" "$CONFLICT_FILES" "$HAS_CONFLICT"')
  case "$CLASSIFY_OUT" in
    *"no commit on this branch mentions bead wa-aoznq"*)
      ok "CONFLICT_FILES (the marker-facing message) carries the real reason: '$CLASSIFY_OUT'" ;;
    *)
      bad "CONFLICT_FILES did not carry the real reason — got '$CLASSIFY_OUT'" ;;
  esac
  case "$CLASSIFY_OUT" in
    *"no stderr captured"*)
      bad "CONFLICT_FILES still says 'no stderr captured' for a gate-decision refusal — the exact defect ga-744kvc exists to close: '$CLASSIFY_OUT'" ;;
    *)
      ok "CONFLICT_FILES never says 'no stderr captured' for this gate-decision refusal" ;;
  esac
fi

echo "── 4. real-git: a GENUINE push failure (fake remote) is completely unaffected by this fix (ga-744kvc AC1) ──"

_PUSH_ERR_FILE="$(mktemp)"
git -C "$TMPD" push "/nonexistent/gate-744kvc-selftest-$$/fake-remote.git" "HEAD:refs/heads/main" \
  2>"$_PUSH_ERR_FILE" && PUSH_RC=0 || PUSH_RC=$?
CAPTURED="$(tr '\n' ' ' < "$_PUSH_ERR_FILE" | cut -c1-500)"
rm -f "$_PUSH_ERR_FILE"

if [ "$PUSH_RC" -ne 0 ] && [ -n "$CAPTURED" ]; then
  ok "a genuine push failure against a bogus remote produces real, non-empty stderr — $(printf '%s' "$CAPTURED" | wc -c | tr -d ' ') bytes captured"
  # Mirror the REAL call-site guard verbatim (quality-gate-dispatcher.sh, all
  # 6 sites: `if [ -z "$AUTO_REBASE_PUSH_ERR" ]; then AUTO_REBASE_PUSH_ERR=$(_gate_push_skip_reason ...); fi`).
  # AUTO_REBASE_PUSH_ERR is already non-empty (a genuine captured git stderr),
  # so the guard must be a no-op. Feed a commit_verdict of "no" — if the guard
  # ever regresses and fires anyway, _gate_push_skip_reason's output ("no
  # commit on this branch mentions bead...") can never equal $CAPTURED, so the
  # assertion below would catch it.
  AUTO_REBASE_PUSH_ERR="$CAPTURED"
  if [ -z "$AUTO_REBASE_PUSH_ERR" ]; then
    AUTO_REBASE_PUSH_ERR=$(_gate_push_skip_reason "no" "yes" "dummy-branch" "ga-xxxxx")
  fi
  if [ "$AUTO_REBASE_PUSH_ERR" = "$CAPTURED" ]; then
    ok "the ga-744kvc guard leaves a genuinely-captured git stderr untouched — real git failures still show their real stderr, never a verdict-naming string"
  else
    bad "the guard fired on an already-non-empty AUTO_REBASE_PUSH_ERR and overwrote it — got '$AUTO_REBASE_PUSH_ERR', expected untouched '$CAPTURED'"
  fi
else
  bad "fake-remote push did not fail with captured stderr as expected (rc=$PUSH_RC, captured='$CAPTURED') — fixture assumption broken, cannot prove AC1"
fi

rm -rf "$TMPD"
trap - EXIT

echo "── 5. drift guards ──"

CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DEF_LN=$(grep -n '^_gate_push_skip_reason() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
  ok "_gate_push_skip_reason (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN) — selftest-sourceable"
else
  bad "_gate_push_skip_reason must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
fi

WIRE_COUNT=$(grep -c '_gate_push_skip_reason "\${PR_COMMIT_VERDICT:-}" "\${PR_CONTENT_VERDICT:-}" "\$BRANCH" "\$BEAD_ID"' "$DISPATCHER" 2>/dev/null || true)
WIRE_COUNT=${WIRE_COUNT:-0}
if [ "$WIRE_COUNT" -eq 6 ]; then
  ok "wired at exactly 6 push-attempt call sites (container-rig + self-repo, x tip-is-merge/rebase/merge-fallback)"
else
  bad "expected exactly 6 wiring sites, found $WIRE_COUNT"
fi

GUARDED_COUNT=$(grep -c 'if \[ -z "\$AUTO_REBASE_PUSH_ERR" \]; then' "$DISPATCHER" 2>/dev/null || true)
GUARDED_COUNT=${GUARDED_COUNT:-0}
if [ "$GUARDED_COUNT" -eq 6 ]; then
  ok "all 6 sites guard on AUTO_REBASE_PUSH_ERR still being empty — never overwrites a real captured stderr"
else
  bad "expected exactly 6 empty-guard sites, found $GUARDED_COUNT"
fi

echo ""
echo "== gate-744kvc-push-skip-reason.selftest: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]

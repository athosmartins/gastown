#!/usr/bin/env bash
# gate-guard-gap3-external-pr-ref-capture.selftest.sh — functional test for
# ga-jto05 GAP-3's PR-URL extraction.
#
# Step 0c.3's EXT_PR_REF jq program lives inline inside the `for EXT_ID in
# $EXT_IDS; do ... done` sweep loop, not in a standalone function — same
# constraint documented in gate-guard-gap2-sling-id-capture.selftest.sh and
# gate-guard-gap1-content-merge-check.selftest.sh for sibling sweep code in
# this same file: it is not reachable via GATE_GUARD_LIB_ONLY=1 sourcing. So
# this harness (1) EXTRACTS the live jq program text verbatim from the source
# (tracks the real code, not a hand-duplicated copy that could silently
# drift) and (2) executes it against realistic bd-show --include-comments
# fixtures shaped like the real ones on ga-yp9r8/ga-ahnxx/ga-hqchm.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate-guard GAP-3 external-PR-ref jq capture() test (ga-jto05) ──"

if [ ! -f "$GUARD" ]; then
  bad "quality-gate-guard.sh not found next to selftest at $GUARD"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
fi

# extract_ext_pr_ref_jq_program <file> — pulls the jq program body (the lines
# between the `EXT_PR_REF=$(echo "$EXT_SHOW" | jq -r '` opener and the
# `' 2>/dev/null | head -1 || echo "")` closer) verbatim out of <file>.
# Anchored on stable literal substrings via awk's index(), not a regex, since
# the surrounding shell is full of literal $ and quote characters.
extract_ext_pr_ref_jq_program() {
  local file="$1"
  awk '
    index($0, "EXT_PR_REF=$(echo \"$EXT_SHOW\" | jq -r '"'"'") > 0 { grabbing=1; next }
    grabbing && index($0, "'"'"' 2>/dev/null | head -1") > 0 { grabbing=0 }
    grabbing { print }
  ' "$file"
}

echo "── 1. live source carries the expected EXT_PR_REF jq program ──"
LIVE_PROGRAM="$(extract_ext_pr_ref_jq_program "$GUARD")"
if [ -z "$LIVE_PROGRAM" ]; then
  bad "could not extract the EXT_PR_REF jq program from $GUARD — anchors drifted?"
  echo
  echo "── results: $PASS passed, $FAIL failed ──"
  exit 1
else
  ok "extracted EXT_PR_REF jq program from live source"
fi

echo "── 2. live jq program correctly extracts owner/repo + PR number ──"

# Real fixture shape from ga-yp9r8: multi-line comment, PR URL embedded in
# prose, wrapped across a line break in the source text itself.
FIXTURE1='{
  "comments": [
    {"created_at":"2026-08-05T19:27:19Z","text":"Pilot dispatched builder '"'"'gastown.dog'"'"' at 2026-08-05T19:27:02Z (tier=bug/tech-debt, lane=small, rig=gascity).\nSling task bead: ga-kdoqn\nBuilder doctrine: fix bug -> /gate-done -> autonomous gate+delivery -> bead closed."},
    {"created_at":"2026-08-05T20:16:21Z","text":"Fix submitted: PR https://github.com/gastownhall/beads/pull/5369 against\ngastownhall/beads (fork athosmartins/beads, branch\nfix/ga-yp9r8-comment-singular-id-validation, commit ba7ff7189)."}
  ]
}'
RESULT1="$(echo "$FIXTURE1" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ "$RESULT1" = "gastownhall/beads 5369" ] && ok "extracted 'gastownhall/beads 5369' from the real ga-yp9r8 comment shape" \
  || bad "expected 'gastownhall/beads 5369', got '$RESULT1'"

# Newest-first: a bead re-dispatched after an earlier abandoned PR must yield
# the MOST RECENT PR reference, not the first one ever posted.
FIXTURE2='{
  "comments": [
    {"created_at":"2026-07-20T09:00:00Z","text":"PR https://github.com/gastownhall/beads/pull/1111 opened."},
    {"created_at":"2026-07-26T13:13:00Z","text":"First PR abandoned. Reopened: PR https://github.com/gastownhall/beads/pull/2222 against gastownhall/beads."}
  ]
}'
RESULT2="$(echo "$FIXTURE2" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ "$RESULT2" = "gastownhall/beads 2222" ] && ok "extracted the MOST RECENT PR ref (2222, not the stale 1111) — sort_by+reverse honored" \
  || bad "expected 'gastownhall/beads 2222', got '$RESULT2'"

# Single-comment real fixture (ga-658cg's re-verification comment on ga-yp9r8).
FIXTURE3='{"comments":[{"created_at":"2026-08-06T11:09:54Z","text":"gh pr view 5369 --repo gastownhall/beads --json state,mergedAt,mergeCommit,reviewDecision,mergeable,mergeStateStatus\n  -> state=OPEN, mergeStateStatus=CLEAN. See PR https://github.com/gastownhall/beads/pull/5369 for detail."}]}'
RESULT3="$(echo "$FIXTURE3" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ "$RESULT3" = "gastownhall/beads 5369" ] && ok "extracted from a single realistic re-verification comment" \
  || bad "expected 'gastownhall/beads 5369', got '$RESULT3'"

# No PR URL at all -> must resolve empty, not error, not garbage.
FIXTURE4='{"comments":[{"created_at":"2026-07-26T13:13:00Z","text":"unrelated comment, no PR reference"}]}'
RESULT4="$(echo "$FIXTURE4" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ -z "$RESULT4" ] && ok "no PR URL in comments -> empty result (genuine no-match, not an error)" \
  || bad "expected empty for a comment set with no PR reference, got '$RESULT4'"

# No comments at all.
FIXTURE5='{"comments":[]}'
RESULT5="$(echo "$FIXTURE5" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ -z "$RESULT5" ] && ok "empty comments array -> empty result" \
  || bad "expected empty for zero comments, got '$RESULT5'"

# Missing comments key entirely (bd show without --include-comments shape).
FIXTURE6='{}'
RESULT6="$(echo "$FIXTURE6" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ -z "$RESULT6" ] && ok "missing 'comments' key -> empty result (// [] fallback honored)" \
  || bad "expected empty for missing comments key, got '$RESULT6'"

# A repo/owner containing a hyphen and dot — realistic GitHub naming.
FIXTURE7='{"comments":[{"created_at":"2026-08-06T00:00:00Z","text":"PR https://github.com/some-org/my.repo-name/pull/42 opened."}]}'
RESULT7="$(echo "$FIXTURE7" | jq -r "$LIVE_PROGRAM" 2>/dev/null | head -1)"
[ "$RESULT7" = "some-org/my.repo-name 42" ] && ok "handles hyphen/dot in owner and repo names" \
  || bad "expected 'some-org/my.repo-name 42', got '$RESULT7'"

echo "── 3. sanity: quality-gate-guard.sh still parses cleanly ──"
if bash -n "$GUARD" 2>/dev/null; then
  ok "quality-gate-guard.sh parses cleanly (bash -n)"
else
  bad "quality-gate-guard.sh FAILED bash -n"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

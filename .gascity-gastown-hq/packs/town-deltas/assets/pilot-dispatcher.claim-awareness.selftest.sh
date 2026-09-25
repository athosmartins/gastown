#!/usr/bin/env bash
# pilot-dispatcher.claim-awareness.selftest.sh
#
# Regression guard for ga-c8jimk: the Opus 5.1 multiagent guide's advice to tell
# every dispatched agent its time/token budget and when to report — an agent with
# no sense of a deadline either stops too early or runs forever. Before this fix,
# neither DISPATCH_TASK heredoc (bug-tier or story-tier) said anything about the
# claim's lifetime, so a builder had no way to know that going quiet for a while
# is fine as long as it stays live or commits, nor what to do before a long gap.
#
# The real mechanism (verified against scripts/inflight-reclaim-guard.py's
# reclaim_decision(), not assumed): RECLAIM_TTL = 1500s = 25min, and it only
# fires when BOTH has_recent_branch AND has_live_session are false continuously
# — either one alone keeps the claim safe. Lane (MAX_SMALL/MAX_BIG) is a
# concurrency cap, not a time budget — there is no per-lane deadline in this
# file. CLAIM_AWARENESS_BLOCK is computed once in dispatch_one() and shared by
# both heredocs (same DRY pattern as DOCTRINE_BLOCK/WORKTREE_DIRECTIVE).
#
# This test extracts the REAL assignment from the dispatcher (never a copy) and
# evaluates it against fixture values, plus greps both heredocs to confirm the
# block is actually referenced in each (not just defined and orphaned).
set -u
SRC="$(cd "$(dirname "$0")" && pwd)/pilot-dispatcher.sh"
[ -r "$SRC" ] || { echo "FATAL: cannot read $SRC"; exit 2; }

FAILS=0
ok()  { echo "  ok   $1"; }
bad() { echo "  FAIL $1"; FAILS=$((FAILS+1)); }

echo "Scenario: both DISPATCH_TASK heredocs reference \$CLAIM_AWARENESS_BLOCK (not just defined and orphaned)"
_heredoc_count=$(grep -c '^\$CLAIM_AWARENESS_BLOCK$' "$SRC")
[ "$_heredoc_count" -eq 2 ] \
  && ok "\$CLAIM_AWARENESS_BLOCK referenced exactly twice (bug-tier + story-tier heredocs)" \
  || bad "\$CLAIM_AWARENESS_BLOCK referenced $_heredoc_count time(s), expected 2 — a heredoc is missing the block or it was duplicated"

echo "Scenario: extract the real CLAIM_AWARENESS_BLOCK assignment (shipped code, not a copy)"
SNIP="$(awk '/^  local CLAIM_AWARENESS_BLOCK$/{f=1}
             f{print}
             /Never just stop without a trace\."$/{exit}' "$SRC")"
case "$SNIP" in
  *CLAIM_AWARENESS_BLOCK=*) ok "extracted the assignment (${#SNIP} chars)" ;;
  *) echo "FATAL: could not extract CLAIM_AWARENESS_BLOCK — did it move/rename?"; exit 2 ;;
esac

# _check_fixture <lane> <max_small> <max_big> <bead_city> <story_id> — evals the
# real extracted assignment with these values in a proper function scope (so the
# snippet's own "local CLAIM_AWARENESS_BLOCK" is valid, not a bare-subshell error)
# and checks the interpolated result. Echoes ok/FAIL lines; returns the fail count.
_check_fixture() {
  local LANE="$1" MAX_SMALL="$2" MAX_BIG="$3" STORY_BEAD_CITY="$4" STORY_ID="$5"
  eval "$SNIP"
  local _fails=0
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -q "The $LANE lane" \
    && ok "lane name interpolated ($LANE)" || { bad "lane name not interpolated"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -q "up to $MAX_SMALL running at once" \
    && ok "MAX_SMALL interpolated ($MAX_SMALL)" || { bad "MAX_SMALL not interpolated"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -q "up to $MAX_BIG)" \
    && ok "MAX_BIG interpolated ($MAX_BIG)" || { bad "MAX_BIG not interpolated"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -q "25 continuous minutes" \
    && ok "states the 25min reclaim-guard window" || { bad "reclaim TTL not stated"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -q "no live session AND no" \
    && printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -qi "recent commit" \
    && ok "explains both real reset conditions (live session, recent commit)" \
    || { bad "reset conditions not explained"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -qF "bd -C \"$STORY_BEAD_CITY\" comment \"$STORY_ID\"" \
    && ok "before-you-go-quiet instruction uses the real bd comment invocation" \
    || { bad "missing concrete before-you-go-quiet instruction"; _fails=1; }
  printf '%s' "$CLAIM_AWARENESS_BLOCK" | grep -qE '\$(LANE|MAX_SMALL|MAX_BIG|STORY_BEAD_CITY|STORY_ID)\b' \
    && { bad "a variable was left unexpanded — literal \$VAR leaked into the builder-facing text"; _fails=1; } \
    || ok "no unexpanded variables leaked"
  return "$_fails"
}

echo "Scenario: real interpolation against fixture values (small lane)"
# _check_fixture runs as a normal function call (not a subshell), so it shares
# this shell's FAILS variable — bad()'s own increment already propagates here.
# Do NOT also add its return value, or every failure would be counted twice.
_check_fixture "small" "5" "2" "/tmp/ga-c8jimk-selftest-fixture" "ga-selftest1"

echo "Scenario: real interpolation against fixture values (big lane, different STORY_ID/city — mutation control)"
_check_fixture "big" "5" "2" "wa" "wa-selftest2"

echo ""
if [ "$FAILS" -eq 0 ]; then echo "SELFTEST PASS"; exit 0
else echo "SELFTEST FAIL ($FAILS)"; exit 1
fi

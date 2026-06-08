#!/usr/bin/env bash
# gate-reviewer-orphan-reap.selftest.sh — Prove the ga-zl277 orphaned-reviewer
# cleanup logic in isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-zl277: failed/timed-out gate runs left gate-reviewer sessions ASLEEP
# but not closed. The dispatcher closed reviewers ONLY at Step 9 (the
# success/timeout path), so a mid-loop spawn-abort (`exit 1`) or any signal/
# timeout kill orphaned the already-spawned reviewer sessions. They accumulate
# against the gate-reviewer template's max_active_sessions=6 budget; once full,
# subsequent runs spawn fewer than 3 reviewers and fail too (vicious cycle).
#
# The fix has two layers:
#   A. An EXIT/signal trap (cleanup_reviewer_sessions) closes whatever is in
#      SESSION_IDS exactly once, from one place, so EVERY abort path frees its
#      cap slots — not just Step 9.
#   B. A startup janitor (Step 0a-2) reaps gate-reviewer sessions that are
#      NON-active, NON-attached, and older than REVIEWER_SESSION_TTL_MINUTES.
#      This backstops SIGKILL/OOM/launchd-timeout deaths that no trap can catch.
#      The TTL > verdict-timeout means a reaped session cannot belong to a live
#      sibling run (concurrency-safe).
#
# This harness unit-tests the PURE reap/keep decision, then DRIFT-GUARDS the
# real dispatcher so a future refactor that drops the trap, the shared cleanup
# helper, or the TTL janitor fails loudly. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── The EXACT pure decision the dispatcher uses (mirror of
#    reviewer_session_should_reap). echo "reap" iff the session is a NON-active,
#    NON-attached gate-reviewer older than the TTL, else "keep".
reviewer_session_should_reap() {
  local state="$1" attached="$2" age="$3" ttl="$4"
  case "$age" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  case "$ttl" in ''|*[!0-9]*) echo "keep"; return 0 ;; esac
  [ "$attached" = "true" ] && { echo "keep"; return 0; }
  [ "$state" = "active" ]  && { echo "keep"; return 0; }
  if [ "$age" -gt "$ttl" ]; then echo "reap"; else echo "keep"; fi
}

TTL=65   # default = VERDICT_TIMEOUT_MINUTES(45) + 20 margin

echo "── 1. NEVER reap a live (active) reviewer, regardless of age ──"
eq "active + young"        "$(reviewer_session_should_reap active false 5   "$TTL")" "keep"
eq "active + old"          "$(reviewer_session_should_reap active false 600 "$TTL")" "keep"

echo "── 2. NEVER reap an attached reviewer, regardless of age/state ──"
eq "attached + asleep old" "$(reviewer_session_should_reap asleep true 600 "$TTL")"  "keep"

echo "── 3. NEVER reap a young asleep reviewer (could be a live sibling's, or"
echo "      a just-spawned session in its wake→nudge window) ──"
eq "asleep + age 0"        "$(reviewer_session_should_reap asleep false 0  "$TTL")"  "keep"
eq "asleep + just under"   "$(reviewer_session_should_reap asleep false 64 "$TTL")"  "keep"
eq "asleep + at TTL (not >)" "$(reviewer_session_should_reap asleep false 65 "$TTL")" "keep"

echo "── 4. REAP an old, asleep, unattached reviewer (a true orphan) ──"
eq "asleep + just over"    "$(reviewer_session_should_reap asleep false 66  "$TTL")" "reap"
eq "drained + way over"    "$(reviewer_session_should_reap asleep false 600 "$TTL")" "reap"

echo "── 5. junk inputs fail SAFE (keep — never reap on a parse error) ──"
eq "empty age"             "$(reviewer_session_should_reap asleep false ''   "$TTL")" "keep"
eq "non-numeric age"       "$(reviewer_session_should_reap asleep false 'NaN' "$TTL")" "keep"
eq "empty ttl"             "$(reviewer_session_should_reap asleep false 600  '')"     "keep"

echo "── 6. drift-guard: the real dispatcher still has the cleanup TRAP (A) ──"
has "$GATE" 'cleanup_reviewer_sessions\(\)'                "shared cleanup helper is defined"
has "$GATE" 'trap cleanup_reviewer_sessions EXIT'          "EXIT trap installs the cleanup helper"
has "$GATE" "trap 'exit 143' TERM"                         "TERM is trapped (launchd stop/reload)"
has "$GATE" '_gate_cleanup_done'                           "cleanup is idempotent (guard flag)"
# Step 9 must route through the shared helper, NOT re-open a raw close loop that
# the abort paths would bypass.
has "$GATE" 'Step 9: Close reviewer sessions'              "Step 9 marker present"

echo "── 7. drift-guard: the real dispatcher still has the TTL janitor (B) ──"
has "$GATE" 'reviewer_session_should_reap\(\)'             "pure reap decision is defined"
has "$GATE" 'REVIEWER_SESSION_TTL_MINUTES'                 "reviewer-session TTL is configured"
has "$GATE" 'Step 0a-2'                                    "startup janitor block present"
has "$GATE" 'select\(.template=="gate-reviewer"\)'         "janitor filters to gate-reviewer template"
has "$GATE" 'session close "\$R_ID"'                       "janitor closes the orphaned session"

echo "── 8. drift-guard: TTL default exceeds the verdict timeout (concurrency-safe) ──"
# A reaped session must be older than any live run could legitimately keep one
# open. The default TTL is verdict-timeout + a positive margin.
has "$GATE" 'REVIEWER_SESSION_TTL_MINUTES:-\$\(\(VERDICT_TIMEOUT_MINUTES \+ [0-9]+\)\)' \
  "TTL default = VERDICT_TIMEOUT_MINUTES + margin"

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0

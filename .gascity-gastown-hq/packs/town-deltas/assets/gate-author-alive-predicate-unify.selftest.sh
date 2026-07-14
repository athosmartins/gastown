#!/usr/bin/env bash
# gate-author-alive-predicate-unify.selftest.sh (ga-ipf6)
#
# ga-ipf6: quality-gate-dispatcher.sh had TWO independent author-liveness
# predicates that were supposed to agree and didn't:
#   - AUTHOR_ALIVE (rebase path, ~L2490) — BROKEN: matched only
#     .alias/.name/.agent. AUTHOR is recorded in session_name form
#     (<agent>-<sessionid>, e.g. peter-wa-ga2gnr) and .agent is not a real
#     field on `gc session list` entries (always null), so this predicate
#     NEVER matched a real author — 100% false-dead on the rebase path.
#   - FAIL_AUTHOR_ALIVE (needs-fix path, ~L4365, the ga-jyox predicate) —
#     CORRECT: matches session_name/name/alias/id/agent_name and filters
#     closed sessions.
#   ga-jyox (an earlier fix) corrected only the FAIL call site and left the
#   rebase call site broken — fixed one call site, not the other. A live
#   author hitting a large rebase (main > GATE_REBASE_AHEAD_MAX ahead) got
#   misread as dead, took the dead-author path, burned MAX_REBASE_ATTEMPTS
#   retries that were IMPOSSIBLE to pass (auto-rebase already outside its
#   envelope), and permanently parked at gate-status:error +
#   gate:needs-human while main diverged further — a live author's work
#   rotted for no reason (marker ga-wisp-w816sz / peter-wa-ga2gnr, 2026-07-14).
#
# FIX: both call sites now delegate to a single helper, author_is_alive
# <author>, using the canonical (session_name/name/alias/id/agent_name,
# closed-filtered) predicate. One predicate, one place it can drift.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL author_is_alive helper (mocked `gc session list`, no
# live Dolt/gc/launchd), then drift-guards that BOTH call sites are wired to
# it (not a re-inlined, re-divergeable predicate).
#
# Mutation-tested during development (ga-ipf6 acceptance criterion 3):
# temporarily reverting author_is_alive's body to the old broken
# alias/name/agent-only predicate turned test 1 below red — confirms the
# test actually exercises the fixed code, not a tautology.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type author_is_alive >/dev/null 2>&1 \
  || { echo "FATAL: author_is_alive not defined by dispatcher (ga-ipf6 missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── Mock `gc session list --json` ────────────────────────────────────────────
# Shapes pulled from ga-ipf6's positive control plus a real `gc session list
# --json` sample: session_name is the format AUTHOR is actually recorded in;
# agent_name is a real field distinct from the nonexistent .agent; alias/name
# are the short crew form WITHOUT the session-id suffix.
MOCK_SESS_JSON='[
  {"session_name":"peter-wa-ga2gnr","alias":"peter-wa","name":"peter-wa","agent_name":null,"id":"ga2gnr","closed":false},
  {"session_name":"thies-wa-gam257","alias":"thies-wa","name":"thies-wa","agent_name":null,"id":"gam257","closed":false},
  {"session_name":"batista-wa-gawispc8tmbq","alias":"batista-wa","name":"batista-wa","agent_name":null,"id":"gawispc8tmbq","closed":false},
  {"session_name":"wa-worker-adhoc-drained01","alias":"wa-worker","name":"wa-worker","agent_name":null,"id":"drained01","closed":true}
]'
gc() {
  case " $* " in
    *" session list "*) echo "$MOCK_SESS_JSON" ;;
    *) : ;;
  esac
  return 0
}
GC_CITY="/fake/hq"

# ── 1. THE bug: live author in session_name form → alive ─────────────────────
# Exact shape from ga-ipf6's positive control (peter-wa-ga2gnr). Pre-fix, the
# rebase-path predicate never checked .session_name and always returned 0
# here (100% false-dead).
echo "── 1. author_is_alive: live author, session_name form ──"
eq "peter-wa-ga2gnr (live, session_name form) → alive" \
  "$(author_is_alive "peter-wa-ga2gnr")" "1"
eq "thies-wa-gam257 (live, session_name form) → alive" \
  "$(author_is_alive "thies-wa-gam257")" "1"

# ── 2. genuinely dead author → 0 ──────────────────────────────────────────────
echo "── 2. author_is_alive: genuinely dead author ──"
eq "wa-worker-adhoc-drained01 (closed:true) → dead" \
  "$(author_is_alive "wa-worker-adhoc-drained01")" "0"
eq "no-such-session-anywhere → dead" \
  "$(author_is_alive "no-such-session-anywhere")" "0"

# ── 3. empty author → 0 (fail-safe, no crash) ────────────────────────────────
echo "── 3. author_is_alive: empty author ──"
eq "empty author → dead (fail-safe)" \
  "$(author_is_alive "")" "0"

# ── 4. short alias form still matches (name/alias honored, not just session_name)
echo "── 4. author_is_alive: short alias form ──"
eq "batista-wa (short alias, live session present) → alive" \
  "$(author_is_alive "batista-wa")" "1"

# ── 5. drift guard: BOTH call sites wired to the unified helper ─────────────
echo "── 5. drift guard: rebase AND needs-fix paths both call author_is_alive ──"
if grep -qF 'AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")' "$DISPATCHER"; then
  ok "rebase-path AUTHOR_ALIVE calls author_is_alive"
else
  bad "rebase-path AUTHOR_ALIVE does NOT call author_is_alive — still the broken inline predicate?"
fi
if grep -qF 'FAIL_AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")' "$DISPATCHER"; then
  ok "needs-fix-path FAIL_AUTHOR_ALIVE calls author_is_alive"
else
  bad "needs-fix-path FAIL_AUTHOR_ALIVE does NOT call author_is_alive — re-diverged from rebase path?"
fi

# ga-jyox non-regression: gate_fail_assignee_action (the ga-jyox decision
# function) must still exist and still be fed by FAIL_AUTHOR_ALIVE — this fix
# only changes HOW FAIL_AUTHOR_ALIVE is computed, never the ga-jyox
# keep/clear decision built on top of it.
echo "── 6. ga-jyox non-regression: decision function still wired to FAIL_AUTHOR_ALIVE ──"
type gate_fail_assignee_action >/dev/null 2>&1 \
  && ok "gate_fail_assignee_action (ga-jyox) still present — unaffected by this fix" \
  || bad "gate_fail_assignee_action MISSING — ga-jyox regressed?"
if grep -qF 'GATE_FAIL_ASSIGNEE_ACTION=$(gate_fail_assignee_action "$AUTHOR" "$FAIL_AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "ga-jyox decision still wired to FAIL_AUTHOR_ALIVE"
else
  bad "ga-jyox wiring to FAIL_AUTHOR_ALIVE missing/changed"
fi
eq "ga-jyox: live named-crew author + alive → keep (unaffected by this fix)" \
  "$(gate_fail_assignee_action "thies-wa-gam257" "$(author_is_alive "thies-wa-gam257")")" \
  "keep"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-author-alive-predicate-unify selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-author-alive-predicate-unify selftest"
  exit 1
fi

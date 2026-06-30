#!/usr/bin/env bash
# Selftest for gatefix-deadworker-recovery.sh — proves the pure decision in isolation.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
J="$SELF_DIR/gatefix-deadworker-recovery.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3] got [$2]"; fi; }

GATEFIX_RECOVERY_LIB_ONLY=1 source "$J" || { echo "FATAL: cannot source lib-only"; exit 1; }
type gatefix_recovery_decide >/dev/null 2>&1 || { echo "FATAL: decide fn missing"; exit 1; }

LIVE="wa-worker-adhoc-LIVE mila-wa oracle-wa"

echo "── gatefix_recovery_decide ──"
# recover ONLY when: needs-fix=1, not in-flight, non-empty worker, worker NOT live
eq "dead worker + needs-fix + not-inflight → RECOVER" "$(gatefix_recovery_decide 1 0 wa-worker-adhoc-DEAD "$LIVE")" "recover"
eq "live worker → skip"                               "$(gatefix_recovery_decide 1 0 mila-wa "$LIVE")"             "skip:worker-still-live"
eq "in-flight (active rework) → skip"                 "$(gatefix_recovery_decide 1 1 wa-worker-adhoc-DEAD "$LIVE")" "skip:in-flight-active-rework"
eq "no recorded worker → skip (cannot prove dead)"    "$(gatefix_recovery_decide 1 0 '' "$LIVE")"                  "skip:no-recorded-worker"
eq "not needs-fix → skip"                             "$(gatefix_recovery_decide 0 0 wa-worker-adhoc-DEAD "$LIVE")" "skip:not-needs-fix"
# the live-match is exact-token (a dead worker whose name is a substring of a live one is NOT spared)
eq "substring of a live name is NOT 'live' → recover" "$(gatefix_recovery_decide 1 0 wa-worker "$LIVE")"           "recover"

echo ""
echo "── drift-guard: live wiring present ──"
grep -q 'gc session list --json' "$J" && ok "reads gc session roster" || bad "no roster read"
grep -q 'empty_roster_failsafe' "$J" && ok "FAIL-SAFE on empty roster (never reaps blind)" || bad "no empty-roster failsafe"
grep -q 'worktree remove --force' "$J" && ok "reaps orphan worktree" || bad "no worktree reap"
grep -q 'rev-parse --short' "$J" && ok "logs branch SHA before delete (recoverable)" || bad "no SHA logging"

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1

#!/usr/bin/env bash
# gate-dup-run-guard.selftest.sh — Prove the ga-dupnv fixes in isolation, with NO
# live Dolt/gc/launchd:
#
#   BUG 1 (DUPLICATE-RUN): a marker was claimed twice for the SAME branch
#   (crew/thies/wa-86jr-reland) — the dispatcher died mid-run leaving the marker
#   gate-status:dispatching, Step 0a re-queued it, and a later sweep re-claimed it
#   and spawned a SECOND gate-run (ga-wisp-4wa97q). The duplicate hit the verdict
#   TIMEOUT and wrote a terminal FAIL onto wa-86jr while the healthy sibling
#   (ga-wisp-mzxm9h) still had a live reviewer; supersede_sibling_runs (terminal-
#   only) then closed the HEALTHY run. FIX: a live-sibling guard at run-creation
#   (Step 5b) yields to an already-running gate-run for the branch, so one branch
#   = one authoritative run and the duplicate can never write a FAIL.
#
#   BUG 2 (REVIEWER NO-VERDICT / process-churn root): the `gc session nudge
#   --delivery queue` task-delivery BLOCKED ~12 min then failed, overrunning the
#   ~2-min launchd interval so the over-running sweep was SIGTERM'd before it ever
#   reached the verdict poll. FIX: bound every reviewer task-delivery in the
#   $GATE_NUDGE_TIMEOUT prefix; the durable-pull channel (ga-67hae) remains the
#   reliable delivery path when a nudge times out.
#
# This harness SOURCES the dispatcher in lib-only mode to unit-test the REAL pure
# decision (classify_sibling_run) and the REAL resolver (live_sibling_run_for_branch,
# driven by an in-shell bd mock), then DRIFT-GUARDS the live script so a future
# refactor that drops either fix fails loudly. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has()    { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type classify_sibling_run        >/dev/null 2>&1 || { echo "FATAL: classify_sibling_run not defined by dispatcher"; exit 1; }
type live_sibling_run_for_branch >/dev/null 2>&1 || { echo "FATAL: live_sibling_run_for_branch not defined by dispatcher"; exit 1; }

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. classify_sibling_run — the pure per-branch decision ───────────────────
echo "── 1. classify_sibling_run (none | live | stale) ──"
eq "no sibling running for branch → none"                  "$(classify_sibling_run 0 5 90)"    "none"
eq "found=0 ignores age → none"                            "$(classify_sibling_run 0 9999 90)" "none"
eq "found + young (within ceiling) → live (yield)"         "$(classify_sibling_run 1 5 90)"    "live"
eq "found + exactly at ceiling → live"                     "$(classify_sibling_run 1 90 90)"   "live"
eq "found + older than ceiling → stale (supersede)"        "$(classify_sibling_run 1 91 90)"   "stale"
eq "found + 53m (the reported healthy run) < 90 → live"    "$(classify_sibling_run 1 53 90)"   "live"
# Conservative: never spawn a duplicate on a sibling we cannot prove stale.
eq "found + unparseable age → live (conservative)"         "$(classify_sibling_run 1 abc 90)"  "live"
eq "found + negative age (clock skew) → live"              "$(classify_sibling_run 1 -7 90)"   "live"
eq "found + bad ceiling → live (conservative)"             "$(classify_sibling_run 1 5 xx)"    "live"

# ── 2. live_sibling_run_for_branch — branch match + age (mock bd) ─────────────
# A reviewer run is matched by BRANCH (NOT source-bead): wa-86jr and
# wa-86jr-reland share bead wa-86jr, so a source-bead match would be wrong. The
# trailing "." in "Autonomous gate run for <branch>." anchors the match so the
# shorter branch name never prefix-matches the longer one.
echo "── 2. live_sibling_run_for_branch (branch-anchored match + age) ──"
GC_CITY="/tmp/dupguard-test-city"
SIBLING_RUN_STALE_MINUTES=90
NOW_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TS_5M_AGO=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
TS_200M_AGO=$(date -u -v-200M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '200 minutes ago' +%Y-%m-%dT%H:%M:%SZ)

# MOCK_RUNS holds the JSON the `bd ... list` call returns. bd() echoes it for the
# list query and is a no-op for everything else.
MOCK_RUNS='[]'
bd() {
  case " $* " in
    *" list "*) printf '%s\n' "$MOCK_RUNS" ;;
    *) : ;;
  esac
  return 0
}

# (a) no running runs at all → "" (none)
MOCK_RUNS='[]'
eq "(a) empty run list → no sibling" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland')" ""

# (b) a young run for THIS branch → "LIVE <id>"
MOCK_RUNS=$(printf '[{"id":"ga-run-live","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(b) young same-branch run → LIVE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland')" "LIVE ga-run-live"

# (c) an OLD (>ceiling) run for THIS branch → "STALE <id>"
MOCK_RUNS=$(printf '[{"id":"ga-run-stale","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nstarted_at: %s"}]' "$TS_200M_AGO")
eq "(c) stale same-branch run → STALE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland')" "STALE ga-run-stale"

# (d) a young run for a DIFFERENT (prefix) branch → "" (must NOT match)
MOCK_RUNS=$(printf '[{"id":"ga-run-other","description":"Autonomous gate run for crew/thies/wa-86jr.\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(d) prefix-only branch (wa-86jr) does NOT match wa-86jr-reland" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland')" ""

# (e) the longer branch IS matched when it is the one running
MOCK_RUNS=$(printf '[{"id":"ga-run-base","description":"Autonomous gate run for crew/thies/wa-86jr.\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(e) exact branch wa-86jr matches its own run" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr')" "LIVE ga-run-base"

# (f) missing started_at → conservative LIVE (never spawn a dup we can't age)
MOCK_RUNS='[{"id":"ga-run-nots","description":"Autonomous gate run for crew/thies/wa-86jr-reland."}]'
eq "(f) run with no started_at → conservative LIVE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland')" "LIVE ga-run-nots"

# ── 3. DRIFT GUARD: bug-1 live-sibling guard wired into the live dispatcher ───
echo "── 3. drift guard: live-sibling run-creation guard present ──"
has "$DISPATCHER" 'GATE_SIBLING_GUARD_ENABLED'                       "guard is feature-flagged (GATE_SIBLING_GUARD_ENABLED)"
has "$DISPATCHER" 'live_sibling_run_for_branch "\$BRANCH"'           "guard resolves a sibling for the current branch"
# The guard must sit BEFORE the gate-run bead is created (otherwise a duplicate
# run is already minted before we check).
GUARD_LN=$(grep -n 'live_sibling_run_for_branch "\$BRANCH"' "$DISPATCHER" | grep -v 'live_sibling_run_for_branch()' | head -1 | cut -d: -f1)
CREATE_LN=$(grep -n 'GATE_RUN_ID=\$(bd -C "\$GC_CITY" create' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$GUARD_LN" ] && [ -n "$CREATE_LN" ] && [ "$GUARD_LN" -lt "$CREATE_LN" ]; then
  ok "guard (line $GUARD_LN) runs BEFORE gate-run creation (line $CREATE_LN)"
else
  bad "guard must precede gate-run creation (guard=$GUARD_LN create=$CREATE_LN)"
fi
has "$DISPATCHER" 'YIELDING \(one branch = one authoritative run\)' "LIVE sibling → yield (no duplicate run spawned)"
has "$DISPATCHER" 'verdict=YIELDED'                                  "yield exits the sweep cleanly (no bead mutation)"
has "$DISPATCHER" 'Superseding it and proceeding with a fresh run'  "STALE sibling → supersede + proceed"

# ── 4. DRIFT GUARD: bug-2 task-delivery is timeout-bounded ───────────────────
echo "── 4. drift guard: reviewer task-delivery bounded by \$GATE_NUDGE_TIMEOUT ──"
has "$DISPATCHER" 'GATE_NUDGE_TIMEOUT="\$\{GATE_NUDGE_TIMEOUT:-timeout \$GATE_NUDGE_TIMEOUT_SECS\}"' "GATE_NUDGE_TIMEOUT prefix defined (timeout N)"
# Every reviewer task-delivery nudge/submit must carry the prefix. There are
# exactly THREE delivery sites: initial spawn (queue+submit), ACK re-queue, and
# re-convene (queue+submit) = 5 calls total.
DELIVERY_PREFIXED=$(grep -cE '\$GATE_NUDGE_TIMEOUT gc --city "\$GC_CITY" session (nudge|submit)' "$DISPATCHER")
eq "all 5 reviewer delivery calls carry the timeout prefix" "$DELIVERY_PREFIXED" "5"
# No reviewer task-delivery nudge/submit may call gc WITHOUT the prefix. (Author
# notifications use --delivery wait-idle and are intentionally excluded.)
UNGUARDED=$(grep -nE 'gc --city "\$GC_CITY" session (nudge|submit) "\$(SESSION_ID|_new_sid|_sid)"' "$DISPATCHER" \
  | grep -v '\$GATE_NUDGE_TIMEOUT' || true)
if [ -z "$UNGUARDED" ]; then
  ok "no reviewer-delivery nudge/submit bypasses the timeout prefix"
else
  bad "un-timeout'd reviewer delivery call(s): $UNGUARDED"
fi
# Lib-only must null the prefix (external timeout cannot see a shell-fn gc mock).
# Use ${VAR-default} (no colon) so an EMPTY string is distinguished from UNSET:
# the fix sets the prefix to the empty string in lib-only mode.
eq "lib-only nulls the prefix so gc mocks still work" "${GATE_NUDGE_TIMEOUT-UNSET}" ""

# ── 5. syntax ────────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

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

# ── 2. live_sibling_run_for_branch — branch+rig match + age (mock bd) ─────────
# A reviewer run is matched by BRANCH (NOT source-bead): wa-86jr and
# wa-86jr-reland share bead wa-86jr, so a source-bead match would be wrong. The
# trailing "." in "Autonomous gate run for <branch>." anchors the match so the
# shorter branch name never prefix-matches the longer one.
# ga-tvpo6z: matching also requires the candidate's `rig:` line to equal the
# caller's own rig (2nd arg) — see cases (k)-(o) below. All same-rig cases in
# this section pass 'gascity' on both sides so the pre-existing (non-rig)
# behavior is unaffected by the rig-match requirement.
echo "── 2. live_sibling_run_for_branch (branch+rig-anchored match + age) ──"
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
eq "(a) empty run list → no sibling" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" ""

# (b) a young run for THIS branch, same rig → "LIVE <id>"
MOCK_RUNS=$(printf '[{"id":"ga-run-live","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(b) young same-branch, same-rig run → LIVE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" "LIVE ga-run-live"

# (c) an OLD (>ceiling) run for THIS branch, same rig → "STALE <id>"
MOCK_RUNS=$(printf '[{"id":"ga-run-stale","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_200M_AGO")
eq "(c) stale same-branch, same-rig run → STALE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" "STALE ga-run-stale"

# (d) a young run for a DIFFERENT (prefix) branch → "" (must NOT match)
MOCK_RUNS=$(printf '[{"id":"ga-run-other","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(d) prefix-only branch (wa-86jr) does NOT match wa-86jr-reland" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" ""

# (e) the longer branch IS matched when it is the one running
MOCK_RUNS=$(printf '[{"id":"ga-run-base","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(e) exact branch wa-86jr matches its own run" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr' 'gascity')" "LIVE ga-run-base"

# (f) missing started_at → conservative LIVE (never spawn a dup we can't age)
MOCK_RUNS=$(printf '[{"id":"ga-run-nots","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: gascity"}]')
eq "(f) run with no started_at → conservative LIVE" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" "LIVE ga-run-nots"

# ── ga-tgj23: closed/superseded sibling must NEVER be treated as live ─────────
# Repro: ga-wisp-5yoelu5 carried label gate-status:superseded (correctly, a
# single clean label) and status=closed, yet a stale/leaked gate-status:running
# label on an EARLIER write (or an equivalent bd-list-layer inconsistency) could
# still surface it as a YIELDING candidate — stranding the sibling marker
# (ga-wisp-wkdz3xn, crew/mila/wa-ya17c) un-reviewed. These cases prove the fix:
# status=open is REQUIRED regardless of how young/matching the candidate is.

# (g) young, branch-matching, but status=closed → "" (NOT live — do not yield)
MOCK_RUNS=$(printf '[{"id":"ga-run-dead","status":"closed","description":"Autonomous gate run for crew/mila/wa-ya17c.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(g) closed sibling (young, branch-matching) → NOT live, no yield" "$(live_sibling_run_for_branch 'crew/mila/wa-ya17c' 'gascity')" ""

# (h) status=closed with NO started_at (would hit the conservative-LIVE branch
# in (f) if status were open) → still "" — the status gate short-circuits
# BEFORE the missing-timestamp fallback ever runs.
MOCK_RUNS=$(printf '[{"id":"ga-run-dead-nots","status":"closed","description":"Autonomous gate run for crew/mila/wa-ya17c.\\nrig: gascity"}]')
eq "(h) closed sibling with no started_at → NOT live (status gate wins)" "$(live_sibling_run_for_branch 'crew/mila/wa-ya17c' 'gascity')" ""

# (i) missing status field entirely → treated as NOT confirmed open → NOT live.
# Fail-safe direction: an uncertain sibling should not strand the marker forever;
# a false-proceed is caught by the terminal-time supersede safety net instead.
MOCK_RUNS=$(printf '[{"id":"ga-run-nostatus","description":"Autonomous gate run for crew/mila/wa-ya17c.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(i) missing status field → NOT live (uncertain treated as not-open)" "$(live_sibling_run_for_branch 'crew/mila/wa-ya17c' 'gascity')" ""

# (j) a genuinely live (status=open) sibling among a closed one still yields —
# proves the fix filters PER-CANDIDATE, not the whole result set.
MOCK_RUNS=$(printf '[{"id":"ga-run-dead2","status":"closed","description":"Autonomous gate run for crew/mila/wa-ya17c.\\nrig: gascity\\nstarted_at: %s"},{"id":"ga-run-alive","status":"open","description":"Autonomous gate run for crew/mila/wa-ya17c.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_200M_AGO" "$TS_5M_AGO")
eq "(j) closed + open siblings mixed → still yields to the OPEN one" "$(live_sibling_run_for_branch 'crew/mila/wa-ya17c' 'gascity')" "LIVE ga-run-alive"

# ── ga-tvpo6z: cross-rig false-positive — a branch NAME can legitimately
# recur across different rigs (rig A has a live run for "feat/x-shared"; rig B
# submits an unrelated diff under the identical branch STRING). Same shape as
# ga-95tq3p's confirmed-live repro for this function's sibling,
# dup_marker_ids_for_branch (quality-gate-guard.sh) — cases (k)-(o) mirror that
# fix's (j)-(m) regression cases, adapted to this function's two guard points
# (an early caller-rig check plus a per-candidate rig check, vs. one jq
# predicate there).

# (k) THE regression: same young, same-branch candidate as (b), but a
# DIFFERENT rig → must NOT match (cross-rig false-positive yield).
MOCK_RUNS=$(printf '[{"id":"ga-run-otherrig","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: whatsapp_automation\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(k) ga-tvpo6z: same branch, different rig → NOT matched" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" ""

# (l) candidate missing rig: line entirely (legacy/pre-field run) → NOT
# matched — fail toward not-yielding on an unconfirmed candidate rig.
MOCK_RUNS=$(printf '[{"id":"ga-run-legacy","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(l) ga-tvpo6z: candidate missing rig: line → NOT matched" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" ""

# (m) candidate rig is literally "unknown" (gate-done.md's own fallback
# placeholder when its RIG derivation can't resolve a repo) → NOT matched;
# "unknown" is a placeholder, not a confirmed identity, even though the
# caller's own rig IS confirmed here.
MOCK_RUNS=$(printf '[{"id":"ga-run-unk","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: unknown\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(m) ga-tvpo6z: candidate rig=unknown → NOT matched (placeholder, not identity)" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'gascity')" ""

# (n) caller's own rig is empty → NOT matched even though a same-branch,
# same-string, confirmed-rig candidate exists — the top-of-function guard
# short-circuits BEFORE the (mocked) bd query ever runs.
MOCK_RUNS=$(printf '[{"id":"ga-run-live2","status":"open","description":"Autonomous gate run for crew/thies/wa-86jr-reland.\\nrig: gascity\\nstarted_at: %s"}]' "$TS_5M_AGO")
eq "(n) ga-tvpo6z: caller's own rig empty → NOT matched" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' '')" ""

# (o) caller's own rig is literally "unknown" → same early short-circuit as (n).
eq "(o) ga-tvpo6z: caller's own rig=unknown → NOT matched" "$(live_sibling_run_for_branch 'crew/thies/wa-86jr-reland' 'unknown')" ""

# ── 3. DRIFT GUARD: bug-1 live-sibling guard wired into the live dispatcher ───
echo "── 3. drift guard: live-sibling run-creation guard present ──"
has "$DISPATCHER" 'GATE_SIBLING_GUARD_ENABLED'                       "guard is feature-flagged (GATE_SIBLING_GUARD_ENABLED)"
has "$DISPATCHER" 'live_sibling_run_for_branch "\$BRANCH" "\$RIG"'   "guard resolves a sibling for the current branch, rig-scoped (ga-tvpo6z: a future refactor can't silently drop rig-scoping)"
# The guard must sit BEFORE the gate-run bead is created (otherwise a duplicate
# run is already minted before we check).
GUARD_LN=$(grep -n 'live_sibling_run_for_branch "\$BRANCH" "\$RIG"' "$DISPATCHER" | grep -v 'live_sibling_run_for_branch()' | head -1 | cut -d: -f1)
CREATE_LN=$(grep -n 'GATE_RUN_ID=\$(bd -C "\$GC_CITY" create' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$GUARD_LN" ] && [ -n "$CREATE_LN" ] && [ "$GUARD_LN" -lt "$CREATE_LN" ]; then
  ok "guard (line $GUARD_LN) runs BEFORE gate-run creation (line $CREATE_LN)"
else
  bad "guard must precede gate-run creation (guard=$GUARD_LN create=$CREATE_LN)"
fi
has "$DISPATCHER" 'YIELDING \(one branch = one authoritative run\)' "LIVE sibling → yield (no duplicate run spawned)"
has "$DISPATCHER" 'verdict=YIELDED'                                  "yield exits the sweep cleanly (no bead mutation)"
has "$DISPATCHER" '\[ "\$status" = "open" \] \|\| continue'          "ga-tgj23: per-candidate status=open gate present (closed sibling never live)"
has "$DISPATCHER" 'Superseding it and proceeding with a fresh run'  "STALE sibling → supersede + proceed"

# ── 4. DRIFT GUARD: bug-2 task-delivery is timeout-bounded ───────────────────
echo "── 4. drift guard: reviewer task-delivery bounded by \$GATE_NUDGE_TIMEOUT ──"
has "$DISPATCHER" 'GATE_NUDGE_TIMEOUT="\$\{GATE_NUDGE_TIMEOUT:-timeout \$GATE_NUDGE_TIMEOUT_SECS\}"' "GATE_NUDGE_TIMEOUT prefix defined (timeout N)"
# Every reviewer task-delivery nudge/submit must carry the prefix. There are
# exactly THREE delivery sites: initial spawn (queue+submit), ACK re-queue, and
# re-convene (queue+submit) = 5 calls total.
# ga-vne2 (2026-08-08) centralized the 3 `nudge` sites (initial-spawn-queue,
# ACK-re-queue, re-convene-queue) behind a single gate_nudge() wrapper that
# applies the prefix once, internally — so a flat grep of the raw inline
# pattern now only sees the 2 remaining `submit` fallbacks plus the wrapper's
# own one definition line (3), not 5. Count logical delivery sites instead of
# raw literal occurrences: raw `submit` sites (still inline) + gate_nudge()
# call sites (each timeout-bound via the wrapper) — verifying the wrapper
# itself is bound separately, so the split can't silently both drift.
GATE_NUDGE_DEF_LN=$(grep -n '^gate_nudge() {' "$DISPATCHER" | head -1 | cut -d: -f1)
GATE_NUDGE_BODY_TIMEOUT_LN=$(grep -n '\$GATE_NUDGE_TIMEOUT gc --city "\$GC_CITY" session nudge "\$@"' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$GATE_NUDGE_DEF_LN" ] && [ -n "$GATE_NUDGE_BODY_TIMEOUT_LN" ] \
   && [ "$GATE_NUDGE_BODY_TIMEOUT_LN" -gt "$GATE_NUDGE_DEF_LN" ] \
   && [ $((GATE_NUDGE_BODY_TIMEOUT_LN - GATE_NUDGE_DEF_LN)) -le 30 ]; then
  ok "gate_nudge() wrapper (line $GATE_NUDGE_DEF_LN) applies the timeout prefix internally (line $GATE_NUDGE_BODY_TIMEOUT_LN)"
else
  bad "gate_nudge() wrapper must apply \$GATE_NUDGE_TIMEOUT internally (def=$GATE_NUDGE_DEF_LN body=$GATE_NUDGE_BODY_TIMEOUT_LN)"
fi
RAW_SUBMIT_SITES=$(grep -cE '\$GATE_NUDGE_TIMEOUT gc --city "\$GC_CITY" session submit' "$DISPATCHER")
GATE_NUDGE_CALLSITES=$(grep -cE '\bgate_nudge "' "$DISPATCHER")
DELIVERY_PREFIXED=$((RAW_SUBMIT_SITES + GATE_NUDGE_CALLSITES))
eq "all 5 reviewer delivery sites are timeout-bounded (raw submit + gate_nudge call sites)" "$DELIVERY_PREFIXED" "5"
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

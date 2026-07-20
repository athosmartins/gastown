#!/usr/bin/env bash
# gate-sibling-branch-guard.selftest.sh — Prove the ga-lxz5w fix in isolation,
# with NO live Dolt/gc/launchd:
#
#   BUG (ga-lxz5w): bead wa-fnibd had 2 builders. wa-worker's branch built an
#   INCOMPLETE fix; crew/oracle's branch (a different SHA, same bead) was the
#   COMPLETE superset. Oracle held the bead with gate:needs-human, but the
#   incomplete branch merged anyway — wa-fnibd closed carrying gate:passed +
#   story:done, and oracle's branch was never referenced again. Two holes:
#   (a) the gate never checked whether another branch was still active for
#   the same source bead before merging; (b) a park-worthy label (or the bead
#   closing entirely) applied AFTER this run's own review began never
#   re-blocked an already in-flight PASS — the hold only ran once, at
#   submission time.
#
#   FIX: two live, pre-merge checks inserted immediately before the merge
#   decision, same shape as the existing ga-nooaw SHA-fail check they sit
#   next to: (b) gate_bead_live_merge_block() re-reads the source bead LIVE
#   and re-runs check_source_bead_park() (reused from quality-gate-guard.sh,
#   zero drift risk) plus a `status=closed` check; (a)
#   gate_bead_active_sibling_branch() scans every marker/gate-run tied to the
#   same source bead (source-bead: label) for another branch in a non-
#   terminal gate-status, and — only on a genuine hit — labels gate:needs-
#   human and mails the Mayor. Both downgrade OVERALL_VERDICT to FAIL and
#   fall through to the existing FAIL path unchanged.
#
# This harness SOURCES the dispatcher in lib-only mode to unit-test the REAL
# pure decisions (gate_is_active_gate_status, gate_pick_active_sibling) and
# the REAL bd-backed resolvers (gate_bead_active_sibling_branch,
# gate_bead_live_merge_block, driven by an in-shell bd mock), then DRIFT-
# GUARDS the live script so a future refactor can't drop or reorder the fix
# silently. Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

for fn in gate_is_active_gate_status gate_pick_active_sibling \
          gate_bead_active_sibling_branch gate_bead_live_merge_block \
          check_source_bead_park; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by dispatcher (lib-only)"; exit 1; }
done

# Quiet logging from the sourced helpers during the test.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. gate_is_active_gate_status — pure active/terminal classification ──────
echo "── 1. gate_is_active_gate_status (pure) ──"
for s in ready queued claimed dispatching running needs-rebase; do
  eq "active: $s" "$(gate_is_active_gate_status "$s")" "yes"
done
for s in passed failed superseded error aborted deferred parked-needs-human "" bogus; do
  eq "terminal/unknown: '$s'" "$(gate_is_active_gate_status "$s")" "no"
done

# ── 2. gate_pick_active_sibling — pure multi-line triage ─────────────────────
echo "── 2. gate_pick_active_sibling (pure) ──"
eq "empty input → no sibling" \
  "$(gate_pick_active_sibling "" "crew/me/x")" ""
eq "only same-branch rows → no sibling (never flags itself)" \
  "$(gate_pick_active_sibling "$(printf 'crew/me/x\trunning\ncrew/me/x\tqueued')" "crew/me/x")" ""
eq "other branch but ALL terminal → no sibling" \
  "$(gate_pick_active_sibling "$(printf 'crew/them/x\tpassed\ncrew/them/x\tsuperseded')" "crew/me/x")" ""
eq "other branch, active status → sibling found" \
  "$(gate_pick_active_sibling "$(printf 'crew/them/x\trunning')" "crew/me/x")" \
  "$(printf 'crew/them/x\trunning')"
eq "mixed rows: skips own+terminal, finds the one active sibling" \
  "$(gate_pick_active_sibling "$(printf 'crew/me/x\tfailed\ncrew/them/x\tpassed\ncrew/other/x\tqueued')" "crew/me/x")" \
  "$(printf 'crew/other/x\tqueued')"
eq "blank lines in input are skipped, not misread as a branch" \
  "$(gate_pick_active_sibling "$(printf '\ncrew/them/x\trunning\n')" "crew/me/x")" \
  "$(printf 'crew/them/x\trunning')"

# ── 3. gate_bead_active_sibling_branch — bd-backed resolver (mock bd) ────────
echo "── 3. gate_bead_active_sibling_branch (bd list + label/description extraction, mock bd) ──"
MOCK_LIST_JSON='[]'
MOCK_LIST_FAIL=0
bd() {
  case " $* " in
    *" list "*)
      [ "$MOCK_LIST_FAIL" = "1" ] && return 1
      printf '%s\n' "$MOCK_LIST_JSON"
      ;;
    *) : ;;
  esac
  return 0
}

eq "(a) empty bead_id → '' (never calls bd)" \
  "$(gate_bead_active_sibling_branch city '' 'crew/me/wa-fnibd')" ""
eq "(b) empty this_branch → '' (never calls bd)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' '')" ""

MOCK_LIST_JSON='[]'
eq "(c) no markers/gate-runs at all → ''" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd')" ""

# Real-incident shape: a marker (branch: LABEL) for the sibling, active status.
MOCK_LIST_JSON='[{"id":"m1","labels":["type:quality-gate-marker","gate-status:queued","source-bead:wa-fnibd","branch:crew/oracle/wa-fnibd"],"description":""}]'
eq "(d) sibling found via branch: LABEL (marker shape)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd')" \
  "$(printf 'crew/oracle/wa-fnibd\tqueued')"

# gate-run shape: no branch: label, branch only in the description.
MOCK_LIST_JSON='[{"id":"r1","labels":["type:quality-gate-run","gate-status:running","source-bead:wa-fnibd"],"description":"Autonomous gate run for crew/oracle/wa-fnibd.\nsource_bead: wa-fnibd\nbranch: crew/oracle/wa-fnibd\ntier: bug"}]'
eq "(e) sibling found via description branch: field (gate-run shape, no label)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd')" \
  "$(printf 'crew/oracle/wa-fnibd\trunning')"

# Only entry IS this run's own marker (same branch) → not a sibling.
MOCK_LIST_JSON='[{"id":"m1","labels":["gate-status:running","source-bead:wa-fnibd","branch:crew/wa-worker/wa-fnibd"],"description":""}]'
eq "(f) only entry is THIS branch itself → '' (not a sibling of itself)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd')" ""

# Sibling exists but already terminal (reland case: a NEW branch resubmitted
# after the old one finished — must NOT flag a sequential, non-conflicting resubmission).
MOCK_LIST_JSON='[{"id":"m1","labels":["gate-status:superseded","source-bead:wa-fnibd","branch:crew/oracle/wa-fnibd"],"description":""}]'
eq "(g) sibling exists but terminal (superseded) → '' (sequential reland is legitimate)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd-reland')" ""

MOCK_LIST_JSON='[]'
MOCK_LIST_FAIL=1
eq "(h) bd list fails (transient) → '' (fail-open)" \
  "$(gate_bead_active_sibling_branch city 'wa-fnibd' 'crew/wa-worker/wa-fnibd')" ""
MOCK_LIST_FAIL=0

# ── 4. gate_bead_live_merge_block — bd-backed resolver (mock bd) ─────────────
echo "── 4. gate_bead_live_merge_block (bd show + check_source_bead_park, mock bd) ──"
MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=0
bd() {
  case " $* " in
    *" show "*)
      [ "$MOCK_SHOW_FAIL" = "1" ] && return 1
      printf '%s\n' "$MOCK_SHOW_JSON"
      ;;
    *) : ;;
  esac
  return 0
}

eq "(a) empty bead_id → ok (never calls bd)" \
  "$(gate_bead_live_merge_block city '')" "ok"

MOCK_SHOW_JSON='[{"id":"wa-fnibd","status":"open","labels":["area:wa"]}]'
eq "(b) open bead, no park-worthy label → ok" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "ok"

MOCK_SHOW_JSON='[{"id":"wa-fnibd","status":"closed","labels":["gate:passed","story:done"]}]'
eq "(c) bead already closed → closed (even though labels look fine)" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "closed"

MOCK_SHOW_JSON='[{"id":"wa-fnibd","status":"open","labels":["gate:needs-human"]}]'
eq "(d) open bead, gate:needs-human applied after claim → park:needs-human" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "park:needs-human"

MOCK_SHOW_JSON='[{"id":"wa-fnibd","status":"open","labels":["story:needs-approval"]}]'
eq "(e) open bead, story:needs-approval → park:needs-approval" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "park:needs-approval"

MOCK_SHOW_JSON='[{"id":"wa-fnibd","status":"open","labels":["gate:needs-fix"]}]'
eq "(f) gate:needs-fix ALONE is the normal iterate path, not a park reason → ok" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "ok"

MOCK_SHOW_JSON='[]'
MOCK_SHOW_FAIL=1
eq "(g) bd show fails (transient) → ok (fail-open, mirrors guard.sh Step 5a)" \
  "$(gate_bead_live_merge_block city 'wa-fnibd')" "ok"
MOCK_SHOW_FAIL=0

# ── 5. DRIFT GUARD: helpers defined before the lib-only cutoff ───────────────
echo "── 5. drift guard: helpers are selftest-sourceable (defined before lib-only guard) ──"
CUTOFF_LN=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
for fn in gate_bead_active_sibling_branch gate_bead_live_merge_block; do
  DEF_LN=$(grep -n "^${fn}() {" "$DISPATCHER" | head -1 | cut -d: -f1)
  if [ -n "$DEF_LN" ] && [ -n "$CUTOFF_LN" ] && [ "$DEF_LN" -lt "$CUTOFF_LN" ]; then
    ok "$fn (line $DEF_LN) defined before the lib-only cutoff (line $CUTOFF_LN)"
  else
    bad "$fn must be defined before the GATE_DISPATCHER_LIB_ONLY cutoff (def=$DEF_LN cutoff=$CUTOFF_LN)"
  fi
done

# ── 6. DRIFT GUARD: both checks wired in, correctly ordered, before the merge ─
echo "── 6. drift guard: pre-merge checks precede the merge attempt, in the right order ──"
has "$DISPATCHER" 'gate_bead_live_merge_block "\$BEAD_CITY" "\$BEAD_ID"' \
  "live re-check (b) calls gate_bead_live_merge_block with BEAD_CITY/BEAD_ID"
has "$DISPATCHER" 'gate_bead_active_sibling_branch "\$GC_CITY" "\$BEAD_ID" "\$BRANCH"' \
  "sibling check (a) calls gate_bead_active_sibling_branch with GC_CITY/BEAD_ID/BRANCH"
has "$DISPATCHER" 'label add "\$BEAD_ID" "gate:needs-human"' \
  "sibling check (a) labels the source bead gate:needs-human"
has "$DISPATCHER" 'mail send mayor' \
  "sibling check (a) escalates to the Mayor via durable mail"

SHA_CHECK_LN=$(grep -n 'gate_bead_has_prior_sha_fail "\$BEAD_CITY" "\$BEAD_ID" "\$BRANCH_SHA"' "$DISPATCHER" | head -1 | cut -d: -f1)
BLOCK_CHECK_LN=$(grep -n 'gate_bead_live_merge_block "\$BEAD_CITY" "\$BEAD_ID"' "$DISPATCHER" | head -1 | cut -d: -f1)
SIBLING_CHECK_LN=$(grep -n 'gate_bead_active_sibling_branch "\$GC_CITY" "\$BEAD_ID" "\$BRANCH"' "$DISPATCHER" | head -1 | cut -d: -f1)
MERGE_LOG_LN=$(grep -n 'log "ALL PASS — proceeding to merge branch' "$DISPATCHER" | head -1 | cut -d: -f1)

if [ -n "$SHA_CHECK_LN" ] && [ -n "$BLOCK_CHECK_LN" ] && [ "$SHA_CHECK_LN" -lt "$BLOCK_CHECK_LN" ]; then
  ok "ga-nooaw SHA-fail check (line $SHA_CHECK_LN) precedes live re-check (line $BLOCK_CHECK_LN)"
else
  bad "expected ga-nooaw check before live re-check (sha=$SHA_CHECK_LN block=$BLOCK_CHECK_LN)"
fi
if [ -n "$BLOCK_CHECK_LN" ] && [ -n "$SIBLING_CHECK_LN" ] && [ "$BLOCK_CHECK_LN" -lt "$SIBLING_CHECK_LN" ]; then
  ok "live re-check (line $BLOCK_CHECK_LN) precedes sibling-branch check (line $SIBLING_CHECK_LN)"
else
  bad "expected live re-check before sibling-branch check (block=$BLOCK_CHECK_LN sibling=$SIBLING_CHECK_LN)"
fi
if [ -n "$SIBLING_CHECK_LN" ] && [ -n "$MERGE_LOG_LN" ] && [ "$SIBLING_CHECK_LN" -lt "$MERGE_LOG_LN" ]; then
  ok "sibling-branch check (line $SIBLING_CHECK_LN) precedes the merge attempt (line $MERGE_LOG_LN)"
else
  bad "sibling-branch check must precede the merge attempt (sibling=$SIBLING_CHECK_LN merge=$MERGE_LOG_LN)"
fi

# ── 7. syntax ──────────────────────────────────────────────────────────────
echo "── 7. syntax ──"
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

#!/usr/bin/env bash
# gate-dup-run-claim-receipt.selftest.sh — proves the ga-f1ngu fix in isolation,
# with NO live Dolt/gc/launchd:
#
#   BUG (ga-f1ngu): quality-gate-guard.sh's Step 6 and quality-gate-dispatcher.sh's
#   own Step 6 are two independent producers of type:quality-gate-run beads for
#   the SAME marker — the guard's "quality-gate: ..." claim receipt (created at
#   claim time, never gets a reviewer) and the dispatcher's "gate-run: ..." real
#   run (created at dispatch time, WITH branch_sha/required_reviewers). Both
#   used to carry gate-status:running, so every consumer that scans for "a
#   review is in flight" saw both:
#     - the dispatcher's OWN pre-creation duplicate guard (live_sibling_run_for_
#       branch, ga-dupnv) matches candidates by the exact description substring
#       "Autonomous gate run for X." — text only the dispatcher's own template
#       writes — so it never recognized the guard's differently-worded receipt
#       as a sibling, and happily created a second, real run right on top of it
#       (the literal "same marker generates 2 runs" bug).
#     - Phase C's health sweep, gate-recovery-watchdog.py's hung_run_verdict,
#       and pilot-dispatcher.sh's/auto-refino-dispatcher.sh's gate-congestion
#       throttle checks all counted the receipt as a live review, inflating
#       occupancy/congestion and (for Phase C) mis-parsing its garbled branch
#       name from a title prefix ("gate-run: ") the receipt's title ("quality-
#       gate: ") never had.
#
#   FIX: the guard's claim receipt is now labeled gate-status:claimed, never
#   gate-status:running (quality-gate-guard.sh Step 6). Only the dispatcher's
#   real run bead is ever gate-status:running, so by construction a marker can
#   never have 2 such beads. The guard's Vector B shared-prelude query is
#   broadened (gate-status:running OR :claimed via --label-any) so the existing
#   dedup_gaterun_action (keep-newest) and reconcile_zero_verdict_run_action
#   (grace-window close) still retire the claim receipt — now typically within
#   one guard sweep of the real run appearing, instead of only at the
#   dispatcher's terminal path or a 90m TTL fallback.
#
# This harness is purely textual (drift-guard) — the Vector A/B reconcile loop
# is inline script, not a callable function, so it cannot be lib-only sourced;
# its pure decision functions (dedup_gaterun_action, reconcile_zero_verdict_run_
# action) are unit-tested in quality-gate-guard.selftest.sh instead. Exit 0 iff
# every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
has()      { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }
has_not()  { if grep -qE "$2" "$1"; then bad "$3 — REGRESSION, found: $2"; else ok "$3"; fi; }

# ── 1. the guard's Step 6 claim receipt is gate-status:claimed, not :running ──
echo "── 1. guard Step 6: claim receipt uses gate-status:claimed ──"
# Isolate the Step 6 bd-create block (from its GATE_RUN_ID= line to the closing
# --json parse) so this assertion is scoped to THIS call site, not a whole-file
# grep that could accidentally match an unrelated line elsewhere in the file.
STEP6_BLOCK=$(awk '/^GATE_RUN_ID=\$\(bd -C "\$GC_CITY" create \\$/{flag=1} flag{print} flag&&/--json 2>\/dev\/null \| jq -r .\.id/{exit}' "$GUARD")
if [ -z "$STEP6_BLOCK" ]; then
  bad "could not isolate guard Step 6's bd-create block — awk anchor drifted, fix the selftest"
else
  ok "isolated guard Step 6's bd-create block (${#STEP6_BLOCK} chars)"
  echo "$STEP6_BLOCK" | grep -qE -- '-l gate-status:claimed' \
    && ok "Step 6 create call carries -l gate-status:claimed" \
    || bad "Step 6 create call missing -l gate-status:claimed"
  echo "$STEP6_BLOCK" | grep -qE -- '-l gate-status:running' \
    && bad "REGRESSION: Step 6 create call carries -l gate-status:running (the ga-f1ngu bug is back)" \
    || ok "Step 6 create call does NOT carry -l gate-status:running"
  echo "$STEP6_BLOCK" | grep -qE 'type:quality-gate-run' \
    && ok "Step 6 create call still carries type:quality-gate-run (unchanged type)" \
    || bad "Step 6 create call lost type:quality-gate-run"
fi

# ── 2. Vector A/B shared prelude sees BOTH :running and :claimed ────────────
echo "── 2. shared prelude: Vector A/B query includes both statuses ──"
has "$GUARD" 'label-any gate-status:running' \
  "shared-prelude query includes --label-any gate-status:running"
has "$GUARD" 'label-any gate-status:claimed' \
  "shared-prelude query includes --label-any gate-status:claimed"

# ── 3. the dispatcher's OWN duplicate-run machinery stays scoped to :running ──
# live_sibling_run_for_branch (ga-dupnv) and supersede_sibling_runs (ga-tmug)
# must NOT be broadened to :claimed — a claim receipt is never a "run" whose
# liveness/duplication those functions should reason about; broadening them
# would just reintroduce a different flavor of the same confusion this fix
# removes. Only the guard's OWN Vector B (which owns the receipt's lifecycle)
# should see gate-status:claimed beads.
echo "── 3. dispatcher's run-vs-run duplicate guards stay :running-only ──"
DISPATCHER_CLAIMED_HITS=$(grep -c -- '--label-any gate-status:claimed\|-l gate-status:claimed' "$DISPATCHER" || true)
[ "${DISPATCHER_CLAIMED_HITS:-0}" -eq 0 ] \
  && ok "dispatcher never queries gate-status:claimed (still guard-owned)" \
  || bad "dispatcher now references gate-status:claimed ($DISPATCHER_CLAIMED_HITS hit(s)) — was this intentional? if so, update this selftest's expectation"
has "$DISPATCHER" 'live_sibling_run_for_branch' \
  "live_sibling_run_for_branch still present (unchanged duplicate-run guard)"
has "$DISPATCHER" 'supersede_sibling_runs\(\)' \
  "supersede_sibling_runs still present (unchanged terminal-path cleanup)"

# ── 4. guard's own dedup/zero-verdict pure functions still exist and are wired ─
echo "── 4. drift guard: dedup_gaterun_action wired into Vector B ──"
has "$GUARD" 'dedup_gaterun_action\(\)' "dedup_gaterun_action is defined"
has "$GUARD" 'DEDUP_ACTION=\$\(dedup_gaterun_action' "Vector B calls dedup_gaterun_action"
has "$GUARD" 'supersede:duplicate' "supersede:duplicate branch is handled"

# ── 5. syntax ──────────────────────────────────────────────────────────────
echo "── 5. syntax ──"
if bash -n "$GUARD"; then ok "guard passes bash -n"; else bad "guard bash -n FAILED"; fi
if bash -n "$DISPATCHER"; then ok "dispatcher passes bash -n"; else bad "dispatcher bash -n FAILED"; fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -eq 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

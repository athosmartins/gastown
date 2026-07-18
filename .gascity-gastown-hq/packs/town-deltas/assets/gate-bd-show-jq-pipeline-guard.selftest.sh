#!/usr/bin/env bash
# gate-bd-show-jq-pipeline-guard.selftest.sh — Drift-guard for ga-8fx5e.
#
# Bug class: quality-gate-dispatcher.sh runs under `set -euo pipefail`. Three
# multi-line command-substitution pipelines that start with `bd show --json |
# jq …` are unguarded. If `bd show` returns non-zero (e.g. transient Dolt
# i/o-timeout), `pipefail` propagates the non-zero through the pipe, and
# `set -e` silently kills the dispatcher mid-sweep — head-of-line-blocking the
# whole gate. Same class as ga-mzc3h (fixed at commit 980b37cd7).
#
# Affected pipelines (ga-8fx5e):
#   BD_STATUS    — supersede path (branch already merged to main)
#   REBASE_ATTEMPT — rebase-attempt counter read from marker labels
#   VB_STATUS×2  — verdict-bead cleanup in timeout and quota-requeue paths
#
# Fix: append `|| true` to each pipeline (matches every other guarded cmdsub
# in the dispatcher). Downstream code already handles the empty-string case:
#   BD_STATUS=""    → [ "$BD_STATUS" != "closed" ] = true → idempotent ops
#   REBASE_ATTEMPT="" → `[ -z ]` guard → default 0   → safe
#   VB_STATUS=""    → [ "$VB_STATUS" != "closed" ] = true → idempotent close
#
# Exit 0 iff all checks pass.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "── gate bd-show|jq pipeline guard (ga-8fx5e) ──"

# ── 1. Reproduce the crash class ─────────────────────────────────────────────
# An UNGUARDED cmdsub-pipeline whose first command fails MUST kill a
# `set -euo pipefail` script.  This proves the bug class is real on this
# platform before testing the fix.
unguarded_rc=0
bash -c 'set -euo pipefail
  X=$(false 2>/dev/null | jq -r "." 2>/dev/null)
  echo "$X"' >/dev/null 2>&1 || unguarded_rc=$?
if [ "$unguarded_rc" -ne 0 ]; then
  ok "unguarded bd-show|jq pipeline crashes under set -euo pipefail (rc=$unguarded_rc)"
else
  bad "unguarded pipeline did NOT crash — test env cannot detect this bug class"
fi

# ── 2. Prove the fix ─────────────────────────────────────────────────────────
# The SAME pipeline with `|| true` at the end must survive.
guarded_rc=0
bash -c 'set -euo pipefail
  X=$(false 2>/dev/null | jq -r "." 2>/dev/null || true)
  echo "reached:[$X]"' >/dev/null 2>&1 || guarded_rc=$?
if [ "$guarded_rc" -eq 0 ]; then
  ok "guarded pipeline (|| true) survives under set -euo pipefail"
else
  bad "guarded pipeline still crashed (rc=$guarded_rc) — || true is not sufficient"
fi

# ── 3. Drift-guard: BD_STATUS (supersede path) ───────────────────────────────
# The line reads the source bead status before deciding whether to deliver it.
# Empty BD_STATUS is safe: `!= "closed"` triggers idempotent delivery ops.
BD_BLOCK="$(awk '/BD_STATUS=\$\(bd.*show.*BEAD_ID.*--json/{c=1} c{printf "%s ", $0} /\.status .* "open"\)/{if(c){print ""; c=0}}' "$GATE" 2>/dev/null || true)"
if printf '%s' "$BD_BLOCK" | grep -q "status .* \"open\"' 2>/dev/null || true)"; then
  ok "BD_STATUS pipeline is guarded with '|| true'"
else
  bad "BD_STATUS pipeline is NOT guarded with '|| true' (silent-crash risk — ga-8fx5e)"
fi

# ── 4. Drift-guard: REBASE_ATTEMPT ───────────────────────────────────────────
# The pipeline reads rebase-attempt counter from marker labels.
# Empty REBASE_ATTEMPT is safe: the `[ -z ]` guard immediately below sets it to 0.
# ga-46g1: the inline call site this awk pattern used to match was refactored
# (ga-6dp9 era) into a read_rebase_attempt() helper — the call site is now the
# plain function call `REBASE_ATTEMPT=$(read_rebase_attempt "$MARKER_ID")`,
# which contains no bd-show|jq pipeline at all, so the old pattern matched
# nothing and this guard was vacuously failing. The pipeline itself now lives
# inside the helper's body, so the guard inspects that instead.
RA_BLOCK="$(sed -n '/^read_rebase_attempt() {/,/^}/p' "$GATE" 2>/dev/null || true)"
if printf '%s' "$RA_BLOCK" | grep -q 'head -1 || true)'; then
  ok "REBASE_ATTEMPT pipeline (read_rebase_attempt helper) is guarded with '|| true'"
else
  bad "REBASE_ATTEMPT pipeline is NOT guarded with '|| true' (silent-crash risk — ga-8fx5e)"
fi

# ── 5. Drift-guard: VB_STATUS (timeout + quota-requeue paths) ────────────────
# Two verdict-bead cleanup loops each read VB_STATUS via a bd-show|jq pipeline.
# Empty VB_STATUS is safe: `!= "closed"` triggers idempotent close ops.
# Count how many of the `bd show "$VB"` pipelines end with `|| true)`.
# Each guarded instance ends its closing jq line with `2>/dev/null || true)`.
VB_GUARDED_COUNT=$(grep -c "status // \"open\"' 2>/dev/null || true)" "$GATE" 2>/dev/null || echo 0)
if [ "${VB_GUARDED_COUNT:-0}" -ge 2 ]; then
  ok "both VB_STATUS pipelines are guarded with '|| true' (count=$VB_GUARDED_COUNT)"
else
  bad "fewer than 2 VB_STATUS pipelines are guarded (count=${VB_GUARDED_COUNT:-0}) — ga-8fx5e"
fi

# ── 6. Drift-guard: GATE_RUN_ID (gate-run bead creation, Step 6) ─────────────
# bd create --json ... | jq -r '.id // empty' — the bd create call can fail
# (transient Dolt i/o-timeout) and without || guard, pipefail silently kills the
# dispatcher before the empty-check at line ~2419 can fire.  The fix adds || echo "".
# Downstream: GATE_RUN_ID="" → guarded by `if [ -z "$GATE_RUN_ID" ]` (warn + set "unknown").
GATE_RUN_GUARDED=$(grep -c "jq -r '.id // empty' || echo \"\")" "$GATE" 2>/dev/null || echo 0)
if [ "${GATE_RUN_GUARDED:-0}" -ge 2 ]; then
  ok "GATE_RUN_ID and VERDICT_BEAD_ID '.id // empty' pipelines both guarded with '|| echo \"\"' (count=$GATE_RUN_GUARDED)"
else
  bad "GATE_RUN_ID or VERDICT_BEAD_ID '.id // empty' pipeline(s) unguarded (count=${GATE_RUN_GUARDED:-0}) — silent-crash on bd create failure kills dispatcher before empty-check guard fires (ga-8fx5e follow-up)"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

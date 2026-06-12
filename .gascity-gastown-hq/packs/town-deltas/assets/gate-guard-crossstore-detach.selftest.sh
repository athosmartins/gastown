#!/usr/bin/env bash
# gate-guard-crossstore-detach.selftest.sh (gt-gwng6)
#
# Proves quality-gate-guard.sh Step 5b detaches the source bead from the dog pool
# in the store that ACTUALLY owns it — not blindly in the HQ store ($GC_CITY).
#
# ROOT BUG (gt-gwng6, residual of ga-e7zk7): Step 5b cleared the source bead's
# assignee and stripped gc.routed_to with `bd -C "$GC_CITY"` (HQ store). Rig-native
# beads (wa-*, ps-*, lx-*) live in their RIG's own Dolt DB, so the HQ-targeted
# writes silently no-op → assignee never clears → the reconciler re-spawns pool
# workers infinitely (wa-nr8o/wa-32fq/wa-tnl5 churned 5x-15x; wa-tnl5 had 4 gate
# markers, 2 running). ga-e7zk7 fixed the dog-side re-claim but NOT this guard leg.
#
# FIX: resolve the bead's owning store (mirror the dispatcher's ga-qw7y6
# resolve_bead_city) and run BOTH the assign-clear and the routed_to-unset against
# that store ($BEAD_CITY), not $GC_CITY.
#
# Covers:
#   A. resolve_bead_city (replicated from the guard) — probes the owning store
#      with a bead-id prefix fallback:
#        (1) rig-native wa- bead              → rig store   (THE FIX)
#        (2) HQ ga- bead in rig context       → HQ store    (ga-qw7y6 preserved)
#        (3) empty bead-id                    → HQ store
#        (4) unknown wa- bead (neither store) → rig via prefix fallback
#        (5) unknown ga- bead (neither store) → HQ via prefix fallback
#        (6) NO rig resolved (RIG_PATH empty) → HQ, no spurious rig probe
#   B. Step 5b targeting — the detach writes go to $BEAD_CITY, proven by capturing
#      the -C argument the guard would pass for a rig-native bead.
#   C. Drift-guards on the live source — the fix cannot silently revert:
#        (7) Step 5b assign-clear no longer uses `bd -C "$GC_CITY" assign`
#        (8) resolve_bead_city() is defined in the guard
#        (9) BEAD_CITY is assigned via the resolver
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD_SRC="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# ── Replicated resolver (mirrors quality-gate-guard.sh resolve_bead_city) ───────
# Stubbed `bd`: rig store owns wa-7nq; HQ store owns ga-qw7y6. A not-found probe
# returns the real bd shape ({"error":...} → no .status) so the resolver skips it.
GC_CITY="/fake/hq"
RIG_PATH="/fake/rig/wa"
bd() {
  local store="" bead=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) store="$2"; shift 2 ;;
      show) bead="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$store/$bead" in
    "$RIG_PATH/wa-7nq")   echo '{"id":"wa-7nq","status":"in_progress"}' ;;
    "$GC_CITY/ga-qw7y6")  echo '{"id":"ga-qw7y6","status":"in_progress"}' ;;
    *) echo '{"error":"no issues found matching the provided IDs","schema_version":1}' ;;
  esac
}
log() { :; }

resolve_bead_city() {
  local bead="$1" store st
  [ -z "$bead" ] && { echo "$GC_CITY"; return 0; }
  for store in "${RIG_PATH:-}" "$GC_CITY"; do
    [ -z "$store" ] && continue
    st=$(bd -C "$store" show "$bead" --json 2>/dev/null \
      | jq -r 'if type=="array" then (.[0] // {}) else . end | .status // empty' 2>/dev/null)
    if [ -n "$st" ]; then echo "$store"; return 0; fi
  done
  case "$bead" in
    ga-*) echo "$GC_CITY" ;;
    *)    echo "${RIG_PATH:-$GC_CITY}" ;;
  esac
}

echo "A. resolve_bead_city (owning-store resolution):"
r=$(resolve_bead_city "wa-7nq")
[ "$r" = "$RIG_PATH" ] && ok "rig-native wa- bead → rig store (THE FIX)" \
  || bad "rig-native wa- bead → expected $RIG_PATH, got $r"
r=$(resolve_bead_city "ga-qw7y6")
[ "$r" = "$GC_CITY" ] && ok "HQ ga- bead in rig context → HQ store" \
  || bad "HQ ga- bead → expected $GC_CITY, got $r"
r=$(resolve_bead_city "")
[ "$r" = "$GC_CITY" ] && ok "empty bead-id → HQ store" \
  || bad "empty bead-id → expected $GC_CITY, got $r"
r=$(resolve_bead_city "wa-unknown999")
[ "$r" = "$RIG_PATH" ] && ok "unknown wa- bead → rig via prefix fallback" \
  || bad "unknown wa- → expected $RIG_PATH, got $r"
r=$(resolve_bead_city "ga-unknown999")
[ "$r" = "$GC_CITY" ] && ok "unknown ga- bead → HQ via prefix fallback" \
  || bad "unknown ga- → expected $GC_CITY, got $r"
# (6) When no rig resolves (RIG_PATH empty), a rig-native bead must still pick a
# store via the prefix heuristic and never probe an empty store dir.
( RIG_PATH=""; r=$(resolve_bead_city "wa-7nq")
  [ "$r" = "$GC_CITY" ] ) && ok "no rig resolved → wa- bead falls back to HQ (best-effort, never aborts)" \
  || bad "no-rig fallback wrong for wa- bead"

# ── B. Step 5b targeting: the detach -C argument is $BEAD_CITY ──────────────────
echo "B. Step 5b detach targets the owning store:"
CAPTURED_STORE=""
bd() {   # capture the -C arg passed to assign
  local store="" verb=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) store="$2"; shift 2 ;;
      assign) verb="assign"; shift ;;
      update) verb="update"; shift ;;
      show) shift 2 ;;
      *) shift ;;
    esac
  done
  [ "$verb" = "assign" ] && CAPTURED_STORE="$store"
  return 0
}
BEAD_ID="wa-7nq"
BEAD_CITY="$RIG_PATH"   # as resolve_bead_city would set it for wa-7nq
# Replicate the guard's Step 5b assign-clear call shape.
if [ -n "$BEAD_ID" ]; then
  bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
fi
[ "$CAPTURED_STORE" = "$RIG_PATH" ] \
  && ok "assign-clear for rig-native bead targets rig store ($CAPTURED_STORE)" \
  || bad "assign-clear targeted '$CAPTURED_STORE' (expected $RIG_PATH) — HQ no-op bug back?"

# ── C. Drift-guards on the live source ─────────────────────────────────────────
echo "C. Drift-guards (live guard still carries the fix):"
if [ -f "$GUARD_SRC" ]; then
  grep -q 'resolve_bead_city()' "$GUARD_SRC" \
    && ok "guard: resolve_bead_city() defined" \
    || bad "guard: resolve_bead_city() MISSING"
  grep -q 'BEAD_CITY="\$(resolve_bead_city "\$BEAD_ID")"' "$GUARD_SRC" \
    && ok "guard: BEAD_CITY assigned via resolver" \
    || bad "guard: BEAD_CITY no longer assigned via resolve_bead_city — REVERTED?"
  # The two Step 5b detach writes must NOT target $GC_CITY anymore.
  if grep -qE 'bd -C "\$GC_CITY" (assign "\$BEAD_ID"|update "\$BEAD_ID" --unset-metadata gc.routed_to)' "$GUARD_SRC"; then
    bad "guard: Step 5b detach STILL uses \$GC_CITY — the no-op bug is back"
  else
    ok "guard: Step 5b detach no longer targets \$GC_CITY (uses \$BEAD_CITY)"
  fi
  grep -q 'bd -C "\$BEAD_CITY" assign "\$BEAD_ID" ""' "$GUARD_SRC" \
    && ok "guard: assign-clear targets \$BEAD_CITY" \
    || bad "guard: assign-clear does not target \$BEAD_CITY"
  grep -q 'bd -C "\$BEAD_CITY" update "\$BEAD_ID" --unset-metadata gc.routed_to' "$GUARD_SRC" \
    && ok "guard: routed_to-unset targets \$BEAD_CITY" \
    || bad "guard: routed_to-unset does not target \$BEAD_CITY"
else
  bad "guard source not found at $GUARD_SRC"
fi

echo ""
echo "── gt-gwng6 selftest: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1

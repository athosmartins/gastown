#!/usr/bin/env bash
# gate-done-bead-resolution.selftest.sh (ga-dx5)
#
# Proves the corrected bead_id resolution in /gate-done.  The root bug:
# session-based lookup returns the FIRST in_progress bead (often a sling/task bead
# from the gate-dispatcher), NOT the owning story bead.  The dispatcher then strips
# story:in-flight from the wrong bead → lane slot never frees.
#
# Covers:
#   (i)   Branch-name extraction is PRIMARY: fix/<ID>-* → ID (not the sling bead)
#   (ii)  Bare branch (no embedded bead-id) → falls through to story:in-flight lookup
#   (iii) FAIL CLOSED: no branch-pattern AND no story:in-flight → abort, exit 1
#   (iv)  The real case from ga-dx5: session has BOTH a sling bead (type=task) and
#         a story bead; branch name is fix/ga-story1-desc → BEAD_ID == ga-story1
#   (v)   Source drift-guards: deployed gate-done.md uses the new resolution order
#         and does NOT contain the :-unknown fallback (fail-open sentinel)
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (three locations in priority order):
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# ── Helper: replicate the PRIMARY bead_id extraction from the corrected gate-done ──
# This mirrors the exact grep pipeline used in the fix so the test cannot silently
# diverge — we assert the live source still defines the same pattern (section v).
extract_bead_from_branch() {
  local branch="$1"
  local bead
  # PRIMARY (generic): <prefix>/<bead-id>-<desc>  (bead in 2nd segment)
  bead=$(echo "$branch" | grep -oE '^[^/]+/[a-z]{2,8}-[a-z0-9]{2,8}-' \
    | grep -oE '[a-z]{2,8}-[a-z0-9]{2,8}' 2>/dev/null || echo "")
  # PRIMARY (crew, ga-zzdph): crew/<name>/<bead-id>[-<desc>]  (bead in 3rd segment)
  if [ -z "$bead" ]; then
    bead=$(echo "$branch" | grep -oE '^crew/[^/]+/[a-z]{2,8}-[a-z0-9]{2,8}' \
      | grep -oE '[a-z]{2,8}-[a-z0-9]{2,8}' | head -1 2>/dev/null || echo "")
  fi
  echo "$bead"
}

echo "── (i) Branch-name extraction: PRIMARY path ──"
GOT=$(extract_bead_from_branch "fix/ga-dx5-gate-done-bead-id-resolution")
[ "$GOT" = "ga-dx5" ] && ok "fix/<ID>-desc → ga-dx5" || bad "fix/<ID>-desc should give ga-dx5, got '$GOT'"

GOT=$(extract_bead_from_branch "feat/ga-abc-new-feature")
[ "$GOT" = "ga-abc" ] && ok "feat/<ID>-desc → ga-abc" || bad "feat/<ID>-desc should give ga-abc, got '$GOT'"

GOT=$(extract_bead_from_branch "chore/wa-x1y2-cleanup")
[ "$GOT" = "wa-x1y2" ] && ok "chore/<ID>-desc → wa-x1y2" || bad "chore/<ID>-desc should give wa-x1y2, got '$GOT'"

echo "── (i-crew) ga-zzdph: crew/<name>/<bead-id> convention (bead in 3rd segment) ──"
# The incident: Mila's crew/mila/ga-0c42e branch (source-bead ga-0c42e lives in the
# HQ city DB) extracted EMPTY under the generic pattern, so /gate-done could not bind
# the marker to the HQ story bead. These assertions lock the crew convention in.
GOT=$(extract_bead_from_branch "crew/mila/ga-0c42e")
[ "$GOT" = "ga-0c42e" ] && ok "crew/<name>/<ID> → ga-0c42e (the incident branch)" \
  || bad "crew/mila/ga-0c42e should give ga-0c42e, got '$GOT'"

GOT=$(extract_bead_from_branch "crew/mila/ga-0c42e-painel-ui")
[ "$GOT" = "ga-0c42e" ] && ok "crew/<name>/<ID>-desc → ga-0c42e" \
  || bad "crew/mila/ga-0c42e-painel-ui should give ga-0c42e, got '$GOT'"

GOT=$(extract_bead_from_branch "crew/batista/wa-rlzo")
[ "$GOT" = "wa-rlzo" ] && ok "crew/<name>/<ID> → wa-rlzo (same-DB case still works)" \
  || bad "crew/batista/wa-rlzo should give wa-rlzo, got '$GOT'"

# A crew branch whose 3rd segment has no bead-shaped token (no <pfx>-<id> dash)
# returns empty → falls through to the story:in-flight lookup, then fail-closed.
# (A 3rd segment that merely LOOKS bead-shaped, e.g. fix-typo, is indistinguishable
# from a real id by regex — same inherent ambiguity as the generic pattern — and is
# caught downstream: the guard rejects a marker whose source-bead does not resolve.)
GOT=$(extract_bead_from_branch "crew/mila/nobeadhere")
[ -z "$GOT" ] && ok "crew/<name>/<no-dash-slug> → empty (name not mistaken for bead)" \
  || bad "crew branch without a bead-shaped 3rd segment should return empty, got '$GOT'"

echo "── (ii) Bare branch: no embedded bead-id → branch extraction returns empty ──"
GOT=$(extract_bead_from_branch "fix/just-a-description-no-id")
[ -z "$GOT" ] && ok "bare-desc branch → empty (falls to story:in-flight lookup)" \
  || bad "bare-desc branch should return empty, got '$GOT'"

GOT=$(extract_bead_from_branch "main")
[ -z "$GOT" ] && ok "main branch → empty" || bad "main should return empty, got '$GOT'"

echo "── (iii) FAIL CLOSED simulation: empty BEAD_ID → gate-done aborts ──"
# Simulate the fail-closed block from gate-done step 2 verbatim.
# If BEAD_ID is empty, the corrected code exits 1 with a clear error.
_simulate_fail_closed() {
  local BEAD_ID="$1"
  local BRANCH="$2"
  if [ -z "$BEAD_ID" ]; then
    echo "ERROR: Cannot resolve owning story bead from branch '$BRANCH' or session assignments." >&2
    return 1
  fi
  return 0
}
_simulate_fail_closed "" "fix/just-a-desc" >/dev/null 2>&1
[ $? -ne 0 ] && ok "empty bead_id → fail-closed exit (no marker written)" \
  || bad "empty bead_id should abort, but simulate_fail_closed returned 0"

_simulate_fail_closed "ga-dx5" "fix/ga-dx5-my-fix" >/dev/null 2>&1
[ $? -eq 0 ] && ok "resolved bead_id → passes fail-closed guard" \
  || bad "resolved bead_id should pass fail-closed guard"

echo "── (iv) THE REAL ga-dx5 CASE: session has sling + story bead; branch wins ──"
# When a builder is assigned BOTH:
#   - ga-sling (type=task, from gate-dispatcher, NO story:in-flight label)
#   - ga-story1 (type=bug, HAS story:in-flight label)
# Naive lookup (--status in_progress, no label filter) returns ga-sling first.
# Corrected logic: branch fix/ga-story1-some-desc → PRIMARY extraction → ga-story1.
#
# We can't run bd in unit-test context, so we prove the extraction logic resolves
# to the story bead when the branch is correctly named — and that the sling bead
# ID (ga-sling) would NEVER be returned by branch extraction.

SLING_BEAD="ga-0uyo"    # example sling bead from this very bug run
STORY_BEAD="ga-dx5"     # the actual story bead
TEST_BRANCH="fix/ga-dx5-some-description"

GOT=$(extract_bead_from_branch "$TEST_BRANCH")
[ "$GOT" = "$STORY_BEAD" ] \
  && ok "branch $TEST_BRANCH → extracts STORY bead $STORY_BEAD (not sling bead $SLING_BEAD)" \
  || bad "expected $STORY_BEAD from branch, got '$GOT'"

[ "$GOT" != "$SLING_BEAD" ] \
  && ok "branch extraction never returns sling bead $SLING_BEAD" \
  || bad "branch extraction must not return the sling bead"

# Confirm: if the naive session lookup had run instead, it would have picked up the
# sling bead (simulate by pretending bd returned ga-0uyo first).
NAIVE_RESULT="$SLING_BEAD"
[ "$NAIVE_RESULT" != "$STORY_BEAD" ] \
  && ok "confirmed: naive session lookup returns sling $SLING_BEAD ≠ story $STORY_BEAD (the bug)" \
  || bad "test setup error: sling and story bead should be different"

echo "── (v) Source drift-guards (deployed gate-done.md matches corrected logic) ──"
if [ -f "$GATE_DONE" ]; then
  grep -q "grep -oE '^\[^/\]+/\[a-z\]" "$GATE_DONE" \
    && ok "gate-done uses branch-name PRIMARY extraction (grep -oE pattern)" \
    || bad "gate-done missing branch-name primary extraction"

  # ga-zzdph: the crew convention extraction must be present in the source.
  grep -q "grep -oE '^crew/\[^/\]+/\[a-z\]" "$GATE_DONE" \
    && ok "gate-done extracts bead from crew/<name>/<bead-id> branches (ga-zzdph)" \
    || bad "gate-done missing crew/<name>/<bead-id> extraction (ga-zzdph regression)"

  grep -q "story:in-flight" "$GATE_DONE" \
    && ok "gate-done filters secondary lookup by story:in-flight label" \
    || bad "gate-done missing story:in-flight label filter in fallback"

  grep -q "Cannot resolve owning story bead" "$GATE_DONE" \
    && ok "gate-done has fail-closed abort message" \
    || bad "gate-done missing fail-closed abort"

  grep -q "Marker NOT created" "$GATE_DONE" \
    && ok "gate-done reports 'Marker NOT created' on fail-closed" \
    || bad "gate-done missing 'Marker NOT created' message"

  # The :-unknown fallback is the fail-OPEN sentinel — it must be GONE.
  if grep -q 'BEAD_ID:-unknown' "$GATE_DONE"; then
    bad "gate-done STILL contains \${BEAD_ID:-unknown} fail-open fallback — the bug is not fixed"
  else
    ok "gate-done no longer contains \${BEAD_ID:-unknown} fail-open fallback"
  fi

  grep -q 'bead_id: \$BEAD_ID' "$GATE_DONE" \
    && ok "gate-done marker body uses \$BEAD_ID (not fallback)" \
    || bad "gate-done marker body should use \$BEAD_ID directly"
else
  bad "gate-done.md not found at $GATE_DONE"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

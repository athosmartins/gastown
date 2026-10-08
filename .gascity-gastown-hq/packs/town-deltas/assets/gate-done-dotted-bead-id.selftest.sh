#!/usr/bin/env bash
# gate-done-dotted-bead-id.selftest.sh (ga-ovz0up)
#
# Proves /gate-done (Step 2) and the quality-gate guard AGREE on which bead ids
# are valid — in particular ids with TWO or more dotted levels (wa-d3ys32.2.1,
# a child of a child; the E11 slicing cap produces exactly this shape) and ids
# whose suffix is longer than 8 chars (wa-prodmotor).
#
# Root incident (ga-ovz0up, wa-worker-1, 2026-10-08, bead wa-d3ys32.2.1): the two
# sides had DIFFERENT limits for the same field, so a bead id one side accepted
# the other rejected:
#   gate-done.md Step 2   one dotted level '(\.[0-9]+)?', suffix [a-z0-9]{2,8}
#   guard validate_bead_id one dotted level '(\.[0-9]{1,4})?', suffix [a-z0-9]{2,16}
# With two levels Step 2 matched the PARENT (wa-d3ys32.2), the identity
# pre-filter discarded it, and /gate-done aborted ("Cannot resolve owning story
# bead"). Hand-patching only Step 2 made a marker the guard then rejected
# ("invalid/unsafe field values" -> gate-status:error). Fixing one side only
# moves the failure to the other, so this test checks the CONTRACT between them.
#
# Both sides are exercised as the REAL artifact, never a copy of their regex:
#   - Step 2: the real branch->bead-id block is cut out of gate-done.md (from
#     `_BRANCH_SEG=""` to the closing `esac`) and eval'd. Run against BOTH
#     bodies (commands/gate-done.md and internal/templates/.../gate-done.md).
#   - guard : validate_bead_id / validate_branch are called from the real
#     quality-gate-guard.sh (sourced with GATE_GUARD_LIB_ONLY=1).
#
# Covers:
#   (A) 2- and 3-level dotted ids resolve from crew/* and generic branches
#   (B) suffix up to 16 chars resolves (aligned with the guard's cap)
#   (C) controls: ids that already worked keep resolving the same way
#   (D) beyond the shared ceiling (4 levels, 5-digit sub-id) -> Step 2 gives
#       EMPTY (fail closed), never the truncated parent
#   (E) CONTRACT: every id Step 2 resolves is accepted by validate_bead_id
#   (F) the guard validator still rejects everything unsafe (security ceiling)
#   (G) mutation guard: the pre-fix guard regex rejects wa-d3ys32.2.1, so (E)
#       would have caught the live incident
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
BODIES=(
  "$SELF_DIR/../../../commands/gate-done.md"
  "$SELF_DIR/../../../../internal/templates/commands/bodies/gate-done.md"
)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

# shellcheck disable=SC1090
GATE_GUARD_LIB_ONLY=1 . "$GUARD"
set +e  # the guard sources with `set -euo pipefail`; this harness counts its own pass/fail
if ! type validate_bead_id >/dev/null 2>&1 || ! type validate_branch >/dev/null 2>&1; then
  echo "FATAL: validate_bead_id/validate_branch did not load from $GUARD in lib-only mode" >&2
  echo "  (they must sit above the GATE_GUARD_LIB_ONLY cutoff so the real function is testable)" >&2
  exit 2
fi

# step2_block <gate-done.md> — the real branch->BEAD_ID block, verbatim.
# Anchors on its first statement and the first column-0 `esac` after it (inner
# esacs are indented). An absent anchor yields an EMPTY block, which the caller
# treats as a hard failure — never as "resolved to empty".
step2_block() {
  awk '
    !on && /^_BRANCH_SEG=""$/ { on=1 }
    on { print }
    on && /^esac$/ { exit }
  ' "$1"
}

# resolve <block> <branch> — run the real Step 2 block, print BEAD_ID.
resolve() {
  local block="$1" branch="$2"
  ( BRANCH="$branch"; BEAD_ID=""; eval "$block" >/dev/null 2>&1; printf '%s' "${BEAD_ID:-}" )
}

# Expected results of Step 2 per branch. Format: "<branch>|<expected BEAD_ID>".
# Empty expectation = Step 2 must fail closed (EMPTY), not return a parent.
CASES_RESOLVE=(
  # (A) the incident: two dotted levels, crew + generic arms, with/without -desc
  "crew/wa-worker/wa-d3ys32.2.1|wa-d3ys32.2.1"
  "crew/wa-worker/wa-d3ys32.2.1-slice-two|wa-d3ys32.2.1"
  "fix/wa-d3ys32.2.1-desc|wa-d3ys32.2.1"
  "fix/wa-d3ys32.2.1|wa-d3ys32.2.1"
  "crew/wa-worker/wa-d3ys32.2.1.3|wa-d3ys32.2.1.3"
  "fix/wa-d3ys32.2.1.3-desc|wa-d3ys32.2.1.3"
  # (B) suffix longer than 8 chars (guard accepts up to 16)
  "crew/wa-worker/wa-prodmotor|wa-prodmotor"
  "fix/wa-prodmotor-desc|wa-prodmotor"
  "crew/wa-worker/wa-abcdefghijklmnop|wa-abcdefghijklmnop"
  # (C) controls: shapes that already worked must not move
  "fix/ga-dx5-my-fix|ga-dx5"
  "crew/ps-worker/ps-8iuu.4|ps-8iuu.4"
  "fix/ga-sfj3i.4-desc|ga-sfj3i.4"
  "fix/ps-8iuu.12-worker-fix|ps-8iuu.12"
  "crew/gastown-dog-3/ga-580b4z|ga-580b4z"
  "fix/ga-okcgb|ga-okcgb"
  # hyphen inside a custom id: the block still yields the leading token; the
  # full id is recovered later by the ga-3xuanq store-identity upgrade
  "crew/mila/wa-campanha-diaria|wa-campanha"
  # (D) past the shared ceiling -> fail closed, never the truncated parent
  "crew/wa-worker/wa-d3ys32.1.2.3.4|"
  "fix/wa-d3ys32.1.2.3.4-desc|"
  "crew/wa-worker/wa-x1y2.12345|"
  "fix/wa-x1y2.12345-desc|"
  "crew/wa-worker/wa-abcdefghijklmnopq|"
)

for BODY in "${BODIES[@]}"; do
  if [ ! -f "$BODY" ]; then
    bad "gate-done body not found: $BODY"
    continue
  fi
  LABEL="$(basename "$(dirname "$(dirname "$BODY")")")/$(basename "$(dirname "$BODY")")"
  echo "── Step 2 of $LABEL/gate-done.md ──"
  BLOCK=$(step2_block "$BODY")
  if [ -z "$BLOCK" ]; then
    bad "could not cut the Step 2 branch->bead block out of $BODY (anchor changed?) — nothing below is meaningful"
    continue
  fi
  # Control: the extraction must be able to resolve a plain id at all. Without
  # this, a block that never sets BEAD_ID would make every expected-EMPTY case
  # in (D) pass vacuously.
  CTRL=$(resolve "$BLOCK" "fix/ga-dx5-my-fix")
  if [ "$CTRL" != "ga-dx5" ]; then
    bad "control fix/ga-dx5-my-fix did not resolve to ga-dx5 (got '$CTRL') — extracted block is not exercising Step 2; skipping its cases"
    continue
  fi
  for ROW in "${CASES_RESOLVE[@]}"; do
    BR="${ROW%%|*}"; WANT="${ROW#*|}"
    GOT=$(resolve "$BLOCK" "$BR")
    if [ "$GOT" = "$WANT" ]; then
      ok "$BR → '${GOT:-<empty, fail closed>}'"
    else
      bad "$BR → expected '${WANT:-<empty, fail closed>}', got '${GOT:-<empty>}'"
    fi
    # (E) CONTRACT: whatever Step 2 hands to the marker, the guard must accept.
    if [ -n "$GOT" ]; then
      if validate_bead_id "$GOT"; then
        ok "   guard accepts what Step 2 produced: '$GOT'"
      else
        bad "   CONTRACT BREAK: Step 2 produced '$GOT' but validate_bead_id rejects it (marker would land in gate-status:error)"
      fi
      if validate_branch "$BR"; then
        ok "   guard accepts the branch '$BR'"
      else
        bad "   CONTRACT BREAK: validate_branch rejects '$BR'"
      fi
    fi
  done
done

# (F) the guard validator is a security check (injection / ref confusion): the
# widening above must not loosen it beyond dotted levels + the 16-char suffix.
echo "── (F) validate_bead_id: still rejects everything unsafe ──"
for V in "" "WA-D3YS32" "wa-d3ys32." "wa-d3ys32.2." "wa-d3ys32..2" "wa-d3ys32.a" \
         "wa-d3ys32.1.2.3.4" "wa-d3ys32.12345" "wa-d3ys32.2.1.12345" "wa-abcdefghijklmnopq" \
         "wa-a" "-d3ys32" "wa-d3ys32;id" 'wa-d3ys32$(id)' 'wa-d3ys32`id`' "wa-d3ys32 x" \
         "wa-d3ys32/../x" "wa_d3ys32" $'wa-d3ys32\nrm' $'wa-d3ys32.2\n.1'; do
  if validate_bead_id "$V"; then
    bad "validate_bead_id ACCEPTED unsafe/malformed value: $(printf '%q' "$V")"
  else
    ok "validate_bead_id rejects $(printf '%q' "$V")"
  fi
done
echo "── (F2) validate_bead_id: accepts the legitimate shapes ──"
for V in "ga-xj6rp0" "ga-qw3p.1" "wa-d3ys32.2.1" "wa-d3ys32.2.1.3" "wa-prodmotor" "wa-abcdefghijklmnop" "ps-8iuu.12" "gt-abc123"; do
  if validate_bead_id "$V"; then ok "validate_bead_id accepts '$V'"; else bad "validate_bead_id REJECTED legitimate id '$V'"; fi
done

# (G) mutation guard: the PRE-FIX guard pattern. If it accepted the incident id,
# (E)/(F2) above would not prove anything about the fix.
echo "── (G) mutation guard: pre-fix guard regex reproduces the incident ──"
if [[ "wa-d3ys32.2.1" =~ ^[a-z]{1,8}-[a-z0-9]{2,16}(\.[0-9]{1,4})?$ ]]; then
  bad "pre-fix guard regex unexpectedly accepts wa-d3ys32.2.1 — (E)/(F2) would not catch a reversion"
else
  ok "pre-fix guard regex rejects wa-d3ys32.2.1 (the incident) — (E)/(F2) discriminate"
fi

echo
echo "gate-done-dotted-bead-id: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

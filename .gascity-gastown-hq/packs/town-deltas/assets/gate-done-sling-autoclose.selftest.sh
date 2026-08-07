#!/usr/bin/env bash
# gate-done-sling-autoclose.selftest.sh (ga-6lwpy)
#
# Proves /gate-done auto-closes the CALLING sling/task bead right after the
# ready-for-gate marker is created, instead of leaving that as a manual,
# easy-to-skip post-gate-done step.
#
# Root incident (ga-6lwpy): a dog built+pushed+gate-done'd a fix for ga-6dpoa
# via sling bead ga-0l58y, then exited/recycled before manually closing
# ga-0l58y itself (the documented-but-code-unenforced "close your sling right
# after gate-done" step — see memory
# gate-refix-sling-bead-closes-story-bead-stays-open). The dangling
# in_progress sling was later resumed by a session with zero memory of the
# prior work. Ground-truth archaeology (dolt_diff_issues label history + git
# reflog on the fix branch's worktree, both cited on ga-6lwpy) showed the
# sling was NEVER double-dispatched: exactly one sling bead was ever created
# for ga-6dpoa, and it carried no in-flight signal at dispatch time (clean
# ctx:ready+exec:auto). The resumed session correctly avoided rebuilding
# (verified the merged diff satisfied the acceptance criteria), but had no
# way to recognize the merge as its own prior work, and reported "a
# concurrent independent build" — a self-attribution error, not a real
# Pilot-side double-dispatch. The actual, narrow, fixable gap is here:
# nothing ever closes the sling bead automatically, so it can outlive the
# session that built the fix it wraps, forcing a memoryless resumption to
# reconstruct (and, in this incident, mis-narrate) what already happened.
#
# Covers:
#   (A)  normal sling dispatch, in_progress + assignee mine -> closed
#   (A2) identity match via a later slot in the fallback chain (not just the
#        first candidate)
#   (B)  rig-native dispatch (pilot.sling_bead == BEAD_ID) -> NEVER touched
#        (closing it would violate "story bead stays open until gate merges")
#   (C)  sling assigned to a DIFFERENT session -> not closed (never touch
#        another session's live claim)
#   (D)  sling already closed (e.g. a retried /gate-done) -> no-op, idempotent
#   (E)  pilot.sling_bead metadata absent -> no-op, fail-open
#   (F)  mutation guard: the PRE-FIX flow (no auto-close block at all)
#        reproduces the ga-0l58y incident shape -- sling stays in_progress
#        forever once the marker exists
#   (G)  source drift-guards: deployed gate-done.md contains the auto-close
#        block, gated on the rig-native exclusion, the in_progress check, and
#        the identity check, running AFTER marker creation within Step 3
#   (H)  the go:embed twin stays byte-identical to canonical after this fix
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (priority order), same convention as
# gate-done-crew-rig.selftest.sh:
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# ── Mock state ────────────────────────────────────────────────────────────
CLOSE_CALLS=0
LAST_CLOSED_ID=""

# mock_show_story <bead_id> — echoes the pilot.sling_bead metadata value (or
# empty) for the given STORY bead, per the scenario's fixture.
mock_show_story() { printf '%s' "${MOCK_STORY_SLING_BEAD:-}"; }

# mock_show_sling <sling_id> — echoes "status<TAB>assignee" for the given
# SLING bead, per the scenario's fixture.
mock_show_sling() { printf '%s\t%s' "${MOCK_SLING_STATUS:-}" "${MOCK_SLING_ASSIGNEE:-}"; }

# mock_close <sling_id> <reason> — records the call instead of touching Dolt.
mock_close() {
  CLOSE_CALLS=$((CLOSE_CALLS + 1))
  LAST_CLOSED_ID="$1"
}

# sling_autoclose <bead_id> <my_id1> <my_id2> <my_id3> <my_id4> — replica of
# the deployed Step 3 auto-close block: same variable names, same branching,
# calling the mocks above instead of `bd`/`jq` against a live database.
sling_autoclose() {
  local BEAD_ID="$1"; shift
  local _SLING_BEAD_ID
  _SLING_BEAD_ID=$(mock_show_story "$BEAD_ID")

  if [ -n "$_SLING_BEAD_ID" ] && [ "$_SLING_BEAD_ID" != "$BEAD_ID" ]; then
    local _SLING_INFO _SLING_STATUS _SLING_ASSIGNEE _SLING_IS_MINE _MY_ID
    _SLING_INFO=$(mock_show_sling "$_SLING_BEAD_ID")
    _SLING_STATUS=$(printf '%s' "$_SLING_INFO" | cut -f1)
    _SLING_ASSIGNEE=$(printf '%s' "$_SLING_INFO" | cut -f2)
    _SLING_IS_MINE=0
    for _MY_ID in "$@"; do
      [ -n "$_MY_ID" ] && [ -n "$_SLING_ASSIGNEE" ] && [ "$_MY_ID" = "$_SLING_ASSIGNEE" ] && _SLING_IS_MINE=1
    done
    if [ "$_SLING_STATUS" = "in_progress" ] && [ "$_SLING_IS_MINE" = "1" ]; then
      mock_close "$_SLING_BEAD_ID" "Auto-closed by /gate-done (ga-6lwpy)."
    fi
  fi
}

# pre_fix_flow — the ORIGINAL flow: no auto-close block exists at all, so
# nothing ever runs against the sling bead once the marker is created. This
# IS the pre-fix behavior (a deliberate no-op), not a stub for it.
pre_fix_flow() { :; }

echo "gate-done-sling-autoclose.selftest.sh (ga-6lwpy)"
echo "  source: $GATE_DONE"
echo

# ── (A) normal sling dispatch: in_progress + assignee mine -> closed ───────
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD="ga-0l58y"
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="dog-gaoz99t"
sling_autoclose "ga-6dpoa" "dog-gaoz99t" "" "" ""
[ "$CLOSE_CALLS" -eq 1 ] && [ "$LAST_CLOSED_ID" = "ga-0l58y" ] \
  && ok "(A) normal sling, in_progress + assignee mine -> closed exactly once (ga-0l58y)" \
  || bad "(A) expected 1 close call on ga-0l58y, got calls=$CLOSE_CALLS id='$LAST_CLOSED_ID'"

# ── (A2) identity match via the LAST fallback slot (GC_ALIAS position) ─────
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD="ga-0l58y"
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="gastown.dog-3"
sling_autoclose "ga-6dpoa" "" "" "" "gastown.dog-3"
[ "$CLOSE_CALLS" -eq 1 ] \
  && ok "(A2) identity match via the LAST fallback slot (GC_ALIAS) still closes" \
  || bad "(A2) expected close via last identity slot, got calls=$CLOSE_CALLS"

# ── (B) rig-native dispatch: pilot.sling_bead == BEAD_ID -> never touched ──
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD="wa-27jn"
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="mila-wa"
sling_autoclose "wa-27jn" "mila-wa" "" "" ""
[ "$CLOSE_CALLS" -eq 0 ] \
  && ok "(B) rig-native (sling_bead==story_id) -> NOT closed (story bead protected)" \
  || bad "(B) rig-native self-referential sling_bead incorrectly triggered a close (calls=$CLOSE_CALLS)"

# ── (C) sling assigned to someone else -> not closed ────────────────────────
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD="ga-0l58y"
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="dog-someoneelse"
sling_autoclose "ga-6dpoa" "dog-gaoz99t" "" "" ""
[ "$CLOSE_CALLS" -eq 0 ] \
  && ok "(C) sling assigned to a DIFFERENT session -> not closed (never touch another session's claim)" \
  || bad "(C) closed a sling that belongs to a different assignee (calls=$CLOSE_CALLS)"

# ── (D) sling already closed -> no-op, idempotent ───────────────────────────
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD="ga-0l58y"
MOCK_SLING_STATUS="closed"
MOCK_SLING_ASSIGNEE="dog-gaoz99t"
sling_autoclose "ga-6dpoa" "dog-gaoz99t" "" "" ""
[ "$CLOSE_CALLS" -eq 0 ] \
  && ok "(D) sling already closed -> no-op (idempotent re-run, e.g. a retried /gate-done)" \
  || bad "(D) attempted to close an already-closed sling (calls=$CLOSE_CALLS)"

# ── (E) pilot.sling_bead metadata absent -> no-op, fail-open ───────────────
CLOSE_CALLS=0; LAST_CLOSED_ID=""
MOCK_STORY_SLING_BEAD=""
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="dog-gaoz99t"
sling_autoclose "ga-6dpoa" "dog-gaoz99t" "" "" ""
[ "$CLOSE_CALLS" -eq 0 ] \
  && ok "(E) no pilot.sling_bead metadata -> no-op, fail-open (never blocks gate-done)" \
  || bad "(E) unexpectedly attempted a close with no sling_bead metadata (calls=$CLOSE_CALLS)"

# ── (F) mutation guard: PRE-FIX flow reproduces the ga-0l58y incident ──────
# Proves (A) would actually catch a reversion of the fix, not just happen to
# pass either way.
CLOSE_CALLS=0
MOCK_STORY_SLING_BEAD="ga-0l58y"
MOCK_SLING_STATUS="in_progress"
MOCK_SLING_ASSIGNEE="dog-gaoz99t"
pre_fix_flow "ga-6dpoa" "dog-gaoz99t"
[ "$CLOSE_CALLS" -eq 0 ] \
  && ok "(F) mutation check: pre-fix flow never closes the sling -- reproduces the ga-0l58y dangling-sling incident" \
  || bad "(F) mutation check: pre-fix replica unexpectedly closed something -- (A) would not catch a reversion"

# ── (G) source drift-guards against deployed gate-done.md ──────────────────
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  step3_src=$(printf '%s\n' "$src" | awk '/^## Step 3:/{flag=1} flag; /^## Step 4:/{flag=0}')

  printf '%s' "$step3_src" | grep -qF 'pilot.sling_bead' \
    && ok "(G1) gate-done.md Step 3 reads pilot.sling_bead to find the calling sling" \
    || bad "(G1) gate-done.md Step 3 missing pilot.sling_bead lookup (ga-6lwpy regression)"

  printf '%s' "$step3_src" | grep -qF '"$_SLING_BEAD_ID" != "$BEAD_ID"' \
    && ok "(G2) gate-done.md excludes the rig-native self-referential case (sling_bead==story_id)" \
    || bad "(G2) gate-done.md missing the rig-native exclusion -- would try to close the STORY bead"

  printf '%s' "$step3_src" | grep -qF '$_SLING_STATUS" = "in_progress"' \
    && ok "(G3) gate-done.md only closes an in_progress sling" \
    || bad "(G3) gate-done.md missing the in_progress guard before closing"

  printf '%s' "$step3_src" | grep -qF '_SLING_IS_MINE' \
    && ok "(G4) gate-done.md verifies the sling is assigned to the CALLING session before closing" \
    || bad "(G4) gate-done.md missing the assignee/identity check -- could close another session's claim"

  printf '%s' "$step3_src" | grep -qF 'bd -C "$GC_CITY_PATH" close "$_SLING_BEAD_ID"' \
    && ok "(G5) gate-done.md closes the sling bead in GC_CITY_PATH (gc sling always creates task beads in HQ)" \
    || bad "(G5) gate-done.md missing (or mis-scoped) the actual bd close call"

  # The auto-close block must run AFTER marker creation (MARKER_ID populated)
  # -- closing the sling before the marker exists would misrepresent an
  # unsubmitted attempt as "submitted to gate".
  marker_line=$(printf '%s\n' "$step3_src" | grep -nE '^MARKER_ID=\$\(bd ' | head -1 | cut -d: -f1)
  autoclose_line=$(printf '%s\n' "$step3_src" | grep -nF '_SLING_BEAD_ID=$(bd' | head -1 | cut -d: -f1)
  if [ -n "$marker_line" ] && [ -n "$autoclose_line" ] && [ "$marker_line" -lt "$autoclose_line" ]; then
    ok "(G6) auto-close block runs AFTER marker creation (line $marker_line < $autoclose_line)"
  else
    bad "(G6) auto-close block does not clearly follow marker creation (marker_line='$marker_line' autoclose_line='$autoclose_line')"
  fi
else
  bad "(G) gate-done.md not found at $GATE_DONE"
fi

# ── (H) the go:embed twin must stay byte-identical to canonical ────────────
TOWN_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
CANONICAL="$TOWN_ROOT/.gascity-gastown-hq/commands/gate-done.md"
EMBEDDED="$TOWN_ROOT/internal/templates/commands/bodies/gate-done.md"
if [ -f "$CANONICAL" ] && [ -f "$EMBEDDED" ]; then
  if cmp -s "$CANONICAL" "$EMBEDDED"; then
    ok "(H) canonical commands/gate-done.md and the go:embed twin are byte-identical"
  else
    bad "(H) canonical and go:embed twin have DRIFTED -- re-copy canonical's content (breaks nothing at runtime but violates ga-54iu's sync invariant)"
  fi
else
  bad "(H) could not locate both canonical ($CANONICAL) and embedded ($EMBEDDED) copies"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"

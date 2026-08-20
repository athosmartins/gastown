#!/usr/bin/env bash
# gate-submitted-by-author-freeze.selftest.sh (ga-b3gso9)
#
# Proves gate.submitted_by / the gate-run's author field become FROZEN at
# the moment /gate-done creates the ready-for-gate marker (reading the
# source bead's assignee/created_by/owner at that exact, race-free instant)
# instead of being derived by quality-gate-guard.sh's Step 5 whenever its
# launchd sweep (~2min, StartInterval) happens to get around to the marker.
#
# ROOT CAUSE (confirmed by reading code, not by correlation — ga-b3gso9's
# AC #1): the ORIGINAL hypothesis in this bead was that the DISPATCHER
# re-derives author from the source bead's CURRENT assignee. That is only
# HALF right — quality-gate-dispatcher.sh Step 3 already prefers a frozen
# gate.submitted_by when present (ga-tkvsa) and never overwrites it. The
# real gap is one layer earlier: quality-gate-guard.sh Step 5 is the ONLY
# place gate.submitted_by ever gets WRITTEN, and it derives from the bead's
# CURRENT (racy) assignee at GUARD-SWEEP time, not at ORIGINAL-SUBMISSION
# time. Between a worker's /gate-done call (marker created, bead's
# gc.routed_to still live) and the guard's own sweep claiming that marker
# (which is what finally clears gc.routed_to, Step 5b), an unrelated
# pool-claim probe can legitimately claim the source bead and become its
# new assignee — reproduced live: wa-pwzn2/ga-0aanz7, gate.submitted_by
# froze as wa-worker-gaa1934f (a second session that merely claimed after
# the work was already done), not wa-worker-ga43ei3l (the actual fixer who
# submitted). Independently verified against the live bead data (not just
# the reporter's narrative): ga-0aanz7.metadata.gate.submitted_by ==
# "wa-worker-gaa1934f" and ga-uiqizi's description embeds
# "author: wa-worker-gaa1934f", both confirmed via `bd show --json`.
#
# THE FIX (two coordinated files, both plain shell/markdown — no engine
# rebuild needed, town-deltas + commands/*.md are both live-read, not
# compiled):
#   1. commands/gate-done.md Step 3: read the bead's assignee -> created_by
#      -> owner (SAME 3-tier priority the guard already trusts, SAME
#      security property — DB-authoritative, never worker self-declared —
#      just read EARLIER, synchronously, right after `bd create`, zero race
#      window) and freeze it onto the marker via --set-metadata
#      gate.submitted_by immediately.
#   2. quality-gate-guard.sh Step 5: prefer that frozen value when present,
#      skip the current-bead-state re-derivation entirely. Falls through to
#      the EXISTING derivation, unchanged, for markers without a frozen
#      value (legacy markers created before this fix — no regression).
#
# Covers:
#   (A)  gate-done freeze: assignee resolves -> gate.submitted_by = assignee
#   (B)  gate-done freeze: assignee empty, created_by resolves -> used
#   (C)  gate-done freeze: assignee+created_by empty, owner resolves -> used
#   (D)  gate-done freeze: all three empty -> gate.submitted_by NOT set
#        (third state: never invent a value, AC #5)
#   (E)  mutation guard: pre-fix gate-done flow (no freeze block) never sets
#        gate.submitted_by even when assignee resolves cleanly
#   (F)  guard Step 5: frozen value present -> used as AUTHOR, bead's
#        CURRENT (possibly hijacked) assignee is never consulted
#   (G)  guard Step 5: no frozen value (legacy marker) -> falls through to
#        the existing bead-derivation unchanged (no regression)
#   (H)  mutation guard: pre-fix guard Step 5 (no frozen-check) ALWAYS
#        re-derives from the bead's current state even when a frozen value
#        exists -- proves (F) would catch a reversion
#   (I)  INTEGRATION, the exact AC #3 scenario: marker submitted by session
#        A (gate-done freezes gate.submitted_by=A); session B then claims
#        the source bead while the gate-run is pending (bead's current
#        assignee becomes B). Post-fix pipeline (freeze + guard preference)
#        resolves AUTHOR=A. The PRE-FIX pipeline (guard always re-derives
#        from current bead state) resolves AUTHOR=B -- reproducing the bug.
#   (J)  source drift-guard: commands/gate-done.md's freeze block runs AFTER
#        the gate:queued stamp and reads the bead's OWN store (_BEAD_STORE)
#   (K)  source drift-guard: quality-gate-guard.sh's frozen-preference check
#        runs BEFORE the bead_field_grep-based derivation, inside the same
#        `if [ -n "$BEAD_ID" ]` block
#   (L)  the go:embed twin (internal/templates/commands/bodies/gate-done.md)
#        stays byte-identical to canonical commands/gate-done.md
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

GUARD_SH="$SELF_DIR/quality-gate-guard.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# ── Replica: gate-done.md's freeze block (Step 3) ───────────────────────────
# Same 3-tier priority, same third-state rule, as the deployed block. Mocks
# in MOCK_BEAD_ASSIGNEE / MOCK_BEAD_CREATED_BY / MOCK_BEAD_OWNER stand in for
# `bd show $BEAD_ID --json`'s .assignee/.created_by/.owner.
FROZEN_GATE_SUBMITTED_BY=""
FREEZE_WRITE_CALLS=0
gate_done_freeze_author() {
  local _submit_author=""
  _submit_author="${MOCK_BEAD_ASSIGNEE:-}"
  if [ -z "$_submit_author" ] || [ "$_submit_author" = "null" ]; then
    _submit_author="${MOCK_BEAD_CREATED_BY:-}"
  fi
  if [ -z "$_submit_author" ] || [ "$_submit_author" = "null" ]; then
    _submit_author="${MOCK_BEAD_OWNER:-}"
  fi
  if [ -n "$_submit_author" ] && [ "$_submit_author" != "null" ]; then
    FROZEN_GATE_SUBMITTED_BY="$_submit_author"
    FREEZE_WRITE_CALLS=$((FREEZE_WRITE_CALLS + 1))
  fi
}

# pre_fix_gate_done — the ORIGINAL flow: no freeze block exists at all, so
# gate.submitted_by is never written by gate-done, ever.
pre_fix_gate_done() { :; }

# ── Replica: quality-gate-guard.sh Step 5's author resolution ──────────────
# MOCK_MARKER_FROZEN stands in for the marker's gate.submitted_by metadata
# (as read back via `bd show $MARKER_ID --json`). MOCK_BEAD_ASSIGNEE/
# CREATED_BY/OWNER stand in for the bead's CURRENT DB state at guard-sweep
# time (which may have changed since gate-done ran, e.g. hijacked by a race).
RESOLVED_AUTHOR=""
guard_resolve_author() {
  if [ -n "${MOCK_MARKER_FROZEN:-}" ] && [ "${MOCK_MARKER_FROZEN}" != "null" ]; then
    RESOLVED_AUTHOR="$MOCK_MARKER_FROZEN"
    return
  fi
  local _a="${MOCK_BEAD_ASSIGNEE:-}"
  if [ -z "$_a" ] || [ "$_a" = "null" ]; then _a="${MOCK_BEAD_CREATED_BY:-}"; fi
  if [ -z "$_a" ] || [ "$_a" = "null" ]; then _a="${MOCK_BEAD_OWNER:-}"; fi
  RESOLVED_AUTHOR="$_a"
}

# pre_fix_guard_resolve_author — the ORIGINAL flow: always re-derives from
# the bead's CURRENT state, never consults a frozen marker value (because
# nothing ever wrote one).
pre_fix_guard_resolve_author() {
  local _a="${MOCK_BEAD_ASSIGNEE:-}"
  if [ -z "$_a" ] || [ "$_a" = "null" ]; then _a="${MOCK_BEAD_CREATED_BY:-}"; fi
  if [ -z "$_a" ] || [ "$_a" = "null" ]; then _a="${MOCK_BEAD_OWNER:-}"; fi
  RESOLVED_AUTHOR="$_a"
}

echo "gate-submitted-by-author-freeze.selftest.sh (ga-b3gso9)"
echo "  gate-done source: $GATE_DONE"
echo "  guard source:      $GUARD_SH"
echo

# ── (A) assignee resolves -> used ──────────────────────────────────────────
FROZEN_GATE_SUBMITTED_BY=""; FREEZE_WRITE_CALLS=0
MOCK_BEAD_ASSIGNEE="wa-worker-ga43ei3l"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
gate_done_freeze_author
[ "$FROZEN_GATE_SUBMITTED_BY" = "wa-worker-ga43ei3l" ] && [ "$FREEZE_WRITE_CALLS" -eq 1 ] \
  && ok "(A) assignee resolves -> gate.submitted_by frozen to the assignee" \
  || bad "(A) expected frozen=wa-worker-ga43ei3l calls=1, got frozen='$FROZEN_GATE_SUBMITTED_BY' calls=$FREEZE_WRITE_CALLS"

# ── (B) assignee empty, created_by resolves -> used ────────────────────────
FROZEN_GATE_SUBMITTED_BY=""; FREEZE_WRITE_CALLS=0
MOCK_BEAD_ASSIGNEE=""; MOCK_BEAD_CREATED_BY="mila"; MOCK_BEAD_OWNER=""
gate_done_freeze_author
[ "$FROZEN_GATE_SUBMITTED_BY" = "mila" ] \
  && ok "(B) assignee empty, created_by resolves -> gate.submitted_by frozen to created_by" \
  || bad "(B) expected frozen=mila, got '$FROZEN_GATE_SUBMITTED_BY'"

# ── (C) assignee+created_by empty, owner resolves -> used ──────────────────
FROZEN_GATE_SUBMITTED_BY=""; FREEZE_WRITE_CALLS=0
MOCK_BEAD_ASSIGNEE="null"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER="athosmartins@gmail.com"
gate_done_freeze_author
[ "$FROZEN_GATE_SUBMITTED_BY" = "athosmartins@gmail.com" ] \
  && ok "(C) assignee+created_by empty, owner resolves -> gate.submitted_by frozen to owner" \
  || bad "(C) expected frozen=athosmartins@gmail.com, got '$FROZEN_GATE_SUBMITTED_BY'"

# ── (D) all three empty -> NOT set (third state, AC #5) ────────────────────
FROZEN_GATE_SUBMITTED_BY=""; FREEZE_WRITE_CALLS=0
MOCK_BEAD_ASSIGNEE=""; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
gate_done_freeze_author
[ -z "$FROZEN_GATE_SUBMITTED_BY" ] && [ "$FREEZE_WRITE_CALLS" -eq 0 ] \
  && ok "(D) assignee/created_by/owner all empty -> gate.submitted_by left UNSET, no invented value" \
  || bad "(D) expected no write when authorship is unresolvable, got frozen='$FROZEN_GATE_SUBMITTED_BY' calls=$FREEZE_WRITE_CALLS"

# ── (E) mutation guard: pre-fix gate-done never freezes anything ──────────
FROZEN_GATE_SUBMITTED_BY=""; FREEZE_WRITE_CALLS=0
MOCK_BEAD_ASSIGNEE="wa-worker-ga43ei3l"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
pre_fix_gate_done
[ -z "$FROZEN_GATE_SUBMITTED_BY" ] && [ "$FREEZE_WRITE_CALLS" -eq 0 ] \
  && ok "(E) mutation check: pre-fix gate-done never freezes gate.submitted_by, even with a clean assignee -- reproduces the gap this fix closes" \
  || bad "(E) mutation check: pre-fix replica unexpectedly froze a value -- (A) would not catch a reversion"

# ── (F) guard: frozen value present -> used, current bead state ignored ────
MOCK_MARKER_FROZEN="wa-worker-ga43ei3l"
MOCK_BEAD_ASSIGNEE="wa-worker-gaa1934f"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
guard_resolve_author
[ "$RESOLVED_AUTHOR" = "wa-worker-ga43ei3l" ] \
  && ok "(F) frozen gate.submitted_by present -> guard trusts it, ignores the bead's current (hijacked) assignee" \
  || bad "(F) expected AUTHOR=wa-worker-ga43ei3l (frozen), got '$RESOLVED_AUTHOR' -- current-state re-derivation leaked through"

# ── (G) guard: no frozen value (legacy marker) -> falls through unchanged ──
MOCK_MARKER_FROZEN=""
MOCK_BEAD_ASSIGNEE="digo-wa"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
guard_resolve_author
[ "$RESOLVED_AUTHOR" = "digo-wa" ] \
  && ok "(G) no frozen value on a legacy marker -> guard falls through to bead-derivation exactly as before (no regression)" \
  || bad "(G) expected AUTHOR=digo-wa (bead-derived fallback), got '$RESOLVED_AUTHOR'"

# ── (H) mutation guard: pre-fix guard always re-derives, ignores frozen ────
MOCK_MARKER_FROZEN="wa-worker-ga43ei3l"
MOCK_BEAD_ASSIGNEE="wa-worker-gaa1934f"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
pre_fix_guard_resolve_author
[ "$RESOLVED_AUTHOR" = "wa-worker-gaa1934f" ] \
  && ok "(H) mutation check: pre-fix guard ignores any frozen value and always re-derives from current bead state -- reproduces the bug (F) fixes" \
  || bad "(H) mutation check: pre-fix replica unexpectedly preferred the frozen value -- (F) would not catch a reversion"

# ── (I) INTEGRATION: the exact AC #3 scenario, both pipelines ─────────────
# Session A submits: gate-done freezes gate.submitted_by=A using the bead's
# state AT THAT MOMENT (assignee=A, nobody else has touched it yet).
FROZEN_GATE_SUBMITTED_BY=""
MOCK_BEAD_ASSIGNEE="wa-worker-ga43ei3l"; MOCK_BEAD_CREATED_BY=""; MOCK_BEAD_OWNER=""
gate_done_freeze_author
_I_FROZEN_AT_SUBMIT="$FROZEN_GATE_SUBMITTED_BY"

# Session B claims the source bead while the marker sits unclaimed by the
# guard (gc.routed_to still live) -- the bead's CURRENT assignee is now B.
MOCK_BEAD_ASSIGNEE="wa-worker-gaa1934f"

# POST-FIX pipeline: guard consults the frozen value from submission time.
MOCK_MARKER_FROZEN="$_I_FROZEN_AT_SUBMIT"
guard_resolve_author
_I_POST_FIX_AUTHOR="$RESOLVED_AUTHOR"

# PRE-FIX pipeline: guard never had a frozen value to consult (gate-done
# never wrote one), so it always re-derives from whatever is current NOW.
MOCK_MARKER_FROZEN=""
pre_fix_guard_resolve_author
_I_PRE_FIX_AUTHOR="$RESOLVED_AUTHOR"

if [ "$_I_PRE_FIX_AUTHOR" = "wa-worker-gaa1934f" ] && [ "$_I_POST_FIX_AUTHOR" = "wa-worker-ga43ei3l" ]; then
  ok "(I) integration: today authorship becomes the LATER claimer B ('$_I_PRE_FIX_AUTHOR'); after the fix it stays the ORIGINAL submitter A ('$_I_POST_FIX_AUTHOR') -- AC #3 reproduced pre-fix, resolved post-fix"
else
  bad "(I) integration expected pre-fix=wa-worker-gaa1934f post-fix=wa-worker-ga43ei3l, got pre-fix='$_I_PRE_FIX_AUTHOR' post-fix='$_I_POST_FIX_AUTHOR'"
fi

# ── (J)/(K)/(L) source drift-guards against the deployed files ────────────
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  step3_src=$(printf '%s\n' "$src" | awk '/^## Step 3:/{flag=1} flag; /^## Step 4:/{flag=0}')

  # ga-b3gso9-selftest: here-string, NOT `printf ... | grep -q` — under
  # `pipefail`, grep -q can exit as soon as it finds a match, SIGPIPE-killing
  # a still-writing upstream printf on a large string; pipefail then reports
  # the pipeline as failed even though grep DID match (reproduced live,
  # empirically, while writing this file — the exact
  # exit-code-after-a-pipe-measures-the-wrong-command class). A here-string
  # has no live pipe to close early, so this can't happen.
  grep -qF 'bd -C "$GC_CITY_PATH" update "$MARKER_ID" --set-metadata "gate.submitted_by=$_SUBMIT_AUTHOR"' <<< "$step3_src" \
    && ok "(J1) gate-done.md Step 3 freezes gate.submitted_by via --set-metadata" \
    || bad "(J1) gate-done.md Step 3 missing the gate.submitted_by freeze write (ga-b3gso9 regression)"

  gate_queued_line=$(printf '%s\n' "$step3_src" | grep -nF 'label add "$BEAD_ID" "gate:queued"' | head -1 | cut -d: -f1)
  freeze_line=$(printf '%s\n' "$step3_src" | grep -nF '_SUBMIT_BEAD_JSON=$(bd -C "$_BEAD_STORE"' | head -1 | cut -d: -f1)
  if [ -n "$gate_queued_line" ] && [ -n "$freeze_line" ] && [ "$gate_queued_line" -lt "$freeze_line" ]; then
    ok "(J2) freeze block runs AFTER the gate:queued stamp (lines $gate_queued_line < $freeze_line), reusing \$_BEAD_STORE"
  else
    bad "(J2) freeze block out of order or missing (gate_queued=$gate_queued_line freeze=$freeze_line)"
  fi

  grep -qF 'if [ -n "$_SUBMIT_AUTHOR" ] && [ "$_SUBMIT_AUTHOR" != "null" ]; then' <<< "$step3_src" \
    && ok "(J3) gate-done.md guards the write behind a non-empty check -- never writes an invented/blank author" \
    || bad "(J3) gate-done.md missing the third-state guard around the freeze write"
else
  bad "(J) gate-done.md not found at $GATE_DONE"
fi

if [ -f "$GUARD_SH" ]; then
  gsrc=$(cat "$GUARD_SH")

  grep -qF 'MARKER_AUTHOR_FROZEN=$(printf' <<< "$gsrc" \
    && ok "(K1) quality-gate-guard.sh Step 5 reads a frozen gate.submitted_by off the marker" \
    || bad "(K1) quality-gate-guard.sh missing the frozen-author read (ga-b3gso9 regression)"

  frozen_check_line=$(printf '%s\n' "$gsrc" | grep -nF 'if [ -n "$MARKER_AUTHOR_FROZEN" ]' | head -1 | cut -d: -f1)
  derive_line=$(printf '%s\n' "$gsrc" | grep -nF 'AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")' | head -1 | cut -d: -f1)
  if [ -n "$frozen_check_line" ] && [ -n "$derive_line" ] && [ "$frozen_check_line" -lt "$derive_line" ]; then
    ok "(K2) frozen-value check runs BEFORE the bead_field_grep current-state derivation (lines $frozen_check_line < $derive_line)"
  else
    bad "(K2) frozen-value check missing or ordered after the current-state derivation (frozen_check=$frozen_check_line derive=$derive_line)"
  fi

  grep -qF 'skipping bead re-derivation' <<< "$gsrc" \
    && ok "(K3) guard logs that it trusted the frozen value and skipped re-derivation (visible, not silent)" \
    || bad "(K3) guard missing a visible log line for the frozen-value path"
else
  bad "(K) quality-gate-guard.sh not found at $GUARD_SH"
fi

# ── (L) the go:embed twin must stay byte-identical to canonical ───────────
TOWN_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
CANONICAL="$TOWN_ROOT/.gascity-gastown-hq/commands/gate-done.md"
EMBEDDED="$TOWN_ROOT/internal/templates/commands/bodies/gate-done.md"
if [ -f "$CANONICAL" ] && [ -f "$EMBEDDED" ]; then
  if cmp -s "$CANONICAL" "$EMBEDDED"; then
    ok "(L) canonical commands/gate-done.md and the go:embed twin are byte-identical"
  else
    bad "(L) canonical and go:embed twin have DRIFTED -- re-copy canonical's content"
  fi
else
  bad "(L) could not locate both canonical ($CANONICAL) and embedded ($EMBEDDED) copies"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"

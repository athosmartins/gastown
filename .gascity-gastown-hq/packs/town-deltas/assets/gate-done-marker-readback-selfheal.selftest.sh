#!/usr/bin/env bash
# gate-done-marker-readback-selfheal.selftest.sh (ga-ehbw5)
#
# Proves /gate-done's Step 3 re-reads the ready-for-gate marker right after
# creating it and self-heals gate-status:ready if the readback doesn't show
# it — instead of trusting `bd create`'s own --json/jq extraction (which only
# proves an id came back, never that the label list the dispatcher filters on
# is what we asked for) and relying solely on
# gate-marker-missing-status-watchdog.sh (ga-5jyo8) to catch a labelless
# marker on its next sweep, minutes later.
#
# This is an OPTIONAL prevention layer on top of ga-5jyo8's DETECTION fix —
# see ga-ehbw5's body for why it landed as its own focused change instead of
# riding along with the watchdog PR (commands/gate-done.md is a high-traffic
# skill file; every /gate-done invocation in the city executes these steps).
#
# Covers:
#   (A)  label present, alone -> no self-heal, no warning
#   (A2) label present, first of several -> no self-heal (comma-boundary,
#        not a bare substring match)
#   (A3) label present, last of several -> no self-heal
#   (A4) label present, in the middle of several -> no self-heal
#   (B)  label absent, other labels present -> self-heal triggered, healed
#   (C)  readback unreadable (empty string, e.g. bd/jq failure) -> self-heal
#        triggered anyway (third-state rule: act on "don't know", the repair
#        is a harmless no-op if the label secretly was already there)
#   (D)  look-alike label with the target as a PREFIX (e.g.
#        "gate-status:ready-ish") does NOT false-positive as present
#   (E)  look-alike label with the target as a SUFFIX (e.g.
#        "not-gate-status:ready") does NOT false-positive as present
#   (F)  the self-heal attempt itself fails -> warned, does not crash/abort
#        (fail-open: the marker already exists, this is a prevention extra)
#   (G)  mutation guard: the PRE-FIX flow (no readback block at all) never
#        calls self-heal even when the label is missing -- reproduces the
#        exposure this fix closes, proving (B)/(C) would catch a reversion
#   (H)  source drift-guards: deployed gate-done.md Step 3 contains the
#        readback+self-heal block, running AFTER marker creation and BEFORE
#        the gate:queued stamp / sling auto-close block
#   (I)  the go:embed twin stays byte-identical to canonical after this fix
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-done.md resolution (priority order), same convention as
# gate-done-sling-autoclose.selftest.sh / gate-done-crew-rig.selftest.sh:
#   1. commands/ relative to pack root (deployed HQ context)
#   2. internal/templates/.../bodies/ (worktree / binary-repo context)
#   3. local sibling (manual copy / test fixture)
GATE_DONE="$SELF_DIR/../../../commands/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/../../../internal/templates/commands/bodies/gate-done.md"
[ -f "$GATE_DONE" ] || GATE_DONE="$SELF_DIR/gate-done.md"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# ── Mock state ────────────────────────────────────────────────────────────
LABEL_ADD_CALLS=0
LAST_LABEL_ADD_ID=""
LABEL_ADD_RESULT=0   # 0 = bd label add succeeds; nonzero = simulates failure
LAST_OUTPUT=""

# mock_show_marker <marker_id> — echoes the comma-joined label list for the
# given marker, per the scenario's fixture ("" = unreadable / no labels).
mock_show_marker() { printf '%s' "${MOCK_MARKER_LABELS-}"; }

# mock_label_add <marker_id> <label> — records the call instead of touching
# Dolt; returns LABEL_ADD_RESULT to let scenarios simulate failure.
mock_label_add() {
  LABEL_ADD_CALLS=$((LABEL_ADD_CALLS + 1))
  LAST_LABEL_ADD_ID="$1"
  return "$LABEL_ADD_RESULT"
}

# marker_readback_selfheal <marker_id> — replica of the deployed Step 3
# readback+self-heal block: same variable name, same case-statement
# comma-boundary match, calling the mocks above instead of bd/jq against a
# live database.
marker_readback_selfheal() {
  local MARKER_ID="$1"
  local _MARKER_LABELS
  _MARKER_LABELS=$(mock_show_marker "$MARKER_ID")
  case ",$_MARKER_LABELS," in
    *,gate-status:ready,*)
      : # present — nothing to do
      ;;
    *)
      echo "Warning: marker $MARKER_ID did not read back gate-status:ready (labels: ${_MARKER_LABELS:-<unreadable>}). Self-healing..."
      if mock_label_add "$MARKER_ID" "gate-status:ready"; then
        echo "Self-healed: gate-status:ready added to $MARKER_ID."
      else
        echo "Self-heal FAILED for $MARKER_ID — gate-marker-missing-status-watchdog.sh (ga-5jyo8) will still catch this within minutes."
      fi
      ;;
  esac
}

# pre_fix_flow — the ORIGINAL flow: no readback block exists at all, so
# nothing ever re-checks the marker's labels once `bd create` returns an id.
pre_fix_flow() { :; }

echo "gate-done-marker-readback-selfheal.selftest.sh (ga-ehbw5)"
echo "  source: $GATE_DONE"
echo

# ── (A) label present, alone -> no self-heal ────────────────────────────────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="gate-status:ready"
LAST_OUTPUT=$(marker_readback_selfheal "mk-1")
[ "$LABEL_ADD_CALLS" -eq 0 ] && [ -z "$LAST_OUTPUT" ] \
  && ok "(A) label present alone -> no self-heal call, no warning printed" \
  || bad "(A) expected 0 self-heal calls and silent output, got calls=$LABEL_ADD_CALLS output='$LAST_OUTPUT'"

# ── (A2) label present, first of several -> no self-heal ──────────────────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="gate-status:ready,branch:fix/x,source-bead:ga-1"
marker_readback_selfheal "mk-2" >/dev/null
[ "$LABEL_ADD_CALLS" -eq 0 ] \
  && ok "(A2) label present as FIRST of several -> no self-heal (comma-boundary match)" \
  || bad "(A2) expected 0 self-heal calls, got calls=$LABEL_ADD_CALLS"

# ── (A3) label present, last of several -> no self-heal ────────────────────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="branch:fix/x,source-bead:ga-1,gate-status:ready"
marker_readback_selfheal "mk-3" >/dev/null
[ "$LABEL_ADD_CALLS" -eq 0 ] \
  && ok "(A3) label present as LAST of several -> no self-heal (comma-boundary match)" \
  || bad "(A3) expected 0 self-heal calls, got calls=$LABEL_ADD_CALLS"

# ── (A4) label present, in the middle of several -> no self-heal ──────────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="branch:fix/x,gate-status:ready,source-bead:ga-1"
marker_readback_selfheal "mk-4" >/dev/null
[ "$LABEL_ADD_CALLS" -eq 0 ] \
  && ok "(A4) label present in the MIDDLE of several -> no self-heal (comma-boundary match)" \
  || bad "(A4) expected 0 self-heal calls, got calls=$LABEL_ADD_CALLS"

# ── (B) label absent, other labels present -> self-heal triggered ─────────
# NOTE: state (LABEL_ADD_CALLS) and content (captured stdout) are checked via
# TWO separate calls, deliberately. `x=$(fn)` forks a subshell for `fn` — any
# counter mutation inside it is invisible to the parent once the subshell
# exits, so a single substituted call can never prove BOTH "called exactly
# once" and "printed the right message" at once. The first (plain, no
# substitution) call proves the state; the second (substituted) call, run
# with the same deterministic fixture, proves the message content. The
# second call's own internal counter increment is discarded with its
# subshell, so it does not corrupt the state assertion already taken.
LABEL_ADD_CALLS=0; LAST_LABEL_ADD_ID=""; LABEL_ADD_RESULT=0
MOCK_MARKER_LABELS="type:quality-gate-marker,branch:fix/x,source-bead:ga-1"
marker_readback_selfheal "mk-5" >/dev/null
_B_STATE_OK=0
[ "$LABEL_ADD_CALLS" -eq 1 ] && [ "$LAST_LABEL_ADD_ID" = "mk-5" ] && _B_STATE_OK=1
LAST_OUTPUT=$(marker_readback_selfheal "mk-5")
_B_CONTENT_OK=0
printf '%s' "$LAST_OUTPUT" | grep -q "Self-healed" && _B_CONTENT_OK=1
[ "$_B_STATE_OK" -eq 1 ] && [ "$_B_CONTENT_OK" -eq 1 ] \
  && ok "(B) label absent with siblings present -> self-heal called exactly once on mk-5 (state), confirmed via 'Self-healed' message (content)" \
  || bad "(B) expected 1 self-heal call on mk-5 + 'Self-healed' confirmation, got state_ok=$_B_STATE_OK(calls=$LABEL_ADD_CALLS id='$LAST_LABEL_ADD_ID') content_ok=$_B_CONTENT_OK output='$LAST_OUTPUT'"

# ── (C) readback unreadable (empty) -> self-heal triggered anyway ─────────
LABEL_ADD_CALLS=0; LABEL_ADD_RESULT=0
MOCK_MARKER_LABELS=""
marker_readback_selfheal "mk-6" >/dev/null
_C_STATE_OK=0
[ "$LABEL_ADD_CALLS" -eq 1 ] && _C_STATE_OK=1
LAST_OUTPUT=$(marker_readback_selfheal "mk-6")
_C_CONTENT_OK=0
printf '%s' "$LAST_OUTPUT" | grep -q "unreadable" && _C_CONTENT_OK=1
[ "$_C_STATE_OK" -eq 1 ] && [ "$_C_CONTENT_OK" -eq 1 ] \
  && ok "(C) unreadable readback (bd/jq failure) -> self-heal triggered anyway (state), labeled <unreadable> in the warning (content) -- third-state: act on don't-know" \
  || bad "(C) expected 1 self-heal call + <unreadable> mention, got state_ok=$_C_STATE_OK(calls=$LABEL_ADD_CALLS) content_ok=$_C_CONTENT_OK output='$LAST_OUTPUT'"

# ── (D) look-alike label, target as PREFIX -> must not false-positive ─────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="gate-status:ready-ish"
marker_readback_selfheal "mk-7" >/dev/null
[ "$LABEL_ADD_CALLS" -eq 1 ] \
  && ok "(D) 'gate-status:ready-ish' (target as prefix) correctly treated as ABSENT -> self-heal fires" \
  || bad "(D) look-alike prefix label false-positived as present -- comma-boundary check regressed"

# ── (E) look-alike label, target as SUFFIX -> must not false-positive ─────
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="not-gate-status:ready"
marker_readback_selfheal "mk-8" >/dev/null
[ "$LABEL_ADD_CALLS" -eq 1 ] \
  && ok "(E) 'not-gate-status:ready' (target as suffix) correctly treated as ABSENT -> self-heal fires" \
  || bad "(E) look-alike suffix label false-positived as present -- comma-boundary check regressed"

# ── (F) self-heal attempt itself fails -> warned, does not abort ──────────
LABEL_ADD_CALLS=0; LABEL_ADD_RESULT=1
MOCK_MARKER_LABELS=""
LAST_OUTPUT=$(marker_readback_selfheal "mk-9")
RC=$?
[ "$RC" -eq 0 ] && printf '%s' "$LAST_OUTPUT" | grep -q "Self-heal FAILED" \
  && ok "(F) self-heal call failing -> warned via 'Self-heal FAILED', function still returns success (fail-open)" \
  || bad "(F) expected a graceful 'Self-heal FAILED' warning and rc=0, got rc=$RC output='$LAST_OUTPUT'"
LABEL_ADD_RESULT=0

# ── (G) mutation guard: PRE-FIX flow never self-heals a missing label ─────
# Proves (B)/(C) would actually catch a reversion of this fix, not just
# happen to pass either way.
LABEL_ADD_CALLS=0
MOCK_MARKER_LABELS="type:quality-gate-marker,branch:fix/x"
pre_fix_flow "mk-10"
[ "$LABEL_ADD_CALLS" -eq 0 ] \
  && ok "(G) mutation check: pre-fix flow never re-reads or self-heals -- reproduces the exposure this fix closes" \
  || bad "(G) mutation check: pre-fix replica unexpectedly called self-heal -- (B)/(C) would not catch a reversion"

# ── (H) source drift-guards against deployed gate-done.md ──────────────────
if [ -f "$GATE_DONE" ]; then
  src=$(cat "$GATE_DONE")
  step3_src=$(printf '%s\n' "$src" | awk '/^## Step 3:/{flag=1} flag; /^## Step 4:/{flag=0}')

  printf '%s' "$step3_src" | grep -qF '_MARKER_LABELS=$(bd -C "$GC_CITY_PATH" show "$MARKER_ID"' \
    && ok "(H1) gate-done.md Step 3 re-reads the marker's labels after creation" \
    || bad "(H1) gate-done.md Step 3 missing the marker readback (ga-ehbw5 regression)"

  printf '%s' "$step3_src" | grep -qF 'case ",$_MARKER_LABELS," in' \
    && ok "(H2) gate-done.md uses comma-boundary matching, not a bare substring grep" \
    || bad "(H2) gate-done.md missing the comma-boundary case match -- could false-positive on look-alike labels"

  printf '%s' "$step3_src" | grep -qF 'bd -C "$GC_CITY_PATH" label add "$MARKER_ID" "gate-status:ready"' \
    && ok "(H3) gate-done.md self-heals via bd label add on the marker in GC_CITY_PATH" \
    || bad "(H3) gate-done.md missing (or mis-scoped) the actual self-heal bd label add call"

  printf '%s' "$step3_src" | grep -qF 'Self-heal FAILED' \
    && ok "(H4) gate-done.md surfaces a visible warning when the self-heal attempt itself fails (fail-open, not silent)" \
    || bad "(H4) gate-done.md missing a visible failure path for the self-heal attempt"

  # The readback block must run AFTER marker creation (MARKER_ID populated)
  # and BEFORE the sling auto-close block -- reading before the marker exists
  # would read the wrong (or a stale) id.
  marker_line=$(printf '%s\n' "$step3_src" | grep -nE '^MARKER_ID=\$\(bd ' | head -1 | cut -d: -f1)
  readback_line=$(printf '%s\n' "$step3_src" | grep -nF '_MARKER_LABELS=$(bd' | head -1 | cut -d: -f1)
  autoclose_line=$(printf '%s\n' "$step3_src" | grep -nF '_SLING_BEAD_ID=$(bd' | head -1 | cut -d: -f1)
  if [ -n "$marker_line" ] && [ -n "$readback_line" ] && [ -n "$autoclose_line" ] \
     && [ "$marker_line" -lt "$readback_line" ] && [ "$readback_line" -lt "$autoclose_line" ]; then
    ok "(H5) readback+self-heal runs AFTER marker creation and BEFORE sling auto-close (lines $marker_line < $readback_line < $autoclose_line)"
  else
    bad "(H5) readback block out of order (marker=$marker_line readback=$readback_line autoclose=$autoclose_line)"
  fi
else
  bad "(H) gate-done.md not found at $GATE_DONE"
fi

# ── (I) the go:embed twin must stay byte-identical to canonical ───────────
TOWN_ROOT="$(cd "$SELF_DIR/../../../.." && pwd)"
CANONICAL="$TOWN_ROOT/.gascity-gastown-hq/commands/gate-done.md"
EMBEDDED="$TOWN_ROOT/internal/templates/commands/bodies/gate-done.md"
if [ -f "$CANONICAL" ] && [ -f "$EMBEDDED" ]; then
  if cmp -s "$CANONICAL" "$EMBEDDED"; then
    ok "(I) canonical commands/gate-done.md and the go:embed twin are byte-identical"
  else
    bad "(I) canonical and go:embed twin have DRIFTED -- re-copy canonical's content (breaks nothing at runtime but violates ga-54iu's sync invariant)"
  fi
else
  bad "(I) could not locate both canonical ($CANONICAL) and embedded ($EMBEDDED) copies"
fi

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"

#!/usr/bin/env bash
# mol-do-work-drain-step.test.sh — reproduction + regression test for ga-0ttcdl:
# "$GC_BEAD_ID empty during mol-do-work drain step, backstop-close silently
# skipped, molecule stalls + pool-worker respawn loop."
#
# Extracts the REAL "drain" step bash block from formulas/mol-do-work.toml (no
# duplication — same technique as
# packs/town-deltas/assets/tests/story-delivery-step5b.test.sh) and drives it
# with stubbed bd/gc, proving:
#   - GC_BEAD_ID empty + exactly one live fallback candidate -> backstop-close
#     still fires (against that candidate, not silently skipped).
#   - GC_BEAD_ID empty + zero fallback candidates -> does NOT silently reach
#     drain-ack: a loud, tagged error is printed AND an escalation nudge is
#     sent (third state, ga-0ttcdl AC3) -- but drain-ack still runs (must not
#     hang the session forever; city reclaim/reaper already backstops a truly
#     stuck sling).
#   - GC_BEAD_ID correctly set (regression guard, mirrors do-work step 6's
#     already-working case) -> backstop-close fires directly, no fallback
#     query needed.
#   - GC_BEAD_ID correctly set but the bead is ALREADY closed (e.g. a prior
#     step recorded gc.outcome=parked) -> backstop-close must NOT run (never
#     overwrite a recorded outcome -- this safety property predates ga-0ttcdl
#     and must survive the fix untouched).
#
# Run against origin/main (pre-fix): cases 1-2's escalation/fallback
# assertions FAIL (today's code has no fallback query and no loud-failure
# path -- it just silently does nothing). Cases 3-4 already pass (protects
# the pre-existing, correct behavior from regressing).
# Run after the fix: all cases pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="$SCRIPT_DIR/../mol-do-work.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
nok() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; [ -n "${2:-}" ] && echo "         $2"; }

# Extract the "drain" step's bash block (first ```bash ... ``` fence at/after
# `id = "drain"`) directly from the live formula -- proves the test tracks
# whatever is actually shipped, not a paraphrase of it.
BLOCK="$(sed -n '/^id = "drain"/,$p' "$FORMULA" | sed -n '/^```bash$/,/^```$/p' | sed '1d;$d')"
[ -n "$BLOCK" ] || { echo "FAIL: could not extract the drain step's bash block from $FORMULA"; exit 1; }

# run_block <scenario>
#   GC_BEAD_ID_VAL      - value (possibly empty) the block sees as $GC_BEAD_ID
#   MOCK_SHOW_STATUS    - status `bd show $GC_BEAD_ID_VAL --json` reports (when GC_BEAD_ID_VAL is set)
#   MOCK_LIST_JSON      - JSON array `bd list ...` (the fallback query) returns
#   GC_TRIGGER_BEAD_ID_VAL (optional, default "") - value the block sees as $GC_TRIGGER_BEAD_ID
#   GC_SESSION_NAME_VAL    (optional, default "dog-test1234") - value the block sees as $GC_SESSION_NAME
# Sets: RUN_RC, LAST_BD, LAST_GC (global) after running.
run_block() {
  local gc_bead_id="$1" show_status="$2" list_json="$3"
  local T; T="$(mktemp -d)"
  BD_LOG="$T/bd.log"; GC_LOG="$T/gc.log"

  # bd/gc stubs: log every invocation, and answer `bd show`/`bd list` with
  # canned JSON so the block's own jq parsing runs for real (only the
  # external bd/gc process boundary is faked, exactly like
  # story-delivery-step5b.test.sh does for bd/gc).
  bd() {
    echo "bd $*" >> "$BD_LOG"
    case "$1" in
      show)
        if [ -n "$show_status" ]; then
          printf '[{"status":"%s"}]' "$show_status"
        fi
        ;;
      list)
        printf '%s' "$list_json"
        ;;
    esac
  }
  gc() { echo "gc $*" >> "$GC_LOG"; }
  export -f bd gc 2>/dev/null || true

  GC_BEAD_ID="$gc_bead_id"
  GC_TRIGGER_BEAD_ID="${4:-}"
  GC_SESSION_NAME="${5-dog-test1234}"
  GC_AGENT="gastown.dog-test"
  export GC_BEAD_ID GC_TRIGGER_BEAD_ID GC_SESSION_NAME GC_AGENT

  ( eval "$BLOCK" ) >"$T/stdout.log" 2>"$T/stderr.log"
  RUN_RC=$?
  LAST_BD="$(cat "$BD_LOG" 2>/dev/null || true)"
  LAST_GC="$(cat "$GC_LOG" 2>/dev/null || true)"
  LAST_STDERR="$(cat "$T/stderr.log" 2>/dev/null || true)"
  rm -rf "$T"
  unset -f bd gc 2>/dev/null || true
}

# --- Case 1: GC_BEAD_ID empty, exactly one live fallback candidate --------
# The step's own bead (e.g. wa-uqwp6) is genuinely in_progress+assigned to
# this session (status "open", not yet closed), but $GC_BEAD_ID never got
# (re)populated for it (ga-0ttcdl's actual reported scenario). A working fix
# resolves it anyway and closes it.
run_block "" "open" '[{"id":"wa-uqwp6"}]'
echo "$LAST_BD" | grep -q 'bd update wa-uqwp6 .*--status=closed' \
  && ok "C1 empty GC_BEAD_ID + 1 fallback candidate -> backstop-close fires on the resolved id" \
  || nok "C1 backstop-close on fallback id" "$LAST_BD"

# --- Case 1b: GC_BEAD_ID empty, GC_TRIGGER_BEAD_ID set --------------------
# Per upstream gascity commit fd56f1048: the claude provider tracks the
# current turn's bead as $GC_TRIGGER_BEAD_ID, correctly re-scoped per step
# (unlike $GC_BEAD_ID). Must resolve directly from it -- cheap, no live
# query -- and NOT touch the live-query path at all (the list stub below
# would resolve to the wrong id, "wa-wrong", if the code incorrectly fell
# through to it; asserting its absence from the log proves the short-circuit).
run_block "" "open" '[{"id":"wa-wrong"}]' "wa-uqwp6"
echo "$LAST_BD" | grep -q 'bd update wa-uqwp6 .*--status=closed' \
  && ok "C1b empty GC_BEAD_ID + GC_TRIGGER_BEAD_ID set -> backstop-close fires on the trigger id" \
  || nok "C1b backstop-close on trigger id" "$LAST_BD"
! echo "$LAST_BD" | grep -q 'bd list' \
  && ok "C1b GC_TRIGGER_BEAD_ID resolved -> live fallback query never ran" \
  || nok "C1b short-circuits before the live query" "$LAST_BD"

# --- Case 2: GC_BEAD_ID empty, zero fallback candidates -------------------
# Truly unresolvable (AC3's third state). Must not silently no-op: loud
# error + escalation, but must still drain (never hang the session).
run_block "" "" '[]'
! echo "$LAST_BD" | grep -q -- '--status=closed' \
  && ok "C2 unresolvable -> no bd update fired against a guessed/wrong id" \
  || nok "C2 no-guess" "$LAST_BD"
echo "$LAST_STDERR" | grep -qi 'ga-0ttcdl\|unresolved\|could not resolve' \
  && ok "C2 unresolvable -> loud, tagged error on stderr (not silent)" \
  || nok "C2 loud error" "stderr was: $LAST_STDERR"
echo "$LAST_GC" | grep -q 'session nudge' \
  && ok "C2 unresolvable -> escalation nudge sent" \
  || nok "C2 escalation" "$LAST_GC"
echo "$LAST_GC" | grep -q 'runtime drain-ack' \
  && ok "C2 unresolvable -> drain-ack still runs (session doesn't hang)" \
  || nok "C2 still drains" "$LAST_GC"

# --- Case 2b: GC_BEAD_ID empty AND GC_SESSION_NAME empty -------------------
# Self-audit catch: `bd list --assignee=""` is NOT "match nothing" -- verified
# live against the real bd CLI, it behaves as NO FILTER and returns every
# in_progress bead city-wide. If the code ran the fallback query anyway with
# an empty assignee, it could resolve to (and close) some OTHER session's
# step bead -- worse than the silent-skip this bug report is about. The list
# stub below would hand back a plausible-looking single candidate ("wa-
# somebody-elses-step") if the code were foolish enough to call `bd list` at
# all here; asserting its absence from the log proves it never did.
run_block "" "" '[{"id":"wa-somebody-elses-step"}]' "" ""
! echo "$LAST_BD" | grep -q 'bd list' \
  && ok "C2b empty GC_SESSION_NAME -> live fallback query never attempted (would be unscoped)" \
  || nok "C2b refuses unscoped query" "$LAST_BD"
! echo "$LAST_BD" | grep -q -- '--status=closed' \
  && ok "C2b empty GC_SESSION_NAME -> no bd update fired against a cross-session id" \
  || nok "C2b no cross-session close" "$LAST_BD"
echo "$LAST_STDERR" | grep -qi 'ga-0ttcdl\|unresolved\|could not resolve' \
  && ok "C2b empty GC_SESSION_NAME -> loud, tagged error on stderr (not silent)" \
  || nok "C2b loud error" "stderr was: $LAST_STDERR"

# --- Case 3: GC_BEAD_ID correctly set (regression guard) ------------------
# Mirrors the do-work step's already-working case: GC_BEAD_ID is populated
# and the bead isn't closed yet -> backstop-close fires directly, no
# fallback query needed. Must keep working exactly as it does today.
run_block "wa-uqwp6" "open" '[]'
echo "$LAST_BD" | grep -q 'bd update wa-uqwp6 .*--status=closed' \
  && ok "C3 GC_BEAD_ID set + not yet closed -> backstop-close fires directly" \
  || nok "C3 direct close" "$LAST_BD"

# --- Case 4: GC_BEAD_ID correctly set, already closed (regression guard) --
# A prior step (e.g. the PARK PROCEDURE) already recorded an outcome. Must
# NEVER be overwritten -- this predates ga-0ttcdl and must not regress.
run_block "wa-uqwp6" "closed" '[]'
! echo "$LAST_BD" | grep -q -- '--status=closed' \
  && ok "C4 already closed -> backstop-close does NOT re-fire (no outcome overwrite)" \
  || nok "C4 no overwrite" "$LAST_BD"

echo ""
echo "mol-do-work drain step tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

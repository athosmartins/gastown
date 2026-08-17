#!/usr/bin/env bash
# mol-do-work-drain-status-guard.selftest.sh (ga-rswuxy)
#
# Proves mol-do-work.toml's "drain" step backstop-close never overwrites an
# already-recorded sling outcome when it cannot positively confirm the
# sling's current status.
#
# Found during the Pre-flight Self-Audit on ga-rswuxy fix-attempt 2 (not
# cited by the gate reviewer, who scoped their attempt-1 review to the PARK
# PROCEDURE block and only verified this drain-step guard checks the
# CORRECT bead — not what it does when that check itself fails). Same
# defect class as fix-attempt 1's blocking issue: a read that might fail
# collapsed into the same value as a definite "not closed" read.
#
# The bug: `SLING_STATUS=$(bd show ... | jq -r '.[0].status // ""')` defaults
# to empty string on ANY failure — bd show erroring, returning an empty
# array, or emitting malformed JSON all produce the exact same empty
# SLING_STATUS as a bead that genuinely has no status field. The old code
# then treated empty-because-unknown identically to a confirmed "not
# closed": `[ "$SLING_STATUS" != "closed" ]` is true either way, so the
# backstop fires unconditionally. If a prior step (PARK PROCEDURE, or the
# build path's own step 6) already closed the sling with
# gc.outcome=parked, a transient read failure here would silently
# overwrite it with gc.outcome=pass and a false "Gate marker submitted"
# note — corrupting the one record that distinguishes "this bead was
# parked, no gate marker exists" from "this bead was built and gated".
#
# This test extracts the REAL drain-step block from the deployed formula
# (between the "drain" step's bash fence) and executes it with a mocked
# `bd` that can be told to fail, or to return a specific status, so the
# assertions cannot silently drift from the deployed behavior.
#
# Covers:
#   (C1) bd show confirms status=closed -> backstop does NOT fire
#   (C2) bd show confirms status=open -> backstop DOES fire, correct args
#   (C3) bd show confirms status=in_progress -> backstop DOES fire (any
#        confirmed non-closed status counts, not just literally "open")
#   (U1) bd show FAILS (nonzero exit) -> backstop does NOT fire, a warning
#        is printed, and drain-ack still runs
#   (U2) bd show succeeds but returns an EMPTY array -> same as U1 (a
#        genuinely absent record must not read as "confirmed open")
#   (U3) bd show succeeds but returns malformed JSON -> same as U1
#   (X)  GC_BEAD_ID unset -> no bd calls at all, drain-ack still runs
#   (F)  source drift-guard: the deployed block still distinguishes
#        confirmed-empty from confirmed-non-closed (not a single `!=
#        "closed"` check against a possibly-unknown value)
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FORMULA="$SELF_DIR/../../../formulas/mol-do-work.toml"
[ -f "$FORMULA" ] || FORMULA="$SELF_DIR/../../../.beads/formulas/mol-do-work.toml"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "mol-do-work-drain-status-guard.selftest.sh (ga-rswuxy)"
echo "  source: $FORMULA"
echo

if [ ! -f "$FORMULA" ]; then
  bad "formula file not found at $FORMULA"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi

# ── Extract the REAL drain-step bash block from the deployed formula ───────
# The drain step has no sentinel comments (unlike PARK PROCEDURE), so slice
# from the "drain" step's id down to the first fenced bash block's closing
# fence.
DRAIN_STEP_TO_EOF=$(awk '/^id = "drain"$/{f=1} f' "$FORMULA")
if [ -z "$DRAIN_STEP_TO_EOF" ]; then
  bad "(F0) drain step (id = \"drain\") not found in $FORMULA"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi
DRAIN_SRC=$(printf '%s\n' "$DRAIN_STEP_TO_EOF" | sed -n '/```bash/,/```/p' | sed '1d;$d')
if [ -z "$DRAIN_SRC" ]; then
  bad "(F0) could not extract drain step's bash block from $FORMULA"
  echo; echo "  PASS=$PASS  FAIL=$FAIL"; exit 1
fi
ok "(F0) drain step bash block found in deployed formula"

# run_drain <mode> <gc_bead_id> — evals the extracted block in a SUBSHELL
# with a mocked `bd show`/`bd update` and a mocked `gc`. Modes:
#   closed / open / in_progress   -> bd show succeeds, returns that status
#   fail                          -> bd show exits 1, prints nothing
#   empty                         -> bd show succeeds, returns "[]"
#   malformed                     -> bd show succeeds, returns invalid JSON
# Writes stdout+stderr to $3 so callers can grep for the update call and
# the warning; returns the block's own exit status.
run_drain() {
  local mode="$1" gc_bead_id="$2" outfile="$3"
  (
    bd() {
      if [ "$1" = "show" ]; then
        case "$MODE" in
          closed)      echo '[{"status":"closed"}]'; return 0 ;;
          open)        echo '[{"status":"open"}]'; return 0 ;;
          in_progress) echo '[{"status":"in_progress"}]'; return 0 ;;
          empty)       echo '[]'; return 0 ;;
          malformed)   echo 'not json'; return 0 ;;
          fail)        return 1 ;;
        esac
      elif [ "$1" = "update" ]; then
        echo "UPDATE_CALLED $*"
        return 0
      fi
    }
    gc() { echo "GC_CALLED $*"; }
    MODE="$mode" GC_BEAD_ID="$gc_bead_id"
    eval "$DRAIN_SRC"
  ) > "$outfile" 2>&1
  return $?
}

# ── (C1) confirmed closed -> no backstop ────────────────────────────────────
OUT="$(mktemp)"
run_drain closed "test-sling-1" "$OUT"
if ! grep -q "UPDATE_CALLED" "$OUT"; then ok "(C1) status=closed: backstop did NOT fire"
else bad "(C1) status=closed: backstop fired unexpectedly. Output:
$(cat "$OUT")"; fi
grep -q "GC_CALLED runtime drain-ack" "$OUT" \
  && ok "(C1.drain) drain-ack still ran" \
  || bad "(C1.drain) drain-ack did not run. Output:
$(cat "$OUT")"
rm -f "$OUT"

# ── (C2) confirmed open -> backstop fires with correct args ────────────────
OUT="$(mktemp)"
run_drain open "test-sling-1" "$OUT"
grep -q "UPDATE_CALLED update test-sling-1 --set-metadata gc.outcome=pass --status=closed" "$OUT" \
  && ok "(C2) status=open: backstop fired with correct bead id and outcome=pass" \
  || bad "(C2) status=open: backstop did not fire (or wrong args). Output:
$(cat "$OUT")"
rm -f "$OUT"

# ── (C3) confirmed in_progress -> backstop fires (not just literal "open") ──
OUT="$(mktemp)"
run_drain in_progress "test-sling-1" "$OUT"
grep -q "UPDATE_CALLED" "$OUT" \
  && ok "(C3) status=in_progress: backstop fired (any confirmed non-closed status)" \
  || bad "(C3) status=in_progress: backstop did not fire. Output:
$(cat "$OUT")"
rm -f "$OUT"

# ── (U1) bd show fails -> backstop must NOT fire, warning must print ───────
OUT="$(mktemp)"
run_drain fail "test-sling-1" "$OUT"
if ! grep -q "UPDATE_CALLED" "$OUT"; then ok "(U1) bd show fails: backstop did NOT fire (would have overwritten a possibly-parked outcome)"
else bad "(U1) bd show fails: backstop fired despite unknown status -- THE BUG. Output:
$(cat "$OUT")"; fi
grep -qi "warning" "$OUT" \
  && ok "(U1.warn) a warning was printed on unknown status" \
  || bad "(U1.warn) no warning printed when status could not be confirmed. Output:
$(cat "$OUT")"
grep -q "GC_CALLED runtime drain-ack" "$OUT" \
  && ok "(U1.drain) drain-ack still ran despite the unknown status" \
  || bad "(U1.drain) drain-ack did not run. Output:
$(cat "$OUT")"
rm -f "$OUT"

# ── (U2) bd show returns an empty array -> same as U1 ───────────────────────
OUT="$(mktemp)"
run_drain empty "test-sling-1" "$OUT"
if ! grep -q "UPDATE_CALLED" "$OUT"; then ok "(U2) bd show returns []: backstop did NOT fire"
else bad "(U2) bd show returns []: backstop fired despite an empty/absent record. Output:
$(cat "$OUT")"; fi
rm -f "$OUT"

# ── (U3) bd show returns malformed JSON -> same as U1 ───────────────────────
OUT="$(mktemp)"
run_drain malformed "test-sling-1" "$OUT"
if ! grep -q "UPDATE_CALLED" "$OUT"; then ok "(U3) bd show returns malformed JSON: backstop did NOT fire"
else bad "(U3) bd show returns malformed JSON: backstop fired. Output:
$(cat "$OUT")"; fi
rm -f "$OUT"

# ── (X) GC_BEAD_ID unset -> no bd calls, drain-ack still runs ──────────────
OUT="$(mktemp)"
run_drain closed "" "$OUT"
if ! grep -qE "UPDATE_CALLED|GC_CALLED show" "$OUT"; then ok "(X) GC_BEAD_ID unset: no backstop attempted"
else bad "(X) GC_BEAD_ID unset: unexpected bd activity. Output:
$(cat "$OUT")"; fi
grep -q "GC_CALLED runtime drain-ack" "$OUT" \
  && ok "(X.drain) drain-ack still ran with GC_BEAD_ID unset" \
  || bad "(X.drain) drain-ack did not run. Output:
$(cat "$OUT")"
rm -f "$OUT"

# ── (F) source drift-guard ───────────────────────────────────────────────────
# The fixed block must check the CAPTURED bd-show exit code, not fold a
# failure straight into the status comparison the way the buggy version did.
printf '%s' "$DRAIN_SRC" | grep -q 'SLING_JSON_RC' \
  && ok "(F1) deployed block captures bd show's exit code separately from the status value" \
  || bad "(F1) deployed block no longer captures bd show's exit code -- may have regressed to the collapse bug"
printf '%s' "$DRAIN_SRC" | grep -q -- '-z "\$SLING_STATUS"' \
  && ok "(F2) deployed block has an explicit unknown-status branch" \
  || bad "(F2) deployed block no longer branches on an unknown/unreadable status"

echo
echo "  PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "ALL ASSERTIONS PASSED"

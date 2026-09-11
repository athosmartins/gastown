#!/usr/bin/env bash
# gate-assignee-clear-holder-aware.selftest.sh (ga-yd8t6)
#
# ORIGIN: two gate sites clear a builder's assignee with a plain
# `bd assign "$BEAD_ID" ""`:
#   - quality-gate-guard.sh Step 5b (~L5012, ga-e7zk7/gt-gwng6): claim-time
#     source-bead detach, every review.
#   - quality-gate-dispatcher.sh FAIL non-keep branch (~L6217, pool authors
#     per gate_fail_assignee_action): return-to-pool clear.
# Since bd-98s5c, `bd assign <id> ""` REFUSES to overwrite another actor's
# live in_progress claim without --force — and both sites run as the
# gate/dispatcher, a DIFFERENT actor than the builder holding the claim, so
# the refusal fires on essentially every ordinary call (measured: 77/day in
# quality-gate-guard.log, ga-yd8t6 evidence). Both sites silently swallowed
# the refusal (`2>/dev/null [|| true]`), and the dispatcher FAIL comment
# asserted "builder assignee cleared" regardless of whether it actually was.
#
# FIX: gate_clear_assignee_if_holder(<bead_id>, <city>) — reads the CURRENT
# raw assignee fresh, then clears it via bd's own holder-aware compare-and-
# swap (`bd update <id> --if-assignee <holder> -a ""`, the alternative
# `bd assign --help` itself recommends over --force) instead of a plain
# assign. Returns 0 if the bead ends up unassigned (already was, or this
# call cleared it), 13 if a different actor grabbed it in the race window
# (expected, not a bug — never escalates to --force, unlike
# gate_release_stale_assignee, because no call site here has independently
# verified the work is done), 1 on any other bd failure. Duplicated
# identically in both files (no shared-lib chokepoint between them — same
# tradeoff default_pool_route_for_rig already documents).
#
# THIS FILE proves: (1) the function's 4 outcomes (already-unassigned /
# clears cleanly / loses the race to a different actor / genuine bd
# failure) in BOTH files' copies, via the same GATE_*_LIB_ONLY sourcing
# mechanism quality-gate-fail-crew-keep.selftest.sh and
# gate-guard-ab-base-test-check.selftest.sh already use for other pure
# functions in these exact two files; (2) a literal reproduction of the
# OLD buggy call (bare `bd assign "" `) under the same live refusal
# semantics, showing it is refused cross-actor — the exact bug this
# function replaces; (3) structural — both known call sites now route
# through the shared function, the old bare pattern is gone from them
# specifically (not a file-wide sweep — other bd-assign-"" sites in
# quality-gate-dispatcher.sh are out of this bug's scope and untouched),
# the FAIL comment reports observed state instead of asserting it, and the
# function is defined before each file's own LIB_ONLY cutoff.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

echo "== gate-assignee-clear-holder-aware.selftest (ga-yd8t6) =="

for f in "$GUARD" "$DISPATCHER"; do
  [ -f "$f" ] || { echo "FATAL: not found: $f" >&2; exit 2; }
done

# ── 1. gate_clear_assignee_if_holder: both files' copies, all 5 outcomes ────
run_scenario() {
  # $1 = "guard"|"dispatcher"  $2 = held_by ("" = already unassigned,
  # "__SHOW_FAILS__" = the show/read itself fails)
  # $3 = update_outcome (ok|race|error, ignored when $2 is empty or the
  # show-fails sentinel)  $4 = logfile
  local which="$1" held_by="$2" update_outcome="$3" log="$4"
  local src lib_var
  if [ "$which" = "guard" ]; then src="$GUARD"; lib_var="GATE_GUARD_LIB_ONLY"
  else src="$DISPATCHER"; lib_var="GATE_DISPATCHER_LIB_ONLY"; fi
  : > "$log"
  bash -c '
    LIB_VAR="$1"; SRC="$2"; HELD_BY="$3"; UPDATE_OUTCOME="$4"; BD_LOG="$5"
    bd() {
      echo "$*" >> "$BD_LOG"
      case " $* " in
        *" show "*)
          if [ "$HELD_BY" = "__SHOW_FAILS__" ]; then return 1; fi
          if [ -n "$HELD_BY" ]; then printf "{\"assignee\":\"%s\"}\n" "$HELD_BY"
          else printf "{\"assignee\":\"\"}\n"; fi
          return 0 ;;
        *" update "*)
          case "$UPDATE_OUTCOME" in
            ok) return 0 ;; race) return 13 ;; error) return 1 ;;
          esac ;;
      esac
      return 0
    }
    export "$LIB_VAR"=1
    # shellcheck disable=SC1090
    . "$SRC" >/dev/null 2>&1 || { echo "FATAL: could not source $SRC in lib-only mode" >&2; exit 2; }
    set +e   # sourcing runs under the script'"'"'s own set -euo pipefail, which
             # leaks into this shell — same fix the other lib-only selftests
             # (quality-gate-fail-crew-keep.selftest.sh,
             # gate-guard-ab-base-test-check.selftest.sh) use for the identical
             # reason.
    type gate_clear_assignee_if_holder >/dev/null 2>&1 \
      || { echo "FATAL: gate_clear_assignee_if_holder not defined after lib-only sourcing"; exit 2; }
    RC=0
    gate_clear_assignee_if_holder "src-bead" "/fake/city" || RC=$?
    exit "$RC"
  ' _ "$lib_var" "$src" "$held_by" "$update_outcome" "$log"
  return $?
}

for WHICH in guard dispatcher; do
  echo "── gate_clear_assignee_if_holder ($WHICH copy) ──"

  LOG1="$(mktemp)"
  run_scenario "$WHICH" "" "ok" "$LOG1"; RC1=$?
  [ "$RC1" -eq 0 ] && ok "($WHICH) already-unassigned -> returns 0" \
    || bad "($WHICH) already-unassigned -> expected 0, got $RC1 — log: $(cat "$LOG1")"
  grep -q ' update ' "$LOG1" \
    && bad "($WHICH) already-unassigned -> called update unnecessarily — log: $(cat "$LOG1")" \
    || ok "($WHICH) already-unassigned -> no write attempted (nothing to clear)"
  rm -f "$LOG1"

  LOG2="$(mktemp)"
  run_scenario "$WHICH" "builderX" "ok" "$LOG2"; RC2=$?
  [ "$RC2" -eq 0 ] && ok "($WHICH) held by builderX, compare-and-swap succeeds -> returns 0" \
    || bad "($WHICH) held+ok -> expected 0, got $RC2 — log: $(cat "$LOG2")"
  grep -q -- "--if-assignee builderX" "$LOG2" \
    && ok "($WHICH) used --if-assignee builderX (holder-aware, not a blind assign)" \
    || bad "($WHICH) did not use --if-assignee with the observed holder — log: $(cat "$LOG2")"
  grep -q -- "--force" "$LOG2" \
    && bad "($WHICH) --force appeared — this function must never force (no merge_verified contract here). log: $(cat "$LOG2")" \
    || ok "($WHICH) --force never used"
  rm -f "$LOG2"

  LOG3="$(mktemp)"
  run_scenario "$WHICH" "builderX" "race" "$LOG3"; RC3=$?
  [ "$RC3" -eq 13 ] && ok "($WHICH) a different actor grabbed it before the write landed -> returns 13 (expected race, not an error)" \
    || bad "($WHICH) race -> expected 13, got $RC3 — log: $(cat "$LOG3")"
  rm -f "$LOG3"

  LOG4="$(mktemp)"
  run_scenario "$WHICH" "builderX" "error" "$LOG4"; RC4=$?
  [ "$RC4" -eq 1 ] && ok "($WHICH) genuine bd failure -> returns 1 (distinct from the race code 13)" \
    || bad "($WHICH) genuine failure -> expected 1, got $RC4 — log: $(cat "$LOG4")"
  rm -f "$LOG4"

  # ga-yd8t6 self-audit finding: the current-state READ failing must be its
  # own distinguishable outcome, never silently folded into "confirmed
  # already unassigned" (both would otherwise return 0 — the exact
  # error-vs-empty collapse this codebase's gate-done self-audit exists to
  # catch, and the same class the surrounding _GFAIL_ROUTE_VERIFY_READ_OK
  # logic right next to this fix already defends against for a sibling read).
  LOG5="$(mktemp)"
  run_scenario "$WHICH" "__SHOW_FAILS__" "ok" "$LOG5"; RC5=$?
  [ "$RC5" -eq 2 ] && ok "($WHICH) current-state read fails -> returns 2 (distinct from 0/13/1, never silently treated as already-unassigned)" \
    || bad "($WHICH) read-failure -> expected 2, got $RC5 — log: $(cat "$LOG5")"
  grep -q ' update ' "$LOG5" \
    && bad "($WHICH) read-failure -> attempted a write despite not knowing the current holder — log: $(cat "$LOG5")" \
    || ok "($WHICH) read-failure -> no write attempted (never guesses at an unknown holder)"
  rm -f "$LOG5"
done

# ── 2. Repro: the OLD bare 'bd assign "" ' call is refused cross-actor ──────
# (bd-98s5c) — the exact bug ga-yd8t6 replaces.
echo "── repro: the OLD bare 'bd assign \"\"' call is refused cross-actor (bd-98s5c) — the bug this replaces ──"
LOG_OLD="$(mktemp)"
bash -c '
  set -euo pipefail
  BD_LOG="$1"
  bd() {
    echo "$*" >> "$BD_LOG"
    case " $* " in
      *" assign "*)
        printf "%s" "$*" | grep -q -- "--force" && return 0
        return 1
        ;;
    esac
    return 0
  }
  OLD_RC=0
  bd assign "src-bead" "" 2>/dev/null || OLD_RC=$?
  exit "$OLD_RC"
' _ "$LOG_OLD"
OLD_REPRO_RC=$?
[ "$OLD_REPRO_RC" -ne 0 ] \
  && ok "OLD pattern: bare assign is refused when a different actor holds the claim (bd-98s5c) — reproduced live" \
  || bad "OLD pattern unexpectedly succeeded — mock does not model bd-98s5c correctly"
rm -f "$LOG_OLD"

# ── 3. Structural: both known call sites route through the shared function ──
echo "── structural: both known call sites wired; old patterns gone from THOSE sites specifically ──"

grep -qF 'gate_clear_assignee_if_holder "$BEAD_ID" "$BEAD_CITY"' "$GUARD" \
  && ok "quality-gate-guard.sh Step 5b calls gate_clear_assignee_if_holder" \
  || bad "quality-gate-guard.sh does not call gate_clear_assignee_if_holder"

grep -qF 'gate_clear_assignee_if_holder "$BEAD_ID" "$BEAD_CITY"' "$DISPATCHER" \
  && ok "quality-gate-dispatcher.sh FAIL non-keep branch calls gate_clear_assignee_if_holder" \
  || bad "quality-gate-dispatcher.sh does not call gate_clear_assignee_if_holder"

# guard.sh has exactly one `bd ... assign` call in the whole file (Step 5b) —
# confirmed during ga-yd8t6's investigation — so a whole-file absence check
# is safe and unambiguous here.
GUARD_OLD_COUNT=$(grep -cF 'bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null; then' "$GUARD" || true)
[ "${GUARD_OLD_COUNT:-0}" -eq 0 ] \
  && ok "quality-gate-guard.sh: the old bare 'bd assign' Step 5b call is gone" \
  || bad "quality-gate-guard.sh: old bare assign call still present (count=${GUARD_OLD_COUNT:-0})"

# dispatcher.sh: this EXACT literal line appears at TWO sites pre-fix — the
# needs-human cleanup (~L6105, OUT of this bug's scope, left unchanged) and
# the FAIL non-keep return-to-pool branch (~L6217, IN scope). After the fix
# only the needs-human site remains -> count goes from 2 to 1. NOT a
# file-wide "zero bare assigns" sweep — several other bd-assign-"" sites in
# this file (already-merged/rebase paths near L9000+/L10000+) are out of
# scope and correctly untouched.
DISP_OLD_COUNT=$(grep -cF 'bd -C "$BEAD_CITY" assign "$BEAD_ID" "" 2>/dev/null || true' "$DISPATCHER" || true)
[ "${DISP_OLD_COUNT:-0}" -eq 1 ] \
  && ok "quality-gate-dispatcher.sh: FAIL non-keep branch's old bare assign is gone (needs-human site at ~L6105 correctly left as the sole remaining match)" \
  || bad "quality-gate-dispatcher.sh: expected exactly 1 remaining bare-assign match (needs-human site only), found ${DISP_OLD_COUNT:-0}"

grep -qF 'and builder assignee cleared. gc.routed_to restored to' "$DISPATCHER" \
  && bad "dispatcher.sh: FAIL comment still unconditionally asserts the assignee was cleared, instead of reporting the observed state" \
  || ok "dispatcher.sh: FAIL comment no longer unconditionally asserts the assignee was cleared"

grep -qF '_GFAIL_ASSIGNEE_OBS' "$DISPATCHER" \
  && ok "dispatcher.sh: FAIL comment reports an OBSERVED (verified post-write) assignee state, matching gc.routed_to's existing ga-p5q3 discipline" \
  || bad "dispatcher.sh: no observed-assignee-state variable found — FAIL comment still asserts rather than verifies"

# Function defined before each file's own LIB_ONLY cutoff — the
# ga-zdkn1-class regression gate-guard-ab-base-test-check.selftest.sh
# already guards for its own two functions, and section 1 above depends on
# it holding for THIS function too (otherwise lib-only sourcing would never
# see it). Anchored on the exact, unpadded early-return conditional line —
# a looser substring match on "GATE_*_LIB_ONLY:-" hits an EARLIER, unrelated
# use in quality-gate-dispatcher.sh (the quiet-hours nudge-timeout override
# near L266 also embeds that exact substring) and would silently pick the
# wrong line.
GUARD_CUTOFF=$(grep -n '^if \[ -n "\${GATE_GUARD_LIB_ONLY:-}" \]; then$' "$GUARD" | head -1 | cut -d: -f1)
GUARD_FN_DEF=$(grep -n '^gate_clear_assignee_if_holder() {' "$GUARD" | head -1 | cut -d: -f1)
if [ -n "$GUARD_FN_DEF" ] && [ -n "$GUARD_CUTOFF" ] && [ "$GUARD_FN_DEF" -lt "$GUARD_CUTOFF" ]; then
  ok "quality-gate-guard.sh: gate_clear_assignee_if_holder (L$GUARD_FN_DEF) defined before the GATE_GUARD_LIB_ONLY cutoff (L$GUARD_CUTOFF)"
else
  bad "REGRESSION (ga-zdkn1-class): guard fn def=${GUARD_FN_DEF:-missing} cutoff=${GUARD_CUTOFF:-missing}"
fi

DISP_CUTOFF=$(grep -n '^if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then$' "$DISPATCHER" | head -1 | cut -d: -f1)
DISP_FN_DEF=$(grep -n '^gate_clear_assignee_if_holder() {' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DISP_FN_DEF" ] && [ -n "$DISP_CUTOFF" ] && [ "$DISP_FN_DEF" -lt "$DISP_CUTOFF" ]; then
  ok "quality-gate-dispatcher.sh: gate_clear_assignee_if_holder (L$DISP_FN_DEF) defined before the GATE_DISPATCHER_LIB_ONLY cutoff (L$DISP_CUTOFF)"
else
  bad "REGRESSION (ga-zdkn1-class): dispatcher fn def=${DISP_FN_DEF:-missing} cutoff=${DISP_CUTOFF:-missing}"
fi

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

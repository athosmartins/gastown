#!/usr/bin/env bash
# prod-tests/gascity/story-ga-rfpm9.sh — prod test for ga-rfpm9: pilot-dispatcher.sh
# _filter_candidates (and its two sibling chokepoints in the same file) plus
# context-check-dispatcher.sh's context_check_is_parked only recognized the
# EXACT string "pilot:no-auto-dispatch" — the bare "no-auto-dispatch" label
# (no pilot: prefix, applied because it reads as an obvious synonym) was
# silently non-functional. 8 live beads carried the bare form; ga-qntfo was
# dispatched via sling ga-0ci7r 4 days after creation despite its body
# explicitly saying "para o Pilot não despachar isto".
#
# Called by run.sh after deploy (STORY_ID=ga-rfpm9). Exits 0 on pass.
#
# What this proves on the LIVE framework:
#   1. The deployed pilot-dispatcher.sh recognizes the bare label at all THREE
#      chokepoints that check it (_filter_candidates candidate-selection time,
#      _pilot_hold_or_escalate's AC3 skip, and the late pre-dispatch
#      _PREDISPATCH_HUMANGATE re-check) — not merely defines the alias
#      somewhere, but that each specific consumer carries it.
#   2. The deployed context-check-dispatcher.sh's context_check_is_parked
#      (the CANONICAL consumer per its own ga-bzbig header comment) recognizes
#      the bare label too.
#   3. The three sandboxed selftests that exercise these functions (real code,
#      no reimplementation) all pass in full.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
DISPATCHER="$ASSETS/pilot-dispatcher.sh"
CCD="$ASSETS/context-check-dispatcher.sh"

log()  { echo "[prod-test:gascity ga-rfpm9] $*"; }
fail() { echo "[prod-test:gascity ga-rfpm9] FAIL: $*" >&2; exit 1; }

[[ -f "$DISPATCHER" ]] || fail "deployed pilot-dispatcher.sh missing: $DISPATCHER"
[[ -f "$CCD" ]] || fail "deployed context-check-dispatcher.sh missing: $CCD"
log "Deployed files found: $DISPATCHER, $CCD"

# ── 1a. _filter_candidates carries the bare-label alias ─────────────────────
FC_SNIP="$(awk '/^_filter_candidates\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
case "$FC_SNIP" in
  *_filter_candidates*) : ;;
  *) fail "could not extract _filter_candidates from deployed file — did it move/rename?" ;;
esac
echo "$FC_SNIP" | grep -q 'or . == "no-auto-dispatch"' \
  || fail "_filter_candidates lacks the bare no-auto-dispatch clause — fix not deployed"
log "_filter_candidates carries the bare no-auto-dispatch clause"

# ── 1b. _pilot_hold_or_escalate carries the bare-label alias ────────────────
HOLD_SNIP="$(awk '/^_pilot_hold_or_escalate\(\)/{f=1} f{print} f&&/^}$/{exit}' "$DISPATCHER")"
case "$HOLD_SNIP" in
  *_pilot_hold_or_escalate*) : ;;
  *) fail "could not extract _pilot_hold_or_escalate from deployed file — did it move/rename?" ;;
esac
echo "$HOLD_SNIP" | grep -q 'or . == "no-auto-dispatch"' \
  || fail "_pilot_hold_or_escalate lacks the bare no-auto-dispatch clause — fix not deployed"
log "_pilot_hold_or_escalate carries the bare no-auto-dispatch clause"

# ── 1c. Late pre-dispatch re-check regex carries the bare-label alternative ──
grep -q 'pilot:no-auto-dispatch|no-auto-dispatch|blocked' "$DISPATCHER" \
  || fail "the late _PREDISPATCH_HUMANGATE re-check lacks the bare no-auto-dispatch alternative — fix not deployed"
log "late pre-dispatch re-check regex carries the bare no-auto-dispatch alternative"

# ── 2. context_check_is_parked (the CANONICAL consumer) carries the alias ───
CCD_SNIP="$(awk '/^context_check_is_parked\(\)/{f=1} f{print} f&&/^}$/{exit}' "$CCD")"
case "$CCD_SNIP" in
  *context_check_is_parked*) : ;;
  *) fail "could not extract context_check_is_parked from deployed file — did it move/rename?" ;;
esac
echo "$CCD_SNIP" | grep -q 'pilot:no-auto-dispatch|no-auto-dispatch)' \
  || fail "context_check_is_parked lacks the bare no-auto-dispatch alias — fix not deployed"
log "context_check_is_parked carries the bare no-auto-dispatch alias"

# ── 3. Sandboxed selftests must pass in full (real code, throwaway fixtures,
#      PATH-shimmed bd/gc/notify — safe on prod) ────────────────────────────
run_selftest() {
  local name="$1" path="$ASSETS/$1"
  [[ -x "$path" ]] || fail "selftest missing or not executable: $path"
  log "running $name ..."
  local out; out="$(mktemp)"
  if ! bash "$path" >"$out" 2>&1; then
    cat "$out" >&2
    rm -f "$out"
    fail "$name failed"
  fi
  tail -3 "$out"
  rm -f "$out"
  log "$name PASS"
}
run_selftest "pilot-dispatcher.selftest.sh"
run_selftest "pilot-hold-escalate.selftest.sh"
run_selftest "context-check-dispatcher.selftest.sh"

log "PASS — ga-rfpm9 bare no-auto-dispatch alias deployed and behaviorally correct at all four chokepoints"
exit 0

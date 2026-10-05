#!/usr/bin/env bash
# prod-tests/gascity/story-ga-4q2zo5.sh — prod test for ga-4q2zo5 (E12 of the P0 ga-ufskhy): the write-time doctrine, as an A/B that
# ships OFF.
#
# What "deployed and correct" means for an experiment that must not change anything until the Mayor turns it on:
#   (1) the pieces are on disk in the LIVE tree and parse;
#   (2) with no conf the experiment is provably OFF: no block, no roster row, nothing logged — the property every other dispatch relies
#       on, so it is the one worth checking after a deploy;
#   (3) the arm is the documented, recomputable function of the bead id (checked by an independent SHA-256, not by the script agreeing
#       with itself);
#   (4) a conf that cannot be read is its own state: nothing handed out, exit 6, nothing recorded — never "no conf";
#   (5) a treated bead gets the block (short, with the comment-line format) and is recorded; a control bead gets nothing and is recorded;
#   (6) the Pilot's hook and its call site are in the deployed dispatcher.
# Everything runs against a scratch E12_STATE_DIR: it never reads or writes the live .gc/e12-roster.jsonl, calls no API and spends nothing.
# Whether the LIVE city is switched on is reported, never asserted: turning it on is the Mayor's decision and either state is a valid deploy.
#
# Called by run.sh after deploy (STORY_ID=ga-4q2zo5). Exits 0 on pass.

set -uo pipefail

CITY="${CITY:-/Users/athos/gt/.gascity-gastown-hq}"
ASSETS="$CITY/packs/town-deltas/assets"
ARMS="$ASSETS/e12-arms.sh"
DISPATCHER="$ASSETS/pilot-dispatcher.sh"

log()  { echo "[prod-test:gascity ga-4q2zo5] $*"; }
fail() { echo "[prod-test:gascity ga-4q2zo5] FAIL: $*" >&2; exit 1; }

# ── 1. the pieces are in the live tree and parse ──────────────────────────────────────────────────────────────
for f in "$ARMS" "$DISPATCHER"; do
  [[ -f "$f" ]] || fail "not deployed: $f"
  bash -n "$f" || fail "does not parse under bash: $f"
done
command -v jq >/dev/null 2>&1 || fail "jq missing — the roster cannot be written or read"
log "e12-arms.sh and pilot-dispatcher.sh are deployed and parse ✓"

S="$(mktemp -d "${TMPDIR:-/tmp}/prod-ga-4q2zo5.XXXXXX")" || fail "no scratch dir"
trap 'rm -rf "$S"' EXIT
export E12_STATE_DIR="$S"

# ── 2. with no conf the experiment is OFF, provably ───────────────────────────────────────────────────────────
st="$(bash "$ARMS" state)" || fail "e12-arms.sh state failed"
[[ "$st" == absent ]] || fail "no conf must read 'absent', got '$st'"
rc=0; out="$(bash "$ARMS" block ga-prodtest "$CITY" prod-test 2>&1)" || rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] || fail "block with no conf must print NOTHING and exit 0, got rc=$rc out='$out'"
[[ ! -e "$S/e12-roster.jsonl" ]] || fail "block with no conf wrote a roster row — an absent experiment records nothing"
log "no conf → state=absent, block prints nothing and says nothing, no roster row ✓"

# ── 3. the arm is the documented function of the bead id (independent recomputation) ─────────────────────────────
printf 'treated_pct=50\n' > "$S/e12-ab.conf"
[[ "$(bash "$ARMS" state)" == "active treated_pct=50" ]] || fail "active conf misread: $(bash "$ARMS" state)"
n_t=0; n_c=0; ID_T=""; ID_C=""
for id in ga-t1 ga-t2 ga-t3 ga-t4 ga-t5 ga-t6 ga-t7 ga-t8; do
  d="$(printf '%s' "e12-write-3state:$id" | shasum -a 256 | cut -c1-8)"
  want=control; [[ $(( 16#$d % 100 )) -lt 50 ]] && want=treated
  got="$(bash "$ARMS" arm "$id")" || fail "arm $id failed"
  [[ "$got" == "$want" ]] || fail "arm for $id is '$got' but SHA-256(e12-write-3state:$id) mod 100 says '$want' — the deployed rule is not the documented one"
  if [[ "$want" == treated ]]; then n_t=$((n_t+1)); [[ -n "$ID_T" ]] || ID_T="$id"; else n_c=$((n_c+1)); [[ -n "$ID_C" ]] || ID_C="$id"; fi
done
[[ "$n_t" -ge 1 && "$n_c" -ge 1 ]] || fail "eight sample ids all landed in one arm (treated=$n_t control=$n_c): the check cannot tell the arms apart"
log "arm = SHA-256(\"e12-write-3state:<id>\") mod 100 < treated_pct, recomputed independently for 8 ids (treated=$n_t control=$n_c) ✓"

# ── 4. a treated bead gets the block and a row; a control bead gets nothing and a row ─────────────────────────────
rc=0; tb="$(bash "$ARMS" block "$ID_T" "$CITY" prod-test)" || rc=$?
[[ "$rc" -eq 0 && -n "$tb" ]] || fail "block for the treated bead $ID_T must print the text, got rc=$rc"
[[ "$(printf '%s\n' "$tb" | head -1)" == "## Write-time doctrine — experiment E12 (ga-4q2zo5)" ]] || fail "the block's first line is not the header the Pilot checks: $(printf '%s\n' "$tb" | head -1)"
[[ "$(printf '%s\n' "$tb" | grep -c .)" -le 10 ]] || fail "the block is longer than 10 lines"
case "$tb" in *"vazio → <what the code does>; falhou/ilegível → <what the code does>"*) ;; *) fail "the block lacks the comment-line format" ;; esac
case "$tb" in *"does the code next to it do exactly this?"*) ;; *) fail "the block lacks the re-read question" ;; esac
rc=0; cb="$(bash "$ARMS" block "$ID_C" "$CITY" prod-test)" || rc=$?
[[ "$rc" -eq 0 && -z "$cb" ]] || fail "block for the control bead $ID_C must print NOTHING, got rc=$rc out='$cb'"
[[ "$(wc -l < "$S/e12-roster.jsonl" | tr -d ' ')" == 2 ]] || fail "expected 2 roster rows (one treated, one control), got $(wc -l < "$S/e12-roster.jsonl" | tr -d ' ')"
[[ "$(jq -r --arg b "$ID_C" 'select(.bead==$b) | .arm' "$S/e12-roster.jsonl")" == control ]] || fail "the control bead has no control row — a control with no denominator is not a control"
log "treated → the ≤10-line block with the 'vazio → …; falhou/ilegível → …' format; control → nothing; both recorded ✓"

# ── 5. a conf that cannot be read is its own state ───────────────────────────────────────────────────────────────
: > "$S/e12-ab.conf"
case "$(bash "$ARMS" state)" in invalid:*) ;; *) fail "an EMPTY conf must read invalid:*, got '$(bash "$ARMS" state)'" ;; esac
printf 'treated_pct=abc\n' > "$S/e12-ab.conf"
rm -f "$S/e12-roster.jsonl"
# the Pilot drops stderr and logs only a non-zero exit: an invalid conf must not answer like "no conf" (exit 0, silent) or a typo at
# turn-on runs the experiment at 0% with nobody told
rc=0; out="$(bash "$ARMS" block "$ID_T" "$CITY" prod-test 2>/dev/null)" || rc=$?
[[ "$rc" -eq 6 && -z "$out" ]] || fail "block under an invalid conf must print nothing and exit 6, got rc=$rc out='$out'"
[[ ! -e "$S/e12-roster.jsonl" ]] || fail "the invalid-conf check wrote a roster row"
log "empty / malformed conf → invalid (not 'no conf'), block exits 6, nothing recorded ✓"

# ── 6. the Pilot's hook is in the deployed dispatcher ─────────────────────────────────────────────────────────────
grep -q '^_e12_doctrine_block() {' "$DISPATCHER" || fail "_e12_doctrine_block() missing from the deployed pilot-dispatcher.sh"
grep -q '_e12_doctrine_block "\$STORY_ID" "\$STORY_BEAD_CITY"' "$DISPATCHER" || fail "the call site of _e12_doctrine_block is missing from the deployed dispatch_one()"
log "pilot-dispatcher.sh carries the E12 hook and its call site ✓"

# ── informational: is the LIVE city switched on? (never a failure — that is the Mayor's call) ─────────────────────
unset E12_STATE_DIR
live="$(E12_STATE_DIR="$CITY/.gc" bash "$ARMS" state 2>/dev/null)" || live="unreadable"
log "live city experiment state: $live (informational)"

log "PASS"
exit 0

#!/usr/bin/env bash
# gate-selfheal.selftest.sh — Prove the ga-jb4l self-healing FAIL loop logic in
# isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-jb4l: a gate FAIL stranded the source story forever — no durable
# feedback reached the source bead and no actor re-picked it. The fix:
#   (gate)  on FAIL → attach a "GATE-FEEDBACK" comment to the SOURCE bead,
#           label gate:needs-fix, clear story:in-flight + assignee, bump a
#           gate:fix-attempt:N counter, and after N=3 escalate (gate:needs-human).
#   (pilot) re-dispatch gate:needs-fix beads with the reviewer feedback in the
#           builder prompt, and NEVER re-dispatch gate:needs-human beads.
#
# This harness unit-tests the PURE parsing/decision snippets the dispatchers use
# (the attempt-counter parser, the GATE-FEEDBACK selector, the cap decision) and
# DRIFT-GUARDS the real scripts so a future refactor that drops the labels/queries
# fails loudly. Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
PILOT="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── The exact parsers used by the dispatchers ────────────────────────────────
# Attempt counter — gate side reads SPACE-separated labels; pilot side reads
# COMMA-separated. Both take the MAX numeric suffix (default 0).
attempt_from_space() { printf '%s' "$1" | tr ' ' '\n' \
  | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1; }
attempt_from_comma() { printf '%s' "$1" | tr ',' '\n' \
  | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1; }
# GATE-FEEDBACK selector — newest comment whose .text starts with GATE-FEEDBACK.
feedback_select() { jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""'; }

echo "── 1. attempt-counter parser (gate: space-separated) ──"
eq "no counter → 0 (empty after default)" "$(x=$(attempt_from_space 'lane:small story:approved'); echo "${x:-0}")" "0"
eq "single counter :1"  "$(attempt_from_space 'gate:needs-fix gate:fix-attempt:1')" "1"
eq "single counter :3"  "$(attempt_from_space 'tech-debt gate:fix-attempt:3 gate:failed')" "3"
eq "max of duplicates"  "$(attempt_from_space 'gate:fix-attempt:1 gate:fix-attempt:2')" "2"

echo "── 2. attempt-counter parser (pilot: comma-separated) ──"
eq "comma single :2"    "$(attempt_from_comma 'lane:small,gate:needs-fix,gate:fix-attempt:2')" "2"
eq "comma no counter→0" "$(x=$(attempt_from_comma 'story:approved,gate:needs-fix'); echo "${x:-0}")" "0"

echo "── 3. cap decision (PREV >= CAP → escalate; else increment) ──"
CAP=3
decide() { if [ "$1" -ge "$CAP" ]; then echo "escalate"; else echo "$(( $1 + 1 ))"; fi; }
eq "prev=0 → re-dispatch attempt 1" "$(decide 0)" "1"
eq "prev=2 → re-dispatch attempt 3" "$(decide 2)" "3"
eq "prev=3 → escalate (cap hit)"    "$(decide 3)" "escalate"
eq "prev=4 → escalate (over cap)"   "$(decide 4)" "escalate"

echo "── 4. GATE-FEEDBACK selector picks newest matching comment ──"
FIX_JSON='[{"text":"old build note"},{"text":"GATE-FEEDBACK (gate_run=g1): first fail\nReviewer 1 FAIL: bad"},{"text":"a human reply"},{"text":"GATE-FEEDBACK (gate_run=g2): second fail\nReviewer 3 FAIL: race"}]'
SEL="$(printf '%s' "$FIX_JSON" | feedback_select)"
case "$SEL" in
  GATE-FEEDBACK*g2*race*) ok "selected newest GATE-FEEDBACK (g2/race)" ;;
  *) bad "selector picked wrong/empty comment: [$SEL]" ;;
esac
eq "no GATE-FEEDBACK → empty" "$(printf '%s' '[{"text":"hi"},{"text":"bye"}]' | feedback_select)" ""
eq "empty comments → empty"   "$(printf '%s' '[]' | feedback_select)" ""

echo "── 5. drift-guard: gate dispatcher still implements the loop ──"
grep -q 'gate:needs-fix'                 "$GATE" && ok "gate sets gate:needs-fix"           || bad "gate missing gate:needs-fix"
grep -q 'gate:needs-human'               "$GATE" && ok "gate sets gate:needs-human"         || bad "gate missing gate:needs-human"
grep -q 'gate:fix-attempt:'              "$GATE" && ok "gate bumps fix-attempt counter"     || bad "gate missing fix-attempt counter"
grep -q 'GATE-FEEDBACK'                  "$GATE" && ok "gate attaches GATE-FEEDBACK"         || bad "gate missing GATE-FEEDBACK"
grep -q 'GATE_FIX_CAP=3'                 "$GATE" && ok "gate cap = 3"                        || bad "gate missing cap=3"
grep -Eq 'assign "\$BEAD_ID" ""'         "$GATE" && ok "gate clears source assignee"        || bad "gate does not clear assignee"
grep -q 'mail send mayor'                "$GATE" && ok "gate escalates to Mayor"             || bad "gate missing Mayor escalation"

echo "── 6. drift-guard: pilot re-dispatches needs-fix, excludes needs-human ──"
eq "pilot excludes gate:needs-human in every candidate query (13)" \
   "$(grep -c 'exclude-label "gate:needs-human"' "$PILOT")" "13"
grep -q 'gate:needs-fix'   "$PILOT" && ok "pilot detects gate:needs-fix"        || bad "pilot missing gate:needs-fix path"
grep -q 'GATE-FEEDBACK'    "$PILOT" && ok "pilot reads GATE-FEEDBACK comment"   || bad "pilot missing GATE-FEEDBACK read"
grep -q 'GATE_FIX_SECTION' "$PILOT" && ok "pilot injects feedback into prompt"  || bad "pilot missing GATE_FIX_SECTION"

echo "── 7. drift-guard: cap (needs-human) branch ALSO clears in-flight markers (ga-5w0hr) ──"
# ga-5w0hr: the RETRY CAP REACHED branch sets gate:needs-human but historically
# left story:in-flight / pilot:dispatched / assignee intact, so a capped bead
# masqueraded as in-flight with NO worker forever (ga-jhyu: 21h SEM WORKER after
# 3× FAIL). Isolate JUST the cap branch (from "RETRY CAP REACHED" up to the
# matching `else`, so the needs-fix branch's own cleanup can't mask a regression)
# and prove it now strips the stale in-flight claim. needs-human still blocks the
# Pilot (asserted in section 6); this only fixes the lying data-model state.
CAP_BLOCK="$(awk '/RETRY CAP REACHED/{f=1} f{print} f&&/^    else[[:space:]]*$/{exit}' "$GATE")"
printf '%s\n' "$CAP_BLOCK" | grep -q 'label remove "\$BEAD_ID" "story:in-flight"' \
  && ok "cap branch clears story:in-flight" \
  || bad "cap branch leaves story:in-flight (ga-5w0hr: bead strands SEM WORKER)"
printf '%s\n' "$CAP_BLOCK" | grep -q 'label remove "\$BEAD_ID" "pilot:dispatched"' \
  && ok "cap branch clears pilot:dispatched" \
  || bad "cap branch leaves pilot:dispatched (stale Pilot claim)"
printf '%s\n' "$CAP_BLOCK" | grep -Eq 'assign "\$BEAD_ID" ""' \
  && ok "cap branch clears stale builder assignee" \
  || bad "cap branch leaves stale assignee (hides bead from Pilot _filter_candidates)"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

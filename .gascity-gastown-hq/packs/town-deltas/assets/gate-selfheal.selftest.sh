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
# COMMA-separated. Semantics (ga-26df, refined after ga-wisp-198xqe):
#   - an explicit `:0` is the RESET SENTINEL and always wins (a human's manual clear);
#   - otherwise take MAX.
# Why not plain MIN: coexistence is NOT manual-clear-only. The dispatcher's bump loop
# removes stale labels with `bd ... label remove ... || true`; a transient Dolt hiccup
# (routine here) leaves the old one behind, so the AUTOMATIC path alone can yield {1,2}.
# MIN reads that as 1 → the counter STALLS below the cap (silent unbounded machine-only
# retries). MAX reads 2 → keeps advancing to GATE_FIX_CAP. The `:0`-override recovers the
# manual-clear case (a reset stamps :0, which wins) without the MIN stall.
_attempt() {  # stdin: newline-separated numeric suffixes
  local nums; nums=$(cat)
  if printf '%s\n' "$nums" | grep -qx 0; then echo 0
  else printf '%s\n' "$nums" | sort -n | tail -1; fi
}
attempt_from_space() { printf '%s' "$1" | tr ' ' '\n' \
  | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | _attempt; }
attempt_from_comma() { printf '%s' "$1" | tr ',' '\n' \
  | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | _attempt; }
# GATE-FEEDBACK selector — newest comment whose .text starts with GATE-FEEDBACK.
feedback_select() { jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""'; }

echo "── 1. attempt-counter parser (gate: space-separated) ──"
eq "no counter → 0 (empty after default)" "$(x=$(attempt_from_space 'lane:small story:approved'); echo "${x:-0}")" "0"
eq "single counter :1"  "$(attempt_from_space 'gate:needs-fix gate:fix-attempt:1')" "1"
eq "single counter :3"  "$(attempt_from_space 'tech-debt gate:fix-attempt:3 gate:failed')" "3"
# ga-wisp-198xqe: a {1,2} residue is the AUTOMATIC path (a failed `|| true` removal),
# NOT a manual clear. It must read as MAX (2) so the counter keeps advancing toward the
# cap — plain MIN read it as 1 and STALLED the circuit-breaker (silent infinite retries).
eq "automatic residue {1,2} → MAX 2 (keeps advancing to cap, no stall)" \
   "$(attempt_from_space 'gate:fix-attempt:1 gate:fix-attempt:2')" "2"
eq "automatic residue {2,3} → MAX 3 (reaches cap → escalates, not stalls)" \
   "$(attempt_from_space 'gate:fix-attempt:2 gate:fix-attempt:3')" "3"
# The reset sentinel :0 wins even against a stale cap-exhausted 3 — a human cleared it.
eq "ga-26df acceptance: clear-to-0 alongside stale cap-exhausted 3 → resolves 0, not 3" \
   "$(attempt_from_space 'gate:needs-human gate:fix-attempt:3 gate:fix-attempt:0')" "0"
eq ":0 beats a whole stale ladder {0,1,2,3} → 0 (reset wins over any residue)" \
   "$(attempt_from_space 'gate:fix-attempt:3 gate:fix-attempt:2 gate:fix-attempt:1 gate:fix-attempt:0')" "0"

echo "── 2. attempt-counter parser (pilot: comma-separated) ──"
eq "comma single :2"    "$(attempt_from_comma 'lane:small,gate:needs-fix,gate:fix-attempt:2')" "2"
eq "comma :0 reset wins (ga-26df, pilot side)" \
   "$(attempt_from_comma 'gate:needs-fix,gate:fix-attempt:3,gate:fix-attempt:0')" "0"
eq "comma automatic residue {1,2} → MAX 2 (pilot side, no stall)" \
   "$(attempt_from_comma 'gate:needs-fix,gate:fix-attempt:1,gate:fix-attempt:2')" "2"
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
# ga-26df (refined, ga-wisp-198xqe): the parser in BOTH dispatchers must implement
# `:0`-override-else-MAX, NOT plain MIN (head -1, which stalls on a {1,2} residue) and
# NOT plain MAX (tail -1 alone, which discards manual clears). The signature of the right
# shape is a `grep -qx 0` reset check paired with a `sort -n | tail -1` fallback. A future
# edit collapsing either back to a single head -1 / tail -1 re-introduces one of the two
# bugs, and this drift-guard is the only thing that would notice (the unit tests above
# exercise a local mirror, not these files).
for _f in "$GATE" "$PILOT"; do
  _n=$(basename "$_f")
  if grep -q 'grep -qx 0' "$_f" && grep -Fq "sed -n 's/^gate:fix-attempt:\\([0-9]\\{1,\\}\\)\$/\\1/p'" "$_f"; then
    ok "$_n fix-attempt parser is :0-override-else-MAX (not plain MIN/MAX)"
  else
    bad "$_n fix-attempt parser lost the :0-override guard — MIN stall or MAX clear-discard regression (ga-26df)"
  fi
  if grep -Eq "gate:fix-attempt:.*sort -n \\| head -1" "$_f"; then
    bad "$_n still has a plain 'sort -n | head -1' on fix-attempt — MIN stall regression (ga-wisp-198xqe)"
  else
    ok "$_n has no plain MIN (head -1) on fix-attempt"
  fi
done
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

echo "── 8. drift-guard: ga-u4yi — AUTHOR (not just Mayor) is mailed at every gate:needs-human transition ──"
# Bug ga-u4yi (thies-wa, P1): a branch parked at gate:needs-human rotted 20h in
# total silence because only the Mayor was mailed — the AUTHOR had no durable
# signal, only an ephemeral bd comment. Fix: mail "$AUTHOR" (survives a dead/
# restarted session, unlike nudge) at EVERY site that applies gate:needs-human.
# ga-huaxo: BIJECTION, not a magic count. The old guard asserted `grep -c mail == N`
# with N hardcoded — so every legitimate new needs-human site left the guard RED until a
# human bumped N by hand (exactly what happened: a 5th site shipped WITH its mail, the
# count stayed 4, the selftest went RED, nobody noticed). That is maintenance-by-
# enumeration: a magic number lies by default, and a chronically-RED guard can no longer
# distinguish "someone added a legit site" from "someone added a SILENT park" — the exact
# thing this guard exists to catch. The structural invariant is: EVERY line that applies
# gate:needs-human has a `mail send "$AUTHOR"` (or, post-ga-409f4, the branch-author-aware
# `mail send "$NOTIFY_AUTHOR"` — same durable-mail-to-a-real-identity property, just no
# longer the bead-assignee-derived variable) within the same escalation block (measured
# window: the site→mail distance is 13–20 lines across all current sites, so 40 is safe).
# A future Nth site WITH its mail passes untouched; a SILENT site fails, naming its line.
# (This subsumes the old 4→5→6 hand-bumped count, incl. ga-y43lq's fix of the ga-tgwq
# escalate-dirty-worktree site — the bijection scan finds that site's mail automatically,
# no count to bump. It also self-updates for sites added by unrelated work, e.g. ga-lxz5w's
# sibling-branch-race site — if such a site is itself missing its author-mail, this guard
# names its line instead of staying silently green.)
NEEDS_HUMAN_SITES=$(grep -nE 'label add[[:space:]]+"\$BEAD_ID"[[:space:]]+"gate:needs-human"' "$GATE" \
  | grep -v 'gate:needs-human:' | cut -d: -f1)
_bij_ok=1; _bij_bad_line=""
for _site in $NEEDS_HUMAN_SITES; do
  if ! sed -n "${_site},$((_site + 40))p" "$GATE" | grep -Eq 'mail send "\$(AUTHOR|NOTIFY_AUTHOR)"'; then
    _bij_ok=0; _bij_bad_line="$_site"; break
  fi
done
_n_sites=$(printf '%s\n' "$NEEDS_HUMAN_SITES" | grep -c .)
if [ "$_bij_ok" = 1 ] && [ "$_n_sites" -ge 1 ]; then
  ok "every gate:needs-human site ($_n_sites) has an adjacent AUTHOR mail (ga-huaxo bijection, no magic count)"
else
  bad "gate:needs-human site at line $_bij_bad_line has NO AUTHOR mail within 40 lines — a SILENT park (ga-u4yi/ga-huaxo)"
fi
grep -Eq 'mail send "\$(AUTHOR|NOTIFY_AUTHOR)"' "$GATE" \
  && ok "gate escalates to the AUTHOR, not just Mayor" \
  || bad "gate still only mails Mayor — author has no durable needs-human signal (ga-u4yi regression)"
# The cap-exhaustion author-mail MUST live inside the SAME once-only idempotency
# guard as the existing Mayor mail, or a bead already needs-human before this
# code path re-triggers (defensively) would re-mail the author every time.
CAP_MAIL_BLOCK="$(awk '/Escalate EXACTLY once/{f=1} f{print} f&&/^      fi[[:space:]]*$/{exit}' "$GATE")"
printf '%s\n' "$CAP_MAIL_BLOCK" | grep -Eq 'mail send "\$(AUTHOR|NOTIFY_AUTHOR)"' \
  && ok "cap-exhaustion author-mail is inside the escalate-exactly-once guard" \
  || bad "cap-exhaustion author-mail is OUTSIDE the once-only guard — would spam on re-entry"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

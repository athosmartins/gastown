#!/usr/bin/env bash
# gate-dispatcher-label-fallback.selftest.sh (ga-9oxah)
#
# Proves the label-fallback fix: a /gate-done-style marker whose DESCRIPTION
# carries no branch:/bead_id:/rig: routing block (e.g. oracle-wa's shape —
# routing stamped as LABELS: branch:<val>, source-bead:<val>, bead-rig:<val>,
# with a human-prose description instead) must still resolve BRANCH/BEAD_ID/
# RIG from those labels, instead of resolving empty and erroring downstream
# (unresolvable rig) — the mechanism behind the gate-stall Athos hit on
# 2026-07-17 (14+ markers churning error, only rare correctly-formatted
# markers merged; gate-recovery-watchdog kept re-queuing the rest forever).
#
# Strategy: extract the LIVE label-fallback block verbatim from the
# dispatcher (between sentinel comments) and execute it under the SAME
# `set -euo pipefail` the dispatcher uses, against fixture MARKER JSON +
# pre-resolved BRANCH/BEAD_ID/RIG (as Step 2's extract() calls would have
# left them), so this test cannot silently diverge from shipped code.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER"; exit 1; }

echo "== gate-dispatcher-label-fallback.selftest (ga-9oxah) =="

# ── Genuine live extraction (not a hand-copied function) ─────────────────────
FALLBACK_BLOCK="$(sed -n '/# SELFTEST-EXTRACT label-fallback: BEGIN/,/# SELFTEST-EXTRACT label-fallback: END/p' "$DISPATCHER")"
if [ -z "$FALLBACK_BLOCK" ]; then
  echo "FATAL: could not locate 'label-fallback' sentinel block in $DISPATCHER"
  echo "  (expected '# SELFTEST-EXTRACT label-fallback: BEGIN' / '...: END' markers"
  echo "   around the branch/bead_id/rig label-fallback — fix not present yet?)"
  exit 1
fi
ok "located live label-fallback block via sentinel extraction"

# run_fallback <marker_json> <branch_in> <bead_id_in> <rig_in>
# Executes the live block under the dispatcher's own `set -euo pipefail`,
# with MARKER/BRANCH/BEAD_ID/RIG set as Step 2's extract() calls would have
# left them, capturing whatever it logs plus a final RESULT| line.
run_fallback() {
  local marker="$1" branch_in="$2" bead_id_in="$3" rig_in="$4"
  MARKER="$marker" BRANCH_IN="$branch_in" BEAD_ID_IN="$bead_id_in" RIG_IN="$rig_in" \
  bash -c '
    set -euo pipefail
    log() { echo "LOG: $*"; }
    MARKER="$MARKER"
    BRANCH="$BRANCH_IN"
    BEAD_ID="$BEAD_ID_IN"
    RIG="$RIG_IN"
    '"$FALLBACK_BLOCK"'
    echo "RESULT|branch=${BRANCH}|bead_id=${BEAD_ID}|rig=${RIG}"
  ' 2>&1
}

echo "── (1) oracle-wa shape: routing ONLY in labels, description is human prose ──"
MARKER1='{"id":"ga-reyxh","description":"Response-processing audit found a real lead stranded because of a cursor race.","labels":["bead-rig:whatsapp_automation","branch:crew/oracle/ga-j1po8","gate-status:queued","source-bead:ga-j1po8","type:quality-gate-marker"]}'
OUT1=$(run_fallback "$MARKER1" "" "" ""); RC1=$?
if [ "$RC1" -eq 0 ]; then ok "survives under set -euo pipefail (the exact ga-7zjs1 abort class)"; else bad "aborted under set -e (rc=$RC1); output: $OUT1"; fi
case "$OUT1" in
  *"RESULT|branch=crew/oracle/ga-j1po8|bead_id=ga-j1po8|rig=whatsapp_automation"*)
    ok "resolves branch+bead_id+rig from labels when description has no routing block";;
  *) bad "did not resolve all three fields from labels; got: '$OUT1'";;
esac
case "$OUT1" in
  *"resolved from label"*) ok "logs that fallback fired (operator visibility)";;
  *) bad "silent fallback — no log line; got: '$OUT1'";;
esac

echo "── (2) CRITICAL non-regression: canonical marker, routing already in description ──"
# Labels deliberately carry NO branch:/source-bead:/bead-rig: — proves the
# block is a true no-op (never even needs to read labels) once nothing is
# missing, so /gate-done's normal markers are completely unaffected.
MARKER2='{"id":"ga-abcd","description":"branch: fix/ga-abcd\nbead_id: ga-abcd\nrig: gascity","labels":["ctx:ready","exec:auto"]}'
OUT2=$(run_fallback "$MARKER2" "fix/ga-abcd" "ga-abcd" "gascity")
case "$OUT2" in
  "RESULT|branch=fix/ga-abcd|bead_id=ga-abcd|rig=gascity")
    ok "canonical marker's description-resolved fields pass through unchanged, no log noise";;
  *) bad "canonical marker's fields were altered or logged unexpectedly; got: '$OUT2'";;
esac

echo "── (3) partial fallback: description has bead_id, labels supply branch+rig ──"
MARKER3='{"id":"ga-partial","description":"bead_id: ga-partial\nsome human note","labels":["branch:crew/oracle/ga-partial","bead-rig:gascity"]}'
OUT3=$(run_fallback "$MARKER3" "" "ga-partial" "")
case "$OUT3" in
  *"RESULT|branch=crew/oracle/ga-partial|bead_id=ga-partial|rig=gascity"*)
    ok "partial fallback fills only the missing fields, leaves description-resolved bead_id untouched";;
  *) bad "partial fallback did not resolve as expected; got: '$OUT3'";;
esac

echo "── (4) no signal anywhere: stays empty, does not crash (real dispatcher's own required-field guard handles the rest) ──"
MARKER4='{"id":"ga-nothing","description":"totally empty marker, no routing at all","labels":["gate-status:queued"]}'
OUT4=$(run_fallback "$MARKER4" "" "" ""); RC4=$?
if [ "$RC4" -eq 0 ]; then ok "completes without error when neither description nor labels have routing"; else bad "aborted (rc=$RC4) on a fully-unrouted marker; output: $OUT4"; fi
case "$OUT4" in
  *"RESULT|branch=|bead_id=|rig="*) ok "stays empty (not a false match) when no routing signal exists anywhere";;
  *) bad "unexpected non-empty resolution with no signal; got: '$OUT4'";;
esac

echo "── (5) label prefix boundary: 'source-bead-type:' must not match 'source-bead:' ──"
MARKER5='{"id":"ga-boundary","description":"no routing here","labels":["source-bead-type:epic"]}'
OUT5=$(run_fallback "$MARKER5" "" "" "")
case "$OUT5" in
  *"bead_id=epic"*) bad "prefix boundary broke — matched 'source-bead-type:' as if it were 'source-bead:'; got: '$OUT5'";;
  *) ok "prefix boundary holds — 'source-bead-type:' does not false-match 'source-bead:'";;
esac

echo "── (6) drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'SELFTEST-EXTRACT label-fallback: BEGIN' "$DISPATCHER" \
  && ok "extraction sentinel present (prevents future silent copy-drift)" || bad "extraction sentinel missing"
grep -q 'label_fallback()' "$DISPATCHER" \
  && ok "label_fallback() helper present" || bad "label_fallback() helper missing"
grep -q 'label_fallback "branch:"' "$DISPATCHER" \
  && ok "branch fallback wired up" || bad "branch fallback missing"
grep -q 'label_fallback "source-bead:"' "$DISPATCHER" \
  && ok "bead_id fallback wired up (source-bead: label)" || bad "bead_id fallback missing"
grep -q 'label_fallback "bead-rig:"' "$DISPATCHER" \
  && ok "rig fallback wired up (bead-rig: label)" || bad "rig fallback missing"
if grep -Eq 'grep -E "\^\$1" \| head -1 \| sed "s/\^\$1//" \|\| true' "$DISPATCHER"; then
  ok "label_fallback() retains '|| true' terminator (ga-7zjs1-class drift guard)"
else
  bad "label_fallback() is missing its '|| true' terminator — set -e abort on a no-match label can recur"
fi
# Placement guard: fallback must sit AFTER all extract() calls (needs
# BRANCH/BEAD_ID/RIG already attempted) and BEFORE the Step 2 extraction log
# line (so the log reflects post-fallback resolved values).
RIG_EXTRACT_LINE=$(grep -n '^RIG=\$(extract "rig")' "$DISPATCHER" | head -1 | cut -d: -f1)
FALLBACK_LINE=$(grep -n 'SELFTEST-EXTRACT label-fallback: BEGIN' "$DISPATCHER" | head -1 | cut -d: -f1)
EXTRACT_LOG_LINE=$(grep -n 'log "  branch=\$BRANCH  bead_id=\$BEAD_ID  rig=' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$RIG_EXTRACT_LINE" ] && [ -n "$FALLBACK_LINE" ] && [ -n "$EXTRACT_LOG_LINE" ] \
   && [ "$RIG_EXTRACT_LINE" -lt "$FALLBACK_LINE" ] && [ "$FALLBACK_LINE" -lt "$EXTRACT_LOG_LINE" ]; then
  ok "fallback sits between Step 2 extract() calls and the extraction log line"
else
  bad "fallback placement drifted (rig_extract=$RIG_EXTRACT_LINE fallback=$FALLBACK_LINE extract_log=$EXTRACT_LOG_LINE)"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

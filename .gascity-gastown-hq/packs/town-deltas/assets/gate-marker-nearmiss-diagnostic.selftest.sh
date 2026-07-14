#!/usr/bin/env bash
# gate-marker-nearmiss-diagnostic.selftest.sh (ga-kefn / ga-o9fs)
#
# Proves the schema-drift diagnostic: when a marker is hand-created OUTSIDE
# /gate-done (e.g. the Mayor re-submitting after a gate infra failure), its
# description has zero schema enforcement against the canonical field set
# (branch/bead_id/author/base_commit/rig/bead_rig — commands/gate-done.md
# Step 3). ga-wisp-5zki27 used `bead:` instead of `bead_id:` and omitted
# `rig:`/`bead_rig:` entirely; BEAD_ID/RIG silently resolved empty and Step 4's
# eventual abort ("Cannot resolve rig path for rig='' (bead=)") read like a
# rig-registry problem — nothing pointed at the real defect. Diagnosing it
# took ~2 hours of reading dispatcher source and cross-referencing raw log
# timestamps, while 3 separate dispatches landed on the already-complete fix
# and could only stand down.
#
# The fix does NOT accept aliases (that would just treat this incident's one
# typo and leave the next hand-typed marker's novel typo equally silent — see
# ga-kefn's "(c) is lowest-leverage" note). It only names a REAL near-miss
# line for a field that came back empty, so it must stay silent for crew
# markers that legitimately omit `rig:` by design (ga-7zjs1) — that's the
# critical non-regression case this test guards.
#
# Strategy: extract the LIVE near-miss-diagnostic block verbatim from the
# dispatcher (between sentinel comments) and execute it in a subshell against
# fixture descriptions, so this test cannot silently diverge from shipped code.
#
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✓ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER"; exit 1; }

echo "== gate-marker-nearmiss-diagnostic.selftest (ga-kefn) =="

# ── Genuine live extraction (not a hand-copied function) ─────────────────────
DIAG_BLOCK="$(sed -n '/# SELFTEST-EXTRACT near-miss-diagnostic: BEGIN/,/# SELFTEST-EXTRACT near-miss-diagnostic: END/p' "$DISPATCHER")"
if [ -z "$DIAG_BLOCK" ]; then
  echo "FATAL: could not locate 'near-miss-diagnostic' sentinel block in $DISPATCHER"
  echo "  (expected '# SELFTEST-EXTRACT near-miss-diagnostic: BEGIN' / '...: END' markers"
  echo "   around warn_near_miss_field() — diagnostic not present yet?)"
  exit 1
fi
ok "located live near-miss-diagnostic block via sentinel extraction"

# run_diag <desc> <bead_id_resolved> <rig_resolved>
# Executes the live block with DESC/BEAD_ID/RIG set as the dispatcher would
# have them at the Step 2b call site, capturing whatever it logs.
run_diag() {
  local desc="$1" bead_id="$2" rig="$3"
  DESC="$desc" BEAD_ID_IN="$bead_id" RIG_IN="$rig" \
  bash -c '
    set -uo pipefail
    log() { echo "LOG: $*"; }
    DESC="$DESC"
    BEAD_ID="$BEAD_ID_IN"
    RIG="$RIG_IN"
    '"$DIAG_BLOCK"'
  ' 2>/dev/null
}

echo "── (1) real incident shape: 'bead:' instead of 'bead_id:', rig/bead_rig fully absent ──"
DESC1="branch: crew/mayor/resubmit
bead: ga-pyzo
author: mayor
base_commit: 715d8fd047f66e28d2f5bc147b9ed3d163a20c41"
OUT1=$(run_diag "$DESC1" "" "")
case "$OUT1" in
  *"'bead_id:' is empty but description has near-miss line 'bead: ga-pyzo'"*)
    ok "fires the bead_id near-miss warning on the exact ga-wisp-5zki27 incident shape";;
  *) bad "did not warn on 'bead:' near-miss; got: '$OUT1'";;
esac
case "$OUT1" in
  *"'rig:' is empty but"*) bad "false-fired a rig warning when rig is genuinely absent (no near-miss line at all); got: '$OUT1'";;
  *)                       ok "stays silent on rig — genuinely absent, not a near-miss (no bead_rig/rig_name/etc line either)";;
esac

echo "── (2) well-formed canonical marker: both fields resolved, no warnings at all ──"
DESC2="branch: fix/ga-abcd
bead_id: ga-abcd
author: gastown.dog-1
base_commit: 715d8fd047f66e28d2f5bc147b9ed3d163a20c41
rig: gascity
bead_rig: gascity"
OUT2=$(run_diag "$DESC2" "ga-abcd" "gascity")
if [ -z "$OUT2" ]; then
  ok "silent on a fully-resolved canonical marker (no false positives)"
else
  bad "unexpected output on a well-formed marker: '$OUT2'"
fi

echo "── (3) CRITICAL non-regression: crew marker legitimately omits rig: (ga-7zjs1) ──"
DESC3="branch: crew/digo/wa-v0td
bead_id: wa-v0td
base_commit: 715d8fd047f66e28d2f5bc147b9ed3d163a20c41"
OUT3=$(run_diag "$DESC3" "wa-v0td" "")
if [ -z "$OUT3" ]; then
  ok "stays silent on an intentionally rig-less crew marker — must not regress ga-7zjs1's design"
else
  bad "false-fired on a normal rig-less crew marker (would spam every crew submission): '$OUT3'"
fi

echo "── (4) hand-typed marker used 'bead_rig:' but omitted 'rig:' ──"
DESC4="branch: crew/mayor/resubmit
bead_id: ga-pyzo
bead_rig: gascity"
OUT4=$(run_diag "$DESC4" "ga-pyzo" "")
case "$OUT4" in
  *"'rig:' is empty but description has near-miss line 'bead_rig: gascity'"*)
    ok "fires the rig near-miss warning when only 'bead_rig:' is present";;
  *) bad "did not warn on 'bead_rig:' near-miss; got: '$OUT4'";;
esac

echo "── (5) drift-guards: shipped dispatcher matches tested logic ──"
grep -q 'SELFTEST-EXTRACT near-miss-diagnostic: BEGIN' "$DISPATCHER" \
  && ok "extraction sentinel present (prevents future silent copy-drift)" || bad "extraction sentinel missing"
grep -q 'warn_near_miss_field' "$DISPATCHER" \
  && ok "warn_near_miss_field function present" || bad "warn_near_miss_field function missing"
grep -q 'warn_near_miss_field "bead_id"' "$DISPATCHER" \
  && ok "bead_id near-miss check wired up" || bad "bead_id near-miss check missing"
grep -q 'warn_near_miss_field "rig"' "$DISPATCHER" \
  && ok "rig near-miss check wired up" || bad "rig near-miss check missing"
# Placement guard: the diagnostic must sit AFTER the Step 2 extraction log line
# (needs BEAD_ID/RIG already resolved) and BEFORE Step 3 (author re-derivation
# doesn't depend on it, but this keeps the diagnostic tied to Step 2 semantics).
EXTRACT_LOG_LINE=$(grep -n 'log "  branch=\$BRANCH  bead_id=\$BEAD_ID  rig=' "$DISPATCHER" | head -1 | cut -d: -f1)
DIAG_LINE=$(grep -n 'warn_near_miss_field "bead_id"' "$DISPATCHER" | head -1 | cut -d: -f1)
STEP3_LINE=$(grep -n '# ── Step 3: Re-derive author authoritatively' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$EXTRACT_LOG_LINE" ] && [ -n "$DIAG_LINE" ] && [ -n "$STEP3_LINE" ] \
   && [ "$EXTRACT_LOG_LINE" -lt "$DIAG_LINE" ] && [ "$DIAG_LINE" -lt "$STEP3_LINE" ]; then
  ok "diagnostic sits between Step 2 extraction and Step 3 author re-derivation"
else
  bad "diagnostic placement drifted (extract_log=$EXTRACT_LOG_LINE diag=$DIAG_LINE step3=$STEP3_LINE)"
fi

echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" = 0 ]; then echo "  RESULT: PASS"; exit 0; else echo "  RESULT: FAIL"; exit 1; fi

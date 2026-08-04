#!/usr/bin/env bash
# gate-eqjo-reviewing-terminal-clear.selftest.sh (ga-n2cpe)
#
# Bug ga-n2cpe: a gate-reviewer that drains before ever ACKing (the
# stale_async_start race — reviewer dies during its own startup, before
# picking up review work) leaves the source bead's gate:reviewing label
# stuck forever. Every OTHER terminal path inside gate_finalize_run() clears
# gate:reviewing on PASS, FAIL, fix-cap-exhaustion, and every auto-circuit-
# break (all tagged wa-qq33j) — but the two "infra re-queue" paths (ga-eqjo:
# every pending reviewer confirmed dead; ga-x3nmz: Claude 5h quota exhausted
# mid-review) requeue the marker back to gate-status:queued WITHOUT clearing
# gate:reviewing. With the label still set, the marker's source bead reads as
# "already under review" on every subsequent dispatcher sweep, so the
# dispatcher's own FIFO/tier marker selection keeps re-picking this same
# stuck-oldest marker every sweep (it carries none of the demotion labels
# ga-q3ig2's two-tier selection sinks to the back) and can't make progress —
# starving the ENTIRE queue behind it, not just this one marker. Only a
# separate periodic watchdog (gate-recovery-watchdog.py FIX4,
# ORPHAN_MARKER_MIN_MINUTES=15) eventually noticed and cleared it externally
# — observed live 2026-07-25 on wa-c3qsr, three separate times in one day
# (16:27, 17:31, 19:21), the last one after the marker sat stuck 39 minutes.
#
# THE FIX: both requeue blocks now also clear gate:reviewing on $BEAD_ID (via
# $BEAD_CITY, the cross-rig store resolver — wa-re77/ga-qw7y6), on the SAME
# sweep the infra condition is confirmed, matching the wa-qq33j convention
# already used at every other terminal path in this function.
#
# Strategy (this file's constraint, inherited from every other test in this
# codebase that touches gate_finalize_run/Phase C): these code paths live in
# the "live sweep" zone AFTER quality-gate-dispatcher.sh's
# GATE_DISPATCHER_LIB_ONLY early-return, so they cannot be unit-tested by
# lib-only sourcing + direct invocation (see gate-async-verdict-pipeline.
# selftest.sh's header for the same constraint on gate_finalize_run itself).
# This is therefore a structural/positional drift-guard (grep + line-number
# ordering against the real source), not a functional execution test — same
# convention as gate-async-verdict-pipeline.selftest.sh and
# gate-head-of-line-skip.selftest.sh. A MUTATION TEST (section 5) proves the
# guards are load-bearing, not vacuous.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

echo "== gate-eqjo-reviewing-terminal-clear.selftest (ga-n2cpe) =="

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# Fixed substring (not a regex) — the target text is full of literal '$'
# characters ($BEAD_CITY, $BEAD_ID), which are ERE end-of-string anchors when
# they land mid-pattern. Matching via awk's index() (plain substring search)
# sidesteps that entirely instead of fighting quoting across sh/grep/awk.
CLEAR_NEEDLE='bd -C "$BEAD_CITY" label remove "$BEAD_ID" "gate:reviewing"'

# check_block_has_clear <file> <label> <if-anchor-regex>
#   Finds <if-anchor-regex>'s line, then the FIRST bare `return 0` at 2-4 space
#   indent after it (that block's own terminal return), then asserts the
#   gate:reviewing clear line falls strictly between the two — i.e. INSIDE
#   this specific block, not merely somewhere in the file.
check_block_has_clear() {
  local file="$1" label="$2" if_anchor="$3"
  local if_line clear_line return_line
  if_line=$(grep -nE "$if_anchor" "$file" | head -1 | cut -d: -f1)
  if [ -z "$if_line" ]; then
    bad "$label: could not locate the block's anchor ('$if_anchor' not found) — dispatcher shape changed?"
    return
  fi
  return_line=$(awk -v start="$if_line" 'NR>start && /^[[:space:]]{2,4}return 0$/{print NR; exit}' "$file")
  if [ -z "$return_line" ]; then
    bad "$label: could not locate this block's own terminal 'return 0' after line $if_line"
    return
  fi
  clear_line=$(awk -v start="$if_line" -v end="$return_line" -v needle="$CLEAR_NEEDLE" \
    'NR>start && NR<end && index($0, needle)>0 {print NR; exit}' "$file")
  if [ -n "$clear_line" ]; then
    ok "$label: gate:reviewing clear present inside the block (anchor L$if_line, clear L$clear_line, return L$return_line)"
  else
    bad "$label: NO gate:reviewing clear found between the block's anchor (L$if_line) and its own return (L$return_line) — ga-n2cpe regression"
  fi
}

echo "── 1. ga-eqjo dead-reviewer requeue block clears gate:reviewing ──"
check_block_has_clear "$DISPATCHER" "ga-eqjo (dead-reviewer)" \
  'REQUEUE_REASON:-quota\}" = "dead-reviewer"'

echo "── 2. ga-x3nmz quota-stop requeue block clears gate:reviewing ──"
check_block_has_clear "$DISPATCHER" "ga-x3nmz (quota-stop)" \
  '_eta=\$\(quota_reset_eta\)'

echo "── 3. Both new clears use the cross-rig-resolved BEAD_CITY, not GC_CITY ──"
N2CPE_CLEAR_LINES=$(grep -F -n "$CLEAR_NEEDLE" "$DISPATCHER" | grep -c "ga-n2cpe")
if [ "$N2CPE_CLEAR_LINES" = "2" ]; then
  ok "exactly 2 ga-n2cpe-tagged gate:reviewing clears present, both via \$BEAD_CITY"
else
  bad "expected exactly 2 ga-n2cpe-tagged gate:reviewing clears, found $N2CPE_CLEAR_LINES"
fi

echo "── 4. Regression guard: pre-existing wa-qq33j clear sites are untouched ──"
# ga-k2wjn added a 12th site: the new delivery:partial hold branch also
# leaves the PASS-reviewing state, so it clears gate:reviewing too (tagged
# wa-qq33j, same convention as its close/story-handoff siblings) — 10
# wa-qq33j-tagged (9 pre-existing + 1 from ga-k2wjn) + 2 ga-n2cpe-tagged = 12.
TOTAL_CLEARS=$(grep -cF "$CLEAR_NEEDLE" "$DISPATCHER")
if [ "$TOTAL_CLEARS" = "12" ]; then
  ok "total gate:reviewing clear call sites = 12 (9 pre-existing + 1 ga-k2wjn + 2 ga-n2cpe) — got $TOTAL_CLEARS"
else
  bad "expected 12 total gate:reviewing clear call sites (9 pre-existing + 1 ga-k2wjn + 2 ga-n2cpe), got $TOTAL_CLEARS — either a pre-existing site was lost or the new count drifted"
fi

echo "── 5. MUTATION TEST: stripping the ga-n2cpe clears must flip sections 1-2 to RED ──"
MUTANT="$(mktemp "${TMPDIR:-/tmp}/gate-n2cpe-mutant-XXXXXX.sh" 2>/dev/null || echo "/tmp/gate-n2cpe-mutant-$$.sh")"
cleanup_mutant() { rm -f "$MUTANT"; }
trap cleanup_mutant EXIT
cp "$DISPATCHER" "$MUTANT"
MUTATE_OK=0
python3 - "$MUTANT" <<'PYEOF' && MUTATE_OK=1
import re
import sys
path = sys.argv[1]
with open(path) as f:
    lines = f.readlines()
out = []
skip_next_clear = False
removed = 0
for line in lines:
    if 'ga-n2cpe' in line and 'label remove "$BEAD_ID" "gate:reviewing"' in line:
        removed += 1
        continue  # drop the clear line itself
    out.append(line)
if removed != 2:
    print("EXPECTED_TO_REMOVE_2_GOT_%d" % removed, file=sys.stderr)
    sys.exit(1)
with open(path, 'w') as f:
    f.writelines(out)
PYEOF
if [ "$MUTATE_OK" != "1" ]; then
  bad "mutation-test: could not construct the mutant (expected exactly 2 ga-n2cpe clear lines to remove) — INCONCLUSIVE, treat as FAIL"
else
  MUT_TOTAL=2
  # Re-run the real checks against the mutant, capturing pass/fail independently
  # of the outer PASS/FAIL counters (temporary local counters).
  _MUT_PASS=0; _MUT_FAIL=0
  ok()  { _MUT_PASS=$((_MUT_PASS+1)); }
  bad() { _MUT_FAIL=$((_MUT_FAIL+1)); }
  check_block_has_clear "$MUTANT" "ga-eqjo (dead-reviewer) [MUTANT]" 'REQUEUE_REASON:-quota\}" = "dead-reviewer"'
  check_block_has_clear "$MUTANT" "ga-x3nmz (quota-stop) [MUTANT]" '_eta=\$\(quota_reset_eta\)'
  # restore real ok/bad for the rest of the script
  ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
  bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
  if [ "$_MUT_FAIL" = "2" ] && [ "$_MUT_PASS" = "0" ]; then
    ok "mutant (ga-n2cpe clears stripped): both block checks flip to RED ($_MUT_FAIL/$MUT_TOTAL) — proves sections 1-2 are load-bearing"
  else
    bad "mutant did NOT flip both checks to RED (pass=$_MUT_PASS fail=$_MUT_FAIL of $MUT_TOTAL) — sections 1-2 may be vacuous against this exact regression"
  fi
  if bash -n "$MUTANT" 2>/dev/null; then
    ok "mutant remains syntactically valid bash (the guard catches BEHAVIOR, not a parse error)"
  else
    bad "mutant is not valid bash — the mutation itself is malformed, weakening this proof"
  fi
fi

echo "── 6. Sanity: the live dispatcher itself is still valid bash after the fix ──"
if bash -n "$DISPATCHER" 2>/dev/null; then
  ok "quality-gate-dispatcher.sh parses cleanly (bash -n)"
else
  bad "quality-gate-dispatcher.sh FAILED bash -n after the ga-n2cpe fix"
fi

echo ""
echo "── RESULTS: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ] || exit 1

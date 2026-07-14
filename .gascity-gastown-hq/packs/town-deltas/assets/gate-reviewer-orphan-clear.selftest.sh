#!/usr/bin/env bash
# gate-reviewer-orphan-clear.selftest.sh — Prove the ga-flfo age/creating guard
# in scripts/gate-reviewer-orphan-clear.sh in isolation, with NO live Dolt/gc/
# launchd/tmux.
#
# Bug ga-flfo: gate-reviewer-orphan-clear.sh (the gt-bewtm stopgap janitor) had
# NO age floor and read STATE from the wrong `gc session list` column ($4 =
# REASON, not STATE). Its StartInterval=189s sweep ran INSIDE every reviewer's
# real ~210s deferred-start boot window, so `gc session peek` reporting
# "session not found" for a not-yet-booted session was indistinguishable from
# a genuinely-dead one — the sweep closed reviewers mid-boot (observed live:
# w4x6vg reaped 32s after spawn, uraowb at 48s).
#
# The fix adds a pure orphan_clear_decision() gate: state=active is kept
# (working), state=creating is kept (not born yet — NEVER a death signal,
# regardless of age), and anything younger than MIN_AGE_SECS (default 360s,
# comfortably above the observed ~210s worst case) is kept. Only a session
# that clears ALL of those AND fails a live `gc session peek` gets closed.
#
# This harness SOURCES the REAL script (GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY)
# to unit-test its REAL pure decision function, proves the two NB-VERIFY-ARTIFACT
# senses (booting/young survives; genuinely-old-and-dead still reaped), runs an
# explicit MUTATION TEST proving the guard is load-bearing (remove it → the same
# scenario that must survive in sense #1 would instead be reaped), and finally
# DRIFT-GUARDS the live script so a future refactor that drops the guard, the
# --json switch, or the state fetch fails loudly. Exit 0 iff every assertion
# holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# gate-reviewer-orphan-clear.sh lives in scripts/, three levels up from
# packs/town-deltas/assets/ where this selftest lives.
SCRIPT="$SELF_DIR/../../../scripts/gate-reviewer-orphan-clear.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

[ -f "$SCRIPT" ] || { echo "FATAL: script not found at $SCRIPT"; exit 1; }

# ── Load the REAL helpers from the script (source-only = no live sweep) ──────
GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY=1 source "$SCRIPT" \
  || { echo "FATAL: could not source gate-reviewer-orphan-clear.sh in source-only mode"; exit 1; }

type orphan_clear_decision >/dev/null 2>&1 || { echo "FATAL: orphan_clear_decision not defined"; exit 1; }
type session_age_secs      >/dev/null 2>&1 || { echo "FATAL: session_age_secs not defined"; exit 1; }

MIN_AGE=360

echo "── 1. orphan_clear_decision — active/creating are NEVER reap candidates ──"
eq "active, age 0 → keep_active"           "$(orphan_clear_decision active 0 "$MIN_AGE")"      "keep_active"
eq "active, age huge → keep_active"        "$(orphan_clear_decision active 999999 "$MIN_AGE")" "keep_active"
eq "(ga-flfo NB-VERIFY sense 1) creating, age 30s → keep_creating (NOT reaped/dead)" \
   "$(orphan_clear_decision creating 30 "$MIN_AGE")" "keep_creating"
eq "creating, age huge → STILL keep_creating (never a death signal by itself)" \
   "$(orphan_clear_decision creating 999999 "$MIN_AGE")" "keep_creating"

echo "── 2. orphan_clear_decision — the age floor protects any OTHER state too ──"
eq "asleep, age 0 → keep_young"                  "$(orphan_clear_decision asleep 0 "$MIN_AGE")"   "keep_young"
eq "asleep, age just under MIN_AGE → keep_young" "$(orphan_clear_decision asleep 359 "$MIN_AGE")" "keep_young"
eq "asleep, age EXACTLY MIN_AGE → eligible (>=)" "$(orphan_clear_decision asleep 360 "$MIN_AGE")" "eligible"

echo "── 3. (ga-flfo NB-VERIFY sense 2) genuinely old + non-active/creating → eligible (still reaped by the peek stage) ──"
eq "asleep, age well over MIN_AGE → eligible"    "$(orphan_clear_decision asleep 600 "$MIN_AGE")"  "eligible"
eq "dormant, age well over MIN_AGE → eligible"   "$(orphan_clear_decision dormant 600 "$MIN_AGE")" "eligible"
eq "drained, age well over MIN_AGE → eligible"   "$(orphan_clear_decision drained 600 "$MIN_AGE")" "eligible"

echo "── 4. fail-SAFE on unknown/garbage age (never reap on incomplete info) ──"
eq "empty age → keep_age_unknown"          "$(orphan_clear_decision asleep '' "$MIN_AGE")"    "keep_age_unknown"
eq "non-numeric age → keep_age_unknown"    "$(orphan_clear_decision asleep 'NaN' "$MIN_AGE")"  "keep_age_unknown"

echo "── 5. session_age_secs — canonical timestamp math ──"
eq "created 360s before now → age 360"     "$(session_age_secs '2020-01-01T00:00:00Z' 1577837160)" "360"
eq "created NOW → age 0"                   "$(session_age_secs '2020-01-01T00:00:00Z' 1577836800)" "0"
eq "empty created_at → unknown (empty)"    "$(session_age_secs '' 1577837160)" ""
eq "unparseable created_at → unknown"      "$(session_age_secs 'not-a-date' 1577837160)" ""
eq "±HH:MM offset parses (matches gc's live -03:00 form)" \
   "$(session_age_secs '2020-01-01T00:00:00-03:00' 1577847960)" "360"

echo "── 6. MUTATION TEST — the age/creating guard is load-bearing ──"
# Reconstruct EXACTLY the pre-fix decision (no age floor, no creating check —
# the literal original script's logic: only 'active' was ever skipped, and
# even that fast-path read the WRONG list column in practice, so in the real
# pre-fix script not even 'active' reliably held — this mirror is deliberately
# the BEST CASE for the old code, to make the mutation test conservative).
# If sense-1's assertion above (creating, 30s → keep_creating) is to mean
# anything, this pre-fix function MUST make the OPPOSITE call for the SAME
# input — proving assertion (1) actually exercises the guard rather than
# passing vacuously (i.e. even a reverted fix would still pass it).
orphan_clear_decision_PRE_FIX() {
  local state="$1"
  case "$state" in
    active) echo "keep_active"; return 0 ;;
  esac
  echo "eligible"   # pre-fix: everything else goes straight to the peek probe
}
_mutant_verdict="$(orphan_clear_decision_PRE_FIX creating 30)"
eq "pre-fix mirror (no guard) reads a 30s-old booting session as 'eligible' (would be peeked+closed)" \
   "$_mutant_verdict" "eligible"
_fixed_verdict="$(orphan_clear_decision creating 30 "$MIN_AGE")"
[ "$_fixed_verdict" != "$_mutant_verdict" ] \
  && ok "FIXED ($_fixed_verdict) vs PRE-FIX ($_mutant_verdict) verdicts diverge on the sense-1 scenario — the guard is the actual cause, not a coincidence" \
  || bad "FIXED and PRE-FIX agree — the guard changed nothing (sense-1 assertion would pass even with the fix reverted)"

echo "── 7. drift-guard: the live script still has the ga-flfo guard wired in ──"
has "$SCRIPT" 'orphan_clear_decision\(\)'                     "pure decision function is defined"
has "$SCRIPT" 'creating\) echo "keep_creating"'               "state=creating is excluded from reap eligibility"
has "$SCRIPT" 'GATE_REVIEWER_ORPHAN_CLEAR_MIN_AGE_SECS:-360'  "MIN_AGE_SECS defaults to 360s (>= observed ~210s boot)"
has "$SCRIPT" 'session list --json'                           "sweep uses --json (fixes the wrong-column state bug)"
has "$SCRIPT" 'template.lower\(\)'                            "template filter preserves gate-reviewer + refino-gate-reviewer scope"
has "$SCRIPT" 'decision=\$\(orphan_clear_decision'            "sweep loop actually calls the decision function (not a leftover unused def)"
has "$SCRIPT" 'gc session peek "\$sid"'                       "eligible sessions still go through a live peek before closing (defense in depth)"
has "$SCRIPT" 'GATE_REVIEWER_ORPHAN_CLEAR_SOURCE_ONLY'        "script is sourceable in source-only mode (this selftest depends on it)"

echo ""
echo "──────────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  SELFTEST FAILED"
  exit 1
fi
echo "  SELFTEST OK"
exit 0

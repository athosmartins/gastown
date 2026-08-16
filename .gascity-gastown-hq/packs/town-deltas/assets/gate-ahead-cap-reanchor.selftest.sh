#!/usr/bin/env bash
# gate-ahead-cap-reanchor.selftest.sh — Prove the ga-hzhn6k ahead-cap
# re-anchor decision in isolation, with NO live Dolt/gc/launchd.
#
# ga-hzhn6k: when a branch is out of the auto-rebase envelope SOLELY because
# it has more own commits than GATE_REBASE_AHEAD_MAX (REBASE_AHEAD_CAP_ONLY=1
# — set only when merge-tree already proved the merge clean AND neither the
# behind-cap nor the unclean-tree guard also fired), the dispatcher must
# re-anchor via merge instead of recording the policy skip as a conflict.
# The old behavior recorded that skip as HAS_CONFLICT=1/CONFLICT_KIND=
# transient every sweep forever (measured: wa-campanha-diaria, ahead=29,
# 7 cycles, gate:rebase-fail-count and gate:exiled-tier5 both climbed to 7,
# zero reviews) since the branch's own commit count never shrinks on its
# own — a policy decision ("I chose not to attempt") recorded as if it were
# a failed attempt.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL pure decision function (gate_ahead_envelope_action),
# same convention as quality-gate-circuit-break.selftest.sh's coverage of the
# sibling gate_behind_envelope_action / gate_circuit_break_check functions.
#
# Exit 0 iff every assertion holds.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL helpers from the dispatcher (lib-only = no live run) ────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

# ga-hzhn6k: this FATAL is both the drift guard AND the "fails on the
# previous HEAD" half of AC5 in one check — gate_ahead_envelope_action did
# not exist before this bead, so sourcing an unpatched dispatcher leaves it
# undefined and this whole selftest fails closed here instead of silently
# skipping every assertion below.
type gate_ahead_envelope_action >/dev/null 2>&1 \
  || { echo "FATAL: gate_ahead_envelope_action not defined by dispatcher (ga-hzhn6k missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. ahead_cap_only=1 → merge_reanchor (the eternal-loop fix) ──────────────
# This is the exact production shape (wa-campanha-diaria, ahead=29,
# GATE_REBASE_AHEAD_MAX=10 default): REBASE_AHEAD_CAP_ONLY only ever reaches
# 1 after merge-tree has ALREADY proven the branch merges into main with
# zero conflicts, so there is nothing left for a rebase to safely resolve
# that a merge doesn't resolve identically.
echo "── 1. ahead_cap_only=1 → merge_reanchor (re-anchor instead of exiling) ──"
eq "ahead_cap_only=1 → merge_reanchor (matches the wa-campanha-diaria shape)" \
  "$(gate_ahead_envelope_action "1")" \
  "merge_reanchor"

# ── 2. ahead_cap_only=0 → skip (pre-existing behavior for every OTHER reason,
# e.g. behind-cap-exceeded or unclean rig .git dir — untouched by this bead,
# ga-6dp9 already gives behind-cap-exceeded its own correct, permanent
# circuit-break path independent of this decision) ──────────────────────────
echo "── 2. ahead_cap_only=0 → skip (behind-cap/unclean-tree paths untouched) ──"
eq "ahead_cap_only=0 → skip" \
  "$(gate_ahead_envelope_action "0")" \
  "skip"

# ── 3. Fail-safe defaults: empty/garbage input never accidentally merges ─────
echo "── 3. fail-safe: empty/garbage input → skip, never a silent merge ──"
eq "ahead_cap_only empty (default arg) → skip" \
  "$(gate_ahead_envelope_action "")" \
  "skip"
eq "ahead_cap_only garbage → skip (fail-safe: only literal 1 triggers a merge)" \
  "$(gate_ahead_envelope_action "yes")" \
  "skip"
eq "ahead_cap_only=2 (out of range) → skip (fail-safe: only literal 1 triggers a merge)" \
  "$(gate_ahead_envelope_action "2")" \
  "skip"

# ── 4. Cross-check: gate_circuit_break_check already exempts merge_clean=1 ──
# ga-agtqm's merge_clean bypass (see quality-gate-circuit-break.selftest.sh
# §2c/3b) is the OTHER half of why this bead's fix is safe: a branch this
# path now actively re-anchors was ALREADY exempt from ever being
# permanently circuit-broken on commit count alone — that's exactly why the
# pre-fix branch could loop forever instead of either resolving or erroring
# out. Re-asserted here so a reader of this file sees both halves of the
# fix agree without cross-referencing the sibling selftest.
echo "── 4. cross-check: gate_circuit_break_check already exempts merge_clean=1 ──"
type gate_circuit_break_check >/dev/null 2>&1 \
  || { echo "FATAL: gate_circuit_break_check not defined (ga-acb missing?)"; exit 1; }
eq "ahead=29, dead author, merge_clean=1 → ok (never circuit-broken; now also actively re-anchored)" \
  "$(gate_circuit_break_check "ahead_dead" "29" "0" "0" "3" "10" "1")" \
  "ok"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — gate-ahead-cap-reanchor selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — gate-ahead-cap-reanchor selftest"
  exit 1
fi

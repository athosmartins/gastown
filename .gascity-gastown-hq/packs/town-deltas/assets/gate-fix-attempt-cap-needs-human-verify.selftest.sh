#!/usr/bin/env bash
# gate-fix-attempt-cap-needs-human-verify.selftest.sh — Prove the ga-55syh
# circuit-breaker verification fix in isolation, with NO live Dolt/gc.
#
# ga-55syh (P0): quality-gate-dispatcher.sh's fix-attempt-cap block used to
# `bd label add ... gate:needs-human -q 2>/dev/null || true` and immediately
# compose a bead comment + Mayor mail + author mail all asserting "Auto-retry
# is now DISABLED (label gate:needs-human)" — from the ATTEMPT to write,
# never a verified read. On wa-klhib (a bead that autonomously charges a
# real credit card, no human in the loop) the label never actually landed,
# and TWO independent sources (an escalation mail and the builder's own bead
# comment) both announced it had.
#
# This harness sources the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL functions (gate_apply_needs_human, gate_needs_human_clause)
# against a stubbed `bd` whose label-add can be forced to silently no-op —
# exactly the shape a transient Dolt hiccup produces, matching this file's
# own `-q 2>/dev/null || true` fail-open posture everywhere else.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ok $*"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
contains() { case "$2" in *"$3"*) ok "$1"; ;; *) bad "$1 — expected to contain [$3], got [$2]"; ;; esac; }
not_contains() { case "$2" in *"$3"*) bad "$1 — expected NOT to contain [$3], got [$2]"; ;; *) ok "$1"; ;; esac; }

# ── Load the REAL functions (lib-only = no live sweep) ──────────────────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
for fn in gate_apply_needs_human gate_needs_human_clause; do
  type "$fn" >/dev/null 2>&1 || { echo "FATAL: $fn not defined by dispatcher (ga-55syh missing?)"; exit 1; }
done

T="$(mktemp -d 2>/dev/null || mktemp -d -t ga55syh)"
trap 'rm -rf "$T" 2>/dev/null || true' EXIT
FAKE_LABELS_FILE="$T/labels.txt"
FAKE_LABEL_ADD_FAIL_COUNT=0

# Stub `bd` — simulates a single bead's label set via a state file, with a
# controllable failure mode for `label add` (silently no-ops N times before
# it starts actually recording the label, mirroring a transient write
# failure that the real `-q 2>/dev/null || true` would swallow identically).
bd() {
  case "$3" in
    label)
      if [ "$4" = "add" ]; then
        if [ "$FAKE_LABEL_ADD_FAIL_COUNT" -gt 0 ]; then
          FAKE_LABEL_ADD_FAIL_COUNT=$((FAKE_LABEL_ADD_FAIL_COUNT - 1))
        else
          echo "$6" >> "$FAKE_LABELS_FILE"
        fi
      fi
      return 0
      ;;
    show)
      local labels_json
      labels_json=$(sort -u "$FAKE_LABELS_FILE" 2>/dev/null | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
      printf '[{"id":"fake-bead","labels":%s}]\n' "$labels_json"
      return 0
      ;;
  esac
  return 0
}

# ── 1. label-add succeeds immediately → armed on first try ─────────────────
echo "── 1. label-add succeeds immediately ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=0
eq "immediate success → armed" \
   "$(gate_apply_needs_human "$T" "fake-bead" "")" "armed"

# ── 2. label-add silently no-ops once, succeeds on retry → armed ───────────
# This is the load-bearing proof: gate_apply_needs_human must actually RETRY
# and RE-READ, not just call label add once and assume.
echo "── 2. label-add fails once (silent no-op), succeeds on retry ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=1
eq "one transient miss, then success → armed (retry worked)" \
   "$(gate_apply_needs_human "$T" "fake-bead" "")" "armed"

# ── 3. label-add ALWAYS silently no-ops → failed, not armed ─────────────────
# The exact shape ga-55syh is about: the write never lands, and the function
# must say so honestly instead of assuming success from having called it.
echo "── 3. label-add persistently fails (never lands) ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=99
eq "persistent failure → failed (not silently claimed armed)" \
   "$(gate_apply_needs_human "$T" "fake-bead" "")" "failed"

# ── 4. sub-label failing alone does NOT block armed (it's classification, ──
#      not the safety mechanism — the bare label is what Pilot/guard key on)
echo "── 4. sub-label is best-effort, does not gate the armed verdict ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=0
RESULT=$(gate_apply_needs_human "$T" "fake-bead" "gate:needs-human:technical")
eq "bare label present with sub-label also applied → armed" "$RESULT" "armed"
grep -q "gate:needs-human:technical" "$FAKE_LABELS_FILE" && ok "sub-label was also recorded" || bad "sub-label missing from fake store"

# ── 5. gate_needs_human_clause: the message text itself, per verdict ───────
echo "── 5. gate_needs_human_clause branches the message wording, not just a footnote ──"
ARMED_MSG="$(gate_needs_human_clause "armed")"
FAILED_MSG="$(gate_needs_human_clause "failed")"
contains     "armed message announces the circuit-breaker is on"     "$ARMED_MSG"  "DISABLED"
not_contains "armed message does NOT also claim it could not arm"    "$ARMED_MSG"  "COULD NOT ARM"
contains     "failed message says COULD NOT ARM, with emphasis"      "$FAILED_MSG" "COULD NOT ARM THE CIRCUIT-BREAKER"
not_contains "failed message does NOT claim auto-retry is disabled"  "$FAILED_MSG" "is now DISABLED"
contains     "failed message says the bead remains unprotected"      "$FAILED_MSG" "NO protection"

# ── 6. drift-guard: the fix-attempt-cap site actually calls these, not the ──
#      old fire-and-forget pattern
echo "── 6. drift-guard: fix-attempt-cap call site wiring ──"
grep -qF '_NH_STATUS=$(gate_apply_needs_human "$BEAD_CITY" "$BEAD_ID" "gate:needs-human:technical")' "$DISPATCHER" \
  && ok "fix-attempt-cap block calls gate_apply_needs_human" \
  || bad "fix-attempt-cap block does not call gate_apply_needs_human — REGRESSION risk"
grep -qF '$(gate_needs_human_clause "$_NH_STATUS")' "$DISPATCHER" \
  && ok "downstream messages route through gate_needs_human_clause" \
  || bad "downstream messages do not use gate_needs_human_clause — REGRESSION risk"
if grep -qF 'Auto-retry is now DISABLED (label gate:needs-human); the Pilot will not re-dispatch it.' "$DISPATCHER"; then
  bad "old hardcoded unconditional success text is still present — the assert-from-intent bug is back"
else
  ok "old hardcoded unconditional success text removed from the fix-attempt-cap block"
fi

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

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
FAKE_SHOW_FAIL=0

# Stub `bd` — simulates a single bead's label set via a state file, with a
# controllable failure mode for `label add` (silently no-ops N times before
# it starts actually recording the label, mirroring a transient write
# failure that the real `-q 2>/dev/null || true` would swallow identically),
# and a controllable failure mode for `show` (ga-h48cm: FAKE_SHOW_FAIL=1
# makes every read attempt error out — no stdout, exit 1 — simulating a bd
# outage/timeout distinct from "read succeeded, no label found").
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
      if [ "$FAKE_SHOW_FAIL" = "1" ]; then
        return 1
      fi
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

# ── 7. ga-h48cm defect 2: a READ ERROR must not collapse into "failed" ─────
# The exact shape the bug describes: bd/jq errors on every attempt. Before
# the fix this indistinguishably produced labels="" (via the old
# `... || echo ""` on the pipe) → same as "read succeeded, no label" →
# "failed". It must now report the distinct "unverified" state instead.
echo "── 7. bd show persistently errors (read failure) → unverified, NOT failed ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=0; FAKE_SHOW_FAIL=1
eq "read error on every try → unverified (not silently promoted to failed)" \
   "$(gate_apply_needs_human "$T" "fake-bead" "")" "unverified"
FAKE_SHOW_FAIL=0

# ── 8. ga-h48cm defect 1: real backoff, not a back-to-back reread ──────────
# Proves the pause is REAL wall-clock time, not a no-op — using $SECONDS
# (bash's auto-incrementing elapsed-time counter) so the assertion doesn't
# depend on parsing `date` output. GATE_NEEDS_HUMAN_VERIFY_BACKOFF_SECS
# defaults to 1s and is sourced from the live dispatcher (not redeclared
# here), so this exercises the REAL default, not a test-only override.
echo "── 8. backoff: write→reread pause is real elapsed time, not immediate ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=0; FAKE_SHOW_FAIL=0
_t0=$SECONDS
gate_apply_needs_human "$T" "fake-bead" "" >/dev/null
_elapsed=$((SECONDS - _t0))
if [ "$_elapsed" -ge 1 ]; then
  ok "immediate-success path still paused for backoff before its verify read (elapsed=${_elapsed}s)"
else
  bad "immediate-success path returned in ${_elapsed}s — no real backoff between write and reread"
fi

# ── 9. ga-h48cm defect 3: the verdict must survive the REAL call-site shape ─
# All 9 real call sites consume this helper as a bare/guarded command-
# substitution ASSIGNMENT (`_NH_STATUS=$(gate_apply_needs_human ...)`), never
# as a tested condition or a function argument. Under `set -e`, a failing
# command substitution used to populate a plain assignment aborts the shell
# immediately — confirmed by direct reproduction against the PRE-FIX
# function (see ga-h48cm's defect-3 note in the dispatcher header comment).
# This harness reproduces that EXACT shape in a child `set -e` subshell so a
# regression here is caught even though every OTHER assertion in this file
# calls gate_apply_needs_human as a function argument (a shape that never
# triggered the crash in the first place — the gap that let this ship).
echo "── 9. crash-safety: the real \$(...)  assignment shape survives set -e for every verdict ──"
: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=99; FAKE_SHOW_FAIL=0
_crash_rc=0
_crash_out=$(
  set -euo pipefail
  echo "before"
  _NH_STATUS=$(gate_apply_needs_human "$T" "fake-bead" "")
  echo "after:$_NH_STATUS"
) 2>&1 || _crash_rc=$?
FAKE_LABEL_ADD_FAIL_COUNT=0
contains "verified-absent (\"failed\") verdict: real call-site shape does not abort the shell" \
  "$_crash_out" "after:failed"
eq "verified-absent (\"failed\") verdict: subshell exit code" "$_crash_rc" "0"

: > "$FAKE_LABELS_FILE"; FAKE_LABEL_ADD_FAIL_COUNT=0; FAKE_SHOW_FAIL=1
_crash_rc=0
_crash_out=$(
  set -euo pipefail
  echo "before"
  _NH_STATUS=$(gate_apply_needs_human "$T" "fake-bead" "")
  echo "after:$_NH_STATUS"
) 2>&1 || _crash_rc=$?
FAKE_SHOW_FAIL=0
contains "unverified verdict: real call-site shape does not abort the shell" \
  "$_crash_out" "after:unverified"
eq "unverified verdict: subshell exit code" "$_crash_rc" "0"

# ── 10. gate_needs_human_clause: the "unverified" message says COULD NOT ──
#       VERIFY, never "did not arm" — ga-h48cm AC2's exact requirement
echo "── 10. gate_needs_human_clause: unverified message is honest, not alarmist ──"
UNVERIFIED_MSG="$(gate_needs_human_clause "unverified")"
contains     "unverified message says COULD NOT VERIFY"            "$UNVERIFIED_MSG" "COULD NOT VERIFY"
not_contains "unverified message does NOT claim it failed to apply" "$UNVERIFIED_MSG" "FAILED to apply"
not_contains "unverified message does NOT claim armed/disabled"     "$UNVERIFIED_MSG" "is now DISABLED"
not_contains "unverified message does NOT claim confirmed absence"  "$UNVERIFIED_MSG" "COULD NOT ARM THE CIRCUIT-BREAKER"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

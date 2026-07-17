#!/usr/bin/env bash
# gate-verdict-assignee-fallback.selftest.sh — Prove the ga-mo7q fix: a verdict
# bead whose --assignee write silently failed is still found by the reviewer's
# poll, via a metadata.gc.session_name fallback, and the residual failure mode
# is made loud instead of silent.
#
# Bug ga-mo7q: quality-gate-dispatcher.sh creates a verdict bead (type:
# quality-gate-verdict), then SEPARATELY assigns it to the reviewer's session
# name via assign_verdict_bead_verified() (ga-vdurb). That second write can
# fail — MEASURED live: 200 verdict beads examined, 60 (30%) had no assignee.
# The reviewer's MANDATED startup poll (`gc bd list --assignee=$GC_SESSION_NAME
# -l type:quality-gate-verdict`) then returns [], indistinguishable from "no
# work for me" — the reviewer waits out its ~2min window and exits silently as
# "unused reviewer", documented as the #1 cause of gates stalling to the 45min
# timeout. Verified directly against two real beads: ga-676t (assignee set
# correctly) and ga-yhxx (assignee empty, but metadata.gc.session_name
# correctly present) — the SAME code produces both outcomes; gc.session_name
# is the more reliable channel in both.
#
# Fix (4 parts, see ga-mo7q comments in the affected files):
#  (a) assign_verdict_bead_verified(): more retries + backoff, and a durable
#      `verdict:assignee-degraded` label on final failure (quality-gate-
#      dispatcher.sh + the analogous refino_assign_verdict_bead_verified() in
#      refino-gate-dispatcher.sh, which had the SAME bug with even less
#      hardening — a single unverified write, no retry at all).
#  (b) the reviewer's poll (gate-reviewer + refino-gate-reviewer prompt
#      templates) falls back to `--metadata-field gc.session_name=...` when
#      the --assignee query is empty.
#  (c) the reviewer's final "unused reviewer" exit is no longer silent — it
#      states explicitly that an empty poll does not distinguish "no work"
#      from "a query blind to a real bead".
#  (d) gate-health-monitor.py gets an independent, bead-content-level
#      detector: any type:quality-gate-verdict + verdict:pending bead with no
#      assignee for > ASSIGNEE_GAP_STUCK_SEC is flagged [VERDICT-ASSIGNEE-GAP].
#
# This harness mirrors the PURE two-step lookup decision (assignee-match OR
# session_name-fallback-match) for direct unit-testing against the two real
# bead shapes above — same technique gate-verdict-status-unreadable.selftest.sh
# uses for vb_status_action. No live bd/Dolt calls (consistent with this
# directory's convention of testing decision logic, not live infra). Section 3
# drift-guards the real shipped files so a regression that quietly drops the
# wiring (not just deletes a function) fails this check too.
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$SELF_DIR/quality-gate-dispatcher.sh"
REFINO_GATE="$SELF_DIR/refino-gate-dispatcher.sh"
REVIEWER_TPL="$SELF_DIR/../../../agents/gate-reviewer/prompt.template.md"
REFINO_REVIEWER_TPL="$SELF_DIR/../../../agents/refino-gate-reviewer/prompt.template.md"
HEALTH_MON="$SELF_DIR/../../../scripts/gate-health-monitor.py"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }
has() { if grep -qE "$2" "$1"; then ok "$3"; else bad "$3 — pattern not found: $2"; fi; }

# ── The PURE two-step lookup decision a reviewer's poll makes: does THIS
# verdict bead belong to me? Mirrors "primary (assignee) then fallback
# (session_name)" exactly as specified in the fixed prompt templates.
verdict_bead_lookup() {
  local _assignee="$1" _session_name_meta="$2" _my_session="$3" _fallback_enabled="$4"
  if [ "$_assignee" = "$_my_session" ] && [ -n "$_my_session" ]; then
    echo "found:assignee"; return 0
  fi
  if [ "$_fallback_enabled" = "1" ] && [ "$_session_name_meta" = "$_my_session" ] && [ -n "$_my_session" ]; then
    echo "found:fallback"; return 0
  fi
  echo "not-found"; return 1
}

echo "── 1. verdict_bead_lookup on the two REAL bead shapes measured live (ga-mo7q) ──"
# ga-676t: assignee correctly set — healthy case, must be found via the
# primary (assignee) path regardless of whether the fallback is enabled.
eq "ga-676t-shaped (assignee OK), fallback ON"  \
   "$(verdict_bead_lookup 'gate-reviewer-adhoc-4c5d8f2342' 'gate-reviewer-adhoc-4c5d8f2342' 'gate-reviewer-adhoc-4c5d8f2342' 1)" \
   "found:assignee"
eq "ga-676t-shaped (assignee OK), fallback OFF (must not depend on it)" \
   "$(verdict_bead_lookup 'gate-reviewer-adhoc-4c5d8f2342' 'gate-reviewer-adhoc-4c5d8f2342' 'gate-reviewer-adhoc-4c5d8f2342' 0)" \
   "found:assignee"

# ga-yhxx: assignee EMPTY (the bug), metadata.gc.session_name correctly
# present — this is the exact incident. With the fix (fallback ON), found.
eq "ga-yhxx-shaped (assignee EMPTY, session_name OK), fallback ON → FOUND (ga-mo7q fixed)" \
   "$(verdict_bead_lookup '' 'gate-reviewer-adhoc-89a41e4f83' 'gate-reviewer-adhoc-89a41e4f83' 1)" \
   "found:fallback"

echo
echo "── 2. mutation: neutralizing the fallback reproduces the ORIGINAL ga-mo7q bug ──"
# Same ga-yhxx-shaped input, fallback OFF (simulates the pre-fix reviewer
# poll, i.e. --assignee only). This MUST go to not-found — that miss, timed
# out over ~2min, IS the "unused reviewer" bug. If this ever comes back found
# without the fallback flag, the mirror function itself no longer matches the
# real bug it's supposed to model.
neutralized="$(verdict_bead_lookup '' 'gate-reviewer-adhoc-89a41e4f83' 'gate-reviewer-adhoc-89a41e4f83' 0)"
if [ "$neutralized" = "not-found" ]; then
  ok "fallback OFF reproduces the original bug (not-found) — proves the fallback is what fixes it"
else
  bad "fallback OFF unexpectedly found the bead ($neutralized) — mirror function does not match the real bug"
fi

# No-work case: both assignee and session_name empty/mismatched. Must NEVER
# hallucinate a match regardless of fallback state (a false positive would be
# worse than the original bug — a reviewer acting on a bead that isn't its own).
eq "no work exists, fallback ON → still not-found (no false match)" \
   "$(verdict_bead_lookup '' '' 'gate-reviewer-adhoc-zzzz' 1)" "not-found"

echo
echo "── 3. DRIFT-GUARD: the real shipped files actually wire this fix in ──"

has "$GATE" 'for _try in 1 2 3 4' \
    "quality-gate-dispatcher.sh: assign_verdict_bead_verified retries 4x, not 2x"
has "$GATE" 'verdict:assignee-degraded' \
    "quality-gate-dispatcher.sh: labels the bead on final assign failure"

has "$REFINO_GATE" 'refino_assign_verdict_bead_verified' \
    "refino-gate-dispatcher.sh: has its own verified-assign helper (was a single unverified write)"
has "$REFINO_GATE" 'verdict:assignee-degraded' \
    "refino-gate-dispatcher.sh: labels the bead on final assign failure too"
# Structural proof the helper actually REPLACED the old bare call at the spawn
# call site (not just added alongside it, dead).
REFINO_CALL_COUNT=$(grep -cE 'refino_assign_verdict_bead_verified "\$VERDICT_BEAD_ID"' "$REFINO_GATE" 2>/dev/null)
if [ "${REFINO_CALL_COUNT:-0}" -ge 1 ]; then
  ok "refino-gate-dispatcher.sh: spawn path calls the new verified-assign helper (count=$REFINO_CALL_COUNT)"
else
  bad "refino-gate-dispatcher.sh: spawn path does not call the new helper — ga-mo7q regression"
fi

has "$REVIEWER_TPL" 'metadata-field "gc\.session_name=\$GC_SESSION_NAME"' \
    "gate-reviewer prompt template: poll has the session_name fallback query"
has "$REVIEWER_TPL" 'UNUSED REVIEWER \(ga-mo7q\)' \
    "gate-reviewer prompt template: unused-reviewer exit is no longer silent"

has "$REFINO_REVIEWER_TPL" 'metadata-field "gc\.session_name=\$GC_SESSION_NAME"' \
    "refino-gate-reviewer prompt template: poll has the session_name fallback query"
has "$REFINO_REVIEWER_TPL" 'UNUSED REVIEWER \(ga-mo7q\)' \
    "refino-gate-reviewer prompt template: unused-reviewer exit is no longer silent"

has "$HEALTH_MON" 'def verdict_beads_missing_assignee' \
    "gate-health-monitor.py: has the empty-assignee query function"
has "$HEALTH_MON" 'ASSIGNEE_GAP_STUCK_SEC' \
    "gate-health-monitor.py: has the >60s threshold constant"
has "$HEALTH_MON" 'VERDICT-ASSIGNEE-GAP' \
    "gate-health-monitor.py: emits the new alert type"
# Mutation-style: the detector must be WIRED into the main loop (called), not
# merely defined-but-dead. Occurrence count must be >= 2 (def + >=1 call).
HM_CALL_COUNT=$(grep -c 'verdict_beads_missing_assignee' "$HEALTH_MON" 2>/dev/null)
if [ "${HM_CALL_COUNT:-0}" -ge 2 ]; then
  ok "gate-health-monitor.py: detector function is actually CALLED, not dead code (refs=$HM_CALL_COUNT)"
else
  bad "gate-health-monitor.py: detector function defined but never called (refs=${HM_CALL_COUNT:-0})"
fi

echo
echo "── 4. VERDICT-ASSIGNEE-GAP: query failure must not corrupt first-seen tracking (gate feedback, attempt 1) ──"
# Gate feedback on attempt 1: verdict_beads_missing_assignee() returned []
# both on a genuinely-resolved gap AND on a query failure (non-zero exit,
# timeout, exception) — indistinguishable, same as the ga-mo7q bug itself.
# The caller's prune step then read a failure as "this bead's gap resolved",
# silently resetting first-seen and understating true staleness (a transient
# hiccup) or suppressing the alert entirely (a sustained outage spanning the
# bead's whole stuck lifetime). Fix: return None on failure, distinct from []
# on genuine-empty; caller skips BOTH alert-check and prune when None —
# mirrors this file's own dolt_responsive() guard pattern (used at the
# IDLE-REVIEWER and GATE-NOMERGE checks) applied to this detector too.
#
# Pure mirror of ONE tracking cycle for a single bead's first-seen value
# (plain scalars + echo, same technique as verdict_bead_lookup() above — no
# bash4+ arrays/namerefs; this directory's selftests target bash 3.2).
# $1 = current first_seen ("" = not yet tracked), $2 = this cycle's result
# for the bead (FAIL | present | absent), $3 = now. Echoes the new first_seen.
cycle_fixed() {
  local fs="$1" result="$2" now="$3"
  case "$result" in
    FAIL)    echo "$fs" ;;                                  # the fix: untouched
    present) if [ -z "$fs" ]; then echo "$now"; else echo "$fs"; fi ;;
    absent)  echo "" ;;                                     # genuinely resolved
  esac
}
# Mutation: the ORIGINAL bug — FAIL treated exactly like genuine-empty.
cycle_buggy() {
  local fs="$1" result="$2" now="$3"
  case "$result" in
    FAIL)    echo "" ;;                                     # bug: silently pruned
    present) if [ -z "$fs" ]; then echo "$now"; else echo "$fs"; fi ;;
    absent)  echo "" ;;
  esac
}

# Scenario (matches the gate reviewer's "one isolated hiccup" trace): bead
# first seen at t=0, query fails at t=60 (transient Dolt hiccup), bead still
# genuinely missing its assignee and found again at t=120.
fs=""
fs="$(cycle_fixed "$fs" present 0)"
fs="$(cycle_fixed "$fs" FAIL 60)"
fs="$(cycle_fixed "$fs" present 120)"
eq "fixed: first-seen survives a mid-sequence query failure" "$fs" "0"

fs=""
fs="$(cycle_buggy "$fs" present 0)"
fs="$(cycle_buggy "$fs" FAIL 60)"
fs="$(cycle_buggy "$fs" present 120)"
if [ "$fs" = "120" ]; then
  ok "mutation: neutralizing the None-check reproduces the bug (first-seen reset 0→120, understates true staleness by 120s) — proves the guard is what fixes it"
else
  bad "mutation: buggy variant did not reproduce the reset (got $fs) — mirror no longer matches the real bug"
fi

# Sustained outage: FAIL every cycle while the bead stays stuck. The fixed
# variant must never manufacture a fresh first-seen from a failure — this is
# the worst-case tail this detector exists to catch (a query blind for the
# bead's entire stuck lifetime must still alert once it recovers, dating from
# the true onset, not the recovery poll).
fs=""
fs="$(cycle_fixed "$fs" present 0)"
fs="$(cycle_fixed "$fs" FAIL 60)"
fs="$(cycle_fixed "$fs" FAIL 120)"
fs="$(cycle_fixed "$fs" FAIL 180)"
eq "fixed: first-seen survives a sustained multi-cycle outage" "$fs" "0"

echo
echo "── 5. DRIFT-GUARD: the None-vs-empty fix is actually wired into the real file ──"
has "$HEALTH_MON" 'return None' \
    "gate-health-monitor.py: verdict_beads_missing_assignee has a None (failure) return path"
has "$HEALTH_MON" 'if gap_ids is not None' \
    "gate-health-monitor.py: caller checks for the None sentinel before alert-check/prune"

echo
echo "── RESULT: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# pilot-dispatcher.pool-direct-claim-guard.selftest.sh — unit tests for
# _ownership_guard_should_refuse's signal (c), specifically its handling of
# an EPHEMERAL POOL identity (gastown.dog-N, wa-worker-N, ps-worker-N) that
# has DIRECTLY claimed the candidate bead itself (ga-uirg32, 4th recurrence).
#
# Bug ga-uirg32: signal (c) ("EXTERNAL ACTIVE CLAIM") re-reads the candidate
# bead fresh and, if status=in_progress with a non-empty assignee, refuses
# dispatch as a competing external claim — UNLESS the assignee matches
# gastown.dog|gastown.dog-*|wa-worker|wa-worker-*|ps-worker|ps-worker-*, in
# which case it unconditionally no-ops (falls through as if unowned),
# regardless of whether that specific pool instance is actually alive right
# now. The comment justifying the exemption ("not a pool worker / dog /
# self") assumed dogs/workers only ever claim the SLING wrapper Pilot mints
# for them, never the target bead directly — but Gas Town's own routed-pool
# self-serve probe (Step 1c: `gc bd update <id> --claim`) can and does claim
# a target bead directly whenever `gc.routed_to=<pool>` metadata lands on it
# (e.g. via pilot-missing-route-watchdog), with no sling involved at all.
#
# Confirmed live 2026-09-24 (gascity/HQ): gastown.dog-2 claimed ga-ormexj
# directly (status=in_progress, assignee=gastown.dog-2) at 23:56:01Z; Pilot's
# fresh re-read at ~23:58:45Z (2m44s later, well past any in-process
# TOCTOU window) saw exactly that state and STILL dispatched a second
# builder onto it, because the pool-prefix case arm treats any
# gastown.dog-* assignee as "not real ownership" unconditionally. This is
# the 4th recorded recurrence of this dispatch shape (ga-nb8eo, ga-w5l8p,
# and this one all share it; ga-hpc1x/ga-6psx5 fixed distinct mechanisms).
#
# The fix: the pool-prefix case arm now checks LIVENESS of that SPECIFIC
# assignee via the same _session_is_active_owner primitive signal (b)
# already uses for named crews (same _DEADWORKER_OK fail-open discipline) —
# refuse only when the pool instance is confirmed live; a dead/orphaned pool
# claim still falls through unchanged to the existing reclaim paths
# (ga-e5yw2/ga-v3z4z), and an untrustworthy roster never blocks a dispatch
# it cannot verify.
#
# Extracted-function harness (mirrors the OWN-GUARD scenario in
# pilot-dispatcher.selftest.sh): stub bd/branch/gate/session-liveness,
# assert the reason _ownership_guard_should_refuse returns.
#
# Exit 0 iff every scenario behaves as expected.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

if [ ! -f "$DISPATCHER" ]; then
  echo "FATAL: dispatcher not found at $DISPATCHER" >&2
  exit 2
fi

# ── Extract the guard + its branch-signal dependency chain verbatim ─────────
_PDC_OG_FN="$(awk '/^_ownership_guard_should_refuse\(\)/{f=1} /^_beadid_matched_crew_branch_ref\(\)/{f=1} /^_beadid_branch_signal\(\)/{f=1} f{print} f&&/^}$/{f=0}' "$DISPATCHER")"
if [ -z "$_PDC_OG_FN" ]; then
  echo "FATAL: _ownership_guard_should_refuse() not found in $DISPATCHER (extraction pattern drifted?)" >&2
  exit 2
fi

# _pdc_og <bead_id> <candidate_json> <live: 0|1> <roster_ok: 0|1> — runs the
# real guard in a subshell with the fresh-read bead fixed to OG_BEAD_JSON,
# signals (a)/(d)/(e) neutralized (dedicated scenarios exist elsewhere for
# each), and _session_is_active_owner's verdict for THIS scenario controlled
# directly — the exact dimension this bug's fix introduces.
_pdc_og() {
  local _bid="$1" _json="$2" _live="$3" _roster_ok="$4"
  (
    eval "$_PDC_OG_FN"
    SELF_BEAD_ID=""
    _DEADWORKER_OK="$_roster_ok"
    bd() { case "$*" in *" show "*) printf '%s' "${OG_BEAD_JSON:-}" ;; *) : ;; esac; }
    _beadid_has_crew_branch() { return 1; }              # signal (a) does not fire
    _beadid_branch_signal()   { return 1; }              # signal (a)'s real entry point — does not fire
    _beadid_has_active_gate_artifact() { return 1; }     # signal (d): no active gate artifact
    _beadid_mentioned_in_attached_session() { return 1; } # signal (e): no attached-session mention
    if [ "$_live" = "1" ]; then
      _session_is_active_owner() { return 0; }
    else
      _session_is_active_owner() { return 1; }
    fi
    _ownership_guard_should_refuse "$_bid" "$_json" "ignored-db"
  )
}

_PDC_SNAPSHOT='{"id":"ga-x","assignee":"","status":"open","labels":[]}'

echo "Scenario POOL-DIRECT-CLAIM (ga-uirg32): guard refuses a LIVE pool-identity direct claim, allows a dead one"

# (1) REGRESSION CASE — status=in_progress, assignee=gastown.dog-2, NO pilot
# fingerprint, pool instance CONFIRMED LIVE, trustworthy roster → REFUSE.
# Pre-fix this returned "" (allowed) unconditionally — the exact bug.
OG_BEAD_JSON='[{"id":"ga-ormexj","status":"in_progress","assignee":"gastown.dog-2","labels":[],"metadata":{}}]'
_PDC_R1="$(_pdc_og "ga-ormexj" "$_PDC_SNAPSHOT" 1 1)"
[ "$_PDC_R1" = "external-claim:gastown.dog-2@in_progress" ] \
  && ok "PDC(1): live gastown.dog-2 direct claim REFUSED (reason: $_PDC_R1)" \
  || bad "PDC(1): live gastown.dog-2 direct claim NOT refused (got: '$_PDC_R1') — ga-uirg32 is back"

# (2) Same claim, but the pool instance is DEAD (session ended/idle-past-
# threshold) → allow, unchanged: the existing reclaim paths own a genuine
# orphan, this guard must never strand it.
OG_BEAD_JSON='[{"id":"ga-ormexj","status":"in_progress","assignee":"gastown.dog-2","labels":[],"metadata":{}}]'
_PDC_R2="$(_pdc_og "ga-ormexj" "$_PDC_SNAPSHOT" 0 1)"
[ -z "$_PDC_R2" ] \
  && ok "PDC(2): dead gastown.dog-2 claim allowed (orphan reclaim paths still own it)" \
  || bad "PDC(2): dead pool claim wrongly refused (got: '$_PDC_R2') — would strand ga-e5yw2/ga-v3z4z reclaim"

# (3) Same LIVE claim, but the session roster itself is untrustworthy
# (_DEADWORKER_OK=0) → allow, fail-open: never block on an unverifiable
# roster (same discipline signal (b) already documents).
OG_BEAD_JSON='[{"id":"ga-ormexj","status":"in_progress","assignee":"gastown.dog-2","labels":[],"metadata":{}}]'
_PDC_R3="$(_pdc_og "ga-ormexj" "$_PDC_SNAPSHOT" 1 0)"
[ -z "$_PDC_R3" ] \
  && ok "PDC(3): untrustworthy roster fails open (allowed) even though claim would be live" \
  || bad "PDC(3): untrustworthy-roster case wrongly refused (got: '$_PDC_R3') — roster read should never gate a block"

# (4) The fix must cover wa-worker-*/ps-worker-* the same as gastown.dog-*
# (the original exemption pattern already listed all three; the fix must
# not narrow it to dogs only).
OG_BEAD_JSON='[{"id":"wa-target","status":"in_progress","assignee":"wa-worker-3","labels":[],"metadata":{}}]'
_PDC_R4="$(_pdc_og "wa-target" '{"id":"wa-target","assignee":"","status":"open","labels":[]}' 1 1)"
[ "$_PDC_R4" = "external-claim:wa-worker-3@in_progress" ] \
  && ok "PDC(4): live wa-worker-3 direct claim REFUSED (reason: $_PDC_R4)" \
  || bad "PDC(4): live wa-worker-3 direct claim NOT refused (got: '$_PDC_R4')"

OG_BEAD_JSON='[{"id":"ps-target","status":"in_progress","assignee":"ps-worker-1","labels":[],"metadata":{}}]'
_PDC_R4B="$(_pdc_og "ps-target" '{"id":"ps-target","assignee":"","status":"open","labels":[]}' 1 1)"
[ "$_PDC_R4B" = "external-claim:ps-worker-1@in_progress" ] \
  && ok "PDC(4b): live ps-worker-1 direct claim REFUSED (reason: $_PDC_R4B)" \
  || bad "PDC(4b): live ps-worker-1 direct claim NOT refused (got: '$_PDC_R4B')"

# (5) NON-REGRESSION — a bead carrying Pilot's OWN dispatch fingerprint
# (pilot:dispatched) is owned by the NEVERSTARTED/ga-e5yw2/ga-v3z4z reclaim
# paths, not this guard's signal (c) at all (the whole in_progress+assignee
# check sits inside `if [ "$_has_pilot_fp" != "1" ]`). Even with a LIVE pool
# assignee, this must stay ALLOWED — the fix must not reach into the
# fingerprinted/reclaim-owned lifecycle.
OG_BEAD_JSON='[{"id":"ga-fp","status":"in_progress","assignee":"gastown.dog-4","labels":["pilot:dispatched"],"metadata":{"pilot.dispatched_at":"123"}}]'
_PDC_R5="$(_pdc_og "ga-fp" '{"id":"ga-fp","assignee":"","status":"open","labels":[]}' 1 1)"
[ -z "$_PDC_R5" ] \
  && ok "PDC(5): pilot-fingerprinted bead with live pool assignee stays allowed (reclaim owns it, unchanged)" \
  || bad "PDC(5): fingerprinted bead wrongly refused (got: '$_PDC_R5') — fix over-reached into reclaim-owned lifecycle"

# NOTE: SELF_BEAD_ID (live value: "ga-8c1", a BEAD id) is compared against
# $_asg (an ASSIGNEE — a session/agent identity like "gastown.dog-2"). Those
# two string shapes never collide in production (a bead id is never a valid
# assignee), so a scenario forcing $_asg == $SELF_BEAD_ID to also match a
# pool-prefix pattern would be testing an input combination that cannot
# occur live — deliberately not tested here.

# Structural: the pool-prefix case arm now consults liveness instead of a
# bare no-op — guards against a future edit silently reverting the fix.
# Scoped to the already-extracted function text (not a fresh whole-file
# scan): this exact pool-prefix case-arm pattern also appears verbatim in
# at least one other, unrelated function in this file
# (_pilot_pool_target_has_live_session and others), so a naive re-scan of
# $DISPATCHER risks anchoring on the wrong occurrence.
if printf '%s' "$_PDC_OG_FN" | grep -q '_DEADWORKER_OK:-0.*&& _session_is_active_owner "\$_asg"'; then
  ok "structural: pool-prefix case arm consults _session_is_active_owner (fail-open on roster) before allowing"
else
  bad "structural: pool-prefix case arm no longer consults liveness — ga-uirg32 regression risk"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "pilot-dispatcher.pool-direct-claim-guard.selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && { echo "SELFTEST PASS"; exit 0; }
echo "SELFTEST FAIL"
exit 1

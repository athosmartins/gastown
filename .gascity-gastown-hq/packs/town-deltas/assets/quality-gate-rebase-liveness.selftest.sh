#!/usr/bin/env bash
# quality-gate-rebase-liveness.selftest.sh — ga-6dp9 mutation test.
#
# Proves the fix for 3 composed bugs in the gate's rebase auto-retry path that
# together produced an INFINITE "attempt 1/3" loop whenever a worker died
# before /gate-done with main still advancing (root-caused from peter-wa
# ga-wisp-c4gx2y, manually unstuck 2026-07-16; observed recurring on ga-p2rb):
#
#   (1) The rebase-liveness check keyed "author alive?" off the source BEAD's
#       CURRENT assignee/owner, which can be reassigned to an unrelated
#       PM/babysitter long after the branch was pushed (a Mayor-crafted rescue
#       marker's bead owner, peter-wa, never touched the branch — the real,
#       already-dead author was an ephemeral wa-worker build). A live
#       NON-author session must never count as "the author is alive, wait."
#   (2) main only ever moves FORWARD, so branch-base-too-far-behind-main
#       (delta > GATE_REBASE_BEHIND_MAX) is a PERMANENT condition — it was
#       being treated as transient and re-queued, which can never self-heal.
#   (3) The gate:rebase-attempt:N label swap is fire-and-forget; an unverified
#       write and a silently-failed write produce the SAME observable state
#       (attempt stuck at its old value) — the exact
#       [[error-and-empty-must-not-produce-the-same-value]] conflation. The
#       3/3 escape hatch that exists specifically to escalate never fired.
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL pure decision functions — resolve_rebase_author(),
# gate_behind_envelope_action(), and gate_rebase_attempt_advanced() — with NO
# live Dolt/gc/launchd. author_is_alive("") is also exercised directly: it
# short-circuits on an empty author before any live IO (verified below), so it
# is safe to call from this harness.
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

for _fn in resolve_rebase_author gate_behind_envelope_action gate_rebase_attempt_advanced author_is_alive; do
  type "$_fn" >/dev/null 2>&1 \
    || { echo "FATAL: $_fn not defined by dispatcher (ga-6dp9 fix missing?)"; exit 1; }
done

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. resolve_rebase_author: branch/marker signals win over a stale bead-owner ─
# (bug 1) A bead-owner value (e.g. peter-wa) can NEVER even reach this
# function — its signature has no bead-owner parameter — which is the
# structural proof that it cannot leak through. These cases prove it picks
# the CORRECT branch-tied signal in priority order instead.
echo "── 1. resolve_rebase_author: branch-tied signals, never a bead-owner value ──"
eq "trusted gate.submitted_by present → wins outright (normal /gate-done flow)" \
  "$(resolve_rebase_author "oracle-wa" "crew/wa-worker/wa-aed6l" "")" \
  "oracle-wa"
eq "trusted absent, crew branch → branch crew segment (the REAL author of a rescued branch)" \
  "$(resolve_rebase_author "" "crew/wa-worker/wa-aed6l" "")" \
  "wa-worker"
eq "reproduces the live incident: crew segment is NEVER the unrelated bead owner peter-wa" \
  "$([ "$(resolve_rebase_author "" "crew/wa-worker/wa-aed6l" "")" != "peter-wa" ] && echo "excluded" || echo "leaked")" \
  "excluded"
eq "trusted absent, non-crew branch (dog fix/* convention), marker self-declared author → falls to marker author" \
  "$(resolve_rebase_author "" "fix/ga-6dp9-desc" "some-dog")" \
  "some-dog"
eq "trusted absent, crew branch takes priority over a marker author when both present" \
  "$(resolve_rebase_author "" "crew/oracle-wa/some-bead" "some-dog")" \
  "oracle-wa"
eq "nothing resolvable → empty (never guesses; conservative fail-safe)" \
  "$(resolve_rebase_author "" "fix/ga-6dp9-desc" "")" \
  ""
eq "trusted literal 'null' (jq empty-metadata artifact) treated as absent → branch fallback" \
  "$(resolve_rebase_author "null" "crew/thies-wa/some-bead" "")" \
  "thies-wa"
eq "marker author literal 'null' treated as absent → empty" \
  "$(resolve_rebase_author "" "fix/ga-6dp9-desc" "null")" \
  ""

# ── 2. author_is_alive(""): the unresolvable case is DEAD, never a phantom alive ─
# (bug 1, closing the loop) Short-circuits on empty input before any live
# gc/Dolt IO — safe to call directly from this no-live-services harness.
echo "── 2. author_is_alive(\"\") → 0 (fail-safe: unresolvable is dead, not alive) ──"
eq "empty author → dead (0), never misread as a phantom live session" \
  "$(author_is_alive "")" \
  "0"

# ── 3. gate_behind_envelope_action: permanent condition, never a silent retry ──
# (bug 2) main only moves forward — behind-envelope-exceeded must resolve to
# circuit_break (dead author) or bounce (live author), and NEVER leave the
# generic transient-retry path free to re-queue it.
echo "── 3. gate_behind_envelope_action: behind-exceeded is ALWAYS non-retry ──"
eq "not exceeded, live author → not_applicable (existing transient-retry path is untouched)" \
  "$(gate_behind_envelope_action "0" "1")" \
  "not_applicable"
eq "not exceeded, dead author → not_applicable" \
  "$(gate_behind_envelope_action "0" "0")" \
  "not_applicable"
eq "exceeded, dead author → circuit_break (immediate escalation, no retry loop)" \
  "$(gate_behind_envelope_action "1" "0")" \
  "circuit_break"
eq "exceeded, LIVE author → bounce (assisted rebase — a live author CAN fix a permanent condition)" \
  "$(gate_behind_envelope_action "1" "1")" \
  "bounce"
eq "garbage exceeded flag sanitizes to 0 → not_applicable (fail-open, no spurious break)" \
  "$(gate_behind_envelope_action "xx" "1")" \
  "not_applicable"
eq "garbage author_alive sanitizes to 0, exceeded=1 → circuit_break" \
  "$(gate_behind_envelope_action "1" "xx")" \
  "circuit_break"

# ── 4. gate_rebase_attempt_advanced: falsify the write, don't assume it ────────
# (bug 3) An unverified label write and a silently-failed one must NOT collapse
# to the same accepted state — that collapse is exactly what produced the
# infinite "attempt 1/3" loop in production.
echo "── 4. gate_rebase_attempt_advanced: counter must be VERIFIED, not assumed ──"
eq "write took effect (actual matches intended) → advanced" \
  "$(gate_rebase_attempt_advanced "1" "1")" \
  "advanced"
eq "write took effect and then some (actual > intended, e.g. a concurrent bump) → advanced" \
  "$(gate_rebase_attempt_advanced "2" "3")" \
  "advanced"
eq "write silently failed (actual still at the OLD value) → stuck" \
  "$(gate_rebase_attempt_advanced "1" "0")" \
  "stuck"
eq "write silently failed on a later attempt (intended 3, marker still shows 2) → stuck" \
  "$(gate_rebase_attempt_advanced "3" "2")" \
  "stuck"
eq "intended=0 (defensive default), actual=0 → advanced (vacuous, never falsely stuck)" \
  "$(gate_rebase_attempt_advanced "0" "0")" \
  "advanced"
eq "garbage intended sanitizes to 0, any actual → advanced (fail-open toward progress, not toward a false stall)" \
  "$(gate_rebase_attempt_advanced "xx" "0")" \
  "advanced"

# ── 5. End-to-end: the exact reported incident shape now escalates, never loops ─
# Reproduces ga-p2rb: a Mayor-rescued marker for branch crew/wa-worker/wa-aed6l,
# no gate.submitted_by (created outside the normal guard flow), main 55 commits
# ahead of the branch base (> default GATE_REBASE_BEHIND_MAX=50), attempt
# counter write silently failing every sweep. Old code: AUTHOR resolved to the
# bead's current owner (peter-wa, live) → AUTHOR_ALIVE=1 → generic transient
# retry branch → counter never verified → "attempt 1/3" forever. New code:
echo "── 5. End-to-end: the reported incident now escalates instead of looping ──"
_INCIDENT_AUTHOR=$(resolve_rebase_author "" "crew/wa-worker/wa-aed6l" "")
_INCIDENT_ALIVE=$(author_is_alive "$_INCIDENT_AUTHOR")
eq "incident: resolved author is the branch's crew segment, not peter-wa" \
  "$_INCIDENT_AUTHOR" \
  "wa-worker"
eq "incident: an ephemeral wa-worker build with no live session named exactly 'wa-worker' reads as dead" \
  "$_INCIDENT_ALIVE" \
  "0"
_INCIDENT_ACTION=$(gate_behind_envelope_action "1" "$_INCIDENT_ALIVE")
eq "incident: 55 > 50 behind-envelope + dead author → circuit_break (not a silent re-queue)" \
  "$_INCIDENT_ACTION" \
  "circuit_break"
_INCIDENT_WRITE_STATUS=$(gate_rebase_attempt_advanced "1" "0")
eq "incident: a silently-failed counter write is caught as stuck (would have forced escalation even if behind-envelope hadn't already caught it)" \
  "$_INCIDENT_WRITE_STATUS" \
  "stuck"

# ── 6. Drift guard: all four functions must still be exported by the dispatcher ─
echo "── 6. drift guard: ga-6dp9 functions present in lib-only mode ──"
for _fn in resolve_rebase_author gate_behind_envelope_action gate_rebase_attempt_advanced; do
  type "$_fn" >/dev/null 2>&1 \
    && ok "$_fn present in lib-only mode" \
    || bad "$_fn MISSING from dispatcher lib-only export (drift!)"
done

# ── 7. gate-fix-1: AUTHOR (notify target) and REBASE_AUTHOR (liveness decision)
#    each get their OWN independent resolve_recycled_author() redirect ────────
# Gate review on the first ga-6dp9 submission (gate_run=ga-wisp-wejpxu) found
# that an earlier revision reassigned ONLY REBASE_AUTHOR, leaving $AUTHOR — the
# notify target used by every nudge/mail call in this block — pointed at a
# confirmed-dead recycled session even when the liveness decision correctly
# read "alive" via the redirect. Concretely: a worker submits under an
# ephemeral adhoc session (gate.submitted_by="digo-wa-adhoc-abc123"); by
# dispatch time that session exited but the durable role "digo-wa" has a fresh
# live session. resolve_recycled_author redirected the DECISION correctly, but
# the "author is live — bounce for manual rebase" nudge/mail was silently sent
# to the dead adhoc id, defeating the live-author escape hatch this whole
# block exists to provide. gate-recycled-session-author-fallback.selftest.sh
# (ga-pyzo) already proves resolve_recycled_author()'s pure behavior
# exhaustively (B1-B6) and its B7/B8 drift-guards independently caught this
# exact regression by literal wiring pattern — this section closes the gap
# the reviewer named specifically: this selftest never exercised the
# AUTHOR-vs-REBASE_AUTHOR split at all.
echo "── 7. gate-fix-1: AUTHOR notify-target redirect, independent of the REBASE_AUTHOR liveness decision ──"
if grep -qF 'REBASE_AUTHOR_ALIVE=$(author_is_alive "$REBASE_AUTHOR")' "$DISPATCHER"; then
  ok "rebase-path liveness DECISION keyed on REBASE_AUTHOR_ALIVE (bug 1 fix intact)"
else
  bad "REBASE_AUTHOR_ALIVE computation missing/renamed — bug 1 regressed?"
fi
if grep -qF '_RESOLVED_REBASE_AUTHOR=$(resolve_recycled_author "$REBASE_AUTHOR" "$AUTHOR_AGENT" "$REBASE_AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "REBASE_AUTHOR gets its own recycled-session redirect for the liveness decision"
else
  bad "REBASE_AUTHOR recycled-session redirect missing/renamed"
fi
# grep -F substring match would false-positive here: 'AUTHOR_ALIVE=$(author_is_alive
# "$AUTHOR")' is also a literal substring of the unrelated FAIL-path line
# 'FAIL_AUTHOR_ALIVE=$(author_is_alive "$AUTHOR")' (drop the "FAIL_" prefix) — the
# same collision that makes B8 in gate-recycled-session-author-fallback.selftest.sh
# vacuous for this exact pattern. Anchor on the line's own leading whitespace so
# only the bare (unprefixed) AUTHOR_ALIVE assignment counts.
if grep -qE '^[[:space:]]+AUTHOR_ALIVE=\$\(author_is_alive "\$AUTHOR"\)$' "$DISPATCHER"; then
  ok "AUTHOR's OWN liveness restored (ga-pyzo/ga-ipf6 original wiring, gate-fix-1)"
else
  bad 'AUTHOR_ALIVE=$(author_is_alive "$AUTHOR") missing — ga-pyzo/ga-ipf6 wiring not restored'
fi
if grep -qF '_RESOLVED_AUTHOR=$(resolve_recycled_author "$AUTHOR" "$AUTHOR_AGENT" "$AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "AUTHOR notify-target gets its own independent recycled-session redirect (the reviewer's blocking issue)"
else
  bad "AUTHOR notify-target redirect missing — gate review blocking issue regressed"
fi
echo "── 7b. rebase-path decision call sites keyed on REBASE_AUTHOR_ALIVE, not bare AUTHOR_ALIVE ──"
grep -qF 'gate_circuit_break_check "ahead_dead" "${REBASE_AHEAD:-}" "$REBASE_AUTHOR_ALIVE"' "$DISPATCHER" \
  && ok "ga-acb ahead_dead circuit-break keyed on REBASE_AUTHOR_ALIVE" \
  || bad "ga-acb ahead_dead circuit-break NOT keyed on REBASE_AUTHOR_ALIVE — regressed to notify-identity liveness?"
grep -qF 'gate_behind_envelope_action "$REBASE_BEHIND_EXCEEDED" "$REBASE_AUTHOR_ALIVE"' "$DISPATCHER" \
  && ok "ga-6dp9 behind-envelope action keyed on REBASE_AUTHOR_ALIVE" \
  || bad "ga-6dp9 behind-envelope action NOT keyed on REBASE_AUTHOR_ALIVE — bug 1/bug 2 regressed?"
grep -qF 'if [ "$REBASE_AUTHOR_ALIVE" = "1" ] && [ "$CONFLICT_KIND" = "merge" ]' "$DISPATCHER" \
  && ok "genuine-merge-conflict bounce keyed on REBASE_AUTHOR_ALIVE" \
  || bad "genuine-merge-conflict bounce NOT keyed on REBASE_AUTHOR_ALIVE — regressed to notify-identity liveness?"
grep -qF 'elif [ "$REBASE_AUTHOR_ALIVE" = "1" ] && [ "$CONFLICT_KIND" = "transient" ]' "$DISPATCHER" \
  && ok "transient-retry live-author branch keyed on REBASE_AUTHOR_ALIVE" \
  || bad "transient-retry live-author branch NOT keyed on REBASE_AUTHOR_ALIVE — regressed to notify-identity liveness?"
grep -qF 'gate_circuit_break_check "retry_dead" "" "$REBASE_AUTHOR_ALIVE"' "$DISPATCHER" \
  && ok "retry_dead circuit-break keyed on REBASE_AUTHOR_ALIVE" \
  || bad "retry_dead circuit-break NOT keyed on REBASE_AUTHOR_ALIVE — regressed to notify-identity liveness?"

# ── 8. gate-fix-2: bounce/retry-live branches notify REBASE_AUTHOR, not the
#    possibly-dead $AUTHOR ──────────────────────────────────────────────────
# Gate review on gate-fix-1 (gate_run=ga-wisp-bkb9q6) found that the 4 branches
# gated on REBASE_AUTHOR_ALIVE=1 (behind-envelope bounce, genuine-merge-conflict
# bounce, transient-retry-live-author, and its exhausted-retries escalation)
# decide "someone can fix this" via REBASE_AUTHOR_ALIVE but nudged the SEPARATE,
# possibly-dead $AUTHOR — which, unlike REBASE_AUTHOR, CAN fall through to a
# stale bead-assignee/owner (see resolve_rebase_author()'s docstring above).
# Concrete repro from the review: a Mayor-rescue marker with no
# gate.submitted_by; bead assignee 'peter-wa' has exited (AUTHOR='peter-wa',
# dead) but the branch's own crew segment 'oracle-wa' is live
# (REBASE_AUTHOR='oracle-wa', REBASE_AUTHOR_ALIVE=1) — a genuine conflict then
# correctly decides to bounce, but the old code nudged dead peter-wa, never
# telling live oracle-wa who could actually act.
#
# Extracts the rebase-handling block by its (verified unique) start/end anchor
# strings and asserts, WITHIN just that block: every session-nudge call
# targets $REBASE_AUTHOR, none target the bare $AUTHOR. A whole-file grep would
# false-positive on 2 unrelated $AUTHOR nudge call sites elsewhere in this
# dispatcher (Step 3 FAIL-path notify) that are out of scope for ga-6dp9.
echo "── 8. gate-fix-2: REBASE_AUTHOR_ALIVE-gated branches nudge REBASE_AUTHOR, not \$AUTHOR ──"
_REBASE_BLOCK=$(sed -n '/ga-ljbx: never-strand bounce/,/stale-base check passed/p' "$DISPATCHER")
if [ -z "$_REBASE_BLOCK" ]; then
  bad "could not extract the rebase-handling block — start/end anchor comments missing/renamed?"
else
  _NUDGE_AUTHOR_COUNT=$(printf '%s\n' "$_REBASE_BLOCK" | { grep -c 'session nudge "\$AUTHOR"' || true; })
  _NUDGE_REBASE_AUTHOR_COUNT=$(printf '%s\n' "$_REBASE_BLOCK" | { grep -c 'session nudge "\$REBASE_AUTHOR"' || true; })
  eq "no session-nudge call inside the rebase block targets the bare \$AUTHOR" \
    "$_NUDGE_AUTHOR_COUNT" \
    "0"
  eq "all 4 REBASE_AUTHOR_ALIVE-gated branches (bounce x2, transient-retry-live x2) nudge \$REBASE_AUTHOR" \
    "$_NUDGE_REBASE_AUTHOR_COUNT" \
    "4"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 1
fi

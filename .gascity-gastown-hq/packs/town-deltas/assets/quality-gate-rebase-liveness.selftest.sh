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

# ga-tz0op NOTE: the 4 assertions above remain factually true in isolation —
# gate_behind_envelope_action("1","0") really does return circuit_break, and
# that pure function is untouched by ga-tz0op. But this composition no longer
# describes what the REAL dispatcher does end-to-end for THIS input. A bare
# pool-template REBASE_AUTHOR ("wa-worker", exactly this section's own probe)
# is now intercepted BEFORE gate_behind_envelope_action is ever called (see
# rebase_author_is_pool() and its call site) — the dispatcher returns the
# source bead to the pool instead of reaching this circuit-break at all.
# Section 12 below covers the corrected end-to-end behavior for this exact
# scenario; this section still documents the pure function's own contract in
# isolation and both remain true simultaneously.

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
  # ga-kyxih: was 4 (bounce x2, transient-retry-live x2) until the transient-
  # retry-live "queued" call site was split in two (still/only $REBASE_AUTHOR
  # in both halves) so a merge-commit-tip branch gets an action-oriented
  # nudge instead of the generic "no action needed" — see section 10d below.
  # The count moved from 4 to 5; the invariant this test actually protects
  # (never the bare, possibly-dead $AUTHOR — asserted just above, count=0)
  # is unchanged.
  eq "all REBASE_AUTHOR_ALIVE-gated branches (bounce x2, transient-retry-live x2 now split into 2 sub-variants = 3) nudge \$REBASE_AUTHOR" \
    "$_NUDGE_REBASE_AUTHOR_COUNT" \
    "5"
fi

# ── 9. ga-g0v96: exile-after-N-attempts decouples the retry counter from the
#    tier-sinking label, captured push diagnostics replace fabricated causes,
#    and the retry state is mirrored onto the source bead ───────────────────
# BUG (ga-g0v96): stamping gate:exiled-tier5 on the VERY FIRST transient
# rebase failure sank the marker behind the ENTIRE healthy queue before its
# own "retry 1/3" had a chance to run — a busy gate could starve attempt 2
# for hours (observed: 4h44m, wa-b6uy3). Separately, "Auto-rebase push
# failed" discarded stderr+exit code entirely, and the retry-queue comment
# asserted a specific guessed mechanism ("likely a rebase-while-queued race,
# author may have force-pushed") as fact — proven chronologically IMPOSSIBLE
# in the real incident (push failed 2h before the cited force-push).
echo "── 9. ga-g0v96: exile-after-N-attempts, captured push diagnostics, bead-visible retry state ──"

echo "── 9a. gate_should_exile_tier5: pure decision, forgives ONE blip ──"
eq "attempt 1 < default threshold 2 → do not exile yet (forgive the first blip)" \
  "$(gate_should_exile_tier5 "1" "2")" \
  "0"
eq "attempt 2 == default threshold 2 → exile (repeated failure)" \
  "$(gate_should_exile_tier5 "2" "2")" \
  "1"
eq "attempt 3 > default threshold 2 → exile" \
  "$(gate_should_exile_tier5 "3" "2")" \
  "1"
eq "threshold=1 (GATE_EXILE_AFTER_ATTEMPTS=1) restores the OLD always-exile-on-attempt-1 behavior" \
  "$(gate_should_exile_tier5 "1" "1")" \
  "1"
eq "garbage attempt/threshold sanitize to defaults (1 < 2) → do not exile (fail toward the forgiving default, not a false exile)" \
  "$(gate_should_exile_tier5 "xx" "yy")" \
  "0"

echo "── 9b. read_rebase_attempt: widened regex recognizes the new counter label end-to-end (mocked bd) ──"
bd() {
  case " $* " in
    *" show "*) printf '%s' "$_RA_MOCK_JSON" ;;
    *) : ;;
  esac
  return 0
}
_RA_MOCK_JSON='[{"id":"ga-wisp-mock","labels":["gate-status:queued","gate:rebase-fail-count:1"]}]'
eq "attempt-1 failure (no tier5 label yet) still reads back as 1 via gate:rebase-fail-count" \
  "$(read_rebase_attempt "ga-wisp-mock")" \
  "1"
_RA_MOCK_JSON='[{"id":"ga-wisp-mock","labels":["gate-status:queued","gate:rebase-fail-count:2","gate:exiled-tier5:2"]}]'
eq "attempt-2 (exiled) reads back as 2 (both labels present, MAX taken, no double-count)" \
  "$(read_rebase_attempt "ga-wisp-mock")" \
  "2"
_RA_MOCK_JSON='[{"id":"ga-wisp-mock","labels":["gate-status:queued","gate:rebase-attempt:3"]}]'
eq "pre-ga-gpcx legacy label name (gate:rebase-attempt:N) still recognized" \
  "$(read_rebase_attempt "ga-wisp-mock")" \
  "3"
_RA_MOCK_JSON='[{"id":"ga-wisp-mock","labels":["gate-status:queued"]}]'
eq "no counter label present → 0" \
  "$(read_rebase_attempt "ga-wisp-mock")" \
  "0"
unset -f bd

echo "── 9c. drift-guard: AC3 — push stderr/exit-code captured, fabricated-cause phrase gone ──"
grep -qF 'AUTO_REBASE_PUSH_RC=$?' "$DISPATCHER" \
  && ok "push exit code is captured into AUTO_REBASE_PUSH_RC" \
  || bad "AUTO_REBASE_PUSH_RC capture missing — AC3 regressed?"
grep -qF '_PUSH_ERR_FILE' "$DISPATCHER" \
  && ok "push stderr is captured to a file instead of being discarded to /dev/null" \
  || bad "_PUSH_ERR_FILE capture missing — AC3 regressed?"
if grep -qE 'likely a rebase-while-queued race \(author \$REBASE_AUTHOR may have force-pushed' "$DISPATCHER"; then
  bad "the fabricated-mechanism phrase ('likely a rebase-while-queued race...') is STILL present — mila-wa proved this exact phrase chronologically impossible in the real incident (ga-g0v96)"
else
  ok "fabricated-mechanism phrase ('likely a rebase-while-queued race...') is gone"
fi
grep -qF 'cause not captured' "$DISPATCHER" \
  && ok "an uncaptured push failure is now labeled 'cause not captured' (hypothesis, not asserted fact)" \
  || bad "'cause not captured' fallback text missing"

echo "── 9d. drift-guard: AC4 — gate_should_exile_tier5 actually gates the write sites (not just defined) ──"
_EXILE_CALL_COUNT=$(grep -c 'gate_should_exile_tier5 "\$NEXT_ATTEMPT" "\$GATE_EXILE_AFTER_ATTEMPTS"' "$DISPATCHER" || true)
if [ "${_EXILE_CALL_COUNT:-0}" -ge 2 ]; then
  ok "gate_should_exile_tier5 is called at both retry sites (live-author + dead-author), count=$_EXILE_CALL_COUNT"
else
  bad "gate_should_exile_tier5 called fewer than 2 times (count=${_EXILE_CALL_COUNT:-0}) — a write site may still unconditionally exile"
fi
grep -qF 'GATE_EXILE_AFTER_ATTEMPTS="${GATE_EXILE_AFTER_ATTEMPTS:-2}"' "$DISPATCHER" \
  && ok "GATE_EXILE_AFTER_ATTEMPTS knob present, env-overridable, defaults to 2" \
  || bad "GATE_EXILE_AFTER_ATTEMPTS knob missing/renamed"

echo "── 9e. drift-guard: AC5 — retry state mirrored onto the SOURCE bead, not just the marker ──"
_BEAD_RETRY_LABEL_COUNT=$(grep -c 'gate:rebase-retry:' "$DISPATCHER" || true)
if [ "${_BEAD_RETRY_LABEL_COUNT:-0}" -ge 4 ]; then
  ok "gate:rebase-retry label referenced at add/remove sites for both retry paths (count=$_BEAD_RETRY_LABEL_COUNT)"
else
  bad "gate:rebase-retry label references fewer than expected (count=${_BEAD_RETRY_LABEL_COUNT:-0}) — AC5 bead-visibility may have regressed"
fi
grep -qF 'bd -C "$BEAD_CITY" label add    "$BEAD_ID" "gate:rebase-retry:$NEXT_ATTEMPT"' "$DISPATCHER" \
  && ok "retry state is written to \$BEAD_CITY/\$BEAD_ID (visible on the source bead), not only \$GC_CITY/\$MARKER_ID" \
  || bad "gate:rebase-retry is not written to the source bead — AC5 (visibility outside the marker) regressed"

# ── 10. ga-kyxih: merge-commit-tip branches route to `git merge`, not `git
#    rebase` — and the messaging tells the author what to do ─────────────────
# BUG (ga-kyxih): `git rebase` (used unconditionally, no --rebase-merges)
# linearizes/mishandles a branch whose OWN tip is itself a merge commit (e.g.
# the author already did a manual "merge origin/main" once). Two real
# incidents (ga-ffop9, ga-mmdm2, measured by the Mayor 2026-08-05) confirmed
# `git merge-tree` correctly predicts a clean 3-way merge while a literal
# `git rebase` still fails or misbehaves on such a branch — and the failure
# was mislabeled "transient" identically to a genuinely random push race, so a
# deterministic, retry-proof condition burned attempts before the author was
# ever told to act.
echo "── 10. ga-kyxih: merge-commit-tip branches route to git merge, not git rebase ──"

echo "── 10a. branch_tip_is_merge_commit: real git fixtures, not string matching ──"
_FIXTURE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-mergetip-fixture.XXXXXX")"
git -C "$_FIXTURE_REPO" init -q -b main
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "root"
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" branch linear-branch
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" checkout -q linear-branch
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "linear commit 1"
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "linear commit 2"
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" checkout -q main
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "main-only commit"
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" checkout -q linear-branch
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" merge -q -m "merge main into linear-branch" main
# linear-branch's tip is NOW itself a merge commit — pin it under its own
# name for clarity, and keep a SEPARATE, genuinely-linear branch (off main,
# never merged into) as the negative case.
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" branch merge-tip-branch
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" checkout -q main
git -C "$_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" branch still-linear-branch main

# git_rig, as sourced from the dispatcher in lib-only mode, is UNDEFINED here
# (it's defined AFTER the GATE_DISPATCHER_LIB_ONLY early-return by design —
# see that guard's own comment above). Shim it to the fixture repo, mirroring
# the real wrapper's self-repo-rig branch (`git -C "$GIT_DIR_PATH" "$@"`) —
# same technique as the `bd()` mock in 9b above, but against a REAL git repo
# so parent-count detection is exercised for real, not string-matched.
git_rig() { git -C "$_FIXTURE_REPO" "$@"; }

eq "still-linear-branch tip (plain commit, single parent) → 0 (not a merge commit)" \
  "$(branch_tip_is_merge_commit "still-linear-branch")" \
  "0"
eq "merge-tip-branch tip (the merge commit just created) → 1 (IS a merge commit)" \
  "$(branch_tip_is_merge_commit "merge-tip-branch")" \
  "1"
eq "empty ref → 0 (fail toward the existing, well-tested rebase path)" \
  "$(branch_tip_is_merge_commit "")" \
  "0"
eq "unresolvable ref → 0 (fail toward the existing rebase path, never toward the newer merge path on an ambiguous read)" \
  "$(branch_tip_is_merge_commit "refs/heads/does-not-exist-xyz")" \
  "0"

unset -f git_rig
rm -rf "$_FIXTURE_REPO"

echo "── 10b. drift-guard: both rebase-attempt sites route on BRANCH_TIP_IS_MERGE_COMMIT before falling to git rebase ──"
_MERGE_ROUTE_COUNT=$(grep -c 'if \[ "\$BRANCH_TIP_IS_MERGE_COMMIT" = "1" \]; then' "$DISPATCHER" || true)
if [ "${_MERGE_ROUTE_COUNT:-0}" -ge 2 ]; then
  ok "BRANCH_TIP_IS_MERGE_COMMIT routing present at both rig-type call sites (count=$_MERGE_ROUTE_COUNT)"
else
  bad "BRANCH_TIP_IS_MERGE_COMMIT routing found fewer than 2 times (count=${_MERGE_ROUTE_COUNT:-0}) — one rig-type call site may be missing the fix"
fi
grep -qF 'elif git -C "$TMP_REBASE_WT" -c user.email="gate-dispatcher@gascity.local" -c user.name="Gate Dispatcher" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then' "$DISPATCHER" \
  && ok "the ORIGINAL rebase invocation is preserved verbatim as the elif fallback (AC3 non-regression: linear branches still rebase)" \
  || bad "original rebase invocation (as an elif fallback) not found verbatim — AC3 non-regression may be broken"
grep -qF 'BRANCH_TIP_IS_MERGE_COMMIT=$(branch_tip_is_merge_commit "origin/$BRANCH")' "$DISPATCHER" \
  && ok "BRANCH_TIP_IS_MERGE_COMMIT is computed once per sweep from the live branch tip" \
  || bad "BRANCH_TIP_IS_MERGE_COMMIT computation call site missing/renamed"

echo "── 10c. drift-guard: AC2 — merge-commit-tip auto-fix path is logged distinctly from a real git-rebase failure ──"
grep -qF 'Auto-merge (ga-kyxih: tip is itself a merge commit — rebase is not applicable)' "$DISPATCHER" \
  && ok "auto-merge path (container-rig) logs a distinct message naming the merge-commit-tip cause" \
  || bad "container-rig auto-merge log message missing/reworded"
grep -qF 'Auto-merge (self-repo, ga-kyxih: tip is itself a merge commit — rebase is not applicable)' "$DISPATCHER" \
  && ok "auto-merge path (self-repo-rig) logs a distinct message naming the merge-commit-tip cause" \
  || bad "self-repo-rig auto-merge log message missing/reworded"
grep -qF 'warn "  Auto-rebase git rebase command failed (unexpected — merge-tree reported no conflicts)"' "$DISPATCHER" \
  && ok "the original 'real rebase failed' warning text is untouched — still distinguishable from the new auto-merge messages" \
  || bad "original rebase-failure warning text missing/reworded — AC2 distinction may have regressed"

echo "── 10d. drift-guard: AC4 — merge-commit-tip transient retries tell the author what to do, others keep 'no action needed' ──"
grep -qF "don't wait: run 'git merge origin/\$DEFAULT_BRANCH' into \$BRANCH yourself and push" "$DISPATCHER" \
  && ok "merge-commit-tip transient-retry nudge tells the author the deterministic fallback action" \
  || bad "merge-commit-tip transient-retry action-oriented nudge missing/reworded"
grep -qF 'No action needed unless this keeps retrying.' "$DISPATCHER" \
  && ok "the original 'no action needed' wording is PRESERVED for the non-merge-commit-tip (genuinely transient) case" \
  || bad "original 'no action needed' wording missing — non-merge-commit-tip transient retries may have lost their correct framing"

echo "── 10e. drift-guard: AC1/AC4 — genuine-conflict bounce (live + dead author) names the merge-not-rebase fix ──"
grep -qF "run 'git merge origin/\$DEFAULT_BRANCH' into \$BRANCH, resolve the conflict, and push" "$DISPATCHER" \
  && ok "live-author genuine-conflict bounce advises merge (not rebase) for a merge-commit-tip branch" \
  || bad "live-author genuine-conflict merge-not-rebase advice missing/reworded"
grep -qF "re-anchoring means 'git merge origin/\$DEFAULT_BRANCH' into \$BRANCH, not a rebase" "$DISPATCHER" \
  && ok "dead-author genuine-conflict marker comment advises merge (not rebase) for a merge-commit-tip branch" \
  || bad "dead-author genuine-conflict merge-not-rebase advice missing/reworded"

# ── 11. ga-gxbxu: rebase-liveness keyed on the branch's OWN commit author,
#     never the /gate-done SUBMITTER ───────────────────────────────────────
# BUG (ga-gxbxu): gate.submitted_by names who ran /gate-done — reliable for
# AUTHORIZATION/AUDIT (untouched by this fix: AUTHOR/AUTHOR_TRUSTED_SUBMIT
# still derive from it exactly as before) but WRONG for "is someone live who
# could be pushing this branch right now" whenever a THIRD party submits on
# someone else's already-pushed branch (a rescue/resubmission marker).
# Measured live: marker ga-ikk0i, gate.submitted_by=gastown__mayor (67-day
# uptime, functionally immortal), but all 5 of the branch's own commits were
# authored by gastown.dog-1 (already exited per normal dog doctrine: close
# bead, exit, pool recycles the slot). "Author alive" read permanently true
# off the wrong identity, so the branch waited forever for a push race that
# was never going to happen — Mayor was never going to push it. Fix: resolve
# the rebase-liveness identity from the branch's own git history FIRST
# (branch_tip_commit_author, new — mirrors branch_tip_is_merge_commit's git_rig
# usage above), falling back to the pre-existing trusted/crew/marker-author
# chain unchanged when git history is unavailable.
echo "── 11. ga-gxbxu: rebase-liveness keyed on the branch's OWN commit author, never the /gate-done SUBMITTER ──"

echo "── 11a. resolve_rebase_author: branch commit author (new 4th arg) OUTRANKS trusted submitter ──"
eq "commit author present → wins outright, even with a trusted submitter also present" \
  "$(resolve_rebase_author "gastown__mayor" "fix/ga-gxbxu" "" "gastown.dog-1")" \
  "gastown.dog-1"
eq "reproduces the live incident: resolved author is the actual committer, never the eternal-uptime submitter" \
  "$([ "$(resolve_rebase_author "gastown__mayor" "fix/ga-gxbxu" "" "gastown.dog-1")" != "gastown__mayor" ] && echo "excluded" || echo "leaked")" \
  "excluded"
eq "REGRESSION (acceptance criterion): commit author omitted (3-arg call) → unchanged pre-ga-gxbxu behavior, trusted submitter still wins — nothing was deleted, only reordered" \
  "$(resolve_rebase_author "gastown__mayor" "fix/ga-gxbxu" "")" \
  "gastown__mayor"
eq "commit author literal 'null' (unresolvable-ref artifact) treated as absent → falls to trusted submitter" \
  "$(resolve_rebase_author "gastown__mayor" "fix/ga-gxbxu" "" "null")" \
  "gastown__mayor"
eq "commit author empty, trusted also absent → falls through to crew branch segment exactly as ga-6dp9 established" \
  "$(resolve_rebase_author "" "crew/wa-worker/wa-aed6l" "" "")" \
  "wa-worker"
eq "commit author empty, no trusted, no crew → falls to marker author exactly as ga-6dp9 established" \
  "$(resolve_rebase_author "" "fix/ga-6dp9-desc" "some-dog" "")" \
  "some-dog"

echo "── 11b. branch_tip_commit_author: real git fixture, not string matching ──"
_AUTHOR_FIXTURE_REPO="$(mktemp -d "${TMPDIR:-/tmp}/gc-gate-commitauthor-fixture.XXXXXX")"
git -C "$_AUTHOR_FIXTURE_REPO" init -q -b main
git -C "$_AUTHOR_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" commit -q --allow-empty -m "root"
git -C "$_AUTHOR_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" branch dog-branch
git -C "$_AUTHOR_FIXTURE_REPO" -c user.email="t@t" -c user.name="t" checkout -q dog-branch
git -C "$_AUTHOR_FIXTURE_REPO" -c user.email="gastown.dog-1@gascity.local" -c user.name="gastown.dog-1" \
  commit -q --allow-empty -m "dog's own fix commit"

# git_rig, as sourced from the dispatcher in lib-only mode, is UNDEFINED here
# (same reasoning as section 10a above) — shim it to the fixture repo.
git_rig() { git -C "$_AUTHOR_FIXTURE_REPO" "$@"; }

eq "branch tip authored by gastown.dog-1 → echoes 'gastown.dog-1' (the real, git-verified committer)" \
  "$(branch_tip_commit_author "dog-branch")" \
  "gastown.dog-1"
eq "empty ref → '' (fail toward resolve_rebase_author's existing fallback chain, never a guess)" \
  "$(branch_tip_commit_author "")" \
  ""
eq "unresolvable ref → '' (same fail-safe direction)" \
  "$(branch_tip_commit_author "refs/heads/does-not-exist-xyz")" \
  ""

unset -f git_rig
rm -rf "$_AUTHOR_FIXTURE_REPO"

echo "── 11c. End-to-end: the exact reported incident (marker ga-ikk0i shape) now resolves off the real committer ──"
# "gastown.dog" (bare pool TEMPLATE, mirroring section 1's "wa-worker" probe)
# can never be any real session's exact alias — real dog slots are always
# numbered instances (gastown.dog-1, gastown.dog-2, ...) — so this
# reproduces "the specific dog that wrote these commits is no longer
# running" without depending on whatever dog-pool state happens to be live
# when this selftest runs (same technique, same reasoning as section 5's
# "wa-worker" probe above).
_GXBXU_AUTHOR=$(resolve_rebase_author "gastown__mayor" "fix/ga-gxbxu" "" "gastown.dog")
eq "incident: resolved rebase-liveness author is the real committer, not the immortal submitter" \
  "$_GXBXU_AUTHOR" \
  "gastown.dog"
eq "incident: reproduces that resolution never leaks the submitter's identity into the liveness decision" \
  "$([ "$_GXBXU_AUTHOR" != "gastown__mayor" ] && echo "excluded" || echo "leaked")" \
  "excluded"
_GXBXU_ALIVE=$(author_is_alive "$_GXBXU_AUTHOR")
eq "incident: the exited dog's bare pool-template alias reads as dead — no more infinite wait on the eternal Mayor session" \
  "$_GXBXU_ALIVE" \
  "0"

echo "── 11d. drift-guard: gate.submitted_by/AUTHOR_TRUSTED_SUBMIT untouched (still the audit/authorization identity), and the call site actually wires the new signal in ──"
# REGRESSION GUARD (acceptance criterion: "quando o DONO da branch está vivo,
# a supressão continua"): this fix does NOT touch REBASE_AUTHOR_ALIVE's own
# definition, nor any of the branches that key off it (sections 3, 7, and 7b
# above exercise those, unmodified by this change, and must still pass) — it
# only changes WHICH identity string can win the priority chain that feeds
# REBASE_AUTHOR. A live real author, however resolved, is still checked by
# the same author_is_alive() and still drives the same bounce/retry
# branches. A test that only proved "now it pushes" would pass equally if
# the safeguard were deleted outright; sections 3/7/7b continuing to pass
# unmodified, plus the "commit author omitted" non-regression case in 11a,
# together prove the safeguard is retargeted, not disabled.
grep -qF 'AUTHOR=$(printf '"'"'%s\n'"'"' "$VERIFY_JSON" | jq -r '"'"'if type=="array" then .[0] else . end | .metadata["gate.submitted_by"] // empty'"'"' 2>/dev/null || true)' "$DISPATCHER" \
  && ok "AUTHOR is still derived from gate.submitted_by metadata (audit/authorization identity, unchanged by ga-gxbxu)" \
  || bad "AUTHOR's gate.submitted_by derivation missing/reworded — this fix must NOT touch it"
grep -qF 'AUTHOR_TRUSTED_SUBMIT="$AUTHOR"' "$DISPATCHER" \
  && ok "AUTHOR_TRUSTED_SUBMIT snapshot still present, unchanged" \
  || bad "AUTHOR_TRUSTED_SUBMIT snapshot missing — ga-6dp9 wiring regressed"
grep -qF 'REBASE_BRANCH_COMMIT_AUTHOR=$(branch_tip_commit_author "$BRANCH_SHA")' "$DISPATCHER" \
  && ok "REBASE_BRANCH_COMMIT_AUTHOR computed from BRANCH_SHA (the already-hardened, already-resolved branch tip) before the call" \
  || bad "REBASE_BRANCH_COMMIT_AUTHOR computation missing/renamed"
grep -qF 'REBASE_AUTHOR=$(resolve_rebase_author "$AUTHOR_TRUSTED_SUBMIT" "$BRANCH" "$MARKER_AUTHOR" "$REBASE_BRANCH_COMMIT_AUTHOR")' "$DISPATCHER" \
  && ok "REBASE_AUTHOR call site passes the branch's own commit author as the new 4th argument — the fix is actually wired in, not just defined" \
  || bad "REBASE_AUTHOR call site not updated — the fix is defined but never wired in"

# ── 12. ga-it1of: REBASE_AUTHOR_ALIVE tries a rig-qualified crew-segment
#     candidate before giving up, closing a gap AUTHOR_AGENT cannot ─────────
# BUG (ga-it1of): two real incidents in one day (wa-qtwh3/marker ga-jvzpb:
# "CIRCUIT-BREAK (behind=117 > max=50, dead author)"; wa-si1vj/marker
# ga-c89o7: "Author session is gone — gate cannot self-heal") both declared
# the author dead while `gc session list` showed the real session (oracle-wa,
# digo-wa respectively) alive and responsive. Root cause, measured directly
# (NOT the bug report's own initial suspicion of a bare crew-segment lookup —
# that theory was wrong): both markers were created BY HAND by the Mayor
# (self_audit text on both confirms this, bypassing /gate-done — so
# AUTHOR_AGENT/gate.submitted_by_agent was never recorded, and the ga-pyzo
# recycled-session fallback above had nothing to try), AND on both branches
# `git log -1 --format=%an` on the tip commit — resolve_rebase_author()'s
# HIGHEST-priority candidate — was the STATIC git identity "athosmartins" on
# every single commit (verified directly against origin for both branches),
# not any agent's alias at all. That identity can never match a live session
# no matter how it is spelled, and resolve_rebase_author() never even reaches
# its own crew-segment fallback when commit_author is non-empty — so the old
# code had no further candidate to try and concluded dead. The fix adds ONE
# more fallback, independent of whatever resolve_rebase_author already
# committed to: the branch's own crew segment, qualified with the bead's rig
# suffix (oracle -> oracle-wa) — the same convention ga-z3i2p already shipped
# for Step 5a's park-notify cascade in quality-gate-guard.sh.
echo "── 12. ga-it1of: crew-segment liveness fallback closes the hand-made-marker gap ──"

for _fn in branch_crew_segment rig_qualify_candidate; do
  type "$_fn" >/dev/null 2>&1 \
    || { echo "FATAL: $_fn not defined by dispatcher (ga-it1of fix missing?)"; exit 1; }
done

echo "── 12a. branch_crew_segment: pure extraction, no live IO ──"
eq "crew/oracle/wa-qtwh3 (the real wa-qtwh3 incident branch) → oracle" \
  "$(branch_crew_segment "crew/oracle/wa-qtwh3")" \
  "oracle"
eq "crew/digo/wa-si1vj (the real wa-si1vj incident branch) → digo" \
  "$(branch_crew_segment "crew/digo/wa-si1vj")" \
  "digo"
eq "non-crew branch (dog fix/* convention) → empty, no segment to extract" \
  "$(branch_crew_segment "fix/ga-it1of-gate-author-liveness")" \
  ""
eq "empty branch → empty" \
  "$(branch_crew_segment "")" \
  ""

echo "── 12b. rig_qualify_candidate: bead-id-prefix-derived suffix, mirrors ga-z3i2p's shipped convention ──"
eq "oracle + wa-qtwh3 (real incident bead) → oracle-wa" \
  "$(rig_qualify_candidate "oracle" "wa-qtwh3")" \
  "oracle-wa"
eq "digo + wa-si1vj (real incident bead) → digo-wa" \
  "$(rig_qualify_candidate "digo" "wa-si1vj")" \
  "digo-wa"
eq "already-qualified bare identity → empty (never double-qualify to oracle-wa-wa)" \
  "$(rig_qualify_candidate "oracle-wa" "wa-qtwh3")" \
  ""
eq "HQ/gascity bead prefix (ga-) → empty, no verified rig-suffix convention to guess" \
  "$(rig_qualify_candidate "gastown.dog-1" "ga-it1of")" \
  ""
eq "empty bare identity → empty (nothing to qualify)" \
  "$(rig_qualify_candidate "" "wa-qtwh3")" \
  ""
eq "bead id with no '-' at all → empty (no real prefix to read, not a false qualify)" \
  "$(rig_qualify_candidate "oracle" "nodash")" \
  ""
eq "ps-rig bead → batista-ps (the convention generalizes beyond wa)" \
  "$(rig_qualify_candidate "batista" "ps-abc12")" \
  "batista-ps"

echo "── 12c. End-to-end: the exact wa-qtwh3 incident shape now finds a live candidate the old code never tried ──"
# Reproduces the real incident's resolve_rebase_author() inputs: no trusted
# submitter (hand-made marker, no gate.submitted_by), branch crew/oracle/...,
# no marker self-declared author consulted (commit_author wins outright), and
# commit_author = "athosmartins" (the measured real value on both incident
# branches — see the section-12 header comment).
_IT1OF_AUTHOR=$(resolve_rebase_author "" "crew/oracle/wa-qtwh3" "" "athosmartins")
eq "resolve_rebase_author picks the branch's own (mis-attributed) commit author, exactly as production did" \
  "$_IT1OF_AUTHOR" \
  "athosmartins"
_IT1OF_ALIVE=$(author_is_alive "$_IT1OF_AUTHOR")
eq "the static git identity 'athosmartins' is not any agent's alias → reads as dead (the OLD code stopped here and circuit-broke)" \
  "$_IT1OF_ALIVE" \
  "0"
# THE FIX: derive the crew-qualified candidate independently of REBASE_AUTHOR
# and check IT too, before giving up.
_IT1OF_CREW_CANDIDATE=$(rig_qualify_candidate "$(branch_crew_segment "crew/oracle/wa-qtwh3")" "wa-qtwh3")
eq "the fix's independently-derived candidate is oracle-wa — the SAME alias 'gc session list' showed alive in the real incident" \
  "$_IT1OF_CREW_CANDIDATE" \
  "oracle-wa"
# Live author_is_alive call against a real, persistent named-crew alias — same
# established technique as gate-recycled-session-author-fallback.selftest.sh's
# PART B (line ~194, "batista-wa" asserted alive directly against the live
# session roster). oracle-wa is itself one of this city's persistent named
# crew members (same class as batista-wa), so this is the same bet that
# selftest already makes, not a new one.
_IT1OF_CREW_ALIVE=$(author_is_alive "$_IT1OF_CREW_CANDIDATE")
eq "oracle-wa (a persistent named crew member) reads alive — the fix's candidate succeeds where the old code's only candidate failed" \
  "$_IT1OF_CREW_ALIVE" \
  "1"

echo "── 12d. drift guard: the crew-segment fallback is actually WIRED into the REBASE_AUTHOR_ALIVE cascade, not just defined ──"
grep -qF '_REBASE_CREW_CANDIDATE=$(rig_qualify_candidate "$(branch_crew_segment "$BRANCH")" "$BEAD_ID")' "$DISPATCHER" \
  && ok "the call site derives the crew-qualified candidate from \$BRANCH/\$BEAD_ID" \
  || bad "crew-qualified candidate derivation missing/renamed at the call site — fix defined but not wired in"
grep -qF 'if [ "$REBASE_AUTHOR_ALIVE" != "1" ]; then' "$DISPATCHER" \
  && ok "the fallback only fires when REBASE_AUTHOR is still dead after the ga-pyzo recycled-session check" \
  || bad "REBASE_AUTHOR_ALIVE guard missing/renamed — fallback may fire unconditionally or not at all"
grep -qF 'REBASE_AUTHOR="$_REBASE_CREW_CANDIDATE"' "$DISPATCHER" \
  && ok "a live crew-qualified candidate actually redirects REBASE_AUTHOR (not just logged)" \
  || bad "REBASE_AUTHOR redirect assignment missing — candidate found but never used"
grep -qF 'REBASE_AUTHOR_ALIVE=1' "$DISPATCHER" \
  && ok "a live crew-qualified candidate actually flips REBASE_AUTHOR_ALIVE (the circuit-break/escalation gate variable itself)" \
  || bad "REBASE_AUTHOR_ALIVE=1 redirect missing — candidate found but the decision variable never updated"

echo "── 12e. drift guard: AC3 — escalation messages state which candidates were checked ──"
grep -qF 'REBASE_LIVENESS_TRACE="$REBASE_AUTHOR:$([ "$REBASE_AUTHOR_ALIVE" = "1" ] && printf alive || printf dead)"' "$DISPATCHER" \
  && ok "REBASE_LIVENESS_TRACE is initialized from the first (commit-author-derived) candidate" \
  || bad "REBASE_LIVENESS_TRACE initialization missing/renamed"
_TRACE_MSG_COUNT=$(grep -c 'ga-it1of liveness check: ${REBASE_LIVENESS_TRACE:-none}\|Liveness candidates checked (ga-it1of): ${REBASE_LIVENESS_TRACE:-none}' "$DISPATCHER" || true)
if [ "${_TRACE_MSG_COUNT:-0}" -ge 6 ]; then
  ok "the candidate trace is interpolated into the escalation messages (ahead_dead, behind_dead, genuine-conflict, retry_dead — comment+mail pairs), count=$_TRACE_MSG_COUNT"
else
  bad "candidate trace interpolated into fewer than expected escalation messages (count=${_TRACE_MSG_COUNT:-0}) — AC3 may be incomplete"
fi

# ── 13. ga-tz0op: pool/ephemeral REBASE_AUTHOR is never asked "is this EXACT
#     instance alive" — routed back to the pool instead of circuit-broken ────
# BUG (ga-tz0op): a virtual Pilot slot label (wa-worker-1, pure concurrency
# accounting, never a real session identity), a bare pool template
# (wa-worker, no live session's session_name/name/alias/id/agent_name is ever
# just the template — real instances are always suffixed) or an
# already-recycled pool instance (wa-worker-<hash>, exited normally on
# delivery) can NEVER match a live session by design. author_is_alive() on
# any of these always answers 0 — not because the pool lacks capacity, but
# because "is this exact string alive" is the wrong question for an
# ephemeral identity class. Measured live: wa-nxwqw/marker ga-wu1f0,
# REBASE_AUTHOR="wa-worker-1", 2 real wa-worker sessions active, still
# circuit-broke as "no live author". Distinct root cause from ga-it1of (the
# CREW case: a real, persistent, named session resolved via the wrong short
# alias) — there IS no "right alias" to find for a pool identity; the
# question itself is the wrong category. Fix: rebase_author_is_pool() reuses
# gate_fail_assignee_action()'s existing pool/ephemeral case pattern (minus
# the empty-string arm — see that function's own header for why '' stays
# out) to short-circuit the ahead_dead/behind_dead/conflict decisions and
# return the source bead to its rig's generic pool instead.
echo "── 13. ga-tz0op: pool/ephemeral rebase-liveness authors routed to the pool, never circuit-broken as dead ──"

echo "── 13a. rebase_author_is_pool: pure truth table ──"
for _author in mayor gastown.mayor gastown__mayor gastown.dog gastown.dog-1 gastown.dog-gao05od dog-gaohnim wa-worker wa-worker-1 wa-worker-adhoc-e346188199 ps-worker ps-worker-3; do
  eq "'$_author' classifies as pool/ephemeral (1)" \
    "$(rebase_author_is_pool "$_author")" \
    "1"
done
eq "a real named crew alias ('oracle-wa') is NOT pool (0) — this fix must never swallow a genuine crew author" \
  "$(rebase_author_is_pool "oracle-wa")" \
  "0"
eq "another real named crew alias ('digo-wa') is NOT pool (0)" \
  "$(rebase_author_is_pool "digo-wa")" \
  "0"
eq "empty author is deliberately NOT pool (0) — resolve_rebase_author()'s own unresolvable-author fail-safe (circuit-break toward needs-human) is untouched by this fix, a different bug class" \
  "$(rebase_author_is_pool "")" \
  "0"

echo "── 13b. AC4: the exact reported incident shape (virtual slot, bare template, recycled instance) ──"
eq "AC4 shape 1: virtual Pilot slot label 'wa-worker-1' (the literal ga-wu1f0 incident value) classifies as pool" \
  "$(rebase_author_is_pool "wa-worker-1")" \
  "1"
eq "AC4 shape 2: bare pool template 'wa-worker' (no session ever matches just the template) classifies as pool" \
  "$(rebase_author_is_pool "wa-worker")" \
  "1"
eq "AC4 shape 3: a recycled pool instance 'wa-worker-gadnuds' (already exited normally) classifies as pool" \
  "$(rebase_author_is_pool "wa-worker-gadnuds")" \
  "1"
# AC1: none of these shapes are asked "is this exact instance alive" via the
# individually-keyed liveness question — author_is_alive() itself is
# untouched (still correctly answers 0 for all three, confirming the
# dispatcher's early pool-intercept is what changes, not the liveness
# predicate itself).
eq "AC1: author_is_alive() itself is unchanged — still 0 for the virtual slot label (proves the FIX is the early intercept, not a liveness-predicate change)" \
  "$(author_is_alive "wa-worker-1")" \
  "0"

echo "── 13c. drift-guard: the pool intercept is wired in AND positioned before every circuit-break/bounce decision ──"
grep -qF 'REBASE_AUTHOR_IS_POOL=$(rebase_author_is_pool "$REBASE_AUTHOR")' "$DISPATCHER" \
  && ok "REBASE_AUTHOR_IS_POOL is actually computed at the call site (fix wired in, not just defined)" \
  || bad "REBASE_AUTHOR_IS_POOL computation missing — rebase_author_is_pool() defined but never called"
grep -qF 'if [ "$REBASE_AUTHOR_IS_POOL" = "1" ]; then' "$DISPATCHER" \
  && ok "dispatcher branches on REBASE_AUTHOR_IS_POOL" \
  || bad "REBASE_AUTHOR_IS_POOL branch missing"

_POOL_INTERCEPT_LN=$(grep -n 'REBASE_AUTHOR_IS_POOL=\$(rebase_author_is_pool "\$REBASE_AUTHOR")' "$DISPATCHER" | head -1 | cut -d: -f1)
_AHEAD_DEAD_LN=$(grep -n '_ACB_AHEAD=\$(gate_circuit_break_check "ahead_dead"' "$DISPATCHER" | head -1 | cut -d: -f1)
_BEHIND_ACTION_LN=$(grep -n '_BEHIND_ACTION=\$(gate_behind_envelope_action' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$_POOL_INTERCEPT_LN" ] && [ -n "$_AHEAD_DEAD_LN" ] && [ "$_POOL_INTERCEPT_LN" -lt "$_AHEAD_DEAD_LN" ]; then
  ok "AC1: pool intercept (line $_POOL_INTERCEPT_LN) runs BEFORE the ahead_dead circuit-break (line $_AHEAD_DEAD_LN) — never reaches that decision for a pool author"
else
  bad "pool intercept is not positioned before the ahead_dead circuit-break (intercept=$_POOL_INTERCEPT_LN ahead_dead=$_AHEAD_DEAD_LN)"
fi
if [ -n "$_POOL_INTERCEPT_LN" ] && [ -n "$_BEHIND_ACTION_LN" ] && [ "$_POOL_INTERCEPT_LN" -lt "$_BEHIND_ACTION_LN" ]; then
  ok "AC1: pool intercept (line $_POOL_INTERCEPT_LN) runs BEFORE gate_behind_envelope_action (line $_BEHIND_ACTION_LN) — never reaches that decision for a pool author"
else
  bad "pool intercept is not positioned before gate_behind_envelope_action (intercept=$_POOL_INTERCEPT_LN behind=$_BEHIND_ACTION_LN)"
fi

echo "── 13d. AC2/AC3: the pool branch routes via default_pool_route_for_rig and never reuses the collapsing 'dead author'/'no live author' phrasing ──"
_POOL_BLOCK=$(sed -n '/ga-tz0op: REBASE_AUTHOR resolved to a pool\/ephemeral identity/,/Read current rebase-attempt counter from the marker labels/p' "$DISPATCHER")
if [ -z "$_POOL_BLOCK" ]; then
  bad "could not extract the ga-tz0op pool-intercept block — start/end anchor comments missing/renamed?"
else
  if printf '%s\n' "$_POOL_BLOCK" | grep -qF 'default_pool_route_for_rig "${RIG:-}"'; then
    ok "AC2: pool branch routes the source bead via default_pool_route_for_rig (same mechanism as the FAIL-path pool-return, ga-f54ui)"
  else
    bad "AC2: pool branch does not call default_pool_route_for_rig — bead may not become self-serve-visible"
  fi
  if printf '%s\n' "$_POOL_BLOCK" | grep -qF 'bd -C "$BEAD_CITY" assign       "$BEAD_ID" ""'; then
    ok "AC2: pool branch clears the source bead's assignee so a fresh worker can claim it"
  else
    bad "AC2: pool branch does not clear the source bead assignee"
  fi
  _DEAD_AUTHOR_HITS=$(printf '%s\n' "$_POOL_BLOCK" | { grep -c 'dead author' || true; })
  eq "AC3: the pool-intercept block never uses the literal phrase 'dead author' (would collapse pool-origin into the same wording as a genuinely dead named author)" \
    "$_DEAD_AUTHOR_HITS" \
    "0"
  _NO_LIVE_AUTHOR_HITS=$(printf '%s\n' "$_POOL_BLOCK" | { grep -c 'no live author' || true; })
  eq "AC3: the pool-intercept block never uses the literal phrase 'no live author' (same collapsing wording used by the ahead_dead/behind_dead circuit-breaks)" \
    "$_NO_LIVE_AUTHOR_HITS" \
    "0"
  _POOL_PHRASE_HITS=$(printf '%s\n' "$_POOL_BLOCK" | { grep -c 'pool/ephemeral identity' || true; })
  if [ "${_POOL_PHRASE_HITS:-0}" -ge 1 ]; then
    ok "AC3: the pool-intercept block names its own distinct category ('pool/ephemeral identity') instead"
  else
    bad "AC3: the pool-intercept block does not name a distinct category for this identity class"
  fi
fi

echo "── 13e. non-regression: named crew authors still take the EXISTING ahead_dead/behind_dead/bounce paths, untouched ──"
eq "a real crew author ('oracle-wa') is not pool — REBASE_AUTHOR_ALIVE still drives the pre-existing circuit-break/bounce decisions exactly as before ga-tz0op" \
  "$(rebase_author_is_pool "oracle-wa")" \
  "0"
eq "gate_behind_envelope_action is UNCHANGED for a genuinely dead named author (rebase_author_is_pool only adds an earlier intercept, never edits this pure function)" \
  "$(gate_behind_envelope_action "1" "0")" \
  "circuit_break"

# ── 14. ga-ivzbuz: behind-envelope circuit-break has an unreachable ceiling on
#    a high-velocity rig, and treats a normally-exited ad-hoc worker's dead
#    session as "abandoned" with no owner-liveness fallback ─────────────────
# Composed bug: (1) GATE_REBASE_BEHIND_MAX=50 is under 10 hours of branch life
# on a rig doing 90-122 commits/day on main — any branch surviving one gate
# review round-trip trips the circuit-break regardless of code quality; (2) an
# ad-hoc pool worker (wa-worker-adhoc-<hash>) ALWAYS reads as a dead author by
# the time this sweep runs (build, commit, submit /gate-done, exit — the same
# doctrine dogs themselves follow), which the old code could not distinguish
# from a worker that crashed mid-task; (3) the dispatcher had no fallback to
# the bead's OWNER before circuit-breaking, even though the Mayor manually
# rescued the two real cases below by nudging the owner directly. Real
# incident, 2026-08-16: wa-nxwqw (84 behind, owner oracle-wa), wa-983jj (61
# behind, owner thies-wa), wa-zg6xf (89 behind) — 3 branches auto-circuit-
# broken to gate:needs-human in ~40min, all normal ad-hoc submissions.
echo "── 14. ga-ivzbuz: owner-liveness fallback before circuit-break, per-rig behind-ceiling ──"

echo "── 14a. gate_behind_envelope_action: 3rd arg (owner_alive) truth table ──"
eq "not exceeded, dead author, dead owner → not_applicable (unchanged)" \
  "$(gate_behind_envelope_action "0" "0" "0")" \
  "not_applicable"
eq "exceeded, dead author, dead owner → circuit_break (safety net intact — AC3)" \
  "$(gate_behind_envelope_action "1" "0" "0")" \
  "circuit_break"
eq "exceeded, dead author, LIVE owner → bounce_owner (NEW — AC1/AC2, never a bare 'bounce' with the wrong nudge target)" \
  "$(gate_behind_envelope_action "1" "0" "1")" \
  "bounce_owner"
eq "exceeded, LIVE author, dead owner → bounce (author still wins outright — unchanged priority, owner_alive irrelevant when author is alive)" \
  "$(gate_behind_envelope_action "1" "1" "0")" \
  "bounce"
eq "exceeded, LIVE author, LIVE owner → bounce (author priority preserved even when both are alive — never bounce_owner)" \
  "$(gate_behind_envelope_action "1" "1" "1")" \
  "bounce"
eq "2-arg legacy call (owner_alive omitted) → circuit_break, UNCHANGED behavior for any caller not yet passing the 3rd arg" \
  "$(gate_behind_envelope_action "1" "0")" \
  "circuit_break"
eq "garbage owner_alive sanitizes to 0, exceeded=1, dead author → circuit_break (fail-safe, never a phantom rescue)" \
  "$(gate_behind_envelope_action "1" "0" "xx")" \
  "circuit_break"

echo "── 14b. resolve_bead_owner: extracts bd's 'owner' field via the cross-rig-then-HQ-fallback lookup (hermetic, gc stubbed) ──"
# Stub `gc` so this test is hermetic — same spirit as this file's own
# log/warn/err no-op stubs above — scoped to this subsection only.
gc() {
  if [ "$1" = "--city" ] && [ "$3" = "bd" ] && [ "$4" = "show" ] && [ "$5" = "wa-nxwqw-fake" ]; then
    printf '{"owner":"oracle-wa","assignee":"","created_by":""}'
    return 0
  fi
  return 1
}
eq "resolve_bead_owner extracts the 'owner' field from a live gc bd show lookup" \
  "$(resolve_bead_owner "wa-nxwqw-fake")" \
  "oracle-wa"
eq "resolve_bead_owner falls back to \"\" when neither the cross-rig nor HQ lookup resolves the bead (fail-safe, matches resolve_rebase_author's empty-string contract)" \
  "$(resolve_bead_owner "totally-unknown-bead")" \
  ""
eq "resolve_bead_owner(\"\") short-circuits to \"\" without attempting any lookup" \
  "$(resolve_bead_owner "")" \
  ""
unset -f gc

echo "── 14c. drift-guard: OWNER/OWNER_ALIVE actually computed and wired into the 3-arg call ──"
grep -qF 'OWNER=$(resolve_bead_owner "$BEAD_ID")' "$DISPATCHER" \
  && ok "OWNER is actually resolved at the call site (fix wired in, not just defined)" \
  || bad "OWNER resolution missing at call site — resolve_bead_owner() defined but never called"
grep -qF 'OWNER_ALIVE=$(author_is_alive "$OWNER")' "$DISPATCHER" \
  && ok "OWNER_ALIVE computed via the canonical author_is_alive() — same liveness predicate as every other identity in this file" \
  || bad "OWNER_ALIVE computation missing"
grep -qF 'gate_behind_envelope_action "$REBASE_BEHIND_EXCEEDED" "$REBASE_AUTHOR_ALIVE" "$OWNER_ALIVE"' "$DISPATCHER" \
  && ok "call site passes OWNER_ALIVE as the 3rd arg (behavior actually reachable, not just defined)" \
  || bad "call site NOT passing OWNER_ALIVE — gate_behind_envelope_action's 3rd arg is dead code"

echo "── 14d. drift-guard: AC2/gate-fix-2 discipline — bounce_owner nudges OWNER, never REBASE_AUTHOR (which is confirmed dead in this branch) ──"
_BOUNCE_OWNER_BLOCK=$(sed -n '/elif \[ "\$_BEHIND_ACTION" = "bounce_owner" \]; then/,/^    fi$/p' "$DISPATCHER")
if [ -z "$_BOUNCE_OWNER_BLOCK" ]; then
  bad "could not extract the bounce_owner block — anchor text missing/renamed?"
else
  if printf '%s\n' "$_BOUNCE_OWNER_BLOCK" | grep -qF 'gc --city "$GC_CITY" session nudge "$OWNER"'; then
    ok "bounce_owner nudges \$OWNER — the identity actually verified alive for this decision"
  else
    bad "bounce_owner does not nudge \$OWNER — repeats the exact gate-fix-2 signal/target divergence bug"
  fi
  if printf '%s\n' "$_BOUNCE_OWNER_BLOCK" | grep -qF 'session nudge "$REBASE_AUTHOR"'; then
    bad "bounce_owner nudges \$REBASE_AUTHOR — that identity is confirmed DEAD in this branch by construction"
  else
    ok "bounce_owner never nudges the confirmed-dead \$REBASE_AUTHOR"
  fi
  # Matches the actual label-add call shape (e.g. `label add "$BEAD_ID"
  # "gate:needs-human"`), not a bare substring — the block's OWN explanatory
  # prose legitimately mentions the phrase "gate:needs-human" to say what did
  # NOT happen ("nudged instead of parking this on gate:needs-human"), which
  # a plain -F substring match would misfire on.
  if printf '%s\n' "$_BOUNCE_OWNER_BLOCK" | grep -qE 'label +add.*"gate:needs-human'; then
    bad "bounce_owner applies gate:needs-human — defeats AC1 (must NOT circuit-break when owner is live)"
  else
    ok "bounce_owner never applies gate:needs-human (AC1: does not park on the human path when owner is live)"
  fi
fi

echo "── 14e. End-to-end: the two real 2026-08-16 incidents now bounce to their owner instead of circuit-breaking (AC1, AC2 'provado com os dois casos') ──"
_WA_NXWQW_ACTION=$(gate_behind_envelope_action "1" "0" "1")
eq "wa-nxwqw shape (84 behind, dead ad-hoc author, live owner oracle-wa) → bounce_owner, not circuit_break" \
  "$_WA_NXWQW_ACTION" \
  "bounce_owner"
_WA_983JJ_ACTION=$(gate_behind_envelope_action "1" "0" "1")
eq "wa-983jj shape (61 behind, dead ad-hoc author, live owner thies-wa) → bounce_owner, not circuit_break — SAME code path proves both cases (AC2)" \
  "$_WA_983JJ_ACTION" \
  "bounce_owner"
_WA_ZG6XF_NO_OWNER_ACTION=$(gate_behind_envelope_action "1" "0" "0")
eq "wa-zg6xf shape, IF no live owner either (worst case) → circuit_break still fires — AC3 safety net is not weakened by this fix" \
  "$_WA_ZG6XF_NO_OWNER_ACTION" \
  "circuit_break"

echo "── 14f. GATE_REBASE_BEHIND_MAX per-rig ceiling: behavioral test executing the REAL shipped case-statement (not a re-typed copy) ──"
_CEILING_BLOCK=$(sed -n '/^  case "\${RIG:-}" in$/,/^  esac$/p' "$DISPATCHER")
if [ -z "$_CEILING_BLOCK" ]; then
  bad "could not extract the ga-ivzbuz per-rig ceiling case-statement — anchor text missing/renamed?"
else
  _CEILING_SCRIPT="$_CEILING_BLOCK"$'\nprintf "%s" "$GATE_REBASE_BEHIND_MAX"'
  _WA_MAX=$(RIG=whatsapp_automation bash -c "$_CEILING_SCRIPT" 2>&1)
  _GASCITY_MAX=$(RIG=gascity bash -c "$_CEILING_SCRIPT" 2>&1)
  _UNMEASURED_MAX=$(RIG=some_future_rig bash -c "$_CEILING_SCRIPT" 2>&1)
  _UNSET_MAX=$(bash -c "$_CEILING_SCRIPT" 2>&1)
  eq "whatsapp_automation ceiling = 400 (3x measured peak 122/day, rounded up to nearest 50)" \
    "$_WA_MAX" "400"
  eq "gascity ceiling = 200 (3x measured peak 56/day, rounded up to nearest 50)" \
    "$_GASCITY_MAX" "200"
  eq "an unmeasured/future rig keeps the ORIGINAL global default (50) — fail-safe, no silent over-permissive default" \
    "$_UNMEASURED_MAX" "50"
  eq "RIG completely unset keeps the original global default (50) — fail-safe" \
    "$_UNSET_MAX" "50"
fi
_ENV_OVERRIDE_MAX=$(RIG=whatsapp_automation GATE_REBASE_BEHIND_MAX=999 bash -c "${_CEILING_BLOCK}"$'\nprintf "%s" "$GATE_REBASE_BEHIND_MAX"' 2>&1)
eq "an explicit GATE_REBASE_BEHIND_MAX env var still overrides the per-rig default (operator escape hatch preserved)" \
  "$_ENV_OVERRIDE_MAX" \
  "999"

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 1
fi

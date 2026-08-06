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

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-rebase-liveness selftest"
  exit 1
fi

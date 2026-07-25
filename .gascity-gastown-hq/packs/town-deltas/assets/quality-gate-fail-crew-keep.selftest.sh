#!/usr/bin/env bash
# quality-gate-fail-crew-keep.selftest.sh — Prove the ga-jyox FAIL-time
# assignee-keep logic in isolation, with NO live Dolt/gc/launchd.
#
# ga-jyox: a gate FAIL used to unconditionally clear the bead's assignee (and
# strip story:in-flight) so the Pilot could re-dispatch a fixer. That is
# correct for an ephemeral pool/adhoc builder (which exits after submitting)
# or a session that has died — but WRONG for a live, long-lived named-crew
# author (e.g. thies-wa): clearing made imparavel-check see "buildable but
# stalled" and the Pilot dispatched a SECOND generic builder onto the SAME
# in-flight branch (ga-1url/ga-u4yi: two builders on one branch destroyed the
# same Fase 2 epic twice in one night).
#
# This harness SOURCES the dispatcher in lib-only mode (GATE_DISPATCHER_LIB_ONLY)
# to unit-test the REAL pure decision function (gate_fail_assignee_action),
# covering both ACEITE cases: live crew → keep; pool/adhoc/dead → clear
# (unchanged from today).
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

# ── Load the REAL helper from the dispatcher (lib-only = no live run) ─────────
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }

type gate_fail_assignee_action >/dev/null 2>&1 \
  || { echo "FATAL: gate_fail_assignee_action not defined by dispatcher (ga-jyox missing?)"; exit 1; }

# Quiet logging noise from sourced helpers.
log()  { :; }
warn() { :; }
err()  { :; }

# ── 1. Live named crew → keep (the ga-jyox fix itself) ───────────────────────
echo "── 1. live named-crew author → keep ──"
eq "session_name form (thies-wa-gam257), alive → keep" \
  "$(gate_fail_assignee_action "thies-wa-gam257" "1")" \
  "keep"
eq "short alias form (digo-wa), alive → keep" \
  "$(gate_fail_assignee_action "digo-wa" "1")" \
  "keep"
eq "gawisp-form (batista-wa-gawispiwq9sj), alive → keep" \
  "$(gate_fail_assignee_action "batista-wa-gawispiwq9sj" "1")" \
  "keep"
eq "ps rig crew (batista-ps-garkj7), alive → keep" \
  "$(gate_fail_assignee_action "batista-ps-garkj7" "1")" \
  "keep"

# ── 2. Named crew but NOT alive → clear (don't regress: dead session) ────────
echo "── 2. named crew, session dead → clear (session must have actually died) ──"
eq "thies-wa-gam257, dead → clear" \
  "$(gate_fail_assignee_action "thies-wa-gam257" "0")" \
  "clear"
eq "digo-wa, dead → clear" \
  "$(gate_fail_assignee_action "digo-wa" "0")" \
  "clear"

# ── 3. Pool/ephemeral builders → ALWAYS clear, regardless of liveness ────────
# (mirrors pilot-dispatcher.sh's _beadid_live_crew_owner deny-list exactly)
echo "── 3. pool/ephemeral builder → always clear (even if 'alive') ──"
eq "gastown.dog (bare alias), alive → clear" \
  "$(gate_fail_assignee_action "gastown.dog" "1")" \
  "clear"
eq "gastown.dog-1 (alias form), alive → clear" \
  "$(gate_fail_assignee_action "gastown.dog-1" "1")" \
  "clear"
eq "dog-gabjtm (real session_name form — confirmed live via gc session list), alive → clear" \
  "$(gate_fail_assignee_action "dog-gabjtm" "1")" \
  "clear"
eq "wa-worker (bare), alive → clear" \
  "$(gate_fail_assignee_action "wa-worker" "1")" \
  "clear"
eq "wa-worker-adhoc-a1b60f0190 (real session_name form), alive → clear" \
  "$(gate_fail_assignee_action "wa-worker-adhoc-a1b60f0190" "1")" \
  "clear"
eq "ps-worker, alive → clear" \
  "$(gate_fail_assignee_action "ps-worker" "1")" \
  "clear"
eq "ps-worker-adhoc-deadbeef, alive → clear" \
  "$(gate_fail_assignee_action "ps-worker-adhoc-deadbeef" "1")" \
  "clear"

# ── 4. mayor sentinel → always clear (routing artifact, never a real author) ─
echo "── 4. mayor routing sentinel → always clear ──"
eq "mayor, alive → clear (never a genuine gate-review author)" \
  "$(gate_fail_assignee_action "mayor" "1")" \
  "clear"
eq "mayor, dead → clear" \
  "$(gate_fail_assignee_action "mayor" "0")" \
  "clear"

# ── 4b. ga-mgrma: Mayor identity → always clear, even though the Mayor's own
#    session is always live. Before this fix, neither "gastown.mayor" nor
#    "gastown__mayor" matched the bare "mayor" sentinel pattern in section 4,
#    so a Mayor-authored gate-fail fell through to the author_alive=1 branch
#    and got "keep" — stranding the bead forever (Mayor delegates all
#    implementation, so it never author-codes the re-fix; the Pilot won't
#    re-dispatch an author-kept bead; the dog pool won't claim a bead assigned
#    to live-mayor). Concrete: ga-tkcam sat kept-assigned to gastown__mayor for
#    110s+ until manually cleared.
echo "── 4b. ga-mgrma: Mayor identity (both resolved forms) → always clear ──"
eq "gastown__mayor (session_name form — what bd's assignee field actually stores), alive → clear" \
  "$(gate_fail_assignee_action "gastown__mayor" "1")" \
  "clear"
eq "gastown.mayor (alias/name form), alive → clear" \
  "$(gate_fail_assignee_action "gastown.mayor" "1")" \
  "clear"
eq "gastown__mayor, dead → clear (unchanged either way)" \
  "$(gate_fail_assignee_action "gastown__mayor" "0")" \
  "clear"

# ── 5. Fail-safe: empty/unresolvable author → clear (today's behavior) ───────
echo "── 5. empty author → clear (fail-safe, matches today's dead-end path) ──"
eq "empty author, alive=1 (shouldn't happen, but fail-safe) → clear" \
  "$(gate_fail_assignee_action "" "1")" \
  "clear"
eq "empty author, alive=0 → clear" \
  "$(gate_fail_assignee_action "" "0")" \
  "clear"

# ── 6. author_alive sanitization: non-numeric/garbage → treated as 0 ─────────
echo "── 6. garbage author_alive input → sanitized to 0 (dead) ──"
eq "named crew, alive='' → clear (sanitized to dead)" \
  "$(gate_fail_assignee_action "thies-wa-gam257" "")" \
  "clear"
eq "named crew, alive='xx' → clear (sanitized to dead)" \
  "$(gate_fail_assignee_action "thies-wa-gam257" "xx")" \
  "clear"

# ── 7. Drift guard: function must still be exported by the dispatcher ────────
echo "── 7. drift guard: gate_fail_assignee_action exported by dispatcher ──"
type gate_fail_assignee_action >/dev/null 2>&1 \
  && ok "gate_fail_assignee_action present in lib-only mode" \
  || bad "gate_fail_assignee_action MISSING from dispatcher lib-only export (drift!)"

# ── 8. Structural guard: the needs-fix FAIL branch actually WIRES the decision
#    in (not just a dead/unused helper), and the needs-human (cap-exhausted)
#    branch is untouched (Pilot already excludes gate:needs-human beads, so no
#    double-dispatch risk there — scope stays minimal, ga-jyox ACEITE only
#    requires the re-dispatchable needs-fix path to change). Uses -F (fixed
#    string) grep against exact, uniquely-occurring snippets — never a
#    file-wide count, since unrelated assign-empty calls exist elsewhere in
#    this file (PASS/story-delivery handoff, NEVERSTARTED recovery) and would
#    make a global count fragile/wrong.
echo "── 8. structural guard: decision function wired into needs-fix FAIL branch ──"
if grep -qF 'GATE_FAIL_ASSIGNEE_ACTION=$(gate_fail_assignee_action "$AUTHOR" "$FAIL_AUTHOR_ALIVE")' "$DISPATCHER"; then
  ok "needs-fix branch calls gate_fail_assignee_action with \$AUTHOR/\$FAIL_AUTHOR_ALIVE"
else
  bad "needs-fix branch does NOT call gate_fail_assignee_action — wiring missing/renamed"
fi
if grep -qF 'bd -C "$BEAD_CITY" assign "$BEAD_ID" "$AUTHOR" 2>/dev/null || true' "$DISPATCHER"; then
  ok "needs-fix 'keep' arm re-asserts assignee to \$AUTHOR"
else
  bad "needs-fix 'keep' arm missing the re-assign-to-\$AUTHOR call"
fi
if grep -qF 'story:in-flight + gate:reviewing (wa-qq33j) and builder assignee cleared. The Pilot will re-dispatch a builder with the GATE-FEEDBACK above.' "$DISPATCHER"; then
  ok "needs-fix 'clear' arm preserves the original unconditional-clear wording verbatim"
else
  bad "needs-fix 'clear' arm's original clear-path wording is missing/changed"
fi
# needs-human (cap-exhausted) branch drift guard: confirm it is UNTOUCHED —
# its own unique comment (ga-5w0hr) must still exist, unconditionally clearing
# regardless of crew liveness (Pilot excludes gate:needs-human beads outright,
# so no double-dispatch risk there; scope intentionally excludes this branch).
if grep -qF 'ga-5w0hr: a needs-human bead has NO active worker' "$DISPATCHER"; then
  ok "needs-human branch (ga-5w0hr) present and untouched by this fix"
else
  bad "needs-human branch (ga-5w0hr) marker missing — branch may have been altered unexpectedly"
fi

# ── 9. ga-7rvyt: 'keep' arm must ALSO strip gc.routed_to + the stale
#    gate:queued label, not just re-assign. Without this, a bead kept
#    in-flight for a live crew author on FAIL still matches routed-pool's
#    `bd ready --metadata-field gc.routed_to=<pool> --unassigned` predicate
#    whenever the NEXT gate-review cycle's Step 5b (quality-gate-guard.sh)
#    transiently blanks the assignee again — gc hook/routed-pool has no
#    live-in-flight-owner guard (unlike Pilot's _filter_candidates), so it
#    re-offers the bead to generic pool workers every ~13min (observed:
#    wa-4s5l9, 3 pool workers in 21min, all correctly stood down but wasted
#    spawns + Dolt churn). The marker was ALREADY closed terminal-FAILED
#    earlier in this same FAIL block, so gate:queued has no live marker
#    behind it either way. Mirrors quality-gate-guard.sh Step 5b's exact
#    `--unset-metadata gc.routed_to` pattern (ga-e7zk7/gt-gwng6).
echo "── 9. ga-7rvyt: 'keep' arm strips gc.routed_to + stale gate:queued ──"
if grep -qF 'bd -C "$BEAD_CITY" update "$BEAD_ID" --unset-metadata gc.routed_to -q 2>/dev/null || true' "$DISPATCHER"; then
  ok "dispatcher strips gc.routed_to somewhere (ga-7rvyt or gt-gwng6 pattern present)"
else
  bad "dispatcher does NOT strip gc.routed_to anywhere — ga-7rvyt fix missing"
fi
# Scope check: the strip must be WIRED INTO the 'keep' arm specifically, not
# merely present elsewhere (e.g. quality-gate-guard.sh's unrelated Step 5b
# call lives in a different file and wouldn't satisfy this). Extract the
# 'keep' arm's body (from its `if` to the matching `else`) and assert both
# new lines appear inside THAT slice.
KEEP_ARM=$(awk '/GATE_FAIL_ASSIGNEE_ACTION" = "keep"/{flag=1} flag{print} /^      else$/{if(flag) exit}' "$DISPATCHER")
if printf '%s' "$KEEP_ARM" | grep -qF 'unset-metadata gc.routed_to'; then
  ok "'keep' arm itself strips gc.routed_to (not just present elsewhere in the file)"
else
  bad "'keep' arm does NOT strip gc.routed_to — fix not wired into the FAIL-keep branch"
fi
if printf '%s' "$KEEP_ARM" | grep -qF 'label remove "$BEAD_ID" "gate:queued"'; then
  ok "'keep' arm removes the stale gate:queued label"
else
  bad "'keep' arm does NOT remove gate:queued — marker was already closed terminal-FAILED above, label would stay stale"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
if [ "$FAIL" = "0" ]; then
  echo "PASS $PASS/$((PASS+FAIL)) — quality-gate-fail-crew-keep selftest"
  exit 0
else
  echo "FAIL $FAIL/$((PASS+FAIL)) — quality-gate-fail-crew-keep selftest"
  exit 1
fi

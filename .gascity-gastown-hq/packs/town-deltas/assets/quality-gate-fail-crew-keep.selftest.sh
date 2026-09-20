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
if grep -qF 'story:in-flight + gate:reviewing (wa-qq33j) cleared. gc.routed_to restored to $_GFAIL_ROUTE so pool workers can self-serve this bead (ga-f54ui) — verified post-write, not assumed: $_GFAIL_ROUTE_OBS; $_GFAIL_ASSIGNEE_OBS; $_GFAIL_STATUS_OBS; $_GFAIL_QUEUED_OBS (ga-39l9z2).' "$DISPATCHER"; then
  ok "needs-fix 'clear' arm reports the OBSERVED assignee-clear state (ga-yd8t6) instead of an unconditional 'assignee cleared' assertion"
else
  bad "needs-fix 'clear' arm no longer reports the observed post-write assignee state — ga-yd8t6 regression"
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
if printf '%s' "$KEEP_ARM" | grep -F 'unset-metadata gc.routed_to' >/dev/null; then
  ok "'keep' arm itself strips gc.routed_to (not just present elsewhere in the file)"
else
  bad "'keep' arm does NOT strip gc.routed_to — fix not wired into the FAIL-keep branch"
fi
if printf '%s' "$KEEP_ARM" | grep -F 'label remove "$BEAD_ID" "gate:queued"' >/dev/null; then
  ok "'keep' arm removes the stale gate:queued label"
else
  bad "'keep' arm does NOT remove gate:queued — marker was already closed terminal-FAILED above, label would stay stale"
fi

# ── 10. ga-f54ui: default_pool_route_for_rig — pure function, every branch ───
# What gc.routed_to should be RESTORED to when a bead returns to the generic
# pool. Mirrors pilot-dispatcher.sh's rig_to_builder()+wa_worker_template()
# composition — bare template names only, never a slot instance.
echo "── 10. ga-f54ui: default_pool_route_for_rig (pure function) ──"
type default_pool_route_for_rig >/dev/null 2>&1 \
  || { echo "FATAL: default_pool_route_for_rig not defined by dispatcher (ga-f54ui missing?)"; exit 1; }
eq "whatsapp_automation (long form) -> wa-worker" \
  "$(default_pool_route_for_rig "whatsapp_automation")" "wa-worker"
eq "wa (short alias) -> wa-worker" \
  "$(default_pool_route_for_rig "wa")" "wa-worker"
eq "property_scrapers (long form) -> ps-worker" \
  "$(default_pool_route_for_rig "property_scrapers")" "ps-worker"
eq "ps (short alias) -> ps-worker" \
  "$(default_pool_route_for_rig "ps")" "ps-worker"
eq "gascity -> gastown.dog" \
  "$(default_pool_route_for_rig "gascity")" "gastown.dog"
eq "gastown -> gastown.dog (default bucket)" \
  "$(default_pool_route_for_rig "gastown")" "gastown.dog"
eq "lexbh -> gastown.dog (default bucket)" \
  "$(default_pool_route_for_rig "lexbh")" "gastown.dog"
eq "marketing -> gastown.dog (default bucket)" \
  "$(default_pool_route_for_rig "marketing")" "gastown.dog"
eq "deacon (not in pilot-dispatcher.sh's own case either) -> gastown.dog (default bucket)" \
  "$(default_pool_route_for_rig "deacon")" "gastown.dog"
eq "unknown/empty rig -> gastown.dog (fail-safe default, never empty output)" \
  "$(default_pool_route_for_rig "")" "gastown.dog"

# ── 11. ga-f54ui: needs-fix 'clear' arm restores gc.routed_to ────────────────
# Signal B (merged-bead-janitor) and quality-gate-guard.sh Step 5b both strip
# gc.routed_to at various points in a bead's gate lifecycle, on the documented
# assumption that "the Pilot will re-dispatch a builder" restores it. This arm
# is exactly the return-to-pool transition that promise depends on — before
# this fix, nothing here ever set the field, so a bead could sit ctx:ready +
# unassigned, invisible to every pool worker's self-serve probe, for as long
# as 13 days (ga-f54ui's own incident: 8 beads same-day, all this shape).
echo "── 11. ga-f54ui: needs-fix 'clear' arm restores gc.routed_to ──"
# Isolate the 'clear'/else arm's own body — same awk-slice technique as
# section 9's KEEP_ARM extraction, continued from the same unique anchor: the
# 'else' this captures is the exact 'else' KEEP_ARM's extraction (section 9)
# stops AT, so the two slices are the true, non-overlapping if/else halves of
# the SAME conditional, not two independently-anchored guesses.
CLEAR_ARM=$(awk '
  /GATE_FAIL_ASSIGNEE_ACTION" = "keep"/ { flag=1 }
  flag==1 && /^      else$/             { flag=2 }
  flag==2                               { print }
  flag==2 && /^      fi$/               { exit }
' "$DISPATCHER")
if [ -z "$CLEAR_ARM" ]; then
  bad "CLEAR_ARM extraction produced nothing — anchor/indentation drifted, cannot verify wiring"
else
  if printf '%s' "$CLEAR_ARM" | grep -F '_GFAIL_ROUTE=$(default_pool_route_for_rig "$RIG")' >/dev/null; then
    ok "'clear' arm computes the restore route via default_pool_route_for_rig"
  else
    bad "'clear' arm does NOT call default_pool_route_for_rig — wiring missing/renamed"
  fi
  if printf '%s' "$CLEAR_ARM" | grep -F -- '--set-metadata "gc.routed_to=$_GFAIL_ROUTE"' >/dev/null; then
    ok "'clear' arm writes gc.routed_to via --set-metadata (key-scoped, not a whole-object replace)"
  else
    bad "'clear' arm does NOT restore gc.routed_to — ga-f54ui fix missing from this arm"
  fi
  if printf '%s' "$CLEAR_ARM" | grep -F 'bd -C "$BEAD_CITY" show "$BEAD_ID" --json 2>/dev/null' >/dev/null; then
    ok "'clear' arm verifies the restore with a post-write read (not just assumed)"
  else
    bad "'clear' arm does NOT verify its own write — error-vs-empty risk (ga-p5q3)"
  fi
  # The verify step's own third-state discipline: a read failure must produce
  # a THIRD, distinguishable observation string — never silently reuse the
  # same text a confirmed mismatch would produce.
  if printf '%s' "$CLEAR_ARM" | grep -F 'UNVERIFIED (post-write read failed' >/dev/null \
     && printf '%s' "$CLEAR_ARM" | grep -F 'NOT $_GFAIL_ROUTE — restore did not stick' >/dev/null; then
    ok "'clear' arm's verify step distinguishes UNVERIFIED (read failed) from a confirmed mismatch"
  else
    bad "'clear' arm's verify step collapses read-failure and confirmed-mismatch into the same observation"
  fi
  # ga-39l9z2 (wa-dnzu0): restoring gc.routed_to alone is NOT sufficient —
  # the worker probe ALSO requires status=open and excludes gate:queued
  # (`bd ready --exclude-label gate:queued`, status checked separately).
  # Before this fix, this arm left status at whatever gate-CLAIM time set it
  # to (in_progress) and never removed gate:queued, so a bead could carry a
  # freshly-restored gc.routed_to and STILL be invisible to every pool
  # worker — confirmed live on wa-dnzu0 (status=in_progress + stale
  # gate:queued, zero open markers, invisible to `bd ready` until a human
  # manually reopened it).
  if printf '%s' "$CLEAR_ARM" | grep -F -- '--status open' >/dev/null; then
    ok "'clear' arm reopens the bead's status once the assignee-clear is confirmed (ga-39l9z2)"
  else
    bad "'clear' arm does NOT reopen status — bead stays in_progress and invisible to \`bd ready\` (ga-39l9z2/wa-dnzu0 regression)"
  fi
  if printf '%s' "$CLEAR_ARM" | grep -F 'label remove "$BEAD_ID" "gate:queued"' >/dev/null; then
    ok "'clear' arm removes the stale gate:queued label once the assignee-clear is confirmed (ga-39l9z2)"
  else
    bad "'clear' arm does NOT remove gate:queued — worker probe's --exclude-label gate:queued hides the bead forever (ga-39l9z2/wa-dnzu0 regression)"
  fi
  # Ordering/gating guard: the status-open + gate:queued-remove writes must
  # sit in the CONFIRMED-empty-assignee branch specifically, not unconditionally
  # — else a bead a different actor just claimed gets corrupted into
  # assigned+in_progress+"open" simultaneously (same hazard section 11's own
  # UNVERIFIED-vs-mismatch check protects against, one level further). Uses
  # line-number bracketing rather than a hand-rolled awk boundary regex (a
  # prior draft of this exact check had an unescaped '[' in its own 'elif'
  # anchor and silently never matched — line numbers are simpler to get
  # right and easier to verify by eye).
  CLEARED_LN=$(printf '%s' "$CLEAR_ARM" | grep -nF '_GFAIL_ASSIGNEE_OBS="assignee=cleared"' | head -1 | cut -d: -f1 || true)
  ELIF_LN=$(printf '%s' "$CLEAR_ARM" | grep -nF 'elif [ "$_GFAIL_CLEAR_RC" = "13" ]' | head -1 | cut -d: -f1 || true)
  STATUS_OPEN_LN=$(printf '%s' "$CLEAR_ARM" | grep -nF -- '--status open' | head -1 | cut -d: -f1 || true)
  QUEUED_RM_LN=$(printf '%s' "$CLEAR_ARM" | grep -nF 'label remove "$BEAD_ID" "gate:queued"' | head -1 | cut -d: -f1 || true)
  if [ -n "$CLEARED_LN" ] && [ -n "$ELIF_LN" ] && [ -n "$STATUS_OPEN_LN" ] && [ -n "$QUEUED_RM_LN" ] \
     && [ "$STATUS_OPEN_LN" -gt "$CLEARED_LN" ] && [ "$STATUS_OPEN_LN" -lt "$ELIF_LN" ] \
     && [ "$QUEUED_RM_LN" -gt "$CLEARED_LN" ] && [ "$QUEUED_RM_LN" -lt "$ELIF_LN" ]; then
    ok "status-open + gate:queued-remove sit between 'assignee=cleared' (line $CLEARED_LN) and the next elif (line $ELIF_LN) — gated on confirmed-empty-assignee, not unconditional (ga-39l9z2)"
  else
    bad "status-open + gate:queued-remove are NOT scoped to the confirmed-empty-assignee branch (cleared=$CLEARED_LN status=$STATUS_OPEN_LN queued=$QUEUED_RM_LN elif=$ELIF_LN) — risk of corrupting a bead a different actor just claimed"
  fi
fi
# Negative control: the needs-human (cap-exhausted) branch must remain
# untouched by this fix — same scope boundary as section 8's own drift guard
# (Pilot excludes gate:needs-human beads outright; no double-dispatch risk).
NEEDS_HUMAN_ARM=$(awk '/PREV_ATTEMPT" -ge "\$GATE_FIX_CAP"/{flag=1} flag{print} /^    else$/{if(flag) exit}' "$DISPATCHER")
if [ -z "$NEEDS_HUMAN_ARM" ]; then
  bad "NEEDS_HUMAN_ARM extraction produced nothing — anchor/indentation drifted, cannot verify scope boundary (would otherwise pass vacuously)"
elif printf '%s' "$NEEDS_HUMAN_ARM" | grep -F 'default_pool_route_for_rig' >/dev/null; then
  bad "needs-human (cap-exhausted) branch unexpectedly calls default_pool_route_for_rig — scope crept beyond ga-f54ui's needs-fix-only ACEITE"
else
  ok "needs-human (cap-exhausted) branch untouched — gc.routed_to restore correctly scoped to the re-dispatchable needs-fix arm only"
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

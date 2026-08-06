#!/usr/bin/env bash
# quality-gate-reconcile.selftest.sh — Prove the ga-tmug gate reconciler logic in
# isolation, with NO live Dolt/gc/launchd.
#
# Bug ga-tmug: a crashed/aborted gate run strands beads forever via two vectors:
#   Vector A — a marker stuck in a TRANSIENT state (gate-status:dispatching from a
#              dead dispatcher, or gate-status:claimed from a dead guard) is never
#              reclaimed because no SINGLE sweep reclaims BOTH past a TTL.
#   Vector B — the guard's `quality-gate:` gate-run bead is left pinned in
#              gate-status:running forever: the dispatcher only drives its OWN
#              `gate-run:` bead to terminal, so the guard's sibling orphans (9 such
#              beads observed live, each with a terminal `passed` sibling).
#
# The fix lives in quality-gate-guard.sh (the guard is an engine INDEPENDENT of
# the dispatcher, and already runs every 120s in-place — so the recovery activates
# with zero deploy steps, avoiding the ga-iwv0 dormant-daemon trap a NEW launchd
# engine would hit). Two pure decision functions drive it:
#   reconcile_marker_action  — Vector A: requeue dispatching→queued / claimed→ready
#                              past TTL, capping re-queues to avoid thrash (→error).
#   reconcile_gaterun_action — Vector B: supersede a running gate-run once its
#                              OWN marker is terminal/gone (keying on the marker —
#                              NOT a bare sibling-terminal check, which would
#                              false-positive on a re-dispatched live run that
#                              shares a source bead with an older failed attempt).
#
# This harness SOURCES the guard for its pure functions (single source of truth,
# no copy-drift) and unit-tests every branch, then DRIFT-GUARDS the real script so
# a future refactor that drops the labels/queries fails loudly. Exit 0 iff every
# assertion holds.

# set -e is intentional: an unexpected command failure in any test helper is a
# harness bug, not a graceful FAIL — we want a hard abort, not silent skips.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$SELF_DIR/quality-gate-guard.sh"
DISPATCHER="$SELF_DIR/quality-gate-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

# ── Load the REAL pure functions from the guard (lib-only mode = no live sweep) ──
GATE_GUARD_LIB_ONLY=1 source "$GUARD" \
  || { echo "FATAL: could not source guard in lib-only mode"; exit 1; }

type reconcile_marker_action  >/dev/null 2>&1 || { echo "FATAL: reconcile_marker_action not defined by guard"; exit 1; }
type reconcile_gaterun_action >/dev/null 2>&1 || { echo "FATAL: reconcile_gaterun_action not defined by guard"; exit 1; }
type dedup_gaterun_action     >/dev/null 2>&1 || { echo "FATAL: dedup_gaterun_action not defined by guard"; exit 1; }
type age_minutes_of           >/dev/null 2>&1 || { echo "FATAL: age_minutes_of not defined by guard"; exit 1; }
type parse_marker_id          >/dev/null 2>&1 || { echo "FATAL: parse_marker_id not defined by guard"; exit 1; }
type classify_inflight_gap1   >/dev/null 2>&1 || { echo "FATAL: classify_inflight_gap1 not defined by guard"; exit 1; }
type classify_parent_gap2     >/dev/null 2>&1 || { echo "FATAL: classify_parent_gap2 not defined by guard"; exit 1; }
type session_matches_author   >/dev/null 2>&1 || { echo "FATAL: session_matches_author not defined by guard (ga-bnu1)"; exit 1; }
type classify_gap2_bugtask_verdict >/dev/null 2>&1 || { echo "FATAL: classify_gap2_bugtask_verdict not defined by guard (ga-4tgga)"; exit 1; }
type gap2_query_active_markers     >/dev/null 2>&1 || { echo "FATAL: gap2_query_active_markers not defined by guard (ga-4tgga)"; exit 1; }
type gap2_marker_for_bead          >/dev/null 2>&1 || { echo "FATAL: gap2_marker_for_bead not defined by guard (ga-4tgga)"; exit 1; }

# ── 0. age_minutes_of must read the bead 'Z' timestamps as UTC (not local) ───
# Regression lock for the TZ bug that made every age negative (off by the host's
# UTC offset), silently disabling all reclaim/abort TTLs. Both args are fixed, so
# the result is deterministic regardless of the host clock or timezone.
echo "── 0. age_minutes_of (UTC parse, TZ-independent) ──"
# 2026-06-05T13:27:29Z = epoch 1780666049; +84m later = now 1780671107.
eq "UTC ts parsed as UTC → +84m"  "$(age_minutes_of '2026-06-05T13:27:29Z' 1780671107)" "84"
eq "same instant → 0m"            "$(age_minutes_of '2026-06-05T13:27:29Z' 1780666049)" "0"
eq "empty timestamp → 0 (safe)"   "$(age_minutes_of '' 1780671107)" "0"

# ── 0b. parse_marker_id — whitespace normalisation (the DRY fix for ga-b92q) ─
# The same description is parsed in two places (guard Step 0b, dispatcher
# supersede_sibling_runs). A divergent sed pattern (' *' vs '[[:space:]]*' and
# presence/absence of trailing tr -d) caused silent mismatch on tab separators
# or trailing whitespace. parse_marker_id is the single canonical implementation.
echo "── 0b. parse_marker_id (whitespace normalisation) ──"
eq "plain id → stripped"           "$(parse_marker_id $'marker_id: ga-abc123\nbranch: foo')" "ga-abc123"
eq "tab separator → stripped"      "$(parse_marker_id $'marker_id:\tga-xyz\nbranch: foo')"   "ga-xyz"
eq "trailing whitespace → stripped" "$(parse_marker_id $'marker_id: ga-tst  \nbranch: foo')" "ga-tst"
eq "tab + trailing space → stripped" "$(parse_marker_id $'marker_id:\tga-tst  \nbranch: foo')" "ga-tst"
eq "no marker_id line → empty"     "$(parse_marker_id $'branch: foo\nauthor: bar')"           ""
eq "empty description → empty"     "$(parse_marker_id '')"                                    ""

# ── 1. Vector A — marker reclaim decision ────────────────────────────────────
# Signature: reconcile_marker_action <status> <age_min> <ttl_min> <count> <max>
echo "── 1. reconcile_marker_action (Vector A: dispatching+claimed reclaim) ──"
eq "dispatching within TTL → skip"            "$(reconcile_marker_action dispatching 10 30 0 3)" "skip"
eq "claimed within TTL → skip"                "$(reconcile_marker_action claimed     29 30 0 3)" "skip"
eq "age == TTL boundary → skip (not >)"       "$(reconcile_marker_action dispatching 30 30 0 3)" "skip"
eq "dispatching past TTL, fresh → requeue:queued" "$(reconcile_marker_action dispatching 31 30 0 3)" "requeue:queued"
eq "claimed past TTL, fresh → requeue:ready"  "$(reconcile_marker_action claimed     31 30 0 3)" "requeue:ready"
eq "dispatching past TTL, count=2<3 → requeue" "$(reconcile_marker_action dispatching 99 30 2 3)" "requeue:queued"
eq "past TTL, count == cap → error (thrash)"  "$(reconcile_marker_action dispatching 99 30 3 3)" "error"
eq "past TTL, count > cap → error"            "$(reconcile_marker_action claimed     99 30 9 3)" "error"
eq "unknown status past TTL → skip (safe)"    "$(reconcile_marker_action queued      99 30 0 3)" "skip"

# ── 1b. ga-cgynn: has_live_companion_run (6th, optional arg) ────────────────
# A dispatcher yield-bounce ("live sibling gate-run already running for this
# branch") is a label-only dispatching→queued touch, which does NOT bump
# updated_at — so a perfectly healthy marker can look "stuck" for 60+ minutes
# to age_min alone. A live companion gate-run (its marker_id: back-reference
# points at this marker) is decisive counter-evidence and must win over BOTH
# the age check and the reclaim-count cap — otherwise the false reclaims
# still accumulate to error and Vector B kills the still-live gate-run next.
echo "── 1b. reconcile_marker_action has_live_companion_run (ga-cgynn) ──"
eq "past TTL but live companion run → skip (not stuck)" \
   "$(reconcile_marker_action dispatching 99 30 0 3 1)" "skip"
eq "past TTL + AT reclaim cap but live companion → skip (not error)" \
   "$(reconcile_marker_action dispatching 99 30 3 3 1)" "skip"
eq "claimed, past TTL, live companion → skip" \
   "$(reconcile_marker_action claimed     99 30 2 3 1)" "skip"
eq "live companion=0 explicit → unchanged (requeues)" \
   "$(reconcile_marker_action dispatching 31 30 0 3 0)" "requeue:queued"
# BACK-COMPAT: the 5-arg form (no has_live_companion_run) must behave EXACTLY
# as the pre-ga-cgynn function — the new skip-override stays inert.
eq "5-arg back-compat: requeue unaffected"  "$(reconcile_marker_action dispatching 31 30 0 3)" "requeue:queued"
eq "5-arg back-compat: error unaffected"    "$(reconcile_marker_action claimed     99 30 3 3)" "error"

# ── 2. Vector B — gate-run reconcile decision ────────────────────────────────
# Signature: reconcile_gaterun_action <age_min> <ttl_min> <marker_active 0|1> \
#                                     [verdict_timeout_min] [reviewers_alive 0|1]
echo "── 2. reconcile_gaterun_action (Vector B: orphan gate-run cleanup) ──"
eq "marker active, young → skip (in-flight)"      "$(reconcile_gaterun_action 5  90 1)" "skip"
eq "marker active, age==TTL → skip (not >)"       "$(reconcile_gaterun_action 90 90 1)" "skip"
eq "marker terminal/gone, young → supersede"      "$(reconcile_gaterun_action 1  90 0)" "supersede:marker"
eq "marker terminal/gone, old → supersede"        "$(reconcile_gaterun_action 999 90 0)" "supersede:marker"
eq "marker active but age>TTL → abort:age"        "$(reconcile_gaterun_action 91 90 1)" "abort:age"
# The killer real-world case (ga-twp8): an orphan whose marker is still
# 'dispatching' must NOT be killed just because a SIBLING attempt failed —
# marker_active=1 protects the possibly-live re-dispatch.
eq "re-dispatch live run (marker active) → skip"  "$(reconcile_gaterun_action 3 90 1)" "skip"
# BACK-COMPAT: the 3-arg form (no verdict_timeout / reviewers_alive) must behave
# EXACTLY as the pre-ga-o57gn function — the new dead-reviewer rule stays inert.
eq "3-arg back-compat: defaults keep old behavior" "$(reconcile_gaterun_action 50 90 1)" "skip"

# ── 2b. ga-o57gn: dead-reviewer zombie rule (5-arg form) ─────────────────────
# Signature adds: <verdict_timeout_min> <reviewers_alive 0|1>. A run still
# RUNNING past verdict-timeout with NO live reviewer = abandoned by a dead
# dispatcher → supersede:dead-reviewers. Both conditions required so a live run
# (which always reaches terminal by verdict-timeout) is never killed.
echo "── 2b. reconcile_gaterun_action dead-reviewer rule (ga-o57gn) ──"
eq "age>verdict-timeout + no reviewer → supersede" "$(reconcile_gaterun_action 46 90 1 45 0)" "supersede:dead-reviewers"
eq "age within verdict-timeout + no reviewer → skip" "$(reconcile_gaterun_action 30 90 1 45 0)" "skip"
eq "age==verdict-timeout boundary (not >) → skip"  "$(reconcile_gaterun_action 45 90 1 45 0)" "skip"
eq "age>verdict-timeout but reviewer ALIVE → skip" "$(reconcile_gaterun_action 50 90 1 45 1)" "skip"
eq "live reviewer past TTL → abort:age (hard cap)" "$(reconcile_gaterun_action 91 90 1 45 1)" "abort:age"
eq "marker terminal beats dead-reviewer rule"      "$(reconcile_gaterun_action 50 90 0 45 0)" "supersede:marker"
eq "dead reviewer past BOTH verdict-timeout+TTL → dead-reviewers wins" "$(reconcile_gaterun_action 99 90 1 45 0)" "supersede:dead-reviewers"

# ── 2c. ga-o57gn (c): dedup decision — ≤1 running gate-run per source-bead ────
# Signature: dedup_gaterun_action <group_count> <is_newest 0|1>. Keep the
# newest run in a marker/source-bead group; supersede stale older siblings.
echo "── 2c. dedup_gaterun_action (ga-o57gn keep-newest dedup) ──"
eq "lone run → keep"                          "$(dedup_gaterun_action 1 1)" "keep"
eq "lone run, is_newest irrelevant → keep"    "$(dedup_gaterun_action 1 0)" "keep"
eq "group of 2, newest → keep"                "$(dedup_gaterun_action 2 1)" "keep"
eq "group of 2, older → supersede:duplicate"  "$(dedup_gaterun_action 2 0)" "supersede:duplicate"
eq "group of 3, older → supersede:duplicate"  "$(dedup_gaterun_action 3 0)" "supersede:duplicate"
eq "group of 0 (ungroupable) → keep (safe)"   "$(dedup_gaterun_action 0 1)" "keep"
eq "non-numeric group_count → keep (safe)"    "$(dedup_gaterun_action x 0)" "keep"

# ── 3. Drift-guard: the guard still wires both vectors into the live sweep ────
echo "── 3. drift-guard: guard implements both reconciler vectors ──"
grep -q 'GATE_GUARD_LIB_ONLY'                "$GUARD" && ok "guard is sourceable in lib-only mode"        || bad "guard missing lib-only guard"
grep -q 'reconcile_marker_action()'          "$GUARD" && ok "guard defines reconcile_marker_action"      || bad "guard missing reconcile_marker_action def"
grep -q 'reconcile_gaterun_action()'         "$GUARD" && ok "guard defines reconcile_gaterun_action"     || bad "guard missing reconcile_gaterun_action def"
# Vector A: unified reclaim must scan BOTH transient states in ONE place.
grep -q 'gate-status:dispatching'            "$GUARD" && ok "guard reclaims dispatching markers"         || bad "guard does not scan dispatching"
grep -q 'gate-status:claimed'                "$GUARD" && ok "guard reclaims claimed markers"             || bad "guard does not scan claimed"
grep -q 'gate-reclaim-count:'                "$GUARD" && ok "guard tracks reclaim-count (thrash cap)"    || bad "guard missing reclaim-count label"
grep -q 'MAX_RECLAIMS'                       "$GUARD" && ok "guard caps re-queues (MAX_RECLAIMS)"        || bad "guard missing MAX_RECLAIMS"
# ga-cgynn: Vector A must not miscount a legitimate sibling-yield bounce as a
# stuck-marker reclaim — a live companion gate-run is decisive counter-evidence.
grep -q 'RUNNING_GATERUN_MARKER_IDS'         "$GUARD" && ok "guard builds RUNNING_GATERUN_MARKER_IDS (companion-liveness index, ga-cgynn)" || bad "guard missing RUNNING_GATERUN_MARKER_IDS"
grep -q 'HAS_LIVE_COMPANION=0'               "$GUARD" && ok "guard computes HAS_LIVE_COMPANION per transient marker"                       || bad "guard missing HAS_LIVE_COMPANION"
grep -q 'reconcile_marker_action "\$T_STATUS" "\$T_AGE" "\$CLAIM_TTL_MINUTES" "\$T_COUNT" "\$MAX_RECLAIMS" "\$HAS_LIVE_COMPANION"' "$GUARD" \
  && ok "guard wires HAS_LIVE_COMPANION into the reconcile_marker_action call (ga-cgynn)" \
  || bad "guard not passing has_live_companion_run into reconcile_marker_action"
[ "$(grep -c 'GATE_RUNS_JSON=\$(bd' "$GUARD")" -eq 1 ] \
  && ok "GATE_RUNS_JSON fetched exactly once (hoisted shared prelude, no duplicate bd round-trip)" \
  || bad "GATE_RUNS_JSON fetch count != 1 (duplicate-fetch regression, or the ga-cgynn hoist was reverted)"
# Vector B: supersede orphans by marker state + keep the age fallback.
# (ga-jhyu: terminal transitions now flow through set_gate_status, which emits
#  the gate-status:superseded/aborted label at runtime — assert the call sites.)
grep -q 'set_gate_status "$GR_ID" "superseded"' "$GUARD" && ok "guard supersedes orphan gate-runs (via set_gate_status)" || bad "guard missing set_gate_status superseded"
grep -q 'set_gate_status "$GR_ID" "aborted"'    "$GUARD" && ok "guard keeps age-TTL abort fallback (via set_gate_status)" || bad "guard missing set_gate_status aborted"
grep -q 'marker_id'                          "$GUARD" && ok "guard keys gate-run cleanup on marker_id"   || bad "guard missing marker_id linkage"
# ── ga-o57gn drift-guards: dead-reviewer zombie sweep + keep-newest dedup ────
grep -q 'dedup_gaterun_action()'             "$GUARD" && ok "guard defines dedup_gaterun_action (ga-o57gn (c))"        || bad "guard missing dedup_gaterun_action def"
grep -q 'GATE_VERDICT_TIMEOUT_MINUTES'       "$GUARD" && ok "guard defines verdict-timeout threshold (dead-reviewer rule)" || bad "guard missing GATE_VERDICT_TIMEOUT_MINUTES"
grep -q 'GATE_ZOMBIE_AGE_MINUTES'            "$GUARD" && ok "guard defines verdict-timeout+margin zombie-age threshold"   || bad "guard missing GATE_ZOMBIE_AGE_MINUTES (merge-window safety margin)"
grep -q 'reviewers_alive_for_run()'          "$GUARD" && ok "guard defines reviewers_alive_for_run helper"            || bad "guard missing reviewers_alive_for_run"
grep -q 'reconcile_gaterun_action "$GR_AGE" "$GATE_RUN_TTL_MINUTES" "$MARKER_ACTIVE" "$GATE_ZOMBIE_AGE_MINUTES" "$REVIEWERS_ALIVE"' "$GUARD" \
  && ok "guard wires zombie-age + reviewers_alive into reconcile call" || bad "guard not passing the dead-reviewer args"
grep -q 'supersede:dead-reviewers)'          "$GUARD" && ok "guard handles supersede:dead-reviewers action"           || bad "guard missing dead-reviewers handler"
grep -q 'dedup_gaterun_action "$_group_count" "$_is_newest"' "$GUARD" && ok "guard runs keep-newest dedup per gate-run" || bad "guard not calling dedup_gaterun_action in the sweep"
grep -q 'supersede:duplicate' "$GUARD" && ok "guard supersedes stale duplicate gate-runs (dedup)" || bad "guard missing supersede:duplicate handler"
# Both new terminal paths must CLOSE the bead (ga-jhyu invariant: terminal ⇒ closed).
[ "$(grep -c 'Closed by guard (ga-o57gn)' "$GUARD")" -ge 2 ] \
  && ok "guard closes dead-reviewer + duplicate gate-runs at terminal (ga-jhyu invariant)" \
  || bad "guard ga-o57gn terminal paths do not both close the gate-run"
grep -q 'date -j -u -f'                      "$GUARD" && ok "guard parses bead timestamps as UTC (-u)"   || bad "guard missing -u (TZ bug regressed)"
# Dispatcher Step 0a (D_EPOCH) + reviewer janitor (R_EPOCH) must ALL parse UTC.
# A bare `grep 'date -j -u -f'` would false-pass (R_EPOCH already has it), so we
# assert the buggy non-UTC form is absent everywhere in the dispatcher (ga-35zp1).
grep -q 'date -j -f "%Y-%m-%dT%H:%M:%S"'     "$DISPATCHER" && bad "dispatcher has a non-UTC BSD date parse (date -j -f without -u — TZ age bug, ga-35zp1)" || ok "dispatcher BSD date parses are all UTC (-u)"
# parse_marker_id: single canonical definition in guard, both scripts converge on it.
grep -q 'parse_marker_id()'                  "$GUARD" && ok "guard defines parse_marker_id (canonical)"   || bad "guard missing parse_marker_id def"
grep -q 'parse_marker_id'                    "$GUARD" && ok "guard Step 0b uses parse_marker_id"          || bad "guard Step 0b not using parse_marker_id"
grep -q 'GATE_GUARD_LIB_ONLY=1.*quality-gate-guard' "$DISPATCHER" \
  && ok "dispatcher sources guard lib for parse_marker_id" \
  || bad "dispatcher not sourcing guard lib (DRY violation)"
grep -q 'parse_marker_id'                    "$DISPATCHER" && ok "dispatcher supersede_sibling_runs uses parse_marker_id" || bad "dispatcher not using parse_marker_id"

# ── 4. drift-guard: dispatcher proactively supersedes the guard's sibling run ─
echo "── 4. drift-guard: dispatcher proactive sibling supersede ──"
grep -q 'supersede_sibling_runs()'           "$DISPATCHER" && ok "dispatcher defines supersede_sibling_runs"        || bad "dispatcher missing supersede_sibling_runs def"
eq "dispatcher calls it on BOTH terminal paths (PASS+FAIL)" \
   "$(grep -c 'supersede_sibling_runs "' "$DISPATCHER")" "2"
grep -q 'set_gate_status "$sibling_id" "superseded"' "$DISPATCHER" && ok "dispatcher supersedes (not deletes) siblings (via set_gate_status)" || bad "dispatcher missing set_gate_status sibling supersede"

# ── 4b. drift-guard: dispatcher retires its OWN gate-run on requeue (ga-fi1dh) ─
# Bug ga-fi1dh: the quota-stop (ga-x3nmz) and dead-reviewer (ga-eqjo) requeue
# branches inside gate_finalize_run() re-queue the MARKER and park the verdict
# bead(s) as REQUEUED, but left $GATE_RUN_ID itself at gate-status:running
# forever. Phase C's `-l gate-status:running` selection query then re-picks the
# SAME bead on its very next sweep, re-reads the now-closed verdict:REQUEUED
# bead as a "received, non-PASS" verdict (gate_collect_verdicts has no case for
# REQUEUED), and terminally FAILs a marker that was re-queued for a legitimate
# retry — confirmed live on gate_run=ga-wisp-yf4wq0
# (fix/ga-268cr-raw-ingestion-hold-labels, 2026-07-18: verdict bead ga-oe1ja
# closed verdict:REQUEUED at 01:58:27Z; the SAME gate-run bead was re-selected
# and FAILed at 02:02:12Z, ~4 minutes later, before the re-queued marker ever
# got its retry). Fix mirrors the exact set_gate_status-supersede idiom
# Section 3/4 above already drift-guard for the guard's Vector B and the
# dispatcher's own sibling-supersede.
echo "── 4b. drift-guard: dispatcher retires GATE_RUN_ID on quota-stop/dead-reviewer requeue (ga-fi1dh) ──"
eq "dispatcher supersedes GATE_RUN_ID in BOTH requeue branches (quota-stop + dead-reviewer)" \
   "$(grep -c 'set_gate_status "$GATE_RUN_ID" "superseded"' "$DISPATCHER")" "2"
eq "dispatcher closes GATE_RUN_ID in BOTH requeue branches (ga-fi1dh)" \
   "$(grep -c 'Closed by dispatcher (ga-fi1dh)' "$DISPATCHER")" "2"
grep -q 'gate-run superseded (terminal) — infra re-queue (ga-eqjo)' "$DISPATCHER" \
  && ok "dead-reviewer requeue branch retires its gate-run bead" \
  || bad "dead-reviewer requeue branch missing gate-run retirement (ga-fi1dh)"
grep -q 'gate-run superseded (terminal) — quota-stop re-queue (ga-x3nmz)' "$DISPATCHER" \
  && ok "quota-stop requeue branch retires its gate-run bead" \
  || bad "quota-stop requeue branch missing gate-run retirement (ga-fi1dh)"

# ── 5. classify_inflight_gap1 (ga-pa36 GAP-1: merged-but-OPEN beads) ─────────
# Signature: classify_inflight_gap1 <status> <has_gate_passed> <has_live_assignee> <branch_merged>
echo "── 5. classify_inflight_gap1 (GAP-1: merged-but-OPEN) ──"
eq "closed bead → already-handled"         "$(classify_inflight_gap1 closed 0 0 1)"   "skip:already-handled"
eq "open+gate:passed → already-handled"    "$(classify_inflight_gap1 open   1 0 1)"   "skip:already-handled"
eq "live builder → safe-skip"              "$(classify_inflight_gap1 open   0 1 1)"   "skip:live-builder"
eq "branch merged, no builder → strip"     "$(classify_inflight_gap1 open   0 0 1)"   "strip:merged"
eq "branch not merged → skip"              "$(classify_inflight_gap1 open   0 0 0)"   "skip:not-merged"
eq "branch state unknown → safe-skip"      "$(classify_inflight_gap1 open   0 0 x)"   "skip:indeterminate"
eq "live builder trumps merged branch"     "$(classify_inflight_gap1 open   0 1 1)"   "skip:live-builder"
eq "already-handled before live check"     "$(classify_inflight_gap1 closed 0 1 1)"   "skip:already-handled"

# ── 6. classify_parent_gap2 (ga-pa36 GAP-2: parent-story stranding) ──────────
# Signature: classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed>
echo "── 6. classify_parent_gap2 (GAP-2: parent-story stranding) ──"
eq "not pilot:dispatched → skip"                       "$(classify_parent_gap2 0 0 1 0 0)"  "skip:not-dispatched"
eq "live assignee on parent → safe-skip"               "$(classify_parent_gap2 1 1 1 0 0)"  "skip:live-assignee"
eq "no sling bead found → safe-skip"                   "$(classify_parent_gap2 1 0 0 0 0)"  "skip:no-sling"
eq "sling gate:needs-fix → free FAIL-stranded"         "$(classify_parent_gap2 1 0 1 1 0)"  "free:fail-stranded"
eq "sling gate:needs-fix beats sling closed"           "$(classify_parent_gap2 1 0 1 1 1)"  "free:fail-stranded"
eq "sling closed (PASS) → free PASS-stranded"          "$(classify_parent_gap2 1 0 1 0 1)"  "free:pass-stranded"
eq "sling still active → skip"                         "$(classify_parent_gap2 1 0 1 0 0)"  "skip:active-sling"

# ── 6b. classify_gap2_bugtask_verdict (ga-4tgga: active-marker wait state) ───
# Signature: classify_gap2_bugtask_verdict <merge_verified> <has_untracked_marker> <has_active_marker>
echo "── 6b. classify_gap2_bugtask_verdict (ga-4tgga: active-marker wait state) ──"
eq "merge verified, no marker → close (baseline unchanged)" \
   "$(classify_gap2_bugtask_verdict 1 0 0)" "close:merge-verified"
eq "merge verified BEATS a co-present active marker"        \
   "$(classify_gap2_bugtask_verdict 1 0 1)" "close:merge-verified"
eq "untracked delivery, no marker → close (baseline unchanged)" \
   "$(classify_gap2_bugtask_verdict 0 1 0)" "close:untracked-delivery"
eq "untracked delivery BEATS a co-present active marker"    \
   "$(classify_gap2_bugtask_verdict 0 1 1)" "close:untracked-delivery"

# FIXTURE (ga-4tgga acceptance criterion 1): sling closed, fix not (yet)
# verified in main, AND an active marker is processing it → wait, don't touch.
GAP4TGGA_FIXTURE="$(classify_gap2_bugtask_verdict 0 0 1)"
eq "FIXTURE: not verified + ACTIVE marker → wait (no label mutation upstream)" \
   "$GAP4TGGA_FIXTURE" "wait:active-marker"

# CONTROL (ga-4tgga acceptance criterion 2): same, but NO active marker → must
# keep reconciling exactly as today (ga-6ync4's value not lost — this is the
# real-orphan case, ga-sb11i.2 / ga-46wq5).
GAP4TGGA_CONTROL="$(classify_gap2_bugtask_verdict 0 0 0)"
eq "CONTROL: not verified + no active marker → keep (today's behavior, unchanged)" \
   "$GAP4TGGA_CONTROL" "keep:merge-not-verified"

# CONTROL 3 (ga-4tgga acceptance criterion 3): FIXTURE and CONTROL MUST differ
# — this distinction is the entire point of the bug.
if [ "$GAP4TGGA_FIXTURE" != "$GAP4TGGA_CONTROL" ]; then
  ok "CONTROL 3: FIXTURE ([$GAP4TGGA_FIXTURE]) and CONTROL ([$GAP4TGGA_CONTROL]) verdicts differ"
else
  bad "CONTROL 3: FIXTURE and CONTROL produced the SAME verdict [$GAP4TGGA_FIXTURE] — the bug is not actually fixed"
fi

eq "has_active_marker omitted (2-arg back-compat call) → same as 0" \
   "$(classify_gap2_bugtask_verdict 0 0)" "keep:merge-not-verified"

# ── 6c. gap2_marker_for_bead (ga-4tgga: label + description dual-signal match) ──
# Signature: gap2_marker_for_bead <active_markers_json> <bead_id>
echo "── 6c. gap2_marker_for_bead (label + description dual-signal match) ──"

GAP2_MARKERS_FIXTURE='[
  {"id":"ga-wisp-aaa","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-ffop9"],"description":"branch: fix/ga-ffop9\nbead_id: ga-ffop9\nauthor: gastown.dog-1"},
  {"id":"ga-wisp-bbb","labels":["type:quality-gate-marker","gate-status:ready"],"description":"branch: fix/ga-xvxvf\nbead_id: ga-xvxvf\nauthor: gastown.dog-2"},
  {"id":"ga-wisp-ccc","labels":["type:quality-gate-marker","gate-status:claimed","source-bead:ga-cjk1j"],"description":"branch: fix/ga-cjk1j-extra\nauthor: mayor"}
]'

eq "matches via source-bead: LABEL (marker already claimed+parked)" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "ga-ffop9")" "ga-wisp-aaa queued"
eq "matches via bead_id: DESCRIPTION line (marker still bare gate-status:ready, no label yet)" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "ga-xvxvf")" "ga-wisp-bbb ready"
eq "matches via source-bead: LABEL even when description carries a DIFFERENT id (sling-vs-parent naming)" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "ga-cjk1j")" "ga-wisp-ccc claimed"
eq "no match for an unrelated bead id" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "ga-e2n96")" ""
eq "substring is NOT a match (ga-ffop9 must not match a ga-ffop9x marker)" \
   "$(gap2_marker_for_bead '[{"id":"ga-wisp-ddd","labels":[],"description":"bead_id: ga-ffop9x"}]' "ga-ffop9")" ""
eq "empty markers list → no match" \
   "$(gap2_marker_for_bead '[]' "ga-ffop9")" ""
eq "empty bead id → no match (fail-safe)" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "")" ""

# ── 7. drift-guard: guard implements both GAP-1 and GAP-2 sweeps ──────────────
echo "── 7. drift-guard: guard implements ga-pa36 GAP-1 + GAP-2 sweeps ──"
grep -q 'classify_inflight_gap1()'  "$GUARD" && ok "guard defines classify_inflight_gap1"  || bad "guard missing classify_inflight_gap1 def"
grep -q 'classify_parent_gap2()'    "$GUARD" && ok "guard defines classify_parent_gap2"    || bad "guard missing classify_parent_gap2 def"
grep -q 'Step 0c.1'                 "$GUARD" && ok "guard implements GAP-1 sweep (Step 0c.1)"  || bad "guard missing Step 0c.1"
grep -q 'Step 0c.2'                 "$GUARD" && ok "guard implements GAP-2 sweep (Step 0c.2)"  || bad "guard missing Step 0c.2"
grep -q 'pilot:dispatched'          "$GUARD" && ok "guard sweeps pilot:dispatched beads (GAP-2)" || bad "guard does not check pilot:dispatched"
grep -q 'Sling task bead'           "$GUARD" && ok "guard parses 'Sling task bead' comment"  || bad "guard missing Sling-task-bead parse"
grep -q 'gate:needs-fix'            "$GUARD" && ok "guard checks gate:needs-fix on sling bead"  || bad "guard missing gate:needs-fix check"
grep -q 'free:fail-stranded'        "$GUARD" && ok "guard handles free:fail-stranded action"    || bad "guard missing free:fail-stranded handler"
grep -q 'free:pass-stranded'        "$GUARD" && ok "guard handles free:pass-stranded action"    || bad "guard missing free:pass-stranded handler"
grep -q 'merge-base --is-ancestor'  "$GUARD" && ok "guard uses merge-base for branch check (GAP-1)" || bad "guard missing merge-base check"
# ga-e2n96: the free:pass-stranded unverified-merge default arm is a PURE
# re-merge signal (sling already gate-passed+closed; no reviewer ever rejected
# anything) — distinct from a real gate failure. It must set its OWN label
# (gate:needs-remerge) additively alongside the legacy gate:needs-fix, so the
# Pilot dispatcher (and any future consumer) can tell "re-submit, no code is
# broken" apart from "a reviewer rejected this, dispatch a fixer".
grep -q 'gate:needs-remerge'        "$GUARD" && ok "guard sets gate:needs-remerge on the pure re-merge arm (ga-e2n96)" || bad "guard missing gate:needs-remerge — re-merge signal still collides with real gate:needs-fix failures"
# Fix: reconcile_marker_action must remove BOTH transient labels before target state (ga-pa36 gate-feedback)
[ "$(grep -c 'label remove.*gate-status:dispatching' "$GUARD")" -ge 2 ] \
  && ok "requeue:ready removes gate-status:dispatching (both transient labels cleared)" \
  || bad "requeue:ready missing label remove gate-status:dispatching — must clear BOTH transients"
[ "$(grep -c 'label remove.*gate-status:claimed' "$GUARD")" -ge 2 ] \
  && ok "requeue:queued removes gate-status:claimed (both transient labels cleared)" \
  || bad "requeue:queued missing label remove gate-status:claimed — must clear BOTH transients"
# Fix: live-builder check must use exact match, not substring contains (ga-pa36 gate-feedback)
! grep -q '| contains(\.' "$GUARD" \
  && ok "live-builder checks use exact match (no substring contains)" \
  || bad "live-builder check still uses substring contains — must use exact match"

# ga-4tgga: GAP-2's bug/task branch must consult an ACTIVE gate marker before
# concluding the parent's fix is abandoned, and must re-check right before the
# risky mutation (race guard) — not just once, up front.
grep -q 'gap2_query_active_markers()' "$GUARD" && ok "guard defines gap2_query_active_markers (ga-4tgga)" || bad "guard missing gap2_query_active_markers def"
grep -q 'gap2_marker_for_bead()'      "$GUARD" && ok "guard defines gap2_marker_for_bead (ga-4tgga)"      || bad "guard missing gap2_marker_for_bead def"
grep -q 'wait:active-marker'          "$GUARD" && ok "guard handles wait:active-marker verdict (ga-4tgga)" || bad "guard missing wait:active-marker handler"
[ "$(grep -c 'gap2_marker_for_bead "' "$GUARD")" -ge 4 ] \
  && ok "Step 0c.2 calls gap2_marker_for_bead at both the pre-search check and the pre-mutation race guard (>=4 call sites)" \
  || bad "expected >=4 gap2_marker_for_bead call sites (pre-search + race-guard, x2 ids each) — the race guard may have been dropped"
grep -q 'race guard' "$GUARD" && ok "guard documents the ga-4tgga race-guard re-check before arming gate:needs-fix" || bad "guard missing the race-guard re-check before arming gate:needs-fix"

echo ""
# ── 7b. session_matches_author (ga-bnu1: GAP-1/GAP-2 false-dead liveness) ────
# Bug ga-bnu1: GAP-1 and GAP-2 each ran their OWN inline session-liveness
# predicate — `any(.; .id == $a or .name == $a)` — instead of the canonical
# (session_name/name/alias/id/agent_name, closed-filtered) match. That inline
# form is doubly broken: `any(.; C)` binds `.` in C to the whole ARRAY (not
# each element — needs `.[]`), so it throws a jq runtime error on any non-
# empty session list; the surrounding `2>/dev/null || echo "uncertain"`
# swallows the crash into a 3rd string neither "alive" nor "dead", which the
# caller's `[ "$MATCH" != "dead" ]` then treats as alive — accidentally
# fail-open, not a real check. And even fixed to iterate, checking only
# .id/.name misses .session_name — the form bd's assignee field actually
# holds for a named-crew author (e.g. "gastown__mayor", whose .name is the
# dotted "gastown.mayor") — the exact ga-ipf6 false-dead class, regressed
# here in a third call site ga-ipf6's unification didn't reach. Real incident:
# GAP-2 (or a sibling reconciler relying on the same empty-assignee/no-live-
# owner signal) let the Pilot redispatch a generic builder onto ga-pyzo three
# times while gastown__mayor's fix was live in the gate pipeline (ga-bnu1).
echo "── 7b. session_matches_author (ga-bnu1: GAP-1/GAP-2 false-dead liveness) ──"

# Fixture mirrors a REAL `gc session list --json` entry for a live named-crew
# session (captured 2026-07-14): .session_name ("gastown__mayor") differs from
# .name/.alias/.id ("gastown.mayor"/"gastown.mayor"/"gh-050"), and a second,
# genuinely closed session to prove the closed-filter still holds.
SESS_FIXTURE='{"sessions":[
  {"session_name":"gastown__mayor","name":"gastown.mayor","alias":"gastown.mayor","agent_name":"gastown.mayor","id":"gh-050","closed":false},
  {"session_name":"peter-wa-ga2gnr","name":"peter-wa","alias":"peter-wa","agent_name":null,"id":"ga2gnr","closed":false},
  {"session_name":"dog-gadead1","name":"dog-gadead1","alias":"gastown.dog-9","agent_name":"gastown.dog","id":"gadead1","closed":true}
]}'

eq "session_name-only match (THE bug: gastown__mayor via .session_name)" \
   "$(session_matches_author "gastown__mayor" "$SESS_FIXTURE")" "1"
eq "name/alias form also matches (gastown.mayor)" \
   "$(session_matches_author "gastown.mayor" "$SESS_FIXTURE")" "1"
eq "id form also matches (gh-050)" \
   "$(session_matches_author "gh-050" "$SESS_FIXTURE")" "1"
eq "closed session does not count as alive" \
   "$(session_matches_author "dog-gadead1" "$SESS_FIXTURE")" "0"
eq "unknown author → dead" \
   "$(session_matches_author "no-such-session" "$SESS_FIXTURE")" "0"
eq "empty author → dead (fail-safe)" \
   "$(session_matches_author "" "$SESS_FIXTURE")" "0"
eq "bare-array session shape also accepted" \
   "$(session_matches_author "gastown__mayor" '[{"session_name":"gastown__mayor","closed":false}]')" "1"

# Mutation-lock: reverting session_matches_author to the old id/name-only jq
# body must turn the FIRST assertion above red — proves this test exercises
# the fixed predicate, not a tautology (mirrors gate-author-alive-predicate-
# unify.selftest.sh's own mutation-testing note for the ga-ipf6 fix).
OLD_BROKEN_MATCH=$(printf '%s' "$SESS_FIXTURE" | jq -r --arg a "gastown__mayor" '
  .sessions // [] |
  if any(.; .id == $a or .name == $a)
  then "alive" else "dead" end
' 2>/dev/null || echo "uncertain")
eq "mutation-lock: the OLD id/name-only predicate does NOT catch the session_name form (uncertain==false-open, not a real match)" \
   "$OLD_BROKEN_MATCH" "uncertain"

# ── 7b-ii. session_matches_author dead-state exclusion (ga-625z4) ───────────
# Bug ga-625z4: `.closed != true` alone is not sufficient — a session can sit
# closed:false in a non-working `state` (asleep/drained/etc) indefinitely.
# GAP-1 safe-skipped forever on exactly this shape: an HQ story bead's
# assignee is the always-live orchestrating owner (gastown__mayor), so
# `.closed` never flips even after the real builder/sling session that did
# the work went dormant and the fix had already landed (ga-eiv38 stuck 13h:
# gate-done marker present, sling bead closed, PR unmerged — GAP-1 kept
# safe-skipping on the Mayor's always-closed:false row).
echo "── 7b-ii. session_matches_author dead-state exclusion (ga-625z4) ──"

eq "closed:false + state:asleep → dead (0), not alive" \
   "$(session_matches_author "gastown__mayor" '{"sessions":[{"session_name":"gastown__mayor","closed":false,"state":"asleep"}]}')" "0"
eq "closed:false + state:drained → dead (0), not alive" \
   "$(session_matches_author "gastown__mayor" '{"sessions":[{"session_name":"gastown__mayor","closed":false,"state":"drained"}]}')" "0"
eq "closed:false + state:active → still alive (1)" \
   "$(session_matches_author "gastown__mayor" '{"sessions":[{"session_name":"gastown__mayor","closed":false,"state":"active"}]}')" "1"
eq "closed:false + state:awake → still alive (1)" \
   "$(session_matches_author "gastown__mayor" '{"sessions":[{"session_name":"gastown__mayor","closed":false,"state":"awake"}]}')" "1"
eq "no state key at all (existing fixture shape) → still alive (1), no regression" \
   "$(session_matches_author "gastown__mayor" "$SESS_FIXTURE")" "1"

# Mutation-lock: reverting to the pre-ga-625z4 body (closed-filter only, no
# state check) must turn the asleep-row assertion above green->wrongly-alive —
# proves this test exercises the state-exclusion, not a tautology.
OLD_STATE_BLIND_MATCH=$(printf '%s' '{"sessions":[{"session_name":"gastown__mayor","closed":false,"state":"asleep"}]}' | jq -e --arg a "gastown__mayor" \
  '[(if type=="array" then . else (.sessions // []) end)[]
     | select(.closed != true)
     | (.session_name, .name, .alias, .id, .agent_name)]
    | map(select(. != null and . != ""))
    | index($a) != null' >/dev/null 2>&1 && echo 1 || echo 0)
eq "mutation-lock: the pre-fix closed-only predicate WOULD wrongly call the asleep row alive" \
   "$OLD_STATE_BLIND_MATCH" "1"

# ── 7c. drift-guard: GAP-1/GAP-2 call the shared predicate, not a reinlined one ──
echo "── 7c. drift-guard: GAP-1/GAP-2 use session_matches_author (ga-bnu1) ──"
grep -q 'session_matches_author()' "$GUARD" && ok "guard defines session_matches_author" || bad "guard missing session_matches_author def"
[ "$(grep -c 'session_matches_author "' "$GUARD")" -ge 2 ] \
  && ok "GAP-1 and GAP-2 both call session_matches_author (>=2 call sites)" \
  || bad "expected >=2 session_matches_author call sites (one per GAP), found fewer"
! grep -q 'any(\.; \.id == \$a or \.name == \$a)' "$GUARD" \
  && ok "the old broken any(.; ...) id/name-only predicate is gone from guard" \
  || bad "guard still contains the old broken any(.; .id==\$a or .name==\$a) predicate"
grep -q 'def dead_states:' "$GUARD" \
  && ok "guard defines a dead_states exclusion list (ga-625z4)" \
  || bad "guard is missing the ga-625z4 dead_states exclusion — GAP-1 will safe-skip forever on asleep/drained assignees again"
grep -q 'dead_states | index(\$s)) == null' "$GUARD" \
  && ok "session_matches_author wires dead_states into its select() (ga-625z4)" \
  || bad "session_matches_author does not filter on dead_states — regression of ga-625z4"
grep -q 'author_is_alive()' "$DISPATCHER" && ok "dispatcher still defines author_is_alive (public contract unchanged)" || bad "dispatcher missing author_is_alive def"
grep -q 'session_matches_author "\$author" "\$sessions_json"' "$DISPATCHER" \
  && ok "dispatcher's author_is_alive delegates to guard's session_matches_author (DRY, ga-bnu1)" \
  || bad "dispatcher's author_is_alive does not delegate to session_matches_author — drift risk"
# The guard-lib source must run BEFORE the LIB_ONLY early-return, or a
# GATE_DISPATCHER_LIB_ONLY caller (this selftest's sibling,
# gate-author-alive-predicate-unify.selftest.sh) never gets
# session_matches_author defined and author_is_alive() dies at call time.
# NOTE: match the early-return's exact `if [ -n "${GATE_DISPATCHER_LIB_ONLY:-}" ]; then`
# form specifically — an unrelated, earlier compound check in this file
# (`[ -n "${GATE_DISPATCHER_LIB_ONLY:-}" ] && [ -z "${GATE_NUDGE_TIMEOUT_FORCE:-}" ]`)
# also references the same var and would otherwise be matched first.
DISP_LIB_ONLY_LINE=$(grep -n 'if \[ -n "\${GATE_DISPATCHER_LIB_ONLY:-}" \]; then' "$DISPATCHER" | head -1 | cut -d: -f1)
DISP_GUARD_SOURCE_LINE=$(grep -n 'GATE_GUARD_LIB_ONLY=1 source' "$DISPATCHER" | head -1 | cut -d: -f1)
if [ -n "$DISP_LIB_ONLY_LINE" ] && [ -n "$DISP_GUARD_SOURCE_LINE" ] && [ "$DISP_GUARD_SOURCE_LINE" -lt "$DISP_LIB_ONLY_LINE" ]; then
  ok "dispatcher sources guard lib BEFORE the GATE_DISPATCHER_LIB_ONLY early-return"
else
  bad "dispatcher sources guard lib AFTER (or missing relative to) the LIB_ONLY early-return — breaks author_is_alive() under GATE_DISPATCHER_LIB_ONLY"
fi

echo ""
# ── 8. ga-jhyu: terminal gate beads are CLOSED (not just relabeled), and
#       set_gate_status leaves EXACTLY ONE gate-status:* label ────────────────
# Bug ga-jhyu: terminal transitions relabeled markers/gate-runs (passed/failed/
# superseded/aborted) but NEVER `bd close`d them — 55+ beads stranded OPEN, then
# promoted to persistent by wisp-compact. Fix (A): close at every terminal site.
# Fix (D): a single set_gate_status() that strips ALL gate-status:* then adds one
# (the legacy remove-then-add leaked dual labels: passed+superseded, done+failed).
echo "── 8. ga-jhyu: close-at-terminal + atomic set_gate_status ──"

# (D) Single source of truth: guard defines set_gate_status; dispatcher inherits
#     it via the guard lib source (same DRY contract as parse_marker_id). No
#     second copy in the dispatcher → impossible to drift.
grep -q 'set_gate_status()'                  "$GUARD"      && ok "guard defines set_gate_status (canonical)"        || bad "guard missing set_gate_status def"
! grep -q '^set_gate_status() {'             "$DISPATCHER" && ok "dispatcher does NOT redefine set_gate_status (DRY, sourced from guard)" || bad "dispatcher redefines set_gate_status — drift risk"
grep -qE 'startswith\("gate-status:"\)'      "$GUARD"      && ok "set_gate_status strips ALL gate-status:* (atomic)"  || bad "set_gate_status not stripping all gate-status:* labels"

# (A) Every terminal transition is followed by a bd close on the SAME id.
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: PASSED'      "$DISPATCHER" && ok "PASS closes the marker"            || bad "PASS path does not close the marker"
grep -q 'close "$GATE_RUN_ID" -r "gate-run terminal: PASSED'       "$DISPATCHER" && ok "PASS closes the gate-run"           || bad "PASS path does not close the gate-run"
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: FAILED'     "$DISPATCHER" && ok "FAIL closes the marker"            || bad "FAIL path does not close the marker"
grep -q 'close "$GATE_RUN_ID" -r "gate-run terminal: FAILED'      "$DISPATCHER" && ok "FAIL closes the gate-run"          || bad "FAIL path does not close the gate-run"
grep -q 'close "$MARKER_ID" -r "Gate marker terminal: SUPERSEDED' "$DISPATCHER" && ok "already-merged closes the marker"  || bad "already-merged path does not close the marker"
grep -q 'close "$sibling_id"'                "$DISPATCHER" && ok "supersede_sibling_runs closes the sibling gate-run"     || bad "sibling supersede does not close the gate-run"
[ "$(grep -c 'close "$GR_ID"' "$GUARD")" -ge 2 ] && ok "guard Vector B closes superseded+aborted gate-runs" || bad "guard Vector B does not close terminal gate-runs (need >=2)"

# (A-invariant) gate-status:error is terminal-FAILED but must stay OPEN so
# gate-health-monitor.py can page a human (ga-piscg). Closing it would blind the
# escalation — assert NO close follows the error transitions.
! grep -A2 'set_gate_status "$T_ID" "error"'     "$GUARD" | grep -q 'close "$T_ID"'     && ok "Vector A error marker NOT closed (gate-health-monitor invariant)"    || bad "Vector A error marker is closed — breaks human paging (ga-piscg)"
! grep -A2 'set_gate_status "$MARKER_ID" "error"' "$GUARD" | grep -q 'close "$MARKER_ID"' && ok "validation-error marker NOT closed (gate-health-monitor invariant)" || bad "validation-error marker is closed — breaks human paging (ga-piscg)"

# (D-unit) EXERCISE set_gate_status with a mock bd: a bead carrying TWO leaked
# gate-status labels must end with exactly ONE (the target), non-gate labels kept.
echo "── 8b. set_gate_status unit-test (mock bd, real fn from guard) ──"
# Run inline (NOT a subshell) so ok/bad update the real PASS/FAIL counters. This
# is the last section; the mock bd is unset immediately after.
GC_CITY=/tmp/ga-jhyu-fake-city
_MOCK_LABELS="gate-status:running gate-status:dispatching other:keepme"
bd() {
  local verb="$3"
  if [ "$verb" = "show" ]; then
    local arr="" l
    for l in $_MOCK_LABELS; do arr="${arr}\"$l\","; done
    printf '[{"labels":[%s]}]' "${arr%,}"
    return 0
  fi
  if [ "$verb" = "label" ]; then
    local op="$4" lbl="$6"
    case "$op" in
      remove) _MOCK_LABELS=$(printf '%s\n' $_MOCK_LABELS | grep -vx "$lbl" | tr '\n' ' ' || true) ;;
      add)    printf '%s\n' $_MOCK_LABELS | grep -qx "$lbl" || _MOCK_LABELS="$_MOCK_LABELS $lbl" ;;
    esac
    return 0
  fi
  return 0
}
set_gate_status fake-bead passed
_n=$(printf '%s\n' $_MOCK_LABELS | grep -c '^gate-status:' || true)
eq "exactly ONE gate-status:* label after transition" "$_n" "1"
printf '%s\n' $_MOCK_LABELS | grep -qx 'gate-status:passed' && ok "surviving gate-status label is the target (passed)" || bad "target label gate-status:passed missing after transition"
printf '%s\n' $_MOCK_LABELS | grep -qx 'other:keepme'       && ok "non-gate-status labels left untouched"            || bad "set_gate_status clobbered a non-gate-status label"
unset -f bd

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

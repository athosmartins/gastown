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
type companion_liveness_from_query >/dev/null 2>&1 || { echo "FATAL: companion_liveness_from_query not defined by guard (ga-qj1xh)"; exit 1; }
type age_minutes_of           >/dev/null 2>&1 || { echo "FATAL: age_minutes_of not defined by guard"; exit 1; }
type parse_marker_id          >/dev/null 2>&1 || { echo "FATAL: parse_marker_id not defined by guard"; exit 1; }
type classify_inflight_gap1   >/dev/null 2>&1 || { echo "FATAL: classify_inflight_gap1 not defined by guard"; exit 1; }
type classify_parent_gap2     >/dev/null 2>&1 || { echo "FATAL: classify_parent_gap2 not defined by guard"; exit 1; }
type session_matches_author   >/dev/null 2>&1 || { echo "FATAL: session_matches_author not defined by guard (ga-bnu1)"; exit 1; }
type classify_gap2_bugtask_verdict >/dev/null 2>&1 || { echo "FATAL: classify_gap2_bugtask_verdict not defined by guard (ga-4tgga)"; exit 1; }
type gap2_query_active_markers     >/dev/null 2>&1 || { echo "FATAL: gap2_query_active_markers not defined by guard (ga-4tgga)"; exit 1; }
type gap2_marker_for_bead          >/dev/null 2>&1 || { echo "FATAL: gap2_marker_for_bead not defined by guard (ga-4tgga)"; exit 1; }
type gap2_arm_needs_remerge        >/dev/null 2>&1 || { echo "FATAL: gap2_arm_needs_remerge not defined by guard (ga-4tgga attempt 3)"; exit 1; }
type gap2_apply_pass_verdict       >/dev/null 2>&1 || { echo "FATAL: gap2_apply_pass_verdict not defined by guard (ga-1un0n)"; exit 1; }
type gap2_refused_token            >/dev/null 2>&1 || { echo "FATAL: gap2_refused_token not defined by guard (ga-eu75w)"; exit 1; }
type gap2_free_refused_stranded    >/dev/null 2>&1 || { echo "FATAL: gap2_free_refused_stranded not defined by guard (ga-eu75w)"; exit 1; }
type open_verdict_ids_from_json    >/dev/null 2>&1 || { echo "FATAL: open_verdict_ids_from_json not defined by guard (ga-g4m18)"; exit 1; }

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

# ── 1c. companion_liveness_from_query (ga-qj1xh: shared query-failure fail-safe) ──
# Bug ga-qj1xh (Mayor, live, Dolt at 215% CPU / 3-dog boot burst): the guard's
# shared GATE_RUNS_JSON prelude fetch used `2>/dev/null || echo "[]"`, so a
# FAILED query (Dolt timeout/contention) collapsed to "zero gate-runs running"
# — indistinguishable from a genuinely empty result. RUNNING_GATERUN_MARKER_IDS
# is built from that same JSON, so has_live_companion_run silently read false
# for EVERY marker on a failed sweep, even one with a real, live companion gate-
# run — reintroducing the exact false-reclaim/error ga-cgynn's companion-
# liveness check (section 1b above) exists to prevent, sourced from the query
# meant to feed it. companion_liveness_from_query is the extracted pure
# decision: signature <query_ok: 0|1> <marker_found_running: 0|1>. Three cases,
# matching the bug's own acceptance criteria verbatim (irmão existe / irmão não
# existe / consulta falhou):
echo "── 1c. companion_liveness_from_query (ga-qj1xh: query-failure fail-safe) ──"
eq "irmão existe: query ok, marker found running → 1 (has companion)" \
   "$(companion_liveness_from_query 1 1)" "1"
eq "irmão não existe: query ok, marker NOT found running → 0 (no companion, proceed normally)" \
   "$(companion_liveness_from_query 1 0)" "0"
eq "consulta falhou: query FAILED, marker found (stale data) → 1 (fail-safe, never trust a failed query's body)" \
   "$(companion_liveness_from_query 0 1)" "1"
eq "consulta falhou: query FAILED, marker not found → 1 (fail-safe — 'not found' is meaningless when the query itself failed)" \
   "$(companion_liveness_from_query 0 0)" "1"
# THE regression this guards: on failure, the OLD code's implicit default was
# always 0 (via `HAS_LIVE_COMPANION=0; if <lookup succeeds>; then =1; fi` — a
# failed query makes the lookup fail too, so it silently stayed 0). Assert the
# fixed direction explicitly so a future refactor that reverts to that default
# fails loudly here, not live against Dolt under load.
FAILED_QUERY_RESULT=$(companion_liveness_from_query 0 0)
if [ "$FAILED_QUERY_RESULT" = "1" ]; then
  ok "REGRESSION GUARD: query failure never defaults to has_live_companion_run=0"
else
  bad "REGRESSION: query failure produced has_live_companion_run='$FAILED_QUERY_RESULT' — the ga-qj1xh bug is back (a failed query would fire false reclaim/error against a possibly-live marker)"
fi

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

# ── 2d. open_verdict_ids_from_json (ga-g4m18: verdict cascade-close projection) ──
# Signature: open_verdict_ids_from_json <verdict_beads_json>. Pure projection
# over the same JSON shape reviewers_alive_for_run already fetches (`bd list
# --json --all -l type:quality-gate-verdict -l gate-run:<id>`): return the ids
# of every NOT-closed bead, one per line. This is the pure half of the
# ga-g4m18 fix — Vector B's supersede:dead-reviewers case now calls the live
# wrapper (close_dead_reviewer_verdicts, below the lib-only cutoff, so it is
# drift-guarded via grep in section 3 instead of sourced here) to actually
# close what this function says is still open.
echo "── 2d. open_verdict_ids_from_json (ga-g4m18: verdict cascade-close projection) ──"

GA_G4M18_MIXED='[
  {"id":"ga-verdict-open1","status":"open"},
  {"id":"ga-verdict-inprog1","status":"in_progress"},
  {"id":"ga-verdict-closed1","status":"closed"}
]'
eq "mixed open+in_progress+closed → only the two non-closed ids" \
   "$(open_verdict_ids_from_json "$GA_G4M18_MIXED" | sort | tr '\n' ',')" \
   "ga-verdict-inprog1,ga-verdict-open1,"
eq "all-closed → empty (nothing left to cascade-close)" \
   "$(open_verdict_ids_from_json '[{"id":"ga-v1","status":"closed"},{"id":"ga-v2","status":"closed"}]')" ""
eq "empty array → empty" \
   "$(open_verdict_ids_from_json '[]')" ""
eq "single open bead → exactly that id" \
   "$(open_verdict_ids_from_json '[{"id":"ga-solo","status":"open"}]')" "ga-solo"
eq "missing status field → treated as non-closed (fail-safe: cascade-close, don't strand)" \
   "$(open_verdict_ids_from_json '[{"id":"ga-nostat"}]')" "ga-nostat"
eq "malformed JSON → empty (fail-safe: never guess ids out of garbage)" \
   "$(open_verdict_ids_from_json 'not-json')" ""

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
grep -q 'companion_liveness_from_query "\$GATE_RUNS_QUERY_OK" "\$_T_MARKER_FOUND"' "$GUARD" \
  && ok "guard computes HAS_LIVE_COMPANION via companion_liveness_from_query (ga-qj1xh)" \
  || bad "guard missing HAS_LIVE_COMPANION computation (or reverted to the pre-ga-qj1xh literal-0-default)"
grep -q 'reconcile_marker_action "\$T_STATUS" "\$T_AGE" "\$CLAIM_TTL_MINUTES" "\$T_COUNT" "\$MAX_RECLAIMS" "\$HAS_LIVE_COMPANION"' "$GUARD" \
  && ok "guard wires HAS_LIVE_COMPANION into the reconcile_marker_action call (ga-cgynn)" \
  || bad "guard not passing has_live_companion_run into reconcile_marker_action"
[ "$(grep -c 'GATE_RUNS_JSON=\$(bd' "$GUARD")" -eq 1 ] \
  && ok "GATE_RUNS_JSON fetched exactly once (hoisted shared prelude, no duplicate bd round-trip)" \
  || bad "GATE_RUNS_JSON fetch count != 1 (duplicate-fetch regression, or the ga-cgynn hoist was reverted)"
# ── ga-qj1xh drift-guards: the shared gate-runs fetch fails safe, not silent ──
grep -q 'companion_liveness_from_query()'    "$GUARD" && ok "guard defines companion_liveness_from_query (ga-qj1xh)" || bad "guard missing companion_liveness_from_query def"
grep -qE 'if GATE_RUNS_JSON=\$\(bd .* list' "$GUARD" \
  && ok "GATE_RUNS_JSON fetch captures bd's exit status via if/then (not '|| echo \"[]\"' masking)" \
  || bad "GATE_RUNS_JSON fetch no longer uses the if/then rc-capture idiom — may have reverted to error/empty conflation (ga-qj1xh)"
grep -q 'GATE_RUNS_QUERY_OK=1'               "$GUARD" && ok "guard sets GATE_RUNS_QUERY_OK=1 on fetch success"  || bad "guard missing GATE_RUNS_QUERY_OK success branch"
grep -q 'GATE_RUNS_QUERY_OK=0'               "$GUARD" && ok "guard sets GATE_RUNS_QUERY_OK=0 on fetch failure"  || bad "guard missing GATE_RUNS_QUERY_OK failure branch"
grep -q 'gate-runs query failed'             "$GUARD" && ok "guard logs a warning when the shared gate-runs query fails (ga-qj1xh: 'loga que não pode decidir')" || bad "guard does not log the gate-runs query failure — silent fail-safe is still a silent failure"
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

# ── ga-g4m18 drift-guards: verdict-bead cascade-close on dead-reviewer supersede ──
# Bug ga-g4m18: reviewers_alive_for_run confirms every OPEN verdict bead for a
# gate-run is assigned to a dead session right before this branch runs, and
# Vector B supersedes+closes the gate-run bead itself here — but never
# touched those verdict beads, which sat open+in_progress, assigned to a
# ghost session, indefinitely (ga-ydf9v/ga-z8erc, hand-closed by the Mayor as
# a one-off). The pure projection (open_verdict_ids_from_json) is unit-tested
# directly in section 2d above; this section drift-guards the live wiring.
echo "── ga-g4m18 drift-guards: verdict cascade-close on dead-reviewer supersede ──"
grep -q 'open_verdict_ids_from_json()'   "$GUARD" && ok "guard defines open_verdict_ids_from_json (pure projection, ga-g4m18)" || bad "guard missing open_verdict_ids_from_json def"
grep -q 'close_dead_reviewer_verdicts()' "$GUARD" && ok "guard defines close_dead_reviewer_verdicts (I/O wrapper, ga-g4m18)"    || bad "guard missing close_dead_reviewer_verdicts def"

eq "close_dead_reviewer_verdicts has exactly ONE call site in the guard" \
   "$(grep -c 'close_dead_reviewer_verdicts "\$GR_ID"' "$GUARD")" "1"

# ACCEPTANCE CRITERIA (ga-g4m18): (1) a verdict bead whose run IS superseded
# via dead-reviewers gets cascade-closed in the same pass; (2) a verdict bead
# belonging to a run that is NOT dead is never touched by this path. Combined
# with the single-call-site count above, proving that ONE call site lives
# inside the supersede:dead-reviewers) arm (bounded by its own ;;) is
# sufficient to prove BOTH — there is nowhere else in the file left for a
# second call site to hide, so it structurally cannot also fire from
# supersede:marker)/abort:age)/skip).
G4M18_DEAD_ARM=$(sed -n '/supersede:dead-reviewers)/,/;;/p' "$GUARD")
printf '%s\n' "$G4M18_DEAD_ARM" | grep -q 'close_dead_reviewer_verdicts "\$GR_ID"' \
  && ok "the single call site lives INSIDE the supersede:dead-reviewers arm (acceptance criteria 1+2)" \
  || bad "close_dead_reviewer_verdicts is not called inside supersede:dead-reviewers) — ga-g4m18 acceptance criteria not met"

# Mutation-lock (CLAUDE.md rule: a test that only passes proves nothing — run
# it against the pre-fix shape too). A scratch copy of the guard with the
# cascade-close call site stripped out must make the SAME detection logic
# above report "missing" — proving the checks exercise live wiring, not just
# vacuously grep the file.
MUT_G4M18="$(mktemp)"
grep -v 'close_dead_reviewer_verdicts "\$GR_ID"' "$GUARD" > "$MUT_G4M18"
MUT_G4M18_DEAD_ARM=$(sed -n '/supersede:dead-reviewers)/,/;;/p' "$MUT_G4M18")
if printf '%s\n' "$MUT_G4M18_DEAD_ARM" | grep -q 'close_dead_reviewer_verdicts "\$GR_ID"'; then
  bad "mutation-test: stripping the call site did not make the detection logic go red — the check above may be vacuous"
else
  ok "mutation-test: stripping the call site correctly flips the detection logic red — the check above is not vacuous"
fi
rm -f "$MUT_G4M18"
# NOTE: close_dead_reviewer_verdicts itself (the I/O wrapper, live-only —
# calls bd-list-cached.sh + bd close/comment) is intentionally NOT sourced
# or behaviorally exercised here, matching its siblings reviewers_alive_
# for_run/verdict_bead_count_for_run immediately above it in the guard:
# all three are defined past the GATE_GUARD_LIB_ONLY cutoff (line ~1207,
# "load PURE functions" by design) and so are unavailable to a lib-only
# source — the file's own established convention tests that category via
# drift-guard greps only, never a mocked-bd behavioral run. The projection
# it depends on (open_verdict_ids_from_json) sits BEFORE the cutoff
# specifically so it CAN get the stronger, behaviorally-exercised test
# (section 2d above).

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

# ── 5b. classify_inflight_gap1 "none" (ga-bz4nsi 3rd form: never-branched) ───
# wa-qfb6j (P0): open + story:in-flight + no live assignee + no gate:passed +
# no pilot:dispatched + NO branch ever created. Pre-fix, the caller never even
# reached classify_inflight_gap1 for this shape (it unconditionally hardcoded
# `continue` on empty branch search) — so "none" used to fall through this
# function's own `*` case as skip:indeterminate too. Locking strip:no-branch
# as a THIRD, distinct outcome from skip:not-merged is the regression this
# guards: collapsing the two would either abandon a bead whose branch is
# genuinely still being built (skip:not-merged's job) or permanently ignore a
# bead that never started (strip:no-branch's job).
echo "── 5b. classify_inflight_gap1 'none' — never-branched (ga-bz4nsi) ──"
eq "no branch ever created, no live builder → strip:no-branch"  "$(classify_inflight_gap1 open   0 0 none)" "strip:no-branch"
eq "live builder still wins over 'none'"                        "$(classify_inflight_gap1 open   0 1 none)" "skip:live-builder"
eq "closed still wins over 'none'"                               "$(classify_inflight_gap1 closed 0 0 none)" "skip:already-handled"
eq "gate:passed still wins over 'none'"                          "$(classify_inflight_gap1 open   1 0 none)" "skip:already-handled"
eq "'none' is NOT the same outcome as not-merged (0)" "$(classify_inflight_gap1 open 0 0 none)" "strip:no-branch"
[ "$(classify_inflight_gap1 open 0 0 0)" != "$(classify_inflight_gap1 open 0 0 none)" ] \
  && ok "skip:not-merged and strip:no-branch are distinct outcomes (a real building branch is never released)" \
  || bad "REGRESSION: 'not merged yet' and 'never branched' collapsed to the same outcome — would abandon real in-progress work"

# ── 6. classify_parent_gap2 (ga-pa36 GAP-2: parent-story stranding) ──────────
# Signature: classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed> [sling_refused]
echo "── 6. classify_parent_gap2 (GAP-2: parent-story stranding) ──"
eq "not pilot:dispatched → skip"                       "$(classify_parent_gap2 0 0 1 0 0)"  "skip:not-dispatched"
eq "live assignee on parent → safe-skip"               "$(classify_parent_gap2 1 1 1 0 0)"  "skip:live-assignee"
eq "no sling bead found → safe-skip"                   "$(classify_parent_gap2 1 0 0 0 0)"  "skip:no-sling"
eq "sling gate:needs-fix → free FAIL-stranded"         "$(classify_parent_gap2 1 0 1 1 0)"  "free:fail-stranded"
eq "sling gate:needs-fix beats sling closed"           "$(classify_parent_gap2 1 0 1 1 1)"  "free:fail-stranded"
eq "sling closed (PASS) → free PASS-stranded"          "$(classify_parent_gap2 1 0 1 0 1)"  "free:pass-stranded"
eq "sling still active → skip"                         "$(classify_parent_gap2 1 0 1 0 0)"  "skip:active-sling"
# ga-eu75w: the 5-arg calls above (no 6th positional) are the pre-existing
# call shape — this section passing unchanged with sling_refused implicitly
# defaulting to 0 IS the backward-compatibility proof.

# ── 6-refused (ga-eu75w GAP-2: a worker refusal is not a gate-pass) ──────────
# Bug (Mayor, 2026-08-07, same night, 3x — ga-1ztxb/ga-6bghe/ga-aw0db/ga-avvu2):
# "sling closed + no gate:needs-fix" used to be read as "gate-passed", silently
# conflating an explicit pool:refused[:reason] worker refusal — which never
# reached a gate review at all — with a genuine pass. GAP-2 then re-armed
# gate:needs-fix + gate:needs-remerge on the parent with no branch and no
# gate-run anywhere, which gate-orphaned-label-watchdog.sh flagged forever.
echo "── 6-refused. classify_parent_gap2 sling_refused (ga-eu75w) ──"
eq "sling closed via refusal → free REFUSED-stranded, NOT pass-stranded" \
   "$(classify_parent_gap2 1 0 1 0 1 1)" "free:refused-stranded"
eq "sling closed, explicitly not refused → free PASS-stranded (unchanged)" \
   "$(classify_parent_gap2 1 0 1 0 1 0)" "free:pass-stranded"
eq "refused but sling still OPEN (not closed) → skip (inflight-reclaim-guard.py owns that window)" \
   "$(classify_parent_gap2 1 0 1 0 0 1)" "skip:active-sling"
eq "ACCEPTANCE CRITERION: genuine gate-FAIL beats a coincidental refused signal" \
   "$(classify_parent_gap2 1 0 1 1 0 1)" "free:fail-stranded"
eq "gate-failed AND closed AND refused all present → fail still wins" \
   "$(classify_parent_gap2 1 0 1 1 1 1)" "free:fail-stranded"
eq "live assignee short-circuits even with a refused sling" \
   "$(classify_parent_gap2 1 1 1 0 1 1)" "skip:live-assignee"

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
# ga-4tgga gate-feedback (secondary, non-blocking): a dotted sub-bead id in
# the QUERY used to be spliced unescaped into a jq regex — its "." matched
# ANY character, so querying for ga-sb11i.2 could false-match an unrelated
# marker whose description says ga-sb11iX2 (dotted sub-bead IDs like
# ga-sb11i.2 are a real, live id shape in this city — verified via bd list).
eq "dotted bead id in QUERY does not wildcard-match an unrelated marker (ga-sb11i.2 vs ga-sb11iX2)" \
   "$(gap2_marker_for_bead '[{"id":"ga-wisp-eee","labels":[],"description":"bead_id: ga-sb11iX2"}]' "ga-sb11i.2")" ""
eq "dotted bead id still matches its OWN exact marker (no false negative from the fix)" \
   "$(gap2_marker_for_bead '[{"id":"ga-wisp-fff","labels":[],"description":"bead_id: ga-sb11i.2"}]' "ga-sb11i.2")" "ga-wisp-fff unknown"
eq "empty markers list → no match" \
   "$(gap2_marker_for_bead '[]' "ga-ffop9")" ""
eq "empty bead id → no match (fail-safe)" \
   "$(gap2_marker_for_bead "$GAP2_MARKERS_FIXTURE" "")" ""

# ── 6d. gap2_query_active_markers (ga-4tgga gate-feedback: --status open) ───
# Signature: gap2_query_active_markers (no args; reads $GC_CITY, calls bd list)
# Exercises the REAL, unmodified function against a mock `bd` (same technique
# as section 8b below) so this is a behavioral proof the --status open flag
# is actually IN the invocation, not just documented as intended. Fixture:
# two markers both pass the label filter (type:quality-gate-marker,
# gate-status:queued) — one genuinely open, one CLOSED. bd close never
# touches labels, so a marker closed as superseded/duplicate can keep a
# stale non-terminal gate-status label forever — this is the live-verified
# shape (ga-wisp-qiij1x1, closed by the Mayor as superseded, still carries
# gate-status:queued). Correct behavior: only the open one comes back.
echo "── 6d. gap2_query_active_markers (ga-4tgga gate-feedback: --status open) ──"

GAP2_BD_FIXTURE_ALL='[
  {"id":"ga-wisp-open1","status":"open","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-live1"],"description":"bead_id: ga-live1"},
  {"id":"ga-wisp-closed1","status":"closed","labels":["type:quality-gate-marker","gate-status:queued","source-bead:ga-stale1"],"description":"bead_id: ga-stale1"}
]'
GC_CITY=/tmp/ga-4tgga-fake-city
bd() {
  # Mirror the real `bd list --status open` filter server-side, keyed off
  # whether the caller's OWN invocation actually included the flag — this
  # is what makes the test fail if --status open is ever dropped again.
  local verb="$3" args="$*"
  if [ "$verb" = "list" ]; then
    case "$args" in
      *"--status open"*) printf '%s' "$GAP2_BD_FIXTURE_ALL" | jq -c '[.[] | select(.status=="open")]' ;;
      *)                 printf '%s' "$GAP2_BD_FIXTURE_ALL" ;;
    esac
    return 0
  fi
  return 0
}
GAP2_QAM_RESULT=$(gap2_query_active_markers)
unset -f bd

eq "gap2_query_active_markers returns the open marker" \
   "$(printf '%s' "$GAP2_QAM_RESULT" | jq -r '[.[] | select(.id=="ga-wisp-open1")] | length')" "1"
eq "gap2_query_active_markers EXCLUDES the closed-but-mislabeled marker (ga-4tgga gate-feedback blocking issue 1)" \
   "$(printf '%s' "$GAP2_QAM_RESULT" | jq -r '[.[] | select(.id=="ga-wisp-closed1")] | length')" "0"

# Drift-guard companion to the behavioral test above: assert --status open
# is present specifically WITHIN gap2_query_active_markers's own body (not
# merely somewhere else in the file — DUP_MARKERS_JSON already has it, so a
# bare file-wide grep would false-pass even with this call site unfixed).
GAP2_QAM_BODY=$(sed -n '/^gap2_query_active_markers() {/,/^}/p' "$GUARD")
printf '%s' "$GAP2_QAM_BODY" | grep -q -- '--status open' \
  && ok "gap2_query_active_markers's own body filters --status open" \
  || bad "gap2_query_active_markers missing --status open in its own body — closed-but-mislabeled markers will false-positive as active (ga-4tgga gate-feedback)"

# ── 6e. gap2_arm_needs_remerge (ga-4tgga gate-feedback, attempt 3, blocking) ──
# Mayor + reviewer, 2026-08-06: attempt 2's version of this arm POSTED a
# comment claiming "story:in-flight + pilot:dispatched cleared" but never
# made the bd label remove calls that would make it true — the labels
# survived, permanently stranding the bead (invisible to every Pilot
# dispatch query, which all --exclude-label both) while the reconciler kept
# re-selecting it and re-posting the same false claim. A test asserting the
# COMMENT TEXT was posted would have passed with that bug intact — exactly
# how it shipped. This test asserts the ACTUAL bd calls instead: it records
# every call the real, unmodified gap2_arm_needs_remerge() makes against a
# mock bd (same call-recording technique as pilot-dispatcher.selftest.sh and
# gate-marker-status-selfheal.selftest.sh) and checks the label-remove calls
# are actually IN the log, not just the comment.
echo "── 6e. gap2_arm_needs_remerge (ga-4tgga gate-feedback attempt 3: labels must ACTUALLY be removed) ──"

GAP2_ARM_CALLS="$(mktemp)"
GC_CITY=/tmp/ga-4tgga-fake-city
bd() { printf '%s\n' "$*" >> "$GAP2_ARM_CALLS"; return 0; }
gap2_arm_needs_remerge "ga-fake-parent" "ga-fake-sling"
unset -f bd

# Fixed-string matches (grep -F), deliberately — no regex metachars/anchors
# (e.g. \b) whose support varies by grep implementation across environments
# this selftest might run under.
grep -qF -- "-C $GC_CITY label remove ga-fake-parent story:in-flight" "$GAP2_ARM_CALLS" \
  && ok "gap2_arm_needs_remerge actually calls bd label remove ... story:in-flight (not just claims to in the comment)" \
  || bad "gap2_arm_needs_remerge did NOT call bd label remove story:in-flight — bead would be permanently stranded (ga-4tgga attempt 2 regression)"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent pilot:dispatched" "$GAP2_ARM_CALLS" \
  && ok "gap2_arm_needs_remerge actually calls bd label remove ... pilot:dispatched (not just claims to in the comment)" \
  || bad "gap2_arm_needs_remerge did NOT call bd label remove pilot:dispatched — bead would be permanently stranded (ga-4tgga attempt 2 regression)"
grep -qF -- "-C $GC_CITY label add ga-fake-parent gate:needs-fix" "$GAP2_ARM_CALLS" \
  && ok "gap2_arm_needs_remerge still sets gate:needs-fix (unchanged legacy consumer path)" \
  || bad "gap2_arm_needs_remerge dropped gate:needs-fix — legacy consumers would stop seeing this bead"
grep -qF -- "-C $GC_CITY label add ga-fake-parent gate:needs-remerge" "$GAP2_ARM_CALLS" \
  && ok "gap2_arm_needs_remerge still sets gate:needs-remerge (ga-e2n96 distinct re-submit signal)" \
  || bad "gap2_arm_needs_remerge dropped gate:needs-remerge — Pilot would dispatch a builder with an empty brief again (ga-e2n96 regression)"
grep -qF -- "comment ga-fake-parent" "$GAP2_ARM_CALLS" \
  && ok "gap2_arm_needs_remerge still posts its explanatory comment" \
  || bad "gap2_arm_needs_remerge stopped posting a comment — silent label mutation with no audit trail"

# Ordering: the removes must land BEFORE the adds (mirrors close:merge-verified
# / close:untracked-delivery exactly) — strip old status before re-arming new.
GAP2_ARM_REMOVE_LINE=$(grep -nF -- "label remove ga-fake-parent pilot:dispatched" "$GAP2_ARM_CALLS" | head -1 | cut -d: -f1)
GAP2_ARM_ADD_LINE=$(grep -nF -- "label add ga-fake-parent gate:needs-fix" "$GAP2_ARM_CALLS" | head -1 | cut -d: -f1)
if [ -n "$GAP2_ARM_REMOVE_LINE" ] && [ -n "$GAP2_ARM_ADD_LINE" ] && [ "$GAP2_ARM_REMOVE_LINE" -lt "$GAP2_ARM_ADD_LINE" ]; then
  ok "gap2_arm_needs_remerge removes old status labels BEFORE adding new ones"
else
  bad "gap2_arm_needs_remerge ordering wrong (or calls missing) — removes must precede adds, mirroring the close:* arms"
fi
rm -f "$GAP2_ARM_CALLS"

# Drift-guard companion: the case-statement call site must actually invoke
# the function (a correct function that nothing calls is exactly as broken
# as attempt 2, just relocated).
grep -q 'gap2_arm_needs_remerge "\$SC_ID" "\$SLING_ID"' "$GUARD" \
  && ok "Step 0c.2's final re-arm arm actually calls gap2_arm_needs_remerge" \
  || bad "gap2_arm_needs_remerge is defined but the case-statement arm never calls it"

# ── 6f. gap2_refused_token + gap2_free_refused_stranded (ga-eu75w) ───────────
# GAP-2's refused-stranded arm: a sling that closed via an explicit worker
# refusal never reached a gate review, so the parent must not be left with
# (or re-armed with) gate:needs-fix/needs-remerge/queued/failed — the exact
# false state gate-orphaned-label-watchdog.sh flagged forever on ga-1ztxb,
# ga-6bghe, ga-aw0db/ga-avvu2 (same night — Mayor manually cleaned up all three
# by hand, which is what this function now does automatically).
echo "── 6f. gap2_refused_token + gap2_free_refused_stranded (ga-eu75w) ──"

eq "gap2_refused_token: sling's own label (documented ps-worker/wa-worker path)" \
   "$(gap2_refused_token "pool:refused:engine-rebuild-required" "" "")" "pool:refused:engine-rebuild-required"
eq "gap2_refused_token: parent's own label (ga-1ztxb precedent — sling carries no pool:refused label at all)" \
   "$(gap2_refused_token "ctx:ready exec:auto" "pool:refused:engine-rebuild-required" "")" "pool:refused:engine-rebuild-required"
eq "gap2_refused_token: close_reason text only (real ga-0hela shape: neither sling nor parent labeled)" \
   "$(gap2_refused_token "ctx:ready exec:auto" "framework:observability" "pool:refused:engine-rebuild-required — see comment on ga-1ztxb.")" "pool:refused:engine-rebuild-required"
eq "gap2_refused_token: no signal anywhere → empty" \
   "$(gap2_refused_token "gate:needs-fix" "story:in-flight" "gate review failed")" ""

# Mocked-bd() call-recording test (ga-4tgga attempt-2's own lesson, reapplied
# here: a comment that only CLAIMS labels were cleared, without the bd calls
# to back it up, is worse than no comment — assert the ACTUAL calls made).
GAP2_REFUSED_CALLS="$(mktemp)"
GC_CITY=/tmp/ga-eu75w-fake-city
bd() { printf '%s\n' "$*" >> "$GAP2_REFUSED_CALLS"; return 0; }
gap2_free_refused_stranded "ga-fake-parent" "ga-fake-sling" "pool:refused:engine-rebuild-required"
unset -f bd

grep -qF -- "-C $GC_CITY label remove ga-fake-parent gate:needs-fix" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded removes gate:needs-fix" \
  || bad "gap2_free_refused_stranded did NOT remove gate:needs-fix — the false state survives"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent gate:needs-remerge" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded removes gate:needs-remerge" \
  || bad "gap2_free_refused_stranded did NOT remove gate:needs-remerge"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent gate:queued" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded removes gate:queued" \
  || bad "gap2_free_refused_stranded did NOT remove gate:queued"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent gate:failed" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded removes gate:failed" \
  || bad "gap2_free_refused_stranded did NOT remove gate:failed"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent story:in-flight" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded frees the lane (story:in-flight)" \
  || bad "gap2_free_refused_stranded did NOT clear story:in-flight — bead stays permanently stranded"
grep -qF -- "-C $GC_CITY label remove ga-fake-parent pilot:dispatched" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded frees the lane (pilot:dispatched)" \
  || bad "gap2_free_refused_stranded did NOT clear pilot:dispatched — GAP-2 would re-select this bead every cycle forever"
grep -qF -- "-C $GC_CITY label add ga-fake-parent pool:refused:engine-rebuild-required" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded stamps the real reason onto the parent" \
  || bad "gap2_free_refused_stranded did NOT stamp pool:refused — the true state never reaches the parent (ga-eu75w acceptance criterion)"
grep -qF -- "comment ga-fake-parent" "$GAP2_REFUSED_CALLS" \
  && ok "gap2_free_refused_stranded posts its explanatory comment" \
  || bad "gap2_free_refused_stranded stopped posting a comment — silent label mutation with no audit trail"

# gate:needs-human* must be STRUCTURALLY unreachable — assert no LABEL
# mutation call ever names it (ga-eu75w acceptance criterion: "gate:needs-human*
# SURVIVES"). Scoped to actual "label add"/"label remove" calls, via the
# two-token phrase (not a bare "label" substring): the function's own
# explanatory comment text legitimately SAYS "gate:needs-human* labels, if
# any, are left untouched" — and "labels" (plural) itself contains "label" as
# a substring, so a bare substring grep over the whole log false-positives on
# that prose. Caught live while writing this very test (ga-eu75w) — the exact
# error-vs-empty shape this city's own doctrine warns about: a match must
# mean what it claims to mean, not just contain the right characters.
if grep -E -- 'label (add|remove)' "$GAP2_REFUSED_CALLS" | grep -qF -- "needs-human"; then
  bad "gap2_free_refused_stranded issued a label add/remove naming needs-human — acceptance criterion violated"
else
  ok "gap2_free_refused_stranded never issues a label mutation naming gate:needs-human*"
fi

# Ordering: removes before adds, mirroring gap2_arm_needs_remerge / the close:* arms.
GAP2_REFUSED_REMOVE_LINE=$(grep -nF -- "label remove ga-fake-parent pilot:dispatched" "$GAP2_REFUSED_CALLS" | head -1 | cut -d: -f1)
GAP2_REFUSED_ADD_LINE=$(grep -nF -- "label add ga-fake-parent pool:refused:engine-rebuild-required" "$GAP2_REFUSED_CALLS" | head -1 | cut -d: -f1)
if [ -n "$GAP2_REFUSED_REMOVE_LINE" ] && [ -n "$GAP2_REFUSED_ADD_LINE" ] && [ "$GAP2_REFUSED_REMOVE_LINE" -lt "$GAP2_REFUSED_ADD_LINE" ]; then
  ok "gap2_free_refused_stranded removes old status labels BEFORE adding the refusal label"
else
  bad "gap2_free_refused_stranded ordering wrong (or calls missing) — removes must precede adds"
fi
rm -f "$GAP2_REFUSED_CALLS"

# Bare "pool:refused" (no reason) fallback — must still stamp something sane,
# never an empty label add.
GAP2_REFUSED_BARE_CALLS="$(mktemp)"
bd() { printf '%s\n' "$*" >> "$GAP2_REFUSED_BARE_CALLS"; return 0; }
gap2_free_refused_stranded "ga-fake-parent2" "ga-fake-sling2" ""
unset -f bd
grep -qF -- "-C $GC_CITY label add ga-fake-parent2 pool:refused" "$GAP2_REFUSED_BARE_CALLS" \
  && ok "gap2_free_refused_stranded falls back to bare pool:refused when no token was extracted" \
  || bad "gap2_free_refused_stranded with empty token did not stamp a sane fallback label"
rm -f "$GAP2_REFUSED_BARE_CALLS"

# Drift-guard companions: the case-statement call site must actually invoke it.
grep -q 'free:refused-stranded)' "$GUARD" \
  && ok "Step 0c.2's case statement defines the free:refused-stranded arm" \
  || bad "free:refused-stranded verdict is classified but the case statement has no matching arm"
grep -q 'gap2_free_refused_stranded "\$SC_ID" "\$SLING_ID" "\$SLING_REFUSED_TOKEN"' "$GUARD" \
  && ok "the free:refused-stranded arm actually calls gap2_free_refused_stranded" \
  || bad "gap2_free_refused_stranded is defined but the case-statement arm never calls it"

# ── 6g. gap2_apply_pass_verdict (ga-1un0n: story:approved must not bypass verification) ──
# Root incident (measured live, 2026-08-09/10, TWICE in ~1h — ga-qhca1, ga-x3e7p):
# the free:pass-stranded arm's story:approved branch set gate:passed straight
# off "sling closed, didn't fail" — story:approved is PRODUCT approval, not
# proof a reviewer ever ran. Both times the real gate-run was still
# gate-status:running with NO verdict when gate:passed landed on the parent.
# gap2_apply_pass_verdict is the new SHARED terminal action both parent types
# must route through, and it must never be the thing deciding whether
# verification happened — it only decides what to do with a verdict the
# caller already computed identically for every type.
echo "── 6g. gap2_apply_pass_verdict (ga-1un0n: story:approved must not bypass verification) ──"

GC_CITY=/tmp/ga-1un0n-fake-city

GAP1UN0N_STORY_MERGED="$(mktemp)"
bd() { printf '%s\n' "$*" >> "$GAP1UN0N_STORY_MERGED"; return 0; }
gap2_apply_pass_verdict "ga-fake-story" "ga-fake-sling" 1 "close:merge-verified"
unset -f bd
grep -qF -- "-C $GC_CITY label add ga-fake-story gate:passed" "$GAP1UN0N_STORY_MERGED" \
  && ok "story:approved + merge-verified → gate:passed IS set" \
  || bad "story:approved + merge-verified did NOT set gate:passed"
grep -qF -- "-C $GC_CITY close ga-fake-story" "$GAP1UN0N_STORY_MERGED" \
  && bad "REGRESSION: story parent was bd-closed directly — story-delivery.sh would never run" \
  || ok "story:approved + merge-verified does NOT close the parent directly (story-delivery finalizes it)"
rm -f "$GAP1UN0N_STORY_MERGED"

GAP1UN0N_BUGTASK_MERGED="$(mktemp)"
bd() { printf '%s\n' "$*" >> "$GAP1UN0N_BUGTASK_MERGED"; return 0; }
gap2_apply_pass_verdict "ga-fake-bug" "ga-fake-sling" 0 "close:merge-verified"
unset -f bd
grep -qF -- "-C $GC_CITY close ga-fake-bug" "$GAP1UN0N_BUGTASK_MERGED" \
  && ok "non-story + merge-verified → parent IS closed directly (unchanged legacy behavior)" \
  || bad "non-story + merge-verified did NOT close the parent"
grep -qF -- "gate:passed" "$GAP1UN0N_BUGTASK_MERGED" \
  && bad "REGRESSION: non-story parent got gate:passed — that label is story-delivery's trigger, not a bug/task's" \
  || ok "non-story + merge-verified never touches gate:passed"
rm -f "$GAP1UN0N_BUGTASK_MERGED"

GAP1UN0N_STORY_UNTRACKED="$(mktemp)"
bd() { printf '%s\n' "$*" >> "$GAP1UN0N_STORY_UNTRACKED"; return 0; }
gap2_apply_pass_verdict "ga-fake-story2" "ga-fake-sling2" 1 "close:untracked-delivery"
unset -f bd
grep -qF -- "-C $GC_CITY label add ga-fake-story2 gate:passed" "$GAP1UN0N_STORY_UNTRACKED" \
  && ok "story:approved + untracked-delivery → gate:passed IS set (ga-x2x63 path preserved for stories)" \
  || bad "story:approved + untracked-delivery did NOT set gate:passed"
rm -f "$GAP1UN0N_STORY_UNTRACKED"

# THE regression fixture: neither "wait" nor "keep" is a close verdict —
# gap2_apply_pass_verdict must be a pure no-op (zero bd calls, non-zero
# return) if ever called with one, regardless of is_story. This is the exact
# shape of the live incident: at the moment GAP-2 swept, the real verdict was
# wait:active-marker (a marker existed, ready/queued, not yet claimed) — never
# close:*. The OLD code never even computed a verdict for stories, so nothing
# could ever distinguish this from close:merge-verified.
GAP1UN0N_NOOP_CALLS="$(mktemp)"
bd() { printf '%s\n' "$*" >> "$GAP1UN0N_NOOP_CALLS"; return 0; }
gap2_apply_pass_verdict "ga-fake-story3" "ga-fake-sling3" 1 "wait:active-marker"      && NOOP_RC1=0 || NOOP_RC1=$?
gap2_apply_pass_verdict "ga-fake-story4" "ga-fake-sling4" 1 "keep:merge-not-verified" && NOOP_RC2=0 || NOOP_RC2=$?
unset -f bd
if [ -s "$GAP1UN0N_NOOP_CALLS" ]; then
  bad "REGRESSION ga-1un0n: gap2_apply_pass_verdict made a bd call for a non-close verdict — got: $(cat "$GAP1UN0N_NOOP_CALLS")"
else
  ok "gap2_apply_pass_verdict makes ZERO bd calls for wait:active-marker / keep:merge-not-verified — story:approved cannot force gate:passed on an unverified/still-reviewing parent"
fi
if [ "$NOOP_RC1" != "0" ] && [ "$NOOP_RC2" != "0" ]; then
  ok "gap2_apply_pass_verdict signals non-success (rc!=0) on a non-close verdict, so a caller cannot mistake this for having acted"
else
  bad "gap2_apply_pass_verdict returned rc=0 on a non-close verdict"
fi
rm -f "$GAP1UN0N_NOOP_CALLS"

# ── 6h. drift-guard: the OLD unconditional story:approved bypass is gone (ga-1un0n) ──
echo "── 6h. drift-guard: GAP-2 story:approved must reach the SAME verification (ga-1un0n) ──"

type gap2_apply_pass_verdict >/dev/null 2>&1 \
  && ok "guard defines gap2_apply_pass_verdict (ga-1un0n)" \
  || bad "guard missing gap2_apply_pass_verdict def"

# Isolate the free:pass-stranded arm's own source text (from its case-label to
# the next sibling arm) so these assertions cannot accidentally match some
# UNRELATED story:approved / classify_gap2_bugtask_verdict occurrence
# elsewhere in this 3000+ line file.
GAP1UN0N_ARM_TEXT="$(awk '/^      free:pass-stranded\)/{flag=1} flag{print} /^      skip:live-assignee\)/{exit}' "$GUARD")"

if [ -z "$GAP1UN0N_ARM_TEXT" ]; then
  bad "could not isolate the free:pass-stranded arm's source text — drift-guard cannot run"
else
  ok "isolated the free:pass-stranded arm's source text ($(echo "$GAP1UN0N_ARM_TEXT" | wc -l | tr -d ' ') lines)"

  # THE regression lock: the OLD bug's exact branching construct — an if/else
  # that made classify_gap2_bugtask_verdict reachable ONLY on the else
  # (non-story) side — must be gone. story:approved may still be READ (to
  # pick the terminal action), just never used to SKIP verification.
  if echo "$GAP1UN0N_ARM_TEXT" | grep -q 'if echo "\$SC_LABELS" | grep -q "story:approved"; then'; then
    bad "REGRESSION ga-1un0n: the free:pass-stranded arm still branches on story:approved BEFORE verification — the exact bypass this bead reports"
  else
    ok "the free:pass-stranded arm no longer gates verification behind an if/else on story:approved"
  fi

  [ "$(echo "$GAP1UN0N_ARM_TEXT" | grep -c 'classify_gap2_bugtask_verdict "')" -eq 1 ] \
    && ok "classify_gap2_bugtask_verdict is called EXACTLY once — one verification path for every parent type" \
    || bad "expected exactly 1 classify_gap2_bugtask_verdict call site in this arm — got $(echo "$GAP1UN0N_ARM_TEXT" | grep -c 'classify_gap2_bugtask_verdict "') (verification path may have been duplicated or is still branch-specific)"

  echo "$GAP1UN0N_ARM_TEXT" | grep -q 'gap2_apply_pass_verdict "\$SC_ID" "\$SLING_ID" "\$GAP2_IS_STORY"' \
    && ok "the close:merge-verified|close:untracked-delivery arm actually calls gap2_apply_pass_verdict, passing the computed story flag" \
    || bad "gap2_apply_pass_verdict is defined but the case-statement arm never calls it with the computed story flag"

  # The OLD literal bug line: an UNCONDITIONAL gate:passed write keyed
  # directly off $SC_ID, outside of any verdict-gated function. If this
  # reappears anywhere in the arm, the bypass is back regardless of what
  # else changed.
  echo "$GAP1UN0N_ARM_TEXT" | grep -q 'label add "\$SC_ID" "gate:passed"' \
    && bad "REGRESSION ga-1un0n: found an UNGATED 'label add \$SC_ID gate:passed' directly in the sweep — this is the exact bypass line the bug reports" \
    || ok "no ungated gate:passed write remains in the sweep — it only happens inside the verdict-gated gap2_apply_pass_verdict"
fi

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
grep -q 'free:refused-stranded'     "$GUARD" && ok "guard handles free:refused-stranded action (ga-eu75w)" || bad "guard missing free:refused-stranded handler"
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

# (D-unit-2, ga-i0n83) The ADD must run BEFORE the removes — the reverse order
# (remove-then-add, pre-fix) has a window where an interruption between the two
# bd calls (crash, Dolt hiccup, launchd timeout kill — NOT a bd exit code, which
# both orders already tolerate via `|| true`) leaves the bead with ZERO
# gate-status:* labels: "unreachable by construction" (ga-5jyo8) — invisible to
# every dispatcher/guard --label-any gate-status:{...} query, undetected for
# days until a human manually re-labels it. A single failing bd call can't
# distinguish the two orders (both already swallow it and keep going), so
# observe the ACTUAL call order instead, via a mock bd that logs every label
# mutation it sees, in sequence.
echo "── 8c. set_gate_status ADDs before it REMOVEs (ga-i0n83) ──"
GC_CITY=/tmp/ga-jhyu-fake-city
_MOCK_LABELS="gate-status:dispatching"
_CALL_LOG=""
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
    _CALL_LOG="$_CALL_LOG $op:$lbl"
    case "$op" in
      remove) _MOCK_LABELS=$(printf '%s\n' $_MOCK_LABELS | grep -vx "$lbl" | tr '\n' ' ' || true) ;;
      add)    printf '%s\n' $_MOCK_LABELS | grep -qx "$lbl" || _MOCK_LABELS="$_MOCK_LABELS $lbl" ;;
    esac
    return 0
  fi
  return 0
}
set_gate_status fake-bead-2 queued
ADD_POS=$(printf '%s\n' $_CALL_LOG | grep -n '^add:gate-status:queued$'      | head -1 | cut -d: -f1)
REMOVE_POS=$(printf '%s\n' $_CALL_LOG | grep -n '^remove:gate-status:dispatching$' | head -1 | cut -d: -f1)
[ -n "$ADD_POS" ] && [ -n "$REMOVE_POS" ] && [ "$ADD_POS" -lt "$REMOVE_POS" ] \
  && ok "add lands BEFORE remove — no window where the bead has zero gate-status labels (ga-i0n83)" \
  || bad "REGRESSION ga-i0n83: remove ran before (or without) add — reintroduces the zero-gate-status window (ga-5jyo8)"
# End-state sanity (unchanged behavior): still converges to exactly one label.
_n=$(printf '%s\n' $_MOCK_LABELS | grep -c '^gate-status:' || true)
eq "still exactly ONE gate-status:* label once both calls land" "$_n" "1"
unset -f bd

echo ""
# ── 9. ga-7fwt1: dispatcher's OWN inline gate-status transitions ─────────────
# Follow-up to ga-i0n83 (section 8 above): that fix reordered the SHARED
# set_gate_status/set_gate_status_py, but quality-gate-dispatcher.sh had
# several raw inline remove-then-add pairs that bypassed the shared helper
# entirely, plus a first-match ambiguity in a sibling-status extraction that
# could feed the wrong status into a concurrent-sibling merge-block decision.

# (a) Structural drift-guard: no `label remove ... "gate-status:X"` line is
# immediately followed by a `label add ... "gate-status:Y"` line anywhere in
# the dispatcher — that exact adjacency is the ga-i0n83 bug shape (remove
# lands before add, leaving a window where the marker has ZERO gate-status:*
# labels if interrupted). Every site of this shape found during the ga-7fwt1
# audit (12 simple pairs + a 10-branch multi-exit block that removed
# "dispatching" unconditionally up front, the widest such window in the file)
# was consolidated into set_gate_status() — add-before-remove, queried live,
# same invariant ga-i0n83 already proved. Two sites embedded in an isolated
# SELFTEST-EXTRACT block (gate-author-final-fallback, rig-path-resolve — each
# unit-tested standalone without guard.sh sourced) were manually reordered to
# add-then-remove instead, to stay dependency-free for those tests. The
# deliberate claim/lock sites (queued→dispatching, ready→claimed) are NOT
# adjacent — they re-fetch and verify between remove and add — so they never
# match this shape and correctly never trigger this guard.
echo "── 9a. drift-guard: no adjacent remove-then-add gate-status:* pairs remain (ga-7fwt1) ──"
ADJACENT_PAIRS=$(awk '
  /label remove.*"gate-status:/ { remove_line=NR; next }
  /label add.*"gate-status:/ && NR == remove_line+1 { print remove_line }
' "$DISPATCHER")
if [ -z "$ADJACENT_PAIRS" ]; then
  ok "no adjacent remove-then-add gate-status:* pairs remain in dispatcher"
else
  bad "REGRESSION ga-7fwt1: adjacent remove-then-add gate-status:* pair(s) reintroduced at dispatcher line(s): $ADJACENT_PAIRS"
fi

# (a-mutation) Prove 9a is not vacuous: a scratch copy with ONE pre-fix-shaped
# pair deliberately reinjected must turn it red.
MUT_9A="$(mktemp)"
cp "$DISPATCHER" "$MUT_9A"
python3 - "$MUT_9A" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = 'log "  Branch $BRANCH is current with $DEFAULT_BRANCH — stale-base check passed."\n'
assert text.count(anchor) == 1, "anchor not unique — mutation-test needs a different anchor"
injected = (
    anchor
    + '  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true\n'
    + '  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"      -q 2>/dev/null || true\n'
)
text = text.replace(anchor, injected, 1)
open(path, 'w').write(text)
PYEOF
MUT_HITS=$(awk '
  /label remove.*"gate-status:/ { remove_line=NR; next }
  /label add.*"gate-status:/ && NR == remove_line+1 { print remove_line }
' "$MUT_9A")
if [ -n "$MUT_HITS" ]; then
  ok "mutation-test: reinjecting a remove-then-add pair turns 9a red — guard is not vacuous"
else
  bad "mutation-test: 9a did not detect a deliberately reinjected remove-then-add pair"
fi
rm -f "$MUT_9A"

# (b) gate_bead_active_sibling_branch (dispatcher.sh, the L978-area caller)
# must never guess between an ambiguous (0 or 2+) gate-status:* label set on
# a sibling marker — it now routes through the shared marker_status_from_labels
# (guard.sh, sourced above) instead of a bare `head -1`. Source the dispatcher
# itself in lib-only mode to exercise the REAL function (its own internal
# guard.sh source, a few thousand lines in, is a harmless idempotent re-source
# of the same functions already defined above — proven by gate-rebase-while-
# queued.selftest.sh's identical pattern run standalone).
echo "── 9b. gate_bead_active_sibling_branch never guesses on ambiguous sibling status (ga-7fwt1) ──"
GATE_DISPATCHER_LIB_ONLY=1 source "$DISPATCHER" \
  || { echo "FATAL: could not source dispatcher in lib-only mode"; exit 1; }
type gate_bead_active_sibling_branch >/dev/null 2>&1 || { echo "FATAL: gate_bead_active_sibling_branch not defined by dispatcher"; exit 1; }

# 9b-i: a sibling with TWO gate-status:* labels (a mid-transition snapshot) on
# a DIFFERENT branch must be EXCLUDED — never picked as the active sibling,
# never crash the caller, and surfaced via the existing ALERT (not silently
# dropped).
bd() {
  local verb="$3"
  if [ "$verb" = "list" ]; then
    printf '[{"id":"sib-1","status":"open","description":"","labels":["source-bead:bead-1","branch:other-branch","gate-status:queued","gate-status:dispatching"]}]'
    return 0
  fi
  return 0
}
AMBIG_STDERR="$(mktemp)"
AMBIG_RESULT=$(gate_bead_active_sibling_branch "/fake/city" "bead-1" "my-own-branch" 2>"$AMBIG_STDERR")
unset -f bd
if [ -z "$AMBIG_RESULT" ]; then
  ok "sibling with 2 ambiguous gate-status:* labels is excluded, not guessed at (empty result)"
else
  bad "sibling with 2 ambiguous gate-status:* labels was NOT excluded — got: $AMBIG_RESULT (a guess here could hide or fabricate a concurrent-sibling merge-block decision)"
fi
if grep -q "AMBIGUOUS gate-status state" "$AMBIG_STDERR"; then
  ok "ambiguous sibling is surfaced via the ALERT (not silently dropped)"
else
  bad "ambiguous sibling produced no ALERT — got stderr: $(cat "$AMBIG_STDERR")"
fi
rm -f "$AMBIG_STDERR"

# 9b-ii: CONTRAST — a sibling with exactly ONE gate-status:* label on a
# different, ACTIVE branch must still be correctly picked up. Proves 9b-i
# isn't vacuous (the function isn't just "always returns empty" — it
# distinguishes exactly-one from ambiguous).
bd() {
  local verb="$3"
  if [ "$verb" = "list" ]; then
    printf '[{"id":"sib-2","status":"open","description":"","labels":["source-bead:bead-1","branch:other-branch","gate-status:queued"]}]'
    return 0
  fi
  return 0
}
CLEAN_RESULT=$(gate_bead_active_sibling_branch "/fake/city" "bead-1" "my-own-branch" 2>/dev/null)
unset -f bd
case "$CLEAN_RESULT" in
  "other-branch"$'\t'"queued") ok "sibling with exactly ONE gate-status:* label is correctly picked up as active (=$CLEAN_RESULT)";;
  *) bad "sibling with exactly ONE gate-status:* label was NOT picked up — got: [$CLEAN_RESULT] (9b-i result may be vacuous)";;
esac

echo ""
# ── 10. ga-qblq4: zero-gate-status-window closed at every remaining transition ──
# Follow-up to ga-i0n83 (section 8, set_gate_status) and ga-7fwt1 (section 9,
# dispatcher's simple inline pairs). Two more classes of site had the same
# defect and survived both prior audits:
#   (i)  The deliberate claim/lock sites (dispatcher queued→dispatching,
#        guard ready→claimed). Section 9a's own comment above explicitly
#        excused these: "they re-fetch and verify between remove and add —
#        so they never match this shape and correctly never trigger this
#        guard." That reasoning was INCOMPLETE: remove and add are not
#        text-adjacent (verify/log code runs between them), but the LIVE
#        MARKER still carries zero gate-status:* labels for the entire gap
#        between the remove call and the add call, regardless of what
#        non-label-mutating code executes in between. Observed live
#        (ga-qblq4): marker ga-4i49c read 3x in ~2min showed
#        ready → FANTASMA (0 gate-status, misclassified by
#        gate-queue-composition.sh as abandoned) → claimed — it was never
#        orphaned, only mid-claim.
#   (ii) gate_status_transition() (dispatcher — ga-ia7m7's own "replace ALL
#        gate-status:* atomically" helper, ironically not itself immune) and
#        four guard.sh blocks (Vector A's two reclaim branches, the
#        author-unresolvable defer, and claimed→queued parking) — none of
#        these route through set_gate_status, so ga-i0n83's fix never
#        reached them. None of them are in $DISPATCHER either, so section
#        9a's drift-guard (which only scans $DISPATCHER) never covered them.
# All seven sites reordered to add-before-remove, the proven set_gate_status/
# ga-i0n83 invariant: worst case is now a brief window with BOTH labels
# present (read as ambiguous/UNKNOWN by the composition analyzer — inert),
# never zero (read as FANTASMA — destructive).
echo "── 10a. gate_status_transition() ADDs before it REMOVEs (ga-qblq4) ──"
GC_CITY=/tmp/ga-qblq4-fake-city
_MOCK_LABELS="gate-status:dispatching"
_CALL_LOG=""
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
    _CALL_LOG="$_CALL_LOG $op:$lbl"
    case "$op" in
      remove) _MOCK_LABELS=$(printf '%s\n' $_MOCK_LABELS | grep -vx "$lbl" | tr '\n' ' ' || true) ;;
      add)    printf '%s\n' $_MOCK_LABELS | grep -qx "$lbl" || _MOCK_LABELS="$_MOCK_LABELS $lbl" ;;
    esac
    return 0
  fi
  return 0
}
gate_status_transition "fake-marker" "ready"
ADD_POS=$(printf '%s\n' $_CALL_LOG | grep -n '^add:gate-status:ready$'             | head -1 | cut -d: -f1 || true)
REMOVE_POS=$(printf '%s\n' $_CALL_LOG | grep -n '^remove:gate-status:dispatching$' | head -1 | cut -d: -f1 || true)
[ -n "$ADD_POS" ] && [ -n "$REMOVE_POS" ] && [ "$ADD_POS" -lt "$REMOVE_POS" ] \
  && ok "gate_status_transition: add lands BEFORE remove — no zero-gate-status window (ga-qblq4)" \
  || bad "REGRESSION ga-qblq4: gate_status_transition removed before (or without) add — reintroduces the zero-gate-status window"
_n=$(printf '%s\n' $_MOCK_LABELS | grep -c '^gate-status:' || true)
eq "gate_status_transition: still exactly ONE gate-status:* label once both calls land" "$_n" "1"
unset -f bd

echo "── 10b. deliberate claim/lock sites: add lands before remove (ga-qblq4) ──"
# These two sites re-fetch and verify BETWEEN the mutating calls, so they are
# not text-adjacent (section 9a's adjacency check would never catch a
# regression here) — but their add/remove targets are each globally unique in
# their own file, so a direct line-number comparison proves the real
# invariant (does the ADD line execute before the REMOVE line) without
# needing to execute the block.
D_ADD_LINE=$(grep -Fn 'label add "$MARKER_ID" "gate-status:dispatching"' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
D_REMOVE_LINE=$(grep -Fn 'label remove "$MARKER_ID" "gate-status:queued"' "$DISPATCHER" | head -1 | cut -d: -f1 || true)
if [ -n "$D_ADD_LINE" ] && [ -n "$D_REMOVE_LINE" ] && [ "$D_ADD_LINE" -lt "$D_REMOVE_LINE" ]; then
  ok "dispatcher queued→dispatching claim: add (L$D_ADD_LINE) precedes remove (L$D_REMOVE_LINE)"
else
  bad "REGRESSION ga-qblq4: dispatcher queued→dispatching claim removes queued before (or without) adding dispatching (add=$D_ADD_LINE remove=$D_REMOVE_LINE)"
fi

G_ADD_LINE=$(grep -Fn 'label add "$MARKER_ID" "gate-status:claimed"' "$GUARD" | head -1 | cut -d: -f1 || true)
G_REMOVE_LINE=$(grep -Fn 'label remove "$MARKER_ID" "gate-status:ready"' "$GUARD" | head -1 | cut -d: -f1 || true)
if [ -n "$G_ADD_LINE" ] && [ -n "$G_REMOVE_LINE" ] && [ "$G_ADD_LINE" -lt "$G_REMOVE_LINE" ]; then
  ok "guard ready→claimed claim: add (L$G_ADD_LINE) precedes remove (L$G_REMOVE_LINE)"
else
  bad "REGRESSION ga-qblq4: guard ready→claimed claim removes ready before (or without) adding claimed (add=$G_ADD_LINE remove=$G_REMOVE_LINE)"
fi

echo "── 10c. guard.sh Vector A / defer / park-as-queued: add before remove (ga-qblq4) ──"
# These four blocks share label PAIRS with a sibling block (Vector A's two
# branches both touch dispatching+claimed; defer and park-as-queued both
# remove "claimed"), so a bare grep for the label text alone would match the
# wrong block. Anchor on each block's own unique log/warn message instead and
# scan a small forward window — robust to the ambiguity and to unrelated
# line-number drift elsewhere in the file.
check_add_before_remove_near_anchor() {
  local file="$1" desc="$2" anchor="$3" window="${4:-6}"
  local result
  result=$(awk -v anchor="$anchor" -v window="$window" '
    index($0, anchor) > 0 { anchor_line = NR; next }
    anchor_line && NR <= anchor_line + window {
      if (!add_line    && index($0, "label add")    > 0 && index($0, "gate-status:") > 0) add_line = NR
      if (!remove_line && index($0, "label remove") > 0 && index($0, "gate-status:") > 0) remove_line = NR
    }
    END {
      if (add_line && remove_line) {
        if (add_line < remove_line) print "PASS " add_line " " remove_line
        else print "FAIL_ORDER " add_line " " remove_line
      } else {
        print "FAIL_NOTFOUND " add_line+0 " " remove_line+0
      }
    }
  ' "$file")
  set -- $result
  case "$1" in
    PASS)         ok "$desc: add (L$2) precedes remove (L$3)" ;;
    FAIL_ORDER)   bad "REGRESSION ga-qblq4: $desc — remove landed before add (add=L$2 remove=L$3)" ;;
    *)            bad "REGRESSION ga-qblq4: $desc — could not locate add/remove near anchor (add=$2 remove=$3)" ;;
  esac
}
check_add_before_remove_near_anchor "$GUARD" "Vector A requeue:queued" \
  'Vector A: requeueing zombie dispatching marker'
check_add_before_remove_near_anchor "$GUARD" "Vector A requeue:ready" \
  'Vector A: re-readying zombie claimed marker'
check_add_before_remove_near_anchor "$GUARD" "author-unresolvable defer" \
  'Cannot determine author authoritatively for bead $BEAD_ID — DEFERRING'
check_add_before_remove_near_anchor "$GUARD" "guard parks marker as queued" \
  'Guard: parking marker $MARKER_ID as gate-status:queued for autonomous dispatcher'

# (mutation-test) Prove 10c's helper is not vacuous: reinject a
# remove-before-add shaped block behind a fresh (unique) anchor and confirm
# it reports the failure shape — mirrors section 9a's own mutation-test
# discipline.
MUT_10C="$(mktemp)"
cp "$GUARD" "$MUT_10C"
python3 - "$MUT_10C" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
anchor = 'log "Attempting to claim marker $MARKER_ID ..."\n'
assert text.count(anchor) == 1, "anchor not unique — mutation-test needs a different anchor"
injected = (
    anchor
    + '  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:mut-old" -q 2>/dev/null || true\n'
    + '  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:mut-new" -q 2>/dev/null || true\n'
)
text = text.replace(anchor, injected, 1)
open(path, 'w').write(text)
PYEOF
MUT_RESULT=$(awk -v anchor='Attempting to claim marker' -v window=6 '
  index($0, anchor) > 0 { anchor_line = NR; next }
  anchor_line && NR <= anchor_line + window {
    if (!add_line    && index($0, "label add")    > 0 && index($0, "gate-status:") > 0) add_line = NR
    if (!remove_line && index($0, "label remove") > 0 && index($0, "gate-status:") > 0) remove_line = NR
  }
  END {
    if (add_line && remove_line && add_line < remove_line) print "PASS"
    else print "CAUGHT"
  }
' "$MUT_10C")
[ "$MUT_RESULT" = "CAUGHT" ] \
  && ok "mutation-test: reinjecting a remove-before-add pair turns 10c's helper red — guard is not vacuous" \
  || bad "mutation-test: 10c's helper did not detect a deliberately reinjected remove-before-add pair"
rm -f "$MUT_10C"

echo ""
echo "──────────────────────────────────────────"
echo "  PASS=$PASS  FAIL=$FAIL"
if [ "$FAIL" -gt 0 ]; then echo "  RESULT: FAIL"; exit 1; fi
echo "  RESULT: PASS"; exit 0

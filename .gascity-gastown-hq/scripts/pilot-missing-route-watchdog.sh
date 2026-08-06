#!/usr/bin/env bash
# pilot-missing-route-watchdog.sh — detects beads that are ARMED (carry both
# ctx:ready AND exec:auto) and OPEN, but carry NO gc.routed_to metadata, for
# longer than a configurable grace period.
#
# WHY THIS EXISTS (ga-f54ui): a bead only becomes visible to a pool worker's
# own self-serve discovery (`bd ready --metadata-field gc.routed_to=<target>
# --unassigned`, the same shape every dog/wa-worker/ps-worker Step-1c probe
# uses) once gc.routed_to is set — normally stamped by pilot-dispatcher.sh
# itself as part of dispatching. If that field is missing (dispatch step
# skipped/failed) or gets CLEARED later without being restored (reclaim,
# manual re-arm, and circuit-break all appear to return a bead to the ready
# queue without re-stamping the route — ga-f54ui's own "investigate why"
# note), the bead can carry ctx:ready+exec:auto — looking READY in the panel
# and in any plain `bd list` — and never be picked up by anything, forever.
# Not slow, not lane-saturated: invisible, the same
# root-class:armed-but-unreachable shape as ga-5jyo8's
# root-class:unreachable-by-construction, just on the metadata side of
# dispatch instead of the label side of gate review.
#
# Real incidents (Mayor, 2026-08-06, two separate sweeps same day, ALL with
# real unmerged work — branch existed, 1-3 commits ahead of main): ga-o9uvc
# (armed, no-route, plus a 13-day-stale pilot.dispatched_at compounding the
# invisibility — the Pilot read "already dispatched" and skipped, two
# blockers stacked), ga-yp9r8, wa-vcd01 (crew/peter/wa-vcd01-v5, fix-attempt
# 3/3 — its LAST attempt before circuit-break), wa-6cx36 (9.5 days),
# wa-444cn, wa-nh37r (26h), wa-ys0cy (13.4 days), wa-ge50x (10.6 days). Lane
# capacity was NOT the limit in either sweep (lane:small had headroom both
# times) — this is pure invisibility, not queue pressure. Causally confirmed,
# not theory: manually setting gc.routed_to on ga-o9uvc and wa-pqsar got both
# picked up within minutes.
#
# SCOPE — MULTI-STORE, unlike ga-5jyo8's gate-marker-missing-status-watchdog
# (GMMSW): gate markers/runs are only ever created in the HQ store, but armed
# beads missing their route span every rig (the incident list above mixes
# ga-* HQ beads and wa-* whatsapp_automation beads). This script sweeps the
# same PMRW_STORES set gate-orphaned-label-watchdog.sh (GOLW) uses — static,
# env-overridable, not a live `gc rig list` call every cycle (that call runs
# 8-17s under Dolt load, not worth paying every sweep for a set that changes
# rarely; override PMRW_STORES if a rig is added).
#
# QUERY (ga-f54ui's own prescription: "a consulta e o complemento da do
# Pilot — nao replique o filtro dele, INVERTA-O" — same instruction GMMSW
# followed for the gate side). This does NOT attempt to replicate
# pilot-dispatcher.sh's full _filter_candidates chain (7000+ lines, session-
# liveness-roster-dependent in places) — that answers "should this be
# dispatched at all", a much bigger question than this watchdog needs. It
# mirrors only the CHEAP, purely label/metadata exclusions that mean "this
# bead is intentionally not routed for a DIFFERENT, already-understood
# reason" (so this watchdog doesn't cry wolf on those), confirmed by reading
# _filter_candidates directly (packs/town-deltas/assets/pilot-dispatcher.sh):
#   - issue_type == epic                                   → excluded
#   - gate:needs-human* (startswith, catches the -decision  → excluded
#     sub-variant too, mirroring _filter_candidates exactly)
#   - pilot:held WITHOUT an expired pilot:held-until:<epoch> → excluded
#     (ga-4aree semantics reproduced exactly: labels accumulate, so this
#     uses the MAX held-until, not the first one found)
#   - a graph.v2 formula step or root (gc.root_bead_id or                 → excluded
#     gc.formula_contract set, or gc.kind in the workflow-ish set) — these
#     are already serviced by a DIFFERENT dispatch mechanism entirely (see
#     .gc/system/packs/core/assets/prompts/graph-worker.md); a route gap
#     there is a different bug, not this one
#   - a Pilot-created sling/dispatch-wrapper bead                        → excluded
#     (metadata pilot.sling_for set — ga-nimyz) — not real work
#
# FIVE MORE exclusions, added after the FIRST live dry-run against the real
# HQ + rig stores flagged 54 candidates against a bug report whose own
# confirmed count was 8 — a ~7x gap large enough to mean "conflating two
# populations," not "found a bigger problem than known." All five are cheap
# label/metadata checks (no session-liveness lookups), same standard as the
# clauses above:
#   - story:* (any prefix) present                                      → excluded.
#     pilot-dispatcher.sh's OWN header is explicit that the ctx:ready
#     auto-dispatch mechanism this bug is about targets "chore/task/debt
#     beads (NO story:* label)" (packs/town-deltas/assets/pilot-dispatcher.sh
#     ~L362) — a story:approved/story:in-flight/etc. bead is dispatched via
#     a SEPARATE tier-2 feature path with its own timing (only reached once
#     tier-1 bug/debt work is exhausted), so sitting armed-without-a-route
#     for a while is its NORMAL waiting state, not this bug. This one
#     exclusion accounted for the majority of the 54.
#   - pilot:refusal-count:* (any) present                                → excluded.
#     already individually evaluated and explicitly parked with a
#     pilot:refused-reason:* — a deliberate decision already made, not an
#     undetected routing gap.
#   - needs:engine-window OR framework:engine present                   → excluded.
#     both explicitly gated on a Mayor-coordinated engine-rebuild window —
#     same "refuse, don't build, don't re-flag" doctrine this dog itself
#     follows for pool:refused:engine-rebuild-required work (framework:engine
#     is this town's own documented engine-rebuild-required trigger label,
#     8 of the first 19 real-world flags after adding the other four
#     exclusions carried it — all legitimately engine-window-gated, not
#     ga-f54ui instances).
#   - no-auto-dispatch OR pilot:no-auto-dispatch present                 → excluded.
#     an explicit, documented dispatch brake
#     ([[pilot-no-auto-dispatch-not-respected-by-pilot-dispatcher]]) — this
#     watchdog must not defeat a deliberate hold.
#   - blocked-on:*, blocked-by:*, or blocked: (any, startswith)          → excluded.
#     an explicit unresolved-dependency marker — status can still read
#     "open" while one of these is present (confirmed live: wa-v66xt), so
#     the status=open check alone does not catch it. Same "park" signal
#     class GOLW already treats as intentional (its own header: 4 of 11
#     known intentional parks carry status=blocked with no gate:needs-human
#     label at all — labels, not just status, carry this signal here).
#   - an ACTIVE (open, gate-status:{ready,claimed,queued,dispatching,
#     reviewing,running}) gate marker/run currently names this bead as
#     source-bead                                                        → excluded.
#     mirrors gate-orphaned-label-watchdog.sh's _gate_artifact_probe
#     EXACTLY (same query shape, same active-state set) rather than a
#     blanket "any gate:* label" exclusion — a bead can carry STALE
#     gate:failed/gate:needs-fix/gate:fix-attempt:N labels from a PAST
#     cycle while genuinely being a fresh instance of THIS bug (re-armed
#     for retry, route never restored — ga-f54ui's own hypothesis); only an
#     ACTIVE marker means "already dispatched, built, and submitted right
#     now" (the exact ga-5jyo8/ga-elvua trap this same dog session hit
#     twice earlier reading its OWN pool-probe candidates), so only an
#     active marker excludes, not label residue.
# What's left: status=open, NOT epic, ctx:ready AND exec:auto BOTH present
# (the "looks ready in the panel" signal ga-f54ui's own text uses),
# gc.routed_to empty/absent, no story:* label, aged past grace, none of the
# eleven holds/wrappers/graph-steps/parks/active-gates above applying.
#
# GRACE PERIOD (PMRW_GRACE_MINUTES, default 10): unlike GMMSW's gate-status
# loss (happens once, atomically, at marker creation — 5min grace), an armed
# bead can lose its route at MULTIPLE points in its lifecycle per ga-f54ui's
# own note (dispatch-time skip, OR a later reclaim/re-arm/circuit-break that
# clears it without restoring it) — closer in shape to GOLW's orphaned-label
# case than GMMSW's create-time-only case, so this uses `updated_at //
# created_at` (GOLW's fallback order) rather than GMMSW's `created_at //
# updated_at`. Grace is short by design regardless — the bug's own acceptance
# criterion is "detected in minutes, not days," and every real incident above
# was hours-to-days old, so a defensive few-minute buffer costs nothing.
#
# WHY DETECTION-ONLY, NOT AUTO-REPAIR: ga-f54ui's own FIX section offers an
# optional repair path — derive the route from the branch owner
# (crew/<name>/<bead> -> <name>-wa, "que e o que fiz a mao"). Tempting (it's
# exactly what the Mayor did by hand to unstick the 8 known cases), but
# LESS safe to automate than even GMMSW's already-deferred repair: GMMSW's
# would-be auto-fix is "add back one well-known label", this one requires
# PARSING a branch name and INFERRING an owner/pool target — more surface for
# a wrong guess, and a wrong route is not obviously safer than no route (a
# bead mis-routed to the wrong pool can be claimed by a worker that can't
# actually build it, burning a cycle that looks like progress but isn't).
# Same precedent as GMMSW/GOLW's own headers: detection-only is the safer
# starting point; auto-remediation, if ever wanted, is a separate decision
# made later with real detector data in hand.
#
# ALERTING: per-bead durable `bd comment` (new-or-cooldown-expired only,
# via --stdin — never a positional-arg `bd comment <id> <text>` invocation,
# which silently fuzzy-matches an invalid id and lands on an unrelated bead;
# --stdin has no id/text positional ambiguity to mis-derive) + aggregate
# `notify -p 2` + `gc mail send mayor`, cooldown-gated. Same shape as
# GMMSW/GOLW.
#
# MULTI-STORE RESOLUTION CORRECTNESS (mirrors GOLW's ga-tqe4j fix exactly):
# a bead tracked in state that's absent from THIS sweep's flagged set is only
# declared RESOLVED after an INDIVIDUAL recheck directly against the store it
# was found in (recorded per-id in state) confirms one of: gc.routed_to is
# now set, the bead closed, the bead is no longer armed (ctx:ready or
# exec:auto stripped — someone else intervened), or the bead is gone. If that
# recheck query itself fails, or confirms the bead is STILL exactly in the
# bad state, it stays tracked and UNVERIFIED, never silently pruned — a
# per-store read failure (one of seven stores, any sweep) must never be
# conflated with "confirmed fixed" (ga-p5q3 defense (a), same as every other
# watchdog in this family).
#
# FAIL-OPEN: any single store's bd/jq query failing skips ONLY that store
# (WARN logged) — the other stores in PMRW_STORES still get swept. A total
# inability to run (bd/jq missing) skips the whole sweep, touches nothing.
#
# KILL-SWITCH: PMRW_ENABLED=0 → no-op.
# DRY-RUN: PMRW_DRY_RUN=1 → log findings, skip comment/notify/mail/state-write.
#
# Selftest: bash pilot-missing-route-watchdog.sh --selftest
set -uo pipefail

# ── config (all env-overridable) ────────────────────────────────────────────
PMRW_ENABLED="${PMRW_ENABLED:-1}"
PMRW_DRY_RUN="${PMRW_DRY_RUN:-0}"
PMRW_GRACE_MINUTES="${PMRW_GRACE_MINUTES:-10}"
PMRW_ALERT_COOLDOWN_S="${PMRW_ALERT_COOLDOWN_S:-21600}"   # 6h — matches GMMSW/GOLW precedent
PMRW_NOTIFY_PRIORITY="${PMRW_NOTIFY_PRIORITY:-2}"

HQ="${PMRW_HQ:-/Users/athos/gt/.gascity-gastown-hq}"
# Same store set as GOLW (gate-orphaned-label-watchdog.sh), same rationale:
# static default matching `gc rig list` at authoring time, env-overridable.
PMRW_STORES="${PMRW_STORES:-$HQ /Users/athos/gt/whatsapp_automation /Users/athos/gt/property_scrapers /Users/athos/gt/marketing /Users/athos/gt/lexbh /Users/athos/gt/gastown /Users/athos/gt/deacon}"

LOG="${PMRW_LOG:-$HQ/.gc/logs/pilot-missing-route-watchdog.log}"
NOTIFY_BIN="${PMRW_NOTIFY_BIN:-/Users/athos/.local/bin/notify}"
GC_BIN="${PMRW_GC_BIN:-gc}"
BD_BIN="${PMRW_BD_BIN:-bd}"

PMRW_STATE_DIR="${PMRW_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${PMRW_STATE_FILE:-$PMRW_STATE_DIR/pilot-missing-route-watchdog.state.json}"

# ── helpers ──────────────────────────────────────────────────────────────────
ts()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { mkdir -p "$(dirname "$LOG")" 2>/dev/null || true; echo "[$(ts)] [pmrw] $*" >> "$LOG" 2>/dev/null || true; }
_store_name() { basename "$1"; }

# _gate_artifact_probe <bead_id>
# Prints "1" if an OPEN type:quality-gate-marker/-run bead currently names
# $1 as source-bead AND carries an active gate-status:* label (ready,
# claimed, queued, dispatching, reviewing, running) — "0" otherwise, "error"
# if the query itself failed. Mirrors gate-orphaned-label-watchdog.sh's
# _gate_artifact_probe exactly (same query shape: `bd list -l
# "source-bead:<id>"` against the HQ store — gate markers/runs are ALWAYS
# created there regardless of which rig store the source bead lives in).
# FAIL-OPEN semantics for THIS watchdog's purpose: "error" is treated by the
# caller as "don't exclude" (a probe failure must not silently suppress a
# real finding — the opposite fail-direction from GOLW, where "error" means
# "don't prune from state"; here it means "don't let an unknown active-gate
# status hide a candidate").
_gate_artifact_probe() {
  local _bid="$1" _arts _rc
  _arts=$("$BD_BIN" -C "$HQ" list -l "source-bead:$_bid" --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'error\n'
    return 1
  fi
  if [ -z "${_arts:-}" ] || [ "$_arts" = "null" ]; then
    printf '0\n'
    return 0
  fi
  printf '%s' "$_arts" | jq -r '
      [ .[] | select(.status == "open")
            | select( ((.labels // []) | index("type:quality-gate-marker"))
                      or ((.labels // []) | index("type:quality-gate-run")) )
            | select( ((.labels // []) | index("gate-status:ready"))       or
                      ((.labels // []) | index("gate-status:claimed"))     or
                      ((.labels // []) | index("gate-status:queued"))      or
                      ((.labels // []) | index("gate-status:dispatching")) or
                      ((.labels // []) | index("gate-status:reviewing"))   or
                      ((.labels // []) | index("gate-status:running")) )
      ] | if length > 0 then "1" else "0" end
    ' 2>/dev/null
}

# _state_load — prints the current state JSON (or "{}" on missing/corrupt file, fail-open)
_state_load() {
  if [ -f "$STATE_FILE" ]; then
    jq -c '.' "$STATE_FILE" 2>/dev/null || echo '{}'
  else
    echo '{}'
  fi
}

# _bead_recheck_status <id> <store>
# Individually re-verifies ONE bead's current armed-but-unrouted status
# directly against the store it was tracked under (ga-tqe4j pattern). Uses
# the exact-match `list --id <id>` flag form, never a positional `bd show
# <id>` (immune to bd's fuzzy positional-id matching —
# [[bd-cli-invalid-id-fuzzy-matches-unrelated-bead-silently]]). Prints ONE
# token:
#   error     — query itself failed: UNKNOWN, caller must NOT resolve.
#   gone      — store has no record for this id: treated as resolved.
#   closed    — status=closed: no longer armed by definition, resolved.
#   routed    — gc.routed_to is now non-empty: the FIX landed, resolved.
#   not-armed — still open, but no longer carries BOTH ctx:ready AND
#               exec:auto (someone/something else intervened — claimed,
#               parked, gate-failed off the ready queue): out of THIS
#               watchdog's scope now, resolved.
#   present   — still open, still armed, still unrouted: dropped from this
#               sweep for some OTHER reason (transient read blip, etc.) —
#               NOT resolved.
# KNOWN SCOPE LIMIT: this recheck deliberately does NOT re-test the five
# label-based exclusions added to the main sweep filter (story:*,
# pilot:refusal-count:*, needs:engine-window, no-auto-dispatch, active-gate
# probe) — only the core armed/routed/closed/gone signals. A bead that
# newly acquires one of those five AFTER being tracked stays in state as
# "present"/UNVERIFIED indefinitely rather than being pruned as resolved.
# Harmless: cooldown already suppresses re-alerting regardless of state, so
# this is a state-file hygiene gap only, never a false-alert or missed-alert
# risk. Not worth duplicating the full filter here for that payoff.
_bead_recheck_status() {
  local _id="$1" _store="$2" _out _rc
  _out=$("$BD_BIN" -C "$_store" list --id "$_id" --all --json 2>/dev/null \
    | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
  _rc=$?
  if [ "$_rc" -ne 0 ] || [ -z "${_out:-}" ] || [ "$_out" = "null" ]; then
    printf 'error\n'
    return 1
  fi
  printf '%s' "$_out" | jq -r --arg id "$_id" '
      ([ .[] | select(.id == $id) ] | .[0]) as $b
      | if $b == null then "gone"
        elif ($b.status // "") == "closed" then "closed"
        elif (($b.metadata["gc.routed_to"] // "") | test("\\S")) then "routed"
        elif ( (($b.labels // []) | index("ctx:ready")) and (($b.labels // []) | index("exec:auto")) ) then "present"
        else "not-armed"
        end
    ' 2>/dev/null
}

# _pmrw_resolve_tracked_state <state_json> <flagged_ids_json>
# ga-tqe4j pattern: the single choke point run_sweep funnels through before
# pruning anything from state. For every id in <state_json> NOT present in
# <flagged_ids_json>, individually re-verifies via _bead_recheck_status
# before deciding resolved-vs-still-broken-but-missed. Prints one JSON object
# on stdout: {"state": <pruned-state>, "resolved_ids": [...]}.
_pmrw_resolve_tracked_state() {
  local _state="$1" _keep="$2"
  local _candidates
  _candidates="$(printf '%s' "$_state" | jq -r --argjson keep "$_keep" 'keys - $keep | .[]' 2>/dev/null)"
  local _resolved="" _rid _rstore _rstatus _unverified_count=0
  if [ -n "${_candidates:-}" ]; then
    while IFS= read -r _rid; do
      [ -z "$_rid" ] && continue
      _rstore="$(printf '%s' "$_state" | jq -r --arg id "$_rid" '.[$id].store // empty' 2>/dev/null)"
      if [ -z "${_rstore:-}" ]; then
        log "UNVERIFIED: $_rid absent from this sweep but no store on record (pre-fix state entry) — cannot re-check, keeping (fail-safe)"
        _unverified_count=$((_unverified_count + 1))
        continue
      fi
      _rstatus="$(_bead_recheck_status "$_rid" "$_rstore")"
      case "$_rstatus" in
        gone|closed|routed|not-armed)
          log "RESOLVED: $_rid re-checked individually (${_rstatus}) — no longer armed-but-unrouted — cleared from state"
          _resolved="${_resolved}${_rid}"$'\n'
          ;;
        present)
          log "UNVERIFIED: $_rid re-checked and is STILL armed+unrouted (dropped from this sweep for another reason) — keeping in state, NOT resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
        *)
          log "UNVERIFIED: $_rid re-check query failed (store '$_rstore') — fail-safe, keeping in state, NOT declaring resolved"
          _unverified_count=$((_unverified_count + 1))
          ;;
      esac
    done <<< "$_candidates"
  fi
  if [ "$_unverified_count" -gt 0 ]; then
    log "UNVERIFIED total this sweep: ${_unverified_count} bead(s) absent from the flagged set but not positively confirmed cleared — kept in state"
  fi
  local _resolved_json
  _resolved_json="$(printf '%s' "$_resolved" | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
  [ -z "${_resolved_json:-}" ] && _resolved_json="[]"
  local _new_state
  _new_state="$(printf '%s' "$_state" | jq -c --argjson gone "$_resolved_json" 'with_entries(select(.key as $k | ($gone | index($k)) == null))' 2>/dev/null)"
  [ -z "${_new_state:-}" ] && _new_state="$_state"
  jq -nc --argjson st "$_new_state" --argjson rid "$_resolved_json" '{state: $st, resolved_ids: $rid}' 2>/dev/null
}

run_sweep() {
  if [ "${PMRW_ENABLED:-1}" != "1" ]; then
    log "disabled (PMRW_ENABLED=0) — no-op"
    return 0
  fi
  if [ -z "${PMRW_TEST_MODE:-}" ]; then
    command -v "$BD_BIN" >/dev/null 2>&1 || { log "WARN: bd not on PATH — fail-open, no sweep"; return 0; }
    command -v jq >/dev/null 2>&1 || { log "WARN: jq not on PATH — fail-open, no sweep"; return 0; }
  fi

  local now cutoff
  now="$(date +%s)"
  cutoff=$(( now - PMRW_GRACE_MINUTES * 60 ))

  local state; state="$(_state_load)"

  # Accumulate flagged candidates as TSV: id, store, age_min, labels, issue_type
  local flagged_tsv=""
  local store cand_json sel_json
  for store in $PMRW_STORES; do
    cand_json=$("$BD_BIN" -C "$store" list --json --limit 0 2>/dev/null \
      | jq -c 'if type=="array" then . else [.] end' 2>/dev/null)
    if [ -z "${cand_json:-}" ] || [ "$cand_json" = "null" ]; then
      log "WARN: could not read store '$store' (bd query or jq parse failed) — skipping this store (fail-open, other stores still swept)"
      continue
    fi

    sel_json=$(printf '%s' "$cand_json" | jq -c --argjson cut "$cutoff" --argjson now_ts "$now" '
        [ .[] | select((.status // "") == "open")
              | select((.issue_type // .type // "") != "epic")
              | select((.labels // []) | index("ctx:ready"))
              | select((.labels // []) | index("exec:auto"))
              | select(((.metadata["gc.routed_to"] // "") | test("\\S")) | not)
              | select(((.labels // []) | any(startswith("gate:needs-human"))) | not)
              | select(
                  (((.labels // []) | index("pilot:held")) | not)
                  or
                  ((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber) |
                    if length > 0 then (max < $now_ts) else false end)
                )
              | select(((.metadata["gc.root_bead_id"] // "") | test("\\S")) | not)
              | select(((.metadata["gc.formula_contract"] // "") | test("\\S")) | not)
              | select((((.metadata["gc.kind"] // "") as $k
                        | ["workflow","scope","ralph","retry","check","fanout","retry-eval","scope-check","workflow-finalize"]
                        | index($k)) == null))
              | select(((.metadata["pilot.sling_for"] // "") | test("\\S")) | not)
              | select(((.labels // []) | any(startswith("story:"))) | not)
              | select(((.labels // []) | any(startswith("pilot:refusal-count:"))) | not)
              | select(((.labels // []) | (index("needs:engine-window") or index("framework:engine"))) | not)
              | select(((.labels // []) | (index("no-auto-dispatch") or index("pilot:no-auto-dispatch"))) | not)
              | select(((.labels // []) | any(startswith("blocked-on:") or startswith("blocked-by:") or startswith("blocked:"))) | not)
              | select( ((( .updated_at // .created_at // "") | fromdateiso8601?) // 9999999999) < $cut )
        ]
      ' 2>/dev/null)
    if [ -z "${sel_json:-}" ]; then
      log "WARN: filter jq failed for store '$store' — skipping this store (fail-open)"
      continue
    fi

    local rows
    rows=$(printf '%s' "$sel_json" | jq -r --argjson now_ts "$now" '
        .[] | . as $b
        | ($b.labels // []) as $L
        | ( (($b.updated_at // $b.created_at // "") | fromdateiso8601?) // null ) as $epoch
        | [ $b.id,
            ($L | join(",")),
            ($b.issue_type // $b.type // "?"),
            ( if $epoch then (((($now_ts) - $epoch) / 60) | floor | tostring) else "?" end )
          ] | @tsv
      ' 2>/dev/null)
    [ -z "${rows:-}" ] && continue
    local gate_active
    while IFS=$'\t' read -r bid blabels btype age_min; do
      [ -z "${bid:-}" ] && continue
      gate_active="$(_gate_artifact_probe "$bid")"
      if [ "$gate_active" = "1" ]; then
        log "  - SKIP $bid ($(_store_name "$store")): active gate marker/run in flight — already dispatched+built+submitted, not a routing gap"
        continue
      fi
      flagged_tsv="${flagged_tsv}${bid}\t${store}\t${age_min}\t${blabels}\t${btype}\n"
    done <<< "$rows"
  done

  # Build the flagged-ids set once, used both for the empty-branch prune pass
  # and the non-empty branch below — always run resolution, even when this
  # sweep found nothing (that's the degenerate "everything got fixed, or
  # every store failed" case, and those two must not collapse to one verdict
  # either — see _pmrw_resolve_tracked_state's per-id fail-safe).
  local flagged_ids_json="[]"
  if [ -n "${flagged_tsv:-}" ]; then
    flagged_ids_json="$(printf '%b' "$flagged_tsv" | cut -f1 | jq -R -s -c 'split("\n") | map(select(length>0))' 2>/dev/null)"
    [ -z "${flagged_ids_json:-}" ] && flagged_ids_json="[]"
  fi

  local resolve_out; resolve_out="$(_pmrw_resolve_tracked_state "$state" "$flagged_ids_json")"
  local resolved_ids_json; resolved_ids_json="$(printf '%s' "$resolve_out" | jq -c '.resolved_ids // []' 2>/dev/null)"
  [ -z "${resolved_ids_json:-}" ] && resolved_ids_json="[]"
  state="$(printf '%s' "$resolve_out" | jq -c '.state // {}' 2>/dev/null)"
  [ -z "${state:-}" ] && state="{}"
  local resolved_count; resolved_count="$(printf '%s' "$resolved_ids_json" | jq 'length' 2>/dev/null)"
  [ -z "${resolved_count:-}" ] && resolved_count=0

  if [ -z "${flagged_tsv:-}" ]; then
    if [ "$resolved_count" -eq 0 ] && [ "$state" = "{}" ]; then
      log "OK: 0 armed-but-unrouted bead(s) found across ${#PMRW_STORES} store(s)"
    else
      log "OK: 0 armed-but-unrouted bead(s) this sweep (${resolved_count} resolved)"
    fi
    if [ "${PMRW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
      if [ "$state" = "{}" ] && [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE" 2>/dev/null || true
      elif [ "$state" != "{}" ]; then
        printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
      fi
    fi
    [ "$resolved_count" -gt 0 ] && return 1 || return 0
  fi

  # ── cooldown/state: alert only new-or-cooldown-expired, log the FULL
  # current flagged set. Process-substitution, NOT a pipe, so `state`
  # mutations survive the loop. ────────────────────────────────────────────
  local to_alert_tsv=""
  local bid store2 age_min labels btype last_alert
  while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    last_alert="$(printf '%s' "$state" | jq -r --arg id "$bid" '.[$id].last_alert // 0' 2>/dev/null)"
    case "$last_alert" in ''|*[!0-9]*) last_alert=0 ;; esac
    if [ "$last_alert" -eq 0 ] || [ $(( now - last_alert )) -ge "$PMRW_ALERT_COOLDOWN_S" ]; then
      to_alert_tsv="${to_alert_tsv}${bid}\t${store2}\t${age_min}\t${labels}\t${btype}\n"
      state="$(printf '%s' "$state" | jq -c --arg id "$bid" --arg store "$store2" --argjson now "$now" \
        '.[$id] = {store: $store, first_seen: (.[$id].first_seen // $now), last_alert: $now}' 2>/dev/null)"
    fi
  done < <(printf '%b' "$flagged_tsv")

  local total_flagged; total_flagged="$(printf '%b' "$flagged_tsv" | grep -c . || true)"
  local new_count; new_count="$(printf '%b' "$to_alert_tsv" | grep -c . || true)"

  log "FLAGGED: ${total_flagged} armed-but-unrouted bead(s) (>=${PMRW_GRACE_MINUTES}min old), ${resolved_count} resolved since last sweep"
  printf '%b' "$flagged_tsv" | while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    log "  - $bid ($(_store_name "$store2"), ${btype}) age=${age_min}min labels=[${labels}]"
  done

  if [ "${new_count:-0}" -eq 0 ] && [ "${resolved_count:-0}" -eq 0 ]; then
    log "OK: all ${total_flagged} flagged bead(s) already alerted within cooldown (${PMRW_ALERT_COOLDOWN_S}s) — no new notification"
    if [ "${PMRW_DRY_RUN:-0}" != "1" ]; then
      mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
      printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true
    fi
    return 1
  fi

  if [ "${PMRW_DRY_RUN:-0}" = "1" ]; then
    log "DRY_RUN: would comment on new/due bead(s), notify (-p ${PMRW_NOTIFY_PRIORITY}), and mail mayor; state not persisted"
    return 1
  fi

  # ── per-bead durable comment (new-or-cooldown-expired only), via --stdin ──
  local msg
  while IFS=$'\t' read -r bid store2 age_min labels btype; do
    [ -z "${bid:-}" ] && continue
    msg="pilot-missing-route-watchdog (ga-f54ui): this bead is armed (ctx:ready + exec:auto, labels=[${labels}]) and open, but carries NO gc.routed_to metadata. ARMED BUT UNREACHABLE: a pool worker's self-serve discovery (bd ready --metadata-field gc.routed_to=<target> --unassigned) will never find it without that field, and the Pilot's own re-dispatch pass may separately skip it if a stale pilot.dispatched_at is present — this can look 'ready' in every listing and the panel while nothing ever picks it up. age=${age_min}min type=${btype} store=$(_store_name "$store2"). Detection-only report — no metadata was changed by this watchdog. A human/Mayor should confirm the intended route (commonly derivable from an existing crew/<name>/<bead> branch owner, or wa-worker/ps-worker/dog for pool-eligible work) and set gc.routed_to to un-strand this bead."
    if [ -n "${PMRW_TEST_COMMENTS_LOG:-}" ]; then
      echo "comment:${bid}" >> "$PMRW_TEST_COMMENTS_LOG" 2>/dev/null || true
    else
      printf '%s' "$msg" | "$BD_BIN" -C "$store2" comment "$bid" --stdin 2>/dev/null || log "WARN: bd comment failed for $bid"
    fi
  done < <(printf '%b' "$to_alert_tsv")

  # ── aggregate notify + mail ─────────────────────────────────────────────
  local unchanged_count=$(( total_flagged - new_count ))
  local summary="ARMED BUT UNROUTED: ${new_count} new/due, ${resolved_count} resolved, ${unchanged_count} unchanged-already-reported — ${total_flagged} total currently flagged (>=${PMRW_GRACE_MINUTES}min old)."

  if [ -n "${PMRW_TEST_NOTIFIED:-}" ]; then
    echo "notify:$summary" >> "$PMRW_TEST_NOTIFIED" 2>/dev/null || true
  else
    command -v "${NOTIFY_BIN}" >/dev/null 2>&1 && \
      "${NOTIFY_BIN}" -t "Pilot: armed bead(s) missing route" -p "${PMRW_NOTIFY_PRIORITY}" "$summary" 2>/dev/null || true
  fi

  local mail_body="PILOT MISSING-ROUTE WATCHDOG — detection-only report (ga-f54ui).

${summary}
"
  if [ "${new_count:-0}" -gt 0 ]; then
    local new_lines; new_lines="$(printf '%b' "$to_alert_tsv" | while IFS=$'\t' read -r bid store2 age_min labels btype; do
      [ -z "${bid:-}" ] && continue
      echo "  ${bid}  ($(_store_name "$store2"), ${btype})  age=${age_min}min  labels=[${labels}]"
    done)"
    mail_body="${mail_body}
NEW/DUE (${new_count}) — why this cycle alerted:
${new_lines}
"
  fi
  if [ "${resolved_count:-0}" -gt 0 ]; then
    local resolved_lines; resolved_lines="$(printf '%s' "$resolved_ids_json" | jq -r '.[]' 2>/dev/null | while IFS= read -r rid; do
      [ -z "${rid:-}" ] && continue
      echo "  ${rid}  (routed, closed, no longer armed, or gone)"
    done)"
    mail_body="${mail_body}
RESOLVED (${resolved_count}) since last alert:
${resolved_lines}
"
  fi
  if [ "${unchanged_count:-0}" -gt 0 ]; then
    mail_body="${mail_body}
+${unchanged_count} already reported previously, unchanged — see the log for the full current list.
"
  fi
  mail_body="${mail_body}
This is DETECTION-ONLY — no gc.routed_to was set on any bead by this
watchdog (see the script header for why auto-repair from branch-owner
inference was considered and deferred). Per-bead detail for NEW/DUE beads is
also posted as a comment on each bead. Re-alerts for an already-flagged bead
are suppressed for ${PMRW_ALERT_COOLDOWN_S}s (state: ${STATE_FILE}). Full
current list always in the log: ${LOG}"

  if [ -n "${PMRW_TEST_MAILED:-}" ]; then
    { echo "mail:pilot-missing-route:$summary"; printf '%s\n' "$mail_body"; } >> "$PMRW_TEST_MAILED" 2>/dev/null || true
  else
    command -v "$GC_BIN" >/dev/null 2>&1 && \
      "$GC_BIN" mail send mayor \
        -s "Watchdog: ${total_flagged} armed bead(s) missing gc.routed_to (invisible to pool dispatch)" \
        -m "$mail_body" 2>/dev/null || true
  fi

  mkdir -p "$PMRW_STATE_DIR" 2>/dev/null || true
  printf '%s' "$state" > "$STATE_FILE" 2>/dev/null || true

  return 1
}

# ── selftest ──────────────────────────────────────────────────────────────────
if [ "${1:-}" = "--selftest" ] || [ "${PMRW_SELFTEST:-0}" = "1" ]; then
  PASS=0; FAIL=0
  ok()  { PASS=$((PASS+1)); echo "  ok  $1"; }
  bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

  PMRW_TEST_MODE=1
  LOG="$TMP/pmrw.log"
  NOTIFY_BIN="$TMP/notify"
  GC_BIN="$TMP/gc"
  BD_BIN="$TMP/bd"
  PMRW_ENABLED=1
  PMRW_DRY_RUN=0
  PMRW_GRACE_MINUTES=10
  PMRW_ALERT_COOLDOWN_S=21600
  PMRW_STATE_DIR="$TMP/state"
  STATE_FILE="$TMP/state/pmrw.state.json"
  HQ="$TMP/hq"
  STORE_A="$TMP/store-a"
  STORE_B="$TMP/store-b"
  PMRW_STORES="$STORE_A $STORE_B"

  mkdir -p "$TMP/fixtures-a" "$TMP/fixtures-b" "$PMRW_STATE_DIR"

  # Fake bd: routes on the -C store path AND verb, since this script queries
  # MULTIPLE stores and each needs its own independent fixture + failure mode.
  cat > "$BD_BIN" <<'BDSTUB'
#!/usr/bin/env bash
store=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [ "${args[$i]}" = "-C" ]; then store="${args[$((i+1))]}"; fi
done
verb="$3"
storekey=$(basename "$store")
case "$verb" in
  list)
    if [ "${args[3]:-}" = "--id" ]; then
      # recheck form: bd -C <store> list --id <id> --all --json
      idval="${args[4]:-}"
      f="$PMRW_TEST_RECHECK_DIR/${storekey}-${idval}.json"
      if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
        echo "simulated bd failure: connection refused" >&2
        exit 1
      fi
      [ -f "$f" ] && cat "$f" || echo "[]"
    elif [ "${args[3]:-}" = "-l" ] && [[ "${args[4]:-}" == source-bead:* ]]; then
      # gate-artifact-probe form: bd -C <store> list -l "source-bead:<id>" --json
      sbid="${args[4]#source-bead:}"
      f="$PMRW_TEST_GATEPROBE_DIR/${sbid}.json"
      [ -f "$f" ] && cat "$f" || echo "[]"
    else
      f="$PMRW_TEST_FIXTURES_DIR/${storekey}.json"
      if [ -f "$f" ] && grep -qx '__BD_FAIL__' "$f" 2>/dev/null; then
        echo "simulated bd failure: connection refused" >&2
        exit 1
      fi
      [ -f "$f" ] && cat "$f" || echo "[]"
    fi
    ;;
  comment)
    bid="$4"
    echo "comment:${bid}" >> "${PMRW_TEST_COMMENTS_LOG:-/dev/null}"
    ;;
  *) echo "[]" ;;
esac
BDSTUB
  chmod +x "$BD_BIN"
  printf '#!/usr/bin/env bash\necho "notify:$*" >> "$PMRW_TEST_NOTIFIED" 2>/dev/null; exit 0\n' > "$NOTIFY_BIN"
  printf '#!/usr/bin/env bash\n[ "$1" = "mail" ] && echo "mail:$*" >> "$PMRW_TEST_MAILED" 2>/dev/null; exit 0\n' > "$GC_BIN"
  chmod +x "$NOTIFY_BIN" "$GC_BIN"

  export PMRW_TEST_FIXTURES_DIR="$TMP/fixtures"
  export PMRW_TEST_RECHECK_DIR="$TMP/recheck"
  export PMRW_TEST_GATEPROBE_DIR="$TMP/gateprobe"
  mkdir -p "$PMRW_TEST_FIXTURES_DIR" "$PMRW_TEST_RECHECK_DIR" "$PMRW_TEST_GATEPROBE_DIR"

  OLD_TS="$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)"
  FRESH_TS="$(date -u -v-1M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)"

  mk() {  # id status labels_csv updated_at [metadata_json]
    local id="$1" status="$2" labels="$3" updated="$4" meta="${5:-}"
    [ -z "$meta" ] && meta='{}'
    local labels_json; labels_json="$(printf '%s' "$labels" | tr ',' '\n' | jq -R . | jq -s -c .)"
    printf '{"id":"%s","status":"%s","updated_at":"%s","labels":%s,"issue_type":"bug","metadata":%s}' \
      "$id" "$status" "$updated" "$labels_json" "$meta"
  }
  reset_stores() {
    echo '[]' > "$TMP/fixtures/store-a.json"
    echo '[]' > "$TMP/fixtures/store-b.json"
    rm -f "$STATE_FILE" 2>/dev/null
  }

  # ── Scenario 1: armed + unrouted + aged, store-a → FLAGGED ────────────────
  echo "Scenario 1: armed (ctx:ready+exec:auto), no gc.routed_to, aged → flagged"
  reset_stores
  printf '[%s]' "$(mk ga-1 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N1="$TMP/notif1"; M1="$TMP/mail1"; C1="$TMP/comm1"; : > "$N1"; : > "$M1"; : > "$C1"
  PMRW_TEST_NOTIFIED="$N1" PMRW_TEST_MAILED="$M1" PMRW_TEST_COMMENTS_LOG="$C1" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 1: flagged (return 1)" || bad "scenario 1: should return 1 (flagged), got $rc"
  grep -q "comment:ga-1" "$C1" 2>/dev/null && ok "scenario 1: bd comment posted (via --stdin)" || bad "scenario 1: no comment posted"
  grep -q "notify:" "$N1" 2>/dev/null && ok "scenario 1: notify fired" || bad "scenario 1: notify did NOT fire"
  grep -q "mail:" "$M1" 2>/dev/null && ok "scenario 1: mayor mailed" || bad "scenario 1: mayor NOT mailed"

  # ── Scenario 2 (core ACEITE requirement): armed + ROUTED → NEVER flags ────
  echo "Scenario 2: armed AND gc.routed_to set → NOT flagged, even though old"
  reset_stores
  printf '[%s]' "$(mk ga-2 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.routed_to":"wa-worker"}')" > "$TMP/fixtures/store-a.json"
  N2="$TMP/notif2"; M2="$TMP/mail2"; C2="$TMP/comm2"; : > "$N2"; : > "$M2"; : > "$C2"
  PMRW_TEST_NOTIFIED="$N2" PMRW_TEST_MAILED="$M2" PMRW_TEST_COMMENTS_LOG="$C2" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 2: routed bead never flags (return 0)" || bad "scenario 2: a routed bead must not flag, got $rc"
  [ ! -s "$C2" ] && ok "scenario 2: no comment posted" || bad "scenario 2 (false positive): comment posted on a routed bead"

  # ── Scenario 3: armed + unrouted but too FRESH → NOT flagged yet ─────────
  echo "Scenario 3: unrouted, only 1min old → NOT flagged (below grace)"
  reset_stores
  printf '[%s]' "$(mk ga-3 open 'ctx:ready,exec:auto' "$FRESH_TS")" > "$TMP/fixtures/store-a.json"
  N3="$TMP/notif3"; M3="$TMP/mail3"; C3="$TMP/comm3"; : > "$N3"; : > "$M3"; : > "$C3"
  PMRW_TEST_NOTIFIED="$N3" PMRW_TEST_MAILED="$M3" PMRW_TEST_COMMENTS_LOG="$C3" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 3: fresh bead not yet flagged (return 0)" || bad "scenario 3: should not flag within grace, got $rc"
  [ ! -s "$C3" ] && ok "scenario 3: no comment (still in grace)" || bad "scenario 3: comment posted before grace elapsed"

  # ── Scenario 4: CLOSED + unrouted → never touched ─────────────────────────
  echo "Scenario 4: closed bead, unrouted → never touched (defense-in-depth)"
  reset_stores
  printf '[%s]' "$(mk ga-4 closed 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N4="$TMP/notif4"; M4="$TMP/mail4"; C4="$TMP/comm4"; : > "$N4"; : > "$M4"; : > "$C4"
  PMRW_TEST_NOTIFIED="$N4" PMRW_TEST_MAILED="$M4" PMRW_TEST_COMMENTS_LOG="$C4" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 4: closed bead ignored (return 0)" || bad "scenario 4: closed bead must never flag, got $rc"
  [ ! -s "$C4" ] && ok "scenario 4: no comment on closed bead" || bad "scenario 4 (ACEITE violation): commented on a CLOSED bead"

  # ── Scenario 5: only ONE of ctx:ready/exec:auto present → NOT armed ───────
  echo "Scenario 5: only exec:auto (no ctx:ready) → not considered armed, not flagged"
  reset_stores
  printf '[%s]' "$(mk ga-5 open 'exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N5="$TMP/notif5"; M5="$TMP/mail5"; C5="$TMP/comm5"; : > "$N5"; : > "$M5"; : > "$C5"
  PMRW_TEST_NOTIFIED="$N5" PMRW_TEST_MAILED="$M5" PMRW_TEST_COMMENTS_LOG="$C5" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 5: half-armed bead not flagged (return 0)" || bad "scenario 5: needs BOTH labels, got $rc"

  # ── Scenario 6: gate:needs-human* → excluded ──────────────────────────────
  echo "Scenario 6: armed+unrouted+aged but gate:needs-human-decision → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-6 open 'ctx:ready,exec:auto,gate:needs-human-decision' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N6="$TMP/notif6"; M6="$TMP/mail6"; C6="$TMP/comm6"; : > "$N6"; : > "$M6"; : > "$C6"
  PMRW_TEST_NOTIFIED="$N6" PMRW_TEST_MAILED="$M6" PMRW_TEST_COMMENTS_LOG="$C6" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 6: gate:needs-human* excluded (return 0)" || bad "scenario 6: needs-human bead should be excluded, got $rc"

  # ── Scenario 7: pilot:held (unexpired, no held-until) → excluded ─────────
  echo "Scenario 7: pilot:held with no held-until label → still held → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-7 open 'ctx:ready,exec:auto,pilot:held' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N7="$TMP/notif7"; M7="$TMP/mail7"; C7="$TMP/comm7"; : > "$N7"; : > "$M7"; : > "$C7"
  PMRW_TEST_NOTIFIED="$N7" PMRW_TEST_MAILED="$M7" PMRW_TEST_COMMENTS_LOG="$C7" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 7: unexpired pilot:held excluded (return 0)" || bad "scenario 7: held bead should be excluded, got $rc"

  # ── Scenario 8: pilot:held-until EXPIRED → no longer excluded ────────────
  echo "Scenario 8: pilot:held but held-until already in the past → eligible again"
  reset_stores
  printf '[%s]' "$(mk ga-8 open 'ctx:ready,exec:auto,pilot:held,pilot:held-until:1000000000' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N8="$TMP/notif8"; M8="$TMP/mail8"; C8="$TMP/comm8"; : > "$N8"; : > "$M8"; : > "$C8"
  PMRW_TEST_NOTIFIED="$N8" PMRW_TEST_MAILED="$M8" PMRW_TEST_COMMENTS_LOG="$C8" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 8: expired hold no longer excludes (return 1, flagged)" || bad "scenario 8: expired hold should flag, got $rc"

  # ── Scenario 9: epic → excluded ───────────────────────────────────────────
  echo "Scenario 9: issue_type=epic, armed+unrouted+aged → excluded"
  reset_stores
  printf '[{"id":"ga-9","status":"open","updated_at":"%s","labels":["ctx:ready","exec:auto"],"issue_type":"epic","metadata":{}}]' "$OLD_TS" > "$TMP/fixtures/store-a.json"
  N9="$TMP/notif9"; M9="$TMP/mail9"; C9="$TMP/comm9"; : > "$N9"; : > "$M9"; : > "$C9"
  PMRW_TEST_NOTIFIED="$N9" PMRW_TEST_MAILED="$M9" PMRW_TEST_COMMENTS_LOG="$C9" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 9: epic excluded (return 0)" || bad "scenario 9: epic should be excluded, got $rc"

  # ── Scenario 10: graph.v2 step (gc.root_bead_id set) → excluded ──────────
  echo "Scenario 10: graph.v2 formula step (gc.root_bead_id) → excluded (different dispatch mechanism)"
  reset_stores
  printf '[%s]' "$(mk ga-10 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.root_bead_id":"ga-root1"}')" > "$TMP/fixtures/store-a.json"
  N10="$TMP/notif10"; M10="$TMP/mail10"; C10="$TMP/comm10"; : > "$N10"; : > "$M10"; : > "$C10"
  PMRW_TEST_NOTIFIED="$N10" PMRW_TEST_MAILED="$M10" PMRW_TEST_COMMENTS_LOG="$C10" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 10: graph.v2 step excluded (return 0)" || bad "scenario 10: graph.v2 step should be excluded, got $rc"

  # ── Scenario 11: pilot.sling_for wrapper bead → excluded ──────────────────
  echo "Scenario 11: Pilot-created sling wrapper (pilot.sling_for set) → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-11 open 'ctx:ready,exec:auto' "$OLD_TS" '{"pilot.sling_for":"ga-parent"}')" > "$TMP/fixtures/store-a.json"
  N11="$TMP/notif11"; M11="$TMP/mail11"; C11="$TMP/comm11"; : > "$N11"; : > "$M11"; : > "$C11"
  PMRW_TEST_NOTIFIED="$N11" PMRW_TEST_MAILED="$M11" PMRW_TEST_COMMENTS_LOG="$C11" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 11: sling wrapper excluded (return 0)" || bad "scenario 11: sling wrapper should be excluded, got $rc"

  # ── Scenario 12: cooldown suppresses re-alert on second sweep ────────────
  echo "Scenario 12: same bead flagged twice in a row within cooldown → only FIRST sweep alerts"
  reset_stores
  printf '[%s]' "$(mk ga-12 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N12a="$TMP/notif12a"; M12a="$TMP/mail12a"; C12a="$TMP/comm12a"; : > "$N12a"; : > "$M12a"; : > "$C12a"
  PMRW_TEST_NOTIFIED="$N12a" PMRW_TEST_MAILED="$M12a" PMRW_TEST_COMMENTS_LOG="$C12a" run_sweep >/dev/null
  grep -q "comment:ga-12" "$C12a" 2>/dev/null && ok "scenario 12: first sweep alerts" || bad "scenario 12: first sweep should alert"
  N12b="$TMP/notif12b"; M12b="$TMP/mail12b"; C12b="$TMP/comm12b"; : > "$N12b"; : > "$M12b"; : > "$C12b"
  PMRW_TEST_NOTIFIED="$N12b" PMRW_TEST_MAILED="$M12b" PMRW_TEST_COMMENTS_LOG="$C12b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 12: second sweep still reports flagged (return 1)" || bad "scenario 12: still-broken bead should still return 1, got $rc"
  [ ! -s "$C12b" ] && ok "scenario 12: second sweep does NOT re-comment (cooldown)" || bad "scenario 12: cooldown did not suppress re-comment"

  # ── Scenario 13: resolution — gc.routed_to added between sweeps → RESOLVED
  echo "Scenario 13: gc.routed_to added between sweeps → RESOLVED, pruned, individually rechecked"
  reset_stores
  printf '[%s]' "$(mk ga-13 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$TMP/notif13a"; : > "$TMP/mail13a"; : > "$TMP/comm13a"
  PMRW_TEST_NOTIFIED="$TMP/notif13a" PMRW_TEST_MAILED="$TMP/mail13a" PMRW_TEST_COMMENTS_LOG="$TMP/comm13a" run_sweep >/dev/null
  grep -q '"ga-13"' "$STATE_FILE" 2>/dev/null && ok "scenario 13: ga-13 tracked in state after first sweep" || bad "scenario 13: ga-13 should be tracked after first sweep"
  echo '[]' > "$TMP/fixtures/store-a.json"   # simulates: no longer matches the query (route now set)
  printf '[%s]' "$(mk ga-13 open 'ctx:ready,exec:auto' "$OLD_TS" '{"gc.routed_to":"wa-worker"}')" > "$TMP/recheck/store-a-ga-13.json"
  : > "$LOG"
  : > "$TMP/notif13b"; : > "$TMP/mail13b"; : > "$TMP/comm13b"
  PMRW_TEST_NOTIFIED="$TMP/notif13b" PMRW_TEST_MAILED="$TMP/mail13b" PMRW_TEST_COMMENTS_LOG="$TMP/comm13b" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 13: sweep reports resolution activity (return 1)" || bad "scenario 13: a resolution should still be reported, got $rc"
  grep -q '"ga-13"' "$STATE_FILE" 2>/dev/null && bad "scenario 13: ga-13 still in state after being resolved" || ok "scenario 13: ga-13 pruned from state"
  grep -q "RESOLVED: ga-13 re-checked individually (routed)" "$LOG" 2>/dev/null && ok "scenario 13: RESOLVED(routed) logged for ga-13" || bad "scenario 13: no RESOLVED(routed) log line for ga-13"

  # ── Scenario 14: recheck query FAILS → stays UNVERIFIED, not wrongly resolved
  echo "Scenario 14: bead vanishes from sweep AND its individual recheck query fails → stays in state (fail-safe)"
  reset_stores
  printf '[%s]' "$(mk ga-14 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  : > "$TMP/notif14a"; : > "$TMP/mail14a"; : > "$TMP/comm14a"
  PMRW_TEST_NOTIFIED="$TMP/notif14a" PMRW_TEST_MAILED="$TMP/mail14a" PMRW_TEST_COMMENTS_LOG="$TMP/comm14a" run_sweep >/dev/null
  grep -q '"ga-14"' "$STATE_FILE" 2>/dev/null && ok "scenario 14: ga-14 tracked after first sweep" || bad "scenario 14: ga-14 should be tracked after first sweep"
  echo '[]' > "$TMP/fixtures/store-a.json"
  echo '__BD_FAIL__' > "$TMP/recheck/store-a-ga-14.json"
  : > "$LOG"
  : > "$TMP/notif14b"; : > "$TMP/mail14b"; : > "$TMP/comm14b"
  PMRW_TEST_NOTIFIED="$TMP/notif14b" PMRW_TEST_MAILED="$TMP/mail14b" PMRW_TEST_COMMENTS_LOG="$TMP/comm14b" run_sweep
  grep -q '"ga-14"' "$STATE_FILE" 2>/dev/null && ok "scenario 14: ga-14 STILL in state (fail-safe, not wrongly resolved)" || bad "scenario 14 (ga-p5q3 violation): ga-14 pruned despite a failed recheck"
  grep -q "UNVERIFIED: ga-14 re-check query failed" "$LOG" 2>/dev/null && ok "scenario 14: UNVERIFIED logged" || bad "scenario 14: no UNVERIFIED log line"

  # ── Scenario 15: multi-store — store A fails, store B still swept ─────────
  echo "Scenario 15: store-a query fails, store-b has a real finding → store-b still flagged (per-store fail-open)"
  reset_stores
  echo '__BD_FAIL__' > "$TMP/fixtures/store-a.json"
  printf '[%s]' "$(mk wa-15 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-b.json"
  : > "$LOG"
  N15="$TMP/notif15"; M15="$TMP/mail15"; C15="$TMP/comm15"; : > "$N15"; : > "$M15"; : > "$C15"
  PMRW_TEST_NOTIFIED="$N15" PMRW_TEST_MAILED="$M15" PMRW_TEST_COMMENTS_LOG="$C15" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 15: store-b finding still flagged despite store-a failure (return 1)" || bad "scenario 15: store-b should still flag, got $rc"
  grep -q "comment:wa-15" "$C15" 2>/dev/null && ok "scenario 15: comment posted for store-b bead" || bad "scenario 15: no comment for store-b bead"
  grep -q "WARN.*store-a.*fail-open" "$LOG" 2>/dev/null && ok "scenario 15: WARN logged for failed store-a" || bad "scenario 15: no WARN for store-a failure"

  # ── Scenario 16: dry-run → detects but does not mutate/alert/persist ─────
  echo "Scenario 16: PMRW_DRY_RUN=1 → logs the finding, fires nothing, persists nothing"
  reset_stores
  printf '[%s]' "$(mk ga-16 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N16="$TMP/notif16"; M16="$TMP/mail16"; C16="$TMP/comm16"; : > "$N16"; : > "$M16"; : > "$C16"
  PMRW_DRY_RUN=1 PMRW_TEST_NOTIFIED="$N16" PMRW_TEST_MAILED="$M16" PMRW_TEST_COMMENTS_LOG="$C16" run_sweep
  rc=$?
  PMRW_DRY_RUN=0
  [ "$rc" -eq 1 ] && ok "scenario 16: dry-run still reports flagged (return 1)" || bad "scenario 16: dry-run should still report flagged, got $rc"
  [ ! -s "$C16" ] && [ ! -s "$N16" ] && [ ! -s "$M16" ] && ok "scenario 16: no comment/notify/mail fired in dry-run" || bad "scenario 16: dry-run must not fire any side effect"
  [ ! -f "$STATE_FILE" ] && ok "scenario 16: no state file written in dry-run" || bad "scenario 16: dry-run must not persist state"

  # ── Scenario 17: kill-switch → complete no-op ─────────────────────────────
  echo "Scenario 17: PMRW_ENABLED=0 → complete no-op"
  reset_stores
  printf '[%s]' "$(mk ga-17 open 'ctx:ready,exec:auto' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N17="$TMP/notif17"; M17="$TMP/mail17"; C17="$TMP/comm17"; : > "$N17"; : > "$M17"; : > "$C17"
  PMRW_ENABLED=0 PMRW_TEST_NOTIFIED="$N17" PMRW_TEST_MAILED="$M17" PMRW_TEST_COMMENTS_LOG="$C17" run_sweep
  rc=$?
  PMRW_ENABLED=1
  [ "$rc" -eq 0 ] && ok "scenario 17: kill-switch returns 0" || bad "scenario 17: kill-switch should return 0, got $rc"
  [ ! -s "$C17" ] && [ ! -s "$N17" ] && [ ! -s "$M17" ] && ok "scenario 17: no side effect while disabled" || bad "scenario 17: disabled watchdog fired a side effect"

  # ── Scenario 19: story:* label → excluded (separate tier-2 dispatch path) ─
  echo "Scenario 19: story:approved present → excluded (managed by the feature tier, not this bug)"
  reset_stores
  printf '[%s]' "$(mk ga-19 open 'ctx:ready,exec:auto,story:approved' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N19="$TMP/notif19"; M19="$TMP/mail19"; C19="$TMP/comm19"; : > "$N19"; : > "$M19"; : > "$C19"
  PMRW_TEST_NOTIFIED="$N19" PMRW_TEST_MAILED="$M19" PMRW_TEST_COMMENTS_LOG="$C19" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 19: story:* excluded (return 0)" || bad "scenario 19: story:* bead should be excluded, got $rc"

  # ── Scenario 20: pilot:refusal-count:* → excluded (already parked) ───────
  echo "Scenario 20: pilot:refusal-count:1 present → excluded (already explicitly refused/parked)"
  reset_stores
  printf '[%s]' "$(mk ga-20 open 'ctx:ready,exec:auto,pilot:refusal-count:1,pilot:refused-reason:some-reason' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N20="$TMP/notif20"; M20="$TMP/mail20"; C20="$TMP/comm20"; : > "$N20"; : > "$M20"; : > "$C20"
  PMRW_TEST_NOTIFIED="$N20" PMRW_TEST_MAILED="$M20" PMRW_TEST_COMMENTS_LOG="$C20" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 20: refusal-count excluded (return 0)" || bad "scenario 20: refused bead should be excluded, got $rc"

  # ── Scenario 21: needs:engine-window / framework:engine / no-auto-dispatch → excluded
  echo "Scenario 21: needs:engine-window + no-auto-dispatch present → excluded"
  reset_stores
  printf '[%s]' "$(mk ga-21 open 'ctx:ready,exec:auto,needs:engine-window,no-auto-dispatch' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N21="$TMP/notif21"; M21="$TMP/mail21"; C21="$TMP/comm21"; : > "$N21"; : > "$M21"; : > "$C21"
  PMRW_TEST_NOTIFIED="$N21" PMRW_TEST_MAILED="$M21" PMRW_TEST_COMMENTS_LOG="$C21" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 21: engine-window/no-auto-dispatch excluded (return 0)" || bad "scenario 21: should be excluded, got $rc"

  echo "Scenario 21b: framework:engine alone (no needs:engine-window) → also excluded"
  reset_stores
  printf '[%s]' "$(mk ga-21b open 'ctx:ready,exec:auto,framework:engine' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N21b="$TMP/notif21b"; M21b="$TMP/mail21b"; C21b="$TMP/comm21b"; : > "$N21b"; : > "$M21b"; : > "$C21b"
  PMRW_TEST_NOTIFIED="$N21b" PMRW_TEST_MAILED="$M21b" PMRW_TEST_COMMENTS_LOG="$C21b" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 21b: framework:engine excluded (return 0)" || bad "scenario 21b: framework:engine bead should be excluded, got $rc"

  # ── Scenario 22: ACTIVE gate marker in flight → excluded ─────────────────
  echo "Scenario 22: armed+unrouted+aged, but an OPEN gate marker with gate-status:reviewing already names it as source-bead → excluded (already dispatched+built+submitted)"
  reset_stores
  printf '[%s]' "$(mk ga-22 open 'ctx:ready,exec:auto,gate:queued' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  printf '[{"id":"ga-wisp-x","status":"open","labels":["type:quality-gate-marker","gate-status:reviewing","source-bead:ga-22"]}]' > "$TMP/gateprobe/ga-22.json"
  N22="$TMP/notif22"; M22="$TMP/mail22"; C22="$TMP/comm22"; : > "$N22"; : > "$M22"; : > "$C22"
  PMRW_TEST_NOTIFIED="$N22" PMRW_TEST_MAILED="$M22" PMRW_TEST_COMMENTS_LOG="$C22" run_sweep
  rc=$?
  rm -f "$TMP/gateprobe/ga-22.json"
  [ "$rc" -eq 0 ] && ok "scenario 22: active gate marker excludes (return 0)" || bad "scenario 22: bead with an active gate marker should be excluded, got $rc"

  # ── Scenario 23 (contrast to 22): STALE gate:* labels but NO active marker
  # → still flagged. This is the case scenario 22 must NOT be allowed to
  # over-exclude: a bead re-armed for retry after a past gate:failed cycle,
  # with the route never restored, is exactly ga-f54ui's own hypothesis and
  # must still be caught. ─────────────────────────────────────────────────
  echo "Scenario 23: stale gate:failed/gate:needs-fix labels but NO active marker for it → still flagged (re-armed-without-route-restore case)"
  reset_stores
  printf '[%s]' "$(mk ga-23 open 'ctx:ready,exec:auto,gate:failed,gate:needs-fix,gate:fix-attempt:2' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  # no gateprobe fixture for ga-23 → probe returns "[]" → 0 active → not excluded
  N23="$TMP/notif23"; M23="$TMP/mail23"; C23="$TMP/comm23"; : > "$N23"; : > "$M23"; : > "$C23"
  PMRW_TEST_NOTIFIED="$N23" PMRW_TEST_MAILED="$M23" PMRW_TEST_COMMENTS_LOG="$C23" run_sweep
  rc=$?
  [ "$rc" -eq 1 ] && ok "scenario 23: stale gate:* labels without an active marker still flags (return 1)" || bad "scenario 23 (would hide a real re-arm case): got $rc"
  grep -q "comment:ga-23" "$C23" 2>/dev/null && ok "scenario 23: comment posted despite stale gate:* labels" || bad "scenario 23: no comment — over-excluded on label residue alone"

  # ── Scenario 25: blocked-on:* → excluded even though status is still "open"
  echo "Scenario 25: blocked-on:<other-bead> present, status still open → excluded (explicit dependency marker, live wa-v66xt shape)"
  reset_stores
  printf '[%s]' "$(mk ga-25 open 'ctx:ready,exec:auto,blocked-on:ga-other' "$OLD_TS")" > "$TMP/fixtures/store-a.json"
  N25="$TMP/notif25"; M25="$TMP/mail25"; C25="$TMP/comm25"; : > "$N25"; : > "$M25"; : > "$C25"
  PMRW_TEST_NOTIFIED="$N25" PMRW_TEST_MAILED="$M25" PMRW_TEST_COMMENTS_LOG="$C25" run_sweep
  rc=$?
  [ "$rc" -eq 0 ] && ok "scenario 25: blocked-on excluded (return 0)" || bad "scenario 25: blocked-on bead should be excluded, got $rc"

  # ── Scenario 26: bash -n syntax check ──────────────────────────────────────
  echo "Scenario 26: bash -n syntax check"
  bash -n "$0" 2>/dev/null && ok "scenario 26: bash -n passes" || bad "scenario 26: bash -n FAILED — syntax error"

  echo ""
  echo "pilot-missing-route-watchdog selftest: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ] && exit 0 || exit 1
fi

run_sweep; exit 0  # daemon health = "ran OK"; findings (if any) already sent via comment+notify+mail

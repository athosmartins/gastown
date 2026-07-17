#!/usr/bin/env bash
# pilot-dispatcher.sh — Autonomous Pilot Dispatcher ("Pilot" / "P").
#
# Runs every ~300s via launchd (com.gascity.pilot.plist).
# PRIORITY DIRECTIVE: "Só depois do sistema perfeito é que a gente faz novas features."
#   Tier 1 (always first): open BUG beads (type:bug) + tech-debt-labeled beads NOT
#     already in-flight/done/assigned. Dispatched as fix tasks to the builder.
#   Tier 2 (only when Tier 1 is EMPTY): story:approved feature stories.
# Picks highest priority within the active tier (P0>P1>P2..., tie-break oldest),
# atomically claims it, dispatches a builder session via gc sling, then transitions
# the bead to story:in-flight.
#
# TWO-LANE DISPATCH (anti-deadlock):
#   SMALL/fast lane (MAX_SMALL, default 5): small items — merge fast, high concurrency.
#   BIG/slow  lane (MAX_BIG,   default 2): big items  — dedicated lane so they can't
#     hog the small lane and starve fast work.
#   Each lane has its OWN cap. A full big lane does NOT block small dispatches.
#   Lane classification (at dispatch time, in priority order):
#     1. Explicit label: lane:big or lane:small on the bead.
#     2. story.size_check metadata == "epic" → big.
#     3. Acceptance-criteria count >= 5 → big.
#     4. Default → small.
#   Tagged on dispatch (lane:big / lane:small) so in-flight counting works.
#   ESCALATION: a worker may relabel lane:small → lane:big mid-flight to correct
#   accounting; Pilot re-counts each sweep from actual bead labels.
#
# Bugs-first tiering is preserved WITHIN each lane.
#
# This is the FRONT HALF of the autonomous delivery loop:
#
#   Pilot (this) → spawns builder → builder implements → /gate-done
#     → G (quality-gate) reviews + merges → ① (story-delivery) deploys + tests
#
# DESIGN INVARIANTS:
#   - Claim is ATOMIC: add pilot:dispatching label + verify before acting.
#     TTL recovery releases stale pilot:dispatching claims after CLAIM_TTL_MINUTES.
#   - Capacity cap: per-lane caps (MAX_SMALL, MAX_BIG). Pilot fills whichever lane
#     has a free slot, up to one dispatch per lane per sweep (or all available slots).
#   - Idempotent: skip beads with story:in-flight, story:done, or already
#     assigned (assignee set). Never dispatch the same bead twice.
#   - Dependency-aware (ga-5ew): skip beads BLOCKED by unresolved (open)
#     dependencies. A story is only dispatchable once every bead it hard-depends
#     on is closed/merged. Uses bd's blocker-aware `bd blocked` set, per-DB,
#     fail-open. See _filter_unblocked.
#   - Self-exclusion: never dispatch the bead labeled pilot:self (the Pilot itself
#     — it cannot build itself). Resolved dynamically at each sweep start.
#   - Cross-rig aware: reads HQ DB (authoritative for all story beads per
#     convention). Falls back to scanning rig DBs if HQ returns none.
#   - Builder routing: maps story.rig metadata → gc sling target using the
#     RIG_TO_BUILDER table below. Falls back to gastown.dog for unknown rigs.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#   - DRY_RUN=1 → shows full pick + would-dispatch, makes zero state changes.
#
# Usage:
#   bash pilot-dispatcher.sh            # normal run
#   DRY_RUN=1 bash pilot-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

# City root. Defaults to the live HQ. PILOT_CITY_OVERRIDE is a TEST-ONLY seam
# (used by pilot-dispatcher.selftest.sh to redirect bd -C / logs / jsonl into a
# throwaway fixture); it is never set in production, where this resolves to the
# hardcoded default. Mirrors the SKILL_AUDIT_* override convention.
GC_CITY="${PILOT_CITY_OVERRIDE:-/Users/athos/gt/.gascity-gastown-hq}"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/pilot-dispatcher.log"
PILOT_LOG="$GC_CITY/.gc/pilot-dispatcher.jsonl"

# ── Two-lane caps ─────────────────────────────────────────────────────────────
MAX_SMALL="${MAX_SMALL:-5}"
MAX_BIG="${MAX_BIG:-2}"

# Acceptance-criteria count threshold for auto-classifying a story as BIG.
BIG_CRITERIA_THRESHOLD="${BIG_CRITERIA_THRESHOLD:-5}"

# TTL for stuck pilot:dispatching claims (minutes). After this, Pilot recycles them.
CLAIM_TTL_MINUTES="${CLAIM_TTL_MINUTES:-30}"

# Dry-run mode: show what WOULD happen, make zero changes.
DRY_RUN="${DRY_RUN:-0}"

# Common exclude-label flags shared by every Tier 1 candidate bd list call.
COMMON_EXCLUDES=(
  "--exclude-label" "story:in-flight"
  "--exclude-label" "story:done"
  "--exclude-label" "pilot:dispatching"
  "--exclude-label" "gate:needs-human"
)

# Tier 2 / feature queries also exclude gate:passed (delivery already in progress).
TIER2_EXCLUDES=(
  "${COMMON_EXCLUDES[@]}"
  "--exclude-label" "gate:passed"
)

# ── Rig → Builder routing table ───────────────────────────────────────────────
# WA rig-native dispatch (ctx:ready) uses _dispatch_wa_ctx_ready below — it picks
# from the live WA crew pool directly. rig_to_builder is used ONLY for HQ/rig-fallback
# Tier 1/2 sling paths, so the WA mapping here now falls through to gastown.dog (safe
# fallback; HQ story:approved wa-* beads will still go through sling if they appear).
rig_to_builder() {
  local rig="$1"
  case "$rig" in
    property_scrapers|ps) echo "batista-ps"  ;;
    whatsapp_automation|wa) echo "gastown.dog" ;;
    *)                      echo "gastown.dog" ;;
  esac
}

# ── WA crew pool (ga-mfeip) ───────────────────────────────────────────────────
# Live WA crews eligible for ctx:ready dispatch.
# EXCLUDED: digo-wa (suspended=true in agent.toml) and oracle-wa (human-operated).
WA_CTX_CREWS=("thies-wa" "peter-wa" "batista-wa" "mila-wa")
WA_RIG_PATH="/Users/athos/gt/whatsapp_automation"

# ── Lane classification ───────────────────────────────────────────────────────
classify_lane() {
  local bead="$1"

  local labels
  labels=$(echo "$bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  if echo "$labels" | grep -q "lane:big";   then echo "big";   return; fi
  if echo "$labels" | grep -q "lane:small"; then echo "small"; return; fi

  local size_check
  size_check=$(echo "$bead" | jq -r '.metadata["story.size_check"] // ""' 2>/dev/null || echo "")
  if [ "$size_check" = "epic" ]; then echo "big"; return; fi

  local criteria crit_count
  criteria=$(echo "$bead" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""' 2>/dev/null || echo "")
  # Count lines with at least one non-whitespace character (blank-line safe).
  crit_count=$(printf '%s' "$criteria" | grep -cE '[^[:space:]]' 2>/dev/null || echo "0")
  crit_count=$(printf '%s' "$crit_count" | tr -d '[:space:]')
  crit_count=${crit_count:-0}
  if [ "$crit_count" -ge "$BIG_CRITERIA_THRESHOLD" ] 2>/dev/null; then echo "big"; return; fi

  echo "small"
}

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: $*"; }

echo ""
log "=== Pilot sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Self-bead resolution ─────────────────────────────────────────────────────
# Resolved dynamically via pilot:self label — never hardcoded. Falls back to a
# sentinel that matches no real bead ID if no bead has the label.
SELF_BEAD_ID=$(bd -C "$GC_CITY" list --json -l "pilot:self" 2>/dev/null \
  | jq -r '.[0].id // empty' 2>/dev/null || echo "")

# ── Candidate filter helpers ──────────────────────────────────────────────────

# _filter_candidates — filter out self-bead + already-assigned from stdin JSON array.
_filter_candidates() {
  local arr
  arr=$(cat)
  printf '%s' "$arr" | jq --arg self "${SELF_BEAD_ID:-__none__}" \
    '[.[] | select(.id != $self and (.assignee == null or .assignee == ""))]' \
    2>/dev/null || printf '%s' "$arr"
}

# _filter_unblocked <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates blocked by unresolved deps in <db_dir>. Fail-open.
_filter_unblocked() {
  local db_dir="$1"
  local arr blocked_ids blocked_json before after filtered
  arr=$(cat)

  blocked_ids=$(bd -C "$db_dir" blocked --json 2>/dev/null \
    | jq -r '(.[]?.id) // empty' 2>/dev/null || echo "")
  if [ -z "$blocked_ids" ]; then
    printf '%s' "$arr"
    return 0
  fi

  blocked_json=$(printf '%s\n' "$blocked_ids" \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")

  before=$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo "0")
  filtered=$(printf '%s' "$arr" | jq --argjson blk "$blocked_json" \
    '[.[] | select((.id as $i | $blk | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  after=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo "0")

  if [ "$before" != "$after" ]; then
    warn "excluded $((before - after)) blocked candidate(s) in $db_dir (unresolved deps — ga-5ew fix)" >&2
  fi
  printf '%s' "$filtered"
}

# ── ga-qw7y6: defense-in-depth — skip beads already PASSED/SUPERSEDED by the gate ─
# Even with the gate's cross-store close fixed (quality-gate-dispatcher.sh
# resolve_bead_city), a close can still fail transiently (Dolt hiccup), leaving a
# merged source bead OPEN. Pilot must NEVER re-dispatch already-merged work: doing
# so spins up a builder which discovers the branch is already merged, rebuilds
# nothing, and burns a lane slot + gate cycle (ga-8tv0s was phantom-re-dispatched
# 3×: ga-dek6y→ga-6oqok→ga-ztksa). The durable, cross-store signal is the gate
# MARKER (type:quality-gate-run, ALWAYS resident in the HQ store regardless of
# which rig built the branch): label source-bead:<id> + gate-status:passed or
# gate-status:superseded == the work merged.
#
# GATED_BEADS — newline-separated set of source-bead IDs carrying a terminal-
# success gate marker. Built ONCE per sweep via two bounded HQ queries. Stays
# empty on any error (fail-open: a failed marker scan must never block dispatch).
GATED_BEADS=""
_build_gated_set() {
  local passed superseded
  # Passed markers stay OPEN (the dispatcher keeps them open); superseded markers
  # are CLOSED. --all covers both. Markers live in HQ (GC_CITY) for every rig.
  passed=$(bd -C "$GC_CITY" list --all --json -l "gate-status:passed" 2>/dev/null \
    | jq -r '.[]?.labels[]? | select(startswith("source-bead:")) | ltrimstr("source-bead:")' 2>/dev/null || true)
  superseded=$(bd -C "$GC_CITY" list --all --json -l "gate-status:superseded" 2>/dev/null \
    | jq -r '.[]?.labels[]? | select(startswith("source-bead:")) | ltrimstr("source-bead:")' 2>/dev/null || true)
  GATED_BEADS=$(printf '%s\n%s\n' "$passed" "$superseded" | grep -vE '^[[:space:]]*$' | sort -u || true)
  local n
  n=$(printf '%s' "$GATED_BEADS" | grep -cE '[^[:space:]]' 2>/dev/null || echo 0)
  n=$(printf '%s' "$n" | tr -d '[:space:]'); n=${n:-0}
  log "ga-qw7y6 defense: $n bead(s) carry a terminal-success gate marker (passed/superseded) — barred from re-dispatch."
}

# _filter_gated   (reads candidate JSON array from stdin)
# Drops candidates whose id is in GATED_BEADS (already merged via the gate). Runs
# per-tier (before tier selection) so a gated bead never counts toward a tier's
# candidate total. Fail-open: any jq error returns the input unchanged.
_filter_gated() {
  local arr
  arr=$(cat)
  [ -z "$GATED_BEADS" ] && { printf '%s' "$arr"; return 0; }
  local gated_json before after filtered
  gated_json=$(printf '%s\n' "$GATED_BEADS" \
    | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || echo "[]")
  before=$(printf '%s' "$arr" | jq 'length' 2>/dev/null || echo 0)
  filtered=$(printf '%s' "$arr" | jq --argjson g "$gated_json" \
    '[.[] | select((.id as $i | $g | index($i)) | not)]' 2>/dev/null) \
    || { printf '%s' "$arr"; return 0; }
  [ -z "$filtered" ] && { printf '%s' "$arr"; return 0; }
  after=$(printf '%s' "$filtered" | jq 'length' 2>/dev/null || echo 0)
  if [ "$before" != "$after" ]; then
    warn "ga-qw7y6: excluded $((before - after)) candidate(s) with a terminal-success gate marker (already merged — phantom re-dispatch prevented)" >&2
  fi
  printf '%s' "$filtered"
}

# ── ga-mfeip: WA ctx:ready quality gates ─────────────────────────────────────
#
# _wa_ctx_ready_passes_gates <bead_json> <dispatched_ids_newline_sep>
#
# Returns 0 (passes) or 1 (skip) for a single WA ctx:ready bead.
# Implements all 6 quality gates:
#   Gate 1 — NOT status=blocked AND NOT labeled needs-human/needs-human-decision/gate:needs-human
#   Gate 2 — Acceptance Criteria NON-EMPTY (story.criterios / acceptance_criteria)
#   Gate 3 — No cost-decision / prod-experiment / ban-risk markers
#   Gate 4 — No UNMET dependencies (bd blocked set, fail-open)
#   Gate 5 — Only exec:auto (never exec:manual)
#   Gate 6 — Not already assigned/in-flight (dedup)
#
# <dispatched_ids_newline_sep> is a newline-separated set of bead IDs already
# dispatched in this sweep (within-sweep dedup across crews).
_wa_ctx_ready_passes_gates() {
  local bead_json="$1"
  local sweep_dispatched="$2"  # newline-separated IDs dispatched this sweep

  local bead_id labels_csv status assignee

  bead_id=$(printf '%s' "$bead_json" | jq -r '.id // empty' 2>/dev/null || echo "")
  [ -z "$bead_id" ] && return 1  # malformed

  labels_csv=$(printf '%s' "$bead_json" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  status=$(printf '%s' "$bead_json" | jq -r '.status // ""' 2>/dev/null || echo "")
  assignee=$(printf '%s' "$bead_json" | jq -r '.assignee // ""' 2>/dev/null || echo "")

  # Gate 1: skip blocked status or human-gated labels
  if [ "$status" = "blocked" ]; then
    log "  WA gate1 SKIP $bead_id: status=blocked"
    return 1
  fi
  if printf '%s' "$labels_csv" | grep -qE '(^|,)(needs-human|needs-human-decision|gate:needs-human)(,|$)'; then
    log "  WA gate1 SKIP $bead_id: has needs-human label"
    return 1
  fi

  # Gate 5: only exec:auto (check early to avoid false-positives on unclassified beads)
  if printf '%s' "$labels_csv" | grep -qE '(^|,)exec:manual(,|$)'; then
    log "  WA gate5 SKIP $bead_id: exec:manual (human-only)"
    return 1
  fi
  # Beads without exec:auto label are not explicitly auto-approved — skip them too.
  if ! printf '%s' "$labels_csv" | grep -qE '(^|,)exec:auto(,|$)'; then
    log "  WA gate5 SKIP $bead_id: no exec:auto label (not classified for autonomous dispatch)"
    return 1
  fi

  # Gate 2: acceptance criteria must be non-empty
  local ac
  ac=$(printf '%s' "$bead_json" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""' 2>/dev/null || echo "")
  # Strip whitespace; empty after strip = skip
  ac_stripped=$(printf '%s' "$ac" | tr -d '[:space:]')
  if [ -z "$ac_stripped" ]; then
    log "  WA gate2 SKIP $bead_id: empty acceptance criteria (not refined)"
    return 1
  fi

  # Gate 3: cost-decision / prod-experiment / ban-risk markers
  # Check labels for known risk markers
  if printf '%s' "$labels_csv" | grep -qiE '(^|,)(cost-decision|prod-experiment|ban-risk|experiment)(,|$)'; then
    log "  WA gate3 SKIP $bead_id: has cost/prod-risk label"
    return 1
  fi
  # Conservative body keyword scan — when in doubt, skip
  local body
  body=$(printf '%s' "$bead_json" | jq -r '(.description // "") + " " + (.notes // "")' 2>/dev/null || echo "")
  if printf '%s' "$body" | grep -qiE \
      'decisão de custo|bloqueado em decisão|ban[- ]risk|session.logout|prod-experiment|criar zona paga|adicionar fundos|budget|never.?(logout|send)|guardrail'; then
    log "  WA gate3 SKIP $bead_id: body contains cost/ban-risk/prod-experiment keywords"
    return 1
  fi

  # Gate 6: dedup — not already assigned/in-flight, not already dispatched this sweep
  if [ -n "$assignee" ] && [ "$assignee" != "null" ]; then
    log "  WA gate6 SKIP $bead_id: already assigned to '$assignee'"
    return 1
  fi
  if printf '%s' "$labels_csv" | grep -qE '(^|,)(story:in-flight|pilot:dispatched|pilot:dispatching)(,|$)'; then
    log "  WA gate6 SKIP $bead_id: already in-flight/dispatched"
    return 1
  fi
  # Within-sweep dedup
  if printf '%s\n' "$sweep_dispatched" | grep -qxF "$bead_id" 2>/dev/null; then
    log "  WA gate6 SKIP $bead_id: already dispatched this sweep (dedup)"
    return 1
  fi

  # Gate 4: no unmet dependencies (use bd blocked set, fail-open)
  # _filter_unblocked already does this on the full array — but we verify per-bead
  # using the blocked_by field already present in bd --json output.
  local blocked_by_count
  blocked_by_count=$(printf '%s' "$bead_json" | jq -r '.blocked_by_count // 0' 2>/dev/null || echo "0")
  blocked_by_count=$(printf '%s' "$blocked_by_count" | tr -d '[:space:]'); blocked_by_count=${blocked_by_count:-0}
  if [ "$blocked_by_count" -gt 0 ] 2>/dev/null; then
    local blocked_by_ids
    blocked_by_ids=$(printf '%s' "$bead_json" | jq -r '(.blocked_by // []) | join(",")' 2>/dev/null || echo "?")
    log "  WA gate4 SKIP $bead_id: has $blocked_by_count unmet dep(s): $blocked_by_ids"
    return 1
  fi

  return 0
}

# _wa_crew_capacity <crew_name> <wa_rig_path>
# Prints the number of ctx:ready beads currently in-flight (story:in-flight) for
# this crew in the WA store. Fail-open (returns 99 on error → crew treated as busy).
_wa_crew_capacity() {
  local crew="$1" wa_path="$2"
  local count
  count=$(bd -C "$wa_path" list --json \
    -l "ctx:ready" \
    -l "story:in-flight" \
    -n 0 2>/dev/null \
    | jq --arg c "$crew" '[.[] | select(.assignee == $c)] | length' 2>/dev/null \
    || echo "99")
  count=$(printf '%s' "$count" | tr -d '[:space:]'); count=${count:-99}
  printf '%s' "$count"
}

# WA_CTX_CAPACITY_PER_CREW — max ctx:ready in-flight per WA crew per sweep.
WA_CTX_CAPACITY_PER_CREW="${WA_CTX_CAPACITY_PER_CREW:-1}"

# _dispatch_wa_ctx_ready <bead_json> <crew>
# Dispatches one WA ctx:ready bead to a live WA crew via the rig-native path:
#   1. Claim via pilot:dispatching label in WA store
#   2. Assign via bd -C <wa_path> update <bead> --assignee <crew>
#   3. Add story:in-flight + pilot:dispatched labels
#   4. Nudge crew
#   5. Post dispatch comment + emit JSONL event + notify
# Returns 0 on success, 1 on failure (claim released on failure).
_dispatch_wa_ctx_ready() {
  local bead_json="$1"
  local crew="$2"

  local wa_bead_id wa_bead_title wa_bead_priority

  wa_bead_id=$(printf '%s' "$bead_json" | jq -r '.id' 2>/dev/null || echo "")
  wa_bead_title=$(printf '%s' "$bead_json" | jq -r '.title // .description // "untitled"' 2>/dev/null | head -c 100)
  wa_bead_priority=$(printf '%s' "$bead_json" | jq -r '.priority // 99' 2>/dev/null || echo "99")

  log "  WA ctx:ready dispatch: $wa_bead_id → $crew (P${wa_bead_priority}: $wa_bead_title)"

  if [ "$DRY_RUN" = "1" ]; then
    log "  DRY_RUN=1 — WOULD: bd -C $WA_RIG_PATH label add $wa_bead_id pilot:dispatching"
    log "  DRY_RUN=1 — WOULD: bd -C $WA_RIG_PATH update $wa_bead_id --assignee $crew"
    log "  DRY_RUN=1 — WOULD: bd -C $WA_RIG_PATH label add $wa_bead_id story:in-flight pilot:dispatched"
    log "  DRY_RUN=1 — WOULD: gc session nudge $crew <task prompt>"
    return 0
  fi

  # Atomic claim
  bd -C "$WA_RIG_PATH" label add "$wa_bead_id" "pilot:dispatching" -q 2>/dev/null || {
    warn "WA ctx:ready: could not claim $wa_bead_id (pilot:dispatching label add failed). Skipping."
    return 1
  }

  # Verify claim / race check
  local _verify_labels
  _verify_labels=$(bd -C "$WA_RIG_PATH" show "$wa_bead_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
  if printf '%s' "$_verify_labels" | grep -qE '(^|,)(story:in-flight|pilot:dispatched)(,|$)'; then
    log "  WA ctx:ready: $wa_bead_id already in-flight after claim check (race). Releasing."
    bd -C "$WA_RIG_PATH" label remove "$wa_bead_id" "pilot:dispatching" -q 2>/dev/null || true
    return 1
  fi

  # Rig-native assignment
  if ! bd -C "$WA_RIG_PATH" update "$wa_bead_id" --assignee "$crew" -q 2>/dev/null; then
    warn "WA ctx:ready: bd update --assignee failed for $wa_bead_id. Releasing claim."
    bd -C "$WA_RIG_PATH" label remove "$wa_bead_id" "pilot:dispatching" -q 2>/dev/null || true
    return 1
  fi

  # Transition labels — story:in-flight BEFORE removing pilot:dispatching
  if ! bd -C "$WA_RIG_PATH" label add "$wa_bead_id" "story:in-flight" -q 2>/dev/null; then
    warn "WA ctx:ready: story:in-flight label failed for $wa_bead_id — pilot:dispatching retained for TTL recovery."
    return 1
  fi
  bd -C "$WA_RIG_PATH" label remove "$wa_bead_id" "pilot:dispatching" -q 2>/dev/null || true
  bd -C "$WA_RIG_PATH" label add    "$wa_bead_id" "pilot:dispatched"  -q 2>/dev/null || true

  # Store dispatch metadata
  local _now_epoch _now_ts
  _now_epoch=$(date +%s)
  _now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  bd -C "$WA_RIG_PATH" update "$wa_bead_id" \
    --set-metadata "pilot.dispatched_at=$_now_epoch" \
    --set-metadata "pilot.crew=$crew" \
    -q 2>/dev/null || true

  # Post dispatch comment
  local _cmt
  _cmt="Pilot (ga-mfeip) dispatched ctx:ready bead to '$crew' at $_now_ts.
Builder doctrine: build → /gate-done → autonomous gate+delivery → story:done.
Dispatched via rig-native path (bd -C whatsapp_automation update --assignee)."
  bd -C "$WA_RIG_PATH" comment "$wa_bead_id" "$_cmt" 2>/dev/null || true

  # Nudge crew with task context
  local _task_prompt
  _task_prompt="PILOT WA DISPATCH (ga-mfeip) — ctx:ready bead assigned

Bead ID: $wa_bead_id
Title: $wa_bead_title
Priority: P${wa_bead_priority}
Rig: whatsapp_automation
City: $WA_RIG_PATH

## Your job
Build this task from acceptance criteria to /gate-done. Do NOT wait for a human.

## Steps
1. Read the full bead: bd -C \"$WA_RIG_PATH\" show \"$wa_bead_id\"
2. Run gc prime to load your full context.
3. Implement on a branch (feat/${wa_bead_id} or crew/\$GC_ALIAS/${wa_bead_id}).
4. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C \"$WA_RIG_PATH\" assign \"$wa_bead_id\" \"\$GC_ALIAS\"
bd -C \"$WA_RIG_PATH\" status in_progress \"$wa_bead_id\"

Start now. Do not wait for permission."

  gc --city "$GC_CITY" session nudge "$crew" "$_task_prompt" \
    --delivery wait-idle 2>/dev/null \
    || warn "WA ctx:ready: could not nudge $crew — crew will see the task on next hook cycle"

  # JSONL event
  mkdir -p "$(dirname "$PILOT_LOG")"
  jq -c -n \
    --arg ts "$_now_ts" \
    --arg bead_id "$wa_bead_id" \
    --arg title "$wa_bead_title" \
    --arg crew "$crew" \
    --arg rig "whatsapp_automation" \
    --arg wa_path "$WA_RIG_PATH" \
    --argjson priority "$wa_bead_priority" \
    --arg dry_run "$DRY_RUN" \
    '{ts: $ts, event: "pilot_wa_ctx_dispatch", bead_id: $bead_id, title: $title,
      crew: $crew, rig: $rig, wa_path: $wa_path, priority: $priority,
      tier: "wa_ctx_ready", dry_run: $dry_run}' \
    >> "$PILOT_LOG" 2>/dev/null || true

  notify -t "Pilot WA dispatch" -p 3 \
    "$wa_bead_id (P${wa_bead_priority}) → $crew | $wa_bead_title" \
    2>/dev/null || true

  log "  WA ctx:ready dispatched: $wa_bead_id → $crew DONE"
  return 0
}

# _top_candidate <json_array>
# Prints the highest-priority candidate (P0>P1>P2, tie-break oldest).
_top_candidate() {
  local arr="$1"
  printf '%s' "$arr" | jq 'sort_by([(.priority // 99), .created_at]) | .[0]' 2>/dev/null
}

# ── Dispatch sub-functions ────────────────────────────────────────────────────
# All sub-functions read shared state from dispatch_one's scope (STORY_ID, BEAD_DB,
# LANE, DISPATCH_TIER, etc.) via bash dynamic scoping — no redundant arg passing.

# _claim_bead — atomically claim STORY_ID in BEAD_DB.
# Returns 0 on success, 1 on race/error (claim NOT held on 1).
_claim_bead() {
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD: bd label add $STORY_ID pilot:dispatching"
    return 0
  fi

  bd -C "$BEAD_DB" label add "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || {
    warn "Could not add pilot:dispatching to $STORY_ID (race condition or bd error). Skipping."
    return 1
  }

  local _vj _vl
  _vj=$(bd -C "$BEAD_DB" show "$STORY_ID" --json 2>/dev/null || echo "[]")
  _vl=$(printf '%s' "$_vj" \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' \
    2>/dev/null || echo "")

  if [ -z "$_vl" ]; then
    warn "Could not verify $STORY_ID claim state (bd show returned empty). Releasing claim."
    bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    return 1
  fi

  if printf '%s' "$_vl" | grep -q "story:in-flight"; then
    log "Story $STORY_ID already in-flight (race condition). Releasing claim."
    bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    return 1
  fi
  if printf '%s' "$_vl" | grep -q "story:done"; then
    log "Story $STORY_ID already done. Releasing claim."
    bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    return 1
  fi
  return 0
}

# _build_task_prompt — populate _DISPATCH_TASK global.
# Reads: STORY_ID STORY_TITLE STORY_PRIORITY STORY_RIG BEAD_DB LANE DISPATCH_TIER
#        STORY_CRITERIA STORY_ESTRELA STORY_EQUILIBRIOS GATE_FIX_SECTION
# Tier-specific text is extracted into local variables; shared doctrine, steps header,
# and claim block are written once in a single heredoc (no duplication).
_build_task_prompt() {
  local _hdr _id_label _type_line _job _crit_label _star_label _step3 _step4 \
        _verb _done_verb _loop_end

  if [ "$DISPATCH_TIER" = "bug" ]; then
    _hdr="Bug/tech-debt assigned for autonomous fix"
    _id_label="Bead ID"
    _type_line="BUG / TECH-DEBT (Tier 1 — dispatched BEFORE new features)"
    _job="Fix this bug or tech-debt item completely. Do NOT wait for a human.
\"Só depois do sistema perfeito é que a gente faz novas features.\" — system quality first."
    _crit_label="Description / Acceptance Criteria"
    _star_label="Additional Context"
    _step3="Diagnose root cause, implement fix on a branch (name: fix/${STORY_ID})."
    _step4="Add a regression test if applicable."
    _verb="fix"
    _done_verb="fix is complete"
    _loop_end="bead closed"
  else
    _hdr="Story assigned for autonomous build"
    _id_label="Story ID"
    _type_line="FEATURE (Tier 2 — dispatched only because no open bugs/tech-debt)"
    _job="Build this story from acceptance criteria to /gate-done. Do NOT wait for a human."
    _crit_label="Acceptance Criteria"
    _star_label="Estrela Guia (north star)"
    _step3="Implement the story on a feature branch (name: feat/${STORY_ID} or story/${STORY_ID})."
    _step4="Add a story-specific prod test at the required path (see delivery-runbooks.toml)."
    _verb="build"
    _done_verb="implementation is complete"
    _loop_end="story:done"
  fi

  _DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — $_hdr

$_id_label: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: $_type_line
Lane: $LANE
Rig: $STORY_RIG
City: $BEAD_DB

## Your job
$_job
$GATE_FIX_SECTION

## $_crit_label
$STORY_CRITERIA

## $_star_label
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your $_done_verb: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just $_verb, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → $_loop_end.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.

## Steps
1. Read the full bead: bd -C "$BEAD_DB" show "$STORY_ID"
2. Run gc prime to load your full context.
3. $_step3
4. $_step4
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$BEAD_DB" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$BEAD_DB" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
}

# _do_sling <sling_title> — dispatch via gc sling, verify bead in Dolt, nudge builder.
# Reads: STORY_ID BUILDER_TARGET STORY_RIG _DISPATCH_TASK GC_CITY BEAD_DB LANE DISPATCH_TIER
# Sets:  _SLING_BEAD_ID _DISPATCH_RESULT
# Returns 0 on success, 1 on failure (claim already released on failure).
_do_sling() {
  local sling_title="$1"

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD DISPATCH (tier=$DISPATCH_TIER lane=$LANE):"
    log "  gc --city $GC_CITY sling $BUILDER_TARGET <task_bead> --nudge"
    log "  Task title: '$sling_title'"
    log "  Rig: $STORY_RIG → builder: $BUILDER_TARGET"
    log "  WOULD: bd label add $STORY_ID lane:${LANE}"
    log "  WOULD: bd label add $STORY_ID story:in-flight"
    log "  WOULD: bd label remove $STORY_ID pilot:dispatching"
    log "  WOULD: bd label add $STORY_ID pilot:dispatched"
    _SLING_BEAD_ID="DRY_RUN_NO_SLING"
    _DISPATCH_RESULT="dry_run"
    return 0
  fi

  local _sling_err_file _sling_err _sling_out
  _sling_err_file=$(mktemp /tmp/pilot-sling-err.XXXXXX 2>/dev/null || echo "/tmp/pilot-sling-err.$$")
  trap "rm -f '${_sling_err_file}'" RETURN
  _sling_out=$(gc --city "$GC_CITY" sling "$BUILDER_TARGET" \
    "$sling_title" \
    --nudge \
    --json \
    2>"$_sling_err_file" || echo "{}")
  _sling_err=$(head -c 300 "$_sling_err_file" 2>/dev/null || echo "")
  rm -f "$_sling_err_file"
  trap - RETURN

  _SLING_BEAD_ID=$(printf '%s' "$_sling_out" | jq -r '.bead_id // .id // empty' 2>/dev/null || echo "")

  if [ -z "$_SLING_BEAD_ID" ]; then
    warn "gc sling failed for $STORY_ID — aborting dispatch (err: ${_sling_err:-no output})"
    bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    _DISPATCH_RESULT="sling_no_bead_id"
    return 1
  fi

  # gt-q0hon: post-sling Dolt verify — guard against phantom bead.
  local _verify_ok=0 _vi
  for _vi in 1 2 3; do
    if bd -C "$GC_CITY" show "$_SLING_BEAD_ID" --json 2>/dev/null \
        | jq -e 'if type=="array" then .[0].id else .id end' >/dev/null 2>&1; then
      _verify_ok=1; break
    fi
    [ "$_vi" -lt 3 ] && sleep 2
  done

  if [ "$_verify_ok" = "0" ]; then
    warn "PHANTOM BEAD: gc sling returned $_SLING_BEAD_ID but not found in Dolt after 3 attempts. Aborting dispatch for $STORY_ID (gt-q0hon)."
    bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    _DISPATCH_RESULT="sling_phantom_bead"
    return 1
  fi

  gc --city "$GC_CITY" session nudge "$BUILDER_TARGET" "$_DISPATCH_TASK" \
    --delivery wait-idle 2>/dev/null \
    || warn "Could not nudge $BUILDER_TARGET — builder will see the task bead on next hook cycle"

  _DISPATCH_RESULT="sling_ok"
  log "Dispatch complete: sling_bead=$_SLING_BEAD_ID target=$BUILDER_TARGET"
}

# _transition_bead — transition labels post-dispatch.
# Reads: STORY_ID BEAD_DB LANE DISPATCH_TIER _SLING_BEAD_ID BUILDER_TARGET STORY_RIG
# story:in-flight is added BEFORE removing pilot:dispatching — if the write fails,
# pilot:dispatching stays on the bead for TTL recovery (no silent re-dispatch window).
# Returns 1 (warning only) if story:in-flight write fails.
_transition_bead() {
  if [ "$DRY_RUN" = "1" ]; then return 0; fi

  local _now
  _now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if ! bd -C "$BEAD_DB" label add "$STORY_ID" "story:in-flight" -q 2>/dev/null; then
    warn "Failed to set story:in-flight on $STORY_ID — leaving pilot:dispatching for TTL recovery. Builder $BUILDER_TARGET will be a no-op on next wake."
    return 1
  fi
  bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
  bd -C "$BEAD_DB" label add    "$STORY_ID" "lane:${LANE}"      -q 2>/dev/null || true
  bd -C "$BEAD_DB" label add    "$STORY_ID" "pilot:dispatched"  -q 2>/dev/null || true

  local _comment
  if [ "$DISPATCH_TIER" = "bug" ]; then
    _comment="Pilot dispatched builder '$BUILDER_TARGET' at $_now (tier=bug/tech-debt, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $_SLING_BEAD_ID
Builder doctrine: fix bug → /gate-done → autonomous gate+delivery → bead closed.
No human review required. SYSTEM QUALITY FIRST."
  else
    _comment="Pilot dispatched builder '$BUILDER_TARGET' at $_now (tier=feature, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $_SLING_BEAD_ID
Builder doctrine: implement → /gate-done → autonomous gate+delivery → story:done.
No human review required."
  fi

  bd -C "$BEAD_DB" comment "$STORY_ID" "$_comment" \
    2>/dev/null || warn "Could not post dispatch comment to $STORY_ID"
}

# _notify_dispatch — emit ntfy notification.
# Reads: STORY_ID STORY_TITLE STORY_PRIORITY DISPATCH_TIER LANE BUILDER_TARGET
_notify_dispatch() {
  if [ "$DRY_RUN" = "1" ]; then
    local _tier_label
    _tier_label="$([ "$DISPATCH_TIER" = "bug" ] && echo "BUG/DEBT" || echo "feature")"
    log "DRY_RUN=1 — WOULD NOTIFY: dispatch $STORY_ID [$_tier_label/$LANE] (P${STORY_PRIORITY}) → $BUILDER_TARGET"
    return 0
  fi
  notify -t "✨ Pilot pegou uma história" -p 3 \
    "✨ $STORY_TITLE ($STORY_ID, P${STORY_PRIORITY}, lane=$LANE → $BUILDER_TARGET)" \
    2>/dev/null || true
}

# ── dispatch_one ──────────────────────────────────────────────────────────────
# dispatch_one <story_json> <lane> <dispatch_tier>
# Shared state vars (STORY_ID, BEAD_DB, etc.) are set without `local` so the
# sub-functions above can read them via bash dynamic scoping.
dispatch_one() {
  local STORY="$1"
  LANE="$2"
  DISPATCH_TIER="$3"

  # ── Extract story fields ─────────────────────────────────────────────────────
  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '.title // .description // "untitled"' | head -c 100)
  STORY_PRIORITY=$(echo "$STORY" | jq -r '.priority // 99')
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')
  STORY_RIG=$(echo "$STORY" | jq -r '.metadata["story.rig"] // ""')
  # _bead_db is injected by the rig fallback scan (Step 2c); absent for HQ beads.
  BEAD_DB=$(echo "$STORY" | jq -r '._bead_db // empty' 2>/dev/null || echo "")
  [ -z "$BEAD_DB" ] && BEAD_DB="$GC_CITY"
  STORY_ESTRELA=$(echo "$STORY" | jq -r '.metadata["story.estrela_guia"] // ""' | head -c 200)
  STORY_CRITERIA=$(echo "$STORY" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""')
  STORY_EQUILIBRIOS=$(echo "$STORY" | jq -r '.metadata["story.equilibrios"] // ""')

  # Sanitize untrusted bead fields: a bare line matching a heredoc delimiter would
  # silently truncate the task prompt with no error. Replace exact delimiter lines.
  STORY_CRITERIA=$(printf '%s'    "$STORY_CRITERIA"    | sed 's/^TASK$/[TASK]/; s/^FIXSEC$/[FIXSEC]/')
  STORY_ESTRELA=$(printf '%s'     "$STORY_ESTRELA"     | sed 's/^TASK$/[TASK]/; s/^FIXSEC$/[FIXSEC]/')
  STORY_EQUILIBRIOS=$(printf '%s' "$STORY_EQUILIBRIOS" | sed 's/^TASK$/[TASK]/; s/^FIXSEC$/[FIXSEC]/')

  # ── Gate re-dispatch: inject reviewer feedback ───────────────────────────────
  STORY_GATE_FEEDBACK="" STORY_FIX_ATTEMPT="" GATE_FIX_SECTION=""
  if echo "$STORY_LABELS" | grep -q "gate:needs-fix"; then
    STORY_FIX_ATTEMPT=$(echo "$STORY_LABELS" | tr ',' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    STORY_GATE_FEEDBACK=$(bd -C "$BEAD_DB" comments "$STORY_ID" --json 2>/dev/null \
      | jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""' \
      2>/dev/null || echo "")
    log "  $STORY_ID is gate:needs-fix (attempt=${STORY_FIX_ATTEMPT:-?}) — injecting reviewer feedback (${#STORY_GATE_FEEDBACK} chars)."
    if [ -n "$STORY_GATE_FEEDBACK" ]; then
      STORY_GATE_FEEDBACK=$(printf '%s' "$STORY_GATE_FEEDBACK" | sed 's/^TASK$/[TASK]/; s/^FIXSEC$/[FIXSEC]/')
      GATE_FIX_SECTION=$(cat <<FIXSEC

## ⚠️ GATE RE-DISPATCH — fix THESE specific issues (fix attempt ${STORY_FIX_ATTEMPT:-?}/3)
This bead previously FAILED the autonomous quality gate. You are being re-dispatched
to fix the EXACT blocking issues the reviewers found below — do NOT redo unrelated
work. After fixing, run /gate-done to re-gate. If you genuinely cannot resolve these,
explain why in a bead comment; after 3 failed attempts the machine escalates to a human.

$STORY_GATE_FEEDBACK
FIXSEC
)
    fi
  fi

  log "Selected $DISPATCH_TIER [$LANE] $STORY_ID (priority=$STORY_PRIORITY): $STORY_TITLE"
  log "  rig=$STORY_RIG  labels=$STORY_LABELS  lane=$LANE  tier=$DISPATCH_TIER  db=$BEAD_DB"

  # ── Atomic claim ─────────────────────────────────────────────────────────────
  log "Attempting atomic claim on $STORY_ID ..."
  _claim_bead || return 1

  # ── Determine builder target ──────────────────────────────────────────────────
  if [ -z "$STORY_RIG" ] || [ "$STORY_RIG" = "null" ]; then
    local _prefix
    _prefix=$(echo "$STORY_ID" | cut -d'-' -f1)
    case "$_prefix" in
      ga) STORY_RIG="gascity"             ;;
      ps) STORY_RIG="property_scrapers"   ;;
      wa) STORY_RIG="whatsapp_automation" ;;
      gt) STORY_RIG="gastown"             ;;
      lx) STORY_RIG="lexbh"              ;;
      ma) STORY_RIG="marketing"           ;;
      *)  STORY_RIG="gascity"             ;;
    esac
    log "  story.rig inferred from bead prefix '$_prefix': $STORY_RIG"
  fi

  BUILDER_TARGET=$(rig_to_builder "$STORY_RIG")
  log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG lane=$LANE)"

  # ── wa-1eos: per-builder mutex ────────────────────────────────────────────────
  if [ "$DRY_RUN" != "1" ] && [ "$BUILDER_TARGET" != "gastown.dog" ]; then
    local _live
    _live=$(gc --city "$GC_CITY" session list 2>/dev/null \
      | awk -v t="$BUILDER_TARGET" '$2==t && $3=="active"' | wc -l | tr -d ' ')
    if [ "${_live:-0}" -ge 1 ] 2>/dev/null; then
      log "MUTEX(wa-1eos): builder $BUILDER_TARGET already has ${_live} live session(s) — deferring $STORY_ID to next sweep. Releasing claim."
      bd -C "$BEAD_DB" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
  fi

  # ── Build task prompt ─────────────────────────────────────────────────────────
  _build_task_prompt
  log "  Task prompt built (${#_DISPATCH_TASK} chars)"

  # ── Dispatch via gc sling ─────────────────────────────────────────────────────
  local SLING_TITLE DISPATCH_EPOCH DISPATCH_END_EPOCH ELAPSED_S NOW
  if [ "$DISPATCH_TIER" = "bug" ]; then
    SLING_TITLE="fix bug $STORY_ID: $STORY_TITLE"
  else
    SLING_TITLE="build story $STORY_ID: $STORY_TITLE"
  fi

  DISPATCH_EPOCH=$(date +%s)
  _do_sling "$SLING_TITLE" || return 1

  # ── Transition bead labels ────────────────────────────────────────────────────
  local _transition_ok=1
  _transition_bead || _transition_ok=0

  DISPATCH_END_EPOCH=$(date +%s)
  ELAPSED_S=$((DISPATCH_END_EPOCH - DISPATCH_EPOCH))
  if [ "$_transition_ok" = "1" ]; then
    log "$DISPATCH_TIER [$LANE] $STORY_ID → story:in-flight (builder=$BUILDER_TARGET elapsed=${ELAPSED_S}s)"
  else
    warn "$DISPATCH_TIER [$LANE] $STORY_ID → story:in-flight FAILED — pilot:dispatching retained for TTL recovery (builder=$BUILDER_TARGET elapsed=${ELAPSED_S}s)"
  fi

  # ── Log to pilot-dispatcher.jsonl ────────────────────────────────────────────
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  mkdir -p "$(dirname "$PILOT_LOG")"
  jq -c -n \
    --arg ts "$NOW" \
    --arg story_id "$STORY_ID" \
    --arg story_title "$STORY_TITLE" \
    --arg tier "$DISPATCH_TIER" \
    --arg lane "$LANE" \
    --arg rig "$STORY_RIG" \
    --arg builder "$BUILDER_TARGET" \
    --arg sling_bead "${_SLING_BEAD_ID:-}" \
    --arg result "${_DISPATCH_RESULT:-sling_ok}" \
    --argjson priority "$STORY_PRIORITY" \
    --argjson elapsed_s "$ELAPSED_S" \
    --arg dry_run "$DRY_RUN" \
    '{ts: $ts, event: "pilot_dispatch", story_id: $story_id, story_title: $story_title,
      tier: $tier, lane: $lane, rig: $rig, builder: $builder, sling_bead: $sling_bead,
      result: $result, priority: $priority, elapsed_s: $elapsed_s, dry_run: $dry_run}' \
    >> "$PILOT_LOG" 2>/dev/null || true

  # ── Notify ────────────────────────────────────────────────────────────────────
  _notify_dispatch
}

# ── TTL recovery helper ───────────────────────────────────────────────────────
# _ttl_recover_db <db_dir> <now_epoch> <ttl_secs>
# Scans <db_dir> for stale pilot:dispatching claims and releases them.
_ttl_recover_db() {
  local _db="$1" _now_epoch="$2" _ttl_secs="$3"
  local _stale_json _stale_count
  _stale_json=$(bd -C "$_db" list --json --all \
    -l "pilot:dispatching" \
    2>/dev/null || echo "[]")
  _stale_count=$(echo "$_stale_json" | jq 'length' 2>/dev/null || echo "0")
  [ "$_stale_count" -eq 0 ] && return 0

  log "TTL recovery: $_stale_count stale pilot:dispatching candidate(s) in $_db"
  echo "$_stale_json" | jq -c '.[]' | while IFS= read -r bead; do
    BEAD_ID_STALE=$(echo "$bead" | jq -r '.id // empty' 2>/dev/null || echo "")
    [ -z "$BEAD_ID_STALE" ] && continue
    UPDATED_AT=$(echo "$bead" | jq -r '.updated_at // .created_at // ""')
    if [ -n "$UPDATED_AT" ]; then
      UPDATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null \
        || date -d "$UPDATED_AT" +%s 2>/dev/null || echo "$_now_epoch")
      AGE_SECS=$((_now_epoch - UPDATED_EPOCH))
      if [ "$AGE_SECS" -gt "$_ttl_secs" ]; then
        warn "Releasing stale pilot:dispatching claim on $BEAD_ID_STALE in $_db (age=${AGE_SECS}s > TTL=${_ttl_secs}s)"
        bd -C "$_db" label remove "$BEAD_ID_STALE" "pilot:dispatching" -q 2>/dev/null || true
      fi
    fi
  done
}

# ── Step 0: TTL recovery — release stale pilot:dispatching claims ─────────────
# Releases any bead whose pilot:dispatching claim is older than CLAIM_TTL_MINUTES.
# No story:approved filter — Tier 1 (bug/tech-debt) beads never carry story:approved
# but can get stale pilot:dispatching claims that must also be recovered.
# Scans BOTH HQ DB and all rig DBs: _claim_bead writes pilot:dispatching to BEAD_DB,
# which is a rig DB path for Step 2c (rig-fallback) candidates. Without scanning rig
# DBs, a crash after claim but before _transition_bead permanently locks those beads.

TTL_NOW_EPOCH=$(date +%s)
TTL_SECS=$((CLAIM_TTL_MINUTES * 60))

_ttl_recover_db "$GC_CITY" "$TTL_NOW_EPOCH" "$TTL_SECS"

_ttl_rig_paths=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")
while IFS= read -r _ttl_rig; do
  [ -z "$_ttl_rig" ] || [ ! -d "$_ttl_rig" ] && continue
  _ttl_recover_db "$_ttl_rig" "$TTL_NOW_EPOCH" "$TTL_SECS"
done <<< "$_ttl_rig_paths"

# ── Step 1: Per-lane capacity check ──────────────────────────────────────────

IN_FLIGHT_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:in-flight" \
  2>/dev/null || echo "[]")

IN_FLIGHT_TOTAL=$(echo "$IN_FLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")
IN_FLIGHT_BIG=$(echo "$IN_FLIGHT_JSON" | jq '[.[] | select((.labels // []) | contains(["lane:big"]))] | length' 2>/dev/null || echo "0")
IN_FLIGHT_SMALL=$((IN_FLIGHT_TOTAL - IN_FLIGHT_BIG))

log "In-flight: total=$IN_FLIGHT_TOTAL  small=$IN_FLIGHT_SMALL/${MAX_SMALL}  big=$IN_FLIGHT_BIG/${MAX_BIG}"

SMALL_SLOTS=$((MAX_SMALL - IN_FLIGHT_SMALL))
BIG_SLOTS=$((MAX_BIG - IN_FLIGHT_BIG))

[ "$SMALL_SLOTS" -lt "0" ] && SMALL_SLOTS=0
[ "$BIG_SLOTS"   -lt "0" ] && BIG_SLOTS=0

log "Available slots: small=$SMALL_SLOTS  big=$BIG_SLOTS"

HQ_LANES_FULL=0
if [ "$SMALL_SLOTS" -eq "0" ] && [ "$BIG_SLOTS" -eq "0" ]; then
  log "Both HQ lanes full (small=${IN_FLIGHT_SMALL}/${MAX_SMALL}, big=${IN_FLIGHT_BIG}/${MAX_BIG}) — HQ dispatch skipped. WA ctx:ready still runs."
  HQ_LANES_FULL=1
fi

# ── ga-qw7y6: build the terminal-success gate-marker set once for this sweep ──
# Runs even when HQ lanes are full — needed for WA ctx:ready gated-bead filter too.
_build_gated_set

if [ "$HQ_LANES_FULL" = "1" ]; then
  # Skip HQ Tier 1/2/2c dispatch — both HQ lanes full. Jump straight to WA ctx:ready.
  DISPATCHED=0
  ALL_CANDIDATES_COUNT=0
else

# ── Step 2: Tier 1 — Find open bugs + tech-debt beads in HQ DB ───────────────

BUGS_JSON=$(bd -C "$GC_CITY" list --json \
  -t bug \
  "${COMMON_EXCLUDES[@]}" \
  -n 0 \
  2>/dev/null || echo "[]")
BUGS_JSON=$(echo "$BUGS_JSON" | _filter_candidates | _filter_gated)

DEBT_JSON=$(bd -C "$GC_CITY" list --json \
  -l "tech-debt" \
  "${COMMON_EXCLUDES[@]}" \
  -n 0 \
  2>/dev/null || echo "[]")
DEBT_JSON=$(echo "$DEBT_JSON" | _filter_candidates | _filter_gated)

TIER1_JSON=$(echo "$BUGS_JSON $DEBT_JSON" \
  | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")
TIER1_JSON=$(echo "$TIER1_JSON" | _filter_unblocked "$GC_CITY")

TIER1_COUNT=$(echo "$TIER1_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Tier 1 (bugs + tech-debt): $TIER1_COUNT open candidate(s) in HQ DB"

ALL_CANDIDATES_JSON="[]"
ALL_CANDIDATES_TIER=""

if [ "$TIER1_COUNT" -gt "0" ]; then
  ALL_CANDIDATES_JSON="$TIER1_JSON"
  ALL_CANDIDATES_TIER="bug"
  log "Tier 1 has candidates — dispatching bugs/debt FIRST (features suppressed)."
fi

# ── Step 2b: Tier 2 — story:approved feature stories (only if Tier 1 empty) ──

if [ "$TIER1_COUNT" -eq "0" ]; then
  log "Tier 1 empty — falling back to Tier 2 (story:approved features) ..."

  TIER2_JSON=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    "${TIER2_EXCLUDES[@]}" \
    -n 0 \
    2>/dev/null || echo "[]")
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_candidates | _filter_gated)
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_unblocked "$GC_CITY")

  TIER2_COUNT=$(echo "$TIER2_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "Tier 2 (story:approved features): $TIER2_COUNT candidate(s) in HQ DB"

  if [ "$TIER2_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_JSON="$TIER2_JSON"
    ALL_CANDIDATES_TIER="feature"
  fi
fi

# ── Step 2c: Fallback — scan rig DBs if HQ returned nothing ──────────────────

if [ -z "$ALL_CANDIDATES_TIER" ]; then
  log "HQ returned no candidates (both tiers) — scanning rig DBs as fallback ..."
  RIG_PATHS=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")

  ALL_RIG_TIER1="[]"
  ALL_RIG_TIER2="[]"
  while IFS= read -r rig_path; do
    [ -z "$rig_path" ] || [ ! -d "$rig_path" ] && continue

    RIG_BUGS=$(bd -C "$rig_path" list --json -t bug \
      "${COMMON_EXCLUDES[@]}" \
      -n 0 2>/dev/null || echo "[]")
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_candidates | _filter_gated | _filter_unblocked "$rig_path")
    RIG_BUGS=$(echo "$RIG_BUGS" | jq --arg db "$rig_path" '[.[] | . + {_bead_db: $db}]' 2>/dev/null || echo "[]")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_BUGS" | jq -s 'add // []' 2>/dev/null || echo "[]")

    RIG_DEBT=$(bd -C "$rig_path" list --json -l "tech-debt" \
      "${COMMON_EXCLUDES[@]}" \
      -n 0 2>/dev/null || echo "[]")
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_candidates | _filter_gated | _filter_unblocked "$rig_path")
    RIG_DEBT=$(echo "$RIG_DEBT" | jq --arg db "$rig_path" '[.[] | . + {_bead_db: $db}]' 2>/dev/null || echo "[]")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_DEBT" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

    RIG_FEATURES=$(bd -C "$rig_path" list --json -l "story:approved" \
      "${TIER2_EXCLUDES[@]}" \
      -n 0 2>/dev/null || echo "[]")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_candidates | _filter_gated | _filter_unblocked "$rig_path")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | jq --arg db "$rig_path" '[.[] | . + {_bead_db: $db}]' 2>/dev/null || echo "[]")
    ALL_RIG_TIER2=$(echo "$ALL_RIG_TIER2 $RIG_FEATURES" | jq -s 'add // []' 2>/dev/null || echo "[]")
  done <<< "$RIG_PATHS"

  RIG_TIER1_COUNT=$(echo "$ALL_RIG_TIER1" | jq 'length' 2>/dev/null || echo "0")
  RIG_TIER2_COUNT=$(echo "$ALL_RIG_TIER2" | jq 'length' 2>/dev/null || echo "0")

  if [ "$RIG_TIER1_COUNT" -gt "0" ]; then
    log "Rig DBs: $RIG_TIER1_COUNT Tier 1 (bug/tech-debt) candidate(s) — using Tier 1."
    ALL_CANDIDATES_JSON="$ALL_RIG_TIER1"
    ALL_CANDIDATES_TIER="bug"
  elif [ "$RIG_TIER2_COUNT" -gt "0" ]; then
    log "Rig DBs: $RIG_TIER2_COUNT Tier 2 (feature) candidate(s) — using Tier 2."
    ALL_CANDIDATES_JSON="$ALL_RIG_TIER2"
    ALL_CANDIDATES_TIER="feature"
  fi
fi

ALL_CANDIDATES_COUNT=$(echo "$ALL_CANDIDATES_JSON" | jq 'length' 2>/dev/null || echo "0")

# ── Step 3: Split candidates by lane, pick one per available lane ─────────────
# NOTE: no early exit here — Step 5 (WA ctx:ready dispatch) runs regardless.

DISPATCHED=0

if [ "$ALL_CANDIDATES_COUNT" = "0" ]; then
  log "No dispatchable candidates (Tier 1 or Tier 2) — HQ/rig-fallback pass skipped."
else
  log "Dispatch tier: $ALL_CANDIDATES_TIER (${ALL_CANDIDATES_COUNT} candidate(s))"

  SMALL_CANDIDATES="[]"
  BIG_CANDIDATES="[]"

  while IFS= read -r bead; do
    lane=$(classify_lane "$bead")
    if [ "$lane" = "big" ]; then
      BIG_CANDIDATES=$(echo "$BIG_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$BIG_CANDIDATES")
    else
      SMALL_CANDIDATES=$(echo "$SMALL_CANDIDATES" | jq --argjson b "$bead" '. + [$b]' 2>/dev/null || echo "$SMALL_CANDIDATES")
    fi
  done < <(echo "$ALL_CANDIDATES_JSON" | jq -c '.[]')

  SMALL_COUNT=$(echo "$SMALL_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
  BIG_COUNT=$(echo "$BIG_CANDIDATES" | jq 'length' 2>/dev/null || echo "0")
  log "Candidates split: small=${SMALL_COUNT}  big=${BIG_COUNT}"

  SMALL_PICK="null"
  BIG_PICK="null"

  [ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ] && \
    SMALL_PICK=$(_top_candidate "$SMALL_CANDIDATES")
  [ "$BIG_SLOTS"   -gt "0" ] && [ "$BIG_COUNT"   -gt "0" ] && \
    BIG_PICK=$(_top_candidate "$BIG_CANDIDATES")

  log "Lane picks — small: $(echo "$SMALL_PICK" | jq -r '.id // "none"')  big: $(echo "$BIG_PICK" | jq -r '.id // "none"')"

  # ── Step 4: Dispatch into available lane slots ────────────────────────────────

  if [ "$SMALL_PICK" != "null" ] && [ "$SMALL_SLOTS" -gt "0" ]; then
    dispatch_one "$SMALL_PICK" "small" "$ALL_CANDIDATES_TIER" && DISPATCHED=$((DISPATCHED + 1)) || true
  fi

  if [ "$BIG_PICK" != "null" ] && [ "$BIG_SLOTS" -gt "0" ]; then
    dispatch_one "$BIG_PICK" "big" "$ALL_CANDIDATES_TIER" && DISPATCHED=$((DISPATCHED + 1)) || true
  fi

  if [ "$DISPATCHED" -eq "0" ]; then
    log "No HQ/rig dispatches this sweep (lane slots may have been won by concurrent process)."
  fi
fi

fi  # end HQ_LANES_FULL guard (else branch)

# ── Step 5: WA ctx:ready dispatch (ga-mfeip) ─────────────────────────────────
#
# Independent of the HQ Tier 1/2 lanes. Runs every sweep regardless of HQ
# dispatch state. Queries the WA store for ctx:ready exec:auto beads and
# distributes them to idle WA crews (capacity: WA_CTX_CAPACITY_PER_CREW per
# crew per sweep). All 6 quality gates applied before any dispatch.
# Env-gated: WA_CTX_DISPATCH=0 disables (fail-open: absent/empty → enabled).

WA_CTX_DISPATCH="${WA_CTX_DISPATCH:-1}"
WA_CTX_DISPATCHED=0

if [ "$WA_CTX_DISPATCH" = "0" ]; then
  log "WA ctx:ready dispatch DISABLED (WA_CTX_DISPATCH=0) — skipping."
else
  log "── WA ctx:ready dispatch (ga-mfeip) ──"

  # Fetch all ctx:ready beads from WA store (fail-open)
  WA_CTX_RAW=$(bd -C "$WA_RIG_PATH" list --json \
    -l "ctx:ready" \
    --exclude-label "story:in-flight" \
    --exclude-label "pilot:dispatching" \
    --exclude-label "pilot:dispatched" \
    -n 0 2>/dev/null || echo "[]")

  # Validate JSON
  WA_CTX_COUNT=$(printf '%s' "$WA_CTX_RAW" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo "0")
  WA_CTX_COUNT=$(printf '%s' "$WA_CTX_COUNT" | tr -d '[:space:]'); WA_CTX_COUNT=${WA_CTX_COUNT:-0}

  if [ "$WA_CTX_COUNT" = "0" ]; then
    log "WA ctx:ready: no candidates in WA store (or bd error — fail-open)."
  else
    log "WA ctx:ready: $WA_CTX_COUNT raw candidate(s) in WA store."

    # Also apply ga-qw7y6 gated-bead filter (already-merged work)
    WA_CTX_CANDIDATES=$(printf '%s' "$WA_CTX_RAW" | _filter_gated)

    # Sort by priority asc, then created_at asc
    WA_CTX_SORTED=$(printf '%s' "$WA_CTX_CANDIDATES" \
      | jq 'sort_by([(.priority // 99), .created_at])' 2>/dev/null || echo "[]")

    # Within-sweep dedup set (bead IDs dispatched to any crew so far)
    WA_SWEEP_DISPATCHED=""

    # Iterate WA crews; for each crew with capacity, pick best passing candidate
    for _wa_crew in "${WA_CTX_CREWS[@]}"; do
      _crew_inflight=$(_wa_crew_capacity "$_wa_crew" "$WA_RIG_PATH")
      if [ "${_crew_inflight:-0}" -ge "${WA_CTX_CAPACITY_PER_CREW:-1}" ] 2>/dev/null; then
        log "WA ctx:ready: $_wa_crew at capacity ($_crew_inflight in-flight) — skip."
        continue
      fi

      # Find first candidate that passes all 6 gates for this crew
      _wa_picked=""
      while IFS= read -r _wa_bead; do
        [ -z "$_wa_bead" ] && continue
        if _wa_ctx_ready_passes_gates "$_wa_bead" "$WA_SWEEP_DISPATCHED"; then
          _wa_picked="$_wa_bead"
          break
        fi
      done < <(printf '%s' "$WA_CTX_SORTED" | jq -c '.[]' 2>/dev/null || true)

      if [ -z "$_wa_picked" ]; then
        log "WA ctx:ready: no gate-passing candidate for $_wa_crew."
        continue
      fi

      _wa_pick_id=$(printf '%s' "$_wa_picked" | jq -r '.id' 2>/dev/null || echo "")
      if _dispatch_wa_ctx_ready "$_wa_picked" "$_wa_crew"; then
        WA_CTX_DISPATCHED=$((WA_CTX_DISPATCHED + 1))
        DISPATCHED=$((DISPATCHED + 1))
        WA_SWEEP_DISPATCHED=$(printf '%s\n%s' "$WA_SWEEP_DISPATCHED" "$_wa_pick_id")
        log "WA ctx:ready: dispatch OK → $wa_pick_id to $_wa_crew."
      else
        log "WA ctx:ready: dispatch FAILED for $_wa_pick_id → $_wa_crew."
      fi
    done

    log "WA ctx:ready dispatch done: WA_CTX_DISPATCHED=$WA_CTX_DISPATCHED"
  fi
fi

log "=== Pilot sweep complete: dispatched=$DISPATCHED (small_slots=$SMALL_SLOTS big_slots=$BIG_SLOTS wa_ctx=$WA_CTX_DISPATCHED) ==="

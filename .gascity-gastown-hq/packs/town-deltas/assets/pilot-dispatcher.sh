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
#   - Self-exclusion: never dispatch bead ga-8c1 (the Pilot itself) — it cannot
#     build itself. Excluded by label policy (pilot:self) not hardcode.
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
# SMALL/fast lane: high concurrency, small items that merge quickly.
MAX_SMALL="${MAX_SMALL:-5}"
# BIG/slow lane: dedicated, prevents big items from blocking small ones.
MAX_BIG="${MAX_BIG:-2}"

# Acceptance-criteria count threshold for auto-classifying a story as BIG.
BIG_CRITERIA_THRESHOLD="${BIG_CRITERIA_THRESHOLD:-5}"

# TTL for stuck pilot:dispatching claims (minutes). After this, Pilot recycles them.
CLAIM_TTL_MINUTES="${CLAIM_TTL_MINUTES:-30}"

# Dry-run mode: show what WOULD happen, make zero changes.
DRY_RUN="${DRY_RUN:-0}"

# Story bead to NEVER dispatch (the Pilot itself — cannot self-build).
SELF_BEAD_ID="ga-8c1"

# ── Rig → Builder routing table ───────────────────────────────────────────────
# Maps story.rig metadata → gc sling target alias.
# Priority: prefer the rig's dedicated builder; fall back to gastown.dog.
#
# Canonical crew-agent naming convention (ga-nkkku): <name>-<sigla>
# Sigla → rig mapping (source of truth):
#   lx = lexbh              (batista-lx)
#   wa = whatsapp_automation (digo-wa, mila-wa, oracle-wa, peter-wa, thies-wa)
#   ps = property_scrapers  (batista-ps)
#   ma = marketing
#   hq = gastown-hq         (system/infra agents)
rig_to_builder() {
  local rig="$1"
  case "$rig" in
    gascity)               echo "gastown.dog"    ;;
    whatsapp_automation|wa) echo "digo-wa"        ;;
    property_scrapers|ps)  echo "batista-ps"     ;;
    gastown|gt)            echo "gastown.dog"    ;;
    lexbh|lx)              echo "gastown.dog"    ;;
    marketing|ma)          echo "gastown.dog"    ;;
    *)                     echo "gastown.dog"    ;;
  esac
}

# ── Lane classification ───────────────────────────────────────────────────────
# classify_lane <bead_json>
# Prints "big" or "small".
classify_lane() {
  local bead="$1"

  # 1. Explicit label wins.
  local labels
  labels=$(echo "$bead" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")
  if echo "$labels" | grep -q "lane:big";   then echo "big";   return; fi
  if echo "$labels" | grep -q "lane:small"; then echo "small"; return; fi

  # 2. story.size_check metadata == "epic" → big.
  local size_check
  size_check=$(echo "$bead" | jq -r '.metadata["story.size_check"] // ""' 2>/dev/null || echo "")
  if [ "$size_check" = "epic" ]; then echo "big"; return; fi

  # 3. Count acceptance criteria lines (newline-separated) — if ≥ threshold → big.
  local criteria crit_count
  criteria=$(echo "$bead" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""' 2>/dev/null || echo "")
  crit_count=$(printf '%s' "$criteria" | grep -c '^.' 2>/dev/null || echo "0")
  # Strip any whitespace/newlines from count (defensive).
  crit_count=$(printf '%s' "$crit_count" | tr -d '[:space:]')
  crit_count=${crit_count:-0}
  if [ "$crit_count" -ge "$BIG_CRITERIA_THRESHOLD" ] 2>/dev/null; then echo "big"; return; fi

  # 4. Default → small.
  echo "small"
}

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: $*"; }

echo ""
log "=== Pilot sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Step 0: TTL recovery — release stale pilot:dispatching claims ─────────────
# A pilot:dispatching story whose updated_at is older than CLAIM_TTL_MINUTES
# means the dispatcher crashed mid-run. Release it back to dispatchable state.

STALE_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:approved" \
  -l "pilot:dispatching" \
  2>/dev/null || echo "[]")

STALE_COUNT=$(echo "$STALE_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$STALE_COUNT" -gt "0" ]; then
  NOW_EPOCH=$(date +%s)
  TTL_SECS=$((CLAIM_TTL_MINUTES * 60))

  echo "$STALE_JSON" | jq -c '.[]' | while IFS= read -r bead; do
    BEAD_ID_STALE=$(echo "$bead" | jq -r '.id')
    UPDATED_AT=$(echo "$bead" | jq -r '.updated_at // .created_at // ""')
    if [ -n "$UPDATED_AT" ]; then
      UPDATED_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$UPDATED_AT" +%s 2>/dev/null \
        || date -d "$UPDATED_AT" +%s 2>/dev/null || echo "$NOW_EPOCH")
      AGE_SECS=$((NOW_EPOCH - UPDATED_EPOCH))
      if [ "$AGE_SECS" -gt "$TTL_SECS" ]; then
        warn "Releasing stale pilot:dispatching claim on $BEAD_ID_STALE (age=${AGE_SECS}s > TTL=${TTL_SECS}s)"
        bd -C "$GC_CITY" label remove "$BEAD_ID_STALE" "pilot:dispatching" -q 2>/dev/null || true
      fi
    fi
  done
fi

# ── Step 1: Per-lane capacity check ──────────────────────────────────────────
# Count in-flight beads per lane by reading their lane:big / lane:small labels.
# Beads without a lane label (manually dispatched) count as small (conservative).

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

if [ "$SMALL_SLOTS" -eq "0" ] && [ "$BIG_SLOTS" -eq "0" ]; then
  log "Both lanes full (small=${IN_FLIGHT_SMALL}/${MAX_SMALL}, big=${IN_FLIGHT_BIG}/${MAX_BIG}). Pilot backing off."
  exit 0
fi

# ── Step 2: Tier 1 — Find open bugs + tech-debt beads in HQ DB ───────────────
# Tier 1 = type:bug OR label:tech-debt, NOT in-flight/done/dispatching, no assignee.
# Bugs do NOT require story:approved — they are always dispatchable when open.
# tech-debt label: use "tech-debt" as canonical label for debt items.
#
# Helper: filter out self-bead + already-assigned from a JSON array.
_filter_candidates() {
  jq --arg self "$SELF_BEAD_ID" \
    '[.[] | select(.id != $self and (.assignee == null or .assignee == ""))]' \
    2>/dev/null || echo "[]"
}

# _filter_unblocked <db_dir>   (reads candidate JSON array from stdin)
# Drops candidates that are currently BLOCKED by unresolved (open) dependencies
# in <db_dir>, using bd's blocker-aware `bd blocked` set. This is the fix for
# bug ga-5ew: the Pilot must NOT dispatch a story whose hard dependency is not
# yet merged/closed (it did — dispatched ga-30v while dep ga-d81 was unmerged).
# A bead is "blocked" iff it has a dependency that is not yet closed; a dep that
# is already closed does NOT block (so we cannot simply filter on dependency_count).
#
# FAIL-OPEN: if `bd blocked` errors, returns nothing, or the jq filter fails,
# candidates pass through UNCHANGED — never worse than the pre-fix behavior.
# Diagnostics go to stderr (which the top-level `exec ... 2>&1` routes to the
# log) so stdout stays pure JSON for the caller's command-substitution capture.
_filter_unblocked() {
  local db_dir="$1"
  local arr blocked_ids blocked_json before after filtered
  arr=$(cat)

  blocked_ids=$(bd -C "$db_dir" blocked --json 2>/dev/null \
    | jq -r '(.[]?.id) // empty' 2>/dev/null || echo "")
  # Nothing blocked in this DB (or probe failed) → pass through unchanged.
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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] WARN: excluded $((before - after)) blocked candidate(s) in $db_dir (unresolved deps — ga-5ew fix)" >&2
  fi
  printf '%s' "$filtered"
}

BUGS_JSON=$(bd -C "$GC_CITY" list --json \
  -t bug \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  -n 0 \
  2>/dev/null || echo "[]")
BUGS_JSON=$(echo "$BUGS_JSON" | _filter_candidates)

DEBT_JSON=$(bd -C "$GC_CITY" list --json \
  -l "tech-debt" \
  --exclude-label "story:in-flight" \
  --exclude-label "story:done" \
  --exclude-label "pilot:dispatching" \
  --exclude-label "gate:needs-human" \
  -n 0 \
  2>/dev/null || echo "[]")
DEBT_JSON=$(echo "$DEBT_JSON" | _filter_candidates)

# Merge bugs + debt, deduplicate by id
TIER1_JSON=$(echo "$BUGS_JSON $DEBT_JSON" \
  | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

# Drop candidates blocked by unresolved deps (ga-5ew). Filtering BEFORE the count
# means an all-blocked Tier 1 correctly falls through to Tier 2 features.
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
# Dispatchable = story:approved AND NOT story:in-flight AND NOT story:done
#                AND NOT gate:passed (merged, delivery in progress — ga-3h8l)
#                AND NOT pilot:dispatching (claim in progress)

if [ "$TIER1_COUNT" -eq "0" ]; then
  log "Tier 1 empty — falling back to Tier 2 (story:approved features) ..."

  TIER2_JSON=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    --exclude-label "story:in-flight" \
    --exclude-label "story:done" \
    --exclude-label "gate:passed" \
    --exclude-label "pilot:dispatching" \
    --exclude-label "gate:needs-human" \
    -n 0 \
    2>/dev/null || echo "[]")
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_candidates)
  # Drop features blocked by unresolved deps (ga-5ew).
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_unblocked "$GC_CITY")

  TIER2_COUNT=$(echo "$TIER2_JSON" | jq 'length' 2>/dev/null || echo "0")
  log "Tier 2 (story:approved features): $TIER2_COUNT candidate(s) in HQ DB"

  if [ "$TIER2_COUNT" -gt "0" ]; then
    ALL_CANDIDATES_JSON="$TIER2_JSON"
    ALL_CANDIDATES_TIER="feature"
  fi
fi

# ── Step 2c: Fallback — scan rig DBs if HQ returned nothing ──────────────────
# Per convention all story beads live in HQ, but check rig DBs as a fallback.
# Only reached when BOTH tiers returned empty from HQ.

if [ -z "$ALL_CANDIDATES_TIER" ]; then
  log "HQ returned no candidates (both tiers) — scanning rig DBs as fallback ..."
  RIG_PATHS=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[] | select(.hq == false) | .path' 2>/dev/null || echo "")

  ALL_RIG_TIER1="[]"
  ALL_RIG_TIER2="[]"
  while IFS= read -r rig_path; do
    [ -z "$rig_path" ] || [ ! -d "$rig_path" ] && continue

    # Tier 1: bugs from rig DB
    RIG_BUGS=$(bd -C "$rig_path" list --json -t bug \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      -n 0 2>/dev/null || echo "[]")
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_candidates | _filter_unblocked "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_BUGS" | jq -s 'add // []' 2>/dev/null || echo "[]")

    # Tier 1: tech-debt from rig DB
    RIG_DEBT=$(bd -C "$rig_path" list --json -l "tech-debt" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      -n 0 2>/dev/null || echo "[]")
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_candidates | _filter_unblocked "$rig_path")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_DEBT" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

    # Tier 2: story:approved features from rig DB
    RIG_FEATURES=$(bd -C "$rig_path" list --json -l "story:approved" \
      --exclude-label "story:in-flight" \
      --exclude-label "story:done" \
      --exclude-label "gate:passed" \
      --exclude-label "pilot:dispatching" \
      --exclude-label "gate:needs-human" \
      -n 0 2>/dev/null || echo "[]")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_candidates | _filter_unblocked "$rig_path")
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

if [ "$ALL_CANDIDATES_COUNT" = "0" ]; then
  log "No dispatchable candidates (Tier 1 or Tier 2). Exiting."
  exit 0
fi

log "Dispatch tier: $ALL_CANDIDATES_TIER (${ALL_CANDIDATES_COUNT} candidate(s))"

# ── Step 3: Split candidates by lane, pick one per available lane ─────────────
# For each candidate classify its lane. Build two sorted candidate lists.
# Pick highest priority (P0>P1>P2..., tie-break oldest) from each.
# Only dispatch into a lane if it has a free slot.

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

# Sort each lane by priority asc, then created_at asc.
_top_candidate() {
  local arr="$1"
  echo "$arr" | jq 'sort_by([(.priority // 99), .created_at]) | .[0]' 2>/dev/null
}

SMALL_PICK="null"
BIG_PICK="null"

[ "$SMALL_SLOTS" -gt "0" ] && [ "$SMALL_COUNT" -gt "0" ] && \
  SMALL_PICK=$(_top_candidate "$SMALL_CANDIDATES")
[ "$BIG_SLOTS"   -gt "0" ] && [ "$BIG_COUNT"   -gt "0" ] && \
  BIG_PICK=$(_top_candidate "$BIG_CANDIDATES")

log "Lane picks — small: $(echo "$SMALL_PICK" | jq -r '.id // "none"')  big: $(echo "$BIG_PICK" | jq -r '.id // "none"')"

# ── Dispatch helper ───────────────────────────────────────────────────────────
# dispatch_one <story_json> <lane> <dispatch_tier>
# Handles: claim, verify, builder routing, sling, bead transitions, logging, ntfy.
dispatch_one() {
  local STORY="$1"
  local LANE="$2"
  local DISPATCH_TIER="$3"

  local STORY_ID STORY_TITLE STORY_PRIORITY STORY_LABELS STORY_RIG
  local STORY_ESTRELA STORY_CRITERIA STORY_EQUILIBRIOS
  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '.title // .description // "untitled"' | head -c 100)
  STORY_PRIORITY=$(echo "$STORY" | jq -r '.priority // 99')
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')
  STORY_RIG=$(echo "$STORY" | jq -r '.metadata["story.rig"] // ""')
  STORY_ESTRELA=$(echo "$STORY" | jq -r '.metadata["story.estrela_guia"] // ""' | head -c 200)
  STORY_CRITERIA=$(echo "$STORY" | jq -r '.acceptance_criteria // .metadata["story.criterios"] // ""')
  STORY_EQUILIBRIOS=$(echo "$STORY" | jq -r '.metadata["story.equilibrios"] // ""')

  # ── ga-jb4l: gate re-dispatch — surface reviewer feedback for needs-fix beads ──
  # A bead labeled gate:needs-fix previously FAILED the quality gate. The gate
  # attached the FAILing reviewers' reasons to it as a "GATE-FEEDBACK" comment.
  # Pull the latest such comment and the attempt counter so the builder prompt
  # tells the re-dispatched builder to fix THE SPECIFIC issues (not redo the work).
  local STORY_GATE_FEEDBACK="" STORY_FIX_ATTEMPT="" GATE_FIX_SECTION=""
  if echo "$STORY_LABELS" | grep -q "gate:needs-fix"; then
    STORY_FIX_ATTEMPT=$(echo "$STORY_LABELS" | tr ',' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    STORY_GATE_FEEDBACK=$(bd -C "$GC_CITY" comments "$STORY_ID" --json 2>/dev/null \
      | jq -r '[ .[]? | (.text // .body // "") | select(test("^GATE-FEEDBACK")) ] | last // ""' \
      2>/dev/null || echo "")
    log "  $STORY_ID is gate:needs-fix (attempt=${STORY_FIX_ATTEMPT:-?}) — injecting reviewer feedback (${#STORY_GATE_FEEDBACK} chars)."
    if [ -n "$STORY_GATE_FEEDBACK" ]; then
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
  log "  rig=$STORY_RIG  labels=$STORY_LABELS  lane=$LANE  tier=$DISPATCH_TIER"

  # ── Atomic claim ────────────────────────────────────────────────────────────
  log "Attempting atomic claim on $STORY_ID (lane=$LANE tier=$DISPATCH_TIER) ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD: bd label add $STORY_ID pilot:dispatching"
  else
    bd -C "$GC_CITY" label add "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || {
      warn "Could not add pilot:dispatching to $STORY_ID (race condition or bd error). Skipping."
      return 1
    }
  fi

  # Verify we won the race.
  if [ "$DRY_RUN" != "1" ]; then
    local VERIFY_JSON VERIFY_LABELS
    VERIFY_JSON=$(bd -C "$GC_CITY" show "$STORY_ID" --json 2>/dev/null || echo "[]")
    VERIFY_LABELS=$(echo "$VERIFY_JSON" \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' \
      2>/dev/null || echo "")

    if [ -z "$VERIFY_LABELS" ]; then
      warn "Could not verify $STORY_ID claim state (bd show returned empty). Releasing claim."
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi

    if echo "$VERIFY_LABELS" | grep -q "story:in-flight"; then
      log "Story $STORY_ID is already in-flight (race condition). Releasing claim."
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
    if echo "$VERIFY_LABELS" | grep -q "story:done"; then
      log "Story $STORY_ID is already done. Releasing claim."
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
  fi

  log "Claim acquired on $STORY_ID."

  # ── Determine builder target ─────────────────────────────────────────────────
  if [ -z "$STORY_RIG" ] || [ "$STORY_RIG" = "null" ]; then
    local BEAD_PREFIX
    BEAD_PREFIX=$(echo "$STORY_ID" | cut -d'-' -f1)
    case "$BEAD_PREFIX" in
      ga) STORY_RIG="gascity" ;;
      ps) STORY_RIG="property_scrapers" ;;
      wa) STORY_RIG="whatsapp_automation" ;;
      gt) STORY_RIG="gastown" ;;
      lx) STORY_RIG="lexbh" ;;
      ma) STORY_RIG="marketing" ;;
      *)  STORY_RIG="gascity" ;;
    esac
    log "  story.rig inferred from bead prefix '$BEAD_PREFIX': $STORY_RIG"
  fi

  local BUILDER_TARGET
  BUILDER_TARGET=$(rig_to_builder "$STORY_RIG")
  log "  Builder target: $BUILDER_TARGET (rig=$STORY_RIG lane=$LANE)"

  # ── wa-1eos: per-builder mutex ───────────────────────────────────────────────
  # Single-identity builders (digo-wa=wa, batista-ps=ps, etc.) must have AT MOST ONE
  # live session. Without this, dispatching a 2nd bead to a busy builder makes
  # `gc sling` spawn a duplicate (digo-wa → digo-wa-1) that works the SAME crew branch —
  # branch corruption. If the builder is already live, defer this bead to the next
  # sweep (release the claim so it stays dispatchable). gastown.dog is a shared
  # pool (multiple instances by design) — exempt. Fail-safe: any error → count 0 →
  # dispatch proceeds (never halts the pipeline on a transient `gc` hiccup).
  if [ "$DRY_RUN" != "1" ] && [ "$BUILDER_TARGET" != "gastown.dog" ]; then
    local LIVE_BUILDER_SESSIONS
    LIVE_BUILDER_SESSIONS=$(gc --city "$GC_CITY" session list 2>/dev/null \
      | awk -v t="$BUILDER_TARGET" '$2==t && $3=="active"' | wc -l | tr -d ' ')
    if [ "${LIVE_BUILDER_SESSIONS:-0}" -ge 1 ] 2>/dev/null; then
      log "MUTEX(wa-1eos): builder $BUILDER_TARGET already has ${LIVE_BUILDER_SESSIONS} live session(s) — deferring $STORY_ID to next sweep (no duplicate spawn). Releasing claim."
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      return 1
    fi
  fi

  # ── Build task prompt ────────────────────────────────────────────────────────
  local DISPATCH_TASK
  if [ "$DISPATCH_TIER" = "bug" ]; then
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Bug/tech-debt assigned for autonomous fix

Bead ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: BUG / TECH-DEBT (Tier 1 — dispatched BEFORE new features)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY

## Your job
Fix this bug or tech-debt item completely. Do NOT wait for a human.
"Só depois do sistema perfeito é que a gente faz novas features." — system quality first.
$GATE_FIX_SECTION

## Description / Acceptance Criteria
$STORY_CRITERIA

## Additional Context
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your fix is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just fix, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → bead closed.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.

## Steps
1. Read the full bead: bd -C "$GC_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Diagnose root cause, implement fix on a branch (name: fix/$STORY_ID).
4. Add a regression test if applicable.
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$GC_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$GC_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  else
    DISPATCH_TASK=$(cat <<TASK
PILOT DISPATCH — Story assigned for autonomous build

Story ID: $STORY_ID
Title: $STORY_TITLE
Priority: P${STORY_PRIORITY}
Type: FEATURE (Tier 2 — dispatched only because no open bugs/tech-debt)
Lane: $LANE
Rig: $STORY_RIG
City: $GC_CITY

## Your job
Build this story from acceptance criteria to /gate-done. Do NOT wait for a human.
$GATE_FIX_SECTION

## Acceptance Criteria
$STORY_CRITERIA

## Estrela Guia (north star)
$STORY_ESTRELA

## Equilibrios (constraints to preserve)
$STORY_EQUILIBRIOS

## DOCTRINE — read carefully
- You are the BUILDER. Human never merges. Gate (G) and Delivery (①) are autonomous.
- When your implementation is complete: run /gate-done — this feeds the autonomous gate.
- DO NOT ask for approval. DO NOT send to Athos. Just build, push, gate-done.
- The autonomous loop: /gate-done → G reviews → merges → ① deploys → story:done.
- If /gate-done fails validation (no commits, no branch), fix the issue and retry.

## Steps
1. Read the full story bead: bd -C "$GC_CITY" show "$STORY_ID"
2. Run gc prime to load your full context.
3. Implement the story on a feature branch (name: feat/$STORY_ID or story/$STORY_ID).
4. Add a story-specific prod test at the required path (see delivery-runbooks.toml).
5. Commit, push, then run /gate-done.

## Claim your work (do this first)
bd -C "$GC_CITY" assign "$STORY_ID" "\$GC_ALIAS"
bd -C "$GC_CITY" status in_progress "$STORY_ID"

Start now. Do not wait for permission.
TASK
)
  fi

  log "  Task prompt built (${#DISPATCH_TASK} chars)"

  # ── Dispatch via gc sling ────────────────────────────────────────────────────
  local DISPATCH_EPOCH DISPATCH_RESULT SLING_BEAD_ID NOW
  DISPATCH_EPOCH=$(date +%s)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [ "$DRY_RUN" = "1" ]; then
    local SLING_TITLE_DRY
    SLING_TITLE_DRY="$([ "$DISPATCH_TIER" = "bug" ] && echo "fix bug" || echo "build story") $STORY_ID: $STORY_TITLE"
    log "DRY_RUN=1 — WOULD DISPATCH (tier=$DISPATCH_TIER lane=$LANE):"
    log "  gc --city $GC_CITY sling $BUILDER_TARGET <task_bead> --nudge"
    log "  Task title: '$SLING_TITLE_DRY'"
    log "  Rig: $STORY_RIG → builder: $BUILDER_TARGET"
    log "  WOULD: bd label add $STORY_ID lane:${LANE}"
    log "  WOULD: bd label add $STORY_ID story:in-flight"
    log "  WOULD: bd label remove $STORY_ID pilot:dispatching"
    log "  WOULD: bd label add $STORY_ID pilot:dispatched"
    log "  WOULD: bd comment $STORY_ID 'Pilot dispatched builder $BUILDER_TARGET at $NOW'"
    SLING_BEAD_ID="DRY_RUN_NO_SLING"
    DISPATCH_RESULT="dry_run"
  else
    local SLING_TITLE SLING_OUT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      SLING_TITLE="fix bug $STORY_ID: $STORY_TITLE"
    else
      SLING_TITLE="build story $STORY_ID: $STORY_TITLE"
    fi

    local _sling_err_file _sling_err
    _sling_err_file="/tmp/pilot-sling-err.$$"
    SLING_OUT=$(gc --city "$GC_CITY" sling "$BUILDER_TARGET" \
      "$SLING_TITLE" \
      --nudge \
      --json \
      2>"$_sling_err_file" || echo "{}")
    _sling_err=$(head -c 300 "$_sling_err_file" 2>/dev/null || echo "")
    rm -f "$_sling_err_file"

    SLING_BEAD_ID=$(echo "$SLING_OUT" | jq -r '.bead_id // .id // empty' 2>/dev/null || echo "")
    DISPATCH_RESULT="sling_ok"

    # gt-q0hon: fail-hard if sling returned no bead ID — do NOT continue with phantom state.
    if [ -z "$SLING_BEAD_ID" ]; then
      warn "gc sling failed for $STORY_ID — aborting dispatch (err: ${_sling_err:-no output})"
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_no_bead_id"
      return 1
    fi

    # gt-q0hon: post-sling Dolt verify — guard against phantom bead (hook set but bead
    # never committed to Dolt). Retry up to 3x with 2s gap for propagation lag.
    local _verify_ok=0 _verify_i
    for _verify_i in 1 2 3; do
      if bd -C "$GC_CITY" show "$SLING_BEAD_ID" --json 2>/dev/null \
          | jq -e 'if type=="array" then .[0].id else .id end' >/dev/null 2>&1; then
        _verify_ok=1; break
      fi
      [ "$_verify_i" -lt 3 ] && sleep 2
    done

    if [ "$_verify_ok" = "0" ]; then
      warn "PHANTOM BEAD: gc sling returned $SLING_BEAD_ID but not found in Dolt after 3 attempts. Aborting dispatch for $STORY_ID (gt-q0hon)."
      bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
      DISPATCH_RESULT="sling_phantom_bead"
      return 1
    fi

    gc --city "$GC_CITY" session nudge "$BUILDER_TARGET" "$DISPATCH_TASK" \
      --delivery wait-idle 2>/dev/null \
      || warn "Could not nudge $BUILDER_TARGET — builder will see the task bead on next hook cycle"

    log "Dispatch complete: sling_bead=$SLING_BEAD_ID target=$BUILDER_TARGET"
  fi

  # ── Transition bead: lane tag + story:in-flight ──────────────────────────────
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$GC_CITY" label add    "$STORY_ID" "lane:${LANE}"      -q 2>/dev/null || true
    bd -C "$GC_CITY" label remove "$STORY_ID" "pilot:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "story:in-flight"   -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "pilot:dispatched"  -q 2>/dev/null || true

    local DISPATCH_COMMENT
    if [ "$DISPATCH_TIER" = "bug" ]; then
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=bug/tech-debt, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: fix bug → /gate-done → autonomous gate+delivery → bead closed.
No human review required. SYSTEM QUALITY FIRST."
    else
      DISPATCH_COMMENT="Pilot dispatched builder '$BUILDER_TARGET' at $NOW (tier=feature, lane=$LANE, rig=$STORY_RIG).
Sling task bead: $SLING_BEAD_ID
Builder doctrine: implement → /gate-done → autonomous gate+delivery → story:done.
No human review required."
    fi

    bd -C "$GC_CITY" comment "$STORY_ID" "$DISPATCH_COMMENT" \
      2>/dev/null || warn "Could not post dispatch comment to $STORY_ID"
  fi

  local DISPATCH_END_EPOCH ELAPSED_S
  DISPATCH_END_EPOCH=$(date +%s)
  ELAPSED_S=$((DISPATCH_END_EPOCH - DISPATCH_EPOCH))

  log "$DISPATCH_TIER [$LANE] $STORY_ID → story:in-flight (builder=$BUILDER_TARGET elapsed=${ELAPSED_S}s)"

  # ── Log to pilot-dispatcher.jsonl ───────────────────────────────────────────
  mkdir -p "$(dirname "$PILOT_LOG")"
  jq -c -n \
    --arg ts "$NOW" \
    --arg story_id "$STORY_ID" \
    --arg story_title "$STORY_TITLE" \
    --arg tier "$DISPATCH_TIER" \
    --arg lane "$LANE" \
    --arg rig "$STORY_RIG" \
    --arg builder "$BUILDER_TARGET" \
    --arg sling_bead "$SLING_BEAD_ID" \
    --arg result "$DISPATCH_RESULT" \
    --argjson priority "$STORY_PRIORITY" \
    --argjson elapsed_s "$ELAPSED_S" \
    --arg dry_run "$DRY_RUN" \
    '{ts: $ts, event: "pilot_dispatch", story_id: $story_id, story_title: $story_title,
      tier: $tier, lane: $lane, rig: $rig, builder: $builder, sling_bead: $sling_bead,
      result: $result, priority: $priority, elapsed_s: $elapsed_s, dry_run: $dry_run}' \
    >> "$PILOT_LOG" 2>/dev/null || true

  # ── Notify ───────────────────────────────────────────────────────────────────
  if [ "$DRY_RUN" = "1" ]; then
    local TIER_LABEL
    TIER_LABEL="$([ "$DISPATCH_TIER" = "bug" ] && echo "BUG/DEBT" || echo "feature")"
    notify -t "Pilot DRY-RUN" -p 1 \
      "Would dispatch $STORY_ID [$TIER_LABEL/$LANE] (P${STORY_PRIORITY}) → $BUILDER_TARGET [DRY_RUN]" \
      2>/dev/null || true
  else
    notify -t "✨ Pilot pegou uma história" -p 3 \
      "✨ $STORY_TITLE ($STORY_ID, P${STORY_PRIORITY}, lane=$LANE → $BUILDER_TARGET)" \
      2>/dev/null || true
  fi
  return 0
}

# ── Step 4: Dispatch into available lane slots ────────────────────────────────
# Dispatch small pick (if small lane has room and we have a small candidate).
# Dispatch big pick (if big lane has room and we have a big candidate).
# Each is independent — a full big lane does NOT block the small dispatch.

DISPATCHED=0

if [ "$SMALL_PICK" != "null" ] && [ "$SMALL_SLOTS" -gt "0" ]; then
  dispatch_one "$SMALL_PICK" "small" "$ALL_CANDIDATES_TIER" && DISPATCHED=$((DISPATCHED + 1)) || true
fi

if [ "$BIG_PICK" != "null" ] && [ "$BIG_SLOTS" -gt "0" ]; then
  dispatch_one "$BIG_PICK" "big" "$ALL_CANDIDATES_TIER" && DISPATCHED=$((DISPATCHED + 1)) || true
fi

if [ "$DISPATCHED" -eq "0" ]; then
  log "No dispatches this sweep (lane slots may have been won by concurrent process)."
fi

log "=== Pilot sweep complete: dispatched=$DISPATCHED (small_slots=$SMALL_SLOTS big_slots=$BIG_SLOTS) ==="

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
rig_to_builder() {
  local rig="$1"
  case "$rig" in
    whatsapp_automation|wa) echo "digo"      ;;
    property_scrapers|ps)   echo "batista-ps" ;;
    *)                      echo "gastown.dog" ;;
  esac
}

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

if [ "$SMALL_SLOTS" -eq "0" ] && [ "$BIG_SLOTS" -eq "0" ]; then
  log "Both lanes full (small=${IN_FLIGHT_SMALL}/${MAX_SMALL}, big=${IN_FLIGHT_BIG}/${MAX_BIG}). Pilot backing off."
  exit 0
fi

# ── Step 2: Tier 1 — Find open bugs + tech-debt beads in HQ DB ───────────────

BUGS_JSON=$(bd -C "$GC_CITY" list --json \
  -t bug \
  "${COMMON_EXCLUDES[@]}" \
  -n 0 \
  2>/dev/null || echo "[]")
BUGS_JSON=$(echo "$BUGS_JSON" | _filter_candidates)

DEBT_JSON=$(bd -C "$GC_CITY" list --json \
  -l "tech-debt" \
  "${COMMON_EXCLUDES[@]}" \
  -n 0 \
  2>/dev/null || echo "[]")
DEBT_JSON=$(echo "$DEBT_JSON" | _filter_candidates)

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
  TIER2_JSON=$(echo "$TIER2_JSON" | _filter_candidates)
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
    RIG_BUGS=$(echo "$RIG_BUGS" | _filter_candidates | _filter_unblocked "$rig_path")
    RIG_BUGS=$(echo "$RIG_BUGS" | jq --arg db "$rig_path" '[.[] | . + {_bead_db: $db}]' 2>/dev/null || echo "[]")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_BUGS" | jq -s 'add // []' 2>/dev/null || echo "[]")

    RIG_DEBT=$(bd -C "$rig_path" list --json -l "tech-debt" \
      "${COMMON_EXCLUDES[@]}" \
      -n 0 2>/dev/null || echo "[]")
    RIG_DEBT=$(echo "$RIG_DEBT" | _filter_candidates | _filter_unblocked "$rig_path")
    RIG_DEBT=$(echo "$RIG_DEBT" | jq --arg db "$rig_path" '[.[] | . + {_bead_db: $db}]' 2>/dev/null || echo "[]")
    ALL_RIG_TIER1=$(echo "$ALL_RIG_TIER1 $RIG_DEBT" | jq -s 'add // [] | unique_by(.id)' 2>/dev/null || echo "[]")

    RIG_FEATURES=$(bd -C "$rig_path" list --json -l "story:approved" \
      "${TIER2_EXCLUDES[@]}" \
      -n 0 2>/dev/null || echo "[]")
    RIG_FEATURES=$(echo "$RIG_FEATURES" | _filter_candidates | _filter_unblocked "$rig_path")
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

if [ "$ALL_CANDIDATES_COUNT" = "0" ]; then
  log "No dispatchable candidates (Tier 1 or Tier 2). Exiting."
  exit 0
fi

log "Dispatch tier: $ALL_CANDIDATES_TIER (${ALL_CANDIDATES_COUNT} candidate(s))"

# ── Step 3: Split candidates by lane, pick one per available lane ─────────────

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

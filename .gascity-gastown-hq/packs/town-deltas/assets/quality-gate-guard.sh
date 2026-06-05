#!/usr/bin/env bash
# quality-gate-guard.sh — Autonomous quality gate guard.
#
# Scans for ready-for-gate markers, claims one atomically, spawns three
# INDEPENDENT reviewer sessions via gc session new + gc sling.
#
# Runs every ~2 minutes via launchd (com.gascity.quality-gate-guard.plist).
# Mirror of the peter-wrapper.sh pattern.
#
# Design invariants:
#   - Guard is the ONLY thing that spawns reviewers. Workers never spawn them.
#   - At most ONE runner per marker (claim via label swap + TTL recovery).
#   - Markers are durable beads — survive worker session death.
#   - Author-exclusion is FAIL-SAFE: author derived from bead DB, not marker
#     self-declaration. If author cannot be resolved authoritatively, DEFER.
#   - Three INDEPENDENT reviewer sessions spawned for CODE tier; each sees
#     only the diff and no shared context from the others.
#   - Claim is re-verified before dispatch to prevent double-processing.
#   - Stale "claimed" markers older than TTL are released back to "ready".

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/quality-gate-guard.log"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"

# ── Constants ─────────────────────────────────────────────────────────────────
CLAIM_TTL_MINUTES=30
DISPATCHING_TTL_MINUTES=30
GATE_RUN_TTL_MINUTES=90
MAX_RECLAIMS=3

# ── Pure decision functions (loaded in GATE_GUARD_LIB_ONLY=1 mode by tests/dispatcher) ──

# age_minutes_of <ts_Z> <now_epoch>
# Returns age of a UTC bead timestamp in whole minutes.
# Uses date -j -u -f (macOS BSD, UTC) to avoid the TZ-offset bug where local-time
# parse made every age negative on UTC-offset hosts.
age_minutes_of() {
  local ts="$1" now_epoch="${2:-$(date +%s)}"
  [ -z "$ts" ] && { echo "0"; return; }
  local ts_epoch
  ts_epoch=$(date -j -u -f "%Y-%m-%dT%H:%M:%S" "${ts%%Z*}" "+%s" 2>/dev/null \
    || date -d "$ts" +%s 2>/dev/null || echo "0")
  echo $(( (now_epoch - ts_epoch) / 60 ))
}

# parse_marker_id <description_text>
# Canonical extractor for the marker_id: field in gate-run bead descriptions.
# Handles space and tab separators, strips trailing whitespace.
# Both the guard and dispatcher converge on this function (DRY: ga-b92q).
parse_marker_id() {
  local desc="$1"
  [ -z "$desc" ] && { echo ""; return; }
  local line
  line=$(printf '%s\n' "$desc" | grep -E "^marker_id:" | head -1 || true)
  [ -z "$line" ] && { echo ""; return; }
  printf '%s' "$line" | sed 's/^marker_id:[[:space:]]*//' | sed 's/[[:space:]]*$//'
}

# reconcile_marker_action <status> <age_min> <ttl_min> <reclaim_count> <max_reclaims>
# Pure decision: what to do with a marker stuck in a transient state.
# Returns: skip | requeue:queued | requeue:ready | error
reconcile_marker_action() {
  local status="$1" age_min="$2" ttl_min="$3" count="$4" max="$5"
  case "$status" in
    dispatching|claimed) ;;
    *) echo "skip"; return ;;
  esac
  [ "$age_min" -le "$ttl_min" ] && { echo "skip"; return; }
  [ "$count" -ge "$max" ]       && { echo "error"; return; }
  case "$status" in
    dispatching) echo "requeue:queued" ;;
    claimed)     echo "requeue:ready"  ;;
  esac
}

# reconcile_gaterun_action <age_min> <ttl_min> <marker_active: 0|1>
# Pure decision: what to do with a gate-run bead stuck in gate-status:running.
# Returns: skip | supersede:marker | abort:age
reconcile_gaterun_action() {
  local age_min="$1" ttl_min="$2" marker_active="$3"
  [ "$marker_active" = "0" ] && { echo "supersede:marker"; return; }
  [ "$age_min" -le "$ttl_min" ] && { echo "skip"; return; }
  echo "abort:age"
}

# ── Lib-only mode: source with GATE_GUARD_LIB_ONLY=1 to load pure functions ──
# without running the live guard sweep. Used by tests and by the dispatcher.
if [ -n "${GATE_GUARD_LIB_ONLY:-}" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-guard] WARN: $*"; }

echo ""
log "=== Guard sweep start ==="

# ── Input validation helpers ──────────────────────────────────────────────────

# Validate branch: lowercase alphanumeric, hyphens, underscores, slashes only.
# Explicitly rejects uppercase, dots, '+', shell metacharacters, spaces, etc.
# This enforces the gate doctrine for safe branch names ([a-z0-9/_-]+).
# Dots are excluded to prevent confusion with remote-tracking ref syntax.
# Uppercase is excluded to avoid case-insensitive filesystem collisions.
# Bug 4 fix: '+' and other unsafe chars (as used in "worktree-fix+wa-..." branches)
# are rejected here, producing gate-status:error with a clear diagnostic.
validate_branch() {
  local val="$1"
  if [[ "$val" =~ ^[a-z0-9/_-]{1,200}$ ]]; then
    return 0
  fi
  return 1
}

# Validate bead ID: e.g. "gt-abc123", "wa-xyz" — prefix/id pattern.
validate_bead_id() {
  local val="$1"
  if [[ "$val" =~ ^[a-z]{1,8}-[a-z0-9]{2,16}$ ]]; then
    return 0
  fi
  return 1
}

# Validate rig name against the known registered rigs.
validate_rig() {
  local val="$1"
  local known_rigs
  known_rigs=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r '.rigs[].name' 2>/dev/null || echo "")
  if [ -z "$known_rigs" ]; then
    warn "Could not fetch rig list for validation; allowing rig='$val' with caution."
    # Still reject obvious injection attempts
    if [[ "$val" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
      return 0
    fi
    return 1
  fi
  echo "$known_rigs" | grep -qx "$val"
}

# ── Step 0: Vector A — unified transient-marker reclaim (dispatching + claimed) ─
# The dispatcher's Step 0a only reclaims gate-status:dispatching when IT runs.
# When the dispatcher CRASHES mid-dispatch, no one reclaims the marker — it
# strands forever (ga-tmug Vector A). Fix: guard now reclaims BOTH transient
# states in ONE authoritative place, with a gate-reclaim-count: thrash cap.

log "Step 0: Vector A reclaim — stuck transient markers (TTL=${CLAIM_TTL_MINUTES}m, MAX_RECLAIMS=${MAX_RECLAIMS})..."

DISP_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker -l gate-status:dispatching \
  2>/dev/null || echo "[]")
CLAIM_JSON_V=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker -l gate-status:claimed \
  2>/dev/null || echo "[]")
TRANSIENT_JSON=$(printf '%s\n%s' "$DISP_JSON" "$CLAIM_JSON_V" \
  | jq -s 'add | unique_by(.id)' 2>/dev/null || echo "[]")
TRANSIENT_COUNT=$(echo "$TRANSIENT_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$TRANSIENT_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)
  for i in $(seq 0 $((TRANSIENT_COUNT - 1))); do
    T=$(echo "$TRANSIENT_JSON" | jq ".[$i]")
    T_ID=$(echo "$T" | jq -r '.id')
    T_UPDATED=$(echo "$T" | jq -r '.updated_at // .created_at // ""')
    T_LABELS=$(echo "$T" | jq -r '(.labels // []) | join(" ")')

    T_STATUS=""
    echo "$T_LABELS" | grep -q "gate-status:dispatching" && T_STATUS="dispatching"
    echo "$T_LABELS" | grep -q "gate-status:claimed"     && T_STATUS="claimed"
    [ -z "$T_STATUS" ] && continue

    T_AGE=$(age_minutes_of "$T_UPDATED" "$NOW_EPOCH")
    T_COUNT=$(echo "$T_LABELS" | tr ' ' '\n' \
      | sed -n 's/^gate-reclaim-count:\([0-9]*\)$/\1/p' | sort -n | tail -1)
    [ -z "$T_COUNT" ] && T_COUNT=0

    ACTION=$(reconcile_marker_action "$T_STATUS" "$T_AGE" "$CLAIM_TTL_MINUTES" "$T_COUNT" "$MAX_RECLAIMS")
    case "$ACTION" in
      requeue:queued)
        warn "Vector A: requeueing zombie dispatching marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:queued"      -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:dispatching for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Dispatcher likely crashed. Re-queued for re-processing (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      requeue:ready)
        warn "Vector A: re-readying zombie claimed marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:ready"   -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:claimed for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Guard likely crashed. Re-readied for re-claim (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      error)
        warn "Vector A: exhausted reclaims for $T_ID (count=${T_COUNT} >= MAX_RECLAIMS=${MAX_RECLAIMS})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:$T_STATUS" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:error"      -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker exhausted ${MAX_RECLAIMS} reclaim attempts stuck in gate-status:${T_STATUS}. Marking gate-status:error — human/Mayor intervention required." 2>/dev/null || true
        ;;
      skip)
        log "  Marker $T_ID in $T_STATUS for ${T_AGE}m — within TTL, skipping."
        ;;
    esac
  done
fi

# ── Step 0b: Vector B — reconcile orphan gate-run:running beads ───────────────
# The guard creates a quality-gate: bead (type:quality-gate-run, gate-status:running)
# at claim time. The dispatcher drives ITS OWN gate-run: bead but NEVER drives the
# guard's bead to terminal — leaving orphans pinned in running after their run
# completed (ga-tmug Vector B, 9 such beads observed).
#
# Fix: use reconcile_gaterun_action keyed on the companion marker's state
# (extracted via parse_marker_id from the gate-run description):
#   - marker terminal/gone → supersede:marker (immediate, no TTL wait)
#   - marker active + age > TTL → abort:age (age fallback preserved)
#   - marker active + within TTL → skip (in-flight, untouched)
#
# Keying on marker_id (not just source-bead) prevents false-positives on
# re-dispatched live runs that share a source bead with an older failed attempt.

log "Step 0b: Vector B reconcile — orphan gate-run:running beads (TTL=${GATE_RUN_TTL_MINUTES}m)..."

GATE_RUNS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")
GATE_RUN_COUNT=$(echo "$GATE_RUNS_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$GATE_RUN_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)
  for i in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    GR=$(echo "$GATE_RUNS_JSON" | jq ".[$i]")
    GR_ID=$(echo "$GR" | jq -r '.id')
    GR_UPDATED=$(echo "$GR" | jq -r '.updated_at // .created_at // ""')
    GR_DESC=$(echo "$GR" | jq -r '.description // ""')

    GR_AGE=$(age_minutes_of "$GR_UPDATED" "$NOW_EPOCH")

    # Determine if the companion marker is still active.
    # parse_marker_id extracts the marker_id: field written by the guard at Step 6.
    COMPANION_MARKER_ID=$(parse_marker_id "$GR_DESC")
    MARKER_ACTIVE=0
    if [ -n "$COMPANION_MARKER_ID" ]; then
      MARKER_JSON=$(bd -C "$GC_CITY" show "$COMPANION_MARKER_ID" --json 2>/dev/null || echo "")
      if [ -n "$MARKER_JSON" ]; then
        MARKER_LABELS=$(echo "$MARKER_JSON" \
          | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
          2>/dev/null || echo "")
        echo "$MARKER_LABELS" | grep -qE "gate-status:(queued|claimed|dispatching)" \
          && MARKER_ACTIVE=1 || true
        echo "$MARKER_LABELS" | grep -qE "gate-status:" || MARKER_ACTIVE=1
      fi
    fi

    ACTION=$(reconcile_gaterun_action "$GR_AGE" "$GATE_RUN_TTL_MINUTES" "$MARKER_ACTIVE")
    case "$ACTION" in
      supersede:marker)
        warn "Vector B: superseding orphan gate-run $GR_ID (age=${GR_AGE}m, marker $COMPANION_MARKER_ID is terminal/gone)"
        bd -C "$GC_CITY" label remove "$GR_ID" "gate-status:running"    -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$GR_ID" "gate-status:superseded"  -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): orphan gate-run superseded — companion marker $COMPANION_MARKER_ID is terminal/gone; run is no longer active. Self-healed by guard." 2>/dev/null || true
        ;;
      abort:age)
        warn "Vector B: aborting gate-run $GR_ID by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m, marker_active=${MARKER_ACTIVE})"
        bd -C "$GC_CITY" label remove "$GR_ID" "gate-status:running"  -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$GR_ID" "gate-status:aborted"  -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): gate-run aborted by guard TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m; marker $COMPANION_MARKER_ID still active but run exceeded max wait)." 2>/dev/null || true
        ;;
      skip)
        log "  Gate-run $GR_ID active (age=${GR_AGE}m, marker_active=${MARKER_ACTIVE}) — skipping."
        ;;
    esac
  done
fi

# ── Step 0c: ga-3h8l — sweep orphaned story:in-flight labels ─────────────────
# story:in-flight is the Pilot's lane-occupancy signal. It is stripped at merge
# (gate PASS+merge dispatcher path) as of ga-3h8l. But beads can accumulate
# a stale story:in-flight via paths the dispatcher doesn't cover:
#   (a) story closed by hand / superseded without going through the gate
#   (b) story merged outside the full gate flow (no gate:passed set)
#   (c) any future path that misses the dispatcher's PASS block
#
# Sweep condition: story:in-flight bead is CLOSED OR carries gate:passed.
# Both states mean the build is done — delivery either completed or will complete
# on its own — so the lane slot is permanently leaked. Strip and log.
#
# bd list without --all returns only OPEN beads. To catch closed beads, use --all.
# We then filter in jq: status==closed OR labels include gate:passed.

log "Checking for orphaned story:in-flight labels (ga-3h8l reconciler)..."

INFLIGHT_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l "story:in-flight" \
  -n 0 \
  2>/dev/null || echo "[]")

INFLIGHT_COUNT=$(echo "$INFLIGHT_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  ORPHAN_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status == "closed" or
      ((.labels // []) | contains(["gate:passed"]))
    ) | .id' 2>/dev/null || echo "")

  for ORP_ID in $ORPHAN_IDS; do
    [ -z "$ORP_ID" ] && continue
    warn "Stripping orphaned story:in-flight from $ORP_ID (ga-3h8l reconciler: closed or gate:passed)"
    bd -C "$GC_CITY" label remove "$ORP_ID" "story:in-flight" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$ORP_ID" "ga-3h8l reconciler: stripped orphaned story:in-flight (bead is closed or carries gate:passed — lane slot was permanently leaked). Self-healed." 2>/dev/null || true
  done
fi

# ── Step 1: Find unclaimed ready-for-gate markers ─────────────────────────────

MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:ready \
  2>/dev/null || echo "[]")

COUNT=$(echo "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT unclaimed marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No work. Exiting."
  exit 0
fi

# ── Step 2: Claim the first marker (atomic conditional claim) ─────────────────
# We remove the "ready" label first. If another process already removed it
# (race), the remove will report nothing changed and the re-fetch below will
# confirm the claim is ours or not.

MARKER=$(echo "$MARKERS_JSON" | jq '.[0]')
MARKER_ID=$(echo "$MARKER" | jq -r '.id')

log "Attempting to claim marker $MARKER_ID ..."

# Remove ready label (may be a no-op if another sweep beat us)
bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:ready" -q 2>/dev/null || true

# Re-fetch the marker to verify its current state
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "{}")
CURRENT_LABELS=$(echo "$VERIFY_JSON" | jq -r '(.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$CURRENT_LABELS" | grep -q "gate-status:claimed"; then
  log "Marker $MARKER_ID already claimed by another sweep. Skipping."
  exit 0
fi

if echo "$CURRENT_LABELS" | grep -q "gate-status:ready"; then
  # Someone re-added ready, or remove failed silently; abort to avoid double dispatch
  log "Marker $MARKER_ID still in ready state after remove attempt (race condition). Skipping."
  exit 0
fi

# We removed ready without another process adding claimed — add claimed atomically
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || {
  err "Failed to add gate-status:claimed to $MARKER_ID. Aborting."
  exit 1
}

log "Marker $MARKER_ID claimed."

# ── Step 3: Extract metadata from marker description ─────────────────────────

DESC=$(echo "$MARKER" | jq -r '.description // ""')

extract() {
  echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//"
}

BRANCH=$(extract "branch")
BEAD_ID=$(extract "bead_id")
MARKER_AUTHOR=$(extract "author")  # Self-declared — used for logging only, NOT for exclusion
BASE_COMMIT=$(extract "base_commit")
RIG=$(extract "rig")

log "  branch=$BRANCH  bead_id=$BEAD_ID  marker_author=${MARKER_AUTHOR:-<EMPTY>}  rig=$RIG"

# ── Step 4: Input validation (security: prevent injection) ──────────────────

VALIDATION_OK=true

if [ -z "$BRANCH" ] || ! validate_branch "$BRANCH"; then
  err "branch '$BRANCH' is missing or contains unsafe characters. Deferring."
  VALIDATION_OK=false
fi

if [ -z "$BEAD_ID" ] || ! validate_bead_id "$BEAD_ID"; then
  err "bead_id '$BEAD_ID' is missing or has unexpected format. Deferring."
  VALIDATION_OK=false
fi

if [ -n "$RIG" ] && ! validate_rig "$RIG"; then
  err "rig '$RIG' is not in the known rig list. Deferring."
  VALIDATION_OK=false
fi

if [ "$VALIDATION_OK" = "false" ]; then
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"   -q 2>/dev/null || true
  # Bug 3 fix: no Mayor mail — autonomous gate; author gets nudge if resolvable
  if [ -n "$BEAD_ID" ]; then
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard rejected marker: invalid/unsafe field values.
branch='$BRANCH' bead_id='$BEAD_ID' rig='$RIG'
Marker set to gate-status:error. Fix the marker fields and re-submit." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (marker error, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): invalid marker $MARKER_ID — security check failed (gate-status:error)."
  exit 1
fi

# ── Step 5: Derive author from the authoritative bead record ─────────────────
# SECURITY: Do NOT use MARKER_AUTHOR (self-declared by worker) for exclusion.
# Instead, look up the bead's assignee or owner in the DB. This prevents
# an attacker from spoofing the author field to bypass self-review checks.
#
# Resolution order:
#   1. Cross-rig lookup via "gc bd show" (handles beads in rig DBs, e.g. wa-*, ps-*).
#   2. HQ DB fallback (bd -C $GC_CITY show) for beads created in the HQ DB.
#   3. Session-id normalization: if assignee is "digo-adhoc-e2510107f6" → strip adhoc
#      suffix → "digo" (the crew role/identity). Prevents false unresolvable on crew beads.

AUTHOR=""

# bead_field_grep <raw_json_text> <field_name>
# Extracts a simple string field from potentially-malformed JSON output.
# Uses grep/sed instead of jq because gc bd output may contain literal newlines
# embedded in string values (invalid JSON per RFC7159) that cause jq 1.8.1+ to fail.
bead_field_grep() {
  local raw="$1" field="$2"
  # The || true prevents pipefail from aborting when grep finds no match (exits 1).
  echo "$raw" | grep -o "\"${field}\": *\"[^\"]*\"" \
    | sed "s/\"${field}\": *\"\(.*\)\"/\1/" \
    | head -1 || true
}

BEAD_RAW=""
if [ -n "$BEAD_ID" ]; then
  # 1. Cross-rig lookup via gc bd (authoritative — queries the owning rig's Dolt DB).
  #    Handles beads in rig DBs (e.g. wa-*, ps-*) that are NOT in the HQ DB.
  BEAD_RAW=$(gc --city "$GC_CITY" bd show "$BEAD_ID" --json 2>/dev/null || echo "")

  if [ -z "$BEAD_RAW" ]; then
    log "  gc bd cross-rig lookup empty; falling back to HQ DB."
    BEAD_RAW=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null || echo "")
  fi

  # Extract fields using grep (robust to embedded-newline JSON from gc bd)
  # Try assignee first, then owner/creator
  AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "created_by")
  fi
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "owner")
  fi
fi

# Session-id normalization: strip adhoc suffix from session IDs to get the crew role.
# e.g. "digo-adhoc-e2510107f6" → "digo", "batista-adhoc-abc123" → "batista"
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then
  AUTHOR_NORMALIZED=$(echo "$AUTHOR" | sed 's/-adhoc-[0-9a-f]*$//')
  log "  Author '$AUTHOR' looks like a session-id; normalizing to crew role '$AUTHOR_NORMALIZED'."
  AUTHOR="$AUTHOR_NORMALIZED"
fi

if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  warn "Cannot determine author authoritatively for bead $BEAD_ID — DEFERRING (fail-safe)."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed"  -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred" -q 2>/dev/null || true
  # Bug 3 fix: no Mayor mail — author-unresolvable is a bead data issue, not a Mayor task.
  # Comment on the marker bead with diagnostic info; ntfy alerts Athos if needed.
  bd -C "$GC_CITY" comment "$MARKER_ID" "Gate guard deferred: cannot determine author authoritatively for bead $BEAD_ID.
Marker self-declared author: ${MARKER_AUTHOR:-<empty>}
Self-review prevention requires an authoritative author source.
Fix the bead's assignee/created_by field and re-submit." 2>/dev/null || true
  # wa-uthi: non-terminal (deferred — bead data issue, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): author unresolvable for marker $MARKER_ID — deferred (gate-status:deferred)."
  exit 0
fi

log "Authoritative author: $AUTHOR"

# ── Step 6: Create gate-run tracking bead ─────────────────────────────────────

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "quality-gate: $BRANCH ($BEAD_ID)" \
  -t chore --ephemeral \
  -l type:quality-gate-run \
  -l gate-status:running \
  -l "source-bead:$BEAD_ID" \
  -d "Quality gate run for branch $BRANCH.
source_bead: $BEAD_ID
author: $AUTHOR
rig: $RIG
base_commit: ${BASE_COMMIT:-unknown}
marker_id: $MARKER_ID
started_at: $NOW" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$GATE_RUN_ID" ]; then
  warn "Could not create gate-run tracking bead. Continuing without it."
  GATE_RUN_ID="unknown"
fi
log "Gate-run tracking bead: $GATE_RUN_ID"

# ── Step 7: Park marker for autonomous dispatcher (G) ────────────────────────
#
# The guard's role is to: scan, validate, claim, derive author (security),
# create the gate-run tracking bead, then park as gate-status:queued.
#
# The autonomous Quality Gate Dispatcher (G, com.gascity.quality-gate-dispatcher)
# picks up gate-status:queued markers and runs the full review + merge flow
# independently. No Mayor involvement required — the gate is fully autonomous.
#
# NOTE: This comment block previously referred to "Mayor dispatch" — that was
# a legacy message from before G was built. G is now the dispatcher.
# Bug 3 fix (ga-v60): removed obsolete Mayor-notification mails.

log "Guard: parking marker $MARKER_ID as gate-status:queued for autonomous dispatcher (G)."

bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:claimed" -q 2>/dev/null || true
bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:queued"  -q 2>/dev/null || true
bd -C "$GC_CITY" update "$GATE_RUN_ID" \
  --notes "Guard claimed marker and created gate-run bead. Marker queued for autonomous dispatcher (G)." \
  2>/dev/null || true

# Notify the author (not Mayor) that their branch is queued for autonomous review
if [ -n "$AUTHOR" ]; then
  gc --city "$GC_CITY" session nudge "$AUTHOR" \
    "Your branch $BRANCH ($BEAD_ID) has passed guard validation and is queued for autonomous quality gate review (G). No action needed — G will process it within ~2 minutes." \
    --delivery wait-idle 2>/dev/null || true
fi

# wa-uthi: non-terminal (queued / entered review) — no push to Athos. The author
# is nudged above; Athos only hears about terminal outcomes (merged / rejected).
log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH queued for autonomous gate review (G dispatching)."

log "Marker $MARKER_ID parked as queued, autonomous dispatcher (G) will pick it up (gate-run=$GATE_RUN_ID)"

# ── Step 8: Append guard sweep to structured log ──────────────────────────────

mkdir -p "$(dirname "$QG_LOG")"
# FM-1 FIX: use -c (compact) so each event is a single line.
# The painel reads JSON-LINES (one object per line); pretty-printed multi-line
# JSON breaks json.loads() per line.
jq -c -n \
  --arg ts "$NOW" \
  --arg branch "$BRANCH" \
  --arg bead "$BEAD_ID" \
  --arg rig "${RIG:-unknown}" \
  --arg marker "$MARKER_ID" \
  --arg gate_run "$GATE_RUN_ID" \
  --arg target "autonomous-dispatcher-G" \
  '{ts: $ts, event: "guard_queued", branch: $branch, bead: $bead, rig: $rig, marker: $marker, gate_run: $gate_run, target: $target}' \
  >> "$QG_LOG" 2>/dev/null || true

log "=== Guard sweep complete ==="

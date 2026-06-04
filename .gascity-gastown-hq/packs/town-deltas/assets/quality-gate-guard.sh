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

# TTL for stuck "claimed" markers: 30 minutes
CLAIM_TTL_MINUTES=30

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

# TTL for stuck gate-run:running beads: 90 minutes.
# Gate-runs created by the guard but never executed (ghost runs) would otherwise
# permanently occupy gate-status:running. 90m > the dispatcher's 45m verdict timeout,
# so any legitimate in-flight run finishes before we would abort it.
GATE_RUN_TTL_MINUTES=90

# ── Step 0: TTL recovery — release stuck "claimed" markers ───────────────────
# If a marker has been in gate-status:claimed for > CLAIM_TTL_MINUTES, the
# runner likely died without cleaning up. Release it back to "ready" so the
# next sweep can re-claim it.

log "Checking for stuck claimed markers (TTL=${CLAIM_TTL_MINUTES}m)..."

CLAIMED_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:claimed \
  2>/dev/null || echo "[]")

CLAIMED_COUNT=$(echo "$CLAIMED_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$CLAIMED_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)
  for i in $(seq 0 $((CLAIMED_COUNT - 1))); do
    C_MARKER=$(echo "$CLAIMED_JSON" | jq ".[$i]")
    C_ID=$(echo "$C_MARKER" | jq -r '.id')
    C_UPDATED=$(echo "$C_MARKER" | jq -r '.updated_at // .created_at // ""')

    if [ -z "$C_UPDATED" ]; then
      continue
    fi

    # Parse ISO8601 updated_at to epoch (macOS-compatible)
    C_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${C_UPDATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$C_UPDATED" +%s 2>/dev/null || echo "0")

    AGE_MINUTES=$(( (NOW_EPOCH - C_EPOCH) / 60 ))

    if [ "$AGE_MINUTES" -gt "$CLAIM_TTL_MINUTES" ]; then
      warn "Releasing stale claimed marker $C_ID (age=${AGE_MINUTES}m > TTL=${CLAIM_TTL_MINUTES}m)"
      bd -C "$GC_CITY" label remove "$C_ID" "gate-status:claimed" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$C_ID" "gate-status:ready"   -q 2>/dev/null || true
    fi
  done
fi

# ── Step 0b: TTL recovery — abort ghost gate-run:running beads ────────────────
# Bug 2a fix: gate-run beads created by the guard (type:quality-gate-run,
# gate-status:running) that survive longer than GATE_RUN_TTL_MINUTES are
# "ghost" runs — the corresponding dispatcher sweep never started or crashed.
# A ghost run with gate-status:running does NOT block the dispatcher from
# picking up its queued marker (the dispatcher doesn't dedup on gate-runs),
# but it creates misleading state and burns ephemeral bead quota.
# Abort them cleanly so the state accurately reflects reality.
#
# TTL is set to 90m — well above the dispatcher's 45m verdict timeout, so
# any legitimately in-flight run (reviewers polling) is never aborted.

log "Checking for ghost gate-run:running beads (TTL=${GATE_RUN_TTL_MINUTES}m)..."

GHOST_RUNS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")

GHOST_COUNT=$(echo "$GHOST_RUNS_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$GHOST_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)
  for i in $(seq 0 $((GHOST_COUNT - 1))); do
    GR=$(echo "$GHOST_RUNS_JSON" | jq ".[$i]")
    GR_ID=$(echo "$GR" | jq -r '.id')
    GR_UPDATED=$(echo "$GR" | jq -r '.updated_at // .created_at // ""')

    if [ -z "$GR_UPDATED" ]; then
      continue
    fi

    GR_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${GR_UPDATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$GR_UPDATED" +%s 2>/dev/null || echo "0")

    GR_AGE_MINUTES=$(( (NOW_EPOCH - GR_EPOCH) / 60 ))

    if [ "$GR_AGE_MINUTES" -gt "$GATE_RUN_TTL_MINUTES" ]; then
      warn "Aborting ghost gate-run $GR_ID (age=${GR_AGE_MINUTES}m > TTL=${GATE_RUN_TTL_MINUTES}m)"
      bd -C "$GC_CITY" label remove "$GR_ID" "gate-status:running" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$GR_ID" "gate-status:aborted" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$GR_ID" "Ghost gate-run aborted by guard TTL recovery (age=${GR_AGE_MINUTES}m > ${GATE_RUN_TTL_MINUTES}m TTL). The dispatcher never executed this run. Corresponding marker will be re-processed if still queued." 2>/dev/null || true
    fi
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
  notify -t "Quality Gate Guard" -p 3 "Invalid marker $MARKER_ID — security check failed (gate-status:error)" 2>/dev/null || true
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
  notify -t "Quality Gate Guard" -p 3 "Author unresolvable for marker $MARKER_ID — deferred (gate-status:deferred)" 2>/dev/null || true
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

notify -t "Quality Gate" -p 2 "Branch $BRANCH queued for autonomous gate review (G dispatching)" 2>/dev/null || true

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

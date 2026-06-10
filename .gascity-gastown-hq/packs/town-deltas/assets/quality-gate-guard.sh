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
# ga-o57gn: a gate-run legitimately stays gate-status:running only while its
# owning dispatcher process polls verdicts — capped at VERDICT_TIMEOUT_MINUTES
# (dispatcher default 45). Past that, a still-running gate-run with no live
# reviewer is a zombie (dispatcher died/OOM/credit-limited). Kept in sync with
# the dispatcher's VERDICT_TIMEOUT_MINUTES default so the dead-reviewer sweep
# fires right after a real run would have driven itself terminal.
GATE_VERDICT_TIMEOUT_MINUTES="${VERDICT_TIMEOUT_MINUTES:-45}"
# Margin past verdict-timeout before the dead-reviewer sweep fires. The
# dispatcher closes reviewer sessions (Step 9) BEFORE it stamps the gate-run
# terminal (post-merge), so a run whose verdicts land NEAR the timeout has a
# brief window with reviewers closed but the bead still running. The margin
# keeps the sweep clear of that window — a live run is terminal well before
# (verdict-timeout + margin), so only genuinely abandoned runs are caught.
GATE_DEAD_REVIEWER_MARGIN_MINUTES="${GATE_DEAD_REVIEWER_MARGIN_MINUTES:-10}"
GATE_ZOMBIE_AGE_MINUTES=$(( GATE_VERDICT_TIMEOUT_MINUTES + GATE_DEAD_REVIEWER_MARGIN_MINUTES ))

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

# reconcile_gaterun_action <age_min> <ttl_min> <marker_active: 0|1> \
#                          [verdict_timeout_min] [reviewers_alive: 0|1]
# Pure decision: what to do with a gate-run bead stuck in gate-status:running.
# Returns: skip | supersede:marker | supersede:dead-reviewers | abort:age
#
# Priority (most-specific / safest first):
#   1. marker terminal/gone (marker_active=0) → supersede:marker     [ga-tmug]
#   2. age > verdict_timeout AND reviewers_alive=0 → supersede:dead-reviewers
#      [ga-o57gn] The owning dispatcher caps a real run at verdict_timeout, so a
#      run still RUNNING past that with no live reviewer is abandoned. Requiring
#      BOTH conditions means we NEVER kill a live run: a live dispatcher reaches
#      terminal by verdict_timeout, and the reviewer-liveness check is the
#      corroborating signal the bug (ga-o57gn) asked for.
#   3. age > ttl (90m hard cap) → abort:age                          [ga-tmug]
#   4. else → skip (in-flight, untouched)
#
# Back-compat: callers may omit the last two args. Defaults (verdict_timeout
# effectively infinite, reviewers_alive=1) make rule 2 inert, so a 3-arg call
# behaves EXACTLY as the pre-ga-o57gn function did.
reconcile_gaterun_action() {
  local age_min="$1" ttl_min="$2" marker_active="$3"
  local verdict_timeout_min="${4:-999999}" reviewers_alive="${5:-1}"
  [ "$marker_active" = "0" ] && { echo "supersede:marker"; return; }
  if [ "$reviewers_alive" = "0" ] && [ "$age_min" -gt "$verdict_timeout_min" ]; then
    echo "supersede:dead-reviewers"; return
  fi
  [ "$age_min" -le "$ttl_min" ] && { echo "skip"; return; }
  echo "abort:age"
}

# dedup_gaterun_action <group_count> <is_newest: 0|1>
# Pure decision: enforce ≤1 running gate-run per source-bead/marker (ga-o57gn (c)).
# The guard creates a tracking gate-run at claim time and the dispatcher creates
# its OWN at dispatch time; a re-queued marker (dead-dispatcher recovery) then
# spawns yet another. Multiple gate-runs sharing a marker_id are thus normal
# transiently — but only the NEWEST is the live run; older ones are stale and
# inflate the "GATES RODANDO" count. Keep the newest, supersede the rest.
# A lone run (group_count<=1) is always kept. Returns: keep | supersede:duplicate
dedup_gaterun_action() {
  local group_count="$1" is_newest="$2"
  case "$group_count" in ''|*[!0-9]*) echo "keep"; return ;; esac
  [ "$group_count" -le 1 ] && { echo "keep"; return; }
  [ "$is_newest" = "1" ] && { echo "keep"; return; }
  echo "supersede:duplicate"
}

# ── set_gate_status <bead_id> <new_status> ─────────────────────────────────
# Atomic-effect gate-status transition: leave EXACTLY ONE gate-status:* label on
# the bead. The legacy `label remove <known>; label add <new>` pattern is
# non-atomic and, when the prior status is unknown or already dual, leaks two
# gate-status labels (observed live: done+failed, passed+superseded — ga-jhyu).
# This strips EVERY gate-status:* currently present, then adds the single target.
# I/O helper (not a pure fn) but defined here in the lib region so the selftest
# can source + unit-test it with a mock bd. Kept BYTE-IDENTICAL with the
# dispatcher's copy (drift-guarded by quality-gate-reconcile.selftest.sh).
set_gate_status() {
  local _id="$1" _new="$2" _cur _lbl
  [ -z "$_id" ] && return 0
  _cur=$(bd -C "$GC_CITY" show "$_id" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | (.labels // [])[]? | select(startswith("gate-status:"))' 2>/dev/null || true)
  for _lbl in $_cur; do
    [ "$_lbl" = "gate-status:$_new" ] && continue
    bd -C "$GC_CITY" label remove "$_id" "$_lbl" -q 2>/dev/null || true
  done
  bd -C "$GC_CITY" label add "$_id" "gate-status:$_new" -q 2>/dev/null || true
}

# classify_inflight_gap1 <status> <has_gate_passed> <has_live_assignee> <branch_merged>
# Pure decision for ga-pa36 GAP-1: OPEN story:in-flight bead whose fix branch
# was already merged to origin/main but has no gate:passed label.
# branch_merged: 1=merged, 0=not-merged, anything-else=indeterminate (safe-skip).
# Returns: strip:merged | skip:already-handled | skip:live-builder | skip:not-merged | skip:indeterminate
classify_inflight_gap1() {
  local status="$1" has_gate_passed="$2" has_live_assignee="$3" branch_merged="$4"
  [ "$status" = "closed" ]       && { echo "skip:already-handled"; return; }
  [ "$has_gate_passed" = "1" ]   && { echo "skip:already-handled"; return; }
  [ "$has_live_assignee" = "1" ] && { echo "skip:live-builder"; return; }
  case "$branch_merged" in
    1) echo "strip:merged" ;;
    0) echo "skip:not-merged" ;;
    *) echo "skip:indeterminate" ;;
  esac
}

# classify_parent_gap2 <has_pilot_dispatched> <has_live_assignee> <sling_found> <sling_needs_fix> <sling_closed>
# Pure decision for ga-pa36 GAP-2: parent story/bug retains story:in-flight after
# the gate ran on a sling/work bead (Pilot-dispatched path) and that bead is terminal.
# sling_needs_fix: 1 if sling bead has gate:needs-fix or gate:needs-human (gate FAILED).
# sling_closed:    1 if sling bead is closed (gate PASSED, work done).
# Returns: free:fail-stranded | free:pass-stranded | skip:not-dispatched | skip:live-assignee | skip:no-sling | skip:active-sling
classify_parent_gap2() {
  local has_pilot_dispatched="$1" has_live_assignee="$2" sling_found="$3" sling_needs_fix="$4" sling_closed="$5"
  [ "$has_pilot_dispatched" != "1" ] && { echo "skip:not-dispatched"; return; }
  [ "$has_live_assignee" = "1" ]     && { echo "skip:live-assignee"; return; }
  [ "$sling_found" != "1" ]          && { echo "skip:no-sling"; return; }
  [ "$sling_needs_fix" = "1" ]       && { echo "free:fail-stranded"; return; }
  [ "$sling_closed" = "1" ]          && { echo "free:pass-stranded"; return; }
  echo "skip:active-sling"
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
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:queued"      -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:dispatching for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Dispatcher likely crashed. Re-queued for re-processing (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      requeue:ready)
        warn "Vector A: re-readying zombie claimed marker $T_ID (age=${T_AGE}m, reclaims=${T_COUNT})"
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:claimed"     -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$T_ID" "gate-status:dispatching" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$T_ID" "gate-status:ready"       -q 2>/dev/null || true
        [ "$T_COUNT" -gt 0 ] && \
          bd -C "$GC_CITY" label remove "$T_ID" "gate-reclaim-count:${T_COUNT}" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add "$T_ID" "gate-reclaim-count:$((T_COUNT+1))" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$T_ID" "Vector A (ga-tmug): marker stuck in gate-status:claimed for ${T_AGE}m (> ${CLAIM_TTL_MINUTES}m TTL). Guard likely crashed. Re-readied for re-claim (reclaim $((T_COUNT+1))/${MAX_RECLAIMS})." 2>/dev/null || true
        ;;
      error)
        warn "Vector A: exhausted reclaims for $T_ID (count=${T_COUNT} >= MAX_RECLAIMS=${MAX_RECLAIMS})"
        set_gate_status "$T_ID" "error"
        # ga-jhyu: do NOT close on error. gate-health-monitor.py pages a human on
        # OPEN markers stuck in gate-status:error >10min (ga-piscg). Closing here
        # would make that escalation blind. The marker is reaped after a human
        # resolves it (which closes it), not at the error transition.
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

log "Step 0b: Vector B reconcile — orphan gate-run:running beads (TTL=${GATE_RUN_TTL_MINUTES}m, zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m=verdict-timeout+margin)..."

# reviewers_alive_for_run <gate_run_id> — I/O helper (ga-o57gn).
# Echo 1 iff at least one of this gate-run's still-OPEN verdict beads is assigned
# to a reviewer session that is present (alive) in SESS_SNAP_JSON, else 0. A
# gate-run still running past verdict-timeout with zero live reviewers is a
# zombie whose dispatcher died. (Live section only — uses bd/gc; never called in
# lib-only mode, so it is intentionally NOT one of the drift-guarded pure fns.)
reviewers_alive_for_run() {
  local gr_id="$1" vbs assignees a present
  [ -z "$gr_id" ] && { echo 0; return; }
  vbs=$(bd -C "$GC_CITY" list --json --all \
    -l type:quality-gate-verdict -l "gate-run:$gr_id" 2>/dev/null || echo "[]")
  # Only OPEN verdict beads matter — a closed verdict means the reviewer finished.
  assignees=$(printf '%s\n' "$vbs" \
    | jq -r '.[]? | select((.status // "") != "closed") | .assignee // empty' \
    2>/dev/null || true)
  [ -z "$assignees" ] && { echo 0; return; }
  for a in $assignees; do
    [ -z "$a" ] && continue
    present=$(printf '%s\n' "$SESS_SNAP_JSON" \
      | jq -r --arg s "$a" 'if type=="array" then . else (.sessions // []) end
          | map(select((.id==$s) or (.session_name==$s) or (.session_id==$s))
                | select((.closed // false) != true)) | length' \
      2>/dev/null || echo 0)
    case "$present" in ''|*[!0-9]*) present=0 ;; esac
    [ "$present" -ge 1 ] && { echo 1; return; }
  done
  echo 0
}

GATE_RUNS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-run \
  -l gate-status:running \
  2>/dev/null || echo "[]")
GATE_RUN_COUNT=$(printf '%s\n' "$GATE_RUNS_JSON" | jq 'length' 2>/dev/null || echo "0")
case "$GATE_RUN_COUNT" in ''|*[!0-9]*) GATE_RUN_COUNT=0 ;; esac

if [ "$GATE_RUN_COUNT" -gt 0 ]; then
  NOW_EPOCH=$(date +%s)

  # One session snapshot for the whole sweep (reviewer-liveness lookups, ga-o57gn).
  SESS_SNAP_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo '{}')

  # ── First pass: build the dedup grouping key for every running gate-run. ────
  # ga-o57gn (c): enforce ≤1 running gate-run per marker. Key on marker_id
  # (canonical — matches the anti-false-positive guidance below); fall back to
  # the source-bead label when a description carries no marker_id. created_at is
  # an ISO-8601 'Z' string, so a lexical compare == a chronological compare.
  GR_ID_ARR=(); GR_KEY_ARR=(); GR_CREATED_ARR=()
  for i in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    _gr=$(printf '%s\n' "$GATE_RUNS_JSON" | jq ".[$i]")
    _id=$(printf '%s\n' "$_gr" | jq -r '.id // ""')
    _created=$(printf '%s\n' "$_gr" | jq -r '.created_at // .updated_at // ""')
    _desc=$(printf '%s\n' "$_gr" | jq -r '.description // ""')
    _key=$(parse_marker_id "$_desc")
    if [ -z "$_key" ]; then
      _key=$(printf '%s\n' "$_gr" \
        | jq -r '(.labels // [])[]? | select(startswith("source-bead:"))' 2>/dev/null | head -1 || true)
    fi
    GR_ID_ARR+=("$_id"); GR_KEY_ARR+=("$_key"); GR_CREATED_ARR+=("$_created")
  done

  for i in $(seq 0 $((GATE_RUN_COUNT - 1))); do
    GR=$(printf '%s\n' "$GATE_RUNS_JSON" | jq ".[$i]")
    GR_ID="${GR_ID_ARR[$i]}"
    GR_UPDATED=$(printf '%s\n' "$GR" | jq -r '.updated_at // .created_at // ""')
    GR_DESC=$(printf '%s\n' "$GR" | jq -r '.description // ""')

    GR_AGE=$(age_minutes_of "$GR_UPDATED" "$NOW_EPOCH")

    # ── Dedup decision: does a NEWER running gate-run share this key? ─────────
    # Keep-newest never supersedes the newest run, so a live re-dispatch (always
    # the newest) is safe; only the stale older siblings (guard tracking bead,
    # dead-dispatcher re-queue remnants) are superseded.
    _key="${GR_KEY_ARR[$i]}"
    _group_count=0; _is_newest=1
    if [ -n "$_key" ]; then
      for j in $(seq 0 $((GATE_RUN_COUNT - 1))); do
        [ "${GR_KEY_ARR[$j]}" = "$_key" ] || continue
        _group_count=$((_group_count + 1))
        [ "$j" -eq "$i" ] && continue
        _cj="${GR_CREATED_ARR[$j]}"; _ci="${GR_CREATED_ARR[$i]}"
        if [[ "$_cj" > "$_ci" ]] || { [ "$_cj" = "$_ci" ] && [[ "${GR_ID_ARR[$j]}" > "$GR_ID" ]]; }; then
          _is_newest=0
        fi
      done
    fi
    DEDUP_ACTION=$(dedup_gaterun_action "$_group_count" "$_is_newest")
    if [ "$DEDUP_ACTION" = "supersede:duplicate" ]; then
      warn "Vector B: superseding STALE DUPLICATE gate-run $GR_ID (a newer running run shares key='$_key'; keep-newest dedup, ga-o57gn)"
      set_gate_status "$GR_ID" "superseded"
      bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-o57gn): stale duplicate — a newer running gate-run shares this marker/source-bead. Keep-newest dedup enforces ≤1 running gate-run per source-bead. Self-healed by guard." 2>/dev/null || true
      bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — stale duplicate, newer running run exists. Closed by guard (ga-o57gn)." 2>/dev/null || true
      continue
    fi

    # Determine if the companion marker is still active.
    # parse_marker_id extracts the marker_id: field written by the guard at Step 6.
    COMPANION_MARKER_ID=$(parse_marker_id "$GR_DESC")
    MARKER_ACTIVE=0
    if [ -n "$COMPANION_MARKER_ID" ]; then
      MARKER_JSON=$(bd -C "$GC_CITY" show "$COMPANION_MARKER_ID" --json 2>/dev/null || echo "")
      if [ -n "$MARKER_JSON" ]; then
        MARKER_LABELS=$(printf '%s\n' "$MARKER_JSON" \
          | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
          2>/dev/null || echo "")
        printf '%s\n' "$MARKER_LABELS" | grep -qE "gate-status:(queued|claimed|dispatching)" \
          && MARKER_ACTIVE=1 || true
        printf '%s\n' "$MARKER_LABELS" | grep -qE "gate-status:" || MARKER_ACTIVE=1
      fi
    fi

    # ── Reviewer-liveness (ga-o57gn): computed ONLY when it can change the
    # outcome — the marker still looks active AND the run is already past
    # verdict-timeout. This bounds the extra bd/gc round-trip to genuine
    # zombie candidates and never touches young/in-flight runs.
    REVIEWERS_ALIVE=1
    if [ "$MARKER_ACTIVE" = "1" ] && [ "$GR_AGE" -gt "$GATE_ZOMBIE_AGE_MINUTES" ]; then
      REVIEWERS_ALIVE=$(reviewers_alive_for_run "$GR_ID")
    fi

    ACTION=$(reconcile_gaterun_action "$GR_AGE" "$GATE_RUN_TTL_MINUTES" "$MARKER_ACTIVE" "$GATE_ZOMBIE_AGE_MINUTES" "$REVIEWERS_ALIVE")
    case "$ACTION" in
      supersede:marker)
        warn "Vector B: superseding orphan gate-run $GR_ID (age=${GR_AGE}m, marker $COMPANION_MARKER_ID is terminal/gone)"
        set_gate_status "$GR_ID" "superseded"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): orphan gate-run superseded — companion marker $COMPANION_MARKER_ID is terminal/gone; run is no longer active. Self-healed by guard." 2>/dev/null || true
        # ga-jhyu: CLOSE at terminal so wisp-compact reaps it (was relabel-only → OPEN forever).
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — companion marker $COMPANION_MARKER_ID terminal/gone. Closed by guard (ga-jhyu)." 2>/dev/null || true
        ;;
      supersede:dead-reviewers)
        warn "Vector B: superseding ZOMBIE gate-run $GR_ID (age=${GR_AGE}m > zombie-age=${GATE_ZOMBIE_AGE_MINUTES}m [verdict-timeout ${GATE_VERDICT_TIMEOUT_MINUTES}m + margin ${GATE_DEAD_REVIEWER_MARGIN_MINUTES}m], no live reviewer — dispatcher abandoned it; ga-o57gn)"
        set_gate_status "$GR_ID" "superseded"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-o57gn): zombie gate-run superseded — age ${GR_AGE}m exceeds verdict-timeout+margin (${GATE_ZOMBIE_AGE_MINUTES}m) AND no live reviewer is assigned to an open verdict bead. The owning dispatcher died/was killed mid-run. Self-healed by guard." 2>/dev/null || true
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run superseded (terminal) — zombie: age>verdict-timeout, no live reviewer. Closed by guard (ga-o57gn)." 2>/dev/null || true
        ;;
      abort:age)
        warn "Vector B: aborting gate-run $GR_ID by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m, marker_active=${MARKER_ACTIVE})"
        set_gate_status "$GR_ID" "aborted"
        bd -C "$GC_CITY" comment "$GR_ID" "Vector B (ga-tmug): gate-run aborted by guard TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m; marker $COMPANION_MARKER_ID still active but run exceeded max wait)." 2>/dev/null || true
        # ga-jhyu: CLOSE at terminal so wisp-compact reaps it.
        bd -C "$GC_CITY" close "$GR_ID" -r "gate-run aborted (terminal) by TTL fallback (age=${GR_AGE}m > ${GATE_RUN_TTL_MINUTES}m). Closed by guard (ga-jhyu)." 2>/dev/null || true
        ;;
      skip)
        log "  Gate-run $GR_ID active (age=${GR_AGE}m, marker_active=${MARKER_ACTIVE}, reviewers_alive=${REVIEWERS_ALIVE}) — skipping."
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

# ── Step 0c.1 (ga-pa36 GAP-1): merged-but-OPEN beads ────────────────────────
# OPEN story:in-flight beads with no gate:passed whose fix branch was already
# merged to origin/main (merged via old gate before ga-3h8l strip code, or
# merged out-of-band). The existing Step-0c misses them because they are OPEN
# with no gate:passed.
# Safe-default: if branch SHA cannot be positively resolved → do NOT act.
# Pilot:dispatched beads are excluded — they are handled by GAP-2 below.

log "Step 0c.1 (ga-pa36 GAP-1): sweep merged-but-OPEN story:in-flight beads..."

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  GAP1_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status != "closed" and
      ((.labels // []) | contains(["gate:passed"]) | not) and
      ((.labels // []) | contains(["pilot:dispatched"]) | not)
    ) | .id' 2>/dev/null || echo "")

  if [ -n "$GAP1_IDS" ]; then
    G1_MAIN_SHA=""
    git -C "$GC_CITY" fetch origin main --quiet 2>/dev/null || true
    G1_MAIN_SHA=$(git -C "$GC_CITY" rev-parse "origin/main" 2>/dev/null || echo "")

    for OI_ID in $GAP1_IDS; do
      [ -z "$OI_ID" ] && continue

      # Check assignee via bd show (bd list --json does not include assignee).
      OI_SHOW=$(bd -C "$GC_CITY" show "$OI_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      OI_ASSIGNEE=$(echo "$OI_SHOW" | jq -r '.assignee // ""' 2>/dev/null || echo "")

      HAS_LIVE_ASSIGNEE=0
      if [ -n "$OI_ASSIGNEE" ] && [ "$OI_ASSIGNEE" != "null" ]; then
        SESSION_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo "{}")
        SESSION_MATCH=$(echo "$SESSION_JSON" | jq -r --arg a "$OI_ASSIGNEE" '
          .sessions // [] |
          if any(.; .id == $a or .name == $a)
          then "alive" else "dead" end
        ' 2>/dev/null || echo "uncertain")
        [ "$SESSION_MATCH" != "dead" ] && HAS_LIVE_ASSIGNEE=1
      fi

      ACTION=$(classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "unknown")
      if [ "$ACTION" = "skip:live-builder" ]; then
        log "GAP-1: $OI_ID has live assignee ($OI_ASSIGNEE) — safe-skip"
        continue
      fi

      if [ -z "$G1_MAIN_SHA" ]; then
        log "GAP-1: origin/main SHA unreachable — safe-skip all GAP-1 candidates"
        break
      fi

      # Find branch tip by convention: fix/<id>* or feature/<id>*
      # Prefer ls-remote (live) with for-each-ref as local cache fallback.
      OI_BRANCH_SHA=""
      for PAT in "refs/heads/fix/${OI_ID}" "refs/heads/fix/${OI_ID}-*" \
                 "refs/heads/feature/${OI_ID}" "refs/heads/feature/${OI_ID}-*"; do
        SHA=$(git -C "$GC_CITY" ls-remote origin "$PAT" 2>/dev/null | head -1 | awk '{print $1}')
        if [ -z "$SHA" ]; then
          RREF="${PAT/refs\/heads\//refs\/remotes\/origin\/}"
          SHA=$(git -C "$GC_CITY" for-each-ref --format='%(objectname)' "$RREF" 2>/dev/null | head -1)
        fi
        [ -n "$SHA" ] && { OI_BRANCH_SHA="$SHA"; break; }
      done

      if [ -z "$OI_BRANCH_SHA" ]; then
        log "GAP-1: $OI_ID — no branch matching fix/$OI_ID* or feature/$OI_ID* — safe-skip"
        continue
      fi

      BRANCH_MERGED=0
      git -C "$GC_CITY" merge-base --is-ancestor "$OI_BRANCH_SHA" "$G1_MAIN_SHA" \
        2>/dev/null && BRANCH_MERGED=1 || true

      ACTION=$(classify_inflight_gap1 "open" "0" "$HAS_LIVE_ASSIGNEE" "$BRANCH_MERGED")
      case "$ACTION" in
        strip:merged)
          warn "GAP-1: $OI_ID branch tip $OI_BRANCH_SHA merged to origin/main, no gate:passed, no live builder — stripping story:in-flight"
          bd -C "$GC_CITY" label remove "$OI_ID" "story:in-flight" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$OI_ID" "ga-pa36 GAP-1 reconciler: stripped orphaned story:in-flight — branch tip $OI_BRANCH_SHA already merged to origin/main, no gate:passed label, no live builder. Lane slot freed." 2>/dev/null || true
          ;;
        skip:not-merged)
          log "GAP-1: $OI_ID branch tip $OI_BRANCH_SHA not yet merged — skip"
          ;;
        *)
          log "GAP-1: $OI_ID action=$ACTION — skip"
          ;;
      esac
    done
  fi
fi

# ── Step 0c.2 (ga-pa36 GAP-2): parent-story stranding ────────────────────────
# When the gate runs on a SLING/WORK bead (Pilot-dispatched path), the FAIL
# self-heal strips story:in-flight from the WORK bead but the PARENT retains
# story:in-flight + pilot:dispatched with no builder — the Pilot's exclusion
# hides it forever. Detect via "Sling task bead: $ID" comment the Pilot writes.
# Safe-default: if sling bead ID is absent from comments or state is ambiguous
# → do NOT act.

log "Step 0c.2 (ga-pa36 GAP-2): sweep stranded parent stories..."

if [ "$INFLIGHT_COUNT" -gt 0 ]; then
  GAP2_IDS=$(echo "$INFLIGHT_JSON" | jq -r '
    .[] |
    select(
      .status != "closed" and
      ((.labels // []) | contains(["gate:passed"]) | not) and
      ((.labels // []) | contains(["pilot:dispatched"]))
    ) | .id' 2>/dev/null || echo "")

  for SC_ID in $GAP2_IDS; do
    [ -z "$SC_ID" ] && continue

    # Check parent's own assignee (Pilot does not assign story to builder, but be safe).
    SC_SHOW=$(bd -C "$GC_CITY" show "$SC_ID" --json --include-comments 2>/dev/null \
      | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
    SC_ASSIGNEE=$(echo "$SC_SHOW" | jq -r '.assignee // ""' 2>/dev/null || echo "")

    HAS_SC_ASSIGNEE=0
    if [ -n "$SC_ASSIGNEE" ] && [ "$SC_ASSIGNEE" != "null" ]; then
      SC_SESSION_JSON=$(gc --city "$GC_CITY" session list --json 2>/dev/null || echo "{}")
      SC_SESSION_MATCH=$(echo "$SC_SESSION_JSON" | jq -r --arg a "$SC_ASSIGNEE" '
        .sessions // [] |
        if any(.; .id == $a or .name == $a)
        then "alive" else "dead" end
      ' 2>/dev/null || echo "uncertain")
      [ "$SC_SESSION_MATCH" != "dead" ] && HAS_SC_ASSIGNEE=1
    fi

    # Find sling bead ID from Pilot dispatch comment.
    SLING_ID=$(echo "$SC_SHOW" | jq -r '
      .comments // [] | sort_by(.created_at) | reverse |
      .[] | .text // "" | select(test("Sling task bead:")) |
      capture("Sling task bead: (?P<id>[a-z][a-z0-9-]+)") | .id
    ' 2>/dev/null | head -1 || echo "")

    SLING_FOUND=0
    SLING_NEEDS_FIX=0
    SLING_CLOSED=0

    if [ -n "$SLING_ID" ] && [ "$SLING_ID" != "null" ]; then
      SLING_FOUND=1
      SLING_JSON=$(bd -C "$GC_CITY" show "$SLING_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SLING_STATUS=$(echo "$SLING_JSON" | jq -r '.status // ""' 2>/dev/null || echo "")
      SLING_LABELS=$(echo "$SLING_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")

      [ "$SLING_STATUS" = "closed" ] && SLING_CLOSED=1
      echo "$SLING_LABELS" | grep -qE "gate:needs-fix|gate:needs-human" && SLING_NEEDS_FIX=1 || true
    fi

    ACTION=$(classify_parent_gap2 "1" "$HAS_SC_ASSIGNEE" "$SLING_FOUND" "$SLING_NEEDS_FIX" "$SLING_CLOSED")

    case "$ACTION" in
      free:fail-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID gate-failed) — freeing lane, applying gate:needs-fix"

        # Propagate GATE-FEEDBACK from sling bead to parent.
        GATE_FEEDBACK=$(bd -C "$GC_CITY" show "$SLING_ID" --json --include-comments 2>/dev/null \
          | jq -r 'if type=="array" then .[0] else . end |
            .comments // [] | map(select(.text | test("^GATE-FEEDBACK"))) | last | .text // ""' \
          2>/dev/null || echo "")

        bd -C "$GC_CITY" label remove "$SC_ID" "story:in-flight"  -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$SC_ID" "pilot:dispatched" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$SC_ID" "gate:needs-fix"   -q 2>/dev/null || true

        if [ -n "$GATE_FEEDBACK" ]; then
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-failed. story:in-flight + pilot:dispatched cleared; gate:needs-fix set so Pilot re-dispatches.
Propagated from $SLING_ID: $GATE_FEEDBACK" 2>/dev/null || true
        else
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-failed (labels: $SLING_LABELS). story:in-flight + pilot:dispatched cleared; gate:needs-fix set. Pilot will re-dispatch." 2>/dev/null || true
        fi
        ;;
      free:pass-stranded)
        warn "GAP-2: $SC_ID stranded (sling $SLING_ID closed/passed) — freeing lane"
        SC_LABELS=$(echo "$SC_SHOW" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")

        bd -C "$GC_CITY" label remove "$SC_ID" "story:in-flight"  -q 2>/dev/null || true
        bd -C "$GC_CITY" label remove "$SC_ID" "pilot:dispatched" -q 2>/dev/null || true

        if echo "$SC_LABELS" | grep -q "story:approved"; then
          # Story-type parent: set gate:passed so story-delivery finalizes it.
          bd -C "$GC_CITY" label add "$SC_ID" "gate:passed" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$SC_ID" "ga-pa36 GAP-2 reconciler: parent stranded after sling bead $SLING_ID gate-passed+closed. story:in-flight + pilot:dispatched cleared; gate:passed set — story-delivery will deploy and mark story:done." 2>/dev/null || true
        else
          # Bug/task parent: close it (work was merged via sling bead).
          bd -C "$GC_CITY" close "$SC_ID" \
            -r "ga-pa36 GAP-2 reconciler: sling bead $SLING_ID gate-passed and closed — work is done; closing parent." \
            2>/dev/null || warn "Could not close parent $SC_ID after pass-stranded detection"
        fi
        ;;
      skip:live-assignee)
        log "GAP-2: $SC_ID has live assignee ($SC_ASSIGNEE) — safe-skip"
        ;;
      skip:no-sling)
        log "GAP-2: $SC_ID — no 'Sling task bead' comment found — safe-skip"
        ;;
      skip:active-sling)
        log "GAP-2: $SC_ID sling $SLING_ID is active (status=$SLING_STATUS) — skip"
        ;;
      skip:not-dispatched)
        log "GAP-2: $SC_ID not pilot:dispatched — skip (should not reach here)"
        ;;
    esac
  done
fi

# ── Step 1: Find unclaimed ready-for-gate markers ─────────────────────────────

MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:ready \
  2>/dev/null || echo "[]")

COUNT=$(printf '%s\n' "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT unclaimed marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No work. Exiting."
  exit 0
fi

# ── Step 2: Claim the first marker (atomic conditional claim) ─────────────────
# We remove the "ready" label first. If another process already removed it
# (race), the remove will report nothing changed and the re-fetch below will
# confirm the claim is ours or not.

MARKER=$(printf '%s\n' "$MARKERS_JSON" | jq '.[0]')
MARKER_ID=$(printf '%s\n' "$MARKER" | jq -r '.id')

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

DESC=$(printf '%s\n' "$MARKER" | jq -r '.description // ""')

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

# ga-mxhf6: protected-branch guard — builders must NEVER commit directly to main/master.
# branch=main is always an ancestor of itself, so the dispatcher supersedes the marker
# without running any reviewers, silently bypassing the gate.
if [ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ]; then
  err "branch '$BRANCH' is a protected branch. Builders must always use feature branches (e.g. fix/<id>-<desc>). Rejecting marker."
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
  # ga-jhyu: atomic single-label transition; do NOT close (gate-health-monitor.py
  # pages a human on OPEN gate-status:error markers — see Vector A note).
  set_gate_status "$MARKER_ID" "error"
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
# e.g. "digo-wa-adhoc-e2510107f6" → "digo-wa", "batista-lx-adhoc-abc123" → "batista-lx"
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

# ── Step 5b (ga-e7zk7): detach source bead from the dog pool — gate owns it now ──
# Why HERE (after Step 5), not before it: Step 5 derives the self-review-exclusion
# author from the source bead's record, and its FIRST-CHOICE signal is the bead's
# assignee (assignee → created_by → owner). assignee and created_by routinely
# diverge in production (e.g. assignee=oracle-wa, created_by=peter-wa — different
# crew). Clearing the assignee BEFORE Step 5 (the original ga-e7zk7 attempt) forced
# author resolution to fall through to created_by (the FILER), which would let the
# real builder be picked to review their own branch — the exact self-review bypass
# Step 5's SECURITY block exists to prevent. So the detach MUST run only after
# AUTHOR is resolved. By this line AUTHOR is final and the author-unresolvable
# fail-safe above has already `exit 0`d (correctly leaving such beads attached for
# re-dispatch), so detaching here is safe for both paths.
#
# What it fixes: the builder leaves the source bead in_progress + assignee=<pool
# alias> for the WHOLE gate duration (the gate closes it on PASS). Markers routinely
# sit queued for hours behind the single-threaded backlog, and throughout that
# window the dog-pool startup probes — label-blind and engine-baked (cannot be
# changed without an engine window) — keep re-matching the source bead:
#   - Step 1a: bd list --status in_progress --assignee=<session id|name|alias>
#              → every recycle of the builder's pool alias re-finds it (Vector 1a)
#   - Step 1c: bd ready --metadata-field gc.routed_to=<template> --unassigned
#              → on dog death the reconciler reset-to-ready re-exposes any residual
#                gc.routed_to (Vector 1c)
# Each re-match spins up a no-op dog that verifies-and-exits — pure session burn
# (ga-noxbv was re-dispatched 15x mid-gate; see ga-e7zk7). The marker is still
# gate-status:claimed at this point (Step 6 has not flipped it yet), an active state
# the inflight-reclaim-guard already excludes, so detaching cannot trigger a false
# reclaim. Neutralize both vectors at the routing layer: clear the source bead's
# assignee (kills 1a) and strip gc.routed_to (kills 1c). The bead stays in_progress
# + story:in-flight; the gate closes it on PASS, or on FAIL the Pilot re-dispatches
# (re-assigning fresh). The marker's source-bead: label — not the bead's assignee —
# is what the gate and delivery use to find it, so detaching is safe. Best-effort,
# never fatal (set -euo pipefail discipline).
if [ -n "$BEAD_ID" ]; then
  if bd -C "$GC_CITY" assign "$BEAD_ID" "" 2>/dev/null; then
    log "  detached source bead $BEAD_ID from dog pool (cleared assignee — ga-e7zk7)"
  else
    log "  WARN: could not clear assignee on source bead $BEAD_ID (non-fatal — ga-e7zk7)"
  fi
  # Strip the metadata-keyed pool route (no-op in the current sling-bead model,
  # where the source bead carries no gc.routed_to; covers the legacy direct-route
  # model where it did). Guarded so a missing key never aborts the sweep.
  bd -C "$GC_CITY" update "$BEAD_ID" --unset-metadata gc.routed_to -q 2>/dev/null || true
fi

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

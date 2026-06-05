#!/usr/bin/env bash
# quality-gate-dispatcher.sh — Autonomous Quality Gate Dispatcher ("G").
#
# Runs every ~2 min via launchd (com.gascity.quality-gate-dispatcher.plist).
# Picks up gate-status:queued markers (set by quality-gate-guard.sh after it
# claims and validates the marker), then:
#
#   1. Determines tier (CODE → 3 independent sessions; NON-CODE → 1 session + tests).
#   2. Spawns N GENUINELY INDEPENDENT reviewer sessions via
#      "gc session new gastown.dog --no-attach".  NO shared context. Each
#      receives a unique targeted nudge describing exactly its review task.
#   3. Polls verdict beads until all reviewers post PASS or FAIL (or timeout).
#   4. On ALL-PASS  → direct-merge to production main + close source bead.
#      On ANY-FAIL  → set gate-status:failed, post blocking reasons, nudge author.
#   5. Appends one compact JSON line to .gc/quality-gate.jsonl.
#
# DESIGN INVARIANTS:
#   - Author-exclusion uses authoritative bead source (assignee/created_by).
#   - 3 separate dog sessions = 3 separate Claude Code processes. Not role-play.
#   - Verdict collection: each reviewer session closes its personal verdict bead
#     with a label "verdict:PASS" or "verdict:FAIL" and a comment with reason.
#   - DRY_RUN=1 → skips the actual git merge/push; logs "WOULD MERGE" instead.
#   - DRAIN-SAFE: this file + its plist are the ONLY artifacts. Does not touch
#     city.toml, pack.toml, or any crew skill files.
#
# Usage:
#   bash quality-gate-dispatcher.sh            # normal run
#   DRY_RUN=1 bash quality-gate-dispatcher.sh  # dry-run (proof mode)

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/quality-gate-dispatcher.log"
QG_LOG="$GC_CITY/.gc/quality-gate.jsonl"

# Maximum wall-clock minutes to wait for all reviewer verdicts before timing out.
VERDICT_TIMEOUT_MINUTES="${VERDICT_TIMEOUT_MINUTES:-45}"

# Safety floor: never allow a timeout shorter than 15 minutes regardless of env var.
# (Prevents accidental short timeouts from leftover test env vars causing false FAILs.)
if [ "$VERDICT_TIMEOUT_MINUTES" -lt 15 ] 2>/dev/null; then
  warn "VERDICT_TIMEOUT_MINUTES=${VERDICT_TIMEOUT_MINUTES} is dangerously short — overriding to 15m (floor)."
  VERDICT_TIMEOUT_MINUTES=15
fi

# Poll interval (seconds) when waiting for verdicts.
VERDICT_POLL_INTERVAL="${VERDICT_POLL_INTERVAL:-30}"

# Dry-run mode: skip actual git merge+push.
DRY_RUN="${DRY_RUN:-0}"

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [quality-gate-dispatcher] WARN: $*"; }

echo ""
log "=== Dispatcher sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Step 0a: TTL recovery — re-queue zombie dispatching markers ───────────────
# If a marker has been in gate-status:dispatching for > DISPATCHING_TTL_MINUTES,
# the dispatcher process was killed mid-run (after claiming but before completing).
# These would otherwise block forever because the dispatcher only processes
# gate-status:queued markers.  Reset them to queued so this sweep (or the next)
# can re-process them.
#
# TTL is 30m — same as the guard's claimed TTL.  Any legitimate dispatcher run
# that's been in flight for 30m has either spawned reviewers (verdict poll keeps
# the bead alive) or should be considered dead.
#
# Safety: we only recover markers that are STILL in dispatching — i.e. the
# dispatcher never finished (no passed/failed/error/needs-rebase was set).
DISPATCHING_TTL_MINUTES=30

DISPATCHING_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:dispatching \
  2>/dev/null || echo "[]")
DISPATCHING_COUNT=$(echo "$DISPATCHING_JSON" | jq 'length' 2>/dev/null || echo "0")

if [ "$DISPATCHING_COUNT" -gt 0 ]; then
  NOW_EPOCH_D=$(date +%s)
  for di in $(seq 0 $((DISPATCHING_COUNT - 1))); do
    D_MARKER=$(echo "$DISPATCHING_JSON" | jq ".[$di]")
    D_ID=$(echo "$D_MARKER" | jq -r '.id')
    D_UPDATED=$(echo "$D_MARKER" | jq -r '.updated_at // .created_at // ""')
    if [ -z "$D_UPDATED" ]; then continue; fi
    D_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${D_UPDATED%%Z*}" "+%s" 2>/dev/null \
      || date -d "$D_UPDATED" +%s 2>/dev/null || echo "0")
    D_AGE_MINUTES=$(( (NOW_EPOCH_D - D_EPOCH) / 60 ))
    if [ "$D_AGE_MINUTES" -gt "$DISPATCHING_TTL_MINUTES" ]; then
      warn "Re-queuing zombie dispatching marker $D_ID (age=${D_AGE_MINUTES}m > TTL=${DISPATCHING_TTL_MINUTES}m — dispatcher died mid-run)"
      bd -C "$GC_CITY" label remove "$D_ID" "gate-status:dispatching" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$D_ID" "gate-status:queued"      -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$D_ID" "Dispatcher TTL recovery: marker was stuck in gate-status:dispatching for ${D_AGE_MINUTES}m (> ${DISPATCHING_TTL_MINUTES}m TTL). Dispatcher process died mid-run. Re-queuing for re-processing." 2>/dev/null || true
    fi
  done
fi

# ── Step 0b: Find a queued marker ────────────────────────────────────────────
# quality-gate-guard.sh claims, validates, derives author, and parks markers as
# gate-status:queued.  We only process queued markers — the guard already did
# all the security work.

MARKERS_JSON=$(bd -C "$GC_CITY" list --json --all \
  -l type:quality-gate-marker \
  -l gate-status:queued \
  2>/dev/null || echo "[]")

COUNT=$(echo "$MARKERS_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT queued marker(s)"

if [ "$COUNT" = "0" ]; then
  log "No queued markers. Exiting."
  exit 0
fi

MARKER=$(echo "$MARKERS_JSON" | jq '.[0]')
MARKER_ID=$(echo "$MARKER" | jq -r '.id')
DESC=$(echo "$MARKER" | jq -r '.description // ""')

log "Attempting to claim marker $MARKER_ID ..."

# ── Step 1: Atomic claim — transition queued → dispatching ───────────────────
# Remove queued label first. If another dispatcher process beat us, the re-fetch
# will show the marker no longer in queued state.

bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:queued" -q 2>/dev/null || true

# Re-fetch to verify we won the race
VERIFY_JSON=$(bd -C "$GC_CITY" show "$MARKER_ID" --json 2>/dev/null || echo "[]")
VERIFY_LABELS=$(echo "$VERIFY_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")

if echo "$VERIFY_LABELS" | grep -q "gate-status:dispatching"; then
  log "Marker $MARKER_ID already dispatching by another process. Skipping."
  exit 0
fi
if echo "$VERIFY_LABELS" | grep -q "gate-status:queued"; then
  log "Marker $MARKER_ID still queued after removal (race condition). Skipping."
  exit 0
fi

# We own it — add dispatching label
bd -C "$GC_CITY" label add "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || {
  err "Failed to add gate-status:dispatching to $MARKER_ID. Aborting."
  exit 1
}

log "Marker $MARKER_ID claimed for dispatching."

# ── Step 2: Extract fields from marker description ────────────────────────────

extract() { echo "$DESC" | grep -E "^$1:" | head -1 | sed "s/^$1: *//"; }

BRANCH=$(extract "branch")
BEAD_ID=$(extract "bead_id")
BASE_COMMIT=$(extract "base_commit")
RIG=$(extract "rig")

log "  branch=$BRANCH  bead_id=$BEAD_ID  rig=${RIG:-unknown}"

# ── Step 3: Re-derive author authoritatively (never trust marker self-declaration)
#
# Resolution order (most-to-least authoritative):
#   1. Look up the bead via "gc bd show" (cross-rig lookup — works for any rig DB).
#   2. Try HQ DB directly as a fallback (in case gc bd fails).
#   3. If assignee is a session-id (contains "adhoc"), map it back to the base
#      crew role by stripping the adhoc suffix (e.g. "digo-adhoc-e2510107f6" → "digo").
#
# SECURITY: We do NOT trust the marker's self-declared author. The resolved value
# is used solely for self-review exclusion. A partial/approximate match is safe
# here: it only prevents a reviewer from reviewing their own work; it doesn't
# grant access.

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

if [ -n "$BEAD_ID" ]; then
  # 1. Cross-rig lookup via gc bd (authoritative — queries the owning rig's DB).
  #    This handles beads in rig DBs (e.g. wa-*, ps-*) that are NOT in the HQ DB.
  BEAD_RAW=$(gc --city "$GC_CITY" bd show "$BEAD_ID" --json 2>/dev/null || echo "")

  # If cross-rig lookup returned nothing, fall back to HQ DB
  if [ -z "$BEAD_RAW" ]; then
    log "  gc bd cross-rig lookup returned empty; trying HQ DB directly."
    BEAD_RAW=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null || echo "")
  fi

  # Extract fields using grep (robust to embedded-newline JSON from gc bd)
  AUTHOR=$(bead_field_grep "$BEAD_RAW" "assignee")
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "created_by")
  fi
  if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
    AUTHOR=$(bead_field_grep "$BEAD_RAW" "owner")
  fi
fi

# 3. Session-id normalization: if assignee looks like an adhoc session-id
#    (e.g. "digo-adhoc-e2510107f6"), strip the adhoc suffix to get the crew role.
#    We keep the FULL id as the exclusion target AND the normalized role — a
#    reviewer session matches if its alias contains either form.
if [ -n "$AUTHOR" ] && echo "$AUTHOR" | grep -qE "-adhoc-[0-9a-f]+" 2>/dev/null; then
  AUTHOR_BASE=$(echo "$AUTHOR" | sed 's/-adhoc-[0-9a-f]*$//')
  log "  Author '$AUTHOR' looks like a session-id; normalized to base role '$AUTHOR_BASE'."
  AUTHOR="$AUTHOR_BASE"
fi

if [ -z "$AUTHOR" ] || [ "$AUTHOR" = "null" ]; then
  err "Cannot derive author authoritatively for bead $BEAD_ID — aborting (fail-safe)."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:deferred"    -q 2>/dev/null || true
  # wa-uthi: non-terminal (deferred) — no push to Athos. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): author unresolvable for $MARKER_ID — deferred."
  exit 0
fi

log "Authoritative author: $AUTHOR"

# ── Step 4: Determine rig path and git references ─────────────────────────────

RIG_PATH=""
if [ -n "$RIG" ]; then
  RIG_PATH=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
    | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r) | .path' 2>/dev/null | head -1 || echo "")
fi

if [ -z "$RIG_PATH" ] || [ ! -d "$RIG_PATH" ]; then
  err "Cannot resolve rig path for rig='$RIG'. Aborting."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  exit 1
fi

# Determine the canonical git repo location.
# Container rigs (property_scrapers, lexbh) have a bare .repo.git.
# Self-repo rigs (gastown, whatsapp_automation, marketing) have .git in root.
if [ -d "$RIG_PATH/.repo.git" ]; then
  GIT_DIR_PATH="$RIG_PATH/.repo.git"
  IS_CONTAINER_RIG=1
else
  GIT_DIR_PATH="$RIG_PATH"
  IS_CONTAINER_RIG=0
fi

# git_rig — wrapper that calls git with the correct rig-specific flags.
# Usage: git_rig <args...>
git_rig() {
  if [ "$IS_CONTAINER_RIG" = "1" ]; then
    git --git-dir="$GIT_DIR_PATH" "$@"
  else
    git -C "$GIT_DIR_PATH" "$@"
  fi
}

log "  rig_path=$RIG_PATH  git_dir=$GIT_DIR_PATH  container_rig=$IS_CONTAINER_RIG"

# Determine default branch (main unless overridden)
DEFAULT_BRANCH=$(gc --city "$GC_CITY" rig list --json 2>/dev/null \
  | jq -r --arg r "$RIG" '.rigs[] | select(.name == $r) | .default_branch // "main"' 2>/dev/null | head -1 || echo "main")

# Fetch to ensure we have the latest remote state
log "Fetching remote for rig $RIG ..."
git_rig fetch origin 2>/dev/null || warn "git fetch failed (continuing with stale refs)"

# Verify branch exists on remote
BRANCH_SHA=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
if [ -z "$BRANCH_SHA" ]; then
  err "Branch '$BRANCH' not found on remote origin. Aborting."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
  # wa-uthi: non-terminal (marker error, fixable + resubmittable) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH not found on remote — gate-status:error."
  exit 1
fi

log "  branch_sha=$BRANCH_SHA"

# ── Step 4b: Already-merged detection ────────────────────────────────────────
# If the branch tip is already an ancestor of the rig's default branch, the
# work has already been merged.  Re-spawning reviewers on merged work wastes
# sessions and produces duplicate gate-failed/passed noise.
# DETECT: if merge-base --is-ancestor origin/$BRANCH origin/$DEFAULT_BRANCH → true
# → mark marker gate-status:done/superseded and exit cleanly.

ALREADY_MERGED=0
if git_rig merge-base --is-ancestor "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
  ALREADY_MERGED=1
fi

if [ "$ALREADY_MERGED" = "1" ]; then
  log "Branch $BRANCH is already merged into $DEFAULT_BRANCH — superseding marker $MARKER_ID."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching"  -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:superseded"   -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "Branch $BRANCH is already merged into $DEFAULT_BRANCH (SHA $BRANCH_SHA is ancestor of main). Gate skipped — no reviewers needed." 2>/dev/null || true

  # Also close the source bead cleanly if open
  if [ -n "$BEAD_ID" ]; then
    BD_STATUS=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
    if [ "$BD_STATUS" != "closed" ]; then
      bd -C "$GC_CITY" label add "$BEAD_ID" "gate:superseded" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Branch $BRANCH already in $DEFAULT_BRANCH — gate superseded (marker $MARKER_ID)." 2>/dev/null || true
    fi
  fi

  # Log and exit without error
  mkdir -p "$(dirname "$QG_LOG")"
  jq -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" \
    --arg bead "$BEAD_ID" \
    --arg rig "${RIG:-unknown}" \
    --arg marker "$MARKER_ID" \
    '{ts: $ts, event: "dispatcher_superseded", branch: $branch, bead: $bead, rig: $rig, marker: $marker, reason: "already_merged"}' \
    >> "$QG_LOG" 2>/dev/null || true

  # wa-uthi: non-terminal (marker superseded — no new outcome) — no push. Logged only.
  log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH already merged — gate marker superseded."
  log "=== Dispatcher sweep complete: branch=$BRANCH verdict=SUPERSEDED (already merged) ==="
  exit 0
fi

log "  Branch $BRANCH not yet merged into $DEFAULT_BRANCH — proceeding with review."

# ── Step 4c: Stale-base check (Bug 1a) ───────────────────────────────────────
# Require that the branch be CURRENT with main before review starts.
# A branch is current iff main HEAD is an ancestor of the branch tip — i.e.
# the branch was forked from (or rebased onto) the current main tip.
#
# If main has moved ahead of the branch base, a merge-tree pre-check can still
# silently resolve conflicts to main's side (as happened with wa-e99e / 52ba4c95).
# We refuse to proceed and bounce back to the author with gate-status:needs-rebase.

MAIN_HEAD_SHA=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
BRANCH_IS_CURRENT=0
if [ -n "$MAIN_HEAD_SHA" ]; then
  # main is an ancestor of branch iff the branch includes all of main
  if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
    BRANCH_IS_CURRENT=1
  fi
fi

if [ "$BRANCH_IS_CURRENT" != "1" ]; then
  # ── ga-we1: Auto-rebase (clean branches only) ─────────────────────────────
  # Instead of bouncing to the author, the dispatcher attempts a conflict-free
  # rebase directly.  This eliminates the starvation loop where a branch passes
  # the stale check, enters review, main moves again during review→merge, and
  # the whole cycle restarts.
  #
  # Strategy:
  #   1. Use `git merge-tree` to detect conflicts before touching anything.
  #   2. If conflict-free: create a temp worktree, rebase onto current main,
  #      push the rebased branch tip, update BRANCH_SHA, and continue.
  #   3. If conflicts: bounce to author with a targeted conflict report (not
  #      a generic "rebase and re-run" — we know exactly which files conflict).

  log "  Branch $BRANCH is STALE (main=$MAIN_HEAD_SHA not in branch=$BRANCH_SHA). Attempting auto-rebase ..."

  MERGE_BASE_SHA=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
  HAS_CONFLICT=0
  CONFLICT_FILES=""

  if [ -n "$MERGE_BASE_SHA" ]; then
    # merge-tree <base> <ours=main> <theirs=branch>
    # A conflict-free rebase is equivalent to a conflict-free three-way merge.
    MT_OUTPUT=$(git_rig merge-tree "$MERGE_BASE_SHA" "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null || echo "")
    if echo "$MT_OUTPUT" | grep -q "^<<<<<<<"; then
      HAS_CONFLICT=1
      CONFLICT_FILES=$(echo "$MT_OUTPUT" | grep -E "^(<<<|changed in both)" | head -5 | tr '\n' ' ' | cut -c1-300)
    fi
  else
    # No common ancestor — treat as conflict (unrelated histories)
    HAS_CONFLICT=1
    CONFLICT_FILES="no common ancestor with main"
  fi

  if [ "$HAS_CONFLICT" = "0" ]; then
    # Clean rebase: perform in a temp worktree, push to origin, continue with review.
    log "  Auto-rebase: no conflicts detected — rebasing $BRANCH onto $MAIN_HEAD_SHA ..."
    AUTO_REBASE_OK=0
    TMP_REBASE_WT="/tmp/gc-gate-autorebase-$$"

    if [ "$IS_CONTAINER_RIG" = "1" ]; then
      # Container rig (bare repo): worktree uses the bare .repo.git
      if git_rig worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        # Configure git user inside worktree for the rebase commit
        git -C "$TMP_REBASE_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
        git -C "$TMP_REBASE_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
        if git -C "$TMP_REBASE_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$NEW_TIP" ] && git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
            AUTO_REBASE_OK=1
            BRANCH_SHA="$NEW_TIP"
            log "  Auto-rebase success: $BRANCH pushed to $NEW_TIP (rebased onto $MAIN_HEAD_SHA)"
            bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
            # Re-verify stale check passes now
            git_rig fetch origin 2>/dev/null || true
            BRANCH_SHA=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "$BRANCH_SHA")
            if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
              BRANCH_IS_CURRENT=1
            else
              warn "  Post-auto-rebase stale check still fails — falling through to bounce."
              AUTO_REBASE_OK=0
            fi
          else
            warn "  Auto-rebase push failed for $BRANCH"
          fi
        else
          warn "  Auto-rebase git rebase command failed (unexpected — merge-tree reported no conflicts)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git_rig worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree at $TMP_REBASE_WT"
      fi
    else
      # Self-repo rig
      if git -C "$GIT_DIR_PATH" worktree add "$TMP_REBASE_WT" "origin/$BRANCH" 2>/dev/null; then
        git -C "$TMP_REBASE_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
        git -C "$TMP_REBASE_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
        if git -C "$TMP_REBASE_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
          NEW_TIP=$(git -C "$TMP_REBASE_WT" rev-parse HEAD 2>/dev/null || echo "")
          if [ -n "$NEW_TIP" ] && git -C "$TMP_REBASE_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
            AUTO_REBASE_OK=1
            BRANCH_SHA="$NEW_TIP"
            log "  Auto-rebase success (self-repo): $BRANCH pushed to $NEW_TIP"
            bd -C "$GC_CITY" comment "$MARKER_ID" "Gate dispatcher auto-rebased $BRANCH onto main ($MAIN_HEAD_SHA). New tip: $NEW_TIP. Proceeding with review." 2>/dev/null || true
            git_rig fetch origin 2>/dev/null || true
            BRANCH_SHA=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "$BRANCH_SHA")
            if git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null; then
              BRANCH_IS_CURRENT=1
            else
              warn "  Post-auto-rebase stale check still fails — falling through to bounce."
              AUTO_REBASE_OK=0
            fi
          else
            warn "  Auto-rebase push failed (self-repo) for $BRANCH"
          fi
        else
          warn "  Auto-rebase git rebase failed (self-repo)"
          git -C "$TMP_REBASE_WT" rebase --abort 2>/dev/null || true
        fi
        git -C "$GIT_DIR_PATH" worktree remove "$TMP_REBASE_WT" --force 2>/dev/null || true
      else
        warn "  Could not create auto-rebase worktree (self-repo) at $TMP_REBASE_WT"
      fi
    fi

    if [ "$AUTO_REBASE_OK" = "1" ] && [ "$BRANCH_IS_CURRENT" = "1" ]; then
      log "  Auto-rebase complete — branch is now current. Continuing with review."
      # Fall through to Step 5 with updated BRANCH_SHA
    else
      # Auto-rebase failed despite no conflicts (worktree/push failure)
      HAS_CONFLICT=1
      CONFLICT_FILES="auto-rebase failed (worktree/push error)"
    fi
  fi

  if [ "$BRANCH_IS_CURRENT" != "1" ]; then
    # Conflicts detected or auto-rebase failed — bounce to author
    warn "Branch $BRANCH: auto-rebase not possible (${CONFLICT_FILES:-conflicts}). Bouncing to author."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$MARKER_ID" "Gate BLOCKED: branch $BRANCH is stale and has conflicts that prevent auto-rebase.
main HEAD is $MAIN_HEAD_SHA. Conflicting regions: ${CONFLICT_FILES:-unknown}.
Action required: manually rebase $BRANCH onto current origin/$DEFAULT_BRANCH, resolve conflicts, and re-run /gate-done." 2>/dev/null || true

    if [ -n "$BEAD_ID" ]; then
      bd -C "$GC_CITY" label add  "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Quality gate blocked: branch $BRANCH has conflicts with current main ($MAIN_HEAD_SHA). Auto-rebase attempted but failed (${CONFLICT_FILES:-conflicts}). Manual rebase required — re-run /gate-done after resolving." 2>/dev/null || true
    fi

    if [ -n "$AUTHOR" ]; then
      gc --city "$GC_CITY" session nudge "$AUTHOR" \
        "GATE BLOCKED for branch $BRANCH: stale with conflicts — auto-rebase failed. Conflicts: ${CONFLICT_FILES:-unknown}. Manually rebase onto origin/$DEFAULT_BRANCH (main HEAD: $MAIN_HEAD_SHA), resolve conflicts, re-run /gate-done. Bead: $BEAD_ID" \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR for rebase"
    fi

    # wa-uthi: non-terminal (bounced to author for rebase, retryable) — no push to
    # Athos. The author is nudged above; Athos only hears about terminal outcomes.
    log "SUPPRESSED PUSH (wa-uthi non-terminal): branch $BRANCH needs manual rebase — bounced to $AUTHOR."

    mkdir -p "$(dirname "$QG_LOG")"
    jq -c -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg branch "$BRANCH" \
      --arg bead "$BEAD_ID" \
      --arg rig "${RIG:-unknown}" \
      --arg marker "$MARKER_ID" \
      --arg author "$AUTHOR" \
      --arg main_sha "$MAIN_HEAD_SHA" \
      --arg conflicts "${CONFLICT_FILES:-unknown}" \
      '{ts: $ts, event: "dispatcher_needs_rebase", branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, main_sha: $main_sha, conflicts: $conflicts}' \
      >> "$QG_LOG" 2>/dev/null || true

    log "=== Dispatcher sweep complete: branch=$BRANCH verdict=NEEDS_REBASE (conflicts, auto-rebase failed) ==="
    exit 0
  fi
fi

log "  Branch $BRANCH is current with $DEFAULT_BRANCH — stale-base check passed."

# ── Step 5: Code-vs-non-code tier classification ──────────────────────────────
#
# NON-CODE: ALL changed files are ONLY in docs/, tests/ (test_*.py, *_test.py,
# *_test.go, *.test.*, spec files), or pure data-config (*.json, *.yaml, *.toml,
# *.md, *.csv, *.txt under docs/ or data/).
#
# CODE: ANY file outside the above set → CODE tier.
#
# When classifier is uncertain or the gate policy itself is modified → CODE tier.
# This is the "escalate up, never down" rule from review-merge-policy.md.

CHANGED_FILES=$(git_rig diff --name-only "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null || echo "")

TIER="CODE"
if [ -n "$CHANGED_FILES" ]; then
  NON_CODE_PATTERN='^(docs/|tests?/|test_|.*_test\.(py|go|js|ts)|.*\.test\.(js|ts|jsx|tsx)|.*\.spec\.(js|ts)|.*\.(md|txt|csv)$|\.github/)'
  ANY_CODE=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if ! echo "$f" | grep -qE "$NON_CODE_PATTERN"; then
      ANY_CODE=1
      break
    fi
  done <<< "$CHANGED_FILES"
  if [ "$ANY_CODE" = "0" ]; then
    TIER="NON-CODE"
  fi
fi

# Policy self-protection: if the gate policy or classifier is being modified,
# escalate to CODE tier regardless.
POLICY_FILES=$(echo "$CHANGED_FILES" | grep -E "(review-merge-policy|quality-gate)" || echo "")
if [ -n "$POLICY_FILES" ]; then
  TIER="CODE"
  warn "Gate policy file in diff — escalating to CODE tier (self-protection)."
fi

case "$TIER" in
  CODE)     REQUIRED_REVIEWERS=3 ;;
  NON-CODE) REQUIRED_REVIEWERS=1 ;;
  *)        REQUIRED_REVIEWERS=3 ;;
esac

log "Tier: $TIER  required_reviewers: $REQUIRED_REVIEWERS"

# ── Step 6: Create gate-run tracking bead ────────────────────────────────────

NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
GATE_START_EPOCH=$(date +%s)

GATE_RUN_ID=$(bd -C "$GC_CITY" create \
  "gate-run: $BRANCH ($BEAD_ID)" \
  -t chore --ephemeral \
  -l type:quality-gate-run \
  -l gate-status:running \
  -l "source-bead:$BEAD_ID" \
  -d "Autonomous gate run for $BRANCH.
source_bead: $BEAD_ID
author: $AUTHOR
rig: $RIG
tier: $TIER
required_reviewers: $REQUIRED_REVIEWERS
branch_sha: $BRANCH_SHA
marker_id: $MARKER_ID
started_at: $NOW" \
  --json 2>/dev/null | jq -r '.id // empty')

if [ -z "$GATE_RUN_ID" ]; then
  warn "Could not create gate-run tracking bead. Continuing without it."
  GATE_RUN_ID="unknown"
fi
log "Gate-run bead: $GATE_RUN_ID"

# ── Step 7: Create verdict beads (one per reviewer) ───────────────────────────
# Each reviewer session writes its verdict to its personal verdict bead:
#   - Closes bead with label "verdict:PASS" or "verdict:FAIL"
#   - Posts a comment with the reasons (required for FAIL)
#
# The dispatcher polls these beads for closed status + verdict label.

DIFF_SUMMARY=$(git_rig diff --stat "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-300 || true)
# Note: "|| true" suppresses SIGPIPE (exit 141) from `head` truncating a large diff under pipefail.
# Without it, the git diff process is killed by SIGPIPE when head exits, causing the script to abort.
DIFF_FULL=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | head -2000 || true)

VERDICT_BEAD_IDS=()
SESSION_IDS=()

log "Spawning $REQUIRED_REVIEWERS independent reviewer session(s) ..."

for i in $(seq 1 $REQUIRED_REVIEWERS); do
  REVIEWER_LENS=""
  case "$i" in
    1) REVIEWER_LENS="CORRECTNESS: focus on logic errors, edge cases, off-by-one bugs, null/empty handling, error propagation, and incorrect assumptions. Be adversarial." ;;
    2) REVIEWER_LENS="SECURITY & ROBUSTNESS: focus on injection risks, unsafe eval/exec, credentials in code, path traversal, race conditions, resource leaks, and missing input validation." ;;
    3) REVIEWER_LENS="DESIGN & MAINTAINABILITY: focus on architectural concerns, code duplication, missing tests, test quality, unclear naming, violation of existing conventions, and tech debt introduced." ;;
  esac

  # Create a verdict bead for this reviewer
  VERDICT_BEAD_ID=$(bd -C "$GC_CITY" create \
    "reviewer-verdict: $BRANCH (reviewer $i/$REQUIRED_REVIEWERS)" \
    -t chore --ephemeral \
    -l type:quality-gate-verdict \
    -l "gate-run:$GATE_RUN_ID" \
    -l "reviewer-index:$i" \
    -l verdict:pending \
    -d "Verdict bead for reviewer $i of $REQUIRED_REVIEWERS on branch $BRANCH.
gate_run: $GATE_RUN_ID
branch: $BRANCH
author: $AUTHOR
lens: $REVIEWER_LENS
This bead ID will be delivered to the reviewer session via nudge with exact commands." \
    --json 2>/dev/null | jq -r '.id // empty')

  if [ -z "$VERDICT_BEAD_ID" ]; then
    err "Failed to create verdict bead for reviewer $i. Aborting gate."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    exit 1
  fi

  VERDICT_BEAD_IDS+=("$VERDICT_BEAD_ID")
  log "  Verdict bead $i: $VERDICT_BEAD_ID"

  # Build the review task message for the session nudge.
  # Each session gets: (a) the diff, (b) its specific lens, (c) exact bd commands to record verdict.
  REVIEW_TASK=$(cat <<TASK
QUALITY GATE REVIEW — You are reviewer $i of $REQUIRED_REVIEWERS for branch: $BRANCH
Author (EXCLUDED from reviewing): $AUTHOR
Rig: $RIG
Branch SHA: $BRANCH_SHA

YOUR REVIEW LENS: $REVIEWER_LENS

CHANGED FILES:
$CHANGED_FILES

DIFF SUMMARY:
$DIFF_SUMMARY

FULL DIFF (first 2000 lines):
$DIFF_FULL

--- YOUR TASK ---
Review this diff adversarially using ONLY your assigned lens above.
You must NOT know or consider what the other reviewers think (you are independent).
This author ($AUTHOR) cannot be a reviewer of their own work.

After completing your review, record your verdict with EXACTLY these bash commands:

bd -C "$GC_CITY" label remove "$VERDICT_BEAD_ID" "verdict:pending"
# If PASS:
bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:PASS"
bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: PASS
Summary: <2-3 sentence summary of what you checked and why it passes your lens>"
bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

# If FAIL:
# bd -C "$GC_CITY" label add "$VERDICT_BEAD_ID" "verdict:FAIL"
# bd -C "$GC_CITY" comment "$VERDICT_BEAD_ID" "VERDICT: FAIL
# Blocking issue 1: <description>
# Blocking issue 2: <description> (if any)"
# bd -C "$GC_CITY" close "$VERDICT_BEAD_ID"

Run those commands and then exit your session. Do not start other work.
TASK
)

  # Spawn an independent dog session (no attach, fresh wake mode)
  SESSION_JSON=$(gc --city "$GC_CITY" session new gastown.dog \
    --no-attach \
    --title "gate-reviewer-$i: $BRANCH" \
    --json 2>/dev/null || echo "{}")

  SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

  if [ -z "$SESSION_ID" ]; then
    err "Failed to spawn reviewer session $i. Aborting gate."
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:error"       -q 2>/dev/null || true
    exit 1
  fi

  SESSION_IDS+=("$SESSION_ID")
  log "  Reviewer session $i spawned: session_id=$SESSION_ID verdict_bead=$VERDICT_BEAD_ID"

  # Wake the session so it starts immediately
  gc --city "$GC_CITY" session wake "$SESSION_ID" 2>/dev/null || true

  # Deliver the review task via nudge (immediate delivery so it runs on startup)
  # Small sleep to let session initialize before nudge
  sleep 3
  gc --city "$GC_CITY" session nudge "$SESSION_ID" "$REVIEW_TASK" --delivery immediate 2>/dev/null || \
    gc --city "$GC_CITY" session submit "$SESSION_ID" "$REVIEW_TASK" 2>/dev/null || \
    warn "Could not deliver review task to session $SESSION_ID via nudge/submit"

  log "  Review task delivered to session $SESSION_ID (reviewer $i)"
done

log "All $REQUIRED_REVIEWERS reviewer sessions spawned: ${SESSION_IDS[*]}"
log "Waiting for verdicts (timeout=${VERDICT_TIMEOUT_MINUTES}m, poll=${VERDICT_POLL_INTERVAL}s) ..."

# ── Step 8: Poll for verdicts ─────────────────────────────────────────────────

VERDICT_TIMEOUT_SECS=$((VERDICT_TIMEOUT_MINUTES * 60))
WAIT_START=$(date +%s)
ALL_VERDICTS_IN=0
OVERALL_VERDICT="PASS"
FAIL_REASONS=""

while true; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$((NOW_EPOCH - WAIT_START))

  if [ "$ELAPSED" -gt "$VERDICT_TIMEOUT_SECS" ]; then
    warn "Verdict timeout after ${ELAPSED}s (limit=${VERDICT_TIMEOUT_SECS}s). Treating as FAIL."
    OVERALL_VERDICT="FAIL"
    FAIL_REASONS="TIMEOUT: reviewers did not submit verdicts within ${VERDICT_TIMEOUT_MINUTES} minutes."
    # Close any remaining pending verdict beads as timed-out
    for VB in "${VERDICT_BEAD_IDS[@]}"; do
      VB_STATUS=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
      if [ "$VB_STATUS" != "closed" ]; then
        bd -C "$GC_CITY" label remove "$VB" "verdict:pending" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$VB" "verdict:TIMEOUT" -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$VB" "VERDICT: TIMEOUT — reviewer session did not complete within ${VERDICT_TIMEOUT_MINUTES}m" 2>/dev/null || true
        bd -C "$GC_CITY" close "$VB" 2>/dev/null || true
      fi
    done
    break
  fi

  VERDICTS_RECEIVED=0
  ANY_FAIL=0

  for j in "${!VERDICT_BEAD_IDS[@]}"; do
    VB="${VERDICT_BEAD_IDS[$j]}"
    VB_JSON=$(bd -C "$GC_CITY" show "$VB" --json 2>/dev/null || echo "[]")
    VB_STATUS=$(echo "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | .status // "open"')
    VB_LABELS=$(echo "$VB_JSON" | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")')

    if [ "$VB_STATUS" = "closed" ]; then
      VERDICTS_RECEIVED=$((VERDICTS_RECEIVED + 1))
      if echo "$VB_LABELS" | grep -q "verdict:PASS"; then
        : # explicit PASS — continue
      elif echo "$VB_LABELS" | grep -q "verdict:FAIL"; then
        ANY_FAIL=1
        # Collect the fail reason from the reviewer's verdict comment.
        # NOTE (ga-kf0v): the beads "bd comments --json" schema uses .text
        # (keys: author, created_at, id, issue_id, text) — there is NO .body
        # field. The old accessor read .[0].body, so jq always fell through to
        # the "No reason provided" default and EVERY genuine reviewer FAIL lost
        # its reason. Parse .text (with .body kept as a defensive fallback for
        # any future schema drift), preferring the comment that starts with
        # "VERDICT:" (the reviewer convention), else the first non-empty one.
        VB_COMMENTS_JSON=$(bd -C "$GC_CITY" comments "$VB" --json 2>/dev/null || echo "[]")
        FAIL_COMMENT=$(printf '%s' "$VB_COMMENTS_JSON" | jq -r '
            [ .[]? | (.text // .body // "") ]
            | ( map(select(test("^\\s*VERDICT:"; "i"))) | last )
              // ( map(select(. != "")) | first )
              // ""
          ' 2>/dev/null || echo "")
        # FORENSICS (ga-kf0v #3): always log the raw comments + verdict labels
        # for a FAIL so any future schema/field drift is visible in the
        # dispatcher log without re-deriving from beads.
        log "  FAIL forensics reviewer $((j+1)) bead=$VB labels=[$VB_LABELS] raw_comments=$(printf '%s' "$VB_COMMENTS_JSON" | jq -c . 2>/dev/null | cut -c1-2000)"
        if [ -z "$FAIL_COMMENT" ]; then
          # Reviewer closed verdict:FAIL but left no parseable reason. Now rare
          # (the .text fix above resolves the common case). Fail-safe: PASS is
          # the only acceptable verdict, so an empty-reason FAIL still blocks
          # the merge — but mark it INCONCLUSIVE and warn loudly so it is
          # distinguishable from a substantive FAIL. (Full per-reviewer session
          # re-run retry per ga-kf0v #2 is deliberately deferred: re-dispatching
          # a reviewer mid-collection is higher-risk than this lane:small fix
          # warrants; making the empty case visible addresses the intent without
          # destabilising the gate's verdict-collection loop.)
          warn "Reviewer $((j+1)) (bead $VB) closed verdict:FAIL with no parseable reason — counting as INCONCLUSIVE FAIL (fail-safe)."
          FAIL_COMMENT="INCONCLUSIVE — verdict:FAIL with empty/unparseable reason (raw bead $VB; see forensics log above)"
        fi
        FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) FAIL: $FAIL_COMMENT\n"
      else
        # Any other label (TIMEOUT, ABORTED, or missing verdict label) → FAIL.
        # PASS is the ONLY acceptable verdict; anything else blocks the merge.
        ANY_FAIL=1
        VERDICT_LABEL=$(echo "$VB_LABELS" | tr ' ' '\n' | grep "^verdict:" | head -1 || echo "no-verdict-label")
        FAIL_REASONS="${FAIL_REASONS}Reviewer $((j+1)) ${VERDICT_LABEL}: verdict bead closed without explicit PASS.\n"
      fi
    fi
  done

  log "  Verdicts: $VERDICTS_RECEIVED/$REQUIRED_REVIEWERS received (elapsed: ${ELAPSED}s)"

  if [ "$VERDICTS_RECEIVED" -eq "$REQUIRED_REVIEWERS" ]; then
    ALL_VERDICTS_IN=1
    if [ "$ANY_FAIL" = "1" ]; then
      OVERALL_VERDICT="FAIL"
    fi
    break
  fi

  sleep "$VERDICT_POLL_INTERVAL"
done

log "Verdict collection complete: OVERALL=$OVERALL_VERDICT"

# ── Step 9: Close reviewer sessions ──────────────────────────────────────────
for SID in "${SESSION_IDS[@]}"; do
  gc --city "$GC_CITY" session close "$SID" 2>/dev/null || true
done
log "Reviewer sessions closed."

# ── Step 10: Act on verdict ───────────────────────────────────────────────────

GATE_END_EPOCH=$(date +%s)
ELAPSED_S=$((GATE_END_EPOCH - GATE_START_EPOCH))

if [ "$OVERALL_VERDICT" = "PASS" ]; then
  log "ALL PASS — proceeding to merge branch $BRANCH → $DEFAULT_BRANCH ..."

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD MERGE: git_rig push origin <branch_sha>:refs/heads/$DEFAULT_BRANCH (FF merge of $BRANCH)"
    log "DRY_RUN=1 — WOULD CLOSE source bead $BEAD_ID"
    MERGE_SHA="DRY_RUN_NO_MERGE"
    MERGE_RESULT="dry_run"
  else
    # ── Container-rig direct merge ──────────────────────────────────────────
    # For container rigs (bare .repo.git):
    #   1. Rebase the branch onto origin/main (ensures clean FF merge)
    #   2. Fast-forward main to the branch tip
    #   3. Push main to origin
    #
    # For self-repo rigs (normal .git directory):
    #   Use standard git commands via -C <rig_path>
    #
    # SECURITY NOTE: We do NOT use `git push --force`. This is a FF merge only.
    # If FF fails (diverged history), we abort and report failure.

    MERGE_SHA=""
    MERGE_RESULT="failed"

    # ── ga-3b8: Merge-time rebase+retry (starvation fix) ──────────────────────
    # The review→merge window is the starvation attack surface: another rig merge
    # can land between "reviewers PASS" and "push main".  We handle this by
    # re-fetching at merge time and, if main moved, auto-rebasing the branch
    # (conflict-free only) before the FF push.  If the FF push races again, we
    # retry the whole rebase→push sequence up to MAX_MERGE_RETRIES times.
    # Each attempt is fast (seconds), so 3 retries closes the window even on a
    # very busy rig.
    MAX_MERGE_RETRIES=3
    MERGE_ATTEMPT=0

    do_merge_ff() {
      # Arguments: IS_CONTAINER_RIG, BRANCH, DEFAULT_BRANCH — all from outer scope.
      # Returns: sets MERGE_SHA and MERGE_RESULT in outer scope.
      # Strategy per attempt:
      #   1. git fetch (get current remote state)
      #   2. If main moved (branch no longer FF-able): auto-rebase if clean
      #   3. FF push branch SHA to main
      #   4. Verify landing

      git_rig fetch origin 2>/dev/null || warn "Pre-merge fetch failed (attempt $((MERGE_ATTEMPT+1)))"
      local CUR_MAIN
      CUR_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
      local CUR_BRANCH
      CUR_BRANCH=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "")

      if [ -z "$CUR_MAIN" ] || [ -z "$CUR_BRANCH" ]; then
        MERGE_RESULT="failed_sha_resolution"
        return 1
      fi

      local IS_ANC
      IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

      if [ "$IS_ANC" != "yes" ]; then
        # Main moved during review — attempt inline rebase before push
        log "  Merge-time rebase: main moved to $CUR_MAIN after review; rebasing $BRANCH ..."
        local TMP_MR_WT="/tmp/gc-gate-mr-retry-$$-${MERGE_ATTEMPT}"
        local MR_OK=0

        # Conflict pre-check
        local MR_BASE
        MR_BASE=$(git_rig merge-base "origin/$BRANCH" "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
        local MR_CONFLICT=0
        if [ -n "$MR_BASE" ]; then
          local MR_MT
          MR_MT=$(git_rig merge-tree "$MR_BASE" "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null || echo "")
          echo "$MR_MT" | grep -q "^<<<<<<" && MR_CONFLICT=1
        else
          MR_CONFLICT=1
        fi

        if [ "$MR_CONFLICT" = "1" ]; then
          err "  Merge-time rebase: conflicts detected — cannot auto-rebase (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_conflict"
          return 1
        fi

        if [ "$IS_CONTAINER_RIG" = "1" ]; then
          if git_rig worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            git -C "$TMP_MR_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
            git -C "$TMP_MR_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
            if git -C "$TMP_MR_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR
              NEW_TIP_MR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase: pushed $BRANCH → $NEW_TIP_MR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git_rig worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        else
          if git -C "$GIT_DIR_PATH" worktree add "$TMP_MR_WT" "origin/$BRANCH" 2>/dev/null; then
            git -C "$TMP_MR_WT" config user.email "gate-dispatcher@gascity.local" 2>/dev/null || true
            git -C "$TMP_MR_WT" config user.name "Gate Dispatcher" 2>/dev/null || true
            if git -C "$TMP_MR_WT" rebase "origin/$DEFAULT_BRANCH" 2>/dev/null; then
              local NEW_TIP_MR_SR
              NEW_TIP_MR_SR=$(git -C "$TMP_MR_WT" rev-parse HEAD 2>/dev/null || echo "")
              if [ -n "$NEW_TIP_MR_SR" ] && git -C "$TMP_MR_WT" push origin "HEAD:refs/heads/$BRANCH" --force-with-lease 2>/dev/null; then
                MR_OK=1
                log "  Merge-time rebase (self-repo): pushed $BRANCH → $NEW_TIP_MR_SR"
              else
                git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
              fi
            else
              git -C "$TMP_MR_WT" rebase --abort 2>/dev/null || true
            fi
            git -C "$GIT_DIR_PATH" worktree remove "$TMP_MR_WT" --force 2>/dev/null || true
          fi
        fi

        if [ "$MR_OK" != "1" ]; then
          err "  Merge-time rebase: worktree/push failed (attempt $((MERGE_ATTEMPT+1)))"
          MERGE_RESULT="failed_merge_time_rebase"
          return 1
        fi

        # Re-fetch after rebase push
        git_rig fetch origin 2>/dev/null || true
        CUR_BRANCH=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "")
        CUR_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
        IS_ANC=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

        if [ "$IS_ANC" != "yes" ]; then
          err "  Merge-time rebase: branch still not FF-able after rebase (main moved again?)"
          MERGE_RESULT="failed_still_not_ff_after_rebase"
          return 1
        fi
      fi

      # FF push
      if git_rig push origin "${CUR_BRANCH}:refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
        git_rig fetch origin 2>/dev/null || warn "Post-FF-push fetch failed"
        local POST_MAIN
        POST_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
        if [ -n "$POST_MAIN" ] && git_rig merge-base --is-ancestor "$CUR_BRANCH" "$POST_MAIN" 2>/dev/null; then
          MERGE_SHA="$CUR_BRANCH"
          MERGE_RESULT="direct_ff"
          log "FF merge + landing verified (attempt $((MERGE_ATTEMPT+1))): $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA, main=$POST_MAIN)"
          return 0
        else
          err "Landing verification FAILED (attempt $((MERGE_ATTEMPT+1))): $CUR_BRANCH not in $DEFAULT_BRANCH ($POST_MAIN)"
          MERGE_RESULT="failed_landing_not_verified"
          return 1
        fi
      else
        # FF push rejected: main moved between our rebase and push (race)
        warn "  FF push rejected (attempt $((MERGE_ATTEMPT+1))) — main moved during push; will retry"
        MERGE_RESULT="failed_push_race"
        return 1
      fi
    }

    while [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; do
      MERGE_ATTEMPT=$((MERGE_ATTEMPT + 1))
      log "Merge attempt $MERGE_ATTEMPT/$MAX_MERGE_RETRIES ..."
      if do_merge_ff; then
        break
      fi
      # Only retry on push-race or stale-after-rebase; give up on conflict/worktree failure
      if [ "$MERGE_RESULT" = "failed_merge_time_conflict" ] || \
         [ "$MERGE_RESULT" = "failed_merge_time_rebase" ] || \
         [ "$MERGE_RESULT" = "failed_sha_resolution" ]; then
        log "  Non-retryable failure ($MERGE_RESULT). Stopping retry loop."
        break
      fi
      if [ "$MERGE_ATTEMPT" -lt "$MAX_MERGE_RETRIES" ]; then
        log "  Retrying in 2s ..."
        sleep 2
      fi
    done

    if [[ "$MERGE_RESULT" = failed* ]]; then
      # Merge failed despite all-PASS verdict — degrade to FAIL
      OVERALL_VERDICT="FAIL"
      FAIL_REASONS="Merge failed after all-PASS verdict. Merge result: $MERGE_RESULT. Check git state of rig $RIG."
      warn "All-PASS verdict but merge failed ($MERGE_RESULT). Setting gate to failed."
    fi

    # ── Bug 1b: Post-merge diff-integrity verification (belt-and-suspenders) ──
    # After a successful merge, verify the branch's changes are actually present
    # in the merged main. This catches silent conflict resolutions where git
    # resolved to main's side (dropping the fix entirely — as seen in wa-e99e).
    #
    # Strategy: fetch updated remote refs, then verify each file changed by the
    # branch still has a non-empty diff vs what was in main BEFORE the merge.
    # If any changed file regressed back to its pre-branch state, the merge
    # silently dropped changes — revert and bounce to author.
    if [[ ! "$MERGE_RESULT" = failed* ]] && [ "$MERGE_RESULT" != "dry_run" ]; then
      log "Post-merge diff-integrity check (Bug 1b belt-and-suspenders) ..."
      git_rig fetch origin 2>/dev/null || warn "Post-merge fetch failed; integrity check may use stale refs"

      MERGED_HEAD=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
      INTEGRITY_FAIL=0
      INTEGRITY_MSG=""

      if [ -n "$MERGED_HEAD" ] && [ -n "$BRANCH_SHA" ]; then
        # For each file changed by the branch, compute:
        #   diff_in_branch   = lines added/removed by branch vs its base (pre-branch main)
        #   diff_in_merged   = what actually changed in merged main vs the original pre-merge main SHA
        # If a file was changed by the branch but shows ZERO net change in the
        # merged result vs pre-merge main, the fix was dropped.
        PRE_MERGE_MAIN="${MAIN_HEAD_SHA}"
        BRANCH_CHANGED_FILES=$(git_rig diff --name-only "${PRE_MERGE_MAIN}...origin/$BRANCH" 2>/dev/null || echo "")

        if [ -n "$BRANCH_CHANGED_FILES" ] && [ -n "$PRE_MERGE_MAIN" ]; then
          while IFS= read -r f; do
            [ -z "$f" ] && continue
            # Lines the branch added in this file (vs pre-merge main)
            BRANCH_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "origin/$BRANCH" -- "$f" 2>/dev/null | grep -c "^+" || echo "0")
            # Lines that actually made it into merged main (vs pre-merge main)
            MERGED_ADDITIONS=$(git_rig diff "$PRE_MERGE_MAIN" "$MERGED_HEAD" -- "$f" 2>/dev/null | grep -c "^+" || echo "0")

            # If branch added lines to a file but the merged result has ZERO
            # additions relative to pre-merge main, the file was completely dropped.
            if [ "$BRANCH_ADDITIONS" -gt 0 ] && [ "$MERGED_ADDITIONS" = "0" ]; then
              INTEGRITY_FAIL=1
              INTEGRITY_MSG="${INTEGRITY_MSG}File $f: branch had $BRANCH_ADDITIONS additions but merged main has 0 (DROPPED).\n"
              log "  INTEGRITY FAIL: $f — branch additions not in merged main"
            fi
          done <<< "$BRANCH_CHANGED_FILES"
        fi
      fi

      if [ "$INTEGRITY_FAIL" = "1" ]; then
        warn "Post-merge integrity FAILED — merge silently dropped branch changes. Reverting."
        # Revert the merge by resetting main back to pre-merge SHA
        REVERT_OK=0
        if [ -n "$MAIN_HEAD_SHA" ] && [ -n "$MERGED_HEAD" ] && [ "$MAIN_HEAD_SHA" != "$MERGED_HEAD" ]; then
          if git_rig push origin "${MAIN_HEAD_SHA}:refs/heads/$DEFAULT_BRANCH" --force-with-lease 2>/dev/null; then
            REVERT_OK=1
            log "  Main reverted to pre-merge SHA $MAIN_HEAD_SHA (merge SHA $MERGED_HEAD removed)"
          else
            err "  Revert push failed. Main may be in corrupted state. Manual intervention required."
          fi
        fi

        OVERALL_VERDICT="FAIL"
        REVERT_STATUS=$([ "$REVERT_OK" = "1" ] && echo "REVERTED (main restored to $MAIN_HEAD_SHA)" || echo "REVERT FAILED — manual fix required")
        FAIL_REASONS="Post-merge integrity check failed: merge silently dropped branch changes.
Files with dropped changes:
$(echo -e "$INTEGRITY_MSG")
Revert status: $REVERT_STATUS
Author must inspect conflict resolution and rebase + resubmit."

        # Comment on the source bead explaining what happened
        if [ -n "$BEAD_ID" ]; then
          bd -C "$GC_CITY" label add "$BEAD_ID" "gate:integrity-fail" -q 2>/dev/null || true
          bd -C "$GC_CITY" comment "$BEAD_ID" "GATE INTEGRITY FAIL: the merge of branch $BRANCH silently dropped your changes (conflict resolved to main's side).
$(echo -e "$INTEGRITY_MSG")
Revert: $REVERT_STATUS
Action required: rebase $BRANCH onto current main, resolve conflicts explicitly, and re-submit via /gate-done." 2>/dev/null || true
        fi

        # wa-uthi: TERMINAL FAIL (merge reverted, definitive) — this push is KEPT.
        notify -t "Quality Gate INTEGRITY FAIL" -p 4 "Branch $BRANCH merge dropped changes — reverted. Author: $AUTHOR" 2>/dev/null || true
        log "Post-merge integrity FAILED: $INTEGRITY_MSG — merge reverted ($REVERT_STATUS)"
      else
        log "Post-merge integrity check PASSED — branch changes present in merged main."
      fi
    fi
  fi

  if [ "$OVERALL_VERDICT" = "PASS" ]; then
    # Update markers and beads for success
    bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:passed"      -q 2>/dev/null || true

    if [ "$GATE_RUN_ID" != "unknown" ]; then
      bd -C "$GC_CITY" label remove "$GATE_RUN_ID" "gate-status:running" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$GATE_RUN_ID" "gate-status:passed"  -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate PASSED. Branch $BRANCH merged to $DEFAULT_BRANCH. SHA=$MERGE_SHA. Tier=$TIER. Reviewers=$REQUIRED_REVIEWERS. Elapsed=${ELAPSED_S}s. mode=${MERGE_RESULT}." 2>/dev/null || true
    fi

    # ── ga-esbg: DRIVE THE SOURCE BEAD TO ITS TERMINAL/HANDOFF STATE ──────────
    # A gate PASS+merge MUST NOT leave the source bead in_progress with the live
    # builder still assigned. The legacy PASS path only added gate:passed + a
    # comment, so the bead stayed in_progress with a live assignee: the pool
    # crash-recovery selector (bd list --status in_progress --assignee <builder>)
    # kept RE-SPAWNING the worker, and the Pilot's Tier-1 selectors kept
    # re-picking open bugs/tech-debt — a wasteful re-spawn loop (wa-krzm).
    # Mirror the already-merged short-circuit: drive the bead all the way to its
    # terminal state — CLOSE bugs/tasks; HAND OFF stories to delivery.
    if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
      # gate:passed is BOTH the success label AND story-delivery's pickup signal
      # (story-delivery selects story:approved + gate:passed, excluding story:done).
      bd -C "$GC_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Quality gate PASSED. Branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA) via autonomous dispatcher (gate_run=$GATE_RUN_ID)." 2>/dev/null || true

      # Read the source bead state authoritatively (labels + live assignee).
      SRC_JSON=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq 'if type=="array" then .[0] else . end' 2>/dev/null || echo "")
      SRC_LABELS=$(printf '%s' "$SRC_JSON" | jq -r '(.labels // []) | join(" ")' 2>/dev/null || echo "")
      BUILDER_ASSIGNEE=$(printf '%s' "$SRC_JSON" | jq -r '.assignee // ""' 2>/dev/null || echo "")
      IS_STORY=0
      if printf '%s' "$SRC_LABELS" | grep -q "story:approved"; then IS_STORY=1; fi

      # (1) Clear the live builder assignee on EVERY source bead. This is what
      #     removes it from the pool in_progress crash-recovery selector
      #     (--assignee <builder>) and from the Pilot's assigned-bead exclusion,
      #     breaking the re-spawn loop even if the close/handoff below fails.
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        bd -C "$GC_CITY" assign "$BEAD_ID" "" 2>/dev/null \
          || warn "Could not clear builder assignee on source bead $BEAD_ID"
      fi

      # (2) Terminal vs handoff, decided by the canonical story marker
      #     (label story:approved — the type field is null for stories in bd;
      #     see story-delivery.sh / pilot-dispatcher.sh).
      if [ "$IS_STORY" = "1" ]; then
        # STORY → hand off to story-delivery (deploy + prod-test → story:done).
        # Leave it OPEN: delivery needs an open story:approved + gate:passed bead.
        # Pool re-spawn is already closed (assignee cleared above); the Pilot's
        # re-pick is excluded by story:in-flight. Do NOT close here.
        log "Source story $BEAD_ID handed off to delivery (gate:passed set; builder assignee cleared)."
        bd -C "$GC_CITY" comment "$BEAD_ID" "Gate PASS handoff (ga-esbg): builder assignee cleared; story:approved + gate:passed in place. story-delivery will deploy + prod-test, then mark story:done." 2>/dev/null || true
      else
        # BUG/TASK → close it. bd list defaults to OPEN-only, so closing removes
        # the bead from EVERY open-work selector (Pilot Tier-1 bug & tech-debt),
        # and — combined with the assignee clear — from the pool crash-recovery
        # query. Closing is the durable fix for non-story source beads.
        log "Closing source bug/task $BEAD_ID (gate PASS + merged sha=$MERGE_SHA)."
        bd -C "$GC_CITY" close "$BEAD_ID" \
          -r "Quality gate PASSED — branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA, gate_run=$GATE_RUN_ID). Closed by autonomous dispatcher (ga-esbg)." \
          2>/dev/null || warn "Could not close source bead $BEAD_ID"
      fi

      # (3) POST-MERGE VERIFICATION (ga-esbg): assert the source bead no longer
      #     appears in any re-spawn / re-pick selector the dispatcher knows about.
      #     If it does, a live loop vector remains — comment + escalate (never
      #     silently leave it).
      RESPAWN_HITS=""
      _still_listed() {  # 0 (true) iff $BEAD_ID is present in `bd list --json <args>`
        bd -C "$GC_CITY" list --json "$@" 2>/dev/null \
          | jq -e --arg id "$BEAD_ID" 'any(.[]?; .id == $id)' >/dev/null 2>&1
      }
      # a) Pool in_progress crash-recovery (applies to ALL beads — the core loop).
      if [ -n "$BUILDER_ASSIGNEE" ]; then
        if _still_listed --status in_progress --assignee "$BUILDER_ASSIGNEE"; then
          RESPAWN_HITS="$RESPAWN_HITS pool:in_progress+assignee=$BUILDER_ASSIGNEE"
        fi
      fi
      # b/c) Pilot Tier-1 open-bug / open-tech-debt re-pick. Stories are EXEMPT:
      #      they are intentionally left OPEN for delivery and may legitimately
      #      carry a tech-debt label; their pool re-spawn is closed by the
      #      assignee clear and their Pilot re-pick by story:in-flight.
      if [ "$IS_STORY" != "1" ]; then
        if _still_listed -t bug;        then RESPAWN_HITS="$RESPAWN_HITS pilot:open-bug"; fi
        if _still_listed -l tech-debt;  then RESPAWN_HITS="$RESPAWN_HITS pilot:open-tech-debt"; fi
      fi

      if [ -n "$RESPAWN_HITS" ]; then
        warn "POST-MERGE re-spawn vector STILL PRESENT for $BEAD_ID:$RESPAWN_HITS"
        bd -C "$GC_CITY" comment "$BEAD_ID" "WARNING (ga-esbg post-merge verify): source bead still appears in open-work selector(s) after gate PASS+merge:$RESPAWN_HITS. This is a re-spawn/re-pick vector — the terminal/handoff transition did not fully take." 2>/dev/null || true
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate post-merge: $BEAD_ID still re-pickable after PASS+merge" \
          -m "$(printf 'Source bead %s PASSED the quality gate and merged (branch %s, sha %s, gate_run %s) but still appears in open-work selector(s):%s\n\nThis leaves a re-spawn / re-pick vector (ga-esbg). The dispatcher could not drive it to terminal/handoff state — investigate (close failed? assignee clear failed? unexpected labels?).' \
            "$BEAD_ID" "$BRANCH" "$MERGE_SHA" "$GATE_RUN_ID" "$RESPAWN_HITS")" \
          2>/dev/null || warn "Could not mail Mayor post-merge re-spawn escalation for $BEAD_ID"
        notify -t "Gate post-merge vector" -p 3 "$BEAD_ID still re-pickable after PASS+merge:$RESPAWN_HITS" 2>/dev/null || true
      else
        log "Post-merge verify OK (ga-esbg): $BEAD_ID absent from all re-spawn/re-pick selectors."
      fi
    fi

    # wa-uthi: TERMINAL SUCCESS (merged to prod) — this push is KEPT.
    # wa-wzvg: differentiate the merge push for Pilot-origin stories. The Pilot
    # sets a durable "pilot:dispatched" label when it autonomously pulls a story
    # (see pilot-dispatcher.sh). If present, use a distinct prefix/emoji so Athos
    # can tell an autonomous Pilot merge apart from a human/Mayor-dispatched one.
    PILOT_ORIGIN=0
    if [ -n "$BEAD_ID" ]; then
      BEAD_LABELS_NOW=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
      if echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched"; then
        PILOT_ORIGIN=1
      fi
    fi
    if [ "$PILOT_ORIGIN" = "1" ]; then
      notify -t "🤖 Pilot Gate PASSED" -p 2 "🤖 [Pilot] Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s (autonomous pickup)" 2>/dev/null || true
      log "Gate PASSED (origin=Pilot): branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    else
      notify -t "Quality Gate PASSED" -p 2 "Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
      log "Gate PASSED: branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
    fi
  fi

else
  # ── FAIL path ─────────────────────────────────────────────────────────────
  log "Gate FAILED: $FAIL_REASONS"

  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:failed"      -q 2>/dev/null || true

  if [ "$GATE_RUN_ID" != "unknown" ]; then
    bd -C "$GC_CITY" label remove "$GATE_RUN_ID" "gate-status:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$GATE_RUN_ID" "gate-status:failed"  -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$GATE_RUN_ID" "Gate FAILED.
Branch: $BRANCH
Tier: $TIER  Reviewers required: $REQUIRED_REVIEWERS
Elapsed: ${ELAPSED_S}s

Blocking reasons:
$(echo -e "$FAIL_REASONS")" 2>/dev/null || true
  fi

  # Notify the author (not the Mayor) via nudge
  if [ -n "$AUTHOR" ]; then
    gc --city "$GC_CITY" session nudge "$AUTHOR" \
      "QUALITY GATE FAILED for branch $BRANCH. Blocking reasons: $(echo -e "$FAIL_REASONS" | head -3). Gate run: $GATE_RUN_ID. Fix the issues and re-run /gate-done when ready." \
      --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR (session may not exist)"
  fi

  # ── ga-jb4l: SELF-HEALING FAIL LOOP ────────────────────────────────────────
  # A gate FAIL must not strand the source story forever. The legacy FAIL path
  # only touched the EPHEMERAL marker/gate-run beads and an ephemeral author
  # session nudge — no durable feedback reached the SOURCE bead and no actor
  # ever re-picked it (the Pilot's selection hid it: features by story:in-flight,
  # bugs by a stale builder assignee). Here we close that loop:
  #   (a) attach the FAILing reviewer reasons to the SOURCE bead (durable),
  #   (b) transition it to a Pilot-re-dispatchable gate:needs-fix state, and
  #   (c) cap auto-retry at N=3, escalating to a human (Mayor) exactly once.
  # FAIL_REASONS is already populated upstream (and, post-ga-kf0v, carries the
  # real reviewer .text reasons), so the feedback we attach is substantive.
  if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
    GATE_FIX_CAP=3

    # Read the source bead's current labels (story beads live in the HQ/city DB).
    SRC_LABELS=$(bd -C "$GC_CITY" show "$BEAD_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(" ")' \
      2>/dev/null || echo "")

    # Current fix-attempt count from label gate:fix-attempt:N (default 0). Take
    # the MAX in case multiple counter labels ever coexist.
    PREV_ATTEMPT=$(printf '%s' "$SRC_LABELS" | tr ' ' '\n' \
      | sed -n 's/^gate:fix-attempt:\([0-9]\{1,\}\)$/\1/p' | sort -n | tail -1)
    [ -z "$PREV_ATTEMPT" ] && PREV_ATTEMPT=0

    # (a) ATTACH FEEDBACK TO THE SOURCE BEAD — durable, machine-readable marker
    #     (prefix "GATE-FEEDBACK") so the Pilot can surface it to the re-dispatched
    #     builder verbatim.
    bd -C "$GC_CITY" comment "$BEAD_ID" "$(printf 'GATE-FEEDBACK (gate_run=%s branch=%s): quality gate FAILED. Fix THESE specific blocking issues, then run /gate-done to re-gate.\n\n%s' \
      "$GATE_RUN_ID" "$BRANCH" "$(echo -e "$FAIL_REASONS")")" \
      2>/dev/null || warn "Could not attach gate feedback to source bead $BEAD_ID"
    bd -C "$GC_CITY" label add "$BEAD_ID" "gate:failed" -q 2>/dev/null || true

    if [ "$PREV_ATTEMPT" -ge "$GATE_FIX_CAP" ]; then
      # (c) RETRY CAP REACHED — stop auto-retry, escalate to the Mayor ONCE.
      log "Gate fix-attempt cap reached for $BEAD_ID (prev=$PREV_ATTEMPT >= $GATE_FIX_CAP). Escalating; no further auto-retry."
      bd -C "$GC_CITY" label remove "$BEAD_ID" "gate:needs-fix"   -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$BEAD_ID" "gate:needs-human" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Gate auto-fix cap ($GATE_FIX_CAP attempts) exhausted — labeled gate:needs-human. The machine could not resolve this after $GATE_FIX_CAP fix cycles; the Pilot will NOT re-dispatch it. Human/Mayor intervention required." 2>/dev/null || true
      # Escalate EXACTLY once: only mail if gate:needs-human was not already set.
      if ! printf '%s' "$SRC_LABELS" | grep -q "gate:needs-human"; then
        gc --city "$GC_CITY" mail send mayor \
          -s "Gate needs-human: $BEAD_ID exhausted $GATE_FIX_CAP fix attempts" \
          -m "$(printf 'Source bead %s failed the quality gate %s times. Auto-retry is now DISABLED (label gate:needs-human); the Pilot will not re-dispatch it.\n\nBranch: %s\nRig: %s\nGate run: %s\n\nLast blocking reasons:\n%s\n\nA human or the Mayor must intervene.' \
            "$BEAD_ID" "$((GATE_FIX_CAP + 1))" "$BRANCH" "$RIG" "$GATE_RUN_ID" "$(echo -e "$FAIL_REASONS")")" \
          2>/dev/null || warn "Could not mail Mayor escalation for $BEAD_ID"
        notify -t "Gate needs-human" -p 4 "$BEAD_ID exhausted $GATE_FIX_CAP gate fix attempts — Mayor escalated" 2>/dev/null || true
      fi
    else
      # (b) TRANSITION TO A PILOT-RE-DISPATCHABLE needs-fix STATE.
      NEW_ATTEMPT=$((PREV_ATTEMPT + 1))
      log "Marking $BEAD_ID gate:needs-fix (attempt $NEW_ATTEMPT/$GATE_FIX_CAP) for autonomous Pilot re-dispatch."
      # Bump the attempt counter (drop any stale counters first).
      for OLD in $(printf '%s' "$SRC_LABELS" | tr ' ' '\n' | grep '^gate:fix-attempt:'); do
        bd -C "$GC_CITY" label remove "$BEAD_ID" "$OLD" -q 2>/dev/null || true
      done
      bd -C "$GC_CITY" label add    "$BEAD_ID" "gate:fix-attempt:${NEW_ATTEMPT}" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$BEAD_ID" "gate:needs-fix"                  -q 2>/dev/null || true
      # Remove story:in-flight so the Pilot's feature-exclusion no longer hides it.
      bd -C "$GC_CITY" label remove "$BEAD_ID" "story:in-flight"  -q 2>/dev/null || true
      # Clear stale Pilot claim labels left over from the failed dispatch.
      bd -C "$GC_CITY" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
      bd -C "$GC_CITY" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
      # The Pilot's _filter_candidates drops ASSIGNED beads (both Tier-1 bugs and
      # Tier-2 features), so a stale builder assignee makes a failed bead invisible.
      # Clear it so the next sweep can re-pick this bead.
      bd -C "$GC_CITY" assign "$BEAD_ID" "" 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Gate FAILED (attempt ${NEW_ATTEMPT}/${GATE_FIX_CAP}) — labeled gate:needs-fix; story:in-flight and builder assignee cleared. The Pilot will re-dispatch a builder with the GATE-FEEDBACK above." 2>/dev/null || true
    fi
  fi

  # wa-uthi: TERMINAL FAIL (review rejected, definitive) — this push is KEPT.
  notify -t "Quality Gate FAILED" -p 3 "Branch $BRANCH failed review — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
fi

# ── Step 11: Log to quality-gate.jsonl ───────────────────────────────────────

mkdir -p "$(dirname "$QG_LOG")"
REASON=""
if [ "$OVERALL_VERDICT" = "PASS" ]; then
  REASON="quorum_${REQUIRED_REVIEWERS}_of_${REQUIRED_REVIEWERS}_independent_sessions"
else
  REASON=$(echo -e "$FAIL_REASONS" | head -1 | tr '\n' ' ' | cut -c1-200)
fi

jq -c -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg branch "$BRANCH" \
  --arg bead "$BEAD_ID" \
  --arg rig "${RIG:-unknown}" \
  --arg tier "$TIER" \
  --arg result "$OVERALL_VERDICT" \
  --arg reason "$REASON" \
  --arg gate_run "$GATE_RUN_ID" \
  --arg marker "$MARKER_ID" \
  --argjson elapsed_s "$ELAPSED_S" \
  --argjson reviewers "$REQUIRED_REVIEWERS" \
  --arg dry_run "$DRY_RUN" \
  '{ts: $ts, event: "dispatcher_complete", branch: $branch, bead: $bead,
    rig: $rig, tier: $tier, result: $result, reason: $reason,
    gate_run: $gate_run, marker: $marker, elapsed_s: $elapsed_s,
    reviewers: $reviewers, dry_run: $dry_run}' \
  >> "$QG_LOG" 2>/dev/null || true

log "=== Dispatcher sweep complete: branch=$BRANCH verdict=$OVERALL_VERDICT elapsed=${ELAPSED_S}s ==="

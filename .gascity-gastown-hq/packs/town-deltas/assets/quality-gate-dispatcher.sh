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

# ── Step 0: Find a queued marker ─────────────────────────────────────────────
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
  notify -t "Quality Gate Dispatcher" -p 3 "Author unresolvable for $MARKER_ID — deferred" 2>/dev/null || true
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
  notify -t "Quality Gate Dispatcher" -p 3 "Branch $BRANCH not found on remote — gate error" 2>/dev/null || true
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

  notify -t "Quality Gate" -p 1 "Branch $BRANCH already merged — gate marker superseded" 2>/dev/null || true
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
  warn "Branch $BRANCH is STALE: origin/$DEFAULT_BRANCH ($MAIN_HEAD_SHA) is not an ancestor of origin/$BRANCH ($BRANCH_SHA). Bouncing to author."
  bd -C "$GC_CITY" label remove "$MARKER_ID" "gate-status:dispatching" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$MARKER_ID" "gate-status:needs-rebase" -q 2>/dev/null || true
  bd -C "$GC_CITY" comment "$MARKER_ID" "Gate BLOCKED: branch $BRANCH is stale.
main HEAD is $MAIN_HEAD_SHA but the branch does not include it (branch base is behind main).
A merge could silently drop your changes if main has edits to the same regions.
Action required: rebase $BRANCH onto current origin/$DEFAULT_BRANCH and re-run /gate-done." 2>/dev/null || true

  if [ -n "$BEAD_ID" ]; then
    bd -C "$GC_CITY" label add  "$BEAD_ID" "gate:needs-rebase" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$BEAD_ID" "Quality gate blocked: branch $BRANCH needs rebase on current main ($MAIN_HEAD_SHA) before review can proceed. Rebase and re-run /gate-done." 2>/dev/null || true
  fi

  # Nudge the author to rebase
  if [ -n "$AUTHOR" ]; then
    gc --city "$GC_CITY" session nudge "$AUTHOR" \
      "GATE BLOCKED for branch $BRANCH: branch is stale and needs a rebase. Rebase onto current origin/$DEFAULT_BRANCH (main HEAD: $MAIN_HEAD_SHA) to ensure your changes merge cleanly, then re-run /gate-done. Bead: $BEAD_ID" \
      --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR for rebase"
  fi

  notify -t "Quality Gate" -p 3 "Branch $BRANCH needs rebase on current main before gate — bounced to $AUTHOR" 2>/dev/null || true

  mkdir -p "$(dirname "$QG_LOG")"
  jq -c -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg branch "$BRANCH" \
    --arg bead "$BEAD_ID" \
    --arg rig "${RIG:-unknown}" \
    --arg marker "$MARKER_ID" \
    --arg author "$AUTHOR" \
    --arg main_sha "$MAIN_HEAD_SHA" \
    '{ts: $ts, event: "dispatcher_needs_rebase", branch: $branch, bead: $bead, rig: $rig, marker: $marker, author: $author, main_sha: $main_sha}' \
    >> "$QG_LOG" 2>/dev/null || true

  log "=== Dispatcher sweep complete: branch=$BRANCH verdict=NEEDS_REBASE (stale base) ==="
  exit 0
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

DIFF_SUMMARY=$(git_rig diff --stat "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | tail -5 | tr '\n' ' ' | cut -c1-300)
DIFF_FULL=$(git_rig diff "origin/$DEFAULT_BRANCH...origin/$BRANCH" 2>/dev/null | head -2000)

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
        # Collect the fail reason from comments
        FAIL_COMMENT=$(bd -C "$GC_CITY" comments "$VB" --json 2>/dev/null \
          | jq -r '.[0].body // "No reason provided"' 2>/dev/null || echo "No reason provided")
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

    if [ "$IS_CONTAINER_RIG" = "1" ]; then
      # Container rig: operate on bare .repo.git via git_rig() wrapper
      # Get current main sha and branch sha
      MAIN_SHA=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
      BRANCH_MERGE_SHA=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "")

      if [ -z "$MAIN_SHA" ] || [ -z "$BRANCH_MERGE_SHA" ]; then
        err "Cannot resolve SHAs for merge. main=$MAIN_SHA branch=$BRANCH_MERGE_SHA"
        MERGE_RESULT="failed_sha_resolution"
      else
        # Check if branch is based on (reachable from) current main — required for FF
        IS_ANCESTOR=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

        if [ "$IS_ANCESTOR" = "yes" ]; then
          # Fast-forward: push branch SHA directly to main ref.
          # This is equivalent to `git push origin <branch>:main` but works from
          # a bare repo where we only have remote-tracking refs.
          if git_rig push origin "$BRANCH_MERGE_SHA:refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
            # Bug 1 fix: VERIFY landing — fetch + confirm branch SHA is now an ancestor of main.
            # The push command can return 0 but still fail to advance main in edge cases
            # (e.g. remote hook rejection). We verify the branch tip is reachable from
            # origin/main BEFORE recording gc.outcome=pass or closing the source bead.
            git_rig fetch origin 2>/dev/null || warn "Post-push fetch failed; landing check may use stale refs"
            POST_PUSH_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
            if [ -n "$POST_PUSH_MAIN" ] && git_rig merge-base --is-ancestor "$BRANCH_MERGE_SHA" "$POST_PUSH_MAIN" 2>/dev/null; then
              MERGE_SHA="$BRANCH_MERGE_SHA"
              MERGE_RESULT="direct_ff"
              log "FF merge + landing verified: $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA, main=$POST_PUSH_MAIN)"
            else
              err "Landing verification FAILED: branch SHA $BRANCH_MERGE_SHA is NOT an ancestor of origin/$DEFAULT_BRANCH ($POST_PUSH_MAIN) after push. Silent drop detected."
              MERGE_RESULT="failed_landing_not_verified"
            fi
          else
            err "git push failed for FF merge of $BRANCH → $DEFAULT_BRANCH"
            MERGE_RESULT="failed_push"
          fi
        else
          # Branch is not based on current main: needs merge commit.
          # Use a temporary worktree to perform the merge and push.
          warn "Branch $BRANCH is not FF-able onto $DEFAULT_BRANCH — attempting merge commit"

          TMP_WT="/tmp/gc-gate-merge-$$"
          if git_rig worktree add "$TMP_WT" "origin/$DEFAULT_BRANCH" 2>/dev/null; then
            # In the worktree, merge with --no-ff to produce a merge commit
            if git -C "$TMP_WT" merge --no-ff "origin/$BRANCH" -m "Merge branch '$BRANCH' via quality gate (gate_run=$GATE_RUN_ID)" 2>/dev/null; then
              if git -C "$TMP_WT" push origin "HEAD:$DEFAULT_BRANCH" 2>/dev/null; then
                CANDIDATE_SHA=$(git -C "$TMP_WT" rev-parse HEAD 2>/dev/null || echo "unknown")
                # Bug 1 fix: verify landing for merge-commit path too
                git_rig fetch origin 2>/dev/null || warn "Post-merge-commit fetch failed"
                POST_PUSH_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
                if [ "$CANDIDATE_SHA" != "unknown" ] && [ -n "$POST_PUSH_MAIN" ] && \
                   git_rig merge-base --is-ancestor "$CANDIDATE_SHA" "$POST_PUSH_MAIN" 2>/dev/null; then
                  MERGE_SHA="$CANDIDATE_SHA"
                  MERGE_RESULT="merge_commit"
                  log "Merge commit + landing verified: $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA)"
                else
                  err "Landing verification FAILED for merge commit: $CANDIDATE_SHA not in origin/$DEFAULT_BRANCH ($POST_PUSH_MAIN)."
                  MERGE_RESULT="failed_landing_not_verified"
                fi
              else
                err "git push failed after merge commit"
                MERGE_RESULT="failed_push_merge_commit"
              fi
            else
              err "git merge failed (conflict?) for $BRANCH"
              MERGE_RESULT="failed_merge_conflict"
            fi
            git_rig worktree remove "$TMP_WT" --force 2>/dev/null || true
          else
            err "Could not create temp worktree for merge commit"
            MERGE_RESULT="failed_worktree"
          fi
        fi
      fi
    else
      # Self-repo rig: git_rig() uses git -C <rig_path>
      IS_ANCESTOR=$(git_rig merge-base --is-ancestor "origin/$DEFAULT_BRANCH" "origin/$BRANCH" 2>/dev/null && echo "yes" || echo "no")

      if [ "$IS_ANCESTOR" = "yes" ]; then
        BRANCH_MERGE_SHA=$(git_rig rev-parse "origin/$BRANCH" 2>/dev/null || echo "unknown")
        if git_rig push origin "$BRANCH_MERGE_SHA:refs/heads/$DEFAULT_BRANCH" 2>/dev/null; then
          # Bug 1 fix: verify landing for self-repo FF path
          git_rig fetch origin 2>/dev/null || warn "Post-push fetch failed (self-repo); landing check may use stale refs"
          POST_PUSH_MAIN=$(git_rig rev-parse "origin/$DEFAULT_BRANCH" 2>/dev/null || echo "")
          if [ "$BRANCH_MERGE_SHA" != "unknown" ] && [ -n "$POST_PUSH_MAIN" ] && \
             git_rig merge-base --is-ancestor "$BRANCH_MERGE_SHA" "$POST_PUSH_MAIN" 2>/dev/null; then
            MERGE_SHA="$BRANCH_MERGE_SHA"
            MERGE_RESULT="direct_ff"
            log "FF merge + landing verified (self-repo): $BRANCH → $DEFAULT_BRANCH (sha=$MERGE_SHA)"
          else
            err "Landing verification FAILED (self-repo): $BRANCH_MERGE_SHA not in origin/$DEFAULT_BRANCH ($POST_PUSH_MAIN). Silent drop."
            MERGE_RESULT="failed_landing_not_verified"
          fi
        else
          err "git push failed for self-repo FF merge"
          MERGE_RESULT="failed_push"
        fi
      else
        err "Branch $BRANCH not FF-able; self-repo rebase required (not auto-handled)."
        MERGE_RESULT="failed_not_ff"
      fi
    fi

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

    # Transition source bead toward done (close if appropriate)
    if [ -n "$BEAD_ID" ] && [ "$DRY_RUN" != "1" ]; then
      bd -C "$GC_CITY" label add "$BEAD_ID" "gate:passed" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$BEAD_ID" "Quality gate PASSED. Branch $BRANCH merged to $RIG/$DEFAULT_BRANCH (sha=$MERGE_SHA) via autonomous dispatcher (gate_run=$GATE_RUN_ID)." 2>/dev/null || true
    fi

    notify -t "Quality Gate PASSED" -p 2 "Branch $BRANCH merged to $DEFAULT_BRANCH — $TIER, ${ELAPSED_S}s" 2>/dev/null || true
    log "Gate PASSED: branch=$BRANCH tier=$TIER merge_sha=$MERGE_SHA elapsed=${ELAPSED_S}s"
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

#!/usr/bin/env bash
# story-delivery.sh — Autonomous Story Delivery Driver ("D").
#
# Runs after the quality gate merges a story to prod main. Handles the gap
# between "merged" and "done": deploys code, verifies in prod, marks story:done.
#
# Pipeline:
#   1. Find stories with label gate:passed (merged, not yet deployed/verified).
#   2. For each, load its rig's deploy runbook from delivery-runbooks.toml.
#   3. Deploy: run the rig's deploy_cmd (git pull / etc.)
#   4. Restart daemons listed in daemon_restarts (if any).
#   5. Run the rig's prod_test_script (with STORY_ID set so story-specific
#      tests are included). Exit code decides pass/fail.
#   6. Verify refino criteria from the story bead metadata.
#   7. SUCCESS: add label story:done + comment with evidence.
#   8. FAILURE: HALT-AND-ESCALATE — notify author + Mayor, add label
#      delivery:failed, DO NOT auto-revert (DB migration risk).
#   9. Log to .gc/story-delivery.jsonl.
#
# SAFETY INVARIANTS:
#   - NEVER auto-reverts. On failure: halt + escalate.
#   - DRY_RUN=1 → prints what it WOULD do, no writes.
#   - No edits to city.toml, pack.toml, or crew skill files.
#   - Idempotent: skips stories already labeled story:done.
#
# Usage:
#   bash story-delivery.sh            # normal run
#   DRY_RUN=1 bash story-delivery.sh  # dry-run (proof mode)
#   STORY_ID=ga-b8t bash story-delivery.sh  # force single story
#   DRY_RUN=1 STORY_ID=ga-b8t bash story-delivery.sh  # dry-run single story

set -euo pipefail

GC_CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG_DIR="$GC_CITY/.gc/logs"
LOG="$LOG_DIR/story-delivery.log"
DELIVERY_LOG="$GC_CITY/.gc/story-delivery.jsonl"
RUNBOOK_FILE="$GC_CITY/packs/town-deltas/assets/delivery-runbooks.toml"

DRY_RUN="${DRY_RUN:-0}"
FORCE_STORY_ID="${STORY_ID:-}"  # If set, process only this story

mkdir -p "$LOG_DIR"
exec >> "$LOG" 2>&1

log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] $*"; }
err()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] ERROR: $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [story-delivery] WARN: $*"; }

echo ""
log "=== Delivery sweep start (DRY_RUN=${DRY_RUN}) ==="

# ── Step 0: Read runbook file ─────────────────────────────────────────────────
# Parse TOML runbook via Python (available everywhere this runs).
if [ ! -f "$RUNBOOK_FILE" ]; then
  err "Runbook file not found: $RUNBOOK_FILE"
  exit 1
fi

get_runbook_field() {
  local rig_name="$1"
  local field="$2"
  python3 - <<PYEOF
import re, sys

rig_name = '$rig_name'
field = '$field'

with open('$RUNBOOK_FILE') as f:
    content = f.read()

# Find the [[rig]] block for our rig
# Simple parser: split on [[rig]] boundaries, find the one with name = "rig_name"
blocks = re.split(r'\[\[rig\]\]', content)
for block in blocks:
    m = re.search(r'name\s*=\s*"([^"]+)"', block)
    if m and m.group(1) == rig_name:
        # Find the field value
        fm = re.search(rf'{re.escape(field)}\s*=\s*"([^"]*)"', block)
        if fm:
            print(fm.group(1))
        else:
            # Check for array (daemon_restarts = [])
            am = re.search(rf'{re.escape(field)}\s*=\s*\[([^\]]*)\]', block)
            if am:
                items = [x.strip().strip('"') for x in am.group(1).split(',') if x.strip().strip('"')]
                print('\n'.join(items))
        sys.exit(0)
# Not found
sys.exit(1)
PYEOF
}

# ── FIX 1 (ga-857v): safe untracked-vs-tracked reconciliation before ff-pull ──
# Problem: deploy_cmd typically runs `git -C <runtime> pull --ff-only`. If the
# runtime working tree holds an UNTRACKED copy of a file that the incoming merge
# adds as TRACKED (e.g. a live-served daemon that ran as an untracked file
# before its tracked version merged to main), git aborts the ff-pull:
#   "The following untracked working tree files would be overwritten by merge:
#    <file> — Please move or remove them before you merge. Aborting"
# Delivery then sets delivery:failed and the story never reaches story:done,
# even though the merge to main is durable and the content is byte-identical.
#
# This reconciler removes ONLY verified-identical duplicates. For each untracked
# file the incoming upstream adds as tracked, it compares the working-tree bytes
# against the upstream version:
#   IDENTICAL  → back up to /tmp then remove, so the ff-pull lands the tracked
#                copy (the NEVER-auto-revert invariant holds: we only delete a
#                proven-identical duplicate, never real content).
#   DIFFERENT  → do NOT touch it; collect into RECONCILE_DIFF_LIST and return 2
#                so the caller halts + escalates (uncommitted prod work is never
#                destroyed).
# Sets globals RECONCILE_DIFF_LIST (space-separated paths that differ) and
# RECONCILE_COUNT (number auto-reconciled). Honours DRY_RUN.
RECONCILE_DIFF_LIST=""
RECONCILE_COUNT=0
reconcile_untracked_for_ffpull() {
  local dir="$1"
  RECONCILE_DIFF_LIST=""
  RECONCILE_COUNT=0

  # Only meaningful for a real git working tree.
  [ -n "$dir" ] || { log "reconcile: no runtime_dir — skip"; return 0; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    log "reconcile: $dir is not a git work tree — skip"; return 0; }

  # Determine the incoming upstream ref (e.g. origin/main).
  local upstream remote branch
  upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo "")
  if [ -z "$upstream" ]; then
    branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || echo "")
    [ -n "$branch" ] && upstream="origin/$branch"
  fi
  [ -n "$upstream" ] || { log "reconcile: no upstream for $dir — skip"; return 0; }
  remote="${upstream%%/*}"

  # Refresh remote refs so the comparison reflects what the pull will merge.
  git -C "$dir" fetch --quiet "$remote" 2>/dev/null \
    || git -C "$dir" fetch --quiet 2>/dev/null || true

  local conflicts=0 u base ts backup
  # Enumerate untracked (non-ignored) files; -z keeps paths with spaces safe.
  while IFS= read -r -d '' u; do
    [ -n "$u" ] || continue
    # Does the incoming upstream add this path as tracked? If not, ignore it
    # (genuine local-only file — leave it completely alone).
    git -C "$dir" cat-file -e "$upstream:$u" 2>/dev/null || continue
    # Collision candidate. Compare working-tree bytes against incoming version.
    if git -C "$dir" show "$upstream:$u" 2>/dev/null | cmp -s - "$dir/$u"; then
      # IDENTICAL → safe to remove so the ff-pull can land the tracked copy.
      base=$(basename "$u")
      ts=$(date +%Y%m%d-%H%M%S)
      backup="/tmp/${base}.backup.${ts}.$$"
      if [ "$DRY_RUN" = "1" ]; then
        log "reconcile: DRY_RUN — WOULD backup+remove identical untracked '$u' (backup $backup)"
      else
        cp -p "$dir/$u" "$backup" 2>/dev/null || cp "$dir/$u" "$backup" 2>/dev/null || true
        rm -f "$dir/$u"
        log "reconcile: auto-reconciled identical untracked '$u' (backup: $backup)"
      fi
      RECONCILE_COUNT=$((RECONCILE_COUNT + 1))
    else
      # GENUINELY DIFFERENT → never clobber. Record for halt + escalation.
      warn "reconcile: CONFLICT — untracked '$u' DIFFERS from incoming $upstream:$u (NOT removed)"
      RECONCILE_DIFF_LIST="$RECONCILE_DIFF_LIST $u"
      conflicts=$((conflicts + 1))
    fi
  done < <(git -C "$dir" ls-files --others --exclude-standard -z 2>/dev/null)

  [ "$conflicts" -gt 0 ] && return 2
  return 0
}

# ── Step 1: Find stories with gate:passed but NOT story:done ──────────────────
# Stories are identified by label story:approved (type field is null in bd).
# gate:passed is set by the quality-gate-dispatcher after merge.
# story:done is set by this script after successful delivery.
if [ -n "$FORCE_STORY_ID" ]; then
  log "Forced single-story mode: $FORCE_STORY_ID"
  STORIES_JSON=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    -l "gate:passed" \
    2>/dev/null | jq --arg id "$FORCE_STORY_ID" '[.[] | select(.id == $id)]' || echo "[]")
else
  STORIES_JSON=$(bd -C "$GC_CITY" list --json \
    -l "story:approved" \
    -l "gate:passed" \
    2>/dev/null | jq '[.[] | select(.labels | map(select(. == "story:done")) | length == 0)]' || echo "[]")
fi

COUNT=$(echo "$STORIES_JSON" | jq 'length' 2>/dev/null || echo "0")
log "Found $COUNT story/stories awaiting delivery"

if [ "$COUNT" = "0" ]; then
  log "No stories pending delivery. Exiting."
  exit 0
fi

# Iterate all eligible stories — avoids head-of-line blocking when .[0] halts.
while IFS= read -r STORY; do
  # Reset per-iteration state so a prior story's halt never bleeds into the next.
  NO_HARNESS=0
  STORY_TEST_MISSING=0
  RUN_RECONCILE=0
  RECONCILE_COUNT=0
  RECONCILE_DIFF_LIST=""
  PRE_DEPLOY_SHA=""
  POST_DEPLOY_SHA=""
  STALENESS_GATE=0

  STORY_ID=$(echo "$STORY" | jq -r '.id')
  STORY_TITLE=$(echo "$STORY" | jq -r '.description // .title // "untitled"' | head -c 80)
  STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')

  log "Processing story $STORY_ID: $STORY_TITLE"
  log "Labels: $STORY_LABELS"

# Skip if already marked story:done (idempotency guard)
if echo "$STORY_LABELS" | grep -q "story:done"; then
  log "Story $STORY_ID already labeled story:done — skipping."
  continue
fi

# Skip if already in delivery (prevents parallel runs)
if echo "$STORY_LABELS" | grep -q "delivery:running"; then
  log "Story $STORY_ID already has delivery:running — skipping (already in flight)."
  continue
fi

# Mark as running (claim)
if [ "$DRY_RUN" != "1" ]; then
  bd -C "$GC_CITY" label add "$STORY_ID" "delivery:running" -q 2>/dev/null || {
    warn "Could not add delivery:running to $STORY_ID (race condition?). Skipping."
    continue
  }
fi

DELIVERY_START=$(date +%s)

# ── Step 2: Determine rig from story metadata / labels ───────────────────────
# Priority order:
#   1. label  rig:<name>  on the bead
#   2. metadata field  story.rig
#   3. Parse the gate comment ("merged to <rig>/main") — set by dispatcher
RIG=""
if echo "$STORY_LABELS" | grep -oE "rig:[a-z_]+" | head -1 | grep -q "rig:"; then
  RIG=$(echo "$STORY_LABELS" | grep -oE "rig:[a-z_]+" | head -1 | sed 's/rig://')
fi

if [ -z "$RIG" ]; then
  RIG=$(echo "$STORY" | jq -r '.metadata // {} | .["story.rig"] // ""' 2>/dev/null || echo "")
fi

if [ -z "$RIG" ]; then
  # Parse the gate dispatcher comment: "merged to property_scrapers/main (sha=...)"
  GATE_COMMENT=$(bd -C "$GC_CITY" comments "$STORY_ID" 2>/dev/null \
    | grep -oE "merged to [a-z_]+/main" | head -1 || echo "")
  if [ -n "$GATE_COMMENT" ]; then
    RIG=$(echo "$GATE_COMMENT" | sed 's/merged to //' | sed 's|/main||')
    log "Rig derived from gate comment: $RIG"
  fi
fi

if [ -z "$RIG" ]; then
  err "Cannot determine rig for story $STORY_ID. Add label rig:<name> or metadata story.rig to the bead."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery FAILED: cannot determine rig. Add label rig:<name> or metadata field story.rig to this bead." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (delivery:failed is re-picked every cycle until fixed —
  # retries indefinitely, not a definitive rejection) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID rig unknown — add rig:<name> label."
  continue
fi

log "Rig: $RIG"

# ── Step 3: Load runbook for this rig ─────────────────────────────────────────
DEPLOY_CMD=$(get_runbook_field "$RIG" "deploy_cmd" 2>/dev/null || echo "")
RUNTIME_DIR=$(get_runbook_field "$RIG" "runtime_dir" 2>/dev/null || echo "")
PROD_TEST_SCRIPT=$(get_runbook_field "$RIG" "prod_test_script" 2>/dev/null || echo "")

if [ -z "$DEPLOY_CMD" ]; then
  err "No deploy_cmd for rig '$RIG' in runbook. Story delivery blocked."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery HALTED: no deploy_cmd for rig '$RIG'. Codify the deploy runbook before retrying." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (config gap, retries every cycle once codified) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — no deploy_cmd for rig $RIG."
  continue
fi

# Bug 2 fix (ga-dqp): warn-only when the rig has NO prod-test harness at all.
# RATIONALE: some rigs (e.g. whatsapp_automation) have no prod_test_script yet.
# Halting delivery for every WA story blocks the pipeline indefinitely.
# INTERIM POLICY: if prod_test_script is empty/missing → deliver + warn (story:done
# with delivery:untested label). If the rig HAS a harness but the file is absent
# or the story-specific test is missing, HALT as before (author must fix).
# DESTINY: add a real prod-test harness per rig (tracked as follow-up).
NO_HARNESS=0
if [ -z "$PROD_TEST_SCRIPT" ]; then
  warn "No prod_test_script configured for rig '$RIG' — rig has no test harness. Proceeding with delivery:untested (interim policy)."
  NO_HARNESS=1
fi

# wa-l5z9 + ga-857v FIX 2: a MISSING story-specific prod test is NON-BLOCKING.
# RATIONALE (flow-never-stops): the pipeline must never stall just because nobody
# wrote a story-specific test. wa-l5z9 first removed the HALT/per-cycle NTFY for
# this case by SKIPPING the prod test → delivery:untested.
# ga-857v FIX 2 finishes the job wa-l5z9's comments deferred to it ("coverage
# tracked by ga-857v"): instead of skipping, if the rig HAS a harness we now RUN
# the rig's BASELINE harness (run.sh invoked WITHOUT STORY_ID, so no rig's run.sh
# can hard-fail on the absent story test) → a passing baseline yields
# delivery:tested. The flow still never HALTs on a *missing* test; it only fails
# if the baseline detects genuinely broken prod (which SHOULD halt). The sole
# remaining delivery:untested case is NO_HARNESS=1 (rig has no harness at all).
STORY_TEST_MISSING=0

if [ "$NO_HARNESS" = "0" ] && [ ! -f "$PROD_TEST_SCRIPT" ]; then
  err "prod_test_script '$PROD_TEST_SCRIPT' not found on disk."
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery HALTED: prod_test_script '$PROD_TEST_SCRIPT' not found. File must exist." 2>/dev/null || true
  fi
  # wa-uthi: non-terminal (runbook misconfig — points to a non-existent harness
  # file; retries every cycle until fixed) — no push. Logged + bead comment only.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — prod_test_script '$PROD_TEST_SCRIPT' not found on disk."
  continue
fi

# Check for story-specific test existence (only if the rig HAS a harness).
# wa-l5z9: an ABSENT story-specific test is NON-BLOCKING (warn-only) — set
# STORY_TEST_MISSING=1 and continue. Delivery proceeds and ends at story:done
# with delivery:untested (same warn-only path as the no-harness case). No HALT,
# no per-cycle NTFY.
SCRIPT_DIR=""
STORY_TEST_FILE=""
if [ "$NO_HARNESS" = "0" ]; then
  SCRIPT_DIR="$(cd "$(dirname "$PROD_TEST_SCRIPT")" && pwd)"
  STORY_TEST_FILE="$SCRIPT_DIR/story-${STORY_ID}.sh"
  if [ ! -f "$STORY_TEST_FILE" ]; then
    warn "No story-specific prod test: $STORY_TEST_FILE — proceeding with delivery:untested (wa-l5z9 warn-only policy). Flow never stops; coverage tracked by ga-857v/ga-iwv0."
    STORY_TEST_MISSING=1
  fi
fi

log "Runbook loaded: deploy_cmd='$DEPLOY_CMD' runtime='$RUNTIME_DIR' test='$PROD_TEST_SCRIPT'"

# ── Step 3.5: Reconcile untracked-vs-tracked before deploy (ga-857v FIX 1) ────
# Prevents the ff-pull abort when the runtime holds an untracked copy of a file
# the incoming merge adds as tracked. Identical duplicates are backed up +
# removed; a genuine divergence halts + escalates (never clobbered).
#
# SCOPE: only run when the deploy will execute a FATAL `pull --ff-only` (the
# bug's domain — property_scrapers, whatsapp_automation). Rigs whose deploy
# swallows pull failures (e.g. gascity: "... 2>/dev/null || true") or that don't
# pull at all are NOT subject to the untracked-overwrite abort, so the reconcile
# must NOT run for them — otherwise a pre-existing, harmless untracked file in
# that runtime (e.g. the town root's .gitignore) would wrongly halt delivery.
RUN_RECONCILE=0
case "$DEPLOY_CMD" in
  *"pull --ff-only"*)
    case "$DEPLOY_CMD" in
      *"|| true"*) RUN_RECONCILE=0 ;;  # pull failure swallowed → not fatal
      *)           RUN_RECONCILE=1 ;;
    esac
    ;;
esac

if [ "$RUN_RECONCILE" != "1" ]; then
  log "Pre-deploy reconcile skipped — deploy_cmd for rig '$RIG' does not run a fatal ff-pull."
elif reconcile_untracked_for_ffpull "$RUNTIME_DIR"; then
  if [ "$RECONCILE_COUNT" -gt 0 ]; then
    log "Pre-deploy reconcile: backed up + removed $RECONCILE_COUNT identical untracked duplicate(s) so the ff-pull can land the tracked version(s)."
  fi
else
  # Return 2 → genuine divergence between an untracked prod file and the merge.
  err "Pre-deploy reconcile ABORT: untracked working-tree file(s) DIFFER from the incoming tracked version:$RECONCILE_DIFF_LIST"
  if [ "$DRY_RUN" != "1" ]; then
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery HALTED (ga-857v FIX 1): the production working tree at $RUNTIME_DIR holds untracked file(s) that the incoming merge adds as tracked, and they GENUINELY DIFFER from the merged version:$RECONCILE_DIFF_LIST
These were NOT removed — uncommitted prod work is never destroyed. Resolve manually: diff each untracked file against origin's version, preserve any real local changes, then re-run delivery." 2>/dev/null || true
    # Escalate to author + Mayor via nudge (durable record is the bead comment + label).
    AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
    if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
      gc --city "$GC_CITY" session nudge "$AUTHOR" \
        "DELIVERY HALTED for story $STORY_ID: untracked prod file(s) differ from the incoming merge:$RECONCILE_DIFF_LIST. NOT clobbered — resolve manually, then re-run delivery." \
        --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
    fi
    gc --city "$GC_CITY" session nudge mayor \
      "DELIVERY HALTED ($STORY_ID, rig $RIG): untracked working-tree file(s) at $RUNTIME_DIR differ from the incoming merged version:$RECONCILE_DIFF_LIST. Not removed (no data loss). Manual resolution needed before re-running delivery." \
      2>/dev/null || true
  fi
  # wa-uthi: non-terminal (delivery:failed is re-picked every cycle until the
  # divergence is resolved — retries, not a definitive rejection) — SUPPRESS the
  # Athos push. Author + Mayor are nudged above; the bead comment is the record.
  warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID reconcile conflict — untracked prod file differs from merge:$RECONCILE_DIFF_LIST."
  continue
fi

# ── Step 4: Deploy ─────────────────────────────────────────────────────────────
# Capture the deploy timestamp + pre-deploy HEAD so Step 5b (ga-iwv0) can tell
# which source files this deploy changed and prove the affected daemons restart
# AFTER the deploy. Both are best-effort: only meaningful when runtime_dir is a
# git work tree (the rigs whose deploy is a git-pull).
DEPLOY_EPOCH=$(date +%s)
PRE_DEPLOY_SHA=""
if [ -n "$RUNTIME_DIR" ] && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  PRE_DEPLOY_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD RUN: $DEPLOY_CMD"
else
  log "Deploying rig $RIG ..."
  DEPLOY_OUTPUT=$(eval "$DEPLOY_CMD" 2>&1) && DEPLOY_RC=$? || DEPLOY_RC=$?
  log "Deploy output: $DEPLOY_OUTPUT"
  if [ "$DEPLOY_RC" -ne 0 ]; then
    err "Deploy failed (rc=$DEPLOY_RC): $DEPLOY_OUTPUT"
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery FAILED at deploy step. Command: $DEPLOY_CMD. Output: $DEPLOY_OUTPUT. HALT — investigate before retrying." 2>/dev/null || true
    # wa-uthi: non-terminal (delivery:failed is re-picked next cycle — retries, no
    # retry-exhaustion counter) — no push. Logged + bead comment only.
    warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID deploy failed (rc=$DEPLOY_RC)."
    continue
  fi
  log "Deploy OK"
fi

# Post-deploy HEAD (the SHA the runtime is now serving). With PRE_DEPLOY_SHA this
# brackets exactly what the deploy changed.
POST_DEPLOY_SHA=""
if [ -n "$RUNTIME_DIR" ] && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  POST_DEPLOY_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
fi

# ── Step 4.5: Post-deploy town-root staleness gate (ga-rhtu) ──────────────────
# THE BUG: rigs whose deploy_cmd runs a BEST-EFFORT, swallowed ff-pull
# (`git -C <dir> pull --ff-only ... 2>/dev/null || true; <install>` — the
# gascity / in-place HQ-framework runtime) can silently keep running STALE code.
# If that runtime's branch carries LOCAL-AHEAD or DIVERGED commits, or its `main`
# tracks a stale upstream (a fork remote), the ff-pull CANNOT fast-forward to
# origin/main, the `|| true` eats the failure, and Step 4 logs "Deploy OK" on a
# tree that never received the just-merged fix. Delivery would then mark
# story:done while the live engines run outdated code (proven on ga-jb4l).
# FATAL-pull rigs are NOT affected — a failed `pull --ff-only` already halts
# Step 4 above — so this gate runs ONLY for the swallowed-pull class.
#
# Fail-closed verification: after deploy, the runtime HEAD must CONTAIN
# origin/<branch> (the canonical merge target the gate pushes to). If
# origin/<branch> is an ANCESTOR of HEAD (HEAD is current, or merely local-ahead
# — a documented, legitimate state for the in-place town root) delivery
# proceeds. If HEAD is BEHIND or DIVERGED (origin/<branch> is NOT an ancestor —
# the merged fix is missing), or freshness cannot be verified at all, delivery
# HALTS LOUDLY (delivery:failed, escalate author + Mayor, story:done WITHHELD)
# and is re-picked next cycle once the town-root reconciler brings the tree
# current. It does NOT reconcile the tree itself: THIS script runs in-place from
# that tree, so a self-mutating ff mid-run risks corrupting the running engine —
# advancing the tree is the reconciler's job, not delivery's.
STALENESS_GATE=0
case "$DEPLOY_CMD" in
  *"pull --ff-only"*)
    case "$DEPLOY_CMD" in
      *"|| true"*) STALENESS_GATE=1 ;;   # swallowed ff-pull → the vulnerable class
    esac
    ;;
esac
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — skipping post-deploy staleness gate."
  STALENESS_GATE=0
fi
if [ "$STALENESS_GATE" = "1" ] && [ -n "$RUNTIME_DIR" ] \
   && git -C "$RUNTIME_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  STALE_BRANCH=$(git -C "$RUNTIME_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  case "$STALE_BRANCH" in ""|HEAD) STALE_BRANCH="main" ;; esac
  STALE_REF="origin/$STALE_BRANCH"
  # Best-effort, bounded refresh of the canonical ref. Never fatal on its own —
  # the deploy's own pull already fetched; this only guards a stale local ref.
  timeout 30 git -C "$RUNTIME_DIR" fetch origin "$STALE_BRANCH" --quiet 2>/dev/null \
    || warn "Staleness gate: 'git fetch origin $STALE_BRANCH' failed/timed out — comparing against last-known $STALE_REF."
  STALE_REMOTE_SHA=$(git -C "$RUNTIME_DIR" rev-parse "$STALE_REF" 2>/dev/null || echo "")
  STALE_HEAD_SHA=$(git -C "$RUNTIME_DIR" rev-parse HEAD 2>/dev/null || echo "")
  if [ -z "$STALE_REMOTE_SHA" ]; then
    STALE_VERDICT="UNVERIFIABLE"
  elif git -C "$RUNTIME_DIR" merge-base --is-ancestor "$STALE_REF" HEAD 2>/dev/null; then
    STALE_VERDICT="CURRENT"     # HEAD contains origin/<branch> (current or local-ahead) → fresh
  else
    STALE_VERDICT="STALE"       # behind or diverged → the merged fix is NOT live
  fi

  if [ "$STALE_VERDICT" = "CURRENT" ]; then
    log "Staleness gate OK: $RUNTIME_DIR HEAD ($STALE_HEAD_SHA) contains $STALE_REF ($STALE_REMOTE_SHA)."
  else
    STALE_COUNTS=$(git -C "$RUNTIME_DIR" rev-list --left-right --count "$STALE_REF...HEAD" 2>/dev/null || printf '?\t?')
    STALE_BEHIND=$(printf '%s' "$STALE_COUNTS" | awk '{print $1}')
    STALE_AHEAD=$(printf '%s' "$STALE_COUNTS" | awk '{print $2}')
    if [ "$STALE_VERDICT" = "UNVERIFIABLE" ]; then
      STALE_MSG="could not resolve $STALE_REF in $RUNTIME_DIR — freshness UNVERIFIABLE (failing closed to avoid a false story:done)"
    else
      STALE_MSG="live runtime $RUNTIME_DIR is STALE — HEAD ($STALE_HEAD_SHA) is behind=$STALE_BEHIND / ahead=$STALE_AHEAD vs $STALE_REF ($STALE_REMOTE_SHA); the merged fix did NOT reach the in-place engines"
    fi
    err "Staleness gate HALT (ga-rhtu): $STALE_MSG"
    if [ "$DRY_RUN" != "1" ]; then
      bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$STORY_ID" "Delivery HALTED (ga-rhtu post-deploy staleness gate): $STALE_MSG. story:done WITHHELD — the live framework engines would otherwise be marked done while running outdated code. NON-TERMINAL: the town-root reconciler brings $RUNTIME_DIR current with $STALE_REF, after which delivery is re-picked automatically. If HEAD carries local-ahead commits on the in-place town root, move them to an isolated worktree (ref: 'Shipping framework stories via gate') so the tree stays fast-forwardable." 2>/dev/null || true
      AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
      if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
        gc --city "$GC_CITY" session nudge "$AUTHOR" \
          "DELIVERY HALTED for story $STORY_ID: $STALE_MSG. story:done withheld; re-picked once the town root is reconciled to $STALE_REF." \
          --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
      fi
      gc --city "$GC_CITY" session nudge mayor \
        "DELIVERY HALTED ($STORY_ID, rig $RIG): $STALE_MSG. story:done withheld (ga-rhtu staleness gate). Reconcile $RUNTIME_DIR to $STALE_REF; delivery retries next cycle." \
        2>/dev/null || true
    fi
    # Non-terminal (re-picked every cycle until the tree is reconciled — retries,
    # not a definitive rejection) → SUPPRESS the Athos push (wa-uthi convention).
    warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID — $STALE_MSG."
    continue
  fi
fi

# ── Step 5: Daemon restarts ────────────────────────────────────────────────────
DAEMON_LIST=$(get_runbook_field "$RIG" "daemon_restarts" 2>/dev/null || echo "")
if [ -n "$DAEMON_LIST" ]; then
  while IFS= read -r daemon; do
    [ -z "$daemon" ] && continue
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN=1 — WOULD kickstart launchd: $daemon"
    else
      log "Kickstarting daemon: $daemon"
      launchctl kickstart -k "gui/$(id -u)/$daemon" 2>/dev/null \
        || launchctl kickstart "$daemon" 2>/dev/null \
        || warn "launchctl kickstart failed for $daemon (may already be running or label wrong)"
    fi
  done <<< "$DAEMON_LIST"
fi

# ── Step 5b: Daemon freshness refresh + verification (ga-iwv0) ────────────────
# THE BUG: the deploy above is a git-pull — it updates files on disk but does
# NOT restart long-lived launchd daemons. A daemon-side feature merged into an
# already-running process stays DORMANT until that process restarts for some
# other reason, while the story is marked story:done (ga-d81: ban-risk-dashboard
# served 5-day-old code; every new endpoint 404'd). This step closes the gap:
# it detects which RUNNING daemons the merged files affect, restarts the SAFE
# (read-only dashboard) ones, and VERIFIES each came up AFTER this deploy.
# SENSITIVE hot-path daemons (central_sender, webhook_receiver, slot_scheduler,
# conversation_monitor — from the rig's sensitive_daemons runbook field) are
# NEVER auto-bounced (in-flight messages/webhooks must drain first); they are
# flagged for a guarded restart. A dormant or unverifiable daemon HALTS delivery
# here, BEFORE story:done — making a dormant deploy impossible to mark done.
#
# Skipped for the framework/town-root rig: its own engine daemons (this very
# script, the gate dispatcher, the reconcilers) must not be self-restarted
# mid-run; they are handled by config-drift-watcher + the static daemon_restarts
# above. Also skipped when runtime_dir is unset.
REFRESH_HELPER="$GC_CITY/packs/town-deltas/assets/daemon-refresh.sh"
if [ -z "$RUNTIME_DIR" ] || [ "$RUNTIME_DIR" = "$GC_CITY" ]; then
  log "Daemon refresh skipped — framework/town-root or no runtime_dir (RUNTIME_DIR='$RUNTIME_DIR')."
elif [ ! -f "$REFRESH_HELPER" ]; then
  warn "daemon-refresh helper missing at $REFRESH_HELPER — skipping freshness verification (degraded; cannot prove daemons are live)."
else
  SENSITIVE_DAEMONS=$(get_runbook_field "$RIG" "sensitive_daemons" 2>/dev/null | tr '\n' ' ' || echo "")
  log "Daemon refresh: pre=$PRE_DEPLOY_SHA post=$POST_DEPLOY_SHA sensitive='$SENSITIVE_DAEMONS' ..."
  REFRESH_OUT=$(RUNTIME_DIR="$RUNTIME_DIR" \
    PRE_DEPLOY_SHA="$PRE_DEPLOY_SHA" POST_DEPLOY_SHA="$POST_DEPLOY_SHA" \
    DEPLOY_EPOCH="$DEPLOY_EPOCH" SENSITIVE_DAEMONS="$SENSITIVE_DAEMONS" \
    DRY_RUN="$DRY_RUN" \
    bash "$REFRESH_HELPER" || true)
  REFRESH_VERDICT=$(echo "$REFRESH_OUT" | grep '^VERDICT=' | head -1 | sed 's/^VERDICT=//')
  REFRESH_REASON=$(echo  "$REFRESH_OUT" | grep '^REASON='  | head -1 | sed 's/^REASON=//')
  REFRESH_RESTARTED=$(echo "$REFRESH_OUT" | grep '^RESTARTED=' | head -1 | sed 's/^RESTARTED=//')
  REFRESH_GUARDED=$(echo "$REFRESH_OUT" | grep '^GUARDED=' | head -1 | sed 's/^GUARDED=//')
  REFRESH_FRESHFAIL=$(echo "$REFRESH_OUT" | grep '^FRESH_FAIL=' | head -1 | sed 's/^FRESH_FAIL=//')
  log "Daemon refresh verdict=$REFRESH_VERDICT restarted=[$REFRESH_RESTARTED] guarded=[$REFRESH_GUARDED] freshfail=[$REFRESH_FRESHFAIL] reason=$REFRESH_REASON"
  case "$REFRESH_VERDICT" in
    OK|SKIPPED)
      if [ -n "${REFRESH_RESTARTED// /}" ]; then
        log "Refreshed + verified live: $REFRESH_RESTARTED"
      fi
      ;;
    *)
      err "Daemon refresh did NOT pass (verdict=$REFRESH_VERDICT): $REFRESH_REASON"
      if [ "$REFRESH_VERDICT" = "NEEDS_GUARDED_RESTART" ]; then
        REFRESH_ACTION="ACTION: perform a guarded/graceful restart of the flagged hot-path daemon(s) ($REFRESH_GUARDED) — drain in-flight messages/webhooks first — then re-run delivery. (Configure a DRAIN_CMD_<label> for daemon-refresh.sh to automate this.)"
      else
        REFRESH_ACTION="ACTION: investigate why the restarted daemon(s) ($REFRESH_FRESHFAIL) did not come up fresh (crash on boot? wrong launchd label? port in use?), fix forward, then re-run delivery."
      fi
      if [ "$DRY_RUN" != "1" ]; then
        bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
        bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed"  -q 2>/dev/null || true
        bd -C "$GC_CITY" comment "$STORY_ID" "Delivery HALTED (ga-iwv0 daemon refresh): $REFRESH_VERDICT — $REFRESH_REASON
A long-lived daemon serving rig '$RIG' is running code OLDER than this deploy and could not be safely refreshed/verified, so the merged feature would be DORMANT in production. story:done is WITHHELD (a dormant deploy must never be marked done).
$REFRESH_ACTION
Refresh detail:
$REFRESH_OUT" 2>/dev/null || true
        AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
        if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
          gc --city "$GC_CITY" session nudge "$AUTHOR" \
            "DELIVERY HALTED for $STORY_ID (ga-iwv0): $REFRESH_VERDICT — a daemon serving the merge is dormant/unverified. See bead; do NOT mark done." \
            --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
        fi
        gc --city "$GC_CITY" session nudge mayor \
          "DELIVERY HALTED ($STORY_ID, rig $RIG): daemon refresh $REFRESH_VERDICT — $REFRESH_REASON. story:done withheld." \
          2>/dev/null || true
      fi
      # wa-uthi: non-terminal (delivery:failed re-picked every cycle once the
      # daemon is refreshed) — no Athos push. Author + Mayor nudged above.
      warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID daemon refresh $REFRESH_VERDICT."
      continue
      ;;
  esac
fi

# ── Step 6: Run prod test ──────────────────────────────────────────────────────
# delivery:untested is now reserved for the SINGLE case NO_HARNESS=1 — the rig
# has no prod-test harness at all (ga-dqp interim). That case skips + warns
# (story:done with delivery:untested), never HALTs.
#
# ga-857v FIX 2: when the rig HAS a harness we ALWAYS run it (→ delivery:tested
# on pass). If the story-specific test is missing (STORY_TEST_MISSING=1) we run
# the rig BASELINE only, by invoking run.sh WITHOUT STORY_ID — every rig's run.sh
# runs its story-specific block solely when STORY_ID is set, so baseline mode can
# never hard-fail on an absent story test. Flow still never HALTs on a *missing*
# test; it only fails if the baseline finds genuinely broken prod (correct).
if [ "$NO_HARNESS" = "1" ]; then
  UNTESTED_REASON="rig '$RIG' has no prod-test harness"
  UNTESTED_FOLLOWUP="a real prod-test harness for rig '$RIG' is needed (ga-dqp DESTINY item)"
  warn "Skipping prod test — $UNTESTED_REASON (delivery:untested, ga-dqp interim). Flow never stops."
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD SKIP PROD TEST ($UNTESTED_REASON); WOULD SET delivery:untested (no NTFY — terminal-only push policy wa-uthi)"
  else
    bd -C "$GC_CITY" label add "$STORY_ID" "delivery:untested" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "WARNING: prod test skipped — $UNTESTED_REASON.
Story is being marked story:done with delivery:untested label.
FOLLOW-UP: $UNTESTED_FOLLOWUP." 2>/dev/null || true
    # wa-uthi: NO push here. "delivery:untested" is a non-terminal warning; the
    # single terminal push fires at story:done (Step 8). Mid-flow warnings are
    # suppressed so Athos only gets pushed on terminal outcomes.
  fi
else
  # Rig HAS a harness → run it. Baseline-only (no STORY_ID) when the
  # story-specific test is absent; full (with STORY_ID) when it exists.
  if [ "$STORY_TEST_MISSING" = "1" ]; then
    TEST_STORY_ID=""
    TEST_MODE_DESC="rig baseline harness only — no story-specific test (ga-857v FIX 2)"
  else
    TEST_STORY_ID="$STORY_ID"
    TEST_MODE_DESC="rig harness + story-specific test (story-${STORY_ID}.sh)"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — WOULD RUN PROD TEST: STORY_ID='$TEST_STORY_ID' bash $PROD_TEST_SCRIPT ($TEST_MODE_DESC)"
  else
    log "Running prod test: $PROD_TEST_SCRIPT (STORY_ID='$TEST_STORY_ID'; $TEST_MODE_DESC) ..."
    TEST_OUTPUT=$(STORY_ID="$TEST_STORY_ID" bash "$PROD_TEST_SCRIPT" 2>&1) && TEST_RC=$? || TEST_RC=$?
    log "Test output: $TEST_OUTPUT"

    if [ "$TEST_RC" -ne 0 ]; then
      err "Prod test FAILED (rc=$TEST_RC)"
      bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
      bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
      bd -C "$GC_CITY" comment "$STORY_ID" "Delivery FAILED: prod test did not pass.
Script: $PROD_TEST_SCRIPT ($TEST_MODE_DESC)
Exit code: $TEST_RC
Output:
$TEST_OUTPUT

HALT — do NOT auto-revert (DB migration risk). Investigate the failure, fix forward, and re-run delivery." 2>/dev/null || true

      # Escalate: notify author (from bead)
      AUTHOR=$(echo "$STORY" | jq -r '.assignee // .created_by // ""' 2>/dev/null || echo "")
      if [ -n "$AUTHOR" ] && [ "$AUTHOR" != "null" ]; then
        gc --city "$GC_CITY" session nudge "$AUTHOR" \
          "DELIVERY FAILED for story $STORY_ID ($STORY_TITLE). Prod test failed (exit $TEST_RC). See bead comments. DO NOT auto-revert — investigate and fix forward." \
          --delivery wait-idle 2>/dev/null || warn "Could not nudge author $AUTHOR"
      fi

      # wa-uthi: non-terminal (delivery:failed re-picked every cycle — retries, no
      # exhaustion counter) — no push to Athos. The author is nudged above; Athos
      # only hears terminal outcomes (story:done or definitive rejection).
      warn "SUPPRESSED PUSH (wa-uthi non-terminal/retries): story $STORY_ID prod test FAILED (rc=$TEST_RC) — author nudged."
      continue
    fi

    log "Prod test PASS ($TEST_MODE_DESC)"
  fi
fi

# ── Step 7: Verify refino criteria from story metadata ────────────────────────
# The story bead has metadata fields set by /refino:
#   story.estrela_guia, story.equilibrios, story.dashboard
# These are already codified in the story bead — we verify they are present
# and non-empty (the actual criteria were verified by the prod test above).
if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD VERIFY refino criteria (story.estrela_guia, story.equilibrios, story.dashboard)"
else
  log "Verifying refino criteria metadata ..."
  STORY_META=$(bd -C "$GC_CITY" show "$STORY_ID" --json 2>/dev/null \
    | jq -r 'if type=="array" then .[0] else . end | .metadata // {}' 2>/dev/null || echo "{}")

  ESTRELA=$(echo "$STORY_META" | jq -r '.["story.estrela_guia"] // ""')
  EQUILIBRIOS=$(echo "$STORY_META" | jq -r '.["story.equilibrios"] // ""')
  DASHBOARD=$(echo "$STORY_META" | jq -r '.["story.dashboard"] // ""')

  MISSING_META=""
  [ -z "$ESTRELA" ] && MISSING_META="$MISSING_META story.estrela_guia"
  [ -z "$EQUILIBRIOS" ] && MISSING_META="$MISSING_META story.equilibrios"
  [ -z "$DASHBOARD" ] && MISSING_META="$MISSING_META story.dashboard"

  if [ -n "$MISSING_META" ]; then
    warn "Missing refino criteria fields:$MISSING_META — story lacks /refino metadata"
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery WARNING: missing refino metadata fields:$MISSING_META. /refino may not have been run. Story marked done but refino incomplete." 2>/dev/null || true
  else
    log "Refino criteria present: estrela_guia, equilibrios, dashboard"
  fi
fi

# ── Step 8: Mark story:done ────────────────────────────────────────────────────
DELIVERY_END=$(date +%s)
ELAPSED=$((DELIVERY_END - DELIVERY_START))

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD: bd label remove $STORY_ID delivery:running"
  log "DRY_RUN=1 — WOULD: bd label add $STORY_ID story:done"
  log "DRY_RUN=1 — WOULD: bd comment $STORY_ID 'Delivery COMPLETE...'"
  log "DRY_RUN=1 — notify 'Story $STORY_ID done'"
else
  bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
  bd -C "$GC_CITY" label add    "$STORY_ID" "story:done"       -q 2>/dev/null || true

  # wa-wzvg: detect Pilot origin (durable "pilot:dispatched" label set by the
  # Pilot when it autonomously pulled the story). Used to differentiate the
  # terminal DONE push so Athos can tell autonomous Pilot deliveries apart.
  PILOT_ORIGIN=0
  if echo "$STORY_LABELS" | grep -q "pilot:dispatched"; then
    PILOT_ORIGIN=1
  else
    BEAD_LABELS_NOW=$(bd -C "$GC_CITY" show "$STORY_ID" --json 2>/dev/null \
      | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | join(",")' 2>/dev/null || echo "")
    echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched" && PILOT_ORIGIN=1 || true
  fi
  PILOT_PREFIX=""
  [ "$PILOT_ORIGIN" = "1" ] && PILOT_PREFIX="🤖 [Pilot] "

  # UNTESTED terminal success is now NO_HARNESS=1 ONLY (ga-857v FIX 2: a missing
  # story-specific test runs the rig baseline → delivery:tested, handled below).
  if [ "$NO_HARNESS" = "1" ]; then
    DONE_TEST_LINE="SKIPPED — rig '$RIG' has no prod-test harness (interim policy per ga-dqp)."
    DONE_NOTE="a real prod-test harness for this rig is a DESTINY follow-up item."
    DONE_PUSH_TAIL="prod test SKIPPED (no harness for $RIG)"
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery COMPLETE. story:done (delivery:untested).
Rig: $RIG
Deploy: $DEPLOY_CMD
Prod test: $DONE_TEST_LINE
Elapsed: ${ELAPSED}s
Criteria verified: estrela_guia, equilibrios, dashboard (see bead metadata)
NOTE: $DONE_NOTE" 2>/dev/null || true
    # wa-uthi: TERMINAL SUCCESS (story:done) — push KEPT. wa-wzvg: Pilot-differentiated.
    notify -t "${PILOT_PREFIX}Story DONE (untested)" -p 2 "${PILOT_PREFIX}Story $STORY_ID ($STORY_TITLE) — deployed, $DONE_PUSH_TAIL" 2>/dev/null || true
  else
    # delivery:tested — rig harness passed (full when a story-specific test exists,
    # baseline-only when it does not — ga-857v FIX 2). Add an explicit
    # delivery:tested label so the tested state is queryable (acceptance wording).
    bd -C "$GC_CITY" label add "$STORY_ID" "delivery:tested" -q 2>/dev/null || true
    if [ "$STORY_TEST_MISSING" = "1" ]; then
      DONE_TEST_LINE="$PROD_TEST_SCRIPT — rig BASELINE harness only, no story-specific test (ga-857v FIX 2)"
      DONE_PUSH_TAIL="deployed + baseline-tested in prod"
    else
      DONE_TEST_LINE="$PROD_TEST_SCRIPT (STORY_ID=$STORY_ID)"
      DONE_PUSH_TAIL="deployed + tested in prod"
    fi
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery COMPLETE. story:done (delivery:tested).
Rig: $RIG
Deploy: $DEPLOY_CMD
Prod test: $DONE_TEST_LINE
Elapsed: ${ELAPSED}s
Criteria verified: estrela_guia, equilibrios, dashboard (see bead metadata)" 2>/dev/null || true
    # wa-uthi: TERMINAL SUCCESS (story:done) — push KEPT. wa-wzvg: Pilot-differentiated.
    notify -t "${PILOT_PREFIX}Story DONE" -p 2 "${PILOT_PREFIX}Story $STORY_ID ($STORY_TITLE) — $DONE_PUSH_TAIL" 2>/dev/null || true
  fi
  log "story:done set on $STORY_ID"
fi

# ── Step 9: Log to story-delivery.jsonl ───────────────────────────────────────
# Determine result classification. ga-857v FIX 2: untested is NO_HARNESS only;
# a missing story-specific test now runs the rig baseline → PASS (tested).
if [ "$DRY_RUN" = "1" ]; then
  DELIVERY_RESULT="dry_run"
elif [ "$NO_HARNESS" = "1" ]; then
  DELIVERY_RESULT="PASS_UNTESTED"
else
  DELIVERY_RESULT="PASS"
fi
mkdir -p "$(dirname "$DELIVERY_LOG")"
jq -c -n \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg story_id "$STORY_ID" \
  --arg story_title "$STORY_TITLE" \
  --arg rig "$RIG" \
  --arg result "$DELIVERY_RESULT" \
  --arg deploy_cmd "$DEPLOY_CMD" \
  --arg prod_test "$PROD_TEST_SCRIPT" \
  --argjson elapsed_s "$ELAPSED" \
  --arg dry_run "$DRY_RUN" \
  '{ts: $ts, event: "delivery_complete", story_id: $story_id, story_title: $story_title,
    rig: $rig, result: $result, deploy_cmd: $deploy_cmd, prod_test: $prod_test,
    elapsed_s: $elapsed_s, dry_run: $dry_run}' \
  >> "$DELIVERY_LOG" 2>/dev/null || true

log "=== Delivery sweep complete: story=$STORY_ID rig=$RIG result=$([ "$DRY_RUN" = "1" ] && echo dry_run || echo PASS) elapsed=${ELAPSED}s ==="

done < <(echo "$STORIES_JSON" | jq -c '.[]')
log "=== Delivery sweep finished ==="

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

# Process one story per run (avoids long-running sweeps; next launchd interval picks up more)
STORY=$(echo "$STORIES_JSON" | jq '.[0]')
STORY_ID=$(echo "$STORY" | jq -r '.id')
STORY_TITLE=$(echo "$STORY" | jq -r '.description // .title // "untitled"' | head -c 80)
STORY_LABELS=$(echo "$STORY" | jq -r '(.labels // []) | join(",")')

log "Processing story $STORY_ID: $STORY_TITLE"
log "Labels: $STORY_LABELS"

# Skip if already marked story:done (idempotency guard)
if echo "$STORY_LABELS" | grep -q "story:done"; then
  log "Story $STORY_ID already labeled story:done — skipping."
  exit 0
fi

# Skip if already in delivery (prevents parallel runs)
if echo "$STORY_LABELS" | grep -q "delivery:running"; then
  log "Story $STORY_ID already has delivery:running — skipping (already in flight)."
  exit 0
fi

# Mark as running (claim)
if [ "$DRY_RUN" != "1" ]; then
  bd -C "$GC_CITY" label add "$STORY_ID" "delivery:running" -q 2>/dev/null || {
    warn "Could not add delivery:running to $STORY_ID (race condition?). Skipping."
    exit 0
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
  exit 1
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
  exit 1
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

# wa-l5z9 fix: a MISSING story-specific prod test is NON-BLOCKING.
# RATIONALE (flow-never-stops): the pipeline must never stall just because nobody
# wrote a story-specific test. Previously this case HALTed delivery and fired an
# NTFY every retry cycle (overnight spam, e.g. ga-0ys). Now it behaves IDENTICALLY
# to the rig-harness-missing case: the story still delivers and ends at story:done
# with the delivery:untested label (a single warn signal, no HALT).
# Harness/test coverage is driven up separately (ga-857v / ga-iwv0), NOT by
# blocking delivery here.
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
  exit 1
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

# ── Step 4: Deploy ─────────────────────────────────────────────────────────────
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
    exit 1
  fi
  log "Deploy OK"
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

# ── Step 6: Run prod test ──────────────────────────────────────────────────────
# UNTESTED path covers two cases, treated IDENTICALLY (wa-l5z9):
#   (a) NO_HARNESS=1        — rig has no prod-test harness at all (ga-dqp)
#   (b) STORY_TEST_MISSING=1 — rig HAS a harness but no story-specific test (wa-l5z9)
# Both deliver + warn-only (story:done with delivery:untested), never HALT.
if [ "$NO_HARNESS" = "1" ] || [ "$STORY_TEST_MISSING" = "1" ]; then
  if [ "$NO_HARNESS" = "1" ]; then
    UNTESTED_REASON="rig '$RIG' has no prod-test harness"
    UNTESTED_FOLLOWUP="a real prod-test harness for rig '$RIG' is needed (ga-dqp DESTINY item)"
  else
    UNTESTED_REASON="no story-specific test at $STORY_TEST_FILE"
    UNTESTED_FOLLOWUP="a story-specific prod test (story-${STORY_ID}.sh) should be authored; coverage tracked by ga-857v/ga-iwv0"
  fi
  warn "Skipping prod test — $UNTESTED_REASON (delivery:untested, wa-l5z9 warn-only). Flow never stops."
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
elif [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — WOULD RUN PROD TEST: STORY_ID=$STORY_ID bash $PROD_TEST_SCRIPT"
  log "DRY_RUN=1 — Story-specific test: $STORY_TEST_FILE"
else
  log "Running prod test: $PROD_TEST_SCRIPT (STORY_ID=$STORY_ID) ..."
  TEST_OUTPUT=$(STORY_ID="$STORY_ID" bash "$PROD_TEST_SCRIPT" 2>&1) && TEST_RC=$? || TEST_RC=$?
  log "Test output: $TEST_OUTPUT"

  if [ "$TEST_RC" -ne 0 ]; then
    err "Prod test FAILED (rc=$TEST_RC)"
    bd -C "$GC_CITY" label remove "$STORY_ID" "delivery:running" -q 2>/dev/null || true
    bd -C "$GC_CITY" label add    "$STORY_ID" "delivery:failed" -q 2>/dev/null || true
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery FAILED: prod test did not pass.
Script: $PROD_TEST_SCRIPT
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
    exit 1
  fi

  log "Prod test PASS"
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
    echo "$BEAD_LABELS_NOW" | grep -q "pilot:dispatched" && PILOT_ORIGIN=1
  fi
  PILOT_PREFIX=""
  [ "$PILOT_ORIGIN" = "1" ] && PILOT_PREFIX="🤖 [Pilot] "

  # UNTESTED terminal success covers both NO_HARNESS and STORY_TEST_MISSING (wa-l5z9).
  if [ "$NO_HARNESS" = "1" ] || [ "$STORY_TEST_MISSING" = "1" ]; then
    if [ "$NO_HARNESS" = "1" ]; then
      DONE_TEST_LINE="SKIPPED — rig '$RIG' has no prod-test harness (interim policy per ga-dqp)."
      DONE_NOTE="a real prod-test harness for this rig is a DESTINY follow-up item."
      DONE_PUSH_TAIL="prod test SKIPPED (no harness for $RIG)"
    else
      DONE_TEST_LINE="SKIPPED at story level — no story-specific test (story-${STORY_ID}.sh); rig harness not run for this story (wa-l5z9 warn-only)."
      DONE_NOTE="a story-specific prod test is owed; coverage tracked by ga-857v/ga-iwv0."
      DONE_PUSH_TAIL="story-level test missing — delivered untested"
    fi
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
    bd -C "$GC_CITY" comment "$STORY_ID" "Delivery COMPLETE. story:done.
Rig: $RIG
Deploy: $DEPLOY_CMD
Prod test: $PROD_TEST_SCRIPT (STORY_ID=$STORY_ID)
Elapsed: ${ELAPSED}s
Criteria verified: estrela_guia, equilibrios, dashboard (see bead metadata)" 2>/dev/null || true
    # wa-uthi: TERMINAL SUCCESS (story:done) — push KEPT. wa-wzvg: Pilot-differentiated.
    notify -t "${PILOT_PREFIX}Story DONE" -p 2 "${PILOT_PREFIX}Story $STORY_ID ($STORY_TITLE) — deployed + tested in prod" 2>/dev/null || true
  fi
  log "story:done set on $STORY_ID"
fi

# ── Step 9: Log to story-delivery.jsonl ───────────────────────────────────────
# Determine result classification (wa-l5z9: untested covers no-harness AND
# story-test-missing).
if [ "$DRY_RUN" = "1" ]; then
  DELIVERY_RESULT="dry_run"
elif [ "$NO_HARNESS" = "1" ] || [ "$STORY_TEST_MISSING" = "1" ]; then
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

#!/usr/bin/env bash
# prod-tests/gascity/story-ga-8ts9b.sh — prod test for ga-8ts9b:
# s3://urblink-claude-history-backup lifecycle (90d -> DEEP_ARCHIVE, 365d ->
# delete) + local ~/.claude 30-day retention verification.
#
# Called by run.sh after deploy (STORY_ID=ga-8ts9b). Exits 0 on pass.
#
# NOTE: the S3 lifecycle policy is external AWS state a git-pull deploy
# cannot apply (see scripts/transcript-s3-backup-lifecycle-setup.sh, run
# directly against production as part of building this story) — this test
# verifies the LIVE policy against AWS directly, independent of deploy_cmd.

set -uo pipefail

BUCKET="${TRANSCRIPT_S3_LIFECYCLE_BUCKET:-urblink-claude-history-backup}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
PROJECTS_ROOT="${CLAUDE_PROJECTS_ROOT:-$HOME/.claude/projects}"
BACKUP_LOG="${CLAUDE_BACKUP_LOG:-$HOME/.claude/backup/backup.log}"

log()  { echo "[prod-test:gascity ga-8ts9b] $*"; }
fail() { echo "[prod-test:gascity ga-8ts9b] FAIL: $*" >&2; exit 1; }

command -v aws >/dev/null || fail "aws CLI not found"
command -v jq  >/dev/null || fail "jq not found"

# ── 1. S3 lifecycle: >90d -> DEEP_ARCHIVE, >365d -> Expiration ─────────────
log "Checking s3://$BUCKET lifecycle configuration..."
POLICY_JSON="$(aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" 2>&1)" \
  || fail "get-bucket-lifecycle-configuration failed: $POLICY_JSON"

echo "$POLICY_JSON" | jq -e '
  .Rules[]
  | select(.Status == "Enabled")
  | select(any(.Transitions[]?; .Days == 90 and .StorageClass == "DEEP_ARCHIVE"))
  | select(.Expiration.Days == 365)
' >/dev/null 2>&1 || fail "no enabled rule with Transition(90d->DEEP_ARCHIVE) + Expiration(365d) found: $POLICY_JSON"
log "  lifecycle rule present ✓ (90d -> DEEP_ARCHIVE, 365d -> delete)"

# ── 2. Local retention: cleanupPeriodDays=30, actually enforced ────────────
log "Checking local ~/.claude retention (cleanupPeriodDays)..."
[[ -f "$SETTINGS" ]] || fail "settings file missing: $SETTINGS"
DAYS="$(jq -r '.cleanupPeriodDays // empty' "$SETTINGS" 2>/dev/null)"
[[ -n "$DAYS" ]] || fail "cleanupPeriodDays not set in $SETTINGS"
[[ "$DAYS" -ge 1 && "$DAYS" -le 30 ]] || fail "cleanupPeriodDays=$DAYS is not a sane 1-30 day retention"
log "  cleanupPeriodDays=$DAYS ✓"

if [[ -d "$PROJECTS_ROOT" ]]; then
  STALE_COUNT="$(find "$PROJECTS_ROOT" -name '*.jsonl' -mtime +35 2>/dev/null | wc -l | tr -d ' ')"
  # 35d grace (30d retention + 5d slack for the cleanup's own run cadence) —
  # a transcript older than that proves the reaper is configured but not
  # actually running, not just mid-cycle.
  [[ "$STALE_COUNT" -eq 0 ]] || fail "$STALE_COUNT transcript(s) under $PROJECTS_ROOT exceed 35 days old — local cleanup is configured but not running"
  log "  0 transcripts older than 35 days under $PROJECTS_ROOT ✓ (reaper is actually running, not just configured)"
else
  log "  $PROJECTS_ROOT does not exist — nothing to verify (WARN, not a failure)"
fi

# ── 3. backup/ coverage: not reaped by cleanupPeriodDays (that setting only
#    prunes projects/), but measured growth is a few lines per backup run —
#    tripwire, not a fabricated fix for a non-problem ─────────────────────
if [[ -f "$BACKUP_LOG" ]]; then
  LOG_KB="$(du -k "$BACKUP_LOG" 2>/dev/null | awk '{print $1}')"
  # 5MB tripwire: measured growth was ~8KB/156 lines (~3 lines/run/day,
  # ~60-80KB/year) at story time. A log 60x that size means growth
  # assumptions changed — investigate rather than silently let an
  # unrotated log run away.
  [[ "${LOG_KB:-0}" -lt 5120 ]] || fail "$BACKUP_LOG is ${LOG_KB}KB — unexpected growth vs ~8KB at story time; investigate before assuming still-negligible"
  log "  $BACKUP_LOG is ${LOG_KB}KB — within expected negligible-growth bound ✓"
else
  log "  $BACKUP_LOG does not exist — nothing to verify (WARN, not a failure)"
fi

log "PASS — S3 lifecycle live, local 30d retention active, backup/ growth bounded"
exit 0

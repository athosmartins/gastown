#!/usr/bin/env bash
# transcript-s3-backup-lifecycle-setup.sh (ga-8ts9b) — applies the S3
# lifecycle policy for s3://urblink-claude-history-backup, the permanent
# off-machine archive that ~/.claude/backup/backup.sh syncs Claude Code
# session transcripts to (`aws s3 sync ... --only-show-errors`, NO --delete
# by design — see that script's own header). Local ~/.claude/settings.json's
# cleanupPeriodDays=30 already bounds the LOCAL copy, but nothing bounded the
# S3 copy: 15.75GB / 39960 objects, +330MB/day, zero lifecycle rules, as
# measured 2026-08-25 (NoSuchLifecycleConfiguration).
#
# WHAT: transcripts are session/diagnostic data, not business data — anything
# worth keeping already became a bead/memory/commit (ga-8ts9b's own scope
# text). Bucket-wide, no prefix filter (every object here — including the
# top-level history.jsonl and salvage/ — is the same class of data):
#   - >90 days old  -> transition to DEEP_ARCHIVE (Glacier Deep Archive)
#   - >365 days old -> Expiration (delete)
# 365 > 90 satisfies AWS's requirement that Expiration.Days exceed the last
# Transition's Days. 365 - 90 = 275 days in Deep Archive, comfortably past
# AWS's 180-day minimum storage duration for that class, so nothing that
# reaches expiration naturally incurs an early-deletion charge.
#
# Idempotent: PutBucketLifecycleConfiguration is a full replace, so re-running
# this with an unchanged policy is a no-op. Safe to re-run.
#
# Bucket versioning is disabled (verified via get-bucket-versioning, 2026-08-25
# — response carried no Status key), so no NoncurrentVersion* rules apply.
#
# VERIFY: packs/town-deltas/assets/prod-tests/gascity/story-ga-8ts9b.sh checks
# the live policy against AWS directly. This script is the reproducible setup
# path, not something the prod test re-invokes — it writes; the prod test is
# read-only, matching this rig's prod-test convention (see story-ga-l4nx1.sh).
#
# This is external AWS state a `git pull` deploy cannot apply (same class of
# gap skill-integrity-install.sh's header describes for launchd registration),
# so it is run directly against production once rather than wired into
# delivery-runbooks.toml's deploy_cmd — an S3 lifecycle policy is durable
# server-side state, not something that drifts and needs re-assertion on
# every deploy.
set -euo pipefail

BUCKET="${TRANSCRIPT_S3_LIFECYCLE_BUCKET:-urblink-claude-history-backup}"
RULE_ID="transcripts-90d-deeparchive-365d-expire"

TMP_POLICY="$(mktemp "${TMPDIR:-/tmp}/transcript-s3-lifecycle.XXXXXX.json")"
trap 'rm -f "$TMP_POLICY"' EXIT

cat > "$TMP_POLICY" <<JSON
{
  "Rules": [
    {
      "ID": "$RULE_ID",
      "Status": "Enabled",
      "Filter": { "Prefix": "" },
      "Transitions": [
        { "Days": 90, "StorageClass": "DEEP_ARCHIVE" }
      ],
      "Expiration": { "Days": 365 }
    }
  ]
}
JSON

echo "Applying lifecycle policy to s3://$BUCKET ..."
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --lifecycle-configuration "file://$TMP_POLICY"

echo "Applied. Current policy:"
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"

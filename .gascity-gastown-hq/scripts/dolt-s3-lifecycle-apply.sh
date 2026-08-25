#!/bin/bash
# dolt-s3-lifecycle-apply.sh (ga-jz7gg, scope item 2) — idempotently applies
# the S3 lifecycle policy for the versioned Dolt backup bucket.
#
# WHY: dolt-backup-reseed.sh (ga-ydrg9) re-uploads the backup content wholesale
# on every reseed (new content-addressed filenames), so each reseed leaves the
# prior objects as NONCURRENT versions in this versioned bucket. Without a
# bound on how long those linger, the backup bucket itself becomes the new
# unbounded accumulator the reseed mechanism exists to eliminate locally.
#
# MEASURED 25/08: the bucket already carried an UNDOCUMENTED lifecycle rule
# (expire-noncurrent-versions-90d) applied out-of-band — zero references to it
# anywhere in this repo before this script (grepped put-bucket-lifecycle-
# configuration / lifecycle.json / NoncurrentVersionExpiration tree-wide).
# 90d is looser than this story's 30d target and doesn't match this city's
# other 25/08 retention decisions (Athos's own decision on the sibling
# hourly/daily S3 backup stream: 30d daily-tier cutover — epic ga-sfj3i). This
# script tightens it to 30d and, from here on, the policy is versioned and
# re-appliable instead of living only in S3 as tribal knowledge nobody can
# see or diff.
#
# SAFE BY CONSTRUCTION: NoncurrentVersionExpiration only ever targets
# NONCURRENT (already-superseded) object versions — there is no Expiration
# rule for the CURRENT version in this policy, so even a wrong NoncurrentDays
# value can shrink the recovery window, never delete the live backup itself.
#
# Idempotent: re-running with the same NONCURRENT_DAYS reapplies the same
# policy (S3 lifecycle PUT is a full replace, not a patch — this script always
# sends the complete rule set, so the unrelated abort-incomplete-multipart
# rule is preserved verbatim, never dropped).
set -uo pipefail

BUCKET="${DOLT_S3_BACKUP_BUCKET:-urblink-dolt-backups}"
NONCURRENT_DAYS="${DOLT_S3_NONCURRENT_EXPIRY_DAYS:-30}"
AWS_BIN="${AWS_BIN:-aws}"

log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') [s3-lifecycle] $*"; }
die()  { log "ABORT: $*"; exit 1; }

POLICY=$(cat <<JSON
{
  "Rules": [
    {
      "ID": "abort-incomplete-multipart",
      "Filter": {},
      "Status": "Enabled",
      "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
    },
    {
      "ID": "expire-noncurrent-versions-${NONCURRENT_DAYS}d",
      "Filter": {},
      "Status": "Enabled",
      "NoncurrentVersionExpiration": { "NoncurrentDays": ${NONCURRENT_DAYS} }
    }
  ]
}
JSON
)

# Refuse to apply a noncurrent-version rule blind — it only means something on
# a versioned bucket, and the "prose says versioned" doctrine that led this
# bucket to grow undetected once already is exactly what this check replaces.
VERSIONING=$("$AWS_BIN" s3api get-bucket-versioning --bucket "$BUCKET" --query Status --output text 2>/dev/null)
[ "$VERSIONING" = "Enabled" ] || die "bucket '$BUCKET' versioning is '${VERSIONING:-EMPTY/unreadable}', not Enabled — NoncurrentVersionExpiration is meaningless here; refusing to apply blind"

log "applying lifecycle to '$BUCKET': abort-incomplete-multipart=7d, expire-noncurrent-versions=${NONCURRENT_DAYS}d"
echo "$POLICY" | "$AWS_BIN" s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration file:///dev/stdin \
  || die "put-bucket-lifecycle-configuration failed"

# Verify the ARTIFACT, not the API call's exit code — a 200 response does not
# by itself prove S3 stored the rule set we intended.
ACTUAL_DAYS=$("$AWS_BIN" s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query "Rules[?ID=='expire-noncurrent-versions-${NONCURRENT_DAYS}d'].NoncurrentVersionExpiration.NoncurrentDays" --output text 2>/dev/null)
[ "$ACTUAL_DAYS" = "$NONCURRENT_DAYS" ] || die "post-apply verification failed: expected NoncurrentDays=$NONCURRENT_DAYS, live bucket reports '${ACTUAL_DAYS:-EMPTY/unreadable}'"
log "confirmed live: NoncurrentVersionExpiration.NoncurrentDays=$ACTUAL_DAYS"
log "=== lifecycle policy applied and verified for '$BUCKET' ==="

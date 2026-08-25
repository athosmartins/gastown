# S3 lifecycle: `urblink-claude-history-backup` (ga-8ts9b)

**Applied:** 2026-08-25. Part of the P0 STORAGE program (epic `ga-sfj3i`).

## What this bucket is

`~/.claude/backup/backup.sh` (lives outside any git repo — local-only file on
the mini, installed via `~/Library/LaunchAgents/com.athos.claude-history-backup.plist`,
daily 4:00 AM) does `aws s3 sync ~/.claude/projects s3://urblink-claude-history-backup/projects/`
with **no `--delete`**, plus a `cp` of `~/.claude/history.jsonl`. It exists so
Claude Code session transcripts survive past the local 30-day cleanup (see
below) — by design it is a complete, permanent, ever-growing archive.

As of story time: 15.75GB / 39,960 objects, +330MB/day, **zero lifecycle
rules** (`NoSuchLifecycleConfiguration`).

## What was applied

Bucket-wide lifecycle rule (every object — `projects/*`, `salvage/*`, the
top-level `history.jsonl` — is the same class of data: session/diagnostic
history, not business data; anything worth keeping already became a
bead/memory/commit):

```json
{
  "Rules": [{
    "ID": "transcripts-90d-deeparchive-365d-expire",
    "Status": "Enabled",
    "Filter": { "Prefix": "" },
    "Transitions": [{ "Days": 90, "StorageClass": "DEEP_ARCHIVE" }],
    "Expiration": { "Days": 365 }
  }]
}
```

- **>90 days** → transitions to Glacier Deep Archive. AWS's default
  `TransitionDefaultMinimumObjectSize` (`all_storage_classes_128K`) applies —
  objects under 128KB stay in Standard rather than transitioning (AWS's own
  cost protection: archiving tiny objects usually costs more than leaving
  them). They still expire normally at 365 days regardless of size.
- **>365 days** → deleted. 365 > 90 satisfies AWS's rule that Expiration.Days
  must exceed the last Transition's Days; 365 − 90 = 275 days in Deep Archive,
  past AWS's 180-day minimum storage duration, so nothing that expires
  naturally incurs an early-deletion charge.
- Bucket versioning is disabled (verified via `get-bucket-versioning` — no
  `Status` key in the response), so no `NoncurrentVersion*` rules are needed.

**Setup script (idempotent, safe to re-run):**
`scripts/transcript-s3-backup-lifecycle-setup.sh`

**Verify live state:**
```bash
aws s3api get-bucket-lifecycle-configuration --bucket urblink-claude-history-backup
```
Also covered by `packs/town-deltas/assets/prod-tests/gascity/story-ga-8ts9b.sh`
(runs in the gascity rig's prod-test suite).

## Local retention (the other half of ga-8ts9b's scope)

`~/.claude/settings.json`'s `cleanupPeriodDays: 30` governs `~/.claude/projects/`
(session transcripts) — confirmed both configured **and actually enforced**:
0 of 455 local `.jsonl` files exceed 30 days old at story time. This is why
local usage (471MB in `projects/`) stays far below the unbounded S3 copy.

**`~/.claude/backup/` is NOT covered** by `cleanupPeriodDays` — that setting
is Claude Code's own session-transcript housekeeping, scoped to `projects/`
and similar Claude-managed state; it has no reason to know about a
user-created `backup/` directory. In practice this is not a real leak:
`backup.log` (the only thing that grows there) was 8KB / 156 lines after 7
weeks of daily runs (~3 lines/run/day, ~60-80KB/year) — negligible, so no
rotation was added for a non-problem. The prod test carries a 5MB tripwire
on this file instead, in case growth assumptions ever change.

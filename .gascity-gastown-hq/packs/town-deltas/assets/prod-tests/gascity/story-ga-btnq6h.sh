#!/usr/bin/env bash
# prod-tests/gascity/story-ga-btnq6h.sh — prod test for ga-btnq6h: hq's Dolt backup could not
# restore (S3 copy broken since 09-21) and the dolt_gc that would shrink hq could not run
# (53 consecutive headroom skips) because ~8.8 GB of redundant local backup staging sat on a
# disk that never has the 2x headroom the GC needs.
#
# What shipped, and what this test proves about each part:
#   1. dolt-backup-s3-proof.sh — manifest-closure proof of a Dolt backup (local dir + S3).
#   2. dolt-s3-backup.sh       — the nightly now mirrors the existing staging to S3 even when
#                                its disk preflight refuses today's sync (it used to `continue`
#                                past that step too, so S3 was never repaired).
#   3. dolt-gc-maintenance.sh  — on a CHRONIC headroom skip, and only under a fresh S3 proof,
#                                release hq's local staging so the GC gate can be met.
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-btnq6h). Exits 0 on pass. Asserts
# against the LIVE deployed tree ($CITY/scripts — gascity's scripts run in place, so
# "deployed" means present on disk there) and against live external state (S3) where a file
# check alone cannot show the defect is gone.
#
# NOT asserted here, on purpose: that dolt_gc has RUN and hq shrank. That is time-dependent
# (it waits for a 2h cycle that happens to see enough free space) and would fail every
# delivery made before then. It is tracked by the story's follow-up verification bead
# instead. Everything that CAN be known at delivery time is checked below.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BUCKET="${DOLT_S3_BACKUP_BUCKET:-urblink-dolt-backups}"
AWS_BIN="${AWS_BIN:-$(command -v aws 2>/dev/null || echo /opt/homebrew/bin/aws)}"
SCRIPTS="$CITY/scripts"

log()  { echo "[prod-test:gascity ga-btnq6h] $*"; }
fail() { echo "[prod-test:gascity ga-btnq6h] FAIL: $*" >&2; exit 1; }

# macOS /bin/bash is 3.2 and is what the launchd jobs and the gate use; Homebrew bash 5
# accepts syntax 3.2 rejects, so check with the interpreter that actually runs these.
BASH32=/bin/bash
[[ -x "$BASH32" ]] || fail "$BASH32 not found — cannot syntax-check under the interpreter the jobs run with"

PROOF="$SCRIPTS/dolt-backup-s3-proof.sh"
GCM="$SCRIPTS/dolt-gc-maintenance.sh"
NIGHTLY="$SCRIPTS/dolt-s3-backup.sh"

# ── 1. The deployed files exist and parse under bash 3.2 ─────────────────────────────
for f in "$PROOF" "$GCM" "$NIGHTLY"; do
  [[ -f "$f" ]] || fail "deployed file missing: $f (the merge did not reach the running tree)"
  "$BASH32" -n "$f" 2>/dev/null || fail "$f does not parse under $BASH32 (3.2) — the launchd job would die on start"
done
log "proof lib, gc-maintenance and nightly backup are deployed and parse under bash 3.2"

# ── 2. The pieces are WIRED, not just present ────────────────────────────────────────
# A defined-but-never-called function is the classic dormant fix (a present file is not a
# live feature). shellcheck-style literal greps: `\$` matches a literal $ on this grep.
grep -q 'dolt-backup-s3-proof.sh' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh never sources dolt-backup-s3-proof.sh — the release could never prove S3"
grep -q '_gc_maybe_release_staging "\$size_mb" "\$avail_mb" "\$required_mb"' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh defines the staging release but main() never calls it"
grep -q '_gc_headroom_ok "\$avail_mb" "\$size_mb" "\$GC_MIN_FREE_PCT"' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh lost its headroom gate"
# The release must sit in the SKIP branch and re-gate afterwards (never lowers the gate).
grep -q 'the gate is NOT lowered' "$GCM" \
  || fail "deployed dolt-gc-maintenance.sh does not re-check the same headroom gate after a release"
grep -q 'dolt-backup-s3-proof.sh' "$NIGHTLY" \
  || fail "deployed dolt-s3-backup.sh never sources dolt-backup-s3-proof.sh"
grep -q '_mirror_staging_after_disk_refusal "\$db" "\$dest"' "$NIGHTLY" \
  || fail "deployed dolt-s3-backup.sh defines the refusal-branch S3 mirror but the disk-refusal path never calls it"
log "release wired into dolt-gc-maintenance main() (gated + re-checked); refusal-branch mirror wired into the nightly"

# ── 3. The regression suites pass against the LIVE tree ──────────────────────────────
run_suite() {  # run_suite <script-basename>
  local name="$1" out
  [[ -f "$SCRIPTS/$name" ]] || fail "deployed selftest missing: $SCRIPTS/$name"
  log "running $name against the live tree ..."
  out="$("$BASH32" "$SCRIPTS/$name" 2>&1)" || { echo "$out" | tail -40 >&2; fail "$name failed against the live tree"; }
  # These suites end "=== RESULT: PASS=N FAIL=0 ===" (older ones omit the trailing ===).
  printf '%s\n' "$out" | grep -Eq 'RESULT: PASS=[0-9]+ FAIL=0( ===)?$' \
    || fail "$name did not report a clean FAIL=0 result: $(printf '%s\n' "$out" | tail -3)"
  log "  $(printf '%s\n' "$out" | grep -E 'RESULT: PASS=' | tail -1)"
}
run_suite dolt-backup-s3-proof.selftest.sh
run_suite dolt-gc-maintenance.selftest.sh
run_suite dolt-s3-backup.selftest.sh

# ── 4. The defect itself: hq's S3 backup RESTORES (its manifest's tables all exist) ──
# Before this story the live bucket held a manifest naming a table the bucket lacked. Read-only:
# fetches the S3 manifest and lists the prefix, changes nothing. Checked with the DEPLOYED proof
# lib so the test exercises the same code the release relies on. One retry after a pause: the
# nightly/reseed can be mid-upload at the instant delivery runs, and a transient open window
# is not the defect being tested for.
s3_closure() { ( export AWS="$AWS_BIN" BUCKET; source "$PROOF" && _s3proof_s3_closure_ok hq ) 2>&1; }
if ! out="$(s3_closure)"; then
  log "hq S3 closure not established on the first read (${out##*$'\n'}) — retrying once in 45s (a backup upload may be in flight)"
  sleep 45
  out="$(s3_closure)" || fail "hq's S3 backup is NOT restorable — its manifest names table(s) missing from s3://$BUCKET/hq/: $out"
fi
log "live S3: ${out##*$'\n'}"

# ── 5. The scheduled job that runs the release is actually loaded ────────────────────
launchctl list 2>/dev/null | grep -q 'com.gascity.dolt-gc-maintenance' \
  || fail "com.gascity.dolt-gc-maintenance is NOT registered with launchd — the GC/release never runs (a present plist is not automation)"
log "com.gascity.dolt-gc-maintenance is registered with launchd"

# ── informational, never failing: where the release stands right now ─────────────────
STATE="$CITY/.gc/runtime/packs/maintenance/dolt-gc-staging-release.state"
STREAK="$CITY/.gc/runtime/packs/maintenance/dolt-gc-skip-streak.state"
if [[ -s "$STATE" ]]; then log "info: staging last released at epoch $(head -1 "$STATE")"; else log "info: staging has not been released yet (cooldown state absent)"; fi
[[ -s "$STREAK" ]] && log "info: dolt_gc skip streak state: $(head -1 "$STREAK")"
if [[ -d "$CITY/.dolt-backup/hq" ]]; then log "info: local hq staging present ($(du -sm "$CITY/.dolt-backup/hq" 2>/dev/null | awk '{print $1}') MB)"; else log "info: local hq staging absent (released for the GC window, or not rebuilt yet — mol-dog-backup recreates it)"; fi
log "info: kill switch = GC_RELEASE_STAGING_ENABLED=0 in the job's env (default on)"

log "PASS — proof lib + refusal-branch mirror + guarded staging release deployed, wired and tested against the live tree; hq's live S3 backup is restorable; the GC job is scheduled"
exit 0

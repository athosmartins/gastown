#!/usr/bin/env bash
# prod-tests/gascity/story-ga-jz7gg.sh — prod test for ga-jz7gg: retention for
# .dolt-backup (post-compact reseed hook + S3 noncurrent-version lifecycle +
# weekly automated restore-verify + the one-time hq verification the story
# itself required as part of delivery).
#
# Called by story-delivery.sh after deploy (STORY_ID=ga-jz7gg). Exits 0 on
# pass. Asserts against the LIVE deployed tree (never this worktree's copy —
# gascity's scripts run in place, so "deployed" means present on disk at
# CITY, per delivery-runbooks.toml's own gascity rig comment) and against
# real, external, live state (the S3 bucket, launchd) where a file check
# alone can't prove the thing actually took effect.
set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
BUCKET="${DOLT_S3_BACKUP_BUCKET:-urblink-dolt-backups}"
AWS_BIN="${AWS_BIN:-aws}"
BD_BIN="${BD_BIN:-bd}"

log()  { echo "[prod-test:gascity ga-jz7gg] $*"; }
fail() { echo "[prod-test:gascity ga-jz7gg] FAIL: $*" >&2; exit 1; }

# ── Scope item 1: post-compaction reseed hook ─────────────────────────────────
COMPACT_SCRIPT="$CITY/scripts/dolt-compact-routine.sh"
[[ -f "$COMPACT_SCRIPT" ]] || fail "deployed dolt-compact-routine.sh missing: $COMPACT_SCRIPT"
grep -q "_reseed_after_compact" "$COMPACT_SCRIPT" \
  || fail "deployed dolt-compact-routine.sh does not carry the ga-jz7gg reseed hook (_reseed_after_compact)"
# shellcheck disable=SC2016 # intentional literal grep pattern, not a missed
# interpolation -- verified directly: this platform's grep needs \$ to match
# a literal $ mid-pattern (an unescaped $ here silently fails to match at all).
grep -q '_reseed_after_compact "\$attempted"' "$COMPACT_SCRIPT" \
  || fail "deployed dolt-compact-routine.sh defines _reseed_after_compact but never CALLS it from _decide_and_run"
log "reseed hook present and wired into _decide_and_run"

log "running dolt-compact-routine's own regression suite against the live tree..."
COMPACT_TEST_OUT="$(bash "$CITY/scripts/dolt-compact-routine.selftest.sh" 2>&1)" || {
  echo "$COMPACT_TEST_OUT" >&2
  fail "dolt-compact-routine.selftest.sh failed against the live tree"
}
echo "$COMPACT_TEST_OUT" | grep -qE 'RESULT: PASS=[0-9]+ FAIL=0$' \
  || fail "dolt-compact-routine.selftest.sh did not report a clean FAIL=0 result:
$COMPACT_TEST_OUT"
log "dolt-compact-routine's full suite (including the reseed scenarios) passes clean"

# ── Scope item 2: S3 lifecycle — 30d noncurrent-version expiration, live ──────
ACTUAL_DAYS="$("$AWS_BIN" s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query "Rules[?ID=='expire-noncurrent-versions-30d'].NoncurrentVersionExpiration.NoncurrentDays" --output text 2>/dev/null)"
[[ "$ACTUAL_DAYS" == "30" ]] \
  || fail "live bucket '$BUCKET' does not have a 30-day noncurrent-version expiration rule (got '${ACTUAL_DAYS:-EMPTY/unreadable}')"
log "S3 bucket '$BUCKET' confirmed live: NoncurrentVersionExpiration.NoncurrentDays=30"

# ── Scope item 3: weekly restore-verify — script, tests, and the launchd job ──
RESTORE_SCRIPT="$CITY/scripts/dolt-restore-verify.sh"
[[ -f "$RESTORE_SCRIPT" ]] || fail "deployed dolt-restore-verify.sh missing: $RESTORE_SCRIPT"

log "running dolt-restore-verify's own regression suite against the live tree..."
RESTORE_TEST_OUT="$(bash "$CITY/scripts/dolt-restore-verify.selftest.sh" 2>&1)" || {
  echo "$RESTORE_TEST_OUT" >&2
  fail "dolt-restore-verify.selftest.sh failed against the live tree"
}
echo "$RESTORE_TEST_OUT" | grep -qE 'RESULT: PASS=[0-9]+ FAIL=0$' \
  || fail "dolt-restore-verify.selftest.sh did not report a clean FAIL=0 result:
$RESTORE_TEST_OUT"
log "dolt-restore-verify's full suite passes clean"

if launchctl list 2>/dev/null | grep -q "com.gascity.dolt-restore-verify"; then
  log "com.gascity.dolt-restore-verify is registered with launchd"
else
  fail "com.gascity.dolt-restore-verify is NOT registered with launchd — the weekly job is not actually scheduled (a present-but-unloaded plist is not automation, see gascity-native-template-fragment-source-location-class gotcha)"
fi

# ── Scope item 4: the one-time hq verification the story itself required ─────
# Not a standing invariant (it's a one-off action, not a recurring property),
# so this proves it happened at least once, ever — not that it happened
# "recently". A past OK record is permanent evidence the action was taken;
# re-checking on every future deploy of unrelated stories is intentional
# (cheap, and confirms the summary-bead trail from item 3 stayed intact).
# _file_summary_bead() builds title/description as "...OK: $results" / "...banco:\n$results"
# — "hq=OK(" is always preceded by a space or an escaped newline in the JSON
# output, NEVER by a raw '"' (gate-caught: the previous pattern required a
# leading '"' and could never match anything). Match the literal status
# token itself, including the paren so a differently-named db can't collide.
HQ_VERIFY_COUNT="$(timeout 30 "$BD_BIN" -C "$CITY" list --label=restore-verify --all --json --limit=0 2>/dev/null \
  | grep -c 'hq=OK(' || true)"
[[ "${HQ_VERIFY_COUNT:-0}" -ge 1 ]] \
  || fail "no restore-verify summary bead recording an OK result for 'hq' was found — the story's own required one-time verification (scope item 4) has no durable record"
log "found $HQ_VERIFY_COUNT restore-verify summary bead(s) recording an OK result for 'hq'"

log "PASS — reseed hook wired + tested, S3 lifecycle live at 30d, weekly restore-verify shipped + scheduled + tested, one-time hq verification has a durable OK record"
exit 0

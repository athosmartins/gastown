#!/bin/bash
# dolt-backup-reseed.selftest.sh (ga-i99qsp) — hermetic tests for the
# low-disk fallback added to dolt-backup-reseed.sh: the hq backup staging
# (13-14G) could never shrink because the NORMAL reseed flow needs ~250% of
# the live db size free, and the staging bloat itself was the reason that
# margin never existed (catch-22). See the script's own header for the full
# mechanism this exercises.
#
# Hermetic: `dolt`, `gc` and `aws` are ALL stub scripts on a scratch PATH —
# no real Dolt server, no real AWS call, ever. `cp -c` (APFS clonefile) and
# `stat`/`awk`/`du`/`df` are REAL, but only ever touch throwaway scratch
# directories under this test's own scratch root — never .dolt-backup, never
# .beads/dolt, never any real city path. `df` itself is a stub whose
# "available" figure is derived from `du -sk` over the scratch root, so it
# reflects the scratch dirs' REAL sizes as the script creates/deletes them,
# without needing to fake the whole host's actual free disk.
#
# Part 1 sources the script in LIB mode (DOLT_BACKUP_RESEED_LIB=1) to unit-
# test _s3_current_backup_verified directly. Part 2 runs the LIVE script as
# a real subprocess for the full low-disk flow — required because _run_reseed
# ends every path via exit/die, which would kill a sourcing test harness.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/dolt-backup-reseed.sh"
S3_BACKUP_SCRIPT="$HERE/dolt-s3-backup.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

echo "=== dolt-backup-reseed.selftest.sh ==="

# ═══════════════════════════════════════════════════════════════════════════
# Part 1: _s3_current_backup_verified() — LIB-mode unit tests, stubbed aws
# ═══════════════════════════════════════════════════════════════════════════
echo "── _s3_current_backup_verified() (ga-i99qsp) ──"

LIB_SCRATCH="/tmp/reseed-selftest-lib.$$"
mkdir -p "$LIB_SCRATCH/bin"

cat > "$LIB_SCRATCH/bin/aws" <<'FAKEAWS'
#!/bin/bash
case "$*" in
  *"s3api head-object"*)
    [ "${FAKE_AWS_MANIFEST_OK:-1}" = "1" ] && exit 0 || exit 254
    ;;
  *"s3 cp"*"_meta/latest.json"*)
    [ "${FAKE_AWS_FINGERPRINT_OK:-1}" = "1" ] || exit 1
    dest="${@: -1}"
    # ga-gjfe78: FAKE_FP_SHAPE selects how the db is published when it FAILED.
    #   failed           = what dolt-s3-backup.sh writes (last good values only under last_ok)
    #   failed-proofkeys = hazardous: status:failed but run_utc/backup_size/head still present
    case "${FAKE_FP_SHAPE:-}" in
      failed)
        printf '{"run_utc": "%s", "databases": {"%s": {"status": "failed", "reason": "sync", "last_ok_run_utc": "2026-09-10T07:00:00Z", "last_ok": {"issues": 9, "head": "abc123", "backup_size": "%s"}}}}' \
          "${FAKE_FP_RUN_UTC:-2026-09-17T04:00:00Z}" "${FAKE_FP_DB:-hq}" "${FAKE_FP_SIZE:-10M}" > "$dest"
        exit 0
        ;;
      failed-proofkeys)
        printf '{"run_utc": "%s", "databases": {"%s": {"status": "failed", "run_utc": "%s", "backup_size": "%s", "head": "abc123"}}}' \
          "${FAKE_FP_RUN_UTC:-2026-09-17T04:00:00Z}" "${FAKE_FP_DB:-hq}" "${FAKE_FP_RUN_UTC:-2026-09-17T04:00:00Z}" "${FAKE_FP_SIZE:-10M}" > "$dest"
        exit 0
        ;;
    esac
    printf '{"run_utc": "%s", "databases": {"%s": {"backup_size": "%s", "head": "abc123"}}}' \
      "${FAKE_FP_RUN_UTC:-2026-09-17T04:00:00Z}" "${FAKE_FP_DB:-hq}" "${FAKE_FP_SIZE:-10M}" > "$dest"
    exit 0
    ;;
  *) exit 0 ;;
esac
FAKEAWS
chmod +x "$LIB_SCRATCH/bin/aws"

PATH="$LIB_SCRATCH/bin:$PATH" DOLT_BACKUP_RESEED_LIB=1 . "$SCRIPT"

if type _s3_current_backup_verified >/dev/null 2>&1; then
  ok "_s3_current_backup_verified defined by lib-mode source"
else
  bad "_s3_current_backup_verified NOT defined — lib mode broken"
  echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
  exit 1
fi

# ga-6xo4r0 / ga-tyaozh: this script now has its OWN S3 upload call sites
# (_publish_db_fingerprint's sync + fingerprint cp), so it must export the
# same AwsChunkedWrapper/UnseekableStreamError workaround dolt-s3-backup.sh
# exports for ITS uploads — independently, since dolt-disk-floor-guard.sh's
# ad hoc CRITICAL trigger (this bead's whole reason for existing) invokes
# this script directly, without going through dolt-s3-backup.sh at all. See
# dolt-s3-backup.selftest.sh's own identical check for the full incident.
if [ "${AWS_REQUEST_CHECKSUM_CALCULATION:-}" = "when_required" ]; then
  ok "AWS_REQUEST_CHECKSUM_CALCULATION=when_required after lib-mode source"
else
  bad "AWS_REQUEST_CHECKSUM_CALCULATION not 'when_required' after lib-mode source (got '${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}') — this script's NEW S3 upload call sites are UNPROTECTED against the ga-tyaozh AwsChunkedWrapper defect when invoked ad hoc (i.e. NOT as a dolt-s3-backup.sh child)"
fi

LOCALDIR="$LIB_SCRATCH/local-backup-hq"
mkdir -p "$LOCALDIR"
dd if=/dev/zero of="$LOCALDIR/data.bin" bs=1M count=10 >/dev/null 2>&1

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=10M \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && ok "manifest present + size coherent → verified true" \
  || bad "manifest present + size coherent → should have verified true"

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=0 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=10M \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "manifest missing → should NOT have verified true" \
  || ok "manifest missing → correctly refused (fail closed)"

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=0 \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "fingerprint unreadable → should NOT have verified true" \
  || ok "fingerprint unreadable (aws s3 cp fails) → correctly refused (fail closed)"

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=1M \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "grossly incoherent size (fp=1M local=10M) → should NOT have verified true" \
  || ok "grossly incoherent size (fp=1M local=10M) → correctly refused (fail closed)"

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=lexbh FAKE_FP_SIZE=10M \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "fingerprint describes a DIFFERENT db → should NOT have verified true" \
  || ok "fingerprint describes a different db (lexbh, not hq) → correctly refused (never guess across dbs)"

# ga-gjfe78: dolt-s3-backup.sh now publishes a db that failed tonight as
# status:"failed" instead of dropping it. This proof gates DELETING the local
# backup in low-disk mode, so a failed entry must never verify — not even the
# hazardous shape that still carries run_utc/backup_size/head, which a reader
# that predates the change takes as a fresh, coherent proof of an S3 copy the
# nightly run said it could not make.
PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=10M FAKE_FP_SHAPE=failed \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "fingerprint marks hq FAILED → should NOT have verified true" \
  || ok "fingerprint marks hq FAILED (manifest present, size otherwise fine) → correctly refused (a failed entry is not proof)"

PATH="$LIB_SCRATCH/bin:$PATH" FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=10M FAKE_FP_SHAPE=failed-proofkeys \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "status:failed entry that still carries run_utc/backup_size/head was read as PROOF — low-disk mode would delete the local backup on it" \
  || ok "status:failed entry that still carries proof-looking keys → correctly refused (status wins over every other key)"

rm -rf "$LIB_SCRATCH" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════════════
# Part 2: full low-disk flow — real subprocess, stubbed dolt/gc/aws/df
# ═══════════════════════════════════════════════════════════════════════════
echo "── low-disk fallback end-to-end (ga-i99qsp) — stubbed dolt/gc/aws/df, real subprocess ──"

# setup_scenario <root> <live_mb> <old_backup_mb> <total_fake_disk_mb> — lays
# down a throwaway CITY under <root>: .beads/dolt/hq (live_mb of dummy data,
# doubling as _offline_backup_sync's clonefile source AND the dolt-config.yaml
# data_dir) and .dolt-backup/hq (old_backup_mb of dummy "bloated" backup).
# Also writes the fake dolt/gc/aws binaries and a fake df whose "available"
# column is (total_fake_disk_mb - real current usage under <root>) in KB —
# so free space naturally tracks whatever the script creates/deletes there.
setup_scenario() {
  local root="$1" live_mb="$2" old_mb="$3" total_mb="$4"
  mkdir -p "$root/city/.beads/dolt/hq" "$root/city/.dolt-backup/hq" "$root/bin" "$root/city/.gc/runtime/packs/dolt"
  dd if=/dev/zero of="$root/city/.beads/dolt/hq/live.bin" bs=1M count="$live_mb" >/dev/null 2>&1
  dd if=/dev/zero of="$root/city/.dolt-backup/hq/old-bloat.bin" bs=1M count="$old_mb" >/dev/null 2>&1

  cat > "$root/city/.gc/runtime/packs/dolt/dolt-config.yaml" <<CFG
data_dir: "$root/city/.beads/dolt"
listener:
  host: 127.0.0.1
  port: 52756
CFG

  local total_kb=$(( total_mb * 1024 ))
  cat > "$root/bin/df" <<DFEOF
#!/bin/bash
used_kb=\$(du -sk "$root/city" 2>/dev/null | awk '{print \$1}')
[ -n "\$used_kb" ] || used_kb=0
free_kb=\$(( $total_kb - used_kb ))
[ "\$free_kb" -lt 0 ] && free_kb=0
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "fake 1 1 \$free_kb 1% /System/Volumes/Data"
DFEOF
  chmod +x "$root/bin/df"

  # fake gc: only ever asked for LIVE_COUNT ("gc dolt sql -q ... issues").
  cat > "$root/bin/gc" <<'GCEOF'
#!/bin/bash
echo "| ${FAKE_LIVE_COUNT:-50} |"
exit 0
GCEOF
  chmod +x "$root/bin/gc"

  # fake dolt: services BOTH reseed.sh's own direct calls (backup restore,
  # sql -q COUNT) AND _offline_backup_sync's embedded-clone calls (--data-dir
  # ... sql -q "SELECT @@port", --data-dir ... backup sync-url).
  cat > "$root/bin/dolt" <<'DOLTEOF'
#!/bin/bash
args="$*"
case "$args" in
  *"SELECT @@port"*)
    echo "9999"
    ;;
  *"backup sync-url"*)
    [ "${FAKE_SYNC_URL_FAIL:-0}" = "1" ] && exit 1
    dest="${args##*file://}"
    mkdir -p "$dest"
    dd if=/dev/zero of="$dest/new-backup.bin" bs=1M count="${FAKE_NEW_BACKUP_MB:-10}" >/dev/null 2>&1
    exit 0
    ;;
  *"backup restore"*)
    [ "${FAKE_RESTORE_FAIL:-0}" = "1" ] && exit 1
    # invoked as: dolt backup restore file://<NEW_DIR> <verify_name>, cwd=$VERIFY_DIR
    verify_name="${@: -1}"
    mkdir -p "./$verify_name"
    echo marker > "./$verify_name/marker"
    exit 0
    ;;
  *"SELECT COUNT(*) FROM issues"*)
    if [ "${FAKE_RESTORED_COUNT_UNREADABLE:-0}" = "1" ]; then
      exit 0
    fi
    echo "| ${FAKE_RESTORED_COUNT:-50} |"
    ;;
  *) exit 0 ;;
esac
DOLTEOF
  chmod +x "$root/bin/dolt"

  # fake aws: same contract as Part 1's stub above, PLUS (ga-6xo4r0):
  #  - "s3 sync" (the new post-swap off-box mirror in _publish_db_fingerprint)
  #    records its invocation to ./s3-sync.log (relative to $root, since
  #    run_scenario always `cd`s there first) and succeeds by default, or
  #    fails when FAKE_S3_SYNC_FAIL=1.
  #  - "s3 cp ... _meta/latest.json" DOWNLOAD (arg $3 is the s3:// URI):
  #    unchanged canned single-db-doc behavior UNLESS FAKE_S3_META_SEED_FILE
  #    points at a file, in which case THAT file's content is served instead
  #    — lets a scenario seed a multi-db doc to prove the merge-publish
  #    preserves sibling entries.
  #  - "s3 cp ... _meta/latest.json" UPLOAD (arg $4 is the s3:// URI — the
  #    NEW direction _publish_db_fingerprint needs, to write the merged doc
  #    back): captures the uploaded content to ./s3-meta-uploaded.json.
  cat > "$root/bin/aws" <<'AWSEOF'
#!/bin/bash
case "$*" in
  *"s3api head-object"*)
    [ "${FAKE_AWS_MANIFEST_OK:-1}" = "1" ] && exit 0 || exit 254
    ;;
  *"s3 sync"*)
    echo "$*" >> ./s3-sync.log
    printf '%s\n' "${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}" >> ./s3-sync-checksum-env.log
    [ "${FAKE_S3_SYNC_FAIL:-0}" = "1" ] && exit 1 || exit 0
    ;;
  *"s3 cp"*"_meta/latest.json"*)
    case "$3" in
      s3://*)
        # DOWNLOAD: aws s3 cp s3://.../_meta/latest.json <local-dest>
        dest="$4"
        if [ -n "${FAKE_S3_META_SEED_FILE:-}" ] && [ -f "${FAKE_S3_META_SEED_FILE:-}" ]; then
          cp "$FAKE_S3_META_SEED_FILE" "$dest"
          exit 0
        fi
        [ "${FAKE_AWS_FINGERPRINT_OK:-1}" = "1" ] || exit 1
        printf '{"run_utc": "%s", "databases": {"%s": {"backup_size": "%s", "head": "abc123"}}}' \
          "${FAKE_FP_RUN_UTC:-2026-09-17T04:00:00Z}" "${FAKE_FP_DB:-hq}" "${FAKE_FP_SIZE:-20M}" > "$dest"
        exit 0
        ;;
      *)
        # UPLOAD: aws s3 cp <local-src> s3://.../_meta/latest.json [flags]
        cp "$3" ./s3-meta-uploaded.json
        exit 0
        ;;
    esac
    ;;
  *) exit 0 ;;
esac
AWSEOF
  chmod +x "$root/bin/aws"
}

# run_scenario <root> [extra env assignments...] — invokes the real script as
# a subprocess against <root>'s scratch city, with the stub bin dir first on
# PATH. Sets $RC (exit code) and writes stdout+stderr to $root/out.log.
run_scenario() {
  local root="$1"; shift
  ( cd "$root" \
    && env "$@" PATH="$root/bin:$PATH" GC_CITY_PATH="$root/city" \
         RESEED_LOG="$root/city/reseed.log" \
         DOLT_BIN=dolt GC_BIN=gc \
         "$SCRIPT" hq > "$root/out.log" 2>&1 )
  RC=$?
}

city_used_kb() { du -sk "$1/city" 2>/dev/null | awk '{print $1}'; }

# ── Scenario 0: normal margin available → UNCHANGED behavior (regression guard) ──
ROOT0="/tmp/reseed-selftest-s0.$$"
setup_scenario "$ROOT0" 5 5 200   # live=5M old=5M, total=200M → plenty of margin (250%)
run_scenario "$ROOT0"
if [ "$RC" -eq 0 ]; then ok "scenario 0 (ample margin): exits 0"; else bad "scenario 0 (ample margin): expected exit 0, got $RC — $(tail -3 "$ROOT0/out.log")"; fi
if [ -d "$ROOT0/city/.dolt-backup/hq.old" ]; then ok "scenario 0: normal path still produces .old (unchanged behavior)"; else bad "scenario 0: expected .old to exist — normal path regressed"; fi
if grep -q "modo de baixo disco" "$ROOT0/out.log" 2>/dev/null; then bad "scenario 0: low-disk mode should NOT have activated with ample margin"; else ok "scenario 0: low-disk mode correctly not activated"; fi
rm -rf "$ROOT0" 2>/dev/null

# ── Scenario 1 (ACCEPTANCE #1): margin below 250% but S3 verified → staging
#    shrinks AND free space ends up HIGHER than before ──
ROOT1="/tmp/reseed-selftest-s1.$$"
setup_scenario "$ROOT1" 10 20 50   # live=10M old=20M(bloated) total=50M
FREE_BEFORE_KB=$(( 50*1024 - $(city_used_kb "$ROOT1") ))
run_scenario "$ROOT1" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M
if [ "$RC" -eq 0 ]; then ok "scenario 1 (low-disk, S3 verified): exits 0"; else bad "scenario 1: expected exit 0, got $RC — $(tail -5 "$ROOT1/out.log")"; fi
if grep -q "modo de baixo disco" "$ROOT1/out.log" 2>/dev/null; then ok "scenario 1: low-disk mode activated"; else bad "scenario 1: low-disk mode should have activated"; fi
NEW_KB=$(du -sk "$ROOT1/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
OLD_KB_APPROX=$((20*1024))
if [ -n "$NEW_KB" ] && [ "$NEW_KB" -lt "$OLD_KB_APPROX" ]; then ok "scenario 1: staging shrunk (${NEW_KB}KB < old ${OLD_KB_APPROX}KB)"; else bad "scenario 1: staging should have shrunk, got ${NEW_KB:-?}KB"; fi
if [ -e "$ROOT1/city/.dolt-backup/hq.old" ]; then bad "scenario 1: low-disk path should NOT leave a .old (old was freed with S3 proof, not renamed)"; else ok "scenario 1: no .old residue left (freed proactively, not deferred)"; fi
FREE_AFTER_KB=$(( 50*1024 - $(city_used_kb "$ROOT1") ))
if [ "$FREE_AFTER_KB" -gt "$FREE_BEFORE_KB" ]; then ok "scenario 1: free space increased (before=${FREE_BEFORE_KB}KB after=${FREE_AFTER_KB}KB)"; else bad "scenario 1: free space should have increased (before=${FREE_BEFORE_KB}KB after=${FREE_AFTER_KB}KB)"; fi
if grep -q "prova do S3 OK" "$ROOT1/out.log" 2>/dev/null; then ok "scenario 1: log has the S3-proof line (acceptance criterion 3's 'conferir no log')"; else bad "scenario 1: log missing the S3-proof line"; fi
rm -rf "$ROOT1" 2>/dev/null

# ── Scenario 2 (ACCEPTANCE #2): margin below 250%, S3 proof FAILS → NOTHING
#    deleted, distinctive failure the caller classifies as a real alarm ──
ROOT2="/tmp/reseed-selftest-s2.$$"
setup_scenario "$ROOT2" 10 20 50
OLD_KB_BEFORE=$(du -sk "$ROOT2/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
run_scenario "$ROOT2" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=0 FAKE_AWS_FINGERPRINT_OK=1
if [ "$RC" -ne 0 ]; then ok "scenario 2 (low-disk, S3 proof fails): exits non-zero"; else bad "scenario 2: expected non-zero exit, got 0"; fi
OLD_KB_AFTER=$(du -sk "$ROOT2/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 2: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 2: old backup should be unchanged, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB"; fi
if [ -e "$ROOT2/city/.dolt-backup/hq.new" ]; then bad "scenario 2: .new leftover should have been cleaned up on proof failure"; else ok "scenario 2: .new correctly cleaned up on proof failure"; fi
if grep -q "prova do S3 FALHOU" "$ROOT2/out.log" 2>/dev/null; then ok "scenario 2: distinctive 'prova do S3 FALHOU' message present"; else bad "scenario 2: missing the distinctive proof-failed message"; fi
( PATH="$ROOT2/bin:$PATH" DOLT_S3_BACKUP_LIB=1 . "$S3_BACKUP_SCRIPT"
  if is_low_disk_proof_failed_refusal "$(cat "$ROOT2/out.log")"; then
    echo "  PASS: scenario 2: dolt-s3-backup.sh's is_low_disk_proof_failed_refusal classifies this as a REAL alarm (not the silent margin-refusal case)"
  else
    echo "  FAIL: scenario 2: is_low_disk_proof_failed_refusal did NOT classify this output — would be misrouted as a silent 'expected' skip"
  fi
) > "$ROOT2/classify.log" 2>&1
cat "$ROOT2/classify.log"
grep -q "^  PASS:" "$ROOT2/classify.log" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
if grep -q "disco insuficiente" "$ROOT2/out.log" 2>/dev/null; then bad "scenario 2: message must NOT also match is_disk_margin_refusal's pattern (would misclassify as silent/expected)"; else ok "scenario 2: message does not collide with the disk-margin-refusal pattern"; fi
rm -rf "$ROOT2" 2>/dev/null

# ── Scenario 3 (invariant c): old ALREADY freed (S3 proof passed), then the
#    rebuild itself fails → db has NO local backup, must alarm LOUDLY and
#    distinctly from scenario 2's "nothing touched yet" case ──
ROOT3="/tmp/reseed-selftest-s3.$$"
setup_scenario "$ROOT3" 10 20 50
run_scenario "$ROOT3" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M FAKE_RESTORE_FAIL=1
if [ "$RC" -ne 0 ]; then ok "scenario 3 (freed-then-rebuild-fails): exits non-zero"; else bad "scenario 3: expected non-zero exit, got 0"; fi
if grep -q "SEM BACKUP LOCAL" "$ROOT3/out.log" 2>/dev/null; then ok "scenario 3: distinctive 'SEM BACKUP LOCAL' message present"; else bad "scenario 3: missing the distinctive no-local-backup message"; fi
if [ -e "$ROOT3/city/.dolt-backup/hq" ]; then bad "scenario 3: old was freed and new was never promoted — .dolt-backup/hq should not exist"; else ok "scenario 3: confirms the invariant-(c) window is real (no local backup dir at all right now)"; fi
( PATH="$ROOT3/bin:$PATH" DOLT_S3_BACKUP_LIB=1 . "$S3_BACKUP_SCRIPT"
  if is_local_backup_lost_refusal "$(cat "$ROOT3/out.log")"; then
    echo "  PASS: scenario 3: dolt-s3-backup.sh's is_local_backup_lost_refusal classifies this correctly"
  else
    echo "  FAIL: scenario 3: is_local_backup_lost_refusal did NOT classify this output"
  fi
  if is_low_disk_proof_failed_refusal "$(cat "$ROOT3/out.log")"; then
    echo "  FAIL: scenario 3: must NOT also match is_low_disk_proof_failed_refusal — these are different severities with different messages"
  else
    echo "  PASS: scenario 3: correctly does NOT collide with the (milder) proof-failed classifier"
  fi
) > "$ROOT3/classify.log" 2>&1
cat "$ROOT3/classify.log"
while read -r line; do
  case "$line" in "  PASS:"*) PASS=$((PASS+1)) ;; "  FAIL:"*) FAIL=$((FAIL+1)) ;; esac
done < "$ROOT3/classify.log"
rm -rf "$ROOT3" 2>/dev/null

# ── Scenario 4: disk too tight even AFTER freeing the old backup → refuses
#    cleanly, still classified as the (streak-tracked) margin refusal, nothing
#    touched. live=10M → LOW_NEED=12M; old=5M so freeing it only ever projects
#    to free(1M)+old(5M)=6M, still short of the 12M a single fresh copy needs —
#    genuinely no amount of freeing helps here (ga-74tts6: distinct from
#    scenarios 6/7 below, where freeing the — much bigger — old backup DOES
#    clear the bar). ──
ROOT4="/tmp/reseed-selftest-s4.$$"
setup_scenario "$ROOT4" 10 5 16   # total=16M: live=10M+old=5M used, 1M free — even freeing old (5M) only projects to 6M < 12M needed
run_scenario "$ROOT4" FAKE_LIVE_COUNT=50
if [ "$RC" -ne 0 ]; then ok "scenario 4 (too tight even after freeing old): exits non-zero"; else bad "scenario 4: expected non-zero exit, got 0"; fi
if grep -q "insuficiente até liberando o backup antigo" "$ROOT4/out.log" 2>/dev/null; then ok "scenario 4: distinctive 'even freeing the old backup' refusal message present"; else bad "scenario 4: missing the freeing-old-still-insufficient message"; fi
if grep -q "disco insuficiente" "$ROOT4/out.log" 2>/dev/null; then ok "scenario 4: still classifiable by is_disk_margin_refusal (so the streak counter tracks it)"; else bad "scenario 4: should still match 'disco insuficiente' for the streak counter to see it"; fi
if [ -d "$ROOT4/city/.dolt-backup/hq" ] && [ ! -e "$ROOT4/city/.dolt-backup/hq.new" ] && [ ! -e "$ROOT4/city/.dolt-backup/hq.old" ]; then ok "scenario 4: nothing touched (no .new, no .old, original backup dir untouched)"; else bad "scenario 4: expected nothing touched"; fi
rm -rf "$ROOT4" 2>/dev/null

# ── Scenario 6 (ACCEPTANCE #1, ga-74tts6): free space below 100% of live (and
#    below the normal low-disk-mode's own 120% margin) but freeing the old
#    (bloated) backup — S3-verified first — opens enough room → staging is
#    freed BEFORE any new write, and free space ends up higher than before ──
ROOT6="/tmp/reseed-selftest-s6.$$"
setup_scenario "$ROOT6" 10 20 35   # live=10M, old=20M(bloated), free=5M (50% of live — below even the 120% low-disk margin)
FREE_BEFORE_KB=$(( 35*1024 - $(city_used_kb "$ROOT6") ))
run_scenario "$ROOT6" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M
if [ "$RC" -eq 0 ]; then ok "scenario 6 (ultra-low-disk, S3 verified): exits 0"; else bad "scenario 6: expected exit 0, got $RC — $(tail -5 "$ROOT6/out.log")"; fi
if grep -q "modo ULTRA de baixo disco" "$ROOT6/out.log" 2>/dev/null; then ok "scenario 6: ultra-low-disk mode activated"; else bad "scenario 6: ultra-low-disk mode should have activated"; fi
if grep -q "ANTES de construir" "$ROOT6/out.log" 2>/dev/null; then ok "scenario 6: log shows the old backup was freed BEFORE writing anything new (inverted order)"; else bad "scenario 6: missing the freed-before-building log line"; fi
NEW_KB=$(du -sk "$ROOT6/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
OLD_KB_APPROX=$((20*1024))
if [ -n "$NEW_KB" ] && [ "$NEW_KB" -lt "$OLD_KB_APPROX" ]; then ok "scenario 6: staging shrunk (${NEW_KB}KB < old ${OLD_KB_APPROX}KB)"; else bad "scenario 6: staging should have shrunk, got ${NEW_KB:-?}KB"; fi
if [ -e "$ROOT6/city/.dolt-backup/hq.old" ]; then bad "scenario 6: ultra path should NOT leave a .old (old was freed proactively with S3 proof, not renamed)"; else ok "scenario 6: no .old residue left"; fi
FREE_AFTER_KB=$(( 35*1024 - $(city_used_kb "$ROOT6") ))
if [ "$FREE_AFTER_KB" -gt "$FREE_BEFORE_KB" ]; then ok "scenario 6: free space increased (before=${FREE_BEFORE_KB}KB after=${FREE_AFTER_KB}KB)"; else bad "scenario 6: free space should have increased (before=${FREE_BEFORE_KB}KB after=${FREE_AFTER_KB}KB)"; fi
if grep -q "prova do S3 OK" "$ROOT6/out.log" 2>/dev/null; then ok "scenario 6: log has the S3-proof line"; else bad "scenario 6: log missing the S3-proof line"; fi
rm -rf "$ROOT6" 2>/dev/null

# ── Scenario 7 (ACCEPTANCE #2, ga-74tts6): same ultra-low-disk trigger as
#    scenario 6, but the S3 proof FAILS → NOTHING deleted, distinctive alarm,
#    and NEW_DIR is never even created (the proof runs before any write) ──
ROOT7="/tmp/reseed-selftest-s7.$$"
setup_scenario "$ROOT7" 10 20 35
OLD_KB_BEFORE=$(du -sk "$ROOT7/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
run_scenario "$ROOT7" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=0 FAKE_AWS_FINGERPRINT_OK=1
if [ "$RC" -ne 0 ]; then ok "scenario 7 (ultra-low-disk, S3 proof fails): exits non-zero"; else bad "scenario 7: expected non-zero exit, got 0"; fi
OLD_KB_AFTER=$(du -sk "$ROOT7/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 7: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 7: old backup should be unchanged, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB"; fi
if [ -e "$ROOT7/city/.dolt-backup/hq.new" ]; then bad "scenario 7: .new should never have been created — the proof runs before Passo 1"; else ok "scenario 7: .new correctly never created (proof-before-write ordering)"; fi
if grep -q "modo ULTRA de baixo disco: prova do S3 FALHOU" "$ROOT7/out.log" 2>/dev/null; then ok "scenario 7: distinctive ultra-mode 'prova do S3 FALHOU' message present"; else bad "scenario 7: missing the distinctive proof-failed message"; fi
if grep -q "disco insuficiente" "$ROOT7/out.log" 2>/dev/null; then bad "scenario 7: message must NOT also match is_disk_margin_refusal's pattern (would misclassify as silent/expected)"; else ok "scenario 7: message does not collide with the disk-margin-refusal pattern"; fi
( PATH="$ROOT7/bin:$PATH" DOLT_S3_BACKUP_LIB=1 . "$S3_BACKUP_SCRIPT"
  if is_low_disk_proof_failed_refusal "$(cat "$ROOT7/out.log")"; then
    echo "  PASS: scenario 7: dolt-s3-backup.sh's is_low_disk_proof_failed_refusal classifies the ultra-mode proof failure the same as the normal low-disk one"
  else
    echo "  FAIL: scenario 7: is_low_disk_proof_failed_refusal did NOT classify this output — would be misrouted"
  fi
) > "$ROOT7/classify.log" 2>&1
cat "$ROOT7/classify.log"
grep -q "^  PASS:" "$ROOT7/classify.log" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
rm -rf "$ROOT7" 2>/dev/null

# ── Scenario 8 (invariant c via the NEW trigger path): ultra mode frees the
#    old backup (S3 proof passed) and THEN the rebuild itself fails → same
#    "SEM BACKUP LOCAL" alarm as scenario 3's normal-low-disk-mode trigger,
#    proving OLD_FREED_EARLY is honored identically regardless of which step
#    (0.5 or 1.5) set it ──
ROOT8="/tmp/reseed-selftest-s8.$$"
setup_scenario "$ROOT8" 10 20 35
run_scenario "$ROOT8" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_MANIFEST_OK=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M FAKE_RESTORE_FAIL=1
if [ "$RC" -ne 0 ]; then ok "scenario 8 (ultra freed-then-rebuild-fails): exits non-zero"; else bad "scenario 8: expected non-zero exit, got 0"; fi
if grep -q "SEM BACKUP LOCAL" "$ROOT8/out.log" 2>/dev/null; then ok "scenario 8: distinctive 'SEM BACKUP LOCAL' message present"; else bad "scenario 8: missing the distinctive no-local-backup message"; fi
if [ -e "$ROOT8/city/.dolt-backup/hq" ]; then bad "scenario 8: old was freed and new was never promoted — .dolt-backup/hq should not exist"; else ok "scenario 8: confirms the invariant-(c) window is real via the ultra trigger too"; fi
rm -rf "$ROOT8" 2>/dev/null

# ── Scenario 5: RESEED_ALLOW_LOW_DISK=0 → old refuse-only behavior preserved ──
ROOT5="/tmp/reseed-selftest-s5.$$"
setup_scenario "$ROOT5" 10 20 50
run_scenario "$ROOT5" FAKE_LIVE_COUNT=50 RESEED_ALLOW_LOW_DISK=0
if [ "$RC" -ne 0 ]; then ok "scenario 5 (low-disk disabled via RESEED_ALLOW_LOW_DISK=0): exits non-zero"; else bad "scenario 5: expected non-zero exit, got 0"; fi
if grep -q "modo de baixo disco desabilitado" "$ROOT5/out.log" 2>/dev/null; then ok "scenario 5: escape hatch correctly disables the new path"; else bad "scenario 5: escape hatch message missing"; fi
if [ -e "$ROOT5/city/.dolt-backup/hq.new" ] || [ -e "$ROOT5/city/.dolt-backup/hq.old" ]; then bad "scenario 5: nothing should have been touched with the escape hatch on"; else ok "scenario 5: nothing touched with the escape hatch on"; fi
rm -rf "$ROOT5" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════════════
# Part 3 (ga-6xo4r0): post-swap S3 sync + per-db fingerprint publish — the
# fix for "S3 backup fingerprint (once/day) can be outpaced by ad hoc
# disk-pressure reseeds, silently freezing residue-reclaim for healthy dbs".
# ═══════════════════════════════════════════════════════════════════════════
echo "── post-swap fingerprint publish (ga-6xo4r0) — stubbed aws, real subprocess ──"

# ── Scenario 9 (THE regression test for this bead): ad hoc reseed for 'hq'
#    with an EXISTING multi-db _meta/latest.json already on "S3" (seeded via
#    FAKE_S3_META_SEED_FILE) whose hq entry is STALE (yesterday) and whose
#    sibling 'otherdb' entry is untouched. Proves three things: (1) the swap
#    triggers a real S3 sync of the promoted backup, (2) the merge refreshes
#    ONLY hq's own entry, byte-for-byte preserving otherdb's, and (3) feeding
#    what actually got published into residue-reclaim's OWN gate
#    (_should_release_residue) now says RELEASE for hq — not just that the
#    settle window cleared, the actual eligibility clock this bead is about.
ROOT9="/tmp/reseed-selftest-s9.$$"
setup_scenario "$ROOT9" 5 5 200
cat > "$ROOT9/seed-meta.json" <<'JSON'
{
  "run_utc": "2026-09-20T04:00:00Z",
  "databases": {
    "hq": {"issues": 999, "backup_size": "999M", "run_utc": "2026-09-20T04:00:00Z"},
    "otherdb": {"issues": 42, "backup_size": "7M", "run_utc": "2026-09-20T04:00:00Z"}
  }
}
JSON
run_scenario "$ROOT9" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_S3_META_SEED_FILE="$ROOT9/seed-meta.json"
if [ "$RC" -eq 0 ]; then ok "scenario 9 (ad hoc reseed + fingerprint publish): exits 0"; else bad "scenario 9: expected exit 0, got $RC — $(tail -5 "$ROOT9/out.log")"; fi
if [ -d "$ROOT9/city/.dolt-backup/hq.old" ]; then ok "scenario 9: normal swap still produces .old (unchanged)"; else bad "scenario 9: expected .old to exist"; fi
if grep -qF "s3://urblink-dolt-backups/hq/" "$ROOT9/s3-sync.log" 2>/dev/null; then ok "scenario 9: the promoted backup was actually synced to S3 (the off-box mirror this bead's fix adds)"; else bad "scenario 9: missing the expected 'aws s3 sync' call to hq's S3 prefix"; fi
if [ "$(cat "$ROOT9/s3-sync-checksum-env.log" 2>/dev/null)" = "when_required" ]; then ok "scenario 9: the real child 'aws s3 sync' subprocess (this bead's NEW upload call site) inherits AWS_REQUEST_CHECKSUM_CALCULATION=when_required (ga-tyaozh protection)"; else bad "scenario 9: child aws subprocess did not see AWS_REQUEST_CHECKSUM_CALCULATION=when_required (saw '$(cat "$ROOT9/s3-sync-checksum-env.log" 2>/dev/null)') — this NEW upload call site is unprotected against the ga-tyaozh defect"; fi
if grep -q "S3 fingerprint refresh OK" "$ROOT9/out.log" 2>/dev/null; then ok "scenario 9: publish logged as OK"; else bad "scenario 9: missing the fingerprint-refresh-OK log line"; fi
if [ -f "$ROOT9/s3-meta-uploaded.json" ]; then ok "scenario 9: a merged _meta/latest.json was actually uploaded"; else bad "scenario 9: no fingerprint was uploaded at all"; fi

python3 - "$ROOT9/seed-meta.json" "$ROOT9/s3-meta-uploaded.json" > "$ROOT9/merge-check.log" 2>&1 <<'PYCHECK'
import json, sys
seed_path, uploaded_path = sys.argv[1], sys.argv[2]
with open(seed_path) as f:
    seed = json.load(f)
with open(uploaded_path) as f:
    uploaded = json.load(f)

ok = True
if uploaded.get("databases", {}).get("otherdb") != seed["databases"]["otherdb"]:
    print("FAIL: otherdb entry was NOT preserved byte-for-byte by the merge — got", uploaded.get("databases", {}).get("otherdb"))
    ok = False
else:
    print("PASS: otherdb entry preserved untouched by the merge (never clobbered by an ad hoc reseed of a DIFFERENT db)")

hq = uploaded.get("databases", {}).get("hq")
if not isinstance(hq, dict) or not hq.get("run_utc"):
    print("FAIL: hq entry missing or has no run_utc in the uploaded doc:", hq)
    ok = False
elif hq.get("run_utc") == seed["databases"]["hq"]["run_utc"]:
    print("FAIL: hq's run_utc was not refreshed — still the stale seeded value", hq.get("run_utc"))
    ok = False
else:
    print("PASS: hq's run_utc was refreshed to a fresh value (" + hq.get("run_utc") + "), distinct from the stale seeded one")

sys.exit(0 if ok else 1)
PYCHECK
cat "$ROOT9/merge-check.log"
while read -r line; do
  case "$line" in "PASS:"*) PASS=$((PASS+1)) ;; "FAIL:"*) FAIL=$((FAIL+1)) ;; esac
done < "$ROOT9/merge-check.log"

# The actual bug this bead is about: feed what got published into
# residue-reclaim's OWN gate and confirm it now says release. Fabricates an
# .old mtime STRICTLY before the published run_epoch and a "now" comfortably
# past the settle window — proving the GATE logic accepts this fix's own
# output deterministically, without depending on real wall-clock timing
# inside a fast hermetic test (where old_mtime and run_epoch could otherwise
# legitimately land in the same wall-clock second).
( DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 . "$HERE/dolt-backup-residue-reclaim.sh"
  FP_OUT="$(mktemp)"
  _parse_fingerprint_to_file "$ROOT9/s3-meta-uploaded.json" "hq" "$FP_OUT"
  IFS="$(printf '\t')" read -r run_epoch size_bytes head < "$FP_OUT"
  rm -f "$FP_OUT"
  if [ -z "$run_epoch" ]; then
    echo "  FAIL: scenario 9: published fingerprint for hq did not parse (empty run_epoch)"
  else
    fabricated_old_mtime=$(( run_epoch - 1 ))
    fabricated_now=$(( run_epoch + 7200 + 10 ))
    if _should_release_residue "$fabricated_old_mtime" "$fabricated_now" 7200 "$run_epoch" 1 1; then
      echo "  PASS: scenario 9: residue-reclaim's OWN gate (_should_release_residue), fed this fix's published fingerprint, now says RELEASE for hq's .old — the actual bug this bead is about is closed"
    else
      echo "  FAIL: scenario 9: _should_release_residue still says spare even with this fix's own fresh fingerprint — gap not closed"
    fi
  fi
) > "$ROOT9/gate-check.log" 2>&1
cat "$ROOT9/gate-check.log"
grep -q "^  PASS:" "$ROOT9/gate-check.log" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
rm -rf "$ROOT9" 2>/dev/null

# ── Scenario 9b (ga-gjfe78): the published fingerprint MARKS hq (and a sibling)
#    as FAILED — what dolt-s3-backup.sh writes now instead of dropping the db.
#    An ad hoc reseed that re-proves hq must merge a fresh, proper entry OVER
#    hq's failed mark (_publish_db_fingerprint replaces the whole
#    databases.<db> entry — the failed-mark design depends on that), while the
#    sibling's failed mark and an untouched good entry pass through byte-for-
#    byte: one db recovering never clears, or fakes, another db's status.
ROOT9B="/tmp/reseed-selftest-s9b.$$"
setup_scenario "$ROOT9B" 5 5 200
cat > "$ROOT9B/seed-meta.json" <<'JSON'
{
  "run_utc": "2026-09-25T07:04:02Z",
  "databases": {
    "hq": {"status": "failed", "reason": "sync", "last_ok_run_utc": "2026-09-20T07:00:00Z", "last_ok": {"issues": 7242, "head": "old", "backup_size": "13G"}},
    "otherdb": {"status": "failed", "reason": "s3", "last_ok_run_utc": null, "last_ok": null},
    "gooddb": {"issues": 3, "head": "g", "backup_size": "5M"}
  }
}
JSON
run_scenario "$ROOT9B" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_S3_META_SEED_FILE="$ROOT9B/seed-meta.json"
if [ "$RC" -eq 0 ]; then ok "scenario 9b (ad hoc reseed over a FAILED-marked hq): exits 0"; else bad "scenario 9b: expected exit 0, got $RC — $(tail -5 "$ROOT9B/out.log")"; fi
if [ -f "$ROOT9B/s3-meta-uploaded.json" ]; then ok "scenario 9b: a merged _meta/latest.json was uploaded"; else bad "scenario 9b: no fingerprint was uploaded"; fi
python3 - "$ROOT9B/seed-meta.json" "$ROOT9B/s3-meta-uploaded.json" > "$ROOT9B/merge-check.log" 2>&1 <<'PYCHECK'
import json, sys
seed = json.load(open(sys.argv[1]))
up = json.load(open(sys.argv[2]))
dbs = up.get("databases", {})
hq = dbs.get("hq")
if not isinstance(hq, dict) or hq.get("status", "ok") != "ok" or not hq.get("run_utc") or not hq.get("backup_size"):
    print("FAIL: hq still carries the failed mark (or lost its proof) after a successful re-prove:", hq)
else:
    print("PASS: hq's failed mark was replaced by a fresh proper entry (no failed status, run_utc + backup_size present)")
if dbs.get("otherdb") != seed["databases"]["otherdb"]:
    print("FAIL: the sibling's FAILED mark was not preserved byte-for-byte:", dbs.get("otherdb"))
else:
    print("PASS: the sibling db's FAILED mark passed through untouched (one db recovering never clears another)")
if dbs.get("gooddb") != seed["databases"]["gooddb"]:
    print("FAIL: an untouched good entry changed:", dbs.get("gooddb"))
else:
    print("PASS: an untouched good entry passed through byte-for-byte")
PYCHECK
cat "$ROOT9B/merge-check.log"
while read -r line; do
  case "$line" in "PASS:"*) PASS=$((PASS+1)) ;; "FAIL:"*) FAIL=$((FAIL+1)) ;; esac
done < "$ROOT9B/merge-check.log"
( DOLT_BACKUP_RESIDUE_RECLAIM_LIB=1 . "$HERE/dolt-backup-residue-reclaim.sh"
  P_OUT="$(mktemp)"
  : > "$P_OUT"; _parse_fingerprint_to_file "$ROOT9B/s3-meta-uploaded.json" "hq" "$P_OUT"
  [ -s "$P_OUT" ] && echo "  PASS: scenario 9b: after the merge the real parser reads hq as PROOF (the reseed re-proved it)" || echo "  FAIL: scenario 9b: hq should parse as proof after the reseed re-proved it"
  : > "$P_OUT"; _parse_fingerprint_to_file "$ROOT9B/s3-meta-uploaded.json" "otherdb" "$P_OUT"
  [ -s "$P_OUT" ] && echo "  FAIL: scenario 9b: the sibling's FAILED entry parsed as proof" || echo "  PASS: scenario 9b: the real parser still reads the sibling's FAILED entry as NO proof"
  rm -f "$P_OUT"
) > "$ROOT9B/parse-check.log" 2>&1
cat "$ROOT9B/parse-check.log"
while read -r line; do
  case "$line" in *"PASS:"*) PASS=$((PASS+1)) ;; *"FAIL:"*) FAIL=$((FAIL+1)) ;; esac
done < "$ROOT9B/parse-check.log"
rm -rf "$ROOT9B" 2>/dev/null

# ── Scenario 10 (ga-6xo4r0): the NEW post-swap S3 sync fails — must NEVER
#    unwind or fail the already-verified LOCAL swap (this bead's own
#    framing: "should a post-swap S3 failure unwind an already-verified
#    local promotion? almost certainly not"). Only the OFF-BOX proof is
#    delayed; the local backup itself is never in doubt.
ROOT10="/tmp/reseed-selftest-s10.$$"
setup_scenario "$ROOT10" 5 5 200
run_scenario "$ROOT10" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_S3_SYNC_FAIL=1
if [ "$RC" -eq 0 ]; then ok "scenario 10 (post-swap S3 sync fails): LOCAL swap still exits 0"; else bad "scenario 10: expected exit 0 (local swap succeeded regardless), got $RC — $(tail -5 "$ROOT10/out.log")"; fi
if [ -d "$ROOT10/city/.dolt-backup/hq.old" ]; then ok "scenario 10: .old still produced normally — the swap is unaffected by the S3 failure"; else bad "scenario 10: swap should be unaffected by an S3 sync failure"; fi
if grep -q "aws s3 sync FAILED" "$ROOT10/out.log" 2>/dev/null; then ok "scenario 10: sync failure logged distinctly"; else bad "scenario 10: missing the sync-failed log line"; fi
if grep -q "S3 fingerprint refresh FAILED" "$ROOT10/out.log" 2>/dev/null; then ok "scenario 10: non-fatal outcome logged (self-healing, retried on a future reseed)"; else bad "scenario 10: missing the non-fatal outcome log line"; fi
if [ -e "$ROOT10/s3-meta-uploaded.json" ]; then bad "scenario 10: fingerprint should never have been fetched/uploaded once the sync itself failed"; else ok "scenario 10: correctly never attempted the fingerprint fetch/merge after the sync failed"; fi
rm -rf "$ROOT10" 2>/dev/null

# ── Scenario 11 (ga-6xo4r0): the S3 sync succeeds but FETCHING the current
#    _meta/latest.json (to merge into) fails — must ABORT the publish
#    entirely rather than upload a partial doc that would erase every other
#    db's proof. Local swap still succeeds regardless (same non-fatal
#    contract as scenario 10).
ROOT11="/tmp/reseed-selftest-s11.$$"
setup_scenario "$ROOT11" 5 5 200
run_scenario "$ROOT11" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_AWS_FINGERPRINT_OK=0
if [ "$RC" -eq 0 ]; then ok "scenario 11 (fingerprint fetch fails): LOCAL swap still exits 0"; else bad "scenario 11: expected exit 0, got $RC — $(tail -5 "$ROOT11/out.log")"; fi
if grep -q "could not fetch current _meta/latest.json" "$ROOT11/out.log" 2>/dev/null; then ok "scenario 11: fetch failure logged distinctly"; else bad "scenario 11: missing the fetch-failed log line"; fi
if [ -e "$ROOT11/s3-meta-uploaded.json" ]; then bad "scenario 11: NEVER upload a partial doc when the current one couldn't be fetched — this would clobber every other db's proof"; else ok "scenario 11: correctly aborted BEFORE any upload — no sibling db's proof was put at risk"; fi
rm -rf "$ROOT11" 2>/dev/null

# ── Scenario 12 (ga-6xo4r0): RESEED_PUBLISH_FINGERPRINT=0 → the whole new
#    step is skipped, reverting to the pre-fix behavior (swap only) — same
#    escape-hatch shape as RESEED_ALLOW_LOW_DISK.
ROOT12="/tmp/reseed-selftest-s12.$$"
setup_scenario "$ROOT12" 5 5 200
run_scenario "$ROOT12" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 RESEED_PUBLISH_FINGERPRINT=0
if [ "$RC" -eq 0 ]; then ok "scenario 12 (kill switch on): exits 0"; else bad "scenario 12: expected exit 0, got $RC"; fi
if [ -d "$ROOT12/city/.dolt-backup/hq.old" ]; then ok "scenario 12: swap still happens normally"; else bad "scenario 12: swap should be unaffected by the kill switch"; fi
if grep -q "S3 fingerprint refresh SKIPPED" "$ROOT12/out.log" 2>/dev/null; then ok "scenario 12: escape hatch correctly logs SKIPPED"; else bad "scenario 12: missing the SKIPPED log line"; fi
if [ -e "$ROOT12/s3-sync.log" ] || [ -e "$ROOT12/s3-meta-uploaded.json" ]; then bad "scenario 12: kill switch should prevent ANY sync/publish call"; else ok "scenario 12: correctly made zero sync/publish calls with the kill switch on"; fi
rm -rf "$ROOT12" 2>/dev/null

echo ""
echo "── drift-guard: dolt-backup-reseed.sh wires _publish_after_swap into BOTH swap branches (ga-6xo4r0) ──"
if [ "$(grep -c '_publish_after_swap "\$DB" "\$BACKUP_DIR" "\$RESTORED_COUNT"' "$SCRIPT")" = "2" ]; then
  ok "_publish_after_swap is called from exactly the two successful-swap branches (normal + low-disk) — wiring is live, not dead code"
else
  bad "_publish_after_swap call count in the live script is not 2 — wiring changed or regressed"
fi

echo ""
echo "── drift-guard: AWS_REQUEST_CHECKSUM_CALCULATION export precedes both new upload call sites (ga-6xo4r0 / ga-tyaozh) ──"
EXPORT_LINE=$(grep -nF 'export AWS_REQUEST_CHECKSUM_CALCULATION=when_required' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -z "$EXPORT_LINE" ]; then
  bad "export AWS_REQUEST_CHECKSUM_CALCULATION=when_required line not found in live script at all"
else
  ok "export line present in live script (line $EXPORT_LINE)"
  for marker in \
    '"$AWS" s3 sync "$local_dir/" "s3://$BUCKET/$db/"' \
    '"$AWS" s3 cp "$merged_file" "s3://$BUCKET/_meta/latest.json"' \
  ; do
    CALL_LINE=$(grep -nF "$marker" "$SCRIPT" | head -1 | cut -d: -f1)
    if [ -z "$CALL_LINE" ]; then
      bad "drift-guard: upload call site not found (script changed shape?): $marker"
    elif [ "$CALL_LINE" -gt "$EXPORT_LINE" ]; then
      ok "drift-guard: upload call at line $CALL_LINE comes after the export (line $EXPORT_LINE): $marker"
    else
      bad "drift-guard: upload call at line $CALL_LINE comes BEFORE the export (line $EXPORT_LINE) — unprotected: $marker"
    fi
  done
fi

# ── drift-guard: dolt-s3-backup.sh actually wires the new classifiers/counter ──
echo "── drift-guard: dolt-s3-backup.sh wiring (ga-i99qsp) ──"
if grep -qF 'is_low_disk_proof_failed_refusal "$out"' "$S3_BACKUP_SCRIPT"; then
  ok "_reseed_staging_if_enabled calls is_low_disk_proof_failed_refusal — wiring is live"
else
  bad "_reseed_staging_if_enabled does NOT call is_low_disk_proof_failed_refusal — dead code"
fi
if grep -qF 'is_local_backup_lost_refusal "$out"' "$S3_BACKUP_SCRIPT"; then
  ok "_reseed_staging_if_enabled calls is_local_backup_lost_refusal — wiring is live"
else
  bad "_reseed_staging_if_enabled does NOT call is_local_backup_lost_refusal — dead code"
fi
if grep -qF '_margin_refusal_count_after_increment "$db"' "$S3_BACKUP_SCRIPT"; then
  ok "margin-refusal streak counter is wired into the margin-refusal branch"
else
  bad "margin-refusal streak counter NOT wired — invariant (d) regressed"
fi
if grep -qF '_margin_refusal_reset "$db"' "$S3_BACKUP_SCRIPT"; then
  ok "margin-refusal streak resets on reseed success"
else
  bad "margin-refusal streak never resets on success — would alarm on unrelated future streaks"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]

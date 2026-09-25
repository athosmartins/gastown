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
# Shared helpers (ga-gsnee8): a fake `aws` that emulates the BUCKET as a
# directory, and builders for realistic Dolt backup dirs (manifest + tables).
# The previous stub only answered head-object + _meta/latest.json — enough for
# the old "manifest object exists + size ratio" proof, and exactly why that
# proof could not tell a restorable S3 copy from an unrestorable one.
# ═══════════════════════════════════════════════════════════════════════════

# Table ids are 32 chars of Dolt's base32 charset; the manifest is colon-
# separated: <ver>:<storage>:<lock>:<root>:<gcgen>:<table-id>:<chunks>:...
tid() { printf '%032d' "$1"; }
LOCKH="0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; ROOTH="0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"; GCG="00000000000000000000000000000000"
mkmanifest() { # <file> <n_tables>
  local f="$1" n="$2" i s="5:__DOLT__:$LOCKH:$ROOTH:$GCG"
  for i in $(seq 1 "$n"); do s="$s:$(tid "$i"):$((i*7))"; done
  printf '%s' "$s" > "$f"
}
mk_backup_tables() { # <dir> <n_tables> — tables 1..n, odd ones raw, even ones .darc (both are normal)
  local d="$1" n="$2" i
  mkdir -p "$d"; mkmanifest "$d/manifest" "$n"
  for i in $(seq 1 "$n"); do
    if [ $((i%2)) -eq 1 ]; then printf 'data%s' "$i" > "$d/$(tid "$i")"; else printf 'darc%s' "$i" > "$d/$(tid "$i").darc"; fi
  done
}
s3_drop_table() { # <bucket-root> <db> <n> — the table object vanishes from the bucket; the manifest still names it
  rm -f "$1/$2/$(tid "$3")" "$1/$2/$(tid "$3").darc"
}

# write_fake_aws <path> — bucket = a directory ($FAKE_BUCKET_DIR, default ./bucket)
# laid out <bucket>/<db>/<object>. Every call is appended to $FAKE_AWS_CALLS
# (default ./aws-calls.log). Knobs: FAKE_S3_LIST_FAIL, FAKE_S3_DRYRUN_FAIL,
# FAKE_S3_UP_FAIL (uploads fail), FAKE_S3_UP_NOOP (uploads "succeed" but never
# land), FAKE_S3_SYNC_FAIL (the post-swap publish sync fails), and the older
# FAKE_AWS_MANIFEST_OK / FAKE_AWS_FINGERPRINT_OK / FAKE_FP_* /
# FAKE_S3_META_SEED_FILE for head-object and _meta/latest.json (still served so
# the incident is replicable against the PREVIOUS proof too: manifest object
# present + fingerprint entry present + size coherent).
write_fake_aws() {
  cat > "$1" <<'AWSEOF'
#!/bin/bash
FB="${FAKE_BUCKET_DIR:-./bucket}"
echo "aws $*" >> "${FAKE_AWS_CALLS:-./aws-calls.log}"
case "$*" in
  *"s3api head-object"*)
    [ "${FAKE_AWS_MANIFEST_OK:-1}" = "1" ] && exit 0 || exit 254
    ;;
  *"s3api list-objects-v2"*)
    [ "${FAKE_S3_LIST_FAIL:-0}" = "1" ] && exit 255
    prefix=""; while [ $# -gt 0 ]; do [ "$1" = "--prefix" ] && prefix="$2"; shift; done
    d="$FB/${prefix%/}"
    if [ ! -d "$d" ] || [ -z "$(ls -A "$d" 2>/dev/null)" ]; then echo "None"; exit 0; fi
    out=""; for f in "$d"/*; do out="${out:+$out	}${prefix}$(basename "$f")"; done
    echo "$out"; exit 0
    ;;
  *"s3 sync"*"--dryrun"*)
    # identity check: $3=<dir>/ $4=s3://B/<db>/ — list what a real sync WOULD upload
    [ "${FAKE_S3_DRYRUN_FAIL:-0}" = "1" ] && exit 2
    dir="${3%/}"; key="${4#s3://*/}"; key="${key%/}"
    for f in "$dir"/*; do
      [ -f "$f" ] || continue; n="$(basename "$f")"; [ "$n" = "LOCK" ] && continue
      if [ ! -f "$FB/$key/$n" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$FB/$key/$n")" ]; then
        echo "(dryrun) upload: $f to $4$n"
      fi
    done
    exit 0
    ;;
  *"s3 sync"*"--exclude manifest"*)
    # the proof's ADDITIVE repair upload (tables first; the manifest goes last, via s3 cp)
    [ "${FAKE_S3_UP_FAIL:-0}" = "1" ] && exit 1
    [ "${FAKE_S3_UP_NOOP:-0}" = "1" ] && exit 0
    dir="${3%/}"; key="${4#s3://*/}"; key="${key%/}"; mkdir -p "$FB/$key"
    for f in "$dir"/*; do
      [ -f "$f" ] || continue; n="$(basename "$f")"
      case "$n" in manifest|LOCK) continue ;; esac
      if [ ! -f "$FB/$key/$n" ] || [ "$(wc -c < "$f")" != "$(wc -c < "$FB/$key/$n")" ]; then cp "$f" "$FB/$key/$n"; fi
    done
    exit 0
    ;;
  *"s3 sync"*)
    # the post-swap PUBLISH sync (ga-6xo4r0): logged where Part 3 expects it
    echo "$*" >> ./s3-sync.log
    printf '%s\n' "${AWS_REQUEST_CHECKSUM_CALCULATION:-<unset>}" >> ./s3-sync-checksum-env.log
    [ "${FAKE_S3_SYNC_FAIL:-0}" = "1" ] && exit 1 || exit 0
    ;;
  *"s3 cp"*"/manifest"*)
    case "$3" in
      s3://*)   # download: aws s3 cp s3://B/<db>/manifest <dest>
        key="${3#s3://*/}"; [ -f "$FB/$key" ] || exit 1; cp "$FB/$key" "$4"; exit 0 ;;
      *)        # upload: aws s3 cp <dir>/manifest s3://B/<db>/manifest
        [ "${FAKE_S3_UP_FAIL:-0}" = "1" ] && exit 1
        [ "${FAKE_S3_UP_NOOP:-0}" = "1" ] && exit 0
        key="${4#s3://*/}"; mkdir -p "$FB/$(dirname "$key")"; cp "$3" "$FB/$key"; exit 0 ;;
    esac
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
  chmod +x "$1"
}

# ═══════════════════════════════════════════════════════════════════════════
# Part 1: _s3_current_backup_verified() — LIB-mode unit tests, fake bucket
# ═══════════════════════════════════════════════════════════════════════════
echo "── _s3_current_backup_verified() (ga-i99qsp / ga-gsnee8) ──"

LIB_SCRATCH="/tmp/reseed-selftest-lib.$$"
mkdir -p "$LIB_SCRATCH/bin"
write_fake_aws "$LIB_SCRATCH/bin/aws"
export FAKE_BUCKET_DIR="$LIB_SCRATCH/bucket" FAKE_AWS_CALLS="$LIB_SCRATCH/aws-calls.log"
FB="$FAKE_BUCKET_DIR"; mkdir -p "$FB"; : > "$FAKE_AWS_CALLS"

# RESEED_LOG points at scratch: log() tees to $LOG, which would otherwise be the
# REAL city reseed log — a hermetic test must not write test lines into it.
RESEED_LOG="$LIB_SCRATCH/reseed.log" PATH="$LIB_SCRATCH/bin:$PATH" DOLT_BACKUP_RESEED_LIB=1 . "$SCRIPT"

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

# ga-gsnee8: the proof's repair upload runs inside the callers' ~1800s budget and (in
# Passo 1.5) with NEW_DIR already built — a timeout mid-proof strands .new, which
# Preflight 3 then refuses forever. So the reseed bounds it below the lib defaults
# (2 rounds x 1500s) and routes the upload output into its own log.
if [ "${S3PROOF_REPAIR_ROUNDS:-}" = "1" ] && [ "${S3PROOF_UP_TIMEOUT:-}" = "600" ] && [ "${S3PROOF_TIMEOUT:-}" = "120" ]; then
  ok "reseed bounds the proof (1 repair round, 600s upload, 120s read-only calls) — below the lib defaults, inside the callers' budget"
else
  bad "reseed left the proof's budget at rounds='${S3PROOF_REPAIR_ROUNDS:-}' upload_timeout='${S3PROOF_UP_TIMEOUT:-}' read_timeout='${S3PROOF_TIMEOUT:-}' (want 1 / 600 / 120)"
fi
if [ "${S3PROOF_LOG:-}" = "$LOG" ]; then ok "the proof's upload output goes to the reseed log"; else bad "S3PROOF_LOG='${S3PROOF_LOG:-}' is not the reseed log '$LOG'"; fi

LOCALDIR="$LIB_SCRATCH/local-hq"
reset_lib_case() {   # a closed LOCAL backup + an identical, closed copy already in the fake bucket
  rm -rf "$FB" "$LOCALDIR"; mkdir -p "$FB"; : > "$FAKE_AWS_CALLS"
  mk_backup_tables "$LOCALDIR" 6
  dd if=/dev/zero of="$LOCALDIR/data.bin" bs=1M count=2 >/dev/null 2>&1
  cp -R "$LOCALDIR" "$FB/hq"
  unset FAKE_S3_LIST_FAIL FAKE_S3_DRYRUN_FAIL FAKE_S3_UP_FAIL FAKE_S3_UP_NOOP FAKE_AWS_FINGERPRINT_OK FAKE_FP_DB FAKE_FP_SIZE
}
n_uploads() { grep -c -- '--exclude manifest' "$FAKE_AWS_CALLS"; }

reset_lib_case
_s3_current_backup_verified hq "$LOCALDIR" \
  && ok "closed local + closed identical S3 → verified true" \
  || bad "closed local + closed identical S3 → should have verified true"
[ "$(n_uploads)" -eq 0 ] && ok "…and nothing was uploaded (nothing to repair)" || bad "uploaded although S3 was already proven"

# INCIDENT REPLICA (hq, 2026-09-25): the manifest OBJECT exists in S3, the fingerprint
# has an entry for the db with a coherent size, but a table the manifest names is NOT
# in the bucket — and the upload path is broken (ga-tyaozh), so it cannot be repaired.
# The previous proof (head-object + size ratio) called this good.
reset_lib_case; s3_drop_table "$FB" hq 3
[ -f "$FB/hq/manifest" ] && ok "setup: the manifest OBJECT exists in S3 (all the previous proof checked)" || bad "setup: manifest object missing"
FAKE_S3_UP_FAIL=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=2M \
  _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "INCIDENT: manifest object present + fingerprint entry + size coherent + a named table MISSING from S3 was VERIFIED (the hq 2026-09-25 defect)" \
  || ok "INCIDENT replica: manifest object exists, fingerprint coherent, but a manifest table is missing from S3 and cannot be repaired → REFUSED"

# Same replica, upload works: the proof REPAIRS S3 (tables first, manifest last), then proves.
reset_lib_case; s3_drop_table "$FB" hq 3; rm -f "$FB/hq/data.bin"
_s3_current_backup_verified hq "$LOCALDIR" \
  && ok "same replica, repairable: repaired S3, then proven → verified true" \
  || bad "repairable replica did not converge to a proof"
[ -f "$FB/hq/$(tid 3)" ] && [ -f "$FB/hq/data.bin" ] && ok "…S3 now holds the missing table and the never-uploaded file (it RESTORES)" || bad "S3 still lacks the table/file after the repair"
[ "$(n_uploads)" -eq 1 ] && ok "…with exactly one repair round (the reseed's bounded budget)" || bad "expected 1 repair upload, saw $(n_uploads)"
grep -- '--exclude manifest' "$FAKE_AWS_CALLS" | grep -q -- '--delete' && bad "the repair upload used --delete" || ok "…and the repair is ADDITIVE (never --delete)"

# An upload that "succeeds" but never lands cannot loop or pass.
reset_lib_case; s3_drop_table "$FB" hq 3
FAKE_S3_UP_NOOP=1 _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "an upload that never lands was reported as proven" \
  || ok "upload that never lands → NOT proven (bounded, no false pass)"

reset_lib_case; rm -f "$FB/hq/manifest"
FAKE_S3_UP_FAIL=1 _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "S3 without a manifest, unrepairable, was verified" \
  || ok "no manifest in S3 and the repair cannot upload → REFUSED"

reset_lib_case
FAKE_S3_LIST_FAIL=1 _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "a listing failure was verified" \
  || ok "listing the bucket fails → REFUSED (unknown ≠ fine)"

reset_lib_case
FAKE_S3_DRYRUN_FAIL=1 _s3_current_backup_verified hq "$LOCALDIR" \
  && bad "an identity-check failure was verified" \
  || ok "the identity check itself fails → REFUSED (unknown ≠ identical)"

# A broken LOCAL dir is never mirrored up over S3, and never authorizes a deletion.
reset_lib_case; rm -f "$LOCALDIR/$(tid 5)"; s3_drop_table "$FB" hq 2
_s3_current_backup_verified hq "$LOCALDIR" \
  && bad "a LOCAL dir missing a manifest table was verified" \
  || ok "local backup is not a closed backup → REFUSED"
[ "$(n_uploads)" -eq 0 ] && ok "…and nothing from the broken local dir was uploaded" || bad "the broken local dir was uploaded"

# The fingerprint is no longer the authority: the proof does not need it.
reset_lib_case
FAKE_AWS_FINGERPRINT_OK=0 _s3_current_backup_verified hq "$LOCALDIR" \
  && ok "fingerprint unreadable but S3 closed + identical → verified (identity is proven per file, not by a size ratio)" \
  || bad "an unreadable fingerprint vetoed a proven mirror"

rm -rf "$LIB_SCRATCH" 2>/dev/null
unset FAKE_BUCKET_DIR FAKE_AWS_CALLS

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

  # fake aws: the bucket-as-a-directory stub (write_fake_aws, defined above). Run
  # from $root (run_scenario cds there), so its ./bucket, ./aws-calls.log,
  # ./s3-sync.log and ./s3-meta-uploaded.json all land under $root.
  write_fake_aws "$root/bin/aws"

  # ga-gsnee8: the OLD backup dir is a realistic Dolt backup (a manifest naming 6
  # tables, all present) and the fake bucket already holds an identical copy — i.e.
  # by default S3 is HEALTHY (the pre-existing scenarios' "S3 proof passes"). A
  # scenario that wants a broken S3 damages $root/bucket/hq AFTER this returns.
  mk_backup_tables "$root/city/.dolt-backup/hq" 6
  mkdir -p "$root/bucket"
  cp -R "$root/city/.dolt-backup/hq" "$root/bucket/hq"
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
# ga-gsnee8: the exact hq 2026-09-25 incident, not a missing manifest object: the manifest
# object EXISTS, the fingerprint has an entry for hq with a coherent size (20M vs the 20M old
# backup) — everything the previous proof looked at says "fine" — but a table the manifest
# names is gone from S3, and the upload path is broken so the proof cannot repair it.
s3_drop_table "$ROOT2/bucket" hq 3
run_scenario "$ROOT2" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_S3_UP_FAIL=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M
if [ "$RC" -ne 0 ]; then ok "scenario 2 (low-disk, S3 proof fails): exits non-zero"; else bad "scenario 2: expected non-zero exit, got 0"; fi
OLD_KB_AFTER=$(du -sk "$ROOT2/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 2: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 2: old backup should be unchanged, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB"; fi
if [ -e "$ROOT2/city/.dolt-backup/hq.new" ]; then bad "scenario 2: .new leftover should have been cleaned up on proof failure"; else ok "scenario 2: .new correctly cleaned up on proof failure"; fi
if grep -q "prova do S3 FALHOU" "$ROOT2/out.log" 2>/dev/null; then ok "scenario 2: distinctive 'prova do S3 FALHOU' message present"; else bad "scenario 2: missing the distinctive proof-failed message"; fi
if grep -q "are MISSING from the bucket" "$ROOT2/out.log" 2>/dev/null; then ok "scenario 2: the log names WHY — a manifest table is missing from S3 (the copy does not restore)"; else bad "scenario 2: the log does not say the S3 copy is missing a manifest table"; fi
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
# ga-gsnee8: same incident replica as scenario 2 (manifest object + coherent fingerprint
# entry present, a manifest table missing from S3, upload path broken).
s3_drop_table "$ROOT7/bucket" hq 3
run_scenario "$ROOT7" FAKE_LIVE_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_S3_UP_FAIL=1 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M
if [ "$RC" -ne 0 ]; then ok "scenario 7 (ultra-low-disk, S3 proof fails): exits non-zero"; else bad "scenario 7: expected non-zero exit, got 0"; fi
OLD_KB_AFTER=$(du -sk "$ROOT7/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 7: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 7: old backup should be unchanged, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB"; fi
if [ -e "$ROOT7/city/.dolt-backup/hq.new" ]; then bad "scenario 7: .new should never have been created — the proof runs before Passo 1"; else ok "scenario 7: .new correctly never created (proof-before-write ordering)"; fi
if grep -q "modo ULTRA de baixo disco: prova do S3 FALHOU" "$ROOT7/out.log" 2>/dev/null; then ok "scenario 7: distinctive ultra-mode 'prova do S3 FALHOU' message present"; else bad "scenario 7: missing the distinctive proof-failed message"; fi
if grep -q "are MISSING from the bucket" "$ROOT7/out.log" 2>/dev/null; then ok "scenario 7: the log names WHY — a manifest table is missing from S3 (the copy does not restore)"; else bad "scenario 7: the log does not say the S3 copy is missing a manifest table"; fi
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

# ── Scenario 13 (ga-gsnee8): the SAME incident replica as scenario 7 (ultra mode; a
#    manifest table missing from S3 AND a file never uploaded) but the upload path
#    WORKS → the proof REPAIRS S3 (tables first, manifest last, additive), proves the
#    result, and only THEN frees the old. Freeing is safe at that point: S3 restores. ──
ROOT13="/tmp/reseed-selftest-s13.$$"
setup_scenario "$ROOT13" 10 20 35
s3_drop_table "$ROOT13/bucket" hq 3; rm -f "$ROOT13/bucket/hq/old-bloat.bin"
run_scenario "$ROOT13" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=20M
if [ "$RC" -eq 0 ]; then ok "scenario 13 (ultra, S3 repairable): exits 0"; else bad "scenario 13: expected exit 0, got $RC — $(tail -5 "$ROOT13/out.log")"; fi
if grep -q "repair/prove: round 1" "$ROOT13/out.log" 2>/dev/null; then ok "scenario 13: S3 was REPAIRED before the deletion (the proof did not just trust the manifest object)"; else bad "scenario 13: no repair round in the log — the broken S3 was not repaired"; fi
if [ -f "$ROOT13/bucket/hq/$(tid 3)" ] && [ -f "$ROOT13/bucket/hq/old-bloat.bin" ]; then ok "scenario 13: S3 now holds the missing table and the never-uploaded file (it restores)"; else bad "scenario 13: S3 still lacks the table/file"; fi
if grep -- '--exclude manifest' "$ROOT13/aws-calls.log" 2>/dev/null | grep -q -- '--delete'; then bad "scenario 13: the proof's repair upload used --delete (must be additive)"; else ok "scenario 13: the repair upload is additive (never --delete)"; fi
if grep -q "prova do S3 OK" "$ROOT13/out.log" 2>/dev/null; then ok "scenario 13: log has the S3-proof-OK line"; else bad "scenario 13: missing the S3-proof-OK line"; fi
if [ -e "$ROOT13/city/.dolt-backup/hq.old" ]; then bad "scenario 13: ultra path should not leave a .old"; else ok "scenario 13: old freed after the repaired proof, no .old residue"; fi
rm -rf "$ROOT13" 2>/dev/null

# ── Scenario 14 (ga-gsnee8): the ULTRA arithmetic counts the RESTORE copy. live=10M,
#    old=14M, free≈5M: freeing the old projects to ≈19M — above the ONE-copy bar the
#    mode used to require (1.2 x live = 12M) but below the TWO-copy bar (12M new copy +
#    10M restore copy = 22M). It used to prove S3, DELETE the old, then run the disk out
#    mid-restore (the ga-odtd3f class). Must refuse at Preflight 2: nothing deleted,
#    nothing built, S3 never even contacted. ──
ROOT14="/tmp/reseed-selftest-s14.$$"
setup_scenario "$ROOT14" 10 14 29
OLD_KB_BEFORE=$(du -sk "$ROOT14/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
run_scenario "$ROOT14" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=14M
if [ "$RC" -ne 0 ]; then ok "scenario 14 (ultra, freeing does not cover TWO copies): exits non-zero"; else bad "scenario 14: expected a refusal, got exit 0 — the mode proceeded with room for only one copy"; fi
OLD_KB_AFTER=$(du -sk "$ROOT14/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 14: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 14: old backup changed, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB — it was freed for room that could not fit the restore"; fi
if [ -e "$ROOT14/city/.dolt-backup/hq.new" ]; then bad "scenario 14: .new should never have been created"; else ok "scenario 14: .new never created"; fi
if grep -q "insuficiente até liberando o backup antigo" "$ROOT14/out.log" 2>/dev/null && grep -q "cópia da restauração" "$ROOT14/out.log" 2>/dev/null; then ok "scenario 14: refusal explains the two-copy arithmetic (new copy + restore copy)"; else bad "scenario 14: missing the two-copy refusal message"; fi
if [ -s "$ROOT14/aws-calls.log" ]; then bad "scenario 14: S3 was contacted although the arithmetic already refused (proof must come after)"; else ok "scenario 14: S3 never contacted — refusal happens before any proof or write"; fi
if ( PATH="$ROOT14/bin:$PATH" DOLT_S3_BACKUP_LIB=1 . "$S3_BACKUP_SCRIPT" >/dev/null 2>&1; is_disk_margin_refusal "$(cat "$ROOT14/out.log")" ); then ok "scenario 14: still classified as the (streak-tracked) disk-margin refusal"; else bad "scenario 14: not classified as a disk-margin refusal — the streak counter would not see it"; fi
rm -rf "$ROOT14" 2>/dev/null

# ── Scenario 15 (ga-gsnee8): the SAME class in the NORMAL low-disk mode (Passo 1.5).
#    live=10M, old=5M, free≈13M → low-disk mode (>= 12M, < 25M). After the new copy is
#    built ≈3M is free; the restore needs 12M; freeing the old (5M) only reaches ≈8M.
#    Deleting the old would not make room AND would leave the db with no local backup.
#    It used to prove S3 and delete anyway. Must refuse: old intact, new discarded. ──
ROOT15="/tmp/reseed-selftest-s15.$$"
setup_scenario "$ROOT15" 10 5 28
OLD_KB_BEFORE=$(du -sk "$ROOT15/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
run_scenario "$ROOT15" FAKE_LIVE_COUNT=50 FAKE_RESTORED_COUNT=50 FAKE_NEW_BACKUP_MB=10 FAKE_AWS_FINGERPRINT_OK=1 FAKE_FP_DB=hq FAKE_FP_SIZE=5M
if [ "$RC" -ne 0 ]; then ok "scenario 15 (low-disk, freeing the old would not make room for the restore): exits non-zero"; else bad "scenario 15: expected a refusal, got exit 0 — the old was freed for room that could not fit the restore"; fi
if grep -q "modo de baixo disco ativado" "$ROOT15/out.log" 2>/dev/null; then ok "scenario 15: entered the NORMAL low-disk mode (not ultra)"; else bad "scenario 15: setup did not enter the normal low-disk mode — the scenario does not test Passo 1.5"; fi
OLD_KB_AFTER=$(du -sk "$ROOT15/city/.dolt-backup/hq" 2>/dev/null | awk '{print $1}')
if [ "$OLD_KB_BEFORE" = "$OLD_KB_AFTER" ]; then ok "scenario 15: old backup UNCHANGED (${OLD_KB_AFTER}KB) — nothing deleted"; else bad "scenario 15: old backup changed, was ${OLD_KB_BEFORE}KB now ${OLD_KB_AFTER}KB"; fi
if [ -e "$ROOT15/city/.dolt-backup/hq.new" ]; then bad "scenario 15: the unverified .new should have been discarded"; else ok "scenario 15: .new (unverified) discarded"; fi
if grep -q "disco insuficiente para a verificação mesmo liberando o backup antigo" "$ROOT15/out.log" 2>/dev/null; then ok "scenario 15: distinctive 'even freeing the old' refusal message present"; else bad "scenario 15: missing the refusal message"; fi
if [ -s "$ROOT15/aws-calls.log" ]; then bad "scenario 15: S3 was contacted — the sufficiency check must come before the proof (no point proving S3 for a deletion that cannot help)"; else ok "scenario 15: S3 never contacted — refused before the proof"; fi
if ( PATH="$ROOT15/bin:$PATH" DOLT_S3_BACKUP_LIB=1 . "$S3_BACKUP_SCRIPT" >/dev/null 2>&1; is_disk_margin_refusal "$(cat "$ROOT15/out.log")" ); then ok "scenario 15: classified as the (streak-tracked) disk-margin refusal"; else bad "scenario 15: not classified as a disk-margin refusal"; fi
rm -rf "$ROOT15" 2>/dev/null

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


# ── drift-guard: every path that DELETES the old local backup goes through the
#    manifest-closure proof (ga-gsnee8) ──
echo "── drift-guard: reseed's early deletion of the old backup is authorized only by the manifest-closure proof (ga-gsnee8) ──"
if grep -qF '_s3proof_repair_then_prove "$local_dir" "$db"' "$SCRIPT"; then
  ok "_s3_current_backup_verified delegates to _s3proof_repair_then_prove (the lib is executed, not reimplemented)"
else
  bad "_s3_current_backup_verified no longer calls _s3proof_repair_then_prove"
fi
if grep -qE '^\. .*dolt-backup-s3-proof\.sh"' "$SCRIPT"; then ok "reseed sources dolt-backup-s3-proof.sh"; else bad "reseed does not source dolt-backup-s3-proof.sh — _s3proof_repair_then_prove would be undefined"; fi
if grep -qF 's3api head-object' "$SCRIPT"; then bad "the weak head-object proof is back in reseed (an object's existence says nothing about restoring)"; else ok "no head-object proof in reseed"; fi
N_VERIFY=$(grep -c '_s3_current_backup_verified "\$DB" "\$BACKUP_DIR"' "$SCRIPT")
N_RM=$(grep -c 'rm -rf "\$BACKUP_DIR"' "$SCRIPT")
if [ "$N_VERIFY" = "2" ] && [ "$N_RM" = "$N_VERIFY" ]; then
  ok "exactly $N_RM place(s) delete the old backup and exactly as many proof call sites guard them (Passo 0.5 + Passo 1.5)"
else
  bad "deletion sites ($N_RM) and proof call sites ($N_VERIFY) diverge (want 2 and 2) — a deletion path may have lost its proof"
fi

echo "=== RESULT: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]

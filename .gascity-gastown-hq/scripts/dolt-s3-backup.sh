#!/bin/bash
# dolt-s3-backup.sh — OFF-BOX (S3) backup of the city's Dolt bead stores.
#
# WHY: the single Dolt server (port from gc dolt status) holds every rig's beads —
# issues, mail, work history, and sensitive debt/CPF work. `gc doctor` flagged that
# NO off-box backup existed: a disk/host loss would lose it all. This closes that gap.
#
# MECHANISM (empirically chosen for Dolt 2.1.8 — see the header of the commit / report):
#   Dolt 2.1.8 does NOT accept a plain s3:// backup URL ("unknown url scheme: 's3'"),
#   and its aws:// scheme REQUIRES a DynamoDB manifest table (extra infra + couples
#   restore to DynamoDB). So we use the canonical Gas Town two-stage pattern, off-boxed
#   to S3 instead of iCloud:
#     1. native, transactionally-consistent  CALL DOLT_BACKUP('sync', <db>-backup)
#        -> a LOCAL file:// staging store at .dolt-backup/<db> (also what gc doctor
#        checks for; kept because it makes both stages INCREMENTAL and enables an
#        instant local restore).
#        ⚠️ CORRECTED DOCTRINE (ga-8f1uh0, 2026-09-16): the line that used to be here
#        ("Dolt GCs on backup, so staging << live noms") is FALSE — dolt-backup-reseed.sh
#        (ga-ydrg9) already found and documented this: DOLT_BACKUP sync is APPEND-ONLY
#        and never shrinks when the live source is compacted/squashed, so staging only
#        ever grows. Measured 2026-09-16: hq alone was 13G local vs 6.9G live (~2x),
#        gastown ~3x, whatsapp_automation ~2.6x — and it crashed Dolt twice that day on
#        "no space left on device". See _reseed_staging_if_enabled below for the fix.
#     2. aws s3 sync .dolt-backup/<db>/ -> s3://<bucket>/<db>/  (incremental; --delete
#        prunes orphans; bucket VERSIONING retains history so a stable prefix gives
#        point-in-time recovery without a full copy per day).
#
# SAFETY: READ + export only. Never stops/restarts Dolt, never touches a live .dolt or
# noms/LOCK. If the server is unreachable at the preflight check it retries a few times
# with spaced waits (ga-abrbt: a transient blip used to cost the whole day), then SKIPS
# if still unreachable (never restarts, at any point). Silent on success (Athos
# preference); notifies via `notify` only on failure. Bounded by per-db timeouts
# and a single-instance lock. Restore procedure: see RESTORE section at the bottom.
set -uo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-offline-backup-sync.sh"

CITY="/Users/athos/gt/.gascity-gastown-hq"
DOLT_CFG="$CITY/.gc/runtime/packs/dolt/dolt-config.yaml"
BACKUP_ROOT="$CITY/.dolt-backup"          # local staging (incremental; gc-doctor expects it)
# ga-7gfd34: mol-dog-jsonl's archive — a LOCAL-only git repo (no push remote
# configured; see the bead's prior-art) holding the only fresh copy of every
# store's bead history as JSONL. Mirrored to S3 below, independent of the
# per-db DOLT_BACKUP loop.
JSONL_ARCHIVE_DIR="$CITY/.gc/runtime/packs/maintenance/jsonl-archive"
JSONL_ARCHIVE_VERIFY_FILE="hq.jsonl"      # post-sync verify target
BUCKET="urblink-dolt-backups"
S3="s3://$BUCKET"
LOG="$CITY/.gc/logs/dolt-s3-backup.log"
NOTIFY="/Users/athos/.local/bin/notify"
AWS="$(command -v aws || echo /opt/homebrew/bin/aws)"
# ga-tyaozh: aws-cli/botocore (>= ~2.33; confirmed empirically here on 2.34.48)
# defaults request_checksum_calculation to "when_supported", which wraps every
# S3 PutObject/UploadPart body in botocore.httpchecksum.AwsChunkedWrapper (a
# chunked-transfer trailing-checksum encoding). On a dropped connection,
# botocore's retry path tries to rewind that wrapper; when the rewind raises
# for any reason, botocore converts it into UnseekableStreamError ("Need to
# rewind the stream <AwsChunkedWrapper ...>, but stream is not seekable"),
# aborting the whole upload instead of completing the retry — this is exactly
# what hit hq's backup at 2026-09-21 04:06 and, by starving hq's local staging
# reseed, cascaded into the day's disk-pressure outage. PutObject/UploadPart
# both have requestChecksumRequired=false (verified against this install's
# own botocore S3 service model), so "when_required" skips the wrapper
# entirely for every plain upload this script does — verified empirically via
# `aws --debug s3 cp` against the real bucket: with this var set, the request
# body is a plain (genuinely seekable) s3transfer.utils.ReadFileChunk, with no
# AwsChunkedWrapper and no Content-Encoding/Transfer-Encoding/X-Amz-Trailer
# headers at all. Exported once here so it covers every "$AWS" s3 upload below
# (JSONL mirror, per-db sync, fingerprint publish) without touching each call
# site individually.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
DOLT="$(command -v dolt || echo /opt/homebrew/bin/dolt)"
HOST="127.0.0.1"
LOCKDIR="$CITY/.gc/logs/.dolt-s3-backup.lock.d"
LOCK_STALE_MIN=180                        # reclaim a lock older than this (crash recovery)
SYNC_TIMEOUT=600                          # per-db native DOLT_BACKUP sync
S3_TIMEOUT=1200                           # per-db aws s3 sync
PREFLIGHT_TIMEOUT=30                       # server reachability probe
RETRY_WAITS_SEC="20 60 120"               # ga-gdsq5: escalating pauses, one connection-timeout retry per wait
# ga-8f1uh0: reuse the already-verified reseed mechanism (fresh backup -> restore
# -> row-count verify -> swap) to keep per-db local staging from growing without
# bound. Same timeout budget dolt-compact-routine.sh's own reseed call already
# uses. Opt-out escape hatch (RESEED_AFTER_UPLOAD=0) in case it ever needs to be
# disabled without a code change; on by default because the growth it prevents
# already crashed Dolt twice in one day.
RESEED_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dolt-backup-reseed.sh"
RESEED_TIMEOUT_SECS="${RESEED_TIMEOUT_SECS:-1800}"
RESEED_AFTER_UPLOAD="${RESEED_AFTER_UPLOAD:-1}"
# ga-i99qsp: dolt-backup-reseed.sh's own disk-margin refusal used to be purely
# "expected; retried next run" forever — for a db whose disk is CONSISTENTLY
# too tight (even for reseed's own low-disk fallback), that meant permanent
# silence, exactly the "silêncio repetido" shape ga-3euoj already named as a
# bug elsewhere in this city. Tracks consecutive margin-refusals PER DB in a
# tiny state dir; one notify_fail per streak once it reaches the threshold,
# then resets so the NEXT alarm only fires after another full streak (not
# every single cycle while the condition persists). Reset to 0 on any reseed
# success. Fail-soft: a bookkeeping problem here (can't write the state file)
# must never block or alter the backup flow itself — it only downgrades this
# one escalation to "never alarms," which is a regression, not a new outage.
MARGIN_REFUSAL_STATE_DIR="${RESEED_MARGIN_REFUSAL_STATE_DIR:-$CITY/.gc/logs/.dolt-reseed-margin-refusals}"
MARGIN_REFUSAL_ALARM_THRESHOLD="${RESEED_MARGIN_REFUSAL_ALARM_THRESHOLD:-3}"
# ga-o3nqy2: wiring for the shared server-free fallback (dolt-offline-backup-sync.sh).
# Read only by that sourced file's functions, not visibly within this one —
# the static analyzer can't see across the dynamic source path below.
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_CFG="$DOLT_CFG"
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_BIN="$DOLT"
# shellcheck disable=SC2034
OFFLINE_SYNC_LOG="$LOG"
# shellcheck disable=SC2034
OFFLINE_SYNC_TIMEOUT="$SYNC_TIMEOUT"      # same per-db budget as the server-mediated sync it falls back from

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }
notify_fail() { "$NOTIFY" -t "Dolt S3 backup" -p 4 "🚨 $*" 2>/dev/null || true; }

# ── PURE detection logic — unit-tested by dolt-s3-backup.selftest.sh ────────────
# ga-b5h83: Dolt's background archive/GC can conjoin a raw table file into a .darc
# archive on disk WITHOUT updating a stale LOCAL file:// backup manifest that still
# references the pre-archive raw filename. DOLT_BACKUP('sync', ...) reads that
# destination manifest for incremental diffing and chokes on the missing raw file.
# This is STRUCTURAL, not transient — retrying the identical sync always fails the
# same way; only a fresh full sync from a clean staging dir recovers.
is_stale_manifest_error() {
  case "$1" in
    *"table file not found"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ga-gdsq5: the managed server's listener.read_timeout_millis (30s, deliberately
# short — reaps abandoned per-call connections; see dolt-config.yaml's own
# comment) can also cut a legitimate CALL DOLT_BACKUP('sync', ...) that runs
# long under load against a large store (hq, 5.7GB+). This is TRANSIENT and
# load-dependent — the same backup succeeded the day before at the same db
# size — unlike is_stale_manifest_error above, no staging corruption is
# involved, so a bare retry (no reinit) can genuinely land in a different load
# window. Root cause (server-side read_timeout_millis) tracked separately in
# ga-gdsq5 — raising it requires a shared Dolt server restart, out of scope
# for this client-side mitigation.
is_connection_timeout_error() {
  case "$1" in
    *"connection was closed"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ga-8f1uh0: dolt-backup-reseed.sh refuses (exit 1, nothing touched) when it
# doesn't have its required 250%-of-live-size disk margin free — an EXPECTED,
# self-healing condition (retried every run; resolves once space recovers),
# not a data-integrity concern. Any OTHER reseed failure (new backup doesn't
# restore, restored count can't be read, restored count < live) is a real
# signal and must still notify_fail. Distinguishing the two by string-match on
# reseed's own die() message, same pattern as the two detectors above.
is_disk_margin_refusal() {
  case "$1" in
    *"disco insuficiente"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ga-8f1uh0: dolt-backup-reseed.sh also refuses (exit 1, nothing touched) when
# a PRIOR run's .old/.new residue is still on disk (its own Preflight 3) — it
# will not overwrite what might be an investigation in progress. Unlike a
# disk-margin refusal this is NOT self-healing: it will keep refusing on
# every future run until a human clears the residue once. Detected separately
# so its notify_fail message can say exactly what to do instead of a generic
# "ver $LOG" pointer.
is_stale_residue_refusal() {
  case "$1" in
    *"resíduo de uma execução anterior"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ga-i99qsp: dolt-backup-reseed.sh's low-disk fallback refuses (exit 1,
# NOTHING touched — no rename, no delete) when the S3 proof it needs before
# freeing the old copy early doesn't hold (manifest missing or size
# incoherent with the fingerprint). Unlike is_disk_margin_refusal this is NOT
# the expected/self-healing case — the db stays bloated until whatever broke
# the S3 proof is fixed (a failed upload, a stale fingerprint), so it must
# notify_fail with its own specific message rather than the generic one.
is_low_disk_proof_failed_refusal() {
  case "$1" in
    *"prova do S3 FALHOU"*) return 0 ;;
    *) return 1 ;;
  esac
}

# ga-i99qsp: the low-disk fallback's worst case — it already freed the old
# local copy (S3 proof passed) and something AFTER that failed (rebuild
# didn't restore, restored count unreadable/short, or the final promote mv
# itself failed). <db> now has NO local backup at all; the S3 copy from
# before the deletion is the only fallback until this is fixed by hand. This
# must never be silently absorbed into a generic "failed, see log" line —
# it changes what dolt-restore-verify.sh's local-restore checks can rely on.
is_local_backup_lost_refusal() {
  case "$1" in
    *"SEM BACKUP LOCAL"*) return 0 ;;
    *) return 1 ;;
  esac
}

# _margin_refusal_count_after_increment <db> — increments (creating if
# absent) the per-db consecutive-margin-refusal counter and echoes the NEW
# count. Fail-soft: if the state dir can't be created/written, echoes the
# threshold itself so a persistent bookkeeping failure surfaces as an alarm
# rather than silently disabling the escalation this function exists for.
_margin_refusal_count_after_increment() {
  local db="$1" f n
  if ! mkdir -p "$MARGIN_REFUSAL_STATE_DIR" 2>/dev/null; then
    echo "$MARGIN_REFUSAL_ALARM_THRESHOLD"
    return
  fi
  f="$MARGIN_REFUSAL_STATE_DIR/$db"
  n="$(cat "$f" 2>/dev/null)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n+1))
  echo "$n" > "$f" 2>/dev/null
  echo "$n"
}

# _margin_refusal_reset <db> — clears the streak counter: called on any
# reseed success (the condition resolved) and right after an alarm fires (so
# the NEXT alarm needs another full streak, not one refusal more).
_margin_refusal_reset() {
  rm -f "$MARGIN_REFUSAL_STATE_DIR/$1" 2>/dev/null || true
}

# ga-odtd3f: neither the initial CALL DOLT_BACKUP('sync', ...) attempt below
# nor its retry/fallback paths (_sync_with_connection_timeout_retry,
# _sync_with_stale_manifest_recovery, the offline-sync fallback) had ANY
# disk-space check of their own — unlike dolt-backup-reseed.sh's Preflight 2,
# which only guards the LATER shrink step this script triggers via
# _reseed_staging_if_enabled below. Measured 2026-09-21: with
# .dolt-backup/hq already bloated (append-only, never shrinks itself — see
# the file header), this let the sync write into .dolt-backup/hq/ until the
# LIVE Dolt server's own noms journal (same physical disk) hit "no space
# left on device" and crashed — three times in one morning (~04:20, ~09:07,
# ~09:33), ~5h20 outage. Each crash freed nothing, and nothing stopped the
# next attempt (server auto-restart, or the next retry wait) from writing
# into the same still-full disk again.
#
# Same disk-query convention as dolt-backup-reseed.sh (/System/Volumes/Data,
# NOT `df /` — "df / MENTE no macOS", already burned this city once) but a
# separate, independently-tunable margin/env-var namespace: this codebase's
# established rule is that one script's safety margin must never silently
# change another's (dolt-restore-verify.sh's own header states the same
# rule for its margin).
SYNC_DISK_MARGIN_PCT="${SYNC_DISK_MARGIN_PCT:-150}"  # % of live db size required free
SYNC_DISK_FLOOR_GB="${SYNC_DISK_FLOOR_GB:-3}"         # absolute backstop for small dbs

# _sync_disk_preflight <db> — 0 (proceed) if free space on
# /System/Volumes/Data covers SYNC_DISK_MARGIN_PCT% of <db>'s current live
# on-disk size (floored at SYNC_DISK_FLOOR_GB), 1 (refuse) otherwise. Logs
# its own reason either way. Fail-closed: an unreadable live size or
# free-space number refuses rather than proceeding on a guess — same
# posture as every other preflight in this city's Dolt backup scripts.
_sync_disk_preflight() {
  local db="$1"
  local live_kb free_kb need_kb floor_kb
  live_kb="$(du -sk "$CITY/.beads/dolt/$db" 2>/dev/null | awk '{print $1}')"
  case "${live_kb:-}" in
    ''|*[!0-9]*)
      log "$db: sync preflight: could not measure live db size at $CITY/.beads/dolt/$db — refusing (fail-closed)"
      return 1
      ;;
  esac
  free_kb="$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4}')"
  case "${free_kb:-}" in
    ''|*[!0-9]*)
      log "$db: sync preflight: could not measure free disk space — refusing (fail-closed)"
      return 1
      ;;
  esac
  need_kb=$(( live_kb * SYNC_DISK_MARGIN_PCT / 100 ))
  floor_kb=$(( SYNC_DISK_FLOOR_GB * 1024 * 1024 ))
  [ "$need_kb" -lt "$floor_kb" ] && need_kb="$floor_kb"
  if [ "$free_kb" -lt "$need_kb" ]; then
    log "$db: sync preflight REFUSED — disco insuficiente (livre=$((free_kb/1024))MB precisa=$((need_kb/1024))MB, vivo=$((live_kb/1024))MB, margem=${SYNC_DISK_MARGIN_PCT}%, piso=${SYNC_DISK_FLOOR_GB}GB) — não vou escrever até o Dolt morrer (precedente: ga-odtd3f, 2026-09-21, outage de ~5h20)"
    return 1
  fi
  log "$db: sync preflight OK (livre=$((free_kb/1024))MB >= precisa=$((need_kb/1024))MB, vivo=$((live_kb/1024))MB)"
  return 0
}

# _sync_once <db> — one CALL DOLT_BACKUP('sync', ...) attempt for <db>; raw
# dolt output goes wherever the caller redirects, dolt's own exit code is
# returned. Factored out so the retry loop below and the selftest's
# simulated-failure stub share the exact same call shape.
_sync_once() {
  local db="$1"
  DOLT_CLI_PASSWORD='' timeout "$SYNC_TIMEOUT" "$DOLT" --host "$HOST" --port "$PORT" \
    --user root --no-tls sql -q "USE \`$db\`; CALL DOLT_BACKUP('sync', '${db}-backup');"
}

# _sync_with_connection_timeout_retry <db> — called after an initial sync
# attempt already failed with is_connection_timeout_error. Retries
# _sync_once with escalating waits (RETRY_WAITS_SEC: 20s, 60s, 120s),
# logging every attempt for frequency tracking. Returns 0 on the first
# success; returns 1, having logged the "DOLT_BACKUP sync FAILED" line
# dolt-compact-routine.sh's backup precondition greps for, once every wait
# has been used. ga-gdsq5: the original single 20s retry sometimes wasn't
# enough against hq under load (measured 2026-09-11 04:01: sync failed
# again after that one retry) — this is the escalation that replaces it.
_sync_with_connection_timeout_retry() {
  local db="$1" wait_sec
  for wait_sec in $RETRY_WAITS_SEC; do
    log "$db: connection-timeout on sync — retrying after ${wait_sec}s"
    sleep "$wait_sec"
    if ! _sync_disk_preflight "$db"; then
      log "$db: DOLT_BACKUP sync FAILED (disk preflight refused before connection-timeout retry)"
      return 1
    fi
    if _sync_once "$db" >> "$LOG" 2>&1; then
      log "$db: sync OK after connection-timeout retry"
      return 0
    fi
  done
  log "$db: DOLT_BACKUP sync FAILED (after connection-timeout retries)"
  return 1
}

# _sync_with_stale_manifest_recovery <db> <dest> — called after an initial
# sync attempt already failed with is_stale_manifest_error. Wipes the local
# staging dir (structural corruption per is_stale_manifest_error's own header
# — safely regenerable, never touches live .beads/dolt or S3) and retries
# ONCE via the server.
#
# ga-yct7r1: that server-mediated retry is PREDICTABLE to fail for the SAME
# structural reason the offline path exists for — a live server holds a
# cached view of the staging dir that was just wiped out from under it. That
# made this the one branch most likely to need the offline fallback and, until
# this fix, the one branch that didn't have it (the sibling
# is_connection_timeout_error branch already falls back to
# _offline_backup_sync below). So, same invariant as that branch: only count
# this db as failed if BOTH the reinit-retry AND the offline fallback fail.
# Returns 0 on either recovery path succeeding; returns 1 (having logged the
# FAILED tripwire dolt-compact-routine.sh's precondition greps for) otherwise.
_sync_with_stale_manifest_recovery() {
  local db="$1" dest="$2"
  log "$db: stale-manifest staging detected — auto-reinit ${dest} and retry once"
  case "$dest" in
    "$BACKUP_ROOT"/*) rm -rf "${dest:?}" ;;
    *) log "$db: REFUSING auto-reinit — dest '$dest' outside BACKUP_ROOT (safety guard)" ;;
  esac
  if ! _sync_disk_preflight "$db"; then
    log "$db: DOLT_BACKUP sync FAILED (disk preflight refused after stale-manifest reinit)"
    return 1
  fi
  if _sync_once "$db" >> "$LOG" 2>&1; then
    log "$db: auto-recover OK after staging reinit"
    return 0
  fi
  log "$db: stale-manifest retry FAILED — falling back to offline sync (no server involved)"
  if ! _sync_disk_preflight "$db"; then
    log "$db: DOLT_BACKUP sync FAILED (disk preflight refused before offline fallback)"
    return 1
  fi
  if _offline_backup_sync "$db" "$dest"; then
    log "$db: offline-sync fallback OK"
    return 0
  fi
  log "$db: DOLT_BACKUP sync FAILED (after stale-manifest recovery)"
  return 1
}

# _reseed_staging_if_enabled <db> — ga-8f1uh0: called AFTER this db's S3 sync
# above already succeeded. .dolt-backup/<db> is APPEND-ONLY (see the corrected
# header doctrine at the top of this file) so it only ever grows, independent
# of whether the live source shrinks — hq alone reached 13G local vs 6.9G live
# and crashed Dolt twice in one day on "no space left on device" (measured
# 2026-09-16). Athos authorized reducing the local copy (AskUserQuestion,
# Mayor session, 2026-09-16) with S3 already confirmed intact.
#
# Deliberately reuses dolt-backup-reseed.sh instead of a new delete-after-
# verify path: it is the already-hardened, adversarially-reviewed mechanism
# for exactly this problem (fresh backup in a new dir -> RESTORE it -> compare
# row counts against the LIVE source -> only then swap; old copy kept as
# .old for a human to clear). That is a stronger guarantee than diffing
# against S3 would be, and — critically — it never leaves .dolt-backup/<db>
# empty, so dolt-restore-verify.sh's own scheduled restores always still have
# a local copy to restore from between runs.
#
# Fail-closed by construction: reseed's own preflight refuses (no swap, no
# deletion, exit 1) without 250% of the live db size free AND a fresh backup
# that demonstrably restores with row count >= live. ga-i99qsp: reseed now
# ALSO has a low-disk fallback for exactly the case that used to make this an
# unconditional dead end for a chronically-tight db (hq: staging bloat itself
# ate the margin the fix needed) — see dolt-backup-reseed.sh's own header. A
# refusal for lack of disk margin is still logged, not alarmed, on the FIRST
# few occurrences (see is_disk_margin_refusal) because a transient tight day
# is expected and self-healing — but it now escalates to one notify_fail per
# consecutive streak (MARGIN_REFUSAL_ALARM_THRESHOLD) instead of staying
# silent forever, because "even the low-disk margin never fits" is no longer
# assumed to always self-heal. Any OTHER failure reason (including the two
# new low-disk-specific ones below) is a real signal and is notify_fail'd
# immediately, same channel as every other failure mode in this script.
_reseed_staging_if_enabled() {
  local db="$1"
  [ "$RESEED_AFTER_UPLOAD" = "1" ] || return 0
  local out rc
  out="$(timeout "$RESEED_TIMEOUT_SECS" "$RESEED_SCRIPT" "$db" 2>&1)"
  rc=$?
  echo "$out" >> "$LOG"
  if [ "$rc" -eq 0 ]; then
    log "$db: staging reseed OK (freed accumulated backup bloat)"
    _margin_refusal_reset "$db"
    return 0
  fi
  if is_disk_margin_refusal "$out"; then
    # ga-i99qsp: reseed itself now has a low-disk fallback (see its own
    # header) — this branch only still fires when even THAT minimal margin
    # isn't free, a genuinely more severe condition than the old "always
    # retried, always silent" framing assumed. Track the streak; escalate
    # once per streak instead of staying silent forever (ga-3euoj shape).
    local n; n="$(_margin_refusal_count_after_increment "$db")"
    if [ "$n" -ge "$MARGIN_REFUSAL_ALARM_THRESHOLD" ]; then
      log "$db: staging reseed skipped — insufficient disk margin for ${n} rodadas seguidas (mesmo o modo de baixo disco não coube) — ALARME"
      notify_fail "backup off-box: reseed de $db sem margem de disco por ${n} rodadas seguidas — mesmo o modo de baixo disco (dolt-backup-reseed.sh) não coube nesse tempo. Ver $LOG."
      _margin_refusal_reset "$db"
    else
      log "$db: staging reseed skipped — insufficient disk margin today (expected; retried next run; ${n}/${MARGIN_REFUSAL_ALARM_THRESHOLD} rodadas seguidas)"
    fi
    return 0
  fi
  if is_stale_residue_refusal "$out"; then
    log "$db: staging reseed BLOCKED — stale .old/.new residue from a prior run — ver $LOG"
    notify_fail "backup off-box: reseed de $db bloqueado por resíduo (.old ou .new) de execução anterior em ${BACKUP_ROOT}/${db}.old — remova à mão uma vez para destravar"
    return 1
  fi
  if is_low_disk_proof_failed_refusal "$out"; then
    log "$db: staging reseed (modo de baixo disco) recusado — prova do S3 falhou, NADA apagado — ver $LOG"
    notify_fail "backup off-box: reseed de $db em modo de baixo disco não conseguiu confirmar o S3 (manifest ausente ou tamanho incoerente) — NADA foi apagado, mas $db segue com o staging bloated até isso ser corrigido. Ver $LOG."
    return 1
  fi
  if is_local_backup_lost_refusal "$out"; then
    log "$db: staging reseed CRÍTICO — modo de baixo disco liberou o backup antigo e a reconstrução FALHOU depois — $db pode estar SEM BACKUP LOCAL — ver $LOG"
    notify_fail "backup off-box: reseed de $db em modo de baixo disco liberou o backup antigo (com prova do S3) e a reconstrução FALHOU — $db pode estar SEM BACKUP LOCAL agora. O S3 verificado antes da liberação é o único fallback. Ver $LOG imediatamente."
    return 1
  fi
  log "$db: staging reseed FAILED (rc=$rc, non-disk reason) — ver $LOG"
  notify_fail "backup off-box: reseed do staging de $db falhou por motivo != espaço — ver $LOG"
  return 1
}

# jsonl_sizes_match <local_size> <s3_size> — pure comparison shared by the live
# verify step and the selftest. Empty/non-numeric on EITHER side must NEVER
# compare equal: an unreadable remote size is the "don't know" case, which
# has to fail closed (verify FAILED), not silently pass as "no news is good
# news" (ga-7gfd34).
jsonl_sizes_match() {
  local local_size="$1" s3_size="$2"
  case "$local_size" in ''|*[!0-9]*) return 1 ;; esac
  case "$s3_size" in ''|*[!0-9]*) return 1 ;; esac
  [ "$local_size" -eq "$s3_size" ]
}

# jsonl_offsite_sync — ga-7gfd34: mirror JSONL_ARCHIVE_DIR (mol-dog-jsonl's
# LOCAL-only git archive; no push remote configured) to S3, excluding .git
# (~1.1GB of history no restore needs), then verify what actually landed by
# comparing the size of JSONL_ARCHIVE_VERIFY_FILE locally against the object
# S3 now reports. Called unconditionally after the per-db loop below,
# independent of that loop's own ok/failed outcome — a stuck hq DOLT_BACKUP
# must never skip this.
#
# Returns: 0 ok (synced + verified) | 1 failed (sync or verify) | 2 skipped
# (refused — see the pre-sync guard below).
#
# SAFETY: the sync uses --delete to prune S3 objects removed locally, exactly
# like the per-db syncs above. That makes an unexpectedly-empty/not-yet-
# populated source directory dangerous — it would read as "everything was
# removed" and WIPE the offsite copy instead of updating it. Refuse to sync
# at all unless JSONL_ARCHIVE_VERIFY_FILE is present first, checked BEFORE
# the destructive call, not after.
jsonl_offsite_sync() {
  if [ ! -f "$JSONL_ARCHIVE_DIR/$JSONL_ARCHIVE_VERIFY_FILE" ]; then
    log "jsonl-offsite: SKIP — $JSONL_ARCHIVE_VERIFY_FILE not present locally (archive looks empty/not yet populated); refusing a --delete sync against it"
    return 2
  fi
  if ! timeout "$S3_TIMEOUT" "$AWS" s3 sync "$JSONL_ARCHIVE_DIR/" "$S3/jsonl-archive/" \
        --exclude ".git/*" --delete --only-show-errors >> "$LOG" 2>&1; then
    log "jsonl-offsite: aws s3 sync FAILED"
    return 1
  fi
  local local_size s3_size
  local_size="$(wc -c < "$JSONL_ARCHIVE_DIR/$JSONL_ARCHIVE_VERIFY_FILE" 2>/dev/null | tr -d ' ')"
  s3_size="$("$AWS" s3api head-object --bucket "$BUCKET" \
        --key "jsonl-archive/$JSONL_ARCHIVE_VERIFY_FILE" \
        --query ContentLength --output text 2>>"$LOG")"
  if ! jsonl_sizes_match "$local_size" "$s3_size"; then
    log "jsonl-offsite: verify FAILED — local size=${local_size:-?} s3 size=${s3_size:-?} for $JSONL_ARCHIVE_VERIFY_FILE"
    return 1
  fi
  log "jsonl-offsite: verify OK — $JSONL_ARCHIVE_VERIFY_FILE size=$local_size matches S3"
  return 0
}

# _build_run_fingerprint <raw_file> <run_utc> <port> <ok> <failed> <total>
#   <discovered_dbs> <failed_dbs_text> <prev_fingerprint_file>
# Prints the run fingerprint (the body of _meta/latest.json) on stdout.
#
# ga-gjfe78: this used to rebuild the file from scratch out of the dbs that
# SUCCEEDED, so a db that failed (hq, every night since 2026-09-21) simply
# vanished from it — no entry, no failed mark, no last good date — which is
# indistinguishable from a db that never existed. Every consumer reads "no
# entry" as "not proven", so nothing unsafe happened, but only by accident, and
# the one place that says whether S3 is fresh never said that hq was failing.
#
# Now EVERY discovered db has an entry. A db with a row in <raw_file> succeeded
# and its entry is exactly the shape it always had (no new key — byte-identical
# on a good night, so existing readers see nothing). A db without one is
# published as
#   {"status":"failed","reason":<disco|sync|s3|unknown>,
#    "last_ok_run_utc":<ts|null>,"last_ok":{issues,head,backup_size}|null}
# and deliberately carries NO run_utc/issues/head/backup_size at its own top
# level: those are the keys a reader that predates this change takes as proof,
# so their absence keeps such a reader inert by construction. The last good
# values live only under "last_ok", which nothing reads as proof.
#
# WHO failed is the complement (discovered minus succeeded), not a parse of the
# failure text — text only supplies the reason, and an unparseable token costs
# "unknown", never a missing db (ga-p5q3). last_ok comes from <prev_fingerprint_
# file> (the previous night's file, fetched by the caller). null means NOT KNOWN
# and never "there was none": a db that is absent from the previous file could
# have never existed OR have been dropped from it by the very bug this fixes
# (the writer before ga-gjfe78 omitted failed dbs — hq's real last-ok is older
# than the file that stopped listing it), and an unreadable/malformed previous
# file, or an entry that cannot be trusted, is likewise "could not find out".
# A db that fails twice in a row carries its ORIGINAL last-ok forward; it is
# never reset to the previous failed night.
#
# An entry with no "status" is a legacy ok entry. The consumers
# (_parse_fingerprint_to_file in dolt-backup-residue-reclaim.sh, which
# dolt-backup-reseed.sh also sources) treat any status other than "ok" as NOT
# proven. dolt-backup-reseed.sh's per-db merge replaces the whole entry, so an
# ad hoc reseed that re-proves a failed db overwrites the failed mark.
_build_run_fingerprint() {
  python3 - "$@" <<'PY'
import json, re, sys

args = sys.argv[1:10]
args += [""] * (9 - len(args))
raw, run_utc, port, ok, failed, total, discovered, failed_text, prev_path = args

dbs = {}
try:
    with open(raw) as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) >= 4:
                dbs[p[0]] = {"issues": int(p[1]), "head": p[2], "backup_size": p[3]}
except FileNotFoundError:
    pass

reasons = {}
for tok in failed_text.split():
    m = re.match(r"^(.+)\(([A-Za-z0-9_-]+)\)$", tok)
    if m:
        reasons[m.group(1)] = m.group(2)

order = [d for d in discovered.split() if d]
seen = set(order)
for d in list(dbs) + list(reasons):
    if d not in seen:
        order.append(d)
        seen.add(d)

prev_dbs = None
prev_run = None
try:
    with open(prev_path) as f:
        prev = json.load(f)
    if isinstance(prev, dict) and isinstance(prev.get("databases"), dict):
        prev_dbs = prev["databases"]
        if isinstance(prev.get("run_utc"), str):
            prev_run = prev["run_utc"]
except Exception:
    pass


def last_ok_of(db):
    """(last_ok_run_utc, last_ok) for a db that failed this run; None = not known."""
    if prev_dbs is None or db not in prev_dbs:
        return (None, None)
    e = prev_dbs[db]
    if not isinstance(e, dict):
        return (None, None)
    if "status" not in e or e["status"] == "ok":
        ts = e["run_utc"] if isinstance(e.get("run_utc"), str) else prev_run
        return (ts, {"issues": e.get("issues"), "head": e.get("head"),
                     "backup_size": e.get("backup_size")})
    if e["status"] == "failed":
        ts = e.get("last_ok_run_utc")
        last_ok = e.get("last_ok")
        if (ts is None or isinstance(ts, str)) and (last_ok is None or isinstance(last_ok, dict)):
            return (ts, last_ok)
    return (None, None)


databases = {}
for db in order:
    if db in dbs:
        databases[db] = dbs[db]
        continue
    try:
        ts, last_ok = last_ok_of(db)
    except Exception:
        ts, last_ok = (None, None)
    databases[db] = {"status": "failed", "reason": reasons.get(db, "unknown"),
                     "last_ok_run_utc": ts, "last_ok": last_ok}

json.dump({"run_utc": run_utc, "port": int(port), "bucket": "urblink-dolt-backups",
           "ok": int(ok), "failed": int(failed), "total": int(total),
           "databases": databases}, sys.stdout, indent=2)
PY
}

# _publish_run_fingerprint — uploads $META as _meta/latest.json and as a dated
# _meta/<ts>.json copy. Returns 0 iff latest.json was uploaded.
#
# ga-dgnpyj: both uploads used to end in `|| true`, so a failed latest.json
# upload logged nothing and alarmed nobody. latest.json is the ONLY "S3 is fresh"
# proof the consumers have (dolt-backup-residue-reclaim.sh, dolt-backup-reseed.sh):
# when it stays at the previous night's file its older run_utc keeps them inert
# (safe), but residue-reclaim files that under "SPARED ... expected, self-healing",
# which never notifies — so a PERMANENT upload failure looked like a healthy
# quiet night. A failed write and "nothing to do" were the same value.
#
# Now: a failed latest.json upload is logged and notify_fail'd, and the
# "published" line is logged ONLY when it really was — so the run never reports
# a fingerprint it did not publish. The dated copy is audit-only (nothing reads it
# as proof), so its failure is logged but does not alarm and does not change the
# result. Both uploads are always attempted (independent), and one call = at most
# ONE notification, so one nightly run = one alarm.
#
# The upload lines below keep their literal shape: the selftest's drift-guard
# greps them to prove they come after `export AWS_REQUEST_CHECKSUM_CALCULATION`.
_publish_run_fingerprint() {
  local rc=0
  if "$AWS" s3 cp "$META" "$S3/_meta/latest.json" --only-show-errors >> "$LOG" 2>&1; then
    log "fingerprint: published _meta/latest.json (the S3 freshness proof is current)"
  else
    rc=1
    log "fingerprint: upload of _meta/latest.json FAILED — S3 keeps the previous run's fingerprint (older run_utc), so its freshness consumers stay inert with no signal of their own"
    notify_fail "backup off-box: upload do _meta/latest.json FALHOU — a prova de S3 fresco fica com a data da rodada anterior e os consumidores (residue-reclaim/reseed) seguem inertes sem alarme próprio; ver $LOG"
  fi
  if ! "$AWS" s3 cp "$META" "$S3/_meta/$(date -u +%Y%m%d-%H%M%S).json" --only-show-errors >> "$LOG" 2>&1; then
    log "fingerprint: upload of the dated _meta/<ts>.json copy failed (audit-only copy; latest.json result unaffected)"
  fi
  return "$rc"
}

# Library mode: `DOLT_S3_BACKUP_LIB=1 source dolt-s3-backup.sh` defines the pure
# functions above without running the live backup flow (lock/PORT/DOLT_BACKUP/S3).
if [ "${DOLT_S3_BACKUP_LIB:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

mkdir -p "$CITY/.gc/logs" "$BACKUP_ROOT" 2>/dev/null || true

# --- single-instance lock (portable; no flock dependency) with staleness reclaim ---
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +"$LOCK_STALE_MIN" 2>/dev/null)" ]; then
    log "reclaiming stale lock (> ${LOCK_STALE_MIN}m): $LOCKDIR"
    rmdir "$LOCKDIR" 2>/dev/null && mkdir "$LOCKDIR" 2>/dev/null || { log "lock race — exiting"; exit 0; }
  else
    log "another run holds the lock — exiting"
    exit 0
  fi
fi
META="$(mktemp)"; RAW="$(mktemp)"; SYNC_OUT="$(mktemp)"
cleanup() { rmdir "$LOCKDIR" 2>/dev/null || true; rm -f "$META" "$RAW" "$SYNC_OUT" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# --- read the Dolt port from the authoritative config each run (NEVER hardcode) ---
# Shared with dolt-offline-backup-sync.sh's own port check (ga-o3nqy2) so
# there is exactly one place that knows how to find the live port.
PORT="$(_offline_sync_live_port)"
if [ -z "$PORT" ]; then log "FATAL: could not determine Dolt port"; notify_fail "backup off-box abortado: porta do Dolt desconhecida"; exit 0; fi

dsql() { DOLT_CLI_PASSWORD='' "$DOLT" --host "$HOST" --port "$PORT" --user root --no-tls sql "$@"; }

log "=== run start (port=$PORT bucket=$BUCKET) ==="

# --- pre-flight: server must be reachable; NEVER touch a hung server ---
# ga-abrbt: a transient blip in reachability at exactly 04:00 (verified live
# 2026-09-05 and 2026-09-07: "FATAL: Dolt server unreachable" with no other
# symptom) used to cost the WHOLE day — no off-box backup at all, which in
# turn kills dolt-compact-routine.sh's 04:30 "backup fresh today"
# precondition for every hour after. Give a handful of short, spaced retries
# before giving up: this NEVER restarts Dolt (unchanged safety property —
# only re-probes the same read-only reachability check), and the worst-case
# total wait (10+20+40=70min) stays well inside this script's own 180min
# stale-lock window and the plist's 24h schedule gap, so a retrying run can
# never collide with tomorrow's scheduled fire.
PREFLIGHT_RETRY_WAITS_MIN="10 20 40"

_dolt_reachable() {
  DOLT_CLI_PASSWORD='' timeout "$PREFLIGHT_TIMEOUT" "$DOLT" --host "$HOST" --port "$PORT" \
    --user root --no-tls sql -q "SELECT 1" --result-format csv >/dev/null 2>&1
}

if ! _dolt_reachable; then
  log "WARN: Dolt server unreachable on $HOST:$PORT at first probe — retrying (waits: ${PREFLIGHT_RETRY_WAITS_MIN} min) before giving up for today (NOT restarting)"
  reachable=0
  for wait_min in $PREFLIGHT_RETRY_WAITS_MIN; do
    sleep "$(( wait_min * 60 ))"
    if _dolt_reachable; then
      log "Dolt server reachable again after a ${wait_min}min wait — resuming backup run"
      reachable=1
      break
    fi
    log "WARN: Dolt still unreachable after a ${wait_min}min wait"
  done
  if [ "$reachable" -ne 1 ]; then
    log "FATAL: Dolt server unreachable on $HOST:$PORT after retries (${PREFLIGHT_RETRY_WAITS_MIN} min) — skipping (NOT restarting)"
    notify_fail "backup off-box: Dolt inacessível em $HOST:$PORT mesmo após retries — pulado (sem restart)"
    exit 0
  fi
fi

# --- discover all real databases (exclude system schemas) ---
DBS="$(dsql -q "SHOW DATABASES" --result-format csv 2>/dev/null | tail -n +2 \
        | grep -vxE 'information_schema|mysql|dolt')"
if [ -z "$DBS" ]; then log "FATAL: no databases discovered"; notify_fail "backup off-box: nenhum banco descoberto"; exit 0; fi

total=0; ok=0; failed=0; FAILED_DBS=""
for db in $DBS; do
  total=$((total+1))
  dest="$BACKUP_ROOT/$db"
  # ensure the backup remote is registered (idempotent — tolerate "already exists")
  dsql -q "USE \`$db\`; CALL DOLT_BACKUP('add', '${db}-backup', 'file://${dest}');" >/dev/null 2>&1 || true
  # capture the commit we are about to back up BEFORE syncing. On an append-only beads
  # store this pre-sync HEAD is always an ancestor of (or equal to) what the sync
  # captures, so it is GUARANTEED present in the backup — which makes the recorded
  # fingerprint verifiable in a restore ("... issues AS OF '<head>'"). Reading it AFTER
  # the sync instead would race a hot store (e.g. hq) and record a commit newer than
  # the backup actually contains.
  head="$(dsql -q "SELECT commit_hash FROM \`$db\`.dolt_log ORDER BY date DESC LIMIT 1" --result-format csv 2>/dev/null | tail -1)"
  # 1) native consistent backup -> local staging (incremental)
  if ! _sync_disk_preflight "$db"; then
    failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(disco)"; continue
  fi
  if ! DOLT_CLI_PASSWORD='' timeout "$SYNC_TIMEOUT" "$DOLT" --host "$HOST" --port "$PORT" \
        --user root --no-tls sql -q "USE \`$db\`; CALL DOLT_BACKUP('sync', '${db}-backup');" > "$SYNC_OUT" 2>&1; then
    cat "$SYNC_OUT" >> "$LOG"
    if is_stale_manifest_error "$(cat "$SYNC_OUT")"; then
      # Structural staging corruption (see is_stale_manifest_error above).
      # ga-yct7r1: reinit-retry alone used to give up here with no fallback —
      # _sync_with_stale_manifest_recovery now falls back to the same
      # server-free _offline_backup_sync the connection-timeout branch below
      # already uses, before counting this db as failed.
      if ! _sync_with_stale_manifest_recovery "$db" "$dest"; then
        failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(sync)"; continue
      fi
    elif is_connection_timeout_error "$(cat "$SYNC_OUT")"; then
      # Transient/load-dependent (ga-gdsq5) — staging itself is fine, only the
      # connection was cut mid-sync, so retry the same sync with no reinit,
      # via escalating waits (RETRY_WAITS_SEC) to give a possibly-different
      # load window a few chances instead of just one.
      if ! _sync_with_connection_timeout_retry "$db"; then
        # ga-o3nqy2: retries exhausted — the bottleneck is the SERVER
        # CONNECTION (30s listener.read_timeout_millis), not the data, so no
        # amount of retrying the same server-mediated call would help (this
        # is why hq has failed every night since 2026-09-11). Fall back to
        # the server-free path before giving up on this db.
        log "$db: connection-timeout retries exhausted — falling back to offline sync (no server involved)"
        if ! _sync_disk_preflight "$db"; then
          failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(disco)"; continue
        fi
        if ! _offline_backup_sync "$db" "$dest"; then
          failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(sync)"; continue
        fi
        log "$db: offline-sync fallback OK"
      fi
    else
      log "$db: DOLT_BACKUP sync FAILED"; failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(sync)"; continue
    fi
  fi
  # 2) off-box mirror -> S3 (incremental; prune orphans; versioning retains history)
  if ! timeout "$S3_TIMEOUT" "$AWS" s3 sync "$dest/" "$S3/$db/" --delete --only-show-errors >> "$LOG" 2>&1; then
    log "$db: aws s3 sync FAILED"; failed=$((failed+1)); FAILED_DBS="$FAILED_DBS ${db}(s3)"; continue
  fi
  # fingerprint: issue count AS OF the exact captured commit (self-consistent + present
  # in the backup), so a restorer can verify: restore, then COUNT(*) issues AS OF <head>.
  if [ -n "$head" ]; then
    cnt="$(dsql -q "USE \`$db\`; SELECT COUNT(*) FROM issues AS OF '$head'" --result-format csv 2>/dev/null | tail -1)"
  else
    cnt="$(dsql -q "SELECT COUNT(*) FROM \`$db\`.issues" --result-format csv 2>/dev/null | tail -1)"
  fi
  sz="$(du -sh "$dest" 2>/dev/null | awk '{print $1}')"
  case "${cnt:-}" in ''|*[!0-9]*) cnt="-1" ;; esac
  printf '%s\t%s\t%s\t%s\n' "$db" "$cnt" "${head:-}" "${sz:-}" >> "$RAW"
  log "$db: OK (issues=$cnt head=${head:-?} size=${sz:-?})"
  ok=$((ok+1))
  # ga-8f1uh0: best-effort space reclaim, AFTER the counters above already
  # reflect this run's real backup outcome — its own success/failure is
  # logged and (when non-disk) notified inside the helper, but never changes
  # $ok/$failed/$FAILED_DBS for the core backup that already succeeded.
  _reseed_staging_if_enabled "$db"
done

# --- JSONL archive offsite mirror (ga-7gfd34) --------------------------------
# Independent of the per-db loop above — runs unconditionally regardless of
# $failed, so a stuck/failing db backup (e.g. hq) never skips this.
JSONL_OFFSITE_STATUS="skipped"
if [ -d "$JSONL_ARCHIVE_DIR" ]; then
  jsonl_offsite_sync
  case "$?" in
    0) JSONL_OFFSITE_STATUS="ok" ;;
    2) JSONL_OFFSITE_STATUS="skipped" ;;
    *) JSONL_OFFSITE_STATUS="failed" ;;
  esac
else
  log "jsonl-offsite: SKIP — archive dir not found at $JSONL_ARCHIVE_DIR"
fi

# --- publish a run fingerprint to S3 (small; latest + dated) ---
RUN_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if "$AWS" --version >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  # ga-gjfe78: a db that failed tonight must stay in the file, marked failed and
  # with the date of its last good backup — see _build_run_fingerprint. The last
  # good values come from the PREVIOUS night's file, so fetch it, but only when
  # something failed: a clean night never reads it, and its output is
  # byte-identical to what it always was. A fetch that fails leaves an empty
  # file, which the builder reads as "could not find out" (last_ok stays null),
  # never as "there was none".
  PREV_META=""
  if [ "$failed" -gt 0 ]; then
    PREV_META="$(mktemp)"
    if ! timeout "${META_FETCH_TIMEOUT:-60}" "$AWS" s3 cp "$S3/_meta/latest.json" "$PREV_META" --only-show-errors >> "$LOG" 2>&1; then
      log "fingerprint: could not fetch the previous _meta/latest.json — failed dbs are published with last_ok=null (not known)"
      : > "$PREV_META"
    fi
  fi
  # Never publish a fingerprint that did not build: an empty/invalid file here
  # would REPLACE the last good one (a missing entry is safe for consumers, a
  # corrupt file is not). Left alone, the old file keeps its older run_utc, which
  # keeps every consumer's freshness check inert.
  if _build_run_fingerprint "$RAW" "$RUN_UTC" "$PORT" "$ok" "$failed" "$total" "$DBS" "$FAILED_DBS" "$PREV_META" > "$META" 2>> "$LOG" \
     && python3 -c 'import json,sys; sys.exit(0 if isinstance(json.load(open(sys.argv[1])), dict) else 1)' "$META" 2>> "$LOG"; then
    # ga-dgnpyj: a failed upload is logged + notify_fail'd inside; this script has
    # no `set -e`, and a failed upload must not abort the rest of the run.
    _publish_run_fingerprint
  else
    log "fingerprint: could not build a valid run fingerprint — NOT publishing (the last good _meta/latest.json stays)"
    notify_fail "backup off-box: fingerprint _meta/latest.json não foi gerado — NÃO publicado (fica o último bom); ver $LOG"
  fi
  [ -z "$PREV_META" ] || rm -f "$PREV_META"
fi

log "=== run complete: ok=$ok failed=$failed total=$total jsonl_offsite=$JSONL_OFFSITE_STATUS ==="
if [ "$failed" -gt 0 ]; then
  notify_fail "backup off-box: $failed/$total store(s) FALHARAM:${FAILED_DBS}"
fi
if [ "$JSONL_OFFSITE_STATUS" = "failed" ]; then
  notify_fail "backup off-box: cópia offsite do JSONL não subiu (ver $LOG)"
fi
exit 0

# ============================================================================
# RESTORE PROCEDURE (verified working — never touches the live store)
# ----------------------------------------------------------------------------
#   BUCKET=urblink-dolt-backups ; DB=property_scrapers ; SCRATCH=/tmp/dolt-restore
#   rm -rf "$SCRATCH"; mkdir -p "$SCRATCH/pull/$DB"
#   aws s3 sync "s3://$BUCKET/$DB/" "$SCRATCH/pull/$DB/"          # pull backup from S3
#   cd "$SCRATCH"
#   dolt backup restore "file://$SCRATCH/pull/$DB" "restored_$DB" # NO DOLT_CLI_PASSWORD (local CLI)
#   cd "restored_$DB"
#   dolt sql -q "SELECT COUNT(*) FROM issues"                     # verify vs _meta/latest.json
#   dolt sql -q "SELECT commit_hash FROM dolt_log ORDER BY date DESC LIMIT 1"
# To adopt into the live server you would `dolt sql-server`-import the restored dir on a
# SCRATCH data-dir first and reconcile — NEVER overwrite the running .beads/dolt/<db>.
# ============================================================================

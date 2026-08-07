#!/bin/bash
# log-reaper.sh (ga-dnc2m) — per-file size cap for known unrotated app logs.
#
# WHY: 2026-08-07 a real disk-floor CRITICAL (avail 7.4Gi -> 4.4Gi in ~20min)
# traced to SIX log files with no rotation at all: appium_server.log (436MB)
# under /private/tmp, plus db_sync.log/db_sync_stdout.log and three
# daemon_dashboard*/classification_dashboard_stderr.log files under
# ~/shared/logs (~4G total). dolt-disk-floor-guard.sh's three existing
# reclaim levers (gc dolt-cleanup, dead-scratchpad reap, dead-transcript
# reap) all ran and recovered ZERO, because none of them look at this file
# class at all — the guard logged "reclaim OK — avail 6GB -> 6GB", which
# reads as success over a complete non-effect (see that script's own header
# for the ga-p5q3 "error/empty must not collapse" idiom this violates when a
# guard's silence about WHY it recovered nothing is mistaken for "handled").
# `df` confirms /private/tmp, ~/shared/logs, and Dolt's own data-dir
# ($CITY/.beads/dolt) are the SAME device (/dev/disk3s5, /System/Volumes/
# Data on this host) — an APFS container shares free space across every
# volume in it, so unrotated logs anywhere in that container compete
# directly for Dolt's disk floor even though none of them are Dolt's data.
#
# Follow-up measurement (Mayor, same bead, same day): appium_server.log's
# growth rate is ~10MB/h (~247MB/day) — normal unrotated accumulation over
# ~1.8 days, NOT a leak or a pathological log level. Nothing here
# investigates *why* a log grows; this reaper only ever asks "is it over the
# cap," matching the bead's own retraction of that investigation as
# unnecessary.
#
# WHAT: for each configured log path, if its size is >= LOG_REAPER_THRESHOLD_MB
# (default 50MB — the bead filer's own suggested cap), copytruncate it: best-
# effort `cp` to `<path>.1` (one generation of history, overwritten each
# rotation — never accumulates), then truncate the ORIGINAL file in place via
# `: > path`. Truncating preserves the inode, so a daemon that already has the
# file open for append keeps writing into the SAME inode with no restart, no
# SIGHUP, and no coordination with this reaper required — this is the exact
# technique the Mayor already used by hand as a stopgap on the same six files
# (see this bead's own description); this script just makes it recurring and
# unattended instead of manual and one-off.
#
# Runs UNCONDITIONALLY every cycle it's invoked (not gated on Dolt's own
# avail/floor class) — deliberately, so "these logs have a cap" is a standing
# property (bead ACEITE #1), not something that only kicks in once Dolt is
# already under pressure. Wired into dolt-disk-floor-guard.sh as its 4th
# reclaim lever (bead ACEITE #2) purely to reuse that guard's already-running
# 5-minute launchd cycle instead of standing up a second plist for the same
# cadence; this script has no Dolt-specific logic of its own and can be
# invoked standalone.
#
# KNOWN TRADEOFF: copytruncate has a small, unavoidable window between the
# `cp` and the `: >` truncate during which anything the writer appends is
# lost from both the live file AND the `.1` backup (same risk logrotate's own
# copytruncate mode documents, and the same one the Mayor's manual `: >`
# already accepted with no `.1` backup at all). Signal-based rotation
# (SIGHUP-to-reopen) would avoid that window, but requires knowing each
# daemon's log-reopen behavior — unverified here and out of scope for this
# bead; copytruncate needs zero cooperation from the writer.
#
# SAFETY: the backup `cp` is best-effort and never blocks the truncate — under
# the exact low-disk conditions this reaper exists for, the `cp` itself could
# fail for lack of space, and recovering space always outranks keeping a
# history copy. A configured path that doesn't exist is skipped, not an
# error (a daemon may not have started yet, or may have been retired).
#
# Kill switch: LOG_REAPER_ENABLED=0 -> no-op every cycle (logs skip reason).
#
# PRODUCTION SENTINEL (same ga-h565g pattern as scratchpad-reaper.sh /
# transcript-reaper.sh): whenever the resolved path list exactly equals the
# real default list AND LOG_REAPER_PROD!=1, main() forces a dry-run
# regardless of LOG_REAPER_DRY_RUN — a test harness that forgets to override
# the path list can never truncate real logs just because it also forgot to
# request dry-run. Set LOG_REAPER_PROD=1 ONLY from the real caller
# (dolt-disk-floor-guard.sh's _reap_growing_logs) — never from a test.
#
# TEST (no real log files touched, no real truncation):
#   bash scripts/log-reaper.selftest.sh
# Library mode: `LOG_REAPER_LIB=1 source log-reaper.sh` defines the pure
# decision functions WITHOUT running the reap flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"

# The six paths measured in this bead's own incident (see header). One path
# per line — deliberately a newline-joined string, not a bash array: this
# file's siblings (scratchpad-reaper.sh, transcript-reaper.sh,
# dolt-disk-floor-guard.sh) avoid arrays entirely to stay simple under macOS
# system /bin/bash (bash 3.2, what launchd invokes per every *.plist in this
# pack), and a herestring `while read` loop over a newline list needs nothing
# array-specific.
LOG_REAPER_REAL_DEFAULT_PATHS="/private/tmp/appium_server.log
/Users/athos/shared/logs/db_sync_stdout.log
/Users/athos/shared/logs/db_sync.log
/Users/athos/shared/logs/daemon_dashboard.log
/Users/athos/shared/logs/daemon_dashboard_stderr.log
/Users/athos/shared/logs/classification_dashboard_stderr.log"

LOG_REAPER_PATHS="${LOG_REAPER_PATHS:-$LOG_REAPER_REAL_DEFAULT_PATHS}"
LOG="${LOG_REAPER_LOG:-$CITY/.gc/logs/log-reaper.log}"
ENABLED="${LOG_REAPER_ENABLED:-1}"
DRY_RUN="${LOG_REAPER_DRY_RUN:-0}"
PROD="${LOG_REAPER_PROD:-0}"
# 50MB default: the bead filer's own suggested per-file cap ("ex.: 50MB,
# mantendo 1-2 geracoes"), informed by the measured ~10MB/h appium rate.
THRESHOLD_MB="${LOG_REAPER_THRESHOLD_MB:-50}"

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by log-reaper.selftest.sh.
# No side effects; bash-3.2-safe.
# ════════════════════════════════════════════════════════════════════════════

# _should_rotate <size_bytes> <threshold_bytes> → 0 (true) iff size_bytes is
# numeric AND >= threshold_bytes (inclusive boundary — same idiom as
# dolt-disk-floor-guard.sh's _floor_class `-le`/`-ge` boundaries). Non-numeric
# size (a stat failure, e.g. a race where the file vanished between the
# existence check and the read) NEVER authorizes rotation — fail toward
# keep, same as every other unreadable-input case in this reaper family.
_should_rotate() {
  local size="$1" threshold="$2"
  case "$size" in ''|*[!0-9]*) return 1 ;; esac
  case "$threshold" in ''|*[!0-9]*) return 1 ;; esac
  [ "$size" -ge "$threshold" ]
}

# _prod_sentinel_active <resolved_paths> <real_default_paths> <prod_flag> → 0
# (true) iff resolved_paths is byte-identical to real_default_paths AND
# prod_flag is not "1". Mirrors scratchpad-reaper.sh's/transcript-reaper.sh's
# own `_prod_sentinel_active` exactly: a caller (test or otherwise) that
# forgets to override the path list must never be able to truncate real logs
# just because it ALSO forgot to opt in; both conditions are required.
_prod_sentinel_active() {
  local paths="$1" real_default="$2" prod="$3"
  [ "$paths" = "$real_default" ] && [ "$prod" != "1" ]
}

# ════════════════════════════════════════════════════════════════════════════
# EXECUTION (side-effecting; NOT exercised by the selftest's pure-function
# assertions, but exercised end-to-end via main() against fixture paths)
# ════════════════════════════════════════════════════════════════════════════

# _file_size_bytes <path> → size in bytes via `stat -f %z` (macOS/BSD stat;
# matches _avail_gb's own `df -k` portability note in dolt-disk-floor-guard.sh
# — this host's stat has no GNU-style `--format`). Empty on any failure
# (missing file, permission error) — caller treats empty as "skip", not
# "zero bytes", via _should_rotate's non-numeric guard.
_file_size_bytes() {
  stat -f %z "$1" 2>/dev/null
}

main() {
  if _prod_sentinel_active "$LOG_REAPER_PATHS" "$LOG_REAPER_REAL_DEFAULT_PATHS" "$PROD"; then
    log "SENTINEL: resolved path list equals the real default and no production opt-in is set (LOG_REAPER_PROD=1) — forcing dry-run this cycle (ga-h565g production sentinel)"
    DRY_RUN=1
  fi

  if [ "$ENABLED" != "1" ]; then
    log "log-reap SKIP — LOG_REAPER_ENABLED=0 (no-op this cycle)"
    return 0
  fi

  local threshold_bytes=$(( THRESHOLD_MB * 1024 * 1024 ))
  local checked=0 rotated=0 skipped=0 missing=0 freed_bytes=0
  local path size

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    checked=$((checked + 1))

    if [ ! -f "$path" ]; then
      missing=$((missing + 1))
      log "log-reap: $path does not exist — skip (daemon not started yet, or retired)"
      continue
    fi

    size="$(_file_size_bytes "$path")"
    if ! _should_rotate "$size" "$threshold_bytes"; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$DRY_RUN" = "1" ]; then
      log "DRY-RUN would rotate: $path (${size} bytes >= threshold ${threshold_bytes} bytes)"
      rotated=$((rotated + 1))
      freed_bytes=$((freed_bytes + size))
      continue
    fi

    # Best-effort backup — see header KNOWN TRADEOFF / SAFETY. A failed copy
    # must never block the truncate: recovering space is the point of this
    # reaper, and it runs precisely when disk is tightest.
    if ! cp "$path" "$path.1" 2>>"$LOG"; then
      log "WARN: backup copy to $path.1 failed (continuing to truncate $path anyway — freeing space outranks keeping history)"
    fi

    if : > "$path" 2>>"$LOG"; then
      rotated=$((rotated + 1))
      freed_bytes=$((freed_bytes + size))
      log "rotated: $path (${size} bytes freed, inode preserved, backup: $path.1)"
    else
      log "FAILED to truncate: $path"
    fi
  done <<< "$LOG_REAPER_PATHS"

  log "cycle complete: checked=$checked rotated=$rotated skipped=$skipped missing=$missing freed_bytes=$freed_bytes threshold_mb=$THRESHOLD_MB enabled=$ENABLED dry_run=$DRY_RUN"
}

# ── run unless sourced as a library (selftest sources with LOG_REAPER_LIB=1) ──
if [ "${LOG_REAPER_LIB:-0}" != "1" ]; then
  main
  exit 0
fi

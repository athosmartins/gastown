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
# SECOND CLASS — TAIL-CAP (ga-52drsg): the city's own daemon logs. 2026-10-12
# the Mayor found the disk at 348MB free (swap 8GB) with SEVEN of the city's
# own logs past 100MB, ~920MB together: .gc/runtime/control-dispatcher-trace.log
# 205MB, ~/.gc/supervisor.log 141MB, scratchpad-reaper.log 124MB,
# gate-merge-survival-sweep.log + -launchd.out 2x122MB, lifecycle-coherence-
# janitor.log 107MB, production-drift-guard-launchd.err 99MB. None was in the
# list above (which only covers the app logs of ga-dnc2m), so this reaper
# logged "checked=6 rotated=0" every cycle while they grew — the same shape
# as ga-dnc2m, one file class over. These get a different treatment from the
# first class because they are the logs somebody reads to debug the city:
# instead of a full copy to `.1` and an empty file, the LAST keep-MB stay in
# the live file and nothing else is kept (no `.1`: the disk was the reason we
# are here, and a second generation per file would put ~140MB back).
#   trigger: size >= LOG_REAPER_CAP_MB (default 20)  — inclusive, same idiom.
#   result : the last LOG_REAPER_KEEP_MB (default 10) bytes, in place.
# The writers all open these files O_APPEND (launchd StandardOut/ErrorPath,
# `>>` in the scripts, the engine's trace) — checked by the Mayor's own manual
# truncate (14:46-14:49 the same day): all seven were still tiny 40 minutes later,
# not a sparse file at its old offset. A writer that does NOT open with
# O_APPEND would keep writing at its old offset after the truncate and turn
# the file sparse (st_size back over the cap), so do not add a path here
# before checking how its writer opens it.
# Paths: LOG_REAPER_CAP_PATHS (empty value = none, which is how a test turns
# the class off; unset = the real list below, except in library mode — a
# sourced selftest never targets production paths it did not name).
#
# SIZE KNOBS (LOG_REAPER_CAP_MB, LOG_REAPER_KEEP_MB and the first class's
# LOG_REAPER_THRESHOLD_MB) are read as plain decimal megabytes: "08" is 8 and
# "010" is 10 (inside bash arithmetic they would be an octal error and an 8).
# A value that is not a positive integer of at most 7 digits (so that
# mb*1MiB cannot wrap bash's 64-bit arithmetic) is replaced by the default, and
# the cycle logs a WARN line saying which knob was replaced. If the cap/keep pair
# is STILL not usable the capped class touches no file that cycle: it logs why
# and counts every configured path as failed (ga-52drsg gate-fix 1).
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

# ga-52drsg tail-cap class (see header). Same newline-joined-string idiom.
LOG_REAPER_CAP_REAL_DEFAULT_PATHS="$CITY/.gc/runtime/control-dispatcher-trace.log
/Users/athos/.gc/supervisor.log
$CITY/.gc/logs/scratchpad-reaper.log
$CITY/.gc/logs/gate-merge-survival-sweep.log
$CITY/.gc/logs/gate-merge-survival-sweep-launchd.out
$CITY/.gc/logs/lifecycle-coherence-janitor.log
$CITY/.gc/logs/production-drift-guard-launchd.err"

LOG_REAPER_PATHS="${LOG_REAPER_PATHS:-$LOG_REAPER_REAL_DEFAULT_PATHS}"
# No colon in `-`: an explicitly empty value means "no capped paths".
if [ "${LOG_REAPER_LIB:-0}" = "1" ]; then
  LOG_REAPER_CAP_PATHS="${LOG_REAPER_CAP_PATHS-}"
else
  LOG_REAPER_CAP_PATHS="${LOG_REAPER_CAP_PATHS-$LOG_REAPER_CAP_REAL_DEFAULT_PATHS}"
fi
CAP_MB="${LOG_REAPER_CAP_MB:-20}"
KEEP_MB="${LOG_REAPER_KEEP_MB:-10}"
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

# _mb_valid <mb> → 0 (true) iff mb is a positive decimal integer of at most 7
# digits once leading zeros are dropped (9,999,999 MB ~ 10 TB: far past any log,
# and small enough that mb*1024*1024 cannot wrap bash's 64-bit arithmetic into a
# plausible-looking or negative size). Purely textual on purpose: nothing here
# goes through $(( )), where "08" is an octal error.
_mb_valid() {
  local mb="$1"
  case "$mb" in ''|*[!0-9]*) return 1 ;; esac
  mb="${mb#"${mb%%[!0]*}"}"          # drop leading zeros: "08" -> "8", "000" -> ""
  [ -n "$mb" ] && [ "${#mb}" -le 7 ]
}

# _mb_to_bytes <mb> <default_mb> → bytes. A value _mb_valid refuses falls back
# to the default: a typo in an env override must not turn into a cap of 0 bytes
# (which would empty every capped log every cycle). The caller says so in the log
# (_mb_valid first); this function only converts. 10# makes the read decimal
# whatever the leading zeros.
_mb_to_bytes() {
  local mb="$1" def="$2"
  _mb_valid "$mb" || mb="$def"
  echo $(( 10#$mb * 1024 * 1024 ))
}

# _cap_limits_usable <cap_bytes> <keep_bytes> → 0 (true) iff both are plain
# positive byte counts and keep is STRICTLY below the cap. The gate in front of
# the whole capped-file loop: a pair that fails it is "cannot tell what the
# limits are", which is neither "under the cap" nor "disk full" — nothing is cut.
_cap_limits_usable() {
  local cap="$1" keep="$2"
  case "$cap" in ''|*[!0-9]*) return 1 ;; esac
  case "$keep" in ''|*[!0-9]*) return 1 ;; esac
  [ "$cap" -gt 0 ] && [ "$keep" -gt 0 ] && [ "$keep" -lt "$cap" ]
}

# _cap_keep_bytes <keep_mb> <cap_bytes> → how many trailing bytes survive a
# tail-cap. Must be positive and STRICTLY below the cap, otherwise the file
# would be over the cap again right after being "capped" and get rewritten
# every cycle. An unusable keep_mb takes the 10 MB default; a keep that is then
# not below the cap is cut down to half the cap.
_cap_keep_bytes() {
  local keep_mb="$1" cap_bytes="$2" keep
  keep="$(_mb_to_bytes "$keep_mb" 10)"
  if [ "$keep" -ge "$cap_bytes" ]; then keep=$(( cap_bytes / 2 )); fi
  echo "$keep"
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

# _tail_cap_one <path> <keep_bytes> → how the file ended up (the caller logs
# what ACTUALLY happened, never "tail kept" for a file that lost its tail):
#   0 = back under the cap with its last keep_bytes still in it
#   2 = emptied: the tail could not be copied aside (most likely no space) so it was cut fully
#   3 = emptied, and the tail could not be written back (it is in <path>.tailcap.tmp)
#   1 = nothing freed: the file could not be truncated (or has vanished)
#   4 = refused: keep_bytes is not a positive byte count, so nobody knows what to
#       keep; neither the file nor the side file was touched
# Keeps the last keep_bytes IN the live file: copy the tail aside, truncate in
# place (`: >` keeps the inode, so a writer holding the file open O_APPEND just
# keeps going), append the tail back. Lines the writer appends between the
# truncate and the append-back land ABOVE the kept tail (out of order by a few
# milliseconds of log) and lines written between reading the tail and the
# truncate are lost — the same copytruncate window the header documents, no
# worse. The side file has a FIXED name so a run killed by the caller's
# `timeout` leaves at most one leftover (<= keep bytes, and it holds the tail
# that did not make it back), overwritten by the next run.
_tail_cap_one() {
  local path="$1" keep="$2" tmp="$1.tailcap.tmp"
  # keep is what stays in the file. A value that is not a positive byte count
  # (empty, text, 0, a leading zero -- the caller computes it, so it never has
  # one) means "do not know what to keep", NOT "keep nothing": `tail -c ""` fails
  # exactly like a full disk, lands in the no-room branch below, and would empty
  # the whole file under a cause nobody observed. Refused before anything is touched.
  case "$keep" in ''|*[!0-9]*|0*) return 4 ;; esac
  # `: >` CREATES a missing file; a path that vanished since the stat must not
  # come back as an empty file this reaper made.
  [ -f "$path" ] || return 1
  if tail -c "$keep" "$path" > "$tmp" 2>>"$LOG" && [ -s "$tmp" ]; then
    if ! : > "$path" 2>>"$LOG"; then
      rm -f "$tmp"
      return 1
    fi
    if ! cat "$tmp" >> "$path" 2>>"$LOG"; then
      return 3
    fi
    rm -f "$tmp"
    return 0
  fi
  # The tail could not be copied aside. The case this is FOR is a full disk (the
  # low-disk case the reaper exists for), where recovering space outranks keeping
  # history (same rule as the cp backup in the first class). The code does NOT
  # check the cause: with a valid keep, any failure of the copy (an unwritable
  # side-file path too) reaches this cut, which is why the caller's log line says
  # "no room?" and not "no room".
  rm -f "$tmp"
  if : > "$path" 2>>"$LOG"; then
    return 2
  fi
  return 1
}

# Second class (ga-52drsg, see header): cap each path in LOG_REAPER_CAP_PATHS at
# CAP_MB, keeping the last KEEP_MB. Runs after the first class, shares ENABLED /
# DRY_RUN, and has its own production sentinel (a test that overrides only the
# first list must still never reach the real city logs).
_cap_pass() {
  local cap_dry="$DRY_RUN"
  if _prod_sentinel_active "$LOG_REAPER_CAP_PATHS" "$LOG_REAPER_CAP_REAL_DEFAULT_PATHS" "$PROD"; then
    log "SENTINEL: capped-log list equals the real default and no production opt-in is set (LOG_REAPER_PROD=1) — forcing dry-run for the tail-cap class (ga-h565g production sentinel)"
    cap_dry=1
  fi

  # A knob that cannot be read as a size runs with the default (documented in the
  # header) -- and the log says so, because the summary below echoes the RAW knob
  # and would otherwise hide which limit really ran.
  _mb_valid "$CAP_MB"  || log "WARN log-cap: LOG_REAPER_CAP_MB='$CAP_MB' is not a usable size — using the default 20 MB"
  _mb_valid "$KEEP_MB" || log "WARN log-cap: LOG_REAPER_KEEP_MB='$KEEP_MB' is not a usable size — using the default 10 MB"

  local cap_bytes keep_bytes limits_ok=1
  cap_bytes="$(_mb_to_bytes "$CAP_MB" 20)"
  keep_bytes="$(_cap_keep_bytes "$KEEP_MB" "$cap_bytes")"
  # Gate in front of the loop below. A pair that is not two positive byte
  # counts with keep < cap is "cannot tell what the limits are" -- not "under the
  # cap" (nothing to do) and not "disk full" (cut everything): the cycle is inert.
  if ! _cap_limits_usable "$cap_bytes" "$keep_bytes"; then
    limits_ok=0
    log "FAILED log-cap: the limits are not usable (cap_bytes='$cap_bytes' keep_bytes='$keep_bytes', from LOG_REAPER_CAP_MB='$CAP_MB' LOG_REAPER_KEEP_MB='$KEEP_MB') — NO capped log is touched this cycle"
  fi
  local checked=0 capped=0 skipped=0 missing=0 unreadable=0 failed=0 freed_bytes=0
  local path size rc

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    checked=$((checked + 1))

    # Unusable limits: the file is not even looked at. Counted as failed (the
    # reason is the FAILED line above), never as skipped, so the summary cannot
    # read like a healthy cycle.
    if [ "$limits_ok" != "1" ]; then
      failed=$((failed + 1))
      continue
    fi

    if [ ! -f "$path" ]; then
      missing=$((missing + 1))
      log "log-cap: $path does not exist — skip"
      continue
    fi

    size="$(_file_size_bytes "$path")"
    case "$size" in
      ''|*[!0-9]*)
        # Could not tell the size: not "under the cap" and not "over" — counted
        # and logged on its own, and the file is left alone.
        unreadable=$((unreadable + 1))
        log "log-cap: cannot read the size of $path — NOT capped this cycle"
        continue
        ;;
    esac
    if ! _should_rotate "$size" "$cap_bytes"; then
      skipped=$((skipped + 1))
      continue
    fi

    if [ "$cap_dry" = "1" ]; then
      log "DRY-RUN would cap: $path (${size} bytes >= cap ${cap_bytes} bytes, would keep the last ${keep_bytes})"
      capped=$((capped + 1))
      freed_bytes=$((freed_bytes + size - keep_bytes))
      continue
    fi

    _tail_cap_one "$path" "$keep_bytes"
    rc=$?
    case "$rc" in
      0)
        capped=$((capped + 1))
        freed_bytes=$((freed_bytes + size - keep_bytes))
        log "capped: $path (${size} bytes -> last ${keep_bytes} kept, inode preserved)"
        ;;
      2)
        capped=$((capped + 1))
        freed_bytes=$((freed_bytes + size))
        log "capped: $path (${size} bytes -> EMPTY: the tail could not be copied aside (no room?), so it was cut fully)"
        ;;
      3)
        capped=$((capped + 1))
        freed_bytes=$((freed_bytes + size))
        log "capped: $path (${size} bytes -> EMPTY: the kept tail could not be written back, it is in $path.tailcap.tmp)"
        ;;
      4)
        failed=$((failed + 1))
        log "FAILED to cap: $path (keep_bytes='$keep_bytes' is not a usable byte count — file NOT touched)"
        ;;
      *)
        failed=$((failed + 1))
        log "FAILED to cap: $path (nothing freed)"
        ;;
    esac
  done <<< "$LOG_REAPER_CAP_PATHS"

  log "cap cycle complete: checked=$checked capped=$capped skipped=$skipped missing=$missing unreadable=$unreadable failed=$failed freed_bytes=$freed_bytes cap_mb=$CAP_MB keep_mb=$KEEP_MB dry_run=$cap_dry"
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

  # Same reader as the capped class: "08" is 8, and a knob that cannot be read as
  # a size runs with the default (50) and says so. It was a raw $(( )), where "08"
  # aborted this whole run before it logged anything or reached the capped class.
  _mb_valid "$THRESHOLD_MB" || log "WARN log-reap: LOG_REAPER_THRESHOLD_MB='$THRESHOLD_MB' is not a usable size — using the default 50 MB"
  local threshold_bytes
  threshold_bytes="$(_mb_to_bytes "$THRESHOLD_MB" 50)"
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

  _cap_pass
}

# ── run unless sourced as a library (selftest sources with LOG_REAPER_LIB=1) ──
if [ "${LOG_REAPER_LIB:-0}" != "1" ]; then
  main
  exit 0
fi

#!/bin/bash
# disk-ballast-guard.sh (ga-pzgr) — last-resort disk-ballast guard, SO PODE AJUDAR.
#
# WHY: 2026-07-14 the HQ Dolt server died mid-journal-write when the disk filled
# to 100% (ga-vs55) — this time from a sandbox script (wa-9lwde) copying 19GB,
# NOT from Dolt itself. ga-gpzr's floor guard only reclaims Dolt's OWN orphan
# DBs — it can't help when the culprit is something else. And ga-jj47 already
# decided AGAINST giving any guard the authority to stop Dolt (self-stop kills
# the mail/escalation channel that runs on top of Dolt, and a clean shutdown is
# MORE silent than a panic — a regression by the ga-p5q3 root class).
#
# WHAT: a pre-allocated ~2GB ballast file that does nothing but occupy real,
# non-sparse disk blocks. When real avail free space drops at/below the floor,
# delete it — 2GB return INSTANTLY, buying ~20-30 min before actual ENOSPC. Only
# recreate once avail recovers to a healthy level (hysteresis — don't flap
# during the crisis). GRITA via `notify` (ntfy, Dolt-independent) with NO
# cooldown at this tier — this is the final alarm. NEVER calls `gc`, `bd`, or
# anything that touches Dolt — must work even with Dolt fully dead. NEVER stops
# anything — the only actions are: create a file, delete a file, send a push.
#
# TEST (hermetic; no real disk mutation outside a throwaway scratch dir, no real
# push sent):
#   bash scripts/disk-ballast-guard.selftest.sh
# Library mode: `DISK_BALLAST_GUARD_LIB=1 source disk-ballast-guard.sh` defines
# the pure decision functions WITHOUT running the guard flow.
set -uo pipefail

CITY="/Users/athos/gt/.gascity-gastown-hq"
LOG="${DISK_BALLAST_GUARD_LOG:-$CITY/.gc/logs/disk-ballast-guard.log}"
NOTIFY_BIN_DEFAULT="/Users/athos/.local/bin/notify"
# _notify_bin() resolves fresh at CALL time (not sourced-in once as a plain
# variable) so a test can override DISK_BALLAST_GUARD_NOTIFY_BIN AFTER sourcing
# this file as a library and still have it take effect.
_notify_bin() { printf '%s' "${DISK_BALLAST_GUARD_NOTIFY_BIN:-$NOTIFY_BIN_DEFAULT}"; }

ts()  { date '+%Y-%m-%d %H:%M:%S'; }
log() { echo "[$(ts)] $*" >> "$LOG" 2>/dev/null || true; }

# ════════════════════════════════════════════════════════════════════════════════
# PURE DECISION FUNCTIONS — unit-tested by disk-ballast-guard.selftest.sh.
# No side effects; config is passed as explicit params so the selftest can
# exercise arbitrary values without touching globals.
# ════════════════════════════════════════════════════════════════════════════════

# _avail_kb [path] → integer KB available on the filesystem hosting [path]
# (default $CITY), or "" if df fails/parses oddly (e.g. nonexistent path). KB
# (not GB) granularity so tests can use small scratch files and still detect a
# real delta. Uses `df -k` (portable — macOS/BSD df has no -g).
_avail_kb() {
  local path="${1:-$CITY}" kb
  kb="$(df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$kb" in ''|*[!0-9]*) echo ""; return ;; esac
  echo "$kb"
}

# _ballast_class <avail_kb> <floor_kb> <healthy_kb> → CRITICAL|MID|HEALTHY|UNKNOWN.
# UNKNOWN (empty/non-numeric avail_kb, e.g. df failed) is NEVER silently treated
# as MID/HEALTHY — a failed read must fail LOUD (ga-p5q3: error and empty must
# not produce the same value when the emptiness is load-bearing).
_ballast_class() {
  local avail="$1" floor="$2" healthy="$3"
  case "$avail" in ''|*[!0-9]*) echo "UNKNOWN"; return ;; esac
  if [ "$avail" -le "$floor" ]; then echo "CRITICAL"; return; fi
  if [ "$avail" -ge "$healthy" ]; then echo "HEALTHY"; return; fi
  echo "MID"
}

# ════════════════════════════════════════════════════════════════════════════════
# EXECUTION FUNCTIONS (side-effecting; tested against REAL scratch files by the
# selftest — small size, same code path as production, real `df`/`du` deltas).
# ════════════════════════════════════════════════════════════════════════════════

# _create_ballast <path> <size_mb> → write <size_mb> of real zero bytes to
# <path>. Deliberately a plain sequential `dd` write (no seek/truncate) so the
# result is NON-SPARSE on APFS — a sparse file would occupy no real blocks and
# provide zero ballast, defeating the entire guard.
_create_ballast() {
  local path="$1" size_mb="$2"
  dd if=/dev/zero of="$path" bs=1m count="$size_mb" 2>/dev/null
}

# _burn_ballast_if_present <path> → delete <path> if it exists (returns 0 — did
# burn) or leave it if already absent (returns 1 — nothing to burn, already
# burned in a prior cycle). Deletion is a plain `rm -f`: no gc/bd/Dolt call
# anywhere in this function, by design — this must work with Dolt fully dead.
_burn_ballast_if_present() {
  local path="$1"
  [ -e "$path" ] || return 1
  rm -f "$path"
}

# _recreate_ballast_if_absent <path> <size_mb> → create <path> only if it
# doesn't already exist (returns 0 — created) or leave an existing ballast
# alone (returns 1 — no-op). Never clobbers a live ballast — avoids needless
# re-allocation churn while avail is still hovering near the floor.
_recreate_ballast_if_absent() {
  local path="$1" size_mb="$2"
  [ -e "$path" ] && return 1
  _create_ballast "$path" "$size_mb"
}

# _notify_critical <avail_kb> [offenders_text] → GRITO. Dolt-independent
# (`notify`/ntfy only — NEVER `gc mail`/`bd`, NEVER gated by any Dolt/gc health
# check) and unconditional — caller must invoke this EVERY cycle the class is
# CRITICAL, with no cooldown; this is the final alarm before real ENOSPC.
# NOT a heredoc (bash 3.2, what launchd invokes, mis-parses a heredoc nested in
# a $(...) substitution when the body has an apostrophe — same bug ga-gpzr's
# script documents and works around the same way).
_notify_critical() {
  local avail_kb="$1" offenders="${2:-}"
  local avail_gb=$(( avail_kb / 1024 / 1024 ))
  local msg="LASTRO QUEIMADO — ~20min antes do Dolt morrer por ENOSPC. Ache o que esta comendo o disco AGORA. avail=${avail_gb}GB. Ver ga-pzgr."
  if [ -n "$offenders" ]; then
    msg="$msg
Top ofensores (ultima hora):
$offenders"
  fi
  "$(_notify_bin)" -k disk-warn -p 5 "$msg" 2>/dev/null
}

# _top_offenders <roots (space-separated)> <n> <timeout_secs> → up to <n> lines
# "X.XMB  path", largest first, among FILES modified in the last hour under
# <roots>. Best-effort and bounded: any failure or timeout yields "" (never
# propagates an error — this must never be why the core alarm doesn't fire).
#
# Safety-critical scoping: PRUNES any "CloudStorage"/".Trash" directory
# encountered. Google Drive/iCloud paths under ~/Library/CloudStorage are
# FUSE/network mounts that can hang in uninterruptible sleep indefinitely (this
# town's operational doctrine — a subagent `ls` against one once hung a crew
# session for 15 minutes); a `timeout` wrapper alone is not trustworthy against
# that class of hang. Callers MUST pass roots that exclude $HOME broadly (walking
# ~/Desktop, ~/Documents, ~/Downloads also risks macOS TCC permission prompts,
# which block forever on a headless agent) — production passes the gt tree and
# /tmp, never $HOME itself. `-x` keeps find from crossing filesystem boundaries
# as further defense-in-depth.
_top_offenders() {
  local roots="$1" n="${2:-5}" timeout_secs="${3:-10}" out
  # shellcheck disable=SC2086
  out="$(timeout "$timeout_secs" find -x $roots \
      \( -iname "CloudStorage" -o -iname ".Trash" \) -prune -o \
      -type f -mmin -60 -print0 2>/dev/null \
    | xargs -0 du -sk 2>/dev/null \
    | sort -rn 2>/dev/null \
    | head -n "$n" 2>/dev/null \
    | awk '{printf "%.1fMB  %s\n", $1/1024, substr($0, index($0,$2))}' 2>/dev/null)"
  printf '%s' "$out"
}

# ════════════════════════════════════════════════════════════════════════════════
# ORCHESTRATION — reads all config fresh from env vars on every call (never
# frozen as top-level globals) so tests can override per-scenario without
# re-sourcing. Kill switch (DISK_BALLAST_GUARD_ENABLED) gates the two MUTATING
# actions (burn, recreate) only — notify is NEVER gated by it (imp07 CALL
# INVARIANT: alerting is the lowest-blast-radius action and must never be the
# one a misconfigured kill switch silences; same convention as ga-gpzr).
# ════════════════════════════════════════════════════════════════════════════════
main() {
  local ballast_path="${DISK_BALLAST_GUARD_BALLAST_PATH:-$CITY/.gc/disk-ballast.bin}"
  local check_path="${DISK_BALLAST_GUARD_CHECK_PATH:-/Users/athos}"
  local size_mb="${DISK_BALLAST_GUARD_SIZE_MB:-2048}"
  local floor_gb="${DISK_BALLAST_GUARD_FLOOR_GB:-2}"
  local healthy_gb="${DISK_BALLAST_GUARD_HEALTHY_GB:-15}"
  local scan_roots="${DISK_BALLAST_GUARD_SCAN_ROOTS:-/Users/athos/gt /tmp /var/tmp}"
  local enabled="${DISK_BALLAST_GUARD_ENABLED:-1}"
  local floor_kb=$(( floor_gb * 1024 * 1024 ))
  local healthy_kb=$(( healthy_gb * 1024 * 1024 ))

  local avail class
  avail="$(_avail_kb "$check_path")"
  class="$(_ballast_class "$avail" "$floor_kb" "$healthy_kb")"

  case "$class" in
    UNKNOWN)
      log "WARN: could not read avail space for $check_path (df failed/unparseable) — cannot verify disk floor this cycle"
      "$(_notify_bin)" -k disk-warn -p 3 "disk-ballast guard couldn't read df for $check_path — check manually" 2>/dev/null || true
      ;;
    CRITICAL)
      if [ "$enabled" = "1" ]; then
        if _burn_ballast_if_present "$ballast_path"; then
          log "CRITICAL: avail=${avail}KB <= floor(${floor_kb}KB) — LASTRO QUEIMADO ($ballast_path deleted)"
        else
          log "CRITICAL: avail=${avail}KB <= floor(${floor_kb}KB) — already burned, still critical"
        fi
      else
        log "CRITICAL: avail=${avail}KB <= floor(${floor_kb}KB) — burn SKIPPED (DISK_BALLAST_GUARD_ENABLED=0, notify-only mode)"
      fi
      local offenders
      offenders="$(_top_offenders "$scan_roots" 5 10)"
      _notify_critical "$avail" "$offenders"
      ;;
    HEALTHY)
      if [ "$enabled" = "1" ] && _recreate_ballast_if_absent "$ballast_path" "$size_mb"; then
        log "HEALTHY: avail=${avail}KB >= healthy(${healthy_kb}KB) — LASTRO RECRIADO ($ballast_path)"
      fi
      ;;
    MID)
      log "avail=${avail}KB between floor(${floor_kb}KB) and healthy(${healthy_kb}KB) — no action (hysteresis band)"
      ;;
  esac
}

# ── run unless sourced as a library (selftest sources with DISK_BALLAST_GUARD_LIB=1) ──
if [ "${DISK_BALLAST_GUARD_LIB:-0}" != "1" ]; then
  main
  exit 0
fi

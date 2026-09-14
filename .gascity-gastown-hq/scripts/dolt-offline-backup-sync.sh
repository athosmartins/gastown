#!/bin/bash
# dolt-offline-backup-sync.sh (ga-o3nqy2) — server-free Dolt backup sync via
# APFS clonefile. LIBRARY FILE: source it, never execute it directly.
#
# WHY: `CALL DOLT_BACKUP('sync', ...)` runs INSIDE the managed Dolt server and
# is bound by listener.read_timeout_millis (30s — deliberately short, reaps
# abandoned per-call connections; see dolt-config.yaml's own comment,
# ga-gdsq5). A big store (hq, 6GB+ live) syncing under load can outlive that
# window and the connection gets cut mid-sync. That is not a fluke to retry
# away — hq has failed every night since 2026-09-11 despite escalating
# retries, because the bottleneck is the SERVER CONNECTION, not the data.
#
# This sidesteps the server entirely: clone the database directory with
# `cp -c` (APFS clonefile — instant, ~0 extra disk; the clone is a
# copy-on-write snapshot, so it stays frozen even while the live directory
# keeps being written), then run `dolt backup sync-url` against the CLONE
# with a bare --data-dir (no --host/--port). No network connection is opened,
# so there is nothing for the 30s timeout to cut.
#
# Shared by dolt-s3-backup.sh (per-db connection-timeout fallback) and
# dolt-backup-reseed.sh (its "new backup" step) — source this file from both.
#
# SAFETY (every guard below fails CLOSED — "can't verify" always means
# refuse, never proceed):
#   - read-only against the live store: `cp -c` only ever READS
#     $data_dir/<db>; nothing is written there, ever.
#   - refuses up front unless the tmp root is verifiably on the SAME volume
#     as data_dir: `man cp` on -c is explicit that when source and target are
#     on different filesystems, cp does NOT error — it silently falls back to
#     a full copyfile(2) copy "to ensure the copy still succeeds". For hq
#     (6.8GB+ live) that would silently trade the "instant, ~0 extra disk"
#     premise this whole mechanism depends on for a slow copy that eats real
#     disk — worse than a loud failure, because nothing would say so.
#   - refuses if the clone carries a `.dolt/sql-server.info` marker: `dolt
#     sql --help` documents that a data-dir claimed by a live server gets its
#     queries silently routed THROUGH that server instead of running
#     embedded — exactly the network path this function exists to avoid.
#   - confirms the CLI actually ran embedded by checking the clone's `SELECT
#     @@port` differs from the live server's port (proven live 2026-09-14:
#     embedded default is 3306, this city's live port is 52756 — never
#     hardcode either side, both are derived fresh each call).
#   - the clone is removed on every exit path (success, failure, refusal).
#   - both the clone and the sync-url step are timeout-bounded (the two
#     server-mediated calls this replaces were: SYNC_TIMEOUT in
#     dolt-s3-backup.sh, `timeout 1800` in dolt-backup-reseed.sh) — a bare
#     "we sidestepped the 30s server timeout" is not the same claim as "this
#     can never hang"; nothing about local I/O is exempt from hanging.
set -uo pipefail

# _offline_sync_log <line> — internal diagnostics. Writes to $OFFLINE_SYNC_LOG
# if the caller set it (append into the CALLER's own log file — deliberately
# NOT a log()/LOG pair of our own, so sourcing this file can never clobber a
# caller's existing log() function or LOG path), else stderr.
_offline_sync_log() {
  if [ -n "${OFFLINE_SYNC_LOG:-}" ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$OFFLINE_SYNC_LOG" 2>/dev/null || true
  else
    echo "$*" >&2
  fi
}

# _offline_sync_data_dir — the Dolt server's data_dir, read fresh from its own
# managed config each call. That config is regenerated on every `gc dolt
# start` (see its own header comment), so this is the live value, not a
# stale doc — matching this city's "never hardcode a path, derive it" rule.
_offline_sync_data_dir() {
  local cfg="${OFFLINE_SYNC_DOLT_CFG:?OFFLINE_SYNC_DOLT_CFG not set}"
  awk -F'"' '/^data_dir:/{print $2; exit}' "$cfg" 2>/dev/null
}

# _offline_sync_live_port — the Dolt server's listener port, read fresh from
# its own managed config each call, with an lsof fallback (mirrors the
# pre-existing port-derivation in dolt-s3-backup.sh): the config's own header
# comment says GC_DOLT_PORT can override the port at server start, which
# could leave the on-disk config stale relative to what is actually running.
_offline_sync_live_port() {
  local cfg="${OFFLINE_SYNC_DOLT_CFG:?OFFLINE_SYNC_DOLT_CFG not set}"
  local p
  p="$(awk '/^listener:/{f=1} f&&/port:/{print $2; exit}' "$cfg" 2>/dev/null)"
  case "${p:-}" in ''|*[!0-9]*) p="" ;; esac
  if [ -z "$p" ]; then
    p="$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '/dolt/{n=split($9,a,":"); print a[n]; exit}')"
  fi
  case "${p:-}" in ''|*[!0-9]*) p="" ;; esac
  printf '%s' "$p"
}

# _offline_sync_same_volume <path_a> <path_b> — true (0) iff both paths are
# on the same filesystem/volume (compared by macOS's stat(1) device id).
# "Can't tell" (stat failed on either side — path missing, etc.) is NOT the
# same volume: refuse, never assume.
_offline_sync_same_volume() {
  local dev_a dev_b
  dev_a="$(stat -f '%d' "$1" 2>/dev/null)"
  dev_b="$(stat -f '%d' "$2" 2>/dev/null)"
  [ -n "$dev_a" ] && [ -n "$dev_b" ] && [ "$dev_a" = "$dev_b" ]
}

# _offline_backup_sync <db> <dest_dir> — see file header for the full
# mechanism and safety guards. Returns 0 on a verified server-free sync to
# <dest_dir>, 1 on any failure or refusal (each logged via
# _offline_sync_log before returning).
#
# Required: OFFLINE_SYNC_DOLT_CFG (path to the live dolt-config.yaml).
# Optional: OFFLINE_SYNC_DOLT_BIN (default: dolt on PATH),
#           OFFLINE_SYNC_TMP_ROOT (default: /tmp — MUST be on the same
#           volume as data_dir; verified before ever touching cp, see
#           _offline_sync_same_volume above and the file header),
#           OFFLINE_SYNC_TIMEOUT (default: 1800 — bounds the sync-url data
#           transfer; the clone step has its own fixed, short bound since a
#           same-volume clonefile is expected to be near-instant),
#           OFFLINE_SYNC_LOG (default: stderr).
_offline_backup_sync() {
  local db="$1" dest="$2"
  local dolt_bin="${OFFLINE_SYNC_DOLT_BIN:-dolt}"
  local tmp_root="${OFFLINE_SYNC_TMP_ROOT:-/tmp}"
  local sync_timeout="${OFFLINE_SYNC_TIMEOUT:-1800}"
  local clone_timeout=120

  local data_dir; data_dir="$(_offline_sync_data_dir)"
  if [ -z "$data_dir" ]; then
    _offline_sync_log "$db: offline-sync: could not determine data_dir from \$OFFLINE_SYNC_DOLT_CFG — refusing"
    return 1
  fi
  local src="$data_dir/$db"

  if ! _offline_sync_same_volume "$data_dir" "$tmp_root"; then
    _offline_sync_log "$db: offline-sync: REFUSING — tmp root ($tmp_root) is not verifiably on the same volume as data_dir ($data_dir); cp -c would silently fall back to a slow full copy instead of an instant clone (see file header)"
    return 1
  fi

  local clone_parent
  clone_parent="$(mktemp -d "$tmp_root/offline-sync-$db.XXXXXX" 2>/dev/null)" \
    || { _offline_sync_log "$db: offline-sync: mktemp failed under $tmp_root"; return 1; }
  local clone="$clone_parent/$db"

  local cp_err
  cp_err="$(timeout "$clone_timeout" cp -c -R "$src" "$clone_parent" 2>&1)"
  if [ ! -d "$clone" ]; then
    _offline_sync_log "$db: offline-sync: clonefile FAILED ($src -> $clone) — refusing to fall back to a slow full copy: $cp_err"
    rm -rf "${clone_parent:?}" 2>/dev/null
    return 1
  fi

  if [ -e "$clone/.dolt/sql-server.info" ]; then
    _offline_sync_log "$db: offline-sync: REFUSING — cloned sql-server.info present; the CLI would route through a live server instead of running embedded"
    rm -rf "${clone_parent:?}" 2>/dev/null
    return 1
  fi

  local live_port embedded_port
  live_port="$(_offline_sync_live_port)"
  if [ -z "$live_port" ]; then
    _offline_sync_log "$db: offline-sync: could not determine the live Dolt port — refusing (can't prove the clone is isolated from it)"
    rm -rf "${clone_parent:?}" 2>/dev/null
    return 1
  fi
  embedded_port="$("$dolt_bin" --data-dir "$clone" sql -q "SELECT @@port" --result-format csv 2>>"${OFFLINE_SYNC_LOG:-/dev/stderr}" | tail -1)"
  case "${embedded_port:-}" in
    ''|*[!0-9]*)
      _offline_sync_log "$db: offline-sync: could not read embedded @@port — refusing (can't prove it ran embedded)"
      rm -rf "${clone_parent:?}" 2>/dev/null
      return 1
      ;;
  esac
  if [ "$embedded_port" = "$live_port" ]; then
    _offline_sync_log "$db: offline-sync: REFUSING — embedded @@port ($embedded_port) matches the live server port ($live_port); not isolated"
    rm -rf "${clone_parent:?}" 2>/dev/null
    return 1
  fi

  local rc=0
  if ! timeout "$sync_timeout" "$dolt_bin" --data-dir "$clone" backup sync-url "file://$dest" >>"${OFFLINE_SYNC_LOG:-/dev/stderr}" 2>&1; then
    _offline_sync_log "$db: offline-sync: dolt backup sync-url FAILED (or timed out after ${sync_timeout}s)"
    rc=1
  else
    _offline_sync_log "$db: offline-sync: OK ($src -> $dest, server-free)"
  fi

  rm -rf "${clone_parent:?}" 2>/dev/null
  return "$rc"
}

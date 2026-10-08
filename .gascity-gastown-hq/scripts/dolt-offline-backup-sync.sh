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
# SEEDED MODE (ga-a0woau, opt-in: OFFLINE_SYNC_SEED_OLDGEN=1) — a fresh <dest> no longer costs a full
# copy of the store. `dolt backup sync-url` into an EMPTY dest rewrites every chunk it is asked for
# (measured on 2.3.1: the dest ends up as one consolidated table as big as the whole store — 11GB for hq,
# on a disk with 7-12GB free: 8 of 9 nights refused, 30/09..08/10). But the dest is an NBS store, and so is
# the live store's `.dolt/noms/oldgen/` — its own `manifest` plus content-addressed table files, i.e. what
# GC already compacted (hq: 11.3GB of the 11.5GB). Pre-loading the dest with CLONEFILE copies of exactly
# that (manifest + tables, ~0 real disk) makes the dest "already have" those chunks: sync-url then writes
# ONLY the new table holding what is not in oldgen (measured: 17MB real disk vs 62MB unseeded on a scratch
# repo; the restored copy matched the live row count). Layout and format of the dest are unchanged, so the
# S3 upload, the manifest-closure proof, the restore and the status readers do not change.
#   - the seeded store is built under the same tmp root as the clone and only RENAMED onto <dest> after
#     sync-url succeeded: a crash or a failed sync never leaves a dest whose manifest closes (all its
#     tables are present) but names a zero root — that would pass a closure proof and then restore EMPTY.
#   - the seed is verified against its own manifest (every table the oldgen manifest names is in the
#     seed) before sync-url runs; a seed that does not close is not used.
#   - OFFLINE_SYNC_REQUIRE_SEED=1 (set by a caller whose disk gate counted on the seed) turns "cannot seed"
#     into a REFUSAL: falling back to the full build would write the GBs the gate never reserved
#     (ga-odtd3f: that took the live Dolt down for 5h20).
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
#   - confirms the CLI actually ran embedded, not routed through a live
#     server, by checking the clone's `SELECT @@port` differs from the live
#     server's port (proven live 2026-09-14: embedded default is 3306, this
#     city's live port is 52756 — never hardcode either side, both are
#     derived fresh each call). This is the ONLY guard against `dolt sql
#     --help`'s documented hazard of a data-dir claimed by a live server
#     silently routing queries through it — there is deliberately no
#     file-marker check for this: a per-db clone (`$data_dir/$db` ->
#     `$clone_parent/$db`) can never carry its own `.dolt/sql-server.info`,
#     because in this city's multi-db deployment that marker lives once, at
#     the shared `$data_dir/.dolt/` root, never inside a per-db subdirectory
#     (verified live against all 7 running databases, ga-o3nqy2 gate-fix). A
#     marker check scoped to the clone would be structurally dead code; @@port
#     is what actually fires.
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

# _offline_sync_oldgen_names <manifest> — the table-file names an NBS manifest lists, one per line.
# Manifest line: version:storage:lock:root:gcgen:<table>:<chunks>:<table>:<chunks>… — so fields 6, 8, 10…
# vazio → prints nothing (the manifest lists no table: an empty oldgen); falhou/ilegível (no such
# file, unreadable, not a manifest line) → prints nothing too but returns 1, so a caller that needs the
# difference tests the return code; "no tables" and "could not read" must never be the same answer.
_offline_sync_oldgen_names() {
  local f="$1" line
  [ -f "$f" ] && [ -r "$f" ] || return 1
  line="$(head -n 1 "$f" 2>/dev/null)" || return 1
  case "$line" in [0-9]*:__DOLT__:*) ;; *) return 1 ;; esac
  printf '%s\n' "$line" | awk -F: '{ for (i = 6; i <= NF; i += 2) print $i }'
  return 0
}

# _offline_sync_seed_state <db> <dest> — can tonight's sync of <db> into <dest> be SEEDED from the live
# store's oldgen? ONE line on stdout, rc always 0 (callers test the word, never the exit code):
#   ok <oldgen_kb>       seedable; <oldgen_kb> is the disk the seed saves (oldgen's size on disk)
#   no:disabled          OFFLINE_SYNC_SEED_OLDGEN is not 1
#   no:dest-has-content  <dest> already holds something (an incremental sync, or a residue): nothing to seed
#   no:no-data-dir       data_dir could not be read from the Dolt config — cannot tell where oldgen is
#   no:volume            data_dir, the tmp root and <dest>'s parent are not all verifiably on one volume
#                        (cp -c would silently become a full copy; the final rename would become a copy)
#   no:no-oldgen         the store has no oldgen manifest or its manifest lists no table: never
#                        GC'd — nothing to seed, and that is a fact about the store, not a failure
#   no:unreadable        oldgen exists but could not be read or measured (manifest, table files, du) —
#                        failed ≠ empty: it is reported as its own word and is never treated as seedable
# Only "ok" credits anything; every "no:*" leaves the caller on the legacy full-build requirement.
_offline_sync_seed_state() {
  local db="$1" dest="$2"
  local tmp_root="${OFFLINE_SYNC_TMP_ROOT:-/tmp}"
  [ "${OFFLINE_SYNC_SEED_OLDGEN:-0}" = "1" ] || { echo "no:disabled"; return 0; }
  case "$db" in ''|*[!A-Za-z0-9_]*) echo "no:unreadable"; return 0 ;; esac
  # vazio (no entry in the dest dir) → "absent", fine to seed; falhou (cannot list it) → the answer is
  # "has content": a dest we cannot look into is never overwritten by a rename.
  if [ -e "$dest" ] || [ -L "$dest" ]; then
    [ -d "$dest" ] && [ ! -L "$dest" ] || { echo "no:dest-has-content"; return 0; }
    local listing
    listing="$(ls -A "$dest" 2>/dev/null)" || { echo "no:dest-has-content"; return 0; }
    [ -z "$listing" ] || { echo "no:dest-has-content"; return 0; }
  fi
  local data_dir; data_dir="$(_offline_sync_data_dir 2>/dev/null)"
  [ -n "$data_dir" ] || { echo "no:no-data-dir"; return 0; }
  # vazio/falhou on stat → _offline_sync_same_volume is false: "volume", i.e. not seedable (inert).
  _offline_sync_same_volume "$data_dir" "$tmp_root" && _offline_sync_same_volume "$data_dir" "$(dirname "$dest")" \
    || { echo "no:volume"; return 0; }
  local og="$data_dir/$db/.dolt/noms/oldgen"
  [ -d "$og" ] && [ -f "$og/manifest" ] || { echo "no:no-oldgen"; return 0; }
  local names; names="$(_offline_sync_oldgen_names "$og/manifest")" || { echo "no:unreadable"; return 0; }
  [ -n "$names" ] || { echo "no:no-oldgen"; return 0; }
  local n missing=0
  for n in $names; do [ -f "$og/$n" ] || [ -f "$og/$n.darc" ] || missing=$((missing+1)); done
  [ "$missing" -eq 0 ] || { echo "no:unreadable"; return 0; }
  # vazio (du prints nothing) / falhou (non-number) → "unreadable": a saving we cannot measure is not credited.
  local kb; kb="$(du -sk "$og" 2>/dev/null | awk '{print $1}')"
  case "${kb:-}" in ''|*[!0-9]*|0) echo "no:unreadable"; return 0 ;; esac
  echo "ok $kb"
  return 0
}

# _offline_sync_seed_build <oldgen_dir> <seed_dir> — builds <seed_dir> (must not exist) as clonefile copies
# of <oldgen_dir>'s `manifest` and of every table file that manifest names, then checks the seed against
# its own manifest. Returns 0 only for a seed that closes; on ANY failure it removes <seed_dir> (a path the
# caller made inside its own mktemp tree) and returns 1, logging why via _offline_sync_log. Table files are
# named by what their manifest says, never by a glob over the directory: a stray file in oldgen is not
# uploaded to S3 as if it were part of the backup.
_offline_sync_seed_build() {
  local og="$1" seed="$2" n src cp_err
  mkdir "$seed" 2>/dev/null || { _offline_sync_log "offline-sync: seed: cannot create $seed"; return 1; }
  # vazio → no names (an oldgen with no table: not seedable, rc 1 below); falhou/ilegível → rc 1 as well.
  local names; names="$(_offline_sync_oldgen_names "$og/manifest")" || names=""
  if [ -z "$names" ]; then
    _offline_sync_log "offline-sync: seed: $og/manifest lists no table or could not be read — not seeding"
    rm -rf "${seed:?}" 2>/dev/null; return 1
  fi
  cp_err="$(timeout 120 cp -c "$og/manifest" "$seed/manifest" 2>&1)" \
    || { _offline_sync_log "offline-sync: seed: manifest clone FAILED: $cp_err"; rm -rf "${seed:?}" 2>/dev/null; return 1; }
  for n in $names; do
    if [ -f "$og/$n" ]; then src="$og/$n"; elif [ -f "$og/$n.darc" ]; then src="$og/$n.darc"; else
      _offline_sync_log "offline-sync: seed: oldgen manifest names $n but the table file is not in $og — not seeding"
      rm -rf "${seed:?}" 2>/dev/null; return 1
    fi
    cp_err="$(timeout 120 cp -c "$src" "$seed/" 2>&1)" \
      || { _offline_sync_log "offline-sync: seed: clone of $(basename "$src") FAILED: $cp_err"; rm -rf "${seed:?}" 2>/dev/null; return 1; }
  done
  # the seed must close on its own manifest, and the clones must be the same size as their sources
  # (vazio/falhou on stat → the sizes differ → not seeding).
  for n in $names; do
    if [ -f "$og/$n" ]; then src="$og/$n"; else src="$og/$n.darc"; fi
    [ "$(stat -f '%z' "$src" 2>/dev/null)" = "$(stat -f '%z' "$seed/$(basename "$src")" 2>/dev/null)" ] \
      && [ -n "$(stat -f '%z' "$seed/$(basename "$src")" 2>/dev/null)" ] \
      || { _offline_sync_log "offline-sync: seed: $(basename "$src") in the seed does not match its source — not seeding"; rm -rf "${seed:?}" 2>/dev/null; return 1; }
  done
  return 0
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

  local cp_err cp_rc
  cp_err="$(timeout "$clone_timeout" cp -c -R "$src" "$clone_parent" 2>&1)"; cp_rc=$?
  # Check the exit code AND the directory's existence — not just one. A
  # nonzero exit (e.g. one unreadable file mid-tree) can still leave a
  # PARTIAL $clone directory behind; trusting existence alone would treat
  # that the same as a clean full copy.
  if [ "$cp_rc" -ne 0 ] || [ ! -d "$clone" ]; then
    _offline_sync_log "$db: offline-sync: clonefile FAILED (rc=$cp_rc) ($src -> $clone) — refusing to fall back to a slow full copy: $cp_err"
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

  # ga-a0woau: a fresh <dest> is SEEDED with clonefile copies of the clone's oldgen (see SEEDED MODE in
  # the header) so sync-url writes only the delta. The sync then runs against a work dir inside
  # $clone_parent and is renamed onto <dest> only after it succeeded.
  # vazio (state "no:*" for a store that was never GC'd, a dest that already holds a copy, the mode off) →
  # the legacy sync straight into <dest>, exactly as before — unless the caller REQUIRES the seed (its disk
  # gate counted on it): then every "no:*", and any failure to build the seed, is a REFUSAL.
  # falhou/ilegível (volume, data_dir or oldgen could not be established, or the seed did not close) →
  # also "no:*": never seeded, and under REQUIRE_SEED never the full build either.
  local sync_dest="$dest" seeded=0 seed_state seed_work=""
  seed_state="$(_offline_sync_seed_state "$db" "$dest")"
  case "$seed_state" in
    "ok "[0-9]*)
      seed_work="$clone_parent/seeded"
      if _offline_sync_seed_build "$clone/.dolt/noms/oldgen" "$seed_work"; then
        sync_dest="$seed_work"; seeded=1
        _offline_sync_log "$db: offline-sync: dest seeded from the snapshot's oldgen (${seed_state#ok }KB of tables as clonefile copies, ~0 real disk) — sync-url writes only what oldgen does not hold"
      elif [ "${OFFLINE_SYNC_REQUIRE_SEED:-0}" = "1" ]; then
        _offline_sync_log "$db: offline-sync: REFUSING — the caller's disk gate counted on the oldgen seed and the seed could not be built; the full build would write the GBs that were never reserved"
        rm -rf "${clone_parent:?}" 2>/dev/null
        return 1
      else
        _offline_sync_log "$db: offline-sync: seed could not be built — falling back to the full sync into $dest"
      fi
      ;;
    *)
      if [ "${OFFLINE_SYNC_REQUIRE_SEED:-0}" = "1" ]; then
        _offline_sync_log "$db: offline-sync: REFUSING — the caller's disk gate counted on the oldgen seed but the seed is not available ($seed_state); the full build would write the GBs that were never reserved"
        rm -rf "${clone_parent:?}" 2>/dev/null
        return 1
      fi
      [ "${OFFLINE_SYNC_SEED_OLDGEN:-0}" = "1" ] && _offline_sync_log "$db: offline-sync: not seeding ($seed_state) — full sync into $dest"
      ;;
  esac

  local rc=0
  if ! timeout "$sync_timeout" "$dolt_bin" --data-dir "$clone" backup sync-url "file://$sync_dest" >>"${OFFLINE_SYNC_LOG:-/dev/stderr}" 2>&1; then
    _offline_sync_log "$db: offline-sync: dolt backup sync-url FAILED (or timed out after ${sync_timeout}s)"
    rc=1
  elif [ "$seeded" -eq 1 ]; then
    # The rename is the commit point: <dest> was absent or an empty directory when the seed was decided;
    # it must STILL be, or the sync is reported failed and nothing is moved (never merge into a dest that
    # filled up meanwhile). rmdir succeeds only on an empty real directory.
    # vazio (absent, or an empty dir that rmdir removes) → proceed; falhou/ilegível (non-empty, a symlink,
    # a file, a dir that cannot be removed) → "not free": FAIL, nothing moved.
    local dest_free=1
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      if [ -d "$dest" ] && [ ! -L "$dest" ] && rmdir "$dest" 2>/dev/null; then :; else dest_free=0; fi
    fi
    if [ "$dest_free" -ne 1 ]; then
      _offline_sync_log "$db: offline-sync: seeded sync finished but $dest is no longer an absent/empty dir — NOT moving the new copy there, reporting FAILED"
      rc=1
    elif ! mv "$sync_dest" "$dest" 2>/dev/null || [ ! -s "$dest/manifest" ]; then
      _offline_sync_log "$db: offline-sync: seeded sync finished but moving it onto $dest FAILED — reporting FAILED"
      rc=1
    else
      _offline_sync_log "$db: offline-sync: OK ($src -> $dest, server-free, seeded from oldgen)"
    fi
  else
    _offline_sync_log "$db: offline-sync: OK ($src -> $dest, server-free)"
  fi

  rm -rf "${clone_parent:?}" 2>/dev/null
  return "$rc"
}

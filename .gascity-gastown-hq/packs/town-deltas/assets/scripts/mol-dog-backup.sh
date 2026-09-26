#!/usr/bin/env bash
# mol-dog-backup — sync Dolt databases to backup remotes and offsite storage.
#
# Replaces mol-dog-backup formula. All operations are deterministic:
# dolt backup sync per DB, rsync backup artifacts to offsite path. No LLM judgment needed.
#
# Runs as an exec order (no LLM, no agent, no wisp).
#
# town-deltas override (ga-gquc1): the embedded copy bounded every per-db
# `dolt backup sync` to a flat 120s and threw away stderr (`2>/dev/null`), so a
# timeout (run_bounded exit 124) and a genuine sync failure both collapsed into
# the identical "<db>(sync failed)" string — the error==empty class (ga-p5q3).
# hq (~6.7G) and whatsapp_automation (~1.5G) are large enough to plausibly need
# more than 120s for a cold/full resync of their local file:// backup target;
# see dolt-s3-backup.sh's SYNC_TIMEOUT=600 for the same kind of operation
# against the same hq db — 600s is proven sufficient there. Script vendored
# into town-deltas/assets for this override (same recipe as gate-sweep's).
# runtime.sh itself is NOT vendored here — it further sources port_resolve.sh
# and is a ~200-line dependency not worth duplicating/drifting — it's sourced
# live from the dolt pack's engine-materialized copy via GC_CITY_PATH instead
# (gate fix-attempt 2: a self-relative $PACK_DIR here resolves under
# town-deltas once vendored, and no runtime.sh was ever copied there).
#
# ga-bz7war: the ga-gquc1 fix above correctly told a timeout apart from a
# real failure, but hq still failed EVERY round — the server connection
# itself (listener.read_timeout_millis) is the bottleneck under load, so no
# per-db timeout budget fixes it. A timeout or connection-closed failure now
# falls back to the same server-free sync (ga-o3nqy2) the 04:00 off-box job
# uses, gated on disk headroom (dolt-disk-floor-guard's own WARN floor) —
# see sync_db_with_fallback below.
#
# ga-ypxbxm: two holes left in that fallback. (1) dolt-gc-maintenance releases
# the hq staging (ga-btnq6h) on the promise that this job rebuilds it, but the
# managed server keeps a cached view of the emptied directory (ga-yct7r1): the
# sync writes ~4GB of tables, dies with "table file not found" and leaves NO
# manifest — an error the fallback did not recognise, so it reported FAILED and
# left the garbage until the next round. "table file not found" now falls back
# too, but only when nothing is committed at the staging (no manifest); with a
# manifest it is the stale-manifest class (ga-b5h83) and stays FAILED.
# (2) The fallback checked only the WARN floor (8GB free), not the size of the
# db: an offline hq sync writes ~8GB, which with 8-10GB free lands next to the
# CRITICAL floor (the ga-odtd3f outage class). It now also needs the same 150%
# of the live size that dolt-s3-backup.sh's _sync_disk_preflight demands. A
# failed server sync against a file:// staging also reports what it left there
# (a non-file remote has no staging to look at, so its line carries no residue).
set -euo pipefail

SMALL_DB_BOUND_SECS=120
LARGE_DB_BOUND_SECS=600
LARGE_DB_THRESHOLD_KB=512000   # 500MB (du -sk units)

# ga-ypxbxm: headroom the offline fallback needs — same rule and defaults as
# dolt-s3-backup.sh's _sync_disk_preflight (SYNC_DISK_MARGIN_PCT/_FLOOR_GB), on
# this script's OWN env vars: one script's safety margin must never silently
# change another's.
OFFLINE_DISK_MARGIN_PCT="${MOL_DOG_BACKUP_DISK_MARGIN_PCT:-150}"   # % of the live db size
OFFLINE_DISK_FLOOR_GB="${MOL_DOG_BACKUP_DISK_FLOOR_GB:-3}"         # absolute backstop for small dbs

# ── PURE classification/sizing logic — unit-tested by mol-dog-backup.selftest.sh ──
# ga-gquc1: run_bounded's exit 124 (coreutils timeout convention) and a genuine
# Dolt sync failure used to collapse into the identical "sync failed" string
# once stderr was discarded, making a benign timeout indistinguishable from a
# real backup failure. classify_sync_failure() is the single place that turns
# (exit code, captured output) into the reported failure reason, and
# bound_for_size_kb() the single place a DB's size becomes its sync timeout —
# both pure and testable without a live Dolt server.
bound_for_size_kb() {
    local size_kb="$1"
    case "$size_kb" in
        ''|*[!0-9]*) size_kb=0 ;;
    esac
    if [ "$size_kb" -ge "$LARGE_DB_THRESHOLD_KB" ]; then
        printf '%s' "$LARGE_DB_BOUND_SECS"
    else
        printf '%s' "$SMALL_DB_BOUND_SECS"
    fi
}

classify_sync_failure() {
    local db="$1" rc="$2" bound="$3" output="$4" err_line
    if [ "$rc" -eq 124 ]; then
        printf '%s(timeout after %ss)' "$db" "$bound"
        return
    fi
    err_line=$(printf '%s\n' "$output" | grep -v '^[[:space:]]*$' | head -1 || true)
    if [ -n "$err_line" ]; then
        printf '%s(sync failed: %s)' "$db" "$err_line"
    else
        printf '%s(sync failed: exit %s)' "$db" "$rc"
    fi
}

# fmt_kb <kb> — PURE. du-style KB → "512KB" / "37MB" / "4.4GB"; "?" when the
# input is not a number, so an unmeasured size never reads as "0KB".
fmt_kb() {
    local kb="$1" tenths
    case "$kb" in
        ''|*[!0-9]*) printf '?'; return ;;
    esac
    kb=$((10#$kb))
    if [ "$kb" -ge 1048576 ]; then
        tenths=$(( kb * 10 / 1048576 ))
        printf '%d.%dGB' $((tenths / 10)) $((tenths % 10))
    elif [ "$kb" -ge 1024 ]; then
        printf '%dMB' $((kb / 1024))
    else
        printf '%dKB' "$kb"
    fi
}

# staging_manifest_state <dest> — what is COMMITTED at a file:// backup staging.
# Read-only. Prints exactly one of four words that must never collapse:
#   no-dir        the directory does not exist (e.g. released by dolt-gc-maintenance)
#   no-manifest   it exists but holds no `manifest` — nothing is committed; whatever
#                 tables are in there are residue of an aborted sync
#   has-manifest  a readable manifest exists — a backup is committed there
#   unknown       could not tell (empty arg, not a dir, a path we may not search or
#                 read). Never guessed into one of the others: "cannot see" is not
#                 "does not exist" and not "no manifest".
staging_manifest_state() {
    local dest="$1" parent
    if [ -z "$dest" ]; then
        printf 'unknown'
        return
    fi
    if [ ! -e "$dest" ]; then
        # "does not exist" is only believable if we could have seen it: a parent
        # we may not search makes every child look absent.
        parent="$(dirname "$dest")"
        if [ -d "$parent" ] && [ -r "$parent" ] && [ -x "$parent" ]; then
            printf 'no-dir'
        else
            printf 'unknown'
        fi
        return
    fi
    if [ ! -d "$dest" ] || [ ! -r "$dest" ] || [ ! -x "$dest" ]; then
        printf 'unknown'
        return
    fi
    if [ -e "$dest/manifest" ]; then
        if [ -r "$dest/manifest" ]; then
            printf 'has-manifest'
        else
            printf 'unknown'
        fi
    else
        printf 'no-manifest'
    fi
}

# dir_size_kb <dir> — `du -sk` of <dir>, or EMPTY when it could not be measured.
dir_size_kb() {
    local kb
    kb="$(du -sk "$1" 2>/dev/null | awk '{print $1}')" || kb=""
    case "$kb" in
        ''|*[!0-9]*) printf '' ;;
        *) printf '%s' "$kb" ;;
    esac
}

# staging_size_kb <dest> — size of a staging dir in KB: 0 when the dir is
# verifiably absent, EMPTY (unknown) when it could not be measured.
staging_size_kb() {
    if [ "$(staging_manifest_state "$1")" = "no-dir" ]; then
        printf '0'
        return
    fi
    dir_size_kb "$1"
}

# staging_residue_note <pre_kb> <post_kb> <post_state> — PURE. The one-line report of what a
# failed server-mediated sync left in the staging (ga-ypxbxm: "cannot fail without
# saying how much garbage it left" — the aborted hq sync left 4.4GB with no manifest).
staging_residue_note() {
    printf 'staging residue: %s now (was %s), manifest=%s' \
        "$(fmt_kb "$2")" "$(fmt_kb "$1")" "${3:-unknown}"
}

# _avail_kb <path> — free KB on the volume that holds <path>, measured at its nearest
# existing ancestor (a released staging dir does not exist). EMPTY when it could not
# be read. Its own function so a selftest can say exactly how much room there is.
_avail_kb() {
    local p="$1" kb
    while [ -n "$p" ] && [ ! -d "$p" ]; do
        if [ "$p" = "/" ]; then
            break
        fi
        p="$(dirname "$p")"
    done
    kb="$(df -k "$p" 2>/dev/null | awk 'NR==2 {print $4}')" || kb=""
    case "$kb" in
        ''|*[!0-9]*) printf '' ;;
        *) printf '%s' "$kb" ;;
    esac
}

# offline_fallback_disk_check <live_kb> <avail_kb> <margin_pct> <floor_gb> — PURE.
# Does the volume have room for an offline sync to write ~the whole live db? Needs
# margin_pct% of the live size, floored at floor_gb (same rule as dolt-s3-backup.sh's
# _sync_disk_preflight). Prints the KB needed when it can be computed. Returns:
#   0  enough room (avail >= need, inclusive)
#   1  SHORT — measured, and there is not enough
#   2  UNKNOWN — an input is not a non-negative integer. Fail-closed and distinct from
#      SHORT: the caller must be able to say "could not measure" rather than "no room".
offline_fallback_disk_check() {
    local live_kb="$1" avail_kb="$2" margin_pct="$3" floor_gb="$4" v need_kb floor_kb
    for v in "$live_kb" "$avail_kb" "$margin_pct" "$floor_gb"; do
        case "$v" in
            ''|*[!0-9]*) return 2 ;;
        esac
    done
    need_kb=$(( 10#$live_kb * 10#$margin_pct / 100 ))
    floor_kb=$(( 10#$floor_gb * 1024 * 1024 ))
    if [ "$need_kb" -lt "$floor_kb" ]; then
        need_kb="$floor_kb"
    fi
    printf '%s' "$need_kb"
    [ $((10#$avail_kb)) -ge "$need_kb" ]
}

# is_fallback_eligible_failure <rc> <output> [<staging_state>] — PURE. True (0) only for the
# SPECIFIC failure class ga-bz7war targets: a run_bounded timeout (rc=124) or
# the managed server's listener.read_timeout_millis cutting the connection
# mid-sync (ga-o3nqy2: hq has failed every night since 2026-09-11 this way —
# the server connection is the bottleneck, not the data, so retrying the same
# server-mediated call never helps). "context canceled" is the literal
# signature the bare `dolt backup sync <name>` CLI form emits for that cut
# (confirmed live 2026-09-14 23:15: "Error 1105 (HY000): context canceled",
# ga-bz7war); "connection was closed" is kept for parity with
# dolt-s3-backup.sh's is_connection_timeout_error, which hits the SAME root
# cause through its explicit --host/--port form. A GENUINE sync failure (bad
# remote, corrupt staging, a real disk error) must return 1 here — falling
# back would just reproduce the same failure over a slower path and
# misreport a real problem as transient.
#
# ga-ypxbxm: "table file not found" is the one signature whose class depends on
# the STAGING (<staging_state> = staging_manifest_state, measured AFTER the
# failed sync). With nothing committed there (no-dir / no-manifest) it is the
# released-staging case — the server's cached view of a directory that was
# emptied under it (ga-yct7r1) — and a fresh server-free sync rebuilds it from
# scratch. With a manifest present (or a state we could not read) it is the
# stale-manifest class (ga-b5h83): the manifest itself names a table that is
# gone, the offline path would read the same manifest, so it must stay FAILED.
# The state alone is never a trigger, and an omitted <staging_state> is "cannot
# tell" — not eligible.
is_fallback_eligible_failure() {
    local rc="$1" output="$2" staging_state="${3:-}"
    if [ "$rc" -eq 124 ]; then
        return 0
    fi
    case "$output" in
        *"context canceled"*) return 0 ;;
        *"connection was closed"*) return 0 ;;
        *"table file not found"*)
            case "$staging_state" in
                no-dir|no-manifest) return 0 ;;
                *) return 1 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# deacon_nudge_allowed <suspended_flag> — PURE. Nudging a suspended agent
# queues forever: the recipient never wakes to consume it, and every
# `gc nudge poll` iteration reloads the ENTIRE queue state regardless of
# size — 379 such DOG_DONE nudges to a 20-day-asleep, suspended deacon
# dominated Dolt poll load (48-58% of total load across 3 measurements —
# see ga-clgc2). deacon's `suspended` flag (city.toml) is the same
# authoritative signal `gc agent list`/`gc agent suspend` already read and
# write. Fail-CLOSED by construction: only the literal string "false" allows
# the nudge — empty/unknown/garbage input (lookup failure, deacon not found)
# is treated as suspended and skipped, never guessed-open. This lives in the
# pure function itself (not just the caller's fallback) so the safety
# invariant holds regardless of how deacon_nudge_allowed() gets called.
# Unit-tested by mol-dog-backup.selftest.sh (library mode).
deacon_nudge_allowed() {
    local suspended_flag="$1"
    [ "$suspended_flag" = "false" ]
}

# sync_db_with_fallback <db> <db_dir> <bound> — attempt the server-mediated
# `dolt backup sync <db>-backup`; on a fallback-eligible failure (timeout or
# connection-closed — is_fallback_eligible_failure above), fall back to the
# shared server-free _offline_backup_sync (ga-o3nqy2,
# scripts/dolt-offline-backup-sync.sh), the same mechanism and semantics as
# the 04:00 off-box job (dolt-s3-backup.sh). Before attempting the fallback,
# checks disk headroom against dolt-disk-floor-guard's own WARN floor via its
# _floor_class — an offline sync clones the live db directory (cp -c), and a
# floor breach means "do not start a disk operation right now", not silence.
#
# Depends on (defined by sourcing, never redefined here): run_bounded
# (runtime.sh), _avail_gb/_floor_class (dolt-disk-floor-guard.sh, library
# mode), _offline_backup_sync (dolt-offline-backup-sync.sh), and the globals
# DOLT_DATA_DIR/FLOOR_WARN_GB/FLOOR_CRITICAL_GB. Defined ahead of the
# MOL_DOG_BACKUP_LIB gate below (like the pure functions above) so a selftest
# can exercise it directly once it sources those same dependencies itself —
# see mol-dog-backup.selftest.sh.
#
# Echoes exactly one line, one of:
#   OK <db>
#   SKIP <db>(<reason>)
#   FAILED <db>(<reason>)
# — mutually exclusive by construction (one printf per branch), so a database
# is never counted into more than one of the three states.
sync_db_with_fallback() {
    local db="$1" db_dir="$2" bound="$3"
    local sync_rc=0 sync_output

    # ga-ypxbxm: resolve the file:// staging BEFORE the sync (a local, read-only
    # listing) so its size can be measured on both sides of the attempt — the
    # difference is what a failed server sync leaves behind, and that is reported.
    local backup_url dest="" pre_kb=""
    # Guarded with `|| backup_url=""`: under pipefail, `dolt backup -v`
    # itself failing (rare — a local, read-only listing) would otherwise
    # abort the whole script via set -e even though awk succeeds. An empty
    # backup_url leaves dest empty, which the non-file branch below treats
    # as "no offline fallback possible" and reports the original failure —
    # the correct, safe behavior when the URL can't be determined at all.
    backup_url=$(cd "$db_dir" && dolt backup -v 2>/dev/null | awk -v n="${db}-backup" '$1==n {print $2; exit}') \
        || backup_url=""
    case "$backup_url" in
        file://*)
            dest="${backup_url#file://}"
            pre_kb="$(staging_size_kb "$dest")"
            ;;
    esac

    sync_output=$(cd "$db_dir" && run_bounded "$bound" dolt backup sync "${db}-backup" 2>&1) || sync_rc=$?

    if [ "$sync_rc" -eq 0 ]; then
        printf 'OK %s\n' "$db"
        return
    fi

    # What the failed server sync left behind. dest_state stays empty for a
    # non-file remote (no staging to look at) — which is_fallback_eligible_failure
    # reads as "cannot tell", never as "nothing committed".
    local dest_state="" residue="" note
    if [ -n "$dest" ]; then
        dest_state="$(staging_manifest_state "$dest")"
        note="$(staging_residue_note "$pre_kb" "$(staging_size_kb "$dest")" "$dest_state")"
        residue=" [$note]"
        echo "backup: $db: server-mediated sync failed (rc=$sync_rc) — $note" >&2
    fi

    if ! is_fallback_eligible_failure "$sync_rc" "$sync_output" "$dest_state"; then
        printf 'FAILED %s%s\n' "$(classify_sync_failure "$db" "$sync_rc" "$bound" "$sync_output")" "$residue"
        return
    fi

    local avail avail_class
    avail="$(_avail_gb "$DOLT_DATA_DIR")"
    avail_class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"
    if [ "$avail_class" != "NONE" ]; then
        printf 'SKIP %s(disk floor %s: avail=%sGB warn=%sGB)%s\n' \
            "$db" "$avail_class" "${avail:-?}" "$FLOOR_WARN_GB" "$residue"
        return
    fi

    if [ -z "$dest" ]; then
        # Offline fallback only ever applies to a file:// backup target
        # (it clones the live db dir and syncs the clone straight to a
        # local path — see dolt-offline-backup-sync.sh's header). A
        # non-file remote (S3, a future scheme) can't use it; report the
        # original failure unchanged.
        printf 'FAILED %s\n' "$(classify_sync_failure "$db" "$sync_rc" "$bound" "$sync_output")"
        return
    fi

    # ga-ypxbxm: the WARN floor above only says "the disk is not already in
    # trouble". An offline sync writes ~the whole live db into the staging, so
    # it also needs room in proportion to THAT (150% of the live size, same rule
    # as dolt-s3-backup.sh's _sync_disk_preflight) — otherwise 8-10GB free and an
    # 8GB hq lands next to the CRITICAL floor (the ga-odtd3f outage class). Below
    # it, or when either number cannot be measured, nothing is written: SKIP with
    # the reason, and the two cases stay distinguishable in the message.
    local live_kb avail_kb need_kb check_rc=0
    live_kb="$(dir_size_kb "$db_dir")"
    avail_kb="$(_avail_kb "$dest")"
    need_kb="$(offline_fallback_disk_check "$live_kb" "$avail_kb" "$OFFLINE_DISK_MARGIN_PCT" "$OFFLINE_DISK_FLOOR_GB")" \
        || check_rc=$?
    case "$check_rc" in
        0) ;;
        1)
            printf 'SKIP %s(disk preflight: offline fallback needs %s free (%s%% of %s live, floor %sGB), %s available — not attempted, nothing written)%s\n' \
                "$db" "$(fmt_kb "$need_kb")" "$OFFLINE_DISK_MARGIN_PCT" "$(fmt_kb "$live_kb")" \
                "$OFFLINE_DISK_FLOOR_GB" "$(fmt_kb "$avail_kb")" "$residue"
            return
            ;;
        *)
            printf 'SKIP %s(disk preflight: could not measure live size (%s) or free space (%s) — not attempted, nothing written)%s\n' \
                "$db" "$(fmt_kb "$live_kb")" "$(fmt_kb "$avail_kb")" "$residue"
            return
            ;;
    esac

    if OFFLINE_SYNC_TIMEOUT="$bound" _offline_backup_sync "$db" "$dest"; then
        printf 'OK %s\n' "$db"
        return
    fi
    # The offline attempt may have changed the staging too — report it as it is now.
    residue=" [$(staging_residue_note "$pre_kb" "$(staging_size_kb "$dest")" "$(staging_manifest_state "$dest")")]"
    local why
    if [ "$sync_rc" -eq 124 ]; then
        why="server sync timeout after ${bound}s"
    else
        case "$sync_output" in
            *"table file not found"*) why="server sync could not find a table file in the emptied staging" ;;
            *) why="server connection closed mid-sync" ;;
        esac
    fi
    printf 'FAILED %s(offline fallback also failed — %s)%s\n' "$db" "$why" "$residue"
}

# Library mode: `MOL_DOG_BACKUP_LIB=1 source mol-dog-backup.sh` defines the pure
# functions above without resolving a live Dolt runtime or running the backup
# flow (port resolution, real syncs, mail/nudge).
if [ "${MOL_DOG_BACKUP_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

: "${GC_CITY_PATH:?GC_CITY_PATH must be set}"
# ga-v75ka: engine exports GC_PACK_DIR=town-deltas (the pack owning this order),
# but runtime.sh:209 trusts GC_PACK_DIR to find its sibling port_resolve.sh —
# override it to dolt's own pack dir for this source, or the dog dies on boot.
GC_PACK_DIR="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt" \
    . "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh"

# ga-bz7war: server-free fallback (ga-o3nqy2) + disk-floor guard (ga-gpzr),
# both library-mode sourced from their real, GC_CITY_PATH-anchored location —
# same anchoring discipline as runtime.sh above, for the same reason (a
# self-relative path here would resolve under town-deltas once vendored, and
# neither file is vendored into this pack). OFFLINE_SYNC_DOLT_CFG is read
# only by _offline_backup_sync's own internal data_dir/port derivation, kept
# independent of this script's own DOLT_DATA_DIR/GC_DOLT_PORT (from
# runtime.sh) by that shared function's own contract.
. "$GC_CITY_PATH/scripts/dolt-offline-backup-sync.sh"
# shellcheck disable=SC2034
OFFLINE_SYNC_DOLT_CFG="$GC_CITY_PATH/.gc/runtime/packs/dolt/dolt-config.yaml"
DOLT_DISK_FLOOR_GUARD_LIB=1 . "$GC_CITY_PATH/scripts/dolt-disk-floor-guard.sh"

PORT="$GC_DOLT_PORT"
HOST="${GC_DOLT_HOST:-127.0.0.1}"
USER="${GC_DOLT_USER:-root}"
OFFSITE_PATH="${GC_BACKUP_OFFSITE_PATH:-}"
BACKUP_ARTIFACT_DIR="${GC_BACKUP_ARTIFACT_DIR:-$GC_CITY_PATH/.dolt-backup}"
SYSTEM_DBS="^(information_schema|mysql|dolt_cluster|__gc_probe|performance_schema|sys)$"
MIN_DOLT_BACKUP_VERSION="1.86.2"

dolt_sql() {
    DOLT_CLI_PASSWORD="${GC_DOLT_PASSWORD:-}" \
        run_bounded 30 \
        dolt --host "$HOST" --port "$PORT" --user "$USER" --no-tls sql "$@"
}

dolt_version_at_least() {
    current="${1#v}"
    minimum="$2"
    current="${current%%+*}"
    minimum="${minimum%%+*}"
    case "$current" in
        *-*) return 1 ;;
    esac
    IFS=. read -r cur_major cur_minor cur_patch <<EOF
$current
EOF
    IFS=. read -r min_major min_minor min_patch <<EOF
$minimum
EOF
    for part in "$cur_major" "$cur_minor" "$cur_patch" "$min_major" "$min_minor" "$min_patch"; do
        case "$part" in
            ''|*[!0-9]*) return 1 ;;
        esac
    done
    cur_major=$((10#$cur_major))
    cur_minor=$((10#$cur_minor))
    cur_patch=$((10#$cur_patch))
    min_major=$((10#$min_major))
    min_minor=$((10#$min_minor))
    min_patch=$((10#$min_patch))
    if [ "$cur_major" -ne "$min_major" ]; then
        [ "$cur_major" -gt "$min_major" ]
        return $?
    fi
    if [ "$cur_minor" -ne "$min_minor" ]; then
        [ "$cur_minor" -gt "$min_minor" ]
        return $?
    fi
    [ "$cur_patch" -ge "$min_patch" ]
}

append_failed_db() {
    db_failure="$1"
    FAILED=$((FAILED + 1))
    if [ -n "$FAILED_DBS" ]; then
        FAILED_DBS="$FAILED_DBS, $db_failure"
    else
        FAILED_DBS="$db_failure"
    fi
}

# append_skipped_db <reason> — a THIRD state, distinct from both OK and
# FAILED (ga-bz7war AC4): a disk-floor breach means "did not attempt this
# db this round", never "it synced" and never "it failed to sync". Kept as
# its own counter/list so Step 4 can never fold it into $FAILED and mail on
# it — only a genuine FAILED is mail-worthy.
append_skipped_db() {
    db_skip="$1"
    SKIPPED=$((SKIPPED + 1))
    if [ -n "$SKIPPED_DBS" ]; then
        SKIPPED_DBS="$SKIPPED_DBS, $db_skip"
    else
        SKIPPED_DBS="$db_skip"
    fi
}

# nudge_deacon_done <message> — best-effort DOG_DONE status ping, sent ONLY
# when deacon can actually consume it (ga-clgc2). `gc agent list --json` is a
# static city.toml read (no Dolt round-trip, ~0.1-0.2s) — cheap enough for
# every dog run. Any lookup failure (gc/jq error, deacon not found) fails
# CLOSED (treated as suspended, nudge skipped) — same "when in doubt, don't
# queue forever" bias as the rest of this fix. Skip is logged to stderr:
# visible, not the old `2>/dev/null || true` silent swallow (ga-clgc2 AC2).
nudge_deacon_done() {
    local message="$1" suspended
    suspended=$(gc agent list --json 2>/dev/null \
        | jq -r '.agents[]? | select(.qualified_name=="gastown.deacon") | .suspended' 2>/dev/null \
        | head -1 || echo "true")
    if ! deacon_nudge_allowed "${suspended:-true}"; then
        echo "backup: skipped DOG_DONE nudge to deacon (suspended=${suspended:-unknown}) — $message" >&2
        return 0
    fi
    # Bare "deacon/" resolves via bd issue-ID lookup and fuzzy-matches ANY
    # bead whose ID contains "deacon" as a substring — this city has two
    # (dc-deacon-refinery, dc-deacon-witness), so it fails ambiguous and the
    # nudge below was silently lost via `|| true` (ga-4zbjs). Target the
    # verified live session by its qualified name instead — same name this
    # function already keys its suspension check on, three lines up.
    gc session nudge gastown.deacon/ "$message" 2>/dev/null || true
}

# --- Step 1: Preflight Dolt version before backup sync ---

DOLT_VERSION="$(dolt version 2>/dev/null | awk 'NR == 1 {print $NF}' || true)"
if ! dolt_version_at_least "$DOLT_VERSION" "$MIN_DOLT_BACKUP_VERSION"; then
    gc mail send mayor/ --from controller \
        -s "Backup dog: dolt-too-old for backup sync [HIGH]" \
        -m "Skipping backup sync: dolt version ${DOLT_VERSION:-unknown} is below required ${MIN_DOLT_BACKUP_VERSION}. Older versions can hang the sql-server during dolt backup sync." \
        2>/dev/null || true
    SUMMARY="backup — dolt-too-old: ${DOLT_VERSION:-unknown}, required: $MIN_DOLT_BACKUP_VERSION"
    nudge_deacon_done "DOG_DONE: $SUMMARY"
    echo "backup: $SUMMARY"
    exit 1
fi

# --- Step 2: Sync databases to backup remotes ---

# If GC_BACKUP_DATABASES is set, use it; otherwise auto-discover DBs that
# have a named Dolt backup <db>-backup configured.
if [ -n "${GC_BACKUP_DATABASES:-}" ]; then
    DATABASES=$(echo "$GC_BACKUP_DATABASES" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true)
else
    # Auto-discover: find databases that have a named Dolt backup <db>-backup.
    ALL_DBS=$(dolt_sql -r csv -q "SHOW DATABASES" 2>/dev/null | tail -n +2 | \
        grep -viE "$SYSTEM_DBS" || true)
    DATABASES=""
    for db in $ALL_DBS; do
        db_dir="$DOLT_DATA_DIR/$db"
        if [ -d "$db_dir/.dolt" ]; then
            if (cd "$db_dir" && dolt backup 2>/dev/null | awk '{print $1}' | grep -x "${db}-backup" >/dev/null); then
                DATABASES="$DATABASES $db"
            fi
        fi
    done
    DATABASES=$(echo "$DATABASES" | tr ' ' '\n' | grep -v '^$' || true)
fi

if [ -z "$DATABASES" ]; then
    echo "backup: no databases with backup remotes found, skipping"
    exit 0
fi

TOTAL=$(printf '%s\n' "$DATABASES" | awk 'NF {count++} END {print count + 0}')
SYNCED=0
FAILED=0
SKIPPED=0
FAILED_DBS=""
SKIPPED_DBS=""

for db in $DATABASES; do
    db_dir="$DOLT_DATA_DIR/$db"
    if [ ! -d "$db_dir" ]; then
        append_failed_db "$db(not found)"
        continue
    fi

    db_size_kb=$(du -sk "$db_dir" 2>/dev/null | awk '{print $1}' || true)
    sync_bound=$(bound_for_size_kb "$db_size_kb")

    result=$(sync_db_with_fallback "$db" "$db_dir" "$sync_bound")
    status="${result%% *}"
    detail="${result#* }"
    case "$status" in
        OK) SYNCED=$((SYNCED + 1)) ;;
        SKIP) append_skipped_db "$detail" ;;
        FAILED) append_failed_db "$detail" ;;
        *) append_failed_db "$db(sync_db_with_fallback: unexpected output '$result')" ;;
    esac
done

FAILED_COUNT=$FAILED
OFFSITE_STATUS="skipped"

# --- Step 3: Rsync backup artifacts to offsite storage ---

if [ -n "$OFFSITE_PATH" ]; then
    if [ ! -d "$BACKUP_ARTIFACT_DIR" ]; then
        OFFSITE_STATUS="missing-artifacts"
    elif same_path "$BACKUP_ARTIFACT_DIR" "$DOLT_DATA_DIR"; then
        OFFSITE_STATUS="invalid-source"
    elif run_bounded 300 rsync -a --delete "$BACKUP_ARTIFACT_DIR/" "$OFFSITE_PATH/" 2>/dev/null; then
        OFFSITE_STATUS="ok"
    else
        OFFSITE_STATUS="failed (non-fatal)"
    fi
fi

# --- Step 4: Report ---

if [ "$FAILED_COUNT" -gt 0 ]; then
    gc mail send mayor/ --from controller \
        -s "Backup dog: $FAILED_COUNT/$TOTAL databases failed to sync [MEDIUM]" \
        -m "Failed databases:$FAILED_DBS" \
        2>/dev/null || true
fi

if [ "$SKIPPED" -gt 0 ]; then
    echo "backup: skipped databases:$SKIPPED_DBS"
fi

SUMMARY="backup — synced: $SYNCED/$TOTAL, skipped: $SKIPPED, offsite: $OFFSITE_STATUS"
nudge_deacon_done "DOG_DONE: $SUMMARY"
echo "backup: $SUMMARY"

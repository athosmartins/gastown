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
set -euo pipefail

SMALL_DB_BOUND_SECS=120
LARGE_DB_BOUND_SECS=600
LARGE_DB_THRESHOLD_KB=512000   # 500MB (du -sk units)

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

# is_fallback_eligible_failure <rc> <output> — PURE. True (0) only for the
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
is_fallback_eligible_failure() {
    local rc="$1" output="$2"
    if [ "$rc" -eq 124 ]; then
        return 0
    fi
    case "$output" in
        *"context canceled"*) return 0 ;;
        *"connection was closed"*) return 0 ;;
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

    sync_output=$(cd "$db_dir" && run_bounded "$bound" dolt backup sync "${db}-backup" 2>&1) || sync_rc=$?

    if [ "$sync_rc" -eq 0 ]; then
        printf 'OK %s\n' "$db"
        return
    fi

    if ! is_fallback_eligible_failure "$sync_rc" "$sync_output"; then
        printf 'FAILED %s\n' "$(classify_sync_failure "$db" "$sync_rc" "$bound" "$sync_output")"
        return
    fi

    local avail avail_class
    avail="$(_avail_gb "$DOLT_DATA_DIR")"
    avail_class="$(_floor_class "$avail" "$FLOOR_WARN_GB" "$FLOOR_CRITICAL_GB")"
    if [ "$avail_class" != "NONE" ]; then
        printf 'SKIP %s(disk floor %s: avail=%sGB warn=%sGB)\n' \
            "$db" "$avail_class" "${avail:-?}" "$FLOOR_WARN_GB"
        return
    fi

    local backup_url dest
    # Guarded with `|| backup_url=""`: under pipefail, `dolt backup -v`
    # itself failing (rare — a local, read-only listing) would otherwise
    # abort the whole script via set -e even though awk succeeds. An empty
    # backup_url falls through to the non-file `*)` branch below, which
    # reports the original failure — the correct, safe behavior when the
    # URL can't be determined at all.
    backup_url=$(cd "$db_dir" && dolt backup -v 2>/dev/null | awk -v n="${db}-backup" '$1==n {print $2; exit}') \
        || backup_url=""
    case "$backup_url" in
        file://*)
            dest="${backup_url#file://}"
            if OFFLINE_SYNC_TIMEOUT="$bound" _offline_backup_sync "$db" "$dest"; then
                printf 'OK %s\n' "$db"
            elif [ "$sync_rc" -eq 124 ]; then
                printf 'FAILED %s(offline fallback also failed — server sync timeout after %ss)\n' "$db" "$bound"
            else
                printf 'FAILED %s(offline fallback also failed — server connection closed mid-sync)\n' "$db"
            fi
            ;;
        *)
            # Offline fallback only ever applies to a file:// backup target
            # (it clones the live db dir and syncs the clone straight to a
            # local path — see dolt-offline-backup-sync.sh's header). A
            # non-file remote (S3, a future scheme) can't use it; report the
            # original failure unchanged.
            printf 'FAILED %s\n' "$(classify_sync_failure "$db" "$sync_rc" "$bound" "$sync_output")"
            ;;
    esac
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
            if (cd "$db_dir" && dolt backup 2>/dev/null | awk '{print $1}' | grep -qx "${db}-backup"); then
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

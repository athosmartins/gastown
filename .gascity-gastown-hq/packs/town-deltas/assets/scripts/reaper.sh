#!/usr/bin/env bash
# reaper — close stale wisps with closed parents, purge old closed data, auto-close stale and TTL-expired issues.
#
# Replaces mol-dog-reaper formula. All operations are deterministic:
# SQL queries with age thresholds, bd close/update commands, count
# comparisons against alert thresholds.
#
# Runs as an exec order (no LLM, no agent, no wisp).
#
# town-deltas override (ga-u8nbt9): vendored from the embedded maintenance copy
# so this fix is git-tracked and durable ($PACK_DIR in
# packs/town-deltas/orders/mol-dog-reaper.toml resolves here; the embedded copy
# is gitignored and re-extracted from the gc binary on reload). Same recipe as
# the wisp-compact override (ga-3rqwa). What changed vs. the embedded script:
#
#  1. THE PER-DATABASE SCHEMA GATE WAS A SILENT SKIP. The embedded script did
#     `has_dependency_target_column ... || continue` ("Skip silently") and the
#     probe demanded a `depends_on_id` column. bd split that column into
#     depends_on_issue_id / depends_on_wisp_id / depends_on_external (all 8
#     databases, tables wisp_dependencies AND dependencies), so EVERY database
#     was skipped before any step ran: no stale-wisp close, no purge, no nudge
#     expiry, no stale-issue close, no anomaly, no mail. The summary read
#     "purged:0" and looked healthy while hq.wisps grew to 23k rows (99% closed)
#     and every scan-shaped wisps read (session lookup by metadata, work probes)
#     slowed to 5-30 s. Now: the split schema is recognised, and a schema that
#     is NOT recognised is an anomaly + counted in the summary, never silent.
#  2. THE PURGE SQL. `NOT IN (subquery over a column that is NULL for issue
#     parents)` evaluates to NULL and matches nothing (the same trap after a
#     naive rename); rewritten NULL-safe (NOT EXISTS). Deletes are chunked by
#     primary key with a per-run cap and time budget (Dolt cuts a connection at
#     read_timeout_millis=30000), and they also remove the purged wisps' rows in
#     wisp_labels / wisp_comments / wisp_events / wisp_dependencies: only
#     wisp_dependencies has an FK cascade, so the old bare `DELETE FROM wisps`
#     left the children behind (measured 19/09: 1.06M of 1.14M wisp_labels rows
#     and 1.87M of 2.07M wisp_events rows are orphans).
#  3. Default purge age 48h (was 168h): the documented wisp-compact policy is a
#     24h TTL for closed wisps; 168h leaves ~17k rows, 48h ~4.5k. Adjustable
#     via GC_REAPER_PURGE_AGE. Closed MAIL wisps are never purged (ga-3rqwa).
#  4. The two steps that mutate PERMANENT issues (3: expire nudge beads, 4:
#     auto-close stale issues) stay OFF unless GC_REAPER_ISSUE_STEPS is set.
#     They have not run since the schema split; switching them back on is a
#     separate decision with its own dry-run numbers, not a side effect of a
#     wisps-performance fix. Their SQL is fixed for the new schema so enabling
#     them is safe; the summary says issue_steps:off|on.
#  5. Anomaly mail to the mayor is deduplicated (same anomaly text is not
#     re-sent within GC_REAPER_ANOMALY_MAIL_TTL_S, default 6h): the reaper runs
#     every 30 min on every rig.
set -euo pipefail

# Trace bd invocations to $GC_BD_TRACE when set (no-op otherwise).
__SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$__SCRIPT_DIR/_bd_trace.sh" "reaper"

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/dolt-target.sh"
CITY_ABS="$(cd "$CITY" 2>/dev/null && pwd -P || printf '%s\n' "$CITY")"
CITY_BEADS_DIR="$CITY_ABS/.beads"

# Configurable thresholds.
MAX_AGE="${GC_REAPER_MAX_AGE:-24h}"
PURGE_AGE="${GC_REAPER_PURGE_AGE:-48h}"   # ga-u8nbt9: was 168h (see the header note)
STALE_ISSUE_AGE="${GC_REAPER_STALE_ISSUE_AGE:-720h}"
SESSION_PURGE_AGE="${GC_REAPER_SESSION_PURGE_AGE:-720h}"
SESSION_STATE_PRUNE_AGE="${GC_REAPER_SESSION_STATE_PRUNE_AGE:-24h}"
ALERT_THRESHOLD="${GC_REAPER_ALERT_THRESHOLD:-500}"
MAIL_ALERT_THRESHOLD="${GC_REAPER_MAIL_ALERT_THRESHOLD:-0}"  # 0 = disabled
DRY_RUN="${GC_REAPER_DRY_RUN:-}"
# ga-u8nbt9: bounded purge. One candidate scan per run, then chunked deletes.
PURGE_BATCH="${GC_REAPER_PURGE_BATCH:-500}"            # wisps per DELETE chunk
PURGE_MAX_PER_RUN="${GC_REAPER_PURGE_MAX_PER_RUN:-5000}" # wisps per database per run
PURGE_BUDGET_S="${GC_REAPER_PURGE_BUDGET_S:-240}"      # wall-clock budget for all chunks
ISSUE_STEPS="${GC_REAPER_ISSUE_STEPS:-}"               # empty = steps 3/4 OFF (see header)
ANOMALY_MAIL_TTL_S="${GC_REAPER_ANOMALY_MAIL_TTL_S:-21600}"

# Convert Go durations to SQL INTERVAL hours for Dolt.
duration_to_hours() {
    local dur="$1"
    # Strip trailing 'h' and return as integer.
    echo "${dur%h}"
}

MAX_AGE_H=$(duration_to_hours "$MAX_AGE")
PURGE_AGE_H=$(duration_to_hours "$PURGE_AGE")
STALE_AGE_H=$(duration_to_hours "$STALE_ISSUE_AGE")

CITY_DB_METADATA_RESULT=""

city_database_name() {
    local metadata="$CITY_BEADS_DIR/metadata.json"
    local db=""
    CITY_DB_METADATA_RESULT=""

    if [ -f "$metadata" ]; then
        if command -v jq >/dev/null 2>&1; then
            if ! db=$(jq -er '.dolt_database // empty | strings' "$metadata" 2>/dev/null); then
                return 0
            fi
        elif command -v python3 >/dev/null 2>&1; then
            if ! db=$(python3 - "$metadata" 2>/dev/null <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as f:
    value = json.load(f).get("dolt_database", "")
if isinstance(value, str) and value:
    print(value)
PY
            ); then
                return 0
            fi
        elif command -v grep >/dev/null 2>&1 && command -v sed >/dev/null 2>&1 && command -v head >/dev/null 2>&1; then
            if grep -q '}' "$metadata" 2>/dev/null; then
                db=$(grep -o '"dolt_database"[[:space:]]*:[[:space:]]*"[^"]*"' "$metadata" 2>/dev/null \
                    | sed 's/.*"dolt_database"[[:space:]]*:[[:space:]]*"//;s/"//' \
                    | head -1 || true)
            fi
        else
            return 0
        fi
    fi

    if [ -n "$db" ]; then
        CITY_DB_METADATA_RESULT="$db"
    fi
}

is_user_database() {
    case "$1" in
        information_schema|mysql|dolt_cluster|performance_schema|sys|__gc_probe|benchdb|testdb_*|beads_pt*|beads_vr*|beads_test_bench_*|doctest_*|doctortest_*)
            return 1
            ;;
        beads_t*)
            local suffix="${1#beads_t}"
            if [[ "$suffix" =~ ^[0-9a-f]{8,}$ ]]; then
                return 1
            fi
            return 0
            ;;
        *)
            return 0
            ;;
    esac
}

# Discover databases from Dolt server. Exclude Dolt/MySQL system schemas,
# Gas City's internal health-probe database, and test-fixture scratch
# databases (benchdb, testdb_*, lowercase beads_t[0-9a-f]{8,}, beads_pt*,
# beads_vr*, beads_test_bench_*, doctest_*, doctortest_* — matching the Go
# cleanup planner contract); the remainder are bead stores.
DATABASES=$(
    while IFS= read -r db; do
        if is_user_database "$db"; then
            printf '%s\n' "$db"
        fi
    done < <(dolt_sql -r csv -q "SHOW DATABASES" 2>/dev/null | tail -n +2)
)
HAD_DATABASES=1
if [ -z "$DATABASES" ]; then
    # The Dolt-backed cleanup loop has no work, but the session-bead
    # prune below still operates through bd's configured task store.
    HAD_DATABASES=0
fi

TOTAL_STALE_WISPS=0
TOTAL_CLOSED_WISPS=0
TOTAL_WOULD_CLOSE_WISPS=0
TOTAL_WOULD_EXPIRE=0
TOTAL_PURGED=0
TOTAL_MAIL_WISPS=0
TOTAL_ISSUES_CLOSED=0
TOTAL_STALE_ISSUES_SKIPPED=0
TOTAL_EXPIRED_ISSUES_CLOSED=0
TOTAL_EXPIRED_ISSUES_SKIPPED=0
TOTAL_SESSIONS_PRUNED=0
SESSION_PRUNE_ATTEMPTED=0
# ga-u8nbt9 counters — every one of them reaches the summary, so a run that did
# nothing for a REASON (unrecognised schema, capped by budget) is distinguishable
# from a run that had nothing to do.
SCHEMA_SKIPPED_DBS=0
TOTAL_WOULD_PURGE=0
PURGE_BATCHES=0
PURGE_CAPPED_DBS=0
PURGE_START_EPOCH=$(date +%s)
ANOMALIES=""

sanitize_output() {
    printf '%s' "$1" | tr '\n' ' ' | cut -c1-4000
}

record_anomaly() {
    local db="$1"
    shift
    ANOMALIES="${ANOMALIES}$db: $*
"
}

CITY_DB_ANOMALY_RECORDED=0

# ga-u8nbt9: these values are interpolated into SQL and loop bounds. A malformed
# override (GC_REAPER_PURGE_AGE=2d, an empty string, ...) must not reach the SQL
# as a syntax error that then reads as "purged:0": fall back to the default AND
# record an anomaly saying so.
validate_num() {  # validate_num <variable-name> <default> [<min>]
    local name="$1" def="$2" min="${3:-0}" val
    val="${!name}"
    case "$val" in
        ''|*[!0-9]*)
            record_anomaly "config" "$name='$val' is not a non-negative integer; using the default $def"
            printf -v "$name" '%s' "$def"
            return 0
            ;;
    esac
    if [ "$val" -lt "$min" ]; then
        record_anomaly "config" "$name=$val is below the minimum $min; using the default $def"
        printf -v "$name" '%s' "$def"
    fi
    return 0
}
validate_num MAX_AGE_H 24 1
validate_num PURGE_AGE_H 48 1
validate_num STALE_AGE_H 720 1
validate_num PURGE_BATCH 500 1
validate_num PURGE_MAX_PER_RUN 5000 1
validate_num PURGE_BUDGET_S 240 1
validate_num ANOMALY_MAIL_TTL_S 21600 0

# ga-u8nbt9: `SHOW DATABASES` failing (Dolt down, connection cut at the 30 s read
# timeout) leaves DATABASES empty, which the loop below reads as "no work" and the
# summary reports as a clean run. Say so.
if [ "$HAD_DATABASES" -eq 0 ]; then
    record_anomaly "dolt" "SHOW DATABASES returned no bead-store database (query failed or the server has none); the reaper had nothing to scan"
fi

valid_database_identifier() {
    local name="$1"

    case "$name" in
        ''|-*|*[!A-Za-z0-9_-]*)
            return 1
            ;;
    esac

    return 0
}

database_list_contains() {
    local needle="$1"
    local db

    while IFS= read -r db; do
        if [ "$db" = "$needle" ]; then
            return 0
        fi
    done <<EOF
$DATABASES
EOF

    return 1
}

CITY_DB=""
CITY_DB_SOURCE="$CITY_BEADS_DIR/metadata.json"
city_database_name
CITY_METADATA_DB="$CITY_DB_METADATA_RESULT"

if [ -n "${GC_REAPER_CITY_DATABASE:-}" ]; then
    CITY_DB_SOURCE="GC_REAPER_CITY_DATABASE"
    if [ -z "$CITY_METADATA_DB" ]; then
        record_anomaly "city" "city database $GC_REAPER_CITY_DATABASE from GC_REAPER_CITY_DATABASE could not be verified against $CITY_BEADS_DIR/metadata.json; stale issue auto-close disabled"
        CITY_DB_ANOMALY_RECORDED=1
    elif [ "$GC_REAPER_CITY_DATABASE" != "$CITY_METADATA_DB" ]; then
        record_anomaly "city" "city database $GC_REAPER_CITY_DATABASE from GC_REAPER_CITY_DATABASE does not match city metadata database $CITY_METADATA_DB; stale issue auto-close disabled"
        CITY_DB_ANOMALY_RECORDED=1
    else
        CITY_DB="$GC_REAPER_CITY_DATABASE"
    fi
else
    CITY_DB="$CITY_METADATA_DB"
fi

if [ -n "$CITY_DB" ] && ! valid_database_identifier "$CITY_DB"; then
    record_anomaly "city" "city database $CITY_DB from $CITY_DB_SOURCE is not a safe Dolt identifier; stale issue auto-close disabled"
    CITY_DB=""
    CITY_DB_ANOMALY_RECORDED=1
elif [ -n "$CITY_DB" ] && ! database_list_contains "$CITY_DB"; then
    record_anomaly "city" "city database $CITY_DB from $CITY_DB_SOURCE was not found in discovered databases; stale issue auto-close disabled"
    CITY_DB=""
    CITY_DB_ANOMALY_RECORDED=1
fi

SQL_COUNT_RESULT=0
get_sql_count() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local stderr_file
    local stderr_output
    local count

    SQL_COUNT_RESULT=0
    if ! stderr_file=$(mktemp); then
        record_anomaly "$db" "$label count failed for $db: could not create stderr capture file"
        return 0
    fi
    if ! output=$(dolt_sql -r csv -q "$query" 2>"$stderr_file"); then
        stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
        rm -f "$stderr_file"
        record_anomaly "$db" "$label count failed for $db: $(sanitize_output "$stderr_output $output")"
        return 0
    fi
    rm -f "$stderr_file"

    count=$(printf '%s\n' "$output" | tail -1 | tr -d '\r')
    if [ -z "$count" ] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
        record_anomaly "$db" "$label count returned non-numeric value for $db: $(sanitize_output "$output")"
        return 0
    fi

    SQL_COUNT_RESULT="$count"
}

SQL_ROWS_RESULT=""
get_sql_rows() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local stderr_file
    local stderr_output

    SQL_ROWS_RESULT=""
    if ! stderr_file=$(mktemp); then
        record_anomaly "$db" "$label query failed for $db: could not create stderr capture file"
        return 0
    fi
    if ! output=$(dolt_sql -r csv -q "$query" 2>"$stderr_file"); then
        stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
        rm -f "$stderr_file"
        record_anomaly "$db" "$label query failed for $db: $(sanitize_output "$stderr_output $output")"
        return 0
    fi
    rm -f "$stderr_file"

    SQL_ROWS_RESULT=$(printf '%s\n' "$output" | tail -n +2 | tr -d '\r')
}

# ga-u8nbt9: which dependency-edge schema does <db>.<table> have?
#   split  — depends_on_issue_id (+ depends_on_wisp_id / depends_on_external):
#            the current bd schema, in BOTH dependencies and wisp_dependencies.
#   legacy — the single depends_on_id column the embedded script was written for.
# Sets DEP_FLAVOR and the two target-column names below (the wisp target is the
# column that holds a PARENT wisp id, the issue target the one that holds a
# parent ISSUE id). Returns 1 when the table cannot be probed or matches
# neither shape: the caller must treat that as an ANOMALY, never as "nothing to
# do". The embedded version returned 0 on an empty/failed field list and 1 for
# the split schema, and its caller did `|| continue` silently.
DEP_FLAVOR=""
DEP_WISP_TARGET_COL=""
DEP_ISSUE_TARGET_COL=""
probe_dependency_table() {
    local db="$1"
    local table="$2"
    local output
    local fields

    DEP_FLAVOR="unknown"
    DEP_WISP_TARGET_COL=""
    DEP_ISSUE_TARGET_COL=""

    if ! output=$(dolt_sql -r csv -q "SHOW COLUMNS FROM \`$db\`.$table" 2>/dev/null); then
        return 1
    fi

    fields=$(printf '%s\n' "$output" | tail -n +2 | cut -d, -f1 | tr -d '\r')
    printf '%s\n' "$fields" | grep -qx 'issue_id' || return 1

    if printf '%s\n' "$fields" | grep -qx 'depends_on_issue_id'; then
        DEP_FLAVOR="split"
        DEP_ISSUE_TARGET_COL="depends_on_issue_id"
        if printf '%s\n' "$fields" | grep -qx 'depends_on_wisp_id'; then
            DEP_WISP_TARGET_COL="depends_on_wisp_id"
        fi
        return 0
    fi
    if printf '%s\n' "$fields" | grep -qx 'depends_on_id'; then
        DEP_FLAVOR="legacy"
        DEP_ISSUE_TARGET_COL="depends_on_id"
        DEP_WISP_TARGET_COL="depends_on_id"
        return 0
    fi
    return 1
}

SQL_CHANGE_ROWS_RESULT=0
close_city_issue() {
    local issue_id="$1"
    local reason="$2"

    if [ ! -d "$CITY_BEADS_DIR" ]; then
        printf 'city bead store %s is unavailable' "$CITY_BEADS_DIR"
        return 1
    fi

    (
        cd "$CITY_ABS"
        BEADS_DIR="$CITY_BEADS_DIR" bd close "$issue_id" --reason "$reason"
    )
}

run_sql_change() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local rows
    local stderr_file
    local stderr_output

    SQL_CHANGE_ROWS_RESULT=0
    if ! stderr_file=$(mktemp); then
        record_anomaly "$db" "$label failed for $db: could not create stderr capture file"
        return 1
    fi
    # DML (DELETE/UPDATE) against a database-qualified table still needs an
    # active database selected, or Dolt can reject it with "no database
    # selected" (Error 1105) even though the target is fully qualified —
    # reads (get_sql_count/get_sql_rows) do not. USE the target db first,
    # mirroring the DOLT_COMMIT block below.
    if ! output=$(dolt_sql -r csv -q "
USE \`$db\`;
$query;
SELECT ROW_COUNT();
    " 2>"$stderr_file"); then
        stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
        rm -f "$stderr_file"
        record_anomaly "$db" "$label failed for $db: $(sanitize_output "$stderr_output $output")"
        return 1
    fi
    stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
    rm -f "$stderr_file"

    rows=$(printf '%s\n' "$output" | tail -1 | tr -d '\r')
    if [ -z "$rows" ] || ! [[ "$rows" =~ ^[0-9]+$ ]]; then
        record_anomaly "$db" "$label returned non-numeric row count for $db: $(sanitize_output "$stderr_output $output")"
        return 1
    fi

    SQL_CHANGE_ROWS_RESULT="$rows"
    return 0
}

# ga-u8nbt9: purge closed wisps older than PURGE_AGE_H hours.
#  * Candidates: closed; NOT mail (ga-3rqwa: closed mail is the only durable
#    record of who wrote what, and it is never hard-deleted here); older than the
#    cutoff by closed_at (updated_at when closed_at is NULL, so a closed row with
#    no closed_at is not immortal); and NOT the parent of a wisp that is still
#    active. The parent test is NOT EXISTS, never NOT IN: NOT IN over a target
#    column that is NULL for issue-parents evaluates to NULL and matches nothing,
#    which is exactly how a naive column rename would still report "purged:0".
#  * One candidate scan per run (oldest first, capped at PURGE_MAX_PER_RUN), then
#    chunked deletes by primary key, so no statement approaches Dolt's 30 s
#    read timeout; the loop stops when the PURGE_BUDGET_S budget is spent and the
#    summary says the database was capped (work remains for the next run).
#  * Children first (labels, comments, events, dependency edges), the wisps row
#    LAST. A failure in between leaves a wisp that is still a candidate next run,
#    never an orphaned child. Only wisp_dependencies has an FK cascade.
purge_candidate_sql() {  # purge_candidate_sql <db> <select-list> [<tail>]
    local db="$1"
    local select_list="$2"
    local tail_sql="${3:-}"

    printf '%s' "
        SELECT $select_list FROM \`$db\`.wisps w
        WHERE w.status = 'closed'
        AND (w.issue_type IS NULL OR w.issue_type <> 'message')
        AND COALESCE(w.closed_at, w.updated_at) < DATE_SUB(NOW(), INTERVAL $PURGE_AGE_H HOUR)
        AND NOT EXISTS (
            SELECT 1 FROM \`$db\`.wisp_dependencies d
            INNER JOIN \`$db\`.wisps child_wisp ON child_wisp.id = d.issue_id
            WHERE d.type = 'parent-child'
            AND d.$WISP_DEP_WISP_COL = w.id
            AND child_wisp.status IN ('open', 'hooked', 'in_progress')
        )
        $tail_sql
    "
}

purge_chunk() {  # purge_chunk <db> <quoted-id-list>; returns 1 when the SQL failed
    local db="$1"
    local list="$2"

    if run_sql_change "$db" "purging closed wisps" "
        DELETE FROM \`$db\`.wisp_labels WHERE issue_id IN ($list);
        DELETE FROM \`$db\`.wisp_comments WHERE issue_id IN ($list);
        DELETE FROM \`$db\`.wisp_events WHERE issue_id IN ($list);
        DELETE FROM \`$db\`.wisp_dependencies WHERE issue_id IN ($list);
        DELETE FROM \`$db\`.wisps WHERE id IN ($list)
    "; then
        DB_PURGED=$((DB_PURGED + SQL_CHANGE_ROWS_RESULT))
        TOTAL_PURGED=$((TOTAL_PURGED + SQL_CHANGE_ROWS_RESULT))
        DB_MUTATIONS=$((DB_MUTATIONS + SQL_CHANGE_ROWS_RESULT))
        PURGE_BATCHES=$((PURGE_BATCHES + 1))
        return 0
    fi
    return 1
}

purge_closed_wisps() {  # purge_closed_wisps <db>
    local db="$1"
    local ids
    local total_ids
    local offset=1
    local chunk
    local id
    local list
    local bad=0
    local capped=0
    local elapsed

    if [ -n "$DRY_RUN" ]; then
        get_sql_count "$db" "closed wisp purge (dry run)" "$(purge_candidate_sql "$db" 'COUNT(*)')"
        TOTAL_WOULD_PURGE=$((TOTAL_WOULD_PURGE + SQL_COUNT_RESULT))
        return 0
    fi

    # Budget already spent by an earlier database: do NOT pay for a candidate scan
    # (a full pass over wisps) just to break out of the loop below. Count the
    # database as capped so the summary still says work remains.
    elapsed=$(( $(date +%s) - PURGE_START_EPOCH ))
    if [ "$elapsed" -ge "$PURGE_BUDGET_S" ]; then
        PURGE_CAPPED_DBS=$((PURGE_CAPPED_DBS + 1))
        return 0
    fi

    get_sql_rows "$db" "closed wisp purge candidates" \
        "$(purge_candidate_sql "$db" 'w.id' "ORDER BY COALESCE(w.closed_at, w.updated_at) ASC LIMIT $PURGE_MAX_PER_RUN")"
    ids=$(printf '%s\n' "$SQL_ROWS_RESULT" | sed '/^[[:space:]]*$/d')
    [ -n "$ids" ] || return 0
    total_ids=$(printf '%s\n' "$ids" | wc -l | tr -d ' ')
    if [ "$total_ids" -ge "$PURGE_MAX_PER_RUN" ]; then
        capped=1
    fi

    while [ "$offset" -le "$total_ids" ]; do
        elapsed=$(( $(date +%s) - PURGE_START_EPOCH ))
        if [ "$elapsed" -ge "$PURGE_BUDGET_S" ]; then
            capped=1
            break
        fi
        chunk=$(printf '%s\n' "$ids" | sed -n "${offset},$((offset + PURGE_BATCH - 1))p")
        offset=$((offset + PURGE_BATCH))

        list=""
        while IFS= read -r id; do
            [ -n "$id" ] || continue
            # ids are interpolated into SQL: accept only the alphabet bd generates.
            if ! [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
                bad=$((bad + 1))
                continue
            fi
            list="${list:+$list,}'$id'"
        done <<< "$chunk"
        [ -n "$list" ] || continue

        if ! purge_chunk "$db" "$list"; then
            capped=1   # the SQL failure is already an anomaly; work remains
            break
        fi
    done

    if [ "$bad" -gt 0 ]; then
        record_anomaly "$db" "$bad closed wisp id(s) with unexpected characters were NOT purged"
    fi
    if [ "$capped" -eq 1 ]; then
        PURGE_CAPPED_DBS=$((PURGE_CAPPED_DBS + 1))
    fi
    return 0
}

while IFS= read -r DB; do
    [ -z "$DB" ] && continue
    if ! valid_database_identifier "$DB"; then
        record_anomaly "$DB" "unsafe Dolt database identifier skipped by reaper"
        continue
    fi
    if ! has_wisps_table "$DB"; then
        # Not a bd-managed bead store. Skip silently; recording an
        # anomaly here would just turn every schemaless DB on the
        # server into noise. See gastownhall/gascity#1816.
        continue
    fi
    # ga-u8nbt9: this gate used to be `... || continue` with the comment "skip
    # silently". Once bd split depends_on_id it skipped EVERY database and
    # nothing anywhere said so. An unrecognised schema is now an anomaly AND a
    # counter in the summary. The database is still skipped (we cannot write SQL
    # against a shape we do not know), but never quietly.
    if ! probe_dependency_table "$DB" "wisp_dependencies" || [ -z "$DEP_WISP_TARGET_COL" ]; then
        record_anomaly "$DB" "wisp_dependencies has an unrecognised schema (want issue_id + depends_on_issue_id/depends_on_wisp_id, or the legacy depends_on_id); the reaper SKIPPED this database"
        SCHEMA_SKIPPED_DBS=$((SCHEMA_SKIPPED_DBS + 1))
        continue
    fi
    WISP_DEP_WISP_COL="$DEP_WISP_TARGET_COL"
    WISP_DEP_ISSUE_COL="$DEP_ISSUE_TARGET_COL"
    ISSUE_DEP_TARGET_COL=""
    ISSUE_STEPS_DB=""
    if [ -n "$ISSUE_STEPS" ]; then
        if probe_dependency_table "$DB" "dependencies"; then
            ISSUE_DEP_TARGET_COL="$DEP_ISSUE_TARGET_COL"
            ISSUE_STEPS_DB=1
        else
            record_anomaly "$DB" "dependencies has an unrecognised schema; issue steps (nudge expiry, stale-issue close) are disabled for this database"
        fi
    fi

    DB_MUTATIONS=0

    # Step 1: Count stale non-closed wisps, then close only candidates whose
    # explicit parent-child edge points to a closed parent. Wisps
    # without a parent edge are reported but not closed by age alone.
    get_sql_count "$DB" "stale non-closed wisp" "
        SELECT COUNT(*) FROM \`$DB\`.wisps
        WHERE status IN ('open', 'hooked', 'in_progress')
        AND created_at < DATE_SUB(NOW(), INTERVAL $MAX_AGE_H HOUR)
    "
    STALE_WISP_COUNT=$SQL_COUNT_RESULT

    if [ "$STALE_WISP_COUNT" -gt 0 ]; then
        TOTAL_STALE_WISPS=$((TOTAL_STALE_WISPS + STALE_WISP_COUNT))
    fi

    CLOSE_WISP_COUNT=0
    DB_CLOSED_WISPS=0
    DB_PURGED=0
    while [ "$STALE_WISP_COUNT" -gt 0 ] && [ "$CLOSE_WISP_COUNT" -lt "$STALE_WISP_COUNT" ]; do
        get_sql_count "$DB" "schema-safe stale wisp" "
            SELECT COUNT(DISTINCT w.id) FROM \`$DB\`.wisps w
            INNER JOIN \`$DB\`.wisp_dependencies d
                ON d.issue_id = w.id
                AND d.type = 'parent-child'
            LEFT JOIN \`$DB\`.wisps parent_wisp ON d.$WISP_DEP_WISP_COL = parent_wisp.id
            LEFT JOIN \`$DB\`.issues parent_issue ON d.$WISP_DEP_ISSUE_COL = parent_issue.id
            WHERE w.status IN ('open', 'hooked', 'in_progress')
            AND w.created_at < DATE_SUB(NOW(), INTERVAL $MAX_AGE_H HOUR)
            AND (
                parent_wisp.status = 'closed'
                OR parent_issue.status = 'closed'
            )
        "
        CLOSE_WISP_BATCH=$SQL_COUNT_RESULT
        if [ "$CLOSE_WISP_BATCH" -eq 0 ]; then
            break
        fi
        if [ -n "$DRY_RUN" ]; then
            TOTAL_WOULD_CLOSE_WISPS=$((TOTAL_WOULD_CLOSE_WISPS + CLOSE_WISP_BATCH))
            break
        fi

        if run_sql_change "$DB" "closing stale wisps" "
            UPDATE \`$DB\`.wisps SET status='closed', closed_at=NOW()
            WHERE status IN ('open', 'hooked', 'in_progress')
            AND created_at < DATE_SUB(NOW(), INTERVAL $MAX_AGE_H HOUR)
            AND id IN (
                SELECT id FROM (
                    SELECT w.id FROM \`$DB\`.wisps w
                    INNER JOIN \`$DB\`.wisp_dependencies d
                        ON d.issue_id = w.id
                        AND d.type = 'parent-child'
                    LEFT JOIN \`$DB\`.wisps parent_wisp ON d.$WISP_DEP_WISP_COL = parent_wisp.id
                    LEFT JOIN \`$DB\`.issues parent_issue ON d.$WISP_DEP_ISSUE_COL = parent_issue.id
                    WHERE w.status IN ('open', 'hooked', 'in_progress')
                    AND w.created_at < DATE_SUB(NOW(), INTERVAL $MAX_AGE_H HOUR)
                    AND (
                        parent_wisp.status = 'closed'
                        OR parent_issue.status = 'closed'
                    )
                ) reaper_wisp_candidates
            )
        "; then
            CLOSE_WISP_ROWS=$SQL_CHANGE_ROWS_RESULT
            if [ "$CLOSE_WISP_ROWS" -eq 0 ]; then
                break
            fi
            CLOSE_WISP_COUNT=$((CLOSE_WISP_COUNT + CLOSE_WISP_ROWS))
            DB_CLOSED_WISPS=$((DB_CLOSED_WISPS + CLOSE_WISP_ROWS))
            TOTAL_CLOSED_WISPS=$((TOTAL_CLOSED_WISPS + CLOSE_WISP_ROWS))
            DB_MUTATIONS=$((DB_MUTATIONS + CLOSE_WISP_ROWS))
        else
            break
        fi
    done

    # Step 2: Purge — delete closed wisps past purge_age (ga-u8nbt9: rewritten,
    # see purge_closed_wisps above: NULL-safe, mail-safe, chunked, children too).
    purge_closed_wisps "$DB"

    # ga-u8nbt9: steps 3 and 4 mutate PERMANENT issues and have not run since the
    # schema split (see the header note). They stay OFF unless GC_REAPER_ISSUE_STEPS
    # is set, and the summary says issue_steps:off|on. The counters are set here
    # because the Dolt commit message below reads them under `set -u`.
    DB_EXPIRED_ISSUES_CLOSED=0
    DB_ISSUES_CLOSED=0
    if [ -n "$ISSUE_STEPS_DB" ]; then

    # Step 3: Close nudge beads whose metadata.expires_at is in the past.
    # Only beads labelled gc:nudge are candidates — other bead types that stamp
    # expires_at (e.g. gc:extmsg-binding session bindings) must not be closed
    # here.  The COALESCE handles whole-second RFC3339+Z, microsecond-width
    # RFC3339 (MySQL %f tops out at 6 fractional digits), and full
    # RFC3339Nano (7-9 fractional digits) by truncating the fractional part to
    # whole seconds for parsing — sub-second precision is immaterial for TTL
    # expiry.  Rows where every pattern fails STR_TO_DATE return NULL and are
    # recorded as anomalies rather than silently skipped.
    DB_EXPIRED_ISSUES_CLOSED=0
    get_sql_rows "$DB" "expired nudge bead with parse anomaly" "
        SELECT i.id
        FROM \`$DB\`.issues i
        INNER JOIN \`$DB\`.labels lbl ON lbl.issue_id = i.id AND lbl.label = 'gc:nudge'
        WHERE i.status IN ('open', 'in_progress')
        AND JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')) IS NOT NULL
        AND JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')) != ''
        AND COALESCE(
            STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '%Y-%m-%dT%H:%i:%s.%fZ'),
            STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '%Y-%m-%dT%H:%i:%sZ'),
            STR_TO_DATE(CONCAT(SUBSTRING_INDEX(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '.', 1), 'Z'), '%Y-%m-%dT%H:%i:%sZ')
        ) IS NULL
    "
    if [ -n "$SQL_ROWS_RESULT" ]; then
        while IFS= read -r bad_id; do
            [ -z "$bad_id" ] && continue
            record_anomaly "$DB" "nudge bead $bad_id in $DB has unparseable expires_at; skipped by TTL reaper"
        done <<< "$SQL_ROWS_RESULT"
    fi

    get_sql_rows "$DB" "expired nudge bead" "
        SELECT i.id
        FROM \`$DB\`.issues i
        INNER JOIN \`$DB\`.labels lbl ON lbl.issue_id = i.id AND lbl.label = 'gc:nudge'
        WHERE i.status IN ('open', 'in_progress')
        AND JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')) IS NOT NULL
        AND JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')) != ''
        AND COALESCE(
            STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '%Y-%m-%dT%H:%i:%s.%fZ'),
            STR_TO_DATE(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '%Y-%m-%dT%H:%i:%sZ'),
            STR_TO_DATE(CONCAT(SUBSTRING_INDEX(JSON_UNQUOTE(JSON_EXTRACT(i.metadata, '$.expires_at')), '.', 1), 'Z'), '%Y-%m-%dT%H:%i:%sZ')
        ) < UTC_TIMESTAMP()
    "
    EXPIRED_IDS=$SQL_ROWS_RESULT
    if [ -n "$EXPIRED_IDS" ]; then
        WOULD_EXPIRE_COUNT=$(printf '%s\n' "$EXPIRED_IDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
        TOTAL_WOULD_EXPIRE=$((TOTAL_WOULD_EXPIRE + WOULD_EXPIRE_COUNT))
    fi

    if [ -n "$EXPIRED_IDS" ] && [ -z "$DRY_RUN" ]; then
        if [ -z "$CITY_DB" ]; then
            if [ "$CITY_DB_ANOMALY_RECORDED" -eq 0 ]; then
                record_anomaly "city" "city database could not be determined from GC_REAPER_CITY_DATABASE or $CITY/.beads/metadata.json; expired nudge close disabled"
                CITY_DB_ANOMALY_RECORDED=1
            fi
            SKIPPED_COUNT=$(printf '%s\n' "$EXPIRED_IDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
            TOTAL_EXPIRED_ISSUES_SKIPPED=$((TOTAL_EXPIRED_ISSUES_SKIPPED + SKIPPED_COUNT))
        elif [ "$DB" != "$CITY_DB" ]; then
            SKIPPED_COUNT=$(printf '%s\n' "$EXPIRED_IDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
            TOTAL_EXPIRED_ISSUES_SKIPPED=$((TOTAL_EXPIRED_ISSUES_SKIPPED + SKIPPED_COUNT))
        else
            while IFS= read -r issue_id; do
                [ -z "$issue_id" ] && continue
                if CLOSE_OUTPUT=$(close_city_issue "$issue_id" "ttl:expired by reaper" 2>&1); then
                    DB_EXPIRED_ISSUES_CLOSED=$((DB_EXPIRED_ISSUES_CLOSED + 1))
                    TOTAL_EXPIRED_ISSUES_CLOSED=$((TOTAL_EXPIRED_ISSUES_CLOSED + 1))
                    DB_MUTATIONS=$((DB_MUTATIONS + 1))
                else
                    record_anomaly "$DB" "closing expired nudge bead $issue_id failed for $DB: $(sanitize_output "$CLOSE_OUTPUT")"
                fi
            done <<< "$EXPIRED_IDS"
        fi
    fi

    # Step 4: Auto-close stale issues (exclude P0/P1, epics, active deps).
    # ga-u8nbt9: WORK ITEMS ONLY. The embedded script excluded just 'epic'. A dry run
    # on 19/09 showed 13 of the 16 would-be closes were type 'agent' (crew / witness /
    # refinery IDENTITY beads, updated_at 06-18): closing one deregisters a live
    # agent. The issue_type list below is the same non-work-item set bd ready itself
    # excludes. (Kept out of the SQL string on purpose: no prose in a query.)
    DB_ISSUES_CLOSED=0
    get_sql_rows "$DB" "stale issue" "
        SELECT id FROM \`$DB\`.issues
        WHERE status IN ('open', 'in_progress')
        AND updated_at < DATE_SUB(NOW(), INTERVAL $STALE_AGE_H HOUR)
        AND priority > 1
        AND issue_type NOT IN ('merge-request', 'gate', 'molecule', 'rig', 'agent', 'role', 'message', 'epic')
        AND (
            JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.expires_at')) IS NULL
            OR JSON_UNQUOTE(JSON_EXTRACT(metadata, '$.expires_at')) = ''
        )
        AND id NOT IN (
            SELECT DISTINCT d.issue_id FROM \`$DB\`.dependencies d
            INNER JOIN \`$DB\`.issues i ON d.$ISSUE_DEP_TARGET_COL = i.id
            WHERE i.status IN ('open', 'in_progress')
            UNION
            SELECT DISTINCT d.$ISSUE_DEP_TARGET_COL FROM \`$DB\`.dependencies d
            INNER JOIN \`$DB\`.issues i ON d.issue_id = i.id
            WHERE i.status IN ('open', 'in_progress')
            AND d.$ISSUE_DEP_TARGET_COL IS NOT NULL
        )
    "
    STALE_IDS=$SQL_ROWS_RESULT

    if [ -n "$STALE_IDS" ] && [ -z "$DRY_RUN" ]; then
        if [ -z "$CITY_DB" ]; then
            if [ "$CITY_DB_ANOMALY_RECORDED" -eq 0 ]; then
                record_anomaly "city" "city database could not be determined from GC_REAPER_CITY_DATABASE or $CITY/.beads/metadata.json; stale issue auto-close disabled"
                CITY_DB_ANOMALY_RECORDED=1
            fi
            SKIPPED_ISSUES=$(printf '%s\n' "$STALE_IDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
            TOTAL_STALE_ISSUES_SKIPPED=$((TOTAL_STALE_ISSUES_SKIPPED + SKIPPED_ISSUES))
        elif [ "$DB" != "$CITY_DB" ]; then
            SKIPPED_ISSUES=$(printf '%s\n' "$STALE_IDS" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
            TOTAL_STALE_ISSUES_SKIPPED=$((TOTAL_STALE_ISSUES_SKIPPED + SKIPPED_ISSUES))
        else
            while IFS= read -r issue_id; do
                [ -z "$issue_id" ] && continue
                if CLOSE_OUTPUT=$(close_city_issue "$issue_id" "stale:auto-closed by reaper" 2>&1); then
                    DB_ISSUES_CLOSED=$((DB_ISSUES_CLOSED + 1))
                    TOTAL_ISSUES_CLOSED=$((TOTAL_ISSUES_CLOSED + 1))
                    DB_MUTATIONS=$((DB_MUTATIONS + 1))
                else
                    record_anomaly "$DB" "closing stale issue $issue_id failed for $DB: $(sanitize_output "$CLOSE_OUTPUT")"
                fi
            done <<< "$STALE_IDS"
        fi
    fi

    fi  # ga-u8nbt9: end of the issue-mutating steps (3 and 4)

    # Step 5a: Anomaly check — stale open wisp count. Fresh workflow load can
    # legitimately exceed the threshold on busy cities; only old non-message
    # rows indicate a reaper leak.
    get_sql_count "$DB" "stale open wisp anomaly" "
        SELECT COUNT(*) FROM \`$DB\`.wisps
        WHERE status IN ('open', 'hooked', 'in_progress')
        AND issue_type NOT IN ('message')
        AND created_at < DATE_SUB(NOW(), INTERVAL $MAX_AGE_H HOUR)
    "
    REAPABLE_WISPS=$SQL_COUNT_RESULT

    if [ "$REAPABLE_WISPS" -gt "$ALERT_THRESHOLD" ]; then
        ANOMALIES="${ANOMALIES}$DB: $REAPABLE_WISPS stale open wisps (threshold: $ALERT_THRESHOLD, age: ${MAX_AGE})\n"
    fi

    # Step 5b: Mail-wisp backlog count, observed separately from reapable wisps.
    get_sql_count "$DB" "open mail wisp" "
        SELECT COUNT(*) FROM \`$DB\`.wisps
        WHERE status IN ('open', 'hooked', 'in_progress')
        AND issue_type = 'message'
    "
    MAIL_WISPS=$SQL_COUNT_RESULT
    TOTAL_MAIL_WISPS=$((TOTAL_MAIL_WISPS + MAIL_WISPS))

    if [ "$MAIL_ALERT_THRESHOLD" -gt 0 ] && [ "$MAIL_WISPS" -gt "$MAIL_ALERT_THRESHOLD" ]; then
        ANOMALIES="${ANOMALIES}$DB: $MAIL_WISPS open mail-wisps (mail threshold: $MAIL_ALERT_THRESHOLD)\n"
    fi

    # Commit Dolt changes. Must use CALL (not SELECT) and have an active
    # database via USE so CALL DOLT_COMMIT(...) runs in the target database.
    # Commit failures are surfaced as anomalies so the dog loop does not
    # silently retry forever.
    if [ -z "$DRY_RUN" ] && [ "$DB_MUTATIONS" -gt 0 ]; then
        if ! COMMIT_OUTPUT=$(dolt_sql -q "
            USE \`$DB\`;
            CALL DOLT_COMMIT('-Am', 'reaper: stale_wisps=$STALE_WISP_COUNT closed_wisps=$DB_CLOSED_WISPS purged=$DB_PURGED stale_issues=$DB_ISSUES_CLOSED expired_issues=$DB_EXPIRED_ISSUES_CLOSED', '--author', 'reaper <reaper@gastown.local>')
        " 2>&1); then
            case "$COMMIT_OUTPUT" in
                *"nothing to commit"*|*"Nothing to commit"*)
                    :
                    ;;
                *)
                    record_anomaly "$DB" "Dolt commit failed for $DB: $(sanitize_output "$COMMIT_OUTPUT")"
                    ;;
            esac
        fi
    fi
done <<EOF
$DATABASES
EOF

# Step 6: prune closed gm session beads from the city's primary bead store.
if [ -d "$CITY_BEADS_DIR" ] && command -v bd >/dev/null 2>&1; then
    SESSION_PRUNE_ATTEMPTED=1
    BD_PRUNE_ARGS=(prune --pattern 'gm-*' --older-than "$SESSION_PURGE_AGE")
    if [ -z "$DRY_RUN" ]; then
        BD_PRUNE_ARGS+=(--force)
    fi
    BD_PRUNE_ARGS+=(--json)

    if PRUNE_JSON=$((
        cd "$CITY_ABS" && BEADS_DIR="$CITY_BEADS_DIR" bd "${BD_PRUNE_ARGS[@]}"
    ) 2>/dev/null); then
        :
    else
        PRUNE_JSON='{"pruned_count":0}'
    fi
    PRUNE_COUNT=$(printf '%s' "$PRUNE_JSON" | sed -n 's/.*"pruned_count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -z "$PRUNE_COUNT" ] && PRUNE_COUNT=0
    TOTAL_SESSIONS_PRUNED=$PRUNE_COUNT
    if [ "$PRUNE_COUNT" -gt 1000 ]; then
        record_anomaly "gm" "$PRUNE_COUNT closed session beads pruned in one run (threshold: 1000)"
    fi
fi

if [ -d "$CITY_BEADS_DIR" ] && [ -z "$DRY_RUN" ] && command -v gc >/dev/null 2>&1; then
    SESSION_PRUNE_ATTEMPTED=1
    if SESSION_STATE_PRUNE_JSON=$((
        cd "$CITY_ABS" && BEADS_DIR="$CITY_BEADS_DIR" gc session prune --state drained --before "$SESSION_STATE_PRUNE_AGE" --json
    ) 2>&1); then
        :
    else
        record_anomaly "gm" "terminal session-state prune failed: $(sanitize_output "$SESSION_STATE_PRUNE_JSON")"
        SESSION_STATE_PRUNE_JSON='{"count":0}'
    fi
    SESSION_STATE_PRUNE_COUNT=$(printf '%s' "$SESSION_STATE_PRUNE_JSON" | sed -n 's/.*"count"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -z "$SESSION_STATE_PRUNE_COUNT" ] && SESSION_STATE_PRUNE_COUNT=0
    TOTAL_SESSIONS_PRUNED=$((TOTAL_SESSIONS_PRUNED + SESSION_STATE_PRUNE_COUNT))
    if [ "$SESSION_STATE_PRUNE_COUNT" -gt 1000 ]; then
        record_anomaly "gm" "$SESSION_STATE_PRUNE_COUNT terminal session-state beads pruned in one run (threshold: 1000)"
    fi
fi

if [ "$HAD_DATABASES" -eq 0 ] && [ "$SESSION_PRUNE_ATTEMPTED" -eq 0 ] && [ -z "$ANOMALIES" ]; then
    exit 0
fi

# Report.
ANOMALY_COUNT=0
if [ -n "$ANOMALIES" ]; then
    ANOMALY_COUNT=$(printf '%b' "$ANOMALIES" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
    # ga-u8nbt9: this runs every 30 min on every rig; the same anomaly text must
    # not become a mail every time. Re-send when the text changes or the TTL passed.
    ANOMALY_HASH=$(printf '%s' "$ANOMALIES" | cksum | cut -d' ' -f1)
    ANOMALY_STATE="$CITY_ABS/.gc/runtime/reaper-anomaly-mailed"
    ANOMALY_NOW=$(date +%s)
    ANOMALY_SEND=1
    LAST_HASH=""
    LAST_EPOCH=""
    if [ -r "$ANOMALY_STATE" ]; then
        read -r LAST_HASH LAST_EPOCH < "$ANOMALY_STATE" || true
        if [ "$LAST_HASH" = "$ANOMALY_HASH" ] && [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]] \
           && [ $((ANOMALY_NOW - LAST_EPOCH)) -lt "$ANOMALY_MAIL_TTL_S" ]; then
            ANOMALY_SEND=0
        fi
    fi
    if [ "$ANOMALY_SEND" -eq 1 ]; then
        # Record "mailed" only when the mail actually went out, so a failed send is retried next run.
        if gc mail send mayor/ -s "ESCALATION: Reaper anomalies detected [MEDIUM]" -m "$ANOMALIES" 2>/dev/null; then
            mkdir -p "$(dirname "$ANOMALY_STATE")" 2>/dev/null || true
            printf '%s %s\n' "$ANOMALY_HASH" "$ANOMALY_NOW" > "$ANOMALY_STATE" 2>/dev/null || true
        fi
    fi
fi

ISSUE_STEPS_STATE="off"
[ -n "$ISSUE_STEPS" ] && ISSUE_STEPS_STATE="on"
SUMMARY="reaper — stale_wisps:$TOTAL_STALE_WISPS, closed_wisps:$TOTAL_CLOSED_WISPS, purged:$TOTAL_PURGED, sessions-pruned:$TOTAL_SESSIONS_PRUNED, closed:$TOTAL_ISSUES_CLOSED, expired:$TOTAL_EXPIRED_ISSUES_CLOSED, expired_skipped:$TOTAL_EXPIRED_ISSUES_SKIPPED, skipped_non_city_issues:$TOTAL_STALE_ISSUES_SKIPPED, mail_wisps:$TOTAL_MAIL_WISPS, purge_age_h:$PURGE_AGE_H, purge_batches:$PURGE_BATCHES, purge_capped_dbs:$PURGE_CAPPED_DBS, schema_skipped_dbs:$SCHEMA_SKIPPED_DBS, issue_steps:$ISSUE_STEPS_STATE, anomalies:$ANOMALY_COUNT"
if [ -n "$DRY_RUN" ]; then
    SUMMARY="$SUMMARY, would_close_wisps:$TOTAL_WOULD_CLOSE_WISPS, would_expire:$TOTAL_WOULD_EXPIRE, would_purge:$TOTAL_WOULD_PURGE (dry run)"
fi

gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
echo "reaper: $SUMMARY"

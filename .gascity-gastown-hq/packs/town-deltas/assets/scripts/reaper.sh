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
#  6. ga-x2fj8h — THE CHUNK THAT FAILED, AND THE 2.9M ORPHANS NOBODY LOOKED AT.
#     (a) purge_chunk sent five DELETEs as ONE multi-statement bounded by WISPS (500
#         ids). Rows per wisp are not bounded (a live wisp owns up to ~1000 wisp_events
#         rows, measured 19/09) and wisp_events is a 1.9M-row table keyed by a random
#         uuid, so removing a row is a random read. One statement could therefore run
#         past Dolt's 30 s read cutoff ("error on line 6 for query DELETE FROM
#         hq.wisp_events"), and because the loop stopped at the FIRST failed chunk and
#         the oldest candidates are always retried first, one heavy chunk could stall
#         the whole purge. Now every child delete is ROW-bounded (DELETE ... LIMIT n in
#         a loop), adaptive (a slow or failed statement halves the batch and is
#         retried), a failed chunk is skipped (a circuit breaker stops the purge after
#         GC_REAPER_PURGE_MAX_CONSEC_FAIL in a row) and the failure reaches the
#         DOG_DONE summary (purge_failed_chunks, last_error), not only the mail.
#         Partial state after a failed chunk is harmless BY DESIGN: children go first
#         and the wisps row last, so a half-emptied wisp is still a purge candidate
#         next run — never an orphan. The statements are separate auto-commits: the
#         chunk is idempotent (safe to retry), not atomic.
#     (b) ORPHAN SWEEP (step 2b). The purge above stops CREATING orphans; the ones
#         already there (wisps hard-deleted before ga-u8nbt9 without their children:
#         measured on the live hq at 19/09 22:08 BRT — 1,871,768 wisp_events and
#         ~674k wisp_labels; wisp_comments and wisp_dependencies had none) were never
#         looked at again. Each run removes, within
#         GC_REAPER_ORPHAN_BUDGET_S, child rows whose wisp no longer exists: selected by
#         an anti-join with a LIMIT (index-ordered, stops early), deleted by issue_id
#         with the SAME NOT EXISTS re-checked inside the DELETE, so a row of a live wisp
#         cannot be removed even if the selection was stale. Never by age. It doubles as
#         the detector: a run that sweeps more than GC_REAPER_ORPHAN_ALERT rows means
#         something still deletes wisps without their children, and says so.
#         A failed selection is NOT "no orphans" (get_sql_rows leaves the result empty
#         either way): SQL_ROWS_FAILED tells them apart.
#     (c) SAFETY RAILS of the sweep, and why (measured 19/09 on a scaled replica of hq.wisp_events:
#         same DDL and row mix, a scratch Dolt with the live auto-GC config, 229k orphans of 237k
#         rows). Deleting them cost ~3 KB of TRANSIENT disk per row — the size peaked at +714 MB over
#         a 177 MB baseline, then auto-GC folded it back to 8 MB — and it made no difference
#         whether the rows went by issue_id (this script) or by primary-key range (+791 MB), so a
#         cleverer delete order does not buy the disk back (why was not isolated; the three
#         indexes of the table cannot all be clustered by one order, and are the suspect). The live
#         volume sat at 96% (8.3 GiB free), and an unbounded drain of 1.87M rows is ~5.6 GB of
#         peak. Hence: a ROW cap per run (GC_REAPER_ORPHAN_MAX_ROWS, so what one run adds before
#         auto-GC catches up is bounded — HARD, never exceeded: the last DELETE batch is shrunk to
#         what is left of the allowance, because one sampled round can name wisps owning far more
#         rows than the sample), a FREE-DISK floor re-read every round
#         (GC_REAPER_ORPHAN_MIN_FREE_GB; an unreadable df is "cannot tell", not "enough"), no sweep
#         after the purge's failure breaker tripped (Dolt is unwell), and no delete at all while
#         `wisps` is empty or unreadable (NOT EXISTS against an empty table makes EVERY child row
#         an orphan). A halted sweep is counted and named in the DOG_DONE line
#         (orphan_halted_dbs, orphan_halt) — never a silent skip.
#         LIVE CORRECTION (measured on the real hq, 19/09 23:31, 12,000 orphan events deleted with
#         this script's statement shape): +97 MB, i.e. ~8 KB per row (2.7x the replica), and it did
#         NOT fold back. The orphans live in oldgen, which the default GC (`CALL dolt_gc()` — all
#         the 2-hourly dolt-gc-maintenance job ever runs) never collects; only `dolt gc --full`
#         does. So a delete-based drain ADDS disk until a full GC. That job is itself gated on
#         free space of max(200% of the store, store + 3 GB) (~15 GiB for the 7.6 GB hq) and had
#         skipped 26 cycles running (~52 h) on 19/09. Hence the free-disk floor defaults to 18 GiB:
#         ABOVE that gate (and above the disk-floor guard's WARN of 8 GiB), so the sweep can never
#         eat the headroom the GC needs to give space back. On a disk as full as 19/09's the sweep
#         is inert by design (orphan_halt says why); it works once space is freed, or after a
#         table rebuild (bead ga-x2fj8h / ga-5dggst). Space is returned only by a full GC: this
#         script never runs gc.
#         The order declares timeout = "900s" (orders/mol-dog-reaper.toml): the engine default for
#         an exec order is 300 s, and PURGE_BUDGET_S 240 + ORPHAN_BUDGET_S 180 + the fixed work
#         can pass it.
#  7. ga-hpdpij — TWO OBSERVABILITY GAPS THAT LEFT THE ORPHANS INVISIBLE (found executing ga-5dggst).
#     (a) THE SUMMARY IS DURABLE. It used to leave the script only as `gc session nudge deacon/ ... || true` and
#         a stdout echo — 0 hits in .gc/events.jsonl or in the deacon's transcript, so "purge_failed_chunks:0,
#         anomalies:0" had to be inferred by SQL. Every run now appends ONE line (UTC timestamp + the exact DOG_DONE
#         summary) to $GC_REAPER_SUMMARY_LOG (default <city>/.gc/runtime/reaper-summary.log; ~40 KB/day at one run
#         per 30 min), size-capped (GC_REAPER_SUMMARY_LOG_MAX_BYTES, default 256 KiB) with GC_REAPER_SUMMARY_LOG_KEEP
#         (default 3) rotated generations (.1 .. .N): `tail -2 <log>` answers "what did the last two rounds do"
#         without SQL. A log that cannot be written never fails the run but is NOT silent: the stdout and DOG_DONE
#         line then end in summary_log:FAILED. One that was written but could not be size-capped (the size was
#         unreadable, or the live file could not be moved aside) ends in summary_log:UNCAPPED instead.
#     (b) THE ORPHANS ARE COUNTED WHETHER OR NOT THE SWEEP RUNS. The "new producer" alert (note 6b) only fires in a
#         run whose sweep finished. With the sweep stopped by the free-disk floor (18 GiB; ~10 GiB free on 20/09),
#         switched off, capped or halted, no NEW orphan was counted or alerted — and with the backlog at 0 in all
#         8 databases, their return would have been invisible. A read-only phase AFTER the whole per-database loop
#         now counts, per database, the orphan rows of wisp_comments / wisp_labels / wisp_events (an anti-join
#         against `wisps`, LIMIT GC_REAPER_ORPHAN_COUNT_ALERT+1 per table: it stops early and cannot run past
#         Dolt's 30 s cutoff) and reports orphan_count in the summary — the orphans LEFT after this run's sweep.
#         EVERY bead store is counted, including one the reaper SKIPPED for an unrecognised wisp_dependencies schema
#         (schema_skipped_dbs): the count never reads that table, and that database is the one nobody is cleaning
#         (ga-u8nbt9). Leaving it out printed orphan_count:0 while 500 orphans sat in it.
#         More than GC_REAPER_ORPHAN_COUNT_ALERT (default 1000) in ONE database is an anomaly (mailed, sweep or no
#         sweep). Its text carries no counts, so the dedupe of note 5 sends it once per TTL; the number is in the
#         summary.
#         THREE states, never two: a read that failed — or that the phase's own budget (GC_REAPER_ORPHAN_COUNT_BUDGET_S,
#         default 90) never reached — is UNKNOWN, never a 0. orphan_count is a number when every probe answered and
#         none hit its cap, "N+" (a lower bound) when something was capped or unanswered, "unknown" when nothing was
#         measured or nothing measured had orphans while something else went unanswered, "off" with
#         GC_REAPER_ORPHAN_COUNT=0; orphan_count_unknown:<probes> says how many probes got no answer.
#         Why AFTER the loop and not per database: time spent inside it is charged to the purge budget of every
#         later database (the same hazard the sweep's clock shift guards against, selftest O18; here C7).
#     (c) THE SCHEMA PROBE NO LONGER FALSE-NEGATIVES. Building (b) exposed a flake in this script's own
#         probe_dependency_table: `printf "$fields" | grep -qx <column>` under `set -o pipefail` can report FAILURE
#         although the column is listed (grep -q exits on the first match; its writer catches SIGPIPE). It skipped
#         HEALTHY databases as "unrecognised schema" — measured 8 of 300 probes at load ~45 (and every probe on a
#         140 KB column list) — and made the reaper selftests fail at random under load. It is now the pipe-free
#         field_listed (selftest C13). The same idiom may live in other scripts: ga-5bxuam.
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
# ga-x2fj8h: child rows are deleted in ROW-bounded statements (a wisp owns an unbounded
# number of rows), and orphan child rows are swept (see header note 6).
PURGE_ROW_BATCH="${GC_REAPER_PURGE_ROW_BATCH:-1000}"           # child rows per DELETE statement
PURGE_STMT_SLOW_S="${GC_REAPER_PURGE_STMT_SLOW_S:-8}"          # a statement this slow halves the batch (Dolt cuts at 30 s)
PURGE_STMT_TRIES="${GC_REAPER_PURGE_STMT_TRIES:-3}"            # attempts per statement; each retry halves the batch
PURGE_RETRY_PAUSE_S="${GC_REAPER_PURGE_RETRY_PAUSE_S:-2}"      # breather before a retry (a timed-out statement means Dolt is hot)
PURGE_MAX_CONSEC_FAIL="${GC_REAPER_PURGE_MAX_CONSEC_FAIL:-3}"  # failed chunks in a row before the purge gives up this run
ORPHAN_SWEEP="${GC_REAPER_ORPHAN_SWEEP:-1}"                    # 0 switches the orphan sweep off
ORPHAN_SELECT_ROWS="${GC_REAPER_ORPHAN_SELECT_ROWS:-2000}"     # orphan rows sampled per round (their wisp ids are then swept)
ORPHAN_BUDGET_S="${GC_REAPER_ORPHAN_BUDGET_S:-180}"            # wall-clock budget of the whole sweep, all databases
ORPHAN_ALERT="${GC_REAPER_ORPHAN_ALERT:-5000}"                 # sweeping more than this in one run is an anomaly
ORPHAN_PAUSE_S="${GC_REAPER_ORPHAN_PAUSE_S:-0.2}"              # breather between rounds (Dolt is hot)
# A deleted child row costs ~8 KB of disk on the live hq (measured 19/09; ~3 KB on a small replica)
# and only a `dolt gc --full` gives it back (header note 6c). So a run is bounded in ROWS as well as
# in time, and refuses to work below a free-disk floor that sits ABOVE the headroom gate of the GC
# job (max(200% of the store, store + 3 GB): ~15 GiB for the 7.6 GB hq) and the disk guard's WARN.
ORPHAN_MAX_ROWS="${GC_REAPER_ORPHAN_MAX_ROWS:-100000}"         # rows ONE run may sweep, all databases
ORPHAN_MIN_FREE_GB="${GC_REAPER_ORPHAN_MIN_FREE_GB:-18}"       # no sweep below this much free disk on the city volume (0 = guard off)
# ga-hpdpij (header note 7): a read-only COUNT of the orphan child rows every run — whether or not the sweep runs —
# and a durable copy of the summary line.
ORPHAN_COUNT="${GC_REAPER_ORPHAN_COUNT:-1}"                    # 0 switches the orphan COUNT off (the sweep has its own switch)
ORPHAN_COUNT_ALERT="${GC_REAPER_ORPHAN_COUNT_ALERT:-1000}"     # orphan rows LEFT in ONE database above this is an anomaly
ORPHAN_COUNT_BUDGET_S="${GC_REAPER_ORPHAN_COUNT_BUDGET_S:-90}" # wall-clock budget of the whole count phase, all databases
SUMMARY_LOG="${GC_REAPER_SUMMARY_LOG:-$CITY_ABS/.gc/runtime/reaper-summary.log}"
SUMMARY_LOG_MAX_BYTES="${GC_REAPER_SUMMARY_LOG_MAX_BYTES:-262144}"  # rotate the log at this size
SUMMARY_LOG_KEEP="${GC_REAPER_SUMMARY_LOG_KEEP:-3}"                 # rotated generations kept (.1 .. .N)

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
# ga-x2fj8h counters — a chunk that failed for good, and what the orphan sweep did, reach the
# summary too. PURGE_LAST_ERROR keeps a SHORT head+tail of the last failed statement's error so
# the DOG_DONE line names the cause (the mail carries the whole text).
PURGE_FAILED_CHUNKS=0
PURGE_CHILD_ROWS=0
PURGE_LAST_ERROR=""
ORPHAN_SWEPT=0
ORPHAN_CAPPED_DBS=0
ORPHAN_FAILED=0
ORPHAN_HALTED_DBS=0    # a safety rail cut the sweep of a database short (disk floor, Dolt unwell, empty wisps)
ORPHAN_HALT_REASON=""  # short, comma-free: the LAST such reason, for the DOG_DONE line
PURGE_TRIPPED=0        # the purge's consecutive-failure breaker fired in this run: Dolt is unwell
TOTAL_WOULD_SWEEP=0
ORPHAN_DEADLINE=""   # $SECONDS value the sweep must stop at; set lazily by its first use
# ga-hpdpij counters (header note 7b) — the read-only orphan COUNT, all databases. Three states: counted,
# counted zero, could not count; only the first two ever reach ORPHAN_COUNT_TOTAL.
ORPHAN_COUNT_TOTAL=0      # orphan rows counted (each probe capped at ORPHAN_COUNT_ALERT+1)
ORPHAN_COUNT_PROBES=0     # (database, table) probes that ANSWERED
ORPHAN_COUNT_CAPPED=0     # of those, the ones that hit the cap: the real number is AT LEAST what was counted
ORPHAN_COUNT_UNKNOWN=0    # probes with NO answer (failed read, or the phase ran out of budget) — never a zero
ORPHAN_COUNT_OVER_DBS=0   # databases with more than ORPHAN_COUNT_ALERT orphan rows left
ORPHAN_COUNT_TEXT="unknown"   # what the summary prints for orphan_count (set by count_orphan_children)
COUNT_DBS=""              # the bead stores (safe name + a wisps table) the main loop met, whatever it then did with them: the ones the count visits
PURGE_START_EPOCH=$(date +%s)
ANOMALIES=""

sanitize_output() {
    printf '%s' "$1" | tr '\n' ' ' | cut -c1-4000
}

# ga-x2fj8h: Dolt echoes the FAILING STATEMENT inside its error ("error on line N for query <sql>:
# <cause>"), and the purge/sweep statements carry IN (<hundreds of ids>) lists: measured on real Dolt,
# a failing 500-id DELETE answers ~10 KB with the CAUSE at the very end, so the 4000-char head cut of
# sanitize_output kept the ids and dropped the cause (the DOG_DONE last_error and the mail never said
# WHY). The lists also differ every run, which defeated the anomaly-mail dedupe (keyed on the text).
# Collapse them to IN (...) before anything is truncated.
strip_id_lists() {
    printf '%s' "$1" | tr '\n' ' ' | sed -E 's/IN \([^)]*\)/IN (...)/g'
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
validate_num PURGE_ROW_BATCH 1000 50
validate_num PURGE_STMT_SLOW_S 8 1
validate_num PURGE_STMT_TRIES 3 1
validate_num PURGE_RETRY_PAUSE_S 2 0
validate_num PURGE_MAX_CONSEC_FAIL 3 1
validate_num ORPHAN_SELECT_ROWS 2000 50
validate_num ORPHAN_BUDGET_S 180 1
validate_num ORPHAN_ALERT 5000 1
validate_num ORPHAN_MAX_ROWS 100000 2   # 2, not 1: a one-row DELETE is never sent (delete_rows_bounded), so a cap of 1 would sweep nothing
validate_num ORPHAN_MIN_FREE_GB 18 0
validate_num ORPHAN_COUNT_ALERT 1000 1
validate_num ORPHAN_COUNT_BUDGET_S 90 1
validate_num SUMMARY_LOG_MAX_BYTES 262144 1024
validate_num SUMMARY_LOG_KEEP 3 1
case "$ORPHAN_SWEEP" in
    0|1) ;;
    *)
        record_anomaly "config" "GC_REAPER_ORPHAN_SWEEP='$ORPHAN_SWEEP' is not 0 or 1; using the default 1"
        ORPHAN_SWEEP=1
        ;;
esac
case "$ORPHAN_COUNT" in
    0|1) ;;
    *)
        record_anomaly "config" "GC_REAPER_ORPHAN_COUNT='$ORPHAN_COUNT' is not 0 or 1; using the default 1"
        ORPHAN_COUNT=1
        ;;
esac
# A decimal number of seconds (sleep accepts a fraction): digits with at most one dot.
case "$ORPHAN_PAUSE_S" in
    ''|.|*[!0-9.]*|*.*.*)
        record_anomaly "config" "GC_REAPER_ORPHAN_PAUSE_S='$ORPHAN_PAUSE_S' is not a number of seconds; using the default 0.2"
        ORPHAN_PAUSE_S=0.2
        ;;
esac

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
# ga-hpdpij: SQL_COUNT_RESULT is 0 both for "counted zero" and for "could not count" (this function returns 0
# either way; a failure is only recorded as an anomaly). A caller that must tell them apart — the orphan COUNT,
# whose whole point is that a failed read never reads as "no orphans" — reads SQL_COUNT_FAILED, the twin of
# SQL_ROWS_FAILED below. 0 = SQL_COUNT_RESULT is a real answer, 1 = it is not.
SQL_COUNT_FAILED=0
get_sql_count() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local stderr_file
    local stderr_output
    local count

    SQL_COUNT_RESULT=0
    SQL_COUNT_FAILED=0
    if ! stderr_file=$(mktemp); then
        SQL_COUNT_FAILED=1
        record_anomaly "$db" "$label count failed for $db: could not create stderr capture file"
        return 0
    fi
    if ! output=$(dolt_sql -r csv -q "$query" 2>"$stderr_file"); then
        stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
        rm -f "$stderr_file"
        SQL_COUNT_FAILED=1
        record_anomaly "$db" "$label count failed for $db: $(sanitize_output "$stderr_output $output")"
        return 0
    fi
    rm -f "$stderr_file"

    count=$(printf '%s\n' "$output" | tail -1 | tr -d '\r')
    if [ -z "$count" ] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
        SQL_COUNT_FAILED=1
        record_anomaly "$db" "$label count returned non-numeric value for $db: $(sanitize_output "$output")"
        return 0
    fi

    SQL_COUNT_RESULT="$count"
}

SQL_ROWS_RESULT=""
# ga-x2fj8h: an EMPTY SQL_ROWS_RESULT means either "no rows" or "no answer" — this function
# returns 0 for both (a failure is only recorded as an anomaly). A caller that acts on
# "no rows" (the orphan sweep: "no orphans left, the table is clean") must read
# SQL_ROWS_FAILED, or a query cut at Dolt's 30 s read timeout reads as a clean table.
SQL_ROWS_FAILED=0
SQL_ROWS_ERR=""
get_sql_rows() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local stderr_file
    local stderr_output

    SQL_ROWS_RESULT=""
    SQL_ROWS_FAILED=0
    SQL_ROWS_ERR=""
    if ! stderr_file=$(mktemp); then
        SQL_ROWS_FAILED=1
        SQL_ROWS_ERR="$label query failed for $db: could not create stderr capture file"
        record_anomaly "$db" "$SQL_ROWS_ERR"
        return 0
    fi
    if ! output=$(dolt_sql -r csv -q "$query" 2>"$stderr_file"); then
        stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
        rm -f "$stderr_file"
        SQL_ROWS_FAILED=1
        SQL_ROWS_ERR="$label query failed for $db: $(sanitize_output "$stderr_output $output")"
        record_anomaly "$db" "$SQL_ROWS_ERR"
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
# field_listed <newline-separated names> <name>: is <name> one of the names — a WHOLE line, like `grep -x`?
# A `case` on the whole string, NOT `printf "$names" | grep -qx <name>`: under `set -o pipefail` a grep that matches
# and exits early can leave its writer with SIGPIPE, and the pipeline then reports FAILURE although the column IS
# there. Measured 20/09 on this very input shape (a 130-byte column list, the pattern present every time): 44 false
# negatives in 4000 tries at load ~45. In probe_dependency_table that read as "unrecognised schema" and skipped a
# HEALTHY database for the whole run, with a misleading anomaly (ga-hpdpij; the class is ga-5bxuam).
field_listed() {
    case $'\n'"$1"$'\n' in
        *$'\n'"$2"$'\n'*) return 0 ;;
    esac
    return 1
}
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
    field_listed "$fields" 'issue_id' || return 1

    if field_listed "$fields" 'depends_on_issue_id'; then
        DEP_FLAVOR="split"
        DEP_ISSUE_TARGET_COL="depends_on_issue_id"
        if field_listed "$fields" 'depends_on_wisp_id'; then
            DEP_WISP_TARGET_COL="depends_on_wisp_id"
        fi
        return 0
    fi
    if field_listed "$fields" 'depends_on_id'; then
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

# ga-x2fj8h: run_sql_change_quiet is the original run_sql_change WITHOUT recording the failure:
# the text is left in SQL_CHANGE_ERR and the CALLER decides — retry with a smaller batch, or
# give up and raise the anomaly. A statement retried three times must not become three mails.
SQL_CHANGE_ERR=""
run_sql_change_quiet() {
    local db="$1"
    local label="$2"
    local query="$3"
    local output
    local rows
    local stderr_file
    local stderr_output

    SQL_CHANGE_ROWS_RESULT=0
    SQL_CHANGE_ERR=""
    if ! stderr_file=$(mktemp); then
        SQL_CHANGE_ERR="$label failed for $db: could not create stderr capture file"
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
        SQL_CHANGE_ERR="$label failed for $db: $(sanitize_output "$(strip_id_lists "$stderr_output $output")")"
        return 1
    fi
    stderr_output=$(cat "$stderr_file" 2>/dev/null || true)
    rm -f "$stderr_file"

    rows=$(printf '%s\n' "$output" | tail -1 | tr -d '\r')
    if [ -z "$rows" ] || ! [[ "$rows" =~ ^[0-9]+$ ]]; then
        SQL_CHANGE_ERR="$label returned non-numeric row count for $db: $(sanitize_output "$(strip_id_lists "$stderr_output $output")")"
        return 1
    fi

    SQL_CHANGE_ROWS_RESULT="$rows"
    return 0
}

run_sql_change() {
    if run_sql_change_quiet "$@"; then
        return 0
    fi
    record_anomaly "$1" "$SQL_CHANGE_ERR"
    return 1
}

# ga-x2fj8h: one line, no commas or quotes (the DOG_DONE summary is comma-separated), keeping
# the HEAD (what failed, where) and the TAIL (the cause) of a long error text.
short_error() {
    printf '%s' "$1" | tr '\n,"' '   ' | tr -s ' ' \
        | awk '{ s = $0; if (length(s) > 240) s = substr(s, 1, 70) " ... " substr(s, length(s) - 150); print s }'
}

# A statement gave up for good: mail it (anomaly) AND keep a short form for the DOG_DONE summary.
note_failure() {  # note_failure <db> <full error text>
    PURGE_LAST_ERROR=$(short_error "$2")
    record_anomaly "$1" "$2"
}

# ga-x2fj8h: DELETE the rows of <table> matching <where>, in ROW-bounded statements, until none
# remain. Rows per wisp are unbounded and removing a wisp_events row is a random read (uuid key,
# 1.9M rows): one big statement can run past Dolt's 30 s cutoff, so the bound is on ROWS.
#  * adaptive: a statement slower than PURGE_STMT_SLOW_S halves the next batch; a FAILED one is
#    retried (PURGE_STMT_TRIES attempts) with half the batch. The floor is 50 rows.
#  * a batch that removes fewer rows than asked for means nothing matching is left (measured
#    against real Dolt: ROW_COUNT() after DELETE ... LIMIT n is exact).
#  * the optional <max-rows> is a cap that is NEVER exceeded by this call (0 = none): the last
#    batch is shrunk to what is left of the allowance (and a remainder of a single row is left
#    for the next run — see the check below). It is a cap on ROWS, not on rounds: the orphan
#    sweep hands the whole "sampled wisp ids" set to one call, and a wisp owns up to ~1000 rows,
#    so a per-round check alone let one round delete every row of the sampled wisps and blow
#    through GC_REAPER_ORPHAN_MAX_ROWS (found by selftest O14: cap 25, 120 rows swept). The
#    disk-transient bound of header note 6c needs the hard form.
# Sets CHILD_ROWS_DELETED (rows removed by THIS call, even when it fails part-way) and
# CHILD_DELETE_ERR. Returns 0 = nothing left; 1 = failed for good; 2 = the deadline (a $SECONDS
# value; empty = none) passed while rows remain; 3 = <max-rows> was reached (rows may remain).
CHILD_ROWS_DELETED=0
CHILD_DELETE_ERR=""
delete_rows_bounded() {  # delete_rows_bounded <db> <table> <where> [<deadline>] [<max-rows>]
    local db="$1" table="$2" where="$3" deadline="${4:-}" max_rows="${5:-0}"
    local limit="$PURGE_ROW_BATCH" tries=0 t0 dt use remaining

    CHILD_ROWS_DELETED=0
    CHILD_DELETE_ERR=""
    while :; do
        if [ -n "$deadline" ] && [ "$SECONDS" -ge "$deadline" ]; then
            return 2
        fi
        use=$limit
        if [ "$max_rows" -gt 0 ]; then
            remaining=$((max_rows - CHILD_ROWS_DELETED))
            # A one-row statement is never sent, so a remainder of 1 is left for the next run: on
            # this Dolt, DELETE ... LIMIT 1 on a table that carries a foreign key (wisp_dependencies)
            # answers ROW_COUNT() = -1 although the row IS removed (measured with `dolt sql`; every
            # other LIMIT and every other table counts exactly), and the row-count check reads -1 as
            # a failed statement and retries it — the row is gone but uncounted, and the sweep
            # raises a false "removed nothing" anomaly (selftest O8b).
            if [ "$remaining" -lt 2 ]; then
                return 3
            fi
            if [ "$use" -gt "$remaining" ]; then
                use=$remaining
            fi
        fi
        t0=$SECONDS
        if run_sql_change_quiet "$db" "purging $table rows" \
            "DELETE FROM \`$db\`.$table WHERE $where LIMIT $use"; then
            tries=0
            CHILD_ROWS_DELETED=$((CHILD_ROWS_DELETED + SQL_CHANGE_ROWS_RESULT))
            if [ "$SQL_CHANGE_ROWS_RESULT" -lt "$use" ]; then
                return 0
            fi
            dt=$((SECONDS - t0))
            if [ "$dt" -ge "$PURGE_STMT_SLOW_S" ] && [ "$limit" -gt 50 ]; then
                limit=$((limit / 2))
                [ "$limit" -lt 50 ] && limit=50
            elif [ "$dt" -lt $((PURGE_STMT_SLOW_S / 4)) ] && [ "$limit" -lt "$PURGE_ROW_BATCH" ]; then
                # Dolt has calmed down: grow back toward the configured batch, so one slow
                # moment does not leave the rest of a long drain crawling at tiny batches.
                limit=$((limit * 2))
                [ "$limit" -gt "$PURGE_ROW_BATCH" ] && limit=$PURGE_ROW_BATCH
            fi
        else
            tries=$((tries + 1))
            CHILD_DELETE_ERR="$SQL_CHANGE_ERR"
            if [ "$tries" -ge "$PURGE_STMT_TRIES" ]; then
                return 1
            fi
            limit=$((limit / 2))
            [ "$limit" -lt 50 ] && limit=50
            sleep "$PURGE_RETRY_PAUSE_S"
        fi
    done
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

# ga-x2fj8h: this used to be ONE multi-statement of five DELETEs bounded by wisps (500 ids). A
# failure in the third (wisp_events, "error on line 6") left the labels and comments already gone,
# stopped the whole purge, and the next run retried the very same oldest chunk. Now each child
# table is drained in ROW-bounded statements (delete_rows_bounded) — children first, the wisps
# rows LAST — so a chunk that fails part-way leaves half-emptied wisps that are still purge
# candidates (idempotent: the next run finishes them), never orphans.
# Returns 0 = the chunk is purged; 1 = a statement failed for good (recorded, in the summary);
# 2 = the time budget ran out while rows remain (nothing failed; the work carries over).
purge_chunk() {  # purge_chunk <db> <quoted-id-list> <seconds-allowed>
    local db="$1"
    local list="$2"
    local allowed="$3"
    local deadline=$((SECONDS + allowed))
    local table
    local rc
    local try=0

    for table in wisp_labels wisp_comments wisp_events wisp_dependencies; do
        rc=0
        delete_rows_bounded "$db" "$table" "issue_id IN ($list)" "$deadline" || rc=$?
        PURGE_CHILD_ROWS=$((PURGE_CHILD_ROWS + CHILD_ROWS_DELETED))
        DB_MUTATIONS=$((DB_MUTATIONS + CHILD_ROWS_DELETED))
        case "$rc" in
            0) ;;
            2) return 2 ;;
            *)
                PURGE_FAILED_CHUNKS=$((PURGE_FAILED_CHUNKS + 1))
                note_failure "$db" "$CHILD_DELETE_ERR"
                return 1
                ;;
        esac
    done

    while :; do
        if run_sql_change_quiet "$db" "purging closed wisps" "DELETE FROM \`$db\`.wisps WHERE id IN ($list)"; then
            DB_PURGED=$((DB_PURGED + SQL_CHANGE_ROWS_RESULT))
            TOTAL_PURGED=$((TOTAL_PURGED + SQL_CHANGE_ROWS_RESULT))
            DB_MUTATIONS=$((DB_MUTATIONS + SQL_CHANGE_ROWS_RESULT))
            PURGE_BATCHES=$((PURGE_BATCHES + 1))
            return 0
        fi
        try=$((try + 1))
        if [ "$try" -ge "$PURGE_STMT_TRIES" ]; then
            PURGE_FAILED_CHUNKS=$((PURGE_FAILED_CHUNKS + 1))
            note_failure "$db" "$SQL_CHANGE_ERR"
            return 1
        fi
        sleep "$PURGE_RETRY_PAUSE_S"
    done
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
    local consec=0
    local rc

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

        # ga-x2fj8h: the chunk is handed what is LEFT of the budget as a deadline, so it cannot run
        # on past it (before, one 500-wisp DELETE alone could outlast the whole budget).
        # A chunk that FAILED (recorded, counted in the summary) no longer stops the purge: it
        # stays a candidate and the others still go — but PURGE_MAX_CONSEC_FAIL failures in a row
        # mean Dolt is unwell, and hammering it further would only make it worse.
        rc=0
        purge_chunk "$db" "$list" $((PURGE_BUDGET_S - elapsed)) || rc=$?
        case "$rc" in
            0)
                consec=0
                ;;
            2)
                capped=1   # out of time with rows remaining — nothing failed; the next run carries on
                break
                ;;
            *)
                capped=1   # the failure is already an anomaly; the chunk is retried next run
                consec=$((consec + 1))
                if [ "$consec" -ge "$PURGE_MAX_CONSEC_FAIL" ]; then
                    PURGE_TRIPPED=1   # the orphan sweep reads this: no piling on an unwell Dolt
                    break
                fi
                ;;
        esac
    done

    if [ "$bad" -gt 0 ]; then
        record_anomaly "$db" "$bad closed wisp id(s) with unexpected characters were NOT purged"
    fi
    if [ "$capped" -eq 1 ]; then
        PURGE_CAPPED_DBS=$((PURGE_CAPPED_DBS + 1))
    fi
    return 0
}

# ga-x2fj8h — step 2b: sweep ORPHAN child rows, i.e. rows of wisp_comments / wisp_dependencies /
# wisp_labels / wisp_events whose wisp no longer exists.
#  * SELECT: an anti-join with a LIMIT. It is index-ordered on issue_id, so it stops as soon as it
#    has ORPHAN_SELECT_ROWS orphan rows (measured 19/09 on the 1.9M-row wisp_events: ~0.5 ms per
#    row; the same anti-join WITHOUT a limit costs 15-25 s, right at Dolt's 30 s cutoff).
#  * DELETE: by issue_id (indexed), ROW-bounded (delete_rows_bounded), with the SAME NOT EXISTS
#    re-checked inside the statement — a row of a live wisp cannot be removed even if the sample
#    was stale. Only "the wisp is gone" qualifies; never age.
#  * A failed SELECT is NOT "no orphans" (SQL_ROWS_FAILED): it is reported, and the table skipped.
#  * Small tables first, so a run that runs out of budget has still finished them. The whole sweep
#    is bounded by ORPHAN_BUDGET_S of wall-clock ($SECONDS: no fork, and independent of the `date`
#    the purge budget reads); what is left is reported (orphan_capped_dbs) and carries over.
#  * Safety rails (header note 6c): a ROW cap per run, a free-disk floor, no sweep after the purge's
#    failure breaker tripped, and no delete at all while `wisps` looks empty (NOT EXISTS against an
#    empty table makes EVERY child row an "orphan").
DB_ORPHANS=0

# Free KB of the volume the city — and so the Dolt data dir — lives on; empty when unreadable.
orphan_free_kb() {
    df -Pk "$CITY_ABS" 2>/dev/null | awk 'NR==2 { print $4 }'
}

# 0 = enough free disk (or the guard is off); 1 = below the floor; 2 = the free space could not be
# read. "Cannot tell" is NOT "enough": a destructive job that needs headroom stays inert.
ORPHAN_FREE_KB=""
orphan_disk_state() {
    ORPHAN_FREE_KB=""
    [ "$ORPHAN_MIN_FREE_GB" -gt 0 ] || return 0
    ORPHAN_FREE_KB=$(orphan_free_kb)
    if ! [[ "$ORPHAN_FREE_KB" =~ ^[0-9]+$ ]]; then
        return 2
    fi
    if [ "$ORPHAN_FREE_KB" -lt $((ORPHAN_MIN_FREE_GB * 1048576)) ]; then
        return 1
    fi
    return 0
}

# A safety rail cut the sweep of <db> short. mail=1 raises an anomaly (something is wrong that a
# human should see); mail=0 is for conditions other alarms already cover (low disk, Dolt unwell).
# Either way the DOG_DONE line carries the count and the reason.
halt_orphan_sweep() {  # halt_orphan_sweep <db> <reason> <mail:0|1>
    ORPHAN_HALTED_DBS=$((ORPHAN_HALTED_DBS + 1))
    ORPHAN_HALT_REASON=$(short_error "$2")
    if [ "$3" = "1" ]; then
        record_anomaly "$1" "orphan sweep halted for $1: $2"
    fi
}

halt_orphan_disk() {  # halt_orphan_disk <db> <orphan_disk_state rc: 1 = low, 2 = unreadable>
    if [ "$2" -eq 1 ]; then
        halt_orphan_sweep "$1" "free disk $((ORPHAN_FREE_KB / 1048576)) GiB is below the floor of $ORPHAN_MIN_FREE_GB GiB (headroom the dolt_gc job needs)" 0
    else
        halt_orphan_sweep "$1" "free disk space could not be read (df -Pk $CITY_ABS); not sweeping blind" 1
    fi
}

sweep_orphan_children() {  # sweep_orphan_children <db>
    local db="$1"
    local table ids list id rc bad bad_seen
    local swept_db=0
    local capped=0
    local failed=0
    local halted=0
    local sweep_t0=$SECONDS

    DB_ORPHANS=0
    [ "$ORPHAN_SWEEP" = "1" ] || return 0

    if [ -n "$DRY_RUN" ]; then
        # A bounded probe: counting EVERY orphan of wisp_events would cost as much as the sweep.
        for table in wisp_comments wisp_dependencies wisp_labels wisp_events; do
            get_sql_count "$db" "orphan $table rows (dry run)" "
                SELECT COUNT(*) FROM (
                    SELECT 1 FROM \`$db\`.$table c
                    WHERE NOT EXISTS (SELECT 1 FROM \`$db\`.wisps w WHERE w.id = c.issue_id)
                    LIMIT $ORPHAN_SELECT_ROWS
                ) orphan_probe
            "
            TOTAL_WOULD_SWEEP=$((TOTAL_WOULD_SWEEP + SQL_COUNT_RESULT))
        done
        return 0
    fi

    if [ "$PURGE_TRIPPED" -eq 1 ]; then
        # The purge just gave up after consecutive failed chunks: Dolt is unwell. The sweep would
        # only add load (anti-join samples + deletes), so it waits for the next run.
        halt_orphan_sweep "$db" "the purge failure breaker tripped in this run (Dolt is unwell); not adding load" 0
        return 0
    fi

    [ -n "$ORPHAN_DEADLINE" ] || ORPHAN_DEADLINE=$((SECONDS + ORPHAN_BUDGET_S))

    for table in wisp_comments wisp_dependencies wisp_labels wisp_events; do
        bad_seen=0
        while :; do
            if [ "$SECONDS" -ge "$ORPHAN_DEADLINE" ]; then
                capped=1
                break
            fi
            # Row cap of the whole run (ORPHAN_SWEPT holds the databases already finished).
            if [ $((ORPHAN_SWEPT + swept_db)) -ge "$ORPHAN_MAX_ROWS" ]; then
                capped=1
                break
            fi
            # Free-disk floor, re-read every round: a drain that itself eats disk must see it.
            rc=0
            orphan_disk_state || rc=$?
            if [ "$rc" -ne 0 ]; then
                halt_orphan_disk "$db" "$rc"
                halted=1
                break
            fi
            get_sql_rows "$db" "orphan $table sample" "
                SELECT c.issue_id FROM \`$db\`.$table c
                WHERE NOT EXISTS (SELECT 1 FROM \`$db\`.wisps w WHERE w.id = c.issue_id)
                LIMIT $ORPHAN_SELECT_ROWS
            "
            if [ "$SQL_ROWS_FAILED" -eq 1 ]; then
                # "No answer" is not "no orphans": say so, and go on to the next table.
                failed=1
                PURGE_LAST_ERROR=$(short_error "$SQL_ROWS_ERR")
                break
            fi
            ids=$(printf '%s\n' "$SQL_ROWS_RESULT" | sed '/^[[:space:]]*$/d' | sort -u)
            [ -n "$ids" ] || break   # nothing left: this table is clean

            # Seatbelt: child rows exist, so `wisps` must not be empty (or unreadable — get_sql_count
            # reads a failed probe as 0 and raises its own anomaly). Against an empty `wisps` the
            # NOT EXISTS guard holds for EVERY row: the whole table would be "orphans". Re-read on
            # EVERY round, not once per database: a `wisps` table emptied or rebuilt while the sweep
            # runs (a migration, another actor) must stop the very next DELETE, not the next run.
            # Only reached when there is something to delete, so a legitimately empty rig database
            # costs nothing and raises nothing.
            get_sql_count "$db" "wisps emptiness probe" "SELECT COUNT(*) FROM (SELECT 1 FROM \`$db\`.wisps LIMIT 1) wisps_probe"
            if [ "$SQL_COUNT_RESULT" -lt 1 ]; then
                halt_orphan_sweep "$db" "the wisps table of $db is empty or unreadable while $table has rows: every child row would look orphaned; nothing deleted" 1
                halted=1
                break
            fi

            list=""
            bad=0
            while IFS= read -r id; do
                [ -n "$id" ] || continue
                # ids are interpolated into SQL: accept only the alphabet bd generates.
                if ! [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; then
                    bad=$((bad + 1))
                    continue
                fi
                list="${list:+$list,}'$id'"
            done <<< "$ids"
            [ "$bad" -gt "$bad_seen" ] && bad_seen=$bad
            if [ -z "$list" ]; then
                # Every sampled orphan has an id we refuse to interpolate; sampling again would
                # return the same rows for ever. Stop this table (the anomaly below says so).
                break
            fi

            # The allowance is what is LEFT of the run's row cap (> 0: the check at the top of the
            # round just passed), handed down so the cap is exact — one round names up to
            # ORPHAN_SELECT_ROWS wisps and each owns many rows, so a per-round check overshoots.
            rc=0
            delete_rows_bounded "$db" "$table" \
                "issue_id IN ($list) AND NOT EXISTS (SELECT 1 FROM \`$db\`.wisps w WHERE w.id = $table.issue_id)" \
                "$ORPHAN_DEADLINE" "$((ORPHAN_MAX_ROWS - ORPHAN_SWEPT - swept_db))" || rc=$?
            swept_db=$((swept_db + CHILD_ROWS_DELETED))
            case "$rc" in
                0)
                    ;;
                2|3)
                    capped=1   # 2 = out of time, 3 = out of row allowance: work remains for the next run
                    break
                    ;;
                *)
                    failed=1
                    note_failure "$db" "$CHILD_DELETE_ERR"
                    break
                    ;;
            esac
            if [ "$CHILD_ROWS_DELETED" -eq 0 ]; then
                # The sample named orphans yet the guarded DELETE removed none: sampling again would
                # loop. Stop this table and say so.
                record_anomaly "$db" "orphan $table sample of up to $ORPHAN_SELECT_ROWS rows was named but the guarded DELETE removed nothing; sweep of $table stopped"
                break
            fi
            sleep "$ORPHAN_PAUSE_S"
        done
        if [ "$bad_seen" -gt 0 ]; then
            record_anomaly "$db" "orphan $table rows with wisp id(s) of unexpected characters (up to $bad_seen per sample) were NOT swept"
        fi
        if [ "$capped" -eq 1 ] || [ "$halted" -eq 1 ]; then
            break
        fi
    done

    # The sweep is best-effort and has its own budget: its time must not be charged to the PURGE budget
    # of the databases that come after this one (purge_closed_wisps measures `elapsed` from
    # PURGE_START_EPOCH), or a long drain would starve their purge on every run — and the purge, not the
    # sweep, is what keeps the wisps tables small. Shift the purge clock by the time spent here.
    PURGE_START_EPOCH=$((PURGE_START_EPOCH + SECONDS - sweep_t0))
    ORPHAN_SWEPT=$((ORPHAN_SWEPT + swept_db))
    DB_ORPHANS=$swept_db
    DB_MUTATIONS=$((DB_MUTATIONS + swept_db))
    if [ "$capped" -eq 1 ]; then
        ORPHAN_CAPPED_DBS=$((ORPHAN_CAPPED_DBS + 1))
    fi
    if [ "$failed" -eq 1 ]; then
        ORPHAN_FAILED=$((ORPHAN_FAILED + 1))
    fi
    return 0
}

# ga-hpdpij (header note 7b) — COUNT, never delete, the orphan child rows of every bead store the loop below
# met (a safe name + a `wisps` table), whatever the sweep did (ran, halted by the disk floor or the purge breaker,
# capped, switched off) and even when the reaper SKIPPED the database for its wisp_dependencies schema.
# The sweep only reports what it swept, and its "new producer" alert only fires in a run that finished: with the
# sweep stopped, a return of the orphans was invisible.
#  * BOUNDED: an anti-join with LIMIT cap, cap = ORPHAN_COUNT_ALERT + 1 — index-ordered on issue_id, it stops as
#    soon as it has `cap` orphan rows (the sweep's sample has the same shape: ~0.5 ms per orphan row on the
#    1.9M-row wisp_events, where the same anti-join WITHOUT a limit costs 15-25 s, right at Dolt's 30 s cutoff).
#    cap = alert + 1 keeps both answers exact: a database is over the limit iff its counted sum is > the alert,
#    and a probe that reaches the cap is a LOWER BOUND (the summary says "N+").
#  * THREE STATES: get_sql_count leaves 0 in SQL_COUNT_RESULT for a read that failed; SQL_COUNT_FAILED tells
#    "counted zero" from "could not count". A failed probe — and one this phase's own budget never reached — is
#    UNKNOWN: it never adds to the total and never reads as "no orphans" (get_sql_count already recorded the
#    anomaly of a failed read; a budget cut is recorded below).
#  * Its own budget ($SECONDS: no fork), and it runs AFTER the loop: a slow count must not be charged to the purge
#    budget of the databases after it (selftest C7), and the order's timeout (orders/mol-dog-reaper.toml) covers
#    it (selftest C12).
#  * `wisps` is queried directly by the anti-join: an emptied `wisps` makes every child row an orphan. For the
#    SWEEP that is a reason not to delete; for a count it is simply the truth (and one mail per TTL).
# Sets ORPHAN_COUNT_TEXT: "off" | "unknown" | "N" | "N+" (see header note 7b).
ORPHAN_COUNT_TABLES="wisp_comments wisp_labels wisp_events"   # small tables first, like the sweep
count_orphan_children() {
    local db table cap db_total deadline
    local budget_hit=0

    ORPHAN_COUNT_TEXT="off"
    [ "$ORPHAN_COUNT" = "1" ] || return 0

    cap=$((ORPHAN_COUNT_ALERT + 1))
    deadline=$((SECONDS + ORPHAN_COUNT_BUDGET_S))
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        db_total=0
        for table in $ORPHAN_COUNT_TABLES; do
            if [ "$SECONDS" -ge "$deadline" ]; then
                budget_hit=1
                ORPHAN_COUNT_UNKNOWN=$((ORPHAN_COUNT_UNKNOWN + 1))
                continue
            fi
            # One line on purpose (the selftest targets it by regex); $db passed valid_database_identifier.
            get_sql_count "$db" "orphan $table" "SELECT COUNT(*) FROM (SELECT 1 FROM \`$db\`.$table c WHERE NOT EXISTS (SELECT 1 FROM \`$db\`.wisps w WHERE w.id = c.issue_id) LIMIT $cap) orphan_count_probe"
            if [ "$SQL_COUNT_FAILED" -eq 1 ]; then
                ORPHAN_COUNT_UNKNOWN=$((ORPHAN_COUNT_UNKNOWN + 1))
                continue
            fi
            ORPHAN_COUNT_PROBES=$((ORPHAN_COUNT_PROBES + 1))
            if [ "$SQL_COUNT_RESULT" -ge "$cap" ]; then
                ORPHAN_COUNT_CAPPED=$((ORPHAN_COUNT_CAPPED + 1))
            fi
            db_total=$((db_total + SQL_COUNT_RESULT))
        done
        ORPHAN_COUNT_TOTAL=$((ORPHAN_COUNT_TOTAL + db_total))
        if [ "$db_total" -gt "$ORPHAN_COUNT_ALERT" ]; then
            ORPHAN_COUNT_OVER_DBS=$((ORPHAN_COUNT_OVER_DBS + 1))
            # Stable text, NO counts: the mail dedupe keys on it, so this is sent once per TTL, not every run
            # the number moves. The number is orphan_count in the DOG_DONE line and in the durable log.
            record_anomaly "$db" "more than $ORPHAN_COUNT_ALERT child rows of wisps that no longer exist (orphan_count in the DOG_DONE line): the orphan sweep is not keeping up (stopped, capped or off) or something deletes wisps without their children"
        fi
    done <<EOF
$COUNT_DBS
EOF
    if [ "$budget_hit" -eq 1 ]; then
        record_anomaly "orphans" "the orphan count ran out of its ${ORPHAN_COUNT_BUDGET_S}s budget (GC_REAPER_ORPHAN_COUNT_BUDGET_S): some databases or tables were NOT counted (orphan_count_unknown in the DOG_DONE line)"
    fi

    if [ "$ORPHAN_COUNT_PROBES" -eq 0 ]; then
        ORPHAN_COUNT_TEXT="unknown"                          # nothing was measured
    elif [ "$ORPHAN_COUNT_TOTAL" -eq 0 ] && [ "$ORPHAN_COUNT_UNKNOWN" -gt 0 ]; then
        ORPHAN_COUNT_TEXT="unknown"                          # the zeros that answered do not speak for the probes that did not
    elif [ "$ORPHAN_COUNT_CAPPED" -gt 0 ] || [ "$ORPHAN_COUNT_UNKNOWN" -gt 0 ]; then
        ORPHAN_COUNT_TEXT="${ORPHAN_COUNT_TOTAL}+"           # at least this many
    else
        ORPHAN_COUNT_TEXT="$ORPHAN_COUNT_TOTAL"              # every probe answered and none was capped: exact
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
    # ga-hpdpij (header note 7b): every database that reaches this line has a safe name and a `wisps` table — it is
    # a bead store — so the orphan COUNT that runs after the loop (count_orphan_children) visits it, WHETHER OR NOT
    # the reaper can then work on it. The count reads wisps and wisp_comments / wisp_labels / wisp_events and never
    # wisp_dependencies, so the schema gate just below (which stops the purge and the sweep) has no business
    # stopping the count either: a database the reaper skipped for its schema is exactly one nobody is cleaning
    # (ga-u8nbt9), and leaving it out would print an exact-looking orphan_count over the OTHER databases while this
    # one — the likeliest place for orphans — went unmeasured (repro: 500 orphan events in a schema-skipped
    # database read as orphan_count:0). If its child tables cannot be read either, the probes fail and the count
    # says so (unknown / "N+"); it never says 0. Kept here, not counted here: time spent inside this loop is
    # charged to the purge budget of every later database.
    COUNT_DBS="${COUNT_DBS}${DB}"$'\n'
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

    # Step 2b (ga-x2fj8h): sweep the child rows whose wisp is already gone (see the function).
    sweep_orphan_children "$DB"

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
            CALL DOLT_COMMIT('-Am', 'reaper: stale_wisps=$STALE_WISP_COUNT closed_wisps=$DB_CLOSED_WISPS purged=$DB_PURGED orphans=$DB_ORPHANS stale_issues=$DB_ISSUES_CLOSED expired_issues=$DB_EXPIRED_ISSUES_CLOSED', '--author', 'reaper <reaper@gastown.local>')
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

# ga-hpdpij (header note 7b): the read-only orphan COUNT, after every database's purge and sweep — so it reports
# the orphans LEFT — and whether or not the sweep ran.
count_orphan_children

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

# ga-x2fj8h: the sweep doubles as the orphan DETECTOR. The purge deletes children with their wisp,
# so a steady-state run should find (almost) none; a run that had to sweep more than the threshold
# says so. Stable text (no counts): the mail dedup above then sends it once per TTL — the number
# is in the DOG_DONE summary (orphan_swept).
# Only a run that FINISHED its sweep can be told from a new producer: while the ga-x2fj8h backlog
# drains, every run stops at its row/time budget (orphan_capped_dbs) or a safety rail
# (orphan_halted_dbs) and sweeps far more than the threshold BY DESIGN — mailing each 6 h would
# page the mayor a few times a day for a known, tracked drain. The run that finishes the backlog
# trips it once ("the tail of the backlog"); a new producer trips it every run it outpaces the
# threshold without hitting a budget.
if [ "$ORPHAN_SWEPT" -gt "$ORPHAN_ALERT" ] && [ "$ORPHAN_CAPPED_DBS" -eq 0 ] && [ "$ORPHAN_HALTED_DBS" -eq 0 ]; then
    record_anomaly "orphans" "one run swept more than $ORPHAN_ALERT child rows of wisps that no longer exist without hitting a budget (orphan_swept in the DOG_DONE line): the tail of the ga-x2fj8h backlog, or something still deletes wisps without their children"
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
# ga-x2fj8h: the new counters go BEFORE issue_steps so the tail of the line is unchanged. A chunk
# that failed for good, and a sweep that failed or ran out of budget, are numbers here — the
# 19/09 failure ("error on line 6 ... wisp_events") was only ever in the mail.
# ga-hpdpij: orphan_count* (the orphans LEFT, counted whether or not the sweep ran; "unknown" — never 0 — when
# they could not be counted; header note 7b) go there too, right after orphan_halted_dbs.
SUMMARY="reaper — stale_wisps:$TOTAL_STALE_WISPS, closed_wisps:$TOTAL_CLOSED_WISPS, purged:$TOTAL_PURGED, sessions-pruned:$TOTAL_SESSIONS_PRUNED, closed:$TOTAL_ISSUES_CLOSED, expired:$TOTAL_EXPIRED_ISSUES_CLOSED, expired_skipped:$TOTAL_EXPIRED_ISSUES_SKIPPED, skipped_non_city_issues:$TOTAL_STALE_ISSUES_SKIPPED, mail_wisps:$TOTAL_MAIL_WISPS, purge_age_h:$PURGE_AGE_H, purge_batches:$PURGE_BATCHES, purge_capped_dbs:$PURGE_CAPPED_DBS, purge_failed_chunks:$PURGE_FAILED_CHUNKS, purge_child_rows:$PURGE_CHILD_ROWS, orphan_swept:$ORPHAN_SWEPT, orphan_capped_dbs:$ORPHAN_CAPPED_DBS, orphan_failed_dbs:$ORPHAN_FAILED, orphan_halted_dbs:$ORPHAN_HALTED_DBS, orphan_count:$ORPHAN_COUNT_TEXT, orphan_count_unknown:$ORPHAN_COUNT_UNKNOWN, orphan_count_over_dbs:$ORPHAN_COUNT_OVER_DBS, schema_skipped_dbs:$SCHEMA_SKIPPED_DBS, issue_steps:$ISSUE_STEPS_STATE, anomalies:$ANOMALY_COUNT"
if [ -n "$DRY_RUN" ]; then
    SUMMARY="$SUMMARY, would_close_wisps:$TOTAL_WOULD_CLOSE_WISPS, would_expire:$TOTAL_WOULD_EXPIRE, would_purge:$TOTAL_WOULD_PURGE, would_sweep:$TOTAL_WOULD_SWEEP (dry run)"
fi
# The cause, when a statement gave up for good (short, comma-free; the mail carries the full text).
if [ -n "$PURGE_LAST_ERROR" ]; then
    SUMMARY="$SUMMARY, last_error: $PURGE_LAST_ERROR"
fi
# Why a safety rail cut the orphan sweep short (short, comma-free; halted dbs are counted above).
if [ -n "$ORPHAN_HALT_REASON" ]; then
    SUMMARY="$SUMMARY, orphan_halt: $ORPHAN_HALT_REASON"
fi

# ga-hpdpij (header note 7a): the durable copy of the line the deacon is nudged with — the nudge below is
# `|| true` and lands nowhere anyone can grep. ONE line per run: UTC timestamp + the exact summary. Rotated by
# size (SUMMARY_LOG_MAX_BYTES), SUMMARY_LOG_KEEP generations. Returns 0 = written and, if it was due, rotated;
# 1 = could not write; 2 = WRITTEN, but the size cap could not be enforced (the size was unreadable, or the live
# file could not be moved aside): nothing is lost, the file just keeps growing — the caller says so.
# `set -e` is ignored inside a function called from an `if`, so every step that can fail says `|| return 1` itself.
append_summary_log() {  # append_summary_log <line>
    local line="$1" bytes i capped=1
    mkdir -p "$(dirname "$SUMMARY_LOG")" 2>/dev/null || return 1
    if [ -f "$SUMMARY_LOG" ]; then
        bytes=$(wc -c < "$SUMMARY_LOG" 2>/dev/null | tr -d ' ') || bytes=""
        if ! [[ "$bytes" =~ ^[0-9]+$ ]]; then
            capped=0    # the size is unknown: not rotating is the inert choice, but not a silent one
        elif [ "$bytes" -ge "$SUMMARY_LOG_MAX_BYTES" ]; then
            # .N is dropped, .(N-1) -> .N ... .1 -> .2, the live file -> .1
            i=$SUMMARY_LOG_KEEP
            rm -f "$SUMMARY_LOG.$i" 2>/dev/null || true
            while [ "$i" -gt 1 ]; do
                if [ -f "$SUMMARY_LOG.$((i - 1))" ]; then
                    mv -f "$SUMMARY_LOG.$((i - 1))" "$SUMMARY_LOG.$i" 2>/dev/null || true
                fi
                i=$((i - 1))
            done
            mv -f "$SUMMARY_LOG" "$SUMMARY_LOG.1" 2>/dev/null || capped=0   # only THIS move enforces the cap
        fi
    fi
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$SUMMARY_LOG" 2>/dev/null || return 1
    [ "$capped" -eq 1 ] || return 2
    return 0
}
# A log that cannot be written must not fail the run — the reaper's real work is done — but it must not be
# silent either (that is the gap this fixes): the nudge and the stdout line below say so. So does a log that WAS
# written but could not be size-capped (summary_log:UNCAPPED). The line itself, written first, cannot carry
# either word: they describe the write.
SUMLOG_RC=0
append_summary_log "$SUMMARY" || SUMLOG_RC=$?
case "$SUMLOG_RC" in
    0) ;;
    2) SUMMARY="$SUMMARY, summary_log:UNCAPPED" ;;
    *) SUMMARY="$SUMMARY, summary_log:FAILED" ;;
esac

gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
echo "reaper: $SUMMARY"

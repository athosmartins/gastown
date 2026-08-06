#!/usr/bin/env bash
# mol-dog-doctor — probe Dolt server health and report findings.
#
# Replaces mol-dog-doctor formula. All checks are read-only: SQL probe,
# PROCESSLIST count, disk usage, orphan DB detection, backup artifact freshness.
# No LLM judgment needed — runs inline in the controller.
#
# Runs as an exec order (no LLM, no agent, no wisp).
#
# town-deltas override (ga-3wdlv/ga-v6y3p): the embedded default BACKUP_STALE_S
# (43200s = 12h, "2x 6h backup interval") assumes backups run every 6h. This
# city's actual per-DB backup artifacts (.dolt-backup/<db>/) are refreshed by a
# bespoke ONCE-DAILY job (dolt-s3-backup.sh via com.gascity.dolt-s3-backup.plist,
# 04:00 local) — so every DB naturally shows ~19-23h old for most of the day,
# tripping the old 12h threshold and paging the Mayor hourly with an identical
# false-positive "Dolt health advisory [MEDIUM]" (5 copies landed in one night —
# see ga-3wdlv). Raised to 108000s (30h): covers the real ~24h cadence plus a
# ~6h margin for one missed/delayed run before actually alarming, per the bug's
# own suggested 26-30h window. Script vendored into town-deltas/assets for this
# override (same recipe as gate-sweep's / mol-dog-backup's ga-gquc1 fix).
# runtime.sh itself is NOT vendored here — it further sources port_resolve.sh
# and is a ~200-line dependency not worth duplicating/drifting — it's sourced
# live from the dolt pack's engine-materialized copy via GC_CITY_PATH instead
# (a self-relative $PACK_DIR here resolves under town-deltas once vendored, and
# no runtime.sh was ever copied there — the exact ga-gquc1 attempt-1 bootstrap
# crash this recipe is known to cause if skipped).
set -euo pipefail

: "${GC_CITY_PATH:?GC_CITY_PATH must be set}"
# ga-v75ka: engine exports GC_PACK_DIR=town-deltas (the pack owning this order),
# but runtime.sh:209 trusts GC_PACK_DIR to find its sibling port_resolve.sh —
# override it to dolt's own pack dir for this source, or the dog dies on boot.
GC_PACK_DIR="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt" \
    . "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh"
# ga-br5sw: ms-resolution now_ms()/latency_should_warn() — see latency.sh's own
# header for why whole-second `date +%s` quantizes a sub-second probe to 0s/1s.
# Same live-sourcing rationale as runtime.sh above (not vendored, so both stay
# in lockstep with the dolt pack's copy instead of drifting independently).
. "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/latency.sh"

PORT="$GC_DOLT_PORT"
HOST="${GC_DOLT_HOST:-127.0.0.1}"
USER="${GC_DOLT_USER:-root}"
# ga-br5sw (2ª regressão desta classe — ga-ouqtg foi a 1ª, fechada 52 dias
# antes): default 1s -> 5s. Com 1s + medição em segundo inteiro (ver
# PROBE_START_MS/PROBE_END_MS abaixo), qualquer sondagem sub-segundo que
# cruzasse o tick do relógio arredondava para 1s e disparava o WARN —
# inundou a inbox do Mayor a cada 5min com "Dolt health advisory [MEDIUM]"
# mesmo com o Dolt saudável (latência real medida: 84-272ms). 5s continua
# pegando degradação real sem inundar. Medido em ms (não segundo inteiro)
# via latency.sh logo abaixo — mol-dog-doctor.selftest.sh fixa as duas
# garantias para que essa classe de regressão pare de voltar sem detector.
LATENCY_WARN_S="${GC_DOCTOR_LATENCY_WARN_S:-5}"
# ga-ood0l: CONN_MAX has no hardcoded numeric default anymore. The old literal
# (50) drifted from this town's real max_connections (256, set outside this
# script by the city's server-start tooling) and stayed wrong for months —
# false WARN at healthy usage (42 connections = 16% of the real cap), and,
# worse, a numerically absurd "410% of max 50" right when a real exhaustion
# needed to be believed. Resolved from the live server in Step 2 below
# (SELECT @@max_connections — the same variable used to measure the real cap
# by hand while diagnosing this bug); only an explicit GC_DOCTOR_CONN_MAX
# override skips that query. If neither is available, CONN_COUNT is still
# reported but no WARN is ever emitted for it (displayed as "N/unknown", see
# CONN_MAX_DISPLAY) — never a second guessed literal standing in for the first.
CONN_MAX="${GC_DOCTOR_CONN_MAX:-}"
CONN_WARN_PCT="${GC_DOCTOR_CONN_WARN_PCT:-80}"
BACKUP_STALE_S="${GC_DOCTOR_BACKUP_STALE_S:-108000}"  # 30h: this city's backup runs once/day at 04:00 (dolt-s3-backup.sh), not every 6h — see override comment above (ga-3wdlv)
BACKUP_ARTIFACT_DIR="${GC_BACKUP_ARTIFACT_DIR:-$GC_CITY_PATH/.dolt-backup}"

dolt_sql() {
    DOLT_CLI_PASSWORD="${GC_DOLT_PASSWORD:-}" \
        run_bounded 10 \
        dolt --host "$HOST" --port "$PORT" --user "$USER" --no-tls sql "$@"
}

file_mtime() {
    file_path="$1"
    file_mtime_value=$(stat -c %Y "$file_path" 2>/dev/null \
        || stat -f %m "$file_path" 2>/dev/null || echo "0")
    case "$file_mtime_value" in
        ''|*[!0-9]*) file_mtime_value=0 ;;
    esac
    printf '%s\n' "$file_mtime_value"
}

backup_path_matches_db() {
    db_name="$1"
    backup_rel_path="$2"
    case "$backup_rel_path" in
        "$db_name"|"$db_name"/*|"$db_name".*|"$db_name"-*|*"/$db_name"|*"/$db_name"/*|*"/$db_name".*|*"/$db_name"-*)
            return 0
            ;;
    esac
    return 1
}

newest_backup_mtime_for_db() {
    db_name="$1"
    newest_mtime=0
    while IFS= read -r -d '' backup_path; do
        backup_rel_path="${backup_path#$BACKUP_ARTIFACT_DIR/}"
        if backup_path_matches_db "$db_name" "$backup_rel_path"; then
            backup_mtime=$(file_mtime "$backup_path")
            if [ "$backup_mtime" -gt "$newest_mtime" ]; then
                newest_mtime="$backup_mtime"
            fi
        fi
    done < <(find "$BACKUP_ARTIFACT_DIR" -type f -print0 2>/dev/null)
    printf '%s\n' "$newest_mtime"
}

append_backup_stale() {
    backup_stale_item="$1"
    if [ -n "$BACKUP_STALE_ITEMS" ]; then
        BACKUP_STALE_ITEMS="$BACKUP_STALE_ITEMS, $backup_stale_item"
    else
        BACKUP_STALE_ITEMS="$backup_stale_item"
    fi
}

send_mayor_mail() {
    local mail_err
    if ! mail_err=$(gc mail send mayor/ --from controller "$@" 2>&1 >/dev/null); then
        if [ -n "$mail_err" ]; then
            echo "doctor: mail send failed: $mail_err" >&2
        else
            echo "doctor: mail send failed" >&2
        fi
        return 1
    fi
}

# ── PURE decision logic — is it safe to nudge the deacon? (ga-clgc2) ──
# Nudging a suspended agent queues forever: the recipient never wakes to
# consume it, and every `gc nudge poll` iteration reloads the ENTIRE queue
# state regardless of size — 379 such DOG_DONE nudges to a 20-day-asleep,
# suspended deacon dominated Dolt poll load (48-58% of total load across 3
# measurements — see ga-clgc2). deacon's `suspended` flag (city.toml) is the
# same authoritative signal `gc agent list`/`gc agent suspend` already read
# and write. Fail-CLOSED by construction: only the literal string "false"
# allows the nudge — empty/unknown/garbage input (lookup failure, deacon not
# found) is treated as suspended and skipped, never guessed-open. This lives
# in the pure function itself (not just the caller's fallback) so the safety
# invariant holds regardless of how deacon_nudge_allowed() gets called.
# Unit-tested by mol-dog-doctor.selftest.sh.
deacon_nudge_allowed() {
    local suspended_flag="$1"
    [ "$suspended_flag" = "false" ]
}

# nudge_deacon_done <message> — best-effort DOG_DONE status ping, sent ONLY
# when deacon can actually consume it. `gc agent list --json` is a static
# city.toml read (no Dolt round-trip, ~0.1-0.2s) — cheap enough for every dog
# run. Any lookup failure (gc/jq error, deacon not found) fails CLOSED
# (treated as suspended, nudge skipped) — the same "when in doubt, don't
# queue forever" bias as the rest of this fix. Skip is logged to stderr:
# visible, not the old `2>/dev/null || true` silent swallow (ga-clgc2 AC2).
nudge_deacon_done() {
    local message="$1" suspended
    suspended=$(gc agent list --json 2>/dev/null \
        | jq -r '.agents[]? | select(.qualified_name=="gastown.deacon") | .suspended' 2>/dev/null \
        | head -1 || echo "true")
    if ! deacon_nudge_allowed "${suspended:-true}"; then
        echo "doctor: skipped DOG_DONE nudge to deacon (suspended=${suspended:-unknown}) — $message" >&2
        return 0
    fi
    gc session nudge deacon/ "$message" 2>/dev/null || true
}

# conn_should_warn <count> <max> <warn_pct> — pure predicate: true (0) once
# connection usage has crossed warn_pct of max. Isolated so a test can inject
# max values the old hardcoded 50 never exercised (e.g. 256, 1000) — a test
# that only ever checks max=50 can't tell "reads the live cap" from "silently
# stayed hardcoded" (ga-ood0l). An empty/non-numeric max means "unmeasured":
# never warn on a cap we don't actually know — a guessed cap presented as
# measured is the bug this replaces, not a safe fallback.
conn_should_warn() {
    local count="$1" max="$2" warn_pct="$3"
    case "$max" in
        ''|*[!0-9]*) return 1 ;;
    esac
    local warn_at=$(( (max * warn_pct) / 100 ))
    [ "${count:-0}" -ge "$warn_at" ]
}

# --- Step 1: Probe connectivity and measure latency ---

PROBE_START_MS=$(now_ms)
if ! dolt_sql -q "SELECT active_branch()" >/dev/null 2>&1; then
    if send_mayor_mail \
        -s "ESCALATION: Dolt server unreachable on port $PORT [CRITICAL]" \
        -m "Doctor probe failed: server did not respond to active_branch() query."; then
        nudge_deacon_done "DOG_DONE: doctor — server: UNREACHABLE (escalated)"
        echo "doctor: server unreachable on port $PORT (escalated)"
    else
        nudge_deacon_done "DOG_DONE: doctor — server: UNREACHABLE (mail failed)"
        echo "doctor: server unreachable on port $PORT (mail failed)"
    fi
    exit 0
fi
PROBE_END_MS=$(now_ms)
LATENCY_MS=$((PROBE_END_MS - PROBE_START_MS))
LATENCY_WARN_MS=$((LATENCY_WARN_S * 1000))
LATENCY_WARN=""
if latency_should_warn "$LATENCY_MS" "$LATENCY_WARN_MS"; then
    LATENCY_WARN=" [WARN: latency ${LATENCY_MS}ms >= threshold ${LATENCY_WARN_MS}ms]"
fi

# --- Step 2: Check resource conditions ---

if [ -z "$CONN_MAX" ]; then
    CONN_MAX=$(dolt_sql -r csv -q "SELECT @@max_connections" 2>/dev/null | tail -1 || true)
    case "$CONN_MAX" in
        ''|*[!0-9]*) CONN_MAX="" ;;
    esac
fi
CONN_MAX_DISPLAY="${CONN_MAX:-unknown}"

CONN_COUNT=$(dolt_sql -r csv -q "SELECT COUNT(*) FROM information_schema.PROCESSLIST" 2>/dev/null \
    | tail -1 || echo "0")
CONN_WARN=""
if conn_should_warn "$CONN_COUNT" "$CONN_MAX" "$CONN_WARN_PCT"; then
    CONN_WARN=" [WARN: ${CONN_COUNT} connections >= ${CONN_WARN_PCT}% of max ${CONN_MAX}]"
fi

# Disk usage of Dolt data directory.
DISK_USAGE=$(du -sh "$DOLT_DATA_DIR" 2>/dev/null | cut -f1 || echo "unknown")

# Orphan database detection.
ALL_DBS=$(dolt_sql -r csv -q "SHOW DATABASES" 2>/dev/null | tail -n +2 || true)
SYSTEM_DBS="^(information_schema|mysql|dolt_cluster|__gc_probe|performance_schema|sys)$"
USER_DBS=$(printf '%s\n' "$ALL_DBS" | grep -viE "$SYSTEM_DBS" || true)
# ga-fwzg4: delegate the orphan COUNT to `gc dolt-cleanup` (hyphen) itself —
# the prefix-gated, dry-run-by-default tool this advisory tells the reader to
# run — instead of a local regex. The prior inline pattern here was a second,
# independently-maintained definition of "orphan" (dolt-cleanup's Go
# classifier uses more prefixes, a hex-suffix check on beads_t, and excludes
# anything in the live rig registry) that had already drifted: this advisory
# reported 1 orphan while `gc dolt-cleanup` found 0 for the same server.
# Delegating makes the two impossible to disagree. Bounded like dolt_sql
# above — dolt-cleanup queries the live server too, so a wedged Dolt must not
# hang this script either. Any failure (timeout, or a run whose "ok":true
# still carries a connect error in summary.errors_total — confirmed live: a
# refused connection reports ok:true with dropped.count:0 and the failure
# surfaced only in summary.errors_total/errors, per dolt-cleanup's own
# --help note that automation must inspect errors_total, not just ok)
# reports "unknown" rather than a guessed 0 — an unmeasured count must
# never look like a measured all-clear (mirrors CONN_MAX "unknown" above).
ORPHAN_JSON=$(run_bounded 10 gc dolt-cleanup --json --city "$GC_CITY_PATH" --port "$PORT" 2>/dev/null || true)
ORPHAN_OK=$(printf '%s' "$ORPHAN_JSON" | jq -r 'if (.ok == true) and ((.summary.errors_total // 1) == 0) then "true" else "false" end' 2>/dev/null || echo false)
if [ "$ORPHAN_OK" = "true" ]; then
    ORPHAN_COUNT=$(printf '%s' "$ORPHAN_JSON" | jq -r '.dropped.count // 0' 2>/dev/null)
    case "$ORPHAN_COUNT" in ''|*[!0-9]*) ORPHAN_COUNT="" ;; esac
else
    ORPHAN_COUNT=""
fi
ORPHAN_COUNT_DISPLAY="${ORPHAN_COUNT:-unknown}"
ORPHAN_WARN=""
if [ -n "$ORPHAN_COUNT" ] && [ "$ORPHAN_COUNT" -gt 0 ]; then
    ORPHAN_WARN=" [WARN: $ORPHAN_COUNT orphan DBs detected — run gc dolt-cleanup]"
fi

# Backup freshness: check newest backup artifact per database.
# Scope mirrors mol-dog-backup.sh: only DBs with a configured <db>-backup
# remote are eligible. Cities with user DBs but no backup remotes
# (legitimate config) must not get false stale-backup alarms.
BACKUP_ELIGIBLE_DBS=""
for db in $USER_DBS; do
    db_dir="$DOLT_DATA_DIR/$db"
    if [ -d "$db_dir/.dolt" ]; then
        if (cd "$db_dir" && dolt backup 2>/dev/null | awk '{print $1}' | grep -qx "${db}-backup"); then
            BACKUP_ELIGIBLE_DBS="$BACKUP_ELIGIBLE_DBS $db"
        fi
    fi
done
BACKUP_ELIGIBLE_DBS=$(printf '%s\n' "$BACKUP_ELIGIBLE_DBS" | tr ' ' '\n' | grep -v '^$' || true)

BACKUP_STALE=""
if [ -n "$BACKUP_ELIGIBLE_DBS" ]; then
    if [ ! -d "$BACKUP_ARTIFACT_DIR" ]; then
        BACKUP_STALE=" [WARN: backup artifact dir missing]"
    else
        BACKUP_STALE_ITEMS=""
        NOW_S=$(date +%s)
        for db in $BACKUP_ELIGIBLE_DBS; do
            NEWEST_BACKUP_MTIME=$(newest_backup_mtime_for_db "$db")
            if [ "$NEWEST_BACKUP_MTIME" -le 0 ]; then
                append_backup_stale "$db backup missing"
                continue
            fi
            BACKUP_AGE=$((NOW_S - NEWEST_BACKUP_MTIME))
            if [ "$BACKUP_AGE" -gt "$BACKUP_STALE_S" ]; then
                append_backup_stale "$db backup is $((BACKUP_AGE / 3600))h old"
            fi
        done
        if [ -n "$BACKUP_STALE_ITEMS" ]; then
            BACKUP_STALE=" [WARN: backup freshness: $BACKUP_STALE_ITEMS]"
        fi
    fi
fi

# --- Step 3: Compose report and escalate if critical ---

WARNINGS="${LATENCY_WARN}${CONN_WARN}${ORPHAN_WARN}${BACKUP_STALE}"
if [ -n "$WARNINGS" ]; then
    if ! send_mayor_mail \
        -s "Dolt health advisory [MEDIUM]" \
        -m "Latency: ${LATENCY_MS}ms${LATENCY_WARN}
Connections: ${CONN_COUNT}/${CONN_MAX_DISPLAY}${CONN_WARN}
Disk: ${DISK_USAGE}
Orphan DBs: ${ORPHAN_COUNT_DISPLAY}${ORPHAN_WARN}${BACKUP_STALE}"; then
        :
    fi
fi

SUMMARY="doctor — server: ok, latency: ${LATENCY_MS}ms, conns: ${CONN_COUNT}/${CONN_MAX_DISPLAY}, disk: ${DISK_USAGE}, orphans: ${ORPHAN_COUNT_DISPLAY}"
nudge_deacon_done "DOG_DONE: $SUMMARY"
echo "doctor: $SUMMARY"

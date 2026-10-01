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
# ga-5a87qv: `.`/source is a POSIX special builtin — under this file's
# `set -euo pipefail` (L27), a missing/unreadable target kills the shell
# immediately, before any log/warn call exists (same defect class ga-q4sadt
# fixed for the core gate/dispatch pipeline). Check readability BEFORE
# sourcing instead — deliberately ONE line (`[ -r ] && ... || true`, same
# shape as quality-gate-dispatcher.sh's git-lock-hygiene.sh source), not an
# `if/fi` block: the real-bootstrap selftest below locates this source line
# by line number (grep -n) and truncates the file there with `head -n` to
# execute a live snippet — a multi-line if/fi would get cut mid-block and
# fail with a bash syntax error. Single line also keeps the GC_CITY_PATH-
# anchored literal directly on the `.` line for the drift-guard greps below,
# guarding against a regression back to the self-relative $PACK_DIR that
# caused ga-gquc1's attempt-1 bootstrap crash.
[ -r "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh" ] && GC_PACK_DIR="${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt" . "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/runtime.sh" || true
# ga-5a87qv (gate FAIL, run ga-zpj88y): surviving a missing runtime.sh is not
# enough on its own — dolt_sql() below calls run_bounded (defined ONLY in
# runtime.sh), and dolt_sql is invoked as `if ! dolt_sql ...; then` further
# down, which is a set -e EXEMPTED context. An undefined run_bounded there
# doesn't crash — "command not found" (exit 127) reads as "dolt_sql failed",
# and the script proceeds into the Dolt-unreachable branch: a FALSE CRITICAL
# escalation mailed to the Mayor ("Dolt server unreachable") for a problem
# that was actually a missing sibling script, never a Dolt query. That is
# WORSE than the pre-fix crash (which at least died honestly, right at this
# source line, with no misattributed mail) — this guard's whole point was to
# avoid a worse failure mode, not manufacture one further downstream. Check
# the symbol the rest of this script actually depends on, not just whether
# the source line itself survived.
command -v run_bounded >/dev/null 2>&1 || {
  echo "FATAL: runtime.sh failed to load (missing/unreadable sibling — a partial/desynced deploy of the dolt pack, NOT a Dolt server problem) — run_bounded is undefined, dolt_sql() cannot run safely. See ga-5a87qv." >&2
  exit 1
}
# ga-br5sw: ms-resolution now_ms()/latency_should_warn() — see latency.sh's own
# header for why whole-second `date +%s` quantizes a sub-second probe to 0s/1s.
# Same live-sourcing rationale as runtime.sh above (not vendored, so both stay
# in lockstep with the dolt pack's copy instead of drifting independently).
# ga-5a87qv: same source-guard reasoning and one-line-for-head-truncation
# constraint as runtime.sh above.
[ -r "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/latency.sh" ] && . "${GC_SYSTEM_PACKS_DIR:-$GC_CITY_PATH/.gc/system/packs}/dolt/assets/scripts/latency.sh" || true
# ga-5a87qv: same reasoning as the run_bounded check above — now_ms() is
# called unconditionally at PROBE_START_MS=$(now_ms) below, OUTSIDE any
# set -e-exempted context, so an undefined now_ms WOULD crash there — but
# with a bare "command not found" pointing at the wrong line, not a message
# that names the actual missing dependency. Fail loud and correctly here
# instead of letting that happen a few lines down.
command -v now_ms >/dev/null 2>&1 || {
  echo "FATAL: latency.sh failed to load (missing/unreadable sibling — a partial/desynced deploy of the dolt pack, NOT a Dolt server problem) — now_ms is undefined, cannot measure probe latency. See ga-5a87qv." >&2
  exit 1
}

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
# ga-gqllbc: a db with EPHEMERAL local staging (dolt-backup-ephemeral-lib.sh; default hq) has no
# local artifacts BY DESIGN — its backup lives in S3 — so "no artifacts under BACKUP_ARTIFACT_DIR"
# must not read as "backup missing". Its freshness is read from S3's run fingerprint instead (see the
# freshness loop below). A missing lib is "nothing is ephemeral": the old, louder behaviour (hq would
# warn as missing), never a silently skipped db.
EPH_LIB="${DOLT_BACKUP_EPHEMERAL_LIB:-$GC_CITY_PATH/scripts/dolt-backup-ephemeral-lib.sh}"
export DOLT_BACKUP_EPHEMERAL_CONF="${DOLT_BACKUP_EPHEMERAL_CONF:-$GC_CITY_PATH/.gc/config/dolt-backup-ephemeral.env}"
AWS="${GC_DOCTOR_AWS:-$(command -v aws || echo /opt/homebrew/bin/aws)}"
BUCKET="${GC_DOCTOR_S3_BUCKET:-urblink-dolt-backups}"
S3PROOF_TIMEOUT="${GC_DOCTOR_S3_TIMEOUT_S:-20}"   # one small `aws s3 cp` of _meta/latest.json, bounded well under DOCTOR_BUDGET_S
if [ -r "$EPH_LIB" ]; then
    # shellcheck disable=SC1090
    . "$EPH_LIB"
fi
# ga-2uz59: the MEDIUM advisory below used to mail on every single 5-minute
# cycle the condition held, with no dedup at all — 85 identical "Dolt health
# advisory [MEDIUM]" mails landed in the Mayor's inbox in ~10h30, burying 8
# distinct real signals (including a P0) in the noise. Same per-condition
# cooldown-state-file pattern as gate-orphaned-label-watchdog.sh
# (GOLW_ALERT_COOLDOWN_S=21600, "re-alerts for an already-flagged bead are
# suppressed for N seconds") — same 6h default, same $HOME/.gastown/state
# directory, different filename so the two never collide.
GC_DOCTOR_STATE_DIR="${GC_DOCTOR_STATE_DIR:-$HOME/.gastown/state}"
STATE_FILE="${GC_DOCTOR_STATE_FILE:-$GC_DOCTOR_STATE_DIR/mol-dog-doctor.state.json}"
ADVISORY_COOLDOWN_S="${GC_DOCTOR_ADVISORY_COOLDOWN_S:-21600}"  # 6h — matches the two cited town precedents (ga-2uz59)
# ga-29lbag: this order declares `timeout = "300s"` (mol-dog-doctor.toml). A run that overshoots is
# killed by the engine and reports nothing, so the per-database loop below stops STARTING new
# databases once the script has been running DOCTOR_BUDGET_S and lists the rest as "not measured"
# instead. 200s leaves 100s for the tail (report + deacon ping) even when a single step runs to
# its own STEP_TIMEOUT_S. Measured 30/09: the old probe was still running after 175s at load 40-80
# (traced) when it died; the fixed one takes ~7s untraced at load ~38 (107s under xtrace at load 81).
DOCTOR_BUDGET_S="${GC_DOCTOR_BUDGET_S:-200}"
STEP_TIMEOUT_S="${GC_DOCTOR_STEP_TIMEOUT_S:-10}"

dolt_sql() {
    DOLT_CLI_PASSWORD="${GC_DOLT_PASSWORD:-}" \
        run_bounded "$STEP_TIMEOUT_S" \
        dolt --host "$HOST" --port "$PORT" --user "$USER" --no-tls sql "$@"
}

# ga-29lbag: a step that could not be measured must say so, never read as a clean value.
# Items are listed in the report, the log summary and the DOG_DONE ping (see UNMEASURED_NOTE).
UNMEASURED_ITEMS=""
append_unmeasured() {
    if [ -n "$UNMEASURED_ITEMS" ]; then
        UNMEASURED_ITEMS="$UNMEASURED_ITEMS, $1"
    else
        UNMEASURED_ITEMS="$1"
    fi
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

# newest_backup_mtime_for_db <db_name> — epoch seconds of the newest artifact under
# BACKUP_ARTIFACT_DIR whose path matches <db_name>; 0 when nothing matches or nothing is readable.
#
# ga-29lbag: the paths are matched in pure bash and their mtimes read with ONE `stat` for the whole
# match set. This used to fork a subshell plus one or two `stat`s PER matching file, and a fork
# costs 0.1-0.2s at this city's typical load (~40): hq's backup dir holds ~250 files, so hq alone
# took 83s and the eight databases ~103s together (untraced, load ~40, measured live 30/09) — by far
# the largest share of the probe. The same scan is 2.6s for hq after this change, with identical
# answers on all 8 databases. A file that vanishes between `find` and `stat` just drops out of the batch.
newest_backup_mtime_for_db() {
    db_name="$1"
    newest_mtime=0
    local -a matched_paths=()
    while IFS= read -r -d '' backup_path; do
        backup_rel_path="${backup_path#$BACKUP_ARTIFACT_DIR/}"
        if backup_path_matches_db "$db_name" "$backup_rel_path"; then
            matched_paths+=("$backup_path")
        fi
    done < <(find "$BACKUP_ARTIFACT_DIR" -type f -print0 2>/dev/null)
    if [ "${#matched_paths[@]}" -gt 0 ]; then
        # GNU form first, BSD/macOS form when the first prints nothing (unsupported flag).
        matched_mtimes=$(stat -c %Y "${matched_paths[@]}" 2>/dev/null) || true
        if [ -z "$matched_mtimes" ]; then
            matched_mtimes=$(stat -f %m "${matched_paths[@]}" 2>/dev/null) || true
        fi
        while IFS= read -r backup_mtime; do
            case "$backup_mtime" in
                ''|*[!0-9]*) continue ;;
            esac
            if [ "$backup_mtime" -gt "$newest_mtime" ]; then
                newest_mtime="$backup_mtime"
            fi
        done <<< "$matched_mtimes"
    fi
    printf '%s\n' "$newest_mtime"
}

# db_last_commit_epoch <db_name> — live query, epoch seconds of the db's newest
# commit on any branch (integer; CAST ... AS SIGNED drops the sub-second fraction
# a ms-precision `date` column carries, which bash's integer `-le`/`-gt`
# tests below cannot parse). Empty output on any failure (unreachable
# server, missing db) — dolt_sql() is already bounded, and stderr is
# discarded same as every other dolt_sql call in this script.
#
# ga-gh8mb: uses TIMESTAMPDIFF(SECOND, epoch, date), NOT UNIX_TIMESTAMP(date).
# The commit date (dolt_log.date then, dolt_branches.latest_commit_date now — same UTC value, see
# ga-29lbag below) is already UTC, but UNIX_TIMESTAMP() interprets a naive
# datetime string as being in the SESSION's time zone (@@time_zone=SYSTEM,
# which on this city's server resolves to @@system_time_zone=-03) and
# converts it to epoch from there — double-converting an already-UTC value
# and adding a spurious +10800s (3h). That inflated "last commit epoch" past
# an already-current backup's mtime, making backup_should_warn() think an
# ALREADY-CAPTURED commit was newer than the backup (proven false by
# `dolt backup restore` on the live staging dir showing the identical HEAD),
# which fell through into the age-only branch and grew a "backup is Nh old"
# alarm forever for a backup that was never behind. TIMESTAMPDIFF computes a
# pure calendar difference against a literal UTC epoch with no session-tz
# reinterpretation, so it is correct regardless of @@system_time_zone.
#
# ga-29lbag (the chronic `exit status 124`, 48 runs in 6 days): two defects lived in this function.
#  1. `ORDER BY date DESC` forces Dolt to read and sort the db's WHOLE commit history. hq gets a
#     commit per bd write; measured 30/09 (load 40-80), that query took 31s on hq and the server
#     aborted it ("row read wait bigger than connection timeout") — three times the 10s step bound,
#     so a 124 whenever it is that slow (48 runs in 6 days did not get through). The answer now comes
#     from dolt_branches (one row per branch, so tiny whatever the history size): the newest
#     latest_commit_date over ALL branches. A first attempt used `dolt_log ... LIMIT 1`, which is
#     fast but leans on dolt_log returning HEAD first — an ordering SQL does not promise, and if it
#     ever handed back an older commit, `last_commit <= backup_mtime` would SUPPRESS a real stale-
#     backup alarm (the dangerous direction). MAX() does not depend on row order, and a branch we
#     did not expect can only make the value newer, i.e. bias toward warning, never toward silence.
#     Measured 30/09 (load ~30): the same epoch as `dolt_log LIMIT 1` on all 8 databases (hq,
#     whatsapp_automation, gastown, dc, lexbh, marketing, property_scrapers, beads), ~1s each
#     including the CLI start-up, and dolt_branches.latest_commit_date is UTC like dolt_log.date, so
#     the ga-gh8mb TIMESTAMPDIFF form below stays correct.
#  2. The docblock promised "Empty output on any failure", but the old body was a bare pipeline:
#     under this script's `set -eo pipefail` a timed-out dolt_sql (run_bounded exit 124) made the
#     FUNCTION return 124, and the caller's plain `DB_LAST_COMMIT_EPOCH=$(...)` assignment then
#     killed the whole probe with that 124. Failure is now swallowed here and yields empty, which
#     backup_should_warn() already treats as "unmeasured" (falls back to the age-only check) — the
#     one failing query no longer takes the other seven databases and every later step with it.
db_last_commit_epoch() {
    db_name="$1"
    local epoch=""
    epoch=$(dolt_sql -r csv -q "SELECT CAST(TIMESTAMPDIFF(SECOND, '1970-01-01 00:00:00', MAX(latest_commit_date)) AS SIGNED) FROM \`$db_name\`.dolt_branches" 2>/dev/null | tail -1) || epoch=""
    case "$epoch" in
        ''|*[!0-9]*) epoch="" ;;
    esac
    printf '%s\n' "$epoch"
    return 0
}

# backup_should_warn <backup_mtime> <now_s> <stale_s> <db_last_commit_epoch>
# Pure predicate (ga-ddwyw) — unit-tested by mol-dog-doctor.selftest.sh.
#
# CALL DOLT_BACKUP('sync') is INCREMENTAL: with no new commit since the last
# sync there is nothing to push, so it reports OK and writes zero bytes — the
# backup artifact's mtime never advances. An idle db (no writes for days) was
# therefore ALARMING FOREVER, every cycle, forever unresolvable by construction
# — the age-vs-now check answered "when did we last write the backup file",
# never "is the backup caught up with the source", the only question that
# actually matters. Measured live: 7 of 12 city databases stale by this
# definition in one report, each idle (not broken) — see ga-ddwyw.
#
# Fix: a backup with no db commit newer than itself is fully current NO MATTER
# HOW OLD its mtime is — skip straight to "not stale" (return 1). Only once
# there IS a newer commit does elapsed time matter at all, and then the
# age-vs-now-vs-threshold check is exactly what ran before this fix.
#
# db_last_commit_epoch empty/non-numeric (the live query failed — transient
# Dolt hiccup, not "definitely no newer commit") falls through to the
# age-only check instead of silently clearing the warning: an unmeasured
# commit-recency must never LOOK LIKE a measured all-clear (same "erro e
# vazio nao podem produzir o mesmo valor" discipline as CONN_MAX/ORPHAN_COUNT
# elsewhere in this script) — only a positively measured "no newer commit"
# may suppress the alarm.
backup_should_warn() {
    local backup_mtime="$1" now_s="$2" stale_s="$3" db_last_commit_epoch="$4"
    case "$db_last_commit_epoch" in
        ''|*[!0-9]*) ;;  # unmeasured — fall through to the age-only check
        *) [ "$db_last_commit_epoch" -le "$backup_mtime" ] && return 1 ;;
    esac
    [ $((now_s - backup_mtime)) -gt "$stale_s" ]
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
    # Bare "deacon/" resolves via bd issue-ID lookup and fuzzy-matches ANY
    # bead whose ID contains "deacon" as a substring — this city has two
    # (dc-deacon-refinery, dc-deacon-witness), so it fails ambiguous and the
    # nudge below was silently lost via `|| true` (ga-4zbjs). Target the
    # verified live session by its qualified name instead — same name this
    # function already keys its suspension check on, three lines up.
    gc session nudge gastown.deacon/ "$message" 2>/dev/null || true
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

# state_read_field <state_file> <field> — reads one field from the JSON
# cooldown-state file; empty string if the file or field doesn't exist yet
# (first-ever run, or a resolved/OK cycle that cleared it). I/O wrapper only,
# always returns 0 (jq failure falls back to an empty read, never propagates
# under this script's `set -e`) — the actual alert DECISION lives in the pure
# advisory_should_alert() below.
state_read_field() {
    local state_file="$1" field="$2"
    [ -f "$state_file" ] || { printf ''; return 0; }
    jq -r --arg f "$field" '.[$f] // empty' "$state_file" 2>/dev/null || printf ''
    return 0
}

# state_write <state_file> <class> <alert_at> <latency_ms> <conn_count> <orphan_count>
# Atomic (tmp+mv) write of the cooldown-state snapshot. Empty args are never
# left blank (that would fail --argjson). alert_at collapses to 0, which
# state_read_field/the elapsed-time check read as "no alert recorded". The three
# MEASUREMENTS (latency_ms, conn_count, orphan_count) are written as JSON null
# when empty (ga-29lbag gate fix): an unmeasured count is not a measured 0, and
# a fake 0 in the snapshot made the next cycle compare against a value nobody
# ever saw. state_read_field reads null back as empty, which
# advisory_should_alert() treats as "no baseline" (any in-WARN metric then
# counts as worse — the cautious side), the same as the first-ever run.
# Best-effort: a write failure (unwritable state dir, disk full) must not
# take down the doctor probe itself, so this always returns 0.
state_write() {
    local state_file="$1" class="$2" alert_at="$3" latency_ms="$4" conn_count="$5" orphan_count="$6"
    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    jq -n --arg class "$class" --argjson alert_at "${alert_at:-0}" \
        --argjson latency_ms "${latency_ms:-null}" --argjson conn_count "${conn_count:-null}" \
        --argjson orphan_count "${orphan_count:-null}" \
        '{class: $class, alert_at: $alert_at, latency_ms: $latency_ms, conn_count: $conn_count, orphan_count: $orphan_count}' \
        > "${state_file}.tmp.$$" 2>/dev/null \
        && mv -f "${state_file}.tmp.$$" "$state_file" 2>/dev/null \
        || rm -f "${state_file}.tmp.$$" 2>/dev/null
    return 0
}

# recovery_is_confirmed <unmeasured_items> — pure predicate (ga-29lbag gate fix, third state).
# "No warning this cycle" only means "recovered" when every step that could raise a warning was
# actually measured. UNMEASURED_ITEMS is deliberately kept out of WARNINGS (a blind spot under load
# must not page the Mayor every cooldown), so a cycle whose SHOW DATABASES failed, whose
# `dolt backup` timed out, or whose probe budget ran out reaches the no-warning branch with an
# EMPTY warning set for the wrong reason: it did not look. Clearing the cooldown state there is
# what the branch does when it KNOWS things are fine — the next fully measured cycle then saw the
# same stale backup as a fresh OK->MEDIUM transition and mailed the Mayor a second time within
# seconds (reproduced on the real script, 3 cycles). Only a fully measured cycle (empty list) may
# clear it; otherwise the state stays as it was. Cost of that caution: an incident that really did
# recover stays recorded as MEDIUM until the next fully measured cycle, and the 6h cooldown
# bounds how long a genuinely new warning could be held back in the meantime.
recovery_is_confirmed() {
    [ -z "$1" ]
}

# advisory_should_alert <prev_class> <elapsed_s> <cooldown_s> \
#                        <latency_ms> <prev_latency_ms> <latency_is_warn> \
#                        <conn_count> <prev_conn_count> <conn_is_warn> \
#                        <orphan_count> <prev_orphan_count> <orphan_is_warn>
# Pure predicate (ga-2uz59, refined by ga-wrl5x) — decides whether the MEDIUM
# advisory mail should actually go out this cycle, vs. being suppressed as a
# duplicate of an already-notified condition. Isolated exactly like
# conn_should_warn() above so a test can drive it directly with real reported
# numbers. NEVER gates the CRITICAL/unreachable escalation earlier in this
# script — that path always fires, unconditionally, per this bug's own
# explicit "não suprimir HIGH/CRITICAL por cooldown" acceptance criterion.
#
# Fires (return 0/true) when ANY of:
#   (a) class changed — prev_class isn't "MEDIUM" (a fresh OK->MEDIUM transition)
#   (b) cooldown has elapsed since the last actual alert
#   (c) a metric that is ITSELF currently in its own WARN state this cycle
#       (per latency_should_warn()/conn_should_warn()/orphan_count>0, already
#       computed by the caller — this function never recomputes thresholds)
#       got WORSE than the last alert's own snapshot for that same metric
#
# ga-wrl5x: (c) used to compare raw latency_ms/conn_count/orphan_count with a
# bare "greater than", regardless of whether that metric was anywhere near its
# own warning threshold. Measured live (2 independent samples, same
# persistently-stale-backup incident, ~2.3h total): latency oscillated
# 109-1649ms and connections 10-35 — both comfortably inside their healthy
# range (5000ms / ~204-of-256 warn thresholds) — yet every random uptick
# against the LAST ALERT's own snapshot re-armed the mail, at ~4.6-7
# advisories/hour with a 6h cooldown in effect (~27x the intended rate). The
# backup-staleness exclusion below already anticipated a monotonic field
# defeating the cooldown; healthy-range noise defeats it the same way, just
# intermittently instead of monotonically. Gating each comparison on the
# metric's OWN warn state anchors "worse" to the same severity notion the
# rest of this script already uses to decide the condition is concerning in
# the first place — a metric that never leaves its healthy range cannot make
# the situation "worse" no matter how much it wobbles inside that range.
#
# Deliberately does NOT take backup-staleness as an input for (c): backup age
# only ever grows while the condition holds (every 5-minute cycle is "worse"
# than the last, by construction, until the next daily backup lands) — a
# naive worse-than-last-time check on that one field would defeat the
# cooldown entirely for the exact condition (a stale backup sitting for
# hours) that produced this bug's 85 duplicate mails. Cooldown alone still
# re-alerts on a persistently stale backup every ADVISORY_COOLDOWN_S.
advisory_should_alert() {
    local prev_class="$1" elapsed_s="$2" cooldown_s="$3" \
          latency_ms="$4" prev_latency_ms="$5" latency_is_warn="$6" \
          conn_count="$7" prev_conn_count="$8" conn_is_warn="$9" \
          orphan_count="${10}" prev_orphan_count="${11}" orphan_is_warn="${12}"

    [ "$prev_class" != "MEDIUM" ] && return 0

    case "$elapsed_s" in ''|*[!0-9]*) return 0 ;; esac
    [ "$elapsed_s" -ge "$cooldown_s" ] && return 0

    case "$latency_ms" in ''|*[!0-9]*) latency_ms=0 ;; esac
    case "$conn_count" in ''|*[!0-9]*) conn_count=0 ;; esac
    case "$orphan_count" in ''|*[!0-9]*) orphan_count=0 ;; esac
    case "$prev_latency_ms" in ''|*[!0-9]*) prev_latency_ms=-1 ;; esac
    case "$prev_conn_count" in ''|*[!0-9]*) prev_conn_count=-1 ;; esac
    case "$prev_orphan_count" in ''|*[!0-9]*) prev_orphan_count=-1 ;; esac

    [ "$latency_is_warn" = "true" ] && [ "$latency_ms" -gt "$prev_latency_ms" ] && return 0
    [ "$conn_is_warn" = "true" ] && [ "$conn_count" -gt "$prev_conn_count" ] && return 0
    [ "$orphan_is_warn" = "true" ] && [ "$orphan_count" -gt "$prev_orphan_count" ] && return 0

    return 1
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
# ga-29lbag gate fix: every step that can raise a warning is registered as "not measured" when it
# yields nothing, so an empty warning set is only read as recovery for a cycle that really looked
# (see recovery_is_confirmed()). Without a known limit conn_should_warn() never warns.
if [ -z "$CONN_MAX" ]; then
    append_unmeasured "connection limit"
fi

# ga-29lbag: a timed-out/failed count used to fall into `|| echo "0"` and be reported as a MEASURED
# zero ("0/256") — the same error==empty collapse CONN_MAX and ORPHAN_COUNT already avoid. The
# numeric value (CONN_COUNT_NUM) stays empty when unmeasured and feeds the predicates and the
# cooldown state; CONN_COUNT is the display form ("unknown" instead of a fake 0).
CONN_COUNT_NUM=$(dolt_sql -r csv -q "SELECT COUNT(*) FROM information_schema.PROCESSLIST" 2>/dev/null \
    | tail -1) || CONN_COUNT_NUM=""
case "$CONN_COUNT_NUM" in
    ''|*[!0-9]*) CONN_COUNT_NUM="" ;;
esac
CONN_COUNT="${CONN_COUNT_NUM:-unknown}"
if [ -z "$CONN_COUNT_NUM" ]; then
    append_unmeasured "connection count"
fi
CONN_WARN=""
if conn_should_warn "$CONN_COUNT_NUM" "$CONN_MAX" "$CONN_WARN_PCT"; then
    CONN_WARN=" [WARN: ${CONN_COUNT} connections >= ${CONN_WARN_PCT}% of max ${CONN_MAX}]"
fi

# Disk usage of Dolt data directory. ga-29lbag: bounded like every other step; `|| true` keeps the
# total du printed even when it exits 1 on one unreadable subdirectory (the old `|| echo unknown`
# appended a second line to the value in that case).
DISK_USAGE=$(run_bounded "$STEP_TIMEOUT_S" du -sh "$DOLT_DATA_DIR" 2>/dev/null | cut -f1) || true
DISK_USAGE="${DISK_USAGE:-unknown}"

# Orphan database detection.
# ga-29lbag: a failed SHOW DATABASES used to leave ALL_DBS empty, so the backup-freshness check
# below found nothing to check and the run looked clean. It now says so in the report.
DBLIST_OK=true
ALL_DBS=$(dolt_sql -r csv -q "SHOW DATABASES" 2>/dev/null | tail -n +2) || DBLIST_OK=false
if [ "$DBLIST_OK" != "true" ]; then
    append_unmeasured "database list (backup freshness skipped)"
fi
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
if [ -z "$ORPHAN_COUNT" ]; then
    append_unmeasured "orphan database count"
fi
ORPHAN_WARN=""
if [ -n "$ORPHAN_COUNT" ] && [ "$ORPHAN_COUNT" -gt 0 ]; then
    ORPHAN_WARN=" [WARN: $ORPHAN_COUNT orphan DBs detected — run gc dolt-cleanup]"
fi

# Backup freshness: check newest backup artifact per database.
# Scope mirrors mol-dog-backup.sh: only DBs with a configured <db>-backup
# remote are eligible. Cities with user DBs but no backup remotes
# (legitimate config) must not get false stale-backup alarms.
#
# ga-29lbag: `dolt backup` is a CLI that opens the database directory, and it ran here once per
# database with no bound at all (~0.5-1.4s each at load ~40; it could also hang). It is now bounded,
# and three-state: listed => eligible, exit 0 without the remote => legitimately not eligible
# (`dolt backup` exits 0 with empty output when no remote exists — checked on a fresh repo), and a
# timeout/failure => "not measured", no longer folded into "not eligible".
BACKUP_ELIGIBLE_DBS=""
for db in $USER_DBS; do
    db_dir="$DOLT_DATA_DIR/$db"
    if [ -d "$db_dir/.dolt" ]; then
        if [ "$SECONDS" -ge "$DOCTOR_BUDGET_S" ]; then
            append_unmeasured "backup remotes of $db (probe budget ${DOCTOR_BUDGET_S}s spent)"
            continue
        fi
        if backup_remotes=$(cd "$db_dir" && run_bounded "$STEP_TIMEOUT_S" dolt backup 2>/dev/null); then
            if printf '%s\n' "$backup_remotes" | awk '{print $1}' | grep -x "${db}-backup" >/dev/null; then
                BACKUP_ELIGIBLE_DBS="$BACKUP_ELIGIBLE_DBS $db"
            fi
        else
            append_unmeasured "backup remotes of $db"
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
            if [ "$SECONDS" -ge "$DOCTOR_BUDGET_S" ]; then
                append_unmeasured "backup freshness of $db (probe budget ${DOCTOR_BUDGET_S}s spent)"
                continue
            fi
            NEWEST_BACKUP_MTIME=$(newest_backup_mtime_for_db "$db")
            # ga-gqllbc: no local artifacts for a db whose staging is ephemeral = the normal state, not a
            # missing backup. Ask S3's run fingerprint (five answers that must not collapse — see
            # _eph_s3_fingerprint_state): a good backup's time, or the last good one's, goes through the
            # SAME age/idle logic below; "could not read it" is NOT-MEASURED, never a warning and never fine.
            if [ "$NEWEST_BACKUP_MTIME" -le 0 ] && declare -f _eph_is_ephemeral >/dev/null 2>&1 && _eph_is_ephemeral "$db"; then
                EPH_FP_STATE="$(_eph_s3_fingerprint_state "$db")"
                case "$EPH_FP_STATE" in
                    "ok "[0-9]*|"failed "[0-9]*)
                        NEWEST_BACKUP_MTIME="${EPH_FP_STATE#* }"
                        ;;
                    "failed unknown")
                        append_backup_stale "$db backup FAILED last night and S3 records no last good backup"
                        continue
                        ;;
                    absent)
                        append_backup_stale "$db backup missing (no entry for it in the S3 run fingerprint)"
                        continue
                        ;;
                    *)
                        append_unmeasured "S3 backup fingerprint of $db (ephemeral staging: no local artifacts to fall back on)"
                        continue
                        ;;
                esac
            fi
            if [ "$NEWEST_BACKUP_MTIME" -le 0 ]; then
                append_backup_stale "$db backup missing"
                continue
            fi
            DB_LAST_COMMIT_EPOCH=$(db_last_commit_epoch "$db")
            if backup_should_warn "$NEWEST_BACKUP_MTIME" "$NOW_S" "$BACKUP_STALE_S" "$DB_LAST_COMMIT_EPOCH"; then
                BACKUP_AGE=$((NOW_S - NEWEST_BACKUP_MTIME))
                append_backup_stale "$db backup is $((BACKUP_AGE / 3600))h old"
                # ga-29lbag gate fix: the commit epoch can only turn a warning into "no warning"
                # (an idle db whose backup already has its newest commit). With the epoch missing
                # this warning came from the age alone, so it may be a false alarm on an idle db —
                # say so. When the age-only check does NOT warn, the missing epoch changes nothing
                # (fresh either way), so that case is fully measured and is not listed.
                if [ -z "$DB_LAST_COMMIT_EPOCH" ]; then
                    append_unmeasured "last commit of $db (its backup-age warning is age-only)"
                fi
            fi
        done
        if [ -n "$BACKUP_STALE_ITEMS" ]; then
            BACKUP_STALE=" [WARN: backup freshness: $BACKUP_STALE_ITEMS]"
        fi
    fi
fi

# --- Step 3: Compose report and escalate if critical ---

WARNINGS="${LATENCY_WARN}${CONN_WARN}${ORPHAN_WARN}${BACKUP_STALE}"
REPORT_BODY="Latency: ${LATENCY_MS}ms${LATENCY_WARN}
Connections: ${CONN_COUNT}/${CONN_MAX_DISPLAY}${CONN_WARN}
Disk: ${DISK_USAGE}
Orphan DBs: ${ORPHAN_COUNT_DISPLAY}${ORPHAN_WARN}${BACKUP_STALE}"
# ga-29lbag: steps that could not run this cycle are named, not silently absent. Deliberately NOT
# part of WARNINGS: a blind spot under load must not page the Mayor every cooldown (the ga-2uz59 /
# ga-wrl5x noise class) — it lands in this report, the log summary and the DOG_DONE ping.
if [ -n "$UNMEASURED_ITEMS" ]; then
    REPORT_BODY="${REPORT_BODY}
Not measured this run: ${UNMEASURED_ITEMS}"
fi

if [ -n "$WARNINGS" ]; then
    # ga-2uz59 AC2: the substantive payload always hits the log every cycle,
    # mail or not — the cooldown below gates only the MAYOR MAIL, never this
    # measurement record.
    echo "doctor: MEDIUM condition this cycle —"
    printf '%s\n' "$REPORT_BODY"

    DOCTOR_NOW_EPOCH=$(date +%s)
    PREV_CLASS=$(state_read_field "$STATE_FILE" class)
    PREV_ALERT_AT=$(state_read_field "$STATE_FILE" alert_at)
    PREV_LATENCY_MS=$(state_read_field "$STATE_FILE" latency_ms)
    PREV_CONN_COUNT=$(state_read_field "$STATE_FILE" conn_count)
    PREV_ORPHAN_COUNT=$(state_read_field "$STATE_FILE" orphan_count)
    case "$PREV_ALERT_AT" in
        ''|*[!0-9]*) DOCTOR_ELAPSED_S=999999999 ;;
        *) DOCTOR_ELAPSED_S=$((DOCTOR_NOW_EPOCH - PREV_ALERT_AT)) ;;
    esac

    # ga-wrl5x: only a metric that is ITSELF in warn state this cycle (per the
    # same LATENCY_WARN/CONN_WARN/ORPHAN_WARN strings already computed above)
    # may count as "worse" below — see advisory_should_alert()'s docblock.
    LATENCY_IS_WARN="false"
    if [ -n "$LATENCY_WARN" ]; then
        LATENCY_IS_WARN="true"
    fi
    CONN_IS_WARN="false"
    if [ -n "$CONN_WARN" ]; then
        CONN_IS_WARN="true"
    fi
    ORPHAN_IS_WARN="false"
    if [ -n "$ORPHAN_WARN" ]; then
        ORPHAN_IS_WARN="true"
    fi

    if advisory_should_alert "${PREV_CLASS:-OK}" "$DOCTOR_ELAPSED_S" "$ADVISORY_COOLDOWN_S" \
        "$LATENCY_MS" "$PREV_LATENCY_MS" "$LATENCY_IS_WARN" \
        "$CONN_COUNT_NUM" "$PREV_CONN_COUNT" "$CONN_IS_WARN" \
        "$ORPHAN_COUNT" "$PREV_ORPHAN_COUNT" "$ORPHAN_IS_WARN"; then
        if send_mayor_mail -s "Dolt health advisory [MEDIUM]" -m "$REPORT_BODY"; then
            state_write "$STATE_FILE" "MEDIUM" "$DOCTOR_NOW_EPOCH" "$LATENCY_MS" "$CONN_COUNT_NUM" "$ORPHAN_COUNT"
        fi
    else
        echo "doctor: MEDIUM advisory suppressed — within ${ADVISORY_COOLDOWN_S}s cooldown and not worsened since last alert (elapsed ${DOCTOR_ELAPSED_S}s)"
    fi
else
    # Recovered (or never triggered) — clear the recorded class to OK so a
    # FUTURE MEDIUM occurrence is treated as a fresh transition and alerts
    # immediately, rather than inheriting a stale cooldown from an already-
    # resolved incident (ga-2uz59 AC1a). ga-29lbag gate fix: only when the cycle
    # was fully measured — see recovery_is_confirmed(). An unmeasured cycle proves
    # nothing about recovery, so the state file is left exactly as it was.
    if [ -f "$STATE_FILE" ]; then
        if recovery_is_confirmed "$UNMEASURED_ITEMS"; then
            state_write "$STATE_FILE" "OK" "" "" "" ""
        else
            echo "doctor: no warning this cycle, but recovery is not confirmed — state left as-is (not measured: $UNMEASURED_ITEMS)"
        fi
    fi
fi

SUMMARY="doctor — server: ok, latency: ${LATENCY_MS}ms, conns: ${CONN_COUNT}/${CONN_MAX_DISPLAY}, disk: ${DISK_USAGE}, orphans: ${ORPHAN_COUNT_DISPLAY}"
if [ -n "$UNMEASURED_ITEMS" ]; then
    SUMMARY="$SUMMARY [not measured: $UNMEASURED_ITEMS]"
fi
nudge_deacon_done "DOG_DONE: $SUMMARY"
echo "doctor: $SUMMARY"

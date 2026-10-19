#!/usr/bin/env bash
# jsonl-export — export Dolt databases to JSONL and push to git archive.
#
# Replaces mol-dog-jsonl formula. All operations are deterministic:
# dolt sql exports, jq record-count comparisons against spike threshold,
# git add/commit/push. No LLM judgment needed.
#
# Runs as an exec order (no LLM, no agent, no wisp).
set -euo pipefail

CITY="${GC_CITY:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bound git-maintenance's pack-objects memory/CPU on the archive repo
# (ga-gtrc8n). Unbounded (git's own default: 10 threads x unlimited delta
# window) measured 3.2GB RSS repacking this repo's ~22MB blobs — the single
# largest process on the host, and a repeat contributor to swap-creation
# bursts. A prior fix set these three keys directly in the archive's
# .git/config, but that lives only in the working copy: since this script
# deletes-and-recreates the repo whenever $ARCHIVE_REPO/.git goes missing,
# the bound would silently disappear with it. Calling this on every run
# instead makes it durable: `git config <key> <value>` (no --add) replaces a
# single-valued key in place, so repeated calls are idempotent — a freshly
# created repo is born with the bound, and a pre-existing repo without it
# gains it on its next cooldown cycle. Measured with the bound: max RSS
# 514MB for the same repack workload.
ensure_archive_pack_config() {
    local repo="$1"
    git -C "$repo" config pack.threads 2
    git -C "$repo" config pack.windowMemory 256m
    git -C "$repo" config pack.deltaCacheSize 64m
    # ga-wkoij7: a plain `git commit` here must start NO background maintenance. On 17/10 ~10:4x it ran `git maintenance run --auto --detach` (a geometric repack of
    # a 4.4GB pack: 1.8GB of RAM, swap 5.2GB, free disk 1.4GB) at midday. The Mayor set these two keys by hand in the live repo; like the three above they would vanish
    # with a recreated repo, so they are written here on every run. The one repack that is wanted — 00:00-06:00, with room on the disk — is asked for explicitly by
    # commit_archive_snapshot (`-c maintenance.auto=true` on that one commit; measured on git 2.54 to repack even with both keys set here).
    git -C "$repo" config maintenance.auto false
    git -C "$repo" config gc.auto 0
}

# The window and the room a whole-repo repack needs (ga-wkoij7). Sourced before the library-mode return so the selftest reaches the same functions the run uses.
# (-r first: bash 3.2 ends a non-interactive shell at a `.` of a missing file before any `||` or `if !` can answer, and the message below is the one that names the cause)
if ! { [ -r "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh" ] && . "$SCRIPT_DIR/jsonl-archive-repack-window-lib.sh"; }; then
    echo "jsonl-export: cannot load $SCRIPT_DIR/jsonl-archive-repack-window-lib.sh — without it no commit knows whether a repack may start" >&2
    exit 1
fi

# The export's cadence follows the disk (ga-j2f5v5). Every run rewrites hq/comments.jsonl (~276 MB), hq/issues.jsonl (~73 MB), the flat hq.jsonl and the whatsapp_automation files, and `git add` keeps a
# new loose blob of each file that changed. Measured 18/10 03:50-09:46Z: the disk dips ~700 MB on every run and comes back, and the archive's packed side grew +860 MiB in 6 h; with the disk under Dolt's
# CRITICAL floor, one more swapfile (+1 GB) in the middle of a dip is all it takes for ENOSPC on Dolt's journal, as on 15/10 and 17/10. So with a low disk the run is spaced out, and says so:
#   free >= DISK_NEW_WORK_MIN_MB (5 GiB) ................................. every tick, as before
#   free below it, Dolt's disk class not CRITICAL ........................ at most once per JEX_LOW_DISK_INTERVAL_S (1 h)
#   free whole GiB <= DOLT_DISK_FLOOR_CRITICAL_GB (3), i.e. under 4096 MB  only when the last export is JEX_CRITICAL_DISK_INTERVAL_S (3 h) old
# The CRITICAL line is dolt-disk-floor-guard.sh's own (same variable, same default, "free GiB rounded down <= N"; jsonl-archive-compact.sh reads it the same way), not a third reading of "3 GB".
# "Last export" is last_export_at in the state file, stamped when a run enters the heavy part (databases listed, nothing exported yet): a run the engine kills at its timeout cost the disk all the same, so it counts.
# THREE answers about the disk, never two: it has room (run), it is low (space the run), it cannot be read (RUN). The export is the backup: a df hiccup, a missing or unreadable last_export_at, a stamp in the
# future or a clock that will not answer must never make it stop in silence, so every doubt is "run" and the reason is in the log. So the export is never held back for more than JEX_CRITICAL_DISK_INTERVAL_S after the last stamp (plus the tick that finds it due); the offsite
# alarm for a stopped exporter (jsonl-hourly-offsite.sh, JHO_STALE_SOURCE_S = 6 h) stays quiet inside that — the selftest compares the two defaults.
JEX_LOW_DISK_INTERVAL_S="${JEX_LOW_DISK_INTERVAL_S:-3600}"
JEX_CRITICAL_DISK_INTERVAL_S="${JEX_CRITICAL_DISK_INTERVAL_S:-10800}"
JEX_DOLT_CRITICAL_GB="${DOLT_DISK_FLOOR_CRITICAL_GB:-3}"
# empty / not a number / more than 9 digits -> the default (a value `[ -ge ]` and $(( )) can take; the arithmetic below also forces base 10, so "08" is eight and not an octal error)
case "$JEX_LOW_DISK_INTERVAL_S" in ''|*[!0-9]*) JEX_LOW_DISK_INTERVAL_S=3600 ;; esac
case "$JEX_CRITICAL_DISK_INTERVAL_S" in ''|*[!0-9]*) JEX_CRITICAL_DISK_INTERVAL_S=10800 ;; esac
case "$JEX_DOLT_CRITICAL_GB" in ''|*[!0-9]*) JEX_DOLT_CRITICAL_GB=3 ;; esac
[ "${#JEX_LOW_DISK_INTERVAL_S}" -le 9 ] || JEX_LOW_DISK_INTERVAL_S=3600
[ "${#JEX_CRITICAL_DISK_INTERVAL_S}" -le 9 ] || JEX_CRITICAL_DISK_INTERVAL_S=10800
[ "${#JEX_DOLT_CRITICAL_GB}" -le 9 ] || JEX_DOLT_CRITICAL_GB=3

# The ONE reader of "how much disk is left" (disk-headroom-lib.sh). Unlike the repack-window lib above, a missing lib does not stop the run: this guard only ever SPACES the export, and a backup that cannot
# find its guard must still run (main section: it says so on stderr and in the log). -r first: bash 3.2 ends a non-interactive shell at a `.` of a missing file before any `||` can answer.
JEX_DISK_LIB_OK=0
if [ -r "$SCRIPT_DIR/disk-headroom-lib.sh" ] && . "$SCRIPT_DIR/disk-headroom-lib.sh" 2>/dev/null && type disk_free_mb disk_state_of >/dev/null 2>&1; then
    JEX_DISK_LIB_OK=1
fi

# jex_cadence_verdict <free_mb> <last_export_epoch> <now_epoch> — pure: prints one line and returns 0 (safe under set -e).
#   run|<why>      export now. why: disk-ok · disk-unreadable · clock-unreadable · no-last-export · last-export-unreadable · last-export-in-the-future · due-low · due-critical
#   skip|<detail>  space it out; detail is the line for the log (tier, the reading, the age, the interval, the wait left)
# free_mb "" or not a number = the disk could not be read. last_export_epoch "" = never stamped; a non-number = a stamp that could not be read.
jex_cadence_verdict() {
    local free="${1:-}" last="${2:-}" now="${3:-}" crit_mb st_new st_crit tier min_s age
    crit_mb=$(( 10#$JEX_DOLT_CRITICAL_GB * 1024 + 1024 ))   # free GiB rounded down <= N  <=>  free MB < (N+1) * 1024
    # disk_state_of answers ok | low | unknown from the very reading we print; "low" there means "below that floor". vazio/falhou/ilegível → unknown → run
    st_new=$(disk_state_of "$free" "$DISK_NEW_WORK_MIN_MB")
    st_crit=$(disk_state_of "$free" "$crit_mb")
    case "$st_new$st_crit" in
        *unknown*) echo "run|disk-unreadable"; return 0 ;;
    esac
    if [ "$st_crit" = "low" ]; then
        tier=critical; min_s="$JEX_CRITICAL_DISK_INTERVAL_S"
    elif [ "$st_new" = "low" ]; then
        tier=low; min_s="$JEX_LOW_DISK_INTERVAL_S"
    else
        echo "run|disk-ok"; return 0
    fi
    # the disk is low: now only the clock and the last stamp decide, and any doubt about them is "run"
    case "$now" in ''|*[!0-9]*) echo "run|clock-unreadable"; return 0 ;; esac
    [ "${#now}" -le 12 ] || { echo "run|clock-unreadable"; return 0; }
    case "$last" in
        '') echo "run|no-last-export"; return 0 ;;
        *[!0-9]*) echo "run|last-export-unreadable"; return 0 ;;
    esac
    [ "${#last}" -le 12 ] || { echo "run|last-export-unreadable"; return 0; }
    age=$(( 10#$now - 10#$last ))
    if [ "$age" -lt 0 ]; then echo "run|last-export-in-the-future"; return 0; fi
    if [ "$age" -ge "$min_s" ]; then echo "run|due-$tier"; return 0; fi
    echo "skip|tier=$tier free=${free}MB last_export_age=${age}s min_interval=${min_s}s next_due_in=$(( min_s - age ))s"
    return 0
}

# How does a supplemental table's export compare with its source? (ga-l6v576) Prints ONE of:
#   short     a source count is readable AND the export has fewer rows than it;
#   complete  a source count is readable AND the export has at least that many rows;
#   unknown   no source count could be read (or the export's own count is not a number).
# Three answers, like export_vs_source_verdict below, for the same reason: an unreadable count must never read as "complete". Pure (no Dolt, no globals but the
# slack knob), so the selftest calls it in library mode.
# The table is counted BEFORE and AFTER the read. Rows deleted while the read runs lower the count after it, so a whole read is never below the SMALLER of the two; comparing
# with the larger one would call every busy table short. Whatever is added meanwhile only raises the export. There is no percentage slack on purpose: comments only grow, and a
# cut that leaves the last 1% (a few hundred comments) is exactly the cut that goes unseen under the 1% the issues gate allows. A false "short" costs one retry, a miss costs the table.
table_export_verdict() {
    local raw="$1" before="$2" after="$3" source slack="${GC_JSONL_SUPP_SHORT_SLACK:-0}"

    case "$raw" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
    case "$before" in ''|*[!0-9]*) before="" ;; esac
    case "$after" in ''|*[!0-9]*) after="" ;; esac
    case "$slack" in ''|*[!0-9]*) slack=0 ;; esac
    if [ -z "$before" ] && [ -z "$after" ]; then
        echo unknown
        return 0
    fi
    if [ -z "$before" ]; then
        source="$after"
    elif [ -z "$after" ]; then
        source="$before"
    elif [ "$((10#$after))" -lt "$((10#$before))" ]; then
        source="$after"
    else
        source="$before"
    fi
    if [ $(( 10#$raw + 10#$slack )) -lt "$((10#$source))" ]; then
        echo short
    else
        echo complete
    fi
}

# Library mode: `JSONL_EXPORT_LIB=1 source jsonl-export.sh` defines the pure
# function above and returns before dolt-target.sh is sourced — no live Dolt
# server, port resolution, or GC_CITY_PATH is ever required. Used by
# jsonl-export.selftest.sh.
if [ "${JSONL_EXPORT_LIB:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

. "$SCRIPT_DIR/dolt-target.sh"

# jq is a hard dependency: count_jsonl_rows below relies on it, and a missing
# jq would silently zero every record count and could mask spikes on a stale
# baseline. Fail loud at startup instead.
if ! command -v jq >/dev/null 2>&1; then
    echo "jsonl-export: jq is required but not found in PATH" >&2
    exit 1
fi
PACK_STATE_DIR="${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance}"
LEGACY_ARCHIVE_REPO="$CITY/.gc/jsonl-archive"
LEGACY_STATE_FILE="$CITY/.gc/jsonl-export-state.json"

# Configurable via environment (defaults match the old formula).
SPIKE_THRESHOLD="${GC_JSONL_SPIKE_THRESHOLD:-20}"  # percentage (0-100)
# Skip the percentage spike check when the previous record count is below
# this absolute floor — small-N percentages are noise. A fresh bead store
# growing 10→309 records during stand-up legitimately trips a 20% delta on
# every cycle; raising the floor to 100 keeps the check meaningful on real
# data while suppressing stand-up flares. Set to 0 to disable.
MIN_PREV_FOR_SPIKE_CHECK="${GC_JSONL_MIN_PREV_FOR_SPIKE:-100}"
# Partial-export gate (ga-7sxdmb): each DB's export is compared with the source's
# own COUNT(*) (read just before the export, same SQL filter), independently of
# the previous snapshot and of SPIKE_THRESHOLD. An export more than the slack
# below the source is a partial export and never becomes the snapshot. The slack
# absorbs rows deleted while the export ran: max(MIN rows, PCT% of the source).
# When the source count cannot be read there is nothing to compare with: that
# export is archived but reported as "unverified" (see the gate in the DB loop).
SHORT_EXPORT_SLACK_PCT="${GC_JSONL_SHORT_EXPORT_SLACK_PCT:-1}"
SHORT_EXPORT_MIN_SLACK="${GC_JSONL_SHORT_EXPORT_MIN_SLACK:-5}"
# Supplemental tables (ga-l6v576): the five tables next to issues, each read in pages of SUPP_CHUNK_ROWS rows (Dolt cuts ONE read that runs past ~40 s: hq.comments came out at
# 11,776 of 36,930 rows, exit 0), checked against its own COUNT(*), and tried at most SUPP_EXPORT_ATTEMPTS times before the previous version is kept. 2000 rows took 3-7 s on the
# live hq, a margin of 5x under the cut; a retry cannot cure a cut that repeats, so the attempts stay few (the order's timeout is 840 s). GC_JSONL_SUPP_SHORT_SLACK (rows) is read
# by table_export_verdict.
SUPP_TABLES="comments config dependencies labels metadata"
SUPP_CHUNK_ROWS="${GC_JSONL_SUPP_CHUNK_ROWS:-2000}"
SUPP_EXPORT_ATTEMPTS="${GC_JSONL_SUPP_EXPORT_ATTEMPTS:-2}"
SUPP_EXPORT_RETRY_DELAY="${GC_JSONL_SUPP_EXPORT_RETRY_DELAY:-3}"
SUPP_MAX_PAGES=5000
# These feed arithmetic and `sleep`: anything that is not a positive number (a delay may be 0) is the default.
case "$SUPP_CHUNK_ROWS" in ''|*[!0-9]*|0|00*) SUPP_CHUNK_ROWS=2000 ;; esac
case "$SUPP_EXPORT_ATTEMPTS" in ''|*[!0-9]*|0|00*) SUPP_EXPORT_ATTEMPTS=2 ;; esac
case "$SUPP_EXPORT_RETRY_DELAY" in ''|*[!0-9]*) SUPP_EXPORT_RETRY_DELAY=3 ;; esac
MAX_PUSH_FAILURES="${GC_JSONL_MAX_PUSH_FAILURES:-3}"
PUSH_RETRY_DELAY_MIN="${GC_JSONL_PUSH_RETRY_DELAY_MIN:-1}"
PUSH_RETRY_DELAY_SPAN="${GC_JSONL_PUSH_RETRY_DELAY_SPAN:-4}"
SCRUB="${GC_JSONL_SCRUB:-true}"
# The archive lives under packs/maintenance whichever pack's copy of this script
# runs (ga-7sxdmb). gc sets GC_PACK_STATE_DIR to the state dir of the pack that
# OWNS the order, so for this vendored copy PACK_STATE_DIR is packs/town-deltas;
# a default derived from it (as this line used to be) forks the archive away from
# the one scripts/dolt-s3-backup.sh mirrors offsite (JSONL_ARCHIVE_DIR) and
# scripts/dolt-gc-maintenance.sh archives pruned rows into (when enabled). The
# state file stays per pack.
ARCHIVE_REPO="${GC_JSONL_ARCHIVE_REPO:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/maintenance/jsonl-archive}"
# The single-flight lock of jsonl-archive-compact.sh (same default path as its LOCK; JAC_LOCK is its test seam, honoured here so one fixture can point both at one
# directory). commit_archive_snapshot reads it: while a compaction run is in flight, a commit here must not start git's own background maintenance (ga-8z0hy7).
COMPACT_LOCK="${JAC_LOCK:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/jsonl-archive-compact.lock}"
# Where the repack window writes the decisions that matter (an allowed repack, a refusal inside the window); see jsonl-archive-repack-window-lib.sh.
JAW_LOG="${JAW_LOG:-$CITY/.gc/logs/jsonl-archive-repack-window.log}"
# Re-log the archive mode at least this often (seconds) even without a mode
# transition, so operators who missed the first line still see the current
# configuration. Default one week.
MODE_RELOG_INTERVAL_SECONDS="${GC_JSONL_MODE_RELOG_INTERVAL:-604800}"

# Cached archive mode ("push" or "local-only"). Resolved once on the first
# get_archive_mode call and reused thereafter so every push checkpoint in a
# single run sees a consistent value even if an operator adds or removes the
# origin remote mid-run.
ARCHIVE_MODE=""

# Count records in a `dolt sql -r json` payload. The output is `{"rows":[...]}`
# on (typically) a single physical line, so `wc -l` measures formatting, not
# records. Falls back to 0 on empty/missing/unparseable input; jq parse errors
# are forwarded to stderr so a corrupt archive surfaces in operator logs
# instead of being silently scored as zero rows.
count_jsonl_rows() {
    jq -s -r 'if length == 0 then 0 else ((.[0].rows // []) | length) end' || echo "0"
}

push_retry_delay_seconds() {
    awk -v seed="$RANDOM$$" -v min="$PUSH_RETRY_DELAY_MIN" -v span="$PUSH_RETRY_DELAY_SPAN" \
        'BEGIN{srand(seed); printf "%.2f", min + rand() * span}'
}

# Scrub test-only rows and ephemeral system rows while preserving the JSON
# export structure and legitimate rows in the same payload. The input is one
# JSON object with a .rows array, not newline-delimited JSON, so row-level
# filtering must happen inside jq.
#
# Mirrors the SQL SCRUB_FILTER built below so post-export validation matches
# the pre-export filter — any system issue_type, system-task title pattern, or
# scoped auto-convoy that slips past the SQL filter is still removed here.
scrub_exported_issues() {
    jq -c '
        if (.rows? | type) == "array" then
            .rows |= map(
                select(
                    ((.title // "") | test("^(Test Issue|test_)") | not) and
                    (
                        (
                            (.id // "") == "bd-1" or
                            (.id // "") == "bd-abc12" or
                            ((.id // "") | test("^(testdb_|beads_t)"))
                        ) | not
                    ) and
                    ((.issue_type // "") | test("^(message|event|wisp|agent)$") | not) and
                    ((.title // "") | test("^(gc:|order:)") | not) and
                    ((((.issue_type // "") == "convoy") and ((.title // "") | test("^sling-"))) | not)
                )
            )
        else
            .
        end
    '
}

validate_exported_issues() {
    jq -e -c '
        if (type == "object") and ((.rows? // [] | type) == "array") then
            .
        else
            error("issues export must be a JSON object with a rows array")
        end
    '
}

normalize_pending_spike_alert_state() {
    jq -c '
        (.pending_spike_alerts //= {}) |
        if (.pending_spike_alert? | type) == "object" and ((.pending_spike_alert.database // "") != "") then
            .pending_spike_alerts[.pending_spike_alert.database] = (.pending_spike_alerts[.pending_spike_alert.database] // .pending_spike_alert)
        else
            .
        end |
        del(.pending_spike_alert) |
        if .pending_spike_alerts == {} then
            del(.pending_spike_alerts)
        else
            .
        end
    '
}

read_state_object() {
    local path="$1"

    jq -c '
        if type == "object" then
            .
        else
            error("state root must be a JSON object")
        end
    ' "$path" 2>/dev/null
}

read_state_json() {
    if [ -f "$STATE_FILE" ] && read_state_object "$STATE_FILE"; then
        return
    fi
    if [ -f "$STATE_FILE_BACKUP" ] && read_state_object "$STATE_FILE_BACKUP"; then
        if [ -f "$STATE_FILE" ]; then
            echo "jsonl-export: state file malformed; using last-known-good backup" >&2
        else
            echo "jsonl-export: state file missing; using last-known-good backup" >&2
        fi
        return
    fi
    if [ -f "$STATE_FILE" ]; then
        echo "jsonl-export: state file malformed; resetting to empty state" >&2
    fi
    echo '{}'
}

write_state_file_atomically() {
    local path="$1"
    local label="$2"
    local content="$3"
    local tmpfile

    if ! tmpfile=$(mktemp "${path}.tmp.XXXXXX"); then
        echo "jsonl-export: creating temporary $label failed" >&2
        return 1
    fi
    if ! printf '%s\n' "$content" > "$tmpfile"; then
        echo "jsonl-export: writing temporary $label failed" >&2
        rm -f "$tmpfile"
        return 1
    fi
    if ! mv -f "$tmpfile" "$path"; then
        echo "jsonl-export: replacing $label failed" >&2
        rm -f "$tmpfile"
        return 1
    fi
}

write_state_json() {
    if ! write_state_file_atomically "$STATE_FILE" "state file" "$1"; then
        return 1
    fi
    if ! write_state_file_atomically "$STATE_FILE_BACKUP" "state backup" "$1"; then
        echo "jsonl-export: state backup update failed; continuing with primary state only" >&2
    fi
}

set_consecutive_push_failures() {
    local count="$1"
    write_state_json "$(read_state_json | jq -c --argjson count "$count" '.consecutive_push_failures = $count')"
}

mark_push_failure_escalated() {
    write_state_json "$(read_state_json | jq -c '.push_failure_escalated = true')"
}

clear_push_failure_escalation() {
    write_state_json "$(read_state_json | jq -c 'del(.push_failure_escalated)')"
}

# Truncate push stderr before persisting it to state so the state file stays
# small regardless of how verbose git/network errors get. The head of the
# output is almost always the actionable message.
truncate_push_stderr_for_state() {
    local raw="$1"
    local max_bytes=512

    if [ -z "$raw" ]; then
        printf '%s' ""
        return
    fi
    printf '%s' "$raw" | LC_ALL=C awk -v max="$max_bytes" '
        BEGIN { total = 0 }
        {
            line = $0
            if (NR > 1) {
                line = "\n" line
            }
            len = length(line)
            if (total + len > max) {
                remaining = max - total
                if (remaining > 0) {
                    printf "%s", substr(line, 1, remaining)
                }
                printf "..."
                exit
            }
            printf "%s", line
            total += len
        }
    '
}

# Record a successful push in state so `gc doctor` can surface a timestamp for
# the archive health check. Clears any stale stderr from previous failures and
# any prior escalation marker so the next failure-cycle escalates fresh.
record_archive_push_success() {
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    write_state_json "$(
        read_state_json \
            | jq -c \
                --arg now "$now" \
                '.consecutive_push_failures = 0
                 | del(.pending_archive_push)
                 | del(.push_failure_escalated)
                 | .last_push_at = $now
                 | del(.last_push_stderr)'
    )"
}

set_pending_archive_push() {
    write_state_json "$(read_state_json | jq -c '.pending_archive_push = true')"
}

clear_pending_archive_push() {
    write_state_json "$(read_state_json | jq -c 'del(.pending_archive_push)')"
}

has_pending_archive_push() {
    [ "$(read_state_json | jq -r '.pending_archive_push // false')" = "true" ]
}

refresh_archive_remote_main() {
    git fetch origin main -q 2>/dev/null
}

archive_has_local_only_commits_from_tracking() {
    local merge_base

    if ! git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
        return 1
    fi
    merge_base=$(git merge-base refs/remotes/origin/main HEAD 2>/dev/null) || return 1
    [ "$(git rev-list --count "$merge_base..HEAD" 2>/dev/null || echo "0")" -gt 0 ]
}

archive_has_local_only_commits() {
    if refresh_archive_remote_main >/dev/null 2>&1; then
        archive_has_local_only_commits_from_tracking
        return
    fi
    if archive_has_local_only_commits_from_tracking; then
        echo "jsonl-export: fetch failed while checking deferred archive push; using existing origin/main tracking ref" >&2
        return 0
    fi
    return 1
}

# Detect the archive's push mode from the live state of its remotes rather
# than from a cached state field. Operators opt into off-box backup by adding
# an `origin` remote; removing it reverts to local-only on the next run with
# no extra command. The result is memoized in ARCHIVE_MODE on first call so
# every push checkpoint within a single run agrees, even if the remote changes
# mid-run.
resolve_archive_mode() {
    if [ -n "$ARCHIVE_MODE" ]; then
        return
    fi
    if [ -d "$ARCHIVE_REPO/.git" ] \
        && git -C "$ARCHIVE_REPO" remote get-url origin >/dev/null 2>&1; then
        ARCHIVE_MODE="push"
    else
        ARCHIVE_MODE="local-only"
    fi
}

get_archive_mode() {
    resolve_archive_mode
    echo "$ARCHIVE_MODE"
}

should_attempt_push() {
    resolve_archive_mode
    [ "$ARCHIVE_MODE" = "push" ]
}

# Log the archive mode on transitions and re-log weekly so operators who
# missed the first line still see the current configuration. State fields
# last_logged_mode and last_logged_at drive the re-log interval.
log_archive_mode_if_needed() {
    local current_mode
    local state_json
    local last_logged_mode
    local last_logged_at
    local stale_push_failures
    local stale_push_escalation
    local now
    local now_ts
    local last_ts
    local should_log=0
    local message

    resolve_archive_mode
    current_mode="$ARCHIVE_MODE"
    state_json=$(read_state_json)
    last_logged_mode=$(printf '%s\n' "$state_json" | jq -r '.last_logged_mode // empty')
    last_logged_at=$(printf '%s\n' "$state_json" | jq -r '.last_logged_at // empty')
    stale_push_failures=$(printf '%s\n' "$state_json" | jq -r '.consecutive_push_failures // 0')
    stale_push_escalation=$(printf '%s\n' "$state_json" | jq -r '.push_failure_escalated // false')
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    now_ts=$(date -u +%s)

    if [ "$current_mode" != "$last_logged_mode" ]; then
        should_log=1
    elif [ -z "$last_logged_at" ]; then
        should_log=1
    else
        last_ts=$(jq -n -r --arg ts "$last_logged_at" '$ts | try fromdateiso8601 catch 0')
        if [ "$last_ts" = "0" ] || [ "$((now_ts - last_ts))" -gt "$MODE_RELOG_INTERVAL_SECONDS" ]; then
            should_log=1
        fi
    fi

    if [ "$should_log" -eq 0 ] && [ "$current_mode" = "local-only" ] && { [ "$stale_push_failures" != "0" ] || [ "$stale_push_escalation" = "true" ]; }; then
        write_state_json "$(printf '%s\n' "$state_json" | jq -c '.consecutive_push_failures = 0 | del(.push_failure_escalated)')"
        return 0
    fi

    if [ "$should_log" -eq 0 ]; then
        return 0
    fi

    if [ "$current_mode" = "push" ]; then
        message="jsonl-export: archive running in push mode (origin configured; will push commits to remote)"
    else
        message="jsonl-export: archive running in local-only mode (no origin remote; commits stay on this host — off-box backup disabled)"
    fi
    echo "$message" >&2

    # On entering local-only mode, clear consecutive_push_failures so a later
    # return to push mode starts from a clean counter. Without this, a
    # push→local-only→push round-trip (operator removes then re-adds origin)
    # would carry the old failure count forward and could trigger a premature
    # HIGH escalation on the very first failure after origin returns.
    # pending_archive_push is intentionally NOT cleared here — it correctly
    # tracks that local commits still need to be pushed once origin returns.
    # shellcheck disable=SC2016  # $mode/$at are jq variables, not bash
    local jq_filter='.last_logged_mode = $mode | .last_logged_at = $at'
    if [ "$current_mode" = "local-only" ]; then
        jq_filter="$jq_filter | .consecutive_push_failures = 0 | del(.push_failure_escalated)"
    fi

    write_state_json "$(
        printf '%s\n' "$state_json" \
            | jq -c --arg mode "$current_mode" --arg at "$now" "$jq_filter"
    )"
}

set_pending_spike_alert() {
    local db="$1"
    local prev_count="$2"
    local current_count="$3"
    local delta="$4"
    local threshold="$5"

    write_state_json "$(
        read_state_json \
            | normalize_pending_spike_alert_state \
            | jq -c \
            --arg db "$db" \
            --argjson prev_count "$prev_count" \
            --argjson current_count "$current_count" \
            --argjson delta "$delta" \
            --argjson threshold "$threshold" \
            '.pending_spike_alerts[$db] = {
                database: $db,
                prev_count: $prev_count,
                current_count: $current_count,
                delta: $delta,
                threshold: $threshold
            }'
    )"
}

clear_pending_spike_alert() {
    local db="${1:-}"

    if [ -z "$db" ]; then
        write_state_json "$(read_state_json | jq -c 'del(.pending_spike_alert, .pending_spike_alerts)')"
        return
    fi

    write_state_json "$(
        read_state_json \
            | normalize_pending_spike_alert_state \
            | jq -c --arg db "$db" '
                del(.pending_spike_alerts[$db]) |
                if (.pending_spike_alerts // {}) == {} then
                    del(.pending_spike_alerts)
                else
                    .
                end
            '
    )"
}

send_spike_alert() {
    local db="$1"
    local prev_count="$2"
    local current_count="$3"
    local delta="$4"
    local threshold="$5"

    gc mail send mayor/ -s "ESCALATION: JSONL spike detected [HIGH]" \
        -m "Database: $db, prev: $prev_count, current: $current_count, delta: ${delta}%, threshold: ${threshold}%" \
        2>/dev/null
}

retry_pending_spike_alert() {
    local state_json
    local updated_state_json
    local state_changed=0
    local alert_json
    local pending_alerts=()
    local db
    local prev_count
    local current_count
    local delta
    local threshold

    state_json=$(read_state_json | normalize_pending_spike_alert_state)
    updated_state_json="$state_json"
    while IFS= read -r alert_json; do
        [ -n "$alert_json" ] || continue
        pending_alerts+=("$alert_json")
    done < <(
        printf '%s\n' "$state_json" \
            | jq -c '.pending_spike_alerts // {} | to_entries | sort_by(.key) | .[].value'
    )
    if [ "${#pending_alerts[@]}" -eq 0 ]; then
        return
    fi

    for alert_json in "${pending_alerts[@]}"; do
        db=$(printf '%s\n' "$alert_json" | jq -r '.database // empty')
        if [ -z "$db" ]; then
            continue
        fi
        prev_count=$(printf '%s\n' "$alert_json" | jq -r '.prev_count // 0')
        current_count=$(printf '%s\n' "$alert_json" | jq -r '.current_count // 0')
        delta=$(printf '%s\n' "$alert_json" | jq -r '.delta // 0')
        threshold=$(printf '%s\n' "$alert_json" | jq -r '.threshold // 0')

        if send_spike_alert "$db" "$prev_count" "$current_count" "$delta" "$threshold"; then
            updated_state_json=$(
                printf '%s\n' "$updated_state_json" \
                    | jq -c --arg db "$db" '
                        del(.pending_spike_alerts[$db]) |
                        if (.pending_spike_alerts // {}) == {} then
                            del(.pending_spike_alerts)
                        else
                            .
                        end
                    '
            )
            state_changed=1
            continue
        fi
        echo "jsonl-export: pending spike alert delivery failed for $db" >&2
    done

    if [ "$state_changed" -eq 1 ]; then
        write_state_json "$updated_state_json"
    fi
}

# Retain only the last ~20 lines of stderr so an extremely chatty failure
# doesn't drown the escalation body.
truncate_stderr_context() {
    local raw="$1"

    [ -z "$raw" ] && return 0
    printf '%s\n' "$raw" | tail -n 20
}

push_archive_main() {
    local consecutive
    local fetch_err
    local rebase_err
    local push_err
    local push_attempt
    local push_succeeded

    record_archive_push_failure() {
        local message="$1"
        local stderr_context="$2"
        local body
        local stderr_display
        local already_escalated
        local state_stderr=""

        echo "$message" >&2
        if [ -n "$stderr_context" ]; then
            state_stderr=$(truncate_push_stderr_for_state "$stderr_context")
        fi
        consecutive=$(read_state_json | jq -r '.consecutive_push_failures // 0' || echo "0")
        consecutive=$((consecutive + 1))
        write_state_json "$(
            read_state_json \
                | jq -c \
                    --argjson count "$consecutive" \
                    --arg stderr "$state_stderr" \
                    '.consecutive_push_failures = $count
                     | .pending_archive_push = true
                     | if $stderr == "" then del(.last_push_stderr) else .last_push_stderr = $stderr end'
        )"

        already_escalated=$(read_state_json | jq -r '.push_failure_escalated // false' || echo "false")
        if [ "$consecutive" -ge "$MAX_PUSH_FAILURES" ] && [ "$already_escalated" != "true" ]; then
            stderr_display=$(truncate_stderr_context "$stderr_context")
            if [ -z "$stderr_display" ]; then
                stderr_display="(no stderr captured)"
            fi
            body=$(cat <<ESCALATION
Order: jsonl-export
Archive: $ARCHIVE_REPO
Consecutive failures: $consecutive (threshold: $MAX_PUSH_FAILURES)

Last git push stderr:
$stderr_display

Remediation:
- Check remote: git -C $ARCHIVE_REPO remote -v
- Verify remote is reachable and credentials are valid
- Temporarily suppress: export GC_JSONL_MAX_PUSH_FAILURES=99
- See docs/getting-started/troubleshooting.md#jsonl-archive-push-failures
ESCALATION
)
            if gc mail send mayor/ -s "ESCALATION: JSONL push failed [HIGH]" \
                -m "$body" \
                2>/dev/null; then
                mark_push_failure_escalated
            fi
        fi

        return 1
    }

    # Branch on the actual git exit status, not on whether stderr is non-empty.
    # Successful git commands can emit benign stderr (e.g. "warning: redirecting
    # to https://...", credential-helper notes, protocol upgrade hints) which
    # would otherwise misclassify the run as a failure and falsely escalate.
    if ! fetch_err=$(git fetch origin main -q 2>&1 >/dev/null); then
        if git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
            record_archive_push_failure \
                "jsonl-export: fetching origin/main failed" \
                "$fetch_err"
            return 1
        fi
        echo "jsonl-export: origin/main missing; attempting initial push bootstrap" >&2
    fi

    if git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1; then
        if ! git merge-base --is-ancestor refs/remotes/origin/main HEAD >/dev/null 2>&1; then
            if ! rebase_err=$(git rebase refs/remotes/origin/main 2>&1 >/dev/null); then
                git rebase --abort >/dev/null 2>&1 || true
                record_archive_push_failure \
                    "jsonl-export: rebase onto origin/main failed during archive push recovery" \
                    "$rebase_err"
                return 1
            fi
        fi
        if ! archive_has_local_only_commits_from_tracking; then
            record_archive_push_success
            return 0
        fi
    fi

    # Retry-with-backoff for transient push failures. Concurrent rigs pushing
    # to the same local bare archive can race on the ref-update lock or produce
    # non-fast-forward (a sibling rig commits between our fetch and our push).
    # Retry up to 3 times with jitter; re-fetch and rebase before each retry to
    # absorb any new commits. Delay bounds default to 1-5s and are overridden
    # in tests to keep failure-path coverage fast.
    push_succeeded=false
    for push_attempt in 1 2 3; do
        if push_err=$(git push origin main -q 2>&1 >/dev/null); then
            push_succeeded=true
            if [ "$push_attempt" -gt 1 ]; then
                echo "jsonl-export: push succeeded on retry attempt $push_attempt" >&2
            fi
            break
        fi

        if [ "$push_attempt" -lt 3 ]; then
            sleep "$(push_retry_delay_seconds)"

            # Refresh origin tracking before retry — a sibling rig may have
            # moved the ref while we slept.
            if fetch_err=$(git fetch origin main -q 2>&1 >/dev/null); then
                if git rev-parse --verify refs/remotes/origin/main >/dev/null 2>&1 \
                    && ! git merge-base --is-ancestor refs/remotes/origin/main HEAD >/dev/null 2>&1; then
                    if ! rebase_err=$(git rebase refs/remotes/origin/main 2>&1 >/dev/null); then
                        git rebase --abort >/dev/null 2>&1 || true
                        record_archive_push_failure \
                            "jsonl-export: rebase onto origin/main failed during retry $push_attempt" \
                            "$rebase_err"
                        return 1
                    fi
                fi
            fi
            # If fetch failed, fall through and retry the push anyway —
            # origin may just be momentarily unavailable.
        fi
    done

    if [ "$push_succeeded" != "true" ]; then
        record_archive_push_failure \
            "jsonl-export: pushing archive main failed after 3 attempts" \
            "$push_err"
        return 1
    fi

    record_archive_push_success
    return 0
}

# compaction_in_flight — 0 when jsonl-archive-compact.sh is running right now, 1 when it is not. Every `git commit` runs `git maintenance run --auto --quiet --detach`, and on
# git 2.54 that is a geometric repack that merges and DELETES the loose-*.pack batch packs the compactor made — 19+ minutes of it under this host's load, with no lock file
# (git's goes with the forking parent). Started while the compactor's consolidating gc runs, it makes the gc die with "could not find pack 'loose-....pack'" (ga-8z0hy7;
# header of jsonl-archive-compact.sh, ONE REPACKER AT A TIME). So a commit that lands during a compaction run commits with maintenance.auto=false, and the next commit after
# the run goes back to the window rule of commit_archive_snapshot (ga-wkoij7) — this lock only delays git's consolidation, it never switches it off. The lock is the compactor's own: a directory holding its owner's pid. No directory = not in
# flight. A directory whose owner is dead (a run SIGKILLed by the order's timeout; the compactor itself reclaims it on its next run) is not in flight either — otherwise a
# compactor that never runs again would keep git's consolidation off for good. (`kill -0` fails the same way for a live process of ANOTHER user; both orders run as one user here,
# so a failure means dead.) A directory with no readable pid (the instant between its mkdir and its pid write, or a pid file
# that cannot be read) counts as in flight: under doubt a commit that starts no background run is the harmless side.
compaction_in_flight() {
    local owner
    [ -d "$COMPACT_LOCK" ] || return 1
    owner="$(cat "$COMPACT_LOCK/pid" 2>/dev/null)" || return 0
    case "$owner" in ''|*[!0-9]*) return 0 ;; esac
    kill -0 "$owner" 2>/dev/null
}

# commit_archive_snapshot — `git commit` of the staged snapshot, with git's background maintenance decided HERE and never left to git (ga-wkoij7). Three cases:
#   - a compaction run is in flight (compaction_in_flight): maintenance.auto=false — ga-8z0hy7, above;
#   - the repack window is open and the disk has room (jaw_repack_allowed): maintenance.auto=true on this one commit — git's geometric repack is the consolidation that works here.
#     Athos's window is 00:00-06:00 (15/10); a commit may START it until 04:59 only — a technical choice, not his: the repack takes 19+ minutes and, detached, cannot be stopped when
#     the window closes (see jsonl-archive-repack-window-lib.sh);
#   - anything else — the rest of the day, no room, the clock or the disk unreadable: maintenance.auto=false and gc.auto=0, so the commit starts nothing even in a repo recreated
#     without the keys ensure_archive_pack_config writes.
# The first case is checked first so a compaction run never has a second repacker started under it, window or not.
commit_archive_snapshot() {
    local message="$1"
    local context="$2"
    local maint="off"

    if compaction_in_flight; then
        echo "jsonl-export: a compaction run is in flight — $context commit starts no background maintenance (ga-8z0hy7)"
    elif jaw_repack_allowed "$ARCHIVE_REPO/.git"; then
        maint="window"   # a refusal is already logged, with its reason, by jaw_repack_allowed
    fi

    # Two spellings, not one with an optional -c: an empty argument array is an unbound variable under `set -u` on /bin/bash 3.2.
    if [ "$maint" = window ]; then
        if ! GIT_AUTHOR_NAME="Gas Town Daemon" \
            GIT_AUTHOR_EMAIL="daemon@gastown.local" \
            GIT_COMMITTER_NAME="Gas Town Daemon" \
            GIT_COMMITTER_EMAIL="daemon@gastown.local" \
            git -c maintenance.auto=true commit -q -m "$message"; then
            echo "jsonl-export: $context commit failed" >&2
            return 1
        fi
    elif ! GIT_AUTHOR_NAME="Gas Town Daemon" \
        GIT_AUTHOR_EMAIL="daemon@gastown.local" \
        GIT_COMMITTER_NAME="Gas Town Daemon" \
        GIT_COMMITTER_EMAIL="daemon@gastown.local" \
        git -c maintenance.auto=false -c gc.auto=0 commit -q -m "$message"; then
        echo "jsonl-export: $context commit failed" >&2
        return 1
    fi
}

discard_failed_db_outputs() {
    local db="$1"

    rm -rf "$ARCHIVE_REPO/$db"
    rm -f "$ARCHIVE_REPO/$db.jsonl"

    if git -C "$ARCHIVE_REPO" cat-file -e "HEAD:$db/issues.jsonl" 2>/dev/null; then
        git -C "$ARCHIVE_REPO" restore --source=HEAD --worktree -- "$db" >/dev/null 2>&1 || true
    fi
    if git -C "$ARCHIVE_REPO" cat-file -e "HEAD:$db.jsonl" 2>/dev/null; then
        git -C "$ARCHIVE_REPO" restore --source=HEAD --worktree -- "$db.jsonl" >/dev/null 2>&1 || true
    fi
}

discard_staged_archive_outputs() {
    local path

    if [ "${#STAGE_PATHS[@]}" -eq 0 ]; then
        return
    fi

    git reset -q -- "${STAGE_PATHS[@]}" >/dev/null 2>&1 || true
    for path in "${STAGE_PATHS[@]}"; do
        if git cat-file -e "HEAD:$path" 2>/dev/null; then
            git restore --source=HEAD --staged --worktree -- "$path" >/dev/null 2>&1 || true
            git clean -fd -- "$path" >/dev/null 2>&1 || true
            continue
        fi
        rm -rf "$path"
    done
}

# purge_stray_export_tmp — leftovers of exports killed under the old layout, when the scratch file lived inside the archive (ga-aai87v): 19 sit in the archive's HEAD, more may be
# untracked in the working tree. They are never archive content (the snapshot is <db>/issues.jsonl). Unstage and delete them so the commit that carries this run's snapshot also drops
# them from HEAD (their blobs stay in git history). Runs inside $ARCHIVE_REPO, before `git add`, and only when this run has a snapshot to commit.
purge_stray_export_tmp() {
    local tracked f dropped=0

    # vazio → no scratch file in the index, nothing to unstage; falhou → warn and leave the index alone (the `git add` exclude keeps them from being re-added)
    if tracked=$(git ls-files -- ':(glob)*/issues.jsonl.tmp.*'); then
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if git rm -q --cached --ignore-unmatch -- "$f"; then
                dropped=$((dropped + 1))
            else
                echo "jsonl-export: could not unstage the stray scratch file $f" >&2
            fi
        done <<EOF
$tracked
EOF
    else
        echo "jsonl-export: could not list tracked scratch files (git ls-files failed); leaving them for the next run" >&2
    fi

    # vazio → nothing left in the working tree; falhou (rm) → warn: the file stays untracked and the `git add` exclude keeps it out of the commit
    for f in "$ARCHIVE_REPO"/*/issues.jsonl.tmp.*; do
        [ -e "$f" ] || continue
        rm -f -- "$f" || echo "jsonl-export: could not remove the stray scratch file $f" >&2
    done

    if [ "$dropped" -gt 0 ]; then
        echo "jsonl-export: dropped $dropped stray scratch file(s) (issues.jsonl.tmp.*) from the archive (ga-aai87v)"
    fi
}

# State file for tracking consecutive push failures.
STATE_FILE="$PACK_STATE_DIR/jsonl-export-state.json"

if [ -z "${GC_JSONL_ARCHIVE_REPO:-}" ] && [ ! -d "$ARCHIVE_REPO/.git" ] && [ -d "$LEGACY_ARCHIVE_REPO/.git" ]; then
    ARCHIVE_REPO="$LEGACY_ARCHIVE_REPO"
fi
if [ ! -e "$STATE_FILE" ] && [ -e "$LEGACY_STATE_FILE" ]; then
    STATE_FILE="$LEGACY_STATE_FILE"
fi
STATE_FILE_BACKUP="${STATE_FILE}.bak"
mkdir -p "$(dirname "$STATE_FILE")"

log_archive_mode_if_needed
retry_pending_spike_alert

# The disk-aware cadence (ga-j2f5v5; the rule and the reasons are above jex_cadence_verdict). Decided here, before any Dolt query, so a skipped tick costs one df and one state read and sends no DOG_DONE nudge;
# the pending spike alert above is retried on every tick, skipped or not. last_export_at is stamped later (jex_stamp_export_start), only once a run is really about to export.
JEX_LOG="${JEX_LOG:-$CITY/.gc/logs/jsonl-export.log}"

# jex_log <text> — one dated line in $JEX_LOG, trimmed to its last 300 lines once it passes 1000. falhou → a warning on stderr and the run goes on: the log is the trace, never a precondition of the export.
jex_log() {
    local n
    if ! { mkdir -p "$(dirname "$JEX_LOG")" && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$JEX_LOG"; } 2>/dev/null; then
        echo "jsonl-export: could not write the log $JEX_LOG" >&2
        return 0
    fi
    # vazio/ilegível → no count, no trim (the file only grows by a line a tick until the next readable count)
    n=$(wc -l < "$JEX_LOG" 2>/dev/null | tr -d ' ') || n=""
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$n" -gt 1000 ]; then
        if tail -n 300 "$JEX_LOG" > "$JEX_LOG.tmp.$$" 2>/dev/null; then
            mv -f "$JEX_LOG.tmp.$$" "$JEX_LOG" 2>/dev/null || rm -f "$JEX_LOG.tmp.$$"
        else
            rm -f "$JEX_LOG.tmp.$$"
        fi
    fi
    return 0
}

# The clock: JEX_NOW_EPOCH pins it in selftests. vazio/ilegível → "" and, on a low disk, the verdict says run (clock-unreadable).
JEX_NOW="${JEX_NOW_EPOCH:-}"
case "$JEX_NOW" in ''|*[!0-9]*) JEX_NOW="$(date +%s 2>/dev/null)" || JEX_NOW="" ;; esac
case "$JEX_NOW" in *[!0-9]*) JEX_NOW="" ;; esac

JEX_DECISION="run|guard-off"
JEX_FREE=""
if [ "$JEX_DISK_LIB_OK" = "1" ]; then
    # vazio → the disk could not be read (""), the verdict is run; falhou → same
    JEX_FREE="$(disk_free_mb)" || JEX_FREE=""
    # vazio → never stamped ("" → run); falhou/ilegível (state, jq or the date unreadable) → "unreadable" → run, with that reason in the log
    JEX_LAST_ISO="$(read_state_json | jq -r '.last_export_at // empty' 2>/dev/null)" || JEX_LAST_ISO="unreadable"
    JEX_LAST=""
    if [ -n "$JEX_LAST_ISO" ]; then
        JEX_LAST="$(jq -nr --arg t "$JEX_LAST_ISO" '$t | fromdateiso8601 | floor | tostring' 2>/dev/null)" || JEX_LAST="unreadable"
    fi
    JEX_DECISION="$(jex_cadence_verdict "$JEX_FREE" "$JEX_LAST" "$JEX_NOW")"
else
    echo "jsonl-export: $SCRIPT_DIR/disk-headroom-lib.sh could not be loaded — the disk-aware cadence is OFF and this run exports (ga-j2f5v5)" >&2
    jex_log "run (guard-off) — disk-headroom-lib.sh could not be loaded from $SCRIPT_DIR"
fi
JEX_VERDICT="${JEX_DECISION%%|*}"
JEX_WHY="${JEX_DECISION#*|}"
if [ "$JEX_VERDICT" = "skip" ]; then
    echo "jsonl-export: skipped-low-disk (cadência estendida) — $JEX_WHY"
    jex_log "skipped-low-disk (cadência estendida) — $JEX_WHY"
    exit 0
fi
case "$JEX_WHY" in
    disk-ok|guard-off) ;;
    *) jex_log "run ($JEX_WHY) free=${JEX_FREE:-unreadable}MB" ;;
esac

# jex_stamp_export_start — last_export_at = the instant this run DECIDED to export (JEX_NOW, not the moment the state is written), so the cadence is counted from tick to tick. Called once the databases are listed
# and before the first export, never earlier: a tick that finds Dolt down or no database exports nothing and must not use up the hour. falhou → rc 1 and the caller warns: with no stamp the next tick simply
# runs (the verdict's "no-last-export"), it never skips on a guess.
jex_stamp_export_start() {
    local iso updated
    iso="$(jq -nr --argjson e "${JEX_NOW:-x}" '$e | todate' 2>/dev/null)" || iso=""
    [ -n "$iso" ] || { echo "jsonl-export: no clock reading, last_export_at not stamped" >&2; return 1; }
    # falhou/vazio (jq cannot rewrite the state) → nothing is written: an empty answer must never replace the state file, which also holds pending_spike_alerts and the push counters
    updated="$(read_state_json | jq -c --arg t "$iso" '.last_export_at = $t' 2>/dev/null)" || updated=""
    [ -n "$updated" ] || { echo "jsonl-export: could not build the updated state, last_export_at not stamped" >&2; return 1; }
    write_state_json "$updated"
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

# Discover databases. Exclude Dolt/MySQL system schemas, Gas City's internal
# health-probe database, and test-fixture scratch databases (benchdb,
# testdb_*, lowercase beads_t[0-9a-f]{8,}, beads_pt*, beads_vr*,
# beads_test_bench_*, doctest_*, doctortest_* — matching the Go cleanup
# planner contract); the remaining databases are expected to be bead stores.
DATABASES=$(
    while IFS= read -r db; do
        if is_user_database "$db"; then
            printf '%s\n' "$db"
        fi
    done < <(dolt_sql -r csv -q "SHOW DATABASES" 2>/dev/null | tail -n +2)
)
if [ -z "$DATABASES" ]; then
    if [ -d "$ARCHIVE_REPO/.git" ]; then
        cd "$ARCHIVE_REPO"
        if has_pending_archive_push || archive_has_local_only_commits; then
            if should_attempt_push; then
                PUSH_STATUS="ok"
                if ! push_archive_main; then
                    PUSH_STATUS="failed"
                fi
            else
                PUSH_STATUS="skipped (local-only)"
            fi
            SUMMARY="jsonl — no user databases, push: $PUSH_STATUS"
            gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
            echo "jsonl-export: $SUMMARY"
        fi
    fi
    exit 0
fi

# Ensure archive repo exists.
if [ ! -d "$ARCHIVE_REPO/.git" ]; then
    mkdir -p "$ARCHIVE_REPO"
    git -C "$ARCHIVE_REPO" init -q 2>/dev/null || true
fi
ensure_archive_pack_config "$ARCHIVE_REPO"

# Where the issues export's scratch file lives (ga-aai87v). It used to be mktemp'd INSIDE $ARCHIVE_REPO/<db>/ — the directory `git add -A -- <db>` stages — and the engine's SIGKILL at
# the order's timeout (no trap runs) left it there for the NEXT run's commit: 19 of them (16 MB) reached the archive's HEAD, a 25 MB one was next, and the S3 mirror copies the working
# tree. Outside the archive a dead run's leftover is just a file nobody stages. A sibling of the archive (same parent, so the same filesystem unless the archive itself is a mount
# point) keeps the final `mv` into place a rename.
EXPORT_TMP_DIR="${GC_JSONL_EXPORT_TMP_DIR:-$(dirname "$ARCHIVE_REPO")/.jsonl-export-tmp}"
# A dead run's scratch file is swept once it is older than this many minutes. Keep it far above the order's timeout (jsonl-export.toml), so a sweep can never take the file of a run
# that is still going; the price of a long age is only the disk a killed run's file holds meanwhile.
EXPORT_TMP_SWEEP_MIN=240
# falhou → exit 1 before anything is exported: the archive keeps its last snapshot (never a fallback to a path inside the archive)
if ! mkdir -p "$EXPORT_TMP_DIR"; then
    echo "jsonl-export: cannot create the scratch dir $EXPORT_TMP_DIR — nothing exported this run" >&2
    exit 1
fi
# vazio → nothing to sweep; falhou → warn and carry on (a leftover outside the archive costs disk, never a commit)
if ! find "$EXPORT_TMP_DIR" -maxdepth 1 -type f -name '*.jsonl.tmp.*' -mmin +"$EXPORT_TMP_SWEEP_MIN" -delete; then
    echo "jsonl-export: could not sweep old scratch files in $EXPORT_TMP_DIR" >&2
fi

# Build scrub filter for the issues table.
SCRUB_FILTER=""
if [ "$SCRUB" = "true" ]; then
    SCRUB_FILTER="WHERE issue_type NOT IN ('message', 'event', 'wisp', 'agent') AND title NOT LIKE 'gc:%' AND title NOT LIKE 'order:%' AND NOT (issue_type = 'convoy' AND title LIKE 'sling-%')"
fi

TOTAL_EXPORTED=0
TOTAL_DBS=0
FAILED_DBS=""
FAILED_DB_COUNT=0
HALTED=0
STAGE_PATHS=()
HALT_DB=""
HALT_PREV_COUNT=0
HALT_CURRENT_COUNT=0
HALT_DELTA=0
# Set by should_halt_for_jsonl_spike when it decides a drop is a short export;
# the caller reports it next to the export's own count.
SHORT_EXPORT_SOURCE_COUNT=""

valid_database_identifier() {
    local name="$1"

    case "$name" in
        ''|-*|*[!A-Za-z0-9_-]*)
            return 1
            ;;
    esac

    return 0
}

read_source_issue_count() {
    local db="$1"
    local output
    local count

    if ! output=$(dolt_sql -r csv -q "SELECT COUNT(*) AS row_count FROM \`$db\`.issues $SCRUB_FILTER" 2>/dev/null); then
        return 1
    fi
    count=$(printf '%s\n' "$output" | tail -n 1 | tr -d '\r')
    case "$count" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    printf '%s\n' "$count"
}

# How does this export compare with the source? (ga-7sxdmb) Prints ONE of:
#   short     the source count is readable AND the export is more than the slack
#             below it — positive evidence of a partial export;
#   complete  the source count is readable AND the export is within the slack;
#   unknown   the source count (or the export's own count) could not be read.
# Three answers on purpose. This was a yes/no return code and an unreadable source
# came out as "no" — the answer a verified-complete export gets — so the export was
# committed with nothing in the log, the summary or the commit to say that nobody
# had checked it. A caller must send anything but "complete" and "short" down the
# unknown path. The caller passes the RAW export count — same SQL filter as the
# source count — never the post-scrub one: rows only the jq scrub removes would
# otherwise read as missing rows on every run and stall the archive.
export_vs_source_verdict() {
    local raw_count="$1"
    local source_count="$2"
    local slack

    case "$raw_count" in ''|*[!0-9]*) echo unknown; return 0 ;; esac
    case "$source_count" in ''|*[!0-9]*) echo unknown; return 0 ;; esac

    slack=$(( source_count * SHORT_EXPORT_SLACK_PCT / 100 ))
    if [ "$slack" -lt "$SHORT_EXPORT_MIN_SLACK" ]; then
        slack="$SHORT_EXPORT_MIN_SLACK"
    fi
    if [ $(( raw_count + slack )) -lt "$source_count" ]; then
        echo short
    else
        echo complete
    fi
}

# DBs whose export went into the archive WITHOUT being checked against the source
# (its COUNT(*) could not be read), one name per line like FAILED_DBS. Filled by
# record_unverified_db; every closing summary and commit message reads it.
UNVERIFIED_DBS=""
DB_UNVERIFIED=0

# Called where a DB's export is staged, so a DB discarded later in the loop is
# reported as failed and never as "unverified".
record_unverified_db() {
    if [ "$DB_UNVERIFIED" -eq 1 ]; then
        UNVERIFIED_DBS="${UNVERIFIED_DBS}$DB
"
    fi
}

# ", unverified: wa " for a run summary / DOG_DONE nudge; empty when every export
# was checked. Called from every exit that reports the run.
unverified_note() {
    if [ -n "$UNVERIFIED_DBS" ]; then
        printf ', unverified: %s' "$(printf '%s' "$UNVERIFIED_DBS" | tr '\n' ' ')"
    fi
}

# " unverified=wa,hq" for an archive commit message (durable: the snapshot itself
# says it was never checked); empty when every export was checked.
unverified_commit_note() {
    if [ -n "$UNVERIFIED_DBS" ]; then
        printf ' unverified=%s' "$(printf '%s' "$UNVERIFIED_DBS" | paste -sd, -)"
    fi
}

# The supplemental tables (comments, config, dependencies, labels, metadata) of a DB whose previous version was KEPT because this run could not read them whole
# (ga-l6v576), as "db(comments,labels)" lines like FAILED_DBS. Filled by record_short_tables where the DB's export is staged; DB_SHORT_TABLES is the loop's own accumulator.
PARTIAL_DBS=""
DB_SHORT_TABLES=""

# A DB with a kept table is reported as failed (the run did not export it whole) with the tables named, next to the verified issues that are still committed. Called where a DB's
# export is staged, like record_unverified_db, so a DB discarded later in the loop is counted once.
record_short_tables() {
    if [ -n "$DB_SHORT_TABLES" ]; then
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB($DB_SHORT_TABLES)
"
        PARTIAL_DBS="${PARTIAL_DBS}$DB($DB_SHORT_TABLES)
"
    fi
}

# " partial=wa(comments)" for an archive commit message (durable: the snapshot says which table kept its previous version); empty when every table was read whole.
partial_commit_note() {
    if [ -n "$PARTIAL_DBS" ]; then
        printf ' partial=%s' "$(printf '%s' "$PARTIAL_DBS" | paste -sd, -)"
    fi
}

# <db>.<table>'s own row count, unfiltered (ga-l6v576). vazio → never printed: an unreadable count is `return 1`, never a 0 that would read as "the table is empty".
read_source_table_count() {
    local db="$1" table="$2" output count

    if ! output=$(dolt_sql -r csv -q "SELECT COUNT(*) AS row_count FROM \`$db\`.\`$table\`" 2>/dev/null); then
        return 1
    fi
    count=$(printf '%s\n' "$output" | tail -n 1 | tr -d '\r')
    case "$count" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    printf '%s\n' "$count"
}

# The ORDER BY list that pages <db>.<table> by its primary key, e.g. "`issue_id`, `label`"; prints an empty line when the table has no key.
# vazio (no key) → the caller reads the table in ONE query, which the count check still gates; falhou/ilegível → return 1, and the caller does the same and says so.
table_order_by() {
    local db="$1" table="$2" output col list=""

    if ! output=$(dolt_sql -r csv -q "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = '$db' AND TABLE_NAME = '$table' AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION" 2>/dev/null); then
        return 1
    fi
    while IFS= read -r col; do
        col=$(printf '%s' "$col" | tr -d '\r')
        [ -n "$col" ] || continue
        # A name that is not plain is never put into SQL.
        case "$col" in *[!A-Za-z0-9_]*) return 1 ;; esac
        list="${list:+$list, }\`$col\`"
    done <<EOF
$(printf '%s\n' "$output" | tail -n +2)
EOF
    printf '%s\n' "$list"
}

SUPP_RAW_ROWS=""

# Reads <db>.<table> into the file <base> (ga-l6v576) and sets SUPP_RAW_ROWS to the rows that file holds (the sum of the pages' own counts: hq.comments is 363 MB, and a `jq -s`
# over the joined file would hold all of it in memory). Scratch files are <base>.p<N> (the pages), <base>.rows and <base>.err (Dolt's stderr); the caller removes <base>.*.
# One read that runs past ~40 s is cut by Dolt — a well-formed document, exit 0, "unexpected EOF" on stderr — so a table is read in pages of SUPP_CHUNK_ROWS rows ordered by its
# primary key, each short enough to finish; a table with no key is read in one query. A single page is kept exactly as Dolt wrote it; several are joined in the same shape.
# Return 0 → <base> holds a document; return 1 → the read failed (Dolt's exit code, or a page that is not a JSON document), Dolt's stderr is in the log, <base> is junk.
# A page that comes back short ends the paging as if it were the last, so a cut page shows up as missing rows to the count check, not as a hang.
read_table_pages() {
    local db="$1" table="$2" order_by="$3" base="$4"
    local offset=0 n=0 i rows query total=0

    : > "$base.err"
    SUPP_RAW_ROWS=""
    while :; do
        n=$((n + 1))
        if [ -n "$order_by" ]; then
            query="SELECT * FROM \`$db\`.\`$table\` ORDER BY $order_by LIMIT $SUPP_CHUNK_ROWS OFFSET $offset"
        else
            query="SELECT * FROM \`$db\`.\`$table\`"
        fi
        if ! dolt_sql -r json -q "$query" > "$base.p$n" 2>>"$base.err"; then
            echo "jsonl-export: reading $db.$table failed (page $n; dolt exited non-zero): $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
            return 1
        fi
        # vazio (a 0-byte page) → an error, not a table with no rows: Dolt prints {} for that
        if ! rows=$(jq -s -r 'if length == 0 then error("empty page") else ((.[0].rows // []) | length) end' "$base.p$n" 2>/dev/null); then
            echo "jsonl-export: reading $db.$table returned an unreadable document (page $n): $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
            return 1
        fi
        total=$((total + rows))
        if [ -z "$order_by" ] || [ "$rows" -lt "$SUPP_CHUNK_ROWS" ]; then
            break
        fi
        if [ "$n" -ge "$SUPP_MAX_PAGES" ]; then
            echo "jsonl-export: reading $db.$table needs more than $SUPP_MAX_PAGES pages of $SUPP_CHUNK_ROWS rows" >&2
            return 1
        fi
        offset=$((offset + SUPP_CHUNK_ROWS))
    done

    if [ "$n" -eq 1 ]; then
        mv -f "$base.p1" "$base" || return 1
    else
        : > "$base.rows"
        i=1
        while [ "$i" -le "$n" ]; do
            jq -c '.rows[]?' "$base.p$i" >> "$base.rows" || return 1
            i=$((i + 1))
        done
        # Dolt's own shape: {"rows": [row,row]}. The rows are one JSON line each, so the only newline paste leaves is its last.
        { printf '{"rows": ['; paste -sd, - < "$base.rows" | tr -d '\n'; printf ']}\n'; } > "$base" || return 1
    fi
    SUPP_RAW_ROWS="$total"
    return 0
}

# Puts the previous version of <db>/<table>.jsonl back in the working tree; a table with no previous version ends up with no file. Return 1 only when git cannot restore it.
keep_previous_table() {
    local db="$1" table="$2" path="$1/$2.jsonl"

    if git -C "$ARCHIVE_REPO" cat-file -e "HEAD:$path" 2>/dev/null; then
        git -C "$ARCHIVE_REPO" restore --source=HEAD --worktree -- "$path" >/dev/null 2>&1
    else
        rm -f "$ARCHIVE_REPO/$path"
    fi
}

# Exports <db>.<table> into $DB_DIR/<table>.jsonl (ga-l6v576), checked against the table's own COUNT(*) read before and after the read. The export is built in the scratch dir
# and moves into the archive only when it passes. Returns:
#   0  whole: at least as many rows as the source has; it is now the file;
#   3  the source count could not be read, so nobody can say: the export is the file, flagged unverified — not discarded, a store whose count query is down must not freeze its archive;
#   1  not read whole in SUPP_EXPORT_ATTEMPTS tries (short, or the read failed): the file is NOT written and the previous version stays;
#   2  the previous version could not be put back: the caller discards the DB.
export_supplemental_table() {
    local db="$1" table="$2"
    local dest="$DB_DIR/$table.jsonl"
    local base order_by before after verdict attempt=1 rc

    # falhou (mktemp) → the table is not exported this run and its previous version stays
    if ! base=$(mktemp "$EXPORT_TMP_DIR/$table.jsonl.tmp.XXXXXX"); then
        echo "jsonl-export: cannot create the scratch file for $db.$table in $EXPORT_TMP_DIR" >&2
        keep_previous_table "$db" "$table" || return 2
        return 1
    fi
    # vazio (no key) / falhou (unreadable) → empty: one query, and the count check below still gates it
    if ! order_by=$(table_order_by "$db" "$table"); then
        echo "jsonl-export: primary key of $db.$table unreadable; reading the table in one query" >&2
        order_by=""
    fi
    while :; do
        # vazio → unreadable ("don't know", never 0): table_export_verdict reads it as the third state
        before=$(read_source_table_count "$db" "$table" || true)
        if read_table_pages "$db" "$table" "$order_by" "$base"; then
            after=$(read_source_table_count "$db" "$table" || true)
            verdict=$(table_export_verdict "$SUPP_RAW_ROWS" "$before" "$after")
            case "$verdict" in
                complete|unknown)
                    if [ "$verdict" = unknown ]; then
                        echo "jsonl-export: source count unavailable for $db.$table; export NOT verified against source (raw export: $SUPP_RAW_ROWS rows)" >&2
                    fi
                    rc=0
                    [ "$verdict" = complete ] || rc=3
                    if ! mv -f "$base" "$dest"; then
                        rm -f "$base" "$base".*
                        return 2
                    fi
                    rm -f "$base".*
                    return "$rc"
                    ;;
                *)
                    echo "jsonl-export: export curto de $db.$table: $SUPP_RAW_ROWS vs fonte ${before:-?}/${after:-?} (tentativa $attempt/$SUPP_EXPORT_ATTEMPTS): $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
                    ;;
            esac
        fi
        if [ "$attempt" -ge "$SUPP_EXPORT_ATTEMPTS" ]; then
            break
        fi
        attempt=$((attempt + 1))
        sleep "$SUPP_EXPORT_RETRY_DELAY"
    done

    rm -f "$base" "$base".*
    echo "jsonl-export: $db.$table fora do snapshot após $SUPP_EXPORT_ATTEMPTS tentativas, mantido o snapshot anterior" >&2
    keep_previous_table "$db" "$table" || return 2
    return 1
}

# Returns 0 to halt (growth spike, source unreadable, or a drop the source
# confirms) and 1 when the drop is the EXPORT coming up short while the source
# did not shrink. Return 1 does not mean the new file is a good snapshot — the
# caller must keep the previous one (ga-fxrrav).
should_halt_for_jsonl_spike() {
    local db="$1"
    local prev_count="$2"
    local current_count="$3"
    local threshold="$4"
    local source_count
    local source_drop

    # Growth spikes are still suspicious. Only drop spikes can be suppressed by
    # checking the Dolt source-of-truth behind the passive JSONL export.
    if [ "$current_count" -ge "$prev_count" ]; then
        return 0
    fi

    if ! source_count=$(read_source_issue_count "$db"); then
        echo "jsonl-export: source-of-truth count unavailable for $db; preserving JSONL spike halt" >&2
        return 0
    fi

    if [ "$source_count" -ge "$prev_count" ]; then
        echo "jsonl-export: suppressing JSONL drop spike for $db; source count $source_count >= previous $prev_count" >&2
        SHORT_EXPORT_SOURCE_COUNT="$source_count"
        return 1
    fi

    source_drop=$(( (prev_count - source_count) * 100 / prev_count ))
    if [ "$source_drop" -le "$threshold" ]; then
        echo "jsonl-export: suppressing JSONL drop spike for $db; source drop ${source_drop}% <= ${threshold}%" >&2
        SHORT_EXPORT_SOURCE_COUNT="$source_count"
        return 1
    fi

    return 0
}

# From here the run exports: spend this tick's slot of the disk-aware cadence (ga-j2f5v5). A stamp that cannot be written is a warning, not a stop — the next tick then runs instead of guessing.
if [ "$JEX_DISK_LIB_OK" = "1" ] && ! jex_stamp_export_start; then
    echo "jsonl-export: could not stamp last_export_at; the next tick will not be spaced out" >&2
fi

while IFS= read -r DB; do
    [ -z "$DB" ] && continue
    TOTAL_DBS=$((TOTAL_DBS + 1))
    DB_UNVERIFIED=0
    DB_SHORT_TABLES=""
    if ! valid_database_identifier "$DB"; then
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    if ! has_wisps_table "$DB"; then
        # Not a bd-managed bead store. Decrement the count we just
        # bumped — schemaless DBs aren't part of the export universe
        # and shouldn't appear in TOTAL_DBS or FAILED_DBS summaries.
        # See dolt-target.sh:has_wisps_table and gastownhall/gascity#1816.
        TOTAL_DBS=$((TOTAL_DBS - 1))
        continue
    fi

    DB_DIR="$ARCHIVE_REPO/$DB"
    mkdir -p "$DB_DIR"

    # The source's own row count, read BEFORE the export with the export's own
    # SQL filter (ga-7sxdmb). Empty means unreadable — "don't know", never 0; the
    # partial-export gate below reports it.
    SOURCE_BEFORE=$(read_source_issue_count "$DB" || true)

    # Step 1: Export issues table. The scratch file lives in $EXPORT_TMP_DIR, never under $DB_DIR (ga-aai87v).
    # falhou (mktemp) → this DB is not exported this run and its previous snapshot is restored, like every other failed step below
    if ! ISSUE_EXPORT_TMP=$(mktemp "$EXPORT_TMP_DIR/issues.jsonl.tmp.XXXXXX"); then
        echo "jsonl-export: cannot create the scratch file for $DB in $EXPORT_TMP_DIR" >&2
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    if ! dolt_sql -r json -q "SELECT * FROM \`$DB\`.issues $SCRUB_FILTER" > "$ISSUE_EXPORT_TMP" 2>/dev/null; then
        rm -f "$ISSUE_EXPORT_TMP"
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    if ! mv -f "$ISSUE_EXPORT_TMP" "$DB_DIR/issues.jsonl"; then
        rm -f "$ISSUE_EXPORT_TMP"
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi

    # Rows in the RAW export — before the jq scrub below rewrites the file — so it
    # is comparable with SOURCE_BEFORE (same SQL filter).
    RAW_EXPORT_COUNT=$(count_jsonl_rows < "$DB_DIR/issues.jsonl")

    # Export supplemental tables (ga-l6v576). Each one is read in pages and checked against its own COUNT(*), the way issues are above: a read that Dolt cut short is still a
    # well-formed document with exit 0 (29 of 37 hq snapshots had comments.jsonl at a multiple of 128 rows). Per table:
    #   whole       -> it is the file;
    #   short/failed-> not written, the previous version stays, the DB is reported as failed with the table named (issues still commit);
    #   unknown     -> the source count is unreadable: kept and flagged unverified, like issues;
    #   unrestorable-> the DB is discarded like any other failed step.
    SUPP_UNRESTORABLE=0
    for TABLE in $SUPP_TABLES; do
        SUPP_RC=0
        export_supplemental_table "$DB" "$TABLE" || SUPP_RC=$?
        case "$SUPP_RC" in
            0)
                ;;
            3)
                DB_UNVERIFIED=1
                ;;
            1)
                DB_SHORT_TABLES="${DB_SHORT_TABLES:+$DB_SHORT_TABLES,}$TABLE"
                ;;
            *)
                SUPP_UNRESTORABLE=1
                break
                ;;
        esac
    done
    if [ "$SUPP_UNRESTORABLE" -eq 1 ]; then
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi

    # Step 2: Validate the exported JSON payload and optionally scrub it. Even
    # when SCRUB=false we still fail the DB on malformed JSON so corrupt live
    # exports cannot silently score as zero rows and become the new baseline.
    TMPFILE=$(mktemp)
    if [ "$SCRUB" = "true" ]; then
        if ! scrub_exported_issues < "$DB_DIR/issues.jsonl" > "$TMPFILE"; then
            rm -f "$TMPFILE"
            discard_failed_db_outputs "$DB"
            FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
            FAILED_DBS="${FAILED_DBS}$DB
"
            continue
        fi
    elif ! validate_exported_issues < "$DB_DIR/issues.jsonl" > "$TMPFILE"; then
        rm -f "$TMPFILE"
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    if [ ! -s "$TMPFILE" ]; then
        echo "jsonl-export: issues export for $DB was empty" >&2
        rm -f "$TMPFILE"
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    if ! validate_exported_issues < "$TMPFILE" >/dev/null; then
        rm -f "$TMPFILE"
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
    mv -f "$TMPFILE" "$DB_DIR/issues.jsonl"

    # Legacy flat file mirrors the scrubbed per-db export. Keep the two output
    # shapes in sync so any downstream reader sees the same filtered payload.
    if ! cp -f "$DB_DIR/issues.jsonl" "$ARCHIVE_REPO/$DB.jsonl" 2>/dev/null; then
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi

    # Partial-export gate (ga-7sxdmb). Under load Dolt can hand back a truncated
    # result set that is still a well-formed document, so validation above cannot
    # tell. A partial export must not become the snapshot — nor, one cycle later,
    # the baseline that makes the next COMPLETE export read as a growth spike (a
    # false HIGH escalation). The spike check below only sees a drop bigger than
    # SPIKE_THRESHOLD against the previous snapshot; this gate compares with the
    # source at ANY size. Three outcomes:
    #   short    -> positive evidence of a partial export: discarded, the previous
    #               snapshot stays, the DB is reported as failed.
    #   complete -> goes on to the spike check.
    #   unknown  -> the source count could not be read, so nobody knows whether this
    #               export is partial. It is NOT discarded: freezing the archive of a
    #               store whose count query is down would be an outage of its own.
    #               It is never silent, though: logged here, listed as
    #               "unverified: <db>" in the run summary and the DOG_DONE nudge,
    #               and recorded in the commit message. What ELSE happens to it is
    #               the spike check's business, and that check only runs when the
    #               previous snapshot has >= MIN_PREV_FOR_SPIKE_CHECK rows AND the
    #               count moved by more than SPIKE_THRESHOLD — then an unreadable
    #               source means HALT + mail (ga-fxrrav). Any other unverified
    #               export (a smaller change, a first run, a small store) is
    #               committed with the flag as its only trace, and a truncated one
    #               can make the next complete export read as growth — a false
    #               alarm, the price ga-fxrrav already accepted for its HALT path.
    case "$(export_vs_source_verdict "$RAW_EXPORT_COUNT" "$SOURCE_BEFORE")" in
        complete)
            ;;
        short)
            echo "jsonl-export: export curto de $DB: $RAW_EXPORT_COUNT vs fonte $SOURCE_BEFORE, mantido o snapshot anterior" >&2
            discard_failed_db_outputs "$DB"
            FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
            FAILED_DBS="${FAILED_DBS}$DB
"
            continue
            ;;
        *)
            echo "jsonl-export: source count unavailable for $DB; export NOT verified against source (raw export: ${RAW_EXPORT_COUNT:-?} rows)" >&2
            DB_UNVERIFIED=1
            ;;
    esac

    # Count records from the final persisted payload (post-scrub / post-
    # validation) so commit messages and DOG_DONE summaries reflect what was
    # actually archived, not the pre-scrub raw export.
    CURRENT_COUNT=$(count_jsonl_rows < "$DB_DIR/issues.jsonl")

    # Step 3: Spike detection — compare record counts against previous commit.
    PREV_COUNT=0
    if git -C "$ARCHIVE_REPO" cat-file -e "HEAD:$DB/issues.jsonl" 2>/dev/null; then
        PREV_COUNT=$(git -C "$ARCHIVE_REPO" show "HEAD:$DB/issues.jsonl" 2>/dev/null | count_jsonl_rows || echo "0")
    fi

    # Skip the percentage check on the first run (no prior commit) and when
    # the previous count is below the absolute floor — a 1→2 swing is 100% but
    # meaningless on a tiny database. The PREV_COUNT > 0 guard also avoids the
    # division-by-zero on line `DELTA=...` when the floor is set to 0 to
    # disable the small-N skip.
    if [ "$PREV_COUNT" -gt 0 ] && [ "$PREV_COUNT" -ge "$MIN_PREV_FOR_SPIKE_CHECK" ]; then
        FILTERED_COUNT=$(count_jsonl_rows < "$DB_DIR/issues.jsonl")
        DELTA=$(( (FILTERED_COUNT - PREV_COUNT) * 100 / PREV_COUNT ))
        if [ "$DELTA" -lt 0 ]; then
            DELTA=$(( -DELTA ))
        fi
        if [ "$DELTA" -gt "$SPIKE_THRESHOLD" ]; then
            if should_halt_for_jsonl_spike "$DB" "$PREV_COUNT" "$FILTERED_COUNT" "$SPIKE_THRESHOLD"; then
                TOTAL_EXPORTED=$((TOTAL_EXPORTED + CURRENT_COUNT))
                STAGE_PATHS+=("$DB" "$DB.jsonl")
                record_unverified_db
                record_short_tables
                HALTED=1
                HALT_DB="$DB"
                HALT_PREV_COUNT="$PREV_COUNT"
                HALT_CURRENT_COUNT="$FILTERED_COUNT"
                HALT_DELTA="$DELTA"
                echo "jsonl-export: HALTED — spike in $DB (${DELTA}% > ${SPIKE_THRESHOLD}%)"
                break
            fi
            # The export fell by much more than the source did: this file is
            # an incomplete export, not a snapshot. Put the previous snapshot
            # back so it is not committed (or pushed offsite), and report the
            # DB as not exported this run. Committing it would also make the
            # next complete export read as a growth spike (ga-fxrrav).
            echo "jsonl-export: export curto de $DB: $CURRENT_COUNT vs fonte $SHORT_EXPORT_SOURCE_COUNT, mantido o snapshot anterior" >&2
            discard_failed_db_outputs "$DB"
            FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
            FAILED_DBS="${FAILED_DBS}$DB
"
            continue
        fi
    fi

    TOTAL_EXPORTED=$((TOTAL_EXPORTED + CURRENT_COUNT))
    STAGE_PATHS+=("$DB" "$DB.jsonl")
    record_unverified_db
    record_short_tables
done <<EOF
$DATABASES
EOF

cd "$ARCHIVE_REPO"
if [ "${#STAGE_PATHS[@]}" -gt 0 ]; then
    purge_stray_export_tmp
    # The exclude holds even if the purge above could not remove one: a scratch file is never staged (ga-aai87v).
    if ! git add -A -- "${STAGE_PATHS[@]}" ':(exclude,glob)**/issues.jsonl.tmp.*'; then
        discard_staged_archive_outputs
        echo "jsonl-export: staging archive outputs failed" >&2
        exit 1
    fi
fi

# On HALT we still commit the new export so PREV_COUNT advances on the next
# run — otherwise the same spike re-fires every cooldown and floods the inbox
# (#1547 root cause #3). Push is skipped, so the spike snapshot stays local
# until a later successful non-HALT run pushes the archive forward.
if [ "$HALTED" -eq 1 ]; then
    if ! git diff --cached --quiet 2>/dev/null; then
        EXPORTED_DBS=$((TOTAL_DBS - FAILED_DB_COUNT))
        commit_archive_snapshot \
            "[HALT] backup $(date -u +%Y-%m-%dT%H:%M:%SZ): exported=$EXPORTED_DBS/$TOTAL_DBS records=$TOTAL_EXPORTED$(unverified_commit_note)$(partial_commit_note) (spike detected; push skipped)" \
            "HALT baseline" || {
            discard_staged_archive_outputs
            exit 1
        }
        set_pending_archive_push
    fi
    set_pending_spike_alert "$HALT_DB" "$HALT_PREV_COUNT" "$HALT_CURRENT_COUNT" "$HALT_DELTA" "$SPIKE_THRESHOLD"
    if send_spike_alert "$HALT_DB" "$HALT_PREV_COUNT" "$HALT_CURRENT_COUNT" "$HALT_DELTA" "$SPIKE_THRESHOLD"; then
        clear_pending_spike_alert "$HALT_DB"
    else
        echo "jsonl-export: spike alert delivery failed; will retry from state" >&2
    fi
    gc session nudge deacon/ "DOG_DONE: jsonl — HALTED on spike detection$(unverified_note)" 2>/dev/null || true
    exit 0
fi

if git diff --cached --quiet 2>/dev/null; then
    if has_pending_archive_push || archive_has_local_only_commits; then
        if should_attempt_push; then
            PUSH_STATUS="ok"
            if ! push_archive_main; then
                PUSH_STATUS="failed"
            fi
        else
            PUSH_STATUS="skipped (local-only)"
        fi
        if [ -n "$FAILED_DBS" ]; then
            EXPORTED_DBS=$((TOTAL_DBS - FAILED_DB_COUNT))
            SUMMARY="jsonl — exported $EXPORTED_DBS/$TOTAL_DBS, records: $TOTAL_EXPORTED, push: $PUSH_STATUS, failed: $(printf '%s' "$FAILED_DBS" | tr '\n' ' ')"
        else
            SUMMARY="jsonl — no changes, push: $PUSH_STATUS"
        fi
        SUMMARY="$SUMMARY$(unverified_note)"
        gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
        echo "jsonl-export: $SUMMARY"
        exit 0
    fi
    if [ -n "$FAILED_DBS" ]; then
        EXPORTED_DBS=$((TOTAL_DBS - FAILED_DB_COUNT))
        SUMMARY="jsonl — exported $EXPORTED_DBS/$TOTAL_DBS, records: $TOTAL_EXPORTED, push: skipped, failed: $(printf '%s' "$FAILED_DBS" | tr '\n' ' ')$(unverified_note)"
        gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
        echo "jsonl-export: $SUMMARY"
        exit 0
    fi
    # No changes. This exit prints nothing on a clean run; an unverified one still
    # says so on stdout, next to the nudge.
    SUMMARY="jsonl — no changes$(unverified_note)"
    gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
    if [ -n "$UNVERIFIED_DBS" ]; then
        echo "jsonl-export: $SUMMARY"
    fi
    exit 0
fi

EXPORTED_DBS=$((TOTAL_DBS - FAILED_DB_COUNT))
commit_archive_snapshot \
    "backup $(date -u +%Y-%m-%dT%H:%M:%SZ): exported=$EXPORTED_DBS/$TOTAL_DBS records=$TOTAL_EXPORTED$(unverified_commit_note)$(partial_commit_note)" \
    "archive snapshot" || {
    discard_staged_archive_outputs
    exit 1
}
set_pending_archive_push

if should_attempt_push; then
    PUSH_STATUS="ok"
    if ! push_archive_main; then
        PUSH_STATUS="failed"
    fi
else
    PUSH_STATUS="skipped (local-only)"
fi

SUMMARY="jsonl — exported $EXPORTED_DBS/$TOTAL_DBS, records: $TOTAL_EXPORTED, push: $PUSH_STATUS"
if [ -n "$FAILED_DBS" ]; then
    SUMMARY="$SUMMARY, failed: $(printf '%s' "$FAILED_DBS" | tr '\n' ' ')"
fi
SUMMARY="$SUMMARY$(unverified_note)"

gc session nudge deacon/ "DOG_DONE: $SUMMARY" 2>/dev/null || true
echo "jsonl-export: $SUMMARY"

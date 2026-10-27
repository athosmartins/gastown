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

# A whole number from the environment, as a plain decimal (ga-l6v576). Prints <value> without its leading zeros when it is 1-9 digits and at least <min>; anything else — empty, a sign,
# a space, letters, too many digits, below the minimum — prints <default>. The numbers feed arithmetic, where bash reads 08 as a bad octal: 10# makes it eight. Pure.
env_whole_number() {
    local value="$1" default="$2" min="$3"

    case "$value" in ''|*[!0-9]*) printf '%s\n' "$default"; return 0 ;; esac
    if [ "${#value}" -gt 9 ]; then
        printf '%s\n' "$default"
        return 0
    fi
    value=$((10#$value))
    [ "$value" -ge "$min" ] || value="$default"
    printf '%s\n' "$value"
}

# The cursor of a keyset page (ga-l6v576): reads ONE row as a JSON object on stdin and prints its key columns <cols> (space-separated plain names) as the SQL literals that go
# into  WHERE (`id`, `seq`) > (<here>) , e.g. 'it''s', 3 . Strings are written the way MySQL reads them (' doubled, \ doubled, \n \r \t as escapes); a whole number of up to 15 digits is
# written as it is. Anything else is NOT written: a null or missing column, a boolean, a fraction, a control character, a document that is not JSON. Return 1 with nothing printed then,
# and the read stops instead of building SQL out of a key it cannot quote. Pure (jq only), so the selftest calls it in library mode.
key_tuple_literal() {
    local cols="$1"

    jq -r --arg cols "$cols" --arg q "'" '
        def lit:
            if type == "string" then
                explode
                | map(if . == 39 then [39, 39]
                      elif . == 92 then [92, 92]
                      elif . == 10 then [92, 110]
                      elif . == 13 then [92, 114]
                      elif . == 9 then [92, 116]
                      elif . < 32 or . == 127 then error("control character in a key")
                      else [.] end)
                | (add // []) | implode | $q + . + $q
            elif type == "number" and . == floor and (tostring | test("^-?[0-9]{1,15}$")) then tostring
            else error("key cannot be written") end;
        . as $row
        | if ($row | type) != "object" then error("not a row") else . end
        | [($cols | split(" ") | .[]) as $c | ($row[$c] | lit)] | join(", ")' 2>/dev/null
}

# Did a read of a table in pages hold every row that was in the table the whole time? (ga-l6v576) Takes three files of KEYS, one JSON array per line: the table's keys read BEFORE the
# rows (<before>), AFTER them (<after>), and the keys of the rows that came back (<export>). A key in <before> and <after> was in the table throughout, so the read must have it; a key
# only one sweep has was inserted or deleted while the read ran, and that is the writers' business, not a loss. Prints ONE of:
#   complete  every key that was there throughout is in the export (extra keys in the export are inserts the sweeps did not see);
#   short N   N such keys are not;
#   unknown   a file is missing or cannot be read — nobody can say (never "complete").
# Unlike a count this sees what paging a live table does wrong: a row skipped is a missing key even when a row inserted meanwhile makes the counts equal. Pure (awk only), so the
# selftest calls it in library mode.
table_keys_verdict() {
    local before="$1" after="$2" export_keys="$3" f missing

    for f in "$before" "$after" "$export_keys"; do
        if [ ! -f "$f" ] || [ ! -r "$f" ]; then
            echo unknown
            return 0
        fi
    done
    if ! missing=$(LC_ALL=C awk -v fb="$before" -v fa="$after" '
        FILENAME == fb { b[$0] = 1; next }
        FILENAME == fa { if ($0 in b) s[$0] = 1; next }
        { e[$0] = 1 }
        END { n = 0; for (k in s) if (!(k in e)) n++; print n }' "$before" "$after" "$export_keys" 2>/dev/null); then
        echo unknown
        return 0
    fi
    case "$missing" in
        ''|*[!0-9]*) echo unknown ;;
        0) echo complete ;;
        *) echo "short $missing" ;;
    esac
}

# How does a supplemental table's export compare with its source COUNT? (ga-l6v576) Used only for a table that cannot be paged by a key (it has none, or Dolt did not say); a keyed table
# is judged by table_keys_verdict, because a count cannot see rows that a read of a live table served twice or skipped. Prints ONE of:
#   short     a source count is readable AND the export has fewer rows than it;
#   complete  a source count is readable AND the export has at least that many rows;
#   unknown   no source count could be read (or the export's own count is not a number).
# Three answers, like export_vs_source_verdict below, for the same reason: an unreadable count must never read as "complete". Pure (no Dolt, no globals but the
# slack knob), so the selftest calls it in library mode.
# The table is counted BEFORE and AFTER the read. Rows deleted while the read runs lower the count after it, so a whole read is never below the SMALLER of the two; comparing
# with the larger one would call every busy table short. Whatever is added meanwhile only raises the export — and may hide rows the read lost, which is the blind spot of a count and
# why a table with a key is not judged by it. There is no percentage slack on purpose: comments only grow, and a cut that leaves the last 1% (a few hundred comments) is exactly the
# cut that goes unseen under the 1% the issues gate allows. A false "short" costs one retry, a miss costs the table.
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
# Supplemental tables (ga-l6v576): the five tables next to issues, each read in pages of SUPP_CHUNK_ROWS rows by KEY (WHERE key > last ORDER BY key LIMIT n; Dolt cuts ONE read that runs past
# ~40 s: hq.comments came out at 11,776 of 36,930 rows, exit 0). A paged read of a live table is judged by its KEYS, not by a count: two sweeps of the table's keys, taken before and after
# the rows, say which rows were there throughout, and the export must hold each of them (table_keys_verdict). The sweeps read SUPP_KEY_CHUNK_ROWS keys a page, a key being a fraction of a
# row. A table is tried at most SUPP_EXPORT_ATTEMPTS times before its previous version is kept; 2000 rows took 3-7 s on the live hq, a margin of 5x under the cut, and a retry cannot cure
# a cut that repeats, so the attempts stay few (the order's timeout is 840 s). A table with no usable key is read in ONE query and checked against its COUNT(*)
# (GC_JSONL_SUPP_SHORT_SLACK rows, read by table_export_verdict). SUPP_CUT_SIGNATURE is what Dolt writes to stderr when it cuts a read.
SUPP_TABLES="comments config dependencies labels metadata"
# These feed arithmetic and `sleep`: a plain whole number in decimal (08 is eight), the default for anything else; only a delay may be 0.
SUPP_CHUNK_ROWS=$(env_whole_number "${GC_JSONL_SUPP_CHUNK_ROWS:-2000}" 2000 1)
SUPP_KEY_CHUNK_ROWS=$(env_whole_number "${GC_JSONL_SUPP_KEY_CHUNK_ROWS:-$((SUPP_CHUNK_ROWS * 5))}" $((SUPP_CHUNK_ROWS * 5)) 1)
SUPP_EXPORT_ATTEMPTS=$(env_whole_number "${GC_JSONL_SUPP_EXPORT_ATTEMPTS:-2}" 2 1)
SUPP_EXPORT_RETRY_DELAY=$(env_whole_number "${GC_JSONL_SUPP_EXPORT_RETRY_DELAY:-3}" 3 0)
SUPP_MAX_PAGES=5000
SUPP_CUT_SIGNATURE='unexpected EOF|packets\.go|bad connection|invalid connection|i/o timeout'
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

# A run that dies before it finishes must show in the log, and its scratch must not wait 4 h (ga-iqsy9c7). Measured 27/10 with the disk at 4.5 GB: the order's 840 s timeout SIGKILLed three runs in a row
# (08:27, 08:48, 09:18) while hq.comments was being read. No trap runs on a SIGKILL and nothing had been written to .gc/logs/jsonl-export.log, so a dead run looked exactly like a run that never happened;
# each left ~830 MB of scratch ($table.jsonl.tmp.*: the rows file and the export) that only the 4 h age sweep took, and the order fires again every 15-30 min. Decided here, before any Dolt query, so
# a Dolt that is down (or a disk so full that Dolt is) still gets its dead runs' scratch swept — and the sweep also runs on a tick that skips for a low disk (below), which is exactly when ~830 MB hurts:
#   1. A run leaves a marker (pid + start) and removes it on any exit that runs the EXIT trap. A marker the next run finds with a DEAD pid is a run that never finished: one DIED line in the log and a count
#      of such runs in a row (state key consecutive_deaths, cleared by a run that finishes). A table that does not fit the timeout is a third outcome — not "ok", not "failed" — so it is counted and said (the deacon is told at the 3rd death in a row) instead of repeating unseen.
#   2. The log gets `start` and `end rc=N` around the run: a start with no end is a run still going or one that was killed, and the DIED line of the next run says which.
#   3. Scratch names carry the pid of the run that made them ($table.jsonl.tmp.p<pid>.XXXXXX): the next run deletes the scratch of a DEAD pid at once and leaves a live run's alone. The age sweep
#      (EXPORT_TMP_SWEEP_MIN) stays as the net for what carries no pid (older names) or a pid that something else has since reused.
EXPORT_TMP_DIR="${GC_JSONL_EXPORT_TMP_DIR:-$(dirname "$ARCHIVE_REPO")/.jsonl-export-tmp}"
# A scratch file older than this many minutes is swept whatever its name says. Keep it far above the order's timeout (jsonl-export.toml): no live run is that old, and the price of a long age is only the
# disk a killed run's file holds when its pid is unreadable or reused.
EXPORT_TMP_SWEEP_MIN=240
JEX_INFLIGHT="$(dirname "$STATE_FILE")/jsonl-export-inflight"
JEX_DEATH_ALERT_AT=3   # runs killed in a row before the deacon is told (once per streak)
JEX_SIGNAL=""

# jex_pid_alive <pid> — rc 0 when a process of ours has that pid. `kill -0` also fails for a pid that belongs to another user, but the exporter always runs as the same user, so a pid we cannot signal is not a run of ours.
jex_pid_alive() {
    kill -0 "$1" 2>/dev/null
}

# jex_epoch_iso <epoch|-> — the instant as ISO text; "?" for anything that is not an epoch (never a made-up date)
jex_epoch_iso() {
    case "${1:-}" in ''|*[!0-9]*) echo "?"; return 0 ;; esac
    jq -nr --argjson e "$1" '$e | todate' 2>/dev/null || echo "?"
}

# jex_sweep_scratch — deletes what a dead run left in $EXPORT_TMP_DIR: a file whose name carries the pid of a run that is gone, and any file older than EXPORT_TMP_SWEEP_MIN. Sets JEX_SWEPT_FILES / JEX_SWEPT_BYTES.
# vazio → no dir or no file: nothing to sweep; falhou/ilegível (a pid, an age or a size that cannot be read) → the file STAYS: a leftover costs disk, a guess deletes the file of a run that is still going
jex_sweep_scratch() {
    local f name pid why size
    JEX_SWEPT_FILES=0
    JEX_SWEPT_BYTES=0
    [ -d "$EXPORT_TMP_DIR" ] || return 0
    for f in "$EXPORT_TMP_DIR"/*.jsonl.tmp.*; do
        [ -f "$f" ] || continue
        name="${f##*/}"
        why=""
        if [[ "$name" =~ \.jsonl\.tmp\.p([0-9]+)\. ]]; then
            pid="${BASH_REMATCH[1]}"
            if [ "$pid" != "$$" ] && ! jex_pid_alive "$pid"; then
                why="run pid $pid is gone"
            fi
        fi
        if [ -z "$why" ] && [ -n "$(find "$f" -maxdepth 0 -mmin +"$EXPORT_TMP_SWEEP_MIN" 2>/dev/null)" ]; then
            why="older than $EXPORT_TMP_SWEEP_MIN min"
        fi
        [ -n "$why" ] || continue
        size=$(wc -c < "$f" 2>/dev/null | tr -d ' ') || size=0
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        if rm -f -- "$f"; then
            JEX_SWEPT_FILES=$((JEX_SWEPT_FILES + 1))
            JEX_SWEPT_BYTES=$((JEX_SWEPT_BYTES + size))
        else
            echo "jsonl-export: could not delete the scratch file $f ($why)" >&2
        fi
    done
    return 0
}

# jex_sweep_and_report — jex_sweep_scratch, and one line on stdout and one in the log when it took something. Called by a run that is about to export and by a tick that skips for a low disk.
jex_sweep_and_report() {
    jex_sweep_scratch
    if [ "$JEX_SWEPT_FILES" -gt 0 ]; then
        echo "jsonl-export: swept $JEX_SWEPT_FILES scratch file(s), $((JEX_SWEPT_BYTES / 1048576)) MB, left in $EXPORT_TMP_DIR by run(s) that did not finish"
        jex_log "swept $JEX_SWEPT_FILES scratch file(s), $((JEX_SWEPT_BYTES / 1048576)) MB, left by run(s) that did not finish"
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
    # A tick skipped for a low disk is where a dead run's scratch hurts most (ga-iqsy9c7): take it now, not at the next export an hour or 3 h away. vazio → nothing to sweep; falhou → the files stay (jex_sweep_scratch never fails the tick).
    # The marker and the streak are left to the run that exports: a skipped tick is not a run.
    jex_sweep_and_report
    echo "jsonl-export: skipped-low-disk (cadência estendida) — $JEX_WHY"
    jex_log "skipped-low-disk (cadência estendida) — $JEX_WHY"
    exit 0
fi
case "$JEX_WHY" in
    disk-ok|guard-off) ;;
    *) jex_log "run ($JEX_WHY) free=${JEX_FREE:-unreadable}MB" ;;
esac

# jex_run_begin — see the block comment above. Runs once, when this tick has decided to export.
jex_run_begin() {
    local prev_pid="" prev_at="" prev_iso deaths new_deaths state_now started
    # vazio (no marker) → the last run ended its own way, or this is the first: nothing to say; falhou/ilegível (a marker that is not "<pid> <epoch>", e.g. cut short by a full disk) → say so and
    # count nothing: a garbled marker proves no death. A marker whose pid still answers is not a death either.
    if [ -e "$JEX_INFLIGHT" ]; then
        if read -r prev_pid prev_at 2>/dev/null < "$JEX_INFLIGHT" && [[ "$prev_pid" =~ ^[0-9]+$ ]]; then
            prev_iso="$(jex_epoch_iso "$prev_at")"
            if [ "$prev_pid" != "$$" ] && jex_pid_alive "$prev_pid"; then
                jex_log "WARN the run pid=$prev_pid (start $prev_iso) is still going — a second export starts beside it"
            else
                # vazio/ilegível (the state or its count cannot be read) → "", the death is still said but no count is written: an unknown count never becomes 0 or 1
                deaths="$(read_state_json | jq -r '(.consecutive_deaths // 0) | if type == "number" then floor else empty end' 2>/dev/null)" || deaths=""
                case "$deaths" in ''|*[!0-9]*) deaths="" ;; esac
                if [ -n "$deaths" ]; then
                    new_deaths=$((deaths + 1))
                    state_now="$(read_state_json | jq -c --argjson n "$new_deaths" '.consecutive_deaths = $n' 2>/dev/null)" || state_now=""
                    if [ -z "$state_now" ] || ! write_state_json "$state_now"; then
                        echo "jsonl-export: could not record the dead run in the state (consecutive_deaths)" >&2
                    fi
                    jex_log "DIED the run of $prev_iso (pid $prev_pid) never finished — killed, most likely by the order's timeout; $new_deaths in a row"
                    if [ "$new_deaths" -eq "$JEX_DEATH_ALERT_AT" ]; then
                        gc session nudge deacon/ "JSONL_EXPORT: $new_deaths runs in a row were killed before they finished (the order's timeout?) — see .gc/logs/jsonl-export.log" 2>/dev/null || true
                    fi
                else
                    jex_log "DIED the run of $prev_iso (pid $prev_pid) never finished — killed, most likely by the order's timeout; the count in the state is unreadable"
                fi
            fi
        else
            jex_log "WARN the marker $JEX_INFLIGHT is unreadable — no death counted for the last run"
        fi
    fi

    jex_sweep_and_report

    # falhou (the marker cannot be written) → warn: this run's death would not be named by the next one (its start with no end in the log still shows it); the export goes on, the marker is never a precondition
    started="${JEX_NOW:-}"
    case "$started" in ''|*[!0-9]*) started="-" ;; esac
    if ! { printf '%s %s\n' "$$" "$started" > "$JEX_INFLIGHT.tmp.$$" && mv -f "$JEX_INFLIGHT.tmp.$$" "$JEX_INFLIGHT"; } 2>/dev/null; then
        rm -f "$JEX_INFLIGHT.tmp.$$" 2>/dev/null || true
        echo "jsonl-export: could not write the marker $JEX_INFLIGHT; a death of this run will not be named" >&2
    fi
    jex_log "start pid=$$"
}

# jex_run_end — the EXIT trap: closes what jex_run_begin opened. Nothing in it may change the exit status of the run, so it never fails and never exits. A SIGTERM/SIGINT/SIGHUP is an end too, but
# not a finished run: bash leaves $? at 0 in the trap for those, so the signal handlers below record which one it was, and the streak of deaths is neither added to nor cleared by it.
jex_run_end() {
    local rc=$? marker_pid="" streak how
    set +e
    how="rc=$rc"
    [ -z "$JEX_SIGNAL" ] || { rc=1; how="signal $JEX_SIGNAL"; }
    jex_log "end $how after ${SECONDS}s"
    # vazio/ilegível (no marker, or not ours) → left alone: it belongs to another run, and removing it would hide that run's death
    if [ -e "$JEX_INFLIGHT" ]; then
        read -r marker_pid _ 2>/dev/null < "$JEX_INFLIGHT"
        [ "$marker_pid" = "$$" ] && rm -f "$JEX_INFLIGHT"
    fi
    # a run that got to its own end clears the streak; falhou/ilegível (the state cannot be read or rewritten) → the streak stays, never a guess
    if [ -z "$JEX_SIGNAL" ]; then
        streak="$(read_state_json | jq -r '.consecutive_deaths // 0' 2>/dev/null)"
        case "$streak" in ''|0|*[!0-9]*) ;; *) write_state_json "$(read_state_json | jq -c 'del(.consecutive_deaths)' 2>/dev/null)" 2>/dev/null ;; esac
    fi
    return 0
}

jex_run_begin
trap 'JEX_SIGNAL=TERM; exit 143' TERM
trap 'JEX_SIGNAL=INT; exit 130' INT
trap 'JEX_SIGNAL=HUP; exit 129' HUP
trap jex_run_end EXIT

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
# EXPORT_TMP_DIR is defined, and swept of dead runs' files, where the run begins (jex_run_begin, ga-iqsy9c7) — before any Dolt query, not here.
# falhou → exit 1 before anything is exported: the archive keeps its last snapshot (never a fallback to a path inside the archive)
if ! mkdir -p "$EXPORT_TMP_DIR"; then
    echo "jsonl-export: cannot create the scratch dir $EXPORT_TMP_DIR — nothing exported this run" >&2
    exit 1
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

# The primary key of <db>.<table> as its column names, space-separated ("id", "issue_id label"); prints an empty line when the table has no key (ga-l6v576).
# vazio (no key) → the caller reads the table in ONE query, which the count check still gates; falhou/ilegível → return 1, and the caller does the same and says so.
table_key_columns() {
    local db="$1" table="$2" output col list=""

    if ! output=$(dolt_sql -r csv -q "SELECT COLUMN_NAME FROM information_schema.KEY_COLUMN_USAGE WHERE TABLE_SCHEMA = '$db' AND TABLE_NAME = '$table' AND CONSTRAINT_NAME = 'PRIMARY' ORDER BY ORDINAL_POSITION" 2>/dev/null); then
        return 1
    fi
    while IFS= read -r col; do
        col=$(printf '%s' "$col" | tr -d '\r')
        [ -n "$col" ] || continue
        # A name that is not plain is never put into SQL.
        case "$col" in *[!A-Za-z0-9_]*) return 1 ;; esac
        list="${list:+$list }$col"
    done <<EOF2
$(printf '%s\n' "$output" | tail -n +2)
EOF2
    printf '%s\n' "$list"
}

# `a`, `b` — the key columns "a b" as SQL identifiers (they are plain names, see table_key_columns). `key` is a reserved word, hence the backticks.
sql_column_list() {
    local cols="$1" col list=""

    for col in $cols; do
        list="${list:+$list, }\`$col\`"
    done
    printf '%s\n' "$list"
}

SUPP_RAW_ROWS=""

# Reads <db>.<table> by KEY (ga-l6v576): pages of <chunk> rows, `SELECT <cols|*> FROM t [WHERE (<key>) > (<last key of the page before>)] ORDER BY <key> LIMIT <chunk>`. <kind> is
# "rows" (whole rows into the document <out>, SUPP_RAW_ROWS = their count) or "keys" (the key columns only, into <out> itself as one JSON array per line). For rows the keys of what was
# read are in <out>.keys. Scratch files are <out>.p<N> (pages), <out>.pe (one page's stderr), <out>.err (all of Dolt's stderr) and <out>.rows; the caller removes <out>.*.
# Paging by key is not a snapshot either, but it fails in ways that can be told: a row inserted or deleted behind the cursor moves nothing, so no row is served twice or stepped over.
# One read that runs past ~40 s is cut by Dolt — a well-formed document, exit 0, SUPP_CUT_SIGNATURE on stderr — so a page that comes back with rows and that line is kept and the next page
# resumes from its last key. The paging stops on an EMPTY page only: a short page is not the end, it may be a cut. An empty page that carries the cut's line is the cut that left nothing:
# a failed read. A single page is kept exactly as Dolt wrote it; several are joined in the same shape. Checked on the way: every page is a JSON document, the cursor moves on, and no key
# comes twice (a server that repeats rows has not given a snapshot, whatever the counts say).
# Return 0 → read; return 1 → the read failed (Dolt's exit code, an unreadable document, a cursor that cannot be written or does not move, a repeated key, an empty page after a cut), the
# reason and Dolt's stderr are in the log, <out> is junk.
read_keyed_pages() {
    local db="$1" table="$2" cols="$3" kind="$4" chunk="$5" out="$6"
    local what keys_file collist sel where query rows literal="" prev_literal="" n=0 kept=0 total=0 i dups

    collist=$(sql_column_list "$cols")
    if [ "$kind" = rows ]; then
        what="$db.$table"
        keys_file="$out.keys"
        sel='*'
        SUPP_RAW_ROWS=""
    else
        what="the keys of $db.$table"
        keys_file="$out"
        sel="$collist"
    fi
    : > "$out.err"
    : > "$keys_file" || return 1
    while :; do
        n=$((n + 1))
        where=""
        [ -z "$literal" ] || where=" WHERE ($collist) > ($literal)"
        query="SELECT $sel FROM \`$db\`.\`$table\`$where ORDER BY $collist LIMIT $chunk"
        if ! dolt_sql -r json -q "$query" > "$out.p$n" 2> "$out.pe"; then
            # third-state-waiver: o .err só junta o stderr do dolt para o texto do log; a falha já foi decidida pelo rc acima, e a linha de corte é lida do .pe, não daqui
            cat "$out.pe" >> "$out.err" 2>/dev/null || true
            # third-state-waiver: a falha já foi decidida pelo rc do dolt acima; este tail só monta o texto do log (vazio se o .err sumiu)
            echo "jsonl-export: reading $what failed (page $n; dolt exited non-zero): $(tail -c 300 "$out.err" | tr '\n' ' ')" >&2
            return 1
        fi
        # third-state-waiver: o .err só junta o stderr do dolt para o texto do log; o veredito da página sai do jq e da linha de corte lida do .pe, não daqui
        cat "$out.pe" >> "$out.err" 2>/dev/null || true
        # vazio (a 0-byte page) → an error, not a table with no rows: Dolt prints {} for that
        if ! rows=$(jq -s -r 'if length == 0 then error("empty page") else ((.[0].rows // []) | length) end' "$out.p$n" 2>/dev/null); then
            # third-state-waiver: a falha já foi decidida pelo status do jq acima; este tail só monta o texto do log (vazio se o .err sumiu)
            echo "jsonl-export: reading $what returned an unreadable document (page $n): $(tail -c 300 "$out.err" | tr '\n' ' ')" >&2
            return 1
        fi
        if [ "$rows" -eq 0 ]; then
            # vazio → the end of the table; a grep that cannot run reads as "no cut line", and the key check after the read still sees what the page should have held
            if grep -Eq "$SUPP_CUT_SIGNATURE" "$out.pe" 2>/dev/null; then
                # third-state-waiver: a falha já foi decidida pelo grep acima; este tail só monta o texto do log (vazio se o .err sumiu)
                echo "jsonl-export: page $n of $what came back empty after the store cut the read: $(tail -c 300 "$out.err" | tr '\n' ' ')" >&2
                return 1
            fi
            [ "$n" -eq 1 ] || rm -f "$out.p$n"
            break
        fi
        kept=$((kept + 1))
        total=$((total + rows))
        # falhou → the page's keys, or the last row's cursor, cannot be made: the read stops (a key that cannot be quoted is never put into SQL)
        if ! jq -c --arg cols "$cols" '($cols | split(" ")) as $cs | .rows[]? | . as $r | [$cs[] as $c | $r[$c]]' "$out.p$n" >> "$keys_file" 2>/dev/null; then
            echo "jsonl-export: reading $what: the keys of page $n cannot be read" >&2
            return 1
        fi
        if ! literal=$(jq -c '.rows[-1]' "$out.p$n" 2>/dev/null | key_tuple_literal "$cols") || [ -z "$literal" ]; then
            echo "jsonl-export: reading $what: the key of the last row of page $n cannot be written into the next query" >&2
            return 1
        fi
        if [ "$literal" = "$prev_literal" ]; then
            echo "jsonl-export: page $n of $what did not move past the cursor ($literal); the server ignores it or repeats the page" >&2
            return 1
        fi
        prev_literal="$literal"
        [ "$kind" = rows ] || rm -f "$out.p$n"
        if [ "$n" -ge "$SUPP_MAX_PAGES" ]; then
            echo "jsonl-export: reading $what needs more than $SUPP_MAX_PAGES pages of $chunk rows" >&2
            return 1
        fi
    done

    # falhou (awk) → no answer: not "no key twice"
    if ! dups=$(awk '($0 in seen) { d++ } { seen[$0] = 1 } END { print d + 0 }' "$keys_file" 2>/dev/null); then
        echo "jsonl-export: reading $what: the keys read cannot be checked for repeats" >&2
        return 1
    fi
    case "$dups" in
        ''|*[!0-9]*)
            echo "jsonl-export: reading $what: the keys read cannot be checked for repeats" >&2
            return 1
            ;;
        0) ;;
        *)
            echo "jsonl-export: reading $what returned $dups keys more than once ($n pages): the server repeated rows, so the read is not a snapshot" >&2
            return 1
            ;;
    esac
    [ "$kind" = rows ] || return 0

    if [ "$kept" -le 1 ]; then
        mv -f "$out.p1" "$out" || return 1
    else
        : > "$out.rows"
        i=1
        while [ "$i" -le "$kept" ]; do
            jq -c '.rows[]?' "$out.p$i" >> "$out.rows" || return 1
            rm -f "$out.p$i"   # joined: the page is no longer needed, and the table's pages are a copy of the table
            i=$((i + 1))
        done
        # Dolt's own shape: {"rows": [row,row]}. The rows are one JSON line each, so the only newline paste leaves is its last.
        { printf '{"rows": ['; paste -sd, - < "$out.rows" | tr -d '\n'; printf ']}\n'; } > "$out" || return 1
    fi
    SUPP_RAW_ROWS="$total"
    return 0
}

# Reads a table that has no key to page by, in ONE query, into the file <base> (ga-l6v576), and sets SUPP_RAW_ROWS to its row count. Scratch: <base>.err (Dolt's stderr).
# Return 0 → read; return 1 → the read failed (Dolt's exit code, or not a JSON document), the reason is in the log, <base> is junk.
read_table_once() {
    local db="$1" table="$2" base="$3" rows

    : > "$base.err"
    SUPP_RAW_ROWS=""
    if ! dolt_sql -r json -q "SELECT * FROM \`$db\`.\`$table\`" > "$base" 2>>"$base.err"; then
        # third-state-waiver: a falha já foi decidida pelo rc do dolt acima; este tail só monta o texto do log (vazio se o .err sumiu)
        echo "jsonl-export: reading $db.$table failed (dolt exited non-zero): $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
        return 1
    fi
    # vazio (a 0-byte document) → an error, not a table with no rows: Dolt prints {} for that
    if ! rows=$(jq -s -r 'if length == 0 then error("empty document") else ((.[0].rows // []) | length) end' "$base" 2>/dev/null); then
        # third-state-waiver: a falha já foi decidida pelo status do jq acima; este tail só monta o texto do log (vazio se o .err sumiu)
        echo "jsonl-export: reading $db.$table returned an unreadable document: $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
        return 1
    fi
    SUPP_RAW_ROWS="$rows"
    return 0
}

# Puts the previous version of <db>/<table>.jsonl back in the working tree; a table with no previous version ends up with no file. Return 1 when git cannot restore it, or cannot
# say whether HEAD has one: the DB is staged as a whole, so deleting the file on a guess would commit the table's removal from the snapshot.
keep_previous_table() {
    local db="$1" table="$2" path="$1/$2.jsonl" listed refs

    # HEAD not born: the archive's first run, no ref at all, so there is no previous version to keep. A HEAD that does not resolve while refs exist is a broken repo, not a first run.
    if ! git -C "$ARCHIVE_REPO" rev-parse --verify --quiet HEAD >/dev/null 2>&1; then
        # vazio → no refs, a first run; falhou/com refs → git cannot say, the tree is left alone and the caller discards the DB
        if refs=$(git -C "$ARCHIVE_REPO" for-each-ref --count=1 2>/dev/null) && [ -z "$refs" ]; then
            rm -f "$ARCHIVE_REPO/$path"
            return 0
        fi
        return 1
    fi
    # vazio → HEAD has no such file (a table new to this DB); falhou → git cannot say, the tree is left alone and the caller discards the DB
    if ! listed=$(git -C "$ARCHIVE_REPO" ls-tree --name-only HEAD -- "$path" 2>/dev/null); then
        return 1
    fi
    if [ -n "$listed" ]; then
        git -C "$ARCHIVE_REPO" restore --source=HEAD --worktree -- "$path" >/dev/null 2>&1
    else
        rm -f "$ARCHIVE_REPO/$path"
    fi
}

# One attempt at a table that has a key (ga-l6v576): its keys, its rows, its keys again, and the verdict of table_keys_verdict. Sets SUPP_VERDICT (complete | short | unknown | failed) and
# SUPP_DETAIL (what the log says, without the "jsonl-export: " prefix). Return 1 only when the ROWS could not be read (SUPP_VERDICT=failed). A key sweep that cannot be read is not an
# empty one: its file is removed, table_keys_verdict has nothing to compare with and answers "unknown".
SUPP_VERDICT=""
SUPP_DETAIL=""
supp_attempt_keyed() {
    local db="$1" table="$2" cols="$3" base="$4" verdict

    SUPP_VERDICT=failed
    SUPP_DETAIL=""
    # falhou → no file for the sweep (never an empty one), so the verdict below is "unknown"
    read_keyed_pages "$db" "$table" "$cols" keys "$SUPP_KEY_CHUNK_ROWS" "$base.kb" || rm -f "$base.kb"
    read_keyed_pages "$db" "$table" "$cols" rows "$SUPP_CHUNK_ROWS" "$base" || return 1
    read_keyed_pages "$db" "$table" "$cols" keys "$SUPP_KEY_CHUNK_ROWS" "$base.ka" || rm -f "$base.ka"
    verdict=$(table_keys_verdict "$base.kb" "$base.ka" "$base.keys")
    case "$verdict" in
        complete)
            SUPP_VERDICT=complete
            ;;
        short\ *)
            SUPP_VERDICT=short
            SUPP_DETAIL="export curto de $db.$table: $SUPP_RAW_ROWS linhas lidas, ${verdict#short } chaves que estavam na tabela do começo ao fim da leitura fora do export"
            ;;
        *)
            SUPP_VERDICT=unknown
            SUPP_DETAIL="key sweep unavailable for $db.$table; export NOT verified against source (raw export: $SUPP_RAW_ROWS rows)"
            ;;
    esac
    return 0
}

# One attempt at a table that has NO key to page by: one query, bracketed by two COUNT(*)s, and the verdict of table_export_verdict. Same contract as supp_attempt_keyed.
supp_attempt_counted() {
    local db="$1" table="$2" base="$3" before after

    SUPP_VERDICT=failed
    SUPP_DETAIL=""
    # vazio → unreadable ("don't know", never 0): table_export_verdict reads it as the third state
    before=$(read_source_table_count "$db" "$table" || true)
    read_table_once "$db" "$table" "$base" || return 1
    after=$(read_source_table_count "$db" "$table" || true)
    SUPP_VERDICT=$(table_export_verdict "$SUPP_RAW_ROWS" "$before" "$after")
    case "$SUPP_VERDICT" in
        complete)
            ;;
        short)
            SUPP_DETAIL="export curto de $db.$table: $SUPP_RAW_ROWS vs fonte ${before:-?}/${after:-?}"
            ;;
        *)
            SUPP_VERDICT=unknown
            SUPP_DETAIL="source count unavailable for $db.$table; export NOT verified against source (raw export: $SUPP_RAW_ROWS rows)"
            ;;
    esac
    return 0
}

# Exports <db>.<table> into $DB_DIR/<table>.jsonl (ga-l6v576). A table with a key is read by key and judged by its keys (supp_attempt_keyed); one without is read in one query and judged
# by its COUNT(*) (supp_attempt_counted). The export is built in the scratch dir and moves into the archive only when it passes. Returns:
#   0  whole: every row that was in the table throughout the read is in the file (a keyless table: at least as many rows as the source has); it is now the file;
#   3  nobody can say (a key sweep or the count could not be read): the export is the file, flagged unverified — not discarded, a store whose sweep is down must not freeze its archive;
#   1  not read whole in SUPP_EXPORT_ATTEMPTS tries (short, or the read failed): the file is NOT written and the previous version stays;
#   2  the previous version could not be put back: the caller discards the DB.
export_supplemental_table() {
    local db="$1" table="$2"
    local dest="$DB_DIR/$table.jsonl"
    local base cols attempt=1 rc

    # falhou (mktemp) → the table is not exported this run and its previous version stays
    if ! base=$(mktemp "$EXPORT_TMP_DIR/$table.jsonl.tmp.p$$.XXXXXX"); then
        echo "jsonl-export: cannot create the scratch file for $db.$table in $EXPORT_TMP_DIR" >&2
        keep_previous_table "$db" "$table" || return 2
        return 1
    fi
    # vazio (no key) / falhou (unreadable) → empty: one query, and the count check below still gates it
    if ! cols=$(table_key_columns "$db" "$table"); then
        echo "jsonl-export: primary key of $db.$table unreadable; reading the table in one query" >&2
        cols=""
    fi
    while :; do
        if [ -n "$cols" ]; then
            supp_attempt_keyed "$db" "$table" "$cols" "$base" || true
        else
            supp_attempt_counted "$db" "$table" "$base" || true
        fi
        case "$SUPP_VERDICT" in
            complete|unknown)
                if [ "$SUPP_VERDICT" = unknown ]; then
                    echo "jsonl-export: $SUPP_DETAIL" >&2
                fi
                rc=0
                [ "$SUPP_VERDICT" = complete ] || rc=3
                if ! mv -f "$base" "$dest"; then
                    rm -f "$base" "$base".*
                    return 2
                fi
                rm -f "$base".*
                return "$rc"
                ;;
            short)
                # third-state-waiver: o export curto já foi decidido pelo veredito acima; este tail só monta o texto do log (vazio se o .err sumiu)
                echo "jsonl-export: $SUPP_DETAIL (tentativa $attempt/$SUPP_EXPORT_ATTEMPTS): $(tail -c 300 "$base.err" | tr '\n' ' ')" >&2
                ;;
        esac
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
    if ! ISSUE_EXPORT_TMP=$(mktemp "$EXPORT_TMP_DIR/issues.jsonl.tmp.p$$.XXXXXX"); then
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

    # Export supplemental tables (ga-l6v576). A table with a primary key is read in pages BY KEY and judged by keys: every key that was in the table before the read and still is after it
    # must be in the file. A read that Dolt cut short is still a well-formed document with exit 0 (29 of 37 hq snapshots had comments.jsonl at a multiple of 128 rows), and a row count
    # cannot tell a lost row from one the table gained meanwhile. A table with no key is read in one query and judged by its COUNT(*), the way issues are above. Per table:
    #   whole       -> it is the file;
    #   short/failed-> not written, the previous version stays, the DB is reported as failed with the table named (issues still commit);
    #   unknown     -> the source (its keys, or its count) is unreadable: kept and flagged unverified, like issues;
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
    # The scrubbed copy is scratch too (ga-iqsy9c7): in $EXPORT_TMP_DIR, named with this run's pid, so a run killed during the ~80 s scrub of hq/issues.jsonl leaves a file the next run sweeps — not a 70 MB file in $TMPDIR that nobody does. Same filesystem as the archive: the final mv is a rename.
    # falhou (mktemp) → this DB is not exported this run and its previous snapshot is restored, like step 1
    if ! TMPFILE=$(mktemp "$EXPORT_TMP_DIR/issues.jsonl.tmp.p$$.XXXXXX"); then
        echo "jsonl-export: cannot create the scratch file for the scrub of $DB in $EXPORT_TMP_DIR" >&2
        discard_failed_db_outputs "$DB"
        FAILED_DB_COUNT=$((FAILED_DB_COUNT + 1))
        FAILED_DBS="${FAILED_DBS}$DB
"
        continue
    fi
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

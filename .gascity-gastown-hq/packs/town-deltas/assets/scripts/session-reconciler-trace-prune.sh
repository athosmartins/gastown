#!/usr/bin/env bash
# session-reconciler-trace-prune (ga-op9f7) — calendar-day retention for
# .gc/runtime/session-reconciler-trace/segments/YYYY/MM/DD.
#
# MEASURED 2026-09-10: ~270MB/day landing in segments/, 1010MB across 5 days,
# on a Mac mini sitting at 96-98% disk (disk-floor CRITICAL repeatedly that
# day, Dolt GC refused for lack of headroom — ga-3euoj). No script or order
# in this city referenced the directory; it only shrank because the Mayor
# manually deleted three days' worth (623MB) by hand.
#
# The engine writer is NOT actually unbounded: cmd/gc/session_reconciler_
# trace_store.go (pruneOldSegments/maybePruneOldSegments, confirmed present
# via `strings` in the live gc-1.1.1-engwin0906b binary) already caps total
# segment bytes at 1GiB and max age at 7 days, checked on a 5min cadence from
# inside AppendBatch. That cap is a real safety net, not dead code — but (a)
# 1GiB is still a lot to dedicate to a diagnostic trace on a disk with only a
# few GB free, and (b) it deletes individual .jsonl files, never the
# now-empty YYYY/MM/DD (and MM/YYYY) directories left behind — this city's
# tree still had empty day-dirs going back to June 2026. This order enforces
# a tighter, city-tunable calendar-day policy on top of the engine's own
# cap, and also sweeps the empty skeleton dirs. No engine rebuild needed or
# attempted for this bead — pure external filesystem housekeeping.
#
# Touches ONLY segments/YYYY/MM/DD directories older than the retention
# window. Never touches the trace root's head.json, arms.json, quarantine/,
# or trace.lock — the script never lists or descends into anything except
# segments/, so those are preserved by construction, not by a carve-out.
#
# Idempotent: safe to run with nothing to prune (exits 0, logs and does
# nothing) and safe to re-run over a partially-pruned tree.
#
# Runs as an exec order (no LLM, no agent, no wisp, no bd calls).
#
# TEST: bash session-reconciler-trace-prune.selftest.sh
set -uo pipefail  # NOT -e: one bad/unreadable day-dir must not abort the sweep

CITY="${GC_CITY_PATH:-${GC_CITY:-.}}"
TRACE_ROOT="${SESSION_RECONCILER_TRACE_ROOT:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/session-reconciler-trace}"
SEGMENTS_DIR="$TRACE_ROOT/segments"
RETENTION_DAYS="${SESSION_RECONCILER_TRACE_RETENTION_DAYS:-3}"
LOG="${SESSION_RECONCILER_TRACE_PRUNE_LOG:-$CITY/.gc/logs/session-reconciler-trace-prune.log}"
DU_BIN="${DU_BIN:-du}"

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
log() { echo "$(date -u '+%Y-%m-%dT%H:%M:%SZ') [session-reconciler-trace-prune] $*" >> "$LOG" 2>/dev/null || true; }

# Idempotent no-op if the trace store doesn't exist yet on this city (e.g.
# never written to, or wisp/city not using this feature).
if [ ! -d "$SEGMENTS_DIR" ]; then
    log "no segments dir at $SEGMENTS_DIR — nothing to do"
    exit 0
fi

# Canonicalize once so every candidate's REAL path is checked against it
# before deletion — defends against a symlink under segments/ pointing
# outside the trace root turning a day-dir prune into something else.
SEGMENTS_REAL=$(cd "$SEGMENTS_DIR" 2>/dev/null && pwd -P) || { log "ERROR: cannot resolve $SEGMENTS_DIR"; exit 1; }

TODAY=$(date -u +%Y-%m-%d)
TODAY_EPOCH=$(TZ=UTC date -j -f "%Y-%m-%d" "$TODAY" +%s 2>/dev/null) || { log "ERROR: cannot compute today's epoch"; exit 1; }

FREED_BYTES=0
REMOVED_DIRS=0
SKIPPED=0

# segments/YYYY/MM/DD — exactly 3 levels, mirroring traceDayDir() in
# session_reconciler_trace_store.go (the only shape the engine ever writes).
while IFS= read -r -d '' daydir; do
    [ -d "$daydir" ] || continue

    yyyy=$(basename "$(dirname "$(dirname "$daydir")")")
    mm=$(basename "$(dirname "$daydir")")
    dd=$(basename "$daydir")
    datestr="$yyyy-$mm-$dd"

    # Defensive: act only on a real YYYY-MM-DD date whose resolved path is
    # still inside $SEGMENTS_REAL. Anything else is left alone and counted
    # as skipped — an unrecognized shape here must never become a guessed
    # rm -rf.
    case "$yyyy" in
        [0-9][0-9][0-9][0-9]) ;;
        *) log "SKIP (not YYYY): $daydir"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac
    case "$mm" in
        [0-9][0-9]) ;;
        *) log "SKIP (not MM): $daydir"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac
    case "$dd" in
        [0-9][0-9]) ;;
        *) log "SKIP (not DD): $daydir"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac

    day_epoch=$(TZ=UTC date -j -f "%Y-%m-%d" "$datestr" +%s 2>/dev/null) || {
        log "SKIP (invalid date $datestr): $daydir"; SKIPPED=$((SKIPPED+1)); continue
    }

    # Never touch the current day, full stop — even if the arithmetic below
    # would otherwise agree, and even under clock skew.
    if [ "$datestr" = "$TODAY" ]; then
        continue
    fi

    age_days=$(( (TODAY_EPOCH - day_epoch) / 86400 ))
    if [ "$age_days" -le "$RETENTION_DAYS" ]; then
        continue
    fi

    real_daydir=$(cd "$daydir" 2>/dev/null && pwd -P) || {
        log "SKIP (cannot resolve): $daydir"; SKIPPED=$((SKIPPED+1)); continue
    }
    case "$real_daydir" in
        "$SEGMENTS_REAL"/*/*/*) ;;
        *) log "SKIP (escapes segments root): $daydir -> $real_daydir"; SKIPPED=$((SKIPPED+1)); continue ;;
    esac

    # "du failed" and "du confirmed 0 bytes" are different facts — only the
    # second may feed the freed-space total; the first is reported as
    # unknown rather than silently costed as zero.
    size_kb=$("$DU_BIN" -sk "$real_daydir" 2>/dev/null | awk '{print $1}')
    size_known=1
    case "$size_kb" in ''|*[!0-9]*) size_known=0 ;; esac

    if rm -rf "$real_daydir"; then
        REMOVED_DIRS=$((REMOVED_DIRS + 1))
        if [ "$size_known" -eq 1 ]; then
            FREED_BYTES=$((FREED_BYTES + size_kb * 1024))
            log "removed $datestr ($daydir), ${size_kb}KB, age=${age_days}d"
        else
            log "removed $datestr ($daydir), size=unknown (du failed), age=${age_days}d"
        fi
    else
        log "ERROR: failed to remove $real_daydir"
    fi
done < <(find "$SEGMENTS_DIR" -mindepth 3 -maxdepth 3 -type d -print0)

# Sweep now-empty MM then YYYY skeletons. rmdir only succeeds on an empty
# directory, so a month/year that still holds a live day is left untouched.
# This also cleans up skeletons left by the engine's own per-file pruner
# (which deletes .jsonl files but never their parent dirs) from before this
# order existed, not just ones this run produced.
find "$SEGMENTS_DIR" -mindepth 2 -maxdepth 2 -type d -empty -exec rmdir {} \; 2>/dev/null || true
find "$SEGMENTS_DIR" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} \; 2>/dev/null || true

FREED_MB=$(( FREED_BYTES / 1048576 ))
log "done: removed_dirs=$REMOVED_DIRS freed_mb=$FREED_MB skipped=$SKIPPED retention_days=$RETENTION_DAYS"
if [ "$REMOVED_DIRS" -gt 0 ] || [ "$SKIPPED" -gt 0 ]; then
    echo "session-reconciler-trace-prune: removed_dirs=$REMOVED_DIRS freed_mb=$FREED_MB skipped=$SKIPPED retention_days=$RETENTION_DAYS"
fi
exit 0

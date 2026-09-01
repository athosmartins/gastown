#!/usr/bin/env bash
# engine-refusal-strip-watchdog.sh — detection-only safety net for the gap
# ga-fn35s root-caused (ga-pxtib).
#
# ── THE GAP ──────────────────────────────────────────────────────────────────
# An ad hoc, session-driven "absorbed patch" reconciliation strips
# needs:engine-window / pool:refused:engine-rebuild-required / framework:engine /
# pilot:refused-reason:engine-rebuild-required from a bead once its patch is
# confirmed byte-identical to the live SOURCE tree (following an
# engine-window-run.sh build/swap) — WITHOUT closing the bead or blocking
# dispatch. "already-applied" (source-tree byte match) != "vivo no binário"
# (running in the deployed binary) — this repo's own doctrine already says so
# (docs/runbooks/janela-20260826-almoco.md). No committed script performs the
# strip (engine-window-run.sh has zero bd interaction, confirmed by full read
# during ga-fn35s) — it is manual bookkeeping, and it has recurred >=3x in one
# day (2026-08-29), independently hit by two different dogs, and cost >=6
# manual correction passes plus one wasted ~84min Pilot builder-dispatch cycle
# (ga-65rml0) before this watchdog existed.
#
# ── WHAT THIS DOES (each StartInterval pass) ────────────────────────────────
# 1. Query dolt_log ($DOLT_DB) for commits whose message matches
#    "bd: label removed '...'" AND names >=1 of the 4 engine-refusal labels,
#    within LOOKBACK_HOURS.
# 2. Skip any commit hash already in the processed-state file (dedup).
# 3. For each new commit, resolve affected issue(s) via
#    dolt_diff_labels WHERE to_commit = '<hash>' (indexed, fast per-commit
#    lookup — confirmed live during ga-fn35s). The lookback window above
#    scopes dolt_log only; dolt_diff_labels is deliberately never scoped by
#    an open date range — see
#    [[dolt-diff-table-audit-trail-for-mutation-attribution]].
# 4. For each affected bead: if it is CLOSED, or already carries
#    pilot:no-auto-dispatch / no-auto-dispatch / any of the 4 refusal labels
#    again, or has a comment postdating the strip commit -> already safe, no
#    action (a bead legitimately un-scoped from engine-window post-review
#    should NOT be permanently vetoed). Otherwise (open OR in_progress,
#    unprotected, silent since the strip) -> FLAG: add pilot:no-auto-dispatch
#    (hardened, already respected by pilot-dispatcher.sh with no engine window
#    required), comment citing the strip commit hash + timestamp.
# 5. Mark the commit hash processed once every affected issue for it was
#    evaluated successfully. A transient bd/dolt read failure leaves the
#    commit UNprocessed for retry next pass — never silently drop a real
#    event because a query hiccuped (error and "nothing to do" must not
#    collapse to the same outcome).
# 6. If anything was flagged this pass, ONE batched `gc mail send mayor` names
#    every flagged bead (never `gc session nudge mayor` — see below).
#
# ── WHY DETECTION-ONLY, NEVER AUTO-CLOSE ────────────────────────────────────
# Source-tree byte-identity is not proof the fix is live in the deployed
# binary (engine rebuild+swap is a separate, Mayor-coordinated step this
# watchdog never touches). Auto-closing here would just relocate the false
# confidence from the label layer to the terminal-status layer. pilot:
# no-auto-dispatch is a manually-cleared VETO, not a close — worst-case
# false-positive cost is one avoidable human/dog look, not lost work.
#
# ── WHY MAIL, NOT `gc session nudge mayor` (deviates from this bead's own
#    prose, which suggested nudge) ───────────────────────────────────────────
# `gc session nudge mayor` HANGS (exit 124) whenever the Mayor's tmux session
# is ATTACHED — which is most of the time. This is not speculation: it is the
# exact, live-verified failure city-health-sentinel.sh's _do_nudge() already
# hit and fixed under ga-eldeu (2026-07-21: nudge oracle-wa/unattached=exit0,
# nudge mayor/attached=exit124), with its own selftest permanently regression-
# guarding against reintroducing a live `session nudge mayor` call. Since the
# whole point of this watchdog is "don't rely on a human noticing", silently
# dropping its own alert to a hung nudge would defeat it. `gc mail send` is
# durable and does not depend on tmux attachment state — mirroring
# city-health-sentinel's exact fix, batched to one mail per pass (not one per
# bead) so a label-strip burst (observed live: 23 commits in 23.185s on
# 2026-08-29, 15:06:39.942-15:07:03.127 UTC) can't produce a mail storm.
# Still timeout-wrapped regardless (general Dolt-health defense, unrelated to
# the attachment-specific bug).
#
# ── SECOND DETECTION PATH: THE WATCHDOG'S OWN VETO GETS REMOVED (ga-6u8e4) ──
# The primary path above catches the 4 engine-refusal labels being stripped
# directly. It does NOT catch a subtler recurrence of the exact same ad hoc
# "session reconciliation" pattern: once THIS watchdog has already protected
# a bead by adding pilot:no-auto-dispatch, a later ad hoc pass can remove
# THAT veto too, without ever re-verifying the underlying engine-rebuild
# constraint. Observed live 2026-08-29 through 2026-09-01 on ga-165vq: actor
# gastown.mayor stripped needs:engine-window + pool:refused:engine-rebuild-
# required directly (08-29, 08-30 — the primary path's exact target, and this
# watchdog correctly re-protected it on 08-30 13:35:39 UTC), then on 09-01
# 15:50:19 UTC removed pilot:no-auto-dispatch ITSELF (the watchdog's own
# prior protection) and re-armed ctx:ready+exec:auto five seconds later — a
# third exposure of the same bead, invisible to the primary path because no
# commit in that window touched any of the original 4 labels.
#
# pilot:no-auto-dispatch is also the general-purpose park label for dozens of
# unrelated reasons (on-device holds, human decisions, etc — see CLAUDE.md
# town deltas), so treating every removal of it as suspect would trade one
# false-positive class for a worse one. Instead: a pilot:no-auto-dispatch
# removal is only in scope here if the bead ALSO carries a comment authored
# by THIS watchdog (the literal "engine-refusal-strip-watchdog (ga-pxtib)"
# prefix — WATCHDOG_MARKER below) that PREDATES the removal commit — i.e.
# only beads this watchdog itself previously protected for an engine-refusal
# reason are ever candidates. Every other check (closed?, already
# re-protected?, a comment postdating the removal?) mirrors the primary path
# exactly, and flagged beads share the same dedup state file and fold into
# the same batched mayor mail — no separate mail path needed.

# ── SAFETY VALVES ────────────────────────────────────────────────────────────
#   - DRY_RUN=1: log decisions, take no action (selftest + supervised first run).
#   - Kill-switch: .gc/state/engine-refusal-strip-watchdog.disabled -> no-op.
#   - Single-instance lock (flock -n): a wedged pass never stacks launchd runs
#     on top of each other (ga-y0g5x class — StartInterval 900s is far above
#     this script's expected sub-minute runtime, and the lock is a second,
#     independent guard against the same failure mode).
#   - Every gc/bd/dolt call is bounded with timeout.
#   - Query failure (not merely zero rows) never marks a commit processed —
#     it is retried next pass instead of silently treated as "nothing found".
#   - No signal, no match -> no action (fail-safe toward inaction; matches
#     merged-bead-janitor's "zero false-positive is paramount" rigor).
#
# Deployed as launchd agent com.gascity.engine-refusal-strip-watchdog
# (StartInterval 900 + RunAtLoad — matches merged-bead-janitor and
# pilot-missing-route-watchdog cadence).
# Log: .gc/logs/engine-refusal-strip-watchdog.log
#
# Supervised first-run procedure (DO NOT load unsupervised on first deploy):
#   1. DRY_RUN=1 bash engine-refusal-strip-watchdog.sh   # preview only
#   2. bash engine-refusal-strip-watchdog.sh             # one supervised real pass
#   3. launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.engine-refusal-strip-watchdog.plist

set -uo pipefail

CITY="${GC_CITY_PATH:-/Users/athos/gt/.gascity-gastown-hq}"
GC="${GC:-gc}"
BD="${BD:-bd}"
LOG_DIR="$CITY/.gc/logs"
LOG="$LOG_DIR/engine-refusal-strip-watchdog.log"
STATE_DIR="$CITY/.gc/state"
RUNTIME_DIR="$CITY/.gc/runtime"
PROCESSED_FILE="$STATE_DIR/engine-refusal-strip-watchdog.processed"
LOCK_FILE="${ENGINE_REFUSAL_STRIP_WATCHDOG_LOCK:-$RUNTIME_DIR/engine-refusal-strip-watchdog.lock}"

DRY_RUN="${DRY_RUN:-0}"
LOOKBACK_HOURS="${LOOKBACK_HOURS:-72}"
DOLT_DB="${DOLT_DB:-hq}"

mkdir -p "$LOG_DIR" "$STATE_DIR" "$RUNTIME_DIR"
touch "$PROCESSED_FILE"

# Export unconditionally (not just read as a local default) so every gc/bd
# child process resolves the SAME city this script is using, whether
# GC_CITY_PATH already existed in the environment or CITY fell back to the
# hardcoded default.
export GC_CITY_PATH="$CITY"

# In DRY_RUN keep output on the terminal (selftest/supervised); else append to log.
if [ "$DRY_RUN" != "1" ]; then
    exec >> "$LOG" 2>&1
fi

log() { echo "[$(date -u '+%Y-%m-%d %H:%M:%S')Z] [engine-refusal-strip] $*"; }

# Startup marker for delivery freshness verification (mirrors crew-hang-
# detector / config-drift-watcher convention). Confirms the LIVE process ran
# the new code after deploy, not merely that the file changed on disk.
printf '%s %s\n' "$$" "$(date +%s)" > "$STATE_DIR/engine-refusal-strip-watchdog.startup"

log "=== pass start (PID $$, LOOKBACK_HOURS=$LOOKBACK_HOURS, DOLT_DB=$DOLT_DB, DRY_RUN=$DRY_RUN) ==="

# Kill-switch.
if [ -f "$STATE_DIR/engine-refusal-strip-watchdog.disabled" ]; then
    log "kill-switch present (engine-refusal-strip-watchdog.disabled) — no-op"
    exit 0
fi

# Single-instance lock. -n exits immediately (not an error) if another pass
# still holds it — never stacks a slow pass behind a wedged one.
exec 9>"$LOCK_FILE" 2>/dev/null || { log "cannot open lock $LOCK_FILE -> exit (fail-safe)"; exit 0; }
if ! flock -n 9; then
    log "another instance already holds the lock ($LOCK_FILE) -> exit"
    exit 0
fi

# ── timestamp helpers ─────────────────────────────────────────────────────────
# Dolt's dolt_log/dolt_diff_labels date columns AND bd's JSON timestamps are
# both UTC; this town runs -03 local. A bare `date -j -f` WITHOUT -u silently
# interprets a UTC wall-clock string as LOCAL and drifts by the zone offset —
# verified live while building this script (a Z-suffixed "now" string parsed
# 3h into the future without -u). Always pass -u on both parse paths.
iso_to_epoch() {  # bd JSON timestamp, e.g. 2026-08-29T19:11:28Z
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null || date -u -d "$1" '+%s' 2>/dev/null
}
sql_to_epoch() {  # dolt SQL datetime, e.g. 2026-08-29 15:06:46.316000
    local base="${1%%.*}"
    date -u -j -f '%Y-%m-%d %H:%M:%S' "$base" '+%s' 2>/dev/null || date -u -d "$base" '+%s' 2>/dev/null
}

# DOLT_SQL <query> — CSV (header + rows, rows may legitimately be zero) on
# stdout, return 0, on success; return 1 (nothing printed) on any failure. The
# caller MUST branch on the return code, not on string emptiness: a
# successful zero-row result still prints the header line, so testing
# `[ -z "$out" ]` alone cannot tell "found nothing" apart from "the query
# never ran" — collapsing those two into one outcome is exactly the trap that
# would let a transient failure get silently treated as a clean sweep.
DOLT_SQL() {
    # NOT `gc --city "$CITY" dolt sql -q ... -r csv`: verified live (building
    # this script) that `dolt sql` mis-parses --city combined with -q/-r —
    # "sql does not take positional arguments, but found N: ity, <path>" (the
    # parser splits "--city" and leaks its tail as a positional arg). `gc
    # mail send` and `bd -C` do not have this bug — only this subcommand.
    # GC_CITY_PATH (exported below via CITY, and set in the plist's
    # EnvironmentVariables) plus WorkingDirectory give city discovery two
    # independent working paths without ever hitting the broken flag combo.
    local out rc
    out="$(timeout 20 "$GC" dolt sql -q "USE $DOLT_DB; $1" -r csv 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        log "DOLT_SQL failed (rc=$rc): $out"
        return 1
    fi
    printf '%s\n' "$out"
    return 0
}

LABELS_SQL="'needs:engine-window','pool:refused:engine-rebuild-required','framework:engine','pilot:refused-reason:engine-rebuild-required'"

# Fingerprint this watchdog stamps on every protective comment it writes
# (both loops below). Used by the second detection path to scope itself to
# beads THIS watchdog previously protected — see the header doc.
WATCHDOG_MARKER="engine-refusal-strip-watchdog (ga-pxtib)"

LOOKBACK_CUTOFF="$(date -u -v-"${LOOKBACK_HOURS}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -d "-${LOOKBACK_HOURS} hours" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
if [ -z "$LOOKBACK_CUTOFF" ]; then
    log "ERROR: could not compute lookback cutoff -> skip pass"
    exit 0
fi

if ! CANDIDATES_CSV="$(DOLT_SQL "SELECT commit_hash, date FROM dolt_log WHERE message LIKE 'bd: label removed%' AND (message LIKE '%needs:engine-window%' OR message LIKE '%pool:refused:engine-rebuild-required%' OR message LIKE '%framework:engine%' OR message LIKE '%pilot:refused-reason:engine-rebuild-required%') AND date > '$LOOKBACK_CUTOFF' ORDER BY date ASC;")"; then
    log "WARN: dolt_log candidate query failed (dolt unavailable?) -> skip pass"
    exit 0
fi

# Second query for the marker-removal path (ga-6u8e4). Deliberately does NOT
# exit 0 on failure the way the primary query does above — a transient
# failure here should not also suppress the primary detection pass.
MARKER_CANDIDATES_CSV=""
if ! MARKER_CANDIDATES_CSV="$(DOLT_SQL "SELECT commit_hash, date FROM dolt_log WHERE message LIKE 'bd: label removed%' AND message LIKE '%pilot:no-auto-dispatch%' AND date > '$LOOKBACK_CUTOFF' ORDER BY date ASC;")"; then
    log "WARN: dolt_log marker-candidate query failed (dolt unavailable?) -> skip marker pass this round"
    MARKER_CANDIDATES_CSV=""
fi

n_candidates=0
n_marker_candidates=0
n_flagged=0
FLAGGED_IDS=""

while IFS=, read -r commit_hash commit_date; do
    [ "$commit_hash" = "commit_hash" ] && continue   # header row
    [ -z "$commit_hash" ] && continue
    n_candidates=$((n_candidates + 1))

    if grep -qxF "$commit_hash" "$PROCESSED_FILE" 2>/dev/null; then
        continue   # already fully evaluated this event
    fi

    if ! DIFF_CSV="$(DOLT_SQL "SELECT from_issue_id, from_label FROM dolt_diff_labels WHERE to_commit = '$commit_hash' AND diff_type = 'removed' AND from_label IN ($LABELS_SQL);")"; then
        log "WARN: dolt_diff_labels lookup failed for $commit_hash -> retry next pass"
        continue   # do NOT mark processed — transient failure, not "no issues"
    fi

    # Unique issue ids touched by this commit (usually exactly 1; the schema
    # allows more, so handle the general case).
    issue_ids="$(printf '%s\n' "$DIFF_CSV" | tail -n +2 | awk -F, '{print $1}' | sort -u)"
    strip_epoch="$(sql_to_epoch "$commit_date")"

    commit_ok=1
    while IFS= read -r issue_id; do
        [ -z "$issue_id" ] && continue

        bead_json="$(timeout 20 "$BD" -C "$CITY" show "$issue_id" --json --include-comments 2>/dev/null)"
        # A bead can be hard-deleted from the working set entirely (not just
        # closed) while dolt_log/dolt_diff_labels — Dolt's immutable commit
        # history — still carries its old label-removal event forever
        # (verified live against production: ga-9n9z7). `bd show` on a
        # deleted id exits non-zero and prints a STRUCTURED {"error": "..."}
        # object on stdout, not an issue array — `.[0].status` on that object
        # silently reads as empty rather than erroring, which would otherwise
        # collapse "gone" and "found, but state unreadable" into the same
        # blank value and let a permanently-deleted bead get "flagged" with a
        # label-add call that can never land. Gate on a real issue record
        # first; only trust the bead's own structured .error to mean
        # "permanently resolved, nothing left to protect" — anything else
        # unparseable (truncated output, a timeout) stays a transient retry.
        if ! printf '%s' "$bead_json" | jq -e '.[0].id' >/dev/null 2>&1; then
            bd_err="$(printf '%s' "$bead_json" | jq -r 'if type == "object" then (.error // empty) else empty end' 2>/dev/null)"
            if [ -n "$bd_err" ]; then
                log "$issue_id: bd show reports '$bd_err' (no longer resolves, likely deleted) -> nothing left to protect"
                continue
            fi
            log "WARN: bd show returned no usable issue data for $issue_id (commit $commit_hash) -> retry next pass"
            commit_ok=0
            continue
        fi

        status="$(printf '%s' "$bead_json" | jq -r '.[0].status // empty' 2>/dev/null)"
        if [ "$status" = "closed" ]; then
            log "$issue_id: closed -> resolved, no action"
            continue
        fi

        labels_csv="$(printf '%s' "$bead_json" | jq -r '(.[0].labels // []) | join(",")' 2>/dev/null)"
        case ",$labels_csv," in
            *,pilot:no-auto-dispatch,*|*,no-auto-dispatch,*|*,needs:engine-window,*|*,pool:refused:engine-rebuild-required,*|*,framework:engine,*|*,pilot:refused-reason:engine-rebuild-required,*)
                log "$issue_id: already protected (labels: $labels_csv) -> no action"
                continue
                ;;
        esac

        latest_comment_iso="$(printf '%s' "$bead_json" | jq -r '[(.[0].comments // [])[].created_at] | max // empty' 2>/dev/null)"
        if [ -n "$latest_comment_iso" ] && [ -n "$strip_epoch" ]; then
            c_epoch="$(iso_to_epoch "$latest_comment_iso")"
            if [ -n "$c_epoch" ] && [ "$c_epoch" -gt "$strip_epoch" ]; then
                log "$issue_id: has a comment postdating the strip ($latest_comment_iso > $commit_date UTC) -> story moved on, no action"
                continue
            fi
        fi

        # Exposed: open or in_progress, unprotected, silent since the strip.
        n_flagged=$((n_flagged + 1))
        FLAGGED_IDS="$FLAGGED_IDS $issue_id"
        log "$issue_id: EXPOSED (status=$status, strip commit=$commit_hash @ ${commit_date} UTC) -> flag with pilot:no-auto-dispatch"
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY_RUN] would: label add pilot:no-auto-dispatch, comment $issue_id"
            # DRY_RUN must never advance the dedup state — a preview pass has
            # to leave the real first pass something to actually act on.
            commit_ok=0
            continue
        fi
        if ! timeout 20 "$BD" -C "$CITY" label add "$issue_id" pilot:no-auto-dispatch >/dev/null 2>&1; then
            log "  ERROR: label add failed for $issue_id -> retry next pass"
            commit_ok=0
            continue
        fi
        timeout 20 "$BD" -C "$CITY" comment "$issue_id" \
            "$WATCHDOG_MARKER: this bead's engine-refusal labels were stripped by commit $commit_hash @ ${commit_date} UTC (an absorbed-patch reconciliation confirming source-tree byte-identity — see ga-fn35s), but the bead was never closed and has stayed unprotected since. Added pilot:no-auto-dispatch as a safety-net veto so Pilot cannot re-dispatch it as fresh work. Source-tree match is not proof the fix is live in the deployed binary — clear this veto manually once that is confirmed (or once you've determined the bead is legitimately out of engine-window scope)." \
            >/dev/null 2>&1 || log "  WARN: comment failed for $issue_id (label add already succeeded)"
    done <<< "$issue_ids"

    if [ "$commit_ok" = "1" ]; then
        echo "$commit_hash" >> "$PROCESSED_FILE"
    fi
done <<< "$CANDIDATES_CSV"

# ── second pass: the watchdog's own veto being removed (ga-6u8e4) ──────────
# Mirrors the loop above almost exactly (same helpers, same dedup file, same
# per-bead checks), with one extra gate before anything else: skip unless a
# prior WATCHDOG_MARKER comment predates this removal. That gate is what
# keeps this scoped to beads this watchdog itself protected, instead of
# reacting to every unrelated pilot:no-auto-dispatch clear in the city.
while IFS=, read -r commit_hash commit_date; do
    [ "$commit_hash" = "commit_hash" ] && continue   # header row
    [ -z "$commit_hash" ] && continue
    n_marker_candidates=$((n_marker_candidates + 1))

    if grep -qxF "$commit_hash" "$PROCESSED_FILE" 2>/dev/null; then
        continue   # already fully evaluated this event
    fi

    if ! DIFF_CSV="$(DOLT_SQL "SELECT from_issue_id, from_label FROM dolt_diff_labels WHERE to_commit = '$commit_hash' AND diff_type = 'removed' AND from_label = 'pilot:no-auto-dispatch';")"; then
        log "WARN: dolt_diff_labels marker lookup failed for $commit_hash -> retry next pass"
        continue   # do NOT mark processed — transient failure, not "no issues"
    fi

    issue_ids="$(printf '%s\n' "$DIFF_CSV" | tail -n +2 | awk -F, '{print $1}' | sort -u)"
    strip_epoch="$(sql_to_epoch "$commit_date")"

    commit_ok=1
    while IFS= read -r issue_id; do
        [ -z "$issue_id" ] && continue

        bead_json="$(timeout 20 "$BD" -C "$CITY" show "$issue_id" --json --include-comments 2>/dev/null)"
        if ! printf '%s' "$bead_json" | jq -e '.[0].id' >/dev/null 2>&1; then
            bd_err="$(printf '%s' "$bead_json" | jq -r 'if type == "object" then (.error // empty) else empty end' 2>/dev/null)"
            if [ -n "$bd_err" ]; then
                log "$issue_id: bd show reports '$bd_err' (no longer resolves, likely deleted) -> nothing left to protect"
                continue
            fi
            log "WARN: bd show returned no usable issue data for $issue_id (marker commit $commit_hash) -> retry next pass"
            commit_ok=0
            continue
        fi

        status="$(printf '%s' "$bead_json" | jq -r '.[0].status // empty' 2>/dev/null)"
        if [ "$status" = "closed" ]; then
            log "$issue_id: closed -> resolved, no action"
            continue
        fi

        # The scoping gate: only beads THIS watchdog previously protected.
        watchdog_comment_iso="$(printf '%s' "$bead_json" | jq -r --arg marker "$WATCHDOG_MARKER" '[(.[0].comments // [])[] | select((.text // "") | startswith($marker)) | .created_at] | max // empty' 2>/dev/null)"
        if [ -z "$watchdog_comment_iso" ]; then
            log "$issue_id: pilot:no-auto-dispatch removed but no prior watchdog comment found -> not our protection, no action"
            continue
        fi
        wc_epoch="$(iso_to_epoch "$watchdog_comment_iso")"
        if [ -z "$wc_epoch" ] || [ -z "$strip_epoch" ] || [ "$wc_epoch" -ge "$strip_epoch" ]; then
            log "$issue_id: watchdog comment ($watchdog_comment_iso) does not predate this removal (commit $commit_hash @ ${commit_date} UTC) -> not this removal's target, no action"
            continue
        fi

        labels_csv="$(printf '%s' "$bead_json" | jq -r '(.[0].labels // []) | join(",")' 2>/dev/null)"
        case ",$labels_csv," in
            *,pilot:no-auto-dispatch,*|*,no-auto-dispatch,*|*,needs:engine-window,*|*,pool:refused:engine-rebuild-required,*|*,framework:engine,*|*,pilot:refused-reason:engine-rebuild-required,*)
                log "$issue_id: already protected again (labels: $labels_csv) -> no action"
                continue
                ;;
        esac

        latest_comment_iso="$(printf '%s' "$bead_json" | jq -r '[(.[0].comments // [])[].created_at] | max // empty' 2>/dev/null)"
        if [ -n "$latest_comment_iso" ] && [ -n "$strip_epoch" ]; then
            c_epoch="$(iso_to_epoch "$latest_comment_iso")"
            if [ -n "$c_epoch" ] && [ "$c_epoch" -gt "$strip_epoch" ]; then
                log "$issue_id: has a comment postdating this removal ($latest_comment_iso > $commit_date UTC) -> story moved on, no action"
                continue
            fi
        fi

        n_flagged=$((n_flagged + 1))
        FLAGGED_IDS="$FLAGGED_IDS $issue_id"
        log "$issue_id: EXPOSED — own veto removed (status=$status, marker-strip commit=$commit_hash @ ${commit_date} UTC) -> re-flag with pilot:no-auto-dispatch"
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY_RUN] would: label add pilot:no-auto-dispatch, comment $issue_id"
            commit_ok=0
            continue
        fi
        if ! timeout 20 "$BD" -C "$CITY" label add "$issue_id" pilot:no-auto-dispatch >/dev/null 2>&1; then
            log "  ERROR: label add failed for $issue_id -> retry next pass"
            commit_ok=0
            continue
        fi
        timeout 20 "$BD" -C "$CITY" comment "$issue_id" \
            "$WATCHDOG_MARKER: this bead's pilot:no-auto-dispatch veto -- which this watchdog had previously added after detecting an engine-refusal-label strip (see this bead's earlier watchdog comment) -- was itself removed by commit $commit_hash @ ${commit_date} UTC, without the bead being closed or its engine-refusal labels restored. Re-added pilot:no-auto-dispatch as a safety-net veto so Pilot cannot re-dispatch it as fresh work. Clear this veto manually once you've confirmed the underlying engine-rebuild constraint no longer applies (fix confirmed LIVE in the deployed binary, not just source-tree match -- or the bead's scope changed to no longer need one)." \
            >/dev/null 2>&1 || log "  WARN: comment failed for $issue_id (label add already succeeded)"
    done <<< "$issue_ids"

    if [ "$commit_ok" = "1" ]; then
        echo "$commit_hash" >> "$PROCESSED_FILE"
    fi
done <<< "$MARKER_CANDIDATES_CSV"

if [ "$n_flagged" -gt 0 ] && [ "$DRY_RUN" != "1" ]; then
    if timeout 15 "$GC" --city "$CITY" mail send mayor \
        -s "[engine-refusal-strip-watchdog] $n_flagged bead(s) protected" \
        -m "engine-refusal-strip-watchdog found engine-refusal labels stripped without the bead being closed or protected, and added pilot:no-auto-dispatch as a safety-net veto on:$FLAGGED_IDS. See each bead's own comment for the strip-commit evidence. Clear the veto manually once each fix is confirmed live in the deployed binary (ga-fn35s / ga-pxtib)." \
        >/dev/null 2>&1; then
        log "mail OK: mayor ($n_flagged bead(s):$FLAGGED_IDS)"
    else
        log "WARN: mayor mail failed/timed out (protective labels/comments already applied regardless)"
    fi
elif [ "$n_flagged" -gt 0 ]; then
    log "[DRY_RUN] would mail mayor about $n_flagged bead(s):$FLAGGED_IDS"
fi

log "=== pass complete (candidates=$n_candidates, marker_candidates=$n_marker_candidates, flagged=$n_flagged) ==="
exit 0

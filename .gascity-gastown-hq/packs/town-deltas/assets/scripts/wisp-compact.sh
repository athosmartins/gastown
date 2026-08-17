#!/usr/bin/env bash
# wisp-compact — TTL-based cleanup of expired ephemeral beads.
#
# Wisps are short-lived work items (heartbeats, pings, patrols) that
# accumulate and bloat the database. This script applies retention policy:
# - Closed wisps past TTL → deleted (Dolt AS OF preserves history)
# - Non-closed wisps past TTL → promoted to permanent (stuck detection)
# - Wisps with comments or "keep" label → promoted (proven value)
# - Closed mail (issue_type=="message") → never deleted (see ga-3rqwa); open
#   mail is unaffected and still follows the non-closed promote rule above
#
# TTL by wisp_type label:
#   heartbeat, ping: 6h
#   patrol, gc_report: 24h
#   recovery, error, escalation: 7d
#   default (untyped): 24h
#
# Runs as an exec order (no LLM, no agent, no wisp).
#
# town-deltas override (ga-3rqwa): vendored from the embedded
# .gc/system/packs/maintenance copy so this fix is git-tracked and durable —
# $PACK_DIR in packs/town-deltas/orders/wisp-compact.toml resolves here
# instead of the ephemeral materialized copy. Same recipe as orphan-sweep's
# override. Only change vs. the embedded original: the mail carve-out below.
set -euo pipefail

# Trace bd invocations to $GC_BD_TRACE when set (no-op otherwise).
__SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ga-5a87qv: `.`/source is a POSIX special builtin — under this file's
# `set -euo pipefail`, a missing/unreadable target kills the shell
# immediately, before any log/warn call exists (same defect class ga-q4sadt
# fixed for the core gate/dispatch pipeline). Check readability BEFORE
# sourcing instead.
# shellcheck disable=SC1091
if [ -r "$__SCRIPT_DIR/_bd_trace.sh" ]; then
  . "$__SCRIPT_DIR/_bd_trace.sh" "wisp-compact"
fi

CITY="${GC_CITY:-.}"

# Get all ephemeral beads.
ALL=$(bd list --json --all -n 0 2>/dev/null) || exit 0
EPHEMERALS=$(echo "$ALL" | jq '[.[] | select(.ephemeral == true)]' 2>/dev/null) || exit 0

if [ -z "$EPHEMERALS" ] || [ "$EPHEMERALS" = "[]" ]; then
    exit 0
fi

NOW=$(date +%s)
PROMOTED=0
DELETED=0
SKIPPED=0
PRESERVED=0

# Process each ephemeral bead. Capturing jq output into BEADS first
# (instead of piping into the loop) preserves the original pipefail
# fail-loud on jq error AND keeps PROMOTED/DELETED/SKIPPED in the parent
# shell so they survive to the summary echo below. EPHEMERALS is
# pre-validated as a non-empty array above, so BEADS is guaranteed
# non-empty here.
BEADS=$(echo "$EPHEMERALS" | jq -c '.[]' 2>/dev/null)
while IFS= read -r bead; do
    id=$(echo "$bead" | jq -r '.id')
    status=$(echo "$bead" | jq -r '.status')
    updated_at=$(echo "$bead" | jq -r '.updated_at // .created_at')
    comment_count=$(echo "$bead" | jq -r '.comment_count // 0')
    issue_type=$(echo "$bead" | jq -r '.issue_type // ""')
    labels=$(echo "$bead" | jq -r '.labels // [] | .[]' 2>/dev/null)

    # Determine TTL from wisp_type label.
    TTL_SECONDS=$((24 * 3600))  # default: 24h
    for label in $labels; do
        case "$label" in
            wisp_type:heartbeat|wisp_type:ping) TTL_SECONDS=$((6 * 3600)) ;;
            wisp_type:patrol|wisp_type:gc_report) TTL_SECONDS=$((24 * 3600)) ;;
            wisp_type:recovery|wisp_type:error|wisp_type:escalation) TTL_SECONDS=$((7 * 24 * 3600)) ;;
            keep) TTL_SECONDS=0 ;;  # force promote
        esac
    done

    # Calculate age. bd emits RFC3339 timestamps with a trailing 'Z'; the
    # second BSD `date -ju -f` fallback handles that explicitly and forces
    # UTC semantics to match GNU `date -d`. The third layout supports older
    # no-Z timestamps without interpreting them in the local timezone.
    BEAD_TS=$(date -d "$updated_at" +%s 2>/dev/null || \
              date -ju -f "%Y-%m-%dT%H:%M:%SZ" "$updated_at" +%s 2>/dev/null || \
              date -ju -f "%Y-%m-%dT%H:%M:%S" "$updated_at" +%s 2>/dev/null) || continue
    AGE=$((NOW - BEAD_TS))

    # Skip if within TTL (unless force-promote via keep label).
    if [ "$TTL_SECONDS" -gt 0 ] && [ "$AGE" -lt "$TTL_SECONDS" ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # ga-3rqwa: mail is the ONLY durable record of who authored a message and
    # when. `gc mail archive/read/delete` all soft-close the underlying bead
    # (bd close) — they do NOT delete it — but mail carries no wisp_type:
    # label, so it falls into the untyped 24h default bucket, and (before this
    # fix) any CLOSED mail with zero comments past that TTL hit the delete
    # branch below within a day, permanently destroying the sole primary-
    # source evidence a later authorship dispute needs (confirmed live: an
    # archived mail wisp was hard-deleted this way, `bd show` returned "no
    # issue found", row absent from `hq.wisps` entirely). Never delete closed
    # mail here — leave it exactly as-is (still ephemeral, still closed) so
    # `bd show <mail-id>` keeps answering "who wrote this, and when"
    # indefinitely, same as the existing quality-gate carve-out below protects
    # gate wisps from the opposite mistake (never-delete bloat). Scoped to
    # status=="closed" only — open/unread mail was never at risk of deletion
    # (non-closed wisps always went to the promote branch, never delete), so
    # leave that pre-existing "stuck detection" promotion behavior unchanged
    # for open mail rather than widening this fix beyond the reported bug.
    if [ "$issue_type" = "message" ] && [ "$status" = "closed" ]; then
        PRESERVED=$((PRESERVED + 1))
        continue
    fi

    # ga-jhyu: quality-gate run/marker/verdict wisps are high-volume and
    # self-documenting via their own comments; the gate decision is enacted on
    # the SOURCE bead, not these tracking wisps. Once CLOSED (terminal) they must
    # be DELETED, not promoted — otherwise comment_count>0 converts every terminal
    # gate bead into a persistent orphan (the real city-DB bloat driver). Only
    # CLOSED ones are carved out, so an in-flight gate bead is never deleted.
    if [ "$status" = "closed" ] && echo "$labels" | grep -qE '^type:quality-gate-(run|marker|verdict)$'; then
        bd delete "$id" --force 2>/dev/null || true
        DELETED=$((DELETED + 1))
        continue
    fi

    # Promote if has comments, keep label, or non-closed.
    if [ "$comment_count" -gt 0 ] || echo "$labels" | grep -q '^keep$' || [ "$status" != "closed" ]; then
        REASON="proven value"
        [ "$status" != "closed" ] && REASON="open past TTL (stuck detection)"
        bd update "$id" --persistent 2>/dev/null || true
        bd comment "$id" "Promoted from wisp: $REASON" 2>/dev/null || true
        PROMOTED=$((PROMOTED + 1))
        continue
    fi

    # Closed + past TTL + no special attributes → delete.
    bd delete "$id" --force 2>/dev/null || true
    DELETED=$((DELETED + 1))
done <<< "$BEADS"

TOTAL=$((PROMOTED + DELETED))
if [ "$TOTAL" -gt 0 ] || [ "$PRESERVED" -gt 0 ]; then
    echo "wisp-compact: promoted=$PROMOTED deleted=$DELETED skipped=$SKIPPED preserved_mail=$PRESERVED"
fi

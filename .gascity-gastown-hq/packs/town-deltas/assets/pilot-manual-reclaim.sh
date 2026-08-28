#!/usr/bin/env bash
# pilot-manual-reclaim.sh — safe replacement for raw `bd reclaim <id>` on a
# Pilot-dispatched bead (gt-1kkgu).
#
# `bd reclaim` is generic beads-CLI lease-reaping: it clears assignee/status
# on a stale-lease issue, with no notion of Gas Town's own Pilot claim
# markers (pilot:dispatched / pilot:dispatching labels, pilot.dispatched_at
# metadata). A bead reclaimed via raw `bd reclaim` keeps those markers, and
# every Pilot Tier1/Tier2 candidate-scan query (_scan_rig_fallback_pool and
# its HQ siblings in pilot-dispatcher.sh) unconditionally excludes anything
# still wearing pilot:dispatched — so the bead goes PERMANENTLY invisible to
# re-dispatch even though it is back to status=open+unassigned, exactly the
# state those queries are supposed to find (confirmed live on wa-2txhl,
# 2026-08-22: 1h44min stuck before a human noticed).
#
# inflight-reclaim-guard.py's own do_reclaim() already strips story:in-flight
# and pilot:dispatched correctly (its automated path is NOT the gap). This
# script gives a human/agent doing an AD-HOC manual reclaim — e.g. forcing an
# early release instead of waiting on a TTL — the same safety, instead of
# reaching for raw `bd reclaim`.
#
# Usage: pilot-manual-reclaim.sh <bead-id> [rig-path]
#   rig-path: optional -C target for a rig-native bead (default: HQ / bd
#             auto-discovery from CWD).
#
# Safety: only strips the Pilot claim markers (and the story:in-flight
# lane-occupancy label, ga-xoa3n) when the reclaim actually flipped the bead
# to status=open. If the lease had not expired yet (bd reclaim no-ops, or the
# bead was never in_progress to begin with), nothing is touched — a
# still-legitimately in-flight bead is never exposed to re-dispatch just
# because this script ran.
set -uo pipefail

BEAD_ID="${1:?usage: pilot-manual-reclaim.sh <bead-id> [rig-path]}"
RIG_PATH="${2:-}"
BD=(bd)
[ -n "$RIG_PATH" ] && BD=(bd -C "$RIG_PATH")

# --older-than 0s: reclaim immediately if the lease has expired at all, no
# extra grace buffer — a human running this already decided to act now
# instead of waiting for the automated guard's own TTL.
"${BD[@]}" reclaim --id "$BEAD_ID" --older-than 0s -q

STATUS=$("${BD[@]}" show "$BEAD_ID" --json 2>/dev/null | jq -r '.[0].status // empty' 2>/dev/null)

if [ "$STATUS" != "open" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID is not open after reclaim (status=${STATUS:-unknown}) — reclaim did not confirm a state change (lease not stale, bead not found, or read failed). Pilot claim markers left untouched." >&2
  exit 0
fi

"${BD[@]}" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
"${BD[@]}" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
"${BD[@]}" update "$BEAD_ID" --unset-metadata "pilot.dispatched_at" -q 2>/dev/null || true
# ga-xoa3n: story:in-flight is what makes a bead count against the dispatch
# lane's cap (pilot-dispatcher.sh's in-flight query keys on this label, not
# on the Pilot markers above) — a reclaim that clears assignee/status but
# leaves this label behind keeps permanently occupying a lane slot even
# though nobody is building the bead anymore. Strip it in the same
# status==open-gated path as the Pilot markers.
"${BD[@]}" label remove "$BEAD_ID" "story:in-flight" -q 2>/dev/null || true

# Verify the actual post-state rather than trusting the removal commands'
# exit codes (suppressed above with `|| true` since "label was never set" is
# a harmless non-error case too) — don't claim "cleared" unless it is. A
# failed/unreadable verification read must NOT collapse into the same empty
# value as "positively confirmed zero markers remain" (mirrors the STATUS
# check above, which already fails closed on empty read output).
VERIFY_JSON=$("${BD[@]}" show "$BEAD_ID" --json 2>/dev/null)

if [ -z "$VERIFY_JSON" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) but the post-removal verification read returned nothing — could NOT confirm Pilot claim markers cleared. Re-run bd show $BEAD_ID manually to check." >&2
  exit 1
fi

REMAINING=$(printf '%s' "$VERIFY_JSON" | jq -r '
  .[0] as $b
  | if $b == null then error("verification read did not return the issue")
    else
      ([($b.labels // [])[] | select(. == "pilot:dispatched" or . == "pilot:dispatching" or . == "story:in-flight")]
       + (if (($b.metadata["pilot.dispatched_at"] // "") != "") then ["pilot.dispatched_at"] else [] end))
      | join(",")
    end
' 2>/dev/null)
JQ_STATUS=$?

if [ "$JQ_STATUS" -ne 0 ]; then
  echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) but the post-removal verification response could NOT be parsed — could NOT confirm Pilot claim markers cleared. Re-run bd show $BEAD_ID manually to check." >&2
  exit 1
fi

if [ -n "$REMAINING" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) but could NOT confirm all Pilot claim markers cleared — still present: $REMAINING. Retry the label/metadata removal manually." >&2
  exit 1
fi

echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open), Pilot claim markers cleared, and story:in-flight removed — bead no longer occupies a dispatch lane slot and is visible to Pilot re-dispatch again."

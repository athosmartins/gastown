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
# Safety: only strips the Pilot claim markers when the reclaim actually
# flipped the bead to status=open. If the lease had not expired yet (bd
# reclaim no-ops, or the bead was never in_progress to begin with), nothing
# is touched — a still-legitimately in-flight bead is never exposed to
# re-dispatch just because this script ran.
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
  echo "pilot-manual-reclaim: $BEAD_ID is not open after reclaim (status=${STATUS:-unknown}) — lease was not stale, nothing reclaimed. Pilot claim markers left untouched." >&2
  exit 0
fi

"${BD[@]}" label remove "$BEAD_ID" "pilot:dispatched"  -q 2>/dev/null || true
"${BD[@]}" label remove "$BEAD_ID" "pilot:dispatching" -q 2>/dev/null || true
"${BD[@]}" update "$BEAD_ID" --unset-metadata "pilot.dispatched_at" -q 2>/dev/null || true

echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) and Pilot claim markers cleared — visible to Pilot re-dispatch again."

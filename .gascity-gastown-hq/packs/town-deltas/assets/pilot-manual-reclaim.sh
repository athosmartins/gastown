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

POST_RECLAIM_JSON=$("${BD[@]}" show "$BEAD_ID" --json 2>/dev/null)
STATUS=$(printf '%s' "$POST_RECLAIM_JSON" | jq -r '.[0].status // empty' 2>/dev/null)

if [ "$STATUS" != "open" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID is not open after reclaim (status=${STATUS:-unknown}) — reclaim did not confirm a state change (lease not stale, bead not found, or read failed). Pilot claim markers left untouched." >&2
  exit 0
fi

# ga-zkaoe: mirror do_reclaim()'s reclaim-count bump (inflight-reclaim-
# guard.py step 3 — remove the old pilot:reclaim-count:<N> label, add
# <N+1>) so a manual reclaim is no longer invisible to the automated
# guard's MAX_RECLAIMS cap and reloop-cooldown threshold, both of which key
# off this label. Parsed the same way as the Python's parse_reclaim_count():
# first label matching the prefix that parses as an int, 0 if none. Reused
# from the JSON already fetched above — no extra bd call.
CUR_RECLAIM_COUNT=$(printf '%s' "$POST_RECLAIM_JSON" | jq -r '
  [(.[0].labels // [])[] | select(startswith("pilot:reclaim-count:")) | ltrimstr("pilot:reclaim-count:") | tonumber?]
  | .[0] // 0
' 2>/dev/null)
case "$CUR_RECLAIM_COUNT" in ''|*[!0-9]*) CUR_RECLAIM_COUNT=0 ;; esac
NEW_RECLAIM_COUNT=$((CUR_RECLAIM_COUNT + 1))

# ga-w6a9xps: a STORY (feature/story) comes back to the pool with its story:approved. The builder's own claim drops that label while the Pilot's
# story:in-flight stays; taking story:in-flight off below would leave the story with no story:* label at all, which auto-refino's RAW sweep reads as a fresh
# idea and sends back to Athos for a second approval (wa-tvrs41.5, 13/11). So the approval goes back FIRST, confirmed by a fresh read, and only then do
# the markers come off. Same rule and verdict words as inflight-reclaim-guard.py's _approved_verdict (ga-w6a9xps slice 2 + ga-btr2dof) and the copy in
# crew-liveness-probe.sh; keep them in step. Only a feature/story carrying story:in-flight and NO other story:* label, WITH a trace of the Pilot's dispatch or of
# Athos's approval (pilot:dispatched, pilot.dispatched_at or story.aprovado_por), gets "restore". Without a trace it may be a bead Athos parked by hand and only
# he approves ("no-proof"). With the tech-debt label the Pilot's Tier-1 dispatched it with NO approval at all (pilot-dispatcher.sh DEBT_JSON: bd list -l tech-debt,
# any type but epic), so a dispatch trace proves nothing about Athos ("tier1-bypass"). The other verdicts (has-approved, not-in-flight, other-story-state, not-story = a
# bug/task/chore, which never had story:approved) write nothing. The verdict is printed either way, so the output tells a story released RAW on purpose from a non-story.
# vazio (nenhuma palavra: o JSON da bead não é uma bead legível) → NÃO sei: nada é tirado, exit 1; falhou/ilegível na releitura → idem; "restore" é o único que escreve
APPROVED_VERDICT=$(printf '%s' "$POST_RECLAIM_JSON" | jq -r '
  (if type == "array" then .[0] else . end) as $b
  | if ($b | type) == "object" and ($b.status | type) == "string" then
      (($b.labels // []) | map(tostring)) as $l
      | if ($l | index("story:approved")) != null then "has-approved"
        elif ($l | index("story:in-flight")) == null then "not-in-flight"
        elif ($l | map(select(startswith("story:") and . != "story:in-flight")) | length) > 0 then "other-story-state"
        elif ($b.issue_type == "feature" or $b.issue_type == "story") then
          (if ($l | index("tech-debt")) != null then "tier1-bypass"
           else ((if ($b.metadata | type) == "object" then $b.metadata else {} end) as $m
                 | if ($l | index("pilot:dispatched")) != null or (($m["pilot.dispatched_at"] // "") | tostring) != "" or (($m["story.aprovado_por"] // "") | tostring) != "" then "restore" else "no-proof" end)
           end)
        else "not-story" end
    else empty end' 2>/dev/null)
if [ -z "$APPROVED_VERDICT" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) but its labels could NOT be read to decide whether story:approved must be restored — Pilot claim markers and story:in-flight left untouched. Re-run bd show $BEAD_ID and restore by hand if it is a story." >&2
  exit 1
fi
echo "pilot-manual-reclaim: $BEAD_ID story:approved check: verdict=$APPROVED_VERDICT"
if [ "$APPROVED_VERDICT" = "restore" ]; then
  "${BD[@]}" label add "$BEAD_ID" "story:approved" -q 2>/dev/null || true
  APPROVED_BACK=$("${BD[@]}" show "$BEAD_ID" --json 2>/dev/null | jq -r '(if type == "array" then .[0] else . end) | if type == "object" then ((.labels // []) | any(. == "story:approved")) else empty end' 2>/dev/null)
  if [ "$APPROVED_BACK" != "true" ]; then
    echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open) but story:approved could NOT be confirmed back on the story (read-back said '${APPROVED_BACK:-unreadable}') — Pilot claim markers and story:in-flight left untouched, so auto-refino does not take it for a new idea. Retry: bd label add $BEAD_ID story:approved, then re-run this script." >&2
    exit 1
  fi
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
if [ "$CUR_RECLAIM_COUNT" -gt 0 ]; then
  "${BD[@]}" label remove "$BEAD_ID" "pilot:reclaim-count:${CUR_RECLAIM_COUNT}" -q 2>/dev/null || true
fi
"${BD[@]}" label add "$BEAD_ID" "pilot:reclaim-count:${NEW_RECLAIM_COUNT}" -q 2>/dev/null || true

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

# ga-zkaoe: confirm the reclaim-count bump landed too — this whole fix
# exists to make that label reliable, so don't claim success without
# checking it, same "verify, don't trust" gate as the other markers above.
RECLAIM_COUNT_OK=$(printf '%s' "$VERIFY_JSON" | jq -r --arg want "pilot:reclaim-count:${NEW_RECLAIM_COUNT}" '
  (.[0].labels // []) | any(. == $want)
' 2>/dev/null)

if [ "$RECLAIM_COUNT_OK" != "true" ]; then
  echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open); pilot:dispatched/pilot:dispatching/story:in-flight cleared, but could NOT confirm pilot:reclaim-count:${NEW_RECLAIM_COUNT} was set — MAX_RECLAIMS/reloop-cooldown in inflight-reclaim-guard.py may undercount this attempt. Retry manually: bd label remove $BEAD_ID pilot:reclaim-count:${CUR_RECLAIM_COUNT} (if present) && bd label add $BEAD_ID pilot:reclaim-count:${NEW_RECLAIM_COUNT}" >&2
  exit 1
fi

echo "pilot-manual-reclaim: $BEAD_ID reclaimed (status=open), Pilot claim markers cleared (pilot:reclaim-count now ${NEW_RECLAIM_COUNT}), and story:in-flight removed — bead no longer occupies a dispatch lane slot and is visible to Pilot re-dispatch again."

#!/bin/sh
# pool-probe-sling-lib.sh — the sling filter of the dog's probe (ga-b97dgq). SOURCED by pool-probe.sh, never executed: it only
# defines variables and functions and has no side effect at source time.
#
# Why a lib and not inline. pool-probe.sh is a snapshot of the engine's probe and pool-probe.selftest.sh pins that every long
# jq/bd literal in it is the engine's own (check 8). This filter is a deliberate difference from the engine, so its programs
# live here (the disk floor's lib, disk-headroom-lib.sh, is the same arrangement). Proof: pool-probe-sling-in-hand.selftest.sh.
# pool-probe.sh defines `drop_slings_for_taken_stories` as a pass-through (cat) BEFORE sourcing this file, so a lib that is
# missing or corrupt leaves the engine's own answer and a line in the pool-probe log; sourcing this file replaces it.
#
# Sling wisps whose story is already in live hands (ga-b97dgq). The Pilot's dispatch creates a sling wisp per story
# (gc.routed_to=<pool> + metadata pilot.sling_for=<story id>). Its own funnel already leaves wisps out
# (_filter_candidates, ga-nimyz) and it defers the wisp of a reused session (ga-i58em), but this probe is a snapshot of the
# engine's and reads neither: on 16/10 an idle dog took the wisp ga-ue9qgi while dog-2 was building its story, and spent a
# whole session finding out and closing the duplicate. So every tier drops a candidate with pilot.sling_for whose story is
# IN HAND: the story is not closed, it has an assignee, and that assignee is a live session (not closed in `gc session list`,
# and not a drained -adhoc- worker that went asleep: it will never resume that build) or the story's bd lease
# (lease_expires_at) has not run out.
# Three states, never two:
#   in hand                      -> dropped: a second builder duplicates a live build
#   free (no assignee, closed) or provably dead (roster read, assignee not in it, no live lease)
#                                -> KEPT, silently: the wisp is the vehicle that re-dispatches that story
#   could not tell (bd show failed or answered something that is not a story; roster unreadable and no live lease; a lease
#   that cannot be parsed and an assignee the roster does not list)
#                                -> KEPT (the engine's own answer) and said on stderr, so the fail-open is visible
# The filter runs BEFORE the oldest-pick: after it, a duplicate wisp that happens to be the oldest would empty the answer
# while legitimate work waits right behind it. A candidate without pilot.sling_for costs nothing: no bd show, no gc call.
STORY_HAND_JQ='(if type == "array" then .[0] else . end) as $s
  | if ($s | type) != "object" or (($s.id // "") | tostring) == "" then "unreadable"
    else ($s.assignee // "") as $a
      | if ($s.status // "") == "closed" or $a == "" then "free"
        else
          ($s.lease_expires_at // null) as $raw
          | (if $raw == null or $raw == "" then "none"
             else (($raw | if type == "number" then . else (tostring | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch null) end) as $e
                   | if $e == null then "bad" elif $e > $now then "live" else "expired" end) end) as $lease
          | if $lease == "live" then "hand"
            elif $roster == null then "unreadable"
            elif ($roster | index($a)) != null then "hand"
            elif $lease == "bad" then "unreadable"
            else "dead" end
        end
      end'
# `gc session list --json` -> the ids of the sessions that can still own a build (every name field, like the dispatcher's
# roster); null when it cannot say. An empty roster is "cannot tell" too, never "nobody is alive".
SESSION_ROSTER_JQ='if (.sessions | type) != "array" then null
  else ([ .sessions[] | select(.closed != true)
          | [.session_name, .name, .alias, .id, .agent_name] as $ids
          | select(((.state // "") == "asleep" and any($ids[]?; type == "string" and test("-adhoc-"))) | not)
          | $ids[] | select(type == "string" and . != "") ] | unique) as $live
       | if ($live | length) == 0 then null else $live end
  end'
read_roster() {
  sl_city="${GC_CITY_PATH:-${GC_CITY:-}}"
  if [ -n "$sl_city" ]; then sl_out=$(gc --city "$sl_city" session list --json 2>/dev/null </dev/null) || return 1
  else sl_out=$(gc session list --json 2>/dev/null </dev/null) || return 1; fi
  [ -n "$sl_out" ] || return 1
  printf "%s" "$sl_out" | jq -c "$SESSION_ROSTER_JQ" 2>/dev/null
}
drop_slings_for_taken_stories() {
  cands=$(cat)
  pairs=$(printf "%s" "$cands" | jq -r '.[] | select(((.metadata["pilot.sling_for"] // "") | type == "string") and ((.metadata["pilot.sling_for"] // "") | test("\\S"))) | [.id, (.metadata["pilot.sling_for"] | gsub("^\\s+|\\s+$"; ""))] | @tsv' 2>/dev/null)
  # vazio -> no wisp in this answer, nothing to look up (no bd show, no gc call); falhou/ilegível (the answer is not JSON) -> the same: it goes on exactly as it would without this filter
  if [ -z "$pairs" ]; then printf "%s" "$cands"; return 0; fi
  now_s=$(date +%s)
  drop_ids=$(printf "%s\n" "$pairs" | {
    roster_read=""; roster=null
    while IFS="$(printf '\t')" read -r wid story; do
      [ -z "$wid" ] && continue
      # vazio/falhou/ilegível -> verdict stays "unreadable": the wisp is kept and stderr says so
      verdict=unreadable
      story_json=$(bd show "$story" --json 2>/dev/null </dev/null) && [ -n "$story_json" ] || story_json=""
      if [ -n "$story_json" ]; then
        if [ -z "$roster_read" ]; then
          # vazio/falhou/ilegível -> roster stays null: only a live lease can prove "in hand" then
          roster=$(read_roster) || roster=null
          case "$roster" in "["*) ;; *) roster=null ;; esac
          roster_read=1
        fi
        verdict=$(printf "%s" "$story_json" | jq -r --argjson now "$now_s" --argjson roster "$roster" "$STORY_HAND_JQ" 2>/dev/null) || verdict=unreadable
      fi
      case "$verdict" in
        hand)      printf "%s\n" "$wid" ;;
        free|dead) ;;
        *)         echo "pool-probe: could not tell whether story $story of sling $wid is in hand (bd show or the session roster unreadable) - kept $wid" >&2 ;;
      esac
    done
  })
  out=$(printf "%s" "$cands" | jq -c --arg ids "$drop_ids" '($ids | split("\n") | map(select(length > 0))) as $drop | [.[] | select(.id as $i | $drop | index($i) == null)]' 2>/dev/null)
  # vazio/falhou/ilegível -> the unfiltered answer (the engine's own), said on stderr; never an empty list that reads as "no work"
  if [ -z "$out" ]; then
    echo "pool-probe: could not apply the sling filter - tier kept every candidate (ga-b97dgq)" >&2
    printf "%s" "$cands"; return 0
  fi
  printf "%s" "$out"
}


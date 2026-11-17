#!/bin/sh
# pool-probe-assigned.sh <1a|1b> — the dog's Steps 1a and 1b ("assigned work") as a versioned file.
# ga-ica007. Sibling of pool-probe.sh (Step 1c, ga-witezg); same stderr/exit-code contract.
#
#   sh pool-probe-assigned.sh 1a    assigned, in_progress  (crash recovery; alias: in_progress)
#   sh pool-probe-assigned.sh 1b    assigned, ready        (pre-assigned work; alias: ready)
#
# Why it exists. The engine renders each of these steps into the dog's prompt as a `sh -c '...'` whose
# every stage ends in `2>/dev/null`. When `bd` fails, or answers something that is not JSON, the stage
# yields nothing and the step prints `[]` with exit 0 and not a word on stderr: "I could not tell" and
# "the queue is empty" come out identical, and a dog that reads `[]` as "no work" drains and exits while
# a bead waits. Reproduced (ga-ica007): ONE raw 0x08 byte inside a string of an otherwise well-formed
# answer makes jq 1.8 refuse the whole document (exit 5) and the engine's text answers `[]`, rc 0. That is
# what hid every ephemeral wisp for the dog in ga-lxm9se (the writer of the 0x08 is fixed there; the
# reader is what this file fixes).
#
# Contract. The SAME probe as the engine's text (pool-probe-assigned.golden-1a.txt / -1b.txt, copied from
# `gc prime`): same bd calls (flags and order), same veto filter, same wo_pick, and the same STDOUT in every
# case (one JSON array of at most one bead, or `[]`) - except what is said below. The proof is
# pool-probe-assigned.selftest.sh, which runs the engine's text and this file against the same fixtures and
# compares stdout and the argv of every bd call. What it adds, without touching stdout:
#   * nothing found, and a tier whose bd call failed / whose answer was not JSON, or was JSON but not exactly ONE
#     array of objects ({}, null, an error envelope, two documents) / whose answer got lost between two stages
#                                           -> `[]`, a line on stderr naming the tier(s), exit 3
#   * something found after an earlier tier could not be read
#                                           -> the answer, a line on stderr (the head may be hidden), exit 0
#   * none of GC_SESSION_ID / GC_SESSION_NAME / GC_ALIAS set, or a bad <step>
#                                           -> `[]`, a line on stderr, exit 2 (nothing was probed)
# Anything on stderr (or a non-zero exit) means `[]` is NOT "no work": do not drain, tell the Mayor.
# (A `work-order WARN: wo_pick: ...` line is the engine's own and means only that the ordering library could
# not answer and the previous order was kept; the answer is still the engine's.)
#
# It is read-only (bd list/ready/query, jq): nothing in here removes anything.
# Usage from a dog session:  sh "$GC_CITY_PATH/packs/town-deltas/assets/scripts/pool-probe-assigned.sh" 1a

step="$1"
case "$step" in
  1a|in_progress) step=1a ;;
  1b|ready) step=1b ;;
  *)
    printf "[]"
    echo "pool-probe-assigned: bad <step> '$step' (usage: sh pool-probe-assigned.sh 1a|1b) - nothing was probed, so [] here does NOT mean there is no work" >&2
    exit 2 ;;
esac

if [ -z "$GC_SESSION_ID" ] && [ -z "$GC_SESSION_NAME" ] && [ -z "$GC_ALIAS" ]; then
  printf "[]"
  echo "pool-probe-assigned[$step]: GC_SESSION_ID, GC_SESSION_NAME and GC_ALIAS are all empty - no identity to look up, nothing was probed, so [] here does NOT mean there is no work" >&2
  exit 2
fi

# Tiers whose answer could not be read, e.g. " durable@dog-3 ephemeral@dog-3". `mark` records one.
unreadable=""
mark() { unreadable="$unreadable $1"; }

# The engine's ordering stage, verbatim in behaviour (config.go: workOrderPickFunctionScript): the survivors go through
# work-order.sh's `work_order_sort --age reclaim`, and the lib's answer is used only when it exited 0 AND printed exactly
# one array as long as the input; anything else is "cannot tell" -> a WARN on stderr and the survivors in their old order.
wo_pick() { wo_in=$(cat); case "$wo_in" in ""|"[]") printf "%s" "$wo_in"; return 0;; esac; wo_lib="${WORK_ORDER_LIB:-}"; if [ -z "$wo_lib" ]; then wo_root="${GC_CITY_PATH:-}"; [ -n "$wo_root" ] || wo_root="${GC_CITY:-}"; [ -n "$wo_root" ] && wo_lib="$wo_root/packs/town-deltas/assets/scripts/work-order.sh"; fi; wo_out=""; if [ -r "$wo_lib" ]; then wo_out=$(printf "%s" "$wo_in" | bash -c '. "$1" && work_order_sort --age reclaim' wo "$wo_lib"); wo_rc=$?; wo_n=$(printf "%s" "$wo_in" | jq 'length' 2>/dev/null); if [ "$wo_rc" -eq 0 ] && printf "%s" "$wo_out" | jq -es --argjson n "${wo_n:--1}" 'length == 1 and (.[0] | type == "array" and length == $n)' >/dev/null 2>&1; then printf "%s" "$wo_out"; return 0; fi; echo "work-order WARN: wo_pick: work_order_sort could not tell ($wo_lib); keeping the previous order" >&2; else echo "work-order WARN: wo_pick: work-order.sh not readable (WORK_ORDER_LIB, else GC_CITY_PATH/GC_CITY + packs/town-deltas/assets/scripts); keeping the previous order" >&2; fi; printf "%s" "$wo_in" | jq -c "${1:-.}" 2>/dev/null; }

# jq_stage <jq args...>: stdin through jq. rc 1 and NOTHING on stdout when jq failed OR answered nothing: an empty answer
# from a stage that is supposed to print a document is "could not tell", never an empty queue (the engine's `2>/dev/null |`
# turned both into `[]`). A real empty queue is the document `[]`, which this passes through.
jq_stage() {
  js_in=$(cat)
  js_out=$(printf "%s" "$js_in" | jq "$@" 2>/dev/null) || return 1
  [ -n "$js_out" ] || return 1
  printf "%s" "$js_out"
}

# take_head <label>: the veto filter, wo_pick and the head, on the raw bd answer in $raw. Sets r. rc 1 = could not tell
# (the tier is marked); rc 0 with r="[]" = a real empty tier; rc 0 with r=[bead] = found.
# $pre is an optional jq stage that runs before the veto filter (the ephemeral tiers' assignee select; it sees $id).
# vazio ("[]") -> empty tier, passes; falhou/ilegível (the shape guard below, or any jq stage that fails or prints nothing) -> tier marked, never the empty verdict
take_head() {
  th_label="$1"; r=""
  th_in="$raw"
  # vazio ([] = ONE array, no element) -> real empty tier, passes; falhou/ilegível (not exactly ONE JSON array of objects: {}, null, an object of objects, two documents, [null], prose) -> tier marked, never the empty verdict nor a "bead" cut from an error envelope
  printf "%s" "$th_in" | jq -es 'length == 1 and (.[0] | type == "array" and all(.[]; type == "object"))' >/dev/null 2>&1 || { mark "$th_label"; return 1; }
  if [ -n "$pre" ]; then
    th_in=$(printf "%s" "$th_in" | jq_stage --arg id "$id" "$pre") || { mark "$th_label"; return 1; }
  fi
  th_kept=$(printf "%s" "$th_in" | jq_stage -c --argjson now_ts "$(date +%s)" '[ .[] | select(((.labels // []) | map(select(startswith("pool:refused"))) | length) == 0) | select((((.labels // []) | map(select(. == "pilot:held" or startswith("pilot:held-until:"))) | length) == 0) or (((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber)) | if length > 0 then (max < $now_ts) else false end)) | select(((.labels // []) | map(select(. == "pilot:no-auto-dispatch")) | length) == 0) ]') || { mark "$th_label"; return 1; }
  r=$(printf "%s" "$th_kept" | wo_pick | jq -c '.[0:1]' 2>/dev/null)
  # the survivors were readable, so an empty answer here was lost between wo_pick and the head: could not tell, not "empty"
  [ -n "$r" ] || { mark "$th_label"; return 1; }
  return 0
}

# found <tier>: a non-empty head ends the probe, as in the engine (`printf "%s" "$r" && exit 0`).
found() {
  printf "%s" "$r"
  [ -n "$unreadable" ] && echo "pool-probe-assigned[$step]: found work, but earlier tier(s) could not be read:$unreadable - a higher-priority bead may be hidden; tell the Mayor" >&2
  exit 0
}

for id in "$GC_SESSION_ID" "$GC_SESSION_NAME" "$GC_ALIAS"; do
  [ -z "$id" ] && continue
  pre=""

  # ---- durable store ------------------------------------------------------------------------------------------------
  # vazio/falhou/ilegível -> "[]" = empty tier; bd failing or printing a non-document = tier marked unreadable
  if [ "$step" = 1a ]; then
    raw=$(bd list --status in_progress --assignee="$id" --json --limit 0 2>/dev/null) && [ -n "$raw" ]
  else
    raw=$(bd ready --assignee="$id" --json --limit 0 2>/dev/null) && [ -n "$raw" ]
  fi
  if [ $? -ne 0 ]; then mark "durable@$id"
  elif take_head "durable@$id"; then
    [ "$r" != "[]" ] && found
  fi

  # ---- ephemeral store (wisps) --------------------------------------------------------------------------------------
  # vazio/falhou/ilegível -> same as above; this is the answer the 0x08 byte used to turn into "no work" (ga-lxm9se)
  if [ "$step" = 1a ]; then
    raw=$(bd query --json 'ephemeral=true AND status=in_progress' --limit=0 2>/dev/null) && [ -n "$raw" ]
  else
    raw=$(bd query --json 'ephemeral=true AND status=open' --limit=0 2>/dev/null) && [ -n "$raw" ]
  fi
  if [ $? -ne 0 ]; then mark "ephemeral@$id"
  else
    if [ "$step" = 1a ]; then
      pre='[.[] | select((.assignee // "") == $id)]'
    else
      pre='[.[] | select((.assignee // "") == $id) | select(((.issue_type // .type // "") != "epic")) | select(([ (.dependencies // [])[] | select((.type // .dep_type // "") as $t | ($t == "blocks" or $t == "waits-for" or $t == "conditional-blocks")) | select((.status // .depends_on_status // "") != "closed") ] | length) == 0)] | sort_by(.created_at // "")'
    fi
    if take_head "ephemeral@$id"; then
      [ "$r" != "[]" ] && found
    fi
  fi
done

printf "[]"
if [ -n "$unreadable" ]; then
  echo "pool-probe-assigned[$step]: could not read:$unreadable (bd failed, its answer was not exactly one JSON array of objects, or a bead in it could not be filtered) - [] here does NOT mean there is no assigned work: do not drain, tell the Mayor" >&2
  exit 3
fi
exit 0

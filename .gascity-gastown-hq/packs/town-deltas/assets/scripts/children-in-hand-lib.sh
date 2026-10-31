#!/bin/sh
# children-in-hand-lib.sh — "this bead is a MOTHER whose work belongs to its children" (ga-vdac4cj). SOURCED by pool-probe.sh
# and by pilot-dispatcher.sh, never executed: it only defines variables and functions and has no side effect at source time
# (children-in-hand.selftest.sh sources it twice under set -euo pipefail).
#
# The incident. A feature sliced into children (E11: ga-hfx1kou -> .1/.2) keeps its OWN gate:queued while the slices hold the
# gate markers. grw FIX8 used to read that label as a phantom (no marker names the mother) and clear it; the mother then
# came back to the probe and the Pilot as a plain ready story, a session was spent on a bead with nothing left to build and
# refused it (pool:refused:delivered-awaiting-gate), and the same happened to WA umbrellas (wa-zmxywv.18/.19/.30). grw no longer
# clears it (gate-recovery-watchdog.py, children_marker_verdict); this lib is the second and third wall: neither the pool probe
# nor the Pilot offers a bead whose open children are in hand, whatever label state the mother ended up in.
#
# One definition, two readers. "In hand" is CHILDREN_STATES_JQ below; nothing else in the city decides it.
#   A child counts when it is NOT closed AND one of: its status is in_progress, or it carries a label that says the gate or a
#   delivery has it - story:in-flight, gate:queued, gate:reviewing, gate:passed, gate:needs-fix, gate:fix-attempt:N, delivery:*.
#   An open child that is merely ready (no such label, not in progress) is NOT in hand: nothing is building it and nothing
#   gates it, so its mother is not shielded by it (this lib does not turn every parent into "not a candidate").
#   A child of M is a row whose `.parent` is M, or whose dependencies carry a parent-child edge to M. Direct children only.
# Three states, never two (children_in_hand_states):
#   hand        at least one child is in hand                       -> the caller does NOT offer the mother
#   none        the children were READ and none is in hand (a bead with no children is this)
#                                                                    -> the mother stays a candidate, exactly as before
#   unreadable  bd failed, printed nothing, printed something that is not a JSON array of beads (or a row that is not an
#               object / has no id), or the verdict for the candidate is missing
#                                                                    -> the caller does NOT offer it either, and SAYS so:
#               inert and loud. This is deliberately the opposite of the sling filter (pool-probe-sling-lib.sh), which keeps
#               the candidate when it cannot tell: there a wrong "keep" costs one duplicate wisp, here it costs a session
#               spent on a mother with nothing to build, and the cause is a bd that is already failing.
#               Callers keep a candidate ONLY on an explicit `none`; any id without a verdict is treated as unreadable.
#
# How the children are found. NOT from the candidate's own row: measured 31/10, `dependent_count` in `bd ready` / `bd list` /
# `bd query` rows does not count parent-child links (it does in `bd show`): the real incident mother ga-hfx1kou is dependent_count
# 0 in every list row while `bd show` says 2, and across 8 real open parents 7 had 0 in the list row. A fast path keyed on that
# field would never have looked at a real mother (the first draft of this lib had one; it is gone). The candidate's row carries no
# children indicator at all, so the only way to know is to ask: ONE fresh `bd list --json --limit 0` per call (every not-closed
# bead of the store, default status filter: open, in_progress, blocked, deferred, hooked), grouped by `.parent` - measured 31/10
# to give exactly the counts `bd list --parent X` gives for every parent in the store (10/10), at one read instead of one per
# candidate (a probe tier holds up to 20). Never a cache: the answer decides whether a bead is offered to a builder. No candidate
# with an id -> no read at all, so an empty tier costs no bd call.

CHILDREN_BULK_VALID_JQ='type == "array" and all(.[]; type == "object" and (((.id // "") | tostring) != ""))'

# stdin: the store's not-closed beads (validated); --argjson ids: the candidate ids. Prints "<state>\t<id>" per id.
CHILDREN_STATES_JQ='def inhand:
    ((.status // "") != "closed")
    and ((.status // "") == "in_progress"
         or ((.labels // []) | any(.[]?; type == "string"
              and (. == "story:in-flight" or . == "gate:queued" or . == "gate:reviewing" or . == "gate:passed"
                   or . == "gate:needs-fix" or startswith("gate:fix-attempt:") or startswith("delivery:")))));
  def kidof($p):
    ((.parent // "") == $p)
    or ((.dependencies // []) | any(.[]?; type == "object" and ((.type // .dep_type // "") == "parent-child")
                                          and ((.depends_on_id // "") == $p)));
  . as $all
  | $ids[] | . as $id
  | ([ $all[] | select(kidof($id)) | select(inhand) ] | length) as $n
  | (if $n > 0 then "hand" else "none" end) + "\t" + $id'

CHILDREN_CANDIDATE_IDS_JQ='(if type == "array" then . else [] end)
  | [ .[] | select(type == "object") | (.id // "") | tostring | select(length > 0) ] | unique | .[]'

# children_candidate_ids - stdin: a JSON array of candidate beads; prints, one per line, the ids to look up.
# vazio/ilegível (stdin is not a JSON array) -> prints nothing: the caller goes on exactly as it would without this lib.
children_candidate_ids() {
  jq -r "$CHILDREN_CANDIDATE_IDS_JQ" 2>/dev/null
}

# children_in_hand_states [<db-dir>] - stdin: a JSON array of candidate beads; stdout: one line "<state>\t<id>" per candidate id
# (hand | none | unreadable), always rc 0 (the states ARE the answer). Prints nothing, and makes NO bd call, when no candidate has
# an id. With a db-dir the read goes to that store (`bd -C`), as the Pilot's per-rig stores need.
children_in_hand_states() {
  cs_db="${1:-}"
  cs_cands=$(cat)
  cs_ids=$(printf "%s" "$cs_cands" | jq -c "[ $CHILDREN_CANDIDATE_IDS_JQ ]" 2>/dev/null) || cs_ids=""
  # vazio/ilegível (no candidate, or stdin is not a JSON array) -> nothing to look up, nothing printed
  case "$cs_ids" in ("") return 0 ;; ("[]") return 0 ;; esac
  # falhou (bd rc != 0) / vazio (bd printed nothing) -> every candidate unreadable, never "no children"
  cs_all=""
  if [ -n "$cs_db" ]; then
    cs_all=$(bd -C "$cs_db" list --json --limit 0 2>/dev/null </dev/null) || cs_all=""
  else
    cs_all=$(bd list --json --limit 0 2>/dev/null </dev/null) || cs_all=""
  fi
  cs_out=""
  # ilegível (not JSON, not an array, a row that is not an object or has no id) -> unreadable; `[]` (a store with nothing in it) -> none
  if [ -n "$cs_all" ] && printf "%s" "$cs_all" | jq -e "$CHILDREN_BULK_VALID_JQ" >/dev/null 2>&1; then
    cs_out=$(printf "%s" "$cs_all" | jq -r --argjson ids "$cs_ids" "$CHILDREN_STATES_JQ" 2>/dev/null) || cs_out=""
  fi
  if [ -z "$cs_out" ]; then
    cs_out=$(printf "%s" "$cs_ids" | jq -r '.[] | "unreadable\t" + .' 2>/dev/null) || cs_out=""
  fi
  [ -z "$cs_out" ] || printf "%s\n" "$cs_out"
  return 0
}

# children_state_of <id> - stdin: the output of children_in_hand_states; prints the state of <id>: hand | none | unreadable.
# A missing line is unreadable (callers keep a candidate only on an explicit `none`).
children_state_of() {
  cso_v=$(awk -F '\t' -v id="${1:-}" '$2 == id && $2 != "" { print $1; exit }' 2>/dev/null)
  case "$cso_v" in
    (hand|none) printf "%s" "$cso_v" ;;
    (*) printf "unreadable" ;;
  esac
}

# drop_mothers_with_children_in_hand - the pool probe's filter. stdin: the JSON array of one tier's candidates; stdout: the
# array without the mothers whose children are in hand AND without those whose children could not be read; rc 1 (stdout still
# the filtered array) when at least one look-up was unreadable, so the caller can mark the tier unreadable (`|| mark N`) and the
# probe's exit-3 line says `[]` is not "no work". The two drops are told apart on purpose: a mother whose children are IN HAND is a
# real verdict ("nothing for you here"), so it goes to the pool-probe log only (pp_log, when it exists) and stdout `[]` stays a
# plain "drain" - the probe's contract reads ANY stderr line as "`[]` is not no-work"; a mother whose children could NOT BE READ
# is the could-not-tell case, so it is a line on stderr as well as in the log. A tier with no candidate costs no bd call; a tier
# with candidates costs exactly one (the bulk read).
# It must run BEFORE the oldest-pick: a mother that happens to be the oldest would otherwise empty the answer while legitimate
# work waits right behind it.
drop_mothers_with_children_in_hand() {
  dm_cands=$(cat)
  dm_ids=$(printf "%s" "$dm_cands" | children_candidate_ids)
  if [ -z "$dm_ids" ]; then printf "%s" "$dm_cands"; return 0; fi
  dm_verdicts=$(printf "%s" "$dm_cands" | children_in_hand_states "")
  dm_drop=""; dm_unread=""; dm_hand=""
  # every id looked up is either explicitly `none` (kept) or dropped; the case patterns carry a leading paren (bash 3.2 reads the
  # closing paren of an unparenthesized pattern as the end of a $( ) substitution; gate guard ga-7dx2vw)
  for dm_i in $dm_ids; do
    dm_s=$(printf "%s\n" "$dm_verdicts" | children_state_of "$dm_i")
    case "$dm_s" in
      (none) ;;
      (hand) dm_drop="$dm_drop
$dm_i"; dm_hand="$dm_hand $dm_i" ;;
      (*) dm_drop="$dm_drop
$dm_i"; dm_unread="$dm_unread $dm_i" ;;
    esac
  done
  for dm_i in $dm_hand; do
    # a real verdict, not a doubt: log only, never stderr (stderr would make the dog read `[]` as "not no-work" and refuse to drain)
    if type pp_log >/dev/null 2>&1; then pp_log "mother $dm_i not offered: its children are in hand (in progress, or held by the gate / a delivery; ga-vdac4cj)"; fi
  done
  for dm_i in $dm_unread; do
    echo "pool-probe: could not read the children of $dm_i - NOT offered (inert, not 'no work'; ga-vdac4cj)" >&2
    if type pp_log >/dev/null 2>&1; then pp_log "mother $dm_i not offered: its children could not be read (ga-vdac4cj)"; fi
  done
  dm_out=$(printf "%s" "$dm_cands" | jq -c --arg ids "$dm_drop" '($ids | split("\n") | map(select(length > 0))) as $drop | [.[] | select(.id as $i | $drop | index($i) == null)]' 2>/dev/null)
  # vazio/falhou/ilegível (the drop could not be applied) -> the tier answers NOTHING and is marked unreadable: never the
  # unfiltered list (that would offer the very mothers the look-ups said to hold back) and never a silent `[]`
  if [ -z "$dm_out" ]; then
    echo "pool-probe: could not apply the children filter - tier answers nothing (ga-vdac4cj)" >&2
    printf "[]"; return 1
  fi
  printf "%s" "$dm_out"
  [ -z "$dm_unread" ]
}

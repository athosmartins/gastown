#!/bin/sh
# pool-probe.sh <target> — the dog's Step 1c probe ("find routed pool work") as a versioned file.
# ga-witezg (P0); stderr/exit-code contract: ga-iu0ms2 (gate findings on ga-witezg).
#
# Why it is a file. The engine renders the probe into the dog's prompt as a ~5.5 KB `sh -c '...'`
# (internal/config/config.go: routedReadyTierCommand + probe_pool_demand). Claude Code's built-in
# "dangerous removal" check DENIES that command ("could not check the script for dangerous
# removals") although it contains no rm, and a pool session has nobody to approve the prompt: dog-1
# and dog-3 sat idle ~2h on 10/10 with three P0 routed to gastown.dog. Bisected the same day: no
# single construct trips it (the ${x#..}/${x%..} trims, the function, the while-read loop, size, the
# count of '\'' escapes, the count of $( ) — each passes alone); it reproduces on the real tier-1
# half and on a combined 1a+1b, so the trigger is the combination, which nobody controls. A short
# call to a file has no such combination: `sh <this file> gastown.dog`.
#
# Contract. The SAME probe: same bd calls (same flags, same order), same veto filter, same tiers, and
# the same STDOUT in every case (one JSON array of at most one bead, or `[]`). It is read-only (bd
# ready/list/query + jq): nothing in here removes anything. The proof is pool-probe.selftest.sh, which
# runs the engine's own text (pool-probe.golden-1c.txt) and this file against the same fixtures and
# compares stdout, the argv of every bd call and the exit code.
#
# Where it deliberately differs from the engine's probe: the engine's probe answers `[]` with exit 0
# and no word on stderr both for "nothing to pick up" and for "I could not tell" (bd failed, bd
# answered something that is not JSON, no <target>). A dog that reads `[]` as "no work" drains and
# exits while work waits. So, without touching stdout:
#   * no <target>                      -> `[]`, a line on stderr, exit 2 (nothing was probed)
#   * a tier whose bd call failed or whose answer is not JSON, and nothing found anywhere
#                                      -> `[]`, a line on stderr naming the tier(s), exit 3
#   * a molecule whose children could not be read (the bead is kept, as the engine does)
#                                      -> a line on stderr, the answer is unchanged
# Anything on stderr (or a non-zero exit) means `[]` is NOT "no work": do not drain, tell the Mayor.
#
# Drift. This is a snapshot of the live binary's probe (gc-1.1.1-engwin0919). When an engine window
# changes the probe (engine-window-0926 adds the next-action:* class — see pool-probe-vetoes.sh), the
# selftest's `--live` mode (compares the golden with what `gc prime` renders now) goes red: update the
# golden AND this file together, never one of them. Run it after every engine window
# (docs/runbooks/janela-manutencao-bd-e-engine.md, "Verificação").
#
# Usage: sh pool-probe.sh <target>        e.g. sh pool-probe.sh gastown.dog
# Like the original it prints nothing when GC_SESSION_ORIGIN is neither ephemeral nor empty.

case "$GC_SESSION_ORIGIN" in ephemeral|"") ;; *) exit 0 ;; esac

target="$1"
if [ -z "$target" ]; then
  printf "[]"
  echo "pool-probe: no <target> given (usage: sh pool-probe.sh <target>, e.g. gastown.dog) - nothing was probed, so [] here does NOT mean there is no work" >&2
  exit 2
fi

# Tiers whose answer could not be read, e.g. " 1 3". `mark N` records one without repeating it.
unreadable=""
mark() {
  case " $unreadable " in *" $1 "*) ;; *) unreadable="$unreadable $1" ;; esac
}

# The veto filter every tier ends with (the engine's poolDemandLabelFilterJQ). The engine pastes the
# same 655-byte program into all three tiers; it is one variable here. Prefix families (bd's
# --exclude-label is exact, so these cannot be flags), an unexpired pilot hold, EPIC-titled beads.
VETO_FILTER='[ .[] | select(((.labels // []) | map(select(startswith("pool:refused"))) | length) == 0) | select((((.labels // []) | map(select(. == "pilot:held" or startswith("pilot:held-until:"))) | length) == 0) or (((.labels // []) | map(select(startswith("pilot:held-until:")) | ltrimstr("pilot:held-until:") | tonumber)) | if length > 0 then (max < $now_ts) else false end)) | select(((.title // "") | test("^(EPIC|ÉPICO)[:\\s]"; "i")) | not) | select(((.labels // []) | map(select(startswith("blocked:") or startswith("blocked-reason:") or startswith("gate:needs-human") or startswith("pilot:refused-reason:") or startswith("pilot:text-veto"))) | length) == 0) ]'

# Tier 1, second half: stdin is the JSON array of routed ready beads; keep the ones whose molecule has
# no in-progress child (a bead with no molecule_id is always kept; an answer that is not proof of a
# live child keeps the bead too — and says so on stderr, so the fail-open is visible).
drop_molecules_in_flight() {
  cands=$(cat)
  keep_ids=$(printf "%s" "$cands" | jq -r '.[] | [.id, (.metadata["molecule_id"] // "")] | @tsv' 2>/dev/null | while IFS="$(printf '\t')" read -r cid mid; do
    [ -z "$cid" ] && continue
    if [ -z "$mid" ]; then printf "%s\n" "$cid"; continue; fi
    live=$(bd list --parent "$mid" --status in_progress --json --limit 1 2>/dev/null)
    live_rc=$?
    if [ "$live" = "[]" ]; then
      printf "%s\n" "$cid"
    elif [ -z "$live" ]; then
      echo "pool-probe: could not read the children of molecule $mid (bd exit $live_rc) - kept $cid" >&2
      printf "%s\n" "$cid"
    elif [ "${live#\[}" != "$live" ] && [ "${live%\]}" != "$live" ]; then
      :
    else
      echo "pool-probe: unreadable answer for the children of molecule $mid - kept $cid" >&2
      printf "%s\n" "$cid"
    fi
  done)
  printf "%s" "$cands" | jq -c --arg ids "$keep_ids" '($ids | split("\n") | map(select(length > 0))) as $keep | [.[] | select(.id as $i | $keep | index($i) != null)]' 2>/dev/null
}

# Print $1 and stop the whole probe when it holds a bead.
found() {
  [ -n "$1" ] && [ "$1" != "[]" ] && printf "%s" "$1" && exit 0
}

# Tier 1: unassigned beads routed to <target> (the exact --exclude-label list is the engine's
# bdReadyPoolDemandExcludeLabelArgs, in the engine's order), oldest first, then the veto filter,
# the molecule check, and the oldest-updated one.
t1_raw=$(bd ready --metadata-field "gc.routed_to=$target" --unassigned --exclude-type=epic \
  --exclude-label "story:needs-human" --exclude-label "needs-human" --exclude-label "ctx:thin" \
  --exclude-label "story:needs-approval" --exclude-label "story:epic" --exclude-label "needs:engine-window" \
  --exclude-label "pilot:no-auto-dispatch" --exclude-label "story:blocked" --exclude-label "delivery:partial" \
  --exclude-label "scope:needs-review" --exclude-label "exec:manual" --exclude-label "needs-human-decision" \
  --exclude-label "auto-refino:refining" --exclude-label "auto-refino:escalated" --exclude-label "refino:info-gap" \
  --exclude-label "refino:policy-gap" --exclude-label "story:unrefined" --exclude-label "story:refinement-in-progress" \
  --exclude-label "story:refino-review" --exclude-label "story:refino-escalado" --exclude-label "story:needs-device" \
  --exclude-label "on-device" --exclude-label "phone-proxy" --exclude-label "gate:queued" \
  --exclude-label "gate:reviewing" --json --sort oldest --limit=20 2>/dev/null) || mark 1
t1_kept=$(printf "%s" "$t1_raw" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null) || mark 1
r=$(printf "%s" "$t1_kept" | drop_molecules_in_flight | jq -c 'sort_by(.updated_at // .created_at // "") | .[0:1]' 2>/dev/null)
found "$r"

# Tier 2 (legacy): workflow beads that carry gc.run_target=<target> and no gc.routed_to.
legacy_candidates=$(bd ready --metadata-field "gc.run_target=$target" --metadata-field "gc.kind=workflow" --unassigned --exclude-type=epic --json --sort oldest --limit=20 2>/dev/null) || mark 2
t2_unrouted=$(printf "%s" "$legacy_candidates" | jq '[.[] | select((.metadata["gc.routed_to"] // "") == "")]' 2>/dev/null) || mark 2
r=$(printf "%s" "$t2_unrouted" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null | jq -c '.[0:1]' 2>/dev/null)
found "$r"

# Tier 3 (legacy, ephemeral store): open, unassigned, no open blocking dependency. As in the engine, a
# jq that fails leaves "[]" appended to whatever it printed.
t3_raw=$(bd query --json 'ephemeral=true AND status=open AND assignee=none' --limit=0 2>/dev/null) || mark 3
legacy_ephemeral_candidates=$(printf "%s" "$t3_raw" | jq --arg target "$target" '[.[] | select((.assignee // "") == "") | select(((.metadata["gc.routed_to"] // "") == $target) or (((.metadata["gc.routed_to"] // "") == "") and ((.metadata["gc.run_target"] // "") == $target) and ((.metadata["gc.kind"] // "") == "workflow"))) | select(((.issue_type // .type // "") != "epic")) | select(([ (.dependencies // [])[] | select((.type // .dep_type // "") as $t | ($t == "blocks" or $t == "waits-for" or $t == "conditional-blocks")) | select((.status // .depends_on_status // "") != "closed") ] | length) == 0)] | sort_by(.created_at // "") | .[:20]' 2>/dev/null) || { mark 3; legacy_ephemeral_candidates="$legacy_ephemeral_candidates[]"; }
r=$(printf "%s" "$legacy_ephemeral_candidates" | jq -c --argjson now_ts "$(date +%s)" "$VETO_FILTER" 2>/dev/null | jq -c '.[0:1]' 2>/dev/null)
found "$r"

printf "[]"
if [ -n "$unreadable" ]; then
  echo "pool-probe: tier(s)$unreadable unreadable (bd failed or answered something that is not JSON) and nothing was found - [] here does NOT mean there is no work" >&2
  exit 3
fi

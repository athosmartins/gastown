#!/usr/bin/env bash
# pool-probe-vetoes.sh — the ONE place that says which beads a pool worker's self-serve probe REFUSES.
# ga-aijm2v.5 (gate round 3, blocking 2). SOURCED, never executed: it only defines variables and
# functions, and has no side effect at source time (safe under the dispatcher's `set -euo pipefail`).
#
# Why it exists. Two consumers answer questions about "will a pool worker pick this bead up?", and
# each had grown its own private idea of the answer:
#   * nudge-on-route-gated.sh (wake suppression): "is this routed bead worth waking anyone for?"
#   * quality-gate-dispatcher.sh (gate FAIL path): "does the source bead come back to the pool by
#     itself, so the Mayor need not be paged?"
# The gate decided from FIVE facts (route, assignee, status, gate:queued, gate:reviewing) while the
# probe refuses a lot more — a bead labelled pilot:no-auto-dispatch / needs-human / pool:refused:* was
# judged "returns by itself" and the Mayor stayed asleep about a bead nothing could ever pick up.
# A decision made on a subset of the conditions the consumer applies is not the same decision.
#
# Two directions, one list. The SAME per-pool data answers both, but the safe error differs:
#   pool_veto_cfg all  = INTERSECTION of the pools (refused by EVERY pool). For wake suppression: a
#                        label only ONE pool refuses must not silence a wake another pool would act on.
#   pool_veto_cfg any  = UNION of the pools (refused by AT LEAST ONE). For "may I stay silent about
#                        this bead": a false page costs one Mayor wake (what happened before this
#                        story); a false silence strands a bead with nobody told.
#
# What is snapshotted, and where each snapshot comes from (read 2026-09-26, not remembered):
#   DOG     the gastown.dog probe = the engine's bdReadyPoolDemandExcludeLabelArgs (exact labels) +
#           poolDemandLabelFilterJQ (prefix families). The LIVE binary is gc-1.1.1-engwin0919.
#           engine-window-0926 (not yet swapped) adds the next-action:* class to it; when that ships,
#           set POOL_VETO_NEXT_ACTION_DOG=true here (the intersection then follows by itself).
#   WA      agents/wa-worker/prompt.template.md — and ps-worker's is identical (pool-probe-vetoes
#           .selftest.sh asserts both, from the tracked files, so this cannot drift silently).
# pilot:reclaim-count:<n> is a SORT key in the wa/ps probes, not a veto, so it is not listed.
# pilot:held / pilot:held-until:<epoch> is a veto only while the hold is unexpired; that is code
# (pool_held), not data, and lives in POOL_VETO_JQ_DEFS below.

# Exact-match label vetoes (bd's --exclude-label is exact).
POOL_VETO_EXACT_DOG='["auto-refino:escalated","auto-refino:refining","ctx:thin","delivery:partial","exec:manual","gate:queued","gate:reviewing","needs-human","needs-human-decision","needs:engine-window","on-device","phone-proxy","pilot:no-auto-dispatch","refino:info-gap","refino:policy-gap","scope:needs-review","story:blocked","story:epic","story:needs-approval","story:needs-device","story:needs-human","story:refinement-in-progress","story:refino-escalado","story:refino-review","story:unrefined"]'
POOL_VETO_EXACT_WA='["auto-refino:escalated","auto-refino:refining","ctx:thin","delivery:pending-restart","exec:manual","gate:queued","gate:reviewing","needs-human","needs-human-decision","needs:engine-window","on-device","phone-proxy","pilot:no-auto-dispatch","refino:info-gap","refino:policy-gap","story:blocked","story:epic","story:needs-approval","story:needs-device","story:needs-human","story:refinement-in-progress","story:refino-escalado","story:refino-review","story:unrefined"]'

# Prefix families (open-ended: the suffix carries the reason, so an exact exclude cannot list them).
POOL_VETO_PREFIX_DOG='["blocked-reason:","blocked:","gate:needs-human","pilot:refused-reason:","pilot:text-veto","pool:refused"]'
POOL_VETO_PREFIX_WA='["blocked:","gate:needs-human","pilot:refused-reason:","pilot:text-veto","pool:refused"]'

# next-action:<x> is a veto unless <x> ends in constroi / corrige-gate / corrige (refino's "ready, <crew>
# builds it" routing suffixes). Present in the wa/ps probes; the dog probe gets it with engine-window-0926.
POOL_VETO_NEXT_ACTION_DOG=false
POOL_VETO_NEXT_ACTION_WA=true

# jq definitions, to be PREPENDED to a jq program that runs on ONE bead object (an element of `bd show
# --json` or an event's payload.bead): `pool_veto_reasons($now; $cfg)` echoes an ARRAY of short reason
# strings — empty means nothing vetoes it. $cfg is the output of `pool_veto_cfg any|all`; $now is epoch.
POOL_VETO_JQ_DEFS='
def pool_held($now):
  ((.labels // []) | map(select(. == "pilot:held" or startswith("pilot:held-until:")))) as $h
  | if ($h | length) == 0 then false
    else ([ $h[] | select(startswith("pilot:held-until:"))
            | ltrimstr("pilot:held-until:") | (tonumber? // empty) ]) as $until
         # An expired held-until (max < now) releases the hold; a bare pilot:held, or a hold
         # with no parseable deadline, is a hold.
         | if ($until | length) > 0 then (($until | max) >= $now) else true end
    end;
def pool_veto_reasons($now; $cfg):
  (.labels // []) as $l
  | [ ( $l[] | select(. as $x | ($cfg.exact | index($x)) != null) | "label:" + . ),
      ( $l[] | . as $x | select(any($cfg.prefix[]; . as $p | $x | startswith($p))) | "prefix:" + $x ),
      ( if $cfg.next_action
        then ($l[] | select(test("^next-action:") and (test("(constroi|corrige-gate|corrige)$") | not)) | "next-action:" + ltrimstr("next-action:"))
        else empty end ),
      ( if ((.issue_type // .type // "") == "epic") then "type:epic" else empty end ),
      ( if ((.title // "") | test("^(EPIC|ÉPICO)[:\\s]"; "i")) then "title:epic" else empty end ),
      ( if pool_held($now) then "held" else empty end ) ];
'

# pool_veto_cfg any|all — prints the JSON config for pool_veto_reasons; non-zero + empty stdout when it
# cannot (bad mode, jq missing/failed). Callers MUST treat empty as "cannot tell", never as "no vetoes".
pool_veto_cfg() {
  jq -cn --arg mode "${1:-}" \
    --argjson de "$POOL_VETO_EXACT_DOG" --argjson we "$POOL_VETO_EXACT_WA" \
    --argjson dp "$POOL_VETO_PREFIX_DOG" --argjson wp "$POOL_VETO_PREFIX_WA" \
    --argjson dn "$POOL_VETO_NEXT_ACTION_DOG" --argjson wn "$POOL_VETO_NEXT_ACTION_WA" '
    if $mode == "any" then
      { exact: (($de + $we) | unique), prefix: (($dp + $wp) | unique), next_action: ($dn or $wn) }
    elif $mode == "all" then
      { exact: [ $de[] | select(. as $x | ($we | index($x)) != null) ],
        prefix: [ $dp[] | select(. as $x | ($wp | index($x)) != null) ],
        next_action: ($dn and $wn) }
    else error("pool_veto_cfg: mode must be any or all") end' 2>/dev/null
}

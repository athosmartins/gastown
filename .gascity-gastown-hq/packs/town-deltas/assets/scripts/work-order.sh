#!/usr/bin/env bash
# work-order.sh — the ONE place that says which bead a pipeline stage serves FIRST.
# ga-9t9acg.1 (programa ga-9t9acg; inventory + design: docs/research/ga-3zlzot-ordem-unica/inventario-e-desenho.md).
# SOURCED, never executed: it only defines variables and functions, and has no side effect at source
# time (safe under a dispatcher's `set -euo pipefail`; no bash-4-only syntax, so /bin/bash 3.2 works).
#
# The rule (Athos, 2026-10-06, programa ga-9t9acg): priority > type > age, on EVERY stage of the board.
# All P0 features, oldest first; then all P0 that are not features, oldest first; then P1 features,
# then the other P1s; and so on. It replaces the per-stage orders that grew here (newest-first in the
# Pilot and in auto-refino, priority-blind in the refino gate, ...).
#
# Why a library. Fourteen places each chose "which bead first" with an order of their own (R1..R14 in
# the inventory), so the panel's "position in the queue" and the real dispatch order could not agree.
# Every consumer calls THIS function. A consumer that re-implements the sort is the bug the registry
# lint (work-order.registry.tsv, checked by work-order.selftest.sh) exists to catch.
#
# The sort key, ascending:  [ priority class, type class, age (epoch seconds), id ]
#   priority class  0..4 -> itself. Anything else (missing, null, "2", 9, 1.5) -> 5, behind P4. WARN prio?
#   type class      feature|story -> 0 (WORK_ORDER_FEATURE_TYPES); any other type string -> 1;
#                   missing / empty / not a string -> 2, behind the known types WITHIN its priority. WARN type?
#                   The type is read from .issue_type, falling back to .type (the engine's probes read both).
#   age             oldest first. Unreadable -> the end of its class (epoch 9999999999). WARN age?
#                   Compared as epoch seconds, never as text: "…:05.123Z" and "…+00:00" sort wrong as strings.
#                   Accepted: a trailing Z or +00:00, with or without a fraction (the fraction is dropped,
#                   so two beads in the same second tie and the id decides). Any other shape is unreadable.
#   id              last tie-break, so the same beads in any input order give the same output.
#
# TWO age rules, chosen per call with --age; each consumer documents which one it uses and why:
#   created  (default) created_at.
#   field    the stage has its OWN entry marker (e.g. when the marker was submitted to the gate): the
#            caller injects it as the bead field `_wo_age` (ISO 8601). A bead without a readable one is
#            age-unreadable (WARN age?, end of class). There is NO fallback to created_at: a stage that
#            wants one injects it itself, so the choice stays visible at the call site.
#   reclaim  updated_at when the bead carries pilot:reclaim-count:<N> with N >= 1, created_at otherwise.
#            This keeps the anti-starvation of ga-w4k2z / ga-oc6knj (a bead reclaimed again and again must
#            not hold position 0 on its ancient created_at). It is INHERITED from those fixes — it is NOT
#            part of the Athos rule. A reclaimed bead with no updated_at is age-unreadable.
#
# THREE states, never collapsed into two:
#   1. read and ordered   array in -> array out, exit 0. `[]` in -> `[]` out, exit 0.
#   2. a field unreadable the bead STAYS in the output at the end of its class, and stderr gets one line per
#                         such bead: `work-order WARN: <id>: prio? type? age?` (only the failing fields).
#                         Never promoted to P0, never dropped.
#   3. cannot tell        stdin is not exactly one JSON array of objects, jq failed, bad option -> stdout
#                         EMPTY, exit 2, one `work-order ERROR:` line on stderr. Callers MUST treat empty as
#                         "I do not know": keep the previous order and log a visible WARN. Empty never
#                         means "no bead" (same contract as pool_veto_cfg in pool-probe-vetoes.sh).
#
# What a caller must still do itself:
#   * fetch the WHOLE population (`--limit 0` / `-n 0`) or prove the window covers it. Never `--limit=N`
#     before ordering: a P0 feature falls outside a window of 20 of the same priority (ga-g7yt: window
#     plus post-filter hides real work);
#   * across stores: UNION first, SORT once, then pick/cap — never "the first store that yields" (R9, R11);
#   * filtering and vetoes stay in the consumer (pool-probe-vetoes.sh and friends): this library only
#     orders, it never filters.

# Data. `story` is an alias of `feature` so a P0 story is never hidden behind a P0 bug (0 open today,
# measured 2026-10-06 in HQ and WA). Space-separated; an empty list is refused by work_order_cfg.
WORK_ORDER_FEATURE_TYPES="feature story"

# jq definitions, to be PREPENDED to a jq program. wo_prio_class / wo_type_class / wo_age / wo_key run on
# ONE bead object; wo_sort / wo_warn / wo_run run on the ARRAY. $o is the output of `work_order_cfg`.
WORK_ORDER_JQ_DEFS='
def wo_epoch($s):
  if ($s | type) != "string" then null
  else ($s | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")) as $t
       | (try ($t | fromdateiso8601) catch null)
  end;
def wo_prio_class:
  if (.priority | type) == "number" and .priority >= 0 and .priority <= 4 and (.priority | floor) == .priority
  then .priority else 5 end;
def wo_type_class($o):
  (.issue_type // .type) as $t
  | if ($t | type) != "string" or $t == "" then 2
    elif (($o.feature_types // ["feature", "story"]) | index($t)) != null then 0
    else 1 end;
def wo_type_class: wo_type_class({});
def wo_age_src($o):
  ($o.age // "created") as $a
  | if $a == "created" then .created_at
    elif $a == "field" then ._wo_age
    elif $a == "reclaim" then
      (.labels // []) as $l
      | if ($l | type) != "array" then null
        elif ($l | map(select(type == "string" and test("^pilot:reclaim-count:[1-9][0-9]*$"))) | length) > 0 then .updated_at
        else .created_at end
    else error("work-order: unknown age source: " + ($a | tostring)) end;
def wo_age($o): wo_epoch(wo_age_src($o));
def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, wo_type_class($o), ($e // 9999999999), (.id // "")];
def wo_sort($o): sort_by(wo_key($o));
def wo_warn($o):
  [ .[] | . as $b
    | [ (if wo_prio_class == 5 then "prio?" else empty end),
        (if wo_type_class($o) == 2 then "type?" else empty end),
        (if wo_age($o) == null then "age?" else empty end) ]
    | select(length > 0)
    | "work-order WARN: " + (($b.id // "?") | tostring) + ": " + join(" ") ];
def wo_run($o): wo_sort($o) as $s | { sorted: $s, warnings: ($s | wo_warn($o)) };
'

# work_order_cfg [--age created|field|reclaim] — prints the JSON options for the wo_* defs; exit 2 and
# EMPTY stdout when it cannot (bad option, empty feature list, jq missing/failed). Callers MUST treat
# empty as "cannot tell", never as a default.
work_order_cfg() {
  local age="created" out
  while [ $# -gt 0 ]; do
    case "$1" in
      --age)   if [ $# -lt 2 ]; then return 2; fi; age="$2"; shift 2 ;;
      --age=*) age="${1#--age=}"; shift ;;
      *)       return 2 ;;
    esac
  done
  if ! out="$(jq -cn --arg age "$age" --arg ft "$WORK_ORDER_FEATURE_TYPES" '
      ($ft | gsub("\\s+"; " ") | split(" ") | map(select(length > 0))) as $f
      | if ($age | IN("created", "field", "reclaim") | not) then error("age must be created, field or reclaim")
        elif ($f | length) == 0 then error("WORK_ORDER_FEATURE_TYPES is empty")
        else { age: $age, feature_types: $f } end' 2>/dev/null)" || [ -z "$out" ]; then
    return 2
  fi
  printf '%s\n' "$out"
}

# work_order_sort [--age created|field|reclaim] — stdin: ONE JSON array of bead objects (what
# `bd list/ready --json` prints); stdout: the same array, ordered; stderr: the WARN lines.
# Cannot tell -> stdout EMPTY, exit 2 (see the header). Nothing is printed until everything succeeded.
work_order_sort() {
  local cfg input res msg sorted warns
  if ! cfg="$(work_order_cfg "$@")" || [ -z "$cfg" ]; then
    echo "work-order ERROR: work_order_sort: bad option or config (usage: work_order_sort [--age created|field|reclaim]); cannot tell" >&2
    return 2
  fi
  input="$(cat)"
  if ! res="$(printf '%s' "$input" | jq -cs --argjson opts "$cfg" "$WORK_ORDER_JQ_DEFS"'
      if length != 1 then error("stdin must hold exactly one JSON document, got \(length)")
      else .[0] as $a
        | if ($a | type) != "array" then error("input is not a JSON array")
          elif ($a | all(type == "object") | not) then error("input has an element that is not an object")
          else $a | wo_run($opts) end
      end' 2>&1)" || [ -z "$res" ]; then
    msg="${res%%$'\n'*}"
    echo "work-order ERROR: work_order_sort: cannot tell (${msg:0:200}${msg:+; }input kept out of the order)" >&2
    return 2
  fi
  if ! sorted="$(printf '%s' "$res" | jq -c '.sorted' 2>/dev/null)" || [ -z "$sorted" ]; then
    echo "work-order ERROR: work_order_sort: cannot tell (could not read the ordered array back)" >&2
    return 2
  fi
  if ! warns="$(printf '%s' "$res" | jq -r '.warnings[]' 2>/dev/null)"; then
    echo "work-order ERROR: work_order_sort: cannot tell (could not read the warnings back)" >&2
    return 2
  fi
  if [ -n "$warns" ]; then printf '%s\n' "$warns" >&2; fi
  printf '%s\n' "$sorted"
}

# work_order_head — stdin: ONE JSON array (normally the output of work_order_sort); stdout: its first
# element, or the literal `null` for `[]`. Cannot tell (empty stdin, not exactly one array) -> stdout
# EMPTY, exit 2. This is what `jq '.[0]'` gets wrong: it prints `null` for `[]` AND prints nothing, with
# exit 0, for an empty stdin — so a failed upstream sort reads as "no bead".
work_order_head() {
  local input out
  input="$(cat)"
  if ! out="$(printf '%s' "$input" | jq -cs '
      if length != 1 then error("stdin must hold exactly one JSON document, got \(length)")
      elif (.[0] | type) != "array" then error("input is not a JSON array")
      else .[0][0] end' 2>/dev/null)" || [ -z "$out" ]; then
    echo "work-order ERROR: work_order_head: cannot tell (stdin is not exactly one JSON array)" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

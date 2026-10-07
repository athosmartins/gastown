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
# The sort key, ascending:  [ priority class, dano class, type class, age (epoch seconds), id ]
#   priority class  0..4 -> itself. Anything else (missing, null, "2", 9, 1.5) -> 5, behind P4. WARN prio?
#   dano class      THE one exception to "priority > type > age" (Athos, 2026-10-06, "Bug com dano ao vivo
#                   primeiro"; the gate has applied it since ga-emgkvn, this is the same rule for every other
#                   stage, ga-9t9acg.14). 0 for a P0 BUG that carries the label `impacto:dano-ao-vivo` (a customer
#                   is being hurt right now), 1 for everything else. So inside P0 the order is: dano bugs, then the
#                   features, then the rest, oldest first inside each — and P1 and below are untouched.
#                   It promotes only when ALL hold; any doubt leaves the bead where the plain rule puts it:
#                     * priority is exactly 0 (an invalid priority is already P-class 5, behind P4: never promoted);
#                     * .issue_type is exactly "bug" — no case folding, and NOT the `.type` fallback the type class
#                       uses: promoting ahead of every P0 feature is the costly direction, so it asks for the
#                       strict reading;
#                     * the label is exactly `impacto:dano-ao-vivo` (case and prefix do not count) in `.labels`.
#                   THREE states of the labels, never collapsed: has it / does not have it / cannot tell.
#                     has it        .labels is a list of strings and the label is in it            -> promotes
#                     does not      the list does not hold it, OR the `labels` key is absent (bd OMITS the key for
#                                   a bead with no label: measured 06/10, 22 of 162 beads, none with an empty array)
#                     cannot tell   .labels is there but is not a list of strings (null, a string, an object, a
#                                   list holding a non-string) -> treated as WITHOUT the label, and, on a P0 bug,
#                                   WARN labels?
#                   The label name is a constant in the jq below, not an env knob: a typo in an override would
#                   switch the exception off with no signal. The label on anything that is not a P0 bug is ignored
#                   (the gate says so in a NOTE line; a sort has no such channel, and one line per ignored bead
#                   on every call of every stage would only teach callers to drop stderr).
#   type class      feature|story -> 0 (WORK_ORDER_FEATURE_TYPES); any other type string -> 1;
#                   missing / empty / not a string -> 2, behind the known types WITHIN its priority. WARN type?
#                   The type is read from .issue_type, falling back to .type (the engine's probes read both).
#                   Case does not matter ("Feature" is a feature): the Pilot lowercases the type, so must this.
#   age             oldest first. Unreadable -> the end of its class (epoch 9999999999). WARN age?
#                   Compared as epoch seconds, never as text: "…:05.123Z" and "…+00:00" sort wrong as strings.
#                   Accepted: YYYY-MM-DDTHH:MM:SS, then an optional .digits fraction, then Z or +00:00 — and
#                   NOTHING else. The shape of the ORIGINAL string is judged first, anchored \A…\z (a jq/Oniguruma
#                   `$` also matches before a final newline); only then is the fraction dropped (so two beads in
#                   the same second tie and the id decides) and +00:00 read as Z. Any other shape is unreadable
#                   — a ".5" after the Z, a trailing newline, padding, a lowercase z, a fraction without digits —
#                   and so is a date the calendar does not have (2026-02-31, a 24:00 hour): it is not rolled over.
#                   (The check is on what the caller handed in, not on a rewritten copy of it: a validator that
#                   looks at its own output accepts whatever the rewrite made well-formed.)
#   id              last tie-break, so the same beads in any input order give the same output. A bead without a
#                   readable string id still stays in the output (id "" sorts first among exact ties) and gets
#                   WARN `id?` — it cannot be told apart from another one, which is worth hearing about.
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
#                         such bead: `work-order WARN: <id>: prio? type? age? labels? id?` (only the failing
#                         fields; `labels?` = a P0 BUG whose labels are not a list of strings: the bead was NOT
#                         promoted by the dano class and its position is the plain rule's. Said only for a P0 bug,
#                         the one bead the label could move — for any other bead the answer to "is this a dano
#                         bug?" is already no, there is nothing the caller cannot tell, and a line per malformed
#                         bead on every call of every stage would only teach callers to drop stderr).
#                         Never promoted to P0, never dropped. THE WARN LINES ARE THE ONLY SIGNAL: a caller must
#                         keep stderr (`2>>"$LOG"`), never `2>/dev/null` — the city's habit for bd calls would
#                         turn "illegible, kept at the end" into "silently misordered".
#   3. cannot tell        stdin is not exactly one JSON array of objects, jq failed, bad option -> stdout
#                         EMPTY, exit 2, one `work-order ERROR:` line on stderr. Callers MUST treat empty as
#                         "I do not know": keep the previous order and log a visible WARN. Empty never
#                         means "no bead" (same contract as pool_veto_cfg in pool-probe-vetoes.sh).
#
# NOT in this library, and decided (slice ga-9t9acg.2, the Pilot): the `tech-debt` tier. The old Pilot sort
# (_PILOT_SORT_JQ, `trank`) ranked a bead labelled `tech-debt`, or typed tech-debt, 1 inside its priority: after
# bug (0), before task/chore/feature. The Athos rule above has no such tier, and the Pilot was moved onto this key
# WITHOUT it: a tech-debt bead is "another type" (class 1) ranked by age, and a labelled one is not looked at.
# The label still picks the Pilot's sling TEMPLATE ("fix bug …", _bead_tier) — it never ordered anything again.
#
# What a caller must still do itself:
#   * fetch the WHOLE population (`--limit 0` / `-n 0`) or prove the window covers it. Never `--limit=N`
#     before ordering: a P0 feature falls outside a window of 20 of the same priority (ga-g7yt: window
#     plus post-filter hides real work);
#   * across stores: UNION first, SORT once, then pick/cap — never "the first store that yields" (R9, R11);
#   * filtering and vetoes stay in the consumer (pool-probe-vetoes.sh and friends): this library only
#     orders, it never filters.

# Data. `story` is an alias of `feature` so a P0 story is never hidden behind a P0 bug (0 open today,
# measured 2026-10-06 in HQ and WA). Space-separated, case-insensitive; an empty list is refused by
# work_order_cfg. Set only when UNSET: a caller or a test that exported its own list keeps it (and an EMPTY
# export stays empty, so it is refused — which is why this is `=` and not `:=`).
: "${WORK_ORDER_FEATURE_TYPES=feature story}"

# jq definitions, to be PREPENDED to a jq program. wo_prio_class / wo_type_class / wo_dano_class / wo_age /
# wo_key run on ONE bead object; wo_sort / wo_warn / wo_run run on the ARRAY. $o is the output of `work_order_cfg`.
WORK_ORDER_JQ_DEFS='
def wo_epoch($s):
  if ($s | type) != "string" then null
  else
    ([$s | capture("\\A(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\\.[0-9]+)?(?:Z|\\+00:00)\\z")] | .[0]) as $m
    | if $m == null then null
      else ($m.d + "Z") as $t
           | (try ($t | fromdateiso8601) catch null) as $e
           | if $e != null and (try ($e | todateiso8601) catch null) == $t then $e else null end
      end
  end;
def wo_prio_class:
  if (.priority | type) == "number" and .priority >= 0 and .priority <= 4 and (.priority | floor) == .priority
  then .priority else 5 end;
def wo_type_class($o):
  (.issue_type // .type) as $t
  | if ($t | type) != "string" or $t == "" then 2
    elif (($o.feature_types // ["feature", "story"]) | index($t | ascii_downcase)) != null then 0
    else 1 end;
def wo_type_class: wo_type_class({});
def wo_age_src($o):
  ($o.age // "created") as $a
  | if $a == "created" then .created_at
    elif $a == "field" then ._wo_age
    elif $a == "reclaim" then
      (.labels // []) as $l
      | if ($l | type) != "array" then null
        elif ($l | map(select(type == "string" and test("\\Apilot:reclaim-count:[1-9][0-9]*\\z"))) | length) > 0 then .updated_at
        else .created_at end
    else error("work-order: unknown age source: " + ($a | tostring)) end;
def wo_age($o): wo_epoch(wo_age_src($o));
# The verdict on the labels of ONE bead (ga-9t9acg.14, the same three values the gate gives in
# gate_src_class_read_store): "yes" = the labels were read and the label is among them; "no" = they were read
# and it is not, or the `labels` key is absent (bd omits it for a bead with none); "unreadable" = the key is
# there but is not a list of strings. `has` and not `// []`: a null `labels` is UNREADABLE, not "no".
def wo_dano_verdict:
  if has("labels") | not then "no"
  elif ((.labels | type) != "array") or ((.labels | all(type == "string")) | not) then "unreadable"
  elif (.labels | index("impacto:dano-ao-vivo")) != null then "yes"
  else "no" end;
# The only beads the label can move: a P0 bug. ONE definition, read by wo_dano_class (who is promoted) AND by
# wo_warn (whose unreadable labels are worth a line), so the two cannot disagree about who a candidate is.
# Priority through wo_prio_class so a priority that is not 0..4 (class 5) can never be a candidate.
def wo_dano_candidate: wo_prio_class == 0 and .issue_type == "bug";
# 0 only for a candidate whose verdict is "yes"; 1 for everything else (an unreadable verdict is NOT a promotion).
def wo_dano_class:
  if wo_dano_candidate and wo_dano_verdict == "yes" then 0 else 1 end;
def wo_key($o): (wo_age($o)) as $e | [wo_prio_class, wo_dano_class, wo_type_class($o), ($e // 9999999999), (.id // "")];
def wo_sort($o): sort_by(wo_key($o));
def wo_warn($o):
  [ .[] | . as $b
    | [ (if wo_prio_class == 5 then "prio?" else empty end),
        (if wo_type_class($o) == 2 then "type?" else empty end),
        (if wo_age($o) == null then "age?" else empty end),
        (if wo_dano_candidate and wo_dano_verdict == "unreadable" then "labels?" else empty end),
        (if (.id | type) != "string" or .id == "" then "id?" else empty end) ]
    | select(length > 0)
    | "work-order WARN: " + (($b.id // "?") | tostring) + ": " + join(" ") ];
def wo_run($o): wo_sort($o) as $s | { sorted: $s, warnings: ($s | wo_warn($o)) };
'

# work_order_cfg [--age created|field|reclaim] — prints the JSON options for the wo_* defs; exit 2 and
# EMPTY stdout when it cannot (bad option, empty feature list, jq missing/failed), with one
# `work-order ERROR:` line on stderr that says WHICH. Callers MUST treat empty as "cannot tell", never as
# a default.
work_order_cfg() {
  local age="created" out msg
  if ! command -v jq >/dev/null 2>&1; then
    echo "work-order ERROR: work_order_cfg: jq is not on PATH; cannot tell" >&2
    return 2
  fi
  while [ $# -gt 0 ]; do
    case "$1" in
      --age)   if [ $# -lt 2 ]; then echo "work-order ERROR: work_order_cfg: --age needs a value" >&2; return 2; fi; age="$2"; shift 2 ;;
      --age=*) age="${1#--age=}"; shift ;;
      *)       echo "work-order ERROR: work_order_cfg: unknown option: $1" >&2; return 2 ;;
    esac
  done
  if ! out="$(jq -cn --arg age "$age" --arg ft "$WORK_ORDER_FEATURE_TYPES" '
      ($ft | ascii_downcase | gsub("\\s+"; " ") | split(" ") | map(select(length > 0))) as $f
      | if ($age | IN("created", "field", "reclaim") | not) then error("age must be created, field or reclaim")
        elif ($f | length) == 0 then error("WORK_ORDER_FEATURE_TYPES is empty")
        else { age: $age, feature_types: $f } end' 2>&1)" || [ -z "$out" ]; then
    msg="${out%%$'\n'*}"
    echo "work-order ERROR: work_order_cfg: ${msg:0:200}; cannot tell" >&2
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
    echo "work-order ERROR: work_order_sort: no usable config (see the line above; usage: work_order_sort [--age created|field|reclaim]); cannot tell" >&2
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

# work_order_head — stdin: ONE JSON array of bead objects (normally the output of work_order_sort); stdout:
# its first element, or the literal `null` for `[]`. Cannot tell (empty stdin, not exactly one array, an
# element that is not an object — raw `bd --json` piped straight in must not read `[null, {...}]` as "the
# bead is null") -> stdout EMPTY, exit 2. This is what `jq '.[0]'` gets wrong: it prints `null` for `[]` AND prints nothing, with
# exit 0, for an empty stdin — so a failed upstream sort reads as "no bead".
work_order_head() {
  local input out msg
  input="$(cat)"
  if ! out="$(printf '%s' "$input" | jq -cs '
      if length != 1 then error("stdin must hold exactly one JSON document, got \(length)")
      elif (.[0] | type) != "array" then error("input is not a JSON array")
      elif (.[0] | all(type == "object") | not) then error("input has an element that is not an object")
      elif (.[0] | length) == 0 then null
      else .[0][0] end' 2>&1)" || [ -z "$out" ]; then
    msg="${out%%$'\n'*}"
    echo "work-order ERROR: work_order_head: cannot tell (${msg:0:200}${msg:+; }stdin is not exactly one JSON array of bead objects)" >&2
    return 2
  fi
  printf '%s\n' "$out"
}

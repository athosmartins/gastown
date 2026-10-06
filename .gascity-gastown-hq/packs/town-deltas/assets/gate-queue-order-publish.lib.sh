#!/bin/bash
# gate-queue-order-publish.lib.sh — the dispatcher PUBLISHES the queue order it computed (ga-dtecvq).
#
# Why this exists. gate-recovery-watchdog.py has to answer "is a queued marker invisible to the
# dispatcher?" (a marker whose gate_run was dropped in an outage, never selected again). Until
# ga-q8tj7p it inferred that from the dispatcher's CLAIM ORDER — "a newer marker was claimed while
# this older one was overdue" — which was only a proof while an overdue tier made the order
# priority-blind. The order is now priority > feature > age, so a newer P0 legitimately beats an
# older P3 for as long as P0s keep arriving, and no claim order proves anything.
#
# What the dispatcher can say instead is the thing it actually computed: for every sweep, the
# markers it ORDERED (with the class that placed each) and the ones it SET ASIDE (retry cooldown —
# the only thing the selection excludes). A queued marker that is in neither, sweep after sweep,
# is not "low priority" — the dispatcher never saw it. That is a fact about the input, so it holds
# whatever the order is, and it is the only thing the watchdog proves from this file.
#
# File format (JSON, one object, rewritten atomically each sweep):
#   {"v":1,"pubs":[{"at":<epoch>,"order":[{"id":"ga-x","class":"P0/feature"},...],"set_aside":["ga-y",...]},...]}
#   `pubs` is oldest-first and holds the last GATE_QUEUE_ORDER_KEEP sweeps (default 6), so a watchdog
#   that polls every 2 minutes still sees every sweep: the history lives HERE, not in its memory.
#
# What this file deliberately does not do:
#   - It is never written when the sweep exits before the order is computed (empty queue, quiet
#     hours, headroom gate). No publication is NOT "an empty order": the reader sees the newest
#     publication go stale and says "cannot prove", never "orphan".
#   - It never fails the sweep. A failed write returns non-zero and warns; the reader then sees a
#     stale or short history, which is the inert answer.
#   - A history that cannot be read back (corrupt, wrong version, clock stepped back) is DROPPED and
#     restarted from this sweep alone — a short history makes the reader abstain, a merged-over-garbage
#     one could make it assert.
#
# bash 3.2 (launchd's /bin/bash): no associative arrays, no mapfile, no ${var,,}.

# gate_publish_queue_order <markers_json> <order_json> <now_epoch>
#   markers_json  the queue the order was computed FROM (a JSON array; every element has .id)
#   order_json    the ordered result (a JSON array; each element has .id and .gate_order_class)
#   now_epoch     the sweep's own clock (the same one the order was computed at)
# Returns 0 on a successful publication, 1 otherwise (and warns when a `warn` function exists).
gate_publish_queue_order() {
  local markers="$1" order="$2" now="$3"
  local file="${GATE_QUEUE_ORDER_FILE:-${GC_CITY:-}/.gc/runtime/gate-queue-order.json}"
  local keep="${GATE_QUEUE_ORDER_KEEP:-6}"
  local pub prev next tmp dir

  case "$now" in ''|*[!0-9]*) _gqop_warn "no usable sweep clock ('$now') — nothing published"; return 1 ;; esac
  case "$keep" in ''|*[!0-9]*|??????*) keep=6 ;; esac
  keep=$((10#$keep))
  if [ "$keep" -lt 1 ]; then keep=6; fi
  case "$file" in ''|/.gc/*) _gqop_warn "no queue-order file path (GC_CITY unset?) — nothing published"; return 1 ;; esac

  pub=$(printf '%s\n' "$markers" | jq -c --argjson now "$now" --argjson order "$order" '
    ($order | map(.id)) as $oids
    | {at: $now,
       order: ($order | map({id: .id, class: (.gate_order_class // "")})),
       set_aside: ([.[] | .id | select(type == "string" and . != "") | select(. as $i | ($oids | index($i)) == null)] | unique)}' 2>/dev/null) || pub=""
  if [ -z "$pub" ]; then
    _gqop_warn "could not build the publication from the queue and its order — nothing published"
    return 1
  fi

  prev=""
  if [ -r "$file" ]; then prev=$(cat "$file" 2>/dev/null) || prev=""; fi
  next=$(printf '%s\n' "$prev" | jq -c --argjson pub "$pub" --argjson keep "$keep" --argjson now "$now" '
    (if (type == "object") and (.v == 1) and ((.pubs | type) == "array") then .pubs else [] end)
    | map(select((.at | type) == "number" and .at < $now)) as $h
    | {v: 1, pubs: (($h + [$pub]) | .[-$keep:])}' 2>/dev/null) || next=""
  if [ -z "$next" ]; then
    # The history could not be read back: restart from this sweep alone.
    next=$(printf '{"v":1,"pubs":[%s]}' "$pub")
  fi

  # `mv -f tmp dir` MOVES INTO the directory and succeeds — a "publication" nobody can read back.
  if [ -d "$file" ]; then _gqop_warn "$file is a directory — nothing published"; return 1; fi
  dir=$(dirname "$file")
  mkdir -p "$dir" 2>/dev/null || { _gqop_warn "cannot create $dir — nothing published"; return 1; }
  tmp="$file.tmp.$$"
  if printf '%s\n' "$next" > "$tmp" 2>/dev/null && mv -f "$tmp" "$file" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  _gqop_warn "could not write $file — the watchdog will see a stale or short history and abstain"
  return 1
}

_gqop_warn() {
  if type warn >/dev/null 2>&1; then warn "gate_publish_queue_order (ga-dtecvq): $*"; else echo "gate_publish_queue_order (ga-dtecvq): $*" >&2; fi
}

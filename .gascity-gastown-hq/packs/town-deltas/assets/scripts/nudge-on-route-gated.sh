#!/usr/bin/env bash
# nudge-on-route-gated — ga-aijm2v.5 (Camada 1 da portaria, regra 1).
#
# REPLACES the maintenance pack's `nudge-on-route` (city.toml `[orders] skip`
# switches the builtin off at EVERY scope; this order is city-scoped only, see
# nudge-on-route-gated.toml). Same job — wake a warm-idle pool worker when a
# bead is routed to its pool, because `gc sling` does not (issue #1129) — but
# it only wakes a session that can actually do something with the wake-up.
#
# Why the builtin was replaced (all measured 2026-09-25, load ~50-60 on 10 cores):
#   1. It ran on EVERY bead.updated and nudged EVERY active member of the target
#      pool for every routed bead it had not seen — including beads that were
#      already in_progress, assigned, closed or gated. In a 60 min sample of the
#      live stream, 45 routed events arrived and only ~23 were open+unassigned.
#   2. It nudged members that already hold in_progress work. A busy session
#      cannot claim a second bead; the nudge only costs it a turn re-reading its
#      whole context (~230k tokens for a dog, ~440k for the Mayor/crews).
#   3. It never finished. `gc session list` costs 4-5 s at this load and it ran
#      one per pair plus one `gc session nudge` per member, sequentially, so a
#      run blew the order timeout (order.failed 5m02s after order.fired). Its
#      dedup state is written ONCE at the very end, so a killed run persisted
#      nothing and the next run re-nudged the same pairs — 79 "check for assigned
#      work" items were pending in the queue (66 of them for dog-1..6).
#
# What this order does instead, in order of cost (cheapest filter first):
#   a. Reduce the recent stream to the LAST event per bead and classify it from
#      the payload alone (no gc/bd call): not routed / not open / assigned /
#      carries a not-ready label / already nudged. Only "actionable" survives.
#   b. Readiness: confirm the bead is in `bd ready` for its target (catches beads
#      still blocked by open dependencies). One bd call per (store,target) per run.
#   c. Members: `gc session list` once per target per run. Members that already
#      hold in_progress work (one bd call per store per run, wisps included) are
#      NOT nudged — a bead nobody idle can take waits for the pool's own
#      scale-up / next session start, which probes for work by itself.
#   d. Persist the dedup key after EACH successful nudge (not once at the end),
#      and stop starting new work once the wall-clock budget is spent.
#
# Three states are never collapsed: a lookup that FAILS is not "nobody is busy"
# and not "nothing is ready". When the readiness or holder lookup fails we fall
# back to the legacy behaviour (nudge) and count it, because suppressing a wake
# on a guess could starve a real bead, while a redundant wake only costs tokens.
#
# Measurement: every run appends ONE json line to
# $GNR_STATE_DIR/nudge-on-route-gated.jsonl with the routed pairs the legacy
# order would have nudged (`legacy_pairs`) next to what this order actually
# did (`gated_pairs`, `sessions_nudged`, `sessions_skipped_busy`, per-class
# suppression counts). That is the before/after for the story, from live traffic.
#
# Scope: only WARNINGS ("check for assigned work"). Work delivery (reviewer tasks,
# the Pilot's DISPATCH_TASK) never goes through this script.
#
# Usage:  nudge-on-route-gated.sh            run once (what the order does)
#         source nudge-on-route-gated.sh --lib   define the functions only (selftest)
set -uo pipefail

CITY="${GC_CITY:-.}"
# Event lookback. Wider than the builtin's 2m on purpose: the dedup key is
# persisted per nudge now, so re-reading an event is free, while a run that was
# skipped by the lock (or hit its budget) must still find its events next time.
GNR_LOOKBACK="${GNR_LOOKBACK:-5m}"
GNR_RETENTION="${GNR_RETENTION:-1h}"
GNR_MESSAGE="${GNR_MESSAGE:-check for assigned work}"
# Must stay well under the controller's exec-order timeout (5m observed).
GNR_BUDGET_S="${GNR_BUDGET_S:-200}"
GNR_CALL_TIMEOUT_S="${GNR_CALL_TIMEOUT_S:-45}"
GNR_STATE_DIR="${GNR_STATE_DIR:-${GC_PACK_STATE_DIR:-${GC_CITY_RUNTIME_DIR:-$CITY/.gc/runtime}/packs/town-deltas}}"
GNR_STATE_FILE="$GNR_STATE_DIR/nudge-on-route-gated-state.json"
GNR_RUNLOG="$GNR_STATE_DIR/nudge-on-route-gated.jsonl"
GNR_LOCK_DIR="$GNR_STATE_DIR/nudge-on-route-gated.lock.d"
GNR_RUNLOG_MAX_LINES="${GNR_RUNLOG_MAX_LINES:-3000}"

# Labels that mean "a pool worker will NOT pick this bead up". Deliberately the
# INTERSECTION of the dog, wa-worker and ps-worker routed-pool probes (verified
# against agents/wa-worker + agents/ps-worker prompt.template.md and the dog
# probe in the gastown.dog prompt on 2026-09-25) — a label only one pool
# excludes would suppress a wake another pool would have acted on. Prefix
# families (pool:refused*, pilot:held*) are handled in gnr_classify.
GNR_NOT_READY_LABELS='["auto-refino:escalated","auto-refino:refining","ctx:thin","exec:manual","gate:queued","gate:reviewing","needs-human","needs-human-decision","needs:engine-window","on-device","phone-proxy","pilot:no-auto-dispatch","refino:info-gap","refino:policy-gap","story:blocked","story:epic","story:needs-approval","story:needs-device","story:needs-human","story:refinement-in-progress","story:refino-escalado","story:refino-review","story:unrefined"]'

gnr_log() { printf 'nudge-on-route-gated: %s\n' "$*" >&2; }
gnr_now() { printf '%s' "${GNR_NOW:-$(date +%s)}"; }
gnr_iso() { date -u -r "$(gnr_now)" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ; }

# Simple Go-style duration (Ns/Nm/Nh) -> whole seconds.
gnr_duration_to_seconds() {
  case "$1" in
    *h) echo $(( ${1%h} * 3600 )) ;;
    *m) echo $(( ${1%m} * 60 )) ;;
    *s) echo "${1%s}" ;;
    *)  echo "$1" ;;
  esac
}

# Bound one external call. A wedged gc/bd must not eat the whole run budget.
gnr_run() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$GNR_CALL_TIMEOUT_S" "$@"
  else
    "$@"
  fi
}

# gnr_classify <state_json> <now_epoch>   (stdin: `gc events` output, one json per line)
# Pure function of its inputs — no gc/bd. Prints one TSV row per routed bead:
#   <class> <bead_id> <routed_to>
# class: not_open | assigned | not_ready | already_nudged | actionable
# The LAST event per bead wins (highest seq): an early "open" event must not
# resurrect a bead that a later event shows as in_progress.
gnr_classify() {
  jq -Rrn --argjson state "$1" --argjson now "$2" --argjson nr "$GNR_NOT_READY_LABELS" '
    def held($now):
      ((.labels // []) | map(select(. == "pilot:held" or startswith("pilot:held-until:")))) as $h
      | if ($h | length) == 0 then false
        else ([ $h[] | select(startswith("pilot:held-until:"))
                | ltrimstr("pilot:held-until:") | (tonumber? // empty) ]) as $until
             # An expired held-until (max < now) releases the hold; a bare
             # pilot:held, or a hold with no parseable deadline, is a hold.
             | if ($until | length) > 0 then (($until | max) >= $now) else true end
        end;
    def not_ready($now):
      (.labels // []) as $l
      | any($l[]; . as $x | ($nr | index($x)) != null or ($x | startswith("pool:refused")))
        or held($now);
    [ inputs | fromjson? | select(type == "object")
      | select((.payload.bead // null) != null and ((.payload.bead.id // "") != "")) ]
    | to_entries | map(.value + {_i: .key})
    | group_by(.payload.bead.id)
    | map(max_by([(.seq // 0), ._i]))
    | .[]
    | .payload.bead as $b
    | (($b.metadata // {})["gc.routed_to"] // "") as $t
    | select($t != "")
    | (if ($b.status // "") != "open" then "not_open"
       elif (($b.assignee // "") != "") then "assigned"
       elif ($b | not_ready($now)) then "not_ready"
       elif ($state | has($b.id + "|" + $t)) then "already_nudged"
       else "actionable" end) as $c
    | [$c, $b.id, $t] | @tsv'
}

# ── rig store resolution (local files only; `gc rig list` costs 8-17 s) ───────
# Prints "<prefix>\t<path>" for the HQ and every registered rig.
gnr_store_map() {
  printf 'ga\t%s\n' "$CITY"
  [ -r "$CITY/city.toml" ] && [ -r "$CITY/.gc/site.toml" ] || return 0
  awk -v site="$CITY/.gc/site.toml" '
    FILENAME == site {
      if ($0 ~ /^name *= *"/)  { n = $0; sub(/^name *= *"/, "", n); sub(/".*/, "", n) }
      if ($0 ~ /^path *= *"/ && n != "") { p = $0; sub(/^path *= *"/, "", p); sub(/".*/, "", p); path[n] = p }
      next
    }
    /^\[\[rigs\]\]/ { name = ""; next }
    /^name *= *"/   { name = $0; sub(/^name *= *"/, "", name); sub(/".*/, "", name); next }
    /^prefix *= *"/ { pre = $0; sub(/^prefix *= *"/, "", pre); sub(/".*/, "", pre)
                      if (name != "" && (name in path)) printf "%s\t%s\n", pre, path[name] }
  ' "$CITY/.gc/site.toml" "$CITY/city.toml"
}

# Sets GNR_STORE to the store dir for a bead id; returns 1 when the prefix is unknown.
gnr_store_for_bead() {
  GNR_STORE=""
  _pre="${1%%-*}"
  while IFS="$(printf '\t')" read -r _p _dir; do
    if [ "$_p" = "$_pre" ]; then GNR_STORE="$_dir"; return 0; fi
  done <<EOF
$GNR_STORE_MAP
EOF
  return 1
}

gnr_key() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# Each fetcher caches to a file under $GNR_RUN and returns 0 (ok) / 2 (lookup
# FAILED — never read as "empty"). Called as plain statements, never through
# $(...), so a memo can never die with a subshell.
gnr_fetch_members() {
  _f="$GNR_RUN/members.$(gnr_key "$1")"
  if [ -f "$_f.done" ]; then [ -f "$_f.fail" ] && return 2; return 0; fi
  : > "$_f.done"
  if _out="$(gnr_run gc --city "$CITY" session list --json --state active --template "$1" 2>/dev/null)" \
     && printf '%s' "$_out" | jq -e 'type == "object" and ((.sessions // null) | type) == "array"' >/dev/null 2>&1; then
    printf '%s' "$_out" | jq -c '[ .sessions[]
        | { name: (.name // .id),
            ids: ([.id, .name, .alias, .agent_name, .session_name] | map(select(. != null and . != ""))) } ]' > "$_f"
    return 0
  fi
  : > "$_f"; : > "$_f.fail"
  return 2
}

# Assignees of everything in_progress in a store, wisps included (a dog holding
# a formula wisp is busy even though no regular bead is assigned to it).
gnr_fetch_holders() {
  _f="$GNR_RUN/holders.$(gnr_key "$1")"
  if [ -f "$_f.done" ]; then [ -f "$_f.fail" ] && return 2; return 0; fi
  : > "$_f.done"
  if _out="$(gnr_run bd -C "$1" list --status in_progress --include-infra --json --limit 0 2>/dev/null)" \
     && printf '%s' "$_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$_out" | jq -c '[ .[] | .assignee // empty ] | unique' > "$_f"
    return 0
  fi
  echo '[]' > "$_f"; : > "$_f.fail"
  return 2
}

# Ids that are ready (open, unblocked, unassigned) and routed to <target>.
gnr_fetch_ready() {
  _f="$GNR_RUN/ready.$(gnr_key "$1|$2")"
  if [ -f "$_f.done" ]; then [ -f "$_f.fail" ] && return 2; return 0; fi
  : > "$_f.done"
  if _out="$(gnr_run bd -C "$1" ready --metadata-field "gc.routed_to=$2" --unassigned --exclude-type=epic --json --limit 0 2>/dev/null)" \
     && printf '%s' "$_out" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$_out" | jq -c '[ .[] | .id ]' > "$_f"
    return 0
  fi
  echo '[]' > "$_f"; : > "$_f.fail"
  return 2
}

# ── dedup state, persisted incrementally ─────────────────────────────────────
GNR_N_STATE_RESET=0; GNR_N_STATE_WRITE_FAILED=0
gnr_state_load() {
  GNR_STATE="$(cat "$GNR_STATE_FILE" 2>/dev/null || true)"
  if ! printf '%s' "$GNR_STATE" | jq -e 'type == "object"' >/dev/null 2>&1; then
    # Missing is normal on the first run; an EXISTING file that does not parse is not —
    # starting empty may re-nudge each pair once, so say so and count it.
    if [ -s "$GNR_STATE_FILE" ]; then
      GNR_N_STATE_RESET=$((GNR_N_STATE_RESET + 1))
      gnr_log "state file $GNR_STATE_FILE is unreadable — starting empty (each pair may be nudged once more)"
    fi
    GNR_STATE='{}'
  fi
}
gnr_state_write() {
  _tmp="$(mktemp "$GNR_STATE_DIR/.nudge-on-route-gated-state.XXXXXX")" || { GNR_N_STATE_WRITE_FAILED=$((GNR_N_STATE_WRITE_FAILED + 1)); return 1; }
  if printf '%s\n' "$GNR_STATE" > "$_tmp" && mv -f "$_tmp" "$GNR_STATE_FILE"; then return 0; fi
  # A state that could not be saved means the NEXT run re-nudges: never silent.
  GNR_N_STATE_WRITE_FAILED=$((GNR_N_STATE_WRITE_FAILED + 1))
  gnr_log "could not persist the dedup state to $GNR_STATE_FILE"
  rm -f "$_tmp" 2>/dev/null || true
  return 1
}

# A run that could not do its job leaves ONE line in the run log saying why, so
# "quiet" in the log always means "nothing to do" and never "could not look".
gnr_runlog_event() {
  jq -cn --arg ts "$(gnr_iso)" --arg what "$1" '{ts:$ts, not_run:$what}' >> "$GNR_RUNLOG" 2>/dev/null || true
}
# Record <key>=now and flush NOW — a run killed one nudge later must not forget it.
gnr_state_put() {
  GNR_STATE="$(printf '%s' "$GNR_STATE" | jq -c --arg k "$1" --arg now "$(gnr_iso)" '.[$k] = $now')"
  gnr_state_write
}
gnr_state_prune() {
  _keep="$(gnr_duration_to_seconds "$GNR_RETENTION")"
  _pruned="$(printf '%s' "$GNR_STATE" | jq -c --argjson keep "$_keep" --argjson now "$(gnr_now)" \
      'with_entries(select(($now - (.value | fromdateiso8601? // 0)) <= $keep))')" \
    && GNR_STATE="$_pruned"
}

# ── single-instance lock (mkdir is atomic; a stale lock is reclaimed) ─────────
gnr_lock() {
  if mkdir "$GNR_LOCK_DIR" 2>/dev/null; then echo $$ > "$GNR_LOCK_DIR/pid"; return 0; fi
  _pid="$(cat "$GNR_LOCK_DIR/pid" 2>/dev/null || true)"
  _age=$(( $(gnr_now) - $(stat -f %m "$GNR_LOCK_DIR" 2>/dev/null || echo 0) ))
  if { [ -n "$_pid" ] && ! kill -0 "$_pid" 2>/dev/null; } || [ "$_age" -gt $(( GNR_BUDGET_S + 120 )) ]; then
    rm -rf "$GNR_LOCK_DIR"
    if mkdir "$GNR_LOCK_DIR" 2>/dev/null; then echo $$ > "$GNR_LOCK_DIR/pid"; return 0; fi
  fi
  return 1
}
gnr_unlock() { rm -rf "$GNR_LOCK_DIR" 2>/dev/null || true; }

# Does <holders_json> mention any identity of a member? (member ids as json array)
gnr_member_busy() {
  printf '%s' "$2" | jq -e --argjson ids "$1" 'any(.[]; . as $h | $ids | index($h) != null)' >/dev/null 2>&1
}

# gnr_nudge_target <bead> <target> <store-or-empty>
# Nudges the IDLE members of the target pool (or the target itself when it has
# no members). Sets GNR_LAST_OUTCOME: nudged | all_busy | none_ok | lookup_failed.
# Counts land in GNR_N_* globals.
gnr_nudge_target() {
  _bead="$1"; _target="$2"; _store="$3"
  _holders='[]'; _holders_ok=0
  if [ -n "$_store" ]; then
    gnr_fetch_holders "$_store"; _hrc=$?
    if [ "$_hrc" -eq 0 ]; then _holders="$(cat "$GNR_RUN/holders.$(gnr_key "$_store")")"; _holders_ok=1
    else GNR_N_HOLDERS_UNKNOWN=$((GNR_N_HOLDERS_UNKNOWN + 1)); fi
  fi

  gnr_fetch_members "$_target"; _mrc=$?
  if [ "$_mrc" -ne 0 ]; then
    # Could not enumerate members: unknown, not "none". Legacy parity = try the
    # target name directly; record only on success.
    GNR_N_MEMBERS_FAILED=$((GNR_N_MEMBERS_FAILED + 1))
    if gnr_run gc --city "$CITY" session nudge "$_target" "$GNR_MESSAGE" >/dev/null 2>&1; then
      GNR_N_NUDGED=$((GNR_N_NUDGED + 1)); GNR_LAST_OUTCOME=nudged
    else GNR_LAST_OUTCOME=lookup_failed; fi
    return 0
  fi
  _members="$(cat "$GNR_RUN/members.$(gnr_key "$_target")")"

  if [ "$(printf '%s' "$_members" | jq 'length')" -eq 0 ]; then
    # A single-session agent (or an explicit slot name): nudge it directly,
    # unless it is itself already working.
    if [ "$_holders_ok" = "1" ] && gnr_member_busy "$(jq -cn --arg t "$_target" '[$t]')" "$_holders"; then
      GNR_N_SKIPPED_BUSY=$((GNR_N_SKIPPED_BUSY + 1)); GNR_LAST_OUTCOME=all_busy; return 0
    fi
    if gnr_run gc --city "$CITY" session nudge "$_target" "$GNR_MESSAGE" >/dev/null 2>&1; then
      GNR_N_NUDGED=$((GNR_N_NUDGED + 1)); GNR_LAST_OUTCOME=nudged
    else GNR_LAST_OUTCOME=none_ok; fi
    return 0
  fi

  _any_ok=0; _tried=0
  while IFS= read -r _m; do
    [ -n "$_m" ] || continue
    _name="$(printf '%s' "$_m" | jq -r '.name')"
    _ids="$(printf '%s' "$_m" | jq -c '.ids')"
    if [ "$_holders_ok" = "1" ] && gnr_member_busy "$_ids" "$_holders"; then
      GNR_N_SKIPPED_BUSY=$((GNR_N_SKIPPED_BUSY + 1)); continue
    fi
    _tried=$((_tried + 1))
    if gnr_run gc --city "$CITY" session nudge "$_name" "$GNR_MESSAGE" >/dev/null 2>&1; then
      _any_ok=1; GNR_N_NUDGED=$((GNR_N_NUDGED + 1))
    fi
  done <<EOF
$(printf '%s' "$_members" | jq -c '.[]')
EOF
  if [ "$_any_ok" = "1" ]; then GNR_LAST_OUTCOME=nudged
  elif [ "$_tried" -eq 0 ]; then GNR_LAST_OUTCOME=all_busy
  else GNR_LAST_OUTCOME=none_ok; fi
  return 0
}

gnr_main() {
  mkdir -p "$GNR_STATE_DIR" || exit 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "nudge-on-route-gated: jq is required but not found in PATH" >&2
    exit 1
  fi
  if ! gnr_lock; then
    gnr_log "another run holds the lock — skipping (events stay inside the ${GNR_LOOKBACK} lookback)"
    gnr_runlog_event lock_held
    exit 0
  fi
  GNR_RUN="$(mktemp -d "${TMPDIR:-/tmp}/nudge-on-route-gated.XXXXXX")" || { gnr_unlock; exit 0; }
  trap 'rm -rf "$GNR_RUN"; gnr_unlock' EXIT
  _t0="$(gnr_now)"

  # Best-effort: an unreadable stream (API down) must not crash the order loop.
  if ! _events="$(gnr_run gc --city "$CITY" events --type bead.updated --since "$GNR_LOOKBACK" 2>/dev/null)"; then
    gnr_runlog_event events_unreadable     # could not look — distinct from "no events"
    exit 0
  fi
  [ -n "$_events" ] || exit 0

  gnr_state_load
  GNR_STORE_MAP="$(gnr_store_map)"
  if ! _rows="$(printf '%s\n' "$_events" | gnr_classify "$GNR_STATE" "$(gnr_now)")"; then
    gnr_log "could not classify the event stream (jq failed) — nothing nudged this run"
    gnr_runlog_event classify_failed
    exit 0
  fi

  GNR_N_NUDGED=0; GNR_N_SKIPPED_BUSY=0; GNR_N_MEMBERS_FAILED=0; GNR_N_HOLDERS_UNKNOWN=0
  _c_routed=0; _c_not_open=0; _c_assigned=0; _c_not_ready=0; _c_already=0
  _c_actionable=0; _c_ready_unknown=0; _c_not_ready_deps=0; _c_all_busy=0
  _c_nudged_pairs=0; _c_none_ok=0; _c_deferred=0; _budget_hit=0

  # Pass 1: count + refresh already-nudged keys so a still-active routing is not
  # pruned and re-nudged while it keeps re-emitting bead.updated.
  while IFS="$(printf '\t')" read -r _class _bead _target; do
    [ -n "$_class" ] || continue
    _c_routed=$((_c_routed + 1))
    case "$_class" in
      not_open)       _c_not_open=$((_c_not_open + 1)) ;;
      assigned)       _c_assigned=$((_c_assigned + 1)) ;;
      not_ready)      _c_not_ready=$((_c_not_ready + 1)) ;;
      already_nudged) _c_already=$((_c_already + 1))
                      GNR_STATE="$(printf '%s' "$GNR_STATE" | jq -c --arg k "$_bead|$_target" --arg now "$(gnr_iso)" '.[$k] = $now')" ;;
      actionable)     _c_actionable=$((_c_actionable + 1)) ;;
    esac
  done <<EOF
$_rows
EOF
  gnr_state_write

  # Pass 2: the actionable beads, cheapest confirmations first.
  while IFS="$(printf '\t')" read -r _class _bead _target; do
    [ "$_class" = "actionable" ] || continue
    if [ $(( $(gnr_now) - _t0 )) -ge "$GNR_BUDGET_S" ]; then
      _budget_hit=1; _c_deferred=$((_c_deferred + 1)); continue
    fi
    _store=""
    if gnr_store_for_bead "$_bead"; then _store="$GNR_STORE"; fi

    # Readiness (dependencies, a claim that landed after the event). A FAILED
    # lookup is unknown, not "not ready": nudge as the legacy order would.
    if [ -n "$_store" ]; then
      gnr_fetch_ready "$_store" "$_target"; _rrc=$?
      if [ "$_rrc" -eq 0 ]; then
        if ! jq -e --arg id "$_bead" 'index($id) != null' "$GNR_RUN/ready.$(gnr_key "$_store|$_target")" >/dev/null 2>&1; then
          _c_not_ready_deps=$((_c_not_ready_deps + 1)); continue
        fi
      else
        _c_ready_unknown=$((_c_ready_unknown + 1))
      fi
    fi

    GNR_LAST_OUTCOME=""
    gnr_nudge_target "$_bead" "$_target" "$_store"
    case "$GNR_LAST_OUTCOME" in
      nudged)  _c_nudged_pairs=$((_c_nudged_pairs + 1)); gnr_state_put "$_bead|$_target" ;;
      # Everyone who could take it is already working: a wake would only cost
      # a turn. Remember the decision so a re-emitting event does not redo it.
      all_busy) _c_all_busy=$((_c_all_busy + 1)); gnr_state_put "$_bead|$_target" ;;
      *)       _c_none_ok=$((_c_none_ok + 1)) ;;   # failed: not recorded, retried next run
    esac
  done <<EOF
$_rows
EOF

  gnr_state_prune
  gnr_state_write

  _dur=$(( $(gnr_now) - _t0 ))
  # legacy_pairs = what the builtin would have nudged (every routed pair it had
  # not seen, whatever the bead's state), each to ALL members of the pool.
  _legacy=$(( _c_not_open + _c_assigned + _c_not_ready + _c_actionable ))
  jq -cn --arg ts "$(gnr_iso)" --argjson dur "$_dur" \
    --argjson routed "$_c_routed" --argjson legacy "$_legacy" \
    --argjson actionable "$_c_actionable" --argjson nudged_pairs "$_c_nudged_pairs" \
    --argjson sessions_nudged "$GNR_N_NUDGED" --argjson sessions_skipped_busy "$GNR_N_SKIPPED_BUSY" \
    --argjson not_open "$_c_not_open" --argjson assigned "$_c_assigned" \
    --argjson not_ready "$_c_not_ready" --argjson already "$_c_already" \
    --argjson not_ready_deps "$_c_not_ready_deps" --argjson all_busy "$_c_all_busy" \
    --argjson none_ok "$_c_none_ok" --argjson members_failed "$GNR_N_MEMBERS_FAILED" \
    --argjson holders_unknown "$GNR_N_HOLDERS_UNKNOWN" --argjson ready_unknown "$_c_ready_unknown" \
    --argjson deferred "$_c_deferred" --argjson budget_hit "$_budget_hit" \
    --argjson state_reset "$GNR_N_STATE_RESET" --argjson state_write_failed "$GNR_N_STATE_WRITE_FAILED" \
    '{ts:$ts, dur_s:$dur, routed_beads:$routed, legacy_pairs:$legacy, gated_pairs:$actionable,
      nudged_pairs:$nudged_pairs, sessions_nudged:$sessions_nudged, sessions_skipped_busy:$sessions_skipped_busy,
      suppressed:{not_open:$not_open, assigned:$assigned, not_ready_label:$not_ready, already_nudged:$already,
                  not_ready_deps:$not_ready_deps, all_busy:$all_busy},
      degraded:{none_ok:$none_ok, members_lookup_failed:$members_failed, holders_unknown:$holders_unknown,
                ready_unknown:$ready_unknown, deferred_over_budget:$deferred, budget_hit:$budget_hit,
                state_reset:$state_reset, state_write_failed:$state_write_failed}}' >> "$GNR_RUNLOG" 2>/dev/null || true
  # Keep the run log bounded.
  if [ "$(wc -l < "$GNR_RUNLOG" 2>/dev/null || echo 0)" -gt "$GNR_RUNLOG_MAX_LINES" ]; then
    tail -n "$(( GNR_RUNLOG_MAX_LINES / 2 ))" "$GNR_RUNLOG" > "$GNR_RUNLOG.tmp" 2>/dev/null && mv -f "$GNR_RUNLOG.tmp" "$GNR_RUNLOG"
  fi

  if [ "$GNR_N_NUDGED" -gt 0 ]; then
    echo "nudge-on-route-gated: nudged $GNR_N_NUDGED idle session(s) for $_c_nudged_pairs bead(s); skipped $GNR_N_SKIPPED_BUSY busy; suppressed $(( _c_not_open + _c_assigned + _c_not_ready + _c_not_ready_deps )) non-actionable"
  fi
}

# Library mode for the selftest: define the functions, run nothing.
if [ "${1:-}" != "--lib" ]; then
  gnr_main "$@"
fi

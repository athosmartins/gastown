#!/usr/bin/env bash
# nudge-on-route-gated.selftest.sh — ga-aijm2v.5 (rule 1).
#
# Black-box: runs the script with a FAKE `gc` and `bd` first in PATH (no live
# Dolt / city / network), records every `gc session nudge`, and asserts who was
# woken. Because it is black-box the SAME scenarios also run against the legacy
# maintenance builtin to prove they fail there:
#
#   GNR_SCRIPT_UNDER_TEST=<city>/.gc/system/packs/maintenance/assets/scripts/nudge-on-route.sh \
#     bash nudge-on-route-gated.selftest.sh        # legacy: expect FAILs (that is the defect)
#
# Sections that call the new script's own functions (--lib) only run against it.
# Exit 0 iff every assertion holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NEW_SCRIPT="$SELF_DIR/nudge-on-route-gated.sh"
SCRIPT="${GNR_SCRIPT_UNDER_TEST:-$NEW_SCRIPT}"
LEGACY=0; [ "$SCRIPT" != "$NEW_SCRIPT" ] && LEGACY=1

PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }

SBX="$(mktemp -d -t nudge-on-route-gated-selftest)" || { echo "FATAL: mktemp"; exit 1; }
trap 'rm -rf "$SBX"' EXIT
mkdir -p "$SBX/bin"

# ── fake gc ──────────────────────────────────────────────────────────────────
cat > "$SBX/bin/gc" <<'FAKE'
#!/usr/bin/env bash
FX="${GNR_FX:?}"
args=(); while [ $# -gt 0 ]; do case "$1" in --city) shift 2 ;; *) args+=("$1"); shift ;; esac; done
set -- "${args[@]}"
echo "gc $*" >> "$FX/gc-calls.log"
case "$1 $2" in
  "events "*) [ -f "$FX/events.fail" ] && exit 1; cat "$FX/events.jsonl" ;;
  "session list")
    tmpl=""; prev=""
    for a in "$@"; do [ "$prev" = "--template" ] && tmpl="$a"; prev="$a"; done
    if [ -f "$FX/members.fail" ]; then exit 1
    elif [ -f "$FX/members.$tmpl.json" ]; then cat "$FX/members.$tmpl.json"
    else echo '{"sessions":[]}'; fi ;;
  "session nudge")
    echo "$3" >> "$FX/nudges.log"
    # kill the script under test mid-run (simulates the exec-order timeout kill)
    if [ -f "$FX/kill-on.$3" ]; then kill -9 "$(cat "$FX/script.pid")" 2>/dev/null; sleep 1; fi
    exit 0 ;;
esac
exit 0
FAKE
# ── fake bd ──────────────────────────────────────────────────────────────────
cat > "$SBX/bin/bd" <<'FAKE'
#!/usr/bin/env bash
FX="${GNR_FX:?}"
[ "$1" = "-C" ] && shift 2
echo "bd $*" >> "$FX/bd-calls.log"
case "$1" in
  list)  [ -f "$FX/holders.fail" ] && exit 1; cat "$FX/inprogress.json" 2>/dev/null || echo '[]' ;;
  ready) [ -f "$FX/ready.fail" ] && exit 1; cat "$FX/ready.json" 2>/dev/null || echo '[]' ;;
esac
exit 0
FAKE
chmod +x "$SBX/bin/gc" "$SBX/bin/bd"

NOW="$(date +%s)"
PAST=$((NOW - 3600)); FUTURE=$((NOW + 3600))

# ev <seq> <id> <status> <assignee|-> <routed_to|-> <labels-json>
ev() {
  jq -cn --argjson seq "$1" --arg id "$2" --arg st "$3" --arg as "$4" --arg rt "$5" --argjson lb "$6" \
    '{seq:$seq, type:"bead.updated", actor:"cache-reconcile",
      payload:{bead:({id:$id, status:$st, labels:$lb,
                      metadata:(if $rt=="-" then {} else {"gc.routed_to":$rt} end)}
                     + (if $as=="-" then {} else {assignee:$as} end))}}'
}
ready_ids() {
  if [ "$#" -eq 0 ]; then echo '[]' > "$FX/ready.json"; return 0; fi
  printf '%s\n' "$@" | jq -R '{id: .}' | jq -cs '.' > "$FX/ready.json"
}
member() { jq -cn --arg n "$1" '{id:("id-"+$n), name:$n, alias:$n, agent_name:$n, session_name:$n, template:"x", state:"active"}'; }

# fresh sandbox for one scenario; sets FX/STATE and exports env
new_case() {
  FX="$SBX/fx.$1"; STATE="$SBX/state.$1"; mkdir -p "$FX" "$STATE"
  : > "$FX/events.jsonl"; : > "$FX/nudges.log"
  export GNR_FX="$FX" GC_CITY="$SBX/city" GC_PACK_STATE_DIR="$STATE" GNR_STATE_DIR="$STATE"
  export GNR_LOOKBACK=5m GNR_BUDGET_S=60 PATH="$SBX/bin:$PATH"
  mkdir -p "$SBX/city"
  # pool members for gastown.dog: dog-1 idle, dog-2 busy
  jq -cn --argjson a "$(member gastown.dog-1)" --argjson b "$(member gastown.dog-2)" '{ok:true,sessions:[$a,$b]}' > "$FX/members.gastown.dog.json"
  jq -cn --argjson a "$(member wa-worker-1)" '{ok:true,sessions:[$a]}' > "$FX/members.wa-worker.json"
  # dog-2 holds an in_progress bead (plus an ephemeral wisp assigned to someone else)
  echo '[{"id":"ga-work","assignee":"gastown.dog-2","status":"in_progress"},{"id":"ga-wisp-x","assignee":"other-session","ephemeral":true}]' > "$FX/inprogress.json"
  ready_ids
}
run_script() {
  # `$$` in a ( ) subshell is the PARENT's pid (BASHPID needs bash>=4), so take the
  # pid from a fresh `sh -c` that then exec's the script: same pid, killable on cue.
  sh -c 'echo $$ > "$1"; exec bash "$2"' _ "$FX/script.pid" "$SCRIPT" >/dev/null 2>>"$FX/stderr.log"
  [ -n "${GNR_DEBUG:-}" ] && { echo "    [stderr]"; sed 's/^/    | /' "$FX/stderr.log"; echo "    [gc]"; sed 's/^/    | /' "$FX/gc-calls.log" 2>/dev/null; echo "    [bd]"; sed 's/^/    | /' "$FX/bd-calls.log" 2>/dev/null; }
  return 0
}
nudged() { sort "$FX/nudges.log" | tr '\n' ' ' | sed 's/ $//'; }
count_nudges() { _c="$(grep -c . "$FX/nudges.log" 2>/dev/null)"; echo "${_c:-0}"; }
state_has() { cat "$STATE"/*state*.json 2>/dev/null | jq -e --arg k "$1" 'has($k)' >/dev/null 2>&1; }

echo "== 1. only an actionable bead wakes an idle member (not busy, not non-actionable beads)"
new_case c1
{
  ev 1 ga-r1      open        -            gastown.dog '[]'
  ev 2 ga-inprog  in_progress gastown.dog-2 gastown.dog '[]'
  ev 3 ga-closed  closed      -            gastown.dog '[]'
  ev 4 ga-assn    open        auto-refino  gastown.dog '[]'
  ev 5 ga-veto    open        -            gastown.dog '["pilot:no-auto-dispatch"]'
  ev 6 ga-noroute open        -            -           '[]'
} > "$FX/events.jsonl"
ready_ids ga-r1
run_script
eq "exactly one wake, to the IDLE member of the pool only" "$(nudged)" "gastown.dog-1"
if grep -q 'gastown.dog-2' "$FX/nudges.log"; then bad "busy member gastown.dog-2 (holds ga-work) was nudged"; else ok "busy member gastown.dog-2 was not nudged"; fi

echo "== 2. a re-run over the same events does not re-nudge (dedup persisted)"
: > "$FX/nudges.log"
run_script
eq "second run wakes nobody" "$(count_nudges)" "0"

echo "== 3. last event per bead wins (an old 'open' must not resurrect an in_progress bead)"
new_case c3
{ ev 1 ga-flip open - gastown.dog '[]'; ev 2 ga-flip in_progress gastown.dog-1 gastown.dog '[]'; } > "$FX/events.jsonl"
ready_ids ga-flip
run_script
eq "no wake for a bead whose latest event is in_progress" "$(count_nudges)" "0"

echo "== 4. held / expired-hold / refused labels"
new_case c4
{
  ev 1 ga-held-future open - gastown.dog "[\"pilot:held\",\"pilot:held-until:$FUTURE\"]"
  ev 2 ga-refused     open - gastown.dog '["pool:refused:engine-rebuild-required"]'
  ev 3 ga-hold-expired open - gastown.dog "[\"pilot:held\",\"pilot:held-until:$PAST\"]"
} > "$FX/events.jsonl"
ready_ids ga-held-future ga-refused ga-hold-expired
run_script
eq "only the bead whose hold EXPIRED is woken for (one idle member, one wake)" "$(nudged)" "gastown.dog-1"
state_has "ga-hold-expired|gastown.dog" && ok "expired-hold bead recorded" || bad "expired-hold bead not recorded"
state_has "ga-held-future|gastown.dog"  && bad "future-held bead was nudged/recorded" || ok "future-held bead untouched"
state_has "ga-refused|gastown.dog"      && bad "pool:refused bead was nudged/recorded" || ok "pool:refused bead untouched"

echo "== 5. a bead still blocked by dependencies (not in 'bd ready') is not woken for"
new_case c5
ev 1 ga-blocked open - gastown.dog '[]' > "$FX/events.jsonl"
ready_ids
run_script
eq "no wake for a not-ready bead" "$(count_nudges)" "0"

echo "== 6. unknown is not 'empty': failed holder/readiness lookups fall back to nudging (never suppress on a guess)"
new_case c6
ev 1 ga-r6 open - gastown.dog '[]' > "$FX/events.jsonl"
: > "$FX/holders.fail"; : > "$FX/ready.fail"
run_script
eq "with holders+ready lookups FAILED both members are woken (legacy behaviour)" "$(nudged)" "gastown.dog-1 gastown.dog-2"

echo "== 7. every member busy => no wake, but the decision is remembered"
new_case c7
ev 1 ga-r7 open - gastown.dog '[]' > "$FX/events.jsonl"
ready_ids ga-r7
echo '[{"id":"a","assignee":"gastown.dog-1"},{"id":"b","assignee":"gastown.dog-2"}]' > "$FX/inprogress.json"
run_script
eq "nobody idle => nobody woken" "$(count_nudges)" "0"
state_has "ga-r7|gastown.dog" && ok "all-busy decision recorded (no re-check storm)" || bad "all-busy decision not recorded"

echo "== 8. state is persisted per nudge: a run KILLED mid-way must not re-nudge finished pairs (the timeout defect)"
new_case c8
{ ev 1 ga-first open - gastown.dog '[]'; ev 2 ga-second open - wa-worker '[]'; } > "$FX/events.jsonl"
# the fake serves the same ready.json for any store, so both beads are ready
ready_ids ga-first ga-second
: > "$FX/kill-on.wa-worker-1"      # killing happens on the SECOND nudge
{ run_script; } 2>/dev/null   # the shell would otherwise print "Killed: 9" for the on-cue kill
first_nudges_run1="$(grep -c 'gastown.dog-1' "$FX/nudges.log" 2>/dev/null || echo 0)"
eq "run 1 woke the first pair before being killed" "$first_nudges_run1" "1"
rm -f "$FX/kill-on.wa-worker-1"; : > "$FX/nudges.log"
run_script
if grep -q 'gastown.dog-1' "$FX/nudges.log"; then bad "run 2 RE-NUDGED the pair run 1 had already finished (state lost when killed)"; else ok "run 2 did not re-nudge the finished pair"; fi

echo "== 9. wall-clock budget: past the budget nothing new is started, and nothing is recorded as done"
new_case c9
ev 1 ga-late open - gastown.dog '[]' > "$FX/events.jsonl"
ready_ids ga-late
GNR_BUDGET_S=0 run_script
eq "no wake once over budget" "$(count_nudges)" "0"
state_has "ga-late|gastown.dog" && bad "deferred bead was recorded as nudged" || ok "deferred bead left for the next run"

if [ "$LEGACY" = "0" ]; then
  echo "== 10. run log carries the before/after counters"
  new_case c10
  {
    ev 1 ga-a open - gastown.dog '[]'
    ev 2 ga-b in_progress gastown.dog-2 gastown.dog '[]'
    ev 3 ga-c closed - gastown.dog '[]'
  } > "$FX/events.jsonl"
  ready_ids ga-a
  run_script
  LINE="$(tail -1 "$STATE/nudge-on-route-gated.jsonl" 2>/dev/null)"
  eq "legacy_pairs (what the builtin would have nudged)" "$(echo "$LINE" | jq -r '.legacy_pairs')" "3"
  eq "gated_pairs (actionable)"                           "$(echo "$LINE" | jq -r '.gated_pairs')" "1"
  eq "sessions_nudged"                                    "$(echo "$LINE" | jq -r '.sessions_nudged')" "1"
  eq "sessions_skipped_busy"                              "$(echo "$LINE" | jq -r '.sessions_skipped_busy')" "1"
  eq "suppressed.not_open"                                "$(echo "$LINE" | jq -r '.suppressed.not_open')" "2"

  echo "== 12. a run that could not look says so: 'could not look' is never the same line as 'nothing to do'"
  new_case c12
  : > "$FX/events.fail"
  run_script
  eq "events unreadable => logged as not_run" "$(tail -1 "$STATE/nudge-on-route-gated.jsonl" 2>/dev/null | jq -r '.not_run')" "events_unreadable"
  new_case c12b        # no events at all is a legitimate quiet run: no not_run line
  run_script
  _nr="$(grep -c not_run "$STATE/nudge-on-route-gated.jsonl" 2>/dev/null)"
  eq "an empty event stream is NOT reported as a failure (no not_run line)" "${_nr:-0}" "0"

  echo "== 13. a corrupt dedup state does not stop the run, and is counted (may re-nudge once)"
  new_case c13
  ev 1 ga-a open - gastown.dog '[]' > "$FX/events.jsonl"; ready_ids ga-a
  echo 'not json {' > "$STATE/nudge-on-route-gated-state.json"
  run_script
  eq "still wakes the idle member" "$(nudged)" "gastown.dog-1"
  eq "state_reset counted in the run line" "$(tail -1 "$STATE/nudge-on-route-gated.jsonl" | jq -r '.degraded.state_reset')" "1"

  echo "== 14. a live lock held by another run: skipped, and logged as such"
  new_case c14
  ev 1 ga-a open - gastown.dog '[]' > "$FX/events.jsonl"; ready_ids ga-a
  sleep 30 & HOLDER=$!
  mkdir "$STATE/nudge-on-route-gated.lock.d"; echo "$HOLDER" > "$STATE/nudge-on-route-gated.lock.d/pid"
  run_script
  kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
  eq "nothing nudged while another run holds the lock" "$(count_nudges)" "0"
  eq "and the skip is logged" "$(tail -1 "$STATE/nudge-on-route-gated.jsonl" 2>/dev/null | jq -r '.not_run')" "lock_held"
  new_case c14b        # stale lock (dead pid) is reclaimed
  ev 1 ga-a open - gastown.dog '[]' > "$FX/events.jsonl"; ready_ids ga-a
  mkdir "$STATE/nudge-on-route-gated.lock.d"; echo 999999 > "$STATE/nudge-on-route-gated.lock.d/pid"
  run_script
  eq "a lock whose owner is dead is reclaimed and the run proceeds" "$(nudged)" "gastown.dog-1"

  echo "== 15. one malformed event must not take the window down with it (no poison pill), and is counted"
  new_case c15
  {
    printf '%s\n' '{"seq":1,"type":"bead.updated","payload":"this-should-be-an-object"}'
    printf '%s\n' '{"seq":2,"type":"bead.updated","payload":{"bead":{"id":"ga-bad","status":"open","metadata":"not-an-object"}}}'
    printf '%s\n' 'this line is not json at all'
    ev 3 ga-good open - gastown.dog '[]'
  } > "$FX/events.jsonl"
  ready_ids ga-good
  run_script
  eq "the valid actionable bead is still woken for" "$(nudged)" "gastown.dog-1"
  eq "the two unusable events are counted, not swallowed (non-json lines are just skipped)" "$(tail -1 "$STATE/nudge-on-route-gated.jsonl" | jq -r '.degraded.malformed_events')" "2"
  eq "and did not inflate the routed count" "$(tail -1 "$STATE/nudge-on-route-gated.jsonl" | jq -r '.routed_beads')" "1"

  echo "== 11. store map resolves prefixes from local files (no gc rig list)"
  # shellcheck disable=SC1090
  GC_CITY="$SBX/mapcity" source "$NEW_SCRIPT" --lib
  mkdir -p "$SBX/mapcity/.gc"
  printf '[[rigs]]\nname = "whatsapp_automation"\nprefix = "wa"\n[rigs.imports]\n[[rigs]]\nname = "lexbh"\nprefix = "lx"\n' > "$SBX/mapcity/city.toml"
  # the REAL shapes: city.toml declares [[rigs]] (name+prefix); .gc/site.toml declares [[rig]] (name+path), singular
  printf '[[rig]]\nname = "whatsapp_automation"\npath = "/x/wa"\n\n[[rig]]\nname = "lexbh"\npath = "/x/lx"\n' > "$SBX/mapcity/.gc/site.toml"
  CITY="$SBX/mapcity"; MAP="$(gnr_store_map)"; GNR_STORE_MAP="$MAP"
  gnr_store_for_bead wa-abc123 && eq "wa- prefix -> rig path" "$GNR_STORE" "/x/wa" || bad "wa- prefix not resolved"
  gnr_store_for_bead ga-zzz    && eq "ga- prefix -> HQ (city path)" "$GNR_STORE" "$SBX/mapcity" || bad "ga- prefix not resolved"
  gnr_store_for_bead qq-1      && bad "unknown prefix resolved to something" || ok "unknown prefix is unknown, not guessed"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed  (script under test: $SCRIPT)"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# pilot-dispatcher.release-owner.selftest.sh (ga-xxtwytk)
#
# ORIGIN: wa-lytych (P1), 13/11. The Pilot's NEVERSTARTED release (_neverstarted_recover_db) and the Stage 1.5
# crew-stale reclaim (_pilot_crew_stale_reclaim) both ended with `bd assign <id> "" -q 2>/dev/null || true`, AFTER
# they had already taken the flight labels off. Since bd-98s5c, bd 1.1.0 REFUSES `assign <id> ""` while the bead is
# another actor's live in_progress claim (the Pilot is a different actor than the builder holding it), and the
# refusal was swallowed: the bead stayed in_progress with the dead builder as owner and WITHOUT story:in-flight /
# pilot:dispatched, the labels the NEVERSTARTED query and the guard's stranded-in_progress scan select on (wa-lytych
# sat from 01:53Z until the witness found it by hand). Events of the incident, per the bead: only label_removed + 2
# metadata unsets, no assignee change.
#
# FIX under test: _pilot_release_owner <db> <bead> <judged owner> clears the owner FIRST, with ONE guarded write
# (`bd update --if-assignee <owner> --if-status <status> --assignee "" [--status open]`, the compare-and-swap that
# gate_clear_assignee_if_holder (ga-yd8t6) uses instead of --force) and CONFIRMS it by reading the bead back; only rc 0 lets the caller take the flight
# labels and stamps off. Any other outcome leaves the bead exactly as it was (flight labels and stamps in place, so
# it stays visible and the next sweep retries) and says so loudly. THE invariant, asserted after every scenario:
# a bead whose owner is still set never ends up without its flight labels ("sem rotulo + dono morto").
#
# The fake bd models bd 1.1.0 as far as the repo documents it (gate-assignee-clear-holder-aware.selftest.sh, the
# `bd assign` refusal of bd-98s5c; gate_clear_assignee_if_holder reads rc 13 as a lost compare-and-swap):
# `assign <id> ""` is refused for another actor's in_progress claim (no --force); `update --if-assignee/--if-status`
# is a compare-and-swap (rc 13 on a mismatch). It was NOT checked against a live bd here (no bd on this node). Its failure
# modes (RO_SHOW_MODE / RO_UPDATE_MODE / RO_LABEL_MODE) inject exactly the third states the fix has to survive:
# a read that fails, comes back empty or garbled, a write that is refused, that "succeeds" without landing, that
# loses a race to a new claimant, a read that dies after the write.
#
# Runs the REAL functions cut out of pilot-dispatcher.sh with sed (same idiom as the sibling selftests); every other
# dependency is stubbed; no live bd/gc/Dolt/git. Against the pre-fix dispatcher the incident scenarios fail with
# the incident's own end state (owner still set, flight labels gone).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="$SELF_DIR/pilot-dispatcher.sh"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-release-owner.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

extract_fn() { sed -n "/^$1() {/,/^}\$/p" "$DISPATCHER"; }
NS_FN="$(extract_fn _neverstarted_recover_db)"
LBL_FN="$(extract_fn _ns_label_blocks_release)"
CS_FN="$(extract_fn _pilot_crew_stale_reclaim)"
for _f in NS_FN LBL_FN CS_FN; do
  [ -n "${!_f}" ] || { echo "FATAL: could not cut $_f out of $DISPATCHER (extraction pattern drifted)" >&2; exit 2; }
done
# Empty on a pre-fix dispatcher: the two functions above are then the old ones, which never call it.
REL_FN="$(extract_fn _pilot_owner_state)
$(extract_fn _pilot_release_owner)"

NOW=1794542500
STAMP=$((NOW - 3600))   # dispatched an hour ago: past PILOT_NEVERSTARTED_MINUTES=15

# ── the fake bd ──────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/bd" <<'FAKE'
#!/usr/bin/env bash
# fake bd (bd 1.1.0 model). World = $RO_WORLD/world.json: {"<id>": {status, assignee, labels[], metadata{}}}.
# list_assignee / list_status on a bead = what `list` reports while the world already moved on (a change after the list).
W="${RO_WORLD:?}"; WJ="$W/world.json"
echo "$*" >> "$W/calls.log"
[ "${1:-}" = "-C" ] && shift 2
cmd="${1:-}"; [ $# -gt 0 ] && shift
wj_set() { jq "$@" "$WJ" > "$WJ.tmp" && mv "$WJ.tmp" "$WJ"; }
cur_of() { jq -r --arg id "$1" '.[$id].assignee // ""' "$WJ"; }
st_of()  { jq -r --arg id "$1" '.[$id].status // ""' "$WJ"; }
case "$cmd" in
  show)
    id="$1"
    case "${RO_SHOW_MODE:-ok}" in
      fail) echo "Error: dolt unavailable" >&2; exit 1 ;;
      empty) exit 0 ;;
      garbage) echo "this is not json"; exit 0 ;;
      nostatus) jq -c --arg id "$id" '[{id:$id}]' "$WJ"; exit 0 ;;
      rc1_valid) jq -c --arg id "$id" '[ .[$id] + {id:$id} | del(.list_assignee, .list_status) ]' "$WJ"; exit 1 ;;
      fail_after_update) [ -e "$W/updated" ] && { echo "Error: dolt unavailable" >&2; exit 1; } ;;
    esac
    jq -c --arg id "$id" 'if has($id) then [ .[$id] + {id:$id} | del(.list_assignee, .list_status) | if .assignee == "" then del(.assignee) else . end ] else [] end' "$WJ" ;;
  list)
    want=""
    while [ $# -gt 0 ]; do [ "$1" = "-l" ] && { want="$want $2"; shift; }; shift; done
    jq -c --arg want "$want" '($want | split(" ") | map(select(length > 0))) as $w
      | [ to_entries[] | select((.value.list_status // .value.status) != "closed")
          | select(.value.labels as $l | all($w[]; . as $x | $l | index($x) != null))
          | .value + {id: .key}
          | (if .list_assignee != null then .assignee = .list_assignee else . end)
          | (if .list_status != null then .status = .list_status else . end)
          | del(.list_assignee, .list_status) | if .assignee == "" then del(.assignee) else . end ]' "$WJ" ;;
  label)
    sub="$1"; id="$2"; lab="$3"
    [ "${RO_LABEL_MODE:-ok}" = fail ] && [ "$sub" = remove ] && { echo "Error: label write failed" >&2; exit 1; }
    case "$sub" in
      remove) wj_set --arg id "$id" --arg l "$lab" '.[$id].labels -= [$l]' ;;
      add)    wj_set --arg id "$id" --arg l "$lab" '.[$id].labels += [$l]' ;;
    esac ;;
  assign)
    id="$1"; name="${2-}"; force=0
    for a in "$@"; do [ "$a" = "--force" ] && force=1; done
    cur="$(cur_of "$id")"
    if [ "$(st_of "$id")" = in_progress ] && [ -n "$cur" ] && [ "$cur" != "$name" ] && [ "$force" = 0 ]; then
      echo "Error: refusing to overwrite another actor's live in_progress claim on $id (held by $cur); use --force (bd-98s5c)" >&2
      exit 1
    fi
    wj_set --arg id "$id" --arg n "$name" '.[$id].assignee = $n' ;;
  update)
    id="$1"; shift
    ifa=""; has_ifa=0; ifs=""; has_ifs=0; newa=""; has_newa=0; news=""; has_news=0; unsetm=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --if-assignee) ifa="$2"; has_ifa=1; shift ;;
        --if-status)   ifs="$2"; has_ifs=1; shift ;;
        --assignee|-a) newa="$2"; has_newa=1; shift ;;
        --status)      news="$2"; has_news=1; shift ;;
        --unset-metadata) unsetm="$unsetm $2"; shift ;;
        --set-metadata) k="${2%%=*}"; v="${2#*=}"; wj_set --arg id "$id" --arg k "$k" --arg v "$v" '.[$id].metadata[$k] = $v'; shift ;;
      esac
      shift
    done
    cur="$(cur_of "$id")"; st="$(st_of "$id")"
    if [ "$has_newa" = 1 ]; then   # the failure modes only touch the owner-clearing write
      case "${RO_UPDATE_MODE:-ok}" in
        refuse) echo "Error: update refused" >&2; exit 1 ;;
        lie)    exit 0 ;;
        ignore_status) has_news=0 ;;
        race:*) cur="${RO_UPDATE_MODE#race:}"; wj_set --arg id "$id" --arg n "$cur" '.[$id].assignee = $n' ;;
        closerace) st=closed; wj_set --arg id "$id" '.[$id].status = "closed"' ;;
      esac
    fi
    [ "$has_ifa" = 1 ] && [ "$cur" != "$ifa" ] && { echo "Error: --if-assignee mismatch (held by '$cur')" >&2; exit 13; }
    [ "$has_ifs" = 1 ] && [ "$st"  != "$ifs" ] && { echo "Error: --if-status mismatch (is '$st')" >&2; exit 13; }
    [ "$has_newa" = 1 ] && { wj_set --arg id "$id" --arg n "$newa" '.[$id].assignee = $n'; : > "$W/updated"; }
    [ "$has_news" = 1 ] && wj_set --arg id "$id" --arg s "$news" '.[$id].status = $s'
    for k in $unsetm; do wj_set --arg id "$id" --arg k "$k" 'del(.[$id].metadata[$k])'; done
    exit 0 ;;
  close) wj_set --arg id "$1" '.[$id].status = "closed"' ;;
  *) echo "fake bd: unexpected command: $cmd $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$WORK/bin/bd"

# ── world helpers ────────────────────────────────────────────────────────────
new_world() {   # $1 = name
  W="$WORK/w.$1"; mkdir -p "$W"
  echo '{}' > "$W/world.json"; : > "$W/calls.log"; : > "$W/warn.log"; rm -f "$W/updated"
  export RO_WORLD="$W"
  unset RO_SHOW_MODE RO_UPDATE_MODE RO_LABEL_MODE
}
add_bead() {    # id status assignee "label label" [sling bead id]
  jq --arg id "$1" --arg st "$2" --arg a "$3" --arg l "$4" --arg s "${5:-}" --argjson stamp "$STAMP" \
    '.[$id] = {status:$st, assignee:$a, labels:($l | split(" ") | map(select(length > 0))),
               metadata:({"pilot.dispatched_at":($stamp|tostring), "gc.session_name":"dog-dead"} + (if $s != "" then {"pilot.sling_bead":$s} else {} end))}' \
    "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
}
w_get() { jq -r --arg id "$1" ".[\$id] | $2" "$W/world.json"; }
owner_of()  { w_get "$1" '.assignee // ""'; }
status_of() { w_get "$1" '.status'; }
flight_n()  { w_get "$1" '[.labels[] | select(. == "story:in-flight" or . == "pilot:dispatched" or . == "pilot:dispatching")] | length'; }
has_meta()  { [ "$(w_get "$1" ".metadata | has(\"$2\")")" = true ]; }
calls_have() { grep -qF -- "$1" "$W/calls.log"; }
warn_have()  { grep -qF -- "$1" "$W/warn.log"; }
# THE invariant: an owner that is still set must not be left without the flight labels.
no_limbo() { [ -z "$(owner_of "$1")" ] || [ "$(flight_n "$1")" != 0 ]; }

# run_ns / run_cs: the real function, bare, under the dispatcher's own `set -euo pipefail`, every dependency stubbed.
run_fn() {      # $1 = name, rest = script tail
  local name="$1"; shift
  cat > "$W/$name.sh" <<EOF
set -euo pipefail
export PATH="$WORK/bin:\$PATH"
warn() { echo "\$*" >> "$W/warn.log"; }
command -v timeout >/dev/null 2>&1 || timeout() { shift; "\$@"; }
GC_CITY=/fake/city
PILOT_NEVERSTARTED_MINUTES=15
PILOT_NEVERSTARTED_OWNER_GRACE_HOURS=24
STALE_SLING_SECONDS=1800
PILOT_STUCK_INFLIGHT_HOURS=2
_DEADWORKER_OK=1
_beadid_has_branch() { return 1; }
_beadid_live_crew_owner() { return 1; }
_session_is_live_builder() { return 1; }
_sling_is_live() { return 1; }
_crew_progressed_since() { return 1; }
_ownership_guard_repos() { return 0; }
_beadid_branch_signal() { return 1; }
$LBL_FN
$REL_FN
$NS_FN
$CS_FN
$*
echo "DONE"
EOF
  "${BASH:-bash}" "$W/$name.sh" > "$W/$name.out" 2> "$W/$name.err"   # the interpreter running this selftest (the mini's /bin/bash is 3.2)
  RC=$?
}
run_ns() { run_fn ns "_neverstarted_recover_db /fake/db $NOW"; }
run_cs() { # $1 = in-flight rows
  run_fn cs "_pilot_crew_stale_reclaim '$1' 9999999999"
}
survived() { [ "$RC" -eq 0 ] && grep -q '^DONE$' "$W/${1:-ns}.out"; }

# ═════════════════════════════════════════════════════════════════════════════
echo "pilot-dispatcher.release-owner.selftest (ga-xxtwytk)"

echo
echo "NS-1 (THE incident): in_progress, dead pool owner gastown.dog-1, self-referential sling — released WITH the owner"
new_world ns1
add_bead wa-lytych in_progress gastown.dog-1 "story:in-flight pilot:dispatched exec:auto lane:small ctx:ready" wa-lytych
run_ns
survived ns && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/ns.err")"
[ -z "$(owner_of wa-lytych)" ] && ok "the dead owner is gone (assignee empty)" || bad "the dead owner is STILL there: '$(owner_of wa-lytych)' (the incident: bd refused the bare assign and the refusal was swallowed)"
[ "$(status_of wa-lytych)" = open ] && ok "status back to open (the state the other release paths leave: no owner, open)" || bad "status is '$(status_of wa-lytych)', not open"
calls_have "--if-status in_progress" && ok "the write is guarded on the status that was read (a bead that closed meanwhile is never reopened)" || bad "no --if-status guard in: $(tr '\n' '|' < "$W/calls.log")"
[ "$(flight_n wa-lytych)" = 0 ] && ok "flight labels off" || bad "flight labels still on after a confirmed release"
[ "$(w_get wa-lytych '.labels | index("exec:auto") != null and index("lane:small") != null and index("ctx:ready") != null')" = true ] \
  && ok "the bead's other labels are untouched" || bad "other labels were removed: $(w_get wa-lytych '.labels | join(",")')"
{ ! has_meta wa-lytych pilot.dispatched_at && ! has_meta wa-lytych pilot.sling_bead; } && ok "dispatch stamps unset" || bad "dispatch stamps still set"
calls_have "--if-assignee gastown.dog-1" && ok "the owner was cleared with the compare-and-swap on the holder (--if-assignee gastown.dog-1)" || bad "no compare-and-swap on the holder in: $(cat "$W/calls.log" | tr '\n' '|')"
{ ! calls_have " assign " && ! calls_have "--force"; } && ok "no plain 'assign' and no --force (the refused call is gone; no override of bd's safety check)" || bad "a plain assign or --force was used: $(grep -E ' assign |--force' "$W/calls.log" | tr '\n' '|')"
no_limbo wa-lytych && ok "invariant: no 'owner set + no flight label'" || bad "LIMBO: owner '$(owner_of wa-lytych)' with no flight labels"

echo
echo "NS-2: the guarded write is REFUSED — the bead is left exactly as it was, loudly, and the NEXT bead is still released"
new_world ns2
add_bead wa-refused in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-refused
add_bead wa-next in_progress gastown.dog-2 "story:in-flight pilot:dispatched" wa-next
export RO_UPDATE_MODE=refuse
run_ns
survived ns && ok "a refused release does not kill the sweep (rc $RC)" || bad "the sweep died on a refused release: rc=$RC err=$(head -c 300 "$W/ns.err")"
for _b in wa-refused wa-next; do
  [ "$(owner_of $_b)" != "" ] && ok "$_b: owner untouched" || bad "$_b: owner was cleared although the write was refused"
  [ "$(flight_n $_b)" = 2 ] && ok "$_b: both flight labels KEPT (inert state, still visible to every query)" || bad "$_b: flight labels were taken off ($(w_get $_b '.labels | join(",")'))"
  has_meta $_b pilot.dispatched_at && has_meta $_b pilot.sling_bead && ok "$_b: dispatch stamps KEPT" || bad "$_b: stamps were unset"
  no_limbo $_b && ok "$_b: invariant holds" || bad "$_b: LIMBO (owner '$(owner_of $_b)', no flight labels)"
done
warn_have "NOT released" && ok "the refusal is logged loudly (NOT released)" || bad "no loud log of the refused release; warn.log: $(head -c 400 "$W/warn.log")"

echo
echo "NS-2b: one bead refused, the next healthy one is still released in the same pass (continue, not abort)"
new_world ns2b
add_bead wa-a-stuck in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-a-stuck
add_bead wa-b-ok in_progress gastown.dog-2 "story:in-flight pilot:dispatched" wa-b-ok
# wa-a-stuck: its owner changes after the list (a new claimant) -> refused for that bead only
jq '.["wa-a-stuck"].list_assignee = "gastown.dog-1" | .["wa-a-stuck"].assignee = "gastown.dog-9"' "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
run_ns
survived ns && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/ns.err")"
[ "$(owner_of wa-a-stuck)" = gastown.dog-9 ] && [ "$(flight_n wa-a-stuck)" = 2 ] && ok "wa-a-stuck: left alone (new owner kept, flight labels kept)" || bad "wa-a-stuck was touched: owner='$(owner_of wa-a-stuck)' flight=$(flight_n wa-a-stuck)"
[ -z "$(owner_of wa-b-ok)" ] && [ "$(flight_n wa-b-ok)" = 0 ] && ok "wa-b-ok: still released after the first one was refused" || bad "wa-b-ok was not released: owner='$(owner_of wa-b-ok)' flight=$(flight_n wa-b-ok)"

echo
echo "NS-3: the write answers rc 0 but does not land (a lie) — the read-back catches it"
new_world ns3
add_bead wa-lie in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-lie
export RO_UPDATE_MODE=lie
run_ns
survived ns && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC"
{ [ -n "$(owner_of wa-lie)" ] && [ "$(flight_n wa-lie)" = 2 ]; } && ok "owner still set, so the flight labels stay (the effect is verified, not the return code)" || bad "labels were taken off on a write that never landed: owner='$(owner_of wa-lie)' flight=$(flight_n wa-lie)"
no_limbo wa-lie && ok "invariant holds" || bad "LIMBO after a write that never landed"

echo
echo "NS-4: the state cannot be READ (fails / empty / garbled) — nothing is written, nothing released"
for _mode in fail empty garbage rc1_valid nostatus; do
  new_world ns4$_mode
  add_bead wa-blind in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-blind
  export RO_SHOW_MODE=$_mode
  run_ns
  survived ns && ok "[$_mode] the sweep survives (rc $RC)" || bad "[$_mode] the sweep died: rc=$RC"
  { [ "$(owner_of wa-blind)" = gastown.dog-1 ] && [ "$(flight_n wa-blind)" = 2 ]; } && ok "[$_mode] third state = unknown: owner and flight labels untouched" || bad "[$_mode] a bead that could not be read was changed: owner='$(owner_of wa-blind)' flight=$(flight_n wa-blind)"
  { ! calls_have " update wa-blind --if-assignee"; } && ok "[$_mode] no owner write was even attempted" || bad "[$_mode] an owner write was attempted without knowing the holder"
  warn_have "could not read it before clearing the owner" && ok "[$_mode] the unreadable bead is logged loudly" || bad "[$_mode] no loud log of the failed read; warn.log: $(head -c 300 "$W/warn.log")"
done

echo
echo "NS-5: the read DIES after the write landed — unknown, flight labels stay, and the next sweep converges"
new_world ns5
# no pilot.sling_bead on purpose: an ownerless bead with a self-referential sling takes the (older, unrelated) ga-l7pp
# "stale unclaimed sling" branch on the next pass, before it ever reaches the release this scenario is about
add_bead wa-ra in_progress gastown.dog-1 "story:in-flight pilot:dispatched"
export RO_SHOW_MODE=fail_after_update
run_ns
survived ns && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC"
{ [ -z "$(owner_of wa-ra)" ] && [ "$(flight_n wa-ra)" = 2 ]; } && ok "owner cleared in the world, flight labels kept because the read-back could not confirm" || bad "unexpected end state: owner='$(owner_of wa-ra)' flight=$(flight_n wa-ra)"
unset RO_SHOW_MODE
rm -f "$W/updated"
run_ns
{ [ -z "$(owner_of wa-ra)" ] && [ "$(flight_n wa-ra)" = 0 ] && [ "$(status_of wa-ra)" = open ]; } && ok "second sweep: nothing left to clear, the labels come off (converged)" || bad "second sweep did not converge: owner='$(owner_of wa-ra)' flight=$(flight_n wa-ra) status=$(status_of wa-ra)"

echo
echo "NS-6: the owner changed after the Pilot judged it (list said gastown.dog-1, the bead says gastown.dog-9) — never clobber the new claimant"
new_world ns6
add_bead wa-chg in_progress gastown.dog-9 "story:in-flight pilot:dispatched" wa-chg
jq '.["wa-chg"].list_assignee = "gastown.dog-1"' "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(owner_of wa-chg)" = gastown.dog-9 ] && [ "$(flight_n wa-chg)" = 2 ]; } && ok "the new owner keeps the bead and its flight labels" || bad "the new claimant was clobbered: owner='$(owner_of wa-chg)' flight=$(flight_n wa-chg)"
{ ! calls_have "--assignee"; } && ok "no owner write at all" || bad "an owner write went out against a bead whose holder changed"

echo
echo "NS-7: a new claimant lands BETWEEN the read and the write — the compare-and-swap loses, the newcomer survives"
for _st in in_progress open; do
  new_world ns7$_st
  add_bead wa-race $_st gastown.dog-1 "story:in-flight pilot:dispatched" wa-race
  export RO_UPDATE_MODE=race:gastown.dog-7
  run_ns
  survived ns && ok "[$_st] the sweep survives" || bad "[$_st] the sweep died: rc=$RC"
  { [ "$(owner_of wa-race)" = gastown.dog-7 ] && [ "$(flight_n wa-race)" = 2 ]; } && ok "[$_st] the newcomer is not cleared and the flight labels stay" || bad "[$_st] race lost badly: owner='$(owner_of wa-race)' flight=$(flight_n wa-race)"
  no_limbo wa-race && ok "[$_st] invariant holds" || bad "[$_st] LIMBO after a lost race"
done

echo
echo "NS-8: no owner (the plain never-started bead) — labels and stamps come off, no owner write, behaviour as before"
new_world ns8
add_bead wa-free open "" "story:in-flight pilot:dispatched"
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(flight_n wa-free)" = 0 ] && ! has_meta wa-free pilot.dispatched_at; } && ok "flight labels and stamp off" || bad "an ownerless never-started bead was not released: flight=$(flight_n wa-free)"
{ ! calls_have "--assignee" && ! calls_have " assign "; } && ok "nothing to clear, so no owner write" || bad "an owner write was made on a bead with no owner"

echo
echo "NS-8b: the list row has no owner and bd cannot answer a show — nothing to let go of, so nothing to read: released as before"
# (the sibling bead ga-9jrt3o7's selftest drives this function with a bd that only answers list; its rows carry no owner)
new_world ns8b
add_bead wa-free2 open "" "story:in-flight pilot:dispatched"
export RO_SHOW_MODE=fail
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(flight_n wa-free2)" = 0 ] && ! has_meta wa-free2 pilot.dispatched_at; } && ok "flight labels and stamp off although a show would have failed" || bad "an ownerless row was held back by a read it did not need: flight=$(flight_n wa-free2)"
{ ! calls_have " show "; } && ok "no read, no write for an ownerless row" || bad "the helper was called for an ownerless row: $(tr '\n' '|' < "$W/calls.log")"

echo
echo "NS-9: owner on an OPEN bead (crew-assigned, never started) — owner cleared, status left alone"
new_world ns9
add_bead wa-open open wa-worker-adhoc-1 "story:in-flight pilot:dispatched"
run_ns
{ [ -z "$(owner_of wa-open)" ] && [ "$(status_of wa-open)" = open ] && [ "$(flight_n wa-open)" = 0 ]; } && ok "owner cleared, still open, labels off" || bad "end state: owner='$(owner_of wa-open)' status=$(status_of wa-open) flight=$(flight_n wa-open)"
{ calls_have "--if-status open" && ! calls_have " --status open"; } && ok "guarded on the status that was read; the status is only rewritten for an in_progress bead" || bad "calls: $(tr '\n' '|' < "$W/calls.log")"

echo
echo "NS-10: the bead closed after the list (the builder just finished) — never reopened, never touched"
new_world ns10
add_bead wa-done closed gastown.dog-1 "story:in-flight pilot:dispatched" wa-done
jq '.["wa-done"].list_status = "in_progress"' "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(status_of wa-done)" = closed ] && [ "$(owner_of wa-done)" = gastown.dog-1 ] && [ "$(flight_n wa-done)" = 2 ]; } && ok "a closed bead is neither reopened nor stripped" || bad "closed bead was touched: status=$(status_of wa-done) owner='$(owner_of wa-done)' flight=$(flight_n wa-done)"

echo
echo "NS-12: the bead closes BETWEEN the read and the write — the status guard refuses, a closed bead is never reopened"
for _st in in_progress open; do
  new_world ns12$_st
  add_bead wa-cr $_st gastown.dog-1 "story:in-flight pilot:dispatched" wa-cr
  export RO_UPDATE_MODE=closerace
  run_ns
  survived ns && ok "[$_st] the sweep survives" || bad "[$_st] the sweep died: rc=$RC"
  { [ "$(status_of wa-cr)" = closed ] && [ "$(owner_of wa-cr)" = gastown.dog-1 ] && [ "$(flight_n wa-cr)" = 2 ]; } && ok "[$_st] still closed, owner and flight labels untouched" || bad "[$_st] closed-in-the-window bead was touched: status=$(status_of wa-cr) owner='$(owner_of wa-cr)' flight=$(flight_n wa-cr)"
done

echo
echo "NS-13: the owner write lands but the bead still reads in_progress — not 'released' (the effect is checked on both fields)"
new_world ns13
add_bead wa-ns in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-ns
export RO_UPDATE_MODE=ignore_status
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ -z "$(owner_of wa-ns)" ] && [ "$(status_of wa-ns)" = in_progress ] && [ "$(flight_n wa-ns)" = 2 ]; } && ok "owner gone but still in_progress: flight labels kept (visible), not stripped into an invisible in_progress bead" || bad "end state: owner='$(owner_of wa-ns)' status=$(status_of wa-ns) flight=$(flight_n wa-ns)"
warn_have "NOT released" && ok "logged loudly" || bad "no loud log; warn.log: $(head -c 300 "$W/warn.log")"

echo
echo "NS-11: the label write fails AFTER the owner went — the bead stays visible (flight labels on), never invisible"
new_world ns11
add_bead wa-lf in_progress gastown.dog-1 "story:in-flight pilot:dispatched" wa-lf
export RO_LABEL_MODE=fail
run_ns
survived ns && ok "the sweep survives a failing label write (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/ns.err")"
{ [ -z "$(owner_of wa-lf)" ] && [ "$(flight_n wa-lf)" = 2 ]; } && ok "owner gone, flight labels still on: visible to the in-flight queries, not limbo" || bad "end state: owner='$(owner_of wa-lf)' flight=$(flight_n wa-lf)"

echo
echo "ST-1: Stage 1.5 (crew-stale reclaim): stale in_progress crew bead, no branch anywhere — owner cleared FIRST, then the labels"
ROW='[{"id":"wa-vm94r","_rig_db":"/fake/wa","assignee":"batista-wa","status":"in_progress","updated_at":"2020-01-01T00:00:00Z"}]'
new_world st1
add_bead wa-vm94r in_progress batista-wa "story:in-flight pilot:dispatched"
run_cs "$ROW"
survived cs && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/cs.err")"
{ [ -z "$(owner_of wa-vm94r)" ] && [ "$(status_of wa-vm94r)" = open ] && [ "$(flight_n wa-vm94r)" = 0 ]; } && ok "reclaimed: owner gone, open, flight labels off" || bad "end state: owner='$(owner_of wa-vm94r)' status=$(status_of wa-vm94r) flight=$(flight_n wa-vm94r) (the wa-lytych shape: owner kept, labels gone)"
{ ! calls_have " assign " && ! calls_have "--force"; } && ok "no plain 'assign', no --force" || bad "plain assign / --force used: $(grep -E ' assign |--force' "$W/calls.log" | tr '\n' '|')"

echo
echo "ST-2: Stage 1.5 with the owner write refused — flight labels and stamps stay, loud log, next row still handled"
new_world st2
add_bead wa-vm94r in_progress batista-wa "story:in-flight pilot:dispatched"
add_bead wa-second in_progress batista-wa "story:in-flight pilot:dispatched"
ROW2='[{"id":"wa-vm94r","_rig_db":"/fake/wa","assignee":"batista-wa","status":"in_progress","updated_at":"2020-01-01T00:00:00Z"},{"id":"wa-second","_rig_db":"/fake/wa","assignee":"batista-wa","status":"in_progress","updated_at":"2020-01-01T00:00:00Z"}]'
export RO_UPDATE_MODE=refuse
run_cs "$ROW2"
survived cs && ok "the sweep survives a refusal on every row (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/cs.err")"
for _b in wa-vm94r wa-second; do
  { [ "$(owner_of $_b)" = batista-wa ] && [ "$(flight_n $_b)" = 2 ] && has_meta $_b pilot.dispatched_at; } && ok "$_b: untouched (owner, flight labels, stamps)" || bad "$_b: changed although the write was refused: owner='$(owner_of $_b)' flight=$(flight_n $_b)"
done
warn_have "NOT released" && ok "logged loudly" || bad "no loud log; warn.log: $(head -c 400 "$W/warn.log")"
unset RO_UPDATE_MODE
run_cs "$ROW2"
{ [ -z "$(owner_of wa-vm94r)" ] && [ -z "$(owner_of wa-second)" ] && [ "$(flight_n wa-vm94r)" = 0 ] && [ "$(flight_n wa-second)" = 0 ]; } && ok "once bd accepts the write again, both rows are reclaimed (retry converges)" || bad "retry did not converge"

echo
echo "ST-3: Stage 1.5 — the read dies: unknown, nothing written (a crew bead that cannot be read is never reclaimed)"
new_world st3
add_bead wa-vm94r in_progress batista-wa "story:in-flight pilot:dispatched"
export RO_SHOW_MODE=fail
run_cs "$ROW"
survived cs && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(owner_of wa-vm94r)" = batista-wa ] && [ "$(flight_n wa-vm94r)" = 2 ]; } && ok "untouched" || bad "changed without knowing the state: owner='$(owner_of wa-vm94r)' flight=$(flight_n wa-vm94r)"

echo
echo "ST-4: Stage 1.5 — a pool-worker owner is still out of scope (Stage 2 owns it): not one call about that bead"
new_world st4
add_bead wa-pool in_progress gastown.dog-1 "story:in-flight pilot:dispatched"
run_cs '[{"id":"wa-pool","_rig_db":"/fake/wa","assignee":"gastown.dog-1","status":"in_progress","updated_at":"2020-01-01T00:00:00Z"}]'
{ [ "$(owner_of wa-pool)" = gastown.dog-1 ] && [ "$(flight_n wa-pool)" = 2 ] && [ ! -s "$W/calls.log" ]; } && ok "untouched, no bd call" || bad "pool-owned bead was touched by the crew reclaim: $(tr '\n' '|' < "$W/calls.log")"

echo
echo "HELPER: _pilot_release_owner directly — the return codes the callers branch on"
if [ -z "$(extract_fn _pilot_release_owner)" ]; then
  bad "_pilot_release_owner is not defined in the dispatcher (the helper of the fix)"
else
  helper() {   # $1 = id, $2 = judged owner -> RC
    run_fn h "_pilot_release_owner /fake/db '$1' '$2' >/dev/null 2>&1 || exit \$?"
  }
  new_world h1; add_bead hb in_progress gastown.dog-1 "story:in-flight"
  helper hb gastown.dog-1
  [ "$RC" -eq 0 ] && [ -z "$(owner_of hb)" ] && ok "cleared -> rc 0" || bad "cleared: rc=$RC owner='$(owner_of hb)'"
  new_world h2; add_bead hb in_progress gastown.dog-1 "story:in-flight"; export RO_UPDATE_MODE=refuse
  helper hb gastown.dog-1
  [ "$RC" -eq 1 ] && ok "refused -> rc 1" || bad "refused: rc=$RC (want 1)"
  new_world h3; add_bead hb in_progress gastown.dog-1 "story:in-flight"; export RO_SHOW_MODE=fail
  helper hb gastown.dog-1
  [ "$RC" -eq 2 ] && ok "unreadable -> rc 2 (not 0, not 1)" || bad "unreadable: rc=$RC (want 2)"
  new_world h4; add_bead hb in_progress gastown.dog-1 "story:in-flight"; export RO_SHOW_MODE=fail_after_update
  helper hb gastown.dog-1
  [ "$RC" -eq 2 ] && ok "write landed but the read-back dies -> rc 2" || bad "read-back failure: rc=$RC (want 2)"
  new_world h5; add_bead hb in_progress gastown.dog-9 "story:in-flight"
  helper hb gastown.dog-1
  [ "$RC" -eq 1 ] && ok "owner changed since it was judged -> rc 1" || bad "changed owner: rc=$RC (want 1)"
  new_world h6; add_bead hb in_progress "" "story:in-flight"
  helper hb gastown.dog-1
  [ "$RC" -eq 0 ] && ok "already without owner -> rc 0 (nothing to clear, even when the judged owner was someone)" || bad "already free: rc=$RC (want 0)"
  new_world h7; add_bead hb closed gastown.dog-1 "story:in-flight"
  helper hb gastown.dog-1
  [ "$RC" -eq 1 ] && ok "closed -> rc 1 (never reopened)" || bad "closed: rc=$RC (want 1)"
  new_world h8; add_bead hb in_progress $'gastown.dog-1\nforged' "story:in-flight"
  helper hb gastown.dog-1
  [ "$RC" -eq 1 ] && [ -n "$(owner_of hb)" ] && ok "a hostile owner with a newline is a different owner, not a match -> rc 1, untouched" || bad "newline owner: rc=$RC owner='$(owner_of hb)'"
  # the owner is free text from bd: its second line must not become a log line of its own (a forged 'released' line would be read as the Pilot's)
  { grep -q 'gastown.dog-1?forged' "$W/warn.log" && ! grep -q '^forged' "$W/warn.log"; } && ok "the hostile owner reaches the log on ONE line (control characters shown as '?')" || bad "the owner's newline split the log: $(tr '\n' '|' < "$W/warn.log")"
fi

echo
echo "STRUCTURE: the refused call is gone and the owner goes first"
if grep -nE 'assign "[^"]*" ""' "$DISPATCHER" >/dev/null; then
  bad "a bare 'assign <id> \"\"' is still in the dispatcher: $(grep -nE 'assign "[^"]*" ""' "$DISPATCHER" | head -3 | tr '\n' '|')"
else
  ok "no bare 'assign <id> \"\"' left in the dispatcher (bd-98s5c refuses it for another actor's in_progress claim)"
fi
# owner release (call) before the first flight-label removal, inside each of the two functions
for _fn in _neverstarted_recover_db _pilot_crew_stale_reclaim; do
  _order="$(sed -n "/^$_fn() {/,/^}\$/p" "$DISPATCHER" | awk '/_pilot_release_owner "/ && !c {c=NR} /label  remove/ && !l {l=NR} END {if (c && l && c < l) print "ok"; else print "c=" c+0 " l=" l+0}')"
  [ "$_order" = ok ] && ok "$_fn: _pilot_release_owner is called before the flight labels come off" || bad "$_fn: owner release does not precede the label removal ($_order)"
done

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

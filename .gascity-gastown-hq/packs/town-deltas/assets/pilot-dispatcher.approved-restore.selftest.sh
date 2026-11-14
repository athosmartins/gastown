#!/usr/bin/env bash
# pilot-dispatcher.approved-restore.selftest.sh (ga-w6a9xps)
#
# ORIGIN: wa-tvrs41.5 (WhatsApp automation), approved by Athos on 13/11, came back to him on 14/11 as a fresh idea asking for a SECOND approval.
# The Pilot keeps story:approved on dispatch and adds story:in-flight next to it, but the builder's own claim drops story:approved. When the
# crew-stale reclaim (Stage 1.5, ga-c9qj8) or the NEVERSTARTED release then took story:in-flight off ("back to the pool"), the story was left with NO
# story:* label at all — which is exactly what auto-refino's RAW sweep (auto_refino_is_ingestable_raw) calls an untriaged idea. The Mayor restored
# the bead by hand.
#
# FIX under test: _pilot_restore_approved <db> <bead> (+ its reader _pilot_approved_verdict) gives story:approved BACK before story:in-flight is
# stripped, for a story (feature/story) that carries story:in-flight and no other story:* label, and CONFIRMS it by reading the bead back. rc 0 lets the
# caller go on; rc 1 (not confirmed) / rc 2 (could not read) leave the bead exactly as it is (owner, flight labels, stamps) so it stays visible and the next
# sweep retries. It never adds story:approved to a bug/task/chore and never overwrites another lifecycle state. Both release paths call it first.
#
# THE invariants, asserted after every scenario:
#   (1) no moment where the story reads as raw: the fake bd traces the number of story:* labels of every bead after EVERY write; a story must never
#       show 0 (auto-refino looks at the bead between two writes of the Pilot too);
#   (2) the END state, fed to the REAL auto_refino_is_ingestable_raw cut out of auto-refino-dispatcher.sh, is "no" (not an idea).
#
# The fake bd models what the repo documents of bd 1.1.0 (see pilot-dispatcher.release-owner.selftest.sh, whose guarded-write model it shares); it was NOT
# checked against a live bd here. Runs the REAL functions cut out of the two scripts with sed; every other dependency is stubbed; no live bd/gc/Dolt/git.
# Against the pre-fix dispatcher the incident scenarios fail with the incident's own end state (story with no story:* label).
#
# Exit 0 iff every assertion holds.

set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${DISPATCHER:-$SELF_DIR/pilot-dispatcher.sh}"
AUTO_REFINO="${AUTO_REFINO:-$SELF_DIR/auto-refino-dispatcher.sh}"

PASS=0
FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }

[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found at $DISPATCHER" >&2; exit 2; }
[ -f "$AUTO_REFINO" ] || { echo "FATAL: auto-refino-dispatcher not found at $AUTO_REFINO" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq not found" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-approved-restore.XXXXXX")" || { echo "FATAL: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$WORK"' EXIT

extract_fn()    { sed -n "/^$1() {/,/^}\$/p" "$DISPATCHER"; }
extract_raw_fn() { sed -n "/^$1() {/,/^}\$/p" "$AUTO_REFINO"; }
NS_FN="$(extract_fn _neverstarted_recover_db)"
LBL_FN="$(extract_fn _ns_label_blocks_release)"
CS_FN="$(extract_fn _pilot_crew_stale_reclaim)"
for _f in NS_FN LBL_FN CS_FN; do
  [ -n "${!_f}" ] || { echo "FATAL: could not cut $_f out of $DISPATCHER (extraction pattern drifted)" >&2; exit 2; }
done
# Empty on a pre-fix dispatcher (the callers are then the old ones, which never call the restore): the scenarios below fail with the incident's end state.
REL_FN="$(extract_fn _pilot_owner_state)
$(extract_fn _pilot_release_owner)
$(extract_fn _pilot_approved_verdict)
$(extract_fn _pilot_restore_approved)"
RAW_FN="$(extract_raw_fn auto_refino_type_eligible)
$(extract_raw_fn auto_refino_has_lifecycle_label)
$(extract_raw_fn auto_refino_is_product_story)
$(extract_raw_fn auto_refino_is_ingestable_raw)"
[ -n "$(extract_raw_fn auto_refino_is_ingestable_raw)" ] || { echo "FATAL: auto_refino_is_ingestable_raw not found in $AUTO_REFINO" >&2; exit 2; }
# shellcheck disable=SC1090
eval "$RAW_FN"

NOW=1794542500
STAMP=$((NOW - 3600))   # dispatched an hour ago: past PILOT_NEVERSTARTED_MINUTES=15

# ── the fake bd ──────────────────────────────────────────────────────────────
mkdir -p "$WORK/bin"
cat > "$WORK/bin/bd" <<'FAKE'
#!/usr/bin/env bash
# fake bd. World = $AR_WORLD/world.json: {"<id>": {status, assignee, issue_type, labels[], metadata{}}}.
# AR_SHOW_MODE: ok | fail | empty | garbage | fail_after_add (show dies once a `label add` has landed)
# AR_ADD_MODE (for `label add`; AR_ADD_ONLY=<id> restricts it to one bead): ok | refuse (rc 1, not applied) | lie (rc 0, not applied)
W="${AR_WORLD:?}"; WJ="$W/world.json"
echo "$*" >> "$W/calls.log"
[ "${1:-}" = "-C" ] && shift 2
cmd="${1:-}"; [ $# -gt 0 ] && shift
wj_set() { jq "$@" "$WJ" > "$WJ.tmp" && mv "$WJ.tmp" "$WJ"; }
# after EVERY write: how many story:* labels the bead carries (a story that shows 0 reads as a raw idea to auto-refino)
trace() { jq -r --arg id "$1" 'if has($id) then "\($id) \([.[$id].labels[] | select(startswith("story:"))] | length)" else empty end' "$WJ" >> "$W/trace.log"; }
cur_of() { jq -r --arg id "$1" '.[$id].assignee // ""' "$WJ"; }
st_of()  { jq -r --arg id "$1" '.[$id].status // ""' "$WJ"; }
case "$cmd" in
  show)
    id="$1"
    case "${AR_SHOW_MODE:-ok}" in
      fail) echo "Error: dolt unavailable" >&2; exit 1 ;;
      empty) exit 0 ;;
      garbage) echo "this is not json"; exit 0 ;;
      fail_after_add) [ -e "$W/added" ] && { echo "Error: dolt unavailable" >&2; exit 1; } ;;
    esac
    jq -c --arg id "$id" 'if has($id) then [ .[$id] + {id:$id} | if .assignee == "" then del(.assignee) else . end ] else [] end' "$WJ" ;;
  list)
    want=""
    while [ $# -gt 0 ]; do [ "$1" = "-l" ] && { want="$want $2"; shift; }; shift; done
    jq -c --arg want "$want" '($want | split(" ") | map(select(length > 0))) as $w
      | [ to_entries[] | select(.value.status != "closed")
          | select(.value.labels as $l | all($w[]; . as $x | $l | index($x) != null))
          | .value + {id: .key} | if .assignee == "" then del(.assignee) else . end ]' "$WJ" ;;
  label)
    sub="$1"; id="$2"; lab="$3"
    case "$sub" in
      remove) wj_set --arg id "$id" --arg l "$lab" '.[$id].labels -= [$l]'; trace "$id" ;;
      add)
        mode="${AR_ADD_MODE:-ok}"
        [ -n "${AR_ADD_ONLY:-}" ] && [ "$AR_ADD_ONLY" != "$id" ] && mode=ok
        case "$mode" in
          refuse) echo "Error: label write refused" >&2; exit 1 ;;
          lie)    exit 0 ;;
        esac
        wj_set --arg id "$id" --arg l "$lab" '.[$id].labels += [$l] | .[$id].labels |= unique'; : > "$W/added"; trace "$id" ;;
    esac ;;
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
      esac
      shift
    done
    cur="$(cur_of "$id")"; st="$(st_of "$id")"
    [ "$has_ifa" = 1 ] && [ "$cur" != "$ifa" ] && { echo "Error: --if-assignee mismatch (held by '$cur')" >&2; exit 13; }
    [ "$has_ifs" = 1 ] && [ "$st"  != "$ifs" ] && { echo "Error: --if-status mismatch (is '$st')" >&2; exit 13; }
    [ "$has_newa" = 1 ] && wj_set --arg id "$id" --arg n "$newa" '.[$id].assignee = $n'
    [ "$has_news" = 1 ] && wj_set --arg id "$id" --arg s "$news" '.[$id].status = $s'
    for k in $unsetm; do wj_set --arg id "$id" --arg k "$k" 'del(.[$id].metadata[$k])'; done
    trace "$id"
    exit 0 ;;
  *) echo "fake bd: unexpected command: $cmd $*" >&2; exit 99 ;;
esac
FAKE
chmod +x "$WORK/bin/bd"

# ── world helpers ────────────────────────────────────────────────────────────
new_world() {   # $1 = name
  W="$WORK/w.$1"; mkdir -p "$W"
  echo '{}' > "$W/world.json"; : > "$W/calls.log"; : > "$W/warn.log"; : > "$W/trace.log"; rm -f "$W/added"
  export AR_WORLD="$W"
  unset AR_SHOW_MODE AR_ADD_MODE AR_ADD_ONLY
}
add_bead() {    # id status assignee issue_type "label label"   (the sling bead is the bead itself, like a self-dispatched story)
  jq --arg id "$1" --arg st "$2" --arg a "$3" --arg ty "$4" --arg l "$5" --argjson stamp "$STAMP" \
    '.[$id] = {status:$st, assignee:$a, issue_type:$ty, labels:($l | split(" ") | map(select(length > 0))),
               metadata:{"pilot.dispatched_at":($stamp|tostring), "pilot.sling_bead":$id}}' \
    "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
}
w_get() { jq -r --arg id "$1" ".[\$id] | $2" "$W/world.json"; }
owner_of()  { w_get "$1" '.assignee // ""'; }
status_of() { w_get "$1" '.status'; }
labels_of() { w_get "$1" '.labels | join(",")'; }
has_label() { [ "$(w_get "$1" ".labels | index(\"$2\") != null")" = true ]; }
flight_n()  { w_get "$1" '[.labels[] | select(. == "story:in-flight" or . == "pilot:dispatched" or . == "pilot:dispatching")] | length'; }
has_meta()  { [ "$(w_get "$1" ".metadata | has(\"$2\")")" = true ]; }
calls_have() { grep -qF -- "$1" "$W/calls.log"; }
warn_have()  { grep -qF -- "$1" "$W/warn.log"; }
calls_line() { grep -nF -- "$1" "$W/calls.log" | head -1 | cut -d: -f1; }
# (1) the story never reads as raw between two writes of the Pilot
never_raw() { ! grep -qx -- "$1 0" "$W/trace.log"; }
# (2) the end state, as auto-refino's RAW classifier sees it ("yes" = it would ingest the bead as a fresh idea)
raw_verdict() { auto_refino_is_ingestable_raw "$1" "$(w_get "$1" '.issue_type')" "$(labels_of "$1")" "false" "" "999999" "0" "$(owner_of "$1")" "no" "no" "no"; }

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
_beadid_has_live_worktree() { return 1; }
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
  "${BASH:-bash}" "$W/$name.sh" > "$W/$name.out" 2> "$W/$name.err"
  RC=$?
}
run_ns() { run_fn ns "_neverstarted_recover_db /fake/db $NOW"; }
run_cs() { run_fn cs "_pilot_crew_stale_reclaim '$1' 9999999999"; }
survived() { [ "$RC" -eq 0 ] && grep -q '^DONE$' "$W/${1:-ns}.out"; }
cs_row() { printf '{"id":"%s","_rig_db":"/fake/db","assignee":"%s","updated_at":"2020-01-01T00:00:00Z"}' "$1" "$2"; }

echo "pilot-dispatcher.approved-restore.selftest (ga-w6a9xps)"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "CS-1 (THE incident): story approved by Athos, builder's claim dropped story:approved, crew stale with no branch — released WITH its approval"
new_world cs1
add_bead wa-tvrs41.5 in_progress batista-wa feature "story:in-flight pilot:dispatched exec:auto ctx:ready"
run_cs "[$(cs_row wa-tvrs41.5 batista-wa)]"
survived cs && ok "the reclaim survives (rc $RC)" || bad "the reclaim died: rc=$RC err=$(head -c 300 "$W/cs.err")"
has_label wa-tvrs41.5 story:approved && ok "story:approved is back" || bad "story:approved is NOT back; labels: $(labels_of wa-tvrs41.5)"
! has_label wa-tvrs41.5 story:in-flight && ok "story:in-flight is off (back to the pool)" || bad "story:in-flight still on"
[ -z "$(owner_of wa-tvrs41.5)" ] && [ "$(status_of wa-tvrs41.5)" = open ] && ok "owner released, status open" || bad "owner='$(owner_of wa-tvrs41.5)' status=$(status_of wa-tvrs41.5)"
{ ! has_meta wa-tvrs41.5 pilot.dispatched_at && ! has_meta wa-tvrs41.5 pilot.sling_bead; } && ok "dispatch stamps unset" || bad "dispatch stamps still set"
never_raw wa-tvrs41.5 && ok "(1) never a moment with zero story:* labels (trace: $(tr '\n' ',' < "$W/trace.log"))" || bad "(1) LIMBO: the story showed ZERO story:* labels after a write (trace: $(tr '\n' ',' < "$W/trace.log"))"
[ "$(raw_verdict wa-tvrs41.5)" = no ] && ok "(2) auto-refino's RAW sweep does NOT pick it up" || bad "(2) auto-refino would re-ingest it as a fresh idea (labels: $(labels_of wa-tvrs41.5))"
_a="$(calls_line 'label add wa-tvrs41.5 story:approved')"; _r="$(calls_line 'label remove wa-tvrs41.5 story:in-flight')"
{ [ -n "$_a" ] && [ -n "$_r" ] && [ "$_a" -lt "$_r" ]; } && ok "story:approved was written BEFORE story:in-flight came off (call $_a < $_r)" || bad "order: add at '$_a', remove at '$_r'"
[ "$(w_get wa-tvrs41.5 '.labels | index("exec:auto") != null and index("ctx:ready") != null')" = true ] && ok "the other labels are untouched" || bad "other labels changed: $(labels_of wa-tvrs41.5)"

echo
echo "CS-2: the story already carries another lifecycle state — left alone (story:approved is not added over it)"
new_world cs2
add_bead wa-other in_progress batista-wa feature "story:in-flight story:needs-approval pilot:dispatched"
run_cs "[$(cs_row wa-other batista-wa)]"
survived cs && ok "the reclaim survives" || bad "the reclaim died: rc=$RC"
{ ! has_label wa-other story:approved && has_label wa-other story:needs-approval; } && ok "no story:approved written over story:needs-approval" || bad "labels: $(labels_of wa-other)"
! calls_have " label add " && ok "no label write at all" || bad "a label was added: $(grep ' label add ' "$W/calls.log" | tr '\n' '|')"
{ ! has_label wa-other story:in-flight && [ -z "$(owner_of wa-other)" ]; } && ok "still released as before" || bad "not released: owner='$(owner_of wa-other)' labels=$(labels_of wa-other)"

echo
echo "CS-3: a BUG (never had story:approved, dispatched without it) — released as before, NOT turned into an approved story"
new_world cs3
add_bead wa-bug in_progress batista-wa bug "story:in-flight pilot:dispatched"
run_cs "[$(cs_row wa-bug batista-wa)]"
survived cs && ok "the reclaim survives" || bad "the reclaim died: rc=$RC"
{ ! has_label wa-bug story:approved && ! calls_have " label add "; } && ok "no story:approved added to a bug" || bad "story:approved added to a bug: $(labels_of wa-bug)"
{ ! has_label wa-bug story:in-flight && [ -z "$(owner_of wa-bug)" ] && [ "$(flight_n wa-bug)" = 0 ]; } && ok "released as before (owner off, flight labels off)" || bad "not released: owner='$(owner_of wa-bug)' labels=$(labels_of wa-bug)"

echo
echo "CS-4: the story still HAS story:approved (the claim never dropped it) — released, no second label write, one approval"
new_world cs4
add_bead wa-kept in_progress batista-wa feature "story:approved story:in-flight pilot:dispatched"
run_cs "[$(cs_row wa-kept batista-wa)]"
survived cs && ok "the reclaim survives" || bad "the reclaim died: rc=$RC"
{ [ "$(w_get wa-kept '[.labels[] | select(. == "story:approved")] | length')" = 1 ] && ! has_label wa-kept story:in-flight && [ -z "$(owner_of wa-kept)" ]; } && ok "one story:approved, in-flight off, owner released" || bad "labels: $(labels_of wa-kept) owner='$(owner_of wa-kept)'"
! calls_have " label add " && ok "nothing to restore, nothing written" || bad "a label was added: $(grep ' label add ' "$W/calls.log" | tr '\n' '|')"
[ "$(raw_verdict wa-kept)" = no ] && ok "(2) not an idea for auto-refino" || bad "(2) auto-refino would re-ingest it"

echo
echo "CS-5: the restore is REFUSED by bd — the bead is left exactly as it was (owner, flight labels, stamps), loudly; the next bead is still reclaimed"
new_world cs5
add_bead wa-refused in_progress batista-wa feature "story:in-flight pilot:dispatched"
add_bead wa-next in_progress batista-wa feature "story:in-flight pilot:dispatched"
export AR_ADD_MODE=refuse AR_ADD_ONLY=wa-refused
run_cs "[$(cs_row wa-refused batista-wa),$(cs_row wa-next batista-wa)]"
survived cs && ok "a refused restore does not kill the sweep (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/cs.err")"
{ [ "$(owner_of wa-refused)" = batista-wa ] && [ "$(flight_n wa-refused)" = 2 ] && has_meta wa-refused pilot.dispatched_at; } && ok "wa-refused: owner, both flight labels and stamps KEPT" || bad "wa-refused was touched: owner='$(owner_of wa-refused)' labels=$(labels_of wa-refused)"
never_raw wa-refused && ok "wa-refused: never raw" || bad "wa-refused: LIMBO"
warn_have "NOT released" && ok "logged loudly (NOT released)" || bad "no loud log; warn.log: $(head -c 300 "$W/warn.log")"
{ has_label wa-next story:approved && ! has_label wa-next story:in-flight && [ -z "$(owner_of wa-next)" ]; } && ok "wa-next: restored and released in the same pass (continue, not abort)" || bad "wa-next: labels=$(labels_of wa-next) owner='$(owner_of wa-next)'"

echo
echo "CS-6: bd answers rc 0 to the restore but nothing lands — the effect is read back, so it is NOT taken for done"
new_world cs6
add_bead wa-lie in_progress batista-wa feature "story:in-flight pilot:dispatched"
export AR_ADD_MODE=lie
run_cs "[$(cs_row wa-lie batista-wa)]"
survived cs && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(owner_of wa-lie)" = batista-wa ] && [ "$(flight_n wa-lie)" = 2 ] && ! has_label wa-lie story:approved; } && ok "bead untouched (the exit code of the write was not believed)" || bad "owner='$(owner_of wa-lie)' labels=$(labels_of wa-lie)"
never_raw wa-lie && ok "never raw" || bad "LIMBO after a restore that never landed"

echo
echo "CS-7: the bead cannot be READ (fails / empty / garbled) — third state = unknown: nothing written, nothing released"
for _mode in fail empty garbage; do
  new_world cs7$_mode
  add_bead wa-blind in_progress batista-wa feature "story:in-flight pilot:dispatched"
  export AR_SHOW_MODE=$_mode
  run_cs "[$(cs_row wa-blind batista-wa)]"
  survived cs && ok "[$_mode] the sweep survives" || bad "[$_mode] the sweep died: rc=$RC"
  { [ "$(owner_of wa-blind)" = batista-wa ] && [ "$(flight_n wa-blind)" = 2 ]; } && ok "[$_mode] owner and flight labels untouched" || bad "[$_mode] changed: owner='$(owner_of wa-blind)' labels=$(labels_of wa-blind)"
  { ! calls_have " label " && ! calls_have " update "; } && ok "[$_mode] no write of any kind" || bad "[$_mode] a write was made: $(tr '\n' '|' < "$W/calls.log")"
  warn_have "ga-w6a9xps" && ok "[$_mode] logged loudly" || bad "[$_mode] no loud log; warn.log: $(head -c 300 "$W/warn.log")"
done

echo
echo "CS-8: the restore LANDED but the read-back dies — unknown: owner and flight labels stay (the approval that landed stays too), the next sweep converges"
new_world cs8
add_bead wa-after in_progress batista-wa feature "story:in-flight pilot:dispatched"
export AR_SHOW_MODE=fail_after_add
run_cs "[$(cs_row wa-after batista-wa)]"
survived cs && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(owner_of wa-after)" = batista-wa ] && has_label wa-after story:in-flight && has_label wa-after pilot:dispatched; } && ok "owner and flight labels kept" || bad "owner='$(owner_of wa-after)' labels=$(labels_of wa-after)"
never_raw wa-after && ok "never raw" || bad "LIMBO"
echo "  (second sweep, bd readable again)"
unset AR_SHOW_MODE
run_cs "[$(cs_row wa-after batista-wa)]"
{ has_label wa-after story:approved && ! has_label wa-after story:in-flight && [ -z "$(owner_of wa-after)" ] && [ "$(raw_verdict wa-after)" = no ]; } && ok "converges: approved, released, not an idea" || bad "second sweep: labels=$(labels_of wa-after) owner='$(owner_of wa-after)'"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "NS-1 (the NEVERSTARTED sibling): story whose builder claimed it and never started — released WITH its approval"
new_world ns1
add_bead wa-ns1 in_progress batista-wa feature "story:in-flight pilot:dispatched exec:auto"
run_ns
survived ns && ok "the sweep survives (rc $RC)" || bad "the sweep died: rc=$RC err=$(head -c 300 "$W/ns.err")"
has_label wa-ns1 story:approved && ok "story:approved is back" || bad "story:approved is NOT back; labels: $(labels_of wa-ns1)"
{ ! has_label wa-ns1 story:in-flight && [ -z "$(owner_of wa-ns1)" ] && [ "$(flight_n wa-ns1)" = 0 ]; } && ok "released (owner off, flight labels off)" || bad "owner='$(owner_of wa-ns1)' labels=$(labels_of wa-ns1)"
never_raw wa-ns1 && ok "(1) never a moment with zero story:* labels" || bad "(1) LIMBO: zero story:* labels after a write (trace: $(tr '\n' ',' < "$W/trace.log"))"
[ "$(raw_verdict wa-ns1)" = no ] && ok "(2) auto-refino's RAW sweep does NOT pick it up" || bad "(2) auto-refino would re-ingest it as a fresh idea (labels: $(labels_of wa-ns1))"
_a="$(calls_line 'label add wa-ns1 story:approved')"; _r="$(calls_line 'label remove wa-ns1 story:in-flight')"
{ [ -n "$_a" ] && [ -n "$_r" ] && [ "$_a" -lt "$_r" ]; } && ok "story:approved written BEFORE story:in-flight came off" || bad "order: add at '$_a', remove at '$_r'"

echo
echo "NS-2: no owner on the row (the claim was already released by someone) and story:approved gone — still restored"
new_world ns2
add_bead wa-ns2 open "" feature "story:in-flight pilot:dispatched"
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ has_label wa-ns2 story:approved && ! has_label wa-ns2 story:in-flight; } && ok "restored, flight label off" || bad "labels: $(labels_of wa-ns2)"
{ never_raw wa-ns2 && [ "$(raw_verdict wa-ns2)" = no ]; } && ok "never raw, not an idea at the end" || bad "LIMBO or re-ingestable (trace: $(tr '\n' ',' < "$W/trace.log"))"

echo
echo "NS-3: a BUG — released as before, no story:approved added"
new_world ns3
add_bead wa-ns3 in_progress batista-wa bug "story:in-flight pilot:dispatched"
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ ! has_label wa-ns3 story:approved && ! calls_have " label add " && [ "$(flight_n wa-ns3)" = 0 ] && [ -z "$(owner_of wa-ns3)" ]; } && ok "released, nothing added" || bad "labels=$(labels_of wa-ns3) owner='$(owner_of wa-ns3)'"

echo
echo "NS-4: the restore is refused — untouched (owner, flight labels, stamps), the sweep goes on to the next bead"
new_world ns4
add_bead wa-ns4a in_progress batista-wa feature "story:in-flight pilot:dispatched"
add_bead wa-ns4b in_progress batista-wa feature "story:in-flight pilot:dispatched"
export AR_ADD_MODE=refuse AR_ADD_ONLY=wa-ns4a
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(owner_of wa-ns4a)" = batista-wa ] && [ "$(flight_n wa-ns4a)" = 2 ] && has_meta wa-ns4a pilot.dispatched_at; } && ok "wa-ns4a untouched" || bad "wa-ns4a: owner='$(owner_of wa-ns4a)' labels=$(labels_of wa-ns4a)"
{ has_label wa-ns4b story:approved && [ "$(flight_n wa-ns4b)" = 0 ] && [ -z "$(owner_of wa-ns4b)" ]; } && ok "wa-ns4b restored and released in the same pass" || bad "wa-ns4b: labels=$(labels_of wa-ns4b) owner='$(owner_of wa-ns4b)'"

echo
echo "NS-5: the row has no owner and the bead cannot be read — unknown: nothing released blind, nothing written"
new_world ns5
add_bead wa-ns5 open "" feature "story:in-flight pilot:dispatched"
export AR_SHOW_MODE=fail
run_ns
survived ns && ok "the sweep survives" || bad "the sweep died: rc=$RC"
{ [ "$(flight_n wa-ns5)" = 2 ] && ! calls_have " label " && ! calls_have " update "; } && ok "flight labels kept, no write" || bad "labels=$(labels_of wa-ns5); calls: $(tr '\n' '|' < "$W/calls.log")"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "VERDICT: _pilot_approved_verdict (pure) — one word per shape; unreadable is rc 1 with NO word"
if [ -z "$(extract_fn _pilot_approved_verdict)" ]; then
  bad "_pilot_approved_verdict is not in the dispatcher (pre-fix tree)"
else
  eval "$(extract_fn _pilot_approved_verdict)"
  v() { _pilot_approved_verdict "$1" 2>/dev/null; }
  chk() { # <expected word> <json> <label>
    local got; got="$(v "$2")"
    [ "$got" = "$1" ] && ok "$3 → $1" || bad "$3: got '$got', want '$1'"
  }
  chk restore           '[{"status":"in_progress","issue_type":"feature","labels":["story:in-flight","pilot:dispatched"]}]' "feature + in-flight, no approval"
  chk restore           '[{"status":"in_progress","issue_type":"story","labels":["story:in-flight","pilot:dispatched"]}]' "story type + in-flight + dispatch label"
  chk restore           '{"status":"open","issue_type":"feature","labels":["story:in-flight","pilot:dispatched"]}' "bare object (not an array)"
  chk restore           '[{"status":"open","issue_type":"feature","labels":["story:in-flight"],"metadata":{"pilot.dispatched_at":"1790000000"}}]' "proof = pilot.dispatched_at stamp"
  chk restore           '[{"status":"open","issue_type":"feature","labels":["story:in-flight"],"metadata":{"story.aprovado_por":"athos"}}]' "proof = story.aprovado_por stamp"
  # no trace that Athos's approval ever stood (Regra 4: never inferred) → never re-approved: also what a bead Athos parked by hand looks like
  chk no-proof          '[{"status":"in_progress","issue_type":"feature","labels":["story:in-flight"]}]' "feature + in-flight, no trace at all"
  chk no-proof          '[{"status":"in_progress","issue_type":"story","labels":["story:in-flight"],"metadata":{}}]' "story type, empty metadata"
  chk no-proof          '[{"status":"in_progress","issue_type":"feature","labels":["story:in-flight"],"metadata":{"pilot.dispatched_at":"","story.aprovado_por":""}}]' "stamps present but empty"
  chk no-proof          '[{"status":"in_progress","issue_type":"feature","labels":["story:in-flight"],"metadata":"oops"}]' "metadata not an object (read as no trace, never as proof)"
  chk has-approved      '[{"status":"in_progress","issue_type":"feature","labels":["story:approved","story:in-flight"]}]' "approved + in-flight"
  chk other-story-state '[{"status":"open","issue_type":"feature","labels":["story:in-flight","story:done"]}]' "in-flight + story:done"
  chk other-story-state '[{"status":"open","issue_type":"feature","labels":["story:in-flight","story:cancelled"]}]' "in-flight + story:cancelled"
  chk not-story         '[{"status":"in_progress","issue_type":"bug","labels":["story:in-flight"]}]' "bug"
  chk not-story         '[{"status":"in_progress","issue_type":"task","labels":["story:in-flight"]}]' "task"
  chk not-story         '[{"status":"in_progress","labels":["story:in-flight"]}]' "no issue_type at all"
  chk not-in-flight     '[{"status":"open","issue_type":"feature","labels":["exec:auto"]}]' "feature without story:in-flight"
  chk not-in-flight     '[{"status":"open","issue_type":"feature"}]' "no labels field"
  chk not-in-flight     '[{"status":"open","issue_type":"feature","labels":null}]' "labels null"
  for _bad in '' 'not json' '[]' '[{}]' '[{"issue_type":"feature","labels":["story:in-flight"]}]' '"x"' 'null'; do
    _out="$(_pilot_approved_verdict "$_bad" 2>/dev/null)"; _rc=$?
    { [ "$_rc" -ne 0 ] && [ -z "$_out" ]; } && ok "unreadable '$_bad' → rc $_rc, no word" || bad "unreadable '$_bad' → rc=$_rc out='$_out' (must be a failure with no word)"
  done
fi

# ════════════════════════════════════════════════════════════════════════════
echo
echo "NO-PROOF: a feature in flight with no dispatch/approval trace is released as before — story:approved is NOT written (only Athos approves)"
new_world np
add_bead wa-np in_progress batista-wa feature "story:in-flight"
jq 'del(.["wa-np"].metadata["pilot.dispatched_at"])' "$W/world.json" > "$W/world.tmp" && mv "$W/world.tmp" "$W/world.json"
run_fn np "_pilot_restore_approved /fake/db wa-np"
{ [ "$RC" -eq 0 ] && grep -q '^DONE$' "$W/np.out"; } && ok "no-proof → rc 0 (the release may go on)" || bad "rc=$RC err: $(tr '\n' '|' < "$W/np.err")"
! calls_have " label add " && ok "story:approved was NOT written" || bad "wrote a label: $(tr '\n' '|' < "$W/calls.log")"
! has_label wa-np story:approved && ok "labels untouched ($(labels_of wa-np))" || bad "story:approved appeared on a bead with no proof"

# ═════════════════════════════════════════════════════════════════════════════
echo
echo "STRUCTURE: the restore comes first, and a refusal skips the release"
for _fn in _neverstarted_recover_db _pilot_crew_stale_reclaim; do
  _order="$(sed -n "/^$_fn() {/,/^}\$/p" "$DISPATCHER" | awk '/_pilot_restore_approved "/ && !r {r=NR} /_pilot_release_owner "/ && !c {c=NR} /label  remove/ && !l {l=NR} END {if (r && c && l && r < c && c < l) print "ok"; else print "r=" r+0 " c=" c+0 " l=" l+0}')"
  [ "$_order" = ok ] && ok "$_fn: _pilot_restore_approved → _pilot_release_owner → flight labels off" || bad "$_fn: wrong order or missing ($_order)"
  sed -n "/^$_fn() {/,/^}\$/p" "$DISPATCHER" | grep -qE '_pilot_restore_approved "[^"]*" "[^"]*" \|\| continue' && ok "$_fn: a restore that is not confirmed skips the bead (|| continue)" || bad "$_fn: no '|| continue' on the restore"
done

echo
echo "── results: $PASS passed, $FAIL failed ──"
[ "$FAIL" -eq 0 ]

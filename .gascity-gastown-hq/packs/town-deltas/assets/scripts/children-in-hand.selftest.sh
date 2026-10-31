#!/usr/bin/env bash
# children-in-hand.selftest.sh — ga-vdac4cj.
#
# children-in-hand-lib.sh is the ONE definition of "this bead is a mother whose work belongs to its children", sourced by the
# pool probe (pool-probe.sh) and by the Pilot (pilot-dispatcher.sh). This file pins the lib on its own, behind a fake `bd`:
#   1. sourcing: no side effect at source time, safe twice under `set -euo pipefail`, also under a POSIX sh;
#   2. CHILDREN_STATES_JQ — the verdict table over a store: none / hand (each label, in_progress), a closed child never counts, a child
#      is a row whose `.parent` is the mother OR whose parent-child edge points at it (a `blocks` edge is not a child), only DIRECT
#      children count, and CHILDREN_BULK_VALID_JQ: anything that is not "an array of objects with an id" is `unreadable`, never `none`;
#   3. children_candidate_ids — which candidate rows are looked up (every row with an id: the row itself cannot say, see below);
#   4. children_in_hand_states — the argv of the ONE bd read (`list --json --limit 0`, `-C <db>` form for the Pilot's per-rig stores),
#      one read however many candidates, none for an empty list, and bd failing / printing nothing / printing garbage = every
#      candidate `unreadable` (rc 0 always: the states ARE the answer);
#   5. children_state_of — a missing verdict line is `unreadable`: a candidate is kept ONLY on an explicit `none`;
#   6. drop_mothers_with_children_in_hand — stdout, rc and stderr: a mother in hand is dropped SILENTLY (a real "nothing for you":
#      the probe's contract reads ANY stderr line as "`[]` is not no-work"), a mother whose children cannot be read is dropped LOUDLY
#      (stderr + rc 1);
#   7. the live schema: on the REAL store, the bulk grouping gives the same answer as `bd list --parent` for a real parent (SKIP when
#      bd is unreadable or the store has no parent);
#   8. textual MUTANTS of the lib (hand read as none, unreadable read as none, closed children counted, the dependent_count fast path of
#      the first draft put back, ...) must each be caught.
# WHY the store is read and not the candidate's row: measured 31/10, `dependent_count` in `bd ready` / `bd list` / `bd query` rows does not
# count parent-child links (`bd show` does): the real mother ga-hfx1kou is 0 in every list row. Every fixture below that stands for a
# mother therefore carries dependent_count 0, as bd prints it. CIH_LIB_UNDER_TEST overrides the lib (mutation checks). Needs bash, jq, sh.
# Exit 0 iff every check holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${CIH_LIB_UNDER_TEST:-$SELF_DIR/children-in-hand-lib.sh}"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad()  { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
skip() { echo "  ~ SKIP: $*"; SKIP=$((SKIP+1)); }
eq()   { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/children-in-hand.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX"

# fake bd: logs argv (\037-separated) and answers `[-C <db>] list --json --limit 0` from $FIX/store.{json,raw,fail,empty}; no fixture answers
# `[]` (a store with nothing in it). `list --parent` is NOT served: the lib must not use it. Any other call is loud.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
if [ "$1" = "-C" ]; then shift 2; fi
case "$1 $2 $3 $4" in
  "list --json --limit 0")
    [ -f "$FIX/store.fail" ]  && exit 1
    [ -f "$FIX/store.empty" ] && exit 0
    [ -f "$FIX/store.raw" ]   && { cat "$FIX/store.raw"; exit 0; }
    [ -f "$FIX/store.json" ]  && { cat "$FIX/store.json"; exit 0; }
    printf '[]'; exit 0 ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE/bd"
reset() { rm -f "${FIX:?}"/* "$TMP/bd.log"; : > "$TMP/bd.log"; }
bdcalls() { grep -c . "$TMP/bd.log" 2>/dev/null || true; }
# a store row: row <id> <parent|-> <status> [label ...]  (with a parent: .parent AND the parent-child edge, as bd prints a child)
row() { local id="$1" par="$2" st="$3"; shift 3; local labels; labels="$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length>0))')"
        if [ "$par" = "-" ]; then jq -cn --arg id "$id" --arg st "$st" --argjson l "$labels" '{id:$id,status:$st,labels:$l,issue_type:"task",dependent_count:0,dependencies:null}'
        else jq -cn --arg id "$id" --arg par "$par" --arg st "$st" --argjson l "$labels" '{id:$id,status:$st,parent:$par,labels:$l,issue_type:"task",dependent_count:0,dependencies:[{issue_id:$id,depends_on_id:$par,type:"parent-child"}]}'; fi; }
arr()   { printf '[%s]' "$(IFS=,; echo "$*")"; }
# a candidate row: what bd ready / bd list print for a MOTHER - dependent_count 0 (parent-child links are not counted there)
cand()  { jq -cn --arg id "$1" '{id:$id,title:"t",status:"open",labels:[],dependent_count:0,dependency_count:0}'; }
store() { arr "$@" > "$FIX/store.json"; }

# load the lib into THIS shell (the functions under test); PATH carries the fake bd
export BD_LOG="$TMP/bd.log" FIX
: > "$BD_LOG"
. "$LIB"
PATH="$FAKE:$PATH"
# vs <store-json> <id> — the state of <id> over that store
vs()    { printf '%s' "$1" | jq -r --argjson ids "[\"$2\"]" "$CHILDREN_STATES_JQ" 2>/dev/null | cut -f1; }
valid() { printf '%s' "$1" | jq -e "$CHILDREN_BULK_VALID_JQ" >/dev/null 2>&1 && echo valid || echo invalid; }

echo "== 1. sourcing: no side effect, twice under set -euo pipefail, and under a POSIX sh"
out="$(cd "$TMP" && BD_LOG="$TMP/src.log" PATH="$FAKE:$PATH" bash -c 'set -euo pipefail; . "$1"; . "$1"; type children_in_hand_states children_candidate_ids children_state_of drop_mothers_with_children_in_hand >/dev/null; echo sourced' _ "$LIB" 2>&1)"
eq "bash, twice, set -euo pipefail" "$out" "sourced"
out="$(cd "$TMP" && BD_LOG="$TMP/src.log" PATH="$FAKE:$PATH" sh -c '. "$1"; type children_in_hand_states >/dev/null && echo sourced' _ "$LIB" 2>&1)"
eq "POSIX sh" "$out" "sourced"
[ ! -s "$TMP/src.log" ] && ok "sourcing never calls bd" || bad "sourcing called bd: $(cat "$TMP/src.log")"

echo "== 2. the verdict table (CHILDREN_STATES_JQ) over a store"
eq "empty store: no children"                      "$(vs '[]' M)" "none"
eq "one open child, no label (merely ready)"       "$(vs "$(arr "$(row M.1 M open)")" M)" "none"
eq "one open child with an unrelated label"        "$(vs "$(arr "$(row M.1 M open area:ui)")" M)" "none"
eq "a label that only looks like a gate one"       "$(vs "$(arr "$(row M.1 M open gate:queuedX gate:fix-attempt gate:delivery)")" M)" "none"
eq "child in_progress"                             "$(vs "$(arr "$(row M.1 M in_progress)")" M)" "hand"
for l in story:in-flight gate:queued gate:reviewing gate:passed gate:needs-fix gate:fix-attempt:1 gate:fix-attempt:3 delivery:merged delivery:pr-open; do
  eq "open child labelled $l"                      "$(vs "$(arr "$(row M.1 M open "$l")")" M)" "hand"
done
eq "a closed child with a gate label does not count"  "$(vs "$(arr "$(row M.1 M closed gate:queued)")" M)" "none"
eq "closed gate child + open plain child"          "$(vs "$(arr "$(row M.1 M closed gate:queued)" "$(row M.2 M open)")" M)" "none"
eq "closed gate child + open gated child"          "$(vs "$(arr "$(row M.1 M closed gate:queued)" "$(row M.2 M open gate:queued)")" M)" "hand"
eq "a deferred / blocked / hooked child with no gate label is not in hand" "$(vs "$(arr "$(row M.1 M deferred)" "$(row M.2 M blocked)" "$(row M.3 M hooked)")" M)" "none"
eq "labels absent / null on an open child"         "$(vs '[{"id":"M.1","status":"open","parent":"M"},{"id":"M.2","status":"open","parent":"M","labels":null}]' M)" "none"
eq "labels with non-string members are ignored"    "$(vs '[{"id":"M.1","status":"open","parent":"M","labels":[1,null,{"a":1}]}]' M)" "none"
eq "status absent counts as not closed (+ a label)" "$(vs '[{"id":"M.1","parent":"M","labels":["gate:queued"]}]' M)" "hand"
echo "   -- who is a child"
eq "the children of ANOTHER bead do not count"     "$(vs "$(arr "$(row X.1 X open gate:queued)" "$(row X.2 X in_progress)")" M)" "none"
eq "a bead that is in progress itself is not its own child" "$(vs "$(arr "$(row M - in_progress story:in-flight)")" M)" "none"
eq ".parent alone (no edge) is a child"            "$(vs '[{"id":"M.1","status":"open","parent":"M","labels":["gate:queued"]}]' M)" "hand"
eq "a parent-child edge alone (no .parent) is a child" "$(vs '[{"id":"M.1","status":"open","labels":["gate:queued"],"dependencies":[{"issue_id":"M.1","depends_on_id":"M","type":"parent-child"}]}]' M)" "hand"
eq "a blocks edge to M is not a child"             "$(vs '[{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":[{"issue_id":"Q","depends_on_id":"M","type":"blocks"}]}]' M)" "none"
eq "a parent-child edge to ANOTHER bead is not M's child" "$(vs '[{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":[{"issue_id":"Q","depends_on_id":"X","type":"parent-child"}]}]' M)" "none"
eq "dependencies null / absent on a row"           "$(vs '[{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":null},{"id":"R","status":"open","labels":["gate:queued"]}]' M)" "none"
eq "only DIRECT children count: a grandchild in hand does not hold the grandmother" "$(vs "$(arr "$(row M.1 M open)" "$(row M.1.1 M.1 in_progress)")" M)" "none"
eq "…but it does hold its own mother"              "$(vs "$(arr "$(row M.1 M open)" "$(row M.1.1 M.1 in_progress)")" M.1)" "hand"
out="$(printf '%s' "$(arr "$(row A.1 A open gate:queued)")" | jq -r --argjson ids '["A","B"]' "$CHILDREN_STATES_JQ" | tr '\t\n' ': ')"
eq "one line per id, in the order given"           "$out" "hand:A none:B "
echo "   -- everything that is not an array of objects with an id is invalid (-> unreadable), never none"
eq "empty array"                                   "$(valid '[]')" "valid"
eq "an array of good rows"                         "$(valid "$(arr "$(row M.1 M open)")")" "valid"
eq "an object instead of an array"                 "$(valid '{"id":"m.1","status":"open"}')" "invalid"
eq "null"                                          "$(valid 'null')" "invalid"
eq "a string"                                      "$(valid '"x"')" "invalid"
eq "a number"                                      "$(valid '3')" "invalid"
eq "an object whose VALUES are good rows"          "$(valid '{"x":{"id":"m.1","status":"open"}}')" "invalid"
eq "a row that is not an object"                   "$(valid '[1]')" "invalid"
eq "a row without id"                              "$(valid '[{"status":"open"}]')" "invalid"
eq "a row with an empty id"                        "$(valid '[{"id":"","status":"open"}]')" "invalid"
eq "one good row + one row without id"             "$(valid '[{"id":"m.1","status":"open"},{"status":"open"}]')" "invalid"
eq "one good row + one row that is a number"       "$(valid '[{"id":"m.1","status":"open"}, 3]')" "invalid"

echo "== 3. children_candidate_ids — which candidate rows are looked up"
ids() { printf '%s' "$1" | children_candidate_ids | tr '\n' ' ' | sed 's/ $//'; }
eq "a mother (dependent_count 0): looked up"        "$(ids "$(arr "$(cand a)")")" "a"
eq "dependent_count is irrelevant: 0, 7, null, absent, a string" "$(ids '[{"id":"a","dependent_count":0},{"id":"b","dependent_count":7},{"id":"c","dependent_count":null},{"id":"d"},{"id":"e","dependent_count":"x"}]')" "a b c d e"
eq "a row without id is never looked up"            "$(ids '[{"dependent_count":3}]')" ""
eq "a row with an empty id is never looked up"      "$(ids '[{"id":""}]')" ""
eq "a non-object row is skipped, the rest still read" "$(ids '[7,{"id":"a"}]')" "a"
eq "duplicates are looked up once"                  "$(ids '[{"id":"a"},{"id":"a"}]')" "a"
eq "empty array"                                    "$(ids '[]')" ""
eq "not JSON -> nothing (the caller goes on as before)" "$(ids 'garbage')" ""
eq "a JSON object -> nothing"                       "$(ids '{"id":"a"}')" ""
eq "empty stdin -> nothing"                         "$(ids '')" ""

echo "== 4. children_in_hand_states — the one read and its three states"
states() { printf '%s' "$1" | children_in_hand_states ${2:+"$2"} | tr '\t\n' ': '; }
reset; store "$(row ga-hfx1kou.1 ga-hfx1kou open gate:queued)" "$(row ga-hfx1kou.2 ga-hfx1kou open gate:queued)"
eq "the real incident shape (dependent_count 0 on the mother's row, children in the gate; ids come back sorted)" "$(states "$(arr "$(cand ga-hfx1kou)" "$(cand P)")")" "none:P hand:ga-hfx1kou "
eq "…ONE bd call, the exact argv"                  "$(tr '\037' ' ' < "$TMP/bd.log" | sed 's/ *$//')" "list --json --limit 0"
reset; store "$(row M.1 M open gate:queued)"
many=(); for i in $(seq 1 20); do many+=("$(cand "B$i")"); done
states "$(arr "${many[@]}")" >/dev/null
eq "twenty candidates: still ONE bd call"          "$(bdcalls)" "1"
reset; store "$(row M.1 M open gate:queued)"
eq "with a db dir: -C form"                        "$(states "$(arr "$(cand M)")" /some/db)" "hand:M "
eq "…the argv carries -C <db> before the verb"     "$(tr '\037' ' ' < "$TMP/bd.log" | sed 's/ *$//')" "-C /some/db list --json --limit 0"
reset
eq "empty store: none"                             "$(states "$(arr "$(cand M)")")" "none:M "
reset
eq "no candidate -> nothing printed"               "$(states '[]')" ""
eq "…and NO bd call"                               "$(bdcalls)" "0"
reset
eq "stdin not JSON -> nothing printed"             "$(states 'garbage')" ""
eq "…and NO bd call"                               "$(bdcalls)" "0"
reset; : > "$FIX/store.fail"
eq "bd fails (rc 1) -> every candidate unreadable" "$(states "$(arr "$(cand M)" "$(cand P)")")" "unreadable:M unreadable:P "
eq "…and the function itself returns 0"            "$(printf '%s' "$(arr "$(cand M)")" | children_in_hand_states >/dev/null; echo $?)" "0"
reset; : > "$FIX/store.empty"
eq "bd prints nothing (rc 0) -> unreadable"        "$(states "$(arr "$(cand M)")")" "unreadable:M "
reset; echo 'Error: dolt is down' > "$FIX/store.raw"
eq "bd prints garbage -> unreadable"               "$(states "$(arr "$(cand M)")")" "unreadable:M "
reset; echo '{"error":"x"}' > "$FIX/store.raw"
eq "bd prints a JSON object -> unreadable"         "$(states "$(arr "$(cand M)")")" "unreadable:M "
reset; echo '[{"status":"open"}]' > "$FIX/store.raw"
eq "bd prints a row without id -> unreadable"      "$(states "$(arr "$(cand M)")")" "unreadable:M "
reset; echo '[7]' > "$FIX/store.raw"
eq "bd prints a non-object row -> unreadable"      "$(states "$(arr "$(cand M)")")" "unreadable:M "

echo "== 5. children_state_of — a candidate is kept ONLY on an explicit none"
sof() { printf '%s' "$1" | children_state_of "$2"; }
eq "hand"                                          "$(sof "$(printf 'hand\tM\nnone\tP\n')" M)" "hand"
eq "none"                                          "$(sof "$(printf 'hand\tM\nnone\tP\n')" P)" "none"
eq "no line for the id -> unreadable"              "$(sof "$(printf 'hand\tM\n')" P)" "unreadable"
eq "empty verdicts -> unreadable"                  "$(sof '' P)" "unreadable"
eq "a verdict that is neither -> unreadable"       "$(sof "$(printf 'weird\tM\n')" M)" "unreadable"
eq "an empty id -> unreadable"                     "$(sof "$(printf 'none\t\n')" '')" "unreadable"
eq "an id that only prefixes another does not match" "$(sof "$(printf 'none\tM.1\n')" M)" "unreadable"

echo "== 6. drop_mothers_with_children_in_hand — stdout, rc, stderr"
run_drop() { # <candidates-json>: DOUT / DRC / DERR / DCALLS
  : > "$TMP/bd.log"; DOUT="$(printf '%s' "$1" | drop_mothers_with_children_in_hand 2>"$TMP/derr")"; DRC=$?; DERR="$(cat "$TMP/derr")"; DCALLS="$(bdcalls)"
}
ids_of() { printf '%s' "$1" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null; }

reset; store "$(row M.1 M open gate:queued)"
run_drop "$(arr "$(cand M)" "$(cand P)")"
eq "mother in hand dropped (its row says dependent_count 0), the plain bead stays" "$(ids_of "$DOUT")" "P"
eq "…rc 0"                                         "$DRC" "0"
eq "…NOTHING on stderr (a real verdict, not a doubt)" "$DERR" ""
eq "…ONE read for both candidates"                 "$DCALLS" "1"

reset; store "$(row M.1 M open)"
run_drop "$(arr "$(cand M)" "$(cand P)")"
eq "mother whose children are merely ready stays"  "$(ids_of "$DOUT")" "M,P"
eq "…rc 0 and silent"                              "$DRC|$DERR" "0|"

reset; : > "$FIX/store.fail"
run_drop "$(arr "$(cand M)" "$(cand P)")"
eq "store unreadable: EVERY candidate is dropped (the row cannot say which are mothers)" "$(ids_of "$DOUT")" ""
eq "…rc 1 (the caller marks the tier)"             "$DRC" "1"
if printf '%s' "$DERR" | grep -q 'could not read the children of M' && printf '%s' "$DERR" | grep -q 'could not read the children of P'; then ok "…and stderr says which beads and why"; else bad "…stderr lacks the could-not-read lines: [$DERR]"; fi

reset; store "$(row M.1 M in_progress)"
run_drop "$(arr "$(cand M)")"
eq "only a mother in hand: [] and rc 0, silent"    "$DOUT|$DRC|$DERR" "[]|0|"

reset
run_drop "$(arr "$(cand A)" "$(cand B)")"
eq "no mother: unchanged, ONE read, rc 0, silent"  "$(ids_of "$DOUT")|$DCALLS|$DRC|$DERR" "A,B|1|0|"

reset
run_drop '[]'
eq "no candidate: unchanged and NO bd call"        "$DOUT|$DCALLS|$DRC|$DERR" "[]|0|0|"

reset; store "$(row P.1 P open)" "$(row Q.1 Q in_progress)"
run_drop "$(arr "$(cand P)" "$(cand Q)" "$(cand R)")"
eq "order kept across drops (P, R survive)"        "$(ids_of "$DOUT")" "P,R"
reset
run_drop 'not json at all'
eq "stdin not JSON: handed back untouched, rc 0, no bd call" "$DOUT|$DRC|$DCALLS" "not json at all|0|0"
run_drop ''
eq "empty stdin: empty answer, rc 0"               "$DOUT|$DRC" "|0"
reset; store "$(row M.1 M open gate:queued)"
run_drop '[{"title":"no id"},{"id":"P"}]'
eq "a candidate without id is kept (nothing to look up), the rest is judged" "$(printf '%s' "$DOUT" | jq -c 'map(.id // "-")')" '["-","P"]'

echo "   -- pp_log (the probe's log function) gets the in-hand verdict, never stderr"
reset; store "$(row M.1 M open gate:queued)"
pp_log() { echo "$*" >> "$TMP/pp.log"; }; : > "$TMP/pp.log"
run_drop "$(arr "$(cand M)")"
if grep -q 'mother M not offered: its children are in hand' "$TMP/pp.log"; then ok "in-hand mother -> a pp_log line"; else bad "no pp_log line: $(cat "$TMP/pp.log")"; fi
eq "…still silent on stderr"                       "$DERR" ""
reset; : > "$FIX/store.fail"; : > "$TMP/pp.log"
run_drop "$(arr "$(cand M)")"
if grep -q 'mother M not offered: its children could not be read' "$TMP/pp.log"; then ok "unreadable mother -> a pp_log line too"; else bad "no pp_log line: $(cat "$TMP/pp.log")"; fi
unset -f pp_log

echo "== 7. live store: the bulk grouping gives the same answer as bd list --parent for a real parent"
if [ -n "${CIH_SKIP_LIVE:-}" ]; then
  skip "live check disabled (CIH_SKIP_LIVE)"
else
  # the fake bd shadows the real one in PATH from here on; look the real one up by its absolute path and run with a PATH that has it first
  REAL_BD=""; for d in $(printf '%s' "$PATH" | tr ':' ' '); do [ "$d" = "$FAKE" ] && continue; [ -x "$d/bd" ] && { REAL_BD="$d/bd"; break; }; done
  if [ -z "$REAL_BD" ]; then
    skip "no real bd on PATH"
  else
    LIVEDIR="${GC_CITY_PATH:-$HOME/gt/.gascity-gastown-hq}"
    live="$(cd "$LIVEDIR" 2>/dev/null && timeout 90 "$REAL_BD" list --json --limit 0 2>/dev/null </dev/null || true)"
    if [ "$(valid "${live:-null}")" != valid ]; then
      skip "bd list did not answer a valid array (bd unreadable or no .beads here) — live schema not checked"
    else
      par="$(printf '%s' "$live" | jq -r '[ .[] | select((.parent // "") != "") | .parent ] | first // empty')"
      if [ -z "$par" ]; then
        skip "the live store has no child row — nothing to compare"
      else
        own="$(printf '%s' "$live" | jq -c --arg p "$par" '[ .[] | select(.id == $p) ]')"
        [ "$own" = "[]" ] && own="[{\"id\":\"$par\"}]"
        lib_state="$(cd "$LIVEDIR" && PATH="$(dirname "$REAL_BD"):${PATH#"$FAKE":}" timeout 90 bash -c '. "$1"; printf "%s" "$2" | children_in_hand_states' _ "$LIB" "$own" | cut -f1 | head -1)"
        per_parent="$(cd "$LIVEDIR" && timeout 90 "$REAL_BD" list --parent "$par" --json --limit 0 2>/dev/null </dev/null || true)"
        want="$(printf '%s' "$per_parent" | jq -r --arg p "$par" 'if type != "array" then "unreadable" else (if ([ .[] | select((.status // "") != "closed")
              | select((.status // "") == "in_progress" or ((.labels // []) | any(.[]?; type == "string"
                and (. == "story:in-flight" or . == "gate:queued" or . == "gate:reviewing" or . == "gate:passed" or . == "gate:needs-fix"
                     or startswith("gate:fix-attempt:") or startswith("delivery:"))))) ] | length) > 0 then "hand" else "none" end) end' 2>/dev/null)"
        eq "live parent $par: bulk grouping == bd list --parent" "$lib_state" "$want"
        live_dc="$(printf '%s' "$live" | jq -r --arg p "$par" '[ .[] | select(.id == $p) | .dependent_count ] | first // "absent"')"
        echo "   (info: the live list row of $par says dependent_count=$live_dc - the lib does not read it)"
      fi
    fi
  fi
fi

# ---- mutants: the lib with ONE literal replaced; each must break at least one check of core() -------------------------------------
echo "== 8. mutants of the lib"
core() { # the decisions every mutant has to break at least one of; sourced into a subshell with the mutant lib
  (
    . "$CIH_LIB_UNDER_TEST"
    PATH="$FAKE:$PATH"
    v() { printf '%s' "$1" | jq -r --argjson ids '["M"]' "$CHILDREN_STATES_JQ" 2>/dev/null | cut -f1; }
    chk() { [ "$2" = "$3" ] && echo "  ✓ $1" || echo "  ✗ $1: expected [$3], got [$2]"; }
    chk "in_progress is hand"            "$(v '[{"id":"M.1","parent":"M","status":"in_progress"}]')" hand
    chk "gate:queued is hand"            "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:queued"]}]')" hand
    chk "gate:reviewing is hand"         "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:reviewing"]}]')" hand
    chk "gate:passed is hand"            "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:passed"]}]')" hand
    chk "gate:needs-fix is hand"         "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:needs-fix"]}]')" hand
    chk "story:in-flight is hand"        "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["story:in-flight"]}]')" hand
    chk "gate:fix-attempt:N is hand"     "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:fix-attempt:2"]}]')" hand
    chk "delivery:* is hand"             "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["delivery:merged"]}]')" hand
    chk "a merely ready child is none"   "$(v '[{"id":"M.1","parent":"M","status":"open","labels":[]}]')" none
    chk "a closed gated child is none"   "$(v '[{"id":"M.1","parent":"M","status":"closed","labels":["gate:queued"]}]')" none
    chk "[] is none"                     "$(v '[]')" none
    chk ".parent alone is a child"       "$(v '[{"id":"M.1","parent":"M","status":"open","labels":["gate:queued"]}]')" hand
    chk "the edge alone is a child"      "$(v '[{"id":"M.1","status":"open","labels":["gate:queued"],"dependencies":[{"depends_on_id":"M","type":"parent-child"}]}]')" hand
    chk "a blocks edge is not a child"   "$(v '[{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":[{"depends_on_id":"M","type":"blocks"}]}]')" none
    chk "a parent-child edge to ANOTHER bead is not M's child" "$(v '[{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":[{"depends_on_id":"X","type":"parent-child"}]}]')" none
    chk "another bead's child is not M's" "$(v '[{"id":"X.1","parent":"X","status":"open","labels":["gate:queued"]}]')" none
    chk "an invalid store is detected"   "$(printf '%s' '[{"status":"open"}]' | jq -e "$CHILDREN_BULK_VALID_JQ" >/dev/null 2>&1 && echo valid || echo invalid)" invalid
    chk "a non-array store is detected"  "$(printf '%s' '{"x":{"id":"a"}}' | jq -e "$CHILDREN_BULK_VALID_JQ" >/dev/null 2>&1 && echo valid || echo invalid)" invalid
    chk "a mother with dependent_count 0 is looked up" "$(printf '%s' '[{"id":"M","dependent_count":0}]' | children_candidate_ids | tr '\n' ' ')" "M "
    chk "a row without id is not looked up" "$(printf '%s' '[{"title":"x"},{"id":"M"}]' | children_candidate_ids | tr '\n' ' ')" "M "
    st() { printf '%s' '[{"id":"M"}]' | children_in_hand_states ${1:+"$1"} | tr '\t\n' ': '; }
    : > "$FIX/store.fail"
    chk "bd failing is unreadable"       "$(st)" "unreadable:M "
    rm -f "$FIX/store.fail"; : > "$FIX/store.empty"
    chk "bd silent is unreadable"        "$(st)" "unreadable:M "
    rm -f "$FIX/store.empty"; echo oops > "$FIX/store.raw"
    chk "bd garbage is unreadable"       "$(st)" "unreadable:M "
    rm -f "$FIX/store.raw"; printf '%s' '[{"id":"M.1","parent":"M","status":"in_progress"}]' > "$FIX/store.json"
    chk "the bulk read finds a child"    "$(st)" "hand:M "
    : > "$BD_LOG"; st /some/db >/dev/null
    chk "the -C form reaches bd"         "$(tr '\037' ' ' < "$BD_LOG" | sed 's/ *$//')" "-C /some/db list --json --limit 0"
    rm -f "$FIX/store.json"
    chk "a missing verdict is unreadable" "$(printf '' | children_state_of M)" unreadable
    chk "a none line is none"            "$(printf 'none\tM\n' | children_state_of M)" none
    printf '%s' '[{"id":"H.1","parent":"H","status":"open","labels":["gate:queued"]}]' > "$FIX/store.json"
    o="$(printf '[{"id":"H"},{"id":"P"}]' | drop_mothers_with_children_in_hand 2>"$TMP/mut.err")"; r=$?
    chk "drop: only P survives"          "$(printf '%s' "$o" | jq -r 'map(.id) | join(",")')" P
    chk "drop: rc 0 and silent for a mother in hand" "$r|$(grep -c . "$TMP/mut.err")" "0|0"
    rm -f "$FIX/store.json"; : > "$FIX/store.fail"
    o="$(printf '[{"id":"U"},{"id":"P"}]' | drop_mothers_with_children_in_hand 2>"$TMP/mut.err")"; r=$?
    chk "drop: nothing survives an unreadable store" "$(printf '%s' "$o" | jq -r 'map(.id) | join(",")')" ""
    chk "drop: rc 1 for the unreadable"  "$r" 1
    chk "drop: a stderr line per unreadable candidate" "$(grep -c . "$TMP/mut.err")" 2
  )
}
mutate() { # <source> <out> <literal old> <literal new>: no such literal (or more than one) = not a mutant = loud
  python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[3])==1, "mutation site not found: "+sys.argv[3][:60]; open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' "$1" "$2" "$3" "$4"
}
check_mutant() { # <name> <literal old> <literal new>
  local before_fail=$FAIL before_pass=$PASS
  if ! mutate "$SELF_DIR/children-in-hand-lib.sh" "$TMP/mut-lib.sh" "$2" "$3" 2>"$TMP/mut.build.err"; then bad "mutant $1 could not be built: $(cat "$TMP/mut.build.err")"; return; fi
  reset
  CIH_LIB_UNDER_TEST="$TMP/mut-lib.sh" core > "$TMP/mut.out" 2>&1
  FAIL=$before_fail; PASS=$before_pass
  if grep -q '^  ✗' "$TMP/mut.out"; then ok "mutant $1 is caught ($(grep -c '^  ✗' "$TMP/mut.out") check(s) fail)"; else bad "mutant $1 SURVIVED: no decision of core() noticed it"; fi
}
if [ -z "${CIH_LIB_UNDER_TEST:-}" ]; then
  # the unmutated lib must pass core() cleanly, or the mutant verdicts mean nothing
  reset; CIH_LIB_UNDER_TEST="$LIB" core > "$TMP/base.out" 2>&1
  if grep -q '^  ✗' "$TMP/base.out"; then bad "core() fails on the real lib: $(grep '^  ✗' "$TMP/base.out" | head -3)"; else ok "core() passes on the real lib ($(grep -c '^  ✓' "$TMP/base.out") checks)"; fi
  check_mutant "in_progress not counted"            '((.status // "") == "in_progress"
         or ' '(false
         or '
  check_mutant "gate:queued not counted"            'or . == "gate:queued" ' 'or . == "gate:queued-x" '
  check_mutant "gate:reviewing not counted"         'or . == "gate:reviewing" ' 'or . == "gate:reviewing-x" '
  check_mutant "gate:passed not counted"            'or . == "gate:passed"' 'or . == "gate:passed-x"'
  check_mutant "gate:needs-fix not counted"         'or . == "gate:needs-fix"' 'or . == "gate:needs-fix-x"'
  check_mutant "story:in-flight not counted"        '. == "story:in-flight"' '. == "story:in-flight-x"'
  check_mutant "gate:fix-attempt not counted"       'startswith("gate:fix-attempt:")' 'startswith("gate:fix-attempt-x:")'
  check_mutant "delivery not counted"               'startswith("delivery:")' 'startswith("delivery-x:")'
  check_mutant "closed children counted"            '((.status // "") != "closed")
    and' 'true
    and'
  check_mutant "hand read as none"                  '(if $n > 0 then "hand" else "none" end)' '(if $n > 0 then "none" else "none" end)'
  check_mutant ".parent ignored"                    '((.parent // "") == $p)' 'false'
  check_mutant "the parent-child edge ignored"      '((.type // .dep_type // "") == "parent-child")' 'false'
  check_mutant "every edge counts as a child"       '((.type // .dep_type // "") == "parent-child")' '((.type // .dep_type // "") != "")'
  check_mutant "every row is a child of every candidate" '((.parent // "") == $p)' 'true'
  check_mutant "the edge target is not compared"    '((.depends_on_id // "") == $p)' 'true'
  check_mutant "non-array store read as valid"      'CHILDREN_BULK_VALID_JQ='"'"'type == "array" and all(' 'CHILDREN_BULK_VALID_JQ='"'"'all('
  check_mutant "row without id read as valid"       'type == "object" and (((.id // "") | tostring) != ""))'"'" 'type == "object")'"'"
  check_mutant "bd failure read as no children"     'cs_all=$(bd list --json --limit 0 2>/dev/null </dev/null) || cs_all=""' 'cs_all=$(bd list --json --limit 0 2>/dev/null </dev/null) || cs_all="[]"'
  check_mutant "unreadable store read as none"      "jq -r '.[] | \"unreadable\\t\" + .'" "jq -r '.[] | \"none\\t\" + .'"
  check_mutant "the -C form dropped"                'cs_all=$(bd -C "$cs_db" list --json --limit 0 2>/dev/null </dev/null) || cs_all=""' 'cs_all=$(bd list --json --limit 0 2>/dev/null </dev/null) || cs_all=""'
  check_mutant "the dependent_count fast path (first draft)" '| (.id // "") | tostring | select(length > 0) ] | unique | .[]'"'" '| select((.dependent_count // 0) > 0) | (.id // "") | tostring | select(length > 0) ] | unique | .[]'"'"
  check_mutant "a row without id looked up"         '| (.id // "") | tostring | select(length > 0) ] | unique | .[]'"'" '| (.id // "") | tostring ] | unique | .[]'"'"
  check_mutant "missing verdict read as none"       '(*) printf "unreadable" ;;' '(*) printf "none" ;;'
  check_mutant "unreadable not dropped"             '(*) dm_drop="$dm_drop
$dm_i"; dm_unread="$dm_unread $dm_i" ;;' '(*) dm_unread="$dm_unread $dm_i" ;;'
  check_mutant "hand not dropped"                   '(hand) dm_drop="$dm_drop
$dm_i"; dm_hand="$dm_hand $dm_i" ;;' '(hand) dm_hand="$dm_hand $dm_i" ;;'
  check_mutant "unreadable drop returns 0"          '[ -z "$dm_unread" ]' 'true'
  check_mutant "unreadable not announced on stderr" 'echo "pool-probe: could not read the children of $dm_i - NOT offered (inert, not '"'"'no work'"'"'; ga-vdac4cj)" >&2' ':'
  check_mutant "hand mother announced on stderr"    'if type pp_log >/dev/null 2>&1; then pp_log "mother $dm_i not offered: its children are in hand (in progress, or held by the gate / a delivery; ga-vdac4cj)"; fi' 'echo "mother $dm_i held back" >&2'
else
  skip "mutants (CIH_LIB_UNDER_TEST is set)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]

#!/usr/bin/env bash
# pool-probe-children.selftest.sh — ga-vdac4cj.
#
# The dog's probe (pool-probe.sh) must not hand out a MOTHER whose work belongs to its children. Incident, 31/10: a feature sliced
# into children (ga-hfx1kou -> .1/.2) kept its own gate:queued while the slices held the gate markers; grw FIX8 cleared that label
# as a phantom, the mother came back to the probe as the OLDEST plain ready bead, a dog session was spent on it and refused it
# (pool:refused:delivered-awaiting-gate) - and the next probe offered it again. pool-probe.selftest.sh cannot hold this proof: it
# runs with the filter pinned OFF (the filter makes one bd read the engine's text does not). This file runs only the script, behind a
# fake `bd` and a fake `gc`, and pins the three states of the filter (children-in-hand-lib.sh):
#   children in hand   (an open child in progress, or labelled story:in-flight / gate:* / delivery:*) -> the mother is dropped,
#                       SILENTLY (stderr empty, `[]` + exit 0 is a real "nothing for you")
#   children not in hand (no children, or only merely-ready / closed ones)                           -> the mother is kept
#   children cannot be read (bd failed, silent, or answered garbage)                                  -> dropped, stderr says so, the
#                       tier is marked unreadable, exit 3 when nothing else is found: inert and loud, never "no work", never "go ahead"
# The fixtures model what bd REALLY prints (measured 31/10): the mother's own row says dependent_count 0 (list/ready rows do not count
# parent-child links; `bd show` does) and carries no hint of children, so the filter reads the store ONCE per tier that holds a candidate
# (`bd list --json --limit 0`) and groups it by `.parent`. A first draft skipped the read for dependent_count 0 and would never have
# looked at a real mother: section 1 is the regression for that, and a mutant puts the skip back.
# plus: the filter runs before the oldest-pick (the oldest being the mother must not hide the next bead), tiers 2 and 3 are covered,
# the cost is one read per tier with a candidate (none for an empty tier) and the engine's own bd calls are untouched, and a lib that is
# missing or corrupt leaves the engine's own answer (a line in the pool-probe log, silent stderr). Textual MUTANTS of the script and of
# the lib must each be caught.
# Needs bash, jq, sh. Exit 0 iff every check holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="${PP_PROBE_UNDER_TEST:-$SELF_DIR/pool-probe.sh}"        # override = mutation checks / "does this fail on the previous HEAD?"
export GATE_FOCUS_ACTIVE_OVERRIDE=0   # ga-6fkx9je: pin the gate focus mode OFF (the real state file would turn this red whenever the mode is ON)
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 1; }
[ -f "$PROBE" ] || { echo "FATAL: probe not found: $PROBE"; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/pool-probe-children.XXXXXX")"
trap '[ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf -- "$TMP"' EXIT
FAKE="$TMP/bin"; FIX="$TMP/fix"; mkdir -p "$FAKE" "$FIX" "$TMP/city"

# fake bd: ready (tier 1 / tier 2), query (tier 3), and the ONE bulk read of the filter, `list --json --limit 0`, which answers
# store.{json,raw,fail,empty} (the not-closed beads of the store; default `[]`). `list --parent` is NOT served: the filter must not use it.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
case "$1 $2 $3" in
  "ready --metadata-field gc.routed_to="*)  key=tier1 ;;
  "ready --metadata-field gc.run_target="*) key=legacy ;;
  "query --json "*)                         key=ephemeral ;;
  "list --json --limit")
      [ "$4" = 0 ] || { echo "fake bd: unexpected call: $*" >&2; exit 2; }
      [ -f "$FIX/store.fail" ]  && exit 1
      [ -f "$FIX/store.empty" ] && exit 0
      [ -f "$FIX/store.raw" ]   && { cat "$FIX/store.raw"; exit 0; }
      [ -f "$FIX/store.json" ]  && { cat "$FIX/store.json"; exit 0; }
      printf '[]'; exit 0 ;;
  "show "*)  exit 1 ;;
  *) echo "fake bd: unexpected call: $*" >&2; exit 2 ;;
esac
if [ -f "$FIX/$key.fail" ]; then exit 1; fi
if [ -f "$FIX/$key.json" ]; then cat "$FIX/$key.json"; else printf '[]'; fi
EOF
cat > "$FAKE/gc" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$GC_LOG"
case " $* " in *" session list --json "*) printf '{"sessions":[]}' ;; *) echo "fake gc: unexpected call: $*" >&2; exit 2 ;; esac
EOF
chmod +x "$FAKE/bd" "$FAKE/gc"

reset() { rm -f "${FIX:?}"/*; }
# a candidate row as bd ready prints it: bead <id> <updated_at> <dependent_count|->. The REAL value for a mother is 0 (list/ready rows do
# not count parent-child links, measured 31/10), so every test uses 0 unless it is about the field itself; "-" = no such field at all.
bead()  { if [ "$3" = "-" ]; then jq -cn --arg id "$1" --arg u "$2" '{id:$id,title:"a bead",status:"open",updated_at:$u,labels:[],issue_type:"task",dependencies:[],metadata:{"gc.routed_to":"gastown.dog"}}';
          else jq -cn --arg id "$1" --arg u "$2" --argjson d "$3" '{id:$id,title:"a bead",status:"open",updated_at:$u,labels:[],issue_type:"task",dependencies:[],dependent_count:$d,dependency_count:0,metadata:{"gc.routed_to":"gastown.dog"}}'; fi; }
# legacy (tier 2) and ephemeral (tier 3) candidates: workflow beads with gc.run_target and no gc.routed_to
legacy() { jq -cn --arg id "$1" --arg u "$2" --argjson d "$3" '{id:$id,title:"a workflow bead",status:"open",updated_at:$u,created_at:$u,labels:[],issue_type:"task",dependencies:[],dependent_count:$d,dependency_count:0,metadata:{"gc.run_target":"gastown.dog","gc.kind":"workflow"}}'; }
# a row of the store as `bd list --json` prints it: child <id> <parent> <status> [labels...] (a child carries .parent and a parent-child edge)
child()  { local id="$1" par="$2" st="$3"; shift 3; local l; l="$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length>0))')"
           jq -cn --arg id "$id" --arg par "$par" --arg st "$st" --argjson l "$l" '{id:$id,status:$st,parent:$par,labels:$l,issue_type:"task",dependent_count:0,dependencies:[{issue_id:$id,depends_on_id:$par,type:"parent-child"}]}'; }
arr()    { printf '[%s]' "$(IFS=,; echo "$*")"; }
tier1()  { arr "$@" > "$FIX/tier1.json"; }
tier2()  { arr "$@" > "$FIX/legacy.json"; }
tier3()  { arr "$@" > "$FIX/ephemeral.json"; }
store()  { arr "$@" > "$FIX/store.json"; }

# run — OUT / RC / ERR / IDS (ids of the answer, "-" for []) / READS (bulk reads of the lib) / PARENTQ (any `list --parent`) / MOLS (the engine's own molecule reads)
run() {
  : > "$TMP/bd.log"; : > "$TMP/gc.log"; : > "$TMP/pp.log"
  OUT="$(BD_LOG="$TMP/bd.log" GC_LOG="$TMP/gc.log" FIX="$FIX" PATH="$FAKE:$PATH" GC_SESSION_ORIGIN=ephemeral \
         DISK_FREE_OVERRIDE_MB=100000 POOL_PROBE_LOG="$TMP/pp.log" GC_CITY_PATH="$TMP/city" sh "$PROBE" gastown.dog 2>"$TMP/err")"; RC=$?
  ERR="$(cat "$TMP/err")"
  IDS="$(printf '%s' "$OUT" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null)"
  [ -z "$IDS" ] && IDS="-"
  READS="$(grep -c '^list.--json.--limit.0.$' "$TMP/bd.log" || true)"
  PARENTQ="$(grep -c '^list.--parent' "$TMP/bd.log" || true)"
  MOLS="$(grep -c -- '--status.in_progress' "$TMP/bd.log" || true)"
}
silent() { if [ -z "$ERR" ]; then ok "$1: nothing on stderr"; else bad "$1: unexpected stderr: ${ERR:0:200}"; fi; }
tells()  { if printf '%s' "$ERR" | grep -q "could not read the children of $2"; then ok "$1: stderr says the children of $2 could not be read"; else bad "$1: stderr lacks the could-not-read line — got: ${ERR:0:200}"; fi; }
logged() { if grep -q "$2" "$TMP/pp.log"; then ok "$1: the pool-probe log has it"; else bad "$1: no '$2' in the pool-probe log: $(head -c 300 "$TMP/pp.log")"; fi; }

# core <label> — the decisions every mutant has to break at least one of; prints the failures it adds
core() {
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)" "$(bead P 2026-01-02T00:00:00Z 0)"; store "$(child M.1 M open gate:queued)"; run
  eq "$1 mother in hand (gate:queued child; its own dependent_count is 0) -> the next bead" "$IDS" "P"
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M in_progress)"; run
  eq "$1 mother in hand (in_progress child), nothing else -> []" "$IDS|$RC" "-|0"
  [ -z "$ERR" ] && ok "$1 …and silent" || bad "$1 …but stderr says: ${ERR:0:120}"
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; run
  eq "$1 store unreadable -> not offered, exit 3" "$IDS|$RC" "-|3"
  [ -n "$ERR" ] && ok "$1 …and stderr says so" || bad "$1 …but stderr is empty"
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)" "$(bead P 2026-01-02T00:00:00Z 0)"; : > "$FIX/store.fail"; run
  eq "$1 store unreadable + two candidates -> neither is offered, exit 3" "$IDS|$RC" "-|3"
  printf '%s' "$ERR" | grep -q 'could not read the children of M' && ok "$1 …stderr names the mother (not only the exit-3 line)" || bad "$1 …stderr does not name the mother: ${ERR:0:120}"
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; echo '[{"status":"open","labels":["gate:queued"]}]' > "$FIX/store.raw"; run
  eq "$1 a store row without an id -> unreadable, exit 3" "$IDS|$RC" "-|3"
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M open)"; run
  eq "$1 children merely ready -> the mother is offered" "$IDS" "M"
  reset; tier2 "$(legacy L 2026-01-01T00:00:00Z 0)"; store "$(child L.1 L open delivery:merged)"; run
  eq "$1 tier 2: mother in hand -> []" "$IDS|$RC" "-|0"
  reset; tier3 "$(legacy E 2026-01-01T00:00:00Z 0)"; store "$(child E.1 E open story:in-flight)"; run
  eq "$1 tier 3: mother in hand -> []" "$IDS|$RC" "-|0"
  reset; tier2 "$(legacy L 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; run
  eq "$1 tier 2: unreadable -> exit 3" "$IDS|$RC" "-|3"
  reset; tier3 "$(legacy E 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; run
  eq "$1 tier 3: unreadable -> exit 3" "$IDS|$RC" "-|3"
}

echo "== 1. the incident: the mother is the OLDEST ready bead (dependent_count 0 in its row, as bd prints it), its children sit in the gate"
reset; tier1 "$(bead ga-hfx1kou 2026-01-01T00:00:00Z 0)" "$(bead P1 2026-01-02T00:00:00Z 0)"
store "$(child ga-hfx1kou.1 ga-hfx1kou open gate:queued)" "$(child ga-hfx1kou.2 ga-hfx1kou open gate:queued)"; run
eq "answer: the next bead, not the mother" "$IDS" "P1"; eq "exit code" "$RC" "0"; silent "dropped mother"
eq "one read of the store for the whole tier" "$READS" "1"; eq "no per-candidate list --parent" "$PARENTQ" "0"
logged "dropped mother" "mother ga-hfx1kou not offered: its children are in hand"
echo "== 1b. …and with NOTHING else ready: [] and exit 0 with an empty stderr (a real 'nothing for you', the dog may drain)"
reset; tier1 "$(bead ga-hfx1kou 2026-01-01T00:00:00Z 0)"
store "$(child ga-hfx1kou.1 ga-hfx1kou open gate:queued)" "$(child ga-hfx1kou.2 ga-hfx1kou open gate:queued)"; run
eq "answer" "$IDS" "-"; eq "stdout is exactly []" "$OUT" "[]"; eq "exit code" "$RC" "0"; silent "only a mother in hand"
echo "== 1c. the children of ANOTHER bead do not hold a bead that is not their mother"
reset; tier1 "$(bead P 2026-01-01T00:00:00Z 0)"; store "$(child X.1 X open gate:queued)" "$(child X.2 X in_progress)"; run
eq "answer" "$IDS" "P"; silent "bystander"
echo "== 1d. a child is also recognised by its parent-child edge when the row carries no .parent"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"
store '{"id":"M.1","status":"open","labels":["gate:queued"],"dependencies":[{"issue_id":"M.1","depends_on_id":"M","type":"parent-child"}]}'; run
eq "answer" "$IDS|$RC" "-|0"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"
store '{"id":"Q","status":"open","labels":["gate:queued"],"dependencies":[{"issue_id":"Q","depends_on_id":"M","type":"blocks"}]}'; run
eq "a 'blocks' edge is not a child" "$IDS" "M"

echo "== 2. control: the same mother, its children merely ready (nothing builds them, nothing gates them) -> it enters"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)" "$(bead P 2026-01-02T00:00:00Z 0)"
store "$(child M.1 M open)" "$(child M.2 M open area:ui)"; run
eq "answer (the oldest)" "$IDS" "M"; eq "exit code" "$RC" "0"; silent "mother with ready children"
echo "== 2b. …no children at all, or the children all closed -> it enters (the default bd list hides closed ones)"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; run
eq "answer" "$IDS" "M"; silent "mother whose children are done"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M closed gate:queued)"; run
eq "a closed child that still wears a gate label does not hold the mother" "$IDS" "M"

echo "== 3. every label (and in_progress) that says 'in hand' holds the mother"
for l in story:in-flight gate:queued gate:reviewing gate:passed gate:needs-fix gate:fix-attempt:2 delivery:merged; do
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M open "$l")"; run
  eq "child labelled $l" "$IDS|$RC" "-|0"
done
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M in_progress)"; run
eq "child in_progress" "$IDS|$RC" "-|0"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M closed)" "$(child M.2 M open)" "$(child M.3 M open gate:queued)"; run
eq "three children, only the last one in hand" "$IDS" "-"

echo "== 4. the store cannot be read -> inert AND loud: dropped, stderr, the tier is marked, exit 3 when nothing else is found"
for how in fail empty; do
  reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.$how"; run
  eq "bd list $how: answer" "$IDS" "-"; eq "bd list $how: exit code" "$RC" "3"; tells "bd $how" M
  if printf '%s' "$ERR" | grep -q 'tier(s) 1 unreadable'; then ok "bd $how: the exit-3 line names tier 1"; else bad "bd $how: no 'tier(s) 1 unreadable' line: ${ERR:0:200}"; fi
done
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; echo 'Error: dolt unreachable' > "$FIX/store.raw"; run
eq "garbage: answer" "$IDS" "-"; eq "garbage: exit code" "$RC" "3"; tells "garbage" M
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; echo '{"error":"x"}' > "$FIX/store.raw"; run
eq "a JSON object instead of the array: exit code" "$RC" "3"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; echo '[7]' > "$FIX/store.raw"; run
eq "a non-object row: exit code" "$RC" "3"
logged "unreadable mother" "mother M not offered: its children could not be read"
echo "== 4b. …an unreadable store holds back EVERY candidate of the tier (the row cannot say which ones are mothers), and stderr names each"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)" "$(bead P 2026-01-02T00:00:00Z 0)"; : > "$FIX/store.fail"; run
eq "answer" "$IDS" "-"; eq "exit code (nothing found, a tier unreadable)" "$RC" "3"; tells "unreadable store" M; tells "unreadable store" P
echo "== 4c. …tiers 1 and 2 both read the same failing store: nothing is offered, exit 3"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; tier2 "$(legacy L 2026-01-02T00:00:00Z 0)"; run
eq "answer and exit code" "$IDS|$RC" "-|3"

echo "== 5. the filter runs BEFORE the oldest-pick: two mothers in hand, then a real bead"
reset; tier1 "$(bead M1 2026-01-01T00:00:00Z 0)" "$(bead M2 2026-01-02T00:00:00Z 0)" "$(bead P 2026-01-03T00:00:00Z 0)"
store "$(child M1.1 M1 open gate:passed)" "$(child M2.1 M2 in_progress)"; run
eq "answer" "$IDS" "P"; silent "two mothers in hand"; eq "ONE read for the three candidates" "$READS" "1"
echo "== 5b. …the first mother is in hand, the second one is free to build -> the second"
reset; tier1 "$(bead M1 2026-01-01T00:00:00Z 0)" "$(bead M2 2026-01-02T00:00:00Z 0)"
store "$(child M1.1 M1 open gate:queued)" "$(child M2.1 M2 open)"; run
eq "answer" "$IDS" "M2"

echo "== 6. cost: one read per tier that holds a candidate, none for an empty tier; the candidate's own dependent_count changes nothing"
reset; run
eq "nothing ready anywhere: answer" "$IDS|$RC" "-|0"; eq "…and no read of the store at all" "$READS" "0"
reset; tier1 "$(bead P1 2026-01-01T00:00:00Z 0)" "$(bead P2 2026-01-02T00:00:00Z 0)"; run
eq "dependent_count 0: answer" "$IDS" "P1"; eq "one read" "$READS" "1"; silent "no mother"
reset; tier1 "$(bead P1 2026-01-01T00:00:00Z -)"; run
eq "no dependent_count field: answer" "$IDS" "P1"; eq "one read" "$READS" "1"
reset; tier1 "$(bead P1 2026-01-01T00:00:00Z 5)"; run
eq "a positive dependent_count: answer (it is not a mother just because of it)" "$IDS" "P1"; eq "one read" "$READS" "1"
reset; many=(); for i in $(seq 1 20); do many+=("$(bead "B$i" "2026-01-01T00:00:$(printf %02d "$i")Z" 0)"); done; tier1 "${many[@]}"; run
eq "twenty candidates: answer" "$IDS" "B1"; eq "…still ONE read" "$READS" "1"
echo "== 6b. the engine's own bd calls are untouched: same calls, same flags, same order, the filter only ADDS its read"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)" "$(bead P 2026-01-02T00:00:00Z 0)"; tier2 "$(legacy L 2026-01-03T00:00:00Z 0)"; store "$(child M.1 M open gate:queued)"; run
with_filter="$(grep -v '^list.--json.--limit.0.$' "$TMP/bd.log" | tr '\037' ' ')"
POOL_PROBE_CHILDREN_LIB=/nonexistent/lib.sh run
without_filter="$(tr '\037' ' ' < "$TMP/bd.log")"
if [ "$with_filter" = "$without_filter" ]; then ok "bd calls minus the filter's read == bd calls with the filter off"; else bad "the engine's bd calls changed: with [$with_filter] vs off [$without_filter]"; fi

echo "== 7. tiers 2 and 3 are filtered too (and marked when unreadable)"
reset; tier2 "$(legacy L1 2026-01-01T00:00:00Z 0)" "$(legacy L2 2026-01-02T00:00:00Z 0)"; store "$(child L1.1 L1 open gate:queued)"; run
eq "tier 2: mother in hand, next workflow bead" "$IDS" "L2"; silent "tier 2 in hand"
reset; tier2 "$(legacy L1 2026-01-01T00:00:00Z 0)"; store "$(child L1.1 L1 open)"; run
eq "tier 2 control: ready children -> offered" "$IDS" "L1"
reset; tier2 "$(legacy L1 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; run
eq "tier 2: unreadable -> exit 3" "$IDS|$RC" "-|3"; tells "tier 2" L1
if printf '%s' "$ERR" | grep -q 'tier(s) 2 unreadable'; then ok "tier 2: the exit-3 line names tier 2"; else bad "tier 2: no 'tier(s) 2 unreadable': ${ERR:0:200}"; fi
reset; tier3 "$(legacy E1 2026-01-01T00:00:00Z 0)" "$(legacy E2 2026-01-02T00:00:00Z 0)"; store "$(child E1.1 E1 open gate:reviewing)"; run
eq "tier 3: mother in hand, next workflow bead" "$IDS" "E2"; silent "tier 3 in hand"
reset; tier3 "$(legacy E1 2026-01-01T00:00:00Z 0)"; store "$(child E1.1 E1 open)"; run
eq "tier 3 control: ready children -> offered" "$IDS" "E1"
reset; tier3 "$(legacy E1 2026-01-01T00:00:00Z 0)"; : > "$FIX/store.fail"; run
eq "tier 3: unreadable -> exit 3" "$IDS|$RC" "-|3"; tells "tier 3" E1
if printf '%s' "$ERR" | grep -q 'tier(s) 3 unreadable'; then ok "tier 3: the exit-3 line names tier 3"; else bad "tier 3: no 'tier(s) 3 unreadable': ${ERR:0:200}"; fi
echo "== 7b. a tier that holds a mother in hand does not stop the next tier from answering"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M open gate:queued)"; tier2 "$(legacy L 2026-01-02T00:00:00Z 0)"; run
eq "tier 1 emptied by the filter -> tier 2 answers" "$IDS" "L"; eq "one read per tier that held a candidate" "$READS" "2"

echo "== 8. the engine's own molecule read is untouched (the candidate's molecule_id path)"
reset; jq -cn '[{id:"W",title:"w",status:"open",updated_at:"2026-01-01T00:00:00Z",labels:[],issue_type:"task",dependencies:[],dependent_count:0,metadata:{"gc.routed_to":"gastown.dog","molecule_id":"MOL"}}]' > "$FIX/tier1.json"; run
eq "answer" "$IDS" "W"; eq "the molecule read happens as before" "$MOLS" "1"; eq "…and the lib adds exactly one read" "$READS" "1"

echo "== 9. the lib missing or corrupt: the engine's own answer, a line in the pool-probe log, nothing on stderr"
reset; tier1 "$(bead M 2026-01-01T00:00:00Z 0)"; store "$(child M.1 M open gate:queued)"
export POOL_PROBE_CHILDREN_LIB="$TMP/no-such-lib.sh"; run
eq "lib missing: answer (unfiltered, as the engine's probe)" "$IDS" "M"; eq "lib missing: exit code" "$RC" "0"; silent "lib missing"; eq "lib missing: reads" "$READS" "0"
logged "lib missing" "children filter lib missing or corrupt"
printf 'drop_mothers_with_children_in_hand() { if then fi\n' > "$TMP/corrupt-lib.sh"; export POOL_PROBE_CHILDREN_LIB="$TMP/corrupt-lib.sh"; run
eq "lib corrupt: answer (the probe did not die)" "$IDS" "M"; eq "lib corrupt: exit code" "$RC" "0"; silent "lib corrupt"
logged "lib corrupt" "children filter lib missing or corrupt"
printf 'exit 7\n' > "$TMP/exiting-lib.sh"; export POOL_PROBE_CHILDREN_LIB="$TMP/exiting-lib.sh"; run
eq "lib that exits at source time: the probe survives" "$IDS|$RC" "M|0"
unset POOL_PROBE_CHILDREN_LIB

# ---- mutants: the script (or its lib) with ONE literal replaced; each must break at least one decision of core() ----------------
echo "== 10. mutants of the script and of the lib"
mutate() { # <source> <out> <literal old> <literal new>: no such literal (or more than one) = not a mutant = loud
  python3 -I -c 'import sys; s=open(sys.argv[1]).read(); assert s.count(sys.argv[3])==1, "mutation site not found: "+sys.argv[3][:60]; open(sys.argv[2],"w").write(s.replace(sys.argv[3], sys.argv[4]))' "$1" "$2" "$3" "$4"
}
check_mutant() { # <name> <probe|lib> <literal old> <literal new>
  local before_fail=$FAIL before_pass=$PASS saved="$PROBE" src
  if [ "$2" = lib ]; then src="$SELF_DIR/children-in-hand-lib.sh"; else src="$SELF_DIR/pool-probe.sh"; fi
  if ! mutate "$src" "$TMP/mut.sh" "$3" "$4" 2>"$TMP/mut.err"; then bad "mutant $1 could not be built: $(cat "$TMP/mut.err")"; return; fi
  if [ "$2" = lib ]; then export POOL_PROBE_CHILDREN_LIB="$TMP/mut.sh"; else PROBE="$TMP/mut.sh"; export POOL_PROBE_CHILDREN_LIB="$SELF_DIR/children-in-hand-lib.sh"; fi
  core "[$1]" > "$TMP/mut.out" 2>&1
  PROBE="$saved"; unset POOL_PROBE_CHILDREN_LIB; FAIL=$before_fail; PASS=$before_pass
  if grep -q '^  ✗' "$TMP/mut.out"; then ok "mutant $1 is caught ($(grep -c '^  ✗' "$TMP/mut.out") check(s) fail)"; else bad "mutant $1 SURVIVED: no decision of core() noticed it"; fi
}
if [ -z "${PP_PROBE_UNDER_TEST:-}" ]; then
  # the unmutated pair must pass core() cleanly, or the mutant verdicts mean nothing
  core "[base]" > "$TMP/base.out" 2>&1
  if grep -q '^  ✗' "$TMP/base.out"; then bad "core() fails on the real probe: $(grep '^  ✗' "$TMP/base.out" | head -3)"; else ok "core() passes on the real probe ($(grep -c '^  ✓' "$TMP/base.out") checks)"; fi
  check_mutant "filter not wired in tier 1"      probe 't1_kept=$(printf "%s" "$t1_kept" | drop_mothers_with_children_in_hand) || mark 1' 't1_kept=$(printf "%s" "$t1_kept")'
  check_mutant "filter not wired in tier 2"      probe 't2_kept=$(printf "%s" "$t2_kept" | drop_mothers_with_children_in_hand) || mark 2' 't2_kept=$(printf "%s" "$t2_kept")'
  check_mutant "filter not wired in tier 3"      probe 't3_kept=$(printf "%s" "$t3_kept" | drop_mothers_with_children_in_hand) || mark 3' 't3_kept=$(printf "%s" "$t3_kept")'
  check_mutant "tier 1 unreadable not marked"    probe 't1_kept=$(printf "%s" "$t1_kept" | drop_mothers_with_children_in_hand) || mark 1' 't1_kept=$(printf "%s" "$t1_kept" | drop_mothers_with_children_in_hand) || true'
  check_mutant "tier 2 unreadable not marked"    probe 't2_kept=$(printf "%s" "$t2_kept" | drop_mothers_with_children_in_hand) || mark 2' 't2_kept=$(printf "%s" "$t2_kept" | drop_mothers_with_children_in_hand) || true'
  check_mutant "tier 3 unreadable not marked"    probe 't3_kept=$(printf "%s" "$t3_kept" | drop_mothers_with_children_in_hand) || mark 3' 't3_kept=$(printf "%s" "$t3_kept" | drop_mothers_with_children_in_hand) || true'
  check_mutant "tier 1 filter after the pick"    probe 't1_kept=$(printf "%s" "$t1_kept" | drop_mothers_with_children_in_hand) || mark 1' 't1_kept=$(printf "%s" "$t1_kept" | jq -c ".[0:1]" | drop_mothers_with_children_in_hand) || mark 1'
  check_mutant "hand read as none"               lib   '(if $n > 0 then "hand" else "none" end)' '(if $n > 0 then "none" else "none" end)'
  check_mutant "fast path on dependent_count (the first draft)" lib '| (.id // "") | tostring | select(length > 0) ] | unique | .[]' '| select((.dependent_count // 0) > 0) | (.id // "") | tostring | select(length > 0) ] | unique | .[]'
  check_mutant "every row is a child of every candidate" lib '((.parent // "") == $p)' 'true'
  check_mutant "unreadable store read as none"   lib   "jq -r '.[] | \"unreadable\\t\" + .'" "jq -r '.[] | \"none\\t\" + .'"
  check_mutant "row validity not checked"        lib   'CHILDREN_BULK_VALID_JQ='"'"'type == "array" and all(.[]; type == "object" and (((.id // "") | tostring) != ""))'"'" 'CHILDREN_BULK_VALID_JQ='"'"'true'"'"
  check_mutant "unreadable not dropped"          lib   '(*) dm_drop="$dm_drop
$dm_i"; dm_unread="$dm_unread $dm_i" ;;' '(*) dm_unread="$dm_unread $dm_i" ;;'
  check_mutant "unreadable not announced"        lib   'echo "pool-probe: could not read the children of $dm_i - NOT offered (inert, not '"'"'no work'"'"'; ga-vdac4cj)" >&2' ':'
  check_mutant "unreadable drop returns 0"       lib   '[ -z "$dm_unread" ]' 'true'
  check_mutant "hand mother announced on stderr" lib   'if type pp_log >/dev/null 2>&1; then pp_log "mother $dm_i not offered: its children are in hand (in progress, or held by the gate / a delivery; ga-vdac4cj)"; fi' 'echo "mother $dm_i held back" >&2'
else
  echo "  ~ SKIP: mutants (PP_PROBE_UNDER_TEST is set)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]

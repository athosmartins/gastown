#!/usr/bin/env bash
# pilot-dispatcher.open-children.selftest.sh — ga-vdac4cj.
#
# _filter_open_children (pilot-dispatcher.sh) is the Pilot's wall against dispatching a MOTHER whose work belongs to its children
# (E11 incident of 31/10: ga-hfx1kou, sliced into .1/.2, came back as a plain approved story while its slices sat in the gate; a
# builder was spent on it and refused it). "In hand" has ONE definition, scripts/children-in-hand-lib.sh, shared with the dog pool
# probe. pilot-dispatcher.selftest.sh (scenario 19m) proves the stage inside a real DRY_RUN sweep; this file pins the stage on its
# own, with the Pilot's own shell options (set -euo pipefail), the way pilot-dispatcher.exclusion-trace.selftest.sh does for the
# other stages (the function body is extracted from the real file, log() injected, a fake `bd` on PATH):
#   1. the three states: children in hand -> the mother is held back (WARN + EXCLUÍDO line, the other candidates untouched, order
#      kept); not in hand / no children -> kept, and the candidate array comes back BYTE FOR BYTE; unreadable (bd failed / printed
#      nothing / printed garbage) -> held back too, LOUDLY (inert, the opposite of the fail-open of _filter_unblocked);
#   2. the cost and the read: ONE `bd -C <db> list --json --limit 0` per call however many candidates (never `list --parent`, never a
#      per-candidate read), none when no candidate has an id; the candidate's `dependent_count` is NOT consulted (measured 31/10: bd's
#      list / ready rows do not count parent-child links - the real mother ga-hfx1kou says 0, `bd show` says 2 - so every fixture's mother
#      below carries dependent_count 0, as bd prints it);
#   3. degradation: lib not loaded, stdin empty / not JSON -> pass-through, exit 0; the drop that cannot be applied -> inert `[]` + WARN;
#   4. stdout stays pure JSON (every diagnostic goes to stderr) and the stage never fails the pipeline under `set -e`;
#   5. the lib sourcing block of the real file: loads a good lib, and a missing / corrupt / exiting lib is a WARN, not a dead Pilot;
#   6. structural guards on the real file: EVERY `_filter_explicit_deps "X"` in a chain is followed by `| _filter_open_children "X"` with
#      the same store argument (a new chain that forgets it fails here), and the lib is sourced before the first top-level chain;
#   7. textual MUTANTS of the stage must each be caught.
# Needs bash, jq, python3. Exit 0 iff every check holds.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISPATCHER="${OC_DISPATCHER_UNDER_TEST:-$SELF_DIR/pilot-dispatcher.sh}"
LIB="$SELF_DIR/scripts/children-in-hand-lib.sh"
PASS=0; FAIL=0
ok()  { echo "  ✓ $*"; PASS=$((PASS+1)); }
bad() { echo "  ✗ $*"; FAIL=$((FAIL+1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1 (=$2)"; else bad "$1: expected [$3], got [$2]"; fi; }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required"; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required"; exit 2; }
[ -f "$DISPATCHER" ] || { echo "FATAL: dispatcher not found: $DISPATCHER"; exit 2; }
[ -f "$LIB" ] || { echo "FATAL: lib not found: $LIB"; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/pilot-open-children.XXXXXX")"
trap '[ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf -- "$WORK"' EXIT
FAKE="$WORK/bin"; FIX="$WORK/fix"; mkdir -p "$FAKE" "$FIX"

extract_fn() { sed -n "/^$1() {/,/^}\$/p" "$2"; }
LOG_FN="log()  { echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] [pilot-dispatcher] \$*\"; }"
FN="$(extract_fn _filter_open_children "$DISPATCHER")"
[ -n "$FN" ] || { echo "FATAL: _filter_open_children() not found in $DISPATCHER — has ga-vdac4cj landed?"; exit 2; }

# fake bd: logs argv; `[-C db] list --json --limit 0` answers store.{json,raw,fail,empty}, default `[]`. `list --parent` is NOT served.
cat > "$FAKE/bd" <<'EOF'
#!/bin/sh
{ for a in "$@"; do printf '%s\037' "$a"; done; printf '\n'; } >> "$BD_LOG"
if [ "$1" = "-C" ]; then shift 2; fi
[ "$1 $2 $3 $4" = "list --json --limit 0" ] || { echo "fake bd: unexpected call: $*" >&2; exit 2; }
[ -f "$FIX/store.fail" ]  && exit 1
[ -f "$FIX/store.empty" ] && exit 0
[ -f "$FIX/store.raw" ]   && { cat "$FIX/store.raw"; exit 0; }
[ -f "$FIX/store.json" ]  && { cat "$FIX/store.json"; exit 0; }
printf '[]'
EOF
chmod +x "$FAKE/bd"
REALJQ="$(command -v jq)"
reset() { rm -f "${FIX:?}"/*; : > "$WORK/bd.log"; }
# a store row for a child: child <id> <parent> <status> [label ...] (.parent AND the parent-child edge, as bd prints a child)
child() { local id="$1" par="$2" st="$3"; shift 3; local l; l="$(printf '%s\n' "$@" | jq -R -s -c 'split("\n") | map(select(length>0))')"; jq -cn --arg id "$id" --arg par "$par" --arg st "$st" --argjson l "$l" '{id:$id,status:$st,parent:$par,labels:$l,dependent_count:0,dependencies:[{issue_id:$id,depends_on_id:$par,type:"parent-child"}]}'; }
arr()   { printf '[%s]' "$(IFS=,; echo "$*")"; }
# a candidate row as bd ready / bd list print it: dependent_count 0 whether or not the bead is a mother; "-" = no such field
cand()  { if [ "${2:-0}" = "-" ]; then jq -cn --arg id "$1" '{id:$id,title:"t",priority:1,status:"open"}'; else jq -cn --arg id "$1" --argjson d "${2:-0}" '{id:$id,title:"t",priority:1,status:"open",dependent_count:$d}'; fi; }
store() { arr "$@" > "$FIX/store.json"; }

# mk_harness <name> <with-lib 1|0> <fn-text>: a script that runs the stage under the Pilot's own shell options
mk_harness() {
  { echo 'set -euo pipefail'; echo "$LOG_FN"
    [ "$2" = 1 ] && echo ". \"$LIB\""
    printf '%s\n' "$3"
    echo 'in="$(cat)"; printf "%s" "$in" | _filter_open_children "$1"; echo "<<rc=$?>>" >&2'
  } > "$WORK/$1.sh"
}
mk_harness h "1" "$FN"
mk_harness h-nolib "0" "$FN"
# run <harness> <stdin-json> [db]: OUT / ERRT / RC / READS (bd children reads)
run() {
  : > "$WORK/bd.log"
  OUT="$(printf '%s' "$2" | BD_LOG="$WORK/bd.log" FIX="$FIX" PATH="$FAKE:$PATH" bash "$WORK/$1.sh" "${3:-/db/city}" 2>"$WORK/err")"; RC=$?
  ERRT="$(cat "$WORK/err")"
  READS="$(grep -c . "$WORK/bd.log" || true)"
}
ids_of() { printf '%s' "$1" | jq -r 'if type == "array" then map(.id) | join(",") else "?" end' 2>/dev/null; }
rc_of_stage() { printf '%s' "$ERRT" | grep -o '<<rc=[0-9]*>>' | tail -1; }

echo "== 1. children in hand -> the mother is held back, the rest untouched and in order"
reset; store "$(child M.1 M open gate:queued)" "$(child M.2 M open gate:queued)"
IN="$(arr "$(cand A)" "$(cand M)" "$(cand B -)")"
run h "$IN"
eq "answer (the mother's own row says dependent_count 0)" "$(ids_of "$OUT")" "A,B"; eq "stage rc" "$(rc_of_stage)" "<<rc=0>>"
printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas em mãos' && ok "EXCLUÍDO line names the bead, the filter and the reason" || bad "no EXCLUÍDO line: ${ERRT:0:300}"
printf '%s' "$ERRT" | grep -q 'WARN: holding M back in /db/city - its children are in hand' && ok "WARN line names the bead and the store" || bad "no WARN line: ${ERRT:0:300}"
eq "ONE bd read for the three candidates" "$READS" "1"
eq "…with the store: -C <db> list --json --limit 0" "$(tr '\037' ' ' < "$WORK/bd.log" | sed 's/ *$//')" "-C /db/city list --json --limit 0"
eq "stdout is pure JSON" "$(printf '%s' "$OUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)" "yes"

reset; store "$(child M.1 M in_progress)"
run h "$(arr "$(cand M)")"
eq "child in_progress: only the mother -> []" "$OUT" "[]"
reset; store "$(child M1.1 M1 open delivery:merged)" "$(child M2.1 M2 open gate:passed)"
run h "$(arr "$(cand M1)" "$(cand P)" "$(cand M2)")"
eq "two mothers in hand + a plain bead -> the plain bead" "$(ids_of "$OUT")" "P"
reset; store "$(child ga-hfx1kou.1 ga-hfx1kou closed gate:passed)" "$(child ga-hfx1kou.2 ga-hfx1kou open gate:queued)"
run h "$(arr "$(cand ga-hfx1kou)" "$(cand Z)")"
eq "the E11 shape (one slice closed, one in the gate): the mother is held" "$(ids_of "$OUT")" "Z"
reset; store "$(child X.1 X open gate:queued)"
run h "$(arr "$(cand M)")"
eq "another bead's child in the gate does not hold M" "$(ids_of "$OUT")" "M"
reset; arr '{"id":"M.1","status":"open","labels":["gate:queued"],"dependencies":[{"depends_on_id":"M","type":"parent-child"}]}' > "$FIX/store.json"
run h "$(arr "$(cand M)")"
eq "a child known only by its parent-child edge (no .parent) holds M" "$OUT" "[]"

echo "== 2. not in hand -> kept, and the candidate array comes back BYTE FOR BYTE"
reset; store "$(child M.1 M open)" "$(child M.2 M closed gate:queued)"
IN="$(arr "$(cand A)" "$(cand M)")"
run h "$IN"
eq "children merely ready / closed: output identical to input" "$OUT" "$IN"; eq "…and silent on stderr (rc line only)" "$ERRT" "<<rc=0>>"
reset
IN="$(arr "$(cand M)")"
run h "$IN"
eq "no children at all (bd answers []): identical" "$OUT" "$IN"; eq "…one read" "$READS" "1"

echo "== 3. unreadable -> held back too, LOUDLY (inert, not fail-open); the row cannot say which are mothers, so ALL are held"
for how in fail empty; do
  reset; : > "$FIX/store.$how"
  run h "$(arr "$(cand A)" "$(cand M)")"
  eq "bd $how: answer" "$OUT" "[]"; eq "bd $how: stage rc (never fails the pipeline)" "$(rc_of_stage)" "<<rc=0>>"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas ilegíveis' && ok "bd $how: EXCLUÍDO line says unreadable" || bad "bd $how: no EXCLUÍDO/ilegíveis line: ${ERRT:0:300}"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO A por _filter_open_children: filhas ilegíveis' && ok "bd $how: …for A too" || bad "bd $how: A is not announced: ${ERRT:0:300}"
  printf '%s' "$ERRT" | grep -q 'WARN: holding M back .* could NOT be read' && ok "bd $how: WARN line says could NOT be read" || bad "bd $how: no WARN line: ${ERRT:0:300}"
done
reset; echo 'Error: dolt unreachable' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "garbage answer: held back" "$OUT" "[]"
reset; echo '{"error":"x"}' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "JSON object instead of the array: held back" "$OUT" "[]"
reset; echo '{"x":{"id":"M.1","status":"open","parent":"M","labels":["gate:queued"]}}' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "an object whose values are rows: held back" "$OUT" "[]"
reset; echo '[{"status":"open","parent":"M","labels":["gate:queued"]}]' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "a store row without an id: held back" "$OUT" "[]"
reset; echo '[7]' > "$FIX/store.raw"
run h "$(arr "$(cand M)")"
eq "a store row that is not an object: held back" "$OUT" "[]"

echo "== 4. the cost: ONE read per call, and the candidate's own row is not consulted"
reset
IN="$(arr "$(cand A 0)" "$(cand B -)" "$(cand C 7)")"
run h "$IN"
eq "dependent_count 0 / absent / 7: all looked up with ONE read, identical output" "$READS|$([ "$OUT" = "$IN" ] && echo same || echo changed)" "1|same"
eq "…nothing on stderr (rc line only)" "$ERRT" "<<rc=0>>"
reset
run h '[{"id":"A","dependent_count":"x"}]'
eq "non-numeric dependent_count: one read" "$READS" "1"
many=(); for i in $(seq 1 20); do many+=("$(cand "B$i")"); done
reset
run h "$(arr "${many[@]}")"
eq "twenty candidates: still ONE read" "$READS" "1"
reset
run h '[]'
eq "empty array: [] and no bd call" "$OUT|$READS" "[]|0"
reset
run h '[{"title":"no id"}]'
eq "a candidate without an id: untouched and no bd call" "$READS" "0"

echo "== 5. degradation: pass-through, never a dead pipeline"
reset; store "$(child M.1 M open gate:queued)"
IN="$(arr "$(cand M)")"
run h-nolib "$IN"
eq "lib not loaded: identical output (the Pilot as it was)" "$OUT" "$IN"; eq "…no bd call" "$READS" "0"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
run h ''
eq "empty stdin: []" "$OUT" "[]"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
run h 'not json at all'
eq "stdin not JSON: handed back untouched" "$OUT" "not json at all"; eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"
echo "   -- the drop that cannot be applied: inert [] + WARN (never the unfiltered list)"
cat > "$FAKE/jq" <<EOF
#!/bin/sh
case "\$*" in *"--argjson held"*) exit 5 ;; esac
exec "$REALJQ" "\$@"
EOF
chmod +x "$FAKE/jq"
run h "$IN"
rm -f "$FAKE/jq"
eq "drop fails: answer is []" "$OUT" "[]"
printf '%s' "$ERRT" | grep -q 'could not apply its drop' && ok "…and the WARN says so" || bad "…no 'could not apply its drop' WARN: ${ERRT:0:300}"
eq "…rc 0" "$(rc_of_stage)" "<<rc=0>>"

echo "== 6. the lib sourcing block of the real file"
BLOCK="$(sed -n '/^_GC_CIH_SIBLING=/,/^unset _GC_CIH_SIBLING/p' "$DISPATCHER")"
[ -n "$BLOCK" ] || bad "sourcing block (_GC_CIH_SIBLING … unset) not found in the dispatcher"
mkdir -p "$WORK/pil/scripts"
{ echo 'set -euo pipefail'; echo 'warn() { echo "WARN: $*"; }'; printf '%s\n' "$BLOCK"
  echo 'if type children_in_hand_states >/dev/null 2>&1 && type children_candidate_ids >/dev/null 2>&1 && type children_state_of >/dev/null 2>&1; then echo "loaded"; else echo "not-loaded"; fi'
  echo 'echo "alive"'; } > "$WORK/pil/block.sh"
LIBDST="$WORK/pil/scripts/children-in-hand-lib.sh"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "lib missing: WARN, not loaded, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
cp "$LIB" "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "good lib: loaded, no WARN" "$(printf '%s' "$out" | tr '\n' '|')" "loaded|alive"
printf 'children_in_hand_states() { if then fi\n' > "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "corrupt lib: WARN, not loaded, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
printf 'exit 7\n' > "$LIBDST"
out="$(bash "$WORK/pil/block.sh" 2>&1)"; eq "lib that exits at source time: WARN, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"
chmod 000 "$LIBDST" 2>/dev/null
out="$(bash "$WORK/pil/block.sh" 2>&1)"; chmod 644 "$LIBDST" 2>/dev/null
if [ "$(id -u)" = 0 ]; then echo "  ~ SKIP: unreadable-lib case (root reads everything)"; else eq "unreadable lib: WARN, Pilot alive" "$(printf '%s' "$out" | tr '\n' '|' | sed -E 's/WARN: [^|]*/WARN/')" "WARN|not-loaded|alive"; fi

echo "== 7. structural guards on the real file"
# the script goes through a file: the mini's /bin/bash 3.2.57 mis-parses a heredoc with quotes in its body inside $( ) (bash -n: unexpected EOF, so gate-bash32 refuses the file); bash 5 accepts it
cat > "$WORK/guard.py" <<'PYEOF'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
lines = src.split("\n")
# code lines only (a comment may quote a chain)
code = [(i + 1, l) for i, l in enumerate(lines) if not l.lstrip().startswith("#")]
sites = []
for i, l in code:
    for m in re.finditer(r'\b_filter_explicit_deps ("[^"]*")(.*)$', l):
        sites.append((i, m.group(1), m.group(2)))
bad = [(i, a) for i, a, rest in sites if not re.match(r'\s*\| _filter_open_children ' + re.escape(a), rest)]
opens = sum(len(re.findall(r'\b_filter_open_children "[^"]*"', l)) for i, l in code)
print("sites=%d opens=%d missing=%s" % (len(sites), opens, ",".join("%d:%s" % x for x in bad) or "-"))
# the lib is sourced before the first TOP-LEVEL line that runs a chain (column 0 assignment of a *_JSON= $(echo ... | _filter_explicit_deps)
src_line = next((i for i, l in code if re.match(r'\s*source "\$_GC_CIH_SIBLING"', l)), 0)
first_top = next((i for i, l in code if re.match(r'^[A-Z_0-9]+=\$\(echo .*_filter_explicit_deps', l)), 0)
print("source=%d first_top_chain=%d" % (src_line, first_top))
PYEOF
GUARD="$(python3 -I "$WORK/guard.py" "$DISPATCHER")"
echo "   $(printf '%s' "$GUARD" | tr '\n' ' ')"
sites="$(printf '%s' "$GUARD" | sed -n 's/^sites=\([0-9]*\) opens=.*/\1/p')"; opens="$(printf '%s' "$GUARD" | sed -n 's/^sites=[0-9]* opens=\([0-9]*\) .*/\1/p')"
missing="$(printf '%s' "$GUARD" | sed -n 's/^.*missing=\(.*\)$/\1/p')"
[ "${sites:-0}" -ge 10 ] 2>/dev/null && ok "found the chains ($sites sites of _filter_explicit_deps)" || bad "found only ${sites:-0} chain sites — the guard's pattern drifted"
eq "every _filter_explicit_deps site is followed by _filter_open_children with the same store argument (missing)" "$missing" "-"
eq "…as many _filter_open_children sites as chains" "$opens" "$sites"
sl="$(printf '%s' "$GUARD" | sed -n 's/^source=\([0-9]*\) first_top_chain=.*/\1/p')"; ft="$(printf '%s' "$GUARD" | sed -n 's/^source=[0-9]* first_top_chain=\([0-9]*\)$/\1/p')"
if [ "${sl:-0}" -gt 0 ] && [ "${ft:-0}" -gt 0 ] && [ "$sl" -lt "$ft" ]; then ok "the lib is sourced (line $sl) before the first top-level chain (line $ft)"; else bad "lib source line ($sl) is not before the first top-level chain ($ft)"; fi
# the stage is defined before the sourcing block and after _filter_explicit_deps (functions are defined before the top-level calls)
fd="$(grep -n '^_filter_explicit_deps() {' "$DISPATCHER" | head -1 | cut -d: -f1)"; od="$(grep -n '^_filter_open_children() {' "$DISPATCHER" | head -1 | cut -d: -f1)"
[ -n "$fd" ] && [ -n "$od" ] && [ "$od" -gt "$fd" ] && ok "_filter_open_children is defined (line $od) after _filter_explicit_deps (line $fd)" || bad "definition order wrong ($fd / $od)"

echo "== 8. mutants of the stage"
core() { # the decisions every mutant has to break at least one of; runs the mutant harness h-mut
  local o
  reset; store "$(child M.1 M open gate:queued)"; run h-mut "$(arr "$(cand A 0)" "$(cand M 0)")"
  [ "$(ids_of "$OUT")" = "A" ] || echo "  ✗ in hand is not dropped (mother row dependent_count 0): $(ids_of "$OUT")"
  reset; store "$(child M.1 M open)"; IN="$(arr "$(cand M 0)")"; run h-mut "$IN"
  [ "$OUT" = "$IN" ] || echo "  ✗ not in hand is not kept untouched"
  reset; : > "$FIX/store.fail"; run h-mut "$(arr "$(cand M 0)")"
  [ "$OUT" = "[]" ] || echo "  ✗ unreadable is not held back"
  printf '%s' "$ERRT" | grep -q 'ilegíveis' || echo "  ✗ unreadable is not announced"
  reset; store "$(child X.1 X open gate:queued)"; IN="$(arr "$(cand M 0)")"; run h-mut "$IN"
  [ "$OUT" = "$IN" ] || echo "  ✗ another bead's child holds M"
  reset; IN="$(arr "$(cand A 0)" "$(cand B -)" "$(cand C 7)")"; run h-mut "$IN"
  [ "$READS" = "1" ] || echo "  ✗ not exactly one read for three candidates (reads=$READS)"
  reset; store "$(child M.1 M open gate:queued)"; run h-mut "$(arr "$(cand M 0)")"
  printf '%s' "$ERRT" | grep -q 'EXCLUÍDO M por _filter_open_children: filhas em mãos' || echo "  ✗ the in-hand exclusion is not logged"
  printf '%s' "$ERRT" | grep -q 'WARN: holding M back' || echo "  ✗ the in-hand exclusion has no WARN"
  [ "$(tr '\037' ' ' < "$WORK/bd.log" | sed 's/ *$//')" = "-C /db/city list --json --limit 0" ] || echo "  ✗ the read does not go to the store (-C)"
  # the drop that cannot be applied: inert [], never the unfiltered list
  reset; store "$(child M.1 M open gate:queued)"
  printf '#!/bin/sh\ncase "$*" in *"--argjson held"*) exit 5 ;; esac\nexec "%s" "$@"\n' "$REALJQ" > "$FAKE/jq"; chmod +x "$FAKE/jq"
  run h-mut "$(arr "$(cand M 0)")"; rm -f "$FAKE/jq"
  [ "$OUT" = "[]" ] || echo "  ✗ a drop that cannot be applied hands the list on"
}
mutate() { # <out> <literal old> <literal new>: no such literal (or more than one) = not a mutant = loud
  python3 -I -c 'import sys; s=sys.stdin.read(); assert s.count(sys.argv[1])==1, "mutation site not found: "+sys.argv[1][:60]; sys.stdout.write(s.replace(sys.argv[1], sys.argv[2]))' "$2" "$3" <<<"$FN" > "$1"
}
check_mutant() { # <name> <literal old> <literal new>
  local before_fail=$FAIL before_pass=$PASS
  if ! mutate "$WORK/mut-fn.txt" "$2" "$3" 2>"$WORK/mut.err"; then bad "mutant $1 could not be built: $(cat "$WORK/mut.err")"; return; fi
  mk_harness h-mut 1 "$(cat "$WORK/mut-fn.txt")"
  core > "$WORK/mut.out" 2>&1
  FAIL=$before_fail; PASS=$before_pass
  if grep -q '^  ✗' "$WORK/mut.out"; then ok "mutant $1 is caught ($(grep -c '^  ✗' "$WORK/mut.out") check(s) fail)"; else bad "mutant $1 SURVIVED: no decision of core() noticed it"; fi
}
if [ -z "${OC_DISPATCHER_UNDER_TEST:-}" ]; then
  mk_harness h-mut 1 "$FN"; core > "$WORK/base.out" 2>&1
  if grep -q '^  ✗' "$WORK/base.out"; then bad "core() fails on the real stage: $(grep '^  ✗' "$WORK/base.out" | head -3)"; else ok "core() passes on the real stage"; fi
  check_mutant "hand not dropped"                  '      hand)
        held_ids="$held_ids $bid"' '      hand)
        :'
  check_mutant "unreadable kept (fail-open)"       '      *)
        held_ids="$held_ids $bid"' '      *)
        :'
  check_mutant "read goes to the wrong store"      'children_in_hand_states "$db_dir"' 'children_in_hand_states ""'
  check_mutant "dependent_count fast path (first draft)" 'ids=$(printf '"'"'%s'"'"' "$arr" | children_candidate_ids) || ids=""' 'ids=$(printf '"'"'%s'"'"' "$arr" | jq -r '"'"'.[] | select((.dependent_count // 0) > 0) | .id'"'"') || ids=""'
  check_mutant "a missing verdict is kept"          'state=$(printf '"'"'%s\n'"'"' "$verdicts" | children_state_of "$bid") || state="unreadable"' 'state=$(printf '"'"'%s\n'"'"' "$verdicts" | children_state_of "$bid"); [ "$state" = unreadable ] && state=none'
  check_mutant "in-hand exclusion not logged"      'log "[pilot] EXCLUÍDO $bid por _filter_open_children: filhas em mãos (in_progress / gate / delivery) - o trabalho é das filhas" >&2' ':'
  check_mutant "unreadable not announced"          'log "[pilot] EXCLUÍDO $bid por _filter_open_children: filhas ilegíveis (bd falhou) - retido, não dispensado" >&2' ':'
  check_mutant "drop failure hands the list on"    "    printf '[]'
    return 0
  fi
  printf '%s' \"\$filtered\"" "    printf '%s' \"\$arr\"
    return 0
  fi
  printf '%s' \"\$filtered\""
else
  echo "  ~ SKIP: mutants (OC_DISPATCHER_UNDER_TEST is set)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
